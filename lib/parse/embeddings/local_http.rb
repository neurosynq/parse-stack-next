# encoding: UTF-8
# frozen_string_literal: true

require "faraday"
require "ipaddr"
require "json"
require "resolv"
require "uri"
require_relative "provider"
require_relative "../model/file"

module Parse
  module Embeddings
    # Generic OpenAI-compatible local embedding provider. Talks to any
    # server that exposes `POST <base_url>/embeddings` with the OpenAI
    # request/response shape — covers Ollama (`/v1`), LM Studio (`/v1`),
    # vLLM, llama.cpp's `server`, and any reverse-proxy that translates
    # to a local model runner.
    #
    # @example Ollama on the same host
    #   Parse::Embeddings.register(:ollama,
    #     Parse::Embeddings::LocalHTTP.new(
    #       base_url: "http://localhost:11434/v1",
    #       model: "nomic-embed-text",
    #       dimensions: 768,
    #       allow_private_endpoint: true,
    #     ))
    #
    # @example public OpenAI-compatible proxy (e.g. internal gateway on a public DNS name)
    #   Parse::Embeddings.register(:gateway,
    #     Parse::Embeddings::LocalHTTP.new(
    #       base_url: "https://embeddings.example.com/v1",
    #       api_key:  ENV.fetch("GATEWAY_API_KEY"),
    #       model:    "bge-small-en-v1.5",
    #       dimensions: 384,
    #     ))
    #
    # == SSRF gate
    #
    # The `base_url` is resolved at construction time and the resolved
    # addresses are checked against {Parse::File::BLOCKED_CIDRS}
    # (loopback, RFC1918, link-local, cloud-metadata, CGNAT, IPv6 ULA,
    # …). When ANY resolved address falls in a private/internal range,
    # the constructor refuses unless the caller opts in via
    # `allow_private_endpoint: true`.
    #
    # The opt-in is a deliberate, audit-able gate — Parse::Embeddings
    # registration is configuration code, not user input, so opting in
    # to "yes, this base_url really is my Ollama on localhost" is a
    # one-line decision by the operator at boot time. A `Kernel#warn`
    # fires when the opt-in is taken so the choice shows up in operator
    # logs / `bundle exec rake about` output.
    #
    # `http://` base URLs are accepted with `allow_private_endpoint: true`
    # (the typical local-runner deployment), and refused otherwise unless
    # the caller also passes `allow_insecure_base_url: true` (escape
    # hatch for self-signed internal HTTPS proxies fronted by http://).
    #
    # == Why no fixed model whitelist
    #
    # Ollama, LM Studio, and vLLM all serve operator-chosen models —
    # we cannot enumerate "supported" models the way {OpenAI} can. The
    # constructor instead takes the `dimensions:` explicitly, and the
    # provider's {#validate_response!} (inherited) enforces that every
    # returned vector matches that width. Mis-specified dimensions
    # surface as {InvalidResponseError} on the first embed call.
    #
    # == Security
    #
    # * Configure-time SSRF gate (above).
    # * The Faraday connection refuses `proxy:` unless the caller opts
    #   in via `allow_faraday_proxy: true`. Env-proxy autodiscovery is
    #   suppressed by default — same model as {OpenAI}.
    # * `#inspect` (inherited from {Provider}) never surfaces `@api_key`.
    class LocalHTTP < Provider
      class AuthenticationError < Error; end
      class BadRequestError < Error; end
      class RateLimitError < Error; end
      class TransientError < Error; end

      DEFAULT_TIMEOUT      = 30
      DEFAULT_OPEN_TIMEOUT = 5
      DEFAULT_MAX_RETRIES  = 3
      DEFAULT_BATCH_SIZE   = 32
      MAX_RESPONSE_BYTES   = 16 * 1024 * 1024

      # @param base_url [String] required. Must be http(s):// with a host.
      # @param model [String] required. Identifier the local server expects
      #   in the `model` request field. Persisted to `embedding_meta`.
      # @param dimensions [Integer] required. Width of vectors the local
      #   model produces. Enforced by {Provider#validate_response!}.
      # @param api_key [String, nil] optional. When present, sent as
      #   `Authorization: Bearer …`. Local runners typically accept any
      #   value or no header.
      # @param normalize [Boolean] whether the local model returns
      #   unit-normalized vectors. Defaults to `false` (Ollama and most
      #   local models do NOT normalize; bge-* and OpenAI do). Affects
      #   similarity metric selection downstream.
      # @param timeout [Integer] read timeout, seconds.
      # @param open_timeout [Integer] connect timeout, seconds.
      # @param max_retries [Integer] retry attempts on 429/5xx/timeouts.
      # @param embed_batch_size [Integer] inputs per request.
      # @param allow_private_endpoint [Boolean] required when `base_url`
      #   resolves to a private/internal/loopback address. Defaults
      #   `false`; opting in emits a one-time warning per provider
      #   instance.
      # @param allow_insecure_base_url [Boolean] permit `http://` for
      #   PUBLIC base URLs. Defaults `false`. Independent of
      #   `allow_private_endpoint` (which already implies http:// is fine
      #   for the local case).
      # @param allow_faraday_proxy [Boolean] opt in to proxy / env-proxy
      #   autodiscovery. Defaults `false`.
      # @param connection [Faraday::Connection, nil] injection seam.
      def initialize(
        base_url:,
        model:,
        dimensions:,
        api_key: nil,
        normalize: false,
        timeout: DEFAULT_TIMEOUT,
        open_timeout: DEFAULT_OPEN_TIMEOUT,
        max_retries: DEFAULT_MAX_RETRIES,
        embed_batch_size: DEFAULT_BATCH_SIZE,
        allow_private_endpoint: false,
        allow_insecure_base_url: false,
        allow_faraday_proxy: false,
        connection: nil
      )
        validate_model!(model)
        validate_dimensions!(dimensions)
        validate_optional_api_key!(api_key)
        unless [true, false].include?(normalize)
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: normalize must be true or false (got #{normalize.inspect})."
        end
        validate_positive_integer!(:timeout, timeout)
        validate_positive_integer!(:open_timeout, open_timeout)
        validate_non_negative_integer!(:max_retries, max_retries)
        validate_positive_integer!(:embed_batch_size, embed_batch_size)

        sanitized_base_url, resolved_addrs, is_private =
          validate_base_url_and_gate_ssrf!(base_url,
                                           allow_private_endpoint: allow_private_endpoint,
                                           allow_insecure_base_url: allow_insecure_base_url)
        if is_private
          # Audit log. Emits once per instance — Kernel#warn so it lands
          # on stderr and any logger that captures it. Operators running
          # a hardened environment can grep this to confirm every
          # private-endpoint opt-in was intentional.
          warn "Parse::Embeddings::LocalHTTP: allow_private_endpoint=true for #{sanitized_base_url} — " \
               "resolved to private address(es) #{resolved_addrs.map(&:to_s).inspect}."
        end

        @base_url = sanitized_base_url
        @model = model
        @dimensions = dimensions
        @api_key = api_key
        @normalize = normalize
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

      def normalize?
        @normalize
      end

      def supports_input_type?
        # The OpenAI-compatible local runners do not asymmetrize. Some
        # models (bge-*) have a documented query prefix, but the local
        # server itself doesn't expose `input_type:` — callers wrap the
        # query text instead. We accept the kwarg for cache-key stability
        # but drop it at the wire level.
        false
      end

      # @param strings [Array<String>] inputs.
      # @param input_type [Symbol] accepted for forward compatibility,
      #   ignored at the wire level.
      # @return [Array<Array<Float>>] vectors aligned 1:1 with `strings`.
      def embed_text(strings, input_type: :search_document)
        unless strings.is_a?(Array)
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP#embed_text expects Array<String> (got #{strings.class})."
        end
        return [] if strings.empty?
        strings.each_with_index do |s, i|
          unless s.is_a?(String)
            raise ArgumentError,
                  "Parse::Embeddings::LocalHTTP#embed_text strings[#{i}] is not a String (#{s.class})."
          end
          if s.empty?
            raise ArgumentError,
                  "Parse::Embeddings::LocalHTTP#embed_text strings[#{i}] is empty; local runners typically reject empty inputs."
          end
        end

        body = { input: strings, model: @model }

        instrument_embed(strings.length, input_type) do |emit_payload|
          payload = post_embeddings(body)
          # Local runners may or may not include `usage`. When present,
          # forward total_tokens to the AS::N payload.
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
          "Content-Type" => "application/json",
          "Accept" => "application/json",
          "User-Agent" => "parse-stack-embeddings/#{user_agent_version}",
        }
        headers["Authorization"] = "Bearer #{@api_key}" if @api_key

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
              raise TransientError, "Parse::Embeddings::LocalHTTP: #{e.class} after #{attempts} attempt(s)."
            end
            sleep(backoff_seconds(attempts))
            next
          end

          status = response.status
          return parse_json_body!(response.body) if status >= 200 && status < 300

          if status == 401
            raise AuthenticationError,
                  "Parse::Embeddings::LocalHTTP: 401 Unauthorized — check api_key."
          end
          if status == 429
            if attempts > @max_retries
              raise RateLimitError,
                    "Parse::Embeddings::LocalHTTP: 429 rate limited after #{attempts} attempt(s)."
            end
            sleep(retry_after_seconds(response) || backoff_seconds(attempts))
            next
          end
          if status >= 500
            if attempts > @max_retries
              raise TransientError,
                    "Parse::Embeddings::LocalHTTP: #{status} after #{attempts} attempt(s)."
            end
            sleep(backoff_seconds(attempts))
            next
          end
          raise BadRequestError,
                "Parse::Embeddings::LocalHTTP: #{status} from POST /embeddings."
        end
      end

      def parse_json_body!(body)
        s = body.to_s
        if s.bytesize > MAX_RESPONSE_BYTES
          raise InvalidResponseError,
                "Parse::Embeddings::LocalHTTP: response body exceeds #{MAX_RESPONSE_BYTES} bytes " \
                "(#{s.bytesize}). Refusing to parse."
        end
        JSON.parse(s, max_nesting: 32)
      rescue JSON::ParserError => e
        raise InvalidResponseError,
              "Parse::Embeddings::LocalHTTP: response is not valid JSON (#{e.message})."
      end

      # Accept the OpenAI-compatible shape. Some local runners omit
      # `index` or return data in request order without it; tolerate
      # both forms by falling back to positional alignment when the
      # field is missing across the entire response.
      def extract_vectors!(payload, input_count)
        unless payload.is_a?(Hash)
          raise InvalidResponseError,
                "Parse::Embeddings::LocalHTTP: response body is not a JSON object."
        end
        data = payload["data"]
        unless data.is_a?(Array)
          raise InvalidResponseError,
                "Parse::Embeddings::LocalHTTP: response.data is not an Array."
        end
        if data.length != input_count
          raise InvalidResponseError,
                "Parse::Embeddings::LocalHTTP: response.data.length #{data.length} != input count #{input_count}."
        end
        all_have_index = data.all? { |e| e.is_a?(Hash) && e["index"].is_a?(Integer) }
        if all_have_index
          sorted = data.map do |entry|
            idx = entry["index"]
            unless idx >= 0 && idx < input_count
              raise InvalidResponseError,
                    "Parse::Embeddings::LocalHTTP: response.data entry index #{idx} out of range."
            end
            [idx, entry["embedding"]]
          end
          if sorted.map(&:first).uniq.length != sorted.length
            raise InvalidResponseError,
                  "Parse::Embeddings::LocalHTTP: duplicate index in response.data."
          end
          sorted.sort_by(&:first).map(&:last)
        else
          data.each_with_index.map do |entry, i|
            unless entry.is_a?(Hash)
              raise InvalidResponseError,
                    "Parse::Embeddings::LocalHTTP: response.data[#{i}] is not a JSON object."
            end
            entry["embedding"]
          end
        end
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

      # @return [Array(String, Array<IPAddr>, Boolean)] sanitized URL,
      #   resolved addresses (may be empty when unresolved AND opted-in
      #   for a private endpoint via hostname), and a flag indicating
      #   whether the host resolved to a private address.
      def validate_base_url_and_gate_ssrf!(base_url, allow_private_endpoint:, allow_insecure_base_url:)
        unless base_url.is_a?(String) && !base_url.empty?
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: base_url must be a non-empty String."
        end
        begin
          uri = URI.parse(base_url)
        rescue URI::InvalidURIError => e
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: base_url is not a valid URL (#{e.message})."
        end
        unless %w[http https].include?(uri.scheme)
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: base_url must be http(s):// (got scheme #{uri.scheme.inspect})."
        end
        host = uri.host
        if host.nil? || host.empty?
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: base_url must include a host."
        end
        if uri.userinfo
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: base_url must not contain userinfo (credentials). " \
                "Use the api_key parameter and a clean URL."
        end

        resolved = Parse::File.resolve_addresses(host)
        if resolved.empty?
          # DNS failure at construction time. Without resolved addresses
          # the SSRF gate has nothing to evaluate, so a hostname that
          # fails to resolve now but resolves later (lazy propagation,
          # attacker-timed flip, split-horizon DNS) would skip the gate
          # entirely. Refuse fail-closed unless the operator has already
          # opted into private endpoints — in which case a transient
          # DNS failure is an acceptable trade-off for the lazy-runner
          # case (Ollama starting after the Rails boot).
          unless allow_private_endpoint
            raise ArgumentError,
                  "Parse::Embeddings::LocalHTTP: could not resolve base_url host #{host.inspect}. " \
                  "Pass allow_private_endpoint: true if the host is intentionally local/transient."
          end
        end
        # Empty-resolution under allow_private_endpoint is treated as
        # private for the http:// scheme gate below, since the operator
        # has already asserted local-class trust.
        is_private =
          if resolved.empty?
            allow_private_endpoint
          else
            resolved.any? { |ip| Parse::File::BLOCKED_CIDRS.any? { |cidr| cidr.include?(ip) } }
          end

        if is_private && !allow_private_endpoint
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: refusing base_url that resolves to a private/internal " \
                "address (#{resolved.map(&:to_s).inspect}). Pass allow_private_endpoint: true to opt in."
        end

        # http:// scheme: allowed when the endpoint is private (the
        # typical local-runner case) OR the caller has explicitly
        # opted into insecure public HTTP. Refused otherwise.
        if uri.scheme == "http" && !is_private && !allow_insecure_base_url
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: refusing http:// base_url for a public host. " \
                "Pass allow_private_endpoint: true (private hosts) or allow_insecure_base_url: true " \
                "(public hosts, escape hatch only)."
        end

        [uri.to_s, resolved, is_private]
      end

      def validate_model!(model)
        unless model.is_a?(String) && !model.empty?
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: model must be a non-empty String."
        end
      end

      def validate_dimensions!(dimensions)
        unless dimensions.is_a?(Integer) && dimensions.positive?
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: dimensions must be a positive Integer (got #{dimensions.inspect})."
        end
      end

      def validate_optional_api_key!(api_key)
        return if api_key.nil?
        unless api_key.is_a?(String) && !api_key.empty?
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: api_key, when provided, must be a non-empty String."
        end
      end

      def validate_positive_integer!(name, value)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: #{name} must be a positive Integer (got #{value.inspect})."
        end
      end

      def validate_non_negative_integer!(name, value)
        unless value.is_a?(Integer) && value >= 0
          raise ArgumentError,
                "Parse::Embeddings::LocalHTTP: #{name} must be a non-negative Integer (got #{value.inspect})."
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
