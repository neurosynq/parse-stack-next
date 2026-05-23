# encoding: UTF-8
# frozen_string_literal: true

require "stringio"
require "json"
require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_rack_app"

# ---------------------------------------------------------------------------
# MCPDispatcher stub
#
# MCPDispatcher is defined in mcp_dispatcher.rb (Agent B) which is already
# on disk. We override .call on the singleton with a controllable stub so
# tests never depend on Agent B's full implementation or a live Parse server.
# The original method is restored in teardown.
# ---------------------------------------------------------------------------
module MCPDispatcherStub
  FIXED_RESPONSE = { status: 200, body: { "jsonrpc" => "2.0", "id" => nil, "result" => {} } }.freeze

  def self.install!
    @original_call = Parse::Agent::MCPDispatcher.method(:call)
    @stub_response = nil

    Parse::Agent::MCPDispatcher.define_singleton_method(:call) do |body:, agent:, logger: nil, progress_callback: nil, cancellation_token: nil|
      MCPDispatcherStub.stub_response || MCPDispatcherStub::FIXED_RESPONSE
    end
  end

  def self.restore!
    if @original_call
      original = @original_call
      Parse::Agent::MCPDispatcher.define_singleton_method(:call, &original)
    end
    @stub_response = nil
  end

  def self.stub_response=(response)
    @stub_response = response
  end

  def self.stub_response
    @stub_response
  end
end

MCPDispatcherStub.install!

# Restore the real MCPDispatcher.call after all tests complete so that
# other test files loaded in the same process are not affected by the stub.
Minitest.after_run { MCPDispatcherStub.restore! }

class MCPRackAppTest < Minitest::Test
  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def setup
    # Configure a minimal Parse client so Parse::Agent.new doesn't raise.
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
    MCPDispatcherStub.stub_response = nil
  end

  # Build a minimal Rack env hash without requiring the rack gem.
  # Default body is a well-formed JSON-RPC envelope (`method: "tools/list"`)
  # so the request reaches the agent_factory / dispatcher. Tests that care
  # specifically about NEW-MCP-6's body-shape short-circuit pass an empty
  # `{}` explicitly.
  def rack_env(method: "POST", content_type: "application/json",
               body: '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')
    {
      "REQUEST_METHOD" => method,
      "CONTENT_TYPE"   => content_type,
      "rack.input"     => StringIO.new(body),
    }
  end

  def valid_agent
    Parse::Agent.new
  end

  # A factory proc that always returns a valid agent (no auth check).
  def permissive_factory
    ->(_env) { valid_agent }
  end

  # Build a rack app with a permissive factory and optional overrides.
  def build_app(**kwargs)
    Parse::Agent::MCPRackApp.new(agent_factory: permissive_factory, **kwargs)
  end

  def teardown
    MCPDispatcherStub.stub_response = nil
  end

  # ---------------------------------------------------------------------------
  # Constructor contract
  # ---------------------------------------------------------------------------

  def test_raises_when_both_block_and_factory_given
    assert_raises(ArgumentError) do
      Parse::Agent::MCPRackApp.new(agent_factory: permissive_factory) { |_e| valid_agent }
    end
  end

  def test_raises_when_neither_block_nor_factory_given
    assert_raises(ArgumentError) do
      Parse::Agent::MCPRackApp.new
    end
  end

  def test_block_form_constructor_works
    app = Parse::Agent::MCPRackApp.new { |_env| valid_agent }
    status, headers, body = app.call(rack_env)
    assert_equal 200, status
    assert_equal "application/json", headers["Content-Type"]
    assert_instance_of Array, body
  end

  # ---------------------------------------------------------------------------
  # Happy path
  # ---------------------------------------------------------------------------

  def test_post_with_valid_json_returns_200
    app = build_app
    json_body = JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "ping" })
    status, headers, body = app.call(rack_env(body: json_body))

    assert_equal 200, status
    assert_equal "application/json", headers["Content-Type"]
    parsed = JSON.parse(body.first)
    # The stub returns a "result" key
    assert parsed.key?("result")
  end

  def test_dispatcher_response_body_is_serialized_to_json
    dispatcher_body = { "jsonrpc" => "2.0", "id" => 42, "result" => { "count" => 7 } }
    MCPDispatcherStub.stub_response = { status: 200, body: dispatcher_body }

    app = build_app
    _status, _headers, body = app.call(rack_env(body: JSON.generate({ "method" => "ping" })))

    parsed = JSON.parse(body.first)
    assert_equal 42, parsed["id"]
    assert_equal 7, parsed["result"]["count"]
  end

  def test_dispatcher_non_200_status_is_forwarded
    MCPDispatcherStub.stub_response = {
      status: 404,
      body: { "jsonrpc" => "2.0", "id" => nil, "error" => { "code" => -32_601, "message" => "Method not found" } },
    }
    app = build_app
    status, _headers, _body = app.call(rack_env(body: JSON.generate({ "method" => "unknown" })))
    assert_equal 404, status
  end

  # ---------------------------------------------------------------------------
  # Method check (405)
  # ---------------------------------------------------------------------------

  def test_get_returns_405
    app = build_app
    status, headers, body = app.call(rack_env(method: "GET"))

    assert_equal 405, status
    assert_equal "POST", headers["Allow"]
    parsed = JSON.parse(body.first)
    assert_equal "method_not_allowed", parsed.dig("error", "message")
  end

  def test_put_returns_405
    app = build_app
    status, _headers, _body = app.call(rack_env(method: "PUT"))
    assert_equal 405, status
  end

  def test_delete_without_session_id_returns_400
    app = build_app
    status, _headers, body = app.call(rack_env(method: "DELETE"))
    assert_equal 400, status
    assert_equal "Missing Mcp-Session-Id", JSON.parse(body.first).dig("error", "message")
  end

  def test_delete_with_session_id_returns_204_and_does_not_invoke_factory
    call_count = 0
    factory = ->(_env) { call_count += 1; valid_agent }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory)
    env = rack_env(method: "DELETE")
    env["HTTP_MCP_SESSION_ID"] = "session-to-terminate"
    status, _headers, body = app.call(env)
    assert_equal 204, status
    assert_equal [""], body
    assert_equal 0, call_count, "DELETE must not invoke agent_factory"
  end

  def test_delete_with_malicious_session_id_returns_400
    app = build_app
    env = rack_env(method: "DELETE")
    env["HTTP_MCP_SESSION_ID"] = "evil\nLOG-INJECTION"
    status, _headers, body = app.call(env)
    assert_equal 400, status
    assert_equal "Invalid Mcp-Session-Id", JSON.parse(body.first).dig("error", "message")
  end

  def test_delete_cancels_inflight_requests_for_session
    app = build_app
    token = Parse::Agent::CancellationToken.new
    registry = app.instance_variable_get(:@cancellation_registry)
    registry.register("session-abc", 1, token)

    env = rack_env(method: "DELETE")
    env["HTTP_MCP_SESSION_ID"] = "session-abc"
    status, _headers, _body = app.call(env)

    assert_equal 204, status
    assert token.cancelled?, "in-flight cancellation token must be tripped by DELETE"
    assert_equal 0, registry.size, "cancelled entries must be removed from the registry"
  end

  # ---------------------------------------------------------------------------
  # Content-type check (415)
  # ---------------------------------------------------------------------------

  def test_wrong_content_type_returns_415
    app = build_app
    status, headers, body = app.call(rack_env(content_type: "text/plain"))

    assert_equal 415, status
    assert_equal "application/json", headers["Content-Type"]
    parsed = JSON.parse(body.first)
    assert_equal(-32_700, parsed.dig("error", "code"))
  end

  def test_application_json_with_charset_is_accepted
    app = build_app
    status, _headers, _body = app.call(rack_env(content_type: "application/json; charset=utf-8"))
    assert_equal 200, status
  end

  def test_form_urlencoded_returns_415
    app = build_app
    status, _headers, _body = app.call(rack_env(content_type: "application/x-www-form-urlencoded"))
    assert_equal 415, status
  end

  # ---------------------------------------------------------------------------
  # Body size limit (413)
  # ---------------------------------------------------------------------------

  def test_oversized_body_returns_413
    max = Parse::Agent::MCPRackApp::DEFAULT_MAX_BODY_SIZE
    oversized = "x" * (max + 1)
    app = build_app

    status, headers, body = app.call(rack_env(body: oversized))

    assert_equal 413, status
    assert_equal "application/json", headers["Content-Type"]
    parsed = JSON.parse(body.first)
    assert_equal(-32_700, parsed.dig("error", "code"))
  end

  def test_body_exactly_at_limit_fails_json_parse
    max = Parse::Agent::MCPRackApp::DEFAULT_MAX_BODY_SIZE
    at_limit = "x" * max
    app = build_app

    # Body at exactly max bytes passes size check but will fail JSON parse.
    status, _headers, _body = app.call(rack_env(body: at_limit))
    assert_equal 400, status
  end

  def test_custom_max_body_size_is_respected
    app = Parse::Agent::MCPRackApp.new(agent_factory: permissive_factory, max_body_size: 10)
    oversized = "x" * 11
    status, _headers, _body = app.call(rack_env(body: oversized))
    assert_equal 413, status
  end

  # ---------------------------------------------------------------------------
  # JSON parse errors (400)
  # ---------------------------------------------------------------------------

  def test_malformed_json_returns_400_with_rpc_parse_error
    app = build_app
    status, headers, body = app.call(rack_env(body: "{ not valid json"))

    assert_equal 400, status
    assert_equal "application/json", headers["Content-Type"]
    parsed = JSON.parse(body.first)
    assert_equal "2.0", parsed["jsonrpc"]
    assert_nil parsed["id"]
    assert_equal(-32_700, parsed.dig("error", "code"))
  end

  def test_truncated_json_returns_400
    app = build_app
    status, _headers, _body = app.call(rack_env(body: '{"method":'))
    assert_equal 400, status
  end

  # ---------------------------------------------------------------------------
  # Auth / factory errors
  # ---------------------------------------------------------------------------

  def test_factory_raising_unauthorized_returns_401_sanitized
    factory = ->(_env) { raise Parse::Agent::Unauthorized, "secret token mismatch do not leak this" }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory)

    status, headers, body = app.call(rack_env)

    assert_equal 401, status
    assert_equal "application/json", headers["Content-Type"]
    parsed = JSON.parse(body.first)
    assert_equal "2.0", parsed["jsonrpc"]
    assert_nil parsed["id"]
    assert_equal(-32_001, parsed.dig("error", "code"))
    assert_equal "Unauthorized", parsed.dig("error", "message")
    # Critically: the original exception message must not appear in the response
    refute_includes body.first, "secret token mismatch"
    refute_includes body.first, "do not leak"
  end

  def test_factory_raising_standard_error_returns_500_no_exception_details
    factory = ->(_env) { raise RuntimeError, "internal secret details" }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory)

    status, headers, body = app.call(rack_env)

    assert_equal 500, status
    assert_equal "application/json", headers["Content-Type"]
    parsed = JSON.parse(body.first)
    assert_equal(-32_603, parsed.dig("error", "code"))
    # Exception message must NOT leak
    refute_includes body.first, "internal secret details"
  end

  def test_logger_is_called_on_unauthorized
    logs = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |msg| logs << msg }

    factory = ->(_env) { raise Parse::Agent::Unauthorized }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory, logger: logger)
    app.call(rack_env)

    assert logs.any? { |m| m.include?("Unauthorized") },
           "Expected logger to receive a warn call containing 'Unauthorized'"
  end

  def test_logger_is_called_on_standard_error
    logs = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |msg| logs << msg }

    factory = ->(_env) { raise RuntimeError, "boom" }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory, logger: logger)
    app.call(rack_env)

    assert logs.any?, "Expected at least one warn log on StandardError"
  end

  def test_no_logger_silent_on_unauthorized
    factory = ->(_env) { raise Parse::Agent::Unauthorized }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory)
    # Must not raise
    assert_silent { app.call(rack_env) }
  end

  # ---------------------------------------------------------------------------
  # Response shape invariants
  # ---------------------------------------------------------------------------

  def test_all_error_responses_have_json_content_type
    app = build_app
    scenarios = [
      rack_env(method: "GET"),
      rack_env(content_type: "text/plain"),
      rack_env(body: "bad json"),
    ]
    scenarios.each do |env|
      _status, headers, _body = app.call(env)
      assert_equal "application/json", headers["Content-Type"],
                   "Content-Type must be application/json (method=#{env["REQUEST_METHOD"]}, ct=#{env["CONTENT_TYPE"]})"
    end
  end

  def test_error_response_body_is_array_with_one_string
    app = build_app
    _status, _headers, body = app.call(rack_env(method: "DELETE"))
    assert_instance_of Array, body
    assert_equal 1, body.size
    assert_instance_of String, body.first
  end

  def test_default_max_body_size_matches_mcp_server
    # Verify constant alignment: MCPRackApp must match MCPServer's 1 MB limit.
    assert_equal 1_048_576, Parse::Agent::MCPRackApp::DEFAULT_MAX_BODY_SIZE
  end

  # ---------------------------------------------------------------------------
  # Response headers must be mutable per-response so downstream Rack middleware
  # (Sinatra's xss_header / json_csrf / common_logger, rack-deflater, etc.)
  # can decorate without raising FrozenError, and so cross-request mutation
  # cannot leak through a shared singleton.
  # ---------------------------------------------------------------------------

  def test_response_headers_are_not_frozen_on_success
    app = build_app
    _status, headers, _body = app.call(rack_env(body: JSON.generate({ "method" => "ping" })))
    refute headers.frozen?, "200 response headers must be mutable for Rack middleware composability"
    headers["X-Decorator"] = "ok"  # would raise FrozenError under the old behavior
    assert_equal "ok", headers["X-Decorator"]
  end

  def test_response_headers_are_not_frozen_on_error_paths
    app = build_app
    [
      rack_env(method: "GET"),                       # 405
      rack_env(content_type: "text/plain"),          # 415
      rack_env(body: "bad json"),                    # 400
    ].each do |env|
      _status, headers, _body = app.call(env)
      refute headers.frozen?,
             "error response headers must be mutable (method=#{env["REQUEST_METHOD"]}, ct=#{env["CONTENT_TYPE"]})"
    end
  end

  def test_response_headers_are_a_fresh_hash_per_response
    app = build_app
    _, headers_a, _ = app.call(rack_env(body: JSON.generate({ "method" => "ping" })))
    _, headers_b, _ = app.call(rack_env(body: JSON.generate({ "method" => "ping" })))
    refute_same headers_a, headers_b,
                "each response must own its own headers hash to prevent cross-request mutation"
  end

  # ---------------------------------------------------------------------------
  # MCP-Protocol-Version header (MCP 2025-06-18 Streamable HTTP)
  # ---------------------------------------------------------------------------

  def test_supported_protocol_version_header_is_accepted
    app = build_app
    env = rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list" }))
    env["HTTP_MCP_PROTOCOL_VERSION"] = "2025-06-18"
    status, _headers, _body = app.call(env)
    assert_equal 200, status
  end

  def test_unsupported_protocol_version_header_returns_400
    app = build_app
    env = rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list" }))
    env["HTTP_MCP_PROTOCOL_VERSION"] = "1999-01-01"
    status, headers, body = app.call(env)
    assert_equal 400, status
    assert_equal "application/json", headers["Content-Type"]
    parsed = JSON.parse(body.first)
    assert_equal(-32_600, parsed.dig("error", "code"))
    assert_includes parsed.dig("error", "message"), "1999-01-01"
    assert_equal 1, parsed["id"], "JSON-RPC id must round-trip when known"
  end

  def test_missing_protocol_version_header_is_accepted_for_backcompat
    # Spec: when absent on a non-initialize request, server SHOULD
    # assume 2025-03-26. Either way, the request must NOT be rejected.
    app = build_app
    env = rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list" }))
    status, _headers, _body = app.call(env)
    assert_equal 200, status
  end

  def test_protocol_version_check_skipped_for_initialize
    # initialize IS the negotiation; the header is undefined at that point.
    # A client that sends an unknown version on initialize must still be
    # able to negotiate down. The header MUST NOT block initialize.
    app = build_app
    env = rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
                                         "params" => { "protocolVersion" => "2025-06-18" } }))
    env["HTTP_MCP_PROTOCOL_VERSION"] = "1999-01-01"
    status, _headers, _body = app.call(env)
    assert_equal 200, status
  end

  def test_protocol_version_check_skipped_for_notifications_cancelled
    # A cancellation may arrive from a client that has not (re-)negotiated
    # protocol on this transport instance. Must not block cancellation.
    app = build_app
    env = rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "method" => "notifications/cancelled",
                                         "params" => { "requestId" => 42 } }))
    env["HTTP_MCP_PROTOCOL_VERSION"] = "1999-01-01"
    status, _headers, _body = app.call(env)
    assert_equal 202, status
  end

  def test_empty_protocol_version_header_is_treated_as_missing
    # Some proxies forward empty header values rather than dropping them.
    # An empty string should not be parsed as an unsupported version.
    app = build_app
    env = rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list" }))
    env["HTTP_MCP_PROTOCOL_VERSION"] = ""
    status, _headers, _body = app.call(env)
    assert_equal 200, status
  end

  def test_unsupported_protocol_version_does_not_invoke_factory
    # Locks in the ordering invariant: the MCP-Protocol-Version header check
    # MUST run before agent_factory.call, so a malformed/unsupported header
    # cannot be used to force per-request agent construction (DoS surface).
    call_count = 0
    factory = ->(_env) { call_count += 1; valid_agent }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory)
    env = rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list" }))
    env["HTTP_MCP_PROTOCOL_VERSION"] = "1999-01-01"
    status, _headers, _body = app.call(env)
    assert_equal 400, status
    assert_equal 0, call_count, "factory must not be called when version validation fails"
  end

  # ---------------------------------------------------------------------------
  # Server-assigned Mcp-Session-Id (MCP 2025-06-18 Streamable HTTP, §session)
  # ---------------------------------------------------------------------------

  def test_initialize_without_session_header_returns_server_assigned_id
    captured_agent = nil
    factory = ->(_env) { captured_agent = valid_agent }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory)
    env = rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "initialize" }))
    status, headers, _body = app.call(env)
    assert_equal 200, status
    sid = headers["Mcp-Session-Id"]
    refute_nil sid, "initialize response must carry an Mcp-Session-Id header"
    refute sid.empty?
    assert_equal sid, captured_agent.correlation_id,
                 "server-assigned id must also be bound to agent.correlation_id"
  end

  def test_initialize_with_client_supplied_session_header_is_echoed
    captured_agent = nil
    factory = ->(_env) { captured_agent = valid_agent }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory)
    env = rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "initialize" }))
    env["HTTP_MCP_SESSION_ID"] = "client-chose-this"
    status, headers, _body = app.call(env)
    assert_equal 200, status
    assert_equal "client-chose-this", headers["Mcp-Session-Id"]
    assert_equal "client-chose-this", captured_agent.correlation_id
  end

  def test_initialize_does_not_overwrite_factory_bound_session_id
    factory = ->(_env) {
      a = valid_agent
      a.correlation_id = "factory-bound"
      a
    }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory)
    env = rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "initialize" }))
    env["HTTP_MCP_SESSION_ID"] = "client-tried-this"
    status, headers, _body = app.call(env)
    assert_equal 200, status
    assert_equal "factory-bound", headers["Mcp-Session-Id"]
  end

  def test_non_initialize_response_does_not_carry_session_header
    # Avoid leaking the session id on every reply; the client already
    # knows it from the initialize handshake.
    app = build_app
    env = rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list" }))
    env["HTTP_MCP_SESSION_ID"] = "abc-123"
    _status, headers, _body = app.call(env)
    refute headers.key?("Mcp-Session-Id"),
           "non-initialize responses must not echo Mcp-Session-Id"
  end
end
