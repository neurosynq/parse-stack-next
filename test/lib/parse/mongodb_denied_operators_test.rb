require_relative "../../test_helper"
require "parse/mongodb"

# Tests the operator denylist that refuses $where / $function / $accumulator
# in raw filters and aggregation pipelines forwarded through
# Parse::MongoDB.find and Parse::MongoDB.aggregate. These operators all
# execute server-side JavaScript and bypass Parse Server ACL enforcement.
class MongoDBDeniedOperatorsTest < Minitest::Test
  def test_assert_no_denied_operators_passes_on_empty_filter
    assert_nil Parse::MongoDB.assert_no_denied_operators!({})
    assert_nil Parse::MongoDB.assert_no_denied_operators!([])
  end

  def test_assert_no_denied_operators_passes_on_normal_filter
    filter = { "name" => "alice", "age" => { "$gte" => 18 } }
    assert_nil Parse::MongoDB.assert_no_denied_operators!(filter)
  end

  def test_assert_no_denied_operators_passes_on_normal_pipeline
    pipeline = [
      { "$match" => { "status" => "active" } },
      { "$group" => { "_id" => "$category", "n" => { "$sum" => 1 } } },
      { "$sort" => { "n" => -1 } },
    ]
    assert_nil Parse::MongoDB.assert_no_denied_operators!(pipeline)
  end

  def test_assert_no_denied_operators_rejects_where_at_top_level
    err = assert_raises(Parse::MongoDB::DeniedOperator) do
      Parse::MongoDB.assert_no_denied_operators!({ "$where" => "this.score > 100" })
    end
    assert_match(/\$where/, err.message)
  end

  def test_assert_no_denied_operators_rejects_where_nested
    pipeline = [
      { "$match" => { "$where" => "function() { return this.x > sleep(99999); }" } },
    ]
    assert_raises(Parse::MongoDB::DeniedOperator) do
      Parse::MongoDB.assert_no_denied_operators!(pipeline)
    end
  end

  def test_assert_no_denied_operators_rejects_function
    pipeline = [{
      "$addFields" => {
        "computed" => {
          "$function" => {
            "body" => "function() { return 1 }",
            "args" => [],
            "lang" => "js",
          },
        },
      },
    }]
    assert_raises(Parse::MongoDB::DeniedOperator) do
      Parse::MongoDB.assert_no_denied_operators!(pipeline)
    end
  end

  def test_assert_no_denied_operators_rejects_accumulator
    pipeline = [{
      "$group" => {
        "_id" => "$kind",
        "stat" => { "$accumulator" => { "init" => "function() {}" } },
      },
    }]
    assert_raises(Parse::MongoDB::DeniedOperator) do
      Parse::MongoDB.assert_no_denied_operators!(pipeline)
    end
  end

  def test_assert_no_denied_operators_handles_symbol_keys
    assert_raises(Parse::MongoDB::DeniedOperator) do
      Parse::MongoDB.assert_no_denied_operators!({ :$where => "x" })
    end
  end

  def test_denied_operator_is_standard_error_subclass
    assert Parse::MongoDB::DeniedOperator < StandardError
  end
end
