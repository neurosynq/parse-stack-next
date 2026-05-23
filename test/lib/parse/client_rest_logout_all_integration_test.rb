require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# End-to-end coverage for the +Parse::User#logout_all!+ /
# +#active_session_count+ / +#sessions+ self-only guard plus the
# session-scoped query plumbing. The guard lives at the SDK layer
# (+require_self_session!+) and fails closed when the instance has no
# +@session_token+, regardless of whether the caller planted an
# objectId. The threat closed here:
#
#   victim_id = "..."                       # known/guessed from a leaked URL
#   forged = Parse::User.new
#   forged.id = victim_id
#   forged.logout_all!                      # would mass-revoke victim's _Session
#                                           # rows on any deployment with a loose
#                                           # _Session CLP
#
# We assert (a) the SDK guard fires on no-session-token, and (b) the
# happy path executes end-to-end under client mode — i.e. the SDK
# automatically self-scopes its +_Session+ query / destroy traffic with
# the caller's own session token, so a client-mode caller does NOT
# have to remember to wrap the call in +Parse.with_session+. Without
# the auto-scoping, the call would 401 against +/classes/_Session+
# under a no-master client.
class ClientRestLogoutAllIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  # --------------------------------------------------------------------
  # SDK-layer guard: no @session_token attached → AuthenticationError.
  # Models the construct-pointer-and-call ATO vector. This must fail
  # BEFORE any network request leaves the SDK.
  # --------------------------------------------------------------------
  def test_logout_all_without_session_token_raises
    victim, _pw = seed_client_user("logoutall_victim")

    as_client do
      forged = Parse::User.new
      forged.id = victim.id
      # NB: no session_token set

      err = assert_raises(Parse::Error::AuthenticationError) do
        forged.logout_all!
      end
      assert_match(/session/i, err.message)
    end
  end

  # --------------------------------------------------------------------
  # Same guard on #active_session_count.
  # --------------------------------------------------------------------
  def test_active_session_count_without_session_token_raises
    victim, _pw = seed_client_user("activecount_victim")

    as_client do
      forged = Parse::User.new
      forged.id = victim.id

      assert_raises(Parse::Error::AuthenticationError) do
        forged.active_session_count
      end
    end
  end

  # --------------------------------------------------------------------
  # Same guard on #sessions.
  # --------------------------------------------------------------------
  def test_sessions_without_session_token_raises
    victim, _pw = seed_client_user("sessions_victim")

    as_client do
      forged = Parse::User.new
      forged.id = victim.id

      assert_raises(Parse::Error::AuthenticationError) do
        forged.sessions
      end
    end
  end

  # --------------------------------------------------------------------
  # Happy path: an authenticated user under client mode can revoke
  # their own sessions. The load-bearing assertion is that the call
  # completes end-to-end (no 401 from the SDK's _Session query going
  # out unscoped) and that the SDK clears @session_token afterward.
  # We deliberately do NOT pin Parse Server's behavior re: whether
  # neighboring session tokens survive a bulk delete — that is a
  # server-side quirk outside the SDK contract.
  # --------------------------------------------------------------------
  def test_logout_all_revokes_self_sessions_under_client_mode
    user, password = seed_client_user("logoutall_self")

    as_client do
      logged_in = Parse::User.login(user.username, password)
      refute_nil logged_in.session_token, "precondition: login must mint a token"

      revoked = logged_in.logout_all!
      assert revoked.is_a?(Integer) && revoked >= 1,
             "logout_all! must return a positive revocation count " \
             "(got: #{revoked.inspect})"
      assert_nil logged_in.session_token,
                 "logout_all! must clear @session_token when keep_current is false"
    end
  end

  # --------------------------------------------------------------------
  # keep_current: true variant. SDK contract: preserves @session_token
  # on the instance and reports a non-negative revocation count. The
  # SDK auto-scopes through the kept token so the query doesn't 401.
  # --------------------------------------------------------------------
  def test_logout_all_keep_current_preserves_in_memory_token
    user, password = seed_client_user("logoutall_keep")

    as_client do
      logged_in = Parse::User.login(user.username, password)
      kept_token = logged_in.session_token
      refute_nil kept_token

      revoked = logged_in.logout_all!(keep_current: true)
      assert revoked.is_a?(Integer) && revoked >= 0
      assert_equal kept_token, logged_in.session_token,
                   "keep_current: true must preserve the in-memory @session_token"
    end
  end

  # --------------------------------------------------------------------
  # active_session_count under client mode runs through the SDK's
  # session-scoped query path. The load-bearing assertion is that the
  # call returns a non-negative Integer (didn't 401 because the SDK
  # forgot to thread the session token).
  # --------------------------------------------------------------------
  def test_active_session_count_under_client_mode_returns_integer
    user, password = seed_client_user("activecount_self")

    as_client do
      logged_in = Parse::User.login(user.username, password)
      count = logged_in.active_session_count
      assert count.is_a?(Integer)
      assert count >= 1, "active_session_count must include the just-issued login session"
    end
  end

  # --------------------------------------------------------------------
  # #sessions under client mode returns the user's own _Session rows
  # via the SDK's auto-scoped query.
  # --------------------------------------------------------------------
  def test_sessions_under_client_mode_returns_array
    user, password = seed_client_user("sessions_self")

    as_client do
      logged_in = Parse::User.login(user.username, password)
      sessions = logged_in.sessions
      assert sessions.is_a?(Array)
      refute sessions.empty?, "must return at least the calling session"
      assert sessions.all? { |s| s.is_a?(Parse::Session) },
             "each entry must be a Parse::Session"
    end
  end
end
