# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for Parse::Audience functionality
class AudienceTest < Minitest::Test
  def setup
    # Clear cache before each test
    Parse::Audience.clear_cache!
    # Override find_by_name_uncached to avoid network calls
    @original_method = Parse::Audience.method(:find_by_name_uncached)
    @fetch_return = nil
    @fetch_count = 0
    test_instance = self
    Parse::Audience.define_singleton_method(:find_by_name_uncached) do |name|
      test_instance.instance_variable_set(:@fetch_count, test_instance.instance_variable_get(:@fetch_count) + 1)
      test_instance.instance_variable_get(:@fetch_return)
    end
  end

  def teardown
    # Restore original method and clean up
    original = @original_method
    Parse::Audience.define_singleton_method(:find_by_name_uncached) do |name|
      original.call(name)
    end
    Parse::Audience.clear_cache!
  end

  # ==========================================================================
  # Cache Configuration Tests
  # ==========================================================================

  def test_default_cache_ttl
    assert_equal 300, Parse::Audience::DEFAULT_CACHE_TTL
    assert_equal 300, Parse::Audience.cache_ttl
  end

  def test_cache_ttl_can_be_configured
    original = Parse::Audience.cache_ttl
    Parse::Audience.cache_ttl = 600
    assert_equal 600, Parse::Audience.cache_ttl
  ensure
    Parse::Audience.cache_ttl = original
  end

  # ==========================================================================
  # Thread Safety Tests
  # ==========================================================================

  def test_cache_mutex_exists
    assert_respond_to Parse::Audience, :cache_mutex
    assert_kind_of Mutex, Parse::Audience.cache_mutex
  end

  def test_cache_mutex_is_same_instance
    mutex1 = Parse::Audience.cache_mutex
    mutex2 = Parse::Audience.cache_mutex
    assert_same mutex1, mutex2, "cache_mutex should return the same instance"
  end

  def test_clear_cache_is_thread_safe
    # This test verifies clear_cache! uses mutex synchronization
    # by checking it doesn't raise when called from multiple threads
    threads = 10.times.map do
      Thread.new do
        10.times { Parse::Audience.clear_cache! }
      end
    end

    # Should complete without deadlock or errors
    threads.each(&:join)
    assert true, "clear_cache! should be thread-safe"
  end

  def test_concurrent_cache_access_does_not_raise
    threads = 10.times.map do |i|
      Thread.new do
        10.times do |j|
          Parse::Audience.cache_fetch("test_audience_#{i}_#{j}", cache: true)
        end
      end
    end

    # Should complete without race conditions
    threads.each(&:join)
    assert true, "concurrent cache access should be thread-safe"
  end

  def test_cache_fetch_with_concurrent_writes
    @fetch_return = nil
    mutex = Mutex.new

    threads = 5.times.map do
      Thread.new do
        Parse::Audience.cache_fetch("same_audience", cache: true)
      end
    end

    threads.each(&:join)

    # Due to mutex synchronization, concurrent requests for the same key
    # may result in multiple fetches (acceptable) but should not corrupt cache
    assert @fetch_count >= 1, "should have made at least one fetch call"
  end

  # ==========================================================================
  # Cache Behavior Tests
  # ==========================================================================

  def test_cache_fetch_returns_nil_for_missing_audience
    @fetch_return = nil
    result = Parse::Audience.cache_fetch("nonexistent", cache: true)
    assert_nil result
  end

  def test_cache_fetch_bypasses_cache_when_disabled
    @fetch_return = nil
    @fetch_count = 0
    3.times { Parse::Audience.cache_fetch("test", cache: false) }
    assert_equal 3, @fetch_count, "should bypass cache and fetch each time"
  end

  def test_cache_fetch_uses_cache_when_enabled
    @fetch_return = nil
    @fetch_count = 0
    3.times { Parse::Audience.cache_fetch("test", cache: true) }
    assert_equal 1, @fetch_count, "should use cache after first fetch"
  end

  def test_cache_respects_ttl
    @fetch_return = nil
    @fetch_count = 0

    # Set very short TTL for testing
    original_ttl = Parse::Audience.cache_ttl
    Parse::Audience.cache_ttl = 0  # Immediate expiry

    Parse::Audience.cache_fetch("test", cache: true)
    sleep(0.01)  # Wait for cache to expire
    Parse::Audience.cache_fetch("test", cache: true)

    assert_equal 2, @fetch_count, "should refetch after TTL expires"
  ensure
    Parse::Audience.cache_ttl = original_ttl
  end

  # ==========================================================================
  # Model Property Tests
  # ==========================================================================

  def test_audience_has_name_property
    audience = Parse::Audience.new(name: "Test Audience")
    assert_equal "Test Audience", audience.name
  end

  def test_audience_has_query_property
    constraints = { "deviceType" => "ios" }
    audience = Parse::Audience.new(query: constraints)
    assert_equal constraints, audience.query
  end

  def test_query_constraint_alias
    constraints = { "deviceType" => "ios" }
    audience = Parse::Audience.new(query: constraints)
    assert_equal constraints, audience.query_constraint
  end

  def test_query_constraint_setter
    audience = Parse::Audience.new
    audience.query_constraint = { "vip" => true }
    assert_equal({ "vip" => true }, audience.query)
  end

  def test_parse_class_is_audience
    assert_equal "_Audience", Parse::Audience.parse_class
  end
end
