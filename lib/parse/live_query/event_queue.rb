# encoding: UTF-8
# frozen_string_literal: true

require "monitor"

module Parse
  module LiveQuery
    # Error raised when event queue is full and strategy is :error
    class EventQueueFullError < Error
      def initialize(max_size)
        super("Event queue full (max: #{max_size})")
      end
    end

    # Bounded event queue with configurable backpressure strategies.
    #
    # Provides a buffer between the WebSocket reader thread and callback
    # execution, preventing high-frequency events from overwhelming the system.
    #
    # Backpressure Strategies:
    # - :block - Block enqueue until space available (can cause reader thread to block)
    # - :drop_oldest - Drop oldest events when full (default)
    # - :drop_newest - Drop incoming events when full
    #
    # @example
    #   queue = EventQueue.new(max_size: 1000, strategy: :drop_oldest)
    #   queue.start { |event| process_event(event) }
    #   queue.enqueue(event)
    #   queue.stop(drain: true)
    #
    class EventQueue
      # Valid backpressure strategies
      STRATEGIES = [:block, :drop_oldest, :drop_newest].freeze

      # Default maximum queue size
      DEFAULT_MAX_SIZE = 1000

      # Default backpressure strategy
      DEFAULT_STRATEGY = :drop_oldest

      # @return [Integer] maximum queue size
      attr_reader :max_size

      # @return [Symbol] backpressure strategy
      attr_reader :strategy

      # @return [Integer] number of dropped events
      attr_reader :dropped_count

      # @return [Integer] total events enqueued
      attr_reader :enqueued_count

      # @return [Integer] total events processed
      attr_reader :processed_count

      # Create a new event queue
      # @param max_size [Integer] maximum queue size
      # @param strategy [Symbol] backpressure strategy (:block, :drop_oldest, :drop_newest)
      # @param on_drop [Proc, nil] callback when events are dropped (receives event, reason)
      def initialize(max_size: DEFAULT_MAX_SIZE, strategy: DEFAULT_STRATEGY, on_drop: nil)
        unless STRATEGIES.include?(strategy)
          raise ArgumentError, "Invalid strategy: #{strategy}. Must be one of #{STRATEGIES.inspect}"
        end

        @max_size = max_size
        @strategy = strategy
        @on_drop = on_drop

        @queue = []
        @monitor = Monitor.new
        @condition = @monitor.new_cond
        @running = false
        @processor_thread = nil

        @dropped_count = 0
        @enqueued_count = 0
        @processed_count = 0
      end

      # Start the event processor thread
      # @yield [event] Block to process each event
      # @return [void]
      def start(&processor)
        raise ArgumentError, "Processor block required" unless block_given?

        @monitor.synchronize do
          return if @running

          @running = true
          @processor_thread = Thread.new { process_loop(&processor) }
          @processor_thread.abort_on_exception = false

          Logging.debug("Event queue started", max_size: @max_size, strategy: @strategy)
        end
      end

      # Stop the event processor
      # @param drain [Boolean] process remaining events before stopping
      # @param timeout [Float] seconds to wait for drain
      # @return [void]
      def stop(drain: true, timeout: 5.0)
        @monitor.synchronize do
          return unless @running

          @running = false
          @condition.broadcast
        end

        if drain && @processor_thread
          @processor_thread.join(timeout)
        end

        @processor_thread&.kill
        @processor_thread = nil

        remaining = @monitor.synchronize { @queue.size }
        Logging.debug("Event queue stopped", remaining: remaining, dropped: @dropped_count)
      end

      # Add an event to the queue
      # @param event [Object] the event to enqueue
      # @return [Boolean] true if enqueued, false if dropped
      def enqueue(event)
        @monitor.synchronize do
          return false unless @running

          if @queue.size >= @max_size
            handle_backpressure(event)
          else
            @queue << event
            @enqueued_count += 1
            @condition.signal
            true
          end
        end
      end

      # Current queue size
      # @return [Integer]
      def size
        @monitor.synchronize { @queue.size }
      end

      # Check if queue is full
      # @return [Boolean]
      def full?
        @monitor.synchronize { @queue.size >= @max_size }
      end

      # Check if queue is empty
      # @return [Boolean]
      def empty?
        @monitor.synchronize { @queue.empty? }
      end

      # Check if queue is running
      # @return [Boolean]
      def running?
        @monitor.synchronize { @running }
      end

      # Get queue statistics
      # @return [Hash]
      def stats
        @monitor.synchronize do
          {
            size: @queue.size,
            max_size: @max_size,
            strategy: @strategy,
            running: @running,
            enqueued_count: @enqueued_count,
            processed_count: @processed_count,
            dropped_count: @dropped_count,
            utilization: @max_size > 0 ? (@queue.size.to_f / @max_size * 100).round(1) : 0,
          }
        end
      end

      # Clear the queue
      # @return [Integer] number of events cleared
      def clear
        @monitor.synchronize do
          count = @queue.size
          @queue.clear
          count
        end
      end

      private

      # Main processing loop - runs in background thread
      def process_loop
        while @running
          event = nil

          @monitor.synchronize do
            # Wait for events or stop signal
            while @queue.empty? && @running
              @condition.wait(1.0)
            end

            event = @queue.shift if @running || !@queue.empty?
          end

          if event
            begin
              yield event
              @monitor.synchronize { @processed_count += 1 }
            rescue StandardError => e
              Logging.error("Event processing error", error: e)
            end
          end
        end

        # Drain remaining events if requested
        drain_remaining { |e| yield e }
      end

      # Drain remaining events after stop
      def drain_remaining
        loop do
          event = @monitor.synchronize { @queue.shift }
          break unless event

          begin
            yield event
            @monitor.synchronize { @processed_count += 1 }
          rescue StandardError => e
            Logging.error("Event drain error", error: e)
          end
        end
      end

      # Handle backpressure when queue is full
      # @param event [Object] the event being enqueued
      # @return [Boolean] true if enqueued, false if dropped
      def handle_backpressure(event)
        case @strategy
        when :block
          # Wait until space available
          @condition.wait until @queue.size < @max_size || !@running
          if @running
            @queue << event
            @enqueued_count += 1
            true
          else
            false
          end
        when :drop_oldest
          dropped = @queue.shift
          @dropped_count += 1
          notify_drop(dropped, :oldest)
          @queue << event
          @enqueued_count += 1
          true
        when :drop_newest
          @dropped_count += 1
          notify_drop(event, :newest)
          false
        end
      end

      # Notify callback of dropped event
      def notify_drop(event, reason)
        Logging.warn("Event dropped", reason: reason, queue_size: @queue.size)
        @on_drop&.call(event, reason)
      rescue StandardError => e
        Logging.error("Drop callback error", error: e)
      end
    end
  end
end
