# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"

# Integration tests for maxTimeMS pushdown (Proposal #11).
# These tests require a live MongoDB connection via the Docker test containers.
#
# Run with:
#   PARSE_TEST_USE_DOCKER=true ruby -Ilib:test \
#     test/lib/parse/mongodb_max_time_ms_integration_test.rb
class MongoDBMaxTimeMsIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # MongoDB URI for the Docker test containers (same as other direct integration tests)
  MONGODB_URI = (ENV["PARSE_TEST_MONGO_URI"] || "mongodb://admin:password@localhost:29017/parse_stack_next_it?authSource=admin")

  def setup
    super
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    begin
      require "mongo"
      require "parse/mongodb"
      Parse::MongoDB.configure(uri: MONGODB_URI, enabled: true)
    rescue LoadError => e
      skip "mongo gem not available: #{e.message}"
    rescue => e
      skip "MongoDB configuration failed: #{e.class}: #{e.message}"
    end
  end

  def teardown
    Parse::MongoDB.reset! if defined?(Parse::MongoDB)
    super
  end

  # ============================================================
  # Basic connectivity smoke test
  # ============================================================

  def test_aggregate_returns_results_without_timeout
    # Verify that a normal, fast aggregation works correctly without any budget.
    # `master: true` opts past the SDK-side CLP/ACL enforcement that `aggregate`
    # applies for non-master scopes — these tests assert SDK timeout behavior
    # against `_User`, not the permission model.
    pipeline = [{ "$limit" => 1 }]
    # Should not raise — returns an Array (possibly empty if the collection is empty)
    results = Parse::MongoDB.aggregate("_User", pipeline, master: true)
    assert_kind_of Array, results
  end

  # ============================================================
  # maxTimeMS enforcement: slow query exceeds budget
  # ============================================================

  def test_aggregate_raises_execution_timeout_when_budget_exceeded
    # Use a heavier $group + $sort stage with a 1ms maxTimeMS budget so the
    # planner actually has to do work that exceeds the timer. A bare $match
    # on `_id $exists true` returns in microseconds on a fast local Mongo
    # even across thousands of rows, so it does not reliably trip the timer.
    # The denylist blocks $function/$where/$out so a heavier pipeline is
    # the only way to provoke a deterministic timeout without those.
    err = assert_raises(Parse::MongoDB::ExecutionTimeout) do
      Parse::MongoDB.aggregate(
        "_User",
        [
          { "$group" => { "_id" => "$username", "n" => { "$sum" => 1 } } },
          { "$sort" => { "n" => -1 } },
          { "$limit" => 100 },
        ],
        max_time_ms: 1,
        master: true,
      )
    end

    assert_equal 1, err.max_time_ms
    assert_equal "_User", err.collection_name
    assert_match(/max_time_ms=1ms/, err.message)
  end

  def test_aggregate_succeeds_with_generous_budget
    # A 10-second budget should be more than enough for a trivial pipeline.
    results = Parse::MongoDB.aggregate(
      "_User",
      [{ "$limit" => 1 }],
      max_time_ms: 10_000,
      master: true,
    )
    assert_kind_of Array, results
  end

  # ============================================================
  # find: maxTimeMS enforcement
  # ============================================================

  def test_find_raises_execution_timeout_when_budget_exceeded
    err = assert_raises(Parse::MongoDB::ExecutionTimeout) do
      Parse::MongoDB.find(
        "_User",
        { "_id" => { "$exists" => true } },
        limit: 1000,
        max_time_ms: 1,
      )
    end

    assert_equal 1, err.max_time_ms
    assert_equal "_User", err.collection_name
  end

  def test_find_succeeds_with_generous_budget
    results = Parse::MongoDB.find(
      "_User",
      {},
      limit: 1,
      max_time_ms: 10_000,
    )
    assert_kind_of Array, results
  end

  # ============================================================
  # Query#results_direct accepts max_time_ms
  # ============================================================

  def test_results_direct_accepts_max_time_ms_kwarg
    # Verify the keyword is accepted; a very tight budget should raise
    # ExecutionTimeout from inside results_direct. A bare find returns
    # in microseconds even at limit=100; an unindexed in-memory sort
    # reliably exceeds 1ms once the collection has any rows.
    # `master: true` opts past the SDK-side CLP/ACL enforcement on
    # `_User`; the test asserts timeout behavior, not the permission model.
    query = Parse::User.query.order(:username).limit(1000)

    err = assert_raises(Parse::MongoDB::ExecutionTimeout) do
      query.results_direct(max_time_ms: 1, master: true)
    end

    assert_equal 1, err.max_time_ms
  end

  def test_results_direct_works_without_max_time_ms
    query = Parse::User.query.limit(1)
    results = query.results_direct(master: true)
    assert_kind_of Array, results
  end
end
