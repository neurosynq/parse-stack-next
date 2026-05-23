# encoding: UTF-8
# frozen_string_literal: true

require "thread"

module Parse
  class Agent
    # Thread-safe rate limiter using a sliding window algorithm.
    #
    # Prevents resource exhaustion by limiting the number of requests
    # an agent can make within a time window.
    #
    # @example Basic usage
    #   limiter = RateLimiter.new(limit: 60, window: 60)  # 60 requests per minute
    #
    #   limiter.check!  # Passes
    #   # ... after too many requests ...
    #   limiter.check!  # raises RateLimitExceeded
    #
    # @example Check without raising
    #   if limiter.available?
    #     # Make request
    #   else
    #     puts "Rate limited, retry after #{limiter.retry_after}s"
    #   end
    #
    class RateLimiter
      # Error raised when rate limit is exceeded
      class RateLimitExceeded < StandardError
        attr_reader :retry_after, :limit, :window

        def initialize(retry_after:, limit:, window:)
          @retry_after = retry_after
          @limit = limit
          @window = window
          super("Rate limit exceeded (#{limit} requests per #{window}s). Retry after #{retry_after.round(1)}s")
        end
      end

      # Default requests allowed per window
      DEFAULT_LIMIT = 60

      # Default time window in seconds
      DEFAULT_WINDOW = 60

      # @return [Integer] maximum requests allowed per window
      attr_reader :limit

      # @return [Integer] time window in seconds
      attr_reader :window

      # Create a new rate limiter.
      #
      # @param limit [Integer] maximum requests per window (default: 60)
      # @param window [Integer] time window in seconds (default: 60)
      def initialize(limit: DEFAULT_LIMIT, window: DEFAULT_WINDOW)
        @limit = limit
        @window = window
        @requests = []
        @mutex = Mutex.new
      end

      # Check rate limit and record request. Raises if limit exceeded.
      #
      # @raise [RateLimitExceeded] if rate limit is exceeded
      # @return [true] if request is allowed
      def check!
        @mutex.synchronize do
          cleanup_old_requests

          if @requests.size >= @limit
            retry_after = calculate_retry_after
            raise RateLimitExceeded.new(
              retry_after: retry_after,
              limit: @limit,
              window: @window,
            )
          end

          @requests << Time.now.to_f
          true
        end
      end

      # Check if a request can be made without blocking.
      #
      # @return [Boolean] true if request would be allowed
      def available?
        @mutex.synchronize do
          cleanup_old_requests
          @requests.size < @limit
        end
      end

      # Get the number of remaining requests in current window.
      #
      # @return [Integer] remaining requests
      def remaining
        @mutex.synchronize do
          cleanup_old_requests
          [@limit - @requests.size, 0].max
        end
      end

      # Get seconds until rate limit resets (oldest request expires).
      #
      # @return [Float, nil] seconds until reset, or nil if not limited
      def retry_after
        @mutex.synchronize do
          cleanup_old_requests
          return nil if @requests.size < @limit
          calculate_retry_after
        end
      end

      # Reset the rate limiter (clear all recorded requests).
      #
      # @return [void]
      def reset!
        @mutex.synchronize do
          @requests.clear
        end
      end

      # Get rate limiter statistics.
      #
      # @return [Hash] current state information
      def stats
        @mutex.synchronize do
          cleanup_old_requests
          {
            limit: @limit,
            window: @window,
            used: @requests.size,
            remaining: [@limit - @requests.size, 0].max,
            retry_after: @requests.size >= @limit ? calculate_retry_after : nil,
          }
        end
      end

      private

      # Remove requests older than the time window
      def cleanup_old_requests
        cutoff = Time.now.to_f - @window
        @requests.reject! { |t| t < cutoff }
      end

      # Calculate seconds until oldest request expires
      def calculate_retry_after
        return 0.1 if @requests.empty?
        oldest = @requests.first
        time_until_expire = oldest + @window - Time.now.to_f
        [time_until_expire, 0.1].max
      end
    end
  end
end
