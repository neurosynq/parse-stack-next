# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the verifyPassword API method (Parse::API::Users#verify_password)
# and the Parse::User#verify_password instance method.
#
# API-layer tests include the module directly and stub +request+ — the same
# pattern used in test/lib/parse/api/cloud_functions_test.rb. User-model tests
# use Minitest::Mock to mock the client at the instance level.
class VerifyPasswordAPITest < Minitest::Test
  include Parse::API::Users

  # Captures the most recent call to #request so tests can assert on method,
  # path, and keyword arguments.
  def setup
    @last_request = nil
    @stub_response = nil
  end

  # Intercept the internal #request call that all API methods delegate to.
  def request(method, path, **kwargs)
    @last_request = { method: method, path: path, kwargs: kwargs }
    @stub_response || Parse::Response.new({})
  end

  # Stub helpers are not needed here since #request is already overridden.
  def check_login_rate_limit!(*); end
  def track_login_attempt(*); end

  # =========================================================================
  # VERIFY_PASSWORD_PATH constant
  # =========================================================================

  def test_verify_password_path_constant_value
    assert_equal "verifyPassword", Parse::API::Users::VERIFY_PASSWORD_PATH
  end

  # =========================================================================
  # #verify_password issues a POST to the correct path with credentials in the
  # BODY (not the URL) so the plaintext password never reaches access logs,
  # proxy logs, the Referer header, or the URL-keyed response cache.
  # =========================================================================

  def test_verify_password_uses_post_method
    verify_password("alice", "s3cret")
    assert_equal :post, @last_request[:method]
  end

  def test_verify_password_uses_correct_path
    verify_password("alice", "s3cret")
    assert_equal "verifyPassword", @last_request[:path]
  end

  def test_verify_password_passes_credentials_in_body_not_query
    verify_password("alice", "s3cret")
    body = @last_request.dig(:kwargs, :body)
    assert_equal "alice", body[:username]
    assert_equal "s3cret", body[:password]
    assert_nil @last_request.dig(:kwargs, :query),
               "credentials must not ride the URL query string"
  end

  def test_verify_password_passes_headers
    verify_password("alice", "s3cret", headers: { "X-Custom" => "val" })
    assert_equal({ "X-Custom" => "val" }, @last_request.dig(:kwargs, :headers))
  end

  def test_verify_password_sets_parse_class_on_response
    ok_result = { "objectId" => "abc123", "username" => "alice" }
    @stub_response = Parse::Response.new(ok_result)
    response = verify_password("alice", "s3cret")
    assert_equal Parse::Model::CLASS_USER, response.parse_class
  end

  def test_verify_password_returns_response_object
    ok_result = { "objectId" => "abc123", "username" => "alice" }
    @stub_response = Parse::Response.new(ok_result)
    response = verify_password("alice", "s3cret")
    assert_instance_of Parse::Response, response
    assert response.success?
  end

  def test_verify_password_returns_error_response_on_failure
    err_body     = { "code" => 101, "error" => "Invalid username/password." }
    @stub_response = Parse::Response.new(err_body)
    response = verify_password("alice", "wrong")
    assert response.error?
    assert_equal 101, response.code
  end
end

# Model-layer tests: Parse::User#verify_password instance method
class VerifyPasswordUserTest < Minitest::Test

  # =========================================================================
  # Happy path
  # =========================================================================

  def test_verify_password_returns_true_on_success
    user = Parse::User.new
    user.username = "alice"

    ok_result   = { "objectId" => "abc123", "username" => "alice" }
    ok_response = Parse::Response.new(ok_result)

    mock_client = Minitest::Mock.new
    mock_client.expect(:verify_password, ok_response, ["alice", "correct"])

    user.stub(:client, mock_client) do
      assert_equal true, user.verify_password("correct")
    end

    mock_client.verify
  end

  # =========================================================================
  # Wrong password / unknown user (code 101)
  # =========================================================================

  def test_verify_password_raises_authentication_error_on_wrong_password
    user = Parse::User.new
    user.username = "alice"

    err_body     = { "code" => 101, "error" => "Invalid username/password." }
    err_response = Parse::Response.new(err_body)
    err_response.http_status = 404

    mock_client = Minitest::Mock.new
    mock_client.expect(:verify_password, err_response, ["alice", "wrong"])

    user.stub(:client, mock_client) do
      assert_raises(Parse::Error::AuthenticationError) do
        user.verify_password("wrong")
      end
    end

    mock_client.verify
  end

  def test_verify_password_auth_error_message_contains_code
    user = Parse::User.new
    user.username = "carol"

    err_body     = { "code" => 101, "error" => "Invalid username/password." }
    err_response = Parse::Response.new(err_body)
    err_response.http_status = 404

    mock_client = Minitest::Mock.new
    mock_client.expect(:verify_password, err_response, ["carol", "badpass"])

    user.stub(:client, mock_client) do
      error = assert_raises(Parse::Error::AuthenticationError) do
        user.verify_password("badpass")
      end
      assert_match(/101/, error.message)
    end

    mock_client.verify
  end

  # =========================================================================
  # Unverified email (code 205)
  # =========================================================================

  def test_verify_password_raises_email_not_verified_error_on_code_205
    user = Parse::User.new
    user.username = "bob"

    err_body     = { "code" => 205, "error" => "User email is not verified." }
    err_response = Parse::Response.new(err_body)
    err_response.http_status = 400

    mock_client = Minitest::Mock.new
    mock_client.expect(:verify_password, err_response, ["bob", "correct"])

    user.stub(:client, mock_client) do
      assert_raises(Parse::Error::EmailNotVerifiedError) do
        user.verify_password("correct")
      end
    end

    mock_client.verify
  end

  def test_verify_password_unverified_error_message_contains_code
    user = Parse::User.new
    user.username = "dana"

    err_body     = { "code" => 205, "error" => "User email is not verified." }
    err_response = Parse::Response.new(err_body)
    err_response.http_status = 400

    mock_client = Minitest::Mock.new
    mock_client.expect(:verify_password, err_response, ["dana", "rightpass"])

    user.stub(:client, mock_client) do
      error = assert_raises(Parse::Error::EmailNotVerifiedError) do
        user.verify_password("rightpass")
      end
      assert_match(/205/, error.message)
    end

    mock_client.verify
  end

  # =========================================================================
  # Error class ancestry
  # =========================================================================

  def test_email_not_verified_error_is_parse_error_subclass
    assert Parse::Error::EmailNotVerifiedError.ancestors.include?(Parse::Error),
           "EmailNotVerifiedError must descend from Parse::Error"
  end
end
