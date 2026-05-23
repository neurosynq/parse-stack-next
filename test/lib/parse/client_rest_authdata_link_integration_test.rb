require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# End-to-end coverage for +Parse::User#link_auth_data!+ and
# +#unlink_auth_data!+ under client mode (no master key).
#
# Historical bug 0.1 (shipped fix in 5.0): +update_user+ silently
# dropped its +headers:+ kwarg, so any caller threading per-request
# auth (notably +link_auth_data!+ via +set_service_auth_data+) would
# silently fall back to the default client's auth — which, if a master
# key happened to be configured in the process, would send the master
# key on every link call. This is a privilege escalation foot-gun: a
# component intended to operate on the user's own row under their
# session would instead bear admin credentials end-to-end.
#
# These tests pin the fixed behavior:
#   1. Under client mode + ambient session, +link_auth_data!+ succeeds
#      end-to-end — the PUT carries the user's session token, the
#      server accepts it, and the row is updated.
#   2. The +authData+ written through the link path round-trips
#      server-side (confirmed via master-key inspection).
#   3. +unlink_auth_data!+ clears the provider entry in the same way.
#
# We use the +:anonymous+ provider because Parse Server's
# Facebook/Google/Apple adapters validate the OAuth token against the
# upstream IdP and reject obvious-fixture values. Anonymous is the
# only provider the default Parse Server accepts without external
# verification (see +client_rest_anonymous_auth_integration_test.rb+
# for the same rationale).
class ClientRestAuthdataLinkIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  # --------------------------------------------------------------------
  # Happy path: a real (username/password) user under client mode +
  # ambient session can link the anonymous provider via the SDK
  # helper. The load-bearing assertion is that the call SUCCEEDS at
  # all — without the headers-forwarding fix it would 401 (or
  # silently exit as the master if one were ambient).
  # --------------------------------------------------------------------
  def test_link_auth_data_under_client_mode_succeeds
    user, password = seed_client_user("link_anon")
    anon_id = SecureRandom.uuid

    as_client do
      me = Parse::User.login!(user.username, password)
      refute_nil me.session_token, "precondition: login must mint a session"

      Parse.with_session(me.session_token) do
        # No exception means the PUT was authorized by the session,
        # not the (absent) master key.
        me.link_auth_data!(:anonymous, id: anon_id)
      end
    end

    # Server-side state is the load-bearing assertion: round-trip the
    # row under master key (the SDK's hydration-time strip would
    # otherwise hide authData from a cross-user fetch — master-key
    # client gets the raw row). Parse Server's PUT /users/:id response
    # body only echoes +updatedAt+, so we cannot assert the linked
    # authData from the in-memory user without an extra GET — the
    # SDK behavior we're pinning is "the write actually landed".
    with_master_key do
      raw = Parse.client.fetch_user(user.id).result
      assert_equal anon_id, raw.dig("authData", "anonymous", "id"),
                   "server-side authData.anonymous.id must match the linked value " \
                   "(got: #{raw["authData"].inspect})"
    end
  end

  # --------------------------------------------------------------------
  # The unlink path is the exact same plumbing (PUT with
  # +authData: { anonymous: nil }+); it must also route through the
  # session-token auth and clear the provider both in memory and
  # server-side.
  # --------------------------------------------------------------------
  def test_unlink_auth_data_under_client_mode_clears_provider
    user, password = seed_client_user("unlink_anon")
    anon_id = SecureRandom.uuid

    as_client do
      me = Parse::User.login!(user.username, password)

      Parse.with_session(me.session_token) do
        me.link_auth_data!(:anonymous, id: anon_id)
        me.unlink_auth_data!(:anonymous)
      end
    end

    with_master_key do
      # Confirm the unlink landed. Parse Server may either drop the
      # provider key entirely or store it as null/{}; both shapes
      # satisfy the security invariant.
      raw = Parse.client.fetch_user(user.id).result
      anon = raw.dig("authData", "anonymous")
      assert_nil anon,
                 "authData.anonymous must be nil server-side after unlink " \
                 "(got: #{raw["authData"].inspect})"
    end
  end

  # --------------------------------------------------------------------
  # Regression guard: without an ambient session token AND without a
  # master key, the SDK has no auth to send. Parse Server requires
  # authorization to write +authData+ on an existing row, so the
  # call must surface a server-side denial rather than silently
  # succeeding under some hidden credential.
  # --------------------------------------------------------------------
  def test_link_auth_data_without_session_or_master_is_denied
    user, _password = seed_client_user("link_unauth")

    as_client do
      # NB: no Parse.with_session wrapping → unauthenticated.
      err = assert_raises(Parse::Client::ResponseError) do
        user.link_auth_data!(:anonymous, id: SecureRandom.uuid)
      end
      assert err.is_a?(Parse::Client::ResponseError),
             "must surface a Parse error rather than silently succeeding " \
             "(got: #{err.class}: #{err.message})"
    end
  end
end
