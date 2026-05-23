# encoding: UTF-8
# frozen_string_literal: true

require "faraday"
require "json"
require "uri"
require_relative "provider"

module Parse
  module Embeddings
    # Jina AI embeddings provider. Wraps `POST /v1/embeddings`.
    #
    # Supported text-capable models:
    #
    # * **v5 text family** — `jina-embeddings-v5-text-small`,
    #   `jina-embeddings-v5-text-nano`.
    # * **v5 omni family (text mode)** — `jina-embeddings-v5-omni-small`,
    #   `jina-embeddings-v5-omni-nano`. These models are multimodal at
    #   the network boundary but accept plain-text inputs through this
    #   provider just like the text-only variants.
    # * **v4** — `jina-embeddings-v4` (Matryoshka, multimodal; text
    #   inputs only here).
    # * **v3** — `jina-embeddings-v3` (Matryoshka, 32–1024).
    # * **code embeddings** — `jina-code-embeddings-0.5b`,
    #   `jina-code-embeddings-1.5b`.
    #
    # Rerankers (`jina-reranker-*`), VLM (`jina-vlm`),
    # image-only (`jina-clip-v2`), and `ReaderLM-v2` are NOT exposed
    # through this provider — they don't fit the `embed_text` contract.
    # They'll surface through forthcoming `embed_image` / rerank /
    # generation hooks.
    #
    # @example registration
    #   Parse::Embeddings.register(:jina,
    #     Parse::Embeddings::Jina.new(
    #       api_key: ENV.fetch("JINA_API_KEY"),
    #       model:   "jina-embeddings-v3",
    #     ))
    #
    # == Asymmetric input types
    #
    # Jina uses a `task` request field with the following canonical
    # values (mapped from SDK-canonical `input_type:` Symbols):
    #
    # * `:search_query`        → `"retrieval.query"`
    # * `:search_document`     → `"retrieval.passage"`
    # * `:classification`      → `"classification"`
    # * `:clustering`          → `"separation"`
    #
    # The `Provider#supports_input_type?` flag returns `true` here so
    # cache-keying middleware can branch on it. Code-embedding models
    # accept the `task` field and use it to bias the head.
    #
    # == Matryoshka dimensions
    #
    # `jina-embeddings-v3`, `jina-embeddings-v4`, and the v5 family
    # support Matryoshka-style output-width truncation via the
    # `dimensions` request field. Pass `dimensions:` to the constructor
    # to set the desired width (must be ≤ the model's native width).
    class Jina < Provider
      class AuthenticationError < Error; end
      class BadRequestError < Error; end
      class RateLimitError < Error; end
      class TransientError < Error; end

      DEFAULT_BASE_URL    = "https://api.jina.ai/v1"
      DEFAULT_MODEL       = "jina-embeddings-v3"
      DEFAULT_TIMEOUT     = 30
      DEFAULT_OPEN_TIMEOUT = 5
      DEFAULT_MAX_RETRIES = 3
      DEFAULT_BATCH_SIZE  = 100
      MAX_RESPONSE_BYTES  = 16 * 1024 * 1024

      # Native vector widths. The Matryoshka-capable rows allow the
      # caller to truncate via the `dimensions:` kwarg.
      MODEL_DEFAULT_DIMENSIONS = {
        "jina-embeddings-v5-omni-small" => 1024,
        "jina-embeddings-v5-omni-nano"  => 512,
        "jina-embeddings-v5-text-small" => 1024,
        "jina-embeddings-v5-text-nano"  => 512,
        "jina-embeddings-v4"            => 2048,
        "jina-embeddings-v3"            => 1024,
        "jina-code-embeddings-1.5b"     => 1024,
        "jina-code-embeddings-0.5b"     => 1024,
      }.freeze

      MODEL_MAX_INPUT_TOKENS = {
        "jina-embeddings-v5-omni-small" => 32_000,
        "jina-embeddings-v5-omni-nano"  => 32_000,
        "jina-embeddings-v5-text-small" => 32_000,
        "jina-embeddings-v5-text-nano"  => 32_000,
        "jina-embeddings-v4"            => 32_000,
        "jina-embeddings-v3"            => 8_192,
        "jina-code-embeddings-1.5b"     => 32_000,
        "jina-code-embeddings-0.5b"     => 32_000,
      }.freeze

      # Models that accept the Matryoshka `dimensions` field. Other
      # rows must pass the native width or no override.
      MATRYOSHKA_MODELS = %w[
        jina-embeddings-v5-omni-small
        jina-embeddings-v5-omni-nano
        jina-embeddings-v5-text-small
        jina-embeddings-v5-text-nano
        jina-embeddings-v4
        jina-embeddings-v3
      ].freeze

      # Map SDK-canonical input_type symbols to Jina `task` strings.
      INPUT_TYPE_WIRE_VALUES = {
        search_query:    "retrieval.query",
        search_document: "retrieval.passage",
        classification:  "classification",
        clustering:      "separation",
      }.freeze

      # @param api_key [String] required. Sent as `Authorization: Bearer …`.
      # @param model [String] one of {MODEL_DEFAULT_DIMENSIONS}'s keys.
      # @param dimensions [Integer, nil] Matryoshka truncation. Only
      #   {MATRYOSHKA_MODELS} accept this; for others must be nil or
      #   equal to the native width.
      # @param base_url [String] override. Must be HTTPS unless
      #   `allow_insecure_base_url: true`.
      # @param timeout [Integer] read timeout, seconds.
      # @param open_timeout [Integer] connect timeout, seconds.
      # @param max_retries [Integer] retry attempts on 429/5xx/timeouts.
      # @param embed_batch_size [Integer] inputs per request.
      # @param allow_faraday_proxy [Boolean] opt in to proxy / env-proxy
      #   autodiscovery. Defaults `false`.
      # @param allow_insecure_base_url [Boolean] permit `http://` base.
      # @param connection [Faraday::Connection, nil] injection seam.
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
        # Jina's v3/v4/v5 embeddings are documented unit-normalized.
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
                "Parse::Embeddings::Jina#embed_text expects Array<String> (got #{strings.class})."
        end
        return [] if strings.empty?
        strings.each_with_index do |s, i|
          unless s.is_a?(String)
            raise ArgumentError,
                  "Parse::Embeddings::Jina#embed_text strings[#{i}] is not a String (#{s.class})."
          end
          if s.empty?
            raise ArgumentError,
                  "Parse::Embeddings::Jina#embed_text strings[#{i}] is empty; Jina rejects empty inputs."
          end
        end
        unless INPUT_TYPE_WIRE_VALUES.key?(input_type)
          raise ArgumentError,
                "Parse::Embeddings::Jina#embed_text input_type #{input_type.inspect} not in " \
                "#{INPUT_TYPE_WIRE_VALUES.keys.inspect}."
        end
        task_value = INPUT_TYPE_WIRE_VALUES[input_type]

        body = {
          model: @model,
          input: strings,
          task: task_value,
          embedding_type: "float",
        }
        # Forward `dimensions` only for Matryoshka-capable models whose
        # active width differs from native. Sending it to a non-Matryoshka
        # model would yield a 400 from Jina.
        if MATRYOSHKA_MODELS.include?(@model) &&
           @dimensions != MODEL_DEFAULT_DIMENSIONS.fetch(@model)
          body[:dimensions] = @dimensions
        end

        instrument_embed(strings.length, input_type) do |emit_payload|
          payload = post_embeddings(body)
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

      def post_embeddings(body)
        attempts = 0
        loop do
          attempts += 1
          begin
            response = @connection.post("embeddings") do |req|
              req.body = body.to_json
            end
          rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
            if attempts > @max_retries
              raise TransientError, "Parse::Embeddings::Jina: #{e.class} after #{attempts} attempt(s)."
            end
            sleep(backoff_seconds(attempts))
            next
          end

          status = response.status
          return parse_json_body!(response.body) if status >= 200 && status < 300

          if status == 401
            raise AuthenticationError, "Parse::Embeddings::Jina: 401 Unauthorized — check api_key."
          end
          if status == 429
            if attempts > @max_retries
              raise RateLimitError, "Parse::Embeddings::Jina: 429 rate limited after #{attempts} attempt(s)."
            end
            sleep(retry_after_seconds(response) || backoff_seconds(attempts))
            next
          end
          if status >= 500
            if attempts > @max_retries
              raise TransientError, "Parse::Embeddings::Jina: #{status} after #{attempts} attempt(s)."
            end
            sleep(backoff_seconds(attempts))
            next
          end
          raise BadRequestError, "Parse::Embeddings::Jina: #{status} from POST /embeddings."
        end
      end

      def parse_json_body!(body)
        s = body.to_s
        if s.bytesize > MAX_RESPONSE_BYTES
          raise InvalidResponseError,
                "Parse::Embeddings::Jina: response body exceeds #{MAX_RESPONSE_BYTES} bytes " \
                "(#{s.bytesize}). Refusing to parse."
        end
        JSON.parse(s, max_nesting: 32)
      rescue JSON::ParserError => e
        raise InvalidResponseError,
              "Parse::Embeddings::Jina: response is not valid JSON (#{e.message})."
      end

      def extract_vectors!(payload, input_count)
        unless payload.is_a?(Hash)
          raise InvalidResponseError,
                "Parse::Embeddings::Jina: response body is not a JSON object."
        end
        data = payload["data"]
        unless data.is_a?(Array)
          raise InvalidResponseError,
                "Parse::Embeddings::Jina: response.data is not an Array."
        end
        if data.length != input_count
          raise InvalidResponseError,
                "Parse::Embeddings::Jina: response.data.length #{data.length} != input count #{input_count}."
        end
        sorted = data.each_with_index.map do |entry, i|
          unless entry.is_a?(Hash)
            raise InvalidResponseError,
                  "Parse::Embeddings::Jina: response.data[#{i}] is not a JSON object."
          end
          idx = entry["index"]
          unless idx.is_a?(Integer) && idx >= 0 && idx < input_count
            raise InvalidResponseError,
                  "Parse::Embeddings::Jina: response.data[#{i}].index #{idx.inspect} out of range."
          end
          [idx, entry["embedding"]]
        end
        indices = sorted.map(&:first)
        if indices.uniq.length != indices.length
          raise InvalidResponseError, "Parse::Embeddings::Jina: duplicate index in response.data."
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
          raise ArgumentError, "Parse::Embeddings::Jina: api_key must be a non-empty String."
        end
      end

      def validate_model!(model)
        unless MODEL_DEFAULT_DIMENSIONS.key?(model)
          raise ArgumentError,
                "Parse::Embeddings::Jina: unknown model #{model.inspect}. " \
                "Supported: #{MODEL_DEFAULT_DIMENSIONS.keys.inspect}."
        end
      end

      def validate_dimensions!(model, dimensions)
        return if dimensions.nil?
        unless dimensions.is_a?(Integer) && dimensions.positive?
          raise ArgumentError,
                "Parse::Embeddings::Jina: dimensions must be a positive Integer (got #{dimensions.inspect})."
        end
        native = MODEL_DEFAULT_DIMENSIONS.fetch(model)
        if dimensions > native
          raise ArgumentError,
                "Parse::Embeddings::Jina: dimensions #{dimensions} exceeds native #{native} for #{model}."
        end
        if !MATRYOSHKA_MODELS.include?(model) && dimensions != native
          raise ArgumentError,
                "Parse::Embeddings::Jina: model #{model.inspect} does not support custom dimensions " \
                "(Matryoshka-capable models: #{MATRYOSHKA_MODELS.inspect})."
        end
      end

      def validate_base_url!(base_url, allow_insecure)
        unless base_url.is_a?(String) && !base_url.empty?
          raise ArgumentError, "Parse::Embeddings::Jina: base_url must be a non-empty String."
        end
        begin
          uri = URI.parse(base_url)
        rescue URI::InvalidURIError => e
          raise ArgumentError, "Parse::Embeddings::Jina: base_url is not a valid URL (#{e.message})."
        end
        unless %w[http https].include?(uri.scheme)
          raise ArgumentError,
                "Parse::Embeddings::Jina: base_url must be http(s):// (got scheme #{uri.scheme.inspect})."
        end
        if uri.scheme == "http" && !allow_insecure
          raise ArgumentError,
                "Parse::Embeddings::Jina: refusing http:// base_url. Pass allow_insecure_base_url: true to opt in."
        end
        if uri.host.nil? || uri.host.empty?
          raise ArgumentError, "Parse::Embeddings::Jina: base_url must include a host."
        end
        if uri.userinfo
          raise ArgumentError,
                "Parse::Embeddings::Jina: base_url must not contain userinfo (credentials). " \
                "Use the api_key parameter and a clean URL."
        end
        uri.to_s
      end

      def validate_positive_integer!(name, value)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError,
                "Parse::Embeddings::Jina: #{name} must be a positive Integer (got #{value.inspect})."
        end
      end

      def validate_non_negative_integer!(name, value)
        unless value.is_a?(Integer) && value >= 0
          raise ArgumentError,
                "Parse::Embeddings::Jina: #{name} must be a non-negative Integer (got #{value.inspect})."
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
