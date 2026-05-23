# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_dispatcher"

# ============================================================================
# Large-record harness.
#
# Simulates a Parse class with relatively few rows (50) where each row carries
# a very wide field (~100 KB `full_text`). The aggregate response size is the
# dominant guardrail here, not row count.
#
# Three guardrails demonstrated:
#   - MCPDispatcher MAX_TOOL_RESPONSE_BYTES (4 MiB) refusing the oversized
#     payload that would otherwise stream into the LLM's context window.
#   - `keys:` projection cutting the body size by ~99.95 % while keeping the
#     same call.
#   - `agent_fields` allowlist on the model — schema-level defense that
#     intersects caller-supplied `keys:` with the permitted field set so a
#     curious caller can't re-request the wide column.
# ============================================================================
class ToolsLargeRecordsTest < Minitest::Test
  # 50 books × 100 KB full_text = ~5 MB raw, ~6 MB after JSON encoding —
  # comfortably over the 4 MiB dispatcher cap so the refusal path fires.
  TOTAL    = 50
  TEXT_LEN = 100_000  # bytes per book

  # Class with no field allowlist — caller-controlled projection only.
  class WideBook < Parse::Object
    parse_class "WideBook"
    property :title, :string
    property :year, :integer
    property :description, :string
    property :full_text, :string
  end

  # Class with a strict agent_fields allowlist — caller cannot pull
  # `full_text` regardless of what they pass to `keys:`.
  class GuardedBook < Parse::Object
    parse_class "GuardedBook"
    property :title, :string
    property :year, :integer
    property :description, :string
    property :full_text, :string
    agent_fields :title, :year, :description
  end

  NEEDLE_ID    = "needle_book"
  NEEDLE_TITLE = "The Singularly Findable Volume"

  def self.rows
    @rows ||= begin
      rng = Random.new(1701)
      rows = Array.new(TOTAL) do |i|
        {
          "objectId"    => format("book_%03d", i),
          "title"       => "Book #{i}",
          "year"        => 1900 + rng.rand(125),
          "description" => "Short description for book #{i}.",
          "full_text"   => "x" * TEXT_LEN,
        }
      end
      rows[17] = {
        "objectId"    => NEEDLE_ID,
        "title"       => NEEDLE_TITLE,
        "year"        => 2024,
        "description" => "The one we want.",
        "full_text"   => "y" * TEXT_LEN,
      }
      rows
    end
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @agent = Parse::Agent.new(permissions: :readonly)
    rows = self.class.rows
    fake_client = Object.new

    fake_client.define_singleton_method(:find_objects) do |_class, query, **_opts|
      filtered = ToolsLargeRecordsTest.apply_where(rows, query[:where])

      if query[:count].to_i == 1 && query[:limit].to_i == 0
        r = Object.new
        r.define_singleton_method(:success?) { true }
        r.define_singleton_method(:count)    { filtered.size }
        r.define_singleton_method(:results)  { [] }
        next r
      end

      page = filtered.first((query[:limit] || filtered.size).to_i)
      page = ToolsLargeRecordsTest.project(page, query[:keys])
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results)  { page }
      r.define_singleton_method(:count)    { page.size }
      r
    end

    fake_client.define_singleton_method(:fetch_object) do |_class, object_id, **opts|
      found = rows.find { |row| row["objectId"] == object_id }
      query = opts[:query] || {}
      keys = query[:keys] || query["keys"]
      r = Object.new
      if found
        projected = ToolsLargeRecordsTest.project([found], keys).first
        r.define_singleton_method(:success?)         { true }
        r.define_singleton_method(:object_not_found?) { false }
        r.define_singleton_method(:result)            { projected }
      else
        r.define_singleton_method(:success?)         { false }
        r.define_singleton_method(:object_not_found?) { true }
        r.define_singleton_method(:error)             { "Not found" }
        r.define_singleton_method(:result)            { nil }
      end
      r
    end

    @agent.define_singleton_method(:client) { fake_client }
  end

  # ---- helpers ----------------------------------------------------------

  def self.apply_where(rows, where_json)
    return rows if where_json.nil? || where_json.empty?
    conds = where_json.is_a?(String) ? JSON.parse(where_json) : where_json
    rows.select do |row|
      conds.all? do |field, expected|
        if expected.is_a?(Hash) && expected.key?("$eq")
          row[field] == expected["$eq"]
        else
          row[field] == expected
        end
      end
    end
  end

  # `keys` arrives from the tool layer as a comma-joined string. Always
  # preserve objectId / createdAt / updatedAt so downstream formatters
  # don't choke on a missing identifier.
  ALWAYS_KEEP = %w[objectId createdAt updatedAt].freeze

  def self.project(rows, keys_csv)
    return rows if keys_csv.nil? || keys_csv.empty?
    requested = keys_csv.to_s.split(",").map(&:strip)
    keep = (requested | ALWAYS_KEEP)
    rows.map { |row| row.slice(*keep) }
  end

  # ---- 1. query_class auto-recovers via truncate-and-annotate -----------

  def test_query_class_recovers_oversize_via_truncate_annotate
    # 50 books × 100 KB = ~5 MB; over the 4 MiB cap. The dispatcher
    # detects this is a query_class result, drops the heaviest field
    # (full_text) from every row, and returns success with a _truncated
    # annotation. The LLM continues with the metadata rows it asked for
    # instead of restarting the whole request.
    body = {
      "jsonrpc" => "2.0",
      "id"      => 1,
      "method"  => "tools/call",
      "params"  => {
        "name"      => "query_class",
        "arguments" => { "class_name" => "WideBook", "limit" => 50 },
      },
    }
    result = Parse::Agent::MCPDispatcher.call(body: body, agent: @agent)
    r = result[:body]["result"]
    assert_equal false, r["isError"], "query_class should recover with partial success"

    payload = JSON.parse(r["content"].first["text"])
    trunc   = payload["_truncated"]
    assert trunc, "_truncated annotation must be present, got #{payload.keys.inspect}"
    assert_equal "response_exceeded_max_bytes", trunc["reason"]
    assert_includes trunc["dropped_fields"], "full_text"
    # Heaviest-field drop alone was enough to fit all 50 books → no next_skip.
    refute payload["_truncated"].key?("next_skip"),
           "with one wide column removed all rows should fit"
    assert_match(/get_object/, trunc["hint"])

    # And the rows that came back genuinely lack full_text:
    sample = payload["results"].first
    refute sample.key?("full_text")
    assert sample.key?("title")
  end

  def test_query_class_refusal_when_truncate_cant_recover
    # Single row with TWO fields each larger than the entire response
    # cap. Dropping the heaviest leaves the other, which is still > cap →
    # not even one row can fit → truncate returns nil → dispatcher falls
    # back to refusal with the per-field diagnostic.
    fat_agent = Parse::Agent.new(permissions: :readonly)
    cap = Parse::Agent::MCPDispatcher::MAX_TOOL_RESPONSE_BYTES
    huge_rows = [{
      "objectId" => "monster",
      "blob_a"   => "x" * (cap + 100_000),
      "blob_b"   => "y" * (cap + 100_000),
    }]
    fc = Object.new
    fc.define_singleton_method(:find_objects) do |_class, _q, **_opts|
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results)  { huge_rows }
      r.define_singleton_method(:count)    { huge_rows.size }
      r
    end
    fat_agent.define_singleton_method(:client) { fc }

    body = {
      "jsonrpc" => "2.0",
      "id"      => 10,
      "method"  => "tools/call",
      "params"  => {
        "name"      => "query_class",
        "arguments" => { "class_name" => "WideBook", "limit" => 1 },
      },
    }
    result = Parse::Agent::MCPDispatcher.call(body: body, agent: fat_agent)
    r = result[:body]["result"]
    assert_equal true, r["isError"],
                 "single oversized row with no useful remainder must refuse, not recover"
    msg = r["content"].first["text"]
    assert_match(/exceeded #{Parse::Agent::MCPDispatcher::MAX_TOOL_RESPONSE_BYTES} bytes/, msg)
    assert_match(/Largest fields by bytes/, msg)
    assert(/blob_a|blob_b/.match?(msg), "diagnostic should name one of the blob fields: #{msg.inspect}")
  end

  # ---- 2. Same query with keys: projection stays within budget ----------

  def test_keys_projection_drops_response_below_cap
    body = {
      "jsonrpc" => "2.0",
      "id"      => 2,
      "method"  => "tools/call",
      "params"  => {
        "name"      => "query_class",
        "arguments" => {
          "class_name" => "WideBook",
          "limit"     => 50,
          "keys"      => ["title", "year", "description"],
        },
      },
    }
    result = Parse::Agent::MCPDispatcher.call(body: body, agent: @agent)
    r = result[:body]["result"]
    assert_equal false, r["isError"], "projection should bring response under cap"
    text = r["content"].first["text"]
    refute_includes text, "x" * 1000   # full_text body should not be present
    # And the projection should still surface the metadata we did ask for:
    parsed = JSON.parse(text)
    first = parsed["results"].first
    assert first.key?("title")
    refute first.key?("full_text")
  end

  # ---- 3. Single-record get_object — 100 KB fits fine -------------------

  def test_single_record_fetch_under_cap
    body = {
      "jsonrpc" => "2.0",
      "id"      => 3,
      "method"  => "tools/call",
      "params"  => {
        "name"      => "get_object",
        "arguments" => { "class_name" => "WideBook", "object_id" => NEEDLE_ID },
      },
    }
    result = Parse::Agent::MCPDispatcher.call(body: body, agent: @agent)
    r = result[:body]["result"]
    assert_equal false, r["isError"]
    text = r["content"].first["text"]
    # 100 KB body shipped in full; well under 4 MiB.
    assert_operator text.bytesize, :<, Parse::Agent::MCPDispatcher::MAX_TOOL_RESPONSE_BYTES
    assert_includes text, NEEDLE_TITLE
    assert_includes text, "y" * 100  # full_text content is present
  end

  # ---- 4. agent_fields allowlist denies full_text regardless of keys: ---

  def test_agent_fields_allowlist_intersects_caller_keys
    # Caller asks for [title, full_text]. agent_fields allowlist on
    # GuardedBook is [title, year, description] — `full_text` is silently
    # dropped from the projection set, so the response never includes it
    # and stays under the cap even on a 50-row pull.
    body = {
      "jsonrpc" => "2.0",
      "id"      => 4,
      "method"  => "tools/call",
      "params"  => {
        "name"      => "query_class",
        "arguments" => {
          "class_name" => "GuardedBook",
          "limit"     => 50,
          "keys"      => ["title", "full_text"],
        },
      },
    }
    result = Parse::Agent::MCPDispatcher.call(body: body, agent: @agent)
    r = result[:body]["result"]
    assert_equal false, r["isError"]
    parsed = JSON.parse(r["content"].first["text"])
    first = parsed["results"].first
    assert first.key?("title")
    refute first.key?("full_text"), "agent_fields allowlist must drop unauthorized projection key"
  end

  def test_agent_fields_default_projection_when_keys_omitted
    # When caller does not pass `keys:` at all, an agent_fields-protected
    # class projects to the allowlist automatically — the wide column
    # cannot leak through the default path either.
    body = {
      "jsonrpc" => "2.0",
      "id"      => 5,
      "method"  => "tools/call",
      "params"  => { "name" => "query_class",
                     "arguments" => { "class_name" => "GuardedBook", "limit" => 50 } },
    }
    result = Parse::Agent::MCPDispatcher.call(body: body, agent: @agent)
    r = result[:body]["result"]
    assert_equal false, r["isError"]
    parsed = JSON.parse(r["content"].first["text"])
    refute parsed["results"].first.key?("full_text")
  end

  # ---- 5. Find the needle, then ask for its body separately -------------

  def test_two_step_needle_pattern
    # Step 1: count-style discovery — narrow with `where:` and project away
    # the heavy column to find the row.
    body1 = {
      "jsonrpc" => "2.0",
      "id"      => 6,
      "method"  => "tools/call",
      "params"  => {
        "name"      => "query_class",
        "arguments" => {
          "class_name" => "WideBook",
          "where"     => { "title" => NEEDLE_TITLE },
          "keys"      => ["title", "year", "description"],
        },
      },
    }
    r1 = Parse::Agent::MCPDispatcher.call(body: body1, agent: @agent)[:body]["result"]
    assert_equal false, r1["isError"]
    parsed = JSON.parse(r1["content"].first["text"])
    assert_equal 1, parsed["result_count"]
    needle = parsed["results"].first
    assert_equal NEEDLE_ID, needle["objectId"]

    # Step 2: fetch the full body for the one row we now care about.
    body2 = {
      "jsonrpc" => "2.0",
      "id"      => 7,
      "method"  => "tools/call",
      "params"  => {
        "name"      => "get_object",
        "arguments" => { "class_name" => "WideBook", "object_id" => needle["objectId"] },
      },
    }
    r2 = Parse::Agent::MCPDispatcher.call(body: body2, agent: @agent)[:body]["result"]
    assert_equal false, r2["isError"]
    full = JSON.parse(r2["content"].first["text"])
    # get_object response wraps the object — find the full_text wherever it lives.
    text_field = full.dig("object", "full_text") || full["full_text"]
    assert_equal TEXT_LEN, text_field.length
  end

  # ---- 6. export_data with a wide column inflates output past cap -------

  def test_export_with_full_text_column_exceeds_cap
    # Exporting all 50 books with the 100 KB full_text column would produce
    # a >5 MB CSV. The dispatcher refuses the response wholesale rather
    # than truncating mid-record.
    body = {
      "jsonrpc" => "2.0",
      "id"      => 8,
      "method"  => "tools/call",
      "params"  => {
        "name"      => "export_data",
        "arguments" => {
          "class_name" => "WideBook",
          "limit"     => 50,
          "columns"   => ["title", "year", "full_text"],
          "format"    => "csv",
        },
      },
    }
    result = Parse::Agent::MCPDispatcher.call(body: body, agent: @agent)
    r = result[:body]["result"]
    assert_equal true, r["isError"]
    assert_match(/exceeded #{Parse::Agent::MCPDispatcher::MAX_TOOL_RESPONSE_BYTES} bytes/,
                 r["content"].first["text"])
  end

  def test_export_metadata_only_fits_easily
    body = {
      "jsonrpc" => "2.0",
      "id"      => 9,
      "method"  => "tools/call",
      "params"  => {
        "name"      => "export_data",
        "arguments" => {
          "class_name" => "WideBook",
          "limit"     => 50,
          "columns"   => ["title", "year", "description"],
          "format"    => "csv",
        },
      },
    }
    result = Parse::Agent::MCPDispatcher.call(body: body, agent: @agent)
    r = result[:body]["result"]
    assert_equal false, r["isError"]
    text = r["content"].first["text"]
    parsed = JSON.parse(text)
    assert_equal 50, parsed["row_count"]
    assert_includes parsed["output"], NEEDLE_TITLE
  end
end
