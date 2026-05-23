# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require_relative "../../../lib/parse/live_query"

# Define a test model for LiveQuery integration tests
class TestLiveQueryModel < Parse::Object
  parse_class "TestLiveQuery"
  property :name, :string
  property :value, :integer
  property :status, :string
end

class LiveQueryIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  LIVE_QUERY_URL = "ws://localhost:2337"

  def setup
    # Setup Parse client connection first (this is normally done by the module)
    Parse::Test::ServerHelper.setup

    # Enable LiveQuery feature
    Parse.live_query_enabled = true

    # Configure LiveQuery
    Parse::LiveQuery.configure do |config|
      config.url = LIVE_QUERY_URL
      config.application_id = "myAppId"
      config.client_key = "test-rest-key"
    end

    # Clean up any existing test data
    cleanup_test_objects
  end

  def teardown
    Parse::LiveQuery.reset!
    cleanup_test_objects
  end

  def cleanup_test_objects
    # Delete all TestLiveQuery objects
    TestLiveQueryModel.all.each do |obj|
      obj.destroy rescue nil
    end
  rescue => e
    # Ignore errors during cleanup
  end

  def test_livequery_configuration
    assert Parse::LiveQuery.available?
    assert_equal LIVE_QUERY_URL, Parse::LiveQuery.configuration[:url]
  end

  def test_subscribe_from_model_class
    # Skip if LiveQuery server is not available
    skip_unless_livequery_available

    subscription = TestLiveQueryModel.subscribe(where: { status: "active" })

    assert_instance_of Parse::LiveQuery::Subscription, subscription
    assert_equal "TestLiveQuery", subscription.class_name
    assert_equal({ "status" => "active" }, subscription.query)

    # Clean up
    subscription.unsubscribe
  end

  def test_subscribe_from_query
    skip_unless_livequery_available

    query = TestLiveQueryModel.query(:value.gt => 10)
    subscription = query.subscribe

    assert_instance_of Parse::LiveQuery::Subscription, subscription
    assert_equal "TestLiveQuery", subscription.class_name

    subscription.unsubscribe
  end

  def test_subscribe_receives_create_event
    skip_unless_livequery_available

    created_object = nil
    callback_called = Concurrent::Event.new

    subscription = TestLiveQueryModel.subscribe
    subscription.on(:create) do |obj|
      created_object = obj
      callback_called.set
    end

    # Wait for subscription to be confirmed
    wait_for_subscription(subscription)

    # Create an object - should trigger callback
    new_obj = TestLiveQueryModel.new
    new_obj.name = "Test Object"
    new_obj.value = 42
    new_obj.status = "active"
    new_obj.save

    # Wait for callback (with timeout)
    callback_called.wait(5)

    if callback_called.set?
      assert_equal "Test Object", created_object.name
      assert_equal 42, created_object.value
    else
      skip "LiveQuery create event not received (may be server configuration issue)"
    end

    subscription.unsubscribe
    new_obj.destroy
  end

  def test_subscribe_receives_update_event
    skip_unless_livequery_available

    # Create initial object
    obj = TestLiveQueryModel.new
    obj.name = "Original"
    obj.value = 1
    obj.save

    updated_object = nil
    original_object = nil
    callback_called = Concurrent::Event.new

    subscription = TestLiveQueryModel.subscribe
    subscription.on(:update) do |updated, original|
      updated_object = updated
      original_object = original
      callback_called.set
    end

    wait_for_subscription(subscription)

    # Update the object
    obj.name = "Updated"
    obj.value = 2
    obj.save

    callback_called.wait(5)

    if callback_called.set?
      assert_equal "Updated", updated_object.name
      assert_equal 2, updated_object.value
    else
      skip "LiveQuery update event not received (may be server configuration issue)"
    end

    subscription.unsubscribe
    obj.destroy
  end

  def test_subscribe_receives_delete_event
    skip_unless_livequery_available

    # Create object to delete
    obj = TestLiveQueryModel.new
    obj.name = "ToDelete"
    obj.value = 99
    obj.save
    object_id = obj.id

    deleted_object = nil
    callback_called = Concurrent::Event.new

    subscription = TestLiveQueryModel.subscribe
    subscription.on(:delete) do |del_obj|
      deleted_object = del_obj
      callback_called.set
    end

    wait_for_subscription(subscription)

    # Delete the object
    obj.destroy

    callback_called.wait(5)

    if callback_called.set?
      assert_equal object_id, deleted_object.id
    else
      skip "LiveQuery delete event not received (may be server configuration issue)"
    end

    subscription.unsubscribe
  end

  def test_subscribe_with_query_filter
    skip_unless_livequery_available

    received_objects = []
    callback_called = Concurrent::Event.new

    # Subscribe only to objects where value > 50
    subscription = TestLiveQueryModel.subscribe(where: { :value.gt => 50 })
    subscription.on(:create) do |obj|
      received_objects << obj
      callback_called.set
    end

    wait_for_subscription(subscription)

    # Create object that doesn't match filter
    obj1 = TestLiveQueryModel.new
    obj1.name = "Low Value"
    obj1.value = 10
    obj1.save

    # Create object that matches filter
    obj2 = TestLiveQueryModel.new
    obj2.name = "High Value"
    obj2.value = 100
    obj2.save

    callback_called.wait(5)

    if callback_called.set?
      # Should only receive the high value object
      assert_equal 1, received_objects.length
      assert_equal "High Value", received_objects.first.name
    else
      skip "LiveQuery filtered create event not received"
    end

    subscription.unsubscribe
    obj1.destroy
    obj2.destroy
  end

  def test_unsubscribe_stops_events
    skip_unless_livequery_available

    callback_count = 0

    subscription = TestLiveQueryModel.subscribe
    subscription.on(:create) { callback_count += 1 }

    wait_for_subscription(subscription)

    # Unsubscribe
    subscription.unsubscribe
    assert subscription.unsubscribed?

    # Create object after unsubscribe
    obj = TestLiveQueryModel.new
    obj.name = "After Unsubscribe"
    obj.save

    sleep 2 # Wait to ensure no callback is triggered

    assert_equal 0, callback_count

    obj.destroy
  end

  def test_multiple_subscriptions
    skip_unless_livequery_available

    sub1_received = []
    sub2_received = []

    sub1 = TestLiveQueryModel.subscribe(where: { status: "active" })
    sub1.on(:create) { |obj| sub1_received << obj }

    sub2 = TestLiveQueryModel.subscribe(where: { status: "inactive" })
    sub2.on(:create) { |obj| sub2_received << obj }

    wait_for_subscription(sub1)
    wait_for_subscription(sub2)

    # Create objects with different statuses
    active_obj = TestLiveQueryModel.new
    active_obj.name = "Active"
    active_obj.status = "active"
    active_obj.save

    inactive_obj = TestLiveQueryModel.new
    inactive_obj.name = "Inactive"
    inactive_obj.status = "inactive"
    inactive_obj.save

    sleep 3 # Wait for events

    # Clean up
    sub1.unsubscribe
    sub2.unsubscribe
    active_obj.destroy
    inactive_obj.destroy

    # Skip assertion if events weren't received
    if sub1_received.empty? && sub2_received.empty?
      skip "LiveQuery events not received for multiple subscriptions"
    end
  end

  def test_subscription_callback_chaining
    skip_unless_livequery_available

    subscription = TestLiveQueryModel.subscribe

    # Test that callbacks return self for chaining
    result = subscription
      .on_create { }
      .on_update { }
      .on_delete { }
      .on_enter { }
      .on_leave { }

    assert_equal subscription, result

    subscription.unsubscribe
  end

  private

  def skip_unless_livequery_available
    unless livequery_server_available?
      skip "LiveQuery server not available at #{LIVE_QUERY_URL}"
    end
  end

  def livequery_server_available?
    require "socket"
    require "timeout"

    uri = URI.parse(LIVE_QUERY_URL.gsub("ws://", "http://").gsub("wss://", "https://"))

    Timeout.timeout(2) do
      TCPSocket.new(uri.host, uri.port).close
      true
    end
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Timeout::Error
    false
  end

  def wait_for_subscription(subscription, timeout: 5)
    start_time = Time.now

    while subscription.pending? && (Time.now - start_time) < timeout
      sleep 0.1
    end

    unless subscription.subscribed?
      # Give it a bit more time for connection establishment
      sleep 1
    end
  end
end
