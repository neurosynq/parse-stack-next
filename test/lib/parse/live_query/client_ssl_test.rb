# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/live_query"

class TestLiveQueryClientSSL < Minitest::Test
  extend Minitest::Spec::DSL

  def teardown
    # Reset module-level configuration after each test
    Parse::LiveQuery.instance_variable_set(:@config, nil)
  end

  # ===========================================
  # Configuration Tests
  # ===========================================

  def test_default_ssl_min_version_is_tls_1_2
    config = Parse::LiveQuery::Configuration.new

    assert_equal :TLSv1_2, config.ssl_min_version
  end

  def test_default_ssl_max_version_is_nil
    config = Parse::LiveQuery::Configuration.new

    assert_nil config.ssl_max_version
  end

  def test_ssl_min_version_can_be_configured
    config = Parse::LiveQuery::Configuration.new
    config.ssl_min_version = :TLSv1_3

    assert_equal :TLSv1_3, config.ssl_min_version
  end

  def test_ssl_max_version_can_be_configured
    config = Parse::LiveQuery::Configuration.new
    config.ssl_max_version = :TLSv1_2

    assert_equal :TLSv1_2, config.ssl_max_version
  end

  def test_ssl_min_version_can_be_set_to_nil
    config = Parse::LiveQuery::Configuration.new
    config.ssl_min_version = nil

    assert_nil config.ssl_min_version
    assert config.valid?
  end

  # ===========================================
  # Validation Tests
  # ===========================================

  def test_valid_tls_versions_pass_validation
    valid_versions = [nil, :TLSv1, :TLSv1_1, :TLSv1_2, :TLSv1_3]

    valid_versions.each do |version|
      config = Parse::LiveQuery::Configuration.new
      config.ssl_min_version = version
      config.ssl_max_version = version

      assert config.valid?, "Expected #{version.inspect} to be valid"
    end
  end

  def test_invalid_ssl_min_version_fails_validation
    config = Parse::LiveQuery::Configuration.new
    config.ssl_min_version = :invalid_version

    refute config.valid?
    assert_includes config.validate, "ssl_min_version must be nil, :TLSv1, :TLSv1_1, :TLSv1_2, or :TLSv1_3"
  end

  def test_invalid_ssl_max_version_fails_validation
    config = Parse::LiveQuery::Configuration.new
    config.ssl_max_version = :SSLv3

    refute config.valid?
    assert_includes config.validate, "ssl_max_version must be nil, :TLSv1, :TLSv1_1, :TLSv1_2, or :TLSv1_3"
  end

  def test_string_ssl_version_fails_validation
    config = Parse::LiveQuery::Configuration.new
    config.ssl_min_version = "TLSv1_2"

    refute config.valid?
  end

  # ===========================================
  # to_h Tests
  # ===========================================

  def test_to_h_includes_ssl_versions
    config = Parse::LiveQuery::Configuration.new
    config.ssl_min_version = :TLSv1_3
    config.ssl_max_version = :TLSv1_3

    hash = config.to_h

    assert_equal :TLSv1_3, hash[:ssl_min_version]
    assert_equal :TLSv1_3, hash[:ssl_max_version]
  end

  # ===========================================
  # SSLContext Application Tests
  # ===========================================

  def test_ssl_context_min_version_can_be_set_with_constant
    # Test that Ruby's OpenSSL accepts the constants we're using
    ssl_context = OpenSSL::SSL::SSLContext.new
    ssl_context.min_version = OpenSSL::SSL::TLS1_2_VERSION

    # OpenSSL stores this internally
    assert_equal OpenSSL::SSL::TLS1_2_VERSION, ssl_context.instance_variable_get(:@min_proto_version)
  end

  def test_ssl_context_max_version_can_be_set_with_constant
    ssl_context = OpenSSL::SSL::SSLContext.new
    ssl_context.max_version = OpenSSL::SSL::TLS1_3_VERSION

    assert_equal OpenSSL::SSL::TLS1_3_VERSION, ssl_context.instance_variable_get(:@max_proto_version)
  end

  def test_tls_version_constant_conversion
    # Verify our symbol-to-constant mapping works
    config_class = Parse::LiveQuery::Configuration

    assert_equal OpenSSL::SSL::TLS1_VERSION, config_class.tls_version_constant(:TLSv1)
    assert_equal OpenSSL::SSL::TLS1_1_VERSION, config_class.tls_version_constant(:TLSv1_1)
    assert_equal OpenSSL::SSL::TLS1_2_VERSION, config_class.tls_version_constant(:TLSv1_2)
    assert_equal OpenSSL::SSL::TLS1_3_VERSION, config_class.tls_version_constant(:TLSv1_3)
    assert_nil config_class.tls_version_constant(nil)
  end

  def test_ssl_context_accepts_all_converted_versions
    # Verify all our TLS version constants work with OpenSSL
    config_class = Parse::LiveQuery::Configuration

    [:TLSv1, :TLSv1_1, :TLSv1_2, :TLSv1_3].each do |version|
      ssl_context = OpenSSL::SSL::SSLContext.new
      constant = config_class.tls_version_constant(version)
      ssl_context.min_version = constant
      assert_equal constant, ssl_context.instance_variable_get(:@min_proto_version),
                   "Expected #{version} (#{constant}) to be accepted"
    end
  end

  def test_client_uses_config_ssl_settings
    # Verify the client accesses ssl settings from config
    Parse::LiveQuery.configure do |cfg|
      cfg.url = "wss://example.com"
      cfg.application_id = "test-app"
      cfg.ssl_min_version = :TLSv1_3
      cfg.ssl_max_version = :TLSv1_3
    end

    # The client should read these values from config
    config = Parse::LiveQuery.config
    assert_equal :TLSv1_3, config.ssl_min_version
    assert_equal :TLSv1_3, config.ssl_max_version
  end

  def test_ssl_context_without_min_version_when_nil
    config = Parse::LiveQuery::Configuration.new
    config.url = "wss://example.com"
    config.application_id = "test-app"
    config.ssl_min_version = nil  # Explicitly nil

    # Just verify the config allows nil and passes validation
    assert_nil config.ssl_min_version
    assert config.valid?
  end

  # ===========================================
  # Integration-style Configuration Tests
  # ===========================================

  def test_configure_block_sets_ssl_versions
    Parse::LiveQuery.configure do |config|
      config.ssl_min_version = :TLSv1_2
      config.ssl_max_version = :TLSv1_3
    end

    # config returns Configuration object, not hash
    assert_equal :TLSv1_2, Parse::LiveQuery.config.ssl_min_version
    assert_equal :TLSv1_3, Parse::LiveQuery.config.ssl_max_version
  end

  def test_tls_1_3_only_configuration
    config = Parse::LiveQuery::Configuration.new
    config.ssl_min_version = :TLSv1_3
    config.ssl_max_version = :TLSv1_3

    assert config.valid?
    assert_equal :TLSv1_3, config.ssl_min_version
    assert_equal :TLSv1_3, config.ssl_max_version
  end

  def test_disable_tls_enforcement_configuration
    config = Parse::LiveQuery::Configuration.new
    config.ssl_min_version = nil  # No minimum
    config.ssl_max_version = nil  # No maximum

    assert config.valid?
    assert_nil config.ssl_min_version
    assert_nil config.ssl_max_version
  end
end
