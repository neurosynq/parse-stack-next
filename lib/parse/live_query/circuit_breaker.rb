# encoding: UTF-8
# frozen_string_literal: true

require "monitor"

module Parse
  module LiveQuery
    # Circuit breaker pattern for connection failure handling.
    #
    # Prevents repeated connection attempts when the server is unavailable,
    # allowing time for recovery before retrying.
    #
    # States:
    # - :closed - Normal operation, requests allowed
    # - :open - Too many failures, requests blocked
    # - :half_open - Testing if service recovered
    #
    # @example
    #   breaker = CircuitBreaker.new(failure_threshold: 5, reset_timeout: 60.0)
    #
    #   if breaker.allow_request?
    #     begin
    #       connect_to_server
    #       breaker.record_success
    #     rescue => e
    #       breaker.record_failure
    #     end
    #   else
    #     # Circuit is open, wait before retrying
    #   end
    #
    class CircuitBreaker
      # Valid circuit states
      STATES = [:closed, :open, :half_open].freeze

      # Default number of failures before opening circuit
      DEFAULT_FAILURE_THRESHOLD = 5

      # Default seconds before transitioning from open to half_open
      DEFAULT_RESET_TIMEOUT = 60.0

      # Default number of successful requests in half_open before closing
      DEFAULT_HALF_OPEN_REQUESTS = 1

      # @return [Symbol] current state (:closed, :open, :half_open)
      attr_reader :state

      # @return [Integer] number of consecutive failures
      attr_reader :failure_count

      # @return [Integer] number of successful requests in half_open
      attr_reader :success_count

      # @return [Time, nil] when the last failure occurred
      attr_reader :last_failure_at

      # @return [Integer] failure threshold before opening
      attr_reader :failure_threshold

      # @return [Float] seconds before half_open transition
      attr_reader :reset_timeout

      # Create a new circuit breaker
      # @param failure_threshold [Integer] failures before opening circuit
      # @param reset_timeout [Float] seconds before testing recovery
      # @param half_open_requests [Integer] successes needed to close
      # @param on_state_change [Proc, nil] callback for state changes
      def initialize(failure_threshold: DEFAULT_FAILURE_THRESHOLD,
                     reset_timeout: DEFAULT_RESET_TIMEOUT,
                     half_open_requests: DEFAULT_HALF_OPEN_REQUESTS,
                     on_state_change: nil)
        @failure_threshold = failure_threshold
        @reset_timeout = reset_timeout
        @half_open_requests = half_open_requests
        @on_state_change = on_state_change

        @monitor = Monitor.new
        @state = :closed
        @failure_count = 0
        @success_count = 0
        @last_failure_at = nil
      end

      # Check if a request is allowed
      # @return [Boolean]
      # @note Thread-safe. Callbacks are invoked outside the synchronized block.
      def allow_request?
        state_change = nil

        result = @monitor.synchronize do
          case @state
          when :closed
            true
          when :open
            if Time.now - @last_failure_at >= @reset_timeout
              state_change = transition_to_internal(:half_open)
              true
            else
              false
            end
          when :half_open
            @success_count < @half_open_requests
          end
        end

        # Invoke callback outside synchronized block to prevent deadlocks
        notify_state_change(state_change) if state_change

        result
      end

      # Record a successful request
      # @return [void]
      # @note Thread-safe. Callbacks are invoked outside the synchronized block.
      def record_success
        state_change = nil

        @monitor.synchronize do
          case @state
          when :half_open
            @success_count += 1
            if @success_count >= @half_open_requests
              Logging.info("Circuit breaker closing after successful recovery")
              state_change = reset_internal!
            end
          when :closed
            @failure_count = 0
          end
        end

        # Invoke callback outside synchronized block to prevent deadlocks
        notify_state_change(state_change) if state_change
      end

      # Record a failed request
      # @return [void]
      # @note Thread-safe. Callbacks are invoked outside the synchronized block.
      def record_failure
        state_change = nil

        @monitor.synchronize do
          @failure_count += 1
          @last_failure_at = Time.now

          case @state
          when :closed
            if @failure_count >= @failure_threshold
              Logging.warn("Circuit breaker opening", failures: @failure_count)
              state_change = transition_to_internal(:open)
            end
          when :half_open
            Logging.warn("Circuit breaker re-opening from half_open")
            state_change = transition_to_internal(:open)
          end
        end

        # Invoke callback outside synchronized block to prevent deadlocks
        notify_state_change(state_change) if state_change
      end

      # Reset the circuit breaker to closed state
      # @return [void]
      # @note Thread-safe. Callbacks are invoked outside the synchronized block.
      def reset!
        state_change = @monitor.synchronize { reset_internal! }

        # Invoke callback outside synchronized block to prevent deadlocks
        notify_state_change(state_change) if state_change
      end

      # Check if circuit is open (blocking requests)
      # @return [Boolean]
      def open?
        @monitor.synchronize { @state == :open }
      end

      # Check if circuit is closed (allowing requests)
      # @return [Boolean]
      def closed?
        @monitor.synchronize { @state == :closed }
      end

      # Check if circuit is half_open (testing recovery)
      # @return [Boolean]
      def half_open?
        @monitor.synchronize { @state == :half_open }
      end

      # Seconds until circuit transitions to half_open
      # @return [Float, nil] nil if not open
      def time_until_half_open
        @monitor.synchronize do
          return nil unless @state == :open && @last_failure_at
          remaining = @reset_timeout - (Time.now - @last_failure_at)
          [remaining, 0].max
        end
      end

      # Get circuit breaker info as hash
      # @return [Hash]
      def info
        @monitor.synchronize do
          {
            state: @state,
            failure_count: @failure_count,
            success_count: @success_count,
            failure_threshold: @failure_threshold,
            reset_timeout: @reset_timeout,
            last_failure_at: @last_failure_at,
            time_until_half_open: time_until_half_open,
          }
        end
      end

      private

      # Transition to a new state (must be called with mutex held)
      # @param new_state [Symbol]
      # @return [Array<Symbol, Symbol>, nil] [old_state, new_state] if changed, nil otherwise
      def transition_to_internal(new_state)
        old_state = @state
        return nil if old_state == new_state

        @state = new_state
        @success_count = 0 if new_state == :half_open

        Logging.debug("Circuit breaker state change", from: old_state, to: new_state)
        [old_state, new_state]
      end

      # Reset internal state (must be called with mutex held)
      # @return [Array<Symbol, Symbol>, nil] [old_state, :closed] if changed, nil otherwise
      def reset_internal!
        old_state = @state
        @state = :closed
        @failure_count = 0
        @success_count = 0
        @last_failure_at = nil

        if old_state != :closed
          Logging.debug("Circuit breaker reset", from: old_state, to: :closed)
          [old_state, :closed]
        end
      end

      # Notify state change callback outside of synchronized block
      # @param state_change [Array<Symbol, Symbol>, nil] [old_state, new_state]
      def notify_state_change(state_change)
        return unless state_change && @on_state_change

        old_state, new_state = state_change
        @on_state_change.call(old_state, new_state)
      end
    end
  end
end
