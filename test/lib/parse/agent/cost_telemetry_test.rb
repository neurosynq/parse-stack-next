# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_rack_app"

# ============================================================================
# Tests for cost-estimation fields added to parse.agent.tool_call payloads.
#
# The :est_input_tokens field uses the heuristic: result_size_bytes / 4.
# The :est_cost_usd field is optional and only appears when
# Parse::Agent.token_cost_per_million_input is set to a numeric rate.
# ============================================================================
class CostTelemetryTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end

    @agent = Parse::Agent.new(permissions: :readonly)
    @events = []
    @subscriber = ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |*args|
      e = ActiveSupport::Notifications::Event.new(*args)
      @events << e.payload.dup
    end

    # Capture original rate so teardown can restore it safely regardless
    # of what individual tests set. Class-level globals must not leak.
    @original_rate = Parse::Agent.token_cost_per_million_input
    Parse::Agent.token_cost_per_million_input = nil
  end

  def teardown
    ActiveSupport::Notifications.unsubscribe(@subscriber)
    Parse::Agent.token_cost_per_million_input = @original_rate
  end

  # Build a fake client whose find_objects returns a lightweight stub
  # that the count_objects tool can use. Returns the agent stubbed to use it.
  def agent_with_fake_client(count: 5, results: [])
    fake_client = Object.new
    fake_client.define_singleton_method(:find_objects) do |_c, _q, **_opts|
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:count)    { count }
      r.define_singleton_method(:results)  { results }
      r
    end
    @agent.define_singleton_method(:client) { fake_client }
    @agent
  end

  # ---- est_input_tokens on success ----------------------------------------

  def test_est_input_tokens_present_on_success
    agent_with_fake_client(count: 42)
    @agent.execute(:count_objects, class_name: "Song")

    assert_equal 1, @events.size
    payload = @events.first
    assert payload.key?(:result_size),      "expected :result_size in payload"
    assert payload.key?(:est_input_tokens), "expected :est_input_tokens in payload"
    assert_equal true, payload[:success]
  end

  def test_est_input_tokens_is_integer_division_of_result_size
    agent_with_fake_client(count: 42)
    @agent.execute(:count_objects, class_name: "Song")

    payload = @events.first
    result_size = payload[:result_size]
    refute_nil result_size, "result_size must be set for this assertion to be valid"

    expected_tokens = result_size / 4   # integer division — exact heuristic
    assert_equal expected_tokens, payload[:est_input_tokens]
  end

  def test_est_input_tokens_exact_heuristic_with_known_size
    # Make the tool return a specific value so we can compute the expected
    # JSON bytesize precisely and verify integer division.
    known_result = { count: 1 }
    known_json_size = JSON.generate(known_result).bytesize  # e.g. 11 bytes => 2 tokens

    # Stub Tools.invoke directly so the payload result matches our expectation.
    agent_with_fake_client(count: 1)
    Parse::Agent::Tools.stub(:invoke, known_result) do
      @agent.execute(:count_objects, class_name: "Anything")
    end

    payload = @events.first
    assert_equal known_json_size,          payload[:result_size]
    assert_equal known_json_size / 4,      payload[:est_input_tokens]
  end

  # ---- est_input_tokens absent when result_size is nil --------------------

  def test_est_input_tokens_absent_when_serialization_fails
    # Return a circular-reference object that JSON.generate cannot serialize.
    # The existing `rescue nil` on result_size will catch the NestingError,
    # and our new code must skip setting est_input_tokens.
    circular = {}
    circular[:self] = circular

    Parse::Agent::Tools.stub(:invoke, circular) do
      @agent.execute(:count_objects, class_name: "Anything")
    end

    payload = @events.first
    assert_nil payload[:result_size], "result_size should be nil after JSON serialization failure"
    refute payload.key?(:est_input_tokens),
           "est_input_tokens must not appear when result_size is nil"
  end

  # ---- est_cost_usd absent when rate is unset (default) -------------------

  def test_est_cost_usd_absent_when_rate_not_configured
    # Ensure the default nil rate leaves :est_cost_usd out of the payload.
    assert_nil Parse::Agent.token_cost_per_million_input

    agent_with_fake_client(count: 7)
    @agent.execute(:count_objects, class_name: "Song")

    payload = @events.first
    refute payload.key?(:est_cost_usd),
           "est_cost_usd must not appear when token_cost_per_million_input is nil"
  end

  # ---- est_cost_usd present and proportional when rate is set -------------

  def test_est_cost_usd_present_when_rate_configured
    Parse::Agent.token_cost_per_million_input = 3.00

    agent_with_fake_client(count: 7)
    @agent.execute(:count_objects, class_name: "Song")

    payload = @events.first
    assert payload.key?(:est_cost_usd),
           "est_cost_usd must appear when token_cost_per_million_input is set"
    assert_kind_of Numeric, payload[:est_cost_usd]
  end

  def test_est_cost_usd_proportional_to_token_count
    rate = 3.00
    Parse::Agent.token_cost_per_million_input = rate

    known_result = { count: 99 }
    known_json_size = JSON.generate(known_result).bytesize

    Parse::Agent::Tools.stub(:invoke, known_result) do
      @agent.execute(:count_objects, class_name: "Anything")
    end

    payload = @events.first
    est_tokens  = known_json_size / 4
    expected_cost = (est_tokens / 1_000_000.0 * rate).round(6)

    assert_equal expected_cost, payload[:est_cost_usd]
  end

  def test_est_cost_usd_works_with_integer_rate
    # Operators may supply an Integer (e.g. 3) rather than a Float (3.00).
    # The 1_000_000.0 denominator ensures float division regardless.
    Parse::Agent.token_cost_per_million_input = 3  # Integer

    known_result = { count: 1 }
    known_json_size = JSON.generate(known_result).bytesize

    Parse::Agent::Tools.stub(:invoke, known_result) do
      @agent.execute(:count_objects, class_name: "Anything")
    end

    payload = @events.first
    est_tokens    = known_json_size / 4
    expected_cost = (est_tokens / 1_000_000.0 * 3).round(6)

    assert_equal expected_cost, payload[:est_cost_usd]
    # Verify it is actually a Float, not Integer zero from integer division
    assert_kind_of Float, payload[:est_cost_usd]
  end

  # ---- Tool failure: no result_size and no est_input_tokens ---------------

  def test_failure_path_has_no_token_fields
    # Make the fake client raise a Parse::Error so the error branch is taken.
    fake_client = Object.new
    fake_client.define_singleton_method(:find_objects) do |_c, _q, **_opts|
      raise Parse::Error, "simulated server error"
    end
    @agent.define_singleton_method(:client) { fake_client }

    @agent.execute(:count_objects, class_name: "Song")

    payload = @events.first
    assert_equal false, payload[:success]
    refute payload.key?(:result_size),      "result_size must not appear on failure"
    refute payload.key?(:est_input_tokens), "est_input_tokens must not appear on failure"
    refute payload.key?(:est_cost_usd),     "est_cost_usd must not appear on failure"
  end

  # ---- est_cost_usd absent when result_size nil even if rate set ----------

  def test_est_cost_usd_absent_when_result_size_nil_even_with_rate
    Parse::Agent.token_cost_per_million_input = 3.00

    circular = {}
    circular[:self] = circular

    Parse::Agent::Tools.stub(:invoke, circular) do
      @agent.execute(:count_objects, class_name: "Anything")
    end

    payload = @events.first
    assert_nil payload[:result_size]
    refute payload.key?(:est_input_tokens)
    refute payload.key?(:est_cost_usd)
  end
end
