# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "faraday"

# Unit tests for Parse::Embeddings::Cohere. No network — every test
# injects a Faraday::Adapter::Test connection.
class EmbeddingsCohereTest < Minitest::Test
  API_KEY = "co-test-DO-NOT-LEAK"

  def setup
    Parse::Embeddings.reset!
  end

  def teardown
    Parse::Embeddings.reset!
  end

  # ---- constructor validation ------------------------------------------

  def test_requires_api_key
    err = assert_raises(ArgumentError) { build(api_key: nil) }
    assert_match(/api_key must be a non-empty String/, err.message)
    assert_raises(ArgumentError) { build(api_key: "") }
  end

  def test_rejects_unknown_model
    err = assert_raises(ArgumentError) { build(model: "made-up-model") }
    assert_match(/unknown model/, err.message)
  end

  def test_refuses_http_base_url_by_default
    err = assert_raises(ArgumentError) { build(base_url: "http://api.cohere.com/v1") }
    assert_match(/refusing http:\/\//, err.message)
  end

  def test_allows_http_base_url_with_opt_in
    refute_nil build(base_url: "http://api.cohere.test/v1", allow_insecure_base_url: true)
  end

  def test_rejects_base_url_with_userinfo
    err = assert_raises(ArgumentError) { build(base_url: "https://user:secret@api.cohere.com/v1") }
    assert_match(/must not contain userinfo/, err.message)
    refute_match(/secret/, err.message)
  end

  def test_rejects_batch_size_over_cohere_cap
    err = assert_raises(ArgumentError) { build(embed_batch_size: 97) }
    assert_match(/per-request cap \(96\)/, err.message)
  end

  # ---- metadata --------------------------------------------------------

  def test_defaults
    provider = build
    assert_equal "embed-english-v3.0", provider.model_name
    assert_equal 1024, provider.dimensions
    assert_equal 96, provider.embed_batch_size
    assert_equal 512, provider.max_input_tokens
    assert provider.normalize?
    assert provider.supports_input_type?
    assert_equal [:text], provider.modalities
  end

  def test_light_model_dimensions
    assert_equal 384, build(model: "embed-english-light-v3.0").dimensions
  end

  # ---- embed-v4.0 + Matryoshka ----------------------------------------

  def test_v4_default_dimensions
    provider = build(model: "embed-v4.0")
    assert_equal "embed-v4.0", provider.model_name
    assert_equal 1536, provider.dimensions
    assert_equal 128_000, provider.max_input_tokens
  end

  def test_v4_accepts_matryoshka_widths
    [256, 512, 1024, 1536].each do |width|
      provider = build(model: "embed-v4.0", dimensions: width)
      assert_equal width, provider.dimensions
    end
  end

  def test_v4_rejects_non_allowlisted_matryoshka_width
    err = assert_raises(ArgumentError) { build(model: "embed-v4.0", dimensions: 768) }
    assert_match(/only accepts Matryoshka widths/, err.message)
  end

  def test_v4_rejects_oversized_dimensions
    err = assert_raises(ArgumentError) { build(model: "embed-v4.0", dimensions: 4096) }
    assert_match(/exceeds native/, err.message)
  end

  def test_v3_rejects_dimensions_override
    err = assert_raises(ArgumentError) { build(model: "embed-english-v3.0", dimensions: 512) }
    assert_match(/does not support custom dimensions/, err.message)
  end

  def test_v4_forwards_output_dimension_when_truncated
    captured_body = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") do |env|
        captured_body = JSON.parse(env.request_body)
        [200, { "Content-Type" => "application/json" }, fake_response(1, 512)]
      end
    end
    provider = build(model: "embed-v4.0", dimensions: 512, connection: stubbed_conn(stubs))
    provider.embed_text(["x"])
    assert_equal 512, captured_body["output_dimension"]
  end

  def test_v4_omits_output_dimension_at_native_width
    captured_body = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") do |env|
        captured_body = JSON.parse(env.request_body)
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1536)]
      end
    end
    provider = build(model: "embed-v4.0", connection: stubbed_conn(stubs))
    provider.embed_text(["x"])
    refute captured_body.key?("output_dimension"),
           "v4.0 at native width must not forward output_dimension (avoid drift across API revisions)"
  end

  def test_v3_does_not_forward_output_dimension
    captured_body = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") do |env|
        captured_body = JSON.parse(env.request_body)
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = build(model: "embed-english-v3.0", connection: stubbed_conn(stubs))
    provider.embed_text(["x"])
    refute captured_body.key?("output_dimension"),
           "v3 models must never carry output_dimension on the wire (Cohere would 400)"
  end

  # ---- inspect never leaks api_key -------------------------------------

  def test_inspect_does_not_leak_api_key
    provider = build
    refute_includes provider.inspect, API_KEY
    refute_includes provider.inspect, "Bearer"
    assert_includes provider.inspect, "embed-english-v3.0"
  end

  # ---- happy path ------------------------------------------------------

  def test_embed_text_sends_correct_payload_and_parses_response
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(2, 1024)]
      end
    end
    provider = build(connection: stubbed_conn(stubs))

    vectors = provider.embed_text(["alpha", "beta"], input_type: :search_query)
    assert_equal 2, vectors.length
    vectors.each { |v| assert_equal 1024, v.length }

    body = JSON.parse(captured_req.request_body)
    assert_equal ["alpha", "beta"], body["texts"]
    assert_equal "embed-english-v3.0", body["model"]
    assert_equal "search_query", body["input_type"]
    assert_equal ["float"], body["embedding_types"]
    assert_equal "Bearer #{API_KEY}", captured_req.request_headers["Authorization"]
  end

  def test_input_type_search_document_sends_correct_wire_value
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = build(connection: stubbed_conn(stubs))
    provider.embed_text(["x"], input_type: :search_document)
    assert_equal "search_document", JSON.parse(captured_req.request_body)["input_type"]
  end

  def test_input_type_classification_and_clustering_send_correct_wire_values
    captured_types = []
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") do |env|
        captured_types << JSON.parse(env.request_body)["input_type"]
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = build(connection: stubbed_conn(stubs))
    provider.embed_text(["x"], input_type: :classification)
    provider.embed_text(["x"], input_type: :clustering)
    assert_equal ["classification", "clustering"], captured_types
  end

  def test_unknown_input_type_raises
    provider = build(connection: stubbed_conn(empty_stubs))
    err = assert_raises(ArgumentError) { provider.embed_text(["x"], input_type: :nonsense) }
    assert_match(/input_type :nonsense not in/, err.message)
  end

  def test_supports_input_type_is_true
    assert build.supports_input_type?
  end

  def test_embed_text_empty_batch_short_circuits
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") do |_env|
        flunk "Should not hit Cohere for empty batch"
      end
    end
    provider = build(connection: stubbed_conn(stubs))
    assert_equal [], provider.embed_text([])
  end

  def test_embed_text_rejects_empty_string
    provider = build(connection: stubbed_conn(empty_stubs))
    err = assert_raises(ArgumentError) { provider.embed_text(["ok", ""]) }
    assert_match(/empty.*Cohere rejects empty/, err.message)
  end

  # ---- response-shape variants ----------------------------------------

  def test_response_with_legacy_array_shape_is_accepted
    # Some Cohere proxies / older versions return embeddings as a bare
    # Array<Array<Float>> rather than `{"float": [...]}`. The provider
    # tolerates both.
    body = {
      "embeddings" => [Array.new(1024, 1.0 / Math.sqrt(1024))],
      "meta" => { "billed_units" => { "input_tokens" => 4 } },
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") { |_| [200, { "Content-Type" => "application/json" }, body] }
    end
    provider = build(connection: stubbed_conn(stubs))
    vectors = provider.embed_text(["a"])
    assert_equal 1, vectors.length
    assert_equal 1024, vectors[0].length
  end

  def test_response_with_wrong_count_is_rejected
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") { |_| [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)] }
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.embed_text(["a", "b"])
    end
    assert_match(/embeddings count 1 != input count 2/, err.message)
  end

  def test_non_json_response_raises_invalid_response
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") { |_| [200, { "Content-Type" => "text/html" }, "<html>"] }
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) { provider.embed_text(["a"]) }
    assert_match(/not valid JSON/, err.message)
  end

  # ---- HTTP status handling --------------------------------------------

  def test_401_raises_authentication_error_without_retry
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") { |_env| calls += 1; [401, {}, '{"message":"bad key"}'] }
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 3)
    assert_raises(Parse::Embeddings::Cohere::AuthenticationError) { provider.embed_text(["a"]) }
    assert_equal 1, calls
  end

  def test_429_retries_then_succeeds
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") do |_env|
        calls += 1
        if calls < 3
          [429, { "Retry-After" => "0" }, '{"message":"slow"}']
        else
          [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
        end
      end
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 3)
    silence_sleep(provider) { provider.embed_text(["a"]) }
    assert_equal 3, calls
  end

  def test_5xx_retries_then_raises_after_exhaustion
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") { |_env| calls += 1; [503, {}, "down"] }
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 1)
    silence_sleep(provider) do
      assert_raises(Parse::Embeddings::Cohere::TransientError) { provider.embed_text(["a"]) }
    end
    assert_equal 2, calls
  end

  def test_500_error_does_not_echo_base_url
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") { |_| [400, {}, '{"message":"bad"}'] }
    end
    provider = build(
      base_url:   "https://customer-private-proxy.example.com/cohere/v1",
      connection: stubbed_conn(stubs),
    )
    err = assert_raises(Parse::Embeddings::Cohere::BadRequestError) { provider.embed_text(["a"]) }
    refute_match(/customer-private-proxy/, err.message)
  end

  # ---- error class hierarchy ------------------------------------------

  def test_all_cohere_errors_subclass_parse_embeddings_error
    [
      Parse::Embeddings::Cohere::AuthenticationError,
      Parse::Embeddings::Cohere::BadRequestError,
      Parse::Embeddings::Cohere::RateLimitError,
      Parse::Embeddings::Cohere::TransientError,
    ].each do |klass|
      assert klass < Parse::Embeddings::Error
    end
  end

  # ---- registry integration --------------------------------------------

  def test_registers_via_short_form
    provider = build(connection: stubbed_conn(empty_stubs))
    Parse::Embeddings.register(:cohere, provider)
    assert_same provider, Parse::Embeddings.provider(:cohere)
  end

  # ---- build_connection introspection ----------------------------------

  def test_build_connection_sets_bearer_header
    provider = Parse::Embeddings::Cohere.new(api_key: API_KEY)
    headers = provider.instance_variable_get(:@connection).headers
    assert_equal "Bearer #{API_KEY}", headers["Authorization"]
    assert_match %r{\Aparse-stack-embeddings/}, headers["User-Agent"]
  end

  def test_build_connection_suppresses_env_proxy_by_default
    with_env("HTTPS_PROXY" => "http://attacker.example:8080") do
      provider = Parse::Embeddings::Cohere.new(api_key: API_KEY)
      assert_nil provider.instance_variable_get(:@connection).proxy
    end
  end

  def test_build_connection_uses_env_proxy_when_opted_in
    with_env("HTTPS_PROXY" => "http://corp-proxy.example:8080") do
      provider = Parse::Embeddings::Cohere.new(api_key: API_KEY, allow_faraday_proxy: true)
      conn = provider.instance_variable_get(:@connection)
      refute_nil conn.proxy
      assert_equal "corp-proxy.example", conn.proxy.uri.host
    end
  end

  # ---- redaction list extension ----------------------------------------

  def test_redacted_headers_include_cohere_credentials
    redacted = Parse::Middleware::BodyBuilder::REDACTED_HEADERS
    assert_includes redacted, "authorization"
    assert_includes redacted, "cohere-api-key"
  end

  # ---- parse.embeddings.embed AS::N notification ----------------------

  def test_embed_emits_as_n_event_with_total_tokens
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embed") { |_| [200, { "Content-Type" => "application/json" }, fake_response(2, 1024)] }
    end
    provider = build(connection: stubbed_conn(stubs))

    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("parse.embeddings.embed") do |*args|
      captured << ActiveSupport::Notifications::Event.new(*args)
    end
    begin
      provider.embed_text(["one", "two"], input_type: :search_query)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 1, captured.length
    payload = captured.first.payload
    assert_equal "Parse::Embeddings::Cohere", payload[:provider]
    assert_equal "embed-english-v3.0", payload[:model]
    assert_equal 1024, payload[:dimensions]
    assert_equal 2, payload[:input_count]
    assert_equal :search_query, payload[:input_type]
    # fake_response sets billed_units.input_tokens == count
    assert_equal 2, payload[:total_tokens]
    assert_nil payload[:error]
  end

  private

  def build(**overrides)
    opts = { api_key: API_KEY, model: "embed-english-v3.0" }.merge(overrides)
    Parse::Embeddings::Cohere.new(**opts)
  end

  def stubbed_conn(stubs)
    Faraday.new(url: "https://api.cohere.test/v1",
                headers: { "Authorization" => "Bearer #{API_KEY}", "Content-Type" => "application/json" }) do |f|
      f.adapter :test, stubs
    end
  end

  def empty_stubs
    Faraday::Adapter::Test::Stubs.new
  end

  def with_env(overrides)
    previous = {}
    overrides.each_key { |k| previous[k] = ENV[k] }
    overrides.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| ENV[k] = v }
  end

  def fake_response(count, dim)
    {
      "id" => "test-#{count}",
      "embeddings" => { "float" => (0...count).map { Array.new(dim, 1.0 / Math.sqrt(dim)) } },
      "texts" => (0...count).map { |i| "text-#{i}" },
      "meta" => { "billed_units" => { "input_tokens" => count } },
    }.to_json
  end

  def silence_sleep(provider)
    provider.define_singleton_method(:backoff_seconds) { |_| 0 }
    yield
  end
end
