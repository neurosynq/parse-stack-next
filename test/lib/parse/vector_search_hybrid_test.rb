# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/vector_search/hybrid"
require "parse/atlas_search"

# Unit tests for Parse::VectorSearch::Hybrid — the reciprocal-rank-fusion
# math, the $rankFusion probe-and-cache, the native pipeline SHAPE, and
# the client-side orchestration. No Atlas / Docker: the branch entry
# points and the Mongo probe are stubbed.
class VectorSearchHybridTest < Minitest::Test
  H = Parse::VectorSearch::Hybrid

  def setup
    H.clear_probe_cache
  end

  def teardown
    H.clear_probe_cache
  end

  # ----- pure RRF fusion -----

  def test_rrf_fuses_on_object_id_and_orders_by_score
    lex = [{ "_id" => "a", "_score" => 9.0 }, { "_id" => "b", "_score" => 8.0 }, { "_id" => "c", "_score" => 7.0 }]
    vec = [{ "_id" => "b", "_vscore" => 0.9 }, { "_id" => "d", "_vscore" => 0.8 }, { "_id" => "a", "_vscore" => 0.7 }]
    fused = H.rrf({ lexical: lex, vector: vec }, k_constant: 60)
    # b: lexical#2 + vector#1 (best combined), a: lexical#1 + vector#3.
    assert_equal %w[b a d c], fused.map { |r| r["_id"] }
    b = fused.first
    assert_equal({ lexical: 2, vector: 1 }, b["_hybrid_ranks"])
    # merged row carries BOTH branch scores.
    assert b.key?("_score")
    assert b.key?("_vscore")
    assert_operator b["_hybrid_score"], :>, fused[1]["_hybrid_score"]
  end

  def test_rrf_weights_shift_order
    lex = [{ "_id" => "x", "_score" => 1.0 }]
    vec = [{ "_id" => "y", "_vscore" => 1.0 }]
    # Heavily weight vector -> y outranks x even though both are rank 1.
    fused = H.rrf({ lexical: lex, vector: vec }, weights: { lexical: 0.1, vector: 0.9 })
    assert_equal "y", fused.first["_id"]
  end

  def test_rrf_zero_weight_branch_excluded
    lex = [{ "_id" => "x", "_score" => 1.0 }]
    vec = [{ "_id" => "y", "_vscore" => 1.0 }]
    fused = H.rrf({ lexical: lex, vector: vec }, weights: { lexical: 0, vector: 1 })
    assert_equal ["y"], fused.map { |r| r["_id"] }
  end

  def test_rrf_deterministic_tie_break_by_object_id
    # Both single-branch rank-1 -> equal scores -> ordered by id.
    lex = [{ "_id" => "zzz", "_score" => 1.0 }]
    vec = [{ "_id" => "aaa", "_vscore" => 1.0 }]
    fused = H.rrf({ lexical: lex, vector: vec }, weights: { lexical: 1, vector: 1 })
    assert_equal %w[aaa zzz], fused.map { |r| r["_id"] }
  end

  def test_rrf_rejects_bad_input
    assert_raises(H::FusionError) { H.rrf({}, k_constant: 60) }
    assert_raises(H::FusionError) { H.rrf({ a: [] }, k_constant: 0) }
    assert_raises(H::FusionError) { H.rrf({ a: [] }, weights: { a: -1 }) }
    assert_raises(H::FusionError) { H.rrf({ a: [] }, weights: "nope") }
  end

  # ----- $rankFusion probe-and-cache -----

  # Fake Mongo collection whose #aggregate runs a supplied proc.
  class FakeColl
    def initialize(behavior) = (@behavior = behavior)
    def aggregate(_pipeline) = self
    def to_a = @behavior.call
  end

  # Run `blk` with Parse::MongoDB.collection stubbed to a FakeColl whose
  # aggregate runs `behavior`.
  def with_probe_collection(behavior)
    Parse::MongoDB.stub(:collection, ->(_name) { FakeColl.new(behavior) }) { yield }
  end

  def test_probe_returns_true_when_stage_recognized
    with_probe_collection(-> { [] }) do
      assert_equal true, H.rank_fusion_supported?("Song")
    end
  end

  def test_probe_returns_false_on_unknown_stage_error
    with_probe_collection(-> { raise StandardError, "Unknown aggregation stage $rankFusion" }) do
      assert_equal false, H.rank_fusion_supported?("Song")
    end
  end

  def test_probe_treats_other_errors_as_supported
    # A recognized-but-misused stage (or auth error) is NOT "unsupported".
    with_probe_collection(-> { raise StandardError, "BSONObj exceeded maximum nested depth" }) do
      assert_equal true, H.rank_fusion_supported?("Song")
    end
  end

  def test_probe_result_is_cached_per_collection
    calls = 0
    with_probe_collection(-> { calls += 1; [] }) do
      H.rank_fusion_supported?("Song")
      H.rank_fusion_supported?("Song")
    end
    assert_equal 1, calls, "second probe should hit the cache"
  end

  # ----- native pipeline shape (security-relevant) -----

  def test_native_pipeline_is_stage0_rankfusion_with_subpipelines
    pipe = H.send(:native_pipeline, "Song",
      lexical: { query: "rain", index: "song_search" },
      vector: { query_vector: [0.1, 0.2], field: "embedding", index: "song_idx", num_candidates: 40 },
      k: 5, fusion: { weights: { lexical: 0.4, vector: 0.6 } }, master: true)
    assert_equal "$rankFusion", pipe.first.keys.first
    inputs = pipe.first["$rankFusion"]["input"]["pipelines"]
    assert_equal "$vectorSearch", inputs["vector"].first.keys.first
    assert_equal "$search", inputs["lexical"].first.keys.first
    assert_equal({ "vector" => 0.6, "lexical" => 0.4 }, pipe.first["$rankFusion"]["combination"]["weights"])
    # Fused score projected as a NUMBER via $meta:score, then sorted.
    assert_equal({ "$meta" => "score" }, pipe[1]["$addFields"]["_hybrid_score"])
    assert(pipe.any? { |s| s["$sort"] == { "_hybrid_score" => -1 } })
  end

  def test_native_pipeline_injects_acl_match_for_scoped_caller
    # A session-token scope (non-master) MUST get an ACL $match stage so
    # the fused candidate set is narrowed to _rperm-readable rows.
    fake_resolution = Object.new
    def fake_resolution.master? = false
    Parse::ACLScope.stub(:resolve!, ->(*) { fake_resolution }) do
      Parse::ACLScope.stub(:match_stage_for, ->(_r) { { "$match" => { "_rperm" => { "$in" => %w[u1] } } } }) do
        pipe = H.send(:native_pipeline, "Song",
          lexical: { query: "x", index: "i" },
          vector: { query_vector: [0.1], field: "e", index: "vi" },
          k: 3, session_token: "tok")
        assert(pipe.any? { |s| s["$match"] && s["$match"].key?("_rperm") },
               "scoped native pipeline must contain an ACL _rperm $match")
      end
    end
  end

  # ----- client-side orchestration (the default path) -----

  def test_search_default_fuses_client_side_without_probing
    lexical_rows = [{ "_id" => "a", "_score" => 5.0 }, { "_id" => "b", "_score" => 4.0 }]
    vector_rows  = [{ "_id" => "b", "_vscore" => 0.9 }, { "_id" => "c", "_vscore" => 0.8 }]
    probed = false
    Parse::MongoDB.stub(:require_gem!, nil) do
      Parse::MongoDB.stub(:available?, true) do
        H.stub(:rank_fusion_supported?, ->(_c) { probed = true; true }) do
          Parse::AtlasSearch.stub(:search, ->(*_a, **_k) { lexical_rows }) do
            Parse::VectorSearch.stub(:search, ->(*_a, **_k) { vector_rows }) do
              out = H.search("Song",
                lexical: { query: "rain" },
                vector: { query_vector: [0.1, 0.2], field: "embedding", index: "idx" },
                k: 10)
              assert_equal %w[b a c], out.map { |r| r["_id"] }
            end
          end
        end
      end
    end
    refute probed, "default :rrf method must NOT probe for native $rankFusion"
  end

  def test_search_validates_inputs
    Parse::MongoDB.stub(:require_gem!, nil) do
      Parse::MongoDB.stub(:available?, true) do
        assert_raises(ArgumentError) do
          H.search("Song", lexical: { query: "" }, vector: { query_vector: [0.1], field: "e" }, k: 5)
        end
        assert_raises(ArgumentError) do
          H.search("Song", lexical: { query: "x" }, vector: { field: "e" }, k: 5)
        end
        assert_raises(ArgumentError) do
          H.search("Song", lexical: { query: "x" }, vector: { query_vector: [0.1], field: "e" },
                   k: 5, fusion: { method: :bogus })
        end
      end
    end
  end
end
