# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/pipeline_security"
require "parse/clp_scope"
require "parse/acl_scope"

# Wave-3 TRACK-CLP-4: unit tests for
# {Parse::PipelineSecurity.refuse_protected_field_references!}.
#
# Background: Parse Server's protectedFields list tells the SDK which
# columns to strip from result rows for a given session. Until this
# fix, the strip ran AFTER the pipeline produced results — so a caller
# who controlled the pipeline (Agent MCP tool, Query#aggregate, custom
# mongo-direct) could rename the protected field via
# `{$project: {x: "$ssn"}}` and the strip would walk past the renamed
# key because it's not literally named "ssn".
#
# The validator scans the caller-supplied pipeline for any nested
# `$<field>` string whose unprefixed head names a protected column.
# Found → raise {Parse::CLPScope::Denied} so the bypass is loud, not
# silent.
class PipelineSecurityProtectedFieldsTest < Minitest::Test
  def setup
    Parse.setup(server_url: "http://localhost:1337/parse",
                application_id: "test", api_key: "test") unless Parse::Client.client?
    Parse::CLPScope.reset_cache!
    # Class under test: `ScopedClass` declares ssn protected for "*".
    Parse::CLPScope.__cache_put("ScopedClass", clp: {
      "find" => { "*" => true },
      "protectedFields" => { "*" => ["ssn", "internal_notes"] },
    })
  end

  def teardown
    Parse::CLPScope.reset_cache!
  end

  def scoped_resolution
    Parse::ACLScope.resolve!(
      { acl_user: Parse::Pointer.new("_User", "alice") },
      method_name: :test,
    )
  end

  def master_resolution
    Parse::ACLScope.resolve!({ master: true }, method_name: :test)
  end

  def assert_denies(pipeline, expected_field: nil)
    err = assert_raises(Parse::CLPScope::Denied) do
      Parse::PipelineSecurity.refuse_protected_field_references!(
        pipeline, "ScopedClass", scoped_resolution,
      )
    end
    if expected_field
      assert_match(/'#{expected_field}'/, err.message,
                   "expected denial to name the protected field #{expected_field.inspect}")
    end
    err
  end

  def assert_permits(pipeline, resolution: scoped_resolution)
    Parse::PipelineSecurity.refuse_protected_field_references!(
      pipeline, "ScopedClass", resolution,
    )
  end

  # -------- the four classic bypass shapes --------------------------

  def test_addFields_rename_of_protected_field_raises
    assert_denies(
      [{ "$addFields" => { "ssn_copy" => "$ssn" } }],
      expected_field: "ssn",
    )
  end

  def test_set_alias_of_protected_field_raises
    # `$set` is the alias for `$addFields`; same bypass.
    assert_denies(
      [{ "$set" => { "x" => "$ssn" } }],
      expected_field: "ssn",
    )
  end

  def test_project_rename_of_protected_field_raises
    assert_denies(
      [{ "$project" => { "renamed" => "$ssn", "objectId" => 1 } }],
      expected_field: "ssn",
    )
  end

  def test_group_id_referencing_protected_field_raises
    assert_denies(
      [{ "$group" => { "_id" => "$ssn", "count" => { "$sum" => 1 } } }],
      expected_field: "ssn",
    )
  end

  def test_group_accumulator_referencing_protected_field_raises
    # `$first: "$ssn"` is a per-group sample of a protected column —
    # another bypass shape.
    assert_denies(
      [{ "$group" => { "_id" => "$grp", "first_ssn" => { "$first" => "$ssn" } } }],
      expected_field: "ssn",
    )
  end

  # -------- additional bypass shapes --------------------------------

  def test_bucket_groupBy_referencing_protected_field_raises
    assert_denies(
      [{ "$bucket" => {
        "groupBy" => "$ssn",
        "boundaries" => [0, 100, 200],
        "default" => "other",
      } }],
      expected_field: "ssn",
    )
  end

  def test_bucketAuto_groupBy_referencing_protected_field_raises
    assert_denies(
      [{ "$bucketAuto" => { "groupBy" => "$ssn", "buckets" => 4 } }],
      expected_field: "ssn",
    )
  end

  def test_replaceWith_referencing_protected_field_raises
    assert_denies(
      [{ "$replaceWith" => "$internal_notes" }],
      expected_field: "internal_notes",
    )
  end

  def test_replaceRoot_newRoot_referencing_protected_field_raises
    assert_denies(
      [{ "$replaceRoot" => { "newRoot" => "$ssn" } }],
      expected_field: "ssn",
    )
  end

  def test_lookup_let_binding_referencing_protected_field_raises
    # `let` captures source-class values into variables usable inside
    # the join's sub-pipeline — a `let: { v: "$ssn" }` reads the
    # protected source-class field and re-exposes it inside the join.
    assert_denies(
      [{ "$lookup" => {
        "from" => "Other",
        "let" => { "user_ssn" => "$ssn" },
        "pipeline" => [{ "$match" => { "$expr" => { "$eq" => ["$_id", "$$user_ssn"] } } }],
        "as" => "rows",
      } }],
      expected_field: "ssn",
    )
  end

  def test_nested_project_inside_lookup_pipeline_raises
    # Even a sub-pipeline `$project` referencing the source class's
    # protected field via `$$<bound_var>` won't be caught (it's a
    # variable, not a field), but a direct `$ssn` reference inside the
    # sub-pipeline is still a leak — though, in practice, the
    # sub-pipeline runs in the joined collection's context. The walker
    # walks recursively, so any `$ssn` reference anywhere in the
    # pipeline shape is gated. This matches the conservative posture.
    assert_denies(
      [{ "$lookup" => {
        "from" => "Other",
        "pipeline" => [{ "$addFields" => { "leak" => "$ssn" } }],
        "as" => "rows",
      } }],
      expected_field: "ssn",
    )
  end

  # -------- safe shapes (must pass) ---------------------------------

  def test_master_mode_passthrough
    # Master mode has no protectedFields constraint; pipeline runs.
    assert_permits(
      [{ "$addFields" => { "x" => "$ssn" } }],
      resolution: master_resolution,
    )
  end

  def test_nil_resolution_passthrough
    Parse::PipelineSecurity.refuse_protected_field_references!(
      [{ "$addFields" => { "x" => "$ssn" } }], "ScopedClass", nil,
    )
  end

  def test_non_protected_field_reference_passes
    assert_permits([{ "$project" => { "renamed" => "$title", "objectId" => 1 } }])
  end

  def test_variable_reference_with_double_dollar_passes
    # `$$ROOT`, `$$CURRENT`, user-defined let variables — all
    # legitimate aggregation variables, not field references.
    assert_permits([{ "$replaceRoot" => { "newRoot" => "$$ROOT" } }])
    assert_permits([{ "$match" => { "$expr" => { "$eq" => ["$x", "$$ssn"] } } }])
  end

  def test_id_reference_passes
    # `$_id` is the canonical primary-key reference; common in group/sort
    # stages and never appears on a protectedFields list.
    assert_permits([{ "$group" => { "_id" => "$_id", "n" => { "$sum" => 1 } } }])
  end

  def test_class_with_no_protected_fields_passes
    # `Unrestricted` has no protectedFields; the walker short-circuits
    # before scanning.
    Parse::CLPScope.__cache_put("Unrestricted", clp: { "find" => { "*" => true } })
    Parse::PipelineSecurity.refuse_protected_field_references!(
      [{ "$addFields" => { "x" => "$ssn" } }], "Unrestricted", scoped_resolution,
    )
  end

  def test_dotted_path_with_protected_head_raises
    # `$ssn.area` references `ssn` at the head. Protected.
    assert_denies(
      [{ "$project" => { "code" => "$ssn.area" } }],
      expected_field: "ssn",
    )
  end

  def test_dotted_path_with_non_protected_head_passes
    # `$address.ssn` references `address` at the head — NOT protected
    # by Parse Server's per-column CLP. (Protecting nested keys
    # requires a different mechanism; we faithfully mirror Parse's
    # column-level granularity.)
    assert_permits([{ "$project" => { "code" => "$address.ssn" } }])
  end

  def test_empty_pipeline_no_op
    Parse::PipelineSecurity.refuse_protected_field_references!(
      [], "ScopedClass", scoped_resolution,
    )
  end

  def test_nil_pipeline_no_op
    Parse::PipelineSecurity.refuse_protected_field_references!(
      nil, "ScopedClass", scoped_resolution,
    )
  end
end
