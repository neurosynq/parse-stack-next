# encoding: UTF-8
# frozen_string_literal: true

require "digest"
require "openssl"
require "json"
require "securerandom"
require "monitor"
require_relative "../../lock_backend"

module Parse
  # Mutual-exclusion primitive for `first_or_create!` / `create_or_update!` to
  # prevent TOCTOU duplicate creation under concurrency. Backed by a Moneta
  # cache store (typically Redis) using atomic `#create` (SETNX semantics).
  #
  # This is the *latency optimization* layer; a MongoDB unique index on the
  # constrained tuple is the correctness floor that survives Redis outages,
  # TTL expiry races, and bypassed locks. The lock here is best-effort and
  # fails open by design when the store is unreachable.
  #
  # Threading model:
  # - Process-local fallback: when the store is the in-memory Moneta adapter
  #   (or unconfigured), the lock degrades to a per-key `Mutex`. Threads in
  #   the same Ruby process serialize; cross-process callers do not. This is
  #   safe for single-Puma-process tests but does not protect production
  #   deployments with multiple dynos / workers.
  # - Cross-process: when the store is Redis-backed Moneta, `#create` is
  #   atomic and the lock excludes other processes.
  #
  # Key derivation: HMAC-SHA256 of a canonical payload when a secret is
  # configured (preferred); plain SHA256 otherwise (deterministic across
  # processes — required for Redis-backed locking — but key material is
  # enumerable via Redis MONITOR/snapshots). Operators wanting hardened key
  # material against snapshot/MONITOR exposure should set
  # `PARSE_STACK_LOCK_SECRET` or `Parse.synchronize_create_secret`.
  module CreateLock
    DEFAULT_TTL = 3
    DEFAULT_WAIT = 2.0
    DEFAULT_POLL_BASE = 0.05
    DEFAULT_POLL_JITTER = 0.015
    MAX_TTL = 30
    MAX_WAIT = 30
    MAX_PAYLOAD_BYTES = 8_192
    MAX_DEPTH = 4
    KEY_PREFIX = "parse-stack:foc:v1:"
    DEGRADED_WARNING_THROTTLE_SECONDS = 60

    class << self
      # Run `block` while holding a mutex keyed by the canonical form of
      # `parse_class + auth context + query_attrs`. Yields nothing; the
      # block's return value is returned.
      #
      # @param parse_class [String] the Parse class name
      # @param query_attrs [Hash] the query attributes used to derive the key
      # @param options [Hash] tuning: ttl:, wait:, on_degraded:
      # @param session_token [String, nil] auth context — included in key
      # @param master_key [Boolean, nil] auth context — included in key
      # @raise [Parse::CreateLockInvalidKey] if query_attrs cannot be canonicalized
      # @raise [Parse::CreateLockTimeoutError] if wait budget exceeded
      def synchronize(parse_class:, query_attrs:, options: {}, session_token: nil, master_key: nil, &block)
        raise ArgumentError, "block required" unless block_given?

        ttl = clamp(Integer(options[:ttl] || DEFAULT_TTL), 1, MAX_TTL)
        wait = clamp(Float(options[:wait] || DEFAULT_WAIT), 0.0, MAX_WAIT)
        on_degraded = options[:on_degraded] || :warn

        key = canonical_key(
          parse_class: parse_class,
          query_attrs: query_attrs,
          session_token: session_token,
          master_key: master_key,
        )

        store = LockBackend.lock_store
        if LockBackend.degraded_store?(store)
          LockBackend.handle_degraded(
            on_degraded, key,
            source: "Parse::CreateLock",
            unavailable_error: Parse::CreateLockUnavailableError,
          )
          return LockBackend.process_mutex(key).synchronize(&block)
        end

        owner = SecureRandom.uuid
        acquired_at = nil
        start = LockBackend.monotonic_now

        loop do
          if LockBackend.try_acquire(store, key, owner, ttl)
            acquired_at = LockBackend.monotonic_now
            wait_ms = ((acquired_at - start) * 1000).round
            instrument("acquired", key, wait_ms: wait_ms)
            break
          end

          elapsed = LockBackend.monotonic_now - start
          if elapsed >= wait
            waited_ms = (elapsed * 1000).round
            instrument("timeout", key, waited_ms: waited_ms)
            raise Parse::CreateLockTimeoutError,
                  "Could not acquire create-lock for #{parse_class} within #{wait}s"
          end
          instrument("contended", key, elapsed_ms: (elapsed * 1000).round) if elapsed > 0
          sleep(LockBackend.poll_interval)
        end

        begin
          yield
        ensure
          if acquired_at
            LockBackend.release(store, key, owner)
            held_ms = ((LockBackend.monotonic_now - acquired_at) * 1000).round
            instrument("released", key, held_ms: held_ms)
          end
        end
      end

      # Canonical lock key for the given inputs. Public for tests.
      # @return [String]
      def canonical_key(parse_class:, query_attrs:, session_token: nil, master_key: nil)
        principal = principal_marker(session_token, master_key)
        attrs_payload = canonicalize_attrs(query_attrs, parse_class: parse_class)
        app_id = parse_application_id
        payload = "#{app_id}|#{parse_class}|#{principal}|#{attrs_payload}"

        if payload.bytesize > MAX_PAYLOAD_BYTES
          raise Parse::CreateLockInvalidKey,
                "synchronize key payload exceeds #{MAX_PAYLOAD_BYTES} bytes (got #{payload.bytesize})"
        end

        secret = lock_secret_for(store: LockBackend.lock_store)
        digest = if secret
            OpenSSL::HMAC.hexdigest("SHA256", secret, payload)
          else
            Digest::SHA256.hexdigest(payload)
          end
        "#{KEY_PREFIX}#{digest}"
      end

      # @!visibility private
      def reset!
        @auto_secret = nil
        @plain_sha_warned = nil
        # Backend-owned state (@degraded_warned_at, @process_mutex_registry)
        # lives on Parse::LockBackend now — extracted in v5.1.0 so
        # Parse::Lock and Parse::CreateLock share one implementation.
        LockBackend.reset!
      end

      private

      def parse_application_id
        Parse.client.application_id
      rescue Parse::Error::ConnectionError
        "no-app-id"
      end

      def principal_marker(session_token, master_key)
        return "default" if session_token.nil? && master_key.nil?
        if session_token
          "st:#{Digest::SHA256.hexdigest(session_token.to_s)[0, 16]}"
        elsif master_key == true
          "mk"
        elsif master_key == false
          "no-mk"
        else
          "default"
        end
      end

      def canonicalize_attrs(query_attrs, parse_class: nil)
        raise Parse::CreateLockInvalidKey, "synchronize requires non-empty query_attrs" if query_attrs.nil? || query_attrs.empty?
        unless query_attrs.is_a?(Hash)
          raise Parse::CreateLockInvalidKey, "synchronize query_attrs must be a Hash (got #{query_attrs.class})"
        end

        seen = {}
        pairs = query_attrs.map do |k, v|
          key_str = canonicalize_key_name(k)
          if seen.key?(key_str)
            class_ctx = parse_class ? " on #{parse_class}" : ""
            raise Parse::CreateLockInvalidKey,
                  "duplicate canonical key #{key_str.inspect}#{class_ctx} in synchronize query_attrs " \
                  "(Parse::Operation has no eql?/hash override, so two instances with the " \
                  "same operand+operator are distinct Hash keys but collapse here)"
          end
          seen[key_str] = true
          [key_str, canonicalize_value(v, 0)]
        end
        sorted = pairs.sort_by(&:first).to_h
        JSON.generate(sorted)
      end

      def canonicalize_key_name(key)
        # Parse::Operation keys (e.g. :project.exists, :email.gt) encode as
        # "<operand>\u0000op_<operator>" so the lock keys the filter shape, not
        # just equality tuples. The null-byte separator is a structural marker
        # that must never appear in plain string keys (rejected below) or in
        # operand/operator names.
        if key.is_a?(Parse::Operation) || (key.respond_to?(:operator) && key.respond_to?(:operand))
          operand = key.operand.to_s
          operator = key.operator.to_s
          if operand.empty? || operator.empty? ||
             operand.include?(".") || operator.include?(".") ||
             operand.start_with?("$") || operator.start_with?("$") ||
             operand.include?("\u0000") || operator.include?("\u0000")
            raise Parse::CreateLockInvalidKey,
                  "invalid Parse::Operation key in synchronize (got #{key.inspect})"
          end
          return "#{operand}\u0000op_#{operator}"
        end
        str = key.to_s
        if str.include?(".") || str.include?("\u0000")
          raise Parse::CreateLockInvalidKey,
                "dotted or null-byte keys not allowed in synchronize (got #{key.inspect})"
        end
        str
      end

      def canonicalize_value(value, depth)
        if depth > MAX_DEPTH
          raise Parse::CreateLockInvalidKey, "synchronize values nested deeper than #{MAX_DEPTH} levels"
        end

        case value
        when nil, true, false, Integer, Float, String, Symbol
          value.is_a?(Symbol) ? value.to_s : value
        when Time, DateTime
          value.utc.iso8601(6)
        when Date
          value.iso8601
        when Array
          value.map { |v| canonicalize_value(v, depth + 1) }
        when Parse::Pointer
          if value.id.nil? || value.id.empty?
            raise Parse::CreateLockInvalidKey,
                  "unsaved Parse pointer cannot be a synchronize key component (#{value.parse_class}#nil)"
          end
          "ptr:#{value.parse_class}:#{value.id}"
        when Hash
          raise Parse::CreateLockInvalidKey,
                "nested Hash values not allowed in synchronize (would be ambiguous against query operators)"
        when Proc, Method, Regexp
          raise Parse::CreateLockInvalidKey, "#{value.class} not allowed in synchronize values"
        else
          if value.respond_to?(:to_pointer)
            ptr = value.to_pointer
            return canonicalize_value(ptr, depth + 1)
          end
          raise Parse::CreateLockInvalidKey, "unsupported type #{value.class} in synchronize values"
        end
      end

      # The store discovery, degraded detection, atomic-SETNX,
      # release semantics, poll-interval jitter, and process-mutex
      # registry all live on {Parse::LockBackend} now (v5.1.0
      # extraction). The two private helpers below — `clamp` and
      # `lock_secret_for` — are CreateLock-specific (input clamping
      # on the public API, HMAC secret resolution) and stay here.

      def clamp(value, lo, hi)
        [lo, value, hi].sort[1]
      end

      def lock_secret_for(store:)
        configured = configured_secret
        return configured if configured && !configured.empty?

        # No operator-configured secret. Behavior depends on store type:
        # - Memory/Null adapter: locking is already process-local, so a
        #   per-process auto-derived HMAC secret is fine and preserves
        #   privacy in tests / single-process deployments.
        # - Redis (or any cross-process store): a per-process secret would
        #   break cross-process key equality, defeating the lock. Fall back
        #   to plain SHA256 with a one-time warning so operators know to
        #   harden key material.
        if LockBackend.degraded_store?(store)
          auto_secret
        else
          warn_plain_sha_once
          nil
        end
      end

      def configured_secret
        if Parse.respond_to?(:synchronize_create_secret) && Parse.synchronize_create_secret
          return Parse.synchronize_create_secret.to_s
        end
        ENV["PARSE_STACK_LOCK_SECRET"]
      end

      def auto_secret
        @auto_secret ||= SecureRandom.hex(32)
      end

      def warn_plain_sha_once
        return if @plain_sha_warned
        @plain_sha_warned = true
        warn "[Parse::CreateLock:SECURITY] No PARSE_STACK_LOCK_SECRET configured and Redis-backed store detected. " \
             "Falling back to plain SHA256 for lock-key derivation so cross-process locking actually works. " \
             "Risks of running without an HMAC secret: (1) lock keys are deterministic and may expose query_attrs " \
             "content via Redis MONITOR/snapshots; (2) when the response cache and the lock store share a Redis DB, " \
             "any caller with write access to Parse.cache can plant a `parse-stack:foc:v1:<sha>` key under a guessable " \
             "digest of (app_id, class, principal, query_attrs) and suppress first_or_create!/create_or_update! for " \
             "that tuple until TTL expiry — a targeted DoS / create-pinning primitive. " \
             "Set PARSE_STACK_LOCK_SECRET (or Parse.synchronize_create_secret = '…') to enable HMAC keying, or " \
             "point Parse.synchronize_create_store at a separate Redis DB from the response cache."
      end

      def instrument(event, key, payload = {})
        return unless defined?(ActiveSupport::Notifications)
        ActiveSupport::Notifications.instrument(
          "parse.synchronize_create.#{event}",
          { key_digest: key[KEY_PREFIX.size, 12] }.merge(payload),
        )
      rescue StandardError
        # never let telemetry break the lock
      end
    end
  end
end


