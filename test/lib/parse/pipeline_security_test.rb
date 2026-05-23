require_relative "../../test_helper"
require "parse/mongodb"

# Tests for the unified Parse::PipelineSecurity validator that replaced
# three separate validators (Parse::Agent::PipelineValidator, the inline
# Parse::Query#validate_pipeline!, and Parse::MongoDB.assert_no_denied_operators!).
class PipelineSecurityTest < Minitest::Test
  PS = Parse::PipelineSecurity

  # --- validate_pipeline! (strict, allowlist + caps) ---

  def test_validate_pipeline_accepts_simple_match_group
    PS.validate_pipeline!([
      { "$match" => { "status" => "active" } },
      { "$group" => { "_id" => "$category", "n" => { "$sum" => 1 } } },
    ])
  end

  def test_validate_pipeline_allows_atlas_search_stages
    PS.validate_pipeline!([{ "$search" => { "index" => "default" } }])
    PS.validate_pipeline!([{ "$searchMeta" => { "index" => "default" } }])
    PS.validate_pipeline!([{ "$listSearchIndexes" => {} }])
  end

  def test_validate_pipeline_rejects_non_array
    assert_raises(PS::Error) { PS.validate_pipeline!({}) }
    assert_raises(PS::Error) { PS.validate_pipeline!(nil) }
  end

  def test_validate_pipeline_rejects_empty
    assert_raises(PS::Error) { PS.validate_pipeline!([]) }
  end

  def test_validate_pipeline_rejects_too_many_stages
    too_many = Array.new(PS::MAX_PIPELINE_STAGES + 1) { { "$match" => {} } }
    err = assert_raises(PS::Error) { PS.validate_pipeline!(too_many) }
    assert_match(/exceeds maximum/, err.message)
  end

  def test_validate_pipeline_rejects_unknown_stage
    err = assert_raises(PS::Error) do
      PS.validate_pipeline!([{ "$mystery_stage" => {} }])
    end
    assert_match(/Unknown aggregation stage/, err.message)
  end

  def test_validate_pipeline_rejects_out_stage
    err = assert_raises(PS::Error) { PS.validate_pipeline!([{ "$out" => "x" }]) }
    assert_match(/denied/, err.message)
    assert_equal "$out", err.operator
  end

  def test_validate_pipeline_rejects_merge_stage
    err = assert_raises(PS::Error) { PS.validate_pipeline!([{ "$merge" => { "into" => "x" } }]) }
    assert_equal "$merge", err.operator
  end

  def test_validate_pipeline_rejects_where_nested_in_match
    err = assert_raises(PS::Error) do
      PS.validate_pipeline!([{ "$match" => { "$where" => "this.x > 0" } }])
    end
    assert_match(/SECURITY/, err.message)
    assert_equal "$where", err.operator
  end

  def test_validate_pipeline_rejects_function_nested_in_facet
    pipeline = [{
      "$facet" => {
        "side" => [{
          "$addFields" => {
            "x" => { "$function" => { "body" => "function() { return 1 }", "args" => [], "lang" => "js" } },
          },
        }],
      },
    }]
    err = assert_raises(PS::Error) { PS.validate_pipeline!(pipeline) }
    assert_equal "$function", err.operator
  end

  def test_validate_pipeline_rejects_where_inside_lookup_pipeline
    pipeline = [{
      "$lookup" => {
        "from" => "users",
        "let" => {},
        "pipeline" => [{ "$match" => { "$where" => "this.admin" } }],
        "as" => "joined",
      },
    }]
    err = assert_raises(PS::Error) { PS.validate_pipeline!(pipeline) }
    assert_equal "$where", err.operator
  end

  def test_validate_pipeline_rejects_out_inside_union_with
    pipeline = [{
      "$unionWith" => { "coll" => "other", "pipeline" => [{ "$out" => "exfil" }] },
    }]
    err = assert_raises(PS::Error) { PS.validate_pipeline!(pipeline) }
    assert_equal "$out", err.operator
  end

  # --- validate_filter! (permissive, denylist-only) ---

  def test_validate_filter_accepts_normal_filter
    PS.validate_filter!({ "name" => "alice", "age" => { "$gte" => 18 } })
  end

  def test_validate_filter_passes_nil_and_primitives
    PS.validate_filter!(nil)
    PS.validate_filter!("string")
    PS.validate_filter!(42)
  end

  def test_validate_filter_rejects_top_level_where
    err = assert_raises(PS::Error) { PS.validate_filter!({ "$where" => "this.x" }) }
    assert_equal "$where", err.operator
  end

  def test_validate_filter_rejects_nested_where
    err = assert_raises(PS::Error) do
      PS.validate_filter!({ "$and" => [{ "x" => 1 }, { "$where" => "this.y" }] })
    end
    assert_equal "$where", err.operator
  end

  def test_validate_filter_rejects_function_in_expr
    err = assert_raises(PS::Error) do
      PS.validate_filter!({
        "$expr" => {
          "$function" => { "body" => "function() { return 1 }", "args" => [], "lang" => "js" },
        },
      })
    end
    assert_equal "$function", err.operator
  end

  def test_validate_filter_rejects_accumulator
    err = assert_raises(PS::Error) do
      PS.validate_filter!({ "$group" => { "x" => { "$accumulator" => {} } } })
    end
    assert_equal "$accumulator", err.operator
  end

  def test_validate_filter_handles_symbol_keys
    err = assert_raises(PS::Error) { PS.validate_filter!({ :$where => "x" }) }
    assert_equal "$where", err.operator
  end

  def test_validate_filter_walks_arrays
    err = assert_raises(PS::Error) do
      PS.validate_filter!([{ "$where" => "x" }])
    end
    assert_equal "$where", err.operator
  end

  def test_validate_filter_rejects_pathological_nesting
    deep = { "k" => "v" }
    (PS::MAX_DEPTH + 5).times { deep = { "k" => deep } }
    err = assert_raises(PS::Error) { PS.validate_filter!(deep) }
    assert_match(/nesting/i, err.message)
  end

  # --- error class shape ---

  def test_error_is_subclass_of_parse_error
    assert PS::Error < Parse::Error
  end

  def test_error_carries_stage_operator_reason
    err = assert_raises(PS::Error) { PS.validate_pipeline!([{ "$where" => "x" }]) }
    assert_equal 0, err.stage
    assert_equal "$where", err.operator
    assert_equal :denied_operator, err.reason
  end

  # --- Query#validate_pipeline! delegation ---

  def test_query_validate_pipeline_uses_permissive_mode
    # Permissive mode means uncommon-but-legitimate read stages should pass.
    # $densify is a real MongoDB read stage not in the strict allowlist.
    query = Parse::Query.new("Song")
    assert query.validate_pipeline!([{ "$densify" => { "field" => "ts" } }])
  end

  def test_query_validate_pipeline_still_blocks_denied
    query = Parse::Query.new("Song")
    assert_raises(ArgumentError) { query.validate_pipeline!([{ "$out" => "x" }]) }
    assert_raises(ArgumentError) do
      query.validate_pipeline!([{ "$match" => { "$where" => "x" } }])
    end
  end

  # --- Atlas Search filter passthrough ---

  def test_atlas_search_convert_filter_rejects_where
    require "parse/atlas_search"
    err = assert_raises(Parse::PipelineSecurity::Error) do
      Parse::AtlasSearch.send(:convert_filter_for_mongodb, { "$where" => "x" }, "Song")
    end
    assert_equal "$where", err.operator
  end

  def test_atlas_search_convert_filter_passes_normal_filter
    require "parse/atlas_search"
    filter = { "tag" => "rock", "year" => { "$gte" => 2020 } }
    assert_equal filter, Parse::AtlasSearch.send(:convert_filter_for_mongodb, filter, "Song")
  end

  def test_atlas_search_convert_filter_passes_nil
    require "parse/atlas_search"
    assert_nil Parse::AtlasSearch.send(:convert_filter_for_mongodb, nil, "Song")
  end

  # --- $graphLookup recursion (allowlist member, denylist must still walk through) ---

  def test_validate_pipeline_rejects_where_inside_graph_lookup
    pipeline = [{
      "$graphLookup" => {
        "from" => "users",
        "startWith" => "$_id",
        "connectFromField" => "_id",
        "connectToField" => "manager",
        "as" => "chain",
        "restrictSearchWithMatch" => { "$where" => "this.admin" },
      },
    }]
    err = assert_raises(PS::Error) { PS.validate_pipeline!(pipeline) }
    assert_equal "$where", err.operator
  end

  # --- nested symbol keys (HashWithIndifferentAccess-style callers) ---

  def test_validate_filter_rejects_symbol_where_nested_in_array
    err = assert_raises(PS::Error) do
      PS.validate_filter!({ "$and" => [{ "x" => 1 }, { :$where => "boom" }] })
    end
    assert_equal "$where", err.operator
  end

  # --- Query#validate_pipeline! re-raise contract ---

  def test_query_validate_pipeline_reraises_as_argument_error
    query = Parse::Query.new("Song")
    err = assert_raises(ArgumentError) do
      query.validate_pipeline!([{ "$match" => { "$where" => "this.admin" } }])
    end
    assert_match(/SECURITY/, err.message)
    assert_match(/\$where/, err.message)
  end

  # --- PipelineValidator shim preserves stage/reason/operator ---

  def test_pipeline_validator_shim_preserves_attributes
    err = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!([{ "$out" => "exfil" }])
    end
    assert_equal 0, err.stage
    assert_equal :denied_operator, err.reason
    assert_equal "$out", err.operator
  end

  def test_pipeline_validator_shim_preserves_operator_for_nested_violation
    pipeline = [{
      "$facet" => {
        "side" => [{ "$out" => "exfil" }],
      },
    }]
    err = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!(pipeline)
    end
    assert_equal "$out", err.operator
    assert_equal :nested_denied_operator, err.reason
  end

  # The Atlas stage-0-only operators ($search, $searchMeta,
  # $vectorSearch, $listSearchIndexes) are present in
  # `PipelineSecurity::ALLOWED_STAGES` so the SDK's own modules can
  # emit them, but they must NEVER be accepted from a caller-supplied
  # agent pipeline. The proper agent surface for those stages is the
  # dedicated atlas_search / semantic_search tools.
  def test_pipeline_validator_refuses_vector_search_stage
    err = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!([
        { "$vectorSearch" => { "index" => "i", "path" => "embedding", "queryVector" => [0.1], "numCandidates" => 10, "limit" => 1 } },
      ])
    end
    assert_equal "$vectorSearch", err.stage
    assert_equal :stage0_only_atlas_stage, err.reason
  end

  def test_pipeline_validator_refuses_atlas_search_stages
    %w[$search $searchMeta $listSearchIndexes].each do |op|
      err = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
        Parse::Agent::PipelineValidator.validate!([{ op => { "index" => "i" } }])
      end
      assert_equal op, err.stage
      assert_equal :stage0_only_atlas_stage, err.reason
    end
  end

  def test_pipeline_security_still_allows_vector_search_internally
    # The SDK-internal validator still accepts the stage so
    # Parse::VectorSearch / Parse::AtlasSearch's own pipelines pass
    # any subsequent PipelineSecurity validation.
    assert(
      Parse::PipelineSecurity.validate_pipeline!([
        { "$vectorSearch" => { "index" => "i", "path" => "embedding", "queryVector" => [0.1], "numCandidates" => 10, "limit" => 1 } },
      ])
    )
  end

  # --- end-to-end DeniedOperator via Parse::MongoDB ---

  def test_mongodb_find_raises_denied_operator_on_where_filter
    # Stub the underlying client.find so we never actually hit MongoDB; the
    # denylist check happens before the cursor is built, so reaching .find
    # would itself be a bug.
    Parse::MongoDB.stub(:collection, ->(_name) { raise "should not reach collection" }) do
      assert_raises(Parse::MongoDB::DeniedOperator) do
        Parse::MongoDB.find("Song", { "$where" => "this.plays > 0" })
      end
    end
  end

  def test_mongodb_aggregate_raises_denied_operator_on_function_in_pipeline
    Parse::MongoDB.stub(:collection, ->(_name) { raise "should not reach collection" }) do
      pipeline = [{
        "$addFields" => {
          "computed" => { "$function" => { "body" => "function() {}", "args" => [], "lang" => "js" } },
        },
      }]
      assert_raises(Parse::MongoDB::DeniedOperator) do
        Parse::MongoDB.aggregate("Song", pipeline)
      end
    end
  end

  def test_mongodb_aggregate_passes_safe_pipeline_to_collection
    # Confirm the validator does NOT trip on a legitimate pipeline. We stub
    # collection() to capture the call and return a fake aggregator.
    fake_cursor = Class.new do
      def to_a; [{ "_id" => 1, "n" => 5 }] end
    end.new
    fake_collection = Class.new do
      def initialize(c); @c = c end
      def aggregate(_p, _opts = {}); @c end
    end.new(fake_cursor)

    Parse::MongoDB.stub(:collection, ->(_name) { fake_collection }) do
      # master: true bypasses Wave-3 fail-closed CLP — this test
      # exercises the validator/aggregate plumbing, not the auth path.
      results = Parse::MongoDB.aggregate("Song", [
        { "$match" => { "status" => "active" } },
        { "$group" => { "_id" => "$category", "n" => { "$sum" => 1 } } },
      ], master: true)
      assert_equal [{ "_id" => 1, "n" => 5 }], results
    end
  end
end
