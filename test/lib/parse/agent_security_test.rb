# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# ============================================================
# Pipeline Validator Tests
# ============================================================

class PipelineValidatorTest < Minitest::Test
  def test_validates_array_pipeline
    assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!("not an array")
    end
  end

  def test_rejects_empty_pipeline
    assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!([])
    end
  end

  def test_allows_match_stage
    assert Parse::Agent::PipelineValidator.validate!([{ "$match" => { "status" => "active" } }])
  end

  def test_allows_group_stage
    assert Parse::Agent::PipelineValidator.validate!([
      { "$group" => { "_id" => "$category", "count" => { "$sum" => 1 } } },
    ])
  end

  def test_allows_sort_stage
    assert Parse::Agent::PipelineValidator.validate!([{ "$sort" => { "createdAt" => -1 } }])
  end

  def test_allows_project_stage
    assert Parse::Agent::PipelineValidator.validate!([{ "$project" => { "title" => 1, "author" => 1 } }])
  end

  def test_allows_limit_stage
    assert Parse::Agent::PipelineValidator.validate!([{ "$limit" => 10 }])
  end

  def test_allows_skip_stage
    assert Parse::Agent::PipelineValidator.validate!([{ "$skip" => 20 }])
  end

  def test_allows_lookup_stage
    assert Parse::Agent::PipelineValidator.validate!([
      { "$lookup" => { "from" => "artists", "localField" => "artistId", "foreignField" => "_id", "as" => "artist" } },
    ])
  end

  def test_allows_unwind_stage
    assert Parse::Agent::PipelineValidator.validate!([{ "$unwind" => "$tags" }])
  end

  def test_allows_count_stage
    assert Parse::Agent::PipelineValidator.validate!([{ "$count" => "total" }])
  end

  def test_allows_facet_stage
    assert Parse::Agent::PipelineValidator.validate!([
      { "$facet" => { "byCategory" => [{ "$group" => { "_id" => "$category" } }] } },
    ])
  end

  # ============================================================
  # Blocked Stages Tests (Security Critical)
  # ============================================================

  def test_blocks_out_stage
    error = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!([{ "$out" => "hacked_collection" }])
    end
    assert_match(/SECURITY/, error.message)
    assert_match(/\$out/, error.message)
  end

  def test_blocks_merge_stage
    error = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!([{ "$merge" => { "into" => "target" } }])
    end
    assert_match(/SECURITY/, error.message)
    assert_match(/\$merge/, error.message)
  end

  def test_blocks_function_stage
    error = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!([
        { "$function" => { "body" => "function() { return 1; }", "args" => [], "lang" => "js" } },
      ])
    end
    assert_match(/SECURITY/, error.message)
    assert_match(/\$function/, error.message)
  end

  def test_blocks_accumulator_stage
    error = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!([
        { "$accumulator" => { "init" => "function() {}", "accumulate" => "function() {}" } },
      ])
    end
    assert_match(/SECURITY/, error.message)
    assert_match(/\$accumulator/, error.message)
  end

  # ============================================================
  # Nested Blocking Tests
  # ============================================================

  def test_blocks_out_nested_in_facet
    error = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!([
        { "$facet" => { "pipeline1" => [{ "$out" => "hacked" }] } },
      ])
    end
    assert_match(/nested/, error.message.downcase)
  end

  def test_blocks_function_deeply_nested
    error = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!([
        { "$facet" => {
          "a" => [{ "$match" => { "x" => { "$function" => { "body" => "evil" } } } }],
        } },
      ])
    end
    assert_match(/\$function/, error.message)
  end

  # ============================================================
  # Unknown Stage Tests
  # ============================================================

  def test_rejects_unknown_stage
    error = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!([{ "$unknownStage" => {} }])
    end
    assert_match(/Unknown/, error.message)
    assert_match(/\$unknownStage/, error.message)
  end

  # ============================================================
  # Depth Limit Tests
  # ============================================================

  def test_rejects_deeply_nested_pipeline
    # Build a deeply nested structure
    deep_value = { "value" => 1 }
    15.times { deep_value = { "nested" => deep_value } }

    error = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!([{ "$match" => deep_value }])
    end
    assert_match(/depth/, error.message.downcase)
  end

  # ============================================================
  # Stage Limit Tests
  # ============================================================

  def test_rejects_too_many_stages
    stages = 25.times.map { { "$match" => { "x" => 1 } } }
    error = assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
      Parse::Agent::PipelineValidator.validate!(stages)
    end
    assert_match(/stages/, error.message.downcase)
  end

  # ============================================================
  # Valid? Helper Tests
  # ============================================================

  def test_valid_returns_true_for_safe_pipeline
    assert Parse::Agent::PipelineValidator.valid?([{ "$match" => { "x" => 1 } }])
  end

  def test_valid_returns_false_for_blocked_pipeline
    refute Parse::Agent::PipelineValidator.valid?([{ "$out" => "x" }])
  end
end

# ============================================================
# Rate Limiter Tests
# ============================================================

class RateLimiterTest < Minitest::Test
  def test_allows_requests_under_limit
    limiter = Parse::Agent::RateLimiter.new(limit: 5, window: 60)
    3.times { limiter.check! }
    assert_equal 2, limiter.remaining
  end

  def test_raises_when_limit_exceeded
    limiter = Parse::Agent::RateLimiter.new(limit: 2, window: 60)
    2.times { limiter.check! }

    error = assert_raises(Parse::Agent::RateLimiter::RateLimitExceeded) do
      limiter.check!
    end
    assert error.retry_after > 0
    assert_equal 2, error.limit
    assert_equal 60, error.window
  end

  def test_remaining_count_accurate
    limiter = Parse::Agent::RateLimiter.new(limit: 10, window: 60)
    assert_equal 10, limiter.remaining

    3.times { limiter.check! }
    assert_equal 7, limiter.remaining
  end

  def test_retry_after_returns_nil_when_not_limited
    limiter = Parse::Agent::RateLimiter.new(limit: 5, window: 60)
    2.times { limiter.check! }
    assert_nil limiter.retry_after
  end

  def test_retry_after_returns_time_when_limited
    limiter = Parse::Agent::RateLimiter.new(limit: 2, window: 60)
    2.times { limiter.check! }

    retry_after = limiter.retry_after
    assert retry_after.is_a?(Float)
    assert retry_after > 0
    assert retry_after <= 60
  end

  def test_reset_clears_requests
    limiter = Parse::Agent::RateLimiter.new(limit: 5, window: 60)
    5.times { limiter.check! }
    assert_equal 0, limiter.remaining

    limiter.reset!
    assert_equal 5, limiter.remaining
  end

  def test_stats_returns_complete_info
    limiter = Parse::Agent::RateLimiter.new(limit: 10, window: 60)
    3.times { limiter.check! }

    stats = limiter.stats
    assert_equal 10, stats[:limit]
    assert_equal 60, stats[:window]
    assert_equal 3, stats[:used]
    assert_equal 7, stats[:remaining]
    assert_nil stats[:retry_after]
  end

  def test_available_returns_true_under_limit
    limiter = Parse::Agent::RateLimiter.new(limit: 5, window: 60)
    3.times { limiter.check! }
    assert limiter.available?
  end

  def test_available_returns_false_at_limit
    limiter = Parse::Agent::RateLimiter.new(limit: 2, window: 60)
    2.times { limiter.check! }
    refute limiter.available?
  end

  def test_thread_safety
    limiter = Parse::Agent::RateLimiter.new(limit: 100, window: 60)
    threads = 10.times.map do
      Thread.new do
        10.times { limiter.check! rescue nil }
      end
    end
    threads.each(&:join)

    # All 100 requests should have been recorded
    assert_equal 0, limiter.remaining
  end
end

# ============================================================
# Constraint Translator Security Tests
# ============================================================

class ConstraintTranslatorSecurityTest < Minitest::Test
  # ============================================================
  # Blocked Operators Tests (Security Critical)
  # ============================================================

  def test_blocks_where_operator
    error = assert_raises(Parse::Agent::ConstraintTranslator::ConstraintSecurityError) do
      Parse::Agent::ConstraintTranslator.translate({ "$where" => "this.a > 1" })
    end
    assert_match(/SECURITY/, error.message)
    assert_match(/\$where/, error.message)
    assert_equal "$where", error.operator
    assert_equal :code_execution, error.reason
  end

  def test_blocks_function_operator
    error = assert_raises(Parse::Agent::ConstraintTranslator::ConstraintSecurityError) do
      Parse::Agent::ConstraintTranslator.translate({
        "field" => { "$function" => { "body" => "function() {}", "args" => [] } },
      })
    end
    assert_match(/\$function/, error.message)
  end

  def test_blocks_accumulator_operator
    error = assert_raises(Parse::Agent::ConstraintTranslator::ConstraintSecurityError) do
      Parse::Agent::ConstraintTranslator.translate({
        "field" => { "$accumulator" => { "init" => "function() {}" } },
      })
    end
    assert_match(/\$accumulator/, error.message)
  end

  def test_blocks_expr_operator
    error = assert_raises(Parse::Agent::ConstraintTranslator::ConstraintSecurityError) do
      Parse::Agent::ConstraintTranslator.translate({
        "field" => { "$expr" => { "$gt" => ["$a", "$b"] } },
      })
    end
    assert_match(/\$expr/, error.message)
  end

  # ============================================================
  # Unknown Operator Tests
  # ============================================================

  def test_rejects_unknown_operator
    error = assert_raises(Parse::Agent::ConstraintTranslator::InvalidOperatorError) do
      Parse::Agent::ConstraintTranslator.translate({ "field" => { "$badOp" => 1 } })
    end
    assert_match(/Unknown/, error.message)
    assert_match(/\$badOp/, error.message)
    assert_equal "$badOp", error.operator
  end

  def test_rejects_unknown_nested_operator
    error = assert_raises(Parse::Agent::ConstraintTranslator::InvalidOperatorError) do
      Parse::Agent::ConstraintTranslator.translate({
        "$and" => [
          { "a" => 1 },
          { "b" => { "$unknownOp" => 2 } },
        ],
      })
    end
    assert_match(/\$unknownOp/, error.message)
  end

  # ============================================================
  # Allowed Operators Tests
  # ============================================================

  def test_allows_comparison_operators
    result = Parse::Agent::ConstraintTranslator.translate({
      "a" => { "$lt" => 10 },
      "b" => { "$lte" => 20 },
      "c" => { "$gt" => 5 },
      "d" => { "$gte" => 15 },
      "e" => { "$ne" => 0 },
      "f" => { "$eq" => 1 },
    })
    assert result.is_a?(Hash)
    assert_equal 10, result["a"]["$lt"]
  end

  def test_allows_array_operators
    result = Parse::Agent::ConstraintTranslator.translate({
      "tags" => { "$in" => ["a", "b"] },
      "ids" => { "$nin" => [1, 2] },
      "items" => { "$all" => ["x", "y"] },
    })
    assert result.is_a?(Hash)
    assert_equal ["a", "b"], result["tags"]["$in"]
  end

  def test_allows_existence_operator
    result = Parse::Agent::ConstraintTranslator.translate({
      "field" => { "$exists" => true },
    })
    assert_equal true, result["field"]["$exists"]
  end

  def test_allows_regex_operator
    result = Parse::Agent::ConstraintTranslator.translate({
      "name" => { "$regex" => "^John", "$options" => "i" },
    })
    assert_equal "^John", result["name"]["$regex"]
  end

  def test_allows_logical_operators
    result = Parse::Agent::ConstraintTranslator.translate({
      "$or" => [{ "a" => 1 }, { "b" => 2 }],
      "$and" => [{ "c" => 3 }, { "d" => 4 }],
    })
    assert result.key?("$or")
    assert result.key?("$and")
  end

  def test_allows_geo_operators
    result = Parse::Agent::ConstraintTranslator.translate({
      "location" => { "$near" => { "__type" => "GeoPoint", "latitude" => 40.0, "longitude" => -74.0 } },
    })
    assert result["location"].key?("$near")
  end

  # ============================================================
  # Depth Limit Tests
  # ============================================================

  def test_rejects_deeply_nested_constraints
    # Build a deeply nested structure
    deep_value = { "$eq" => 1 }
    12.times { deep_value = { "nested" => deep_value } }

    error = assert_raises(Parse::Agent::ConstraintTranslator::InvalidOperatorError) do
      Parse::Agent::ConstraintTranslator.translate({ "field" => deep_value })
    end
    assert_match(/depth/, error.message.downcase)
  end

  # ============================================================
  # Valid? Helper Tests
  # ============================================================

  def test_valid_returns_true_for_safe_constraints
    assert Parse::Agent::ConstraintTranslator.valid?({ "name" => { "$eq" => "John" } })
  end

  def test_valid_returns_false_for_blocked_constraints
    refute Parse::Agent::ConstraintTranslator.valid?({ "$where" => "this.a > 1" })
  end

  def test_valid_returns_false_for_unknown_operators
    refute Parse::Agent::ConstraintTranslator.valid?({ "x" => { "$badOp" => 1 } })
  end
end

# ============================================================
# Agent Rate Limiting Integration Tests
# ============================================================

class AgentRateLimitingTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
  end

  def test_agent_has_rate_limiter
    agent = Parse::Agent.new
    assert agent.rate_limiter.is_a?(Parse::Agent::RateLimiter)
  end

  def test_agent_custom_rate_limit
    agent = Parse::Agent.new(rate_limit: 100, rate_window: 30)
    stats = agent.rate_limiter.stats
    assert_equal 100, stats[:limit]
    assert_equal 30, stats[:window]
  end

  def test_agent_default_rate_limit
    agent = Parse::Agent.new
    stats = agent.rate_limiter.stats
    assert_equal 60, stats[:limit]
    assert_equal 60, stats[:window]
  end
end
