# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/live_query"
require "stringio"

class TestLiveQueryLogging < Minitest::Test
  extend Minitest::Spec::DSL

  def setup
    Parse::LiveQuery::Logging.reset!
  end

  def teardown
    Parse::LiveQuery::Logging.reset!
  end

  def test_disabled_by_default
    refute Parse::LiveQuery::Logging.enabled
  end

  def test_default_log_level_is_info
    assert_equal :info, Parse::LiveQuery::Logging.log_level
  end

  def test_can_enable_logging
    Parse::LiveQuery::Logging.enabled = true

    assert Parse::LiveQuery::Logging.enabled
  end

  def test_can_set_log_level
    Parse::LiveQuery::Logging.log_level = :debug

    assert_equal :debug, Parse::LiveQuery::Logging.log_level
  end

  def test_invalid_log_level_raises_error
    assert_raises(ArgumentError) do
      Parse::LiveQuery::Logging.log_level = :verbose
    end
  end

  def test_valid_log_levels
    %i[debug info warn error].each do |level|
      Parse::LiveQuery::Logging.log_level = level
      assert_equal level, Parse::LiveQuery::Logging.log_level
    end
  end

  def test_can_set_custom_logger
    custom_logger = Logger.new(StringIO.new)
    Parse::LiveQuery::Logging.logger = custom_logger

    assert_equal custom_logger, Parse::LiveQuery::Logging.logger
  end

  def test_default_logger_writes_to_stdout
    logger = Parse::LiveQuery::Logging.default_logger

    assert_instance_of Logger, logger
    assert_equal "Parse::LiveQuery", logger.progname
  end

  def test_current_logger_returns_custom_when_set
    custom = Logger.new(StringIO.new)
    Parse::LiveQuery::Logging.logger = custom

    assert_equal custom, Parse::LiveQuery::Logging.current_logger
  end

  def test_current_logger_returns_default_when_not_set
    assert_equal Parse::LiveQuery::Logging.default_logger, Parse::LiveQuery::Logging.current_logger
  end

  def test_does_not_log_when_disabled
    output = StringIO.new
    Parse::LiveQuery::Logging.logger = Logger.new(output)
    Parse::LiveQuery::Logging.enabled = false

    Parse::LiveQuery::Logging.info("test message")

    assert_empty output.string
  end

  def test_logs_when_enabled
    output = StringIO.new
    Parse::LiveQuery::Logging.logger = Logger.new(output)
    Parse::LiveQuery::Logging.enabled = true

    Parse::LiveQuery::Logging.info("test message")

    assert_includes output.string, "test message"
  end

  def test_debug_respects_log_level
    output = StringIO.new
    Parse::LiveQuery::Logging.logger = Logger.new(output)
    Parse::LiveQuery::Logging.enabled = true
    Parse::LiveQuery::Logging.log_level = :info

    Parse::LiveQuery::Logging.debug("debug message")

    assert_empty output.string
  end

  def test_debug_logs_at_debug_level
    output = StringIO.new
    Parse::LiveQuery::Logging.logger = Logger.new(output)
    Parse::LiveQuery::Logging.enabled = true
    Parse::LiveQuery::Logging.log_level = :debug

    Parse::LiveQuery::Logging.debug("debug message")

    assert_includes output.string, "debug message"
  end

  def test_warn_logs_at_info_level
    output = StringIO.new
    Parse::LiveQuery::Logging.logger = Logger.new(output)
    Parse::LiveQuery::Logging.enabled = true
    Parse::LiveQuery::Logging.log_level = :info

    Parse::LiveQuery::Logging.warn("warning message")

    assert_includes output.string, "warning message"
  end

  def test_error_logs_at_warn_level
    output = StringIO.new
    Parse::LiveQuery::Logging.logger = Logger.new(output)
    Parse::LiveQuery::Logging.enabled = true
    Parse::LiveQuery::Logging.log_level = :warn

    Parse::LiveQuery::Logging.error("error message")

    assert_includes output.string, "error message"
  end

  def test_context_is_included_in_log
    output = StringIO.new
    Parse::LiveQuery::Logging.logger = Logger.new(output)
    Parse::LiveQuery::Logging.enabled = true

    Parse::LiveQuery::Logging.info("test", key: "value", count: 42)

    assert_includes output.string, "key=value"
    assert_includes output.string, "count=42"
  end

  def test_exception_context_formats_correctly
    output = StringIO.new
    Parse::LiveQuery::Logging.logger = Logger.new(output)
    Parse::LiveQuery::Logging.enabled = true

    error = StandardError.new("test error")
    Parse::LiveQuery::Logging.error("failed", error: error)

    assert_includes output.string, "StandardError: test error"
  end

  def test_long_string_context_is_truncated
    output = StringIO.new
    Parse::LiveQuery::Logging.logger = Logger.new(output)
    Parse::LiveQuery::Logging.enabled = true

    long_value = "x" * 200
    Parse::LiveQuery::Logging.info("test", data: long_value)

    assert_includes output.string, "..."
    refute_includes output.string, "x" * 200
  end

  def test_reset_clears_all_settings
    Parse::LiveQuery::Logging.enabled = true
    Parse::LiveQuery::Logging.log_level = :debug
    Parse::LiveQuery::Logging.logger = Logger.new(StringIO.new)

    Parse::LiveQuery::Logging.reset!

    refute Parse::LiveQuery::Logging.enabled
    assert_equal :info, Parse::LiveQuery::Logging.log_level
    assert_nil Parse::LiveQuery::Logging.logger
  end
end
