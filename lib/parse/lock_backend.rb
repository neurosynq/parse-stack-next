# encoding: UTF-8
# frozen_string_literal: true

require "monitor"

module Parse
  # Shared low-level primitives for both {Parse::CreateLock} (the
  # internal lock used by `first_or_create!` / `create_or_update!`)
  # and {Parse::Lock} (the public mutual-exclusion primitive). The
  # extraction exists so {Parse::Lock} does not reach into
  # {Parse::CreateLock}'s private methods via `.send` — a brittle
  # coupling pattern called out in the v5.1.0 round-2 review. Both
  # callers now depend on a small documented surface and any future
  # refactor of the lock store discovery / degraded-detection
  # heuristic / atomic-SETNX semantics happens in exactly one place.
  #
  # **Not a public API for application code.** `@!visibility private`
  # is intentional. End users compose with locking through
  # {Parse::Lock.acquire} (block-form) or `first_or_create!` /
  # `create_or_update!` (find-or-create). This module is documented
  # only because SDK extension authors and security auditors need to
  # know where the SETNX semantics actually live.
  #
  # @api private
  module LockBackend
    # Base poll interval for the wait-loop spin in the caller's
    # acquire loop. Caller adds jitter via {.poll_interval}; this
    # constant is the midpoint.
    DEFAULT_POLL_BASE = 0.05

    # Half-width of the symmetric jitter applied around
    # {DEFAULT_POLL_BASE}. Spreads contended-acquire spin starts so
    # N waiters don't all hit `try_acquire` on the same monotonic
    # tick after a release.
    DEFAULT_POLL_JITTER = 0.015

    # Throttle floor for {.handle_degraded}(`:warn_throttled`). One
    # warning per process per this many seconds; subsequent degraded
    # acquisitions are silent.
    DEGRADED_WARNING_THROTTLE_SECONDS = 60

    class << self
      # Find the Moneta store the lock should write through. Resolved
      # at call time (not memoized) so a test or an operator can swap
      # `Parse.synchronize_create_store` after boot and see the change
      # take effect on the next acquisition.
      #
      # @return [Object, nil] a Moneta-shaped store, or nil when none
      #   is configured / the Parse client is unconfigured.
      def lock_store
        if Parse.respond_to?(:synchronize_create_store) && Parse.synchronize_create_store
          return Parse.synchronize_create_store
        end
        Parse.cache
      rescue Parse::Error::ConnectionError
        nil
      end

      # Decide whether `store` is process-local (Memory / Null /
      # missing-`:create` / nil) — i.e. cannot serve as a cross-
      # process lock store, so the caller should fall back to a
      # per-key in-process Mutex. The {Parse::Cache::Redis} wrapper
      # is explicitly accepted because it doesn't expose a Moneta
      # `.adapter` chain to walk.
      #
      # @param store [Object, nil] candidate store
      # @return [Boolean]
      def degraded_store?(store)
        return true if store.nil?
        return false if defined?(Parse::Cache::Redis) && store.is_a?(Parse::Cache::Redis)
        return true unless store.respond_to?(:create)
        bottom = walk_to_adapter(store)
        return true if bottom.nil?
        klass_name = bottom.class.name.to_s
        klass_name.include?("Memory") || klass_name.include?("Null")
      end

      # Emit the configured degraded-store warning. `source:` lets
      # the caller tag the prefix so an operator reading
      # `[Parse::Lock] Lock store is process-local` knows which
      # caller surfaced the warning (vs `[Parse::CreateLock]` for
      # the find-or-create path).
      #
      # @param mode [Symbol] one of `:warn`, `:warn_throttled`,
      #   `:proceed`, `:raise`. Callers are responsible for
      #   validating the symbol BEFORE calling this; an unknown
      #   value here falls through to plain `:warn`.
      # @param key [String] the (already-hashed) cache key — used
      #   only for the debug snippet in the warning message.
      # @param source [String] caller tag for the log prefix.
      # @param unavailable_error [Class] error class to raise in
      #   `:raise` mode. Lets each caller raise its own typed
      #   error (Parse::CreateLockUnavailableError vs
      #   Parse::Lock::UnavailableError) without coupling here.
      def handle_degraded(mode, key, source: "Parse::LockBackend",
                          unavailable_error: nil)
        case mode
        when :raise
          err = unavailable_error || Parse::Error
          raise err,
                "#{source}: cross-process lock store unavailable; " \
                "current store is process-local"
        when :proceed
          # silent
        when :warn_throttled
          now = monotonic_now
          if @degraded_warned_at.nil? ||
             (now - @degraded_warned_at) >= DEGRADED_WARNING_THROTTLE_SECONDS
            @degraded_warned_at = now
            warn "[#{source}] Lock store is process-local (Moneta Memory/Null). " \
                 "Cross-process locking is NOT in effect. Configure a Redis-backed " \
                 "cache to enable distributed locking."
          end
        else
          warn "[#{source}] Lock store is process-local; cross-process locking disabled. " \
               "key_digest=#{key.is_a?(String) ? key[-12..] : key.inspect}"
        end
      end

      # Atomic SETNX-style acquisition. Returns true on success,
      # false on contention OR error (logged). Never raises — the
      # caller's wait loop is the source of truth for "did we get
      # the lock," and a transient store error should look the
      # same to the loop as "someone else has it."
      #
      # @param store [Object] Moneta-shaped store responding to
      #   `:create` and `:key?`.
      # @param key [String] cache key (already prefixed/hashed).
      # @param owner [String] unique-per-acquisition identifier
      #   used by {.release}'s compare-and-delete.
      # @param ttl [Integer] seconds before the store entry self-
      #   clears (crash-recovery floor).
      # @return [Boolean]
      def try_acquire(store, key, owner, ttl)
        # Trigger lazy TTL sweep on Moneta::Memory before `:create`
        # (no-op on Redis). Without this, the Memory adapter returns
        # false on `:create` even after TTL expiry until a `:key?`
        # or `:[]` access flushes the stale entry.
        store.key?(key)
        store.create(key, owner, expires: ttl)
      rescue StandardError => e
        warn "[Parse::LockBackend] acquire error (#{e.class}): #{e.message}"
        false
      end

      # Best-effort compare-and-delete release. Moneta does not
      # expose atomic CAD; the worst-case race is bounded by the
      # short TTL (callers clamp `ttl:` to ≤ 30s).
      #
      # @param store [Object] Moneta-shaped store.
      # @param key [String] cache key.
      # @param owner [String] the owner token from {.try_acquire}.
      def release(store, key, owner)
        current = store[key]
        store.delete(key) if current == owner
      rescue StandardError => e
        warn "[Parse::LockBackend] release error (#{e.class}): #{e.message}"
      end

      # Jittered poll interval for the wait-loop. Symmetric jitter
      # around {DEFAULT_POLL_BASE} of half-width
      # {DEFAULT_POLL_JITTER}; the result is bounded but
      # non-deterministic so contended waiters don't sync up.
      #
      # @return [Float] seconds.
      def poll_interval
        DEFAULT_POLL_BASE + (rand * 2 - 1) * DEFAULT_POLL_JITTER
      end

      # Per-key in-process Mutex registry for the degraded fallback
      # path. The first acquisition for a given key creates the
      # Mutex; subsequent acquisitions reuse it. Registry itself is
      # guarded by a tiny outer Mutex so two threads racing the
      # first acquisition of the same key get the same Mutex.
      #
      # @param key [String] cache key.
      # @return [Mutex]
      def process_mutex(key)
        @process_mutex_registry_lock ||= Mutex.new
        @process_mutex_registry_lock.synchronize do
          @process_mutex_registry ||= {}
          @process_mutex_registry[key] ||= Mutex.new
        end
      end

      # @return [Float] CLOCK_MONOTONIC seconds.
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Reset backend-owned state. Intended for test teardown —
      # production code should never call this.
      #
      # @return [void]
      def reset!
        @degraded_warned_at = nil
        @process_mutex_registry = nil
        @process_mutex_registry_lock = nil
      end

      private

      # Walk the Moneta transformer chain to the bottom adapter so
      # {.degraded_store?} can name-check the adapter class.
      def walk_to_adapter(store)
        current = store
        while current.respond_to?(:adapter) && current.adapter && current.adapter != current
          current = current.adapter
        end
        current
      end
    end
  end
end
