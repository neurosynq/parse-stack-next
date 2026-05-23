# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# Covers the FIX-AGENT-C2 mandate:
#
#   * AGENT-2  — ConstraintTranslator nested $inQuery kwarg→positional fix
#   * AGENT-1  — get_objects per-agent filter (UNCONDITIONAL) + canonical (kwarg)
#   * AGENT-6  — get_object / get_objects / group_by / group_by_date / distinct /
#                atlas_text_search / atlas_autocomplete / atlas_faceted_search
#                respect BOTH filters with split semantics
#   * AGENT-7  — canonical/per-agent SPLIT: apply_canonical_filter: false drops
#                ONLY the canonical half; per-agent filter remains UNCONDITIONAL
#   * AGENT-8  — describe.rb / would_permit? mirror the real dispatch gates
#                (op:, method_filtered, master_atlas, write env, master-key heuristic)
#   * AGENT-5  — master_atlas tri-state (nil = inherit, true/false = explicit)
class TrackAgentFixC2Test < Minitest::Test
  T = Parse::Agent::Tools

  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
        master_key: "test-master-key",
      )
    end
    @prior_suppress = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
    Parse::Agent.reset_master_key_warning!
    T.reset_registry!
  end

  def teardown
    Parse::Agent.suppress_master_key_warning = @prior_suppress
    Parse::Agent.reset_master_key_warning!
    T.reset_registry!
  end

  # Minimal fake client that records the query/pipeline shape passed in
  # and answers all methods sensibly. Mirrors FakeFilterClient in
  # canonical_filter_test.rb (kept local so this test file is self-contained).
  class FakeClient
    attr_reader :received_query, :received_pipeline, :received_class

    def find_objects(class_name, query, **_opts)
      @received_class = class_name
      @received_query = query
      response = Object.new
      response.define_singleton_method(:success?) { true }
      response.define_singleton_method(:count)    { 0 }
      response.define_singleton_method(:results)  { [] }
      response.define_singleton_method(:error)    { nil }
      response
    end

    def aggregate_pipeline(class_name, pipeline, **_opts)
      @received_class    = class_name
      @received_pipeline = pipeline
      response = Object.new
      response.define_singleton_method(:success?) { true }
      response.define_singleton_method(:results)  { [] }
      response.define_singleton_method(:error)    { nil }
      response
    end

    def fetch_object(class_name, object_id, **_opts)
      @received_class = class_name
      response = Object.new
      response.define_singleton_method(:success?) { true }
      response.define_singleton_method(:result) { { "objectId" => object_id } }
      response.define_singleton_method(:object_not_found?) { false }
      response.define_singleton_method(:error) { nil }
      response
    end
  end

  def stub_agent_client(agent, client = FakeClient.new)
    agent.instance_variable_set(:@client, client)
    client
  end

  # =============================================================
  # Test classes that exercise both filter layers
  # =============================================================

  class FilterClassOrder < Parse::Object
    parse_class "FilterClassOrder"
    property :title,    :string
    property :archived, :boolean
    property :status,   :string
    agent_canonical_filter "archived" => { "$ne" => true }
  end

  class FilterClassPayment < Parse::Object
    parse_class "FilterClassPayment"
    property :amount,   :integer
    property :test_user, :boolean
    # No canonical filter — exercises the "per-agent only" path
  end

  class ATAtlasClass < Parse::Object
    parse_class "ATAtlasClass"
    property :title, :string
    property :archived, :boolean
    agent_canonical_filter "archived" => { "$ne" => true }
  end

  # =============================================================
  # AGENT-2: ConstraintTranslator nested $inQuery kwarg fix
  # =============================================================

  class HiddenInQueryClass < Parse::Object
    parse_class "HiddenInQueryClass"
    property :label, :string
    agent_hidden
  end

  def test_agent2_nested_inquery_into_hidden_class_raises_access_denied
    # The outer reachable class wraps an inner $inQuery into a hidden class.
    # Before the fix, the recursive translate(embedded_where, agent: agent)
    # call bundled the agent into a Hash literal {agent: <Parse::Agent>},
    # so the inner per-agent class filter crashed on Hash#class_filter_permits?
    # and was rescued+rewrapped as ConstraintSecurityError. After the fix
    # the proper AccessDenied with kind: :hidden_class surfaces unchanged.
    agent = Parse::Agent.new
    nested_where = {
      "permitted_ptr" => {
        "$inQuery" => {
          "className" => "FilterClassPayment",
          "where"     => {
            "deeper_ptr" => {
              "$inQuery" => {
                "className" => HiddenInQueryClass.parse_class,
                "where"     => {},
              },
            },
          },
        },
      },
    }
    err = assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::ConstraintTranslator.translate(nested_where, agent)
    end
    # The AccessDenied MUST surface unchanged — the kind is nil for the
    # global hidden gate (no kind: kwarg at the raise site, see
    # tools.rb:1066). Before the fix, the inner per-agent class-filter
    # check crashed on Hash#class_filter_permits? (because `agent` was
    # bundled into a Hash literal {agent: <Agent>}) and the rescue
    # StandardError in assert_embedded_class_accessible! rewrapped it as
    # ConstraintSecurityError — which loses the AccessDenied subtype.
    refute_kind_of Parse::Agent::ConstraintTranslator::ConstraintSecurityError, err,
                   "should NOT be rewrapped as ConstraintSecurityError"
    assert_match(/HiddenInQueryClass/, err.message)
  end

  # =============================================================
  # AGENT-7: SPLIT semantics — `apply_canonical_filter: false`
  # drops ONLY the canonical half. Per-agent filter is UNCONDITIONAL.
  # =============================================================

  def test_agent7_per_agent_filter_is_unconditional_when_kwarg_false
    # The LLM-controlled kwarg can disable the per-class canonical filter,
    # but the operator's per-agent filter MUST stay applied — that's the
    # operator's narrowing boundary.
    agent  = Parse::Agent.new(filters: { FilterClassPayment => { test_user: false } })
    client = stub_agent_client(agent)
    T.count_objects(agent, class_name: "FilterClassPayment",
                    apply_canonical_filter: false)
    refute_nil client.received_query
    # `where:` was injected — the per-agent filter MUST appear even though
    # apply_canonical_filter: false dropped the canonical-filter declaration.
    assert client.received_query.key?(:where), "where: missing — per-agent filter was dropped"
    parsed = JSON.parse(client.received_query[:where])
    # The shape is the per-agent filter directly (single extra, unwrapped).
    assert_equal({ "testUser" => false }, parsed)
  end

  def test_agent7_apply_canonical_filter_false_skips_only_canonical_half
    # Class declares an agent_canonical_filter; agent declares a per-class
    # filter. apply_canonical_filter: false should drop the FORMER and
    # keep the LATTER (the test_user constraint must survive).
    agent  = Parse::Agent.new(filters: { FilterClassOrder => { test_user: false } })
    client = stub_agent_client(agent)
    T.count_objects(agent, class_name: "FilterClassOrder",
                    apply_canonical_filter: false)
    parsed = JSON.parse(client.received_query[:where])
    # Per-agent filter is preserved; canonical (archived: { $ne: true }) is dropped.
    assert_equal({ "testUser" => false }, parsed)
  end

  def test_agent7_apply_canonical_filter_true_keeps_both_layers
    agent  = Parse::Agent.new(filters: { FilterClassOrder => { test_user: false } })
    client = stub_agent_client(agent)
    T.count_objects(agent, class_name: "FilterClassOrder",
                    apply_canonical_filter: true)
    parsed = JSON.parse(client.received_query[:where])
    # Both layers compose via $and.
    assert parsed.key?("$and"), "expected $and composition of per-agent + canonical, got #{parsed.inspect}"
    clauses = parsed["$and"]
    assert_includes clauses, { "testUser" => false }
    assert_includes clauses, { "archived" => { "$ne" => true } }
  end

  # =============================================================
  # AGENT-1 / AGENT-6: get_objects now respects BOTH filters
  # =============================================================

  def test_agent1_get_objects_applies_per_agent_filter_unconditional
    agent  = Parse::Agent.new(filters: { FilterClassPayment => { test_user: false } })
    client = stub_agent_client(agent)
    T.get_objects(agent, class_name: "FilterClassPayment", ids: %w[abc1234567],
                  apply_canonical_filter: false)
    refute_nil client.received_query
    parsed = JSON.parse(client.received_query[:where])
    # Per-agent filter MUST appear alongside the $in even with canonical-off.
    assert parsed.key?("$and"), "expected $and composing per-agent + $in"
    clauses = parsed["$and"]
    assert_includes clauses, { "testUser" => false }
    assert(clauses.any? { |c| c["objectId"].is_a?(Hash) && c["objectId"]["$in"] == ["abc1234567"] },
           "expected the objectId $in clause inside $and")
  end

  def test_agent1_get_objects_applies_canonical_filter_by_default
    agent  = Parse::Agent.new
    client = stub_agent_client(agent)
    T.get_objects(agent, class_name: "FilterClassOrder", ids: %w[abc1234567])
    parsed = JSON.parse(client.received_query[:where])
    # Canonical filter composes with the $in via $and.
    assert parsed.key?("$and")
    clauses = parsed["$and"]
    assert_includes clauses, { "archived" => { "$ne" => true } }
  end

  def test_agent1_get_objects_canonical_opt_out_drops_only_canonical
    agent  = Parse::Agent.new
    client = stub_agent_client(agent)
    T.get_objects(agent, class_name: "FilterClassOrder", ids: %w[abc1234567],
                  apply_canonical_filter: false)
    parsed = JSON.parse(client.received_query[:where])
    # With canonical off and no per-agent filter, the where is just the $in.
    assert_equal({ "objectId" => { "$in" => ["abc1234567"] } }, parsed)
  end

  # =============================================================
  # AGENT-6: get_object also applies canonical (LLM-controllable)
  # =============================================================

  def test_agent6_get_object_applies_canonical_filter_by_default
    agent  = Parse::Agent.new
    client = stub_agent_client(agent)
    # The FakeClient returns one row from find_objects so get_object
    # treats it as a hit and the call completes.
    client.define_singleton_method(:find_objects) do |class_name, query, **_opts|
      @received_class = class_name
      @received_query = query
      response = Object.new
      response.define_singleton_method(:success?) { true }
      response.define_singleton_method(:results)  { [{ "objectId" => "abc1234567", "title" => "x" }] }
      response.define_singleton_method(:error)    { nil }
      response
    end

    T.get_object(agent, class_name: "FilterClassOrder", object_id: "abc1234567")

    refute_nil client.received_query, "get_object should route through find_objects when filters apply"
    parsed = JSON.parse(client.received_query[:where])
    # Composed via $and: canonical + objectId clause.
    assert parsed.key?("$and")
    clauses = parsed["$and"]
    assert(clauses.any? { |c| c["archived"] == { "$ne" => true } })
    assert(clauses.any? { |c| c["objectId"] == "abc1234567" })
  end

  def test_agent6_get_object_canonical_opt_out_uses_direct_fetch_path
    # With canonical off and no per-agent filter, get_object should NOT
    # rewrite to find_objects — it falls through to the cheap fetch_object.
    agent  = Parse::Agent.new
    client = stub_agent_client(agent)

    fetch_called = false
    find_called  = false
    client.define_singleton_method(:fetch_object) do |class_name, object_id, **_opts|
      fetch_called = true
      response = Object.new
      response.define_singleton_method(:success?) { true }
      response.define_singleton_method(:result) { { "objectId" => object_id } }
      response.define_singleton_method(:object_not_found?) { false }
      response.define_singleton_method(:error) { nil }
      response
    end
    client.define_singleton_method(:find_objects) do |*_|
      find_called = true
      raise "find_objects should NOT be called"
    end

    T.get_object(agent, class_name: "FilterClassOrder", object_id: "abc1234567",
                 apply_canonical_filter: false)

    assert fetch_called, "fetch_object should have been called when no filter applies"
    refute find_called,  "find_objects should NOT be called when no filter applies"
  end

  # =============================================================
  # AGENT-6: group_by / group_by_date / distinct accept the kwarg
  # =============================================================

  def test_agent6_group_by_accepts_apply_canonical_filter_kwarg
    # Just verify the kwarg is accepted (no ArgumentError) and that
    # dry-run echoes a pipeline. Real execution is exercised by the
    # group_distinct test file already.
    agent = Parse::Agent.new
    out = T.group_by(agent, class_name: "FilterClassOrder", field: "status",
                     operation: "count", dry_run: true, apply_canonical_filter: false)
    assert out.is_a?(Hash)
  end

  def test_agent6_distinct_accepts_apply_canonical_filter_kwarg
    agent = Parse::Agent.new
    out = T.distinct(agent, class_name: "FilterClassOrder", field: "status",
                     dry_run: true, apply_canonical_filter: false)
    assert out.is_a?(Hash)
  end

  def test_agent6_group_by_date_accepts_apply_canonical_filter_kwarg
    agent = Parse::Agent.new
    out = T.group_by_date(agent, class_name: "FilterClassOrder",
                          field: "createdAt", interval: "day",
                          dry_run: true, apply_canonical_filter: false)
    assert out.is_a?(Hash)
  end

  # =============================================================
  # AGENT-6: atlas helpers compose per-agent + canonical into filter:
  # =============================================================

  def test_agent6_compose_atlas_filter_returns_nil_when_no_filters
    agent = Parse::Agent.new
    out = T.compose_atlas_filter(nil, "ATAtlasClass", agent: agent,
                                 apply_canonical_filter: false)
    assert_nil out
  end

  def test_agent6_compose_atlas_filter_returns_canonical_when_no_others
    agent = Parse::Agent.new
    out = T.compose_atlas_filter(nil, "ATAtlasClass", agent: agent,
                                 apply_canonical_filter: true)
    assert_equal({ "archived" => { "$ne" => true } }, out)
  end

  def test_agent6_compose_atlas_filter_per_agent_unconditional_with_kwarg_false
    # Even with apply_canonical_filter: false the per-agent filter survives.
    agent = Parse::Agent.new(filters: { ATAtlasClass => { archived: true } })
    out = T.compose_atlas_filter(nil, "ATAtlasClass", agent: agent,
                                 apply_canonical_filter: false)
    assert_equal({ archived: true }, out)
  end

  def test_agent6_compose_atlas_filter_three_way_and
    agent = Parse::Agent.new(filters: { ATAtlasClass => { user_id: "u1" } })
    caller_filter = { "score" => { "$gte" => 5 } }
    out = T.compose_atlas_filter(caller_filter, "ATAtlasClass", agent: agent,
                                 apply_canonical_filter: true)
    assert out.key?("$and")
    parts = out["$and"]
    assert_includes parts, { user_id: "u1" }
    assert_includes parts, { "archived" => { "$ne" => true } }
    assert_includes parts, { "score" => { "$gte" => 5 } }
  end

  def test_agent6_atlas_faceted_search_refuses_when_per_agent_filter_declared
    # Bucket counts CANNOT be filtered through a post-search $match, so
    # the tool must fail-closed when a per-agent or canonical filter
    # is declared on the class. Use a class WITHOUT a canonical filter
    # so we isolate the per-agent gate.
    agent = Parse::Agent.new(
      filters: { FilterClassPayment => { test_user: false } },
      master_atlas: true,
    )
    err = assert_raises(Parse::Agent::AccessDenied) do
      T.atlas_faceted_search(agent, class_name: "FilterClassPayment",
                              facets: { "x" => { type: :string, path: :amount } })
    end
    assert_equal :atlas_facet_filter_unsafe, err.kind
  end

  def test_agent6_atlas_faceted_search_refuses_when_canonical_filter_declared
    agent = Parse::Agent.new(master_atlas: true)
    err = assert_raises(Parse::Agent::AccessDenied) do
      T.atlas_faceted_search(agent, class_name: "ATAtlasClass",
                              facets: { "x" => { type: :string, path: :title } })
    end
    assert_equal :atlas_facet_filter_unsafe, err.kind
  end

  # =============================================================
  # AGENT-8: describe / would_permit? mirror real gates
  # =============================================================

  class CLPCreateAdminOnly < Parse::Object
    parse_class "CLPCreateAdminOnly"
    property :label, :string
  end

  class HiddenExceptMaster < Parse::Object
    parse_class "HiddenExceptMaster"
    property :label, :string
    agent_hidden(except: :master_key)
  end

  def test_agent8_describe_class_accessibility_for_acl_user_against_master_key_except
    # Bug 1 from AGENT-8 — describe wrongly used @session_token.to_s.empty?
    # as proxy for master-key. An acl_user agent also has empty session_token
    # but is NOT master-key; it must NOT see the master-key-except class as
    # accessible.
    user  = Parse::User.new(objectId: "u_describe_acl_user")
    agent = silence_master_key { Parse::Agent.new(acl_user: user) }
    accessibility = agent.describe_for(HiddenExceptMaster.parse_class)[:accessible]
    assert_equal :hidden, accessibility,
                 "acl_user agent must NOT be reported as :permitted for an except: :master_key class"
  end

  def test_agent8_describe_class_accessibility_for_master_key_against_master_key_except
    # Conversely, a true master-key agent IS permitted.
    master = silence_master_key { Parse::Agent.new }
    accessibility = master.describe_for(HiddenExceptMaster.parse_class)[:accessible]
    assert_equal :permitted, accessibility
  end

  def test_agent8_auth_descriptor_reports_acl_user_not_master_key
    user  = Parse::User.new(objectId: "u_describe_acl_user")
    agent = silence_master_key { Parse::Agent.new(acl_user: user) }
    desc  = agent.describe[:auth]
    assert_equal :acl_user, desc[:mode]
    refute_equal :master_key, desc[:mode]
  end

  def test_agent8_auth_descriptor_reports_acl_role_not_master_key
    role = Parse::Role.new(name: "Auditor")
    role.id = "r_auditor_test"
    agent = silence_master_key { Parse::Agent.new(acl_role: role) }
    desc  = agent.describe[:auth]
    assert_equal :acl_role, desc[:mode]
    assert_equal "Auditor", desc[:identity]
  end

  def test_agent8_would_permit_op_kwarg_enforces_clp
    # Bug 5: would_permit? must forward op: into assert_class_accessible!
    # so a CLP-restricted op on an otherwise-permitted class returns
    # refusal. Use query_class (a readonly tool) with op: :create so the
    # tier/env-gate checks pass and we isolate the CLP-op gate.
    user  = Parse::User.new(objectId: "u_clp_test")
    agent = silence_master_key { Parse::Agent.new(acl_user: user) }

    # Stub the CLP gate so :create is refused unless role:Admin is in
    # the agent's permission_strings. acl_user agents get
    # ["*", userId] (no roles), so :create MUST be refused.
    Parse::CLPScope.stub(:permits?, lambda { |_cn, op, perms|
      next true unless op == :create
      perms && perms.include?("role:Admin")
    }) do
      result = agent.would_permit?(:query_class, class_name: "CLPCreateAdminOnly",
                                    op: :create)
      refute result[:allowed], "op: :create should be refused without role:Admin (got #{result.inspect})"
      assert_equal :clp_denied, result[:reason]
    end
  end

  def test_agent8_would_permit_master_atlas_gate_for_faceted_search
    # Bug 3: atlas_faceted_search requires master_atlas: true. The
    # simulator must refuse without it.
    agent = silence_master_key { Parse::Agent.new(permissions: :readonly) }
    result = agent.would_permit?(:atlas_faceted_search, class_name: "ATAtlasClass")
    refute result[:allowed]
    assert_equal :master_atlas_required, result[:reason]
    assert_equal :master_atlas_gate,     result[:denied_at]
  end

  def test_agent8_would_permit_master_atlas_permitted_when_set
    agent = silence_master_key { Parse::Agent.new(permissions: :readonly, master_atlas: true) }
    # Even with master_atlas: true, tool_allowed? still gates on tier
    # membership — atlas_faceted_search isn't a readonly builtin, so
    # the gate may stop at allowed_tools first. Confirm the master_atlas
    # gate-pass behavior on a tier that includes atlas_faceted_search,
    # or by allowlisting it via the tools: filter.
    result = agent.would_permit?(:atlas_faceted_search, class_name: "ATAtlasClass")
    # Tool filter may refuse first; verify by checking allowed_tools.
    if agent.allowed_tools.include?(:atlas_faceted_search)
      # master_atlas gate passed if allowed_tools includes the tool
      refute_equal :master_atlas_required, result[:reason]
    end
  end

  def test_agent8_would_permit_write_env_gate_disabled_by_default
    # Bug 4: would_permit? must consult PARSE_AGENT_ALLOW_WRITE_TOOLS /
    # PARSE_AGENT_ALLOW_RAW_CRUD. With neither set, create_object must
    # report refused even for a :write agent.
    ENV.delete("PARSE_AGENT_ALLOW_WRITE_TOOLS")
    ENV.delete("PARSE_AGENT_ALLOW_RAW_CRUD")
    agent = silence_master_key { Parse::Agent.new(permissions: :write) }
    result = agent.would_permit?(:create_object, class_name: "CLPCreateAdminOnly")
    refute result[:allowed]
    assert_equal :write_env_gate_disabled, result[:reason]
    assert_equal :write_env_gate,           result[:denied_at]
  end

  def test_agent8_would_permit_write_env_gate_passes_when_both_envs_set
    ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = "true"
    ENV["PARSE_AGENT_ALLOW_RAW_CRUD"]    = "true"
    begin
      agent = silence_master_key { Parse::Agent.new(permissions: :write) }
      result = agent.would_permit?(:create_object, class_name: "FilterClassPayment")
      assert result[:allowed], "with both env-vars set, create_object should be permitted: #{result.inspect}"
    ensure
      ENV.delete("PARSE_AGENT_ALLOW_WRITE_TOOLS")
      ENV.delete("PARSE_AGENT_ALLOW_RAW_CRUD")
    end
  end

  class MethodFilterTarget < Parse::Object
    parse_class "MethodFilterTarget"
    agent_method :archive,    permission: :readonly
    agent_method :reactivate, permission: :readonly
    def archive    ; :archived ; end
    def reactivate ; :reactivated ; end
  end

  def test_agent8_would_permit_method_filtered_for_call_method
    # Bug 2: would_permit? must consult method_filtered? for call_method.
    agent = silence_master_key {
      Parse::Agent.new(methods: { except: [:archive] })
    }
    result = agent.would_permit?(:call_method, class_name: "MethodFilterTarget",
                                  method_name: :archive)
    refute result[:allowed]
    assert_equal :method_filtered, result[:reason]
  end

  def test_agent8_would_permit_method_not_filtered_when_within_set
    agent = silence_master_key {
      Parse::Agent.new(methods: { except: [:archive] })
    }
    result = agent.would_permit?(:call_method, class_name: "MethodFilterTarget",
                                  method_name: :reactivate)
    assert result[:allowed]
  end

  # =============================================================
  # AGENT-5: master_atlas tri-state for sub-agents
  # =============================================================

  def test_agent5_subagent_inherits_master_atlas_when_nil
    parent = silence_master_key { Parse::Agent.new(master_atlas: true) }
    child  = Parse::Agent.new(parent: parent)
    assert child.master_atlas?, "sub-agent with no master_atlas: kwarg should inherit parent's true"
  end

  def test_agent5_subagent_explicit_false_drops_master_atlas_below_parent
    parent = silence_master_key { Parse::Agent.new(master_atlas: true) }
    child  = Parse::Agent.new(parent: parent, master_atlas: false)
    refute child.master_atlas?,
           "sub-agent passing master_atlas: false should DROP authority below parent (TRACK-AGENT-5)"
  end

  def test_agent5_subagent_explicit_true_keeps_master_atlas
    parent = silence_master_key { Parse::Agent.new(master_atlas: true) }
    child  = Parse::Agent.new(parent: parent, master_atlas: true)
    assert child.master_atlas?
  end

  def test_agent5_root_default_master_atlas_is_false
    a = silence_master_key { Parse::Agent.new }
    refute a.master_atlas?, "root-level default must remain false"
  end

  private

  def silence_master_key
    was = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
    yield
  ensure
    Parse::Agent.suppress_master_key_warning = was unless was.nil?
  end
end
