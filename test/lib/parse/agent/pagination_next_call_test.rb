# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_dispatcher"

# ============================================================================
# Tests for the next_call: pagination hint in format_query_results.
#
# When has_more is true, ResultFormatter.format_query_results should include
# a top-level next_call: field whose value is the exact argument hash for the
# follow-up query_class invocation. When has_more is false, next_call: should
# be absent entirely (stripped by .compact).
#
# Also verifies that attempt_truncate_response strips next_call: because
# the truncate path emits its own resume signal via _truncated.next_skip.
# ============================================================================
class PaginationNextCallTest < Minitest::Test
  class PaginationStudent < Parse::Object
    parse_class "PaginationStudent"
    property :name, :string
    property :grade, :integer
  end

  # Build a minimal fake-client agent that returns a fixed set of rows.
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @agent = Parse::Agent.new(permissions: :readonly)
  end

  # -----------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------

  # Build a fake agent whose find_objects returns `rows`.
  def agent_with_rows(rows)
    agent = Parse::Agent.new(permissions: :readonly)
    fake_client = Object.new
    fake_client.define_singleton_method(:find_objects) do |_class, _query, **_opts|
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results)  { rows }
      r
    end
    agent.define_singleton_method(:client) { fake_client }
    agent
  end

  # Build exactly `n` rows whose objectIds are sequential.
  def make_rows(n)
    Array.new(n) { |i| { "objectId" => format("id_%04d", i), "name" => "Student#{i}", "grade" => 9 } }
  end

  # -----------------------------------------------------------------------
  # has_more: true — next_call: present
  # -----------------------------------------------------------------------

  def test_has_more_true_produces_next_call
    # limit:10 rows returned → has_more (10 >= 10) → next_call present
    rows  = make_rows(10)
    agent = agent_with_rows(rows)
    result = agent.execute(:query_class, class_name: "PaginationStudent", limit: 10)
    assert result[:success], result[:error].to_s
    data = result[:data]
    assert data[:pagination][:has_more], "has_more should be true when result count equals limit"
    assert data.key?(:next_call), "next_call: key must be present when has_more is true"
    nc = data[:next_call]
    assert_equal "query_class", nc[:tool]
  end

  def test_next_call_skip_incremented_by_limit
    rows  = make_rows(10)
    agent = agent_with_rows(rows)
    result = agent.execute(:query_class, class_name: "PaginationStudent", limit: 10, skip: 20)
    data = result[:data]
    assert data[:next_call], "next_call: must be present"
    assert_equal 30, data[:next_call][:arguments][:skip], "skip must be original_skip + limit"
  end

  def test_next_call_tool_is_literal_string
    rows  = make_rows(10)
    agent = agent_with_rows(rows)
    result = agent.execute(:query_class, class_name: "PaginationStudent", limit: 10)
    nc = result[:data][:next_call]
    assert_equal "query_class", nc[:tool]
    assert_instance_of String, nc[:tool]
  end

  def test_next_call_class_name_preserved
    rows  = make_rows(10)
    agent = agent_with_rows(rows)
    result = agent.execute(:query_class, class_name: "PaginationStudent", limit: 10)
    assert_equal "PaginationStudent", result[:data][:next_call][:arguments][:class_name]
  end

  def test_next_call_limit_preserved
    rows  = make_rows(10)
    agent = agent_with_rows(rows)
    result = agent.execute(:query_class, class_name: "PaginationStudent", limit: 10)
    assert_equal 10, result[:data][:next_call][:arguments][:limit]
  end

  # -----------------------------------------------------------------------
  # Optional caller args threaded through
  # -----------------------------------------------------------------------

  def test_next_call_preserves_where
    rows  = make_rows(10)
    agent = agent_with_rows(rows)
    where = { "grade" => 12 }
    result = agent.execute(:query_class, class_name: "PaginationStudent",
                           limit: 10, where: where)
    nc = result[:data][:next_call]
    assert nc, "next_call: must be present"
    assert_equal where, nc[:arguments][:where]
  end

  def test_next_call_preserves_order
    rows  = make_rows(10)
    agent = agent_with_rows(rows)
    result = agent.execute(:query_class, class_name: "PaginationStudent",
                           limit: 10, order: "-grade")
    nc = result[:data][:next_call]
    assert nc, "next_call: must be present"
    assert_equal "-grade", nc[:arguments][:order]
  end

  def test_next_call_preserves_keys
    rows  = make_rows(10)
    agent = agent_with_rows(rows)
    result = agent.execute(:query_class, class_name: "PaginationStudent",
                           limit: 10, keys: ["name", "grade"])
    nc = result[:data][:next_call]
    assert nc, "next_call: must be present"
    assert_equal ["name", "grade"], nc[:arguments][:keys]
  end

  def test_next_call_preserves_include
    rows  = make_rows(10)
    agent = agent_with_rows(rows)
    # PaginationStudent has no pointer fields declared so assert_include_paths_accessible!
    # short-circuits on `return unless klass.respond_to?(:references)`. Any
    # syntactically-valid include path passes through unchanged. We verify that
    # the caller-supplied value appears verbatim in next_call.arguments.
    include_val = ["someRelated"]
    result = agent.execute(:query_class, class_name: "PaginationStudent",
                           limit: 10, include: include_val)
    nc = result[:data][:next_call]
    assert nc, "next_call: must be present when has_more is true"
    assert nc[:arguments].key?(:include),
           "include must be present in next_call.arguments when supplied"
    assert_equal include_val, nc[:arguments][:include]
  end

  # -----------------------------------------------------------------------
  # .compact removes absent optional args from next_call.arguments
  # -----------------------------------------------------------------------

  def test_next_call_arguments_compact_omits_nil_optional_args
    rows  = make_rows(10)
    agent = agent_with_rows(rows)
    # No where, keys, order, include supplied — they should all be absent from
    # next_call.arguments (compacted away, not present as nil).
    result = agent.execute(:query_class, class_name: "PaginationStudent", limit: 10)
    args = result[:data][:next_call][:arguments]
    refute args.key?(:where),   "where: must be absent when not supplied"
    refute args.key?(:keys),    "keys: must be absent when not supplied"
    refute args.key?(:order),   "order: must be absent when not supplied"
    refute args.key?(:include), "include: must be absent when not supplied"
    # But required keys ARE present:
    assert args.key?(:class_name)
    assert args.key?(:limit)
    assert args.key?(:skip)
  end

  # -----------------------------------------------------------------------
  # has_more: false — next_call: absent
  # -----------------------------------------------------------------------

  def test_has_more_false_omits_next_call
    # 5 rows with limit:10 → has_more (5 < 10) is false → no next_call
    rows  = make_rows(5)
    agent = agent_with_rows(rows)
    result = agent.execute(:query_class, class_name: "PaginationStudent", limit: 10)
    data = result[:data]
    refute data[:pagination][:has_more], "has_more should be false when result count < limit"
    refute data.key?(:next_call), "next_call: must be absent when has_more is false"
  end

  def test_empty_results_omit_next_call
    agent = agent_with_rows([])
    result = agent.execute(:query_class, class_name: "PaginationStudent", limit: 10)
    data = result[:data]
    refute data.key?(:next_call), "next_call: must be absent for empty results"
  end

  # -----------------------------------------------------------------------
  # Original result envelope keys still present
  # -----------------------------------------------------------------------

  def test_result_envelope_keys_intact
    rows  = make_rows(10)
    agent = agent_with_rows(rows)
    result = agent.execute(:query_class, class_name: "PaginationStudent", limit: 10)
    data = result[:data]
    assert data.key?(:class_name),   "class_name must still be present"
    assert data.key?(:result_count), "result_count must still be present"
    assert data.key?(:pagination),   "pagination block must still be present"
    assert data.key?(:results),      "results array must still be present"
    assert_equal 10, data[:results].size
  end

  def test_truncated_note_present_when_results_exceed_display_cap
    # MAX_RESULTS_DISPLAY is 50. Return 60 rows (limit:100) so:
    #   - has_more is false (60 < 100) → no next_call
    #   - truncated is true → truncated_note present
    rows  = make_rows(60)
    agent = agent_with_rows(rows)
    result = agent.execute(:query_class, class_name: "PaginationStudent", limit: 100)
    data = result[:data]
    assert data[:truncated], "truncated should be true for 60 results with MAX_RESULTS_DISPLAY=50"
    assert data[:truncated_note]
    assert_equal 50, data[:results].size
    refute data.key?(:next_call), "has_more is false so next_call: must be absent"
  end

  def test_next_call_and_truncated_can_coexist
    # 100 rows with limit:100 → has_more true AND truncated (100 > 50).
    # Both next_call: and truncated:/truncated_note: should be present.
    rows  = make_rows(100)
    agent = agent_with_rows(rows)
    result = agent.execute(:query_class, class_name: "PaginationStudent", limit: 100)
    data = result[:data]
    assert data[:pagination][:has_more]
    assert data.key?(:next_call),       "next_call: present when has_more"
    assert data[:truncated],            "truncated: present when result count exceeds display cap"
    assert data[:truncated_note]
  end

  # -----------------------------------------------------------------------
  # Truncation path strips next_call: (MCPDispatcher.attempt_truncate_query_class)
  # -----------------------------------------------------------------------

  def test_attempt_truncate_strips_next_call
    # Build a data hash as format_query_results would produce it (with next_call:
    # present because has_more was true).
    rows = Array.new(20) do |i|
      { "objectId" => "id_#{i}", "a" => "x" * 5_000, "b" => "y" * 5_000 }
    end
    data = {
      class_name:   "PaginationStudent",
      result_count: 20,
      pagination:   { limit: 100, skip: 0, has_more: true },
      next_call:    { tool: "query_class", arguments: { class_name: "PaginationStudent", limit: 100, skip: 100 } },
      results:      rows,
    }
    d = Parse::Agent::MCPDispatcher
    text = d.send(:attempt_truncate_response, data, 50_000, "query_class")
    refute_nil text, "should have recovered a truncated response"
    payload = JSON.parse(text)
    refute payload.key?("next_call"),
           "next_call: must be stripped by attempt_truncate_response so _truncated is the sole pagination signal"
    # _truncated block should be present instead:
    assert payload.key?("_truncated")
  end

  def test_attempt_truncate_strips_stale_keys_plus_next_call
    # Regression: verify that result_count, truncated, truncated_note, AND
    # next_call: are all stripped in one pass (the existing test_strips_stale_*
    # in oversize_handling_test covers the first three; this covers next_call).
    rows = Array.new(20) do |i|
      { "objectId" => "id_#{i}", "a" => "x" * 5_000, "b" => "y" * 5_000 }
    end
    data = {
      result_count:   20,
      truncated:      true,
      truncated_note: "Showing first 50 of 20 results",
      next_call:      { tool: "query_class", arguments: { class_name: "PaginationStudent", limit: 100, skip: 100 } },
      pagination:     { limit: 100, skip: 0, has_more: true },
      results:        rows,
    }
    d = Parse::Agent::MCPDispatcher
    text = d.send(:attempt_truncate_response, data, 50_000, "query_class")
    refute_nil text
    payload = JSON.parse(text)
    refute payload.key?("result_count")
    refute payload.key?("truncated")
    refute payload.key?("truncated_note")
    refute payload.key?("next_call")
  end
end
