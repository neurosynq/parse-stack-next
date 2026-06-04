# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"

# DISRUPTIVE integration test: this file STOPS and RESTARTS the Parse
# Server container to simulate a real network/server outage, then proves
# the SDK degrades and recovers correctly.
#
# It is segregated from the normal integration run (see the Rakefile's
# `test:integration:disruptive` task and the `*disruptive*` exclusion in
# the default tasks) precisely because stopping the shared server would
# flake any other test running against it. It only ever touches the Parse
# Server container — mongo/redis stay up via DockerHelper.stop_server! /
# start_server! — so the database the rest of the suite relies on survives.
#
# What this pins, end to end against a real server going down and back up:
#   1. Baseline: the server is reachable/connected and CRUD works.
#   2. During a hard outage: reachable?/connected? flip to false WITHOUT
#      raising (the predicates stay safe booleans), and a real data request
#      raises a connection-class Parse::Error rather than hanging or
#      returning a bogus empty result.
#   3. After recovery: reachable?/connected? return true and CRUD works
#      again on the same client — the SDK does not get wedged on a stale
#      connection from before the outage.
class NetworkFailureDisruptiveTest < Minitest::Test
  include ParseStackIntegrationTest

  # Connection-class failures the SDK may raise once the server is gone.
  # assert_raises passes if the raised error matches ANY of these.
  OUTAGE_ERRORS = [
    Parse::Error::ConnectionError,
    Parse::Error::TimeoutError,
    Parse::Error::ServiceUnavailableError,
    Faraday::Error,
  ].freeze

  def teardown
    # Bulletproof restore: whatever state a test left the container in,
    # the next test's setup (and the rest of the suite) needs a healthy
    # server. ensure_server_running! is a no-op when already healthy.
    Parse::Test::DockerHelper.ensure_server_running!
    super
  end

  def test_outage_then_recovery_lifecycle
    client = Parse::Client.client

    # --- 1. Baseline --------------------------------------------------
    assert client.reachable?, "precondition: server must be reachable before the outage"
    assert client.connected?, "precondition: server must be connected before the outage"

    before = DisruptiveProbe.new(label: "before-outage")
    assert before.save, "precondition: CRUD must work before the outage"
    before_id = before.id
    refute_nil before_id

    # --- 2. Hard outage ----------------------------------------------
    Parse::Test::DockerHelper.stop_server!
    _wait_until(timeout: 15) { client.reachable? == false }

    refute client.reachable?,
           "reachable? must report false during a hard outage (got true)"
    refute client.connected?,
           "connected? must report false during a hard outage (got true)"

    # A real data request must surface a connection-class error, not hang
    # and not return a fabricated empty result.
    err = assert_raises(*OUTAGE_ERRORS) do
      DisruptiveProbe.query.where(label: "before-outage").results
    end
    refute_nil err, "an outage data request must raise, not return nil"

    # A create during the outage must also fail loudly (returns false /
    # raises) rather than silently appearing to succeed.
    blocked = DisruptiveProbe.new(label: "during-outage")
    created_during_outage =
      begin
        blocked.save
      rescue *OUTAGE_ERRORS
        false
      end
    refute created_during_outage, "a create during the outage must not report success"
    assert_nil blocked.id, "a failed create during the outage must not assign an id"

    # --- 3. Recovery --------------------------------------------------
    assert Parse::Test::DockerHelper.start_server!,
           "server must come back up after start_server!"
    # The Docker health probe (start_server! -> wait_for_server) confirms
    # the server answers, but the SDK's own pooled connection may need a
    # beat to discard a socket killed mid-outage. Poll the SDK client.
    _wait_until(timeout: 30) { client.reachable? }

    assert client.reachable?, "reachable? must return true after recovery"
    assert client.connected?, "connected? must return true after recovery"

    # CRUD works again on the SAME client instance.
    after = DisruptiveProbe.new(label: "after-recovery")
    assert _with_recovery_retries { after.save },
           "CRUD must work again after the server recovers"
    refute_nil after.id, "a post-recovery save must assign an id"
    @test_context.track(after) if @test_context
  end

  private

  # Poll a predicate until it is truthy or the timeout elapses. Returns the
  # final value (so callers can assert on it). Used instead of a bare sleep
  # so recovery is detected as soon as it happens.
  def _wait_until(timeout:, interval: 0.5)
    deadline = monotonic_now + timeout
    result = yield
    while !result && monotonic_now < deadline
      sleep interval
      result = yield
    end
    result
  end

  # A non-idempotent create (POST) is not auto-retried by the client, so a
  # single stale-socket error right after recovery would fail the test
  # spuriously. Retry the block a couple of times through transient
  # connection errors only.
  def _with_recovery_retries(attempts: 3)
    yield
  rescue *OUTAGE_ERRORS
    attempts -= 1
    raise if attempts <= 0
    sleep 1
    retry
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

# Minimal registered model so saves route to a real collection rather than
# the abstract Parse::Object base (whose parse_class is not a valid Parse
# identifier).
class DisruptiveProbe < Parse::Object
  parse_class "DisruptiveProbe"
  property :label, :string
end
