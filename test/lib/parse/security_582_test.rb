# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/parse/live_query"

# 5.8.2 security fixes:
#   SEC-03  a whitespace-only MCP API key counts as no key everywhere.
#   SEC-09  scheme checks compare case-insensitively (HTTP:// is plain http).
#   SEC-10  every LiveQuery client URL is validated, not only derived ones.
#   SEC-17  Parse::Response#inspect / #to_s never print credentials.

# Saves and restores the registered clients and LiveQuery config, so a
# Parse::Client built here never becomes another test's default.
module Security582ClientIsolation
  def setup
    super
    @saved_clients = Parse::Client.instance_variable_get(:@clients)
    Parse::Client.instance_variable_set(:@clients, {})
    Parse::LiveQuery.reset!
    Parse::LiveQuery.instance_variable_set(:@config, nil)
  end

  def teardown
    Parse::Client.instance_variable_set(:@clients, @saved_clients)
    Parse::LiveQuery.reset!
    Parse::LiveQuery.instance_variable_set(:@config, nil)
    super
  end

  def build_client(**opts)
    capture_io do
      @built = Parse::Client.new({ application_id: "a", api_key: "k" }.merge(opts))
    end
    @built
  end
end

class MCPApiKeyNormalizationTest < Minitest::Test
  def setup
    @saved_env = ENV.delete("MCP_API_KEY")
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse", application_id: "test", api_key: "test")
    end
    require_relative "../../../lib/parse/agent/mcp_server" unless defined?(Parse::Agent::MCPServer)
  end

  def teardown
    ENV.delete("MCP_API_KEY")
    ENV["MCP_API_KEY"] = @saved_env if @saved_env
  end

  def test_whitespace_only_key_refuses_a_public_bind
    ["   ", "\t", " \n "].each do |blank|
      err = assert_raises(ArgumentError) { Parse::Agent::MCPServer.new(host: "0.0.0.0", api_key: blank) }
      assert_match(/non-loopback/, err.message)
    end
  end

  def test_whitespace_only_env_key_refuses_a_public_bind
    ENV["MCP_API_KEY"] = "   "
    assert_raises(ArgumentError) { Parse::Agent::MCPServer.new(host: "0.0.0.0") }
  end

  def test_whitespace_only_key_on_loopback_is_no_key
    server = capture_io { @s = Parse::Agent::MCPServer.new(host: "127.0.0.1", api_key: "   ") } && @s
    assert_nil server.instance_variable_get(:@api_key)
  end

  def test_padded_key_is_enforced_without_its_padding
    server = Parse::Agent::MCPServer.new(host: "0.0.0.0", api_key: "  secret-0123456789  ")
    assert_equal "secret-0123456789", server.instance_variable_get(:@api_key)
    err = assert_raises(Parse::Agent::Unauthorized) do
      server.send(:agent_factory, { "HTTP_X_MCP_API_KEY" => "wrong" })
    end
    assert_equal :bad_api_key, err.reason
    assert_raises(Parse::Agent::Unauthorized) { server.send(:agent_factory, { "HTTP_X_MCP_API_KEY" => "   " }) }
    assert_raises(Parse::Agent::Unauthorized) { server.send(:agent_factory, {}) }
  end

  def test_normalize_api_key
    assert_nil Parse::Agent::MCPServer.normalize_api_key(nil)
    assert_nil Parse::Agent::MCPServer.normalize_api_key("  ")
    assert_equal "k", Parse::Agent::MCPServer.normalize_api_key(" k ")
  end
end

class SchemeCaseInsensitivityTest < Minitest::Test
  include Security582ClientIsolation

  def test_uppercase_http_is_refused_under_require_https
    ["HTTP://api.example.com/parse", "Http://api.example.com/parse", "  http://api.example.com/parse"].each do |url|
      err = assert_raises(ArgumentError) { build_client(server_url: url, require_https: true) }
      assert_match(/HTTPS required/, err.message)
    end
  end

  def test_uppercase_http_warns_without_require_https
    _out, err = capture_io { Parse::Client.new(server_url: "HTTP://api.example.com/parse", application_id: "a", api_key: "k") }
    assert_match(/SECURITY WARNING/, err)
  end

  def test_https_in_any_case_is_accepted
    build_client(server_url: "Https://api.example.com/parse", require_https: true)
    build_client(server_url: "HTTPS://api.example.com/parse", require_https: true)
    pass
  end

  def test_loopback_http_stays_allowed_in_any_case
    build_client(server_url: "HTTP://localhost:1337/parse", require_https: true)
    build_client(server_url: "http://127.0.0.1:1337/parse", require_https: true)
    pass
  end

  def test_tls_verify_off_is_refused_on_uppercase_https
    assert_raises(ArgumentError) do
      build_client(server_url: "HTTPS://api.example.com/parse", faraday: { ssl: { verify: false } })
    end
  end

  def test_uppercase_ws_live_query_url_is_refused_on_a_routable_host
    assert_raises(ArgumentError) do
      build_client(server_url: "https://api.example.com/parse", live_query_url: "WS://prod.example.com:1337")
    end
  end

  def test_url_scheme_helper
    assert_equal "http", Parse::Client.url_scheme(" HTTP://x.com ")
    assert_equal "wss", Parse::Client.url_scheme("WsS://x")
    assert_nil Parse::Client.url_scheme(nil)
    assert_nil Parse::Client.url_scheme("http://exa mple.com")
  end
end

class LiveQueryUrlValidationTest < Minitest::Test
  include Security582ClientIsolation

  def lq(url)
    Parse::LiveQuery::Client.new(url: url, application_id: "a", client_key: "k",
                                 master_key: nil, auto_connect: false)
  end

  def test_explicit_plaintext_url_on_a_routable_host_is_refused
    ["ws://prod.example.com:1337", "WS://prod.example.com:1337", " ws://prod.example.com "].each do |url|
      err = assert_raises(ArgumentError) { lq(url) }
      assert_match(/insecure ws:/, err.message)
    end
  end

  def test_non_websocket_scheme_is_refused
    err = assert_raises(ArgumentError) { lq("ftp://prod.example.com") }
    assert_match(/must use wss/, err.message)
  end

  # http(s) LiveQuery URLs are mapped to ws(s) with a deprecation warning
  # instead of refused, so harmless local configs keep working.
  def test_http_schemes_map_to_websocket_schemes
    Parse::LiveQuery::Client.instance_variable_set(:@warned_http_schemes, nil)
    _out, err = capture_io do
      assert_equal "ws://localhost:1337", lq("http://localhost:1337").url
      assert_equal "wss://prod.example.com/lq", lq("HTTPS://prod.example.com/lq").url
    end
    assert_match(/DEPRECATION.*http:\/\/.*ws:\/\//, err)
    assert_match(/DEPRECATION.*https:\/\/.*wss:\/\//, err)
    err = assert_raises(ArgumentError) { lq("http://prod.example.com") }
    assert_match(/insecure ws:/, err.message)
  end

  def test_secure_and_loopback_urls_are_accepted
    assert_equal "wss://prod.example.com", lq("wss://prod.example.com").url
    assert_equal "wss://prod.example.com", lq("WSS://prod.example.com").url
    assert_equal "ws://localhost:1337", lq("ws://localhost:1337").url
    assert_equal "ws://127.0.0.1:1337", lq("ws://127.0.0.1:1337").url
  end

  def test_configured_url_is_validated_too
    Parse::LiveQuery.configure { |c| c.url = "ws://prod.example.com:1337" }
    assert_raises(ArgumentError) do
      Parse::LiveQuery::Client.new(application_id: "a", client_key: "k", master_key: nil, auto_connect: false)
    end
  end

  def test_allow_insecure_permits_plaintext_with_a_warning
    Parse::LiveQuery.configure { |c| c.allow_insecure = true }
    _out, err = capture_io { lq("ws://prod.example.com:1337") }
    assert_match(/insecure ws:/, err)
  end
end

class ResponseRedactionTest < Minitest::Test
  def login_response
    Parse::Response.new({ "objectId" => "u1", "username" => "alice", "sessionToken" => "r:live-secret",
                          "authData" => { "anonymous" => { "id" => "anon-secret" } } })
  end

  def test_inspect_never_prints_result_values
    out = login_response.inspect
    refute_includes out, "r:live-secret"
    refute_includes out, "anon-secret"
    refute_includes out, "alice"
    assert_match(/Hash\(4 keys\)/, out)
  end

  def test_to_s_redacts_credentials_but_keeps_other_fields
    out = login_response.to_s
    refute_includes out, "r:live-secret"
    refute_includes out, "anon-secret"
    assert_includes out, "alice"
    assert_includes out, "[FILTERED]"
  end

  def test_redaction_reaches_array_results
    resp = Parse::Response.new({ "results" => [{ "objectId" => "s1", "sessionToken" => "r:row-secret" }] })
    refute_includes resp.inspect, "r:row-secret"
    refute_includes resp.to_s, "r:row-secret"
  end

  def test_raw_result_is_untouched
    resp = login_response
    resp.to_s
    resp.inspect
    assert_equal "r:live-secret", resp.result["sessionToken"]
  end
end
