require_relative "../../test_helper_integration"
require_relative "../../support/webhook_test_server"
require "securerandom"

# End-to-end integration coverage for "run as the calling user" via the session
# token Parse Server embeds in webhook trigger payloads (`user.sessionToken`).
#
# Parse::Webhooks::Payload captures that token (before scrubbing it out of
# `user` / `object` / etc.) and exposes two opt-in handles:
#
#   * payload.user_client -- a non-master Parse::Client sibling of the default.
#   * payload.user_agent  -- a non-master Parse::Agent carrying the token, which
#                            therefore runs in CLIENT MODE (ACL + CLP enforced,
#                            no master-key fallback to silently bypass scoping).
#
# THE LOAD-BEARING ASSERTION IN EVERY TEST IS THE NEGATIVE ONE: the scoped
# path must NOT see another user's private row, while the master path DOES.
# "Scoped sees my own row" proves nothing on its own -- master sees it too, and
# a handler that accidentally got the master client would still pass that check.
# Only the (scoped-excludes-B) AND (master-includes-B) contrast proves real ACL
# enforcement and would catch a regression that dropped the agent back to master.
#
# The triggering save in tests 1 and 2 is performed AS user A (a real
# X-Parse-Session-Token header) -- a master-key write carries no `user` and so
# no token, and the feature could not apply. Tokens are obtained with a real
# Parse::User.login: a bare master-key save yields session_token => nil.
#
# Requires Docker (PARSE_TEST_USE_DOCKER=true) and a Parse Server container
# whose `host.docker.internal` resolves back to the test host (tests 1 and 2).

# Neutral domain classes (see CLAUDE.md domain-term hygiene). acl_policy :public
# keeps a non-master create from being blocked at the ACL gate before the
# webhook runs -- the non-master/session-scoped path is the whole point.
class WebhookRoutePost < Parse::Object
  parse_class "WebhookRoutePost"
  acl_policy :public
  property :title, :string
end

# Carrier for the model-DSL ("callback"-style) handler's capture. The webhook is
# registered inside the test via the WebhookCallbackPost.webhook DSL macro (not
# Parse::Webhooks.route) so it survives the per-test routes reset in setup.
class WebhookCallbackPost < Parse::Object
  parse_class "WebhookCallbackPost"
  acl_policy :public
  property :title, :string

  class << self
    attr_accessor :captured
  end
  self.captured = nil
end

class McpScopedPost < Parse::Object
  parse_class "McpScopedPost"
  acl_policy :public
  property :title, :string
end

module WebhookSessionTokenSetup
  def setup
    super
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks.allow_unauthenticated = true
    @prior_allow_private_webhook_urls = Parse::Webhooks.instance_variable_get(:@allow_private_webhook_urls)
    Parse::Webhooks.allow_private_webhook_urls = true

    WebhookCallbackPost.captured = nil

    @server = Parse::Test::WebhookTestServer.new.start!

    unless docker_can_reach_host?
      @server.stop!
      skip "Parse Server container cannot reach the test host at " \
           "#{@server.url}; ensure docker-compose has " \
           "extra_hosts: [\"host.docker.internal:host-gateway\"]."
    end
  end

  def teardown
    begin
      Parse::Webhooks.remove_all_triggers! if @server
    rescue StandardError
      # parent resets DB anyway
    end
    @server&.stop!
    Parse::Webhooks.allow_unauthenticated = false
    Parse::Webhooks.instance_variable_set(:@allow_private_webhook_urls, @prior_allow_private_webhook_urls)
    super
  end
end

class WebhookSessionTokenAsUserIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  prepend WebhookSessionTokenSetup

  # Reads +class_name+ two ways from inside a webhook handler and returns a hash
  # the test body asserts on:
  #   * scoped via payload.user_agent (non-master + token => client mode), and
  #   * master via a plain Parse::Agent on the default (master) client.
  # Defined as a class method so both the Parse::Webhooks.route block (test 1)
  # and the WebhookCallbackPost.webhook DSL block (test 2) can share it; both
  # run instance_exec'd on the Parse::Webhooks::Payload, so +payload+ is +self+.
  def self.capture_scoped_vs_master(payload, class_name)
    cap = { has_token: payload.session_token? }
    agent = payload.user_agent
    cap[:client_mode] = agent && agent.instance_variable_get(:@client_mode)
    scoped = agent.execute(:query_class, class_name: class_name, limit: 100)
    cap[:scoped_ok]  = scoped[:success]
    cap[:scoped_err] = scoped[:error]
    cap[:scoped_ids] = scoped[:success] ? scoped[:data][:results].map { |r| r["objectId"] } : []
    # Prove the token is BOUND to user_client: a raw REST GET with NO
    # session_token: arg and NO Parse.with_session wrapper is still authorized
    # as the caller (the client carries no master key, so the bound token is
    # the only credential).
    raw = payload.user_client.request(:get, "classes/#{class_name}")
    # Parse::Response#result already unwraps a find to the results array.
    cap[:raw_client_ids] = raw.result.map { |r| r["objectId"] }
    master = Parse::Agent.new.execute(:query_class, class_name: class_name, limit: 100)
    cap[:master_ids] = master[:success] ? master[:data][:results].map { |r| r["objectId"] } : []
    cap
  rescue => e
    { error: "#{e.class}: #{e.message}" }
  end

  # ------------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------------

  # Seed a user under the master client, then log in for a LIVE session token
  # (a master-key save leaves session_token => nil). Returns [user, token].
  def seed_and_login(prefix)
    username = "#{prefix}_#{SecureRandom.hex(4)}"
    password = "pw_#{SecureRandom.hex(4)}"
    user = Parse::User.new(username: username, password: password, email: "#{username}@test.com")
    assert user.save, "seeded user #{username} must save"
    @test_context.track(user)
    logged_in = Parse::User.login(username, password)
    refute_nil logged_in&.session_token,
               "Parse::User.login must return a live session token for #{username}"
    [user, logged_in.session_token]
  end

  # Master-create a row owned (read+write) by exactly one user -- private to
  # that user (and the master key). No "*" entry, so no other session can read.
  def seed_private_post(class_name, owner_id, title)
    master_create(class_name, {
      "title" => title,
      "ACL"   => { owner_id => { "read" => true, "write" => true } },
    })
  end

  def master_create(class_name, body)
    Parse.client.request(:post, "classes/#{class_name}", body: body.to_json).result["objectId"]
  end

  # Create as a logged-in user so Parse Server fires the trigger with
  # user.sessionToken in the webhook payload.
  def session_create(class_name, body, session_token)
    Parse.client.request(
      :post,
      "classes/#{class_name}",
      body: body.to_json,
      headers: { "X-Parse-Master-Key" => "", "X-Parse-Session-Token" => session_token },
      opts: { use_master_key: false },
    ).result["objectId"]
  end

  # A non-master sibling of the default client, mirroring how an MCP host that
  # does NOT hold the master key in-process would be configured.
  def non_master_client
    base = Parse::Client.client
    Parse::Client.new(
      server_url: base.server_url,
      app_id: base.application_id,
      api_key: base.api_key,
      master_key: nil,
    )
  end

  # A non-master client with a session token BOUND (the shape user_client /
  # session_client return).
  def bound_client(token)
    base = Parse::Client.client
    Parse::Client.new(
      server_url: base.server_url,
      app_id: base.application_id,
      api_key: base.api_key,
      master_key: nil,
      session_token: token,
    )
  end

  # Install a class schema with the given classLevelPermissions (which may
  # include protectedFields). Idempotent: update first, create if missing.
  def install_schema!(class_name, clp, fields = {})
    schema = {
      "className" => class_name,
      "fields" => { "title" => { "type" => "String" } }.merge(fields),
      "classLevelPermissions" => clp,
    }
    resp = Parse.client.update_schema(class_name, schema)
    Parse.client.create_schema(class_name, schema) unless resp.success?
  end

  # Did a raw GET through +client+ succeed (return rows) or get denied by CLP?
  def reads_or_denied(client, class_name)
    client.request(:get, "classes/#{class_name}").result.map { |r| r["objectId"] }
  rescue Parse::Error, StandardError
    :denied
  end

  def wait_until(description, timeout: 8)
    deadline = Time.now + timeout
    loop do
      return if yield
      flunk "timed out (#{timeout}s) waiting for: #{description}" if Time.now >= deadline
      sleep 0.05
    end
  end

  def docker_can_reach_host?
    result = `docker exec #{ENV["PSNEXT_PREFIX"] || "psnext-it"}-server sh -c 'getent hosts host.docker.internal' 2>&1`
    !result.empty? && $?.success?
  end

  # ==================================================================
  # Test 1: standalone (non-callback) webhook registered via
  #         Parse::Webhooks.route, reading as the caller through user_agent.
  # ==================================================================
  def test_route_webhook_reads_as_caller_via_user_agent
    user_a, token_a = seed_and_login("route_a")
    user_b, _tok_b  = seed_and_login("route_b")

    a_post = seed_private_post("WebhookRoutePost", user_a.id, "A private")
    b_post = seed_private_post("WebhookRoutePost", user_b.id, "B private")

    captured = {}
    Parse::Webhooks.route(:after_save, "WebhookRoutePost") do
      # Capture only the first delivery (Parse may retry / fan out).
      unless captured.any?
        captured.replace(
          WebhookSessionTokenAsUserIntegrationTest.capture_scoped_vs_master(self, "WebhookRoutePost")
        )
      end
      true
    end
    Parse::Webhooks.register_triggers!(@server.url)

    # Trigger as user A -> payload carries user.sessionToken (A's token).
    session_create("WebhookRoutePost", { "title" => "A trigger" }, token_a)
    wait_until("route afterSave captured a scoped read") { captured.any? }

    assert_nil captured[:error], "handler raised: #{captured[:error]}"
    assert captured[:has_token],   "payload carried user A's session token"
    assert captured[:client_mode], "payload.user_agent runs in CLIENT MODE (non-master + token)"
    assert captured[:scoped_ok],   "scoped query_class failed: #{captured[:scoped_err]}"
    assert_includes captured[:scoped_ids], a_post,
                    "A can read her own private row through the scoped agent"
    refute_includes captured[:scoped_ids], b_post,
                    "[ACL] the scoped agent must NOT see user B's private row"
    # Raw user_client (bound token, no with_session, no per-call token) also
    # enforces ACL -- proves the token is genuinely bound to the client.
    assert_includes captured[:raw_client_ids], a_post,
                    "raw user_client (bound token) reads A's own row"
    refute_includes captured[:raw_client_ids], b_post,
                    "[ACL] raw user_client must NOT see B's private row"
    assert_includes captured[:master_ids], b_post,
                    "master sees B's row -> it exists and was excluded only by ACL scoping"
  end

  # ==================================================================
  # Test 2: model webhook DSL ("callback"-style registration) reading as the
  #         caller through user_agent. Registered via WebhookCallbackPost.webhook
  #         (the Parse::Object macro) rather than Parse::Webhooks.route directly.
  # ==================================================================
  def test_model_dsl_webhook_reads_as_caller_via_user_agent
    user_a, token_a = seed_and_login("cb_a")
    user_b, _tok_b  = seed_and_login("cb_b")

    a_post = seed_private_post("WebhookCallbackPost", user_a.id, "A private")
    b_post = seed_private_post("WebhookCallbackPost", user_b.id, "B private")

    # Model-level DSL registration (distinct from test 1's direct route call).
    WebhookCallbackPost.webhook(:after_save) do
      unless WebhookCallbackPost.captured
        WebhookCallbackPost.captured =
          WebhookSessionTokenAsUserIntegrationTest.capture_scoped_vs_master(self, "WebhookCallbackPost")
      end
      true
    end
    Parse::Webhooks.register_triggers!(@server.url)

    session_create("WebhookCallbackPost", { "title" => "A trigger" }, token_a)
    wait_until("model-DSL afterSave captured a scoped read") { WebhookCallbackPost.captured }

    cap = WebhookCallbackPost.captured
    assert_nil cap[:error], "handler raised: #{cap[:error]}"
    assert cap[:has_token],   "payload carried the caller's session token"
    assert cap[:client_mode], "user_agent runs in CLIENT MODE"
    assert cap[:scoped_ok],   "scoped query failed: #{cap[:scoped_err]}"
    assert_includes cap[:scoped_ids], a_post, "A reads her own private row"
    refute_includes cap[:scoped_ids], b_post,
                    "[ACL] scoped agent must NOT see B's private row"
    refute_includes cap[:raw_client_ids], b_post,
                    "[ACL] raw user_client (bound token) must NOT see B's private row"
    assert_includes cap[:master_ids], b_post,
                    "master sees B's row (excluded above only by scoping)"
  end

  # ==================================================================
  # Test 3: an MCP-style agent initialized with the session-token scope,
  #         proving ACL enforcement. Mirrors the MCP rack-app factory but with
  #         the CORRECT posture -- a non-master client. (A :default client that
  #         still holds the master key would put the agent in MASTER mode and
  #         silently ignore ACL; that is the trap this test guards against.)
  # ==================================================================
  def test_mcp_agent_session_token_scope_enforces_acl
    user_a, token_a = seed_and_login("mcp_a")
    user_b, _tok_b  = seed_and_login("mcp_b")

    a_post = seed_private_post("McpScopedPost", user_a.id, "A private")
    b_post = seed_private_post("McpScopedPost", user_b.id, "B private")

    agent = Parse::Agent.new(session_token: token_a, client: non_master_client)
    assert agent.instance_variable_get(:@client_mode),
           "agent built with a non-master client + session token must be in CLIENT MODE"

    res = agent.execute(:query_class, class_name: "McpScopedPost", limit: 100)
    assert res[:success], "scoped query_class failed: #{res[:error]}"
    ids = res[:data][:results].map { |r| r["objectId"] }
    assert_includes ids, a_post, "A reads her own private row through the MCP agent"
    refute_includes ids, b_post,
                    "[ACL] an MCP agent scoped to A must NOT see B's private row"

    # Fetch-by-id of B's row is denied under A's ACL (Parse returns not-found).
    got_b = agent.execute(:get_object, class_name: "McpScopedPost", object_id: b_post)
    refute got_b[:success], "MCP agent must not fetch B's private row by id"

    # Master contrast: the row really exists, so the exclusion above is ACL
    # enforcement, not an empty class.
    master = Parse::Agent.new.execute(:query_class, class_name: "McpScopedPost", limit: 100)
    assert_includes master[:data][:results].map { |r| r["objectId"] }, b_post,
                    "master sees B's row -> exclusion above is ACL enforcement"
  end

  # ==================================================================
  # Test 4: Parse::Client#with_session { } runs a block as the user so ordinary
  #         model queries (REST-routed) inside it are implicitly ACL-scoped.
  # ==================================================================
  def test_client_with_session_block_scopes_model_queries_to_user
    user_a, token_a = seed_and_login("scope_a")
    user_b, _tok_b  = seed_and_login("scope_b")

    a_post = seed_private_post("McpScopedPost", user_a.id, "A private")
    b_post = seed_private_post("McpScopedPost", user_b.id, "B private")

    uc = bound_client(token_a)

    # Inside the block, a plain model query resolves the default client but is
    # authorized as user A (master suppressed, token applied).
    scoped_ids = uc.with_session { McpScopedPost.query.all.map(&:id) }
    assert_includes scoped_ids, a_post, "with_session block: A sees her own private row"
    refute_includes scoped_ids, b_post,
                    "[ACL] with_session block must NOT surface B's private row"

    scoped_count = uc.with_session { McpScopedPost.query.count }
    assert_operator scoped_count, :>=, 1, "scoped count includes A's own row"

    # Outside the block (master default client) both rows are visible -> proves
    # the exclusion above is scoping, not an empty class.
    master_ids = McpScopedPost.query.all.map(&:id)
    assert_includes master_ids, a_post
    assert_includes master_ids, b_post,
                    "master sees B's row -> with_session excluded it by ACL, not absence"

    # A client with no bound token cannot scope (fail-fast, not a silent no-op).
    assert_raises(ArgumentError) { non_master_client.with_session { McpScopedPost.query.count } }
  end

  # ==================================================================
  # Test 5: a Cloud Code FUNCTION webhook fired by a logged-in user carries the
  #         session token, so user_agent works from a function handler too.
  #         (Empirically confirms Parse Server sends user.sessionToken for
  #         functions, not just triggers.)
  # ==================================================================
  def test_function_webhook_carries_token_and_scopes_via_user_agent
    user_a, token_a = seed_and_login("fn_a")
    user_b, _tok_b  = seed_and_login("fn_b")
    a_post = seed_private_post("McpScopedPost", user_a.id, "A private")
    b_post = seed_private_post("McpScopedPost", user_b.id, "B private")

    captured = {}
    Parse::Webhooks.route(:function, "scopedVisible") do
      unless captured.any?
        cap = { function: function?, has_token: session_token? }
        agent = user_agent
        cap[:client_mode] = agent && agent.instance_variable_get(:@client_mode)
        res = agent ? agent.execute(:query_class, class_name: "McpScopedPost", limit: 100) : { success: false }
        cap[:scoped_ids] = res[:success] ? res[:data][:results].map { |r| r["objectId"] } : []
        captured.replace(cap)
      end
      captured[:scoped_ids]
    end
    Parse::Webhooks.register_functions!(@server.url)

    # Invoke the function as user A so Parse includes user.sessionToken.
    Parse.client.request(
      :post, "functions/scopedVisible",
      body: {}.to_json,
      headers: { "X-Parse-Master-Key" => "", "X-Parse-Session-Token" => token_a },
      opts: { use_master_key: false },
    )
    wait_until("function webhook captured a scoped read") { captured.any? }

    assert captured[:function],   "payload.function? is true in a function webhook"
    assert captured[:has_token],  "function webhook carries the caller's session token"
    assert captured[:client_mode], "user_agent runs in client mode from a function webhook"
    assert_includes captured[:scoped_ids], a_post, "A reads her own row from the function handler"
    refute_includes captured[:scoped_ids], b_post,
                    "[ACL] function-webhook user_agent must NOT see B's private row"
  end

  # ==================================================================
  # Test 6: a FORGED/invalid session token fails closed — it must never fall
  #         back to the master key and read a row the real user couldn't.
  # ==================================================================
  def test_forged_session_token_fails_closed_no_master_fallback
    user_a, _tok = seed_and_login("forge_a")
    a_post = seed_private_post("McpScopedPost", user_a.id, "A private")

    forged = bound_client("r:totally-bogus-session-token-xyz")
    saw_row = begin
      forged.request(:get, "classes/McpScopedPost").result.any? { |r| r["objectId"] == a_post }
    rescue Parse::Error, StandardError
      false # 401 invalid-session is the expected fail-closed outcome
    end
    refute saw_row,
           "[security] a forged session token must never read a row via a master fallback"

    # Master DOES see the row -> the denial above was authorization, not an
    # empty class.
    assert_includes McpScopedPost.query.all.map(&:id), a_post, "master sees A's row"
  end

  # ==================================================================
  # Test 7: CLP depth — a class whose find/get requires authentication. A
  #         session-bound client passes the CLP gate; the same client made
  #         anonymous (token cleared) is denied; master bypasses CLP.
  #         Also exercises Parse::Client#anonymous actually dropping the token.
  # ==================================================================
  def test_clp_requires_auth_session_allowed_anonymous_denied
    _user_a, token_a = seed_and_login("clp_a")
    install_schema!("SessionClpPost", {
      "find"     => { "requiresAuthentication" => true },
      "get"      => { "requiresAuthentication" => true },
      "count"    => { "requiresAuthentication" => true },
      "create"   => { "*" => true },
      "update"   => { "*" => true },
      "delete"   => { "*" => true },
      "addField" => { "*" => true },
    })
    # Public-read ACL so the gate under test is CLP, not row ACL.
    row = master_create("SessionClpPost",
                        { "title" => "t", "ACL" => { "*" => { "read" => true, "write" => true } } })

    sc = bound_client(token_a)
    anon = sc.anonymous # same connection, token cleared

    assert_includes reads_or_denied(sc, "SessionClpPost"), row,
                    "[CLP] an authenticated session passes the requiresAuthentication gate"
    assert_equal :denied, reads_or_denied(anon, "SessionClpPost"),
                 "[CLP] an anonymous client (token cleared via #anonymous) must be denied"
    # Master bypasses CLP entirely.
    assert_includes Parse.client.request(:get, "classes/SessionClpPost").result.map { |r| r["objectId"] },
                    row, "master bypasses CLP"
  end

  # ==================================================================
  # Test 8: protectedFields depth — a protected field is stripped on the
  #         user-session REST path (and for anonymous), but present for master.
  #         Proves user_client/session_client route through the enforced path,
  #         not a hidden master fallback.
  # ==================================================================
  def test_protected_fields_stripped_for_session_and_anonymous_present_for_master
    _user_a, token_a = seed_and_login("pf_a")
    install_schema!("SessionProtectedPost", {
      "find"           => { "*" => true },
      "get"            => { "*" => true },
      "create"         => { "*" => true },
      "update"         => { "*" => true },
      "addField"       => { "*" => true },
      "protectedFields" => { "*" => ["secret"] }, # hidden from every non-master client
    }, { "secret" => { "type" => "String" } })

    row = master_create("SessionProtectedPost", {
      "title" => "t", "secret" => "S3CRET",
      "ACL" => { "*" => { "read" => true } },
    })

    sc   = bound_client(token_a)
    anon = sc.anonymous

    sc_row = sc.request(:get, "classes/SessionProtectedPost/#{row}").result
    assert_equal "t", sc_row["title"], "non-protected field passes through to the session client"
    refute sc_row.key?("secret"),
           "[protectedFields] the protected field must be stripped for a session client"

    anon_row = anon.request(:get, "classes/SessionProtectedPost/#{row}").result
    refute anon_row.key?("secret"),
           "[protectedFields] the protected field must be stripped for an anonymous client"

    # Master sees it -> proves the field exists and was stripped by enforcement,
    # i.e. the scoped clients are genuinely non-master.
    master_row = Parse.client.request(:get, "classes/SessionProtectedPost/#{row}").result
    assert_equal "S3CRET", master_row["secret"], "master sees the protected field"
  end
end
