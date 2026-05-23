# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_dispatcher"

# ============================================================================
# Unit-level tests for the three oversize-handling features:
#
#   A) MCPDispatcher.diagnose_oversize — per-field byte sampling + positive
#      keys: recommendation appended to the refusal message.
#   B) agent_large_fields DSL — schema annotation so the LLM learns which
#      fields are heavy BEFORE its first query.
#   C) MCPDispatcher.attempt_truncate_response — partial-success recovery
#      that drops the heaviest field (and trailing rows if needed) and
#      annotates the response with a _truncated block.
# ============================================================================

# ----------------------------------------------------------------------------
# A) diagnose_oversize unit cases
# ----------------------------------------------------------------------------
class DiagnoseOversizeTest < Minitest::Test
  D = Parse::Agent::MCPDispatcher

  def diagnose(data)
    D.send(:diagnose_oversize, data)
  end

  def test_nil_for_non_hash
    assert_nil diagnose("not a hash")
    assert_nil diagnose(nil)
    assert_nil diagnose([])
  end

  def test_nil_for_export_data_shape
    # The dispatcher intentionally skips export_data: without per-column
    # byte sampling the column list would be misleading.
    out = diagnose(output: "csv,blob\n...", headers: ["title", "year"])
    assert_nil out
  end

  def test_returns_positive_keys_list_with_top_ranked_fields
    rows = Array.new(3) do |i|
      {
        "objectId" => "id_#{i}",
        "title"    => "Book #{i}",
        "body"     => "x" * 10_000,
      }
    end
    msg = diagnose(results: rows)
    refute_nil msg
    assert_match(/Largest fields by bytes/, msg)
    assert_match(/body/, msg)
    m = msg.match(/Try keys: "([^"]+)"/)
    assert m, "expected positive-keys list in #{msg.inspect}"
    suggested = m[1].split(",")
    refute_includes suggested, "body"
    assert_includes suggested, "title"
    assert_includes suggested, "objectId"  # always-keep
    assert_match(/drops the heaviest field/, msg)
  end

  def test_handles_objects_hash_shape_from_get_objects
    out = diagnose(objects: {
      "a" => { "objectId" => "a", "title" => "t", "body" => "x" * 5_000 },
      "b" => { "objectId" => "b", "title" => "t", "body" => "y" * 5_000 },
    })
    refute_nil out
    assert_match(/body/, out)
  end

  def test_handles_single_object_shape_from_get_object
    out = diagnose(object: { "objectId" => "a", "title" => "t", "body" => "x" * 5_000 })
    refute_nil out
    assert_match(/body/, out)
  end

  def test_always_keep_fields_appended_even_when_absent_from_row
    # If a row legitimately doesn't have objectId/createdAt, the positive
    # keys list still includes them so the suggested projection is
    # forwards-compatible.
    rows = [{ "title" => "T", "body" => "x" * 5_000 }]
    msg = diagnose(results: rows)
    m = msg.match(/Try keys: "([^"]+)"/)
    suggested = m[1].split(",")
    assert_includes suggested, "objectId"
    assert_includes suggested, "createdAt"
    assert_includes suggested, "updatedAt"
  end

  def test_no_crash_on_pointer_cycle
    # A self-referential hash would normally explode to_json with
    # SystemStackError. The sampler must skip that field and continue,
    # not abort the whole diagnostic.
    cyclic = { "objectId" => "x", "title" => "T" }
    cyclic["self"] = cyclic
    cyclic["body"] = "x" * 5_000

    msg = nil
    assert_silent { msg = diagnose(results: [cyclic]) }
    refute_nil msg
    # We should still surface title and body in the analysis even though
    # `self` was skipped.
    assert_match(/Largest fields by bytes/, msg)
    m = msg.match(/Try keys: "([^"]+)"/)
    suggested = m[1].split(",")
    refute_includes suggested, "body"  # body was the heaviest serializable field
  end

  def test_returns_nil_for_empty_rows
    assert_nil diagnose(results: [])
  end

  def test_skips_non_hash_rows
    out = diagnose(results: ["not-a-hash", 42, nil])
    assert_nil out
  end
end

# ----------------------------------------------------------------------------
# B) agent_large_fields DSL — declaration + schema enrichment
# ----------------------------------------------------------------------------
class AgentLargeFieldsDslTest < Minitest::Test
  class FlaggedArticle < Parse::Object
    parse_class "FlaggedArticle"
    property :title, :string
    property :body, :string
    property :raw_html, :string
    property :author, :pointer, class_name: "_User"
    agent_large_fields :body, :raw_html
  end

  class UnflaggedArticle < Parse::Object
    parse_class "UnflaggedArticle"
    property :title, :string
    property :body, :string
  end

  def test_dsl_records_field_list
    assert_equal [:body, :raw_html], FlaggedArticle.agent_large_field_list
  end

  def test_dsl_returns_empty_list_when_not_declared
    assert_equal [], UnflaggedArticle.agent_large_field_list
  end

  def test_dsl_called_without_args_returns_current_list
    assert_equal [:body, :raw_html], FlaggedArticle.agent_large_fields
  end

  def test_enrich_fields_injects_large_field_true
    fields = {
      "title"    => { "type" => "String" },
      "body"     => { "type" => "String" },
      "raw_html" => { "type" => "String" },
    }
    enriched = Parse::Agent::MetadataRegistry.send(:enrich_fields, fields, FlaggedArticle)
    refute enriched["title"]["large_field"], "title was not declared large"
    assert_equal true, enriched["body"]["large_field"]
    assert_equal true, enriched["raw_html"]["large_field"]
  end

  def test_enrich_fields_skips_pointer_types_even_when_declared
    # Pointer/Relation are never flagged: the stored value is a small
    # reference, and only `include:` resolution materializes the payload —
    # a query-time concern, not a schema-time hint. Stub the metadata
    # surface enrich_fields reads so we don't need a real Parse::Object
    # subclass for this assertion.
    stub_klass = Class.new do
      def self.agent_large_field_list; [:author, :tags]; end
      def self.property_descriptions;  {}; end
    end

    fields = {
      "author" => { "type" => "Pointer", "targetClass" => "_User" },
      "tags"   => { "type" => "Relation", "targetClass" => "_User" },
    }
    enriched = Parse::Agent::MetadataRegistry.send(:enrich_fields, fields, stub_klass)
    refute enriched["author"]["large_field"]
    refute enriched["tags"]["large_field"]
  end

  def test_enriched_field_surfaces_in_format_fields_detailed
    fields = {
      "body" => { "type" => "String" },
    }
    enriched = Parse::Agent::MetadataRegistry.send(:enrich_fields, fields, FlaggedArticle)
    rendered = Parse::Agent::ResultFormatter.send(:format_fields_detailed, enriched)
    body = rendered.find { |f| f[:name] == "body" }
    assert body
    assert_equal true, body[:large_field]
  end

  def test_unflagged_field_does_not_appear_in_format_output
    fields = {
      "title" => { "type" => "String" },
    }
    enriched = Parse::Agent::MetadataRegistry.send(:enrich_fields, fields, UnflaggedArticle)
    rendered = Parse::Agent::ResultFormatter.send(:format_fields_detailed, enriched)
    title = rendered.find { |f| f[:name] == "title" }
    refute title.key?(:large_field), "non-declared field should not carry large_field key"
  end
end

# ----------------------------------------------------------------------------
# C) attempt_truncate_response — partial-success recovery (query_class path)
# ----------------------------------------------------------------------------
class TruncateAndAnnotateTest < Minitest::Test
  D = Parse::Agent::MCPDispatcher

  def truncate(data, max_bytes)
    D.send(:attempt_truncate_response, data, max_bytes, "query_class")
  end

  def test_returns_nil_for_non_hash
    assert_nil truncate(nil, 1_000)
    assert_nil truncate([], 1_000)
  end

  def test_returns_nil_for_empty_results
    assert_nil truncate({ results: [] }, 1_000)
  end

  def test_heaviest_field_drop_suffices_no_next_skip
    # 5 rows with one wide field; dropping that field puts everything
    # easily under a generous cap.
    rows = Array.new(5) do |i|
      { "objectId" => "id_#{i}", "title" => "T#{i}", "body" => "x" * 20_000 }
    end
    text = truncate({ results: rows }, 50_000)
    refute_nil text

    payload = JSON.parse(text)
    assert_equal 5, payload["results"].size
    trunc = payload["_truncated"]
    assert_equal "response_exceeded_max_bytes", trunc["reason"]
    assert_includes trunc["dropped_fields"], "body"
    assert_equal 5, trunc["kept_count"]
    assert_equal 5, trunc["original_count"]
    refute trunc.key?("next_skip"),
           "with heaviest-field drop alone fitting, next_skip should be absent"
    assert_match(/get_object/, trunc["hint"])
  end

  def test_falls_back_to_row_trim_when_heaviest_drop_insufficient
    # 20 rows × ~10 KB metadata each. Even dropping the heaviest single
    # field, the response would be ~200 KB. Set a tight cap so the
    # algorithm must also drop rows.
    rows = Array.new(20) do |i|
      { "objectId" => "id_#{i}", "a" => "x" * 5_000, "b" => "y" * 5_000 }
    end
    text = truncate({ results: rows }, 50_000)
    refute_nil text

    payload = JSON.parse(text)
    trunc   = payload["_truncated"]
    assert_includes trunc["dropped_fields"], "a" # or "b" — depends on tie-break
    assert_operator payload["results"].size, :<, 20, "must have dropped trailing rows"
    assert trunc.key?("next_skip"), "next_skip required when rows are trimmed"
    assert_equal payload["results"].size, trunc["next_skip"]
    assert_match(/query_class\(skip: #{trunc["next_skip"]}\)/, trunc["hint"])
    assert text.bytesize <= 50_000
  end

  def test_returns_nil_when_even_one_row_cannot_fit
    # Single row that's far too large to fit under the cap even after
    # dropping the heaviest field.
    rows = [{ "objectId" => "x", "a" => "x" * 10_000, "b" => "y" * 10_000 }]
    assert_nil truncate({ results: rows }, 100)
  end

  def test_preserves_other_data_envelope_keys
    rows = [{ "objectId" => "a", "title" => "T", "body" => "x" * 20_000 }]
    data = {
      class_name:   "Article",
      result_count: 1,
      pagination:   { limit: 100, skip: 0 },
      results:      rows,
    }
    text = truncate(data, 50_000)
    refute_nil text
    payload = JSON.parse(text)
    assert_equal "Article", payload["class_name"]
    assert_equal({ "limit" => 100, "skip" => 0 }, payload["pagination"])
  end

  def test_does_not_mutate_caller_data
    rows = [{ "objectId" => "a", "title" => "T", "body" => "x" * 20_000 }]
    data = { results: rows }
    truncate(data, 50_000)
    # Original hash should still contain body; we copy, not mutate.
    assert_equal "x" * 20_000, data[:results].first["body"]
    refute data.key?(:_truncated)
  end

  def test_strips_stale_cardinality_keys_so_truncated_block_is_authoritative
    # ResultFormatter writes result_count, truncated, truncated_note based
    # on the FULL row set. After we trim rows or drop fields those values
    # are no longer accurate — the recovered envelope must remove them so
    # the LLM cannot mistake them for the post-truncation cardinality.
    rows = Array.new(20) do |i|
      { "objectId" => "id_#{i}", "a" => "x" * 5_000, "b" => "y" * 5_000 }
    end
    data = {
      class_name:     "Article",
      result_count:   20,
      truncated:      true,
      truncated_note: "Showing first 50 of N results",
      pagination:     { limit: 100, skip: 0, has_more: false },
      results:        rows,
    }
    text = truncate(data, 50_000)
    refute_nil text
    payload = JSON.parse(text)
    refute payload.key?("result_count"), "stale result_count must not survive truncation"
    refute payload.key?("truncated"),    "ResultFormatter `truncated` flag must be stripped"
    refute payload.key?("truncated_note"), "ResultFormatter `truncated_note` must be stripped"
    # _truncated is the sole authoritative cardinality signal:
    assert payload["_truncated"]["kept_count"]
    assert payload["_truncated"]["original_count"]
  end

  def test_next_skip_resumes_pagination_relative_to_original_skip
    # Caller paginated to skip:100 already. When we trim and emit a partial
    # page of 7 rows, next_skip must be 107, NOT 7 — otherwise the next
    # query_class call restarts from page 0 and the dataset never advances.
    rows = Array.new(20) do |i|
      { "objectId" => "id_#{i}", "a" => "x" * 5_000, "b" => "y" * 5_000 }
    end
    data = {
      pagination: { limit: 100, skip: 100, has_more: true },
      results:    rows,
    }
    text = truncate(data, 50_000)
    refute_nil text
    payload  = JSON.parse(text)
    trunc    = payload["_truncated"]
    fit      = trunc["kept_count"]
    expected = 100 + fit
    assert_equal expected, trunc["next_skip"],
                 "next_skip must add to original skip, not reset it"
    assert_match(/query_class\(skip: #{expected}\)/, trunc["hint"])
  end

  def test_next_skip_defaults_to_fit_count_when_no_prior_skip
    # No pagination block at all — original_skip defaults to 0, so
    # next_skip equals fit_count. (Same as the existing fallback test,
    # but documents that the absence of `:pagination` is handled.)
    rows = Array.new(20) do |i|
      { "objectId" => "id_#{i}", "a" => "x" * 5_000, "b" => "y" * 5_000 }
    end
    text = truncate({ results: rows }, 50_000)
    refute_nil text
    trunc = JSON.parse(text)["_truncated"]
    assert_equal trunc["kept_count"], trunc["next_skip"]
  end
end

# ----------------------------------------------------------------------------
# D) attempt_truncate_response — get_objects (hash-of-records) path
# ----------------------------------------------------------------------------
class TruncateGetObjectsTest < Minitest::Test
  D = Parse::Agent::MCPDispatcher

  def truncate(data, max_bytes)
    D.send(:attempt_truncate_response, data, max_bytes, "get_objects")
  end

  def make_objects(count, body_field_size: 20_000)
    count.times.each_with_object({}) do |i, h|
      id = "obj#{i.to_s.rjust(6, '0')}"
      h[id] = { "objectId" => id, "title" => "Record #{i}", "body" => "x" * body_field_size }
    end
  end

  # ---------- nil / empty guards -------------------------------------------

  def test_returns_nil_for_non_hash
    assert_nil truncate(nil, 1_000)
    assert_nil truncate([], 1_000)
  end

  def test_returns_nil_for_empty_objects_hash
    data = {
      class_name: "Article",
      objects:    {},
      missing:    [],
      requested:  0,
      found:      0,
    }
    assert_nil truncate(data, 1_000)
  end

  # ---------- heaviest-field drop suffices (all records kept) ---------------

  def test_heaviest_field_dropped_all_records_kept
    # 5 records × 20 KB body = ~100 KB; dropping body leaves ~1 KB → fits
    # under a generous cap.
    objects = make_objects(5, body_field_size: 20_000)
    data = {
      class_name: "Article",
      objects:    objects,
      missing:    [],
      requested:  5,
      found:      5,
    }
    text = truncate(data, 50_000)
    refute_nil text

    payload = JSON.parse(text)
    trunc   = payload["_truncated"]
    assert_equal "response_exceeded_max_bytes", trunc["reason"]
    assert_includes trunc["dropped_fields"], "body"
    assert_equal 5, trunc["kept_count"]
    assert_equal 5, trunc["original_count"]
    assert_equal [],  trunc["dropped_for_size"]
    assert_match(/get_object/, trunc["hint"])

    # Records should all be present, but without `body`
    assert_equal 5, payload["objects"].size
    payload["objects"].each_value do |rec|
      refute rec.key?("body"),  "body must be dropped from all records"
      assert rec.key?("title"), "title must be preserved"
    end

    # next_skip must NOT appear — get_objects has no pagination concept
    refute trunc.key?("next_skip"), "get_objects recovery must not include next_skip"
  end

  # ---------- tighter cap — some records moved to dropped_for_size ----------

  def test_tighter_cap_moves_records_to_dropped_for_size
    # 10 records × 5 KB apiece after body dropped. A very tight cap forces
    # only a few records to fit.
    objects = make_objects(10, body_field_size: 5_000)
    data = {
      class_name: "Article",
      objects:    objects,
      missing:    [],
      requested:  10,
      found:      10,
    }
    # After dropping body, each trimmed record is ~64 bytes. The 10-record
    # envelope is ~1157 bytes; cap at 850 so only a few records fit.
    text = truncate(data, 850)
    refute_nil text

    payload      = JSON.parse(text)
    trunc        = payload["_truncated"]
    kept         = payload["objects"].size
    dropped_ids  = trunc["dropped_for_size"]

    assert_operator kept, :<, 10, "fewer than 10 records must fit under the tight cap"
    assert_equal kept, trunc["kept_count"]
    assert_equal 10,   trunc["original_count"]
    refute_nil dropped_ids
    assert_operator dropped_ids.size, :>, 0, "at least one record must be in dropped_for_size"
    assert_equal 10, kept + dropped_ids.size, "kept + dropped_for_size must equal original_count"

    # All remaining IDs must only come from the original objects hash
    original_ids = objects.keys
    payload["objects"].each_key { |k| assert_includes original_ids, k }
    dropped_ids.each             { |k| assert_includes original_ids, k }

    # next_skip must not appear
    refute trunc.key?("next_skip")

    assert text.bytesize <= 850, "recovered text must fit within the cap"
  end

  # ---------- missing: array is left untouched ------------------------------

  def test_missing_array_preserved_unchanged
    objects = make_objects(3, body_field_size: 20_000)
    data = {
      class_name: "Article",
      objects:    objects,
      missing:    ["absent_id_1", "absent_id_2"],
      requested:  5,
      found:      3,
    }
    text = truncate(data, 50_000)
    refute_nil text
    payload = JSON.parse(text)
    assert_equal ["absent_id_1", "absent_id_2"], payload["missing"],
                 "missing: must reflect server-side absence, not size-based drops"
  end

  # ---------- no mutation of caller data ------------------------------------

  def test_does_not_mutate_caller_data
    objects = make_objects(3, body_field_size: 20_000)
    data = {
      class_name: "Article",
      objects:    objects,
      missing:    [],
      requested:  3,
      found:      3,
    }
    truncate(data, 50_000)
    data[:objects].each_value do |rec|
      assert rec.key?("body"), "original records must still carry body"
    end
    refute data.key?(:_truncated)
  end

  # ---------- returns nil when even one record cannot fit -------------------

  def test_returns_nil_when_one_record_cannot_fit
    # One record with TWO fields each larger than the entire cap.
    cap = 200
    objects = { "x" => { "objectId" => "x", "a" => "x" * (cap + 100), "b" => "y" * (cap + 100) } }
    data = { class_name: "Article", objects: objects, missing: [], requested: 1, found: 1 }
    assert_nil truncate(data, cap)
  end
end

# ----------------------------------------------------------------------------
# E) attempt_truncate_response — aggregate (row-array) path
# ----------------------------------------------------------------------------
class TruncateAggregateTest < Minitest::Test
  D = Parse::Agent::MCPDispatcher

  def truncate(data, max_bytes)
    D.send(:attempt_truncate_response, data, max_bytes, "aggregate")
  end

  def make_agg_data(row_count, body_size: 20_000, auto_limited: false)
    results = Array.new(row_count) do |i|
      { "objectId" => "id_#{i}", "title" => "Row #{i}", "body" => "x" * body_size }
    end
    data = {
      class_name:     "Article",
      pipeline_stages: 1,
      result_count:   row_count,
      results:        results,
    }
    if auto_limited
      data[:auto_limited] = true
      data[:auto_limit]   = 200
      data[:hint]         = "Pipeline auto-bounded with $limit:200 ..."
    end
    data
  end

  # ---------- nil / empty guards -------------------------------------------

  def test_returns_nil_for_non_hash
    assert_nil truncate(nil, 1_000)
    assert_nil truncate([], 1_000)
  end

  def test_returns_nil_for_empty_results
    assert_nil truncate({ results: [], class_name: "Article" }, 1_000)
  end

  # ---------- heaviest-field drop suffices (all rows kept) ------------------

  def test_heaviest_field_dropped_all_rows_kept
    data = make_agg_data(5, body_size: 20_000)
    text = truncate(data, 50_000)
    refute_nil text

    payload = JSON.parse(text)
    trunc   = payload["_truncated"]
    assert_equal "response_exceeded_max_bytes", trunc["reason"]
    assert_includes trunc["dropped_fields"], "body"
    assert_equal 5, trunc["kept_count"]
    assert_equal 5, trunc["original_count"]
    assert_match(/\$match|\$project/, trunc["hint"],
                 "hint should mention narrowing with pipeline stages")

    # All 5 rows kept, body removed
    assert_equal 5, payload["results"].size
    payload["results"].each do |row|
      refute row.key?("body")
      assert row.key?("title")
    end

    # next_skip must NOT appear — pipelines are not paginatable
    refute trunc.key?("next_skip"), "aggregate recovery must not include next_skip"
  end

  # ---------- tighter cap — trailing rows trimmed ---------------------------

  def test_tighter_cap_trims_trailing_rows
    # 20 rows × 5 KB each; tight cap forces only a few to fit.
    data = make_agg_data(20, body_size: 5_000)
    text = truncate(data, 850)
    refute_nil text

    payload = JSON.parse(text)
    trunc   = payload["_truncated"]
    assert_operator payload["results"].size, :<, 20
    assert_equal payload["results"].size, trunc["kept_count"]
    assert_equal 20, trunc["original_count"]
    assert_match(/\$match|\$project/, trunc["hint"])
    refute trunc.key?("next_skip"), "aggregate recovery must not include next_skip"
    assert text.bytesize <= 850
  end

  # ---------- hint mentions $match/$project, NOT query_class(skip:) --------

  def test_hint_mentions_pipeline_narrowing_not_query_class
    data = make_agg_data(20, body_size: 5_000)
    text = truncate(data, 850)
    refute_nil text
    trunc = JSON.parse(text)["_truncated"]
    refute_match(/query_class\(skip:/, trunc["hint"],
                 "aggregate hint must not suggest query_class pagination")
    assert_match(/\$match|\$project/, trunc["hint"])
  end

  # ---------- next_skip absent even when rows are trimmed -------------------

  def test_next_skip_absent_when_rows_trimmed
    data = make_agg_data(20, body_size: 5_000)
    text = truncate(data, 850)
    refute_nil text
    trunc = JSON.parse(text)["_truncated"]
    refute trunc.key?("next_skip"),
           "next_skip must never appear in aggregate _truncated blocks"
  end

  # ---------- auto_limited: true survives in recovered envelope -------------

  def test_auto_limited_flag_survives_recovery
    # When the pipeline was auto-bounded (no explicit $limit), the
    # auto_limited / auto_limit keys must still be present in the recovered
    # envelope so the LLM knows the result set was already capped upstream.
    # The top-level :hint (auto-limit message) is stripped — _truncated.hint
    # is the sole guidance. auto_limited / auto_limit themselves are kept.
    data = make_agg_data(5, body_size: 20_000, auto_limited: true)
    text = truncate(data, 50_000)
    refute_nil text

    payload = JSON.parse(text)
    assert_equal true, payload["auto_limited"],
                 "auto_limited flag must survive in the recovered envelope"
    assert_equal 200, payload["auto_limit"],
                 "auto_limit value must survive in the recovered envelope"
    refute payload.key?("hint"),
           "top-level :hint (auto-limit message) must be stripped when _truncated is present"
    assert payload["_truncated"],
           "_truncated annotation must be present"
    assert_match(/\$match|\$project/, payload["_truncated"]["hint"])
  end

  # ---------- returns nil when even one row cannot fit ----------------------

  def test_returns_nil_when_one_row_cannot_fit
    cap = 200
    results = [{ "objectId" => "x", "a" => "x" * (cap + 100), "b" => "y" * (cap + 100) }]
    data = { class_name: "Article", pipeline_stages: 1, result_count: 1, results: results }
    assert_nil truncate(data, cap)
  end

  # ---------- does not mutate caller data -----------------------------------

  def test_does_not_mutate_caller_data
    data = make_agg_data(3, body_size: 20_000)
    truncate(data, 50_000)
    assert data[:results].first.key?("body"), "original rows must still carry body"
    refute data.key?(:_truncated)
  end
end
