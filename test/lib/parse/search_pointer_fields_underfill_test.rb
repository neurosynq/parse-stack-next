# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "set"
require "parse/atlas_search"
require "parse/vector_search"
require "parse/vector_search/hybrid"

# Regression tests for pointerFields / readUserFields underfill in the
# Atlas Search, vector, and hybrid paths.
#
# The ownership constraint used to run in Ruby on the rows the pipeline
# had already cut to `$limit`. When the top-ranked hits belonged to other
# users, the caller got a short or empty page even though their own
# matches ranked just below the cutoff. The constraint now runs as a
# `$match` before `$limit` (and, for `$vectorSearch`, as the index
# prefilter when the owner pointer is filter-indexed), so those rows come
# back. Inaccessible rows must still never be returned.
class SearchPointerFieldsUnderfillTest < Minitest::Test
  OWNER_CLP = {
    "find" => { "pointerFields" => ["owner"] },
    "get" => { "pointerFields" => ["owner"] },
    "count" => { "pointerFields" => ["owner"] },
  }.freeze

  # Evaluates the pipeline stages this suite's paths emit, in order, over
  # rows already in rank order. Unknown match operators raise so a shape
  # change cannot silently pass.
  # The owner prefilter is pushed down only for a field declared as a
  # scalar pointer on the local model.
  class UnderfillDoc < Parse::Object
    parse_class "Doc"
    belongs_to :owner, as: :user
  end

  # Same ownership CLP, but `owner` is an array of pointers stored under
  # the bare field name.
  class UnderfillArrayDoc < Parse::Object
    parse_class "ArrayDoc"
    has_many :owner, as: :user, through: :array
  end

  class EvalColl
    attr_reader :pipelines

    def initialize(rows)
      @rows = rows
      @pipelines = []
    end

    def with(*) = self

    def aggregate(pipeline, _opts = {})
      @pipelines << pipeline
      rows = @rows.map(&:dup)
      pipeline.each do |stage|
        op, arg = stage.first
        case op
        when "$search", "$addFields", "$sort", "$rankFusion" then next
        when "$vectorSearch"
          rows = rows.select { |r| Matcher.match?(r, arg["filter"]) } if arg["filter"]
          rows = rows.first(arg["limit"])
        when "$match" then rows = rows.select { |r| Matcher.match?(r, arg) }
        when "$limit" then rows = rows.first(arg)
        when "$skip" then rows = rows.drop(arg)
        else raise "EvalColl: unsupported stage #{op}"
        end
      end
      rows
    end
  end

  module Matcher
    module_function

    def match?(doc, cond)
      cond.all? do |key, val|
        case key.to_s
        when "$or" then val.any? { |c| match?(doc, c) }
        when "$and" then val.all? { |c| match?(doc, c) }
        else field_match?(doc, key.to_s, val)
        end
      end
    end

    def field_match?(doc, key, val)
      actual = doc[key]
      return actual == val || (actual.is_a?(Array) && actual.include?(val)) unless operator_hash?(val)

      val.all? do |op, arg|
        case op.to_s
        when "$in" then Array(actual).any? { |a| arg.include?(a) }
        when "$nin" then Array(actual).none? { |a| arg.include?(a) }
        when "$exists" then doc.key?(key) == arg
        when "$eq" then actual == arg
        when "$elemMatch" then Array(actual).any? { |el| el.is_a?(Hash) && match?(el, arg) }
        else raise "Matcher: unsupported operator #{op}"
        end
      end
    end

    def operator_hash?(val)
      val.is_a?(Hash) && !val.empty? && val.keys.all? { |k| k.to_s.start_with?("$") }
    end
  end

  # 20 higher-ranked rows owned by someone else, then 10 owned by u1. All
  # are publicly readable by ACL, so only the pointerFields CLP separates
  # them.
  def ranked_rows
    others = (0...20).map { |i| row("o#{i}", "other") }
    mine = (0...10).map { |i| row("m#{i}", "u1") }
    others + mine
  end

  def row(id, owner)
    { "_id" => id, "title" => "t#{id}", "_rperm" => ["*"], "_p_owner" => "_User$#{owner}" }
  end

  def session_resolution
    Parse::ACLScope::Resolution.new(mode: :session, permission_strings: ["u1", "*"], user_id: "u1",
                                    session: nil, strict_role: false)
  end

  def setup
    begin
      Parse.client
    rescue Parse::Error::ConnectionError
      Parse.setup(server_url: "http://localhost:9999/parse", application_id: "test-app", api_key: "test-key")
    end
    Parse::AtlasSearch.reset!
    Parse::AtlasSearch.configure(enabled: true, default_index: "default")
    Parse::CLPScope.reset_cache!
    Parse::CLPScope.__cache_put("Doc", clp: OWNER_CLP)
    Parse::CLPScope.__cache_put("ArrayDoc", clp: OWNER_CLP)
    Parse::CLPScope.__cache_put("Undeclared", clp: OWNER_CLP)
    Parse::VectorSearch.clear_prefilter_cache!
  end

  def teardown
    Parse::AtlasSearch.reset!
    Parse::CLPScope.reset_cache!
    Parse::VectorSearch.clear_prefilter_cache!
  end

  def with_coll(coll)
    Parse::MongoDB.stub(:require_gem!, nil) do
      Parse::MongoDB.stub(:available?, true) do
        Parse::MongoDB.stub(:collection, ->(_n, **_o) { coll }) do
          Parse::ACLScope.stub(:resolve!, ->(*, **) { session_resolution }) do
            Parse::AtlasSearch.stub(:resolve_scope!, ->(*, **) { session_resolution }) do
              yield
            end
          end
        end
      end
    end
  end

  # Row ids encode the owner ("m" rows are u1's), so this holds whether
  # the path returned storage-form rows or converted the pointer.
  def owned_by_u1?(doc)
    (doc["_id"] || doc["objectId"]).to_s.start_with?("m")
  end

  # ---- Atlas Search ---------------------------------------------------

  def test_search_returns_owned_rows_ranked_below_other_users
    coll = EvalColl.new(ranked_rows)
    result = with_coll(coll) { Parse::AtlasSearch.search("Doc", "t", limit: 5, raw: true) }

    assert_equal 5, result.results.length, "eligible rows below the cutoff must fill the page"
    assert result.results.all? { |r| owned_by_u1?(r) }, "rows owned by another user must not appear"
  end

  def test_search_pointer_match_runs_before_limit
    coll = EvalColl.new(ranked_rows)
    with_coll(coll) { Parse::AtlasSearch.search("Doc", "t", limit: 5, raw: true) }

    pipe = coll.pipelines.first
    pointer_at = pipe.index { |s| s["$match"].to_s.include?("_p_owner") }
    limit_at = pipe.index { |s| s.key?("$limit") }
    assert_equal "$search", pipe.first.keys.first, "$search must stay stage 0"
    refute_nil pointer_at
    assert_operator pointer_at, :<, limit_at
  end

  def test_autocomplete_returns_owned_rows_ranked_below_other_users
    coll = EvalColl.new(ranked_rows)
    result = with_coll(coll) do
      Parse::AtlasSearch.autocomplete("Doc", "t", field: :title, limit: 5, raw: true)
    end

    assert_equal 5, result.results.length
    assert result.results.all? { |r| owned_by_u1?(r) }
  end

  def test_search_without_owned_rows_returns_nothing
    coll = EvalColl.new((0...20).map { |i| row("o#{i}", "other") })
    result = with_coll(coll) { Parse::AtlasSearch.search("Doc", "t", limit: 5, raw: true) }
    assert_empty result.results
  end

  def test_master_search_has_no_pointer_match
    coll = EvalColl.new(ranked_rows)
    master = Parse::ACLScope::Resolution.new(mode: :master, permission_strings: nil, user_id: nil,
                                             session: nil, strict_role: false)
    Parse::MongoDB.stub(:require_gem!, nil) do
      Parse::MongoDB.stub(:available?, true) do
        Parse::MongoDB.stub(:collection, ->(_n, **_o) { coll }) do
          Parse::ACLScope.stub(:resolve!, ->(*, **) { master }) do
            Parse::AtlasSearch.search("Doc", "t", limit: 5, raw: true, master: true)
          end
        end
      end
    end
    refute(coll.pipelines.first.any? { |s| s["$match"].to_s.include?("_p_owner") })
  end

  # ---- $vectorSearch --------------------------------------------------

  # 1000 rows owned by someone else rank above u1's rows, far past the
  # default candidate window. Only a prefilter can reach them.
  def deep_vector_rows
    (0...1000).map { |i| row("o#{i}", "other") } + (0...10).map { |i| row("m#{i}", "u1") }
  end

  def vector_index(filter_paths, status: "READY", **extra)
    fields = [{ "type" => "vector", "path" => "embedding", "numDimensions" => 3, "similarity" => "cosine" }]
    fields += filter_paths.map { |p| { "type" => "filter", "path" => p } }
    { "name" => "vec_idx", "type" => "vectorSearch", "status" => status,
      "latestDefinition" => { "fields" => fields } }.merge(extra)
  end

  def vector_search(coll, index_def:, collection: "Doc", **opts)
    with_coll(coll) do
      Parse::AtlasSearch::IndexManager.stub(:get_index, ->(*) { index_def }) do
        Parse::VectorSearch.search(collection, field: "embedding", query_vector: [0.1, 0.2, 0.3],
                                               k: 5, index: "vec_idx", **opts)
      end
    end
  end

  def test_vector_prefilters_on_filter_indexed_owner_pointer
    coll = EvalColl.new(deep_vector_rows)
    results = vector_search(coll, index_def: vector_index(["_p_owner"]))

    vs = coll.pipelines.first.dig(0, "$vectorSearch")
    assert_equal({ "_p_owner" => { "$eq" => "_User$u1" } }, vs["filter"])
    assert_equal 5, results.length, "the prefilter keeps other users' rows out of the candidate window"
    assert results.all? { |r| owned_by_u1?(r) }
  end

  def test_vector_prefilter_is_anded_with_caller_vector_filter
    coll = EvalColl.new(deep_vector_rows)
    vector_search(coll, index_def: vector_index(["_p_owner", "kind"]), vector_filter: { "kind" => "a" })

    vs = coll.pipelines.first.dig(0, "$vectorSearch")
    assert_equal({ "$and" => [{ "kind" => "a" }, { "_p_owner" => { "$eq" => "_User$u1" } }] }, vs["filter"])
  end

  def test_vector_without_filter_index_matches_server_side_without_prefilter
    coll = EvalColl.new(ranked_rows)
    results = vector_search(coll, index_def: vector_index([]))

    pipe = coll.pipelines.first
    refute pipe.dig(0, "$vectorSearch").key?("filter"), "no prefilter on a path the index does not declare"
    assert(pipe.drop(1).any? { |s| s["$match"].to_s.include?("_p_owner") },
           "ownership must still run server-side after $vectorSearch")
    assert_equal 5, results.length, "owned rows inside the candidate window still fill the page"
    assert results.all? { |r| owned_by_u1?(r) }
  end

  def test_vector_index_lookup_failure_falls_back_to_post_match
    coll = EvalColl.new(ranked_rows)
    results = with_coll(coll) do
      Parse::AtlasSearch::IndexManager.stub(:get_index, ->(*) { raise "listSearchIndexes not permitted" }) do
        Parse::VectorSearch.search("Doc", field: "embedding", query_vector: [0.1, 0.2, 0.3],
                                          k: 5, index: "vec_idx")
      end
    end

    refute coll.pipelines.first.dig(0, "$vectorSearch").key?("filter")
    assert results.all? { |r| owned_by_u1?(r) }
  end

  # ---- prefilter only on scalar pointer fields ------------------------

  def array_owned_rows
    others = (0...20).map { |i| row("o#{i}", "other") }
    mine = (0...10).map do |i|
      { "_id" => "m#{i}", "title" => "tm#{i}", "_rperm" => ["*"],
        "owner" => [{ "__type" => "Pointer", "className" => "_User", "objectId" => "u1" }] }
    end
    others + mine
  end

  def test_vector_no_prefilter_when_owner_is_an_array_field
    coll = EvalColl.new(array_owned_rows)
    results = vector_search(coll, index_def: vector_index(["_p_owner"]), collection: "ArrayDoc")

    refute coll.pipelines.first.dig(0, "$vectorSearch").key?("filter"),
           "a scalar _p_owner prefilter would drop rows owned through the pointer array"
    assert_equal 5, results.length, "array-owned rows still come back through the post-stage $match"
    assert results.all? { |r| owned_by_u1?(r) }
  end

  def test_vector_no_prefilter_when_owner_field_is_undeclared
    coll = EvalColl.new(ranked_rows)
    vector_search(coll, index_def: vector_index(["_p_owner"]), collection: "Undeclared")
    refute coll.pipelines.first.dig(0, "$vectorSearch").key?("filter")
  end

  def test_native_hybrid_no_vector_prefilter_for_array_owner
    pipe = Parse::ACLScope.stub(:resolve!, ->(*, **) { session_resolution }) do
      Parse::AtlasSearch::IndexManager.stub(:get_index, ->(*) { vector_index(["_p_owner"]) }) do
        Parse::VectorSearch::Hybrid.send(
          :native_pipeline, "ArrayDoc",
          lexical: { query: "t", index: "default" },
          vector: { query_vector: [0.1, 0.2], field: "embedding", index: "vec_idx" },
          k: 5,
        )
      end
    end
    inputs = pipe.dig(0, "$rankFusion", "input", "pipelines")
    refute inputs["vector"].dig(0, "$vectorSearch").key?("filter")
    assert(inputs["lexical"].any? { |s| s["$match"].to_s.include?("$elemMatch") },
           "the lexical input still filters ownership, array form included")
  end

  # ---- prefilter readiness, retry, negative cache --------------------

  def test_vector_no_prefilter_while_index_is_building
    coll = EvalColl.new(ranked_rows)
    vector_search(coll, index_def: vector_index(["_p_owner"], status: "BUILDING"))
    refute coll.pipelines.first.dig(0, "$vectorSearch").key?("filter"),
           "a rebuilding index may still serve the old definition without the filter path"
  end

  def test_vector_no_prefilter_when_served_version_lags_latest
    detail = [{ "hostname" => "h1", "mainIndex" => { "status" => "READY", "definitionVersion" => { "version" => 0 } },
                "stagedIndex" => { "status" => "PENDING", "definitionVersion" => { "version" => 1 } } }]
    idx = vector_index(["_p_owner"], "latestDefinitionVersion" => { "version" => 1 }, "statusDetail" => detail)
    coll = EvalColl.new(ranked_rows)
    vector_search(coll, index_def: idx)
    refute coll.pipelines.first.dig(0, "$vectorSearch").key?("filter")
  end

  def test_vector_prefilters_when_every_host_serves_latest
    detail = [{ "hostname" => "h1", "mainIndex" => { "status" => "READY", "definitionVersion" => { "version" => 2 } } }]
    idx = vector_index(["_p_owner"], "latestDefinitionVersion" => { "version" => 2 }, "statusDetail" => detail)
    coll = EvalColl.new(deep_vector_rows)
    results = vector_search(coll, index_def: idx)
    assert_equal({ "_p_owner" => { "$eq" => "_User$u1" } }, coll.pipelines.first.dig(0, "$vectorSearch", "filter"))
    assert_equal 5, results.length
  end

  # Atlas refuses a prefilter on a path the served index does not declare.
  class RejectingColl < EvalColl
    def aggregate(pipeline, opts = {})
      if pipeline.dig(0, "$vectorSearch", "filter").to_s.include?("_p_owner")
        @pipelines << pipeline
        raise StandardError, "PlanExecutor error during aggregation :: caused by :: " \
                             "Path '_p_owner' needs to be indexed as filter"
      end
      super
    end
  end

  def test_vector_retries_without_prefilter_when_atlas_rejects_it
    coll = RejectingColl.new(ranked_rows)
    cleared = []
    results = Parse::AtlasSearch::IndexManager.stub(:clear_cache, ->(c = nil) { cleared << c }) do
      vector_search(coll, index_def: vector_index(["_p_owner"]), vector_filter: { "kind" => { "$exists" => false } })
    end

    assert_equal 2, coll.pipelines.size, "one rejected attempt, one retry"
    assert_equal({ "kind" => { "$exists" => false } }, coll.pipelines.last.dig(0, "$vectorSearch", "filter"),
                 "the retry keeps the caller's own prefilter")
    assert(coll.pipelines.last.drop(1).any? { |s| s["$match"].to_s.include?("_p_owner") },
           "ownership still runs after $vectorSearch on the retry")
    assert_equal ["Doc"], cleared
    assert_equal 5, results.length
    assert results.all? { |r| owned_by_u1?(r) }

    # The next search skips the pushdown instead of failing again.
    coll2 = RejectingColl.new(ranked_rows)
    vector_search(coll2, index_def: vector_index(["_p_owner"]))
    assert_equal 1, coll2.pipelines.size
    refute coll2.pipelines.first.dig(0, "$vectorSearch").key?("filter")
  end

  # Atlas words the refusal the same way for a caller's own unindexed path.
  class CallerPathRejectingColl < EvalColl
    def aggregate(pipeline, opts = {})
      if pipeline.dig(0, "$vectorSearch", "filter").to_s.include?("kind")
        @pipelines << pipeline
        raise StandardError, "PlanExecutor error during aggregation :: caused by :: " \
                             "Path 'kind' needs to be indexed as filter"
      end
      super
    end
  end

  def test_caller_filter_refusal_does_not_disable_owner_prefilter
    coll = CallerPathRejectingColl.new(ranked_rows)
    cleared = []
    Parse::AtlasSearch::IndexManager.stub(:clear_cache, ->(c = nil) { cleared << c }) do
      err = assert_raises(StandardError) do
        vector_search(coll, index_def: vector_index(["_p_owner"]), vector_filter: { "kind" => "x" })
      end
      assert_match(/Path 'kind'/, err.message)
    end
    assert_equal 1, coll.pipelines.size, "a caller-path refusal is not retried"
    assert_empty cleared, "the index cache is left alone"

    coll2 = EvalColl.new(deep_vector_rows)
    vector_search(coll2, index_def: vector_index(["_p_owner"]))
    assert_equal({ "_p_owner" => { "$eq" => "_User$u1" } }, coll2.pipelines.first.dig(0, "$vectorSearch", "filter"),
                 "the owner prefilter is still pushed down for the next caller")
  end

  def test_native_hybrid_uses_default_vector_index_for_prefilter
    prior = Parse::VectorSearch.default_index
    Parse::VectorSearch.default_index = "vec_idx"
    looked_up = []
    pipe = Parse::ACLScope.stub(:resolve!, ->(*, **) { session_resolution }) do
      lookup = ->(_coll, name) { looked_up << name; vector_index(["_p_owner"]) }
      Parse::AtlasSearch::IndexManager.stub(:get_index, lookup) do
        Parse::VectorSearch::Hybrid.send(
          :native_pipeline, "Doc",
          lexical: { query: "t", index: "default" },
          vector: { query_vector: [0.1, 0.2], field: "embedding" },
          k: 5,
        )
      end
    end
    vs = pipe.dig(0, "$rankFusion", "input", "pipelines", "vector", 0, "$vectorSearch")
    assert_equal "vec_idx", vs["index"]
    assert_equal ["vec_idx"], looked_up.uniq
    assert_equal({ "_p_owner" => { "$eq" => "_User$u1" } }, vs["filter"])
  ensure
    Parse::VectorSearch.default_index = prior
  end

  def test_vector_other_errors_are_not_retried
    coll = EvalColl.new(ranked_rows)
    def coll.aggregate(pipeline, _opts = {})
      @pipelines << pipeline
      raise StandardError, "operation exceeded time limit"
    end
    assert_raises(StandardError) { vector_search(coll, index_def: vector_index(["_p_owner"])) }
    assert_equal 1, coll.pipelines.size
  end

  def test_failed_index_lookup_is_cached_for_the_ttl
    calls = 0
    lookup = ->(*) { calls += 1; raise "not authorized on db to execute command listSearchIndexes" }
    2.times do
      coll = EvalColl.new(ranked_rows)
      with_coll(coll) do
        Parse::AtlasSearch::IndexManager.stub(:get_index, lookup) do
          Parse::VectorSearch.search("Doc", field: "embedding", query_vector: [0.1, 0.2, 0.3], k: 5, index: "vec_idx")
        end
      end
    end
    assert_equal 1, calls, "a failed lookup must not be repeated on every search"
  end

  def test_native_hybrid_filters_ownership_inside_each_input
    pipe = Parse::ACLScope.stub(:resolve!, ->(*, **) { session_resolution }) do
      Parse::AtlasSearch::IndexManager.stub(:get_index, ->(*) { vector_index(["_p_owner"]) }) do
        Parse::VectorSearch::Hybrid.send(
          :native_pipeline, "Doc",
          lexical: { query: "t", index: "default" },
          vector: { query_vector: [0.1, 0.2], field: "embedding", index: "vec_idx" },
          k: 5,
        )
      end
    end
    inputs = pipe.dig(0, "$rankFusion", "input", "pipelines")
    assert_equal({ "_p_owner" => { "$eq" => "_User$u1" } }, inputs["vector"].dig(0, "$vectorSearch", "filter"))
    lexical = inputs["lexical"]
    owner_at = lexical.index { |s| s["$match"].to_s.include?("_p_owner") }
    limit_at = lexical.index { |s| s.key?("$limit") }
    refute_nil owner_at, "the lexical input filters ownership"
    assert_operator owner_at, :<, limit_at, "before the per-input $limit"
  end

  # ---- native $rankFusion ---------------------------------------------

  def test_native_hybrid_pointer_match_runs_before_limit
    pipe = Parse::ACLScope.stub(:resolve!, ->(*, **) { session_resolution }) do
      Parse::VectorSearch::Hybrid.send(
        :native_pipeline, "Doc",
        lexical: { query: "t", index: "default" },
        vector: { query_vector: [0.1, 0.2], field: "embedding", index: "vec_idx" },
        k: 5,
      )
    end

    pointer_at = pipe.index { |s| s["$match"].to_s.include?("_p_owner") }
    limit_at = pipe.index { |s| s.key?("$limit") }
    refute_nil pointer_at, "the native pipeline must carry the ownership $match"
    assert_operator pointer_at, :<, limit_at
  end
end
