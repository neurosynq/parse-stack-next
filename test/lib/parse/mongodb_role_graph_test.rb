# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"

# Unit tests for Parse::MongoDB.role_names_for_user and .users_in_role_subtree.
# Pure unit tests — no Docker or live Mongo. The mongo gem IS in the bundle
# so we can reference ::Mongo::Error::OperationFailure for the timeout cases.
#
# Authorization contract under test:
# - Both helpers require an explicit `master: true` OR `as: <User|Pointer>`
#   kwarg. Calls without one (or with both) raise ArgumentError.
# - When `as:` is supplied, the scope's permission strings are checked
#   against `_Role` CLP via Parse::CLPScope.permits?; CLP denial raises
#   Parse::CLPScope::Denied.
# - Process-level `master_key_configured?` is NO LONGER a gate. It exists
#   only for backwards-compat introspection.
class MongoDBRoleGraphTest < Minitest::Test
  VALID_ID = "AHYeeptUZU"

  def setup
    Parse::MongoDB.reset! if Parse::MongoDB.respond_to?(:reset!)
    @captured_pipelines = {}
    @captured_opts = {}
    @original_master_key = capture_existing_master_key
    ensure_client_with_master_key!("master-key-for-tests")
  end

  def teardown
    Parse::MongoDB.reset! if Parse::MongoDB.respond_to?(:reset!)
    restore_master_key!(@original_master_key)
  end

  # ============================================================
  # Authorization gate — TRACK-MONGO-1
  # ============================================================

  def test_role_names_for_user_requires_master_or_as
    configure_with_pipeline_capture
    err = assert_raises(ArgumentError) do
      Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5)
    end
    assert_match(/authorization scope/, err.message)
    refute @captured_pipelines.key?("_Join:users:_Role"),
      "pipeline must not run without an authorization scope"
  end

  def test_users_in_role_subtree_requires_master_or_as
    configure_with_pipeline_capture
    err = assert_raises(ArgumentError) do
      Parse::MongoDB.users_in_role_subtree(VALID_ID, max_depth: 5)
    end
    assert_match(/authorization scope/, err.message)
    refute @captured_pipelines.key?("_Join:roles:_Role"),
      "pipeline must not run without an authorization scope"
  end

  def test_role_names_for_user_rejects_both_master_and_as
    user = Parse::User.new
    user.id = VALID_ID
    err = assert_raises(ArgumentError) do
      Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5,
                                          master: true, as: user)
    end
    assert_match(/mutually exclusive/, err.message)
  end

  def test_users_in_role_subtree_rejects_both_master_and_as
    user = Parse::User.new
    user.id = VALID_ID
    err = assert_raises(ArgumentError) do
      Parse::MongoDB.users_in_role_subtree(VALID_ID, max_depth: 5,
                                            master: true, as: user)
    end
    assert_match(/mutually exclusive/, err.message)
  end

  # ============================================================
  # CLP enforcement on `as:` scope — TRACK-MONGO-1
  # ============================================================

  def test_role_names_for_user_with_as_raises_clp_denied_when_role_clp_forbids
    configure_with_pipeline_capture(
      "_Join:users:_Role" => [{ "names" => ["Admin"] }],
    )
    # Master-only CLP: empty op-map → only master-key permitted.
    Parse::CLPScope.__cache_put(Parse::Model::CLASS_ROLE, clp: { "find" => {} })

    user = Parse::User.new
    user.id = VALID_ID
    err = assert_raises(Parse::CLPScope::Denied) do
      Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5, as: user)
    end
    assert_equal Parse::Model::CLASS_ROLE, err.class_name
    assert_equal :find, err.operation
    refute @captured_pipelines.key?("_Join:users:_Role"),
      "pipeline must not run when CLP denies the scope"
  ensure
    Parse::CLPScope.reset_cache!
  end

  def test_users_in_role_subtree_with_as_raises_clp_denied_when_role_clp_forbids
    configure_with_pipeline_capture(
      "_Join:roles:_Role" => [{ "user_ids" => [] }],
    )
    Parse::CLPScope.__cache_put(Parse::Model::CLASS_ROLE, clp: { "find" => {} })

    user = Parse::User.new
    user.id = VALID_ID
    err = assert_raises(Parse::CLPScope::Denied) do
      Parse::MongoDB.users_in_role_subtree(VALID_ID, max_depth: 5, as: user)
    end
    assert_equal Parse::Model::CLASS_ROLE, err.class_name
    refute @captured_pipelines.key?("_Join:roles:_Role"),
      "pipeline must not run when CLP denies the scope"
  ensure
    Parse::CLPScope.reset_cache!
  end

  def test_role_names_for_user_master_mode_bypasses_clp
    configure_with_pipeline_capture(
      "_Join:users:_Role" => [{ "names" => ["Admin"] }],
    )
    # Master-only CLP — master path must still succeed.
    Parse::CLPScope.__cache_put(Parse::Model::CLASS_ROLE, clp: { "find" => {} })

    result = Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5, master: true)
    assert_equal Set["Admin"], result
  ensure
    Parse::CLPScope.reset_cache!
  end

  # ============================================================
  # Master-key configured remains a metadata helper, NOT a gate
  # ============================================================

  def test_master_key_configured_still_introspects_client
    # Sanity check — the helper still exists for backwards-compat
    # callers, but is no longer used as the authorization gate.
    assert Parse::MongoDB.respond_to?(:master_key_configured?)
    assert_equal true, Parse::MongoDB.master_key_configured?
  end

  def test_role_names_for_user_returns_nil_when_mongo_not_configured
    Parse::MongoDB.reset!
    # `master: true` provides the auth, but availability fails closed.
    assert_nil Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5, master: true)
  end

  # ============================================================
  # Input validation
  # ============================================================

  def test_role_names_for_user_rejects_non_string_user_id
    err = assert_raises(ArgumentError) do
      Parse::MongoDB.role_names_for_user(12345, max_depth: 5, master: true)
    end
    assert_match(/user_id/, err.message)
  end

  def test_role_names_for_user_rejects_empty_user_id
    assert_raises(ArgumentError) do
      Parse::MongoDB.role_names_for_user("", max_depth: 5, master: true)
    end
  end

  def test_role_names_for_user_rejects_id_with_disallowed_chars
    %W[foo\x00bar foo.bar foo/bar #{"x" * 65}].each do |bad|
      assert_raises(ArgumentError, "should reject #{bad.inspect}") do
        Parse::MongoDB.role_names_for_user(bad, max_depth: 5, master: true)
      end
    end
  end

  def test_role_names_for_user_rejects_non_integer_depth
    assert_raises(ArgumentError) do
      Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: "5", master: true)
    end
  end

  # TRACK-MONGO-7: ROLE_GRAPH_MAX_DEPTH lowered from 20 to 6.
  def test_role_names_for_user_rejects_depth_above_max
    assert_raises(ArgumentError) do
      Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 7, master: true)
    end
  end

  def test_role_names_for_user_accepts_depth_at_max
    configure_with_pipeline_capture(
      "_Join:users:_Role" => [{ "names" => ["Admin"] }],
    )
    Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 6, master: true)
    pipeline = @captured_pipelines["_Join:users:_Role"]
    graph_stage = pipeline.find { |s| s.key?("$graphLookup") }
    # max_depth (Ruby) = 6 → graph_depth = 5
    assert_equal 5, graph_stage["$graphLookup"]["maxDepth"]
  end

  def test_role_graph_max_depth_constant_is_6
    # MONGO-7 cap lowered from 20 → 6 to neutralize the $graphLookup
    # DoS amplifier. Hardcoded here so a future bump regresses loudly.
    # The constant lives on the singleton_class because the role-graph
    # helpers are defined inside `class << self`.
    assert_equal 6, Parse::MongoDB.singleton_class::ROLE_GRAPH_MAX_DEPTH
  end

  def test_role_names_for_user_returns_empty_set_for_zero_depth
    # max_depth = 0 returns Set.new without touching Mongo
    configure_with_pipeline_capture
    result = Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 0, master: true)
    assert_equal Set.new, result
    refute @captured_pipelines.key?("_Join:users:_Role"),
      "no aggregation should run when max_depth is zero"
  end

  # ============================================================
  # Pipeline shape
  # ============================================================

  def test_forward_pipeline_runs_against_user_role_join
    configure_with_pipeline_capture(
      "_Join:users:_Role" => [{ "names" => ["Admin", "Editor"] }],
    )

    Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5, master: true)

    assert @captured_pipelines.key?("_Join:users:_Role"),
      "forward query must run against _Join:users:_Role"
  end

  def test_forward_pipeline_first_stage_matches_user_id
    configure_with_pipeline_capture(
      "_Join:users:_Role" => [{ "names" => [] }],
    )

    Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5, master: true)

    pipeline = @captured_pipelines["_Join:users:_Role"]
    assert_equal({ "$match" => { "relatedId" => VALID_ID } }, pipeline.first)
  end

  def test_forward_pipeline_uses_graphLookup_with_inheritance_join
    configure_with_pipeline_capture(
      "_Join:users:_Role" => [{ "names" => [] }],
    )

    Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5, master: true)

    pipeline = @captured_pipelines["_Join:users:_Role"]
    graph_stage = pipeline.find { |s| s.key?("$graphLookup") }
    refute_nil graph_stage
    g = graph_stage["$graphLookup"]
    assert_equal "_Join:roles:_Role", g["from"]
    assert_equal "$owningId", g["startWith"]
    assert_equal "owningId", g["connectFromField"]
    assert_equal "relatedId", g["connectToField"]
    # max_depth (Ruby) = 5 → graph_depth = 4
    assert_equal 4, g["maxDepth"]
  end

  def test_forward_pipeline_passes_max_time_ms_5000
    configure_with_pipeline_capture(
      "_Join:users:_Role" => [{ "names" => [] }],
    )

    Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5, master: true)

    assert_equal 5000, @captured_opts["_Join:users:_Role"][:max_time_ms]
  end

  def test_forward_returns_set_of_names_filtering_nils_and_blanks
    configure_with_pipeline_capture(
      "_Join:users:_Role" => [{ "names" => ["Admin", nil, "", "Editor"] }],
    )

    result = Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5, master: true)
    assert_equal Set.new(["Admin", "Editor"]), result
  end

  def test_forward_returns_empty_set_when_user_has_no_memberships
    configure_with_pipeline_capture(
      "_Join:users:_Role" => [],
    )

    assert_equal Set.new, Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5, master: true)
  end

  # ============================================================
  # Reverse pipeline
  # ============================================================

  def test_reverse_pipeline_runs_against_role_role_join
    configure_with_pipeline_capture(
      "_Join:roles:_Role" => [{ "user_ids" => ["userA", "userB"] }],
    )

    Parse::MongoDB.users_in_role_subtree(VALID_ID, max_depth: 5, master: true)

    assert @captured_pipelines.key?("_Join:roles:_Role"),
      "reverse query must run against _Join:roles:_Role"
  end

  def test_reverse_pipeline_graphLookup_walks_downward
    configure_with_pipeline_capture(
      "_Join:roles:_Role" => [{ "user_ids" => [] }],
    )

    Parse::MongoDB.users_in_role_subtree(VALID_ID, max_depth: 5, master: true)

    pipeline = @captured_pipelines["_Join:roles:_Role"]
    graph_stage = pipeline.find { |s| s.key?("$graphLookup") }
    g = graph_stage["$graphLookup"]
    # Reverse direction: connectFrom='relatedId' (child) connectTo='owningId'
    assert_equal "relatedId", g["connectFromField"]
    assert_equal "owningId", g["connectToField"]
  end

  def test_reverse_pipeline_filters_tombstoned_users
    configure_with_pipeline_capture(
      "_Join:roles:_Role" => [{ "user_ids" => [] }],
    )

    Parse::MongoDB.users_in_role_subtree(VALID_ID, max_depth: 5, master: true)

    pipeline = @captured_pipelines["_Join:roles:_Role"]
    user_lookup = pipeline.find { |s| s.dig("$lookup", "from") == "_User" }
    refute_nil user_lookup, "pipeline must $lookup _User to filter tombstones"
    serialized = pipeline.to_s
    assert_match(/_tombstone/, serialized,
      "pipeline must filter on _tombstone field")
  end

  def test_reverse_pipeline_master_mode_does_not_inject_rperm
    configure_with_pipeline_capture(
      "_Join:roles:_Role" => [{ "user_ids" => [] }],
    )

    Parse::MongoDB.users_in_role_subtree(VALID_ID, max_depth: 5, master: true)
    pipeline = @captured_pipelines["_Join:roles:_Role"]
    user_lookup = pipeline.find { |s| s.dig("$lookup", "from") == "_User" }
    user_pipeline = user_lookup["$lookup"]["pipeline"]
    match_stage = user_pipeline.first["$match"]
    # Master path: no _rperm filter in the sub-pipeline.
    refute match_stage.key?("$or"), "master-mode pipeline must not inject _rperm"
    refute match_stage.key?("_rperm"), "master-mode pipeline must not name _rperm"
  end

  # TRACK-MONGO-4: scoped path injects _rperm into the _User sub-pipeline.
  def test_reverse_pipeline_scoped_mode_injects_rperm_into_user_lookup
    configure_with_pipeline_capture(
      "_Join:roles:_Role" => [{ "user_ids" => [] }],
    )
    # CLP that permits the user to find on _Role so we get past the
    # CLP gate and reach the pipeline-build step.
    Parse::CLPScope.__cache_put(Parse::Model::CLASS_ROLE,
      clp: { "find" => { "*" => true } })

    user = Parse::User.new
    user.id = VALID_ID

    Parse::MongoDB.users_in_role_subtree(VALID_ID, max_depth: 5, as: user)
    pipeline = @captured_pipelines["_Join:roles:_Role"]
    user_lookup = pipeline.find { |s| s.dig("$lookup", "from") == "_User" }
    user_pipeline = user_lookup["$lookup"]["pipeline"]
    match_stage = user_pipeline.first["$match"]
    # Scoped path: _rperm $or-of-$in / $exists:false predicate from
    # Parse::ACL.read_predicate is folded into the join filter.
    or_clause = match_stage["$or"]
    refute_nil or_clause, "scoped pipeline must inject _rperm $or"
    assert or_clause.is_a?(Array), "_rperm injection must be a $or array"
    assert(or_clause.any? { |c| c.dig("_rperm", "$in").is_a?(Array) },
      "_rperm $or must include a $in branch")
    assert(or_clause.any? { |c| c["_rperm"] == { "$exists" => false } },
      "_rperm $or must include the documents-with-no-acl branch")
    # Tombstone filter still present (the scoped injection adds, not
    # replaces).
    assert match_stage.key?("_tombstone")
  ensure
    Parse::CLPScope.reset_cache!
  end

  def test_reverse_returns_set_of_user_ids
    configure_with_pipeline_capture(
      "_Join:roles:_Role" => [{ "user_ids" => ["userA", "userB"] }],
    )

    result = Parse::MongoDB.users_in_role_subtree(VALID_ID, max_depth: 5, master: true)
    assert_equal Set.new(["userA", "userB"]), result
  end

  # ============================================================
  # Error handling
  # ============================================================

  def test_forward_translates_code_50_to_execution_timeout
    configure_with_pipeline_capture(
      "_Join:users:_Role" => operation_failure_for(code: 50),
    )

    assert_raises(Parse::MongoDB::ExecutionTimeout) do
      Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5, master: true)
    end
  end

  def test_forward_reraises_other_operation_failures
    configure_with_pipeline_capture(
      "_Join:users:_Role" => operation_failure_for(code: 11_000),
    )

    err = assert_raises(::Mongo::Error::OperationFailure) do
      Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5, master: true)
    end
    refute_kind_of Parse::MongoDB::ExecutionTimeout, err
  end

  # ============================================================
  # Notifications
  # ============================================================

  def test_forward_emits_role_graph_notification
    configure_with_pipeline_capture(
      "_Join:users:_Role" => [{ "names" => ["Admin"] }],
    )

    events = []
    subscriber = ActiveSupport::Notifications.subscribe("parse.mongodb.role_graph") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    Parse::MongoDB.role_names_for_user(VALID_ID, max_depth: 5, master: true)

    assert_equal 1, events.size
    event = events.first
    assert_equal :forward, event.payload[:direction]
    assert_equal VALID_ID, event.payload[:target_id]
    assert_equal 5, event.payload[:depth]
    assert_equal 1, event.payload[:result_count]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # ============================================================
  # TRACK-MONGO-11: pipeline shape regression assertions
  # ============================================================

  def test_build_user_role_names_pipeline_shape_assertion_catches_regression
    # Direct exercise of the shape-assertion helper. If a future
    # change breaks the hardcoded shape (e.g. interpolates a caller
    # value into connectFromField), the builder raises at the boundary.
    bad_pipeline = [
      { "$match" => { "relatedId" => "AHYeeptUZU" } },
      { "$graphLookup" => {
          "from" => "_Join:roles:_Role",
          "startWith" => "$owningId",
          "connectFromField" => "evilField",  # mutated
          "connectToField" => "relatedId",
          "as" => "parent_chain",
          "maxDepth" => 4,
      } },
    ]
    err = assert_raises(RuntimeError) do
      Parse::MongoDB.assert_user_role_names_pipeline_shape!(
        bad_pipeline, "AHYeeptUZU", 4,
      )
    end
    assert_match(/connectFromField/, err.message)
  end

  def test_build_role_subtree_users_pipeline_shape_assertion_catches_regression
    bad_pipeline = [
      { "$match" => { "owningId" => "AHYeeptUZU" } },
      { "$graphLookup" => {
          "from" => "_Join:roles:_Role",
          "startWith" => "$relatedId",
          "connectFromField" => "relatedId",
          "connectToField" => "evilField",   # mutated
          "as" => "descendant_chain",
          "maxDepth" => 4,
      } },
    ]
    err = assert_raises(RuntimeError) do
      Parse::MongoDB.assert_role_subtree_users_pipeline_shape!(
        bad_pipeline, "AHYeeptUZU", 4,
      )
    end
    assert_match(/connectToField/, err.message)
  end

  # ============================================================
  # TRACK-MONGO-6: index_stats requires explicit master
  # ============================================================

  def test_index_stats_without_master_degrades_to_empty
    # The auth check raises ArgumentError; the method's own
    # rescue catches it and returns {} so describe.rb-style callers
    # continue to work. The loud signal is preserved for any new
    # caller that introspects the raw exception (tests, debuggers).
    configure_with_pipeline_capture
    result = Parse::MongoDB.index_stats("SomeClass")
    assert_equal({}, result)
  end

  private

  def capture_existing_master_key
    return :no_client unless Parse::Client.client?
    Parse.client.master_key
  end

  def restore_master_key!(value)
    return if value == :no_client
    return unless Parse::Client.client?
    Parse.client.instance_variable_set(:@master_key, value)
  end

  def ensure_client_with_master_key!(master_key)
    if Parse::Client.client?
      Parse.client.instance_variable_set(:@master_key, master_key)
    else
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        master_key: master_key,
      )
    end
  end

  def clear_master_key!
    return unless Parse::Client.client?
    Parse.client.instance_variable_set(:@master_key, nil)
  end

  def configure_with_pipeline_capture(results_or_errors = {})
    captured_pipelines = @captured_pipelines
    captured_opts = @captured_opts

    mock_client = Object.new
    mock_client.define_singleton_method(:[]) do |coll_name|
      mock_collection = Object.new
      mock_collection.define_singleton_method(:aggregate) do |pipeline, opts = {}|
        captured_pipelines[coll_name] = pipeline
        captured_opts[coll_name] = opts
        configured = results_or_errors[coll_name]
        view = Object.new
        view.define_singleton_method(:to_a) do
          raise configured if configured.is_a?(StandardError)
          configured || []
        end
        view
      end
      mock_collection
    end

    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, "mongodb://localhost:27017/test")
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@client, mock_client)
  end

  def operation_failure_for(code:)
    require "mongo"
    instance = ::Mongo::Error::OperationFailure.allocate
    StandardError.instance_method(:initialize)
      .bind(instance).call("MongoDB operation failure (code: #{code})")
    instance.define_singleton_method(:code) { code }
    instance
  end
end
