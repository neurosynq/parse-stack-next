# encoding: UTF-8
# frozen_string_literal: true

require_relative "model/core/errors"

module Parse
  # LiveQuery provides real-time data subscriptions for reactive applications.
  # It uses WebSockets to receive push notifications when data changes on the server.
  # Stable since Parse Stack 3.0.0.
  #
  # @note LiveQuery requires an explicit opt-in before any subscription will
  #   open a network connection. This is a safety gate (operator must
  #   consciously enable the WebSocket egress surface), not a stability
  #   warning. Set the toggle once at boot:
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
    # Base error class for LiveQuery. Inherits from Parse::Error so that
    # `rescue Parse::Error` will also catch LiveQuery failures.
    class Error < Parse::Error; end
    class ConnectionError < Error; end

    # Raised when the LiveQuery server rejects a subscribe request.
    # Carries the originating `request_id` (the client-assigned
    # sequence number used for op/error correlation on the same socket)
    # and the `class_name` the subscription targeted. Both are present
    # on `Subscription#fail!`-constructed instances; standalone
    # `SubscriptionError.new("...")` callers can omit them and the
    # `message` is preserved verbatim.
    #
    # Mirrors the structure of `Parse::Error::ProtocolError` — the
    # error string contains the contextual prefix when the fields are
    # set so `rescue SubscriptionError => e; e.message` carries enough
    # for a single-line log line without inspecting `e` further.
    class SubscriptionError < Error
      # @return [Integer, nil] request id of the failed subscribe
      attr_reader :request_id
      # @return [String, nil] Parse class the subscription was targeting
      attr_reader :class_name

      def initialize(message_or_error, request_id: nil, class_name: nil)
        @request_id = request_id
        @class_name = class_name
        text = message_or_error.respond_to?(:message) ? message_or_error.message : message_or_error.to_s
        prefix_parts = []
        prefix_parts << "request_id=#{request_id}" if request_id
        prefix_parts << "class=#{class_name}" if class_name
        prefixed = prefix_parts.empty? ? text : "#{prefix_parts.join(' ')} #{text}"
        super(prefixed)
      end
    end

    class AuthenticationError < Error; end

    # Default LiveQuery events
    EVENTS = %i[create update delete enter leave].freeze

    # Error raised when LiveQuery is used but the opt-in toggle has not
    # been set. Opening a WebSocket is a network-egress action that the
    # operator must consciously enable; we refuse to do it implicitly.
    class NotEnabledError < Error
      def initialize
        super("LiveQuery must be explicitly enabled before opening a subscription. Set Parse.live_query_enabled = true")
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

      # Block until the process receives one of `signals` (default
      # `INT` and `TERM`), then gracefully shut down the supplied
      # LiveQuery client and return. Designed for long-running
      # rake-task-style consumers of LiveQuery (`rake livequery:tail`,
      # `rake installations:watch`, etc.) where the caller's natural
      # idiom is "subscribe, then wait forever; on Ctrl-C, clean up."
      #
      # **Why a helper:** Signal.trap blocks on MRI / macOS run in a
      # restricted context — calling `client.unsubscribe` /
      # `client.close` (which themselves take the client's internal
      # Monitor) directly from the trap raises `ThreadError: can't be
      # called from trap context` on the platforms that enforce
      # `:signal_safe?`. The safe idiom is "set a flag in the trap,
      # poll from the main thread, perform the shutdown there." This
      # method bundles that idiom so callers don't have to re-derive
      # it (and so they don't deploy the unsafe version and hit the
      # ThreadError in production).
      #
      # The supplied block (if any) runs once before the wait loop,
      # so callers can hand-off subscription setup that should not
      # race the trap installation:
      #
      # @example
      #   Parse::LiveQuery.run_until_signal! do |client|
      #     client.subscribe(Post, where: { published: true }) do |sub|
      #       sub.on(:create) { |obj| puts "new post: #{obj.id}" }
      #     end
      #   end
      #
      # @param client [Parse::LiveQuery::Client, nil] client to shut
      #   down on signal. Defaults to `Parse::LiveQuery.client` (the
      #   process-wide default).
      # @param signals [Array<Symbol, String>] signal names to trap.
      #   Defaults to `%i[INT TERM]` — common for SIGINT (Ctrl-C) and
      #   SIGTERM (orchestrator stop).
      # @param shutdown_timeout [Float] seconds to allow
      #   {Parse::LiveQuery::Client#shutdown} to drain pending events.
      # @param poll_interval [Float] seconds between sentinel checks.
      #   Lower values reduce shutdown latency; higher values reduce
      #   wakeup overhead on idle processes. Default 0.25s.
      # @yieldparam client [Parse::LiveQuery::Client] passed once
      #   before the wait loop starts. Optional.
      # @return [void] returns after the client has been shut down.
      def run_until_signal!(client: nil, signals: %i[INT TERM],
                            shutdown_timeout: 5.0, poll_interval: 0.25)
        ensure_enabled!
        unless signals.is_a?(Array) && !signals.empty?
          raise ArgumentError,
                "Parse::LiveQuery.run_until_signal!: signals must be a non-empty Array " \
                "(got #{signals.inspect}). An empty list would block the poll loop forever " \
                "with no trap installed."
        end
        target = client || self.client

        # Sentinel is a single-element queue rather than an instance
        # variable so the trap handler does only the absolute minimum
        # work (one `push`) — no mutex acquisition, no allocation
        # beyond what `<<` does internally.
        stop_signal = Queue.new
        installed = []
        begin
          # Yield BEFORE installing traps (so a SIGINT during caller
          # setup still aborts normally) but INSIDE the begin/ensure so a
          # raise from the block — including Interrupt — still runs the
          # shutdown/restore cleanup below rather than leaking the
          # client's connection and threads.
          yield(target) if block_given?

          signals.each do |sig|
            prior = Signal.trap(sig) { stop_signal << sig }
            installed << [sig, prior]
          end

          # Block until a signal arrives. Use `Queue#pop` with the
          # poll loop so trap-context limitations don't matter — we
          # only ever ENQUEUE from the trap; the dequeue is here on
          # the main thread.
          loop do
            sig = stop_signal.pop(true) rescue nil
            break if sig
            sleep poll_interval
          end
        ensure
          # Restore the prior trap handlers so re-running the helper
          # (e.g. in tests, or in a parent process that traps INT
          # itself) does not leak our handler.
          installed.each { |sig, prior| Signal.trap(sig, prior) if prior }
          # Shutdown from the main thread, not the trap context.
          target.shutdown(timeout: shutdown_timeout) if target.respond_to?(:shutdown)
        end
      end
    end
  end
end
