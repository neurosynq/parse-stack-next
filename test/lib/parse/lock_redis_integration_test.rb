# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require "minitest/autorun"
require "moneta"
require "parse/lock"
require "openssl"
require "digest"

# Integration test for Parse::Lock against a real Redis backend.
# Pins behaviors that require cross-process semantics (and therefore
# can't be exercised with in-memory Moneta):
#
#  - HMAC-keyed acquisition produces the expected store key when an
#    operator secret is configured (PARSE_STACK_LOCK_SECRET).
#  - Two Parse::Lock instances in the same process — pointed at the
#    same Redis with the same secret — race for the same key and
#    one wins / the other waits (cross-process exclusion semantics
#    work end-to-end, not just in unit-test mocks).
#  - The block's view of Redis confirms the lock key exists between
#    acquire and release, and is gone after release.
#  - The shared secret IS shared with Parse::CreateLock —
#    configuring once gates both APIs.
#  - Two Parse::Lock instances with DIFFERENT secrets but the same
#    raw key do NOT serialize (HMAC keying isolates tenants).
class LockRedisIntegrationTest < Minitest::Test
  REDIS_URL = ENV["PARSE_TEST_REDIS_URL"] || "redis://localhost:6399/0"

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Redis not reachable at #{REDIS_URL}" unless redis_reachable?

    @probe = Moneta.new(:Redis, url: REDIS_URL, expires: true)
    @probe.clear

    @saved_store = Parse.synchronize_create_store
    @saved_secret = Parse.synchronize_create_secret
    @saved_env_secret = ENV["PARSE_STACK_LOCK_SECRET"]

    ENV["PARSE_STACK_LOCK_SECRET"] = "integration-test-secret"
    Parse.synchronize_create_secret = nil

    @wrapper = Parse::Cache::Redis.new(url: REDIS_URL, namespace: nil, pool_size: 2)
    Parse.synchronize_create_store = @wrapper
    Parse::LockBackend.reset!
  end

  def teardown
    Parse.synchronize_create_store = @saved_store
    Parse.synchronize_create_secret = @saved_secret
    if @saved_env_secret
      ENV["PARSE_STACK_LOCK_SECRET"] = @saved_env_secret
    else
      ENV.delete("PARSE_STACK_LOCK_SECRET")
    end
    Parse::LockBackend.reset!
    @probe&.clear
    @wrapper&.close
    @probe&.close
  end

  # ---- HMAC-keyed store entries against real Redis ----------------------

  def test_acquire_writes_hmac_keyed_entry_to_real_redis
    raw_key = "billing-cycle-2026-Q4-#{SecureRandom.hex(4)}"
    expected_store_key =
      "#{Parse::Lock::KEY_PREFIX}#{OpenSSL::HMAC.hexdigest("SHA256", "integration-test-secret", raw_key)}"

    observed_inside = nil
    Parse::Lock.acquire(raw_key, ttl: 5, wait: 2.0) do
      observed_inside = @probe[expected_store_key]
    end

    refute_nil observed_inside,
      "lock key must be present in Redis while the block is running"
    assert_nil @probe[expected_store_key],
      "lock key must be released (CAD) after the block exits"
  end

  def test_acquire_with_nil_secret_writes_plain_sha_key
    raw_key = "no-secret-#{SecureRandom.hex(4)}"
    expected_store_key =
      "#{Parse::Lock::KEY_PREFIX}#{Digest::SHA256.hexdigest(raw_key)}"

    observed = nil
    Parse::Lock.acquire(raw_key, ttl: 5, secret: nil) do
      observed = @probe[expected_store_key]
    end

    refute_nil observed,
      "secret: nil must produce a plain-SHA256 store entry visible at the expected key"
  end

  # ---- cross-process contention semantics on real Redis -----------------

  def test_concurrent_acquire_on_same_key_serializes
    # Two threads in the same Ruby process, but both routing through
    # the real Redis (atomic SETNX). Exercises the actual
    # cross-process exclusion code path — not a Mutex.
    #
    # Synchronization via Queue gates rather than `sleep`-based
    # ordering: the holder thread signals "I've acquired" via the
    # `acquired_signal` queue, the waiter thread blocks on that
    # before starting its own acquire attempt. The holder then
    # blocks on `release_signal` (sent by the test thread after the
    # waiter has been waiting long enough to prove contention).
    # Slow-CI flake risk: zero.
    key = "race-key-#{SecureRandom.hex(4)}"
    acquired_signal = Queue.new
    release_signal  = Queue.new
    waiter_acquired_at = nil
    waiter_acquire_start = nil

    holder = Thread.new do
      Parse::Lock.acquire(key, ttl: 5) do
        acquired_signal << :holder_inside
        release_signal.pop  # block until test thread says "ok release"
      end
    end

    # Wait deterministically for holder to acquire.
    assert_equal :holder_inside, acquired_signal.pop(timeout: 5),
      "holder must have entered the block"

    waiter = Thread.new do
      waiter_acquire_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Parse::Lock.acquire(key, ttl: 5, wait: 5.0) do
        waiter_acquired_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) - waiter_acquire_start
      end
    end

    # Give the waiter a measurable contention window before releasing.
    # Real wall-clock here is OK — we're just establishing a floor for
    # the waiter's observed wait time; the test asserts ≥ this floor.
    contention_floor = 0.2
    sleep contention_floor
    release_signal << :ok

    holder.join
    waiter.join

    refute_nil waiter_acquired_at, "waiter must have acquired"
    assert waiter_acquired_at >= contention_floor,
      "waiter should have waited at least #{contention_floor}s for the holder (got #{waiter_acquired_at}s)"
  end

  def test_wait_zero_against_held_real_redis_lock_raises_timeout
    key = "fast-fail-#{SecureRandom.hex(4)}"
    acquired_signal = Queue.new
    release_signal  = Queue.new

    holder = Thread.new do
      Parse::Lock.acquire(key, ttl: 5) do
        acquired_signal << :inside
        release_signal.pop
      end
    end

    # Block until the holder is actually inside the block — no sleep.
    assert_equal :inside, acquired_signal.pop(timeout: 5)

    assert_raises(Parse::Lock::TimeoutError) do
      Parse::Lock.acquire(key, ttl: 5, wait: 0) { flunk "should not enter block" }
    end

    release_signal << :ok
    holder.join
  end

  # ---- different secrets isolate locks on the same raw key -------------

  def test_different_secrets_do_not_serialize_same_raw_key
    # Operator A and Operator B both lock "shared-name" but with
    # different secrets. HMAC keying means they get different store
    # keys, so they do NOT block each other. Queue-gated to avoid
    # sleep-based race conditions.
    key = "shared-name-#{SecureRandom.hex(4)}"
    a_acquired = Queue.new
    a_release  = Queue.new
    b_seen     = false

    # 32-byte secrets — Parse::Lock now refuses explicit secrets
    # shorter than SECRET_MIN_BYTES (=16). Use real-length keys here.
    secret_a = "operator-A-secret-padding-to-32!" # exactly 32 bytes
    secret_b = "operator-B-secret-padding-to-32!"

    holder = Thread.new do
      Parse::Lock.acquire(key, ttl: 5, secret: secret_a) do
        a_acquired << :inside
        a_release.pop  # block until test says ok
      end
    end

    # Deterministic wait — A is inside.
    assert_equal :inside, a_acquired.pop(timeout: 5)

    # B with a DIFFERENT secret must acquire immediately (no wait).
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Parse::Lock.acquire(key, ttl: 5, wait: 0.5, secret: secret_b) do
      b_seen = true
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    a_release << :ok
    holder.join

    assert b_seen, "B with a different secret must have acquired immediately"
    assert elapsed < 0.1,
      "B's acquire must NOT have waited on A's lock (got #{elapsed}s)"
  end

  # ---- shared HMAC secret with Parse::CreateLock -----------------------

  def test_secret_is_shared_with_create_lock_via_env_var
    # PARSE_STACK_LOCK_SECRET resolves the same value from
    # LockBackend regardless of which caller passes the source: tag.
    s_lock        = Parse::LockBackend.lock_secret_for(store: @wrapper, source: "Parse::Lock")
    s_create_lock = Parse::LockBackend.lock_secret_for(store: @wrapper, source: "Parse::CreateLock")
    assert_equal "integration-test-secret", s_lock
    assert_equal "integration-test-secret", s_create_lock
    assert_equal s_lock, s_create_lock,
      "operator-configured secret must be uniform across both Parse::Lock and Parse::CreateLock"
  end

  # ---- namespace isolation on the real shared Redis --------------------

  def test_lock_namespace_does_not_collide_with_first_or_create_namespace
    # Hold a Parse::Lock under a particular raw key; the cache-store
    # key MUST be in the parse-stack:lock:v1: namespace and NOT in
    # the parse-stack:foc:v1: namespace.
    raw_key = "namespace-isolation-#{SecureRandom.hex(4)}"

    keys_during_hold = []
    Parse::Lock.acquire(raw_key, ttl: 5) do
      keys_during_hold = @probe.each_key.to_a
    end

    assert keys_during_hold.any? { |k| k.start_with?(Parse::Lock::KEY_PREFIX) },
      "Parse::Lock key must use the parse-stack:lock:v1: prefix: #{keys_during_hold.inspect}"
    refute keys_during_hold.any? { |k| k.start_with?("parse-stack:foc:v1:") },
      "Parse::Lock must NOT write into the first_or_create! namespace"
  end

  private

  def redis_reachable?
    probe = Moneta.new(:Redis, url: REDIS_URL)
    probe["__health__"] = "ok"
    reachable = probe["__health__"] == "ok"
    probe.delete("__health__")
    probe.close
    reachable
  rescue StandardError
    false
  end
end
