# encoding: UTF-8
# frozen_string_literal: true

require_relative "pipeline_security"
require_relative "acl_scope"
require_relative "clp_scope"
require_relative "mongodb"

module Parse
  # Atlas Vector Search entry point. Routes through `Parse::MongoDB`
  # rather than Parse Server's REST aggregate (REST aggregate is master-
  # key-only and bypasses ACL/CLP — see CLAUDE.md).
  #
  # v5.0 ships the low-level surface only:
  #
  #   Parse::VectorSearch.search(
  #     "WikiArticle",
  #     field: :embedding,
  #     query_vector: vec,
  #     k: 10,
  #     index: "WikiArticle_embedding_voyage_multimodal_3_1024_idx",
  #     session_token: token,
  #   )
  #
  # The high-level `Class.find_similar(text: …)` wrapper and the
  # `:vector` property type land later in the v5.0 cycle. This module
  # is callable today against any collection that has a queryable
  # `vectorSearch` index — including the `vector_prototype.Movie`
  # fixture in `scripts/vector_prototype/`.
  #
  # == Stage 0 invariant
  #
  # Atlas refuses any pipeline whose stage 0 is not `$vectorSearch`,
  # `$search`, or `$searchMeta`. The module therefore bypasses
  # `Parse::MongoDB.aggregate` (which prepends an ACL `$match` at
  # stage 0) and reproduces the SDK-side enforcement chain inline —
  # ACL `$match` is appended AFTER `$vectorSearch`, mirroring
  # `Parse::AtlasSearch.search`.
  #
  # == ACL / CLP enforcement
  #
  # Identity is resolved through {Parse::ACLScope.resolve!}, so the
  # same kwargs accepted by mongo-direct paths are honored here:
  # `session_token:`, `master: true`, `acl_user:`, `acl_role:`. The
  # resolution drives:
  #
  # * CLP `find` boundary check — refuses calls the equivalent REST
  #   find would refuse.
  # * Optional `pointerFields` post-filter — drops rows that don't
  #   name the current user_id in the configured pointer fields.
  # * Post-`$vectorSearch` ACL `$match` injection (Parse Server's
  #   `_rperm` predicate).
  # * Post-fetch `protectedFields` redaction.
  #
  # `master: true` bypasses ACL/CLP injection (matches the standard
  # mongo-direct semantics). The unconditional
  # {Parse::PipelineSecurity.strip_internal_fields} pass runs on
  # every result row regardless of mode, so `_hashed_password` and
  # friends never appear in returned documents.
  module VectorSearch
    # Raised when the caller's query vector has the wrong shape.
    # Inherits from `ArgumentError` so callers can rescue uniformly
    # alongside the other bad-input `ArgumentError`s raised inline by
    # {.search} (bad k, bad field, bad num_candidates).
    class InvalidQueryVector < ArgumentError; end

    # Raised when the module is called but `Parse::MongoDB` is not
    # configured.
    class NotAvailable < StandardError; end

    # Raised when a `Parse::Query` constraint is built against a
    # declared `:vector` property using an operator other than the
    # narrow allow-list (`:exists`, `:null`). Vector fields are dense
    # numeric arrays — equality, range, `$in`, and friends will either
    # return nonsense or do something the caller did not intend. The
    # right way to query a `:vector` is {Parse::Core::VectorSearchable#find_similar},
    # which routes through Atlas `$vectorSearch`. Inherits from
    # {ArgumentError} so it joins {InvalidQueryVector} and the inline
    # bad-input raises in a single rescue boundary.
    class ConstraintNotSupported < ArgumentError; end

    # Hard cap on query-vector dimensions to bound validator work and
    # to refuse obvious garbage (the largest production-grade model
    # today, Voyage `voyage-multimodal-3`, is 1024-dim; OpenAI
    # `text-embedding-3-large` is 3072-dim).
    MAX_DIMENSIONS = 8192

    # Hard cap on `limit` (k). Atlas itself caps `$vectorSearch.limit`
    # at 10_000 but practical RAG workloads stay well below that;
    # tighter cap here keeps a runaway caller from materializing a
    # huge result set client-side.
    MAX_K = 1000

    # Default `numCandidates` multiplier when the caller doesn't pass
    # one. Atlas's guidance: numCandidates ≥ 10 × limit, ≤ 10_000.
    DEFAULT_NUM_CANDIDATES_MULTIPLIER = 20

    class << self
      # Low-level `$vectorSearch` entry point.
      #
      # @param collection_name [String] Parse class name / Mongo
      #   collection name. Treated as a literal collection name; no
      #   property-type lookup happens at this layer.
      # @param field [String, Symbol] vector field path inside the
      #   document. Must match `path:` on the Atlas index definition.
      # @param query_vector [Array<Float>] the query embedding.
      # @param k [Integer] number of hits to return. Capped at
      #   {MAX_K}.
      # @param num_candidates [Integer, nil] Atlas's HNSW search
      #   width. Defaults to `k * DEFAULT_NUM_CANDIDATES_MULTIPLIER`.
      # @param filter [Hash, nil] additional post-`$vectorSearch`
      #   match (validated by {Parse::PipelineSecurity.validate_filter!}).
      #   For pre-search filtering use `vector_filter:`.
      # @param vector_filter [Hash, nil] Atlas-native pre-search
      #   filter, injected into `$vectorSearch.filter`. Atlas requires
      #   the referenced fields be declared as `type: "filter"` in the
      #   index definition. Validated by
      #   {Parse::PipelineSecurity.validate_filter!}.
      # @param index [String, nil] Atlas vectorSearch index name. If
      #   nil, falls back to {.default_index}.
      # @param session_token [String, nil] session token for ACL/CLP
      #   resolution via {Parse::ACLScope.resolve!}.
      # @param master [Boolean] explicit master-key opt-in; bypasses
      #   ACL/CLP enforcement.
      # @param acl_user [Parse::User, Parse::Pointer, nil] pre-resolved
      #   user pointer for ACL scoping.
      # @param acl_role [String, Parse::Role, nil] role-only scope.
      # @param max_time_ms [Integer, nil] server-side timeout.
      # @return [Array<Hash>] raw result documents. Each row includes
      #   `_vscore` (the Atlas vectorSearchScore — projected under
      #   `_vscore` rather than `_score` so hybrid pipelines with
      #   Atlas Search don't collide on the same key).
      def search(collection_name, field:, query_vector:, k: 10,
                 num_candidates: nil, filter: nil, vector_filter: nil,
                 index: nil, max_time_ms: nil, **scope_opts)
        require_available!
        index_name = (index || @default_index)
        if index_name.nil? || index_name.to_s.empty?
          raise ArgumentError,
                "Parse::VectorSearch.search requires index: (or set Parse::VectorSearch.default_index)."
        end

        # `Parse::ACLScope.resolve!` mutates the options hash by deleting
        # auth kwargs. Pass a fresh hash so we don't accidentally drop
        # caller kwargs and so `resolve!` can refuse 2-of-N combinations.
        resolution = Parse::ACLScope.resolve!(scope_opts, method_name: :"VectorSearch.search")

        path = field.to_s
        if path.empty? || path.start_with?("$") || path.include?(".")
          raise ArgumentError,
                "field: must be a non-empty, non-$-prefixed, non-dotted field name."
        end
        if Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST.include?(path) ||
           path.start_with?("_auth_data_")
          raise ArgumentError,
                "field: refuses internal/sensitive field path #{path.inspect}."
        end

        k_int = Integer(k)
        if k_int <= 0 || k_int > MAX_K
          raise ArgumentError, "k must be in 1..#{MAX_K} (got #{k_int})."
        end

        num_candidates_int = (num_candidates || (k_int * DEFAULT_NUM_CANDIDATES_MULTIPLIER)).to_i
        if num_candidates_int < k_int
          raise ArgumentError, "num_candidates (#{num_candidates_int}) must be >= k (#{k_int})."
        end
        if num_candidates_int > 10_000
          raise ArgumentError, "num_candidates capped at 10000 by Atlas (got #{num_candidates_int})."
        end

        validated_vector = validate_query_vector!(query_vector)

        Parse::PipelineSecurity.validate_filter!(filter) if filter
        Parse::PipelineSecurity.validate_filter!(vector_filter) if vector_filter

        # CLP `find` boundary + pointerFields. Mirrors
        # `Parse::AtlasSearch.search` — without this, a scoped caller
        # could issue $vectorSearch against a collection whose CLP
        # would refuse them on the equivalent REST find.
        assert_clp_find!(collection_name, resolution)
        pointer_fields = resolve_pointer_fields!(collection_name, resolution)
        protected_fields = Parse::CLPScope.protected_fields_for(
          collection_name, resolution.permission_strings,
        )

        vs_stage = {
          "index"         => index_name.to_s,
          "path"          => path,
          "queryVector"   => validated_vector,
          "numCandidates" => num_candidates_int,
          "limit"         => k_int,
        }
        vs_stage["filter"] = vector_filter if vector_filter && !vector_filter.empty?
        pipeline = [{ "$vectorSearch" => vs_stage }]

        pipeline << {
          "$addFields" => { "_vscore" => { "$meta" => "vectorSearchScore" } },
        }

        # Inject ACL $match AFTER $vectorSearch + the score projection
        # but BEFORE the caller-supplied filter, so the user-controlled
        # filter cannot exfiltrate restricted documents that passed the
        # $vectorSearch operator. NOTE: Atlas's `$vectorSearch.filter`
        # (the pre-filter) cannot enforce ACL here because `_rperm`
        # would need to be declared as `type: "filter"` in the index
        # definition — out of scope at the SDK layer. The post-stage
        # `$match` is the enforcement boundary.
        unless resolution.master?
          acl_match = Parse::ACLScope.match_stage_for(resolution)
          pipeline << acl_match if acl_match
        end

        pipeline << { "$match" => filter } if filter

        raw_results = run_pipeline!(collection_name, pipeline, max_time_ms: max_time_ms)

        # Post-fetch enforcement: walk the rows the same way
        # Parse::MongoDB.aggregate would. Master mode skips every
        # redaction layer (matches the helper's behavior).
        unless resolution.master?
          Parse::ACLScope.redact_results!(raw_results, resolution)
          Parse::CLPScope.redact_protected_fields!(raw_results, protected_fields) if protected_fields.any?
          if pointer_fields
            raw_results = Parse::CLPScope.filter_by_pointer_fields(
              raw_results, pointer_fields, resolution.user_id,
            )
          end
        end

        # Internal-fields denylist is the process-level floor: runs in
        # every mode, master included, so `_hashed_password` /
        # `_session_token` can never surface through this entry point.
        raw_results.map! { |doc| Parse::PipelineSecurity.strip_internal_fields(doc) }
        raw_results
      end

      # Validate a query vector. Public so callers (and tests) can
      # invoke it independently of {.search}.
      #
      # @param vec [Array<Float>] candidate query vector.
      # @param dimensions [Integer, nil] expected length; nil to skip
      #   the length check.
      # @return [Array<Float>] the vector, coerced to Float and
      #   frozen.
      # @raise [InvalidQueryVector] on bad shape, infinite, or NaN
      #   values.
      def validate_query_vector!(vec, dimensions: nil)
        unless vec.is_a?(Array)
          raise InvalidQueryVector, "query_vector must be an Array (got #{vec.class})."
        end
        if vec.empty?
          raise InvalidQueryVector, "query_vector cannot be empty."
        end
        if vec.length > MAX_DIMENSIONS
          raise InvalidQueryVector,
                "query_vector length #{vec.length} exceeds MAX_DIMENSIONS=#{MAX_DIMENSIONS}."
        end
        if dimensions && vec.length != dimensions
          raise InvalidQueryVector,
                "query_vector length #{vec.length} != declared dimensions #{dimensions}."
        end
        out = Array.new(vec.length)
        vec.each_with_index do |v, i|
          unless v.is_a?(Numeric)
            raise InvalidQueryVector, "query_vector[#{i}] is not numeric (#{v.class})."
          end
          f = v.to_f
          unless f.finite?
            raise InvalidQueryVector, "query_vector[#{i}] is not finite (#{v.inspect})."
          end
          out[i] = f
        end
        out.freeze
      end

      # @!attribute [rw] default_index
      #   Optional fallback for {.search}'s `index:` keyword.
      #   @return [String, nil]
      attr_accessor :default_index

      private

      def require_available!
        Parse::MongoDB.require_gem!
        unless Parse::MongoDB.available?
          raise NotAvailable,
                "Parse::VectorSearch requires Parse::MongoDB.configure(enabled: true)."
        end
      end

      # CLP `find` boundary check. Master-mode skips; for every other
      # scope, refuse the call when the resolved claim set can't
      # `find` on the collection. Mirrors `Parse::AtlasSearch.search`.
      def assert_clp_find!(collection_name, resolution)
        return if resolution.nil? || resolution.master?
        unless Parse::CLPScope.permits?(collection_name, :find, resolution.permission_strings)
          raise Parse::CLPScope::Denied.new(
            collection_name, :find,
            "CLP refuses find on '#{collection_name}' for the current VectorSearch scope.",
          )
        end
      end

      # Resolve and return pointerFields for `find` on the collection.
      # Raises CLPScope::Denied when pointerFields is set but the
      # current scope has no user_id (acl_role-only / public agents).
      # Returns nil when master-mode or no pointerFields entry exists.
      def resolve_pointer_fields!(collection_name, resolution)
        return nil if resolution.nil? || resolution.master?
        pointer_fields = Parse::CLPScope.pointer_fields_for(collection_name, :find)
        return nil if pointer_fields.nil?
        if resolution.user_id.nil?
          raise Parse::CLPScope::Denied.new(
            collection_name, :find,
            "CLP requires user identity (pointerFields=#{pointer_fields.inspect}) " \
            "but the current VectorSearch scope has no user_id.",
          )
        end
        pointer_fields
      end

      # Execute the pipeline directly against the MongoDB collection.
      # Mirrors `Parse::AtlasSearch#run_atlas_pipeline!` — bypasses
      # `Parse::MongoDB.aggregate` because that helper prepends an
      # ACL `$match` at stage 0, which Atlas rejects for any pipeline
      # whose stage 0 is `$vectorSearch`.
      def run_pipeline!(collection_name, pipeline, max_time_ms: nil)
        agg_opts = {}
        agg_opts[:max_time_ms] = max_time_ms if max_time_ms
        coll = Parse::MongoDB.collection(collection_name)
        coll.aggregate(pipeline, agg_opts).to_a
      rescue => e
        Parse::MongoDB.send(:raise_if_timeout!, e, collection_name, max_time_ms)
        raise
      end
    end

    @default_index = nil
  end
end
