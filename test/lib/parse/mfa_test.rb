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
end
