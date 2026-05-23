# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_dispatcher"

# ---------------------------------------------------------------------------
# Stub Parse::Agent for unit tests — no real Parse Server required.
# ---------------------------------------------------------------------------
class StubAgent
  STUB_TOOL_DEFS = [
    {
      "name"        => "query_class",
      "description" => "Query objects in a Parse class",
      "inputSchema" => { "type" => "object" },
    },
  ].freeze

  # progress_callback / cancellation_token accessors mirror the real
  # Parse::Agent surface so MCPDispatcher.call can install and clear
  # both through the `respond_to?` checks it uses in production.
  attr_accessor :progress_callback, :cancellation_token

  # cancelled? mirrors Parse::Agent#cancelled? so the dispatcher's
  # post-execute checkpoint behaves the same in the stub.
  def cancelled?
    !!@cancellation_token&.cancelled?
  end

  # Optional hook fired with the current progress_callback when execute
  # runs. Tests use this to verify the dispatcher installed the callback
  # before invoking the tool.
  attr_accessor :on_execute_capture_callback

  def tool_definitions(format: :mcp, category: nil)
    STUB_TOOL_DEFS
  end

  def execute(tool_name, **kwargs)
    @on_execute_capture_callback&.call(@progress_callback)
    case tool_name
    when :get_all_schemas
      { success: true, data: { classes: [
        { name: "Song",  description: "Music tracks", type: "Custom" },
        { name: "_User", description: "Auth users",   type: "System" },
      ] } }
    when :get_schema
      { success: true, data: { className: kwargs[:class_name], fields: {} } }
    when :count_objects
      { success: true, data: { count: 42 } }
    when :get_sample_objects
      { success: true, data: { results: [] } }
    when :query_class
      { success: true, data: { results: [{ "objectId" => "abc123" }] } }
    when :fail_tool
      { success: false, error: "Something went wrong in the tool" }
    else
      { success: false, error: "Unknown tool: #{tool_name}" }
    end
  end
end

class ErrorAgent < StubAgent
  def execute(tool_name, **kwargs)
    raise Parse::Agent::Unauthorized, "No token provided"
  end
end

class SecurityAgent < StubAgent
  def execute(tool_name, **kwargs)
    raise Parse::Agent::SecurityError, "Blocked operator $where"
  end
end

class ValidationAgent < StubAgent
  def execute(tool_name, **kwargs)
    raise Parse::Agent::ValidationError, "class_name is required"
  end
end

class StandardErrorAgent < StubAgent
  def execute(tool_name, **kwargs)
    raise RuntimeError, "Internal database connection failure details"
  end
end

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
class MCPDispatcherTest < Minitest::Test
  D = Parse::Agent::MCPDispatcher

  def setup
    @agent = StubAgent.new

    # Guard: mcp_rack_app_test.rb and mcp_streaming_test.rb both install
    # singleton-method stubs on MCPDispatcher.call at file-load time and restore
    # only in Minitest.after_run. When these files are loaded into the same
    # process (e.g. a "test all" rake task), the stub is active here and
    # would short-circuit every dispatch to a canned response. Restore the real
    # implementation for the duration of each dispatcher test.
    if defined?(MCPDispatcherStub) && MCPDispatcherStub.instance_variable_get(:@original_call)
      MCPDispatcherStub.restore!
      @mcp_stub_was_active = true
    else
      @mcp_stub_was_active = false
    end

    if defined?(StreamingDispatcherStub) && StreamingDispatcherStub.instance_variable_get(:@original)
      StreamingDispatcherStub.restore!
      @streaming_stub_was_active = true
    else
      @streaming_stub_was_active = false
    end

    # Register a custom test prompt using the real Prompts.register API.
    # This exercises the extension point and isolates tests from builtin changes.
    Parse::Agent::Prompts.register(
      name:        "test_prompt",
      description: "A test prompt",
      arguments:   [{ "name" => "class_name", "description" => "Parse class", "required" => true }],
      renderer:    lambda { |args|
        cn = args["class_name"].to_s
        raise Parse::Agent::ValidationError, "missing required argument: class_name" if cn.empty?
        "Describe the #{cn} Parse class."
      },
    )
  end

  def teardown
    Parse::Agent::Prompts.reset_registry!

    # Re-install each stub if it was active before setup, so the stub's owner
    # test class still sees it if it runs after us in the same process.
    if @mcp_stub_was_active && defined?(MCPDispatcherStub)
      MCPDispatcherStub.install!
    end
    if @streaming_stub_was_active && defined?(StreamingDispatcherStub)
      StreamingDispatcherStub.install!
    end
  end

  # ---------- initialize ----------------------------------------------------

  def test_initialize_returns_protocol_version
    body   = { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => {} }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    env = result[:body]
    assert_equal "2.0", env["jsonrpc"]
    assert_equal 1,     env["id"]
    assert_equal Parse::Agent::MCPDispatcher::PROTOCOL_VERSION, env["result"]["protocolVersion"]
    assert_equal "parse-stack-mcp", env["result"]["serverInfo"]["name"]
  end

  def test_protocol_version_constant_matches_mcp_server
    assert_equal "2025-06-18", Parse::Agent::MCPDispatcher::PROTOCOL_VERSION
  end

  def test_initialize_echoes_supported_client_protocol_version
    body = {
      "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
      "params"  => { "protocolVersion" => "2024-11-05" },
    }
    result = D.call(body: body, agent: @agent)
    assert_equal "2024-11-05", result[:body]["result"]["protocolVersion"],
                 "MCP lifecycle spec: server MUST echo client's requested protocolVersion when supported"
  end

  def test_initialize_falls_back_to_server_version_for_unsupported_client
    body = {
      "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
      "params"  => { "protocolVersion" => "1999-01-01" },
    }
    result = D.call(body: body, agent: @agent)
    assert_equal Parse::Agent::MCPDispatcher::PROTOCOL_VERSION,
                 result[:body]["result"]["protocolVersion"]
  end

  def test_initialize_uses_server_version_when_client_omits_protocol_version
    body = { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => {} }
    result = D.call(body: body, agent: @agent)
    assert_equal Parse::Agent::MCPDispatcher::PROTOCOL_VERSION,
                 result[:body]["result"]["protocolVersion"]
  end

  # ---------- dispatcher state lifecycle ------------------------------------

  def test_call_restores_prior_cancellation_token_in_ensure
    prev_token = Parse::Agent::CancellationToken.new
    @agent.cancellation_token = prev_token

    body = { "jsonrpc" => "2.0", "id" => 1, "method" => "ping" }
    D.call(body: body, agent: @agent, cancellation_token: Parse::Agent::CancellationToken.new)

    assert_same prev_token, @agent.cancellation_token,
                "Dispatcher ensure must restore the pre-existing cancellation_token, not null it"
  end

  def test_call_restores_prior_progress_callback_in_ensure
    prev_cb = ->(progress:, total: nil, message: nil) { :prior }
    @agent.progress_callback = prev_cb

    body = { "jsonrpc" => "2.0", "id" => 1, "method" => "ping" }
    D.call(body: body, agent: @agent, progress_callback: ->(**_) {})

    assert_same prev_cb, @agent.progress_callback,
                "Dispatcher ensure must restore the pre-existing progress_callback, not null it"
  end

  def test_call_clears_dispatcher_installed_state_when_no_prior_value
    body = { "jsonrpc" => "2.0", "id" => 1, "method" => "ping" }
    D.call(body: body, agent: @agent,
           cancellation_token: Parse::Agent::CancellationToken.new,
           progress_callback:  ->(**_) {})

    assert_nil @agent.cancellation_token
    assert_nil @agent.progress_callback
  end

  # ---------- notifications/* id rejection ----------------------------------

  def test_notifications_cancelled_with_id_returns_invalid_request_error
    body = {
      "jsonrpc" => "2.0", "id" => 42, "method" => "notifications/cancelled",
      "params"  => { "requestId" => 1 },
    }
    result = D.call(body: body, agent: @agent)
    assert_equal(-32600, result[:body]["error"]["code"])
    assert_match(/notifications must not carry an id/, result[:body]["error"]["message"])
  end

  def test_notifications_initialized_with_id_returns_invalid_request_error
    body = { "jsonrpc" => "2.0", "id" => 7, "method" => "notifications/initialized" }
    result = D.call(body: body, agent: @agent)
    assert_equal(-32600, result[:body]["error"]["code"])
  end

  def test_notifications_cancelled_without_id_remains_a_notification
    body = {
      "jsonrpc" => "2.0", "method" => "notifications/cancelled",
      "params"  => { "requestId" => 1 },
    }
    result = D.call(body: body, agent: @agent)
    assert_equal 200, result[:status]
    assert_nil result[:body], "Notifications with no id must produce no response body"
  end

  # ---------- ping ----------------------------------------------------------

  def test_ping_returns_empty_result
    body   = { "jsonrpc" => "2.0", "id" => 2, "method" => "ping" }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    assert_equal({}, result[:body]["result"])
    refute result[:body].key?("error")
  end

  # ---------- tools/list ----------------------------------------------------

  def test_tools_list_returns_agent_definitions
    body   = { "jsonrpc" => "2.0", "id" => 3, "method" => "tools/list", "params" => {} }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    tools = result[:body]["result"]["tools"]
    assert_instance_of Array, tools
    assert_equal "query_class", tools.first["name"]
  end

  # ---------- tools/call — success ------------------------------------------

  def test_tools_call_success_executes_tool_and_returns_content
    body = {
      "jsonrpc" => "2.0",
      "id"      => 4,
      "method"  => "tools/call",
      "params"  => { "name" => "query_class", "arguments" => { "class_name" => "Song" } },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    r = result[:body]["result"]
    assert_equal false, r["isError"]
    assert_equal "text", r["content"].first["type"]
    # Content text should contain the JSON-serialized data
    assert_includes r["content"].first["text"], "abc123"
  end

  # ---------- tools/call — tool-level failure (isError: true) ---------------

  def test_tools_call_tool_failure_returns_is_error_true_not_jsonrpc_error
    # Build an agent that always returns success:false from execute
    failing_agent = Class.new(StubAgent) do
      def execute(tool_name, **kwargs)
        { success: false, error: "Simulated tool failure" }
      end
    end.new

    body = {
      "jsonrpc" => "2.0",
      "id"      => 5,
      "method"  => "tools/call",
      "params"  => { "name" => "query_class", "arguments" => {} },
    }
    result = D.call(body: body, agent: failing_agent)

    assert_equal 200, result[:status]
    r = result[:body]["result"]
    # Must be a result envelope with isError: true, NOT a JSON-RPC error field
    assert_equal true, r["isError"]
    refute result[:body].key?("error"), "tool failure must not produce a JSON-RPC error field"
    assert_includes r["content"].first["text"], "Simulated tool failure"
  end

  # ---------- tools/call — missing tool name --------------------------------

  def test_tools_call_without_name_returns_invalid_params
    body = {
      "jsonrpc" => "2.0",
      "id"      => 6,
      "method"  => "tools/call",
      "params"  => { "arguments" => {} },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    assert_equal(-32602, result[:body]["error"]["code"])
  end

  # ---------- unknown method → -32601 and HTTP 200 --------------------------

  def test_unknown_method_returns_32601_with_http_200
    body   = { "jsonrpc" => "2.0", "id" => 7, "method" => "no_such_method/v99" }
    result = D.call(body: body, agent: @agent)

    # HTTP status must still be 200 for JSON-RPC error responses
    assert_equal 200, result[:status]
    err = result[:body]["error"]
    assert_equal(-32601, err["code"])
    assert_includes err["message"], "no_such_method/v99"
  end

  # ---------- malformed body → -32700 ---------------------------------------

  def test_missing_method_key_returns_32700
    body   = { "jsonrpc" => "2.0", "id" => 8 }  # no "method"
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    assert_equal(-32700, result[:body]["error"]["code"])
  end

  def test_non_hash_body_returns_32700_with_nil_id
    result = D.call(body: "not a hash", agent: @agent)

    assert_equal 200, result[:status]
    assert_equal(-32700, result[:body]["error"]["code"])
    assert_nil result[:body]["id"]
  end

  # ---------- Unauthorized → HTTP 401 + -32001 ------------------------------

  def test_unauthorized_error_returns_401
    body = {
      "jsonrpc" => "2.0",
      "id"      => 9,
      "method"  => "tools/call",
      "params"  => { "name" => "query_class", "arguments" => {} },
    }
    result = D.call(body: body, agent: ErrorAgent.new)

    assert_equal 401, result[:status]
    assert_equal(-32001, result[:body]["error"]["code"])
    assert_equal "Unauthorized", result[:body]["error"]["message"]
  end

  # ---------- SecurityError → HTTP 200 + -32602, no message leakage ---------

  def test_security_error_returns_32602_without_leaking_details
    body = {
      "jsonrpc" => "2.0",
      "id"      => 10,
      "method"  => "tools/call",
      "params"  => { "name" => "query_class", "arguments" => {} },
    }
    result = D.call(body: body, agent: SecurityAgent.new)

    assert_equal 200, result[:status]
    err = result[:body]["error"]
    assert_equal(-32602, err["code"])
    # The blocked operator detail must NOT appear in the message
    refute_includes err["message"].to_s, "where"
  end

  # ---------- StandardError → -32603 with sanitized "Internal error" --------

  def test_standard_error_returns_32603_with_sanitized_message
    body = {
      "jsonrpc" => "2.0",
      "id"      => 11,
      "method"  => "tools/call",
      "params"  => { "name" => "query_class", "arguments" => {} },
    }
    # Capture STDERR so the dispatcher's diagnostic warn line doesn't litter
    # test output. The class+message belong in operator logs, not on the wire.
    original_stderr = $stderr
    $stderr = StringIO.new
    begin
      result = D.call(body: body, agent: StandardErrorAgent.new)
    ensure
      $stderr = original_stderr
    end

    assert_equal 200, result[:status]
    err = result[:body]["error"]
    assert_equal(-32603, err["code"])
    # Body must NOT leak exception class name (gem fingerprinting) or details.
    assert_equal "Internal error", err["message"]
    refute_includes err["message"], "RuntimeError"
    refute_includes err["message"], "database connection failure details"
  end

  # ---------- resources/list ------------------------------------------------

  def test_resources_list_returns_three_resources_per_class
    body   = { "jsonrpc" => "2.0", "id" => 12, "method" => "resources/list", "params" => {} }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    resources = result[:body]["result"]["resources"]
    # StubAgent returns 2 classes; 3 resources each = 6
    assert_equal 6, resources.size
    uris = resources.map { |r| r["uri"] }
    assert_includes uris, "parse://Song/schema"
    assert_includes uris, "parse://Song/count"
    assert_includes uris, "parse://Song/samples"
  end

  # ---------- resources/templates/list (v4.2) -------------------------------

  def test_resources_templates_list_returns_three_templates
    body   = { "jsonrpc" => "2.0", "id" => 120, "method" => "resources/templates/list", "params" => {} }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    templates = result[:body]["result"]["resourceTemplates"]
    assert_equal 3, templates.size,
                 "Expected 3 URI templates (schema/count/samples), got #{templates.size}"

    uris = templates.map { |t| t["uriTemplate"] }
    assert_includes uris, "parse://{className}/schema"
    assert_includes uris, "parse://{className}/count"
    assert_includes uris, "parse://{className}/samples"

    templates.each do |t|
      assert t.key?("name"),        "every template must include a name"
      assert t.key?("description"), "every template must include a description"
      assert_equal "application/json", t["mimeType"]
    end
  end

  def test_resources_templates_list_does_not_require_agent_schema_access
    # Verify the handler doesn't call agent.execute(:get_all_schemas) — the
    # templates are server metadata, not derived from the agent's schema view.
    schema_calls = 0
    metrics_agent = Class.new(StubAgent) do
      define_method(:execute) do |tool_name, **kwargs|
        schema_calls += 1 if tool_name == :get_all_schemas
        super(tool_name, **kwargs)
      end
    end.new

    body = { "jsonrpc" => "2.0", "id" => 121, "method" => "resources/templates/list", "params" => {} }
    D.call(body: body, agent: metrics_agent)

    assert_equal 0, schema_calls,
                 "templates/list must not call get_all_schemas — templates are static server metadata"
  end

  # ---------- resources/read ------------------------------------------------

  def test_resources_read_schema_returns_contents
    body = {
      "jsonrpc" => "2.0",
      "id"      => 13,
      "method"  => "resources/read",
      "params"  => { "uri" => "parse://Song/schema" },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    contents = result[:body]["result"]["contents"]
    assert_equal 1, contents.size
    assert_equal "parse://Song/schema", contents.first["uri"]
    assert_equal "application/json", contents.first["mimeType"]
  end

  def test_resources_read_invalid_uri_returns_32602
    body = {
      "jsonrpc" => "2.0",
      "id"      => 14,
      "method"  => "resources/read",
      "params"  => { "uri" => "http://evil.com/../../etc/passwd" },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    assert_equal(-32602, result[:body]["error"]["code"])
  end

  # ---------- prompts/list --------------------------------------------------

  def test_prompts_list_delegates_to_prompts_module
    body   = { "jsonrpc" => "2.0", "id" => 15, "method" => "prompts/list", "params" => {} }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    prompts = result[:body]["result"]["prompts"]
    assert_instance_of Array, prompts
    # Our registered custom prompt must appear in the list.
    # Registered prompts are appended after builtins, so we check inclusion.
    prompt_names = prompts.map { |p| p["name"] }
    assert_includes prompt_names, "test_prompt", "registered test_prompt must appear in prompts list"
    # Builtins must also be present
    assert_includes prompt_names, "parse_conventions"
  end

  # ---------- prompts/get — success ----------------------------------------

  def test_prompts_get_renders_known_prompt
    body = {
      "jsonrpc" => "2.0",
      "id"      => 16,
      "method"  => "prompts/get",
      "params"  => { "name" => "test_prompt", "arguments" => { "class_name" => "Song" } },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    # Prompts.render returns the full MCP envelope; dispatcher passes it through as-is.
    r = result[:body]["result"]
    # description comes from Prompts.render (builtin or custom)
    assert_instance_of String, r["description"]
    # messages array with a user role entry
    assert_instance_of Array, r["messages"]
    msg = r["messages"].first
    assert_equal "user", msg["role"]
    # The rendered text should contain our class name
    assert_includes msg["content"]["text"], "Song"
  end

  # ---------- prompts/get — unknown prompt ----------------------------------

  def test_prompts_get_unknown_prompt_returns_32602
    body = {
      "jsonrpc" => "2.0",
      "id"      => 17,
      "method"  => "prompts/get",
      "params"  => { "name" => "no_such_prompt", "arguments" => {} },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    # Prompts.render raises ValidationError("Unknown prompt: no_such_prompt")
    # which dispatch maps to -32602 preserving the message.
    assert_equal(-32602, result[:body]["error"]["code"])
    assert_includes result[:body]["error"]["message"], "Unknown prompt"
  end

  # ---------- prompts/get — missing required argument -----------------------

  def test_prompts_get_missing_required_argument_returns_32602
    body = {
      "jsonrpc" => "2.0",
      "id"      => 18,
      "method"  => "prompts/get",
      "params"  => { "name" => "test_prompt", "arguments" => {} },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    assert_equal(-32602, result[:body]["error"]["code"])
    assert_includes result[:body]["error"]["message"], "class_name"
  end

  # ---------- prompts/get — size cap ----------------------------------------

  def test_prompts_get_oversized_renderer_returns_32602
    # Register a prompt whose renderer returns text exceeding the cap.
    Parse::Agent::Prompts.register(
      name:        "big_prompt",
      description: "A deliberately oversized prompt",
      arguments:   [],
      renderer:    lambda { |_args| "x" * (Parse::Agent::MCPDispatcher::MAX_TOOL_RESPONSE_BYTES + 1) },
    )

    body = {
      "jsonrpc" => "2.0",
      "id"      => 100,
      "method"  => "prompts/get",
      "params"  => { "name" => "big_prompt", "arguments" => {} },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    err = result[:body]["error"]
    assert_equal(-32602, err["code"])
    assert_includes err["message"], "Prompt output exceeded"
    assert_includes err["message"], Parse::Agent::MCPDispatcher::MAX_TOOL_RESPONSE_BYTES.to_s
    assert_includes err["message"], "tools, not prompts"
  end

  # ---------- progress_callback warn ----------------------------------------

  # progress_callback wiring (v4.2: now functional, no longer a reserved no-op)
  # ---------------------------------------------------------------------------

  def test_progress_callback_is_installed_on_agent_for_duration_of_call
    captured_during_call = nil

    cb = ->(*) {}

    @agent.on_execute_capture_callback = ->(installed) { captured_during_call = installed }

    D.call(
      body: {
        "jsonrpc" => "2.0", "id" => 200, "method" => "tools/call",
        "params"  => { "name" => "query_class", "arguments" => {} },
      },
      agent:             @agent,
      progress_callback: cb,
    )

    assert_same cb, captured_during_call,
                "Dispatcher must install progress_callback on the agent before the tool runs"
    assert_nil @agent.progress_callback,
               "Dispatcher must clear progress_callback from the agent after the tool returns"
  end

  def test_progress_callback_cleared_even_when_dispatch_raises
    cb = ->(*) {}

    # Force the dispatch path through an unknown method to take a normal
    # success-shaped exit, then verify the agent has been cleared.
    D.call(
      body:              { "jsonrpc" => "2.0", "id" => 201, "method" => "no_such_method" },
      agent:             @agent,
      progress_callback: cb,
    )

    assert_nil @agent.progress_callback,
               "progress_callback must be cleared after dispatch returns, including via ensure"
  end

  def test_no_progress_callback_leaves_agent_unchanged
    @agent.progress_callback = nil
    D.call(
      body:  { "jsonrpc" => "2.0", "id" => 202, "method" => "ping" },
      agent: @agent,
    )
    assert_nil @agent.progress_callback,
               "When no progress_callback is passed, the agent's progress_callback must remain nil"
  end

  # ---------- envelope structure --------------------------------------------

  def test_response_always_has_jsonrpc_and_id_keys
    body   = { "jsonrpc" => "2.0", "id" => "req-abc", "method" => "ping" }
    result = D.call(body: body, agent: @agent)

    env = result[:body]
    assert env.key?("jsonrpc"), "envelope must have jsonrpc key"
    assert env.key?("id"),      "envelope must have id key"
    assert_equal "2.0",       env["jsonrpc"]
    assert_equal "req-abc",   env["id"]
  end

  def test_successful_response_has_result_not_error
    body   = { "jsonrpc" => "2.0", "id" => 19, "method" => "ping" }
    result = D.call(body: body, agent: @agent)

    assert result[:body].key?("result"), "success must have result key"
    refute result[:body].key?("error"),  "success must not have error key"
  end

  # ---------- cancellation (v4.2) -------------------------------------------

  def test_cancellation_token_is_installed_and_cleared
    token = Parse::Agent::CancellationToken.new
    captured = nil
    @agent.on_execute_capture_callback = ->(_) { captured = @agent.cancellation_token }

    D.call(
      body: {
        "jsonrpc" => "2.0", "id" => 300, "method" => "tools/call",
        "params"  => { "name" => "query_class", "arguments" => {} },
      },
      agent:              @agent,
      cancellation_token: token,
    )

    assert_same token, captured,
                "Dispatcher must install cancellation_token on the agent before the tool runs"
    assert_nil @agent.cancellation_token,
               "Dispatcher must clear cancellation_token from the agent after the tool returns"
  end

  def test_cancelled_tool_result_translates_to_iserror_content
    # Agent stub returns a cancelled-shaped envelope.
    cancelled_agent = Class.new(StubAgent) do
      def execute(_tool_name, **)
        { success: false, error: "Cancelled by client", cancelled: true }
      end
    end.new

    body = {
      "jsonrpc" => "2.0", "id" => 301, "method" => "tools/call",
      "params"  => { "name" => "query_class", "arguments" => {} },
    }
    result = D.call(body: body, agent: cancelled_agent)

    assert_equal 200, result[:status]
    content_result = result[:body]["result"]
    refute_nil content_result, "Cancelled tools still produce a JSON-RPC result envelope (not an error envelope)"
    assert_equal true, content_result["isError"]
    assert_equal true, content_result["cancelled"]
    assert content_result["content"].first["text"].include?("Cancelled by client")
  end

  def test_notifications_initialized_returns_no_response_body
    body = {
      "jsonrpc" => "2.0",
      "method"  => "notifications/initialized",
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    assert_nil result[:body],
               "notifications/initialized is a JSON-RPC notification — no response body"
  end

  def test_capability_advertises_tools_and_prompts_list_changed
    body = {
      "jsonrpc" => "2.0", "id" => 30, "method" => "initialize", "params" => {},
    }
    result = D.call(body: body, agent: @agent)
    caps   = result[:body]["result"]["capabilities"]

    assert_equal true,  caps["tools"]["listChanged"]
    assert_equal true,  caps["prompts"]["listChanged"]
    assert_equal false, caps["resources"]["listChanged"]
  end

  def test_registered_tool_with_output_schema_emits_structuredContent
    Parse::Agent::Tools.register(
      name:          :__test_structured_tool,
      description:   "tool that returns structured data",
      parameters:    { "type" => "object", "properties" => {} },
      permission:    :readonly,
      output_schema: { "type" => "object", "properties" => { "count" => { "type" => "integer" } } },
      handler:       ->(_a, **) { { count: 42, label: "answer" } },
    )

    structured_agent = Class.new(StubAgent) do
      def execute(tool_name, **_)
        if tool_name == :__test_structured_tool
          # Mirror what Parse::Agent#execute does: wrap handler return.
          data = Parse::Agent::Tools.invoke(self, tool_name)
          { success: true, data: data }
        else
          super
        end
      end
    end.new

    body = {
      "jsonrpc" => "2.0", "id" => 31, "method" => "tools/call",
      "params"  => { "name" => "__test_structured_tool", "arguments" => {} },
    }
    result = D.call(body: body, agent: structured_agent)

    content_result = result[:body]["result"]
    refute content_result["isError"]
    structured = content_result["structuredContent"]
    refute_nil structured, "structuredContent must be present when tool declared outputSchema"
    assert_equal 42, structured[:count]
    assert_equal "answer", structured[:label]

    text_block = content_result["content"].first
    assert_equal "text", text_block["type"]
    assert text_block["text"].include?("42"),
           "text content should still serialize the data for clients that ignore structuredContent"
  ensure
    Parse::Agent::Tools.reset_registry!
  end

  def test_registered_tool_without_output_schema_omits_structuredContent
    Parse::Agent::Tools.register(
      name:        :__test_plain_tool,
      description: "tool without an output schema",
      parameters:  { "type" => "object", "properties" => {} },
      permission:  :readonly,
      handler:     ->(_a, **) { { count: 1 } },
    )

    plain_agent = Class.new(StubAgent) do
      def execute(tool_name, **_)
        if tool_name == :__test_plain_tool
          data = Parse::Agent::Tools.invoke(self, tool_name)
          { success: true, data: data }
        else
          super
        end
      end
    end.new

    body = {
      "jsonrpc" => "2.0", "id" => 32, "method" => "tools/call",
      "params"  => { "name" => "__test_plain_tool", "arguments" => {} },
    }
    result = D.call(body: body, agent: plain_agent)

    content_result = result[:body]["result"]
    refute content_result.key?("structuredContent"),
           "structuredContent must be omitted when no outputSchema was declared"
  ensure
    Parse::Agent::Tools.reset_registry!
  end

  def test_tools_list_includes_outputSchema_when_declared
    Parse::Agent::Tools.register(
      name:          :__test_with_output_schema,
      description:   "tool with output schema",
      parameters:    { "type" => "object", "properties" => {} },
      permission:    :readonly,
      output_schema: { "type" => "object", "properties" => { "ok" => { "type" => "boolean" } } },
      handler:       ->(_a, **) { { ok: true } },
    )

    # StubAgent's tool_definitions hard-codes a list, so use a thin
    # subclass that pulls from the real definitions surface.
    real_defs_agent = Class.new(StubAgent) do
      def tool_definitions(format: :mcp, category: nil)
        Parse::Agent::Tools.definitions([:__test_with_output_schema], format: format, category: category)
      end
    end.new

    body = { "jsonrpc" => "2.0", "id" => 33, "method" => "tools/list", "params" => {} }
    result = D.call(body: body, agent: real_defs_agent)

    tools = result[:body]["result"]["tools"]
    refute_nil tools
    assert_equal 1, tools.size
    assert tools.first.key?(:outputSchema),
           "MCP tool definition must include outputSchema when declared"
    assert_equal "boolean", tools.first[:outputSchema]["properties"]["ok"]["type"]
  ensure
    Parse::Agent::Tools.reset_registry!
  end

  # Built-in tools (count_objects, get_object, get_objects, get_sample_objects,
  # distinct, group_by, group_by_date, list_tools, get_all_schemas, get_schema,
  # query_class) declare an `output_schema` in TOOL_DEFINITIONS so the
  # dispatcher mirrors their result data into `structuredContent` per
  # MCP 2025-06-18. Tools.output_schema_for falls through to TOOL_DEFINITIONS
  # when the registered-overlay misses.
  def test_builtin_tools_declare_output_schemas
    %i[count_objects get_object get_objects get_sample_objects
       distinct group_by group_by_date list_tools
       get_all_schemas get_schema query_class].each do |tool|
      schema = Parse::Agent::Tools.output_schema_for(tool)
      refute_nil schema,
                 "built-in tool #{tool} should carry an outputSchema for MCP structuredContent"
      assert_equal "object", schema[:type] || schema["type"],
                   "built-in tool #{tool} outputSchema must be a JSON object schema"
    end
  end

  def test_builtin_count_objects_emits_structuredContent
    body = {
      "jsonrpc" => "2.0", "id" => 100, "method" => "tools/call",
      "params"  => { "name" => "count_objects", "arguments" => { "class_name" => "Song" } },
    }
    result = D.call(body: body, agent: @agent)

    content_result = result[:body]["result"]
    refute content_result["isError"], "expected non-error tools/call result"
    refute_nil content_result["structuredContent"],
               "count_objects must mirror its result Hash as structuredContent"
    structured = content_result["structuredContent"]
    assert_equal 42, structured[:count] || structured["count"]
  end

  def test_builtin_get_all_schemas_emits_structuredContent
    body = {
      "jsonrpc" => "2.0", "id" => 110, "method" => "tools/call",
      "params"  => { "name" => "get_all_schemas", "arguments" => {} },
    }
    result = D.call(body: body, agent: @agent)

    content_result = result[:body]["result"]
    refute content_result["isError"], "expected non-error tools/call result"
    structured = content_result["structuredContent"]
    refute_nil structured,
               "get_all_schemas must mirror its result Hash as structuredContent"
    classes = structured[:classes] || structured["classes"]
    refute_nil classes, "get_all_schemas structuredContent must carry the class catalog"
  end

  def test_builtin_get_schema_emits_structuredContent
    body = {
      "jsonrpc" => "2.0", "id" => 111, "method" => "tools/call",
      "params"  => { "name" => "get_schema", "arguments" => { "class_name" => "Song" } },
    }
    result = D.call(body: body, agent: @agent)

    content_result = result[:body]["result"]
    refute content_result["isError"], "expected non-error tools/call result"
    structured = content_result["structuredContent"]
    refute_nil structured,
               "get_schema must mirror its result Hash as structuredContent"
    assert_equal "Song", structured[:className] || structured["className"]
  end

  # query_class declares a permissive-superset outputSchema covering both
  # the JSON row envelope (results, pagination, ...) and the text envelope
  # (format, headers, output, row_count) so clients disambiguate via the
  # presence of `format`. Exercise both shapes through the dispatcher to
  # prove structuredContent flows transparently in both cases.
  def test_builtin_query_class_emits_structuredContent_json_envelope
    body = {
      "jsonrpc" => "2.0", "id" => 112, "method" => "tools/call",
      "params"  => {
        "name"      => "query_class",
        "arguments" => { "class_name" => "Song" },
      },
    }
    result = D.call(body: body, agent: @agent)

    content_result = result[:body]["result"]
    refute content_result["isError"], "expected non-error tools/call result"
    structured = content_result["structuredContent"]
    refute_nil structured,
               "query_class (json envelope) must mirror its result Hash as structuredContent"
    results = structured[:results] || structured["results"]
    refute_nil results, "json-envelope structuredContent must carry :results"
    assert_equal "abc123", results.first["objectId"] || results.first[:objectId]
  end

  def test_builtin_query_class_emits_structuredContent_text_envelope
    text_agent = Class.new(StubAgent) do
      def execute(tool_name, **kwargs)
        return super unless tool_name == :query_class
        { success: true, data: {
          class_name: kwargs[:class_name],
          format:     "csv",
          headers:    %w[objectId title],
          row_count:  1,
          output:     "objectId,title\nabc123,Hello\n",
        } }
      end
    end.new

    body = {
      "jsonrpc" => "2.0", "id" => 113, "method" => "tools/call",
      "params"  => {
        "name"      => "query_class",
        "arguments" => { "class_name" => "Song", "format" => "csv" },
      },
    }
    result = D.call(body: body, agent: text_agent)

    content_result = result[:body]["result"]
    refute content_result["isError"], "expected non-error tools/call result"
    structured = content_result["structuredContent"]
    refute_nil structured,
               "query_class (text envelope) must mirror its result Hash as structuredContent"
    assert_equal "csv", structured[:format] || structured["format"]
    refute_nil structured[:output] || structured["output"],
               "text-envelope structuredContent must carry :output"
  end

  def test_builtin_tools_list_advertises_outputSchema
    real_defs_agent = Class.new(StubAgent) do
      def tool_definitions(format: :mcp, category: nil)
        Parse::Agent::Tools.definitions(
          %i[count_objects get_object get_sample_objects distinct],
          format: format, category: category,
        )
      end
    end.new

    body = { "jsonrpc" => "2.0", "id" => 101, "method" => "tools/list", "params" => {} }
    result = D.call(body: body, agent: real_defs_agent)

    tools = result[:body]["result"]["tools"]
    assert_equal 4, tools.size
    tools.each do |t|
      assert t.key?(:outputSchema),
             "built-in tool #{t[:name]} must surface outputSchema on tools/list"
    end
  end

  def test_notifications_cancelled_returns_no_response_body
    body = {
      "jsonrpc" => "2.0",
      "method"  => "notifications/cancelled",
      "params"  => { "requestId" => 42 },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    assert_nil result[:body],
               "JSON-RPC notifications must have no response body (transport writes empty)"
  end

  # Drives the REAL Parse::Agent#execute (not StubAgent) to catch
  # bugs the agent-side checkpoint cannot find with a stub. Specifically
  # regression-tests the bare-`next` bug fix in checkpoint #2 — a tripped
  # token mid-flight must produce a cancelled response, not nil.
  def test_real_agent_execute_returns_cancelled_envelope_when_token_tripped_before_run
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse", application_id: "x", api_key: "y")
    end
    real_agent = Parse::Agent.new(permissions: :readonly)
    token = Parse::Agent::CancellationToken.new
    real_agent.cancellation_token = token
    token.cancel!(reason: :test)

    result = real_agent.execute(:get_all_schemas)

    refute_nil result,        "execute must return a hash, never nil"
    assert_equal false, result[:success]
    assert_equal true,  result[:cancelled],
                        "Pre-run cancellation must yield cancelled: true"
    assert_equal :cancelled, result[:error_code]
  ensure
    real_agent.cancellation_token = nil if real_agent
  end

  def test_real_agent_execute_returns_cancelled_envelope_when_token_tripped_mid_flight
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse", application_id: "x", api_key: "y")
    end
    real_agent = Parse::Agent.new(permissions: :readonly)
    token = Parse::Agent::CancellationToken.new
    real_agent.cancellation_token = token

    # Register a custom tool that runs to completion but trips the token
    # during its body — simulates "tool's blocking I/O finished, but the
    # client cancelled while it was running."
    Parse::Agent::Tools.register(
      name:        :__test_mid_flight_cancel,
      description: "test tool that trips the token mid-execution",
      parameters:  { "type" => "object", "properties" => {}, "additionalProperties" => false },
      permission:  :readonly,
      handler:     ->(_agent, **_) {
        token.cancel!(reason: :test)
        { tool_finished: true }   # tool itself returns success
      },
    )

    result = real_agent.execute(:__test_mid_flight_cancel)

    refute_nil result, "execute must return a hash, never nil (regression of bare-next bug)"
    assert_equal false, result[:success]
    assert_equal true,  result[:cancelled],
                        "Post-run cancellation must yield cancelled: true"
    assert_equal :cancelled, result[:error_code]
  ensure
    Parse::Agent::Tools.reset_registry!
    real_agent.cancellation_token = nil if real_agent
  end
end
