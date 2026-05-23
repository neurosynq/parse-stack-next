# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/live_query"

class TestLiveQuerySubscription < Minitest::Test
  extend Minitest::Spec::DSL

  def setup
    # Create a mock client for testing
    @mock_client = Minitest::Mock.new
    @subscription = Parse::LiveQuery::Subscription.new(
      client: @mock_client,
      class_name: "Song",
      query: { "artist" => "Beatles" },
      fields: ["title", "plays"],
      session_token: "r:abc123",
    )
  end

  def test_initialization
    assert_equal "Song", @subscription.class_name
    assert_equal({ "artist" => "Beatles" }, @subscription.query)
    assert_equal ["title", "plays"], @subscription.fields
    assert_equal "r:abc123", @subscription.session_token
    assert_equal :pending, @subscription.state
    refute_nil @subscription.request_id
  end

  def test_state_methods
    assert @subscription.pending?
    refute @subscription.subscribed?
    refute @subscription.unsubscribed?
  end

  def test_callback_registration
    callback_called = false

    result = @subscription.on(:create) { callback_called = true }

    assert_equal @subscription, result # chainable
  end

  def test_shorthand_callback_methods
    # Test that shorthand methods return self for chaining
    result = @subscription
      .on_create { }
      .on_update { }
      .on_delete { }
      .on_enter { }
      .on_leave { }
      .on_error { }
      .on_subscribe { }
      .on_unsubscribe { }

    # All methods should return self for chaining
    assert_equal @subscription, result
  end

  def test_to_subscribe_message
    message = @subscription.to_subscribe_message

    assert_equal "subscribe", message[:op]
    assert_equal @subscription.request_id, message[:requestId]
    assert_equal "Song", message[:query][:className]
    assert_equal({ "artist" => "Beatles" }, message[:query][:where])
    assert_equal ["title", "plays"], message[:query][:fields]
    assert_equal "r:abc123", message[:sessionToken]
  end

  def test_to_subscribe_message_without_optional_fields
    subscription = Parse::LiveQuery::Subscription.new(
      client: @mock_client,
      class_name: "Song",
      query: {},
    )

    message = subscription.to_subscribe_message

    refute message.key?(:sessionToken)
    refute message[:query].key?(:fields)
  end

  def test_to_unsubscribe_message
    message = @subscription.to_unsubscribe_message

    assert_equal "unsubscribe", message[:op]
    assert_equal @subscription.request_id, message[:requestId]
  end

  def test_confirm_changes_state
    subscribe_callback_called = false
    @subscription.on_subscribe { subscribe_callback_called = true }

    @subscription.confirm!

    assert @subscription.subscribed?
    assert subscribe_callback_called
  end

  def test_fail_changes_state
    error_callback_called = false
    error_received = nil
    @subscription.on_error { |e| error_callback_called = true; error_received = e }

    @subscription.fail!("Test error")

    assert_equal :error, @subscription.state
    assert error_callback_called
    assert_instance_of Parse::LiveQuery::SubscriptionError, error_received
  end

  def test_unique_request_ids
    sub1 = Parse::LiveQuery::Subscription.new(client: @mock_client, class_name: "A")
    sub2 = Parse::LiveQuery::Subscription.new(client: @mock_client, class_name: "B")

    refute_equal sub1.request_id, sub2.request_id
  end

  def test_to_h
    hash = @subscription.to_h

    assert_equal @subscription.request_id, hash[:request_id]
    assert_equal "Song", hash[:class_name]
    assert_equal({ "artist" => "Beatles" }, hash[:query])
    assert_equal :pending, hash[:state]
    assert_equal ["title", "plays"], hash[:fields]
  end
end
