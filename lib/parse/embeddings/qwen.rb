# encoding: UTF-8
# frozen_string_literal: true

require "faraday"
require "json"
require "uri"
require_relative "provider"

module Parse
  module Embeddings
    # Qwen 3 embeddings provider. Targets Alibaba Cloud DashScope's
    # OpenAI-compatible endpoint (`/compatible-mode/v1/embeddings`),
    # which mirrors the OpenAI request envelope but speaks the
    # `qwen3-embedding-*` model family.
    #
    # Supported models — all three are Matryoshka-capable, so the
    # `dimensions:` constructor kwarg truncates the returned vector
    # to any width ≤ native:
    #
    # * `qwen3-embedding-0.6b` — 1024 dim native, ~32k input tokens.
    # * `qwen3-embedding-4b`   — 2560 dim native.
    # * `qwen3-embedding-8b`   — 4096 dim native.
    #
    # The same three checkpoints are published open-weight on Hugging
    # Face under Apache 2.0 (`Qwen/Qwen3-Embedding-0.6B`, etc.) — for
    # self-hosted inference behind vLLM / Text Embeddings Inference /
    # llama.cpp, use {LocalHTTP} instead and point it at your gateway.
    #
    # @example registration (DashScope International endpoint)
    #   Parse::Embeddings.register(:qwen,
    #     Parse::Embeddings::Qwen.new(
    #       api_key: ENV.fetch("DASHSCOPE_API_KEY"),
    #       model:   "qwen3-embedding-8b",
    #     ))
    #
    # @example Matryoshka truncation
    #   Parse::Embeddings::Qwen.new(
    #     api_key: ENV.fetch("DASHSCOPE_API_KEY"),
    #     model:      "qwen3-embedding-8b",
    #     dimensions: 1024,  # truncate from 4096 → 1024
    #   )
    #
    # == Asymmetric input types
    #
    # Qwen3-Embedding is trained with an instruction-tuned head, but
    # the DashScope compatible-mode endpoint does not currently accept
    # an `input_type` / `task` request field. We therefore set
    # `supports_input_type?` to `false` and drop the SDK-canonical
    # `input_type:` kwarg at the wire — same posture as {OpenAI} and
    # {LocalHTTP}. Callers who want query/passage asymmetry must wrap
    # their text with an explicit instruction prefix client-side; the
    # AS::N event still carries the requested `input_type` so cache
    # keys remain stable.
    class Qwen < Provider
      class AuthenticationError < Error; end
      class BadRequestError < Error; end
      class RateLimitError < Error; end
      class TransientError < Error; end

      # Default to the international compatible-mode host. Operators
      # in mainland China should override to
      # `https://dashscope.aliyuncs.com/compatible-mode/v1`.
      DEFAULT_BASE_URL    = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
      DEFAULT_MODEL       = "qwen3-embedding-8b"
      DEFAULT_TIMEOUT     = 30
      DEFAULT_OPEN_TIMEOUT = 5
      DEFAULT_MAX_RETRIES = 3
      # DashScope's compatible endpoint caps embedding requests at 25
      # inputs per call (smaller than OpenAI's 2048). Default below
      # the cap so callers don't have to tune.
      DEFAULT_BATCH_SIZE  = 10
      MAX_RESPONSE_BYTES  = 16 * 1024 * 1024

      MODEL_DEFAULT_DIMENSIONS = {
        "qwen3-embedding-0.6b" => 1024,
        "qwen3-embedding-4b"   => 2560,
        "qwen3-embedding-8b"   => 4096,
      }.freeze

      MODEL_MAX_INPUT_TOKENS = {
        "qwen3-embedding-0.6b" => 32_000,
        "qwen3-embedding-4b"   => 32_000,
        "qwen3-embedding-8b"   => 32_000,
      }.freeze

      # Every Qwen3-Embedding row is Matryoshka-capable. Kept as an
      # explicit allowlist so future non-Matryoshka additions (e.g.
      # qwen-text-embedding-v3) don't silently inherit the behaviour.
      MATRYOSHKA_MODELS = %w[
        qwen3-embedding-0.6b
        qwen3-embedding-4b
        qwen3-embedding-8b
      ].freeze

      # @param api_key [String] required. Sent as `Authorization: Bearer …`.
      # @param model [String] one of {MODEL_DEFAULT_DIMENSIONS}'s keys.
      # @param dimensions [Integer, nil] Matryoshka truncation. Must
      #   be ≤ the model's native width.
      # @param base_url [String] override (mainland-China host or a
      #   private gateway). Must be HTTPS unless
      #   `allow_insecure_base_url: true`.
      # @param timeout [Integer] read timeout, seconds.
      # @param open_timeout [Integer] connect timeout, seconds.
      # @param max_retries [Integer] retry attempts on 429/5xx/timeouts.
      # @param embed_batch_size [Integer] inputs per request (DashScope
      #   compatible-mode caps at 25).
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
        # Qwen3-Embedding is documented unit-normalized at the head.
        true
      end

      def supports_input_type?
        # DashScope compatible-mode does not accept a wire-level
        # input_type / task field. The kwarg threads through for
        # cache-key stability but is dropped at the request.
        false
      end

      # @param strings [Array<String>] inputs.
      # @param input_type [Symbol] accepted for forward compatibility,
      #   dropped at the wire (see {#supports_input_type?}).
      # @return [Array<Array<Float>>] vectors aligned 1:1 with `strings`.
      def embed_text(strings, input_type: :search_document)
        unless strings.is_a?(Array)
          raise ArgumentError,
                "Parse::Embeddings::Qwen#embed_text expects Array<String> (got #{strings.class})."
        end
        return [] if strings.empty?
        strings.each_with_index do |s, i|
          unless s.is_a?(String)
            raise ArgumentError,
                  "Parse::Embeddings::Qwen#embed_text strings[#{i}] is not a String (#{s.class})."
          end
          if s.empty?
            raise ArgumentError,
                  "Parse::Embeddings::Qwen#embed_text strings[#{i}] is empty; Qwen rejects empty inputs."
          end
        end

        body = {
          model: @model,
          input: strings,
          encoding_format: "float",
        }
        # Forward `dimensions` only when active width differs from
        # native. Sending native width is a no-op on DashScope but
        # we keep the wire minimal to avoid drift across future
        # endpoint revisions.
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
              raise TransientError, "Parse::Embeddings::Qwen: #{e.class} after #{attempts} attempt(s)."
            end
            sleep(backoff_seconds(attempts))
            next
          end

          status = response.status
          return parse_json_body!(response.body) if status >= 200 && status < 300

          if status == 401
            raise AuthenticationError, "Parse::Embeddings::Qwen: 401 Unauthorized — check api_key."
          end
          if status == 429
            if attempts > @max_retries
              raise RateLimitError, "Parse::Embeddings::Qwen: 429 rate limited after #{attempts} attempt(s)."
            end
            sleep(retry_after_seconds(response) || backoff_seconds(attempts))
            next
          end
          if status >= 500
            if attempts > @max_retries
              raise TransientError, "Parse::Embeddings::Qwen: #{status} after #{attempts} attempt(s)."
            end
            sleep(backoff_seconds(attempts))
            next
          end
          raise BadRequestError, "Parse::Embeddings::Qwen: #{status} from POST /embeddings."
        end
      end

      def parse_json_body!(body)
        s = body.to_s
        if s.bytesize > MAX_RESPONSE_BYTES
          raise InvalidResponseError,
                "Parse::Embeddings::Qwen: response body exceeds #{MAX_RESPONSE_BYTES} bytes " \
                "(#{s.bytesize}). Refusing to parse."
        end
        JSON.parse(s, max_nesting: 32)
      rescue JSON::ParserError => e
        raise InvalidResponseError,
              "Parse::Embeddings::Qwen: response is not valid JSON (#{e.message})."
      end

      def extract_vectors!(payload, input_count)
        unless payload.is_a?(Hash)
          raise InvalidResponseError,
                "Parse::Embeddings::Qwen: response body is not a JSON object."
        end
        data = payload["data"]
        unless data.is_a?(Array)
          raise InvalidResponseError,
                "Parse::Embeddings::Qwen: response.data is not an Array."
        end
        if data.length != input_count
          raise InvalidResponseError,
                "Parse::Embeddings::Qwen: response.data.length #{data.length} != input count #{input_count}."
        end
        sorted = data.each_with_index.map do |entry, i|
          unless entry.is_a?(Hash)
            raise InvalidResponseError,
                  "Parse::Embeddings::Qwen: response.data[#{i}] is not a JSON object."
          end
          idx = entry["index"]
          unless idx.is_a?(Integer) && idx >= 0 && idx < input_count
            raise InvalidResponseError,
                  "Parse::Embeddings::Qwen: response.data[#{i}].index #{idx.inspect} out of range."
          end
          [idx, entry["embedding"]]
        end
        indices = sorted.map(&:first)
        if indices.uniq.length != indices.length
          raise InvalidResponseError, "Parse::Embeddings::Qwen: duplicate index in response.data."
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
          raise ArgumentError, "Parse::Embeddings::Qwen: api_key must be a non-empty String."
        end
      end

      def validate_model!(model)
        unless MODEL_DEFAULT_DIMENSIONS.key?(model)
          raise ArgumentError,
                "Parse::Embeddings::Qwen: unknown model #{model.inspect}. " \
                "Supported: #{MODEL_DEFAULT_DIMENSIONS.keys.inspect}."
        end
      end

      def validate_dimensions!(model, dimensions)
        return if dimensions.nil?
        unless dimensions.is_a?(Integer) && dimensions.positive?
          raise ArgumentError,
                "Parse::Embeddings::Qwen: dimensions must be a positive Integer (got #{dimensions.inspect})."
        end
        native = MODEL_DEFAULT_DIMENSIONS.fetch(model)
        if dimensions > native
          raise ArgumentError,
                "Parse::Embeddings::Qwen: dimensions #{dimensions} exceeds native #{native} for #{model}."
        end
        if !MATRYOSHKA_MODELS.include?(model) && dimensions != native
          raise ArgumentError,
                "Parse::Embeddings::Qwen: model #{model.inspect} does not support custom dimensions " \
                "(Matryoshka-capable models: #{MATRYOSHKA_MODELS.inspect})."
        end
      end

      def validate_base_url!(base_url, allow_insecure)
        unless base_url.is_a?(String) && !base_url.empty?
          raise ArgumentError, "Parse::Embeddings::Qwen: base_url must be a non-empty String."
        end
        begin
          uri = URI.parse(base_url)
        rescue URI::InvalidURIError => e
          raise ArgumentError, "Parse::Embeddings::Qwen: base_url is not a valid URL (#{e.message})."
        end
        unless %w[http https].include?(uri.scheme)
          raise ArgumentError,
                "Parse::Embeddings::Qwen: base_url must be http(s):// (got scheme #{uri.scheme.inspect})."
        end
        if uri.scheme == "http" && !allow_insecure
          raise ArgumentError,
                "Parse::Embeddings::Qwen: refusing http:// base_url. Pass allow_insecure_base_url: true to opt in."
        end
        if uri.host.nil? || uri.host.empty?
          raise ArgumentError, "Parse::Embeddings::Qwen: base_url must include a host."
        end
        if uri.userinfo
          raise ArgumentError,
                "Parse::Embeddings::Qwen: base_url must not contain userinfo (credentials). " \
                "Use the api_key parameter and a clean URL."
        end
        uri.to_s
      end

      def validate_positive_integer!(name, value)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError,
                "Parse::Embeddings::Qwen: #{name} must be a positive Integer (got #{value.inspect})."
        end
      end

      def validate_non_negative_integer!(name, value)
        unless value.is_a?(Integer) && value >= 0
          raise ArgumentError,
                "Parse::Embeddings::Qwen: #{name} must be a non-negative Integer (got #{value.inspect})."
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
