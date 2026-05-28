# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "parse/model/file"
require "faraday"

# Unit tests for Parse::Embeddings::Voyage#embed_image (v5.1). No
# network — every test injects a Faraday::Adapter::Test connection.
# The image URL validator is enabled per-test via the sentinel +
# allowed_image_hosts configuration.
class EmbeddingsVoyageImageTest < Minitest::Test
  API_KEY  = "pa-test-DO-NOT-LEAK"
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

  def test_embed_image_on_text_only_model_raises_bad_request
    enable_with_hosts(["1.1.1.1"])
    provider = build(model: "voyage-3", connection: stubbed_conn(empty_stubs))
    err = assert_raises(Parse::Embeddings::Voyage::BadRequestError) do
      provider.embed_image(["https://1.1.1.1/img.jpg"])
    end
    assert_match(/does not accept image inputs/, err.message)
    assert_match(/voyage-multimodal-3/, err.message)
  end

  def test_embed_image_reports_multimodal_modality
    provider = build(model: "voyage-multimodal-3")
    assert_equal %i[text image], provider.modalities
  end

  def test_text_only_model_still_reports_text_only_modality
    provider = build(model: "voyage-3")
    assert_equal [:text], provider.modalities
  end

  # ---- input validation -------------------------------------------------

  def test_embed_image_empty_batch_short_circuits
    enable_with_hosts(["1.1.1.1"])
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") { |_| flunk "Empty batch should not hit Voyage" }
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
    assert_match(/sources\[1\] is not a String/, err.message)
    # The URL-only constraint should be called out.
    assert_match(/URL-only/, err.message)
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
    # Configure provider with a small batch cap so the test doesn't
    # need to build 128+ URLs.
    provider = build(model: "voyage-multimodal-3",
                     embed_batch_size: 4,
                     connection: stubbed_conn(empty_stubs))
    urls = Array.new(5) { |i| "https://1.1.1.1/img#{i}.jpg" }
    err = assert_raises(ArgumentError) { provider.embed_image(urls) }
    assert_match(/batch size 5 exceeds.*cap 4/, err.message)
  end

  # ---- URL validation is enforced before network call -----------------

  def test_embed_image_aborts_batch_on_blocked_url
    # Allowlist BOTH the routable IP and 127.0.0.1 so the test pins
    # the CIDR check (not the allowlist) as the gate that catches the
    # private-IP URL. Operators cannot disable SSRF protection by
    # allowlisting a private host.
    enable_with_hosts(["1.1.1.1", "127.0.0.1"])
    network_hit = false
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |_|
        network_hit = true
        [200, { "Content-Type" => "application/json" }, fake_response(2, 1024)]
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
    refute network_hit, "Voyage must not be contacted when validation fails for any URL"
  end

  def test_embed_image_raises_confirmation_required_when_sentinel_off
    # Allowlist set, but sentinel never assigned.
    Parse::Embeddings.allowed_image_hosts = ["1.1.1.1"]
    provider = multimodal_provider(empty_stubs)
    assert_raises(Parse::Embeddings::ConfirmationRequired) do
      provider.embed_image(["https://1.1.1.1/img.jpg"])
    end
  end

  # ---- wire envelope ----------------------------------------------------

  def test_embed_image_posts_to_multimodal_endpoint_with_image_url_content
    enable_with_hosts(["1.1.1.1"])
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(2, 1024)]
      end
    end
    provider = multimodal_provider(stubs)
    vectors = provider.embed_image(
      ["https://1.1.1.1/a.jpg", "https://1.1.1.1/b.jpg"],
      input_type: :search_query,
    )
    assert_equal 2, vectors.length
    body = JSON.parse(captured_req.request_body)
    assert_equal "voyage-multimodal-3", body["model"]
    assert_equal "query", body["input_type"]
    assert_equal true, body["truncation"]
    assert_equal 2, body["inputs"].length
    body["inputs"].each_with_index do |entry, i|
      assert_equal 1, entry["content"].length
      row = entry["content"].first
      assert_equal "image_url", row["type"]
      expected_url = ["https://1.1.1.1/a.jpg", "https://1.1.1.1/b.jpg"][i]
      assert_equal expected_url, row["image_url"]
    end
    assert_equal "Bearer #{API_KEY}", captured_req.request_headers["Authorization"]
  end

  def test_embed_image_forwards_canonicalized_url_not_raw_input
    enable_with_hosts(["1.1.1.1"])
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = multimodal_provider(stubs)
    # Trailing slash + uppercase host get normalized by URI.parse.
    provider.embed_image(["https://1.1.1.1/X.JPG?q=1"])
    body = JSON.parse(captured_req.request_body)
    forwarded = body["inputs"].first["content"].first["image_url"]
    # URI.parse round-trip keeps the path/query as-is but is what the
    # validator returned — the caller never gets to bypass canonicalization.
    assert_equal "https://1.1.1.1/X.JPG?q=1", forwarded
  end

  def test_embed_image_omits_input_type_for_classification
    enable_with_hosts(["1.1.1.1"])
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = multimodal_provider(stubs)
    provider.embed_image(["https://1.1.1.1/x.jpg"], input_type: :classification)
    body = JSON.parse(captured_req.request_body)
    refute body.key?("input_type")
  end

  # ---- allow_insecure forwarded to validator --------------------------

  def test_embed_image_with_allow_insecure_permits_http
    enable_with_hosts(["1.1.1.1"])
    captured_req = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        captured_req = env
        [200, { "Content-Type" => "application/json" }, fake_response(1, 1024)]
      end
    end
    provider = multimodal_provider(stubs)
    provider.embed_image(["http://1.1.1.1/img.jpg"], allow_insecure: true)
    body = JSON.parse(captured_req.request_body)
    assert_equal "http://1.1.1.1/img.jpg",
      body["inputs"].first["content"].first["image_url"]
  end

  # ---- response shape reuses extract_vectors! -------------------------

  def test_embed_image_validates_response_dimensions
    enable_with_hosts(["1.1.1.1"])
    bad_body = {
      "data" => [{ "index" => 0, "embedding" => Array.new(8, 0.0) }],
      "model" => "voyage-multimodal-3",
    }.to_json
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") { |_| [200, { "Content-Type" => "application/json" }, bad_body] }
    end
    provider = multimodal_provider(stubs)
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.embed_image(["https://1.1.1.1/x.jpg"])
    end
    assert_match(/length 8 != declared dimensions 1024/, err.message)
  end

  private

  def build(**overrides)
    opts = { api_key: API_KEY, model: "voyage-3" }.merge(overrides)
    Parse::Embeddings::Voyage.new(**opts)
  end

  def multimodal_provider(stubs)
    build(model: "voyage-multimodal-3", connection: stubbed_conn(stubs))
  end

  def stubbed_conn(stubs)
    Faraday.new(url: "https://api.voyageai.test/v1",
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
      "object" => "list",
      "data" => (0...count).map do |i|
        { "object" => "embedding", "index" => i,
          "embedding" => Array.new(dim, 1.0 / Math.sqrt(dim)) }
      end,
      "model" => "voyage-multimodal-3",
      "usage" => { "total_tokens" => count },
    }.to_json
  end

  def enable_with_hosts(hosts)
    Parse::Embeddings.trust_provider_url_fetch = SENTINEL
    Parse::Embeddings.allowed_image_hosts = hosts
  end
end
