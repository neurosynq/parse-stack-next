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

      # Raised (under `Parse::VectorSearch.index_drift_policy = :raise`)
      # when first-query verification finds the deployed vectorSearch
      # index disagreeing with the model declaration — wrong
      # `numDimensions`, wrong `similarity`, or a registered
      # tenant-scope field missing from the index's `filter` paths.
      # Under the default `:warn` policy the same findings emit a
      # single `[Parse::VectorSearch:DRIFT]` warning instead.
      class IndexDriftError < StandardError
        # @return [Array<String>] human-readable drift findings.
        attr_reader :findings
        def initialize(message, findings: [])
          @findings = findings
          super(message)
        end
      end

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
        # Spend cap: every query-embed path (find_similar(text:),
        # hybrid_search(text:), Retrieval.retrieve) funnels through this
        # method, so charging here closes the "direct callers bypass the
        # cap" gap. No-op when no limit is configured, or when an
        # upstream caller (the semantic_search agent tool) has already
        # charged with per-tenant identity (SpendCap.with_precharged).
        #
        # Deliberate: the charge runs BEFORE the cache lookup, so cache
        # hits bill at full price. The cap bounds query *volume* (an
        # abuse/probing control), not just provider spend — a caller
        # replaying one cached query must not get unlimited throughput.
        Parse::Embeddings::SpendCap.charge_query!(text)
        # Query-embed cache: repeated identical queries skip the
        # provider round-trip when Parse::Embeddings::Cache.enable! has
        # been called; pass-through (with the provider's own response
        # validation preserved) when disabled.
        Parse::Embeddings::Cache.fetch_vector(provider, text, input_type: :search_query)
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
        if explicit_index && !explicit_index.to_s.empty?
          verify_explicit_vector_index(field, explicit_index.to_s)
          return explicit_index
        end
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
        verify_vector_index!(field, idx)
        (idx["name"] || idx[:name]).to_s
      end

      # Best-effort drift verification for an explicitly named `index:`.
      # The auto-discovery path verifies the index it resolves; an
      # explicit kwarg would otherwise skip verification entirely. Look
      # the field's covering index up in the catalog and verify it when
      # its name matches the explicit one. Lookup failures (catalog
      # unavailable, index not discoverable, name targeting a different
      # index) skip verification rather than failing the query — the
      # explicit kwarg is an override, not a discovery request.
      def verify_explicit_vector_index(field, index_name)
        return if Parse::VectorSearch.index_drift_policy == :ignore
        begin
          require_relative "../../atlas_search"
          idx = Parse::AtlasSearch::IndexCatalog.find_vector_index(parse_class, field: field)
        rescue StandardError, LoadError
          return
        end
        return if idx.nil?
        return unless (idx["name"] || idx[:name]).to_s == index_name
        verify_vector_index!(field, idx)
      end

      # First-query drift verification: compare the deployed index's
      # `latestDefinition` against the model declaration. The drift
      # findings are computed once per (field, index name) per class per
      # process and cached; the policy check runs on EVERY query, so
      # under `:raise` a drifted index keeps failing instead of failing
      # once and then silently serving results. Under `:warn` the
      # warning is emitted only on the first check to avoid log spam.
      # Honors {Parse::VectorSearch.index_drift_policy} (`:warn` default
      # / `:raise` / `:ignore`).
      #
      # Checks:
      # 1. `numDimensions` on the covering `type: "vector"` entry vs the
      #    property's declared `dimensions:`.
      # 2. `similarity` vs the property's declared `similarity:` (only
      #    when both sides declare one).
      # 3. When the class registers an `agent_tenant_scope`, the scope
      #    field must appear among the index's `type: "filter"` paths —
      #    otherwise the tenant pre-filter that
      #    {Parse::Retrieval.retrieve} folds into `$vectorSearch.filter`
      #    fails Atlas-side at query time.
      def verify_vector_index!(field, idx)
        return if Parse::VectorSearch.index_drift_policy == :ignore
        index_name = (idx["name"] || idx[:name]).to_s
        @_verified_vector_indexes ||= {}
        cache_key = "#{field}|#{index_name}"
        findings = @_verified_vector_indexes[cache_key]
        first_check = findings.nil?
        if first_check
          findings = vector_index_drift_findings(field, idx).freeze
          @_verified_vector_indexes[cache_key] = findings
        end
        return if findings.empty?

        message = "#{self} vectorSearch index #{index_name.inspect} drifts from the " \
                  "model declaration for :#{field}: #{findings.join("; ")}"
        if Parse::VectorSearch.index_drift_policy == :raise
          # Raise on every query, not just the first: strict mode means a
          # drifted index must never serve results.
          raise IndexDriftError.new(message, findings: findings)
        end
        warn "[Parse::VectorSearch:DRIFT] #{message}" if first_check
      end

      # @!visibility private
      # @return [Array<String>] drift findings (empty when in sync).
      def vector_index_drift_findings(field, idx)
        defn = idx["latestDefinition"] || idx[:latestDefinition] || {}
        entries = defn["fields"] || defn[:fields] || []
        field_str = field.to_s
        vector_entry = entries.find do |f|
          (f["type"] || f[:type]).to_s == "vector" && (f["path"] || f[:path]).to_s == field_str
        end
        findings = []
        return findings if vector_entry.nil? # find_vector_index matched on it; defensive

        declared_dims = vector_properties.dig(field.to_sym, :dimensions)
        index_dims = vector_entry["numDimensions"] || vector_entry[:numDimensions]
        if declared_dims && index_dims && Integer(index_dims) != Integer(declared_dims)
          findings << "index numDimensions=#{index_dims} but property declares " \
                      "dimensions: #{declared_dims} (every query will mismatch — " \
                      "rebuild the index or run #{self}.reembed! after fixing the declaration)"
        end

        declared_sim = vector_properties.dig(field.to_sym, :similarity)
        index_sim = vector_entry["similarity"] || vector_entry[:similarity]
        if declared_sim && index_sim && index_sim.to_s != declared_sim.to_s
          findings << "index similarity=#{index_sim.inspect} but property declares " \
                      "similarity: #{declared_sim.inspect}"
        end

        scope_field = registered_tenant_scope_field
        if scope_field
          filter_paths = entries.select { |f| (f["type"] || f[:type]).to_s == "filter" }
                                .map { |f| (f["path"] || f[:path]).to_s }
          unless filter_paths.include?(scope_field)
            findings << "agent_tenant_scope field #{scope_field.inspect} is not declared " \
                        "as a type: \"filter\" path in the index — tenant-scoped " \
                        "$vectorSearch.filter will fail Atlas-side"
          end
        end
        findings
      end

      # @!visibility private
      # Wire/storage name of the class's registered tenant-scope field,
      # or nil. Mirrors the resolution Parse::Retrieval#wire_name uses
      # when folding the scope into $vectorSearch.filter.
      def registered_tenant_scope_field
        return nil unless defined?(Parse::Agent::MetadataRegistry)
        rule = Parse::Agent::MetadataRegistry.tenant_scope_rule(parse_class)
        return nil unless rule
        sym = rule[:field].to_sym
        fmap = respond_to?(:field_map) ? field_map : {}
        (fmap[sym] || sym.to_s.columnize).to_s
      rescue StandardError
        nil
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
