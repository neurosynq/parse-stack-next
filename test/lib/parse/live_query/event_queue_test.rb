# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/live_query"

class TestLiveQueryEventQueue < Minitest::Test
  extend Minitest::Spec::DSL

  def setup
    @queue = Parse::LiveQuery::EventQueue.new(
      max_size: 5,
      strategy: :drop_oldest,
    )
  end

  def teardown
    @queue.stop(drain: false, timeout: 1) if @queue.running?
  end

  def test_initial_state
    assert_equal 0, @queue.size
    assert @queue.empty?
    refute @queue.full?
    refute @queue.running?
    assert_equal 0, @queue.dropped_count
    assert_equal 0, @queue.enqueued_count
    assert_equal 0, @queue.processed_count
  end

  def test_default_values
    queue = Parse::LiveQuery::EventQueue.new

    assert_equal 1000, queue.max_size
    assert_equal :drop_oldest, queue.strategy
  end

  def test_invalid_strategy_raises_error
    assert_raises(ArgumentError) do
      Parse::LiveQuery::EventQueue.new(strategy: :invalid)
    end
  end

  def test_start_requires_block
    assert_raises(ArgumentError) do
      @queue.start
    end
  end

  def test_enqueue_requires_running_queue
    refute @queue.enqueue("event")
    assert_equal 0, @queue.size
  end

  def test_enqueue_and_process
    processed = []
    @queue.start { |event| processed << event }

    @queue.enqueue("event1")
    @queue.enqueue("event2")

    # Wait for processing
    sleep 0.1

    assert_equal ["event1", "event2"], processed
    assert_equal 2, @queue.processed_count
    assert_equal 2, @queue.enqueued_count
  end

  def test_drop_oldest_strategy
    dropped_events = []
    processing_started = false
    mutex = Mutex.new
    cond = ConditionVariable.new

    queue = Parse::LiveQuery::EventQueue.new(
      max_size: 3,
      strategy: :drop_oldest,
      on_drop: ->(event, reason) { dropped_events << [event, reason] },
    )

    # Start with slow processor that signals when processing
    queue.start do |_|
      mutex.synchronize do
        processing_started = true
        cond.signal
      end
      sleep 2 # Block processing
    end

    # Wait for first event to start processing
    mutex.synchronize do
      4.times { |i| queue.enqueue("event#{i}") }
      cond.wait(mutex, 1) until processing_started
    end

    # Now queue has 3 items (max_size), adding more should drop oldest
    queue.enqueue("event4")

    queue.stop(drain: false, timeout: 0.1)

    # At least one should be dropped
    assert queue.dropped_count >= 1
  end

  def test_drop_newest_strategy
    dropped_events = []
    processing_started = false
    mutex = Mutex.new
    cond = ConditionVariable.new

    queue = Parse::LiveQuery::EventQueue.new(
      max_size: 3,
      strategy: :drop_newest,
      on_drop: ->(event, reason) { dropped_events << [event, reason] },
    )

    # Start with slow processor
    queue.start do |_|
      mutex.synchronize do
        processing_started = true
        cond.signal
      end
      sleep 2
    end

    # Wait for first event to start processing
    mutex.synchronize do
      4.times { |i| queue.enqueue("event#{i}") }
      cond.wait(mutex, 1) until processing_started
    end

    # Now try to add when full - should be dropped
    result = queue.enqueue("event4")

    queue.stop(drain: false, timeout: 0.1)

    # Either the result is false or dropped_count > 0
    assert((!result) || (queue.dropped_count >= 1))
  end

  def test_stop_with_drain
    processed = []
    @queue.start { |event| processed << event }

    @queue.enqueue("event1")
    @queue.enqueue("event2")

    @queue.stop(drain: true, timeout: 2)

    assert_equal ["event1", "event2"], processed
  end

  def test_stop_without_drain
    processed = []
    @queue.start { |event| sleep 0.1; processed << event }

    5.times { |i| @queue.enqueue("event#{i}") }

    @queue.stop(drain: false, timeout: 0.05)

    # Not all events should be processed
    assert processed.size < 5
  end

  def test_full_when_at_capacity
    processing_started = false
    mutex = Mutex.new
    cond = ConditionVariable.new

    @queue.start do |_|
      mutex.synchronize do
        processing_started = true
        cond.signal
      end
      sleep 2
    end

    # Enqueue events and wait for processing to start
    mutex.synchronize do
      6.times { |i| @queue.enqueue("event#{i}") }
      cond.wait(mutex, 1) until processing_started
    end

    # With one being processed, queue should be at capacity
    assert @queue.size >= 4 # At least 4 in queue (5 enqueued, 1 processing)

    @queue.stop(drain: false, timeout: 0.1)
  end

  def test_stats
    @queue.start { |_| }
    @queue.enqueue("event")
    sleep 0.1

    stats = @queue.stats

    assert_equal 5, stats[:max_size]
    assert_equal :drop_oldest, stats[:strategy]
    assert stats[:running]
    assert_equal 1, stats[:enqueued_count]
    assert stats[:processed_count] >= 0
    assert_equal 0, stats[:dropped_count]
    assert stats.key?(:utilization)

    @queue.stop(drain: false)
  end

  def test_clear
    @queue.start { |_| sleep 1 }

    3.times { |i| @queue.enqueue("event#{i}") }
    sleep 0.05

    cleared = @queue.clear

    assert cleared >= 0 # Some may have been processed
    assert_equal 0, @queue.size

    @queue.stop(drain: false)
  end

  def test_processing_error_does_not_break_queue
    processed = []
    @queue.start do |event|
      raise "test error" if event == "error"
      processed << event
    end

    @queue.enqueue("event1")
    @queue.enqueue("error")
    @queue.enqueue("event2")

    sleep 0.2

    assert_includes processed, "event1"
    assert_includes processed, "event2"
    refute_includes processed, "error"

    @queue.stop(drain: false)
  end

  def test_thread_safety
    queue = Parse::LiveQuery::EventQueue.new(max_size: 100)
    processed = []
    mutex = Mutex.new

    queue.start { |event| mutex.synchronize { processed << event } }

    threads = 5.times.map do |t|
      Thread.new do
        20.times { |i| queue.enqueue("t#{t}_e#{i}") }
      end
    end

    threads.each(&:join)
    sleep 0.5

    queue.stop(drain: true, timeout: 2)

    # All events should be processed
    assert_equal 100, processed.size
  end
end
