# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/vector_search/hybrid"

# Unit tests for the v5.5 hybrid-search security follow-ups:
#   - NEW-VEC-2: unsupported_stage_error? no longer matches the broad
#     "is not allowed" phrase (authorization errors must not be
#     classified as unknown-stage probe results).
#   - NEW-VEC-1: _hybrid_score for non-master native results is
#     recomputed from the post-ACL visible ordering, so it carries no
#     information about hidden rows.
class VectorSearchHybridSecurityTest < Minitest::Test
  HYBRID = Parse::VectorSearch::Hybrid

  # ---------- NEW-VEC-2: probe-failure classification ----------

  def classify(message)
    HYBRID.send(:unsupported_stage_error?, StandardError.new(message))
  end

  def test_unknown_stage_phrases_classify_as_unsupported
    assert classify("Unrecognized pipeline stage name: '$rankFusion'")
    assert classify("Unknown aggregation stage $rankFusion")
    assert classify("unknown stage rankFusion in pipeline")
  end

  def test_authorization_error_is_not_classified_as_unsupported
    # The pre-fix list included "is not allowed", which matches MongoDB
    # authorization failures and would cache the wrong probe verdict.
    refute classify("user is not allowed to execute command aggregate with $rankFusion")
    refute classify("$rankFusion is not allowed in this context")
  end

  def test_unrelated_error_is_not_classified_as_unsupported
    refute classify("operation exceeded time limit")
    refute classify("Unrecognized pipeline stage name: '$weirdStage'")
  end

  # ---------- NEW-VEC-1: visible-order score recompute ----------

  def rows_with_scores(scores)
    scores.each_with_index.map do |s, i|
      { "_id" => "row#{i}", "_hybrid_score" => s }
    end
  end

  def test_recompute_replaces_scores_with_visible_rank_function
    rows = rows_with_scores([0.0321, 0.0289, 0.0164])
    HYBRID.send(:recompute_scores_from_visible_order!, rows,
                k_constant: 60, weights: nil)
    # weight 1.0 + 1.0 = 2.0; rank i+1 among VISIBLE rows.
    assert_in_delta 2.0 / 61, rows[0]["_hybrid_score"], 1e-12
    assert_in_delta 2.0 / 62, rows[1]["_hybrid_score"], 1e-12
    assert_in_delta 2.0 / 63, rows[2]["_hybrid_score"], 1e-12
  end

  def test_recomputed_scores_are_independent_of_hidden_rows
    # Same three visible rows, but in scenario B they survived a much
    # deeper fused ranking (huge raw-score gaps from hidden rows between
    # them). Post-recompute the two scenarios must be indistinguishable.
    visible_a = rows_with_scores([0.0321, 0.0320, 0.0319])
    visible_b = rows_with_scores([0.0321, 0.0150, 0.0021])
    [visible_a, visible_b].each do |rows|
      HYBRID.send(:recompute_scores_from_visible_order!, rows,
                  k_constant: 60, weights: nil)
    end
    assert_equal visible_a.map { |r| r["_hybrid_score"] },
                 visible_b.map { |r| r["_hybrid_score"] }
  end

  def test_recompute_preserves_descending_order
    rows = rows_with_scores([0.9, 0.5, 0.1, 0.05])
    HYBRID.send(:recompute_scores_from_visible_order!, rows,
                k_constant: 60, weights: nil)
    scores = rows.map { |r| r["_hybrid_score"] }
    assert_equal scores.sort.reverse, scores
  end

  def test_recompute_honors_branch_weights
    rows = rows_with_scores([0.5])
    HYBRID.send(:recompute_scores_from_visible_order!, rows,
                k_constant: 60, weights: { lexical: 0.4, vector: 0.6 })
    assert_in_delta 1.0 / 61, rows[0]["_hybrid_score"], 1e-12
  end

  def test_recompute_handles_empty_and_non_hash_rows
    assert_equal [], HYBRID.send(:recompute_scores_from_visible_order!, [],
                                 k_constant: 60, weights: nil)
    rows = [nil, { "_id" => "a", "_hybrid_score" => 0.5 }]
    HYBRID.send(:recompute_scores_from_visible_order!, rows,
                k_constant: 60, weights: nil)
    assert_in_delta 2.0 / 62, rows[1]["_hybrid_score"], 1e-12
  end
end
