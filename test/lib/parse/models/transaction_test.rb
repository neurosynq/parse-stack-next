require_relative "../../../test_helper"
require "ostruct"

class TestTransaction < Minitest::Test
  
  def setup
    Parse.use_shortnames!
  end
  
  def test_transaction_requires_block
    assert_raises(ArgumentError) do
      Parse::Object.transaction
    end
  end
  
  def test_transaction_creates_batch_with_transaction_flag
    batch_created = nil
    
    # Stub BatchOperation.new to capture what gets created
    original_new = Parse::BatchOperation.method(:new)
    Parse::BatchOperation.define_singleton_method(:new) do |*args, **kwargs|
      batch_created = original_new.call(*args, **kwargs)
      # Stub submit to return successful response
      batch_created.define_singleton_method(:submit) { [OpenStruct.new(success?: true)] }
      batch_created
    end
    
    begin
      Parse::Object.transaction do |batch|
        assert_instance_of Parse::BatchOperation, batch
      end
      
      assert batch_created
      assert_equal true, batch_created.transaction
    ensure
      # Restore original method
      Parse::BatchOperation.define_singleton_method(:new, &original_new)
    end
  end
  
  def test_transaction_with_mock_objects
    # Create a mock object that responds to change_requests
    mock_obj = Object.new
    def mock_obj.respond_to?(method)
      method == :change_requests
    end
    def mock_obj.change_requests
      [OpenStruct.new(method: :post, path: "/test")]
    end
    
    batch_requests = []
    
    # Stub BatchOperation methods
    original_new = Parse::BatchOperation.method(:new)
    Parse::BatchOperation.define_singleton_method(:new) do |*args, **kwargs|
      batch = original_new.call(*args, **kwargs)
      batch.define_singleton_method(:add) do |obj|
        batch_requests << obj if obj
      end
      batch.define_singleton_method(:submit) { [OpenStruct.new(success?: true)] }
      batch
    end
    
    begin
      result = Parse::Object.transaction do
        mock_obj # Return object to be added to batch
      end
      
      assert_equal 1, result.count
      assert result.first.success?
    ensure
      Parse::BatchOperation.define_singleton_method(:new, &original_new)
    end
  end
  
  def test_transaction_failure_handling
    # Test that transaction raises error on failure
    original_new = Parse::BatchOperation.method(:new)
    Parse::BatchOperation.define_singleton_method(:new) do |*args, **kwargs|
      batch = original_new.call(*args, **kwargs)
      # Stub submit to return failed response
      batch.define_singleton_method(:submit) do
        [OpenStruct.new(success?: false, error: "Test error")]
      end
      batch
    end
    
    begin
      assert_raises(Parse::Error) do
        Parse::Object.transaction do
          # This should trigger the error
        end
      end
    ensure
      Parse::BatchOperation.define_singleton_method(:new, &original_new)
    end
  end
  
  def test_transaction_with_custom_retry_count
    # Test that retries parameter is accepted
    batch_created = nil
    
    original_new = Parse::BatchOperation.method(:new)
    Parse::BatchOperation.define_singleton_method(:new) do |*args, **kwargs|
      batch_created = original_new.call(*args, **kwargs)
      batch_created.define_singleton_method(:submit) { [OpenStruct.new(success?: true)] }
      batch_created
    end
    
    begin
      result = Parse::Object.transaction(retries: 10) do |batch|
        # Test that custom retry count is accepted
        assert_instance_of Parse::BatchOperation, batch
      end
      
      assert batch_created
      assert_equal true, batch_created.transaction
    ensure
      Parse::BatchOperation.define_singleton_method(:new, &original_new)
    end
  end
end