# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"
require "parse/agent/mcp_rack_app"
require "json"
require "stringio"

# Deployment-pattern factories: MCPRackApp.user_scoped and
# MCPRackApp.master_analytics. Covers identity rejection, the no-fallback and
# resolver-required rules, option pinning, cross-caller isolation of streams,
# approvals, and cancellations, and the documented revocation intervals.
class MCPDeploymentsTest < Minitest::Test
  App = Parse::Agent::MCPRackApp

  # ---- doubles ------------------------------------------------------------

  Resp = Struct.new(:result, :failed) do
    def error? = failed
  end

  # A Parse::Client double: `/users/me` answers from a mutable token table, and
  # every call is counted so tests can tell a cached validation from a live one.
  class FakeClient
    attr_accessor :master_key
    attr_reader :tokens, :me_calls, :authorization

    # Tokens may be passed as a positional Hash or brace-less (`"tok" => "uid"`),
    # which Ruby delivers as keywords.
    def initialize(tokens = {}, master_key: nil, **more)
      @tokens = tokens.merge(more.transform_keys(&:to_s))
      @master_key = master_key
      @me_calls = 0
      @authorization = FakeAuthorization.new
    end

    def current_user(token, cache: nil)
      @me_calls += 1
      user_id = @tokens[token]
      user_id ? Resp.new({ "objectId" => user_id }, false) : Resp.new(nil, true)
    end

    def authorization=(ctx)
      @authorization = ctx
    end
  end

  class FakeAuthorization
    attr_reader :invalidated

    def initialize = @invalidated = []
    def invalidate(token) = @invalidated << token
  end

  # Stands in for Parse::Agent: records its constructor options and exposes the
  # identity surface the rack app reads.
  class AgentDouble
    attr_accessor :correlation_id, :tenant_id
    attr_reader :options, :session_token, :acl_user_scope, :acl_role_scope, :client

    def initialize(**options)
      @options = options
      @session_token = options[:session_token]
      @tenant_id = options[:tenant_id]
      @client = options[:client]
    end

    def permissions = @options[:permissions]
    def tool_definitions(**) = []
  end

  # Process-local cache with an injectable clock, matching the
  # Parse::Authorization cache contract (get / set(ttl:) / invalidate / clear).
  class ClockCache
    attr_accessor :now

    def initialize(now = 0.0)
      @now = now
      @data = {}
    end

    def get(key)
      entry = @data[key]
      return nil if entry.nil?
      return @data.delete(key) && nil if @now >= entry[:expires_at]
      entry[:value]
    end

    def set(key, value, ttl:) = @data[key] = { value: value, expires_at: @now + ttl }
    def invalidate(key) = @data.delete(key)
    def clear = @data.clear
  end

  def setup
    @built = []
  end

  def with_agent_double(&block)
    built = @built
    Parse::Agent.stub(:new, ->(**kw) { AgentDouble.new(**kw).tap { |a| built << a } }, &block)
  end

  def post(app, method, params: {}, session_id: nil, headers: {}, id: 1, body: nil)
    payload = body || { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json",
      "rack.input" => StringIO.new(JSON.generate(payload)),
    }
    env["HTTP_MCP_SESSION_ID"] = session_id if session_id
    env.merge!(headers)
    status, _h, resp = app.call(env)
    [status, resp]
  end

  def get_stream(app, session_id:, headers: {})
    env = {
      "REQUEST_METHOD" => "GET",
      "HTTP_ACCEPT" => "text/event-stream",
      "HTTP_MCP_SESSION_ID" => session_id,
      "rack.input" => StringIO.new(""),
    }.merge(headers)
    app.call(env)
  end

  def bearer(token) = { "HTTP_AUTHORIZATION" => "Bearer #{token}" }

  def user_app(client, **opts)
    App.user_scoped(client: client, notifications: true, **opts)
  end

  # ---- user_scoped: identity -----------------------------------------------

  def test_user_scoped_rejects_missing_and_blank_tokens_before_building_an_agent
    client = FakeClient.new("tok-a" => "u_a")
    app = user_app(client)
    with_agent_double do
      assert_equal 401, post(app, "tools/list").first
      assert_equal 401, post(app, "tools/list", headers: bearer("   ")).first
    end
    assert_empty @built, "no agent may be built without a session token"
    assert_equal 0, client.me_calls
  end

  def test_user_scoped_rejects_invalid_token_and_evicts_it_from_the_identity_cache
    client = FakeClient.new("tok-a" => "u_a")
    app = user_app(client)
    with_agent_double do
      assert_equal 401, post(app, "tools/list", headers: bearer("forged")).first
    end
    assert_empty @built
    assert_equal ["forged"], client.authorization.invalidated
  end

  def test_user_scoped_builds_a_session_agent_with_no_master_fallback
    client = FakeClient.new({ "tok-a" => "u_a" }, master_key: "mk")
    app = user_app(client, permissions: :write, agent_options: { classes: %w[Post] })
    with_agent_double do
      status, = post(app, "initialize", headers: bearer("tok-a"))
      assert_equal 200, status
    end
    agent = @built.last
    assert_equal "tok-a", agent.session_token
    assert_equal :write, agent.permissions
    assert_equal %w[Post], agent.options[:classes], "agent_options pass through"
    refute agent.options.key?(:acl_user)
    refute agent.options.key?(:acl_role)
  end

  def test_user_scoped_reads_x_parse_session_token_and_custom_extractors
    client = FakeClient.new("tok-a" => "u_a")
    with_agent_double do
      assert_equal 200, post(user_app(client), "initialize", headers: { "HTTP_X_PARSE_SESSION_TOKEN" => "tok-a" }).first
      custom = user_app(client, session_token_from: ->(env) { env["HTTP_X_APP_TOKEN"] })
      assert_equal 200, post(custom, "initialize", headers: { "HTTP_X_APP_TOKEN" => "tok-a" }).first
      assert_equal 401, post(custom, "initialize", headers: bearer("tok-a")).first
    end
  end

  def test_user_scoped_pins_tenant_server_side_and_fails_closed_without_one
    client = FakeClient.new("tok-a" => "u_a", "tok-b" => "u_b")
    app = user_app(client, tenant_from: ->(_env, user_id) { user_id == "u_a" ? "Workspace$w1" : nil })
    with_agent_double do
      assert_equal 200, post(app, "initialize", headers: bearer("tok-a")).first
      assert_equal "Workspace$w1", @built.last.tenant_id
      assert_equal 401, post(app, "initialize", headers: bearer("tok-b")).first
    end
  end

  def test_user_scoped_refuses_factory_owned_options
    client = FakeClient.new
    %i[session_token acl_user acl_role tenant_id client permissions impersonate_user].each do |key|
      assert_raises(ArgumentError, key.to_s) { App.user_scoped(client: client, agent_options: { key => "x" }) }
    end
    assert_raises(ArgumentError) { App.user_scoped(client: client, agent_factory: ->(_e) { nil }) }
    assert_raises(ArgumentError) { App.user_scoped(client: client, principal_resolver: ->(*) { "x" }) }
    assert_raises(ArgumentError) { App.user_scoped(client: client) { |_e| nil } }
    assert_raises(ArgumentError) { App.user_scoped(client: client, session_validation: :sometimes) }
  end

  # ---- master_analytics ----------------------------------------------------

  def analytics_app(client = FakeClient.new({}, master_key: "mk"), **opts)
    App.master_analytics(client: client, notifications: true,
                         principal_resolver: ->(_agent, env) { env["HTTP_X_OPERATOR"] }, **opts)
  end

  def op(name) = { "HTTP_X_OPERATOR" => name }

  def test_master_analytics_requires_a_principal_resolver_at_construction
    err = assert_raises(ArgumentError) { App.master_analytics(client: FakeClient.new({}, master_key: "mk")) }
    assert_match(/principal_resolver/, err.message)
    assert_raises(ArgumentError) { App.master_analytics(principal_resolver: "not callable") }
  end

  def test_master_analytics_refuses_unidentified_operators
    with_agent_double do
      assert_equal 401, post(analytics_app, "tools/list").first
      assert_equal 401, post(analytics_app, "tools/list", headers: op("  ")).first
    end
  end

  def test_master_analytics_is_read_only_by_default_and_needs_a_master_key
    with_agent_double do
      assert_equal 200, post(analytics_app, "initialize", headers: op("ops-1")).first
      assert_equal :readonly, @built.last.permissions
      no_master = analytics_app(FakeClient.new({}, master_key: nil))
      assert_equal 401, post(no_master, "initialize", headers: op("ops-1")).first
    end
  end

  def test_master_analytics_refuses_identity_options
    assert_raises(ArgumentError) { analytics_app(agent_options: { session_token: "t" }) }
    assert_raises(ArgumentError) { analytics_app(agent_options: { acl_role: "Admin" }) }
  end

  def test_master_analytics_resolves_the_principal_once_per_request
    calls = 0
    resolver = ->(_agent, env) { calls += 1; env["HTTP_X_OPERATOR"] }
    app = App.master_analytics(client: FakeClient.new({}, master_key: "mk"), notifications: true,
                               principal_resolver: resolver)
    with_agent_double { post(app, "initialize", session_id: "s1", headers: op("ops-1")) }
    assert_equal 1, calls
  end

  def test_user_scoped_refuses_elevating_agent_options
    client = FakeClient.new({ "tok-a" => "u_a" }, master_key: "mk")
    %i[master_atlas allow_mutations].each do |opt|
      err = assert_raises(ArgumentError) { user_app(client, agent_options: { opt => true }) }
      assert_match(/#{opt}/, err.message)
    end
  end

  # ---- per-principal rate limiting ------------------------------------------

  def test_user_scoped_shares_one_limiter_per_user_across_requests
    client = FakeClient.new({ "tok-a" => "u_a", "tok-a2" => "u_a", "tok-b" => "u_b" }, master_key: "mk")
    app = user_app(client, agent_options: { rate_limit: 1 })
    with_agent_double do
      post(app, "tools/list", headers: bearer("tok-a"))
      post(app, "tools/list", headers: bearer("tok-a2"))
      post(app, "tools/list", headers: bearer("tok-b"))
    end
    a1, a2, b = @built.map { |agent| agent.options[:rate_limiter] }
    assert_same a1, a2, "two requests (even two sessions) from one user share a limiter"
    refute_same a1, b, "different users get different limiters"
    assert_equal 1, a1.instance_variable_get(:@limit)
  end

  def test_shared_limiter_actually_limits_across_requests
    limiter = App::PrincipalRateLimiters.new(limit: 1, window: 60).fetch("user:u_a")
    limiter.check!
    assert_raises(Parse::Agent::RateLimitExceeded) do
      App::PrincipalRateLimiters.new(limit: 1, window: 60) # a new registry is a new window...
      limiter.check!                                       # ...but the shared limiter is not reset
    end
  end

  def test_injected_rate_limiter_is_honored
    injected = Object.new
    def injected.check! = nil
    client = FakeClient.new({ "tok-a" => "u_a" }, master_key: "mk")
    app = user_app(client, agent_options: { rate_limiter: injected })
    with_agent_double { post(app, "tools/list", headers: bearer("tok-a")) }
    assert_same injected, @built.last.options[:rate_limiter]
  end

  def test_master_analytics_shares_one_limiter_per_operator
    app = analytics_app
    with_agent_double do
      post(app, "tools/list", headers: op("ops-1"))
      post(app, "tools/list", headers: op("ops-1"))
      post(app, "tools/list", headers: op("ops-2"))
    end
    limiters = @built.map { |agent| agent.options[:rate_limiter] }.compact
    assert_equal 3, limiters.size
    assert_same limiters[0], limiters[1]
    refute_same limiters[0], limiters[2]
  end

  def test_principal_limiter_registry_is_bounded
    reg = App::PrincipalRateLimiters.new(limit: 5, window: 60, max_entries: 2)
    first = reg.fetch("a")
    reg.fetch("b")
    reg.fetch("c")
    assert_equal 2, reg.size
    refute_same first, reg.fetch("a"), "the least recently used principal was evicted"
  end

  # ---- cross-caller isolation, both factories --------------------------------

  def isolation_cases
    users = FakeClient.new({ "tok-a" => "u_a", "tok-b" => "u_b" }, master_key: "mk")
    [
      [user_app(users), bearer("tok-a"), bearer("tok-b")],
      [analytics_app, op("ops-alice"), op("ops-bob")],
    ]
  end

  def test_second_caller_cannot_attach_to_or_reinitialize_anothers_session
    isolation_cases.each do |app, alice, bob|
      with_agent_double do
        assert_equal 200, post(app, "initialize", session_id: "S", headers: alice).first
        assert_equal 403, post(app, "initialize", session_id: "S", headers: bob).first
        status, = get_stream(app, session_id: "S", headers: bob)
        assert_equal 403, status
        status, _h, body = get_stream(app, session_id: "S", headers: alice)
        assert_equal 200, status
        body.close
      end
    end
  end

  def test_second_caller_cannot_cancel_anothers_requests
    isolation_cases.each do |app, alice, bob|
      token = Parse::Agent::CancellationToken.new
      app.instance_variable_get(:@cancellation_registry).register("S", 7, token)
      with_agent_double do
        post(app, "initialize", session_id: "S", headers: alice)
        cancel = { "jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => { "requestId" => 7 } }
        assert_equal 202, post(app, nil, session_id: "S", headers: bob, body: cancel).first
        refute token.cancelled?, "another principal must not cancel this session's request"
        assert_equal 202, post(app, nil, session_id: "S", headers: alice, body: cancel).first
        assert token.cancelled?
      end
    end
  end

  def test_second_caller_cannot_answer_anothers_approval
    isolation_cases.each do |app, alice, bob|
      queue = app.instance_variable_get(:@pending_elicitations).register("S", "elic-1")
      with_agent_double do
        post(app, "initialize", session_id: "S", headers: alice)
        reply = { "jsonrpc" => "2.0", "id" => "elic-1", "result" => { "action" => "accept" } }
        assert_equal 202, post(app, nil, session_id: "S", headers: bob, body: reply).first
        assert_nil queue.pop(timeout: 0.05), "another principal must not answer this session's approval"
        post(app, nil, session_id: "S", headers: alice, body: reply)
        assert_equal :accept, queue.pop(timeout: 1)
      end
    end
  end

  # ---- revocation intervals ---------------------------------------------------

  # per_request (default): revocation, logout, and expiry are all "Parse Server
  # no longer resolves the token", and take effect on the very next request.
  def test_per_request_validation_refuses_a_revoked_session_on_the_next_request
    client = FakeClient.new("tok-a" => "u_a")
    app = user_app(client)
    with_agent_double do
      assert_equal 200, post(app, "initialize", headers: bearer("tok-a")).first
      client.tokens.delete("tok-a") # logout / revocation / expiry
      assert_equal 401, post(app, "tools/list", headers: bearer("tok-a")).first
    end
    assert_includes client.authorization.invalidated, "tok-a",
                    "mongo-direct identity cache must drop the revoked token too"
  end

  def cached_context(client, cache, ttl: Parse::Authorization::Context::DEFAULT_IDENTITY_TTL)
    ctx = Parse::Authorization::Context.new(client: client)
    ctx.configure(identity_cache: cache, role_cache: ClockCache.new, identity_cache_ttl: ttl)
    ctx.define_singleton_method(:lookup_role_names) { |_uid| Set.new }
    ctx
  end

  # cached: a revoked token keeps validating until the identity-cache TTL
  # elapses, unless an invalidation hook evicts it first.
  def test_cached_validation_honors_the_identity_ttl_bound
    client = FakeClient.new("tok-a" => "u_a")
    cache = ClockCache.new
    client.authorization = cached_context(client, cache, ttl: 3600)
    app = user_app(client, session_validation: :cached)
    with_agent_double do
      assert_equal 200, post(app, "initialize", headers: bearer("tok-a")).first
      client.tokens.delete("tok-a")
      cache.now = 3599
      assert_equal 200, post(app, "tools/list", headers: bearer("tok-a")).first, "still inside the TTL"
      cache.now = 3600
      assert_equal 401, post(app, "tools/list", headers: bearer("tok-a")).first, "refused once the TTL elapses"
    end
  end

  def test_cached_validation_refuses_immediately_when_invalidation_fires
    client = FakeClient.new("tok-a" => "u_a")
    cache = ClockCache.new
    client.authorization = cached_context(client, cache)
    app = user_app(client, session_validation: :cached)
    with_agent_double do
      assert_equal 200, post(app, "initialize", headers: bearer("tok-a")).first
      client.tokens.delete("tok-a")
      client.authorization.invalidate("tok-a") # what the after_logout hook does
      assert_equal 401, post(app, "tools/list", headers: bearer("tok-a")).first
    end
  end

  # Role changes reach mongo-direct ACL resolution within the role-cache TTL,
  # or immediately when the _Role invalidation hook evicts the closure.
  def test_role_closure_bound_is_the_role_cache_ttl_or_invalidation
    client = FakeClient.new
    roles = ClockCache.new
    ctx = Parse::Authorization::Context.new(client: client)
    ctx.configure(identity_cache: ClockCache.new, role_cache: roles,
                  role_cache_ttl: Parse::Authorization::Context::DEFAULT_ROLE_TTL)
    current = Set["Editor"]
    ctx.define_singleton_method(:lookup_role_names) do |uid|
      cached = roles.get(uid)
      next cached if cached
      current.dup.tap { |names| roles.set(uid, names, ttl: role_cache_ttl) }
    end

    assert_equal Set["Editor"], ctx.resolve_user("u_a").role_names
    current = Set[] # role removed
    roles.now = Parse::Authorization::Context::DEFAULT_ROLE_TTL - 1
    assert_equal Set["Editor"], ctx.resolve_user("u_a").role_names, "stale within the role TTL"
    roles.now = Parse::Authorization::Context::DEFAULT_ROLE_TTL
    assert_equal Set[], ctx.resolve_user("u_a").role_names, "fresh once the role TTL elapses"

    current = Set["Admin"]
    ctx.invalidate_user_roles("u_a")
    assert_equal Set["Admin"], ctx.resolve_user("u_a").role_names, "immediate on invalidation"
  end

  # An open listening stream is re-checked on a timer and closed (tearing down
  # its subscriptions) once the session no longer validates.
  def test_listening_stream_closes_within_the_revalidation_interval
    detached = Queue.new
    manager = Object.new
    manager.define_singleton_method(:attach_listener) { |_sid, &_cb| nil }
    manager.define_singleton_method(:detach_listener) { |sid| detached << sid }
    valid = true
    body = App::ListeningStreamBody.new(manager, "S", 0, nil,
                                        revalidate: -> { valid }, revalidate_interval: 0.05)
    reader = Thread.new { chunks = []; body.each { |c| chunks << c }; chunks }
    sleep 0.15
    assert reader.alive?, "stream stays open while the session validates"
    valid = false
    assert_equal "S", detached.pop(timeout: 1), "stream must close once revalidation fails"
    assert_includes reader.value, ": connected\n\n"
  end

  def test_stream_closed_during_first_frame_starts_no_revalidation
    manager = Object.new
    manager.define_singleton_method(:attach_listener) { |_sid, &_cb| nil }
    manager.define_singleton_method(:detach_listener) { |_sid| nil }
    checks = 0
    body = App::ListeningStreamBody.new(manager, "S", 0.01, nil,
                                        revalidate: -> { checks += 1; true }, revalidate_interval: 0.01)
    # The client disconnects while the initial frame is being written.
    body.each { |_chunk| body.close }
    sleep 0.1
    assert_equal 0, checks, "no revalidation may run after the stream closed"
    assert_nil body.instance_variable_get(:@revalidator_thread)
    assert_nil body.instance_variable_get(:@heartbeat)
  end

  def test_user_scoped_installs_listening_stream_revalidation
    client = FakeClient.new("tok-a" => "u_a")
    app = user_app(client, session_revalidate_interval: 5)
    assert_equal 5, app.instance_variable_get(:@listening_stream_revalidate_interval)
    revalidator = app.instance_variable_get(:@listening_stream_revalidator)
    agent = AgentDouble.new(session_token: "tok-a")
    assert revalidator.call(agent)
    client.tokens.delete("tok-a")
    refute revalidator.call(agent)
  end
end
