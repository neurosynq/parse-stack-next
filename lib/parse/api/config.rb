# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module API
    # Defines the Config interface for the Parse REST API
    module Config

      # @!attribute config
      #  @return [Hash] the cached config hash for the client.
      attr_writer :config

      # @!attribute master_key_only
      #  @return [Hash] the cached masterKeyOnly flag map for the client.
      attr_writer :master_key_only

      # @!visibility private
      CONFIG_PATH = "config"

      # @return [Hash] force fetch the application configuration hash.
      def config!
        @config = nil
        @master_key_only = nil
        self.config
      end

      # Return the configuration hash for the configured application for this client.
      # This method caches the configuration after the first time it is fetched.
      # The accompanying `masterKeyOnly` map (if returned by the server) is cached
      # alongside it and exposed via {#master_key_only}.
      # @return [Hash] force fetch the application configuration hash.
      def config
        if @config.nil?
          response = request :get, CONFIG_PATH
          unless response.error?
            result = response.result || {}
            @config = result["params"] || {}
            @master_key_only = result["masterKeyOnly"] || {}
          end
        end
        @config
      end

      # Return every config entry zipped with its masterKeyOnly trait.
      #
      # Pass `master: true` to include keys whose `masterKeyOnly` flag is `true`;
      # the default `master: false` filters those entries out, matching what a
      # non-master-key client would actually observe. Each entry has the shape
      # `{ value: ..., master_key_only: Boolean }`. This is a client-side
      # filter on the already-cached config — it does NOT re-request the
      # config. When the connection is not authenticated with the master key,
      # Parse Server has already stripped master-key-only entries before the
      # response reaches the cache, so `master: true` has nothing extra to
      # surface in that case.
      #
      # @param master [Boolean] when true, include master-key-only entries.
      # @return [Hash{String=>Hash}] map of config key to `{value:, master_key_only:}`.
      def config_entries(master: false)
        config if @config.nil?
        return {} if @config.nil?
        flags = @master_key_only || {}
        @config.each_with_object({}) do |(key, value), out|
          is_master_only = flags[key] == true
          next if is_master_only && !master
          out[key] = { value: value, master_key_only: is_master_only }
        end
      end

      # Return the masterKeyOnly flag map for the application configuration.
      # Keys map to `true` when the corresponding config param is only readable
      # by master-key clients. Lazily triggers a config fetch on first access.
      # @return [Hash{String=>Boolean}] the cached masterKeyOnly map, or an
      #   empty hash if the server did not return one (e.g. non-master-key reads).
      def master_key_only
        config if @master_key_only.nil?
        @master_key_only || {}
      end

      # Update the application configuration.
      #
      # Pass `master_key_only:` to additionally mark (or unmark) which keys are
      # only readable by master-key clients. Parse Server merges this map into
      # the existing flags; unspecified keys keep their current flag. Note that
      # Parse Server rejects masterKeyOnly entries for keys that do not exist
      # in `params` (either in this PUT body or already stored).
      #
      # @param params [Hash] the hash of key value pairs.
      # @param master_key_only [Hash{String=>Boolean}, nil] optional flag map
      #   to merge into the server-side masterKeyOnly settings.
      # @return [Boolean] true if the configuration was successfully updated.
      def update_config(params, master_key_only: nil)
        body = { params: params }
        unless master_key_only.nil?
          body[:masterKeyOnly] = master_key_only
          # Parse Server (9.x) rejects PUT /parse/config when masterKeyOnly
          # references a key that is not present in the request's params
          # payload, EVEN IF the key already exists in stored config. The
          # SDK absorbs that constraint by backfilling any flag-only keys
          # from the cached @config so flag-only updates round-trip cleanly.
          # Without this, `update_config({}, master_key_only: {foo: false})`
          # would always fail with a server-side 400 even after foo was
          # previously persisted.
          if @config.is_a?(Hash)
            master_key_only.each_key do |k|
              ks = k.to_s
              next if body[:params].key?(ks) || body[:params].key?(k)
              cached = @config[ks]
              body[:params][ks] = cached unless cached.nil?
            end
          end
        end
        response = request :put, CONFIG_PATH, body: body
        return false if response.error?
        result = response.result["result"]
        if result
          @config.merge!(params) if @config.present?
          if master_key_only.is_a?(Hash) && @master_key_only.is_a?(Hash)
            @master_key_only.merge!(master_key_only.transform_keys(&:to_s))
          end
        end
        result
      end
    end
  end
end
