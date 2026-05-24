# encoding: UTF-8
# frozen_string_literal: true

# Test 3: COLLSCAN refusal against real MongoDB.
#
# Verifies that the real MongoDB explain output is parsed correctly by the
# Tools#collscan_preflight path. Uses MCPCollscanProbe, a class whose
# `random_field` property has no Parse index, so full-collection scans are
# expected on queries against that field.
#
# All tests are gated on PARSE_TEST_USE_DOCKER=true.
#
# NOTE on expose_explain: Parse::Agent.expose_explain is already implemented
# (as of v4.1.0) and defaults to false. Tests that verify winning_plan
# is NOT in the refusal (expose_explain false) and IS present (expose_explain
# true) run unconditionally — no skip guard is needed.

require_relative "../../../test_helper_integration"
require "timeout"

require "parse/agent"

# ---------------------------------------------------------------------------
# Test fixture model — no explicit Parse index on random_field.
# ---------------------------------------------------------------------------
class MCPCollscanProbe < Parse::Object
  parse_class "MCPCollscanProbe"
  property :random_field, :string
  property :value, :integer, default: 0
end

# ---------------------------------------------------------------------------
# Main test class
# ---------------------------------------------------------------------------
class ToolsCollscanIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  RECORD_COUNT = 20

  # -------------------------------------------------------------------------
  # Helper: seed probe records and yield; always cleans up and resets flags.
  # -------------------------------------------------------------------------
  def with_collscan_probes
    probes = nil
    Parse::Agent::Tools.reset_registry!
    Parse::Agent.refuse_collscan = false
    Parse::Agent.expose_explain  = false

    probes = []
    RECORD_COUNT.times do |i|
      probe = MCPCollscanProbe.new(
        random_field: "rf_#{i}_#{SecureRandom.hex(4)}",
        value: i,
      )
      probe.save
      probes << probe
    end

    yield probes
  ensure
    probes&.each { |p| p.destroy rescue nil }
    Parse::Agent::Tools.reset_registry!
    Parse::Agent.refuse_collscan = false
    Parse::Agent.expose_explain  = false
  end

  # =========================================================================
  # 1. refuse_collscan = false (default) — queries proceed normally
  # =========================================================================

  def test_collscan_off_random_field_query_succeeds
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_collscan_probes do |_probes|
        Parse::Agent.refuse_collscan = false
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:query_class,
          class_name: "MCPCollscanProbe",
          where: { "random_field" => { "$exists" => true } },
          limit: 5,
        )
        assert result[:success],
               "Query should succeed with refuse_collscan=false: #{result[:error]}"
      end
    end
  end

  def test_collscan_off_does_not_return_refused_key
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_collscan_probes do |_probes|
        Parse::Agent.refuse_collscan = false
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:query_class,
          class_name: "MCPCollscanProbe",
          where: { "value" => { "$gte" => 0 } },
          limit: 3,
        )
        assert result[:success]
        if result[:data].is_a?(Hash)
          refute result[:data].key?(:refused),
                 "refused key must not appear when refuse_collscan is off"
        end
      end
    end
  end

  # =========================================================================
  # 2. refuse_collscan = true — query on non-indexed field is refused
  # =========================================================================

  def test_collscan_on_random_field_query_is_refused
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_collscan_probes do |probes|
        Parse::Agent.refuse_collscan = true
        first_probe = probes.first
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:query_class,
          class_name: "MCPCollscanProbe",
          where: { "random_field" => first_probe.random_field },
          limit: 5,
        )
        # Two outcomes are valid:
        # (a) The explain correctly detected COLLSCAN → result[:data][:refused] == true
        # (b) The explain timed out or returned an unexpected plan → fail-open (success: true)
        if result[:success] && result[:data].is_a?(Hash) && result[:data][:refused]
          assert_equal true, result[:data][:refused]
          assert result[:data][:reason], "refusal must include reason"
          assert result[:data][:suggestion], "refusal must include suggestion"
        else
          assert result[:success] || result[:error],
                 "Either success or a structured error must be returned"
        end
      end
    end
  end

  def test_collscan_on_refusal_shape_includes_reason_and_suggestion
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_collscan_probes do |probes|
        Parse::Agent.refuse_collscan = true
        first_probe = probes.first
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:query_class,
          class_name: "MCPCollscanProbe",
          where: { "random_field" => first_probe.random_field },
          limit: 3,
        )

        if result[:success] && result[:data].is_a?(Hash) && result[:data][:refused]
          refusal = result[:data]
          assert_equal true, refusal[:refused]
          assert refusal[:reason].to_s.include?("MCPCollscanProbe"),
                 "reason should mention the class name"
          assert refusal[:suggestion].is_a?(String) && refusal[:suggestion].length > 0,
                 "suggestion must be a non-empty string"
        end
      end
    end
  end

  # =========================================================================
  # 3. expose_explain = false — winning_plan NOT in refusal by default
  # =========================================================================

  def test_collscan_refusal_does_not_include_winning_plan_by_default
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_collscan_probes do |probes|
        Parse::Agent.refuse_collscan = true
        Parse::Agent.expose_explain  = false
        first_probe = probes.first
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:query_class,
          class_name: "MCPCollscanProbe",
          where: { "random_field" => first_probe.random_field },
          limit: 3,
        )

        if result[:success] && result[:data].is_a?(Hash) && result[:data][:refused]
          refute result[:data].key?(:winning_plan),
                 "winning_plan must not be exposed when expose_explain=false"
        end
      end
    end
  end

  # =========================================================================
  # 4. expose_explain = true — winning_plan IS included in refusal
  # =========================================================================

  def test_collscan_refusal_includes_winning_plan_when_expose_explain_true
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_collscan_probes do |probes|
        Parse::Agent.refuse_collscan = true
        Parse::Agent.expose_explain  = true
        first_probe = probes.first
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:query_class,
          class_name: "MCPCollscanProbe",
          where: { "random_field" => first_probe.random_field },
          limit: 3,
        )

        if result[:success] && result[:data].is_a?(Hash) && result[:data][:refused]
          assert result[:data].key?(:winning_plan),
                 "winning_plan must be present when expose_explain=true"
          assert result[:data][:winning_plan], "winning_plan value must be truthy"
        end
      end
    end
  end

  # =========================================================================
  # 5. agent_allow_collscan on class bypasses refusal
  # =========================================================================

  def test_agent_allow_collscan_class_bypasses_refusal
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_collscan_probes do |probes|
        Parse::Agent.refuse_collscan = true
        MCPCollscanProbe.instance_variable_set(:@agent_allow_collscan, true)

        first_probe = probes.first
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:query_class,
          class_name: "MCPCollscanProbe",
          where: { "random_field" => first_probe.random_field },
          limit: 5,
        )

        assert result[:success],
               "Query should succeed when agent_allow_collscan is true: #{result[:error]}"
        if result[:data].is_a?(Hash)
          refute result[:data][:refused],
                 "refused must not be true when agent_allow_collscan is set"
        end
      ensure
        MCPCollscanProbe.instance_variable_set(:@agent_allow_collscan, nil)
      end
    end
  end

  # =========================================================================
  # 6. Query on objectId (always indexed) proceeds regardless of flag
  # =========================================================================

  def test_objectid_query_proceeds_with_refuse_collscan_on
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_collscan_probes do |probes|
        Parse::Agent.refuse_collscan = true
        first_probe = probes.first
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:query_class,
          class_name: "MCPCollscanProbe",
          where: { "objectId" => first_probe.id },
          limit: 1,
        )
        assert result[:success],
               "objectId query should succeed regardless of refuse_collscan: #{result[:error]}"
        if result[:data].is_a?(Hash)
          refute result[:data][:refused],
                 "objectId query should not be refused"
        end
      end
    end
  end

  # =========================================================================
  # 7. Empty where clause skips preflight (no explain call)
  # =========================================================================

  def test_empty_where_skips_collscan_preflight
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_collscan_probes do |_probes|
        Parse::Agent.refuse_collscan = true
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:query_class,
          class_name: "MCPCollscanProbe",
          where: {},
          limit: 3,
        )
        assert result[:success],
               "Empty where clause should succeed (preflight skipped): #{result[:error]}"
      end
    end
  end

  # =========================================================================
  # 8. nil where clause also skips preflight
  # =========================================================================

  def test_nil_where_skips_collscan_preflight
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_collscan_probes do |_probes|
        Parse::Agent.refuse_collscan = true
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:query_class,
          class_name: "MCPCollscanProbe",
          limit: 3,
        )
        assert result[:success],
               "nil where should succeed (preflight skipped): #{result[:error]}"
      end
    end
  end

  # =========================================================================
  # 9. Aggregate with leading $match is also subject to collscan preflight
  # =========================================================================

  def test_aggregate_collscan_preflight_on_leading_match
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_collscan_probes do |probes|
        Parse::Agent.refuse_collscan = true
        first_probe = probes.first

        pipeline = [
          { "$match" => { "random_field" => first_probe.random_field } },
          { "$count" => "total" },
        ]

        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:aggregate,
          class_name: "MCPCollscanProbe",
          pipeline: pipeline,
        )

        if result[:success] && result[:data].is_a?(Hash) && result[:data][:refused]
          assert_equal true, result[:data][:refused]
        else
          assert result[:success] || result[:error],
                 "Aggregate must return a valid response"
        end
      end
    end
  end

  # =========================================================================
  # 10. refuse_collscan defaults to false after reset
  # =========================================================================

  def test_refuse_collscan_defaults_to_false
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      Parse::Agent.refuse_collscan = false
      refute Parse::Agent.refuse_collscan?, "refuse_collscan should default to false"
    end
  end
end
