# encoding: UTF-8
# frozen_string_literal: true

require "faraday"
require_relative "response"
require_relative "protocol"
require "active_support"
require "active_support/core_ext"
require "active_model/serializers/json"
require "json"
require "set"
require_relative "../terminal_safe"

module Parse

  # @!attribute self.logging
  # Sets {Parse::Middleware::BodyBuilder} logging.
  # You may specify `:debug` for additional verbosity.
  # @return (see Parse::Middleware::BodyBuilder.logging)
  def self.logging
    Parse::Middleware::BodyBuilder.logging
  end
  # @!visibility private
  def self.logging=(value)
    Parse::Middleware::BodyBuilder.logging = value
  end

  # Namespace for Parse-Stack related middleware.
  module Middleware
    # This middleware takes an incoming Parse response, after an outgoing request,
    # and creates a Parse::Response object.
    class BodyBuilder < Faraday::Middleware
      include Parse::Protocol
      # Header sent when a GET requests exceeds the limit.
      HTTP_METHOD_OVERRIDE = "X-Http-Method-Override"
      # Maximum url length for most server requests before HTTP Method Override is used.
      MAX_URL_LENGTH = 2_000.freeze
      # Fields that should be redacted from log output.
      #
      # Covers MFA material (`recovery` codes and the `secret` returned by
      # MFA enrollment, also under `authDataResponse`) and the storage-form
      # credential columns a raw MongoDB document carries (`_session_token`,
      # `_hashed_password`, and the reset/verify tokens). Keys starting with
      # {SENSITIVE_KEY_PREFIXES} (per-provider `_auth_data_<provider>`
      # columns) are redacted too.
      SENSITIVE_FIELDS = %w[
        password token sessionToken session_token access_token authData
        masterKey master_key apiKey api_key clientKey client_key
        javascriptKey javascript_key refreshToken refresh_token
        recovery recoveryCodes recovery_codes authDataResponse secret
        _session_token _hashed_password _email_verify_token
        _perishable_token _password_history
      ].freeze
      # Key prefixes whose values are always redacted.
      SENSITIVE_KEY_PREFIXES = %w[_auth_data_].freeze
      # A credential value: a double- or single-quoted string (with escapes),
      # taken whole so a quoted value with spaces is redacted entirely, or an
      # unquoted run up to a delimiter.
      SENSITIVE_VALUE = /(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^"'&\s,}\]]+)/
      SENSITIVE_PATTERN = /(#{(SENSITIVE_FIELDS + SENSITIVE_KEY_PREFIXES.map { |p| "#{p}\\w+" }).join("|")})(["']?\s*[=:>]\s*)(#{SENSITIVE_VALUE.source})/i
      # Credential header names whose value is redacted when they appear as
      # text (`X-Parse-Master-Key: mk`, `Authorization: Bearer x`), for
      # example in an error message or a pasted request. Real request
      # headers are redacted through {REDACTED_HEADERS}.
      SENSITIVE_HEADER_NAMES = %w[
        X-Parse-Master-Key X-Parse-REST-API-Key X-Parse-Session-Token
        X-Parse-Javascript-Key X-Parse-Client-Key X-Parse-Webhook-Key
        Authorization
      ].freeze
      # Header-shaped text: a credential header name, a `:` or `=`
      # separator, an optional auth scheme (`Bearer`, `Basic`, `Token`),
      # then the value.
      SENSITIVE_HEADER_PATTERN = /(#{SENSITIVE_HEADER_NAMES.map { |n| Regexp.escape(n) }.join("|")})(["']?\s*[=:]\s*)((?:bearer|basic|token)\s+)?(#{SENSITIVE_VALUE.source})/i
      # Lookup set of sensitive field names for structural (JSON) redaction
      # — case-insensitive match on the key, not the value. Walks the parsed
      # structure so nested objects like {"password":{"nested":"value"}}
      # and escaped-quote payloads (which the regex misses) are scrubbed.
      SENSITIVE_FIELDS_SET = SENSITIVE_FIELDS.map(&:downcase).to_set.freeze
      # Placeholder used in place of redacted values.
      REDACTED_PLACEHOLDER = "[FILTERED]"
      # Minimum length at which a numeric-only Array in a logged JSON
      # body is compacted to a single placeholder string instead of
      # printed verbatim. Two concerns drive this:
      #
      # 1. **Noise.** A 1536-float OpenAI embedding inlines as ~25 KB of
      #    JSON per logged row. Aggregation pipelines with
      #    `$vectorSearch.queryVector` and any save/fetch carrying a
      #    `:vector` field would otherwise drown operator logs.
      # 2. **Sensitivity.** Embeddings are reversible-by-similarity:
      #    an attacker who scrapes operator logs can reconstruct
      #    high-level features of the source text (topic, sentiment,
      #    sometimes near-verbatim phrases for short inputs) by
      #    nearest-neighbor lookup against a public model.
      #
      # Threshold rationale: 32 is well below every common embedding
      # width (BGE-small 384, Cohere 1024, OpenAI small 1536, OpenAI
      # large 3072) and well above any normal Parse Array property
      # (tags, role lists, etc.). Numeric-only check additionally
      # protects normal long arrays of strings/objects.
      LOG_VECTOR_COMPACT_THRESHOLD = 32
      # Request headers that must never be printed verbatim in debug logs.
      # Matched case-insensitively against Faraday header keys.
      REDACTED_HEADERS = [
        Parse::Protocol::MASTER_KEY,
        Parse::Protocol::API_KEY,
        Parse::Protocol::SESSION_TOKEN,
        # Caller-supplied Cloud Code context (X-Parse-Cloud-Context) carries
        # `context.to_json`, which may hold PII / request metadata. Redact it in
        # the header log; the body/as_json log path scrubs sensitive sub-values
        # of context separately.
        Parse::Protocol::CLOUD_CONTEXT,
        "X-Parse-JavaScript-Key",
        "Authorization",
        "Cookie",
        # Embedding-provider credentials (Parse::Embeddings::OpenAI and
        # forthcoming Cohere/Voyage adapters). These never touch Parse
        # Server itself, but they share the same Faraday log path when a
        # caller mounts the embeddings connection through Parse logging.
        # OpenAI's official auth header is `Authorization: Bearer …`
        # (already covered above); Organization/Project are listed here
        # since they're account-identifying metadata operators may not
        # want to publish. `X-Api-Key` and `Anthropic-Api-Key` are
        # reserved for forthcoming non-OpenAI providers.
        "X-Api-Key",
        "OpenAI-Organization",
        "OpenAI-Project",
        "Anthropic-Api-Key",
        # Cohere, Voyage, Jina, and DashScope (Qwen) use Bearer auth
        # (covered by "Authorization" above), but some operators front
        # them with a proxy that rewrites to a vendor-specific header.
        # These are listed defensively so a future header-form switch
        # doesn't silently leak keys into Faraday logs. `Api-Key` is the
        # bare form some vendor SDKs and proxies use; covered for parity.
        "Cohere-Api-Key",
        "Voyage-Api-Key",
        "Jina-Api-Key",
        "Api-Key",
        "X-DashScope-Api-Key",
        "DashScope-Api-Key",
      ].map(&:downcase).freeze

      class << self
        # Allows logging. Set to `true` to enable logging, `false` to disable.
        # You may specify `:debug` for additional verbosity.
        # @return [Boolean]
        attr_accessor :logging
      end

      # Redacts sensitive fields from a string for safe logging.
      #
      # Two passes run in sequence so that no payload shape leaks secrets:
      #
      # 1. **Structural pass.** If the body (after whitespace trim) parses as
      #    JSON, the parsed structure is walked recursively. Any value whose
      #    key matches `SENSITIVE_FIELDS_SET` (case-insensitive) is replaced.
      #    String values that themselves look like JSON are recursively
      #    parsed and scrubbed — catches `{"body":"{\"password\":\"x\"}"}`
      #    payloads.
      #
      # 2. **Regex pass.** The result of the structural pass (or the original
      #    string if parsing failed) is always also run through the
      #    `SENSITIVE_PATTERN` regex as defense-in-depth. This catches form-
      #    encoded bodies, partial JSON, escaped-quote payloads, and string
      #    array elements like `["password=hunter2"]` that the structural
      #    walker can't redact in-place.
      # @param str [String] the string to redact.
      # @return [String] the redacted string.
      def self.redact(str)
        s = str.to_s
        return s if s.empty?
        if (parsed = try_parse_json(s))
          scrubbed = scrub_sensitive!(parsed)
          compact_vectors!(scrubbed)
          begin
            # Text patterns run on each string value before encoding, never
            # on the encoded JSON: escaped quotes inside a value
            # (`password=\"x\"`) would defeat them and could corrupt the JSON.
            return redact_string_values!(scrubbed).to_json
          rescue StandardError
            # Fall through to the text pass on the original string.
          end
        end
        redact_patterns(s)
      end

      # Apply {redact_patterns} to every String value in a parsed JSON
      # structure, in place. Keys are left alone (the structural pass already
      # replaced the values of sensitive keys).
      # @param obj [Object] a parsed JSON value.
      # @return [Object] obj.
      def self.redact_string_values!(obj)
        case obj
        when Hash
          obj.each { |k, v| obj[k] = v.is_a?(String) ? redact_patterns(v) : redact_string_values!(v) }
        when Array
          obj.map! { |v| v.is_a?(String) ? redact_patterns(v) : redact_string_values!(v) }
        end
        obj
      end

      # The regex pass of {redact} on its own: replaces values that follow
      # a credential field name (`password=x`, `"sessionToken":"r:x"`) or a
      # credential header name (`X-Parse-Master-Key: mk`,
      # `Authorization: Bearer x`). Use it on text that is not JSON, or on
      # JSON that has already been scrubbed structurally.
      # @param str [String]
      # @return [String]
      def self.redact_patterns(str)
        s = str.to_s
        return s if s.empty?
        s = s.gsub(SENSITIVE_PATTERN) do
          key_part = $1
          sep_part = $2
          val_part = $3
          # Skip values that the structural pass already redacted. The
          # value class `[^"&\s,}\]]+` stops at the bracket, so without
          # this a second pass would turn `"[FILTERED]"` into
          # `[FILTERED]]`.
          "#{key_part}#{sep_part}#{redacted_value(val_part)}"
        end
        s.gsub(SENSITIVE_HEADER_PATTERN) do
          name_part = $1
          sep_part = $2
          scheme_part = $3
          val_part = $4
          "#{name_part}#{sep_part}#{scheme_part}#{redacted_value(val_part)}"
        end
      end

      # @!visibility private
      def self.already_redacted?(value)
        value == "[FILTERED" || value == REDACTED_PLACEHOLDER
      end

      # @!visibility private
      # The placeholder for a matched value, keeping the value's own quotes
      # so quoted text (and JSON) stays well formed. A value that is already
      # the placeholder is left as is.
      def self.redacted_value(value)
        quote = value[0] if value.length >= 2 && (value[0] == '"' || value[0] == "'") && value[-1] == value[0]
        inner = quote ? value[1..-2] : value
        return value if already_redacted?(inner)
        quote ? "#{quote}#{REDACTED_PLACEHOLDER}#{quote}" : REDACTED_PLACEHOLDER
      end

      # @!visibility private
      def self.try_parse_json(str)
        # Find first non-whitespace byte; allow leading whitespace and BOM.
        trimmed = str.byteslice(0, 16).to_s.dup
        trimmed.force_encoding("BINARY")
        trimmed.sub!(/\A\xEF\xBB\xBF/n, "")
        first = trimmed.lstrip[0]
        return nil unless first == "{" || first == "["
        JSON.parse(str, max_nesting: 32)
      rescue JSON::ParserError, JSON::NestingError
        nil
      end

      # Whether a JSON key names a credential whose value must be redacted.
      # @!visibility private
      def self.sensitive_key?(key)
        k = key.to_s.downcase
        SENSITIVE_FIELDS_SET.include?(k) || SENSITIVE_KEY_PREFIXES.any? { |p| k.start_with?(p) }
      end

      # @!visibility private
      # Recursively walks a parsed JSON structure replacing values under any
      # sensitive key with the redaction placeholder. Returns the same node
      # for chaining; mutates Hashes/Arrays in place.
      #
      # When a value is itself a String that looks like JSON, attempt to
      # parse-scrub-re-encode it so embedded-JSON payloads are also covered
      # (e.g. `{"body":"{\"password\":\"x\"}"}`).
      def self.scrub_sensitive!(node)
        case node
        when Hash
          node.each do |key, value|
            if key.is_a?(String) && sensitive_key?(key)
              node[key] = REDACTED_PLACEHOLDER
            elsif value.is_a?(Hash) || value.is_a?(Array)
              scrub_sensitive!(value)
            elsif value.is_a?(String)
              redacted_string = maybe_scrub_embedded_json(value)
              node[key] = redacted_string unless redacted_string.equal?(value)
            end
          end
        when Array
          node.each_with_index do |item, i|
            if item.is_a?(Hash) || item.is_a?(Array)
              scrub_sensitive!(item)
            elsif item.is_a?(String)
              redacted_string = maybe_scrub_embedded_json(item)
              node[i] = redacted_string unless redacted_string.equal?(item)
            end
          end
        end
        node
      end

      # @!visibility private
      # Recursively walk a parsed JSON structure replacing any
      # numeric-only Array of length >= `LOG_VECTOR_COMPACT_THRESHOLD`
      # with a compact placeholder string ("<vector dims=N>"). Mutates
      # Hashes/Arrays in place; returns the node for chaining. Distinct
      # pass from {scrub_sensitive!} because the criterion is shape
      # (numeric array width), not key name.
      #
      # The walker does NOT descend into the replaced array — once a
      # node is recognised as a vector its inner Numerics aren't of
      # interest. Nested vectors (Array<Array<Numeric>>, e.g. a batched
      # embedding response in a logged HTTP body) are caught at the
      # inner array level on the next recursion.
      def self.compact_vectors!(node)
        case node
        when Hash
          node.each do |key, value|
            if vector_shape?(value)
              node[key] = "<vector dims=#{value.length}>"
            elsif value.is_a?(Hash) || value.is_a?(Array)
              compact_vectors!(value)
            end
          end
        when Array
          node.each_with_index do |item, i|
            if vector_shape?(item)
              node[i] = "<vector dims=#{item.length}>"
            elsif item.is_a?(Hash) || item.is_a?(Array)
              compact_vectors!(item)
            end
          end
        end
        node
      end

      # @!visibility private
      # An Array is "vector-shaped" if it meets the compaction threshold
      # AND every element is Numeric. The numeric check prevents long
      # tag arrays / role lists / mixed-type arrays from being mangled.
      # Boolean is not Numeric in Ruby, so an array of booleans (rare
      # but possible) is left alone — also fine.
      def self.vector_shape?(val)
        return false unless val.is_a?(Array)
        return false if val.length < LOG_VECTOR_COMPACT_THRESHOLD
        val.all? { |x| x.is_a?(Numeric) }
      end

      # @!visibility private
      # If `str` parses as JSON (object or array), scrub structurally and
      # re-encode. Otherwise return the original string unchanged.
      def self.maybe_scrub_embedded_json(str)
        return str unless (inner = try_parse_json(str))
        scrub_sensitive!(inner)
        compact_vectors!(inner)
        begin
          inner.to_json
        rescue StandardError
          str
        end
      end

      # Thread-safety
      # @!visibility private
      def call(env)
        dup.call!(env)
      end

      # @!visibility private
      def call!(env)
        # the maximum url size is ~2KB, so if we request a Parse API url greater than this
        # (which is most likely a very complicated query), we need to override the request method
        # to be POST instead of GET and send the query parameters in the body of the POST request.
        # The standard maximum POST request (which is a server setting), is usually set to 20MBs
        if env[:method] == :get && env[:url].to_s.length >= MAX_URL_LENGTH
          if aggregate_request?(env[:url])
            # Parse Server's AggregateRouter only JSON-decodes query-string
            # params (via JSONFromQuery); it does NOT decode a `pipeline` param
            # that arrives in the request body. The urlencoded override below
            # would therefore deliver `pipeline` as a raw JSON *string*, which
            # AggregateRouter.getPipeline mis-reads character-by-character and
            # rejects with "Invalid aggregate stage '0'". Send a JSON body
            # instead so the pipeline survives as a real Array. `_method=GET`
            # still routes Parse Server to its GET-only aggregate handler.
            env[:request_headers][HTTP_METHOD_OVERRIDE] = "GET"
            env[:request_headers][CONTENT_TYPE] = CONTENT_TYPE_FORMAT
            env[:body] = aggregate_override_body(env[:url].query)
            env[:url].query = nil
            env[:method] = :post
          else
            env[:request_headers][HTTP_METHOD_OVERRIDE] = "GET"
            env[:request_headers][CONTENT_TYPE] = "application/x-www-form-urlencoded"
            # parse-server looks for method overrides in the body under the `_method` param.
            # so we will add it to the query string, which will now go into the body.
            # `.to_s` guards the (contrived but possible) case of a >=2KB URL whose
            # length is all path and no query — nil + String would raise TypeError.
            env[:body] = "_method=GET&" + env[:url].query.to_s
            env[:url].query = nil
            #override
            env[:method] = :post
          end
          # else if not a get, always make sure the request is JSON encoded if the content type matches
        elsif env[:request_headers][CONTENT_TYPE] == CONTENT_TYPE_FORMAT &&
              (env[:body].is_a?(Hash) || env[:body].is_a?(Array))
          env[:body] = env[:body].to_json
        end

        # `Parse.logging = true` routes here, so this legacy printer sees the
        # same tenant-controlled bytes the Faraday logging middleware does and
        # needs the same terminal-escape handling.
        if self.class.logging
          puts "[Request #{env.method.upcase}] " \
               "#{Parse::TerminalSafe.sanitize_line(self.class.redact(env[:url].to_s))}"
          env[:request_headers].each do |k, v|
            if REDACTED_HEADERS.include?(k.to_s.downcase)
              puts "[Header] #{Parse::TerminalSafe.sanitize_line(k)} : [FILTERED]"
            else
              puts "[Header] #{Parse::TerminalSafe.sanitize_line(k)} : " \
                   "#{Parse::TerminalSafe.sanitize_line(v)}"
            end
          end

          puts "[Request Body] " \
               "#{Parse::TerminalSafe.sanitize_line(self.class.redact(env[:body].to_s))}"
        end
        @app.call(env).on_complete do |response_env|
          # on a response, create a new Parse::Response and replace the :body
          # of the env
          # @todo CHECK FOR HTTP STATUS CODES
          if self.class.logging
            puts "[[Response #{response_env[:status]}]] ----------------------------------"
            puts Parse::TerminalSafe.sanitize(self.class.redact(response_env.body.to_s))
            puts "[[Response]] --------------------------------------\n"
          end

          parsed = true
          begin
            r = Parse::Response.new(response_env.body)
          rescue => e
            parsed = false
            r = Parse::Response.new
            r.code = response_env.status
            r.error = "Invalid response for #{env[:method]} #{env[:url]}: #{e}"
          end
          status = response_env[:status].to_i
          r.http_status = response_env[:status]
          r.headers = response_env[:response_headers]
          if parsed && status.between?(200, 299)
            # Parse Server never reports an error with a 2xx status, so a
            # `code` or `error` key in a 2xx body is object data (for example
            # a column set by a beforeSave trigger), not an error envelope.
            r.code = nil
            r.error = nil
          elsif status > 0 && !status.between?(200, 299) && r.error.blank?
            # A non-2xx response is a failure even without a Parse `error`
            # field. It may come from something in front of Parse Server (an
            # API gateway or load balancer returning 502/504 with
            # `{"message": ...}`), or from Parse Server itself (a failed
            # transaction returns `{"code": 1, "message": ...}`). Record the
            # HTTP status as the code when there is none, so the request is
            # never mistaken for a success.
            detail = r.result.is_a?(Hash) ? r.result["message"] : nil
            r.code ||= status
            r.error = detail.present? ? detail.to_s : "HTTP #{status} response without a Parse error body"
          end
          r.code ||= response_env[:status] if r.error.present?
          response_env[:body] = r
        end
      end

      private

      # Whether the request targets Parse Server's `/aggregate/<Class>`
      # endpoint. Used by {#call!} to pick the JSON-body form of the
      # long-URL GET→POST override (the aggregate endpoint does not
      # JSON-decode a body `pipeline` param, unlike `where`).
      #
      # Anchored to the final two path segments: `.../aggregate/<ClassName>`
      # where <ClassName> is the last segment (no further slashes). The
      # className is mandatory and slash-free — see
      # {Parse::API::Aggregate#aggregate_uri_path}, which validates it via
      # PathSegment.identifier! — so a real aggregate URL always ends this way.
      # A `find` request is `.../classes/<ClassName>` (no match), a class
      # merely *named* with "aggregate" (e.g. `MyAggregateData`) does not match,
      # and an `/aggregate/` segment appearing earlier in a custom mount prefix
      # (e.g. `/aggregate/api/classes/Foo`) does not match either.
      # @param url [URI] the request URL.
      # @return [Boolean]
      def aggregate_request?(url)
        url.path.to_s.match?(%r{/aggregate/[^/]+/?\z})
      end

      # Build the JSON request body for a long-URL aggregate GET→POST
      # override. Reconstructs the params from the encoded query string and
      # JSON-decodes each value so the `pipeline` Array (and boolean
      # `rawValues`/`rawFieldNames`) reach Parse Server as real types rather
      # than strings. A value that is not itself JSON is passed through
      # unchanged. `_method=GET` is injected so Parse Server routes the POST
      # to its GET-only aggregate handler.
      # @param query_string [String, nil] the encoded query string.
      # @return [String] the JSON body to send.
      def aggregate_override_body(query_string)
        params = Faraday::Utils.parse_query(query_string.to_s) || {}
        body = { "_method" => "GET" }
        params.each do |key, value|
          body[key] = begin
              JSON.parse(value)
            rescue JSON::ParserError, TypeError
              value
            end
        end
        body.to_json
      end
    end
  end #Middleware
end
