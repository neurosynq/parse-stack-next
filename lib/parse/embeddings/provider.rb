# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Embeddings
    # Abstract base class for embedding providers. Concrete subclasses
    # implement {#embed_text} (and, in v5.1+, optionally {#embed_image}).
    #
    # Provider responsibilities:
    #
    # * Translate a batch of inputs into a batch of float vectors.
    # * Return vectors in **the same order** as inputs.
    # * Call {#validate_response!} before returning so the caller sees
    #   a typed {InvalidResponseError} for off-by-one batches and NaN /
    #   ±Inf poisoning at the provider boundary — not deep inside a
    #   later $vectorSearch call.
    #
    # Subclasses MUST override:
    #
    # * {#embed_text} — `(strings, input_type:) -> Array<Array<Float>>`
    # * {#dimensions} — `Integer`, the fixed output width
    # * {#model_name} — stable identifier for cache keys / `embedding_meta`
    #
    # Subclasses MAY override:
    #
    # * {#embed_image}      — v5.1 (multimodal); default `NotImplementedError`
    # * {#embed_batch_size} — provider-recommended batch size hint
    # * {#max_input_tokens} — chunker hint
    # * {#normalize?}       — whether output is unit-normalized
    # * {#modalities}       — defaults to `[:text]`
    # * {#supports_input_type?} — defaults to `false`
    #
    # @abstract
    class Provider
      # @return [Array<Array<Float>>] vectors aligned 1:1 with `strings`.
      # @raise [NotImplementedError] when the concrete subclass has not
      #   overridden the method.
      def embed_text(strings, input_type: :search_document)
        raise NotImplementedError, "#{self.class}#embed_text must be implemented"
      end

      # @param sources [Array<URI, IO, String>] image sources — URI for
      #   remote, IO for streamed bytes, String for base64. Concrete
      #   providers document which forms they accept. In v5.1 (URL-only
      #   path), every source is a raw `String` URL forwarded unchanged
      #   from the managed path: {Parse::Core::EmbedManaged} deliberately
      #   does NOT validate before calling the provider (validating there
      #   would double-resolve every URL). The concrete `embed_image`
      #   override is therefore responsible for calling
      #   {Parse::Embeddings.validate_image_url!} (passing `allow_insecure:`
      #   through) before egress — see the bundled Voyage/Cohere providers,
      #   which validate internally.
      # @param input_type [Symbol] `:search_query` or `:search_document`,
      #   parallel to {#embed_text}.
      # @param allow_insecure [Boolean] **contract kwarg** —
      #   {Parse::Core::EmbedManaged.recompute_embedding!} unconditionally
      #   forwards this from the directive declaration. Concrete
      #   `embed_image` overrides MUST either accept `allow_insecure:`
      #   explicitly (passing it through to
      #   {Parse::Embeddings.validate_image_url!}) or absorb it via
      #   `**opts`. Dropping `**opts` from the override signature
      #   without accepting `allow_insecure:` will raise
      #   `ArgumentError: unknown keyword: allow_insecure` from the
      #   managed-embedding save path. Default `false`.
      # @param opts [Hash] provider-specific options (e.g. `dim:` for
      #   Matryoshka-style truncation). Forward-compatible escape hatch.
      # @return [Array<Array<Float>>] vectors aligned 1:1 with `sources`.
      # @raise [NotImplementedError] image embedding is a v5.1+ feature.
      def embed_image(sources, input_type: :search_document, allow_insecure: false, **opts)
        raise NotImplementedError, "#{self.class} does not support image embedding"
      end

      # Batched text embedding. Splits `strings` into chunks of size
      # {#embed_batch_size} (or returns a single-shot call when nil) and
      # concatenates results. Concrete providers should override only
      # when their HTTP shape needs more than naive slicing (e.g. async
      # parallelism, per-request budgets). The default is sufficient for
      # any provider whose `embed_text` accepts an array directly.
      #
      # @param strings [Array<String>]
      # @param input_type [Symbol]
      # @return [Array<Array<Float>>] aligned 1:1 with `strings`.
      def embed_text_batched(strings, input_type: :search_document)
        unless strings.is_a?(Array)
          raise ArgumentError,
                "#{self.class}#embed_text_batched expects Array<String> (got #{strings.class})."
        end
        return [] if strings.empty?
        size = embed_batch_size
        return embed_text(strings, input_type: input_type) if size.nil? || strings.length <= size
        strings.each_slice(size).flat_map do |slice|
          embed_text(slice, input_type: input_type)
        end
      end

      # @return [Integer] fixed output width of this provider's vectors.
      def dimensions
        raise NotImplementedError, "#{self.class}#dimensions must be implemented"
      end

      # @return [String] stable model identifier (e.g. "text-embedding-3-small").
      #   Used as a cache-key component and persisted to `embedding_meta`.
      def model_name
        raise NotImplementedError, "#{self.class}#model_name must be implemented"
      end

      # @return [Array<Symbol>] subset of [:text, :image, :audio, :video].
      def modalities
        [:text]
      end

      # @return [Integer, nil] provider-recommended batch size, or nil.
      def embed_batch_size
        nil
      end

      # @return [Integer, nil] chunker hint; max tokens per input.
      def max_input_tokens
        nil
      end

      # @return [Boolean] whether the provider returns unit-normalized
      #   vectors. Affects similarity-metric selection (`:cosine` vs
      #   `:dotProduct`).
      def normalize?
        false
      end

      # @return [Boolean] whether the provider distinguishes between
      #   `:search_query` and `:search_document` inputs. When false the
      #   `input_type:` kwarg is accepted (for forward compatibility and
      #   cache-key stability) but has no effect on the returned vector.
      def supports_input_type?
        false
      end

      # Validate a provider response before returning it from `embed_*`.
      #
      # Raises {InvalidResponseError} on any of:
      #
      # * `vectors.length != input_count` (off-by-one across batch — the
      #   most insidious provider bug, since vectors would be silently
      #   misaligned with their inputs).
      # * `vectors[i]` is not an Array.
      # * `vectors[i].length != dimensions` (variable-width response).
      # * any element non-Numeric, NaN, or ±Inf.
      #
      # @param input_count [Integer] number of items in the input batch.
      # @param vectors [Array<Array<Float>>] the provider's response.
      # @return [Array<Array<Float>>] vectors, unchanged on success.
      # @raise [InvalidResponseError]
      def validate_response!(input_count, vectors)
        unless vectors.is_a?(Array)
          raise InvalidResponseError,
                "#{self.class}: expected Array of vectors, got #{vectors.class}."
        end
        if vectors.length != input_count
          raise InvalidResponseError,
                "#{self.class}: response length #{vectors.length} != input count #{input_count}."
        end
        dims = dimensions
        vectors.each_with_index do |vec, i|
          unless vec.is_a?(Array)
            raise InvalidResponseError,
                  "#{self.class}: response[#{i}] is not an Array (#{vec.class})."
          end
          if vec.length != dims
            raise InvalidResponseError,
                  "#{self.class}: response[#{i}] length #{vec.length} != declared dimensions #{dims}."
          end
          vec.each_with_index do |x, j|
            # Strictly Float or Integer. Numeric is too loose — Complex
            # has #finite? and would pass; Rational/BigDecimal serialize
            # to BSON in surprising ways. Vector elements are always
            # floats in practice.
            unless x.is_a?(Float) || x.is_a?(Integer)
              raise InvalidResponseError,
                    "#{self.class}: response[#{i}][#{j}] is not Float or Integer (#{x.class})."
            end
            unless x.respond_to?(:finite?) && x.finite?
              raise InvalidResponseError,
                    "#{self.class}: response[#{i}][#{j}] is not finite (#{x.inspect})."
            end
          end
        end
        vectors
      end

      # Default {#inspect} that allowlists safe instance vars. Concrete
      # providers holding `@api_key`, `@bearer_token`, etc. inherit a
      # safe `inspect` automatically. Subclasses may extend the
      # allowlist by overriding {#inspect_attrs}.
      def inspect
        attrs = inspect_attrs.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
        attrs.empty? ? "#<#{self.class}>" : "#<#{self.class} #{attrs}>"
      end

      # @return [Hash] attributes safe to surface in {#inspect}. Override
      #   in subclasses to add fields; never add credentials.
      def inspect_attrs
        out = {}
        out[:model] = safe_call(:model_name)
        out[:dim]   = safe_call(:dimensions)
        out.compact
      end

      # AS::N event name emitted from {#instrument_embed}. Subscribers
      # match this exact string. Parallel namespace to
      # `parse.mongodb.aggregate` / `parse.cache.*` /
      # `parse.agent.tool_call` so a single AS::N subscription tree can
      # cover query, cache, agent, and embedding spend.
      AS_NOTIFICATION_NAME = "parse.embeddings.embed"

      # Subscribed payload contract. Keys are present on every emit so
      # subscribers can rely on them without `key?` guards (values may
      # be `nil` when the provider does not surface usage telemetry —
      # e.g. {Fixture} has no token cost).
      #
      # * `:provider`     [String]  — `self.class.name`
      # * `:model`        [String]  — {#model_name}
      # * `:dimensions`   [Integer] — {#dimensions}
      # * `:input_count`  [Integer] — number of items in the batch
      # * `:input_type`   [Symbol]  — `:search_query` / `:search_document`
      # * `:total_tokens` [Integer, nil] — provider-reported token usage; nil when N/A
      # * `:cached`       [Boolean] — whether the batch was served from cache (always false in v5.0)
      # * `:error`        [String, nil] — `exception.class.name` when the block raised
      #
      # Subscribers should NOT depend on additional keys appearing — the
      # contract is stable. New keys may be added but existing semantics
      # will not change without a deprecation cycle.
      #
      # Synchronous-subscriber discipline: AS::N delivers events on the
      # request thread. A slow subscriber blocks every embed call; an
      # exception in a subscriber surfaces as a request failure. Keep
      # subscribers cheap (counters, in-memory accumulators) or push to
      # non-blocking sinks (StatsD-over-UDP, OTel exporters that batch).
      #
      # The block is yielded the payload Hash so concrete providers can
      # write `:total_tokens` / `:cached` from inside the network call
      # (after parsing the provider's `usage` envelope). Any other field
      # set on the yielded payload also reaches subscribers — but only
      # via the documented keys above. Stick to the contract.
      def instrument_embed(input_count, input_type, **extra)
        payload = {
          provider: self.class.name,
          model: safe_call(:model_name),
          dimensions: safe_call(:dimensions),
          input_count: input_count,
          input_type: input_type,
          total_tokens: nil,
          cached: false,
          error: nil,
        }.merge(extra)
        # Defensive: AS::N is in active_support, which the wider gem
        # already requires; if a downstream caller has loaded the
        # embeddings module without ActiveSupport (e.g. a sliced
        # require of just `parse/embeddings`), fall through.
        unless defined?(ActiveSupport::Notifications)
          return yield(payload)
        end
        result = nil
        ActiveSupport::Notifications.instrument(AS_NOTIFICATION_NAME, payload) do |emit_payload|
          begin
            result = yield(emit_payload)
          rescue StandardError => e
            emit_payload[:error] = e.class.name
            raise
          end
        end
        result
      end

      private

      def safe_call(method)
        public_send(method)
      rescue NotImplementedError
        nil
      end
    end
  end
end
