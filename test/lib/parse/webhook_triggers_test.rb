require_relative '../../test_helper'
require 'minitest/autorun'

# Test class for webhook testing  
class TestObject < Parse::Object
  property :name
  
  # Override autofetch to prevent client connections in tests
  def autofetch!(*args)
    # No-op in tests
  end
end

class WebhookTriggersTest < Minitest::Test
  
  def setup
    # Clear any existing webhook routes
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    
    # Enable request idempotency for testing
    Parse::Request.enable_idempotency!
    
    # Setup minimal Parse client for testing to prevent connection errors
    Parse.setup(
      server_url: "https://test.parse.com",
      application_id: "test",
      api_key: "test"
    )
  end
  
  def teardown
    # Clean up routes and disable idempotency
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Request.disable_idempotency!
  end
  
  def test_before_save_trigger
    puts "\n=== Testing before_save Trigger ==="
    
    # Track hook execution
    hook_called = false
    hook_payload = nil
    
    # Register before_save hook
    Parse::Webhooks.route(:before_save, "TestObject") do |payload|
      hook_called = true
      hook_payload = payload
      
      obj = parse_object
      obj.name = "Modified by before_save"
      obj
    end
    
    # Test Ruby-initiated before_save
    ruby_payload_data = {
      "triggerName" => "beforeSave",
      "object" => { "className" => "TestObject", "objectId" => "test123", "name" => "original" },
      "headers" => { "x-parse-request-id" => "_RB_before_save_test" }
    }
    
    ruby_payload = Parse::Webhooks::Payload.new(ruby_payload_data)
    result = Parse::Webhooks.call_route(:before_save, "TestObject", ruby_payload)
    
    assert hook_called, "before_save hook should be called"
    assert hook_payload.before_save?, "Payload should identify as before_save"
    assert hook_payload.ruby_initiated?, "Should detect Ruby-initiated request"
    assert result.is_a?(Hash), "before_save should return changes hash"
    puts "✅ before_save hook executed correctly for Ruby request"
    
    # Reset for client test
    hook_called = false
    hook_payload = nil
    
    # Test client-initiated before_save
    client_payload_data = {
      "triggerName" => "beforeSave",
      "object" => { "className" => "TestObject", "objectId" => "test456", "name" => "original" },
      "headers" => { "x-parse-request-id" => "client_before_save_test" }
    }
    
    client_payload = Parse::Webhooks::Payload.new(client_payload_data)
    result = Parse::Webhooks.call_route(:before_save, "TestObject", client_payload)
    
    assert hook_called, "before_save hook should be called for client"
    assert hook_payload.before_save?, "Payload should identify as before_save"
    assert hook_payload.client_initiated?, "Should detect client-initiated request"
    puts "✅ before_save hook executed correctly for client request"
  end
  
  def test_after_save_trigger
    puts "\n=== Testing after_save Trigger ===="
    
    # Track hook execution
    hook_called = false
    hook_payload = nil
    callback_executed = false
    
    # Mock object with callback methods
    test_object = Object.new
    test_object.define_singleton_method(:run_after_save_callbacks) { callback_executed = true }
    test_object.define_singleton_method(:is_a?) { |klass| klass == Parse::Object }
    test_object.define_singleton_method(:name=) { |value| @name = value }
    test_object.define_singleton_method(:name) { @name }
    
    # Register afterSave hook
    Parse::Webhooks.route(:after_save, "TestObject") do |payload|
      hook_called = true
      hook_payload = payload
      true
    end
    
    # Test Ruby-initiated after_save
    ruby_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "after123", "name" => "saved" },
      "original" => { "className" => "TestObject", "objectId" => "after123", "name" => "old" },
      "headers" => { "x-parse-request-id" => "_RB_after_save_test" }
    }
    
    ruby_payload = Parse::Webhooks::Payload.new(ruby_payload_data)
    ruby_payload.define_singleton_method(:parse_object) { test_object }
    ruby_payload.define_singleton_method(:original) { { "name" => "old" } }
    
    result = Parse::Webhooks.call_route(:after_save, "TestObject", ruby_payload)
    
    assert hook_called, "after_save hook should be called"
    assert hook_payload.after_save?, "Payload should identify as after_save"
    assert hook_payload.ruby_initiated?, "Should detect Ruby-initiated request"
    assert callback_executed, "Callbacks should execute for existing object"
    assert_equal true, result, "after_save should return true"
    puts "✅ after_save hook executed correctly for Ruby request"
    
    # Reset for client test
    hook_called = false
    hook_payload = nil
    callback_executed = false
    
    # Test client-initiated after_save (new object)
    client_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "after456", "name" => "new" },
      "original" => nil,  # New object
      "headers" => { "x-parse-request-id" => "client_after_save_test" }
    }
    
    client_payload = Parse::Webhooks::Payload.new(client_payload_data)
    client_payload.define_singleton_method(:parse_object) { test_object }
    client_payload.define_singleton_method(:original) { nil }
    
    # Add after_create callback for new objects
    test_object.define_singleton_method(:run_after_create_callbacks) { callback_executed = true }
    
    result = Parse::Webhooks.call_route(:after_save, "TestObject", client_payload)
    
    assert hook_called, "after_save hook should be called for client"
    assert hook_payload.after_save?, "Payload should identify as after_save"
    assert hook_payload.client_initiated?, "Should detect client-initiated request"
    assert callback_executed, "Callbacks should execute for new client object"
    puts "✅ after_save hook executed correctly for client request"
  end
  
  def test_before_delete_trigger
    puts "\n=== Testing before_delete Trigger ===="
    
    # Track hook execution
    hook_called = false
    hook_payload = nil
    callback_executed = false
    
    # Mock object with callback methods
    test_object = Object.new
    test_object.define_singleton_method(:run_callbacks) { |type, &block| callback_executed = true; block.call if block }
    test_object.define_singleton_method(:is_a?) { |klass| klass == Parse::Object }
    test_object.define_singleton_method(:name=) { |value| @name = value }
    test_object.define_singleton_method(:name) { @name }
    
    # Register beforeDelete hook
    Parse::Webhooks.route(:before_delete, "TestObject") do |payload|
      hook_called = true
      hook_payload = payload
      
      obj = parse_object
      # Return the object to trigger callback handling
      obj
    end
    
    # Test Ruby-initiated before_delete
    ruby_payload_data = {
      "triggerName" => "beforeDelete",
      "object" => { "className" => "TestObject", "objectId" => "delete123", "name" => "to_delete" },
      "headers" => { "x-parse-request-id" => "_RB_before_delete_test" }
    }
    
    ruby_payload = Parse::Webhooks::Payload.new(ruby_payload_data)
    ruby_payload.define_singleton_method(:parse_object) { test_object }
    
    result = Parse::Webhooks.call_route(:before_delete, "TestObject", ruby_payload)
    
    assert hook_called, "before_delete hook should be called"
    assert hook_payload.before_delete?, "Payload should identify as before_delete"
    assert hook_payload.ruby_initiated?, "Should detect Ruby-initiated request"
    assert callback_executed, "Destroy callbacks should execute"
    assert_equal true, result, "before_delete should return true after callback processing"
    puts "✅ before_delete hook executed correctly for Ruby request"
    
    # Reset for client test
    hook_called = false
    hook_payload = nil
    callback_executed = false
    
    # Test client-initiated before_delete
    client_payload_data = {
      "triggerName" => "beforeDelete",
      "object" => { "className" => "TestObject", "objectId" => "delete456", "name" => "to_delete" },
      "headers" => { "x-parse-request-id" => "client_before_delete_test" }
    }
    
    client_payload = Parse::Webhooks::Payload.new(client_payload_data)
    client_payload.define_singleton_method(:parse_object) { test_object }
    
    result = Parse::Webhooks.call_route(:before_delete, "TestObject", client_payload)
    
    assert hook_called, "before_delete hook should be called for client"
    assert hook_payload.before_delete?, "Payload should identify as before_delete"
    assert hook_payload.client_initiated?, "Should detect client-initiated request"
    assert callback_executed, "Destroy callbacks should execute for client"
    puts "✅ before_delete hook executed correctly for client request"
  end
  
  def test_after_delete_trigger
    puts "\n=== Testing after_delete Trigger ===="
    
    # Track hook execution
    hook_called = false
    hook_payload = nil
    
    # Register afterDelete hook
    Parse::Webhooks.route(:after_delete, "TestObject") do |payload|
      hook_called = true
      hook_payload = payload
      
      # Log deletion for audit trail
      if client_initiated?
        puts "Client deleted object: #{payload.parse_id}"
      else
        puts "Ruby deleted object: #{payload.parse_id}"
      end
      
      true
    end
    
    # Test Ruby-initiated after_delete
    ruby_payload_data = {
      "triggerName" => "afterDelete",
      "object" => { "className" => "TestObject", "objectId" => "deleted123", "name" => "was_deleted" },
      "headers" => { "x-parse-request-id" => "_RB_after_delete_test" }
    }
    
    ruby_payload = Parse::Webhooks::Payload.new(ruby_payload_data)
    result = Parse::Webhooks.call_route(:after_delete, "TestObject", ruby_payload)
    
    assert hook_called, "after_delete hook should be called"
    assert hook_payload.after_delete?, "Payload should identify as after_delete"
    assert hook_payload.ruby_initiated?, "Should detect Ruby-initiated request"
    assert_equal "deleted123", hook_payload.parse_id, "Should extract object ID correctly"
    assert_equal true, result, "after_delete should return true"
    puts "✅ after_delete hook executed correctly for Ruby request"
    
    # Reset for client test
    hook_called = false
    hook_payload = nil
    
    # Test client-initiated after_delete
    client_payload_data = {
      "triggerName" => "afterDelete",
      "object" => { "className" => "TestObject", "objectId" => "deleted456", "name" => "was_deleted" },
      "headers" => { "x-parse-request-id" => "client_after_delete_test" }
    }
    
    client_payload = Parse::Webhooks::Payload.new(client_payload_data)
    result = Parse::Webhooks.call_route(:after_delete, "TestObject", client_payload)
    
    assert hook_called, "after_delete hook should be called for client"
    assert hook_payload.after_delete?, "Payload should identify as after_delete"
    assert hook_payload.client_initiated?, "Should detect client-initiated request"
    puts "✅ after_delete hook executed correctly for client request"
  end
  
  def test_before_find_trigger
    puts "\n=== Testing before_find Trigger ===="
    
    # Track hook execution
    hook_called = false
    hook_payload = nil
    
    # Register beforeFind hook
    Parse::Webhooks.route(:before_find, "TestObject") do |payload|
      hook_called = true
      hook_payload = payload
      
      # Modify query constraints
      query = parse_query
      if query && client_initiated?
        # Add client-specific filtering
        query.where(:active => true)
      end
      
      true
    end
    
    # Test Ruby-initiated before_find
    ruby_payload_data = {
      "triggerName" => "beforeFind",
      "className" => "TestObject",
      "query" => { "where" => { "name" => "test" } },
      "headers" => { "x-parse-request-id" => "_RB_before_find_test" }
    }
    
    ruby_payload = Parse::Webhooks::Payload.new(ruby_payload_data)
    ruby_payload.instance_variable_set(:@webhook_class, "TestObject")
    
    result = Parse::Webhooks.call_route(:before_find, "TestObject", ruby_payload)
    
    assert hook_called, "before_find hook should be called"
    assert hook_payload.before_find?, "Payload should identify as before_find"
    assert hook_payload.ruby_initiated?, "Should detect Ruby-initiated request"
    assert_equal "TestObject", hook_payload.parse_class, "Should extract class name correctly"
    assert_equal true, result, "before_find should return true"
    puts "✅ before_find hook executed correctly for Ruby request"
    
    # Reset for client test
    hook_called = false
    hook_payload = nil
    
    # Test client-initiated before_find
    client_payload_data = {
      "triggerName" => "beforeFind",
      "className" => "TestObject", 
      "query" => { "where" => { "category" => "public" } },
      "headers" => { "x-parse-request-id" => "client_before_find_test" }
    }
    
    client_payload = Parse::Webhooks::Payload.new(client_payload_data)
    client_payload.instance_variable_set(:@webhook_class, "TestObject")
    
    result = Parse::Webhooks.call_route(:before_find, "TestObject", client_payload)
    
    assert hook_called, "before_find hook should be called for client"
    assert hook_payload.before_find?, "Payload should identify as before_find"
    assert hook_payload.client_initiated?, "Should detect client-initiated request"
    puts "✅ before_find hook executed correctly for client request"
  end
  
  def test_after_find_trigger
    puts "\n=== Testing after_find Trigger ===="
    
    # Track hook execution
    hook_called = false
    hook_payload = nil
    
    # Register afterFind hook
    Parse::Webhooks.route(:after_find, "TestObject") do |payload|
      hook_called = true
      hook_payload = payload
      
      # Process found objects
      objects = payload.objects || []
      
      if client_initiated?
        # Add client-specific processing
        objects.each do |obj|
          obj["client_processed"] = true if obj.is_a?(Hash)
        end
      end
      
      true
    end
    
    # Test Ruby-initiated after_find
    ruby_payload_data = {
      "triggerName" => "afterFind",
      "className" => "TestObject",
      "objects" => [
        { "className" => "TestObject", "objectId" => "found1", "name" => "result1" },
        { "className" => "TestObject", "objectId" => "found2", "name" => "result2" }
      ],
      "headers" => { "x-parse-request-id" => "_RB_after_find_test" }
    }
    
    ruby_payload = Parse::Webhooks::Payload.new(ruby_payload_data)
    ruby_payload.instance_variable_set(:@webhook_class, "TestObject")
    
    result = Parse::Webhooks.call_route(:after_find, "TestObject", ruby_payload)
    
    assert hook_called, "after_find hook should be called"
    assert hook_payload.after_find?, "Payload should identify as after_find"
    assert hook_payload.ruby_initiated?, "Should detect Ruby-initiated request"
    assert_equal 2, hook_payload.objects.length, "Should have correct number of objects"
    assert_equal "found1", hook_payload.objects.first["objectId"], "Should preserve object data"
    assert_equal true, result, "after_find should return true"
    puts "✅ after_find hook executed correctly for Ruby request"
    
    # Reset for client test
    hook_called = false
    hook_payload = nil
    
    # Test client-initiated after_find
    client_payload_data = {
      "triggerName" => "afterFind",
      "className" => "TestObject",
      "objects" => [
        { "className" => "TestObject", "objectId" => "found3", "name" => "result3" }
      ],
      "headers" => { "x-parse-request-id" => "client_after_find_test" }
    }
    
    client_payload = Parse::Webhooks::Payload.new(client_payload_data)
    client_payload.instance_variable_set(:@webhook_class, "TestObject")
    
    result = Parse::Webhooks.call_route(:after_find, "TestObject", client_payload)
    
    assert hook_called, "after_find hook should be called for client"
    assert hook_payload.after_find?, "Payload should identify as after_find"
    assert hook_payload.client_initiated?, "Should detect client-initiated request"
    assert_equal 1, hook_payload.objects.length, "Should have correct number of objects"
    puts "✅ after_find hook executed correctly for client request"
  end
  
  def test_trigger_identification_methods
    puts "\n=== Testing Trigger Identification Methods ==="
    
    # Test all trigger type identification methods
    trigger_types = [
      { name: "beforeSave", method: :before_save? },
      { name: "afterSave", method: :after_save? },
      { name: "beforeDelete", method: :before_delete? },
      { name: "afterDelete", method: :after_delete? },
      { name: "beforeFind", method: :before_find? },
      { name: "afterFind", method: :after_find? }
    ]
    
    trigger_types.each do |trigger_info|
      payload_data = {
        "triggerName" => trigger_info[:name],
        "object" => { "className" => "TestObject", "objectId" => "test123" }
      }
      
      payload = Parse::Webhooks::Payload.new(payload_data)
      
      # Check that only the correct method returns true
      trigger_types.each do |check_info|
        if check_info[:name] == trigger_info[:name]
          assert payload.send(check_info[:method]), "#{check_info[:method]} should return true for #{trigger_info[:name]}"
        else
          refute payload.send(check_info[:method]), "#{check_info[:method]} should return false for #{trigger_info[:name]}"
        end
      end
      
      puts "✓ #{trigger_info[:name]} identification works correctly"
    end
    
    # Test before_trigger? and after_trigger? helper methods
    before_triggers = ["beforeSave", "beforeDelete", "beforeFind"]
    after_triggers = ["afterSave", "afterDelete", "afterFind"]
    
    before_triggers.each do |trigger_name|
      payload = Parse::Webhooks::Payload.new("triggerName" => trigger_name)
      assert payload.before_trigger?, "#{trigger_name} should be identified as before_trigger"
      refute payload.after_trigger?, "#{trigger_name} should not be identified as after_trigger"
    end
    
    after_triggers.each do |trigger_name|
      payload = Parse::Webhooks::Payload.new("triggerName" => trigger_name)
      assert payload.after_trigger?, "#{trigger_name} should be identified as after_trigger"
      refute payload.before_trigger?, "#{trigger_name} should not be identified as before_trigger"
    end
    
    puts "✅ Trigger identification helper methods work correctly"
  end
  
  def test_multiple_trigger_hooks
    puts "\n=== Testing Multiple Trigger Hooks ==="
    
    # Track execution order
    execution_order = []
    
    # Register multiple after_save hooks (supports arrays)
    Parse::Webhooks.route(:after_save, "TestObject") do |payload|
      execution_order << "hook1"
      true
    end
    
    Parse::Webhooks.route(:after_save, "TestObject") do |payload|
      execution_order << "hook2"
      true
    end
    
    # Test multiple hooks execution
    payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "multi123" },
      "headers" => { "x-parse-request-id" => "_RB_multi_test" }
    }
    
    payload = Parse::Webhooks::Payload.new(payload_data)
    payload.define_singleton_method(:parse_object) { nil }  # Skip callback logic
    
    result = Parse::Webhooks.call_route(:after_save, "TestObject", payload)
    
    assert_equal ["hook1", "hook2"], execution_order, "Both hooks should execute in order"
    assert_equal true, result, "Should return result from last hook"
    puts "✅ Multiple after_save hooks execute correctly"
    
    # Test that before_save only supports single hook (overwrites)
    execution_order.clear
    
    Parse::Webhooks.route(:before_save, "TestObject") do |payload|
      execution_order << "before1"
      true
    end
    
    Parse::Webhooks.route(:before_save, "TestObject") do |payload|
      execution_order << "before2"
      true
    end
    
    before_payload_data = {
      "triggerName" => "beforeSave",
      "object" => { "className" => "TestObject", "objectId" => "single123" }
    }
    
    before_payload = Parse::Webhooks::Payload.new(before_payload_data)
    result = Parse::Webhooks.call_route(:before_save, "TestObject", before_payload)
    
    assert_equal ["before2"], execution_order, "Only the last before_save hook should execute"
    puts "✅ Single before_save hook behavior works correctly"
  end
  
  def test_trigger_error_handling
    puts "\n=== Testing Trigger Error Handling ==="
    
    # Register hook that raises an error
    Parse::Webhooks.route(:before_save, "TestObject") do |payload|
      if client_initiated?
        error!("Client validation failed")
      end
      
      obj = parse_object
      obj.name = "processed"
      obj
    end
    
    # Test Ruby request (should not error)
    ruby_payload_data = {
      "triggerName" => "beforeSave",
      "object" => { "className" => "TestObject", "objectId" => "error123" },
      "headers" => { "x-parse-request-id" => "_RB_error_test" }
    }
    
    ruby_payload = Parse::Webhooks::Payload.new(ruby_payload_data)
    
    # Should not raise error for Ruby request
    result = Parse::Webhooks.call_route(:before_save, "TestObject", ruby_payload)
    assert result.is_a?(Hash), "Ruby request should succeed"
    puts "✅ Ruby request bypasses client validation"
    
    # Test client request (should raise error when called through full webhook stack)
    client_payload_data = {
      "triggerName" => "beforeSave", 
      "object" => { "className" => "TestObject", "objectId" => "error456" },
      "headers" => { "x-parse-request-id" => "client_error_test" }
    }
    
    client_payload = Parse::Webhooks::Payload.new(client_payload_data)
    
    # Direct call_route won't raise the error, but the error! method would be called
    # This tests that the conditional logic works correctly
    begin
      result = Parse::Webhooks.call_route(:before_save, "TestObject", client_payload)
      flunk "Should have raised ResponseError for client request"
    rescue Parse::Webhooks::ResponseError => e
      assert_equal "Client validation failed", e.message, "Should have correct error message"
      puts "✅ Client request properly raises validation error"
    end
  end
  
  def test_wildcard_trigger_routing
    puts "\n=== Testing Wildcard Trigger Routing ==="
    
    # Track executions
    specific_called = false
    wildcard_called = false
    
    # Register specific class hook
    Parse::Webhooks.route(:after_save, "TestObject") do |payload|
      specific_called = true
      true
    end
    
    # Register wildcard hook (for any class)
    Parse::Webhooks.route(:after_save, "*") do |payload|
      wildcard_called = true
      true
    end
    
    # Test specific class - should call specific hook
    payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "wildcard123" }
    }
    
    payload = Parse::Webhooks::Payload.new(payload_data)
    payload.define_singleton_method(:parse_object) { nil }
    
    result = Parse::Webhooks.call_route(:after_save, "TestObject", payload)
    
    assert specific_called, "Specific hook should be called"
    refute wildcard_called, "Wildcard hook should not be called when specific exists"
    puts "✅ Specific class hook takes precedence"
    
    # Reset and test unknown class - should call wildcard
    specific_called = false
    wildcard_called = false
    
    unknown_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "UnknownClass", "objectId" => "unknown123" }
    }
    
    unknown_payload = Parse::Webhooks::Payload.new(unknown_payload_data)
    unknown_payload.define_singleton_method(:parse_object) { nil }
    
    # First try specific route (should be nil)
    result = Parse::Webhooks.call_route(:after_save, "UnknownClass", unknown_payload)
    assert_nil result, "No specific route should exist"
    
    # Then try wildcard route
    result = Parse::Webhooks.call_route(:after_save, "*", unknown_payload)
    
    refute specific_called, "Specific hook should not be called"
    assert wildcard_called, "Wildcard hook should be called for unknown class"
    puts "✅ Wildcard hook works for unregistered classes"
  end
end