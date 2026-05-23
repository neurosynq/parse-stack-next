require_relative "../../../test_helper"

class TestSafeWarn < Minitest::Test
  extend Minitest::Spec::DSL

  def make_response(error:, code: 141, http_status: 400)
    r = Parse::Response.new("code" => code, "error" => error)
    r.http_status = http_status
    r
  end

  def test_redacts_session_token_from_error_string
    r = make_response(error: 'login denied: sessionToken="r:abc123secret456" rejected')

    _out, err = capture_io do
      Parse::Client._safe_warn("AuthenticationError", r)
    end

    assert_match(/\[Parse:AuthenticationError\]/, err)
    refute_match(/abc123secret456/, err, "raw session token must not appear in stderr")
    assert_match(/\[FILTERED\]/, err)
  end

  def test_redacts_password_field
    r = make_response(error: 'failed: password="hunter2"')

    _out, err = capture_io do
      Parse::Client._safe_warn("ServerError", r)
    end

    refute_match(/hunter2/, err)
    assert_match(/\[FILTERED\]/, err)
  end

  def test_redacts_access_token
    r = make_response(error: 'oauth: access_token=ya29.LIVE-TOKEN expired')

    _out, err = capture_io do
      Parse::Client._safe_warn("AuthenticationError", r)
    end

    refute_match(/ya29\.LIVE-TOKEN/, err)
    assert_match(/\[FILTERED\]/, err)
  end

  def test_truncates_long_error_messages
    long = "X" * 5_000
    r = make_response(error: long)

    _out, err = capture_io do
      Parse::Client._safe_warn("ServerError", r)
    end

    # SAFE_WARN_MAX_ERROR_LENGTH is 200; line length should not balloon to thousands.
    assert err.length < 500, "expected truncated output, got #{err.length} chars"
    assert_equal Parse::Client::SAFE_WARN_MAX_ERROR_LENGTH, 200
  end

  def test_named_form_uses_cloud_code_format
    r = make_response(error: "Boom")

    _out, err = capture_io do
      Parse::Client._safe_warn("CloudCodeError", r, name: "addUserToTeams")
    end

    assert_match(/\[Parse:CloudCodeError\] `addUserToTeams` \[141\] Boom \(HTTP 400\)/, err)
  end

  def test_unnamed_form_uses_http_error_format
    r = make_response(error: "Unauthorized", code: 209, http_status: 401)

    _out, err = capture_io do
      Parse::Client._safe_warn("InvalidSessionTokenError", r)
    end

    # Preserves the prior `Response#to_s` shape: [Parse:Tag] [E-code] req : err (status)
    assert_match(/\[Parse:InvalidSessionTokenError\] \[E-209\] /, err)
    assert_match(/Unauthorized/, err)
    assert_match(/\(401\)/, err)
  end

  def test_handles_nil_error_string
    r = Parse::Response.new
    r.http_status = 500
    # No code, no error fields set — both will be nil

    # Should not raise even on a degenerate response.
    _out, err = capture_io do
      Parse::Client._safe_warn("ServerError", r)
    end

    assert_match(/\[Parse:ServerError\]/, err)
  end

  def test_returns_nil
    r = make_response(error: "x")
    capture_io do
      assert_nil Parse::Client._safe_warn("ServerError", r)
    end
  end
end
