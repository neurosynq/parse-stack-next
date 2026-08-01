# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/cache/keyspace"
require "parse/cache/sub_cache"

# Unit tests for the identity and role planes. Backed by a plain hash rather
# than Redis, since the behavior under test is key layout, plane isolation, and
# the generation counter, none of which need a server.
class CacheSubCacheTest < Minitest::Test
  APP = "myAppId"
  SERVER = "https://api.example.com/parse"

  # Minimal store with the four methods SubCache uses, plus pattern deletion.
  # Records the options passed to `store` so the TTL tests can assert on the
  # expiry that was actually requested.
  class FakeStore
    attr_reader :data, :options

    def initialize
      @data = {}
      @options = {}
    end

    def [](k) = @data[k]
    def key?(k) = @data.key?(k)
    def delete(k) = @data.delete(k)

    def store(k, v, o = {})
      @options[k] = o
      @data[k] = v
    end

    def delete_matching(pattern)
      doomed = @data.keys.select { |k| File.fnmatch(pattern, k, File::FNM_NOESCAPE) }
      doomed.each { |k| @data.delete(k) }
      doomed.size
    end
  end

  def setup
    @store = FakeStore.new
    @keyspace = Parse::Cache::Keyspace.new(app_id: APP, server_url: SERVER)
    @identity = Parse::Cache::SubCache.new(store: @store, keyspace: @keyspace, family: :idn, ttl: 3600)
    @roles = Parse::Cache::SubCache.new(store: @store, keyspace: @keyspace, family: :role, ttl: 30)
  end

  # --- basic contract -----------------------------------------------------

  def test_round_trips_a_value
    @identity.set("tokendigest", "user123")
    assert_equal "user123", @identity.get("tokendigest")
  end

  def test_miss_returns_nil
    assert_nil @roles.get("nobody")
  end

  def test_invalidate_removes_only_that_key
    @roles.set("userA", ["role:Admin"])
    @roles.set("userB", ["role:Viewer"])
    @roles.invalidate("userA")
    assert_nil @roles.get("userA")
    assert_equal ["role:Viewer"], @roles.get("userB")
  end

  def test_nil_keys_are_inert
    assert_nil @roles.get(nil)
    assert_nil @roles.invalidate(nil)
    @roles.set(nil, "x")
    assert_empty @store.data
  end

  # --- plane isolation ----------------------------------------------------

  def test_planes_do_not_collide_on_the_same_logical_key
    @identity.set("same", "identity-value")
    @roles.set("same", "role-value")
    assert_equal "identity-value", @identity.get("same")
    assert_equal "role-value", @roles.get("same")
  end

  def test_keys_are_written_under_the_right_family
    @roles.set("userA", ["role:Admin"])
    key = @store.data.keys.first
    assert key.start_with?("#{@keyspace.root_prefix}:role:"), key
  end

  def test_clear_evicts_only_its_own_plane
    @identity.set("tok", "user123")
    @roles.set("userA", ["role:Admin"])
    @roles.clear
    assert_nil @roles.get("userA")
    assert_equal "user123", @identity.get("tok"), "clearing roles must not touch identity"
  end

  # --- generation counter -------------------------------------------------

  # A _User write yields a user id, but identity entries are keyed by session
  # token and there is no reverse map. A generation invalidates every entry for
  # that user in O(1), including tokens this process never saw.
  def test_generation_starts_at_zero
    assert_equal 0, @identity.generation("user123")
  end

  def test_bump_increments_and_is_observable
    assert_equal 1, @identity.bump_generation("user123")
    assert_equal 1, @identity.generation("user123")
    assert_equal 2, @identity.bump_generation("user123")
  end

  def test_generation_current_detects_a_stale_value
    stored = { "user_id" => "user123", "gen" => @identity.generation("user123") }
    assert @identity.generation_current?("user123", stored["gen"])
    @identity.bump_generation("user123")
    refute @identity.generation_current?("user123", stored["gen"]),
           "a bumped generation must invalidate a previously captured value"
  end

  def test_generations_are_per_subject
    @identity.bump_generation("userA")
    assert_equal 1, @identity.generation("userA")
    assert_equal 0, @identity.generation("userB")
  end

  def test_generation_key_does_not_collide_with_a_user_id_entry
    @identity.set("gen", "not-a-generation")
    @identity.bump_generation("gen")
    assert_equal "not-a-generation", @identity.get("gen")
    assert_equal 1, @identity.generation("gen")
  end

  def test_plane_clear_also_removes_generations
    @identity.bump_generation("user123")
    @identity.clear
    assert_equal 0, @identity.generation("user123")
  end

  def test_nil_subject_is_inert
    assert_equal 0, @identity.bump_generation(nil)
    assert_equal 0, @identity.generation(nil)
  end

  # --- generation keys must not accumulate forever -------------------------

  # One generation key per user id, written on every `_User` webhook, is
  # unbounded Redis growth on a public signup flow: every account that ever
  # saves leaves a permanent key behind.
  def test_generation_key_carries_an_expiry
    @identity.bump_generation("user123")
    key = @store.options.keys.find { |k| k.include?(":gen:") }
    refute_nil key, "the bump must have written a generation key"
    assert_equal 7200, @store.options[key][:expires],
                 "generation keys must expire, at twice the plane's entry TTL"
  end

  # The TTL is not free to choose. Expiry resets the counter to 0, and 0 is
  # also the value for a user who has never been bumped, so a generation that
  # outlived its entries would let an entry written at generation 0 compare
  # current again and come back after having been invalidated. Twice the entry
  # TTL guarantees every such entry is gone first.
  def test_generation_outlives_the_entries_it_guards
    assert_operator @identity.generation_ttl, :>, 3600
    assert_operator @roles.generation_ttl, :>, 30
  end

  # A caller passing a longer per-call TTL would reopen exactly that window,
  # so the plane clamps it. Shortening is the safe direction: the cost is one
  # extra resolution, against a session that stays resolvable after being
  # invalidated.
  def test_set_clamps_a_ttl_longer_than_the_plane_default
    @identity.set("tok", "user123", ttl: 999_999)
    key = @store.options.keys.find { |k| k.include?(":idn:") && !k.include?(":gen:") }
    assert_equal 3600, @store.options[key][:expires]
  end

  def test_set_leaves_a_shorter_ttl_alone
    @identity.set("tok", "user123", ttl: 60)
    key = @store.options.keys.find { |k| k.include?(":idn:") && !k.include?(":gen:") }
    assert_equal 60, @store.options[key][:expires]
  end

  # A plane with no default TTL stores entries that never expire, so no
  # counter lifetime is safe and generations stay permanent.
  def test_a_plane_without_a_ttl_keeps_permanent_generations
    plane = Parse::Cache::SubCache.new(store: @store, keyspace: @keyspace, family: :idn, ttl: nil)
    assert_nil plane.generation_ttl
    plane.bump_generation("user123")
    key = @store.options.keys.find { |k| k.include?(":gen:") }
    assert_empty @store.options[key]
  end

  # An INCR-capable store takes the atomic path, which sets no expiry of its
  # own, so the plane applies one through a value-preserving `expire`.
  def test_atomic_increment_path_applies_the_expiry_without_rewriting
    store = Class.new(FakeStore) do
      attr_reader :expiries
      def increment(k, amount = 1, _o = {})
        @data[k] = (@data[k] || 0).to_i + amount
      end

      def expire(k, ttl)
        (@expiries ||= {})[k] = ttl
        true
      end
    end.new

    plane = Parse::Cache::SubCache.new(store: store, keyspace: @keyspace, family: :idn, ttl: 3600)
    assert_equal 1, plane.bump_generation("user123")

    key = store.data.keys.find { |k| k.include?(":gen:") }
    assert_equal 7200, store.expiries[key], "the TTL must be applied"
    assert_empty store.options, "the counter's value must never be rewritten"
  end

  # The re-store fallback is gone, and its absence is the point.
  #
  # `store(key, value, expires:)` after an INCR is a lost update: two
  # concurrent bumps interleave as INCR(2), INCR(3), store(3), store(2), and
  # the counter moves BACKWARDS. Generation checks are equality comparisons,
  # so a counter returning to a previously issued value re-admits exactly the
  # identity entries that value had invalidated, turning a revoked session
  # resolvable again. A key with no TTL is unbounded growth; a counter that
  # goes backwards is an authorization failure, so the trade is not close.
  def test_a_store_without_expire_leaves_the_counter_alone
    store = Class.new(FakeStore) do
      def increment(k, amount = 1, _o = {}) = @data[k] = (@data[k] || 0).to_i + amount
    end.new

    plane = Parse::Cache::SubCache.new(store: store, keyspace: @keyspace, family: :idn, ttl: 3600)
    assert_equal 1, plane.bump_generation("user123")
    assert_equal 2, plane.bump_generation("user123")
    assert_empty store.options, "must not rewrite the counter to attach a TTL"
    assert_equal 2, plane.generation("user123"), "the counter must never move backwards"
  end
end
