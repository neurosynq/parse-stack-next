# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/live_query"

class TestLiveQueryHealthMonitor < Minitest::Test
  extend Minitest::Spec::DSL

  class MockClient
    attr_accessor :ping_sent, :stale_handled

    def initialize
      @ping_sent = false
      @stale_handled = false
    end

    private

    def send_ping
      @ping_sent = true
    end

    def handle_stale_connection
      @stale_handled = true
    end
  end

  def setup
    @mock_client = MockClient.new
    @monitor = Parse::LiveQuery::HealthMonitor.new(
      client: @mock_client,
      ping_interval: 0.1,
      pong_timeout: 0.05,
    )
  end

  def teardown
    @monitor.stop
  end

  def test_initial_state
    refute @monitor.running?
    assert_nil @monitor.connection_established_at
    assert_nil @monitor.last_activity_at
    assert_nil @monitor.last_pong_at
  end

  def test_default_values
    monitor = Parse::LiveQuery::HealthMonitor.new(client: @mock_client)

    assert_equal 30.0, monitor.ping_interval
    assert_equal 10.0, monitor.pong_timeout
  end

  def test_start_sets_initial_timestamps
    @monitor.start

    assert @monitor.running?
    refute_nil @monitor.connection_established_at
    refute_nil @monitor.last_activity_at
    refute_nil @monitor.last_pong_at
  end

  def test_start_is_idempotent
    @monitor.start
    first_established = @monitor.connection_established_at

    @monitor.start

    assert_equal first_established, @monitor.connection_established_at
  end

  def test_stop_clears_running_state
    @monitor.start
    @monitor.stop

    refute @monitor.running?
  end

  def test_stop_is_idempotent
    @monitor.start
    @monitor.stop
    @monitor.stop # Should not raise

    refute @monitor.running?
  end

  def test_record_pong_updates_timestamps
    @monitor.start
    initial_pong = @monitor.last_pong_at

    sleep 0.01
    @monitor.record_pong

    assert @monitor.last_pong_at > initial_pong
    assert @monitor.last_activity_at >= @monitor.last_pong_at
  end

  def test_record_activity_updates_timestamp
    @monitor.start
    initial_activity = @monitor.last_activity_at

    sleep 0.01
    @monitor.record_activity

    assert @monitor.last_activity_at > initial_activity
  end

  def test_not_stale_when_not_awaiting_pong
    @monitor.start

    refute @monitor.stale?
  end

  def test_healthy_when_running_and_recent_activity
    @monitor.start

    assert @monitor.healthy?
  end

  def test_not_healthy_when_not_running
    refute @monitor.healthy?
  end

  def test_seconds_since_activity
    @monitor.start
    sleep 0.05

    seconds = @monitor.seconds_since_activity

    assert seconds >= 0.05
    assert seconds < 1.0
  end

  def test_seconds_since_pong
    @monitor.start
    sleep 0.05

    seconds = @monitor.seconds_since_pong

    assert seconds >= 0.05
    assert seconds < 1.0
  end

  def test_health_info_returns_correct_hash
    @monitor.start

    info = @monitor.health_info

    assert info[:running]
    assert info.key?(:healthy)
    assert info.key?(:stale)
    assert info.key?(:awaiting_pong)
    assert info.key?(:connection_established_at)
    assert info.key?(:last_activity_at)
    assert info.key?(:last_pong_at)
    assert_equal 0.1, info[:ping_interval]
    assert_equal 0.05, info[:pong_timeout]
  end

  def test_ping_is_sent_after_interval
    @monitor.start

    # Wait for ping interval plus a bit
    sleep 0.15

    assert @mock_client.ping_sent
  end

  def test_stale_connection_handled_when_no_pong
    @monitor.start

    # Wait for ping + pong timeout + margin
    sleep 0.25

    # Connection should be detected as stale
    assert @mock_client.stale_handled
  end
end
