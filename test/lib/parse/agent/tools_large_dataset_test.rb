# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# ============================================================================
# 100k-row in-memory harness.
#
# Simulates a high-cardinality Parse class (LargeStudent) with one known
# "needle" record buried in 100,000 rows of pseudo-random data. The fake
# client implements a minimal subset of find_objects / aggregate_pipeline /
# get_object so the agent's read tools can be exercised without Docker.
#
# Purpose: exercise the conversational guardrails that prevent an LLM from
# accidentally pulling the whole dataset into its context window —
#   - query_class display cap (ResultFormatter::MAX_RESULTS_DISPLAY = 50)
#   - aggregate auto-$limit:200 injection
#   - export_data row_cap (default 1_000, max 10_000)
#   - count_objects-then-narrow pattern for finding the needle.
# ============================================================================
class ToolsLargeDatasetTest < Minitest::Test
  class LargeStudent < Parse::Object
    parse_class "LargeStudent"
    property :name, :string
    property :grade, :integer
    property :subject, :string
    property :email, :string
  end

  TOTAL        = 100_000
  NEEDLE_ID    = "needle_targetina"
  NEEDLE_NAME  = "Targetina Findwell"
  NEEDLE_GRADE = 12
  NEEDLE_SUBJ  = "Astronomy"
  SUBJECTS     = %w[Algebra Biology Chemistry English History Physics].freeze

  # Lazily build the row corpus once per process. 100k hashes is ~30 MB
  # resident; cheap enough but not something we want to repeat per test.
  def self.rows
    @rows ||= begin
      rng = Random.new(42) # deterministic
      rows = Array.new(TOTAL) do |i|
        {
          "objectId" => format("id_%06d", i),
          "name"     => "Student#{i}_#{rng.bytes(3).unpack1('H*')}",
          "grade"    => 9 + rng.rand(4),
          "subject"  => SUBJECTS[rng.rand(SUBJECTS.size)],
          "email"    => "student#{i}@example.edu",
        }
      end
      rows[42_000] = {
        "objectId" => NEEDLE_ID,
        "name"     => NEEDLE_NAME,
        "grade"    => NEEDLE_GRADE,
        "subject"  => NEEDLE_SUBJ,
        "email"    => "targetina@example.edu",
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
      filtered = ToolsLargeDatasetTest.apply_where(rows, query[:where])

      if query[:count].to_i == 1 && query[:limit].to_i == 0
        # count-only path (count_objects tool)
        r = Object.new
        r.define_singleton_method(:success?) { true }
        r.define_singleton_method(:count)    { filtered.size }
        r.define_singleton_method(:results)  { [] }
        next r
      end

      limit = query[:limit] || filtered.size
      page  = filtered.first(limit.to_i)
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results)  { page }
      r.define_singleton_method(:count)    { page.size }
      r
    end

    fake_client.define_singleton_method(:aggregate_pipeline) do |_class, pipeline, **_opts|
      out = rows
      pipeline.each do |stage|
        op = stage.keys.first.to_s
        case op
        when "$match"
          out = ToolsLargeDatasetTest.apply_match(out, stage["$match"])
        when "$limit"
          out = out.first(stage["$limit"].to_i)
        when "$skip"
          out = out.drop(stage["$skip"].to_i)
        when "$count"
          out = [{ stage["$count"] => out.size }]
        when "$group"
          # Minimal: only support _id by a single field plus $sum aggregations
          spec = stage["$group"]
          id_expr = spec["_id"]
          groups = Hash.new { |h, k| h[k] = { "_id" => k } }
          field = id_expr.is_a?(String) ? id_expr.sub(/^\$/, "") : nil
          out.each do |row|
            key = field ? row[field] : nil
            g = groups[key]
            spec.each do |k, v|
              next if k == "_id"
              if v.is_a?(Hash) && v.key?("$sum")
                inc = v["$sum"]
                g[k] = (g[k] || 0) + (inc.is_a?(Numeric) ? inc : 1)
              end
            end
          end
          out = groups.values
        end
      end
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results)  { out }
      r
    end

    @agent.define_singleton_method(:client) { fake_client }
  end

  # ---- where / $match helpers -------------------------------------------
  # `query[:where]` arrives as JSON (because query_class calls
  # ConstraintTranslator.translate(where).to_json). For this harness we
  # only need equality matches, so the parser is intentionally tiny.

  def self.apply_where(rows, where_json)
    return rows if where_json.nil? || where_json.empty?
    conds = where_json.is_a?(String) ? JSON.parse(where_json) : where_json
    apply_match(rows, conds)
  end

  def self.apply_match(rows, conds)
    return rows if conds.nil? || conds.empty?
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

  # ---- query_class: display cap and has_more -----------------------------

  def test_naive_query_caps_display_at_50_and_signals_has_more
    result = @agent.execute(:query_class, class_name: "LargeStudent")
    assert result[:success]
    data = result[:data]
    # The dataset has 100k rows; the underlying limit clamps at DEFAULT_LIMIT
    # (100). The result_count reflects what came back from the client
    # (100), and the display is trimmed to MAX_RESULTS_DISPLAY (50).
    assert_equal Parse::Agent::DEFAULT_LIMIT, data[:result_count]
    assert_equal 50, data[:results].size
    assert data[:truncated]
    assert_match(/Showing first 50 of/, data[:truncated_note])
    assert data[:pagination][:has_more]
  end

  def test_query_with_max_limit_still_caps_display_at_50
    result = @agent.execute(:query_class, class_name: "LargeStudent",
                            limit: Parse::Agent::MAX_LIMIT)
    assert result[:success]
    data = result[:data]
    # Even at the MAX_LIMIT (1000) the display is still 50.
    assert_equal Parse::Agent::MAX_LIMIT, data[:result_count]
    assert_equal 50, data[:results].size
    assert data[:truncated]
  end

  # ---- count-then-narrow needle pattern ---------------------------------

  def test_count_objects_returns_full_cardinality
    result = @agent.execute(:count_objects, class_name: "LargeStudent")
    assert result[:success]
    assert_equal TOTAL, result[:data][:count]
  end

  def test_count_by_grade_narrows_the_haystack
    # An LLM-style "how many seniors are in this dataset" call. Grade is one
    # of four values evenly distributed, so the count should be roughly
    # TOTAL/4 (the rng + needle injection produces a small variance).
    result = @agent.execute(:count_objects, class_name: "LargeStudent",
                            where: { "grade" => 12 })
    assert result[:success]
    count = result[:data][:count]
    assert_in_delta TOTAL / 4.0, count, TOTAL * 0.05
  end

  def test_needle_findable_with_narrow_where
    # The needle is one row out of 100k. With a precise equality filter the
    # query returns exactly one row and the display does not need to truncate.
    result = @agent.execute(:query_class, class_name: "LargeStudent",
                            where: { "name" => NEEDLE_NAME })
    assert result[:success]
    data = result[:data]
    assert_equal 1, data[:result_count]
    refute data[:truncated]
    found = data[:results].first
    assert_equal NEEDLE_NAME, found["name"]
    assert_equal NEEDLE_GRADE, found["grade"]
    assert_equal NEEDLE_SUBJ,  found["subject"]
  end

  # ---- aggregate: auto-$limit ------------------------------------------

  def test_aggregate_match_only_is_auto_limited
    result = @agent.execute(:aggregate, class_name: "LargeStudent",
                            pipeline: [{ "$match" => { "grade" => 11 } }])
    assert result[:success]
    data = result[:data]
    assert_equal true, data[:auto_limited]
    assert_equal 200, data[:auto_limit]
    assert_equal 200, data[:result_count]
    assert_match(/\$limit:200/, data[:hint])
  end

  def test_aggregate_terminal_count_is_not_limited
    result = @agent.execute(:aggregate, class_name: "LargeStudent",
                            pipeline: [{ "$match" => { "grade" => 12 } },
                                       { "$count" => "total" }])
    assert result[:success]
    data = result[:data]
    refute data[:auto_limited]
    row = data[:results].first
    total = row["total"] || row[:total]
    assert_in_delta TOTAL / 4.0, total, TOTAL * 0.05
  end

  def test_aggregate_explicit_terminal_limit_is_respected
    result = @agent.execute(:aggregate, class_name: "LargeStudent",
                            pipeline: [{ "$match" => { "grade" => 10 } },
                                       { "$limit" => 25 }])
    assert result[:success]
    data = result[:data]
    refute data[:auto_limited]
    assert_equal 25, data[:result_count]
  end

  def test_aggregate_under_cap_omits_auto_limited_hint
    # When the result set is smaller than the auto-cap (200), the cap
    # never actually fires — even though no terminal $limit / $count was
    # supplied. The hint is gated on result_count >= cap so small
    # aggregations don't pay the ~200-byte hint cost on every call.
    result = @agent.execute(:aggregate, class_name: "LargeStudent",
                            pipeline: [
                              { "$match" => { "grade" => 10 } },
                              { "$group" => { "_id" => "$subject", "n" => { "$sum" => 1 } } },
                            ])
    assert result[:success]
    data = result[:data]
    assert data[:result_count] < 200,
           "grouped result must be smaller than the auto-cap for this regression to be meaningful"
    refute data[:auto_limited], "auto_limited must NOT be set when the cap did not fire"
    refute data[:auto_limit],   "auto_limit must NOT be set when the cap did not fire"
    refute data[:hint],         "hint must NOT be set when the cap did not fire"
  end

  # ---- export_data: row_cap truncation ----------------------------------

  def test_export_data_truncates_at_default_row_cap
    # No explicit row_cap. The fetched query limit clamps to MAX_LIMIT
    # (1000), which exactly matches DEFAULT_EXPORT_ROW_CAP — the export
    # therefore returns the cap's worth of rows and is not flagged
    # truncated (truncated only fires when available > cap).
    result = @agent.execute(:export_data, class_name: "LargeStudent",
                            limit: 5_000, format: "csv")
    assert result[:success]
    data = result[:data]
    # MAX_LIMIT (1000) bounds the upstream fetch; row_cap (1000) equals
    # that, so no truncation flag — but row_count is the cap value.
    assert_equal 1_000, data[:row_count]
    refute data[:truncated]
    # CSV header line plus 1000 data lines:
    assert_equal 1_001, data[:output].lines.size
  end

  def test_export_data_with_low_row_cap_truncates
    # Upstream fetch limit (500) > row_cap (100) — the cap clips and the
    # truncated flag fires.
    result = @agent.execute(:export_data, class_name: "LargeStudent",
                            limit: 500, row_cap: 100, format: "csv")
    assert result[:success]
    data = result[:data]
    assert data[:truncated]
    assert_equal 100, data[:row_cap]
    assert_equal 100, data[:row_count]
    assert_equal 500, data[:available_rows]
    assert_match(/Output truncated/, data[:hint])
  end

  def test_export_data_aggregate_mode_inherits_auto_limit
    # When pipeline mode is used in export, the underlying pipeline also
    # gets auto-$limit:200 injected (so the upstream fetch is bounded).
    # row_cap then clips the formatted output further.
    result = @agent.execute(:export_data, class_name: "LargeStudent",
                            pipeline: [{ "$match" => { "grade" => 11 } }],
                            row_cap: 100, format: "csv")
    assert result[:success]
    data = result[:data]
    # 200 rows came back from the underlying aggregate (auto-limited);
    # row_cap of 100 then trimmed the output.
    assert_equal 100, data[:row_count]
    assert data[:truncated]
    assert_equal 200, data[:available_rows]
  end

  def test_export_data_finding_needle_returns_one_row
    result = @agent.execute(:export_data, class_name: "LargeStudent",
                            where: { "name" => NEEDLE_NAME },
                            format: "csv")
    assert result[:success]
    data = result[:data]
    assert_equal 1, data[:row_count]
    refute data[:truncated]
    assert_includes data[:output], NEEDLE_NAME
    assert_includes data[:output], NEEDLE_SUBJ
  end
end
