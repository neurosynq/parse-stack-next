# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "parse/model/file"
require "faraday"

# Unit tests for Parse::Embeddings::Cohere#embed_image (v5.1). No
# network — every test injects a Faraday::Adapter::Test connection.
# Mirrors test/lib/parse/embeddings_voyage_image_test.rb in shape;
# Cohere v2's wire envelope differs from Voyage (`image_url: { url: }`
# nested object vs Voyage's flat String) so the body assertions diverge.
class EmbeddingsCohereImageTest < Minitest::Test
  API_KEY  = "co-test-DO-NOT-LEAK"
  SENTINEL = "PROVIDER_EGRESS_VERIFIED"

  def setup
    Parse::Embeddings.reset!
    @prior_ports = Parse::File.allowed_remote_ports.dup
    @prior_hosts = Parse::File.allowed_remote_hosts.dup
  end

  def teardown
    Parse::Embeddings.reset!
    Parse::File.allowed_remote_ports = @prior_ports
    Parse::File.allowed_remote_hosts = @prior_hosts
  end

  # ---- model gating ----------------------------------------------------

  def test_embed_image_on_v3_model_raises_bad_request
    enable_with_hosts(["1.1.1.1"])
    provider = build(model: "embed-english-v3.0", connection: stubbed_conn(empty_stubs))
    err = assert_raises(Parse::Embeddings::Cohere::BadRequestError) do
      provider.embed_image(["https://1.1.1.1/img.jpg"])
    end
    assert_match(/does not accept image inputs/, err.message)
    assert_match(/embed-v4\.0/, err.message)
  end

  def test_embed_image_reports_multimodal_modality
    provider = build(model: "embed-v4.0")
    assert_equal %i[text image], provider.modalities
  end

  def test_v3_model_reports_text_only_modality
    provider = build(model: "embed-english-v3.0")
    assert_equal [:text], provider.modalities
  end

  # ---- input validation ------------------------------------------------

  def test_embed_image_empty_batch_short_circuits
    enable_with_hosts(["1.1.1.1"])
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v2/embed") { |_| flunk "Empty batch must not hit Cohere" }
    end
    provider = multimodal_provider(stubs)
    assert_equal [], provider.embed_image([])
  end

  def test_embed_image_rejects_non_array
    enable_with_hosts(["1.1.1.1"])
    provider = multimodal_provider(empty_stubs)
    err = assert_raises(ArgumentError) { provider.embed_image("https://1.1.1.1/img.jpg") }
    assert_match(/Array of image URLs/, err.message)
  end

  def test_embed_image_rejects_non_string_source
    enable_with_hosts(["1.1.1.1"])
    provider = multimodal_provider(empty_stubs)
    err = assert_raises(ArgumentError) do
      provider.embed_image(["https://1.1.1.1/img.jpg", 12345])
    end
    assert_match(/sources\[1\] must be a URL String/, err.message)
    assert_match(/FetchedImage/, err.message)
  end

  def test_embed_image_rejects_unknown_input_type
    enable_with_hosts(["1.1.1.1"])
    provider = multimodal_provider(empty_stubs)
    assert_raises(ArgumentError) do
      provider.embed_image(["https://1.1.1.1/img.jpg"], input_type: :nonsense)
    end
  end

  def test_embed_image_rejects_oversized_batch
    enable_with_hosts(["1.1.1.1"])
    provider = build(model: "embed-v4.0",
                     embed_batch_size: 4,
                     connection: stubbed_conn(empty_stubs))
    urls = Array.new(5) { |i| "https://1.1.1.1/img#{i}.jpg" }
    err = assert_raises(ArgumentError) { provider.embed_image(urls) }
    assert_match(/batch size 5 exceeds.*cap 4/, err.message)
  end

  # ---- URL validation gates the wire call -----------------------------

  def test_embed_image_aborts_batch_on_blocked_url
    # Allowlist BOTH so the CIDR check (not the allowlist) catches
    # the private-IP URL — same pattern as the Voyage test.
    enable_with_hosts(["1.1.1.1", "127.0.0.1"])
    network_hit = false
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v2/embed") do |_|
        network_hit = true
        [200, { "Content-Type" => "application/json" }, fake_response(2, 1536)]
      end
    end
    provider = multimodal_provider(stubs)
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      provider.embed_image([
        "https://1.1.1.1/ok.jpg",
        "https://127.0.0.1/blocked.jpg",
      ])
    end
    assert_equal :host_blocked, err.reason
    refute network_hit, "Cohere must not be contacted when validation fails for any URL"
  end

  def test_embed_image_raises_confirmation_required_when_sentinel_off
    Parse::Embeddings.allowed_image_hosts = ["1.1.1.1"]
    provider = multimodal_provider(empty_stubs)
    assert_raises(Parse::Embeddings::ConfirmationRequired) do
      provider.embed_image(["https://1.1.1.1/img.jpg"])
    end
  end

  # ---- wire envelope: nested image_url shape --------------------------

  def test_embed_image_posts_to_v2_embed_with_nested_image_url_content
    enable_with_hosts(["1.1.1.1"])
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v2/embed") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(2, 1536)]
      end
    end
    provider = multimodal_provider(stubs)
    vectors = provider.embed_image(
      ["https://1.1.1.1/a.jpg", "https://1.1.1.1/b.jpg"],
      input_type: :search_query,
    )
    assert_equal 2, vectors.length

    body = JSON.parse(captured_req.request_body)
    assert_equal "embed-v4.0", body["model"]
    assert_equal "search_query", body["input_type"]
    assert_equal ["float"], body["embedding_types"]
    assert_equal 2, body["inputs"].length
    body["inputs"].each_with_index do |entry, i|
      assert_equal 1, entry["content"].length
      row = entry["content"].first
      assert_equal "image_url", row["type"]
      # Cohere v2 uses {image_url: {url: "..."}} — nested object, not
      # a flat String. This is the key wire difference from Voyage.
      assert_kind_of Hash, row["image_url"]
      expected = ["https://1.1.1.1/a.jpg", "https://1.1.1.1/b.jpg"][i]
      assert_equal expected, row["image_url"]["url"]
    end
    assert_equal "Bearer #{API_KEY}", captured_req.request_headers["Authorization"]
  end

  def test_embed_image_routes_v4_to_v2_endpoint_not_v1
    # Negative path — make sure the v1 endpoint is NOT called for
    # image embedding, even with embed-v4.0 (which also serves the
    # text path on v1).
    enable_with_hosts(["1.1.1.1"])
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v2/embed") { |_| [200, { "Content-Type" => "application/json" }, fake_response(1, 1536)] }
      stub.post("/v1/embed") { |_| flunk "embed_image must NOT post to /v1/embed" }
      stub.post("embed")     { |_| flunk "embed_image must NOT post to relative embed (v1)" }
    end
    provider = multimodal_provider(stubs)
    provider.embed_image(["https://1.1.1.1/x.jpg"])
  end

  def test_embed_image_forwards_canonical_url
    enable_with_hosts(["1.1.1.1"])
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v2/embed") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1536)]
      end
    end
    provider = multimodal_provider(stubs)
    provider.embed_image(["https://1.1.1.1/X.JPG?q=1"])
    body = JSON.parse(captured_req.request_body)
    forwarded = body["inputs"].first["content"].first["image_url"]["url"]
    assert_equal "https://1.1.1.1/X.JPG?q=1", forwarded
  end

  # ---- allow_insecure pass-through -----------------------------------

  def test_embed_image_with_allow_insecure_permits_http
    enable_with_hosts(["1.1.1.1"])
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v2/embed") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1536)]
      end
    end
    provider = multimodal_provider(stubs)
    provider.embed_image(["http://1.1.1.1/img.jpg"], allow_insecure: true)
    body = JSON.parse(captured_req.request_body)
    assert_equal "http://1.1.1.1/img.jpg",
      body["inputs"].first["content"].first["image_url"]["url"]
  end

  # ---- response-shape validation reuses extract_vectors! -------------

  def test_embed_image_validates_response_dimensions
    enable_with_hosts(["1.1.1.1"])
    # Cohere v2 returns embeddings.float; wrong-width vector trips
    # validate_response! the same as the text path.
    bad_body = { "embeddings" => { "float" => [Array.new(8, 0.0)] } }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v2/embed") { |_| [200, { "Content-Type" => "application/json" }, bad_body] }
    end
    provider = multimodal_provider(stubs)
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.embed_image(["https://1.1.1.1/x.jpg"])
    end
    assert_match(/length 8 != declared dimensions 1536/, err.message)
  end

  # ---- token cost passes through on AS::N -----------------------------

  # Regression test for the round-2-review finding: an operator using a
  # custom-proxy base_url like "https://corp-proxy.example.com/cohere/v1"
  # must have embed_image POST to "/cohere/v2/embed" — NOT the host-root
  # "/v2/embed" that an absolute path would silently route to. Without
  # the fix, the proxy's egress-logging / API-key custody / rate-limit
  # layer is bypassed by image embedding while text embedding still
  # honors it.
  def test_embed_image_routes_through_custom_proxy_base_path
    enable_with_hosts(["1.1.1.1"])
    captured_path = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/cohere/v2/embed") do |env|
        captured_path = env.url.path
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1536)]
      end
    end
    # Build a connection bound to a proxy-shaped base URL.
    conn = Faraday.new(url: "https://corp-proxy.example.test/cohere/v1",
                       headers: { "Authorization" => "Bearer #{API_KEY}",
                                  "Content-Type"  => "application/json" }) do |f|
      f.adapter :test, stubs
    end
    provider = Parse::Embeddings::Cohere.new(
      api_key: API_KEY, model: "embed-v4.0",
      base_url: "https://corp-proxy.example.test/cohere/v1",
      connection: conn,
    )

    provider.embed_image(["https://1.1.1.1/x.jpg"])
    assert_equal "/cohere/v2/embed", captured_path,
      "embed_image must POST under the proxy base path, not host-root /v2/embed"
  end

  def test_embed_image_extracts_billed_input_tokens_into_payload
    enable_with_hosts(["1.1.1.1"])
    body_with_meta = {
      "embeddings" => { "float" => [Array.new(1536, 0.0)] },
      "meta" => { "billed_units" => { "input_tokens" => 42 } },
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v2/embed") { |_| [200, { "Content-Type" => "application/json" }, body_with_meta] }
    end
    captured_payload = nil
    subscriber = ActiveSupport::Notifications.subscribe("parse.embeddings.embed") do |*args|
      captured_payload = args.last
    end
    begin
      multimodal_provider(stubs).embed_image(["https://1.1.1.1/x.jpg"])
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end
    refute_nil captured_payload
    assert_equal 42, captured_payload[:total_tokens]
    assert_equal :image, captured_payload[:modality]
  end

  private

  def build(**overrides)
    opts = { api_key: API_KEY, model: "embed-english-v3.0" }.merge(overrides)
    Parse::Embeddings::Cohere.new(**opts)
  end

  def multimodal_provider(stubs)
    build(model: "embed-v4.0", connection: stubbed_conn(stubs))
  end

  def stubbed_conn(stubs)
    # Base URL has /v1/ — but the embed_image path is absolute /v2/embed
    # so Faraday should route to /v2/embed on the host.
    Faraday.new(url: "https://api.cohere.test/v1",
                headers: { "Authorization" => "Bearer #{API_KEY}",
                           "Content-Type"  => "application/json" }) do |f|
      f.adapter :test, stubs
    end
  end

  def empty_stubs
    Faraday::Adapter::Test::Stubs.new
  end

  def fake_response(count, dim)
    {
      "embeddings" => { "float" => (0...count).map { Array.new(dim, 1.0 / Math.sqrt(dim)) } },
      "meta" => { "billed_units" => { "input_tokens" => count } },
    }.to_json
  end

  def enable_with_hosts(hosts)
    Parse::Embeddings.trust_provider_url_fetch = SENTINEL
    Parse::Embeddings.allowed_image_hosts = hosts
  end
end
