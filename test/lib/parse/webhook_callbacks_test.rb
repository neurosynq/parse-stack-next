require_relative "../../test_helper"
require "minitest/autorun"

class WebhookCallbacksTest < Minitest::Test
  def setup
    # Clear any existing webhook routes
    Parse::Webhooks.instance_variable_set(:@routes, nil)

    # Enable request idempotency for testing
    Parse::Request.enable_idempotency!
  end

  def teardown
    # Clean up routes and disable idempotency
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Request.disable_idempotency!
  end

  def test_payload_ruby_initiated_detection
    puts "\n=== Testing Payload Ruby Initiated Detection ==="

    # Test Ruby-initiated payload
    ruby_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "abc123" },
      "headers" => { "x-parse-request-id" => "_RB_550e8400-e29b-41d4-a716-446655440000" },
    }

    ruby_payload = Parse::Webhooks::Payload.new(ruby_payload_data)
    assert ruby_payload.ruby_initiated?, "Should detect Ruby-initiated request"
    refute ruby_payload.client_initiated?, "Should not be client-initiated"
    puts "✅ Ruby-initiated payload detected correctly"

    # Test client-initiated payload
    client_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "def456" },
      "headers" => { "x-parse-request-id" => "client-550e8400-e29b-41d4-a716-446655440000" },
    }

    client_payload = Parse::Webhooks::Payload.new(client_payload_data)
    refute client_payload.ruby_initiated?, "Should not detect Ruby-initiated request"
    assert client_payload.client_initiated?, "Should be client-initiated"
    puts "✅ Client-initiated payload detected correctly"

    # Test payload without request ID
    no_id_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "ghi789" },
    }

    no_id_payload = Parse::Webhooks::Payload.new(no_id_payload_data)
    refute no_id_payload.ruby_initiated?, "Should not detect Ruby-initiated without request ID"
    assert no_id_payload.client_initiated?, "Should be client-initiated by default"
    puts "✅ Payload without request ID handled correctly"

    # Test different header case variations
    header_variations = [
      { "x-parse-request-id" => "_RB_test1" },
      { "X-Parse-Request-Id" => "_RB_test2" },
      { "headers" => { "x-parse-request-id" => "_RB_test3" } },
      { "headers" => { "X-Parse-Request-Id" => "_RB_test4" } },
    ]

    header_variations.each_with_index do |headers, index|
      payload_data = {
        "triggerName" => "afterSave",
        "object" => { "className" => "TestObject", "objectId" => "test#{index}" },
      }.merge(headers)

      payload = Parse::Webhooks::Payload.new(payload_data)
      assert payload.ruby_initiated?, "Header variation #{index + 1} should be detected"
      puts "✓ Header variation #{index + 1} detected correctly"
    end
  end

  def test_before_save_callback_handling
    puts "\n=== Testing Before Save Callback Handling ==="

    # Track callback invocations
    prepare_save_called = false

    # Mock Parse::Object with prepare_save! method
    test_object = Object.new
    test_object.define_singleton_method(:prepare_save!) { prepare_save_called = true }
    test_object.define_singleton_method(:changes_payload) { { "name" => "test" } }
    test_object.define_singleton_method(:is_a?) { |klass| klass == Parse::Object }

    # Register a before_save webhook that returns the object
    Parse::Webhooks.route(:before_save, "TestObject") do |payload|
      test_object
    end

    # Test Ruby-initiated before_save (should skip prepare_save!)
    ruby_payload_data = {
      "triggerName" => "beforeSave",
      "object" => { "className" => "TestObject", "objectId" => "abc123" },
      "headers" => { "x-parse-request-id" => "_RB_test_request_id" },
    }

    ruby_payload = Parse::Webhooks::Payload.new(ruby_payload_data)
    result = Parse::Webhooks.call_route(:before_save, "TestObject", ruby_payload)

    refute prepare_save_called, "prepare_save! should not be called for Ruby-initiated requests"
    assert_equal({ "name" => "test" }, result, "Should return changes payload")
    puts "✅ Ruby-initiated before_save skips prepare_save!"

    # Reset tracking
    prepare_save_called = false

    # Test client-initiated before_save (should call prepare_save!)
    client_payload_data = {
      "triggerName" => "beforeSave",
      "object" => { "className" => "TestObject", "objectId" => "def456" },
      "headers" => { "x-parse-request-id" => "client_request_id" },
    }

    client_payload = Parse::Webhooks::Payload.new(client_payload_data)
    result = Parse::Webhooks.call_route(:before_save, "TestObject", client_payload)

    assert prepare_save_called, "prepare_save! should be called for client-initiated requests"
    assert_equal({ "name" => "test" }, result, "Should return changes payload")
    puts "✅ Client-initiated before_save calls prepare_save!"
  end

  def test_after_save_callback_handling
    puts "\n=== Testing After Save Callback Handling ==="

    # Track callback invocations
    after_create_called = false
    after_save_called = false

    # Mock Parse::Object with callback methods
    test_object = Object.new
    test_object.define_singleton_method(:run_after_create_callbacks) { after_create_called = true }
    test_object.define_singleton_method(:run_after_save_callbacks) { after_save_called = true }
    test_object.define_singleton_method(:is_a?) { |klass| klass == Parse::Object }

    # Register an after_save webhook that returns true/nil
    Parse::Webhooks.route(:after_save, "TestObject") do |payload|
      true  # or nil, both should trigger callback handling
    end

    # Test 1: Ruby-initiated new object (should skip both callbacks)
    puts "\n--- Test 1: Ruby-initiated new object ---"

    ruby_new_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "new123" },
      "original" => nil,  # indicates new object
      "headers" => { "x-parse-request-id" => "_RB_new_object_test" },
    }

    ruby_new_payload = Parse::Webhooks::Payload.new(ruby_new_payload_data)
    ruby_new_payload.define_singleton_method(:parse_object) { test_object }
    ruby_new_payload.define_singleton_method(:original) { nil }

    result = Parse::Webhooks.call_route(:after_save, "TestObject", ruby_new_payload)

    refute after_create_called, "after_create should not be called for Ruby-initiated new objects"
    refute after_save_called, "after_save should not be called for Ruby-initiated new objects"
    assert_equal true, result, "Should return true"
    puts "✅ Ruby-initiated new object skips callbacks"

    # Reset tracking
    after_create_called = false
    after_save_called = false

    # Test 2: Client-initiated new object (should call after_create)
    puts "\n--- Test 2: Client-initiated new object ---"

    client_new_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "client_new123" },
      "original" => nil,  # indicates new object
      "headers" => { "x-parse-request-id" => "client_new_object_test" },
    }

    client_new_payload = Parse::Webhooks::Payload.new(client_new_payload_data)
    client_new_payload.define_singleton_method(:parse_object) { test_object }
    client_new_payload.define_singleton_method(:original) { nil }

    result = Parse::Webhooks.call_route(:after_save, "TestObject", client_new_payload)

    assert after_create_called, "after_create should be called for client-initiated new objects"
    assert after_save_called, "after_save should be called for client-initiated new objects"
    assert_equal true, result, "Should return true"
    puts "✅ Client-initiated new object calls callbacks"

    # Reset tracking
    after_create_called = false
    after_save_called = false

    # Test 3: Ruby-initiated existing object (should skip after_save)
    puts "\n--- Test 3: Ruby-initiated existing object ---"

    ruby_existing_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "existing123" },
      "original" => { "className" => "TestObject", "objectId" => "existing123", "name" => "old" },
      "headers" => { "x-parse-request-id" => "_RB_existing_object_test" },
    }

    ruby_existing_payload = Parse::Webhooks::Payload.new(ruby_existing_payload_data)
    ruby_existing_payload.define_singleton_method(:parse_object) { test_object }
    ruby_existing_payload.define_singleton_method(:original) { { "name" => "old" } }

    result = Parse::Webhooks.call_route(:after_save, "TestObject", ruby_existing_payload)

    refute after_create_called, "after_create should not be called for existing objects"
    assert after_save_called, "after_save should be called for Ruby-initiated existing objects"
    assert_equal true, result, "Should return true"
    puts "✅ Ruby-initiated existing object calls after_save only"

    # Reset tracking
    after_create_called = false
    after_save_called = false

    # Test 4: Client-initiated existing object (should call after_save)
    puts "\n--- Test 4: Client-initiated existing object ---"

    client_existing_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "client_existing123" },
      "original" => { "className" => "TestObject", "objectId" => "client_existing123", "name" => "old" },
      "headers" => { "x-parse-request-id" => "client_existing_object_test" },
    }

    client_existing_payload = Parse::Webhooks::Payload.new(client_existing_payload_data)
    client_existing_payload.define_singleton_method(:parse_object) { test_object }
    client_existing_payload.define_singleton_method(:original) { { "name" => "old" } }

    result = Parse::Webhooks.call_route(:after_save, "TestObject", client_existing_payload)

    refute after_create_called, "after_create should not be called for existing objects"
    assert after_save_called, "after_save should be called for client-initiated existing objects"
    assert_equal true, result, "Should return true"
    puts "✅ Client-initiated existing object calls after_save"
  end

  def test_webhook_integration_with_request_idempotency
    puts "\n=== Testing Webhook Integration with Request Idempotency ==="

    # Simulate the full flow: Ruby request -> Parse Server -> Webhook

    # Create a Ruby request with idempotency
    request = Parse::Request.new(:post, "/classes/TestObject",
                                 body: { name: "test object" })
    request.with_idempotency

    # Verify request has the _RB_ prefix
    assert request.idempotent?, "Request should be idempotent"
    assert request.request_id.start_with?("_RB_"), "Request ID should have Ruby prefix"
    request_id = request.request_id
    puts "✓ Ruby request has proper request ID: #{request_id}"

    # Simulate Parse Server forwarding this request ID to webhook
    webhook_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "webhook123", "name" => "test object" },
      "original" => nil,
      "headers" => { "x-parse-request-id" => request_id },
    }

    webhook_payload = Parse::Webhooks::Payload.new(webhook_payload_data)

    # Verify webhook correctly identifies this as Ruby-initiated
    assert webhook_payload.ruby_initiated?, "Webhook should detect Ruby-initiated request"
    puts "✓ Webhook correctly identifies Ruby-initiated request"

    # Test callback coordination
    callback_called = false

    test_object = Object.new
    test_object.define_singleton_method(:run_after_create_callbacks) { callback_called = true }
    test_object.define_singleton_method(:run_after_save_callbacks) { callback_called = true }
    test_object.define_singleton_method(:is_a?) { |klass| klass == Parse::Object }

    Parse::Webhooks.route(:after_save, "TestObject") { true }

    webhook_payload.define_singleton_method(:parse_object) { test_object }
    webhook_payload.define_singleton_method(:original) { nil }

    result = Parse::Webhooks.call_route(:after_save, "TestObject", webhook_payload)

    refute callback_called, "Ruby callbacks should not be called for Ruby-initiated webhook"
    assert_equal true, result, "Webhook should still return success"
    puts "✓ Ruby-initiated webhook skips redundant callbacks"

    # Test client request scenario
    client_webhook_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "client123", "name" => "client object" },
      "original" => nil,
      "headers" => { "x-parse-request-id" => "js_client_12345" },  # No _RB_ prefix
    }

    client_webhook_payload = Parse::Webhooks::Payload.new(client_webhook_data)
    client_webhook_payload.define_singleton_method(:parse_object) { test_object }
    client_webhook_payload.define_singleton_method(:original) { nil }

    callback_called = false
    result = Parse::Webhooks.call_route(:after_save, "TestObject", client_webhook_payload)

    assert callback_called, "Ruby callbacks should be called for client-initiated webhook"
    assert_equal true, result, "Webhook should return success"
    puts "✓ Client-initiated webhook triggers Ruby callbacks"
  end

  def test_edge_cases_and_error_handling
    puts "\n=== Testing Edge Cases and Error Handling ==="

    # Test payload with malformed headers
    malformed_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "malformed123" },
      "headers" => "not a hash",
    }

    malformed_payload = Parse::Webhooks::Payload.new(malformed_payload_data)
    refute malformed_payload.ruby_initiated?, "Should handle malformed headers gracefully"
    puts "✓ Malformed headers handled gracefully"

    # Test payload with nil raw data
    nil_payload = Parse::Webhooks::Payload.new({})
    refute nil_payload.ruby_initiated?, "Should handle nil raw data gracefully"
    puts "✓ Nil raw data handled gracefully"

    # Test request ID that's close but not exactly _RB_
    almost_rb_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "almost123" },
      "headers" => { "x-parse-request-id" => "RB_test" },  # Missing underscore
    }

    almost_rb_payload = Parse::Webhooks::Payload.new(almost_rb_payload_data)
    refute almost_rb_payload.ruby_initiated?, "Should not match similar but incorrect prefixes"
    puts "✓ Similar but incorrect prefixes handled correctly"

    # Test empty request ID
    empty_id_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "empty123" },
      "headers" => { "x-parse-request-id" => "" },
    }

    empty_id_payload = Parse::Webhooks::Payload.new(empty_id_payload_data)
    refute empty_id_payload.ruby_initiated?, "Should handle empty request ID gracefully"
    puts "✓ Empty request ID handled gracefully"

    # Test webhook without payload
    result = Parse::Webhooks.call_route(:after_save, "TestObject", nil)
    assert_nil result, "Should handle nil payload gracefully"
    puts "✓ Nil payload handled gracefully"
  end

  def test_multiple_webhook_handlers
    puts "\n=== Testing Multiple Webhook Handlers ==="

    # Register multiple after_save handlers
    call_order = []

    Parse::Webhooks.route(:after_save, "TestObject") do |payload|
      call_order << "handler1_#{payload.ruby_initiated? ? "ruby" : "client"}"
      true
    end

    Parse::Webhooks.route(:after_save, "TestObject") do |payload|
      call_order << "handler2_#{payload.ruby_initiated? ? "ruby" : "client"}"
      true
    end

    # Test Ruby-initiated request
    ruby_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "multi123" },
      "headers" => { "x-parse-request-id" => "_RB_multi_test" },
    }

    ruby_payload = Parse::Webhooks::Payload.new(ruby_payload_data)
    ruby_payload.define_singleton_method(:parse_object) { nil }  # No parse_object to avoid callback logic

    result = Parse::Webhooks.call_route(:after_save, "TestObject", ruby_payload)

    assert_equal ["handler1_ruby", "handler2_ruby"], call_order, "Both handlers should execute with correct ruby flag"
    assert_equal true, result, "Should return result from last handler"
    puts "✓ Multiple handlers execute with correct ruby_initiated flag"

    # Reset and test client-initiated request
    call_order.clear()

    client_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "multi456" },
      "headers" => { "x-parse-request-id" => "client_multi_test" },
    }

    client_payload = Parse::Webhooks::Payload.new(client_payload_data)
    client_payload.define_singleton_method(:parse_object) { nil }

    result = Parse::Webhooks.call_route(:after_save, "TestObject", client_payload)

    assert_equal ["handler1_client", "handler2_client"], call_order, "Both handlers should execute with correct client flag"
    assert_equal true, result, "Should return result from last handler"
    puts "✓ Multiple handlers execute with correct client_initiated flag"
  end
end
