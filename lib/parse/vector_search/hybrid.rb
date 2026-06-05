# encoding: UTF-8
# frozen_string_literal: true

require_relative "../vector_search"

module Parse
  module VectorSearch
    # Hybrid (lexical + vector) search with reciprocal-rank fusion.
    #
    # Lexical search (`Parse::AtlasSearch`, BM25/`$search`) nails
    # exact-token matches — proper nouns, SKU codes, "OAuth 2.0". Vector
    # search (`Parse::VectorSearch`, `$vectorSearch`) nails paraphrase —
    # "login token spec". Fusing the two beats either alone on most real
    # workloads.
    #
    # == Why two aggregations (and not one `$facet`)
    #
    # `$vectorSearch` is explicitly prohibited inside `$facet`,
    # `$lookup`, `$unionWith`, or any compound stage on every Atlas
    # version, and it must be the FIRST stage of its pipeline. So on
    # pre-Atlas-8.0 clusters the only correct shape is two independent
    # aggregations followed by client-side reciprocal-rank fusion (RRF).
    # On Atlas 8.0+ the native `$rankFusion` stage performs the same
    # fusion server-side in a single round-trip; {.rank_fusion_supported?}
    # detects it (probe-and-cache, not version-string parsing).
    #
    # == ACL / CLP enforcement
    #
    # The client-side path delegates each branch to an entry point that
    # already enforces the full SDK-side chain — {Parse::AtlasSearch.search}
    # (lexical) and {Parse::VectorSearch.search} (vector). Both apply the
    # CLP `find` boundary, the post-stage `_rperm` `$match`, pointerFields
    # filtering, `protectedFields` redaction, and the internal-fields
    # denylist BEFORE returning rows. Fusion therefore operates only on
    # rows the caller is already allowed to read; there is no separate
    # hydration fetch to re-secure. The native `$rankFusion` path
    # reproduces the same enforcement inline (CLP `find`, post-stage ACL
    # `$match`, post-fetch redaction), mirroring {Parse::VectorSearch.search}.
    #
    # == Scores
    #
    # The vector branch projects `_vscore` (Atlas `vectorSearchScore`),
    # the lexical branch `_score` (Atlas `searchScore`). The fused row
    # carries `_hybrid_score` (the summed RRF weight) and `_hybrid_ranks`
    # (`{ lexical: <rank>, vector: <rank> }`, 1-based, absent for a branch
    # the row did not appear in). The raw branch scores are preserved on
    # the row for callers that want them.
    module Hybrid
      # Raised on malformed fusion input (bad weights, non-positive
      # `k_constant`, empty branch set). Inherits {ArgumentError} so it
      # joins the other bad-input raises in a single rescue boundary.
      class FusionError < ArgumentError; end

      # Standard RRF rank constant. Larger values flatten the
      # contribution curve (later ranks matter more); 60 is the value
      # from the original Cormack et al. RRF paper and the Atlas
      # `$rankFusion` default.
      DEFAULT_K_CONSTANT = 60

      # Default number of fused hits returned.
      DEFAULT_K = 20

      # Per-branch oversample multiplier. Each branch fetches
      # `k * this` candidates so a row ranked low in one branch but high
      # in the other still has a rank to fuse. Atlas's own `$rankFusion`
      # uses a comparable internal oversample.
      DEFAULT_OVERSAMPLE_MULTIPLIER = 5

      # Hard ceiling on the fused result count, matching
      # {Parse::VectorSearch::MAX_K}.
      MAX_K = Parse::VectorSearch::MAX_K

      # TTL (seconds) for the {.rank_fusion_supported?} probe cache. A
      # cluster gaining or losing `$rankFusion` support is a rare,
      # operator-driven event (an Atlas major-version upgrade), so a
      # 1-hour cache keeps the extra probe round-trip off the hot path.
      PROBE_CACHE_TTL = 3600

      class << self
        # Pure reciprocal-rank fusion. Operates on already-fetched,
        # already-ranked branch result lists — no I/O, no ACL concerns
        # (the rows were enforced upstream).
        #
        # `fused_score(d) = Σ_b weight_b / (k_constant + rank_b(d))`
        #
        # @param branches [Hash{Symbol=>Array<Hash>}] each value is a
        #   branch's result rows in descending relevance order (best
        #   first). Keys name the branch (`:lexical`, `:vector`).
        # @param k_constant [Integer] RRF rank constant (> 0).
        # @param weights [Hash{Symbol=>Numeric}, nil] per-branch weight.
        #   Missing branches default to weight 1.0; nil weights the whole
        #   set at 1.0.
        # @return [Array<Hash>] fused rows, descending by `_hybrid_score`,
        #   each carrying `_hybrid_score` and `_hybrid_ranks`. Ties broke
        #   deterministically by objectId (stable for snapshots).
        def rrf(branches, k_constant: DEFAULT_K_CONSTANT, weights: nil)
          unless branches.is_a?(Hash) && !branches.empty?
            raise FusionError, "rrf: branches must be a non-empty Hash of ranked result lists."
          end
          kc = Integer(k_constant)
          raise FusionError, "rrf: k_constant must be a positive integer (got #{kc})." if kc <= 0
          validate_weights!(weights)

          acc = {}
          order = 0
          branches.each do |branch_name, rows|
            weight = weight_for(weights, branch_name)
            next if weight.zero?
            Array(rows).each_with_index do |row, i|
              id = row_id(row)
              next if id.nil?
              rank = i + 1
              entry = (acc[id] ||= { doc: row, score: 0.0, ranks: {}, seq: (order += 1) })
              entry[:doc] = merge_rows(entry[:doc], row)
              entry[:score] += weight.to_f / (kc + rank)
              entry[:ranks][branch_name] = rank
            end
          end

          acc.values
             .sort_by { |e| [-e[:score], row_id(e[:doc]).to_s, e[:seq]] }
             .map do |e|
               row = e[:doc].dup
               row["_hybrid_score"] = e[:score]
               row["_hybrid_ranks"] = e[:ranks]
               row
             end
        end

        # Detect whether the cluster backing `collection` supports the
        # native `$rankFusion` aggregation stage (Atlas 8.0+).
        #
        # Probe-and-cache, NOT version-string parsing: Atlas upgrades
        # cluster versions silently and the exact version where
        # `$rankFusion` reached general availability has moved. We send a
        # zero-cost behavioural probe (`[{$rankFusion: {input: {}}},
        # {$limit: 0}]`) and classify the response: success or any error
        # OTHER than "unknown stage" means supported; an "Unknown
        # aggregation stage" failure means unsupported. The result is
        # cached per collection for {PROBE_CACHE_TTL}.
        #
        # @param collection [String] Parse class / Mongo collection name.
        # @return [Boolean]
        def rank_fusion_supported?(collection)
          key = collection.to_s
          now = monotonic
          cached = probe_cache_get(key, now)
          return cached unless cached.nil?

          supported = run_probe(key)
          probe_cache_put(key, supported, now)
          supported
        end

        # Clear the {.rank_fusion_supported?} probe cache (all
        # collections, or one). Mainly for tests that toggle cluster
        # behaviour between cases.
        #
        # @param collection [String, nil]
        def clear_probe_cache(collection = nil)
          probe_mutex.synchronize do
            if collection
              probe_cache.delete(collection.to_s)
            else
              @probe_cache = {}
            end
          end
        end

        # Run a hybrid search and return the fused raw rows.
        #
        # @param collection_name [String] Parse class / collection.
        # @param lexical [Hash] lexical branch config:
        #   * `:query` [String] (required) the `$search` query text.
        #   * `:index` [String, nil] Atlas Search (lexical) index name.
        #   * `:fields` [Array<String>, String, nil] fields to search;
        #     defaults to a wildcard path.
        #   * `:filter` [Hash, nil] post-`$search` `$match`.
        #   * `:fuzzy` [Hash, nil] forwarded to the text operator.
        # @param vector [Hash] vector branch config:
        #   * `:query_vector` [Array<Float>] (required) the query embedding.
        #   * `:field` [String, Symbol] (required) vector field path.
        #   * `:index` [String, nil] vectorSearch index name.
        #   * `:num_candidates` [Integer, nil] Atlas HNSW search width.
        #   * `:filter` [Hash, nil] post-`$vectorSearch` `$match`.
        #   * `:vector_filter` [Hash, nil] Atlas-native pre-search filter.
        # @param k [Integer] number of fused hits to return (≤ {MAX_K}).
        # @param fusion [Hash, nil] fusion config:
        #   * `:method` [Symbol] `:rrf` (default) and `:rrf_client` both
        #     fuse CLIENT-SIDE (deterministic across Atlas versions).
        #     `:rrf_native` opts into the single-roundtrip server-side
        #     `$rankFusion` stage (Atlas 8.0+ only) and falls back to the
        #     client path when unsupported or on any execution error.
        #   * `:k_constant` [Integer] RRF rank constant.
        #   * `:weights` [Hash] `{ lexical:, vector: }` branch weights.
        # @param scope_opts [Hash] ACL/CLP scope kwargs forwarded to BOTH
        #   branch entry points: `session_token:` / `master:` /
        #   `acl_user:` / `acl_role:`.
        # @return [Array<Hash>] fused rows (see {.rrf}).
        def search(collection_name, lexical:, vector:, k: DEFAULT_K, fusion: nil, **scope_opts)
          require_available!
          fusion = symbolize(fusion || {})
          lex = symbolize(lexical || {})
          vec = symbolize(vector || {})

          k_int = Integer(k)
          raise ArgumentError, "k must be in 1..#{MAX_K} (got #{k_int})." if k_int <= 0 || k_int > MAX_K

          unless lex[:query].is_a?(String) && !lex[:query].strip.empty?
            raise ArgumentError, "hybrid search: lexical[:query] must be a non-empty String."
          end
          if vec[:query_vector].nil? || vec[:field].nil?
            raise ArgumentError, "hybrid search: vector[:query_vector] and vector[:field] are required."
          end

          method = (fusion[:method] || :rrf).to_sym
          unless %i[rrf rrf_client rrf_native].include?(method)
            raise ArgumentError,
                  "hybrid search: fusion[:method] must be :rrf, :rrf_client, or :rrf_native (got #{method.inspect})."
          end
          k_constant = fusion[:k_constant] || DEFAULT_K_CONSTANT
          weights    = fusion[:weights]
          oversample = [k_int * DEFAULT_OVERSAMPLE_MULTIPLIER, k_int].max

          # NOTE (deviation from plan §8.3): the default fuses CLIENT-SIDE.
          # The native single-roundtrip `$rankFusion` path is OPT-IN
          # (`fusion: { method: :rrf_native }`) rather than the default,
          # because its server-side execution (and its ACL `$match`
          # placement) cannot be validated without an Atlas 8.0+ cluster
          # in CI. `rank_fusion_supported?` detection ships and is unit-
          # tested; the native pipeline shape is snapshot-tested; but live
          # results route through the always-correct, fully-enforced
          # two-aggregate client path unless a caller explicitly opts into
          # native AND the cluster supports it. Native still falls back to
          # the client path on any execution error.
          if method == :rrf_native && rank_fusion_supported?(collection_name)
            fused = run_native(collection_name, lex, vec, oversample,
                               k_constant: k_constant, weights: weights, scope_opts: scope_opts)
            return fused.first(k_int) if fused
          end

          lexical_rows = run_lexical(collection_name, lex, oversample, scope_opts)
          vector_rows  = run_vector(collection_name, vec, oversample, scope_opts)
          rrf({ lexical: lexical_rows, vector: vector_rows },
              k_constant: k_constant, weights: weights).first(k_int)
        end

        private

        # -- client-side branch execution --------------------------------

        def run_lexical(collection_name, lex, oversample, scope_opts)
          require_relative "../atlas_search"
          Parse::AtlasSearch.search(
            collection_name, lex[:query],
            index: lex[:index],
            fields: lex[:fields],
            filter: lex[:filter],
            fuzzy: lex[:fuzzy],
            limit: oversample,
            raw: true,
            **scope_opts.dup,
          )
        end

        def run_vector(collection_name, vec, oversample, scope_opts)
          Parse::VectorSearch.search(
            collection_name,
            field: vec[:field],
            query_vector: vec[:query_vector],
            k: oversample,
            num_candidates: vec[:num_candidates],
            filter: vec[:filter],
            vector_filter: vec[:vector_filter],
            index: vec[:index],
            **scope_opts.dup,
          )
        end

        # -- native $rankFusion path -------------------------------------

        # Build the native `$rankFusion` pipeline (without ACL/CLP
        # stages). Public-ish via {.native_pipeline} for snapshot tests;
        # the live path appends ACL enforcement in {#run_native}.
        def build_rank_fusion_stage(lex, vec, oversample, k_constant:, weights:)
          vsel = vector_search_stage(vec, oversample)
          lsel = lexical_search_stage(lex, oversample)
          stage = {
            "input" => {
              "pipelines" => { "vector" => vsel, "lexical" => lsel },
            },
            # `$rankFusion` performs reciprocal-rank fusion implicitly; the
            # only tunable in `combination` is per-input `weights`.
            "scoreDetails" => false,
          }
          if weights
            w = symbolize(weights)
            stage["combination"] = {
              "weights" => { "vector" => weight_for(w, :vector), "lexical" => weight_for(w, :lexical) },
            }
          end
          { "$rankFusion" => stage }
        end

        # Assemble (but do not execute) the full native pipeline,
        # including the ACL `$match` for a non-master resolution. Exposed
        # for snapshot tests so the security-relevant shape is pinned even
        # without an Atlas 8.0 cluster to execute against.
        #
        # @return [Array<Hash>] the aggregation pipeline.
        def native_pipeline(collection_name, lexical:, vector:, k: DEFAULT_K, fusion: nil, **scope_opts)
          fusion = symbolize(fusion || {})
          lex = symbolize(lexical || {})
          vec = symbolize(vector || {})
          oversample = [Integer(k) * DEFAULT_OVERSAMPLE_MULTIPLIER, Integer(k)].max
          resolution = Parse::ACLScope.resolve!(scope_opts.dup, method_name: :"VectorSearch::Hybrid.search")
          native_pipeline_for(lex, vec, oversample, resolution,
                              k_constant: fusion[:k_constant] || DEFAULT_K_CONSTANT,
                              weights: fusion[:weights], limit: Integer(k))
        end

        def native_pipeline_for(lex, vec, oversample, resolution, k_constant:, weights:, limit:)
          pipeline = [build_rank_fusion_stage(lex, vec, oversample, k_constant: k_constant, weights: weights)]
          # The fused RRF score is surfaced via `{ $meta: "score" }`
          # (a numeric), not "scoreDetails" (a breakdown document).
          pipeline << { "$addFields" => { "_hybrid_score" => { "$meta" => "score" } } }
          unless resolution.nil? || resolution.master?
            acl_match = Parse::ACLScope.match_stage_for(resolution)
            pipeline << acl_match if acl_match
          end
          pipeline << { "$sort" => { "_hybrid_score" => -1 } }
          pipeline << { "$limit" => limit }
          pipeline
        end

        def run_native(collection_name, lex, vec, oversample, k_constant:, weights:, scope_opts:)
          resolution = Parse::ACLScope.resolve!(scope_opts.dup, method_name: :"VectorSearch::Hybrid.search")
          assert_clp_find!(collection_name, resolution)
          pointer_fields = resolve_pointer_fields!(collection_name, resolution)
          protected_fields = Parse::CLPScope.protected_fields_for(
            collection_name, resolution.permission_strings,
          )
          Parse::VectorSearch.validate_query_vector!(vec[:query_vector])
          Parse::PipelineSecurity.validate_filter!(vec[:vector_filter]) if vec[:vector_filter]
          Parse::PipelineSecurity.validate_filter!(vec[:filter]) if vec[:filter]
          Parse::PipelineSecurity.validate_filter!(lex[:filter]) if lex[:filter]

          pipeline = native_pipeline_for(lex, vec, oversample, resolution,
                                         k_constant: k_constant, weights: weights, limit: oversample)
          rows = run_pipeline!(collection_name, pipeline)

          unless resolution.master?
            # Defense-in-depth top-level row gate. The in-pipeline ACL
            # `$match` is the primary filter, but it sits AFTER
            # `$rankFusion` and treats a missing `_rperm` as public
            # (`{$exists: false}`). If the fusion stage fails to carry
            # `_rperm` through to its output documents — a behaviour we
            # cannot validate without an Atlas 8.x cluster, and one this
            # method would otherwise silently swallow via the StandardError
            # fallback below — every row would fail OPEN as public. So
            # re-verify each row here and FAIL CLOSED: a non-master row
            # must carry an `_rperm` array that explicitly satisfies the
            # scope. `redact_results!` does NOT cover this case — it skips
            # top-level rows by design (see Parse::ACLScope). The tradeoff
            # is that genuinely ACL-less rows (no `_rperm` at all) are
            # dropped on this opt-in path; public-readable rows store
            # `_rperm: ["*"]` and are kept (non-strict scopes carry `"*"`).
            perms_set = Array(resolution.permission_strings).to_set
            rows.select! { |doc| native_row_visible?(doc, perms_set) }
            Parse::ACLScope.redact_results!(rows, resolution)
            Parse::CLPScope.redact_protected_fields!(rows, protected_fields) if protected_fields.any?
            if pointer_fields
              rows = Parse::CLPScope.filter_by_pointer_fields(rows, pointer_fields, resolution.user_id)
            end
          end
          rows.map! { |doc| Parse::PipelineSecurity.strip_internal_fields(doc) }
          rows
        rescue Parse::CLPScope::Denied
          raise
        rescue StandardError
          # Native execution failed (e.g. a cluster that probed as
          # supported but rejects this exact shape, or a transient error).
          # Fall back to the client-side path rather than failing the
          # whole search — the client path is the always-correct baseline.
          nil
        end

        def vector_search_stage(vec, oversample)
          # Parity with Parse::VectorSearch: Atlas requires
          # `numCandidates >= limit` and caps it at 10_000. The default
          # (`oversample * MULTIPLIER`) can blow past 10_000 for a large
          # `k`, so clamp into `[limit, 10_000]` rather than emit a value
          # Atlas will reject. `oversample` (the per-branch limit) is
          # bounded by `MAX_K * OVERSAMPLE_MULTIPLIER` and stays below the
          # cap, so the clamp range is always valid.
          num_candidates = (vec[:num_candidates] || oversample * Parse::VectorSearch::DEFAULT_NUM_CANDIDATES_MULTIPLIER).to_i
          num_candidates = [[num_candidates, oversample].max, 10_000].min
          stage = {
            "index"         => vec[:index].to_s,
            "path"          => vec[:field].to_s,
            "queryVector"   => vec[:query_vector],
            "numCandidates" => num_candidates,
            "limit"         => oversample,
          }
          stage["filter"] = vec[:vector_filter] if vec[:vector_filter] && !vec[:vector_filter].empty?
          inner = [{ "$vectorSearch" => stage }]
          inner << { "$match" => vec[:filter] } if vec[:filter]
          inner
        end

        def lexical_search_stage(lex, oversample)
          require_relative "../atlas_search" if defined?(Parse::AtlasSearch::SearchBuilder).nil?
          builder = Parse::AtlasSearch::SearchBuilder.new(index_name: lex[:index])
          fields = lex[:fields]
          if fields.nil? || (fields.respond_to?(:empty?) && fields.empty?)
            builder.text(query: lex[:query], path: { "wildcard" => "*" }, fuzzy: lex[:fuzzy])
          else
            Array(fields).each { |f| builder.text(query: lex[:query], path: f.to_s, fuzzy: lex[:fuzzy]) }
          end
          inner = [builder.build, { "$limit" => oversample }]
          inner << { "$match" => lex[:filter] } if lex[:filter]
          inner
        end

        # -- the $rankFusion support probe -------------------------------

        def run_probe(collection_name)
          coll = Parse::MongoDB.collection(collection_name)
          coll.aggregate([{ "$rankFusion" => { "input" => {} } }, { "$limit" => 0 }]).to_a
          true
        rescue StandardError => e
          # "Unknown aggregation stage $rankFusion" (or an unrecognized-
          # operator variant) means the cluster predates native support.
          # Any OTHER failure (a malformed-but-recognized stage, an auth
          # error, etc.) means the stage IS recognized — treat as supported
          # and let the real query surface the real error.
          unsupported_stage_error?(e) ? false : true
        end

        # Message fragments Mongo emits for an UNRECOGNIZED pipeline stage.
        # We only treat the probe failure as "unsupported" when BOTH the
        # stage name AND an unrecognized-stage phrase appear, so a
        # recognized-but-misused `$rankFusion` (or an unrelated auth/parse
        # error) is treated as supported and surfaces its real error on the
        # actual query rather than silently disabling native fusion.
        UNSUPPORTED_STAGE_FRAGMENTS = [
          "unrecognized pipeline stage name",
          "unknown aggregation stage",
          "is not allowed",
        ].freeze
        private_constant :UNSUPPORTED_STAGE_FRAGMENTS

        def unsupported_stage_error?(err)
          msg = err.message.to_s.downcase
          msg.include?("rankfusion") && UNSUPPORTED_STAGE_FRAGMENTS.any? { |f| msg.include?(f) }
        end

        # -- probe cache -------------------------------------------------

        PROBE_MUTEX_INIT = Mutex.new
        private_constant :PROBE_MUTEX_INIT

        def probe_mutex
          @probe_mutex ||= PROBE_MUTEX_INIT.synchronize { @probe_mutex ||= Mutex.new }
        end

        def probe_cache
          @probe_cache ||= {}
        end

        def probe_cache_get(key, now)
          probe_mutex.synchronize do
            entry = probe_cache[key]
            next nil if entry.nil?
            next nil if (now - entry[:at]) >= PROBE_CACHE_TTL
            entry[:supported]
          end
        end

        def probe_cache_put(key, supported, now)
          probe_mutex.synchronize { probe_cache[key] = { supported: supported, at: now } }
        end

        # Monotonic clock so the TTL is immune to wall-clock jumps.
        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        # -- shared helpers ----------------------------------------------

        def require_available!
          Parse::MongoDB.require_gem!
          unless Parse::MongoDB.available?
            raise Parse::VectorSearch::NotAvailable,
                  "Parse::VectorSearch::Hybrid requires Parse::MongoDB.configure(enabled: true)."
          end
        end

        def run_pipeline!(collection_name, pipeline)
          Parse::MongoDB.collection(collection_name).aggregate(pipeline).to_a
        end

        def assert_clp_find!(collection_name, resolution)
          return if resolution.nil? || resolution.master?
          unless Parse::CLPScope.permits?(collection_name, :find, resolution.permission_strings)
            raise Parse::CLPScope::Denied.new(
              collection_name, :find,
              "CLP refuses find on '#{collection_name}' for the current hybrid-search scope.",
            )
          end
        end

        def resolve_pointer_fields!(collection_name, resolution)
          return nil if resolution.nil? || resolution.master?
          pointer_fields = Parse::CLPScope.pointer_fields_for(collection_name, :find)
          return nil if pointer_fields.nil?
          if resolution.user_id.nil?
            raise Parse::CLPScope::Denied.new(
              collection_name, :find,
              "CLP requires user identity (pointerFields=#{pointer_fields.inspect}) " \
              "but the current hybrid-search scope has no user_id.",
            )
          end
          pointer_fields
        end

        def validate_weights!(weights)
          return if weights.nil?
          unless weights.is_a?(Hash)
            raise FusionError, "rrf: weights must be a Hash of branch => weight (got #{weights.class})."
          end
          weights.each_value do |w|
            unless w.is_a?(Numeric) && w >= 0
              raise FusionError, "rrf: weights must be non-negative numbers (got #{w.inspect})."
            end
          end
        end

        def weight_for(weights, branch_name)
          return 1.0 if weights.nil?
          w = weights[branch_name] || weights[branch_name.to_s] || weights[branch_name.to_sym]
          w.nil? ? 1.0 : w.to_f
        end

        def row_id(row)
          id = row["_id"] || row[:_id] || row["objectId"] || row[:objectId]
          id.nil? ? nil : id.to_s
        end

        # Fail-closed top-level row gate for the native fusion path.
        # Unlike {Parse::ACLScope}'s subdoc matcher (which treats a
        # missing `_rperm` as public), this REQUIRES an explicit,
        # satisfied `_rperm` array: a row with no, empty, or non-Array
        # `_rperm` is dropped, because on the native path a missing
        # `_rperm` may mean `$rankFusion` stripped it rather than the row
        # being genuinely public.
        def native_row_visible?(doc, perms_set)
          rperm = doc["_rperm"] || doc[:_rperm]
          rperm.is_a?(Array) && rperm.any? { |entry| perms_set.include?(entry) }
        end

        # Merge two rows for the same objectId across branches: keep all
        # fields, preferring non-nil values, so the fused row carries both
        # branch scores (`_score` and `_vscore`).
        def merge_rows(a, b)
          return b if a.nil?
          return a if b.nil?
          a.merge(b) { |_k, va, vb| vb.nil? ? va : vb }
        end

        def symbolize(hash)
          return {} if hash.nil?
          hash.each_with_object({}) { |(k, v), out| out[k.to_sym] = v }
        end
      end
    end
  end
end
