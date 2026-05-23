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
# Real-LLM × real-Parse-Server integration test — statistical bias detection.
#
# Scenario: a school's grading dataset is seeded such that one teacher
# (Mr. Briggs) systematically scores female students ~30 points higher than
# male students, while the other two teachers grade both groups within 2
# points of each other.  The LLM must identify Briggs as the statistical
# outlier by grouping MCPBiasGrade records by teacher × student gender and
# comparing means.
#
# This exercises:
#   - Multi-class joins (grade → student for gender; grade → teacher for name)
#   - Group-by aggregation computed client-side after fetching with include:
#   - Comparison reasoning (which teacher's gap is anomalous)
#   - Synthesis (naming the outlier + quantifying the evidence)
#
# Gating:
#   PARSE_TEST_USE_DOCKER=true    — Dockerized Parse Server must be running
#   LLM_PROVIDER=openai           — real LLM provider
#   LLM_API_KEY=<key>             — API key for openai or anthropic
#
# The test is self-contained: all LLM-plumbing helpers are inline (copied
# from mcp_real_llm_docker_integration_test.rb) so no shared state with the
# other parallel test files.
# ============================================================================
class MCPBiasDetectionTest < Minitest::Test
  include ParseStackIntegrationTest

  # --------------------------------------------------------------------------
  # Parse class definitions  (MCPBias* namespace — no collision with peers)
  # --------------------------------------------------------------------------

  class MCPBiasStudent < Parse::Object
    parse_class "MCPBiasStudent"
    property :name,   :string
    property :gender, :string   # "F" | "M"
  end

  class MCPBiasTeacher < Parse::Object
    parse_class "MCPBiasTeacher"
    property :name, :string
  end

  class MCPBiasGrade < Parse::Object
    parse_class "MCPBiasGrade"
    property :score,      :integer   # 0–100
    property :assignment, :string    # e.g. "Midterm"
    belongs_to :student, as: :pointer, class_name: "MCPBiasStudent"
    belongs_to :teacher, as: :pointer, class_name: "MCPBiasTeacher"
  end

  # --------------------------------------------------------------------------
  # Fixture constants
  # --------------------------------------------------------------------------

  # Ground truth: Mr. Briggs is the biased teacher.
  # Female avg under Briggs:  (95 + 92 + 90) / 3 = 92.33
  # Male avg under Briggs:    (65 + 62 + 60) / 3 = 62.33  →  gap ≈ 30 pts
  #
  # Ms. Patel:  F avg 82.0,  M avg 81.0  →  gap  1 pt  (fair)
  # Mr. Romero: F avg 77.0,  M avg 78.0  →  gap  1 pt  (fair)
  BIASED_TEACHER = "Mr. Briggs"

  GRADES_BY_TEACHER = {
    "Ms. Patel"  => {
      "Ada"   => 84, "Bao"   => 80, "Cheng" => 82,
      "Diego" => 83, "Eli"   => 80, "Felix" => 80,
    },
    "Mr. Romero" => {
      "Ada"   => 78, "Bao"   => 76, "Cheng" => 77,
      "Diego" => 79, "Eli"   => 77, "Felix" => 78,
    },
    "Mr. Briggs" => {
      "Ada"   => 95, "Bao"   => 92, "Cheng" => 90,
      "Diego" => 65, "Eli"   => 62, "Felix" => 60,
    },
  }.freeze

  STUDENT_GENDERS = {
    "Ada"   => "F",
    "Bao"   => "F",
    "Cheng" => "F",
    "Diego" => "M",
    "Eli"   => "M",
    "Felix" => "M",
  }.freeze

  # --------------------------------------------------------------------------
  # Fixture helper
  # --------------------------------------------------------------------------

  # Seeds students + teachers first (independent of each other), then grades
  # (which need both).  Yields students, teachers, grades.  Teardown in
  # reverse order in ensure so a mid-seed failure still cleans up.
  def with_bias_fixtures
    students = []
    teachers = []
    grades   = []

    STUDENT_GENDERS.each do |sname, gender|
      s = MCPBiasStudent.new(name: sname, gender: gender)
      assert s.save, "MCPBiasStudent save failed for #{sname}: #{s.errors.full_messages.join(', ')}"
      students << s
    end
    students_by_name = students.each_with_object({}) { |s, h| h[s.name] = s }

    GRADES_BY_TEACHER.each_key do |tname|
      t = MCPBiasTeacher.new(name: tname)
      assert t.save, "MCPBiasTeacher save failed for #{tname}: #{t.errors.full_messages.join(', ')}"
      teachers << t
    end
    teachers_by_name = teachers.each_with_object({}) { |t, h| h[t.name] = t }

    GRADES_BY_TEACHER.each do |tname, scores|
      teacher = teachers_by_name.fetch(tname)
      scores.each do |sname, score|
        student = students_by_name.fetch(sname)
        g = MCPBiasGrade.new(
          score:      score,
          assignment: "Midterm",
          student:    student,
          teacher:    teacher
        )
        assert g.save, "MCPBiasGrade save failed (#{tname}/#{sname}): #{g.errors.full_messages.join(', ')}"
        grades << g
      end
    end

    yield students, teachers, grades
  ensure
    grades.each   { |g| g.destroy rescue nil }
    teachers.each { |t| t.destroy rescue nil }
    students.each { |s| s.destroy rescue nil }
  end

  # ==========================================================================
  # Test 1 — headline: LLM identifies the teacher with grading disparity
  # ==========================================================================
  def test_llm_identifies_teacher_with_gender_grading_disparity
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (openai | anthropic | lmstudio) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_bias_fixtures do |students, teachers, grades|
      agent        = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      prompt = build_bias_prompt(
        <<~QUESTION
          You are auditing grading fairness at a school.

          Question: Is there evidence that any teacher grades female and male
          students differently? If so, identify the teacher and quantify the
          disparity (mean score by gender).

          Steps:
            1. Call query_class on MCPBiasGrade with include: ["student","teacher"]
               so each grade row contains the student's gender field and the
               teacher's name field.
            2. Group the returned grades by teacher name, then by student gender
               ("F" or "M").
            3. Compute the mean score for "F" and for "M" within each teacher.
            4. Report which teacher shows the largest gap between female and male
               averages and state what that gap is.

          Use the tools — do not guess.
        QUESTION
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)

      assert_bias_analysis(
        transcript,
        must_include:     ["Briggs"],
        pattern:          /briggs/i
      )

      # LLM must have actually fetched data (not hallucinated)
      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert (tool_calls & %w[query_class aggregate]).any?,
             "model must call query_class or aggregate; got #{tool_calls.inspect}"

      # Must reference gender grouping — not just raw scores
      assert_match(/female|women|gender/i, flat,
                   "answer must reference gender grouping; got: #{flat[0, 800]}")

      # Gap evidence: either a numeric ≥ 20 OR explicit disparity language
      gap_found = flat.match?(/\b[2-9]\d\b/) ||
                  flat.match?(/gap|disparity/i) ||
                  (flat.match?(/higher|lower|more|less/i) && flat.match?(/female|women/i))
      assert gap_found,
             "answer must quantify or describe the gap; got: #{flat[0, 800]}"

      # Must NOT falsely accuse fair teachers
      refute_match(/\bPatel\b.{0,40}\b(bias|unfair|discriminat)/i, flat,
                   "must not accuse Ms. Patel of bias; got: #{flat[0, 800]}")
      refute_match(/\bRomero\b.{0,40}\b(bias|unfair|discriminat)/i, flat,
                   "must not accuse Mr. Romero of bias; got: #{flat[0, 800]}")
    end
  end

  # ==========================================================================
  # Test 2 — quantitative: LLM extracts specific group averages for Briggs
  # ==========================================================================
  def test_llm_provides_quantitative_evidence_for_disparity
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (openai | anthropic | lmstudio) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_bias_fixtures do |students, teachers, grades|
      agent        = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      prompt = build_bias_prompt(
        <<~QUESTION
          What is Mr. Briggs's average score for female students vs male students?

          Steps:
            1. Call query_class on MCPBiasTeacher where name is "Mr. Briggs" to
               get his objectId.
            2. Call query_class on MCPBiasGrade with:
               - where: { "teacher": { "__type": "Pointer", "className":
                 "MCPBiasTeacher", "objectId": "<briggs_id>" } }
               - include: ["student"]
               This returns all Briggs grades with each student's gender inline.
            3. Separate the grades into gender "F" and gender "M".
            4. Compute the mean score for each group and report both numbers.

          Expected answer format: "Mr. Briggs's female average is X and male
          average is Y."  Use the tools — do not guess.
        QUESTION
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)

      # Must have fetched data
      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert (tool_calls & %w[query_class aggregate get_object]).any?,
             "model must call a data-fetching tool; got #{tool_calls.inspect}"

      # Ground truth: female avg 92.33, male avg 62.33.
      # gpt-4o-mini may render 92.33, 92.3, ~92, or "approximately 92" — all
      # contain "92".  Same for 62.
      assert_match(/92/, flat,
                   "answer must report female avg ~92.33; got: #{flat[0, 800]}")
      assert_match(/62/, flat,
                   "answer must report male avg ~62.33; got: #{flat[0, 800]}")

      # Must identify both genders explicitly
      assert_match(/female|women/i, flat, "answer must mention female group; got: #{flat[0, 800]}")
      assert_match(/male|men/i,     flat, "answer must mention male group; got: #{flat[0, 800]}")
    end
  end

  # ==========================================================================
  # Test 3 — negative case: LLM identifies fair teachers without flagging Briggs
  # ==========================================================================
  def test_llm_does_not_falsely_flag_fair_teachers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (openai | anthropic | lmstudio) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_bias_fixtures do |students, teachers, grades|
      agent        = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      prompt = build_bias_prompt(
        <<~QUESTION
          Compute the average grade by gender for each of the three teachers.
          Report the teachers where the difference between the female average
          and the male average is less than 5 points (i.e., the teacher grades
          both genders about equally).

          Steps:
            1. Call query_class on MCPBiasGrade with include: ["student","teacher"]
               to get all 18 grade rows with gender and teacher name inline.
            2. Group by teacher name, then by student gender ("F" or "M").
            3. Compute mean score for each (teacher, gender) group.
            4. List only the teachers whose |female_avg - male_avg| < 5.

          Use the tools — do not guess.
        QUESTION
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)

      # Must have fetched data
      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert (tool_calls & %w[query_class aggregate]).any?,
             "model must call query_class or aggregate; got #{tool_calls.inspect}"

      # Fair teachers must appear in the answer
      assert_match(/Patel/i,  flat, "answer must include Ms. Patel as fair; got: #{flat[0, 800]}")
      assert_match(/Romero/i, flat, "answer must include Mr. Romero as fair; got: #{flat[0, 800]}")

      # Briggs must NOT be labelled fair — tightened to verb-adjacency so a
      # correct contrast sentence ("Briggs is not fair like Patel") doesn't
      # trigger a false positive.
      refute_match(/\bBriggs\b.{0,50}\b(is fair|grades fairly|grades equally|equal grading|no (significant )?disparity|no (significant )?gap)\b/i, flat,
                   "must not call Briggs a fair grader; got: #{flat[0, 800]}")
      refute_match(/\b(is fair|grades fairly|grades equally)\b.{0,50}\bBriggs\b/i, flat,
                   "must not call Briggs a fair grader (reversed); got: #{flat[0, 800]}")
    end
  end

  private

  # --------------------------------------------------------------------------
  # Prompt helper
  # --------------------------------------------------------------------------

  # Wraps a question with the schema preamble and pointer format so that each
  # test method reads cleanly without repeating boilerplate.
  def build_bias_prompt(question)
    <<~PROMPT
      You query a Parse database using MCP tools.

      Schema:
        MCPBiasStudent  fields: name (string), gender (string — values are exactly "F" or "M")
        MCPBiasTeacher  fields: name (string)
        MCPBiasGrade    fields: score (integer 0-100), assignment (string),
                                student (Pointer -> MCPBiasStudent),
                                teacher (Pointer -> MCPBiasTeacher)

      Pointer where-clause format — use this EXACT structure when filtering by pointer:
        { "<field>": { "__type": "Pointer", "className": "<ClassName>", "objectId": "<id>" } }

      To expand pointer fields inline, pass include: ["student"] or
      include: ["student","teacher"] to query_class.

      The aggregate tool supports MongoDB $group stages if you prefer server-side
      grouping, but query_class with include followed by client-side grouping is
      simpler and equally correct.

      #{question}
    PROMPT
  end

  # --------------------------------------------------------------------------
  # Shared assertion helper
  # --------------------------------------------------------------------------

  # Asserts common conditions across bias-analysis tests.
  #   must_include     — array of strings that must appear (case-insensitive)
  #   must_not_include — array of strings that must NOT appear (case-insensitive)
  #   pattern          — optional Regexp that flat text must match
  def assert_bias_analysis(transcript, must_include: [], must_not_include: [], pattern: nil)
    tool_calls = transcript_tool_names(transcript)
    flat       = transcript_text(transcript)

    refute_empty tool_calls, "model must invoke at least one MCP tool"
    assert (tool_calls & %w[query_class aggregate]).any?,
           "model must call query_class or aggregate; got #{tool_calls.inspect}"

    must_include.each do |s|
      assert flat.downcase.include?(s.downcase),
             "answer must include #{s.inspect}; got: #{flat[0, 800]}"
    end

    must_not_include.each do |s|
      refute flat.downcase.include?(s.downcase),
             "answer must NOT include #{s.inspect}; got: #{flat[0, 800]}"
    end

    if pattern
      assert_match pattern, flat,
                   "answer must match #{pattern.inspect}; got: #{flat[0, 800]}"
    end
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

  def mcp_call(body, agent)
    Parse::Agent::MCPDispatcher.call(body: body, agent: agent)[:body]
  end

  def mcp_tools_to_openai(tools)
    tools.map do |t|
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
  # LLM provider configuration
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
  # LLM round-trip (agentic tool-use loop)
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

  def anthropic_chat(messages:, tools:)
    anth_tools = tools.map do |t|
      { name: t[:function][:name], description: t[:function][:description], input_schema: t[:function][:parameters] }
    end
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
    text   = blocks.select { |b| b["type"] == "text" }.map  { |b| b["text"] }.join("\n")
    calls  = blocks.select { |b| b["type"] == "tool_use" }.map { |b| { id: b["id"], name: b["name"], arguments: b["input"] || {} } }
    { role: "assistant", content: text, tool_calls: calls }
  end
end
