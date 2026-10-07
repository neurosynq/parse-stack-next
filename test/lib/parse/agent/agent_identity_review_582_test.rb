# encoding: UTF-8
# frozen_string_literal: true

require "json"
require "yaml"
require_relative "../../../test_helper"

# 5.8.2 review follow-ups to TRACK-AGENT-4 and the agent inspect redaction:
# serialization redaction, sub-agent scope reuse, the impersonate race, the
# failed-resolution backoff, refresh_scope!, and error wording.
class AgentIdentityReview582Test < Minitest::Test
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

  def scope_for(token)
    user = token.to_s.delete_prefix("r:")
    Parse::ACLScope::Resolution.new(mode: :session, user_id: user, permission_strings: ["*", user])
  end

  def unresolved_agent(token = "r:alice")
    Parse::ACLScope.stub(:resolve!, failing_resolve) do
      Parse::Agent.new(session_token: token)
    end
  end

  def resolved_agent(token = "r:alice")
    Parse::ACLScope.stub(:resolve!, ->(opts, **_k) { scope_for(opts[:session_token]) }) do
      Parse::Agent.new(session_token: token)
    end
  end

  # 1. Serialization never carries credentials.

  def test_agent_json_and_yaml_are_redacted
    agent = resolved_agent("r:SECRET_TOKEN")
    [agent.to_json, JSON.generate(agent.as_json), agent.to_yaml].each do |out|
      refute_includes out, "r:SECRET_TOKEN"
      refute_includes out, "test_master_key"
    end
    assert_equal agent.agent_id, agent.as_json["agent_id"]
  end

  def test_client_json_and_yaml_are_redacted
    client = Parse::Client.new(server_url: "http://localhost:1337/parse", app_id: "app",
                               api_key: "REST_KEY_SECRET", master_key: "MASTER_SECRET")
    bound = client.become("r:BOUND_SECRET")
    [client, bound].each do |c|
      [c.to_json, c.to_yaml].each do |out|
        %w[MASTER_SECRET REST_KEY_SECRET r:BOUND_SECRET].each { |secret| refute_includes out, secret }
      end
      assert_equal "app", c.as_json["app_id"]
    end
  end

  # 2. A sub-agent holding its parent's token reuses the parent's scope.

  def test_child_with_parent_token_reuses_resolved_scope
    parent = resolved_agent
    calls = 0
    counting_fail = ->(*_a, **_k) { calls += 1; raise "server unreachable" }
    child = Parse::ACLScope.stub(:resolve!, counting_fail) { Parse::Agent.new(parent: parent) }
    assert_equal 0, calls, "the child must not resolve the same token again"
    assert_equal ["*", "alice"], child.acl_permission_strings
  end

  def test_child_with_other_token_that_fails_is_unresolved_not_widening
    parent = resolved_agent
    err = Parse::ACLScope.stub(:resolve!, failing_resolve) do
      assert_raises(Parse::Agent::UnresolvedIdentity) do
        Parse::Agent.new(parent: parent, session_token: "r:other")
      end
    end
    refute_match(/widen/, err.message)
  end

  # 3. A concurrent impersonate cannot leave one token's scope on another.

  def test_impersonate_during_lazy_resolution_does_not_bind_stale_scope
    agent = unresolved_agent("r:alice")
    started = Queue.new
    slow = lambda do |opts, **_k|
      if opts[:session_token] == "r:alice"
        started << true
        sleep 0.3
      end
      scope_for(opts[:session_token])
    end
    Parse::ACLScope.stub(:resolve!, slow) do
      resolver = Thread.new { agent.acl_scope }
      started.pop
      agent.stub(:resolve_impersonation_token!, "r:bob") { agent.impersonate("bob") }
      resolver.join
      assert_equal "r:bob", agent.session_token
      assert_equal ["*", "bob"], agent.acl_permission_strings,
                   "the scope must belong to the token the agent now holds"
    end
  end

  # 4. A failed lazy resolution is remembered briefly.

  def test_failed_lazy_resolution_backs_off
    agent = unresolved_agent
    calls = 0
    counting_fail = ->(*_a, **_k) { calls += 1; raise "server unreachable" }
    Parse::ACLScope.stub(:resolve!, counting_fail) do
      3.times { assert_raises(Parse::Agent::UnresolvedIdentity) { agent.acl_permission_strings } }
    end
    assert_equal 1, calls, "repeated reads inside the backoff window must not retry"
    # Once the window has passed, the next use retries.
    agent.instance_variable_set(:@scope_failed_at,
                                Process.clock_gettime(Process::CLOCK_MONOTONIC) - 60)
    Parse::ACLScope.stub(:resolve!, ->(opts, **_k) { scope_for(opts[:session_token]) }) do
      assert_equal ["*", "alice"], agent.acl_permission_strings
    end
  end

  # 5. refresh_scope! resolves or raises for a session agent.

  def test_refresh_scope_never_returns_nil_for_a_session_agent
    agent = unresolved_agent
    Parse::ACLScope.stub(:resolve!, failing_resolve) do
      assert_raises(Parse::Agent::UnresolvedIdentity) { agent.refresh_scope! }
    end
    agent.instance_variable_set(:@scope_failed_at, nil)
    Parse::ACLScope.stub(:resolve!, ->(opts, **_k) { scope_for(opts[:session_token]) }) do
      assert_equal ["*", "alice"], agent.refresh_scope!.permission_strings
    end
  end

  # 6. Error wording and audit identity.

  def test_invalid_token_gets_its_own_message
    agent = unresolved_agent
    invalid = ->(*_a, **_k) { raise Parse::Authorization::InvalidSession, "session token invalid or expired" }
    err = Parse::ACLScope.stub(:resolve!, invalid) do
      assert_raises(Parse::Agent::UnresolvedIdentity) { agent.acl_scope }
    end
    assert_match(/invalid or expired/, err.message)
    assert_equal :unresolved_identity, err.kind
  end

  def test_unresolved_agent_audit_identity_is_a_fingerprint
    agent = unresolved_agent("r:alice")
    identity = agent.auth_context[:identity]
    assert_match(/\Asession:\h{8}\z/, identity)
    refute_includes identity, "alice"
  end

  # The unresolved check and the scope read in #acl_scope are one locked
  # step: an #impersonate that lands between them waits instead of clearing
  # the scope under the reader, which would read as master-key posture.
  def test_impersonate_between_check_and_read_never_yields_nil
    agent = resolved_agent("r:alice")
    checked = Queue.new
    go = Queue.new
    original = agent.method(:session_scope_unresolved?)
    paused = false
    agent.define_singleton_method(:session_scope_unresolved?) do
      result = original.call
      if Thread.current[:pause_scope_read] && !paused
        paused = true
        checked << true
        go.pop
      end
      result
    end
    reader = Thread.new do
      Thread.current[:pause_scope_read] = true
      Parse::ACLScope.stub(:resolve!, ->(opts, **_k) { scope_for(opts[:session_token]) }) do
        agent.acl_permission_strings
      end
    end
    checked.pop
    swapper = Thread.new do
      agent.stub(:resolve_impersonation_token!, "r:bob") { agent.impersonate("bob") }
    end
    sleep 0.1
    go << true
    perms = reader.value
    swapper.join
    refute_nil perms, "a session agent must never read as master-key posture"
    assert_equal ["*", "alice"], perms
    # The impersonation still applies afterwards, resolved under its token.
    later = Parse::ACLScope.stub(:resolve!, ->(opts, **_k) { scope_for(opts[:session_token]) }) do
      agent.acl_permission_strings
    end
    assert_equal ["*", "bob"], later
  end

  def test_permission_strings_raise_when_a_session_scope_is_missing
    agent = resolved_agent("r:alice")
    agent.define_singleton_method(:acl_scope) { nil }
    assert_raises(Parse::Agent::UnresolvedIdentity) { agent.acl_permission_strings }
  end
end
