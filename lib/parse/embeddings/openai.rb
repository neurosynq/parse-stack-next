# encoding: UTF-8
# frozen_string_literal: true

require "faraday"
require "json"
require "uri"
require_relative "provider"

module Parse
  module Embeddings
    # OpenAI embeddings provider. Wraps `POST /v1/embeddings` and the
    # `text-embedding-3-small`, `text-embedding-3-large`, and legacy
    # `text-embedding-ada-002` models.
    #
    # @example registration
    #   Parse::Embeddings.register(:openai,
    #     Parse::Embeddings::OpenAI.new(
    #       api_key: ENV.fetch("OPENAI_API_KEY"),
    #       model:   "text-embedding-3-small",
    #     ))
    #
    # == Security
    #
    # * The Faraday connection refuses `ssl: { verify: false }` on the
    #   production HTTPS base URL and refuses `proxy:` unless the caller
    #   opts in via `allow_faraday_proxy: true`. Env-proxy autodiscovery
    #   (`HTTPS_PROXY` etc.) is suppressed by default — same model as
    #   `Parse::Client`.
    # * `#inspect` (inherited from {Provider}) never surfaces `@api_key`.
    # * `Authorization`, `OpenAI-Organization`, and `OpenAI-Project`
    #   headers are added to {Parse::Middleware::BodyBuilder::REDACTED_HEADERS}
    #   so Faraday logging cannot leak them.
    #
    # == Errors
    #
    # All errors inherit from {Parse::Embeddings::Error}:
    #
    # * {AuthenticationError} — 401 from OpenAI.
    # * {RateLimitError}      — 429 from OpenAI (retried up to `max_retries`).
    # * {BadRequestError}     — 400/404 (not retried).
    # * {TransientError}      — 5xx or network/timeout (retried).
    # * {InvalidResponseError} — response shape violates the contract.
    class OpenAI < Provider
      # Subclasses of {Parse::Embeddings::Error} specific to OpenAI's
      # HTTP boundary. Concrete enough for retry middleware to switch
      # on; opaque enough that callers don't depend on response bodies.
      class AuthenticationError < Error; end
      class BadRequestError < Error; end
      class RateLimitError < Error; end
      class TransientError < Error; end

      DEFAULT_BASE_URL    = "https://api.openai.com/v1"
      DEFAULT_MODEL       = "text-embedding-3-small"
      DEFAULT_TIMEOUT     = 30
      DEFAULT_OPEN_TIMEOUT = 5
      DEFAULT_MAX_RETRIES = 3
      DEFAULT_BATCH_SIZE  = 100

      # Hard ceiling on the response body we'll parse. A legitimate
      # OpenAI embeddings response for the worst-case configuration
      # (100 inputs × text-embedding-3-large, 3072 floats × ~12 chars
      # per encoded float) is ~3.6 MB. We allow 16 MB to leave generous
      # headroom for usage telemetry and future fields, while still
      # bounding the buffer an adversarial / misconfigured base_url
      # could ship at us before the 30s timeout fires.
      MAX_RESPONSE_BYTES = 16 * 1024 * 1024

      # Native vector widths for each supported model. `text-embedding-3-*`
      # also accept a `dimensions:` parameter that truncates the output
      # (Matryoshka-style) — when set, it overrides the native width.
      MODEL_DEFAULT_DIMENSIONS = {
        "text-embedding-3-small" => 1536,
        "text-embedding-3-large" => 3072,
        "text-embedding-ada-002" => 1536,
      }.freeze

      # Max input tokens per item for the supported models. Provided as
      # a chunker hint via {#max_input_tokens}.
      MODEL_MAX_INPUT_TOKENS = {
        "text-embedding-3-small" => 8191,
        "text-embedding-3-large" => 8191,
        "text-embedding-ada-002" => 8191,
      }.freeze

      # @param api_key [String] required. Sent as `Authorization: Bearer …`.
      # @param model [String] one of {MODEL_DEFAULT_DIMENSIONS}'s keys.
      # @param dimensions [Integer, nil] override output width (3-series
      #   only). When nil, uses the model's native dimensions.
      # @param base_url [String] override (Azure / proxy). Must be HTTPS
      #   unless `allow_insecure_base_url: true`.
      # @param organization [String, nil] sent as `OpenAI-Organization`.
      # @param project [String, nil] sent as `OpenAI-Project`.
      # @param timeout [Integer] read timeout, seconds.
      # @param open_timeout [Integer] connect timeout, seconds.
      # @param max_retries [Integer] retry attempts on 429/5xx/timeouts.
      # @param embed_batch_size [Integer] inputs per request.
      # @param allow_faraday_proxy [Boolean] opt in to proxy / env-proxy
      #   autodiscovery. Defaults `false` — matches `Parse::Client`.
      # @param allow_insecure_base_url [Boolean] permit `http://` base
      #   (local Ollama-shaped proxies). Defaults `false`.
      # @param connection [Faraday::Connection, nil] injection seam for
      #   tests. When nil, a connection is built from the other options.
      def initialize(
        api_key:,
        model: DEFAULT_MODEL,
        dimensions: nil,
        base_url: DEFAULT_BASE_URL,
        organization: nil,
        project: nil,
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
        @organization = organization
        @project = project
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
        # OpenAI's text-embedding-3-* and ada-002 all return
        # unit-normalized vectors. Documented in the API reference.
        true
      end

      def supports_input_type?
        # OpenAI does NOT distinguish search_query vs search_document.
        # We accept the kwarg (for cache-key stability across providers)
        # but it does not affect the request payload. See {#embed_text}.
        false
      end

      # @param strings [Array<String>] inputs.
      # @param input_type [Symbol] accepted for forward compatibility,
      #   ignored at the wire level — OpenAI does not asymmetrize
      #   query vs document. The base {#embed_text_batched} threads the
      #   value through; this implementation drops it.
      # @return [Array<Array<Float>>] vectors aligned 1:1 with `strings`.
      def embed_text(strings, input_type: :search_document)
        unless strings.is_a?(Array)
          raise ArgumentError,
                "Parse::Embeddings::OpenAI#embed_text expects Array<String> (got #{strings.class})."
        end
        return [] if strings.empty?
        strings.each_with_index do |s, i|
          unless s.is_a?(String)
            raise ArgumentError,
                  "Parse::Embeddings::OpenAI#embed_text strings[#{i}] is not a String (#{s.class})."
          end
          if s.empty?
            raise ArgumentError,
                  "Parse::Embeddings::OpenAI#embed_text strings[#{i}] is empty; OpenAI rejects empty inputs."
          end
        end

        body = { input: strings, model: @model }
        # `dimensions:` is only valid for text-embedding-3-*. Sending it
        # to ada-002 yields a 400. When the caller specified an override
        # we always forward it; when the model is 3-series and we're
        # using the default, we still forward to make the contract
        # explicit (and to assert the server returns what we expect).
        body[:dimensions] = @dimensions if @model.start_with?("text-embedding-3-")

        instrument_embed(strings.length, input_type) do |emit_payload|
          payload = post_embeddings(body)
          # OpenAI's response envelope carries `usage: { prompt_tokens,
          # total_tokens }`. Forward total_tokens (the operator-facing
          # cost number) into the AS::N payload so cost subscribers can
          # budget embedding spend on the same footing as
          # `parse.agent.tool_call` token cost. Defensive on shape — a
          # mock / proxy that strips the usage block must not crash the
          # request path.
          if payload.is_a?(Hash) && payload["usage"].is_a?(Hash)
            tt = payload["usage"]["total_tokens"]
            emit_payload[:total_tokens] = tt if tt.is_a?(Integer) && tt >= 0
          end
          vectors = extract_vectors!(payload, strings.length)
          validate_response!(strings.length, vectors)
        end
      end

      # Override the Provider's safe inspect to add OpenAI-specific
      # non-sensitive attrs. `@base_url` is redacted to host-only
      # because operators may point this provider at an Azure / Ollama
      # endpoint they consider sensitive — the same policy
      # `post_embeddings` applies when raising on transient errors.
      def inspect_attrs
        super.merge(base: safe_base_host, retries: @max_retries)
      end

      protected

      # Subclass extension points. Azure/Ollama/Voyage adapters can
      # override these to swap the auth header shape, the URL path, the
      # JSON envelope, or the retry policy without re-implementing the
      # validation layer above.
      #
      # `build_connection`     — Faraday wiring (override for Azure
      #                          `api-key:` header form).
      # `post_embeddings`      — request + retry loop.
      # `parse_json_body!`     — JSON parse + bounded-size check.
      # `extract_vectors!`     — response envelope shape.
      # `backoff_seconds`      — sleep schedule between retries.
      # `retry_after_seconds`  — Retry-After header interpretation.

      def build_connection
        headers = {
          "Authorization" => "Bearer #{@api_key}",
          "Content-Type" => "application/json",
          "Accept" => "application/json",
          "User-Agent" => "parse-stack-embeddings/#{user_agent_version}",
        }
        headers["OpenAI-Organization"] = @organization if @organization
        headers["OpenAI-Project"] = @project if @project

        # Mirror Parse::Client: when proxy is NOT explicitly opted in,
        # pass `proxy: nil` to suppress Faraday's automatic discovery of
        # HTTPS_PROXY / HTTP_PROXY env vars. When opted in, omit the
        # key entirely so Faraday's normal env-discovery runs.
        faraday_opts = { url: @base_url, headers: headers }
        faraday_opts[:proxy] = nil unless @allow_faraday_proxy

        conn = Faraday.new(**faraday_opts) do |f|
          f.options.timeout = @timeout
          f.options.open_timeout = @open_timeout
          f.adapter Faraday.default_adapter
        end
        # Belt-and-suspenders mirroring Parse::Client (see client.rb): Faraday may
        # still synthesise a ProxyOptions from env regardless of the `proxy: nil`
        # we passed in opts, so we re-assert post-construction.
        conn.proxy = nil if !@allow_faraday_proxy && conn.respond_to?(:proxy=)
        conn
      end

      # Single POST with bounded retry. Inline implementation — we don't
      # depend on faraday-retry (not in the runtime gemspec) and the
      # logic is small enough to audit in place.
      def post_embeddings(body)
        attempts = 0
        loop do
          attempts += 1
          begin
            response = @connection.post("embeddings") do |req|
              req.body = body.to_json
            end
          rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
            # Surface e.class only — Faraday's message often contains
            # the full URL (which may be a customer Azure/Ollama base)
            # and we don't want that flowing into error trackers.
            if attempts > @max_retries
              raise TransientError, "Parse::Embeddings::OpenAI: #{e.class} after #{attempts} attempt(s)."
            end
            sleep(backoff_seconds(attempts))
            next
          end

          status = response.status
          return parse_json_body!(response.body) if status >= 200 && status < 300

          if status == 401
            raise AuthenticationError,
                  "Parse::Embeddings::OpenAI: 401 Unauthorized — check api_key."
          end
          if status == 429
            if attempts > @max_retries
              raise RateLimitError,
                    "Parse::Embeddings::OpenAI: 429 rate limited after #{attempts} attempt(s)."
            end
            sleep(retry_after_seconds(response) || backoff_seconds(attempts))
            next
          end
          if status >= 500
            if attempts > @max_retries
              raise TransientError,
                    "Parse::Embeddings::OpenAI: #{status} after #{attempts} attempt(s)."
            end
            sleep(backoff_seconds(attempts))
            next
          end
          # 4xx other than 401/429 — don't retry. Surface the error
          # without the response body (which may echo input we don't
          # want in error tracking) and without @base_url (which may be
          # a customer-configured Azure/Ollama URL captured by error
          # trackers).
          raise BadRequestError,
                "Parse::Embeddings::OpenAI: #{status} from POST /embeddings."
        end
      end

      def parse_json_body!(body)
        # NOTE: we no longer short-circuit on Hash. A pre-parsed Hash
        # from a test adapter bypassed the MAX_RESPONSE_BYTES check
        # AND the max_nesting cap — both defenses against a misbehaving
        # adapter or operator-configured base_url. Tests that want to
        # inject a parsed hash should do so via the `connection:` seam
        # which still runs through Faraday and emits a String body.
        s = body.to_s
        if s.bytesize > MAX_RESPONSE_BYTES
          raise InvalidResponseError,
                "Parse::Embeddings::OpenAI: response body exceeds #{MAX_RESPONSE_BYTES} bytes " \
                "(#{s.bytesize}). Refusing to parse."
        end
        # `max_nesting:` caps JSON's recursion depth to defend against
        # adversarial payloads on a customer-configured base_url. A
        # well-formed OpenAI response is at most ~5 levels deep.
        JSON.parse(s, max_nesting: 32)
      rescue JSON::ParserError => e
        raise InvalidResponseError,
              "Parse::Embeddings::OpenAI: response is not valid JSON (#{e.message})."
      end

      def extract_vectors!(payload, input_count)
        unless payload.is_a?(Hash)
          raise InvalidResponseError,
                "Parse::Embeddings::OpenAI: response body is not a JSON object."
        end
        data = payload["data"]
        unless data.is_a?(Array)
          raise InvalidResponseError,
                "Parse::Embeddings::OpenAI: response.data is not an Array."
        end
        if data.length != input_count
          raise InvalidResponseError,
                "Parse::Embeddings::OpenAI: response.data.length #{data.length} != input count #{input_count}."
        end
        # OpenAI documents that `data[].index` reflects request order,
        # but the API spec allows out-of-order responses. Sort defensively.
        sorted = data.each_with_index.map do |entry, i|
          unless entry.is_a?(Hash)
            raise InvalidResponseError,
                  "Parse::Embeddings::OpenAI: response.data[#{i}] is not a JSON object."
          end
          idx = entry["index"]
          unless idx.is_a?(Integer) && idx >= 0 && idx < input_count
            raise InvalidResponseError,
                  "Parse::Embeddings::OpenAI: response.data[#{i}].index #{idx.inspect} out of range."
          end
          [idx, entry["embedding"]]
        end
        indices = sorted.map(&:first)
        if indices.uniq.length != indices.length
          raise InvalidResponseError,
                "Parse::Embeddings::OpenAI: duplicate index in response.data."
        end
        sorted.sort_by(&:first).map(&:last)
      end

      # Exponential backoff with deterministic ceiling.
      #
      # NOTE: no jitter. {Parse::Client#request} (lib/parse/client.rb)
      # multiplies its sleep by `0.75 + rand * 0.5` to de-correlate
      # fleet-wide retries. We deliberately omit that here: this
      # provider is intended to be driven by a single rate-limited
      # job runner (Sidekiq throttler, AS::Worker bucket, etc.) that
      # already paces concurrent requests against OpenAI's rate
      # limits. Per-call jitter on top of an external limiter only
      # masks coordination bugs. Operators driving this provider from
      # an unbounded worker pool should add their own jitter
      # (subclass and override) — otherwise a fleet-wide 429 will
      # synchronize the retry storm exponentially.
      def backoff_seconds(attempt)
        # 0.5, 1.0, 2.0, 4.0, 8.0 …  capped at 30s
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
                "Parse::Embeddings::OpenAI: api_key must be a non-empty String."
        end
      end

      def validate_model!(model)
        unless MODEL_DEFAULT_DIMENSIONS.key?(model)
          raise ArgumentError,
                "Parse::Embeddings::OpenAI: unknown model #{model.inspect}. " \
                "Supported: #{MODEL_DEFAULT_DIMENSIONS.keys.inspect}."
        end
      end

      def validate_dimensions!(model, dimensions)
        return if dimensions.nil?
        unless dimensions.is_a?(Integer) && dimensions.positive?
          raise ArgumentError,
                "Parse::Embeddings::OpenAI: dimensions must be a positive Integer (got #{dimensions.inspect})."
        end
        native = MODEL_DEFAULT_DIMENSIONS.fetch(model)
        if dimensions > native
          raise ArgumentError,
                "Parse::Embeddings::OpenAI: dimensions #{dimensions} exceeds native #{native} for #{model}."
        end
        if !model.start_with?("text-embedding-3-") && dimensions != native
          raise ArgumentError,
                "Parse::Embeddings::OpenAI: model #{model.inspect} does not support custom dimensions " \
                "(only text-embedding-3-* do)."
        end
      end

      # Parse base_url with URI, reject userinfo and non-http(s) schemes,
      # and return a normalized credential-free string suitable for safe
      # interpolation into log lines and error messages. Refuses
      # `http://` unless the caller opts in via `allow_insecure_base_url`.
      def validate_base_url!(base_url, allow_insecure)
        unless base_url.is_a?(String) && !base_url.empty?
          raise ArgumentError,
                "Parse::Embeddings::OpenAI: base_url must be a non-empty String."
        end
        begin
          uri = URI.parse(base_url)
        rescue URI::InvalidURIError => e
          raise ArgumentError,
                "Parse::Embeddings::OpenAI: base_url is not a valid URL (#{e.message})."
        end
        unless %w[http https].include?(uri.scheme)
          raise ArgumentError,
                "Parse::Embeddings::OpenAI: base_url must be http(s):// (got scheme #{uri.scheme.inspect})."
        end
        if uri.scheme == "http" && !allow_insecure
          raise ArgumentError,
                "Parse::Embeddings::OpenAI: refusing http:// base_url. " \
                "Pass allow_insecure_base_url: true to opt in (local proxies only)."
        end
        if uri.host.nil? || uri.host.empty?
          raise ArgumentError,
                "Parse::Embeddings::OpenAI: base_url must include a host."
        end
        # Reject embedded credentials outright. `https://user:pass@host/`
        # would otherwise leak via inspect, error messages, and any
        # error-tracker that captures the URL.
        if uri.userinfo
          raise ArgumentError,
                "Parse::Embeddings::OpenAI: base_url must not contain userinfo (credentials). " \
                "Use the api_key parameter and a clean URL."
        end
        # Return a normalized, credential-free string. We round-trip
        # through URI so callers don't accidentally inject userinfo via
        # later concatenation.
        uri.to_s
      end

      def validate_positive_integer!(name, value)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError,
                "Parse::Embeddings::OpenAI: #{name} must be a positive Integer (got #{value.inspect})."
        end
      end

      def validate_non_negative_integer!(name, value)
        unless value.is_a?(Integer) && value >= 0
          raise ArgumentError,
                "Parse::Embeddings::OpenAI: #{name} must be a non-negative Integer (got #{value.inspect})."
        end
      end

      def user_agent_version
        defined?(Parse::Stack::VERSION) ? Parse::Stack::VERSION : "unknown"
      end

      # Host-only form of the configured base URL — for {#inspect_attrs}.
      # Operators may set @base_url to an Azure deployment URL or an
      # internal Ollama endpoint; surfacing the full URL via #inspect
      # would put that in any error tracker / log scrape that captures
      # `.inspect`. Host alone is enough to identify the provider in
      # dev logs without leaking deployment paths or query strings.
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
