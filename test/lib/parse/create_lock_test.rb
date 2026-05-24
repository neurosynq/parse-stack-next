# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "moneta"

# Unit tests for Parse::CreateLock — the mutex primitive used by the
# synchronize-create wrapper on first_or_create! and create_or_update!.
#
# These tests use a fake Moneta store backed by a Hash with TTL simulation,
# plus a real Moneta::Memory adapter to exercise the degraded-mode in-process
# Mutex fallback. Integration tests (test/lib/parse/first_or_create_race_integration_test.rb)
# cover Redis-backed cross-process locking.
class CacheOptionRegressionKlass < Parse::Object
  parse_class "CacheOptionRegressionKlass"
  property :email, :string
end

class CacheLockKeyKlass < Parse::Object
  parse_class "CacheLockKeyKlass"
  property :email, :string
end

class CacheOptionCreateOrUpdateKlass < Parse::Object
  parse_class "CacheOptionCreateOrUpdateKlass"
  property :email, :string
end

class CreateLockTest < Minitest::Test
  # Minimal in-memory store that emulates Moneta's #create / #key? / #[] /
  # #delete contract with TTL. Used to test the cross-process acquire/release
  # path without actually requiring a Redis connection. The lock module
  # detects "process-local" stores by class name; this class is intentionally
  # named so it is NOT detected as Memory/Null, so the cross-process code path
  # is exercised.
  class FakeRedisLikeStore
    def initialize
      @data = {}
      @mutex = Mutex.new
    end

    def create(key, value, expires: nil)
      @mutex.synchronize do
        sweep_expired
        return false if @data.key?(key)
        deadline = expires ? monotonic + expires : nil
        @data[key] = [value, deadline]
        true
      end
    end

    def key?(key)
      @mutex.synchronize do
        sweep_expired
        @data.key?(key)
      end
    end

    def [](key)
      @mutex.synchronize do
        sweep_expired
        v = @data[key]
        v ? v[0] : nil
      end
    end

    def delete(key)
      @mutex.synchronize do
        @data.delete(key)
      end
    end

    def store(key, value, expires: nil)
      @mutex.synchronize do
        deadline = expires ? monotonic + expires : nil
        @data[key] = [value, deadline]
        value
      end
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def sweep_expired
      now = monotonic
      @data.delete_if { |_, (_, deadline)| deadline && deadline <= now }
    end
  end

  def setup
    @saved_store = Parse.synchronize_create_store
    @saved_secret = Parse.synchronize_create_secret
    @saved_classes = Parse.synchronize_classes
    @saved_default = Parse.synchronize_create_default
    @saved_options = Parse.synchronize_create_options
    @saved_env_secret = ENV["PARSE_STACK_LOCK_SECRET"]
    ENV.delete("PARSE_STACK_LOCK_SECRET")
    Parse.synchronize_create_secret = nil
    Parse.synchronize_create_store = nil
    Parse.synchronize_classes = nil
    Parse.synchronize_create_default = false
    Parse.synchronize_create_options = {}
    Parse::CreateLock.reset!
  end

  def teardown
    Parse.synchronize_create_store = @saved_store
    Parse.synchronize_create_secret = @saved_secret
    Parse.synchronize_classes = @saved_classes
    Parse.synchronize_create_default = @saved_default
    Parse.synchronize_create_options = @saved_options
    ENV["PARSE_STACK_LOCK_SECRET"] = @saved_env_secret if @saved_env_secret
    Parse::CreateLock.reset!
  end

  # --- Canonical key derivation -----------------------------------------

  def test_canonical_key_is_stable_for_same_inputs
    k1 = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { email: "a@b.c" })
    k2 = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { email: "a@b.c" })
    assert_equal k1, k2
    assert k1.start_with?("parse-stack:foc:v1:")
  end

  def test_canonical_key_changes_with_class
    k1 = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { email: "a@b.c" })
    k2 = Parse::CreateLock.canonical_key(parse_class: "Admin", query_attrs: { email: "a@b.c" })
    refute_equal k1, k2
  end

  def test_canonical_key_changes_with_session_token
    k1 = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { email: "a@b.c" })
    k2 = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { email: "a@b.c" }, session_token: "r:abc")
    refute_equal k1, k2
  end

  def test_canonical_key_changes_with_master_key_flag
    k1 = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { email: "a@b.c" }, master_key: true)
    k2 = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { email: "a@b.c" }, master_key: false)
    refute_equal k1, k2
  end

  def test_canonical_key_is_independent_of_attr_order
    k1 = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { email: "a@b.c", name: "X" })
    k2 = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { name: "X", email: "a@b.c" })
    assert_equal k1, k2
  end

  def test_canonical_key_string_and_symbol_keys_collapse
    k1 = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { email: "a@b.c" })
    k2 = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { "email" => "a@b.c" })
    assert_equal k1, k2
  end

  def test_canonical_key_distinguishes_saved_pointers
    saved_a = Parse::User.pointer("abc")
    saved_b = Parse::User.pointer("xyz")
    k1 = Parse::CreateLock.canonical_key(parse_class: "Note", query_attrs: { author: saved_a })
    k2 = Parse::CreateLock.canonical_key(parse_class: "Note", query_attrs: { author: saved_b })
    refute_equal k1, k2
  end

  # --- Invalid-key raises ----------------------------------------------

  def test_canonical_key_rejects_empty_attrs
    assert_raises(Parse::CreateLockInvalidKey) do
      Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: {})
    end
  end

  def test_canonical_key_rejects_proc_value
    assert_raises(Parse::CreateLockInvalidKey) do
      Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { email: ->(x) { x } })
    end
  end

  def test_canonical_key_rejects_regexp_value
    assert_raises(Parse::CreateLockInvalidKey) do
      Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { email: /foo/ })
    end
  end

  def test_canonical_key_rejects_nested_hash
    assert_raises(Parse::CreateLockInvalidKey) do
      Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { meta: { a: 1 } })
    end
  end

  def test_canonical_key_rejects_dotted_key
    assert_raises(Parse::CreateLockInvalidKey) do
      Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { "email.gt" => "a@b.c" })
    end
  end

  def test_canonical_key_accepts_parse_operation_key_and_is_stable
    # Filter-lock: identical operator predicates across callers must hash to the
    # same key so concurrent first_or_create! callers serialize. The lock keys
    # the whole query shape — equivalence-class reasoning belongs to the Mongo
    # unique index, not the lock.
    k1 = Parse::CreateLock.canonical_key(
      parse_class: "Role",
      query_attrs: { team: Parse::Pointer.new("Team", "t1"), :project.exists => false, access_level: "read" },
    )
    k2 = Parse::CreateLock.canonical_key(
      parse_class: "Role",
      query_attrs: { access_level: "read", :project.exists => false, team: Parse::Pointer.new("Team", "t1") },
    )
    assert_equal k1, k2
  end

  def test_canonical_key_distinguishes_operator_from_plain_field
    # {project: nil} and {:project.exists => false} are NOT the same filter,
    # so they must produce distinct lock keys.
    k_plain = Parse::CreateLock.canonical_key(parse_class: "Role", query_attrs: { project: nil })
    k_op = Parse::CreateLock.canonical_key(parse_class: "Role", query_attrs: { :project.exists => false })
    refute_equal k_plain, k_op
  end

  def test_canonical_key_distinguishes_different_operators
    k_exists = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { :email.exists => true })
    k_gt = Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { :email.gt => "a@b.c" })
    refute_equal k_exists, k_gt
  end

  def test_canonical_key_rejects_plain_key_with_null_byte
    # Defense-in-depth: a plain string key containing \u0000 could otherwise
    # collide with a Parse::Operation encoding (operand\u0000op_operator).
    assert_raises(Parse::CreateLockInvalidKey) do
      Parse::CreateLock.canonical_key(parse_class: "Role", query_attrs: { "project\u0000op_exists" => false })
    end
  end

  def test_canonical_key_rejects_duplicate_operation_keys
    # Parse::Operation has no eql?/hash override, so {:age.gt => 10, :age.gt => 20}
    # is two distinct Hash entries that collapse to the same canonical key string.
    # Must raise rather than silently dropping one.
    assert_raises(Parse::CreateLockInvalidKey) do
      Parse::CreateLock.canonical_key(
        parse_class: "User",
        query_attrs: { :age.gt => 10, :age.gt => 20 },
      )
    end
  end

  def test_canonical_key_allows_plain_field_and_same_named_operator
    # Plain key "project" and operator key "project\u0000op_exists" must coexist
    # without colliding — they describe different facets of the same field.
    k = Parse::CreateLock.canonical_key(
      parse_class: "Role",
      query_attrs: { project: Parse::Pointer.new("Project", "p1"), :project.exists => true },
    )
    assert k.start_with?("parse-stack:foc:v1:")
  end

  def test_canonical_key_operation_with_pointer_value
    k1 = Parse::CreateLock.canonical_key(
      parse_class: "Role",
      query_attrs: { :owner.exists => true, team: Parse::Pointer.new("Team", "t1") },
    )
    k2 = Parse::CreateLock.canonical_key(
      parse_class: "Role",
      query_attrs: { team: Parse::Pointer.new("Team", "t1"), :owner.exists => true },
    )
    assert_equal k1, k2
  end

  def test_canonical_key_rejects_nested_hash_value_under_operator_key
    # Operator keys must still flow through value-side rejection — the new key
    # encoding doesn't loosen any value-side gates.
    assert_raises(Parse::CreateLockInvalidKey) do
      Parse::CreateLock.canonical_key(
        parse_class: "User",
        query_attrs: { :meta.exists => { a: 1 } },
      )
    end
  end

  def test_canonical_key_rejects_unsaved_pointer
    unsaved = Parse::User.new
    assert_raises(Parse::CreateLockInvalidKey) do
      Parse::CreateLock.canonical_key(parse_class: "Note", query_attrs: { author: unsaved })
    end
  end

  def test_canonical_key_rejects_oversized_payload
    huge = "x" * 9_000
    assert_raises(Parse::CreateLockInvalidKey) do
      Parse::CreateLock.canonical_key(parse_class: "User", query_attrs: { blob: huge })
    end
  end

  # --- Acquire / release lifecycle on cross-process store ---------------

  def test_acquire_yields_block_and_releases
    Parse.synchronize_create_store = FakeRedisLikeStore.new
    sentinel = nil
    result = Parse::CreateLock.synchronize(
      parse_class: "Order",
      query_attrs: { ref: "X1" },
      options: { ttl: 2, wait: 1.0 },
    ) do
      sentinel = :ran
      "block-result"
    end
    assert_equal :ran, sentinel
    assert_equal "block-result", result
    # Lock should be released — a follow-up acquisition succeeds immediately.
    second = Parse::CreateLock.synchronize(
      parse_class: "Order",
      query_attrs: { ref: "X1" },
      options: { ttl: 2, wait: 0.2 },
    ) { :again }
    assert_equal :again, second
  end

  def test_concurrent_acquisitions_serialize
    Parse.synchronize_create_store = FakeRedisLikeStore.new
    order = []
    order_mu = Mutex.new
    threads = 5.times.map do |i|
      Thread.new do
        Parse::CreateLock.synchronize(
          parse_class: "Order",
          query_attrs: { ref: "shared" },
          options: { ttl: 2, wait: 5.0 },
        ) do
          order_mu.synchronize { order << [i, :in] }
          sleep 0.02
          order_mu.synchronize { order << [i, :out] }
        end
      end
    end
    threads.each(&:join)
    # Each thread's :in and :out must be adjacent — no interleaving.
    enters_and_exits = order.each_slice(2).to_a
    enters_and_exits.each do |pair|
      assert_equal pair.first.first, pair.last.first
      assert_equal :in, pair.first.last
      assert_equal :out, pair.last.last
    end
  end

  def test_wait_timeout_raises
    Parse.synchronize_create_store = FakeRedisLikeStore.new
    blocker = Thread.new do
      Parse::CreateLock.synchronize(
        parse_class: "Order",
        query_attrs: { ref: "X1" },
        options: { ttl: 5, wait: 1.0 },
      ) { sleep 1.0 }
    end
    sleep 0.05  # let blocker acquire
    assert_raises(Parse::CreateLockTimeoutError) do
      Parse::CreateLock.synchronize(
        parse_class: "Order",
        query_attrs: { ref: "X1" },
        options: { ttl: 5, wait: 0.2 },
      ) { flunk "should not reach block" }
    end
    blocker.join
  end

  def test_release_does_not_run_when_acquire_times_out
    # When acquire never succeeds, release must not be called — protects the
    # pre-existing holder from a never-acquired caller wiping their lock.
    store = FakeRedisLikeStore.new
    Parse.synchronize_create_store = store
    key = Parse::CreateLock.canonical_key(parse_class: "Order", query_attrs: { ref: "X1" })
    store.create(key, "other-owner", expires: 60)
    assert_raises(Parse::CreateLockTimeoutError) do
      Parse::CreateLock.synchronize(
        parse_class: "Order",
        query_attrs: { ref: "X1" },
        options: { ttl: 5, wait: 0.2 },
      ) { flunk "should not yield" }
    end
    assert_equal "other-owner", store[key]
  end

  def test_release_uses_compare_and_delete
    # When the lock's owner has been replaced mid-section (e.g. TTL expired,
    # another caller acquired), the original owner's release must NOT delete
    # the new holder's lock. This is the load-bearing CAD safety property.
    store = FakeRedisLikeStore.new
    Parse.synchronize_create_store = store
    key = Parse::CreateLock.canonical_key(parse_class: "Order", query_attrs: { ref: "X1" })

    Parse::CreateLock.synchronize(
      parse_class: "Order",
      query_attrs: { ref: "X1" },
      options: { ttl: 60, wait: 1.0 },
    ) do
      # Simulate a concurrent owner overwriting the lock value (e.g. after
      # our TTL expired and another process acquired) while we're still
      # "inside" our critical section. The release block runs on yield exit
      # and must see the value doesn't match its UUID, so it does nothing.
      store.store(key, "concurrent-owner", expires: 60)
    end
    assert_equal "concurrent-owner", store[key], "CAD: release must not delete a lock owned by someone else"
  end

  # --- Degraded-mode (process-local Mutex) ------------------------------

  def test_degraded_mode_with_memory_adapter_falls_back_to_mutex
    # Real Moneta Memory adapter — module should detect process-local and
    # use the Mutex fallback rather than the cross-process create()/delete().
    Parse.synchronize_create_store = Moneta.build { use :Expires; adapter :Memory }
    # Suppress the per-call :warn output for cleaner test runs
    _stderr = capture_stderr do
      Parse::CreateLock.synchronize(
        parse_class: "Order",
        query_attrs: { ref: "X" },
        options: { ttl: 2, wait: 1.0, on_degraded: :proceed },
      ) { :ok }
    end
  end

  def test_degraded_mode_serializes_threads
    Parse.synchronize_create_store = Moneta.build { use :Expires; adapter :Memory }
    order = []
    order_mu = Mutex.new
    threads = 8.times.map do |i|
      Thread.new do
        Parse::CreateLock.synchronize(
          parse_class: "Order",
          query_attrs: { ref: "shared" },
          options: { ttl: 2, wait: 5.0, on_degraded: :proceed },
        ) do
          order_mu.synchronize { order << [i, :in] }
          sleep 0.005
          order_mu.synchronize { order << [i, :out] }
        end
      end
    end
    threads.each(&:join)
    order.each_slice(2) do |a, b|
      assert_equal a.first, b.first, "in/out interleaved: #{order.inspect}"
    end
  end

  def test_degraded_mode_raise_when_configured
    Parse.synchronize_create_store = Moneta.build { use :Expires; adapter :Memory }
    assert_raises(Parse::CreateLockUnavailableError) do
      Parse::CreateLock.synchronize(
        parse_class: "Order",
        query_attrs: { ref: "X" },
        options: { ttl: 2, wait: 1.0, on_degraded: :raise },
      ) { flunk }
    end
  end

  # --- Regression: store without #create degrades gracefully -----------

  # Mimics the pre-fix Parse::Cache::Redis wrapper shape: a non-Memory/Null
  # class name and no #create method. Before the 5.0.1 fix this was classified
  # as a healthy cross-process store, every acquire raised NoMethodError, and
  # the lock spun until the wait budget elapsed and raised
  # Parse::CreateLockTimeoutError.
  class NoCreateFakeWrapper
    def initialize; @h = {}; end
    def [](k); @h[k]; end
    def key?(k); @h.key?(k); end
    def store(k, v, _opts = {}); @h[k] = v; end
    def delete(k); @h.delete(k); end
  end

  def test_store_without_create_degrades_to_process_local_mutex
    Parse.synchronize_create_store = NoCreateFakeWrapper.new
    capture_stderr do
      result = Parse::CreateLock.synchronize(
        parse_class: "Order",
        query_attrs: { ref: "Y" },
        options: { ttl: 2, wait: 0.5, on_degraded: :proceed },
      ) { :acquired }
      assert_equal :acquired, result
    end
  end

  def test_parse_cache_redis_wrapper_is_treated_as_cross_process_store
    skip "Parse::Cache::Redis not loaded" unless defined?(Parse::Cache::Redis)
    refute Parse::CreateLock.send(:degraded_store?, Parse::Cache::Redis.allocate),
           "Parse::Cache::Redis wrapper must be classified as cross-process"
  end

  # --- Query-option partition (regression for the cache: TTL escape hatch) -

  def test_parse_query_option_key_predicate_recognizes_query_shape_keys
    # Source of truth for the actions.rb partition. If conditions() gains
    # a new option-branch key, add it to QUERY_OPTION_KEYS and extend this
    # assertion so the partition keeps track.
    assert Parse::Query.option_key?(:cache)
    assert Parse::Query.option_key?(:limit)
    assert Parse::Query.option_key?(:order)
    assert Parse::Query.option_key?(:keys)
    assert Parse::Query.option_key?(:skip)
    assert Parse::Query.option_key?(:include)
    assert Parse::Query.option_key?(:includes)
    assert Parse::Query.option_key?(:session)
    assert Parse::Query.option_key?(:use_master_key)
    assert Parse::Query.option_key?(:read_preference)
    assert Parse::Query.option_key?(:readable_by)
    assert Parse::Query.option_key?(:writable_by)
    assert Parse::Query.option_key?(:publicly_readable)
    assert Parse::Query.option_key?(:master_key_only)
    # String form also works (callers symbolize_keys before partitioning,
    # but the predicate is defensive).
    assert Parse::Query.option_key?("cache")
    # Plain constraint keys must NOT be matched.
    refute Parse::Query.option_key?(:email)
    refute Parse::Query.option_key?(:status)
    refute Parse::Query.option_key?(:created_at)
    # Non-Symbol/String inputs (e.g. Parse::Operation) are constraints.
    refute Parse::Query.option_key?(:email.gt)
  end

  def test_first_or_create_with_duration_cache_option_does_not_raise
    # Regression for 4.4.2: callers used to pass `cache: 30.seconds` (or
    # any other Parse::Query option key) inside the constraints hash so
    # `first_or_create!` could memoize the find via the HTTP query
    # cache. Before the partition, CreateLock's canonicalizer saw the
    # `ActiveSupport::Duration` value and raised
    # `Parse::CreateLockInvalidKey` in its "unsupported type" branch.
    Parse.synchronize_create_store = FakeRedisLikeStore.new

    found = CacheOptionRegressionKlass.new(email: "a@b.c")
    captured = nil
    CacheOptionRegressionKlass.define_singleton_method(:_scoped_first) do |query_attrs, **|
      captured = query_attrs
      found
    end

    result = CacheOptionRegressionKlass.first_or_create!(
      { email: "a@b.c", cache: 30.seconds, limit: 5 },
      {},
      synchronize: true,
    )
    assert_same found, result
    # _scoped_first still receives the option keys so Parse::Query#conditions
    # absorbs them on the find side (the cache TTL still applies).
    assert_includes captured.keys, :cache
    assert_includes captured.keys, :limit
  ensure
    CacheOptionRegressionKlass.singleton_class.send(:remove_method, :_scoped_first) rescue nil
  end

  def test_create_or_update_with_duration_cache_option_does_not_raise
    # Companion to test_first_or_create_with_duration_cache_option_does_not_raise:
    # create_or_update! shares the same partition logic as first_or_create!,
    # but a refactor that drifted one without the other would not be caught
    # by the first_or_create-only test. Verify the same regression is
    # closed on this side.
    Parse.synchronize_create_store = FakeRedisLikeStore.new

    found = CacheOptionCreateOrUpdateKlass.new(email: "a@b.c")
    captured = nil
    CacheOptionCreateOrUpdateKlass.define_singleton_method(:_scoped_first) do |query_attrs, **|
      captured = query_attrs
      found
    end

    result = CacheOptionCreateOrUpdateKlass.create_or_update!(
      { email: "a@b.c", cache: 30.seconds, limit: 5 },
      {}, # empty resource_attrs — skip the "apply changes" side-effect branch
      synchronize: true,
    )
    assert_same found, result
    assert_includes captured.keys, :cache
    assert_includes captured.keys, :limit
  ensure
    CacheOptionCreateOrUpdateKlass.singleton_class.send(:remove_method, :_scoped_first) rescue nil
  end

  def test_first_or_create_raises_specific_error_when_query_attrs_are_all_options
    # When the caller passes a query_attrs Hash containing ONLY
    # Parse::Query option keys, the lock partition leaves nothing for
    # canonicalization. Rather than surfacing CreateLock's generic
    # "non-empty query_attrs" message (which is misleading — the
    # caller DID pass a non-empty Hash), `first_or_create!` now
    # raises a specific CreateLockInvalidKey naming the option keys.
    Parse.synchronize_create_store = FakeRedisLikeStore.new

    err = assert_raises(Parse::CreateLockInvalidKey) do
      CacheOptionRegressionKlass.first_or_create!(
        { cache: 30.seconds, limit: 5 },
        {},
        synchronize: true,
      )
    end
    assert_match(/at least one constraint key/, err.message)
    assert_match(/cache/, err.message)
    assert_match(/limit/, err.message)
    assert_match(/synchronize: false/, err.message)
  end

  def test_first_or_create_raises_generic_error_on_empty_query_attrs
    # Pure empty Hash → distinguished from the "all options" case so the
    # error message doesn't fabricate a list of option keys that weren't
    # actually passed.
    Parse.synchronize_create_store = FakeRedisLikeStore.new

    err = assert_raises(Parse::CreateLockInvalidKey) do
      CacheOptionRegressionKlass.first_or_create!({}, {}, synchronize: true)
    end
    assert_match(/empty Hash/, err.message)
  end

  def test_first_or_create_lock_key_ignores_query_options
    # Two callers with identical CONSTRAINTS but different query-shape
    # OPTIONS must serialize on the same lock. The lock identifies the
    # find/create target, not the caller's caching preferences.
    Parse.synchronize_create_store = FakeRedisLikeStore.new

    found = CacheLockKeyKlass.new(email: "a@b.c")
    CacheLockKeyKlass.define_singleton_method(:_scoped_first) do |*, **|
      found
    end

    captured = []
    original_canonical_key = Parse::CreateLock.method(:canonical_key)
    Parse::CreateLock.singleton_class.send(:define_method, :canonical_key) do |**kwargs|
      result = original_canonical_key.call(**kwargs)
      captured << result
      result
    end

    begin
      CacheLockKeyKlass.first_or_create!({ email: "a@b.c", cache: 30 },         {}, synchronize: true)
      CacheLockKeyKlass.first_or_create!({ email: "a@b.c", cache: 60, limit: 3 }, {}, synchronize: true)
      CacheLockKeyKlass.first_or_create!({ email: "a@b.c" },                    {}, synchronize: true)
    ensure
      Parse::CreateLock.singleton_class.send(:remove_method, :canonical_key)
      Parse::CreateLock.define_singleton_method(:canonical_key, original_canonical_key)
      CacheLockKeyKlass.singleton_class.send(:remove_method, :_scoped_first) rescue nil
    end

    assert_equal 3, captured.size
    assert_equal captured.first, captured[1],
                 "different cache TTL must not change the lock key"
    assert_equal captured.first, captured[2],
                 "absent cache option must not change the lock key"
  end

  # --- Telemetry --------------------------------------------------------

  def test_acquire_release_emit_notifications
    Parse.synchronize_create_store = FakeRedisLikeStore.new
    events = []
    sub = ActiveSupport::Notifications.subscribe(/^parse\.synchronize_create\./) do |name, *_args|
      events << name
    end
    begin
      Parse::CreateLock.synchronize(
        parse_class: "Order",
        query_attrs: { ref: "X" },
        options: { ttl: 1, wait: 0.5 },
      ) { :ok }
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
    assert_includes events, "parse.synchronize_create.acquired"
    assert_includes events, "parse.synchronize_create.released"
  end

  private

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
