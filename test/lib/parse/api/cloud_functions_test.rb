require_relative "../../../test_helper"

class TestCloudFunctions < Minitest::Test
  extend Minitest::Spec::DSL
  include Parse::API::CloudFunctions

  def setup
    @mock_client = Minitest::Mock.new
  end

  def request(method, path, **args)
    # Mock the request method that would normally be provided by Parse::Client
    @last_request = { method: method, path: path, args: args }
    
    # Return a mock successful response
    response = Minitest::Mock.new
    response.expect :result, { "result" => "success" }
    response.expect :error?, false
    response
  end

  def test_call_function_basic
    response = call_function("testFunction", { param: "value" })
    
    assert_equal :post, @last_request[:method]
    assert_equal "functions/testFunction", @last_request[:path]
    assert_equal({ param: "value" }, @last_request[:args][:body])
    assert_equal({}, @last_request[:args][:opts])
    refute response.error?
  end

  def test_call_function_with_opts
    opts = { session_token: "test_token", master_key: true }
    response = call_function("testFunction", { param: "value" }, opts: opts)
    
    assert_equal :post, @last_request[:method]
    assert_equal "functions/testFunction", @last_request[:path] 
    assert_equal({ param: "value" }, @last_request[:args][:body])
    assert_equal opts, @last_request[:args][:opts]
    refute response.error?
  end

  def test_call_function_with_session
    response = call_function_with_session("testFunction", { param: "value" }, "test_session_token")
    
    assert_equal :post, @last_request[:method]
    assert_equal "functions/testFunction", @last_request[:path]
    assert_equal({ param: "value" }, @last_request[:args][:body])
    assert_equal({ session_token: "test_session_token" }, @last_request[:args][:opts])
    refute response.error?
  end

  def test_call_function_with_session_nil_token
    response = call_function_with_session("testFunction", { param: "value" }, nil)
    
    assert_equal :post, @last_request[:method]
    assert_equal "functions/testFunction", @last_request[:path]
    assert_equal({ param: "value" }, @last_request[:args][:body])
    assert_equal({}, @last_request[:args][:opts])
    refute response.error?
  end

  def test_trigger_job_basic
    response = trigger_job("testJob", { param: "value" })
    
    assert_equal :post, @last_request[:method]
    assert_equal "jobs/testJob", @last_request[:path]
    assert_equal({ param: "value" }, @last_request[:args][:body])
    assert_equal({}, @last_request[:args][:opts])
    refute response.error?
  end

  def test_trigger_job_with_opts
    opts = { session_token: "test_token", master_key: true }
    response = trigger_job("testJob", { param: "value" }, opts: opts)
    
    assert_equal :post, @last_request[:method]
    assert_equal "jobs/testJob", @last_request[:path]
    assert_equal({ param: "value" }, @last_request[:args][:body])
    assert_equal opts, @last_request[:args][:opts]
    refute response.error?
  end

  def test_trigger_job_with_session
    response = trigger_job_with_session("testJob", { param: "value" }, "test_session_token")
    
    assert_equal :post, @last_request[:method]
    assert_equal "jobs/testJob", @last_request[:path]
    assert_equal({ param: "value" }, @last_request[:args][:body])
    assert_equal({ session_token: "test_session_token" }, @last_request[:args][:opts])
    refute response.error?
  end

  def test_trigger_job_with_session_nil_token
    response = trigger_job_with_session("testJob", { param: "value" }, nil)
    
    assert_equal :post, @last_request[:method]
    assert_equal "jobs/testJob", @last_request[:path]
    assert_equal({ param: "value" }, @last_request[:args][:body])
    assert_equal({}, @last_request[:args][:opts])
    refute response.error?
  end
end