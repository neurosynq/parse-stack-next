# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# ============================================================================
# Tests for the agent_tenant_scope multi-tenant DSL.
#
# All tests use a fake Parse client so no Docker / Parse Server is required.
# The fake client intercepts find_objects / aggregate_pipeline / fetch_object
# and records what was sent so assertions can verify scope injection.
# ============================================================================
class AgentTenantScopeTest < Minitest::Test
  # ---- Fixtures --------------------------------------------------------------

  # Scoped class: every agent read is filtered to org_id == agent.tenant_id.
  class TenantOrder < Parse::Object
    parse_class "TenantOrder"
    property :org_id, :string
    property :amount, :integer

    agent_tenant_scope :org_id, from: ->(agent) { agent.tenant_id }
  end

  # Scoped class with an admin bypass.
  class TenantReport < Parse::Object
    parse_class "TenantReport"
    property :org_id, :string
    property :name, :string

    agent_tenant_scope :org_id, from: ->(agent) { agent.tenant_id }
    agent_tenant_scope_bypass { |agent| agent.permissions == :admin }
  end

  # Unscoped class: back-compat, no tenant enforcement.
  class TenantProduct < Parse::Object
    parse_class "TenantProduct"
    property :name, :string
  end

  # ---- Fake client helper ---------------------------------------------------

  # Build a minimal fake Parse client that stubs find_objects and
  # aggregate_pipeline, recording every call for assertions.
  def build_fake_client(find_rows: [], agg_rows: [], fetch_row: nil, find_success: true)
    client       = Object.new
    @find_calls  = []
    @agg_calls   = []
    @fetch_calls = []

    find_calls  = @find_calls
    agg_calls   = @agg_calls
    fetch_calls = @fetch_calls

    client.define_singleton_method(:find_objects) do |class_name, query, **_opts|
      find_calls << { class_name: class_name, query: query }
      r = Object.new
      r.define_singleton_method(:success?) { find_success }
      r.define_singleton_method(:error)   { "injected failure" }
      r.define_singleton_method(:results) { find_rows }
      r.define_singleton_method(:count)   { find_rows.size }
      r
    end

    client.define_singleton_method(:aggregate_pipeline) do |class_name, pipeline, **_opts|
      agg_calls << { class_name: class_name, pipeline: pipeline }
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results)  { agg_rows }
      r
    end

    if fetch_row
      client.define_singleton_method(:fetch_object) do |class_name, object_id, query: {}, **_opts|
        fetch_calls << { class_name: class_name, object_id: object_id, query: query }
        r = Object.new
        r.define_singleton_method(:success?)         { true }
        r.define_singleton_method(:object_not_found?) { false }
        r.define_singleton_method(:result)           { fetch_row }
        r
      end
    end

    client
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
  end

  # Helper: build an agent with injected fake client and given tenant_id/permissions.
  def make_agent(tenant_id:, permissions: :readonly, fake_client: nil)
    agent = Parse::Agent.new(permissions: permissions, tenant_id: tenant_id)
    agent.define_singleton_method(:client) { fake_client } if fake_client
    agent
  end

  # ============================================================
  # Agent construction and tenant_id accessor
  # ============================================================

  def test_tenant_id_constructor_kwarg
    agent = Parse::Agent.new(tenant_id: "org_abc")
    assert_equal "org_abc", agent.tenant_id
  end

  def test_tenant_id_setter
    agent = Parse::Agent.new
    assert_nil agent.tenant_id
    agent.tenant_id = "org_xyz"
    assert_equal "org_xyz", agent.tenant_id
  end

  def test_tenant_id_defaults_to_nil
    agent = Parse::Agent.new
    assert_nil agent.tenant_id
  end

  # ============================================================
  # query_class — scope injection
  # ============================================================

  # Helper: return the tenant scope field as it appears on the wire.
  # ConstraintTranslator camelizes snake_case field names: org_id -> orgId.
  SCOPE_FIELD_WIRE = "orgId"
  SCOPE_FIELD_RUBY = "org_id"

  def test_query_class_injects_scope_into_where
    rows = [{ "objectId" => "aaa", SCOPE_FIELD_WIRE => "org1", "amount" => 50 }]
    fc   = build_fake_client(find_rows: rows)
    agent = make_agent(tenant_id: "org1", fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantOrder")
    assert result[:success], result.inspect

    sent = @find_calls.first
    refute_nil sent
    where_json = sent[:query][:where]
    refute_nil where_json, "Expected a :where to be injected"
    where_hash = JSON.parse(where_json)
    # ConstraintTranslator camelizes org_id -> orgId on the wire
    assert_equal "org1", where_hash[SCOPE_FIELD_WIRE],
                 "scope field should be injected into where (camelized as #{SCOPE_FIELD_WIRE.inspect})"
  end

  def test_query_class_merges_scope_with_existing_where
    rows = [{ "objectId" => "bbb", SCOPE_FIELD_WIRE => "org1", "amount" => 99 }]
    fc   = build_fake_client(find_rows: rows)
    agent = make_agent(tenant_id: "org1", fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantOrder",
                           where: { "amount" => { "$gt" => 10 } })
    assert result[:success], result.inspect

    where_hash = JSON.parse(@find_calls.first[:query][:where])
    assert_equal "org1", where_hash[SCOPE_FIELD_WIRE]
    assert_equal({ "$gt" => 10 }, where_hash["amount"])
  end

  def test_query_class_passes_through_matching_caller_scope_value
    # Caller supplies the same org_id value (snake_case key) — this is OK (case 2: pass-through).
    rows = [{ "objectId" => "ccc", SCOPE_FIELD_WIRE => "org1" }]
    fc   = build_fake_client(find_rows: rows)
    agent = make_agent(tenant_id: "org1", fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantOrder",
                           where: { SCOPE_FIELD_RUBY => "org1" })
    assert result[:success], result.inspect

    where_hash = JSON.parse(@find_calls.first[:query][:where])
    assert_equal "org1", where_hash[SCOPE_FIELD_WIRE]
  end

  def test_query_class_refuses_spoofed_scope_value
    # Caller tries to override org_id with a different tenant's value.
    fc    = build_fake_client(find_rows: [])
    agent = make_agent(tenant_id: "org1", fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantOrder",
                           where: { "org_id" => "org_evil" })
    refute result[:success]
    assert_equal :access_denied, result[:error_code],
                 "Spoofed scope field must yield :access_denied"
    assert_empty @find_calls, "No query should reach Parse when scope is spoofed"
  end

  def test_query_class_refuses_spoofed_scope_value_via_camelcase_key
    # LLM passes the field using the camelCase wire-format key (orgId instead of
    # org_id). Without the camelCase check this would be treated as case-1
    # (absent) and allow both keys into ConstraintTranslator simultaneously.
    fc    = build_fake_client(find_rows: [])
    agent = make_agent(tenant_id: "org1", fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantOrder",
                           where: { "orgId" => "org_evil" })
    refute result[:success]
    assert_equal :access_denied, result[:error_code],
                 "camelCase spoofed scope key must yield :access_denied"
    assert_empty @find_calls, "No query must reach Parse when scope is camelCase-spoofed"
  end

  def test_query_class_passes_through_matching_caller_scope_value_camelcase_key
    # Caller supplies the correct org_id value using the camelCase wire-format key.
    # This is valid (case-2 pass-through) — just an unusual key format.
    rows = [{ "objectId" => "ccc2", SCOPE_FIELD_WIRE => "org1" }]
    fc   = build_fake_client(find_rows: rows)
    agent = make_agent(tenant_id: "org1", fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantOrder",
                           where: { "orgId" => "org1" })
    assert result[:success], result.inspect

    where_hash = JSON.parse(@find_calls.first[:query][:where])
    assert_equal "org1", where_hash[SCOPE_FIELD_WIRE]
  end

  def test_query_class_refuses_nil_scope_operator_on_scoped_field
    # LLM passes $ne operator — also a case-3 refusal.
    fc    = build_fake_client(find_rows: [])
    agent = make_agent(tenant_id: "org1", fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantOrder",
                           where: { "org_id" => { "$ne" => "org1" } })
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  def test_query_class_refuses_unbound_agent_on_scoped_class
    # Agent has no tenant_id — should be refused.
    fc    = build_fake_client(find_rows: [])
    agent = make_agent(tenant_id: nil, fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantOrder")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_empty @find_calls
  end

  # ============================================================
  # count_objects — scope injection
  # ============================================================

  def test_count_objects_injects_scope
    fc    = build_fake_client(find_rows: [])
    agent = make_agent(tenant_id: "org2", fake_client: fc)

    result = agent.execute(:count_objects, class_name: "TenantOrder")
    assert result[:success], result.inspect

    sent       = @find_calls.first
    where_json = sent[:query][:where]
    refute_nil where_json
    where_hash = JSON.parse(where_json)
    assert_equal "org2", where_hash[SCOPE_FIELD_WIRE]
  end

  def test_count_objects_refuses_unbound_agent
    fc    = build_fake_client(find_rows: [])
    agent = make_agent(tenant_id: nil, fake_client: fc)

    result = agent.execute(:count_objects, class_name: "TenantOrder")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  # ============================================================
  # get_object — post-fetch scope verification
  # ============================================================

  def test_get_object_succeeds_for_in_tenant_record
    record = { "objectId" => "id1", "org_id" => "org1", "amount" => 42 }
    fc = build_fake_client(fetch_row: record)
    agent = make_agent(tenant_id: "org1", fake_client: fc)

    result = agent.execute(:get_object, class_name: "TenantOrder", object_id: "id1")
    assert result[:success], result.inspect
  end

  def test_get_object_refuses_cross_tenant_record
    # Record belongs to org2; agent is bound to org1.
    record = { "objectId" => "id2", "org_id" => "org2", "amount" => 99 }
    fc = build_fake_client(fetch_row: record)
    agent = make_agent(tenant_id: "org1", fake_client: fc)

    result = agent.execute(:get_object, class_name: "TenantOrder", object_id: "id2")
    refute result[:success]
    assert_equal :access_denied, result[:error_code],
                 "Cross-tenant fetch must yield :access_denied, not :not_found"
  end

  def test_get_object_refuses_record_with_missing_scope_field
    # Record has no org_id at all — treated as mismatch.
    record = { "objectId" => "id3", "amount" => 5 }
    fc = build_fake_client(fetch_row: record)
    agent = make_agent(tenant_id: "org1", fake_client: fc)

    result = agent.execute(:get_object, class_name: "TenantOrder", object_id: "id3")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  def test_get_object_refuses_unbound_agent
    fc = build_fake_client(fetch_row: { "objectId" => "id4", "org_id" => "org1" })
    agent = make_agent(tenant_id: nil, fake_client: fc)

    result = agent.execute(:get_object, class_name: "TenantOrder", object_id: "id4")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  # ============================================================
  # get_objects — post-fetch scope verification
  # ============================================================

  def test_get_objects_succeeds_all_in_tenant
    rows = [
      { "objectId" => "a1", "org_id" => "org1" },
      { "objectId" => "a2", "org_id" => "org1" },
    ]
    fc    = build_fake_client(find_rows: rows)
    agent = make_agent(tenant_id: "org1", fake_client: fc)

    result = agent.execute(:get_objects, class_name: "TenantOrder", ids: ["a1", "a2"])
    assert result[:success], result.inspect
  end

  def test_get_objects_refuses_when_any_record_is_cross_tenant
    # One record is in org1, one is in org2 — entire call must be refused.
    rows = [
      { "objectId" => "b1", "org_id" => "org1" },
      { "objectId" => "b2", "org_id" => "org2" },
    ]
    fc    = build_fake_client(find_rows: rows)
    agent = make_agent(tenant_id: "org1", fake_client: fc)

    result = agent.execute(:get_objects, class_name: "TenantOrder", ids: ["b1", "b2"])
    refute result[:success]
    assert_equal :access_denied, result[:error_code],
                 "Must refuse whole call when any record is out of scope"
  end

  def test_get_objects_refuses_unbound_agent
    fc    = build_fake_client(find_rows: [])
    agent = make_agent(tenant_id: nil, fake_client: fc)

    result = agent.execute(:get_objects, class_name: "TenantOrder", ids: ["c1"])
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  # ============================================================
  # aggregate — $match prepend
  # ============================================================

  def test_aggregate_prepends_match_stage_at_index_0
    rows = [{ "total" => 100 }]
    fc   = build_fake_client(agg_rows: rows)
    agent = make_agent(tenant_id: "org3", fake_client: fc)

    pipeline = [{ "$group" => { "_id" => nil, "total" => { "$sum" => "$amount" } } },
                { "$limit" => 10 }]

    result = agent.execute(:aggregate, class_name: "TenantOrder", pipeline: pipeline)
    assert result[:success], result.inspect

    sent_pipeline = @agg_calls.first[:pipeline]
    first_stage   = sent_pipeline.first
    assert first_stage.key?("$match"),
           "First stage must be a $match (got #{first_stage.keys.first.inspect})"
    # Pipeline $match uses the camelCase wire key (orgId for org_id)
    assert_equal "org3", first_stage["$match"][SCOPE_FIELD_WIRE]
  end

  def test_aggregate_refuses_unbound_agent
    fc    = build_fake_client(agg_rows: [])
    agent = make_agent(tenant_id: nil, fake_client: fc)

    result = agent.execute(:aggregate, class_name: "TenantOrder",
                           pipeline: [{ "$limit" => 5 }])
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  # ============================================================
  # get_sample_objects — scope injection
  # ============================================================

  def test_get_sample_objects_injects_scope
    rows = [{ "objectId" => "s1", "org_id" => "org4" }]
    fc   = build_fake_client(find_rows: rows)
    agent = make_agent(tenant_id: "org4", fake_client: fc)

    result = agent.execute(:get_sample_objects, class_name: "TenantOrder", limit: 5)
    assert result[:success], result.inspect

    sent       = @find_calls.first
    where_json = sent[:query][:where]
    refute_nil where_json, "Expected :where to be injected for samples"
    where_hash = JSON.parse(where_json)
    assert_equal "org4", where_hash[SCOPE_FIELD_WIRE]
  end

  def test_get_sample_objects_refuses_unbound_agent
    fc    = build_fake_client(find_rows: [])
    agent = make_agent(tenant_id: nil, fake_client: fc)

    result = agent.execute(:get_sample_objects, class_name: "TenantOrder")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  # ============================================================
  # export_data (query mode) — scope injection
  # ============================================================

  def test_export_data_query_mode_injects_scope
    rows = [{ "objectId" => "e1", "org_id" => "org5", "amount" => 10 }]
    fc   = build_fake_client(find_rows: rows)
    agent = make_agent(tenant_id: "org5", fake_client: fc)

    result = agent.execute(:export_data, class_name: "TenantOrder", format: "csv")
    assert result[:success], result.inspect

    sent       = @find_calls.first
    where_json = sent[:query][:where]
    refute_nil where_json
    where_hash = JSON.parse(where_json)
    assert_equal "org5", where_hash[SCOPE_FIELD_WIRE]
  end

  # ============================================================
  # export_data (aggregate mode) — $match prepend
  # ============================================================

  def test_export_data_aggregate_mode_prepends_match
    rows = [{ "total" => 200 }]
    fc   = build_fake_client(agg_rows: rows)
    agent = make_agent(tenant_id: "org6", fake_client: fc)

    pipeline = [{ "$group" => { "_id" => nil, "total" => { "$sum" => "$amount" } } },
                { "$limit" => 10 }]

    result = agent.execute(:export_data, class_name: "TenantOrder", pipeline: pipeline, format: "csv")
    assert result[:success], result.inspect

    sent_pipeline = @agg_calls.first[:pipeline]
    first_stage   = sent_pipeline.first
    assert first_stage.key?("$match"),
           "First stage must be $match for scoped aggregate export"
    assert_equal "org6", first_stage["$match"][SCOPE_FIELD_WIRE]
  end

  # ============================================================
  # Bypass — admin agent skips enforcement
  # ============================================================

  def test_bypass_admin_agent_skips_scope_on_scoped_report_class
    rows = [{ "objectId" => "r1", "org_id" => "any_tenant", "name" => "Q4 Report" }]
    fc   = build_fake_client(find_rows: rows)
    # TenantReport has bypass: agent.permissions == :admin
    agent = make_agent(tenant_id: nil, permissions: :admin, fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantReport")
    assert result[:success], "Admin bypass should allow unscoped access: #{result.inspect}"

    sent = @find_calls.first
    # No where: clause should be injected at all (bypass = full access)
    assert_nil sent[:query][:where],
               "Admin bypass must not inject any scope filter"
  end

  def test_non_admin_agent_is_still_scoped_on_bypass_class
    rows = [{ "objectId" => "r2", "org_id" => "org7", "name" => "Monthly" }]
    fc   = build_fake_client(find_rows: rows)
    agent = make_agent(tenant_id: "org7", permissions: :readonly, fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantReport")
    assert result[:success], result.inspect

    where_hash = JSON.parse(@find_calls.first[:query][:where])
    assert_equal "org7", where_hash[SCOPE_FIELD_WIRE],
                 "Non-admin agent must still have scope injected on bypass class"
  end

  def test_nil_tenant_non_admin_refused_on_bypass_class
    fc    = build_fake_client(find_rows: [])
    agent = make_agent(tenant_id: nil, permissions: :readonly, fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantReport")
    refute result[:success]
    assert_equal :access_denied, result[:error_code],
                 "Non-admin agent with nil tenant_id must be refused even on bypass class"
  end

  # ============================================================
  # Unscoped class — back-compat, no enforcement
  # ============================================================

  def test_unscoped_class_passes_through_without_scope
    rows = [{ "objectId" => "p1", "name" => "Widget" }]
    fc   = build_fake_client(find_rows: rows)
    # Even nil tenant_id is fine for an unscoped class.
    agent = make_agent(tenant_id: nil, fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantProduct")
    assert result[:success], "Unscoped class must be unaffected: #{result.inspect}"

    sent = @find_calls.first
    assert_nil sent[:query][:where],
               "No scope filter must be injected for unscoped class"
  end

  def test_unscoped_class_with_tenant_bound_agent_passes_through
    rows = [{ "objectId" => "p2", "name" => "Gadget" }]
    fc   = build_fake_client(find_rows: rows)
    agent = make_agent(tenant_id: "org99", fake_client: fc)

    result = agent.execute(:query_class, class_name: "TenantProduct")
    assert result[:success], result.inspect

    # No scope filter on unscoped class
    assert_nil @find_calls.first[:query][:where]
  end

  # ============================================================
  # MetadataRegistry helpers (unit)
  # ============================================================

  def test_registry_resolve_raises_access_denied_for_nil_value
    # Simulate a class with a scope rule where from: returns nil.
    Parse::Agent::MetadataRegistry.register_tenant_scope(
      "TenantScopeRegistryNilTest",
      :org_id,
      from: ->(_agent) { nil },
    )
    agent = Parse::Agent.new(tenant_id: nil)
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::MetadataRegistry.resolve_tenant_scope("TenantScopeRegistryNilTest", agent)
    end
  end

  def test_registry_resolve_returns_nil_for_no_rule
    agent = Parse::Agent.new(tenant_id: "org1")
    result = Parse::Agent::MetadataRegistry.resolve_tenant_scope("ClassWithNoRule_XYZ", agent)
    assert_nil result
  end

  def test_registry_bypass_fail_closed_on_exception
    Parse::Agent::MetadataRegistry.register_tenant_scope(
      "TenantScopeBypassErrorTest",
      :org_id,
      from: ->(_agent) { "org1" },
    )
    Parse::Agent::MetadataRegistry.register_tenant_scope_bypass(
      "TenantScopeBypassErrorTest",
      ->(_agent) { raise "boom" },
    )
    agent = Parse::Agent.new(tenant_id: "org1")
    # Bypass raised — fail closed means scope IS enforced.
    result = Parse::Agent::MetadataRegistry.resolve_tenant_scope("TenantScopeBypassErrorTest", agent)
    refute_nil result
    assert_equal :org_id, result[:field]
    assert_equal "org1", result[:value]
  end

  # ============================================================
  # apply_tenant_scope_to_where (unit)
  # ============================================================

  def test_apply_scope_injects_when_field_absent
    scope  = { field: :org_id, value: "orgA" }
    result = Parse::Agent::Tools.apply_tenant_scope_to_where(nil, scope, "Klass")
    assert_equal "orgA", result["org_id"]
  end

  def test_apply_scope_passes_through_matching_string_key
    scope  = { field: :org_id, value: "orgA" }
    where  = { "org_id" => "orgA", "amount" => 5 }
    result = Parse::Agent::Tools.apply_tenant_scope_to_where(where, scope, "Klass")
    assert_equal "orgA",  result["org_id"]
    assert_equal 5,       result["amount"]
  end

  def test_apply_scope_passes_through_matching_symbol_key
    scope  = { field: :org_id, value: "orgA" }
    where  = { org_id: "orgA" }
    result = Parse::Agent::Tools.apply_tenant_scope_to_where(where, scope, "Klass")
    # Symbol key passes through — correct value is present
    assert_equal "orgA", result[:org_id]
  end

  def test_apply_scope_raises_on_mismatch
    scope = { field: :org_id, value: "orgA" }
    where = { "org_id" => "evil_org" }
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.apply_tenant_scope_to_where(where, scope, "Klass")
    end
  end

  def test_apply_scope_returns_nil_when_no_scope_and_no_where
    result = Parse::Agent::Tools.apply_tenant_scope_to_where(nil, nil, "Klass")
    assert_nil result
  end

  def test_apply_scope_raises_on_camelcase_mismatch
    # Caller passes the camelCase wire-format key with a different value — must refuse.
    scope = { field: :org_id, value: "orgA" }
    where = { "orgId" => "evil_org" }
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.apply_tenant_scope_to_where(where, scope, "Klass")
    end
  end

  def test_apply_scope_passes_through_matching_camelcase_string_key
    # Caller passes the camelCase wire-format key with the correct value — case 2.
    scope  = { field: :org_id, value: "orgA" }
    where  = { "orgId" => "orgA", "amount" => 5 }
    result = Parse::Agent::Tools.apply_tenant_scope_to_where(where, scope, "Klass")
    assert_equal "orgA", result["orgId"]
    assert_equal 5,      result["amount"]
  end

  def test_apply_scope_passes_through_matching_camelcase_symbol_key
    # Caller uses camelCase symbol key — case 2.
    scope  = { field: :org_id, value: "orgA" }
    where  = { orgId: "orgA" }
    result = Parse::Agent::Tools.apply_tenant_scope_to_where(where, scope, "Klass")
    assert_equal "orgA", result[:orgId]
  end

  # ============================================================
  # apply_tenant_scope_to_pipeline (unit)
  # ============================================================

  def test_apply_scope_to_pipeline_prepends_match
    scope    = { field: :org_id, value: "orgB" }
    pipeline = [{ "$group" => { "_id" => "$status" } }, { "$limit" => 5 }]
    result   = Parse::Agent::Tools.apply_tenant_scope_to_pipeline(pipeline, scope)

    assert_equal 3, result.size
    assert result.first.key?("$match")
    # Pipeline $match uses camelCase wire key: org_id -> orgId
    assert_equal "orgB", result.first["$match"]["orgId"]
    # Original stages preserved in order
    assert result[1].key?("$group")
    assert result[2].key?("$limit")
  end

  def test_apply_scope_to_pipeline_noop_when_no_scope
    pipeline = [{ "$limit" => 5 }]
    result   = Parse::Agent::Tools.apply_tenant_scope_to_pipeline(pipeline, nil)
    assert_equal pipeline, result
  end

  # ============================================================
  # assert_record_in_tenant_scope! (unit)
  # ============================================================

  def test_assert_record_passes_for_matching_field
    scope  = { field: :org_id, value: "orgC" }
    record = { "objectId" => "x1", "org_id" => "orgC" }
    assert_silent { Parse::Agent::Tools.assert_record_in_tenant_scope!(record, scope, "Klass") }
  end

  def test_assert_record_raises_for_mismatched_field
    scope  = { field: :org_id, value: "orgC" }
    record = { "objectId" => "x2", "org_id" => "orgD" }
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.assert_record_in_tenant_scope!(record, scope, "Klass")
    end
  end

  def test_assert_record_raises_for_missing_field
    scope  = { field: :org_id, value: "orgC" }
    record = { "objectId" => "x3" }
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.assert_record_in_tenant_scope!(record, scope, "Klass")
    end
  end

  def test_assert_record_noop_when_no_scope
    record = { "objectId" => "x4" }
    assert_silent { Parse::Agent::Tools.assert_record_in_tenant_scope!(record, nil, "Klass") }
  end

  def test_assert_record_passes_for_camelcase_wire_field
    # Parse Server returns camelCase field names on the wire (orgId, not org_id).
    # assert_record_in_tenant_scope! must accept this real-world format.
    scope  = { field: :org_id, value: "orgC" }
    record = { "objectId" => "x5", "orgId" => "orgC" }
    assert_silent { Parse::Agent::Tools.assert_record_in_tenant_scope!(record, scope, "Klass") }
  end

  def test_assert_record_raises_for_camelcase_wire_field_mismatch
    scope  = { field: :org_id, value: "orgC" }
    record = { "objectId" => "x6", "orgId" => "orgD" }
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.assert_record_in_tenant_scope!(record, scope, "Klass")
    end
  end

  # ============================================================
  # DSL validation guards
  # ============================================================

  def test_agent_tenant_scope_requires_callable_from
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        parse_class "TenantDSLGuardTest"
        agent_tenant_scope :org_id, from: "not_a_proc"
      end
    end
  end

  def test_agent_tenant_scope_bypass_requires_block
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        parse_class "TenantDSLBypassGuardTest"
        agent_tenant_scope_bypass
      end
    end
  end
end
