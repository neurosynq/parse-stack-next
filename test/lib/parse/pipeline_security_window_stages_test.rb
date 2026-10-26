# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/pipeline_security"
require "parse/clp_scope"
require "parse/acl_scope"
require "parse/atlas_search/protected_paths"

# Protected and internal field references in stages that decide row order,
# partitioning, or filled values without a `$match` / `$sort` key:
# `$setWindowFields`, `$densify`, `$fill`, `$bucket` / `$bucketAuto`,
# `$sortByCount`, and a top-level `$search` / `$searchMeta`.
class PipelineSecurityWindowStagesTest < Minitest::Test
  def setup
    Parse.setup(server_url: "http://localhost:1337/parse",
                application_id: "test", api_key: "test") unless Parse::Client.client?
    Parse::CLPScope.reset_cache!
    Parse::CLPScope.__cache_put("ScopedClass", clp: {
                                                 "find" => { "*" => true },
                                                 "protectedFields" => { "*" => ["ssn", "owner"] },
                                               })
  end

  def teardown
    Parse::CLPScope.reset_cache!
  end

  def scoped_resolution
    Parse::ACLScope.resolve!({ acl_user: Parse::Pointer.new("_User", "alice") }, method_name: :test)
  end

  def master_resolution
    Parse::ACLScope.resolve!({ master: true }, method_name: :test)
  end

  def assert_denies(pipeline, collection: "ScopedClass")
    assert_raises(Parse::CLPScope::Denied) do
      Parse::PipelineSecurity.refuse_protected_field_references!(pipeline, collection, scoped_resolution)
    end
  end

  def assert_permits(pipeline, resolution: scoped_resolution)
    Parse::PipelineSecurity.refuse_protected_field_references!(pipeline, "ScopedClass", resolution)
  end

  def assert_internal_refused(pipeline, allow_internal_fields: false)
    err = assert_raises(Parse::PipelineSecurity::Error) do
      Parse::PipelineSecurity.validate_filter!(pipeline, allow_internal_fields: allow_internal_fields)
    end
    assert_equal :denied_internal_field, err.reason
  end

  # -------- protected fields ------------------------------------------

  def test_set_window_fields_sort_by_protected_key_denied
    assert_denies([{ "$setWindowFields" => {
      "sortBy" => { "ssn" => 1 },
      "output" => { "rank" => { "$rank" => {} } },
    } }])
  end

  def test_set_window_fields_partition_by_protected_ref_denied
    assert_denies([{ "$setWindowFields" => {
      "partitionBy" => "$ssn", "sortBy" => { "createdAt" => 1 },
      "output" => { "n" => { "$documentNumber" => {} } },
    } }])
  end

  def test_set_window_fields_output_ref_denied
    assert_denies([{ "$setWindowFields" => {
      "sortBy" => { "createdAt" => 1 },
      "output" => { "prev" => { "$shift" => { "output" => "$ssn", "by" => -1 } } },
    } }])
  end

  def test_set_window_fields_pointer_storage_sort_key_denied
    assert_denies([{ "$setWindowFields" => {
      "sortBy" => { "_p_owner" => 1 },
      "output" => { "rank" => { "$rank" => {} } },
    } }])
  end

  def test_densify_field_and_partition_denied
    assert_denies([{ "$densify" => { "field" => "ssn", "range" => { "step" => 1, "bounds" => "full" } } }])
    assert_denies([{ "$densify" => {
      "field" => "createdAt", "partitionByFields" => ["ssn"],
      "range" => { "step" => 1, "unit" => "day", "bounds" => "full" },
    } }])
  end

  def test_fill_sort_partition_and_output_denied
    assert_denies([{ "$fill" => { "sortBy" => { "ssn" => 1 }, "output" => { "x" => { "method" => "locf" } } } }])
    assert_denies([{ "$fill" => { "partitionByFields" => ["ssn"], "output" => { "x" => { "value" => 0 } } } }])
    assert_denies([{ "$fill" => { "partitionBy" => { "p" => "$ssn" }, "output" => { "x" => { "value" => 0 } } } }])
    assert_denies([{ "$fill" => { "sortBy" => { "createdAt" => 1 }, "output" => { "ssn" => { "method" => "linear" } } } }])
  end

  def test_sort_by_count_and_bucket_denied
    assert_denies([{ "$sortByCount" => "$ssn" }])
    assert_denies([{ "$bucket" => { "groupBy" => "$ssn", "boundaries" => [0, 5, 10] } }])
    assert_denies([{ "$bucketAuto" => { "groupBy" => { "$toLower" => "$ssn" }, "buckets" => 3 } }])
  end

  def test_search_path_protected_denied
    assert_denies([{ "$search" => { "text" => { "query" => "1", "path" => "ssn" } } }])
    assert_denies([{ "$search" => { "text" => { "query" => "x", "path" => "title" }, "sort" => { "ssn" => 1 } } }])
    assert_denies([{ "$searchMeta" => { "text" => { "query" => "x", "path" => { "wildcard" => "*" } } } }])
    assert_denies([{ "$search" => { "queryString" => { "defaultPath" => "title", "query" => "ssn:1*" } } }])
  end

  def test_unprotected_window_stages_permitted
    assert_permits([{ "$setWindowFields" => {
      "partitionBy" => "$category", "sortBy" => { "createdAt" => 1 },
      "output" => { "running" => { "$sum" => "$plays", "window" => { "documents" => ["unbounded", "current"] } } },
    } }])
    assert_permits([{ "$densify" => { "field" => "day", "partitionByFields" => ["category"], "range" => { "step" => 1, "bounds" => "full" } } }])
    assert_permits([{ "$fill" => { "sortBy" => { "day" => 1 }, "output" => { "plays" => { "method" => "linear" } } } }])
    assert_permits([{ "$sortByCount" => "$category" }])
    assert_permits([{ "$search" => { "text" => { "query" => "x", "path" => "title" } } }])
  end

  def test_master_permits_protected_window_stage
    assert_permits([{ "$setWindowFields" => { "sortBy" => { "ssn" => 1 }, "output" => { "r" => { "$rank" => {} } } } }],
                   resolution: master_resolution)
  end

  def test_facet_branch_window_stage_denied
    assert_denies([{ "$facet" => { "a" => [{ "$fill" => { "partitionByFields" => ["ssn"], "output" => { "x" => { "value" => 0 } } } }] } }])
  end

  def test_scoped_user_search_wildcard_refused
    Parse::CLPScope.__cache_put("_User", clp: { "find" => { "*" => true } })
    assert_denies([{ "$search" => { "text" => { "query" => "x", "path" => { "wildcard" => "*" } } } }], collection: "_User")
  end

  # -------- internal / credential columns for every caller ------------

  def test_densify_credential_field_refused
    assert_internal_refused([{ "$densify" => { "field" => "_failed_login_count", "range" => { "step" => 1, "bounds" => "full" } } }])
    assert_internal_refused([{ "$densify" => { "field" => "day", "partitionByFields" => ["_hashed_password"],
                                               "range" => { "step" => 1, "bounds" => "full" } } }])
  end

  def test_fill_and_window_partition_by_fields_credential_refused
    assert_internal_refused([{ "$fill" => { "partitionByFields" => ["_perishable_token"], "output" => { "x" => { "value" => 0 } } } }])
    assert_internal_refused([{ "$fill" => { "partitionByFields" => ["_auth_data_github"], "output" => { "x" => { "value" => 0 } } } }])
  end

  def test_window_sort_by_and_partition_by_credential_refused
    # Keys and `$field` references reach the existing screens.
    assert_raises(Parse::PipelineSecurity::Error) do
      Parse::PipelineSecurity.validate_filter!([{ "$setWindowFields" => {
        "sortBy" => { "_session_token" => 1 }, "output" => { "r" => { "$rank" => {} } },
      } }])
    end
    assert_raises(Parse::PipelineSecurity::Error) do
      Parse::PipelineSecurity.validate_filter!([{ "$setWindowFields" => {
        "partitionBy" => "$_hashed_password", "output" => { "n" => { "$documentNumber" => {} } },
      } }])
    end
  end

  def test_credential_refused_even_with_allow_internal_fields
    assert_internal_refused([{ "$densify" => { "field" => "_email_verify_token", "range" => { "step" => 1, "bounds" => "full" } } }],
                            allow_internal_fields: true)
  end

  def test_acl_columns_gated_by_allow_internal_fields
    pipeline = [{ "$fill" => { "partitionByFields" => ["_rperm"], "output" => { "x" => { "value" => 0 } } } }]
    assert_internal_refused(pipeline)
    assert Parse::PipelineSecurity.validate_filter!(pipeline, allow_internal_fields: true)
  end

  def test_search_internal_paths_refused
    assert_internal_refused([{ "$search" => { "wildcard" => { "query" => "a*", "path" => "_perishable_token" } } }])
    assert_internal_refused([{ "$searchMeta" => { "autocomplete" => { "query" => "a", "path" => "_hashed_password.x" } } }])
    assert_internal_refused([{ "$search" => { "text" => { "query" => "a", "path" => { "wildcard" => "*token" } } } }])
    assert_internal_refused([{ "$search" => { "text" => { "query" => "a", "path" => ["title", "_session_token"] } } }])
    assert_internal_refused([{ "$search" => { "queryString" => { "defaultPath" => "title", "query" => "_perishable_token:a*" } } }])
  end

  def test_join_and_geo_bare_credential_names_refused
    assert_internal_refused([{ "$lookup" => { "from" => "Post", "localField" => "_hashed_password", "foreignField" => "x", "as" => "j" } }])
    assert_internal_refused([{ "$geoNear" => { "near" => [0, 0], "distanceField" => "d", "key" => "_auth_data_x" } }])
  end

  def test_ordinary_bare_names_pass
    assert Parse::PipelineSecurity.validate_filter!([
      { "$search" => { "text" => { "query" => "a", "path" => ["title", { "wildcard" => "*" }] } } },
      { "$densify" => { "field" => "day", "partitionByFields" => ["category"], "range" => { "step" => 1, "bounds" => "full" } } },
      { "$fill" => { "partitionByFields" => ["category"], "output" => { "plays" => { "value" => 0 } } } },
      { "$lookup" => { "from" => "Post", "localField" => "_p_author", "foreignField" => "_id", "as" => "j" } },
    ])
  end
end
