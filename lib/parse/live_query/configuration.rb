# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module LiveQuery
    # Centralized configuration for LiveQuery client.
    #
    # @example Configure LiveQuery
    #   Parse::LiveQuery.configure do |config|
    #     config.url = "wss://your-server.com"
    #     config.ping_interval = 20.0
    #     config.logging_enabled = true
    #   end
    #
    class Configuration
      # Connection settings
      # @return [String] WebSocket URL for LiveQuery server
      attr_accessor :url

      # @return [String] Parse application ID
      attr_accessor :application_id

      # @return [String] Parse client key
      attr_accessor :client_key

      # @return [String] Parse master key (optional)
      attr_accessor :master_key

      # @return [Boolean] build admin connections that send the master
      #   key on the connect frame, bypassing ACL/CLP for ALL
      #   subscriptions. Defaults to false — connections are ACL-scoped.
      #   Set true ONLY for dedicated admin/event-tap consumers; never
      #   for clients that serve end-user, session-scoped streams. See
      #   {Parse::LiveQuery::Client#use_master_key}.
      attr_accessor :use_master_key

      # @return [Boolean] automatically connect on client creation (default: true)
      attr_accessor :auto_connect

      # @return [Boolean] automatically reconnect on disconnect (default: true)
      attr_accessor :auto_reconnect

      # Health monitoring settings
      # @return [Float] seconds between ping frames (default: 30.0)
      attr_accessor :ping_interval

      # @return [Float] seconds to wait for pong response (default: 10.0)
      attr_accessor :pong_timeout

      # Circuit breaker settings
      # @return [Integer] failures before circuit opens (default: 5)
      attr_accessor :circuit_failure_threshold

      # @return [Float] seconds before circuit transitions to half-open (default: 60.0)
      attr_accessor :circuit_reset_timeout

      # Reconnection backoff settings
      # @return [Float] initial reconnect delay in seconds (default: 1.0)
      attr_accessor :initial_reconnect_interval

      # @return [Float] maximum reconnect delay in seconds (default: 30.0)
      attr_accessor :max_reconnect_interval

      # @return [Float] reconnect delay multiplier (default: 1.5)
      attr_accessor :reconnect_multiplier

      # @return [Float] jitter factor for reconnect delay, 0.0-1.0 (default: 0.2)
      attr_accessor :reconnect_jitter

      # Event queue settings
      # @return [Integer] maximum queued events before backpressure (default: 1000)
      attr_accessor :event_queue_size

      # @return [Symbol] backpressure strategy :block, :drop_oldest, :drop_newest (default: :drop_oldest)
      attr_accessor :backpressure_strategy

      # Security settings
      # @return [Integer] maximum WebSocket message size in bytes (default: 1MB)
      #   Prevents memory exhaustion from malicious oversized frames
      attr_accessor :max_message_size

      # @return [Integer] frame read timeout in seconds (default: 30)
      #   Prevents indefinite blocking when reading from socket
      attr_accessor :frame_read_timeout

      # @return [Boolean] when false (default), refuse to derive a `ws://`
      #   URL from an `http://` server URL on any non-loopback host. The
      #   default `Parse::LiveQuery::Client#derive_websocket_url` path
      #   silently picks `ws://` when the Parse server URL is `http://`,
      #   carrying master keys and session tokens over a cleartext
      #   socket. Set to `true` to explicitly opt into insecure
      #   WebSocket transport (local development, container-internal
      #   networks). Loopback hosts (`localhost`, `127.0.0.1`, `::1`)
      #   are exempt and emit a warning instead.
      attr_accessor :allow_insecure

      # @return [Symbol, nil] minimum TLS version :TLSv1, :TLSv1_1, :TLSv1_2, :TLSv1_3 (default: :TLSv1_2)
      #   Enforces minimum TLS version for WebSocket connections
      attr_accessor :ssl_min_version

      # @return [Symbol, nil] maximum TLS version :TLSv1, :TLSv1_1, :TLSv1_2, :TLSv1_3 (default: nil = highest available)
      #   Caps the maximum TLS version (rarely needed, use for compatibility)
      attr_accessor :ssl_max_version

      # Map of TLS version symbols to OpenSSL constants
      TLS_VERSION_MAP = {
        TLSv1: OpenSSL::SSL::TLS1_VERSION,
        TLSv1_1: OpenSSL::SSL::TLS1_1_VERSION,
        TLSv1_2: OpenSSL::SSL::TLS1_2_VERSION,
        TLSv1_3: OpenSSL::SSL::TLS1_3_VERSION,
      }.freeze

      # Valid TLS version symbols
      VALID_TLS_VERSIONS = [nil, :TLSv1, :TLSv1_1, :TLSv1_2, :TLSv1_3].freeze

      # Convert a TLS version symbol to OpenSSL constant
      # @param version [Symbol, nil] TLS version symbol
      # @return [Integer, nil] OpenSSL TLS version constant or nil
      def self.tls_version_constant(version)
        return nil if version.nil?
        TLS_VERSION_MAP[version]
      end

      # Logging settings
      # @return [Boolean] enable structured logging (default: false)
      attr_accessor :logging_enabled

      # @return [Symbol] log level :debug, :info, :warn, :error (default: :info)
      attr_accessor :log_level

      # @return [Logger, nil] custom logger instance (default: nil, uses STDOUT)
      attr_accessor :logger

      # Initialize with sensible defaults
      def initialize
        # Connection
        @url = nil
        @application_id = nil
        @client_key = nil
        @master_key = nil
        # ACL-scoped by default; opt into admin (ACL-bypassing)
        # connections explicitly. See attr doc above.
        @use_master_key = false
        @auto_connect = true
        @auto_reconnect = true

        # Health monitoring
        @ping_interval = 30.0
        @pong_timeout = 10.0

        # Circuit breaker
        @circuit_failure_threshold = 5
        @circuit_reset_timeout = 60.0

        # Reconnection backoff
        @initial_reconnect_interval = 1.0
        @max_reconnect_interval = 30.0
        @reconnect_multiplier = 1.5
        @reconnect_jitter = 0.2

        # Event queue
        @event_queue_size = 1000
        @backpressure_strategy = :drop_oldest

        # Security
        @max_message_size = 1_048_576  # 1MB
        @frame_read_timeout = 30       # 30 seconds
        @ssl_min_version = :TLSv1_2    # Enforce modern TLS by default
        @ssl_max_version = nil         # No maximum (use highest available)
        @allow_insecure = false        # Refuse ws:// downgrade on non-loopback hosts

        # Logging
        @logging_enabled = false
        @log_level = :info
        @logger = nil
      end

      # Validate configuration
      # @return [Array<String>] list of validation errors
      def validate
        errors = []
        errors << "ping_interval must be positive" if @ping_interval && @ping_interval <= 0
        errors << "pong_timeout must be positive" if @pong_timeout && @pong_timeout <= 0
        errors << "circuit_failure_threshold must be positive" if @circuit_failure_threshold && @circuit_failure_threshold <= 0
        errors << "event_queue_size must be positive" if @event_queue_size && @event_queue_size <= 0
        errors << "reconnect_jitter must be between 0.0 and 1.0" if @reconnect_jitter && (@reconnect_jitter < 0.0 || @reconnect_jitter > 1.0)
        errors << "backpressure_strategy must be :block, :drop_oldest, or :drop_newest" unless [:block, :drop_oldest, :drop_newest].include?(@backpressure_strategy)
        errors << "max_message_size must be positive" if @max_message_size && @max_message_size <= 0
        errors << "frame_read_timeout must be positive" if @frame_read_timeout && @frame_read_timeout <= 0
        errors << "log_level must be :debug, :info, :warn, or :error" unless [:debug, :info, :warn, :error].include?(@log_level)

        # SSL/TLS version validation
        errors << "ssl_min_version must be nil, :TLSv1, :TLSv1_1, :TLSv1_2, or :TLSv1_3" unless VALID_TLS_VERSIONS.include?(@ssl_min_version)
        errors << "ssl_max_version must be nil, :TLSv1, :TLSv1_1, :TLSv1_2, or :TLSv1_3" unless VALID_TLS_VERSIONS.include?(@ssl_max_version)

        errors
      end

      # Check if configuration is valid
      # @return [Boolean]
      def valid?
        validate.empty?
      end

      # Convert to hash
      # @return [Hash]
      def to_h
        {
          url: @url,
          application_id: @application_id,
          client_key: @client_key.nil? ? nil : "[REDACTED]",
          master_key: @master_key.nil? ? nil : "[REDACTED]",
          use_master_key: @use_master_key,
          auto_connect: @auto_connect,
          auto_reconnect: @auto_reconnect,
          ping_interval: @ping_interval,
          pong_timeout: @pong_timeout,
          circuit_failure_threshold: @circuit_failure_threshold,
          circuit_reset_timeout: @circuit_reset_timeout,
          initial_reconnect_interval: @initial_reconnect_interval,
          max_reconnect_interval: @max_reconnect_interval,
          reconnect_multiplier: @reconnect_multiplier,
          reconnect_jitter: @reconnect_jitter,
          event_queue_size: @event_queue_size,
          backpressure_strategy: @backpressure_strategy,
          max_message_size: @max_message_size,
          frame_read_timeout: @frame_read_timeout,
          ssl_min_version: @ssl_min_version,
          ssl_max_version: @ssl_max_version,
          logging_enabled: @logging_enabled,
          log_level: @log_level,
        }
      end
    end
  end
end
