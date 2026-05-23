# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper_integration"
require "parse/agent"
require "parse/agent/mcp_dispatcher"
require "net/http"
require "json"
require "uri"
require "securerandom"

# ============================================================================
# Real-LLM x real-Parse-Server integration test for temporal / trend reasoning.
#
# Unlike the static cross-class lookup test (mcp_real_llm_docker_integration_test.rb)
# or the schema introspection test (mcp_real_llm_schema_introspection_test.rb),
# this file focuses entirely on LONGITUDINAL / TIME-SERIES analysis:
#
#   The signal is a *trend* — not a count, not a max — across four consecutive
#   weekly exams for four students with deliberately distinct performance arcs.
#   The LLM must fetch ordered exam data and reason about direction and variance.
#
# Full stack under test:
#   1. 4 MCPTrendStudent + 16 MCPTrendExam records seeded against Docker Parse.
#   2. Real Parse::Agent dispatches MCP calls through MCPDispatcher to live MongoDB.
#   3. A real LLM (gpt-4o-mini default) calls tools, sees temporal data, reasons.
#   4. Assertions verify the LLM named the right student and used trend language.
#
# Skipped unless BOTH:
#   - PARSE_TEST_USE_DOCKER=true   (docker-compose.test.yml stack is running)
#   - LLM_PROVIDER + LLM_API_KEY   (real LLM is configured)
#
# Distinct class namespace: MCPTrend* (no collision with other parallel files)
# ============================================================================
class MCPLLMTemporalAnalysisTest < Minitest::Test
  include ParseStackIntegrationTest

  # --------------------------------------------------------------------------
  # Fixture class definitions
  # --------------------------------------------------------------------------
  #
  # Two-class schema:
  #   MCPTrendStudent   — the student
  #   MCPTrendExam      — a weekly exam result with a pointer back to the student
  #
  # Deliberately minimal: this file is about temporal pattern detection, not
  # graph traversal. One subject, no teacher, no attendance.

  class MCPTrendStudent < Parse::Object
    parse_class "MCPTrendStudent"
    property :name, :string
    property :grade, :integer   # e.g. 10, 11, 12
  end

  class MCPTrendExam < Parse::Object
    parse_class "MCPTrendExam"
    property :title, :string        # "Week 1 Quiz" ... "Week 4 Quiz"
    property :score, :integer       # 0..100
    property :exam_date, :date      # staggered by week; Week 1 = oldest
    belongs_to :student, as: :pointer, class_name: "MCPTrendStudent"
  end

  # --------------------------------------------------------------------------
  # Ground-truth fixture data
  # --------------------------------------------------------------------------
  #
  # Four students, four exams each (16 rows total). Exam dates are staggered so
  # Week 1 is the OLDEST (21 days ago) and Week 4 is the most recent (today).
  # ORDER BY exam_date ASC therefore surfaces scores in the canonical order.

  STABLE_STUDENT    = "Ada"
  IMPROVING_STUDENT = "Bao"
  DECLINING_STUDENT = "Cheng"
  ERRATIC_STUDENT   = "Diego"

  TREND_FIXTURE_SCORES = {
    "Ada"   => [85, 86, 84, 87],   # stable, narrow band ±2 (range 3, stdev ~1.1)
    "Bao"   => [70, 78, 85, 92],   # +22 across 4 weeks — clear monotonic positive (range 22, stdev ~8.2)
    "Cheng" => [88, 82, 74, 65],   # -23 across 4 weeks — clear monotonic negative (range 23, stdev ~8.6)
    "Diego" => [95, 60, 85, 70],   # non-monotonic, widest range (35) and highest stdev (~13.5)
  }.freeze
  # Variance ranking (stdev): Diego 13.5 > Cheng 8.6 ~ Bao 8.2 > Ada 1.1
  # Diego's range (35) and stdev (13.5) are strictly larger than every other student,
  # so the "most inconsistent" answer is unambiguous. Cheng's decline is preserved as
  # a clear negative monotonic trend without competing with Diego on variance.

  # NOTE: do NOT override `def setup` / `def teardown`.
  # `ParseStackIntegrationTest.included(base)` injects those via
  # `base.define_method`; a subclass def would replace the injection and the
  # Parse client would never be configured.

  # --------------------------------------------------------------------------
  # Block helper: seed both classes, yield, tear down in reverse order.
  #
  # Dependency order: students first (exam pointers to students).
  # Teardown order:   exams first, then students.
  #
  # exam_date staggering: Week 1 is 21 days ago so ASC sort shows the scores in
  # ascending week order (70, 78, 85, 92 for Bao etc.).
  # --------------------------------------------------------------------------
  def with_trend_fixtures
    students = nil
    exams    = nil

    students = TREND_FIXTURE_SCORES.keys.map.with_index do |name, i|
      s = MCPTrendStudent.new(name: name, grade: 10 + (i % 3))
      assert s.save, "student save failed for #{name}: #{s.errors.full_messages.join(", ")}"
      s
    end
    students_by_name = students.each_with_object({}) { |s, h| h[s.name] = s }

    exams = TREND_FIXTURE_SCORES.flat_map do |name, scores|
      student = students_by_name.fetch(name)
      scores.each_with_index.map do |score, week_idx|
        # Week 1 = 21 days ago (oldest), Week 4 = 0 days ago (most recent).
        exam_date = Date.today - ((3 - week_idx) * 7)
        e = MCPTrendExam.new(
          title:     "Week #{week_idx + 1} Quiz",
          score:     score,
          exam_date: exam_date,
          student:   student
        )
        assert e.save, "exam save failed for #{name} week #{week_idx + 1}: #{e.errors.full_messages.join(", ")}"
        e
      end
    end

    yield students, exams
  ensure
    (exams    || []).each { |e| e.destroy rescue nil }
    (students || []).each { |s| s.destroy rescue nil }
  end

  # ==========================================================================
  # Test 1: Headline scenario — identify the student whose performance is
  # significantly DECLINING (the "who should we be concerned about" question).
  #
  # Ground truth: Cheng (88 → 82 → 74 → 65, a -23 drop over four weeks).
  # The LLM must fetch exam history ordered by date and reason about direction.
  # ==========================================================================
  def test_llm_identifies_declining_student_we_should_be_concerned_about
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_trend_fixtures do |students, exams|
      agent        = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      prompt = build_trend_prompt(
        "Look at exam scores over time for each student. Is there a student " \
        "whose academic performance is significantly declining and who we should " \
        "be concerned about? Answer with the student's name and a brief " \
        "one-sentence explanation of the trend you see.",
        hints: [
          "Fetch ALL exams in one call: query_class on MCPTrendExam with " \
          "limit: 20, include: [\"student\"], order: \"exam_date\" " \
          "(ascending = oldest first). This gives you all 16 rows with the " \
          "student name already resolved inline.",
          "Look for a student whose scores decrease consistently from Week 1 " \
          "to Week 4. The student we are concerned about starts very high and " \
          "finishes significantly lower.",
        ]
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)
      assert_temporal_finding(
        transcript,
        expected_name:    DECLINING_STUDENT,
        expected_pattern: /declin|drop|worsen|fall|decreas/i
      )
    end
  end

  # ==========================================================================
  # Test 2: Symmetric to Test 1 — identify the MOST IMPROVED student.
  #
  # Ground truth: Bao (70 → 78 → 85 → 92, a +22 gain over four weeks).
  # ==========================================================================
  def test_llm_identifies_most_improved_student
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_trend_fixtures do |students, exams|
      agent        = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      prompt = build_trend_prompt(
        "Which student has shown the most improvement in exam scores over the " \
        "four weeks? Answer with the student's name and a brief one-sentence " \
        "explanation of the trend.",
        hints: [
          "Fetch ALL exams in one call: query_class on MCPTrendExam with " \
          "limit: 20, include: [\"student\"], order: \"exam_date\" " \
          "(ascending = oldest first).",
          "Look for the student whose Week 4 score is highest relative to their " \
          "Week 1 score (largest positive difference).",
        ]
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)
      assert_temporal_finding(
        transcript,
        expected_name:    IMPROVING_STUDENT,
        expected_pattern: /improv|better|grew|increas|progress/i
      )
    end
  end

  # ==========================================================================
  # Test 3: Variance / inconsistency — identify the student with the HIGHEST
  # performance volatility (no monotonic direction, wide swing).
  #
  # Ground truth: Diego (95 → 60 → 85 → 70, standard deviation ~13.7).
  #
  # Variance reasoning is harder for smaller models than monotonic-trend
  # reasoning. The assertion accepts a broad set of synonyms. If gpt-4o-mini
  # consistently picks the wrong student on this one, the assertion can be
  # loosened to just name-check (see comment below), but run it first.
  # ==========================================================================
  def test_llm_flags_erratic_performer
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_trend_fixtures do |students, exams|
      agent        = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      prompt = build_trend_prompt(
        "Which student has the most inconsistent exam performance — the highest " \
        "variance or the widest swings between scores — over the four weeks? " \
        "Answer with the student's name and a brief one-sentence explanation.",
        hints: [
          "Fetch ALL exams in one call: query_class on MCPTrendExam with " \
          "limit: 20, include: [\"student\"], order: \"exam_date\" " \
          "(ascending = oldest first).",
          "Look for the student whose scores fluctuate the most — large drops " \
          "followed by recoveries, or big swings up and down. The range " \
          "(max score minus min score) per student is a useful measure.",
        ]
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)

      # NOTE: if gpt-4o-mini consistently misidentifies this student (e.g., calls
      # Cheng "inconsistent" instead of Diego), weaken this to a name-only check:
      #   assert_temporal_finding(transcript, expected_name: ERRATIC_STUDENT, expected_pattern: nil)
      # The broader synonym list (/fluctuat|varies|swing|inconsist|variab|unpredict|erratic|unstabl|volatile/i)
      # is intentionally permissive to accommodate paraphrase without relaxing the student-name check.
      assert_temporal_finding(
        transcript,
        expected_name:    ERRATIC_STUDENT,
        expected_pattern: /fluctuat|varies|swing|inconsist|variab|unpredict|erratic|unstabl|volatile/i
      )
    end
  end

  # ==========================================================================
  # Test 4: Open-ended synthesis — summarize overall class trajectory.
  #
  # An academic advisor or school admin would ask exactly this kind of open-ended
  # question. The LLM must mention at least the declining student (Cheng) or the
  # improving student (Bao) by name, and use at least one trend word.
  #
  # This is intentionally less strict than the targeted tests: it verifies that
  # a free-form synthesis question still surfaces the most notable signals from
  # the data.
  # ==========================================================================
  def test_llm_summarizes_class_trajectory
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_trend_fixtures do |students, exams|
      agent        = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      prompt = build_trend_prompt(
        "Summarize how the class is doing overall. Are there any students who " \
        "stand out positively or negatively in terms of their exam performance " \
        "over the four weeks?",
        hints: [
          "Fetch ALL exams in one call: query_class on MCPTrendExam with " \
          "limit: 20, include: [\"student\"], order: \"exam_date\" " \
          "(ascending = oldest first).",
          "Group scores by student, then describe each student's trajectory. " \
          "Highlight the student with the steepest decline and the one with the " \
          "most improvement.",
        ]
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)

      # Must invoke at least one data-fetching tool.
      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert (tool_calls & %w[query_class aggregate count_objects get_object]).any?,
             "model should invoke a data-fetching tool; got #{tool_calls.inspect}"

      # Must mention at least one of the two most notable students.
      assert (flat.include?(DECLINING_STUDENT) || flat.include?(IMPROVING_STUDENT)),
             "model must mention at least Cheng or Bao in its summary; got: #{flat[0, 800]}"

      # Must use at least one trend-direction word.
      assert_match(/improv|declin|drop|increas|worsen|better|progress|fall/i, flat,
                   "model must use trend language in its summary; got: #{flat[0, 800]}")
    end
  end

  private

  # --------------------------------------------------------------------------
  # Assertion helper: consolidates the standard temporal-finding assertions.
  #
  # Checks:
  #   1. At least one tool was called (the LLM queried something).
  #   2. That tool was a data-fetching operation.
  #   3. The final text names the expected student.
  #   4. The final text matches the expected trend pattern (if provided).
  #
  # Pass expected_pattern: nil to skip the pattern check (e.g., if you want
  # to assert only the student name without constraining the adjective used).
  # --------------------------------------------------------------------------
  def assert_temporal_finding(transcript, expected_name:, expected_pattern:)
    flat       = transcript_text(transcript)
    tool_calls = transcript_tool_names(transcript)

    refute_empty tool_calls,
                 "model must invoke at least one MCP tool; got none"

    assert (tool_calls & %w[query_class aggregate count_objects get_object]).any?,
           "model should invoke a data-fetching tool; got #{tool_calls.inspect}"

    assert flat.include?(expected_name),
           "model must identify '#{expected_name}' in its answer; got: #{flat[0, 800]}"

    if expected_pattern
      assert_match expected_pattern, flat,
                   "model must use appropriate trend language for '#{expected_name}'; got: #{flat[0, 800]}"
    end
  end

  # --------------------------------------------------------------------------
  # Prompt builder — prepends schema context and per-test hints.
  # --------------------------------------------------------------------------

  def build_trend_prompt(question, hints: [])
    hint_block = hints.empty? ? "" : hints.map { |h| "Hint: #{h}" }.join("\n") + "\n\n"

    <<~PROMPT
      You have access to MCP tools that query a Parse database tracking student
      exam performance over time. The database has two classes:

        MCPTrendStudent  fields: name (string), grade (integer)
        MCPTrendExam     fields: title (string "Week N Quiz"), score (integer 0-100),
                                 exam_date (Date — Week 1 is oldest, Week 4 is newest),
                                 student (Pointer -> MCPTrendStudent)

      There are 4 students and 4 exams per student (16 exam rows total).

      Key query parameters available:
        - limit: 20                        (fetch all 16 rows in one call)
        - order: "exam_date"               (ascending = oldest first = Week 1 first)
        - include: ["student"]             (resolves the student pointer inline so you
                                            see the student name without a second call)

      Pointer where-clause format (use this EXACT structure when filtering by pointer):
        { "<field>": { "__type": "Pointer", "className": "<ClassName>", "objectId": "<id>" } }

      #{hint_block}Question: #{question}
      Use tools to find the answer. Do not guess.
    PROMPT
  end

  # --------------------------------------------------------------------------
  # Transcript helpers
  # --------------------------------------------------------------------------

  def transcript_text(transcript)
    transcript.map { |m| m[:content].to_s }.compact.join(" ")
  end

  def transcript_tool_names(transcript)
    transcript.flat_map { |m| Array(m[:tool_calls]).map { |tc| tc[:name] } }
  end

  # --------------------------------------------------------------------------
  # MCP / tool helpers
  # --------------------------------------------------------------------------

  def fetch_openai_tools(agent)
    envelope = mcp_call({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => {} }, agent)
    tools    = envelope.dig("result", "tools")
    refute_nil tools, "tools/list returned no tools"
    mcp_tools_to_openai(tools)
  end

  # --------------------------------------------------------------------------
  # Provider configuration
  # --------------------------------------------------------------------------

  def configure_llm_provider!
    @provider = ENV["LLM_PROVIDER"]
    case @provider
    when "lmstudio"
      @base_url = ENV["LLM_BASE_URL"] || "http://localhost:1234/v1"
      @model    = ENV["LLM_MODEL"]    || "qwen2.5-7b-instruct"
      @api_key  = ENV["LLM_API_KEY"]  || "lm-studio"
    when "openai"
      @base_url = ENV["LLM_BASE_URL"] || "https://api.openai.com/v1"
      @model    = ENV["LLM_MODEL"]    || "gpt-4o-mini"
      @api_key  = ENV["LLM_API_KEY"]
    when "anthropic"
      @base_url = ENV["LLM_BASE_URL"] || "https://api.anthropic.com/v1"
      @model    = ENV["LLM_MODEL"]    || "claude-haiku-4-5"
      @api_key  = ENV["LLM_API_KEY"]
    else
      skip "Unknown LLM_PROVIDER=#{@provider.inspect}"
    end
  end

  # --------------------------------------------------------------------------
  # In-process MCP dispatch (real agent -> real Parse Server)
  # --------------------------------------------------------------------------

  def mcp_call(body, agent)
    Parse::Agent::MCPDispatcher.call(body: body, agent: agent)[:body]
  end

  def mcp_tools_to_openai(tools)
    tools.map do |t|
      # MCPDispatcher returns symbol-keyed descriptors in-process; JSON wire
      # format uses string keys. Accept both via transform_keys.
      h = t.transform_keys(&:to_s)
      {
        type: "function",
        function: {
          name:        h["name"],
          description: h["description"].to_s[0, 1024],
          parameters:  h["inputSchema"] || { "type" => "object", "properties" => {} },
        },
      }
    end
  end

  # --------------------------------------------------------------------------
  # LLM round-trip: prompt -> tool calls -> tool results -> final answer.
  # Iterates up to max_iterations to allow multi-step reasoning.
  # --------------------------------------------------------------------------

  def llm_round_trip(prompt:, tools:, agent:, max_iterations: 8)
    messages   = [{ role: "user", content: prompt }]
    transcript = []

    max_iterations.times do
      reply = call_llm(messages: messages, tools: tools)
      transcript << reply
      messages << { role: "assistant", content: reply[:content], tool_calls: reply[:tool_calls] }

      break if reply[:tool_calls].nil? || reply[:tool_calls].empty?

      reply[:tool_calls].each do |tc|
        body = {
          "jsonrpc" => "2.0",
          "id"      => SecureRandom.hex(4),
          "method"  => "tools/call",
          "params"  => { "name" => tc[:name], "arguments" => tc[:arguments] },
        }
        result    = mcp_call(body, agent)
        tool_text = if result["result"]
          result.dig("result", "content", 0, "text") || result["result"].to_json
        else
          result.dig("error", "message").to_s
        end
        messages << { role: "tool", tool_call_id: tc[:id], content: tool_text }
      end
    end

    transcript
  end

  def call_llm(messages:, tools:)
    case @provider
    when "anthropic" then anthropic_chat(messages: messages, tools: tools)
    else                  openai_chat(messages: messages, tools: tools)
    end
  end

  # --------------------------------------------------------------------------
  # OpenAI-compatible chat (also used by LM Studio)
  # --------------------------------------------------------------------------

  def openai_chat(messages:, tools:)
    openai_messages = messages.map do |m|
      case m[:role]
      when "user", "system"
        { role: m[:role], content: m[:content].to_s }
      when "assistant"
        out = { role: "assistant", content: m[:content] }
        if m[:tool_calls] && !m[:tool_calls].empty?
          out[:tool_calls] = m[:tool_calls].map do |tc|
            args_str = tc[:arguments].is_a?(String) ? tc[:arguments] : JSON.generate(tc[:arguments] || {})
            { id: tc[:id], type: "function", function: { name: tc[:name], arguments: args_str } }
          end
        end
        out
      when "tool"
        { role: "tool", tool_call_id: m[:tool_call_id], content: m[:content].to_s }
      end
    end.compact

    uri  = URI("#{@base_url}/chat/completions")
    body = JSON.generate({ model: @model, messages: openai_messages, tools: tools, tool_choice: "auto" })

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"]  = "application/json"
    req["Authorization"] = "Bearer #{@api_key}"
    req.body = body

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: 90) { |h| h.request(req) }
    skip "LLM call failed: HTTP #{res.code} #{res.body[0, 300]}" unless res.code.to_i.between?(200, 299)

    parsed = JSON.parse(res.body)
    msg    = parsed.dig("choices", 0, "message") || {}
    calls  = Array(msg["tool_calls"]).map do |tc|
      args = tc.dig("function", "arguments")
      args = JSON.parse(args) if args.is_a?(String) && !args.empty?
      { id: tc["id"] || SecureRandom.hex(4), name: tc.dig("function", "name"), arguments: args || {} }
    end
    { role: "assistant", content: msg["content"], tool_calls: calls }
  end

  # --------------------------------------------------------------------------
  # Anthropic chat
  # --------------------------------------------------------------------------

  def anthropic_chat(messages:, tools:)
    anth_tools    = tools.map { |t| { name: t[:function][:name], description: t[:function][:description], input_schema: t[:function][:parameters] } }
    anth_messages = messages.map do |m|
      case m[:role]
      when "user", "assistant" then { role: m[:role], content: m[:content].to_s }
      when "tool"              then { role: "user", content: [{ type: "tool_result", tool_use_id: m[:tool_call_id], content: m[:content] }] }
      end
    end.compact

    uri  = URI("#{@base_url}/messages")
    body = JSON.generate({ model: @model, max_tokens: 1024, tools: anth_tools, messages: anth_messages })

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"]      = "application/json"
    req["x-api-key"]         = @api_key
    req["anthropic-version"] = "2023-06-01"
    req.body = body

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: 90) { |h| h.request(req) }
    skip "Anthropic call failed: HTTP #{res.code} #{res.body[0, 300]}" unless res.code.to_i.between?(200, 299)

    parsed = JSON.parse(res.body)
    blocks = Array(parsed["content"])
    text   = blocks.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("\n")
    calls  = blocks.select { |b| b["type"] == "tool_use" }.map { |b| { id: b["id"], name: b["name"], arguments: b["input"] || {} } }
    { role: "assistant", content: text, tool_calls: calls }
  end
end
