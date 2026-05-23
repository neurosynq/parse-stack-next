# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

class MFATest < Minitest::Test
  def setup
    # Reset MFA config before each test
    Parse::MFA.instance_variable_set(:@config, nil)
  end

  # ==========================================================================
  # Configuration Tests
  # ==========================================================================

  def test_default_config
    config = Parse::MFA.config
    assert_equal "Parse App", config[:issuer]
    assert_equal 6, config[:digits]
    assert_equal 30, config[:period]
    assert_equal "SHA1", config[:algorithm]
    assert_equal 20, config[:secret_length]
  end

  def test_configure
    Parse::MFA.configure do |config|
      config[:issuer] = "Test App"
      config[:digits] = 8
    end

    assert_equal "Test App", Parse::MFA.config[:issuer]
    assert_equal 8, Parse::MFA.config[:digits]
  end

  # ==========================================================================
  # Secret Generation Tests
  # ==========================================================================

  def test_generate_secret_requires_rotp
    skip "rotp gem not available" unless Parse::MFA.rotp_available?

    secret = Parse::MFA.generate_secret
    assert_kind_of String, secret
    assert secret.length >= 20, "Secret should be at least 20 characters"
  end

  def test_generate_secret_minimum_length
    skip "rotp gem not available" unless Parse::MFA.rotp_available?

    # Even if we request shorter, should be at least 20
    secret = Parse::MFA.generate_secret(length: 10)
    assert secret.length >= 20, "Secret should enforce minimum of 20 characters"
  end

  def test_generate_secret_custom_length
    skip "rotp gem not available" unless Parse::MFA.rotp_available?

    secret = Parse::MFA.generate_secret(length: 32)
    assert secret.length >= 32, "Secret should be at least requested length"
  end

  def test_generate_secret_raises_without_rotp
    # Mock rotp unavailability
    Parse::MFA.stub(:rotp_available?, false) do
      assert_raises(Parse::MFA::DependencyError) do
        Parse::MFA.generate_secret
      end
    end
  end

  # ==========================================================================
  # TOTP Tests
  # ==========================================================================

  def test_verify_valid_code
    skip "rotp gem not available" unless Parse::MFA.rotp_available?

    secret = Parse::MFA.generate_secret
    current = Parse::MFA.current_code(secret)

    assert Parse::MFA.verify(secret, current), "Should verify current code"
  end

  def test_verify_invalid_code
    skip "rotp gem not available" unless Parse::MFA.rotp_available?

    secret = Parse::MFA.generate_secret
    refute Parse::MFA.verify(secret, "000000"), "Should reject invalid code"
  end

  def test_verify_blank_inputs
    skip "rotp gem not available" unless Parse::MFA.rotp_available?

    secret = Parse::MFA.generate_secret
    refute Parse::MFA.verify(nil, "123456"), "Should reject nil secret"
    refute Parse::MFA.verify("", "123456"), "Should reject empty secret"
    refute Parse::MFA.verify(secret, nil), "Should reject nil code"
    refute Parse::MFA.verify(secret, ""), "Should reject empty code"
  end

  def test_current_code_format
    skip "rotp gem not available" unless Parse::MFA.rotp_available?

    secret = Parse::MFA.generate_secret
    code = Parse::MFA.current_code(secret)

    assert_kind_of String, code
    assert_equal 6, code.length, "Default code should be 6 digits"
    assert_match(/^\d{6}$/, code, "Code should be numeric")
  end

  # ==========================================================================
  # Provisioning URI Tests
  # ==========================================================================

  def test_provisioning_uri
    skip "rotp gem not available" unless Parse::MFA.rotp_available?

    secret = Parse::MFA.generate_secret
    uri = Parse::MFA.provisioning_uri(secret, "test@example.com")

    assert_kind_of String, uri
    assert uri.start_with?("otpauth://totp/"), "Should be otpauth URI"
    assert uri.include?("secret="), "Should include secret"
    assert uri.include?("test@example.com"), "Should include account name"
  end

  def test_provisioning_uri_with_issuer
    skip "rotp gem not available" unless Parse::MFA.rotp_available?

    secret = Parse::MFA.generate_secret
    uri = Parse::MFA.provisioning_uri(secret, "user@test.com", issuer: "MyApp")

    assert uri.include?("issuer=MyApp"), "Should include custom issuer"
  end

  # ==========================================================================
  # QR Code Tests
  # ==========================================================================

  def test_qr_code_svg
    skip "rotp or rqrcode gem not available" unless Parse::MFA.rotp_available? && Parse::MFA.rqrcode_available?

    secret = Parse::MFA.generate_secret
    svg = Parse::MFA.qr_code(secret, "user@test.com")

    assert_kind_of String, svg
    assert svg.include?("<svg"), "Should be SVG format"
  end

  def test_qr_code_raises_without_rqrcode
    skip "rotp gem not available" unless Parse::MFA.rotp_available?

    secret = Parse::MFA.generate_secret

    Parse::MFA.stub(:rqrcode_available?, false) do
      assert_raises(Parse::MFA::DependencyError) do
        Parse::MFA.qr_code(secret, "user@test.com")
      end
    end
  end

  # ==========================================================================
  # Auth Data Builder Tests
  # ==========================================================================

  def test_build_setup_auth_data
    auth_data = Parse::MFA.build_setup_auth_data(secret: "TESTSECRET", token: "123456")

    expected = {
      mfa: {
        secret: "TESTSECRET",
        token: "123456",
      },
    }
    assert_equal expected, auth_data
  end

  def test_build_login_auth_data
    auth_data = Parse::MFA.build_login_auth_data(token: "654321")

    expected = {
      mfa: {
        token: "654321",
      },
    }
    assert_equal expected, auth_data
  end

  def test_build_sms_setup_auth_data
    auth_data = Parse::MFA.build_sms_setup_auth_data(mobile: "+1234567890")

    expected = {
      mfa: {
        mobile: "+1234567890",
      },
    }
    assert_equal expected, auth_data
  end

  def test_build_sms_confirm_auth_data
    auth_data = Parse::MFA.build_sms_confirm_auth_data(mobile: "+1234567890", token: "123456")

    expected = {
      mfa: {
        mobile: "+1234567890",
        token: "123456",
      },
    }
    assert_equal expected, auth_data
  end

  # ==========================================================================
  # Error Class Tests
  # ==========================================================================

  def test_verification_error
    error = Parse::MFA::VerificationError.new
    assert_equal "Invalid MFA token", error.message

    custom = Parse::MFA::VerificationError.new("Custom message")
    assert_equal "Custom message", custom.message
  end

  def test_required_error
    error = Parse::MFA::RequiredError.new
    assert_equal "MFA token is required for this account", error.message
  end

  def test_already_enabled_error
    error = Parse::MFA::AlreadyEnabledError.new
    assert_equal "MFA is already set up on this account", error.message
  end

  def test_not_enabled_error
    error = Parse::MFA::NotEnabledError.new
    assert_equal "MFA is not enabled for this user", error.message
  end

  def test_dependency_error
    error = Parse::MFA::DependencyError.new("rotp")
    assert error.message.include?("rotp")
    assert error.message.include?("Gemfile")
  end

  def test_forbidden_error
    error = Parse::MFA::ForbiddenError.new
    assert_equal "Not authorized to perform this MFA operation", error.message
  end

  # ==========================================================================
  # disable_mfa_master_key! authorization gate (NEW-AUTH-8)
  # ==========================================================================

  def test_disable_mfa_master_key_requires_authorized_by
    target = Parse::User.new(objectId: "victim")
    assert_raises(ArgumentError) { target.disable_mfa_master_key! }
  end

  def test_disable_mfa_master_key_rejects_non_user_authorized_by
    target = Parse::User.new(objectId: "victim")
    assert_raises(ArgumentError) do
      target.disable_mfa_master_key!(authorized_by: "an_admin_id")
    end
    assert_raises(ArgumentError) do
      target.disable_mfa_master_key!(authorized_by: { id: "admin" })
    end
  end

  def test_disable_mfa_master_key_rejects_unpersisted_authorized_by
    target = Parse::User.new(objectId: "victim")
    operator = Parse::User.new
    assert_raises(ArgumentError) do
      target.disable_mfa_master_key!(authorized_by: operator)
    end
  end

  def test_disable_mfa_admin_alias_still_requires_authorized_by
    target = Parse::User.new(objectId: "victim")
    capture_io do
      assert_raises(ArgumentError) { target.disable_mfa_admin! }
    end
  end

  def test_disable_mfa_admin_alias_emits_deprecation_warning
    target = Parse::User.new(objectId: "victim")
    _out, err = capture_io do
      target.disable_mfa_admin!(authorized_by: "not_a_user") rescue ArgumentError
    end
    assert_match(/DEPRECATION/, err)
    assert_match(/disable_mfa_master_key!/, err)
  end

  # ==========================================================================
  # setup_mfa! / setup_sms_mfa! TOCTOU narrowing (NEW-AUTH-3)
  # ==========================================================================
  #
  # Stale in-memory state must not bypass the AlreadyEnabledError guard.
  # The fix calls #fetch before consulting #mfa_enabled? so a re-setup
  # attempt sees current server-side authData. This is mitigation, not
  # elimination — the residual race window is one round-trip wide.

  def test_setup_mfa_calls_fetch_before_enabled_check
    user = Parse::User.new(objectId: "u1")
    # In-memory auth_data is empty (no MFA from the SDK's perspective).
    # The singleton fetch flips the ivar directly to bypass dirty
    # tracking / autofetch, simulating a server response that says MFA
    # is already enabled.
    fetch_called = false
    user.define_singleton_method(:fetch) do |*_args, **_kw|
      fetch_called = true
      instance_variable_set(:@auth_data, { "mfa" => { "status" => "enabled" } })
      self
    end
    assert_raises(Parse::MFA::AlreadyEnabledError) do
      user.setup_mfa!(secret: "A" * 32, token: "123456")
    end
    assert fetch_called, "setup_mfa! must call #fetch before consulting mfa_enabled?"
  end

  def test_setup_sms_mfa_calls_fetch_before_enabled_check
    user = Parse::User.new(objectId: "u1")
    fetch_called = false
    user.define_singleton_method(:fetch) do |*_args, **_kw|
      fetch_called = true
      instance_variable_set(:@auth_data, { "mfa" => { "status" => "enabled" } })
      self
    end
    assert_raises(Parse::MFA::AlreadyEnabledError) do
      user.setup_sms_mfa!(mobile: "+14155551234")
    end
    assert fetch_called, "setup_sms_mfa! must call #fetch before consulting mfa_enabled?"
  end

  def test_setup_mfa_skips_fetch_when_user_unpersisted
    # No objectId — nothing to fetch. The guard runs against the
    # in-memory state (which is empty for a brand-new user), so setup
    # proceeds to the server call (mocked away by client absence).
    user = Parse::User.new
    fetch_called = false
    user.define_singleton_method(:fetch) do |*_args, **_kw|
      fetch_called = true
      self
    end
    # We expect this to fail at the client call (no objectId), not at
    # the AlreadyEnabledError guard. The point of the assertion is just
    # that #fetch was NOT invoked on an id-less user.
    begin
      user.setup_mfa!(secret: "A" * 32, token: "123456")
    rescue StandardError
      # Any error past the fetch decision is acceptable for this test.
    end
    refute fetch_called, "setup_mfa! must not call #fetch on an unpersisted user"
  end
end
