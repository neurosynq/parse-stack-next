# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../vector_search"
require_relative "../../embeddings"

module Parse
  module Core
    # Class-level `find_similar` wrapper around {Parse::VectorSearch.search}
    # for any Parse::Object subclass that has declared at least one
    # `:vector` property.
    #
    # The wrapper handles three things the low-level entry point doesn't:
    #
    # 1. **Field resolution.** Defaults to the subclass's single
    #    `:vector` property; raises if the class has none, requires
    #    explicit `field:` if it has more than one.
    # 2. **Declared-dimension validation.** Compares the query vector's
    #    length against the `dimensions:` declared on the property,
    #    so callers get "expected 1536, got 768" instead of an Atlas-
    #    side error after a round-trip.
    # 3. **Index auto-discovery.** Looks up the Atlas vectorSearch
    #    index covering the field via
    #    {Parse::AtlasSearch::IndexCatalog.find_vector_index} when no
    #    explicit `index:` kwarg is given.
    #
    # ACL/CLP enforcement is inherited from {Parse::VectorSearch.search}
    # (which routes through {Parse::MongoDB} — REST `/aggregate` is
    # master-key-only and bypasses ACL/CLP, see CLAUDE.md). The full
    # scope-kwarg surface (`session_token:`, `master:`, `acl_user:`,
    # `acl_role:`) is forwarded as-is.
    #
    # @example default field, default index
    #   WikiArticle.find_similar(vector: query_embedding, k: 5)
    #
    # @example explicit field + post-filter, scoped to a session
    #   Document.find_similar(
    #     vector: embed.call("ruby parse"),
    #     field: :body_embedding,
    #     k: 10,
    #     filter: { tag: "ruby" },
    #     session_token: user.session_token,
    #   )
    module VectorSearchable
      # Raised when the calling class has no `:vector` property to
      # search against. Distinct from {Parse::VectorSearch::InvalidQueryVector}
      # because the misuse is at the class level, not the query level.
      class NoVectorProperty < ArgumentError; end

      # Raised when a class declares more than one `:vector` property
      # and the caller didn't pass `field:` to disambiguate.
      class AmbiguousVectorField < ArgumentError; end

      # Raised when no Atlas vectorSearch index covers the requested
      # field and the caller didn't pass an explicit `index:` kwarg.
      class IndexNotResolved < ArgumentError; end

      # Raised by the `find_similar(text:)` overload when the resolved
      # `:vector` property has no `provider:` (and therefore no way to
      # turn `text:` into a query vector). Distinct from
      # {Parse::Embeddings::ProviderNotRegistered} (registry miss) — this
      # is a class-declaration miss: the field was declared without
      # binding it to a provider at the property level.
      class EmbedderNotConfigured < ArgumentError; end

      # Accepted {#vector_visibility} modes.
      VECTOR_VISIBILITY_MODES = %i[owner_only public].freeze

      # Class-level default for whether this class's `:vector` properties
      # are included in `as_json` serialization.
      #
      # * `:owner_only` (default) — vectors are OMITTED from `as_json`
      #   unless the caller passes `include_vectors: true`. Embeddings are
      #   large and leak ML signal; the safe default keeps them off the
      #   wire and out of API responses. Row-level read access is still
      #   governed by ACL as usual — this controls serialization exposure,
      #   not row authorization.
      # * `:public` — vectors are INCLUDED in `as_json` by default (a
      #   caller can still suppress per-call with `include_vectors: false`).
      #
      #   class Article < Parse::Object
      #     vector_visibility :public           # expose embeddings in as_json
      #     property :embedding, :vector, dimensions: 1536, provider: :openai
      #   end
      #
      # Read the effective mode by calling with no argument; it inherits
      # from the superclass when unset on the subclass.
      #
      # @param mode [Symbol, nil] one of {VECTOR_VISIBILITY_MODES}, or nil
      #   to read the current effective mode.
      # @return [Symbol] the effective mode (when reading) or the mode set.
      # @raise [ArgumentError] on an unknown mode.
      def vector_visibility(mode = nil)
        if mode.nil?
          return @vector_visibility if defined?(@vector_visibility) && @vector_visibility
          return superclass.vector_visibility if superclass.respond_to?(:vector_visibility)
          return :owner_only
        end
        m = mode.to_sym
        unless VECTOR_VISIBILITY_MODES.include?(m)
          raise ArgumentError,
                "#{self}.vector_visibility: mode must be one of " \
                "#{VECTOR_VISIBILITY_MODES.inspect} (got #{mode.inspect})."
        end
        @vector_visibility = m
      end

      # @return [Boolean] whether `:vector` fields are serialized into
      #   `as_json` by default for this class (true only for `:public`).
      def vectors_public_by_default?
        vector_visibility == :public
      end

      # Find documents whose declared `:vector` property is closest to
      # `vector:` under the Atlas vectorSearch index's similarity
      # function.
      #
      # @param vector [Array<Float>, Parse::Vector, nil] the query
      #   embedding. Mutually exclusive with `text:` — exactly one of the
      #   two must be given.
      # @param text [String, nil] natural-language query. When given, the
      #   resolved field's declared `provider:` is looked up via
      #   {Parse::Embeddings.provider}, used to embed `[text]` with
      #   `input_type: :search_query`, and the resulting vector is used
      #   in place of `vector:`. Requires the property to have been
      #   declared with `provider:` metadata.
      # @param k [Integer] number of hits to return. Default 10.
      # @param field [Symbol, String, nil] the `:vector` property to
      #   search. Auto-resolves when the class has exactly one
      #   `:vector` property.
      # @param filter [Hash, nil] post-`$vectorSearch` `$match` filter.
      # @param vector_filter [Hash, nil] Atlas-native pre-search filter
      #   (fields must be declared `type: "filter"` in the index).
      # @param index [String, nil] explicit vectorSearch index name.
      #   Skips auto-discovery when given.
      # @param num_candidates [Integer, nil] HNSW search width.
      # @param max_time_ms [Integer, nil] server-side timeout.
      # @param raw [Boolean] when true return the raw Mongo documents
      #   (each enriched with `_vscore`); when false (default) build
      #   instances of the calling class and attach `vector_score`.
      # @param scope_opts [Hash] ACL/CLP scope kwargs forwarded to
      #   {Parse::VectorSearch.search}: `session_token:`, `master:`,
      #   `acl_user:`, `acl_role:`.
      # @return [Array<Parse::Object>, Array<Hash>] hits in
      #   descending-similarity order. Each instance responds to
      #   `vector_score` (the Atlas `vectorSearchScore`).
      # @raise [NoVectorProperty] when the class has no `:vector`
      #   property.
      # @raise [AmbiguousVectorField] when the class has more than one
      #   `:vector` property and `field:` was omitted.
      # @raise [Parse::VectorSearch::InvalidQueryVector] when the query
      #   vector's shape doesn't match the declared dimensions.
      # @raise [IndexNotResolved] when no covering vectorSearch index
      #   exists and no explicit `index:` was given.
      # @raise [ArgumentError] when neither `vector:` nor `text:` is
      #   given, or both are given.
      # @raise [EmbedderNotConfigured] when `text:` is given but the
      #   resolved field's property has no `provider:` declared.
      # @raise [Parse::Embeddings::ProviderNotRegistered] when the
      #   declared `provider:` was never registered via
      #   {Parse::Embeddings.register}.
      # @raise [Parse::Embeddings::InvalidResponseError] when the
      #   registered provider returns a payload that is not a single
      #   vector (defense-in-depth above {Parse::Embeddings::Provider#validate_response!}).
      #
      # @note When `text:` is given, the text is sent over the wire to
      #   the embedding provider (e.g. OpenAI). Operators that enable
      #   global Faraday request logging on the embedding connection
      #   will capture the full query text in the JSON request body.
      #   Treat `text:` as user-visible content for log-handling
      #   purposes.
      # @note The provider is responsible for bounding its own request
      #   timeout. {Parse::Embeddings::OpenAI} self-bounds at 30 s read
      #   / 5 s connect with capped retries. Custom providers MUST
      #   self-bound — `find_similar` does not impose a wall-clock
      #   deadline on the embed step.
      def find_similar(vector: nil, text: nil, k: 10, field: nil, filter: nil,
                       vector_filter: nil, index: nil,
                       num_candidates: nil, max_time_ms: nil, raw: false,
                       **scope_opts)
        if vector.nil? && text.nil?
          raise ArgumentError,
                "#{self}.find_similar: must pass either `vector:` or `text:`."
        end
        if !vector.nil? && !text.nil?
          raise ArgumentError,
                "#{self}.find_similar: pass either `vector:` or `text:`, not both."
        end

        resolved_field = resolve_vector_field!(field)
        declared_dims = vector_properties.dig(resolved_field, :dimensions)

        query_vector =
          if text.nil?
            coerce_query_vector(vector)
          else
            embed_query_text!(text, resolved_field)
          end
        Parse::VectorSearch.validate_query_vector!(query_vector, dimensions: declared_dims)

        index_name = resolve_vector_index!(resolved_field, index)

        raw_hits = Parse::VectorSearch.search(
          parse_class,
          field: resolved_field,
          query_vector: query_vector,
          k: k,
          num_candidates: num_candidates,
          filter: filter,
          vector_filter: vector_filter,
          index: index_name,
          max_time_ms: max_time_ms,
          **scope_opts,
        )

        return raw_hits if raw
        build_vector_hits(raw_hits)
      end

      # Hybrid (lexical + vector) search with reciprocal-rank fusion.
      #
      # Runs a lexical Atlas Search branch and a `$vectorSearch` branch
      # independently, then fuses their ranked results client-side via RRF
      # (or, on Atlas 8.0+, server-side via native `$rankFusion` when
      # detected). Both branches enforce ACL/CLP/protectedFields before
      # fusion — see {Parse::VectorSearch::Hybrid}.
      #
      # @example
      #   Song.hybrid_search(
      #     text: "love songs about rain",
      #     lexical: { index: "song_search", query: "rain love" },
      #     vector:  { num_candidates: 200 },
      #     k: 20,
      #     fusion: { k_constant: 60, weights: { lexical: 0.4, vector: 0.6 } },
      #   )
      #
      # @param text [String, nil] natural-language query. Embedded (via
      #   the resolved `:vector` property's `provider:`) for the vector
      #   branch, and used as the lexical query unless `lexical[:query]`
      #   overrides it.
      # @param query_vector [Array<Float>, Parse::Vector, nil] pre-computed
      #   query embedding (alternative to `text:` for the vector branch).
      # @param lexical [Hash] lexical branch config (`:query`, `:index`,
      #   `:fields`, `:filter`, `:fuzzy`). `:query` defaults to `text:`.
      # @param vector [Hash] vector branch config (`:field`, `:index`,
      #   `:num_candidates`, `:filter`, `:vector_filter`). `:field`
      #   defaults to the class's sole `:vector` property; `:index` is
      #   auto-discovered when omitted.
      # @param k [Integer] number of fused hits to return.
      # @param fusion [Hash, nil] `:method` (`:rrf` / `:rrf_client`),
      #   `:k_constant`, `:weights` (`{ lexical:, vector: }`).
      # @param raw [Boolean] return fused raw rows instead of built
      #   Parse::Object instances.
      # @param scope_opts [Hash] ACL/CLP scope kwargs forwarded to both
      #   branches (`session_token:` / `master:` / `acl_user:` /
      #   `acl_role:`).
      # @return [Array<Parse::Object>] fused, RRF-ordered; each carries
      #   `#hybrid_score` and `#hybrid_ranks` (and `#vector_score` /
      #   `#search_score` when the branch contributed). `raw: true`
      #   returns the fused Hashes.
      def hybrid_search(text: nil, query_vector: nil, lexical: {}, vector: {},
                        k: 20, fusion: nil, raw: false, **scope_opts)
        require_relative "../../vector_search/hybrid"
        lex = (lexical || {}).transform_keys(&:to_sym)
        vec = (vector || {}).transform_keys(&:to_sym)

        field_sym = resolve_vector_field!(vec[:field])
        declared_dims = vector_properties.dig(field_sym, :dimensions)

        qv = query_vector || vec[:query_vector]
        qv =
          if qv.nil?
            unless text.is_a?(String) && !text.strip.empty?
              raise ArgumentError,
                    "#{self}.hybrid_search: pass `text:` (to embed) or a `query_vector:`."
            end
            embed_query_text!(text, field_sym)
          else
            coerce_query_vector(qv)
          end
        Parse::VectorSearch.validate_query_vector!(qv, dimensions: declared_dims)

        lexical_query = lex[:query] || text
        unless lexical_query.is_a?(String) && !lexical_query.strip.empty?
          raise ArgumentError,
                "#{self}.hybrid_search: needs a lexical query — pass `text:` or `lexical: { query: }`."
        end

        vector_index = vec[:index] || resolve_vector_index!(field_sym, nil)

        fused = Parse::VectorSearch::Hybrid.search(
          parse_class,
          lexical: {
            query: lexical_query, index: lex[:index], fields: lex[:fields],
            filter: lex[:filter], fuzzy: lex[:fuzzy],
          },
          vector: {
            query_vector: qv, field: field_sym, index: vector_index,
            num_candidates: vec[:num_candidates], filter: vec[:filter],
            vector_filter: vec[:vector_filter],
          },
          k: k,
          fusion: fusion,
          **scope_opts,
        )

        return fused if raw
        build_hybrid_hits(fused)
      end

      private

      def resolve_vector_field!(field)
        declared = vector_properties.keys
        if field
          sym = field.to_sym
          unless declared.include?(sym)
            raise NoVectorProperty,
                  "#{self}.find_similar: field :#{sym} is not a :vector property " \
                  "(declared :vector fields: #{declared.inspect})."
          end
          return sym
        end
        if declared.length == 1
          return declared.first
        end
        if declared.empty?
          raise NoVectorProperty,
                "#{self}.find_similar: no :vector property declared on this class."
        end
        raise AmbiguousVectorField,
              "#{self}.find_similar: class declares multiple :vector properties " \
              "(#{declared.inspect}); pass `field:` to disambiguate."
      end

      # Maximum bytes accepted for the `text:` overload. 256 KiB is well
      # above any reasonable embedding-model token budget (8K tokens ≈
      # 32 KB UTF-8) and keeps a runaway caller from shipping multi-MB
      # bodies to the provider — and from filling operator error-trackers
      # with the captured request body when the provider eventually 400s.
      MAX_QUERY_TEXT_BYTES = 256 * 1024

      # Embed a natural-language query against the provider declared on
      # the resolved `:vector` property. Validates the text input here
      # (rather than letting the provider raise its own message) so the
      # error trace points at `find_similar`, not at HTTP-layer code.
      def embed_query_text!(text, resolved_field)
        unless text.is_a?(String)
          raise ArgumentError,
                "#{self}.find_similar: `text:` must be a String (got #{text.class})."
        end
        if text.empty?
          raise ArgumentError,
                "#{self}.find_similar: `text:` is empty."
        end
        if text.bytesize > MAX_QUERY_TEXT_BYTES
          raise ArgumentError,
                "#{self}.find_similar: `text:` exceeds #{MAX_QUERY_TEXT_BYTES} bytes " \
                "(#{text.bytesize}); embedding providers will reject it. Chunk the " \
                "input client-side before calling find_similar(text:)."
        end
        provider_name = vector_properties.dig(resolved_field, :provider)
        if provider_name.nil?
          raise EmbedderNotConfigured,
                "#{self}.find_similar: property :#{resolved_field} has no `provider:` " \
                "declared; cannot embed `text:`. Declare `provider: :openai` (or other) " \
                "on the property, or pass an explicit `vector:`."
        end
        provider = Parse::Embeddings.provider(provider_name)
        vectors = provider.embed_text([text], input_type: :search_query)
        unless vectors.is_a?(Array) && vectors.length == 1 && vectors.first.is_a?(Array)
          raise Parse::Embeddings::InvalidResponseError,
                "#{self}.find_similar: provider #{provider_name.inspect} did not return " \
                "a single vector for `text:` (got #{vectors.inspect[0, 80]})."
        end
        vectors.first
      end

      def coerce_query_vector(vector)
        case vector
        when Parse::Vector then vector.to_a
        when Array         then vector
        else
          raise Parse::VectorSearch::InvalidQueryVector,
                "vector: must be an Array<Float> or Parse::Vector (got #{vector.class})."
        end
      end

      def resolve_vector_index!(field, explicit_index)
        return explicit_index if explicit_index && !explicit_index.to_s.empty?
        begin
          require_relative "../../atlas_search"
        rescue LoadError
          raise IndexNotResolved,
                "#{self}.find_similar: no index: given and Parse::AtlasSearch " \
                "could not be loaded; pass an explicit index: kwarg."
        end
        idx = Parse::AtlasSearch::IndexCatalog.find_vector_index(parse_class, field: field)
        if idx.nil?
          raise IndexNotResolved,
                "#{self}.find_similar: no vectorSearch index found covering " \
                "#{parse_class}.#{field}; pass index: explicitly or create one " \
                "via Parse::AtlasSearch::IndexCatalog.create_index."
        end
        (idx["name"] || idx[:name]).to_s
      end

      def build_vector_hits(raw_hits)
        return [] if raw_hits.nil? || raw_hits.empty?
        converted = Parse::MongoDB.convert_documents_to_parse(raw_hits, parse_class)
        converted.each_with_index.map do |doc, idx|
          obj = Parse::Object.build(doc, parse_class)
          next nil unless obj
          score = raw_hits[idx]["_vscore"] || raw_hits[idx][:_vscore]
          # `vector_score` reader is defined once on Parse::Object — see
          # lib/parse/model/object.rb — so we only need to set the ivar
          # here. No per-row singleton methods.
          obj.instance_variable_set(:@_vector_score, score) if score
          obj
        end.compact
      end

      # Build Parse::Object instances from fused hybrid rows, attaching
      # the fused score / per-branch ranks plus whatever per-branch scores
      # survived the merge (`_vscore`, `_score`).
      def build_hybrid_hits(rows)
        return [] if rows.nil? || rows.empty?
        converted = Parse::MongoDB.convert_documents_to_parse(rows, parse_class)
        converted.each_with_index.map do |doc, idx|
          obj = Parse::Object.build(doc, parse_class)
          next nil unless obj
          src = rows[idx]
          hscore = src["_hybrid_score"] || src[:_hybrid_score]
          hranks = src["_hybrid_ranks"] || src[:_hybrid_ranks]
          vscore = src["_vscore"] || src[:_vscore]
          sscore = src["_score"] || src[:_score]
          obj.instance_variable_set(:@_hybrid_score, hscore) unless hscore.nil?
          obj.instance_variable_set(:@_hybrid_ranks, hranks) unless hranks.nil?
          obj.instance_variable_set(:@_vector_score, vscore) unless vscore.nil?
          obj.instance_variable_set(:@_search_score, sscore) unless sscore.nil?
          obj
        end.compact
      end
    end
  end
end
