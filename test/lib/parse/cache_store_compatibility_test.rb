# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/cache/keyspace"
require "parse/cache/scoped_view"
require "moneta"

# The contract between an application's cache store and the SDK's slice of it.
#
# Two things went wrong before this existed, and they are opposite failures of
# the same confusion about who owns the store.
#
# 1. `cache_keyspace: true` REPLACED `client.cache` with a scoped view. The
#    store the application configured and handed in was no longer reachable
#    through the accessor documented for reaching it, and application reads
#    and writes silently moved inside the SDK's keyspace, changing the
#    physical names of keys the application had been using.
#
# 2. `clear_cache!` then operated on whatever `cache` had become. Without a
#    keyspace that is the raw store, so on Redis it is `FLUSHDB`, taking
#    application keys, other applications, and the create-locks with it.
#
# The split is `client.cache` (exactly what was configured, application-owned)
# and `client.sdk_cache` (the SDK's slice). A scoped view cannot honestly
# double as a complete Moneta store: `clear`, `each_key`, and `close` either
# break scope isolation or change meaning.
class CacheStoreCompatibilityTest < Minitest::Test
  SERVER = "https://api.example.com/parse"

  # Several cases call Parse.setup, which REPLACES the process-wide default
  # client. Leaving that in place leaked into whatever ran next: paired with
  # the Mongo binding tests it produced errors that appear only in a full-suite
  # run and vanish when the file is run alone, which is the worst kind to
  # debug.
  def setup
    @previous_default = Parse::Client.instance_variable_get(:@clients)[:default]
  end

  def teardown
    Parse::Client.instance_variable_get(:@clients)[:default] = @previous_default
  end

  # A double standing in for both halves of what Parse::Cache::Redis talks to:
  # the Moneta store (which carries `load`, including its options argument)
  # and the redis-rb client reached for SCAN and locking.
  #
  # `load` is modelled deliberately. An earlier version of this double had
  # only `[]`, which is why it could not see that option-carrying reads
  # recursed until SystemStackError: the wrapper never had a `load` to call,
  # so no test ever called one.
  #
  # Keys are stored verbatim, which is what the real adapter does. Verified
  # against a live Redis: writing `parse-stack:v1:<scope>:_:role:u1` through
  # this wrapper produces exactly that physical key, because the wrapper
  # keeps Moneta's default key handling and Moneta writes String keys
  # through unchanged. That is what makes the SCAN patterns in
  # `delete_keys_matching!` correct.
  class FakeRedisNode
    attr_reader :data, :load_options

    def initialize = @data = {}

    def load(key, options = {})
      @load_options = options
      @data[key]
    end

    def [](key) = load(key, {})
    def key?(key, _options = {}) = @data.key?(key)
    def delete(key, _options = {}) = @data.delete(key)
    def store(key, value, _options = {}) = (@data[key] = value)
    def backend = self
    def keys = @data.keys.dup

    def create(key, value, _options = {})
      return false if @data.key?(key)
      @data[key] = value
      true
    end

    def increment(key, amount = 1, _options = {})
      @data[key] = (@data[key] || 0).to_i + amount
    end

    def scan(_cursor, match:, count: 1000)
      ["0", @data.keys.select { |k| File.fnmatch(match, k, File::FNM_NOESCAPE) }]
    end

    def clear(_options = {}) = @data.clear
    def unlink(*keys) = keys.flatten.count { |k| !@data.delete(k).nil? }
    def del(*keys) = unlink(*keys)
    def pexpire(_key, _ms) = true
  end

  def redis_backend
    node = FakeRedisNode.new
    backend = Parse::Cache::Redis.new(url: "redis://localhost:6379/0")
    backend.instance_variable_set(:@pool, Parse::Cache::Pool.new(size: 1) { node })
    [backend, node]
  end

  def keyspace(app_id: "appA", namespace: nil)
    Parse::Cache::Keyspace.new(app_id: app_id, server_url: SERVER, namespace: namespace)
  end

  # The four store shapes the matrix runs against: raw Moneta memory and
  # Parse::Cache::Redis, each with keyspacing on and off.
  def each_store_shape
    ks = keyspace

    moneta = Moneta.new(:Memory)
    yield("moneta, no keyspace", moneta, moneta)
    yield("moneta, keyspaced", moneta, Parse::Cache::KeyspacedStore.new(store: moneta, keyspace: ks))

    backend, = redis_backend
    yield("redis, no keyspace", backend, backend)

    backend2, = redis_backend
    yield("redis, keyspaced", backend2, backend2.scoped(ks))
  end

  # --- 1. the documented Moneta surface actually exists --------------------

  # The README has documented `Parse.cache["key"] = value` and `.fetch` for
  # years. Neither `[]=` nor `fetch` existed on Parse::Cache::Redis or on the
  # scoped view, so anyone following the documentation got NoMethodError.
  def test_documented_moneta_methods_work_on_every_shape
    each_store_shape do |label, _raw, store|
      store["k"] = "v"
      assert_equal "v", store["k"], "#{label}: []= then [] must round-trip"
      assert_equal "v", store.fetch("k"), "#{label}: fetch hit"
      assert_equal "d", store.fetch("absent", "d"), "#{label}: fetch default"
      assert_equal "gen", store.fetch("absent") { "gen" }, "#{label}: fetch block"
      assert_equal "v", store.load("k"), "#{label}: load"
      assert_equal ["v", nil], store.values_at("k", "absent"), "#{label}: values_at"
      # Pairs, not a Hash: that is Moneta's shape and the point is to match it.
      assert_equal [["k", "v"]], store.slice("k", "absent"), "#{label}: slice"

      store.merge!({ "a" => "1", "b" => "2" })
      assert_equal [["a", "1"], ["b", "2"]], store.slice("a", "b"), "#{label}: merge!"

      store.store("t", "ttl-value", expires: 60)
      assert_equal "ttl-value", store["t"], "#{label}: store with expires"

      assert store.key?("k"), "#{label}: key?"
      store.delete("k")
      refute store.key?("k"), "#{label}: delete"
    end
  end

  # Derived-only. Capabilities that need real backend support must stay
  # feature-detected, or a `respond_to?` check becomes a runtime error.
  def test_backend_capabilities_are_not_claimed_unconditionally
    moneta = Moneta.new(:Memory)
    view = Parse::Cache::KeyspacedStore.new(store: moneta, keyspace: keyspace)
    refute view.respond_to?(:expire), "expire must not be claimed without backend support"

    backend, = redis_backend
    assert backend.scoped(keyspace).respond_to?(:increment), "a capable backend must expose increment"
    assert backend.scoped(keyspace).respond_to?(:expire), "a capable backend must expose expire"
  end

  # Moneta defines every optional method on every store and has unsupported
  # ones raise NotImplementedError, so `respond_to?(:each_key)` is TRUE on a
  # Null store while calling it raises. Advertising capabilities on that basis
  # made the wrapper claim each_key, create, and increment for a store with
  # none of them, and a scoped clear leaked NotImplementedError instead of the
  # refusal this class promises.
  def test_capabilities_follow_supports_not_respond_to
    ks = keyspace
    null = Moneta.new(:Null)
    assert null.respond_to?(:each_key), "precondition: Moneta advertises the method"
    refute null.supports?(:each_key), "precondition: but does not support it"

    view = Parse::Cache::KeyspacedStore.new(store: null, keyspace: ks)
    refute view.respond_to?(:each_key), "must not advertise an unsupported capability"
    refute view.respond_to?(:create)
    refute view.respond_to?(:increment)

    # Must refuse, not leak NotImplementedError.
    assert_raises(Parse::Cache::UnscopedClearRefused) { view.clear }
  end

  def test_capabilities_are_kept_for_a_store_that_really_has_them
    view = Parse::Cache::KeyspacedStore.new(store: Moneta.new(:Memory), keyspace: keyspace)
    assert view.respond_to?(:each_key)
    assert view.respond_to?(:create)
    assert view.respond_to?(:increment)
  end

  # `delete` used to be called with options and retried on ArgumentError.
  # A store's own argument validation raises ArgumentError too, so a genuine
  # rejection was retried instead of surfaced, and the retry meant the
  # deletion could run TWICE. Arity is decided once, at construction.
  def test_delete_is_not_retried_on_a_genuine_argument_error
    calls = 0
    bare = Object.new
    bare.define_singleton_method(:[]) { |_k| nil }
    bare.define_singleton_method(:key?) { |_k| false }
    bare.define_singleton_method(:store) { |_k, _v, _o = {}| nil }
    bare.define_singleton_method(:delete) do |_k, _o = {}|
      calls += 1
      raise ArgumentError, "the store rejects this key"
    end

    view = Parse::Cache::KeyspacedStore.new(store: bare, keyspace: keyspace)
    assert_raises(ArgumentError) { view.delete("k") }
    assert_equal 1, calls, "a rejected delete must not be attempted a second time"
  end

  # --- 2. application keys keep their physical names -----------------------

  # An application writing through the configured store must find its key
  # under the name it used, not relocated under `parse-stack:...`.
  #
  # "The name it used" means the logical key: what the physical bytes are is
  # the store's business, and a Moneta adapter with a key serializer is free
  # to rewrite them. Verified against a live Redis that this wrapper writes
  # String keys through unchanged, which is what makes the SCAN patterns in
  # scoped clearing correct, but the guarantee the SDK owes an application is
  # about the logical key.
  def test_application_keys_keep_their_original_physical_names
    backend, node = redis_backend
    backend["my-app-key"] = "mine"

    assert_includes node.data.keys, "my-app-key",
                    "the application's key must be stored under its own name"
    refute node.data.keys.any? { |k| k.start_with?("parse-stack:") && k.include?("my-app-key") },
           "the application's key must not be relocated into the SDK keyspace"
  end

  # --- 3. clear_cache! spares application keys ----------------------------

  # Through the actual public entry point, not the view directly: what an
  # application calls is `client.clear_cache!`.
  def test_client_clear_cache_preserves_application_keys_when_keyspaced
    store = Moneta.new(:Memory)
    client = Parse::Client.new(
      server_url: SERVER, application_id: "appA", api_key: "k",
      cache: store, expires: 10, cache_keyspace: true,
    )

    store["app-key"] = "app-value"
    client.sdk_cache.roles.set("userA", ["role:Admin"]) if client.sdk_cache.respond_to?(:roles)
    sdk_key = "#{client.sdk_cache.keyspace.root_prefix}:cache:probe:anon"
    client.sdk_cache.store(sdk_key, "cached", {})

    client.clear_cache!

    assert_equal "app-value", store["app-key"],
                 "clear_cache! must not reach application keys"
    assert_nil store[sdk_key], "the SDK's own key must be gone"
  end

  # Without the opt-in there is no keyspace to confine the clear to, so
  # `clear_cache!` keeps its historical whole-store meaning. This is the
  # caveat the README has to state plainly rather than implying protection is
  # unconditional.
  def test_client_clear_cache_is_whole_store_without_a_keyspace
    store = Moneta.new(:Memory)
    client = Parse::Client.new(
      server_url: SERVER, application_id: "appA", api_key: "k",
      cache: store, expires: 10,
    )

    store["app-key"] = "app-value"
    client.clear_cache!

    assert_nil store["app-key"],
               "without cache_keyspace: true, clear_cache! still clears everything"
  end

  def test_sdk_clear_removes_sdk_keys_and_preserves_application_keys
    backend, node = redis_backend
    view = backend.scoped(keyspace)

    backend["app-key"] = "app-value"
    view.roles.set("userA", ["role:Admin"])
    view.store(view.keyspace.cache_key("https://x/1", auth: :anon), "cached", {})

    view.clear

    assert_equal "app-value", backend["app-key"],
                 "clearing the SDK's slice must not touch application keys"
    assert_nil view.roles.get("userA"), "the SDK's own keys must be gone"
    refute node.data.keys.any? { |k| k.start_with?("parse-stack:v") },
           "no keyspaced SDK key may survive"
  end

  # The raw store's own clear is the blunt instrument and stays reachable
  # deliberately.
  def test_raw_store_clear_is_total_without_a_namespace
    backend, node = redis_backend
    backend["app-key"] = "app-value"
    backend.scoped(keyspace).roles.set("userA", ["role:Admin"])

    backend.clear

    assert_empty node.data, "client.cache.clear is a whole-store operation"
  end

  # But NOT when the wrapper carries a namespace: then `clear` scan-deletes
  # `<namespace>:*` and leaves everything else alone. Calling it FLUSHDB
  # unconditionally is wrong in both directions, since it overstates the
  # danger here and understates it for `flush_db!`.
  def test_raw_store_clear_is_namespace_scoped_when_a_namespace_is_set
    node = FakeRedisNode.new
    backend = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", namespace: "web")
    backend.instance_variable_set(:@pool, Parse::Cache::Pool.new(size: 1) { node })

    node.store("web:mine", "scoped", {})
    node.store("documents:post:1", "outside", {})

    backend.clear

    assert_nil node.data["web:mine"], "the namespace's own keys go"
    assert_equal "outside", node.data["documents:post:1"],
                 "keys outside the namespace survive a namespaced clear"
  end

  # flush_db! is the genuinely total operation.
  def test_flush_db_is_the_total_operation
    node = FakeRedisNode.new
    backend = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", namespace: "web")
    backend.instance_variable_set(:@pool, Parse::Cache::Pool.new(size: 1) { node })

    node.store("web:mine", "scoped", {})
    node.store("documents:post:1", "outside", {})

    backend.flush_db!

    assert_empty node.data, "flush_db! takes the whole database"
  end

  # The documented difference between store types when `family:` is misrouted.
  # Parse::Cache::Redis refuses; a plain Moneta store accepts the hash as
  # options, ignores the key it does not recognize, and clears EVERYTHING
  # while returning normally. The quiet outcome is the non-Redis one, which is
  # why the docs have to name the store type rather than promise a refusal.
  def test_misrouted_family_clear_refuses_on_redis_but_not_on_plain_moneta
    backend, = redis_backend
    assert_raises(ArgumentError) { backend.clear(family: :role) }

    moneta = Moneta.new(:Memory)
    moneta["a"] = 1
    moneta["b"] = 2
    moneta.clear(family: :role)
    assert_equal 0, moneta.each_key.to_a.size,
                 "a plain Moneta store silently clears everything"
  end

  # --- 4. two views cannot clear each other -------------------------------

  def test_two_client_views_cannot_clear_each_other
    backend, = redis_backend
    view_a = backend.scoped(keyspace(app_id: "appA"))
    view_b = backend.scoped(keyspace(app_id: "appB"))

    view_a.roles.set("u", ["role:A"])
    view_b.roles.set("u", ["role:B"])

    view_a.clear

    assert_nil view_a.roles.get("u")
    assert_equal ["role:B"], view_b.roles.get("u"),
                 "one client's clear must never reach another client's keys"
  end

  # Option-carrying reads must reach the backing store, not recurse.
  # `load` derived from `[]` consulting a backing store that defaulted to
  # `self` asked whether self responded to the method it was executing, so
  # `load(key, expires: 60)` blew the stack. Everything below routes through
  # `load`, so all of it went the same way.
  def test_option_carrying_reads_do_not_recurse
    each_store_shape do |label, _raw, store|
      store["k"] = "v"
      assert_equal "v", store.load("k", expires: 60), "#{label}: load with options"
      assert_equal "v", store.fetch("k", expires: 60), "#{label}: fetch with options"
      assert_equal ["v"], store.values_at("k", expires: 60), "#{label}: values_at with options"
      assert_equal [["k", "v"]], store.slice("k", expires: 60), "#{label}: slice with options"
      assert_equal ["v"], store.fetch_values("k", expires: 60) { "d" }, "#{label}: fetch_values"
    end
  end

  # Moneta reads the second positional differently depending on the block.
  # Without one it is the default value; with one it is the OPTIONS hash and
  # the block supplies the fallback. Treating it as a default in both cases
  # silently dropped the options.
  def test_fetch_matches_monetas_two_argument_shapes
    each_store_shape do |label, _raw, store|
      store["k"] = "v"
      assert_equal "v", (store.fetch("k", expires: 60) { "blk" }),
                   "#{label}: a hash before a block is options, and the hit wins"
      assert_equal "blk", (store.fetch("absent", expires: 60) { "blk" }),
                   "#{label}: the block supplies the miss value"
      assert_equal({ expires: 60 }, store.fetch("absent", expires: 60),
                   "#{label}: without a block the same hash is the default")
    end
  end

  # store and delete return the VALUE, as Moneta does. Parse::Cache::Redis
  # JSON-encodes on the way in, and used to hand that encoded string back, so
  # `store` and `delete` returned `"{\"a\":1}"` where every read returned
  # `{"a" => 1}`.
  def test_store_and_delete_return_decoded_values_not_encoded_ones
    backend, = redis_backend
    value = { "a" => 1 }

    assert_equal value, backend.store("k", value, {}), "store must return the value it was given"
    assert_equal value, backend["k"], "and the read must agree with it"
    assert_equal value, backend.delete("k"), "delete must return the decoded value"
  end

  # --- 5. the configured store stays reachable ----------------------------

  # The regression that motivated the split: `cache_keyspace: true` used to
  # overwrite `client.cache` with the view, so the object the application
  # passed in was unreachable.
  def test_configured_store_remains_reachable_as_cache
    store = Moneta.new(:Memory)
    client = Parse::Client.new(
      server_url: SERVER, application_id: "appA", api_key: "k",
      cache: store, expires: 10, cache_keyspace: true,
    )

    assert_same store, client.cache,
                "client.cache must be exactly the store that was configured"
    refute_same store, client.sdk_cache,
                "sdk_cache must be the keyspaced view, not the raw store"
    assert_kind_of Parse::Cache::KeyspacedStore, client.sdk_cache
  end

  # Without the option there is no view to hold, and the two are the same
  # object, so nothing about an existing deployment changes.
  def test_sdk_cache_is_the_store_itself_without_a_keyspace
    store = Moneta.new(:Memory)
    client = Parse::Client.new(
      server_url: SERVER, application_id: "appA", api_key: "k",
      cache: store, expires: 10,
    )

    assert_same store, client.cache
    assert_same store, client.sdk_cache
  end

  # `Parse.cache` memoized the first default client's store forever, so a
  # later Parse.setup kept returning the previous client's cache with no way
  # to reset it.
  def test_module_level_cache_is_not_memoized_across_clients
    first = Moneta.new(:Memory)
    Parse.setup(server_url: SERVER, application_id: "appA", api_key: "k",
                cache: first, expires: 10)
    assert_same first, Parse.cache

    second = Moneta.new(:Memory)
    Parse.setup(server_url: SERVER, application_id: "appB", api_key: "k",
                cache: second, expires: 10)
    assert_same second, Parse.cache,
                "Parse.cache must follow the current default client"
  end
end
