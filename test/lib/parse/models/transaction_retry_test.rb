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
          # Simulate a 251 conflict carried in the error's response.
          conflict = Parse::Response.new({ "code" => 251, "error" => "Transaction conflict" })
          conflict.http_status = 500
          raise Parse::Error::ServiceUnavailableError.new(conflict)
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

  # Parse Server answers an aborted transaction with a bare 500: it is
  # retried, and once retries run out the error names the likely causes.
  def server_error(status)
    response = Parse::Response.new({ "code" => 1, "error" => "Internal server error." })
    response.http_status = status
    Parse::Error::ServiceUnavailableError.new(response)
  end

  def with_submit(behavior)
    original_new = Parse::BatchOperation.method(:new)
    Parse::BatchOperation.define_singleton_method(:new) do |*args, **kwargs|
      batch = original_new.call(*args, **kwargs)
      batch.define_singleton_method(:submit, &behavior)
      batch
    end
    yield
  ensure
    Parse::BatchOperation.define_singleton_method(:new, &original_new)
  end

  # A bare 500 does not prove the transaction was not applied, so by
  # default it is not resent and the error says the outcome is unknown.
  def test_server_500_is_not_retried_by_default
    attempts = 0
    aborted = server_error(500)
    submit = lambda do
      attempts += 1
      raise aborted
    end
    with_submit(submit) do
      error = assert_raises(Parse::Error) { Parse::Object.transaction(retries: 5) {} }
      assert_match(/may or may not have been applied/, error.message)
      assert_match(/replica set/, error.message)
      assert_match(/Array#save/, error.message)
      assert_kind_of Parse::Error::ServiceUnavailableError, error.cause
    end
    assert_equal 1, attempts
  end

  # A caller can opt in to resending on a 500 for writes that are safe to
  # repeat.
  def test_server_500_retry_is_opt_in
    attempts = 0
    aborted = server_error(500)
    submit = lambda do
      attempts += 1
      raise aborted if attempts < 3
      [OpenStruct.new(success?: true)]
    end
    with_submit(submit) do
      responses = Parse::Object.transaction(retries: 5, retry_server_errors: true) {}
      assert responses.first.success?
    end
    assert_equal 3, attempts
  end

  # A gateway 502/503/504 can arrive after Parse Server committed the
  # transaction, so it is never resent.
  def test_gateway_errors_are_not_retried
    [502, 503, 504].each do |status|
      attempts = 0
      gateway = server_error(status)
      submit = lambda do
        attempts += 1
        raise gateway
      end
      with_submit(submit) do
        error = assert_raises(Parse::Error::ServiceUnavailableError) do
          Parse::Object.transaction(retries: 5, retry_server_errors: true) {}
        end
        assert_equal status, error.http_status
      end
      assert_equal 1, attempts, "HTTP #{status} must not be retried"
    end
  end


  # "251" appearing in an error message is not a conflict code: only the
  # structured code is, so unrelated text never triggers a resend.
  def test_251_in_message_text_is_not_a_conflict
    [500, 502, 503, 504].each do |status|
      attempts = 0
      response = Parse::Response.new({ "code" => 1, "error" => "Upstream request 251 timed out after commit" })
      response.http_status = status
      failure = Parse::Error::ServiceUnavailableError.new(response)
      plain = Parse::Error.new("Upstream request 251 timed out after commit")
      [failure, plain].each do |err|
        attempts = 0
        submit = lambda do
          attempts += 1
          raise err
        end
        with_submit(submit) do
          assert_raises(Parse::Error) { Parse::Object.transaction(retries: 5) {} }
        end
        assert_equal 1, attempts, "HTTP #{status} #{err.class}: must not be resent"
      end
    end
  end

  # A conflict reported per request in the batch responses is retried.
  def test_per_request_251_response_is_retried
    attempts = 0
    conflict = OpenStruct.new(success?: false, code: 251, error: "conflict")
    submit = lambda do
      attempts += 1
      attempts < 2 ? [conflict] : [OpenStruct.new(success?: true)]
    end
    with_submit(submit) do
      responses = Parse::Object.transaction(retries: 3) {}
      assert responses.first.success?
    end
    assert_equal 2, attempts
  end

end
