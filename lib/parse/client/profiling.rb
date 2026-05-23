# encoding: UTF-8
# frozen_string_literal: true

require "faraday"

module Parse
  module Middleware
    # Faraday middleware that profiles Parse API requests.
    #
    # This middleware provides detailed timing information for HTTP requests
    # including network time and overall request duration.
    #
    # @example Enable profiling
    #   Parse.profiling_enabled = true
    #
    # @example Access profile data in callbacks
    #   Parse.on_request_complete do |profile|
    #     puts "Request to #{profile[:url]} took #{profile[:duration_ms]}ms"
    #   end
    #
    # @example Get recent profiles
    #   Parse.recent_profiles.each do |profile|
    #     puts "#{profile[:method]} #{profile[:url]}: #{profile[:duration_ms]}ms"
    #   end
    #
    class Profiling < Faraday::Middleware
      # Maximum number of profiles to keep in memory
      MAX_PROFILES = 100

      class << self
        # @return [Boolean] Whether profiling is enabled
        attr_accessor :enabled

        # @return [Array<Hash>] Recent profile data
        def profiles
          @profiles ||= []
        end

        # Clear all stored profiles
        def clear_profiles!
          @profiles = []
        end

        # @return [Array<Proc>] Callbacks to execute on request completion
        def callbacks
          @callbacks ||= []
        end

        # Register a callback to be executed when a request completes
        # @yield [Hash] the profile data for the completed request
        def on_request_complete(&block)
          callbacks << block if block_given?
        end

        # Clear all registered callbacks
        def clear_callbacks!
          @callbacks = []
        end

        # Add a profile entry
        # @param profile [Hash] the profile data
        def add_profile(profile)
          profiles << profile
          # Keep only the most recent profiles
          profiles.shift while profiles.size > MAX_PROFILES

          # Execute callbacks
          callbacks.each { |cb| cb.call(profile) }
        end

        # Get aggregate statistics for recent profiles
        # @return [Hash] statistics including count, avg, min, max durations
        def statistics
          return {} if profiles.empty?

          durations = profiles.map { |p| p[:duration_ms] }
          {
            count: profiles.size,
            total_ms: durations.sum,
            avg_ms: (durations.sum.to_f / durations.size).round(2),
            min_ms: durations.min,
            max_ms: durations.max,
            by_method: profiles.group_by { |p| p[:method] }.transform_values(&:size),
            by_status: profiles.group_by { |p| p[:status] }.transform_values(&:size),
          }
        end
      end

      # Thread-safety: duplicate the middleware for each request
      # @!visibility private
      def call(env)
        dup.call!(env)
      end

      # @!visibility private
      def call!(env)
        return @app.call(env) unless self.class.enabled

        start_time = Time.now

        @app.call(env).on_complete do |response_env|
          end_time = Time.now
          duration_ms = ((end_time - start_time) * 1000).round(2)

          profile = {
            method: env[:method].to_s.upcase,
            url: sanitize_url(env[:url].to_s),
            status: response_env[:status],
            duration_ms: duration_ms,
            started_at: start_time.iso8601(3),
            completed_at: end_time.iso8601(3),
            request_size: env[:body].to_s.bytesize,
            response_size: response_body_size(response_env),
          }

          self.class.add_profile(profile)
        end
      end

      private

      def sanitize_url(url)
        # Remove sensitive query parameters
        url.gsub(/([?&])(sessionToken|masterKey|apiKey)=[^&]*/, '\1\2=[FILTERED]')
      end

      def response_body_size(response_env)
        body = response_env[:body]
        if body.is_a?(Parse::Response)
          body.result.to_json.bytesize rescue 0
        elsif body.is_a?(String)
          body.bytesize
        else
          body.to_s.bytesize
        end
      end
    end
  end

  # Module-level profiling configuration
  class << self
    # Enable or disable request profiling
    # @param value [Boolean]
    def profiling_enabled=(value)
      Middleware::Profiling.enabled = value
    end

    # @return [Boolean] whether profiling is enabled
    def profiling_enabled
      Middleware::Profiling.enabled
    end

    # Get recent profile data
    # @return [Array<Hash>]
    def recent_profiles
      Middleware::Profiling.profiles
    end

    # Clear all stored profiles
    def clear_profiles!
      Middleware::Profiling.clear_profiles!
    end

    # Get profiling statistics
    # @return [Hash]
    def profiling_statistics
      Middleware::Profiling.statistics
    end

    # Register a callback for request completion
    # @yield [Hash] profile data
    def on_request_complete(&block)
      Middleware::Profiling.on_request_complete(&block)
    end

    # Clear all profiling callbacks
    def clear_profiling_callbacks!
      Middleware::Profiling.clear_callbacks!
    end
  end
end
