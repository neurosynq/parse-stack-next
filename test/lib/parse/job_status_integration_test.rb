# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require "securerandom"

# Integration tests for Parse::JobStatus against a real Parse Server.
#
# Run with:
#   PARSE_TEST_USE_DOCKER=true ruby -Ilib -Itest test/lib/parse/job_status_integration_test.rb
#
# Notes:
#   * `_JobStatus` is normally written by Parse Server's job runner. These
#     tests construct rows directly via the SDK (which falls through to the
#     master key when no session token is set) so that scope and lifecycle
#     behavior can be exercised without registering a server-side Cloud
#     Code job.
#   * `reset_database!` in the integration harness skips classes whose
#     names start with `_`, so each test cleans up its own rows via
#     `@test_context.track`.
class JobStatusIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def setup_skipped?
    return true unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    false
  end

  def make_job_status(**attrs)
    defaults = {
      job_name: "itest_job_#{SecureRandom.hex(3)}",
      source: "api",
      status: Parse::JobStatus::STATUS_SUCCEEDED,
      message: "ok",
      finished_at: Time.now,
    }
    js = Parse::JobStatus.new(defaults.merge(attrs))
    assert js.save, "Parse::JobStatus.save must succeed (#{js.errors.inspect})"
    @test_context.track(js)
    js
  end

  # =========================================================================
  # Round-trip: create + reload preserves all fields
  # =========================================================================

  def test_create_and_fetch_round_trip
    skip "Integration tests require PARSE_TEST_USE_DOCKER=true" if setup_skipped?

    js = make_job_status(
      job_name: "round_trip_#{SecureRandom.hex(2)}",
      status: "succeeded",
      message: "hello",
      params: { "limit" => 50, "dryRun" => true },
    )

    refute_nil js.id
    refute_nil js.created_at

    reloaded = Parse::JobStatus.find(js.id)
    refute_nil reloaded
    assert_equal js.job_name, reloaded.job_name
    assert_equal "succeeded", reloaded.status
    assert_equal "hello", reloaded.message
    assert_equal({ "limit" => 50, "dryRun" => true }, reloaded.params)
    refute_nil reloaded.finished_at
  end

  # =========================================================================
  # Status-bucket query scopes
  # =========================================================================

  def test_status_scopes_partition_correctly
    skip "Integration tests require PARSE_TEST_USE_DOCKER=true" if setup_skipped?

    tag = "scope_#{SecureRandom.hex(3)}"
    make_job_status(job_name: tag, status: "running",  finished_at: nil)
    make_job_status(job_name: tag, status: "succeeded")
    make_job_status(job_name: tag, status: "failed",   message: "boom")

    running_ids = Parse::JobStatus.running.where(job_name: tag).all.map(&:id)
    succeeded_ids = Parse::JobStatus.succeeded.where(job_name: tag).all.map(&:id)
    failed_ids = Parse::JobStatus.failed.where(job_name: tag).all.map(&:id)

    assert_equal 1, running_ids.size, "exactly one running row expected"
    assert_equal 1, succeeded_ids.size, "exactly one succeeded row expected"
    assert_equal 1, failed_ids.size, "exactly one failed row expected"
    assert_empty(running_ids & succeeded_ids)
    assert_empty(running_ids & failed_ids)
  end

  # =========================================================================
  # for_job + latest_for
  # =========================================================================

  def test_for_job_filters_by_name_and_latest_for_returns_most_recent
    skip "Integration tests require PARSE_TEST_USE_DOCKER=true" if setup_skipped?

    name_a = "job_a_#{SecureRandom.hex(2)}"
    name_b = "job_b_#{SecureRandom.hex(2)}"

    # Three runs of name_a, one of name_b
    a1 = make_job_status(job_name: name_a)
    sleep 1.05 # ensure distinct createdAt seconds
    a2 = make_job_status(job_name: name_a)
    sleep 1.05
    a3 = make_job_status(job_name: name_a)
    make_job_status(job_name: name_b)

    for_a = Parse::JobStatus.for_job(name_a).all.map(&:id).sort
    assert_equal [a1.id, a2.id, a3.id].sort, for_a,
                 "for_job should return exactly the rows tagged with that name"

    latest = Parse::JobStatus.latest_for(name_a)
    refute_nil latest
    assert_equal a3.id, latest.id, "latest_for should return the most-recent run"
  end

  # =========================================================================
  # cleanup_older_than! — actually invokes the method end-to-end
  # =========================================================================
  #
  # `_JobStatus.createdAt` is server-managed and cannot be PUT (Parse Server
  # 500s on direct writes). To exercise the destructive code path with a
  # populated database, we pass `days: -60` so the helper's cutoff lands
  # ~60 days in the future, making every just-created row eligible. Each
  # test scopes its rows to a unique `job_name` tag and only asserts about
  # rows under that tag, so unrelated rows in the test database are not a
  # concern (the helper still destroys them — that's its job — but we
  # don't observe that side effect).

  def test_cleanup_older_than_destroys_only_terminal_rows_by_default
    skip "Integration tests require PARSE_TEST_USE_DOCKER=true" if setup_skipped?

    tag = "cleanup_#{SecureRandom.hex(3)}"
    old_succeeded = make_job_status(job_name: tag, status: "succeeded")
    old_failed = make_job_status(job_name: tag, status: "failed")
    in_flight = make_job_status(job_name: tag, status: "running", finished_at: nil)

    # Sanity: all three rows are visible before cleanup.
    pre_ids = Parse::JobStatus.for_job(tag).all.map(&:id).sort
    assert_equal [old_succeeded.id, old_failed.id, in_flight.id].sort, pre_ids

    # Default invocation: `terminal_only: true`. Negative days makes the
    # cutoff fall in the future, so every row's `created_at` is "older."
    Parse::JobStatus.cleanup_older_than!(days: -60)

    remaining_ids = Parse::JobStatus.for_job(tag).all.map(&:id)
    assert_equal [in_flight.id], remaining_ids,
                 "running row must survive cleanup_older_than! default call"
  end

  def test_cleanup_older_than_terminal_only_false_reaps_running_rows
    skip "Integration tests require PARSE_TEST_USE_DOCKER=true" if setup_skipped?

    tag = "cleanup_inc_#{SecureRandom.hex(3)}"
    long_runner = make_job_status(job_name: tag, status: "running", finished_at: nil)
    old_succeeded = make_job_status(job_name: tag, status: "succeeded")

    Parse::JobStatus.cleanup_older_than!(days: -60, terminal_only: false)

    # With the status guard dropped, both rows are gone.
    refute Parse::JobStatus.for_job(tag).count.positive?,
           "terminal_only: false must reap every old row including running"
    # Defensive direct fetches in case the count query was cached.
    assert_nil Parse::JobStatus.find(long_runner.id)
    assert_nil Parse::JobStatus.find(old_succeeded.id)
  end
end
