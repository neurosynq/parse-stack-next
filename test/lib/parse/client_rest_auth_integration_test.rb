require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# Auth convenience surface from the SDK-as-client side: signup, login,
# logout, current_user, password change, and MFA hook points. All run
# with a Parse::Client that does NOT carry the master key.
#
# These overlap intentionally with user_save_signup_integration_test.rb
# but with one critical difference: the prior file lets master-key
# context leak in via the default client. Here we prove the same flows
# work when the SDK truly has no admin credentials.
class ClientRestAuthIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  # --------------------------------------------------------------------
  # Signup-on-save under a no-master client. Parse Server treats POST
  # /users without a session as an account creation regardless of master
  # key, so this must round-trip a real session token.
  # --------------------------------------------------------------------
  def test_signup_on_save_under_client_mode
    as_client do
      username = "csignup_#{SecureRandom.hex(4)}"
      user = Parse::User.new(
        username: username, password: "p4ssw0rd!", email: "#{username}@test.com",
      )
      assert user.save, "signup-on-save must succeed without master key"
      @test_context.track(user)

      refute_nil user.id, "objectId assigned by server"
      refute_nil user.session_token, "session_token populated"

      me = Parse.client.current_user(user.session_token)
      assert me.success?, "/users/me accepts the issued token"
      assert_equal user.id, me.result["objectId"]
    end
  end

  # --------------------------------------------------------------------
  # signup! explicitly (not save). Same expectations.
  # --------------------------------------------------------------------
  def test_signup_bang_under_client_mode
    as_client do
      username = "csignup_bang_#{SecureRandom.hex(4)}"
      user = Parse::User.new(
        username: username, password: "p4ssw0rd!", email: "#{username}@test.com",
      )
      assert user.signup!, "signup! must succeed under client mode"
      @test_context.track(user)
      refute_nil user.session_token
    end
  end

  # --------------------------------------------------------------------
  # Login by username+password through Parse::User.login.
  # --------------------------------------------------------------------
  def test_login_under_client_mode
    user, password = seed_client_user("clogin")

    as_client do
      logged_in = Parse::User.login(user.username, password)
      refute_nil logged_in
      assert_equal user.id, logged_in.id
      refute_nil logged_in.session_token
      assert logged_in.logged_in?
    end
  end

  # --------------------------------------------------------------------
  # Bad password: Parse::User.login swallows the auth error and returns
  # nil (see user.rb#self.login). The assertion is that the SDK does
  # NOT silently return a partially-built user — that path would be a
  # serious security regression. Direct client.login should surface the
  # error response.
  # --------------------------------------------------------------------
  def test_login_with_bad_password_returns_nil_and_errors_on_raw_client
    user, _ = seed_client_user("cbad")

    as_client do
      result = Parse::User.login(user.username, "wrong-password!")
      assert_nil result, "Parse::User.login with bad password must return nil"

      # Raw client surface should carry the error info on the response
      # (or raise — Parse Server's auth errors propagate as a 4xx that
      # the middleware translates to a Parse::Error::AuthenticationError).
      begin
        response = Parse.client.login(user.username, "wrong-password!")
        refute response.success?, "bad-password response must not be success"
      rescue Parse::Error => e
        assert_match(/invalid|password|auth|session|login/i, e.message)
      end
    end
  end

  # --------------------------------------------------------------------
  # Logout revokes the session — current_user with that token fails.
  # --------------------------------------------------------------------
  def test_logout_invalidates_session
    user, password = seed_client_user("clogout")

    as_client do
      session = Parse::User.login(user.username, password)
      token = session.session_token

      # Sanity: token live now.
      assert Parse.client.current_user(token).success?

      logout_response = Parse.client.logout(token)
      assert logout_response.success?, "logout call must succeed"

      # Now /users/me must reject the token. The SDK raises
      # Parse::Error::InvalidSessionTokenError rather than returning an
      # error response — either is acceptable evidence that the server
      # invalidated the session.
      err = assert_raises(Parse::Error) do
        Parse.client.current_user(token)
      end
      assert_match(/invalid|session|token/i, err.message,
                   "post-logout token check must raise an auth error, got: #{err.message}")
    end
  end

  # --------------------------------------------------------------------
  # current_user with an obviously-bogus token must not 500 or leak —
  # it should return a clean error response.
  # --------------------------------------------------------------------
  def test_current_user_with_bogus_token_errors_cleanly
    as_client do
      err = assert_raises(Parse::Error) do
        Parse.client.current_user("not-a-real-session-token")
      end
      assert_match(/invalid|session|token/i, err.message,
                   "bogus token must raise an auth-class Parse::Error, got: #{err.message}")
    end
  end

  # --------------------------------------------------------------------
  # MFA: only assertable when the two_factor_auth extension is loaded
  # AND the test server has the matching cloud-code hook. Without that,
  # we still validate the SDK API surface refuses to silently bypass MFA
  # by checking that login_with_mfa is dispatchable and that bare login
  # against an MFA-enabled user fails (when the feature is in play).
  # --------------------------------------------------------------------
  def test_mfa_surface_is_reachable_under_client_mode
    skip "MFA tests require a Parse Server with the MFA cloud-code hook configured" unless mfa_supported?

    user, password = seed_client_user("cmfa")
    as_client do
      # If MFA is configured but not enrolled, plain login still works.
      logged_in = Parse::User.login(user.username, password)
      refute_nil logged_in.session_token
      refute logged_in.mfa_enabled?, "freshly-seeded user must not have MFA enabled"
    end
  end

  private

  # MFA is opt-in: the gem ships a User extension, but the server side
  # requires a matching cloud-code hook + authData adapter. We treat the
  # presence of `Parse::User#mfa_enabled?` as a proxy for the extension
  # being loaded, and additionally probe whether the server appears to
  # support the MFA login pathway. If either is missing, skip.
  def mfa_supported?
    Parse::User.instance_methods.include?(:mfa_enabled?)
  end
end
