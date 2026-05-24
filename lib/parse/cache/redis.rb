# encoding: UTF-8
# frozen_string_literal: true

require "moneta"
require_relative "pool"

module Parse
  module Cache
    # Ergonomic Redis cache builder for Parse Stack. Composes a
    # ConnectionPool of Moneta-Redis stores and carries an optional
    # `namespace` that `Parse::Client` will pick up automatically — there
    # is no need to also pass `cache_namespace:` to `Parse.setup` when
    # using this wrapper.
    #
    # Usage:
    #   Parse.setup(
    #     cache: Parse::Cache::Redis.new(
    #       url: "redis://localhost:6379/0",
    #       namespace: "app_x",
    #       pool_size: 10,
    #     ),
    #     expires: 60,
    #     ...
    #   )
    #
    # The instance is a Moneta-compatible store (it delegates the four
    # methods the Faraday caching middleware uses — `[]`, `key?`,
    # `delete`, `store` — to a pooled backend), so it can be passed
    # directly to `Parse.setup(cache:)` / `Parse::Client.new(cache:)`.
    class Redis
      # @return [String, nil] cache key namespace prefix (or nil if not set).
      attr_reader :namespace

      # @return [Integer] pool size.
      attr_reader :pool_size

      # @return [String] Redis connection URL.
      attr_reader :url

      # @param url [String] Redis URL (e.g. `"redis://localhost:6379/0"`).
      # @param namespace [String, nil] optional key prefix so multiple Parse
      #   apps can share one Redis without colliding. When non-nil, the
      #   namespace is automatically forwarded to the caching middleware
      #   as `cache_namespace:`.
      # @param pool_size [Integer] number of pooled Moneta-Redis stores.
      #   Defaults to 5 (the Puma default thread count).
      #
      #   **Sizing math (per Faraday request):**
      #   - cache hit: `key?` + `[]` = **2 checkouts**
      #   - GET miss + successful store: `key?` + 3 variant deletes
      #     (anonymous + master-key sibling + final key) + 1 `store` in
      #     `on_complete` = **up to 5 checkouts**
      #   - non-GET write (POST/PUT/DELETE): 3 variant deletes =
      #     **3 checkouts**
      #
      #   The worst case (5) is on the write-through-after-miss path, not
      #   the hit path. Rule of thumb: start at `pool_size = RAILS_MAX_THREADS`,
      #   then bump it up if you observe `ConnectionPool::TimeoutError` in
      #   `parse.cache.error` notifications (the middleware swallows that
      #   error into a passthrough request rather than raising to the caller).
      # @param pool_timeout [Numeric] seconds to wait for a backend
      #   checkout before raising `ConnectionPool::TimeoutError`. Defaults
      #   to 5s. The caching middleware catches that error and falls back
      #   to a passthrough request rather than raising to the caller.
      # @param moneta_options [Hash] extra options passed through to
      #   `Moneta.new(:Redis, ...)` (e.g. `:db`, `:connect_timeout`).
      #   `expires: true` is set automatically so per-key TTLs supplied
      #   by the caching middleware (the `:expires` Faraday option) are
      #   honored by Redis. Pass `expires: false` here to opt out — but
      #   note that doing so causes cached responses to live forever,
      #   which is rarely what you want for a session-token-scoped
      #   response cache.
      def initialize(url:, namespace: nil, pool_size: 5, pool_timeout: 5, **moneta_options)
        @url = url
        @namespace = normalize_namespace(namespace)
        @pool_size = pool_size
        @pool_timeout = pool_timeout
        # Default expires: true so per-call `expires:` (the TTL the
        # Faraday caching middleware passes on store) is honored. The
        # Moneta-Redis adapter ignores per-call expires unless the
        # store was constructed with this flag. Without it, cached
        # session-scoped REST responses outlive their token's
        # validity. Callers can still pass `expires: false` to opt out.
        merged_options = { expires: true }.merge(moneta_options)
        @moneta_options = merged_options
        @closed = false
        @pool = Pool.new(size: pool_size, timeout: pool_timeout) do
          Moneta.new(:Redis, { url: url }.merge(merged_options))
        end
      end

      def [](key)
        @pool[key]
      end

      def key?(key)
        @pool.key?(key)
      end

      def delete(key)
        @pool.delete(key)
      end

      def store(key, value, options = {})
        @pool.store(key, value, options)
      end

      # Atomic SETNX. Required so `Parse::CreateLock` can acquire
      # cross-process locks when this wrapper is the configured cache /
      # `synchronize_create_store`. Returns `true` only when the key did
      # not already exist.
      def create(key, value, options = {})
        @pool.create(key, value, options)
      end

      # Atomic counter increment. Forwarded for Moneta surface parity.
      def increment(key, amount = 1, options = {})
        @pool.increment(key, amount, options)
      end

      # Clear cached entries belonging to this wrapper. Required for
      # `Parse::Client#clear_cache!` compatibility.
      #
      # **Namespace-scoped when a namespace is set:** the wrapper walks
      # `<namespace>:*` via Redis SCAN and DELs the matching keys,
      # leaving other tenants on the same DB untouched. When no
      # namespace is configured the wrapper falls back to `FLUSHDB` on
      # the backing DB — same blast radius as previous versions, but
      # only for unnamespaced deployments. To opt into the wide
      # FLUSHDB explicitly (e.g. ops tooling), call {#flush_db!}.
      #
      # @param scope [String, nil] explicit namespace prefix to scan-delete.
      #   When provided, overrides the wrapper's configured `@namespace` and
      #   SCAN-deletes `<scope>:*` regardless of how the wrapper was built.
      #   This is the safe escape hatch for tenants that share a non-
      #   namespaced wrapper but still want to evict only their own keys
      #   without `FLUSHDB`-ing siblings (and without wiping
      #   `parse-stack:foc:v1:*` create-lock keys that live on the same DB).
      #   The scope must be a non-empty String; the trailing `:` is added
      #   automatically and any trailing `:` in the input is stripped so
      #   `"tenant_x"` and `"tenant_x:"` are equivalent.
      def clear(scope: nil)
        if scope
          prefix = validate_scope!(scope)
          delete_keys_matching!("#{prefix}:*")
        elsif @namespace
          delete_keys_matching!("#{@namespace}:*")
        else
          @pool.clear
        end
        self
      end

      # Issue `FLUSHDB` on the backing Redis DB, regardless of whether a
      # namespace is configured. Evicts every key on the selected DB,
      # including unrelated tenants — use only for ops tooling that
      # owns the whole DB.
      def flush_db!
        @pool.clear
        self
      end

      # Close all pooled connections. Safe to call multiple times.
      def close
        return if @closed
        @closed = true
        @pool.close
      end

      private

      def delete_keys_matching!(pattern)
        @pool.pool.with do |store|
          redis = backend_client(store)
          # SCAN-DEL loop. `count:` is a hint to the server; the actual
          # batch size returned varies. Loop until the cursor wraps back
          # to "0".
          cursor = "0"
          loop do
            cursor, keys = redis.scan(cursor, match: pattern, count: 1000)
            redis.del(*keys) unless keys.empty?
            break if cursor == "0"
          end
        end
      end

      def backend_client(moneta_store)
        # Walk down the Moneta proxy chain (Expires → Adapter → redis-rb)
        # until we reach an object that quacks like the redis-rb client
        # (i.e. responds to #scan). Moneta wraps the actual adapter when
        # `expires: true` is passed, and the adapter then exposes the
        # underlying redis-rb client via `#backend` (modern releases) or
        # the `@backend` ivar (older releases).
        node = moneta_store
        12.times do
          return node if node.respond_to?(:scan)
          if node.respond_to?(:backend)
            node = node.backend
          elsif node.instance_variable_defined?(:@backend)
            node = node.instance_variable_get(:@backend)
          elsif node.instance_variable_defined?(:@adapter)
            node = node.instance_variable_get(:@adapter)
          else
            break
          end
          break if node.nil?
        end
        node
      end

      def normalize_namespace(ns)
        s = ns.to_s.chomp(":")
        s.empty? ? nil : s
      end

      # Validate a caller-supplied `scope:` for `clear(scope:)`. Returns the
      # normalized prefix or raises ArgumentError. We enforce:
      #
      # - must be a String (Symbol / Integer / nil would silently `.to_s`
      #   under `normalize_namespace` and expand the deletion target —
      #   `scope: 0` would clear `0:*`)
      # - must be non-empty after trimming a trailing `:`
      # - must not contain Redis SCAN glob metacharacters (`*`, `?`, `[`,
      #   `]`, `\`) — otherwise `scope: "*"` would SCAN-delete the whole
      #   DB, defeating the whole point of having `flush_db!` as the
      #   explicit wide-blast-radius escape hatch
      # - must not contain a null byte (defense-in-depth against keys
      #   crafted to terminate early in some Redis client paths)
      GLOB_METACHARS = /[\*\?\[\]\\\x00]/.freeze
      private_constant :GLOB_METACHARS

      def validate_scope!(scope)
        unless scope.is_a?(String)
          raise ArgumentError, "scope: must be a String (got #{scope.class})"
        end
        prefix = scope.chomp(":")
        if prefix.empty?
          raise ArgumentError, "scope: must be a non-empty namespace string"
        end
        if prefix.match?(GLOB_METACHARS)
          raise ArgumentError,
                "scope: must not contain Redis SCAN glob characters (*, ?, [, ], \\, or NUL); " \
                "use flush_db! for a full-DB flush"
        end
        prefix
      end
    end
  end
end
