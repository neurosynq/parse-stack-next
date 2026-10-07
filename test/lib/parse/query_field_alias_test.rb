# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# A property declared with an explicit remote name (`field:`) must be queried
# by that exact name. Before 5.8 queries camel-cased every key, so
# `where(account_id:)` compiled to `accountId` and `"authId_sub"` to
# `authIdSub`, silently matching nothing on systems whose columns use
# underscores or mixed casing.
class QueryFieldAliasTest < Minitest::Test
  class ExtAccount < Parse::Object
    parse_class "FieldAliasExtAccount"
    property :account_id, :string, field: :account_id
    property :auth_id_sub, :string, field: :authId_sub
    property :plain_name, :string
    belongs_to :owner_ref, as: :field_alias_ext_owner, field: :owner_ref
  end

  class ExtOwner < Parse::Object
    parse_class "FieldAliasExtOwner"
    property :legacy_code, :string, field: :legacy_code
  end

  def test_where_uses_declared_names_for_ruby_and_remote_keys
    q = ExtAccount.query(account_id: "A1", auth_id_sub: "S1", plain_name: "p")
    assert_equal({ "account_id" => "A1", "authId_sub" => "S1", "plainName" => "p" }, q.compile_where)
    q = ExtAccount.query("account_id" => "A1", "authId_sub" => "S1")
    assert_equal({ "account_id" => "A1", "authId_sub" => "S1" }, q.compile_where)
  end

  def test_operators_order_keys_and_includes_use_declared_names
    q = ExtAccount.query(:account_id.in => %w[A1 A2], :auth_id_sub.exists => true)
                  .order(:auth_id_sub.desc).keys(:account_id, :plain_name).includes(:owner_ref)
    compiled = q.compile(encode: false)
    assert_equal({ "$in" => %w[A1 A2] }, q.compile_where["account_id"].transform_keys(&:to_s))
    assert_equal({ :$exists => true }.transform_keys(&:to_s), q.compile_where["authId_sub"].transform_keys(&:to_s))
    assert_equal "-authId_sub", compiled[:order]
    assert_equal "account_id,plainName,owner_ref", compiled[:keys]
    assert_equal "owner_ref", compiled[:include]
  end

  def test_undeclared_names_keep_default_formatting
    assert_equal({ "plainName" => "p" }, ExtAccount.query(plain_name: "p").compile_where)
  end

  def test_unrelated_class_is_unaffected
    q = Parse::Query.new("SomeOtherClass", account_id: "A1")
    assert_equal({ "accountId" => "A1" }, q.compile_where)
  end

  def test_subquery_uses_its_own_class_aliases
    inner = ExtOwner.query(legacy_code: "L1")
    q = ExtAccount.query(:owner_ref.in_query => inner, account_id: "A1")
    where = q.compile_where
    assert_equal "A1", where["account_id"]
    assert_equal({ "legacy_code" => "L1" }, where.dig("owner_ref", :$inQuery, :where) || where.dig("owner_ref", "$inQuery", "where"))
  end

  def test_scope_does_not_leak_between_threads
    seen = {}
    q = Queue.new
    t1 = Thread.new do
      Parse::Query.with_field_aliases("FieldAliasExtAccount") do
        q.pop
        seen[:aliased] = Parse::Query.format_field("account_id")
      end
    end
    t2 = Thread.new do
      q << :go
      seen[:plain] = Parse::Query.format_field("account_id")
    end
    [t1, t2].each(&:join)
    assert_equal "account_id", seen[:aliased]
    assert_equal "accountId", seen[:plain]
  end

  # ---- review hardening ----------------------------------------------------

  class StatsDoc < Parse::Object
    parse_class "FieldAliasStats"
    property :ext_id, :string, field: :ExternalID
    property :play_count, :integer
    property :seen_at, :date, field: :Seen_At
  end

  class InternalDoc < Parse::Object
    parse_class "FieldAliasInternal"
    property :hash_ref, :string, field: :_hashed_password
  end

  # Raised by stubbed aggregate/fetch entry points to hand the built request
  # back to the test without touching the network.
  class Captured < StandardError
    attr_reader :value
    def initialize(value)
      @value = value
      super("captured")
    end
  end

  class AggregateClient
    def aggregate_pipeline(_table, pipeline, **)
      raise Captured.new(pipeline)
    end
  end

  def capture_aggregate(query)
    query.define_singleton_method(:aggregate) { |pipeline, **| raise Captured.new(pipeline) }
    client = AggregateClient.new
    query.define_singleton_method(:client) { client }
    yield
    flunk "aggregate was not called"
  rescue Captured => e
    e.value
  end

  def group_stage(pipeline)
    pipeline.find { |stage| stage.key?("$group") }["$group"]
  end

  def test_group_by_aggregations_use_declared_names
    group = StatsDoc.query.group_by(:ext_id)
    pipeline = capture_aggregate(group.instance_variable_get(:@query)) { group.sum(:ext_id) }
    assert_equal({ "_id" => "$ExternalID", "count" => { "$sum" => "$ExternalID" } }, group_stage(pipeline))

    group = StatsDoc.query.group_by(:ext_id)
    pipeline = capture_aggregate(group.instance_variable_get(:@query)) { group.sum(:play_count) }
    assert_equal({ "_id" => "$ExternalID", "count" => { "$sum" => "$playCount" } }, group_stage(pipeline))

    assert_equal "$ExternalID", group_stage(StatsDoc.query.group_by(:ext_id).pipeline)["_id"]
  end

  def test_group_by_date_uses_declared_names
    group = StatsDoc.query(ext_id: "x").group_by_date(:seen_at, :day)
    pipeline = group.pipeline
    assert_equal({ "ExternalID" => "x" }, pipeline.first["$match"])
    assert_equal({ "$year" => "$Seen_At" }, group_stage(pipeline)["_id"]["year"])

    pipeline = capture_aggregate(group.instance_variable_get(:@query)) { group.sum(:ext_id) }
    assert_equal({ "$sum" => "$ExternalID" }, group_stage(pipeline)["count"])
    assert_equal({ "$dayOfMonth" => "$Seen_At" }, group_stage(pipeline)["_id"]["day"])
  end

  def test_aggregation_match_stage_uses_declared_names
    pipeline = StatsDoc.query(ext_id: "x").aggregate([{ "$limit" => 1 }]).pipeline
    assert_equal [{ "$match" => { "ExternalID" => "x" } }, { "$limit" => 1 }], pipeline
  end

  def test_direct_pipeline_uses_declared_names
    pipeline = StatsDoc.query(ext_id: "x").order(:ext_id.desc).keys(:ext_id)
                       .send(:build_direct_mongodb_pipeline)
    assert_equal({ "ExternalID" => "x" }, pipeline.find { |s| s.key?("$match") }["$match"])
    assert_equal({ "ExternalID" => -1 }, pipeline.find { |s| s.key?("$sort") }["$sort"])
    assert_equal 1, pipeline.find { |s| s.key?("$project") }["$project"]["ExternalID"]
  end

  def test_query_sum_formats_the_declared_name
    query = StatsDoc.query
    pipeline = capture_aggregate(query) { query.sum(:ext_id) }
    assert_equal({ "_id" => nil, "total" => { "$sum" => "$ExternalID" } }, group_stage(pipeline))
    assert_nil Parse::Query.field_alias_table, "the scope must be closed after the call"
  end

  # ---- user blocks and other classes' keys ---------------------------------

  FakeResponse = Struct.new(:results, :error) do
    def error?
      !error.nil?
    end
  end

  # Fetch client that records the query it was sent, then stops the fetch.
  class RecordingClient
    attr_reader :queries
    def initialize
      @queries = []
    end

    def fetch_object(_klass, _id, query: nil, **)
      @queries << query
      raise Captured.new(query)
    end
  end

  def stub_single_page(query, rows)
    pages = [rows]
    query.define_singleton_method(:fetch!) { |_compiled| FakeResponse.new(pages.shift || [], nil) }
    query
  end

  def test_results_block_runs_outside_the_query_scope
    query = stub_single_page(ExtAccount.query.limit(1),
                             [{ "objectId" => "a1", "className" => "FieldAliasExtAccount" }])
    seen = []
    query.results do |_obj|
      seen << Parse::Query.format_field(:account_id)
      seen << Parse::Query.field_alias_table
    end
    assert_equal ["accountId", nil], seen
  end

  def test_results_block_restores_an_enclosing_scope
    query = stub_single_page(ExtAccount.query.limit(1),
                             [{ "objectId" => "a1", "className" => "FieldAliasExtAccount" }])
    seen = nil
    Parse::Query.with_field_aliases("FieldAliasExtOwner") do
      query.results { |_obj| seen = Parse::Query.field_alias_table }
    end
    assert_equal "FieldAliasExtOwner", seen
  end

  def test_pointer_fetch_inside_results_block_uses_its_own_class
    query = stub_single_page(ExtAccount.query.limit(1),
                             [{ "objectId" => "a1", "className" => "FieldAliasExtAccount" }])
    client = RecordingClient.new
    pointer = Parse::Pointer.new("FieldAliasExtOwner", "o1")
    pointer.define_singleton_method(:client) { client }
    query.results do |_obj|
      begin
        pointer.fetch(keys: [:account_id, :legacy_code])
      rescue Captured
      end
      begin
        pointer.fetch_json(keys: [:account_id])
      rescue Captured
      end
    end
    assert_equal ["accountId,legacy_code", "accountId"], client.queries.map { |q| q[:keys] }
  end

  def test_pointer_and_object_fetch_use_their_class_aliases_without_a_query
    client = RecordingClient.new
    pointer = Parse::Pointer.new("FieldAliasExtAccount", "a1")
    pointer.define_singleton_method(:client) { client }
    assert_raises(Captured) { pointer.fetch(keys: [:account_id, :auth_id_sub, :plain_name]) }

    owner = ExtOwner.new
    owner.instance_variable_set(:@id, "o1")
    owner.define_singleton_method(:client) { client }
    validate = Parse.validate_query_keys
    Parse.validate_query_keys = false
    begin
      assert_raises(Captured) { owner.fetch!(keys: [:legacy_code, :account_id]) }
    ensure
      Parse.validate_query_keys = validate
    end
    assert_raises(Captured) { owner.fetch_json(keys: [:legacy_code]) }

    assert_equal ["account_id,authId_sub,plainName", "legacy_code,accountId", "legacy_code"],
                 client.queries.map { |q| q[:keys] }
  end

  def test_fetched_keys_use_the_object_class_aliases
    owner = ExtOwner.new
    owner.fetched_keys = [:legacy_code, :account_id]
    assert_includes owner.fetched_keys, :legacy_code
    assert_includes owner.fetched_keys, :accountId

    built = Parse::Object.build({ "objectId" => "a1", "className" => "FieldAliasExtAccount" },
                                "FieldAliasExtAccount", fetched_keys: [:account_id, :auth_id_sub])
    assert_includes built.fetched_keys, :account_id
    assert_includes built.fetched_keys, :authId_sub

    # Inside another class's query scope the object's own names still win.
    Parse::Query.with_field_aliases("FieldAliasExtAccount") do
      owner.fetched_keys = [:account_id]
    end
    assert_includes owner.fetched_keys, :accountId
  end

  def test_cursor_constraint_uses_the_query_class_aliases
    cursor = ExtAccount.query.cursor(limit: 10, order: :auth_id_sub.desc)
    cursor.instance_variable_set(:@last_order_value, "v")
    cursor.instance_variable_set(:@last_object_id, "a1")
    constraint = Parse::Query.with_field_aliases("FieldAliasExtOwner") do
      cursor.send(:build_cursor_constraint)
    end
    assert_includes constraint.inspect, "authId_sub"
    refute_includes constraint.inspect, "authIdSub"
  end

  # ---- scope storage and caching -------------------------------------------

  def test_scope_is_inherited_by_child_threads_and_fibers_without_leaking_back
    seen = {}
    Parse::Query.with_field_aliases("FieldAliasExtAccount") do
      Thread.new do
        seen[:thread] = Parse::Query.format_field("account_id")
        Parse::Query.with_field_aliases("FieldAliasExtOwner") { seen[:inner] = Parse::Query.field_alias_table }
      end.join
      Fiber.new { seen[:fiber] = Parse::Query.format_field("account_id") }.resume
      seen[:after] = Parse::Query.field_alias_table
    end
    assert_equal "account_id", seen[:thread]
    assert_equal "account_id", seen[:fiber]
    assert_equal "FieldAliasExtOwner", seen[:inner]
    assert_equal "FieldAliasExtAccount", seen[:after]
  end

  def test_alias_cache_tracks_later_declarations
    klass = Class.new(Parse::Object) do
      def self.name
        "QueryFieldAliasTest::LateDoc"
      end
      parse_class "FieldAliasLateDoc"
    end
    assert_equal({}, Parse::Query.field_aliases_for("FieldAliasLateDoc"))
    klass.property :late_code, :string, field: :late_code
    assert_equal "late_code", Parse::Query.field_aliases_for("FieldAliasLateDoc")["late_code"]
    klass.belongs_to :late_owner, as: :field_alias_ext_owner, field: :late_owner
    assert_equal "late_owner", Parse::Query.field_aliases_for("FieldAliasLateDoc")["late_owner"]
  end

  def test_find_class_miss_is_cached_until_a_model_is_defined
    name = "FieldAliasNotYetDefined"
    assert_nil Parse::Model.find_class(name)
    assert Parse::Model.model_cache_misses.key?(name)
    klass = Class.new(Parse::Object) do
      def self.name
        "QueryFieldAliasTest::NotYetDefined"
      end
    end
    klass.parse_class name
    assert_equal klass, Parse::Model.find_class(name)
  end

  def test_formatter_nil_users_see_no_change_for_default_names
    previous = Parse::Query.field_formatter
    Parse::Query.field_formatter = nil
    q = StatsDoc.query(play_count: 1, ext_id: "x")
    assert_equal({ "play_count" => 1, "ExternalID" => "x" }, q.compile_where)
  ensure
    Parse::Query.field_formatter = previous
  end

  def test_builtin_acl_key_is_unchanged
    assert_equal({ "acl" => 1 }.keys, StatsDoc.query(acl: 1).compile_where.keys)
  end

  def test_declared_column_name_passes_verbatim
    assert_equal({ "ExternalID" => "x" }, StatsDoc.query("ExternalID" => "x").compile_where)
  end

  def test_alias_never_targets_an_internal_column
    refute_includes Parse::Query.field_aliases_for("FieldAliasInternal").values, "_hashed_password"
  end

  def test_wrapped_private_methods_stay_private
    assert Parse::Query.private_method_defined?(:build_query_aggregate_pipeline),
           "wrapping must not make a private builder public"
  end
end
