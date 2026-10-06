# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
require "parse/pipeline_security"
require "parse/clp_scope"
require "parse/acl_scope"

# REST vs mongo-direct parity for CLP enforcement inside
# Parse::MongoDB.aggregate. Parse Server enforces all of this on REST
# find; the direct path bypasses Parse Server, so the SDK must:
#
# * refuse a filter or sort that names a protected field (REST error 119),
#   including dotted, `_p_`, `$or`, `$geoNear`, and joined-class forms;
# * evaluate the find CLP with Parse Server's branch semantics, so
#   `readUserFields` constrains rows and a public grant is not narrowed by
#   `pointerFields`;
# * apply the pointer-permission constraint BEFORE `$limit` / `$count`;
# * strip each included class's protectedFields and Parse Server's default
#   `_User.email` protection, top-level keys only.
#
# No live MongoDB: Parse::MongoDB.collection is stubbed with a collection
# that records the pipeline it receives and returns seeded rows.
class ParityAuditMongoDirectCLPTest < Minitest::Test
  class FakeCollection
    attr_reader :pipelines

    def initialize(rows = [])
      @rows = rows
      @pipelines = []
    end

    def aggregate(pipeline, _opts = {})
      @pipelines << pipeline
      Marshal.load(Marshal.dump(@rows))
    end

    def with(*)
      self
    end
  end

  USER_ID = "aliceUid01"

  def setup
    Parse.setup(server_url: "http://localhost:1337/parse",
                application_id: "test", api_key: "test") unless Parse::Client.client?
    Parse::CLPScope.reset_cache!
    Parse::CLPScope.default_protected_fields = nil
  end

  def teardown
    Parse::CLPScope.reset_cache!
    Parse::CLPScope.default_protected_fields = nil
  end

  def scoped(user_id = USER_ID, perms: nil)
    Parse::ACLScope::Resolution.new(
      mode: :session,
      permission_strings: perms || ["*", user_id],
      user_id: user_id,
      session: nil,
      client: nil,
    )
  end

  def role_only
    Parse::ACLScope::Resolution.new(mode: :public, permission_strings: ["*", "role:Ops"],
                                    user_id: nil, session: nil, client: nil)
  end

  def master
    Parse::ACLScope::Resolution.new(mode: :master, permission_strings: nil, user_id: nil,
                                    session: nil, client: nil)
  end

  # Run Parse::MongoDB.aggregate with a fixed resolution and a fake collection.
  def run_aggregate(class_name, pipeline, resolution, rows: [])
    coll = FakeCollection.new(rows)
    results = nil
    Parse::ACLScope.stub(:resolve!, ->(*_a, **_k) { resolution }) do
      Parse::MongoDB.stub(:collection, ->(*_a, **_k) { coll }) do
        results = Parse::MongoDB.aggregate(class_name, pipeline, session_token: "r:stub")
      end
    end
    [results, coll.pipelines.last]
  end

  def public_clp(extra = {})
    { "find" => { "*" => true }, "count" => { "*" => true } }.merge(extra)
  end

  # ---------------------------------------------------------------- P-S1

  def test_match_on_protected_field_is_refused
    Parse::CLPScope.__cache_put("PItem", clp: public_clp("protectedFields" => { "*" => ["secret"] }))
    err = assert_raises(Parse::CLPScope::Denied) do
      run_aggregate("PItem", [{ "$match" => { "secret" => "aaa" } }], scoped)
    end
    assert_match(/not allowed to query secret/, err.message)
  end

  def test_protected_filter_refused_in_or_dotted_and_storage_forms
    Parse::CLPScope.__cache_put("PItem", clp: public_clp("protectedFields" => { "*" => ["secret", "owner"] }))
    [
      { "$or" => [{ "name" => "x" }, { "secret" => { "$regex" => "^a" } }] },
      { "$and" => [{ "$nor" => [{ "secret.sub" => 1 }] }] },
      { "_p_owner" => "_User$abc" },
      { "$expr" => { "$gt" => ["$secret", "m"] } },
    ].each do |filter|
      assert_raises(Parse::CLPScope::Denied, "expected refusal for #{filter.inspect}") do
        run_aggregate("PItem", [{ "$match" => filter }], scoped)
      end
    end
  end

  def test_sort_on_protected_field_is_refused
    Parse::CLPScope.__cache_put("PItem", clp: public_clp("protectedFields" => { "*" => ["secret"] }))
    assert_raises(Parse::CLPScope::Denied) do
      run_aggregate("PItem", [{ "$sort" => { "secret" => 1 } }], scoped)
    end
  end

  def test_geo_near_query_on_protected_field_is_refused
    Parse::CLPScope.__cache_put("PItem", clp: public_clp("protectedFields" => { "*" => ["secret"] }))
    stage = { "$geoNear" => { "near" => { "type" => "Point", "coordinates" => [0, 0] },
                              "distanceField" => "d", "query" => { "secret" => "x" } } }
    assert_raises(Parse::CLPScope::Denied) { run_aggregate("PItem", [stage], scoped) }
  end

  def test_unprotected_nested_key_of_object_column_is_allowed
    # `meta.secret` is a sub-key of an unprotected object column. Parse
    # Server protects top-level columns only, so REST allows this filter.
    Parse::CLPScope.__cache_put("PItem", clp: public_clp("protectedFields" => { "*" => ["secret"] }))
    results, = run_aggregate("PItem", [{ "$match" => { "meta.secret" => "inner" } }], scoped)
    assert_equal [], results
  end

  def test_master_may_filter_on_protected_field
    Parse::CLPScope.__cache_put("PItem", clp: public_clp("protectedFields" => { "*" => ["secret"] }))
    _results, pipeline = run_aggregate("PItem", [{ "$match" => { "secret" => "aaa" } }], master)
    assert_equal [{ "$match" => { "secret" => "aaa" } }], pipeline
  end

  def test_role_exempt_from_protection_may_filter
    Parse::CLPScope.__cache_put("PItem", clp: public_clp(
      "protectedFields" => { "*" => ["secret"], "role:Ops" => [] },
    ))
    run_aggregate("PItem", [{ "$match" => { "secret" => "aaa" } }], role_only)
  end

  def test_join_filter_on_joined_class_protected_field_is_refused
    Parse::CLPScope.__cache_put("PItem", clp: public_clp)
    Parse::CLPScope.__cache_put("PRef", clp: public_clp("protectedFields" => { "*" => ["hidden"] }))
    lookup = { "$lookup" => {
      "from" => "PRef", "let" => { "id" => "$_p_ref" },
      "pipeline" => [{ "$match" => { "hidden" => "H1" } }], "as" => "_j",
    } }
    err = assert_raises(Parse::CLPScope::Denied) { run_aggregate("PItem", [lookup], scoped) }
    assert_match(/hidden on class PRef/, err.message)
  end

  def test_user_email_filter_is_refused_by_default_protection
    Parse::CLPScope.__cache_put("_User", clp: public_clp)
    err = assert_raises(Parse::CLPScope::Denied) do
      run_aggregate("_User", [{ "$match" => { "email" => "bob@example.com" } }], scoped)
    end
    assert_match(/email/, err.message)
  end

  # ------------------------------------------------- P-S2 / P2 / P1

  def test_read_user_fields_constrain_rows_in_pipeline_before_limit
    Parse::CLPScope.__cache_put("PRuf", clp: {
      "find" => { "requiresAuthentication" => true },
      "readUserFields" => ["owner"],
    })
    _r, pipeline = run_aggregate("PRuf", [{ "$limit" => 1 }], scoped)
    front = pipeline.first["$match"]
    assert front.to_s.include?("_User$#{USER_ID}"), "pointer predicate must lead the pipeline: #{pipeline.inspect}"
    assert_equal({ "$limit" => 1 }, pipeline.last)
  end

  def test_pointer_fields_constraint_runs_before_count
    Parse::CLPScope.__cache_put("PPf", clp: { "find" => { "pointerFields" => ["owner"] } })
    results, pipeline = run_aggregate("PPf", [{ "$count" => "count" }], scoped, rows: [{ "count" => 2 }])
    assert_equal [{ "count" => 2 }], results, "count row must survive; it has no pointer column"
    assert pipeline.first["$match"].to_s.include?("_p_owner")
  end

  def test_pointer_fields_predicate_matches_pointer_and_pointer_array_storage
    pred = Parse::CLPScope.pointer_fields_predicate(["owner", "editors"], "u1")
    assert_includes pred["$or"], { "_p_owner" => "_User$u1" }
    assert_includes pred["$or"], { "editors" => { "$elemMatch" => { "className" => "_User", "objectId" => "u1" } } }
  end

  def test_public_grant_is_not_narrowed_by_pointer_fields
    Parse::CLPScope.__cache_put("PPf", clp: { "find" => { "*" => true, "pointerFields" => ["owner"] } })
    _r, pipeline = run_aggregate("PPf", [], scoped)
    refute pipeline.to_s.include?("_p_owner"), "a public grant permits every row: #{pipeline.inspect}"
  end

  def test_pointer_only_clp_denies_scope_without_user
    Parse::CLPScope.__cache_put("PPf", clp: { "find" => { "pointerFields" => ["owner"] } })
    err = assert_raises(Parse::CLPScope::Denied) { run_aggregate("PPf", [], role_only) }
    assert_match(/requires user identity/, err.message)
  end

  def test_requires_authentication_denies_role_only_scope
    Parse::CLPScope.__cache_put("PAuth", clp: { "find" => { "requiresAuthentication" => true } })
    assert_raises(Parse::CLPScope::Denied) { run_aggregate("PAuth", [], role_only) }
  end

  def test_row_constraint_for_master_is_nil
    Parse::CLPScope.__cache_put("PPf", clp: { "find" => { "pointerFields" => ["owner"] } })
    assert_nil Parse::CLPScope.row_constraint_for!("PPf", :find, master)
  end

  def test_unresolvable_clp_fails_closed
    failing = Object.new
    def failing.schema(_c) = raise(Net::ReadTimeout, "stub")
    Parse::CLPScope.schema_client = failing
    _o, _e = capture_io do
      assert_raises(Parse::CLPScope::Denied) do
        Parse::CLPScope.row_constraint_for!("Nope", :find, scoped)
      end
    end
  ensure
    Parse::CLPScope.schema_client = nil
  end

  def test_search_helpers_share_the_row_constraint
    require "parse/atlas_search"
    require "parse/vector_search"
    require "parse/vector_search/hybrid"
    Parse::CLPScope.__cache_put("PRuf", clp: {
      "find" => { "requiresAuthentication" => true }, "readUserFields" => ["owner"],
    })
    Parse::CLPScope.__cache_put("PPub", clp: { "find" => { "*" => true, "pointerFields" => ["owner"] } })
    [Parse::AtlasSearch, Parse::VectorSearch, Parse::VectorSearch::Hybrid].each do |mod|
      assert_equal ["owner"], mod.send(:resolve_pointer_fields!, "PRuf", scoped), mod.name
      assert_nil mod.send(:resolve_pointer_fields!, "PPub", scoped), mod.name
      assert_raises(Parse::CLPScope::Denied, mod.name) { mod.send(:assert_clp_find!, "PRuf", role_only) }
    end
  end

  # ------------------------------------------------------ P-S3 / P8

  def test_included_class_protected_fields_are_stripped
    Parse::CLPScope.__cache_put("PItem", clp: public_clp)
    Parse::CLPScope.__cache_put("PRef", clp: public_clp("protectedFields" => { "*" => ["hidden"] }))
    pipeline = [
      { "$lookup" => { "from" => "PRef", "localField" => "_include_id_ref", "foreignField" => "_id", "as" => "_included_ref" } },
    ]
    rows = [{ "_id" => "i1", "_p_ref" => "PRef$r1", "_included_ref" => { "_id" => "r1", "label" => "L", "hidden" => "H" } }]
    results, = run_aggregate("PItem", pipeline, scoped, rows: rows)
    assert_equal({ "_id" => "r1", "label" => "L" }, results.first["_included_ref"])
  end

  def test_included_user_email_stripped_except_for_self
    Parse::CLPScope.__cache_put("PItem", clp: public_clp)
    Parse::CLPScope.__cache_put("_User", clp: public_clp)
    pipeline = [
      { "$lookup" => { "from" => "_User", "localField" => "_include_id_owner", "foreignField" => "_id", "as" => "_included_owner" } },
    ]
    rows = [
      { "_id" => "i1", "_included_owner" => { "_id" => "bobUid", "username" => "bob", "email" => "bob@x" } },
      { "_id" => "i2", "_included_owner" => { "_id" => USER_ID, "username" => "alice", "email" => "alice@x" } },
    ]
    results, = run_aggregate("PItem", pipeline, scoped, rows: rows)
    refute results[0]["_included_owner"].key?("email"), "another user's email is protected by default"
    assert_equal "alice@x", results[1]["_included_owner"]["email"], "a user sees their own email"
  end

  def test_user_rows_strip_other_users_email
    Parse::CLPScope.__cache_put("_User", clp: public_clp)
    rows = [{ "_id" => "bobUid", "email" => "bob@x" }, { "_id" => USER_ID, "email" => "alice@x" }]
    results, = run_aggregate("_User", [], scoped, rows: rows)
    assert_nil results[0]["email"]
    assert_equal "alice@x", results[1]["email"]
  end

  def test_default_protection_can_be_disabled
    Parse::CLPScope.__cache_put("_User", clp: public_clp)
    Parse::CLPScope.default_protected_fields = {}
    assert_empty Parse::CLPScope.protected_fields_for("_User", ["*", USER_ID])
  end

  def test_default_protection_merges_with_stored_groups
    # A role whose group lists nothing relaxes the default, as on Parse
    # Server where the server-config default is merged into the CLP.
    Parse::CLPScope.__cache_put("_User", clp: public_clp("protectedFields" => { "role:Support" => [] }))
    assert_equal Set.new(["email"]), Parse::CLPScope.protected_fields_for("_User", ["*", USER_ID])
    assert_empty Parse::CLPScope.protected_fields_for("_User", ["*", USER_ID, "role:Support"])
  end

  def test_protected_strip_is_top_level_only
    docs = [{ "secret" => "s", "meta" => { "secret" => "inner", "k" => 1 }, "_p_secret" => "X$1" }]
    Parse::CLPScope.redact_protected_fields!(docs, Set.new(["secret"]))
    assert_equal({ "meta" => { "secret" => "inner", "k" => 1 } }, docs.first)
  end

  # --------------------------------------------------------------- U10

  def test_schema_fetch_sends_master_key_inside_with_session
    client = Parse::Client.new(server_url: "http://localhost:1337/parse", app_id: "test",
                               api_key: "test", master_key: "mk")
    seen = nil
    response = Struct.new(:success?, :result).new(true, { "classLevelPermissions" => {} })
    client.stub(:request, ->(_m, path, **kw) { seen = [path, kw[:opts]]; response }) do
      Parse.with_session("r:user") do
        Parse::CLPScope.send(:fetch_schema_response, client, "PItem")
      end
    end
    assert_equal "schemas/PItem", seen[0]
    assert_equal true, seen[1][:use_master_key]
  end
end
