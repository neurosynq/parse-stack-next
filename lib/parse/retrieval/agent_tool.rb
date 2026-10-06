# encoding: UTF-8
# frozen_string_literal: true

require_relative "../retrieval"

module Parse
  module Retrieval
    # The `semantic_search` agent tool: the agent-aware wrapper around
    # {Parse::Retrieval.retrieve}. It applies the agent security
    # envelope that {Parse::Retrieval.retrieve} (a model-layer method) is
    # deliberately kept free of:
    #
    # * Class allowlist via {Parse::Agent::MetadataRegistry.resolve_searchable!}
    #   (`agent_searchable` opt-in, hidden-class refusal, tenant-scope gate).
    # * Recursive underscore-key refusal + filter-field allowlist on
    #   caller-supplied `filter:` / `vector_filter:`.
    # * Tenant scope merged into the Atlas pre-filter AND re-asserted on
    #   every returned source record (NEW-TOOLS-3 guard).
    # * `field_allowlist` projection of each source record on the way out.
    # * Score quantization in non-admin contexts.
    #
    # ACL is enforced mongo-direct inside `find_similar` via the agent's
    # `acl_scope_kwargs` (`session_token:` / `acl_user:` / `acl_role:` /
    # `master:`), which is why the tool is `client_safe: true`: a
    # session-token client routes through the one path with first-class
    # SDK-side `_rperm` enforcement.
    module AgentTool
      module_function

      # The agent's auth kwargs for the direct path, including its client
      # when the agent can supply one.
      #
      # Agents are duck-typed at this boundary, so an agent-shaped object
      # that predates `direct_auth_kwargs` still works and simply resolves as
      # an unidentified caller, which Parse::MongoDB's binding guard already
      # models. Requiring the new method of every stand-in would break each
      # one that has not been updated, to gain a field that is optional by
      # construction.
      def retrieval_auth_kwargs(agent)
        return agent.direct_auth_kwargs if agent.respond_to?(:direct_auth_kwargs)
        agent.acl_scope_kwargs
      end

      # Upper bound on `k` (mirrors the registered parameter schema).
      MAX_K = 20
      # Default neighbour count for the agent tool. Intentionally lower than
      # Parse::Retrieval.retrieve's library default of 10: an LLM tool result
      # is paid for in context tokens, so the agent surface defaults
      # conservatively. Callers/LLMs can raise it up to MAX_K per call.
      DEFAULT_K = 5

      # Default ceiling on total returned chunk-content tokens (estimated as
      # chars/4). The retrieve count caps (k * max_chunks_per_document) bound
      # the NUMBER of chunks but not their total size, so a few long documents
      # could silently blow the context window. This budget trims the
      # (score-ordered) chunk list and reports `budget_truncated` so the
      # truncation is never silent. Pass `max_total_tokens: 0` to disable.
      DEFAULT_MAX_TOTAL_TOKENS = 20_000

      # Longest `query` accepted. A search query is a short natural-language
      # request; the bound keeps one call from sending a body-sized string to
      # the embedding provider and, under a reranking profile, pairing it
      # with every candidate document.
      MAX_QUERY_CHARS = 4_000

      # @param agent [Parse::Agent]
      # @param text_field [String, Symbol, nil] which embedded text source to
      #   chunk and return as `content`. Must name one of the class's declared
      #   embed sources that is also inside its `agent_fields` allowlist: an
      #   arbitrary field is refused so chunk `content` can't disclose a
      #   non-embedded field, and an embedded-but-hidden field is refused with
      #   `:field_denied` so it can't disclose a field the agent may not read.
      #   When omitted, it is inferred from the readable embed sources.
      # @param max_chunks_per_document [Integer, nil] cap on chunks emitted per
      #   matched document (forwarded to the chunker).
      # @param max_total_tokens [Integer, nil] ceiling on total returned
      #   chunk-content tokens (estimated chars/4). nil uses
      #   {DEFAULT_MAX_TOTAL_TOKENS}; 0 disables the budget.
      # @return [Hash] `{ chunks: Array<Hash>, documents: Hash, count: Integer }`
      #   — each chunk's parent record is hoisted once into `documents` (keyed
      #   by objectId) instead of being duplicated on every chunk. When the
      #   token budget trims the result, `budget_truncated: true` and
      #   `budget_dropped: <n>` are added.
      def semantic_search(agent, **args)
        started = monotonic_now
        semantic_search_unobserved(agent, **args)
      rescue StandardError => e
        # Failures are observable too: one sanitized event naming the error
        # class (never its message, which can echo input).
        emit_failure_event(args, e, started)
        raise
      end

      # @!visibility private
      def emit_failure_event(args, error, started)
        return unless defined?(ActiveSupport::Notifications)
        payload = {
          class_name: (args[:class_name] || args[:klass]).to_s,
          profile: args[:profile]&.to_s,
          error: error.class.name,
          duration_ms: ((monotonic_now - started) * 1000).round(1),
        }
        ActiveSupport::Notifications.instrument("parse.retrieval.search", payload)
      rescue StandardError
        nil
      end

      # @!visibility private
      def semantic_search_unobserved(agent, class_name: nil, query: nil, k: nil,
                                 filter: nil, vector_filter: nil, text_field: nil,
                                 chunk_size: nil, chunk_overlap: nil, chunk_by: nil,
                                 max_chunks_per_document: nil, max_total_tokens: nil,
                                 profile: nil,
                                 # Back-compat / ergonomic aliases for direct callers:
                                 # `klass:`/`class:` for class_name, and the chunker's
                                 # own `size:`/`overlap:`/`by:` names.
                                 klass: nil, size: nil, overlap: nil, by: nil,
                          **rest)
        class_name ||= klass || rest.delete(:class)
        chunk_size ||= size
        chunk_overlap ||= overlap
        chunk_by ||= by

        klass = Parse::Agent::MetadataRegistry.resolve_searchable!(class_name)
        cname = klass.parse_class

        unless query.is_a?(String) && !query.strip.empty?
          raise Parse::Agent::ValidationError, "semantic_search: `query` must be a non-empty String."
        end
        if query.length > MAX_QUERY_CHARS
          raise Parse::Agent::ValidationError,
                "semantic_search: `query` is #{query.length} characters; the limit is #{MAX_QUERY_CHARS}."
        end

        resolved_text_field = normalize_text_field!(text_field, klass)
        # A named, server-configured retrieval profile (Parse::Retrieval::Profiles).
        # Unknown names fail here, before any provider call.
        prof = profile.nil? || profile.to_s.strip.empty? ? nil : Parse::Retrieval::Profiles.fetch!(profile)

        # Reject reserved underscore keys at any depth, then enforce the
        # per-class filter-field allowlist on top-level keys.
        Parse::Retrieval.assert_no_underscore_keys!(filter) unless filter.nil?
        Parse::Retrieval.assert_no_underscore_keys!(vector_filter) unless vector_filter.nil?
        allowed = Parse::Agent::MetadataRegistry.searchable_filter_fields(cname).map(&:to_s)
        # A per-agent `fields:` narrowing also narrows the filterable fields:
        # filtering on a field the agent cannot read would reveal its value
        # through which rows match.
        if Parse::Agent::FieldPolicy.narrowing_for(cname)
          readable = Parse::Agent::MetadataRegistry.field_allowlist(cname).map(&:to_s)
          allowed = allowed.select do |f|
            readable.include?(Parse::Agent::MetadataRegistry.wire_field_names(cname, [f]).first)
          end
        end
        assert_filter_fields_allowed!(filter, allowed)
        assert_filter_fields_allowed!(vector_filter, allowed)

        # Tenant scope (nil for unscoped classes / bypassed admins; raises
        # AccessDenied for an un-bound agent on a scoped class).
        scope = Parse::Agent::Tools.resolve_tenant_scope!(agent, cname)

        # Per-tenant embedding spend cap (§16.10 — agent-tool exposure
        # mitigation). semantic_search embeds attacker-controlled query
        # text on every call; charge the estimated query tokens against
        # the tenant's budget BEFORE embedding. HARD-REFUSES once the
        # tenant is over cap. No-op when no limit is configured or for
        # trusted admin agents.
        charge_spend_cap!(agent, scope, query)

        # Non-admin agents get quantized scores (membership-inference
        # defense); admin agents get full precision. Keyed on the
        # permission tier, not master-key posture.
        score_quantize = (agent.permissions != :admin)
        vector_field = Parse::Agent::MetadataRegistry.searchable_field(cname)

        # Profile resolution: k is bounded by the profile's max_k; a reranking
        # profile retrieves `rerank_candidates` and keeps `rerank_top_n` (or
        # the effective k); hybrid settings come only from the profile.
        effective_k = if prof
            requested = k.to_i.positive? ? k.to_i : prof.k
            clamp_k([requested, prof.max_k].min)
          else
            clamp_k(k)
          end
        reranker = nil
        retrieve_k = effective_k
        rerank_top_n = nil
        if prof&.rerank?
          reranker = Parse::Retrieval::BudgetedReranker.new(
            Parse::Retrieval.reranker(prof.reranker), prof,
            charge: ->(tokens) { charge_rerank_tokens!(agent, scope, tokens) },
          )
          # rerank_candidates is a hard budget: the caller's k can never
          # raise how many documents are retrieved and sent to the
          # reranker, so k is capped at it.
          retrieve_k = prof.rerank_candidates
          effective_k = [effective_k, retrieve_k].min
          rerank_top_n = [prof.rerank_top_n || effective_k, effective_k].min
        end
        if prof
          # Under a profile the response budget is mandatory: the caller can
          # lower it but never raise or disable it (0 does not switch it off).
          ceiling = prof.max_total_tokens || DEFAULT_MAX_TOTAL_TOKENS
          requested = max_total_tokens.to_i
          max_total_tokens = requested.positive? ? [requested, ceiling].min : ceiling
        end
        started = monotonic_now

        # with_precharged: the cap was charged above with per-tenant
        # identity (or deliberately skipped for trusted admin agents) —
        # suppress the generic query-embed charge inside
        # find_similar/embed_query_text! so the query isn't double-billed
        # (or admin queries billed to the shared default bucket).
        chunks = Parse::Embeddings::SpendCap.with_precharged do
          Parse::Retrieval.retrieve(
            query: query,
            klass: klass,
            field: vector_field,
            text_field: resolved_text_field,
            k: retrieve_k,
            hybrid: prof&.hybrid ? hybrid_config_for(prof, klass) : nil,
            rerank: reranker,
            rerank_top_n: rerank_top_n,
            filter: filter,
            vector_filter: vector_filter,
            chunker: build_chunker(chunk_size, chunk_overlap, chunk_by, max_chunks_per_document),
            tenant_scope: scope,
            score_quantize: score_quantize,
            source_transform: source_projector(agent, cname, scope),
            **retrieval_auth_kwargs(agent),
          )
        end

        # Token budget (B4): trim the score-ordered chunk list before
        # building the envelope so `documents` only carries parents whose
        # chunks survived.
        kept, dropped = apply_token_budget(chunks, resolve_token_budget(max_total_tokens), strict: !prof.nil?)

        # Source dedup (A3): a document's (projected) source record is
        # identical across all its chunks. Hoist it into a `documents` map
        # keyed by objectId and drop the inline `source` from each chunk —
        # ~46 tok/chunk saved for every chunk past the first of a document.
        documents = {}
        chunk_hashes = kept.map do |chunk|
          h = chunk.to_h
          oid = h.dig(:metadata, :object_id)
          if oid && !oid.to_s.empty?
            documents[oid] ||= h[:source]
            h = h.reject { |key, _| key == :source }
          end
          h
        end
        stamp_chunk_provenance!(chunk_hashes, cname) if Parse::Agent.include_source_provenance?

        envelope = { chunks: chunk_hashes, documents: documents, count: chunk_hashes.length }
        if dropped > 0
          envelope[:budget_truncated] = true
          envelope[:budget_dropped] = dropped
        end
        if prof
          envelope[:profile] = prof.name
          if reranker&.stats&.dig(:fallback)
            # Observable fallback: the result is in retrieval order, not
            # reranked, and the caller is told why.
            envelope[:rerank_fallback] = true
            envelope[:rerank_fallback_reason] = reranker.stats[:fallback_reason]
          end
        end
        emit_search_event(cname, prof, effective_k, retrieve_k, reranker, envelope, dropped, started)
        envelope
      end

      # @!visibility private
      # A profile's hybrid settings with the lexical branch restricted to the
      # text sources the agent may read. Without this the lexical search runs
      # over every field (`wildcard: "*"`), so which documents match, and
      # their rank, could depend on a hidden field. Refused when the class
      # has an allowlist and no readable text source.
      def hybrid_config_for(prof, klass)
        cfg = Marshal.load(Marshal.dump(prof.hybrid.to_h))
        allowlist = Parse::Agent::MetadataRegistry.field_allowlist(klass.parse_class)
        if allowlist.nil? || allowlist.empty?
          # No allowlist: never fall back to `wildcard: "*"`, which would
          # let every column (including CLP protectedFields) decide matches.
          # Search the embedded text sources unless the profile names fields;
          # Atlas search then refuses any named field protected for the caller.
          lexical = (cfg[:lexical] || {}).dup
          if Array(lexical[:fields]).empty?
            lexical[:fields] = searchable_text_fields(klass).map { |f| Parse::Retrieval.send(:wire_name, klass, f) }
            cfg[:lexical] = lexical
          end
          return cfg
        end
        lexical = (cfg[:lexical] || {}).dup
        if lexical[:fields]
          # Server-configured lexical fields are kept when the agent may read
          # them (any readable field, not only embedding sources), and
          # translated to their stored names.
          readable_wire = allowlist.map(&:to_s) - Parse::Agent::MetadataRegistry::ALWAYS_KEEP_FIELDS
          configured = Array(lexical[:fields]).map { |f| Parse::Retrieval.send(:wire_name, klass, f) }
          lexical[:fields] = configured & readable_wire
        else
          # Unconfigured: search the readable embedded text sources.
          readable = readable_text_fields(klass) || []
          lexical[:fields] = readable.map { |f| Parse::Retrieval.send(:wire_name, klass, f) }
        end
        if lexical[:fields].empty?
          # An empty list would mean `wildcard: "*"`, letting hidden fields
          # decide matches; refuse instead.
          raise text_field_denied(klass, Array(cfg.dig(:lexical, :fields)).first || searchable_text_fields(klass).first)
        end
        cfg[:lexical] = lexical
        cfg
      end

      # @!visibility private
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # @!visibility private
      # One sanitized `parse.retrieval.search` event per semantic_search
      # call: profile, budgets, stage counts and timings, and estimated
      # rerank usage. Never document text, field values, URLs, or
      # credentials. Rerank tokens are the SDK's estimate
      # (`tokens_estimated`), not provider-reported usage.
      def emit_search_event(cname, prof, k, retrieve_k, reranker, envelope, dropped, started)
        return unless defined?(ActiveSupport::Notifications)
        total_ms = ((monotonic_now - started) * 1000).round(1)
        rerank = reranker ? reranker.stats.dup : { used: false }
        payload = {
          class_name: cname,
          profile: prof&.name,
          hybrid: !prof&.hybrid.nil?,
          k: k,
          candidates: retrieve_k,
          rerank: rerank,
          chunks_returned: envelope[:count],
          documents_returned: envelope[:documents].size,
          budget_dropped: dropped,
          duration_ms: total_ms,
          retrieve_ms: (total_ms - (rerank[:duration_ms] || 0)).round(1),
        }
        ActiveSupport::Notifications.instrument("parse.retrieval.search", payload)
      rescue StandardError
        nil
      end

      # @!visibility private
      # Charge estimated reranker tokens to the same per-tenant spend cap
      # the query embedding uses (admin agents are exempt, as there). A
      # transient cap hit surfaces as RateLimitExceeded; an impossible one
      # as ValidationError, mirroring {#charge_spend_cap!}.
      def charge_rerank_tokens!(agent, scope, tokens)
        return if agent.permissions == :admin
        tenant_id = scope && (scope[:value] || scope["value"])
        Parse::Embeddings::SpendCap.charge!(tenant_id: tenant_id, tokens: tokens)
      rescue Parse::Embeddings::SpendCap::Exceeded => e
        if e.retry_after.nil?
          raise Parse::Agent::ValidationError,
                "semantic_search: reranking exceeds the spend cap " \
                "(#{e.requested} tokens requested, limit #{e.limit}/#{e.window}s)."
        end
        raise Parse::Agent::RateLimitExceeded.new(retry_after: e.retry_after, limit: e.limit, window: e.window)
      end

      # @!visibility private
      # Charge the estimated query-embedding token cost against the
      # tenant's spend cap. The tenant key is the resolved tenant-scope
      # value (so each tenant has its own budget); unscoped non-admin
      # calls charge the shared default bucket. Admin agents are trusted
      # and skip the cap entirely (mirrors the score-quantize tier check).
      #
      # A cap hit is surfaced as a structured error rather than the raw
      # {Parse::Embeddings::SpendCap::Exceeded} — otherwise the agent's
      # generic-error rescue would collapse it to an opaque "internal
      # error" and the model couldn't self-correct. Two distinct cases:
      #
      # * Transient (`retry_after` non-nil): the window will roll off
      #   enough tokens to admit this charge. Surface as
      #   {Parse::Agent::RateLimitExceeded} (wire `error_code:
      #   :rate_limited`) carrying the real backoff hint so the model
      #   waits and retries.
      # * Permanent (`retry_after` nil): the request alone exceeds the cap
      #   (`requested > limit`) and can NEVER fit, no matter how long the
      #   caller waits. Mapping that to a RateLimitExceeded would tell the
      #   model to back off and retry an unsatisfiable request — and it
      #   would also crash, since RateLimitExceeded#initialize calls
      #   `retry_after.round`. Surface as {Parse::Agent::ValidationError}
      #   so the model shrinks the query (or the operator raises the cap).
      def charge_spend_cap!(agent, scope, query)
        return if agent.permissions == :admin
        tenant_id = scope && (scope[:value] || scope["value"])
        tokens = Parse::Embeddings::SpendCap.estimate_tokens(query)
        Parse::Embeddings::SpendCap.charge!(tenant_id: tenant_id, tokens: tokens)
      rescue Parse::Embeddings::SpendCap::Exceeded => e
        if e.retry_after.nil?
          raise Parse::Agent::ValidationError,
                "semantic_search: query too large for the embedding spend cap " \
                "(#{e.requested} tokens requested, limit #{e.limit}/#{e.window}s). " \
                "Shorten the query or raise the cap."
        end
        raise Parse::Agent::RateLimitExceeded.new(
          retry_after: e.retry_after, limit: e.limit, window: e.window,
        )
      end

      # @!visibility private
      # nil -> DEFAULT_MAX_TOTAL_TOKENS; <=0 -> nil (unlimited); else the int.
      def resolve_token_budget(max_total_tokens)
        return DEFAULT_MAX_TOTAL_TOKENS if max_total_tokens.nil?
        n = max_total_tokens.to_i
        n <= 0 ? nil : n
      end

      # @!visibility private
      # Greedily keep score-ordered chunks until the cumulative content
      # token estimate (chars/4) would exceed `budget`. Always keeps at
      # least the first chunk so a single oversize chunk still returns
      # something (flagged truncated).
      # @return [Array(Array<Chunk>, Integer)] [kept, dropped_count]
      #
      # The estimate covers the whole response, not only chunk text: each
      # chunk's content plus, the first time a parent document appears, that
      # document's serialized source record (it is hoisted into `documents`).
      #
      # `strict:` (a profile's mandatory budget) drops even the first chunk
      # when it alone exceeds the budget; otherwise the first chunk is always
      # kept so an oversized single result still returns something.
      def apply_token_budget(chunks, budget, strict: false)
        return [chunks, 0] if budget.nil? || chunks.empty?
        total = 0
        kept = []
        seen_docs = {}
        chunks.each do |chunk|
          est = (chunk.content.to_s.length / 4.0).ceil
          oid = chunk.respond_to?(:metadata) && chunk.metadata.is_a?(Hash) ? chunk.metadata[:object_id] : nil
          if oid && !seen_docs.key?(oid) && chunk.respond_to?(:source) && chunk.source
            doc_est = (JSON.generate(chunk.source).length / 4.0).ceil rescue 0
            est += doc_est
          end
          break unless (kept.empty? && !strict) || total + est <= budget
          kept << chunk
          seen_docs[oid] = true if oid
          total += est
        end
        [kept, chunks.length - kept.length]
      end

      # @!visibility private
      # Per-chunk `_source` provenance. The chunk already carries a
      # `source` key (the projected parent record), so provenance uses the
      # distinct `_source` key. object_id comes from the chunk metadata
      # (or the projected source record).
      def stamp_chunk_provenance!(chunk_hashes, cname)
        chunk_hashes.each do |c|
          next unless c.is_a?(Hash)
          next if c.key?(:_source)
          oid = c.dig(:metadata, :object_id)
          oid ||= (c[:source]["objectId"] || c[:source][:objectId]) if c[:source].is_a?(Hash)
          c[:_source] = { "class" => cname.to_s, "tool" => "semantic_search", "object_id" => oid }
        end
      end

      # @!visibility private
      # Build the per-record OUTPUT transform: convert the raw storage-
      # form Mongo hit to Parse/wire form, re-assert tenant scope (raises
      # AccessDenied — fail closed for the whole call), redact hidden
      # nested classes, then project through `field_allowlist`.
      def source_projector(agent, cname, scope)
        lambda do |raw_doc|
          converted = convert_to_parse_form(raw_doc, cname)
          Parse::Agent::Tools.assert_record_in_tenant_scope!(converted, scope, cname) if scope
          projected = Parse::Agent::Tools.project_object_to_allowlist(cname, converted)
          redacted = Parse::Agent::Tools.redact_hidden_classes!(projected, agent: agent)
          # Normalize to the same LLM-friendly, ACL-stripped form the other
          # read tools emit so the `documents` map is consistent (and ACL-
          # free) even for a searchable class with no agent_fields allowlist,
          # where project_object_to_allowlist is a pass-through.
          Parse::Agent::ResultFormatter.simplify_object(redacted)
        end
      end

      # @!visibility private
      def convert_to_parse_form(raw_doc, cname)
        Parse::MongoDB.convert_documents_to_parse([raw_doc], cname).first || raw_doc
      rescue StandardError
        # Conversion failed for this hit. Do NOT surface the raw storage-form
        # Mongo document: it carries internal metadata (_acl, _rperm/_wperm,
        # storage-form _p_* pointers, _id, _created_at/_updated_at) that the
        # success path strips. For a searchable class with NO agent_fields
        # allowlist, project_object_to_allowlist downstream is a pass-through, so
        # this fallback is the only thing standing between those keys and the
        # LLM. Drop every storage-internal (underscore-prefixed) key. NOTE:
        # reusing Parse::PipelineSecurity.strip_internal_fields is NOT enough —
        # its denylist EXCLUDES _acl, which is exactly the field that discloses
        # other principals' object ids and roles. The chunk's object_id is read
        # from the raw doc before this transform runs, so dropping _id is
        # harmless.
        raw_doc.is_a?(Hash) ? raw_doc.reject { |k, _| k.to_s.start_with?("_") } : {}
      end

      # @!visibility private
      def clamp_k(k)
        n = k.to_i
        n = DEFAULT_K if n <= 0
        [n, MAX_K].min
      end

      # @!visibility private
      def build_chunker(size, overlap, by, max_chunks_per_document = nil)
        return nil if size.nil? && overlap.nil? && by.nil? && max_chunks_per_document.nil?
        opts = {
          size: (size || 800).to_i,
          overlap: (overlap || 100).to_i,
          by: (by || :chars).to_sym,
        }
        # Only override the chunker's own default (200) when the caller asked,
        # so an unset cap keeps the library default rather than forcing it here.
        opts[:max_chunks_per_document] = max_chunks_per_document.to_i unless max_chunks_per_document.nil?
        Parse::Retrieval::Chunker::FixedSizeOverlap.new(**opts)
      rescue ArgumentError => e
        raise Parse::Agent::ValidationError, "semantic_search: invalid chunker options — #{e.message}"
      end

      # @!visibility private
      # The class's declared embed TEXT sources — the only fields an agent may
      # name as `text_field:`. Chunk `content` is the text_field's value, so
      # restricting it to embedded sources stops the tool from surfacing a
      # field the model never opted into embedding.
      def searchable_text_fields(klass)
        return [] unless klass.respond_to?(:embed_directives)
        klass.embed_directives.values
             .reject { |d| d.respond_to?(:image?) && d.image? }
             .flat_map(&:sources).map(&:to_s).uniq
      end

      # @!visibility private
      # The embed text sources the agent may also READ: those whose wire
      # column is inside the class's `agent_fields` allowlist. Chunk
      # `content` (and any reranker input) is built from the chosen source's
      # raw value BEFORE the per-record projection strips disallowed fields,
      # so the source itself must be readable. With no allowlist every
      # source is readable, as before.
      #
      # @return [Array<String>, nil] readable sources, or nil when the class
      #   declares no `agent_fields` allowlist.
      def readable_text_fields(klass)
        allowlist = Parse::Agent::MetadataRegistry.field_allowlist(klass.parse_class)
        return nil if allowlist.nil? || allowlist.empty?
        permitted = allowlist.map(&:to_s)
        searchable_text_fields(klass).select do |source|
          permitted.include?(Parse::Retrieval.send(:wire_name, klass, source))
        end
      end

      # @!visibility private
      # Validate a caller-supplied text_field against the embedded-source
      # list and the `agent_fields` allowlist, or infer one.
      #
      # * Explicit field that is not an embed source: ValidationError.
      # * Explicit embed source outside `agent_fields`: AccessDenied
      #   (`:field_denied`), raised before any search runs.
      # * Omitted, class has no `agent_fields`: nil, so retrieve infers as
      #   before (single source) or raises AmbiguousTextField (several).
      # * Omitted, class has `agent_fields`: the sole readable source; a
      #   `:field_denied` refusal when none is readable; a ValidationError
      #   asking for `text_field` when several are.
      def normalize_text_field!(text_field, klass)
        readable = readable_text_fields(klass)

        if text_field.nil? || text_field.to_s.strip.empty?
          return nil if readable.nil?
          return readable.first.to_sym if readable.length == 1
          if readable.empty?
            raise text_field_denied(klass, searchable_text_fields(klass).first)
          end
          raise Parse::Agent::ValidationError,
                "semantic_search: this class embeds several readable text sources; pass " \
                "text_field (allowed: #{readable.inspect})."
        end

        allowed = searchable_text_fields(klass)
        unless allowed.include?(text_field.to_s)
          raise Parse::Agent::ValidationError,
                "semantic_search: text_field #{text_field.to_s.inspect} is not an embedded " \
                "text source for this class (allowed: #{(readable || allowed).inspect})."
        end
        if readable && !readable.include?(text_field.to_s)
          raise text_field_denied(klass, text_field.to_s)
        end
        text_field.to_sym
      end

      # @!visibility private
      def text_field_denied(klass, source)
        allowlist = Parse::Agent::MetadataRegistry.field_allowlist(klass.parse_class)
        Parse::Agent::AccessDenied.new(
          klass.parse_class,
          "semantic_search: text source #{source.to_s.inspect} is outside the agent_fields " \
          "allowlist for class '#{klass.parse_class}', so it cannot be returned as chunk content.",
          kind: :field_denied,
          denied_field: source.to_s,
          allowed_fields: allowlist&.map(&:to_s),
        )
      end

      # @!visibility private
      # Refuse any top-level filter key not in the class's declared
      # `filter_fields` allowlist (compound operators included — the
      # allowlist is the complete set of keys the agent may use).
      def assert_filter_fields_allowed!(filter, allowed)
        return if filter.nil? || (filter.respond_to?(:empty?) && filter.empty?)
        unless filter.is_a?(Hash)
          raise Parse::Agent::ValidationError, "semantic_search: filter must be an object."
        end
        offending = filter.keys.map(&:to_s).reject { |key| allowed.include?(key) }
        unless offending.empty?
          raise Parse::Agent::ValidationError,
                "semantic_search: filter field(s) #{offending.inspect} are not in the " \
                "agent_searchable filter_fields allowlist (#{allowed.inspect})."
        end
      end

      # JSON Schema for the registered tool's parameters.
      PARAMETERS = {
        "type" => "object",
        "properties" => {
          "class_name" => { "type" => "string", "description" => "Parse class name (must be agent_searchable)." },
          "query" => { "type" => "string", "description" => "Natural-language query.", "maxLength" => MAX_QUERY_CHARS },
          "k" => { "type" => "integer", "default" => DEFAULT_K, "minimum" => 1, "maximum" => MAX_K },
          "filter" => { "type" => "object", "description" => "Post-search field filter (allowlisted fields only)." },
          "vector_filter" => { "type" => "object", "description" => "Atlas pre-search filter (allowlisted fields only)." },
          "text_field" => { "type" => "string", "description" => "Which embedded text source to chunk and return as content. Required only when the class embeds more than one text field; must name one of those sources." },
          "profile" => { "type" => "string", "description" => "Optional server-configured retrieval profile name (for example fast, balanced, precise). Profiles set result counts, hybrid search, and reranking; omit for the default search. An unknown name is refused with the list of available profiles." },
          "chunk_size" => { "type" => "integer", "description" => "Override chunk window size." },
          "chunk_overlap" => { "type" => "integer", "description" => "Override chunk overlap." },
          "chunk_by" => { "type" => "string", "enum" => %w[chars tokens], "description" => "Chunk unit." },
          "max_chunks_per_document" => { "type" => "integer", "minimum" => 1, "description" => "Cap on chunks emitted per matched document." },
          "max_total_tokens" => { "type" => "integer", "minimum" => 0, "description" => "Ceiling on total returned chunk-content tokens (approx chars/4). Trims lowest-ranked chunks first and sets budget_truncated. 0 disables." },
        },
        "required" => %w[class_name query],
      }.freeze

      # MCP outputSchema → mirrored as structuredContent on results.
      # The parent record of each chunk is hoisted into `documents` (keyed
      # by objectId) rather than duplicated inline on every chunk; map a
      # chunk to its source via `metadata.object_id`.
      OUTPUT_SCHEMA = {
        "type" => "object",
        "properties" => {
          "chunks" => {
            "type" => "array",
            "items" => {
              "type" => "object",
              "properties" => {
                "id" => { "type" => "string" },
                "score" => { "type" => %w[number null] },
                "content" => { "type" => "string" },
                "metadata" => { "type" => "object" },
              },
            },
          },
          "documents" => {
            "type" => "object",
            "description" => "objectId => projected source record (sent once per matched document).",
          },
          "count" => { "type" => "integer" },
          "budget_truncated" => { "type" => "boolean", "description" => "Present when the token budget dropped lowest-ranked chunks." },
          "budget_dropped" => { "type" => "integer", "description" => "Number of chunks dropped by the token budget." },
        },
      }.freeze

      # Register the tool. Idempotent-ish: re-requiring is a no-op because
      # require caches; an explicit re-register after reset_registry! is
      # supported via {.register!}.
      def register!
        Parse::Agent::Tools.register(
          name: :semantic_search,
          description: "Find documents semantically similar to a natural-language query and " \
                       "return scored text chunks. Use when keyword matching is unlikely to " \
                       "work or the question needs synthesizing across documents. The target " \
                       "class must be declared `agent_searchable`.",
          parameters: PARAMETERS,
          permission: :readonly,
          timeout: 30,
          output_schema: OUTPUT_SCHEMA,
          client_safe: true,
          handler: ->(agent, **args) { Parse::Retrieval::AgentTool.semantic_search(agent, **args) },
        )
      end
    end
  end
end

# Register at load. Requires Parse::Agent::Tools (TOOL_DEFINITIONS for the
# collision check), Parse::Retrieval (loaded with the model layer), and
# Parse::Object + MetadataDSL — all present by the time agent.rb requires
# this file at its tail.
Parse::Retrieval::AgentTool.register!
