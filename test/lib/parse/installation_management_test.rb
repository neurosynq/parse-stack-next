# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for Parse::Installation management functionality
class InstallationManagementTest < Minitest::Test

  # ==========================================================================
  # Device Type Scopes - Class Methods
  # ==========================================================================

  def test_ios_class_method_exists
    puts "\n=== Testing ios Class Method Exists ==="

    assert_respond_to Parse::Installation, :ios

    puts "ios class method exists!"
  end

  def test_android_class_method_exists
    puts "\n=== Testing android Class Method Exists ==="

    assert_respond_to Parse::Installation, :android

    puts "android class method exists!"
  end

  def test_by_device_type_class_method_exists
    puts "\n=== Testing by_device_type Class Method Exists ==="

    assert_respond_to Parse::Installation, :by_device_type

    puts "by_device_type class method exists!"
  end

  def test_ios_returns_query
    puts "\n=== Testing ios Returns Query ==="

    result = Parse::Installation.ios
    assert_instance_of Parse::Query, result

    puts "ios returns a Query!"
  end

  def test_android_returns_query
    puts "\n=== Testing android Returns Query ==="

    result = Parse::Installation.android
    assert_instance_of Parse::Query, result

    puts "android returns a Query!"
  end

  def test_by_device_type_returns_query
    puts "\n=== Testing by_device_type Returns Query ==="

    result = Parse::Installation.by_device_type(:winrt)
    assert_instance_of Parse::Query, result

    puts "by_device_type returns a Query!"
  end

  # ==========================================================================
  # Device Type Helpers - Instance Methods
  # ==========================================================================

  def test_ios_predicate_exists
    puts "\n=== Testing ios? Predicate Exists ==="

    installation = Parse::Installation.new
    assert_respond_to installation, :ios?

    puts "ios? predicate exists!"
  end

  def test_android_predicate_exists
    puts "\n=== Testing android? Predicate Exists ==="

    installation = Parse::Installation.new
    assert_respond_to installation, :android?

    puts "android? predicate exists!"
  end

  def test_ios_predicate_returns_true_for_ios
    puts "\n=== Testing ios? Returns True for iOS ==="

    installation = Parse::Installation.new
    installation.device_type = :ios

    assert installation.ios?
    refute installation.android?

    puts "ios? correctly returns true for iOS device!"
  end

  def test_android_predicate_returns_true_for_android
    puts "\n=== Testing android? Returns True for Android ==="

    installation = Parse::Installation.new
    installation.device_type = :android

    assert installation.android?
    refute installation.ios?

    puts "android? correctly returns true for Android device!"
  end

  # ==========================================================================
  # Badge Management - Class Methods
  # ==========================================================================

  def test_reset_badges_for_channel_exists
    puts "\n=== Testing reset_badges_for_channel Exists ==="

    assert_respond_to Parse::Installation, :reset_badges_for_channel

    puts "reset_badges_for_channel exists!"
  end

  def test_reset_all_badges_exists
    puts "\n=== Testing reset_all_badges Exists ==="

    assert_respond_to Parse::Installation, :reset_all_badges

    puts "reset_all_badges exists!"
  end

  # ==========================================================================
  # Badge Management - Instance Methods
  # ==========================================================================

  def test_reset_badge_instance_method_exists
    puts "\n=== Testing reset_badge! Instance Method Exists ==="

    installation = Parse::Installation.new
    assert_respond_to installation, :reset_badge!

    puts "reset_badge! instance method exists!"
  end

  def test_increment_badge_instance_method_exists
    puts "\n=== Testing increment_badge! Instance Method Exists ==="

    installation = Parse::Installation.new
    assert_respond_to installation, :increment_badge!

    puts "increment_badge! instance method exists!"
  end

  def test_reset_badge_sets_badge_to_zero
    puts "\n=== Testing reset_badge! Sets Badge to Zero ==="

    installation = Parse::Installation.new
    installation.badge = 5

    # Mock save to prevent actual API call
    installation.define_singleton_method(:save) { true }

    installation.reset_badge!
    assert_equal 0, installation.badge

    puts "reset_badge! correctly sets badge to 0!"
  end

  def test_increment_badge_increments_by_one
    puts "\n=== Testing increment_badge! Increments by One ==="

    installation = Parse::Installation.new
    installation.badge = 3

    # Mock save
    installation.define_singleton_method(:save) { true }

    installation.increment_badge!
    assert_equal 4, installation.badge

    puts "increment_badge! correctly increments by 1!"
  end

  def test_increment_badge_increments_by_amount
    puts "\n=== Testing increment_badge! Increments by Amount ==="

    installation = Parse::Installation.new
    installation.badge = 3

    # Mock save
    installation.define_singleton_method(:save) { true }

    installation.increment_badge!(5)
    assert_equal 8, installation.badge

    puts "increment_badge!(5) correctly increments by 5!"
  end

  def test_increment_badge_handles_nil_badge
    puts "\n=== Testing increment_badge! Handles nil Badge ==="

    installation = Parse::Installation.new
    # badge is nil by default

    # Mock save
    installation.define_singleton_method(:save) { true }

    installation.increment_badge!
    assert_equal 1, installation.badge

    puts "increment_badge! correctly handles nil badge!"
  end

  # ==========================================================================
  # Stale Token Detection - Class Methods
  # ==========================================================================

  def test_stale_tokens_class_method_exists
    puts "\n=== Testing stale_tokens Class Method Exists ==="

    assert_respond_to Parse::Installation, :stale_tokens

    puts "stale_tokens class method exists!"
  end

  def test_stale_count_class_method_exists
    puts "\n=== Testing stale_count Class Method Exists ==="

    assert_respond_to Parse::Installation, :stale_count

    puts "stale_count class method exists!"
  end

  def test_cleanup_stale_tokens_class_method_exists
    puts "\n=== Testing cleanup_stale_tokens! Class Method Exists ==="

    assert_respond_to Parse::Installation, :cleanup_stale_tokens!

    puts "cleanup_stale_tokens! class method exists!"
  end

  def test_stale_tokens_returns_query
    puts "\n=== Testing stale_tokens Returns Query ==="

    result = Parse::Installation.stale_tokens
    assert_instance_of Parse::Query, result

    puts "stale_tokens returns a Query!"
  end

  def test_stale_tokens_accepts_days_parameter
    puts "\n=== Testing stale_tokens Accepts days Parameter ==="

    result = Parse::Installation.stale_tokens(days: 30)
    assert_instance_of Parse::Query, result

    puts "stale_tokens accepts days parameter!"
  end

  # ==========================================================================
  # Stale Token Detection - Instance Methods
  # ==========================================================================

  def test_stale_predicate_exists
    puts "\n=== Testing stale? Predicate Exists ==="

    installation = Parse::Installation.new
    assert_respond_to installation, :stale?

    puts "stale? predicate exists!"
  end

  def test_days_since_update_exists
    puts "\n=== Testing days_since_update Exists ==="

    installation = Parse::Installation.new
    assert_respond_to installation, :days_since_update

    puts "days_since_update exists!"
  end

  def test_stale_with_nil_updated_at
    puts "\n=== Testing stale? with nil updated_at ==="

    installation = Parse::Installation.new
    # updated_at is nil

    refute installation.stale?

    puts "stale? with nil updated_at returns false!"
  end

  def test_stale_with_recent_update
    puts "\n=== Testing stale? with Recent Update ==="

    installation = Parse::Installation.new
    recent_time = Time.now - 86400  # 1 day ago
    installation.instance_variable_set(:@updated_at, recent_time)

    refute installation.stale?(days: 90)

    puts "stale? with recent update returns false!"
  end

  def test_stale_with_old_update
    puts "\n=== Testing stale? with Old Update ==="

    installation = Parse::Installation.new
    old_time = Time.now - (100 * 24 * 60 * 60)  # 100 days ago
    installation.instance_variable_set(:@updated_at, old_time)

    assert installation.stale?(days: 90)

    puts "stale? with old update returns true!"
  end

  def test_days_since_update_with_nil
    puts "\n=== Testing days_since_update with nil ==="

    installation = Parse::Installation.new

    assert_nil installation.days_since_update

    puts "days_since_update with nil returns nil!"
  end

  def test_days_since_update_calculation
    puts "\n=== Testing days_since_update Calculation ==="

    installation = Parse::Installation.new
    days_ago = 45
    past_time = Time.now - (days_ago * 24 * 60 * 60)
    installation.instance_variable_set(:@updated_at, past_time)

    result = installation.days_since_update
    # Allow for slight time drift
    assert result >= days_ago - 1 && result <= days_ago + 1

    puts "days_since_update correctly calculates days!"
  end
end
