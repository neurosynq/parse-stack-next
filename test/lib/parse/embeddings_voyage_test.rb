# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "faraday"

# Unit tests for Parse::Embeddings::Voyage. No network — every test
# injects a Faraday::Adapter::Test connection.
class EmbeddingsVoyageTest < Minitest::Test
  API_KEY = "pa-test-DO-NOT-LEAK"

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
    err = assert_raises(ArgumentError) { build(base_url: "http://api.voyageai.com/v1") }
    assert_match(/refusing http:\/\//, err.message)
  end

  def test_rejects_base_url_with_userinfo
    err = assert_raises(ArgumentError) { build(base_url: "https://user:secret@api.voyageai.com/v1") }
    assert_match(/must not contain userinfo/, err.message)
    refute_match(/secret/, err.message)
  end

  def test_rejects_batch_size_over_voyage_cap
    err = assert_raises(ArgumentError) { build(embed_batch_size: 129) }
    assert_match(/per-request cap \(128\)/, err.message)
  end

  def test_rejects_non_boolean_truncation
    assert_raises(ArgumentError) { build(truncation: "yes") }
    assert_raises(ArgumentError) { build(truncation: nil) }
  end

  def test_rejects_dimensions_override_on_non_matryoshka_model
    err = assert_raises(ArgumentError) { build(model: "voyage-3", dimensions: 512) }
    assert_match(/does not support custom dimensions/, err.message)
  end

  def test_rejects_oversized_dimensions_on_matryoshka_model
    err = assert_raises(ArgumentError) do
      build(model: "voyage-4-large", dimensions: 4096)
    end
    assert_match(/exceeds native/, err.message)
  end

  def test_accepts_dimensions_override_on_matryoshka_model
    provider = build(model: "voyage-4-large", dimensions: 1024)
    assert_equal 1024, provider.dimensions
  end

  # ---- metadata --------------------------------------------------------

  def test_defaults
    provider = build
    assert_equal "voyage-3", provider.model_name
    assert_equal 1024, provider.dimensions
    assert_equal 128, provider.embed_batch_size
    assert_equal 32_000, provider.max_input_tokens
    assert provider.normalize?
    assert provider.supports_input_type?
  end

  def test_v4_family_dimensions
    assert_equal 2048, build(model: "voyage-4-large").dimensions
    assert_equal 1024, build(model: "voyage-4").dimensions
    assert_equal 512, build(model: "voyage-4-lite").dimensions
    assert_equal 256, build(model: "voyage-4-nano").dimensions
  end

  def test_lite_model_dimensions
    assert_equal 512, build(model: "voyage-3-lite").dimensions
  end

  def test_domain_model_max_tokens
    assert_equal 16_000, build(model: "voyage-finance-2").max_input_tokens
    assert_equal 16_000, build(model: "voyage-law-2").max_input_tokens
  end

  # ---- inspect never leaks api_key -------------------------------------

  def test_inspect_does_not_leak_api_key
    provider = build
    refute_includes provider.inspect, API_KEY
    refute_includes provider.inspect, "Bearer"
    assert_includes provider.inspect, "voyage-3"
  end

  # ---- happy path ------------------------------------------------------

  def test_embed_text_sends_correct_payload_and_parses_response
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(2, 1024)]
      end
    end
    provider = build(connection: stubbed_conn(stubs))

    vectors = provider.embed_text(["alpha", "beta"], input_type: :search_query)
    assert_equal 2, vectors.length

    body = JSON.parse(captured_req.request_body)
    assert_equal ["alpha", "beta"], body["input"]
    assert_equal "voyage-3", body["model"]
    # Voyage wire value for :search_query is "query"
    assert_equal "query", body["input_type"]
    assert_equal true, body["truncation"]
    assert_equal "Bearer #{API_KEY}", captured_req.request_headers["Authorization"]
  end

  def test_search_document_maps_to_document_wire_value
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = build(connection: stubbed_conn(stubs))
    provider.embed_text(["x"], input_type: :search_document)
    assert_equal "document", JSON.parse(captured_req.request_body)["input_type"]
  end

  def test_classification_input_type_omits_input_type_field
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = build(connection: stubbed_conn(stubs))
    provider.embed_text(["x"], input_type: :classification)
    body = JSON.parse(captured_req.request_body)
    refute body.key?("input_type"),
           "Voyage classification → input_type must be omitted (unconditioned head)"
  end

  def test_unknown_input_type_raises
    provider = build(connection: stubbed_conn(empty_stubs))
    err = assert_raises(ArgumentError) { provider.embed_text(["x"], input_type: :nonsense) }
    assert_match(/input_type :nonsense not in/, err.message)
  end

  def test_truncation_false_is_forwarded
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = build(truncation: false, connection: stubbed_conn(stubs))
    provider.embed_text(["x"])
    assert_equal false, JSON.parse(captured_req.request_body)["truncation"]
  end

  def test_matryoshka_truncation_sends_output_dimension
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = build(model: "voyage-4-large", dimensions: 1024, connection: stubbed_conn(stubs))
    provider.embed_text(["x"])
    body = JSON.parse(captured_req.request_body)
    assert_equal 1024, body["output_dimension"]
  end

  def test_omits_output_dimension_when_matching_native_width
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 2048)]
      end
    end
    provider = build(model: "voyage-4-large", connection: stubbed_conn(stubs))
    provider.embed_text(["x"])
    refute JSON.parse(captured_req.request_body).key?("output_dimension"),
           "must omit output_dimension when active dims match native width"
  end

  def test_supports_input_type_is_true
    assert build.supports_input_type?
  end

  def test_embed_text_empty_batch_short_circuits
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| flunk "Should not hit Voyage for empty batch" }
    end
    provider = build(connection: stubbed_conn(stubs))
    assert_equal [], provider.embed_text([])
  end

  def test_embed_text_rejects_empty_string
    provider = build(connection: stubbed_conn(empty_stubs))
    err = assert_raises(ArgumentError) { provider.embed_text(["ok", ""]) }
    assert_match(/empty.*Voyage rejects empty/, err.message)
  end

  # ---- response-shape validation ---------------------------------------

  def test_response_with_out_of_order_indices_is_sorted
    body = {
      "data" => [
        { "index" => 1, "embedding" => Array.new(1024, 2.0 / 1024) },
        { "index" => 0, "embedding" => Array.new(1024, 1.0 / 1024) },
      ],
      "model" => "voyage-3",
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, body] }
    end
    provider = build(connection: stubbed_conn(stubs))
    vectors = provider.embed_text(["first", "second"])
    assert_in_delta 1.0 / 1024, vectors[0][0], 1e-9
    assert_in_delta 2.0 / 1024, vectors[1][0], 1e-9
  end

  def test_response_with_duplicate_indices_is_rejected
    body = {
      "data" => [
        { "index" => 0, "embedding" => Array.new(1024, 0.0) },
        { "index" => 0, "embedding" => Array.new(1024, 0.0) },
      ],
      "model" => "voyage-3",
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, body] }
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) { provider.embed_text(["a", "b"]) }
    assert_match(/duplicate index/, err.message)
  end

  def test_response_with_wrong_count_is_rejected
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)] }
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) { provider.embed_text(["a", "b"]) }
    assert_match(/data\.length 1 != input count 2/, err.message)
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
      stub.post("/v1/embeddings") { |_env| calls += 1; [401, {}, '{"detail":"bad key"}'] }
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 3)
    assert_raises(Parse::Embeddings::Voyage::AuthenticationError) { provider.embed_text(["a"]) }
    assert_equal 1, calls
  end

  def test_429_retries_then_succeeds
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        calls += 1
        if calls < 2
          [429, { "Retry-After" => "0" }, '{"detail":"slow"}']
        else
          [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
        end
      end
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 2)
    silence_sleep(provider) { provider.embed_text(["a"]) }
    assert_equal 2, calls
  end

  def test_5xx_retries_then_raises_after_exhaustion
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_env| calls += 1; [502, {}, "down"] }
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 1)
    silence_sleep(provider) do
      assert_raises(Parse::Embeddings::Voyage::TransientError) { provider.embed_text(["a"]) }
    end
    assert_equal 2, calls
  end

  # ---- error class hierarchy ------------------------------------------

  def test_all_voyage_errors_subclass_parse_embeddings_error
    [
      Parse::Embeddings::Voyage::AuthenticationError,
      Parse::Embeddings::Voyage::BadRequestError,
      Parse::Embeddings::Voyage::RateLimitError,
      Parse::Embeddings::Voyage::TransientError,
    ].each do |klass|
      assert klass < Parse::Embeddings::Error
    end
  end

  # ---- registry integration --------------------------------------------

  def test_registers_via_short_form
    provider = build(connection: stubbed_conn(empty_stubs))
    Parse::Embeddings.register(:voyage, provider)
    assert_same provider, Parse::Embeddings.provider(:voyage)
  end

  # ---- build_connection introspection ----------------------------------

  def test_build_connection_sets_bearer_header
    provider = Parse::Embeddings::Voyage.new(api_key: API_KEY)
    headers = provider.instance_variable_get(:@connection).headers
    assert_equal "Bearer #{API_KEY}", headers["Authorization"]
  end

  def test_build_connection_suppresses_env_proxy_by_default
    with_env("HTTPS_PROXY" => "http://attacker.example:8080") do
      provider = Parse::Embeddings::Voyage.new(api_key: API_KEY)
      assert_nil provider.instance_variable_get(:@connection).proxy
    end
  end

  # ---- redaction list extension ----------------------------------------

  def test_redacted_headers_include_voyage_credentials
    redacted = Parse::Middleware::BodyBuilder::REDACTED_HEADERS
    assert_includes redacted, "authorization"
    assert_includes redacted, "voyage-api-key"
  end

  # ---- parse.embeddings.embed AS::N notification ----------------------

  # ---- voyage-multimodal-3 text-mode routing -------------------------

  def test_multimodal_model_routes_to_multimodalembeddings_path
    captured_path = nil
    captured_body = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        captured_path = env.url.path
        captured_body = JSON.parse(env.request_body)
        [200, { "Content-Type" => "application/json" }, fake_response(2, 1024)]
      end
    end
    provider = build(model: "voyage-multimodal-3", connection: stubbed_conn(stubs))
    vectors = provider.embed_text(["alpha", "beta"], input_type: :search_query)

    assert_equal 2, vectors.length
    assert_equal "/v1/multimodalembeddings", captured_path
    # Multimodal envelope wraps each input as content[type=text].
    assert_equal "voyage-multimodal-3", captured_body["model"]
    assert_equal "query", captured_body["input_type"]
    refute captured_body.key?("input"), "multimodal endpoint must not carry the text-only `input` field"
    assert_equal 2, captured_body["inputs"].length
    assert_equal [{ "type" => "text", "text" => "alpha" }], captured_body["inputs"][0]["content"]
    assert_equal [{ "type" => "text", "text" => "beta" }], captured_body["inputs"][1]["content"]
    # truncation is forwarded on the multimodal envelope too.
    assert_equal true, captured_body["truncation"]
  end

  def test_multimodal_model_classification_omits_input_type
    captured_body = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        captured_body = JSON.parse(env.request_body)
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = build(model: "voyage-multimodal-3", connection: stubbed_conn(stubs))
    provider.embed_text(["x"], input_type: :classification)
    refute captured_body.key?("input_type")
  end

  def test_text_model_does_not_route_to_multimodal_path
    captured_path = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_path = env.url.path
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = build(model: "voyage-3", connection: stubbed_conn(stubs))
    provider.embed_text(["x"])
    assert_equal "/v1/embeddings", captured_path
  end

  def test_multimodal_model_default_dimensions
    assert_equal 1024, build(model: "voyage-multimodal-3").dimensions
    assert_equal 32_000, build(model: "voyage-multimodal-3").max_input_tokens
  end

  def test_multimodal_model_clustering_omits_input_type
    captured_body = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        captured_body = JSON.parse(env.request_body)
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = build(model: "voyage-multimodal-3", connection: stubbed_conn(stubs))
    provider.embed_text(["x"], input_type: :clustering)
    refute captured_body.key?("input_type")
  end

  def test_multimodal_model_truncation_false_is_forwarded
    captured_body = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        captured_body = JSON.parse(env.request_body)
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = build(model: "voyage-multimodal-3", truncation: false,
                     connection: stubbed_conn(stubs))
    provider.embed_text(["x"])
    assert_equal false, captured_body["truncation"]
  end

  def test_multimodal_model_rejects_empty_string
    provider = build(model: "voyage-multimodal-3")
    assert_raises(ArgumentError) { provider.embed_text([""]) }
  end

  def test_multimodal_model_emits_as_n_event_with_total_tokens
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |_|
        [200, { "Content-Type" => "application/json" }, fake_response(2, 1024)]
      end
    end
    provider = build(model: "voyage-multimodal-3", connection: stubbed_conn(stubs))

    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("parse.embeddings.embed") do |*args|
      captured << ActiveSupport::Notifications::Event.new(*args)
    end
    begin
      provider.embed_text(["one", "two"], input_type: :search_document)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    assert_equal 1, captured.length
    payload = captured.first.payload
    assert_equal "voyage-multimodal-3", payload[:model]
    assert_equal 1024, payload[:dimensions]
    assert_equal 2, payload[:input_count]
    assert_kind_of Integer, payload[:total_tokens]
    assert payload[:total_tokens] >= 0
  end

  def test_embed_emits_as_n_event_with_total_tokens
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, fake_response(2, 1024)] }
    end
    provider = build(connection: stubbed_conn(stubs))

    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("parse.embeddings.embed") do |*args|
      captured << ActiveSupport::Notifications::Event.new(*args)
    end
    begin
      provider.embed_text(["one", "two"], input_type: :search_document)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 1, captured.length
    payload = captured.first.payload
    assert_equal "Parse::Embeddings::Voyage", payload[:provider]
    assert_equal "voyage-3", payload[:model]
    assert_equal :search_document, payload[:input_type]
    assert_equal 2, payload[:total_tokens]
  end

  private

  def build(**overrides)
    opts = { api_key: API_KEY, model: "voyage-3" }.merge(overrides)
    Parse::Embeddings::Voyage.new(**opts)
  end

  def stubbed_conn(stubs)
    Faraday.new(url: "https://api.voyageai.test/v1",
                headers: { "Authorization" => "Bearer #{API_KEY}", "Content-Type" => "application/json" }) do |f|
      f.adapter :test, stubs
    end
  end

  def empty_stubs
    Faraday::Adapter::Test::Stubs.new
  end

  def with_env(overrides)
    previous = nil
    previous = {}
    overrides.each_key { |k| previous[k] = ENV[k] }
    overrides.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous&.each { |k, v| ENV[k] = v }
  end

  def fake_response(count, dim)
    {
      "object" => "list",
      "data" => (0...count).map do |i|
        { "object" => "embedding", "index" => i, "embedding" => Array.new(dim, 1.0 / Math.sqrt(dim)) }
      end,
      "model" => "voyage-3",
      "usage" => { "total_tokens" => count },
    }.to_json
  end

  def silence_sleep(provider)
    provider.define_singleton_method(:backoff_seconds) { |_| 0 }
    yield
  end
end
