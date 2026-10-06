# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"
require "parse/agent/mcp_rack_app"
require "json"
require "stringio"

# Session ownership on the POST path: a session bound to one principal
# refuses every request from another, subscriptions need a session the
# caller established, and one principal cannot flood the owner registry
# to evict other principals' bindings.
class MCPSessionOwnershipTest < Minitest::Test
  class AgentStub
    attr_accessor :correlation_id, :log_callback, :progress_callback, :cancellation_token
    attr_reader :session_token, :acl_user_scope, :acl_role_scope, :client, :rate_limiter

    def initialize(session_token: nil, rate_limiter: nil)
      @correlation_id = nil
      @session_token = session_token
      @rate_limiter = rate_limiter
      @client = Struct.new(:master_key).new(session_token ? nil : "mk")
    end

    def log(*); end

    def execute(_tool_name, **_kwargs)
      { success: true, data: { ok: true } }
    end
  end

  class FakeManager
    attr_reader :subscribed

    def initialize
      @subscribed = []
    end

    def supported?
      true
    end

    def listener?(_sid)
      false
    end

    def subscribe(session_id:, uri:, agent:)
      @subscribed << [session_id, uri]
      true
    end

    def unsubscribe(session_id:, uri:)
      true
    end
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse", application_id: "a", api_key: "k")
    end
    @restub = defined?(MCPDispatcherStub) && !MCPDispatcherStub.instance_variable_get(:@original_call).nil?
    MCPDispatcherStub.restore! if @restub
    @limiters = {}
  end

  def teardown
    MCPDispatcherStub.install! if @restub
  end

  def build_app(limit: nil)
    Parse::Agent::MCPRackApp.new do |env|
      principal = env["HTTP_X_PRINCIPAL"]
      limiter = limit && (@limiters[principal] ||= Parse::Agent::RateLimiter.new(limit: limit, window: 60))
      AgentStub.new(session_token: principal, rate_limiter: limiter)
    end
  end

  def post(app, method, params: {}, session_id: nil, principal: nil)
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json",
      "rack.input" => StringIO.new(JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params)),
    }
    env["HTTP_MCP_SESSION_ID"] = session_id if session_id
    env["HTTP_X_PRINCIPAL"] = principal if principal
    status, _headers, body = app.call(env)
    [status, (JSON.parse(body.join) rescue nil)]
  end

  def test_other_principal_is_refused_on_a_bound_session
    app = build_app
    status, = post(app, "initialize", params: { "protocolVersion" => "2025-11-25" }, session_id: "s1", principal: "alice")
    assert_equal 200, status

    status, res = post(app, "ping", session_id: "s1", principal: "mallory")
    assert_equal 403, status
    assert res["error"]

    status, = post(app, "ping", session_id: "s1", principal: "alice")
    assert_equal 200, status
  end

  def test_unbound_session_still_serves_ordinary_calls
    app = build_app
    status, = post(app, "ping", session_id: "never-initialized", principal: "alice")
    assert_equal 200, status
  end

  def test_subscribe_requires_a_session_the_caller_established
    app = build_app
    manager = FakeManager.new
    app.instance_variable_set(:@subscription_manager, manager)

    status, = post(app, "resources/subscribe", params: { "uri" => "parse://Post/count" },
                                              session_id: "invented", principal: "mallory")
    assert_equal 404, status, "an unknown session is answered 404 so the client re-initializes"
    assert_empty manager.subscribed

    post(app, "initialize", params: { "protocolVersion" => "2025-11-25" }, session_id: "s1", principal: "alice")
    status, = post(app, "resources/subscribe", params: { "uri" => "parse://Post/count" },
                                              session_id: "s1", principal: "alice")
    assert_equal 200, status
    assert_equal [["s1", "parse://Post/count"]], manager.subscribed
  end

  def test_initialize_is_charged_against_the_principal_limiter
    app = build_app(limit: 2)
    assert_equal 200, post(app, "initialize", session_id: "a1", principal: "alice").first
    assert_equal 200, post(app, "initialize", session_id: "a2", principal: "alice").first
    assert_equal 429, post(app, "initialize", session_id: "a3", principal: "alice").first
    assert_equal 200, post(app, "initialize", session_id: "b1", principal: "bob").first
  end

  def test_one_principal_cannot_evict_another_principals_bindings
    registry = Parse::Agent::MCPRackApp::SessionOwnerRegistry.new(max_entries: 50, max_per_principal: 5)
    assert_equal true, registry.bind("victim", "alice")
    200.times { |i| registry.bind("flood-#{i}", "mallory") }

    assert registry.owned_by?("victim", "alice"), "the victim's binding survives the flood"
    assert registry.owned_by?("flood-199", "mallory")
    refute registry.owned_by?("flood-0", "mallory"), "the flooder's own oldest bindings were evicted"
    assert_equal 6, registry.size
  end

  def test_per_principal_bound_refuses_when_all_own_bindings_are_pinned
    pinned = %w[p1 p2]
    registry = Parse::Agent::MCPRackApp::SessionOwnerRegistry.new(
      max_entries: 50, max_per_principal: 2, pinned: ->(sid) { pinned.include?(sid) },
    )
    assert_equal true, registry.bind("p1", "alice")
    assert_equal true, registry.bind("p2", "alice")
    assert_equal :full, registry.bind("p3", "alice")
    refute registry.owned_by?("p3", "alice")
    assert_equal true, registry.bind("b1", "bob")
  end

  def test_forget_releases_the_principal_slot
    registry = Parse::Agent::MCPRackApp::SessionOwnerRegistry.new(max_entries: 50, max_per_principal: 1, pinned: ->(_) { true })
    assert_equal true, registry.bind("s1", "alice")
    assert_equal :full, registry.bind("s2", "alice")
    registry.forget("s1")
    assert_equal true, registry.bind("s2", "alice")
  end

  def test_shared_master_key_principal_is_not_capped_per_principal
    registry = Parse::Agent::MCPRackApp::SessionOwnerRegistry.new(max_entries: 50, max_per_principal: 2)
    5.times { |i| assert_equal true, registry.bind("s#{i}", "mk") }
    assert_equal 5, registry.size
  end

  def test_an_owners_requests_keep_its_session_from_eviction
    registry = Parse::Agent::MCPRackApp::SessionOwnerRegistry.new(max_entries: 50, max_per_principal: 2)
    registry.bind("old", "alice")
    registry.bind("mid", "alice")
    registry.owned_by?("old", "alice") # an ordinary request on "old"
    registry.bind("new", "alice")
    assert registry.owned_by?("old", "alice"), "the recently used session survives"
    refute registry.owned_by?("mid", "alice"), "the idle one is evicted"
  end

  # A stream body closed before Rack iterates it never attached, so it must
  # not detach the session's active stream.
  def test_unattached_stream_close_leaves_the_active_listener
    manager = Parse::Agent::MCPSubscriptions::Manager.new(live_query_client: Object.new)
    active = Parse::Agent::MCPRackApp::ListeningStreamBody.new(manager, "S", 0, nil)
    reader = Thread.new { active.each { |_c| } }
    deadline = Time.now + 1
    sleep 0.01 until manager.listener?("S") || Time.now > deadline
    assert manager.listener?("S")

    aborted = Parse::Agent::MCPRackApp::ListeningStreamBody.new(manager, "S", 0, nil)
    aborted.close
    assert manager.listener?("S"), "the aborted replacement did not detach the active stream"

    active.close
    reader.join(1)
    refute manager.listener?("S")
  end

  # A close that wins the race with the attach leaves nothing registered.
  def test_close_before_attach_registers_no_listener
    manager = Parse::Agent::MCPSubscriptions::Manager.new(live_query_client: Object.new)
    body = Parse::Agent::MCPRackApp::ListeningStreamBody.new(manager, "S2", 0, nil)
    body.close
    body.each { |_c| }
    refute manager.listener?("S2")
  end

end
