# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# Exercises the elicitation round-trip (MCPElicitationGate +
# PendingElicitationRegistry) directly, simulating the two-POST
# rendezvous WITHOUT a live transport: one thread blocks in #review while
# another delivers the reply (or aborts / times out).
class ElicitationRendezvousTest < Minitest::Test
  Gate = Parse::Agent::MCPElicitationGate
  Registry = Parse::Agent::PendingElicitationRegistry

  def setup
    @pending = Registry.new
    @published = []
    @publish = ->(cid, req) { @published << [cid, req]; true }
  end

  def build_gate(correlation_id: "S1", timeout: 2, capability: true, listener: true,
                 elic_id: "elic-1", publish: @publish)
    Gate.new(
      correlation_id: correlation_id,
      pending: @pending,
      publish: publish,
      capability_check: ->(_cid) { capability },
      listener_check: ->(_cid) { listener },
      timeout: timeout,
      id_generator: -> { elic_id },
    )
  end

  def wait_until(timeout = 2)
    deadline = Time.now + timeout
    until yield
      raise "condition not met within #{timeout}s" if Time.now > deadline
      sleep 0.005
    end
  end

  def review_async(gate)
    Thread.new { gate.review(tool_name: :call_method, effective_permission: :write, preview: { x: 1 }, agent: nil) }
  end

  def test_accept_approves
    gate = build_gate
    t = review_async(gate)
    wait_until { @published.any? }
    assert_equal 1, @pending.size
    assert @pending.deliver("S1", "elic-1", :accept)
    decision = t.value
    assert decision.approved?
    assert_equal 0, @pending.size, "entry should be cleared after delivery"
  end

  def test_decline_denies
    gate = build_gate
    t = review_async(gate)
    wait_until { @published.any? }
    @pending.deliver("S1", "elic-1", :decline)
    decision = t.value
    refute decision.approved?
    assert_equal :deny, decision.outcome
  end

  def test_cancel_denies
    gate = build_gate
    t = review_async(gate)
    wait_until { @published.any? }
    @pending.deliver("S1", "elic-1", :cancel)
    assert_equal :deny, t.value.outcome
  end

  def test_timeout_is_unavailable
    gate = build_gate(timeout: 0.1)
    decision = gate.review(tool_name: :call_method, effective_permission: :write, preview: {}, agent: nil)
    assert_equal :unavailable, decision.outcome
    assert_match(/timed out/, decision.reason)
    assert_equal 0, @pending.size, "entry should be deregistered on timeout"
  end

  def test_abort_is_unavailable
    gate = build_gate
    t = review_async(gate)
    wait_until { @published.any? }
    assert_equal 1, @pending.abort_all_for("S1", :session_terminated)
    decision = t.value
    assert_equal :unavailable, decision.outcome
    assert_match(/aborted/, decision.reason)
  end

  def test_double_reply_is_harmless
    gate = build_gate
    t = review_async(gate)
    wait_until { @published.any? }
    assert_equal true,  @pending.deliver("S1", "elic-1", :accept)
    assert_equal false, @pending.deliver("S1", "elic-1", :decline), "second reply is a no-op"
    assert t.value.approved?
  end

  def test_reply_after_timeout_finds_nothing
    gate = build_gate(timeout: 0.1)
    decision = gate.review(tool_name: :call_method, effective_permission: :write, preview: {}, agent: nil)
    assert_equal :unavailable, decision.outcome
    # A late reply for the (now-deregistered) request returns false.
    assert_equal false, @pending.deliver("S1", "elic-1", :accept)
  end

  def test_cross_session_cannot_answer
    gate = build_gate(correlation_id: "S1", timeout: 0.3)
    t = review_async(gate)
    wait_until { @published.any? }
    # Another session tries to answer S1's prompt (guessed id, wrong session).
    assert_equal false, @pending.deliver("S2", "elic-1", :accept)
    decision = t.value
    assert_equal :unavailable, decision.outcome, "S1 must time out, not be answered by S2"
  end

  def test_no_capability_fails_closed_without_publishing
    gate = build_gate(capability: false)
    decision = gate.review(tool_name: :call_method, effective_permission: :write, preview: {}, agent: nil)
    assert_equal :unavailable, decision.outcome
    assert_match(/capability/, decision.reason)
    assert_empty @published, "must not publish when client lacks capability"
  end

  def test_no_listener_fails_closed_without_publishing
    gate = build_gate(listener: false)
    decision = gate.review(tool_name: :call_method, effective_permission: :write, preview: {}, agent: nil)
    assert_equal :unavailable, decision.outcome
    assert_match(/listening stream/, decision.reason)
    assert_empty @published
  end

  def test_undeliverable_publish_fails_closed
    gate = build_gate(publish: ->(_cid, _req) { false })
    decision = gate.review(tool_name: :call_method, effective_permission: :write, preview: {}, agent: nil)
    assert_equal :unavailable, decision.outcome
    assert_equal 0, @pending.size, "entry deregistered when publish fails"
  end

  def test_published_request_shape
    gate = build_gate(timeout: 0.1)
    gate.review(tool_name: :call_method, effective_permission: :admin, preview: { would: "delete" }, agent: nil)
    _cid, req = @published.first
    assert_equal "2.0", req["jsonrpc"]
    assert_equal "elic-1", req["id"]
    assert_equal "elicitation/create", req["method"]
    assert req["params"]["requestedSchema"]["properties"].key?("approve")
    assert_equal({ would: "delete" }, req["params"]["_meta"]["parse.preview"])
    assert_equal "admin", req["params"]["_meta"]["parse.permission"]
  end

  def test_blank_correlation_id_unavailable
    gate = build_gate(correlation_id: "")
    decision = gate.review(tool_name: :call_method, effective_permission: :write, preview: {}, agent: nil)
    assert_equal :unavailable, decision.outcome
  end
end
