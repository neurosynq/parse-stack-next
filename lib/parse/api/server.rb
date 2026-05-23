# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module API
    # APIs related to the open source Parse Server.
    module Server

      # @!attribute server_info
      #  @return [Hash] the information about the server.
      attr_writer :server_info

      # @!visibility private
      SERVER_INFO_PATH = "serverInfo"
      # @!visibility private
      SERVER_HEALTH_PATH = "health"

      # Minimum supported Parse Server major version. Below this floor the
      # SDK emits a one-shot deprecation warning per client instance the
      # first time `server_info` resolves. The threshold tracks "current
      # major minus two" against Parse Server's release cadence — Parse
      # Server 9.x is current in 2026, so anything below 7.0 is flagged.
      # Override with `PARSE_DEPRECATED_SERVER_VERSION_BELOW=6.0` or
      # silence entirely with `PARSE_SUPPRESS_SERVER_VERSION_WARNING=true`.
      DEPRECATED_SERVER_VERSION_BELOW = "7.0.0"

      # Fetch and cache information about the Parse server configuration. This
      # hash contains information specifically to the configuration of the running
      # parse server.
      # @return (see #server_info!)
      def server_info
        return @server_info if @server_info.present?
        response = request :get, SERVER_INFO_PATH
        @server_info = response.error? ? nil :
          response.result.with_indifferent_access
        warn_if_deprecated_server_version! if @server_info
        @server_info
      end

      # Fetches the status of the server based on the health check.
      # @return [Boolean] whether the server is 'OK'.
      def server_health
        opts = { cache: false }
        response = request :get, SERVER_HEALTH_PATH, opts: opts
        response.success?
      end

      # Force fetches the server information.
      # @return [Hash] a hash containing server configuration if available.
      def server_info!
        @server_info = nil
        @server_version_warned = false
        server_info
      end

      # Returns the version of the Parse server the client is connected to.
      # @return [String] a version string (ex. '2.2.25') if available.
      def server_version
        server_info.present? ? @server_info[:parseServerVersion] : nil
      end

      private

      # One-shot deprecation warning. The check runs once per client
      # instance (`@server_version_warned` latches), after `server_info`
      # has actually resolved against the wire — so unit tests that
      # never reach a real server don't pay the cost. Silenceable via
      # ENV so operators on a known-old Parse Server pinned for an
      # explicit reason can suppress the noise.
      def warn_if_deprecated_server_version!
        return if @server_version_warned
        return if ENV["PARSE_SUPPRESS_SERVER_VERSION_WARNING"] == "true"
        return unless defined?(Parse) && (!Parse.respond_to?(:suppress_server_version_warning?) || !Parse.suppress_server_version_warning?)
        version_string = @server_info[:parseServerVersion].to_s
        return if version_string.empty?
        floor = ENV["PARSE_DEPRECATED_SERVER_VERSION_BELOW"].to_s
        floor = DEPRECATED_SERVER_VERSION_BELOW if floor.empty?
        return unless server_version_below?(version_string, floor)
        @server_version_warned = true
        message = "[Parse::Client] DEPRECATION: connected Parse Server version #{version_string} " \
                  "is below the supported floor #{floor}. Newer Parse Stack releases assume " \
                  "behaviors (CLP shape, aggregate envelope, $vectorSearch, schema endpoints) " \
                  "that may not be present on this server. Upgrade Parse Server, or silence " \
                  "with Parse.suppress_server_version_warning = true / " \
                  "PARSE_SUPPRESS_SERVER_VERSION_WARNING=true. Override the floor with " \
                  "PARSE_DEPRECATED_SERVER_VERSION_BELOW=#{floor.sub(/\.0\.0\z/, ".0")}."
        if defined?(Parse) && Parse.respond_to?(:logger) && Parse.logger
          Parse.logger.warn(message)
        else
          warn message
        end
      end

      # Loose semver compare on major.minor. Parse Server publishes
      # `parseServerVersion` as `"9.0.0"`, `"6.5.7"`, `"8.0.0-alpha.1"`,
      # etc. We only care about the major (and minor as a tiebreak) for
      # the deprecation gate. Falls back to "not below" on any
      # unparseable input so a wire-format surprise never raises.
      def server_version_below?(actual, floor)
        actual_parts = actual.scan(/\d+/).first(2).map(&:to_i)
        floor_parts  = floor.scan(/\d+/).first(2).map(&:to_i)
        return false if actual_parts.empty? || floor_parts.empty?
        actual_parts << 0 while actual_parts.length < 2
        floor_parts  << 0 while floor_parts.length  < 2
        (actual_parts <=> floor_parts) < 0
      end
    end
  end
end
