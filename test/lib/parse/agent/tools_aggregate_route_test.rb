# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Defined at top level (not nested under the test class) so the schema
# lookup `Parse::Model.const_get(@table)` used by `field_is_pointer?`
# resolves successfully. Nested constants are reachable as
# `ToolsAggregateRouteTest::RouteCapture`, not `RouteCapture` — and the
# Query layer looks the latter up by bare name.
class RouteCapture < Parse::Object
  parse_class "RouteCapture"
  property :title, :string
  property :status, :string
  belongs_to :requested_by, as: :user, field: :requestedBy
  belongs_to :author, as: :user
end

# Covers the new `mongo_direct:` toggle on Parse::Agent::Tools.aggregate
# and the Parse::Query pipeline translator that feeds it.
#
# Two behaviors matter here:
#
#   1. When Parse::MongoDB isn't enabled (the common case in unit tests),
#      the toggle silently falls back to the Parse Server REST aggregate
#      route — the SDK never tries to dial out to a Mongo URI that
#      doesn't exist.
#   2. The Query-level pipeline translator applies the recursive
#      expression rewriter to every stage in a pipeline. This is the
#      shared helper the agent tool calls before handing the pipeline to
#      Parse::MongoDB.aggregate.
class ToolsAggregateRouteTest < Minitest::Test

  class FakeRouteClient
    attr_reader :received_pipeline, :aggregate_call_count

    def initialize
      @aggregate_call_count = 0
    end

    def aggregate_pipeline(_class, pipeline, **_opts)
      @aggregate_call_count += 1
      @received_pipeline = pipeline
      response = Object.new
      response.define_singleton_method(:success?) { true }
      response.define_singleton_method(:results)  { [] }
      response.define_singleton_method(:error)    { nil }
      response
    end
  end

  def setup
    @client = FakeRouteClient.new
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse", application_id: "t", api_key: "t")
    end
    @agent = Parse::Agent.new
    @agent.instance_variable_set(:@client, @client)
    # Sanity: tests in this file rely on MongoDB NOT being enabled so the
    # toggle's auto-fallback is exercised. If a previous test left the
    # module enabled, reset it here.
    Parse::MongoDB.reset! if defined?(Parse::MongoDB) && Parse::MongoDB.respond_to?(:reset!)
  end

  # When MongoDB isn't enabled, the default mongo_direct: true must NOT
  # raise — it falls back to the Parse Server aggregate route. The agent
  # client's aggregate_pipeline is the discriminator: it should be called
  # exactly once, and the result envelope should report "parse_server"
  # (String, coerced from Symbol so it matches the MCP output_schema).
  def test_default_falls_back_to_parse_server_when_mongo_not_enabled
    result = Parse::Agent::Tools.aggregate(
      @agent,
      class_name: "RouteCapture",
      pipeline:   [{ "$group" => { "_id" => "$status" } }],
      apply_canonical_filter: false,
    )

    assert_equal 1, @client.aggregate_call_count, "expected fallback to call client.aggregate_pipeline"
    assert_equal "parse_server", result[:route]
  end

  # Explicit mongo_direct: false must use the Parse Server route even if
  # MongoDB *were* enabled. This is the regression net for callers who
  # need the server-route behavior (audit logging, ACL re-checks).
  def test_explicit_false_uses_parse_server_route
    result = Parse::Agent::Tools.aggregate(
      @agent,
      class_name: "RouteCapture",
      pipeline:   [{ "$group" => { "_id" => "$status" } }],
      apply_canonical_filter: false,
      mongo_direct: false,
    )

    assert_equal 1, @client.aggregate_call_count
    assert_equal "parse_server", result[:route]
  end

  # Server-route pipeline must NOT be field-translated — Parse Server
  # expects logical names (`$status`, `$_p_author` only if the caller
  # wrote it that way). Verifies the translator runs only on the direct
  # path and doesn't bleed through to the REST endpoint.
  def test_server_route_pipeline_is_not_field_translated
    Parse::Agent::Tools.aggregate(
      @agent,
      class_name: "RouteCapture",
      pipeline:   [{ "$group" => { "_id" => "$author", "n" => { "$sum" => 1 } } }],
      apply_canonical_filter: false,
      mongo_direct: false,
    )

    # The captured pipeline is the post-policy form; $author is logical
    # and must survive unchanged because the server applies its own
    # field translation on the aggregate endpoint.
    group_stage = @client.received_pipeline.find { |s| s.key?("$group") }
    refute_nil group_stage
    assert_equal "$author", group_stage["$group"]["_id"]
  end

  # The Query-level translator is the shared helper the agent tool calls
  # when routing through direct MongoDB. It must walk every stage and
  # apply the expression rewriter recursively. We exercise it directly
  # here so the helper has unit coverage independent of the agent tool.
  def test_pipeline_translator_walks_every_stage
    query = Parse::Query.new("RouteCapture")
    pipeline = [
      { "$match"  => { "$expr" => { "$eq" => ["$author", "$requestedBy"] } } },
      { "$group"  => { "_id" => { "$cond" => [{ "$eq" => ["$requestedBy", nil] }, "system", "human"] },
                       "n"   => { "$sum" => 1 } } },
      { "$sort"   => { "n" => -1 } },
      { "$limit"  => 100 },
    ]

    translated = query.send(:translate_pipeline_for_direct_mongodb, pipeline)

    # Stage 1: $match with $expr rewrites both sides of $eq.
    eq_args = translated[0]["$match"]["$expr"]["$eq"]
    assert_equal "$_p_author",      eq_args[0]
    assert_equal "$_p_requestedBy", eq_args[1]

    # Stage 2: $group._id ($cond inside $eq with null) and accumulator
    # are both walked.
    cond_args = translated[1]["$group"]["_id"]["$cond"]
    assert_equal "$_p_requestedBy", cond_args[0]["$eq"][0]
    assert_nil cond_args[0]["$eq"][1]

    # Untouched stages (no field references) pass through structurally.
    assert_equal({ "n" => -1 },  translated[2]["$sort"])
    assert_equal({ "$limit" => 100 }, translated[3])
  end

  # Idempotency: translating an already-translated pipeline must be a
  # no-op. This is the regression net that allows callers to apply the
  # translator defensively without worrying about double-rewriting.
  def test_translator_is_idempotent
    query = Parse::Query.new("RouteCapture")
    pipeline = [
      { "$match" => { "$expr" => { "$eq" => ["$_p_author", "$_p_requestedBy"] } } },
      { "$group" => { "_id" => "$_p_requestedBy" } },
    ]

    once  = query.send(:translate_pipeline_for_direct_mongodb, pipeline)
    twice = query.send(:translate_pipeline_for_direct_mongodb, once)

    assert_equal once, twice
  end

  # Non-array input passes through. Defensive — the agent tool guards
  # before calling, but the helper itself shouldn't blow up on
  # malformed inputs.
  def test_translator_passes_non_array_through
    query = Parse::Query.new("RouteCapture")
    assert_nil  query.send(:translate_pipeline_for_direct_mongodb, nil)
    assert_equal "not a pipeline", query.send(:translate_pipeline_for_direct_mongodb, "not a pipeline")
  end

  # Session-less agents default to master:true on the mongo-direct path.
  # The agent's class/field/tenant/canonical-filter gates form the
  # security boundary for this posture; ACLScope row-filtering would
  # mask rows the agent is authorized to see. Pre-4.4.0 parity.
  def test_mongo_direct_auth_kwargs_defaults_to_master
    kwargs = Parse::Agent::Tools.send(:mongo_direct_auth_kwargs, @agent)
    assert_equal({ master: true }, kwargs)
  end

  # Session-tokened agents thread the token through to ACLScope so
  # the mongo-direct path enforces row-ACL the same way the REST route
  # does. Closes a real gap: pre-4.4.0 the token was dropped.
  def test_mongo_direct_auth_kwargs_uses_session_token_when_present
    agent = Parse::Agent.new(session_token: "r:tok_abc123")
    kwargs = Parse::Agent::Tools.send(:mongo_direct_auth_kwargs, agent)
    assert_equal({ session_token: "r:tok_abc123" }, kwargs)
  end

  # Defense: an LLM that puts master: true in a tool call's JSON args
  # cannot bypass agent_hidden via the mongo-direct path. The aggregate
  # tool's signature swallows unknown kwargs into **_kwargs which is
  # never propagated; the posture is built solely from agent state.
  def test_llm_master_kwarg_not_forwarded_to_mongo_direct
    # Verify the aggregate tool method ignores stray kwargs cleanly.
    # The actual MongoDB call isn't exercised here (Mongo not enabled in
    # this test file's setup) but the signature contract must hold:
    # extra kwargs must not raise and must not influence routing.
    result = Parse::Agent::Tools.aggregate(
      @agent,
      class_name: "RouteCapture",
      pipeline:   [{ "$group" => { "_id" => "$status" } }],
      apply_canonical_filter: false,
      # Hostile LLM-supplied kwargs:
      master: true,
      session_token: "r:malicious",
      acl_user: nil,
      acl_role: "scope:admin",
    )
    # Falls through to parse_server route (MongoDB not enabled). The
    # hostile kwargs were swallowed silently — no exception, no
    # routing change.
    assert_equal "parse_server", result[:route]
  end
end
