# encoding: UTF-8
# frozen_string_literal: true

require "stringio"
require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_dispatcher"
require_relative "../../../../lib/parse/agent/mcp_subscriptions"
require_relative "../../../../lib/parse/agent/mcp_rack_app"

# ---------------------------------------------------------------------------
# Test doubles
# ---------------------------------------------------------------------------

# Minimal LiveQuery subscription stub: records callbacks per event, lets the
# test fire them, and tracks unsubscribe.
class FakeLQSubscription
  def initialize
    @callbacks = Hash.new { |h, k| h[k] = [] }
    @unsubscribed = false
  end

  def on(event, &block)
    @callbacks[event] << block
    self
  end

  def fire(event)
    @callbacks[event].each(&:call)
  end

  def unsubscribe
    @unsubscribed = true
  end

  def unsubscribed?
    @unsubscribed
  end
end

# Minimal LiveQuery client stub: records each subscribe(class_name, **creds).
class FakeLQClient
  Subscribe = Struct.new(:class_name, :creds, :subscription)

  attr_reader :subscriptions

  def initialize
    @subscriptions = []
  end

  def subscribe(class_name, **creds)
    sub = FakeLQSubscription.new
    @subscriptions << Subscribe.new(class_name, creds, sub)
    sub
  end

  def last
    @subscriptions.last
  end
end

# Deterministic debounce timer: stores fire blocks instead of sleeping so a
# test can flush them on demand.
class ManualTimer
  attr_reader :pending

  def initialize
    @pending = []
  end

  def call(_interval, &fire)
    @pending << fire
  end

  def fire_all
    fired = @pending.dup
    @pending.clear
    fired.each(&:call)
  end

  def armed_count
    @pending.size
  end
end

# Agent stub exposing the credential/scope and session surface the bridge and
# dispatcher read. Defaults to a master-key posture WITH a real master key on
# its own client — master-key posture requires master-key authority, otherwise
# the bridge refuses to open an admin (ACL-bypassing) LiveQuery socket.
class SubAgentStub
  attr_accessor :progress_callback, :cancellation_token, :correlation_id
  attr_reader :session_token, :acl_user_scope, :acl_role_scope, :acl_scope, :client

  # @param master_key [String, nil] the master key on the agent's OWN client.
  #   Defaults present, so the default no-scope posture is a genuine master-key
  #   agent. Pass nil to model an unprivileged / client-mode agent that must
  #   NOT be able to open an admin LiveQuery socket.
  # @param permitted [Boolean] result of the per-agent `classes:` allowlist
  #   gate (Tools.assert_class_accessible! → class_filter_permits?). Pass false
  #   to model a class outside the agent's allowlist.
  def initialize(correlation_id: "sess-1", session_token: nil,
                 acl_user_scope: nil, acl_role_scope: nil, acl_scope: nil,
                 master_key: "test-master-key", permitted: true)
    @correlation_id = correlation_id
    @session_token  = session_token
    @acl_user_scope = acl_user_scope
    @acl_role_scope = acl_role_scope
    @acl_scope      = acl_scope
    @client         = Struct.new(:master_key).new(master_key)
    @permitted      = permitted
  end

  # Mirrors Parse::Agent#class_filter_permits? — the per-agent `classes:`
  # allowlist gate consulted by Tools.assert_class_accessible!.
  def class_filter_permits?(_class_name)
    @permitted
  end

  def cancelled?
    !!@cancellation_token&.cancelled?
  end
end

# ---------------------------------------------------------------------------
# MCPSubscriptions module-function tests (URI + credential derivation)
# ---------------------------------------------------------------------------
class MCPSubscriptionsHelpersTest < Minitest::Test
  M = Parse::Agent::MCPSubscriptions

  def test_parse_subscribable_uri_count_and_samples
    assert_equal %w[Post count],    M.parse_subscribable_uri("parse://Post/count")
    assert_equal %w[Document samples], M.parse_subscribable_uri("parse://Document/samples")
  end

  def test_parse_subscribable_uri_rejects_schema
    err = assert_raises(Parse::Agent::ValidationError) do
      M.parse_subscribable_uri("parse://Post/schema")
    end
    assert_match(/not subscribable/, err.message)
  end

  def test_parse_subscribable_uri_rejects_malformed
    assert_raises(Parse::Agent::ValidationError) { M.parse_subscribable_uri("nope://Post/count") }
    assert_raises(Parse::Agent::ValidationError) { M.parse_subscribable_uri("parse://Post") }
    assert_raises(Parse::Agent::ValidationError) { M.parse_subscribable_uri("parse://9bad/count") }
  end

  def test_credentials_for_master_key_agent
    agent = SubAgentStub.new
    assert_equal({ use_master_key: true }, M.live_query_credentials_for(agent))
  end

  def test_credentials_master_key_posture_without_master_key_fails_closed
    # No session token, no acl_user/acl_role, no acl_scope — a master-key
    # POSTURE — but the agent's own client carries no master key (client mode /
    # unprivileged). Returning use_master_key: true here would let the bridge
    # open an admin socket using the PROCESS-GLOBAL master key the agent has no
    # authority over. Must fail closed instead of escalating.
    agent = SubAgentStub.new(master_key: nil)
    assert_raises(Parse::Agent::SecurityError) { M.live_query_credentials_for(agent) }
  end

  def test_credentials_master_key_posture_with_blank_master_key_fails_closed
    # A blank/whitespace key is not a usable master key (matches
    # Parse::LiveQuery::Client#admin_connection?), so it must also fail closed.
    agent = SubAgentStub.new(master_key: "   ")
    assert_raises(Parse::Agent::SecurityError) { M.live_query_credentials_for(agent) }
  end

  def test_credentials_for_session_token_agent
    agent = SubAgentStub.new(session_token: "r:abc", acl_scope: Object.new)
    assert_equal({ session_token: "r:abc" }, M.live_query_credentials_for(agent))
  end

  def test_credentials_session_token_takes_precedence_over_scope
    # A session-token posture is authoritative for LiveQuery even if an
    # acl_scope object is present.
    agent = SubAgentStub.new(session_token: "r:abc", acl_scope: Object.new)
    assert_equal({ session_token: "r:abc" }, M.live_query_credentials_for(agent))
  end

  def test_credentials_refuses_acl_user_scope
    agent = SubAgentStub.new(acl_user_scope: Object.new, acl_scope: Object.new)
    assert_raises(Parse::Agent::SecurityError) { M.live_query_credentials_for(agent) }
  end

  def test_credentials_refuses_acl_role_scope
    agent = SubAgentStub.new(acl_role_scope: Object.new, acl_scope: Object.new)
    assert_raises(Parse::Agent::SecurityError) { M.live_query_credentials_for(agent) }
  end

  def test_credentials_refuses_unknown_scoped_posture_fails_closed
    # Non-nil acl_scope with no session token and no acl_user/role mapping:
    # an unrecognized scoped posture must fail closed, never silently
    # downgrade to master key.
    agent = SubAgentStub.new(acl_scope: Object.new)
    assert_raises(Parse::Agent::SecurityError) { M.live_query_credentials_for(agent) }
  end
end

# ---------------------------------------------------------------------------
# Manager flow tests (bridge: subscribe -> event -> debounce -> publish)
# ---------------------------------------------------------------------------
class MCPSubscriptionsManagerTest < Minitest::Test
  M = Parse::Agent::MCPSubscriptions

  def build_manager(interval: 0, timer: nil)
    @lq = FakeLQClient.new
    M::Manager.new(supported: true, live_query_client: @lq,
                   debounce_interval: interval, timer: timer)
  end

  def test_supported_override
    assert build_manager.supported?
  end

  def test_subscribe_creates_live_query_with_master_creds_and_delivers
    mgr = build_manager(interval: 0)
    received = []
    mgr.attach_listener("sess-1") { |n| received << n }
    assert mgr.subscribe(session_id: "sess-1", uri: "parse://Post/count", agent: SubAgentStub.new)

    rec = @lq.last
    assert_equal "Post", rec.class_name
    assert_equal({ use_master_key: true }, rec.creds)
    assert_equal 1, mgr.subscription_count

    rec.subscription.fire(:create)
    assert_equal 1, received.size
    assert_equal "notifications/resources/updated", received.first["method"]
    assert_equal "parse://Post/count", received.first.dig("params", "uri")
  end

  def test_each_live_query_event_kind_triggers_update
    mgr = build_manager(interval: 0)
    received = []
    mgr.attach_listener("sess-1") { |n| received << n }
    mgr.subscribe(session_id: "sess-1", uri: "parse://Post/count", agent: SubAgentStub.new)

    Parse::LiveQuery::EVENTS.each { |ev| @lq.last.subscription.fire(ev) }
    assert_equal Parse::LiveQuery::EVENTS.size, received.size
  end

  def test_subscribe_with_session_token_passes_token_creds
    mgr = build_manager(interval: 0)
    agent = SubAgentStub.new(session_token: "r:tok")
    mgr.subscribe(session_id: "sess-1", uri: "parse://Post/samples", agent: agent)
    assert_equal({ session_token: "r:tok" }, @lq.last.creds)
  end

  def test_routes_master_to_admin_and_session_to_scoped_client
    # Parse Server has no per-subscription master key, so master-posture
    # subscriptions must ride an admin connection and session-token ones a
    # scoped connection. Verify the manager routes by credential.
    admin  = FakeLQClient.new
    scoped = FakeLQClient.new
    mgr = M::Manager.new(supported: true, debounce_interval: 0,
                         live_query_admin_client: admin, live_query_scoped_client: scoped)
    mgr.subscribe(session_id: "s1", uri: "parse://Post/count", agent: SubAgentStub.new)
    mgr.subscribe(session_id: "s1", uri: "parse://Post/samples",
                  agent: SubAgentStub.new(session_token: "r:tok"))

    assert_equal 1, admin.subscriptions.size
    assert_equal({ use_master_key: true }, admin.last.creds)
    assert_equal 1, scoped.subscriptions.size
    assert_equal({ session_token: "r:tok" }, scoped.last.creds)
  end

  def test_subscribe_derives_clp_op_from_uri_verb
    # The subscribe gate mirrors the read path's CLP op: a `count` resource
    # gates on :count, a `samples` resource on :find — so a subscribe is never
    # stricter than the equivalent read. Stub the gate to capture the op.
    captured = []
    fake = ->(class_name, agent:, op:) { captured << [class_name, op] }
    Parse::Agent::Tools.stub(:assert_class_accessible!, fake) do
      mgr = build_manager
      mgr.subscribe(session_id: "s1", uri: "parse://Post/count",   agent: SubAgentStub.new)
      mgr.subscribe(session_id: "s1", uri: "parse://Post/samples", agent: SubAgentStub.new)
    end
    assert_equal [["Post", :count], ["Post", :find]], captured
  end

  def test_scoped_subscription_refused_when_scoped_client_is_admin_connection
    # A global `config.use_master_key = true` makes Parse::LiveQuery.client an
    # admin (ACL-bypassing) socket. A session-token subscription must NOT ride
    # it — the bridge fails closed rather than leak rows the user can't read.
    admin_scoped = Object.new
    def admin_scoped.admin_connection?; true; end
    def admin_scoped.subscribe(*)
      raise "must not open a subscription on an admin scoped client"
    end
    mgr = M::Manager.new(supported: true, debounce_interval: 0, live_query_scoped_client: admin_scoped)
    agent = SubAgentStub.new(session_token: "r:tok")
    assert_raises(Parse::Agent::SecurityError) do
      mgr.subscribe(session_id: "s1", uri: "parse://Post/count", agent: agent)
    end
  end

  def test_subscribe_is_idempotent_per_uri
    mgr = build_manager(interval: 0)
    mgr.attach_listener("sess-1") {}
    mgr.subscribe(session_id: "sess-1", uri: "parse://Post/count", agent: SubAgentStub.new)
    mgr.subscribe(session_id: "sess-1", uri: "parse://Post/count", agent: SubAgentStub.new)
    assert_equal 1, @lq.subscriptions.size
    assert_equal 1, mgr.subscription_count
  end

  def test_subscribe_requires_session_id
    mgr = build_manager
    assert_raises(Parse::Agent::ValidationError) do
      mgr.subscribe(session_id: nil, uri: "parse://Post/count", agent: SubAgentStub.new)
    end
  end

  def test_per_session_subscription_cap
    @lq = FakeLQClient.new
    mgr = M::Manager.new(supported: true, live_query_client: @lq,
                         debounce_interval: 0, max_subscriptions_per_session: 2)
    mgr.subscribe(session_id: "sess-1", uri: "parse://Post/count", agent: SubAgentStub.new)
    mgr.subscribe(session_id: "sess-1", uri: "parse://Post/samples", agent: SubAgentStub.new)
    err = assert_raises(Parse::Agent::ValidationError) do
      mgr.subscribe(session_id: "sess-1", uri: "parse://Document/count", agent: SubAgentStub.new)
    end
    assert_match(/limit reached/, err.message)
    assert_equal 2, @lq.subscriptions.size, "no socket opens for the capped subscribe"
    # A different session is unaffected by another session's cap.
    assert mgr.subscribe(session_id: "sess-2", uri: "parse://Post/count", agent: SubAgentStub.new)
  end

  def test_subscribe_refuses_acl_user_agent_without_opening_socket
    mgr = build_manager
    agent = SubAgentStub.new(acl_user_scope: Object.new, acl_scope: Object.new)
    assert_raises(Parse::Agent::SecurityError) do
      mgr.subscribe(session_id: "sess-1", uri: "parse://Post/count", agent: agent)
    end
    assert_equal 0, @lq.subscriptions.size, "no LiveQuery socket should open on a refused subscribe"
  end

  def test_subscribe_enforces_class_allowlist_before_opening_socket
    # Authorization parity with the read path: a class outside the agent's
    # `classes:` allowlist must be refused at subscribe BEFORE any socket
    # opens, so a hidden/forbidden class can't become a change/timing oracle.
    mgr = build_manager
    agent = SubAgentStub.new(permitted: false)
    assert_raises(Parse::Agent::AccessDenied) do
      mgr.subscribe(session_id: "sess-1", uri: "parse://Post/count", agent: agent)
    end
    assert_equal 0, @lq.subscriptions.size, "no LiveQuery socket should open for a disallowed class"
    assert_equal 0, mgr.subscription_count
  end

  def test_unsubscribe_tears_down_live_query_socket
    mgr = build_manager(interval: 0)
    mgr.subscribe(session_id: "sess-1", uri: "parse://Post/count", agent: SubAgentStub.new)
    sub = @lq.last.subscription
    assert mgr.unsubscribe(session_id: "sess-1", uri: "parse://Post/count")
    assert sub.unsubscribed?
    assert_equal 0, mgr.subscription_count
  end

  def test_unsubscribe_is_idempotent
    mgr = build_manager
    refute mgr.unsubscribe(session_id: "sess-1", uri: "parse://Post/count")
  end

  def test_detach_listener_tears_down_all_session_subscriptions
    mgr = build_manager(interval: 0)
    mgr.attach_listener("sess-1") {}
    mgr.subscribe(session_id: "sess-1", uri: "parse://Post/count", agent: SubAgentStub.new)
    mgr.subscribe(session_id: "sess-1", uri: "parse://Post/samples", agent: SubAgentStub.new)
    subs = @lq.subscriptions.map(&:subscription)

    count = mgr.detach_listener("sess-1")
    assert_equal 2, count
    assert subs.all?(&:unsubscribed?)
    assert_equal 0, mgr.subscription_count
    refute mgr.listener?("sess-1")
  end

  def test_publish_after_detach_is_dropped
    mgr = build_manager(interval: 0)
    received = []
    mgr.attach_listener("sess-1") { |n| received << n }
    mgr.subscribe(session_id: "sess-1", uri: "parse://Post/count", agent: SubAgentStub.new)
    sub = @lq.last.subscription
    mgr.detach_listener("sess-1")

    # Firing the (now torn-down) subscription must not deliver anything.
    sub.fire(:create)
    assert_empty received
  end

  def test_debounce_coalesces_burst_into_single_update
    timer = ManualTimer.new
    mgr = build_manager(interval: 0.25, timer: timer)
    received = []
    mgr.attach_listener("sess-1") { |n| received << n }
    mgr.subscribe(session_id: "sess-1", uri: "parse://Post/count", agent: SubAgentStub.new)
    sub = @lq.last.subscription

    # Burst of events within one debounce window arms the timer once.
    sub.fire(:create)
    sub.fire(:update)
    sub.fire(:create)
    assert_equal 1, timer.armed_count
    assert_empty received, "no delivery until the debounce window fires"

    timer.fire_all
    assert_equal 1, received.size, "burst collapses to a single update"

    # A new event after the window rearms and fires again.
    sub.fire(:update)
    assert_equal 1, timer.armed_count
    timer.fire_all
    assert_equal 2, received.size
  end
end

# ---------------------------------------------------------------------------
# Dispatcher integration: capability negotiation + subscribe/unsubscribe routing
# ---------------------------------------------------------------------------
class MCPSubscriptionsDispatcherTest < Minitest::Test
  D = Parse::Agent::MCPDispatcher
  M = Parse::Agent::MCPSubscriptions

  def setup
    # In a combined run, mcp_rack_app_test.rb / mcp_streaming_test.rb install a
    # singleton stub on MCPDispatcher.call (restored only at process exit).
    # Restore the real implementation so these dispatcher tests exercise the
    # real routing, then RE-INSTALL in teardown so the stub's owner class still
    # sees it if it runs after us — mirroring mcp_dispatcher_test.rb's guard.
    @mcp_stub_was_active = defined?(MCPDispatcherStub) &&
                           MCPDispatcherStub.instance_variable_get(:@original_call)
    MCPDispatcherStub.restore! if @mcp_stub_was_active

    @streaming_stub_was_active = defined?(StreamingDispatcherStub) &&
                                 StreamingDispatcherStub.instance_variable_get(:@original)
    StreamingDispatcherStub.restore! if @streaming_stub_was_active

    @lq = FakeLQClient.new
    @manager = M::Manager.new(supported: true, live_query_client: @lq, debounce_interval: 0)
    @agent = SubAgentStub.new(correlation_id: "sess-1")
  end

  def teardown
    # Re-install each stub if it was active before setup, so the stub's owner
    # test class still sees it if it runs after us in the same process.
    MCPDispatcherStub.install!       if @mcp_stub_was_active && defined?(MCPDispatcherStub)
    StreamingDispatcherStub.install! if @streaming_stub_was_active && defined?(StreamingDispatcherStub)
  end

  def init_caps(manager)
    body = { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
             "params" => { "protocolVersion" => "2025-06-18" } }
    res = D.call(body: body, agent: @agent, subscription_manager: manager)
    res[:body]["result"]["capabilities"]["resources"]
  end

  def test_capability_subscribe_false_without_manager
    assert_equal false, init_caps(nil)["subscribe"]
  end

  def test_capability_subscribe_true_with_supported_manager
    assert_equal true, init_caps(@manager)["subscribe"]
  end

  def test_capability_subscribe_false_when_manager_unsupported
    unsupported = M::Manager.new(supported: false, live_query_client: @lq)
    assert_equal false, init_caps(unsupported)["subscribe"]
  end

  def test_base_capabilities_constant_unmutated
    init_caps(@manager)
    assert_equal false, D::CAPABILITIES["resources"]["subscribe"]
  end

  def call_method(method, params, manager: @manager)
    body = { "jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params }
    D.call(body: body, agent: @agent, subscription_manager: manager)
  end

  def test_resources_subscribe_success_returns_empty_result
    res = call_method("resources/subscribe", { "uri" => "parse://Post/count" })
    assert_equal 200, res[:status]
    assert_equal({}, res[:body]["result"])
    assert_equal 1, @manager.subscription_count
    assert_equal "Post", @lq.last.class_name
  end

  def test_resources_unsubscribe_success_returns_empty_result
    call_method("resources/subscribe", { "uri" => "parse://Post/count" })
    res = call_method("resources/unsubscribe", { "uri" => "parse://Post/count" })
    assert_equal({}, res[:body]["result"])
    assert_equal 0, @manager.subscription_count
  end

  def test_resources_subscribe_bad_uri_is_invalid_params
    res = call_method("resources/subscribe", { "uri" => "parse://Post/schema" })
    assert_equal(-32_602, res[:body]["error"]["code"])
  end

  def test_resources_subscribe_acl_user_agent_is_invalid_params
    @agent = SubAgentStub.new(correlation_id: "sess-1", acl_user_scope: Object.new, acl_scope: Object.new)
    res = call_method("resources/subscribe", { "uri" => "parse://Post/count" })
    assert_equal(-32_602, res[:body]["error"]["code"])
    assert_equal 0, @manager.subscription_count
  end

  def test_resources_subscribe_disallowed_class_is_invalid_params
    # A class outside the agent's `classes:` allowlist must be refused through
    # the REAL dispatcher with JSON-RPC -32602 (AccessDenied → -32602), opening
    # no socket. Locks the dispatcher's AccessDenied rescue mapping — the
    # Manager-level test asserts the raise, this asserts the wire error code.
    @agent = SubAgentStub.new(correlation_id: "sess-1", permitted: false)
    res = call_method("resources/subscribe", { "uri" => "parse://Post/count" })
    assert_equal(-32_602, res[:body]["error"]["code"])
    assert_equal 0, @manager.subscription_count
    assert_equal 0, @lq.subscriptions.size
  end

  def test_resources_subscribe_without_manager_is_method_not_found
    res = call_method("resources/subscribe", { "uri" => "parse://Post/count" }, manager: nil)
    assert_equal(-32_601, res[:body]["error"]["code"])
  end

  def test_subscribe_then_event_delivers_to_attached_listener
    received = []
    @manager.attach_listener("sess-1") { |n| received << n }
    call_method("resources/subscribe", { "uri" => "parse://Post/count" })
    @lq.last.subscription.fire(:update)
    assert_equal 1, received.size
    assert_equal "parse://Post/count", received.first.dig("params", "uri")
  end
end

# ---------------------------------------------------------------------------
# MCPRackApp GET listening stream (transport-level)
# ---------------------------------------------------------------------------
class MCPListeningStreamRackTest < Minitest::Test
  M    = Parse::Agent::MCPSubscriptions
  Body = Parse::Agent::MCPRackApp::ListeningStreamBody

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app-id", api_key: "test-api-key")
    end
    @lq = FakeLQClient.new
    @manager = M::Manager.new(supported: true, live_query_client: @lq, debounce_interval: 0)
  end

  def build_app(manager: @manager, factory: ->(_env) { SubAgentStub.new })
    Parse::Agent::MCPRackApp.new(subscription_manager: manager, &factory)
  end

  def get_env(session_id: "sess-1", accept: "text/event-stream", origin: nil)
    env = {
      "REQUEST_METHOD"      => "GET",
      "HTTP_ACCEPT"         => accept,
      "HTTP_MCP_SESSION_ID" => session_id,
      "rack.input"          => StringIO.new(""),
    }
    env["HTTP_ORIGIN"] = origin if origin
    env
  end

  def pop_with_timeout(queue, timeout: 2)
    deadline = Time.now + timeout
    loop do
      return queue.pop(true)
    rescue ThreadError
      raise "timed out waiting for SSE chunk" if Time.now > deadline
      sleep 0.01
    end
  end

  def test_get_opens_listening_stream
    status, headers, body = build_app.call(get_env)
    assert_equal 200, status
    assert_equal "text/event-stream", headers["Content-Type"]
    assert_instance_of Body, body
    body.close
  end

  def test_get_missing_session_id_is_400
    status, = build_app.call(get_env(session_id: ""))
    assert_equal 400, status
  end

  def test_get_unauthorized_factory_is_401
    app = build_app(factory: ->(_env) { raise Parse::Agent::Unauthorized, "no token" })
    status, = app.call(get_env)
    assert_equal 401, status
  end

  def test_get_without_manager_falls_through_to_405
    app = Parse::Agent::MCPRackApp.new { |_env| SubAgentStub.new }
    status, = app.call(get_env)
    assert_equal 405, status
  end

  def test_listening_body_delivers_published_update_then_tears_down_on_close
    body   = Body.new(@manager, "sess-1", 0, nil)
    chunks = Queue.new
    worker = Thread.new { body.each { |c| chunks << c } }

    # First chunk flushes headers and confirms the stream is live.
    assert_equal ": connected\n\n", pop_with_timeout(chunks)

    @manager.subscribe(session_id: "sess-1", uri: "parse://Post/count", agent: SubAgentStub.new)
    sub = @lq.last.subscription
    sub.fire(:create)

    event = pop_with_timeout(chunks)
    assert_includes event, "event: message"
    assert_includes event, "notifications/resources/updated"
    assert_includes event, "parse://Post/count"

    body.close
    worker.join(2)
    assert sub.unsubscribed?, "close must tear down the session's LiveQuery subscription"
    assert_equal 0, @manager.subscription_count
  end
end
