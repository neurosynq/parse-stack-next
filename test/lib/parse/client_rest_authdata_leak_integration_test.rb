require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# Integration coverage for the cross-user +_User+ +authData+ leak fix
# in Parse::User. End-to-end: seed user A with anonymous authData,
# log in as user B under a no-master-key client, fetch A through
# query / find paths, and assert the strip is in effect — the
# +authData.anonymous.id+ does not arrive at the in-memory object.
#
# Why anonymous: the test Parse Server's Facebook / Google / Apple
# adapters validate the OAuth token against the upstream IdP and
# reject obvious-fixture values, so we use the +anonymous+ provider
# (the only one the default Parse Server accepts without external
# verification). The threat is realistic: an exposed anonymous id
# lets an attacker silently log into the freshly-credentialed
# account before the upgrade unlinks the provider — exactly the
# vector that motivated {Parse::User#upgrade_anonymous!} to clear
# the anonymous provider in the same PUT as the credential set.
#
# The strip lives at the hydration layer
# (+Parse::User#apply_attributes!+), so query, find, and autofetch
# all share one defense. The trusted self-fetch sites
# (login/login!/session!/create/link_auth_data!/unlink_auth_data!/MFA)
# wrap their build calls in +Parse::User.with_authdata_trust+ — we
# also assert the asymmetry (strip on cross-user, retain on self).
class ClientRestAuthdataLeakIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    # User B is the attacker / unintended viewer — has a username +
    # password and uses the standard session flow.
    @bob, @bob_pw = seed_client_user("leak_bob")

    # User A is the victim — anonymous-signed-up so its row carries a
    # real authData.anonymous.id we can assert against. Held for the
    # cross-user fetch under B's session.
    @alice_anon_id = nil
    @alice_id = nil
    as_client do
      alice = Parse::User.anonymous_signup
      @test_context.track(alice)
      @alice_id = alice.id
      @alice_anon_id = alice.auth_data["anonymous"]["id"]
      refute_nil @alice_id, "fixture: anonymous user must have id"
      refute_nil @alice_anon_id, "fixture: anonymous user must carry the provider id"
    end

    # Widen Alice's ACL so Bob can actually GET /users/:alice_id. Without
    # this, Parse Server's default per-row _User ACL (owner-only after
    # anonymous_signup) means the SDK strip path is never exercised — the
    # request 404s on the wire instead. The realistic threat is exactly
    # the deployment that has loose _User ACLs (catalog directories,
    # social-app member lists), so we model that here.
    with_master_key do
      Parse.client.update_user(
        @alice_id,
        { ACL: { "*" => { "read" => true }, @alice_id => { "read" => true, "write" => true } } },
      )

      raw = Parse.client.fetch_user(@alice_id).result
      assert raw["authData"].is_a?(Hash),
             "fixture: master-key fetch must see authData on Alice"
      assert_equal @alice_anon_id, raw.dig("authData", "anonymous", "id"),
                   "fixture: master-key fetch must round-trip the anonymous id"
    end
  end

  # --------------------------------------------------------------------
  # GET /users/:id under user B's session. Server response may or may
  # not carry authData depending on the row's ACL and the deployment's
  # protectedFields, but the SDK hydration layer must strip it either
  # way — this assertion holds the line regardless of server config.
  # --------------------------------------------------------------------
  def test_find_other_user_under_session_does_not_leak_authdata
    as_client do
      bob = Parse::User.login!(@bob.username, @bob_pw)
      Parse.with_session(bob) do
        fetched = Parse::User.find(@alice_id)
        if fetched.nil?
          # The deployment's default _User ACL may forbid the cross-user
          # read outright; skip rather than green-light a vacuous pass.
          # The assertion we want is "stripped IF the row hydrates."
          skip "Server's _User ACL blocks cross-user read; strip path not exercised"
        end
        assert_equal @alice_id, fetched.id, "must round-trip the right user"
        assert_nil fetched.auth_data,
                   "Parse::User hydration must strip authData on cross-user fetch"
      end
    end
  end

  # --------------------------------------------------------------------
  # Same defense on the query path. Parse::Query routes through
  # Parse::Object.build → User#apply_attributes!, same override as find.
  # --------------------------------------------------------------------
  def test_query_other_user_under_session_does_not_leak_authdata
    as_client do
      bob = Parse::User.login!(@bob.username, @bob_pw)
      Parse.with_session(bob) do
        results = Parse::User.all(objectId: @alice_id)
        skip "Server's _User ACL blocks cross-user query" if results.empty?

        fetched = results.first
        assert_equal @alice_id, fetched.id
        assert_nil fetched.auth_data,
                   "Parse::Query hydration must strip authData on cross-user results"
      end
    end
  end

  # --------------------------------------------------------------------
  # Anonymous self-login through autologin_service goes through the
  # trusted path — Parse::User.with_authdata_trust { build(...) } — so
  # authData legitimately belonging to the authenticating user IS
  # preserved. This pins the asymmetry: strip on cross-user, retain
  # on self-login. Without this, callers can't read
  # `user.auth_data["anonymous"]["id"]` immediately post-login (e.g.
  # to remember the anonymous id for an upgrade flow).
  # --------------------------------------------------------------------
  def test_anonymous_self_login_preserves_own_authdata
    as_client do
      alice = Parse::User.anonymous_signup
      @test_context.track(alice)
      refute_nil alice.auth_data,
                 "trusted self-login must preserve authData on the in-memory user"
      assert alice.auth_data["anonymous"].is_a?(Hash),
             "anonymous provider entry must round-trip on self-login"
      refute_nil alice.auth_data["anonymous"]["id"],
                 "anonymous id must be available to the caller post-signup"
    end
  end
end
