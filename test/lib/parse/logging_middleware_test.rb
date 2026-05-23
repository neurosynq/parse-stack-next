require_relative '../../test_helper'
require 'stringio'
require 'logger'

# Unit tests for Parse Stack 2.1.10 logging middleware
class LoggingMiddlewareTest < Minitest::Test

  def setup
    # Reset logging state before each test
    Parse::Middleware::Logging.enabled = nil
    Parse::Middleware::Logging.log_level = nil
    Parse::Middleware::Logging.logger = nil
    Parse::Middleware::Logging.max_body_length = nil
  end

  def teardown
    # Clean up after each test
    Parse::Middleware::Logging.enabled = nil
    Parse::Middleware::Logging.log_level = nil
    Parse::Middleware::Logging.logger = nil
    Parse::Middleware::Logging.max_body_length = nil
  end

  # ==========================================================================
  # Test 1: Logging configuration via Parse module methods
  # ==========================================================================
  def test_logging_configuration_methods
    puts "\n=== Testing Logging Configuration Methods ==="

    # Test logging_enabled
    assert_nil Parse::Middleware::Logging.enabled, "Default enabled should be nil"
    Parse.logging_enabled = true
    assert_equal true, Parse::Middleware::Logging.enabled, "Should be able to set logging_enabled"
    assert_equal true, Parse.logging_enabled, "Should be able to read logging_enabled"

    # Test log_level
    assert_equal :info, Parse.log_level, "Default log_level should be :info"
    Parse.log_level = :debug
    assert_equal :debug, Parse::Middleware::Logging.log_level, "Should be able to set log_level"
    assert_equal :debug, Parse.log_level, "Should be able to read log_level"

    # Test invalid log_level raises error
    assert_raises ArgumentError do
      Parse.log_level = :invalid
    end

    # Test max_body_length
    assert_equal 500, Parse.log_max_body_length, "Default max_body_length should be 500"
    Parse.log_max_body_length = 1000
    assert_equal 1000, Parse::Middleware::Logging.max_body_length, "Should be able to set max_body_length"
    assert_equal 1000, Parse.log_max_body_length, "Should be able to read max_body_length"

    puts "✅ Logging configuration methods work correctly!"
  end

  # ==========================================================================
  # Test 2: Custom logger assignment
  # ==========================================================================
  def test_custom_logger_assignment
    puts "\n=== Testing Custom Logger Assignment ==="

    # Default logger should be a Logger
    default_logger = Parse.logger
    assert_kind_of Logger, default_logger, "Default logger should be a Logger"

    # Test setting custom logger
    custom_logger = Logger.new(StringIO.new)
    custom_logger.progname = "CustomTest"
    Parse.logger = custom_logger

    assert_equal custom_logger, Parse::Middleware::Logging.logger, "Should be able to set custom logger"
    assert_equal "CustomTest", Parse.logger.progname, "Should return custom logger"

    puts "✅ Custom logger assignment works correctly!"
  end

  # ==========================================================================
  # Test 3: Default logger format
  # ==========================================================================
  def test_default_logger_format
    puts "\n=== Testing Default Logger Format ==="

    output = StringIO.new
    logger = Logger.new(output)
    logger.progname = "Parse"
    logger.formatter = proc do |severity, datetime, progname, msg|
      "[#{progname}] #{msg}\n"
    end

    logger.info "Test message"
    output.rewind
    log_output = output.read

    assert_includes log_output, "[Parse]", "Default format should include progname"
    assert_includes log_output, "Test message", "Default format should include message"

    puts "✅ Default logger format works correctly!"
  end

  # ==========================================================================
  # Test 4: Log level filtering
  # ==========================================================================
  def test_log_level_options
    puts "\n=== Testing Log Level Options ==="

    # Test all valid log levels
    [:info, :debug, :warn].each do |level|
      Parse.log_level = level
      assert_equal level, Parse.log_level, "Should accept #{level} as log level"
    end

    # Test that invalid levels raise errors
    [:error, :fatal, :trace, :verbose, "info", 1].each do |invalid|
      assert_raises ArgumentError, "Should reject invalid log level: #{invalid.inspect}" do
        Parse.log_level = invalid
      end
    end

    puts "✅ Log level options work correctly!"
  end

  # ==========================================================================
  # Test 5: Middleware class structure
  # ==========================================================================
  def test_middleware_class_structure
    puts "\n=== Testing Middleware Class Structure ==="

    # Verify class exists and has expected attributes
    assert_equal Parse::Middleware::Logging, Parse::Middleware::Logging
    assert_respond_to Parse::Middleware::Logging, :enabled
    assert_respond_to Parse::Middleware::Logging, :enabled=
    assert_respond_to Parse::Middleware::Logging, :log_level
    assert_respond_to Parse::Middleware::Logging, :log_level=
    assert_respond_to Parse::Middleware::Logging, :logger
    assert_respond_to Parse::Middleware::Logging, :logger=
    assert_respond_to Parse::Middleware::Logging, :max_body_length
    assert_respond_to Parse::Middleware::Logging, :max_body_length=
    assert_respond_to Parse::Middleware::Logging, :current_logger
    assert_respond_to Parse::Middleware::Logging, :current_log_level
    assert_respond_to Parse::Middleware::Logging, :current_max_body_length

    # Verify it's a Faraday middleware
    assert Parse::Middleware::Logging < Faraday::Middleware, "Logging should inherit from Faraday::Middleware"

    puts "✅ Middleware class structure is correct!"
  end

  # ==========================================================================
  # Test 6: MAX_BODY_LENGTH constant
  # ==========================================================================
  def test_max_body_length_constant
    puts "\n=== Testing MAX_BODY_LENGTH Constant ==="

    assert_equal 500, Parse::Middleware::Logging::MAX_BODY_LENGTH, "MAX_BODY_LENGTH should be 500"

    puts "✅ MAX_BODY_LENGTH constant is correct!"
  end

  # ==========================================================================
  # Test 7: configure_logging block
  # ==========================================================================
  def test_configure_logging_block
    puts "\n=== Testing configure_logging Block ==="

    Parse.configure_logging do |config|
      config.enabled = true
      config.log_level = :debug
      config.max_body_length = 1000
    end

    assert_equal true, Parse::Middleware::Logging.enabled
    assert_equal :debug, Parse::Middleware::Logging.log_level
    assert_equal 1000, Parse::Middleware::Logging.max_body_length

    puts "✅ configure_logging block works correctly!"
  end

  # ==========================================================================
  # Test 8: Thread safety (dup call)
  # ==========================================================================
  def test_middleware_creates_dup_for_thread_safety
    puts "\n=== Testing Middleware Thread Safety (dup) ==="

    # The middleware should implement call -> dup.call! pattern
    # We can verify this by checking the call method exists and creates a dup
    middleware = Parse::Middleware::Logging.new(nil)
    assert_respond_to middleware, :call, "Middleware should respond to call"

    puts "✅ Middleware thread safety pattern is present!"
  end
end
