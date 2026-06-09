# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Tests that Parse::API::Users#verify_password participates in the client-side
# login rate-limit the same way #login does: it calls check_login_rate_limit!
# before issuing the request and track_login_attempt after, keyed on the BARE
# username so failures share a bucket with #login.
#
# These do NOT stub check_login_rate_limit! / track_login_attempt (that would
# make the assertions vacuous). Instead they include the real module and inject
# a fake #request so verify_password runs end-to-end without a live server.
class VerifyPasswordRateLimitTest < Minitest::Test

  # A minimal response double exposing the two surfaces verify_password touches.
  class FakeResponse
    def initialize(success)
      @success = success
    end

    def success?
      @success
    end

    attr_accessor :parse_class
  end

  # Host class that includes the real Users module and lets the test control
  # what #request returns (success vs failure) without any HTTP.
  class Limiter
    include Parse::API::Users

    attr_accessor :next_response
    attr_reader :request_count

    def initialize
      @request_count = 0
    end

    def request(*)
      @request_count += 1
      @next_response
    end
  end

  def make_limiter(success: false)
    l = Limiter.new
    l.next_response = FakeResponse.new(success)
    l
  end

  # =========================================================================
  # Guard: a pre-existing lockout blocks verify_password before any request
  # =========================================================================

  def test_verify_password_raises_when_locked_out
    limiter = make_limiter
    limiter.send(:login_rate_limits)["alice"] = {
      failures: 5,
      locked_until: Time.now + 300
    }

    assert_raises(Parse::Error::AccountLockoutError) do
      limiter.verify_password("alice", "secret")
    end
    assert_equal 0, limiter.request_count,
                 "the rate-limit guard must short-circuit before issuing the request"
  end

  # =========================================================================
  # Tracking: repeated verify_password failures accumulate to a lockout
  # =========================================================================

  def test_verify_password_failures_accumulate_to_lockout
    limiter = make_limiter(success: false)
    failures = Parse::API::Users::LOGIN_MAX_FAILURES

    # The Nth failure trips the lockout; the (N+1)th call must be blocked.
    failures.times { limiter.verify_password("mallory", "wrong") }

    assert_raises(Parse::Error::AccountLockoutError) do
      limiter.verify_password("mallory", "wrong")
    end
  end

  def test_verify_password_success_clears_failure_counter
    limiter = make_limiter(success: false)
    # A few failures below the threshold...
    failures = Parse::API::Users::LOGIN_MAX_FAILURES - 1
    failures.times { limiter.verify_password("nadia", "wrong") }

    # Precondition: the failures actually accumulated an entry. Without this,
    # the test would pass even if track_login_attempt were removed entirely
    # (no entry to delete, so the final assert_nil would hold vacuously).
    assert_equal failures, limiter.send(:login_rate_limits)["nadia"][:failures],
                 "failed verify_password calls must accumulate a failure counter"

    # ...then a success deletes the bucket entry entirely. Asserting the entry
    # is gone (not merely that the guard passes) is what actually proves the
    # success-side track wiring — a non-zero failure count below the lockout
    # threshold would also pass the guard.
    limiter.next_response = FakeResponse.new(true)
    limiter.verify_password("nadia", "correct")

    assert_nil limiter.send(:login_rate_limits)["nadia"],
               "a successful verify_password must delete the username's rate-limit entry"
  end

  # =========================================================================
  # Shared bucket: verify_password and login key on the same bare username
  # =========================================================================

  def test_verify_password_shares_lockout_bucket_with_login
    limiter = make_limiter(success: false)
    # Drive login-side failures to the lockout threshold for the username...
    Parse::API::Users::LOGIN_MAX_FAILURES.times do
      limiter.send(:track_login_attempt, "trudy", false)
    end

    # ...and verify_password for the SAME username is now blocked, proving the
    # shared (bare-username) bucket — an attacker cannot pivot past a login
    # lockout by switching to verify_password.
    assert_raises(Parse::Error::AccountLockoutError) do
      limiter.verify_password("trudy", "secret")
    end
  end
end
