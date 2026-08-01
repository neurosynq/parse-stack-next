require_relative "../../test_helper_integration"
require "minitest/autorun"
require "net/http"
require "uri"
require "json"
require "securerandom"

# End-to-end coverage for Parse::Cache::UpstreamRoles against a live Parse
# Server whose cache adapter is backed by Redis.
#
# The unit tests stub the Redis client, so they pin our decoding and our
# freshness rules but say nothing about whether the key layout we read is the
# layout Parse Server actually writes. This file closes that gap: it signs a
# user up over REST, puts that user in a role hierarchy, makes an authenticated
# non-master request so Parse Server resolves and caches the closure, and then
# reads it back through the SDK.
#
# The stack wires this up in scripts/docker/docker-compose.test.yml, which sets
# PARSE_CACHE_REDIS_URL and thereby engages test/cloud/redis-cache-adapter.js.
# Parse Server's cache lives on Redis db 1; the SDK's own cache lives on db 0.
# They must stay apart because Parse Server clears its cache with a raw FLUSHDB
# on every _Role write (parse-community/parse-server#10617), which on a shared
# database would delete the SDK's cached responses and its create-locks.
class CacheUpstreamRolesIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  SERVER_URL = ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse"
  APP_ID = ENV["PARSE_TEST_APP_ID"] || "psnextItAppId"
  API_KEY = ENV["PARSE_TEST_API_KEY"] || "psnext-it-rest-key"
  MASTER_KEY = ENV["PARSE_TEST_MASTER_KEY"] || "psnextItMasterKey"

  # The SDK's own cache. Never written by Parse Server.
  SDK_REDIS_URL = ENV["PARSE_TEST_REDIS_URL"] || "redis://localhost:29379/0"
  # Parse Server's cache. Read-only from the SDK's point of view.
  UPSTREAM_REDIS_URL = ENV["PARSE_TEST_SERVER_CACHE_REDIS_URL"] || "redis://localhost:29379/1"

  # How long to wait for Parse Server to land the role entry. The write happens
  # inside the request it serves, so this is only slack for the round trip.
  POPULATE_TIMEOUT = 10

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Redis not reachable at #{SDK_REDIS_URL}" unless redis_reachable?(SDK_REDIS_URL)
    skip "Redis not reachable at #{UPSTREAM_REDIS_URL}" unless redis_reachable?(UPSTREAM_REDIS_URL)

    super

    @keyspace = Parse::Cache::Keyspace.new(app_id: APP_ID, server_url: SERVER_URL)
    @store = Parse::Cache::Redis.new(
      url: SDK_REDIS_URL,
      parse_cache_url: UPSTREAM_REDIS_URL,
    )
    # A keyspace can only ever be bound via a scoped view now. The backend
    # itself has no keyspace of its own. `upstream_roles` (app-id-aware, with
    # the role plane's freshness epoch) lives on the view.
    @view = @store.scoped(@keyspace)

    @seeded = seed_user_in_role_hierarchy

    # A stack running Parse Server's default in-memory cache adapter writes
    # nothing we can read. That is a harness gap, not a failure of this SDK
    # code, so skip rather than fail. Bring the stack up with
    # scripts/docker/docker-compose.test.yml to configure it.
    unless wait_for_upstream_entry(@seeded[:user_id])
      skip "Parse Server is not caching roles to #{UPSTREAM_REDIS_URL}; " \
           "PARSE_CACHE_REDIS_URL is unset or the stack predates the Redis cache adapter"
    end
  end

  def teardown
    @store&.close
    super
  end

  # The contract: the key we build is the key Parse Server writes, and its
  # value decodes into exactly the closure the server enforces.
  def test_reads_role_closure_written_by_parse_server
    roles = @view.upstream_roles.roles_for(@seeded[:user_id])

    refute_nil roles, "upstream reader should return a closure for a user Parse Server just cached"
    assert_kind_of Set, roles
    assert_includes roles, @seeded[:child_role], "direct role membership must be present"
    assert_includes roles, @seeded[:parent_role],
                    "Parse Server resolves the transitive closure, so the parent role must be present too"
  end

  # Names come back bare. Our own role_names sets hold bare names and re-add the
  # prefix when building permission strings, so a leaked prefix would compile
  # into `role:role:X` and silently under-permission every scoped query.
  def test_role_names_are_returned_without_the_role_prefix
    roles = @view.upstream_roles.roles_for(@seeded[:user_id])

    roles.each do |name|
      refute name.start_with?("role:"), "expected a bare role name, got #{name.inspect}"
    end
  end

  # Pins the physical layout against the live server rather than against our own
  # constant, so an upstream change to the key shape fails here.
  def test_key_layout_matches_the_entry_parse_server_wrote
    key = @view.upstream_roles.key_for(@seeded[:user_id])

    assert_equal "#{APP_ID}:role:#{@seeded[:user_id]}", key

    raw = with_redis(UPSTREAM_REDIS_URL) { |r| r.get(key) }
    refute_nil raw, "Parse Server should have written #{key}"

    decoded = JSON.parse(raw)
    assert_kind_of Array, decoded
    assert_includes decoded, "role:#{@seeded[:child_role]}"
    assert_includes decoded, "role:#{@seeded[:parent_role]}"
  end

  # The freshness guard needs a TTL it can age the entry by. An entry with no
  # expiry, or one far longer than the adapter's configured TTL, is rejected.
  def test_upstream_entry_carries_an_ageable_ttl
    key = @view.upstream_roles.key_for(@seeded[:user_id])
    pttl = with_redis(UPSTREAM_REDIS_URL) { |r| r.pttl(key) }

    assert_operator pttl, :>, 0, "entry must carry a positive TTL for the freshness guard to age it"
    assert_operator pttl, :<=, Parse::Cache::UpstreamRoles::DEFAULT_MAX_TTL_MS,
                    "TTL exceeds the reader's max; the adapter TTL and DEFAULT_MAX_TTL_MS have drifted apart"
  end

  # A user Parse Server never resolved has no entry, and a miss must read as nil
  # so the caller falls back to computing the closure itself.
  def test_unknown_user_is_a_miss
    assert_nil @view.upstream_roles.roles_for("NoSuchUser#{SecureRandom.hex(6)}")
    assert_nil @view.upstream_roles.roles_for(nil)
    assert_nil @view.upstream_roles.roles_for("")
  end

  # The harness contract. If this fails, the stack has put both caches on one
  # database and a single _Role write will take the SDK's create-locks with it.
  def test_parse_server_cache_is_a_separate_database_from_the_sdk_cache
    assert @view.upstream_roles.shares_database_with?(@store) == false,
           "Parse Server's cache database must not be the SDK's cache database"
    assert @store.verify_upstream_isolation!, "verify_upstream_isolation! should report the endpoints isolated"
  end

  # The reason the two databases are separated, demonstrated rather than
  # asserted from documentation: a _Role write flushes Parse Server's database
  # and leaves the SDK's create-lock keyspace untouched.
  def test_role_write_flushes_only_the_upstream_database
    lock_key = "parse-stack:foc:v1:isolation-probe:#{SecureRandom.hex(6)}"
    with_redis(SDK_REDIS_URL) { |r| r.set(lock_key, "held", ex: 120) }

    upstream_before = with_redis(UPSTREAM_REDIS_URL) { |r| r.dbsize }
    assert_operator upstream_before, :>, 0, "expected Parse Server to have cached something before the flush"

    create_role("FlushProbe#{SecureRandom.hex(4)}")

    assert_equal "held", with_redis(SDK_REDIS_URL) { |r| r.get(lock_key) },
                 "a _Role write must not reach the SDK's database"
  ensure
    with_redis(SDK_REDIS_URL) { |r| r.del(lock_key) } if lock_key
  end

  private

  # Signs a user up, builds `parent -> child` with the user in the child, then
  # makes an authenticated non-master request. That request is what makes Parse
  # Server resolve the closure and cache it; the writes alone do not.
  def seed_user_in_role_hierarchy
    suffix = SecureRandom.hex(4)
    username = "upstream_roles_probe_#{suffix}"

    signup = rest_post("/users", { username: username, password: "probe-password-#{suffix}" })
    user_id = signup.fetch("objectId")
    session_token = signup.fetch("sessionToken")

    child_role = "UpstreamChild#{suffix}"
    parent_role = "UpstreamParent#{suffix}"

    child_id = create_role(child_role, users: [user_id])
    create_role(parent_role, roles: [child_id])

    # Non-master read. Parse Server builds the ACL group for the session, which
    # is what walks the role graph and populates `<appId>:role:<userId>`.
    rest_get("/classes/_User?limit=0", session_token: session_token)

    { user_id: user_id, session_token: session_token,
      child_role: child_role, parent_role: parent_role }
  end

  def create_role(name, users: [], roles: [])
    body = { "name" => name, "ACL" => { "*" => { "read" => true } } }
    body["users"] = relation("_User", users) unless users.empty?
    body["roles"] = relation("_Role", roles) unless roles.empty?
    rest_post("/classes/_Role", body, master: true).fetch("objectId")
  end

  def relation(class_name, ids)
    {
      "__op" => "AddRelation",
      "objects" => ids.map { |id| { "__type" => "Pointer", "className" => class_name, "objectId" => id } },
    }
  end

  # Poll until Parse Server's entry shows up. The write is synchronous with the
  # request that triggered it, so this normally succeeds on the first pass; the
  # loop only covers a slow container.
  def wait_for_upstream_entry(user_id)
    key = "#{APP_ID}:role:#{user_id}"
    deadline = Time.now + POPULATE_TIMEOUT
    loop do
      return true if with_redis(UPSTREAM_REDIS_URL) { |r| r.get(key) }
      return false if Time.now >= deadline
      sleep 0.25
    end
  end

  def rest_post(path, body, master: false)
    request(Net::HTTP::Post, path, body: body, master: master)
  end

  def rest_get(path, session_token: nil)
    request(Net::HTTP::Get, path, session_token: session_token)
  end

  def request(verb, path, body: nil, master: false, session_token: nil)
    uri = URI("#{SERVER_URL}#{path}")
    req = verb.new(uri)
    req["X-Parse-Application-Id"] = APP_ID
    req["Content-Type"] = "application/json"
    if master
      req["X-Parse-Master-Key"] = MASTER_KEY
    else
      req["X-Parse-REST-API-Key"] = API_KEY
    end
    req["X-Parse-Session-Token"] = session_token if session_token
    req.body = JSON.generate(body) if body

    response = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 15) { |http| http.request(req) }
    parsed = response.body.to_s.empty? ? {} : JSON.parse(response.body)
    unless response.is_a?(Net::HTTPSuccess)
      raise "Parse Server rejected #{verb::METHOD} #{path}: #{response.code} #{parsed.inspect}"
    end
    parsed
  end

  def with_redis(url)
    require "redis"
    client = ::Redis.new(url: url, connect_timeout: 2, timeout: 2)
    yield client
  ensure
    begin
      client&.close
    rescue StandardError
      nil
    end
  end

  def redis_reachable?(url)
    with_redis(url) { |c| c.ping == "PONG" }
  rescue LoadError, StandardError
    false
  end
end
