require_relative '../../test_helper'
require 'minitest/autorun'

class RequestIdempotencyTest < Minitest::Test
  
  def setup
    # Reset configuration to defaults before each test
    Parse::Request.configure_idempotency(enabled: true)
  end
  
  def teardown
    # Reset configuration to defaults after each test
    Parse::Request.configure_idempotency(enabled: true)
  end
  
  def test_default_configuration
    puts "\n=== Testing Default Idempotency Configuration ==="
    
    # Test default values
    assert Parse::Request.enable_request_id, "Request ID should be enabled by default"
    assert_equal 'X-Parse-Request-Id', Parse::Request.request_id_header, "Should use standard Parse header"
    assert_equal [:post, :put, :patch], Parse::Request.idempotent_methods, "Should default to modifying methods"
    
    # Test that requests DO get request IDs by default
    request = Parse::Request.new(:post, '/classes/TestObject', body: { name: 'test' })
    assert request.idempotent?, "Request should be idempotent by default"
    refute_nil request.request_id, "Request should have request ID by default"
    assert request.headers.key?('X-Parse-Request-Id'), "Headers should contain request ID by default"
    
    puts "✅ Default configuration verified"
  end
  
  def test_enable_idempotency_globally
    puts "\n=== Testing Global Idempotency Enable ==="
    
    # Enable idempotency globally
    Parse::Request.enable_idempotency!
    
    assert Parse::Request.enable_request_id, "Request ID should be enabled"
    
    # Test POST request gets request ID
    post_request = Parse::Request.new(:post, '/classes/TestObject', body: { name: 'test' })
    assert post_request.idempotent?, "POST request should be idempotent"
    assert post_request.request_id.present?, "POST request should have request ID"
    assert post_request.headers['X-Parse-Request-Id'].present?, "POST request should have header"
    assert post_request.request_id.start_with?('_RB_'), "Request ID should have Ruby prefix"
    puts "✅ POST request gets request ID"
    
    # Test PUT request gets request ID
    put_request = Parse::Request.new(:put, '/classes/TestObject/abc123', body: { name: 'updated' })
    assert put_request.idempotent?, "PUT request should be idempotent"
    assert put_request.request_id.present?, "PUT request should have request ID"
    puts "✅ PUT request gets request ID"
    
    # Test GET request does not get request ID (naturally idempotent)
    get_request = Parse::Request.new(:get, '/classes/TestObject')
    refute get_request.idempotent?, "GET request should not need request ID"
    assert_nil get_request.request_id, "GET request should not have request ID"
    puts "✅ GET request correctly excluded"
    
    # Test DELETE request gets request ID
    delete_request = Parse::Request.new(:delete, '/classes/TestObject/abc123')
    refute delete_request.idempotent?, "DELETE not in default idempotent methods"
    assert_nil delete_request.request_id, "DELETE should not have request ID by default"
    puts "✅ DELETE request correctly excluded by default"
  end
  
  def test_custom_idempotency_configuration
    puts "\n=== Testing Custom Idempotency Configuration ==="
    
    # Configure with custom settings
    Parse::Request.configure_idempotency(
      enabled: true,
      methods: [:post, :put, :patch, :delete],
      header: 'X-Custom-Request-Id'
    )
    
    assert Parse::Request.enable_request_id, "Should be enabled"
    assert_equal 'X-Custom-Request-Id', Parse::Request.request_id_header, "Should use custom header"
    assert_equal [:post, :put, :patch, :delete], Parse::Request.idempotent_methods, "Should use custom methods"
    
    # Test DELETE now gets request ID
    delete_request = Parse::Request.new(:delete, '/classes/TestObject/abc123')
    assert delete_request.idempotent?, "DELETE should now be idempotent"
    assert delete_request.headers['X-Custom-Request-Id'].present?, "Should use custom header name"
    puts "✅ Custom configuration applied correctly"
  end
  
  def test_per_request_idempotency_control
    puts "\n=== Testing Per-Request Idempotency Control ==="

    # Disable idempotency globally to test per-request enabling
    Parse::Request.disable_idempotency!

    # Test forcing idempotency on individual request
    request = Parse::Request.new(:post, '/classes/TestObject', body: { name: 'test' })
    refute request.idempotent?, "Should not be idempotent initially (global disabled)"
    
    request.with_idempotency
    assert request.idempotent?, "Should be idempotent after with_idempotency"
    assert request.request_id.present?, "Should have request ID"
    puts "✅ with_idempotency() works"
    
    # Test with custom request ID
    custom_id = "custom-123-test"
    request2 = Parse::Request.new(:post, '/classes/TestObject', body: { name: 'test2' })
    request2.with_idempotency(custom_id)
    assert_equal custom_id, request2.request_id, "Should use custom request ID"
    assert_equal custom_id, request2.headers['X-Parse-Request-Id'], "Header should contain custom ID"
    puts "✅ Custom request ID works"
    
    # Test disabling idempotency on individual request
    Parse::Request.enable_idempotency!
    request3 = Parse::Request.new(:post, '/classes/TestObject', body: { name: 'test3' })
    assert request3.idempotent?, "Should be idempotent by default"
    
    request3.without_idempotency
    refute request3.idempotent?, "Should not be idempotent after without_idempotency"
    assert_nil request3.request_id, "Should not have request ID"
    refute request3.headers.key?('X-Parse-Request-Id'), "Should not have header"
    puts "✅ without_idempotency() works"
  end
  
  def test_request_id_in_options
    puts "\n=== Testing Request ID in Options ==="
    
    Parse::Request.enable_idempotency!
    
    # Test custom request ID in options
    custom_id = "options-test-456"
    request = Parse::Request.new(:post, '/classes/TestObject', 
      body: { name: 'test' },
      opts: { request_id: custom_id }
    )
    
    assert request.idempotent?, "Should be idempotent"
    assert_equal custom_id, request.request_id, "Should use request ID from options"
    assert_equal custom_id, request.headers['X-Parse-Request-Id'], "Header should contain options ID"
    puts "✅ Request ID from options works"
    
    # Test explicit idempotent flag in options
    request2 = Parse::Request.new(:get, '/classes/TestObject',
      opts: { idempotent: true }
    )
    
    assert request2.idempotent?, "GET should be idempotent when explicitly enabled"
    assert request2.request_id.present?, "Should have request ID"
    puts "✅ Explicit idempotent flag works"
    
    # Test explicit disable in options
    request3 = Parse::Request.new(:post, '/classes/TestObject',
      body: { name: 'test3' },
      opts: { idempotent: false }
    )
    
    refute request3.idempotent?, "Should not be idempotent when explicitly disabled"
    assert_nil request3.request_id, "Should not have request ID"
    puts "✅ Explicit disable flag works"
  end
  
  def test_request_id_in_headers
    puts "\n=== Testing Request ID in Headers ==="
    
    # Test manual request ID in headers
    manual_id = "manual-header-789"
    request = Parse::Request.new(:post, '/classes/TestObject',
      body: { name: 'test' },
      headers: { 'X-Parse-Request-Id' => manual_id }
    )
    
    assert request.idempotent?, "Should be idempotent with manual header"
    assert_equal manual_id, request.headers['X-Parse-Request-Id'], "Should preserve manual header"
    puts "✅ Manual request ID in headers works"
    
    # Test that manual header overrides generated ID
    Parse::Request.enable_idempotency!
    request2 = Parse::Request.new(:post, '/classes/TestObject',
      body: { name: 'test2' },
      headers: { 'X-Parse-Request-Id' => manual_id }
    )
    
    assert_equal manual_id, request2.headers['X-Parse-Request-Id'], "Manual header should not be overridden"
    puts "✅ Manual header takes precedence"
  end
  
  def test_non_idempotent_paths
    puts "\n=== Testing Non-Idempotent Path Exclusions ==="
    
    Parse::Request.enable_idempotency!
    
    # Test paths that should not get request IDs
    non_idempotent_paths = [
      '/sessions',
      '/logout',
      '/requestPasswordReset',
      '/functions/myFunction',
      '/jobs/myJob',
      '/events/Analytics',
      '/push'
    ]
    
    non_idempotent_paths.each do |path|
      request = Parse::Request.new(:post, path, body: { data: 'test' })
      refute request.idempotent?, "Path #{path} should not be idempotent"
      assert_nil request.request_id, "Path #{path} should not have request ID"
      puts "✓ #{path} correctly excluded"
    end
    
    # Test normal paths still get request IDs
    normal_paths = [
      '/classes/TestObject',
      '/users',
      '/installations'
    ]
    
    normal_paths.each do |path|
      request = Parse::Request.new(:post, path, body: { data: 'test' })
      assert request.idempotent?, "Path #{path} should be idempotent"
      assert request.request_id.present?, "Path #{path} should have request ID"
      puts "✓ #{path} correctly included"
    end
  end
  
  def test_request_id_format
    puts "\n=== Testing Request ID Format ==="
    
    Parse::Request.enable_idempotency!
    
    request = Parse::Request.new(:post, '/classes/TestObject', body: { name: 'test' })
    request_id = request.request_id
    
    assert request_id.present?, "Request ID should be present"
    assert request_id.start_with?('_RB_'), "Request ID should start with Ruby prefix"
    
    # Check UUID format (after prefix)
    uuid_part = request_id[4..-1]  # Remove '_RB_' prefix
    uuid_pattern = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    assert uuid_part.match?(uuid_pattern), "UUID part should be valid UUID format"
    
    puts "✅ Request ID format is correct: #{request_id}"
  end
  
  def test_request_equality_with_idempotency
    puts "\n=== Testing Request Equality with Idempotency ==="
    
    # Test that requests with different request IDs are still equal for comparison
    request1 = Parse::Request.new(:post, '/classes/TestObject', body: { name: 'test' })
    request1.with_idempotency
    
    request2 = Parse::Request.new(:post, '/classes/TestObject', body: { name: 'test' })
    request2.with_idempotency
    
    # Request IDs should be different
    refute_equal request1.request_id, request2.request_id, "Request IDs should be different"
    
    # But requests should still be equal based on method, path, and body
    # Note: This depends on how the equality method is implemented
    # The current implementation compares headers, so they won't be equal
    # This is actually correct behavior for idempotency
    refute_equal request1, request2, "Requests with different request IDs should not be equal"
    
    puts "✅ Request equality respects idempotency headers"
  end
  
  def test_request_signature_with_idempotency
    puts "\n=== Testing Request Signature with Idempotency ==="
    
    request = Parse::Request.new(:post, '/classes/TestObject', body: { name: 'test' })
    request.with_idempotency
    
    signature = request.signature
    
    # Signature should include method, path, and body but not headers
    assert_equal :POST, signature[:method], "Signature should include method"
    assert_equal '/classes/TestObject', signature[:path], "Signature should include path"
    assert_equal({ name: 'test' }, signature[:body], "Signature should include body")
    
    # Signature should not include request ID (which is in headers)
    refute signature.key?(:request_id), "Signature should not include request ID"
    refute signature.key?(:headers), "Signature should not include headers"
    
    puts "✅ Request signature excludes idempotency headers"
  end
  
  def test_disable_idempotency_globally
    puts "\n=== Testing Global Idempotency Disable ==="
    
    # Enable first
    Parse::Request.enable_idempotency!
    assert Parse::Request.enable_request_id, "Should be enabled"
    
    # Then disable
    Parse::Request.disable_idempotency!
    refute Parse::Request.enable_request_id, "Should be disabled"
    
    # Test that new requests don't get request IDs
    request = Parse::Request.new(:post, '/classes/TestObject', body: { name: 'test' })
    refute request.idempotent?, "Request should not be idempotent after global disable"
    assert_nil request.request_id, "Request should not have request ID"
    
    puts "✅ Global disable works correctly"
  end
  
  def test_method_chaining
    puts "\n=== Testing Method Chaining ==="
    
    # Test that idempotency methods return self for chaining
    request = Parse::Request.new(:post, '/classes/TestObject', body: { name: 'test' })
    
    result = request.with_idempotency
    assert_equal request, result, "with_idempotency should return self"
    
    result2 = request.without_idempotency
    assert_equal request, result2, "without_idempotency should return self"
    
    # Test chaining
    request.with_idempotency.without_idempotency.with_idempotency("custom-chain-id")
    assert request.idempotent?, "Should be idempotent after chaining"
    assert_equal "custom-chain-id", request.request_id, "Should have custom ID from chain"
    
    puts "✅ Method chaining works correctly"
  end
  
  def test_thread_safety
    puts "\n=== Testing Thread Safety ==="
    
    Parse::Request.enable_idempotency!
    
    # Test that different threads get different request IDs
    request_ids = []
    threads = []
    
    10.times do
      threads << Thread.new do
        request = Parse::Request.new(:post, '/classes/TestObject', body: { name: 'test' })
        request_ids << request.request_id
      end
    end
    
    threads.each(&:join)
    
    # All request IDs should be unique
    assert_equal 10, request_ids.length, "Should have 10 request IDs"
    assert_equal 10, request_ids.uniq.length, "All request IDs should be unique"
    
    puts "✅ Thread safety verified"
  end
  
  def test_edge_cases
    puts "\n=== Testing Edge Cases ==="
    
    Parse::Request.enable_idempotency!
    
    # Test with empty body
    request1 = Parse::Request.new(:post, '/classes/TestObject')
    assert request1.idempotent?, "Request with no body should still be idempotent"
    puts "✓ Empty body handled"
    
    # Test with nil body explicitly
    request2 = Parse::Request.new(:post, '/classes/TestObject', body: nil)
    assert request2.idempotent?, "Request with nil body should still be idempotent"
    puts "✓ Nil body handled"
    
    # Test with empty headers
    request3 = Parse::Request.new(:post, '/classes/TestObject', 
      body: { name: 'test' }, 
      headers: {}
    )
    assert request3.idempotent?, "Request with empty headers should be idempotent"
    puts "✓ Empty headers handled"
    
    # Test case insensitive method
    request4 = Parse::Request.new('POST', '/classes/TestObject', body: { name: 'test' })
    assert request4.idempotent?, "String method should work"
    puts "✓ String method handled"
    
    # Test invalid method (should raise error before idempotency)
    assert_raises(ArgumentError) do
      Parse::Request.new(:invalid, '/classes/TestObject')
    end
    puts "✓ Invalid method raises error"
    
    puts "✅ Edge cases handled correctly"
  end
end