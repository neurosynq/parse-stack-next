# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/cache/keyspace"

# Tests for Parse::Cache::ScopedView, the immutable per-client view that
# replaces the old mutable Parse::Cache::Redis#keyspace= binding.
#
# The defect this closes: one Parse::Cache::Redis backend shared by two
# Parse::Client instances used to let the second client's `keyspace=` rebind
# the ONE `@keyspace` ivar out from under the first. Client A's caching
# middleware kept using A's captured keyspace object while `clear`,
# `identity`, `roles`, and the memoized `upstream_roles` on the shared
# backend answered with B's. A stopped invalidating its own entries, and a
# scoped clear issued through A could delete B's keys.
#
# `Parse::Cache::Redis#scoped(keyspace)` now hands back one of these per
# caller instead, each carrying its own keyspace and its own memoized planes,
# so two views over the same backend can never step on each other.
class CacheScopedViewTest < Minitest::Test
  APP_A = "appA"
  APP_B = "appB"
  SERVER = "https://api.example.com/parse"

  # A minimal redis-rb-shaped double that backs both the Moneta store the
  # Faraday middleware writes through AND the SCAN-capable node
  # `Parse::Cache::Redis` reaches for on eviction / locking, all against one
  # shared in-memory Hash. This lets a real `Parse::Cache::Redis` (and
  # therefore real `Parse::Cache::ScopedView` instances built from `#scoped`)
  # be exercised end to end without a live Redis.
  class FakeRedisNode
    def initialize
      @data = {}
      @ttl = {}
    end

    # -- Moneta surface (raw storage; Parse::Cache::Redis handles JSON
    #    encoding on top of this) --
    def [](key) = @data[key]
    def key?(key) = @data.key?(key)
    def delete(key) = @data.delete(key)
    def store(key, value, _options = {}) = (@data[key] = value)

    def create(key, value, _options = {})
      return false if @data.key?(key)
      @data[key] = value
      true
    end

    def increment(key, amount = 1, _options = {})
      @data[key] = (@data[key] || 0).to_i + amount
    end

    # -- redis-rb-shaped surface (SCAN eviction + raw locks) --
    def backend
      self
    end

    def scan(_cursor, match:, count: 1000)
      ["0", @data.keys.select { |k| File.fnmatch(match, k, File::FNM_NOESCAPE) }]
    end

    def unlink(*keys) = keys.each { |k| @data.delete(k) }
    def del(*keys) = keys.each { |k| @data.delete(k) }

    def set(key, value, nx: false, ex: nil)
      return nil if nx && @data.key?(key)
      @data[key] = value
      @ttl[key] = ex
      "OK"
    end

    def get(key) = @data[key]

    # Emulates Parse::Cache::Redis::LOCK_RELEASE_SCRIPT (compare-and-delete).
    def eval(_script, keys:, argv:)
      key = keys.first
      if @data[key] == argv.first
        @data.delete(key)
        1
      else
        0
      end
    end

    def keys = @data.keys.dup
  end

  def build_backend
    node = FakeRedisNode.new
    backend = Parse::Cache::Redis.new(url: "redis://localhost:6379/0")
    backend.instance_variable_set(:@pool, Parse::Cache::Pool.new(size: 1) { node })
    [backend, node]
  end

  def keyspace(app_id: APP_A, namespace: nil)
    Parse::Cache::Keyspace.new(app_id: app_id, server_url: SERVER, namespace: namespace)
  end

  # --- deriving views ------------------------------------------------------

  def test_scoped_returns_a_scoped_view
    backend, = build_backend
    view = backend.scoped(keyspace)
    assert_kind_of Parse::Cache::ScopedView, view
    assert_equal keyspace, view.keyspace
  end

  def test_scoped_rejects_a_non_keyspace
    backend, = build_backend
    assert_raises(ArgumentError) { backend.scoped("not-a-keyspace") }
  end

  def test_two_views_derived_from_one_backend_have_independent_keyspaces
    backend, = build_backend
    view_a = backend.scoped(keyspace(app_id: APP_A))
    view_b = backend.scoped(keyspace(app_id: APP_B))

    refute_equal view_a.keyspace, view_b.keyspace
    assert_same backend, view_a.backend
    assert_same backend, view_b.backend, "both views must share the SAME backend connection pool"
  end

  # There is no setter at all now: rebinding is not merely guarded, it is
  # impossible.
  def test_view_keyspace_has_no_setter
    backend, = build_backend
    view = backend.scoped(keyspace)
    refute_respond_to view, :keyspace=
  end

  # The removal this test guards: Parse::Cache::Redis must never again expose
  # a way to mutate a keyspace binding shared by more than one caller.
  def test_backend_does_not_respond_to_keyspace_setter
    backend, = build_backend
    refute_respond_to backend, :keyspace=
    refute_respond_to backend, :keyspace
  end

  # --- the actual bug: cross-client isolation on clear ----------------------

  def test_client_a_view_cannot_clear_client_bs_keys
    backend, = build_backend
    view_a = backend.scoped(keyspace(app_id: APP_A))
    view_b = backend.scoped(keyspace(app_id: APP_B))

    view_a.store(view_a.keyspace.cache_key("https://x/1", auth: :anon), "a-value", {})
    view_b.store(view_b.keyspace.cache_key("https://x/1", auth: :anon), "b-value", {})

    view_a.clear

    assert_nil view_a[view_a.keyspace.cache_key("https://x/1", auth: :anon)],
               "A's clear must remove A's own entry"
    refute_nil view_b[view_b.keyspace.cache_key("https://x/1", auth: :anon)],
               "A's clear must NEVER remove B's entry"
  end

  def test_client_b_view_cannot_clear_client_as_keys
    backend, = build_backend
    view_a = backend.scoped(keyspace(app_id: APP_A))
    view_b = backend.scoped(keyspace(app_id: APP_B))

    view_a.store(view_a.keyspace.cache_key("https://x/1", auth: :anon), "a-value", {})
    view_b.store(view_b.keyspace.cache_key("https://x/1", auth: :anon), "b-value", {})

    view_b.clear

    assert_nil view_b[view_b.keyspace.cache_key("https://x/1", auth: :anon)],
               "B's clear must remove B's own entry"
    refute_nil view_a[view_a.keyspace.cache_key("https://x/1", auth: :anon)],
               "B's clear must NEVER remove A's entry"
  end

  def test_clear_with_family_stays_within_the_calling_views_keyspace
    backend, = build_backend
    view_a = backend.scoped(keyspace(app_id: APP_A))
    view_b = backend.scoped(keyspace(app_id: APP_B))

    view_a.roles.set("userA", ["role:Admin"])
    view_b.roles.set("userA", ["role:Admin"])

    view_a.clear(family: :role)

    assert_nil view_a.roles.get("userA")
    assert_equal ["role:Admin"], view_b.roles.get("userA"),
                 "clearing A's role family must not touch B's role plane"
  end

  # The bare backend has no keyspace and therefore no root_prefix to resolve a
  # family against. It used to accept `family:` and silently ignore it, which
  # fell through to the unnamespaced branch and issued FLUSHDB: a request to
  # clear ONE family wiped the whole database, taking every other family,
  # every other app sharing the backend, and the `parse-stack:foc:v1:*`
  # create-locks whose loss silently removes `first_or_create!` mutual
  # exclusion. A request to narrow must never widen.
  def test_bare_backend_refuses_family_rather_than_flushing_the_database
    backend, node = build_backend
    backend.scoped(keyspace(app_id: APP_A)).roles.set("userA", ["role:Admin"])
    before = node.keys.size

    assert_raises(ArgumentError) { backend.clear(family: :role) }
    assert_raises(ArgumentError) { backend.clear(tenant: "acme") }

    assert_equal before, node.keys.size, "the refused clear must not have deleted anything"
  end

  # --- KeyspacedStore: the non-scopable fallback ---------------------------

  # A store that cannot enumerate its keys cannot clear within a keyspace, and
  # the only alternative is the database-wide clear this wrapper exists to
  # prevent. It refuses instead.
  def test_keyspaced_store_refuses_a_clear_it_cannot_scope
    bare = Object.new
    %i[[] key? delete store].each { |m| bare.define_singleton_method(m) { |*| nil } }
    wrapper = Parse::Cache::KeyspacedStore.new(store: bare, keyspace: keyspace)

    assert_raises(Parse::Cache::UnscopedClearRefused) { wrapper.clear }
  end

  # The refusal message tells the operator how to take the unscoped clear
  # deliberately, so the method it names has to exist and be callable with no
  # arguments. It previously named `client.cache.store.clear`, but `store` is
  # Moneta's writer and needs a key and a value, so anyone following the
  # advice got an ArgumentError instead of a clear.
  def test_refusal_message_names_a_method_that_actually_works
    cleared = false
    bare = Object.new
    %i[[] key? delete store].each { |m| bare.define_singleton_method(m) { |*| nil } }
    bare.define_singleton_method(:clear) { cleared = true }
    wrapper = Parse::Cache::KeyspacedStore.new(store: bare, keyspace: keyspace)

    message = assert_raises(Parse::Cache::UnscopedClearRefused) { wrapper.clear }.message
    assert_includes message, "wrapped.clear"

    wrapper.wrapped.clear
    assert cleared, "the method the message names must reach the wrapped store's clear"
  end

  # An enumerable store gets a real scoped clear, deleting only what sits
  # under this keyspace.
  def test_keyspaced_store_clears_only_its_own_keys
    data = {
      "#{keyspace.root_prefix}:cache:mine" => 1,
      "someone-elses-key" => 2,
    }
    bare = Object.new
    bare.define_singleton_method(:[]) { |k| data[k] }
    bare.define_singleton_method(:key?) { |k| data.key?(k) }
    bare.define_singleton_method(:delete) { |k| data.delete(k) }
    bare.define_singleton_method(:store) { |k, v, _o = {}| data[k] = v }
    bare.define_singleton_method(:each_key) { |&blk| data.keys.each(&blk) }

    Parse::Cache::KeyspacedStore.new(store: bare, keyspace: keyspace).clear

    assert_equal ["someone-elses-key"], data.keys
  end

  # --- delete_matching refuses foreign patterns -----------------------------

  def test_delete_matching_refuses_a_pattern_belonging_to_another_view
    backend, = build_backend
    view_a = backend.scoped(keyspace(app_id: APP_A))
    view_b = backend.scoped(keyspace(app_id: APP_B))

    view_b.store(view_b.keyspace.cache_key("https://x/1", auth: :anon), "b-value", {})
    foreign_pattern = view_b.keyspace.pattern

    assert_equal 0, view_a.delete_matching(foreign_pattern),
                 "a view must refuse to delete_matching outside its own root_prefix"
    refute_nil view_b[view_b.keyspace.cache_key("https://x/1", auth: :anon)],
               "B's entry must survive A's rejected delete_matching call"
  end

  # Regression test: a bare string-prefix check (no segment boundary) would
  # let a view whose namespace is "foo" accept a pattern belonging to a
  # DIFFERENT namespace "foobar", since "...:foobar:..." starts with the
  # characters "...:foo". delete_matching must require the `:` boundary
  # after root_prefix, not just a string prefix match.
  def test_delete_matching_refuses_a_namespace_that_merely_shares_a_prefix
    backend, = build_backend
    view_foo = backend.scoped(keyspace(namespace: "foo"))
    view_foobar = backend.scoped(keyspace(namespace: "foobar"))

    refute view_foobar.keyspace.root_prefix == view_foo.keyspace.root_prefix
    assert view_foobar.keyspace.root_prefix.start_with?(view_foo.keyspace.root_prefix),
           "test setup requires a genuine string-prefix collision between the two root_prefixes"

    key = view_foobar.keyspace.cache_key("https://x/1", auth: :anon)
    view_foobar.store(key, "foobar-value", {})

    assert_equal 0, view_foo.delete_matching(view_foobar.keyspace.pattern),
                 "namespace 'foo' must not be able to delete_matching against namespace 'foobar'"
    refute_nil view_foobar[key], "foobar's entry must survive foo's rejected delete_matching call"
  end

  def test_delete_matching_accepts_its_own_pattern
    backend, = build_backend
    view = backend.scoped(keyspace)
    key = view.keyspace.cache_key("https://x/1", auth: :anon)
    view.store(key, "value", {})

    deleted = view.delete_matching(view.keyspace.pattern)
    assert_equal 1, deleted
    assert_nil view[key]
  end

  def test_delete_matching_is_inert_on_nil_or_empty_pattern
    backend, = build_backend
    view = backend.scoped(keyspace)
    assert_equal 0, view.delete_matching(nil)
    assert_equal 0, view.delete_matching("")
  end

  # --- per-view memoized identity / roles / upstream_roles ------------------

  def test_identity_roles_and_upstream_roles_are_distinct_per_view
    backend, = build_backend
    view_a = backend.scoped(keyspace(app_id: APP_A))
    view_b = backend.scoped(keyspace(app_id: APP_B))

    refute_same view_a.identity, view_b.identity
    refute_same view_a.roles, view_b.roles

    # Memoized: repeated calls on the SAME view return the SAME instance.
    assert_same view_a.identity, view_a.identity
    assert_same view_a.roles, view_a.roles
  end

  def test_identity_and_roles_are_bound_to_their_own_views_keyspace
    backend, = build_backend
    view_a = backend.scoped(keyspace(app_id: APP_A))
    view_b = backend.scoped(keyspace(app_id: APP_B))

    view_a.roles.set("userX", ["role:Admin"])
    assert_equal ["role:Admin"], view_a.roles.get("userX")
    assert_nil view_b.roles.get("userX"), "B's role plane must not see A's entry"
  end

  def test_upstream_roles_is_nil_without_a_parse_cache_url
    backend, = build_backend
    view = backend.scoped(keyspace)
    assert_nil view.upstream_roles
  end

  def test_upstream_roles_is_memoized_and_distinct_per_view
    node = FakeRedisNode.new
    backend = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", parse_cache_url: "redis://localhost:6379/1")
    backend.instance_variable_set(:@pool, Parse::Cache::Pool.new(size: 1) { node })
    # Stub the raw redis-rb client the upstream reader is built with so this
    # test never attempts a real network connection.
    fake_upstream_client = Object.new
    backend.instance_variable_set(:@upstream_client, fake_upstream_client)

    view_a = backend.scoped(keyspace(app_id: APP_A))
    view_b = backend.scoped(keyspace(app_id: APP_B))

    refute_nil view_a.upstream_roles
    refute_same view_a.upstream_roles, view_b.upstream_roles
    assert_same view_a.upstream_roles, view_a.upstream_roles, "must be memoized per view"
    assert_equal APP_A, view_a.upstream_roles.app_id
    assert_equal APP_B, view_b.upstream_roles.app_id
  end

  # --- Moneta interface ------------------------------------------------------

  def test_view_satisfies_the_moneta_interface_the_middleware_requires
    backend, = build_backend
    view = backend.scoped(keyspace)
    [:[], :key?, :delete, :store].each do |method|
      assert_respond_to view, method
    end
  end

  def test_view_round_trips_a_value_through_the_shared_backend
    backend, = build_backend
    view = backend.scoped(keyspace)
    view.store("some-key", "some-value", {})
    assert view.key?("some-key")
    assert_equal "some-value", view["some-key"]
    view.delete("some-key")
    refute view.key?("some-key")
  end

  def test_view_exposes_create_when_the_backend_supports_it
    backend, = build_backend
    view = backend.scoped(keyspace)
    assert_respond_to view, :create
    assert_equal true, view.create("lockish-key", "v", {})
    assert_equal false, view.create("lockish-key", "v2", {})
  end

  # --- flush_db! is not exposed on the view ----------------------------------

  def test_flush_db_bang_is_not_available_on_the_view
    backend, = build_backend
    view = backend.scoped(keyspace)
    refute_respond_to view, :flush_db!
  end

  # --- locks are NOT scoped: same key regardless of which view acquires it --

  def test_lock_key_is_identical_through_either_view
    backend, node = build_backend
    view_a = backend.scoped(keyspace(app_id: APP_A))
    view_b = backend.scoped(keyspace(app_id: APP_B))

    lock_key = "parse-stack:foc:v1:#{Digest::SHA256.hexdigest("shared-lock")}"

    assert view_a.lock_acquire(lock_key, "owner-a", 30)
    # The SAME physical key is now held; a second acquire attempt (even from
    # the other view) must see it as already taken, proving both views write
    # through to one unscoped key rather than two keyspaced ones.
    refute view_b.lock_acquire(lock_key, "owner-b", 30)

    assert view_a.lock_release(lock_key, "owner-a")
    assert node.instance_variable_get(:@data)[lock_key].nil?
  end

  def test_scoped_clear_does_not_delete_a_lock_key
    backend, = build_backend
    view = backend.scoped(keyspace)

    lock_key = "parse-stack:foc:v1:#{Digest::SHA256.hexdigest("survives-clear")}"
    assert view.lock_acquire(lock_key, "owner", 30)

    # A scoped clear over the whole keyspace must never reach outside its own
    # root_prefix, and the lock prefix is deliberately outside every keyspace
    # root_prefix (see Parse::Cache::Keyspace's own docs on this).
    view.clear

    assert view.lock_release(lock_key, "owner"),
           "the lock key must have survived the scoped clear so release still finds it"
  end

  def test_lock_release_via_either_view_reaches_the_same_key
    backend, = build_backend
    view_a = backend.scoped(keyspace(app_id: APP_A))
    view_b = backend.scoped(keyspace(app_id: APP_B))

    lock_key = "parse-stack:foc:v1:#{Digest::SHA256.hexdigest("cross-view-release")}"
    assert view_a.lock_acquire(lock_key, "owner-a", 30)
    # Releasing through a DIFFERENT view still works, since locks are not
    # partitioned by keyspace at all.
    assert view_b.lock_release(lock_key, "owner-a")
  end
end
