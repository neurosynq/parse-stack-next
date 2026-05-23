# encoding: UTF-8
# frozen_string_literal: true

module Parse
  # LiveQuery provides real-time data subscriptions for reactive applications.
  # It uses WebSockets to receive push notifications when data changes on the server.
  #
  # @note EXPERIMENTAL: This feature is not fully implemented. The WebSocket client
  #   is incomplete. You must explicitly enable this feature before use:
  #
  #   Parse.live_query_enabled = true
  #
  # @example Basic usage
  #   # Configure LiveQuery server URL
  #   Parse.setup(
  #     application_id: "your_app_id",
  #     api_key: "your_api_key",
  #     server_url: "https://your-parse-server.com/parse",
  #     live_query_url: "wss://your-parse-server.com"
  #   )
  #
  #   # Subscribe to changes on a model
  #   subscription = Song.subscribe(where: { artist: "Artist Name" })
  #
  #   subscription.on(:create) { |song| puts "New song: #{song.title}" }
  #   subscription.on(:update) { |song, original| puts "Updated: #{song.title}" }
  #   subscription.on(:delete) { |song| puts "Deleted: #{song.id}" }
  #   subscription.on(:enter) { |song, original| puts "Entered query: #{song.title}" }
  #   subscription.on(:leave) { |song, original| puts "Left query: #{song.title}" }
  #
  #   # Unsubscribe when done
  #   subscription.unsubscribe
  #
  # @example Using Query directly
  #   query = Song.query(:plays.gt => 1000)
  #   subscription = query.subscribe
  #
  #   subscription.on_create { |song| puts "New popular song!" }
  #   subscription.on_update { |song| puts "Song updated!" }
  #
  # @example Multiple subscriptions
  #   client = Parse::LiveQuery.client
  #
  #   sub1 = client.subscribe(Song, where: { genre: "rock" })
  #   sub2 = client.subscribe(Album, where: { year: 2024 })
  #
  #   # Close all subscriptions
  #   client.close
  #
  module LiveQuery
    # Base error class for LiveQuery
    class Error < StandardError; end
    class ConnectionError < Error; end
    class SubscriptionError < Error; end
    class AuthenticationError < Error; end

    # Default LiveQuery events
    EVENTS = %i[create update delete enter leave].freeze

    # Error raised when LiveQuery is used but not enabled
    class NotEnabledError < Error
      def initialize
        super("LiveQuery is experimental and must be explicitly enabled. Set Parse.live_query_enabled = true")
      end
    end
  end
end

# Require components after module and error classes are defined
require_relative "live_query/configuration"
require_relative "live_query/logging"
require_relative "live_query/event"
require_relative "live_query/health_monitor"
require_relative "live_query/circuit_breaker"
require_relative "live_query/event_queue"
require_relative "live_query/subscription"
require_relative "live_query/client"

module Parse
  module LiveQuery
    class << self
      # @return [Parse::LiveQuery::Client] the default LiveQuery client
      attr_accessor :default_client

      # Check if LiveQuery feature is enabled
      # @return [Boolean]
      def enabled?
        Parse.live_query_enabled?
      end

      # Ensure LiveQuery is enabled, raising an error if not
      # @raise [NotEnabledError] if LiveQuery is not enabled
      def ensure_enabled!
        raise NotEnabledError unless enabled?
      end

      # Get or create the default LiveQuery client.
      # Uses the configuration from Parse.setup if available.
      # @return [Parse::LiveQuery::Client]
      # @raise [NotEnabledError] if LiveQuery is not enabled
      def client
        ensure_enabled!
        @default_client ||= Client.new
      end

      # Reset the default client (closes connection and clears instance)
      def reset!
        @default_client&.close
        @default_client = nil
      end

      # Check if LiveQuery is configured and available
      # @return [Boolean]
      def available?
        !!config.url
      end

      # Get the LiveQuery configuration object
      # @return [Parse::LiveQuery::Configuration]
      def config
        @config ||= Configuration.new
      end

      # Configure LiveQuery settings using a block
      # @yield [config] Configuration object
      # @return [Configuration]
      #
      # @example
      #   Parse::LiveQuery.configure do |config|
      #     config.url = "wss://your-server.com"
      #     config.ping_interval = 20.0
      #     config.logging_enabled = true
      #   end
      def configure
        yield config if block_given?

        # Sync logging settings
        if config.logging_enabled
          Logging.enabled = true
          Logging.log_level = config.log_level
          Logging.logger = config.logger if config.logger
        end

        config
      end

      # Legacy configuration method for backward compatibility
      # @deprecated Use configure block instead
      # @return [Hash]
      def configuration
        {
          url: config.url,
          application_id: config.application_id,
          client_key: config.client_key,
          master_key: config.master_key,
        }
      end
    end
  end
end
