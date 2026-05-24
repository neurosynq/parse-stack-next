require_relative "../../test_helper_integration"
require "minitest/autorun"
require "moneta"

# Integration test for the 5.0.1 fix: Parse::CreateLock must successfully
# acquire / release cross-process locks against a Parse::Cache::Redis wrapper
# backed by a real Redis. The pre-fix code path raised NoMethodError on
# every #create call (the wrapper did not forward SETNX), was misclassified
# as a healthy cross-process store by degraded_store?, and spun on the
# polling loop until Parse::CreateLockTimeoutError. This test pins:
#
#  - synchronize() returns the block value (no NoMethodError swallowed
#    into infinite contention)
#  - the lock key actually appears in Redis between acquire and release
#  - the lock key is gone after the block exits (CAD release runs)
#  - clear(scope:) deletes only the targeted prefix and never touches
#    parse-stack:foc:v1:* lock keys living on the same DB
#  - the Parse::Cache::Redis wrapper is classified as non-degraded by
#    Parse::CreateLock.degraded_store? (i.e. the in-process Mutex
#    fallback is NOT taken when the wrapper is configured)

class CreateLockRedisIntegrationTest < Minitest::Test
  REDIS_URL = ENV["PARSE_TEST_REDIS_URL"] || "redis://localhost:6399/0"

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Redis not reachable at #{REDIS_URL}" unless redis_reachable?

    @probe = Moneta.new(:Redis, url: REDIS_URL, expires: true)
    @probe.clear

    @saved_store = Parse.synchronize_create_store
    @saved_secret = Parse.synchronize_create_secret
    @saved_env_secret = ENV["PARSE_STACK_LOCK_SECRET"]
    # Pin a deterministic HMAC secret so the canonical_key the test computes
    # locally matches what synchronize() puts into Redis. Without this the
    # plain-SHA256 fallback path runs and the keys still match, but the
    # one-time SECURITY warning fires on $stderr and noises the test log.
    ENV["PARSE_STACK_LOCK_SECRET"] = "integration-test-secret"
    Parse.synchronize_create_secret = nil

    @wrapper = Parse::Cache::Redis.new(url: REDIS_URL, namespace: nil, pool_size: 2)
    Parse.synchronize_create_store = @wrapper
    Parse::CreateLock.reset!
  end

  def teardown
    Parse.synchronize_create_store = @saved_store
    Parse.synchronize_create_secret = @saved_secret
    if @saved_env_secret
      ENV["PARSE_STACK_LOCK_SECRET"] = @saved_env_secret
    else
      ENV.delete("PARSE_STACK_LOCK_SECRET")
    end
    Parse::CreateLock.reset!
    @wrapper&.close
    @probe&.close
  end

  def test_wrapper_is_classified_as_cross_process_store
    refute Parse::CreateLock.send(:degraded_store?, @wrapper),
           "Parse::Cache::Redis wrapper must NOT be classified as degraded — " \
           "otherwise synchronize() falls back to a per-process Mutex and " \
           "cross-process locking is silently disabled."
  end

  def test_synchronize_acquires_and_releases_against_real_redis
    query_attrs = { ref: "INT-#{SecureRandom.hex(4)}" }
    expected_key = Parse::CreateLock.canonical_key(
      parse_class: "IntegrationOrder",
      query_attrs: query_attrs,
    )

    observed_inside = nil
    result = Parse::CreateLock.synchronize(
      parse_class: "IntegrationOrder",
      query_attrs: query_attrs,
      options: { ttl: 5, wait: 2.0 },
    ) do
      observed_inside = @probe[expected_key]
      :acquired
    end

    assert_equal :acquired, result, "synchronize must return the block value"
    assert observed_inside, "lock key must be present in Redis while the block is running"
    assert_nil @probe[expected_key], "lock key must be released after the block exits"
  end

  def test_contended_acquire_serializes_across_threads
    # Two threads, one shared query_attrs, ttl long enough that the first
    # holder still has the lock when the second tries. Verifies that the
    # second thread actually waits on Redis rather than racing in.
    query_attrs = { ref: "INT-CONT-#{SecureRandom.hex(4)}" }
    events = Queue.new

    holder = Thread.new do
      Parse::CreateLock.synchronize(
        parse_class: "IntegrationOrder",
        query_attrs: query_attrs,
        options: { ttl: 10, wait: 5.0 },
      ) do
        events << [:holder_in, monotonic]
        sleep 0.2
        events << [:holder_out, monotonic]
      end
    end

    sleep 0.05  # give holder a head start
    waiter = Thread.new do
      Parse::CreateLock.synchronize(
        parse_class: "IntegrationOrder",
        query_attrs: query_attrs,
        options: { ttl: 5, wait: 5.0 },
      ) do
        events << [:waiter_in, monotonic]
      end
    end

    holder.join
    waiter.join

    seq = []
    seq << events.pop until events.empty?
    seq.sort_by!(&:last)
    names = seq.map(&:first)
    assert_equal %i[holder_in holder_out waiter_in], names,
                 "second thread must acquire only after first releases (got #{names.inspect})"
  end

  def test_clear_with_scope_preserves_lock_keys
    # Plant a few application keys under a tenant namespace and an active
    # lock key under parse-stack:foc:v1: on the same DB. Clearing the
    # tenant namespace must NOT delete the lock.
    @probe.store("tenant_x:cache:item:1", "a", expires: 60)
    @probe.store("tenant_x:cache:item:2", "b", expires: 60)
    @probe.store("tenant_y:cache:item:1", "c", expires: 60)
    lock_key = "parse-stack:foc:v1:integration-fixture-#{SecureRandom.hex(4)}"
    @probe.store(lock_key, "owner-uuid", expires: 60)

    @wrapper.clear(scope: "tenant_x")

    assert_nil @probe["tenant_x:cache:item:1"], "tenant_x keys must be deleted"
    assert_nil @probe["tenant_x:cache:item:2"], "tenant_x keys must be deleted"
    assert_equal "c", @probe["tenant_y:cache:item:1"], "tenant_y keys must be untouched"
    assert_equal "owner-uuid", @probe[lock_key], "create-lock keys on the shared DB must be untouched by a scoped clear"
  end

  def test_clear_rejects_empty_scope
    assert_raises(ArgumentError) { @wrapper.clear(scope: "") }
    assert_raises(ArgumentError) { @wrapper.clear(scope: ":") }
  end

  private

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

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
