# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# Client-side coverage for +Parse::User.request_password_reset+ against a live
# Parse Server. Password reset requires a server email adapter + public server
# URL; the test stack configures a capturing adapter (see
# test/cloud/capturing-email-adapter.js, wired via scripts/start-parse.sh) that
# records each outgoing message into an +EmailCapture+ class instead of sending
# it, so the test can assert that an email was generated and read back the reset
# link. Requests run in CLIENT MODE (no master key) — `requestPasswordReset` is
# a public endpoint, which is how a real application initiates a reset.
class ClientRestPasswordResetIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  # Mirrors the documents written by the capturing email adapter.
  class EmailCapture < Parse::Object
    parse_class "EmailCapture"
    property :kind
    property :email
    property :username
    property :link
  end

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  # Poll (with master key) for a captured email. The adapter writes
  # asynchronously, so allow a brief window.
  def captured_email(email, kind: "passwordReset", timeout: 8)
    deadline = Time.now + timeout
    loop do
      row = EmailCapture.query(email: email, kind: kind, order: :createdAt.desc).first
      return row if row
      break if Time.now > deadline
      sleep 0.25
    end
    nil
  end

  # A client-mode reset request for an existing user reports success and the
  # server generates a reset email carrying a tokenized link.
  def test_request_password_reset_for_existing_user_sends_email
    user, _password = seed_client_user("pwreset")
    email = user.email

    ok = as_client do
      assert_client_mode!
      Parse::User.request_password_reset(email)
    end
    assert ok, "request_password_reset should report success for an existing user"

    captured = captured_email(email)
    refute_nil captured, "a password-reset email should have been generated"
    assert_equal "passwordReset", captured.kind
    assert_match %r{\Ahttps?://}, captured.link.to_s, "the email should contain a reset link"
    assert_includes captured.link.to_s, "token=", "the reset link should carry a reset token"
  end

  # Parse Server returns success for an unknown email (so attackers cannot
  # enumerate which addresses are registered), and no email is generated.
  def test_request_password_reset_for_unknown_email_does_not_enumerate
    unknown = "nobody_#{SecureRandom.hex(6)}@test.com"

    ok = as_client { Parse::User.request_password_reset(unknown) }
    assert ok, "an unknown email must be indistinguishable from a known one (no enumeration)"

    assert_nil captured_email(unknown, timeout: 3),
               "no reset email should be generated for an unregistered address"
  end

  # The instance helper resolves the user's own email.
  def test_instance_request_password_reset_uses_user_email
    user, _password = seed_client_user("pwreset_inst")

    ok = as_client { user.request_password_reset }
    assert ok

    refute_nil captured_email(user.email), "the instance helper should trigger a reset email"
  end

  # A blank email short-circuits in the SDK without a server round-trip.
  def test_request_password_reset_blank_email_returns_false
    refute Parse::User.request_password_reset(""),
           "a blank email should return false without contacting the server"
  end
end
