# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Tests for the agent_canonical_filter DSL + apply-by-default mechanism.
#
# A class can declare a Mongo-style "valid state" filter that the agent's
# read tools (query_class, count_objects, aggregate) apply automatically
# to every call. Callers opt out with apply_canonical_filter: false.
class CanonicalFilterTest < Minitest::Test
  class CFCapture < Parse::Object
    parse_class "CFCapture"
    property :title, :string
    property :isRemoved, :boolean
    property :onTimeline, :boolean

    agent_canonical_filter "isRemoved" => { "$ne" => true },
                           "onTimeline" => true
  end

  class CFUntouchedClass < Parse::Object
    parse_class "CFUntouchedClass"
    property :title, :string
  end

  # ---- DSL storage ---------------------------------------------------------

  def test_dsl_returns_filter_when_declared
    assert_equal({ "isRemoved" => { "$ne" => true }, "onTimeline" => true },
                 CFCapture.agent_canonical_filter_for_apply)
  end

  def test_dsl_returns_nil_when_not_declared
    assert_nil CFUntouchedClass.agent_canonical_filter_for_apply
  end

  class CFTemp < Parse::Object
    parse_class "CFTemp"
  end

  def test_dsl_refuses_non_hash_input
    assert_raises(ArgumentError) { CFTemp.agent_canonical_filter("not a hash") }
    assert_raises(ArgumentError) { CFTemp.agent_canonical_filter(42) }
  end

  # ---- Registry lookup -----------------------------------------------------

  def test_metadata_registry_canonical_filter
    assert_equal({ "isRemoved" => { "$ne" => true }, "onTimeline" => true },
                 Parse::Agent::MetadataRegistry.canonical_filter("CFCapture"))
    assert_nil Parse::Agent::MetadataRegistry.canonical_filter("CFUntouchedClass")
    assert_nil Parse::Agent::MetadataRegistry.canonical_filter("DoesNotExist")
  end

  # ---- apply_canonical_filter_to_where -------------------------------------

  def test_apply_to_where_when_caller_where_is_nil
    result = Parse::Agent::Tools.apply_canonical_filter_to_where(nil, "CFCapture")
    assert_equal({ "isRemoved" => { "$ne" => true }, "onTimeline" => true }, result)
  end

  def test_apply_to_where_when_caller_where_is_empty_hash
    result = Parse::Agent::Tools.apply_canonical_filter_to_where({}, "CFCapture")
    assert_equal({ "isRemoved" => { "$ne" => true }, "onTimeline" => true }, result)
  end

  def test_apply_to_where_composes_via_and_with_caller_where
    caller_where = { "title" => "Hello" }
    result = Parse::Agent::Tools.apply_canonical_filter_to_where(caller_where, "CFCapture")
    assert_equal [
      { "isRemoved" => { "$ne" => true }, "onTimeline" => true },
      { "title" => "Hello" },
    ], result["$and"]
  end

  def test_apply_to_where_returns_caller_where_when_no_filter_declared
    caller_where = { "title" => "Hello" }
    result = Parse::Agent::Tools.apply_canonical_filter_to_where(caller_where, "CFUntouchedClass")
    assert_equal caller_where, result
  end

  # ---- apply_canonical_filter_to_pipeline ----------------------------------

  def test_apply_to_pipeline_prepends_match_stage_when_no_leading_match
    pipeline = [{ "$group" => { "_id" => "$title" } }]
    result = Parse::Agent::Tools.apply_canonical_filter_to_pipeline(pipeline, "CFCapture")
    assert_equal 2, result.size
    assert_equal({ "isRemoved" => { "$ne" => true }, "onTimeline" => true },
                 result[0]["$match"])
    assert_equal pipeline[0], result[1]
  end

  def test_apply_to_pipeline_inserts_after_leading_tenant_scope_match
    # A leading $match (tenant scope) stays at index 0 so the canonical
    # filter sits at index 1.
    pipeline = [
      { "$match" => { "orgId" => "tenant-A" } },
      { "$group" => { "_id" => "$title" } },
    ]
    result = Parse::Agent::Tools.apply_canonical_filter_to_pipeline(pipeline, "CFCapture")
    assert_equal 3, result.size
    assert_equal({ "orgId" => "tenant-A" }, result[0]["$match"])
    assert_equal({ "isRemoved" => { "$ne" => true }, "onTimeline" => true }, result[1]["$match"])
    assert_equal pipeline[1], result[2]
  end

  def test_apply_to_pipeline_returns_unchanged_when_no_filter_declared
    pipeline = [{ "$group" => { "_id" => "$title" } }]
    result = Parse::Agent::Tools.apply_canonical_filter_to_pipeline(pipeline, "CFUntouchedClass")
    assert_equal pipeline, result
  end

  # ---- Integration with query_class / count / aggregate via stub client ----

  class FakeFilterClient
    attr_reader :received_query, :received_pipeline

    def find_objects(_class, query, **_opts)
      @received_query = query
      response = Object.new
      response.define_singleton_method(:success?) { true }
      response.define_singleton_method(:count)    { 0 }
      response.define_singleton_method(:results)  { [] }
      response
    end

    def aggregate_pipeline(_class, pipeline, **_opts)
      @received_pipeline = pipeline
      response = Object.new
      response.define_singleton_method(:success?) { true }
      response.define_singleton_method(:results)  { [] }
      response.define_singleton_method(:error)    { nil }
      response
    end
  end

  def build_agent(client = FakeFilterClient.new)
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse", application_id: "t", api_key: "t")
    end
    agent = Parse::Agent.new
    agent.instance_variable_set(:@client, client)
    agent
  end

  def test_query_class_applies_canonical_filter_by_default
    client = FakeFilterClient.new
    agent  = build_agent(client)
    Parse::Agent::Tools.query_class(agent, class_name: "CFCapture")
    where = JSON.parse(client.received_query[:where])
    assert_equal({ "$ne" => true }, where["isRemoved"])
  end

  def test_query_class_opt_out_does_not_apply_filter
    client = FakeFilterClient.new
    agent  = build_agent(client)
    Parse::Agent::Tools.query_class(agent, class_name: "CFCapture", apply_canonical_filter: false)
    # No where: at all when caller didn't supply one.
    assert_nil client.received_query[:where]
  end

  def test_count_objects_applies_canonical_filter_by_default
    client = FakeFilterClient.new
    agent  = build_agent(client)
    Parse::Agent::Tools.count_objects(agent, class_name: "CFCapture")
    where = JSON.parse(client.received_query[:where])
    assert_equal({ "$ne" => true }, where["isRemoved"])
  end

  def test_aggregate_prepends_canonical_filter_by_default
    client = FakeFilterClient.new
    agent  = build_agent(client)
    Parse::Agent::Tools.aggregate(agent, class_name: "CFCapture",
                                  pipeline: [{ "$group" => { "_id" => "$title" } }])
    first = client.received_pipeline.first
    assert_equal({ "isRemoved" => { "$ne" => true }, "onTimeline" => true },
                 first["$match"])
  end

  def test_aggregate_opt_out_skips_canonical_filter
    client = FakeFilterClient.new
    agent  = build_agent(client)
    Parse::Agent::Tools.aggregate(agent, class_name: "CFCapture",
                                  pipeline: [{ "$group" => { "_id" => "$title" } }],
                                  apply_canonical_filter: false)
    # The auto-injected $limit is appended; the canonical filter is NOT prepended.
    refute client.received_pipeline.first.dig("$match", "isRemoved"),
           "canonical filter must not appear when opted out"
  end

  def test_query_class_compose_with_caller_where_via_and
    client = FakeFilterClient.new
    agent  = build_agent(client)
    Parse::Agent::Tools.query_class(agent, class_name: "CFCapture",
                                    where: { "title" => "Hello" })
    where = JSON.parse(client.received_query[:where])
    # $and-composed: caller constraint preserved, canonical predicate also applied.
    assert where["$and"].is_a?(Array)
    assert(where["$and"].any? { |c| c["isRemoved"] == { "$ne" => true } })
    assert(where["$and"].any? { |c| c["title"] == "Hello" })
  end
end
