# encoding: UTF-8
# frozen_string_literal: true

require "stringio"
require "json"
require_relative "../../../test_helper"
require "parse/agent/prompts"
require "parse/agent/mcp_dispatcher"
require "parse/agent/mcp_rack_app"
require "parse/agent/mcp_server"

# ---------------------------------------------------------------------------
# MCPIntegrationTest — end-to-end tests from Rack env through to JSON response.
#
# These tests exercise the full MCP stack:
#   MCPRackApp (transport) → MCPDispatcher (protocol) → Parse::Agent (tools)
#
# No Docker or live Parse Server is required. Tool execution is stubbed at the
# Parse::Agent#execute boundary so network calls never happen. Everything above
# that boundary (Rack env parsing, JSON-RPC dispatch, prompt rendering) is real.
# ---------------------------------------------------------------------------
class MCPIntegrationTest < Minitest::Test
  # --------------------------------------------------------------------------
  # Setup / Teardown
  # --------------------------------------------------------------------------

  def setup
    # Configure a minimal Parse client so Parse::Agent.new doesn't raise.
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key:        "test-api-key",
      )
    end

    # Always start each test with a clean prompt registry so custom-prompt
    # tests don't bleed into each other.
    Parse::Agent::Prompts.reset_registry!

    # Guard: mcp_rack_app_test.rb installs a stub on MCPDispatcher.call at
    # file-load time and restores it only in Minitest.after_run. If both files
    # are loaded into the same process (e.g. rake test:unit), the stub is active
    # here. Restore the real implementation for the duration of each integration
    # test so we exercise the actual dispatcher.
    if defined?(MCPDispatcherStub) && MCPDispatcherStub.instance_variable_get(:@original_call)
      MCPDispatcherStub.restore!
      @mcp_stub_was_active = true
    else
      @mcp_stub_was_active = false
    end

  end

  def teardown
    Parse::Agent::Prompts.reset_registry!

    # Re-install the rack-app stub if it was active before setup, so that any
    # MCPRackAppTest tests that run after us in the same process still see it.
    if @mcp_stub_was_active && defined?(MCPDispatcherStub)
      MCPDispatcherStub.install!
    end
  end

  # --------------------------------------------------------------------------
  # Helper: build a Rack env and call MCPRackApp, returning [status, hdrs, body]
  # --------------------------------------------------------------------------

  # @param body     [Hash, String]  request body; Hashes are JSON-encoded
  # @param agent_factory [Proc]     factory called with the Rack env
  # @param headers  [Hash]          extra Rack env keys (override defaults)
  # @param max_body_size [Integer, nil]  pass to MCPRackApp when non-nil
  # @return [Array(Integer, Hash, Hash)]  [status, headers, parsed_body]
  def post_mcp(body, agent_factory:, headers: {}, max_body_size: nil)
    raw = body.is_a?(String) ? body : JSON.generate(body)
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE"   => "application/json",
      "rack.input"     => StringIO.new(raw),
      "rack.errors"    => $stderr,
    }.merge(headers)

    kwargs = { agent_factory: agent_factory }
    kwargs[:max_body_size] = max_body_size if max_body_size

    app    = Parse::Agent::MCPRackApp.new(**kwargs)
    status, hdrs, chunks = app.call(env)
    parsed = JSON.parse(chunks.join)
    [status, hdrs, parsed]
  end

  # Build an agent whose #execute method returns canned data without hitting
  # Parse Server. The stub mirrors agent.rb's rate-limiter contract so that
  # injected rate-limiters are exercised correctly.
  def stubbed_agent(rate_limiter: nil)
    agent = if rate_limiter
      Parse::Agent.new(rate_limiter: rate_limiter)
    else
      Parse::Agent.new
    end

    agent.define_singleton_method(:execute) do |tool_name, **kwargs|
      # Honor the rate limiter so tests that inject a shared limiter work.
      @rate_limiter.check!

      case tool_name
      when :get_all_schemas
        {
          success: true,
          data: {
            total: 2,
            custom: [{ name: "Song", type: "Custom", description: "Music tracks", fields: 5 }],
            built_in: [{ name: "_User", type: "System", description: "Auth users", fields: 10 }],
            classes: [
              { name: "Song",  type: "Custom", description: "Music tracks" },
              { name: "_User", type: "System", description: "Auth users"   },
            ],
          },
        }
      when :list_classes
        { success: true, data: { classes: ["Song", "_User"] } }
      else
        { success: true, data: { tool: tool_name.to_s, args: kwargs } }
      end
    rescue Parse::Agent::RateLimitExceeded => e
      { success: false, error: e.message, error_code: :rate_limited, retry_after: e.retry_after }
    end

    agent
  end

  # A factory that always returns a freshly stubbed agent.
  def permissive_factory
    ->(_env) { stubbed_agent }
  end

  # --------------------------------------------------------------------------
  # 1. Full happy-path tests
  # --------------------------------------------------------------------------

  def test_initialize_handshake
    status, hdrs, body = post_mcp(
      { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => {} },
      agent_factory: permissive_factory,
    )

    assert_equal 200, status
    assert_equal "application/json", hdrs["Content-Type"]
    assert_equal "2.0",  body["jsonrpc"]
    assert_equal 1,      body["id"]
    result = body["result"]
    assert_equal Parse::Agent::MCPDispatcher::PROTOCOL_VERSION, result["protocolVersion"]
    assert result.key?("capabilities")
    assert result.key?("serverInfo")
    assert_equal "parse-stack-mcp", result.dig("serverInfo", "name")
  end

  def test_ping_returns_empty_result
    status, _hdrs, body = post_mcp(
      { "jsonrpc" => "2.0", "id" => 2, "method" => "ping" },
      agent_factory: permissive_factory,
    )

    assert_equal 200, status
    assert_equal "2.0", body["jsonrpc"]
    assert_equal 2,     body["id"]
    assert_equal({},    body["result"])
  end

  def test_tools_list_returns_mcp_format
    status, _hdrs, body = post_mcp(
      { "jsonrpc" => "2.0", "id" => 3, "method" => "tools/list" },
      agent_factory: permissive_factory,
    )

    assert_equal 200, status
    tools = body.dig("result", "tools")
    assert_instance_of Array, tools
    assert tools.size > 0, "Should return at least one tool"
    # Each tool must have at minimum name and inputSchema (MCP format)
    tools.each do |t|
      assert t.key?("name"),        "Tool missing 'name': #{t.inspect}"
      assert t.key?("inputSchema"), "Tool missing 'inputSchema': #{t.inspect}"
    end
  end

  def test_tools_call_get_all_schemas_returns_content_envelope
    status, _hdrs, body = post_mcp(
      {
        "jsonrpc" => "2.0",
        "id"      => 4,
        "method"  => "tools/call",
        "params"  => { "name" => "get_all_schemas", "arguments" => {} },
      },
      agent_factory: permissive_factory,
    )

    assert_equal 200, status
    result = body["result"]
    assert result.key?("content"), "Result should have 'content' key"
    assert_equal false, result["isError"]
    content_text = result.dig("content", 0, "text")
    assert_instance_of String, content_text
    parsed_content = JSON.parse(content_text)
    assert_equal 2, parsed_content["total"]
  end

  def test_tools_call_failure_returns_is_error_true
    agent = Parse::Agent.new
    agent.define_singleton_method(:execute) do |tool_name, **kwargs|
      { success: false, error: "Tool execution failed for test" }
    end

    status, _hdrs, body = post_mcp(
      {
        "jsonrpc" => "2.0",
        "id"      => 5,
        "method"  => "tools/call",
        "params"  => { "name" => "query_class", "arguments" => { "class_name" => "Song" } },
      },
      agent_factory: ->(_env) { agent },
    )

    assert_equal 200, status
    result = body["result"]
    assert_equal true, result["isError"]
    assert_includes result.dig("content", 0, "text"), "Tool execution failed for test"
  end

  def test_prompts_list_returns_builtin_prompts
    status, _hdrs, body = post_mcp(
      { "jsonrpc" => "2.0", "id" => 6, "method" => "prompts/list" },
      agent_factory: permissive_factory,
    )

    assert_equal 200, status
    prompts = body.dig("result", "prompts")
    assert_instance_of Array, prompts
    names = prompts.map { |p| p["name"] }
    assert_includes names, "parse_conventions"
    assert_includes names, "class_overview"
    assert_includes names, "explore_database"
  end

  def test_prompts_get_parse_conventions_argless
    # parse_conventions requires no arguments — ideal for a self-contained test.
    status, _hdrs, body = post_mcp(
      {
        "jsonrpc" => "2.0",
        "id"      => 7,
        "method"  => "prompts/get",
        "params"  => { "name" => "parse_conventions", "arguments" => {} },
      },
      agent_factory: permissive_factory,
    )

    assert_equal 200, status
    result = body["result"]
    assert result.key?("messages"), "Result should have 'messages' key"
    messages = result["messages"]
    assert_instance_of Array, messages
    assert messages.size > 0
    assert_equal "user", messages.first["role"]
    text = messages.dig(0, "content", "text")
    # The conventions text includes Parse-specific terms
    assert_includes text, "objectId"
    assert_includes text, "Parse"
  end

  def test_resources_list_returns_virtual_resources
    status, _hdrs, body = post_mcp(
      { "jsonrpc" => "2.0", "id" => 8, "method" => "resources/list" },
      agent_factory: permissive_factory,
    )

    assert_equal 200, status
    resources = body.dig("result", "resources")
    assert_instance_of Array, resources
    # Our stubbed execute(:get_all_schemas) returns Song and _User → 6 resources
    assert resources.size >= 2, "Should have at least some resources"
    uris = resources.map { |r| r["uri"] }
    assert uris.any? { |u| u.start_with?("parse://") }, "Resource URIs should use parse:// scheme"
  end

  # --------------------------------------------------------------------------
  # 2. Auth flows
  # --------------------------------------------------------------------------

  def test_block_form_factory_returning_agent_gives_200
    app = Parse::Agent::MCPRackApp.new do |_env|
      stubbed_agent
    end
    raw = JSON.generate({ "jsonrpc" => "2.0", "id" => 9, "method" => "ping" })
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE"   => "application/json",
      "rack.input"     => StringIO.new(raw),
    }
    status, _hdrs, chunks = app.call(env)
    assert_equal 200, status
  end

  def test_block_form_factory_raising_unauthorized_returns_401
    factory = ->(_env) { raise Parse::Agent::Unauthorized, "bad bearer token — do not leak" }
    status, hdrs, body = post_mcp(
      { "jsonrpc" => "2.0", "id" => 10, "method" => "ping" },
      agent_factory: factory,
    )

    assert_equal 401, status
    assert_equal "application/json", hdrs["Content-Type"]
    assert_equal "2.0",        body["jsonrpc"]
    assert_nil                 body["id"]
    assert_equal(-32_001,      body.dig("error", "code"))
    assert_equal "Unauthorized", body.dig("error", "message")
    # No exception detail must leak
    refute_includes body.to_json, "bad bearer token"
    refute_includes body.to_json, "do not leak"
  end

  def test_block_form_factory_raising_standard_error_returns_500_sanitized
    factory = ->(_env) { raise RuntimeError, "internal secret db password" }
    status, hdrs, body = post_mcp(
      { "jsonrpc" => "2.0", "id" => 11, "method" => "ping" },
      agent_factory: factory,
    )

    assert_equal 500, status
    assert_equal "application/json", hdrs["Content-Type"]
    assert_equal(-32_603, body.dig("error", "code"))
    # Exception message must NOT appear
    refute_includes body.to_json, "internal secret db password"
    # Backtrace must not appear
    refute body.to_json.include?("mcp_integration_test.rb"),
           "Backtrace line must not appear in sanitized response body"
  end

  def test_bearer_token_auth_via_factory_env_inspection
    secret = "Bearer let-me-in"
    auth_factory = lambda do |env|
      token = env["HTTP_AUTHORIZATION"].to_s
      raise Parse::Agent::Unauthorized, "bad token" unless token == secret
      stubbed_agent
    end

    # Good token → 200
    status_ok, _hdrs_ok, body_ok = post_mcp(
      { "jsonrpc" => "2.0", "id" => 12, "method" => "ping" },
      agent_factory: auth_factory,
      headers: { "HTTP_AUTHORIZATION" => secret },
    )
    assert_equal 200, status_ok
    assert_equal({}, body_ok["result"])

    # Wrong token → 401
    status_bad, _hdrs_bad, body_bad = post_mcp(
      { "jsonrpc" => "2.0", "id" => 13, "method" => "ping" },
      agent_factory: auth_factory,
      headers: { "HTTP_AUTHORIZATION" => "Bearer wrong-token" },
    )
    assert_equal 401, status_bad
    assert_equal "Unauthorized", body_bad.dig("error", "message")
  end

  # --------------------------------------------------------------------------
  # 3. Transport-level failures
  # --------------------------------------------------------------------------

  def test_get_request_returns_405
    status, hdrs, body = post_mcp(
      "{}",
      agent_factory: permissive_factory,
      headers: { "REQUEST_METHOD" => "GET" },
    )

    assert_equal 405, status
    assert_equal "POST", hdrs["Allow"]
    assert_equal(-32_700, body.dig("error", "code"))
    assert_equal "method_not_allowed", body.dig("error", "message")
  end

  def test_wrong_content_type_returns_415
    status, _hdrs, body = post_mcp(
      "{}",
      agent_factory: permissive_factory,
      headers: { "CONTENT_TYPE" => "text/plain" },
    )

    assert_equal 415, status
    assert_equal(-32_700, body.dig("error", "code"))
  end

  def test_body_exceeding_max_size_returns_413
    oversized = "x" * 11
    status, _hdrs, body = post_mcp(
      oversized,
      agent_factory: permissive_factory,
      max_body_size: 10,
    )

    assert_equal 413, status
    assert_equal(-32_700, body.dig("error", "code"))
    assert_includes body.dig("error", "message"), "Payload Too Large"
  end

  def test_malformed_json_returns_400_parse_error
    status, hdrs, body = post_mcp(
      "{ this is not json !!!",
      agent_factory: permissive_factory,
    )

    assert_equal 400, status
    assert_equal "application/json", hdrs["Content-Type"]
    assert_equal "2.0", body["jsonrpc"]
    assert_nil          body["id"]
    assert_equal(-32_700, body.dig("error", "code"))
    assert_includes body.dig("error", "message"), "Parse error"
  end

  # --------------------------------------------------------------------------
  # 4. Dispatcher-level errors (transport succeeds, protocol fails)
  # --------------------------------------------------------------------------

  def test_unknown_method_returns_200_with_rpc_error_32601
    status, _hdrs, body = post_mcp(
      { "jsonrpc" => "2.0", "id" => 20, "method" => "tools/fly_to_moon" },
      agent_factory: permissive_factory,
    )

    assert_equal 200, status
    assert_equal(-32_601, body.dig("error", "code"))
    assert_includes body.dig("error", "message"), "Method not found"
  end

  def test_tools_call_missing_tool_name_returns_32602
    status, _hdrs, body = post_mcp(
      { "jsonrpc" => "2.0", "id" => 21, "method" => "tools/call", "params" => { "arguments" => {} } },
      agent_factory: permissive_factory,
    )

    # Dispatcher returns 200 with JSON-RPC error when tool_name is missing
    assert_equal 200, status
    assert_equal(-32_602, body.dig("error", "code"))
    assert_includes body.dig("error", "message"), "Missing tool name"
  end

  def test_body_missing_method_key_returns_32600
    # The rack app's transport-layer DoS guard refuses a JSON-RPC envelope
    # with no usable "method" field BEFORE invoking the agent factory or
    # the dispatcher (an empty `{}` or missing-method body would otherwise
    # amplify into a Parse Server load problem via the factory's auth /
    # audit-log hits). Per JSON-RPC 2.0, a parseable body that violates
    # the request envelope shape is -32600 "Invalid Request" (-32700 is
    # reserved for unparseable JSON). The rack layer answers with HTTP
    # 400 to discourage retries; application-layer JSON-RPC errors
    # downstream of the guard continue to use HTTP 200.
    status, _hdrs, body = post_mcp(
      { "jsonrpc" => "2.0", "id" => 22 },   # no "method" key
      agent_factory: permissive_factory,
    )

    assert_equal 400, status
    assert_equal(-32_600, body.dig("error", "code"))
    assert_equal "Invalid Request", body.dig("error", "message")
  end

  def test_prompts_get_unknown_name_returns_32602
    status, _hdrs, body = post_mcp(
      {
        "jsonrpc" => "2.0",
        "id"      => 23,
        "method"  => "prompts/get",
        "params"  => { "name" => "nonexistent_prompt_xyz", "arguments" => {} },
      },
      agent_factory: permissive_factory,
    )

    assert_equal 200, status
    assert_equal(-32_602, body.dig("error", "code"))
    assert_includes body.dig("error", "message"), "Unknown prompt"
  end

  # --------------------------------------------------------------------------
  # 5. Per-request agent isolation
  # --------------------------------------------------------------------------

  def test_agent_factory_invoked_once_per_request
    invocation_count = 0
    factory = lambda do |_env|
      invocation_count += 1
      stubbed_agent
    end

    3.times do
      post_mcp(
        { "jsonrpc" => "2.0", "id" => 30, "method" => "ping" },
        agent_factory: factory,
      )
    end

    assert_equal 3, invocation_count,
                 "agent_factory must be called exactly once per request (got #{invocation_count} calls for 3 requests)"
  end

  def test_each_request_receives_independent_agent_instance
    agents = []
    factory = lambda do |_env|
      a = stubbed_agent
      agents << a
      a
    end

    2.times do
      post_mcp(
        { "jsonrpc" => "2.0", "id" => 31, "method" => "ping" },
        agent_factory: factory,
      )
    end

    assert_equal 2, agents.size
    # Two distinct objects — per-request isolation
    refute_same agents[0], agents[1]
  end

  # --------------------------------------------------------------------------
  # 6. Rate-limiter injection scenario
  # --------------------------------------------------------------------------

  def test_shared_rate_limiter_triggers_on_fourth_request
    # Shared limiter across all agents returned by the factory.
    shared_limiter = Parse::Agent::RateLimiter.new(limit: 3, window: 60)

    factory = ->(_env) { stubbed_agent(rate_limiter: shared_limiter) }

    # First 3 requests should succeed with is_error: false
    3.times do |i|
      status, _hdrs, body = post_mcp(
        {
          "jsonrpc" => "2.0",
          "id"      => 40 + i,
          "method"  => "tools/call",
          "params"  => { "name" => "get_all_schemas", "arguments" => {} },
        },
        agent_factory: factory,
      )
      assert_equal 200, status, "Request #{i + 1} should return HTTP 200"
      assert_equal false, body.dig("result", "isError"),
                   "Request #{i + 1} should succeed (isError false), got: #{body.inspect}"
    end

    # 4th request — rate limit exhausted
    # The stub returns {success: false, error: "Rate limit exceeded..."} from the
    # rescued RateLimitExceeded, which the dispatcher wraps as isError: true.
    status4, _hdrs4, body4 = post_mcp(
      {
        "jsonrpc" => "2.0",
        "id"      => 43,
        "method"  => "tools/call",
        "params"  => { "name" => "get_all_schemas", "arguments" => {} },
      },
      agent_factory: factory,
    )

    # Transport-level must still be 200 (rate limit is a tool-level error per MCP spec)
    assert_equal 200, status4
    assert_equal true, body4.dig("result", "isError"),
                 "4th request should hit rate limit (isError true), got: #{body4.inspect}"
    error_text = body4.dig("result", "content", 0, "text")
    assert_includes error_text, "Rate limit exceeded"
  end

  # --------------------------------------------------------------------------
  # 7. Prompt registration scenario
  # --------------------------------------------------------------------------

  def test_registered_custom_prompt_appears_in_prompts_list
    Parse::Agent::Prompts.register(
      name:        "test_custom_prompt",
      description: "A custom test prompt",
      arguments:   [{ "name" => "widget_id", "description" => "ID of the widget", "required" => true }],
      renderer:    ->(args) { "Do something with widget #{args['widget_id']}" },
    )

    status, _hdrs, body = post_mcp(
      { "jsonrpc" => "2.0", "id" => 50, "method" => "prompts/list" },
      agent_factory: permissive_factory,
    )

    assert_equal 200, status
    prompts = body.dig("result", "prompts")
    names   = prompts.map { |p| p["name"] }
    assert_includes names, "test_custom_prompt", "Custom prompt should appear in prompts/list"
    entry = prompts.find { |p| p["name"] == "test_custom_prompt" }
    assert_equal "A custom test prompt", entry["description"]
  end

  def test_registered_custom_prompt_renders_via_prompts_get
    Parse::Agent::Prompts.register(
      name:        "test_custom_prompt",
      description: "A custom test prompt",
      arguments:   [{ "name" => "widget_id", "description" => "ID of the widget", "required" => true }],
      renderer:    ->(args) { "Do something with widget #{args['widget_id']}" },
    )

    status, _hdrs, body = post_mcp(
      {
        "jsonrpc" => "2.0",
        "id"      => 51,
        "method"  => "prompts/get",
        "params"  => { "name" => "test_custom_prompt", "arguments" => { "widget_id" => "wgt42" } },
      },
      agent_factory: permissive_factory,
    )

    assert_equal 200, status
    result = body["result"]
    assert result.key?("messages"), "prompts/get result should have 'messages'"
    text = result.dig("messages", 0, "content", "text")
    assert_includes text, "widget wgt42", "Rendered text should include the argument value"
  end

  def test_custom_prompt_with_hash_renderer_returns_description
    Parse::Agent::Prompts.register(
      name:        "hash_renderer_prompt",
      description: "Uses a hash renderer",
      arguments:   [],
      renderer:    ->(_args) { { description: "Custom description text", text: "Custom message text" } },
    )

    status, _hdrs, body = post_mcp(
      {
        "jsonrpc" => "2.0",
        "id"      => 52,
        "method"  => "prompts/get",
        "params"  => { "name" => "hash_renderer_prompt", "arguments" => {} },
      },
      agent_factory: permissive_factory,
    )

    assert_equal 200, status
    result = body["result"]
    assert_equal "Custom description text", result["description"]
    assert_includes result.dig("messages", 0, "content", "text"), "Custom message text"
  end

  def test_reset_registry_removes_custom_prompts
    Parse::Agent::Prompts.register(
      name:        "temp_prompt",
      description: "Temporary",
      arguments:   [],
      renderer:    ->(_args) { "temp" },
    )

    # Verify it's there before reset
    list_before = Parse::Agent::Prompts.list
    assert list_before.any? { |p| p["name"] == "temp_prompt" }

    Parse::Agent::Prompts.reset_registry!

    # Verify it's gone after reset
    list_after = Parse::Agent::Prompts.list
    refute list_after.any? { |p| p["name"] == "temp_prompt" },
           "Custom prompt should be removed after reset_registry!"
    # Builtins must survive the reset
    assert list_after.any? { |p| p["name"] == "parse_conventions" },
           "Builtin prompts must survive reset_registry!"
  end

  # --------------------------------------------------------------------------
  # 8. MCPServer → MCPRackApp delegation
  # --------------------------------------------------------------------------

  def test_mcp_server_delegates_to_mcp_rack_app
    server = Parse::Agent::MCPServer.new(port: 9991, api_key: "test-key-abc")
    rack_app = server.instance_variable_get(:@rack_app)

    assert_instance_of Parse::Agent::MCPRackApp, rack_app,
                       "MCPServer's @rack_app must be a Parse::Agent::MCPRackApp instance"
  end

  def test_mcp_server_agent_factory_raises_unauthorized_on_bad_key
    server = Parse::Agent::MCPServer.new(port: 9992, api_key: "correct-key")

    # Build a Rack env that carries the wrong API key
    env_bad = {
      "REQUEST_METHOD"      => "POST",
      "CONTENT_TYPE"        => "application/json",
      "HTTP_X_MCP_API_KEY"  => "wrong-key",
      "rack.input"          => StringIO.new("{}"),
    }

    assert_raises(Parse::Agent::Unauthorized) do
      server.send(:agent_factory, env_bad)
    end
  end

  def test_mcp_server_agent_factory_returns_fresh_agent_on_correct_key
    server = Parse::Agent::MCPServer.new(port: 9993, api_key: "correct-key")

    env_good = {
      "REQUEST_METHOD"      => "POST",
      "CONTENT_TYPE"        => "application/json",
      "HTTP_X_MCP_API_KEY"  => "correct-key",
      "rack.input"          => StringIO.new("{}"),
    }

    a = server.send(:agent_factory, env_good)
    b = server.send(:agent_factory, env_good)

    assert_instance_of Parse::Agent, a
    refute_same a, b, "agent_factory must build a fresh Parse::Agent per request to avoid cross-request leakage of @conversation_history / @operation_log"
    refute_same server.agent, a, "agent_factory must not return the server's template agent — that would re-leak state across requests"
    # Sanity: per-request agents must share the rate limiter so the budget persists.
    shared_limiter = server.instance_variable_get(:@shared_rate_limiter)
    assert_same shared_limiter, a.instance_variable_get(:@rate_limiter)
    assert_same shared_limiter, b.instance_variable_get(:@rate_limiter)
  end

  def test_mcp_server_agent_factory_skips_key_check_when_no_api_key_configured
    # Ensure env var doesn't interfere with this test
    original_env = ENV.delete("MCP_API_KEY")

    begin
      server = Parse::Agent::MCPServer.new(port: 9994, api_key: nil)

      env_any = {
        "REQUEST_METHOD"     => "POST",
        "CONTENT_TYPE"       => "application/json",
        "rack.input"         => StringIO.new("{}"),
      }

      result = server.send(:agent_factory, env_any)
      assert_instance_of Parse::Agent, result,
                         "agent_factory must build an agent without key check when no api_key is configured"
      refute_same server.agent, result,
                  "agent_factory must build a fresh agent per request even when no api_key is configured"
    ensure
      ENV["MCP_API_KEY"] = original_env if original_env
    end
  end

  def test_mcp_server_exposes_shared_agent
    server = Parse::Agent::MCPServer.new(port: 9995)
    assert_instance_of Parse::Agent, server.agent
  end

  def test_mcp_server_accepts_external_rate_limiter_kwarg
    # Build a minimal duck-typed limiter.
    check_count = 0
    custom_limiter = Object.new
    custom_limiter.define_singleton_method(:check!) { check_count += 1 }

    server = Parse::Agent::MCPServer.new(port: 9996, rate_limiter: custom_limiter)

    # The shared_rate_limiter stored on the server should be the one we passed.
    assert_same custom_limiter,
                server.instance_variable_get(:@shared_rate_limiter),
                "MCPServer must use the provided rate_limiter instead of creating a new RateLimiter"

    # The template agent on the server must also receive the injected limiter.
    assert_same custom_limiter,
                server.agent.instance_variable_get(:@rate_limiter),
                "Template agent must share the injected rate_limiter"
  end

  def test_mcp_server_raises_argument_error_for_invalid_rate_limiter
    # An object that does NOT respond to :check! must be rejected.
    bad_limiter = Object.new  # no #check! method

    assert_raises(ArgumentError) do
      Parse::Agent::MCPServer.new(port: 9997, rate_limiter: bad_limiter)
    end
  end

  def test_mcp_server_rate_limiter_is_invoked_by_agent_factory
    # Verify that agents built by the factory share the injected limiter.
    custom_limiter = Parse::Agent::RateLimiter.new(limit: 10, window: 60)

    server = Parse::Agent::MCPServer.new(port: 9998, rate_limiter: custom_limiter)

    env_good = {
      "REQUEST_METHOD"  => "POST",
      "CONTENT_TYPE"    => "application/json",
      "rack.input"      => StringIO.new("{}"),
    }

    a = server.send(:agent_factory, env_good)
    assert_same custom_limiter, a.instance_variable_get(:@rate_limiter),
                "agent_factory must share the injected limiter with per-request agents"
  end

  # --------------------------------------------------------------------------
  # 9. Response envelope shape invariants
  # --------------------------------------------------------------------------

  def test_all_successful_responses_have_jsonrpc_version
    methods = [
      { "method" => "ping" },
      { "method" => "tools/list" },
      { "method" => "prompts/list" },
    ]

    methods.each do |m|
      _status, _hdrs, body = post_mcp(
        { "jsonrpc" => "2.0", "id" => 60, **m },
        agent_factory: permissive_factory,
      )
      assert_equal "2.0", body["jsonrpc"],
                   "Response for #{m['method']} must carry jsonrpc: '2.0'"
    end
  end

  def test_id_echo_in_response
    _status, _hdrs, body = post_mcp(
      { "jsonrpc" => "2.0", "id" => 999, "method" => "ping" },
      agent_factory: permissive_factory,
    )
    assert_equal 999, body["id"], "Response id must match request id"
  end

  def test_null_id_preserved_in_error_responses
    status, _hdrs, body = post_mcp(
      "totally-not-json",
      agent_factory: permissive_factory,
    )
    assert_equal 400, status
    assert_nil body["id"], "Error response id must be null when request couldn't be parsed"
  end

  def test_content_type_is_always_application_json
    scenarios = [
      [{ "jsonrpc" => "2.0", "id" => 1, "method" => "ping" }, {}],
      ["{}", { "REQUEST_METHOD" => "GET" }],
      ["bad json", {}],
    ]

    scenarios.each_with_index do |(body, extra_headers), i|
      _status, hdrs, _body = post_mcp(
        body,
        agent_factory: permissive_factory,
        headers: extra_headers,
      )
      assert_equal "application/json", hdrs["Content-Type"],
                   "Scenario #{i}: Content-Type must always be application/json"
    end
  end
end
