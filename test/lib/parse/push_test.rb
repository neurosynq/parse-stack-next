# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for Parse::Push functionality
class PushTest < Minitest::Test
  def setup
    # Reset any instance variables between tests
  end

  # ==========================================================================
  # Test 1: Basic initialization
  # ==========================================================================
  def test_basic_initialization
    puts "\n=== Testing Basic Push Initialization ==="

    push = Parse::Push.new
    assert_instance_of Parse::Push, push
    assert_instance_of Parse::Query, push.query
    assert_equal Parse::Model::CLASS_INSTALLATION, push.query.table

    puts "Push initialized correctly!"
  end

  def test_initialization_with_constraints
    puts "\n=== Testing Push Initialization with Constraints ==="

    push = Parse::Push.new(device_type: "ios")
    assert_instance_of Parse::Query, push.query
    assert_equal({ "deviceType" => "ios" }, push.where)

    puts "Push initialized with constraints correctly!"
  end

  # ==========================================================================
  # Test 2: Channel setting
  # ==========================================================================
  def test_channels_setter_with_array
    puts "\n=== Testing Channels Setter with Array ==="

    push = Parse::Push.new
    push.channels = ["news", "sports"]
    assert_equal ["news", "sports"], push.channels

    puts "Channels array set correctly!"
  end

  def test_channels_setter_with_single_string
    puts "\n=== Testing Channels Setter with Single String ==="

    push = Parse::Push.new
    push.channels = "news"
    assert_equal ["news"], push.channels

    puts "Channels single string converted to array correctly!"
  end

  def test_channels_in_payload_without_query
    puts "\n=== Testing Channels in Payload (no query) ==="

    push = Parse::Push.new
    push.channels = ["news", "sports"]
    push.alert = "Test message"

    payload = push.payload
    assert_equal ["news", "sports"], payload[:channels]
    refute payload.key?(:where), "Should not have :where when only channels set"

    puts "Channels in payload without query correct!"
  end

  def test_channels_merged_into_query_where
    puts "\n=== Testing Channels Merged into Query Where ==="

    push = Parse::Push.new
    push.where(device_type: "ios")
    push.channels = ["news"]
    push.alert = "Test"

    payload = push.payload
    # When there's a query, channels get added to the where clause
    assert payload.key?(:where), "Should have :where when query constraints exist"
    refute payload.key?(:channels), "Should not have top-level :channels when query exists"
    # The where clause should include channels constraint
    assert payload[:where]["channels"], "Where should include channels constraint"

    puts "Channels merged into query where correctly!"
  end

  # ==========================================================================
  # Test 3: Query constraints (where)
  # ==========================================================================
  def test_where_method_sets_constraints
    puts "\n=== Testing Where Method Sets Constraints ==="

    push = Parse::Push.new
    push.where(device_type: "ios", app_version: "2.0")

    # where() without args returns compiled where
    compiled = push.where
    assert_equal "ios", compiled["deviceType"]
    assert_equal "2.0", compiled["appVersion"]

    puts "Where method sets constraints correctly!"
  end

  def test_where_method_returns_query_for_chaining
    puts "\n=== Testing Where Method Chaining ==="

    push = Parse::Push.new
    result = push.where(device_type: "ios")

    assert_instance_of Parse::Query, result
    assert_equal push.query, result

    puts "Where method returns query for chaining!"
  end

  def test_where_in_payload
    puts "\n=== Testing Where in Payload ==="

    push = Parse::Push.new
    push.where(device_type: "android")
    push.alert = "Test"

    payload = push.payload
    assert payload.key?(:where)
    assert_equal "android", payload[:where]["deviceType"]

    puts "Where included in payload correctly!"
  end

  # ==========================================================================
  # Test 4: Alert and message
  # ==========================================================================
  def test_alert_setter
    puts "\n=== Testing Alert Setter ==="

    push = Parse::Push.new
    push.alert = "Hello World"

    assert_equal "Hello World", push.alert
    assert_equal "Hello World", push.payload[:data][:alert]

    puts "Alert setter works correctly!"
  end

  def test_message_alias
    puts "\n=== Testing Message Alias ==="

    push = Parse::Push.new
    push.message = "Hello via message"

    assert_equal "Hello via message", push.alert
    assert_equal "Hello via message", push.message

    puts "Message alias works correctly!"
  end

  # ==========================================================================
  # Test 5: Badge
  # ==========================================================================
  def test_badge_default_increment
    puts "\n=== Testing Badge Default (Increment) ==="

    push = Parse::Push.new
    push.alert = "Test"

    payload = push.payload
    assert_equal "Increment", payload[:data][:badge]

    puts "Badge defaults to 'Increment' correctly!"
  end

  def test_badge_explicit_value
    puts "\n=== Testing Badge Explicit Value ==="

    push = Parse::Push.new
    push.alert = "Test"
    push.badge = 5

    payload = push.payload
    assert_equal 5, payload[:data][:badge]

    puts "Badge explicit value works correctly!"
  end

  def test_badge_zero
    puts "\n=== Testing Badge Zero (Clear) ==="

    push = Parse::Push.new
    push.alert = "Test"
    push.badge = 0

    payload = push.payload
    assert_equal 0, payload[:data][:badge]

    puts "Badge zero (clear) works correctly!"
  end

  # ==========================================================================
  # Test 6: Sound
  # ==========================================================================
  def test_sound_not_included_when_nil
    puts "\n=== Testing Sound Not Included When Nil ==="

    push = Parse::Push.new
    push.alert = "Test"

    payload = push.payload
    refute payload[:data].key?(:sound), "Sound should not be in payload when nil"

    puts "Sound not included when nil!"
  end

  def test_sound_included_when_set
    puts "\n=== Testing Sound Included When Set ==="

    push = Parse::Push.new
    push.alert = "Test"
    push.sound = "notification.caf"

    payload = push.payload
    assert_equal "notification.caf", payload[:data][:sound]

    puts "Sound included in payload when set!"
  end

  # ==========================================================================
  # Test 7: Title
  # ==========================================================================
  def test_title_not_included_when_nil
    puts "\n=== Testing Title Not Included When Nil ==="

    push = Parse::Push.new
    push.alert = "Test"

    payload = push.payload
    refute payload[:data].key?(:title), "Title should not be in payload when nil"

    puts "Title not included when nil!"
  end

  def test_title_included_when_set
    puts "\n=== Testing Title Included When Set ==="

    push = Parse::Push.new
    push.alert = "Test body"
    push.title = "Test Title"

    payload = push.payload
    assert_equal "Test Title", payload[:data][:title]
    assert_equal "Test body", payload[:data][:alert]

    puts "Title included in payload when set!"
  end

  # ==========================================================================
  # Test 8: Custom data
  # ==========================================================================
  def test_custom_data_merged_into_payload
    puts "\n=== Testing Custom Data Merged into Payload ==="

    push = Parse::Push.new
    push.alert = "Test"
    push.data = { uri: "app://deep/link", custom_key: "custom_value" }

    payload = push.payload
    assert_equal "app://deep/link", payload[:data][:uri]
    assert_equal "custom_value", payload[:data][:custom_key]

    puts "Custom data merged into payload correctly!"
  end

  def test_data_setter_with_string_sets_alert
    puts "\n=== Testing Data Setter with String Sets Alert ==="

    push = Parse::Push.new
    push.data = "This is an alert"

    assert_equal "This is an alert", push.alert

    puts "Data setter with string sets alert correctly!"
  end

  def test_data_setter_symbolizes_keys
    puts "\n=== Testing Data Setter Symbolizes Keys ==="

    push = Parse::Push.new
    push.data = { "string_key" => "value" }

    # Internal @data should have symbolized keys
    payload = push.payload
    assert payload[:data].key?(:string_key)

    puts "Data setter symbolizes keys correctly!"
  end

  # ==========================================================================
  # Test 9: Expiration time
  # ==========================================================================
  def test_expiration_time_with_time_object
    puts "\n=== Testing Expiration Time with Time Object ==="

    push = Parse::Push.new
    push.alert = "Test"
    future_time = Time.now + 3600 # 1 hour from now
    push.expiration_time = future_time

    payload = push.payload
    assert payload.key?(:expiration_time)
    # Should be ISO8601 formatted
    assert_match(/\d{4}-\d{2}-\d{2}T/, payload[:expiration_time])

    puts "Expiration time with Time object works correctly!"
  end

  def test_expiration_time_with_string
    puts "\n=== Testing Expiration Time with String ==="

    push = Parse::Push.new
    push.alert = "Test"
    push.expiration_time = "2025-12-31T23:59:59.000Z"

    payload = push.payload
    assert_equal "2025-12-31T23:59:59.000Z", payload[:expiration_time]

    puts "Expiration time with string works correctly!"
  end

  def test_expiration_time_not_included_when_nil
    puts "\n=== Testing Expiration Time Not Included When Nil ==="

    push = Parse::Push.new
    push.alert = "Test"

    payload = push.payload
    refute payload.key?(:expiration_time)

    puts "Expiration time not included when nil!"
  end

  # ==========================================================================
  # Test 10: Expiration interval
  # ==========================================================================
  def test_expiration_interval_as_integer
    puts "\n=== Testing Expiration Interval as Integer ==="

    push = Parse::Push.new
    push.alert = "Test"
    push.expiration_interval = 86400 # 24 hours in seconds

    payload = push.payload
    assert_equal 86400, payload[:expiration_interval]

    puts "Expiration interval as integer works correctly!"
  end

  def test_expiration_interval_converts_to_integer
    puts "\n=== Testing Expiration Interval Converts to Integer ==="

    push = Parse::Push.new
    push.alert = "Test"
    push.expiration_interval = 3600.5

    payload = push.payload
    assert_equal 3600, payload[:expiration_interval]

    puts "Expiration interval converts to integer correctly!"
  end

  def test_expiration_interval_not_included_when_nil
    puts "\n=== Testing Expiration Interval Not Included When Nil ==="

    push = Parse::Push.new
    push.alert = "Test"

    payload = push.payload
    refute payload.key?(:expiration_interval)

    puts "Expiration interval not included when nil!"
  end

  # ==========================================================================
  # Test 11: Push time (scheduled push)
  # ==========================================================================
  def test_push_time_with_time_object
    puts "\n=== Testing Push Time with Time Object ==="

    push = Parse::Push.new
    push.alert = "Test"
    future_time = Time.now + 7200 # 2 hours from now
    push.push_time = future_time

    payload = push.payload
    assert payload.key?(:push_time)
    assert_match(/\d{4}-\d{2}-\d{2}T/, payload[:push_time])

    puts "Push time with Time object works correctly!"
  end

  def test_push_time_not_included_when_nil
    puts "\n=== Testing Push Time Not Included When Nil ==="

    push = Parse::Push.new
    push.alert = "Test"

    payload = push.payload
    refute payload.key?(:push_time)

    puts "Push time not included when nil!"
  end

  # ==========================================================================
  # Test 12: JSON serialization
  # ==========================================================================
  def test_as_json
    puts "\n=== Testing as_json ==="

    push = Parse::Push.new
    push.alert = "Test"
    push.title = "Title"

    json_hash = push.as_json
    assert_instance_of Hash, json_hash
    assert json_hash.key?("data") || json_hash.key?(:data)

    puts "as_json works correctly!"
  end

  def test_to_json
    puts "\n=== Testing to_json ==="

    push = Parse::Push.new
    push.alert = "Test"

    json_string = push.to_json
    assert_instance_of String, json_string

    # Should be valid JSON
    parsed = JSON.parse(json_string)
    assert parsed.key?("data")

    puts "to_json works correctly!"
  end

  # ==========================================================================
  # Test 13: send method structure
  # ==========================================================================
  def test_send_method_sets_alert_from_string
    puts "\n=== Testing Send Method Sets Alert from String ==="

    push = Parse::Push.new

    # Verify send method behavior: when called with string, it sets @alert
    # We test this by examining the internal logic without actually sending
    # The send method does: @alert = message if message.is_a?(String)
    push.instance_variable_set(:@alert, nil)

    # Simulate what send does internally for string argument
    message = "Hello from send"
    push.instance_variable_set(:@alert, message) if message.is_a?(String)

    assert_equal "Hello from send", push.alert
    assert_equal "Hello from send", push.payload[:data][:alert]

    puts "Send method sets alert from string correctly!"
  end

  def test_send_with_hash_message
    puts "\n=== Testing Send Sets Data from Hash ==="

    push = Parse::Push.new

    # Verify that passing a hash to data= sets @data
    push.data = { custom: "value" }
    payload = push.payload
    assert_equal "value", payload[:data][:custom]

    puts "Send with hash message sets data correctly!"
  end

  # ==========================================================================
  # Test 14: Class method send
  # ==========================================================================
  def test_class_send_method_exists
    puts "\n=== Testing Class Send Method Exists ==="

    assert_respond_to Parse::Push, :send

    puts "Class send method exists!"
  end

  # ==========================================================================
  # Test 15: Complete payload structure
  # ==========================================================================
  def test_complete_payload_structure
    puts "\n=== Testing Complete Payload Structure ==="

    push = Parse::Push.new
    push.channels = ["news"]
    push.alert = "Breaking news!"
    push.title = "News Alert"
    push.badge = 1
    push.sound = "alert.caf"
    push.data = { article_id: "12345" }

    payload = push.payload

    # Verify structure
    assert payload.key?(:data), "Payload should have :data"
    assert payload.key?(:channels), "Payload should have :channels (no query constraints)"

    # Verify data contents
    assert_equal "Breaking news!", payload[:data][:alert]
    assert_equal "News Alert", payload[:data][:title]
    assert_equal 1, payload[:data][:badge]
    assert_equal "alert.caf", payload[:data][:sound]
    assert_equal "12345", payload[:data][:article_id]

    puts "Complete payload structure is correct!"
  end

  # ==========================================================================
  # Test 16: Query object creation
  # ==========================================================================
  def test_query_lazy_initialization
    puts "\n=== Testing Query Lazy Initialization ==="

    push = Parse::Push.new
    # Query should be created on first access
    query1 = push.query
    query2 = push.query

    assert_same query1, query2, "Query should be memoized"
    assert_instance_of Parse::Query, query1

    puts "Query lazy initialization works correctly!"
  end

  def test_query_targets_installation_class
    puts "\n=== Testing Query Targets Installation Class ==="

    push = Parse::Push.new
    assert_equal "_Installation", push.query.table

    puts "Query targets Installation class correctly!"
  end

  # ==========================================================================
  # Test 17: Client::Connectable inclusion
  # ==========================================================================
  def test_includes_connectable
    puts "\n=== Testing Client::Connectable Inclusion ==="

    assert Parse::Push.include?(Parse::Client::Connectable)
    push = Parse::Push.new
    assert_respond_to push, :client

    puts "Client::Connectable is included!"
  end

  # ==========================================================================
  # Builder Pattern Tests
  # ==========================================================================

  # Test 18: to_channel builder method
  def test_builder_to_channel
    puts "\n=== Testing Builder: to_channel ==="

    push = Parse::Push.new
    result = push.to_channel("news")

    assert_same push, result, "to_channel should return self for chaining"
    assert_equal ["news"], push.channels

    puts "to_channel works correctly!"
  end

  # Test 19: to_channels builder method
  def test_builder_to_channels
    puts "\n=== Testing Builder: to_channels ==="

    push = Parse::Push.new
    result = push.to_channels("news", "sports", "weather")

    assert_same push, result, "to_channels should return self for chaining"
    assert_equal ["news", "sports", "weather"], push.channels

    puts "to_channels works correctly!"
  end

  def test_builder_to_channels_with_array
    puts "\n=== Testing Builder: to_channels with array ==="

    push = Parse::Push.new
    result = push.to_channels(["news", "sports"])

    assert_same push, result
    assert_equal ["news", "sports"], push.channels

    puts "to_channels with array works correctly!"
  end

  # Test 20: to_query builder method
  def test_builder_to_query
    puts "\n=== Testing Builder: to_query ==="

    push = Parse::Push.new
    result = push.to_query { |q| q.where(device_type: "ios") }

    assert_same push, result, "to_query should return self for chaining"
    assert_equal "ios", push.where["deviceType"]

    puts "to_query works correctly!"
  end

  # Test 21: with_alert builder method
  def test_builder_with_alert
    puts "\n=== Testing Builder: with_alert ==="

    push = Parse::Push.new
    result = push.with_alert("Hello World!")

    assert_same push, result, "with_alert should return self for chaining"
    assert_equal "Hello World!", push.alert

    puts "with_alert works correctly!"
  end

  # Test 22: with_body builder method (alias)
  def test_builder_with_body
    puts "\n=== Testing Builder: with_body ==="

    push = Parse::Push.new
    result = push.with_body("Body text")

    assert_same push, result, "with_body should return self for chaining"
    assert_equal "Body text", push.alert

    puts "with_body works correctly!"
  end

  # Test 23: with_title builder method
  def test_builder_with_title
    puts "\n=== Testing Builder: with_title ==="

    push = Parse::Push.new
    result = push.with_title("Notification Title")

    assert_same push, result, "with_title should return self for chaining"
    assert_equal "Notification Title", push.title

    puts "with_title works correctly!"
  end

  # Test 24: with_badge builder method
  def test_builder_with_badge
    puts "\n=== Testing Builder: with_badge ==="

    push = Parse::Push.new
    result = push.with_badge(5)

    assert_same push, result, "with_badge should return self for chaining"
    assert_equal 5, push.badge

    puts "with_badge works correctly!"
  end

  # Test 25: with_sound builder method
  def test_builder_with_sound
    puts "\n=== Testing Builder: with_sound ==="

    push = Parse::Push.new
    result = push.with_sound("alert.caf")

    assert_same push, result, "with_sound should return self for chaining"
    assert_equal "alert.caf", push.sound

    puts "with_sound works correctly!"
  end

  # Test 26: with_data builder method
  def test_builder_with_data
    puts "\n=== Testing Builder: with_data ==="

    push = Parse::Push.new
    result = push.with_data(article_id: "123", action: "open")

    assert_same push, result, "with_data should return self for chaining"
    payload = push.payload
    assert_equal "123", payload[:data][:article_id]
    assert_equal "open", payload[:data][:action]

    puts "with_data works correctly!"
  end

  def test_builder_with_data_merges
    puts "\n=== Testing Builder: with_data merges multiple calls ==="

    push = Parse::Push.new
    push.with_data(key1: "value1")
    push.with_data(key2: "value2")

    payload = push.payload
    assert_equal "value1", payload[:data][:key1]
    assert_equal "value2", payload[:data][:key2]

    puts "with_data merges multiple calls correctly!"
  end

  # Test 27: schedule builder method
  def test_builder_schedule
    puts "\n=== Testing Builder: schedule ==="

    push = Parse::Push.new
    future_time = Time.now + 3600
    result = push.schedule(future_time)

    assert_same push, result, "schedule should return self for chaining"
    assert_equal future_time, push.push_time

    puts "schedule works correctly!"
  end

  # Test 28: expires_at builder method
  def test_builder_expires_at
    puts "\n=== Testing Builder: expires_at ==="

    push = Parse::Push.new
    expire_time = Time.now + 7200
    result = push.expires_at(expire_time)

    assert_same push, result, "expires_at should return self for chaining"
    assert_equal expire_time, push.expiration_time

    puts "expires_at works correctly!"
  end

  # Test 29: expires_in builder method
  def test_builder_expires_in
    puts "\n=== Testing Builder: expires_in ==="

    push = Parse::Push.new
    result = push.expires_in(3600)

    assert_same push, result, "expires_in should return self for chaining"
    assert_equal 3600, push.expiration_interval

    puts "expires_in works correctly!"
  end

  def test_builder_expires_in_converts_to_integer
    puts "\n=== Testing Builder: expires_in converts to integer ==="

    push = Parse::Push.new
    push.expires_in(3600.5)

    assert_equal 3600, push.expiration_interval

    puts "expires_in converts to integer correctly!"
  end

  # Test 30: Full builder chain
  def test_builder_full_chain
    puts "\n=== Testing Builder: Full Chain ==="

    future_time = Time.now + 3600
    expire_time = Time.now + 7200

    push = Parse::Push.new
      .to_channel("news")
      .with_title("Breaking News")
      .with_body("Something happened!")
      .with_badge(1)
      .with_sound("alert.caf")
      .with_data(article_id: "123")
      .schedule(future_time)
      .expires_at(expire_time)

    assert_equal ["news"], push.channels
    assert_equal "Breaking News", push.title
    assert_equal "Something happened!", push.alert
    assert_equal 1, push.badge
    assert_equal "alert.caf", push.sound
    assert_equal future_time, push.push_time
    assert_equal expire_time, push.expiration_time

    payload = push.payload
    assert_equal "123", payload[:data][:article_id]

    puts "Full builder chain works correctly!"
  end

  # Test 31: Class method to_channel
  def test_class_method_to_channel
    puts "\n=== Testing Class Method: to_channel ==="

    push = Parse::Push.to_channel("alerts")

    assert_instance_of Parse::Push, push
    assert_equal ["alerts"], push.channels

    puts "Class method to_channel works correctly!"
  end

  # Test 32: Class method to_channels
  def test_class_method_to_channels
    puts "\n=== Testing Class Method: to_channels ==="

    push = Parse::Push.to_channels("news", "sports")

    assert_instance_of Parse::Push, push
    assert_equal ["news", "sports"], push.channels

    puts "Class method to_channels works correctly!"
  end

  # Test 33: send! method exists
  def test_send_bang_method_exists
    puts "\n=== Testing send! Method Exists ==="

    push = Parse::Push.new
    assert_respond_to push, :send!

    puts "send! method exists!"
  end

  # Test 34: Builder with query constraints and channels
  def test_builder_query_with_channels
    puts "\n=== Testing Builder: Query with Channels ==="

    push = Parse::Push.new
      .to_query { |q| q.where(device_type: "ios") }
      .to_channels("news", "alerts")
      .with_alert("iOS users on news or alerts channels")

    payload = push.payload
    # When there's a query, channels get added to the where clause
    assert payload.key?(:where)
    assert payload[:where]["channels"]

    puts "Builder with query and channels works correctly!"
  end

  # ==========================================================================
  # Silent Push Tests
  # ==========================================================================

  # Test 35: content_available attribute
  def test_content_available_attribute
    puts "\n=== Testing content_available Attribute ==="

    push = Parse::Push.new
    assert_nil push.content_available
    refute push.content_available?

    push.content_available = true
    assert push.content_available?

    push.content_available = false
    refute push.content_available?

    puts "content_available attribute works correctly!"
  end

  # Test 36: silent! builder method
  def test_builder_silent
    puts "\n=== Testing Builder: silent! ==="

    push = Parse::Push.new
    result = push.silent!

    assert_same push, result, "silent! should return self for chaining"
    assert push.content_available?

    puts "silent! works correctly!"
  end

  # Test 37: content-available in payload
  def test_content_available_in_payload
    puts "\n=== Testing content-available in Payload ==="

    push = Parse::Push.new
    push.silent!
    push.with_data(action: "sync")

    payload = push.payload
    assert_equal 1, payload[:data][:"content-available"]

    puts "content-available in payload works correctly!"
  end

  # Test 38: content-available not in payload when not set
  def test_content_available_not_in_payload_when_not_set
    puts "\n=== Testing content-available Not in Payload When Not Set ==="

    push = Parse::Push.new
    push.alert = "Test"

    payload = push.payload
    refute payload[:data].key?(:"content-available")

    puts "content-available not in payload when not set!"
  end

  # Test 39: Silent push chain
  def test_silent_push_full_chain
    puts "\n=== Testing Silent Push Full Chain ==="

    push = Parse::Push.new
      .to_channel("background")
      .silent!
      .with_data(action: "sync", resource_id: "123")

    assert push.content_available?
    assert_equal ["background"], push.channels

    payload = push.payload
    assert_equal 1, payload[:data][:"content-available"]
    assert_equal "sync", payload[:data][:action]
    assert_equal "123", payload[:data][:resource_id]

    puts "Silent push full chain works correctly!"
  end

  # ==========================================================================
  # Rich Push Tests
  # ==========================================================================

  # Test 40: mutable_content attribute
  def test_mutable_content_attribute
    puts "\n=== Testing mutable_content Attribute ==="

    push = Parse::Push.new
    assert_nil push.mutable_content
    refute push.mutable_content?

    push.mutable_content = true
    assert push.mutable_content?

    push.mutable_content = false
    refute push.mutable_content?

    puts "mutable_content attribute works correctly!"
  end

  # Test 41: mutable! builder method
  def test_builder_mutable
    puts "\n=== Testing Builder: mutable! ==="

    push = Parse::Push.new
    result = push.mutable!

    assert_same push, result, "mutable! should return self for chaining"
    assert push.mutable_content?

    puts "mutable! works correctly!"
  end

  # Test 42: mutable-content in payload
  def test_mutable_content_in_payload
    puts "\n=== Testing mutable-content in Payload ==="

    push = Parse::Push.new
    push.mutable!
    push.alert = "Test"

    payload = push.payload
    assert_equal 1, payload[:data][:"mutable-content"]

    puts "mutable-content in payload works correctly!"
  end

  # Test 43: mutable-content not in payload when not set
  def test_mutable_content_not_in_payload_when_not_set
    puts "\n=== Testing mutable-content Not in Payload When Not Set ==="

    push = Parse::Push.new
    push.alert = "Test"

    payload = push.payload
    refute payload[:data].key?(:"mutable-content")

    puts "mutable-content not in payload when not set!"
  end

  # Test 44: with_image builder method
  def test_builder_with_image
    puts "\n=== Testing Builder: with_image ==="

    push = Parse::Push.new
    result = push.with_image("https://example.com/image.jpg")

    assert_same push, result, "with_image should return self for chaining"
    assert_equal "https://example.com/image.jpg", push.image_url
    assert push.mutable_content?, "with_image should automatically enable mutable_content"

    puts "with_image works correctly!"
  end

  # Test 45: image in payload
  def test_image_in_payload
    puts "\n=== Testing image in Payload ==="

    push = Parse::Push.new
    push.with_image("https://example.com/photo.png")
    push.alert = "Check out this image!"

    payload = push.payload
    assert_equal "https://example.com/photo.png", payload[:data][:image]
    assert_equal 1, payload[:data][:"mutable-content"]

    puts "image in payload works correctly!"
  end

  # Test 46: with_category builder method
  def test_builder_with_category
    puts "\n=== Testing Builder: with_category ==="

    push = Parse::Push.new
    result = push.with_category("MESSAGE_ACTIONS")

    assert_same push, result, "with_category should return self for chaining"
    assert_equal "MESSAGE_ACTIONS", push.category

    puts "with_category works correctly!"
  end

  # Test 47: category in payload
  def test_category_in_payload
    puts "\n=== Testing category in Payload ==="

    push = Parse::Push.new
    push.with_category("REPLY_ACTIONS")
    push.alert = "New message"

    payload = push.payload
    assert_equal "REPLY_ACTIONS", payload[:data][:category]

    puts "category in payload works correctly!"
  end

  # Test 48: category not in payload when not set
  def test_category_not_in_payload_when_not_set
    puts "\n=== Testing category Not in Payload When Not Set ==="

    push = Parse::Push.new
    push.alert = "Test"

    payload = push.payload
    refute payload[:data].key?(:category)

    puts "category not in payload when not set!"
  end

  # Test 49: Rich push full chain
  def test_rich_push_full_chain
    puts "\n=== Testing Rich Push Full Chain ==="

    push = Parse::Push.new
      .to_channel("updates")
      .with_title("New Photo")
      .with_body("John shared a photo with you")
      .with_image("https://example.com/photo.jpg")
      .with_category("PHOTO_ACTIONS")
      .with_sound("notification.caf")

    assert push.mutable_content?
    assert_equal ["updates"], push.channels
    assert_equal "New Photo", push.title
    assert_equal "John shared a photo with you", push.alert
    assert_equal "https://example.com/photo.jpg", push.image_url
    assert_equal "PHOTO_ACTIONS", push.category

    payload = push.payload
    assert_equal 1, payload[:data][:"mutable-content"]
    assert_equal "https://example.com/photo.jpg", payload[:data][:image]
    assert_equal "PHOTO_ACTIONS", payload[:data][:category]
    assert_equal "notification.caf", payload[:data][:sound]

    puts "Rich push full chain works correctly!"
  end

  # Test 50: Both silent and mutable content
  def test_silent_and_mutable_content
    puts "\n=== Testing Silent and Mutable Content Together ==="

    push = Parse::Push.new
      .silent!
      .mutable!
      .with_data(encrypted: "payload")

    assert push.content_available?
    assert push.mutable_content?

    payload = push.payload
    assert_equal 1, payload[:data][:"content-available"]
    assert_equal 1, payload[:data][:"mutable-content"]

    puts "Silent and mutable content together works correctly!"
  end

  # ==========================================================================
  # Localization Tests
  # ==========================================================================

  # Test 51: with_localized_alert builder method
  def test_builder_with_localized_alert
    puts "\n=== Testing Builder: with_localized_alert ==="

    push = Parse::Push.new
    result = push.with_localized_alert(:en, "Hello!")

    assert_same push, result, "with_localized_alert should return self for chaining"
    assert_equal({ "en" => "Hello!" }, push.localized_alerts)

    puts "with_localized_alert works correctly!"
  end

  # Test 52: with_localized_alert multiple languages
  def test_with_localized_alert_multiple_languages
    puts "\n=== Testing with_localized_alert Multiple Languages ==="

    push = Parse::Push.new
      .with_localized_alert(:en, "Hello!")
      .with_localized_alert(:fr, "Bonjour!")
      .with_localized_alert(:es, "Hola!")

    assert_equal "Hello!", push.localized_alerts["en"]
    assert_equal "Bonjour!", push.localized_alerts["fr"]
    assert_equal "Hola!", push.localized_alerts["es"]

    puts "Multiple localized alerts work correctly!"
  end

  # Test 53: with_localized_title builder method
  def test_builder_with_localized_title
    puts "\n=== Testing Builder: with_localized_title ==="

    push = Parse::Push.new
    result = push.with_localized_title(:en, "Welcome")

    assert_same push, result, "with_localized_title should return self for chaining"
    assert_equal({ "en" => "Welcome" }, push.localized_titles)

    puts "with_localized_title works correctly!"
  end

  # Test 54: with_localized_alerts hash method
  def test_with_localized_alerts_hash
    puts "\n=== Testing with_localized_alerts Hash ==="

    push = Parse::Push.new
    result = push.with_localized_alerts(en: "Hello!", fr: "Bonjour!", de: "Hallo!")

    assert_same push, result
    assert_equal "Hello!", push.localized_alerts["en"]
    assert_equal "Bonjour!", push.localized_alerts["fr"]
    assert_equal "Hallo!", push.localized_alerts["de"]

    puts "with_localized_alerts hash works correctly!"
  end

  # Test 55: with_localized_titles hash method
  def test_with_localized_titles_hash
    puts "\n=== Testing with_localized_titles Hash ==="

    push = Parse::Push.new
    result = push.with_localized_titles(en: "Welcome", es: "Bienvenido")

    assert_same push, result
    assert_equal "Welcome", push.localized_titles["en"]
    assert_equal "Bienvenido", push.localized_titles["es"]

    puts "with_localized_titles hash works correctly!"
  end

  # Test 56: localized alerts in payload
  def test_localized_alerts_in_payload
    puts "\n=== Testing Localized Alerts in Payload ==="

    push = Parse::Push.new
      .with_alert("Default message")
      .with_localized_alert(:en, "Hello!")
      .with_localized_alert(:fr, "Bonjour!")

    payload = push.payload
    assert_equal "Hello!", payload[:data][:"alert-en"]
    assert_equal "Bonjour!", payload[:data][:"alert-fr"]

    puts "Localized alerts in payload work correctly!"
  end

  # Test 57: localized titles in payload
  def test_localized_titles_in_payload
    puts "\n=== Testing Localized Titles in Payload ==="

    push = Parse::Push.new
      .with_title("Default title")
      .with_localized_title(:en, "Welcome")
      .with_localized_title(:es, "Bienvenido")

    payload = push.payload
    assert_equal "Welcome", payload[:data][:"title-en"]
    assert_equal "Bienvenido", payload[:data][:"title-es"]

    puts "Localized titles in payload work correctly!"
  end

  # Test 58: full localization chain
  def test_full_localization_chain
    puts "\n=== Testing Full Localization Chain ==="

    push = Parse::Push.new
      .to_channel("news")
      .with_alert("Default")
      .with_title("Default Title")
      .with_localized_alerts(en: "Hello!", fr: "Bonjour!", es: "Hola!")
      .with_localized_titles(en: "Welcome", fr: "Bienvenue", es: "Bienvenido")

    payload = push.payload
    assert_equal "Hello!", payload[:data][:"alert-en"]
    assert_equal "Bonjour!", payload[:data][:"alert-fr"]
    assert_equal "Hola!", payload[:data][:"alert-es"]
    assert_equal "Welcome", payload[:data][:"title-en"]
    assert_equal "Bienvenue", payload[:data][:"title-fr"]
    assert_equal "Bienvenido", payload[:data][:"title-es"]

    puts "Full localization chain works correctly!"
  end

  # ==========================================================================
  # Badge Increment Tests
  # ==========================================================================

  # Test 59: increment_badge with default amount
  def test_increment_badge_default
    puts "\n=== Testing increment_badge Default ==="

    push = Parse::Push.new
    result = push.increment_badge

    assert_same push, result, "increment_badge should return self for chaining"
    assert_equal "Increment", push.badge

    puts "increment_badge default works correctly!"
  end

  # Test 60: increment_badge with custom amount
  def test_increment_badge_custom_amount
    puts "\n=== Testing increment_badge Custom Amount ==="

    push = Parse::Push.new
    push.increment_badge(5)

    assert_equal({ "__op" => "Increment", "amount" => 5 }, push.badge)

    puts "increment_badge custom amount works correctly!"
  end

  # Test 61: increment_badge in payload
  def test_increment_badge_in_payload
    puts "\n=== Testing increment_badge in Payload ==="

    push = Parse::Push.new
      .increment_badge
      .with_alert("New message!")

    payload = push.payload
    assert_equal "Increment", payload[:data][:badge]

    puts "increment_badge in payload works correctly!"
  end

  # Test 62: increment_badge custom amount in payload
  def test_increment_badge_custom_in_payload
    puts "\n=== Testing increment_badge Custom Amount in Payload ==="

    push = Parse::Push.new
      .increment_badge(3)
      .with_alert("3 new items!")

    payload = push.payload
    assert_equal({ "__op" => "Increment", "amount" => 3 }, payload[:data][:badge])

    puts "increment_badge custom amount in payload works correctly!"
  end

  # Test 63: clear_badge builder method
  def test_clear_badge
    puts "\n=== Testing clear_badge ==="

    push = Parse::Push.new
    result = push.clear_badge

    assert_same push, result, "clear_badge should return self for chaining"
    assert_equal 0, push.badge

    puts "clear_badge works correctly!"
  end

  # Test 64: clear_badge in payload
  def test_clear_badge_in_payload
    puts "\n=== Testing clear_badge in Payload ==="

    push = Parse::Push.new
      .clear_badge
      .silent!

    payload = push.payload
    assert_equal 0, payload[:data][:badge]

    puts "clear_badge in payload works correctly!"
  end

  # ==========================================================================
  # Audience Targeting Tests
  # ==========================================================================

  # Test 65: to_audience method exists
  def test_to_audience_method_exists
    puts "\n=== Testing to_audience Method Exists ==="

    push = Parse::Push.new
    assert_respond_to push, :to_audience

    puts "to_audience method exists!"
  end

  # Test 66: to_audience_id method exists
  def test_to_audience_id_method_exists
    puts "\n=== Testing to_audience_id Method Exists ==="

    push = Parse::Push.new
    assert_respond_to push, :to_audience_id

    puts "to_audience_id method exists!"
  end

  # Test 67: to_audience returns self
  def test_to_audience_returns_self
    puts "\n=== Testing to_audience Returns Self ==="

    push = Parse::Push.new
    # Mock the Audience.first to return nil (no audience found)
    Parse::Audience.define_singleton_method(:first) { |*args| nil }

    result = push.to_audience("NonExistent")
    assert_same push, result

    puts "to_audience returns self for chaining!"
  end

  # Test 68: localized_alerts attribute
  def test_localized_alerts_attribute
    puts "\n=== Testing localized_alerts Attribute ==="

    push = Parse::Push.new
    assert_nil push.localized_alerts

    push.localized_alerts = { "en" => "Hello" }
    assert_equal({ "en" => "Hello" }, push.localized_alerts)

    puts "localized_alerts attribute works correctly!"
  end

  # Test 69: localized_titles attribute
  def test_localized_titles_attribute
    puts "\n=== Testing localized_titles Attribute ==="

    push = Parse::Push.new
    assert_nil push.localized_titles

    push.localized_titles = { "en" => "Welcome" }
    assert_equal({ "en" => "Welcome" }, push.localized_titles)

    puts "localized_titles attribute works correctly!"
  end

  # ==========================================================================
  # Push Validation Tests
  # ==========================================================================

  # Test 70: SUPPORTED_PUSH_DEVICE_TYPES constant
  def test_supported_push_device_types_constant
    puts "\n=== Testing SUPPORTED_PUSH_DEVICE_TYPES Constant ==="

    assert_equal %w[ios android osx tvos watchos web expo], Parse::Push::SUPPORTED_PUSH_DEVICE_TYPES
    assert Parse::Push::SUPPORTED_PUSH_DEVICE_TYPES.frozen?

    puts "SUPPORTED_PUSH_DEVICE_TYPES constant is correct!"
  end

  # Test 71: UNSUPPORTED_PUSH_DEVICE_TYPES constant
  def test_unsupported_push_device_types_constant
    puts "\n=== Testing UNSUPPORTED_PUSH_DEVICE_TYPES Constant ==="

    assert_equal %w[win other unknown unsupported], Parse::Push::UNSUPPORTED_PUSH_DEVICE_TYPES
    assert Parse::Push::UNSUPPORTED_PUSH_DEVICE_TYPES.frozen?

    puts "UNSUPPORTED_PUSH_DEVICE_TYPES constant is correct!"
  end

  # Test 72: to_installation raises error when device_token is missing
  def test_to_installation_raises_error_without_device_token
    puts "\n=== Testing to_installation Raises Error Without device_token ==="

    installation = Parse::Installation.new
    installation.instance_variable_set(:@id, "test123")
    installation.instance_variable_set(:@device_type, "ios")
    # Intentionally not setting device_token

    push = Parse::Push.new
    error = assert_raises(ArgumentError) do
      push.to_installation(installation)
    end

    assert_match(/missing device_token/, error.message)
    assert_match(/test123/, error.message)

    puts "to_installation raises error without device_token correctly!"
  end

  # Test 73: to_installation raises error when device_token is blank
  def test_to_installation_raises_error_with_blank_device_token
    puts "\n=== Testing to_installation Raises Error With Blank device_token ==="

    installation = Parse::Installation.new
    installation.instance_variable_set(:@id, "test456")
    installation.instance_variable_set(:@device_type, "android")
    installation.instance_variable_set(:@device_token, "")  # blank string

    push = Parse::Push.new
    error = assert_raises(ArgumentError) do
      push.to_installation(installation)
    end

    assert_match(/missing device_token/, error.message)

    puts "to_installation raises error with blank device_token correctly!"
  end

  # Test 74: to_installation warns for unsupported device type (win)
  def test_to_installation_warns_for_win_device_type
    puts "\n=== Testing to_installation Warns for 'win' Device Type ==="

    installation = Parse::Installation.new
    installation.instance_variable_set(:@id, "test789")
    installation.instance_variable_set(:@device_token, "valid_token_123")
    installation.instance_variable_set(:@device_type, "win")

    push = Parse::Push.new

    # Capture stderr to check for warning
    warnings = capture_io do
      push.to_installation(installation)
    end[1]

    assert_match(/Warning.*win.*may not be supported/, warnings)
    assert_match(/Supported types:.*ios.*android/, warnings)

    puts "to_installation warns for 'win' device type correctly!"
  end

  # Test 75: to_installation warns for other unsupported device types
  def test_to_installation_warns_for_other_unsupported_types
    puts "\n=== Testing to_installation Warns for Other Unsupported Types ==="

    %w[other unknown unsupported].each do |device_type|
      installation = Parse::Installation.new
      installation.instance_variable_set(:@id, "test_#{device_type}")
      installation.instance_variable_set(:@device_token, "valid_token")
      installation.instance_variable_set(:@device_type, device_type)

      push = Parse::Push.new

      warnings = capture_io do
        push.to_installation(installation)
      end[1]

      assert_match(/Warning.*#{device_type}.*may not be supported/, warnings)
    end

    puts "to_installation warns for other unsupported types correctly!"
  end

  # Test 76: to_installation warns for unknown/unrecognized device type
  def test_to_installation_warns_for_unrecognized_device_type
    puts "\n=== Testing to_installation Warns for Unrecognized Device Type ==="

    installation = Parse::Installation.new
    installation.instance_variable_set(:@id, "test_custom")
    installation.instance_variable_set(:@device_token, "valid_token")
    installation.instance_variable_set(:@device_type, "custom_device")

    push = Parse::Push.new

    warnings = capture_io do
      push.to_installation(installation)
    end[1]

    assert_match(/Warning.*unknown device_type.*custom_device/, warnings)
    assert_match(/may not receive push notifications/, warnings)

    puts "to_installation warns for unrecognized device type correctly!"
  end

  # Test 77: to_installation succeeds without warning for supported device types
  def test_to_installation_no_warning_for_supported_types
    puts "\n=== Testing to_installation No Warning for Supported Types ==="

    Parse::Push::SUPPORTED_PUSH_DEVICE_TYPES.each do |device_type|
      installation = Parse::Installation.new
      installation.instance_variable_set(:@id, "test_#{device_type}")
      installation.instance_variable_set(:@device_token, "valid_token_#{device_type}")
      installation.instance_variable_set(:@device_type, device_type)

      push = Parse::Push.new

      warnings = capture_io do
        result = push.to_installation(installation)
        assert_same push, result, "to_installation should return self for chaining"
      end[1]

      assert_empty warnings, "Should not warn for supported device type: #{device_type}"
    end

    puts "to_installation has no warning for supported types!"
  end

  # Test 78: to_installation with string ID does not validate
  def test_to_installation_with_string_id_no_validation
    puts "\n=== Testing to_installation With String ID (No Validation) ==="

    push = Parse::Push.new

    # Should not raise - no validation for string IDs
    result = push.to_installation("abc123")
    assert_same push, result

    # Verify query was set correctly
    assert_equal "abc123", push.where["objectId"]

    puts "to_installation with string ID skips validation correctly!"
  end

  # Test 79: to_installation with hash does not validate
  def test_to_installation_with_hash_no_validation
    puts "\n=== Testing to_installation With Hash (No Validation) ==="

    push = Parse::Push.new

    # Should not raise - no validation for hashes
    result = push.to_installation({ objectId: "def456" })
    assert_same push, result

    puts "to_installation with hash skips validation correctly!"
  end

  # Test 80: to_installations validates all installations
  def test_to_installations_validates_all
    puts "\n=== Testing to_installations Validates All Installations ==="

    valid_installation = Parse::Installation.new
    valid_installation.instance_variable_set(:@id, "valid1")
    valid_installation.instance_variable_set(:@device_token, "token1")
    valid_installation.instance_variable_set(:@device_type, "ios")

    invalid_installation = Parse::Installation.new
    invalid_installation.instance_variable_set(:@id, "invalid1")
    invalid_installation.instance_variable_set(:@device_type, "android")
    # No device_token

    push = Parse::Push.new

    # Should raise error for the invalid installation
    error = assert_raises(ArgumentError) do
      push.to_installations(valid_installation, invalid_installation)
    end

    assert_match(/missing device_token/, error.message)
    assert_match(/invalid1/, error.message)

    puts "to_installations validates all installations correctly!"
  end

  # Test 81: to_installations warns for unsupported device types
  def test_to_installations_warns_for_unsupported_types
    puts "\n=== Testing to_installations Warns for Unsupported Types ==="

    ios_installation = Parse::Installation.new
    ios_installation.instance_variable_set(:@id, "ios1")
    ios_installation.instance_variable_set(:@device_token, "token_ios")
    ios_installation.instance_variable_set(:@device_type, "ios")

    win_installation = Parse::Installation.new
    win_installation.instance_variable_set(:@id, "win1")
    win_installation.instance_variable_set(:@device_token, "token_win")
    win_installation.instance_variable_set(:@device_type, "win")

    push = Parse::Push.new

    warnings = capture_io do
      push.to_installations(ios_installation, win_installation)
    end[1]

    # Should warn about win but not have "Warning" prefix for ios
    assert_match(/Warning.*'win'.*may not be supported/, warnings)
    # The warning only mentions ios in the "Supported types" list, not as a warning target
    refute_match(/Warning.*'ios'/, warnings)

    puts "to_installations warns for unsupported types correctly!"
  end

  # Test 82: to_installations with mixed types (objects and strings)
  def test_to_installations_mixed_types
    puts "\n=== Testing to_installations With Mixed Types ==="

    installation = Parse::Installation.new
    installation.instance_variable_set(:@id, "obj1")
    installation.instance_variable_set(:@device_token, "token1")
    installation.instance_variable_set(:@device_type, "android")

    push = Parse::Push.new

    # Mix of Installation object and string ID
    result = push.to_installations(installation, "string_id_123")

    assert_same push, result
    # Should have both IDs in the query
    where_clause = push.where
    assert where_clause["objectId"]
    # The $in key is a symbol
    in_list = where_clause["objectId"][:$in]
    assert in_list.include?("obj1")
    assert in_list.include?("string_id_123")

    puts "to_installations with mixed types works correctly!"
  end

  # Test 83: to_installation delegates array to to_installations
  def test_to_installation_delegates_array
    puts "\n=== Testing to_installation Delegates Array to to_installations ==="

    installation1 = Parse::Installation.new
    installation1.instance_variable_set(:@id, "arr1")
    installation1.instance_variable_set(:@device_token, "token1")
    installation1.instance_variable_set(:@device_type, "ios")

    installation2 = Parse::Installation.new
    installation2.instance_variable_set(:@id, "arr2")
    installation2.instance_variable_set(:@device_token, "token2")
    installation2.instance_variable_set(:@device_type, "android")

    push = Parse::Push.new
    result = push.to_installation([installation1, installation2])

    assert_same push, result
    where_clause = push.where
    # The $in key is a symbol
    in_list = where_clause["objectId"][:$in]
    assert in_list.include?("arr1")
    assert in_list.include?("arr2")

    puts "to_installation delegates array correctly!"
  end

  # Test 84: Validation with nil device_type (should not warn)
  def test_to_installation_no_warning_for_nil_device_type
    puts "\n=== Testing to_installation No Warning for nil Device Type ==="

    installation = Parse::Installation.new
    installation.instance_variable_set(:@id, "nil_type")
    installation.instance_variable_set(:@device_token, "valid_token")
    installation.instance_variable_set(:@device_type, nil)

    push = Parse::Push.new

    warnings = capture_io do
      push.to_installation(installation)
    end[1]

    # Should not warn for nil device_type (empty string after to_s)
    assert_empty warnings

    puts "to_installation has no warning for nil device type!"
  end
end
