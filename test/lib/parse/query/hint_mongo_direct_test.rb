# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Query#hint forwards to the mongo-direct path (Parse::MongoDB.aggregate `hint:`),
# not just the REST body. Stubs Parse::MongoDB so the test is deterministic and
# needs no live Mongo.
class TestHintMongoDirect < Minitest::Test
  def capture_aggregate_opts
    captured = nil
    Parse::MongoDB.stub(:require_gem!, nil) do
      Parse::MongoDB.stub(:available?, true) do
        agg = ->(_table, _pipeline, **opts) { captured = opts; [] }
        Parse::MongoDB.stub(:aggregate, agg) do
          yield
        end
      end
    end
    captured
  end

  def test_results_direct_forwards_hint
    opts = capture_aggregate_opts do
      Parse::Query.new("HintMongoDirectThing").hint("status_1_createdAt_-1").results_direct
    end
    refute_nil opts, "Parse::MongoDB.aggregate should have been called"
    assert_equal "status_1_createdAt_-1", opts[:hint]
  end

  def test_results_direct_without_hint_forwards_nil
    opts = capture_aggregate_opts do
      Parse::Query.new("HintMongoDirectThing").results_direct
    end
    assert_nil opts[:hint]
  end

  def test_hint_accepts_key_pattern_hash
    opts = capture_aggregate_opts do
      Parse::Query.new("HintMongoDirectThing").hint({ "status" => 1 }).results_direct
    end
    assert_equal({ "status" => 1 }, opts[:hint])
  end
end
