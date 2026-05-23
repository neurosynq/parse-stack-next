# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Integration tests for Parse::Push functionality
# These tests require Parse Server to be running
#
# Run with: PARSE_TEST_USE_DOCKER=true ruby -Itest test/lib/parse/push_integration_test.rb
class PushIntegrationTest < Minitest::Test
  def setup
    skip "Integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"]

    # Ensure we have a valid connection
    begin
      response = Parse.client.request(:get, "health")
      skip "Parse Server not responding" unless response
    rescue StandardError => e
      skip "Parse Server not available: #{e.message}"
    end
  end

  # ==========================================================================
  # Test 1: Push payload structure
  # ==========================================================================
  def test_push_payload_structure
    puts "\n=== Testing Push Payload Structure ==="

    push = Parse::Push.new
      .to_channel("test_channel")
      .with_title("Test Title")
      .with_body("Test Body")
      .with_badge(1)
      .with_sound("default")

    payload = push.payload.as_json

    assert payload.key?("data")
    assert_equal "Test Title", payload["data"]["title"]
    assert_equal "Test Body", payload["data"]["alert"]
    assert_equal 1, payload["data"]["badge"]
    assert_equal "default", payload["data"]["sound"]
    assert_equal ["test_channel"], payload["channels"]

    puts "Push payload structure is correct!"
  end

  # ==========================================================================
  # Test 2: Silent push payload
  # ==========================================================================
  def test_silent_push_payload
    puts "\n=== Testing Silent Push Payload ==="

    push = Parse::Push.new
      .to_channel("background")
      .silent!
      .with_data(action: "sync", resource: "users")

    payload = push.payload.as_json

    assert_equal 1, payload["data"]["content-available"]
    assert_equal "sync", payload["data"]["action"]
    assert_equal "users", payload["data"]["resource"]

    puts "Silent push payload is correct!"
  end

  # ==========================================================================
  # Test 3: Rich push payload
  # ==========================================================================
  def test_rich_push_payload
    puts "\n=== Testing Rich Push Payload ==="

    push = Parse::Push.new
      .to_channel("media")
      .with_title("New Photo")
      .with_body("Check out this photo!")
      .with_image("https://example.com/photo.jpg")
      .with_category("PHOTO_ACTIONS")

    payload = push.payload.as_json

    assert_equal 1, payload["data"]["mutable-content"]
    assert_equal "https://example.com/photo.jpg", payload["data"]["image"]
    assert_equal "PHOTO_ACTIONS", payload["data"]["category"]

    puts "Rich push payload is correct!"
  end

  # ==========================================================================
  # Test 4: Scheduled push payload
  # ==========================================================================
  def test_scheduled_push_payload
    puts "\n=== Testing Scheduled Push Payload ==="

    future_time = Time.now + 3600  # 1 hour from now
    push = Parse::Push.new
      .to_channel("scheduled")
      .with_alert("Scheduled message")
      .schedule(future_time)
      .expires_in(7200)

    payload = push.payload.as_json

    assert payload.key?("push_time")
    assert_equal 7200, payload["expiration_interval"]

    puts "Scheduled push payload is correct!"
  end

  # ==========================================================================
  # Test 5: Query-based push payload
  # ==========================================================================
  def test_query_based_push_payload
    puts "\n=== Testing Query-Based Push Payload ==="

    push = Parse::Push.new
      .to_query { |q| q.where(device_type: "ios", :app_version.gte => "2.0") }
      .with_alert("iOS 2.0+ users only")

    payload = push.payload.as_json

    assert payload.key?("where")
    assert_equal "ios", payload["where"]["deviceType"]
    assert payload["where"]["appVersion"].key?("$gte")

    puts "Query-based push payload is correct!"
  end

  # ==========================================================================
  # Test 6: Installation channel management structure
  # ==========================================================================
  def test_installation_subscribe_structure
    puts "\n=== Testing Installation Subscribe Structure ==="

    installation = Parse::Installation.new
    installation.device_type = :ios
    installation.device_token = "test_token_#{SecureRandom.hex(16)}"
    installation.installation_id = SecureRandom.uuid

    # Test that subscribe modifies channels locally
    installation.channels = []
    original_channels = installation.channels.to_a.dup

    # Mock save to prevent actual API call in this structure test
    installation.define_singleton_method(:save) { true }

    installation.subscribe("news", "weather")

    assert_includes installation.channels, "news"
    assert_includes installation.channels, "weather"

    puts "Installation subscribe structure is correct!"
  end

  # ==========================================================================
  # Test 7: Installation unsubscribe structure
  # ==========================================================================
  def test_installation_unsubscribe_structure
    puts "\n=== Testing Installation Unsubscribe Structure ==="

    installation = Parse::Installation.new
    installation.channels = ["news", "sports", "weather"]

    # Mock save
    installation.define_singleton_method(:save) { true }

    installation.unsubscribe("sports")

    refute_includes installation.channels, "sports"
    assert_includes installation.channels, "news"
    assert_includes installation.channels, "weather"

    puts "Installation unsubscribe structure is correct!"
  end

  # ==========================================================================
  # Test 8: Combined silent and mutable push
  # ==========================================================================
  def test_combined_silent_mutable_push
    puts "\n=== Testing Combined Silent and Mutable Push ==="

    push = Parse::Push.new
      .to_channel("encrypted")
      .silent!
      .mutable!
      .with_data(encrypted_payload: "base64data...")

    payload = push.payload.as_json

    assert_equal 1, payload["data"]["content-available"]
    assert_equal 1, payload["data"]["mutable-content"]
    assert_equal "base64data...", payload["data"]["encrypted_payload"]

    puts "Combined silent and mutable push is correct!"
  end

  # ==========================================================================
  # Test 9: Class method shortcuts
  # ==========================================================================
  def test_class_method_shortcuts
    puts "\n=== Testing Class Method Shortcuts ==="

    # Test Parse::Push.to_channel
    push1 = Parse::Push.to_channel("news")
    assert_instance_of Parse::Push, push1
    assert_equal ["news"], push1.channels

    # Test Parse::Push.to_channels
    push2 = Parse::Push.to_channels("sports", "weather")
    assert_instance_of Parse::Push, push2
    assert_equal ["sports", "weather"], push2.channels

    puts "Class method shortcuts work correctly!"
  end

  # ==========================================================================
  # Test 10: Full push notification chain
  # ==========================================================================
  def test_full_push_chain
    puts "\n=== Testing Full Push Notification Chain ==="

    push = Parse::Push.new
      .to_channels("breaking_news", "alerts")
      .with_title("Breaking News")
      .with_body("Major event happening now!")
      .with_badge(1)
      .with_sound("news_alert.caf")
      .with_image("https://example.com/news/image.jpg")
      .with_category("NEWS_ACTIONS")
      .with_data(article_id: "12345", source: "breaking")
      .schedule(Time.now + 60)
      .expires_in(3600)

    payload = push.payload.as_json

    # Verify all components
    assert_equal "Breaking News", payload["data"]["title"]
    assert_equal "Major event happening now!", payload["data"]["alert"]
    assert_equal 1, payload["data"]["badge"]
    assert_equal "news_alert.caf", payload["data"]["sound"]
    assert_equal 1, payload["data"]["mutable-content"]
    assert_equal "https://example.com/news/image.jpg", payload["data"]["image"]
    assert_equal "NEWS_ACTIONS", payload["data"]["category"]
    assert_equal "12345", payload["data"]["article_id"]
    assert_equal "breaking", payload["data"]["source"]
    assert payload.key?("push_time")
    assert_equal 3600, payload["expiration_interval"]

    puts "Full push notification chain works correctly!"
  end

  # ==========================================================================
  # Localization Integration Tests
  # ==========================================================================

  # Test 11: Localized push payload structure
  def test_localized_push_payload
    puts "\n=== Testing Localized Push Payload ==="

    push = Parse::Push.new
      .to_channel("international")
      .with_alert("Default message")
      .with_title("Default title")
      .with_localized_alerts(en: "Hello!", fr: "Bonjour!", es: "Hola!")
      .with_localized_titles(en: "Welcome", fr: "Bienvenue", es: "Bienvenido")

    payload = push.payload.as_json

    # Verify default message
    assert_equal "Default message", payload["data"]["alert"]
    assert_equal "Default title", payload["data"]["title"]

    # Verify localized alerts
    assert_equal "Hello!", payload["data"]["alert-en"]
    assert_equal "Bonjour!", payload["data"]["alert-fr"]
    assert_equal "Hola!", payload["data"]["alert-es"]

    # Verify localized titles
    assert_equal "Welcome", payload["data"]["title-en"]
    assert_equal "Bienvenue", payload["data"]["title-fr"]
    assert_equal "Bienvenido", payload["data"]["title-es"]

    puts "Localized push payload is correct!"
  end

  # Test 12: Localized push with partial translations
  def test_localized_push_partial
    puts "\n=== Testing Localized Push with Partial Translations ==="

    push = Parse::Push.new
      .to_channel("partial_i18n")
      .with_alert("English fallback")
      .with_localized_alert(:de, "Hallo!")
      .with_localized_alert(:ja, "Hello!")

    payload = push.payload.as_json

    assert_equal "English fallback", payload["data"]["alert"]
    assert_equal "Hallo!", payload["data"]["alert-de"]
    assert_equal "Hello!", payload["data"]["alert-ja"]

    puts "Partial localization works correctly!"
  end

  # ==========================================================================
  # Badge Increment Integration Tests
  # ==========================================================================

  # Test 13: Badge increment payload
  def test_badge_increment_payload
    puts "\n=== Testing Badge Increment Payload ==="

    push = Parse::Push.new
      .to_channel("badges")
      .with_alert("New message!")
      .increment_badge

    payload = push.payload.as_json

    assert_equal "Increment", payload["data"]["badge"]

    puts "Badge increment payload is correct!"
  end

  # Test 14: Badge increment with amount
  def test_badge_increment_amount_payload
    puts "\n=== Testing Badge Increment with Amount ==="

    push = Parse::Push.new
      .to_channel("badges")
      .with_alert("5 new messages!")
      .increment_badge(5)

    payload = push.payload.as_json

    assert_equal({ "__op" => "Increment", "amount" => 5 }, payload["data"]["badge"])

    puts "Badge increment with amount is correct!"
  end

  # Test 15: Clear badge payload
  def test_clear_badge_payload
    puts "\n=== Testing Clear Badge Payload ==="

    push = Parse::Push.new
      .to_channel("badges")
      .silent!
      .clear_badge

    payload = push.payload.as_json

    assert_equal 0, payload["data"]["badge"]

    puts "Clear badge payload is correct!"
  end

  # ==========================================================================
  # Audience Integration Tests
  # ==========================================================================

  # Test 16: Audience class exists
  def test_audience_class_exists
    puts "\n=== Testing Audience Class Exists ==="

    assert_equal "_Audience", Parse::Audience.parse_class

    audience = Parse::Audience.new
    assert_respond_to audience, :name
    assert_respond_to audience, :query
    assert_respond_to audience, :query_constraint

    puts "Audience class exists and has correct properties!"
  end

  # Test 17: Audience instance methods
  def test_audience_instance_methods
    puts "\n=== Testing Audience Instance Methods ==="

    audience = Parse::Audience.new
    audience.name = "Test Audience"
    audience.query = { "deviceType" => "ios" }

    assert_equal "Test Audience", audience.name
    assert_equal({ "deviceType" => "ios" }, audience.query_constraint)

    assert_respond_to audience, :installation_count
    assert_respond_to audience, :installations

    puts "Audience instance methods work correctly!"
  end

  # Test 18: Audience class methods
  def test_audience_class_methods
    puts "\n=== Testing Audience Class Methods ==="

    assert_respond_to Parse::Audience, :find_by_name
    assert_respond_to Parse::Audience, :installation_count
    assert_respond_to Parse::Audience, :installations

    puts "Audience class methods exist!"
  end

  # ==========================================================================
  # PushStatus Integration Tests
  # ==========================================================================

  # Test 19: PushStatus class exists
  def test_push_status_class_exists
    puts "\n=== Testing PushStatus Class Exists ==="

    assert_equal "_PushStatus", Parse::PushStatus.parse_class

    status = Parse::PushStatus.new
    assert_respond_to status, :push_hash
    assert_respond_to status, :status
    assert_respond_to status, :num_sent
    assert_respond_to status, :num_failed
    assert_respond_to status, :sent_per_type
    assert_respond_to status, :failed_per_type

    puts "PushStatus class exists and has correct properties!"
  end

  # Test 20: PushStatus query scopes
  def test_push_status_query_scopes
    puts "\n=== Testing PushStatus Query Scopes ==="

    assert_respond_to Parse::PushStatus, :pending
    assert_respond_to Parse::PushStatus, :scheduled
    assert_respond_to Parse::PushStatus, :running
    assert_respond_to Parse::PushStatus, :succeeded
    assert_respond_to Parse::PushStatus, :failed
    assert_respond_to Parse::PushStatus, :recent

    # Verify they return queries
    assert_instance_of Parse::Query, Parse::PushStatus.pending
    assert_instance_of Parse::Query, Parse::PushStatus.recent

    puts "PushStatus query scopes work correctly!"
  end

  # Test 21: PushStatus status predicates
  def test_push_status_predicates
    puts "\n=== Testing PushStatus Status Predicates ==="

    status = Parse::PushStatus.new
    status.status = "succeeded"

    assert status.succeeded?
    refute status.failed?
    refute status.pending?
    assert status.complete?
    refute status.in_progress?

    status.status = "running"
    assert status.running?
    assert status.in_progress?
    refute status.complete?

    puts "PushStatus predicates work correctly!"
  end

  # Test 22: PushStatus metrics
  def test_push_status_metrics
    puts "\n=== Testing PushStatus Metrics ==="

    status = Parse::PushStatus.new
    status.num_sent = 980
    status.num_failed = 20
    status.count = 1000

    assert_equal 1000, status.total_attempted
    assert_equal 98.0, status.success_rate
    assert_equal 2.0, status.failure_rate

    summary = status.summary
    assert_equal 980, summary[:sent]
    assert_equal 20, summary[:failed]
    assert_equal 98.0, summary[:success_rate]

    puts "PushStatus metrics work correctly!"
  end

  # Test 23: Full push with all new features
  def test_full_push_with_new_features
    puts "\n=== Testing Full Push with All New Features ==="

    push = Parse::Push.new
      .to_channel("all_features")
      .with_title("Multi-language Alert")
      .with_body("Default message")
      .with_localized_alerts(
        en: "New notification!",
        fr: "Nouvelle notification!",
        de: "Neue Benachrichtigung!",
        es: "Nueva notificacion!",
      )
      .with_localized_titles(
        en: "Alert",
        fr: "Alerte",
        de: "Warnung",
        es: "Alerta",
      )
      .increment_badge
      .with_sound("multilang.caf")
      .with_image("https://example.com/flag.png")
      .with_category("INTERNATIONAL")

    payload = push.payload.as_json

    # Default content
    assert_equal "Default message", payload["data"]["alert"]
    assert_equal "Multi-language Alert", payload["data"]["title"]

    # Localized content
    assert_equal "New notification!", payload["data"]["alert-en"]
    assert_equal "Nouvelle notification!", payload["data"]["alert-fr"]
    assert_equal "Neue Benachrichtigung!", payload["data"]["alert-de"]
    assert_equal "Alert", payload["data"]["title-en"]
    assert_equal "Alerte", payload["data"]["title-fr"]
    assert_equal "Warnung", payload["data"]["title-de"]

    # Badge and rich content
    assert_equal "Increment", payload["data"]["badge"]
    assert_equal 1, payload["data"]["mutable-content"]
    assert_equal "https://example.com/flag.png", payload["data"]["image"]
    assert_equal "INTERNATIONAL", payload["data"]["category"]

    puts "Full push with all new features works correctly!"
  end
end
