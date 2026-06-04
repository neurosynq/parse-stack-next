# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# Unit tests for the approval-gate primitives: ApprovalDecision and the
# default NullGate. The MCPElicitationGate round-trip is exercised
# separately in elicitation_rendezvous_test.rb.
class ApprovalGateTest < Minitest::Test
  Decision = Parse::Agent::ApprovalDecision

  def test_approve_decision
    d = Decision.approve
    assert d.approved?
    assert_equal :approve, d.outcome
    assert_nil d.reason
  end

  def test_deny_decision
    d = Decision.deny("rejected")
    refute d.approved?
    assert_equal :deny, d.outcome
    assert_equal "rejected", d.reason
  end

  def test_unavailable_decision
    d = Decision.unavailable("no stream")
    refute d.approved?
    assert_equal :unavailable, d.outcome
    assert_equal "no stream", d.reason
  end

  def test_null_gate_always_approves
    gate = Parse::Agent::NullGate.new
    d = gate.review(tool_name: :call_method, effective_permission: :admin, preview: {}, agent: nil)
    assert d.approved?
  end

  def test_abstract_gate_review_raises
    assert_raises(NotImplementedError) do
      Parse::Agent::ApprovalGate.new.review(
        tool_name: :x, effective_permission: :write, preview: {}, agent: nil,
      )
    end
  end

  def test_pending_registry_register_returns_nil_for_blank_correlation_id
    reg = Parse::Agent::PendingElicitationRegistry.new
    assert_nil reg.register("", "e1")
    assert_nil reg.register(nil, "e1")
    assert_nil reg.register("S1", "")
  end

  def test_capability_registry_defaults_false_and_forgets
    reg = Parse::Agent::ClientCapabilityRegistry.new
    assert_equal false, reg.get("unknown")
    reg.set("S1", true)
    assert_equal true, reg.get("S1")
    reg.forget("S1")
    assert_equal false, reg.get("S1")
  end
end
