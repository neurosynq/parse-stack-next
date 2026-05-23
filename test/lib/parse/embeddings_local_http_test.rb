# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "faraday"

# Unit tests for Parse::Embeddings::LocalHTTP. The SSRF gate runs at
# construct-time against Parse::File.resolve_addresses, so most tests
# either point at a host that does NOT resolve to a private CIDR
# (e.g. "ollama.test") or opt-in via allow_private_endpoint: true for
# the localhost case.
#
# We stub Parse::File.resolve_addresses to return a public IP for the
# synthetic test hostnames so the SSRF gate has something to evaluate
# without burning real DNS. Tests that need a private resolution stub
# the method to return an RFC1918 / loopback / metadata address
# explicitly.
class EmbeddingsLocalHTTPTest < Minitest::Test
  TEST_PUBLIC_IP = IPAddr.new("203.0.113.7").freeze
  TEST_HOSTS_STUB_PUBLIC = %w[
    embeddings.example.com
    embeddings.test
    ollama.test
    embed.test
    public-runner.example.com
  ].freeze

  def setup
    Parse::Embeddings.reset!
    @_orig_resolve = Parse::File.singleton_class.instance_method(:resolve_addresses)
    stub_hosts = TEST_HOSTS_STUB_PUBLIC
    public_ip = TEST_PUBLIC_IP
    orig = @_orig_resolve
    Parse::File.define_singleton_method(:resolve_addresses) do |host|
      if stub_hosts.include?(host)
        [public_ip]
      else
        orig.bind(Parse::File).call(host)
      end
    end
  end

  def teardown
    Parse::Embeddings.reset!
    orig = @_orig_resolve
    Parse::File.define_singleton_method(:resolve_addresses) do |host|
      orig.bind(Parse::File).call(host)
    end
  end

  # ---- constructor validation ------------------------------------------

  def test_requires_base_url
    assert_raises(ArgumentError) { Parse::Embeddings::LocalHTTP.new(model: "m", dimensions: 8) }
  end

  def test_requires_model
    assert_raises(ArgumentError) do
      Parse::Embeddings::LocalHTTP.new(base_url: "https://embeddings.test/v1", dimensions: 8)
    end
  end

  def test_requires_dimensions
    assert_raises(ArgumentError) do
      Parse::Embeddings::LocalHTTP.new(base_url: "https://embeddings.test/v1", model: "m")
    end
  end

  def test_rejects_non_positive_dimensions
    assert_raises(ArgumentError) { build(dimensions: 0) }
    assert_raises(ArgumentError) { build(dimensions: -1) }
    assert_raises(ArgumentError) { build(dimensions: 3.5) }
  end

  def test_rejects_base_url_with_userinfo
    err = assert_raises(ArgumentError) { build(base_url: "https://user:secret@embeddings.test/v1") }
    assert_match(/must not contain userinfo/, err.message)
    refute_match(/secret/, err.message)
  end

  def test_rejects_non_http_base_url
    assert_raises(ArgumentError) { build(base_url: "ftp://embeddings.test/v1") }
    assert_raises(ArgumentError) { build(base_url: "file:///tmp/x") }
  end

  def test_optional_api_key_must_be_non_empty_string_when_given
    assert_raises(ArgumentError) { build(api_key: "") }
    assert_raises(ArgumentError) { build(api_key: 123) }
    # nil is allowed
    refute_nil build(api_key: nil)
  end

  # ---- SSRF gate -------------------------------------------------------

  def test_refuses_private_endpoint_by_default
    err = assert_raises(ArgumentError) do
      Parse::Embeddings::LocalHTTP.new(
        base_url:   "http://127.0.0.1:11434/v1",
        model:      "nomic-embed-text",
        dimensions: 768,
      )
    end
    assert_match(/private\/internal address/, err.message)
    assert_match(/allow_private_endpoint: true/, err.message)
  end

  def test_refuses_loopback_hostname_by_default
    # `localhost` resolves to 127.0.0.1 / ::1 — both are BLOCKED_CIDRS.
    err = assert_raises(ArgumentError) do
      Parse::Embeddings::LocalHTTP.new(
        base_url:   "http://localhost:11434/v1",
        model:      "nomic-embed-text",
        dimensions: 768,
      )
    end
    assert_match(/private\/internal address/, err.message)
  end

  def test_allows_private_endpoint_with_opt_in_and_warns
    output = capture_warnings do
      provider = Parse::Embeddings::LocalHTTP.new(
        base_url:               "http://127.0.0.1:11434/v1",
        model:                  "nomic-embed-text",
        dimensions:             768,
        allow_private_endpoint: true,
      )
      refute_nil provider
    end
    assert_match(/allow_private_endpoint=true/, output)
    assert_match(/127\.0\.0\.1/, output)
  end

  def test_refuses_link_local_metadata_endpoint
    # 169.254.169.254 is the AWS/GCP metadata service. Belt-and-
    # suspenders: confirm the resolved-address gate catches it even
    # when the operator types the literal IP.
    err = assert_raises(ArgumentError) do
      Parse::Embeddings::LocalHTTP.new(
        base_url:   "http://169.254.169.254/v1",
        model:      "exfil",
        dimensions: 8,
      )
    end
    assert_match(/private\/internal address/, err.message)
  end

  def test_refuses_http_for_public_host_without_opt_in
    # A public host (no private resolution) on http:// without
    # allow_insecure_base_url must be refused. We pin this with an IP
    # literal in public space (8.8.8.8) so DNS doesn't affect the test.
    err = assert_raises(ArgumentError) do
      Parse::Embeddings::LocalHTTP.new(
        base_url:   "http://8.8.8.8/v1",
        model:      "x",
        dimensions: 8,
      )
    end
    assert_match(/refusing http:\/\/ base_url for a public host/, err.message)
  end

  def test_allows_http_public_host_with_insecure_opt_in
    refute_nil Parse::Embeddings::LocalHTTP.new(
      base_url:                "http://8.8.8.8/v1",
      model:                   "x",
      dimensions:              8,
      allow_insecure_base_url: true,
    )
  end

  def test_refuses_base_url_that_does_not_resolve_by_default
    # Unresolvable host without allow_private_endpoint must fail closed —
    # an attacker who controls DNS for the hostname could otherwise pass
    # the construct-time gate (empty resolution → "not private") and then
    # flip the record to 169.254.169.254 before the first POST.
    err = assert_raises(ArgumentError) do
      Parse::Embeddings::LocalHTTP.new(
        base_url:   "https://does-not-resolve-anywhere.invalid/v1",
        model:      "x",
        dimensions: 8,
      )
    end
    assert_match(/could not resolve base_url host/, err.message)
  end

  def test_allows_unresolved_base_url_with_private_endpoint_opt_in
    # The local-runner-starts-after-Rails-boot case. The operator has
    # already accepted the localhost-class trust model; a transient DNS
    # failure is acceptable when allow_private_endpoint is set.
    refute_nil Parse::Embeddings::LocalHTTP.new(
      base_url:               "http://does-not-resolve-anywhere.invalid:11434/v1",
      model:                  "x",
      dimensions:             8,
      allow_private_endpoint: true,
    )
  end

  # ---- metadata --------------------------------------------------------

  def test_defaults
    provider = build
    assert_equal "test-model", provider.model_name
    assert_equal 8, provider.dimensions
    assert_equal 32, provider.embed_batch_size
    refute provider.normalize?, "default normalize is false (local runners usually don't)"
    refute provider.supports_input_type?
    assert_equal [:text], provider.modalities
  end

  def test_normalize_can_be_set
    assert build(normalize: true).normalize?
  end

  def test_inspect_does_not_leak_api_key
    provider = build(api_key: "secret-key")
    refute_includes provider.inspect, "secret-key"
    refute_includes provider.inspect, "Bearer"
    assert_includes provider.inspect, "test-model"
  end

  # ---- happy path ------------------------------------------------------

  def test_embed_text_sends_correct_payload_and_parses_response
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(2, 8)]
      end
    end
    provider = build(connection: stubbed_conn(stubs))
    vectors = provider.embed_text(["alpha", "beta"])
    assert_equal 2, vectors.length
    body = JSON.parse(captured_req.request_body)
    assert_equal ["alpha", "beta"], body["input"]
    assert_equal "test-model", body["model"]
    refute body.key?("input_type"), "LocalHTTP must not send input_type (no asymmetry on local servers)"
  end

  def test_embed_text_sends_authorization_only_when_api_key_set
    captured_no_key = nil
    captured_with_key = nil
    stubs_no_key = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_no_key = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 8)]
      end
    end
    stubs_with_key = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_with_key = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 8)]
      end
    end
    build(api_key: nil, connection: stubbed_conn(stubs_no_key)).embed_text(["x"])
    build(api_key: "secret", connection: stubbed_conn(stubs_with_key, with_bearer: "secret")).embed_text(["x"])

    refute captured_no_key.request_headers.key?("Authorization"),
           "no api_key configured → no Authorization header"
    assert_equal "Bearer secret", captured_with_key.request_headers["Authorization"]
  end

  def test_embed_text_empty_batch_short_circuits
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| flunk "Should not hit local server for empty batch" }
    end
    provider = build(connection: stubbed_conn(stubs))
    assert_equal [], provider.embed_text([])
  end

  def test_embed_text_rejects_empty_string
    provider = build(connection: stubbed_conn(empty_stubs))
    err = assert_raises(ArgumentError) { provider.embed_text(["ok", ""]) }
    assert_match(/empty/, err.message)
  end

  # ---- response-shape validation ---------------------------------------

  def test_tolerates_responses_without_index_field
    # vLLM and some llama.cpp builds omit `index`. Confirm we fall
    # back to positional alignment.
    body = {
      "data" => [
        { "embedding" => Array.new(8, 1.0 / Math.sqrt(8)) },
        { "embedding" => Array.new(8, 1.0 / Math.sqrt(8)) },
      ],
      "model" => "test-model",
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, body] }
    end
    provider = build(connection: stubbed_conn(stubs))
    vectors = provider.embed_text(["a", "b"])
    assert_equal 2, vectors.length
  end

  def test_sorts_indexed_responses
    body = {
      "data" => [
        { "index" => 1, "embedding" => Array.new(8, 2.0 / 8) },
        { "index" => 0, "embedding" => Array.new(8, 1.0 / 8) },
      ],
      "model" => "test-model",
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, body] }
    end
    provider = build(connection: stubbed_conn(stubs))
    vectors = provider.embed_text(["first", "second"])
    assert_in_delta 1.0 / 8, vectors[0][0], 1e-9
    assert_in_delta 2.0 / 8, vectors[1][0], 1e-9
  end

  def test_wrong_width_vector_is_rejected
    body = {
      "data" => [{ "embedding" => Array.new(16, 0.0) }],
      "model" => "test-model",
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, body] }
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) { provider.embed_text(["a"]) }
    assert_match(/length 16 != declared dimensions 8/, err.message)
  end

  def test_non_json_response_raises_invalid_response
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "text/html" }, "<html>"] }
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) { provider.embed_text(["a"]) }
    assert_match(/not valid JSON/, err.message)
  end

  # ---- HTTP status handling --------------------------------------------

  def test_401_raises_authentication_error_without_retry
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_env| calls += 1; [401, {}, "bad key"] }
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 3)
    assert_raises(Parse::Embeddings::LocalHTTP::AuthenticationError) { provider.embed_text(["a"]) }
    assert_equal 1, calls
  end

  def test_5xx_retries_then_succeeds
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        calls += 1
        if calls < 2
          [503, {}, "down"]
        else
          [200, { "Content-Type" => "application/json" }, fake_response(1, 8)]
        end
      end
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 3)
    silence_sleep(provider) { provider.embed_text(["a"]) }
    assert_equal 2, calls
  end

  # ---- error class hierarchy ------------------------------------------

  def test_all_local_http_errors_subclass_parse_embeddings_error
    [
      Parse::Embeddings::LocalHTTP::AuthenticationError,
      Parse::Embeddings::LocalHTTP::BadRequestError,
      Parse::Embeddings::LocalHTTP::RateLimitError,
      Parse::Embeddings::LocalHTTP::TransientError,
    ].each do |klass|
      assert klass < Parse::Embeddings::Error
    end
  end

  # ---- registry integration --------------------------------------------

  def test_registers_via_short_form
    provider = build(connection: stubbed_conn(empty_stubs))
    Parse::Embeddings.register(:ollama, provider)
    assert_same provider, Parse::Embeddings.provider(:ollama)
  end

  # ---- AS::N notification ----------------------------------------------

  def test_embed_emits_as_n_event
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, fake_response(1, 8)] }
    end
    provider = build(connection: stubbed_conn(stubs))

    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("parse.embeddings.embed") do |*args|
      captured << ActiveSupport::Notifications::Event.new(*args)
    end
    begin
      provider.embed_text(["x"])
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 1, captured.length
    payload = captured.first.payload
    assert_equal "Parse::Embeddings::LocalHTTP", payload[:provider]
    assert_equal "test-model", payload[:model]
    assert_equal 8, payload[:dimensions]
    assert_nil payload[:error]
  end

  private

  # Default builder uses a public-resolution host so the SSRF gate
  # passes without requiring allow_private_endpoint.
  def build(**overrides)
    opts = {
      base_url:   "https://embeddings.example.com/v1",
      model:      "test-model",
      dimensions: 8,
    }.merge(overrides)
    Parse::Embeddings::LocalHTTP.new(**opts)
  end

  def stubbed_conn(stubs, with_bearer: nil)
    headers = { "Content-Type" => "application/json" }
    headers["Authorization"] = "Bearer #{with_bearer}" if with_bearer
    Faraday.new(url: "https://embeddings.example.com/v1", headers: headers) do |f|
      f.adapter :test, stubs
    end
  end

  def empty_stubs
    Faraday::Adapter::Test::Stubs.new
  end

  def fake_response(count, dim)
    {
      "data" => (0...count).map do |i|
        { "index" => i, "embedding" => Array.new(dim, 1.0 / Math.sqrt(dim)) }
      end,
      "model" => "test-model",
    }.to_json
  end

  def silence_sleep(provider)
    provider.define_singleton_method(:backoff_seconds) { |_| 0 }
    yield
  end

  # Capture Kernel#warn output for the duration of the block.
  def capture_warnings
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
