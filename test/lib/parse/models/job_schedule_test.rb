# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Unit tests for Parse::JobSchedule — the model for Parse Server's
# `_JobSchedule` collection. Exercises schema declarations, the `for_job`
# scope, the JSON-decoding helper `parsed_params`, and `agent_hidden`
# registration.
class TestJobSchedule < Minitest::Test
  CORE_FIELDS = Parse::Object.fields.merge({
    job_name: :string,
    jobName: :string,
    description: :string,
    params: :string, # canonical Parse Server schema stores params as String, not Object
    start_after: :string,
    startAfter: :string,
    days_of_week: :array,
    daysOfWeek: :array,
    time_of_day: :string,
    timeOfDay: :string,
    last_run: :integer,
    lastRun: :integer,
    repeat_minutes: :integer,
    repeatMinutes: :integer,
  })

  def test_properties
    assert Parse::JobSchedule < Parse::Object
    assert_equal "_JobSchedule", Parse::JobSchedule.parse_class
    assert_equal CORE_FIELDS, Parse::JobSchedule.fields
    assert_empty Parse::JobSchedule.references
    assert_empty Parse::JobSchedule.relations
  end

  def test_params_is_string_not_object
    # Confirms the deliberate choice that mirrors Parse Server's
    # defaultColumns._JobSchedule, where params is stored as a
    # JSON-encoded String (not Object) to avoid the `$`/`.` nested-key
    # restriction that applies to Object columns.
    assert_equal :string, Parse::JobSchedule.fields[:params]
  end

  def test_agent_hidden_by_default
    assert Parse::JobSchedule.agent_hidden?,
           "Parse::JobSchedule should be agent_hidden — see class docstring"
  end

  # =========================================================================
  # for_job query scope
  # =========================================================================

  def test_for_job_returns_query
    assert_instance_of Parse::Query, Parse::JobSchedule.for_job("nightlyCleanup")
  end

  def test_for_job_coerces_symbol_to_string
    assert_instance_of Parse::Query, Parse::JobSchedule.for_job(:nightlyCleanup)
  end

  # =========================================================================
  # parsed_params JSON decoder
  # =========================================================================

  def test_parsed_params_returns_nil_when_blank
    sched = Parse::JobSchedule.new
    assert_nil sched.parsed_params

    sched2 = Parse::JobSchedule.new(params: "")
    assert_nil sched2.parsed_params
  end

  def test_parsed_params_decodes_valid_json
    sched = Parse::JobSchedule.new(params: %({"dryRun":false,"limit":100}))
    decoded = sched.parsed_params
    assert_equal({ "dryRun" => false, "limit" => 100 }, decoded)
  end

  def test_parsed_params_handles_nested_structures
    sched = Parse::JobSchedule.new(params: %({"a":1,"b":[2,3],"c":{"d":true}}))
    decoded = sched.parsed_params
    assert_equal 1, decoded["a"]
    assert_equal [2, 3], decoded["b"]
    assert_equal({ "d" => true }, decoded["c"])
  end

  def test_parsed_params_returns_nil_on_invalid_json
    sched = Parse::JobSchedule.new(params: "not valid json {")
    assert_nil sched.parsed_params
  end

  def test_parsed_params_returns_nil_on_partial_json
    sched = Parse::JobSchedule.new(params: %({"a":}))
    assert_nil sched.parsed_params
  end
end
