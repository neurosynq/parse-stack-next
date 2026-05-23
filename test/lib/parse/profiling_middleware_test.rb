# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/autorun"

class ProfilingMiddlewareTest < Minitest::Test
  def setup
    # Reset profiling state before each test
    Parse::Middleware::Profiling.enabled = false
    Parse::Middleware::Profiling.clear_profiles!
    Parse::Middleware::Profiling.clear_callbacks!
  end

  def teardown
    # Clean up after each test
    Parse::Middleware::Profiling.enabled = false
    Parse::Middleware::Profiling.clear_profiles!
    Parse::Middleware::Profiling.clear_callbacks!
  end

  def test_profiling_disabled_by_default
    refute Parse::Middleware::Profiling.enabled, "Profiling should be disabled by default"
    refute Parse.profiling_enabled, "Parse.profiling_enabled should be false by default"
  end

  def test_can_enable_profiling
    Parse.profiling_enabled = true
    assert Parse::Middleware::Profiling.enabled, "Profiling should be enabled"
    assert Parse.profiling_enabled, "Parse.profiling_enabled should be true"
  end

  def test_can_disable_profiling
    Parse.profiling_enabled = true
    Parse.profiling_enabled = false
    refute Parse::Middleware::Profiling.enabled, "Profiling should be disabled"
    refute Parse.profiling_enabled, "Parse.profiling_enabled should be false"
  end

  def test_profiles_array_exists
    profiles = Parse.recent_profiles
    assert profiles.is_a?(Array), "recent_profiles should return an array"
    assert profiles.empty?, "Profiles should be empty initially"
  end

  def test_clear_profiles
    # Add some test profiles
    Parse::Middleware::Profiling.add_profile({ method: "GET", url: "/test", duration_ms: 100 })
    Parse::Middleware::Profiling.add_profile({ method: "POST", url: "/test", duration_ms: 200 })

    assert_equal 2, Parse.recent_profiles.size, "Should have 2 profiles"

    Parse.clear_profiles!
    assert_equal 0, Parse.recent_profiles.size, "Profiles should be cleared"
  end

  def test_add_profile
    profile = {
      method: "GET",
      url: "http://localhost:1337/parse/classes/Test",
      status: 200,
      duration_ms: 50.5,
      started_at: Time.now.iso8601(3),
      completed_at: Time.now.iso8601(3),
      request_size: 100,
      response_size: 500,
    }

    Parse::Middleware::Profiling.add_profile(profile)

    assert_equal 1, Parse.recent_profiles.size
    assert_equal "GET", Parse.recent_profiles.first[:method]
    assert_equal 200, Parse.recent_profiles.first[:status]
    assert_equal 50.5, Parse.recent_profiles.first[:duration_ms]
  end

  def test_max_profiles_limit
    # Add more than MAX_PROFILES (100)
    110.times do |i|
      Parse::Middleware::Profiling.add_profile({
        method: "GET",
        url: "/test/#{i}",
        duration_ms: i,
      })
    end

    assert_equal 100, Parse.recent_profiles.size, "Should only keep MAX_PROFILES profiles"

    # The oldest should have been removed
    urls = Parse.recent_profiles.map { |p| p[:url] }
    refute urls.include?("/test/0"), "Oldest profile should be removed"
    assert urls.include?("/test/109"), "Newest profile should be present"
  end

  def test_statistics_empty
    stats = Parse.profiling_statistics
    assert stats.empty?, "Statistics should be empty when no profiles exist"
  end

  def test_statistics_with_profiles
    # Add some profiles
    Parse::Middleware::Profiling.add_profile({ method: "GET", url: "/test1", duration_ms: 100, status: 200 })
    Parse::Middleware::Profiling.add_profile({ method: "GET", url: "/test2", duration_ms: 200, status: 200 })
    Parse::Middleware::Profiling.add_profile({ method: "POST", url: "/test3", duration_ms: 300, status: 201 })

    stats = Parse.profiling_statistics

    assert_equal 3, stats[:count], "Count should be 3"
    assert_equal 600, stats[:total_ms], "Total should be 600ms"
    assert_equal 200.0, stats[:avg_ms], "Average should be 200ms"
    assert_equal 100, stats[:min_ms], "Min should be 100ms"
    assert_equal 300, stats[:max_ms], "Max should be 300ms"
    assert_equal({ "GET" => 2, "POST" => 1 }, stats[:by_method], "By method breakdown should match")
    assert_equal({ 200 => 2, 201 => 1 }, stats[:by_status], "By status breakdown should match")
  end

  def test_callback_registration
    callback_executed = false
    received_profile = nil

    Parse.on_request_complete do |profile|
      callback_executed = true
      received_profile = profile
    end

    profile = { method: "GET", url: "/test", duration_ms: 50 }
    Parse::Middleware::Profiling.add_profile(profile)

    assert callback_executed, "Callback should be executed"
    assert_equal profile, received_profile, "Callback should receive the profile"
  end

  def test_multiple_callbacks
    callback_count = 0

    3.times do
      Parse.on_request_complete do |_profile|
        callback_count += 1
      end
    end

    Parse::Middleware::Profiling.add_profile({ method: "GET", url: "/test", duration_ms: 50 })

    assert_equal 3, callback_count, "All callbacks should be executed"
  end

  def test_clear_callbacks
    callback_executed = false

    Parse.on_request_complete do |_profile|
      callback_executed = true
    end

    Parse.clear_profiling_callbacks!

    Parse::Middleware::Profiling.add_profile({ method: "GET", url: "/test", duration_ms: 50 })

    refute callback_executed, "Callback should not be executed after clearing"
  end

  def test_sanitize_url_master_key
    middleware = Parse::Middleware::Profiling.new(nil)

    url = "http://localhost:1337/parse/classes/Test?masterKey=secret123&other=value"
    sanitized = middleware.send(:sanitize_url, url)

    assert sanitized.include?("masterKey=[FILTERED]"), "masterKey should be filtered"
    assert sanitized.include?("other=value"), "Other params should remain"
    refute sanitized.include?("secret123"), "Master key value should not appear"
  end

  def test_sanitize_url_session_token
    middleware = Parse::Middleware::Profiling.new(nil)

    url = "http://localhost:1337/parse/classes/Test?sessionToken=r:abc123&limit=10"
    sanitized = middleware.send(:sanitize_url, url)

    assert sanitized.include?("sessionToken=[FILTERED]"), "sessionToken should be filtered"
    assert sanitized.include?("limit=10"), "Other params should remain"
    refute sanitized.include?("r:abc123"), "Session token value should not appear"
  end

  def test_sanitize_url_api_key
    middleware = Parse::Middleware::Profiling.new(nil)

    url = "http://localhost:1337/parse/classes/Test?apiKey=mykey123"
    sanitized = middleware.send(:sanitize_url, url)

    assert sanitized.include?("apiKey=[FILTERED]"), "apiKey should be filtered"
    refute sanitized.include?("mykey123"), "API key value should not appear"
  end
end
