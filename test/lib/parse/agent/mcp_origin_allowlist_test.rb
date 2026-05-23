# encoding: UTF-8
# frozen_string_literal: true

require "stringio"
require "json"
require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_rack_app"

# Unit tests for the MCP Origin allowlist and required custom header
# (CSRF defense for the JSON-RPC endpoint).
#
# - allowed_origins: refuses POSTs whose `Origin` header is not in the
#   allowlist. Empty / missing `Origin` is allowed regardless (browsers
#   always send Origin on cross-origin POST; native clients don't, and
#   we don't want to break curl / SDK-to-SDK).
# - require_custom_header: refuses POSTs that don't carry the named
#   header. Custom headers can't be set by a `<form>` CSRF and force a
#   CORS preflight on browser `fetch()`.
class TestMCPOriginAllowlist < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app-id",
                  api_key: "test-api-key")
    end
    # Stub the dispatcher so tests don't need a real Parse server.
    @original_call = Parse::Agent::MCPDispatcher.method(:call)
    Parse::Agent::MCPDispatcher.define_singleton_method(:call) do |body:, agent:, **_kw|
      { status: 200, body: { "jsonrpc" => "2.0", "id" => body["id"], "result" => {} } }
    end
  end

  def teardown
    if @original_call
      original = @original_call
      Parse::Agent::MCPDispatcher.define_singleton_method(:call, &original)
    end
  end

  def rack_env(origin: nil, headers: {})
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE"   => "application/json",
      "rack.input"     => StringIO.new('{"jsonrpc":"2.0","id":1,"method":"ping"}'),
    }
    env["HTTP_ORIGIN"] = origin if origin
    headers.each { |k, v| env["HTTP_#{k.upcase.tr("-", "_")}"] = v }
    env
  end

  def factory
    ->(_env) { Parse::Agent.new }
  end

  def build_app(**kwargs)
    Parse::Agent::MCPRackApp.new(agent_factory: factory, **kwargs)
  end

  # ---- allowed_origins ----------------------------------------------------

  def test_no_allowlist_configured_means_no_check
    app = build_app
    status, _headers, _body = app.call(rack_env(origin: "https://attacker.example.com"))
    assert_equal 200, status
  end

  def test_origin_matching_allowlist_is_accepted
    app = build_app(allowed_origins: ["https://app.example.com"])
    status, _h, _b = app.call(rack_env(origin: "https://app.example.com"))
    assert_equal 200, status
  end

  def test_origin_not_in_allowlist_is_refused
    app = build_app(allowed_origins: ["https://app.example.com"])
    status, _h, body = app.call(rack_env(origin: "https://attacker.example.com"))
    assert_equal 403, status
    assert_includes body.first, "Origin not allowed"
  end

  def test_origin_check_is_case_insensitive
    app = build_app(allowed_origins: ["https://App.Example.com"])
    status, _h, _b = app.call(rack_env(origin: "https://app.example.com"))
    assert_equal 200, status
  end

  def test_wildcard_origin_matches_subdomains
    app = build_app(allowed_origins: [".example.com"])
    %w[
      https://app.example.com
      https://files.example.com
      https://example.com
    ].each do |origin|
      status, _h, _b = app.call(rack_env(origin: origin))
      assert_equal 200, status, "should accept #{origin}"
    end
  end

  def test_wildcard_origin_does_not_match_unrelated_host
    app = build_app(allowed_origins: [".example.com"])
    status, _h, _b = app.call(rack_env(origin: "https://attacker-example.com"))
    assert_equal 403, status
  end

  def test_missing_origin_is_allowed_when_allowlist_configured
    # Native clients (curl, SDK) don't send Origin; the allowlist is a
    # browser-CSRF defense, not a transport-level requirement.
    app = build_app(allowed_origins: ["https://app.example.com"])
    status, _h, _b = app.call(rack_env)
    assert_equal 200, status
  end

  def test_empty_string_origin_is_allowed_when_allowlist_configured
    app = build_app(allowed_origins: ["https://app.example.com"])
    env = rack_env
    env["HTTP_ORIGIN"] = ""
    status, _h, _b = app.call(env)
    assert_equal 200, status
  end

  def test_empty_allowlist_array_is_treated_as_no_check
    app = build_app(allowed_origins: [])
    status, _h, _b = app.call(rack_env(origin: "https://attacker.example.com"))
    assert_equal 200, status
  end

  # ---- require_custom_header ---------------------------------------------

  def test_no_required_header_configured_means_no_check
    app = build_app
    status, _h, _b = app.call(rack_env)
    assert_equal 200, status
  end

  def test_required_header_missing_refused
    app = build_app(require_custom_header: "X-MCP-Client")
    status, _h, body = app.call(rack_env)
    assert_equal 403, status
    assert_includes body.first, "Required custom header"
  end

  def test_required_header_present_with_any_value_accepted
    app = build_app(require_custom_header: "X-MCP-Client")
    status, _h, _b = app.call(rack_env(headers: { "X-MCP-Client" => "anything" }))
    assert_equal 200, status
  end

  def test_required_header_with_expected_value_must_match
    app = build_app(require_custom_header: { "X-MCP-Client" => "my-app-v1" })
    status, _h, _b = app.call(rack_env(headers: { "X-MCP-Client" => "wrong" }))
    assert_equal 403, status

    status, _h, _b = app.call(rack_env(headers: { "X-MCP-Client" => "my-app-v1" }))
    assert_equal 200, status
  end

  def test_required_header_invalid_type_raises_at_construction
    assert_raises(ArgumentError) do
      build_app(require_custom_header: 12345)
    end
  end

  # ---- both gates compose -------------------------------------------------

  def test_origin_and_required_header_both_enforced
    app = build_app(allowed_origins: ["https://app.example.com"],
                    require_custom_header: "X-MCP-Client")
    # Wrong origin → 403 even with right header
    status, _h, _b = app.call(rack_env(origin: "https://attacker.example.com",
                                       headers: { "X-MCP-Client" => "ok" }))
    assert_equal 403, status

    # Right origin, missing header → 403
    status, _h, _b = app.call(rack_env(origin: "https://app.example.com"))
    assert_equal 403, status

    # Both correct → 200
    status, _h, _b = app.call(rack_env(origin: "https://app.example.com",
                                       headers: { "X-MCP-Client" => "ok" }))
    assert_equal 200, status
  end
end
