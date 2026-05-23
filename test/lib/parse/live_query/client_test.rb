# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/live_query"

class TestLiveQueryClient < Minitest::Test
  extend Minitest::Spec::DSL

  def setup
    # Configure LiveQuery for testing (but don't actually connect)
    Parse::LiveQuery.configure do |config|
      config.url = "wss://test.example.com"
      config.application_id = "test_app_id"
      config.client_key = "test_client_key"
    end
  end

  def teardown
    Parse::LiveQuery.reset!
    Parse::LiveQuery.instance_variable_set(:@config, nil)
  end

  def test_configuration
    config = Parse::LiveQuery.configuration

    assert_equal "wss://test.example.com", config[:url]
    assert_equal "test_app_id", config[:application_id]
    assert_equal "test_client_key", config[:client_key]
  end

  def test_available_when_url_configured
    assert Parse::LiveQuery.available?
  end

  def test_not_available_when_url_missing
    Parse::LiveQuery.instance_variable_set(:@config, nil)
    Parse::LiveQuery.configure do |config|
      config.url = nil
    end
    refute Parse::LiveQuery.available?
  end

  def test_client_initialization_without_auto_connect
    client = Parse::LiveQuery::Client.new(
      url: "wss://test.example.com",
      application_id: "test_app_id",
      client_key: "test_key",
      auto_connect: false,
    )

    assert_equal "wss://test.example.com", client.url
    assert_equal "test_app_id", client.application_id
    assert_equal "test_key", client.client_key
    assert_equal :disconnected, client.state
    assert_empty client.subscriptions
  end

  def test_client_subscribe_creates_subscription
    client = Parse::LiveQuery::Client.new(
      url: "wss://test.example.com",
      application_id: "test_app_id",
      client_key: "test_key",
      auto_connect: false,
    )

    subscription = client.subscribe("Song", where: { "artist" => "Beatles" })

    assert_instance_of Parse::LiveQuery::Subscription, subscription
    assert_equal "Song", subscription.class_name
    assert_equal({ "artist" => "Beatles" }, subscription.query)
    assert client.subscriptions.key?(subscription.request_id)
  end

  def test_client_subscribe_with_parse_query
    client = Parse::LiveQuery::Client.new(
      url: "wss://test.example.com",
      application_id: "test_app_id",
      client_key: "test_key",
      auto_connect: false,
    )

    query = Parse::Query.new("Album")
    query.where(:year.gt => 2000)

    subscription = client.subscribe(query)

    assert_instance_of Parse::LiveQuery::Subscription, subscription
    assert_equal "Album", subscription.class_name
    refute_empty subscription.query
  end

  def test_client_state_methods
    client = Parse::LiveQuery::Client.new(
      url: "wss://test.example.com",
      application_id: "test_app_id",
      client_key: "test_key",
      auto_connect: false,
    )

    refute client.connected?
    refute client.connecting?
    refute client.closed?
  end

  def test_client_callback_registration
    client = Parse::LiveQuery::Client.new(
      url: "wss://test.example.com",
      application_id: "test_app_id",
      client_key: "test_key",
      auto_connect: false,
    )

    callback_called = false
    result = client.on(:open) { callback_called = true }

    assert_equal client, result # chainable
  end

  def test_client_shorthand_callbacks
    client = Parse::LiveQuery::Client.new(
      url: "wss://test.example.com",
      application_id: "test_app_id",
      client_key: "test_key",
      auto_connect: false,
    )

    # These should not raise
    client.on_open { }
    client.on_close { }
    client.on_error { }
  end

  def test_subscription_with_fields
    client = Parse::LiveQuery::Client.new(
      url: "wss://test.example.com",
      application_id: "test_app_id",
      client_key: "test_key",
      auto_connect: false,
    )

    subscription = client.subscribe(
      "User",
      where: { "status" => "active" },
      fields: ["name", "email"],
    )

    assert_equal ["name", "email"], subscription.fields
  end

  def test_subscription_with_session_token
    client = Parse::LiveQuery::Client.new(
      url: "wss://test.example.com",
      application_id: "test_app_id",
      client_key: "test_key",
      auto_connect: false,
    )

    subscription = client.subscribe(
      "PrivateData",
      session_token: "r:user_session_token",
    )

    assert_equal "r:user_session_token", subscription.session_token
  end
end
