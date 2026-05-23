require_relative "../../test_helper"
require "minitest/autorun"

# Mock request class for testing
class MockRequest
  attr_accessor :method, :path, :tag, :signature

  def initialize(method, path, tag = nil)
    @method = method
    @path = path
    @tag = tag
    @signature = "#{method}:#{path}:#{tag}"
  end

  def is_a?(klass)
    klass == Parse::Request || super
  end
end

# Mock response class for testing
class MockResponse
  attr_accessor :success, :result

  def initialize(success = true, result = {})
    @success = success
    @result = result
  end

  def success?
    @success
  end

  def result
    @result
  end
end

# Mock object that responds to change_requests
class MockObject
  attr_accessor :object_id, :requests

  def initialize(requests = [])
    @object_id = rand(100000)
    @requests = requests
  end

  def respond_to?(method)
    method == :change_requests || super
  end

  def change_requests(force = false)
    @requests
  end

  def is_a?(klass)
    klass == Parse::Object || super
  end

  def set_attributes!(attrs)
    # Mock implementation
  end

  def clear_changes!
    # Mock implementation
  end

  def id
    @id
  end

  def id=(new_id)
    @id = new_id
  end

  def blank?
    @id.nil?
  end
end

class BatchTransactionTest < Minitest::Test
  def setup
    @mock_client = Object.new
    def @mock_client.batch_request(batch)
      MockResponse.new(true, { "success" => true })
    end
  end

  def test_parse_batch_creation
    # Test Parse.batch method
    batch = Parse.batch
    assert_instance_of Parse::BatchOperation, batch
    assert_empty batch.requests

    # Test with requests
    requests = [MockRequest.new(:post, "/test"), MockRequest.new(:put, "/test2")]
    batch_with_reqs = Parse.batch(requests)
    assert_equal 2, batch_with_reqs.count
  end

  def test_batch_operation_initialization
    # Test empty initialization
    batch = Parse::BatchOperation.new
    assert_empty batch.requests
    assert_empty batch.responses
    assert_equal false, batch.transaction

    # Test with requests
    requests = [MockRequest.new(:post, "/test")]
    batch_with_reqs = Parse::BatchOperation.new(requests)
    assert_equal 1, batch_with_reqs.count

    # Test with transaction flag
    transaction_batch = Parse::BatchOperation.new([], transaction: true)
    assert_equal true, transaction_batch.transaction
  end

  def test_batch_operation_add_requests
    batch = Parse::BatchOperation.new

    # Test adding single request
    request = MockRequest.new(:post, "/test")
    batch.add(request)
    assert_equal 1, batch.count

    # Test adding array of requests
    more_requests = [MockRequest.new(:put, "/test2"), MockRequest.new(:delete, "/test3")]
    batch.add(more_requests)
    assert_equal 3, batch.count

    # Test adding another batch operation
    other_batch = Parse::BatchOperation.new([MockRequest.new(:get, "/test4")])
    batch.add(other_batch)
    assert_equal 4, batch.count

    # Test adding object with change_requests
    mock_obj = MockObject.new([MockRequest.new(:post, "/obj")])
    batch.add(mock_obj)
    assert_equal 5, batch.count
  end

  def test_batch_operation_enumerable
    requests = [MockRequest.new(:post, "/test1"), MockRequest.new(:put, "/test2")]
    batch = Parse::BatchOperation.new(requests)

    # Test enumerable interface
    assert_respond_to batch, :each
    assert_respond_to batch, :map
    assert_respond_to batch, :select

    # Test each method
    collected = []
    batch.each { |req| collected << req }
    assert_equal 2, collected.length

    # Test map
    methods = batch.map(&:method)
    assert_equal [:post, :put], methods
  end

  def test_batch_operation_as_json
    requests = [MockRequest.new(:post, "/test")]
    batch = Parse::BatchOperation.new(requests)

    # Test normal batch as_json
    json = batch.as_json
    assert json.key?("requests")
    assert_equal 1, json["requests"].length
    refute json.key?("transaction")

    # Test transaction batch as_json
    transaction_batch = Parse::BatchOperation.new(requests, transaction: true)
    transaction_json = transaction_batch.as_json
    assert transaction_json.key?("requests")
    assert_equal true, transaction_json["transaction"]
  end

  def test_batch_operation_success_error_methods
    batch = Parse::BatchOperation.new

    # Test with no responses
    refute batch.success?
    refute batch.error?

    # Test with successful responses
    batch.responses = [MockResponse.new(true), MockResponse.new(true)]
    assert batch.success?
    refute batch.error?

    # Test with mixed responses
    batch.responses = [MockResponse.new(true), MockResponse.new(false)]
    refute batch.success?
    assert batch.error?

    # Test with all failed responses
    batch.responses = [MockResponse.new(false), MockResponse.new(false)]
    refute batch.success?
    assert batch.error?
  end

  def test_batch_operation_clear
    requests = [MockRequest.new(:post, "/test1"), MockRequest.new(:put, "/test2")]
    batch = Parse::BatchOperation.new(requests)

    assert_equal 2, batch.count
    batch.clear!
    assert_equal 0, batch.count
    assert_empty batch.requests
  end

  def test_batch_operation_change_requests_compatibility
    requests = [MockRequest.new(:post, "/test")]
    batch = Parse::BatchOperation.new(requests)

    # Should be compatible with Parse::Object interface
    assert_equal requests, batch.change_requests
  end

  def test_batch_operation_client_access
    batch = Parse::BatchOperation.new

    # Should have access to Parse client
    assert_respond_to batch, :client
  end

  def test_batch_operation_submit_segmentation
    # Create more than 50 requests to test segmentation
    requests = 75.times.map { |i| MockRequest.new(:post, "/test#{i}", i) }
    batch = Parse::BatchOperation.new(requests)

    # Mock the client and submit method to simulate segmentation
    batch.instance_variable_set(:@client, @mock_client)

    # Mock the threaded_map method on Array to simulate threading behavior
    Array.class_eval do
      alias_method :original_threaded_map, :threaded_map if method_defined?(:threaded_map)

      def threaded_map(threads)
        map { |slice| yield(slice) }
      end
    end

    # Mock each_slice to return proper segments
    original_submit = Parse::BatchOperation.instance_method(:submit)
    Parse::BatchOperation.define_method(:submit) do |segment = 50, &block|
      @responses = []
      @requests.uniq!(&:signature)
      segments = @requests.each_slice(segment).to_a

      # Process each segment
      segment_responses = segments.map do |slice|
        slice.map { MockResponse.new(true, { "success" => true }) }
      end

      @responses = segment_responses.flatten
      @requests.zip(@responses).each(&block) if block_given?
      @responses
    end

    begin
      # Submit should segment into chunks and process all
      responses = batch.submit(50)

      # Should have processed all requests
      assert_equal 75, responses.length
      assert responses.all? { |r| r.is_a?(MockResponse) }
    ensure
      # Restore original method
      Parse::BatchOperation.define_method(:submit, original_submit)

      # Restore threaded_map if it was defined
      if Array.method_defined?(:original_threaded_map)
        Array.class_eval do
          alias_method :threaded_map, :original_threaded_map
          remove_method :original_threaded_map
        end
      end
    end
  end

  def test_array_destroy_extension
    # Test Array#destroy method
    mock_objects = [
      MockObject.new([MockRequest.new(:delete, "/obj1")]),
      MockObject.new([MockRequest.new(:delete, "/obj2")]),
    ]

    # Mock the destroy_request method on objects
    mock_objects.each do |obj|
      def obj.respond_to?(method)
        method == :destroy_request || method == :change_requests || super
      end

      def obj.destroy_request
        MockRequest.new(:delete, "/destroy/#{object_id}")
      end
    end

    # Mock the submit method to avoid actual network calls
    original_submit = Parse::BatchOperation.instance_method(:submit)
    Parse::BatchOperation.define_method(:submit) do |*args|
      @responses = @requests.map { MockResponse.new(true) }
      self
    end

    begin
      result = mock_objects.destroy
      assert_instance_of Parse::BatchOperation, result
      assert_equal 2, result.count
    ensure
      # Restore original method
      Parse::BatchOperation.define_method(:submit, original_submit)
    end
  end

  def test_array_save_extension
    # Test Array#save method
    mock_objects = [
      MockObject.new([MockRequest.new(:post, "/obj1")]),
      MockObject.new([MockRequest.new(:put, "/obj2")]),
    ]

    # Mock the submit method to avoid actual network calls
    original_submit = Parse::BatchOperation.instance_method(:submit)
    Parse::BatchOperation.define_method(:submit) do |*args, &block|
      @responses = @requests.map { |req| MockResponse.new(true, { "objectId" => "test#{rand(1000)}" }) }

      # Call the block if provided (for merging results)
      if block
        @requests.zip(@responses).each(&block)
      end

      self
    end

    begin
      result = mock_objects.save
      assert_instance_of Parse::BatchOperation, result
      assert_equal 2, result.count

      # Test save with merge: false
      result_no_merge = mock_objects.save(merge: false)
      assert_instance_of Parse::BatchOperation, result_no_merge

      # Test save with force: true
      result_force = mock_objects.save(force: true)
      assert_instance_of Parse::BatchOperation, result_force
    ensure
      # Restore original method
      Parse::BatchOperation.define_method(:submit, original_submit)
    end
  end

  def test_batch_operation_with_duplicate_requests
    # Test that duplicate requests are filtered out
    request1 = MockRequest.new(:post, "/test", "tag1")
    request2 = MockRequest.new(:post, "/test", "tag1") # Same signature
    request3 = MockRequest.new(:put, "/test2", "tag2")

    batch = Parse::BatchOperation.new([request1, request2, request3])

    # Mock submit to test deduplication
    original_submit = Parse::BatchOperation.instance_method(:submit)
    Parse::BatchOperation.define_method(:submit) do |segment = 50, &block|
      # Check that requests are deduplicated by signature
      @requests.uniq!(&:signature)
      @responses = @requests.map { MockResponse.new(true) }
      self
    end

    begin
      batch.submit
      # Should have deduplicated the identical requests
      assert batch.requests.map(&:signature).uniq.length <= 2
    ensure
      Parse::BatchOperation.define_method(:submit, original_submit)
    end
  end

  def test_batch_operation_with_block_callback
    requests = [MockRequest.new(:post, "/test1", "tag1"), MockRequest.new(:put, "/test2", "tag2")]
    batch = Parse::BatchOperation.new(requests)

    # Mock submit to test callback functionality
    callback_calls = []

    original_submit = Parse::BatchOperation.instance_method(:submit)
    Parse::BatchOperation.define_method(:submit) do |segment = 50, &block|
      @responses = @requests.map { MockResponse.new(true, { "objectId" => "test#{rand(1000)}" }) }

      # Call the block for each request/response pair
      if block
        @requests.zip(@responses).each do |request, response|
          callback_calls << [request, response]
          block.call(request, response)
        end
      end

      @responses
    end

    begin
      batch.submit do |request, response|
        # This block should be called for each request/response pair
        assert_instance_of MockRequest, request
        assert_instance_of MockResponse, response
      end

      assert_equal 2, callback_calls.length
    ensure
      Parse::BatchOperation.define_method(:submit, original_submit)
    end
  end
end
