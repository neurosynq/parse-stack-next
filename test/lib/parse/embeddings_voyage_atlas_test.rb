# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "parse/model/file"
require "faraday"
require "tmpdir"
require "base64"

# Unit tests for the Atlas-endpoint awareness, the file-backed
# streaming media path, and video support on
# Parse::Embeddings::Voyage. No network — every test injects a
# Faraday::Adapter::Test connection.
class EmbeddingsVoyageAtlasTest < Minitest::Test
  VOYAGE_KEY = "pa-test-DO-NOT-LEAK"
  ATLAS_KEY  = "al-test-DO-NOT-LEAK"
  SENTINEL   = "PROVIDER_EGRESS_VERIFIED"

  def setup
    Parse::Embeddings.reset!
    @dir = Dir.mktmpdir("psnext-media")
    @prior_ports = Parse::File.allowed_remote_ports.dup
    @prior_hosts = Parse::File.allowed_remote_hosts.dup
  end

  def teardown
    Parse::Embeddings.reset!
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
    Parse::File.allowed_remote_ports = @prior_ports
    Parse::File.allowed_remote_hosts = @prior_hosts
  end

  # ---- endpoint resolution ---------------------------------------------

  def test_atlas_key_prefix_selects_atlas_endpoint
    provider = build(api_key: ATLAS_KEY, model: "voyage-4")
    assert_equal :atlas, provider.endpoint
    assert provider.atlas?
  end

  def test_voyage_key_selects_voyage_endpoint
    provider = build(api_key: VOYAGE_KEY, model: "voyage-4")
    assert_equal :voyage, provider.endpoint
    refute provider.atlas?
  end

  def test_explicit_endpoint_overrides_key_inference
    provider = build(api_key: VOYAGE_KEY, model: "voyage-4", endpoint: :atlas)
    assert_equal :atlas, provider.endpoint
  end

  def test_endpoint_is_inferred_from_an_explicit_base_url
    provider = build(api_key: VOYAGE_KEY, model: "voyage-4",
                     base_url: Parse::Embeddings::Voyage::ATLAS_BASE_URL)
    assert_equal :atlas, provider.endpoint
  end

  def test_unrecognized_base_url_reports_custom_endpoint
    provider = build(api_key: VOYAGE_KEY, model: "voyage-4",
                     base_url: "https://proxy.internal/v1")
    assert_equal :custom, provider.endpoint
  end

  # A named endpoint that disagrees with the URL is a configuration
  # error — silently preferring one would send the credential to a host
  # the caller did not intend.
  def test_endpoint_contradicting_base_url_raises
    err = assert_raises(ArgumentError) do
      build(api_key: ATLAS_KEY, model: "voyage-4", endpoint: :voyage,
            base_url: Parse::Embeddings::Voyage::ATLAS_BASE_URL)
    end
    assert_match(/contradicts base_url host/, err.message)
  end

  def test_rejects_unknown_endpoint_symbol
    assert_raises(ArgumentError) { build(api_key: ATLAS_KEY, endpoint: :nope) }
  end

  # ---- Atlas model availability ----------------------------------------

  def test_atlas_rejects_models_the_endpoint_does_not_expose
    Parse::Embeddings::Voyage::ATLAS_UNAVAILABLE_MODELS.each do |model|
      err = assert_raises(ArgumentError) { build(api_key: ATLAS_KEY, model: model) }
      assert_match(/not available on the Atlas/, err.message)
    end
  end

  def test_same_models_are_accepted_on_the_voyage_endpoint
    Parse::Embeddings::Voyage::ATLAS_UNAVAILABLE_MODELS.each do |model|
      assert_equal :voyage, build(api_key: VOYAGE_KEY, model: model).endpoint
    end
  end

  # ---- modalities -------------------------------------------------------

  def test_video_capable_model_reports_video_modality
    assert_equal %i[text image video],
                 build(api_key: ATLAS_KEY, model: "voyage-multimodal-3.5").modalities
  end

  def test_multimodal_3_reports_no_video
    assert_equal %i[text image],
                 build(api_key: ATLAS_KEY, model: "voyage-multimodal-3").modalities
  end

  def test_embed_video_on_non_video_model_raises_before_any_request
    provider = build(api_key: ATLAS_KEY, model: "voyage-multimodal-3",
                     connection: stubbed_conn(flunking_stubs))
    err = assert_raises(Parse::Embeddings::Voyage::BadRequestError) do
      provider.embed_video([media_video])
    end
    assert_match(/does not accept video inputs/, err.message)
  end

  # ---- MediaFile sniffing ----------------------------------------------

  def test_media_file_sniffs_png_without_reading_whole_file
    m = Parse::Embeddings::MediaFile.image(write_png)
    assert_equal "image/png", m.mime_type
    assert_equal :image, m.kind
    assert_equal "data:image/png;base64,", m.data_uri_prefix
  end

  def test_media_file_sniffs_mp4
    m = Parse::Embeddings::MediaFile.video(write_mp4)
    assert_equal "video/mp4", m.mime_type
    assert_equal :video, m.kind
  end

  def test_media_file_refuses_content_whose_magic_bytes_are_unknown
    path = ::File.join(@dir, "fake.png")
    ::File.binwrite(path, "not really a png at all")
    assert_raises(Parse::Embeddings::ImageFetch::InvalidImageType) do
      Parse::Embeddings::MediaFile.image(path)
    end
  end

  # An image must not slip through the video constructor just because
  # the caller named it wrong — the magic bytes govern.
  def test_media_file_video_refuses_an_image
    assert_raises(Parse::Embeddings::VideoSource::InvalidVideoType) do
      Parse::Embeddings::MediaFile.video(write_png)
    end
  end

  def test_media_file_rejects_empty_and_missing_files
    empty = ::File.join(@dir, "empty.png")
    ::File.binwrite(empty, "")
    assert_raises(Parse::Embeddings::ImageFetch::InvalidImageType) do
      Parse::Embeddings::MediaFile.image(empty)
    end
    assert_raises(ArgumentError) do
      Parse::Embeddings::MediaFile.image(::File.join(@dir, "nope.png"))
    end
  end

  def test_media_file_inspect_does_not_leak_contents
    refute_match(/base64|\\x/, Parse::Embeddings::MediaFile.image(write_png).inspect)
  end

  # Voyage accepts MP4 only; the live API rejects WebM and QuickTime.
  # Refusing them locally turns an opaque provider 400 into a clear
  # error naming what was actually supplied.
  def test_video_allowlist_is_mp4_only
    assert_equal %w[video/mp4], Parse::Embeddings.allowed_video_types

    webm = ::File.join(@dir, "clip.webm")
    ::File.binwrite(webm, "\x1A\x45\xDF\xA3#{"\x00" * 32}")
    err = assert_raises(Parse::Embeddings::VideoSource::InvalidVideoType) do
      Parse::Embeddings::MediaFile.video(webm)
    end
    assert_equal :type_not_allowed, err.reason
    assert_match(%r{video/webm}, err.message)

    mov = ::File.join(@dir, "clip.mov")
    ::File.binwrite(mov, "\x00\x00\x00\x14ftypqt  \x00\x00\x02\x00#{"\x00" * 32}")
    assert_equal :type_not_allowed,
                 assert_raises(Parse::Embeddings::VideoSource::InvalidVideoType) {
                   Parse::Embeddings::MediaFile.video(mov)
                 }.reason
  end

  # An `ftyp` box alone does not imply MP4 — QuickTime shares the
  # container — so an unrecognized brand must not be assumed valid.
  def test_unknown_iso_bmff_brand_is_not_assumed_to_be_mp4
    path = ::File.join(@dir, "weird.mp4")
    ::File.binwrite(path, "\x00\x00\x00\x14ftypXXXX\x00\x00\x02\x00#{"\x00" * 32}")
    err = assert_raises(Parse::Embeddings::VideoSource::InvalidVideoType) do
      Parse::Embeddings::MediaFile.video(path)
    end
    assert_equal :unknown_magic, err.reason
  end

  def test_media_file_enforces_the_size_cap
    Parse::Embeddings.max_media_bytes = 512
    path = ::File.join(@dir, "big.png")
    ::File.binwrite(path, png_bytes + ("\x00" * 1024))
    err = assert_raises(Parse::Embeddings::MediaFile::TooLarge) do
      Parse::Embeddings::MediaFile.image(path)
    end
    assert_match(/max_media_bytes/, err.message)
  end

  def test_size_cap_defaults_to_twenty_megabytes
    assert_equal 20 * 1024 * 1024, Parse::Embeddings.max_media_bytes
  end

  # M4A is Apple's audio-only profile and shares the ISO-BMFF
  # container with MP4. Admitting its brand would let an audio file
  # pass as video.
  def test_m4a_audio_is_not_accepted_as_video
    path = ::File.join(@dir, "audio.m4a")
    ::File.binwrite(path, "\x00\x00\x00\x1CftypM4A \x00\x00\x02\x00#{"\x00" * 32}")
    assert_nil Parse::Embeddings::VideoSource.sniff_mime(::File.binread(path))
    err = assert_raises(Parse::Embeddings::VideoSource::InvalidVideoType) do
      Parse::Embeddings::MediaFile.video(path)
    end
    assert_equal :unknown_magic, err.reason
    refute_includes Parse::Embeddings::VideoSource::MP4_BRANDS, "M4A"
  end

  # Raising the global knob must not let an oversized payload through:
  # Voyage's own ceiling is enforced by the adapter.
  def test_provider_enforces_voyage_size_ceiling_even_if_global_is_raised
    Parse::Embeddings.max_media_bytes = 64 * 1024 * 1024
    oversized = Parse::Embeddings::ImageFetch::FetchedImage.new(
      bytes: "\x00" * (Parse::Embeddings::Voyage::MAX_MEDIA_BYTES + 1),
      mime_type: "image/png", url: nil
    )
    provider = multimodal(flunking_stubs_conn)
    err = assert_raises(Parse::Embeddings::Voyage::BadRequestError) do
      provider.embed_image([oversized])
    end
    assert_match(/over Voyage's \d+-byte per-file limit/, err.message)
  end

  # ---- streamed wire bodies --------------------------------------------

  def test_streamed_image_body_carries_full_base64_payload
    png = write_png
    captured = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        captured = read_body(env)
        [200, json_headers, fake_response(1, 1024)]
      end
    end
    provider = multimodal(stubs)
    provider.embed_image([Parse::Embeddings::MediaFile.image(png)])

    body = JSON.parse(captured)
    row = body["inputs"][0]["content"][0]
    assert_equal "image_base64", row["type"]
    assert_equal "data:image/png;base64,#{Base64.strict_encode64(::File.binread(png))}",
                 row["image_base64"]
    assert_equal "voyage-multimodal-3", body["model"]
    assert_equal true, body["truncation"]
  end

  def test_streamed_video_body_uses_video_base64_row
    mp4 = write_mp4
    captured = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        captured = read_body(env)
        [200, json_headers, fake_response(1, 1024)]
      end
    end
    provider = multimodal(stubs, model: "voyage-multimodal-3.5")
    provider.embed_video([Parse::Embeddings::MediaFile.video(mp4)])

    row = JSON.parse(captured)["inputs"][0]["content"][0]
    assert_equal "video_base64", row["type"]
    assert_equal "data:video/mp4;base64,#{Base64.strict_encode64(::File.binread(mp4))}",
                 row["video_base64"]
  end

  # Voyage requires one representation per request, so a mixed batch is
  # split. The caller's 1:1 ordering must survive the split.
  def test_mixed_batch_is_split_into_one_request_per_representation
    enable_urls(["1.1.1.1"])
    png = write_png
    bodies = []
    provider = multimodal(counting_stubs { |b| bodies << b })
    provider.embed_image([
      "https://1.1.1.1/a.jpg",
      Parse::Embeddings::MediaFile.image(png),
      "https://1.1.1.1/b.jpg",
    ])

    assert_equal 2, bodies.length, "mixed batch must not go out as one request"
    bodies.each do |raw|
      types = JSON.parse(raw)["inputs"].map { |r| r["content"][0]["type"] }
      assert_equal 1, types.uniq.length, "each request must use a single representation"
    end
    assert_equal [2, 1], bodies.map { |b| JSON.parse(b)["inputs"].length }
  end

  def test_split_batch_preserves_caller_ordering
    enable_urls(["1.1.1.1"])
    png = write_png
    # Encode each vector's first element with its input's slot so the
    # reassembled order can be asserted rather than assumed.
    provider = multimodal(ordered_stubs)
    vectors = provider.embed_image([
      "https://1.1.1.1/url0.jpg",
      Parse::Embeddings::MediaFile.image(png),
      "https://1.1.1.1/url2.jpg",
    ])

    assert_equal 3, vectors.length
    assert_equal "url0.jpg", tag_of(vectors[0])
    assert_equal "base64", tag_of(vectors[1])
    assert_equal "url2.jpg", tag_of(vectors[2])
  end

  # A caller-controlled URL must never be able to capture a streamed
  # file's bytes. The body is assembled structurally, so a URL that
  # happens to look like an internal token is inert.
  def test_url_cannot_capture_a_streamed_files_bytes
    enable_urls(["1.1.1.1"])
    png = write_png
    bodies = []
    provider = multimodal(counting_stubs { |b| bodies << b })
    provider.embed_image([
      "https://1.1.1.1/a.jpg?c=PSNEXTxSTREAMxSLOTx0&d=inputs&e=image_base64",
      Parse::Embeddings::MediaFile.image(png),
    ])

    encoded = Base64.strict_encode64(::File.binread(png))
    # Select by parsed content type — the hostile URL deliberately
    # contains the literal "image_base64", so a substring match here
    # would pick the wrong body.
    parsed = bodies.map { |b| JSON.parse(b) }
    url_body = parsed.find { |b| b["inputs"][0]["content"][0]["type"] == "image_url" }
    b64_body = parsed.find { |b| b["inputs"][0]["content"][0]["type"] == "image_base64" }

    url_value = url_body["inputs"][0]["content"][0]["image_url"]
    refute_includes url_value, encoded,
                    "file bytes must never be spliced into a caller-supplied URL"
    assert_equal "https://1.1.1.1/a.jpg?c=PSNEXTxSTREAMxSLOTx0&d=inputs&e=image_base64",
                 url_value

    b64_value = b64_body["inputs"][0]["content"][0]["image_base64"]
    assert_equal "data:image/png;base64,#{encoded}", b64_value
  end

  # Metacharacters in a URL must not be able to break out of the JSON
  # string and restructure the request.
  def test_url_with_json_metacharacters_is_escaped
    enable_urls(["1.1.1.1"])
    bodies = []
    provider = multimodal(counting_stubs { |b| bodies << b })
    hostile = 'https://1.1.1.1/a.jpg?q=%22%7D%5D%2C%22model%22%3A%22evil'
    provider.embed_image([hostile])

    body = JSON.parse(bodies.first)
    assert_equal "voyage-multimodal-3", body["model"], "model must not be overridable via a URL"
    assert_equal 1, body["inputs"].length
  end

  def test_streamed_body_sets_exact_content_length
    png = write_png
    captured = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        captured = env
        [200, json_headers, fake_response(1, 1024)]
      end
    end
    provider = multimodal(stubs)
    provider.embed_image([Parse::Embeddings::MediaFile.image(png)])

    declared = captured.request_headers["Content-Length"].to_i
    assert_equal read_body(captured).bytesize, declared
  end

  # Without a file-backed source there is nothing to stream, so the
  # body should stay a plain serialized Hash.
  def test_url_only_batch_does_not_use_a_streaming_body
    enable_urls(["1.1.1.1"])
    captured = nil
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        captured = env
        [200, json_headers, fake_response(1, 1024)]
      end
    end
    multimodal(stubs).embed_image(["https://1.1.1.1/a.jpg"])
    assert_kind_of String, captured.request_body
  end

  def test_video_media_file_rejected_by_embed_image
    provider = multimodal(flunking_stubs_conn)
    err = assert_raises(ArgumentError) { provider.embed_image([media_video]) }
    assert_match(/expected image/, err.message)
  end

  private

  def build(**overrides)
    opts = { api_key: ATLAS_KEY, model: "voyage-4" }.merge(overrides)
    Parse::Embeddings::Voyage.new(**opts)
  end

  def multimodal(stubs, model: "voyage-multimodal-3")
    conn = stubs.is_a?(Faraday::Connection) ? stubs : stubbed_conn(stubs)
    build(model: model, connection: conn)
  end

  def stubbed_conn(stubs)
    Faraday.new(url: "https://ai.mongodb.test/v1",
                headers: { "Authorization" => "Bearer #{ATLAS_KEY}",
                           "Content-Type" => "application/json" }) do |f|
      f.adapter :test, stubs
    end
  end

  def flunking_stubs
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") { |_| flunk "must not reach the network" }
    end
  end

  # Responds with exactly as many vectors as the request asked for, so
  # split batches are answered correctly, and hands each raw body to
  # the block for inspection.
  def counting_stubs(&capture)
    test = self
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        raw = test.send(:read_body, env)
        capture&.call(raw)
        [200, { "Content-Type" => "application/json" },
         test.send(:fake_response, JSON.parse(raw)["inputs"].length, 1024)]
      end
    end
  end

  # Tags each returned vector with the source it answers, so ordering
  # across a split batch can be asserted end to end.
  def ordered_stubs
    test = self
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post("/v1/multimodalembeddings") do |env|
        rows = JSON.parse(test.send(:read_body, env))["inputs"]
        data = rows.each_with_index.map do |row, i|
          content = row["content"][0]
          tag = content["type"] == "image_url" ? ::File.basename(URI.parse(content["image_url"]).path) : "base64"
          { "object" => "embedding", "index" => i,
            "embedding" => test.send(:tagged_vector, tag) }
        end
        [200, { "Content-Type" => "application/json" },
         { "object" => "list", "data" => data, "model" => "m",
           "usage" => { "total_tokens" => rows.length } }.to_json]
      end
    end
  end

  # Encode a short ASCII tag into the leading floats of a unit vector.
  TAG_SCALE = 1000.0

  def tagged_vector(tag)
    vec = Array.new(1024, 0.0)
    tag.bytes.each_with_index { |b, i| vec[i] = b / TAG_SCALE }
    vec
  end

  def tag_of(vector)
    vector.take(32).map { |f| (f * TAG_SCALE).round }.reject(&:zero?).pack("C*")
  end

  def flunking_stubs_conn
    stubbed_conn(flunking_stubs)
  end

  # The test adapter leaves a StreamingBody as an IO; drain it so
  # assertions can inspect the bytes that would go on the wire.
  def read_body(env)
    body = env.request_body
    return body if body.is_a?(String)
    body.rewind
    out = +""
    while (c = body.read(4096))
      out << c
    end
    out
  end

  def json_headers
    { "Content-Type" => "application/json" }
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

  def enable_urls(hosts)
    Parse::Embeddings.trust_provider_url_fetch = SENTINEL
    Parse::Embeddings.allowed_image_hosts = hosts
  end

  def media_video
    Parse::Embeddings::MediaFile.video(write_mp4)
  end

  # 1x1 PNG, written byte-wise so the sniffer sees real magic bytes.
  def png_bytes
    Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
  end

  def write_png
    path = ::File.join(@dir, "img.png")
    ::File.binwrite(path, png_bytes)
    path
  end

  # Minimal ISO Base Media header — `ftyp` box with an `isom` brand,
  # padded so the file clears the 12-byte sniff floor.
  def write_mp4
    path = ::File.join(@dir, "clip.mp4")
    ::File.binwrite(path, "\x00\x00\x00\x20ftypisom\x00\x00\x02\x00#{"\x00" * 64}")
    path
  end
end
