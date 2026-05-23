require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# End-to-end coverage for +Parse::User.autologin_service+ under client
# mode. This is the SDK entry point for federated-identity flows
# (Facebook, Google, Apple, custom OAuth, anonymous): the caller hands
# the SDK a provider name + provider-specific authData blob; the SDK
# creates-or-finds the user, plants the authData under +authData.<svc>+,
# and returns a logged-in user.
#
# Most OAuth providers (Facebook, Google, Apple) require Parse Server
# to have an auth adapter configured AND validate the supplied token
# against the upstream IdP — neither holds in the test Docker setup,
# which only has the built-in +anonymous+ adapter accepting fixtures.
#
# What this pins:
#   1. +autologin_service(:anonymous, …)+ end-to-end on client mode
#      returns a logged-in user with a real session token — proving
#      the federated-create path works without master key.
#   2. The user is marked +anonymous?+ and the session token actually
#      authenticates against +/users/me+. Defense against "we got a
#      user object back but the token is bogus / planted".
#   3. Providers Parse Server can't validate (Facebook with a fixture)
#      surface the rejection rather than smuggling a master key.
class ClientRestOauthAutologinIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  # --------------------------------------------------------------------
  # Anonymous provider: the always-available federated path. Asserts
  # the full create+login flow under client mode.
  # --------------------------------------------------------------------
  def test_autologin_service_anonymous_under_client_mode
    user = nil
    as_client do
      assert_client_mode!
      user = Parse::User.autologin_service(:anonymous, { id: SecureRandom.uuid })
    end

    refute_nil user, "autologin_service must return a User"
    refute_nil user.id, "user must have an objectId"
    refute_nil user.session_token, "user must carry a session_token from the server"
    assert user.anonymous?, "user must report anonymous?" if user.respond_to?(:anonymous?)

    # Defense against "the SDK fabricated a user without actually
    # logging in": confirm /users/me accepts the session token.
    as_client do
      me = Parse.client.current_user(user.session_token)
      assert me.success?, "/users/me must accept the token from autologin_service " \
                          "(got: #{me.inspect})"
      assert_equal user.id, me.result["objectId"]
    end

    @test_context.track(user)
  end

  # --------------------------------------------------------------------
  # The +anonymous_signup+ convenience routes through autologin_service.
  # Pin that it also works under client mode and yields an upgradable
  # user.
  # --------------------------------------------------------------------
  def test_anonymous_signup_convenience_under_client_mode
    user = nil
    as_client do
      user = Parse::User.anonymous_signup
    end

    refute_nil user.session_token
    assert user.anonymous?, "freshly anonymous_signup'd user must report anonymous?" if user.respond_to?(:anonymous?)
    @test_context.track(user)
  end

  # --------------------------------------------------------------------
  # Provider rejection: a Facebook autologin with a fixture token must
  # be rejected by Parse Server (its adapter validates against the
  # upstream FB Graph API and refuses obvious-fixture tokens). The
  # invariant is "no silent master-key smuggling": the SDK must surface
  # the rejection. If the test Parse Server doesn't have the FB adapter
  # configured, the call fails with a different (still-rejected) shape
  # and we still pin "no silent success".
  # --------------------------------------------------------------------
  def test_autologin_service_unverifiable_provider_rejected
    raised = nil
    as_client do
      assert_client_mode!
      begin
        Parse::User.autologin_service(:facebook, {
          id: "fixture-fb-id",
          access_token: "fixture-fb-token",
        })
      rescue StandardError => e
        # Broad rescue is intentional: Parse Server's adapter rejection
        # could surface as +Parse::Error::*+, +Parse::Client::ResponseError+,
        # or a transport-layer error depending on adapter config. The
        # invariant we pin is "something was raised, NOT silent success".
        raised = e
      end
    end

    refute_nil raised,
               "autologin_service with a fixture FB token must raise (got no error — possible silent escalation)"
  end
end
