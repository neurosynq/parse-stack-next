# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit-level coverage for `Parse::Console.watch` and `Parse::Console.wait_for`.
# These tests do NOT spin up a LiveQuery server — instead we stub
# `klass.subscribe` to hand back a fake subscription that records the
# handlers and lets the test drive synthetic events through them.
class ConsoleHelpersTest < Minitest::Test
  # Minimal stand-in for a Parse::LiveQuery::Subscription. Records every
  # `on(:event)` callback and exposes #emit / #emit_error to drive them.
  class FakeSubscription
    attr_reader :handlers, :unsubscribed, :open_args

    def initialize(open_args)
      @open_args   = open_args
      @handlers    = Hash.new { |h, k| h[k] = [] }
      @unsubscribed = false
    end

    def on(event, &block)
      @handlers[event.to_sym] << block
      self
    end

    def emit(event, obj)
      @handlers[event.to_sym].each { |cb| cb.call(obj) }
    end

    def emit_error(err)
      @handlers[:error].each { |cb| cb.call(err) }
    end

    def unsubscribe
      @unsubscribed = true
    end
  end

  # Stand-in for a Parse::Object subclass with a .subscribe entry point.
  class FakeKlass
    class << self
      attr_accessor :last_subscription

      def parse_class
        "FakeKlass"
      end

      def subscribe(where:, fields:, session_token:)
        @last_subscription = FakeSubscription.new(
          where: where, fields: fields, session_token: session_token,
        )
      end
    end
  end

  def setup
    FakeKlass.last_subscription = nil
  end

  # ------------------------------------------------------------------
  # wait_for
  # ------------------------------------------------------------------
  def test_wait_for_registers_default_events
    started = Queue.new
    waiter = Thread.new do
      started << :ready
      Parse::Console.wait_for(FakeKlass)
    end
    started.pop
    # Spin until the helper has had a chance to register its handlers.
    Thread.pass until FakeKlass.last_subscription&.handlers&.any?

    sub = FakeKlass.last_subscription
    assert sub.handlers.key?(:create), "default :create handler must be registered"
    assert sub.handlers.key?(:enter),  "default :enter handler must be registered"
    refute sub.handlers.key?(:update), ":update must NOT be on the default wait_for set"

    obj = Object.new
    sub.emit(:create, obj)
    assert_same obj, waiter.value
    assert sub.unsubscribed, "wait_for must unsubscribe on exit"
  end

  def test_wait_for_skips_events_that_fail_the_predicate
    started = Queue.new
    waiter = Thread.new do
      started << :ready
      Parse::Console.wait_for(FakeKlass) { |o| o == :match }
    end
    started.pop
    Thread.pass until FakeKlass.last_subscription&.handlers&.any?

    sub = FakeKlass.last_subscription
    sub.emit(:create, :skip_me)
    sub.emit(:enter,  :match)
    assert_equal :match, waiter.value
  end

  def test_wait_for_propagates_predicate_exception_through_queue
    started = Queue.new
    waiter = Thread.new do
      Thread.current.report_on_exception = false
      started << :ready
      Parse::Console.wait_for(FakeKlass) { |_o| raise ArgumentError, "boom" }
    end
    started.pop
    Thread.pass until FakeKlass.last_subscription&.handlers&.any?

    sub = FakeKlass.last_subscription
    sub.emit(:create, Object.new)
    err = assert_raises(ArgumentError) { waiter.value }
    assert_equal "boom", err.message
    assert sub.unsubscribed, "wait_for must unsubscribe even when predicate raises"
  end

  def test_wait_for_times_out_when_no_event_arrives
    assert_raises(Timeout::Error) do
      Parse::Console.wait_for(FakeKlass, timeout: 0.05)
    end
    assert FakeKlass.last_subscription.unsubscribed,
           "wait_for must unsubscribe on timeout"
  end

  def test_wait_for_raises_when_subscription_emits_error
    started = Queue.new
    waiter = Thread.new do
      Thread.current.report_on_exception = false
      started << :ready
      Parse::Console.wait_for(FakeKlass)
    end
    started.pop
    Thread.pass until FakeKlass.last_subscription&.handlers&.any?

    sub = FakeKlass.last_subscription
    err_obj = RuntimeError.new("ws gone")
    sub.emit_error(err_obj)
    assert_raises(RuntimeError) { waiter.value }
    assert sub.unsubscribed
  end

  def test_wait_for_respects_explicit_event_list
    started = Queue.new
    Thread.new do
      Thread.current.report_on_exception = false
      started << :ready
      Parse::Console.wait_for(FakeKlass, on: :update, timeout: 0.05) rescue nil
    end
    started.pop
    Thread.pass until FakeKlass.last_subscription&.handlers&.any?

    sub = FakeKlass.last_subscription
    assert sub.handlers.key?(:update)
    refute sub.handlers.key?(:create),
           "explicit on: :update must override default [:create, :enter]"
  end

  # ------------------------------------------------------------------
  # watch
  # ------------------------------------------------------------------
  def test_watch_registers_all_default_event_handlers
    # Stub _block_until_interrupt so watch returns synchronously after
    # registering handlers (no SIGINT needed in the unit test).
    Parse::Console.singleton_class.send(:alias_method, :__orig_block, :_block_until_interrupt)
    Parse::Console.singleton_class.send(:define_method, :_block_until_interrupt) { nil }

    delivered = []
    count = Parse::Console.watch(FakeKlass) { |ev, obj| delivered << [ev, obj] }
    sub = FakeKlass.last_subscription

    Parse::Console::DEFAULT_WATCH_EVENTS.each do |ev|
      assert sub.handlers.key?(ev), "watch must register handler for #{ev}"
    end

    # Now drive a few events through and confirm the block is called.
    sub.emit(:create, :a)
    sub.emit(:update, :b)
    assert_equal [[:create, :a], [:update, :b]], delivered
    assert_equal 0, count, "watch returns the delivered count up to its return point"
    assert sub.unsubscribed, "watch must unsubscribe on exit"
  ensure
    Parse::Console.singleton_class.send(:alias_method, :_block_until_interrupt, :__orig_block)
    Parse::Console.singleton_class.send(:remove_method, :__orig_block)
  end

  def test_watch_swallows_handler_errors_without_tearing_subscription_down
    Parse::Console.singleton_class.send(:alias_method, :__orig_block, :_block_until_interrupt)
    Parse::Console.singleton_class.send(:define_method, :_block_until_interrupt) { nil }

    Parse::Console.watch(FakeKlass) { |_ev, _obj| raise "kaboom" }
    sub = FakeKlass.last_subscription

    # Should not raise outward — handler exception is logged via warn.
    capture_io { sub.emit(:create, :x) }
    assert sub.unsubscribed
  ensure
    Parse::Console.singleton_class.send(:alias_method, :_block_until_interrupt, :__orig_block)
    Parse::Console.singleton_class.send(:remove_method, :__orig_block)
  end

  # ------------------------------------------------------------------
  # subscription opening guard
  # ------------------------------------------------------------------
  def test_open_subscription_rejects_non_subscribable_class
    bad = Class.new # no .subscribe
    err = assert_raises(ArgumentError) do
      Parse::Console.wait_for(bad, timeout: 0.05)
    end
    assert_match(/does not implement \.subscribe/, err.message)
  end
end
