# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "base64"
require "tmpdir"

# LIVE contract tests for the Voyage embeddings provider.
#
# These issue real, billable requests and are SKIPPED unless
# `VOYAGE_CONTRACT_KEY` is set. Ordinary PR runs stay mocked and
# credential-free; run these manually or on a nightly schedule.
#
#   VOYAGE_CONTRACT_KEY=al-... bundle exec rake test:contract
#
# Why they exist: mocked tests assert what the SDK *believes* the API
# does, so they cannot detect provider drift. Every fact this file pins
# was, at some point, wrong in the SDK while the mocked suite was fully
# green — the v4 dimension table, the accepted video containers, the
# endpoint a key authenticates against. A mock cannot catch any of that.
#
# The matrix is deliberately minimal: one probe per contract fact, the
# cheapest model that exercises it, one-token inputs.
class EmbeddingsVoyageContractTest < Minitest::Test
  KEY = ENV["VOYAGE_CONTRACT_KEY"]

  def setup
    skip "set VOYAGE_CONTRACT_KEY to run live Voyage contract tests" if KEY.nil? || KEY.empty?
    Parse::Embeddings.reset!
    @dir = Dir.mktmpdir("psnext-contract")
  end

  def teardown
    Parse::Embeddings.reset!
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  # ---- request routing --------------------------------------------------

  # The key prefix must select the host the key actually authenticates
  # against. Getting this wrong is an immediate 403.
  def test_key_prefix_routes_to_an_endpoint_that_accepts_it
    provider = build(model: "voyage-3.5")
    expected = KEY.start_with?(Parse::Embeddings::Voyage::ATLAS_KEY_PREFIX) ? :atlas : :voyage
    assert_equal expected, provider.endpoint

    vectors = provider.embed_text(["contract probe"])
    assert_equal 1, vectors.length, "routing is wrong if this 403s"
  end

  # ---- dimensions -------------------------------------------------------

  # Every model's declared native width must match what the API returns
  # with no output_dimension requested.
  def test_declared_native_dimensions_match_the_live_api
    mismatches = []
    contract_models.each do |model|
      provider = build(model: model)
      actual = provider.embed_text(["d"]).first.length
      mismatches << "#{model}: declared #{provider.dimensions}, got #{actual}" if actual != provider.dimensions
    end
    assert_empty mismatches, "native dimension table has drifted:\n  #{mismatches.join("\n  ")}"
  end

  # Each width on a model's Matryoshka ladder must actually be honored.
  def test_matryoshka_ladder_widths_are_honored
    model = "voyage-3.5"
    supported = Parse::Embeddings::Voyage::MODEL_SUPPORTED_DIMENSIONS.fetch(model)
    supported.each do |width|
      actual = build(model: model, dimensions: width).embed_text(["m"]).first.length
      assert_equal width, actual, "#{model} did not honor output_dimension #{width}"
    end
  end

  # ---- response shape ---------------------------------------------------

  def test_response_envelope_shape_is_stable
    provider = build(model: "voyage-3.5")
    vectors = provider.embed_text(%w[alpha beta], input_type: :search_document)
    assert_equal 2, vectors.length
    assert vectors.all? { |v| v.is_a?(Array) && v.all?(Float) }
    assert_equal vectors[0].length, vectors[1].length
    # Alignment is positional; distinct inputs must not collapse.
    refute_equal vectors[0], vectors[1]
  end

  def test_asymmetric_input_types_are_accepted
    provider = build(model: "voyage-3.5")
    q = provider.embed_text(["a query"], input_type: :search_query).first
    d = provider.embed_text(["a document"], input_type: :search_document).first
    assert_equal q.length, d.length
  end

  # ---- accepted media ---------------------------------------------------

  def test_multimodal_model_accepts_a_streamed_image
    provider = build(model: "voyage-multimodal-3")
    vectors = provider.embed_image([Parse::Embeddings::MediaFile.image(write_png)])
    assert_equal 1, vectors.length
    assert_equal provider.dimensions, vectors.first.length
  end

  def test_video_capable_model_accepts_a_streamed_mp4
    skip "ffmpeg not available" unless ffmpeg?
    provider = build(model: "voyage-multimodal-3.5")
    vectors = provider.embed_video([Parse::Embeddings::MediaFile.video(write_mp4)])
    assert_equal 1, vectors.length
    assert_equal provider.dimensions, vectors.first.length
  end

  # voyage-multimodal-3 must keep rejecting video; if it ever starts
  # accepting it, VIDEO_MODELS is stale and should be widened.
  #
  # This goes over raw HTTP deliberately: calling `embed_video` would be
  # stopped by the SDK's own VIDEO_MODELS guard before any request, so
  # it would assert the guard rather than the contract the guard encodes.
  def test_non_video_multimodal_model_still_rejects_video
    skip "ffmpeg not available" unless ffmpeg?
    body = {
      model: "voyage-multimodal-3", input_type: "document",
      inputs: [{ content: [{ type: "video_base64",
                             video_base64: data_uri(write_mp4, "video/mp4") }] }],
    }
    status, response = raw_post("multimodalembeddings", body)
    refute_infrastructure_failure(status, response, "video rejection probe")
    refute response.key?("data"),
           "voyage-multimodal-3 now accepts video — VIDEO_MODELS is stale"
    # Require the SPECIFIC refusal, not merely the absence of data — a
    # generic 400 would otherwise pass for the wrong reason.
    assert_match(/video/i, response["detail"].to_s,
                 "expected a video-capability refusal, got: #{response["detail"].inspect}")
  end

  # The SDK refuses WebM/QuickTime locally because the API refuses them.
  # If that ever changes, the allowlist is needlessly narrow.
  def test_api_still_rejects_non_mp4_containers
    skip "ffmpeg not available" unless ffmpeg?
    webm = ::File.join(@dir, "clip.webm")
    ok = system("ffmpeg -loglevel error -y -f lavfi -i testsrc=size=160x120:rate=8:duration=1 " \
                "-c:v libvpx-vp9 #{webm} > /dev/null 2>&1")
    skip "could not encode a WebM fixture" unless ok && ::File.exist?(webm)

    # Bypass the SDK allowlist to ask the API directly.
    Parse::Embeddings.allowed_video_types = %w[video/webm video/mp4]
    provider = build(model: "voyage-multimodal-3.5")
    assert_raises(Parse::Embeddings::Voyage::BadRequestError,
                  Parse::Embeddings::InvalidResponseError) do
      provider.embed_video([Parse::Embeddings::MediaFile.video(webm)])
    end
  end

  # ---- size limits ------------------------------------------------------

  # Pinned as documentation of the provider's stated cap; the adapter
  # refuses locally so no oversized upload is attempted.
  def test_adapter_refuses_media_over_the_documented_cap
    provider = build(model: "voyage-multimodal-3")
    oversized = Parse::Embeddings::ImageFetch::FetchedImage.new(
      bytes: "\x00" * (Parse::Embeddings::Voyage::MAX_MEDIA_BYTES + 1),
      mime_type: "image/png", url: nil,
    )
    assert_raises(Parse::Embeddings::Voyage::BadRequestError) do
      provider.embed_image([oversized])
    end
  end

  # ---- model availability -----------------------------------------------

  # ATLAS_UNAVAILABLE_MODELS drives a construction-time refusal, so a
  # model that quietly becomes available leaves callers blocked from a
  # working model. Raw HTTP again: every SDK constructor path refuses
  # these before a request, so only a direct call observes the API's
  # own verdict.
  def test_atlas_unavailable_models_are_still_unavailable
    skip "Atlas-only assertion" unless atlas_key?

    now_available = Parse::Embeddings::Voyage::ATLAS_UNAVAILABLE_MODELS.select do |model|
      model_available?(model, "atlas-unavailable probe")
    end
    assert_empty now_available,
                 "ATLAS_UNAVAILABLE_MODELS lists models Atlas now serves: #{now_available.inspect}"
  end

  # The converse: every model the SDK does expose on Atlas must work,
  # or the availability list is over-permissive.
  def test_models_the_sdk_allows_on_atlas_are_actually_available
    skip "Atlas-only assertion" unless atlas_key?

    broken = contract_models.reject { |model| model_available?(model, "availability probe") }
    assert_empty broken, "models the SDK permits on Atlas but the API rejects: #{broken.inspect}"
  end

  # The inverse half of the availability contract. ATLAS_UNAVAILABLE_MODELS
  # asserts these are missing from ATLAS SPECIFICALLY — the SDK still
  # permits them against Voyage's own endpoint, and would be wrong to
  # block them if Voyage had dropped them too. Runs automatically the
  # first time a `pa-` key is supplied; skipped under an Atlas key
  # because that credential cannot reach Voyage's host at all.
  def test_atlas_unavailable_models_remain_available_on_voyage
    skip "needs a Voyage (pa-) key; an Atlas key cannot reach api.voyageai.com" if atlas_key?

    missing = Parse::Embeddings::Voyage::ATLAS_UNAVAILABLE_MODELS.reject do |model|
      model_available?(model, "voyage availability probe")
    end
    assert_empty missing,
                 "models kept out of ATLAS_UNAVAILABLE_MODELS' reach are gone from Voyage " \
                 "too: #{missing.inspect} — they should be removed from the SDK entirely " \
                 "rather than merely gated off Atlas."
  end

  # Routing's other half: a Voyage key must NOT authenticate against the
  # Atlas host, which is what makes the prefix inference safe.
  def test_voyage_key_is_rejected_by_the_atlas_host
    skip "needs a Voyage (pa-) key" if atlas_key?

    status, body = raw_post_to(Parse::Embeddings::Voyage::ATLAS_BASE_URL,
                               "embeddings", { model: "voyage-3.5", input: ["x"] })
    refute_equal 200, status,
                 "a Voyage key authenticated against the Atlas host; endpoint inference " \
                 "by key prefix would no longer be meaningful"
    assert_includes [401, 403], status, "expected an auth refusal, got #{status}: #{body["detail"]}"
  end

  private

  # One representative per contract-relevant family, kept small so a
  # nightly run stays cheap.
  def contract_models
    %w[voyage-3.5 voyage-4 voyage-code-3 voyage-multimodal-3]
  end

  def build(model:, **opts)
    Parse::Embeddings::Voyage.new(api_key: KEY, model: model, **opts)
  end

  def atlas_key?
    KEY.start_with?(Parse::Embeddings::Voyage::ATLAS_KEY_PREFIX)
  end

  def base_url
    atlas_key? ? Parse::Embeddings::Voyage::ATLAS_BASE_URL
               : Parse::Embeddings::Voyage::DEFAULT_BASE_URL
  end

  # Issue a request WITHOUT the SDK, so probes can observe the API's own
  # verdict on inputs the SDK's local guards would refuse first. A guard
  # asserted against itself proves nothing about the contract.
  # @return [Array(Integer, Hash)] HTTP status and parsed body.
  #   The status matters: a negative probe that accepts "any response
  #   without a data key" as proof of unavailability would false-pass on
  #   a 429 or a 500 and hide newly-added support.
  def raw_post(path, body)
    raw_post_to(base_url, path, body)
  end

  def raw_post_to(host_base, path, body)
    require "net/http"
    require "uri"
    uri = URI("#{host_base}/#{path}")
    http = Net::HTTP.new(uri.host, 443)
    http.use_ssl = true
    http.read_timeout = 120
    req = Net::HTTP::Post.new(uri.path,
                              "Authorization" => "Bearer #{KEY}",
                              "Content-Type" => "application/json")
    req.body = JSON.dump(body)
    res = http.request(req)
    parsed = begin
      JSON.parse(res.body.to_s)
    rescue JSON::ParserError
      { "detail" => "unparseable body: #{res.body.to_s[0, 200]}" }
    end
    [res.code.to_i, parsed]
  end

  # Fail loudly on infrastructure errors so they are never mistaken for
  # a contract verdict.
  def refute_infrastructure_failure(status, body, context)
    case status
    when 401, 403
      flunk "#{context}: authentication failed (#{status}) — cannot judge the contract. #{body["detail"]}"
    when 429
      flunk "#{context}: rate limited (429) — rerun. #{body["detail"]}"
    when 500..599
      flunk "#{context}: server error (#{status}) — cannot judge the contract. #{body["detail"]}"
    end
  end

  # A model is available iff the API answered 200 with data. Anything
  # else is either a genuine refusal (4xx with a model error) or an
  # infrastructure failure, which flunks rather than counting as either.
  def model_available?(model, context)
    status, body = probe_model(model)
    refute_infrastructure_failure(status, body, "#{context} (#{model})")
    status == 200 && body.key?("data")
  end

  # Minimal availability probe for a model, routed to whichever
  # endpoint serves it — multimodal models are not served by
  # `/embeddings` and would look "unavailable" if probed there.
  def probe_model(model)
    if Parse::Embeddings::Voyage::MULTIMODAL_MODELS.include?(model)
      raw_post("multimodalembeddings",
               { model: model, input_type: "document",
                 inputs: [{ content: [{ type: "text", text: "x" }] }] })
    else
      raw_post("embeddings", { model: model, input: ["x"] })
    end
  end

  def data_uri(path, mime)
    "data:#{mime};base64,#{Base64.strict_encode64(::File.binread(path))}"
  end

  def ffmpeg?
    system("which ffmpeg > /dev/null 2>&1")
  end

  def write_png
    path = ::File.join(@dir, "img.png")
    ::File.binwrite(path, Base64.decode64(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    ))
    path
  end

  def write_mp4
    path = ::File.join(@dir, "clip.mp4")
    system("ffmpeg -loglevel error -y -f lavfi -i testsrc=size=160x120:rate=8:duration=1 " \
           "-pix_fmt yuv420p #{path} > /dev/null 2>&1")
    path
  end
end
