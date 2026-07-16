# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"

# Unit tests for Parse::MongoDB.prepend_or_fold_acl_match — the seam that
# keeps a scoped `$geoNear` query at pipeline stage 0.
#
# MongoDB requires `$geoNear` to be the FIRST pipeline stage. The generic
# aggregate path prepends the scoped ACL `$match` at index 0, which for a
# `$geoNear` pipeline pushes `$geoNear` to index 1 — MongoDB then rejects
# the whole pipeline (a scoped `geo_near` fails closed). The fold folds
# the ACL predicate into `$geoNear.query` instead, preserving stage 0.
class MongoDBGeoNearACLFoldTest < Minitest::Test
  ACL_STAGE = { "$match" => { "$or" => [{ "_rperm" => { "$in" => %w[U1 *] } },
                                        { "_rperm" => { "$exists" => false } }] } }.freeze

  def fold(pipeline)
    Parse::MongoDB.send(:prepend_or_fold_acl_match, pipeline, ACL_STAGE)
  end

  def test_non_geo_pipeline_prepends_acl_match_at_stage_zero
    pipeline = [{ "$match" => { "genre" => "Rock" } }, { "$limit" => 10 }]
    result = fold(pipeline)
    assert_equal ACL_STAGE, result.first, "ACL $match must be prepended for non-geo pipelines"
    assert_equal 3, result.length
  end

  def test_geo_near_first_folds_acl_into_query_and_keeps_stage_zero
    pipeline = [{ :$geoNear => { near: { type: "Point", coordinates: [0, 0] },
                                 distanceField: "dist", spherical: true } },
                { :$limit => 5 }]
    result = fold(pipeline)
    # $geoNear must remain the first stage.
    assert result.first.key?(:$geoNear), "$geoNear must stay at stage 0"
    refute result.any? { |s| s.key?("$match") || s.key?(:$match) },
           "no standalone $match may be injected ahead of $geoNear"
    # The ACL predicate must be folded into $geoNear.query.
    assert_equal ACL_STAGE["$match"], result.first[:$geoNear][:query],
                 "ACL predicate must be folded into $geoNear.query"
  end

  def test_geo_near_with_existing_query_combines_with_and
    pipeline = [{ :$geoNear => { near: { type: "Point", coordinates: [1, 2] },
                                 distanceField: "dist",
                                 query: { "status" => "published" } } }]
    result = fold(pipeline)
    q = result.first[:$geoNear][:query]
    assert q.key?("$and"), "existing query and ACL predicate must combine under $and"
    assert_includes q["$and"], { "status" => "published" }
    assert_includes q["$and"], ACL_STAGE["$match"]
  end

  def test_fold_does_not_mutate_caller_pipeline
    geo = { near: { type: "Point", coordinates: [0, 0] }, distanceField: "dist" }
    pipeline = [{ :$geoNear => geo }]
    fold(pipeline)
    refute geo.key?(:query), "caller's $geoNear stage must not be mutated in place"
  end

  def test_string_keyed_geo_near_is_recognized
    pipeline = [{ "$geoNear" => { "near" => { "type" => "Point", "coordinates" => [0, 0] },
                                  "distanceField" => "dist" } }]
    result = fold(pipeline)
    assert result.first.key?("$geoNear"), "$geoNear (string key) must stay at stage 0"
    assert_equal ACL_STAGE["$match"], result.first["$geoNear"]["query"]
  end

  # The folded pipeline must not share the caller's `$geoNear.query` hash:
  # mutating the caller's query afterwards must not change the folded result
  # (and vice versa). Guards the shallow-copy aliasing the outer .dup missed.
  def test_folded_query_does_not_alias_callers_query_hash
    caller_query = { "status" => "published" }
    pipeline = [{ :$geoNear => { near: { type: "Point", coordinates: [1, 2] },
                                 distanceField: "dist", query: caller_query } }]
    result = fold(pipeline)
    folded_existing = result.first[:$geoNear][:query]["$and"][0]
    refute_same caller_query, folded_existing,
                "the folded pipeline must embed a copy of the caller's query, not the same object"

    # Mutating the caller's query after folding must not leak into the result.
    caller_query["injected"] = true
    refute folded_existing.key?("injected"),
           "mutating the caller's $geoNear.query must not change the folded pipeline"
  end
end
