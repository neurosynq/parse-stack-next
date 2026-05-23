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
    # multimodal text+image models (text-input path only in v5.0; the
    # image-input path lands with {Provider#embed_image} in v5.1).
    #
    # Supported models:
    #
    # * **v4 family** — `voyage-4-large` (MoE flagship, Matryoshka-capable),
    #   `voyage-4`, `voyage-4-lite`, `voyage-4-nano` (Apache 2.0,
    #   open-weight on Hugging Face — also runnable through
    #   {LocalHTTP} when self-hosted on vLLM / Ollama / llama.cpp).
    # * **v3 family** — `voyage-3-large`, `voyage-3`, `voyage-3-lite`,
    #   `voyage-code-3`.
    # * **domain models** — `voyage-finance-2`, `voyage-law-2`.
    # * **multimodal** — `voyage-multimodal-3` (1024-dim). Unified
    #   text+image vector space at the network boundary. This provider
    #   exposes the text-input path only: routes to
    #   `/v1/multimodalembeddings` with a `{ inputs: [{ content:
    #   [{ type: "text", text: … }] }] }` envelope. The same model will
    #   accept image inputs in v5.1 when the `embed_image` hook ships;
    #   text vectors stored today will sit in the same space as the
    #   eventual image vectors (no re-embed required).
    #
    # @example registration
    #   Parse::Embeddings.register(:voyage,
    #     Parse::Embeddings::Voyage.new(
    #       api_key: ENV.fetch("VOYAGE_API_KEY"),
    #       model:   "voyage-3",
    #     ))
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

      DEFAULT_BASE_URL    = "https://api.voyageai.com/v1"
      DEFAULT_MODEL       = "voyage-3"
      DEFAULT_TIMEOUT     = 30
      DEFAULT_OPEN_TIMEOUT = 5
      DEFAULT_MAX_RETRIES = 3
      # Voyage's documented per-request cap is 128 inputs.
      DEFAULT_BATCH_SIZE  = 128
      MAX_RESPONSE_BYTES  = 16 * 1024 * 1024

      # Native vector widths per model. The v4 family is Voyage's
      # current flagship line (MoE for `voyage-4-large`, open-weight
      # nano under Apache 2.0). `voyage-4-large` supports Matryoshka
      # truncation via the constructor's `dimensions:` override.
      MODEL_DEFAULT_DIMENSIONS = {
        "voyage-4-large"      => 2048,
        "voyage-4"            => 1024,
        "voyage-4-lite"       => 512,
        "voyage-4-nano"       => 256,
        "voyage-3-large"      => 1024,
        "voyage-3"            => 1024,
        "voyage-3-lite"       => 512,
        "voyage-code-3"       => 1024,
        "voyage-finance-2"    => 1024,
        "voyage-law-2"        => 1024,
        "voyage-multimodal-3" => 1024,
      }.freeze

      MODEL_MAX_INPUT_TOKENS = {
        "voyage-4-large"      => 32_000,
        "voyage-4"            => 32_000,
        "voyage-4-lite"       => 32_000,
        "voyage-4-nano"       => 32_000,
        "voyage-3-large"      => 32_000,
        "voyage-3"            => 32_000,
        "voyage-3-lite"       => 32_000,
        "voyage-code-3"       => 32_000,
        "voyage-finance-2"    => 16_000,
        "voyage-law-2"        => 16_000,
        "voyage-multimodal-3" => 32_000,
      }.freeze

      # Models that accept Voyage's `output_dimension` Matryoshka
      # truncation parameter. Sending the field for other models is
      # rejected with a 400 by Voyage, so we gate it explicitly.
      MATRYOSHKA_MODELS = %w[voyage-4-large].freeze

      # Models that route to `/v1/multimodalembeddings` with the
      # `{ inputs: [{ content: [...] }] }` envelope rather than the
      # standard `/v1/embeddings` `{ input: [String] }` envelope.
      # Text-only inputs from this provider are wrapped as
      # `{ type: "text", text: s }` content rows.
      MULTIMODAL_MODELS = %w[voyage-multimodal-3].freeze

      # Map SDK-canonical input_type symbols to Voyage wire strings.
      # `:classification` / `:clustering` map to `nil` (omitted) since
      # Voyage only distinguishes retrieval halves — other intents
      # should receive the unconditioned vector.
      INPUT_TYPE_WIRE_VALUES = {
        search_query:    "query",
        search_document: "document",
        classification:  nil,
        clustering:      nil,
      }.freeze

      # @param api_key [String] required. Sent as `Authorization: Bearer …`.
      # @param model [String] one of {MODEL_DEFAULT_DIMENSIONS}'s keys.
      # @param base_url [String] override. Must be HTTPS unless
      #   `allow_insecure_base_url: true`.
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
        base_url: DEFAULT_BASE_URL,
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
        body =
          if MULTIMODAL_MODELS.include?(@model)
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
        # `output_dimension` is only valid for the Matryoshka-capable
        # models. Forward when the configured model is in the
        # Matryoshka set and the active dimensions differ from native.
        # Sending it elsewhere would yield a 400.
        if MATRYOSHKA_MODELS.include?(@model) &&
           @dimensions != MODEL_DEFAULT_DIMENSIONS.fetch(@model)
          body[:output_dimension] = @dimensions
        end
        body
      end

      # Build the wire body for `/v1/multimodalembeddings`. The text
      # path wraps each input string as a single `{type: "text", text:}`
      # content row. Image inputs will land in v5.1 alongside
      # {Provider#embed_image}; for now the provider is text-only and
      # the multimodal envelope's `content` array always contains a
      # single text row per input.
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
        body
      end

      def post_embeddings(body, path: "embeddings")
        attempts = 0
        loop do
          attempts += 1
          begin
            response = @connection.post(path) do |req|
              req.body = body.to_json
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
        native = MODEL_DEFAULT_DIMENSIONS.fetch(model)
        if dimensions > native
          raise ArgumentError,
                "Parse::Embeddings::Voyage: dimensions #{dimensions} exceeds native #{native} for #{model}."
        end
        if !MATRYOSHKA_MODELS.include?(model) && dimensions != native
          raise ArgumentError,
                "Parse::Embeddings::Voyage: model #{model.inspect} does not support custom dimensions " \
                "(Matryoshka-capable models: #{MATRYOSHKA_MODELS.inspect})."
        end
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
