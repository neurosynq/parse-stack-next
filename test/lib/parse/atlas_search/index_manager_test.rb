# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/atlas_search"

# Unit tests for Parse::AtlasSearch::IndexManager's mutation wrappers
# (create_index / drop_index / update_index) and the wait_for_ready
# polling helper. All Parse::MongoDB interactions are stubbed — no live
# Mongo or Atlas needed.
class AtlasSearchIndexManagerTest < Minitest::Test
  IM = Parse::AtlasSearch::IndexManager

  def setup
    IM.clear_cache
    @restore = {}
  end

  def teardown
    @restore.each do |meth, original|
      Parse::MongoDB.singleton_class.send(:remove_method, meth) if Parse::MongoDB.singleton_class.method_defined?(meth)
      Parse::MongoDB.define_singleton_method(meth, &original) if original
    end
    @restore.clear
    IM.clear_cache
  end

  # Replace a Parse::MongoDB singleton method with a block; remember the
  # original so teardown can restore it. Used to stub the search-index
  # primitives without touching the real method bodies.
  def stub_mongodb(meth, &block)
    original = Parse::MongoDB.method(meth) if Parse::MongoDB.respond_to?(meth)
    @restore[meth] ||= original
    Parse::MongoDB.singleton_class.send(:remove_method, meth) if Parse::MongoDB.singleton_class.method_defined?(meth)
    Parse::MongoDB.define_singleton_method(meth, &block)
  end

  # ---- create_index wrapper ----------------------------------------------

  def test_create_index_delegates_to_mongodb_and_clears_cache
    calls = []
    stub_mongodb(:create_search_index) do |coll, name, defn, **opts|
      calls << [coll, name, defn, opts]
      :created
    end

    # Pre-populate the cache so we can observe its invalidation.
    IM.instance_variable_get(:@index_cache) || IM.instance_variable_set(:@index_cache, {})
    IM.instance_variable_get(:@index_cache)["Song"] = { indexes: [{ "name" => "stale" }], cached_at: Time.now }

    result = IM.create_index("Song", "song_search", { mappings: { dynamic: true } })
    assert_equal :created, result
    assert_equal 1, calls.size
    assert_equal ["Song", "song_search", { mappings: { dynamic: true } }, { allow_system_classes: false }], calls.first
    refute IM.instance_variable_get(:@index_cache).key?("Song"),
           "create_index must invalidate the Song cache entry"
  end

  def test_create_index_propagates_allow_system_classes_kwarg
    calls = []
    stub_mongodb(:create_search_index) do |coll, name, defn, **opts|
      calls << opts
      :created
    end
    IM.create_index("Song", "s", { mappings: { dynamic: true } }, allow_system_classes: true)
    assert_equal({ allow_system_classes: true }, calls.first)
  end

  # ---- drop_index wrapper ------------------------------------------------

  def test_drop_index_delegates_with_confirm_and_clears_cache
    calls = []
    stub_mongodb(:drop_search_index) do |coll, name, confirm:, **opts|
      calls << [coll, name, confirm, opts]
      :dropped
    end
    IM.instance_variable_set(:@index_cache, { "Song" => { indexes: [{ "name" => "old" }], cached_at: Time.now } })

    result = IM.drop_index("Song", "song_search", confirm: "drop_search:Song:song_search")
    assert_equal :dropped, result
    assert_equal ["Song", "song_search", "drop_search:Song:song_search", { allow_system_classes: false }],
                 calls.first
    refute IM.instance_variable_get(:@index_cache).key?("Song")
  end

  # ---- update_index wrapper ----------------------------------------------

  def test_update_index_delegates_and_clears_cache
    calls = []
    stub_mongodb(:update_search_index) do |coll, name, defn, **opts|
      calls << [coll, name, defn, opts]
      :updated
    end
    IM.instance_variable_set(:@index_cache, { "Song" => { indexes: [{ "name" => "old" }], cached_at: Time.now } })

    result = IM.update_index("Song", "song_search", { mappings: { dynamic: false } })
    assert_equal :updated, result
    assert_equal ["Song", "song_search", { mappings: { dynamic: false } }, { allow_system_classes: false }],
                 calls.first
    refute IM.instance_variable_get(:@index_cache).key?("Song")
  end

  # ---- wait_for_ready ---------------------------------------------------

  # Stub IM.list_indexes to return a sequence of result sets — one per
  # poll. The stub also captures the force_refresh kwarg on every call
  # so the cache-bypass invariant can be asserted.
  def stub_list_indexes_sequence(sequences)
    refresh_flags = []
    queue = sequences.dup
    IM.singleton_class.send(:alias_method, :__test_orig_list_indexes, :list_indexes)
    IM.define_singleton_method(:list_indexes) do |_coll, force_refresh: false|
      refresh_flags << force_refresh
      queue.size > 1 ? queue.shift : queue.first
    end
    refresh_flags
  ensure
    # Caller restores in their own ensure.
  end

  def restore_list_indexes
    if IM.singleton_class.method_defined?(:__test_orig_list_indexes)
      IM.singleton_class.send(:remove_method, :list_indexes)
      IM.singleton_class.send(:alias_method, :list_indexes, :__test_orig_list_indexes)
      IM.singleton_class.send(:remove_method, :__test_orig_list_indexes)
    end
  end

  def with_list_indexes_stub(sequences)
    refresh_flags = stub_list_indexes_sequence(sequences)
    # Swap sleep to a no-op so timeouts/interval don't slow the suite.
    IM.singleton_class.send(:alias_method, :__test_orig_sleep, :sleep) if IM.respond_to?(:sleep)
    IM.define_singleton_method(:sleep) { |_| nil }
    yield refresh_flags
  ensure
    restore_list_indexes
    IM.singleton_class.send(:remove_method, :sleep) rescue nil
  end

  def test_wait_for_ready_returns_ready_on_queryable_true
    with_list_indexes_stub([[{ "name" => "song_search", "queryable" => true, "status" => "READY" }]]) do |flags|
      assert_equal :ready, IM.wait_for_ready("Song", "song_search", timeout: 5, interval: 0)
      assert flags.all? { |f| f == true },
             "wait_for_ready must call list_indexes with force_refresh: true to bypass the 300s cache"
    end
  end

  def test_wait_for_ready_returns_failed_when_status_failed
    with_list_indexes_stub([[{ "name" => "song_search", "queryable" => false, "status" => "FAILED" }]]) do |_|
      assert_equal :failed, IM.wait_for_ready("Song", "song_search", timeout: 5, interval: 0)
    end
  end

  def test_wait_for_ready_transitions_from_building_to_ready
    sequences = [
      [{ "name" => "song_search", "queryable" => false, "status" => "BUILDING" }],
      [{ "name" => "song_search", "queryable" => false, "status" => "BUILDING" }],
      [{ "name" => "song_search", "queryable" => true,  "status" => "READY" }],
    ]
    with_list_indexes_stub(sequences) do |flags|
      assert_equal :ready, IM.wait_for_ready("Song", "song_search", timeout: 5, interval: 0)
      # Every poll must request a fresh list — otherwise the cache locks
      # in the first BUILDING reading for the full TTL.
      assert_operator flags.size, :>=, 3
      assert flags.all? { |f| f == true }
    end
  end

  def test_wait_for_ready_returns_timeout_when_deadline_elapses
    # Always returns BUILDING — wait_for_ready must give up at timeout=0.
    with_list_indexes_stub([[{ "name" => "song_search", "queryable" => false, "status" => "BUILDING" }]]) do |_|
      assert_equal :timeout, IM.wait_for_ready("Song", "song_search", timeout: 0, interval: 0)
    end
  end

  def test_wait_for_ready_returns_timeout_when_index_never_appears
    with_list_indexes_stub([[]]) do |_|
      assert_equal :timeout, IM.wait_for_ready("Song", "song_search", timeout: 0, interval: 0)
    end
  end

  # ---- type-aware lookups -----------------------------------------------

  # Pre-populate the cache with a mixed set of search + vectorSearch
  # indexes. Shape matches what Atlas actually returns from
  # $listSearchIndexes (confirmed against a live mongodb-atlas-local
  # vector_prototype/Movie collection).
  def seed_mixed_indexes
    indexes = [
      {
        "name" => "song_search",
        "type" => "search",
        "status" => "READY",
        "queryable" => true,
        "latestDefinition" => { "mappings" => { "dynamic" => true } },
      },
      {
        "name" => "song_no_type",  # older Atlas omits "type" — defaults to search
        "status" => "READY",
        "queryable" => true,
        "latestDefinition" => { "mappings" => { "dynamic" => false } },
      },
      {
        "name" => "Movie_embedding_openai_idx",
        "type" => "vectorSearch",
        "status" => "READY",
        "queryable" => true,
        "latestDefinition" => {
          "fields" => [
            { "type" => "vector", "path" => "embedding",
              "numDimensions" => 1536, "similarity" => "cosine" },
            { "type" => "filter", "path" => "wiki_id" },
          ],
        },
      },
      {
        "name" => "Movie_summary_vec_idx",
        "type" => "vectorSearch",
        "status" => "READY",
        "queryable" => true,
        "latestDefinition" => {
          "fields" => [
            { "type" => "vector", "path" => "summary_vec",
              "numDimensions" => 768, "similarity" => "dotProduct" },
          ],
        },
      },
    ]
    IM.instance_variable_set(:@index_cache, {})
    IM.instance_variable_get(:@index_cache)["Movie"] = {
      indexes: indexes, cached_at: Time.now,
    }
  end

  def test_list_search_indexes_returns_only_search_type
    seed_mixed_indexes
    names = IM.list_search_indexes("Movie").map { |i| i["name"] }
    # Both explicit "search" type AND the no-type fallback must be included.
    assert_includes names, "song_search"
    assert_includes names, "song_no_type"
    refute_includes names, "Movie_embedding_openai_idx"
    refute_includes names, "Movie_summary_vec_idx"
  end

  def test_list_vector_indexes_returns_only_vectorSearch_type
    seed_mixed_indexes
    names = IM.list_vector_indexes("Movie").map { |i| i["name"] }
    assert_equal %w[Movie_embedding_openai_idx Movie_summary_vec_idx].sort, names.sort
  end

  def test_find_vector_index_matches_by_field_path
    seed_mixed_indexes
    idx = IM.find_vector_index("Movie", field: "embedding")
    refute_nil idx, "expected to find the embedding vector index"
    assert_equal "Movie_embedding_openai_idx", idx["name"]
  end

  def test_find_vector_index_accepts_symbol_field
    seed_mixed_indexes
    idx = IM.find_vector_index("Movie", field: :summary_vec)
    refute_nil idx
    assert_equal "Movie_summary_vec_idx", idx["name"]
  end

  def test_find_vector_index_returns_nil_when_no_vector_field_matches
    seed_mixed_indexes
    # "wiki_id" is a *filter* field on the embedding index, not a vector
    # field — find_vector_index must not match it.
    assert_nil IM.find_vector_index("Movie", field: "wiki_id")
  end

  def test_find_vector_index_returns_nil_when_collection_has_no_vector_indexes
    IM.instance_variable_set(:@index_cache, {})
    IM.instance_variable_get(:@index_cache)["Song"] = {
      indexes: [
        { "name" => "song_search", "type" => "search", "status" => "READY",
          "queryable" => true, "latestDefinition" => {} },
      ],
      cached_at: Time.now,
    }
    assert_nil IM.find_vector_index("Song", field: "embedding")
    assert_empty IM.list_vector_indexes("Song")
  end

  def test_index_catalog_aliases_index_manager
    # IndexCatalog is the public name for the type-aware lookup surface,
    # backed by the same module so the cache is shared.
    assert_same Parse::AtlasSearch::IndexManager, Parse::AtlasSearch::IndexCatalog
  end
end
