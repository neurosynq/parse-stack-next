# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper_integration"
require "timeout"

# Integration test for Query#hint against a REAL MongoDB connection.
#
# The companion unit test (hint_mongo_direct_test.rb) proves the SDK forwards
# `hint:` into Parse::MongoDB.aggregate's options. This test proves the driver
# actually applies it end-to-end:
#   (a) .hint("<existing index>").results_direct returns the seeded rows.
#   (b) .hint("<bogus index>").results_direct fails fast with a raw
#       Mongo::Error::OperationFailure (the documented stale-hint signal — the
#       SDK only wraps code-50 timeouts, so a bad hint propagates unwrapped).
#
# Requires the Docker test stack (PARSE_TEST_USE_DOCKER=true) and the mongo gem.
# Run with:
#   PARSE_TEST_USE_DOCKER=true bundle exec ruby -Ilib:test \
#     test/lib/parse/query/hint_mongo_direct_integration_test.rb
class HintItem < Parse::Object
  parse_class "HintItem"
  property :category, :string
  property :label, :string
end

class HintMongoDirectIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Same URI the other direct integration tests use.
  MONGODB_URI = (ENV["PARSE_TEST_MONGO_URI"] || "mongodb://admin:password@localhost:29017/parse_stack_next_it?authSource=admin")

  INDEX_NAME = "hint_integ_category_1"
  CATEGORY = "hint_integ_seeds"

  def setup
    super
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    begin
      require "mongo"
      require "parse/mongodb"
      Parse::MongoDB.configure(uri: MONGODB_URI, enabled: true)
      # configure is lazy (connection deferred to first query). Ping now so an
      # auth/connectivity wrinkle surfaces here as a clean skip instead of an
      # error mid-test. Use a server ping, not a collection op — the DB was just
      # reset, so HintItem's collection doesn't exist yet (listing its indexes
      # would raise NamespaceNotFound and skip for the wrong reason).
      Parse::MongoDB.client.database.command(ping: 1)
    rescue LoadError => e
      skip "mongo gem not available: #{e.message}"
    rescue => e
      skip "MongoDB unavailable: #{e.class}: #{e.message}"
    end
  end

  def teardown
    Parse::MongoDB.reset! if defined?(Parse::MongoDB)
    super
  end

  # Seed a few rows and create the named index they can be queried under.
  def seed_and_index!
    3.times do |i|
      item = HintItem.new(category: CATEGORY, label: "item_#{i}")
      assert item.save, "setup: failed to save HintItem #{i}"
    end
    # Let the writes commit before the direct read (mirrors sibling tests).
    sleep 0.5
    Parse::MongoDB.collection("HintItem").indexes.create_one({ "category" => 1 }, name: INDEX_NAME)
  end

  # (a) A real, named index is honored and rows come back.
  def test_hint_named_index_returns_rows
    Timeout.timeout(30) do
      seed_and_index!

      results = HintItem.query(category: CATEGORY)
                        .hint(INDEX_NAME)
                        .results_direct(master: true)

      refute_empty results,
                   ".hint(#{INDEX_NAME.inspect}).results_direct must return the seeded rows"
      assert_equal 3, results.size,
                   "all seeded rows must be visible under the forced index hint"
      assert(results.all? { |r| r.category == CATEGORY },
             "every returned row must belong to the seeded category")
    end
  end

  # (b) A bogus index name fails fast — the documented stale-hint signal.
  def test_hint_nonexistent_index_raises_operation_failure
    Timeout.timeout(30) do
      item = HintItem.new(category: CATEGORY, label: "negative_case")
      assert item.save, "setup: failed to save HintItem"
      sleep 0.5

      err = assert_raises(Mongo::Error::OperationFailure) do
        HintItem.query(category: CATEGORY)
                .hint("nonexistent_index_xyz")
                .results_direct(master: true)
      end
      # Loose match — wording varies across MongoDB versions; the class is the
      # primary assertion.
      assert_match(/hint|index|nonexistent_index_xyz/i, err.message,
                   "OperationFailure message should reference the bad hint")
    end
  end
end
