# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../lib/parse/live_query"

# 5.8.2 review follow-ups:
#   - Parse::File trusted-host check is not bypassed by scheme case or
#     malformed http(s) URLs; force_ssl upgrades HTTP:// too.
#   - Credential redaction covers MFA recovery codes and storage-form fields.
#   - The TLS guard refuses verify_mode NONE, verify_hostname false, and a
#     Faraday::SSLOptions value, not only a Hash with verify: false.
#   - Response error text is redacted and control characters escaped.
#   - MCP keys: Unicode whitespace is blank, an explicit blank key does not
#     hide MCP_API_KEY, and a public bind needs a long key.
#   - One loopback rule for Parse::Client and LiveQuery.
#   - http(s) LiveQuery URLs map to ws(s) at configure time and in the client.
#   - Webhook endpoint scheme checks ignore case and warn on public http.
#   - The cache bypass event carries cache_tenant; a client can override
#     cache_session_requests.

module Security582ReviewIsolation
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
end

class FileTrustedHostBypassTest < Minitest::Test
  def setup
    @prior_hosts = Parse::File.trusted_url_hosts.dup
    @prior_policy = Parse::File.untrusted_url_policy
    @prior_ssl = Parse::File.force_ssl
    Parse::File.trusted_url_hosts = ["files.example.com"]
    Parse::File.untrusted_url_policy = :raise
  end

  def teardown
    Parse::File.trusted_url_hosts = @prior_hosts
    Parse::File.untrusted_url_policy = @prior_policy
    Parse::File.force_ssl = @prior_ssl
  end

  def hydrate(url)
    Parse::File.new({ "__type" => "File", "name" => "a.png", "url" => url })
  end

  def test_scheme_case_and_malformed_urls_do_not_skip_the_allowlist
    [
      "https://evil.test/a.png",
      "HTTPS://evil.test/a.png",
      "Https://evil.test/a.png",
      "https:evil.test/a.png",
      "https:\\\\evil.test\\a.png",
      "https:///evil.test/a.png",
      " https://evil.test/a.png",
    ].each do |url|
      assert_raises(Parse::File::UntrustedHostError, "expected #{url.inspect} to be refused") { hydrate(url) }
    end
  end

  def test_strip_policy_clears_malformed_urls
    Parse::File.untrusted_url_policy = :strip
    capture_io { assert_nil hydrate("https:evil.test/a.png").url }
  end

  def test_trusted_host_and_non_url_values_still_pass
    assert_equal "HTTPS://files.example.com/a.png", hydrate("HTTPS://files.example.com/a.png").url
    assert_equal "files/a.png", hydrate("files/a.png").url
  end

  def test_force_ssl_upgrades_uppercase_http
    Parse::File.force_ssl = true
    assert_equal "https://files.example.com/a.png", hydrate("HTTP://files.example.com/a.png").url
  end
end

class CredentialRedactionCoverageTest < Minitest::Test
  def test_mfa_and_storage_form_fields_are_redacted
    payload = {
      "objectId" => "u1",
      "sessionToken" => "r:LIVE",
      "_session_token" => "r:S2",
      "recoveryCodes" => "RC",
      "recovery" => ["a", "b"],
      "secret" => "S",
      "mfa" => { "secret" => "TOTP" },
      "authDataResponse" => { "mfa" => { "recovery" => ["R1"] } },
      "_hashed_password" => "$2b$",
      "_perishable_token" => "pt",
      "_auth_data_facebook" => { "id" => "1" },
    }
    out = Parse::Response.new(payload).to_s
    %w[r:LIVE r:S2 RC TOTP R1 $2b$ pt].each { |secret| refute_includes out, secret }
    refute_match(/"S"/, out)
    assert_includes out, "u1"
  end

  def test_string_redaction_covers_prefixed_auth_data_columns
    assert_equal "_auth_data_github=[FILTERED]&x=1",
                 Parse::Middleware::BodyBuilder.redact("_auth_data_github=abc&x=1")
  end
end

class TlsVerificationGuardTest < Minitest::Test
  include Security582ReviewIsolation

  def build(ssl)
    capture_io do
      @c = Parse::Client.new(server_url: "https://prod.test/parse", application_id: "a", api_key: "k",
                             faraday: { ssl: ssl })
    end
    @c
  end

  def test_every_way_to_turn_verification_off_is_refused
    [
      { verify_mode: OpenSSL::SSL::VERIFY_NONE },
      { "verify_mode" => OpenSSL::SSL::VERIFY_NONE },
      { verify_hostname: false },
      { verify: false },
      Faraday::SSLOptions.new(false),
    ].each do |ssl|
      assert_raises(ArgumentError, "expected #{ssl.inspect} to be refused") { build(ssl) }
    end
  end

  def test_verification_on_is_accepted
    build({ verify: true, verify_mode: OpenSSL::SSL::VERIFY_PEER })
  end

  def connection_options_client(opts, **kw)
    capture_io do
      @c = Parse::Client.new(server_url: "https://prod.test/parse", application_id: "a", api_key: "k",
                             faraday: opts, **kw)
    end
    @c
  end

  def test_connection_options_are_checked_like_a_hash
    err = assert_raises(ArgumentError) do
      connection_options_client(Faraday::ConnectionOptions.new(ssl: { verify: false }))
    end
    assert_match(/TLS certificate verification/, err.message)
    err = assert_raises(ArgumentError) do
      connection_options_client(Faraday::ConnectionOptions.new(proxy: "http://attacker"))
    end
    assert_match(/proxy/, err.message)
    # Accepted options still apply, and env proxy discovery stays off.
    client = connection_options_client(Faraday::ConnectionOptions.new(ssl: { verify: true }))
    conn = client.instance_variable_get(:@conn)
    assert conn.ssl.verify?
    assert_nil conn.proxy
  end

  def test_other_faraday_option_types_are_refused
    assert_raises(ArgumentError) { connection_options_client("ssl=off") }
  end
end

class ResponseErrorTextTest < Minitest::Test
  def test_error_text_is_redacted_and_control_characters_escaped
    resp = Parse::Response.new({ "code" => 101, "error" => "bad sessionToken=r:LEAK\e[31m\nforged" })
    [resp.to_s, resp.inspect].each do |text|
      refute_includes text, "r:LEAK"
      refute_includes text, "\e"
      refute_includes text, "\n"
    end
  end
end

class MCPApiKeyReviewTest < Minitest::Test
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

  def test_unicode_whitespace_is_blank
    assert_nil Parse::Agent::MCPServer.normalize_api_key("  ")
    assert_equal "k" * 20, Parse::Agent::MCPServer.normalize_api_key(" #{"k" * 20} ")
    assert_raises(ArgumentError) { Parse::Agent::MCPServer.new(host: "0.0.0.0", api_key: " ") }
  end

  def test_explicit_blank_key_does_not_hide_the_env_key
    ENV["MCP_API_KEY"] = "env-key-0123456789"
    server = Parse::Agent::MCPServer.new(host: "127.0.0.1", api_key: "  ")
    assert_equal "env-key-0123456789", server.instance_variable_get(:@api_key)
  end

  def test_public_bind_warns_on_a_short_key
    _out, err = capture_io { Parse::Agent::MCPServer.new(host: "0.0.0.0", api_key: "short") }
    assert_match(/shorter than 16/, err)
    _out, err = capture_io { Parse::Agent::MCPServer.new(host: "0.0.0.0", api_key: "x" * 16) }
    refute_match(/shorter than 16/, err)
    _out, err = capture_io { Parse::Agent::MCPServer.new(host: "127.0.0.1", api_key: "short") }
    refute_match(/shorter than 16/, err)
  end
end

class LoopbackHostRuleTest < Minitest::Test
  def test_loopback_hosts
    # 0.0.0.0 stays local for client URLs (a connect to it reaches this host).
    %w[localhost LOCALHOST 127.0.0.1 127.0.0.2 127.9.9.9 ::1 [::1] 0.0.0.0].each do |h|
      assert Parse::Client.loopback_host?(h), "#{h} should be loopback"
    end
    # Malformed addresses go to a resolver by name; a trailing-dot localhost
    # can skip /etc/hosts.
    ["10.0.0.1", "example.com", "127.0.0.1.evil.test", "127.999.1.1", "localhost.",
     "127.1", "0x7f000001", "", nil].each do |h|
      refute Parse::Client.loopback_host?(h), "#{h.inspect} should not be loopback"
    end
  end

  def test_live_query_accepts_any_127_address_for_ws
    assert_equal "ws://127.0.0.5:1337", Parse::LiveQuery::Client.normalize_url("ws://127.0.0.5:1337")
  end
end

class LiveQueryHttpMappingTest < Minitest::Test
  include Security582ReviewIsolation

  def setup
    super
    Parse::LiveQuery::Client.instance_variable_set(:@warned_http_schemes, nil)
  end

  def test_normalize_url_maps_http_schemes
    _out, err = capture_io do
      assert_equal "ws://localhost:1337", Parse::LiveQuery::Client.normalize_url("http://localhost:1337")
      assert_equal "wss://prod.example.com", Parse::LiveQuery::Client.normalize_url("https://prod.example.com")
    end
    assert_match(/DEPRECATION/, err)
    assert_raises(ArgumentError) { Parse::LiveQuery::Client.normalize_url("http://prod.example.com") }
    capture_io do
      assert_equal "ws://prod.example.com",
                   Parse::LiveQuery::Client.normalize_url("http://prod.example.com", allow_insecure: true)
    end
  end

  def test_configure_time_check_maps_and_refuses
    capture_io do
      Parse::Client.new(server_url: "https://api.example.com/parse", application_id: "a", api_key: "k",
                        live_query_url: "https://lq.example.com")
    end
    assert_equal "wss://lq.example.com", Parse::LiveQuery.config.url
    assert_raises(ArgumentError) do
      capture_io do
        Parse::Client.new(server_url: "https://api.example.com/parse", application_id: "a", api_key: "k",
                          live_query_url: "ftp://lq.example.com")
      end
    end
    assert_raises(ArgumentError) do
      capture_io do
        Parse::Client.new(server_url: "https://api.example.com/parse", application_id: "a", api_key: "k",
                          live_query_url: "http://lq.example.com")
      end
    end
  end
end

class WebhookEndpointSchemeTest < Minitest::Test
  def test_endpoint_scheme_ignores_case_and_rejects_malformed
    assert_equal "HTTPS://hooks.example.com/w", Parse::Webhooks.validate_hooks_endpoint!(" HTTPS://hooks.example.com/w ")
    ["https:hooks.example.com", "ftp://hooks.example.com", "", nil].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { Parse::Webhooks.validate_hooks_endpoint!(bad) }
    end
  end

  def test_public_http_endpoint_warns
    _out, err = capture_io { Parse::Webhooks.validate_hooks_endpoint!("http://hooks.example.com/w") }
    assert_match(/cleartext/, err)
    _out, err = capture_io { Parse::Webhooks.validate_hooks_endpoint!("http://localhost:3000/w") }
    refute_match(/cleartext/, err)
  end
end

class CacheReviewFollowupTest < Minitest::Test
  include Parse::Protocol

  SERVER = "https://test.parse/parse"
  PATH = "/parse/classes/Post"

  def setup
    @store = Moneta.new(:Memory, expires: true)
    @prior_enabled = Parse::Middleware::Caching.enabled
    @prior_session = Parse::Middleware::Caching.cache_session_requests
    Parse::Middleware::Caching.enabled = true
    Parse::Middleware::Caching.cache_session_requests = false
  end

  def teardown
    @store.clear
    Parse::Middleware::Caching.enabled = @prior_enabled
    Parse::Middleware::Caching.cache_session_requests = @prior_session
  end

  def conn(opts = {})
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(PATH) do
        body = '{"results":[{"objectId":"p1"}]}'
        [200, { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }, body]
      end
    end
    Faraday.new(url: SERVER) do |f|
      f.use Parse::Middleware::Caching, @store, { expires: 60 }.merge(opts)
      f.adapter :test, stubs
    end
  end

  def session_get(c)
    r = c.get(PATH) { |req| req.headers[APP_ID] = "app"; req.headers[SESSION_TOKEN] = "r:abc" }
    r.headers["X-Cache-Response"] == "true"
  end

  def test_bypass_event_carries_cache_tenant
    skip "cache tenants unavailable" unless Parse.respond_to?(:with_cache_tenant)
    events = []
    sub = ActiveSupport::Notifications.subscribe("parse.cache.bypass") { |*args| events << args.last }
    Parse.with_cache_tenant("t1") { session_get(conn) }
    assert_equal "t1", events.last[:cache_tenant]
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  def test_per_client_override_in_both_directions
    c = conn(cache_session_requests: true)
    session_get(c)
    assert session_get(c), "a client opted in caches session reads"
    Parse::Middleware::Caching.cache_session_requests = true
    c2 = conn(cache_session_requests: false)
    session_get(c2)
    refute session_get(c2), "a client opted out never caches session reads"
  end

  def test_string_true_does_not_enable
    Parse::Middleware::Caching.cache_session_requests = "true"
    refute Parse::Middleware::Caching.cache_session_requests
  end
end
