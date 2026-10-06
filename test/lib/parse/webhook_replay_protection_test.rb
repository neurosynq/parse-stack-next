# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "openssl"

# Tests Parse::Webhooks::ReplayProtection: the nonce-keyed dedup LRU and
# the opt-in HMAC freshness verification added for NEW-EXT-4.
class WebhookReplayProtectionTest < Minitest::Test
  WEBHOOK_HEADER = "HTTP_X_PARSE_WEBHOOK_KEY"

  def setup
    @saved_key = Parse::Webhooks.instance_variable_get(:@key)
    @saved_allow = Parse::Webhooks.instance_variable_get(:@allow_unauthenticated)
    @saved_logging = Parse::Webhooks.logging
    @saved_warned = Parse::Webhooks.instance_variable_get(:@missing_key_warned)
    @saved_env_key = ENV["PARSE_SERVER_WEBHOOK_KEY"]
    @saved_env_legacy = ENV["PARSE_WEBHOOK_KEY"]
    @saved_env_allow = ENV["PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED"]
    @saved_env_secret = ENV["PARSE_WEBHOOK_SIGNING_SECRET"]
    ENV.delete("PARSE_SERVER_WEBHOOK_KEY")
    ENV.delete("PARSE_WEBHOOK_KEY")
    ENV.delete("PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED")
    ENV.delete("PARSE_WEBHOOK_SIGNING_SECRET")
    Parse::Webhooks.instance_variable_set(:@key, "test_key")
    Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, nil)
    Parse::Webhooks.instance_variable_set(:@missing_key_warned, nil)
    Parse::Webhooks.logging = false
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    # Unregistered functions are answered with an error, so register the
    # function names these requests call.
    %w[a b c expiry hello signed x].each do |name|
      Parse::Webhooks.route(:function, name) { true }
    end
    Parse::Webhooks::ReplayProtection.reset!
  end

  def teardown
    Parse::Webhooks.instance_variable_set(:@key, @saved_key)
    Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, @saved_allow)
    Parse::Webhooks.instance_variable_set(:@missing_key_warned, @saved_warned)
    Parse::Webhooks.logging = @saved_logging
    # Restore each variable, deleting it when it was unset before the test,
    # so a secret set here never leaks into later test files.
    {
      "PARSE_SERVER_WEBHOOK_KEY" => @saved_env_key,
      "PARSE_WEBHOOK_KEY" => @saved_env_legacy,
      "PARSE_WEBHOOK_ALLOW_UNAUTHENTICATED" => @saved_env_allow,
      "PARSE_WEBHOOK_SIGNING_SECRET" => @saved_env_secret,
    }.each { |name, saved| saved.nil? ? ENV.delete(name) : ENV[name] = saved }
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks::ReplayProtection.reset!
  end

  def build_env(body:, request_id: nil, key: "test_key",
                timestamp: nil, signature: nil)
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new(body),
      "CONTENT_LENGTH" => body.bytesize.to_s,
      WEBHOOK_HEADER => key,
    }
    env["HTTP_X_PARSE_REQUEST_ID"] = request_id if request_id
    env["HTTP_X_PARSE_WEBHOOK_TIMESTAMP"] = timestamp.to_s if timestamp
    env["HTTP_X_PARSE_WEBHOOK_SIGNATURE"] = signature if signature
    env
  end

  def parse_body(rack_response)
    JSON.parse(rack_response[2].join)
  end

  # ==========================================================================
  # Layer 1 - nonce-keyed dedup
  # ==========================================================================

  def test_first_request_passes_dedup
    body = '{"functionName":"hello","params":{}}'
    capture_io do
      _status, _headers, body_io = Parse::Webhooks.call(build_env(body: body, request_id: "_RB_abc"))
      payload = parse_body([nil, nil, body_io])
      assert payload.key?("success"), "first request must pass: #{payload.inspect}"
    end
  end

  def test_immediate_replay_is_refused
    body = '{"functionName":"hello","params":{}}'
    capture_io do
      Parse::Webhooks.call(build_env(body: body, request_id: "_RB_xyz"))
      _status, _headers, body_io = Parse::Webhooks.call(build_env(body: body, request_id: "_RB_xyz"))
      payload = parse_body([nil, nil, body_io])
      assert_equal "Webhook replay detected.", payload["error"]
    end
  end

  def test_distinct_request_id_is_not_a_replay
    body = '{"functionName":"hello","params":{}}'
    capture_io do
      Parse::Webhooks.call(build_env(body: body, request_id: "_RB_one"))
      _status, _headers, body_io = Parse::Webhooks.call(build_env(body: body, request_id: "_RB_two"))
      payload = parse_body([nil, nil, body_io])
      assert payload.key?("success"), "different request-id must pass: #{payload.inspect}"
    end
  end

  def test_distinct_body_is_not_a_replay
    capture_io do
      Parse::Webhooks.call(build_env(body: '{"functionName":"a"}', request_id: "_RB_same"))
      _status, _headers, body_io = Parse::Webhooks.call(build_env(body: '{"functionName":"b"}', request_id: "_RB_same"))
      payload = parse_body([nil, nil, body_io])
      assert payload.key?("success"), "different body must pass: #{payload.inspect}"
    end
  end

  def test_identical_bodies_without_a_nonce_are_not_rejected
    # Parse Server sends no request id or nonce on webhook deliveries, so two
    # legitimate identical calls (the same function with the same params)
    # must both run. Body-only dedup rejected the second one.
    body = '{"functionName":"hello"}'
    capture_io do
      Parse::Webhooks.call(build_env(body: body))
      _status, _headers, body_io = Parse::Webhooks.call(build_env(body: body))
      payload = parse_body([nil, nil, body_io])
      assert payload.key?("success"), "an identical repeat without a nonce must pass: #{payload.inspect}"
    end
  end

  def test_nonce_header_enables_dedup
    body = '{"functionName":"hello"}'
    capture_io do
      env = build_env(body: body)
      env["HTTP_X_PARSE_WEBHOOK_NONCE"] = "n-1"
      Parse::Webhooks.call(env)
      env2 = build_env(body: body)
      env2["HTTP_X_PARSE_WEBHOOK_NONCE"] = "n-1"
      _status, _headers, body_io = Parse::Webhooks.call(env2)
      assert_equal "Webhook replay detected.", parse_body([nil, nil, body_io])["error"]
      env3 = build_env(body: body)
      env3["HTTP_X_PARSE_WEBHOOK_NONCE"] = "n-2"
      _status, _headers, body_io = Parse::Webhooks.call(env3)
      assert parse_body([nil, nil, body_io]).key?("success"), "a fresh nonce must pass"
    end
  end

  def test_replay_window_expiry_allows_retry
    Parse::Webhooks::ReplayProtection.replay_window_seconds = 1
    body = '{"functionName":"expiry"}'
    capture_io do
      Parse::Webhooks.call(build_env(body: body, request_id: "_RB_exp"))
      # Roll the clock forward past the window without sleeping.
      future = Time.now + 2
      Time.stub(:now, future) do
        _status, _headers, body_io = Parse::Webhooks.call(build_env(body: body, request_id: "_RB_exp"))
        payload = parse_body([nil, nil, body_io])
        assert payload.key?("success"), "post-window retry must succeed: #{payload.inspect}"
      end
    end
  end

  def test_lru_evicts_oldest_when_over_capacity
    Parse::Webhooks::ReplayProtection.replay_cache_size = 2
    capture_io do
      Parse::Webhooks.call(build_env(body: '{"functionName":"a"}', request_id: "_RB_a"))
      Parse::Webhooks.call(build_env(body: '{"functionName":"b"}', request_id: "_RB_b"))
      Parse::Webhooks.call(build_env(body: '{"functionName":"c"}', request_id: "_RB_c"))
      # The "a" entry must have been evicted, so re-sending it succeeds.
      _status, _headers, body_io = Parse::Webhooks.call(build_env(body: '{"functionName":"a"}', request_id: "_RB_a"))
      payload = parse_body([nil, nil, body_io])
      assert payload.key?("success"), "evicted entry should re-pass: #{payload.inspect}"
    end
  end

  # ==========================================================================
  # Layer 2 - opt-in HMAC signature
  # ==========================================================================

  SECRET = "s3cret-shared-with-parse-server"

  def sign(body, ts)
    OpenSSL::HMAC.hexdigest("SHA256", SECRET, "#{ts}.#{body}")
  end

  def test_signature_required_when_secret_configured
    Parse::Webhooks::ReplayProtection.signing_secret = SECRET
    capture_io do
      _status, _headers, body_io = Parse::Webhooks.call(build_env(body: '{"functionName":"x"}', request_id: "_RB_n1"))
      payload = parse_body([nil, nil, body_io])
      assert_equal "Missing webhook signature.", payload["error"]
    end
  end

  def test_valid_signature_passes
    Parse::Webhooks::ReplayProtection.signing_secret = SECRET
    body = '{"functionName":"signed"}'
    ts = Time.now.to_i
    capture_io do
      _status, _headers, body_io = Parse::Webhooks.call(build_env(
        body: body, request_id: "_RB_sig1",
        timestamp: ts, signature: sign(body, ts),
      ))
      payload = parse_body([nil, nil, body_io])
      assert payload.key?("success"), "valid signature must pass: #{payload.inspect}"
    end
  end

  # A captured signed delivery cannot be replayed by changing or dropping the
  # unsigned nonce: signed deliveries are deduplicated on their signature.
  def test_signed_replay_with_altered_nonce_is_rejected
    Parse::Webhooks::ReplayProtection.signing_secret = SECRET
    body = '{"functionName":"signed"}'
    ts = Time.now.to_i
    sig = sign(body, ts)
    capture_io do
      first = parse_body([nil, nil, Parse::Webhooks.call(build_env(body: body, request_id: "_RB_r1",
                                                                     timestamp: ts, signature: sig))[2]])
      assert first.key?("success"), first.inspect
      %w[_RB_r2 different].each do |nonce|
        replay = parse_body([nil, nil, Parse::Webhooks.call(build_env(body: body, request_id: nonce,
                                                                        timestamp: ts, signature: sig))[2]])
        assert_equal "Webhook replay detected.", replay["error"], "nonce #{nonce}"
      end
      no_nonce = parse_body([nil, nil, Parse::Webhooks.call(build_env(body: body, timestamp: ts, signature: sig))[2]])
      assert_equal "Webhook replay detected.", no_nonce["error"]
    end
  end

  def test_tampered_body_is_rejected
    Parse::Webhooks::ReplayProtection.signing_secret = SECRET
    body = '{"functionName":"signed"}'
    ts = Time.now.to_i
    valid_sig = sign(body, ts)
    capture_io do
      _status, _headers, body_io = Parse::Webhooks.call(build_env(
        body: '{"functionName":"TAMPERED"}', request_id: "_RB_sig2",
        timestamp: ts, signature: valid_sig,
      ))
      payload = parse_body([nil, nil, body_io])
      assert_equal "Invalid webhook signature.", payload["error"]
    end
  end

  def test_stale_timestamp_is_rejected
    Parse::Webhooks::ReplayProtection.signing_secret = SECRET
    Parse::Webhooks::ReplayProtection.signing_max_skew_seconds = 60
    body = '{"functionName":"signed"}'
    ts = Time.now.to_i - 3600 # 1h ago, well outside the 60s window
    capture_io do
      _status, _headers, body_io = Parse::Webhooks.call(build_env(
        body: body, request_id: "_RB_sig3",
        timestamp: ts, signature: sign(body, ts),
      ))
      payload = parse_body([nil, nil, body_io])
      assert_equal "Stale webhook timestamp.", payload["error"]
    end
  end

  def test_future_timestamp_outside_skew_is_rejected
    Parse::Webhooks::ReplayProtection.signing_secret = SECRET
    Parse::Webhooks::ReplayProtection.signing_max_skew_seconds = 30
    body = '{"functionName":"signed"}'
    ts = Time.now.to_i + 600 # 10 min in the future
    capture_io do
      _status, _headers, body_io = Parse::Webhooks.call(build_env(
        body: body, request_id: "_RB_sig4",
        timestamp: ts, signature: sign(body, ts),
      ))
      payload = parse_body([nil, nil, body_io])
      assert_equal "Stale webhook timestamp.", payload["error"]
    end
  end

  def test_garbage_timestamp_header_is_rejected
    Parse::Webhooks::ReplayProtection.signing_secret = SECRET
    body = '{"functionName":"signed"}'
    capture_io do
      _status, _headers, body_io = Parse::Webhooks.call(build_env(
        body: body, request_id: "_RB_sig5",
        timestamp: "not-a-number", signature: "deadbeef",
      ))
      payload = parse_body([nil, nil, body_io])
      assert_equal "Invalid webhook timestamp.", payload["error"]
    end
  end

  def test_env_var_configures_secret
    ENV["PARSE_WEBHOOK_SIGNING_SECRET"] = SECRET
    Parse::Webhooks::ReplayProtection.reset!
    capture_io do
      _status, _headers, body_io = Parse::Webhooks.call(build_env(body: '{"functionName":"x"}', request_id: "_RB_env"))
      payload = parse_body([nil, nil, body_io])
      assert_equal "Missing webhook signature.", payload["error"]
    end
  end

  def test_signing_disabled_when_secret_blank
    # Explicit empty string is treated as no secret configured.
    Parse::Webhooks::ReplayProtection.signing_secret = ""
    capture_io do
      _status, _headers, body_io = Parse::Webhooks.call(build_env(body: '{"functionName":"x"}', request_id: "_RB_blank"))
      payload = parse_body([nil, nil, body_io])
      assert payload.key?("success"), "blank secret should disable signing: #{payload.inspect}"
    end
  end
end
