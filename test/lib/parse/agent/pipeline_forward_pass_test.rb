# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Forward-pass field-availability tracking for the pipeline access
# policy. Source-class `agent_fields` allowlist gates references to
# source-collection fields, but stages like $group, $project,
# $addFields, $lookup, $bucket introduce NEW fields that downstream
# stages must be able to reference. Without forward-pass tracking, the
# canonical "group → filter → sort → limit" pattern failed because
# accumulator outputs (e.g. `count`) were rejected as "outside the
# allowlist."
#
# This test matrix pins:
#   * `$group` introduces `_id` + accumulator keys; downstream
#     `$match`/`$sort`/`$project` may reference them.
#   * `$addFields` / `$set` extend the schema without replacing it.
#   * `$lookup` makes its `as:` name addressable downstream.
#   * `$project` replaces the schema — source fields not in the
#     projection are no longer addressable.
#   * `$facet` branches each get a fresh forward-pass starting from
#     the pre-facet state.
#   * Source-allowlist enforcement still fires for source references
#     that are NEVER in the allowlist (pre-stage), and for synthetic
#     references the caller never introduced.
class PipelineForwardPassTest < Minitest::Test
  class PFPCapture < Parse::Object
    parse_class "PFPCapture"
    agent_description "Forward-pass fixture class"
    agent_fields :author, :project, :status, :created_at
    property :author, :pointer, class_name: "_User"
    property :project, :pointer, class_name: "Project"
    property :status, :string
  end

  class PFPProject < Parse::Object
    parse_class "PFPProject"
    agent_fields :name, :owner
    property :name, :string
    property :owner, :pointer, class_name: "_User"
  end

  def aggregate(pipeline, class_name: "PFPCapture")
    Parse::Agent::Tools.enforce_pipeline_access_policy!(class_name, pipeline)
  end

  # ─── $group → downstream synthetic-field references ───────────────────

  def test_group_then_match_on_synthetic_count_passes
    aggregate([
      { "$group" => { "_id" => "$author", "count" => { "$sum" => 1 } } },
      { "$match" => { "count" => { "$gte" => 5 } } },
    ])
  end

  def test_group_then_sort_by_synthetic_count_passes
    aggregate([
      { "$group" => { "_id" => "$author", "count" => { "$sum" => 1 } } },
      { "$sort"  => { "count" => -1 } },
      { "$limit" => 10 },
    ])
  end

  def test_group_then_project_keeping_synthetic_passes
    aggregate([
      { "$group" => { "_id" => "$author", "n" => { "$sum" => 1 } } },
      { "$project" => { "_id" => 1, "n" => 1 } },
    ])
  end

  def test_group_then_match_on_unintroduced_synthetic_fails
    err = assert_raises(Parse::Agent::AccessDenied) do
      aggregate([
        { "$group" => { "_id" => "$author", "count" => { "$sum" => 1 } } },
        { "$match" => { "average" => { "$gte" => 1 } } },
      ])
    end
    assert_match(/match field|average/, err.message)
  end

  def test_chained_group_to_group_to_match_passes
    aggregate([
      { "$group" => { "_id" => "$author", "n" => { "$sum" => 1 } } },
      { "$group" => { "_id" => "$_id", "total" => { "$sum" => "$n" } } },
      { "$match" => { "total" => { "$gte" => 10 } } },
    ])
  end

  # ─── $addFields / $set extend the schema ─────────────────────────────

  def test_add_fields_introduces_new_field_addressable_downstream
    aggregate([
      { "$addFields" => { "computed" => { "$concat" => ["$status", "_x"] } } },
      { "$match"     => { "computed" => "active_x" } },
    ])
  end

  def test_set_introduces_new_field_addressable_downstream
    aggregate([
      { "$set"   => { "marker" => { "$literal" => 42 } } },
      { "$sort"  => { "marker" => 1, "status" => -1 } },
    ])
  end

  def test_add_fields_rejects_output_key_mirroring_internal_column
    err = assert_raises(Parse::Agent::AccessDenied) do
      aggregate([
        { "$addFields" => { "_hashed_password" => { "$literal" => "x" } } },
      ])
    end
    assert_match(/_hashed_password|internal Parse Server column/, err.message)
  end

  def test_set_rejects_output_key_with_denied_prefix
    err = assert_raises(Parse::Agent::AccessDenied) do
      aggregate([
        { "$set" => { "_auth_data_facebook" => { "$literal" => "x" } } },
      ])
    end
    assert_match(/_auth_data|internal Parse Server column/, err.message)
  end

  def test_add_fields_still_allows_source_fields_downstream
    # $addFields is schema-EXTENDING, not replacing.
    aggregate([
      { "$addFields" => { "extra" => { "$literal" => "z" } } },
      { "$match"     => { "status" => "x", "extra" => "z" } },
    ])
  end

  # ─── $project replaces the schema ────────────────────────────────────

  def test_project_then_match_on_projected_field_passes
    aggregate([
      { "$project" => { "status" => 1, "objectId" => 1 } },
      { "$match"   => { "status" => "active" } },
    ])
  end

  def test_project_then_match_on_unprojected_source_field_fails
    # Source schema replaced; `author` is in the source allowlist but
    # wasn't projected, so it's not addressable downstream.
    err = assert_raises(Parse::Agent::AccessDenied) do
      aggregate([
        { "$project" => { "status" => 1 } },
        { "$match"   => { "author" => "abc" } },
      ])
    end
    assert_match(/match field|author/, err.message)
  end

  # ─── $lookup.as becomes addressable ──────────────────────────────────

  def test_lookup_as_field_is_addressable_downstream
    aggregate([
      { "$lookup" => {
        "from"         => "PFPProject",
        "localField"   => "project",
        "foreignField" => "objectId",
        "as"           => "project_doc",
      } },
      { "$match" => { "project_doc" => { "$ne" => [] } } },
    ])
  end

  # ─── $bucket / $bucketAuto / $sortByCount / $count ───────────────────

  def test_bucket_introduces_id_and_output_keys
    aggregate([
      { "$bucket" => {
        "groupBy"     => "$status",
        "boundaries"  => ["a", "m", "z"],
        "default"     => "other",
        "output"      => { "count" => { "$sum" => 1 } },
      } },
      { "$match" => { "_id" => "other", "count" => { "$gte" => 1 } } },
    ])
  end

  def test_bucket_auto_default_output_is_count
    aggregate([
      { "$bucketAuto" => { "groupBy" => "$status", "buckets" => 3 } },
      { "$sort"       => { "count" => -1 } },
    ])
  end

  def test_sort_by_count_introduces_id_and_count
    aggregate([
      { "$sortByCount" => "$status" },
      { "$project"     => { "_id" => 1, "count" => 1 } },
    ])
  end

  def test_count_stage_introduces_named_field
    aggregate([
      { "$match" => { "status" => "x" } },
      { "$count" => "total" },
      { "$project" => { "total" => 1 } },
    ])
  end

  def test_count_stage_with_empty_string_does_not_register_anything
    # MongoDB rejects `{$count: ""}` server-side; the validator must
    # not register the empty string as an available field either,
    # since the downstream walker's empty-root guard would let a
    # subsequent `$match { "": ... }` pass without enforcement.
    err = assert_raises(Parse::Agent::AccessDenied) do
      aggregate([
        { "$count" => "" },
        { "$project" => { "anything" => 1 } },
      ])
    end
    assert_match(/anything|field/, err.message)
  end

  # ─── $facet branches isolated from one another ───────────────────────

  def test_facet_branches_each_get_fresh_forward_pass
    aggregate([
      { "$facet" => {
        "by_author" => [
          { "$group" => { "_id" => "$author", "n" => { "$sum" => 1 } } },
          { "$match" => { "n" => { "$gte" => 1 } } },
        ],
        "by_status" => [
          { "$group" => { "_id" => "$status", "total" => { "$sum" => 1 } } },
          { "$sort"  => { "total" => -1 } },
        ],
      } },
    ])
  end

  def test_facet_branch_does_not_leak_state_to_sibling_branch
    # by_author introduces `n` in its branch; by_status introduces
    # `total`. A reference to `n` from by_status would fail because
    # branches don't share evolved state.
    err = assert_raises(Parse::Agent::AccessDenied) do
      aggregate([
        { "$facet" => {
          "by_author" => [
            { "$group" => { "_id" => "$author", "n" => { "$sum" => 1 } } },
          ],
          "by_status" => [
            { "$group" => { "_id" => "$status", "total" => { "$sum" => 1 } } },
            { "$match" => { "n" => 1 } },
          ],
        } },
      ])
    end
    assert_match(/match field|n/, err.message)
  end

  # ─── Source-allowlist still enforced pre-introduction ────────────────

  def test_group_id_referencing_non_allowlisted_source_field_fails
    err = assert_raises(Parse::Agent::AccessDenied) do
      aggregate([
        { "$group" => { "_id" => "$ssn", "n" => { "$sum" => 1 } } },
      ])
    end
    assert_match(/field reference|ssn/, err.message)
  end

  def test_match_on_non_allowlisted_field_before_introduction_fails
    err = assert_raises(Parse::Agent::AccessDenied) do
      aggregate([
        { "$match" => { "ssn" => "1234" } },
      ])
    end
    assert_match(/match field|ssn/, err.message)
  end

  # ─── No-allowlist class continues to bypass field checks ─────────────

  class PFPUnrestricted < Parse::Object
    parse_class "PFPUnrestricted"
    # No agent_fields declared — no allowlist enforcement.
    property :name, :string
  end

  def test_no_allowlist_means_no_field_enforcement_regardless_of_stages
    aggregate([
      { "$group" => { "_id" => "$anything", "tally" => { "$sum" => 1 } } },
      { "$match" => { "anything_else" => 1, "tally" => 1 } },
    ], class_name: "PFPUnrestricted")
  end

  # ─── Regressions for review-flagged bugs ────────────────────────────

  def test_sort_by_count_with_non_allowlisted_field_ref_fails
    # Prior to the fix, $sortByCount's string value silently bypassed
    # the allowlist (the walker guarded on value.is_a?(Hash)). This
    # asserts that `$sortByCount: "$ssn"` against a class without `ssn`
    # in agent_fields now raises.
    err = assert_raises(Parse::Agent::AccessDenied) do
      aggregate([{ "$sortByCount" => "$ssn" }])
    end
    assert_match(/field reference|ssn/, err.message)
  end

  def test_project_exclusion_only_keeps_source_fields_addressable
    # $project { _id: 0 } drops _id but keeps every other field —
    # downstream $match on a source-allowlisted field must still pass.
    aggregate([
      { "$project" => { "_id" => 0 } },
      { "$match"   => { "author" => "abc", "status" => "x" } },
    ])
  end

  def test_project_mixed_inclusion_with_id_exclusion_still_replaces_schema
    # `{name: 1, _id: 0}` is the canonical "show name, hide _id" shape
    # — still inclusion-mode, so downstream references to other source
    # fields must fail.
    err = assert_raises(Parse::Agent::AccessDenied) do
      aggregate([
        { "$project" => { "status" => 1, "_id" => 0 } },
        { "$match"   => { "author" => "x" } },
      ])
    end
    assert_match(/author/, err.message)
  end

  def test_bucket_without_explicit_output_defaults_to_count
    # $bucket emits `{_id, count}` when no `output` is supplied,
    # matching $bucketAuto. Prior to the fix only $bucketAuto did this.
    aggregate([
      { "$bucket" => { "groupBy" => "$status", "boundaries" => ["a", "m"], "default" => "other" } },
      { "$sort"   => { "count" => -1 } },
    ])
  end

  def test_unwind_with_include_array_index_registers_index_field
    aggregate([
      { "$unwind" => { "path" => "$status", "includeArrayIndex" => "idx" } },
      { "$sort"   => { "idx" => 1 } },
    ])
  end

  def test_set_window_fields_introduces_output_keys
    aggregate([
      { "$setWindowFields" => {
        "partitionBy" => "$status",
        "sortBy"      => { "createdAt" => 1 },
        "output"      => { "rolling_total" => { "$sum" => 1 } },
      } },
      { "$match" => { "rolling_total" => { "$gte" => 1 } } },
    ])
  end

  def test_project_dotted_path_registers_root_for_downstream_match
    # `{"author.objectId": 1}` introduces the `author` root downstream,
    # not the literal "author.objectId" string. Without root
    # normalization, `$match { author: ... }` would fail because the
    # walker splits the match key on "." and looks up the root.
    aggregate([
      { "$project" => { "author.objectId" => 1, "status" => 1 } },
      { "$match"   => { "author" => "abc" } },
    ])
  end

  def test_add_fields_dotted_output_key_registers_root_for_downstream_match
    # Same root-normalization that $project gets — $addFields { "user.x": ... }
    # should register `user` as available downstream, not the literal
    # "user.x". Without this, $match { user: ... } would fail because
    # the walker looks up the root segment.
    aggregate([
      { "$addFields" => { "user.derived" => { "$literal" => "z" } } },
      { "$match"     => { "user" => "abc" } },
    ])
  end

  def test_set_window_fields_dotted_output_key_registers_root
    aggregate([
      { "$setWindowFields" => {
        "partitionBy" => "$status",
        "sortBy"      => { "createdAt" => 1 },
        "output"      => { "audit.running_total" => { "$sum" => 1 } },
      } },
      { "$match" => { "audit" => { "$exists" => true } } },
    ])
  end

  def test_project_compute_output_key_rejected_when_mirroring_internal_column
    err = assert_raises(Parse::Agent::AccessDenied) do
      aggregate([
        { "$project" => { "sessionToken" => "$status" } },
      ])
    end
    assert_match(/sessionToken|internal Parse Server column/, err.message)
  end
end
