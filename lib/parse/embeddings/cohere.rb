# encoding: UTF-8
# frozen_string_literal: true

require "faraday"
require "json"
require "uri"
require_relative "provider"

module Parse
  module Embeddings
    # Cohere embeddings provider. Wraps `POST /v1/embed`.
    #
    # Supported models:
    #
    # * **v4** — `embed-v4.0` (1536 native, Matryoshka {256, 512, 1024,
    #   1536}, 128k-token context). Unified text + image model at the
    #   network boundary. The text path uses Cohere's `/v1/embed`
    #   endpoint; the image path ({#embed_image}, v5.1+) uses the
    #   `/v2/embed` multimodal endpoint with OpenAI-style
    #   `{ type: "image_url", image_url: { url: ... } }` content rows.
    #   Text vectors stored today share the vector space with the
    #   eventual image vectors (no re-embed required when adding
    #   image-side data).
    # * **v3** — `embed-english-v3.0`, `embed-multilingual-v3.0` (both
    #   1024-dim), `embed-english-light-v3.0`,
    #   `embed-multilingual-light-v3.0` (both 384-dim). Text-only.
    #
    # @example registration
    #   Parse::Embeddings.register(:cohere,
    #     Parse::Embeddings::Cohere.new(
    #       api_key: ENV.fetch("COHERE_API_KEY"),
    #       model:   "embed-english-v3.0",
    #     ))
    #
    # == Asymmetric input types
    #
    # Cohere is one of the providers that DOES distinguish queries from
    # documents at the wire level via the `input_type` request field.
    # Sending `input_type: "search_query"` for a query and
    # `"search_document"` for a corpus item is required for good recall
    # on Cohere's v3 models — using the same type for both halves of a
    # retrieval pair degrades nDCG by a noticeable margin (Cohere's own
    # benchmarks). `Provider#supports_input_type?` returns `true` here
    # so callers / cache-keying middleware can branch on this.
    #
    # The accepted Symbol values map to the Cohere wire strings:
    #
    # * `:search_query`        → `"search_query"`
    # * `:search_document`     → `"search_document"`
    # * `:classification`      → `"classification"`
    # * `:clustering`          → `"clustering"`
    #
    # == Security
    #
    # * The Faraday connection refuses `proxy:` unless the caller opts
    #   in via `allow_faraday_proxy: true`. Env-proxy autodiscovery
    #   (`HTTPS_PROXY` etc.) is suppressed by default — same model as
    #   `Parse::Client` and {OpenAI}.
    # * `#inspect` (inherited from {Provider}) never surfaces `@api_key`.
    # * `Authorization` and `Cohere-Api-Key` are in
    #   {Parse::Middleware::BodyBuilder::REDACTED_HEADERS}.
    class Cohere < Provider
      # Per-provider error subclasses. Mirror OpenAI's split so retry
      # middleware can `rescue Parse::Embeddings::Cohere::RateLimitError`
      # without picking up unrelated providers.
      class AuthenticationError < Error; end
      class BadRequestError < Error; end
      class RateLimitError < Error; end
      class TransientError < Error; end

      DEFAULT_BASE_URL    = "https://api.cohere.com/v1"
      DEFAULT_MODEL       = "embed-english-v3.0"
      DEFAULT_TIMEOUT     = 30
      DEFAULT_OPEN_TIMEOUT = 5
      DEFAULT_MAX_RETRIES = 3
      # Cohere documents a hard cap of 96 inputs per `/embed` call.
      DEFAULT_BATCH_SIZE  = 96
      MAX_RESPONSE_BYTES  = 16 * 1024 * 1024

      MODEL_DEFAULT_DIMENSIONS = {
        "embed-v4.0"                     => 1536,
        "embed-english-v3.0"             => 1024,
        "embed-multilingual-v3.0"        => 1024,
        "embed-english-light-v3.0"       => 384,
        "embed-multilingual-light-v3.0"  => 384,
      }.freeze

      MODEL_MAX_INPUT_TOKENS = {
        "embed-v4.0"                     => 128_000,
        "embed-english-v3.0"             => 512,
        "embed-multilingual-v3.0"        => 512,
        "embed-english-light-v3.0"       => 512,
        "embed-multilingual-light-v3.0"  => 512,
      }.freeze

      # Models that accept Cohere's `output_dimension` Matryoshka
      # truncation parameter. v4.0 is the only such row today; v3
      # models reject the field with a 400.
      MATRYOSHKA_MODELS = %w[embed-v4.0].freeze

      # Models that accept image inputs via the `/v2/embed` multimodal
      # endpoint. Currently only `embed-v4.0` — v3 is text-only.
      MULTIMODAL_MODELS = %w[embed-v4.0].freeze

      # Allowed Matryoshka widths per model (Cohere quantizes the
      # available truncations rather than accepting any integer ≤
      # native). Empty allowlist = any integer ≤ native is fine, but
      # for v4.0 Cohere documents exactly these four widths.
      MATRYOSHKA_WIDTHS = {
        "embed-v4.0" => [256, 512, 1024, 1536].freeze,
      }.freeze

      # Map SDK-canonical input_type symbols to Cohere wire strings.
      # Symbols outside this set raise — silently downgrading
      # `:unknown_type` to `"search_document"` would mask cache-key
      # bugs in higher layers (the value participates in cache keys).
      INPUT_TYPE_WIRE_VALUES = {
        search_query:    "search_query",
        search_document: "search_document",
        classification:  "classification",
        clustering:      "clustering",
      }.freeze

      # @param api_key [String] required. Sent as `Authorization: Bearer …`.
      # @param model [String] one of {MODEL_DEFAULT_DIMENSIONS}'s keys.
      # @param base_url [String] override. Must be HTTPS unless
      #   `allow_insecure_base_url: true`.
      # @param timeout [Integer] read timeout, seconds.
      # @param open_timeout [Integer] connect timeout, seconds.
      # @param max_retries [Integer] retry attempts on 429/5xx/timeouts.
      # @param embed_batch_size [Integer] inputs per request (max 96).
      # @param allow_faraday_proxy [Boolean] opt in to proxy / env-proxy
      #   autodiscovery. Defaults `false`.
      # @param allow_insecure_base_url [Boolean] permit `http://` base
      #   (local proxies). Defaults `false`.
      # @param connection [Faraday::Connection, nil] injection seam for
      #   tests.
      def initialize(
        api_key:,
        model: DEFAULT_MODEL,
        dimensions: nil,
        base_url: DEFAULT_BASE_URL,
        timeout: DEFAULT_TIMEOUT,
        open_timeout: DEFAULT_OPEN_TIMEOUT,
        max_retries: DEFAULT_MAX_RETRIES,
        embed_batch_size: DEFAULT_BATCH_SIZE,
        allow_faraday_proxy: false,
        allow_insecure_base_url: false,
        connection: nil
      )
        validate_api_key!(api_key)
        validate_model!(model)
        validate_dimensions!(model, dimensions)
        sanitized_base_url = validate_base_url!(base_url, allow_insecure_base_url)
        validate_positive_integer!(:timeout, timeout)
        validate_positive_integer!(:open_timeout, open_timeout)
        validate_non_negative_integer!(:max_retries, max_retries)
        validate_positive_integer!(:embed_batch_size, embed_batch_size)
        if embed_batch_size > 96
          raise ArgumentError,
                "Parse::Embeddings::Cohere: embed_batch_size #{embed_batch_size} exceeds Cohere's per-request cap (96)."
        end

        @api_key = api_key
        @model = model
        @dimensions = dimensions || MODEL_DEFAULT_DIMENSIONS.fetch(model)
        @base_url = sanitized_base_url
        @timeout = timeout
        @open_timeout = open_timeout
        @max_retries = max_retries
        @embed_batch_size = embed_batch_size
        @allow_faraday_proxy = allow_faraday_proxy
        @connection = connection || build_connection
      end

      def dimensions
        @dimensions
      end

      def model_name
        @model
      end

      def embed_batch_size
        @embed_batch_size
      end

      def max_input_tokens
        MODEL_MAX_INPUT_TOKENS[@model]
      end

      def normalize?
        # Cohere v3 embeddings are documented unit-normalized.
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
                "Parse::Embeddings::Cohere#embed_text expects Array<String> (got #{strings.class})."
        end
        return [] if strings.empty?
        strings.each_with_index do |s, i|
          unless s.is_a?(String)
            raise ArgumentError,
                  "Parse::Embeddings::Cohere#embed_text strings[#{i}] is not a String (#{s.class})."
          end
          if s.empty?
            raise ArgumentError,
                  "Parse::Embeddings::Cohere#embed_text strings[#{i}] is empty; Cohere rejects empty inputs."
          end
        end
        wire_input_type = INPUT_TYPE_WIRE_VALUES[input_type]
        unless wire_input_type
          raise ArgumentError,
                "Parse::Embeddings::Cohere#embed_text input_type #{input_type.inspect} not in " \
                "#{INPUT_TYPE_WIRE_VALUES.keys.inspect}."
        end

        body = {
          texts: strings,
          model: @model,
          input_type: wire_input_type,
          embedding_types: ["float"],
        }
        # Forward `output_dimension` only for Matryoshka-capable models
        # whose active width differs from native. Sending it to a v3
        # row would yield a 400 from Cohere.
        if MATRYOSHKA_MODELS.include?(@model) &&
           @dimensions != MODEL_DEFAULT_DIMENSIONS.fetch(@model)
          body[:output_dimension] = @dimensions
        end

        instrument_embed(strings.length, input_type) do |emit_payload|
          payload = post_embeddings(body)
          # Cohere's response carries `meta.billed_units.input_tokens`
          # (and `output_tokens`, though for embeddings it's 0). Forward
          # input_tokens as the operator-facing cost number on the AS::N
          # payload so cost subscribers can budget across providers.
          if payload.is_a?(Hash) && payload["meta"].is_a?(Hash) &&
             payload["meta"]["billed_units"].is_a?(Hash)
            tt = payload["meta"]["billed_units"]["input_tokens"]
            emit_payload[:total_tokens] = tt if tt.is_a?(Integer) && tt >= 0
          end
          vectors = extract_vectors!(payload, strings.length)
          validate_response!(strings.length, vectors)
        end
      end

      # @return [Array<Symbol>] `[:text, :image]` for `embed-v4.0`,
      #   `[:text]` for v3 models.
      def modalities
        MULTIMODAL_MODELS.include?(@model) ? %i[text image] : [:text]
      end

      # Embed a batch of images through Cohere's `/v2/embed`
      # multimodal endpoint. Two source forms:
      #
      # * **String URL** (v5.1 path) — the provider receives a public
      #   URL and issues its own fetch. The SDK does NOT download the
      #   image; it validates the URL through
      #   {Parse::Embeddings.validate_image_url!} (sentinel-gated
      #   egress opt-in, CIDR / port / host allowlist) and forwards
      #   the canonicalized URL string in the `{ type: "image_url",
      #   image_url: { url: ... } }` content row.
      # * **{Parse::Embeddings::ImageFetch::FetchedImage}** (v5.5 bytes
      #   path) — bytes the SDK already downloaded through
      #   {Parse::File.safe_open_url}, magic-byte-verified, and
      #   EXIF-stripped. Forwarded as a base64 data URI in the same
      #   `image_url` content row (Cohere v2 accepts data URIs). No
      #   URL validation runs and the `trust_provider_url_fetch`
      #   sentinel is NOT required.
      #
      # **Multimodal model required.** Cohere's v3 models do not accept
      # image inputs; calling `embed_image` on a v3-configured provider
      # raises {BadRequestError} before any network call.
      #
      # **Wire shape differs from {Voyage#embed_image}.** Voyage uses
      # `{ type: "image_url", image_url: "<url>" }` (flat String); Cohere
      # v2 uses `{ type: "image_url", image_url: { url: "<url>" } }`
      # (nested object), matching the OpenAI chat-completions content
      # convention. The high-level SDK contract is identical — callers
      # pass an `Array<String>` of URLs.
      #
      # @param sources [Array<String>] image URLs. Each must satisfy
      #   {Parse::Embeddings.validate_image_url!}; failing entries
      #   abort the whole batch (no partial forwarding).
      # @param input_type [Symbol] one of {INPUT_TYPE_WIRE_VALUES}'s
      #   keys; mapped to Cohere's `input_type` field. Defaults to
      #   `:search_document`.
      # @param allow_insecure [Boolean] forwarded to the URL validator;
      #   permit `http://` for local-dev CDN proxies.
      # @return [Array<Array<Float>>] vectors aligned 1:1 with `sources`.
      def embed_image(sources, input_type: :search_document, allow_insecure: false)
        unless MULTIMODAL_MODELS.include?(@model)
          raise BadRequestError,
                "Parse::Embeddings::Cohere#embed_image: model #{@model.inspect} does not " \
                "accept image inputs. Configure the provider with a multimodal model " \
                "(supported: #{MULTIMODAL_MODELS.inspect})."
        end
        unless sources.is_a?(Array)
          raise ArgumentError,
                "Parse::Embeddings::Cohere#embed_image expects Array of image URLs " \
                "(got #{sources.class})."
        end
        return [] if sources.empty?

        wire_input_type = INPUT_TYPE_WIRE_VALUES[input_type]
        unless wire_input_type
          raise ArgumentError,
                "Parse::Embeddings::Cohere#embed_image input_type #{input_type.inspect} not in " \
                "#{INPUT_TYPE_WIRE_VALUES.keys.inspect}."
        end
        # Cohere caps `/v2/embed` at the same 96-input per-call limit
        # as `/v1/embed`. Guard direct-API callers against a silent
        # 400 — the DSL passes a single URL per directive.
        if sources.length > @embed_batch_size
          raise ArgumentError,
                "Parse::Embeddings::Cohere#embed_image: batch size #{sources.length} exceeds " \
                "the configured cap #{@embed_batch_size} (Cohere per-request max: 96). " \
                "Split the input and call embed_image once per chunk."
        end

        # Validate every URL up-front so a malformed entry in slot N
        # does not slip through after slots 0..N-1 are already in the
        # wire body. URL entries forward the validator's canonicalized
        # URL — not the caller's raw input; fetched-bytes entries skip
        # URL validation (already downloaded + verified by ImageFetch)
        # and forward as a base64 data URI.
        content_rows = sources.each_with_index.map do |src, i|
          if src.is_a?(Parse::Embeddings::ImageFetch::FetchedImage)
            { content: [{ type: "image_url", image_url: { url: src.to_data_uri } }] }
          elsif src.is_a?(String)
            canonical = Parse::Embeddings.validate_image_url!(src, allow_insecure: allow_insecure)
            { content: [{ type: "image_url", image_url: { url: canonical } }] }
          else
            raise ArgumentError,
                  "Parse::Embeddings::Cohere#embed_image sources[#{i}] must be a URL String " \
                  "or Parse::Embeddings::ImageFetch::FetchedImage (got #{src.class})."
          end
        end

        body = {
          model: @model,
          input_type: wire_input_type,
          embedding_types: ["float"],
          inputs: content_rows,
        }

        instrument_embed(sources.length, input_type, modality: :image) do |emit_payload|
          payload = post_embeddings(body, path: v2_embed_path)
          if payload.is_a?(Hash) && payload["meta"].is_a?(Hash) &&
             payload["meta"]["billed_units"].is_a?(Hash)
            tt = payload["meta"]["billed_units"]["input_tokens"]
            emit_payload[:total_tokens] = tt if tt.is_a?(Integer) && tt >= 0
          end
          vectors = extract_vectors!(payload, sources.length)
          validate_response!(sources.length, vectors)
        end
      end

      def inspect_attrs
        super.merge(base: safe_base_host, retries: @max_retries)
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

      # @api private
      # Compute the v2/embed path relative to the configured base_url's
      # path component. For the default base `https://api.cohere.com/v1`
      # this produces `/v2/embed`; for a custom-proxy base like
      # `https://corp-proxy.example.com/cohere/v1` it produces
      # `/cohere/v2/embed` — so the operator's proxy / egress-logging
      # / API-key custody layer is NOT silently bypassed by image
      # embedding calls. The substitution targets the trailing `/v1`
      # segment specifically; bases without that segment fall back to
      # appending `/v2/embed` to the host root with a warning so the
      # caller sees the asymmetry rather than discovering it via a
      # 404 from a misrouted request.
      def v2_embed_path
        uri = URI.parse(@base_url)
        path = uri.path.to_s
        if path =~ %r{/v1/?\z}i
          # Replace `/v1` (with optional trailing slash) with `/v2/embed`.
          path.sub(%r{/v1/?\z}i, "/v2/embed")
        else
          warn "[Parse::Embeddings::Cohere] base_url path #{path.inspect} does not end " \
               "in `/v1` — embed_image will POST to host-root `/v2/embed`, which may " \
               "bypass a configured proxy path. Configure base_url to end with `/v1`."
          "/v2/embed"
        end
      end

      # `path:` accepts either a Faraday-relative segment (default
      # `"embed"`, which resolves under the configured `/v1/` base) or
      # an absolute path (`"/v2/embed"`) for endpoints outside the
      # configured base — used by {#embed_image} to reach `/v2/embed`.
      def post_embeddings(body, path: "embed")
        attempts = 0
        loop do
          attempts += 1
          begin
            response = @connection.post(path) do |req|
              req.body = body.to_json
            end
          rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
            if attempts > @max_retries
              raise TransientError, "Parse::Embeddings::Cohere: #{e.class} after #{attempts} attempt(s)."
            end
            sleep(backoff_seconds(attempts))
            next
          end

          status = response.status
          return parse_json_body!(response.body) if status >= 200 && status < 300

          if status == 401
            raise AuthenticationError,
                  "Parse::Embeddings::Cohere: 401 Unauthorized — check api_key."
          end
          if status == 429
            if attempts > @max_retries
              raise RateLimitError,
                    "Parse::Embeddings::Cohere: 429 rate limited after #{attempts} attempt(s)."
            end
            sleep(retry_after_seconds(response) || backoff_seconds(attempts))
            next
          end
          if status >= 500
            if attempts > @max_retries
              raise TransientError,
                    "Parse::Embeddings::Cohere: #{status} after #{attempts} attempt(s)."
            end
            sleep(backoff_seconds(attempts))
            next
          end
          raise BadRequestError,
                "Parse::Embeddings::Cohere: #{status} from POST #{path.start_with?('/') ? path : "/#{path}"}."
        end
      end

      def parse_json_body!(body)
        s = body.to_s
        if s.bytesize > MAX_RESPONSE_BYTES
          raise InvalidResponseError,
                "Parse::Embeddings::Cohere: response body exceeds #{MAX_RESPONSE_BYTES} bytes " \
                "(#{s.bytesize}). Refusing to parse."
        end
        JSON.parse(s, max_nesting: 32)
      rescue JSON::ParserError => e
        raise InvalidResponseError,
              "Parse::Embeddings::Cohere: response is not valid JSON (#{e.message})."
      end

      # Cohere's v1 /embed response shape:
      #
      #   {
      #     "id": "...",
      #     "embeddings": { "float": [[...], [...]] },   # when embedding_types=["float"]
      #     "texts": [...],
      #     "meta": { "billed_units": { "input_tokens": N } }
      #   }
      #
      # A legacy/no-embedding_types call returns `embeddings: [[...]]`
      # as a bare Array. We accept both shapes — the request always
      # sends `embedding_types: ["float"]`, but proxies / Cohere's
      # versioned endpoints may strip it.
      def extract_vectors!(payload, input_count)
        unless payload.is_a?(Hash)
          raise InvalidResponseError,
                "Parse::Embeddings::Cohere: response body is not a JSON object."
        end
        embeddings = payload["embeddings"]
        vectors =
          case embeddings
          when Hash
            f = embeddings["float"]
            unless f.is_a?(Array)
              raise InvalidResponseError,
                    "Parse::Embeddings::Cohere: response.embeddings.float is not an Array."
            end
            f
          when Array
            embeddings
          else
            raise InvalidResponseError,
                  "Parse::Embeddings::Cohere: response.embeddings is neither Hash nor Array."
          end
        if vectors.length != input_count
          raise InvalidResponseError,
                "Parse::Embeddings::Cohere: response embeddings count #{vectors.length} != input count #{input_count}."
        end
        vectors
      end

      def backoff_seconds(attempt)
        [0.5 * (2**(attempt - 1)), 30.0].min
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
                "Parse::Embeddings::Cohere: api_key must be a non-empty String."
        end
      end

      def validate_model!(model)
        unless MODEL_DEFAULT_DIMENSIONS.key?(model)
          raise ArgumentError,
                "Parse::Embeddings::Cohere: unknown model #{model.inspect}. " \
                "Supported: #{MODEL_DEFAULT_DIMENSIONS.keys.inspect}."
        end
      end

      def validate_dimensions!(model, dimensions)
        return if dimensions.nil?
        unless dimensions.is_a?(Integer) && dimensions.positive?
          raise ArgumentError,
                "Parse::Embeddings::Cohere: dimensions must be a positive Integer (got #{dimensions.inspect})."
        end
        native = MODEL_DEFAULT_DIMENSIONS.fetch(model)
        if dimensions > native
          raise ArgumentError,
                "Parse::Embeddings::Cohere: dimensions #{dimensions} exceeds native #{native} for #{model}."
        end
        if !MATRYOSHKA_MODELS.include?(model) && dimensions != native
          raise ArgumentError,
                "Parse::Embeddings::Cohere: model #{model.inspect} does not support custom dimensions " \
                "(Matryoshka-capable models: #{MATRYOSHKA_MODELS.inspect})."
        end
        allowlist = MATRYOSHKA_WIDTHS[model]
        if allowlist && !allowlist.include?(dimensions)
          raise ArgumentError,
                "Parse::Embeddings::Cohere: model #{model.inspect} only accepts Matryoshka widths " \
                "#{allowlist.inspect} (got #{dimensions})."
        end
      end

      def validate_base_url!(base_url, allow_insecure)
        unless base_url.is_a?(String) && !base_url.empty?
          raise ArgumentError,
                "Parse::Embeddings::Cohere: base_url must be a non-empty String."
        end
        begin
          uri = URI.parse(base_url)
        rescue URI::InvalidURIError => e
          raise ArgumentError,
                "Parse::Embeddings::Cohere: base_url is not a valid URL (#{e.message})."
        end
        unless %w[http https].include?(uri.scheme)
          raise ArgumentError,
                "Parse::Embeddings::Cohere: base_url must be http(s):// (got scheme #{uri.scheme.inspect})."
        end
        if uri.scheme == "http" && !allow_insecure
          raise ArgumentError,
                "Parse::Embeddings::Cohere: refusing http:// base_url. " \
                "Pass allow_insecure_base_url: true to opt in."
        end
        if uri.host.nil? || uri.host.empty?
          raise ArgumentError,
                "Parse::Embeddings::Cohere: base_url must include a host."
        end
        if uri.userinfo
          raise ArgumentError,
                "Parse::Embeddings::Cohere: base_url must not contain userinfo (credentials). " \
                "Use the api_key parameter and a clean URL."
        end
        uri.to_s
      end

      def validate_positive_integer!(name, value)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError,
                "Parse::Embeddings::Cohere: #{name} must be a positive Integer (got #{value.inspect})."
        end
      end

      def validate_non_negative_integer!(name, value)
        unless value.is_a?(Integer) && value >= 0
          raise ArgumentError,
                "Parse::Embeddings::Cohere: #{name} must be a non-negative Integer (got #{value.inspect})."
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
