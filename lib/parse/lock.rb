# encoding: UTF-8
# frozen_string_literal: true

require "securerandom"
require "digest"
require_relative "lock_backend"

module Parse
  # Public mutual-exclusion primitive built on the same Redis-backed
  # store + in-process Mutex fallback used internally by
  # `first_or_create!` and `create_or_update!`. Designed for callers
  # who need a distributed lock outside the find-or-create flow —
  # bulk-import dedup, cron-job singletons, idempotency keys for
  # external API integrations, anywhere two processes might race the
  # same logical operation.
  #
  # == Contract
  #
  # * **TTL-bounded.** Every acquisition writes a TTL on the Redis key
  #   (1..30s, default 3s). If the holder crashes or the process is
  #   terminated mid-block, the lock self-clears after `ttl:` seconds
  #   — there is no manual recovery step. The block-form API releases
  #   on normal return, on exception, and on `return`/`break`/`raise`
  #   exiting the block (via `ensure`).
  # * **In-process Mutex fallback when Redis unavailable.** If the
  #   configured cache is process-local (Moneta `Memory` / `Null`) or
  #   nil, this falls back to a per-key `Mutex` keyed in this process.
  #   That guards single-process contention but does NOT serialize
  #   across processes — operators running multi-worker deployments
  #   should configure a Redis-backed cache for the locking to
  #   actually serve its purpose. The fallback emits a one-line warn
  #   on first use per process (throttle via `on_degraded: :warn_throttled`).
  # * **Fails closed on acquisition errors.** Errors raised by the
  #   underlying store during `SETNX`-style acquisition are caught,
  #   warned, and treated as "lock not acquired" — `acquire` will keep
  #   polling until the `wait:` budget elapses, then raise
  #   {Parse::Lock::TimeoutError}. The block is NEVER entered without
  #   the lock; there is no "best-effort proceed without locking"
  #   escape hatch.
  # * **TTL/wait clamps.** `ttl:` is clamped to 1..30s; `wait:` is
  #   clamped to 0.0..30s. Callers asking for longer windows are
  #   silently capped (the underlying store cannot reliably hold a
  #   minutes-long lock under typical Redis maxmemory eviction
  #   policies; documented in the operator guide).
  #
  # == Cooperation with `first_or_create!`
  #
  # Both APIs talk to the same store under the same namespace
  # (`parse-stack:foc:v1:<digest>` for `first_or_create!`,
  # `parse-stack:lock:v1:<your-key>` for {Parse::Lock}). The prefix
  # difference ensures the two namespaces cannot collide — a
  # {Parse::Lock.acquire(key: "billing-cycle-2026-Q4")} cannot block
  # a `first_or_create!` for the literally-equal-named row.
  #
  # @example bulk-import dedup
  #   Parse::Lock.acquire("import:#{batch_id}", ttl: 10) do
  #     # Only one worker runs the import for this batch; the rest
  #     # either get LockTimeoutError or see the already-imported state.
  #     run_batch_import(batch_id)
  #   end
  #
  # @example cron singleton
  #   Parse::Lock.acquire("cron:nightly-rollup", ttl: 5, wait: 0) do
  #     # wait: 0 → either acquire immediately or raise. Other workers
  #     # discover "someone else has it" without spinning.
  #     compute_nightly_rollup
  #   end
  #
  # @example external-API idempotency key
  #   Parse::Lock.acquire("stripe-webhook:#{evt_id}", ttl: 30, wait: 0.5) do
  #     # Two webhook deliveries with the same evt_id can't double-charge.
  #     process_webhook(evt_id)
  #   end
  module Lock
    KEY_PREFIX = "parse-stack:lock:v1:"

    DEFAULT_TTL  = 3
    DEFAULT_WAIT = 2.0
    MAX_TTL      = 30
    MAX_WAIT     = 30

    # Raised when {Parse::Lock.acquire} cannot obtain the lock within
    # the configured `wait:` budget. Distinct from
    # `Parse::CreateLockTimeoutError` (the `first_or_create!` /
    # `create_or_update!` internal) so callers can `rescue` one
    # without picking up the other — namespacing the error under
    # `Parse::Lock::` makes the peer-not-base relationship explicit.
    class TimeoutError < Parse::Error; end

    # Raised when {Parse::Lock.acquire} is asked to use a degraded
    # (process-local) store with `on_degraded: :raise`. The default
    # behavior is to fall back to an in-process Mutex with a
    # warning; this error only fires when the caller explicitly
    # opts into the strict mode.
    class UnavailableError < Parse::Error; end

    class << self
      # Acquire `key`, run the block, release on return. Block-form
      # only — there is no `try_acquire` returning a token (the
      # token-based form makes ensure-release the caller's job, and
      # any caller forgetting `ensure release(token)` leaks the key
      # for `ttl:` seconds before TTL expiry. Block-form is the safe
      # default; if you need finer control, build it locally.)
      #
      # @param key [String] a stable identifier for the resource being
      #   guarded. Hashed with SHA-256 before hitting the store so the
      #   raw caller-supplied String does not appear verbatim in
      #   `KEYS *` output. **This is obfuscation, not authentication**
      #   — an attacker with `KEYS *` access who knows the input space
      #   (e.g. "this app uses stripe-webhook:<evt_id>" keys with
      #   guessable `evt_id` prefixes) can recover the original via
      #   wordlist. For unguessable inputs (UUIDs, opaque opaque
      #   tokens) the SHA is effectively non-reversible; for
      #   semi-structured inputs (`tenant_<id>:order_<id>`) treat
      #   `KEYS *` access as equivalent to read access on the input
      #   space itself. Must be a non-empty String of at most 1024
      #   bytes — longer keys are refused (a runaway-string bug that
      #   turned into a multi-megabyte key would silently break Redis
      #   perf).
      # @param ttl [Integer] seconds the lock is held before
      #   self-clearing. Clamped to 1..30. Pick a value comfortably
      #   longer than your expected critical-section duration; the
      #   TTL is a crash-recovery floor, not a hard cap on work.
      # @param wait [Float] seconds to wait for the lock if another
      #   holder has it. Clamped to 0.0..30. Pass 0 to fail-fast
      #   (raise LockTimeoutError immediately if contended).
      # @param on_degraded [Symbol] action when the store is
      #   process-local: `:warn` (default — one warning per call),
      #   `:warn_throttled` (one warning per minute), `:proceed`
      #   (silent), `:raise` (raise Parse::Lock::UnavailableError).
      # @yield runs the block with the lock held.
      # @return [Object] the block's return value.
      # @raise [ArgumentError] on invalid `key` / `ttl` / `wait` /
      #   `on_degraded`.
      # @raise [Parse::Lock::TimeoutError] when `wait` elapses without
      #   acquisition.
      # @raise [Parse::Lock::UnavailableError] when `on_degraded: :raise`
      #   and the store is process-local.
      def acquire(key, ttl: DEFAULT_TTL, wait: DEFAULT_WAIT,
                  on_degraded: :warn, &block)
        raise ArgumentError, "block required" unless block_given?
        validated_key = validate_key!(key)
        validate_on_degraded!(on_degraded)
        normalized_ttl  = clamp(Integer(ttl),  1,   MAX_TTL)
        normalized_wait = clamp(Float(wait),   0.0, MAX_WAIT)

        # Route through Parse::LockBackend — the shared module that
        # also serves Parse::CreateLock. The KEY_PREFIX
        # ("parse-stack:lock:v1:") is distinct from CreateLock's
        # ("parse-stack:foc:v1:") so the two namespaces cannot
        # collide even on literally-equal-named keys.
        store_key = "#{KEY_PREFIX}#{Digest::SHA256.hexdigest(validated_key)}"
        store     = Parse::LockBackend.lock_store

        if Parse::LockBackend.degraded_store?(store)
          Parse::LockBackend.handle_degraded(
            on_degraded, store_key,
            source: "Parse::Lock",
            unavailable_error: Parse::Lock::UnavailableError,
          )
          return Parse::LockBackend.process_mutex(store_key).synchronize(&block)
        end

        owner       = SecureRandom.uuid
        acquired_at = nil
        start       = Parse::LockBackend.monotonic_now

        loop do
          if Parse::LockBackend.try_acquire(store, store_key, owner, normalized_ttl)
            acquired_at = Parse::LockBackend.monotonic_now
            break
          end
          elapsed = Parse::LockBackend.monotonic_now - start
          if elapsed >= normalized_wait
            raise Parse::Lock::TimeoutError,
                  "Parse::Lock.acquire: could not acquire #{key.inspect} within #{normalized_wait}s"
          end
          sleep(Parse::LockBackend.poll_interval)
        end

        begin
          yield
        ensure
          if acquired_at
            Parse::LockBackend.release(store, store_key, owner)
          end
        end
      end

      # @!visibility private
      # Reset internal state — intended for test teardown.
      def reset!
        Parse::LockBackend.reset!
      end

      private

      VALID_ON_DEGRADED = %i[warn warn_throttled proceed raise].freeze

      def validate_on_degraded!(value)
        return if VALID_ON_DEGRADED.include?(value)
        raise ArgumentError,
              "Parse::Lock.acquire: on_degraded must be one of " \
              "#{VALID_ON_DEGRADED.inspect} (got #{value.inspect}). " \
              "Refusing to silently fall back to :warn on an unknown safety knob — " \
              "a typo like :riase would otherwise become silent-warn and mask intent."
      end

      def validate_key!(key)
        unless key.is_a?(String) && !key.empty?
          raise ArgumentError,
                "Parse::Lock.acquire: key must be a non-empty String (got #{key.class})"
        end
        if key.bytesize > 1024
          raise ArgumentError,
                "Parse::Lock.acquire: key exceeds 1024 bytes (got #{key.bytesize}). " \
                "Hash the inputs to a stable digest before passing them in."
        end
        key
      end

      def clamp(value, lo, hi)
        [lo, value, hi].sort[1]
      end
    end
  end
end
