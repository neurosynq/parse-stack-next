# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/client/authentication"
require "parse/agent"
require "parse/agent/mcp_rack_app"
require "moneta"

# Regression coverage for the user / session / cache audit findings. Every
# test runs in-process: requests are captured by a stub connection (and,
# where the wire matters, fed through the real Authentication middleware),
# and the cache tests drive the real caching middleware over a memory store.
class SessionAuditTest < Minitest::Test
  include Parse::Protocol

  MASTER = "configured-master-key"
  REST = "test-rest"
  APP = "test-app"
  DISABLE = Parse::Middleware::Authentication::DISABLE_MASTER_KEY

  # Records each request and answers from a handler. The default handler
  # resolves `users/me` from a token table so identity resolution can be
  # observed, and answers everything else with an empty success.
  class FakeConn
    attr_reader :calls
    attr_accessor :handler

    def initialize(tokens = {})
      @calls = []
      @tokens = tokens
      @handler = nil
    end

    def send(method, uri, params, headers)
      @calls << { method: method, uri: uri, params: params, headers: headers.dup }
      status, body = @handler ? @handler.call(method, uri, params, headers) : default(uri, headers)
      resp = Parse::Response.new(body)
      resp.http_status = status
      Struct.new(:body).new(resp)
    end

    def default(uri, headers)
      if uri.to_s == "users/me"
        uid = @tokens[headers[Parse::Protocol::SESSION_TOKEN]]
        return [400, { "code" => 209, "error" => "Invalid session token" }] if uid.nil?
        return [200, { "objectId" => uid, "username" => "u_#{uid}" }]
      end
      [200, {}]
    end
  end

  class FakeResponse
    def on_complete; yield(nil) if block_given?; self; end
  end

  def setup
    @prior_client_mode = Parse.client_mode
  end

  def teardown
    Parse.client_mode = @prior_client_mode
  end

  def build_client(session_token: nil, master_key: MASTER, tokens: {})
    client = Parse::Client.new(
      server_url: "http://localhost:1337/parse",
      app_id: APP, api_key: REST,
      master_key: master_key, session_token: session_token, logging: false,
    )
    @conn = FakeConn.new(tokens)
    client.instance_variable_set(:@conn, @conn)
    client
  end

  # The headers that would reach the wire after the Authentication middleware.
  def wire(headers)
    final = nil
    mw = Parse::Middleware::Authentication.new(
      ->(env) { final = env[:request_headers]; FakeResponse.new },
      application_id: APP, api_key: REST, master_key: MASTER,
    )
    mw.call({ request_headers: headers.dup })
    final
  end

  def last_headers
    @conn.calls.last[:headers]
  end

  def assert_unauthenticated(headers, label)
    assert_equal "true", headers[DISABLE], "#{label}: master key must be disabled"
    refute headers.key?(SESSION_TOKEN), "#{label}: no session token may be attached"
    refute wire(headers).key?(MASTER_KEY), "#{label}: master key must not reach the wire"
  end

  # ---- U1 / U11: credential endpoints never carry the master key ----------

  def test_login_is_sent_without_master_key_or_ambient_token
    client = build_client(session_token: "r:bound")
    Parse.with_session("r:ambient") { client.login("alice", "pw") }
    assert_unauthenticated(last_headers, "login")
  end

  def test_login_ignores_an_explicit_master_key_request
    client = build_client
    client.login("alice", "pw", use_master_key: true)
    assert_unauthenticated(last_headers, "login(use_master_key: true)")
  end

  def test_mfa_login_is_sent_without_master_key
    client = build_client
    Parse.with_session("r:ambient") { client.login_with_mfa("alice", "pw", "123456") }
    assert_unauthenticated(last_headers, "login_with_mfa")
    assert_equal({ token: "123456" }, @conn.calls.last[:params][:authData][:mfa])
  end

  def test_other_body_authenticated_endpoints_are_unauthenticated
    client = build_client(session_token: "r:bound")
    client.verify_password("alice", "pw")
    assert_unauthenticated(last_headers, "verify_password")
    client.request_password_reset("a@example.com")
    assert_unauthenticated(last_headers, "request_password_reset")
    client.request_email_verification("a@example.com")
    assert_unauthenticated(last_headers, "request_email_verification")
  end

  def test_signup_defaults_to_no_master_key
    client = build_client
    Parse.with_session("r:ambient") { client.create_user({ username: "alice", password: "pw" }) }
    h = last_headers
    refute h.key?(SESSION_TOKEN), "an ambient session must not ride along on a signup"
    assert_equal "true", h[DISABLE]
    refute wire(h).key?(MASTER_KEY), "signup must not send the master key by default"
    assert_equal "1", h[REVOCABLE_SESSION]
  end

  def test_signup_honors_an_explicit_master_key
    client = build_client
    client.create_user({ username: "alice", password: "pw" }, use_master_key: true)
    assert wire(last_headers).key?(MASTER_KEY), "explicit use_master_key: true is still honored"
  end

  def test_logout_sends_the_token_without_master_key
    client = build_client(session_token: "r:bound")
    Parse.with_session("r:ambient") { client.logout("r:target") }
    h = last_headers
    assert_equal "r:target", h[SESSION_TOKEN]
    assert_equal "true", h[DISABLE]
  end

  # ---- U4: with_session(nil) is anonymous --------------------------------

  def test_with_session_nil_sends_neither_token_nor_master_key
    client = build_client(session_token: "r:bound")
    Parse.with_session(nil) { client.request(:get, "classes/Thing") }
    assert_unauthenticated(last_headers, "with_session(nil)")
  end

  def test_tokenless_user_block_is_anonymous
    client = build_client
    user = Parse::User.new("objectId" => "UA0000000A", "username" => "alice")
    Parse.with_session(user) { client.request(:get, "classes/Thing") }
    assert_unauthenticated(last_headers, "with_session(tokenless user)")
  end

  def test_anonymous_block_inside_a_session_block
    client = build_client
    Parse.with_session("r:outer") do
      Parse.with_session(nil) do
        client.request(:get, "classes/Thing")
        assert_unauthenticated(last_headers, "nested nil")
        assert_nil Parse.current_session_token
        assert Parse.anonymous_session?
        Parse.with_session("r:inner") do
          client.request(:get, "classes/Thing")
          assert_equal "r:inner", last_headers[SESSION_TOKEN]
          refute Parse.anonymous_session?
        end
        assert Parse.anonymous_session?, "inner block restores the anonymous state"
      end
      assert_equal "r:outer", Parse.current_session_token
      refute Parse.anonymous_session?
      client.request(:get, "classes/Thing")
      assert_equal "r:outer", last_headers[SESSION_TOKEN]
    end
    refute Parse.anonymous_session?
    client.request(:get, "classes/Thing")
    assert wire(last_headers).key?(MASTER_KEY), "outside any block the master fallback is unchanged"
  end

  def test_anonymous_block_restores_after_a_raise
    assert_raises(RuntimeError) { Parse.with_session(nil) { raise "boom" } }
    refute Parse.anonymous_session?
  end

  def test_explicit_opt_outs_inside_an_anonymous_block
    client = build_client
    Parse.with_session(nil) do
      client.request(:get, "classes/Thing", opts: { use_master_key: true })
      assert wire(last_headers).key?(MASTER_KEY), "explicit use_master_key: true is honored"
      client.request(:get, "classes/Thing", opts: { session_token: "r:explicit" })
      assert_equal "r:explicit", last_headers[SESSION_TOKEN]
    end
  end

  # ---- U3: an explicit token header is not overwritten --------------------

  def test_current_user_token_wins_over_ambient_session
    client = build_client(tokens: { "r:ta" => "UA", "r:tb" => "UB" })
    resp = Parse.with_session("r:tb") { client.current_user("r:ta") }
    assert_equal "r:ta", last_headers[SESSION_TOKEN]
    assert_equal "UA", resp.result["objectId"]
  end

  def test_current_user_token_wins_over_bound_session
    client = build_client(session_token: "r:tb", tokens: { "r:ta" => "UA", "r:tb" => "UB" })
    resp = client.current_user("r:ta")
    assert_equal "UA", resp.result["objectId"]
  end

  def test_fetch_session_token_wins_over_ambient_session
    client = build_client
    Parse.with_session("r:tb") { client.fetch_session("r:ta") }
    assert_equal "r:ta", last_headers[SESSION_TOKEN]
  end

  def test_raw_session_header_wins_over_ambient_session
    client = build_client
    Parse.with_session("r:tb") do
      client.request(:get, "classes/Thing", headers: { SESSION_TOKEN => "r:ta" })
    end
    assert_equal "r:ta", last_headers[SESSION_TOKEN]
  end

  def test_blank_current_user_token_is_not_replaced_by_ambient
    client = build_client(tokens: { "r:tb" => "UB" })
    Parse.with_session("r:tb") do
      assert_raises(Parse::Error::InvalidSessionTokenError) { client.current_user("") }
    end
    refute last_headers.key?(SESSION_TOKEN)
    assert_equal "true", last_headers[DISABLE]
  end

  def test_identity_cache_is_not_poisoned_under_an_ambient_session
    client = build_client(tokens: { "r:ta" => "UA", "r:tb" => "UB" })
    Parse.with_session("r:tb") do
      assert_equal "UA", client.authorization.resolve("r:ta").user_id
      assert_raises(Parse::Authorization::InvalidSession) do
        client.authorization.resolve("r:garbage")
      end
    end
    assert_nil client.authorization.identity_cache.get("r:garbage")
    assert_equal "UA", client.authorization.identity_cache.get("r:ta")
  end

  def test_user_session_inside_with_session_returns_the_token_owner
    client = build_client(tokens: { "r:ta" => "UA", "r:tb" => "UB" })
    Parse::User.stub(:client, client) do
      u = Parse.with_session("r:tb") { Parse::User.session("r:ta") }
      assert_equal "UA", u.id
      assert_nil(Parse.with_session("r:tb") { Parse::User.session("r:garbage") })
    end
  end

  # ---- U5: revocation reaches the identity plane --------------------------

  def test_logout_evicts_the_identity_entry
    client = build_client(tokens: { "r:ta" => "UA" })
    client.authorization.resolve("r:ta")
    refute_nil client.authorization.identity_cache.get("r:ta")
    client.logout("r:ta")
    assert_nil client.authorization.identity_cache.get("r:ta")
  end

  def test_invalidate_user_drops_every_token_of_the_user
    ctx = build_client.authorization
    ctx.identity_cache.set("r:a1", "UA", ttl: 60)
    ctx.identity_cache.set("r:a2", "UA", ttl: 60)
    ctx.identity_cache.set("r:b1", "UB", ttl: 60)
    ctx.invalidate_user("UA")
    assert_nil ctx.identity_cache.get("r:a1")
    assert_nil ctx.identity_cache.get("r:a2")
    assert_equal "UB", ctx.identity_cache.get("r:b1")
  end

  def test_invalidate_user_bumps_a_generation_capable_plane
    bumped = []
    plane = Object.new
    plane.define_singleton_method(:generation) { |_u| 0 }
    plane.define_singleton_method(:generation_current?) { |_u, _g| true }
    plane.define_singleton_method(:bump_generation) { |u| bumped << u }
    ctx = build_client.authorization
    ctx.identity_cache = plane
    ctx.invalidate_user("UA")
    assert_equal ["UA"], bumped
  end

  def test_password_change_and_delete_through_the_api_evict_the_user
    client = build_client
    ctx = client.authorization
    ctx.identity_cache.set("r:a1", "UA0000000A", ttl: 60)
    client.update_user("UA0000000A", { username: "renamed" })
    refute_nil ctx.identity_cache.get("r:a1"), "a non-password update leaves sessions alone"
    client.update_user("UA0000000A", { password: "new" })
    assert_nil ctx.identity_cache.get("r:a1")

    ctx.identity_cache.set("r:a2", "UA0000000A", ttl: 60)
    client.delete_user("UA0000000A")
    assert_nil ctx.identity_cache.get("r:a2")
  end

  def test_user_model_password_save_and_destroy_evict_the_user
    client = build_client
    ctx = client.authorization
    @conn.handler = ->(_m, _u, _p, _h) { [200, { "updatedAt" => "2026-01-01T00:00:00.000Z" }] }
    user = Parse::User.build({ "objectId" => "UA0000000A", "username" => "alice",
                               "createdAt" => "2026-01-01T00:00:00.000Z", "updatedAt" => "2026-01-01T00:00:00.000Z" })
    user.stub(:client, client) do
      ctx.identity_cache.set("r:a1", "UA0000000A", ttl: 60)
      user.password = "new-password"
      assert user.save
      assert_nil ctx.identity_cache.get("r:a1"), "password change must evict"

      ctx.identity_cache.set("r:a2", "UA0000000A", ttl: 60)
      assert user.destroy
      assert_nil ctx.identity_cache.get("r:a2"), "account deletion must evict"
    end
  end

  def test_session_destroy_evicts_the_token_and_the_owner
    client = build_client
    ctx = client.authorization
    ctx.identity_cache.set("r:s1", "UA0000000A", ttl: 60)
    ctx.identity_cache.set("r:s2", "UA0000000A", ttl: 60)
    session = Parse::Session.build({ "objectId" => "S000000001", "sessionToken" => "r:s1",
                                     "createdAt" => "2026-01-01T00:00:00.000Z", "updatedAt" => "2026-01-01T00:00:00.000Z",
                                     "user" => { "__type" => "Pointer", "className" => "_User", "objectId" => "UA0000000A" } })
    session.stub(:client, client) { assert session.destroy }
    assert_nil ctx.identity_cache.get("r:s1")
    assert_nil ctx.identity_cache.get("r:s2")
  end

  # ---- U12: MFA login errors are typed ------------------------------------

  def test_missing_mfa_raises_required_error_not_service_unavailable
    client = build_client
    @conn.handler = ->(*) { [400, { "code" => -1, "error" => "Missing additional authData mfa" }] }
    assert_raises(Parse::MFA::RequiredError) { client.login("alice", "pw") }
    assert_equal 1, @conn.calls.size, "a 400 must not be retried"
  end

  def test_other_cause_without_mfa_text_still_maps_as_before
    client = build_client
    @conn.handler = ->(*) { [500, { "code" => 1, "error" => "boom" }] }
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:get, "classes/Thing", opts: { retry: false })
    end
  end

  def test_wrong_mfa_code_raises_verification_error
    client = build_client
    @conn.handler = ->(*) { [400, { "code" => 141, "error" => "Invalid MFA token" }] }
    Parse::User.stub(:client, client) do
      assert_raises(Parse::MFA::VerificationError) do
        Parse::User.login_with_mfa("alice", "pw", "000000")
      end
    end
  end

  def test_wrong_password_on_mfa_login_returns_nil
    client = build_client
    @conn.handler = ->(*) { [400, { "code" => 101, "error" => "Invalid username/password." }] }
    Parse::User.stub(:client, client) do
      assert_nil Parse::User.login_with_mfa("alice", "bad", "123456")
    end
  end

  # ---- U9: a revoked token is a rejection, not an outage ------------------

  def test_mcp_session_check_rejects_a_revoked_token
    client = build_client(tokens: { "r:live" => "UA" })
    client.authorization.identity_cache.set("r:revoked", "UA", ttl: 60)
    err = assert_raises(Parse::Agent::Unauthorized) do
      Parse::Agent::MCPRackApp.validate_session!(client, "r:revoked", mode: :per_request)
    end
    assert_equal :invalid_session, err.reason
    assert_nil client.authorization.identity_cache.get("r:revoked"), "the rejected token is evicted"
    assert_equal "UA", Parse::Agent::MCPRackApp.validate_session!(client, "r:live", mode: :per_request)
  end

  def test_mcp_session_check_still_treats_an_outage_as_unavailable
    client = build_client
    @conn.handler = ->(*) { [503, { "code" => 2, "error" => "down" }] }
    client.retry_limit = 0 if client.respond_to?(:retry_limit=)
    assert_raises(Parse::Agent::MCPRackApp::SessionCheckUnavailable) do
      Parse::Agent::MCPRackApp.validate_session!(client, "r:any", mode: :per_request)
    end
  end

  # ---- U10 (schema half): schema reads ask for the master key -------------

  def test_schema_fetch_ignores_the_ambient_session
    client = build_client
    Parse.with_session("r:ambient") { client.schema("Thing") }
    h = last_headers
    refute h.key?(SESSION_TOKEN)
    assert wire(h).key?(MASTER_KEY)
  end

  def test_schema_fetch_respects_client_mode
    client = build_client
    Parse.client_mode = true
    client.schema("Thing")
    assert_equal "true", last_headers[DISABLE]
  end

  # ---- U13: token redaction -----------------------------------------------

  def test_user_inspect_redacts_the_session_token
    user = Parse::User.new("objectId" => "UA0000000A", "username" => "alice")
    user.session_token = "r:secret-token-value"
    refute_includes user.inspect, "r:secret-token-value"
    assert_includes user.inspect, "[FILTERED]"
  end

  def test_session_inspect_and_as_json_redact_the_token
    s = Parse::Session.build({ "objectId" => "S000000001", "sessionToken" => "r:secret-token-value",
                               "createdAt" => "2026-01-01T00:00:00.000Z", "updatedAt" => "2026-01-01T00:00:00.000Z" })
    refute_includes s.inspect, "r:secret-token-value"
    refute_includes s.as_json.to_s, "r:secret-token-value"
    refute_includes s.to_json, "r:secret-token-value"
    assert_includes s.as_json(include_session_token: true).to_s, "r:secret-token-value"
    assert_equal "r:secret-token-value", s.session_token, "the accessor is unaffected"
  end
end

# Drives the caching middleware over a memory store with the headers the
# Authentication middleware would have stamped.
class SessionAuditCacheTest < Minitest::Test
  include Parse::Protocol

  SERVER = "https://test.parse/parse"

  def setup
    @store = Moneta.new(:Memory, expires: true)
    @prior_enabled = Parse::Middleware::Caching.enabled
    Parse::Middleware::Caching.enabled = true
    @hits = 0
  end

  def teardown
    @store.clear
    Parse::Middleware::Caching.enabled = @prior_enabled
  end

  def request(path, headers, method: :get, body: '{"results":["fresh-from-server"]}')
    padded = body.ljust(20)
    calls = (@server_calls ||= Hash.new(0))
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.send(method, path) do |_|
        calls[path] += 1
        [200, { "Content-Type" => "application/json", "Content-Length" => padded.bytesize.to_s }, padded]
      end
    end
    conn = Faraday.new(url: SERVER) do |f|
      f.use Parse::Middleware::Caching, @store, { expires: 60 }
      f.adapter :test, stubs
    end
    resp = conn.send(method, path) { |req| headers.each { |k, v| req.headers[k] = v } }
    [resp.body, resp.headers["X-Cache-Response"] == "true"]
  end

  def app_headers(app: "app-a", master: nil, session: nil, rest: "rest-a")
    h = { APP_ID => app, API_KEY => rest }
    h[MASTER_KEY] = master if master
    h[SESSION_TOKEN] = session if session
    h
  end

  # ---- U6 ----------------------------------------------------------------

  def test_users_me_is_never_cached
    h = app_headers(session: "r:ta")
    request("/parse/users/me", h)
    _, hit = request("/parse/users/me", h)
    refute hit, "users/me must not be served from cache"
    assert_empty @store.each_key.to_a
  end

  def test_sessions_me_is_never_cached
    h = app_headers(session: "r:ta")
    request("/parse/sessions/me", h)
    _, hit = request("/parse/sessions/me", h)
    refute hit
  end

  # ---- U7 ----------------------------------------------------------------

  def test_same_credentials_hit
    h = app_headers(master: "mk-a")
    request("/parse/classes/Post/abc", h)
    _, hit = request("/parse/classes/Post/abc", h)
    assert hit
  end

  def test_wrong_master_key_does_not_hit
    request("/parse/classes/Post/abc", app_headers(master: "mk-a"))
    _, hit = request("/parse/classes/Post/abc", app_headers(master: "wrong"))
    refute hit, "a different master key must not read the cached master response"
  end

  def test_wrong_app_id_does_not_hit
    request("/parse/classes/Post/abc", app_headers(master: "mk-a"))
    _, hit = request("/parse/classes/Post/abc", app_headers(app: "other-app", master: "mk-a"))
    refute hit
    request("/parse/classes/Post/pub", app_headers)
    _, anon_hit = request("/parse/classes/Post/pub", app_headers(app: "other-app", rest: "x"))
    refute anon_hit, "anonymous entries are bound to the app and REST key too"
  end

  def test_same_session_other_app_does_not_hit
    request("/parse/classes/Post/abc", app_headers(session: "r:ta"))
    _, hit = request("/parse/classes/Post/abc", app_headers(app: "other-app", session: "r:ta"))
    refute hit
  end

  # ---- U8 ----------------------------------------------------------------

  def test_write_by_one_user_retires_every_other_users_entry
    b = app_headers(session: "r:tb")
    a = app_headers(session: "r:ta")
    request("/parse/classes/Post/abc", b)
    _, hit = request("/parse/classes/Post/abc", b)
    assert hit, "precondition: B's read is cached"
    request("/parse/classes/Post/abc", app_headers(master: "mk-a"))
    request("/parse/classes/Post/abc", app_headers)

    request("/parse/classes/Post/abc", a, method: :put, body: '{"updatedAt":"2026-01-01"}')

    _, b_hit = request("/parse/classes/Post/abc", b)
    refute b_hit, "B must not keep reading a record whose ACL A just changed"
    _, mk_hit = request("/parse/classes/Post/abc", app_headers(master: "mk-a"))
    refute mk_hit
    _, anon_hit = request("/parse/classes/Post/abc", app_headers)
    refute anon_hit
  end

  def test_write_retires_query_string_variants_of_the_path
    b = app_headers(session: "r:tb")
    request("/parse/classes/Post/abc?include=author", b)
    request("/parse/classes/Post/abc", b, method: :put, body: '{"updatedAt":"2026-01-01"}')
    _, hit = request("/parse/classes/Post/abc?include=author", b)
    refute hit
  end

  def test_write_does_not_retire_another_resource
    b = app_headers(session: "r:tb")
    request("/parse/classes/Post/other", b)
    request("/parse/classes/Post/abc", b, method: :put, body: '{"updatedAt":"2026-01-01"}')
    _, hit = request("/parse/classes/Post/other", b)
    assert hit
  end
end
