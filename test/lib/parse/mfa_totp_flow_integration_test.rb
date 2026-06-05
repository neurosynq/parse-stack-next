# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# End-to-end coverage for the TOTP MFA flow against a real MFA-enabled Parse
# Server. The test stack configures Parse Server's built-in TOTP adapter (see
# scripts/start-parse.sh) and the suite depends on the `rotp` gem to generate
# valid time-based codes, so this exercises the actual enroll / login / status /
# disable path rather than just the SDK boundary.
#
# #mfa_enabled? / #mfa_status read back authData.mfa. The SDK never retains the
# raw value (the server exposes the TOTP secret + recovery codes there), but it
# preserves a non-sensitive `{ "status" => "enabled" }` projection, so the
# status methods work after an ordinary fetch — asserted below alongside the
# secret-is-not-leaked guarantee.
class MfaTotpFlowIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    skip "rotp gem not available (add to the Gemfile :test group)" unless Parse::MFA.rotp_available?
    require "rotp"
  end

  # Enroll a freshly-seeded user in TOTP MFA. Returns the logged-in user, its
  # password, the TOTP secret, and the recovery codes.
  def enroll_user(prefix)
    user, password = seed_client_user(prefix)
    logged = Parse::User.login(user.username, password)
    secret = Parse::MFA.generate_secret
    recovery = logged.setup_mfa!(secret: secret, token: ROTP::TOTP.new(secret).now)
    [logged, password, secret, recovery]
  end

  def logged_in?(result)
    result.is_a?(Parse::User) && !result.session_token.to_s.empty?
  end

  # Enrollment returns recovery codes, and a password-only login is afterwards
  # rejected by the server as requiring an additional MFA factor.
  def test_totp_enrollment_returns_recovery_and_enforces_mfa
    user, password, _secret, recovery = enroll_user("mfa_enroll")

    refute_empty Array(recovery), "enrollment should return one-time recovery codes"

    err = assert_raises(Parse::Error) { Parse.client.login(user.username, password) }
    assert_match(/additional authData|mfa/i, err.message,
                 "password-only login on an enrolled account must be rejected as MFA-required")
  end

  # #mfa_enabled? / #mfa_status report enabled after an ordinary (untrusted)
  # fetch, and the fetched record must NOT carry the raw TOTP secret or recovery
  # codes — only the leak-safe status projection.
  def test_mfa_status_readable_after_fetch_without_leaking_secret
    user, _password, secret, _ = enroll_user("mfa_status")

    fetched = Parse::User.query(objectId: user.id).first
    refute_nil fetched

    assert fetched.mfa_enabled?, "mfa_enabled? should be true after enrollment"
    assert_equal :enabled, fetched.mfa_status

    blob = fetched.auth_data.to_s
    refute_includes blob, secret, "the TOTP secret must never survive into a fetched user"
    refute_match(/recovery/i, blob, "recovery codes must never survive into a fetched user")
  end

  # Self-disable with a valid current code clears MFA (password-only login works
  # again); a wrong code is rejected and leaves MFA enabled.
  def test_self_disable_with_valid_code_clears_mfa
    user, password, secret, _ = enroll_user("mfa_selfdisable")

    user.fetch
    user.disable_mfa!(current_token: ROTP::TOTP.new(secret).now)

    relog = Parse::User.login(user.username, password)
    assert logged_in?(relog), "after self-disable, password-only login should succeed"
  end

  def test_self_disable_with_wrong_code_is_rejected
    user, password, _secret, _ = enroll_user("mfa_selfdisable_bad")

    user.fetch
    assert_raises(Parse::MFA::VerificationError) do
      user.disable_mfa!(current_token: "000000")
    end

    # MFA must still be enforced — password-only login is still rejected.
    assert_raises(Parse::Error) { Parse.client.login(user.username, password) }
  end

  # A valid time-based code completes the second factor and yields a session.
  #
  # These login assertions run in CLIENT MODE (non-master). The master key
  # bypasses MFA by design — Parse Server's MFA `validateLogin` short-circuits
  # on `req.master` — so MFA enforcement is only meaningful for a normal client,
  # which is how real applications authenticate users.
  def test_login_with_valid_totp_succeeds
    user, password, secret, _ = enroll_user("mfa_login")

    result = as_client do
      Parse::User.login_with_mfa(user.username, password, ROTP::TOTP.new(secret).now)
    end

    assert logged_in?(result), "a valid TOTP code should produce a logged-in session"
  end

  # A wrong (or empty) code must NOT authenticate a non-master client.
  def test_login_with_wrong_totp_does_not_authenticate
    user, password, _secret, _ = enroll_user("mfa_wrong")

    as_client do
      %w[000000 123456].each do |bad|
        result =
          begin
            Parse::User.login_with_mfa(user.username, password, bad)
          rescue Parse::Error
            nil
          end
        refute logged_in?(result), "a wrong MFA code (#{bad}) must not authenticate"
      end
    end
  end

  # The master-key disable path (authData.mfa = nil, no mfa_enabled? guard)
  # clears MFA so a password-only login works again.
  def test_master_key_disable_restores_password_login
    user, password, _secret, _ = enroll_user("mfa_disable")
    admin, _admin_pw = seed_client_user("mfa_admin")

    # `allow_unverified: true` opts into caller-side authorization (this
    # test vouches for `admin`); without it the method now fails closed.
    user.disable_mfa_master_key!(authorized_by: admin, allow_unverified: true)

    relog = Parse::User.login(user.username, password)
    assert logged_in?(relog), "after master-key disable, password-only login should succeed again"
  end
end
