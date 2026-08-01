# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/cache/keyspace"
require "parse/cache/sub_cache"
require "parse/cache/invalidation"
require "redis"

# Tests that the SDK's own webhook triggers invalidate the identity and role
# planes, replacing the previous contract where applications had to remember to
# call Session.invalidate / invalidate_user_roles from their own code paths.
class CacheInvalidationTest < Minitest::Test
  APP = "myAppId"
  SERVER = "https://api.example.com/parse"

  class FakeStore
    attr_reader :data
    def initialize = @data = {}
    def [](k) = @data[k]
    def key?(k) = @data.key?(k)
    def delete(k) = @data.delete(k)
    def store(k, v, _o = {}) = @data[k] = v

    def delete_matching(pattern)
      doomed = @data.keys.select { |k| File.fnmatch(pattern, k, File::FNM_NOESCAPE) }
      doomed.each { |k| @data.delete(k) }
      doomed.size
    end
  end

  # Stands in for Parse::Cache::Redis with both planes.
  class FakeCache
    attr_reader :identity, :roles

    def initialize(store, keyspace)
      @identity = Parse::Cache::SubCache.new(store: store, keyspace: keyspace, family: :idn, ttl: 3600)
      @roles = Parse::Cache::SubCache.new(store: store, keyspace: keyspace, family: :role, ttl: 30)
    end
  end

  def setup
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    @store = FakeStore.new
    @keyspace = Parse::Cache::Keyspace.new(app_id: APP, server_url: SERVER)
    @cache = FakeCache.new(@store, @keyspace)
    Parse::Cache::Invalidation.install!(@cache)
  end

  def teardown
    Parse::Webhooks.instance_variable_set(:@routes, nil)
  end

  def fire(type, class_name, payload)
    handlers = Parse::Webhooks.routes[type][class_name]
    Array(handlers).each { |h| h.call(payload) }
  end

  # Minimal payload doubles: only what the invalidation handlers read.
  FakeUser = Struct.new(:id)
  FakeSessionObject = Struct.new(:user)
  FakePayload = Struct.new(:parse_object, :parse_class, :session_token)

  def user_payload(user_id)
    FakePayload.new(FakeUser.new(user_id), Parse::Model::CLASS_USER, nil)
  end

  # --- registration -------------------------------------------------------

  def test_installs_all_five_triggers
    assert Parse::Webhooks.routes[:after_save]["_Role"]
    assert Parse::Webhooks.routes[:after_delete]["_Role"]
    assert Parse::Webhooks.routes[:after_save]["_User"]
    assert Parse::Webhooks.routes[:after_delete]["_User"]
    assert Parse::Webhooks.routes[:after_logout]["_Session"]
  end

  def test_install_rejects_a_cache_without_planes
    assert_raises(ArgumentError) { Parse::Cache::Invalidation.install!(Object.new) }
  end

  # Registration must not clobber an application's own handler.
  def test_composes_with_an_application_handler
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    called = false
    Parse::Webhooks.route(:after_logout, "_Session") { called = true }
    Parse::Cache::Invalidation.install!(@cache)
    fire(:after_logout, "_Session", FakePayload.new(nil, nil, "r:tok"))
    assert called, "the application's handler must still run"
  end

  # --- role plane ---------------------------------------------------------

  def test_role_save_clears_the_role_plane
    @cache.roles.set("userA", ["role:Admin"])
    fire(:after_save, "_Role", FakePayload.new(nil, "_Role", nil))
    assert_nil @cache.roles.get("userA")
  end

  def test_role_delete_clears_the_role_plane
    @cache.roles.set("userA", ["role:Admin"])
    fire(:after_delete, "_Role", FakePayload.new(nil, "_Role", nil))
    assert_nil @cache.roles.get("userA")
  end

  # Parse Server does not clear its own role cache on a _Role delete, so
  # clearing ours is not enough: the epoch is what lets a read reject their
  # stale entry rather than taking the deleted role back.
  def test_role_mutation_advances_the_epoch
    before = @cache.roles.epoch
    fire(:after_delete, "_Role", FakePayload.new(nil, "_Role", nil))
    assert_operator @cache.roles.epoch, :>, before
  end

  def test_role_clear_does_not_touch_identity
    @cache.identity.set("tok", "user123")
    fire(:after_save, "_Role", FakePayload.new(nil, "_Role", nil))
    assert_equal "user123", @cache.identity.get("tok")
  end

  # --- identity plane -----------------------------------------------------

  def test_user_save_bumps_that_users_generation
    assert_equal 0, @cache.identity.generation("user123")
    fire(:after_save, "_User", user_payload("user123"))
    assert_equal 1, @cache.identity.generation("user123")
  end

  def test_user_delete_bumps_that_users_generation
    fire(:after_delete, "_User", user_payload("user123"))
    assert_equal 1, @cache.identity.generation("user123")
  end

  def test_user_write_does_not_bump_another_user
    fire(:after_save, "_User", user_payload("user123"))
    assert_equal 0, @cache.identity.generation("other")
  end

  # --- logout -------------------------------------------------------------

  # Real callers (Parse::AtlasSearch::Session) `set` / `get` the identity
  # plane keyed by the RAW session token. SubCache hashes it internally
  # exactly once (see SubCache#logical_key). The trigger must invalidate
  # with that same raw token so the two agree on the underlying storage
  # key; pre-hashing here before handing SubCache a key it hashes again
  # lands on a key nothing ever wrote to, and logout silently fails to
  # evict the entry.
  def test_logout_invalidates_that_session_token
    @cache.identity.set("r:tok", "user123")
    fire(:after_logout, "_Session", FakePayload.new(nil, "_Session", "r:tok"))
    assert_nil @cache.identity.get("r:tok")
  end

  def test_logout_does_not_invalidate_another_session
    @cache.identity.set("r:other", "user456")
    fire(:after_logout, "_Session", FakePayload.new(nil, "_Session", "r:tok"))
    assert_equal "user456", @cache.identity.get("r:other")
  end

  # A master-key logout carries no requesting user, so no token is available.
  # Fall back to bumping the affected user's generation.
  def test_logout_without_a_token_falls_back_to_the_generation
    payload = FakePayload.new(FakeSessionObject.new(FakeUser.new("user123")), "_Session", nil)
    fire(:after_logout, "_Session", payload)
    assert_equal 1, @cache.identity.generation("user123")
  end

  # These triggers fire after the write has committed, so a cache backend error
  # must not turn an already-successful save into a 500.
  def test_role_trigger_swallows_a_backend_error
    boom = Object.new
    boom.define_singleton_method(:clear) { raise Redis::CommandError, "NOPERM" }
    boom.define_singleton_method(:touch_epoch) { |*| raise Redis::CommandError, "NOPERM" }
    cache = Object.new
    cache.define_singleton_method(:roles) { boom }
    cache.define_singleton_method(:identity) { boom }
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Cache::Invalidation.install!(cache)

    fire(:after_save, "_Role", FakePayload.new(nil, "_Role", nil))
    fire(:after_delete, "_Role", FakePayload.new(nil, "_Role", nil))
  end

  def test_identity_trigger_swallows_a_backend_error
    boom = Object.new
    boom.define_singleton_method(:bump_generation) { |*| raise IOError, "down" }
    boom.define_singleton_method(:invalidate) { |*| raise IOError, "down" }
    cache = Object.new
    cache.define_singleton_method(:roles) { boom }
    cache.define_singleton_method(:identity) { boom }
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Cache::Invalidation.install!(cache)

    fire(:after_save, "_User", user_payload("user123"))
    fire(:after_logout, "_Session", FakePayload.new(nil, "_Session", "r:tok"))
  end

  def test_logout_with_neither_token_nor_user_is_inert
    fire(:after_logout, "_Session", FakePayload.new(nil, "_Session", nil))
    assert_empty @store.data
  end
end
