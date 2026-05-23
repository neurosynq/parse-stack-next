# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require "securerandom"
require "json"

# Integration tests for Parse::JobSchedule against a real Parse Server.
#
# Run with:
#   PARSE_TEST_USE_DOCKER=true ruby -Ilib -Itest test/lib/parse/job_schedule_integration_test.rb
#
# `_JobSchedule` is master-key-only by default; the SDK falls through to
# master key when no session token is set, so direct .save() works.
class JobScheduleIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def setup_skipped?
    return true unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    false
  end

  def make_schedule(**attrs)
    defaults = {
      job_name: "itest_sched_#{SecureRandom.hex(3)}",
      description: "integration-test schedule",
      params: JSON.generate({ "dryRun" => false }),
      start_after: (Time.now + 60).utc.iso8601,
      days_of_week: ["mon", "wed", "fri"],
      time_of_day: "03:00:00",
      repeat_minutes: 1440,
    }
    sched = Parse::JobSchedule.new(defaults.merge(attrs))
    assert sched.save, "Parse::JobSchedule.save must succeed (#{sched.errors.inspect})"
    @test_context.track(sched)
    sched
  end

  # =========================================================================
  # Round-trip: create + reload preserves all canonical fields
  # =========================================================================

  def test_create_and_fetch_round_trip
    skip "Integration tests require PARSE_TEST_USE_DOCKER=true" if setup_skipped?

    payload = { "limit" => 100, "dryRun" => true, "channels" => ["news", "weather"] }
    sched = make_schedule(
      job_name: "round_trip_#{SecureRandom.hex(2)}",
      description: "Nightly cleanup",
      params: JSON.generate(payload),
      days_of_week: ["sun", "sat"],
      time_of_day: "02:30:00",
      repeat_minutes: nil,
      last_run: (Time.now.to_f * 1000).to_i,
    )

    refute_nil sched.id

    reloaded = Parse::JobSchedule.find(sched.id)
    refute_nil reloaded
    assert_equal sched.job_name, reloaded.job_name
    assert_equal "Nightly cleanup", reloaded.description
    assert_equal "02:30:00", reloaded.time_of_day
    assert_equal ["sun", "sat"], reloaded.days_of_week.to_a
    assert_kind_of Integer, reloaded.last_run
    # params is stored on the wire as a String per Parse Server's canonical
    # schema; reading it back gives the same JSON-encoded string we wrote.
    assert_kind_of String, reloaded.params
    assert_equal payload, JSON.parse(reloaded.params)
  end

  # =========================================================================
  # parsed_params helper on a real round-tripped row
  # =========================================================================

  def test_parsed_params_decodes_round_tripped_json
    skip "Integration tests require PARSE_TEST_USE_DOCKER=true" if setup_skipped?

    payload = { "team" => "ops", "alertOnFail" => true, "retries" => 3 }
    sched = make_schedule(params: JSON.generate(payload))

    reloaded = Parse::JobSchedule.find(sched.id)
    assert_equal payload, reloaded.parsed_params
  end

  def test_parsed_params_returns_nil_for_blank_round_trip
    skip "Integration tests require PARSE_TEST_USE_DOCKER=true" if setup_skipped?

    sched = make_schedule(params: nil)
    reloaded = Parse::JobSchedule.find(sched.id)
    assert_nil reloaded.parsed_params
  end

  # =========================================================================
  # for_job scope filters real rows
  # =========================================================================

  def test_for_job_filters_real_rows
    skip "Integration tests require PARSE_TEST_USE_DOCKER=true" if setup_skipped?

    name_a = "sched_a_#{SecureRandom.hex(2)}"
    name_b = "sched_b_#{SecureRandom.hex(2)}"

    a1 = make_schedule(job_name: name_a)
    a2 = make_schedule(job_name: name_a)
    b1 = make_schedule(job_name: name_b)

    a_ids = Parse::JobSchedule.for_job(name_a).all.map(&:id).sort
    b_ids = Parse::JobSchedule.for_job(name_b).all.map(&:id).sort

    assert_equal [a1.id, a2.id].sort, a_ids
    assert_equal [b1.id], b_ids
    assert_empty(a_ids & b_ids)
  end
end
