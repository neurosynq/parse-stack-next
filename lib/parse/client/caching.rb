# encoding: UTF-8
# frozen_string_literal: true

require "faraday"
require "moneta"
require "connection_pool"
require "digest"
require_relative "protocol"

module Parse
  module Middleware
    # This is a caching middleware for Parse queries using Moneta. The caching
    # middleware will cache all GET requests made to the Parse REST API as long
    # as the API responds with a successful non-empty result payload.
    #
    # Whenever an object is created or updated, the corresponding entry in the cache
    # when fetching the particular record (using the specific non-Query based API)
    # will be cleared.
    class Caching < Faraday::Middleware
      include Parse::Protocol

      # List of status codes that can be cached:
      # * 200 - 'OK'
      # * 203 - 'Non-Authoritative Information'
      # * 300 - 'Multiple Choices'
      # * 301 - 'Moved Permanently'
      # * 302 - 'Found'
      # * 404 - 'Not Found' - removed
      # * 410 - 'Gone' - removed
      CACHEABLE_HTTP_CODES = [200, 203, 300, 301, 302].freeze
      # Cache control header
      CACHE_CONTROL = "Cache-Control"
      # Request env key for the content length
      CONTENT_LENGTH_KEY = "content-length"
      # Header in response that is sent if this is a cached result
      CACHE_RESPONSE_HEADER = "X-Cache-Response"
      # Header in request to set caching information for the middleware.
      CACHE_EXPIRES_DURATION = "X-Parse-Stack-Cache-Expires"
      # Header in request to enable write-only cache mode (skip read, still write)
      CACHE_WRITE_ONLY = "X-Parse-Stack-Cache-Write-Only"

      class << self
        # @!attribute enabled
        # @return [Boolean] whether the caching middleware should be enabled.
        attr_writer :enabled

        # @!attribute logging
        # @return [Boolean] whether the logging should be enabled.
        attr_accessor :logging

        def enabled
          @enabled = true if @enabled.nil?
          @enabled
        end

        # @return [Boolean] whether caching is enabled.
        def caching?
          @enabled
        end
      end

      # @!attribute [rw] store
      # The internal moneta cache store instance.
      # @return [Moneta::Transformer,Moneta::Expires]
      attr_accessor :store

      # @!attribute [rw] expires
      # The expiration time in seconds for this particular request.
      # @return [Integer]
      attr_accessor :expires

      # Creates a new caching middleware.
      # @param adapter [Faraday::Adapter] An instance of the Faraday adapter
      #  used for the connection. Defaults Faraday::Adapter::NetHttp.
      # @param store [Moneta] An instance of the Moneta cache store to use.
      # @param opts [Hash] additional options.
      # @option opts [Integer] :expires the default expiration for a cache entry.
      # @raise ArgumentError, if `store` is not a Moneta::Transformer or Moneta::Expires instance.
      def initialize(adapter, store, opts = {})
        super(adapter)
        @store = store
        @opts = { expires: 0 }
        @opts.merge!(opts) if opts.is_a?(Hash)
        @expires = @opts[:expires]
        # Optional cache key namespace so two Parse apps sharing one Redis don't
        # collide (e.g. `mk:/classes/Song/abc` is the same path for both apps).
        # When set, keys become `<namespace>:<existing-prefix>:<url>`. Empty
        # string is treated as nil. Trailing `:` is stripped once so users can
        # pass either `"app_x"` or `"app_x:"`.
        ns = @opts[:namespace].to_s
        ns = ns.chomp(":")
        @namespace = ns.empty? ? nil : ns

        # The keyspace owns physical key layout and the patterns that clear it,
        # so key generation and eviction cannot drift apart. Previously this
        # middleware composed keys from its own `@namespace` while
        # `Parse::Cache::Redis` held a separate one, and `clear_cache!` used
        # only the latter: a client namespaced here but not there would clear
        # every SDK key on the database instead of its own.
        #
        # When no keyspace is supplied the middleware keeps writing legacy
        # un-prefixed keys, so an upgrade that does not opt in behaves exactly
        # as before.
        @keyspace = @opts[:keyspace]
        # During the transition, also delete the pre-keyspace form of a key on
        # invalidation. Without this, a rolling deploy has new workers writing
        # keyspaced keys while old workers still read legacy ones, so a write
        # served by a new worker never invalidates what an old worker serves.
        @delete_legacy_variants = @opts.fetch(:delete_legacy_variants, true)

        unless [:key?, :[], :delete, :store].all? { |method| @store.respond_to?(method) }
          raise ArgumentError, "Caching store object must a Moneta key/value store."
        end
      end

      # Thread-safety
      # @!visibility private
      def call(env)
        dup.call!(env)
      end

      # @!visibility private
      def call!(env)
        @request_headers = env[:request_headers]

        # get default caching state
        @enabled = self.class.enabled
        # disable cache for this request if "no-cache" was passed
        if @request_headers[CACHE_CONTROL] == "no-cache"
          @enabled = false
        end

        # Check for write-only mode (skip cache read, still write to cache)
        # This is useful for fetch!/reload! which want fresh data but should update cache
        @write_only = @request_headers[CACHE_WRITE_ONLY] == "true"

        # get the expires information from header (per-request) or instance default
        if @request_headers[CACHE_EXPIRES_DURATION].to_i > 0
          @expires = @request_headers[CACHE_EXPIRES_DURATION].to_i
        end

        # cleanup
        @request_headers.delete(CACHE_CONTROL)
        @request_headers.delete(CACHE_EXPIRES_DURATION)
        @request_headers.delete(CACHE_WRITE_ONLY)

        # if caching is enabled and we have a valid cache duration, use cache
        # otherwise work as a passthrough.
        return @app.call(env) unless @enabled && @store.present? && @expires > 0

        url = env.url
        method = env.method
        @cache_key = url.to_s

        # Auth discriminator. A master-key request bypasses ACL, CLP and
        # protectedFields, so the same URL returns a strictly fuller body than a
        # session request, and two sessions can differ from each other through
        # protectedFields entity rules and row ACLs. These must never share a
        # cache entry or the cache would hand privileged fields to an
        # unprivileged caller.
        @cache_auth = :anon
        if @request_headers.key?(SESSION_TOKEN)
          @session_token = @request_headers[SESSION_TOKEN]
          hashed_token = Digest::SHA256.hexdigest(@session_token.to_s)[0, 32]
          @cache_auth = hashed_token
          @cache_key = "#{hashed_token}:#{@cache_key}" # prefix with hashed token
        elsif @request_headers.key?(MASTER_KEY)
          @cache_auth = :master
          @cache_key = "mk:#{@cache_key}" # prefix for master key requests
        end

        # Optional ambient cache-tenant scope from `Parse.with_cache_tenant`.
        # When present, composes between the configured namespace and the
        # token/mk prefix as `T:<tenant>:` so a SCAN-delete over
        # `<namespace>:T:<tenant>:*` evicts exactly one tenant, and
        # `<namespace>:*` still evicts the whole namespace cleanly. The
        # `T:` discriminator makes tenant prefixes unambiguously
        # distinguishable from session-token hex prefixes (32-char hex)
        # and from `mk:`, so legacy cache entries written before the
        # tenant feature don't accidentally re-hydrate into a tenanted
        # request and vice versa.
        @cache_tenant = Parse.respond_to?(:current_cache_tenant) ? Parse.current_cache_tenant : nil
        @cache_key = "T:#{@cache_tenant}:#{@cache_key}" if @cache_tenant

        # Namespace outermost so a SCAN over `<namespace>:*` evicts a whole
        # tenant/app cleanly without touching another app's entries.
        @cache_key = "#{@namespace}:#{@cache_key}" if @namespace

        # Keep the legacy key for dual-delete on invalidation, then switch the
        # live key to the keyspace form when one is configured.
        @legacy_cache_key = @cache_key
        if @keyspace
          @cache_key = @keyspace.cache_key(url, auth: @cache_auth, tenant: @cache_tenant)
        end

        url_path = url.path

        begin
          # Skip cache read if write_only mode is enabled
          if method == :get && @cache_key.present? && !@write_only && @store.key?(@cache_key)
            # Debug-log the URL **path only** — `url.to_s` would include the
            # query string, which Parse encodes JSON `where=` into and may
            # contain PII. Same redaction discipline as the AS::N payload.
            puts("[Parse::Cache] Hit >> #{url_path}") if self.class.logging.present?
            response = Faraday::Response.new
            begin
              cache_data = @store[@cache_key] # previous cached response
            rescue => e
              # Log only the class name — some Moneta/Redis drivers echo the
              # offending key in `e.message`, and our key contains a hashed
              # session-token prefix that we treat as side-channel material.
              puts "[Parse::Cache] Error: #{e.class.name}"
              instrument_cache(:error, method: method, url_path: url_path, error: e.class.name)
              cache_data = nil
            end

            # check if the store was from a legacy parse-stack cache value which
            # is stored as Faraday::Env. T\he new system stores less content in a simple hash
            # for improved interoperability and access time.
            body = nil
            response_headers = nil
            if cache_data.is_a?(Faraday::Env)
              body = cache_data.respond_to?(:body) ? cache_data.body : nil
              response_headers = cache_data.response_headers || {}
            elsif cache_data.is_a?(Hash)
              # New entries are stored with string keys so they survive a
              # JSON round-trip (the Redis cache wrapper serializes values as
              # JSON, not Marshal — see Parse::Cache::Redis). Fall back to
              # symbol keys for legacy in-memory / Marshal-backed entries
              # written before that switch.
              body = cache_data["body"] || cache_data[:body]
              response_headers = cache_data["headers"] || cache_data[:headers] || {}
            end

            if cache_data.present? && body.present?
              response_headers[CACHE_RESPONSE_HEADER] = "true"
              response.finish({ status: 200, response_headers: response_headers, body: body })
              instrument_cache(:hit, method: method, url_path: url_path)
              return response
            else
              delete_cache_variants(url)
              instrument_cache(:miss, method: method, url_path: url_path, reason: :empty_payload)
            end
          elsif method == :get && @cache_key.present? && !@write_only
            # GET miss: opportunistically clear any sibling variants of the
            # current namespace (anonymous `<url>` and master-key `mk:<url>`
            # under the same namespace) so a stale variant from a prior
            # request flavor doesn't linger until TTL.
            #
            # When @namespace is set we deliberately do NOT touch the bare
            # un-namespaced `<url>` / `mk:<url>` keys — those could belong to
            # another Parse app sharing the Redis DB, and cross-namespace
            # eviction would be a blast-radius bug, not a fix. Operators
            # upgrading an SDK that previously wrote un-namespaced keys
            # should evict those once at upgrade time via SCAN.
            delete_cache_variants(url)
            instrument_cache(:miss, method: method, url_path: url_path)
          elsif method == :get && @cache_key.present? && @write_only
            delete_cache_variants(url)
            instrument_cache(:miss, method: method, url_path: url_path, reason: :write_only)
          elsif @cache_key.present?
            #non GET requets should clear the cache for that same resource path.
            #ex. a POST to /1/classes/Artist/<objectId> should delete the cache for a GET
            # request for the same '/1/classes/Artist/<objectId>' where objectId are equivalent
            delete_cache_variants(url, resource: true)
            instrument_cache(:delete, method: method, url_path: url_path)
          end
          # `Redis::CommandError` covers the failures a scoped eviction can now
          # produce that a plain GET/SET never did: a NOPERM from a restricted
          # ACL, an UNLINK the server does not implement, and a CROSSSLOT refusal
          # under Redis Cluster. Without it those escape the middleware and turn a
          # cache problem into a failed application request, which inverts the
          # whole point of the cache being optional.
        rescue ::TypeError, Errno::EINVAL, Redis::CannotConnectError, Redis::TimeoutError,
               Redis::CommandError, ConnectionPool::TimeoutError => e
          # if the cache store fails to connect, catch the exception but proceed
          # with the regular request, but turn off caching for this request. It is possible
          # that the cache connection resumes at a later point, so this is temporary.
          @enabled = false
          puts "[Parse::Cache] Error: #{e.class.name}"
          instrument_cache(:error, method: method, url_path: url_path, error: e.class.name)
        end

        @app.call(env).on_complete do |response_env|
          # Only cache GET requests with valid HTTP status codes whose content-length
          # is between 20 bytes and 1MB. Otherwise they could be errors, successes and empty result sets.

          if @enabled && method == :get && CACHEABLE_HTTP_CODES.include?(response_env.status) &&
             response_env.body.present? && response_env.response_headers[CONTENT_LENGTH_KEY].to_i.between?(20, 1_250_000)
            store_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            begin
              # Store with string keys (and a plain Hash of headers) so the
              # value round-trips losslessly through the Redis cache wrapper's
              # JSON serialization. The read path above reads string keys first
              # with a symbol-key fallback for legacy entries.
              @store.store(@cache_key,
                           { "headers" => response_env.response_headers.to_h, "body" => response_env.body },
                           expires: @expires)
              duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - store_start) * 1000.0).round(3)
              instrument_cache(:store, method: method, url_path: url_path, duration_ms: duration_ms)
            rescue => e
              puts "[Parse::Cache] Store Error: #{e.class.name}"
              instrument_cache(:error, method: method, url_path: url_path, error: e.class.name)
            end
          end # if
          # do something with the response
          # response_env[:response_headers].merge!(...)
        end
      end

      private

      # Emit an ActiveSupport::Notifications event under the `parse.cache.*`
      # namespace.
      #
      # **Payload shape (stable):** `{ event:, namespace:, method:, url_path:,
      # [reason:], [duration_ms:], [error:] }`.
      #
      # **Security invariants:**
      # - The cache key is NEVER emitted. The key contains a hashed
      #   session-token prefix that would be a side-channel for "this user
      #   has data at this URL" enumeration.
      # - `url_path` is `URI#path` only — query strings are stripped because
      #   Parse encodes query JSON there (potentially long or PII-bearing).
      # - `error` is `Exception#class.name` only — never the exception
      #   message or backtrace.
      # - `namespace` is whatever the SDK consumer configured at setup. Treat
      #   subscribers as you would your application log sink: they observe
      #   the namespace, the HTTP method, and the URL path of every cached
      #   GET / invalidating write.
      #
      # **Subscriber discipline:** ActiveSupport::Notifications runs
      # subscribers **synchronously on the Faraday request thread**. A
      # blocking subscriber (e.g. synchronous I/O to a slow sink) blocks
      # every cached request for the duration of its work, and an exception
      # raised inside a subscriber will surface as a request failure. Keep
      # subscribers cheap — counter increments, in-memory accumulators, or
      # non-blocking sinks like StatsD-over-UDP.
      # @!visibility private
      def instrument_cache(event, **extra)
        return unless defined?(ActiveSupport::Notifications)
        payload = {
          event: event,
          namespace: @namespace,
          cache_tenant: @cache_tenant,
        }.merge!(extra)
        ActiveSupport::Notifications.instrument("parse.cache.#{event}", payload)
      end

      # Delete the canonical cache_key plus its legacy un-namespaced and
      # master-key-prefixed variants. Called on both GET misses (defensive
      # cleanup of stale pre-namespace entries) and non-GET writes (cache
      # invalidation for the resource).
      # @!visibility private
      # @param resource [Boolean] when true, evict every auth variant of this
      #   resource, not just the caller's own entry. Only a write should do
      #   that. On a GET miss this method is called defensively to clear stale
      #   siblings, and evicting resource-wide there would destroy other
      #   sessions' perfectly valid entries on every single cache miss.
      def delete_cache_variants(url, resource: false)
        delete_keyspace_variants(url) if resource && @keyspace
        delete_legacy_variants(url) if legacy_variants?
        @store.delete @cache_key # final key
      end

      # Whether to also evict the pre-keyspace key shape. Always true before a
      # keyspace is configured, since that shape is the only one in use.
      # @!visibility private
      def legacy_variants?
        @keyspace.nil? || @delete_legacy_variants
      end

      # Evict every auth variant of this resource, not just the caller's own.
      #
      # The old two-variant delete could name the anonymous and master-key
      # siblings but had no way to enumerate *other sessions'* entries, so a
      # write by one user left every other user holding a stale copy until TTL.
      # A scan-capable store can express that as one pattern; anything else
      # falls back to the variants we can name.
      # @!visibility private
      def delete_keyspace_variants(url)
        pattern = @keyspace.resource_pattern(url, tenant: @cache_tenant)
        if @store.respond_to?(:delete_matching)
          @store.delete_matching(pattern)
        else
          @store.delete @keyspace.cache_key(url, auth: :anon, tenant: @cache_tenant)
          @store.delete @keyspace.cache_key(url, auth: :master, tenant: @cache_tenant)
        end
      end

      # Evict the pre-keyspace key shape so a rolling deploy does not leave old
      # workers serving entries that a new worker's write should have killed.
      # @!visibility private
      def delete_legacy_variants(url)
        if @namespace
          # Namespaced: only delete our app's variants so a write through
          # client A doesn't blow away client B's cache when both share Redis.
          @store.delete "#{@namespace}:#{url.to_s}"
          @store.delete "#{@namespace}:mk:#{url.to_s}"
        else
          @store.delete url.to_s # regular
          @store.delete "mk:#{url.to_s}" # master key cache-key
        end
        @store.delete @legacy_cache_key if @legacy_cache_key
      end
    end #Caching
  end #Middleware
end
