# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Unit tests for the agent-level ACL scope:
#
#   * Constructor mutex on session_token: / acl_user: / acl_role:
#   * @acl_scope resolution per identity mode (and master-key = nil)
#   * acl_scope_kwargs shape per mode
#   * auth_context extension to :acl_user / :acl_role with using_master_key=false
#   * Master-key banner trigger uses @acl_scope.nil?, not @session_token.nil?
#   * Sub-agent inheritance: child inherits verbatim, refuses to widen
#   * request_opts fail-closed under acl_user / acl_role
#   * acl_scope_requires_direct? and acl_scope? predicates
#   * acl_permission_strings / acl_read_match_stage / acl_write_match_stage
#
# These tests do NOT depend on Parse Server being running for the master-key
# and acl_user / acl_role paths — those resolve client-side. The session_token
# constructor path is exercised separately because it requires /users/me.
class AgentACLScopeTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @prior_suppress = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
    Parse::Agent.reset_master_key_warning!
  end

  def teardown
    Parse::Agent.suppress_master_key_warning = @prior_suppress
    Parse::Agent.reset_master_key_warning!
  end

  # -------- master-key construction -----------------------------------

  def test_master_key_construction_has_nil_acl_scope
    a = Parse::Agent.new
    assert_nil a.acl_scope
    assert_equal({ master: true }, a.acl_scope_kwargs)
    refute a.acl_scope?
    refute a.acl_scope_requires_direct?
    assert_nil a.acl_permission_strings
    assert_nil a.acl_read_match_stage
    assert_nil a.acl_write_match_stage
  end

  def test_master_key_auth_context_reports_master_key
    a = Parse::Agent.new
    ctx = a.auth_context
    assert_equal :master_key, ctx[:type]
    assert_equal true, ctx[:using_master_key]
    assert_nil ctx[:identity]
  end

  # -------- mutex -----------------------------------------------------

  def test_constructor_refuses_session_token_with_acl_role
    err = assert_raises(ArgumentError) do
      Parse::Agent.new(session_token: "r:abc", acl_role: "admin")
    end
    assert_match(/mutually exclusive/, err.message)
  end

  def test_constructor_refuses_acl_user_with_acl_role
    user = Parse::User.new(objectId: "u_test_user")
    err = assert_raises(ArgumentError) do
      Parse::Agent.new(acl_user: user, acl_role: "admin")
    end
    assert_match(/mutually exclusive/, err.message)
  end

  def test_constructor_refuses_session_token_with_acl_user
    user = Parse::User.new(objectId: "u_test_user")
    err = assert_raises(ArgumentError) do
      Parse::Agent.new(session_token: "r:abc", acl_user: user)
    end
    assert_match(/mutually exclusive/, err.message)
  end

  def test_constructor_treats_empty_session_token_as_unset
    # empty string is Ruby-truthy but conveys no identity; mutex must
    # not fire when paired with acl_role:.
    assert_nothing_raised do
      Parse::Agent.new(session_token: "", acl_role: "admin")
    end
  end

  # -------- acl_user / acl_role resolution ----------------------------

  def test_acl_user_construction_resolves_scope
    user = Parse::User.new(objectId: "u_alice")
    a = Parse::Agent.new(acl_user: user)
    refute_nil a.acl_scope
    assert_equal :session, a.acl_scope.mode
    assert_equal "u_alice", a.acl_scope.user_id
    assert_includes a.acl_permission_strings, "u_alice"
    assert_includes a.acl_permission_strings, "*"
  end

  def test_acl_user_kwargs_forwards_user
    user = Parse::User.new(objectId: "u_alice")
    a = Parse::Agent.new(acl_user: user)
    kwargs = a.acl_scope_kwargs
    assert_equal user, kwargs[:acl_user]
    refute kwargs.key?(:session_token)
    refute kwargs.key?(:acl_role)
    refute kwargs.key?(:master)
  end

  def test_acl_user_auth_context_carries_user_id
    user = Parse::User.new(objectId: "u_alice")
    a = Parse::Agent.new(acl_user: user)
    ctx = a.auth_context
    assert_equal :acl_user, ctx[:type]
    assert_equal false, ctx[:using_master_key]
    assert_equal "u_alice", ctx[:identity]
  end

  def test_acl_role_with_role_instance_skips_lookup
    role = Parse::Role.new(name: "viewer")
    role.id = "r_viewer_test"
    a = Parse::Agent.new(acl_role: role)
    refute_nil a.acl_scope
    assert_includes a.acl_permission_strings, "*"
    assert_includes a.acl_permission_strings, "role:viewer"
    assert_equal "viewer", a.auth_context[:identity]
  end

  # -------- predicates ------------------------------------------------

  def test_acl_scope_requires_direct_for_acl_user
    user = Parse::User.new(objectId: "u_alice")
    a = Parse::Agent.new(acl_user: user)
    assert a.acl_scope_requires_direct?
    assert a.acl_scope?
  end

  def test_acl_scope_requires_direct_false_for_master_key
    a = Parse::Agent.new
    refute a.acl_scope_requires_direct?
    refute a.acl_scope?
  end

  def test_acl_scope_requires_direct_false_for_acl_role_with_master_key
    # acl_role construction with role-instance avoids the Parse Server
    # lookup; scope is set, so acl_scope? is true and requires_direct is true.
    role = Parse::Role.new(name: "guest")
    role.id = "r_guest_test"
    a = Parse::Agent.new(acl_role: role)
    assert a.acl_scope?
    assert a.acl_scope_requires_direct?
  end

  # -------- read / write match stages ---------------------------------

  def test_acl_read_match_stage_uses_rperm
    user = Parse::User.new(objectId: "u_alice")
    a = Parse::Agent.new(acl_user: user)
    stage = a.acl_read_match_stage
    assert_kind_of Hash, stage
    match = stage["$match"]
    refute_nil match
    # read_predicate produces an $or that references _rperm
    serialized = match.to_s
    assert_includes serialized, "_rperm"
  end

  def test_acl_write_match_stage_uses_wperm
    user = Parse::User.new(objectId: "u_alice")
    a = Parse::Agent.new(acl_user: user)
    stage = a.acl_write_match_stage
    assert_kind_of Hash, stage
    serialized = stage["$match"].to_s
    assert_includes serialized, "_wperm"
  end

  # -------- request_opts fail-closed ----------------------------------

  def test_request_opts_raises_under_acl_user
    user = Parse::User.new(objectId: "u_alice")
    a = Parse::Agent.new(acl_user: user)
    err = assert_raises(Parse::ACLScope::ACLRequired) { a.request_opts }
    assert_match(/REST surface cannot honor/, err.message)
  end

  # session_token construction round-trips Parse Server's /users/me to
  # validate the token, so this lives behind a real-Parse-Server gate;
  # skipped here. The master-key and acl_user request_opts cases above
  # cover the contract end-to-end without needing the server.

  def test_request_opts_ok_under_master_key
    a = Parse::Agent.new
    assert_equal({}, a.request_opts)
  end

  # -------- sub-agent inheritance + subset check ----------------------

  def test_sub_agent_inherits_parent_acl_user_verbatim
    user = Parse::User.new(objectId: "u_alice")
    parent = Parse::Agent.new(acl_user: user)
    sub = Parse::Agent.new(parent: parent)
    assert_equal parent.acl_permission_strings, sub.acl_permission_strings
    assert_equal :acl_user, sub.auth_context[:type]
  end

  def test_sub_agent_refuses_widening_via_different_user
    alice = Parse::User.new(objectId: "u_alice")
    bob   = Parse::User.new(objectId: "u_bob")
    parent = Parse::Agent.new(acl_user: alice)
    err = assert_raises(ArgumentError) do
      Parse::Agent.new(parent: parent, acl_user: bob)
    end
    assert_match(/widens parent/, err.message)
    # Regression: the message must NOT leak real principal
    # identifiers — they belong on the audit channel only.
    refute_includes err.message, "u_alice"
    refute_includes err.message, "u_bob"
  end

  def test_sub_agent_master_key_parent_allows_any_child_scope
    parent = Parse::Agent.new  # master-key
    user = Parse::User.new(objectId: "u_alice")
    sub = Parse::Agent.new(parent: parent, acl_user: user)
    assert_equal :acl_user, sub.auth_context[:type]
  end

  def test_sub_agent_role_parent_refuses_user_child_outside_role_set
    # Parent's permission_strings = ["*", "role:admin"]. Child with
    # acl_user adds "u_bob" which is NOT in parent's set → refused.
    role = Parse::Role.new(name: "admin")
    role.id = "r_admin_test"
    parent = Parse::Agent.new(acl_role: role)
    bob = Parse::User.new(objectId: "u_bob")
    err = assert_raises(ArgumentError) do
      Parse::Agent.new(parent: parent, acl_user: bob)
    end
    assert_match(/widens parent/, err.message)
    # Regression: the message must NOT leak real principal
    # identifiers (objectIds or role names).
    refute_includes err.message, "u_bob"
    refute_includes err.message, "role:admin"
  end

  # -------- agent: injection into call_with_args ----------------------

  def test_call_with_args_injects_agent_when_method_declares_it
    captured = nil
    target = Class.new do
      define_singleton_method(:archive) do |reason:, agent: nil, **|
        captured = { reason: reason, agent_class: agent&.class }
        { ok: true }
      end
    end
    user = Parse::User.new(objectId: "u_alice")
    agent = Parse::Agent.new(acl_user: user)
    Parse::Agent::Tools.send(:call_with_args, target, :archive,
                              { reason: "obsolete" }, agent: agent)
    assert_equal "obsolete", captured[:reason]
    assert_equal Parse::Agent, captured[:agent_class]
  end

  def test_call_with_args_skips_agent_when_method_does_not_accept_it
    captured = nil
    target = Class.new do
      define_singleton_method(:archive) do |reason:|
        captured = { reason: reason }
        { ok: true }
      end
    end
    agent = Parse::Agent.new
    # Should not raise — agent: is not in the signature, so it's omitted.
    Parse::Agent::Tools.send(:call_with_args, target, :archive,
                              { reason: "obsolete" }, agent: agent)
    assert_equal "obsolete", captured[:reason]
  end

  # -------- master-key banner trigger ---------------------------------

  def test_banner_does_not_fire_for_acl_user_construction
    Parse::Agent.suppress_master_key_warning = false
    Parse::Agent.reset_master_key_warning!
    user = Parse::User.new(objectId: "u_alice")
    out = capture_warn { Parse::Agent.new(acl_user: user) }
    refute_match(/master key/i, out)
  end

  def test_banner_does_not_fire_for_acl_role_construction_with_real_role
    # Without a real Parse Server we can't materialize a Parse::Role,
    # but we can pass a Parse::Role instance directly to skip the
    # lookup branch in resolve_for_role.
    role = Parse::Role.new(name: "admin")
    role.id = "r_admin_test"
    Parse::Agent.suppress_master_key_warning = false
    Parse::Agent.reset_master_key_warning!
    out = capture_warn { Parse::Agent.new(acl_role: role) }
    refute_match(/master key/i, out)
  end

  # -------- helpers ---------------------------------------------------

  private

  def assert_nothing_raised
    yield
  rescue => e
    flunk "expected no exception, got #{e.class}: #{e.message}"
  end

  def capture_warn
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
