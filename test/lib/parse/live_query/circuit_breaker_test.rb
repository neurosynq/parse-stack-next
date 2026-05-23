# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/live_query"

class TestLiveQueryCircuitBreaker < Minitest::Test
  extend Minitest::Spec::DSL

  def setup
    @breaker = Parse::LiveQuery::CircuitBreaker.new(
      failure_threshold: 3,
      reset_timeout: 0.1,
      half_open_requests: 1,
    )
  end

  def test_initial_state_is_closed
    assert @breaker.closed?
    refute @breaker.open?
    refute @breaker.half_open?
    assert_equal :closed, @breaker.state
  end

  def test_allows_requests_when_closed
    assert @breaker.allow_request?
  end

  def test_stays_closed_after_failures_below_threshold
    2.times { @breaker.record_failure }

    assert @breaker.closed?
    assert @breaker.allow_request?
    assert_equal 2, @breaker.failure_count
  end

  def test_opens_after_reaching_failure_threshold
    3.times { @breaker.record_failure }

    assert @breaker.open?
    refute @breaker.closed?
    assert_equal 3, @breaker.failure_count
  end

  def test_blocks_requests_when_open
    3.times { @breaker.record_failure }

    refute @breaker.allow_request?
  end

  def test_resets_failure_count_on_success_when_closed
    2.times { @breaker.record_failure }
    @breaker.record_success

    assert_equal 0, @breaker.failure_count
  end

  def test_transitions_to_half_open_after_timeout
    3.times { @breaker.record_failure }
    assert @breaker.open?

    # Wait for reset timeout
    sleep 0.15

    assert @breaker.allow_request?
    assert @breaker.half_open?
  end

  def test_closes_after_success_in_half_open
    3.times { @breaker.record_failure }
    sleep 0.15
    @breaker.allow_request? # Transition to half_open

    @breaker.record_success

    assert @breaker.closed?
    assert_equal 0, @breaker.failure_count
  end

  def test_reopens_on_failure_in_half_open
    3.times { @breaker.record_failure }
    sleep 0.15
    @breaker.allow_request? # Transition to half_open

    @breaker.record_failure

    assert @breaker.open?
  end

  def test_reset_closes_circuit
    3.times { @breaker.record_failure }
    assert @breaker.open?

    @breaker.reset!

    assert @breaker.closed?
    assert_equal 0, @breaker.failure_count
  end

  def test_time_until_half_open_returns_nil_when_not_open
    assert_nil @breaker.time_until_half_open
  end

  def test_time_until_half_open_returns_positive_when_open
    3.times { @breaker.record_failure }

    time = @breaker.time_until_half_open
    assert time > 0
    assert time <= 0.1
  end

  def test_info_returns_correct_hash
    info = @breaker.info

    assert_equal :closed, info[:state]
    assert_equal 0, info[:failure_count]
    assert_equal 0, info[:success_count]
    assert_equal 3, info[:failure_threshold]
    assert_equal 0.1, info[:reset_timeout]
    assert_nil info[:last_failure_at]
  end

  def test_state_change_callback
    old_states = []
    new_states = []

    breaker = Parse::LiveQuery::CircuitBreaker.new(
      failure_threshold: 2,
      reset_timeout: 0.1,
      on_state_change: ->(old, new_state) {
        old_states << old
        new_states << new_state
      },
    )

    2.times { breaker.record_failure }

    assert_equal [:closed], old_states
    assert_equal [:open], new_states
  end

  def test_last_failure_at_is_set_on_failure
    assert_nil @breaker.last_failure_at

    @breaker.record_failure

    refute_nil @breaker.last_failure_at
    assert_instance_of Time, @breaker.last_failure_at
  end

  def test_thread_safety_of_state_transitions
    threads = 10.times.map do
      Thread.new do
        100.times do
          @breaker.record_failure
          @breaker.record_success
        end
      end
    end

    threads.each(&:join)

    # Should not raise any errors and state should be valid
    assert Parse::LiveQuery::CircuitBreaker::STATES.include?(@breaker.state)
  end

  def test_callback_can_safely_query_breaker_state
    # This test verifies callbacks are invoked outside the synchronized block.
    # If callbacks were inside the lock, this would deadlock with non-reentrant locks
    # or cause issues with reentrant locks in more complex scenarios.
    callback_states = []

    breaker = Parse::LiveQuery::CircuitBreaker.new(
      failure_threshold: 2,
      reset_timeout: 0.1,
      on_state_change: ->(old_state, new_state) {
        # Query breaker state from within callback - should not deadlock
        callback_states << {
          old: old_state,
          new: new_state,
          current_state: breaker.state,
          is_open: breaker.open?,
          is_closed: breaker.closed?,
          info: breaker.info,
        }
      },
    )

    # Trigger state change: closed -> open
    2.times { breaker.record_failure }

    assert_equal 1, callback_states.length
    assert_equal :closed, callback_states[0][:old]
    assert_equal :open, callback_states[0][:new]
    assert_equal :open, callback_states[0][:current_state]
    assert callback_states[0][:is_open]
    refute callback_states[0][:is_closed]
  end

  def test_callback_invoked_after_state_change_complete
    # Verify the state is already updated when callback is invoked
    observed_states = []

    breaker = Parse::LiveQuery::CircuitBreaker.new(
      failure_threshold: 1,
      reset_timeout: 0.05,
      on_state_change: ->(old_state, new_state) {
        observed_states << breaker.state
      },
    )

    breaker.record_failure  # closed -> open
    sleep 0.1
    breaker.allow_request?  # open -> half_open
    breaker.record_success  # half_open -> closed

    assert_equal [:open, :half_open, :closed], observed_states
  end

  def test_concurrent_state_changes_with_callbacks
    callback_count = Concurrent::AtomicFixnum.new(0)

    breaker = Parse::LiveQuery::CircuitBreaker.new(
      failure_threshold: 1,
      reset_timeout: 0.01,
      on_state_change: ->(_old, _new) {
        callback_count.increment
        # Simulate slow callback
        sleep 0.001
      },
    )

    threads = 5.times.map do
      Thread.new do
        20.times do
          breaker.record_failure
          sleep 0.02  # Allow timeout to elapse
          breaker.allow_request?  # May trigger half_open
          breaker.record_success
        end
      end
    end

    threads.each(&:join)

    # Callbacks should have been called (exact count varies due to timing)
    assert callback_count.value > 0
    # State should be valid
    assert Parse::LiveQuery::CircuitBreaker::STATES.include?(breaker.state)
  end

  def test_no_callback_when_state_unchanged
    callback_count = 0

    breaker = Parse::LiveQuery::CircuitBreaker.new(
      failure_threshold: 3,
      reset_timeout: 0.1,
      on_state_change: ->(_old, _new) { callback_count += 1 },
    )

    # Record failures below threshold - no state change
    2.times { breaker.record_failure }
    assert_equal 0, callback_count

    # Record successes when closed - no state change
    breaker.record_success
    assert_equal 0, callback_count

    # Reset when already closed - no state change
    breaker.reset!
    assert_equal 0, callback_count
  end
end
