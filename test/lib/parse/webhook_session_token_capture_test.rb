# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/autorun"

# Unit-level (no Docker) guards for the webhook "run as the calling user"
# feature. The companion integration suite
# (webhook_session_token_as_user_integration_test.rb) proves that user_agent
# actually ENFORCES ACL against a live server. This suite pins the SAFETY
# invariant v5.2.1 cares about and that the integration tests do NOT cover:
#
#   The caller's session token is captured for opt-in use, but must NOT leak
#   back into the handler-visible object or into serialization / logs.
#
# If a future refactor re-leaked the token (e.g. by adding session_token to
# Payload::ATTRIBUTES, which drives #as_json), every integration test would
# still pass while the token started flowing into logs -- these would fail.
# Mirrors the off-Docker style of webhook_aftersave_payload_fidelity_test.rb.
class WebhookSessionTokenCaptureTest < Minitest::Test
  LIVE = "r:live-token-abc"

  # Build a beforeSave trigger payload the way Parse Server sends one: the
  # session token lives at user.sessionToken (camelCase string key), and the
  # object hash carries its own (different) credential that must be scrubbed.
  def trigger_payload(session_token: LIVE, with_user: true)
    user = { "objectId" => "U1", "username" => "matt",
             "createdAt" => "2020-01-01T00:00:00.000Z" }
    user["sessionToken"] = session_token if session_token
    hash = {
      "master" => false,
      "triggerName" => "beforeSave",
      "object" => { "className" => "Post", "objectId" => "P1", "title" => "hi",
                    "createdAt" => "2020-01-01T00:00:00.000Z",
                    "sessionToken" => "r:object-token-should-vanish" },
    }
    hash["user"] = user if with_user
    Parse::Webhooks::Payload.new(hash.to_json)
  end

  # user_client / user_agent need a configured default client. Stand one up
  # for the duration of the block and restore whatever was there before.
  def with_default_client
    prior = Parse::Client.clients[:default]
    Parse.setup(server_url: "http://localhost:1337/parse", app_id: "app",
                api_key: "rest", master_key: "master")
    yield
  ensure
    Parse::Client.clients[:default] = prior
  end

  def test_captures_session_token_from_user
    p = trigger_payload(session_token: LIVE)
    assert_equal LIVE, p.session_token
    assert p.session_token?
  end

  def test_token_absent_from_serialization_and_logs
    p = trigger_payload(session_token: LIVE)
    refute_includes p.as_json.to_json, "live-token-abc",
                    "session token must never appear in #as_json (the request-log surface)"
    refute_includes p.to_json, "live-token-abc",
                    "session token must never appear in #to_json"
  end

  # #inspect is what error reporters / a stray `p payload` hit. The default
  # Ruby #inspect would dump @session_token AND the pre-scrub @raw (which still
  # holds the credential). Pin that the redacting override hides both.
  def test_token_absent_from_inspect
    p = trigger_payload(session_token: LIVE)
    refute_includes p.inspect, "live-token-abc",
                    "captured session token must not appear in #inspect"
    refute_includes p.inspect, "object-token-should-vanish",
                    "pre-scrub @raw credential must not leak through #inspect"
    assert_includes p.inspect, "session_token=[FILTERED]",
                    "#inspect should mark the token presence without revealing it"
  end

  def test_token_scrubbed_from_user_and_object
    p = trigger_payload(session_token: LIVE)
    user_token = p.user.respond_to?(:session_token) ? p.user.session_token : nil
    refute_equal LIVE, user_token, "payload.user must not surface the captured token"
    assert p.object.key?("createdAt"), "server-authoritative createdAt is preserved"
    refute p.object.key?("sessionToken"), "the object's own credential is scrubbed"
  end

  def test_master_only_payload_has_no_token_or_scoped_handles
    p = Parse::Webhooks::Payload.new(
      { "master" => true, "triggerName" => "afterSave",
        "object" => { "className" => "Post" } }.to_json
    )
    assert_nil p.session_token
    refute p.session_token?
    assert_nil p.user_client, "no token => no scoped client"
    assert_nil p.user_agent,  "no token => no scoped agent"
  end

  def test_user_present_without_token_yields_nil
    p = trigger_payload(session_token: nil)
    assert_nil p.session_token
    refute p.session_token?
  end

  def test_user_client_is_non_master_with_bound_token
    with_default_client do
      p = trigger_payload(session_token: LIVE)
      c = p.user_client
      assert_instance_of Parse::Client, c
      assert_nil c.master_key, "user_client must carry NO master key"
      assert_equal LIVE, c.session_token, "user_client must BIND the caller's token"
      assert_equal Parse::Client.client.server_url, c.server_url
      assert_same c, p.user_client, "the user-scoped client is memoized per payload"
    end
  end

  def test_user_agent_runs_in_client_mode
    with_default_client do
      p = trigger_payload(session_token: LIVE)
      a = p.user_agent
      assert_instance_of Parse::Agent, a
      assert_equal true, a.instance_variable_get(:@client_mode),
                   "non-master client + non-empty session token => CLIENT MODE"
      assert_equal LIVE, a.instance_variable_get(:@session_token)
      assert_nil a.instance_variable_get(:@client).master_key
    end
  end

  # The user-scoped client must never reveal its bound token / master key via
  # #inspect (the default would print both in cleartext).
  def test_client_inspect_redacts_credentials
    with_default_client do
      uc = trigger_payload(session_token: LIVE).user_client
      refute_includes uc.inspect, "live-token-abc", "bound token must not appear in Client#inspect"
      assert_includes uc.inspect, "session_token=[FILTERED]"

      c = Parse::Client.new(server_url: Parse::Client.client.server_url, app_id: "app",
                            api_key: "rest", master_key: "MK-SECRET-9", session_token: LIVE)
      refute_includes c.inspect, "MK-SECRET-9", "master key VALUE must not appear in Client#inspect"
      refute_includes c.inspect, "live-token-abc", "bound token must not appear in Client#inspect"
      assert_includes c.inspect, "master_key=[FILTERED]"
      assert_includes c.inspect, "session_token=[FILTERED]"
    end
  end

  # A whitespace-only bound token must normalize to nil so it never silently
  # falls through to the master key at request time (where present? is false).
  def test_whitespace_bound_token_normalizes_to_nil
    with_default_client do
      c = Parse::Client.new(server_url: Parse::Client.client.server_url, app_id: "app",
                            api_key: "rest", master_key: "master", session_token: "   ")
      assert_nil c.session_token, "whitespace-only session_token must be treated as no token"
    end
  end

  # Parse::Client#become builds a non-master sibling carrying THIS client's
  # connection identity (server_url/app_id/api_key) + the given token. It is the
  # primitive behind payload.user_client and user.session_client.
  def test_client_become_carries_connection_identity_and_binds_token
    with_default_client do
      base = Parse::Client.client
      uc = base.become("r:become-token")
      assert_instance_of Parse::Client, uc
      assert_nil uc.master_key, "become() builds a non-master client"
      assert_equal "r:become-token", uc.session_token, "become() binds the token"
      assert_equal base.server_url, uc.server_url, "become() mirrors the connection"
      assert_equal base.application_id, uc.application_id
      assert_equal base.api_key, uc.api_key
    end
  end

  # Parse::Client#anonymous drops the bound identity: a new client with no
  # master key and no session token (unauthenticated REST), mirroring the
  # connection.
  def test_client_anonymous_clears_token_and_master_key
    with_default_client do
      uc = Parse::Client.client.become("r:some-token")
      anon = uc.anonymous
      assert_instance_of Parse::Client, anon
      assert_nil anon.master_key, "anonymous client has no master key"
      assert_nil anon.session_token, "anonymous client has no session token"
      assert_equal uc.server_url, anon.server_url, "anonymous mirrors the connection"
    end
  end

  # Parse::Client#with_session runs a block with the client's bound token as the
  # ambient session; raises if there is no token to scope by.
  def test_client_with_session_sets_ambient_and_requires_token
    with_default_client do
      uc = Parse::Client.client.become("r:ambient-token")
      seen = uc.with_session { Parse.current_session_token }
      assert_equal "r:ambient-token", seen, "with_session binds the token as the ambient session"
      assert_nil Parse.current_session_token, "ambient is restored after the block"
      # A client with no bound token cannot scope.
      assert_raises(ArgumentError) { Parse::Client.client.with_session { 1 } }
      # Called without a block, raise a clear ArgumentError rather than the
      # LocalJumpError that `Parse.with_session`'s bare `yield` would produce.
      assert_raises(ArgumentError) { uc.with_session }
    end
  end

  # Parse::User#session_client mirrors payload.user_client for the client-side
  # login path: non-master client bound to the logged-in user's token.
  def test_user_session_client_is_non_master_and_bound
    with_default_client do
      u = Parse::User.new(username: "x")
      u.session_token = "r:user-token-xyz"
      c = u.session_client(Parse::Client.client)
      assert_instance_of Parse::Client, c
      assert_nil c.master_key, "session_client must carry NO master key"
      assert_equal "r:user-token-xyz", c.session_token, "session_client binds the user's token"
      # A user with no session token (e.g. master-key save) yields nil.
      assert_nil Parse::User.new(username: "y").session_client(Parse::Client.client)
    end
  end

  # Explicit master_key: nil must NOT silently re-inherit the process master key
  # from ENV — otherwise a "non-master" user_client/session_client is secretly a
  # master client in any deployment that exports PARSE_SERVER_MASTER_KEY.
  def test_explicit_nil_master_key_not_reinherited_from_env
    prior = ENV["PARSE_SERVER_MASTER_KEY"]
    ENV["PARSE_SERVER_MASTER_KEY"] = "env-master-should-not-leak"
    begin
      c = Parse::Client.new(server_url: "http://localhost:1337/parse",
                            app_id: "a", api_key: "r", master_key: nil)
      assert_nil c.master_key,
                 "explicit master_key: nil must not re-inherit the ENV master key"
    ensure
      ENV["PARSE_SERVER_MASTER_KEY"] = prior
    end
  end

  # The **opts passthrough on user_agent must not let a caller override the
  # scoping identity (session_token:/client:) — a double-splat repeat would
  # otherwise win in Ruby and defeat the scoping.
  def test_user_agent_opts_cannot_override_scoping
    with_default_client do
      p = trigger_payload(session_token: LIVE)
      a = p.user_agent(client: Parse::Client.client, session_token: "r:attacker")
      assert_nil a.instance_variable_get(:@client).master_key,
                 "client: override must be ignored (still the non-master user_client)"
      assert_equal LIVE, a.instance_variable_get(:@session_token),
                   "session_token: override must be ignored"
      assert_equal true, a.instance_variable_get(:@client_mode)
    end
  end

  # A mixed-whitespace token is stripped before storage so it cannot reach the
  # X-Parse-Session-Token header with surrounding spaces.
  def test_mixed_whitespace_bound_token_is_stripped
    with_default_client do
      c = Parse::Client.new(server_url: Parse::Client.client.server_url, app_id: "a",
                            api_key: "r", master_key: nil, session_token: "  r:abc  ")
      assert_equal "r:abc", c.session_token
    end
  end

  # A token object responding to #session_token is unwrapped at construction.
  def test_bound_token_unwraps_session_token_object
    with_default_client do
      holder = Struct.new(:session_token).new(LIVE)
      c = Parse::Client.new(server_url: Parse::Client.client.server_url, app_id: "app",
                            api_key: "rest", master_key: nil, session_token: holder)
      assert_equal LIVE, c.session_token
    end
  end

  # Parse sends the camelCase string key; tolerate symbol and snake_case too,
  # and treat blank/non-Hash/absent as "no token" (mirrors scrub_credentials).
  def test_extract_session_token_key_tolerance
    extract = Parse::Webhooks::Payload.method(:extract_session_token)
    assert_equal "t", extract.call("sessionToken" => "t")
    assert_equal "t", extract.call(sessionToken: "t")
    assert_equal "t", extract.call("session_token" => "t")
    assert_nil extract.call("sessionToken" => "")
    assert_nil extract.call("sessionToken" => "   "),
               "a whitespace-only token must be treated as no token"
    assert_equal "t", extract.call("sessionToken" => "  t  "),
                 "a usable token is stripped of surrounding whitespace"
    assert_nil extract.call(nil)
    assert_nil extract.call("foo" => "bar")
  end
end
