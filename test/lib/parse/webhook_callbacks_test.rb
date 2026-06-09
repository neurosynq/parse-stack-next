require_relative "../../test_helper"
require "minitest/autorun"
require "stringio"

# Real Parse::Object model for the run_after_save_chain tests. A class-level
# counter records how many times the chained ActiveModel after_save callback
# fired, so a double-fire (or a fire when no route is registered) is visible.
class WebhookChainModel < Parse::Object
  parse_class "WebhookChainModel"

  class << self
    attr_accessor :after_save_count
  end
  self.after_save_count = 0

  after_save :bump_after_save
  def bump_after_save
    self.class.after_save_count += 1
  end
end

# Real model whose chained after_create / after_save callbacks can be made to
# raise, to exercise the throw-mid-chain containment in run_after_save_chain.
# Each callback increments its counter BEFORE (optionally) raising, so a test
# can assert the callback actually ran.
class WebhookRaisingModel < Parse::Object
  parse_class "WebhookRaisingModel"

  class << self
    attr_accessor :after_create_count, :after_save_count, :raise_on
  end
  self.after_create_count = 0
  self.after_save_count = 0
  self.raise_on = nil # nil, :after_create, or :after_save

  after_create :on_after_create
  after_save :on_after_save

  def on_after_create
    self.class.after_create_count += 1
    raise "boom in after_create" if self.class.raise_on == :after_create
  end

  def on_after_save
    self.class.after_save_count += 1
    raise "boom in after_save" if self.class.raise_on == :after_save
  end
end

# Real model with TWO after_save callbacks that BOTH raise, plus an after_create
# probe. Used to prove the containment is at the *chain* level (ActiveModel halts
# the rest of the phase once a callback raises) rather than a per-callback wrap:
# exactly one of the two after_save callbacks should run, not both. Order-agnostic
# (whichever ActiveModel runs first raises and halts the other).
class WebhookHaltModel < Parse::Object
  parse_class "WebhookHaltModel"

  class << self
    attr_accessor :after_save_ran, :after_create_ran
  end
  self.after_save_ran = []
  self.after_create_ran = 0

  after_create :note_create
  after_save :cb_one
  after_save :cb_two

  def note_create
    self.class.after_create_ran += 1
  end

  def cb_one
    self.class.after_save_ran << :one
    raise "boom in cb_one"
  end

  def cb_two
    self.class.after_save_ran << :two
    raise "boom in cb_two"
  end
end

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
    before_save_called = false
    before_create_called = false

    # Mock Parse::Object with the before-phase callback runners the dispatcher
    # invokes (run_before_save_callbacks always; run_before_create_callbacks for
    # new objects -- original.nil?).
    test_object = Object.new
    test_object.define_singleton_method(:run_before_save_callbacks) { before_save_called = true }
    test_object.define_singleton_method(:run_before_create_callbacks) { before_create_called = true }
    test_object.define_singleton_method(:changes_payload) { { "name" => "test" } }
    test_object.define_singleton_method(:is_a?) { |klass| klass == Parse::Object }

    # Register a before_save webhook that returns the object
    Parse::Webhooks.route(:before_save, "TestObject") do |payload|
      test_object
    end

    # Test Ruby-initiated before_save (should skip the before callbacks).
    # A "trusted" Ruby-initiated request requires both the _RB_ header AND
    # master:true. The header alone is client-controllable; honoring it
    # without master would let a non-master client spoof the bypass.
    ruby_payload_data = {
      "triggerName" => "beforeSave",
      "master" => true,
      "object" => { "className" => "TestObject", "objectId" => "abc123" },
      "headers" => { "x-parse-request-id" => "_RB_test_request_id" },
    }

    ruby_payload = Parse::Webhooks::Payload.new(ruby_payload_data)
    result = Parse::Webhooks.call_route(:before_save, "TestObject", ruby_payload)

    refute before_save_called, "before_save callbacks should not run for Ruby-initiated requests"
    refute before_create_called, "before_create callbacks should not run for Ruby-initiated requests"
    assert_equal({ "name" => "test" }, result, "Should return changes payload")
    puts "✅ Ruby-initiated before_save skips before callbacks"

    # Reset tracking
    before_save_called = false
    before_create_called = false

    # Test client-initiated before_save on a NEW object (no original): both
    # before_save AND before_create run, since Parse Server has no separate
    # beforeCreate trigger.
    client_payload_data = {
      "triggerName" => "beforeSave",
      "object" => { "className" => "TestObject", "objectId" => "def456" },
      "headers" => { "x-parse-request-id" => "client_request_id" },
    }

    client_payload = Parse::Webhooks::Payload.new(client_payload_data)
    result = Parse::Webhooks.call_route(:before_save, "TestObject", client_payload)

    assert before_save_called, "before_save callbacks should run for client-initiated requests"
    assert before_create_called, "before_create callbacks should run for a client-initiated create"
    assert_equal({ "name" => "test" }, result, "Should return changes payload")
    puts "✅ Client-initiated before_save runs before_save + before_create"

    # Reset tracking
    before_save_called = false
    before_create_called = false

    # Client-initiated before_save on an UPDATE (original present): before_save
    # runs, before_create does NOT (not a create).
    update_payload_data = {
      "triggerName" => "beforeSave",
      "object" => { "className" => "TestObject", "objectId" => "def456", "name" => "new" },
      "original" => { "className" => "TestObject", "objectId" => "def456", "name" => "old" },
      "headers" => { "x-parse-request-id" => "client_update_id" },
    }
    update_payload = Parse::Webhooks::Payload.new(update_payload_data)
    Parse::Webhooks.call_route(:before_save, "TestObject", update_payload)

    assert before_save_called, "before_save callbacks should run on a client update"
    refute before_create_called, "before_create callbacks must NOT run on an update"
    puts "✅ Client-initiated before_save on update skips before_create"
  end

  # The chained ActiveModel after_save/after_create callbacks no longer fire
  # inside call_route -- the dispatch moved to Parse::Webhooks.run_after_save_chain,
  # which call! invokes exactly once per delivery (after both the class route and
  # the "*" route). So callback-firing assertions drive run_after_save_chain
  # directly; result-normalization assertions still drive call_route.
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
      "master" => true, # required alongside _RB_ for trusted Ruby-initiated
      "object" => { "className" => "TestObject", "objectId" => "new123" },
      "original" => nil,  # indicates new object
      "headers" => { "x-parse-request-id" => "_RB_new_object_test" },
    }

    ruby_new_payload = Parse::Webhooks::Payload.new(ruby_new_payload_data)
    ruby_new_payload.define_singleton_method(:parse_object) { test_object }
    ruby_new_payload.define_singleton_method(:original) { nil }

    result = Parse::Webhooks.call_route(:after_save, "TestObject", ruby_new_payload)
    Parse::Webhooks.run_after_save_chain(ruby_new_payload)

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
    Parse::Webhooks.run_after_save_chain(client_new_payload)

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
      "master" => true, # required alongside _RB_ for trusted Ruby-initiated
      "object" => { "className" => "TestObject", "objectId" => "existing123" },
      "original" => { "className" => "TestObject", "objectId" => "existing123", "name" => "old" },
      "headers" => { "x-parse-request-id" => "_RB_existing_object_test" },
    }

    ruby_existing_payload = Parse::Webhooks::Payload.new(ruby_existing_payload_data)
    ruby_existing_payload.define_singleton_method(:parse_object) { test_object }
    ruby_existing_payload.define_singleton_method(:original) { { "name" => "old" } }

    result = Parse::Webhooks.call_route(:after_save, "TestObject", ruby_existing_payload)
    Parse::Webhooks.run_after_save_chain(ruby_existing_payload)

    refute after_create_called, "after_create should not be called for existing objects"
    # Previously this asserted after_save WAS called, which was a bug: a
    # ruby-initiated update would also fire after_save callbacks in the
    # webhook on top of the local `run_callbacks :save` -- effectively
    # sending two emails for an `after_save :send_email`. The framework
    # now skips run_after_save_callbacks for all trusted-ruby-initiated
    # saves regardless of is_new.
    refute after_save_called, "after_save must NOT be called for Ruby-initiated existing objects (Ruby will fire it locally)"
    assert_equal true, result, "Should return true"
    puts "✅ Ruby-initiated existing object skips both webhook callbacks"

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
    Parse::Webhooks.run_after_save_chain(client_existing_payload)

    refute after_create_called, "after_create should not be called for existing objects"
    assert after_save_called, "after_save should be called for client-initiated existing objects"
    assert_equal true, result, "Should return true"
    puts "✅ Client-initiated existing object calls after_save"
  end

  def test_after_save_handler_returning_object_still_fires_callbacks
    puts "\n=== Testing After Save Callback Handling (handler returns object) ==="

    # Regression: Parse Server discards the afterSave response body, so the
    # handler's return value must NOT gate callback dispatch. A handler that
    # returns the parse_object (the recommended before_save pattern, easy to
    # copy by mistake) must still fire the model's after_create/after_save
    # callbacks for client-initiated saves, and the result must normalize to
    # `true` so the object never leaks into the response/log.
    after_create_called = false
    after_save_called = false

    test_object = Object.new
    test_object.define_singleton_method(:run_after_create_callbacks) { after_create_called = true }
    test_object.define_singleton_method(:run_after_save_callbacks) { after_save_called = true }
    test_object.define_singleton_method(:is_a?) { |klass| klass == Parse::Object }

    # Handler returns the object instead of true/nil (the mistake we now tolerate).
    Parse::Webhooks.route(:after_save, "TestObject") do |payload|
      payload.parse_object
    end

    # Client-initiated new object: both callbacks must fire despite the object return.
    client_new_payload_data = {
      "triggerName" => "afterSave",
      "object" => { "className" => "TestObject", "objectId" => "obj_return_new" },
      "original" => nil,
      "headers" => { "x-parse-request-id" => "client_obj_return_new" },
    }
    client_new_payload = Parse::Webhooks::Payload.new(client_new_payload_data)
    client_new_payload.define_singleton_method(:parse_object) { test_object }
    client_new_payload.define_singleton_method(:original) { nil }

    result = Parse::Webhooks.call_route(:after_save, "TestObject", client_new_payload)
    Parse::Webhooks.run_after_save_chain(client_new_payload)

    assert after_create_called, "after_create must fire even when handler returns the object"
    assert after_save_called, "after_save must fire even when handler returns the object"
    assert_equal true, result, "Result must normalize to true so the object never leaks into the response"
    refute_kind_of Parse::Object, result, "Returned object must not leak into the response body"
    puts "✅ Object-returning handler still fires client-initiated callbacks and normalizes result"

    # Trusted-ruby-initiated object: still skips webhook callbacks (Ruby fires them locally),
    # and still normalizes the result regardless of the object return.
    after_create_called = false
    after_save_called = false

    ruby_payload_data = {
      "triggerName" => "afterSave",
      "master" => true,
      "object" => { "className" => "TestObject", "objectId" => "obj_return_ruby" },
      "original" => nil,
      "headers" => { "x-parse-request-id" => "_RB_obj_return_ruby" },
    }
    ruby_payload = Parse::Webhooks::Payload.new(ruby_payload_data)
    ruby_payload.define_singleton_method(:parse_object) { test_object }
    ruby_payload.define_singleton_method(:original) { nil }

    result = Parse::Webhooks.call_route(:after_save, "TestObject", ruby_payload)
    Parse::Webhooks.run_after_save_chain(ruby_payload)

    refute after_create_called, "after_create must stay suppressed for trusted-ruby-initiated saves"
    refute after_save_called, "after_save must stay suppressed for trusted-ruby-initiated saves"
    assert_equal true, result, "Result must normalize to true even for the trusted-ruby path"
    puts "✅ Trusted-ruby-initiated handler keeps suppression and normalizes result"
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
      "master" => true, # trusted Ruby-initiated requires master alongside _RB_
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
    Parse::Webhooks.run_after_save_chain(webhook_payload)

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
    Parse::Webhooks.run_after_save_chain(client_webhook_payload)

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

  # The chain must honor the "unregistered afterSave trigger never fires model
  # callbacks" contract that call_route's early `return unless routes[...]`
  # provided. With the firing moved into run_after_save_chain, this guard is
  # the load-bearing correctness check: without it, every afterSave delivery
  # for a class with no registered handler would start firing the model's
  # callbacks.
  def test_run_after_save_chain_does_not_fire_without_a_registered_route
    puts "\n=== Testing run_after_save_chain route-present guard ==="

    WebhookChainModel.after_save_count = 0

    # No after_save route registered for WebhookChainModel (or "*").
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "afterSave",
      "object" => { "className" => "WebhookChainModel", "objectId" => "noroute1" },
    )
    assert_kind_of Parse::Object, payload.parse_object, "sanity: payload builds a real object"

    Parse::Webhooks.run_after_save_chain(payload)

    assert_equal 0, WebhookChainModel.after_save_count,
                 "model after_save must NOT fire when no afterSave route is registered"
    puts "✓ No registered route => no model callbacks"

    # Registering a "*" route is enough to satisfy the guard (client-initiated,
    # so not suppressed) and the chain fires exactly once.
    Parse::Webhooks.route(:after_save, "*") { true }
    Parse::Webhooks.run_after_save_chain(payload)
    assert_equal 1, WebhookChainModel.after_save_count,
                 'a registered "*" route lets the chain fire once'
    puts '✓ Registered "*" route => chain fires once'
  end

  # Marquee regression: call! dispatches every trigger twice (the specific class
  # route AND the generic "*" route). When the chained callbacks fired inside
  # call_route, an app that registered BOTH routes ran the model's after_save
  # twice per delivery (e.g. two emails). With the dispatch moved into
  # run_after_save_chain -- invoked once by call! after both route calls -- the
  # model callback fires exactly once regardless of how many routes match.
  def test_call_fires_after_save_chain_once_with_both_class_and_wildcard_routes
    puts "\n=== Testing call! fires after_save chain once (class + wildcard) ==="

    WebhookChainModel.after_save_count = 0

    class_fires = 0
    wildcard_fires = 0
    Parse::Webhooks.route(:after_save, "WebhookChainModel") { class_fires += 1; true }
    Parse::Webhooks.route(:after_save, "*") { wildcard_fires += 1; true }

    body = JSON.generate(
      "triggerName" => "afterSave",
      "object" => { "className" => "WebhookChainModel", "objectId" => "bothroutes1" },
    )

    with_rack_webhook_env do
      status, _headers, resp = Parse::Webhooks.call(
        rack_env(body: body, path: "/webhooks/afterSave/WebhookChainModel")
      )
      assert_equal 200, status, "afterSave delivery should succeed"
      assert_equal({ "success" => true }, JSON.parse(resp.join))
    end

    # Both route handlers run (specific + wildcard) ...
    assert_equal 1, class_fires, "class-route handler should run once"
    assert_equal 1, wildcard_fires, "wildcard-route handler should run once"
    # ... but the chained model callback fires EXACTLY once across both.
    assert_equal 1, WebhookChainModel.after_save_count,
                 "model after_save must fire exactly once even with both routes registered"
    puts "✓ Model after_save fired exactly once across class + wildcard routes"
  end

  # The suppression decision (trusted-Ruby-initiated => skip the webhook-side
  # callbacks, local run_callbacks :save already fired them) must still hold
  # end-to-end through call! AND under the dual class+"*" dispatch -- the exact
  # intersection this change touches. Both route handlers run, but the model
  # callback fires ZERO times webhook-side.
  def test_call_suppresses_trusted_ruby_callbacks_even_with_both_routes
    puts "\n=== Testing call! suppresses trusted-ruby callbacks (both routes) ==="

    WebhookChainModel.after_save_count = 0

    class_fires = 0
    wildcard_fires = 0
    Parse::Webhooks.route(:after_save, "WebhookChainModel") { class_fires += 1; true }
    Parse::Webhooks.route(:after_save, "*") { wildcard_fires += 1; true }

    # Trusted-Ruby-initiated: _RB_ request id (nested, as Parse Server sends it)
    # AND master:true.
    body = JSON.generate(
      "triggerName" => "afterSave",
      "master" => true,
      "object" => { "className" => "WebhookChainModel", "objectId" => "trusted1" },
      "headers" => { "x-parse-request-id" => "_RB_trusted_both_routes" },
    )

    with_rack_webhook_env do
      status, _headers, resp = Parse::Webhooks.call(
        rack_env(body: body, path: "/webhooks/afterSave/WebhookChainModel")
      )
      assert_equal 200, status
      assert_equal({ "success" => true }, JSON.parse(resp.join))
    end

    assert_equal 1, class_fires, "class-route handler still runs"
    assert_equal 1, wildcard_fires, "wildcard-route handler still runs"
    assert_equal 0, WebhookChainModel.after_save_count,
                 "trusted-ruby-initiated save must NOT fire webhook-side callbacks " \
                 "(the local run_callbacks :save is the single fire)"
    puts "✓ Trusted-ruby suppression holds through call! with both routes"
  end

  # An afterSave UPDATE (original present) with both routes must also fire the
  # after_save chain exactly once -- the create-only marquee test doesn't cover
  # the update path.
  def test_call_fires_after_save_chain_once_on_update_with_both_routes
    puts "\n=== Testing call! fires after_save once on update (both routes) ==="

    WebhookChainModel.after_save_count = 0
    Parse::Webhooks.route(:after_save, "WebhookChainModel") { true }
    Parse::Webhooks.route(:after_save, "*") { true }

    body = JSON.generate(
      "triggerName" => "afterSave",
      "object" => { "className" => "WebhookChainModel", "objectId" => "upd1" },
      "original" => { "className" => "WebhookChainModel", "objectId" => "upd1" },
    )

    with_rack_webhook_env do
      status, _headers, _resp = Parse::Webhooks.call(
        rack_env(body: body, path: "/webhooks/afterSave/WebhookChainModel")
      )
      assert_equal 200, status
    end

    assert_equal 1, WebhookChainModel.after_save_count,
                 "after_save fires exactly once on an update with both routes"
    puts "✓ Update fires after_save exactly once across both routes"
  end

  # The containment is chain-level, not per-callback: when a callback raises, the
  # REST of that phase's chain is halted (ActiveModel semantics). With two
  # raising after_save callbacks, exactly ONE runs (not both) -- a per-callback
  # rescue refactor would let both run and would fail this. The sibling
  # after_create phase still runs, and the endpoint stays 200.
  def test_call_halts_rest_of_phase_chain_when_a_callback_raises
    puts "\n=== Testing chain-level halt when an after_save callback raises ==="

    WebhookHaltModel.after_save_ran = []
    WebhookHaltModel.after_create_ran = 0

    Parse::Webhooks.route(:after_save, "WebhookHaltModel") { true }
    body = JSON.generate(
      "triggerName" => "afterSave",
      "object" => { "className" => "WebhookHaltModel", "objectId" => "halt1" },
      # no "original" => a create, so after_create runs as the sibling phase
    )

    with_rack_webhook_env do
      status, _headers, resp = Parse::Webhooks.call(
        rack_env(body: body, path: "/webhooks/afterSave/WebhookHaltModel")
      )
      assert_equal 200, status, "endpoint stays 200 despite the raising callback"
      assert_equal({ "success" => true }, JSON.parse(resp.join))
    end

    assert_equal 1, WebhookHaltModel.after_create_ran,
                 "the sibling after_create phase still ran"
    assert_equal 1, WebhookHaltModel.after_save_ran.size,
                 "exactly ONE after_save callback ran -- the raise halted the rest " \
                 "of the chain (a per-callback wrap would let both run)"
    puts "✓ A raising callback halts the rest of its phase; sibling phase + 200 intact"
  end

  # Symmetric to the after_create log assertion: a raising after_save is also
  # contained-but-logged (not silently swallowed).
  def test_run_after_save_chain_logs_a_raising_after_save
    puts "\n=== Testing a raising after_save is logged, not silent ==="

    WebhookRaisingModel.after_create_count = 0
    WebhookRaisingModel.after_save_count = 0
    WebhookRaisingModel.raise_on = :after_save

    Parse::Webhooks.route(:after_save, "WebhookRaisingModel") { true }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "afterSave",
      "object" => { "className" => "WebhookRaisingModel", "objectId" => "raise3" },
    )

    _out, err = capture_io { Parse::Webhooks.run_after_save_chain(payload) }

    assert_equal 1, WebhookRaisingModel.after_save_count, "after_save ran (and raised)"
    assert_match(/after_save callback raised/, err,
                 "the contained after_save failure must be logged")
    puts "✓ Raising after_save is logged"
  ensure
    WebhookRaisingModel.raise_on = nil
  end

  # afterSave fires AFTER the object is already persisted, and Parse Server
  # discards the response body. So a chained after_create callback that raises
  # must not (a) propagate out and skip the unrelated after_save side effects,
  # nor (b) crash the dispatcher. run_after_save_chain runs the two phases
  # independently, swallowing+logging the raise.
  def test_run_after_save_chain_contains_a_raising_after_create_and_still_fires_after_save
    puts "\n=== Testing run_after_save_chain contains a raising after_create ==="

    WebhookRaisingModel.after_create_count = 0
    WebhookRaisingModel.after_save_count = 0
    WebhookRaisingModel.raise_on = :after_create

    Parse::Webhooks.route(:after_save, "WebhookRaisingModel") { true }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "afterSave",
      "object" => { "className" => "WebhookRaisingModel", "objectId" => "raise1" },
      # no "original" => a create, so after_create runs first
    )

    # Must not raise out of the dispatcher.
    _out, err = capture_io { Parse::Webhooks.run_after_save_chain(payload) }

    assert_equal 1, WebhookRaisingModel.after_create_count,
                 "after_create ran (and raised) once"
    assert_equal 1, WebhookRaisingModel.after_save_count,
                 "after_save still fired even though after_create raised"
    # The failure is contained, but NOT silent -- it is logged so the unrelated
    # work isn't dropped without a trace.
    assert_match(/after_create callback raised/, err,
                 "the contained after_create failure must be logged, not swallowed silently")
    puts "✓ Raising after_create is contained (and logged); after_save still fires"
  ensure
    WebhookRaisingModel.raise_on = nil
  end

  # End-to-end through call!: a chained callback raising must NOT 500 the
  # webhook endpoint. call!'s rescue only catches ResponseError /
  # ValidationError, so an unguarded StandardError from a callback would escape
  # and crash the response. The phase guard keeps the delivery a 200 success
  # (the object is already saved; the response is discarded by Parse Server).
  def test_call_returns_success_when_a_chained_after_save_callback_raises
    puts "\n=== Testing call! survives a raising after_save callback ==="

    WebhookRaisingModel.after_create_count = 0
    WebhookRaisingModel.after_save_count = 0
    WebhookRaisingModel.raise_on = :after_save

    Parse::Webhooks.route(:after_save, "WebhookRaisingModel") { true }
    body = JSON.generate(
      "triggerName" => "afterSave",
      "object" => { "className" => "WebhookRaisingModel", "objectId" => "raise2" },
    )

    status = nil
    resp = nil
    with_rack_webhook_env do
      status, _headers, resp = Parse::Webhooks.call(
        rack_env(body: body, path: "/webhooks/afterSave/WebhookRaisingModel")
      )
    end

    assert_equal 200, status, "endpoint must stay 200 when a chained callback raises"
    assert_equal({ "success" => true }, JSON.parse(resp.join))
    assert_equal 1, WebhookRaisingModel.after_save_count,
                 "after_save callback actually ran (and raised)"
    puts "✓ call! returns success despite a raising chained callback"
  ensure
    WebhookRaisingModel.raise_on = nil
  end

  # ==========================================================================
  # Rack entry-point (#call!) harness -- drives the real production path on a
  # raw body. Mirrors the helper in webhook_non_object_triggers_test.rb.
  # ==========================================================================
  def with_rack_webhook_env
    saved_key = Parse::Webhooks.instance_variable_get(:@key)
    saved_allow = Parse::Webhooks.instance_variable_get(:@allow_unauthenticated)
    saved_logging = Parse::Webhooks.logging
    Parse::Webhooks.instance_variable_set(:@key, nil)
    Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, true)
    Parse::Webhooks.logging = false
    Parse::Webhooks::ReplayProtection.reset!
    capture_io { yield }
  ensure
    Parse::Webhooks.instance_variable_set(:@key, saved_key)
    Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, saved_allow)
    Parse::Webhooks.logging = saved_logging
  end

  def rack_env(body:, path:)
    {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "PATH_INFO" => path,
      "rack.input" => StringIO.new(body),
      "CONTENT_LENGTH" => body.bytesize.to_s,
    }
  end
end
