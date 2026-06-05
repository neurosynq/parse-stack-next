# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require "securerandom"

# Email-address verification flow against a real Parse Server.
#
# Verification fundamentally changes signup (an unverified user gets no session
# token), so it cannot be enabled for the main integration suite. This test is
# therefore DISRUPTIVE: it recreates the Parse Server container with
# `verifyUserEmails=true` (via scripts/docker/docker-compose.verifyemail.yml),
# exercises the flow, and restores the default config in teardown. It runs only
# under `rake test:integration:disruptive` (excluded from `test` /
# `test:integration` by the `*disruptive*` filename), so it never reconfigures
# the shared server out from under other tests.
#
# The capturing email adapter (test/cloud/capturing-email-adapter.js) records
# the verification email into an `EmailCapture` class so the test can assert it
# was sent and read back the verification link.
class EmailVerificationDisruptiveTest < Minitest::Test
  include ParseStackIntegrationTest

  COMPOSE = "scripts/docker/docker-compose.test.yml"
  OVERRIDE = "scripts/docker/docker-compose.verifyemail.yml"
  HEALTH_URL = "http://localhost:#{ENV['PARSE_HOST_PORT'] || 29337}/parse/health"

  class EmailCapture < Parse::Object
    parse_class "EmailCapture"
    property :kind
    property :email
    property :link
  end

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    recreate_parse!(verify_emails: true)
    super
  end

  def teardown
    super
  ensure
    # Always restore the default (no-verification) config for the shared server.
    recreate_parse!(verify_emails: false)
  end

  def test_signup_sends_verification_email_and_request_resends
    username = "ev_#{SecureRandom.hex(4)}"
    email = "#{username}@test.com"

    user = Parse::User.new(username: username, password: "p4ssw0rd!", email: email)
    assert user.save, "signup should succeed even when email verification is required"

    sent = captured_email(email)
    refute_nil sent, "signup with verifyUserEmails should generate a verification email"
    assert_equal "verification", sent.kind
    assert_includes sent.link.to_s, "token=", "the verification link should carry a token"

    # The SDK can (re)request the verification email for the same address.
    assert Parse::User.request_email_verification(email),
           "request_email_verification should be accepted by the server"

    # And the instance helper resolves the user's own email.
    assert user.request_email_verification,
           "the instance helper should also request a verification email"
  end

  private

  def recreate_parse!(verify_emails:)
    files = verify_emails ? "-f #{COMPOSE} -f #{OVERRIDE}" : "-f #{COMPOSE}"
    system("docker-compose #{files} up -d --force-recreate --no-deps parse",
           out: IO::NULL, err: IO::NULL)
    wait_for_health!
  end

  def wait_for_health!(timeout: 60)
    deadline = Time.now + timeout
    until Time.now > deadline
      return if system("curl -sf #{HEALTH_URL} -o /dev/null 2>/dev/null")
      sleep 1
    end
    flunk "Parse Server did not become healthy within #{timeout}s after recreate"
  end

  def captured_email(email, kind: "verification", timeout: 8)
    deadline = Time.now + timeout
    loop do
      row = EmailCapture.query(email: email, kind: kind, order: :createdAt.desc).first
      return row if row
      break if Time.now > deadline
      sleep 0.25
    end
    nil
  end
end
