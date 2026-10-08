# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
begin
  require "bson"
rescue LoadError
  nil
end
require_relative "../../../lib/parse/live_query"

# Every caller-supplied regex goes through Parse::RegexSecurity, whatever path
# carries it: a raw `$regex` in a REST where hash, mongo-direct filters and
# pipelines, Parse::MongoDB.find, the agent constraint translator, LiveQuery,
# and webhook queries. Patterns the SDK builds from escaped input
# (starts_with, ends_with, contains) still pass.
class RegexRouting582Test < Minitest::Test
  UNSAFE = "(a+)+$"

  class RxPost < Parse::Object
    parse_class "RxPost"
    property :name, :string
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1/parse", application_id: "a",
                  api_key: "k", master_key: "mk")
    end
  end

  def compile(query)
    query.compile(encode: false)[:where]
  end

  # REST where hashes

  def test_raw_regex_in_where_hash_is_refused
    [{ name: { "$regex" => UNSAFE } }, { "name" => { "$regex" => UNSAFE } }].each do |where|
      assert_raises(ArgumentError) { compile(RxPost.query(where)) }
    end
  end

  def test_raw_regex_under_eq_and_not_is_refused
    assert_raises(ArgumentError) { compile(RxPost.query(:name.eq => { "$regex" => UNSAFE })) }
    assert_raises(ArgumentError) { compile(RxPost.query(:name.not => { "$regex" => UNSAFE })) }
  end

  def test_raw_regex_in_or_branch_is_refused
    assert_raises(ArgumentError) do
      compile(RxPost.query(:or => [{ name: { "$regex" => UNSAFE } }, { name: "x" }]))
    end
  end

  def test_raw_regex_options_are_checked
    err = assert_raises(ArgumentError) { compile(RxPost.query(name: { "$regex" => "^a", "$options" => "iq" })) }
    assert_match(/unsupported flags/, err.message)
    where = compile(RxPost.query(name: { "$regex" => "^a", "$options" => "iu" }))
    assert_equal "^a", JSON.parse(where.to_json)["name"]["$regex"]
  end

  def test_safe_raw_regex_and_sdk_built_patterns_still_compile
    assert_equal "^abc", JSON.parse(compile(RxPost.query(name: { "$regex" => "^abc" })).to_json)["name"]["$regex"]
    [
      RxPost.query(:name.contains => ""),
      RxPost.query(:name.contains => "(a+)+"),
      RxPost.query(:name.starts_with => "(a*)*"),
      RxPost.query(:name.ends_with => ".*.*"),
      RxPost.query(:name.like => /^bob/i),
    ].each { |q| refute_nil compile(q) }
  end

  # Mongo-direct filters, pipelines, and Parse::MongoDB.find

  def test_direct_filter_refuses_unsafe_patterns_in_every_form
    filters = [
      { "name" => { "$regex" => UNSAFE } },
      { "name" => /(a+)+$/ },
      { "$or" => [{ "name" => { "$regex" => UNSAFE } }] },
      { "$expr" => { "$regexMatch" => { "input" => "$name", "regex" => UNSAFE } } },
    ]
    filters << { "name" => BSON::Regexp::Raw.new(UNSAFE) } if defined?(BSON::Regexp::Raw)
    filters.each do |filter|
      err = assert_raises(Parse::PipelineSecurity::Error) { Parse::PipelineSecurity.validate_filter!(filter) }
      assert_equal :regex_unsafe, err.reason
    end
  end

  def test_direct_filter_checks_options
    err = assert_raises(Parse::PipelineSecurity::Error) do
      Parse::PipelineSecurity.validate_filter!({ "name" => { "$regex" => "^a", "$options" => "q" } })
    end
    assert_equal :regex_options_unsupported, err.reason
  end

  def test_direct_filter_allows_safe_and_sdk_built_patterns
    [
      { "name" => { "$regex" => "^abc", "$options" => "iu" } },
      { "name" => { "$regex" => ".*.*", "$options" => "i" } },
      { "name" => { "$regex" => ".*\\(a\\+\\)\\+.*", "$options" => "i" } },
      { "name" => /^bob/i },
    ].each { |filter| Parse::PipelineSecurity.validate_filter!(filter) }
  end

  def test_pipeline_match_refuses_unsafe_regex
    err = assert_raises(Parse::PipelineSecurity::Error) do
      Parse::PipelineSecurity.validate_pipeline!([{ "$match" => { "name" => { "$regex" => UNSAFE } } }])
    end
    assert_equal :regex_unsafe, err.reason
  end

  def test_mongodb_find_filter_refuses_unsafe_regex
    assert_raises(Parse::MongoDB::DeniedOperator) do
      Parse::MongoDB.assert_no_denied_operators!({ "name" => { "$regex" => UNSAFE } })
    end
  end

  def test_overlong_pattern_keeps_its_length_reason
    err = assert_raises(Parse::PipelineSecurity::Error) do
      # A non-literal pattern: escaped literal text gets a larger cap.
      Parse::PipelineSecurity.validate_filter!({ "name" => { "$regex" => "[ab]" * 150 } })
    end
    assert_equal :regex_pattern_too_long, err.reason
  end

  # Agent constraint translator

  def test_agent_translator_runs_regex_security
    # Overlapping alternation under a repeat is not caught by the
    # translator's own nested-quantifier heuristic, only by
    # Parse::RegexSecurity.
    err = assert_raises(Parse::Agent::ConstraintTranslator::ConstraintSecurityError) do
      Parse::Agent::ConstraintTranslator.translate({ "name" => { "$regex" => "(a|aa)+$" } })
    end
    assert_equal :regex_redos, err.reason
    assert Parse::Agent::ConstraintTranslator.translate({ "name" => { "$regex" => "^abc" } })
  end

  # LiveQuery and webhook queries

  def test_live_query_subscribe_refuses_unsafe_regex
    client = Parse::LiveQuery::Client.new(url: "wss://test.example.com", application_id: "a",
                                          client_key: "k", auto_connect: false)
    assert_raises(Parse::PipelineSecurity::Error) do
      client.subscribe("RxPost", where: { "name" => { "$regex" => UNSAFE } })
    end
  ensure
    Parse::LiveQuery.reset! if Parse::LiveQuery.respond_to?(:reset!)
  end

  def test_webhook_query_with_unsafe_regex_is_refused_when_compiled
    payload = Parse::Webhooks::Payload.new(
      { "triggerName" => "beforeFind", "query" => { "where" => { "name" => { "$regex" => UNSAFE } } } },
      "RxPost",
    )
    assert_raises(ArgumentError) { payload.parse_query.compile(encode: false) }
  end

  # Parse::MongoDB.find inside Parse.without_master_key

  def test_find_is_refused_inside_without_master_key
    err = assert_raises(Parse::ACLScope::ACLRequired) do
      Parse.without_master_key { Parse::MongoDB.find("RxPost", {}) }
    end
    assert_match(/without_master_key/, err.message)
  end

  def test_find_outside_the_block_is_not_refused_for_scope
    raised = begin
        Parse::MongoDB.find("RxPost", {})
        nil
      rescue StandardError => e
        e
      end
    refute_kind_of Parse::ACLScope::ACLRequired, raised
  end

  def test_indexes_stay_available_inside_without_master_key
    fake = Object.new
    def fake.indexes
      [{ "name" => "_id_" }]
    end
    Parse::MongoDB.stub(:collection, fake) do
      assert_equal [{ "name" => "_id_" }], Parse.without_master_key { Parse::MongoDB.indexes("RxPost") }
    end
  end
end
