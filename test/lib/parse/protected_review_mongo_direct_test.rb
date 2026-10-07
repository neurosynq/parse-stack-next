# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
require "parse/pipeline_security"
require "parse/clp_scope"
require "parse/acl_scope"

# Follow-up review of the mongo-direct protectedFields / CLP parity work.
#
# 1. The `_User` self exemption (a user sees their own `email`) must not be
#    decided by the OUTPUT row's `_id`, which a caller stage can rewrite.
# 2. `$$ROOT` / `$$CURRENT` (and `$getField` on the current document) copy a
#    whole document, protected fields included, into a nested value the
#    top-level strip never reaches.
# 3. `$lookup` / `$unionWith` / `$graphLookup` into another class must apply
#    that class's readUserFields / pointerFields row constraint.
# 4. A join sub-pipeline that renames a protected field of the JOINED class
#    (`{ copy: "$secret" }`) must be refused like the root pipeline is.
#
# No live MongoDB: Parse::MongoDB.collection is stubbed with a collection
# that records the executed pipeline and returns seeded rows.
class ProtectedReviewMongoDirectTest < Minitest::Test
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

  def scoped(user_id = USER_ID)
    Parse::ACLScope::Resolution.new(mode: :session, permission_strings: ["*", user_id],
                                    user_id: user_id, session: nil, client: nil)
  end

  def role_only
    Parse::ACLScope::Resolution.new(mode: :public, permission_strings: ["*", "role:Ops"],
                                    user_id: nil, session: nil, client: nil)
  end

  def master
    Parse::ACLScope::Resolution.new(mode: :master, permission_strings: nil, user_id: nil,
                                    session: nil, client: nil)
  end

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

  def protect_secret!(klass = "PItem")
    Parse::CLPScope.__cache_put(klass, clp: public_clp("protectedFields" => { "*" => ["secret"] }))
  end

  def join_spec(stage)
    stage["$lookup"] || stage["$unionWith"] || stage["$graphLookup"]
  end

  # ------------------------------------------- 1. self-exemption identity

  def test_rewritten_id_does_not_unlock_another_users_email
    Parse::CLPScope.__cache_put("_User", clp: public_clp)
    # The fake returns what MongoDB would after the caller's `$set` stage:
    # bob's document carrying alice's id.
    rows = [{ "_id" => USER_ID, "username" => "bob", "email" => "bob@x" }]
    [
      [{ "$set" => { "_id" => USER_ID } }],
      [{ "$addFields" => { "_id" => { "$literal" => USER_ID } } }],
      [{ "$project" => { "_id" => { "$literal" => USER_ID }, "email" => 1 } }],
      [{ "$project" => { "_id" => 0, "objectId" => { "$literal" => USER_ID }, "email" => 1 } }],
      [{ "$group" => { "_id" => USER_ID, "n" => { "$sum" => 1 } } }],
      [{ "$unwind" => { "path" => "$tags", "includeArrayIndex" => "_id" } }],
      [{ "$lookup" => { "from" => "PItem", "pipeline" => [], "as" => "_id" } }],
    ].each do |pipeline|
      Parse::CLPScope.__cache_put("PItem", clp: public_clp)
      results, = run_aggregate("_User", pipeline, scoped, rows: rows)
      refute results.first.key?("email"), "email must be stripped after #{pipeline.inspect}"
    end
  end

  def test_identity_preserving_pipeline_keeps_own_email
    Parse::CLPScope.__cache_put("_User", clp: public_clp)
    rows = [{ "_id" => "bobUid", "email" => "bob@x" }, { "_id" => USER_ID, "email" => "alice@x" }]
    pipeline = [
      { "$match" => { "username" => { "$in" => ["alice", "bob"] } } },
      { "$sort" => { "username" => 1 } },
      { "$project" => { "username" => 1, "email" => 1, "_id" => 1 } },
      { "$skip" => 0 }, { "$limit" => 10 },
    ]
    results, = run_aggregate("_User", pipeline, scoped, rows: rows)
    refute results[0].key?("email")
    assert_equal "alice@x", results[1]["email"]
  end

  def test_joined_user_rows_are_stripped_before_caller_stages
    Parse::CLPScope.__cache_put("PItem", clp: public_clp)
    Parse::CLPScope.__cache_put("_User", clp: public_clp)
    lookup = { "$lookup" => { "from" => "_User", "pipeline" => [{ "$set" => { "_id" => USER_ID } }], "as" => "u" } }
    _r, pipeline = run_aggregate("PItem", [lookup], scoped)
    sub = join_spec(pipeline.find { |s| s.key?("$lookup") })["pipeline"]
    strip_idx = sub.index { |s| s.key?("$set") && s["$set"]["email"].is_a?(Hash) }
    caller_idx = sub.index({ "$set" => { "_id" => USER_ID } })
    refute_nil strip_idx, "joined _User rows need a head strip: #{sub.inspect}"
    assert strip_idx < caller_idx, "the strip must run before the caller's stages: #{sub.inspect}"
    cond = sub[strip_idx]["$set"]["email"]["$cond"]
    assert_equal({ "$eq" => ["$_id", { "$literal" => USER_ID }] }, cond[0])
    assert_equal "$$REMOVE", cond[2]
  end

  def test_union_with_rows_get_the_unioned_class_strip
    Parse::CLPScope.__cache_put("PItem", clp: public_clp)
    protect_secret!("PRef")
    _r, pipeline = run_aggregate("PItem", [{ "$unionWith" => "PRef" }], scoped)
    sub = pipeline.find { |s| s.key?("$unionWith") }["$unionWith"]["pipeline"]
    assert_includes sub, { "$unset" => ["secret", "_p_secret"] }
  end

  # -------------------------------------------------- 2. nested copies

  def test_root_and_current_copies_are_refused_when_class_has_protected_fields
    protect_secret!
    [
      { "$project" => { "snapshot" => "$$ROOT" } },
      { "$project" => { "newRoot" => "$$ROOT" } },
      { "$addFields" => { "snapshot" => "$$CURRENT" } },
      { "$set" => { "s" => "$$ROOT.secret" } },
      { "$replaceWith" => { "wrap" => { "$mergeObjects" => ["$$ROOT", { "x" => 1 }] } } },
      { "$replaceWith" => { "$mergeObjects" => ["$$ROOT", { "copy" => "$$ROOT" }] } },
      { "$replaceWith" => { "$mergeObjects" => ["$$ROOT", { "copy" => "$secret" }] } },
      { "$replaceRoot" => { "newRoot" => { "wrap" => "$$CURRENT" } } },
      { "$group" => { "_id" => nil, "docs" => { "$push" => "$$ROOT" } } },
      { "$project" => { "c" => { "$getField" => "secret" } } },
      { "$project" => { "c" => { "$getField" => { "field" => "secret" } } } },
      { "$project" => { "c" => { "$getField" => { "field" => { "$concat" => ["sec", "ret"] } } } } },
      { "$lookup" => { "from" => "PItem", "let" => { "r" => "$$ROOT" }, "pipeline" => [], "as" => "j" } },
    ].each do |stage|
      assert_raises(Parse::CLPScope::Denied, "expected refusal for #{stage.inspect}") do
        run_aggregate("PItem", [stage], scoped)
      end
    end
  end

  def test_root_dotted_into_unprotected_field_is_allowed
    protect_secret!
    run_aggregate("PItem", [{ "$project" => { "n" => "$$ROOT.name" } }], scoped)
    run_aggregate("PItem", [{ "$project" => { "c" => { "$getField" => "name" } } }], scoped)
  end

  def test_top_level_rehome_of_root_is_allowed_and_still_stripped
    # Re-homing the whole document at the top level keeps protected fields
    # at the top level, where the strip removes them.
    protect_secret!
    rows = [{ "_id" => "i1", "secret" => "s", "x" => 1 }]
    [
      { "$replaceRoot" => { "newRoot" => "$$ROOT" } },
      { "$replaceWith" => "$$CURRENT" },
      { "$replaceWith" => { "$mergeObjects" => ["$$ROOT", { "x" => 1 }] } },
    ].each do |stage|
      results, = run_aggregate("PItem", [stage], scoped, rows: rows)
      refute results.first.key?("secret"), stage.inspect
    end
  end

  def test_root_copy_allowed_without_protected_fields_and_for_master
    Parse::CLPScope.__cache_put("PPlain", clp: public_clp)
    run_aggregate("PPlain", [{ "$project" => { "snapshot" => "$$ROOT" } }], scoped)
    protect_secret!
    run_aggregate("PItem", [{ "$project" => { "snapshot" => "$$ROOT" } }], master)
  end

  def test_root_copy_inside_join_checked_against_joined_class
    Parse::CLPScope.__cache_put("PItem", clp: public_clp)
    protect_secret!("PRef")
    lookup = { "$lookup" => { "from" => "PRef", "pipeline" => [{ "$project" => { "s" => "$$ROOT" } }], "as" => "j" } }
    err = assert_raises(Parse::CLPScope::Denied) { run_aggregate("PItem", [lookup], scoped) }
    assert_match(/PRef/, err.message)
  end

  def test_facet_branches_strip_protected_fields_at_their_head
    protect_secret!
    facet = { "$facet" => { "all" => [{ "$limit" => 5 }] } }
    _r, pipeline = run_aggregate("PItem", [facet], scoped)
    branch = pipeline.find { |s| s.key?("$facet") }["$facet"]["all"]
    assert_equal({ "$unset" => ["secret", "_p_secret"] }, branch.first)
    assert_equal({ "$limit" => 5 }, branch.last)
  end

  # ------------------------------------------ 3. join row constraints

  def test_lookup_applies_joined_read_user_fields
    Parse::CLPScope.__cache_put("PItem", clp: public_clp)
    Parse::CLPScope.__cache_put("PRuf", clp: {
      "find" => { "requiresAuthentication" => true }, "readUserFields" => ["owner"],
    })
    [
      { "$lookup" => { "from" => "PRuf", "localField" => "_p_x", "foreignField" => "_id", "as" => "j" } },
      { "$lookup" => { "from" => "PRuf", "pipeline" => [{ "$limit" => 1 }], "as" => "j" } },
      { "$unionWith" => "PRuf" },
      { "$unionWith" => { "coll" => "PRuf", "pipeline" => [{ "$limit" => 1 }] } },
    ].each do |stage|
      _r, pipeline = run_aggregate("PItem", [stage], scoped)
      spec = join_spec(pipeline.find { |s| s.key?("$lookup") || s.key?("$unionWith") })
      head = spec["pipeline"].first
      assert head.key?("$match"), "join must lead with a $match: #{spec.inspect}"
      assert head.to_s.include?("_p_owner") && head.to_s.include?("_User$#{USER_ID}"),
             "joined readUserFields constraint missing for #{stage.inspect}: #{head.inspect}"
    end
  end

  def test_graph_lookup_applies_joined_pointer_fields
    Parse::CLPScope.__cache_put("PItem", clp: public_clp)
    Parse::CLPScope.__cache_put("PPf", clp: { "find" => { "pointerFields" => ["owner"] } })
    stage = { "$graphLookup" => { "from" => "PPf", "startWith" => "$x", "connectFromField" => "x",
                                  "connectToField" => "_id", "as" => "g" } }
    _r, pipeline = run_aggregate("PItem", [stage], scoped)
    restrict = pipeline.find { |s| s.key?("$graphLookup") }["$graphLookup"]["restrictSearchWithMatch"]
    assert restrict.to_s.include?("_User$#{USER_ID}"), restrict.inspect
  end

  def test_join_into_pointer_only_class_without_user_is_refused
    Parse::CLPScope.__cache_put("PItem", clp: public_clp)
    Parse::CLPScope.__cache_put("PPf", clp: { "find" => { "pointerFields" => ["owner"] } })
    Parse::CLPScope.__cache_put("PAuth", clp: { "find" => { "requiresAuthentication" => true } })
    %w[PPf PAuth].each do |target|
      assert_raises(Parse::CLPScope::Denied, target) do
        run_aggregate("PItem", [{ "$lookup" => { "from" => target, "pipeline" => [], "as" => "j" } }], role_only)
      end
    end
  end

  def test_join_into_public_class_is_not_narrowed
    Parse::CLPScope.__cache_put("PItem", clp: public_clp)
    Parse::CLPScope.__cache_put("PPub", clp: { "find" => { "*" => true, "pointerFields" => ["owner"] } })
    _r, pipeline = run_aggregate("PItem", [{ "$lookup" => { "from" => "PPub", "pipeline" => [], "as" => "j" } }], scoped)
    refute pipeline.to_s.include?("_p_owner"), pipeline.inspect
  end

  def test_master_join_is_unchanged
    Parse::CLPScope.__cache_put("PPf", clp: { "find" => { "pointerFields" => ["owner"] } })
    stage = { "$lookup" => { "from" => "PPf", "pipeline" => [{ "$project" => { "c" => "$secret" } }], "as" => "j" } }
    _r, pipeline = run_aggregate("PItem", [stage], master)
    assert_equal [stage], pipeline
  end

  # ------------------------------------- 4. joined projections renaming

  def test_join_sub_pipeline_rename_of_joined_protected_field_is_refused
    Parse::CLPScope.__cache_put("PItem", clp: public_clp)
    protect_secret!("PRef")
    [
      { "$project" => { "copy" => "$secret" } },
      { "$addFields" => { "copy" => "$secret.sub" } },
      { "$set" => { "copy" => { "$toUpper" => "$secret" } } },
      { "$group" => { "_id" => "$secret" } },
      { "$replaceRoot" => { "newRoot" => { "c" => "$secret" } } },
      { "$project" => { "copy" => "$_p_secret" } },
    ].each do |sub_stage|
      [
        { "$lookup" => { "from" => "PRef", "pipeline" => [sub_stage], "as" => "j" } },
        { "$unionWith" => { "coll" => "PRef", "pipeline" => [sub_stage] } },
      ].each do |stage|
        assert_raises(Parse::CLPScope::Denied, "expected refusal for #{stage.inspect}") do
          run_aggregate("PItem", [stage], scoped)
        end
      end
    end
  end

  def test_join_let_and_sub_pipeline_also_checked_against_outer_class
    # PItem protects `secret`; PRef does not. A `let` reading the ROOT
    # secret is refused, and a sub-pipeline name shared with the outer
    # class's protected set is refused conservatively.
    protect_secret!
    Parse::CLPScope.__cache_put("PRef", clp: public_clp)
    ok = { "$lookup" => { "from" => "PRef", "pipeline" => [{ "$project" => { "c" => "$label" } }], "as" => "j" } }
    run_aggregate("PItem", [ok], scoped)
    [
      { "$lookup" => { "from" => "PRef", "let" => { "s" => "$secret" }, "pipeline" => [], "as" => "j" } },
      { "$lookup" => { "from" => "PRef", "pipeline" => [{ "$project" => { "c" => "$secret" } }], "as" => "j" } },
    ].each do |stage|
      assert_raises(Parse::CLPScope::Denied, stage.inspect) { run_aggregate("PItem", [stage], scoped) }
    end
  end

  def test_graph_lookup_into_protected_class_is_refused
    Parse::CLPScope.__cache_put("PItem", clp: public_clp)
    protect_secret!("PRef")
    stage = { "$graphLookup" => { "from" => "PRef", "startWith" => "$x", "connectFromField" => "x",
                                  "connectToField" => "_id", "as" => "g" } }
    assert_raises(Parse::CLPScope::Denied) { run_aggregate("PItem", [stage], scoped) }
  end
end
