# encoding: UTF-8
# frozen_string_literal: true

require "set"

module Parse
  # Exception raised when N+1 query is detected in strict mode
  class NPlusOneQueryError < StandardError
    attr_reader :source_class, :association, :target_class, :count, :location

    def initialize(source_class, association, target_class, count, location = nil)
      @source_class = source_class
      @association = association
      @target_class = target_class
      @count = count
      @location = location

      message = "N+1 query detected on #{source_class}.#{association} " \
                "(#{count} separate fetches for #{target_class})"
      message += " at #{location}" if location
      message += ". Use `.includes(:#{association})` to eager-load this association."
      super(message)
    end
  end

  # Detects N+1 query patterns when accessing associations.
  #
  # N+1 queries occur when you load a collection of objects and then
  # access an association on each object individually, triggering a
  # separate query for each. This is inefficient and can be avoided
  # by using includes() to eager-load the associations.
  #
  # @example Detecting N+1 queries (warn mode - default)
  #   Parse.n_plus_one_mode = :warn
  #
  #   songs = Song.all(limit: 100)
  #   songs.each do |song|
  #     song.artist.name  # Warning: N+1 query detected on Song.artist
  #   end
  #
  # @example Strict mode for CI/tests
  #   Parse.n_plus_one_mode = :raise
  #
  #   songs = Song.all(limit: 100)
  #   songs.each do |song|
  #     song.artist.name  # Raises Parse::NPlusOneQueryError
  #   end
  #
  # @example Avoiding N+1 with includes
  #   songs = Song.all(limit: 100, includes: [:artist])
  #   songs.each do |song|
  #     song.artist.name  # No warning - artist was eager-loaded
  #   end
  #
  class NPlusOneDetector
    # Default time window in seconds to track related fetches
    DEFAULT_DETECTION_WINDOW = 2.0

    # Default minimum number of fetches to trigger a warning
    DEFAULT_FETCH_THRESHOLD = 3

    # Default cleanup interval in seconds
    DEFAULT_CLEANUP_INTERVAL = 60.0

    # Thread-local storage key for tracking
    TRACKING_KEY = :parse_n_plus_one_tracking

    # Thread-local key for last cleanup time
    CLEANUP_KEY = :parse_n_plus_one_last_cleanup

    # Thread-local key for source registry (maps object_id to source info)
    SOURCE_REGISTRY_KEY = :parse_n_plus_one_source_registry

    # Valid modes for N+1 detection
    VALID_MODES = [:warn, :raise, :ignore].freeze

    # Thread-local key for mode
    MODE_KEY = :parse_n_plus_one_mode

    class << self
      # Configurable thresholds
      # @return [Float] time window in seconds to track related fetches
      attr_writer :detection_window

      # @return [Integer] minimum number of fetches to trigger a warning
      attr_writer :fetch_threshold

      # @return [Float] how often to run cleanup in seconds
      attr_writer :cleanup_interval

      def detection_window
        @detection_window || DEFAULT_DETECTION_WINDOW
      end

      def fetch_threshold
        @fetch_threshold || DEFAULT_FETCH_THRESHOLD
      end

      def cleanup_interval
        @cleanup_interval || DEFAULT_CLEANUP_INTERVAL
      end

      # Register a source (class and association) for a pointer object.
      # This uses the object's Ruby object_id as a key in a thread-local registry,
      # avoiding the need to set instance variables on foreign objects.
      #
      # @param pointer [Parse::Pointer] the pointer object
      # @param source_class [String] the class where the pointer was accessed
      # @param association [Symbol] the association name
      def register_source(pointer, source_class:, association:)
        return unless pointer && enabled?
        registry = get_source_registry
        registry[pointer.object_id] = {
          source_class: source_class,
          association: association,
          registered_at: Time.now.to_f,
        }
      end

      # Look up the source info for a pointer object.
      #
      # @param pointer [Parse::Pointer] the pointer object
      # @return [Hash, nil] the source info or nil if not found
      def lookup_source(pointer)
        return nil unless pointer
        registry = get_source_registry
        registry[pointer.object_id]
      end

      # Clear the source registry (called during reset)
      def clear_source_registry!
        Thread.current[SOURCE_REGISTRY_KEY] = nil
      end

      # Get the current N+1 detection mode
      # @return [Symbol] :warn, :raise, or :ignore
      def mode
        Thread.current[MODE_KEY] || :ignore
      end

      # Set the N+1 detection mode
      # @param value [Symbol] :warn, :raise, or :ignore
      # @raise [ArgumentError] if an invalid mode is provided
      def mode=(value)
        value = value.to_sym if value.respond_to?(:to_sym)
        unless VALID_MODES.include?(value)
          raise ArgumentError, "Invalid N+1 mode: #{value.inspect}. Valid modes: #{VALID_MODES.join(", ")}"
        end
        Thread.current[MODE_KEY] = value
        reset! if value == :ignore
      end

      # Whether N+1 detection is enabled (not in ignore mode)
      # @return [Boolean]
      def enabled?
        mode != :ignore
      end

      # Enable or disable N+1 detection for the current thread
      # @param value [Boolean] true enables :warn mode, false sets :ignore mode
      def enabled=(value)
        self.mode = value ? :warn : :ignore
      end

      # Reset all tracking data
      def reset!
        Thread.current[TRACKING_KEY] = nil
        clear_source_registry!
      end

      # Track an autofetch event for N+1 detection.
      #
      # @param source_class [String] the class name where the fetch originated
      # @param association [Symbol] the association being accessed
      # @param target_class [String] the class being fetched
      # @param object_id [String] the ID of the object being fetched
      def track_autofetch(source_class:, association:, target_class:, object_id:)
        return unless enabled?

        tracking = get_tracking
        key = "#{source_class}.#{association}"
        now = Time.now.to_f

        # Periodically clean up stale tracking entries to prevent memory leaks
        # in long-running threads (e.g., Puma, Sidekiq thread pools)
        cleanup_stale_entries(tracking, now)

        # Initialize or update tracking for this association
        tracking[key] ||= { fetches: [], warned: false, target_class: target_class }
        data = tracking[key]

        # Remove stale entries outside the detection window
        data[:fetches] = data[:fetches].select { |t| now - t < detection_window }

        # Add this fetch
        data[:fetches] << now

        # Check if we've exceeded the threshold and haven't warned yet
        if data[:fetches].size >= fetch_threshold && !data[:warned]
          data[:warned] = true
          emit_warning(source_class, association, target_class, data[:fetches].size)
        end
      end

      # Emit an N+1 warning or raise an error based on the current mode.
      #
      # @param source_class [String] the class where the N+1 originated
      # @param association [Symbol] the association causing the N+1
      # @param target_class [String] the class being fetched repeatedly
      # @param count [Integer] the number of fetches detected
      def emit_warning(source_class, association, target_class, count)
        location = find_user_code_location

        # Call registered callbacks regardless of mode
        callbacks.each { |cb| cb.call(source_class, association, target_class, count, location) }

        case mode
        when :raise
          raise NPlusOneQueryError.new(source_class, association, target_class, count, location)
        when :warn
          message = "[Parse::N+1] Warning: N+1 query detected on #{source_class}.#{association} " \
                    "(#{count} separate fetches for #{target_class})"

          if location
            message += "\n  Location: #{location}"
          end

          message += "\n  Suggestion: Use `.includes(:#{association})` to eager-load this association"

          # Output warning
          if logger
            logger.warn(message)
          else
            warn(message)
          end
          # :ignore mode does nothing (but callbacks still run)
        end
      end

      # Register a callback to be called when N+1 is detected.
      # Useful for custom logging or metrics.
      #
      # @yield [source_class, association, target_class, count, location]
      def on_n_plus_one(&block)
        callbacks << block if block_given?
      end

      # Clear all registered callbacks
      def clear_callbacks!
        @callbacks = []
      end

      # Get registered callbacks
      # @return [Array<Proc>]
      def callbacks
        @callbacks ||= []
      end

      # Set a custom logger
      # @param value [Logger, nil]
      attr_writer :logger

      # Get the configured logger
      # @return [Logger, nil]
      def logger
        @logger
      end

      # Get summary statistics of detected N+1 patterns
      # @return [Hash] summary of N+1 detections
      def summary
        tracking = get_tracking
        {
          patterns_detected: tracking.count { |_, v| v[:warned] },
          associations: tracking.map { |k, v| { pattern: k, fetches: v[:fetches].size, warned: v[:warned] } },
        }
      end

      private

      def get_tracking
        Thread.current[TRACKING_KEY] ||= {}
      end

      # Clean up stale tracking entries to prevent memory leaks in thread pools.
      # Removes entries that have no recent fetches and have already warned.
      # Runs at most once per cleanup_interval to minimize overhead.
      def cleanup_stale_entries(tracking, now)
        last_cleanup = Thread.current[CLEANUP_KEY] || 0
        return if now - last_cleanup < cleanup_interval

        Thread.current[CLEANUP_KEY] = now

        # Remove entries that are stale (no recent fetches) and have already warned
        tracking.delete_if do |_key, data|
          # Clean up old timestamps first
          data[:fetches] = data[:fetches].select { |t| now - t < detection_window }
          # Remove if empty and already warned (pattern is stale)
          data[:fetches].empty? && data[:warned]
        end

        # Also clean up stale source registry entries
        cleanup_source_registry(now)
      end

      def get_source_registry
        Thread.current[SOURCE_REGISTRY_KEY] ||= {}
      end

      # Clean up old source registry entries to prevent memory leaks.
      # Removes entries older than the detection window.
      def cleanup_source_registry(now)
        registry = get_source_registry
        registry.delete_if do |_object_id, data|
          now - data[:registered_at] > detection_window
        end
      end

      # Find the location in user code where the N+1 originated.
      # Filters out parse-stack internal frames to show relevant user code.
      def find_user_code_location
        caller_locations.each do |loc|
          path = loc.path.to_s
          # Skip internal parse-stack code
          next if path.include?("/lib/parse/")
          next if path.include?("/gems/")
          next if path.include?("ruby/") || path.include?("<internal")

          return "#{loc.path}:#{loc.lineno} in `#{loc.label}`"
        end
        nil
      end
    end
  end

  # Module-level configuration for N+1 detection
  class << self
    # Set the N+1 detection mode.
    #
    # @example Different modes
    #   Parse.n_plus_one_mode = :warn   # Log warnings (default when enabled)
    #   Parse.n_plus_one_mode = :raise  # Raise NPlusOneQueryError (for CI/tests)
    #   Parse.n_plus_one_mode = :ignore # Disable detection
    #
    # @param value [Symbol] :warn, :raise, or :ignore
    def n_plus_one_mode=(value)
      NPlusOneDetector.mode = value
    end

    # Get the current N+1 detection mode.
    # @return [Symbol] :warn, :raise, or :ignore
    def n_plus_one_mode
      NPlusOneDetector.mode
    end

    # Enable or disable N+1 query detection.
    # When enabled, warnings are emitted when N+1 patterns are detected.
    # For more control, use {#n_plus_one_mode=} instead.
    #
    # @example Enable N+1 detection
    #   Parse.warn_on_n_plus_one = true
    #
    # @param value [Boolean] true enables :warn mode, false sets :ignore mode
    def warn_on_n_plus_one=(value)
      NPlusOneDetector.enabled = value
    end

    # Check if N+1 detection is enabled.
    # @return [Boolean]
    def warn_on_n_plus_one
      NPlusOneDetector.enabled?
    end

    # Alias for compatibility
    alias_method :warn_on_n_plus_one?, :warn_on_n_plus_one

    # Register a callback for N+1 detection events.
    # Useful for custom logging or metrics collection.
    # Callbacks are called regardless of mode (even in :ignore mode).
    #
    # @example Track N+1 patterns
    #   Parse.on_n_plus_one do |source, assoc, target, count, location|
    #     MyMetrics.increment("n_plus_one.#{source}.#{assoc}")
    #   end
    #
    # @yield [source_class, association, target_class, count, location]
    def on_n_plus_one(&block)
      NPlusOneDetector.on_n_plus_one(&block)
    end

    # Clear N+1 detection callbacks
    def clear_n_plus_one_callbacks!
      NPlusOneDetector.clear_callbacks!
    end

    # Reset N+1 detection tracking
    def reset_n_plus_one_tracking!
      NPlusOneDetector.reset!
    end

    # Get N+1 detection summary
    # @return [Hash]
    def n_plus_one_summary
      NPlusOneDetector.summary
    end

    # Configure N+1 detection thresholds.
    #
    # @example Configure thresholds
    #   Parse.configure_n_plus_one do |config|
    #     config.detection_window = 5.0   # 5 seconds
    #     config.fetch_threshold = 5      # 5 fetches to trigger
    #     config.cleanup_interval = 120.0 # cleanup every 2 minutes
    #   end
    #
    # @yield [NPlusOneDetector] the detector class for configuration
    def configure_n_plus_one
      yield NPlusOneDetector if block_given?
    end

    # Set the N+1 detection window (time in seconds to track related fetches)
    # @param value [Float]
    def n_plus_one_detection_window=(value)
      NPlusOneDetector.detection_window = value
    end

    # Get the N+1 detection window
    # @return [Float]
    def n_plus_one_detection_window
      NPlusOneDetector.detection_window
    end

    # Set the N+1 fetch threshold (minimum fetches to trigger warning)
    # @param value [Integer]
    def n_plus_one_fetch_threshold=(value)
      NPlusOneDetector.fetch_threshold = value
    end

    # Get the N+1 fetch threshold
    # @return [Integer]
    def n_plus_one_fetch_threshold
      NPlusOneDetector.fetch_threshold
    end
  end
end
