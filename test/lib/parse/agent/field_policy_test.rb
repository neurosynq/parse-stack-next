# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"
require "parse/atlas_search"

# Per-agent field narrowing (Parse::Agent.new(fields:)). The class's
# agent_fields is the ceiling; an agent's policy narrows it for that agent
# only, can never widen it, and a sub-agent intersects its parent. The
# effective set must reach every enforcement point.
class AgentFieldPolicyTest < Minitest::Test
  class FPDoc < Parse::Object
    parse_class "FieldPolicyDoc"
    property :title, :string
    property :status, :string
    property :body, :string
    property :internal_note, :string
    agent_fields :title, :status, :body
  end

  class FPOpen < Parse::Object
    parse_class "FieldPolicyOpen"
    property :name, :string
    property :email, :string
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse", application_id: "test",
                  api_key: "test", master_key: "test-master")
    end
  end

  def agent(**opts)
    Parse::Agent.new(permissions: :readonly, **opts)
  end

  def effective(agent, class_name)
    Parse::Agent::FieldPolicy.with(agent) { Parse::Agent::MetadataRegistry.field_allowlist(class_name) }
  end

  SYSTEM = %w[objectId createdAt updatedAt].freeze

  # ---- resolution ------------------------------------------------------

  def test_narrowing_intersects_the_class_ceiling
    a = agent(fields: { FPDoc => %i[title status] })
    assert_equal (%w[title status] + SYSTEM).sort, effective(a, "FieldPolicyDoc").sort
  end

  def test_outside_a_tool_call_the_ceiling_applies
    agent(fields: { FPDoc => %i[title] })
    assert_equal (%w[title status body] + SYSTEM).sort,
                 Parse::Agent::MetadataRegistry.field_allowlist("FieldPolicyDoc").sort
  end

  def test_narrowing_cannot_widen_past_the_ceiling
    a = agent(fields: { FPDoc => %i[title internal_note] })
    eff = effective(a, "FieldPolicyDoc")
    assert_includes eff, "title"
    refute_includes eff, "internalNote", "a policy must not expose a field outside agent_fields"
  end

  def test_narrowing_applies_to_a_class_without_agent_fields
    a = agent(fields: { "FieldPolicyOpen" => [:name] })
    assert_equal (%w[name] + SYSTEM).sort, effective(a, "FieldPolicyOpen").sort
    assert_nil Parse::Agent::MetadataRegistry.field_allowlist("FieldPolicyOpen")
  end

  def test_string_keys_resolve_to_the_parse_class_name
    a = agent(fields: { "User" => [:username] })
    eff = effective(a, "_User")
    refute_nil eff
    assert_includes eff, "username"
    refute_includes eff, "email"
  end

  def test_default_key_narrows_unlisted_classes
    a = agent(fields: { default: [:title], "FieldPolicyOpen" => %i[name email] })
    assert_equal (%w[title] + SYSTEM).sort, effective(a, "FieldPolicyDoc").sort
    assert_equal (%w[name email] + SYSTEM).sort, effective(a, "FieldPolicyOpen").sort
  end

  def test_agent_without_policy_sees_the_ceiling
    assert_equal (%w[title status body] + SYSTEM).sort, effective(agent, "FieldPolicyDoc").sort
  end

  def test_invalid_policy_shapes_raise
    assert_raises(ArgumentError) { agent(fields: [:title]) }
    assert_raises(ArgumentError) { agent(fields: { FPDoc => "title" }) }
    assert_raises(ArgumentError) { agent(fields: { FPDoc => [1] }) }
  end

  class FPAliased < Parse::Object
    parse_class "FieldPolicyAliased"
    property :public_text, :string, field: :PublicText
    property :other, :string
  end

  def test_policy_accepts_ruby_and_exact_server_alias_names
    by_ruby = agent(fields: { FPAliased => [:public_text] })
    by_wire = agent(fields: { "FieldPolicyAliased" => ["PublicText"] })
    assert_includes effective(by_ruby, "FieldPolicyAliased"), "PublicText"
    assert_includes effective(by_wire, "FieldPolicyAliased"), "PublicText"
  end

  # ---- sub-agents ------------------------------------------------------

  def test_sub_agent_intersects_its_parent
    parent = agent(fields: { FPDoc => %i[title status] })
    child = Parse::Agent.new(parent: parent, fields: { FPDoc => %i[status body] })
    assert_equal (%w[status] + SYSTEM).sort, effective(child, "FieldPolicyDoc").sort
  end

  def test_sub_agent_without_policy_inherits_the_parent
    parent = agent(fields: { FPDoc => %i[title] })
    child = Parse::Agent.new(parent: parent)
    assert_equal (%w[title] + SYSTEM).sort, effective(child, "FieldPolicyDoc").sort
  end

  # ---- scope isolation -------------------------------------------------

  def test_concurrent_agents_see_their_own_policy
    narrow = agent(fields: { FPDoc => %i[title] })
    broad = agent
    seen = {}
    q = Queue.new
    t1 = Thread.new do
      Parse::Agent::FieldPolicy.with(narrow) do
        q.pop # wait until the other thread is inside its own scope
        seen[:narrow] = Parse::Agent::MetadataRegistry.field_allowlist("FieldPolicyDoc").sort
      end
    end
    t2 = Thread.new do
      Parse::Agent::FieldPolicy.with(broad) do
        q << :go
        seen[:broad] = Parse::Agent::MetadataRegistry.field_allowlist("FieldPolicyDoc").sort
      end
    end
    [t1, t2].each(&:join)
    assert_equal (%w[title] + SYSTEM).sort, seen[:narrow]
    assert_equal (%w[title status body] + SYSTEM).sort, seen[:broad]
    assert_nil Parse::Agent::FieldPolicy.current_agent, "scope must not leak past the block"
  end

  def test_nested_unrelated_agent_cannot_escape_the_outer_policy
    outer = agent(fields: { FPDoc => %i[title status] })
    inner = agent(fields: { FPDoc => %i[status body] })   # no parent:
    eff = Parse::Agent::FieldPolicy.with(outer) do
      Parse::Agent::FieldPolicy.with(inner) { Parse::Agent::MetadataRegistry.field_allowlist("FieldPolicyDoc") }
    end
    assert_equal (%w[status] + SYSTEM).sort, eff.sort
    unrestricted = Parse::Agent::FieldPolicy.with(outer) do
      Parse::Agent::FieldPolicy.with(agent) { Parse::Agent::MetadataRegistry.field_allowlist("FieldPolicyDoc") }
    end
    assert_equal (%w[title status] + SYSTEM).sort, unrestricted.sort, "an unrestricted inner agent stays within the outer policy"
  end

  # ---- enforcement points ---------------------------------------------

  def test_projection_strips_fields_outside_the_narrowing
    a = agent(fields: { FPDoc => %i[title] })
    row = { "objectId" => "x", "title" => "t", "status" => "s", "body" => "b" }
    projected = Parse::Agent::FieldPolicy.with(a) do
      Parse::Agent::Tools.project_object_to_allowlist("FieldPolicyDoc", row)
    end
    assert_equal({ "objectId" => "x", "title" => "t" }, projected)
  end

  def test_where_on_a_narrowed_field_is_refused
    a = agent(fields: { FPDoc => %i[title] })
    err = assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::FieldPolicy.with(a) do
        Parse::Agent::Tools.assert_where_fields_in_allowlist!("FieldPolicyDoc", { "status" => "open" })
      end
    end
    assert_equal :field_denied, err.kind
    # The same filter is fine for an agent with no narrowing.
    Parse::Agent::FieldPolicy.with(agent) do
      Parse::Agent::Tools.assert_where_fields_in_allowlist!("FieldPolicyDoc", { "status" => "open" })
    end
  end

  def test_query_class_refuses_where_and_order_on_hidden_fields_before_any_request
    a = agent(fields: { FPDoc => %i[title] })
    Parse::Agent::Tools.stub(:assert_class_accessible!, nil) do
      r = a.execute(:query_class, class_name: "FieldPolicyDoc", where: { "body" => "secret" })
      refute r[:success]
      assert_equal :access_denied, r[:error_code]
      assert_equal :field_denied, r.dig(:details, :kind)

      r = a.execute(:query_class, class_name: "FieldPolicyDoc", order: "-status")
      refute r[:success], r.inspect
      assert_equal :field_denied, r.dig(:details, :kind), r.reject { |k, _| k == :data }.inspect
    end
  end

  def test_count_objects_refuses_where_on_hidden_fields
    a = agent(fields: { FPDoc => %i[title] })
    Parse::Agent::Tools.stub(:assert_class_accessible!, nil) do
      r = a.execute(:count_objects, class_name: "FieldPolicyDoc", where: { "status" => "x" })
      assert_equal :field_denied, r.dig(:details, :kind)
    end
  end

  def test_class_ceiling_where_guard_applies_without_a_policy
    # The where/order guard on query_class is new in 5.8 and applies to the
    # class ceiling too: internal_note is outside agent_fields entirely.
    Parse::Agent::Tools.stub(:assert_class_accessible!, nil) do
      r = agent.execute(:query_class, class_name: "FieldPolicyDoc", where: { "internalNote" => "x" })
      assert_equal :field_denied, r.dig(:details, :kind)
    end
  end

  def test_field_refusal_carries_structured_details
    a = agent(fields: { FPDoc => %i[title] })
    err = assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::FieldPolicy.with(a) { Parse::Agent::Tools.assert_fields_in_allowlist!("FieldPolicyDoc", ["status"]) }
    end
    assert_equal :field_denied, err.kind
    assert_equal "status", err.denied_field
    refute_match(/\{message:/, err.message, "the message must not be a stringified Hash")
  end

  def test_subquery_predicates_are_checked_against_their_target_class
    a = agent(fields: { FPDoc => %i[title] })
    inquery = { "parent" => { "$inQuery" => { "className" => "FieldPolicyDoc", "where" => { "body" => "x" } } } }
    select = { "ref" => { "$select" => { "query" => { "className" => "FieldPolicyDoc", "where" => {} }, "key" => "status" } } }
    nested = { "$or" => [inquery] }
    [inquery, select, nested].each do |where|
      err = assert_raises(Parse::Agent::AccessDenied, where.inspect) do
        # The outer class has no allowlist; the subquery's class does.
        Parse::Agent::FieldPolicy.with(a) { Parse::Agent::Tools.assert_where_fields_in_allowlist!("FieldPolicyOpen", where) }
      end
      assert_equal :field_denied, err.kind
    end
    # A readable subquery field passes.
    ok = { "parent" => { "$inQuery" => { "className" => "FieldPolicyDoc", "where" => { "title" => "x" } } } }
    Parse::Agent::FieldPolicy.with(a) { Parse::Agent::Tools.assert_where_fields_in_allowlist!("FieldPolicyOpen", ok) }
  end

  class FPSnake < Parse::Object
    parse_class "FieldPolicySnake"
    property :play_count, :integer
    property :secret_score, :integer
    agent_fields :play_count
  end

  def test_snake_case_where_and_order_keys_resolve_like_the_translator
    Parse::Agent::FieldPolicy.with(agent) do
      Parse::Agent::Tools.assert_where_fields_in_allowlist!("FieldPolicySnake",
        { "play_count" => { "$gt" => 1 }, "created_at" => { "$exists" => true },
          "$or" => [{ "playCount" => 2 }] })
      assert_raises(Parse::Agent::AccessDenied) do
        Parse::Agent::Tools.assert_where_fields_in_allowlist!("FieldPolicySnake", { "secret_score" => 1 })
      end
    end
    Parse::Agent::Tools.stub(:assert_class_accessible!, nil) do
      r = agent.execute(:query_class, class_name: "FieldPolicySnake", order: "-play_count", where: { "secret_score" => 1 })
      assert_equal :field_denied, r.dig(:details, :kind)
    end
  end

  def test_explain_query_refuses_hidden_where
    a = agent(fields: { FPDoc => %i[title] })
    Parse::Agent::Tools.stub(:assert_class_accessible!, nil) do
      r = a.execute(:explain_query, class_name: "FieldPolicyDoc", where: { "body" => "x" })
      assert_equal :field_denied, r.dig(:details, :kind)
    end
  end

  def test_atlas_text_search_filter_and_default_fields_respect_the_policy
    a = agent(fields: { FPDoc => %i[title] })
    Parse::Agent::Tools.stub(:assert_class_accessible!, nil) do
      r = a.execute(:atlas_text_search, class_name: "FieldPolicyDoc", query: "q", filter: { "status" => "x" })
      assert_equal :field_denied, r.dig(:details, :kind)

      captured = nil
      Parse::AtlasSearch.stub(:search, ->(_c, _q, **opts) { captured = opts; raise "stop" }) do
        a.execute(:atlas_text_search, class_name: "FieldPolicyDoc", query: "q")
      end
      assert_equal ["title"], captured[:fields], "no wildcard over hidden fields"
    end
  end

  def test_order_field_names_parses_rest_and_array_forms
    assert_equal %w[createdAt title], Parse::Agent::Tools.order_field_names("-createdAt, title")
    assert_equal %w[a b], Parse::Agent::Tools.order_field_names(["-a", "+b"])
    assert_equal [], Parse::Agent::Tools.order_field_names(nil)
  end

  def test_include_projection_is_narrowed
    a = agent(fields: { FPDoc => %i[title] })
    proj = Parse::Agent::FieldPolicy.with(a) do
      Parse::Agent::MetadataRegistry.join_projection_fields(FPDoc)
    end
    refute_nil proj
    assert_equal (%w[title] + SYSTEM).sort, proj[:project].sort
  end

  def test_describe_reports_the_effective_fields
    a = agent(fields: { FPDoc => %i[title] })
    assert_equal (%w[title] + SYSTEM).sort, a.describe_for("FieldPolicyDoc")[:agent_fields].sort
  end

  def test_enriched_schema_is_narrowed
    a = agent(fields: { FPDoc => %i[title] })
    server = { "className" => "FieldPolicyDoc",
               "fields" => { "objectId" => { "type" => "String" }, "title" => { "type" => "String" },
                             "status" => { "type" => "String" }, "body" => { "type" => "String" } } }
    schema = Parse::Agent::FieldPolicy.with(a) do
      Parse::Agent::MetadataRegistry.enriched_schema("FieldPolicyDoc", server)
    end
    assert_equal %w[objectId title], schema["fields"].keys.sort
  end
end
