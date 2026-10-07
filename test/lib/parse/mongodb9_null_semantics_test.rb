# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# MongoDB 9.0 changed `null` comparisons on dotted paths that traverse arrays:
# a path that resolves to no non-null value now compares equal to `null`, so
# `{ "a.b": null }` matches documents like `{ a: [] }` or `{ a: [1] }` that it
# did not match before, and `{ "a.b": { $ne: null } }` stops matching them.
# `$exists` is unchanged. (docs/mongodb_direct_guide.md, "MongoDB 9.0 null
# semantics".)
#
# Audit result: the SDK never adds a null comparison on a dotted path of its
# own (ACL scoping's `_rperm` `$exists` is top-level). It only compiles one
# when the CALLER names a dotted field. These tests pin exactly which public
# constraints produce a 9.0-sensitive shape (`$eq`/`$ne`/`$in` against null)
# and which stay on unchanged `$exists`, so a compilation change that moves a
# constraint between the two groups is visible in review.
class MongoDB9NullSemanticsTest < Minitest::Test
  class NullAuditDoc < Parse::Object
    parse_class "NullAuditDoc"
    property :meta, :object
  end

  def where(constraints)
    Parse::Query.new("NullAuditDoc", constraints).compile(encode: false)[:where]
  end

  def pipeline(constraints)
    Parse::Query.new("NullAuditDoc", constraints).send(:build_aggregation_pipeline).first
  end

  # ---- 9.0-sensitive: null equality / inequality on a dotted path ----

  def test_nil_equality_compiles_to_null_match
    assert_equal({ "meta.owner" => nil }, where(:"meta.owner" => nil))
  end

  def test_not_nil_compiles_to_ne_null
    assert_equal({ "meta.owner" => { "$ne": nil } }, where(:"meta.owner".not => nil))
  end

  def test_null_false_compiles_to_ne_null
    assert_equal({ "meta.owner" => { "$ne": nil } }, where(:"meta.owner".null => false))
  end

  def test_in_with_nil_compiles_to_in_null
    assert_equal({ "meta.owner" => { "$in": [nil, "x"] } }, where(:"meta.owner".in => [nil, "x"]))
  end

  def test_empty_or_nil_includes_eq_null
    match = pipeline(:"meta.items".empty_or_nil => true).first["$match"]["$or"]
    assert_includes match, { "meta.items" => { "$eq" => nil } }
  end

  def test_not_empty_includes_ne_null
    match = pipeline(:"meta.items".not_empty => true).first["$match"]["$and"]
    assert_includes match, { "meta.items" => { "$ne" => nil } }
  end

  # ---- unchanged in 9.0: $exists ----

  def test_null_true_compiles_to_exists_false
    assert_equal({ "meta.owner" => { "$exists": false } }, where(:"meta.owner".null => true))
  end

  def test_exists_false_compiles_to_exists_false
    assert_equal({ "meta.owner" => { "$exists": false } }, where(:"meta.owner".exists => false))
  end

  # ---- SDK-internal scoping stays top-level ----

  def test_acl_scope_null_handling_is_top_level
    res = Parse::ACLScope::Resolution.new(mode: :session, permission_strings: ["u1", "*"], user_id: "u1",
                                          session: nil, strict_role: false)
    stage = JSON.generate(Parse::ACLScope.match_stage_for(res))
    refute_match(/"[A-Za-z_]+\.[A-Za-z_.]+"\s*:\s*\{"\$(eq|ne|exists)"/, stage,
                 "ACL scoping must not compare a dotted path against null")
    assert_includes stage, '"_rperm":{"$exists":false}'
  end
end
