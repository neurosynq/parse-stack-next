# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# TRACK-AGENT-4: a session-token agent whose token could not be resolved at
# construction must not be treated as master-key posture by the SDK-side
# permission checks. Parse Server still validates the token on REST calls;
# the gap was the local CLP gate (and anything else that reads the agent's
# claim set), which reads `nil` as "master, bypass".
class AgentUnresolvedIdentityTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test",
                  master_key: "test_master_key")
    end
    @prior_suppress = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
    Parse::Agent.reset_master_key_warning!
  end

  def teardown
    Parse::Agent.suppress_master_key_warning = @prior_suppress
    Parse::Agent.reset_master_key_warning!
  end

  def failing_resolve
    ->(*_args, **_kw) { raise "server unreachable" }
  end

  def resolved_scope(user_id = "u1")
    Parse::ACLScope::Resolution.new(mode: :session, user_id: user_id,
                                    permission_strings: ["*", user_id])
  end

  def unresolved_agent
    Parse::ACLScope.stub(:resolve!, failing_resolve) do
      Parse::Agent.new(session_token: "r:alice")
    end
  end

  def test_failed_resolution_is_not_master_posture
    agent = unresolved_agent
    assert agent.acl_scope?, "a session-token agent is scoped even before its token resolves"
    assert agent.requires_mongo_direct?
    Parse::ACLScope.stub(:resolve!, failing_resolve) do
      assert_raises(Parse::Agent::UnresolvedIdentity) { agent.acl_permission_strings }
      assert_raises(Parse::Agent::UnresolvedIdentity) { agent.acl_read_match_stage }
      assert_raises(Parse::Agent::UnresolvedIdentity) { agent.acl_scope }
    end
  end

  def test_clp_gate_refuses_instead_of_bypassing
    agent = unresolved_agent
    seen = []
    permits = ->(_cls, _op, perms) { seen << perms; true }
    Parse::ACLScope.stub(:resolve!, failing_resolve) do
      Parse::CLPScope.stub(:permits?, permits) do
        err = assert_raises(Parse::Agent::UnresolvedIdentity) do
          Parse::Agent::Tools.assert_class_accessible!("Song", agent: agent, op: :find)
        end
        assert_equal :unresolved_identity, err.kind
      end
    end
    refute_includes seen, nil, "the CLP check must never run with a nil (master) claim set for a session agent"
  end

  def test_tool_call_reports_access_denied
    agent = unresolved_agent
    Parse::ACLScope.stub(:resolve!, failing_resolve) do
      result = agent.execute(:count_objects, class_name: "Song")
      refute result[:success]
      assert_equal :access_denied, result[:error_code]
      assert_match(/could not be resolved/, result[:error].to_s)
    end
  end

  def test_resolution_is_retried_lazily
    agent = unresolved_agent
    Parse::ACLScope.stub(:resolve!, ->(*_a, **_k) { resolved_scope }) do
      assert_equal ["*", "u1"], agent.acl_permission_strings
    end
    # Once resolved it is kept; no further resolution is attempted.
    Parse::ACLScope.stub(:resolve!, failing_resolve) do
      assert_equal ["*", "u1"], agent.acl_permission_strings
    end
  end

  def test_master_key_agent_is_unchanged
    agent = Parse::Agent.new
    Parse::ACLScope.stub(:resolve!, failing_resolve) do
      assert_nil agent.acl_scope
      assert_nil agent.acl_permission_strings
      refute agent.acl_scope?
      Parse::CLPScope.stub(:permits?, ->(*_a) { true }) do
        Parse::Agent::Tools.assert_class_accessible!("Song", agent: agent, op: :find)
      end
    end
  end

  def test_impersonated_agent_resolves_before_the_clp_gate
    agent = Parse::Agent.new
    agent.stub(:resolve_impersonation_token!, "r:bob") { agent.impersonate("bob") }
    seen = []
    Parse::ACLScope.stub(:resolve!, ->(*_a, **_k) { resolved_scope("bob") }) do
      Parse::CLPScope.stub(:permits?, ->(_c, _o, perms) { seen << perms; true }) do
        Parse::Agent::Tools.assert_class_accessible!("Song", agent: agent, op: :find)
      end
    end
    assert_equal [["*", "bob"]], seen
  end

  def test_child_of_unresolved_parent_cannot_pick_another_identity
    parent = unresolved_agent
    Parse::ACLScope.stub(:resolve!, failing_resolve) do
      role = Parse::Role.new(name: "admin")
      Parse::ACLScope.stub(:resolve_for_role, Parse::ACLScope::Resolution.new(
        mode: :role, permission_strings: ["*", "role:admin"],
      )) do
        assert_raises(Parse::Agent::UnresolvedIdentity) do
          Parse::Agent.new(parent: parent, acl_role: role)
        end
      end
      # Inheriting the parent's own token is fine: it is the same identity.
      child = Parse::Agent.new(parent: parent)
      assert_equal "r:alice", child.session_token
    end
  end
end
