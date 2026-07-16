# encoding: UTF-8
# frozen_string_literal: true

require "monitor"
require "securerandom"

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

    # Upper bound on the in-process Mutex registry (degraded fallback
    # path). Without a cap, every distinct lock key leaks a permanent
    # Mutex — a memory-exhaustion vector when keys are high-cardinality
    # or attacker-influenced. Real deployments use a handful of lock
    # keys, so this ceiling is far above normal use and only bites a
    # runaway/abusive caller.
    PROCESS_MUTEX_REGISTRY_MAX = 4096

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
        # Prefer the store's native atomic lock primitive when it exposes
        # one (Parse::Cache::Redis). That path uses raw-Redis
        # `SET key owner NX EX ttl` with plain-string encoding so it pairs
        # with the atomic compare-and-delete in {.release}. Falls back to
        # Moneta `:create` (also an atomic SETNX) for raw-Moneta stores.
        return store.lock_acquire(key, owner, ttl) if store.respond_to?(:lock_acquire)

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

      # Compare-and-delete release. When the store exposes an atomic
      # primitive (Parse::Cache::Redis → server-side Lua CAD), use it so
      # a holder whose lease expired and was re-acquired by someone else
      # can never delete the new holder's key. Falls back to a
      # best-effort GET-then-DEL for raw-Moneta stores, where the
      # worst-case cross-holder-delete race is bounded by the short TTL
      # (callers clamp `ttl:` to ≤ 30s) — documented residual risk for
      # the non-Redis path.
      #
      # @param store [Object] Moneta-shaped store.
      # @param key [String] cache key.
      # @param owner [String] the owner token from {.try_acquire}.
      def release(store, key, owner)
        return store.lock_release(key, owner) if store.respond_to?(:lock_release)

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

      # Run `block` while holding the per-key in-process Mutex for the
      # degraded fallback path, safe against registry eviction. This is
      # the API callers should use — NOT the bare {.process_mutex}
      # accessor.
      #
      # {.process_mutex} returns an *unlocked* Mutex; there is a window
      # between the accessor returning and the caller reaching
      # `Mutex#synchronize`. Under registry saturation the approximate-LRU
      # eviction could observe that Mutex as unlocked and reclaim it, after
      # which a second caller mints a DISTINCT Mutex for the same key —
      # splitting mutual exclusion. This method closes the window by
      # registering the caller as a *pending acquirer* inside the same
      # critical section that hands out the Mutex, and eviction never
      # reclaims a key with pending acquirers (or a locked Mutex).
      #
      # @param key [String] cache key.
      # @yield executed while holding the per-key Mutex.
      # @return the block's return value.
      def synchronize_process_mutex(key, &block)
        mutex = checkout_process_mutex(key)
        begin
          mutex.synchronize(&block)
        ensure
          checkin_process_mutex(key)
        end
      end

      # Per-key in-process Mutex registry for the degraded fallback
      # path. The first acquisition for a given key creates the
      # Mutex; subsequent acquisitions reuse it. Registry itself is
      # guarded by a tiny outer Mutex so two threads racing the
      # first acquisition of the same key get the same Mutex.
      #
      # The registry is bounded at {PROCESS_MUTEX_REGISTRY_MAX} entries
      # via approximate-LRU eviction: reused keys move to the MRU end,
      # and when a new key would overflow the cap the oldest evictable
      # mutexes are dropped first. A Mutex is evictable only when it is
      # neither locked NOR reserved by a pending acquirer (see
      # {.synchronize_process_mutex}); dropping either would let a
      # concurrent acquisition mint a fresh Mutex for the same key and
      # split mutual exclusion. Under pathological all-in-use saturation
      # the registry may briefly exceed the cap rather than break
      # correctness.
      #
      # NOTE: a Mutex handed back here is eligible for eviction until it is
      # locked. Callers that lock it later (rather than immediately) must
      # go through {.synchronize_process_mutex}, which reserves the key.
      #
      # @param key [String] cache key.
      # @return [Mutex]
      def process_mutex(key)
        @process_mutex_registry_lock ||= Mutex.new
        @process_mutex_registry_lock.synchronize { registry_get_or_create(key) }
      end

      # @api private
      # Atomically get-or-create the per-key Mutex AND reserve it for the
      # caller (pending-acquirer count += 1) so eviction cannot reclaim it
      # before the caller locks it. MUST be balanced by
      # {.checkin_process_mutex} in an `ensure`.
      #
      # @param key [String] cache key.
      # @return [Mutex]
      def checkout_process_mutex(key)
        @process_mutex_registry_lock ||= Mutex.new
        @process_mutex_registry_lock.synchronize do
          mutex = registry_get_or_create(key)
          pending = (@process_mutex_pending ||= Hash.new(0))
          pending[key] += 1
          mutex
        end
      end

      # @api private
      # Release a pending-acquirer reservation taken by
      # {.checkout_process_mutex}.
      #
      # @param key [String] cache key.
      # @return [void]
      def checkin_process_mutex(key)
        @process_mutex_registry_lock ||= Mutex.new
        @process_mutex_registry_lock.synchronize do
          pending = (@process_mutex_pending ||= Hash.new(0))
          if pending.key?(key)
            pending[key] -= 1
            pending.delete(key) if pending[key] <= 0
          end
        end
      end

      # @api private
      # Get-or-create + approximate-LRU eviction. MUST be called with
      # `@process_mutex_registry_lock` already held (all three public
      # entry points synchronize on it before calling in).
      #
      # @param key [String] cache key.
      # @return [Mutex]
      def registry_get_or_create(key)
        reg = (@process_mutex_registry ||= {})

        if (existing = reg[key])
          # Move to the MRU end so the eviction scan treats it as
          # recently used (Ruby Hashes preserve insertion order).
          reg.delete(key)
          reg[key] = existing
          return existing
        end

        if reg.size >= PROCESS_MUTEX_REGISTRY_MAX
          pending = (@process_mutex_pending ||= Hash.new(0))
          reg.keys.each do |k|
            break if reg.size < PROCESS_MUTEX_REGISTRY_MAX
            m = reg[k]
            # Evict only Mutexes that are neither locked nor reserved by a
            # pending acquirer — either state means a caller is (about to
            # be) inside it, and reclaiming would split mutual exclusion.
            reg.delete(k) unless m.locked? || pending[k] > 0
          end
        end

        reg[key] = Mutex.new
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
        @process_mutex_pending = nil
        @auto_secret = nil
        @plain_sha_warned = nil
      end

      # =====================================================================
      # HMAC secret resolution (v5.1.0 — extracted from Parse::CreateLock so
      # Parse::Lock can also derive HMAC-keyed cache keys when an operator-
      # configured secret is available)
      # =====================================================================

      # Resolve the HMAC secret for lock-key derivation. Behavior depends
      # on store type:
      #
      # * **Configured secret present** — returned verbatim (operator
      #   set `Parse.synchronize_create_secret` or
      #   `PARSE_STACK_LOCK_SECRET`).
      # * **Degraded (process-local) store, no configured secret** —
      #   returns the per-process auto-derived random secret. Locking
      #   is already process-local in this branch, so a per-process
      #   secret is fine and improves test/single-process privacy by
      #   preventing `KEYS *` enumeration.
      # * **Cross-process store, no configured secret** — returns `nil`
      #   with a one-time warn. Per-process auto-derived secrets would
      #   break cross-process key equality (and therefore the lock
      #   itself), so the caller falls back to plain SHA-256 and gets a
      #   loud nudge to configure a real secret.
      #
      # @param store [Object, nil] the lock store (used only for
      #   degraded detection).
      # @param source [String] caller tag for the warn-once message —
      #   "Parse::CreateLock" or "Parse::Lock".
      # @return [String, nil] the secret, or nil to indicate plain SHA.
      def lock_secret_for(store:, source: "Parse::LockBackend")
        configured = configured_secret
        return configured if configured && !configured.empty?
        if degraded_store?(store)
          auto_secret
        else
          warn_plain_sha_once(source: source)
          nil
        end
      end

      # @return [String, nil] operator-configured HMAC secret from
      #   `Parse.synchronize_create_secret` or
      #   `PARSE_STACK_LOCK_SECRET`. The env-var and accessor names
      #   carry "synchronize_create" / "LOCK" historical naming;
      #   both `Parse::CreateLock` and `Parse::Lock` consume the same
      #   value.
      def configured_secret
        if Parse.respond_to?(:synchronize_create_secret) && Parse.synchronize_create_secret
          return Parse.synchronize_create_secret.to_s
        end
        ENV["PARSE_STACK_LOCK_SECRET"]
      end

      # @return [String] per-process random secret. Memoized.
      def auto_secret
        @auto_secret ||= SecureRandom.hex(32)
      end

      # One-time process-scoped warn when a cross-process lock store
      # is in use without an operator-configured HMAC secret. The
      # warning text explains both the enumeration risk (key material
      # is deterministic) and the lock-pinning risk (when the cache
      # and lock store share a Redis DB) and points at the
      # remediation knobs.
      def warn_plain_sha_once(source:)
        return if @plain_sha_warned
        @plain_sha_warned = true
        warn "[#{source}:SECURITY] No PARSE_STACK_LOCK_SECRET configured and Redis-backed store detected. " \
             "Falling back to plain SHA256 for lock-key derivation so cross-process locking actually works. " \
             "Risks of running without an HMAC secret: (1) lock keys are deterministic and may expose key " \
             "material content via Redis MONITOR/snapshots; (2) when the response cache and the lock store " \
             "share a Redis DB, any caller with write access to Parse.cache can plant a lock key under a " \
             "guessable digest and pin the lock for that resource until TTL expiry — a targeted DoS / " \
             "lock-pinning primitive. Set PARSE_STACK_LOCK_SECRET (or Parse.synchronize_create_secret = '…') " \
             "to enable HMAC keying, or point Parse.synchronize_create_store at a separate Redis DB from " \
             "the response cache."
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
