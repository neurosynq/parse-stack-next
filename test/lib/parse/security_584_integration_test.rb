# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require_relative "../../../lib/parse/live_query"
require "securerandom"
require "timeout"

# Live integration coverage for the 5.8.4 security patch against the Docker
# stack (Parse Server, MongoDB, Redis). Each behavior is checked both ways:
# an authorized read that returns the seeded rows, and a denied or
# cross-tenant read that returns nothing or raises the documented error.
#
# Run:
#   PARSE_TEST_USE_DOCKER=true bundle exec ruby -Ilib:test \
#     test/lib/parse/security_584_integration_test.rb

# Tenant-scoped class with a declared server name on a plain field
# ("PublicState") and on a pointer ("OwnerRef", stored as _p_OwnerRef).
class Sec584Post < Parse::Object
  parse_class "Sec584Post"
  property :title, :string
  property :tenant_code, :string
  property :public_state, :string, field: "PublicState"
  belongs_to :owner_ref, as: :user, field: "OwnerRef"

  agent_tenant_scope :tenant_code, from: ->(agent) { agent.tenant_id }
end

# Plain class for the ambient-session and pipeline checks.
class Sec584Document < Parse::Object
  parse_class "Sec584Document"
  property :title, :string
  property :category, :string
end

# Class whose CLP marks secretCode as a protected field for everyone.
class Sec584Secret < Parse::Object
  parse_class "Sec584Secret"
  property :name, :string
  property :secret_code, :string
  property :score, :integer
end

# The stack's LiveQuery server only watches a fixed list of classes
# (scripts/start-parse.sh), so the MCP subscription check reuses
# "TestLiveQuery" with a tenant field added.
class Sec584LiveRow < Parse::Object
  parse_class "TestLiveQuery"
  property :name, :string
  property :status, :string
  property :tenant_code, :string

  agent_tenant_scope :tenant_code, from: ->(agent) { agent.tenant_id }
end

class Security584IntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  MONGODB_URI = (ENV["PARSE_TEST_MONGO_URI"] || "mongodb://admin:password@localhost:29017/parse_stack_next_it?authSource=admin&directConnection=true")
  LIVE_QUERY_URL = ENV["PARSE_TEST_LIVE_QUERY_URL"] || "ws://localhost:29337"
  EVENT_TIMEOUT = 8

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    Parse::CLPScope.reset_cache! if defined?(Parse::CLPScope)
  end

  def teardown
    Parse::MongoDB.reset! if defined?(Parse::MongoDB)
    Parse::CLPScope.reset_cache! if defined?(Parse::CLPScope)
    super
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def setup_mongo_direct!
    require "mongo"
    require "parse/mongodb"
    Parse::MongoDB.configure(uri: MONGODB_URI, enabled: true)
  rescue LoadError
    skip "MongoDB direct tests require mongo gem"
  end

  def acl_for(*user_ids, public_read: false)
    acl = Parse::ACL.new
    acl.apply(:public, read: true) if public_read
    user_ids.each { |id| acl.apply(id, read: true, write: true) }
    acl
  end

  def save!(obj)
    assert obj.save, "seed save failed for #{obj.parse_class}: #{obj.errors.full_messages.inspect rescue ""}"
    @test_context.track(obj)
    obj
  end

  def new_user(prefix)
    create_test_user(username: "#{prefix}_#{SecureRandom.hex(4)}", password: "pw_#{SecureRandom.hex(6)}")
  end

  # Seeds Sec584Post rows: two public rows and one private row in tenant A
  # (owned by alice), one public row in tenant B (owned by bob).
  def seed_tenant_posts(alice, bob)
    {
      a_public_1: save!(Sec584Post.new(title: "a-public-1", tenant_code: "tenant_a", public_state: "public", owner_ref: alice).tap { |p| p.acl = acl_for(public_read: true) }),
      a_public_2: save!(Sec584Post.new(title: "a-public-2", tenant_code: "tenant_a", public_state: "shared", owner_ref: alice).tap { |p| p.acl = acl_for(public_read: true) }),
      a_private: save!(Sec584Post.new(title: "a-private", tenant_code: "tenant_a", public_state: "private", owner_ref: alice).tap { |p| p.acl = acl_for(public_read: true) }),
      b_public: save!(Sec584Post.new(title: "b-public", tenant_code: "tenant_b", public_state: "public", owner_ref: bob).tap { |p| p.acl = acl_for(public_read: true) }),
    }
  end

  def titles_from_tool(result)
    assert result[:success], "agent tool call failed: #{result[:error]}"
    Array(result.dig(:data, :results)).map { |r| r["title"] || r[:title] }.compact.sort
  end

  def install_clp!(class_name, clp)
    response = Parse.client.update_schema(class_name, { "className" => class_name, "classLevelPermissions" => clp })
    assert response.success?, "CLP install failed for #{class_name}: #{response.error rescue response.inspect}"
    Parse::CLPScope.reset_cache!
  end

  # ------------------------------------------------------------------
  # 1. Agent tenant scope and per-agent filter on the mongo-direct path
  # ------------------------------------------------------------------

  def test_agent_tenant_scope_and_per_agent_filter_on_mongo_direct_query_class
    setup_mongo_direct!
    alice = new_user("sec584_alice")
    bob = new_user("sec584_bob")
    seed_tenant_posts(alice, bob)

    # The stored column is the declared server name, not the camelized one.
    raw = Parse::MongoDB.aggregate("Sec584Post", [{ "$match" => { "PublicState" => "private" } }], master: true)
    assert_equal 1, raw.size, "private row must be stored under the real PublicState column"

    alice_ptr = Parse::Pointer.new("_User", alice.id)

    # Tenant A agent without a per-agent filter sees all three tenant A rows.
    agent_a = Parse::Agent.new(acl_user: alice_ptr, tenant_id: "tenant_a")
    assert agent_a.acl_scope_requires_direct?, "acl_user agent must route through mongo-direct"
    assert_equal %w[a-private a-public-1 a-public-2], titles_from_tool(agent_a.execute(:query_class, class_name: "Sec584Post"))

    # Tenant B agent sees only the tenant B row, never tenant A's.
    agent_b = Parse::Agent.new(acl_user: alice_ptr, tenant_id: "tenant_b")
    assert_equal %w[b-public], titles_from_tool(agent_b.execute(:query_class, class_name: "Sec584Post"))

    # A caller where naming tenant B from the tenant A agent is refused.
    cross = agent_a.execute(:query_class, class_name: "Sec584Post", where: { "tenantCode" => "tenant_b" })
    refute cross[:success], "tenant A agent must not reach tenant B rows through its own where"
    assert_match(/Tenant scope conflict/i, cross[:error].to_s)
    refute_match(/b-public/, cross.inspect)

    # Per-agent filter keyed by the declared server name hides private rows.
    filtered = Parse::Agent.new(
      acl_user: alice_ptr, tenant_id: "tenant_a",
      filters: { "Sec584Post" => { "PublicState" => { "$ne" => "private" } } },
    )
    visible = titles_from_tool(filtered.execute(:query_class, class_name: "Sec584Post"))
    assert_equal %w[a-public-1 a-public-2], visible
    refute_includes visible, "a-private"

    # The caller cannot widen the per-agent filter by asking for private rows.
    widened = titles_from_tool(filtered.execute(:query_class, class_name: "Sec584Post", where: { "PublicState" => "private" }))
    assert_empty widened, "caller where must not override the per-agent filter"
  end

  def test_agent_aggregate_tool_applies_tenant_scope_and_filter_on_mongo_direct
    setup_mongo_direct!
    alice = new_user("sec584_alice")
    bob = new_user("sec584_bob")
    seed_tenant_posts(alice, bob)
    alice_ptr = Parse::Pointer.new("_User", alice.id)

    filtered = Parse::Agent.new(
      acl_user: alice_ptr, tenant_id: "tenant_a",
      filters: { "Sec584Post" => { "PublicState" => { "$ne" => "private" } } },
    )
    result = filtered.execute(:aggregate, class_name: "Sec584Post",
                                          pipeline: [{ "$group" => { "_id" => "$tenantCode", "n" => { "$sum" => 1 } } }])
    assert result[:success], "aggregate failed: #{result[:error]}"
    rows = Array(result.dig(:data, :results))
    assert_equal 1, rows.size, "only the tenant A group may appear: #{rows.inspect}"
    row = rows.first
    assert_equal "tenant_a", (row["_id"] || row[:_id] || row["objectId"] || row[:objectId])
    assert_equal 2, (row["n"] || row[:n]), "private tenant A row must be excluded by the per-agent filter"
  end

  # ------------------------------------------------------------------
  # 2. Declared pointer server name on results_direct
  # ------------------------------------------------------------------

  def test_results_direct_declared_pointer_server_name_uses_p_column
    setup_mongo_direct!
    alice = new_user("sec584_alice")
    bob = new_user("sec584_bob")
    seed_tenant_posts(alice, bob)
    alice_ptr = Parse::Pointer.new("_User", alice.id)

    owned = Sec584Post.query("OwnerRef" => alice_ptr).results_direct(master: true)
    assert_equal %w[a-private a-public-1 a-public-2], owned.map(&:title).sort

    not_owned = Sec584Post.query("OwnerRef" => { "$ne" => alice_ptr }).results_direct(master: true)
    assert_equal %w[b-public], not_owned.map(&:title).sort,
                 "$ne must exclude alice's rows; matching every row means the wrong column was used"

    missing = Sec584Post.query(:OwnerRef.exists => false).results_direct(master: true)
    assert_empty missing, "$exists:false on the real _p_OwnerRef column matches no seeded row"
  end

  # ------------------------------------------------------------------
  # 3. $jsonSchema refused in a mongo-direct pipeline
  # ------------------------------------------------------------------

  def test_json_schema_refused_and_normal_match_allowed
    setup_mongo_direct!
    save!(Sec584Document.new(title: "alpha", category: "news").tap { |d| d.acl = acl_for(public_read: true) })
    save!(Sec584Document.new(title: "beta", category: "news").tap { |d| d.acl = acl_for(public_read: true) })

    rows = Parse::MongoDB.aggregate("Sec584Document", [{ "$match" => { "category" => "news" } }], master: true)
    assert_equal 2, rows.size

    assert_raises(Parse::MongoDB::DeniedOperator) do
      Parse::MongoDB.aggregate("Sec584Document",
                               [{ "$match" => { "$jsonSchema" => { "properties" => { "title" => { "pattern" => "^a" } } } } }],
                               master: true)
    end
    assert_raises(Parse::MongoDB::DeniedOperator) do
      Parse::MongoDB.aggregate("Sec584Document",
                               [{ "$match" => { "$and" => [{ "category" => "news" }, { "$jsonSchema" => { "required" => ["title"] } }] } }],
                               master: true)
    end
  end

  # ------------------------------------------------------------------
  # 4. Parse::MongoDB.find inside Parse.with_session
  # ------------------------------------------------------------------

  def test_mongodb_find_refused_in_session_and_results_direct_scoped
    setup_mongo_direct!
    alice = new_user("sec584_alice")
    bob = new_user("sec584_bob")
    save!(Sec584Document.new(title: "alice-only", category: "acl").tap { |d| d.acl = acl_for(alice.id) })
    save!(Sec584Document.new(title: "bob-only", category: "acl").tap { |d| d.acl = acl_for(bob.id) })

    # Outside any session block, master find sees both rows.
    all_rows = Parse::MongoDB.find("Sec584Document", { "category" => "acl" })
    assert_equal 2, all_rows.size

    Parse.with_session(alice.session_token) do
      assert_raises(Parse::ACLScope::ACLRequired) do
        Parse::MongoDB.find("Sec584Document", { "category" => "acl" })
      end

      scoped = Sec584Document.query(category: "acl").results_direct
      assert_equal %w[alice-only], scoped.map(&:title)
    end

    Parse.with_session(bob.session_token) do
      scoped = Sec584Document.query(category: "acl").results_direct
      assert_equal %w[bob-only], scoped.map(&:title)
    end

    # A with_master_key block nested inside the session block allows find.
    Parse.with_session(alice.session_token) do
      Parse.with_master_key do
        assert_equal 2, Parse::MongoDB.find("Sec584Document", { "category" => "acl" }).size
      end
    end
  end

  # ------------------------------------------------------------------
  # 5. protectedFields on mongo-direct for a session scope
  # ------------------------------------------------------------------

  def test_protected_fields_refused_in_pipeline_stages_for_session_scope
    setup_mongo_direct!
    reader = new_user("sec584_reader")
    save!(Sec584Secret.new(name: "one", secret_code: "s-111", score: 1).tap { |s| s.acl = acl_for(public_read: true) })
    save!(Sec584Secret.new(name: "two", secret_code: "s-222", score: 2).tap { |s| s.acl = acl_for(public_read: true) })

    install_clp!("Sec584Secret", {
      "find" => { "*" => true }, "get" => { "*" => true }, "count" => { "*" => true },
      "create" => { "*" => true }, "update" => { "*" => true }, "delete" => { "*" => true },
      "addField" => { "*" => true },
      "protectedFields" => { "*" => ["secretCode"] },
    })

    token = reader.session_token
    rows = Parse::MongoDB.aggregate("Sec584Secret", [{ "$match" => { "score" => { "$gte" => 1 } } }], session_token: token)
    assert_equal 2, rows.size, "unprotected read must return the seeded rows"
    rows.each { |r| refute r.key?("secretCode"), "protected field leaked: #{r.inspect}" }
    assert_equal %w[one two], rows.map { |r| r["name"] }.sort

    # Master still sees the protected column (proves it is stored).
    master_rows = Parse::MongoDB.aggregate("Sec584Secret", [], master: true)
    assert(master_rows.all? { |r| r["secretCode"].to_s.start_with?("s-") })

    [
      [{ "$match" => { "secretCode" => { "$regex" => "^s-1" } } }],
      [{ "$group" => { "_id" => "$secretCode" } }],
      [{ "$setWindowFields" => { "sortBy" => { "secretCode" => 1 }, "output" => { "rank" => { "$rank" => {} } } } }],
    ].each do |pipeline|
      assert_raises(Parse::CLPScope::Denied, "expected Denied for #{pipeline.inspect}") do
        Parse::MongoDB.aggregate("Sec584Secret", pipeline, session_token: token)
      end
    end
  end

  # ------------------------------------------------------------------
  # 6a. LiveQuery _User events carry no sessionToken
  # ------------------------------------------------------------------

  def livequery_available?
    require "socket"
    uri = URI.parse(LIVE_QUERY_URL.sub(/\Aws/, "http"))
    Timeout.timeout(2) { TCPSocket.new(uri.host, uri.port).close }
    true
  rescue StandardError, Timeout::Error
    false
  end

  def configure_live_query!
    skip "LiveQuery server not available at #{LIVE_QUERY_URL}" unless livequery_available?
    Parse.live_query_enabled = true
    Parse::LiveQuery.configure do |config|
      config.url = LIVE_QUERY_URL
      config.application_id = ENV["PARSE_TEST_APP_ID"] || "psnextItAppId"
      config.client_key = ENV["PARSE_TEST_API_KEY"] || "psnext-it-rest-key"
    end
  end

  def wait_for_subscribed(sub, timeout: 6)
    deadline = Time.now + timeout
    sleep 0.1 until sub.subscribed? || Time.now > deadline
    assert sub.subscribed?, "LiveQuery subscription did not reach the subscribed state"
  end

  def test_live_query_user_events_have_no_session_token
    configure_live_query!
    user = new_user("sec584_lq")
    events = Queue.new
    sub = Parse::LiveQuery.client.subscribe("_User", where: { "objectId" => user.id }, session_token: user.session_token)
    sub.on(:update) { |obj, _orig| events << obj }
    begin
      wait_for_subscribed(sub)
      Parse.with_session(user.session_token) do
        u = Parse::User.find(user.id)
        u.username = "#{user.username}_x"
        assert u.save, "user self-update failed"
      end
      obj = Timeout.timeout(EVENT_TIMEOUT) { events.pop }
      assert_equal user.id, obj.id, "update event must be for the subscribed user"
      assert_nil obj.session_token, "sessionToken must not be present on a LiveQuery _User event"
      raw = obj.respond_to?(:attributes) ? obj.as_json : {}
      refute raw.key?("sessionToken"), "sessionToken present in event object JSON"
      refute raw.key?("authData"), "authData present in event object JSON"
    rescue Timeout::Error
      flunk "no LiveQuery update event received for _User within #{EVENT_TIMEOUT}s"
    ensure
      sub.unsubscribe rescue nil
      Parse::LiveQuery.reset!
    end
  end

  # ------------------------------------------------------------------
  # 6b. MCP resource subscription applies the tenant scope live
  # ------------------------------------------------------------------

  def test_mcp_subscription_scoped_to_agent_tenant
    configure_live_query!
    require_relative "../../../lib/parse/agent/mcp_subscriptions"
    user = new_user("sec584_mcp")
    # Create the tenantCode column before subscribing.
    save!(Sec584LiveRow.new(name: "warmup", status: "x", tenant_code: "tenant_z").tap { |r| r.acl = acl_for(public_read: true) })

    lq = Parse::LiveQuery.client
    recorded = []
    recorder = Object.new
    recorder.define_singleton_method(:subscribe) do |class_name, **opts|
      recorded << [class_name, opts]
      lq.subscribe(class_name, **opts)
    end

    notes = Queue.new
    mgr = Parse::Agent::MCPSubscriptions::Manager.new(supported: true, debounce_interval: 0, live_query_client: recorder)
    mgr.attach_listener("s1") { |n| notes << n }
    agent = Parse::Agent.new(session_token: user.session_token, tenant_id: "tenant_a")
    uri = "parse://TestLiveQuery/count"
    begin
      assert mgr.subscribe(session_id: "s1", uri: uri, agent: agent)
      cls, opts = recorded.last
      assert_equal "TestLiveQuery", cls
      assert_equal({ "tenantCode" => "tenant_a" }, opts[:where], "subscription where must carry the tenant constraint")
      assert_equal user.session_token, opts[:session_token]
      sleep 1.0

      # A write in tenant B produces no notification.
      save!(Sec584LiveRow.new(name: "other", status: "x", tenant_code: "tenant_b").tap { |r| r.acl = acl_for(public_read: true) })
      got_b = begin
          Timeout.timeout(3) { notes.pop }
        rescue Timeout::Error
          nil
        end
      assert_nil got_b, "tenant B write must not notify a tenant A subscription"

      # A write in tenant A produces a resources/updated notification.
      save!(Sec584LiveRow.new(name: "mine", status: "x", tenant_code: "tenant_a").tap { |r| r.acl = acl_for(public_read: true) })
      got_a = Timeout.timeout(EVENT_TIMEOUT) { notes.pop }
      assert_equal "notifications/resources/updated", got_a["method"]
      assert_equal uri, got_a.dig("params", "uri")
    rescue Timeout::Error
      flunk "no notification for a tenant A write within #{EVENT_TIMEOUT}s"
    ensure
      mgr.unsubscribe(session_id: "s1", uri: uri) rescue nil
      Parse::LiveQuery.reset!
    end
  end
end
