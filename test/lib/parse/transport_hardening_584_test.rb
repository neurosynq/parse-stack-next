# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "moneta"
require "stringio"
require "openssl"

# Transport and webhook hardening:
# - absolute / protocol-relative request paths are refused before they can
#   carry the master key or a session token to another host
# - PARSE_REQUIRE_HTTPS accepts the usual truthy spellings
# - userinfo in the server URL is redacted from inspect / as_json / warnings
# - a caller-built Moneta cache that Marshal-deserializes values from an
#   external backend is refused unless explicitly allowed
# - a whitespace-only webhook signing secret counts as unset, and an empty
#   PARSE_SERVER_WEBHOOK_KEY does not hide PARSE_WEBHOOK_KEY
# - oversize webhook bodies are refused before being buffered in full
class TransportHardening584Test < Minitest::Test
  SERVER = "https://example.parse.local/parse"

  # Records what the client would send instead of opening a socket.
  class RecordingConn
    Env = Struct.new(:body)
    attr_reader :calls

    def initialize
      @calls = []
    end

    def send(method, uri, params, headers)
      @calls << [method, uri, params, headers]
      response = Parse::Response.new({ "results" => [] })
      response.http_status = 200
      Env.new(response)
    end
  end

  def build_client(**opts)
    Parse::Client.new({ server_url: SERVER, application_id: "app", master_key: "mk" }.merge(opts))
  end

  def recording_client
    client = build_client
    conn = RecordingConn.new
    client.instance_variable_set(:@conn, conn)
    [client, conn]
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # ---- request paths -------------------------------------------------------

  UNSAFE_PATHS = [
    "https://attacker.example/x",
    "HTTP://attacker.example/x",
    "  https://attacker.example/x",
    "\thttp://attacker.example/x",
    "ftp://attacker.example/x",
    "//attacker.example/x",
    "\\\\attacker.example\\x",
    "/\\attacker.example/x",
    "\\/attacker.example/x",
    " //attacker.example/x",
  ].freeze

  def test_unsafe_paths_are_refused_by_request_and_helpers
    client, conn = recording_client
    UNSAFE_PATHS.each do |path|
      assert_raises(ArgumentError, "request #{path.inspect}") { client.request(:get, path) }
      assert_raises(ArgumentError, "get #{path.inspect}") { client.get(path) }
      assert_raises(ArgumentError, "post #{path.inspect}") { client.post(path, {}) }
      assert_raises(ArgumentError, "put #{path.inspect}") { client.put(path, {}) }
      assert_raises(ArgumentError, "delete #{path.inspect}") { client.delete(path) }
      assert_raises(ArgumentError, "connected? #{path.inspect}") { client.connected?(path) }
    end
    assert_empty conn.calls, "no unsafe request may reach the connection"
  end

  def test_unsafe_path_in_a_parse_request_is_refused
    client, conn = recording_client
    req = Parse::Request.new(:get, "https://attacker.example/x")
    assert_raises(ArgumentError) { client.send_request(req) }
    assert_empty conn.calls
  end

  def test_relative_paths_still_work
    client, conn = recording_client
    ["classes/Song", "/classes/Song", "classes/Song?where=%7B%22a%22%3A1%7D",
     "functions/hello", "health", "users/me"].each do |path|
      assert client.get(path).success?, path
    end
    assert_equal 6, conn.calls.size
    assert client.connected?
  end

  def test_unsafe_request_path_predicate
    refute Parse::Client.unsafe_request_path?(nil)
    refute Parse::Client.unsafe_request_path?("classes/Song?keys=a:b")
    refute Parse::Client.unsafe_request_path?("classes/Song/abc")
    assert Parse::Client.unsafe_request_path?("javascript:alert(1)")
    assert Parse::Client.unsafe_request_path?(URI("https://attacker.example/"))
  end

  # ---- PARSE_REQUIRE_HTTPS -------------------------------------------------

  def test_require_https_env_accepts_truthy_spellings
    %w[true TRUE True 1 yes YES].push(" true ").each do |value|
      with_env("PARSE_REQUIRE_HTTPS" => value) do
        assert_raises(ArgumentError, value.inspect) { build_client(server_url: "http://parse.example.com/parse") }
      end
    end
  end

  def test_require_https_env_falsey_only_warns
    ["false", "0", "", "no"].each do |value|
      with_env("PARSE_REQUIRE_HTTPS" => value) do
        _out, err = capture_io { build_client(server_url: "http://parse.example.com/parse") }
        assert_match(/SECURITY WARNING/, err)
      end
    end
  end

  def test_require_https_explicit_option_wins_over_env
    with_env("PARSE_REQUIRE_HTTPS" => "true") do
      capture_io { build_client(server_url: "http://parse.example.com/parse", require_https: false) }
    end
  end

  # ---- server URL userinfo -------------------------------------------------

  def test_userinfo_redacted_from_inspect_and_as_json
    client = nil
    capture_io { client = build_client(server_url: "https://alice:s3cret@parse.example.com/parse") }
    refute_includes client.inspect, "s3cret"
    refute_includes client.inspect, "alice"
    assert_includes client.inspect, "[FILTERED]@parse.example.com"
    refute_includes client.to_json, "s3cret"
    assert_equal "https://[FILTERED]@parse.example.com/parse/", client.as_json["server_url"]
    # The real URL is still used for the connection.
    assert_includes client.server_url, "alice:s3cret@"
  end

  def test_userinfo_redacted_from_https_error_and_warning
    err = assert_raises(ArgumentError) do
      capture_io { build_client(server_url: "http://bob:pw@parse.example.com/parse", require_https: true) }
    end
    refute_includes err.message, "bob:pw"
    assert_includes err.message, "[FILTERED]@"

    Parse::Client.instance_variable_set(:@userinfo_warned, nil)
    _out, warned = capture_io { build_client(server_url: "http://bob:pw@parse.example.com/parse") }
    refute_includes warned, "bob:pw"
    assert_match(/embedded credentials/, warned)
  ensure
    Parse::Client.instance_variable_set(:@userinfo_warned, nil)
  end

  def test_redact_url_userinfo_handles_at_in_password
    assert_equal "https://[FILTERED]@h/parse", Parse::Client.redact_url_userinfo("https://u:p@ss@h/parse")
    assert_equal "https://h/parse?x=a@b", Parse::Client.redact_url_userinfo("https://h/parse?x=a@b")
    assert_nil Parse::Client.redact_url_userinfo(nil)
  end

  # ---- Marshal-serializing caches ------------------------------------------

  def marshal_redis
    Moneta.new(:Redis, url: "redis://127.0.0.1:1/0") # connects lazily
  end

  def test_marshal_redis_cache_is_refused
    err = assert_raises(ArgumentError) { build_client(cache: marshal_redis, expires: 10) }
    assert_match(/Marshal/, err.message)
    assert_match(/allow_marshal_cache/, err.message)
  end

  def test_marshal_cache_wrapped_in_expires_is_refused
    store = Moneta.new(:Redis, url: "redis://127.0.0.1:1/0", expires: true, logger: { out: StringIO.new })
    assert Parse::Client.marshal_value_cache?(store)
    store2 = Moneta.build do
      use :Logger, out: StringIO.new
      use :Transformer, value: [:marshal, :zlib]
      adapter :Redis, url: "redis://127.0.0.1:1/0"
    end
    assert Parse::Client.marshal_value_cache?(store2)
  end

  def test_marshal_cache_allowed_with_opt_in_and_warns
    _out, err = capture_io { build_client(cache: marshal_redis, expires: 10, allow_marshal_cache: true) }
    assert_match(/allow_marshal_cache: true/, err)
  end

  def test_safe_caches_are_accepted
    refute Parse::Client.marshal_value_cache?(Moneta.new(:Redis, url: "redis://127.0.0.1:1/0", value_serializer: nil))
    refute Parse::Client.marshal_value_cache?(Moneta.new(:Memory))
    refute Parse::Client.marshal_value_cache?(Moneta.new(:Memory, expires: true))
    refute Parse::Client.marshal_value_cache?(Moneta.new(:LRUHash, expires: 60))
    refute Parse::Client.marshal_value_cache?({})
    build_client(cache: Moneta.new(:Memory, expires: true), expires: 10)
    build_client(cache: Moneta.new(:Redis, url: "redis://127.0.0.1:1/0", value_serializer: nil), expires: 10)
  end

  # ---- webhook key and signing secret --------------------------------------

  WEBHOOK_HEADER = Parse::Webhooks::HTTP_PARSE_WEBHOOK

  def setup
    @saved_key = Parse::Webhooks.instance_variable_get(:@key)
    @saved_logging = Parse::Webhooks.logging
    Parse::Webhooks.logging = false
    Parse::Webhooks::ReplayProtection.reset!
  end

  def teardown
    Parse::Webhooks.key = @saved_key
    Parse::Webhooks.logging = @saved_logging
    Parse::Webhooks::ReplayProtection.reset!
  end

  def test_blank_server_webhook_key_env_does_not_hide_fallback
    Parse::Webhooks.key = nil
    with_env("PARSE_SERVER_WEBHOOK_KEY" => "", "PARSE_WEBHOOK_KEY" => "fallback-key") do
      assert_equal "fallback-key", Parse::Webhooks.key
    end
    Parse::Webhooks.key = nil
    with_env("PARSE_SERVER_WEBHOOK_KEY" => "   ", "PARSE_WEBHOOK_KEY" => nil) do
      assert_nil Parse::Webhooks.key
    end
    Parse::Webhooks.key = nil
  end

  def test_whitespace_signing_secret_is_treated_as_unset
    Parse::Webhooks::ReplayProtection.signing_secret = "   "
    error, verified = Parse::Webhooks::ReplayProtection.check({}, "{}", nil)
    assert_nil error
    refute verified, "a whitespace secret must not mark a request as signature-verified"
  end

  def test_whitespace_signing_secret_env_is_treated_as_unset
    with_env("PARSE_WEBHOOK_SIGNING_SECRET" => " \t ") do
      error, verified = Parse::Webhooks::ReplayProtection.check({}, "{}", nil)
      assert_nil error
      refute verified
    end
  end

  def test_real_signing_secret_still_enforced
    Parse::Webhooks::ReplayProtection.signing_secret = "topsecret"
    error, _verified = Parse::Webhooks::ReplayProtection.check({}, "{}", nil)
    assert_equal "Missing webhook signature.", error
  end

  # ---- webhook body size ---------------------------------------------------

  def webhook_call(body, content_length: body.bytesize.to_s)
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/",
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new(body),
      WEBHOOK_HEADER => "hook-key",
    }
    env["CONTENT_LENGTH"] = content_length unless content_length.nil?
    status, _headers, chunks = nil
    capture_io { status, _headers, chunks = Parse::Webhooks.call(env) }
    [status, chunks.join]
  end

  def test_declared_oversize_body_is_refused_without_reading
    Parse::Webhooks.key = "hook-key"
    input = StringIO.new("{}")
    def input.read(*)
      raise "body must not be read"
    end
    env = {
      "REQUEST_METHOD" => "POST", "PATH_INFO" => "/", "CONTENT_TYPE" => "application/json",
      "rack.input" => input, "CONTENT_LENGTH" => (Parse::Webhooks::MAX_BODY_BYTES + 1).to_s,
      WEBHOOK_HEADER => "hook-key",
    }
    chunks = nil
    capture_io { _s, _h, chunks = Parse::Webhooks.call(env) }
    assert_match(/Payload too large/, chunks.join)
  end

  def test_understated_oversize_body_is_refused
    Parse::Webhooks.key = "hook-key"
    big = "{\"a\":\"#{"x" * (Parse::Webhooks::MAX_BODY_BYTES + 10)}\"}"
    _status, body = webhook_call(big, content_length: "10")
    assert_match(/Payload too large/, body)
    _status, body = webhook_call(big, content_length: nil)
    assert_match(/Payload too large/, body)
  end

  def test_body_at_limit_is_accepted
    Parse::Webhooks.key = "hook-key"
    payload = { "functionName" => "nope", "params" => { "pad" => "" } }
    pad = Parse::Webhooks::MAX_BODY_BYTES - payload.to_json.bytesize
    payload["params"]["pad"] = "x" * pad
    json = payload.to_json
    assert_equal Parse::Webhooks::MAX_BODY_BYTES, json.bytesize
    _status, body = webhook_call(json)
    refute_match(/Payload too large/, body)
  end
end
