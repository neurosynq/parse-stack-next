# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/live_query"

class TestLiveQueryConfiguration < Minitest::Test
  extend Minitest::Spec::DSL

  def setup
    @config = Parse::LiveQuery::Configuration.new
  end

  def test_default_values
    assert_nil @config.url
    assert_nil @config.application_id
    assert_nil @config.client_key
    assert_nil @config.master_key
    assert @config.auto_connect
    assert @config.auto_reconnect

    assert_equal 30.0, @config.ping_interval
    assert_equal 10.0, @config.pong_timeout

    assert_equal 5, @config.circuit_failure_threshold
    assert_equal 60.0, @config.circuit_reset_timeout

    assert_equal 1.0, @config.initial_reconnect_interval
    assert_equal 30.0, @config.max_reconnect_interval
    assert_equal 1.5, @config.reconnect_multiplier
    assert_equal 0.2, @config.reconnect_jitter

    assert_equal 1000, @config.event_queue_size
    assert_equal :drop_oldest, @config.backpressure_strategy

    refute @config.logging_enabled
    assert_equal :info, @config.log_level
    assert_nil @config.logger
  end

  def test_setters_work
    @config.url = "wss://example.com"
    @config.application_id = "app123"
    @config.ping_interval = 20.0

    assert_equal "wss://example.com", @config.url
    assert_equal "app123", @config.application_id
    assert_equal 20.0, @config.ping_interval
  end

  def test_valid_with_defaults
    assert @config.valid?
    assert_empty @config.validate
  end

  def test_validate_ping_interval
    @config.ping_interval = -1

    errors = @config.validate
    assert_includes errors, "ping_interval must be positive"
    refute @config.valid?
  end

  def test_validate_pong_timeout
    @config.pong_timeout = 0

    errors = @config.validate
    assert_includes errors, "pong_timeout must be positive"
  end

  def test_validate_circuit_failure_threshold
    @config.circuit_failure_threshold = -5

    errors = @config.validate
    assert_includes errors, "circuit_failure_threshold must be positive"
  end

  def test_validate_event_queue_size
    @config.event_queue_size = 0

    errors = @config.validate
    assert_includes errors, "event_queue_size must be positive"
  end

  def test_validate_reconnect_jitter
    @config.reconnect_jitter = 1.5

    errors = @config.validate
    assert_includes errors, "reconnect_jitter must be between 0.0 and 1.0"

    @config.reconnect_jitter = -0.1
    errors = @config.validate
    assert_includes errors, "reconnect_jitter must be between 0.0 and 1.0"
  end

  def test_validate_backpressure_strategy
    @config.backpressure_strategy = :invalid

    errors = @config.validate
    assert_includes errors, "backpressure_strategy must be :block, :drop_oldest, or :drop_newest"
  end

  def test_validate_log_level
    @config.log_level = :verbose

    errors = @config.validate
    assert_includes errors, "log_level must be :debug, :info, :warn, or :error"
  end

  def test_to_h
    @config.url = "wss://example.com"
    @config.application_id = "app123"
    @config.client_key = "secret"
    @config.master_key = "super_secret"

    hash = @config.to_h

    assert_equal "wss://example.com", hash[:url]
    assert_equal "app123", hash[:application_id]
    assert_equal "[REDACTED]", hash[:client_key]
    assert_equal "[REDACTED]", hash[:master_key]
    assert_equal 30.0, hash[:ping_interval]
    assert_equal :drop_oldest, hash[:backpressure_strategy]
  end

  def test_to_h_without_secrets
    hash = @config.to_h

    assert_nil hash[:client_key]
    assert_nil hash[:master_key]
  end
end
