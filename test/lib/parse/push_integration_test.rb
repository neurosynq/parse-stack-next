# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"

# Integration tests for Parse::Push functionality.
#
# These exercise the SDK-side push surface (payload construction, badge ops,
# localization, and the Push/PushStatus/Audience/Installation model APIs).
# They need a configured Parse client but do not push to a real device
# gateway, so a running Parse Server is sufficient.
#
# Run with: PARSE_TEST_USE_DOCKER=true ruby -Itest test/lib/parse/push_integration_test.rb
class PushIntegrationTest < Minitest::Test
  def setup
    skip "Integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    # Configure the default Parse client (server URL, app id, keys). The
    # previous health-check ran before any client was set up, so `Parse.client`
    # raised and silently skipped every test in this file.
    Parse::Test::ServerHelper.setup
    @created = []
  end

  # The server-backed tests below create real _Installation / _PushStatus rows
  # on the shared integration database. Destroy them so they don't skew counts
  # or queries other files run (e.g. Installation.subscribers_count,
  # PushStatus.recent).
  def teardown
    Array(@created).reverse_each { |obj| obj.destroy rescue nil }
  end

  # Register a saved object for teardown cleanup.
  def track(obj)
    (@created ||= []) << obj
    obj
  end

  # Poll for the _PushStatus belonging to THIS test to reach a terminal
  # state. Parse Server processes `POST /push` asynchronously, so the row's
  # counts are not populated the instant the request returns.
  #
  # `channel:` scopes the lookup to the push under test (every test uses a
  # unique channel). Without it, a concurrent or prior test's terminal row
  # is the globally-newest one and can both false-fail (wrong counts) and
  # false-pass (assertions check the wrong row). For non-channel targeting
  # (e.g. `to_query`), pass `since:` to accept only rows newer than a
  # snapshot taken before `.send`.
  def latest_push_status_time
    Parse::PushStatus.query(order: :createdAt.desc).first&.created_at
  end

  def wait_for_terminal_push_status(timeout: 10, channel: nil, since: nil)
    matches = lambda do |status|
      return false unless status
      return false unless %w[succeeded failed].include?(status.status)
      return false if since && !(status.created_at && status.created_at > since)
      return false if channel && !push_status_targets_channel?(status, channel)
      true
    end

    deadline = Time.now + timeout
    candidate = nil
    loop do
      candidate = recent_push_status(channel)
      return candidate if matches.call(candidate)
      break if Time.now > deadline
      sleep 0.25
    end
    candidate
  end

  # Newest _PushStatus, narrowed server-side to the channel when possible
  # (the `query` column stores the target as a JSON string, so an exact
  # server-side filter isn't reliable — fall back to a client-side scan of
  # recent rows).
  def recent_push_status(channel)
    rows = Parse::PushStatus.query(order: :createdAt.desc, limit: 25).results
    return rows.first if channel.nil?
    rows.find { |s| push_status_targets_channel?(s, channel) } || rows.first
  end

  # True if the _PushStatus row's stored target query references `channel`.
  def push_status_targets_channel?(status, channel)
    q = status.query
    q = (JSON.parse(q) rescue nil) if q.is_a?(String)
    q.to_s.include?(channel)
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

  # ==========================================================================
  # Server-backed integration: real _Installation round-trips
  # ==========================================================================

  # Test 24: Installation saves and is queryable by channel
  def test_installation_save_and_query_by_channel
    channel = "news_#{SecureRandom.hex(4)}"
    token = SecureRandom.hex(32)

    installation = Parse::Installation.new(
      device_type: "ios",
      device_token: token,
      installation_id: SecureRandom.uuid,
      channels: [channel],
    )
    assert installation.save, "installation should save to the server"
    refute_nil installation.id
    track(installation)

    # Round-trip: query the channel back from the server.
    found = Parse::Installation.query(:channels.in => [channel]).first
    refute_nil found, "installation should be findable by its channel"
    assert_equal installation.id, found.id
    assert_includes found.channels.to_a, channel
  end

  # Test 25: subscribe / unsubscribe persist to the server
  def test_installation_subscribe_unsubscribe_round_trip
    installation = Parse::Installation.new(
      device_type: "android",
      device_token: SecureRandom.hex(32),
      installation_id: SecureRandom.uuid,
      channels: [],
    )
    installation.save
    track(installation)

    a = "alpha_#{SecureRandom.hex(3)}"
    b = "beta_#{SecureRandom.hex(3)}"

    installation.subscribe(a, b)
    reloaded = Parse::Installation.find(installation.id)
    assert_includes reloaded.channels.to_a, a
    assert_includes reloaded.channels.to_a, b

    installation.unsubscribe(a)
    reloaded = Parse::Installation.find(installation.id)
    refute_includes reloaded.channels.to_a, a
    assert_includes reloaded.channels.to_a, b
  end

  # ==========================================================================
  # Server-backed integration: push send + _PushStatus lifecycle
  #
  # The test stack configures a no-op push adapter (test/cloud/
  # dummy-push-adapter.js, wired via PARSE_SERVER_PUSH). It reports a
  # successful transmission without contacting any device gateway, so Parse
  # Server creates and completes a real _PushStatus we can assert against.
  # ==========================================================================

  # Test 26: sending to a channel creates a succeeded _PushStatus
  def test_push_send_to_channel_creates_succeeded_status
    channel = "push_#{SecureRandom.hex(4)}"

    # A subscriber must exist for the push to have a recipient.
    installation = Parse::Installation.new(
      device_type: "ios",
      device_token: SecureRandom.hex(32),
      installation_id: SecureRandom.uuid,
      channels: [channel],
    )
    installation.save
    track(installation)

    response = Parse::Push.new
      .to_channel(channel)
      .with_alert("Integration ping")
      .send

    assert response.success?, "POST /push should succeed with a push adapter configured"
    assert_equal true, response.result["result"]

    status = wait_for_terminal_push_status(channel: channel)
    refute_nil status, "a _PushStatus row should be created"
    track(status)
    assert_equal "succeeded", status.status
    assert_operator status.num_sent.to_i, :>=, 1, "at least the one subscriber should be counted as sent"
    assert_equal 1, status.sent_per_type["ios"], "the iOS subscriber should be tallied under sent_per_type"
  end

  # Test 27: sending without a push adapter would fail closed — here we assert
  # the SDK's master-key guard on the send path (no master key => raise, never
  # an unauthenticated POST).
  def test_push_send_requires_master_key
    no_master = Parse::Client.new(
      server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse",
      application_id: ENV["PARSE_TEST_APP_ID"] || "psnextItAppId",
      api_key: ENV["PARSE_TEST_API_KEY"] || "psnext-it-rest-key",
    )

    assert_raises(Parse::Error::AuthenticationError) do
      no_master.push(channels: ["anything"], data: { alert: "nope" })
    end
  end

  # ==========================================================================
  # Server-backed integration: real _Audience round-trip
  #
  # Parse Server's `_Audience.query` column is typed String (JSON), so a hash
  # query must be persisted as a JSON string. This exercises that the SDK
  # serializes/deserializes correctly and that the audience drives a real
  # Installation count.
  # ==========================================================================

  # Test 28: audience saves a hash query, is findable, and counts installations
  def test_audience_save_find_and_installation_count
    channel = "aud_#{SecureRandom.hex(4)}"
    name = "Audience #{SecureRandom.hex(4)}"

    # An installation that matches the audience's query.
    installation = Parse::Installation.new(
      device_type: "ios",
      device_token: SecureRandom.hex(32),
      installation_id: SecureRandom.uuid,
      channels: [channel],
    )
    installation.save
    track(installation)

    audience = Parse::Audience.new(name: name, query: { "channels" => channel })
    assert audience.save,
      "audience with a hash query should save (query persists as a JSON string)"
    track(audience)

    found = Parse::Audience.find_by_name(name, cache: false)
    refute_nil found, "audience should be findable by name"
    assert_equal channel, found.query["channels"], "query should round-trip back to a hash"

    assert_equal 1, Parse::Audience.installation_count(name),
      "the one matching installation should be counted"
  end

  # ==========================================================================
  # Server-backed integration: _PushStatus failure + multi-type lifecycle
  #
  # The no-op adapter simulates a failed transmission for any installation whose
  # device token begins with "fail-", which exercises numFailed / failedPerType
  # without a real device gateway.
  # ==========================================================================

  # Helper: save an installation subscribed to a channel.
  def save_installation(device_type:, token:, channel:)
    inst = Parse::Installation.new(
      device_type: device_type,
      device_token: token,
      installation_id: SecureRandom.uuid,
      channels: [channel],
    )
    inst.save
    track(inst)
  end

  # Test 29: a failed transmission is tracked under num_failed / failed_per_type
  def test_push_failed_delivery_is_tracked
    channel = "fail_#{SecureRandom.hex(4)}"
    save_installation(device_type: "ios", token: "fail-#{SecureRandom.hex(8)}", channel: channel)

    Parse::Push.new.to_channel(channel).with_alert("will fail").send

    status = wait_for_terminal_push_status(channel: channel)
    refute_nil status
    track(status)
    assert_equal 0, status.num_sent.to_i
    assert_operator status.num_failed.to_i, :>=, 1
    assert_equal 1, status.failed_per_type["ios"]
  end

  # Test 30: a single push with one good and one failing recipient tallies both
  def test_push_mixed_sent_and_failed
    channel = "mix_#{SecureRandom.hex(4)}"
    save_installation(device_type: "ios", token: SecureRandom.hex(16), channel: channel)
    save_installation(device_type: "ios", token: "fail-#{SecureRandom.hex(8)}", channel: channel)

    Parse::Push.new.to_channel(channel).with_alert("mixed").send

    status = wait_for_terminal_push_status(channel: channel)
    refute_nil status
    track(status)
    assert_operator status.num_sent.to_i, :>=, 1, "the good recipient should be counted as sent"
    assert_operator status.num_failed.to_i, :>=, 1, "the fail- recipient should be counted as failed"
  end

  # Test 31: sent_per_type tallies each device type
  def test_push_sent_per_type_for_multiple_device_types
    channel = "multi_#{SecureRandom.hex(4)}"
    save_installation(device_type: "ios", token: SecureRandom.hex(16), channel: channel)
    save_installation(device_type: "android", token: SecureRandom.hex(16), channel: channel)

    Parse::Push.new.to_channel(channel).with_alert("multi-type").send

    status = wait_for_terminal_push_status(channel: channel)
    refute_nil status
    track(status)
    assert_equal "succeeded", status.status
    assert_equal 1, status.sent_per_type["ios"], "iOS recipient should be tallied"
    assert_equal 1, status.sent_per_type["android"], "Android recipient should be tallied"
  end

  # ==========================================================================
  # Server-backed integration: alternate targeting paths
  # ==========================================================================

  # Test 32: query-based targeting (to_query) sends to matching installations
  def test_push_to_query_creates_succeeded_status
    token = SecureRandom.hex(16)
    save_installation(device_type: "ios", token: token, channel: "q_#{SecureRandom.hex(4)}")

    # Query-based targeting has no channel to scope on; snapshot the newest
    # terminal row before sending and accept only a row created after it.
    since = latest_push_status_time

    Parse::Push.new
      .to_query { |q| q.where(device_token: token) }
      .with_alert("query target")
      .send

    status = wait_for_terminal_push_status(since: since)
    refute_nil status
    track(status)
    assert_equal "succeeded", status.status
    assert_operator status.num_sent.to_i, :>=, 1
  end

  # Test 33: audience-based targeting (to_audience) resolves the saved query
  def test_push_to_audience_sends_to_matching_installations
    channel = "ta_#{SecureRandom.hex(4)}"
    name = "PushAudience #{SecureRandom.hex(4)}"
    save_installation(device_type: "ios", token: SecureRandom.hex(16), channel: channel)

    audience = Parse::Audience.new(name: name, query: { "channels" => channel })
    audience.save
    track(audience)

    Parse::Push.new
      .to_audience(name)
      .with_alert("audience target")
      .send

    status = wait_for_terminal_push_status(channel: channel)
    refute_nil status
    track(status)
    assert_equal "succeeded", status.status
    assert_operator status.num_sent.to_i, :>=, 1
  end
end
