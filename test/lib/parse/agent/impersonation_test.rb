# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# Tests agent impersonation (D2-AS variant b: genuine session-token
# resolution) and the variant-a audit label. Session lookup and minting
# are stubbed so these run without a live server.
class AgentImpersonationTest < Minitest::Test
  def setup
    unless Parse::Client.client? && Parse::Client.client.master_key
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "a", api_key: "k", master_key: "m")
    end
    Parse::Agent.suppress_master_key_warning = true
  end

  # A chainable query double whose #first returns `result`. Supports
  # `client=` because resolve_impersonation_token! scopes the lookup to the
  # agent's own client before calling #first.
  def session_chain(result)
    chain = Object.new
    chain.define_singleton_method(:where) { |*_| self }
    chain.define_singleton_method(:order) { |*_| self }
    chain.define_singleton_method(:client=) { |*_| nil }
    chain.define_singleton_method(:first) { result }
    chain
  end

  def session_double(token)
    s = Object.new
    s.define_singleton_method(:session_token) { token }
    s
  end

  def test_mutual_exclusion_with_session_token
    assert_raises(ArgumentError) do
      Parse::Agent.new(session_token: "x", impersonate_user: "u1")
    end
  end

  def test_rejects_non_user_pointer
    assert_raises(ArgumentError) do
      Parse::Agent.new(impersonate_user: Parse::Pointer.new("Order", "abc"))
    end
  end

  def test_reuses_existing_active_session
    Parse::Session.stub(:for_user, session_chain(session_double("r:imptoken"))) do
      agent = Parse::Agent.new(impersonate_user: "user123")
      assert_equal "r:imptoken", agent.session_token
      assert_equal "user123", agent.impersonated_user_id
    end
  end

  def test_no_active_session_without_mint_fails_closed
    Parse::Session.stub(:for_user, session_chain(nil)) do
      err = assert_raises(ArgumentError) do
        Parse::Agent.new(impersonate_user: "user123")
      end
      assert_match(/no active session/, err.message)
    end
  end

  def test_mint_creates_session_when_none_active
    minted = Object.new
    minted.define_singleton_method(:success?) { true }
    minted.define_singleton_method(:result) { { "sessionToken" => "r:minted" } }
    Parse::Session.stub(:for_user, session_chain(nil)) do
      Parse::Client.client.stub(:create_object, minted) do
        agent = Parse::Agent.new(impersonate_user: "user123", impersonate_mint: true)
        assert_equal "r:minted", agent.session_token
      end
    end
  end

  def test_variant_a_role_with_audit_label
    Parse::ACLScope.stub(:resolve_for_role, nil) do
      agent = Parse::Agent.new(acl_role: "Admin", impersonation_label: "ticket-4821")
      assert_equal "ticket-4821", agent.impersonation_label
    end
  end

  def test_label_sanitization_truncates
    Parse::ACLScope.stub(:resolve_for_role, nil) do
      agent = Parse::Agent.new(acl_role: "Admin", impersonation_label: "x" * 300)
      assert_equal 128, agent.impersonation_label.length
    end
  end

  def test_label_non_string_ignored
    Parse::ACLScope.stub(:resolve_for_role, nil) do
      agent = Parse::Agent.new(acl_role: "Admin", impersonation_label: 12_345)
      assert_nil agent.impersonation_label
    end
  end

  def test_impersonate_post_construction
    agent = Parse::Agent.new(permissions: :readonly)
    Parse::Session.stub(:for_user, session_chain(session_double("r:tok2"))) do
      agent.impersonate("user999")
    end
    assert_equal "r:tok2", agent.session_token
    assert_equal "user999", agent.impersonated_user_id
  end

  def test_impersonation_user_alias_resolves_like_impersonate_user
    Parse::Session.stub(:for_user, session_chain(session_double("r:aliastok"))) do
      agent = Parse::Agent.new(impersonation_user: "user123")
      assert_equal "r:aliastok", agent.session_token
      assert_equal "user123", agent.impersonated_user_id
    end
  end

  def test_permission_singular_alias_on_agent_new
    Parse::ACLScope.stub(:resolve_for_role, nil) do
      agent = Parse::Agent.new(acl_role: "Admin", permission: :admin)
      assert_equal :admin, agent.permissions
    end
  end

  def test_stop_impersonating_clears_binding
    agent = Parse::Agent.new(permissions: :readonly)
    Parse::Session.stub(:for_user, session_chain(session_double("r:tok3"))) do
      agent.impersonate("user999")
    end
    agent.stop_impersonating!
    assert_nil agent.session_token
    assert_nil agent.impersonated_user_id
  end
end
