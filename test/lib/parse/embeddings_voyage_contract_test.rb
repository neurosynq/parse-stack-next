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

  # Trial and free-tier keys are rate limited aggressively — 3 requests
  # per minute per model is common. Without pacing, most of this suite
  # would skip as "rate limited, contract not determined", which is
  # honest but useless. Set VOYAGE_CONTRACT_RPM to the key's per-model
  # limit and the suite throttles itself to produce real verdicts.
  # Unset means no pacing, for keys with production quota.
  #
  # The budget is PER MODEL, so the clock is tracked per model and
  # probes against different models never wait on each other.
  RPM = ENV["VOYAGE_CONTRACT_RPM"].to_i
  MIN_INTERVAL = RPM.positive? ? 60.0 / RPM : 0.0

  @last_request_at = {}
  class << self
    attr_reader :last_request_at
  end

  def setup
    skip "set VOYAGE_CONTRACT_KEY to run live Voyage contract tests" if KEY.nil? || KEY.empty?
    Parse::Embeddings.reset!
    @dir = Dir.mktmpdir("psnext-contract")
  end

  # Wait out this model's rate limit before issuing a request. Called
  # immediately before every outbound call, including inside
  # multi-request probes.
  def pace!(model)
    return if MIN_INTERVAL.zero?

    now = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    if (last = self.class.last_request_at[model.to_s])
      wait = MIN_INTERVAL - (now.call - last)
      sleep(wait) if wait.positive?
    end
    self.class.last_request_at[model.to_s] = now.call
  end

  # An SDK-driven probe against a single model, paced and with
  # transient failures classified as "could not determine".
  def probe(model, context, &block)
    pace!(model)
    via_sdk(context, &block)
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

    probe("voyage-3.5", "routing probe") do
      assert_equal 1, provider.embed_text(["contract probe"]).length,
                   "routing is wrong if this 403s"
    end
  end

  # ---- dimensions -------------------------------------------------------

  # Every model's declared native width must match what the API returns
  # with no output_dimension requested.
  def test_declared_native_dimensions_match_the_live_api
    mismatches = []
    contract_models.each do |model|
      probe(model, "dimension probe (#{model})") do
        provider = build(model: model)
        actual = provider.embed_text(["d"]).first.length
        mismatches << "#{model}: declared #{provider.dimensions}, got #{actual}" if actual != provider.dimensions
      end
    end
    assert_empty mismatches, "native dimension table has drifted:\n  #{mismatches.join("\n  ")}"
  end

  # Each width on a model's Matryoshka ladder must actually be honored.
  def test_matryoshka_ladder_widths_are_honored
    model = "voyage-3.5"
    supported = Parse::Embeddings::Voyage::MODEL_SUPPORTED_DIMENSIONS.fetch(model)
    supported.each do |width|
      probe(model, "matryoshka probe (#{width})") do
        actual = build(model: model, dimensions: width).embed_text(["m"]).first.length
        assert_equal width, actual, "#{model} did not honor output_dimension #{width}"
      end
    end
  end

  # ---- response shape ---------------------------------------------------

  def test_response_envelope_shape_is_stable
    provider = build(model: "voyage-3.5")
    vectors = probe("voyage-3.5", "envelope probe") { provider.embed_text(%w[alpha beta], input_type: :search_document) }
    assert_equal 2, vectors.length
    assert vectors.all? { |v| v.is_a?(Array) && v.all?(Float) }
    assert_equal vectors[0].length, vectors[1].length
    # Alignment is positional; distinct inputs must not collapse.
    refute_equal vectors[0], vectors[1]
  end

  def test_asymmetric_input_types_are_accepted
    provider = build(model: "voyage-3.5")
    q = probe("voyage-3.5", "input-type probe (query)") { provider.embed_text(["a query"], input_type: :search_query).first }
    d = probe("voyage-3.5", "input-type probe (document)") { provider.embed_text(["a document"], input_type: :search_document).first }
    assert_equal q.length, d.length
  end

  # ---- accepted media ---------------------------------------------------

  def test_multimodal_model_accepts_a_streamed_image
    provider = build(model: "voyage-multimodal-3")
    vectors = probe("voyage-multimodal-3", "image probe") { provider.embed_image([Parse::Embeddings::MediaFile.image(write_png)]) }
    assert_equal 1, vectors.length
    assert_equal provider.dimensions, vectors.first.length
  end

  def test_video_capable_model_accepts_a_streamed_mp4
    skip "ffmpeg not available" unless ffmpeg?
    provider = build(model: "voyage-multimodal-3.5")
    vectors = probe("voyage-multimodal-3.5", "video probe") { provider.embed_video([Parse::Embeddings::MediaFile.video(write_mp4)]) }
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
    # Deliberately not assert_raises: a RateLimitError would be reported
    # as an unexpected-exception FAILURE rather than reaching via_sdk's
    # "could not determine" skip.
    probe("voyage-multimodal-3.5", "webm rejection probe") do
      begin
        provider.embed_video([Parse::Embeddings::MediaFile.video(webm)])
        flunk "the API accepted a WebM payload — the MP4-only allowlist is too narrow"
      rescue Parse::Embeddings::Voyage::BadRequestError,
             Parse::Embeddings::InvalidResponseError
        # Expected: the container is refused.
      end
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
                 "ATLAS_UNAVAILABLE_MODELS means 'on Voyage but not Atlas'. These are gone " \
                 "from Voyage too: #{missing.inspect} — they belong in " \
                 "SELF_HOSTED_ONLY_MODELS or should be dropped entirely, not merely gated " \
                 "off Atlas."
  end

  # The complement: open-weight models must be absent from BOTH hosted
  # endpoints, or they are not self-host-only and the constant is wrong.
  def test_self_hosted_only_models_are_absent_from_the_hosted_api
    present = Parse::Embeddings::Voyage::SELF_HOSTED_ONLY_MODELS.select do |model|
      model_available?(model, "self-hosted-only probe")
    end
    assert_empty present,
                 "SELF_HOSTED_ONLY_MODELS are served by this hosted endpoint after all: " \
                 "#{present.inspect} — the constructor is refusing a usable model."
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

  # `max_retries: 0` when pacing is configured: the provider's backoff
  # (sub-second, then a couple of seconds) is far shorter than the
  # ~20s a 3-RPM budget needs, so retries never succeed and each one
  # silently spends another request the pacer has already accounted
  # for. Failing immediately lets the pacer do the waiting instead.
  def build(model:, **opts)
    defaults = MIN_INTERVAL.zero? ? {} : { max_retries: 0 }
    Parse::Embeddings::Voyage.new(api_key: KEY, model: model, **defaults.merge(opts))
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
    pace!(body[:model] || body["model"] || "unknown")
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

  # Classify infrastructure conditions so they are never mistaken for a
  # contract verdict — in either direction.
  #
  # A bad credential is a configuration error the operator must fix, so
  # it fails. Rate limiting and 5xx are transient and say nothing about
  # the contract, so they skip: failing there would cry wolf on a
  # low-quota key, and passing would hide real drift. A skip is the
  # honest "could not determine".
  def refute_infrastructure_failure(status, body, context)
    case status
    when 401, 403
      flunk "#{context}: authentication failed (#{status}) — check the key. #{body["detail"]}"
    when 429
      skip "#{context}: rate limited (429); contract not determined. #{body["detail"]}"
    when 500..599
      skip "#{context}: server error (#{status}); contract not determined. #{body["detail"]}"
    end
  end

  # Same classification for calls that go through the SDK, where a 429
  # surfaces as an exception after the provider's own retries rather
  # than as a status code.
  def via_sdk(context)
    yield
  rescue Parse::Embeddings::Voyage::RateLimitError => e
    skip "#{context}: rate limited; contract not determined. #{e.message}"
  rescue Parse::Embeddings::Voyage::TransientError => e
    skip "#{context}: transient provider failure; contract not determined. #{e.message}"
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
