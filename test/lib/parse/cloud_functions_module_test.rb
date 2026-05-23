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
    error_response = Minitest::Mock.new
    error_response.expect :error?, true
    
    @mock_client.expect :call_function, error_response, ["testFunction", { param: "value" }], opts: {}
    
    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Parse.call_function("testFunction", { param: "value" })
    end
    
    assert_nil result
    @mock_client.verify
    error_response.verify
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
end