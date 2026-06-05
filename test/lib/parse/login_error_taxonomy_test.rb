# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Tests for the typed login-failure taxonomy introduced in response.rb and
# user.rb. Specifically:
#   - Parse::Response::ERROR_EMAIL_NOT_FOUND has the correct numeric value (205).
#   - Parse::User.login! raises EmailNotVerifiedError for code-205 responses.
#   - Parse::User.login! raises the generic AuthenticationError for other codes.
#   - Parse::User.login! returns a user object on success (no raise).
#
# The mock is registered on Parse::User.stub(:client, ...) because
# Parse::User.client is memoised in @client — stubbing Parse::Client.client
# alone would race with the memoised value from a prior test run in the
# same process.
class LoginErrorTaxonomyTest < Minitest::Test

  # =========================================================================
  # Constant values
  # =========================================================================

  def test_error_email_not_found_constant_is_205
    # Parse Server throws code 205 (EMAIL_NOT_FOUND) when
    # preventLoginWithUnverifiedEmail is enabled and the email is unverified.
    assert_equal 205, Parse::Response::ERROR_EMAIL_NOT_FOUND
  end

  def test_error_email_not_verified_class_exists
    assert defined?(Parse::Error::EmailNotVerifiedError),
           "Parse::Error::EmailNotVerifiedError must be defined"
  end

  def test_email_not_verified_error_is_parse_error_subclass
    assert Parse::Error::EmailNotVerifiedError.ancestors.include?(Parse::Error),
           "EmailNotVerifiedError must descend from Parse::Error"
  end

  def test_email_not_verified_error_subclasses_authentication_error
    # EmailNotVerifiedError MUST descend from AuthenticationError: before the
    # typed error existed, a 205 login rejection raised a plain
    # AuthenticationError, so existing `rescue AuthenticationError` handlers
    # must keep catching it (subclassing preserves that contract; a sibling
    # would be a silent breaking change). Callers that want the unverified case
    # specifically just rescue the narrower subclass first.
    assert Parse::Error::EmailNotVerifiedError.ancestors.include?(Parse::Error::AuthenticationError),
           "EmailNotVerifiedError must inherit from AuthenticationError (back-compat)"
  end

  def test_email_not_verified_caught_by_authentication_error_rescue
    raised =
      begin
        raise Parse::Error::EmailNotVerifiedError, "unverified"
      rescue Parse::Error::AuthenticationError => e
        e
      end
    assert_kind_of Parse::Error::EmailNotVerifiedError, raised,
                   "a generic `rescue AuthenticationError` must still catch the unverified case"
  end

  # =========================================================================
  # Parse::User.login! — typed error on code 205
  # =========================================================================

  def test_login_bang_raises_email_not_verified_error_on_code_205
    err_body     = { "code" => 205, "error" => "User email is not verified." }
    err_response = Parse::Response.new(err_body)
    err_response.http_status = 400

    mock_client = Minitest::Mock.new
    mock_client.expect(:login, err_response, ["alice", "correct"])

    Parse::User.stub(:client, mock_client) do
      assert_raises(Parse::Error::EmailNotVerifiedError) do
        Parse::User.login!("alice", "correct")
      end
    end

    mock_client.verify
  end

  def test_login_bang_error_message_includes_username_and_code_on_205
    err_body     = { "code" => 205, "error" => "User email is not verified." }
    err_response = Parse::Response.new(err_body)
    err_response.http_status = 400

    mock_client = Minitest::Mock.new
    mock_client.expect(:login, err_response, ["bob", "pass"])

    Parse::User.stub(:client, mock_client) do
      error = assert_raises(Parse::Error::EmailNotVerifiedError) do
        Parse::User.login!("bob", "pass")
      end
      assert_match(/bob/, error.message)
      assert_match(/205/, error.message)
    end

    mock_client.verify
  end

  # =========================================================================
  # Parse::User.login! — generic AuthenticationError for other error codes
  # =========================================================================

  def test_login_bang_raises_authentication_error_on_code_101
    err_body     = { "code" => 101, "error" => "Invalid username/password." }
    err_response = Parse::Response.new(err_body)
    err_response.http_status = 404

    mock_client = Minitest::Mock.new
    mock_client.expect(:login, err_response, ["alice", "wrong"])

    Parse::User.stub(:client, mock_client) do
      assert_raises(Parse::Error::AuthenticationError) do
        Parse::User.login!("alice", "wrong")
      end
    end

    mock_client.verify
  end

  def test_login_bang_raises_authentication_error_on_code_200
    err_body     = { "code" => 200, "error" => "Username is required." }
    err_response = Parse::Response.new(err_body)
    err_response.http_status = 400

    mock_client = Minitest::Mock.new
    mock_client.expect(:login, err_response, ["", ""])

    Parse::User.stub(:client, mock_client) do
      assert_raises(Parse::Error::AuthenticationError) do
        Parse::User.login!("", "")
      end
    end

    mock_client.verify
  end

  def test_login_bang_raises_authentication_error_without_json_code
    # When Parse Server returns an HTTP error with no JSON body / error code,
    # the generic AuthenticationError must still be raised (not EmailNotVerifiedError).
    err_response = Parse::Response.new({})
    err_response.http_status = 503
    # Simulate missing code / error (service-level failure)
    def err_response.success?; false; end
    def err_response.error?;   true;  end

    mock_client = Minitest::Mock.new
    mock_client.expect(:login, err_response, ["carol", "pass"])

    Parse::User.stub(:client, mock_client) do
      assert_raises(Parse::Error::AuthenticationError) do
        Parse::User.login!("carol", "pass")
      end
    end

    mock_client.verify
  end

  # =========================================================================
  # Parse::User.login! — success path is unchanged
  # =========================================================================

  def test_login_bang_returns_user_on_success
    ok_result   = { "objectId" => "xyz789", "username" => "dave", "sessionToken" => "r:tok123" }
    ok_response = Parse::Response.new(ok_result)

    mock_client = Minitest::Mock.new
    mock_client.expect(:login, ok_response, ["dave", "correct"])

    user = nil
    Parse::User.stub(:client, mock_client) do
      user = Parse::User.login!("dave", "correct")
    end

    assert_instance_of Parse::User, user
    assert_equal "xyz789", user.id
    mock_client.verify
  end

  def test_login_bang_does_not_raise_on_success
    ok_result   = { "objectId" => "abc001", "username" => "eve", "sessionToken" => "r:sessabc" }
    ok_response = Parse::Response.new(ok_result)

    mock_client = Minitest::Mock.new
    mock_client.expect(:login, ok_response, ["eve", "s3cret"])

    Parse::User.stub(:client, mock_client) do
      refute_raises(Parse::Error) do
        Parse::User.login!("eve", "s3cret")
      end
    end

    mock_client.verify
  end

  # =========================================================================
  # Backward-compat: a code-205 login rejection IS caught by an existing
  # `rescue AuthenticationError` (it was a plain AuthenticationError before the
  # typed subclass existed) — AND it is specifically an EmailNotVerifiedError
  # for callers that rescue the narrower subclass first.
  # =========================================================================

  def test_email_not_verified_error_is_caught_by_authentication_error_rescue
    err_body     = { "code" => 205, "error" => "User email is not verified." }
    err_response = Parse::Response.new(err_body)
    err_response.http_status = 400

    mock_client = Minitest::Mock.new
    mock_client.expect(:login, err_response, ["frank", "pass"])

    caught = nil
    Parse::User.stub(:client, mock_client) do
      begin
        Parse::User.login!("frank", "pass")
      rescue Parse::Error::AuthenticationError => e
        caught = e
      end
    end

    refute_nil caught, "a generic `rescue AuthenticationError` must still catch the 205 case"
    assert_kind_of Parse::Error::EmailNotVerifiedError, caught,
                   "the caught error is specifically the typed EmailNotVerifiedError"
    mock_client.verify
  end
end
