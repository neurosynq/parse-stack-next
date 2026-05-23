require_relative "../../test_helper"
require "minitest/autorun"

# Two foreign classes: one declares parse_reference, one does not. This lets
# us exercise both the direct-equality path and the $split fallback.
class LRForeignWithRef < Parse::Object
  parse_class "LRForeignWithRef"
  property :title, :string
  parse_reference
  def autofetch!(*); nil; end
end

class LRForeignNoRef < Parse::Object
  parse_class "LRForeignNoRef"
  property :title, :string
  def autofetch!(*); nil; end
end

# Local class with two belongs_to pointers, plus its own parse_reference so we
# can test reverse joins coming back into this collection.
class LRLocal < Parse::Object
  parse_class "LRLocal"
  property :name, :string
  belongs_to :project, class_name: "LRForeignWithRef"
  belongs_to :legacy, class_name: "LRForeignNoRef"
  parse_reference
  def autofetch!(*); nil; end
end

# Reverse-side counterpart: a foreign class that points BACK at LRLocal via a
# belongs_to. Used for reverse-join rewrites.
class LRChildOfLocal < Parse::Object
  parse_class "LRChildOfLocal"
  property :title, :string
  belongs_to :owner, class_name: "LRLocal"
  parse_reference
  def autofetch!(*); nil; end
end

# Local class WITHOUT parse_reference, so reverse rewrites must fall back to
# $split form on the foreign _p_ column.
class LRLocalNoRef < Parse::Object
  parse_class "LRLocalNoRef"
  property :name, :string
  def autofetch!(*); nil; end
end

class LRChildOfLocalNoRef < Parse::Object
  parse_class "LRChildOfLocalNoRef"
  belongs_to :owner, class_name: "LRLocalNoRef"
  def autofetch!(*); nil; end
end

class LookupRewriterTest < Minitest::Test
  def test_forward_join_with_parse_reference_uses_direct_equality
    pipeline = [
      { "$lookup" => {
        "from" => "LRForeignWithRef",
        "localField" => "project",
        "foreignField" => "_id",
        "as" => "project_doc",
      } },
    ]
    result = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal)
    spec = result.first["$lookup"]
    assert_equal "LRForeignWithRef", spec["from"]
    assert_equal "_p_project", spec["localField"]
    assert_equal "parseReference", spec["foreignField"]
    assert_equal "project_doc", spec["as"]
  end

  def test_forward_join_accepts_objectId_alias_for_foreign_field
    pipeline = [
      { "$lookup" => {
        "from" => "LRForeignWithRef",
        "localField" => "project",
        "foreignField" => "objectId",
        "as" => "x",
      } },
    ]
    spec = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$lookup"]
    assert_equal "_p_project", spec["localField"]
    assert_equal "parseReference", spec["foreignField"]
  end

  def test_forward_join_without_parse_reference_falls_back_to_split
    pipeline = [
      { "$lookup" => {
        "from" => "LRForeignNoRef",
        "localField" => "legacy",
        "foreignField" => "_id",
        "as" => "legacy_doc",
      } },
    ]
    spec = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$lookup"]
    refute spec.key?("localField"), "fallback form must drop localField"
    refute spec.key?("foreignField"), "fallback form must drop foreignField"
    assert_equal "LRForeignNoRef", spec["from"]
    assert spec["let"].is_a?(Hash)
    assert spec["pipeline"].is_a?(Array)
    assert_equal "legacy_doc", spec["as"]
    let_var = spec["let"].keys.first
    expr = spec["pipeline"].first["$match"]["$expr"]
    assert_equal "$_id", expr["$eq"].first
    assert_equal "$$#{let_var}", expr["$eq"].last
    split_expr = spec["let"][let_var]
    assert_equal "$_p_legacy", split_expr["$arrayElemAt"].first["$split"].first
  end

  def test_reverse_join_with_parse_reference_uses_direct_equality
    # Asking "for each LRLocal row, fetch its LRChildOfLocal rows".
    pipeline = [
      { "$lookup" => {
        "from" => "LRChildOfLocal",
        "localField" => "_id",
        "foreignField" => "owner",
        "as" => "children",
      } },
    ]
    spec = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$lookup"]
    assert_equal "LRChildOfLocal", spec["from"]
    assert_equal "parseReference", spec["localField"]
    assert_equal "_p_owner", spec["foreignField"]
    assert_equal "children", spec["as"]
  end

  def test_reverse_join_without_local_parse_reference_falls_back_to_split
    pipeline = [
      { "$lookup" => {
        "from" => "LRChildOfLocalNoRef",
        "localField" => "_id",
        "foreignField" => "owner",
        "as" => "kids",
      } },
    ]
    spec = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocalNoRef).first["$lookup"]
    refute spec.key?("localField")
    refute spec.key?("foreignField")
    assert spec["let"].is_a?(Hash)
    let_var = spec["let"].keys.first
    assert_equal "$_id", spec["let"][let_var]
    expr = spec["pipeline"].first["$match"]["$expr"]
    inner_split = expr["$eq"].first
    assert_equal "$_p_owner", inner_split["$arrayElemAt"].first["$split"].first
    assert_equal "$$#{let_var}", expr["$eq"].last
  end

  def test_idempotent_when_localField_already_in_p_form
    pipeline = [
      { "$lookup" => {
        "from" => "LRForeignWithRef",
        "localField" => "_p_project",
        "foreignField" => "parseReference",
        "as" => "p",
      } },
    ]
    out = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$lookup"]
    assert_equal "_p_project", out["localField"]
    assert_equal "parseReference", out["foreignField"]
  end

  def test_system_class_collection_rename
    pipeline = [
      { "$lookup" => {
        "from" => "User",
        "localField" => "_p_owner",
        "foreignField" => "parseReference",
        "as" => "owner",
      } },
    ]
    spec = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$lookup"]
    assert_equal "_User", spec["from"]
  end

  def test_unknown_local_field_passes_through_with_only_collection_rename
    pipeline = [
      { "$lookup" => {
        "from" => "User",
        "localField" => "nonexistent",
        "foreignField" => "_id",
        "as" => "x",
      } },
    ]
    spec = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$lookup"]
    assert_equal "_User", spec["from"]
    assert_equal "nonexistent", spec["localField"]
    assert_equal "_id", spec["foreignField"]
  end

  def test_let_pipeline_form_recurses_with_foreign_local_context
    # Outer lookup is in let/pipeline form; inner sub-pipeline contains a
    # nested $lookup against `owner` -- a belongs_to declared ON the foreign
    # class LRChildOfLocal. The rewriter must therefore resolve `owner`
    # against LRChildOfLocal's references (not the outer LRLocal's) to
    # produce `_p_owner`/`parseReference`. This proves target_class is
    # actually being used as the new local context for the recursion.
    inner_pipeline = [
      { "$lookup" => {
        "from" => "LRLocal",
        "localField" => "owner",     # belongs_to on LRChildOfLocal
        "foreignField" => "_id",
        "as" => "owner_doc",
      } },
    ]
    pipeline = [
      { "$lookup" => {
        "from" => "LRChildOfLocal",
        "let" => { "lid" => "$_id" },
        "pipeline" => inner_pipeline,
        "as" => "children",
      } },
    ]
    out = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$lookup"]
    assert_equal "LRChildOfLocal", out["from"]
    nested = out["pipeline"].first["$lookup"]
    assert_equal "_p_owner", nested["localField"],
                 "inner lookup must resolve `owner` against LRChildOfLocal's belongs_to"
    assert_equal "parseReference", nested["foreignField"],
                 "outer LRLocal declares parse_reference, so direct-equality rewrite must apply"
  end

  def test_let_pipeline_form_also_renames_system_class_in_sub_pipeline
    inner_pipeline = [
      { "$lookup" => {
        "from" => "User",
        "localField" => "_p_owner",
        "foreignField" => "parseReference",
        "as" => "u",
      } },
    ]
    pipeline = [
      { "$lookup" => {
        "from" => "LRForeignWithRef",
        "let" => { "lid" => "$_p_project" },
        "pipeline" => inner_pipeline,
        "as" => "joined",
      } },
    ]
    out = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$lookup"]
    assert_equal "LRForeignWithRef", out["from"]
    assert_equal "_User", out["pipeline"].first["$lookup"]["from"]
  end

  def test_facet_recurses_with_original_local_context
    pipeline = [
      { "$facet" => {
        "branch_a" => [
          { "$lookup" => {
            "from" => "LRForeignWithRef",
            "localField" => "project",
            "foreignField" => "_id",
            "as" => "p",
          } },
        ],
        "branch_b" => [
          { "$lookup" => {
            "from" => "User",
            "localField" => "_p_owner",
            "foreignField" => "parseReference",
            "as" => "o",
          } },
        ],
      } },
    ]
    out = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$facet"]
    assert_equal "_p_project", out["branch_a"].first["$lookup"]["localField"]
    assert_equal "parseReference", out["branch_a"].first["$lookup"]["foreignField"]
    assert_equal "_User", out["branch_b"].first["$lookup"]["from"]
  end

  def test_unionWith_with_hash_recurses_into_pipeline
    pipeline = [
      { "$unionWith" => {
        "coll" => "LRForeignWithRef",
        "pipeline" => [
          { "$lookup" => {
            "from" => "User",
            "localField" => "_p_owner",
            "foreignField" => "parseReference",
            "as" => "o",
          } },
        ],
      } },
    ]
    out = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$unionWith"]
    nested = out["pipeline"].first["$lookup"]
    assert_equal "_User", nested["from"]
  end

  def test_unionWith_with_bare_string_does_not_break
    pipeline = [{ "$unionWith" => "LRForeignWithRef" }]
    out = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal)
    assert_equal "LRForeignWithRef", out.first["$unionWith"]
  end

  def test_non_lookup_stages_are_untouched
    match = { "$match" => { "name" => "alice" } }
    out = Parse::LookupRewriter.rewrite([match], local_class: LRLocal)
    assert_equal match, out.first
  end

  def test_symbol_keys_preserved_in_unmodified_positions
    pipeline = [
      { "$lookup" => {
        from: "LRForeignWithRef",
        localField: "project",
        foreignField: "_id",
        as: "p",
      } },
    ]
    spec = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$lookup"]
    # Whatever key style is chosen for replaced keys, the field values must be right.
    assert_equal "_p_project", (spec["localField"] || spec[:localField])
    assert_equal "parseReference", (spec["foreignField"] || spec[:foreignField])
    assert_equal "p", (spec["as"] || spec[:as])
  end

  def test_non_array_input_returned_unchanged
    assert_equal "not a pipeline", Parse::LookupRewriter.rewrite("not a pipeline", local_class: LRLocal)
  end

  def test_graph_lookup_renames_system_class_collection
    pipeline = [
      { "$graphLookup" => {
        "from" => "User",
        "startWith" => "$_p_owner",
        "connectFromField" => "_p_manager",
        "connectToField" => "_id",
        "as" => "chain",
      } },
    ]
    out = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$graphLookup"]
    assert_equal "_User", out["from"]
  end

  def test_graph_lookup_non_system_class_passes_through
    pipeline = [
      { "$graphLookup" => {
        "from" => "LRForeignWithRef",
        "startWith" => "$_p_project",
        "connectFromField" => "_p_parent",
        "connectToField" => "_id",
        "as" => "chain",
      } },
    ]
    out = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$graphLookup"]
    assert_equal "LRForeignWithRef", out["from"]
    assert_equal "_p_project", out["startWith"].sub(/\A\$/, "")
  end

  def test_preserve_fallback_leaves_lookup_unchanged_when_foreign_has_no_parse_reference
    pipeline = [
      { "$lookup" => {
        "from" => "LRForeignNoRef",
        "localField" => "legacy",
        "foreignField" => "_id",
        "as" => "x",
      } },
    ]
    out = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal, fallback: :preserve).first["$lookup"]
    assert_equal "legacy", out["localField"], "preserve mode must not switch to _p_ form when foreign lacks parse_reference"
    assert_equal "_id", out["foreignField"]
    refute out.key?("let"), "preserve mode must not emit $split fallback"
  end

  def test_preserve_fallback_still_rewrites_when_foreign_has_parse_reference
    pipeline = [
      { "$lookup" => {
        "from" => "LRForeignWithRef",
        "localField" => "project",
        "foreignField" => "_id",
        "as" => "x",
      } },
    ]
    out = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal, fallback: :preserve).first["$lookup"]
    assert_equal "_p_project", out["localField"]
    assert_equal "parseReference", out["foreignField"]
  end

  def test_auto_rewrite_respects_global_flag
    pipeline = [
      { "$lookup" => {
        "from" => "LRForeignWithRef",
        "localField" => "project",
        "foreignField" => "_id",
        "as" => "x",
      } },
    ]
    original = Parse.rewrite_lookups
    begin
      Parse.rewrite_lookups = false
      out = Parse::LookupRewriter.auto_rewrite(pipeline, class_name: "LRLocal").first["$lookup"]
      assert_equal "project", out["localField"], "global disable must skip rewrite"

      Parse.rewrite_lookups = true
      out = Parse::LookupRewriter.auto_rewrite(pipeline, class_name: "LRLocal").first["$lookup"]
      assert_equal "_p_project", out["localField"]
    ensure
      Parse.rewrite_lookups = original
    end
  end

  def test_auto_rewrite_explicit_enabled_overrides_global_flag
    pipeline = [
      { "$lookup" => {
        "from" => "LRForeignWithRef",
        "localField" => "project",
        "foreignField" => "_id",
        "as" => "x",
      } },
    ]
    original = Parse.rewrite_lookups
    begin
      Parse.rewrite_lookups = false
      out = Parse::LookupRewriter.auto_rewrite(pipeline, class_name: "LRLocal", enabled: true).first["$lookup"]
      assert_equal "_p_project", out["localField"], "explicit enabled: true must override global"
    ensure
      Parse.rewrite_lookups = original
    end
  end

  def test_auto_rewrite_unknown_class_passes_through
    pipeline = [{ "$lookup" => { "from" => "X", "localField" => "y", "foreignField" => "_id", "as" => "z" } }]
    out = Parse::LookupRewriter.auto_rewrite(pipeline, class_name: "NonExistentClass")
    assert_equal pipeline, out
  end

  def test_lookup_without_localField_only_renames_collection
    pipeline = [
      { "$lookup" => {
        "from" => "User",
        "as" => "u",
      } },
    ]
    spec = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal).first["$lookup"]
    assert_equal "_User", spec["from"]
  end

  # --- NEW-QUERY-3 underscore-collection denylist ----------------------

  %w[_Hooks _SCHEMA _GraphQLConfig _Audit _GlobalConfig _Idempotency _PushStatus _JobStatus _JobSchedule _Audience].each do |coll|
    define_method("test_lookup_refuses_internal_collection_#{coll}") do
      pipeline = [{ "$lookup" => { "from" => coll, "as" => "x" } }]
      err = assert_raises(Parse::PipelineSecurity::Error) do
        Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal)
      end
      assert_equal :denied_internal_collection, err.reason
      assert_match coll, err.message
    end
  end

  def test_graph_lookup_refuses_internal_collection
    pipeline = [{ "$graphLookup" => { "from" => "_Hooks", "as" => "x",
                                       "startWith" => "$x", "connectFromField" => "a",
                                       "connectToField" => "b" } }]
    err = assert_raises(Parse::PipelineSecurity::Error) do
      Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal)
    end
    assert_match "_Hooks", err.message
  end

  def test_union_with_refuses_internal_collection_hash_form
    pipeline = [{ "$unionWith" => { "coll" => "_SCHEMA", "pipeline" => [] } }]
    assert_raises(Parse::PipelineSecurity::Error) do
      Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal)
    end
  end

  def test_union_with_refuses_internal_collection_string_form
    pipeline = [{ "$unionWith" => "_Hooks" }]
    assert_raises(Parse::PipelineSecurity::Error) do
      Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal)
    end
  end

  def test_lookup_permits_user_role_installation_session
    %w[User _User Role _Role Installation _Installation Session _Session].each do |from|
      pipeline = [{ "$lookup" => { "from" => from, "as" => "x" } }]
      out = Parse::LookupRewriter.rewrite(pipeline, local_class: LRLocal)
      refute_nil out.first["$lookup"]["from"]
    end
  end
end
