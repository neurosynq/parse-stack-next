# encoding: UTF-8
# frozen_string_literal: true

require_relative "pipeline_security"
require_relative "acl_scope"
require_relative "clp_scope"
require_relative "mongodb"
require_relative "atlas_search/protected_paths"

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
  # * `pointerFields` / `readUserFields` ownership `$match` after
  #   `$vectorSearch`, pushed into the `$vectorSearch.filter` prefilter
  #   when every owner pointer (`_p_<field>`) is declared as a
  #   `type: "filter"` field of the index.
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

    # How far past `k` the `$vectorSearch.limit` is raised when
    # something downstream can drop rows (ACL enforcement, a
    # caller-supplied `filter`, `protectedFields`, or pointer-field
    # filtering). Atlas applies `limit` BEFORE any of those run, so
    # without overfetching a caller who can read 2 of the top 10 asks
    # for 10 and receives 2 — even when hundreds of readable matches
    # exist further down the ranking.
    #
    # This is a mitigation, not a guarantee: a sufficiently selective
    # ACL can still exhaust any finite candidate window. Deterministic
    # fill would require `_rperm` declared as `type: "filter"` in the
    # Atlas index (so the prefilter enforces visibility) or iterative
    # candidate expansion. The instrumentation emitted by {.search}
    # exists so an underfill is observable rather than silent.
    DEFAULT_CANDIDATE_MULTIPLIER = 10

    # Ceiling on the internally-raised candidate window. Atlas caps
    # `numCandidates` at 10_000 and `numCandidates` must be >= `limit`,
    # so the candidate window cannot usefully exceed that.
    MAX_CANDIDATE_LIMIT = 10_000

    # Emitted once per {.search}. The counts are deliberately named for
    # where they are actually measured — there is no cheap way to learn
    # how many rows `$vectorSearch` emitted before the server-side
    # `$match` stages ran, so no field claims to be that number:
    #
    # * `candidate_limit` / `num_candidates` — the requested window.
    # * `post_filter_count` — rows returned by the pipeline, i.e. after
    #   the server-side ACL `$match`, the pointerFields `$match`, and any
    #   caller `filter`.
    # * `post_pointer_count` — rows left after client-side redaction and
    #   the defense-in-depth pointer-field re-check.
    # * `returned_count` — rows handed back, after trimming to `k`.
    # * `underfilled` — the caller received fewer than `k`.
    #
    # Obtaining a true pre-`$match` count would require a `$facet`, at
    # the cost of a second pass over the candidate set.
    AS_NOTIFICATION_NAME = "parse.vector_search.search"

    # Accepted {.index_drift_policy} values.
    INDEX_DRIFT_POLICIES = %i[warn raise ignore].freeze

    # Guards the lazy creation of the owner-prefilter negative cache mutex.
    PREFILTER_MUTEX_INIT = Mutex.new
    private_constant :PREFILTER_MUTEX_INIT

    class << self
      # Policy applied when first-query index verification (see
      # {Parse::Core::VectorSearchable}) finds the deployed Atlas
      # vectorSearch index disagreeing with the model declaration —
      # wrong `numDimensions`, wrong `similarity`, or a tenant-scope
      # field missing from the index's `filter` paths.
      #
      # * `:warn` (default) — emit a `[Parse::VectorSearch:DRIFT]`
      #   warning once per (class, field, index) and continue. Drift
      #   usually means the index predates a model change; queries
      #   still run but return degraded or wrongly-scoped results.
      # * `:raise` — fail the query with
      #   {Parse::Core::VectorSearchable::IndexDriftError}. Strict mode
      #   for deployments that treat drift as a release blocker.
      # * `:ignore` — skip verification entirely.
      #
      # @param value [Symbol]
      # @return [Symbol]
      def index_drift_policy=(value)
        v = value.respond_to?(:to_sym) ? value.to_sym : nil
        unless v && INDEX_DRIFT_POLICIES.include?(v)
          raise ArgumentError,
                "Parse::VectorSearch.index_drift_policy must be one of " \
                "#{INDEX_DRIFT_POLICIES.inspect} (got #{value.inspect})."
        end
        @index_drift_policy = v
      end

      # @return [Symbol] current drift policy (default `:warn`).
      def index_drift_policy
        @index_drift_policy ||= :warn
      end

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
                                  num_candidates: nil, candidate_limit: nil, filter: nil,
                                  vector_filter: nil, index: nil, max_time_ms: nil, **scope_opts)
        candidate_limit_override = candidate_limit
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

        # Anything that can drop rows AFTER Atlas has already applied
        # `limit` forces an overfetch, otherwise the caller silently
        # receives fewer than `k`. Master mode with no caller filter
        # has no attrition, so it keeps the old one-for-one cost.
        attrition_possible = !resolution.master? || !(filter.nil? || filter.empty?)
        candidate_limit = if candidate_limit_override
            Integer(candidate_limit_override)
          elsif attrition_possible
            [k_int * DEFAULT_CANDIDATE_MULTIPLIER, MAX_CANDIDATE_LIMIT].min
          else
            k_int
          end
        if candidate_limit < k_int
          raise ArgumentError,
                "candidate_limit (#{candidate_limit}) must be >= k (#{k_int})."
        end
        if candidate_limit > MAX_CANDIDATE_LIMIT
          raise ArgumentError,
                "candidate_limit capped at #{MAX_CANDIDATE_LIMIT} by Atlas (got #{candidate_limit})."
        end

        # ANN width stays anchored to `k`, NOT to the raised window.
        # Deriving it from `candidate_limit` would multiply twice and
        # silently widen the HNSW search by the candidate multiplier —
        # a scoped k=10 would jump from 200 to 2000 candidates. The
        # window only needs numCandidates to be at least as large as
        # `limit`, so take whichever is greater.
        derived_num_candidates =
          [k_int * DEFAULT_NUM_CANDIDATES_MULTIPLIER, candidate_limit].max
        num_candidates_int = (num_candidates || derived_num_candidates).to_i
        num_candidates_int = MAX_CANDIDATE_LIMIT if num_candidates_int > MAX_CANDIDATE_LIMIT &&
                                                    num_candidates.nil?

        # A caller-supplied num_candidates that predates the candidate
        # window used to be valid whenever it was >= k. Clamping the
        # implicit window down to it keeps those calls working rather
        # than turning them into a new ArgumentError. An EXPLICIT
        # candidate_limit still conflicts loudly — that combination can
        # only be a mistake.
        if num_candidates && num_candidates_int < candidate_limit
          if candidate_limit_override
            raise ArgumentError,
                  "num_candidates (#{num_candidates_int}) must be >= candidate_limit " \
                  "(#{candidate_limit})."
          end
          candidate_limit = [num_candidates_int, k_int].max
        end

        if num_candidates_int < k_int
          raise ArgumentError,
                "num_candidates (#{num_candidates_int}) must be >= k (#{k_int})."
        end
        if num_candidates_int > MAX_CANDIDATE_LIMIT
          raise ArgumentError,
                "num_candidates capped at #{MAX_CANDIDATE_LIMIT} by Atlas (got #{num_candidates_int})."
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
        assert_protected_fields_untouched!(collection_name, path, filter, vector_filter,
                                           protected_fields, resolution)

        vs_stage = {
          "index" => index_name.to_s,
          "path" => path,
          "queryVector" => validated_vector,
          "numCandidates" => num_candidates_int,
          # Deliberately the raised candidate window, not `k` — the
          # result set is trimmed to `k` after enforcement runs.
          "limit" => candidate_limit,
        }
        caller_prefilter = vector_filter if vector_filter && !vector_filter.empty?
        owner_prefilter = unless resolution.master?
            owner_vector_prefilter(collection_name, index_name, pointer_fields, resolution)
          end
        prefilter = [caller_prefilter, owner_prefilter].compact
        unless prefilter.empty?
          vs_stage["filter"] = prefilter.size == 1 ? prefilter.first : { "$and" => prefilter }
        end
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
          # pointerFields / readUserFields ownership, server-side so it
          # runs on the whole candidate window before the trim to `k`.
          # When every owner pointer is filter-indexed it also ran as the
          # `$vectorSearch.filter` prefilter above; this stage then drops
          # nothing but still covers the array-of-pointers storage form.
          if pointer_fields
            pipeline << {
              "$match" => Parse::CLPScope.pointer_fields_predicate(pointer_fields, resolution.user_id),
            }
          end
        end

        pipeline << { "$match" => filter } if filter

        authorizing_client = Parse::ACLScope.client_of(resolution)
        raw_results = begin
            run_pipeline!(collection_name, pipeline, max_time_ms: max_time_ms,
                                                     authorizing_client: authorizing_client)
          rescue StandardError => e
            raise unless owner_prefilter && owner_prefilter_rejected?(e, owner_prefilter)
            # Atlas is serving an index version without the owner filter
            # path (a rebuild in progress, or a stale cached definition).
            # Stop pushing it down and rerun once without it; the
            # ownership `$match` after `$vectorSearch` still enforces it.
            owner_prefilter_unavailable!(collection_name, index_name)
            if caller_prefilter
              vs_stage["filter"] = caller_prefilter
            else
              vs_stage.delete("filter")
            end
            run_pipeline!(collection_name, pipeline, max_time_ms: max_time_ms,
                                                     authorizing_client: authorizing_client)
          end
        # Already past the server-side ACL `$match` and any caller
        # `filter` — NOT the number $vectorSearch emitted.
        post_filter_count = raw_results.length

        # Post-fetch enforcement: walk the rows the same way
        # Parse::MongoDB.aggregate would. Master mode skips every
        # redaction layer (matches the helper's behavior).
        unless resolution.master?
          Parse::ACLScope.redact_results!(raw_results, resolution)
          Parse::CLPScope.redact_protected_fields!(raw_results, protected_fields) if protected_fields.any?
          # Defense in depth: the pointerFields `$match` already ran in
          # the pipeline, so this should drop nothing.
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

        # Trim only AFTER every enforcement layer has run — that
        # ordering is the whole point of the raised candidate window.
        post_pointer_count = raw_results.length
        raw_results = raw_results.first(k_int) if post_pointer_count > k_int

        emit_search_stats(
          collection_name: collection_name, k: k_int,
          candidate_limit: candidate_limit, num_candidates: num_candidates_int,
          post_filter_count: post_filter_count, post_pointer_count: post_pointer_count,
          returned_count: raw_results.length, master: resolution.master?,
        )

        raw_results
      end

      # @!visibility private
      # Emit per-search counts so ACL/filter attrition is observable.
      # `underfilled` means the caller received fewer rows than they
      # asked for — the signal worth alerting on, since it means either
      # the candidate window was too small for this principal or the
      # collection simply ran out of matches. Distinguishing those two
      # would need a pre-`$match` count, which this deliberately does
      # not fabricate.
      def emit_search_stats(**payload)
        return unless defined?(ActiveSupport::Notifications)

        payload[:pointer_attrition] =
          payload[:post_filter_count] - payload[:post_pointer_count]
        payload[:underfilled] = payload[:returned_count] < payload[:k]
        ActiveSupport::Notifications.instrument(AS_NOTIFICATION_NAME, payload)
        nil
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

      # @!visibility private
      # Whether an error is Atlas refusing one of the owner prefilter's
      # paths because the served index does not declare it as
      # `type: "filter"`. Atlas words the refusal the same way for any
      # path, so the message must name an owner path: a caller
      # `vector_filter` on an unindexed field raises as it always did and
      # does not switch the owner prefilter off for other callers.
      # @param error [Exception]
      # @param owner_prefilter [Hash] the owner clause that was pushed down.
      # @return [Boolean]
      def owner_prefilter_rejected?(error, owner_prefilter)
        message = error.message.to_s
        return false unless message.match?(PREFILTER_REJECTED_PATTERN)
        owner_prefilter_paths(owner_prefilter).any? { |path| message.include?(path) }
      end

      # @!visibility private
      # The `_p_<field>` paths an owner prefilter clause names.
      # @param owner_prefilter [Hash]
      # @return [Array<String>]
      def owner_prefilter_paths(owner_prefilter)
        return [] unless owner_prefilter.is_a?(Hash)
        clauses = owner_prefilter.key?("$or") ? Array(owner_prefilter["$or"]) : [owner_prefilter]
        clauses.flat_map { |c| c.is_a?(Hash) ? c.keys.map(&:to_s) : [] }.select { |k| k.start_with?("_p_") }
      end

      # @!visibility private
      # Stop pushing the owner prefilter down for this index until the
      # index cache TTL passes, and drop the cached index definition so
      # the next lookup reads what Atlas now reports.
      # @param collection_name [String]
      # @param index_name [String, Symbol]
      def owner_prefilter_unavailable!(collection_name, index_name)
        require_relative "atlas_search"
        Parse::AtlasSearch::IndexManager.clear_cache(collection_name)
        mark_prefilter_unavailable(prefilter_cache_key(collection_name, index_name))
      end

      # @!visibility private
      # Forget every negative prefilter lookup (tests, or after an
      # operator fixes the index and does not want to wait out the TTL).
      def clear_prefilter_cache!
        prefilter_mutex.synchronize { @prefilter_unavailable = {} }
        nil
      end

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
        # Same CLP branch evaluation as Parse::MongoDB.aggregate (public,
        # user, and role grants first; then pointerFields / readUserFields).
        # Raises Parse::CLPScope::Denied when the scope cannot find at all.
        Parse::CLPScope.row_constraint_for!(collection_name, :find, resolution,
                                            label: "VectorSearch")
        nil
      end

      # Resolve and return pointerFields for `find` on the collection.
      # Refuse a scoped vector search that lets a protected field decide
      # which rows match or how they rank: a protected vector `field:`, a
      # `filter:` / `vector_filter:` predicate keyed on a protected field
      # (top level or under $and/$or/$nor/$not, dotted or `_p_` form), or
      # an `$expr` reference to one. The output strip alone does not close
      # that oracle. Master scopes and classes with nothing protected are
      # unaffected.
      #
      # @raise [Parse::CLPScope::Denied]
      def assert_protected_fields_untouched!(collection_name, path, filter, vector_filter,
                                             protected_fields, resolution)
        paths = Parse::AtlasSearch::ProtectedPaths
        return unless paths.enforce?(resolution, protected_fields)
        paths.assert_paths_allowed!(path, protected_fields, resolution,
                                    collection_name: collection_name,
                                    method_name: "Parse::VectorSearch.search",
                                    what: "vector field")
        [filter, vector_filter].each do |f|
          next if f.nil? || f.empty?
          Parse::PipelineSecurity.refuse_protected_field_references!(
            [{ "$match" => f }], collection_name, resolution,
          )
          paths.assert_filter_allowed!(f, protected_fields, resolution,
                                       collection_name: collection_name,
                                       method_name: "Parse::VectorSearch.search")
        end
        nil
      end

      # Raises CLPScope::Denied when pointerFields is set but the
      # current scope has no user_id (acl_role-only / public agents).
      # Returns nil when master-mode or no pointerFields entry exists.
      def resolve_pointer_fields!(collection_name, resolution)
        # nil when a public, user, or role grant already permits every row
        # (Parse Server ignores pointer permissions then); otherwise the
        # pointerFields plus readUserFields the rows must match. The older
        # permits? / pointer_fields_for pair missed readUserFields entirely
        # and over-restricted a public grant that also listed pointerFields.
        Parse::CLPScope.row_constraint_for!(collection_name, :find, resolution,
                                            label: "VectorSearch")
      end

      # The pointerFields ownership constraint as a `$vectorSearch.filter`
      # clause, or nil when it cannot be pushed down. Atlas only accepts a
      # prefilter on paths declared `type: "filter"` in the index, so this
      # applies only when every owner pointer's storage path
      # (`_p_<field>`) is filter-indexed. A prefilter keeps other users'
      # rows out of the candidate window entirely, so an owner-scoped
      # caller is not underfilled by higher-ranked rows they cannot read.
      # Any lookup failure returns nil: the post-`$vectorSearch` `$match`
      # still enforces ownership, only the fill is weaker.
      #
      # The prefilter matches only the scalar `_p_<field>` storage form.
      # CLP ownership also accepts an array of pointers stored under the
      # bare field name, so pushing down on such a field would drop rows
      # the caller owns. It is therefore used only when every owner field
      # is declared as a scalar pointer on the local model.
      def owner_vector_prefilter(collection_name, index_name, pointer_fields, resolution)
        return nil if pointer_fields.nil? || pointer_fields.empty?
        uid = resolution.user_id.to_s
        return nil if uid.empty?
        return nil unless scalar_pointer_fields?(collection_name, pointer_fields)
        paths = pointer_fields.map { |f| "_p_#{f}" }
        indexed = vector_filter_paths(collection_name, index_name)
        return nil unless paths.all? { |path| indexed.include?(path) }
        storage = "#{Parse::Model::CLASS_USER}$#{uid}"
        clauses = paths.map { |path| { path => { "$eq" => storage } } }
        clauses.size == 1 ? clauses.first : { "$or" => clauses }
      end

      # Whether every owner field is declared as a scalar pointer
      # (`belongs_to`) on the local model for the collection. Read from the
      # model's declared fields, so no schema request is made. An unknown
      # class, an undeclared field, or an array field all answer false.
      def scalar_pointer_fields?(collection_name, pointer_fields)
        klass = Parse::Model.find_class(collection_name.to_s)
        return false unless klass.respond_to?(:fields)
        fields = klass.fields
        pointer_fields.all? { |f| fields[f.to_s.to_sym] == :pointer }
      rescue StandardError
        false
      end

      # Paths the named vectorSearch index declares as `type: "filter"`.
      # Read through {Parse::AtlasSearch::IndexManager}, which caches the
      # `$listSearchIndexes` result. Empty unless the index is READY and
      # serving its latest definition: during a rebuild
      # `latestDefinition` already lists the new filter path while Atlas
      # still serves the old version, and a prefilter on that path is
      # refused. A lookup error is remembered for the index cache TTL so a
      # deployment without the `listSearchIndexes` privilege does not pay
      # a failing round trip on every search.
      def vector_filter_paths(collection_name, index_name)
        key = prefilter_cache_key(collection_name, index_name)
        return Set.new if prefilter_unavailable?(key)
        require_relative "atlas_search"
        idx = begin
            Parse::AtlasSearch::IndexManager.get_index(collection_name, index_name.to_s)
          rescue StandardError
            mark_prefilter_unavailable(key)
            return Set.new
          end
        return Set.new unless idx && index_serving_latest?(idx)
        defn = idx["latestDefinition"] || idx[:latestDefinition] || {}
        Array(defn["fields"] || defn[:fields]).each_with_object(Set.new) do |f, set|
          next unless (f["type"] || f[:type]).to_s == "filter"
          set << (f["path"] || f[:path]).to_s
        end
      end

      # Whether Atlas is serving the index's latest definition: status
      # READY and, when per-host `statusDetail` is reported, every host's
      # main index at `latestDefinitionVersion`. Missing status fails
      # toward "not serving" so the prefilter is simply skipped.
      def index_serving_latest?(idx)
        return false unless (idx["status"] || idx[:status]).to_s.upcase == "READY"
        latest = definition_version(idx["latestDefinitionVersion"] || idx[:latestDefinitionVersion])
        details = Array(idx["statusDetail"] || idx[:statusDetail])
        return true if latest.nil? || details.empty?
        details.all? do |detail|
          main = detail["mainIndex"] || detail[:mainIndex]
          main && definition_version(main["definitionVersion"] || main[:definitionVersion]) == latest
        end
      end

      def definition_version(value)
        return nil unless value.is_a?(Hash)
        value["version"] || value[:version]
      end

      PREFILTER_REJECTED_PATTERN = /indexed as (?:a )?filter/i
      private_constant :PREFILTER_REJECTED_PATTERN

      def prefilter_cache_key(collection_name, index_name)
        "#{collection_name}\x1f#{index_name}"
      end

      def prefilter_mutex
        @prefilter_mutex ||= PREFILTER_MUTEX_INIT.synchronize { @prefilter_mutex ||= Mutex.new }
      end

      def prefilter_unavailable?(key)
        prefilter_mutex.synchronize do
          expires = (@prefilter_unavailable ||= {})[key]
          next false unless expires
          next true if Process.clock_gettime(Process::CLOCK_MONOTONIC) < expires
          @prefilter_unavailable.delete(key)
          false
        end
      end

      def mark_prefilter_unavailable(key)
        require_relative "atlas_search"
        ttl = Parse::AtlasSearch::IndexManager.cache_ttl.to_f
        return if ttl <= 0
        prefilter_mutex.synchronize do
          (@prefilter_unavailable ||= {})[key] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + ttl
        end
      end

      # Execute the pipeline directly against the MongoDB collection.
      # Mirrors `Parse::AtlasSearch#run_atlas_pipeline!` — bypasses
      # `Parse::MongoDB.aggregate` because that helper prepends an
      # ACL `$match` at stage 0, which Atlas rejects for any pipeline
      # whose stage 0 is `$vectorSearch`.
      def run_pipeline!(collection_name, pipeline, max_time_ms: nil, authorizing_client: nil)
        agg_opts = {}
        max_time_ms ||= Parse::PipelineSecurity.regex_time_budget(pipeline)
        agg_opts[:max_time_ms] = max_time_ms if max_time_ms
        # Vector search bypasses Parse::MongoDB.aggregate, so the binding
        # guard only sees this read if the authorizing client arrives here.
        coll = Parse::MongoDB.collection(collection_name, authorizing_client: authorizing_client)
        coll.aggregate(pipeline, agg_opts).to_a
      rescue => e
        Parse::MongoDB.send(:raise_if_timeout!, e, collection_name, max_time_ms)
        raise
      end
    end

    @default_index = nil
  end
end

require_relative "vector_search/index_definition"
