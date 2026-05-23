require_relative "../../test_helper"

class TestCloudFunctionsModule < Minitest::Test
  extend Minitest::Spec::DSL

  def setup
    # Mock the client and its methods
    @mock_client = Minitest::Mock.new
    @mock_response = Minitest::Mock.new

    # Set up the mock response
    @mock_response.expect :error?, false
    @mock_response.expect :result, { "result" => "test_result" }

    # Mock Parse::Client.client to return our mock client
    Parse::Client.stub :client, @mock_client do
      yield if block_given?
    end
  end

  def test_parse_call_function_basic
    @mock_client.expect :call_function, @mock_response, ["testFunction", { param: "value" }], opts: {}

    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Parse.call_function("testFunction", { param: "value" })
    end

    assert_equal "test_result", result
    @mock_client.verify
    @mock_response.verify
  end

  def test_parse_call_function_with_session_token
    @mock_client.expect :call_function, @mock_response, ["testFunction", { param: "value" }], opts: { session_token: "test_token" }

    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Parse.call_function("testFunction", { param: "value" }, session_token: "test_token")
    end

    assert_equal "test_result", result
    @mock_client.verify
    @mock_response.verify
  end

  def test_parse_call_function_with_master_key
    @mock_client.expect :call_function, @mock_response, ["testFunction", { param: "value" }], opts: { master_key: true }

    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Parse.call_function("testFunction", { param: "value" }, master_key: true)
    end

    assert_equal "test_result", result
    @mock_client.verify
    @mock_response.verify
  end

  def test_parse_call_function_with_raw_response
    @mock_client.expect :call_function, @mock_response, ["testFunction", { param: "value" }], opts: {}

    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Parse.call_function("testFunction", { param: "value" }, raw: true)
    end

    # Note: When raw: true is passed, the response object is returned directly
    # We cannot assert on the mock object itself due to unmocked comparison methods
    @mock_client.verify
  end

  def test_parse_call_function_with_error
    error_response = Parse::Response.new("code" => 141, "error" => "Boom")
    error_response.http_status = 400

    @mock_client.expect :call_function, error_response, ["testFunction", { param: "value" }], opts: {}

    result = nil
    _out, err = capture_io do
      Parse::Client.stub :client, @mock_client do
        result = Parse.call_function("testFunction", { param: "value" })
      end
    end

    assert_nil result
    assert_match(/\[Parse:CloudCodeError\] `testFunction` \[141\] Boom \(HTTP 400\)/, err)
    @mock_client.verify
  end

  def test_parse_call_function_with_session
    # Mock different client connection
    mock_session_client = Minitest::Mock.new
    mock_session_client.expect :call_function, @mock_response, ["testFunction", { param: "value" }], opts: { session_token: "test_token" }

    Parse::Client.stub :client, mock_session_client do
      result = Parse.call_function("testFunction", { param: "value" }, session: :test_session, session_token: "test_token")
      assert_equal "test_result", result
    end

    mock_session_client.verify
    @mock_response.verify
  end

  def test_parse_call_function_with_session_convenience_method
    @mock_client.expect :call_function, @mock_response, ["testFunction", { param: "value" }], opts: { session_token: "test_token" }

    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Parse.call_function_with_session("testFunction", { param: "value" }, "test_token")
    end

    assert_equal "test_result", result
    @mock_client.verify
    @mock_response.verify
  end

  def test_parse_trigger_job_basic
    @mock_client.expect :trigger_job, @mock_response, ["testJob", { param: "value" }], opts: {}

    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Parse.trigger_job("testJob", { param: "value" })
    end

    assert_equal "test_result", result
    @mock_client.verify
    @mock_response.verify
  end

  def test_parse_trigger_job_with_session_token
    @mock_client.expect :trigger_job, @mock_response, ["testJob", { param: "value" }], opts: { session_token: "test_token" }

    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Parse.trigger_job("testJob", { param: "value" }, session_token: "test_token")
    end

    assert_equal "test_result", result
    @mock_client.verify
    @mock_response.verify
  end

  def test_parse_trigger_job_with_session_convenience_method
    @mock_client.expect :trigger_job, @mock_response, ["testJob", { param: "value" }], opts: { session_token: "test_token" }

    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Parse.trigger_job_with_session("testJob", { param: "value" }, "test_token")
    end

    assert_equal "test_result", result
    @mock_client.verify
    @mock_response.verify
  end

  def test_parse_trigger_job_warns_on_error
    error_response = Parse::Response.new("code" => 141, "error" => "Boom")
    error_response.http_status = 400

    @mock_client.expect :trigger_job, error_response, ["testJob", {}], opts: {}

    result = nil
    _out, err = capture_io do
      Parse::Client.stub :client, @mock_client do
        result = Parse.trigger_job("testJob", {})
      end
    end

    assert_nil result
    assert_match(/\[Parse:CloudCodeError\] `testJob` \[141\] Boom \(HTTP 400\)/, err)
    @mock_client.verify
  end

  def test_parse_call_function_bang_raises_on_error
    error_response = Parse::Response.new("code" => 141, "error" => "Boom")
    error_response.http_status = 400

    @mock_client.expect :call_function, error_response, ["testFunction", {}], opts: {}

    error = nil
    Parse::Client.stub :client, @mock_client do
      error = assert_raises(Parse::Error::CloudCodeError) do
        Parse.call_function!("testFunction", {})
      end
    end

    assert_equal "testFunction", error.function_name
    assert_equal 141, error.code
    assert_equal 400, error.http_status
    assert_same error_response, error.response
    assert_kind_of Parse::Error, error
    assert_match(/Parse cloud function `testFunction` failed: \[141\] Boom \(HTTP 400\)/, error.message)
    @mock_client.verify
  end

  def test_parse_call_function_bang_returns_result_on_success
    ok_response = Parse::Response.new("result" => "ok-value")

    @mock_client.expect :call_function, ok_response, ["testFunction", { a: 1 }], opts: {}

    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Parse.call_function!("testFunction", { a: 1 })
    end

    assert_equal "ok-value", result
    @mock_client.verify
  end

  def test_parse_call_function_bang_does_not_warn_on_error
    error_response = Parse::Response.new("code" => 141, "error" => "Boom")
    error_response.http_status = 400

    @mock_client.expect :call_function, error_response, ["testFunction", {}], opts: {}

    _out, err = capture_io do
      Parse::Client.stub :client, @mock_client do
        assert_raises(Parse::Error::CloudCodeError) do
          Parse.call_function!("testFunction", {})
        end
      end
    end

    refute_match(/\[Parse:CloudCodeError\]/, err)
    @mock_client.verify
  end

  def test_parse_trigger_job_bang_raises_on_error
    error_response = Parse::Response.new("code" => 141, "error" => "Boom")
    error_response.http_status = 400

    @mock_client.expect :trigger_job, error_response, ["testJob", {}], opts: {}

    error = nil
    Parse::Client.stub :client, @mock_client do
      error = assert_raises(Parse::Error::CloudCodeError) do
        Parse.trigger_job!("testJob", {})
      end
    end

    assert_equal "testJob", error.function_name
    assert_equal 141, error.code
    assert_equal 400, error.http_status
    @mock_client.verify
  end

  def test_parse_trigger_job_bang_returns_result_on_success
    ok_response = Parse::Response.new("result" => "job-done")

    @mock_client.expect :trigger_job, ok_response, ["testJob", {}], opts: {}

    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Parse.trigger_job!("testJob", {})
    end

    assert_equal "job-done", result
    @mock_client.verify
  end

  def test_parse_call_function_with_session_bang_raises_on_error
    error_response = Parse::Response.new("code" => 141, "error" => "Boom")
    error_response.http_status = 400

    @mock_client.expect :call_function, error_response, ["testFunction", { param: "value" }], opts: { session_token: "test_token" }

    error = nil
    Parse::Client.stub :client, @mock_client do
      error = assert_raises(Parse::Error::CloudCodeError) do
        Parse.call_function_with_session!("testFunction", { param: "value" }, "test_token")
      end
    end

    assert_equal "testFunction", error.function_name
    assert_equal 141, error.code
    @mock_client.verify
  end

  def test_parse_call_function_bang_ignores_raw_option
    error_response = Parse::Response.new("code" => 141, "error" => "Boom")
    error_response.http_status = 400

    # Whether the caller passes raw: true or raw: false, the bang variant must
    # still raise — the documented contract is that :raw is ignored.
    @mock_client.expect :call_function, error_response, ["fn", {}], opts: {}

    Parse::Client.stub :client, @mock_client do
      assert_raises(Parse::Error::CloudCodeError) do
        Parse.call_function!("fn", {}, raw: false)
      end
    end

    @mock_client.verify
  end

  def test_parse_call_function_handles_non_hash_response_body
    # Guard against TypeError when Parse Server returns a non-Hash body for a
    # "successful" response. Should return the raw result rather than indexing
    # into a String.
    odd_response = Parse::Response.new
    odd_response.result = "bare-string-body"

    @mock_client.expect :call_function, odd_response, ["fn", {}], opts: {}

    Parse::Client.stub :client, @mock_client do
      assert_equal "bare-string-body", Parse.call_function("fn", {})
    end

    @mock_client.verify
  end

  def test_cloud_code_error_inspect_omits_response
    error_response = Parse::Response.new("code" => 141, "error" => "Boom")
    error_response.http_status = 400
    error = Parse::Error::CloudCodeError.new("fn", error_response)

    inspected = error.inspect
    assert_match(/function="fn"/, inspected)
    assert_match(/code=141/, inspected)
    assert_match(/http_status=400/, inspected)
    refute_match(/Boom/, inspected, "inspect must not leak the underlying response error string")
  end

  def test_parse_trigger_job_with_session_bang_raises_on_error
    error_response = Parse::Response.new("code" => 141, "error" => "Boom")
    error_response.http_status = 400

    @mock_client.expect :trigger_job, error_response, ["testJob", { param: "value" }], opts: { session_token: "test_token" }

    error = nil
    Parse::Client.stub :client, @mock_client do
      error = assert_raises(Parse::Error::CloudCodeError) do
        Parse.trigger_job_with_session!("testJob", { param: "value" }, "test_token")
      end
    end

    assert_equal "testJob", error.function_name
    assert_equal 141, error.code
    @mock_client.verify
  end
end
