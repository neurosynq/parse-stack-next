require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# End-to-end coverage for the anonymous-user upgrade flow:
#   Parse::User.anonymous_signup → Parse::User#upgrade_anonymous!
#
# The flow models a "guest -> registered" account on a real Parse Server.
# The load-bearing assertion is that after an upgrade the server-side
# +authData.anonymous+ entry is cleared in the same PUT that claims the
# new credentials. Without that, anyone who still holds the original
# random anonymous id (a second device, an exfiltrated payload) can
# silently log into the freshly-named account — a documented Parse
# foot-gun the upgrade helper exists to close.
#
# These tests run under client mode (no master key on the default
# client). The master-key client is only borrowed via #with_master_key
# to perform the cross-user inspection that proves what the server
# actually stored, since +Parse::User#apply_attributes!+ strips
# +authData+ from cross-user hydration even for the master-key caller.
class ClientRestAnonymousAuthIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  # --------------------------------------------------------------------
  # anonymous_signup returns a saved, logged-in user with the anonymous
  # provider attached.
  # --------------------------------------------------------------------
  def test_anonymous_signup_returns_logged_in_anonymous_user
    as_client do
      user = Parse::User.anonymous_signup
      @test_context.track(user)

      refute_nil user.id, "anonymous_signup must return a saved user with objectId"
      assert user.session_token.is_a?(String) && !user.session_token.empty?,
             "anonymous_signup must return a session_token"
      assert user.anonymous?, "anonymous_signup user must report anonymous? true"
      refute_nil user.anonymous_id, "anonymous_signup must surface the provider id"
    end
  end

  # --------------------------------------------------------------------
  # The load-bearing assertion: after upgrade, the server-side row no
  # longer carries +authData.anonymous+. We inspect via the raw client
  # under master key to bypass the SDK's hydration-time strip.
  # --------------------------------------------------------------------
  def test_upgrade_anonymous_clears_anonymous_provider_server_side
    user = nil
    username = "upgraded_#{SecureRandom.hex(4)}"
    password = "p4ss!#{SecureRandom.hex(2)}"

    as_client do
      user = Parse::User.anonymous_signup
      @test_context.track(user)
      assert user.anonymous?, "precondition: user starts anonymous"

      assert user.upgrade_anonymous!(username: username, password: password),
             "upgrade_anonymous! must return truthy on success"
    end

    with_master_key do
      raw = Parse.client.fetch_user(user.id).result
      refute_nil raw, "master-key fetch must return the upgraded user row"
      assert_equal username, raw["username"], "upgraded username must persist"

      # The anonymous provider entry MUST be cleared. Parse Server may
      # either drop the key entirely or store it as null/{} depending on
      # version; both shapes satisfy the security invariant.
      anon = raw.dig("authData", "anonymous")
      assert_nil anon,
                 "authData.anonymous must be nil server-side after upgrade " \
                 "(got: #{raw["authData"].inspect})"
    end
  end

  # --------------------------------------------------------------------
  # In-memory state mirrors the server: anonymous? is false, username is
  # set, anonymous_id returns nil.
  # --------------------------------------------------------------------
  def test_upgrade_anonymous_updates_in_memory_state
    username = "upgraded_mem_#{SecureRandom.hex(4)}"
    password = "p4ss!#{SecureRandom.hex(2)}"
    email = "#{username}@test.com"

    as_client do
      user = Parse::User.anonymous_signup
      @test_context.track(user)

      assert user.upgrade_anonymous!(username: username, password: password, email: email)

      refute user.anonymous?, "user must no longer be anonymous after upgrade"
      assert_nil user.anonymous_id, "anonymous_id must be nil after upgrade"
      assert_equal username, user.username
      assert_equal email, user.email
    end
  end

  # --------------------------------------------------------------------
  # Re-logging in with the new credentials succeeds and returns the same
  # objectId — i.e. the upgrade did not orphan or duplicate the row.
  # --------------------------------------------------------------------
  def test_relogin_with_upgraded_credentials_returns_same_user
    username = "relogin_#{SecureRandom.hex(4)}"
    password = "p4ss!#{SecureRandom.hex(2)}"
    user_id = nil

    as_client do
      anon = Parse::User.anonymous_signup
      @test_context.track(anon)
      user_id = anon.id
      assert anon.upgrade_anonymous!(username: username, password: password)

      relogin = Parse::User.login(username, password)
      refute_nil relogin, "must be able to log in with the upgraded credentials"
      assert_equal user_id, relogin.id,
                   "re-login must return the same objectId, not a new account"
      assert relogin.session_token.is_a?(String) && !relogin.session_token.empty?
    end
  end

  # --------------------------------------------------------------------
  # Guard: upgrade on a user with no @session_token must fail closed.
  # This is the +Parse::User.new.tap { |u| u.id = victim_id }+ attack —
  # the helper must not derive authorization from the objectId alone.
  # --------------------------------------------------------------------
  def test_upgrade_anonymous_without_session_raises
    as_client do
      anon = Parse::User.anonymous_signup
      @test_context.track(anon)

      forged = Parse::User.new
      forged.id = anon.id
      # NB: no session_token set — require_self_session! must fire.

      err = assert_raises(Parse::Error::AuthenticationError) do
        forged.upgrade_anonymous!(username: "x_#{SecureRandom.hex(3)}", password: "pw12345")
      end
      assert_match(/session/i, err.message)
    end
  end

  # --------------------------------------------------------------------
  # Guard: upgrade on an unsaved user (no objectId) must fail closed,
  # even if a session_token is somehow attached.
  # --------------------------------------------------------------------
  def test_upgrade_anonymous_unsaved_user_raises
    as_client do
      u = Parse::User.new
      u.session_token = "fake-but-nonempty-token"
      # @id is nil — the second guard must fire.

      err = assert_raises(Parse::Error::AuthenticationError) do
        u.upgrade_anonymous!(username: "x_#{SecureRandom.hex(3)}", password: "pw12345")
      end
      assert_match(/saved user|objectId/i, err.message)
    end
  end

  # --------------------------------------------------------------------
  # Guard: upgrade on a non-anonymous user must fail closed before any
  # PUT is sent. A registered user calling upgrade_anonymous! is a bug
  # in caller code; we refuse rather than silently strip authData on
  # a real account.
  # --------------------------------------------------------------------
  def test_upgrade_anonymous_on_non_anonymous_user_raises
    seeded_user, seeded_pw = seed_client_user("upgrade_guard")

    as_client do
      me = Parse::User.login!(seeded_user.username, seeded_pw)
      refute me.anonymous?, "fixture: seeded user must NOT be anonymous"

      err = assert_raises(Parse::Error::AuthenticationError) do
        me.upgrade_anonymous!(username: "x_#{SecureRandom.hex(3)}", password: "pw12345")
      end
      assert_match(/anonymous/i, err.message)
    end
  end

  # --------------------------------------------------------------------
  # Server-side conflict: claiming a username that already exists must
  # bubble up as Parse::Error::UsernameTakenError, not a generic
  # ResponseError.
  # --------------------------------------------------------------------
  def test_upgrade_anonymous_duplicate_username_raises_username_taken
    existing, _existing_pw = seed_client_user("taken")

    as_client do
      anon = Parse::User.anonymous_signup
      @test_context.track(anon)

      assert_raises(Parse::Error::UsernameTakenError) do
        anon.upgrade_anonymous!(username: existing.username, password: "pw12345")
      end
    end
  end

  # --------------------------------------------------------------------
  # Server-side conflict: claiming an email that already exists must
  # bubble up as Parse::Error::EmailTakenError.
  # --------------------------------------------------------------------
  def test_upgrade_anonymous_duplicate_email_raises_email_taken
    existing, _existing_pw = seed_client_user("etaken")

    as_client do
      anon = Parse::User.anonymous_signup
      @test_context.track(anon)

      assert_raises(Parse::Error::EmailTakenError) do
        anon.upgrade_anonymous!(
          username: "fresh_#{SecureRandom.hex(4)}",
          password: "pw12345",
          email: existing.email,
        )
      end
    end
  end
end
