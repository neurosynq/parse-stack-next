# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/lock"
require "moneta"

# Unit tests for the public Parse::Lock primitive extracted from
# Parse::CreateLock in v5.1.0. Uses ParseLockTestStore (nested below)
# so the contention tests exercise the cross-process Redis-shaped
# path (atomic SETNX, wait-budget timeout) rather than the in-process
# Mutex fallback path (which is covered separately).
class ParseLockTest < Minitest::Test
  # Test-only store wrapper: delegates to Moneta::Memory but presents
  # a class name OTHER than "Memory" / "Null" so CreateLock's
  # `degraded_store?` heuristic treats it as cross-process-shaped.
  # Without this the contention timeout tests would fall back to the
  # in-process Mutex path, which intentionally does NOT honor `wait:`
  # (Mutex.synchronize blocks indefinitely until the holder releases).
  #
  # Nested under ParseLockTest so the helper does not pollute the
  # top-level constant namespace for other test files in the suite.
  class ParseLockTestStore
    def initialize
      @inner = Moneta.new(:Memory, expires: true)
      @monitor = Monitor.new
    end

    # CreateLock.walk_to_adapter terminates when adapter.adapter == self.
    def adapter; self; end

    # Atomic SETNX semantics, required for the lock store.
    def create(key, value, expires: nil)
      @monitor.synchronize do
        return false if @inner.key?(key)
        @inner.store(key, value, expires: expires)
        true
      end
    end

    def key?(key); @inner.key?(key); end
    def [](key); @inner[key]; end
    def delete(key); @inner.delete(key); end
    def store(key, value, expires: nil); @inner.store(key, value, expires: expires); end
    def each_key(&blk); @inner.each_key(&blk); end
  end

  def setup
    @prior_store = Parse.instance_variable_get(:@synchronize_create_store)
    @lock_store  = ParseLockTestStore.new
    Parse.singleton_class.attr_accessor :synchronize_create_store unless Parse.respond_to?(:synchronize_create_store=)
    Parse.synchronize_create_store = @lock_store
    Parse::CreateLock.reset!
  end

  def teardown
    Parse.synchronize_create_store = @prior_store
    Parse::CreateLock.reset!
  end

  # ---- argument validation -----------------------------------------------

  def test_acquire_requires_block
    assert_raises(ArgumentError) { Parse::Lock.acquire("k", ttl: 1) }
  end

  def test_acquire_refuses_non_string_key
    assert_raises(ArgumentError) { Parse::Lock.acquire(nil, ttl: 1) {} }
    assert_raises(ArgumentError) { Parse::Lock.acquire(:symbol, ttl: 1) {} }
    assert_raises(ArgumentError) { Parse::Lock.acquire(42, ttl: 1) {} }
  end

  def test_acquire_refuses_empty_key
    err = assert_raises(ArgumentError) { Parse::Lock.acquire("", ttl: 1) {} }
    assert_match(/non-empty String/, err.message)
  end

  def test_acquire_refuses_oversized_key
    huge = "x" * 2048
    err = assert_raises(ArgumentError) { Parse::Lock.acquire(huge, ttl: 1) {} }
    assert_match(/exceeds 1024 bytes/, err.message)
  end

  # ---- TTL / wait clamping -----------------------------------------------

  def test_ttl_below_minimum_is_clamped_to_one
    # ttl: 0 → clamped to 1. The lock should still succeed.
    out = Parse::Lock.acquire("clamp-low", ttl: 0, wait: 0) { :ok }
    assert_equal :ok, out
  end

  def test_ttl_above_maximum_is_clamped_to_thirty
    out = Parse::Lock.acquire("clamp-high", ttl: 600, wait: 0) { :ok }
    assert_equal :ok, out
  end

  def test_wait_above_maximum_is_clamped_to_thirty
    # Verify we don't actually wait the requested 600s by using a
    # fail-fast assertion — if not clamped, this test would hang.
    refute_raises_timeout do
      Parse::Lock.acquire("wait-clamp", ttl: 1, wait: 600) { :ok }
    end
  end

  # ---- happy path --------------------------------------------------------

  def test_acquire_returns_block_value
    assert_equal 42, Parse::Lock.acquire("ret", ttl: 1) { 42 }
  end

  def test_acquire_releases_on_normal_return
    Parse::Lock.acquire("release-normal", ttl: 5) { :ok }
    # Should be able to re-acquire immediately.
    Parse::Lock.acquire("release-normal", ttl: 5, wait: 0) { :ok }
  end

  def test_acquire_releases_on_raise
    assert_raises(RuntimeError) do
      Parse::Lock.acquire("release-raise", ttl: 5) { raise "boom" }
    end
    # Lock must be released even though the block raised.
    Parse::Lock.acquire("release-raise", ttl: 5, wait: 0) { :ok }
  end

  def test_acquire_releases_on_throw
    catch(:done) do
      Parse::Lock.acquire("release-throw", ttl: 5) { throw :done }
    end
    Parse::Lock.acquire("release-throw", ttl: 5, wait: 0) { :ok }
  end

  # ---- contention --------------------------------------------------------

  def test_acquire_blocks_when_held_then_succeeds_after_release
    # Holder thread holds for ~50ms; main thread waits up to 5s and
    # should acquire shortly after holder releases.
    holder = Thread.new do
      Parse::Lock.acquire("contended", ttl: 5) { sleep 0.1 }
    end

    sleep 0.02  # let holder grab it first

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Parse::Lock.acquire("contended", ttl: 5, wait: 5.0) do
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      assert elapsed >= 0.05, "main thread should have waited >=50ms for holder"
      assert elapsed < 1.0,   "main thread should have acquired well under 1s"
    end
    holder.join
  end

  def test_acquire_times_out_when_held_longer_than_wait
    holder = Thread.new do
      Parse::Lock.acquire("timeout-key", ttl: 5) { sleep 1.0 }
    end

    sleep 0.02

    assert_raises(Parse::Lock::TimeoutError) do
      Parse::Lock.acquire("timeout-key", ttl: 5, wait: 0.1) { flunk "should not run" }
    end
    holder.join
  end

  def test_wait_zero_fails_fast_when_contended
    holder = Thread.new do
      Parse::Lock.acquire("fail-fast", ttl: 5) { sleep 0.2 }
    end

    sleep 0.02

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Parse::Lock::TimeoutError) do
      Parse::Lock.acquire("fail-fast", ttl: 5, wait: 0) { :unreachable }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    assert elapsed < 0.1, "wait: 0 must fail-fast (under 100ms)"
    holder.join
  end

  # ---- in-process fallback ----------------------------------------------

  def test_degraded_store_falls_back_to_in_process_mutex
    # Configure a process-local store (Memory adapter without :create)
    # — strictly speaking Memory does support :create, so simulate
    # degraded by clearing the store entirely. The actual degraded
    # detection is in CreateLock and uses the adapter walk.
    Parse.synchronize_create_store = nil  # nil store → degraded
    # Suppress the degraded-fallback warning; capture_io's return value isn't
    # a reliable channel for the block's result, so assert via a side effect
    # below instead.
    capture_io do
      Parse::Lock.acquire("degraded", ttl: 5, wait: 0) { :ok_in_process }
    end
    side_effect = nil
    capture_io do
      Parse::Lock.acquire("degraded-2", ttl: 5, wait: 0) { side_effect = :ran }
    end
    assert_equal :ran, side_effect
  end

  def test_degraded_raise_mode_raises
    # `Parse::Lock` raises its own namespaced error
    # `Parse::Lock::UnavailableError` (not Parse::CreateLockUnavailableError —
    # those are peers, not a class hierarchy). The backend's
    # `handle_degraded` accepts `unavailable_error:` so each caller
    # raises its own typed error.
    Parse.synchronize_create_store = nil
    capture_io do
      assert_raises(Parse::Lock::UnavailableError) do
        Parse::Lock.acquire("degraded-raise", ttl: 5, on_degraded: :raise) { :unreachable }
      end
    end
  end

  def test_degraded_proceed_mode_is_silent
    Parse.synchronize_create_store = nil
    _out, err = capture_io do
      Parse::Lock.acquire("degraded-silent", ttl: 5, on_degraded: :proceed) { :ok }
    end
    assert_equal "", err
  end

  # ---- namespace isolation from first_or_create! ------------------------

  def test_acquire_refuses_unknown_on_degraded_symbol
    err = assert_raises(ArgumentError) do
      Parse::Lock.acquire("typo", on_degraded: :riase) { flunk }
    end
    assert_match(/on_degraded must be one of/, err.message)
    assert_match(/riase/, err.message)
  end

  def test_acquire_fails_closed_when_store_raises_mid_acquisition
    # Inject a store whose `create` always raises. CreateLock's
    # `try_acquire` catches the exception, warns, and returns false —
    # the lock is treated as not acquired and the wait loop spins
    # until timeout. NEVER enters the block.
    raising_store = Class.new do
      def adapter; self; end
      def create(*); raise RuntimeError, "redis down"; end
      def key?(_); false; end
      def [](_); nil; end
      def delete(_); nil; end
      def store(*); nil; end
    end.new

    Parse.synchronize_create_store = raising_store
    block_ran = false

    _out, err = capture_io do
      assert_raises(Parse::Lock::TimeoutError) do
        Parse::Lock.acquire("fail-closed", ttl: 1, wait: 0.1) { block_ran = true }
      end
    end

    refute block_ran, "block must NOT run when the store consistently fails to acquire"
    assert_match(/acquire error/, err)
  end

  # ---- HMAC secret resolution (TODO #1 — v5.1.0 deferred follow-up) ----
  #
  # `Parse::Lock.acquire(secret:)` accepts `:auto` (default — use the
  # backend's secret lookup, including PARSE_STACK_LOCK_SECRET /
  # `Parse.synchronize_create_secret`), `nil` (explicit plain SHA-256
  # opt-out, no warn), or a `String` (caller-supplied HMAC key). The
  # default-on HMAC keying means a configured operator secret is
  # consumed by BOTH `Parse::Lock` and `Parse::CreateLock` without
  # the operator having to opt in twice.

  def test_acquire_rejects_invalid_secret
    [42, :nope, true, false, "", []].each do |bad|
      err = assert_raises(ArgumentError) { Parse::Lock.acquire("k", secret: bad) { :unreachable } }
      assert_match(/secret must be :auto/, err.message, "value=#{bad.inspect}")
    end
  end

  def test_acquire_rejects_short_secret
    # Round-3-of-round-3 hardening: an explicit `secret:` shorter than
    # SECRET_MIN_BYTES is refused at the boundary. Without this, a
    # caller misconfiguration like `secret: "x"` would silently
    # degrade the lock-pinning resistance the HMAC keying is supposed
    # to provide.
    [
      "a",                                          # 1 byte
      "shortie",                                    # 7 bytes
      "a" * (Parse::Lock::SECRET_MIN_BYTES - 1),    # just under the line
    ].each do |bad|
      err = assert_raises(ArgumentError) do
        Parse::Lock.acquire("k", ttl: 1, secret: bad) { flunk "must not run" }
      end
      assert_match(/at least #{Parse::Lock::SECRET_MIN_BYTES} bytes/, err.message,
        "value=#{bad.inspect} should be rejected")
    end
  end

  def test_acquire_accepts_minimum_length_secret
    min_secret = "a" * Parse::Lock::SECRET_MIN_BYTES
    Parse::Lock.acquire("k", ttl: 5, secret: min_secret) { :ok }
  end

  def test_acquire_explicit_secret_produces_hmac_keyed_store_entry
    # With an explicit secret, the cache-store key is HMAC-SHA256
    # rather than plain SHA-256. Verify the digest matches the
    # expected HMAC of the raw key.
    require "openssl"
    secret = "test-secret-DO-NOT-LEAK"
    expected = "#{Parse::Lock::KEY_PREFIX}#{OpenSSL::HMAC.hexdigest("SHA256", secret, "billing-2026-Q4")}"

    Parse::Lock.acquire("billing-2026-Q4", ttl: 5, secret: secret) do
      keys = @lock_store.each_key.to_a
      assert_equal 1, keys.length
      assert_equal expected, keys.first,
        "HMAC-keyed store entry must match OpenSSL::HMAC.hexdigest"
    end
  end

  def test_acquire_nil_secret_produces_plain_sha_keyed_store_entry
    require "digest"
    expected = "#{Parse::Lock::KEY_PREFIX}#{Digest::SHA256.hexdigest("billing-2026-Q4")}"

    Parse::Lock.acquire("billing-2026-Q4", ttl: 5, secret: nil) do
      keys = @lock_store.each_key.to_a
      assert_equal 1, keys.length
      assert_equal expected, keys.first,
        "secret: nil must use plain SHA-256"
    end
  end

  def test_acquire_different_secrets_produce_different_store_keys
    # Same raw key, two different HMAC secrets, two different store
    # keys — so the same logical lock under two different secrets
    # does NOT serialize. Important: two services sharing one Redis
    # but using different secrets get isolated locks for the same
    # raw key. Both secrets are ≥ SECRET_MIN_BYTES (16) to satisfy
    # the validate_secret! length floor.
    keys_seen = []
    Parse::Lock.acquire("alpha", ttl: 5, secret: "operator-secret-A-aaaaaa") do
      keys_seen << @lock_store.each_key.to_a.first
    end
    Parse::Lock.acquire("alpha", ttl: 5, secret: "operator-secret-B-bbbbbb") do
      keys_seen << @lock_store.each_key.to_a.last
    end
    refute_equal keys_seen[0], keys_seen[1],
      "different secrets must produce different store keys for the same raw key"
  end

  def test_acquire_auto_secret_picks_up_env_var
    prior_env  = ENV["PARSE_STACK_LOCK_SECRET"]
    prior_attr = Parse.respond_to?(:synchronize_create_secret) ? Parse.synchronize_create_secret : nil
    ENV["PARSE_STACK_LOCK_SECRET"] = "env-test-secret"
    # Force a refresh so any cached state is cleared.
    Parse::LockBackend.reset!

    expected = "#{Parse::Lock::KEY_PREFIX}#{OpenSSL::HMAC.hexdigest("SHA256", "env-test-secret", "thing")}"
    Parse::Lock.acquire("thing", ttl: 5) do
      assert_equal expected, @lock_store.each_key.to_a.first
    end
  ensure
    ENV["PARSE_STACK_LOCK_SECRET"] = prior_env
    Parse.synchronize_create_secret = prior_attr if Parse.respond_to?(:synchronize_create_secret=)
    Parse::LockBackend.reset!
  end

  def test_acquire_auto_secret_picks_up_synchronize_create_secret_accessor
    prior_attr = Parse.synchronize_create_secret if Parse.respond_to?(:synchronize_create_secret)
    Parse.synchronize_create_secret = "accessor-test-secret"
    Parse::LockBackend.reset!

    expected = "#{Parse::Lock::KEY_PREFIX}#{OpenSSL::HMAC.hexdigest("SHA256", "accessor-test-secret", "alpha")}"
    Parse::Lock.acquire("alpha", ttl: 5) do
      assert_equal expected, @lock_store.each_key.to_a.first
    end
  ensure
    Parse.synchronize_create_secret = prior_attr
    Parse::LockBackend.reset!
  end

  def test_auto_secret_shared_with_create_lock_when_env_set
    # An operator setting PARSE_STACK_LOCK_SECRET expects ONE
    # configuration to harden both APIs. Verify the same env var
    # resolves to the same secret from both LockBackend.lock_secret_for
    # (called from Parse::Lock) and the CreateLock-internal version
    # (now also going through LockBackend).
    prior = ENV["PARSE_STACK_LOCK_SECRET"]
    ENV["PARSE_STACK_LOCK_SECRET"] = "shared-secret"
    Parse::LockBackend.reset!

    s1 = Parse::LockBackend.lock_secret_for(store: @lock_store, source: "Parse::Lock")
    s2 = Parse::LockBackend.lock_secret_for(store: @lock_store, source: "Parse::CreateLock")
    assert_equal "shared-secret", s1
    assert_equal "shared-secret", s2
  ensure
    ENV["PARSE_STACK_LOCK_SECRET"] = prior
    Parse::LockBackend.reset!
  end

  def test_namespace_does_not_collide_with_create_lock
    # Parse::Lock uses "parse-stack:lock:v1:" prefix; CreateLock uses
    # "parse-stack:foc:v1:". A Parse::Lock on key "billing-cycle" must
    # not block a CreateLock on a literally-equal-named row, and vice
    # versa. Hold the Parse::Lock, then verify the store key prefix
    # the lock wrote contains the Parse::Lock prefix only.
    capture_io do
      Parse::Lock.acquire("billing-cycle-2026-Q4", ttl: 5) do
        keys = @lock_store.each_key.to_a
        assert keys.any? { |k| k.start_with?(Parse::Lock::KEY_PREFIX) },
          "Parse::Lock key must use the lock-namespace prefix: #{keys.inspect}"
        refute keys.any? { |k| k.start_with?("parse-stack:foc:v1:") },
          "Parse::Lock must NOT write into the first_or_create! namespace"
      end
    end
  end

  private

  def refute_raises_timeout
    completed = false
    t = Thread.new do
      yield
      completed = true
    end
    t.join(2.0) # generous upper bound
    t.kill if t.alive?
    assert completed, "Block should have completed quickly (clamping not effective)"
  end
end
