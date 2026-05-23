require_relative "../../../test_helper"
require "ostruct"

class TestTransactionRetry < Minitest::Test
  
  def setup
    Parse.use_shortnames!
    @attempt_count = 0
  end
  
  def test_transaction_retries_on_error_251
    attempt_count = 0
    max_retries = 3
    
    # Mock BatchOperation to track attempts
    original_new = Parse::BatchOperation.method(:new)
    Parse::BatchOperation.define_singleton_method(:new) do |*args, **kwargs|
      batch = original_new.call(*args, **kwargs)
      batch.define_singleton_method(:submit) do
        attempt_count += 1
        if attempt_count < max_retries
          # Simulate 251 error
          raise Parse::Error, "Transaction conflict error code 251"
        else
          # Success on final attempt
          [OpenStruct.new(success?: true)]
        end
      end
      batch
    end
    
    # Mock sleep to speed up test
    sleep_calls = []
    # Override the global sleep method
    original_sleep = Object.instance_method(:sleep)
    Object.class_eval do
      define_method(:sleep) do |time|
        sleep_calls << time
      end
    end
    
    begin
      responses = Parse::Object.transaction(retries: max_retries) do
        # Empty transaction
      end
      assert_equal max_retries, attempt_count
      assert_equal 1, responses.count
      assert responses.first.success?
      
      # Check exponential backoff
      assert_equal 2, sleep_calls.count
      assert_equal 0.1, sleep_calls[0]
      assert_equal 0.2, sleep_calls[1]
      
    ensure
      Parse::BatchOperation.define_singleton_method(:new, &original_new)
      # Restore the original sleep method
      Object.class_eval do
        define_method(:sleep, original_sleep)
      end
    end
  end
  
  def test_transaction_does_not_retry_on_other_errors
    attempt_count = 0
    
    # Mock BatchOperation with non-251 error
    original_new = Parse::BatchOperation.method(:new)
    Parse::BatchOperation.define_singleton_method(:new) do |*args, **kwargs|
      batch = original_new.call(*args, **kwargs)
      batch.define_singleton_method(:submit) do
        attempt_count += 1
        raise Parse::Error, "Invalid data error code 111"
      end
      batch
    end
    
    begin
      assert_raises(Parse::Error) do
        Parse::Object.transaction(retries: 5) do
          # Empty transaction
        end
      end
      
      # Should not retry for non-251 errors
      assert_equal 1, attempt_count
      
    ensure
      Parse::BatchOperation.define_singleton_method(:new, &original_new)
    end
  end
end