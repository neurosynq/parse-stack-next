# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit regression for the per-email rate limiter on
# {Parse::API::Users#request_password_reset}. Without this guard, an
# attacker can flood +POST /requestPasswordReset+ for a victim email
# (DoS / email-spam vector) or probe many emails to enumerate the user
# table — Parse Server's response is intentionally identical for
# found/not-found emails, so the SDK is the only place to apply
# pre-network throttling.
class ApiUsersPasswordResetRateLimitTest < Minitest::Test
  # Stub host that includes the API module so we drive the rate-limit
  # path without standing up a real Parse::Client (which needs an
  # HTTP server). Captures requests instead of dispatching them.
  class FakeClient
    include Parse::API::Users

    attr_reader :requests

    def initialize
      @requests = []
    end

    # Stand-in for Parse::Client#request used by the API module.
    def request(method, path, body: nil, headers: {}, opts: {})
      @requests << { method: method, path: path, body: body }
      # Mimic the API contract: a Parse::Response duck-type with a
      # successful empty body. The rate limiter doesn't care about the
      # response content — every attempt is intentionally counted.
      Struct.new(:success?, :code, :result, :error).new(true, nil, {}, nil)
    end
  end

  def setup
    @client = FakeClient.new
  end

  def test_first_attempts_are_allowed
    # The login limiter cap is 5 failures before exponential backoff;
    # the password-reset path shares that limiter so the first 5
    # requests for a single email must round-trip.
    5.times do |i|
      @client.request_password_reset("a@example.com")
      assert_equal i + 1, @client.requests.size,
                   "attempt #{i + 1} must round-trip below the lockout cap"
    end
  end

  def test_sixth_attempt_locks_email_out
    5.times { @client.request_password_reset("locked@example.com") }
    err = assert_raises(RuntimeError) do
      @client.request_password_reset("locked@example.com")
    end
    assert_match(/Login rate limited/, err.message,
                 "expected the shared limiter's lockout message")
    assert_match(/pwreset:locked@example\.com/, err.message,
                 "limiter key must be namespaced under pwreset: to avoid colliding with a username")
    assert_equal 5, @client.requests.size,
                 "the locked-out attempt must NOT have left the SDK"
  end

  def test_different_emails_have_independent_counters
    5.times { @client.request_password_reset("a@example.com") }
    # a@ is now locked, but b@ has a fresh counter.
    @client.request_password_reset("b@example.com")
    assert_equal 6, @client.requests.size

    # And a@ is still locked.
    assert_raises(RuntimeError) do
      @client.request_password_reset("a@example.com")
    end
  end

  def test_username_login_and_email_reset_do_not_collide
    # If the limiter keyed on the raw string, an attacker who knew a
    # victim used the same value as both their username and recovery
    # email could exhaust the counter via either endpoint. The pwreset:
    # prefix prevents that — five password-reset attempts must NOT
    # leave the matching login counter touched.
    5.times { @client.request_password_reset("shared@example.com") }
    # Reach into the limiter's private state to inspect both keys.
    tracker = @client.send(:login_rate_limits)
    assert tracker.key?("pwreset:shared@example.com"),
           "pwreset counter must be tracked under the namespaced key"
    refute tracker.key?("shared@example.com"),
           "raw 'shared@example.com' must not collide with the login counter"
  end
end
