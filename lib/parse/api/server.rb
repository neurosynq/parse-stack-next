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

      # The `features` block advertised by `GET /serverInfo`. Parse Server
      # surfaces coarse capability groups here (`globalConfig`, `hooks`,
      # `cloudCode`, `logs`, `push`, `schemas`), each a Hash of booleans.
      # This is authoritative where present but intentionally coarse — it
      # does NOT carry fine-grained behavior flags like "public explain" or
      # the LiveQuery `keys` rename. Those are resolved by version inference
      # in {#server_supports?}.
      # @return [Hash] the advertised features block, or `{}` if unavailable.
      def server_features
        info = server_info
        return {} unless info.is_a?(Hash)
        feats = info[:features]
        feats.is_a?(Hash) ? feats : {}
      end

      # Capability table consumed by {#server_supports?}. Each entry is
      # version-inferred (we cannot read these off the coarse `features`
      # block) with one of two predicates:
      #
      # - `since:` — the capability EXISTS on this version and newer. An
      #   unknown/unparseable server version resolves to `true`
      #   (fail-open-to-modern: assume the current server line, matching the
      #   deprecation gate's posture).
      # - `until:` — the capability existed BELOW this version and was
      #   removed/restricted at it. Unknown version resolves to `false`
      #   (the modern server no longer offers it).
      #
      # `feature:` (a `[group, flag]` pair) lets a future capability prefer
      # the advertised `features` block when Parse Server genuinely surfaces
      # it there; absent that, the version predicate decides.
      # @!visibility private
      CAPABILITIES = {
        # LiveQuery subscription field projection: the `fields` option was
        # renamed `keys` in Parse Server 7.0.0 (DEPPS9 / #8852). The SDK
        # emits both, so this is informational rather than gating.
        livequery_keys_option: { since: "7.0.0" },
        # Cloud functions encode returned Parse.Object values as `__type`
        # dictionaries: default flipped to `true` in 8.0.0, made
        # unconditional (option removed) in 9.0.0.
        cloud_object_encoding: { since: "8.0.0" },
        # Non-master `explain` on a query: `allowPublicExplain` defaulted to
        # `false` in 9.0.0, so a session-scoped explain that worked on 8.x
        # is rejected on 9.x unless the operator re-enables it.
        public_explain: { until: "9.0.0" },
        # Aggregation `rawValues` / `rawFieldNames` options added in 9.9.0
        # (#10438).
        aggregate_raw_values: { since: "9.9.0" },
      }.freeze

      # Capability probe against the connected Parse Server. Builds on the
      # already-memoized {#server_info} (no extra round-trip beyond the one
      # `serverInfo` fetch) and the coarse `features` block, falling back to
      # version inference for behavior flags the `features` block does not
      # carry.
      #
      # Fails OPEN to the modern server line: when the server version cannot
      # be determined (offline unit tests, a `serverInfo` outage, a wire
      # surprise), a `since:` capability resolves `true` and an `until:`
      # capability resolves `false` — i.e. "assume the current server",
      # mirroring {#warn_if_deprecated_server_version!}.
      #
      # @example
      #   client.server_supports?(:public_explain)   # => false on PS 9.x
      #   client.server_supports?(:aggregate_raw_values)
      # @param feature [Symbol] a key of {CAPABILITIES}.
      # @return [Boolean] whether the connected server supports the feature.
      # @raise [ArgumentError] for an unknown capability key (typo guard).
      def server_supports?(feature)
        spec = CAPABILITIES[feature]
        raise ArgumentError, "Unknown Parse Server capability #{feature.inspect}" if spec.nil?

        # Prefer the advertised features block when a capability declares a
        # `[group, flag]` path AND the server actually surfaces it.
        if (path = spec[:feature])
          group, flag = path
          advertised = server_features.dig(group.to_s, flag.to_s)
          advertised = server_features.dig(group, flag) if advertised.nil?
          return advertised == true unless advertised.nil?
        end

        version = server_version.to_s
        if (floor = spec[:since])
          # Supported on `floor` and newer. Unknown version => assume modern => true.
          return true if version.empty?
          !server_version_below?(version, floor)
        elsif (ceiling = spec[:until])
          # Supported strictly below `ceiling`. Unknown version => assume modern => false.
          return false if version.empty?
          server_version_below?(version, ceiling)
        else
          false
        end
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
