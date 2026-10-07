# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"

# Live regression for the MFA bypass on master-keyed clients. A login sent
# with the master key makes Parse Server skip the MFA check and store the
# submitted `authData.mfa` over the enrolled secret. The SDK must send every
# login without the master key, so a wrong code is refused and the enrolled
# secret is left untouched.
class SessionAuditMfaIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    skip "rotp gem not available (add to the Gemfile :test group)" unless Parse::MFA.rotp_available?
    require "rotp"
  end

  def mfa_secret_digest(user_id)
    raw = Parse.client.fetch_object("_User", user_id, use_master_key: true, cache: false).result
    raw.dig("authData", "mfa", "secret").to_s
  end

  def test_master_keyed_client_cannot_bypass_or_overwrite_mfa
    user, password = seed_client_user("audit_mfa")
    logged = Parse::User.login(user.username, password)
    secret = Parse::MFA.generate_secret
    logged.setup_mfa!(secret: secret, token: ROTP::TOTP.new(secret).now)
    before = mfa_secret_digest(user.id)
    refute_empty before

    refute_empty Parse.client.master_key.to_s, "precondition: the default client is master-keyed"
    response = Parse.client.login_with_mfa(user.username, password, "000000")
    refute response.success?, "a wrong code must be refused on a master-keyed client"
    assert_equal before, mfa_secret_digest(user.id), "the enrolled secret must not be overwritten"

    assert_raises(Parse::MFA::RequiredError) { Parse::User.login(user.username, password) }
    assert_raises(Parse::MFA::VerificationError) do
      Parse::User.login_with_mfa(user.username, password, "000000")
    end
    ok = Parse::User.login_with_mfa(user.username, password, ROTP::TOTP.new(secret).now)
    refute_empty ok.session_token.to_s
  end

  def test_signup_on_master_keyed_client_returns_a_session_token
    name = "audit_signup_#{SecureRandom.hex(4)}"
    user = Parse::User.new(username: name, password: "Pw#{SecureRandom.hex(4)}!x")
    assert user.signup!
    refute_empty user.session_token.to_s
    anon = Parse::User.anonymous_signup
    refute_empty anon.session_token.to_s
    assert anon.upgrade_anonymous!(username: "#{name}_up", password: "Pw#{SecureRandom.hex(4)}!y")
  ensure
    [user, anon].compact.each { |u| u.destroy rescue nil if u.id }
  end
end
