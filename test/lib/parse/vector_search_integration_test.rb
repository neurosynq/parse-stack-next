# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "json"
require "parse/mongodb"
require "parse/vector_search"

# Integration tests for Parse::VectorSearch against the embeddings
# fixture loaded by `scripts/vector_prototype/`.
#
# Setup:
#   docker-compose -f scripts/docker/docker-compose.atlas.yml up -d
#   ./scripts/vector_prototype/run.sh
#
# Run:
#   ATLAS_URI="mongodb://localhost:29020/vector_prototype?directConnection=true" \
#     ruby -Ilib:test test/lib/parse/vector_search_integration_test.rb
#
# The fixture's manifest (`scripts/vector_prototype/fixture_manifest.json`)
# is the single source of truth for collection name + index name + dims,
# so the test stays in sync with whatever PRESET the operator loaded.
class VectorSearchIntegrationTest < Minitest::Test
  MANIFEST_PATH = File.expand_path(
    "../../../../scripts/vector_prototype/fixture_manifest.json", __FILE__
  )
  DEFAULT_URI = "mongodb://localhost:29020/vector_prototype?directConnection=true"
  ATLAS_URI = ENV["ATLAS_URI"] || DEFAULT_URI

  def self.manifest
    return @manifest if defined?(@manifest)
    @manifest = File.exist?(MANIFEST_PATH) ? JSON.parse(File.read(MANIFEST_PATH)) : nil
  end

  def self.fixture_available?
    return @fixture_available if defined?(@fixture_available)
    @fixture_available = probe_fixture
  end

  def self.probe_fixture
    return false unless manifest
    require "mongo"
    client = Mongo::Client.new(
      ATLAS_URI,
      server_selection_timeout: 15, connect_timeout: 5, socket_timeout: 10,
      logger: Logger.new(IO::NULL),
    )
    coll = client[manifest["collection"]]
    n = coll.count_documents({})
    client.close
    n.to_i > 0
  rescue => e
    warn "[VectorSearchIntegrationTest] fixture probe failed: #{e.class}: #{e.message}"
    false
  end

  def setup
    unless self.class.manifest
      skip "No fixture_manifest.json — run `./scripts/vector_prototype/run.sh` first."
    end
    unless self.class.fixture_available?
      skip "Fixture collection empty or unreachable at #{ATLAS_URI}."
    end

    @manifest = self.class.manifest
    @collection = @manifest["collection"]
    @index = @manifest["index_name"]
    @dims = @manifest["dims"]

    Parse::MongoDB.configure(uri: ATLAS_URI, enabled: true, verify_role: false)
    # The fixture lives in `vector_prototype.Movie`; there's no Parse
    # Server REST endpoint to fetch a schema from, so CLPScope would
    # fail-closed on every non-master call. Pre-populate the cache
    # with `:no_clp` (public-default) so the ACL/CLP enforcement
    # chain can actually run against the fixture.
    Parse::CLPScope.__cache_put(@collection, clp: {})
  end

  def teardown
    Parse::MongoDB.reset!
    Parse::VectorSearch.default_index = nil
    Parse::CLPScope.reset_cache!
  end

  # ----- validate_query_vector! ----------------------------------------

  def test_validate_query_vector_accepts_floats
    v = Parse::VectorSearch.validate_query_vector!([0.1, 0.2, -0.3])
    assert_equal [0.1, 0.2, -0.3], v
    assert v.frozen?, "validated vector should be frozen"
  end

  def test_validate_query_vector_coerces_integers
    v = Parse::VectorSearch.validate_query_vector!([1, 2, 3])
    assert_equal [1.0, 2.0, 3.0], v
    assert v.all? { |x| x.is_a?(Float) }
  end

  def test_validate_query_vector_rejects_non_array
    assert_raises(Parse::VectorSearch::InvalidQueryVector) do
      Parse::VectorSearch.validate_query_vector!("not a vector")
    end
  end

  def test_validate_query_vector_rejects_empty
    assert_raises(Parse::VectorSearch::InvalidQueryVector) do
      Parse::VectorSearch.validate_query_vector!([])
    end
  end

  def test_validate_query_vector_rejects_non_numeric_entries
    assert_raises(Parse::VectorSearch::InvalidQueryVector) do
      Parse::VectorSearch.validate_query_vector!([0.1, "oops", 0.3])
    end
  end

  def test_validate_query_vector_rejects_infinite_and_nan
    assert_raises(Parse::VectorSearch::InvalidQueryVector) do
      Parse::VectorSearch.validate_query_vector!([0.1, Float::INFINITY])
    end
    assert_raises(Parse::VectorSearch::InvalidQueryVector) do
      Parse::VectorSearch.validate_query_vector!([0.1, Float::NAN])
    end
  end

  def test_validate_query_vector_enforces_dimensions
    assert_raises(Parse::VectorSearch::InvalidQueryVector) do
      Parse::VectorSearch.validate_query_vector!([0.1, 0.2], dimensions: 3)
    end
  end

  def test_validate_query_vector_enforces_max_dimensions
    too_big = Array.new(Parse::VectorSearch::MAX_DIMENSIONS + 1, 0.0)
    assert_raises(Parse::VectorSearch::InvalidQueryVector) do
      Parse::VectorSearch.validate_query_vector!(too_big)
    end
  end

  # ----- search end-to-end against the fixture -------------------------

  def test_search_returns_hits_with_vscore
    seed = seed_doc
    results = Parse::VectorSearch.search(
      @collection,
      field: :embedding,
      query_vector: seed["embedding"],
      k: 5,
      index: @index,
      master: true,
    )
    assert_equal 5, results.size
    results.each do |r|
      assert r.key?("_vscore"), "result missing _vscore: #{r.inspect}"
      assert r["_vscore"].is_a?(Numeric)
    end
  end

  def test_search_self_similarity_top_hit_is_seed
    seed = seed_doc
    results = Parse::VectorSearch.search(
      @collection,
      field: :embedding,
      query_vector: seed["embedding"],
      k: 1,
      index: @index,
      master: true,
    )
    refute_empty results, "expected at least one hit"
    assert_equal seed["_id"], results.first["_id"], "top hit should be the seed itself"
    assert_in_delta 1.0, results.first["_vscore"], 0.001, "self-similarity score ~= 1.0"
  end

  def test_search_respects_k
    seed = seed_doc
    results = Parse::VectorSearch.search(
      @collection,
      field: :embedding,
      query_vector: seed["embedding"],
      k: 3,
      index: @index,
      master: true,
    )
    assert_equal 3, results.size
  end

  def test_search_uses_default_index_when_unset
    seed = seed_doc
    Parse::VectorSearch.default_index = @index
    results = Parse::VectorSearch.search(
      @collection,
      field: :embedding,
      query_vector: seed["embedding"],
      k: 2,
      master: true,
    )
    assert_equal 2, results.size
  end

  def test_search_refuses_no_scope_when_require_session_token
    Parse::ACLScope.require_session_token = true
    assert_raises(Parse::ACLScope::ACLRequired) do
      Parse::VectorSearch.search(
        @collection,
        field: :embedding,
        query_vector: Array.new(@dims, 0.0),
        k: 1,
        index: @index,
      )
    end
  ensure
    Parse::ACLScope.require_session_token = false
  end

  def test_search_refuses_conflicting_scope_kwargs
    assert_raises(ArgumentError) do
      Parse::VectorSearch.search(
        @collection,
        field: :embedding,
        query_vector: Array.new(@dims, 0.0),
        k: 1,
        index: @index,
        master: true,
        acl_role: "Admin",
      )
    end
  end

  def test_search_runs_under_public_scope_without_kwargs
    # Fixture docs have no `_rperm` (legacy public-default); the public
    # scope's `read_predicate` matches via the `_rperm: {$exists: false}`
    # branch, so this returns the same self-similarity row that master
    # mode does, just under the public-only `["*"]` permission set.
    seed = seed_doc
    results = Parse::VectorSearch.search(
      @collection,
      field: :embedding,
      query_vector: seed["embedding"],
      k: 1,
      index: @index,
    )
    refute_empty results
    assert_equal seed["_id"], results.first["_id"]
  end

  def test_search_refuses_invalid_field
    assert_raises(ArgumentError) do
      Parse::VectorSearch.search(
        @collection,
        field: "",
        query_vector: Array.new(@dims, 0.0),
        k: 1,
        index: @index,
        master: true,
      )
    end
    assert_raises(ArgumentError) do
      Parse::VectorSearch.search(
        @collection,
        field: "$inject",
        query_vector: Array.new(@dims, 0.0),
        k: 1,
        index: @index,
        master: true,
      )
    end
  end

  def test_search_refuses_dangerous_filter
    seed = seed_doc
    assert_raises(Parse::PipelineSecurity::Error) do
      Parse::VectorSearch.search(
        @collection,
        field: :embedding,
        query_vector: seed["embedding"],
        k: 5,
        index: @index,
        master: true,
        filter: { "$where" => "this.title == 'whatever'" },
      )
    end
  end

  def test_search_refuses_dangerous_vector_filter
    seed = seed_doc
    assert_raises(Parse::PipelineSecurity::Error) do
      Parse::VectorSearch.search(
        @collection,
        field: :embedding,
        query_vector: seed["embedding"],
        k: 5,
        index: @index,
        master: true,
        vector_filter: { "$function" => { body: "function(){}", args: [], lang: "js" } },
      )
    end
  end

  def test_search_refuses_dotted_field_path
    assert_raises(ArgumentError) do
      Parse::VectorSearch.search(
        @collection,
        field: "nested.embedding",
        query_vector: Array.new(@dims, 0.0),
        k: 1, index: @index, master: true,
      )
    end
  end

  def test_search_refuses_internal_field_names
    assert_raises(ArgumentError) do
      Parse::VectorSearch.search(
        @collection,
        field: "_hashed_password",
        query_vector: Array.new(@dims, 0.0),
        k: 1, index: @index, master: true,
      )
    end
  end

  def test_search_refuses_k_over_max
    assert_raises(ArgumentError) do
      Parse::VectorSearch.search(
        @collection,
        field: :embedding,
        query_vector: Array.new(@dims, 0.0),
        k: Parse::VectorSearch::MAX_K + 1,
        index: @index, master: true,
      )
    end
  end

  def test_search_refuses_num_candidates_less_than_k
    assert_raises(ArgumentError) do
      Parse::VectorSearch.search(
        @collection,
        field: :embedding,
        query_vector: Array.new(@dims, 0.0),
        k: 10, num_candidates: 5,
        index: @index, master: true,
      )
    end
  end

  def test_search_refuses_num_candidates_over_10k
    assert_raises(ArgumentError) do
      Parse::VectorSearch.search(
        @collection,
        field: :embedding,
        query_vector: Array.new(@dims, 0.0),
        k: 10, num_candidates: 10_001,
        index: @index, master: true,
      )
    end
  end

  def test_search_accepts_empty_vector_filter
    seed = seed_doc
    results = Parse::VectorSearch.search(
      @collection,
      field: :embedding,
      query_vector: seed["embedding"],
      k: 1, index: @index, master: true,
      vector_filter: {},
    )
    assert_equal 1, results.size
  end

  def test_search_filters_acl_restricted_docs_under_public_scope
    seed = seed_doc
    coll = Parse::MongoDB.collection(@collection)
    # Restrict the seed doc to a specific user only — public scope
    # should NOT see it because `_rperm` is set and doesn't include "*".
    coll.update_one(
      { "_id" => seed["_id"] },
      { "$set" => { "_rperm" => ["someOtherUser"] } },
    )
    begin
      results = Parse::VectorSearch.search(
        @collection,
        field: :embedding,
        query_vector: seed["embedding"],
        k: 5, index: @index,
      )
      ids = results.map { |r| r["_id"] }
      refute_includes ids, seed["_id"],
        "public scope should not see ACL-restricted doc"
    ensure
      coll.update_one(
        { "_id" => seed["_id"] },
        { "$unset" => { "_rperm" => "" } },
      )
    end
  end

  def test_search_master_bypasses_acl_restriction
    seed = seed_doc
    coll = Parse::MongoDB.collection(@collection)
    coll.update_one(
      { "_id" => seed["_id"] },
      { "$set" => { "_rperm" => ["someOtherUser"] } },
    )
    begin
      results = Parse::VectorSearch.search(
        @collection,
        field: :embedding,
        query_vector: seed["embedding"],
        k: 1, index: @index, master: true,
      )
      assert_equal seed["_id"], results.first["_id"],
        "master mode should bypass ACL restriction"
    ensure
      coll.update_one(
        { "_id" => seed["_id"] },
        { "$unset" => { "_rperm" => "" } },
      )
    end
  end

  def test_search_strips_internal_fields_from_results
    seed = seed_doc
    coll = Parse::MongoDB.collection(@collection)
    coll.update_one(
      { "_id" => seed["_id"] },
      { "$set" => { "_rperm" => ["*"], "_wperm" => [seed["_id"].to_s] } },
    )
    begin
      results = Parse::VectorSearch.search(
        @collection,
        field: :embedding,
        query_vector: seed["embedding"],
        k: 1, index: @index, master: true,
      )
      hit = results.first
      refute hit.key?("_rperm"), "results should strip _rperm"
      refute hit.key?("_wperm"), "results should strip _wperm"
    ensure
      coll.update_one(
        { "_id" => seed["_id"] },
        { "$unset" => { "_rperm" => "", "_wperm" => "" } },
      )
    end
  end

  # ----- IndexCatalog discovery against the live fixture --------------

  # Sanity-check that the type-aware IndexCatalog helpers correctly
  # classify the fixture's vector index. The fixture currently loads
  # exactly one vectorSearch index on Movie.embedding and no lexical
  # search indexes, so the assertions can be exact. This is the
  # primary live-shape contract test for `find_vector_index` — the
  # mocked unit test in atlas_search/index_manager_test.rb can drift
  # from reality if the Atlas response shape changes.
  def test_index_catalog_classifies_fixture_vector_index
    require "parse/atlas_search"
    Parse::AtlasSearch::IndexCatalog.clear_cache(@collection)

    vec_indexes = Parse::AtlasSearch::IndexCatalog.list_vector_indexes(@collection)
    assert_equal 1, vec_indexes.size,
      "fixture should expose exactly one vectorSearch index on #{@collection}"
    assert_equal @index, vec_indexes.first["name"]
    assert_equal "vectorSearch", vec_indexes.first["type"]

    assert_empty Parse::AtlasSearch::IndexCatalog.list_search_indexes(@collection),
      "fixture has no lexical search indexes — list_search_indexes must filter them out"
  end

  def test_index_catalog_find_vector_index_matches_fixture_field
    require "parse/atlas_search"
    Parse::AtlasSearch::IndexCatalog.clear_cache(@collection)

    idx = Parse::AtlasSearch::IndexCatalog.find_vector_index(@collection, field: "embedding")
    refute_nil idx, "fixture vector index must be discoverable by field path"
    assert_equal @index, idx["name"]

    # Negative: an unrelated field path must not match.
    assert_nil Parse::AtlasSearch::IndexCatalog.find_vector_index(@collection, field: "nonexistent_field")
  end

  private

  def seed_doc
    Parse::MongoDB.collection(@collection).find.limit(1).first
  end
end
