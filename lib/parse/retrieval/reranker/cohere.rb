# encoding: UTF-8
# frozen_string_literal: true

require "json"
require "uri"
require_relative "../reranker"

module Parse
  module Retrieval
    module Reranker
      # Cohere cross-encoder reranker. Wraps `POST /v2/rerank`.
      #
      # Cohere's rerank API takes a query plus a list of document strings
      # and returns a relevance-ordered list of `{ index, relevance_score }`
      # objects. It is a distinct endpoint from `/v1/embed` /
      # `/v2/embed` — do NOT confuse it with
      # {Parse::Embeddings::Cohere} (the embeddings provider).
      #
      # The HTTP stack mirrors the embeddings provider's hardening:
      # explicit `proxy: nil` unless opted in, bounded timeouts, capped
      # retries with backoff on 429/5xx, response-size cap, and a redacted
      # `#inspect`.
      #
      # @example
      #   reranker = Parse::Retrieval::Reranker::Cohere.new(
      #     api_key: ENV.fetch("COHERE_API_KEY"),
      #     model:   "rerank-v3.5",
      #   )
      #   reranker.rerank(query: "rain songs", documents: lyrics, top_n: 5)
      class Cohere < Base
        class AuthenticationError < Error; end
        class RateLimitError < Error; end
        class TransientError < Error; end
        class BadRequestError < Error; end

        DEFAULT_BASE_URL = "https://api.cohere.com/v2"
        DEFAULT_MODEL    = "rerank-v3.5"
        DEFAULT_TIMEOUT  = 30
        DEFAULT_OPEN_TIMEOUT = 5
        DEFAULT_MAX_RETRIES  = 2

        # Cohere documents a cap of 1000 documents per rerank call; the
        # {Base::MAX_DOCUMENTS} cap (1000) already enforces this.
        MAX_RESPONSE_BYTES = 5 * 1024 * 1024

        # @param api_key [String] Cohere API key.
        # @param model [String] rerank model (default {DEFAULT_MODEL}).
        # @param base_url [String] API base (default {DEFAULT_BASE_URL}).
        # @param timeout [Integer] read timeout (seconds).
        # @param open_timeout [Integer] connect timeout (seconds).
        # @param max_retries [Integer] retry budget for 429 / 5xx /
        #   transient connection errors.
        # @param allow_faraday_proxy [Boolean] permit Faraday to honor
        #   `*_proxy` env vars (default false — explicit `proxy: nil`).
        def initialize(api_key:, model: DEFAULT_MODEL, base_url: DEFAULT_BASE_URL,
                       timeout: DEFAULT_TIMEOUT, open_timeout: DEFAULT_OPEN_TIMEOUT,
                       max_retries: DEFAULT_MAX_RETRIES, allow_faraday_proxy: false)
          validate_api_key!(api_key)
          @api_key = api_key
          @model = model.to_s
          raise ArgumentError, "Reranker::Cohere: model must be non-empty." if @model.empty?
          @base_url = base_url.to_s
          validate_base_url!(@base_url)
          @timeout = Integer(timeout)
          @open_timeout = Integer(open_timeout)
          @max_retries = Integer(max_retries)
          raise ArgumentError, "Reranker::Cohere: max_retries must be >= 0." if @max_retries.negative?
          @allow_faraday_proxy = allow_faraday_proxy ? true : false
          @connection = build_connection
        end

        # @return [String] the rerank model name.
        attr_reader :model

        def inspect
          "#<#{self.class} model=#{@model.inspect} base=#{safe_base_host.inspect} " \
            "retries=#{@max_retries} api_key=[REDACTED]>"
        end

        protected

        def rerank_scores(query, documents, top_n)
          require_faraday!
          body = {
            "model"     => @model,
            "query"     => query,
            "documents" => documents,
            "top_n"     => top_n,
          }
          payload = post_rerank(body)
          extract_results!(payload, documents.length)
        end

        private

        def post_rerank(body)
          attempts = 0
          loop do
            attempts += 1
            begin
              response = @connection.post("rerank") { |req| req.body = body.to_json }
            rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
              raise TransientError, "Reranker::Cohere: #{e.class} after #{attempts} attempt(s)." if attempts > @max_retries
              sleep(backoff_seconds(attempts))
              next
            end

            status = response.status
            return parse_json_body!(response.body) if status >= 200 && status < 300

            case status
            when 401
              raise AuthenticationError, "Reranker::Cohere: 401 Unauthorized — check api_key."
            when 429
              raise RateLimitError, "Reranker::Cohere: 429 rate limited after #{attempts} attempt(s)." if attempts > @max_retries
              sleep(retry_after_seconds(response) || backoff_seconds(attempts))
            when 500..599
              raise TransientError, "Reranker::Cohere: #{status} after #{attempts} attempt(s)." if attempts > @max_retries
              sleep(backoff_seconds(attempts))
            else
              raise BadRequestError, "Reranker::Cohere: #{status} from POST /rerank."
            end
          end
        end

        # Cohere v2 /rerank response shape:
        #   { "id": "...", "results": [ { "index": 0, "relevance_score": 0.98 }, ... ],
        #     "meta": { "billed_units": { "search_units": 1 } } }
        def extract_results!(payload, doc_count)
          unless payload.is_a?(Hash)
            raise InvalidResponseError, "Reranker::Cohere: response body is not a JSON object."
          end
          results = payload["results"]
          unless results.is_a?(Array)
            raise InvalidResponseError, "Reranker::Cohere: response.results is not an Array."
          end
          results.map do |r|
            unless r.is_a?(Hash)
              raise InvalidResponseError, "Reranker::Cohere: rerank result is not an object (#{r.inspect})."
            end
            Result.new(index: r["index"], relevance_score: r["relevance_score"])
          end
        end

        def parse_json_body!(body)
          s = body.to_s
          if s.bytesize > MAX_RESPONSE_BYTES
            raise InvalidResponseError,
                  "Reranker::Cohere: response body exceeds #{MAX_RESPONSE_BYTES} bytes (#{s.bytesize})."
          end
          JSON.parse(s, max_nesting: 32)
        rescue JSON::ParserError => e
          raise InvalidResponseError, "Reranker::Cohere: response is not valid JSON (#{e.message})."
        end

        def build_connection
          require_faraday!
          headers = {
            "Authorization" => "Bearer #{@api_key}",
            "Content-Type"  => "application/json",
            "Accept"        => "application/json",
            "User-Agent"    => "parse-stack-reranker/#{Parse::Stack::VERSION rescue "0"}",
          }
          # base_url must end with a trailing slash so Faraday resolves the
          # relative "rerank" path under /v2/ rather than replacing it.
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
          [0.5 * (2**(attempt - 1)), 30.0].min
        end

        def retry_after_seconds(response)
          ra = response.respond_to?(:headers) ? response.headers["retry-after"] || response.headers["Retry-After"] : nil
          return nil unless ra
          v = ra.to_f
          v.positive? ? [v, 60.0].min : nil
        end

        def validate_api_key!(api_key)
          unless api_key.is_a?(String) && !api_key.empty?
            raise ArgumentError, "Reranker::Cohere: api_key must be a non-empty String."
          end
        end

        def validate_base_url!(base_url)
          uri = URI.parse(base_url)
          unless uri.is_a?(URI::HTTPS) || uri.is_a?(URI::HTTP)
            raise ArgumentError, "Reranker::Cohere: base_url must be http(s) (got #{base_url.inspect})."
          end
        rescue URI::InvalidURIError => e
          raise ArgumentError, "Reranker::Cohere: invalid base_url #{base_url.inspect} (#{e.message})."
        end

        def safe_base_host
          URI.parse(@base_url).host
        rescue StandardError
          "?"
        end

        def require_faraday!
          require "faraday" unless defined?(Faraday)
        rescue LoadError
          raise Error, "Reranker::Cohere requires the `faraday` gem."
        end
      end
    end
  end
end
