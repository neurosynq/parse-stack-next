# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# A batch `Array#destroy` of sessions or users drops their identity-plane
# entries the same way a single `destroy` does, so a revoked token stops
# resolving now rather than when its cached entry expires. Also covers the
# `_User` write paths that store server timestamps: they keep Parse::Date
# values, so reading `updated_at` never dirties a freshly signed-up user.
class IdentityRevocation581Test < Minitest::Test
  CREATED = "2026-01-01T00:00:00.000Z"

  class FakeAuth
    attr_reader :tokens, :users, :resets, :owners

    def initialize(owners = {})
      @tokens = []
      @users = []
      @resets = 0
      @owners = owners
    end

    def invalidate(token) = @tokens << token
    def invalidate_user(id) = @users << id
    def reset_caches! = @resets += 1
    def remember_session_owner(sid, uid) = @owners[sid] = uid
    def session_owner(sid) = @owners[sid]
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1/parse", application_id: "a", api_key: "k")
    end
    # The token lookup reads `_Session` with the master key when the client
    # has one; most tests here exercise that path.
    @client = Parse::Client.client
    @prior_master_key = @client.instance_variable_get(:@master_key)
    @client.instance_variable_set(:@master_key, "mk")
    clear_reset_limiter
  end

  def teardown
    @client.instance_variable_set(:@master_key, @prior_master_key)
    clear_reset_limiter
  end

  def clear_reset_limiter
    Parse::Session.instance_variable_get(:@identity_reset_at)&.clear
  end

  def session(id, token, user_id)
    Parse::Session.build({ "objectId" => id, "sessionToken" => token,
                           "user" => { "__type" => "Pointer", "className" => "_User", "objectId" => user_id },
                           "createdAt" => CREATED, "updatedAt" => CREATED }, "_Session")
  end

  # Every request in the batch succeeds, except paths listed in `fail_ids`.
  def batch_responder(fail_ids = [])
    lambda do |batch, **_opts|
      batch.requests.map do |r|
        failed = fail_ids.any? { |id| r.path.to_s.end_with?(id) }
        Parse::Response.new(failed ? { "code" => 101, "error" => "nope" } : {})
      end
    end
  end

  def destroy_in_batch(objects, fail_ids: [])
    auth = FakeAuth.new
    client = objects.first.client
    client.stub(:authorization, auth) do
      client.stub(:batch_request, batch_responder(fail_ids)) do
        objects.destroy
      end
    end
    auth
  end

  def test_batch_destroy_of_sessions_invalidates_tokens_and_owners
    s1 = session("S1", "r:tok1", "U1")
    s2 = session("S2", "r:tok2", "U2")
    auth = destroy_in_batch([s1, s2])
    assert_equal %w[r:tok1 r:tok2], auth.tokens.sort
    assert_equal %w[U1 U2], auth.users.sort
    assert s1.destroyed?
  end

  # "Object not found" still drops the cached identity: the session was
  # already revoked elsewhere while its token may still be cached here, and
  # dropping an entry is idempotent.
  def test_object_not_found_batch_destroy_still_invalidates
    s1 = session("S1", "r:tok1", "U1")
    s2 = session("S2", "r:tok2", "U2")
    auth = destroy_in_batch([s1, s2], fail_ids: ["S2"])
    assert_equal %w[r:tok1 r:tok2], auth.tokens.sort
    assert_equal %w[U1 U2], auth.users.sort
    assert s1.destroyed?
    refute s2.destroyed?
  end

  def test_failed_single_session_destroy_still_invalidates
    s = session("S8", "r:tok8", "U8")
    auth = FakeAuth.new
    s.client.stub(:authorization, auth) do
      s.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({ "code" => 101, "error" => "Object not found." }) }) do
        refute s.destroy
      end
    end
    assert_equal ["r:tok8"], auth.tokens
    assert_equal ["U8"], auth.users
  end

  def test_single_session_destroy_invalidates_when_the_request_raises
    s = session("S7", "r:tok7", "U7")
    auth = FakeAuth.new
    s.client.stub(:authorization, auth) do
      s.client.stub(:delete_object, ->(*_a, **_k) { raise Parse::Error::ConnectionError, "down" }) do
        assert_raises(Parse::Error::ConnectionError) { s.destroy }
      end
    end
    assert_equal ["r:tok7"], auth.tokens
  end

  def test_session_without_token_still_invalidates_owner
    s = session("S1", nil, "U7")
    auth = nil
    s.client.stub(:find_objects, ->(*_a, **_k) { raise Parse::Error::ConnectionError, "down" }) do
      capture_io { auth = destroy_in_batch([s]) }
    end
    assert_empty auth.tokens
    assert_equal ["U7"], auth.users
    assert_equal 1, auth.resets, "an unknown token drops the whole identity plane"
  end

  def test_batch_destroy_of_users_invalidates_user_identity
    u = Parse::User.build({ "objectId" => "U3", "username" => "x",
                            "createdAt" => CREATED, "updatedAt" => CREATED }, "_User")
    auth = destroy_in_batch([u])
    assert_equal ["U3"], auth.users
  end

  def test_single_session_destroy_still_invalidates
    s = session("S9", "r:tok9", "U9")
    auth = FakeAuth.new
    s.client.stub(:authorization, auth) do
      s.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({}) }) do
        assert s.destroy
      end
    end
    assert_equal ["r:tok9"], auth.tokens
    assert_equal ["U9"], auth.users
  end

  # --- partially loaded sessions ---------------------------------------------

  # Answers the `_Session` lookup with the given rows and records the
  # request options it was sent with.
  def session_lookup(rows, seen)
    lambda do |_table, query, headers: {}, **opts|
      seen << { query: query, opts: opts }
      Parse::Response.new({ "results" => rows })
    end
  end

  # A session fetched with `keys:` that left the token and owner out.
  def session_ref(id)
    Parse::Session.build({ "objectId" => id, "createdAt" => CREATED, "updatedAt" => CREATED }, "_Session")
  end

  def session_row(id, token, user_id)
    { "objectId" => id, "sessionToken" => token,
      "user" => { "__type" => "Pointer", "className" => "_User", "objectId" => user_id } }
  end

  def test_pointer_session_destroy_looks_up_token_and_owner
    s = session_ref("SP1")
    auth = FakeAuth.new
    seen = []
    s.client.stub(:authorization, auth) do
      s.client.stub(:find_objects, session_lookup([session_row("SP1", "r:tokp", "UP")], seen)) do
        s.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({}) }) do
          Parse.without_master_key { assert s.destroy }
        end
      end
    end
    assert_equal ["r:tokp"], auth.tokens
    assert_equal ["UP"], auth.users
    assert_equal 0, auth.resets
    assert_equal 1, seen.size
    assert_equal true, seen.first[:opts][:use_master_key]
    assert seen.first[:opts][:metadata_master].equal?(Parse::Client::METADATA_MASTER_REQUEST),
           "the lookup is an SDK metadata read that keeps the master key inside the block"
  end

  def test_pointer_sessions_in_a_batch_are_looked_up_in_one_query
    s1 = session_ref("SB1")
    s2 = session_ref("SB2")
    full = session("SB3", "r:tok3", "U3")
    auth = FakeAuth.new
    seen = []
    rows = [session_row("SB1", "r:tokb1", "UB1"), session_row("SB2", "r:tokb2", "UB2")]
    client = s1.client
    client.stub(:authorization, auth) do
      client.stub(:find_objects, session_lookup(rows, seen)) do
        client.stub(:batch_request, batch_responder) do
          [s1, s2, full].destroy
        end
      end
    end
    assert_equal 1, seen.size, "one lookup for every partially loaded session"
    where = seen.first[:query][:where] || seen.first[:query]["where"]
    where = JSON.parse(where) if where.is_a?(String)
    assert_equal %w[SB1 SB2], where["objectId"]["$in"].sort
    assert_equal %w[r:tok3 r:tokb1 r:tokb2], auth.tokens.sort
    assert_equal %w[U3 UB1 UB2], auth.users.sort
    assert_equal 0, auth.resets
  end

  def test_failed_lookup_falls_back_to_dropping_the_identity_plane
    s = session_ref("SF1")
    auth = FakeAuth.new
    s.client.stub(:authorization, auth) do
      s.client.stub(:find_objects, ->(*_a, **_k) { raise Parse::Error::ConnectionError, "down" }) do
        s.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({}) }) do
          capture_io { assert s.destroy }
        end
      end
    end
    assert_empty auth.tokens
    assert_equal 1, auth.resets
  end

  # A lookup that answers without the row (a bogus id, a session already
  # gone) leaves nothing to forget: it never resets the identity plane.
  def test_session_missing_from_lookup_resets_nothing
    s = session_ref("SM1")
    auth = FakeAuth.new
    s.client.stub(:authorization, auth) do
      s.client.stub(:find_objects, session_lookup([], [])) do
        s.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({ "code" => 101, "error" => "Object not found." }) }) do
          refute s.destroy
        end
      end
    end
    assert_equal 0, auth.resets
    assert_empty auth.tokens
    assert_empty auth.users
  end

  def bogus_sessions(count)
    Array.new(count) { |i| Parse::Session.build({ "objectId" => "bogus#{i}" }, "_Session") }
  end

  def test_many_absent_ids_reset_at_most_once_per_interval_without_a_recorded_owner
    auth = FakeAuth.new
    client = Parse::Client.client
    client.stub(:authorization, auth) do
      client.stub(:find_objects, session_lookup([], [])) do
        client.stub(:batch_request, batch_responder((0...50).map { |i| "bogus#{i}" })) do
          bogus_sessions(50).destroy
          bogus_sessions(50).destroy
        end
      end
    end
    assert_equal 1, auth.resets, "an absent row deleted as not found falls back to one rate-limited reset"
    assert_empty auth.users
  end

  def test_absent_session_with_recorded_owner_invalidates_that_owner
    auth = FakeAuth.new("gone1" => "UOWN")
    client = Parse::Client.client
    client.stub(:authorization, auth) do
      client.stub(:find_objects, session_lookup([], [])) do
        client.stub(:batch_request, batch_responder(["gone1"])) do
          [Parse::Session.build({ "objectId" => "gone1" }, "_Session")].destroy
        end
      end
    end
    assert_equal ["UOWN"], auth.users
    assert_equal 0, auth.resets, "a recorded owner is targeted; no reset"
  end

  def test_absent_session_denied_delete_never_resets
    auth = FakeAuth.new
    client = Parse::Client.client
    denied = lambda do |batch, **_opts|
      batch.requests.map { Parse::Response.new({ "code" => 119, "error" => "Permission denied." }) }
    end
    client.stub(:authorization, auth) do
      client.stub(:find_objects, session_lookup([], [])) do
        client.stub(:batch_request, denied) { bogus_sessions(5).destroy }
      end
    end
    assert_equal 0, auth.resets
    assert_empty auth.users
  end

  def test_single_absent_destroy_uses_recorded_owner_and_never_resets
    s = session_ref("gone2")
    auth = FakeAuth.new("gone2" => "UOWN2")
    client = s.client
    client.stub(:authorization, auth) do
      client.stub(:find_objects, session_lookup([], [])) do
        client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({ "code" => 101, "error" => "gone" }) }) do
          s.destroy
        end
      end
    end
    assert_equal ["UOWN2"], auth.users
    assert_equal 0, auth.resets

    s2 = session_ref("gone3")
    auth2 = FakeAuth.new
    s2.client.stub(:authorization, auth2) do
      s2.client.stub(:find_objects, session_lookup([], [])) do
        s2.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({ "code" => 101, "error" => "gone" }) }) do
          s2.destroy
        end
      end
    end
    assert_equal 0, auth2.resets, "a single delete cannot tell gone from denied, so it never resets"
  end

  def other_client(app)
    Parse::Client.new(server_url: "http://localhost:1/parse", app_id: app, api_key: "k")
  end

  def test_querying_sessions_records_owners_in_the_fetching_client_without_the_token
    default_auth = FakeAuth.new
    other = other_client("owner-app-b")
    other_auth = FakeAuth.new
    rows = [session_row("SREC", "r:secret", "UREC")]
    Parse::Client.client.stub(:authorization, default_auth) do
      other.stub(:authorization, other_auth) do
        query = Parse::Session.query
        query.client = other
        query.send(:decode, rows)
      end
    end
    assert_equal({ "SREC" => "UREC" }, other_auth.owners, "recorded against the client that fetched the row")
    assert_empty default_auth.owners, "never recorded in another application's context"
    refute_includes other_auth.owners.values.join, "r:secret"
  end

  def test_building_a_session_records_nothing
    auth = FakeAuth.new
    Parse::Client.client.stub(:authorization, auth) { session("SB", "r:t", "UB") }
    assert_empty auth.owners
  end

  def test_real_context_records_and_reads_session_owner
    auth = other_client("owner-map").authorization
    auth.remember_session_owner("S9", "U9")
    assert_equal "U9", auth.session_owner("S9")
    assert_nil auth.session_owner("S10")
    # The records live outside the identity plane: a reset drops cached
    # identities but keeps the owners a later delete may need.
    auth.reset_caches!
    assert_equal "U9", auth.session_owner("S9")
    assert_nil auth.identity_cache.get("S9")
  end

  def test_owner_records_never_resolve_as_tokens
    client = other_client("owner-forge")
    auth = client.authorization
    auth.remember_session_owner("S1", "U1")
    lookups = 0
    rejected = lambda do |_t, **_o|
      lookups += 1
      Parse::Response.new({ "code" => 209, "error" => "Invalid session token" })
    end
    client.stub(:current_user, rejected) do
      ["S1", "sid\x1fS1", "session_owner", auth.session_owner_cache.class.name].each do |forged|
        assert_raises(Parse::Authorization::InvalidSession) { auth.resolve(forged) }
      end
    end
    assert_equal 4, lookups, "every crafted token went to Parse Server; none resolved from an owner record"
  end

  def test_many_bogus_ids_reset_at_most_once_when_the_lookup_raises
    auth = FakeAuth.new
    client = Parse::Client.client
    client.stub(:authorization, auth) do
      client.stub(:find_objects, ->(*_a, **_k) { raise Parse::Error::ConnectionError, "down" }) do
        client.stub(:batch_request, batch_responder((0...50).map { |i| "bogus#{i}" })) do
          capture_io do
            bogus_sessions(50).destroy
            bogus_sessions(50).destroy
          end
        end
      end
    end
    assert_equal 1, auth.resets, "lookup-triggered resets are rate limited per client"
  end

  def test_denied_batch_destroy_leaves_the_cache_alone
    s = session("SX1", "r:tokx", "UX")
    u = Parse::User.build({ "objectId" => "UY", "username" => "y",
                            "createdAt" => CREATED, "updatedAt" => CREATED }, "_User")
    auth = FakeAuth.new
    client = s.client
    denied = lambda do |batch, **_opts|
      batch.requests.map { Parse::Response.new({ "code" => 119, "error" => "Permission denied." }) }
    end
    client.stub(:authorization, auth) do
      client.stub(:batch_request, denied) { [s, u].destroy }
    end
    assert_empty auth.tokens
    assert_empty auth.users
    assert_equal 0, auth.resets
  end

  def test_client_without_master_key_looks_up_with_the_delete_session
    @client.instance_variable_set(:@master_key, nil)
    s = session_ref("SC1")
    auth = FakeAuth.new
    seen = []
    s.client.stub(:authorization, auth) do
      s.client.stub(:find_objects, session_lookup([session_row("SC1", "r:mine", "UC")], seen)) do
        s.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({}) }) do
          assert s.destroy(session: "r:mine")
        end
      end
    end
    assert_equal 1, seen.size
    assert_equal "r:mine", seen.first[:opts][:session_token]
    refute_equal true, seen.first[:opts][:use_master_key]
    assert_nil seen.first[:opts][:metadata_master]
    assert_equal ["r:mine"], auth.tokens
    assert_equal ["UC"], auth.users
  end

  # With a master key, a session-scoped delete still looks up as that user,
  # so it cannot read other users' tokens and owners (P3-2).
  def test_session_scoped_batch_destroy_looks_up_as_the_user_even_with_a_master_key
    victim = session_ref("SV1")
    auth = FakeAuth.new(auth_owners = { "SV1" => "VICTIM" })
    seen = []
    client = victim.client
    client.stub(:authorization, auth) do
      client.stub(:find_objects, session_lookup([], seen)) do
        client.stub(:batch_request, batch_responder(["SV1"])) do
          [victim].destroy(session: "r:attacker")
        end
      end
    end
    assert_equal 1, seen.size
    assert_equal "r:attacker", seen.first[:opts][:session_token]
    assert_nil seen.first[:opts][:metadata_master]
    # The row was invisible to the caller: nothing is forgotten, the recorded
    # owner is not used, and nothing is reset.
    assert_empty auth.tokens
    assert_empty auth.users
    assert_equal 0, auth.resets
    assert_equal "VICTIM", auth_owners["SV1"]
  end

  # A caller allowed to delete a session it cannot read: when the delete
  # succeeds, the session is gone, so its owner's cached identities go too.
  def test_invisible_session_deleted_successfully_invalidates_the_recorded_owner
    s = session_ref("SV3")
    auth = FakeAuth.new("SV3" => "OWNER3")
    client = s.client
    client.stub(:authorization, auth) do
      client.stub(:find_objects, session_lookup([], [])) do
        client.stub(:batch_request, batch_responder([])) do
          [s].destroy(session: "r:deleter")
        end
      end
    end
    assert_equal ["OWNER3"], auth.users
    assert_equal 0, auth.resets
  end

  def test_invisible_sessions_deleted_successfully_without_an_owner_reset_at_most_once
    auth = FakeAuth.new
    client = Parse::Client.client
    client.stub(:authorization, auth) do
      client.stub(:find_objects, session_lookup([], [])) do
        client.stub(:batch_request, batch_responder([])) do
          bogus_sessions(20).destroy(session: "r:deleter")
          bogus_sessions(20).destroy(session: "r:deleter")
        end
      end
    end
    assert_equal 1, auth.resets, "a successful delete of unreadable rows falls back to one rate-limited reset"
    assert_empty auth.users
  end

  def test_invisible_session_denied_or_not_found_forgets_nothing
    [[{ "code" => 101, "error" => "not found" }], [{ "code" => 119, "error" => "denied" }]].each do |(body)|
      clear_reset_limiter
      s = session_ref("SV4")
      auth = FakeAuth.new("SV4" => "OWNER4")
      responder = ->(batch, **_o) { batch.requests.map { Parse::Response.new(body) } }
      client = s.client
      client.stub(:authorization, auth) do
        client.stub(:find_objects, session_lookup([], [])) do
          client.stub(:batch_request, responder) { [s].destroy(session: "r:deleter") }
        end
      end
      assert_empty auth.users, "code #{body["code"]} on an unreadable row forgets nothing"
      assert_equal 0, auth.resets
    end
  end

  def test_single_invisible_destroy_uses_owner_only_when_it_succeeds
    ok = session_ref("SV5")
    auth = FakeAuth.new("SV5" => "OWNER5")
    ok.client.stub(:authorization, auth) do
      ok.client.stub(:find_objects, session_lookup([], [])) do
        ok.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({}) }) do
          ok.destroy(session: "r:deleter")
        end
      end
    end
    assert_equal ["OWNER5"], auth.users

    denied = session_ref("SV6")
    auth2 = FakeAuth.new("SV6" => "OWNER6")
    denied.client.stub(:authorization, auth2) do
      denied.client.stub(:find_objects, session_lookup([], [])) do
        denied.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({ "code" => 101, "error" => "nope" }) }) do
          denied.destroy(session: "r:deleter")
        end
      end
    end
    assert_empty auth2.users
    assert_equal 0, auth2.resets
  end

  def test_master_batch_destroy_still_uses_the_recorded_owner
    gone = session_ref("SV2")
    auth = FakeAuth.new({ "SV2" => "OWNER2" })
    client = gone.client
    client.stub(:authorization, auth) do
      client.stub(:find_objects, session_lookup([], [])) do
        client.stub(:batch_request, batch_responder(["SV2"])) do
          [gone].destroy
        end
      end
    end
    assert_equal ["OWNER2"], auth.users
  end

  def test_client_without_master_key_or_session_skips_the_lookup
    @client.instance_variable_set(:@master_key, nil)
    s = session_ref("SC2")
    auth = FakeAuth.new
    s.client.stub(:authorization, auth) do
      s.client.stub(:find_objects, ->(*_a, **_k) { flunk "no anonymous lookup expected" }) do
        s.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({ "code" => 101, "error" => "Object not found." }) }) do
          refute s.destroy
        end
      end
    end
    assert_equal 0, auth.resets
  end

  def test_session_lookup_bypasses_the_response_cache
    prior_cache = Parse.default_query_cache
    Parse.default_query_cache = true
    s = session_ref("SC3")
    seen = []
    s.client.stub(:authorization, FakeAuth.new) do
      s.client.stub(:find_objects, session_lookup([session_row("SC3", "r:t", "U")], seen)) do
        s.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({}) }) do
          assert s.destroy
        end
      end
    end
    assert_equal false, seen.first[:opts][:cache]
  ensure
    Parse.default_query_cache = prior_cache
  end

  def test_identity_helpers_are_not_public
    refute Parse::Session.respond_to?(:_preload_identity_for_destroy!)
    s = session_ref("SC4")
    refute s.respond_to?(:_after_batch_destroy)
    refute s.respond_to?(:_clear_identity_for_destroy!)
    refute s.respond_to?(:_identity_lookup_needed?)
    refute Parse::User.new.respond_to?(:_after_batch_destroy)
  end

  def test_fully_loaded_session_needs_no_lookup
    s = session("SL1", "r:tokl", "UL")
    auth = FakeAuth.new
    s.client.stub(:authorization, auth) do
      s.client.stub(:find_objects, ->(*_a, **_k) { flunk "no lookup expected" }) do
        s.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({}) }) do
          assert s.destroy
        end
      end
    end
    assert_equal ["r:tokl"], auth.tokens
  end

  # A session built from its objectId alone (no timestamps, so `new?`) is
  # still deleted by a batch, which deletes by id; its token must be looked
  # up and dropped too.
  def test_id_only_session_in_a_batch_is_looked_up_and_invalidated
    s = Parse::Session.build({ "objectId" => "SID1" }, "_Session")
    assert s.new?, "no timestamps loaded"
    auth = FakeAuth.new
    seen = []
    client = s.client
    client.stub(:authorization, auth) do
      client.stub(:find_objects, session_lookup([session_row("SID1", "r:tokid", "UID")], seen)) do
        client.stub(:batch_request, batch_responder) do
          [s].destroy
        end
      end
    end
    assert_equal 1, seen.size
    assert_equal ["r:tokid"], auth.tokens
    assert_equal ["UID"], auth.users
    assert_equal 0, auth.resets
  end

  def assert_token_not_exposed(s, token)
    refute_includes s.inspect, token
    refute_includes s.to_s, token
    refute_includes s.as_json.to_json, token
    refute_includes s.instance_variables, :@_identity_for_destroy
    s.instance_variables.each do |iv|
      refute_includes s.instance_variable_get(iv).inspect, token, "#{iv} holds the looked-up token"
    end
  end

  def test_looked_up_token_is_not_kept_after_a_denied_single_destroy
    s = session_ref("SD1")
    s.client.stub(:authorization, FakeAuth.new) do
      s.client.stub(:find_objects, session_lookup([session_row("SD1", "r:livetok", "UD")], [])) do
        s.client.stub(:delete_object, ->(*_a, **_k) { Parse::Response.new({ "code" => 119, "error" => "Permission denied." }) }) do
          refute s.destroy
        end
      end
    end
    assert_token_not_exposed(s, "r:livetok")
  end

  def test_looked_up_token_is_not_kept_after_a_raised_single_destroy
    s = session_ref("SD2")
    s.client.stub(:authorization, FakeAuth.new) do
      s.client.stub(:find_objects, session_lookup([session_row("SD2", "r:livetok2", "UD")], [])) do
        s.client.stub(:delete_object, ->(*_a, **_k) { raise Parse::Error::ConnectionError, "down" }) do
          assert_raises(Parse::Error::ConnectionError) { s.destroy }
        end
      end
    end
    assert_token_not_exposed(s, "r:livetok2")
  end

  def test_looked_up_token_is_not_kept_after_a_denied_or_raised_batch
    s1 = session_ref("SD3")
    s2 = session_ref("SD4")
    rows = [session_row("SD3", "r:livetok3", "U3"), session_row("SD4", "r:livetok4", "U4")]
    client = s1.client
    client.stub(:authorization, FakeAuth.new) do
      client.stub(:find_objects, session_lookup(rows, [])) do
        client.stub(:batch_request, batch_responder(["SD3"])) do
          [s1, s2].destroy
        end
      end
    end
    assert_token_not_exposed(s1, "r:livetok3")
    assert_token_not_exposed(s2, "r:livetok4")

    s5 = session_ref("SD5")
    client.stub(:authorization, FakeAuth.new) do
      client.stub(:find_objects, session_lookup([session_row("SD5", "r:livetok5", "U5")], [])) do
        client.stub(:batch_request, ->(*_a, **_k) { raise Parse::Error::ConnectionError, "down" }) do
          assert_raises(Parse::Error::ConnectionError) { [s5].destroy }
        end
      end
    end
    assert_token_not_exposed(s5, "r:livetok5")
  end

  def test_inspect_redacts_a_pending_looked_up_token
    s = session_ref("SD6")
    s.instance_variable_set(:@_identity_for_destroy, ["r:pending", "U6"])
    refute_includes s.inspect, "r:pending"
  end

  # --- user.rb timestamps -----------------------------------------------------

  def signup_response
    Parse::Response.new({ "objectId" => "NEWU", "createdAt" => CREATED,
                          "sessionToken" => "r:fresh" })
  end

  def test_signup_bang_stores_dates_and_reading_does_not_dirty
    u = Parse::User.new(username: "fresh", password: "pw")
    u.client.stub(:create_user, ->(*_a, **_k) { signup_response }) do
      assert u.signup!
    end
    assert_kind_of Parse::Date, u.instance_variable_get(:@created_at)
    assert_kind_of Parse::Date, u.instance_variable_get(:@updated_at)
    u.updated_at
    u.created_at
    refute u.changed?, "reading timestamps after signup! must not dirty the user"
  end

  def test_signup_on_save_stores_dates_and_reading_does_not_dirty
    u = Parse::User.new(username: "fresh2", password: "pw")
    u.client.stub(:create_user, ->(*_a, **_k) { signup_response }) do
      assert u.save
    end
    assert_kind_of Parse::Date, u.instance_variable_get(:@updated_at)
    u.updated_at
    refute u.changed?, "reading timestamps after a signup save must not dirty the user"
  end

  def test_upgrade_anonymous_stores_date
    u = Parse::User.build({ "objectId" => "ANON", "createdAt" => CREATED, "updatedAt" => CREATED }, "_User")
    u.instance_variable_set(:@auth_data, { "anonymous" => { "id" => "x" } })
    u.instance_variable_set(:@session_token, "r:anon")
    ok = Parse::Response.new({ "updatedAt" => "2026-02-01T00:00:00.000Z" })
    u.client.stub(:update_user, ->(*_a, **_k) { ok }) do
      u.upgrade_anonymous!(username: "real", password: "pw")
    end
    assert_kind_of Parse::Date, u.instance_variable_get(:@updated_at)
    u.updated_at
    refute u.changed?
  end
end
