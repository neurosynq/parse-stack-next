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
  end

  def teardown
    restore_mongodb_stub
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
