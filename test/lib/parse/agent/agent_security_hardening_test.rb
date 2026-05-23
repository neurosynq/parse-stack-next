# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# ============================================================================
# Security hardening regression tests.
#
# H1 — where:-key oracle on internal Parse fields
#   ConstraintTranslator.translate must refuse any key that is in the
#   internal-fields denylist, regardless of which tool supplies the where:.
#
# H2 — group_by/distinct leak hidden-class identifiers via $group._id
#   walk_and_redact must scrub bare pointer-storage strings that don't live
#   under a _p_* key when the className is hidden.
#
# H3 — group_by/group_by_date/distinct skip agent_canonical_filter
#   run_aggregation_for_group_tool! must call apply_canonical_filter_to_pipeline.
#   explain_query and export_data path must also apply the canonical filter.
#
# M1 — INTERNAL_FIELDS_DENYLIST / DENIED_FIELD_REFS missing _auth_data_*
#   Any key whose lowercased form starts with _auth_data must be refused.
# ============================================================================
class AgentSecurityHardeningTest < Minitest::Test
  T = Parse::Agent::Tools
  CT = Parse::Agent::ConstraintTranslator
  PS = Parse::PipelineSecurity

  # ---- Fixtures ------------------------------------------------------------

  class SHSong < Parse::Object
    parse_class "SHSong"
    property :title,     :string
    property :archived, :boolean

    agent_canonical_filter "archived" => { "$ne" => true }
  end

  class SHArtist < Parse::Object
    parse_class "SHArtist"
    property :name, :string
  end

  class SHHiddenClass < Parse::Object
    parse_class "SHHiddenClass"
    property :secret, :string
    agent_hidden
  end

  class SHVisible < Parse::Object
    parse_class "SHVisible"
    property :label, :string
    belongs_to :hidden_ref, as: :pointer, class_name: "SHHiddenClass"
    agent_canonical_filter "archived" => { "$ne" => true }
  end

  # ---- Setup / teardown ----------------------------------------------------

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    Parse::Agent::Tools.reset_registry! if T.respond_to?(:reset_registry!)
    Parse::Agent.refuse_collscan = false
    @agent = Parse::Agent.new(permissions: :readonly)
    @agg_calls  = []
    @find_calls = []
  end

  def teardown
    Parse::Agent::Tools.reset_registry! if T.respond_to?(:reset_registry!)
    Parse::Agent.refuse_collscan = false
  end

  # Stub that raises if invoked — proves a gate fired BEFORE reaching the client.
  # Returns a [fake_client, invoked_flag] pair. invoked_flag[:called] turns
  # true if any method fires, letting the test assert it stayed false.
  def build_never_called_client
    invoked = { called: false }
    fake = Object.new
    fake.define_singleton_method(:find_objects) do |*_args, **_opts|
      invoked[:called] = true
      raise "SECURITY: find_objects must not be reached for this input"
    end
    fake.define_singleton_method(:aggregate_pipeline) do |*_args, **_opts|
      invoked[:called] = true
      raise "SECURITY: aggregate_pipeline must not be reached for this input"
    end
    [fake, invoked]
  end

  def stub_aggregate(results, calls: @agg_calls)
    fake = Object.new
    fake.define_singleton_method(:aggregate_pipeline) do |class_name, pipeline, **_opts|
      calls << [class_name, pipeline]
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results)  { results }
      r.define_singleton_method(:error)    { nil }
      r
    end
    @agent.define_singleton_method(:client) { fake }
  end

  def stub_find(results, calls: @find_calls)
    agg_calls = @agg_calls
    fake = Object.new
    fake.define_singleton_method(:find_objects) do |class_name, query, **_opts|
      calls << [class_name, query]
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:count)    { results.size }
      r.define_singleton_method(:results)  { results }
      r.define_singleton_method(:result)   { results.first }
      r.define_singleton_method(:error)    { nil }
      r
    end
    fake.define_singleton_method(:aggregate_pipeline) do |cn, pl, **_opts|
      agg_calls << [cn, pl]
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results)  { [] }
      r.define_singleton_method(:error)    { nil }
      r
    end
    @agent.define_singleton_method(:client) { fake }
  end

  # =========================================================================
  # H1 — ConstraintTranslator.translate blocks internal-field keys
  # =========================================================================

  # The oracle: translate must raise for each internal field key before
  # the query reaches the wire.  We test via translate() directly AND via
  # each tool that accepts a where:.

  INTERNAL_FIELD_KEYS = %w[
    _hashed_password
    _session_token
    _sessionToken
    _email_verify_token
    _perishable_token
    _password_history
    _auth_data_facebook
    _auth_data_google
    _auth_data_apple
  ].freeze

  def test_constraint_translator_refuses_hashed_password_key
    assert_raises(CT::ConstraintSecurityError) do
      CT.translate("_hashed_password" => { "$regex" => "^\\$2a" })
    end
  end

  def test_constraint_translator_refuses_session_token_key
    assert_raises(CT::ConstraintSecurityError) do
      CT.translate("_session_token" => { "$ne" => nil })
    end
  end

  def test_constraint_translator_refuses_perishable_token_key
    assert_raises(CT::ConstraintSecurityError) do
      CT.translate("_perishable_token" => { "$exists" => true })
    end
  end

  def test_constraint_translator_refuses_email_verify_token_key
    assert_raises(CT::ConstraintSecurityError) do
      CT.translate("_email_verify_token" => "abc123")
    end
  end

  def test_constraint_translator_refuses_auth_data_wildcard
    INTERNAL_FIELD_KEYS.select { |k| k.start_with?("_auth_data_") }.each do |key|
      assert_raises(CT::ConstraintSecurityError,
                    "translate should refuse key #{key.inspect}") do
        CT.translate(key => { "$exists" => true })
      end
    end
  end

  def test_constraint_translator_refuses_all_internal_keys
    INTERNAL_FIELD_KEYS.each do |key|
      assert_raises(CT::ConstraintSecurityError,
                    "translate should refuse key #{key.inspect}") do
        CT.translate(key => "value")
      end
    end
  end

  # Agent re-raises security errors rather than wrapping them in {success:false},
  # so the tool-boundary tests use assert_raises to prove the gate fired
  # BEFORE the client was reached.

  # count_objects must never reach the client when where: has an internal key
  def test_count_objects_refuses_hashed_password_in_where
    fake, invoked = build_never_called_client
    @agent.define_singleton_method(:client) { fake }
    assert_raises(CT::ConstraintSecurityError) do
      @agent.execute(:count_objects, class_name: "SHSong",
                     where: { "_hashed_password" => { "$regex" => "^X" } })
    end
    refute invoked[:called], "client.find_objects must never be invoked"
  end

  def test_count_objects_refuses_session_token_in_where
    fake, invoked = build_never_called_client
    @agent.define_singleton_method(:client) { fake }
    assert_raises(CT::ConstraintSecurityError) do
      @agent.execute(:count_objects, class_name: "SHSong",
                     where: { "_session_token" => { "$ne" => nil } })
    end
    refute invoked[:called]
  end

  def test_count_objects_refuses_auth_data_facebook_in_where
    fake, invoked = build_never_called_client
    @agent.define_singleton_method(:client) { fake }
    assert_raises(CT::ConstraintSecurityError) do
      @agent.execute(:count_objects, class_name: "SHSong",
                     where: { "_auth_data_facebook" => { "$exists" => true } })
    end
    refute invoked[:called]
  end

  # query_class must also refuse
  def test_query_class_refuses_hashed_password_in_where
    fake, invoked = build_never_called_client
    @agent.define_singleton_method(:client) { fake }
    assert_raises(CT::ConstraintSecurityError) do
      @agent.execute(:query_class, class_name: "SHSong",
                     where: { "_hashed_password" => { "$regex" => "^X" } })
    end
    refute invoked[:called]
  end

  # group_by where: also goes through translate — must refuse
  def test_group_by_refuses_hashed_password_in_where
    fake, invoked = build_never_called_client
    @agent.define_singleton_method(:client) { fake }
    assert_raises(CT::ConstraintSecurityError) do
      @agent.execute(:group_by, class_name: "SHSong", field: "title",
                     where: { "_hashed_password" => { "$regex" => "^X" } })
    end
    refute invoked[:called]
  end

  # aggregate pipeline with _hashed_password in $match must be refused by
  # PipelineSecurity (the aggregate path goes through PipelineValidator, not
  # ConstraintTranslator, so the error class is different).
  def test_aggregate_pipeline_refuses_hashed_password_match_key
    fake, invoked = build_never_called_client
    @agent.define_singleton_method(:client) { fake }
    assert_raises(Parse::PipelineSecurity::Error,
                  Parse::Agent::PipelineValidator::PipelineSecurityError) do
      @agent.execute(:aggregate, class_name: "SHSong",
                     pipeline: [
                       { "$match" => { "_hashed_password" => { "$regex" => "^X" } } },
                       { "$count" => "total" },
                     ])
    end
    refute invoked[:called], "aggregate_pipeline must never be invoked"
  end

  def test_aggregate_pipeline_refuses_session_token_match_key
    fake, invoked = build_never_called_client
    @agent.define_singleton_method(:client) { fake }
    assert_raises(Parse::PipelineSecurity::Error,
                  Parse::Agent::PipelineValidator::PipelineSecurityError) do
      @agent.execute(:aggregate, class_name: "SHSong",
                     pipeline: [{ "$match" => { "_session_token" => { "$ne" => nil } } },
                                { "$count" => "total" }])
    end
    refute invoked[:called]
  end

  def test_aggregate_pipeline_refuses_auth_data_match_key
    fake, invoked = build_never_called_client
    @agent.define_singleton_method(:client) { fake }
    assert_raises(Parse::PipelineSecurity::Error,
                  Parse::Agent::PipelineValidator::PipelineSecurityError) do
      @agent.execute(:aggregate, class_name: "SHSong",
                     pipeline: [{ "$match" => { "_auth_data_facebook" => { "$exists" => true } } },
                                { "$count" => "total" }])
    end
    refute invoked[:called]
  end

  # =========================================================================
  # H2 — group_by / distinct must not leak hidden-class ids in $group._id
  # =========================================================================

  # SHVisible has a belongs_to :hidden_ref -> SHHiddenClass (agent_hidden).
  # After a $group on _p_hidden_ref, rows come back as
  #   [{"_id" => "SHHiddenClass$abc123", "value" => 5}]
  # extract_pointer_class! surfaces pointer_class: "SHHiddenClass" in the
  # envelope, AND surfaces the raw objectId "abc123" as the key.
  # After the fix those values should be redacted.

  def test_group_by_hidden_pointer_field_redacts_class_name_and_objectids
    stub_aggregate([
      { "_id" => "SHHiddenClass$abc123", "value" => 5 },
      { "_id" => "SHHiddenClass$def456", "value" => 3 },
    ])
    result = @agent.execute(:group_by, class_name: "SHVisible", field: "hiddenRef")
    assert result[:success], result.inspect
    body = result[:data]
    # pointer_class must not expose a hidden class name
    refute_equal "SHHiddenClass", body[:pointer_class],
                 "pointer_class must not name a hidden class"
    # group keys must not contain raw objectIds from the hidden class.
    # Check for the specific objectId suffixes (after the $), not generic
    # alphanum which would false-positive on the redacted placeholder hash.
    result_json = body[:groups].to_json
    refute_match(/abc123/, result_json,
                 "objectId abc123 from hidden class must be redacted from group keys")
    refute_match(/def456/, result_json,
                 "objectId def456 from hidden class must be redacted from group keys")
  end

  def test_distinct_hidden_pointer_field_redacts_values
    stub_aggregate([
      { "_id" => "SHHiddenClass$abc123" },
      { "_id" => "SHHiddenClass$def456" },
    ])
    result = @agent.execute(:distinct, class_name: "SHVisible", field: "hiddenRef")
    assert result[:success], result.inspect
    body = result[:data]
    refute_equal "SHHiddenClass", body[:pointer_class],
                 "pointer_class must not expose a hidden class name"
    result_json = body[:values].to_json
    refute_match(/abc123/, result_json,
                 "objectId abc123 from hidden class must be redacted from distinct values")
    refute_match(/def456/, result_json,
                 "objectId def456 from hidden class must be redacted from distinct values")
  end

  # =========================================================================
  # H3 — group_by / group_by_date / distinct skip canonical filter
  # =========================================================================

  # SHSong declares agent_canonical_filter "archived" => { "$ne" => true }.
  # group_by / group_by_date / distinct must include this as a $match in the
  # pipeline submitted to aggregate_pipeline.

  def find_stage(pipeline, op)
    pipeline.find { |s| s.is_a?(Hash) && s.keys.first.to_s == op }
  end

  def test_group_by_applies_canonical_filter_as_match_stage
    stub_aggregate([{ "_id" => "rock", "value" => 3 }])
    @agent.execute(:group_by, class_name: "SHSong", field: "title")
    _, pipeline = @agg_calls.first
    match_stages = pipeline.select { |s| s.is_a?(Hash) && s.keys.first.to_s == "$match" }
    canonical_present = match_stages.any? do |s|
      m = s["$match"]
      m.is_a?(Hash) && m["archived"] == { "$ne" => true }
    end
    assert canonical_present,
           "group_by pipeline must contain a $match with canonical filter; got: #{pipeline.inspect}"
  end

  def test_group_by_date_applies_canonical_filter_as_match_stage
    stub_aggregate([{ "_id" => { "year" => 2024, "month" => 1 }, "value" => 2 }])
    @agent.execute(:group_by_date, class_name: "SHSong", field: "createdAt", interval: "month")
    _, pipeline = @agg_calls.first
    match_stages = pipeline.select { |s| s.is_a?(Hash) && s.keys.first.to_s == "$match" }
    canonical_present = match_stages.any? do |s|
      m = s["$match"]
      m.is_a?(Hash) && m["archived"] == { "$ne" => true }
    end
    assert canonical_present,
           "group_by_date pipeline must contain canonical filter $match; got: #{pipeline.inspect}"
  end

  def test_distinct_applies_canonical_filter_as_match_stage
    stub_aggregate([{ "_id" => "rock" }])
    @agent.execute(:distinct, class_name: "SHSong", field: "title")
    _, pipeline = @agg_calls.first
    match_stages = pipeline.select { |s| s.is_a?(Hash) && s.keys.first.to_s == "$match" }
    canonical_present = match_stages.any? do |s|
      m = s["$match"]
      m.is_a?(Hash) && m["archived"] == { "$ne" => true }
    end
    assert canonical_present,
           "distinct pipeline must contain canonical filter $match; got: #{pipeline.inspect}"
  end

  # explain_query should apply canonical filter so its result reflects what
  # query_class actually executes.
  def test_explain_query_applies_canonical_filter
    stub_find([], calls: @find_calls)
    @agent.execute(:explain_query, class_name: "SHSong")
    _, query = @find_calls.first
    # The where: must encode the canonical filter
    assert query[:where], "explain_query must include a where: when canonical filter is declared"
    where = JSON.parse(query[:where])
    assert where["archived"] == { "$ne" => true } ||
           (where["$and"] && where["$and"].any? { |c| c["archived"] == { "$ne" => true } }),
           "explain_query where: must include canonical filter; got: #{where.inspect}"
  end

  # export_data (query path) must apply canonical filter
  def test_export_via_query_applies_canonical_filter
    stub_find([], calls: @find_calls)
    @agent.execute(:export_data, class_name: "SHSong", format: "csv")
    _, query = @find_calls.first
    assert query[:where], "export_data must include a where: when canonical filter is declared"
    where = JSON.parse(query[:where])
    canonical = where["archived"] == { "$ne" => true } ||
                (where["$and"] && where["$and"].any? { |c| c["archived"] == { "$ne" => true } })
    assert canonical,
           "export_data (query path) must include canonical filter; got: #{where.inspect}"
  end

  # export_data (aggregate path) must apply canonical filter
  def test_export_via_aggregate_applies_canonical_filter
    stub_aggregate([])
    @agent.execute(:export_data, class_name: "SHSong", format: "csv",
                   pipeline: [{ "$group" => { "_id" => "$title" } }])
    _, pipeline = @agg_calls.first
    match_stages = pipeline.select { |s| s.is_a?(Hash) && s.keys.first.to_s == "$match" }
    canonical_present = match_stages.any? do |s|
      m = s["$match"]
      m.is_a?(Hash) && m["archived"] == { "$ne" => true }
    end
    assert canonical_present,
           "export_data (pipeline path) must contain canonical filter $match; got: #{pipeline.inspect}"
  end

  # get_sample_objects must apply canonical filter
  def test_get_sample_objects_applies_canonical_filter
    stub_find([])
    @agent.execute(:get_sample_objects, class_name: "SHSong")
    _, query = @find_calls.first
    assert query[:where], "get_sample_objects must include a where: when canonical filter is declared"
    where = JSON.parse(query[:where])
    canonical = where["archived"] == { "$ne" => true } ||
                (where["$and"] && where["$and"].any? { |c| c["archived"] == { "$ne" => true } })
    assert canonical,
           "get_sample_objects must include canonical filter in where:; got: #{where.inspect}"
  end

  # =========================================================================
  # M1 — INTERNAL_FIELDS_DENYLIST and DENIED_FIELD_REFS include _auth_data_*
  # =========================================================================

  def test_internal_fields_denylist_contains_auth_data_prefix
    has_auth_data = PS::INTERNAL_FIELDS_DENYLIST.any? { |f| f.start_with?("_auth_data") }
    assert has_auth_data,
           "INTERNAL_FIELDS_DENYLIST must contain an _auth_data entry; " \
           "got: #{PS::INTERNAL_FIELDS_DENYLIST.inspect}"
  end

  def test_denied_field_refs_contains_auth_data_prefix
    has_auth_data = PS::DENIED_FIELD_REFS.any? { |f| f.start_with?("$_auth_data") }
    assert has_auth_data,
           "DENIED_FIELD_REFS must contain a $_auth_data entry; " \
           "got: #{PS::DENIED_FIELD_REFS.inspect}"
  end

  def test_pipeline_security_validate_pipeline_refuses_auth_data_match_key
    assert_raises(PS::Error) do
      PS.validate_pipeline!([
        { "$match" => { "_auth_data_facebook" => { "$exists" => true } } },
        { "$count" => "total" },
      ])
    end
  end

  def test_pipeline_security_validate_pipeline_refuses_hashed_password_match_key
    assert_raises(PS::Error) do
      PS.validate_pipeline!([
        { "$match" => { "_hashed_password" => { "$regex" => "^X" } } },
        { "$count" => "total" },
      ])
    end
  end

  def test_strip_internal_fields_strips_auth_data_key
    doc = { "name" => "Alice", "_auth_data_facebook" => '{"id":"123"}', "score" => 5 }
    result = PS.strip_internal_fields(doc)
    refute result.key?("_auth_data_facebook"),
           "strip_internal_fields must remove _auth_data_* keys"
    assert_equal "Alice", result["name"]
    assert_equal 5,       result["score"]
  end

  # =========================================================================
  # C-2 — Pointer storage string leaks hidden className+objectId in aggregation
  #        results when the output key is NOT a `_p_*` column (re-projected
  #        or grouped under an arbitrary key name).
  # =========================================================================

  # $project { "leak" => "$_p_secret" } returns rows like
  # {"leak" => "HiddenClass$abc123"}. The key is "leak", not "_p_*", so the
  # old `_p_`-key guard missed it.
  def test_walk_and_redact_scrubs_pointer_storage_string_under_non_p_key
    hidden = Set.new(["SHHiddenClass"])
    rows = [
      { "leak" => "SHHiddenClass$abc123" },
      { "leak" => "SHHiddenClass$def456" },
    ]
    result = Parse::Agent::Tools.walk_and_redact(rows, hidden)
    result.each do |row|
      refute_match(/abc123|def456/, row.to_json,
                   "objectId from hidden class must be scrubbed when key is not _p_*")
      assert_kind_of Hash, row["leak"],
                    "value should be replaced with redacted placeholder hash"
      assert_equal "SHHiddenClass", row["leak"]["className"]
      assert row["leak"]["__redacted"]
    end
  end

  # $group { "_id" => "$_p_secret" } returns rows like
  # {"_id" => "HiddenClass$abc123", "n" => N}. The key is "_id", not "_p_*".
  def test_walk_and_redact_scrubs_pointer_storage_string_under_id_key
    hidden = Set.new(["SHHiddenClass"])
    rows = [
      { "_id" => "SHHiddenClass$abc123", "n" => 3 },
      { "_id" => "SHHiddenClass$def456", "n" => 1 },
    ]
    result = Parse::Agent::Tools.walk_and_redact(rows, hidden)
    result.each do |row|
      refute_match(/abc123|def456/, row.to_json,
                   "objectId from hidden class must be scrubbed in $group._id result")
      assert_kind_of Hash, row["_id"],
                    "_id should be replaced with redacted placeholder hash"
      assert_equal "SHHiddenClass", row["_id"]["className"]
    end
  end

  # Visible class pointer-storage strings must NOT be scrubbed.
  def test_walk_and_redact_passes_visible_class_pointer_string_through
    hidden = Set.new(["SHHiddenClass"])
    rows = [{ "item" => "SHArtist$xyz999" }]
    result = Parse::Agent::Tools.walk_and_redact(rows, hidden)
    assert_equal "SHArtist$xyz999", result.first["item"],
                 "pointer storage string for a visible class must not be touched"
  end

  # An actual aggregate call where the pipeline re-projects a _p_* column
  # under a new name — the agent's execute(:aggregate) must redact it.
  def test_aggregate_project_reproject_of_hidden_pointer_column_is_redacted
    stub_aggregate([
      { "leak" => "SHHiddenClass$abc123" },
      { "leak" => "SHHiddenClass$def456" },
    ])
    result = @agent.execute(:aggregate, class_name: "SHVisible",
                            pipeline: [{ "$project" => { "leak" => 1 } }])
    assert result[:success], result.inspect
    result[:data].each do |row|
      refute_match(/abc123|def456/, row.to_json,
                   "aggregate result must not expose hidden-class objectIds under re-projected key")
    end
  end

  def test_aggregate_group_id_with_hidden_pointer_value_is_redacted
    stub_aggregate([
      { "_id" => "SHHiddenClass$abc123", "count" => 5 },
    ])
    result = @agent.execute(:aggregate, class_name: "SHVisible",
                            pipeline: [{ "$group" => { "_id" => "$label", "count" => { "$sum" => 1 } } }])
    assert result[:success], result.inspect
    result[:data].each do |row|
      refute_match(/abc123/, row.to_json,
                   "aggregate result must not expose hidden-class objectIds in $group._id")
    end
  end

  # =========================================================================
  # H-1 — Internal-field denylist enforced on field-reference strings
  #        regardless of allowlist presence (no agent_fields declared).
  # =========================================================================

  # Classes WITHOUT agent_fields must still have internal fields blocked in
  # $project via field-reference strings like "$_hashed_password".
  def test_pipeline_security_refuses_hashed_password_field_ref_in_project
    assert_raises(PS::Error) do
      PS.validate_pipeline!([
        { "$project" => { "x" => "$_hashed_password" } },
      ])
    end
  end

  def test_pipeline_security_refuses_auth_data_field_ref_in_project
    assert_raises(PS::Error) do
      PS.validate_pipeline!([
        { "$project" => { "x" => "$_auth_data_facebook" } },
      ])
    end
  end

  def test_pipeline_security_refuses_hashed_password_field_ref_in_group_id
    assert_raises(PS::Error) do
      PS.validate_pipeline!([
        { "$group" => { "_id" => "$_hashed_password", "n" => { "$sum" => 1 } } },
      ])
    end
  end

  def test_pipeline_security_refuses_auth_data_field_ref_in_group_id
    assert_raises(PS::Error) do
      PS.validate_pipeline!([
        { "$group" => { "_id" => "$_auth_data_facebook", "n" => { "$sum" => 1 } } },
      ])
    end
  end

  def test_pipeline_security_refuses_hashed_password_field_ref_in_addfields
    assert_raises(PS::Error) do
      PS.validate_pipeline!([
        { "$addFields" => { "copy" => "$_hashed_password" } },
      ])
    end
  end

  def test_pipeline_security_refuses_hashed_password_field_ref_in_replace_root
    assert_raises(PS::Error) do
      PS.validate_pipeline!([
        { "$replaceRoot" => { "newRoot" => "$_hashed_password" } },
      ])
    end
  end

  def test_pipeline_security_refuses_session_token_field_ref_in_project
    assert_raises(PS::Error) do
      PS.validate_pipeline!([
        { "$project" => { "x" => "$_session_token" } },
      ])
    end
  end

  # Against allowlist-less classes (SHArtist has no agent_fields), the
  # aggregate tool must still refuse the pipeline via PipelineSecurity.
  def test_aggregate_on_no_allowlist_class_refuses_hashed_password_field_ref
    fake, invoked = build_never_called_client
    @agent.define_singleton_method(:client) { fake }
    assert_raises(Parse::PipelineSecurity::Error,
                  Parse::Agent::PipelineValidator::PipelineSecurityError) do
      @agent.execute(:aggregate, class_name: "SHArtist",
                     pipeline: [{ "$project" => { "x" => "$_hashed_password" } }])
    end
    refute invoked[:called]
  end

  def test_aggregate_on_no_allowlist_class_refuses_auth_data_field_ref
    fake, invoked = build_never_called_client
    @agent.define_singleton_method(:client) { fake }
    assert_raises(Parse::PipelineSecurity::Error,
                  Parse::Agent::PipelineValidator::PipelineSecurityError) do
      @agent.execute(:aggregate, class_name: "SHArtist",
                     pipeline: [{ "$group" => { "_id" => "$_auth_data_facebook" } }])
    end
    refute invoked[:called]
  end

  # =========================================================================
  # H-3 — agent_canonical_filter validated at registration time
  # =========================================================================

  # A canonical filter containing $where must be rejected at DSL registration
  # (class definition time), not silently accepted and smuggled past validation.
  def test_agent_canonical_filter_rejects_where_at_registration
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        agent_canonical_filter "$where" => "this.x > 0"
      end
    end
  end

  def test_agent_canonical_filter_rejects_function_at_registration
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        agent_canonical_filter "$function" => { "body" => "return true;", "args" => [], "lang" => "js" }
      end
    end
  end

  def test_agent_canonical_filter_rejects_accumulator_at_registration
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        agent_canonical_filter "$accumulator" => { "init" => "function(){}", "lang" => "js" }
      end
    end
  end

  # Internal field key in the canonical filter must also be rejected.
  def test_agent_canonical_filter_rejects_hashed_password_field_key
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        agent_canonical_filter "_hashed_password" => { "$ne" => nil }
      end
    end
  end

  def test_agent_canonical_filter_rejects_auth_data_field_key
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        agent_canonical_filter "_auth_data_facebook" => { "$exists" => true }
      end
    end
  end

  # Legitimate canonical filters must still be accepted.
  def test_agent_canonical_filter_accepts_valid_filter
    klass = nil
    refute_raises do
      klass = Class.new(Parse::Object) do
        agent_canonical_filter "archived" => { "$ne" => true }, "status" => "active"
      end
    end
    assert_equal({ "archived" => { "$ne" => true }, "status" => "active" },
                 klass.agent_canonical_filter_for_apply)
  end

  # =========================================================================
  # Medium 1 — apply_canonical_filter_to_where raises on non-Hash where
  # =========================================================================

  # When a canonical filter is declared and the caller supplies a non-Hash,
  # non-nil where value, silently dropping the canonical filter is a security
  # regression. The method must raise ArgumentError.
  def test_apply_canonical_filter_to_where_raises_on_non_hash_where
    # SHSong has agent_canonical_filter declared, so canonical will be present.
    assert_raises(ArgumentError) do
      Parse::Agent::Tools.apply_canonical_filter_to_where("some string", "SHSong")
    end
  end

  def test_apply_canonical_filter_to_where_raises_on_array_where
    assert_raises(ArgumentError) do
      Parse::Agent::Tools.apply_canonical_filter_to_where(["item"], "SHSong")
    end
  end

  # When no canonical filter is declared the method must still return
  # the where value unchanged (no raise).
  def test_apply_canonical_filter_to_where_passthrough_when_no_filter
    # SHArtist has no canonical filter.
    result = Parse::Agent::Tools.apply_canonical_filter_to_where("any value", "SHArtist")
    assert_equal "any value", result
  end

  # =========================================================================
  # Medium 2 — format_methods gates permitted_keys behind agent_debug
  # =========================================================================

  class SHMethodClass < Parse::Object
    parse_class "SHMethodClass"
    property :name, :string

    agent_method :update_name, "Update the name",
                 permitted_keys: [:name],
                 permission: :write
  end

  def test_format_methods_omits_permitted_keys_when_agent_debug_is_false
    Parse::Agent.agent_debug = false
    methods = SHMethodClass.agent_methods_for(:write)
    result = Parse::Agent::MetadataRegistry.send(:format_methods, methods)
    entry = result.find { |m| m[:name] == "update_name" }
    refute_nil entry
    refute entry.key?(:permitted_keys),
           "permitted_keys must be omitted from format_methods output when agent_debug is false"
  ensure
    Parse::Agent.agent_debug = false
  end

  def test_format_methods_includes_permitted_keys_when_agent_debug_is_true
    Parse::Agent.agent_debug = true
    methods = SHMethodClass.agent_methods_for(:write)
    result = Parse::Agent::MetadataRegistry.send(:format_methods, methods)
    entry = result.find { |m| m[:name] == "update_name" }
    refute_nil entry
    assert entry.key?(:permitted_keys),
           "permitted_keys must be present in format_methods output when agent_debug is true"
    assert_includes entry[:permitted_keys], "name"
  ensure
    Parse::Agent.agent_debug = false
  end
end
