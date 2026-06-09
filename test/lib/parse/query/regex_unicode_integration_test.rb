# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper_integration"
require "timeout"

# Integration test for the opt-in Unicode regex flag against a REAL
# Parse Server + MongoDB stack.
#
# The companion unit test (regex_unicode_option_unit_test.rb) pins the
# compiled wire shape (`$regex` + `$options: "iu"`). This test proves both
# execution paths actually ACCEPT that shape — MongoDB's documented
# `$options` letters are i/m/x/s, and the `u` flag is only valid on the
# PCRE2 engine (MongoDB 6.1+ / Parse Server 8.3.0+), so a regression here
# would surface as a server-side error on every unicode-flagged query
# while the wire-shape unit test kept passing:
#   (a) REST: `.results` through Parse Server.
#   (b) mongo-direct: `.results_direct` straight into the driver.
#
# Requires the Docker test stack (PARSE_TEST_USE_DOCKER=true) and the
# mongo gem. Run with:
#   PARSE_TEST_USE_DOCKER=true bundle exec ruby -Ilib:test \
#     test/lib/parse/query/regex_unicode_integration_test.rb
class UnicodeRegexItem < Parse::Object
  parse_class "UnicodeRegexItem"
  property :name, :string
end

class RegexUnicodeIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Same URI the other direct integration tests use.
  MONGODB_URI = (ENV["PARSE_TEST_MONGO_URI"] || "mongodb://admin:password@localhost:29017/parse_stack_next_it?authSource=admin")

  def setup
    super
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    begin
      require "mongo"
      require "parse/mongodb"
      Parse::MongoDB.configure(uri: MONGODB_URI, enabled: true)
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

  def seed!
    ["CAFÉ corner", "café latte", "plain coffee"].each_with_index do |name, i|
      item = UnicodeRegexItem.new(name: name)
      assert item.save, "setup: failed to save UnicodeRegexItem #{i}"
    end
    # Let the writes commit before the reads (mirrors sibling tests).
    sleep 0.5
  end

  # (a) REST path: Parse Server accepts $options "iu" and folds the
  # non-ASCII É/é pair case-insensitively.
  def test_unicode_contains_executes_over_rest
    Timeout.timeout(30) do
      seed!

      results = UnicodeRegexItem.query(
        :name.contains => { value: "café", unicode: true },
      ).results

      names = results.map(&:name).sort
      assert_equal ["CAFÉ corner", "café latte"], names,
                   "unicode contains over REST must fold É/é and exclude the ASCII row"
    end
  end

  # (b) mongo-direct path: the driver accepts $options "iu" (PCRE2 engine)
  # with identical results. The load-bearing assertion is that no
  # OperationFailure is raised — `u` is not one of MongoDB's documented
  # i/m/x/s letters, so acceptance is an engine property, not a given.
  def test_unicode_contains_executes_mongo_direct
    Timeout.timeout(30) do
      seed!

      results = UnicodeRegexItem.query(
        :name.contains => { value: "café", unicode: true },
      ).results_direct(master: true)

      names = results.map(&:name).sort
      assert_equal ["CAFÉ corner", "café latte"], names,
                   "unicode contains over mongo-direct must fold É/é and exclude the ASCII row"
    end
  end

  # The `like` hash form (explicit Regexp + unicode flag) executes
  # mongo-direct as well.
  def test_unicode_like_executes_mongo_direct
    Timeout.timeout(30) do
      seed!

      results = UnicodeRegexItem.query(
        :name.like => { value: /CAFÉ/i, unicode: true },
      ).results_direct(master: true)

      names = results.map(&:name).sort
      assert_equal ["CAFÉ corner", "café latte"], names,
                   "unicode like over mongo-direct must fold É/é and exclude the ASCII row"
    end
  end
end
