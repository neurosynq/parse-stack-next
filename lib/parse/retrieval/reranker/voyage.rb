# encoding: UTF-8
# frozen_string_literal: true

require "json"
require "uri"
require "ipaddr"
require_relative "../reranker"

module Parse
  module Retrieval
    module Reranker
      # Voyage AI cross-encoder reranker. Wraps `POST /v1/rerank`.
      #
      # Takes a query plus a list of document strings and returns a
      # relevance-ordered list of `{ index, relevance_score }` objects.
      # It is a distinct endpoint from `/v1/embeddings`; do NOT confuse it
      # with {Parse::Embeddings::Voyage} (the embeddings provider).
      #
      # == Endpoints
      #
      # The same models are served by Voyage's own API and by MongoDB's
      # Atlas Embedding and Reranking API, with an identical wire contract.
      # An Atlas model API key (prefix {ATLAS_KEY_PREFIX}) routes to
      # {ATLAS_BASE_URL} automatically, matching the embeddings provider.
      # Pass `base_url:` to target either host (or a proxy) explicitly.
      #
      # The HTTP stack mirrors {Cohere}: explicit `proxy: nil` unless
      # opted in, bounded timeouts, capped retries with backoff on
      # 429/5xx, a response-size cap, and a redacted `#inspect`.
      #
      # @example
      #   reranker = Parse::Retrieval::Reranker::Voyage.new(
      #     api_key: ENV.fetch("VOYAGE_API_KEY"),
      #     model:   "rerank-3",
      #   )
      #   reranker.rerank(query: "rain songs", documents: lyrics, top_n: 5)
      class Voyage < Base
        class AuthenticationError < Error; end
        class RateLimitError < Error; end
        class TransientError < Error; end
        class BadRequestError < Error; end

        DEFAULT_BASE_URL = "https://api.voyageai.com/v1"
        ATLAS_BASE_URL = "https://ai.mongodb.com/v1"
        # Atlas model API keys carry this prefix and authenticate only
        # against {ATLAS_BASE_URL}.
        ATLAS_KEY_PREFIX = "al-"
        DEFAULT_MODEL = "rerank-3"
        DEFAULT_TIMEOUT = 30
        DEFAULT_OPEN_TIMEOUT = 5
        DEFAULT_MAX_RETRIES = 2

        # Current and still-served rerank models. Informational: the
        # constructor accepts any non-empty model name so a newly released
        # model works without an SDK upgrade.
        MODELS = %w[rerank-3 rerank-3-lite rerank-2.5 rerank-2.5-lite rerank-2 rerank-2-lite].freeze

        # Voyage documents a cap of 1000 documents per rerank call; the
        # {Base::MAX_DOCUMENTS} cap (1000) already enforces this.
        MAX_RESPONSE_BYTES = 5 * 1024 * 1024

        # @param api_key [String] Voyage API key, or an Atlas model API key.
        # @param model [String] rerank model (default {DEFAULT_MODEL}).
        # @param base_url [String, nil] API base. Defaults to
        #   {ATLAS_BASE_URL} for an Atlas key, else {DEFAULT_BASE_URL}.
        # @param truncation [Boolean] forward Voyage's `truncation:` field.
        #   Defaults `true` (Voyage's default). `false` makes over-length
        #   inputs a 400 instead of silently truncating them.
        # @param timeout [Integer] read timeout (seconds).
        # @param open_timeout [Integer] connect timeout (seconds).
        # @param max_retries [Integer] retry budget for 429 / 5xx /
        #   transient connection errors.
        # @param allow_faraday_proxy [Boolean] permit Faraday to honor
        #   `*_proxy` env vars (default false, explicit `proxy: nil`).
        def initialize(api_key:, model: DEFAULT_MODEL, base_url: nil, truncation: true,
                       timeout: DEFAULT_TIMEOUT, open_timeout: DEFAULT_OPEN_TIMEOUT,
                       max_retries: DEFAULT_MAX_RETRIES, allow_faraday_proxy: false)
          validate_api_key!(api_key)
          @api_key = api_key
          @model = model.to_s
          raise ArgumentError, "Reranker::Voyage: model must be non-empty." if @model.empty?
          base_url ||= api_key.start_with?(ATLAS_KEY_PREFIX) ? ATLAS_BASE_URL : DEFAULT_BASE_URL
          @base_url = base_url.to_s
          validate_base_url!(@base_url)
          unless [true, false].include?(truncation)
            raise ArgumentError, "Reranker::Voyage: truncation must be true or false (got #{truncation.inspect})."
          end
          @truncation = truncation
          @timeout = Integer(timeout)
          @open_timeout = Integer(open_timeout)
          @max_retries = Integer(max_retries)
          raise ArgumentError, "Reranker::Voyage: max_retries must be >= 0." if @max_retries.negative?
          @allow_faraday_proxy = allow_faraday_proxy ? true : false
          @connection = build_connection
        end

        # @return [String] the rerank model name.
        attr_reader :model

        # @return [Boolean] true when routed through {ATLAS_BASE_URL}.
        def atlas?
          safe_base_host == URI.parse(ATLAS_BASE_URL).host
        end

        def inspect
          "#<#{self.class} model=#{@model.inspect} base=#{safe_base_host.inspect} " \
          "retries=#{@max_retries} api_key=[REDACTED]>"
        end

        protected

        def rerank_scores(query, documents, top_n)
          require_faraday!
          body = {
            "model" => @model,
            "query" => query,
            "documents" => documents,
            "top_k" => top_n,
            "truncation" => @truncation,
          }
          payload = post_rerank(body)
          extract_results!(payload)
        end

        private

        def post_rerank(body)
          attempts = 0
          loop do
            attempts += 1
            begin
              response = @connection.post("rerank") { |req| req.body = body.to_json }
            rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
              raise TransientError, "Reranker::Voyage: #{e.class} after #{attempts} attempt(s)." if attempts > @max_retries
              sleep(backoff_seconds(attempts))
              next
            end

            status = response.status
            return parse_json_body!(response.body) if status >= 200 && status < 300

            case status
            when 401
              raise AuthenticationError, "Reranker::Voyage: 401 Unauthorized. Check api_key."
            when 429
              raise RateLimitError, "Reranker::Voyage: 429 rate limited after #{attempts} attempt(s)." if attempts > @max_retries
              sleep(retry_after_seconds(response) || backoff_seconds(attempts))
            when 500..599
              raise TransientError, "Reranker::Voyage: #{status} after #{attempts} attempt(s)." if attempts > @max_retries
              sleep(backoff_seconds(attempts))
            else
              raise BadRequestError, "Reranker::Voyage: #{status} from POST /rerank."
            end
          end
        end

        # Voyage /v1/rerank response shape:
        #   { "object": "list",
        #     "data": [ { "index": 0, "relevance_score": 0.45 }, ... ],
        #     "model": "rerank-3", "usage": { "total_tokens": 8 } }
        def extract_results!(payload)
          unless payload.is_a?(Hash)
            raise InvalidResponseError, "Reranker::Voyage: response body is not a JSON object."
          end
          data = payload["data"]
          unless data.is_a?(Array)
            raise InvalidResponseError, "Reranker::Voyage: response.data is not an Array."
          end
          data.map do |r|
            unless r.is_a?(Hash)
              raise InvalidResponseError, "Reranker::Voyage: rerank result is not an object (#{r.inspect})."
            end
            Result.new(index: r["index"], relevance_score: r["relevance_score"])
          end
        end

        def parse_json_body!(body)
          s = body.to_s
          if s.bytesize > MAX_RESPONSE_BYTES
            raise InvalidResponseError,
                  "Reranker::Voyage: response body exceeds #{MAX_RESPONSE_BYTES} bytes (#{s.bytesize})."
          end
          JSON.parse(s, max_nesting: 32)
        rescue JSON::ParserError => e
          raise InvalidResponseError, "Reranker::Voyage: response is not valid JSON (#{e.message})."
        end

        def build_connection
          require_faraday!
          headers = {
            "Authorization" => "Bearer #{@api_key}",
            "Content-Type" => "application/json",
            "Accept" => "application/json",
            "User-Agent" => "parse-stack-reranker/#{Parse::Stack::VERSION rescue "0"}",
          }
          # base_url must end with a trailing slash so Faraday resolves the
          # relative "rerank" path under /v1/ rather than replacing it.
          base = @base_url.end_with?("/") ? @base_url : "#{@base_url}/"
          faraday_opts = { url: base, headers: headers }
          faraday_opts[:proxy] = nil unless @allow_faraday_proxy
          conn = Faraday.new(**faraday_opts) do |f|
            f.options.timeout = @timeout
            f.options.open_timeout = @open_timeout
            f.adapter Faraday.default_adapter
          end
          conn.proxy = nil if !@allow_faraday_proxy && conn.respond_to?(:proxy=)
          conn
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

        def validate_api_key!(api_key)
          unless api_key.is_a?(String) && !api_key.empty?
            raise ArgumentError, "Reranker::Voyage: api_key must be a non-empty String."
          end
        end

        def validate_base_url!(base_url)
          uri = URI.parse(base_url)
          unless uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP)
            raise ArgumentError, "Reranker::Voyage: base_url must be http(s) (got #{base_url.inspect})."
          end
          # Credentials in the URL leak into logs and error messages, and
          # userinfo can mask the real host.
          unless uri.userinfo.nil?
            raise ArgumentError,
                  "Reranker::Voyage: base_url must not embed userinfo (credentials in the URL)."
          end
          # Plaintext http:// would send the API key in the clear. Permit it
          # only for loopback hosts (a local dev proxy or sidecar).
          if uri.scheme == "http" && !loopback_host?(uri.host)
            raise ArgumentError,
                  "Reranker::Voyage: base_url must be https:// for non-loopback hosts " \
                  "(refusing to send the API key over plaintext http to #{uri.host.inspect})."
          end
        rescue URI::InvalidURIError => e
          raise ArgumentError, "Reranker::Voyage: invalid base_url #{base_url.inspect} (#{e.message})."
        end

        # @return [Boolean] true for localhost / 127.0.0.0/8 / ::1 etc.
        def loopback_host?(host)
          return false if host.nil? || host.empty?
          h = host.downcase.sub(/\A\[/, "").sub(/\]\z/, "")
          return true if h == "localhost"
          begin
            IPAddr.new(h).loopback?
          rescue IPAddr::Error
            false
          end
        end

        def safe_base_host
          URI.parse(@base_url).host
        rescue StandardError
          "?"
        end

        def require_faraday!
          require "faraday" unless defined?(Faraday)
        rescue LoadError
          raise Error, "Reranker::Voyage requires the `faraday` gem."
        end
      end
    end
  end
end
