# encoding: UTF-8
# frozen_string_literal: true

require "connection_pool"
require "moneta"

module Parse
  module Cache
    # Moneta-compatible facade over a ConnectionPool of Moneta stores. The
    # Faraday caching middleware only calls four methods on its store
    # (`[]`, `key?`, `delete`, `store`); this class checks out a backend
    # for each of them via `@pool.with`.
    #
    # Why a pool: a single Moneta-Redis store wraps one Redis connection.
    # Under a multi-threaded Puma worker (or any concurrent caller), threads
    # serialize on that connection's mutex. A pool of N stores lets up to N
    # cache calls run in parallel.
    #
    # Note that a cache hit costs two checkouts (`key?` then `[]`). That is
    # accepted to keep behavior identical to a plain Moneta store; callers
    # should size the pool with that in mind (default 5, which matches the
    # Puma default thread count).
    class Pool
      # The wrapped ConnectionPool instance.
      attr_reader :pool

      # @param size [Integer] number of pooled backend stores.
      # @param timeout [Numeric] seconds to wait for a checkout before
      #   raising `ConnectionPool::TimeoutError`.
      # @yield Block invoked to build a single backend store. Must return a
      #   Moneta store responding to `[]`, `key?`, `delete`, `store`.
      def initialize(size: 5, timeout: 5, &block)
        raise ArgumentError, "Parse::Cache::Pool requires a block that builds a Moneta store" unless block_given?
        @pool = ConnectionPool.new(size: size, timeout: timeout, &block)
        @closed = false
      end

      def [](key)
        @pool.with { |store| store[key] }
      end

      def key?(key)
        @pool.with { |store| store.key?(key) }
      end

      def delete(key)
        @pool.with { |store| store.delete(key) }
      end

      def store(key, value, options = {})
        @pool.with { |store| store.store(key, value, options) }
      end

      # Atomic SETNX-style write. Required by `Parse::CreateLock` to acquire
      # cross-process locks against Redis-backed stores. Forwards to the
      # underlying Moneta store's `#create`, which returns `true` only if
      # the key was absent and is now set.
      def create(key, value, options = {})
        @pool.with { |store| store.create(key, value, options) }
      end

      # Atomic counter increment. Forwarded for parity with Moneta so
      # callers expecting the full Moneta surface (counters, rate limits)
      # work transparently through the pool.
      def increment(key, amount = 1, options = {})
        @pool.with { |store| store.increment(key, amount, options) }
      end

      # Clear the underlying backend. Pooled Moneta stores all point at the
      # same Redis DB, so a single checkout suffices — issuing `clear` on
      # one connection flushes the DB for every connection.
      def clear
        @pool.with { |store| store.clear if store.respond_to?(:clear) }
        self
      end

      # Close all pooled backends. Safe to call multiple times — repeat
      # calls are no-ops. `ConnectionPool#shutdown` raises
      # `ConnectionPool::PoolShuttingDownError` on a second invocation,
      # so we gate it with a `@closed` flag.
      def close
        return if @closed
        @closed = true
        @pool.shutdown { |store| store.close if store.respond_to?(:close) }
      end
    end
  end
end
