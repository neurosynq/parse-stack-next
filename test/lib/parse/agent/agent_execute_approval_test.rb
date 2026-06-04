# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# Tests the human-in-the-loop approval gate on Parse::Agent#execute, the
# transport-agnostic seam. A fake gate stands in for MCP elicitation, so
# these run without any transport.
class AgentExecuteApprovalTest < Minitest::Test
  class ApprovalWidget < Parse::Object
    parse_class "ApprovalExecWidget"
    property :name, :string

    @@writes = 0
    def self.writes; @@writes; end
    def self.reset_writes; @@writes = 0; end

    agent_method :do_write, "A destructive write", permission: :write
    def self.do_write
      @@writes += 1
      { wrote: true }
    end

    agent_method :do_read, "A read", permission: :readonly
    def self.do_read
      { read: true }
    end
  end

  # Records review calls and returns a fixed decision.
  class RecordingGate < Parse::Agent::ApprovalGate
    attr_reader :calls
    def initialize(decision)
      @decision = decision
      @calls = []
    end

    def review(tool_name:, effective_permission:, preview:, agent:)
      @calls << { tool_name: tool_name, effective_permission: effective_permission, preview: preview }
      @decision
    end
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    ApprovalWidget.reset_writes
    @saved = Parse::Agent.require_approval_for
    @saved_write_env = ENV.delete("PARSE_AGENT_ALLOW_WRITE_TOOLS")
    ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = "true"
  end

  def teardown
    Parse::Agent.require_approval_for = @saved
    @saved_write_env ? ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = @saved_write_env
                     : ENV.delete("PARSE_AGENT_ALLOW_WRITE_TOOLS")
  end

  def admin_agent(gate)
    a = Parse::Agent.new(permissions: :admin, allow_mutations: true)
    a.approval_gate = gate
    a
  end

  def test_denied_approval_blocks_execution
    Parse::Agent.require_approval_for = [:write, :admin]
    gate = RecordingGate.new(Parse::Agent::ApprovalDecision.deny("nope"))
    agent = admin_agent(gate)

    result = agent.execute(:call_method, class_name: "ApprovalExecWidget", method_name: "do_write")

    assert_equal false, result[:success]
    assert_equal :approval_denied, result[:error_code]
    assert_equal 0, ApprovalWidget.writes, "destructive method must not run when denied"
    assert_equal 1, gate.calls.length
    # Effective tier is the target method's :write, not call_method's :readonly.
    assert_equal :write, gate.calls.first[:effective_permission]
  end

  def test_approved_allows_execution
    Parse::Agent.require_approval_for = [:write, :admin]
    gate = RecordingGate.new(Parse::Agent::ApprovalDecision.approve)
    agent = admin_agent(gate)

    result = agent.execute(:call_method, class_name: "ApprovalExecWidget", method_name: "do_write")

    assert result[:success], "expected success, got #{result.inspect}"
    assert_equal 1, ApprovalWidget.writes
    assert_equal 1, gate.calls.length
  end

  def test_readonly_method_via_call_method_not_gated
    Parse::Agent.require_approval_for = [:write, :admin]
    gate = RecordingGate.new(Parse::Agent::ApprovalDecision.deny("would block if consulted"))
    agent = admin_agent(gate)

    result = agent.execute(:call_method, class_name: "ApprovalExecWidget", method_name: "do_read")

    assert result[:success], "readonly method should run, got #{result.inspect}"
    assert_equal 0, gate.calls.length, "gate must not be consulted for a readonly target method"
  end

  def test_no_opt_in_means_gate_not_consulted
    Parse::Agent.require_approval_for = []
    gate = RecordingGate.new(Parse::Agent::ApprovalDecision.deny("would block if consulted"))
    agent = admin_agent(gate)

    result = agent.execute(:call_method, class_name: "ApprovalExecWidget", method_name: "do_write")

    assert result[:success]
    assert_equal 1, ApprovalWidget.writes
    assert_equal 0, gate.calls.length
  end

  def test_effective_permission_for_call_method_resolves_target_tier
    agent = Parse::Agent.new(permissions: :admin)
    assert_equal :write,
                 agent.send(:effective_permission_for, :call_method,
                            { class_name: "ApprovalExecWidget", method_name: "do_write" })
    assert_equal :readonly,
                 agent.send(:effective_permission_for, :call_method,
                            { class_name: "ApprovalExecWidget", method_name: "do_read" })
  end
end
