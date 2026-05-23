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

  def test_delete_returns_405
    app = build_app
    status, _headers, _body = app.call(rack_env(method: "DELETE"))
    assert_equal 405, status
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
end
