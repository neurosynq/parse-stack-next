# encoding: UTF-8
# frozen_string_literal: true

require "monitor"

module Parse
  module LiveQuery
    # Monitors WebSocket connection health via ping/pong and activity tracking.
    #
    # Schedules periodic ping frames and detects stale connections when pong
    # responses are not received within the configured timeout.
    #
    # @example
    #   monitor = HealthMonitor.new(client: client, ping_interval: 30.0, pong_timeout: 10.0)
    #   monitor.start
    #   # ... connection activity ...
    #   monitor.stop
    #
    class HealthMonitor
      # Default ping interval in seconds
      DEFAULT_PING_INTERVAL = 30.0

      # Default pong timeout in seconds
      DEFAULT_PONG_TIMEOUT = 10.0

      # @return [Float] seconds between ping frames
      attr_reader :ping_interval

      # @return [Float] seconds to wait for pong response
      attr_reader :pong_timeout

      # @return [Time, nil] when connection was established
      attr_reader :connection_established_at

      # @return [Time, nil] last activity (any message received)
      attr_reader :last_activity_at

      # @return [Time, nil] last pong received
      attr_reader :last_pong_at

      # Create a new health monitor
      # @param client [Client] the LiveQuery client to monitor
      # @param ping_interval [Float] seconds between pings
      # @param pong_timeout [Float] seconds to wait for pong
      def initialize(client:, ping_interval: DEFAULT_PING_INTERVAL, pong_timeout: DEFAULT_PONG_TIMEOUT)
        @client = client
        @ping_interval = ping_interval
        @pong_timeout = pong_timeout

        @monitor = Monitor.new
        @running = false
        @ping_thread = nil
        @awaiting_pong = false

        @connection_established_at = nil
        @last_activity_at = nil
        @last_pong_at = nil
      end

      # Start the health monitoring thread
      # @return [void]
      def start
        @monitor.synchronize do
          return if @running

          @running = true
          @connection_established_at = Time.now
          @last_activity_at = Time.now
          @last_pong_at = Time.now
          @awaiting_pong = false

          @ping_thread = Thread.new { ping_loop }
          @ping_thread.abort_on_exception = false

          Logging.debug("Health monitor started", ping_interval: @ping_interval, pong_timeout: @pong_timeout)
        end
      end

      # Stop the health monitoring thread
      # @return [void]
      def stop
        @monitor.synchronize do
          return unless @running

          @running = false
          @ping_thread&.kill
          @ping_thread = nil
          @awaiting_pong = false

          Logging.debug("Health monitor stopped")
        end
      end

      # Record that a pong was received
      # @return [void]
      def record_pong
        @monitor.synchronize do
          @last_pong_at = Time.now
          @last_activity_at = Time.now
          @awaiting_pong = false
        end
        Logging.debug("Pong received")
      end

      # Record that activity was received (any message)
      # @return [void]
      def record_activity
        @monitor.synchronize do
          @last_activity_at = Time.now
        end
      end

      # Check if monitor is running
      # @return [Boolean]
      def running?
        @monitor.synchronize { @running }
      end

      # Check if connection is stale (no pong within timeout)
      # @return [Boolean]
      def stale?
        @monitor.synchronize do
          return false unless @awaiting_pong
          return false unless @last_pong_at

          Time.now - @last_pong_at > (@ping_interval + @pong_timeout)
        end
      end

      # Check if connection appears healthy
      # @return [Boolean]
      def healthy?
        @monitor.synchronize do
          return false unless @running
          return true unless @last_activity_at

          # Consider unhealthy if no activity for 2x ping interval + pong timeout
          max_idle = (@ping_interval * 2) + @pong_timeout
          Time.now - @last_activity_at < max_idle
        end
      end

      # Seconds since last activity
      # @return [Float, nil]
      def seconds_since_activity
        @monitor.synchronize do
          return nil unless @last_activity_at
          Time.now - @last_activity_at
        end
      end

      # Seconds since last pong
      # @return [Float, nil]
      def seconds_since_pong
        @monitor.synchronize do
          return nil unless @last_pong_at
          Time.now - @last_pong_at
        end
      end

      # Get health information as a hash
      # @return [Hash]
      def health_info
        @monitor.synchronize do
          {
            running: @running,
            healthy: healthy?,
            stale: stale?,
            awaiting_pong: @awaiting_pong,
            connection_established_at: @connection_established_at,
            last_activity_at: @last_activity_at,
            last_pong_at: @last_pong_at,
            seconds_since_activity: seconds_since_activity,
            seconds_since_pong: seconds_since_pong,
            ping_interval: @ping_interval,
            pong_timeout: @pong_timeout,
          }
        end
      end

      private

      # Main ping loop - runs in background thread
      def ping_loop
        while @running
          begin
            sleep @ping_interval
            break unless @running

            # Send ping and mark as awaiting pong
            @monitor.synchronize { @awaiting_pong = true }

            Logging.debug("Sending ping")
            @client.send(:send_ping)

            # Wait for pong timeout
            sleep @pong_timeout
            break unless @running

            # Check if pong was received
            if @awaiting_pong
              Logging.warn("Connection stale: no pong received", seconds_waited: @ping_interval + @pong_timeout)
              @client.send(:handle_stale_connection)
              break
            end
          rescue StandardError => e
            Logging.error("Ping loop error", error: e)
            break
          end
        end
      end
    end
  end
end
