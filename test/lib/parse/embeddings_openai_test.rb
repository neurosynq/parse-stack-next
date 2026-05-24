# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "faraday"

# Unit tests for Parse::Embeddings::OpenAI. No network — every test
# injects a Faraday::Adapter::Test connection so we can pin request
# shape, header redaction expectations, retry behavior, and response
# parsing without webmock.
class EmbeddingsOpenAITest < Minitest::Test
  API_KEY = "sk-test-DO-NOT-LEAK"

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

  def test_rejects_oversized_dimensions
    err = assert_raises(ArgumentError) do
      build(model: "text-embedding-3-small", dimensions: 9999)
    end
    assert_match(/exceeds native/, err.message)
  end

  def test_rejects_custom_dimensions_on_ada
    err = assert_raises(ArgumentError) do
      build(model: "text-embedding-ada-002", dimensions: 512)
    end
    assert_match(/does not support custom dimensions/, err.message)
  end

  def test_rejects_non_integer_dimensions
    assert_raises(ArgumentError) { build(dimensions: 3.5) }
    assert_raises(ArgumentError) { build(dimensions: 0) }
    assert_raises(ArgumentError) { build(dimensions: -1) }
  end

  def test_refuses_http_base_url_by_default
    err = assert_raises(ArgumentError) { build(base_url: "http://api.openai.com/v1") }
    assert_match(/refusing http:\/\//, err.message)
  end

  def test_allows_http_base_url_with_opt_in
    provider = build(base_url: "http://localhost:11434/v1", allow_insecure_base_url: true)
    refute_nil provider
  end

  def test_rejects_non_http_base_url
    assert_raises(ArgumentError) { build(base_url: "file:///tmp/x") }
    assert_raises(ArgumentError) { build(base_url: "ftp://x") }
  end

  def test_rejects_base_url_with_userinfo
    err = assert_raises(ArgumentError) { build(base_url: "https://user:secret@api.openai.com/v1") }
    assert_match(/must not contain userinfo/, err.message)
    refute_match(/secret/, err.message, "error message must not echo the embedded credential")
  end

  def test_rejects_base_url_with_only_user_in_userinfo
    err = assert_raises(ArgumentError) { build(base_url: "https://leaked@api.openai.com/v1") }
    assert_match(/must not contain userinfo/, err.message)
    refute_match(/leaked/, err.message)
  end

  def test_rejects_base_url_without_host
    assert_raises(ArgumentError) { build(base_url: "https:///path") }
  end

  def test_rejects_malformed_base_url
    err = assert_raises(ArgumentError) { build(base_url: "https://exa mple.com") }
    assert_match(/valid URL|must include a host/, err.message)
  end

  def test_inspect_does_not_include_userinfo_even_if_smuggled
    # validate_base_url! is the front door — but if a future refactor
    # bypasses it, the normalized @base_url should still not carry
    # userinfo. This test pins the contract: nothing in inspect output
    # ever contains user:pass@.
    provider = build
    refute_match(/@.*\bopenai\.com/, provider.inspect)
  end

  def test_rejects_non_positive_timeouts
    assert_raises(ArgumentError) { build(timeout: 0) }
    assert_raises(ArgumentError) { build(open_timeout: 0) }
    assert_raises(ArgumentError) { build(embed_batch_size: 0) }
  end

  def test_rejects_negative_max_retries
    assert_raises(ArgumentError) { build(max_retries: -1) }
  end

  def test_max_retries_zero_is_allowed
    provider = build(max_retries: 0)
    refute_nil provider
  end

  # ---- metadata --------------------------------------------------------

  def test_defaults
    provider = build
    assert_equal "text-embedding-3-small", provider.model_name
    assert_equal 1536, provider.dimensions
    assert_equal 100, provider.embed_batch_size
    assert_equal 8191, provider.max_input_tokens
    assert provider.normalize?
    refute provider.supports_input_type?
    assert_equal [:text], provider.modalities
  end

  def test_dimensions_override
    provider = build(dimensions: 512)
    assert_equal 512, provider.dimensions
  end

  def test_large_model_native_dimensions
    provider = build(model: "text-embedding-3-large")
    assert_equal 3072, provider.dimensions
  end

  def test_ada_model_native_dimensions
    provider = build(model: "text-embedding-ada-002")
    assert_equal 1536, provider.dimensions
  end

  # ---- inspect never leaks api_key -------------------------------------

  def test_inspect_does_not_leak_api_key
    provider = build
    refute_includes provider.inspect, API_KEY
    refute_includes provider.inspect, "Bearer"
    assert_includes provider.inspect, "text-embedding-3-small"
  end

  # ---- happy path ------------------------------------------------------

  def test_embed_text_sends_correct_payload_and_parses_response
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(2, 1536)]
      end
    end
    provider = build(connection: stubbed_conn(stubs))

    vectors = provider.embed_text(["alpha", "beta"])
    assert_equal 2, vectors.length
    vectors.each { |v| assert_equal 1536, v.length }

    body = JSON.parse(captured_req.request_body)
    assert_equal ["alpha", "beta"], body["input"]
    assert_equal "text-embedding-3-small", body["model"]
    assert_equal 1536, body["dimensions"]
    assert_equal "Bearer #{API_KEY}", captured_req.request_headers["Authorization"]
  end

  def test_embed_text_omits_dimensions_for_ada
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1536)]
      end
    end
    provider = build(model: "text-embedding-ada-002", connection: stubbed_conn(stubs))
    provider.embed_text(["x"])
    body = JSON.parse(captured_req.request_body)
    refute body.key?("dimensions"), "dimensions param must be omitted for ada-002"
  end

  def test_embed_text_sends_org_and_project_headers
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1536)]
      end
    end
    provider = build(
      organization: "org-abc",
      project:      "proj-xyz",
      connection:   stubbed_conn(stubs, headers: { "OpenAI-Organization" => "org-abc", "OpenAI-Project" => "proj-xyz" }),
    )
    provider.embed_text(["x"])
    assert_equal "org-abc", captured_req.request_headers["OpenAI-Organization"]
    assert_equal "proj-xyz", captured_req.request_headers["OpenAI-Project"]
  end

  def test_embed_text_empty_batch_short_circuits
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        flunk "Should not hit OpenAI for empty batch"
      end
    end
    provider = build(connection: stubbed_conn(stubs))
    assert_equal [], provider.embed_text([])
  end

  def test_embed_text_rejects_non_array
    provider = build(connection: stubbed_conn(empty_stubs))
    assert_raises(ArgumentError) { provider.embed_text("not a batch") }
  end

  def test_embed_text_rejects_non_string_element
    provider = build(connection: stubbed_conn(empty_stubs))
    assert_raises(ArgumentError) { provider.embed_text(["ok", 123]) }
  end

  def test_embed_text_rejects_empty_string
    provider = build(connection: stubbed_conn(empty_stubs))
    err = assert_raises(ArgumentError) { provider.embed_text(["ok", ""]) }
    assert_match(/empty.*OpenAI rejects empty/, err.message)
  end

  # ---- response-shape validation ---------------------------------------

  def test_response_with_wrong_data_length_is_rejected
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1536)]
      end
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.embed_text(["a", "b"])
    end
    assert_match(/data\.length 1 != input count 2/, err.message)
  end

  def test_response_with_out_of_order_indices_is_sorted
    body = {
      "data" => [
        { "index" => 1, "embedding" => Array.new(1536, 2.0 / 1536) },
        { "index" => 0, "embedding" => Array.new(1536, 1.0 / 1536) },
      ],
      "model" => "text-embedding-3-small",
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, body] }
    end
    provider = build(connection: stubbed_conn(stubs))
    vectors = provider.embed_text(["first", "second"])
    assert_in_delta 1.0 / 1536, vectors[0][0], 1e-9
    assert_in_delta 2.0 / 1536, vectors[1][0], 1e-9
  end

  def test_response_with_duplicate_indices_is_rejected
    body = {
      "data" => [
        { "index" => 0, "embedding" => Array.new(1536, 0.0) },
        { "index" => 0, "embedding" => Array.new(1536, 0.0) },
      ],
      "model" => "text-embedding-3-small",
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, body] }
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.embed_text(["a", "b"])
    end
    assert_match(/duplicate index/, err.message)
  end

  def test_response_with_out_of_range_index_is_rejected
    body = {
      "data" => [
        { "index" => 5, "embedding" => Array.new(1536, 0.0) },
      ],
      "model" => "text-embedding-3-small",
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, body] }
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.embed_text(["a"])
    end
    assert_match(/index.*out of range/, err.message)
  end

  def test_response_with_wrong_width_vector_is_rejected
    body = {
      "data" => [
        { "index" => 0, "embedding" => Array.new(512, 0.0) },
      ],
      "model" => "text-embedding-3-small",
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, body] }
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.embed_text(["a"])
    end
    assert_match(/length 512 != declared dimensions 1536/, err.message)
  end

  def test_non_json_response_raises_invalid_response
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "text/html" }, "<html>oops</html>"] }
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.embed_text(["a"])
    end
    assert_match(/not valid JSON/, err.message)
  end

  # ---- HTTP status handling --------------------------------------------

  def test_401_raises_authentication_error_without_retry
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        calls += 1
        [401, {}, '{"error":{"message":"bad key"}}']
      end
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 3)
    assert_raises(Parse::Embeddings::OpenAI::AuthenticationError) do
      provider.embed_text(["a"])
    end
    assert_equal 1, calls, "401 must not be retried"
  end

  def test_400_raises_bad_request_without_retry
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        calls += 1
        [400, {}, '{"error":{"message":"input too long"}}']
      end
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 3)
    assert_raises(Parse::Embeddings::OpenAI::BadRequestError) do
      provider.embed_text(["a"])
    end
    assert_equal 1, calls
  end

  def test_400_error_message_does_not_echo_base_url
    # Confirms that BadRequestError doesn't include the configured
    # base_url — important when a customer points the provider at a
    # private Azure/Ollama endpoint that they don't want surfaced in
    # error trackers like Sentry/Rollbar.
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [400, {}, '{"error":"bad"}'] }
    end
    provider = build(
      base_url:   "https://customer-private-azure.example.com/openai/deployments/x/v1",
      connection: stubbed_conn(stubs),
    )
    err = assert_raises(Parse::Embeddings::OpenAI::BadRequestError) { provider.embed_text(["a"]) }
    refute_match(/customer-private-azure/, err.message)
    refute_match(/azure|ollama|openai\.com/i, err.message)
  end

  def test_transient_error_does_not_echo_faraday_message
    # Faraday::ConnectionFailed#message often contains the target URL.
    # Confirm we surface only the error class, not the message body.
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| raise Faraday::ConnectionFailed, "failed to connect to https://customer-private-azure.example.com" }
    end
    provider = build(
      base_url:   "https://customer-private-azure.example.com/v1",
      connection: stubbed_conn(stubs),
      max_retries: 0,
    )
    err = assert_raises(Parse::Embeddings::OpenAI::TransientError) do
      silence_sleep(provider) { provider.embed_text(["a"]) }
    end
    assert_match(/ConnectionFailed/, err.message)
    refute_match(/customer-private-azure/, err.message)
  end

  def test_response_body_over_cap_is_rejected
    cap = Parse::Embeddings::OpenAI::MAX_RESPONSE_BYTES
    # Build a string larger than the cap. Contents need not be valid
    # JSON — the size guard runs before JSON.parse.
    big = "a" * (cap + 1024)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, big] }
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) { provider.embed_text(["a"]) }
    assert_match(/exceeds.*bytes/, err.message)
  end

  def test_response_with_excessive_json_nesting_is_rejected
    # max_nesting: 32 — build something well past that.
    deeply_nested = ("[" * 200) + "1" + ("]" * 200)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") { |_| [200, { "Content-Type" => "application/json" }, deeply_nested] }
    end
    provider = build(connection: stubbed_conn(stubs))
    err = assert_raises(Parse::Embeddings::InvalidResponseError) { provider.embed_text(["a"]) }
    assert_match(/not valid JSON/, err.message)
  end

  def test_429_retries_then_succeeds
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        calls += 1
        if calls < 3
          [429, { "Retry-After" => "0" }, '{"error":{"message":"slow down"}}']
        else
          [200, { "Content-Type" => "application/json" }, fake_response(1, 1536)]
        end
      end
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 3)
    silence_sleep(provider) do
      vectors = provider.embed_text(["a"])
      assert_equal 1, vectors.length
    end
    assert_equal 3, calls
  end

  def test_429_exhausts_retries_then_raises
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        calls += 1
        [429, { "Retry-After" => "0" }, '{"error":{"message":"slow down"}}']
      end
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 2)
    err = silence_sleep(provider) do
      assert_raises(Parse::Embeddings::OpenAI::RateLimitError) { provider.embed_text(["a"]) }
    end
    assert_match(/rate limited/, err.message)
    assert_equal 3, calls, "max_retries=2 means 1 initial + 2 retries = 3 attempts"
  end

  def test_5xx_retries_then_succeeds
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        calls += 1
        if calls < 2
          [503, {}, "unavailable"]
        else
          [200, { "Content-Type" => "application/json" }, fake_response(1, 1536)]
        end
      end
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 3)
    silence_sleep(provider) { provider.embed_text(["a"]) }
    assert_equal 2, calls
  end

  def test_timeout_retries_then_raises_transient_error
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        calls += 1
        raise Faraday::TimeoutError, "execution expired"
      end
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 1)
    silence_sleep(provider) do
      err = assert_raises(Parse::Embeddings::OpenAI::TransientError) { provider.embed_text(["a"]) }
      assert_match(/TimeoutError/, err.message)
    end
    assert_equal 2, calls, "max_retries=1 → 2 total attempts"
  end

  def test_max_retries_zero_does_not_retry
    calls = 0
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        calls += 1
        [503, {}, "down"]
      end
    end
    provider = build(connection: stubbed_conn(stubs), max_retries: 0)
    silence_sleep(provider) do
      assert_raises(Parse::Embeddings::OpenAI::TransientError) { provider.embed_text(["a"]) }
    end
    assert_equal 1, calls
  end

  # ---- error class hierarchy ------------------------------------------

  def test_all_openai_errors_subclass_parse_embeddings_error
    [
      Parse::Embeddings::OpenAI::AuthenticationError,
      Parse::Embeddings::OpenAI::BadRequestError,
      Parse::Embeddings::OpenAI::RateLimitError,
      Parse::Embeddings::OpenAI::TransientError,
    ].each do |klass|
      assert klass < Parse::Embeddings::Error,
             "#{klass} must inherit from Parse::Embeddings::Error for retry middleware"
    end
  end

  # ---- registry integration --------------------------------------------

  def test_registers_via_short_form
    provider = build(connection: stubbed_conn(empty_stubs))
    Parse::Embeddings.register(:openai, provider)
    assert_same provider, Parse::Embeddings.provider(:openai)
  end

  def test_registry_rejects_string_pretending_to_be_openai
    err = assert_raises(ArgumentError) do
      Parse::Embeddings.register(:openai, "sk-not-a-provider")
    end
    assert_match(/Parse::Embeddings::Provider instance/, err.message)
  end

  # ---- build_connection introspection ----------------------------------
  # These tests pin the Faraday wiring that the redaction layer (and
  # any future shared logging middleware) relies on. Without them, a
  # silent regression like the always-nil-proxy bug (where both
  # ternary branches collapsed to `proxy: nil`) slips through.

  def test_build_connection_sets_credential_and_metadata_headers
    provider = Parse::Embeddings::OpenAI.new(
      api_key:      API_KEY,
      organization: "org-abc",
      project:      "proj-xyz",
    )
    conn = provider.instance_variable_get(:@connection)
    headers = conn.headers

    assert_equal "Bearer #{API_KEY}", headers["Authorization"]
    assert_equal "application/json", headers["Content-Type"]
    assert_equal "application/json", headers["Accept"]
    assert_equal "org-abc", headers["OpenAI-Organization"]
    assert_equal "proj-xyz", headers["OpenAI-Project"]
    assert_match %r{\Aparse-stack-embeddings/}, headers["User-Agent"]
  end

  def test_build_connection_omits_org_and_project_headers_when_unset
    provider = Parse::Embeddings::OpenAI.new(api_key: API_KEY)
    headers = provider.instance_variable_get(:@connection).headers
    refute headers.key?("OpenAI-Organization"), "must not send OpenAI-Organization when unset"
    refute headers.key?("OpenAI-Project"), "must not send OpenAI-Project when unset"
  end

  def test_build_connection_propagates_timeouts
    provider = Parse::Embeddings::OpenAI.new(
      api_key:      API_KEY,
      timeout:      17,
      open_timeout: 3,
    )
    conn = provider.instance_variable_get(:@connection)
    assert_equal 17, conn.options.timeout
    assert_equal 3,  conn.options.open_timeout
  end

  def test_build_connection_suppresses_env_proxy_by_default
    with_env("HTTPS_PROXY" => "http://attacker.example:8080") do
      provider = Parse::Embeddings::OpenAI.new(api_key: API_KEY)
      conn = provider.instance_variable_get(:@connection)
      assert_nil conn.proxy, "default must NOT inherit HTTPS_PROXY from env"
    end
  end

  def test_build_connection_uses_env_proxy_when_opted_in
    with_env("HTTPS_PROXY" => "http://corp-proxy.example:8080") do
      provider = Parse::Embeddings::OpenAI.new(
        api_key:             API_KEY,
        allow_faraday_proxy: true,
      )
      conn = provider.instance_variable_get(:@connection)
      refute_nil conn.proxy, "opt-in must surface HTTPS_PROXY from env"
      assert_equal "corp-proxy.example", conn.proxy.uri.host
    end
  end

  # ---- redaction list extension ----------------------------------------

  def test_redacted_headers_include_openai_credentials
    redacted = Parse::Middleware::BodyBuilder::REDACTED_HEADERS
    # `Authorization` carries the Bearer api_key on every request;
    # Organization/Project are account-identifying metadata operators
    # may want kept out of logs. `OpenAI-Api-Key` is intentionally NOT
    # in the list — OpenAI doesn't use that header (only the Bearer
    # Authorization header). Including it would imply the provider
    # sends it.
    %w[authorization openai-organization openai-project x-api-key].each do |h|
      assert_includes redacted, h, "REDACTED_HEADERS must filter #{h}"
    end
    refute_includes redacted, "openai-api-key",
                    "stale: provider uses Bearer Authorization, not OpenAI-Api-Key"
  end

  # ---- parse.embeddings.embed AS::N notification ----------------------

  def test_embed_emits_as_n_event_with_total_tokens_from_usage_envelope
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        [200, { "Content-Type" => "application/json" }, fake_response(3, 1536)]
      end
    end
    provider = build(connection: stubbed_conn(stubs))

    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("parse.embeddings.embed") do |*args|
      captured << ActiveSupport::Notifications::Event.new(*args)
    end
    begin
      provider.embed_text(["one", "two", "three"], input_type: :search_document)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 1, captured.length
    payload = captured.first.payload
    assert_equal "Parse::Embeddings::OpenAI", payload[:provider]
    assert_equal "text-embedding-3-small", payload[:model]
    assert_equal 1536, payload[:dimensions]
    assert_equal 3, payload[:input_count]
    assert_equal :search_document, payload[:input_type]
    # fake_response sets total_tokens == count
    assert_equal 3, payload[:total_tokens]
    assert_equal false, payload[:cached]
    assert_nil payload[:error]
  end

  def test_embed_event_records_error_class_when_network_call_fails
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        [401, { "Content-Type" => "application/json" }, '{"error":{"message":"bad key"}}']
      end
    end
    provider = build(connection: stubbed_conn(stubs))

    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("parse.embeddings.embed") do |*args|
      captured << ActiveSupport::Notifications::Event.new(*args)
    end
    begin
      assert_raises(Parse::Embeddings::OpenAI::AuthenticationError) do
        provider.embed_text(["x"])
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 1, captured.length
    assert_equal "Parse::Embeddings::OpenAI::AuthenticationError",
                 captured.first.payload[:error]
    # No tokens recorded on a failed call — the usage envelope never arrived.
    assert_nil captured.first.payload[:total_tokens]
  end

  def test_embed_event_tolerates_missing_usage_envelope
    body = {
      "data" => [{ "index" => 0, "embedding" => Array.new(1536, 1.0 / Math.sqrt(1536)) }],
      "model" => "text-embedding-3-small",
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/embeddings") do |_env|
        [200, { "Content-Type" => "application/json" }, body]
      end
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
    # No usage block → total_tokens stays nil; request still succeeds.
    assert_nil captured.first.payload[:total_tokens]
    assert_nil captured.first.payload[:error]
  end

  private

  def build(**overrides)
    opts = {
      api_key: API_KEY,
      model: "text-embedding-3-small",
    }.merge(overrides)
    Parse::Embeddings::OpenAI.new(**opts)
  end

  def stubbed_conn(stubs, headers: {})
    Faraday.new(url: "https://api.openai.test/v1",
                headers: {
                  "Authorization" => "Bearer #{API_KEY}",
                  "Content-Type" => "application/json",
                }.merge(headers)) do |f|
      f.adapter :test, stubs
    end
  end

  def empty_stubs
    Faraday::Adapter::Test::Stubs.new
  end

  # Temporarily override ENV vars for the duration of a block, restoring
  # whatever was there before. Used by build_connection proxy tests.
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
      "data" => (0...count).map do |i|
        # Cheap unit vector: 1.0/sqrt(dim) per element ⇒ ||v|| = 1
        { "index" => i, "embedding" => Array.new(dim, 1.0 / Math.sqrt(dim)) }
      end,
      "model" => "text-embedding-3-small",
      "usage" => { "prompt_tokens" => count, "total_tokens" => count },
    }.to_json
  end

  # Stub backoff on a specific provider instance so retry tests don't
  # pause. Per-instance to keep tests parallel-safe — overriding the
  # class would leak into any other test that happens to construct a
  # provider during the window.
  def silence_sleep(provider)
    provider.define_singleton_method(:backoff_seconds) { |_| 0 }
    yield
  end
end
