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

  # --- redact_internal_fields_deep! (RT-1: $lookup foreign-doc credential leak) ---

  def test_redact_internal_fields_deep_strips_embedded_credentials
    # A Post row with a _User document embedded via $lookup as: "leak".
    row = {
      "_id" => "post1", "_p_author" => "_User$u1", "_acl" => { "u1" => { "r" => true } },
      "title" => "hello", "_rperm" => ["*"],
      "leak" => [
        { "_id" => "u1", "username" => "alice",
          "_hashed_password" => "$2b$10$secret",
          "_auth_data_google" => { "access_token" => "ya29.SECRET" },
          "_session_token" => "r:TOKEN", "_email_verify_token" => "v",
          "_rperm" => ["*"], "_p_org" => "Tenant$t1" },
      ],
    }
    PS.redact_internal_fields_deep!(row)

    leak = row["leak"].first
    # Credentials stripped from the embedded foreign document at depth.
    %w[_hashed_password _auth_data_google _session_token _email_verify_token _rperm].each do |k|
      refute leak.key?(k), "embedded #{k} must be stripped"
    end
    # Structural columns preserved for object reconstruction.
    %w[_id username _p_org].each { |k| assert leak.key?(k), "embedded #{k} must survive" }
    # Top-level _rperm stripped; ACL / pointer / id reconstruction columns kept.
    refute row.key?("_rperm")
    %w[_id _p_author _acl title].each { |k| assert row.key?(k), "top-level #{k} must survive" }
  end

  def test_redact_internal_fields_deep_handles_arrays_and_scalars
    node = { "list" => [{ "_session_token" => "x", "ok" => 1 }, 42, "str"], "n" => 5 }
    PS.redact_internal_fields_deep!(node)
    refute node["list"].first.key?("_session_token")
    assert_equal 1, node["list"].first["ok"]
    assert_equal [{ "ok" => 1 }, 42, "str"], node["list"]
    assert_equal 5, node["n"]
  end

  def test_redact_internal_fields_deep_strips_auth_data_prefix_and_symbol_keys
    node = { "_auth_data_facebook" => { "id" => 1 }, :_hashed_password => "h", "keep" => "v" }
    PS.redact_internal_fields_deep!(node)
    refute node.key?("_auth_data_facebook")
    refute node.key?(:_hashed_password)
    assert_equal "v", node["keep"]
  end

  def test_redact_internal_fields_deep_is_depth_bounded
    # Build a chain deeper than the bound; the call must terminate (no stack
    # overflow / infinite recursion) and clean the top level within the bound.
    leaf = { "_session_token" => "x" }
    (PS::INTERNAL_REDACT_MAX_DEPTH + 5).times do
      leaf = { "child" => leaf, "_session_token" => "y" }
    end
    PS.redact_internal_fields_deep!(leaf)
    refute leaf.key?("_session_token"), "top level always cleaned"
    # Reaching here (no exception) confirms the recursion terminates.
  end

  # --- RT-2: credential match-keys refused even under allow_internal_fields ---

  def test_credential_field_match_key_refused_even_with_allow_internal_fields
    # allow_internal_fields: true is what the `*_direct` terminals pass so
    # SDK-emitted _rperm/_wperm references survive. It must NOT relax a
    # user-supplied credential column used as a $match key (a count/match
    # oracle that bisects a bcrypt hash / session token char-by-char).
    %w[_hashed_password _session_token _email_verify_token _perishable_token
       _password_history _auth_data_google].each do |field|
      err = assert_raises(PS::Error, "#{field} must be refused") do
        PS.validate_filter!({ field => { "$regex" => "^x" } }, allow_internal_fields: true)
      end
      assert_equal field, err.operator
      assert_equal :denied_internal_field, err.reason
    end
  end

  def test_credential_field_match_key_refused_when_nested
    err = assert_raises(PS::Error) do
      PS.validate_filter!({ "$or" => [{ "x" => 1 }, { "_session_token" => "r:t" }] },
                          allow_internal_fields: true)
    end
    assert_equal "_session_token", err.operator
  end

  def test_acl_columns_allowed_with_allow_internal_fields_but_gated_without
    # _rperm/_wperm are emitted by readable_by_role / publicly_readable, so they
    # must pass when allow_internal_fields: true ...
    PS.validate_filter!({ "_rperm" => { "$in" => ["*", "role:Admin"] } }, allow_internal_fields: true)
    PS.validate_filter!({ "_wperm" => { "$in" => ["*"] } }, allow_internal_fields: true)
    # ... and stay refused when allow_internal_fields: false (unchanged).
    assert_raises(PS::Error) { PS.validate_filter!({ "_rperm" => { "$in" => ["*"] } }) }
  end

  def test_credential_denylist_excludes_acl_columns
    assert_includes PS::CREDENTIAL_FIELDS_DENYLIST, "_hashed_password"
    assert_includes PS::CREDENTIAL_FIELDS_DENYLIST, "_session_token"
    refute_includes PS::CREDENTIAL_FIELDS_DENYLIST, "_rperm"
    refute_includes PS::CREDENTIAL_FIELDS_DENYLIST, "_wperm"
  end

  # --- RT-6: camelCase $sessionToken / $session_token field refs denied ---

  def test_camelcase_session_token_field_refs_are_denied
    assert_includes PS::DENIED_FIELD_REFS, "$sessionToken"
    assert_includes PS::DENIED_FIELD_REFS, "$session_token"
    # And the validator refuses them as a $-field reference (e.g. laundering
    # via a $project/$expr rename).
    assert_raises(PS::Error) do
      PS.validate_pipeline!([{ "$project" => { "leak" => "$sessionToken" } }])
    end
    assert_raises(PS::Error) do
      PS.validate_pipeline!([{ "$project" => { "leak" => "$session_token" } }])
    end
  end

  # --- RT-7 / NEW-4: ACLScope join gate enforces the internal-collection floor ---

  def test_join_gate_refuses_internal_collections_unconditionally
    # _SCHEMA / _Hooks / _GlobalConfig etc. must be refused as a $lookup target
    # even if a CLP fetch would (wrongly) permit them — the hard floor runs
    # first, independent of rewrite_lookups having run.
    %w[_SCHEMA _Hooks _GlobalConfig _Audit].each do |coll|
      assert_raises(PS::Error, "#{coll} join must be refused by the floor") do
        Parse::ACLScope.send(:assert_join_target_permitted!, coll, ["*"])
      end
    end
  end

  def test_join_gate_admits_sdk_data_classes_through_floor
    # The four allowed underscore collections pass the floor; they then face
    # the per-scope CLP gate (which may still deny, but NOT via the floor).
    %w[_User _Role _Installation _Session].each do |coll|
      begin
        Parse::ACLScope.send(:assert_join_target_permitted!, coll, ["*"])
      rescue Parse::CLPScope::Denied
        # CLP may deny for this scope — acceptable; the floor did not refuse it.
      rescue PS::Error => e
        flunk "#{coll} must pass the internal-collection floor, got #{e.message}"
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
