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

      # @param agent [Parse::Agent]
      # @param text_field [String, Symbol, nil] which embedded text source to
      #   chunk and return as `content`. Required only for models with more
      #   than one `embed` text source (otherwise inferred). Must name one of
      #   the class's declared embed sources — an arbitrary field is refused so
      #   the chunk `content` can't disclose a non-embedded field.
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
      def semantic_search(agent, class_name: nil, query: nil, k: DEFAULT_K,
                          filter: nil, vector_filter: nil, text_field: nil,
                          chunk_size: nil, chunk_overlap: nil, chunk_by: nil,
                          max_chunks_per_document: nil, max_total_tokens: nil,
                          # Back-compat / ergonomic aliases for direct callers:
                          # `klass:`/`class:` for class_name, and the chunker's
                          # own `size:`/`overlap:`/`by:` names.
                          klass: nil, size: nil, overlap: nil, by: nil,
                          **rest)
        class_name    ||= klass || rest.delete(:class)
        chunk_size    ||= size
        chunk_overlap ||= overlap
        chunk_by      ||= by

        klass = Parse::Agent::MetadataRegistry.resolve_searchable!(class_name)
        cname = klass.parse_class

        unless query.is_a?(String) && !query.strip.empty?
          raise Parse::Agent::ValidationError, "semantic_search: `query` must be a non-empty String."
        end

        resolved_text_field = normalize_text_field!(text_field, klass)

        # Reject reserved underscore keys at any depth, then enforce the
        # per-class filter-field allowlist on top-level keys.
        Parse::Retrieval.assert_no_underscore_keys!(filter) unless filter.nil?
        Parse::Retrieval.assert_no_underscore_keys!(vector_filter) unless vector_filter.nil?
        allowed = Parse::Agent::MetadataRegistry.searchable_filter_fields(cname).map(&:to_s)
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

        chunks = Parse::Retrieval.retrieve(
          query: query,
          klass: klass,
          field: vector_field,
          text_field: resolved_text_field,
          k: clamp_k(k),
          filter: filter,
          vector_filter: vector_filter,
          chunker: build_chunker(chunk_size, chunk_overlap, chunk_by, max_chunks_per_document),
          tenant_scope: scope,
          score_quantize: score_quantize,
          source_transform: source_projector(agent, cname, scope),
          **agent.acl_scope_kwargs,
        )

        # Token budget (B4): trim the score-ordered chunk list before
        # building the envelope so `documents` only carries parents whose
        # chunks survived.
        kept, dropped = apply_token_budget(chunks, resolve_token_budget(max_total_tokens))

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
        envelope
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
      def apply_token_budget(chunks, budget)
        return [chunks, 0] if budget.nil? || chunks.empty?
        total = 0
        kept = []
        chunks.each do |chunk|
          est = (chunk.content.to_s.length / 4.0).ceil
          break unless kept.empty? || total + est <= budget
          kept << chunk
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
      # Validate a caller-supplied text_field against the embedded-source
      # allowlist. nil/blank → nil (retrieve infers; works for single-source
      # models, raises AmbiguousTextField for multi-source so the agent knows
      # to pass one).
      def normalize_text_field!(text_field, klass)
        return nil if text_field.nil? || text_field.to_s.strip.empty?
        allowed = searchable_text_fields(klass)
        unless allowed.include?(text_field.to_s)
          raise Parse::Agent::ValidationError,
                "semantic_search: text_field #{text_field.to_s.inspect} is not an embedded " \
                "text source for this class (allowed: #{allowed.inspect})."
        end
        text_field.to_sym
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
          "class_name"    => { "type" => "string", "description" => "Parse class name (must be agent_searchable)." },
          "query"         => { "type" => "string", "description" => "Natural-language query." },
          "k"             => { "type" => "integer", "default" => DEFAULT_K, "minimum" => 1, "maximum" => MAX_K },
          "filter"        => { "type" => "object", "description" => "Post-search field filter (allowlisted fields only)." },
          "vector_filter" => { "type" => "object", "description" => "Atlas pre-search filter (allowlisted fields only)." },
          "text_field"    => { "type" => "string", "description" => "Which embedded text source to chunk and return as content. Required only when the class embeds more than one text field; must name one of those sources." },
          "chunk_size"    => { "type" => "integer", "description" => "Override chunk window size." },
          "chunk_overlap" => { "type" => "integer", "description" => "Override chunk overlap." },
          "chunk_by"      => { "type" => "string", "enum" => %w[chars tokens], "description" => "Chunk unit." },
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
                "id"      => { "type" => "string" },
                "score"   => { "type" => %w[number null] },
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
