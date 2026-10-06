# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"

class FinalReviewSubRef < Parse::Object
  parse_class "FinalReviewSubRef"
  property :label, :string
end

class FinalReviewSubItem < Parse::Object
  parse_class "FinalReviewSubItem"
  property :name, :string
  property :status, :string
  belongs_to :ref, as: :final_review_sub_ref
end

# Subquery operators (`$inQuery`, `$notInQuery`, `$select`, `$dontSelect`)
# nested under `$or` / `$and` / `$nor` have no MongoDB equivalent. The
# direct compiler must translate each into its own `$lookup` plus a match on
# the join result, at any depth, and never hand a raw subquery operator to
# MongoDB's `$match`.
class FinalReviewNestedSubqueryDirectTest < Minitest::Test
  SUBQUERY_OPS = %w[$inQuery $notInQuery $select $dontSelect].freeze

  def setup
    Parse.setup(server_url: "http://localhost:1337/parse", application_id: "test",
                api_key: "test", master_key: "mk") unless Parse::Client.client?
  end

  def pipeline_for(query)
    query.send(:build_direct_mongodb_pipeline)
  end

  def compile(where)
    FinalReviewSubItem.query.send(:direct_subquery_stages, where)
  end

  def refute_raw_subquery(obj)
    text = obj.inspect
    SUBQUERY_OPS.each { |op| refute_includes text, "\"#{op}\"", text }
    SUBQUERY_OPS.each { |op| refute_includes text, ":#{op}", text }
  end

  def lookups(pipeline)
    pipeline.select { |s| s.key?("$lookup") }.map { |s| s["$lookup"] }
  end

  def in_query(label)
    { "$inQuery" => { "where" => { "label" => label }, "className" => "FinalReviewSubRef" } }
  end

  def test_or_where_with_in_query_compiles_to_lookup
    q = FinalReviewSubItem.query(name: "a").or_where(:ref.in_query => FinalReviewSubRef.query(label: "L1"))
    pipeline = pipeline_for(q)
    refute_raw_subquery(pipeline)
    joins = lookups(pipeline)
    assert_equal 1, joins.size
    assert_equal "FinalReviewSubRef", joins.first["from"]
    assert_includes joins.first["pipeline"], { "$match" => { "label" => "L1" } }
    temp = joins.first["as"]
    # The `$or` is matched AFTER the join, against the join result.
    lookup_idx = pipeline.index { |s| s.key?("$lookup") }
    or_idx = pipeline.index { |s| s.key?("$match") && s["$match"].key?("$or") }
    assert or_idx > lookup_idx, pipeline.inspect
    assert_equal [{ "name" => "a" }, { temp => { "$ne" => [] } }], pipeline[or_idx]["$match"]["$or"]
    unset = pipeline.find { |s| s.key?("$unset") }
    assert_includes Array(unset["$unset"]), temp
  end

  def test_each_nested_subquery_gets_its_own_lookup
    where = {
      "status" => "open",
      "$or" => [
        { "ref" => in_query("A") },
        { "ref" => { "$notInQuery" => { "where" => { "label" => "B" }, "className" => "FinalReviewSubRef" } } },
        { "$and" => [{ "name" => "x" }, { "name" => { "$select" => { "key" => "label", "query" => { "className" => "FinalReviewSubRef", "where" => {} } } } }] },
      ],
    }
    match, stages = compile(where)
    refute_raw_subquery([match, stages])
    assert_equal({ "status" => "open" }, match)
    joins = stages.select { |s| s.key?("$lookup") }.map { |s| s["$lookup"]["as"] }
    assert_equal 3, joins.size
    assert_equal joins.uniq, joins
    post = stages.find { |s| s.key?("$match") }["$match"]
    branches = post["$or"]
    assert_equal({ joins[0] => { "$ne" => [] } }, branches[0])
    assert_equal({ joins[1] => { "$eq" => [] } }, branches[1])
    assert_equal [{ "name" => "x" }, { joins[2] => { "$ne" => [] } }], branches[2]["$and"]
  end

  def test_nor_and_symbol_keys_and_mixed_operators
    where = {
      :"$nor" => [{ "ref" => { :"$inQuery" => { where: { "label" => "A" }, className: "FinalReviewSubRef" }, "$exists" => true } }],
    }
    match, stages = compile(where)
    refute_raw_subquery([match, stages])
    temp = stages.find { |s| s.key?("$lookup") }["$lookup"]["as"]
    post = stages.find { |s| s.key?("$match") }["$match"]
    assert_equal [{ "_p_ref" => { "$exists" => true }, temp => { "$ne" => [] } }], post["$nor"]
  end

  def test_top_level_and_nested_subqueries_together
    where = { "ref" => in_query("A"), "$or" => [{ "name" => "x" }, { "ref" => in_query("B") }] }
    match, stages = compile(where)
    refute_raw_subquery([match, stages])
    assert_equal({}, match)
    assert_equal 2, stages.count { |s| s.key?("$lookup") }
  end

  def test_logical_clause_without_subquery_stays_in_first_match
    where = { "$or" => [{ "name" => "x" }, { "name" => "y" }], "ref" => in_query("A") }
    match, = compile(where)
    assert_equal({ "$or" => [{ "name" => "x" }, { "name" => "y" }] }, match)
  end

  def test_untranslatable_nesting_fails_closed
    [
      { "name" => { "$not" => in_query("A") } },
      { "tags" => { "$elemMatch" => { "ref" => in_query("A") } } },
      { "$or" => [{ "$expr" => { "x" => in_query("A") } }] },
    ].each do |where|
      assert_raises(ArgumentError, "expected refusal for #{where.inspect}") { compile(where) }
    end
  end

  def test_results_direct_runs_nested_subquery_through_acl_scope
    q = FinalReviewSubItem.query(name: "a").or_where(:ref.in_query => FinalReviewSubRef.query(label: "L1"))
    seen = nil
    Parse::MongoDB.stub(:require_gem!, nil) do
      Parse::MongoDB.stub(:available?, true) do
        Parse::MongoDB.stub(:aggregate, ->(_t, p, **_kw) { seen = p; [] }) do
          q.results_direct(raw: true, session_token: "r:abc")
        end
      end
    end
    refute_raw_subquery(seen)
    assert seen.any? { |s| s.key?("$lookup") }
  end
end

# The aggregation path (`aggregate_from_query`, `count` / `group_by` with
# mongo-direct) translates only top-level `$inQuery` / `$notInQuery`. A
# nested subquery used to pass to MongoDB raw (under `$or`) or lose its
# enclosing operator (under `$not`); both now fail closed.
class FinalReviewNestedSubqueryAggregateTest < Minitest::Test
  def setup
    Parse.setup(server_url: "http://localhost:1337/parse", application_id: "test",
                api_key: "test", master_key: "mk") unless Parse::Client.client?
  end

  def test_or_where_subquery_in_aggregate_pipeline_fails_closed
    q = FinalReviewSubItem.query(name: "a").or_where(:ref.in_query => FinalReviewSubRef.query(label: "L1"))
    err = assert_raises(ArgumentError) { q.send(:build_query_aggregate_pipeline) }
    assert_match(/inQuery/, err.message)
    assert_raises(ArgumentError) { q.send(:build_aggregation_pipeline) }
  end

  def test_not_wrapped_subquery_is_refused_not_unwrapped
    where = { "ref" => { "$not" => { "$inQuery" => { "where" => {}, "className" => "FinalReviewSubRef" } } } }
    assert_raises(ArgumentError) { FinalReviewSubItem.query.send(:extract_subquery_to_lookup_stages, where) }
  end

  def test_top_level_in_query_still_translates
    q = FinalReviewSubItem.query(:ref.in_query => FinalReviewSubRef.query(label: "L1"))
    pipeline, = q.send(:build_query_aggregate_pipeline)
    refute_includes pipeline.inspect, "$inQuery"
    assert pipeline.any? { |s| s.key?("$lookup") }
  end
end
