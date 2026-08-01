# encoding: UTF-8
# frozen_string_literal: true

require "faraday"
require "json"
require "uri"
require_relative "provider"

module Parse
  module Embeddings
    # Voyage AI embeddings provider. Wraps `POST /v1/embeddings` for
    # text-only models and `POST /v1/multimodalembeddings` for the
    # multimodal text+image models (text via {#embed_text}, images via
    # {#embed_image}).
    #
    # Supported models:
    #
    # * **v4 family** — `voyage-4-large`, `voyage-4`, `voyage-4-lite`,
    #   `voyage-4-nano` (Apache 2.0, open-weight on Hugging Face — also
    #   runnable through {LocalHTTP} when self-hosted on vLLM / Ollama /
    #   llama.cpp).
    # * **v3 family** — `voyage-3-large`, `voyage-3.5`,
    #   `voyage-3.5-lite`, `voyage-3`, `voyage-3-lite`.
    # * **code models** — `voyage-code-3`, `voyage-code-2` (1536-dim).
    # * **domain models** — `voyage-finance-2`, `voyage-law-2`.
    # * **multimodal** — `voyage-multimodal-3` (text+image) and
    #   `voyage-multimodal-3.5` (text+image+video). Unified vector
    #   space at the network boundary: text routes to
    #   `/v1/multimodalembeddings` with a `{ inputs: [{ content:
    #   [{ type: "text", text: … }] }] }` envelope, images go through
    #   {#embed_image}, video through {#embed_video}. All three share
    #   the same space, so stored text vectors are comparable against
    #   image and video vectors without re-embedding.
    #
    # Audio is not offered by any Voyage model, and neither PDF nor
    # DOCX is accepted as a content type — render document pages to
    # images and embed those instead.
    #
    # Most models expose a Matryoshka ladder
    # ({MODEL_SUPPORTED_DIMENSIONS}); note that the whole v4 family
    # DEFAULTS to 1024 and reaches 2048 or 256 only when `dimensions:`
    # asks for it.
    #
    # == Endpoints
    #
    # The same models are served by Voyage's own API and by MongoDB's
    # Atlas Embedding and Reranking API. The wire contract is
    # identical; the credentials are not interchangeable, and Voyage
    # returns a 403 explaining as much if they are crossed. An Atlas
    # model API key is recognized by its {ATLAS_KEY_PREFIX} and routes
    # to {ATLAS_BASE_URL} automatically — pass `endpoint:` to be
    # explicit. A few older models are absent from Atlas; see
    # {ATLAS_UNAVAILABLE_MODELS}.
    #
    # == Memory
    #
    # Local images and video should be wrapped with
    # {Parse::Embeddings::MediaFile}, which streams the file into the
    # request body {StreamingBody::READ_CHUNK} bytes at a time. Passing
    # a URL instead keeps the SDK out of the transfer entirely — the
    # provider does the fetch. Only {ImageFetch::FetchedImage} holds a
    # payload in memory, so prefer it for small images only.
    #
    # @example registration
    #   Parse::Embeddings.register(:voyage,
    #     Parse::Embeddings::Voyage.new(
    #       api_key: ENV.fetch("VOYAGE_API_KEY"),
    #       model:   "voyage-3.5",
    #     ))
    #
    # @example Atlas model API key (endpoint inferred from the prefix)
    #   Parse::Embeddings.register(:voyage,
    #     Parse::Embeddings::Voyage.new(
    #       api_key: ENV.fetch("ATLAS_MODEL_API_KEY"),  # "al-…"
    #       model:   "voyage-multimodal-3.5",
    #     ))
    #
    # @example streaming local media
    #   provider.embed_image([Parse::Embeddings::MediaFile.image("page.png")])
    #   provider.embed_video([Parse::Embeddings::MediaFile.video("demo.mp4")])
    #
    # == Asymmetric input types
    #
    # Voyage's `input_type` field accepts `"query"` or `"document"`
    # (mapped from the SDK-canonical `:search_query` / `:search_document`
    # Symbols). The values are functionally analogous to Cohere's
    # `search_query` / `search_document` — they're encoded by separately
    # tuned heads, so re-using one type for both sides of a retrieval
    # pair measurably degrades recall.
    #
    # Voyage also accepts `null` (omit the field), which Voyage's docs
    # recommend for "general purpose" embeddings unrelated to retrieval.
    # We translate the absent / non-retrieval cases to `null` rather
    # than picking a default — Voyage's training depends on the
    # asymmetry, so guessing on the caller's behalf would be worse than
    # passing-through.
    #
    # == Security
    #
    # * The Faraday connection refuses `proxy:` unless the caller opts
    #   in via `allow_faraday_proxy: true`. Env-proxy autodiscovery
    #   (`HTTPS_PROXY` etc.) is suppressed by default.
    # * `#inspect` (inherited from {Provider}) never surfaces `@api_key`.
    # * `Authorization` and `Voyage-Api-Key` are in
    #   {Parse::Middleware::BodyBuilder::REDACTED_HEADERS}.
    class Voyage < Provider
      class AuthenticationError < Error; end
      class BadRequestError < Error; end
      class RateLimitError < Error; end
      class TransientError < Error; end

      DEFAULT_BASE_URL = "https://api.voyageai.com/v1"
      # MongoDB's Atlas Embedding and Reranking API re-exposes the same
      # Voyage models under a MongoDB-operated host. The wire contract
      # (request envelopes, response envelopes, error shapes) is
      # identical — only the host and the credential differ.
      ATLAS_BASE_URL = "https://ai.mongodb.com/v1"
      # Bumped from `voyage-3` in 5.6.0: that model is retired from the
      # Atlas endpoint, so an Atlas key used without naming a model
      # failed at construction. `voyage-3.5` is served by both
      # endpoints and shares the 1024 native width.
      DEFAULT_MODEL = "voyage-3.5"
      DEFAULT_TIMEOUT = 30
      DEFAULT_OPEN_TIMEOUT = 5
      DEFAULT_MAX_RETRIES = 3
      # Voyage's documented per-request cap is 128 inputs.
      DEFAULT_BATCH_SIZE = 128
      MAX_RESPONSE_BYTES = 16 * 1024 * 1024

      # Default (native) vector width per model — the width returned
      # when `output_dimension` is omitted from the request.
      #
      # NOTE: the whole v4 family defaults to 1024, NOT to a
      # per-tier width. `voyage-4-large` reaches 2048 and
      # `voyage-4-lite` reaches 512 only by explicitly requesting them
      # via `output_dimension` (the constructor's `dimensions:`
      # override) — those are Matryoshka options, not native widths.
      # Verified against the live API for every model reachable
      # through {ATLAS_BASE_URL}; see {MODEL_SUPPORTED_DIMENSIONS}.
      MODEL_DEFAULT_DIMENSIONS = {
        "voyage-4-large" => 1024,
        "voyage-4" => 1024,
        "voyage-4-lite" => 1024,
        "voyage-4-nano" => 1024,
        "voyage-3-large" => 1024,
        "voyage-3.5" => 1024,
        "voyage-3.5-lite" => 1024,
        "voyage-3" => 1024,
        "voyage-3-lite" => 512,
        "voyage-code-3" => 1024,
        "voyage-code-2" => 1536,
        "voyage-finance-2" => 1024,
        "voyage-law-2" => 1024,
        "voyage-multimodal-3" => 1024,
        "voyage-multimodal-3.5" => 1024,
      }.freeze

      # Every width a model's Matryoshka head will actually return.
      # A model whose list has a single entry accepts no
      # `output_dimension` override at all — requesting one is a 400.
      #
      # This replaces the older "Matryoshka-capable models" boolean
      # gate, which was too coarse: the v4 family, `voyage-3-large`,
      # the v3.5 family, and `voyage-code-3` all accept the full
      # 256/512/1024/2048 ladder, and `voyage-multimodal-3.5` accepts
      # it too while `voyage-multimodal-3` does not.
      MODEL_SUPPORTED_DIMENSIONS = {
        "voyage-4-large" => [256, 512, 1024, 2048],
        "voyage-4" => [256, 512, 1024, 2048],
        "voyage-4-lite" => [256, 512, 1024, 2048],
        "voyage-4-nano" => [256, 512, 1024, 2048],
        "voyage-3-large" => [256, 512, 1024, 2048],
        "voyage-3.5" => [256, 512, 1024, 2048],
        "voyage-3.5-lite" => [256, 512, 1024, 2048],
        "voyage-3" => [1024],
        "voyage-3-lite" => [512],
        "voyage-code-3" => [256, 512, 1024, 2048],
        "voyage-code-2" => [1536],
        "voyage-finance-2" => [1024],
        "voyage-law-2" => [1024],
        "voyage-multimodal-3" => [1024],
        "voyage-multimodal-3.5" => [256, 512, 1024, 2048],
      }.freeze

      # Back-compat alias: the set of models accepting any
      # `output_dimension` other than their native width. Derived from
      # {MODEL_SUPPORTED_DIMENSIONS} rather than hand-maintained.
      MATRYOSHKA_MODELS =
        MODEL_SUPPORTED_DIMENSIONS.select { |_m, dims| dims.length > 1 }.keys.freeze

      MODEL_MAX_INPUT_TOKENS = {
        "voyage-4-large" => 32_000,
        "voyage-4" => 32_000,
        "voyage-4-lite" => 32_000,
        "voyage-4-nano" => 32_000,
        "voyage-3-large" => 32_000,
        "voyage-3.5" => 32_000,
        "voyage-3.5-lite" => 32_000,
        "voyage-3" => 32_000,
        "voyage-3-lite" => 32_000,
        "voyage-code-3" => 32_000,
        "voyage-code-2" => 16_000,
        "voyage-finance-2" => 32_000,
        "voyage-law-2" => 16_000,
        "voyage-multimodal-3" => 32_000,
        "voyage-multimodal-3.5" => 32_000,
      }.freeze

      # Models that route to `/v1/multimodalembeddings` with the
      # `{ inputs: [{ content: [...] }] }` envelope rather than the
      # standard `/v1/embeddings` `{ input: [String] }` envelope.
      # Text-only inputs from this provider are wrapped as
      # `{ type: "text", text: s }` content rows.
      MULTIMODAL_MODELS = %w[voyage-multimodal-3 voyage-multimodal-3.5].freeze

      # Voyage's documented hard ceiling for a single image or video.
      # {Parse::Embeddings.max_media_bytes} is a global convenience
      # knob that may be lowered for any reason — but raising it above
      # this cannot make Voyage accept a larger file, so the adapter
      # enforces its own limit independently.
      MAX_MEDIA_BYTES = 20 * 1024 * 1024

      # Multimodal models that additionally accept video content rows
      # (`video_url` / `video_base64`) via {#embed_video}.
      # `voyage-multimodal-3` rejects video with an explicit
      # "does not support video inputs" 400.
      VIDEO_MODELS = %w[voyage-multimodal-3.5].freeze

      # Models Voyage's hosted API serves but the Atlas Embedding and
      # Reranking API does not. Verified against both endpoints.
      ATLAS_UNAVAILABLE_MODELS = %w[voyage-3 voyage-3-lite].freeze

      # Open-weight models that NO hosted endpoint serves — neither
      # Voyage's nor Atlas's. `voyage-4-nano` ships under Apache 2.0 on
      # Hugging Face and is meant to be self-hosted (vLLM / Ollama /
      # llama.cpp), reached either through {LocalHTTP} or through this
      # provider with an explicit `base_url:` pointing at the local
      # server. Naming one against a hosted endpoint is always a
      # mistake, so it is refused there rather than failing as an
      # opaque provider 400.
      SELF_HOSTED_ONLY_MODELS = %w[voyage-4-nano].freeze

      # Atlas model API keys carry this prefix and authenticate ONLY
      # against {ATLAS_BASE_URL}; Voyage's own endpoint rejects them
      # with a 403. Used to infer the endpoint when the caller does
      # not name one explicitly.
      ATLAS_KEY_PREFIX = "al-"

      # Map SDK-canonical input_type symbols to Voyage wire strings.
      # `:classification` / `:clustering` map to `nil` (omitted) since
      # Voyage only distinguishes retrieval halves — other intents
      # should receive the unconditioned vector.
      INPUT_TYPE_WIRE_VALUES = {
        search_query: "query",
        search_document: "document",
        classification: nil,
        clustering: nil,
      }.freeze

      # @param api_key [String] required. Sent as `Authorization: Bearer …`.
      # @param model [String] one of {MODEL_DEFAULT_DIMENSIONS}'s keys.
      # @param endpoint [Symbol] `:auto` (default), `:voyage`, or
      #   `:atlas`. Selects the default `base_url` and enables
      #   endpoint-specific model validation. `:auto` infers `:atlas`
      #   when `api_key` carries the {ATLAS_KEY_PREFIX}, else
      #   `:voyage`. An explicit `base_url:` always wins; the endpoint
      #   is then inferred from its host.
      # @param base_url [String, nil] override. Must be HTTPS unless
      #   `allow_insecure_base_url: true`. Defaults to the resolved
      #   endpoint's host.
      # @param timeout [Integer] read timeout, seconds.
      # @param open_timeout [Integer] connect timeout, seconds.
      # @param max_retries [Integer] retry attempts on 429/5xx/timeouts.
      # @param embed_batch_size [Integer] inputs per request (max 128).
      # @param dimensions [Integer, nil] override output width via
      #   Voyage's `output_dimension` Matryoshka parameter. Only
      #   `voyage-4-large` accepts the field; for every other model the
      #   override must equal the native width or be omitted.
      # @param truncation [Boolean] forward Voyage's `truncation:` field.
      #   Defaults `true` to match Voyage's API default. Set `false` to
      #   force the API to reject over-length inputs rather than silently
      #   truncating (useful when you want explicit chunking errors).
      # @param allow_faraday_proxy [Boolean] opt in to proxy / env-proxy
      #   autodiscovery. Defaults `false`.
      # @param allow_insecure_base_url [Boolean] permit `http://` base.
      # @param connection [Faraday::Connection, nil] injection seam.
      def initialize(
        api_key:,
        model: DEFAULT_MODEL,
        endpoint: :auto,
        base_url: nil,
        timeout: DEFAULT_TIMEOUT,
        open_timeout: DEFAULT_OPEN_TIMEOUT,
        max_retries: DEFAULT_MAX_RETRIES,
        embed_batch_size: DEFAULT_BATCH_SIZE,
        dimensions: nil,
        truncation: true,
        allow_faraday_proxy: false,
        allow_insecure_base_url: false,
        connection: nil
      )
        validate_api_key!(api_key)
        validate_model!(model)
        resolved_endpoint = resolve_endpoint!(endpoint, api_key, base_url)
        base_url ||= resolved_endpoint == :atlas ? ATLAS_BASE_URL : DEFAULT_BASE_URL
        validate_model_for_endpoint!(model, resolved_endpoint)
        sanitized_base_url = validate_base_url!(base_url, allow_insecure_base_url)
        validate_positive_integer!(:timeout, timeout)
        validate_positive_integer!(:open_timeout, open_timeout)
        validate_non_negative_integer!(:max_retries, max_retries)
        validate_positive_integer!(:embed_batch_size, embed_batch_size)
        if embed_batch_size > 128
          raise ArgumentError,
                "Parse::Embeddings::Voyage: embed_batch_size #{embed_batch_size} exceeds Voyage's per-request cap (128)."
        end
        unless [true, false].include?(truncation)
          raise ArgumentError,
                "Parse::Embeddings::Voyage: truncation must be true or false (got #{truncation.inspect})."
        end
        validate_dimensions!(model, dimensions)

        @api_key = api_key
        @model = model
        @endpoint = resolved_endpoint
        @dimensions = dimensions || MODEL_DEFAULT_DIMENSIONS.fetch(model)
        @base_url = sanitized_base_url
        @timeout = timeout
        @open_timeout = open_timeout
        @max_retries = max_retries
        @embed_batch_size = embed_batch_size
        @truncation = truncation
        @allow_faraday_proxy = allow_faraday_proxy
        @connection = connection || build_connection
      end

      def dimensions
        @dimensions
      end

      def model_name
        @model
      end

      # @return [Symbol] `:atlas` when this provider targets MongoDB's
      #   Atlas Embedding and Reranking API, `:voyage` when it targets
      #   Voyage's own API, `:custom` for any other host.
      def endpoint
        @endpoint
      end

      # @return [Boolean] true when routed through {ATLAS_BASE_URL}.
      def atlas?
        @endpoint == :atlas
      end

      def embed_batch_size
        @embed_batch_size
      end

      def max_input_tokens
        MODEL_MAX_INPUT_TOKENS[@model]
      end

      def normalize?
        # Voyage's v3 embeddings are documented unit-normalized.
        true
      end

      def supports_input_type?
        true
      end

      # @param strings [Array<String>] inputs.
      # @param input_type [Symbol] one of {INPUT_TYPE_WIRE_VALUES}'s keys.
      # @return [Array<Array<Float>>] vectors aligned 1:1 with `strings`.
      def embed_text(strings, input_type: :search_document)
        unless strings.is_a?(Array)
          raise ArgumentError,
                "Parse::Embeddings::Voyage#embed_text expects Array<String> (got #{strings.class})."
        end
        return [] if strings.empty?
        strings.each_with_index do |s, i|
          unless s.is_a?(String)
            raise ArgumentError,
                  "Parse::Embeddings::Voyage#embed_text strings[#{i}] is not a String (#{s.class})."
          end
          if s.empty?
            raise ArgumentError,
                  "Parse::Embeddings::Voyage#embed_text strings[#{i}] is empty; Voyage rejects empty inputs."
          end
        end
        unless INPUT_TYPE_WIRE_VALUES.key?(input_type)
          raise ArgumentError,
                "Parse::Embeddings::Voyage#embed_text input_type #{input_type.inspect} not in " \
                "#{INPUT_TYPE_WIRE_VALUES.keys.inspect}."
        end
        wire_input_type = INPUT_TYPE_WIRE_VALUES[input_type]

        # Multimodal models route to a different endpoint with a
        # different request envelope. The response envelope shape is
        # the same (`{ data: [{ embedding, index }], usage: {...} }`)
        # so `extract_vectors!` is reused as-is.
        body = if MULTIMODAL_MODELS.include?(@model)
            build_multimodal_body(strings, wire_input_type)
          else
            build_text_body(strings, wire_input_type)
          end

        path = MULTIMODAL_MODELS.include?(@model) ? "multimodalembeddings" : "embeddings"

        instrument_embed(strings.length, input_type) do |emit_payload|
          payload = post_embeddings(body, path: path)
          # Voyage's response carries `usage: { total_tokens }`.
          if payload.is_a?(Hash) && payload["usage"].is_a?(Hash)
            tt = payload["usage"]["total_tokens"]
            emit_payload[:total_tokens] = tt if tt.is_a?(Integer) && tt >= 0
          end
          vectors = extract_vectors!(payload, strings.length)
          validate_response!(strings.length, vectors)
        end
      end

      # @return [Array<Symbol>] `[:text, :image, :video]` for
      #   `voyage-multimodal-3.5`, `[:text, :image]` for
      #   `voyage-multimodal-3`, and `[:text]` for text-only models.
      #   Audio is not offered by any Voyage model.
      def modalities
        return [:text] unless MULTIMODAL_MODELS.include?(@model)
        VIDEO_MODELS.include?(@model) ? %i[text image video] : %i[text image]
      end

      # Embed a batch of images through Voyage's
      # `/v1/multimodalembeddings` endpoint. Two source forms:
      #
      # * **String URL** (v5.1 path) — the provider receives a public
      #   URL and issues its own fetch. The SDK does NOT download the
      #   image; it validates the URL through
      #   {Parse::Embeddings.validate_image_url!} (CIDR / port / host
      #   allowlist, sentinel-gated egress opt-in) and forwards the
      #   canonicalized URL string in a `{ type: "image_url",
      #   image_url: ... }` content row.
      # * **{Parse::Embeddings::ImageFetch::FetchedImage}** (v5.5 bytes
      #   path) — bytes the SDK already downloaded through
      #   {Parse::File.safe_open_url}, magic-byte-verified, and
      #   EXIF-stripped. Forwarded as a `{ type: "image_base64",
      #   image_base64: "data:<mime>;base64,..." }` content row. No URL
      #   validation runs (there is no provider-side fetch) and the
      #   `trust_provider_url_fetch` sentinel is NOT required.
      #
      # **Multimodal model required.** Voyage's text-only models
      # (`voyage-3`, `voyage-4`, etc.) do not accept image inputs;
      # calling `embed_image` on a provider configured with one of
      # those raises {BadRequestError} before any network call.
      #
      # @param sources [Array<String, Parse::Embeddings::ImageFetch::FetchedImage>]
      #   image URLs and/or fetched-bytes wrappers (forms may be
      #   mixed). Each URL must satisfy
      #   {Parse::Embeddings.validate_image_url!} — failing entries
      #   raise the corresponding {Parse::Embeddings::InvalidImageURL}
      #   / {Parse::Embeddings::ConfirmationRequired} and ABORT the
      #   whole batch (no partial forwarding).
      # @param input_type [Symbol] one of {INPUT_TYPE_WIRE_VALUES}'s
      #   keys; mapped to Voyage's `input_type` field. Defaults to
      #   `:search_document`.
      # @param allow_insecure [Boolean] forwarded to the URL
      #   validator; permit `http://` for local-dev CDN proxies.
      # @return [Array<Array<Float>>] vectors aligned 1:1 with `sources`.
      def embed_image(sources, input_type: :search_document, allow_insecure: false)
        embed_media(sources, kind: :image, input_type: input_type,
                             allow_insecure: allow_insecure)
      end

      # Embed a batch of videos through
      # `/v1/multimodalembeddings`. Mirrors {#embed_image}'s source
      # forms and security posture exactly:
      #
      # * **String URL** — forwarded as a `{ type: "video_url",
      #   video_url: … }` content row after
      #   {Parse::Embeddings.validate_image_url!} canonicalizes and
      #   screens it. The provider issues the fetch, so the
      #   `trust_provider_url_fetch` sentinel IS required and the SDK
      #   never downloads the video.
      # * **{Parse::Embeddings::MediaFile}** — a local file, streamed
      #   into the request body as a `{ type: "video_base64",
      #   video_base64: "data:…" }` row without ever being held in
      #   memory. No URL validation and no sentinel, because nothing is
      #   fetched.
      #
      # **Video-capable model required.** Only {VIDEO_MODELS} accept
      # video; `voyage-multimodal-3` rejects it server-side, so this
      # raises {BadRequestError} before any network call.
      #
      # @param sources [Array<String, Parse::Embeddings::MediaFile>]
      #   video URLs and/or file-backed wrappers (forms may be mixed).
      # @param input_type [Symbol] one of {INPUT_TYPE_WIRE_VALUES}'s keys.
      # @param allow_insecure [Boolean] forwarded to the URL validator.
      # @return [Array<Array<Float>>] vectors aligned 1:1 with `sources`.
      def embed_video(sources, input_type: :search_document, allow_insecure: false)
        embed_media(sources, kind: :video, input_type: input_type,
                             allow_insecure: allow_insecure)
      end

      def inspect_attrs
        super.merge(base: safe_base_host, endpoint: @endpoint, retries: @max_retries)
      end

      protected

      def build_connection
        headers = {
          "Authorization" => "Bearer #{@api_key}",
          "Content-Type" => "application/json",
          "Accept" => "application/json",
          "User-Agent" => "parse-stack-embeddings/#{user_agent_version}",
        }

        faraday_opts = { url: @base_url, headers: headers }
        faraday_opts[:proxy] = nil unless @allow_faraday_proxy

        conn = Faraday.new(**faraday_opts) do |f|
          f.options.timeout = @timeout
          f.options.open_timeout = @open_timeout
          f.adapter Faraday.default_adapter
        end
        conn.proxy = nil if !@allow_faraday_proxy && conn.respond_to?(:proxy=)
        conn
      end

      # Build the wire body for the standard `/v1/embeddings` endpoint
      # (text-only models).
      def build_text_body(strings, wire_input_type)
        body = {
          input: strings,
          model: @model,
          truncation: @truncation,
        }
        # Only forward input_type when it has a wire value. Voyage
        # treats absent and `null` identically (unconditioned head),
        # but absent is the spec-correct form for non-retrieval intent.
        body[:input_type] = wire_input_type if wire_input_type
        apply_output_dimension!(body)
        body
      end

      # Build the wire body for `/v1/multimodalembeddings` for TEXT
      # inputs: each string wraps as a single `{type: "text", text:}`
      # content row. Image inputs build their content rows inline in
      # {#embed_image} (`image_url` / `image_base64`) and do not pass
      # through here.
      def build_multimodal_body(strings, wire_input_type)
        body = {
          inputs: strings.map { |s| { content: [{ type: "text", text: s }] } },
          model: @model,
        }
        body[:input_type] = wire_input_type if wire_input_type
        # `truncation` is documented for the multimodal endpoint too —
        # forward it for parity with the text path so callers get the
        # same fail-on-overlength behavior across models.
        body[:truncation] = @truncation
        apply_output_dimension!(body)
        body
      end

      # Forward `output_dimension` only when the configured width
      # differs from the model's native default. Sending it to a model
      # with a single supported width is a 400, and sending the native
      # width needlessly is redundant — so both are omitted.
      #
      # The constructor has already rejected any width outside
      # {MODEL_SUPPORTED_DIMENSIONS}, so no re-validation is needed.
      def apply_output_dimension!(body)
        return body if @dimensions == MODEL_DEFAULT_DIMENSIONS.fetch(@model)
        body[:output_dimension] = @dimensions
        body
      end

      # Everything modality-specific about a non-text input, in one
      # table. `models` names the constant gating which models accept
      # the modality; `url` / `base64` are the wire content-type keys.
      #
      # Adding a modality (audio, when Voyage ships it) is a row here
      # plus a {Parse::Embeddings::MediaFile} constructor and a
      # one-line `embed_audio` delegating to {#embed_media} — the
      # streaming body, row builder, batching, URL validation, and
      # instrumentation are all modality-agnostic already.
      MEDIA_MODALITIES = {
        image: { url: "image_url", base64: "image_base64",
                 models: :MULTIMODAL_MODELS, noun: "image" },
        video: { url: "video_url", base64: "video_base64",
                 models: :VIDEO_MODELS, noun: "video" },
      }.freeze

      # Shared implementation behind {#embed_image} and {#embed_video}.
      #
      # @param kind [Symbol] a {MEDIA_MODALITIES} key.
      # @return [Array<Array<Float>>] vectors aligned 1:1 with `sources`.
      def embed_media(sources, kind:, input_type:, allow_insecure:)
        spec = MEDIA_MODALITIES.fetch(kind)
        capable = self.class.const_get(spec[:models])
        caller_name = "embed_#{kind}"

        unless capable.include?(@model)
          raise BadRequestError,
                "Parse::Embeddings::Voyage##{caller_name}: model #{@model.inspect} does not " \
                "accept #{spec[:noun]} inputs. Configure the provider with a capable model " \
                "(supported: #{capable.inspect})."
        end
        unless sources.is_a?(Array)
          raise ArgumentError,
                "Parse::Embeddings::Voyage##{caller_name} expects Array of #{spec[:noun]} " \
                "URLs (got #{sources.class})."
        end
        return [] if sources.empty?

        unless INPUT_TYPE_WIRE_VALUES.key?(input_type)
          raise ArgumentError,
                "Parse::Embeddings::Voyage##{caller_name} input_type #{input_type.inspect} " \
                "not in #{INPUT_TYPE_WIRE_VALUES.keys.inspect}."
        end
        # Voyage caps multimodal requests at the same per-request size
        # as the text endpoint. The text path chunks automatically; the
        # media path has no chunker (every directive is a single
        # source), so guard the direct-API caller against a silent 400.
        if sources.length > @embed_batch_size
          raise ArgumentError,
                "Parse::Embeddings::Voyage##{caller_name}: batch size #{sources.length} " \
                "exceeds the configured cap #{@embed_batch_size} (Voyage per-request max: " \
                "128). Split the input and call #{caller_name} once per chunk."
        end

        rows = build_media_rows(
          sources, kind: kind, allow_insecure: allow_insecure, caller_name: caller_name,
        )
        wire_input_type = INPUT_TYPE_WIRE_VALUES[input_type]

        # Voyage requires a single representation per request: "each
        # request should use either image_base64/video_base64 or
        # image_url/video_url exclusively, not both." A mixed batch is
        # therefore split into one request per representation and
        # reassembled in the caller's original order, so the 1:1
        # alignment this method promises still holds.
        groups = rows.each_with_index.group_by { |row, _i| row_representation(row) }
        return dispatch_media(rows, input_type, wire_input_type, kind) if groups.size == 1

        results = Array.new(rows.length)
        groups.each_value do |pairs|
          subset = pairs.map(&:first)
          vectors = dispatch_media(subset, input_type, wire_input_type, kind)
          pairs.each_with_index { |(_row, original_index), n| results[original_index] = vectors[n] }
        end
        results
      end

      # Issue one multimodal request for a set of same-representation
      # rows and return the vectors in row order.
      def dispatch_media(rows, input_type, wire_input_type, kind)
        body = build_request_body(rows, wire_input_type)

        instrument_embed(rows.length, input_type, modality: kind) do |emit_payload|
          payload = post_embeddings(body, path: "multimodalembeddings")
          if payload.is_a?(Hash) && payload["usage"].is_a?(Hash)
            tt = payload["usage"]["total_tokens"]
            emit_payload[:total_tokens] = tt if tt.is_a?(Integer) && tt >= 0
          end
          vectors = extract_vectors!(payload, rows.length)
          validate_response!(rows.length, vectors)
        end
      end

      # Build `inputs[].content[]` row descriptors for a batch of media
      # sources, accepting URL Strings, in-memory
      # {ImageFetch::FetchedImage} wrappers, and file-backed
      # {MediaFile} wrappers.
      #
      # Every URL is validated up-front so a malformed entry in slot N
      # cannot get past validation while slots 0..N-1 are already in
      # the wire body — no partial forwarding.
      #
      # Returns descriptors rather than finished Hashes so
      # {#build_request_body} can assemble the JSON structurally. A
      # streamed row is `{ stream: MediaFile, key: String }`; every
      # other row is a ready-to-serialize Hash.
      #
      # @return [Array<Hash>] one descriptor per source, in order.
      def build_media_rows(sources, kind:, allow_insecure:, caller_name:)
        spec = MEDIA_MODALITIES.fetch(kind)
        url_key = spec[:url]
        b64_key = spec[:base64]

        sources.each_with_index.map do |src, i|
          case src
          when Parse::Embeddings::MediaFile
            unless src.kind == kind
              raise ArgumentError,
                    "Parse::Embeddings::Voyage##{caller_name} sources[#{i}] is a " \
                    "#{src.kind} MediaFile; expected #{kind}."
            end
            enforce_media_size!(src.byte_size, i, caller_name, src.path)
            { stream: src, key: b64_key }
          when Parse::Embeddings::ImageFetch::FetchedImage
            # The only in-memory wrapper the SDK ships is for images.
            unless kind == :image
              raise ArgumentError,
                    "Parse::Embeddings::Voyage##{caller_name} sources[#{i}] is a FetchedImage; " \
                    "wrap #{spec[:noun]} sources with Parse::Embeddings::MediaFile.#{kind}."
            end
            enforce_media_size!(src.bytes.bytesize, i, caller_name)
            { content: [{ type: b64_key, b64_key => src.to_data_uri }] }
          when String
            canonical = Parse::Embeddings.validate_image_url!(src, allow_insecure: allow_insecure)
            { content: [{ type: url_key, url_key => canonical }] }
          else
            raise ArgumentError,
                  "Parse::Embeddings::Voyage##{caller_name} sources[#{i}] must be a URL String " \
                  "or a Parse::Embeddings::MediaFile (got #{src.class})."
          end
        end
      end

      # Refuse a payload Voyage will reject anyway. Enforced here
      # rather than relying on {Parse::Embeddings.max_media_bytes},
      # which callers may legitimately raise for other providers.
      def enforce_media_size!(bytes, index, caller_name, path = nil)
        return if bytes <= MAX_MEDIA_BYTES

        where = path ? " (#{path})" : ""
        raise BadRequestError,
              "Parse::Embeddings::Voyage##{caller_name} sources[#{index}]#{where} is " \
              "#{bytes} bytes, over Voyage's #{MAX_MEDIA_BYTES}-byte per-file limit. " \
              "Downscale or re-encode before embedding."
      end

      # Which wire representation a row descriptor uses. Voyage
      # requires a single representation per request, so this is what
      # {#embed_media} partitions on.
      def row_representation(row)
        return :base64 if row[:stream]
        type = row.dig(:content, 0, :type).to_s
        type.end_with?("_base64") ? :base64 : :url
      end

      # Assemble the request body for a set of row descriptors.
      #
      # With no streamed rows this returns a plain Hash, serialized
      # later by {#post_embeddings}. With them it returns a
      # {StreamingBody} whose JSON is built **structurally** — each
      # fragment is serialized independently and concatenated in
      # order, so the file payloads are spliced by position rather than
      # by searching the serialized document.
      #
      # Building it structurally is a correctness requirement, not a
      # style preference: an earlier version emitted a sentinel token
      # and located it with `String#split`, which let a caller-supplied
      # URL containing that token capture a local file's bytes and ship
      # them to the provider as a URL to fetch.
      def build_request_body(rows, wire_input_type)
        trailer = { model: @model, truncation: @truncation }
        trailer[:input_type] = wire_input_type if wire_input_type
        apply_output_dimension!(trailer)

        return { inputs: rows }.merge(trailer) unless rows.any? { |r| r[:stream] }

        segments = [+'{"inputs":[']
        rows.each_with_index do |row, i|
          segments << "," if i.positive?
          if (media = row[:stream])
            key = row[:key]
            # Open the JSON string, emit the data: prefix, stream the
            # payload, then close it. Base64 needs no escaping, and the
            # prefix is escaped by #to_json before its closing quote is
            # trimmed.
            segments << %({"content":[{"type":#{key.to_json},#{key.to_json}:)
            segments << json_string_prefix(media.data_uri_prefix)
            segments << media.stream_segment
            segments << %("}]})
          else
            segments << row.to_json
          end
        end
        segments << "]"
        trailer.each { |k, v| segments << ",#{k.to_s.to_json}:#{v.to_json}" }
        segments << "}"

        Parse::Embeddings::StreamingBody.new(segments)
      end

      # A JSON string literal with its opening quote and escaped
      # contents but no closing quote, so a streamed payload can be
      # appended before the string is closed.
      def json_string_prefix(str)
        encoded = str.to_json
        encoded[0...-1]
      end

      def post_embeddings(body, path: "embeddings")
        attempts = 0
        loop do
          attempts += 1
          begin
            response = @connection.post(path) do |req|
              if body.is_a?(Parse::Embeddings::StreamingBody)
                # Faraday's net_http adapter routes an IO-shaped body
                # to Net::HTTP#body_stream. Rewind so a retry replays
                # from the start, and set Content-Length explicitly —
                # without it Net::HTTP falls back to chunked transfer
                # encoding, which some API gateways reject.
                body.rewind
                req.headers["Content-Length"] = body.size.to_s
                req.body = body
              else
                req.body = body.to_json
              end
            end
          rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
            if attempts > @max_retries
              raise TransientError, "Parse::Embeddings::Voyage: #{e.class} after #{attempts} attempt(s)."
            end
            sleep(backoff_seconds(attempts))
            next
          end

          status = response.status
          return parse_json_body!(response.body) if status >= 200 && status < 300

          if status == 401
            raise AuthenticationError,
                  "Parse::Embeddings::Voyage: 401 Unauthorized — check api_key."
          end
          if status == 429
            if attempts > @max_retries
              raise RateLimitError,
                    "Parse::Embeddings::Voyage: 429 rate limited after #{attempts} attempt(s)."
            end
            sleep(retry_after_seconds(response) || backoff_seconds(attempts))
            next
          end
          if status >= 500
            if attempts > @max_retries
              raise TransientError,
                    "Parse::Embeddings::Voyage: #{status} after #{attempts} attempt(s)."
            end
            sleep(backoff_seconds(attempts))
            next
          end
          raise BadRequestError,
                "Parse::Embeddings::Voyage: #{status} from POST /#{path}."
        end
      end

      def parse_json_body!(body)
        s = body.to_s
        if s.bytesize > MAX_RESPONSE_BYTES
          raise InvalidResponseError,
                "Parse::Embeddings::Voyage: response body exceeds #{MAX_RESPONSE_BYTES} bytes " \
                "(#{s.bytesize}). Refusing to parse."
        end
        JSON.parse(s, max_nesting: 32)
      rescue JSON::ParserError => e
        raise InvalidResponseError,
              "Parse::Embeddings::Voyage: response is not valid JSON (#{e.message})."
      end

      # Voyage's response shape mirrors OpenAI:
      #
      #   {
      #     "object": "list",
      #     "data": [
      #       { "object": "embedding", "embedding": [...], "index": 0 },
      #       ...
      #     ],
      #     "model": "voyage-3",
      #     "usage": { "total_tokens": N }
      #   }
      def extract_vectors!(payload, input_count)
        unless payload.is_a?(Hash)
          raise InvalidResponseError,
                "Parse::Embeddings::Voyage: response body is not a JSON object."
        end
        data = payload["data"]
        unless data.is_a?(Array)
          raise InvalidResponseError,
                "Parse::Embeddings::Voyage: response.data is not an Array."
        end
        if data.length != input_count
          raise InvalidResponseError,
                "Parse::Embeddings::Voyage: response.data.length #{data.length} != input count #{input_count}."
        end
        sorted = data.each_with_index.map do |entry, i|
          unless entry.is_a?(Hash)
            raise InvalidResponseError,
                  "Parse::Embeddings::Voyage: response.data[#{i}] is not a JSON object."
          end
          idx = entry["index"]
          unless idx.is_a?(Integer) && idx >= 0 && idx < input_count
            raise InvalidResponseError,
                  "Parse::Embeddings::Voyage: response.data[#{i}].index #{idx.inspect} out of range."
          end
          [idx, entry["embedding"]]
        end
        indices = sorted.map(&:first)
        if indices.uniq.length != indices.length
          raise InvalidResponseError,
                "Parse::Embeddings::Voyage: duplicate index in response.data."
        end
        sorted.sort_by(&:first).map(&:last)
      end

      def backoff_seconds(attempt)
        [0.5 * (2 ** (attempt - 1)), 30.0].min
      end

      def retry_after_seconds(response)
        ra = response.respond_to?(:headers) ? response.headers["retry-after"] || response.headers["Retry-After"] : nil
        return nil unless ra
        v = ra.to_f
        v.positive? ? [v, 60.0].min : nil
      end

      private

      def validate_api_key!(api_key)
        unless api_key.is_a?(String) && !api_key.empty?
          raise ArgumentError,
                "Parse::Embeddings::Voyage: api_key must be a non-empty String."
        end
      end

      def validate_model!(model)
        unless MODEL_DEFAULT_DIMENSIONS.key?(model)
          raise ArgumentError,
                "Parse::Embeddings::Voyage: unknown model #{model.inspect}. " \
                "Supported: #{MODEL_DEFAULT_DIMENSIONS.keys.inspect}."
        end
      end

      def validate_dimensions!(model, dimensions)
        return if dimensions.nil?
        unless dimensions.is_a?(Integer) && dimensions.positive?
          raise ArgumentError,
                "Parse::Embeddings::Voyage: dimensions must be a positive Integer (got #{dimensions.inspect})."
        end
        supported = MODEL_SUPPORTED_DIMENSIONS.fetch(model)
        return if supported.include?(dimensions)

        if supported.length == 1
          raise ArgumentError,
                "Parse::Embeddings::Voyage: model #{model.inspect} does not support custom dimensions " \
                "(only #{supported.first} is available)."
        end
        raise ArgumentError,
              "Parse::Embeddings::Voyage: dimensions #{dimensions} is not supported by #{model} " \
              "(supported: #{supported.inspect})."
      end

      # Resolve the target endpoint. An explicit `base_url:` always
      # wins — the endpoint is then inferred from its host so that
      # model validation still applies to a caller who points at Atlas
      # by URL rather than by name.
      def resolve_endpoint!(endpoint, api_key, base_url)
        unless %i[auto voyage atlas].include?(endpoint)
          raise ArgumentError,
                "Parse::Embeddings::Voyage: endpoint must be :auto, :voyage, or :atlas " \
                "(got #{endpoint.inspect})."
        end

        if base_url
          host = begin
              URI.parse(base_url).host
            rescue URI::InvalidURIError
              nil
            end
          inferred = case host
            when URI.parse(ATLAS_BASE_URL).host then :atlas
            when URI.parse(DEFAULT_BASE_URL).host then :voyage
            else :custom
            end
          # A named endpoint that contradicts the URL is a
          # configuration error, not something to silently reconcile.
          if endpoint != :auto && inferred != :custom && inferred != endpoint
            raise ArgumentError,
                  "Parse::Embeddings::Voyage: endpoint #{endpoint.inspect} contradicts " \
                  "base_url host #{host.inspect}. Pass one or the other."
          end
          return endpoint == :auto ? inferred : endpoint
        end

        return endpoint unless endpoint == :auto
        api_key.start_with?(ATLAS_KEY_PREFIX) ? :atlas : :voyage
      end

      def validate_model_for_endpoint!(model, endpoint)
        # A custom base_url may well point at a self-hosted server, so
        # only the two known hosted endpoints are policed.
        if %i[voyage atlas].include?(endpoint) && SELF_HOSTED_ONLY_MODELS.include?(model)
          raise ArgumentError,
                "Parse::Embeddings::Voyage: model #{model.inspect} is open-weight and is not " \
                "served by any hosted endpoint (neither #{DEFAULT_BASE_URL} nor " \
                "#{ATLAS_BASE_URL}). Self-host it and pass an explicit base_url:, or use " \
                "Parse::Embeddings::LocalHTTP."
        end

        return unless endpoint == :atlas
        return unless ATLAS_UNAVAILABLE_MODELS.include?(model)

        raise ArgumentError,
              "Parse::Embeddings::Voyage: model #{model.inspect} is not available on the Atlas " \
              "Embedding and Reranking API (#{ATLAS_BASE_URL}). Atlas-unavailable models: " \
              "#{ATLAS_UNAVAILABLE_MODELS.inspect}. Use a current model such as \"voyage-3.5\" " \
              "or \"voyage-4\", or target Voyage's own API with endpoint: :voyage."
      end

      def validate_base_url!(base_url, allow_insecure)
        unless base_url.is_a?(String) && !base_url.empty?
          raise ArgumentError,
                "Parse::Embeddings::Voyage: base_url must be a non-empty String."
        end
        begin
          uri = URI.parse(base_url)
        rescue URI::InvalidURIError => e
          raise ArgumentError,
                "Parse::Embeddings::Voyage: base_url is not a valid URL (#{e.message})."
        end
        unless %w[http https].include?(uri.scheme)
          raise ArgumentError,
                "Parse::Embeddings::Voyage: base_url must be http(s):// (got scheme #{uri.scheme.inspect})."
        end
        if uri.scheme == "http" && !allow_insecure
          raise ArgumentError,
                "Parse::Embeddings::Voyage: refusing http:// base_url. " \
                "Pass allow_insecure_base_url: true to opt in."
        end
        if uri.host.nil? || uri.host.empty?
          raise ArgumentError,
                "Parse::Embeddings::Voyage: base_url must include a host."
        end
        if uri.userinfo
          raise ArgumentError,
                "Parse::Embeddings::Voyage: base_url must not contain userinfo (credentials). " \
                "Use the api_key parameter and a clean URL."
        end
        uri.to_s
      end

      def validate_positive_integer!(name, value)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError,
                "Parse::Embeddings::Voyage: #{name} must be a positive Integer (got #{value.inspect})."
        end
      end

      def validate_non_negative_integer!(name, value)
        unless value.is_a?(Integer) && value >= 0
          raise ArgumentError,
                "Parse::Embeddings::Voyage: #{name} must be a non-negative Integer (got #{value.inspect})."
        end
      end

      def user_agent_version
        defined?(Parse::Stack::VERSION) ? Parse::Stack::VERSION : "unknown"
      end

      def safe_base_host
        uri = URI.parse(@base_url)
        host = uri.host
        host && !host.empty? ? "#{uri.scheme}://#{host}" : nil
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
