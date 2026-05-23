# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"
require "parse/agent/mcp_rack_app"

# NEW-MCP-6: MCPRackApp must (a) refuse obviously-malformed JSON-RPC
# bodies before invoking the agent_factory, and (b) honor an optional
# pre_auth_rate_limiter so a flood of bad requests cannot amplify into
# load on the Parse Server backend the factory typically calls.
class MCPPreAuthTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
    @factory_calls = 0
  end

  def factory_proc
    counter = method(:bump_factory_calls)
    ->(_env) {
      counter.call
      Parse::Agent.new(permissions: :readonly)
    }
  end

  def bump_factory_calls
    @factory_calls += 1
  end

  def post_env(body:, content_type: "application/json")
    {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => content_type,
      "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.input" => StringIO.new(body),
    }
  end

  def parse_response(rack_triple)
    status, headers, body_io = rack_triple
    payload = JSON.parse(body_io.join)
    [status, headers, payload]
  end

  # ==========================================================================
  # Body short-circuit
  # ==========================================================================

  def test_empty_json_object_short_circuits_before_factory
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory_proc)
    status, _hdrs, payload = parse_response(app.call(post_env(body: "{}")))
    assert_equal 400, status
    assert_equal(-32_600, payload.dig("error", "code"))
    assert_equal "Invalid Request", payload.dig("error", "message")
    assert_equal 0, @factory_calls, "agent_factory must NOT be called for empty body"
  end

  def test_missing_method_short_circuits_before_factory
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory_proc)
    body = JSON.generate("jsonrpc" => "2.0", "id" => 1, "params" => {})
    status, _hdrs, payload = parse_response(app.call(post_env(body: body)))
    assert_equal 400, status
    assert_equal(-32_600, payload.dig("error", "code"))
    assert_equal 0, @factory_calls
  end

  def test_blank_method_short_circuits_before_factory
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory_proc)
    body = JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "")
    status, _hdrs, payload = parse_response(app.call(post_env(body: body)))
    assert_equal 400, status
    assert_equal(-32_600, payload.dig("error", "code"))
    assert_equal 0, @factory_calls
  end

  def test_non_object_body_short_circuits_before_factory
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory_proc)
    body = JSON.generate([1, 2, 3])
    status, _hdrs, _payload = parse_response(app.call(post_env(body: body)))
    assert_equal 400, status
    assert_equal 0, @factory_calls
  end

  def test_well_formed_request_still_reaches_factory
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory_proc)
    body = JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => {})
    app.call(post_env(body: body))
    assert_equal 1, @factory_calls, "valid JSON-RPC must reach the agent_factory"
  end

  # ==========================================================================
  # pre_auth_rate_limiter
  # ==========================================================================

  class FakeLimiter
    attr_accessor :allow, :retry_after
    def initialize(allow: true, retry_after: 5)
      @allow = allow
      @retry_after = retry_after
      @calls = 0
    end
    attr_reader :calls
    def check!
      @calls += 1
      return true if @allow
      raise FakeRateError.new(retry_after: @retry_after)
    end
  end

  class FakeRateError < StandardError
    attr_reader :retry_after
    def initialize(retry_after:)
      @retry_after = retry_after
      super("limit")
    end
  end

  def test_initialize_rejects_pre_auth_limiter_without_check
    assert_raises(ArgumentError) do
      Parse::Agent::MCPRackApp.new(agent_factory: factory_proc, pre_auth_rate_limiter: Object.new)
    end
  end

  def test_pre_auth_limiter_runs_on_every_call_even_when_allowed
    limiter = FakeLimiter.new(allow: true)
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory_proc, pre_auth_rate_limiter: limiter)
    body = JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list")
    app.call(post_env(body: body))
    app.call(post_env(body: body))
    assert_equal 2, limiter.calls
  end

  def test_pre_auth_limiter_blocks_before_factory_on_exhaustion
    limiter = FakeLimiter.new(allow: false, retry_after: 7.4)
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory_proc, pre_auth_rate_limiter: limiter)
    body = JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list")
    status, headers, payload = parse_response(app.call(post_env(body: body)))
    assert_equal 429, status
    assert_equal "8", headers["Retry-After"]
    assert_equal "Too Many Requests", payload.dig("error", "message")
    assert_equal(-32_000, payload.dig("error", "code"))
    assert_equal 0, @factory_calls, "factory must NOT run after pre-auth 429"
  end

  def test_pre_auth_limiter_blocks_empty_body_before_short_circuit
    # Even malformed bodies must hit the limiter first — otherwise an
    # attacker spamming `{}` bypasses the per-IP throttle by never
    # touching JSON parse.
    limiter = FakeLimiter.new(allow: false)
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory_proc, pre_auth_rate_limiter: limiter)
    status, _hdrs, _payload = parse_response(app.call(post_env(body: "{}")))
    assert_equal 429, status
    assert_equal 1, limiter.calls
  end

  def test_pre_auth_limiter_omits_retry_after_when_unavailable
    err_klass = Class.new(StandardError)  # no #retry_after
    limiter = Object.new
    limiter.define_singleton_method(:check!) { raise err_klass, "boom" }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory_proc, pre_auth_rate_limiter: limiter)
    body = JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list")
    status, headers, _payload = parse_response(app.call(post_env(body: body)))
    assert_equal 429, status
    refute headers.key?("Retry-After"), "Retry-After must be omitted when limiter doesn't expose it"
  end

  def test_pre_auth_limiter_omits_retry_after_for_non_positive
    limiter = FakeLimiter.new(allow: false, retry_after: 0)
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory_proc, pre_auth_rate_limiter: limiter)
    body = JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list")
    _status, headers, _payload = parse_response(app.call(post_env(body: body)))
    refute headers.key?("Retry-After")
  end
end
