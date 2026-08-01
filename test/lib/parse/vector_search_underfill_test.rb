# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the candidate-window behavior of
# Parse::VectorSearch.search.
#
# Atlas applies `$vectorSearch.limit` BEFORE the SDK's ACL `$match`,
# `protectedFields` redaction, pointer-field filtering, and any
# caller-supplied `filter`. Setting `limit` to `k` therefore truncates
# the ranking before visibility is known, and a scoped caller receives
# fewer than `k` rows even when plenty of readable matches exist. The
# search raises `limit` to an internal candidate window and trims to
# `k` only after every enforcement layer has run.
class VectorSearchUnderfillTest < Minitest::Test
  FakeResolution = Struct.new(:master, :user_id, :permission_strings, keyword_init: true) do
    def master? = master
  end

  # Collection double that records the pipeline and replays rows.
  #
  # It honors the `$vectorSearch.limit` AND any `$match` stages, because
  # in a real pipeline those run server-side — so `post_filter_count` is
  # measured after them. An earlier version of this harness stubbed the
  # ACL `$match` away, which made a post-filter count look like a
  # pre-filter one and hid exactly that distinction.
  class FakeColl
    attr_reader :pipelines

    def initialize(rows)
      @rows = rows
      @pipelines = []
    end

    def aggregate(pipeline, _opts = {})
      @pipelines << pipeline
      rows = @rows.first(pipeline.dig(0, "$vectorSearch", "limit"))
      pipeline.each do |stage|
        next unless (m = stage["$match"])
        rows = rows.select { |r| match?(r, m) }
      end
      rows
    end

    private

    # Only the shapes this suite emits: `_rperm $in [...]` and equality.
    def match?(row, criteria)
      criteria.all? do |field, cond|
        actual = row[field]
        if cond.is_a?(Hash) && cond.key?("$in")
          Array(actual).any? { |v| cond["$in"].include?(v) }
        else
          actual == cond
        end
      end
    end
  end

  def setup
    @events = []
    @sub = ActiveSupport::Notifications.subscribe(
      Parse::VectorSearch::AS_NOTIFICATION_NAME
    ) { |*args| @events << ActiveSupport::Notifications::Event.new(*args).payload }
  end

  def teardown
    ActiveSupport::Notifications.unsubscribe(@sub) if @sub
  end

  # ---- the underfill fix ------------------------------------------------

  # 100 matches exist; the caller may read only every tenth. Asking for
  # 5 must yield 5, not the 1 that survives a limit-5 window.
  def test_scoped_search_fills_k_despite_heavy_acl_attrition
    rows = (0...100).map { |i| { "_id" => "doc#{i}", "_rperm" => [i % 10 == 0 ? "u1" : "other"] } }
    results = run_search(rows, k: 5, master: false)

    assert_equal 5, results.length, "ACL attrition must not underfill the result set"
    assert results.all? { |r| r["_id"].to_s.start_with?("doc") }
  end

  def test_candidate_window_is_raised_above_k_for_scoped_callers
    rows = (0...500).map { |i| { "_id" => "d#{i}", "_rperm" => ["u1"] } }
    coll = FakeColl.new(rows)
    run_search(rows, k: 5, master: false, coll: coll)

    vs = coll.pipelines.first.dig(0, "$vectorSearch")
    assert_equal 5 * Parse::VectorSearch::DEFAULT_CANDIDATE_MULTIPLIER, vs["limit"]
    assert_operator vs["numCandidates"], :>=, vs["limit"],
                    "Atlas requires numCandidates >= limit"
  end

  # Master with no filter has no attrition, so the old one-for-one cost
  # is preserved rather than fetching 10x for nothing.
  def test_master_without_filter_does_not_overfetch
    rows = (0...100).map { |i| { "_id" => "d#{i}" } }
    coll = FakeColl.new(rows)
    run_search(rows, k: 5, master: true, coll: coll)

    assert_equal 5, coll.pipelines.first.dig(0, "$vectorSearch", "limit")
  end

  # A caller-supplied post-filter drops rows after `limit`, so it forces
  # an overfetch even in master mode.
  def test_master_with_post_filter_does_overfetch
    rows = (0...100).map { |i| { "_id" => "d#{i}" } }
    coll = FakeColl.new(rows)
    run_search(rows, k: 5, master: true, coll: coll, filter: { "kind" => "a" })

    assert_operator coll.pipelines.first.dig(0, "$vectorSearch", "limit"), :>, 5
  end

  def test_never_returns_more_than_k
    rows = (0...100).map { |i| { "_id" => "d#{i}", "_rperm" => ["u1"] } }
    assert_equal 3, run_search(rows, k: 3, master: false).length
  end

  # ---- explicit override ------------------------------------------------

  def test_explicit_candidate_limit_is_honored
    rows = (0...900).map { |i| { "_id" => "d#{i}", "_rperm" => ["u1"] } }
    coll = FakeColl.new(rows)
    run_search(rows, k: 5, master: false, coll: coll, candidate_limit: 400)

    assert_equal 400, coll.pipelines.first.dig(0, "$vectorSearch", "limit")
  end

  def test_candidate_limit_below_k_is_refused
    rows = [{ "_id" => "d0", "_rperm" => ["u1"] }]
    err = assert_raises(ArgumentError) do
      run_search(rows, k: 10, master: false, candidate_limit: 5)
    end
    assert_match(/candidate_limit .* must be >= k/, err.message)
  end

  def test_candidate_limit_above_atlas_cap_is_refused
    rows = [{ "_id" => "d0", "_rperm" => ["u1"] }]
    err = assert_raises(ArgumentError) do
      run_search(rows, k: 10, master: false, candidate_limit: 10_001)
    end
    assert_match(/candidate_limit capped at 10000/, err.message)
  end

  # A large k must not push the derived window past Atlas's ceiling.
  def test_derived_window_is_clamped_to_the_atlas_cap
    rows = (0...10).map { |i| { "_id" => "d#{i}", "_rperm" => ["u1"] } }
    coll = FakeColl.new(rows)
    run_search(rows, k: 1000, master: false, coll: coll)

    vs = coll.pipelines.first.dig(0, "$vectorSearch")
    assert_operator vs["limit"], :<=, Parse::VectorSearch::MAX_CANDIDATE_LIMIT
    assert_operator vs["numCandidates"], :<=, Parse::VectorSearch::MAX_CANDIDATE_LIMIT
    assert_operator vs["numCandidates"], :>=, vs["limit"]
  end

  def test_explicit_num_candidates_below_candidate_limit_is_refused
    rows = [{ "_id" => "d0", "_rperm" => ["u1"] }]
    err = assert_raises(ArgumentError) do
      run_search(rows, k: 10, master: false, candidate_limit: 100, num_candidates: 50)
    end
    assert_match(/must be >= candidate_limit/, err.message)
  end

  # ---- attrition telemetry ----------------------------------------------

  # Server-side ACL attrition is already reflected in post_filter_count,
  # since the $match runs inside the pipeline.
  def test_post_filter_count_is_measured_after_the_server_side_match
    rows = (0...100).map { |i| { "_id" => "d#{i}", "_rperm" => [i < 20 ? "u1" : "other"] } }
    run_search(rows, k: 5, master: false)

    e = @events.last
    assert_equal 5, e[:k]
    assert_equal 50, e[:candidate_limit]
    assert_equal 20, e[:post_filter_count], "20 of the 50 candidates survive the ACL $match"
    assert_equal 20, e[:post_pointer_count], "no client-side attrition in this mode"
    assert_equal 5, e[:returned_count]
    refute e[:underfilled]
  end

  # Client-side attrition (pointer fields, redaction) happens after the
  # pipeline, so it shows up as the gap between the two counts.
  def test_pointer_attrition_is_reported_separately
    rows = (0...100).map { |i| { "_id" => "d#{i}", "_rperm" => [i < 20 ? "u1" : "other"] } }
    run_search(rows, k: 5, master: false, acl_mode: :pointer)

    e = @events.last
    assert_equal 50, e[:post_filter_count], "the pipeline returned the full window"
    assert_equal 20, e[:post_pointer_count]
    assert_equal 30, e[:pointer_attrition]
  end

  # The signal worth alerting on: the caller got less than they asked
  # for, whatever the cause.
  def test_underfill_is_reported
    rows = (0...500).map { |i| { "_id" => "d#{i}", "_rperm" => [i == 499 ? "u1" : "other"] } }
    results = run_search(rows, k: 10, master: false)

    assert_equal 0, results.length
    assert @events.last[:underfilled], "caller asked for 10 and received 0"
  end

  def test_not_underfilled_when_k_is_satisfied
    rows = (0...100).map { |i| { "_id" => "d#{i}", "_rperm" => ["u1"] } }
    run_search(rows, k: 10, master: false)
    refute @events.last[:underfilled]
  end

  # ---- ANN width --------------------------------------------------------

  # The raised window must not multiply the HNSW search width as well.
  # Deriving numCandidates from candidate_limit would take a scoped
  # k=10 from 200 candidates to 2000.
  def test_ann_width_stays_anchored_to_k_not_the_raised_window
    rows = (0...100).map { |i| { "_id" => "d#{i}", "_rperm" => ["u1"] } }
    coll = FakeColl.new(rows)
    run_search(rows, k: 10, master: false, coll: coll)

    vs = coll.pipelines.first.dig(0, "$vectorSearch")
    assert_equal 10 * Parse::VectorSearch::DEFAULT_NUM_CANDIDATES_MULTIPLIER,
                 vs["numCandidates"], "ANN width must match the pre-window behavior"
    assert_operator vs["numCandidates"], :>=, vs["limit"]
  end

  # A caller-supplied num_candidates that was valid before the candidate
  # window existed must keep working: clamp the implicit window down to
  # it rather than raising.
  def test_legacy_num_candidates_clamps_the_implicit_window
    rows = (0...100).map { |i| { "_id" => "d#{i}", "_rperm" => ["u1"] } }
    coll = FakeColl.new(rows)
    run_search(rows, k: 10, master: false, coll: coll, num_candidates: 50)

    vs = coll.pipelines.first.dig(0, "$vectorSearch")
    assert_equal 50, vs["numCandidates"]
    assert_equal 50, vs["limit"], "window clamped down to the caller's ANN width"
  end

  def test_num_candidates_below_k_is_still_refused
    rows = [{ "_id" => "d0", "_rperm" => ["u1"] }]
    err = assert_raises(ArgumentError) do
      run_search(rows, k: 10, master: false, num_candidates: 5)
    end
    assert_match(/must be >= k/, err.message)
  end

  private

  # `acl_mode: :server` puts the ACL predicate in the pipeline (the real
  # arrangement — attrition happens before the rows come back).
  # `acl_mode: :pointer` instead drops rows client-side, standing in for
  # pointer-field filtering, which genuinely runs after the fetch.
  def run_search(rows, k:, master:, coll: nil, acl_mode: :server, **extra)
    coll ||= FakeColl.new(rows)
    resolution = FakeResolution.new(
      master: master, user_id: "u1", permission_strings: %w[u1 *],
    )
    acl_stage = if master || acl_mode != :server
        nil
      else
        { "$match" => { "_rperm" => { "$in" => %w[u1] } } }
      end
    Parse::MongoDB.stub(:require_gem!, nil) do
      Parse::MongoDB.stub(:available?, true) do
        Parse::MongoDB.stub(:collection, ->(_n, **_o) { coll }) do
          Parse::ACLScope.stub(:resolve!, ->(*, **) { resolution }) do
            Parse::ACLScope.stub(:match_stage_for, ->(_r) { acl_stage }) do
              Parse::ACLScope.stub(:redact_results!, ->(res, _r) {
                if !master && acl_mode == :pointer
                  res.select! { |d| Array(d["_rperm"]).include?("u1") }
                end
                res
              }) do
                Parse::CLPScope.stub(:protected_fields_for, ->(*) { [] }) do
                  Parse::CLPScope.stub(:pointer_fields_for, ->(*) { nil }) do
                    Parse::CLPScope.stub(:permits?, ->(*) { true }) do
                      Parse::VectorSearch.search(
                        "Doc", field: "embedding", query_vector: [0.1, 0.2, 0.3],
                               k: k, index: "vec_idx", **extra,
                      )
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
