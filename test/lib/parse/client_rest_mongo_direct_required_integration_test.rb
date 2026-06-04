require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# Locks in the v5.0 +@use_master_key = nil+ flip on Parse::Query. The
# silent-ACL-bypass it closes: prior to 5.0, a bare client-mode query
# carrying a constraint that ONLY Mongo (not Parse REST) can run —
# +within_sphere+, +geo_intersects+ on a GeoJSON shape — would fall
# through to the mongo-direct path with implicit master-key auth,
# bypassing CLP/ACL for every row in the collection. After 5.0,
# +@use_master_key+ defaults to nil, and {Parse::Query#assert_mongo_direct_routable!}
# raises {Parse::Query::MongoDirectRequired} unless the caller has
# explicitly opted into one of: +use_master_key: true+,
# +scope_to_user(user)+, +scope_to_role("name")+, or
# +session_token = "..."+.
#
# These tests are the regression guard for that closure. They run under
# the no-master-key client (the test harness's +as_client+ mode) so
# +client.master_key+ is nil and there is no implicit fallthrough.
class MongoDirectGate < Parse::Object
  parse_class "MongoDirectGate"
  acl_policy :public
  property :name, :string
  property :location, :geopoint
end

class ClientRestMongoDirectRequiredIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  MONGODB_URI = (ENV["PARSE_TEST_MONGO_URI"] || "mongodb://admin:password@localhost:29017/parse_stack_next_it?authSource=admin")

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super

    # Wipe Parse::CLPScope's in-process cache so a previous test's
    # negative (unresolvable) verdict for +MongoDirectGate+ doesn't
    # bleed across the per-test DB reset. The schema is reinstalled
    # below; this guarantees CLPScope refetches it on the first
    # mongo-direct call.
    Parse::CLPScope.reset_cache! if defined?(Parse::CLPScope)

    # Install the class with CLP that lets +scope_to_user+ /
    # +session_token+ paths read it. Without this, Parse::CLPScope
    # fails closed on the mongo-direct path (correctly) and shadows
    # the routing assertion we care about here.
    with_master_key do
      schema = {
        "className" => "MongoDirectGate",
        "fields" => {
          "name" => { "type" => "String" },
          "location" => { "type" => "GeoPoint" },
        },
        "classLevelPermissions" => {
          "find"   => { "requiresAuthentication" => true },
          "get"    => { "requiresAuthentication" => true },
          "count"  => { "requiresAuthentication" => true },
          "create" => { "requiresAuthentication" => true },
          "update" => { "requiresAuthentication" => true },
          "delete" => { "requiresAuthentication" => true },
          "addField" => {},
        },
      }
      response = Parse.client.update_schema("MongoDirectGate", schema)
      Parse.client.create_schema("MongoDirectGate", schema) unless response.success?

      # Pre-warm Parse::CLPScope cache with the just-installed CLP.
      # Without this, the cache miss happens under the no-master client
      # (because the test below runs in +as_client+), the schema GET
      # 403s, and CLPScope falls closed — shadowing the routing
      # assertion. In a real client-mode deployment the operator
      # similarly pre-warms (or routes schema fetches through a
      # master-key sidecar); we simulate that here.
      if defined?(Parse::CLPScope)
        Parse::CLPScope.__cache_put(
          "MongoDirectGate", clp: schema["classLevelPermissions"],
        )
      end

      MongoDirectGate.new(
        name: "in-range",
        location: Parse::GeoPoint.new(37.7749, -122.4194),
      ).tap do |row|
        assert row.save
        @test_context.track(row)
      end
    end

    @user, @user_pw = seed_client_user("mdr_user")
  end

  def teardown
    Parse::MongoDB.reset! if defined?(Parse::MongoDB)
    super
  end

  # Lazy-configure Parse::MongoDB so the +mongo+ gem load is skipped on
  # CI runs that don't ship it. Returns false when not available so
  # individual tests can skip cleanly.
  def setup_mongo_direct
    require "mongo"
    require "parse/mongodb"
    Parse::MongoDB.configure(uri: MONGODB_URI, enabled: true)
    true
  rescue LoadError
    false
  end

  # The constraint shape we use throughout: +within_sphere+ compiles to
  # +$geoWithin+/+$centerSphere+, which is a native MongoDB operator
  # the Parse REST find layer cannot express. The compiled where carries
  # a +__mongo_direct_only+ marker that +Parse::Query#requires_mongo_direct?+
  # detects.
  def direct_only_query
    center = Parse::GeoPoint.new(37.7749, -122.4194)
    MongoDirectGate.query(:location.within_sphere => [center, 50, :km])
  end

  # --------------------------------------------------------------------
  # 1. Bare client-mode query with a direct-only constraint and NO
  #    auth context (no master, no scope_to_user, no session) MUST
  #    raise rather than silently fall through to mongo-direct under
  #    implicit master-key auth.
  # --------------------------------------------------------------------
  def test_bare_client_query_with_direct_only_constraint_raises
    as_client do
      err = assert_raises(Parse::Query::MongoDirectRequired) do
        direct_only_query.results
      end
      assert_match(/use_master_key|scope_to_user|session_token/i, err.message,
                   "error must explain the available auth-context opt-ins, got: #{err.message}")
    end
  end

  # --------------------------------------------------------------------
  # 2. Same query with explicit +use_master_key: true+ routes through.
  #    Caller takes responsibility for the bypass — they've named it.
  # --------------------------------------------------------------------
  def test_query_with_explicit_use_master_key_routes_through
    skip "MongoDB direct tests require mongo gem" unless setup_mongo_direct

    # Master-key path requires the master-key client; ambient client mode
    # would set the disable-master flag. Run this outside +as_client+.
    center = Parse::GeoPoint.new(37.7749, -122.4194)
    q = MongoDirectGate.query(:location.within_sphere => [center, 50, :km])
    q.use_master_key = true

    results = q.results
    assert_kind_of Array, results
    refute_empty results, "seeded row must come back through the master-key direct route"
    assert(results.any? { |r| r.name == "in-range" },
           "the routed query must actually return the seeded row")
  end

  # --------------------------------------------------------------------
  # 3. Same query under +scope_to_user(user)+ routes through with the
  #    SDK-mediated ACLScope simulation. This is the recommended path
  #    for a client-mode caller that holds a User pointer (not a session
  #    token) and wants per-row ACL enforcement.
  # --------------------------------------------------------------------
  def test_query_with_scope_to_user_routes_through
    skip "MongoDB direct tests require mongo gem" unless setup_mongo_direct

    as_client do
      me = Parse::User.login!(@user.username, @user_pw)
      center = Parse::GeoPoint.new(37.7749, -122.4194)
      q = MongoDirectGate.query(:location.within_sphere => [center, 50, :km]).scope_to_user(me)

      results = q.results
      assert_kind_of Array, results,
                     "scope_to_user must satisfy the gate and return an Array"
      # The seeded row has :public ACL so it's visible to any
      # authenticated user; the assertion here is that the routing fired
      # without raising, not the ACL outcome (covered separately).
      assert(results.any? { |r| r.name == "in-range" },
             "the routed query must return the publicly-readable seeded row")
    end
  end

  # --------------------------------------------------------------------
  # 4. Same query carrying a +session_token+ (the kwarg form) routes
  #    through with the full three-layer ACL simulation. Equivalent to
  #    +scope_to_user+ but driven from a raw token rather than a
  #    pre-resolved User pointer.
  # --------------------------------------------------------------------
  def test_query_with_session_token_routes_through
    skip "MongoDB direct tests require mongo gem" unless setup_mongo_direct

    as_client do
      me = Parse::User.login!(@user.username, @user_pw)
      center = Parse::GeoPoint.new(37.7749, -122.4194)
      q = MongoDirectGate.query(:location.within_sphere => [center, 50, :km])
      q.session_token = me.session_token

      results = q.results
      assert_kind_of Array, results
      assert(results.any? { |r| r.name == "in-range" })
    end
  end
end
