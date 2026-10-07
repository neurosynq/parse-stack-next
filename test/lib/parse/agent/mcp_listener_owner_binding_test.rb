# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"
require "parse/agent/mcp_rack_app"
require "json"
require "stringio"

# Owner-binding for the MCP listening stream (#6): only the principal that
# established a session (or the first to attach for an ad-hoc notifications-bus
# id) may open its server->client SSE stream. A different authenticated caller
# who knows/guesses the id is refused, closing the cross-session subscribe/evict
# hijack.
class MCPListenerOwnerBindingTest < Minitest::Test
  # Minimal agent double whose identity surface is what principal_fingerprint
  # reads. correlation_id defaults to nil so the rack app assigns it from the
  # Mcp-Session-Id header (matching production).
  class AgentStub
    attr_accessor :correlation_id
    attr_reader :session_token, :acl_user_scope, :acl_role_scope, :client

    def initialize(session_token: nil, acl_user_scope: nil, acl_role_scope: nil)
      @correlation_id = nil
      @session_token = session_token
      @acl_user_scope = acl_user_scope
      @acl_role_scope = acl_role_scope
      @client = Struct.new(:master_key).new(session_token ? nil : "mk")
    end
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "a", api_key: "k")
    end
  end

  # Factory: the X-Principal header selects the caller's session token, so two
  # requests model two distinct authenticated principals. No header => a bare
  # master-key agent (the shared "mk" fingerprint).
  def build_app(principal_resolver: nil)
    factory = lambda do |env|
      tok = env["HTTP_X_PRINCIPAL"]
      AgentStub.new(session_token: tok)
    end
    Parse::Agent::MCPRackApp.new(notifications: true,
                                 principal_resolver: principal_resolver,
      &factory)
  end

  def get_env(session_id:, principal: nil)
    env = {
      "REQUEST_METHOD" => "GET",
      "HTTP_ACCEPT" => "text/event-stream",
      "HTTP_MCP_SESSION_ID" => session_id,
      "rack.input" => StringIO.new(""),
    }
    env["HTTP_X_PRINCIPAL"] = principal if principal
    env
  end

  def delete_env(session_id:)
    {
      "REQUEST_METHOD" => "DELETE",
      "HTTP_MCP_SESSION_ID" => session_id,
      "rack.input" => StringIO.new(""),
    }
  end

  def post_initialize_env(session_id:, principal: nil)
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json",
      "rack.input" => StringIO.new(JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => "initialize")),
    }
    env["HTTP_MCP_SESSION_ID"] = session_id if session_id
    env["HTTP_X_PRINCIPAL"] = principal if principal
    env
  end

  def test_first_attach_claims_session_tofu
    app = build_app
    status, _h, body = app.call(get_env(session_id: "sess-1", principal: "r:alice"))
    assert_equal 200, status
    body.close
  end

  def test_same_principal_may_reattach
    app = build_app
    s1, _h, b1 = app.call(get_env(session_id: "sess-1", principal: "r:alice"))
    assert_equal 200, s1
    b1.close
    s2, _h, b2 = app.call(get_env(session_id: "sess-1", principal: "r:alice"))
    assert_equal 200, s2, "the owning principal must be able to reconnect"
    b2.close
  end

  def test_different_principal_is_denied
    app = build_app
    s1, _h, b1 = app.call(get_env(session_id: "sess-1", principal: "r:alice"))
    assert_equal 200, s1
    b1.close
    s2, _h, _b = app.call(get_env(session_id: "sess-1", principal: "r:mallory"))
    assert_equal 403, s2, "a different principal must not attach to a claimed session"
  end

  def test_delete_forgets_binding_so_id_can_be_reclaimed
    app = build_app
    s1, _h, b1 = app.call(get_env(session_id: "sess-1", principal: "r:alice"))
    assert_equal 200, s1
    b1.close
    # Another principal cannot terminate the session (5.8).
    refused, = app.call(delete_env(session_id: "sess-1").merge("HTTP_X_PRINCIPAL" => "r:mallory"))
    assert_equal 403, refused
    dstatus, = app.call(delete_env(session_id: "sess-1").merge("HTTP_X_PRINCIPAL" => "r:alice"))
    assert_equal 204, dstatus
    # After explicit termination a new principal may claim the id.
    s2, _h, b2 = app.call(get_env(session_id: "sess-1", principal: "r:mallory"))
    assert_equal 200, s2
    b2.close
  end

  def test_initialize_binds_session_to_principal
    app = build_app
    istatus, headers, = app.call(post_initialize_env(session_id: "sess-init", principal: "r:alice"))
    assert_equal 200, istatus
    assert_equal "sess-init", headers["Mcp-Session-Id"]
    # A different principal cannot attach to the initialize-bound session,
    # even though it never opened a stream.
    s2, _h, _b = app.call(get_env(session_id: "sess-init", principal: "r:mallory"))
    assert_equal 403, s2
    # The initializing principal can.
    s3, _h, b3 = app.call(get_env(session_id: "sess-init", principal: "r:alice"))
    assert_equal 200, s3
    b3.close
  end

  def test_initialize_cannot_rebind_a_session_owned_by_another_principal
    app = build_app
    s1, = app.call(post_initialize_env(session_id: "sess-own", principal: "r:alice"))
    assert_equal 200, s1
    s2, = app.call(post_initialize_env(session_id: "sess-own", principal: "r:mallory"))
    assert_equal 403, s2, "re-initializing another principal's session must be refused"
    # Ownership is unchanged: alice can still attach, mallory still cannot.
    s3, _h, b3 = app.call(get_env(session_id: "sess-own", principal: "r:alice"))
    assert_equal 200, s3
    b3.close
    s4, = app.call(get_env(session_id: "sess-own", principal: "r:mallory"))
    assert_equal 403, s4
  end

  def test_owner_may_reinitialize_its_own_session
    app = build_app
    s1, = app.call(post_initialize_env(session_id: "sess-re", principal: "r:alice"))
    s2, = app.call(post_initialize_env(session_id: "sess-re", principal: "r:alice"))
    assert_equal [200, 200], [s1, s2]
  end

  def test_initialize_cannot_take_over_a_stream_claimed_session
    app = build_app
    s1, _h, b1 = app.call(get_env(session_id: "sess-tofu", principal: "r:alice"))
    assert_equal 200, s1
    b1.close
    s2, = app.call(post_initialize_env(session_id: "sess-tofu", principal: "r:mallory"))
    assert_equal 403, s2
  end

  def test_live_session_binding_survives_lru_pressure
    live = %w[s-live]
    reg = Parse::Agent::MCPRackApp::SessionOwnerRegistry.new(max_entries: 2, pinned: ->(sid) { live.include?(sid) })
    reg.bind("s-live", "op:alice")
    reg.bind("s-a", "op:x")
    reg.bind("s-b", "op:y")
    reg.bind("s-c", "op:z")
    assert reg.owned_by?("s-live", "op:alice"), "a live session keeps its owner under eviction pressure"
    refute reg.owned_by?("s-a", "op:x"), "idle sessions are still evicted"
  end

  def test_full_pinned_registry_refuses_admission_instead_of_dropping_ownership
    reg = Parse::Agent::MCPRackApp::SessionOwnerRegistry.new(max_entries: 1, pinned: ->(_sid) { true })
    assert_equal true, reg.bind("s-live", "op:alice")
    assert_equal :full, reg.bind("s-new", "op:bob"), "cannot keep a new owner when every slot is live"
    assert_equal :full, reg.authorize_attach("s-other", "op:eve")
    refute reg.controllable_by?("s-live", "op:bob")
    assert reg.owned_by?("s-live", "op:alice")
  end

  def test_master_key_agents_share_one_principal_without_resolver
    # Documented limitation: with no principal_resolver, bare master-key agents
    # are indistinguishable, so owner-binding is a no-op among them.
    app = build_app
    s1, _h, b1 = app.call(get_env(session_id: "sess-1")) # no principal => "mk"
    assert_equal 200, s1
    b1.close
    s2, _h, b2 = app.call(get_env(session_id: "sess-1")) # another "mk" caller
    assert_equal 200, s2
    b2.close
  end

  def test_principal_resolver_distinguishes_master_key_callers
    # An operator that authenticates users upstream supplies a per-user
    # principal, turning owner-binding from a no-op into real protection even
    # for master-key agents.
    resolver = ->(_agent, env) { env["HTTP_X_USER"] }
    factory = ->(_env) { AgentStub.new } # always bare master-key
    app = Parse::Agent::MCPRackApp.new(notifications: true,
                                       principal_resolver: resolver,
      &factory)
    e1 = get_env(session_id: "sess-1")
    e1["HTTP_X_USER"] = "alice"
    s1, _h, b1 = app.call(e1)
    assert_equal 200, s1
    b1.close

    e2 = get_env(session_id: "sess-1")
    e2["HTTP_X_USER"] = "mallory"
    s2, = app.call(e2)
    assert_equal 403, s2, "resolver-supplied principals must owner-bind master-key agents"
  end

  def test_invalid_principal_resolver_rejected_at_construction
    assert_raises(ArgumentError) do
      Parse::Agent::MCPRackApp.new(notifications: true, principal_resolver: "not-callable") { |_e| AgentStub.new }
    end
  end

  # --- acl_role / acl_user principal fingerprint stability ---

  def build_role_app
    factory = ->(env) { AgentStub.new(acl_role_scope: env["HTTP_X_ROLE"]) }
    Parse::Agent::MCPRackApp.new(notifications: true, &factory)
  end

  def role_env(session_id:, role:)
    e = get_env(session_id: session_id)
    e["HTTP_X_ROLE"] = role
    e
  end

  def test_acl_role_string_principal_is_stable_for_reconnect
    app = build_role_app
    s1, _h, b1 = app.call(role_env(session_id: "sess-r", role: "Admin"))
    assert_equal 200, s1
    b1.close
    s2, _h, b2 = app.call(role_env(session_id: "sess-r", role: "Admin"))
    assert_equal 200, s2, "same acl_role must reconnect (stable fingerprint)"
    b2.close
  end

  def test_acl_role_different_role_denied
    app = build_role_app
    s1, _h, b1 = app.call(role_env(session_id: "sess-r", role: "Admin"))
    assert_equal 200, s1
    b1.close
    s2, = app.call(role_env(session_id: "sess-r", role: "Editor"))
    assert_equal 403, s2
  end

  # A scope OBJECT whose bare #to_s differs per instance but whose #id is
  # stable — the case that would false-reject the owner if the fingerprint
  # used #to_s instead of #id.
  class UserScopeObj
    attr_reader :id

    def initialize(id)
      @id = id
    end
  end

  def test_acl_user_object_fingerprint_is_stable_across_instances
    factory = ->(env) { AgentStub.new(acl_user_scope: UserScopeObj.new(env["HTTP_X_UID"])) }
    app = Parse::Agent::MCPRackApp.new(notifications: true, &factory)

    e1 = get_env(session_id: "sess-u")
    e1["HTTP_X_UID"] = "u123"
    s1, _h, b1 = app.call(e1)
    assert_equal 200, s1
    b1.close

    # New request → factory builds a fresh UserScopeObj (different object_id /
    # #to_s) with the same #id → must still match and allow reconnect.
    e2 = get_env(session_id: "sess-u")
    e2["HTTP_X_UID"] = "u123"
    s2, _h, b2 = app.call(e2)
    assert_equal 200, s2, "stable :id-based fingerprint must allow the owner to reconnect"
    b2.close

    # Different user id → different principal → denied.
    e3 = get_env(session_id: "sess-u")
    e3["HTTP_X_UID"] = "u999"
    s3, = app.call(e3)
    assert_equal 403, s3
  end
end
