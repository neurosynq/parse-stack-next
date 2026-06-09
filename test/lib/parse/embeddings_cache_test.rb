# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"

# Unit tests for Parse::Embeddings::Cache — the query-embed cache keyed
# by (provider, model, dimensions, input_type, input_hash). Covers
# disabled pass-through, hit/miss accounting, key separation, TTL expiry,
# LRU eviction, custom stores, and the cached:true instrumentation event.
class EmbeddingsCacheTest < Minitest::Test
  CACHE = Parse::Embeddings::Cache

  # Counts embed_text invocations.
  class CountingProvider < Parse::Embeddings::Provider
    attr_reader :count
    def initialize(model: "counting-1")
      @model = model
      @count = 0
    end
    def dimensions; 3; end
    def model_name; @model; end
    def embed_text(strings, input_type: :search_document)
      @count += 1
      strings.map { |s| [s.length.to_f, input_type == :search_query ? 1.0 : 0.0, 9.9] }
    end
  end

  def teardown
    CACHE.disable!
  end

  def test_disabled_is_passthrough
    provider = CountingProvider.new
    v1 = CACHE.fetch_vector(provider, "hello")
    v2 = CACHE.fetch_vector(provider, "hello")
    assert_equal v1, v2
    assert_equal 2, provider.count
    refute CACHE.enabled?
  end

  def test_enabled_serves_repeats_from_cache
    CACHE.enable!
    provider = CountingProvider.new
    v1 = CACHE.fetch_vector(provider, "hello")
    v2 = CACHE.fetch_vector(provider, "hello")
    assert_equal v1, v2
    assert_equal 1, provider.count
    stats = CACHE.stats
    assert_equal 1, stats[:hits]
    assert_equal 1, stats[:misses]
    assert_equal 1, stats[:size]
  end

  def test_key_separates_input_type
    CACHE.enable!
    provider = CountingProvider.new
    CACHE.fetch_vector(provider, "hello", input_type: :search_query)
    CACHE.fetch_vector(provider, "hello", input_type: :search_document)
    assert_equal 2, provider.count
  end

  def test_key_separates_model
    CACHE.enable!
    a = CountingProvider.new(model: "model-a")
    b = CountingProvider.new(model: "model-b")
    CACHE.fetch_vector(a, "hello")
    CACHE.fetch_vector(b, "hello")
    assert_equal 1, a.count
    assert_equal 1, b.count
    assert_equal 2, CACHE.stats[:size]
  end

  def test_key_separates_input
    CACHE.enable!
    provider = CountingProvider.new
    CACHE.fetch_vector(provider, "hello")
    CACHE.fetch_vector(provider, "world")
    assert_equal 2, provider.count
  end

  def test_key_separates_dimensions
    # Matryoshka-capable providers can register the same model at two
    # output widths; the narrower instance must never be served the wider
    # instance's cached vector.
    CACHE.enable!
    narrow = CountingProvider.new
    wide = CountingProvider.new
    wide.define_singleton_method(:dimensions) { 1024 }
    CACHE.fetch_vector(narrow, "hello")
    CACHE.fetch_vector(wide, "hello")
    assert_equal 1, narrow.count
    assert_equal 1, wide.count
    assert_equal 2, CACHE.stats[:size]
  end

  def test_lru_eviction
    CACHE.enable!(max_entries: 2)
    provider = CountingProvider.new
    CACHE.fetch_vector(provider, "a")
    CACHE.fetch_vector(provider, "b")
    CACHE.fetch_vector(provider, "c") # evicts "a"
    assert_equal 2, CACHE.stats[:size]
    CACHE.fetch_vector(provider, "a") # miss again
    assert_equal 4, provider.count
  end

  def test_ttl_expiry
    CACHE.enable!(ttl: 0.01)
    provider = CountingProvider.new
    CACHE.fetch_vector(provider, "hello")
    sleep 0.02
    CACHE.fetch_vector(provider, "hello")
    assert_equal 2, provider.count
  end

  def test_clear_resets_entries_and_counters
    CACHE.enable!
    provider = CountingProvider.new
    CACHE.fetch_vector(provider, "hello")
    CACHE.clear!
    stats = CACHE.stats
    assert_equal 0, stats[:size]
    assert_equal 0, stats[:hits]
    assert_equal 0, stats[:misses]
  end

  def test_custom_store
    store = Class.new do
      attr_reader :h
      def initialize = @h = {}
      def get(k) = @h[k]
      def set(k, v) = @h[k] = v
    end.new
    CACHE.enable!(store: store)
    provider = CountingProvider.new
    CACHE.fetch_vector(provider, "hello")
    CACHE.fetch_vector(provider, "hello")
    assert_equal 1, provider.count
    assert_equal 1, store.h.length
  end

  def test_custom_store_must_quack
    assert_raises(ArgumentError) { CACHE.enable!(store: Object.new) }
  end

  def test_hit_emits_cached_instrumentation_event
    CACHE.enable!
    provider = CountingProvider.new
    events = []
    sub = ActiveSupport::Notifications.subscribe(
      Parse::Embeddings::Provider::AS_NOTIFICATION_NAME,
    ) { |*, payload| events << payload }
    begin
      CACHE.fetch_vector(provider, "hello")
      CACHE.fetch_vector(provider, "hello")
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
    cached_events = events.select { |p| p[:cached] }
    assert_equal 1, cached_events.length
    assert_equal "counting-1", cached_events.first[:model]
  end

  # ---------- MonetaStore (persistent L2 adapter) ----------

  class FakeMoneta
    attr_reader :h, :expires_seen
    def initialize
      @h = {}
      @expires_seen = []
    end

    def [](k)
      @h[k]
    end

    def []=(k, v)
      @h[k] = v
    end

    def store(k, v, expires: nil)
      @expires_seen << expires
      @h[k] = v
    end
  end

  class BrokenMoneta
    def [](_k)
      raise "redis down"
    end

    def []=(_k, _v)
      raise "redis down"
    end
  end

  def test_moneta_store_round_trips_with_namespace_and_ttl
    moneta = FakeMoneta.new
    store = CACHE::MonetaStore.new(moneta, ttl: 3600)
    CACHE.enable!(store: store)
    provider = CountingProvider.new
    v1 = CACHE.fetch_vector(provider, "hello")
    v2 = CACHE.fetch_vector(provider, "hello")
    assert_equal v1, v2
    assert_equal 1, provider.count
    assert_equal 1, moneta.h.length
    assert moneta.h.keys.first.start_with?("emb:")
    assert_equal [3600.0], moneta.expires_seen
  end

  def test_moneta_store_without_ttl_uses_plain_assignment
    moneta = FakeMoneta.new
    store = CACHE::MonetaStore.new(moneta)
    store.set("k", [1.0])
    assert_empty moneta.expires_seen
    assert_equal [1.0], store.get("k")
  end

  def test_moneta_store_with_ttl_and_hash_backend_falls_back_to_plain_write
    # Hash#store(key, value) rejects the expires: kwarg with ArgumentError;
    # the adapter must fall back to a plain (no-expiry) write instead of
    # letting the fail-open rescue silently drop every vector.
    moneta = {}
    store = CACHE::MonetaStore.new(moneta, ttl: 60)
    store.set("k", [1.0, 2.0])
    assert_equal [1.0, 2.0], store.get("k")
    assert_equal [1.0, 2.0], moneta["emb:k"]
  end

  def test_moneta_store_fails_open_on_backend_errors
    store = CACHE::MonetaStore.new(BrokenMoneta.new)
    CACHE.enable!(store: store)
    provider = CountingProvider.new
    # get raises -> miss; set raises -> dropped write. Both swallowed.
    v1 = CACHE.fetch_vector(provider, "hello")
    v2 = CACHE.fetch_vector(provider, "hello")
    assert_equal v1, v2
    assert_equal 2, provider.count, "broken store degrades to pass-through"
  end

  def test_moneta_store_ignores_non_array_values
    moneta = FakeMoneta.new
    moneta.h["emb:poisoned"] = "not a vector"
    store = CACHE::MonetaStore.new(moneta)
    assert_nil store.get("poisoned")
  end

  def test_moneta_store_requires_indexing_duck
    assert_raises(ArgumentError) { CACHE::MonetaStore.new(Object.new) }
  end

  def test_invalid_provider_response_raises
    bad = Class.new(Parse::Embeddings::Provider) do
      def dimensions; 3; end
      def model_name; "bad"; end
      def embed_text(strings, input_type: :search_document)
        [[1.0], [2.0]] # two vectors for one input
      end
    end.new
    CACHE.enable!
    assert_raises(Parse::Embeddings::InvalidResponseError) do
      CACHE.fetch_vector(bad, "hello")
    end
  end
end
