# encoding: UTF-8
# frozen_string_literal: true

require "stringio"
require "json"
require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_dispatcher"
require_relative "../../../../lib/parse/agent/mcp_subscriptions"
require_relative "../../../../lib/parse/agent/mcp_rack_app"
require_relative "../../../../lib/parse/agent/mcp_server"

# A blank master key on the agent's client counts as no master key. The HTTP
# authentication middleware never sends a blank key, so an agent that treated
# "" or "   " as present ran in master-key posture with no master-key authority
# and skipped the client-mode and acl_user:/acl_role: refusals.
class Security584BlankMasterKeyTest < Minitest::Test
  def blank_client(key)
    Parse::Client.new(server_url: "http://localhost:1/parse", application_id: "blank-mk-app",
                      api_key: "rest-key", master_key: key)
  end

  def test_blank_master_key_with_session_token_is_client_mode
    ["", "   "].each do |key|
      agent = Parse::Agent.new(session_token: "r:blank-mk", client: blank_client(key))
      assert agent.client_mode?, "master_key #{key.inspect} should be treated as absent"
    end
  end

  def test_blank_master_key_refuses_acl_user_and_acl_role
    ["", "   "].each do |key|
      assert_raises(ArgumentError) do
        Parse::Agent.new(acl_user: Parse::User.pointer("abc1234567"), client: blank_client(key))
      end
      assert_raises(ArgumentError) do
        Parse::Agent.new(acl_role: "Admin", client: blank_client(key))
      end
    end
  end

  def test_blank_master_key_refuses_impersonation
    agent = Parse::Agent.new(client: blank_client("  "))
    err = assert_raises(ArgumentError) { agent.impersonate("user123") }
    assert_match(/master_key/, err.message)
  end

  def test_real_master_key_is_not_client_mode
    agent = Parse::Agent.new(session_token: "r:real-mk", client: blank_client("real-master-key"))
    refute agent.client_mode?
  end
end

# MCP resource subscriptions apply the agent's tenant scope and per-agent
# filter as the LiveQuery `where`, so change events only fire for rows the
# agent may read.
class Security584SubscriptionScopingTest < Minitest::Test
  M = Parse::Agent::MCPSubscriptions
  Reg = Parse::Agent::MetadataRegistry
  SCOPED_CLASS = "Sec584ScopedPost"

  class RecordingSub
    def on(_event)
      self
    end

    def unsubscribe; end
  end

  class RecordingClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def subscribe(class_name, **opts)
      @calls << [class_name, opts]
      RecordingSub.new
    end
  end

  class StubAgent
    attr_accessor :correlation_id
    attr_reader :session_token, :acl_user_scope, :acl_role_scope, :acl_scope, :client, :tenant_id

    def initialize(tenant_id: nil, filters: {})
      @session_token = "r:sub-tok"
      @client = Struct.new(:master_key).new(nil)
      @tenant_id = tenant_id
      @filters = filters
    end

    def class_filter_permits?(_class_name)
      true
    end

    def filter_for(class_name)
      @filters[class_name]
    end
  end

  def setup
    @lq = RecordingClient.new
    @mgr = M::Manager.new(supported: true, debounce_interval: 0, live_query_client: @lq)
  end

  def teardown
    rules = Reg.instance_variable_get(:@tenant_scope_rules)
    rules&.delete(SCOPED_CLASS)
  end

  def test_unscoped_agent_subscribes_without_where
    @mgr.subscribe(session_id: "s1", uri: "parse://Post/count", agent: StubAgent.new)
    _cls, opts = @lq.calls.last
    refute opts.key?(:where)
  end

  def test_tenant_scope_becomes_subscription_where
    Reg.register_tenant_scope(SCOPED_CLASS, :workspace_id, from: ->(a) { a.tenant_id })
    @mgr.subscribe(session_id: "s1", uri: "parse://#{SCOPED_CLASS}/count",
                   agent: StubAgent.new(tenant_id: "ws1"))
    cls, opts = @lq.calls.last
    assert_equal SCOPED_CLASS, cls
    assert_equal({ "workspaceId" => "ws1" }, opts[:where])
    assert_equal "r:sub-tok", opts[:session_token]
  end

  def test_tenant_scoped_class_without_binding_refuses_before_subscribing
    Reg.register_tenant_scope(SCOPED_CLASS, :workspace_id, from: ->(a) { a.tenant_id })
    assert_raises(Parse::Agent::AccessDenied) do
      @mgr.subscribe(session_id: "s1", uri: "parse://#{SCOPED_CLASS}/samples",
                     agent: StubAgent.new(tenant_id: nil))
    end
    assert_empty @lq.calls
  end

  def test_per_agent_filter_becomes_subscription_where
    agent = StubAgent.new(filters: { "Post" => { "status" => "published" } })
    @mgr.subscribe(session_id: "s1", uri: "parse://Post/samples", agent: agent)
    _cls, opts = @lq.calls.last
    assert_equal({ "status" => "published" }, opts[:where])
  end

  def test_tenant_scope_and_per_agent_filter_compose
    Reg.register_tenant_scope(SCOPED_CLASS, :workspace_id, from: ->(a) { a.tenant_id })
    agent = StubAgent.new(tenant_id: "ws1", filters: { SCOPED_CLASS => { "status" => "published" } })
    @mgr.subscribe(session_id: "s1", uri: "parse://#{SCOPED_CLASS}/count", agent: agent)
    _cls, opts = @lq.calls.last
    assert_equal({ "$and" => [{ "status" => "published" }, { "workspaceId" => "ws1" }] }, opts[:where])
  end
end

# DNS-rebinding guidance: on a loopback bind the Host header must be a
# loopback host or listed in allowed_hosts:.
class Security584HostHeaderTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app-id", api_key: "test-api-key")
    end
    @original_call = Parse::Agent::MCPDispatcher.method(:call)
    Parse::Agent::MCPDispatcher.define_singleton_method(:call) do |body:, agent:, **_kw|
      { status: 200, body: { "jsonrpc" => "2.0", "id" => body["id"], "result" => {} } }
    end
  end

  def teardown
    original = @original_call
    Parse::Agent::MCPDispatcher.define_singleton_method(:call, &original) if original
  end

  def env_with_host(host)
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new('{"jsonrpc":"2.0","id":1,"method":"ping"}'),
    }
    env["HTTP_HOST"] = host if host
    env
  end

  def build_app(**kwargs)
    Parse::Agent::MCPRackApp.new(agent_factory: ->(_env) { Parse::Agent.new }, **kwargs)
  end

  def test_loopback_bind_refuses_non_loopback_host
    app = build_app(loopback_bind: true)
    status, _h, body = app.call(env_with_host("evil.example:3001"))
    assert_equal 403, status
    assert_includes body.first, "Host not allowed"
  end

  def test_loopback_bind_accepts_loopback_hosts
    app = build_app(loopback_bind: true)
    ["localhost", "localhost:3001", "127.0.0.1:3001", "[::1]:3001", "[::1]", "LOCALHOST:80"].each do |host|
      status, _h, _b = app.call(env_with_host(host))
      assert_equal 200, status, "should accept Host #{host}"
    end
  end

  def test_loopback_bind_allows_missing_host
    app = build_app(loopback_bind: true)
    status, _h, _b = app.call(env_with_host(nil))
    assert_equal 200, status
  end

  def test_loopback_bind_refuses_malformed_host
    app = build_app(loopback_bind: true)
    ["localhost:abc", "local host", "[::1"].each do |host|
      status, _h, _b = app.call(env_with_host(host))
      assert_equal 403, status, "should refuse Host #{host.inspect}"
    end
  end

  def test_loopback_csrf_default_implies_host_check
    app = build_app(loopback_csrf_default: true)
    status, _h, _b = app.call(env_with_host("rebind.example"))
    assert_equal 403, status
  end

  def test_allowed_hosts_extends_loopback_set
    app = build_app(loopback_bind: true, allowed_hosts: ["dev.example.test", "box.example.test:8443"])
    assert_equal 200, app.call(env_with_host("dev.example.test:3001")).first
    assert_equal 200, app.call(env_with_host("box.example.test:8443")).first
    assert_equal 403, app.call(env_with_host("box.example.test:9000")).first
    assert_equal 200, app.call(env_with_host("127.0.0.1:3001")).first
  end

  def test_allowed_hosts_alone_restricts_host
    app = build_app(allowed_hosts: ["mcp.example.test"])
    assert_equal 200, app.call(env_with_host("mcp.example.test")).first
    assert_equal 403, app.call(env_with_host("localhost")).first
  end

  def test_no_bind_flag_and_no_allowlist_means_no_check
    app = build_app
    assert_equal 200, app.call(env_with_host("anything.example")).first
  end

  def test_host_check_guards_delete_and_get
    app = build_app(loopback_bind: true)
    del = { "REQUEST_METHOD" => "DELETE", "HTTP_HOST" => "evil.example", "HTTP_MCP_SESSION_ID" => "abc" }
    assert_equal 403, app.call(del).first
    get = { "REQUEST_METHOD" => "GET", "HTTP_HOST" => "evil.example" }
    assert_equal 403, app.call(get).first
  end

  def test_mcp_server_loopback_bind_enables_host_check
    server = nil
    capture_io { server = Parse::Agent::MCPServer.new(host: "127.0.0.1", port: 0) }
    rack = server.instance_variable_get(:@rack_app)
    assert_equal 403, rack.call(env_with_host("evil.example:3001")).first
    assert_equal 200, rack.call(env_with_host("127.0.0.1:3001")).first
  end

  def test_mcp_server_allowed_hosts_passthrough
    server = nil
    capture_io do
      server = Parse::Agent::MCPServer.new(host: "127.0.0.1", port: 0, allowed_hosts: ["dev.example.test"])
    end
    rack = server.instance_variable_get(:@rack_app)
    assert_equal 200, rack.call(env_with_host("dev.example.test:3001")).first
  end
end
