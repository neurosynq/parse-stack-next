require_relative "../../test_helper"

# Tests the Rack-level Parse::Webhooks#call! entry point, in particular the
# 3.4.0 fail-closed default when no webhook key is configured.
class WebhookRackCallTest < Minitest::Test
  WEBHOOK_HEADER = "HTTP_X_PARSE_WEBHOOK_KEY"

  def setup
    @saved_key = Parse::Webhooks.instance_variable_get(:@key)
    @saved_allow = Parse::Webhooks.instance_variable_get(:@allow_unauthenticated)
    @saved_logging = Parse::Webhooks.logging
    @saved_warned = Parse::Webhooks.instance_variable_get(:@missing_key_warned)
    @saved_env_key = ENV["PARSE_SERVER_WEBHOOK_KEY"]
    @saved_env_legacy = ENV["PARSE_WEBHOOK_KEY"]
    @saved_env_allow = ENV["PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED"]
    ENV.delete("PARSE_SERVER_WEBHOOK_KEY")
    ENV.delete("PARSE_WEBHOOK_KEY")
    ENV.delete("PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED")
    Parse::Webhooks.instance_variable_set(:@key, nil)
    Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, nil)
    Parse::Webhooks.instance_variable_set(:@missing_key_warned, nil)
    Parse::Webhooks.logging = false
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    # NEW-EXT-4 replay protection: cache is process-wide, so reset between
    # tests so identical bodies across cases don't trip the dedup LRU.
    Parse::Webhooks::ReplayProtection.reset!
  end

  def teardown
    Parse::Webhooks.instance_variable_set(:@key, @saved_key)
    Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, @saved_allow)
    Parse::Webhooks.instance_variable_set(:@missing_key_warned, @saved_warned)
    Parse::Webhooks.logging = @saved_logging
    ENV["PARSE_SERVER_WEBHOOK_KEY"] = @saved_env_key if @saved_env_key
    ENV["PARSE_WEBHOOK_KEY"] = @saved_env_legacy if @saved_env_legacy
    ENV["PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED"] = @saved_env_allow if @saved_env_allow
    Parse::Webhooks.instance_variable_set(:@routes, nil)
  end

  def build_env(body: '{"functionName":"test"}', key_header: nil)
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new(body),
      "CONTENT_LENGTH" => body.bytesize.to_s,
    }
    env[WEBHOOK_HEADER] = key_header if key_header
    env
  end

  def parse_body(status_headers_body)
    JSON.parse(status_headers_body[2].join)
  end

  def test_fails_closed_when_no_key_and_not_allowed
    capture_io do
      status, _headers, body = Parse::Webhooks.call(build_env)
      assert_equal 200, status
      payload = JSON.parse(body.join)
      assert_equal "Webhook key not configured.", payload["error"]
    end
  end

  def test_emits_missing_key_warning_only_once_across_requests
    _out, err = capture_io do
      Parse::Webhooks.call(build_env)
      Parse::Webhooks.call(build_env)
      Parse::Webhooks.call(build_env)
    end
    occurrences = err.scan(/no webhook key configured/).size
    assert_equal 1, occurrences, "expected the missing-key warning to fire once across multiple requests"
  end

  def test_permissive_mode_via_setter_allows_request_without_key
    Parse::Webhooks.allow_unauthenticated = true
    capture_io do
      status, _headers, body = Parse::Webhooks.call(build_env)
      payload = JSON.parse(body.join)
      # No route registered, but request was accepted past the auth gate.
      # success() returns {"success":true} by default.
      assert_equal 200, status
      assert payload.key?("success")
    end
  end

  def test_permissive_mode_via_env_var_allows_request_without_key
    ENV["PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED"] = "true"
    Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, nil)
    capture_io do
      _status, _headers, body = Parse::Webhooks.call(build_env)
      payload = JSON.parse(body.join)
      assert payload.key?("success")
    end
  end

  def test_env_var_strict_truthy_parsing
    # Any value other than literal "true" must NOT enable permissive mode.
    %w[1 yes True TRUE on].each do |val|
      ENV["PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED"] = val
      Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, nil)
      Parse::Webhooks.instance_variable_set(:@missing_key_warned, nil)
      capture_io do
        _status, _headers, body = Parse::Webhooks.call(build_env)
        payload = JSON.parse(body.join)
        assert_equal "Webhook key not configured.", payload["error"], "value #{val.inspect} should not enable permissive mode"
      end
    end
  end

  def test_explicit_false_overrides_env_var
    ENV["PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED"] = "true"
    Parse::Webhooks.allow_unauthenticated = false
    capture_io do
      _status, _headers, body = Parse::Webhooks.call(build_env)
      payload = JSON.parse(body.join)
      assert_equal "Webhook key not configured.", payload["error"]
    end
  end

  def test_key_validated_even_when_allow_unauthenticated_is_true
    # Having both a key configured AND allow_unauthenticated=true must still
    # validate the key — the permissive flag only applies when no key is set.
    Parse::Webhooks.key = "secret"
    Parse::Webhooks.allow_unauthenticated = true
    capture_io do
      _status, _headers, body = Parse::Webhooks.call(build_env(key_header: "wrong"))
      payload = JSON.parse(body.join)
      assert_equal "Invalid Parse Webhook Key", payload["error"]
    end
  end

  def test_valid_key_passes_auth_gate
    Parse::Webhooks.key = "secret"
    capture_io do
      _status, _headers, body = Parse::Webhooks.call(build_env(key_header: "secret"))
      payload = JSON.parse(body.join)
      # No route registered, success() returns {"success":true}
      assert payload.key?("success")
    end
  end

  def test_legacy_parse_webhook_key_env_var
    # The older PARSE_WEBHOOK_KEY name continues to work alongside the
    # newer PARSE_SERVER_WEBHOOK_KEY.
    ENV["PARSE_WEBHOOK_KEY"] = "legacy_key"
    Parse::Webhooks.instance_variable_set(:@key, nil)
    capture_io do
      _status, _headers, body = Parse::Webhooks.call(build_env(key_header: "legacy_key"))
      payload = JSON.parse(body.join)
      assert payload.key?("success")
    end
  end

  def test_parse_server_webhook_key_takes_precedence_over_legacy
    ENV["PARSE_SERVER_WEBHOOK_KEY"] = "primary"
    ENV["PARSE_WEBHOOK_KEY"] = "legacy"
    Parse::Webhooks.instance_variable_set(:@key, nil)
    capture_io do
      _status, _headers, body = Parse::Webhooks.call(build_env(key_header: "legacy"))
      payload = JSON.parse(body.join)
      assert_equal "Invalid Parse Webhook Key", payload["error"]
    end
  end

  def test_key_setter_resets_missing_key_warned
    Parse::Webhooks.instance_variable_set(:@missing_key_warned, true)
    Parse::Webhooks.key = "newly_set"
    assert_nil Parse::Webhooks.instance_variable_get(:@missing_key_warned)
  end

  # ─── Content-Type validation uses exact media_type ─────────────────────
  # The previous substring check on the raw Content-Type header accepted
  # look-alikes (text/application/json, application/jsonp, etc.). Switching
  # to Rack's media_type makes the comparison exact while still allowing
  # legitimate "application/json; charset=utf-8" by stripping parameters.

  def build_env_with_content_type(ct, body: '{"functionName":"x"}')
    {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => ct,
      "rack.input" => StringIO.new(body),
      "CONTENT_LENGTH" => body.bytesize.to_s,
    }
  end

  def test_rejects_application_jsonp_content_type
    Parse::Webhooks.allow_unauthenticated = true
    capture_io do
      _status, _headers, body = Parse::Webhooks.call(
        build_env_with_content_type("application/jsonp"))
      payload = JSON.parse(body.join)
      assert_equal "Invalid content-type format. Should be application/json.",
                   payload["error"]
    end
  end

  def test_rejects_text_prefixed_lookalike_content_type
    Parse::Webhooks.allow_unauthenticated = true
    capture_io do
      _status, _headers, body = Parse::Webhooks.call(
        build_env_with_content_type("text/application/json"))
      payload = JSON.parse(body.join)
      assert_equal "Invalid content-type format. Should be application/json.",
                   payload["error"]
    end
  end

  def test_accepts_application_json_with_charset_parameter
    Parse::Webhooks.allow_unauthenticated = true
    capture_io do
      _status, _headers, body = Parse::Webhooks.call(
        build_env_with_content_type("application/json; charset=utf-8"))
      payload = JSON.parse(body.join)
      # No route registered for "x"; success path returns {"success":true}.
      assert payload.key?("success")
    end
  end

  def test_rejects_missing_content_type
    Parse::Webhooks.allow_unauthenticated = true
    env = {
      "REQUEST_METHOD" => "POST",
      "rack.input" => StringIO.new('{"functionName":"x"}'),
      "CONTENT_LENGTH" => "20",
    }
    capture_io do
      _status, _headers, body = Parse::Webhooks.call(env)
      payload = JSON.parse(body.join)
      assert_equal "Invalid content-type format. Should be application/json.",
                   payload["error"]
    end
  end
end
