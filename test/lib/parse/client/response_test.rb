require_relative "../../../test_helper"

class TestResponse < Minitest::Test
  def test_retry_after_constant_defined
    assert_equal "Retry-After", Parse::Response::RETRY_AFTER
  end

  def test_headers_attribute_exists
    response = Parse::Response.new
    assert_respond_to response, :headers
    assert_respond_to response, :headers=
  end

  def test_retry_after_method_exists
    response = Parse::Response.new
    assert_respond_to response, :retry_after
  end

  def test_retry_after_returns_nil_when_no_headers
    response = Parse::Response.new
    assert_nil response.retry_after
  end

  def test_retry_after_returns_nil_when_headers_empty
    response = Parse::Response.new
    response.headers = {}
    assert_nil response.retry_after
  end

  def test_retry_after_returns_nil_when_header_not_present
    response = Parse::Response.new
    response.headers = { "Content-Type" => "application/json" }
    assert_nil response.retry_after
  end

  def test_retry_after_parses_integer_seconds
    response = Parse::Response.new
    response.headers = { "Retry-After" => "30" }
    assert_equal 30, response.retry_after
  end

  def test_retry_after_parses_integer_as_integer
    response = Parse::Response.new
    response.headers = { "Retry-After" => 60 }
    assert_equal 60, response.retry_after
  end

  def test_retry_after_handles_lowercase_header_name
    response = Parse::Response.new
    response.headers = { "retry-after" => "45" }
    assert_equal 45, response.retry_after
  end

  def test_retry_after_parses_http_date
    # Test with a future HTTP-date
    future_time = Time.now + 120  # 2 minutes from now
    http_date = future_time.httpdate
    response = Parse::Response.new
    response.headers = { "Retry-After" => http_date }

    result = response.retry_after
    assert_kind_of Integer, result
    # Should be approximately 120 seconds (allowing for test execution time)
    assert result >= 118 && result <= 122, "Expected ~120, got #{result}"
  end

  def test_retry_after_returns_1_for_past_http_date
    # Test with a past HTTP-date
    past_time = Time.now - 60
    http_date = past_time.httpdate
    response = Parse::Response.new
    response.headers = { "Retry-After" => http_date }

    # Should return 1 (minimum) for past dates
    assert_equal 1, response.retry_after
  end

  def test_retry_after_returns_nil_for_invalid_value
    response = Parse::Response.new
    response.headers = { "Retry-After" => "invalid" }
    assert_nil response.retry_after
  end

  def test_retry_after_returns_nil_for_non_hash_headers
    response = Parse::Response.new
    response.headers = "not a hash"
    assert_nil response.retry_after
  end

  # Test success/error behavior is preserved
  def test_success_response
    response = Parse::Response.new({ "objectId" => "abc123" })
    assert response.success?
    refute response.error?
  end

  def test_error_response
    response = Parse::Response.new({ "code" => 101, "error" => "Object not found" })
    refute response.success?
    assert response.error?
  end

  def test_http_status_set
    response = Parse::Response.new
    response.http_status = 429
    assert_equal 429, response.http_status
  end
end
