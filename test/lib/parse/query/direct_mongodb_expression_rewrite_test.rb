require_relative "../../../test_helper"

# Test class with pointer fields so field_is_pointer? has something to
# resolve. The Parse class name matches the Ruby constant; properties
# declared as :pointer / belongs_to drive the rewrite from logical
# `requestedBy` to the storage column `_p_requestedBy`.
class ExprRewriteTarget < Parse::Object
  parse_class "ExprRewriteTarget"
  property :status, :string
  belongs_to :requested_by, as: :user, field: :requestedBy
  belongs_to :author, as: :user
  belongs_to :approver, as: :user
end

# Coverage for the recursive expression walker used by the mongo_direct
# pipeline conversion. The walker is schema-aware (4.4.2): `$field`
# references inside aggregation expression VALUES are rewritten to
# their storage-column form only when the field is a declared Parse
# property (or a universal built-in like `objectId`/`createdAt`/
# `updatedAt`). Names the schema does not know — including the
# pipeline-local aliases introduced by `$group` / `$project` /
# `$addFields` / `$set` — pass through verbatim, so a downstream
# `$alias` reference matches the literal output key the upstream stage
# produced. Output-alias keys (the LHS of those four stages) are never
# rewritten: result rows are keyed by whatever spelling the caller
# wrote into the pipeline.
class DirectMongoDBExpressionRewriteTest < Minitest::Test
  def setup
    @query = Parse::Query.new("ExprRewriteTarget")
  end

  # Case 1: $group._id with $cond containing $eq with null.
  # This is the reproducer that motivated the original patch.
  def test_group_id_cond_with_eq_null_rewrites_pointer_field_ref
    stage = {
      "$group" => {
        "_id" => {
          "$cond" => [
            { "$eq" => ["$requestedBy", nil] },
            "system",
            "human",
          ],
        },
      },
    }

    rewritten = @query.send(:convert_stage_for_direct_mongodb, stage)
    cond_args = rewritten["$group"]["_id"]["$cond"]

    assert_equal "$_p_requestedBy", cond_args[0]["$eq"][0],
                 "expected $requestedBy inside $eq to rewrite to $_p_requestedBy"
    assert_nil cond_args[0]["$eq"][1], "null literal must survive verbatim"
    assert_equal "system", cond_args[1]
    assert_equal "human", cond_args[2]
  end

  # Case 2: accumulator-side expression — $sum: { $cond: [...] }.
  # The accumulator output key `system_count` passes through verbatim
  # (no rewriting of pipeline-local aliases). The expression VALUE is
  # still walked so the inner `$requestedBy` reaches `$_p_requestedBy`.
  def test_group_accumulator_sum_cond_rewrites_pointer_field_ref
    stage = {
      "$group" => {
        "_id" => "$status",
        "system_count" => {
          "$sum" => {
            "$cond" => [
              { "$eq" => ["$requestedBy", nil] },
              1,
              0,
            ],
          },
        },
      },
    }

    rewritten = @query.send(:convert_stage_for_direct_mongodb, stage)

    assert rewritten["$group"].key?("system_count"),
           "expected $group accumulator alias to pass through verbatim"
    inner = rewritten["$group"]["system_count"]["$sum"]["$cond"]

    assert_equal "$status", rewritten["$group"]["_id"]
    assert_equal "$_p_requestedBy", inner[0]["$eq"][0]
    assert_nil inner[0]["$eq"][1]
  end

  # Case 3: $switch with branches array-of-objects. Exercises the
  # array-of-hashes recursion path that the original
  # convert_group_id_for_direct_mongodb missed entirely.
  def test_group_id_switch_branches_rewrites_pointer_field_refs
    stage = {
      "$group" => {
        "_id" => {
          "$switch" => {
            "branches" => [
              { "case" => { "$eq" => ["$author", "$approver"] }, "then" => "self_approved" },
              { "case" => { "$eq" => ["$requestedBy", nil] },    "then" => "system" },
            ],
            "default" => "other",
          },
        },
      },
    }

    rewritten = @query.send(:convert_stage_for_direct_mongodb, stage)
    branches = rewritten["$group"]["_id"]["$switch"]["branches"]

    assert_equal "$_p_author",      branches[0]["case"]["$eq"][0]
    assert_equal "$_p_approver",    branches[0]["case"]["$eq"][1]
    assert_equal "self_approved",   branches[0]["then"]
    assert_equal "$_p_requestedBy", branches[1]["case"]["$eq"][0]
    assert_nil                      branches[1]["case"]["$eq"][1]
    assert_equal "other",           rewritten["$group"]["_id"]["$switch"]["default"]
  end

  # Case 4: $addFields with $not on a bare pointer reference. The
  # output-alias key `is_system` passes through verbatim — pipeline-
  # local alias, not a schema field. The expression value's
  # `$requestedBy` reaches `$_p_requestedBy` because the schema knows
  # `requestedBy` is a pointer.
  def test_addfields_not_on_pointer_field_ref_rewrites
    stage = {
      "$addFields" => {
        "is_system" => { "$not" => ["$requestedBy"] },
      },
    }

    rewritten = @query.send(:convert_stage_for_direct_mongodb, stage)
    assert rewritten["$addFields"].key?("is_system"),
           "expected $addFields alias to pass through verbatim"
    assert_equal({ "$not" => ["$_p_requestedBy"] }, rewritten["$addFields"]["is_system"])
  end

  # Case 5 (raised by the original reporter): $match with $expr. The
  # constraint converter only special-cased $and/$or/$nor at the top
  # level; $expr's value passed through unrewritten before the patch.
  def test_match_expr_eq_rewrites_pointer_field_refs_on_both_sides
    stage = {
      "$match" => {
        "$expr" => { "$eq" => ["$author", "$approver"] },
      },
    }

    rewritten = @query.send(:convert_stage_for_direct_mongodb, stage)
    eq_args = rewritten["$match"]["$expr"]["$eq"]

    assert_equal "$_p_author",   eq_args[0]
    assert_equal "$_p_approver", eq_args[1]
  end

  # The walker must not rewrite the argument of $literal — that argument
  # is a string constant, not a field reference. Without this guard, a
  # value like `{ "$literal": "$requestedBy" }` (legitimately used to
  # output the literal string "$requestedBy") would be corrupted.
  def test_literal_argument_is_not_rewritten
    stage = {
      "$addFields" => {
        "label" => { "$literal" => "$requestedBy" },
      },
    }

    rewritten = @query.send(:convert_stage_for_direct_mongodb, stage)
    assert_equal "$requestedBy", rewritten["$addFields"]["label"]["$literal"]
  end

  # `$$varName` denotes a $lookup `let` binding or a system variable
  # ($$ROOT, $$CURRENT, $$NOW); these are not field references and must
  # pass through unchanged.
  def test_let_variable_references_are_not_rewritten
    expr = { "$eq" => ["$$lookupId", "$author"] }
    rewritten = @query.send(:rewrite_expression_for_direct_mongodb, expr)

    assert_equal "$$lookupId", rewritten["$eq"][0]
    assert_equal "$_p_author", rewritten["$eq"][1]
  end

  # Idempotency: a caller that already wrote $_p_* directly should not
  # see double-rewriting. convert_field_for_direct_mongodb passes
  # _p_*-prefixed names through unchanged; this is a regression net
  # against future "helpful" rewrites that strip-and-restore.
  def test_already_rewritten_storage_form_is_idempotent
    expr = { "$eq" => ["$_p_requestedBy", nil] }
    rewritten = @query.send(:rewrite_expression_for_direct_mongodb, expr)

    assert_equal "$_p_requestedBy", rewritten["$eq"][0]
    assert_nil rewritten["$eq"][1]
  end

  # Dot-path field references: only the root segment is a Parse field
  # name; the tail is a sub-document path that must survive verbatim.
  def test_dotted_field_ref_rewrites_root_only
    rewritten = @query.send(:rewrite_expression_for_direct_mongodb, "$requestedBy.objectId")
    assert_equal "$_p_requestedBy.objectId", rewritten
  end

  # Non-pointer schema fields pass through with the formatter applied
  # (already camelCase here) but no `_p_` prefix. `status` is declared
  # on ExprRewriteTarget as a string property, so the schema knows it.
  def test_non_pointer_field_ref_is_not_prefixed
    rewritten = @query.send(:rewrite_expression_for_direct_mongodb, "$status")
    assert_equal "$status", rewritten
  end

  # Reproducer for the original bug: a $group accumulator output alias
  # was left as-is by convert_group_for_direct_mongodb, but the
  # expression walker camelCased the same name when it appeared as a
  # reference in a downstream $project stage. The full pipeline used
  # to ship with the $group writing `contributor_set` and the $project
  # reading `$contributorSet` — so $size operated on a missing field
  # and Mongo raised "$size must be an array, but was of type:
  # missing".
  #
  # After 4.4.2: both sides pass through verbatim. The $group output is
  # `contributor_set`, the $project reference is `$contributor_set`,
  # and they match. The result row is keyed by `contributing_user_count`
  # — the spelling the caller wrote — so `row["contributing_user_count"]`
  # works without translation on the read side.
  def test_group_output_alias_matches_downstream_project_reference
    pipeline = [
      { "$group" => {
        "_id" => nil,
        "contributor_set" => { "$addToSet" => "$_p_user" },
      } },
      { "$project" => {
        "contributing_user_count" => { "$size" => "$contributor_set" },
      } },
    ]

    translated = @query.send(:translate_pipeline_for_direct_mongodb, pipeline)

    group_out = translated[0]["$group"]
    project_out = translated[1]["$project"]

    assert_equal "contributor_set", group_out.keys.last,
                 "expected $group accumulator alias to pass through verbatim"
    assert_equal "contributing_user_count", project_out.keys.first,
                 "expected $project output alias to pass through verbatim"
    assert_equal "$contributor_set", project_out["contributing_user_count"]["$size"],
                 "expected $project reference to the $group alias to also pass through verbatim " \
                 "(schema-aware walker: unknown names are not rewritten)"
  end

  # Schema-aware walker — UNKNOWN field references pass through. This
  # is the primary new guarantee. A `$field` reference whose name isn't
  # in the Parse class schema and isn't a built-in
  # (objectId/createdAt/updatedAt) is treated as a pipeline-local alias
  # and survives verbatim.
  def test_unknown_field_ref_passes_through_verbatim
    rewritten = @query.send(:rewrite_expression_for_direct_mongodb, "$contributor_set")
    assert_equal "$contributor_set", rewritten

    rewritten = @query.send(:rewrite_expression_for_direct_mongodb, "$totalsByMonth")
    assert_equal "$totalsByMonth", rewritten
  end

  # Built-in names are universal — they are always remapped to their
  # internal storage column regardless of whether the schema declares
  # them. `$objectId` reaches `$_id`, `$createdAt` reaches
  # `$_created_at`, `$updatedAt` reaches `$_updated_at`.
  def test_builtin_field_refs_always_remap
    assert_equal "$_id",          @query.send(:rewrite_expression_for_direct_mongodb, "$objectId")
    assert_equal "$_created_at",  @query.send(:rewrite_expression_for_direct_mongodb, "$createdAt")
    assert_equal "$_updated_at",  @query.send(:rewrite_expression_for_direct_mongodb, "$updatedAt")
    # The snake_case forms also remap — format_field normalizes first.
    assert_equal "$_id",          @query.send(:rewrite_expression_for_direct_mongodb, "$object_id")
    assert_equal "$_created_at",  @query.send(:rewrite_expression_for_direct_mongodb, "$created_at")
    assert_equal "$_updated_at",  @query.send(:rewrite_expression_for_direct_mongodb, "$updated_at")
  end

  # Output-key aliases on every projection-shape stage pass through
  # verbatim. The result row uses whatever spelling the caller wrote.
  def test_output_alias_keys_pass_through_on_all_projection_shapes
    pipeline = [
      { "$project" => { "contributing_user_count" => { "$size" => "$contributor_set" } } },
      { "$addFields" => { "is_system" => { "$not" => ["$_p_requestedBy"] } } },
      { "$set" => { "total_count" => { "$add" => ["$count_a", "$count_b"] } } },
      { "$group" => { "_id" => "$status", "subtotal_amount" => { "$sum" => "$amount" } } },
    ]

    translated = @query.send(:translate_pipeline_for_direct_mongodb, pipeline)

    assert_equal "contributing_user_count", translated[0]["$project"].keys.first
    assert_equal "is_system",               translated[1]["$addFields"].keys.first
    assert_equal "total_count",             translated[2]["$set"].keys.first
    assert_equal "subtotal_amount",         translated[3]["$group"].keys.last
  end

  # Aliases whose names happen to coincide with pointer-property names
  # are NOT treated specially — the schema wins. This is the documented
  # limitation of the schema-aware walker: a `$group { author: ... }`
  # alias followed by `$author` later in the pipeline will see the
  # reference resolved to `$_p_author` (the storage column), not the
  # alias. Avoid alias names that shadow declared Parse properties.
  def test_alias_shadowing_property_name_is_rewritten_per_documented_limitation
    pipeline = [
      { "$group"   => { "_id" => nil, "author" => { "$first" => "$_p_author" } } },
      { "$project" => { "first_author" => "$author" } },
    ]

    translated = @query.send(:translate_pipeline_for_direct_mongodb, pipeline)

    # $group output key passes through (no key rewriting at all).
    assert_equal "author", translated[0]["$group"].keys.last
    # But the $project reference goes through the schema-aware walker,
    # which sees `author` as a declared pointer and rewrites it.
    # Documented: don't shadow Parse property names with alias names.
    assert_equal "$_p_author", translated[1]["$project"]["first_author"]
  end

  # Aliases that explicitly write a leading-underscore name (`_id`,
  # etc.) pass through verbatim. The convert_field_for_direct_mongodb
  # short-circuit handles `_*` for both expression-value references and
  # the field-name dispatch.
  def test_leading_underscore_alias_passes_through
    stage = {
      "$project" => {
        "_id" => 0,
        "title" => 1,
      },
    }

    rewritten = @query.send(:convert_stage_for_direct_mongodb, stage)

    assert_equal 0, rewritten["$project"]["_id"]
    assert_equal 1, rewritten["$project"]["title"]
  end
end
