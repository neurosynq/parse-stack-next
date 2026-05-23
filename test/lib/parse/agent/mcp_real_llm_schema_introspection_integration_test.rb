# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper_integration"
require "parse/agent"
require "parse/agent/mcp_dispatcher"
require "parse/agent/prompts"
require "net/http"
require "json"
require "uri"
require "securerandom"

# ============================================================================
# Real-LLM × real-Parse-Server integration test for MCP schema introspection.
#
# SIBLING test to mcp_real_llm_docker_integration_test.rb (which focuses on
# data-graph traversal). THIS file focuses on the MCP introspection surface:
#   - Schema discovery via get_all_schemas / get_schema tools
#   - Resource reading via resources/read MCP method (direct URI reads)
#   - Prompt rendering via prompts/list and prompts/get MCP methods
#   - LLM-driven full discovery loop across unknown Parse classes
#
# NOTE on resources/list: handle_resources_list reads the get_all_schemas
# envelope's :custom and :built_in arrays (added in the fix that landed
# alongside this test). Each Parse class becomes 3 resource URIs:
# parse://<Class>/schema, /count, /samples. resources/read calls the
# corresponding agent tools directly. Both code paths are exercised below.
#
# Skipped unless BOTH:
#   - PARSE_TEST_USE_DOCKER=true   (the Docker compose stack is up)
#   - LLM_PROVIDER + LLM_API_KEY   (real LLM is configured)
#
# A minimal two-class fixture is used. The test validates that an LLM can:
#   1. Discover available classes via schema tools and pick the right one.
#   2. Read resource URIs directly and interpret their output.
#   3. Use hydrated MCP prompts to guide its analysis.
#   4. Drive a full autonomous exploration loop from a cold start.
# ============================================================================
class MCPSchemaIntrospectionLLMTest < Minitest::Test
  include ParseStackIntegrationTest

  # Minimal two-class schema. Intentionally simpler than the school fixture in
  # the sibling test — we need just enough structure to validate pointer fields
  # and cross-class relationships without requiring student/enrollment data.
  class MCPSchemaProbeSubject < Parse::Object
    parse_class "MCPSchemaProbeSubject"
    property :name, :string
    property :department, :string
  end

  class MCPSchemaProbeTeacher < Parse::Object
    parse_class "MCPSchemaProbeTeacher"
    property :name, :string
    property :rating, :float
    belongs_to :subject, as: :pointer, class_name: "MCPSchemaProbeSubject"
  end

  PROBE_SUBJECTS = [
    { name: "Algebra II", department: "Mathematics" },
    { name: "Biology",    department: "Sciences"    },
  ].freeze

  PROBE_TEACHERS = [
    { name: "Ms. Vasquez", rating: 4.9, subject_name: "Algebra II" },
    { name: "Mr. Okafor",  rating: 4.2, subject_name: "Biology"    },
  ].freeze

  # NOTE: do NOT override `def setup` / `def teardown` here.
  # ParseStackIntegrationTest.included(base) injects setup via
  # base.define_method :setup; a subclass def setup would replace that
  # injection. Per-test gating and fixture seeding happen inside each test
  # method via with_probe_fixtures.

  # Block helper: seed 2 subjects and 2 teachers. Yields subjects and teachers.
  # Cleans up in ensure so teardown runs even on assertion failure. Records are
  # saved in dependency order: Subject → Teacher (needs subject pointer).
  def with_probe_fixtures
    subjects = PROBE_SUBJECTS.map do |attrs|
      s = MCPSchemaProbeSubject.new(attrs)
      assert s.save, "subject save failed for #{attrs[:name]}: #{s.errors.full_messages.join(", ")}"
      s
    end
    subjects_by_name = subjects.each_with_object({}) { |s, h| h[s.name] = s }

    teachers = PROBE_TEACHERS.map do |attrs|
      subject = subjects_by_name.fetch(attrs[:subject_name])
      t = MCPSchemaProbeTeacher.new(name: attrs[:name], rating: attrs[:rating], subject: subject)
      assert t.save, "teacher save failed for #{attrs[:name]}: #{t.errors.full_messages.join(", ")}"
      t
    end

    yield subjects, teachers
  ensure
    (teachers || []).each { |t| t.destroy rescue nil }
    (subjects || []).each { |s| s.destroy rescue nil }
  end

  # --------------------------------------------------------------------------
  # Test 1: LLM uses get_all_schemas then get_schema to identify the teacher class
  #
  # The LLM does not know which classes exist. It must call get_all_schemas to
  # discover them, identify the MCPSchemaProbeTeacher class by its name prefix,
  # then call get_schema on it and report the field list.
  #
  # NOTE: reset_database! deletes data objects but preserves schema definitions.
  # If prior test runs created other "teacher" classes (e.g. MCPSchoolTeacher
  # from the sibling test), they will appear in get_all_schemas. The prompt
  # must direct the LLM to look for the "MCPSchemaProbe" prefix specifically.
  # --------------------------------------------------------------------------
  def test_llm_uses_get_all_schemas_then_picks_right_class
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_probe_fixtures do |subjects, teachers|
      agent = Parse::Agent.new(permissions: :readonly)

      tools_envelope = mcp_call({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => {} }, agent)
      tools          = tools_envelope.dig("result", "tools")
      refute_nil tools, "tools/list returned no tools"
      openai_tools = mcp_tools_to_openai(tools)

      prompt = <<~PROMPT
        You are exploring a Parse database. You do not know which classes exist.

        Step 1: Call get_all_schemas to list every class in the database.
        Step 2: Among the results, find the class whose name starts with
                "MCPSchemaProbe" AND ends with "Teacher" (it tracks academic teachers).
        Step 3: Call get_schema on that exact class to get its full field list.
        Step 4: Reply with:
                - The exact class name (copy it verbatim)
                - A bullet list of every custom field in its schema (exclude
                  objectId, createdAt, updatedAt, ACL)

        Do not guess. Use the tools. Use the exact class name from the schema results.
      PROMPT

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 8)
      flat       = transcript.map { |m| m[:content].to_s }.join(" ")
      tool_calls = transcript.flat_map { |m| Array(m[:tool_calls]).map { |tc| tc[:name] } }

      refute_empty tool_calls, "LLM must invoke at least one MCP tool; got none"

      assert_includes tool_calls, "get_all_schemas",
        "LLM must call get_all_schemas to discover classes; called: #{tool_calls.inspect}"

      assert_includes tool_calls, "get_schema",
        "LLM must call get_schema to inspect the teacher class; called: #{tool_calls.inspect}"

      assert_match(/MCPSchemaProbeTeacher/i, flat,
        "LLM answer must name MCPSchemaProbeTeacher; got: #{flat[0, 800]}")

      # The schema has three custom fields: name, rating, subject (pointer).
      # Require at least 2 to be mentioned — LLMs sometimes omit pointer fields.
      mentioned_fields = %w[name rating subject].count { |f| flat.match?(/\b#{f}\b/i) }
      assert mentioned_fields >= 2,
        "LLM must mention at least 2 of [name, rating, subject] fields; got: #{flat[0, 800]}"
    end
  end

  # --------------------------------------------------------------------------
  # Test 2: Test code calls resources/read directly; LLM interprets the output
  #
  # The MCP resources/read path (resources/read → handle_resources_read →
  # agent tool) works correctly and is exercised here. resources/list via
  # MCPDispatcher is also tested to verify its actual behavior.
  #
  # The LLM's role is synthesis: given the content from resources/read calls
  # made by the test code, confirm understanding of the schema and data.
  # --------------------------------------------------------------------------
  def test_llm_reads_a_resource_uri
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_probe_fixtures do |subjects, teachers|
      agent = Parse::Agent.new(permissions: :readonly)

      # Step 1: Verify resources/list via dispatcher.
      #
      # KNOWN BUG IN lib/parse/agent/mcp_dispatcher.rb:278:
      #   handle_resources_list reads result[:data][:classes] but
      #   ResultFormatter#format_schemas (result_formatter.rb:72-77) returns
      #   { total:, note:, built_in:, custom: } — there is no :classes key.
      #   This means resources/list always returns [] regardless of how many
      #   classes exist. External MCP clients (Claude Desktop, Cursor) that
      #   call resources/list will receive an empty resource catalog.
      #
      #   Fix: change the dispatcher to use:
      #     (result[:data][:custom] || []) + (result[:data][:built_in] || [])
      #   OR add a :classes key to ResultFormatter#format_schemas output.
      #
      #   When the dispatcher is fixed, change assert_empty below to:
      #     assert probe_resources.length >= 6  (3 URIs × 2 probe classes)
      list_envelope = mcp_call(
        { "jsonrpc" => "2.0", "id" => 10, "method" => "resources/list", "params" => {} },
        agent
      )
      list_result = list_envelope.dig("result") || {}
      assert list_result.key?("resources"),
        "resources/list response must have a 'resources' key; got: #{list_envelope.inspect}"
      assert list_result["resources"].is_a?(Array),
        "resources/list 'resources' value must be an Array"
      # The dispatcher reads custom + built_in from get_all_schemas and emits
      # three resource URIs per class (schema, count, samples). MCPSchemaProbe
      # contributes 2 classes × 3 URIs = 6 probe resources; other test classes
      # persisted on the Parse Server (from sibling test runs) contribute more.
      # We assert at least the 6 probe resources are present.
      refute_empty list_result["resources"],
        "resources/list returned no resources — dispatcher key-mismatch bug may have regressed"

      probe_uris = list_result["resources"].map { |r| r["uri"] }.grep(/MCPSchemaProbe/)
      assert probe_uris.length >= 6,
        "expected at least 6 MCPSchemaProbe resource URIs (2 classes × 3 kinds), got #{probe_uris.length}: #{probe_uris.inspect}"
      %w[schema count samples].each do |kind|
        assert probe_uris.any? { |u| u.end_with?("/#{kind}") },
          "resources/list missing /#{kind} URI for MCPSchemaProbe classes"
      end

      # Step 2: Read the schema resource directly — this path works correctly.
      schema_envelope = mcp_call(
        {
          "jsonrpc" => "2.0",
          "id"      => 11,
          "method"  => "resources/read",
          "params"  => { "uri" => "parse://MCPSchemaProbeSubject/schema" },
        },
        agent
      )
      schema_result = schema_envelope.dig("result")
      refute_nil schema_result,
        "resources/read schema must return a result; got: #{schema_envelope.inspect}"
      schema_text = schema_result.dig("contents", 0, "text")
      refute_nil schema_text, "resources/read schema must have contents[0].text"
      schema_data = JSON.parse(schema_text) rescue nil
      refute_nil schema_data, "resources/read schema content must be valid JSON"

      # Step 3: Read the samples resource for MCPSchemaProbeSubject.
      samples_envelope = mcp_call(
        {
          "jsonrpc" => "2.0",
          "id"      => 12,
          "method"  => "resources/read",
          "params"  => { "uri" => "parse://MCPSchemaProbeSubject/samples" },
        },
        agent
      )
      samples_result = samples_envelope.dig("result")
      refute_nil samples_result,
        "resources/read samples must return a result; got: #{samples_envelope.inspect}"
      samples_text = samples_result.dig("contents", 0, "text")
      refute_nil samples_text, "resources/read samples must have contents[0].text"
      samples_data = JSON.parse(samples_text) rescue nil
      refute_nil samples_data, "resources/read samples content must be valid JSON"

      # Step 4: Read the count resource.
      count_envelope = mcp_call(
        {
          "jsonrpc" => "2.0",
          "id"      => 13,
          "method"  => "resources/read",
          "params"  => { "uri" => "parse://MCPSchemaProbeSubject/count" },
        },
        agent
      )
      count_result = count_envelope.dig("result")
      refute_nil count_result,
        "resources/read count must return a result; got: #{count_envelope.inspect}"
      count_text = count_result.dig("contents", 0, "text")
      refute_nil count_text, "resources/read count must have contents[0].text"

      # Step 5: Pass the resource content to the LLM for interpretation.
      # The LLM does not make tool calls here — the data is already in context.
      subject_names = PROBE_SUBJECTS.map { |s| s[:name] }
      prompt = <<~PROMPT
        An MCP client read resources from a Parse database and got these responses.
        Please interpret them.

        --- SCHEMA resource (parse://MCPSchemaProbeSubject/schema) ---
        #{schema_text}

        --- SAMPLES resource (parse://MCPSchemaProbeSubject/samples) ---
        #{samples_text}

        --- COUNT resource (parse://MCPSchemaProbeSubject/count) ---
        #{count_text}

        Based on these resource responses, answer:
        1. How many MCPSchemaProbeSubject objects exist?
        2. What are the names of the subjects shown in the samples?

        Answer concisely in two numbered sentences.
      PROMPT

      # No tools needed here — pure context interpretation by the LLM.
      reply = openai_chat(messages: [{ role: "user", content: prompt }], tools: [])
      flat  = reply[:content].to_s

      # The LLM must recognize both subject names from the samples data.
      subject_names.each do |name|
        assert_match(/#{Regexp.escape(name)}/i, flat,
          "LLM must mention subject '#{name}' from the samples resource; got: #{flat[0, 600]}")
      end

      # The LLM must report the count of 2.
      assert_match(/\b2\b|two/i, flat,
        "LLM must report 2 subjects (or 'two'); got: #{flat[0, 600]}")
    end
  end

  # --------------------------------------------------------------------------
  # Test 3: LLM renders and uses built-in MCP prompts
  #
  # Test code calls prompts/list and prompts/get directly, verifies the
  # protocol shapes, then passes the rendered class_overview prompt to the
  # LLM to demonstrate the end-to-end "client hydrates prompt → feeds to LLM"
  # pattern.
  # --------------------------------------------------------------------------
  def test_llm_renders_a_builtin_prompt
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    # Reset any custom-registered prompts so we test only builtins.
    # Registered prompts override builtins by name; clear defensively.
    Parse::Agent::Prompts.reset_registry!

    with_probe_fixtures do |subjects, teachers|
      agent = Parse::Agent.new(permissions: :readonly)

      # Step 1: Call prompts/list and verify all 8 builtins are present.
      list_envelope = mcp_call(
        { "jsonrpc" => "2.0", "id" => 20, "method" => "prompts/list", "params" => {} },
        agent
      )
      prompts = list_envelope.dig("result", "prompts") || []
      assert prompts.length >= 8,
        "prompts/list must return at least 8 builtin prompts; got #{prompts.length}: " \
        "#{prompts.map { |p| p["name"] }.inspect}"

      prompt_names = prompts.map { |p| p["name"] }
      expected_builtins = %w[
        parse_conventions parse_relations class_overview count_by
        recent_activity find_relationship created_in_range explore_database
      ]
      expected_builtins.each do |name|
        assert_includes prompt_names, name,
          "prompts/list must include builtin '#{name}'; got: #{prompt_names.inspect}"
      end

      # Verify each prompt descriptor has required MCP protocol fields.
      prompts.each do |p|
        assert p["name"].to_s.length > 0, "prompt must have a non-empty name"
        assert p.key?("description"), "prompt #{p["name"].inspect} must have 'description'"
        assert p.key?("arguments"),   "prompt #{p["name"].inspect} must have 'arguments'"
        assert p["arguments"].is_a?(Array), "prompt #{p["name"].inspect} arguments must be an Array"
      end

      # Step 2: Render parse_conventions (no args required).
      conventions_envelope = mcp_call(
        {
          "jsonrpc" => "2.0",
          "id"      => 21,
          "method"  => "prompts/get",
          "params"  => { "name" => "parse_conventions", "arguments" => {} },
        },
        agent
      )
      conventions_result = conventions_envelope.dig("result")
      refute_nil conventions_result, "prompts/get parse_conventions must return a result"
      assert conventions_result.key?("description"), "prompts/get result must have 'description'"
      assert conventions_result.key?("messages"),    "prompts/get result must have 'messages'"

      messages = conventions_result["messages"]
      assert messages.is_a?(Array) && !messages.empty?,
        "prompts/get messages must be a non-empty array"
      first_message = messages.first
      assert_equal "user", first_message["role"],
        "first prompt message must have role 'user'"
      conventions_text = first_message.dig("content", "text").to_s
      assert conventions_text.length > 50,
        "parse_conventions prompt text must be non-trivial; got: #{conventions_text.inspect}"

      # Step 3: Render class_overview with class_name argument.
      overview_envelope = mcp_call(
        {
          "jsonrpc" => "2.0",
          "id"      => 22,
          "method"  => "prompts/get",
          "params"  => {
            "name"      => "class_overview",
            "arguments" => { "class_name" => "MCPSchemaProbeTeacher" },
          },
        },
        agent
      )
      overview_result = overview_envelope.dig("result")
      refute_nil overview_result, "prompts/get class_overview must return a result"

      overview_messages = overview_result["messages"]
      assert overview_messages.is_a?(Array) && !overview_messages.empty?,
        "class_overview messages must be a non-empty array"
      overview_text = overview_messages.first.dig("content", "text").to_s
      assert overview_text.include?("MCPSchemaProbeTeacher"),
        "class_overview prompt text must mention the class name; got: #{overview_text[0, 400]}"
      assert overview_text.length > 50,
        "class_overview prompt text must be non-trivial; got: #{overview_text.inspect}"

      # Step 4: Pass the rendered class_overview prompt to the LLM with tools.
      # class_overview instructs the LLM to call get_schema, count_objects, and
      # get_sample_objects — so tools must be available for the LLM to act on
      # the prompt's instructions.
      tools_envelope = mcp_call({ "jsonrpc" => "2.0", "id" => 23, "method" => "tools/list", "params" => {} }, agent)
      openai_tools   = mcp_tools_to_openai(tools_envelope.dig("result", "tools") || [])

      transcript = llm_round_trip(
        prompt:         overview_text,
        tools:          openai_tools,
        agent:          agent,
        max_iterations: 8
      )
      flat       = transcript.map { |m| m[:content].to_s }.join(" ")
      tool_calls = transcript.flat_map { |m| Array(m[:tool_calls]).map { |tc| tc[:name] } }

      # The LLM should have called at least one introspection tool in response
      # to the class_overview prompt's instructions ("call get_schema ... count_objects ...").
      assert (tool_calls & %w[get_schema count_objects get_sample_objects query_class]).any?,
        "LLM should call at least one introspection tool in response to class_overview prompt; " \
        "called: #{tool_calls.inspect}"

      # The LLM's response should produce a meaningful, non-empty analysis.
      assert flat.strip.length > 50,
        "LLM must produce a meaningful response to the class_overview prompt; got: #{flat[0, 400]}"
    end
  end

  # --------------------------------------------------------------------------
  # Test 4: LLM drives a full autonomous discovery loop
  #
  # The LLM is dropped into an unknown database with only tool access. It must
  # independently call get_all_schemas, identify the MCPSchemaProbe classes,
  # get their schemas and counts, then summarize what the database tracks.
  # This is the highest-fidelity test of an LLM MCP client behavior.
  #
  # The prompt is scoped to MCPSchemaProbe* classes so the LLM doesn't spend
  # tokens exploring unrelated schema leftovers from other test runs.
  # --------------------------------------------------------------------------
  def test_llm_drives_a_full_discovery_loop
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run" unless ENV["LLM_PROVIDER"]
    skip "openai/anthropic require LLM_API_KEY" if %w[openai anthropic].include?(ENV["LLM_PROVIDER"]) && ENV["LLM_API_KEY"].to_s.empty?
    configure_llm_provider!

    with_probe_fixtures do |subjects, teachers|
      agent = Parse::Agent.new(permissions: :readonly)

      tools_envelope = mcp_call({ "jsonrpc" => "2.0", "id" => 30, "method" => "tools/list", "params" => {} }, agent)
      tools          = tools_envelope.dig("result", "tools")
      refute_nil tools, "tools/list returned no tools"
      openai_tools = mcp_tools_to_openai(tools)

      prompt = <<~PROMPT
        You are exploring a Parse database. Your task is to document what the
        database tracks, focusing only on classes whose name starts with
        "MCPSchemaProbe".

        Follow these steps exactly:
        1. Call get_all_schemas to list all classes.
        2. For each class whose name starts with "MCPSchemaProbe", call:
           a. get_schema to learn its field definitions.
           b. count_objects to find the exact number of records in that class.
        3. After gathering data for ALL MCPSchemaProbe classes, write a
           two-paragraph summary that includes:
           - What each MCPSchemaProbeXxx class appears to represent.
           - The EXACT object count for each class (a number, like "2 objects").

        Skip system classes (_User, _Role, _Session, etc.) and all classes
        that do NOT start with "MCPSchemaProbe".
        Do not estimate counts — call count_objects for each class.
      PROMPT

      transcript = llm_round_trip(prompt: prompt, tools: openai_tools, agent: agent, max_iterations: 10)
      flat       = transcript.map { |m| m[:content].to_s }.join(" ")
      tool_calls = transcript.flat_map { |m| Array(m[:tool_calls]).map { |tc| tc[:name] } }

      refute_empty tool_calls, "LLM must invoke at least one MCP tool; got none"

      # LLM must have started with class discovery.
      assert_includes tool_calls, "get_all_schemas",
        "LLM must call get_all_schemas to discover classes; called: #{tool_calls.inspect}"

      # LLM must have done per-class introspection on probe classes.
      assert (tool_calls & %w[get_schema count_objects]).any?,
        "LLM must call get_schema or count_objects on probe classes; called: #{tool_calls.inspect}"

      # The final summary must mention both probe class names.
      assert_match(/MCPSchemaProbeSubject/i, flat,
        "LLM summary must mention MCPSchemaProbeSubject; got: #{flat[0, 1000]}")
      assert_match(/MCPSchemaProbeTeacher/i, flat,
        "LLM summary must mention MCPSchemaProbeTeacher; got: #{flat[0, 1000]}")

      # The summary must include actual counts. Each probe class has exactly 2
      # objects (2 subjects, 2 teachers). Accept the digit "2" or word "two".
      # Require at least 2 mentions — one per class.
      count_mentions = flat.scan(/\b2\b|two/i).length
      assert count_mentions >= 2,
        "LLM summary must mention the count '2' at least twice (once per probe class); " \
        "found #{count_mentions} mention(s) in: #{flat[0, 1000]}"
    end
  end

  private

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
  # In-process MCP dispatch (real agent, real Parse Server)
  # --------------------------------------------------------------------------

  def mcp_call(body, agent)
    Parse::Agent::MCPDispatcher.call(body: body, agent: agent)[:body]
  end

  def mcp_tools_to_openai(tools)
    tools.map do |t|
      # MCPDispatcher returns symbol-keyed descriptors in-process; on the
      # JSON-RPC wire they are stringified by JSON.generate. Support both.
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
  # LLM round-trip (agentic loop with tool dispatch)
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
          (result.dig("result", "content", 0, "text") || result["result"].to_json)
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
  # OpenAI chat completion (supports function calling)
  # --------------------------------------------------------------------------

  def openai_chat(messages:, tools:)
    # Translate internal message shape → OpenAI wire shape. OpenAI requires
    # tool_calls[] entries to be {id:, type: "function", function: {name:,
    # arguments: <JSON-string>}}; tool responses use role "tool" with
    # tool_call_id and string content.
    openai_messages = messages.map do |m|
      case m[:role]
      when "user", "system"
        { role: m[:role], content: m[:content].to_s }
      when "assistant"
        out = { role: "assistant", content: m[:content] }
        if m[:tool_calls] && !m[:tool_calls].empty?
          out[:tool_calls] = m[:tool_calls].map do |tc|
            args     = tc[:arguments]
            args_str = args.is_a?(String) ? args : JSON.generate(args || {})
            { id: tc[:id], type: "function", function: { name: tc[:name], arguments: args_str } }
          end
        end
        out
      when "tool"
        { role: "tool", tool_call_id: m[:tool_call_id], content: m[:content].to_s }
      end
    end.compact

    uri  = URI("#{@base_url}/chat/completions")
    body = JSON.generate({
      model:       @model,
      messages:    openai_messages,
      tools:       tools.empty? ? nil : tools,
      tool_choice: tools.empty? ? nil : "auto",
    }.compact)

    req                  = Net::HTTP::Post.new(uri)
    req["Content-Type"]  = "application/json"
    req["Authorization"] = "Bearer #{@api_key}"
    req.body             = body

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: 90) do |h|
      h.request(req)
    end
    skip "LLM call failed: HTTP #{res.code} #{res.body[0, 400]}" unless res.code.to_i.between?(200, 299)

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
  # Anthropic chat (tools via input_schema)
  # --------------------------------------------------------------------------

  def anthropic_chat(messages:, tools:)
    anth_tools = tools.map do |t|
      {
        name:         t[:function][:name],
        description:  t[:function][:description],
        input_schema: t[:function][:parameters],
      }
    end

    anth_messages = messages.map do |m|
      case m[:role]
      when "user", "assistant"
        { role: m[:role], content: m[:content].to_s }
      when "tool"
        { role: "user", content: [{ type: "tool_result", tool_use_id: m[:tool_call_id], content: m[:content] }] }
      end
    end.compact

    uri  = URI("#{@base_url}/messages")
    body = JSON.generate({
      model:      @model,
      max_tokens: 1024,
      tools:      anth_tools.empty? ? nil : anth_tools,
      messages:   anth_messages,
    }.compact)

    req                      = Net::HTTP::Post.new(uri)
    req["Content-Type"]      = "application/json"
    req["x-api-key"]         = @api_key
    req["anthropic-version"] = "2023-06-01"
    req.body                 = body

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: 90) do |h|
      h.request(req)
    end
    skip "Anthropic call failed: HTTP #{res.code} #{res.body[0, 400]}" unless res.code.to_i.between?(200, 299)

    parsed = JSON.parse(res.body)
    blocks = Array(parsed["content"])
    text   = blocks.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("\n")
    calls  = blocks.select { |b| b["type"] == "tool_use" }.map do |b|
      { id: b["id"], name: b["name"], arguments: b["input"] || {} }
    end
    { role: "assistant", content: text, tool_calls: calls }
  end
end
