# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# ============================================================================
# Tests for per-agent tools: / methods: filters, parent: inheritance, and
# the recursion-depth cap. The filter is an overlay on the permission-tier
# output of allowed_tools — it narrows, never elevates. The denial path
# distinguishes :tool_filtered (filter excluded it) from :permission_denied
# (tier never allowed it) so consumers see meaningful diagnostics.
# ============================================================================
class AgentToolFilterTest < Minitest::Test
  class FilterArticle < Parse::Object
    parse_class "FilterArticle"
    property :title, :string

    agent_method :archive, "Archive this record", permission: :readonly
    def self.archive
      "archived"
    end

    agent_method :delete_all, "Delete every record", permission: :readonly
    def self.delete_all
      "deleted"
    end
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    Parse::Agent::Tools.reset_registry!
    @saved_strict = Parse::Agent.strict_tool_filter
    Parse::Agent.strict_tool_filter = false
  end

  def teardown
    Parse::Agent::Tools.reset_registry!
    Parse::Agent.strict_tool_filter = @saved_strict
  end

  # ---- nil filter preserves today's behavior ----------------------------

  def test_nil_filter_does_not_narrow
    a = Parse::Agent.new(permissions: :readonly)
    assert_includes a.allowed_tools, :query_class
    assert_includes a.allowed_tools, :aggregate
    assert_includes a.allowed_tools, :call_method
  end

  # ---- Array form (shorthand for only:) ---------------------------------

  def test_array_shorthand_acts_as_only
    a = Parse::Agent.new(tools: [:query_class, :get_schema])
    assert_equal %i[get_schema query_class], a.allowed_tools.sort
  end

  def test_array_shorthand_accepts_strings
    a = Parse::Agent.new(tools: ["query_class"])
    assert_equal [:query_class], a.allowed_tools
  end

  # ---- Hash form: only -------------------------------------------------

  def test_hash_only_narrows
    a = Parse::Agent.new(tools: { only: [:query_class] })
    assert_equal [:query_class], a.allowed_tools
  end

  # ---- Hash form: except -----------------------------------------------

  def test_hash_except_removes_named_tools
    a = Parse::Agent.new(tools: { except: [:aggregate] })
    refute_includes a.allowed_tools, :aggregate
    assert_includes a.allowed_tools, :query_class
  end

  # ---- Both only and except compose ------------------------------------

  def test_only_and_except_compose
    a = Parse::Agent.new(
      tools: { only: [:query_class, :aggregate, :get_schema], except: [:aggregate] },
    )
    assert_equal %i[get_schema query_class], a.allowed_tools.sort
  end

  # ---- Empty arrays are fail-closed ------------------------------------

  def test_empty_only_array_produces_empty_allowed_tools
    a = Parse::Agent.new(tools: { only: [] })
    assert_equal [], a.allowed_tools
  end

  # ---- Filter cannot elevate above permission tier ---------------------

  def test_only_filter_cannot_expose_write_tool_on_readonly_agent
    a = Parse::Agent.new(permissions: :readonly, tools: { only: [:create_object, :query_class] })
    refute_includes a.allowed_tools, :create_object
    assert_includes a.allowed_tools, :query_class
  end

  def test_only_filter_cannot_expose_admin_tool_on_write_agent
    a = Parse::Agent.new(permissions: :write, tools: { only: [:delete_class] })
    refute_includes a.allowed_tools, :delete_class
  end

  # ---- Shape validation ------------------------------------------------

  def test_unknown_hash_key_raises_argument_error
    err = assert_raises(ArgumentError) { Parse::Agent.new(tools: { invalid: [] }) }
    assert_match(/only and :except/, err.message)
  end

  def test_non_array_only_raises
    err = assert_raises(ArgumentError) { Parse::Agent.new(tools: { only: "query_class" }) }
    assert_match(/:only must be an Array/, err.message)
  end

  def test_non_hash_non_array_raises
    err = assert_raises(ArgumentError) { Parse::Agent.new(tools: "query_class") }
    assert_match(/must be nil, an Array of names, or a Hash/, err.message)
  end

  def test_methods_kwarg_uses_same_validation
    err = assert_raises(ArgumentError) { Parse::Agent.new(methods: { invalid: [] }) }
    assert_match(/methods: accepts only :only and :except/, err.message)
  end

  # ---- Typo guard ------------------------------------------------------

  def test_unknown_tool_name_warns_in_non_strict_mode
    captured = capture_warns do
      a = Parse::Agent.new(tools: [:zzz_typo_tool])
      refute_includes a.allowed_tools, :zzz_typo_tool
    end
    assert_match(/zzz_typo_tool/, captured)
  end

  def test_unknown_tool_name_raises_in_strict_mode
    Parse::Agent.strict_tool_filter = true
    err = assert_raises(ArgumentError) { Parse::Agent.new(tools: [:zzz_typo_tool]) }
    assert_match(/unknown tool/, err.message)
  end

  def test_per_instance_strict_override_wins_over_class_default
    Parse::Agent.strict_tool_filter = false
    err = assert_raises(ArgumentError) do
      Parse::Agent.new(tools: [:zzz_typo_tool], strict_tool_filter: true)
    end
    assert_match(/unknown tool/, err.message)
  end

  def test_write_and_admin_tool_names_are_recognized_even_on_readonly_agent
    prev = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
    captured = capture_warns do
      Parse::Agent.new(
        permissions: :readonly,
        tools: { except: [:create_object, :update_object, :delete_object, :create_class, :delete_class] },
      )
    end
    refute_match(/unknown tool|typo/i, captured,
                 "permission-tier tool names should not trigger typo warning")
  ensure
    Parse::Agent.suppress_master_key_warning = prev
  end

  # ---- :tool_filtered distinct error_code ------------------------------

  def test_filtered_tool_returns_tool_filtered_error_code
    a = Parse::Agent.new(tools: { except: [:aggregate] })
    r = a.execute(:aggregate, class_name: "X", pipeline: [])
    refute r[:success]
    assert_equal :tool_filtered, r[:error_code]
    assert_match(/not enabled for this agent instance/, r[:error])
  end

  def test_tier_denied_tool_returns_permission_denied_error_code
    a = Parse::Agent.new(permissions: :readonly)
    r = a.execute(:create_object, class_name: "X", data: {})
    refute r[:success]
    assert_equal :permission_denied, r[:error_code]
    assert_match(/requires write permissions/, r[:error])
  end

  # ---- tool_definitions reflects filter (the load-bearing invariant) ----

  def test_tool_definitions_reflects_per_agent_filter
    a = Parse::Agent.new(tools: { only: [:query_class] })
    b = Parse::Agent.new(tools: { only: [:get_schema, :get_all_schemas] })

    a_names = a.tool_definitions(format: :mcp).map { |t| t[:name] }.sort
    b_names = b.tool_definitions(format: :mcp).map { |t| t[:name] }.sort

    assert_equal ["query_class"], a_names
    assert_equal ["get_all_schemas", "get_schema"], b_names
    refute_equal a_names, b_names,
                 "Two agents with different filters must produce different tools/list outputs"
  end

  # End-to-end through MCPDispatcher.call — the load-bearing invariant for
  # the multi-flavor /mcp use case (one mount point, per-request factory
  # produces agents with different filters). Tests the JSON-RPC wire
  # shape, not just the in-process method.
  def test_mcp_dispatcher_tools_list_reflects_per_request_filter
    require "parse/agent/mcp_dispatcher"

    dashboard_agent = Parse::Agent.new(tools: { only: [:query_class, :get_schema] })
    external_agent = Parse::Agent.new(tools: { only: [:get_all_schemas] })

    body = { "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => {} }
    dashboard_result = Parse::Agent::MCPDispatcher.call(body: body, agent: dashboard_agent)
    external_result = Parse::Agent::MCPDispatcher.call(body: body, agent: external_agent)

    dashboard_names = dashboard_result[:body]["result"]["tools"].map { |t| t[:name] }.sort
    external_names = external_result[:body]["result"]["tools"].map { |t| t[:name] }.sort

    assert_equal ["get_schema", "query_class"], dashboard_names
    assert_equal ["get_all_schemas"], external_names
    refute_equal dashboard_names, external_names,
                 "Per-agent tool filter must produce distinct tools/list wire output on shared dispatcher"
  end

  # ---- parent: inheritance --------------------------------------------

  def test_parent_kwarg_inherits_rate_limiter
    root = Parse::Agent.new
    sub = Parse::Agent.new(parent: root)
    assert_same root.rate_limiter, sub.rate_limiter,
                "Sub-agent must share the parent's rate limiter to enforce the budget"
  end

  def test_parent_kwarg_inherits_correlation_id
    root = Parse::Agent.new
    root.correlation_id = "session-abc"
    sub = Parse::Agent.new(parent: root)
    assert_equal "session-abc", sub.correlation_id
  end

  def test_parent_kwarg_records_parent_agent_id
    root = Parse::Agent.new
    sub = Parse::Agent.new(parent: root)
    assert_equal root.agent_id, sub.parent_agent_id
    assert_nil root.parent_agent_id
  end

  def test_parent_kwarg_increments_agent_depth
    root = Parse::Agent.new
    sub = Parse::Agent.new(parent: root)
    subsub = Parse::Agent.new(parent: sub)
    assert_equal 0, root.agent_depth
    assert_equal 1, sub.agent_depth
    assert_equal 2, subsub.agent_depth
  end

  def test_parent_must_be_a_parse_agent
    err = assert_raises(ArgumentError) { Parse::Agent.new(parent: "not-an-agent") }
    assert_match(/parent: must be a Parse::Agent/, err.message)
  end

  # ---- recursion_depth cap --------------------------------------------

  def test_recursion_depth_decrements
    root = Parse::Agent.new(recursion_depth: 3)
    s1 = Parse::Agent.new(parent: root)
    s2 = Parse::Agent.new(parent: s1)
    s3 = Parse::Agent.new(parent: s2)
    assert_equal 2, s1.recursion_depth
    assert_equal 1, s2.recursion_depth
    assert_equal 0, s3.recursion_depth
  end

  def test_recursion_cap_raises_at_zero
    root = Parse::Agent.new(recursion_depth: 1)
    s1 = Parse::Agent.new(parent: root)
    assert_raises(Parse::Agent::RecursionLimitExceeded) do
      Parse::Agent.new(parent: s1)
    end
  end

  def test_default_recursion_depth_uses_class_default
    saved = Parse::Agent.default_recursion_depth
    Parse::Agent.default_recursion_depth = 7
    a = Parse::Agent.new
    assert_equal 7, a.recursion_depth
  ensure
    Parse::Agent.default_recursion_depth = saved
  end

  # ---- Auth-scope inheritance (security-critical) -----------------------
  # Without these, a session-token parent silently produces a master-key
  # sub-agent, elevating privilege through the very kwarg meant to close
  # the sub-agent footgun.

  def test_parent_inheritance_does_not_drop_session_token
    parent = Parse::Agent.new(session_token: "r:abc123")
    sub = Parse::Agent.new(parent: parent)
    assert_equal "r:abc123", sub.session_token,
                 "Session-token parent must produce session-token sub-agent (auth-scope inheritance)"
  end

  def test_parent_inheritance_does_not_drop_tenant_id
    parent = Parse::Agent.new(tenant_id: "org_abc")
    sub = Parse::Agent.new(parent: parent)
    assert_equal "org_abc", sub.tenant_id
  end

  def test_explicit_session_token_overrides_inherited
    parent = Parse::Agent.new(session_token: "r:parent_token")
    sub = Parse::Agent.new(parent: parent, session_token: "r:child_token")
    assert_equal "r:child_token", sub.session_token
  end

  def test_parent_inheritance_does_not_inherit_permissions
    parent = Parse::Agent.new(permissions: :write)
    sub = Parse::Agent.new(parent: parent)
    assert_equal :readonly, sub.permissions,
                 "permissions: must be opt-in; sub-agents default to :readonly even with a :write parent"
  end

  def test_explicit_permissions_parity_with_parent_is_allowed
    parent = Parse::Agent.new(permissions: :write)
    sub = Parse::Agent.new(parent: parent, permissions: :write)
    assert_equal :write, sub.permissions
  end

  def test_explicit_permissions_below_parent_is_allowed
    parent = Parse::Agent.new(permissions: :admin)
    sub = Parse::Agent.new(parent: parent, permissions: :write)
    assert_equal :write, sub.permissions
  end

  def test_explicit_permissions_above_parent_raises
    parent = Parse::Agent.new(permissions: :readonly)
    err = assert_raises(ArgumentError) do
      Parse::Agent.new(parent: parent, permissions: :admin)
    end
    assert_match(/sub-agent permissions: :admin exceeds parent's permissions: :readonly/, err.message)
    assert_match(/cannot be more privileged than its parent/, err.message)
  end

  def test_explicit_permissions_write_above_readonly_parent_raises
    parent = Parse::Agent.new(permissions: :readonly)
    assert_raises(ArgumentError) do
      Parse::Agent.new(parent: parent, permissions: :write)
    end
  end

  def test_explicit_permissions_admin_above_write_parent_raises
    parent = Parse::Agent.new(permissions: :write)
    assert_raises(ArgumentError) do
      Parse::Agent.new(parent: parent, permissions: :admin)
    end
  end

  def test_parent_inheritance_sub_agent_uses_master_key_only_when_parent_did
    parent = Parse::Agent.new # master-key
    sub = Parse::Agent.new(parent: parent)
    refute sub.session_token
    # Master-key parent → master-key sub-agent (this is correct — the
    # sub-agent inherits the parent's auth scope, which here is "no
    # session token = master key").
  end

  # ---- Notification payload --------------------------------------------

  def test_notification_payload_includes_agent_id_and_depth
    events = []
    sub = ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args).payload.dup
    end

    a = Parse::Agent.new
    a.execute(:aggregate, class_name: "X", pipeline: []) rescue nil

    assert_equal 1, events.size
    payload = events.last
    assert_equal a.agent_id, payload[:agent_id]
    assert_equal 0, payload[:agent_depth]
    refute payload.key?(:parent_agent_id), "Root agent payload should not include parent_agent_id"
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  def test_notification_payload_includes_parent_agent_id_for_subagent
    events = []
    sub = ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args).payload.dup
    end

    root = Parse::Agent.new
    child = Parse::Agent.new(parent: root)
    child.execute(:aggregate, class_name: "X", pipeline: []) rescue nil

    payload = events.last
    assert_equal child.agent_id, payload[:agent_id]
    assert_equal root.agent_id, payload[:parent_agent_id]
    assert_equal 1, payload[:agent_depth]
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  # ---- methods: filter (Phase 2) ---------------------------------------

  def test_method_filtered_predicate_with_bare_only
    a = Parse::Agent.new(methods: [:archive])
    refute a.method_filtered?(:archive, class_name: "FilterArticle")
    assert a.method_filtered?(:delete_all, class_name: "FilterArticle")
  end

  def test_method_filtered_predicate_with_qualified_only
    a = Parse::Agent.new(methods: ["FilterArticle.archive"])
    refute a.method_filtered?(:archive, class_name: "FilterArticle")
    assert a.method_filtered?(:archive, class_name: "OtherClass")
  end

  def test_method_filtered_predicate_with_except
    a = Parse::Agent.new(methods: { except: ["FilterArticle.delete_all"] })
    refute a.method_filtered?(:archive, class_name: "FilterArticle")
    assert a.method_filtered?(:delete_all, class_name: "FilterArticle")
  end

  def test_nil_method_filter_permits_all
    a = Parse::Agent.new
    refute a.method_filtered?(:archive, class_name: "FilterArticle")
    refute a.method_filtered?(:delete_all, class_name: "FilterArticle")
  end

  def test_call_method_refuses_filtered_method_with_tool_filtered_code
    a = Parse::Agent.new(methods: { except: ["FilterArticle.delete_all"] })
    r = a.execute(:call_method, class_name: "FilterArticle", method_name: "delete_all")
    refute r[:success]
    assert_equal :tool_filtered, r[:error_code]
    assert_match(/FilterArticle.delete_all/, r[:error])
  end

  def test_call_method_permits_non_filtered_method
    a = Parse::Agent.new(methods: { except: ["FilterArticle.delete_all"] })
    r = a.execute(:call_method, class_name: "FilterArticle", method_name: "archive")
    assert r[:success], "non-filtered method should dispatch (got error: #{r[:error]})"
  end

  def test_method_filter_cannot_expose_undeclared_method
    a = Parse::Agent.new(methods: [:undeclared_method])
    r = a.execute(:call_method, class_name: "FilterArticle", method_name: "undeclared_method")
    refute r[:success], "filter never exposes a method that was not declared agent_method"
  end

  # ---- Sub-agent tools: / methods: narrow only (5.8.1) ------------------

  def test_sub_agent_tools_only_intersects_parent
    root = Parse::Agent.new(tools: { only: [:query_class, :count_objects] })
    sub = Parse::Agent.new(parent: root, tools: { only: [:count_objects, :get_schema] })
    assert_equal [:count_objects], sub.allowed_tools
  end

  def test_sub_agent_tools_only_without_overlap_raises
    root = Parse::Agent.new(tools: { only: [:query_class] })
    err = assert_raises(ArgumentError) { Parse::Agent.new(parent: root, tools: { only: [:get_schema] }) }
    assert_match(/no overlap with the parent's tools: filter/, err.message)
  end

  def test_sub_agent_without_tools_inherits_parent_filter
    root = Parse::Agent.new(tools: { only: [:query_class] })
    sub = Parse::Agent.new(parent: root)
    assert_equal [:query_class], sub.allowed_tools
  end

  def test_sub_agent_tools_except_unions_with_parent
    root = Parse::Agent.new(tools: { except: [:query_class] })
    sub = Parse::Agent.new(parent: root, tools: { except: [:count_objects] })
    refute_includes sub.allowed_tools, :query_class
    refute_includes sub.allowed_tools, :count_objects
  end

  def test_sub_agent_tools_only_cannot_reenable_parent_except
    root = Parse::Agent.new(tools: { except: [:query_class] })
    sub = Parse::Agent.new(parent: root, tools: { only: [:query_class, :count_objects] })
    assert_equal [:count_objects], sub.allowed_tools
    r = sub.execute(:query_class, class_name: "FilterArticle")
    refute r[:success]
    assert_equal :tool_filtered, r[:error_code]
  end

  def test_sub_agent_cannot_call_method_parent_was_not_given
    root = Parse::Agent.new(methods: { only: [:archive] })
    err = assert_raises(ArgumentError) { Parse::Agent.new(parent: root, methods: { only: [:delete_all] }) }
    assert_match(/no overlap with the parent's methods: filter/, err.message)
  end

  def test_sub_agent_method_filter_keeps_parent_layer
    root = Parse::Agent.new(methods: { only: [:archive] })
    sub = Parse::Agent.new(parent: root, methods: { only: [:archive, :delete_all] })
    refute sub.method_filtered?(:archive, class_name: "FilterArticle")
    assert sub.method_filtered?(:delete_all, class_name: "FilterArticle")
    r = sub.execute(:call_method, class_name: "FilterArticle", method_name: "delete_all")
    refute r[:success]
    assert_equal :tool_filtered, r[:error_code]
  end

  def test_sub_agent_without_methods_inherits_parent_filter
    root = Parse::Agent.new(methods: { except: ["FilterArticle.delete_all"] })
    sub = Parse::Agent.new(parent: root)
    assert sub.method_filtered?(:delete_all, class_name: "FilterArticle")
    refute sub.method_filtered?(:archive, class_name: "FilterArticle")
  end

  def test_sub_agent_methods_except_cannot_be_undone_by_child_only
    root = Parse::Agent.new(methods: { except: [:delete_all] })
    err = assert_raises(ArgumentError) { Parse::Agent.new(parent: root, methods: { only: [:delete_all] }) }
    assert_match(/no overlap/, err.message)
  end

  def test_sub_agent_qualified_entry_narrows_bare_parent_entry
    root = Parse::Agent.new(methods: { only: [:archive] })
    sub = Parse::Agent.new(parent: root, methods: { only: ["FilterArticle.archive"] })
    refute sub.method_filtered?(:archive, class_name: "FilterArticle")
    assert sub.method_filtered?(:archive, class_name: "OtherClass")
  end

  def test_sub_agent_bare_entry_under_qualified_parent_stays_class_bound
    root = Parse::Agent.new(methods: { only: ["FilterArticle.archive"] })
    sub = Parse::Agent.new(parent: root, methods: { only: [:archive] })
    refute sub.method_filtered?(:archive, class_name: "FilterArticle")
    assert sub.method_filtered?(:archive, class_name: "OtherClass")
  end

  def test_grandchild_keeps_every_ancestor_method_layer
    root = Parse::Agent.new(methods: { only: [:archive, :delete_all] })
    mid = Parse::Agent.new(parent: root, methods: { except: [:delete_all] })
    leaf = Parse::Agent.new(parent: mid)
    assert leaf.method_filtered?(:delete_all, class_name: "FilterArticle")
    refute leaf.method_filtered?(:archive, class_name: "FilterArticle")
  end

  def test_sub_agent_tools_only_empty_is_kept
    root = Parse::Agent.new(tools: { only: [:query_class] })
    sub = Parse::Agent.new(parent: root, tools: { only: [] })
    assert_empty sub.allowed_tools
  end

  def test_sub_agent_methods_only_empty_is_kept
    root = Parse::Agent.new(methods: { only: [:archive] })
    sub = Parse::Agent.new(parent: root, methods: { only: [] })
    assert sub.method_filtered?(:archive, class_name: "FilterArticle")
  end

  def test_sub_agent_tools_only_fully_excluded_by_parent_raises
    root = Parse::Agent.new(tools: { only: [:query_class, :count_objects], except: [:query_class] })
    err = assert_raises(ArgumentError) { Parse::Agent.new(parent: root, tools: { only: [:query_class] }) }
    assert_match(/no overlap with the parent's tools: filter/, err.message)
  end

  def test_sub_agent_tools_only_inside_parent_except_only_raises
    root = Parse::Agent.new(tools: { except: [:query_class] })
    err = assert_raises(ArgumentError) { Parse::Agent.new(parent: root, tools: { only: [:query_class] }) }
    assert_match(/no overlap/, err.message)
  end

  # ---- Class aliases in methods: entries ------------------------------

  def test_qualified_method_entry_matches_user_alias_both_ways
    a = Parse::Agent.new(methods: { except: ["_User.reset_all"] })
    assert a.method_filtered?(:reset_all, class_name: "_User")
    assert a.method_filtered?(:reset_all, class_name: "User")

    b = Parse::Agent.new(methods: { except: ["User.reset_all"] })
    assert b.method_filtered?(:reset_all, class_name: "_User")
    assert b.method_filtered?(:reset_all, class_name: "User")
  end

  def test_qualified_method_only_entry_matches_alias
    a = Parse::Agent.new(methods: { only: ["User.reset_all"] })
    refute a.method_filtered?(:reset_all, class_name: "_User")
    assert a.method_filtered?(:other, class_name: "_User")
  end

  def test_qualified_method_entries_match_other_system_aliases
    %w[Role Session Installation].each do |name|
      a = Parse::Agent.new(methods: { except: ["_#{name}.purge"] })
      assert a.method_filtered?(:purge, class_name: name), "#{name} alias should match _#{name}"
    end
  end

  # ---- Sub-agent approval gate (5.8.1) ---------------------------------

  class DenyGate < Parse::Agent::ApprovalGate
    attr_reader :calls
    def initialize; @calls = 0; end
    def review(**)
      @calls += 1
      Parse::Agent::ApprovalDecision.deny("denied by test gate")
    end
  end

  def with_required_approval(tiers)
    prior = Parse::Agent.require_approval_for
    Parse::Agent.require_approval_for = tiers
    yield
  ensure
    Parse::Agent.require_approval_for = prior
  end

  def test_sub_agent_uses_parent_approval_gate
    with_required_approval([:readonly]) do
      root = Parse::Agent.new
      gate = DenyGate.new
      root.approval_gate = gate
      sub = Parse::Agent.new(parent: root)
      r = sub.execute(:get_all_schemas)
      refute r[:success]
      assert_equal :approval_denied, r[:error_code]
      assert_equal 1, gate.calls
    end
  end

  def test_sub_agent_sees_gate_swapped_on_parent_after_construction
    with_required_approval([:readonly]) do
      root = Parse::Agent.new
      sub = Parse::Agent.new(parent: root)
      gate = DenyGate.new
      root.approval_gate = gate
      r = sub.execute(:get_all_schemas)
      assert_equal :approval_denied, r[:error_code]
      root.approval_gate = Parse::Agent::NullGate.new
      assert_kind_of Parse::Agent::NullGate, sub.approval_gate
    end
  end

  def test_sub_agent_own_gate_takes_precedence
    root = Parse::Agent.new
    root.approval_gate = DenyGate.new
    sub = Parse::Agent.new(parent: root)
    own = Parse::Agent::NullGate.new
    sub.approval_gate = own
    assert_same own, sub.approval_gate
  end

  # ---- Effective method layers in audit / describe ---------------------

  def test_describe_reports_inherited_method_layers
    root = Parse::Agent.new(methods: { except: [:delete_all] })
    sub = Parse::Agent.new(parent: root)
    methods = sub.describe[:methods]
    assert_nil methods[:only]
    assert_nil methods[:except]
    assert_equal [{ only: nil, except: ["delete_all"] }], methods[:layers]
  end

  # ---- v4.2 follow-up safety fixes ------------------------------------

  def test_agent_id_is_a_uuid_string
    a = Parse::Agent.new
    assert_kind_of String, a.agent_id
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, a.agent_id,
                 "agent_id must be a UUID so GC-reused object_ids cannot collide in audit logs")
  end

  def test_distinct_agents_have_distinct_agent_ids
    a = Parse::Agent.new
    b = Parse::Agent.new
    refute_equal a.agent_id, b.agent_id
  end

  def test_sub_agent_inherits_parent_cancellation_token
    parent = Parse::Agent.new
    token = Parse::Agent::CancellationToken.new
    parent.cancellation_token = token
    sub = Parse::Agent.new(parent: parent)

    assert_same token, sub.cancellation_token,
                "Sub-agent must inherit parent's cancellation token so cooperative cancel reaches the delegation subtree"
    refute sub.cancelled?

    token.cancel!(reason: :test)
    assert sub.cancelled?, "Cancelling parent's token must trip the inherited sub-agent token"
  end

  def test_sub_agent_inherits_parent_progress_callback
    parent = Parse::Agent.new
    cb = ->(progress:, total: nil, message: nil) { :unused }
    parent.progress_callback = cb
    sub = Parse::Agent.new(parent: parent)
    assert_same cb, sub.progress_callback
  end

  def test_empty_session_token_inherits_from_parent
    parent = Parse::Agent.new(session_token: "r:parent_token")
    sub = Parse::Agent.new(parent: parent, session_token: "")
    assert_equal "r:parent_token", sub.session_token,
                 "Empty-string session_token must be treated as unset so ACL scoping isn't silently disabled"
  end

  def test_empty_tenant_id_inherits_from_parent
    parent = Parse::Agent.new(tenant_id: "org_abc")
    sub = Parse::Agent.new(parent: parent, tenant_id: "")
    assert_equal "org_abc", sub.tenant_id
  end

  def test_recursion_depth_kwarg_with_parent_emits_warning
    root = Parse::Agent.new(recursion_depth: 3)
    warns = capture_warns do
      Parse::Agent.new(parent: root, recursion_depth: 99)
    end
    assert_match(/recursion_depth: kwarg is ignored when parent: is passed/, warns)
  end

  def test_recursion_depth_kwarg_with_parent_uses_parents_budget
    root = Parse::Agent.new(recursion_depth: 3)
    sub = nil
    capture_warns { sub = Parse::Agent.new(parent: root, recursion_depth: 99) }
    assert_equal root.recursion_depth - 1, sub.recursion_depth,
                 "Explicit recursion_depth: must NOT widen the inherited budget"
  end

  # ---- Helpers ---------------------------------------------------------

  private

  def capture_warns
    original_stderr = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original_stderr
  end
end
