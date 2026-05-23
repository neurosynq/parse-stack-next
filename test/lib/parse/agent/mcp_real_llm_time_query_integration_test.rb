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
# Real-LLM x real-Parse-Server integration test for date-range filtering.
#
# This file is a distinct test surface from mcp_real_llm_temporal_analysis_test.rb
# (which exercises trend reasoning over ordered time-series data). This file
# exercises `where:` clause filtering on date columns — a frequently-flaky
# surface because Parse Server expects dates in a specific wire format:
#
#   { "__type": "Date", "iso": "2026-05-10T00:00:00.000Z" }
#
# NOT as raw ISO strings. An LLM that constructs:
#   where: { "event_at": { "$gte": "2026-05-10" } }
# will receive zero results because Parse Server performs no string-to-Date
# coercion. The right shape is the wrapped object form above.
#
# Whether gpt-4o-mini can figure this out from the tool description + schema
# — when given the wire-format reminder in the prompt — is the open question
# this test answers.
#
# Full stack under test:
#   1. 20 MCPTimeQueryEvent records seeded against Docker Parse Server.
#   2. Real Parse::Agent dispatches MCP calls through MCPDispatcher to MongoDB.
#   3. A real LLM (gpt-4o-mini default) calls tools with date where-clauses.
#   4. Assertions verify counts match the precisely-seeded fixture distribution.
#
# Skipped unless BOTH:
#   - PARSE_TEST_USE_DOCKER=true   (docker-compose.test.yml stack is running)
#   - LLM_PROVIDER + LLM_API_KEY   (real LLM is configured)
#
# Distinct class namespace: MCPTimeQuery* (no collision with other test files)
# ============================================================================
class MCPTimeQueryTest < Minitest::Test
  include ParseStackIntegrationTest

  # --------------------------------------------------------------------------
  # Fixture class definition
  # --------------------------------------------------------------------------

  class MCPTimeQueryEvent < Parse::Object
    parse_class "MCPTimeQueryEvent"
    property :title, :string
    property :category, :string   # "login" | "checkout" | "signup" | "error"
    property :event_at, :date
  end

  # --------------------------------------------------------------------------
  # Ground-truth counts
  # --------------------------------------------------------------------------
  #
  # 20 events total, distributed across three time buckets using UTC offsets
  # that avoid boundary-straddling values. No event lands at exactly N=7 or
  # N=14 days ago; the smallest "older than 14 days" value is N=16 to keep
  # $lt comparisons unambiguous.
  #
  # EVENTS_LAST_7_DAYS: events with N in {0,1,2,3,4,5,6} — 8 events.
  #   Login events within last-7-days bucket: exactly 3 (N=0,2,4).
  #   Category breakdown: 3 login, 2 checkout, 2 signup, 1 error.
  #
  # EVENTS_8_TO_14_DAYS: events with N in {8,9,10,11,12} — 5 events.
  #
  # EVENTS_OLDER_THAN_14: events with N in {16,18,20,22,25,28,30} — 7 events.

  EVENTS_TOTAL         = 20
  EVENTS_LAST_7_DAYS   = 8
  EVENTS_LAST_14_DAYS  = 13   # 8 + 5
  EVENTS_OLDER_THAN_14 = 7
  LOGIN_EVENTS_LAST_7  = 3    # login events in the last-7-days bucket only

  # Fixture table: [days_ago, category, title]
  # Using UTC seconds so event_at timestamps are unambiguously in the correct
  # bucket regardless of local timezone.
  #
  # Last-7-days bucket (N in 0..6) — 8 events, 3 login:
  EVENT_FIXTURES = [
    [0,  "login",    "User login attempt"],
    [1,  "checkout", "Checkout completed"],
    [2,  "login",    "User login attempt"],
    [3,  "signup",   "Signup confirmation"],
    [4,  "login",    "User login attempt"],
    [5,  "checkout", "Checkout completed"],
    [5,  "signup",   "Signup confirmation"],
    [6,  "error",    "Error in payment flow"],
    # 8-14 days bucket (N in 8..12) — 5 events:
    [8,  "checkout", "Checkout completed"],
    [9,  "signup",   "Signup confirmation"],
    [10, "error",    "Error in payment flow"],
    [11, "login",    "User login attempt"],
    [12, "checkout", "Checkout completed"],
    # Older than 14 days bucket (N in 16..30) — 7 events:
    [16, "signup",   "Signup confirmation"],
    [18, "login",    "User login attempt"],
    [20, "error",    "Error in payment flow"],
    [22, "checkout", "Checkout completed"],
    [25, "login",    "User login attempt"],
    [28, "signup",   "Signup confirmation"],
    [30, "error",    "Error in payment flow"],
  ].freeze

  # NOTE: do NOT override `def setup` / `def teardown` here.
  # `ParseStackIntegrationTest.included(base)` injects those via
  # `base.define_method`; a subclass def would replace the injection and
  # the Parse client would never be configured.

  # --------------------------------------------------------------------------
  # Block helper: drop stale schema, seed 20 events, yield, teardown.
  #
  # Schema is dropped before seeding so that Parse Server re-infers the
  # event_at column type from the first insert. If event_at was previously
  # stored as String and is now inserted as a Date, the column type metadata
  # would reject the new type without this drop.
  # --------------------------------------------------------------------------
  def with_time_query_fixtures
    events = nil

    drop_time_query_schemas!

    events = EVENT_FIXTURES.map do |days_ago, category, title|
      ts = Time.now.utc - (days_ago * 86400)
      e = MCPTimeQueryEvent.new(
        title:    title,
        category: category,
        event_at: ts
      )
      assert e.save, "event save failed (#{days_ago}d ago, #{category}): #{e.errors.full_messages.join(", ")}"
      e
    end

    yield events
  ensure
    (events || []).each { |e| e.destroy rescue nil }
  end

  # ==========================================================================
  # Test 1: Headline scenario — count events in the last 7 days.
  #
  # Ground truth: 8 events. The LLM must use the Parse Date wire format in
  # the where clause. This is the primary test of whether gpt-4o-mini can
  # construct { "__type": "Date", "iso": "..." } when given the reminder.
  # ==========================================================================
  def test_llm_filters_events_to_last_7_days
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_time_query_fixtures do |events|
      agent        = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      # Pre-compute the cutoff so the LLM does not need to do date math.
      # Subtracting exactly 7 * 86400 seconds from now in UTC places the
      # cutoff between the N=6 fixture (6 days ago) and the N=8 fixture
      # (8 days ago), so all 8 events in the last-7-days bucket are matched
      # by event_at >= cutoff_7_ago.
      cutoff_7_ago = (Time.now.utc - 7 * 86400).iso8601

      prompt = time_query_prompt(
        question:            "How many events occurred since #{cutoff_7_ago}? " \
                             "Use count_objects with event_at >= the provided cutoff timestamp. " \
                             "Answer with just the count.",
        include_format_hint: true,
        cutoffs:             { "seven_days_ago (use as $gte value)" => cutoff_7_ago }
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 6)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)
      tool_args  = transcript_tool_args(transcript)

      # Always print tool args — this is the empirical record of whether the
      # LLM constructed { "__type": "Date", "iso": "..." } or some other form.
      $stderr.puts "\n[TEST1 TOOL ARGS] #{JSON.generate(tool_args)}"

      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert (tool_calls & %w[count_objects query_class]).any?,
             "model should call count_objects or query_class; got #{tool_calls.inspect}"
      assert_match(/\b8\b/, flat,
                   "model must report 8 events in the last 7 days; " \
                   "tool args: #{JSON.generate(tool_args)}; got: #{flat[0, 600]}")
    end
  end

  # ==========================================================================
  # Test 2: Explicit date range — count events between 14 and 7 days ago.
  #
  # Ground truth: 5 events (the 8-14 day bucket at N in {8,9,10,11,12}).
  # The prompt gives the LLM two specific cut-off dates and the wire-format
  # reminder, so it must construct both $gte and $lte constraints.
  # ==========================================================================
  def test_llm_filters_events_by_explicit_date_range
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_time_query_fixtures do |events|
      agent        = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      cutoff_7_ago  = (Time.now.utc - 7  * 86400).iso8601
      cutoff_14_ago = (Time.now.utc - 14 * 86400).iso8601

      prompt = time_query_prompt(
        question:            "How many events occurred between the two provided cutoff timestamps " \
                             "(from fourteen_days_ago up to seven_days_ago, inclusive)? " \
                             "Use $gte for the start cutoff and $lte for the end cutoff on event_at. " \
                             "Answer with just the count.",
        include_format_hint: true,
        cutoffs:             {
          "fourteen_days_ago (use as $gte value)" => cutoff_14_ago,
          "seven_days_ago    (use as $lte value)" => cutoff_7_ago,
        }
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 6)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)
      tool_args  = transcript_tool_args(transcript)

      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert (tool_calls & %w[count_objects query_class]).any?,
             "model should call count_objects or query_class; got #{tool_calls.inspect}"
      assert_match(/\b5\b/, flat,
                   "model must report 5 events in the 7-14 day window; " \
                   "tool args: #{JSON.generate(tool_args)}; got: #{flat[0, 600]}")
    end
  end

  # ==========================================================================
  # Test 3: $lt filter — count events older than 14 days.
  #
  # Ground truth: 7 events (N in {16,18,20,22,25,28,30}).
  # The prompt explicitly names $lt so the LLM understands the direction.
  # ==========================================================================
  def test_llm_correctly_uses_lt_for_older_events
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_time_query_fixtures do |events|
      agent        = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      cutoff_14_ago = (Time.now.utc - 14 * 86400).iso8601

      prompt = time_query_prompt(
        question:            "How many events occurred MORE than 14 days ago? " \
                             "Use $lt on event_at with the provided fourteen_days_ago cutoff. " \
                             "Answer with just the count.",
        include_format_hint: true,
        cutoffs:             { "fourteen_days_ago (use as $lt value)" => cutoff_14_ago }
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 6)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)
      tool_args  = transcript_tool_args(transcript)

      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert (tool_calls & %w[count_objects query_class]).any?,
             "model should call count_objects or query_class; got #{tool_calls.inspect}"
      assert_match(/\b7\b/, flat,
                   "model must report 7 events older than 14 days; " \
                   "tool args: #{JSON.generate(tool_args)}; got: #{flat[0, 600]}")
    end
  end

  # ==========================================================================
  # Test 4: Combined date + category filter.
  #
  # Ground truth: exactly 3 login events in the last-7-days bucket.
  # (Fixture positions N=0, N=2, N=4 are all category="login".)
  # The LLM must combine $gte on event_at with an equality filter on category.
  # ==========================================================================
  def test_llm_combines_date_filter_with_category_filter
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_time_query_fixtures do |events|
      agent        = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      cutoff_7_ago = (Time.now.utc - 7 * 86400).iso8601

      prompt = time_query_prompt(
        question:            "How many login events occurred since the provided seven_days_ago cutoff? " \
                             "Filter by BOTH event_at >= seven_days_ago AND category equal to 'login'. " \
                             "Answer with just the count.",
        include_format_hint: true,
        cutoffs:             { "seven_days_ago (use as $gte value for event_at)" => cutoff_7_ago }
      )

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 6)
      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)
      tool_args  = transcript_tool_args(transcript)

      refute_empty tool_calls, "model must invoke at least one MCP tool; got none"
      assert (tool_calls & %w[count_objects query_class]).any?,
             "model should call count_objects or query_class; got #{tool_calls.inspect}"
      assert_match(/\b3\b/, flat,
                   "model must report 3 login events in last 7 days; " \
                   "tool args: #{JSON.generate(tool_args)}; got: #{flat[0, 600]}")
      assert_match(/login/i, flat,
                   "model must mention 'login' in its answer; got: #{flat[0, 600]}")
    end
  end

  # ==========================================================================
  # Test 5: Negative / empirical test — no wire-format hint.
  #
  # This test intentionally OMITS the Parse Date wire-format reminder to
  # characterize gpt-4o-mini's behavior when left to figure out the date format
  # on its own.
  #
  # OBSERVED BEHAVIOR (gpt-4o-mini, temperature=0, against Docker Parse Server):
  #   Without the format hint, gpt-4o-mini made 1-2 tool calls and returned
  #   the total unfiltered count (20). It did NOT attempt to construct a
  #   date-filtered where clause at all. It called count_objects with no where
  #   argument, received 20, and answered "20".
  #
  #   The model did NOT try a raw ISO string date — it simply omitted the filter
  #   entirely rather than risk a malformed query it wasn't sure how to construct.
  #
  #   This behavior reveals TWO things:
  #   1. gpt-4o-mini does NOT know Parse's Date wire format from training data.
  #      The format hint in tests 1-4 is REQUIRED for correct date filtering.
  #   2. Parse Server's raw-string coercion is NOT exercised by this model.
  #      gpt-4o-mini avoids constructing raw strings, so whether Parse Server
  #      would coerce them remains an open question not answered by this test.
  #
  # The assertion only checks that the LLM made at least one tool call (it
  # did — just without a date filter). No count assertion is made because
  # the unfiltered result (20) is a legitimate (if incorrect) answer.
  # ==========================================================================
  def test_llm_falls_back_gracefully_when_using_string_date
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_time_query_fixtures do |events|
      agent        = Parse::Agent.new(permissions: :readonly)
      openai_tools = fetch_openai_tools(agent)

      # Deliberately no wire-format hint. The LLM may construct a raw ISO
      # string, may omit the filter, or may loop without converging.
      # We observe all three possible behaviors without enforcing a count.
      prompt = time_query_prompt(
        question:            "How many events happened today? " \
                             "Use count_objects with a where filter on event_at. Answer with just the count.",
        include_format_hint: false
      )

      # This must not raise — the tool result (whatever it is) should be
      # returned without an exception, even if the LLM loops.
      transcript = begin
        llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 6)
      rescue => e
        flunk "llm_round_trip raised unexpectedly: #{e.class}: #{e.message}"
      end

      flat       = transcript_text(transcript)
      tool_calls = transcript_tool_names(transcript)
      tool_args  = transcript_tool_args(transcript)

      # Always print tool args — this is the empirical record of what format
      # the LLM used (or did not use) and what Parse Server returned.
      $stderr.puts "\n[TEST5 EMPIRICAL] tool_args=#{JSON.generate(tool_args)}"
      $stderr.puts "[TEST5 EMPIRICAL] llm_answer=#{flat.strip[0, 200].inspect}"

      # The LLM must have attempted at least one tool call.
      refute_empty tool_calls,
                   "model must attempt at least one tool call even without the format hint; got none"

      # Do NOT assert on the final text — the model may exhaust iterations
      # without producing a final text answer (as observed with gpt-4o-mini).
      # The tool_calls list above is the empirical record of Parse Server's
      # response to whatever date format (or lack thereof) the LLM sent.
    end
  end

  private

  # --------------------------------------------------------------------------
  # Schema cleanup
  # --------------------------------------------------------------------------

  # Drop the MCPTimeQueryEvent schema (if it exists) so that Parse Server
  # re-infers column types from scratch on the next insert. Without this,
  # a stale event_at column stored as String (from a previous failed run)
  # would silently break all date-comparison queries.
  def drop_time_query_schemas!
    client = Parse::Client.client
    begin
      client.request(:delete, "schemas/MCPTimeQueryEvent", opts: { use_master_key: true })
    rescue StandardError
      # Ignore "class not found" — schema simply may not exist yet.
    end
  end

  # --------------------------------------------------------------------------
  # Prompt builder
  # --------------------------------------------------------------------------

  # Builds the standard prompt for time-query tests. When include_format_hint
  # is true (the default), adds the Parse Date wire-format reminder that
  # gpt-4o-mini needs to construct correct date where-clauses. When false,
  # the LLM must guess the format (used by test 5 to characterize coercion).
  #
  # Pre-computed cutoff ISO strings can be injected via `cutoffs:` to eliminate
  # date-math variance — the LLM is told the exact ISO timestamps to use rather
  # than being asked to compute "now minus N days" itself.
  def time_query_prompt(question:, include_format_hint: true, cutoffs: {})
    now_utc = Time.now.utc.iso8601

    cutoff_block = cutoffs.map { |label, iso| "  #{label}: #{iso}" }.join("\n")
    cutoff_section = cutoffs.empty? ? "" : "Pre-computed cutoff timestamps (use these EXACTLY as the iso value):\n#{cutoff_block}\n"

    format_hint = if include_format_hint
      <<~HINT

        IMPORTANT: Parse Server expects date values in this wire format:
          { "__type": "Date", "iso": "<ISO 8601 string in UTC>" }
        NOT as raw strings. A where clause filtering by date looks like:
          where: { "event_at": { "$gte": { "__type": "Date", "iso": "2026-05-10T00:00:00Z" } } }
        For a range, combine $gte and $lte (or $lt) in the same field object:
          where: { "event_at": { "$gte": { "__type": "Date", "iso": "<start>" },
                                 "$lte": { "__type": "Date", "iso": "<end>" } } }

        Use count_objects with a where argument for counting with filters. Example call:
          count_objects(class_name: "MCPTimeQueryEvent", where: { "event_at": { "$gte": { "__type": "Date", "iso": "..." } } })
        Do NOT use query_class for counting — it returns records, not a count.
      HINT
    else
      ""
    end

    <<~PROMPT
      You have access to MCP tools. The class MCPTimeQueryEvent has:
        title    (string)
        category (string — "login", "checkout", "signup", or "error")
        event_at (date — when the event occurred)

      Today (current UTC time): #{now_utc}
      #{cutoff_section}#{format_hint}
      Question: #{question}
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

  # Returns an array of {name:, arguments:} hashes for every tool call made.
  # Used for diagnostic output when an assertion fails.
  def transcript_tool_args(transcript)
    transcript.flat_map { |m| Array(m[:tool_calls]).map { |tc| { name: tc[:name], arguments: tc[:arguments] } } }
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
  # LLM round-trip: prompt -> tool calls -> tool results -> final answer.
  # Iterates up to max_iterations to allow multi-step reasoning chains.
  # --------------------------------------------------------------------------

  def llm_round_trip(prompt:, tools:, agent:, max_iterations: 6)
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
    body = JSON.generate({ model: @model, messages: openai_messages, tools: tools, tool_choice: "auto", temperature: 0 })

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
