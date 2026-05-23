# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for Parse::Installation channel management functionality
class InstallationChannelsTest < Minitest::Test

  # ==========================================================================
  # Test 1: Class methods exist
  # ==========================================================================
  def test_class_methods_exist
    puts "\n=== Testing Installation Class Methods Exist ==="

    assert_respond_to Parse::Installation, :all_channels
    assert_respond_to Parse::Installation, :subscribers_count
    assert_respond_to Parse::Installation, :subscribers

    puts "Class methods exist!"
  end

  # ==========================================================================
  # Test 2: Instance methods exist
  # ==========================================================================
  def test_instance_methods_exist
    puts "\n=== Testing Installation Instance Methods Exist ==="

    installation = Parse::Installation.new
    assert_respond_to installation, :subscribe
    assert_respond_to installation, :unsubscribe
    assert_respond_to installation, :subscribed_to?

    puts "Instance methods exist!"
  end

  # ==========================================================================
  # Test 3: subscribed_to? with no channels
  # ==========================================================================
  def test_subscribed_to_with_no_channels
    puts "\n=== Testing subscribed_to? with No Channels ==="

    installation = Parse::Installation.new
    refute installation.subscribed_to?("news")

    puts "subscribed_to? with no channels works correctly!"
  end

  # ==========================================================================
  # Test 4: subscribed_to? with channels set
  # ==========================================================================
  def test_subscribed_to_with_channels
    puts "\n=== Testing subscribed_to? with Channels ==="

    installation = Parse::Installation.new
    installation.channels = ["news", "sports"]

    assert installation.subscribed_to?("news")
    assert installation.subscribed_to?("sports")
    refute installation.subscribed_to?("weather")

    puts "subscribed_to? with channels works correctly!"
  end

  # ==========================================================================
  # Test 5: subscribed_to? converts to string
  # ==========================================================================
  def test_subscribed_to_converts_to_string
    puts "\n=== Testing subscribed_to? Converts to String ==="

    installation = Parse::Installation.new
    installation.channels = ["news"]

    # Should work with symbols too
    assert installation.subscribed_to?(:news)

    puts "subscribed_to? converts to string correctly!"
  end

  # ==========================================================================
  # Test 6: channels property
  # ==========================================================================
  def test_channels_property
    puts "\n=== Testing channels Property ==="

    installation = Parse::Installation.new
    # channels returns a CollectionProxy which is empty by default
    assert installation.channels.empty?

    installation.channels = ["test"]
    assert_includes installation.channels, "test"

    puts "channels property works correctly!"
  end

  # ==========================================================================
  # Test 7: Parse::Push.channels class method exists
  # ==========================================================================
  def test_push_channels_class_method_exists
    puts "\n=== Testing Parse::Push.channels Class Method Exists ==="

    assert_respond_to Parse::Push, :channels

    puts "Parse::Push.channels class method exists!"
  end

  # ==========================================================================
  # Test 8: subscribers returns a query
  # ==========================================================================
  def test_subscribers_returns_query
    puts "\n=== Testing subscribers Returns Query ==="

    result = Parse::Installation.subscribers("news")
    assert_instance_of Parse::Query, result

    puts "subscribers returns a query!"
  end

  # ==========================================================================
  # Test 9: subscribe modifies channels locally (before save)
  # ==========================================================================
  def test_subscribe_modifies_channels_locally
    puts "\n=== Testing subscribe Modifies Channels Locally ==="

    installation = Parse::Installation.new

    # Mock save to prevent actual API call
    saved = false
    installation.define_singleton_method(:save) do
      saved = true
      true
    end

    installation.subscribe("news", "sports")

    assert_includes installation.channels, "news"
    assert_includes installation.channels, "sports"
    assert saved, "save should have been called"

    puts "subscribe modifies channels locally!"
  end

  # ==========================================================================
  # Test 10: subscribe prevents duplicates
  # ==========================================================================
  def test_subscribe_prevents_duplicates
    puts "\n=== Testing subscribe Prevents Duplicates ==="

    installation = Parse::Installation.new
    installation.channels = ["news"]

    # Mock save
    installation.define_singleton_method(:save) { true }

    installation.subscribe("news", "sports")

    assert_equal 2, installation.channels.to_a.length
    assert_equal ["news", "sports"], installation.channels.to_a.sort

    puts "subscribe prevents duplicates!"
  end

  # ==========================================================================
  # Test 11: subscribe with array argument
  # ==========================================================================
  def test_subscribe_with_array
    puts "\n=== Testing subscribe with Array Argument ==="

    installation = Parse::Installation.new

    # Mock save
    installation.define_singleton_method(:save) { true }

    installation.subscribe(["news", "sports"])

    assert_includes installation.channels, "news"
    assert_includes installation.channels, "sports"

    puts "subscribe with array argument works correctly!"
  end

  # ==========================================================================
  # Test 12: unsubscribe removes channels
  # ==========================================================================
  def test_unsubscribe_removes_channels
    puts "\n=== Testing unsubscribe Removes Channels ==="

    installation = Parse::Installation.new
    installation.channels = ["news", "sports", "weather"]

    # Mock save
    installation.define_singleton_method(:save) { true }

    installation.unsubscribe("sports")

    assert_equal ["news", "weather"], installation.channels
    refute_includes installation.channels, "sports"

    puts "unsubscribe removes channels correctly!"
  end

  # ==========================================================================
  # Test 13: unsubscribe with no channels returns true
  # ==========================================================================
  def test_unsubscribe_with_no_channels
    puts "\n=== Testing unsubscribe with No Channels ==="

    installation = Parse::Installation.new
    # channels is nil

    result = installation.unsubscribe("news")

    assert result, "unsubscribe should return true when no channels exist"

    puts "unsubscribe with no channels returns true!"
  end

  # ==========================================================================
  # Test 14: unsubscribe multiple channels
  # ==========================================================================
  def test_unsubscribe_multiple_channels
    puts "\n=== Testing unsubscribe Multiple Channels ==="

    installation = Parse::Installation.new
    installation.channels = ["news", "sports", "weather", "tech"]

    # Mock save
    installation.define_singleton_method(:save) { true }

    installation.unsubscribe("sports", "tech")

    assert_equal ["news", "weather"], installation.channels

    puts "unsubscribe multiple channels works correctly!"
  end

  # ==========================================================================
  # Test 15: unsubscribe with array argument
  # ==========================================================================
  def test_unsubscribe_with_array
    puts "\n=== Testing unsubscribe with Array Argument ==="

    installation = Parse::Installation.new
    installation.channels = ["news", "sports", "weather"]

    # Mock save
    installation.define_singleton_method(:save) { true }

    installation.unsubscribe(["sports", "weather"])

    assert_equal ["news"], installation.channels

    puts "unsubscribe with array argument works correctly!"
  end

  # ==========================================================================
  # Test 16: subscribe converts to strings
  # ==========================================================================
  def test_subscribe_converts_to_strings
    puts "\n=== Testing subscribe Converts to Strings ==="

    installation = Parse::Installation.new

    # Mock save
    installation.define_singleton_method(:save) { true }

    installation.subscribe(:news, :sports)

    assert_includes installation.channels, "news"
    assert_includes installation.channels, "sports"
    # Should be strings, not symbols
    assert installation.channels.all? { |c| c.is_a?(String) }

    puts "subscribe converts to strings correctly!"
  end
end
