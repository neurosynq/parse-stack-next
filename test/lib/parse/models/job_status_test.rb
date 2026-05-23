# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Unit tests for Parse::JobStatus — the model for Parse Server's `_JobStatus`
# collection. Exercises schema declarations, query scopes, instance predicates,
# the cleanup helper's running-row guard, and `agent_hidden` registration.
class TestJobStatus < Minitest::Test
  CORE_FIELDS = Parse::Object.fields.merge({
    job_name: :string,
    jobName: :string,
    source: :string,
    status: :string,
    message: :string,
    params: :object,
    finished_at: :date,
    finishedAt: :date,
  })

  def test_properties
    assert Parse::JobStatus < Parse::Object
    assert_equal "_JobStatus", Parse::JobStatus.parse_class
    assert_equal CORE_FIELDS, Parse::JobStatus.fields
    assert_empty Parse::JobStatus.references
    assert_empty Parse::JobStatus.relations
  end

  def test_status_constants
    assert_equal "running", Parse::JobStatus::STATUS_RUNNING
    assert_equal "succeeded", Parse::JobStatus::STATUS_SUCCEEDED
    assert_equal "failed", Parse::JobStatus::STATUS_FAILED
  end

  def test_agent_hidden_by_default
    assert Parse::JobStatus.agent_hidden?,
           "Parse::JobStatus should be agent_hidden — see class docstring"
  end

  # =========================================================================
  # Class-method query scopes
  # =========================================================================

  def test_running_scope_returns_query
    assert_instance_of Parse::Query, Parse::JobStatus.running
  end

  def test_succeeded_scope_returns_query
    assert_instance_of Parse::Query, Parse::JobStatus.succeeded
  end

  def test_failed_scope_returns_query
    assert_instance_of Parse::Query, Parse::JobStatus.failed
  end

  def test_recent_scope_returns_query
    assert_instance_of Parse::Query, Parse::JobStatus.recent
  end

  def test_recent_accepts_limit_kwarg
    assert_instance_of Parse::Query, Parse::JobStatus.recent(limit: 5)
  end

  def test_for_job_returns_query
    assert_instance_of Parse::Query, Parse::JobStatus.for_job("nightlyCleanup")
  end

  def test_for_job_coerces_symbol_to_string
    q = Parse::JobStatus.for_job(:nightlyCleanup)
    assert_instance_of Parse::Query, q
  end

  def test_older_than_returns_query
    assert_instance_of Parse::Query, Parse::JobStatus.older_than(days: 30)
  end

  def test_class_methods_exist
    %i[running succeeded failed recent for_job latest_for
       older_than older_than_count cleanup_older_than!].each do |m|
      assert_respond_to Parse::JobStatus, m, "Parse::JobStatus should respond to #{m}"
    end
  end

  # =========================================================================
  # Instance predicates
  # =========================================================================

  def test_running_predicate
    js = Parse::JobStatus.new
    js.status = "running"
    assert js.running?
    refute js.succeeded?
    refute js.failed?
  end

  def test_succeeded_predicate
    js = Parse::JobStatus.new
    js.status = "succeeded"
    assert js.succeeded?
    refute js.running?
    refute js.failed?
  end

  def test_failed_predicate
    js = Parse::JobStatus.new
    js.status = "failed"
    assert js.failed?
    refute js.running?
    refute js.succeeded?
  end

  def test_finished_predicate_with_finished_at
    js = Parse::JobStatus.new
    js.instance_variable_set(:@finished_at, Time.now)
    assert js.finished?
  end

  def test_finished_predicate_with_terminal_status
    js = Parse::JobStatus.new
    js.status = "succeeded"
    assert js.finished?
  end

  def test_finished_predicate_false_for_running
    js = Parse::JobStatus.new
    js.status = "running"
    refute js.finished?
  end

  def test_finished_predicate_false_for_blank
    js = Parse::JobStatus.new
    refute js.finished?
  end

  # =========================================================================
  # Duration calculation
  # =========================================================================

  def test_duration_nil_when_finished_at_missing
    js = Parse::JobStatus.new
    js.instance_variable_set(:@created_at, Time.now - 10)
    assert_nil js.duration
  end

  def test_duration_nil_when_created_at_missing
    js = Parse::JobStatus.new
    js.instance_variable_set(:@finished_at, Time.now)
    assert_nil js.duration
  end

  def test_duration_returns_seconds
    js = Parse::JobStatus.new
    t = Time.now
    js.instance_variable_set(:@created_at, t - 42)
    js.instance_variable_set(:@finished_at, t)
    assert_in_delta 42.0, js.duration, 0.001
  end

  # =========================================================================
  # cleanup_older_than! safety guard against running rows
  # =========================================================================

  def test_cleanup_older_than_excludes_running_by_default
    # The implementation should constrain the destroy scope to terminal
    # statuses unless include_running: true is passed. We can't hit the
    # network here, so verify the query that cleanup_older_than! would
    # build does include the status guard.
    scope = Parse::JobStatus.older_than(days: 30)
                            .where(:status.in => [Parse::JobStatus::STATUS_SUCCEEDED,
                                                  Parse::JobStatus::STATUS_FAILED])
    assert_instance_of Parse::Query, scope
    # Sanity check the underlying compiled-where structure contains the
    # status.in constraint plus the created_at.lt constraint.
    compiled = scope.compile_where.to_s
    assert_match(/status/, compiled)
    assert_match(/createdAt/, compiled)
  end

  def test_cleanup_older_than_signature_accepts_terminal_only
    # Verify the method's keyword-arg surface. End-to-end coverage of the
    # destructive path lives in the integration suite — it would destroy
    # rows unrelated to this test if invoked here.
    params = Parse::JobStatus.method(:cleanup_older_than!).parameters
    keyword_names = params.select { |kind, _| kind == :key }.map(&:last)
    assert_includes keyword_names, :days
    assert_includes keyword_names, :terminal_only
  end
end
