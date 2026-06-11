require_relative "../../test_helper"

# Unit tests for the scoped-query auto-promotion added in 4.4.3:
# group_by / group_by_date / distinct aggregations on a query with a
# session_token, acl_user, or acl_role should auto-route to the
# mongo-direct path so the SDK's ACLScope + CLPScope + protectedFields
# enforcement actually runs. Parse Server's REST /aggregate endpoint is
# master-key-only and enforces neither ACL nor CLP, so without this
# promotion a scoped aggregation would silently return unscoped rows.
#
# These tests don't need a real Mongo connection — they stub
# Parse::MongoDB.enabled? and watch which path the SDK takes.
class AggregationAutoPromotionTest < Minitest::Test
  def setup
    @query = Parse::Query.new("Song")
    @mock_client = Minitest::Mock.new
    @query.client = @mock_client
    # `Parse::MongoDB.aggregate` is a real singleton method. Several tests
    # below stub it via define_singleton_method; capture the original here so
    # teardown can restore it, ensuring a stub (or a stub's `remove_method`
    # cleanup) never leaks the method's absence into a later test in the run.
    require_relative "../../../lib/parse/mongodb"
    @mongodb_aggregate_original =
      (Parse::MongoDB.method(:aggregate) if Parse::MongoDB.singleton_class.method_defined?(:aggregate))
  end

  def teardown
    restore_mongodb_stub
    restore_mongodb_aggregate
  end

  # Restore the real Parse::MongoDB.aggregate captured in setup (or remove a
  # leftover stub if it was never a real method). Idempotent.
  def restore_mongodb_aggregate
    if @mongodb_aggregate_original
      Parse::MongoDB.define_singleton_method(:aggregate, @mongodb_aggregate_original)
    elsif Parse::MongoDB.singleton_class.method_defined?(:aggregate)
      Parse::MongoDB.singleton_class.remove_method(:aggregate)
    end
  end

  # ---- GroupBy auto-promotion -------------------------------------------

  def test_group_by_promotes_when_session_token_set
    stub_mongodb_enabled!(true)
    @query.session_token = "r:test-session"

    gb = @query.group_by(:artist)
    assert_promotes_to_direct(gb, :count)
  end

  def test_group_by_promotes_when_acl_user_set
    stub_mongodb_enabled!(true)
    user = Parse::User.new(objectId: "u1")
    @query.scope_to_user(user)

    gb = @query.group_by(:artist)
    assert_promotes_to_direct(gb, :count)
  end

  def test_group_by_promotes_when_acl_role_set
    stub_mongodb_enabled!(true)
    @query.scope_to_role("Admin")

    gb = @query.group_by(:artist)
    assert_promotes_to_direct(gb, :count)
  end

  def test_group_by_stays_on_rest_when_no_scope
    stub_mongodb_enabled!(true)
    # Default Parse::Query has use_master_key = true and no token/scope.
    gb = @query.group_by(:artist)
    assert_stays_on_rest(gb, :count)
  end

  def test_group_by_fails_closed_when_scoped_and_mongodb_disabled
    stub_mongodb_enabled!(false)
    @query.session_token = "r:test-session"
    gb = @query.group_by(:artist)
    # Security: a SCOPED aggregation must NOT silently fall back to Parse
    # Server's REST /aggregate endpoint, which is master-key-only and
    # enforces neither ACL nor CLP — that would run the query unscoped as
    # the master key. With mongo-direct unavailable it fails closed.
    assert_raises(Parse::Query::MongoDirectRequired) { gb.count }
  end

  # ---- GroupByDate auto-promotion ---------------------------------------

  def test_group_by_date_promotes_when_session_token_set
    stub_mongodb_enabled!(true)
    @query.session_token = "r:test-session"

    gbd = @query.group_by_date(:created_at, :day)
    assert_date_promotes_to_direct(gbd, :count)
  end

  def test_group_by_date_stays_on_rest_when_no_scope
    stub_mongodb_enabled!(true)
    gbd = @query.group_by_date(:created_at, :day)
    assert_date_stays_on_rest(gbd, :count)
  end

  # ---- Query#distinct auto-promotion ------------------------------------

  def test_distinct_promotes_when_session_token_set
    stub_mongodb_enabled!(true)
    @query.session_token = "r:test-session"

    # The promoted path calls distinct_direct, which calls
    # Parse::MongoDB.aggregate (not @query.client.aggregate_pipeline).
    # We assert that the REST client is NOT called.
    assert_distinct_promotes_to_direct
  end

  def test_distinct_stays_on_rest_when_no_scope
    stub_mongodb_enabled!(true)
    assert_distinct_stays_on_rest
  end

  def test_distinct_fails_closed_when_scoped_and_mongodb_disabled
    stub_mongodb_enabled!(false)
    @query.session_token = "r:test-session"
    # Security: see test_group_by_fails_closed_when_scoped_and_mongodb_disabled.
    # A scoped distinct cannot fall back to REST /aggregate (unscoped master).
    assert_raises(Parse::Query::MongoDirectRequired) { @query.distinct(:artist) }
  end

  # ---- Query#count (aggregation-pipeline branch) -------------------------
  # `:field.size` compiles to an __aggregation_pipeline marker, forcing
  # #count and #results through the inline-Aggregation terminals that the
  # other tests above never reach.

  def test_count_aggregation_promotes_when_session_token_set
    stub_mongodb_enabled!(true)
    @query.session_token = "r:test-session"
    @query.where :tags.size => 2
    direct_called = false
    Parse::MongoDB.define_singleton_method(:aggregate) do |_class_name, _pipeline, **_kw|
      direct_called = true
      []
    end
    @query.count
    assert direct_called, "expected scoped #count (aggregation branch) to route through mongo-direct"
  ensure
    Parse::MongoDB.singleton_class.remove_method(:aggregate) if Parse::MongoDB.singleton_class.method_defined?(:aggregate)
  end

  def test_count_aggregation_stays_on_rest_when_no_scope
    stub_mongodb_enabled!(true)
    @query.where :tags.size => 2
    response = stub_response([])
    @mock_client.expect :aggregate_pipeline, response do |_table, _pipeline, **_kw|
      true
    end
    @query.count
    @mock_client.verify
  end

  def test_count_aggregation_fails_closed_when_scoped_and_mongodb_disabled
    stub_mongodb_enabled!(false)
    @query.session_token = "r:test-session"
    @query.where :tags.size => 2
    # Security: same contract as #aggregate / #distinct — a scoped count
    # must not fall back to REST /aggregate (master-key-only, unenforced).
    assert_raises(Parse::Query::MongoDirectRequired) { @query.count }
  end

  # ---- Query#results via execute_aggregation_pipeline --------------------

  def test_results_pipeline_promotes_when_session_token_set
    stub_mongodb_enabled!(true)
    @query.session_token = "r:test-session"
    @query.where :tags.size => 2
    direct_called = false
    Parse::MongoDB.define_singleton_method(:aggregate) do |_class_name, _pipeline, **_kw|
      direct_called = true
      []
    end
    @query.results
    assert direct_called, "expected scoped #results (pipeline branch) to route through mongo-direct"
  ensure
    Parse::MongoDB.singleton_class.remove_method(:aggregate) if Parse::MongoDB.singleton_class.method_defined?(:aggregate)
  end

  def test_results_pipeline_fails_closed_when_scoped_and_mongodb_disabled
    stub_mongodb_enabled!(false)
    @query.session_token = "r:test-session"
    @query.where :tags.size => 2
    assert_raises(Parse::Query::MongoDirectRequired) { @query.results }
  end

  # ---- RT-3: Query#aggregate must not let an explicit mongo_direct: false
  #       opt a scoped query out of ACL/CLP enforcement (REST /aggregate) ----

  PIPE = [{ "$group" => { "_id" => "$artist", "n" => { "$sum" => 1 } } }].freeze

  def test_aggregate_scoped_explicit_mongo_direct_false_fails_closed
    # The crux: an explicit mongo_direct: false on a SCOPED query must NOT
    # route to REST /aggregate (master-key-only, unenforced). With mongo-direct
    # unavailable it fails closed instead of silently leaking unscoped rows.
    stub_mongodb_enabled!(false)
    @query.scope_to_role("Admin")
    assert_raises(Parse::Query::MongoDirectRequired) do
      @query.aggregate(PIPE, mongo_direct: false)
    end
  end

  def test_aggregate_scoped_explicit_mongo_direct_false_promotes_when_ready
    stub_mongodb_enabled!(true)
    @query.scope_to_role("Admin")
    agg = @query.aggregate(PIPE, mongo_direct: false)
    assert agg.mongo_direct, "scoped aggregate must be promoted to mongo-direct despite mongo_direct: false"
  end

  def test_aggregate_scoped_session_token_explicit_false_fails_closed
    stub_mongodb_enabled!(false)
    @query.session_token = "r:test-session"
    assert_raises(Parse::Query::MongoDirectRequired) do
      @query.aggregate(PIPE, mongo_direct: false)
    end
  end

  def test_aggregate_unscoped_explicit_mongo_direct_false_stays_on_rest
    # Unscoped callers can still opt out to REST with an explicit false.
    stub_mongodb_enabled!(true)
    agg = @query.aggregate(PIPE, mongo_direct: false)
    refute agg.mongo_direct, "unscoped aggregate must honor explicit mongo_direct: false"
  end

  # ---- Ambient Parse.with_session scopes aggregations -------------------------
  # An active Parse.with_session(token) block sets a fiber-local session that
  # should scope aggregations just as it scopes REST find/get/count calls.
  # The query_is_scoped? / distinct_query_is_scoped? checks must consult
  # Parse.current_session_token so that GroupByDate / GroupBy / distinct /
  # count (aggregation branch) all auto-promote to mongo-direct (or fail closed
  # when mongo-direct is unavailable) rather than silently running as master
  # and returning unscoped rows.

  def test_group_by_date_ambient_session_promotes_to_direct
    stub_mongodb_enabled!(true)
    gbd = @query.group_by_date(:created_at, :day)
    Parse.with_session("r:ambient-tok") { assert_date_promotes_to_direct(gbd, :count) }
  end

  def test_group_by_date_ambient_session_fails_closed_when_mongodb_disabled
    stub_mongodb_enabled!(false)
    gbd = @query.group_by_date(:created_at, :day)
    assert_raises(Parse::Query::MongoDirectRequired) do
      Parse.with_session("r:ambient-tok") { gbd.count }
    end
  end

  def test_group_by_ambient_session_promotes_to_direct
    stub_mongodb_enabled!(true)
    gb = @query.group_by(:created_at)
    Parse.with_session("r:ambient-tok") { assert_promotes_to_direct(gb, :count) }
  end

  def test_group_by_ambient_session_fails_closed_when_mongodb_disabled
    stub_mongodb_enabled!(false)
    gb = @query.group_by(:created_at)
    assert_raises(Parse::Query::MongoDirectRequired) do
      Parse.with_session("r:ambient-tok") { gb.count }
    end
  end

  def test_distinct_ambient_session_promotes_to_direct
    stub_mongodb_enabled!(true)
    Parse.with_session("r:ambient-tok") { assert_distinct_promotes_to_direct }
  end

  def test_distinct_ambient_session_fails_closed_when_mongodb_disabled
    stub_mongodb_enabled!(false)
    assert_raises(Parse::Query::MongoDirectRequired) do
      Parse.with_session("r:ambient-tok") { @query.distinct(:artist) }
    end
  end

  def test_count_aggregation_ambient_session_promotes_to_direct
    stub_mongodb_enabled!(true)
    @query.where :tags.size => 2
    direct_called = false
    Parse::MongoDB.define_singleton_method(:aggregate) do |_class_name, _pipeline, **_kw|
      direct_called = true
      []
    end
    Parse.with_session("r:ambient-tok") { @query.count }
    assert direct_called, "expected scoped #count (ambient session) to route through mongo-direct"
  ensure
    Parse::MongoDB.singleton_class.remove_method(:aggregate) if Parse::MongoDB.singleton_class.method_defined?(:aggregate)
  end

  def test_count_aggregation_ambient_session_fails_closed_when_mongodb_disabled
    stub_mongodb_enabled!(false)
    @query.where :tags.size => 2
    assert_raises(Parse::Query::MongoDirectRequired) do
      Parse.with_session("r:ambient-tok") { @query.count }
    end
  end

  # ---- precedence: explicit use_master_key: true beats the ambient ----------
  # Parse::Client#request treats an explicit use_master_key: true as a
  # deliberate admin call that skips the ambient Parse.with_session token. The
  # scoping checks must mirror that: an admin aggregation inside a with_session
  # block must NOT be treated as scoped (no forced mongo-direct / fail-closed).

  def test_group_by_date_ambient_ignored_when_use_master_key_true
    # mongo-direct disabled: if the ambient were (wrongly) treated as scope this
    # would raise MongoDirectRequired. With use_master_key: true it must stay on
    # REST instead.
    stub_mongodb_enabled!(false)
    @query.use_master_key = true
    gbd = @query.group_by_date(:created_at, :day)
    response = stub_response([])
    @mock_client.expect(:aggregate_pipeline, response) { |_t, _p, **_kw| true }
    Parse.with_session("r:ambient-tok") { gbd.count }
    @mock_client.verify
  end

  def test_group_by_ambient_ignored_when_use_master_key_true
    stub_mongodb_enabled!(false)
    @query.use_master_key = true
    gb = @query.group_by(:created_at)
    response = stub_response([])
    @mock_client.expect(:aggregate_pipeline, response) { |_t, _p, **_kw| true }
    Parse.with_session("r:ambient-tok") { gb.count }
    @mock_client.verify
  end

  def test_distinct_query_is_scoped_ignores_ambient_when_use_master_key_true
    # Drive the predicate directly: with use_master_key: true an ambient session
    # must not register as scope.
    @query.use_master_key = true
    scoped = Parse.with_session("r:ambient-tok") { @query.send(:distinct_query_is_scoped?) }
    refute scoped, "explicit use_master_key: true must suppress the ambient session as scope"
  end

  def test_distinct_query_is_scoped_honors_ambient_without_master_key
    # Control: without use_master_key: true the ambient DOES count as scope.
    scoped = Parse.with_session("r:ambient-tok") { @query.send(:distinct_query_is_scoped?) }
    assert scoped, "ambient session must count as scope when master key is not forced"
  end

  def test_aggregate_ambient_session_promotes_to_direct
    # Query#aggregate returns an Aggregation object; the routing decision
    # (mongo_direct flag) is made at construction time by #aggregate itself.
    stub_mongodb_enabled!(true)
    agg = Parse.with_session("r:ambient-tok") { @query.aggregate(PIPE) }
    assert agg.mongo_direct,
           "Query#aggregate inside Parse.with_session must set mongo_direct: true on " \
           "the returned Aggregation so subsequent .results/.raw run through mongo-direct"
  end

  def test_aggregate_ambient_session_fails_closed_when_mongodb_disabled
    stub_mongodb_enabled!(false)
    assert_raises(Parse::Query::MongoDirectRequired) do
      Parse.with_session("r:ambient-tok") { @query.aggregate(PIPE) }
    end
  end

  def test_group_by_raw_ambient_session_promotes_to_direct
    stub_mongodb_enabled!(true)
    gb = @query.group_by(:artist)
    direct_called = false
    Parse::MongoDB.define_singleton_method(:aggregate) do |_class_name, _pipeline, **_kw|
      direct_called = true
      []
    end
    Parse.with_session("r:ambient-tok") { gb.raw("count", { "$sum" => 1 }) }
    assert direct_called,
           "GroupBy#raw must route through mongo-direct when ambient session is active " \
           "(not REST /aggregate as master, which would return unscoped rows)"
  ensure
    Parse::MongoDB.singleton_class.remove_method(:aggregate) if Parse::MongoDB.singleton_class.method_defined?(:aggregate)
  end

  def test_group_by_raw_ambient_session_fails_closed_when_mongodb_disabled
    stub_mongodb_enabled!(false)
    gb = @query.group_by(:artist)
    assert_raises(Parse::Query::MongoDirectRequired) do
      Parse.with_session("r:ambient-tok") { gb.raw("count", { "$sum" => 1 }) }
    end
  end

  def test_group_by_date_rest_respects_explicit_use_master_key_false
    # An unscoped query with explicit use_master_key: false (no ambient, no
    # scope) must still route to REST and forward the false flag.
    stub_mongodb_enabled!(false)
    @query.use_master_key = false
    gbd = @query.group_by_date(:created_at, :day)

    opts_received = nil
    response = stub_response([])
    @mock_client.expect(:aggregate_pipeline, response) do |_table, _pipeline, **kw|
      opts_received = kw
      true
    end

    gbd.count
    @mock_client.verify

    assert_equal false, opts_received[:use_master_key],
                 "explicit use_master_key: false must be respected on REST aggregate path"
  end

  private

  # Stub Parse::MongoDB.enabled? for the duration of one test. We don't
  # need to load the real mongodb shim — the SDK's auto-promotion path
  # already does `defined?(Parse::MongoDB) && Parse::MongoDB.enabled?`,
  # so just toggle the predicate.
  def stub_mongodb_enabled!(enabled)
    require_relative "../../../lib/parse/mongodb"
    @stubs ||= {}
    %i[enabled? available?].each do |m|
      @stubs[m] = Parse::MongoDB.method(m) if Parse::MongoDB.respond_to?(m)
      Parse::MongoDB.define_singleton_method(m) { enabled }
    end
    @stubs[:require_gem!] = Parse::MongoDB.method(:require_gem!) if Parse::MongoDB.respond_to?(:require_gem!)
    Parse::MongoDB.define_singleton_method(:require_gem!) { true }
  end

  def restore_mongodb_stub
    return unless @stubs
    @stubs.each do |name, original|
      next unless original
      Parse::MongoDB.define_singleton_method(name) { |*a, **kw, &b| original.call(*a, **kw, &b) }
    end
    @stubs = nil
  end

  # Assert that calling `op` on the GroupBy triggers the mongo-direct
  # path. We detect this by ensuring the REST `aggregate_pipeline`
  # client is NEVER called, AND that the direct path's distinguishing
  # call (`Parse::MongoDB.aggregate`) IS called.
  def assert_promotes_to_direct(group_by, op)
    direct_called = false
    Parse::MongoDB.define_singleton_method(:aggregate) do |_class_name, _pipeline, **_kw|
      direct_called = true
      []
    end
    # If the REST path is taken, the mock_client expectation we did NOT
    # set will fire and raise. So just don't set an expectation.
    group_by.public_send(op)
    assert direct_called, "expected Parse::MongoDB.aggregate to be called (mongo-direct path)"
  ensure
    # Remove the stub so other tests aren't affected.
    Parse::MongoDB.singleton_class.remove_method(:aggregate) if Parse::MongoDB.singleton_class.method_defined?(:aggregate)
  end

  def assert_stays_on_rest(group_by, op)
    # REST path calls @query.client.aggregate_pipeline. Set a stub
    # response and verify it WAS called.
    response = stub_response([])
    @mock_client.expect :aggregate_pipeline, response do |_table, _pipeline, **_kw|
      true
    end
    group_by.public_send(op)
    @mock_client.verify
  end

  def assert_date_promotes_to_direct(date_helper, op)
    direct_called = false
    Parse::MongoDB.define_singleton_method(:aggregate) do |_class_name, _pipeline, **_kw|
      direct_called = true
      []
    end
    date_helper.public_send(op)
    assert direct_called, "expected mongo-direct path for scoped group_by_date"
  ensure
    Parse::MongoDB.singleton_class.remove_method(:aggregate) if Parse::MongoDB.singleton_class.method_defined?(:aggregate)
  end

  def assert_date_stays_on_rest(date_helper, op)
    response = stub_response([])
    @mock_client.expect :aggregate_pipeline, response do |_table, _pipeline, **_kw|
      true
    end
    date_helper.public_send(op)
    @mock_client.verify
  end

  def assert_distinct_promotes_to_direct
    direct_called = false
    Parse::MongoDB.define_singleton_method(:aggregate) do |_class_name, _pipeline, **_kw|
      direct_called = true
      []
    end
    @query.distinct(:genre)
    assert direct_called, "expected scoped #distinct to route through mongo-direct"
  ensure
    Parse::MongoDB.singleton_class.remove_method(:aggregate) if Parse::MongoDB.singleton_class.method_defined?(:aggregate)
  end

  def assert_distinct_stays_on_rest
    response = stub_response([])
    @mock_client.expect :aggregate_pipeline, response do |_table, _pipeline, **_kw|
      true
    end
    @query.distinct(:genre)
    @mock_client.verify
  end

  def stub_response(rows)
    Class.new do
      define_method(:success?) { true }
      define_method(:error?) { false }
      define_method(:result) { rows }
    end.new
  end

end
