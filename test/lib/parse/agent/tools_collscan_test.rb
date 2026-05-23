# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

class ToolsCollscanTest < Minitest::Test
  T = Parse::Agent::Tools

  def setup
    Parse::Agent::Tools.reset_registry!
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
    @agent = Parse::Agent.new(permissions: :readonly)
    # Default: refuse_collscan off
    Parse::Agent.refuse_collscan = false
  end

  def teardown
    Parse::Agent::Tools.reset_registry!
    Parse::Agent.refuse_collscan = false
    Parse::Agent.expose_explain = false
  end

  # ---------------------------------------------------------------------------
  # collscan? — unit tests (private method, tested via send)
  # ---------------------------------------------------------------------------

  def test_collscan_detects_top_level_collscan
    plan = { "stage" => "COLLSCAN" }
    assert T.send(:collscan?, plan)
  end

  def test_collscan_detects_nested_collscan_under_inputStage
    plan = {
      "stage" => "FETCH",
      "inputStage" => { "stage" => "COLLSCAN" },
    }
    assert T.send(:collscan?, plan)
  end

  def test_collscan_detects_deeply_nested_collscan
    plan = {
      "stage" => "PROJECTION",
      "inputStage" => {
        "stage" => "FETCH",
        "inputStage" => { "stage" => "COLLSCAN" },
      },
    }
    assert T.send(:collscan?, plan)
  end

  def test_collscan_detects_collscan_in_inputStages_array
    plan = {
      "stage" => "OR",
      "inputStages" => [
        { "stage" => "IXSCAN", "keyPattern" => { "name" => 1 } },
        { "stage" => "COLLSCAN" },
      ],
    }
    assert T.send(:collscan?, plan)
  end

  def test_collscan_returns_false_for_ixscan
    plan = {
      "stage" => "FETCH",
      "inputStage" => {
        "stage" => "IXSCAN",
        "keyPattern" => { "plays" => 1 },
      },
    }
    refute T.send(:collscan?, plan)
  end

  def test_collscan_returns_false_for_nil
    refute T.send(:collscan?, nil)
  end

  def test_collscan_returns_false_for_non_hash
    refute T.send(:collscan?, "COLLSCAN")
    refute T.send(:collscan?, [])
  end

  def test_collscan_returns_false_for_empty_hash
    refute T.send(:collscan?, {})
  end

  # ---------------------------------------------------------------------------
  # refuse_collscan = false (default) — no pre-flight fired
  # ---------------------------------------------------------------------------

  def test_refuse_collscan_off_does_not_preflight_query_class
    Parse::Agent.refuse_collscan = false

    explain_called = false
    returned_objects = [{ "objectId" => "abc1234567" }]
    fake_results_response = build_success_response(returned_objects)

    @agent.client.stub(:find_objects, ->(cn, query, **opts) {
      explain_called = true if query[:explain]
      fake_results_response
    }) do
      T.query_class(@agent, class_name: "Song", where: { "status" => "active" })
    end

    refute explain_called, "explain should not be called when refuse_collscan is false"
  end

  # ---------------------------------------------------------------------------
  # refuse_collscan = true — pre-flight on non-empty where
  # ---------------------------------------------------------------------------

  def test_refuse_collscan_on_refuses_collscan_query
    Parse::Agent.refuse_collscan = true

    # Simulate explain returning a COLLSCAN plan
    collscan_explain = {
      "queryPlanner" => {
        "winningPlan" => { "stage" => "COLLSCAN" },
      },
    }
    fake_explain_response = build_explain_response(collscan_explain)

    @agent.client.stub(:find_objects, fake_explain_response) do
      result = T.query_class(@agent, class_name: "Song", where: { "status" => "active" })
      assert result[:refused], "should return a refused result for COLLSCAN"
      assert_equal "COLLSCAN on Song", result[:reason]
      assert_kind_of String, result[:suggestion]
    end
  end

  def test_refuse_collscan_on_allows_ixscan_query
    Parse::Agent.refuse_collscan = true

    explain_called_count = 0
    ixscan_plan = {
      "queryPlanner" => {
        "winningPlan" => {
          "stage" => "FETCH",
          "inputStage" => { "stage" => "IXSCAN" },
        },
      },
    }
    returned_objects = [{ "objectId" => "abc1234567" }]

    @agent.client.stub(:find_objects, ->(cn, query, **opts) {
      if query[:explain]
        explain_called_count += 1
        build_explain_response(ixscan_plan)
      else
        build_success_response(returned_objects)
      end
    }) do
      result = T.query_class(@agent, class_name: "Song", where: { "status" => "active" })
      # Should not be refused
      refute result.key?(:refused), "IXSCAN query should not be refused"
    end

    assert_equal 1, explain_called_count, "explain should be called exactly once for pre-flight"
  end

  # ---------------------------------------------------------------------------
  # Empty where skips pre-flight even when refuse_collscan = true
  # ---------------------------------------------------------------------------

  def test_refuse_collscan_on_empty_where_skips_preflight
    Parse::Agent.refuse_collscan = true

    explain_called = false
    returned_objects = [{ "objectId" => "abc1234567" }]

    @agent.client.stub(:find_objects, ->(cn, query, **opts) {
      explain_called = true if query[:explain]
      build_success_response(returned_objects)
    }) do
      T.query_class(@agent, class_name: "Song")
    end

    refute explain_called, "explain should not be called when where is empty"
  end

  def test_refuse_collscan_on_nil_where_skips_preflight
    Parse::Agent.refuse_collscan = true

    explain_called = false
    returned_objects = [{ "objectId" => "abc1234567" }]

    @agent.client.stub(:find_objects, ->(cn, query, **opts) {
      explain_called = true if query[:explain]
      build_success_response(returned_objects)
    }) do
      T.query_class(@agent, class_name: "Song", where: nil)
    end

    refute explain_called
  end

  # ---------------------------------------------------------------------------
  # agent_allow_collscan bypasses refusal
  # ---------------------------------------------------------------------------

  def test_agent_allow_collscan_bypasses_refusal
    Parse::Agent.refuse_collscan = true

    # Register a model class with agent_allow_collscan
    klass_name = "CollscanAllowedModel"
    original_method = Parse::Agent::MetadataRegistry.method(:allow_collscan?)
    Parse::Agent::MetadataRegistry.define_singleton_method(:allow_collscan?) do |cn|
      cn == klass_name ? true : original_method.call(cn)
    end

    explain_called = false
    returned_objects = [{ "objectId" => "abc1234567" }]

    @agent.client.stub(:find_objects, ->(cn, query, **opts) {
      explain_called = true if query[:explain]
      build_success_response(returned_objects)
    }) do
      result = T.query_class(@agent, class_name: klass_name, where: { "x" => 1 })
      refute result.key?(:refused), "collscan-allowed class should not be refused"
    end

    refute explain_called, "explain should not be called for collscan-allowed class"
  ensure
    Parse::Agent::MetadataRegistry.define_singleton_method(:allow_collscan?, &original_method)
  end

  # ---------------------------------------------------------------------------
  # aggregate pre-flight with leading $match
  # ---------------------------------------------------------------------------

  def test_refuse_collscan_on_aggregate_refuses_collscan_pipeline
    Parse::Agent.refuse_collscan = true

    collscan_explain = {
      "queryPlanner" => {
        "winningPlan" => { "stage" => "COLLSCAN" },
      },
    }
    fake_explain = build_explain_response(collscan_explain)

    @agent.client.stub(:find_objects, fake_explain) do
      pipeline = [
        { "$match" => { "status" => "active" } },
        { "$group" => { "_id" => "$status", "count" => { "$sum" => 1 } } },
      ]
      result = T.aggregate(@agent, class_name: "Song", pipeline: pipeline)
      assert result[:refused]
      assert_match(/COLLSCAN/, result[:reason])
    end
  end

  def test_refuse_collscan_on_aggregate_skips_preflight_without_match
    Parse::Agent.refuse_collscan = true

    explain_called = false
    aggregate_results = [{ "_id" => "active", "count" => 5 }]
    fake_agg_response = Minitest::Mock.new
    fake_agg_response.expect(:success?, true)
    fake_agg_response.expect(:results, aggregate_results)

    @agent.client.stub(:find_objects, ->(cn, query, **opts) {
      explain_called = true if query[:explain]
      # Should not be called since no $match leads the pipeline
      raise "find_objects should not be called"
    }) do
      @agent.client.stub(:aggregate_pipeline, fake_agg_response) do
        pipeline = [
          { "$group" => { "_id" => "$status", "count" => { "$sum" => 1 } } },
        ]
        T.aggregate(@agent, class_name: "Song", pipeline: pipeline)
      end
    end

    refute explain_called
  end

  # ---------------------------------------------------------------------------
  # expose_explain flag controls winning_plan in COLLSCAN refusal responses
  # ---------------------------------------------------------------------------

  def test_expose_explain_false_omits_winning_plan_from_collscan_refusal
    Parse::Agent.refuse_collscan = true
    Parse::Agent.expose_explain  = false  # explicit default

    collscan_explain = {
      "queryPlanner" => {
        "winningPlan" => { "stage" => "COLLSCAN" },
      },
    }
    fake_explain_response = build_explain_response(collscan_explain)

    @agent.client.stub(:find_objects, fake_explain_response) do
      result = T.query_class(@agent, class_name: "Song", where: { "status" => "active" })
      assert result[:refused]
      assert_equal "COLLSCAN on Song", result[:reason]
      refute result.key?(:winning_plan),
             "winning_plan must NOT be present when expose_explain is false (default)"
    end
  end

  def test_expose_explain_true_includes_winning_plan_in_collscan_refusal
    Parse::Agent.refuse_collscan = true
    Parse::Agent.expose_explain  = true

    collscan_explain = {
      "queryPlanner" => {
        "winningPlan" => { "stage" => "COLLSCAN" },
      },
    }
    fake_explain_response = build_explain_response(collscan_explain)

    @agent.client.stub(:find_objects, fake_explain_response) do
      result = T.query_class(@agent, class_name: "Song", where: { "status" => "active" })
      assert result[:refused]
      assert result.key?(:winning_plan),
             "winning_plan must be present when expose_explain is true"
      assert_kind_of String, result[:winning_plan]
      assert_includes result[:winning_plan], "COLLSCAN"
    end
  end

  # ---------------------------------------------------------------------------
  # MetadataDSL agent_allow_collscan DSL
  # ---------------------------------------------------------------------------

  def test_agent_allow_collscan_dsl_getter_returns_false_by_default
    # Create an anonymous class that includes MetadataDSL
    klass = Class.new do
      include Parse::Agent::MetadataDSL
    end
    refute klass.agent_allow_collscan?
  end

  def test_agent_allow_collscan_dsl_setter_and_getter
    klass = Class.new do
      include Parse::Agent::MetadataDSL
      agent_allow_collscan true
    end
    assert klass.agent_allow_collscan?
  end

  def test_agent_allow_collscan_false_disables_it
    klass = Class.new do
      include Parse::Agent::MetadataDSL
      agent_allow_collscan true
      agent_allow_collscan false
    end
    refute klass.agent_allow_collscan?
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  private

  def build_success_response(results)
    fake = Minitest::Mock.new
    fake.expect(:success?, true)
    fake.expect(:results, results)
    fake
  end

  def build_explain_response(explanation)
    fake = Minitest::Mock.new
    fake.expect(:success?, true)
    fake.expect(:result, explanation)
    fake
  end
end
