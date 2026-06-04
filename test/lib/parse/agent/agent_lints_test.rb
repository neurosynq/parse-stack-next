# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# Covers the fail-loud operator lints/observability added for the MCP
# usability review: M1 (ungated-writes warning), M2 (agent-visible-but-unscoped
# class lint), and MN4 (approval observability event).
class AgentLintsTest < Minitest::Test
  Reg = Parse::Agent::MetadataRegistry

  def setup
    Parse::Agent.reset_mcp_writes_unguarded_warning!
    Reg.reset_tenant_scope_lint!
    # Snapshot the global registries a test mutates so it doesn't leak into
    # the rest of the suite (flipping any_tenant_scope? or agent-visibility).
    @saved_rules = Reg.instance_variable_get(:@tenant_scope_rules).dup
    @saved_searchable = Reg.instance_variable_get(:@searchable_classes).dup
  end

  def teardown
    Parse::Agent.reset_mcp_writes_unguarded_warning!
    Reg.instance_variable_set(:@tenant_scope_rules, @saved_rules)
    Reg.instance_variable_set(:@searchable_classes, @saved_searchable)
    Reg.reset_tenant_scope_lint!
  end

  # Make a class explicitly agent-visible (the lint only fires for classes
  # opted into the agent surface, not every class a tool touches).
  def make_agent_visible(class_name)
    Reg.register_searchable(class_name, field: :embedding)
  end

  # --- M1: ungated-writes warning ---

  def test_mcp_writes_unguarded_warns_once
    _out, err = capture_io { Parse::Agent.warn_mcp_writes_unguarded! }
    assert_match(/require_approval_for is empty/, err)
    # Second call is silent (one-time).
    _out2, err2 = capture_io { Parse::Agent.warn_mcp_writes_unguarded! }
    assert_equal "", err2
  end

  def test_mcp_writes_unguarded_rearmed_by_reset
    capture_io { Parse::Agent.warn_mcp_writes_unguarded! }
    Parse::Agent.reset_mcp_writes_unguarded_warning!
    _out, err = capture_io { Parse::Agent.warn_mcp_writes_unguarded! }
    assert_match(/SECURITY/, err)
  end

  # --- M2: agent-visible-but-unscoped class lint ---

  def fake_agent
    Object.new
  end

  def test_unscoped_class_warns_when_deployment_is_tenant_aware
    Reg.register_tenant_scope("ScopedClassForLint", :workspace, from: ->(_a) { "Workspace$x" })
    make_agent_visible("UnscopedClassForLint")
    out, err = capture_io do
      result = Reg.resolve_tenant_scope("UnscopedClassForLint", fake_agent)
      assert_nil result, "unscoped class still passes through (returns nil), just warns"
    end
    combined = out + err
    assert_match(/agent-visible but declares no/, combined)
    assert_match(/UnscopedClassForLint/, combined)
  end

  def test_unscoped_class_warns_only_once_per_class
    Reg.register_tenant_scope("ScopedClassForLint", :workspace, from: ->(_a) { "Workspace$x" })
    make_agent_visible("UnscopedClassForLint")
    capture_io { Reg.resolve_tenant_scope("UnscopedClassForLint", fake_agent) }
    _out, err = capture_io { Reg.resolve_tenant_scope("UnscopedClassForLint", fake_agent) }
    assert_equal "", err, "the lint is once-per-class-per-process"
  end

  def test_no_warning_for_non_agent_visible_class
    # The lint is gated to classes explicitly opted into the agent surface, so
    # a system/incidental class (e.g. _User) the agent merely touches stays
    # silent even in a tenant-aware deployment — that was the noise concern.
    Reg.register_tenant_scope("ScopedClassForLint", :workspace, from: ->(_a) { "Workspace$x" })
    out, err = capture_io { Reg.resolve_tenant_scope("_User", fake_agent) }
    assert_equal "", (out + err), "non-agent-visible classes must not trip the lint"
  end

  def test_no_warning_when_no_tenant_scopes_anywhere
    # Snapshot restored in teardown guarantees an empty rule set here.
    Reg.instance_variable_set(:@tenant_scope_rules, {})
    make_agent_visible("UnscopedClassForLint")
    out, err = capture_io { Reg.resolve_tenant_scope("UnscopedClassForLint", fake_agent) }
    assert_equal "", (out + err), "a fully unscoped deployment is back-compat — no lint"
  end

  # --- MN4: approval observability event ---

  def test_approval_emits_notification_with_outcome
    events = []
    sub = ActiveSupport::Notifications.subscribe("parse.agent.approval") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    # capability_check returns false → fast :unavailable, no threads/queues.
    gate = Parse::Agent::MCPElicitationGate.new(
      correlation_id: "sess-1",
      pending: Parse::Agent::PendingElicitationRegistry.new,
      publish: ->(_cid, _req) { true },
      capability_check: ->(_cid) { false },
      listener_check: ->(_cid) { true },
      timeout: 1,
    )
    decision = gate.review(tool_name: :delete_object, effective_permission: :admin,
                           preview: { tool: "delete_object" }, agent: Object.new)

    refute decision.approved?
    assert_equal 1, events.length
    payload = events.first.payload
    assert_equal :delete_object, payload[:tool]
    assert_equal :admin, payload[:effective_permission]
    assert_equal :unavailable, payload[:outcome]
    assert_match(/elicitation capability/, payload[:reason])
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end
end
