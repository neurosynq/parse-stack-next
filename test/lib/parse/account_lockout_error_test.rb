# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Tests for Parse::Error::AccountLockoutError — the typed error raised by the
# SDK's client-side login rate-limit guard in Parse::API::Users#check_login_rate_limit!.
#
# The rate-limit state is stored in a plain in-memory Hash (no Redis/Docker
# required), so these are pure unit tests driven by a minimal object that
# includes the module.
class AccountLockoutErrorTest < Minitest::Test

  # A minimal host class that includes the Users module so we can exercise
  # check_login_rate_limit! and track_login_attempt in isolation.
  def make_limiter
    Class.new { include Parse::API::Users }.new
  end

  # =========================================================================
  # Class existence and ancestry
  # =========================================================================

  def test_account_lockout_error_class_exists
    assert defined?(Parse::Error::AccountLockoutError),
           "Parse::Error::AccountLockoutError must be defined"
  end

  def test_account_lockout_error_is_parse_error_subclass
    assert Parse::Error::AccountLockoutError.ancestors.include?(Parse::Error),
           "AccountLockoutError must descend from Parse::Error"
  end

  def test_account_lockout_error_is_standard_error_subclass
    assert Parse::Error::AccountLockoutError.ancestors.include?(StandardError),
           "AccountLockoutError must descend from StandardError (bare rescue must still catch it)"
  end

  def test_account_lockout_error_subclasses_authentication_error
    # AccountLockoutError is in the login-failure taxonomy alongside
    # EmailNotVerifiedError. A single `rescue AuthenticationError` handler
    # should cover all login failures including lockout.
    assert Parse::Error::AccountLockoutError.ancestors.include?(Parse::Error::AuthenticationError),
           "AccountLockoutError must inherit from AuthenticationError"
  end

  # =========================================================================
  # AccountLockoutError caught by AuthenticationError rescue
  # =========================================================================

  def test_account_lockout_caught_by_authentication_error_rescue
    raised =
      begin
        raise Parse::Error::AccountLockoutError, "locked"
      rescue Parse::Error::AuthenticationError => e
        e
      end
    assert_kind_of Parse::Error::AccountLockoutError, raised,
                   "rescue AuthenticationError must also catch AccountLockoutError"
  end

  def test_account_lockout_caught_by_bare_rescue
    raised =
      begin
        raise Parse::Error::AccountLockoutError, "locked"
      rescue => e
        e
      end
    assert_kind_of Parse::Error::AccountLockoutError, raised,
                   "a bare rescue must still catch AccountLockoutError"
  end

  # =========================================================================
  # check_login_rate_limit! raises AccountLockoutError when locked
  # =========================================================================

  def test_check_login_rate_limit_raises_account_lockout_error_when_locked
    limiter = make_limiter
    # Seed the rate-limit table directly so the test has no timing dependency.
    limiter.send(:login_rate_limits)["alice"] = {
      failures: 5,
      locked_until: Time.now + 300
    }

    assert_raises(Parse::Error::AccountLockoutError) do
      limiter.send(:check_login_rate_limit!, "alice")
    end
  end

  def test_check_login_rate_limit_error_message_contains_username
    limiter = make_limiter
    limiter.send(:login_rate_limits)["bob"] = {
      failures: 5,
      locked_until: Time.now + 300
    }

    error = assert_raises(Parse::Error::AccountLockoutError) do
      limiter.send(:check_login_rate_limit!, "bob")
    end
    assert_match(/bob/, error.message)
  end

  def test_check_login_rate_limit_error_message_contains_wait_seconds
    limiter = make_limiter
    limiter.send(:login_rate_limits)["carol"] = {
      failures: 5,
      locked_until: Time.now + 300
    }

    error = assert_raises(Parse::Error::AccountLockoutError) do
      limiter.send(:check_login_rate_limit!, "carol")
    end
    assert_match(/\d+\s+seconds?/i, error.message,
                 "error message must include a wait duration in seconds")
  end

  def test_check_login_rate_limit_does_not_raise_when_no_entry
    limiter = make_limiter
    # No entry for this username — should return cleanly.
    assert_nil limiter.send(:check_login_rate_limit!, "unknown_user")
  end

  def test_check_login_rate_limit_does_not_raise_when_lockout_expired
    limiter = make_limiter
    limiter.send(:login_rate_limits)["dave"] = {
      failures: 5,
      locked_until: Time.now - 1  # already expired
    }

    # Must not raise; should return nil.
    assert_nil limiter.send(:check_login_rate_limit!, "dave")
  end

  # =========================================================================
  # End-to-end: triggering lockout via track_login_attempt
  # =========================================================================

  def test_lockout_raised_after_max_failures_via_track_login_attempt
    limiter = make_limiter
    # Each failure increments the counter; lockout kicks in at LOGIN_MAX_FAILURES.
    failures = Parse::API::Users::LOGIN_MAX_FAILURES
    failures.times { limiter.send(:track_login_attempt, "eve", false) }

    assert_raises(Parse::Error::AccountLockoutError) do
      limiter.send(:check_login_rate_limit!, "eve")
    end
  end

  def test_lockout_error_is_parse_error_subclass_in_end_to_end_raise
    limiter = make_limiter
    failures = Parse::API::Users::LOGIN_MAX_FAILURES
    failures.times { limiter.send(:track_login_attempt, "frank", false) }

    error = assert_raises(Parse::Error::AccountLockoutError) do
      limiter.send(:check_login_rate_limit!, "frank")
    end
    assert_kind_of Parse::Error, error
    assert_kind_of Parse::Error::AuthenticationError, error
  end

  def test_no_lockout_before_max_failures
    limiter = make_limiter
    failures = Parse::API::Users::LOGIN_MAX_FAILURES - 1
    failures.times { limiter.send(:track_login_attempt, "grace", false) }

    # One below the threshold — must not raise.
    assert_nil limiter.send(:check_login_rate_limit!, "grace")
  end

  def test_successful_login_clears_lockout_state
    limiter = make_limiter
    failures = Parse::API::Users::LOGIN_MAX_FAILURES
    failures.times { limiter.send(:track_login_attempt, "henry", false) }
    # Verify it IS locked first.
    assert_raises(Parse::Error::AccountLockoutError) do
      limiter.send(:check_login_rate_limit!, "henry")
    end

    # A successful login clears the entry.
    limiter.send(:track_login_attempt, "henry", true)
    assert_nil limiter.send(:check_login_rate_limit!, "henry")
  end
end
