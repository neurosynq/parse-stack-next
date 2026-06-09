# encoding: UTF-8
# frozen_string_literal: true

require_relative "chunker"
require_relative "chunk"
require_relative "reranker"

module Parse
  # Retrieval-augmented-generation (RAG) helpers. `Parse::RAG` is a
  # discoverability alias for this module.
  #
  # {.retrieve} is the agent-agnostic core: it embeds a natural-language
  # query, runs Atlas `$vectorSearch` through the existing
  # `Class.find_similar` (which enforces ACL/CLP mongo-direct), then
  # splits each retrieved document's text field into scored
  # {Parse::Retrieval::Chunk}s for presentation.
  #
  # The agent-facing `semantic_search` tool (see
  # `lib/parse/retrieval/agent_tool.rb`) wraps {.retrieve} with the
  # agent security envelope (tenant scope, `field_allowlist` projection,
  # score quantization).
  #
  # == ACL model
  #
  # {.retrieve} does NOT implement a REST "two-stage" re-query. The
  # vector path is mongo-direct only (Parse Server's REST `/aggregate`
  # is master-key-only and bypasses ACL — see the project notes), and
  # `acl_user:` / `acl_role:` scopes have no REST equivalent. ACL is
  # enforced inside `find_similar` via a post-`$vectorSearch` `_rperm`
  # `$match`. Scope kwargs (`session_token:` / `acl_user:` /
  # `acl_role:` / `master:`) pass straight through `**scope_opts`.
  module Retrieval
    # Raised when a tenant-scope value conflicts with a caller-supplied
    # `vector_filter` constraint on the same field — a scope-spoofing
    # attempt. Mirrors the agent layer's tenant-scope refusal.
    class TenantScopeConflict < ArgumentError; end

    # Raised when the text field to chunk cannot be inferred from the
    # class's `embed` declarations and was not passed explicitly.
    class AmbiguousTextField < ArgumentError; end

    module_function

    # Recursively refuse any underscore-prefixed key, at any depth, in a
    # caller-supplied filter. This is distinct from (and stricter than)
    # the agent layer's flat `validate_keys!`: a Mongo-style filter is a
    # nested structure, and an underscore key buried inside `$or` /
    # `$elemMatch` / a hash value could clobber tenant scope or reach a
    # reserved column (`_rperm`, `_p_*`, `_auth_data_*`). The walk is
    # unconditional — it does not special-case operators.
    #
    # @param obj [Object] a filter Hash/Array (or anything; scalars pass).
    # @param path [Array<String>] internal — accumulates the key path for
    #   the error message.
    # @raise [ArgumentError] on any `_`-prefixed key.
    def assert_no_underscore_keys!(obj, path = [])
      case obj
      when Hash
        obj.each do |k, v|
          ks = k.to_s
          if ks.start_with?("_")
            raise ArgumentError,
                  "filter key '#{(path + [ks]).join(".")}' is reserved (underscore-prefixed)."
          end
          assert_no_underscore_keys!(v, path + [ks])
        end
      when Array
        obj.each_with_index { |v, i| assert_no_underscore_keys!(v, path + ["[#{i}]"]) }
      end
      obj
    end

    # Translate Parse pointer VALUES in a caller-supplied filter into
    # their MongoDB storage form so they actually match raw documents.
    # `{ owner: <Parse::Pointer User/abc> }` becomes
    # `{ "_p_owner" => "_User$abc" }` — pointer columns are stored under
    # a `_p_` prefix with `"<className>$<objectId>"` string values, so a
    # Parse-side pointer (a `{__type: "Pointer", ...}` hash on the wire,
    # or a `Parse::Pointer` / `Parse::Object` instance from Ruby
    # callers) in a `$match` / `$vectorSearch.filter` would otherwise
    # never match anything.
    #
    # Recognized pointer values:
    # * `Parse::Pointer` / `Parse::Object` instances,
    # * `{ "__type" => "Pointer", "className" => ..., "objectId" => ... }`
    #   hashes (symbol or string keys).
    #
    # Translation applies to direct values, and to pointer values inside
    # one level of operator hashes (`{ owner: { "$in" => [ptr, ptr] } }`,
    # `$eq` / `$ne` / `$nin`). Non-pointer values and unrecognized keys
    # pass through untouched, so the call is idempotent.
    #
    # SECURITY ORDERING: run this AFTER {.assert_no_underscore_keys!} /
    # the agent filter-field allowlist (callers may not name `_p_*`
    # columns directly) and BEFORE the tenant-scope fold.
    #
    # @param klass [Class] the Parse::Object subclass (for field_map
    #   wire-name resolution).
    # @param filter [Hash, nil] caller filter.
    # @return [Hash, nil] translated copy (or the input when nothing
    #   needed translation / input was nil).
    def translate_pointer_filter_values(klass, filter)
      return filter unless filter.is_a?(Hash)
      out = {}
      filter.each do |key, value|
        if (storage = pointer_storage_value(value))
          out["_p_#{wire_name(klass, key)}"] = storage
        elsif value.is_a?(Hash) && value.keys.any? { |op| op.to_s.start_with?("$") }
          translated = value.transform_values do |opval|
            if (s = pointer_storage_value(opval))
              s
            elsif opval.is_a?(Array)
              opval.map { |el| pointer_storage_value(el) || el }
            else
              opval
            end
          end
          if translated == value
            out[key] = value
          else
            out["_p_#{wire_name(klass, key)}"] = translated
          end
        else
          out[key] = value
        end
      end
      out
    end

    # @!visibility private
    # `"<className>$<objectId>"` storage string for a pointer-shaped
    # value, or nil when the value is not a pointer.
    def pointer_storage_value(value)
      if defined?(Parse::Pointer) && value.is_a?(Parse::Pointer)
        cname = value.parse_class
        oid = value.id
        return nil if cname.to_s.empty? || oid.to_s.empty?
        return "#{cname}$#{oid}"
      end
      if value.is_a?(Hash)
        type = value["__type"] || value[:__type]
        return nil unless type.to_s == "Pointer"
        cname = value["className"] || value[:className]
        oid = value["objectId"] || value[:objectId]
        return nil if cname.to_s.empty? || oid.to_s.empty?
        return "#{cname}$#{oid}"
      end
      nil
    end

    # Retrieve and chunk documents semantically similar to `query`.
    #
    # @param query [String] natural-language query.
    # @param klass [Class, String] a Parse::Object subclass (or its
    #   class name) declaring a `:vector` property. `class:` is accepted
    #   as an alias.
    # @param field [Symbol, nil] the `:vector` property to search.
    #   Auto-resolved by `find_similar` when the class has exactly one.
    # @param text_field [Symbol, nil] the text property to chunk for
    #   presentation. Defaults to the sole text source of the class's
    #   `embed` declaration; raises {AmbiguousTextField} when it can't be
    #   inferred.
    # @param k [Integer] number of documents to retrieve. Default 10.
    # @param filter [Hash, nil] post-`$vectorSearch` `$match` filter.
    # @param vector_filter [Hash, nil] Atlas-native pre-search filter.
    # @param chunker [#chunk_with_meta, #chunk, nil] chunking strategy.
    #   Defaults to {Chunker::FixedSizeOverlap}.
    # @param tenant_scope [Hash, nil] `{ field:, value: }` merged into
    #   `vector_filter` (closing the cross-tenant existence side
    #   channel) — not just a post-stage match.
    # @param score_quantize [Boolean] round scores to 1 decimal (limits
    #   membership-inference probing in non-admin contexts).
    # @param source_transform [#call, nil] optional callable applied to
    #   each raw source record before it is stored on a Chunk. The agent
    #   tool injects tenant-scope assertion + `field_allowlist`
    #   projection here; a `StandardError` raised by the callable
    #   propagates and aborts the whole call (fail-closed). Kept as an
    #   injection point so this model-layer method stays free of any
    #   agent-layer dependency.
    # @param hybrid [Boolean, Hash, nil] when truthy, fuse a lexical
    #   Atlas Search branch with the `$vectorSearch` branch via
    #   reciprocal-rank fusion (see {Parse::Core::VectorSearchable#hybrid_search}).
    #   `true` uses defaults (lexical query = `query`); a Hash may carry
    #   `:lexical`, `:vector`, and `:fusion` sub-configs.
    # @param rerank [#rerank, nil] a {Parse::Retrieval::Reranker::Base}
    #   (or any object answering `#rerank(query:, documents:, top_n:)`).
    #   When present, retrieved documents are reordered by the
    #   cross-encoder relevance score BEFORE chunking, and the chunk score
    #   becomes the rerank relevance score.
    # @param rerank_top_n [Integer, nil] keep only the top-N documents
    #   after reranking (defaults to all retrieved documents).
    # @param scope_opts [Hash] ACL/CLP scope kwargs forwarded verbatim to
    #   `find_similar` / `hybrid_search`: `session_token:` / `acl_user:` /
    #   `acl_role:` / `master:`.
    # @return [Array<Parse::Retrieval::Chunk>] descending by score; chunk
    #   order within a document is positional.
    def retrieve(query:, klass: nil, field: nil, text_field: nil, k: 10,
                 filter: nil, vector_filter: nil, chunker: nil,
                 tenant_scope: nil, score_quantize: false,
                 source_transform: nil, hybrid: nil, rerank: nil,
                 rerank_top_n: nil, **scope_opts)
      if rerank && !rerank.respond_to?(:rerank)
        raise ArgumentError,
              "Parse::Retrieval.retrieve: `rerank:` must respond to #rerank " \
              "(a Parse::Retrieval::Reranker::Base); got #{rerank.class}."
      end

      # `class:` alias (reserved word — arrives via **scope_opts).
      klass ||= scope_opts.delete(:class)
      klass = resolve_class!(klass)

      unless query.is_a?(String) && !query.strip.empty?
        raise ArgumentError, "Parse::Retrieval.retrieve: `query:` must be a non-empty String."
      end

      resolved_text_field = (text_field || infer_text_field!(klass)).to_sym
      # Pointer-value translation runs BEFORE the tenant-scope fold (the
      # fold's conflict check must see final storage-form keys) and after
      # any caller-side underscore-key gate (the agent tool walks the raw
      # filter before calling retrieve).
      filter = translate_pointer_filter_values(klass, filter)
      vector_filter = translate_pointer_filter_values(klass, vector_filter)
      merged_vector_filter = fold_tenant_scope(klass, vector_filter, tenant_scope)
      chunker ||= default_chunker
      text_wire = wire_name(klass, resolved_text_field)

      raw_hits =
        if hybrid
          fetch_hybrid_hits(klass, query, k, field, filter, merged_vector_filter,
                            tenant_scope, hybrid, scope_opts)
        else
          klass.find_similar(
            text: query, k: k, field: field, filter: filter,
            vector_filter: merged_vector_filter, raw: true, **scope_opts,
          )
        end
      return [] if raw_hits.nil? || raw_hits.empty?

      raw_hits = apply_rerank(rerank, query, raw_hits, text_wire, rerank_top_n) if rerank

      raw_hits.flat_map do |doc|
        build_chunks_for(doc, klass, text_wire, score_quantize, source_transform, chunker)
      end
    end

    # @!visibility private
    # Run the hybrid (lexical + vector) branch and return fused raw rows.
    # Tenant scope is folded into BOTH branches: the vector branch via the
    # Atlas pre-filter (`merged_vector_filter`) and the lexical branch via
    # a post-`$search` `$match` (so neither branch leaks cross-tenant
    # document existence).
    def fetch_hybrid_hits(klass, query, k, field, filter, merged_vector_filter,
                          tenant_scope, hybrid, scope_opts)
      cfg = hybrid.is_a?(Hash) ? hybrid : {}
      lexical = (cfg[:lexical] || cfg["lexical"] || {}).dup
      vector  = (cfg[:vector]  || cfg["vector"]  || {}).dup
      fusion  = cfg[:fusion] || cfg["fusion"]

      lexical[:query] ||= query
      # Tenant scope must be AUTHORITATIVE in BOTH branches. The previous
      # `||=` form let a caller-supplied `vector[:vector_filter]` (or a
      # colliding `lexical[:filter]`) REPLACE the tenant-folded filter
      # rather than narrow within it — silently dropping tenant isolation
      # and contradicting this method's "folded into BOTH branches"
      # contract. `merge_filters` is last-wins, so ordering the tenant
      # constraint LAST guarantees its key survives any caller collision:
      # callers can narrow the result set but never escape their tenant.
      lexical[:filter] = merge_filters(filter, lexical[:filter], tenant_filter_hash(klass, tenant_scope))
      vector[:field] ||= field unless field.nil?
      vector[:filter] = merge_filters(vector[:filter], filter)
      vector[:vector_filter] = merge_filters(vector[:vector_filter], merged_vector_filter)

      klass.hybrid_search(
        text: query, lexical: lexical, vector: vector,
        k: k, fusion: fusion, raw: true, **scope_opts,
      )
    end

    # @!visibility private
    def resolve_class!(klass)
      resolved =
        case klass
        when nil
          nil
        when Class
          klass
        else
          Parse::Model.find_class(klass.to_s)
        end
      unless resolved.is_a?(Class) && resolved.respond_to?(:find_similar)
        raise ArgumentError,
              "Parse::Retrieval.retrieve: `klass:`/`class:` must be a Parse::Object " \
              "subclass with a :vector property (got #{klass.inspect})."
      end
      resolved
    end

    # @!visibility private
    # Infer the text field to chunk from the class's `embed` directives:
    # the sole text (non-image) source field. Raises when zero or more
    # than one candidate exists — the caller must then pass `text_field:`.
    def infer_text_field!(klass)
      directives = klass.respond_to?(:embed_directives) ? klass.embed_directives.values : []
      sources = directives.reject { |d| d.respond_to?(:image?) && d.image? }
                          .flat_map(&:sources).uniq
      return sources.first if sources.length == 1
      raise AmbiguousTextField,
            "Parse::Retrieval.retrieve: cannot infer the text field to chunk for " \
            "#{klass} (candidates: #{sources.inspect}); pass `text_field:` explicitly."
    end

    # @!visibility private
    def default_chunker
      Chunker::FixedSizeOverlap.new(size: 800, overlap: 100)
    end

    # @!visibility private
    # Merge the tenant scope into the Atlas pre-search filter using the
    # field's wire/storage column name. A pre-existing constraint on the
    # same field with a different value is a spoof attempt and is refused.
    def fold_tenant_scope(klass, vector_filter, tenant_scope)
      return vector_filter if tenant_scope.nil?
      field = tenant_scope[:field] || tenant_scope["field"]
      value = tenant_scope.key?(:value) ? tenant_scope[:value] : tenant_scope["value"]
      return vector_filter if field.nil?

      wire = wire_name(klass, field)
      base = vector_filter ? vector_filter.dup : {}
      existing_key = base.keys.find { |k| k.to_s == wire }
      if existing_key && base[existing_key] != value
        raise TenantScopeConflict,
              "Parse::Retrieval.retrieve: vector_filter pins #{wire.inspect} to " \
              "#{base[existing_key].inspect} but the tenant scope requires #{value.inspect}."
      end
      base[wire] = value
      base
    end

    # @!visibility private
    # Ruby property symbol -> wire/storage column name. Prefers the
    # class's explicit field_map alias; falls back to lowerCamelCase
    # columnization. Matches the resolution MetadataRegistry uses.
    def wire_name(klass, field)
      sym = field.to_sym
      fmap = klass.respond_to?(:field_map) ? klass.field_map : {}
      mapped = fmap[sym]
      (mapped || sym.to_s.columnize).to_s
    end

    # @!visibility private
    def fetch_field(doc, wire, sym)
      return doc[wire] if doc.key?(wire)
      return doc[wire.to_sym] if doc.key?(wire.to_sym)
      return doc[sym.to_s] if doc.key?(sym.to_s)
      doc[sym]
    end

    # @!visibility private
    # Reorder retrieved documents by a cross-encoder reranker and stamp
    # each surviving hit with its `_rerank_score`. The reranker scores the
    # document's presentation text (the same `text_field` used for
    # chunking). Index alignment between `documents` and `raw_hits` is
    # preserved so the returned `index` maps back to the right hit.
    def apply_rerank(reranker, query, raw_hits, text_wire, top_n)
      documents = raw_hits.map { |doc| fetch_field(doc, text_wire, text_wire).to_s }
      results = reranker.rerank(query: query, documents: documents, top_n: top_n)
      results.map do |r|
        hit = raw_hits[r.index]
        next nil if hit.nil?
        hit = hit.dup
        hit["_rerank_score"] = r.relevance_score
        hit
      end.compact
    end

    # @!visibility private
    # Convert a `{ field:, value: }` tenant scope into a `{ wire => value }`
    # filter hash (the lexical branch's post-`$search` `$match`), or nil.
    def tenant_filter_hash(klass, tenant_scope)
      return nil if tenant_scope.nil?
      field = tenant_scope[:field] || tenant_scope["field"]
      return nil if field.nil?
      value = tenant_scope.key?(:value) ? tenant_scope[:value] : tenant_scope["value"]
      { wire_name(klass, field) => value }
    end

    # @!visibility private
    # Shallow-merge non-empty filter hashes (left-to-right; later keys
    # win). Returns nil when nothing is left to apply.
    def merge_filters(*filters)
      merged = {}
      filters.each do |f|
        next if f.nil? || (f.respond_to?(:empty?) && f.empty?)
        merged.merge!(f)
      end
      merged.empty? ? nil : merged
    end

    # @!visibility private
    def build_chunks_for(doc, klass, text_wire, score_quantize, source_transform, chunker)
      object_id = (doc["_id"] || doc[:_id] || doc["objectId"] || doc[:objectId]).to_s
      raw_score = doc["_rerank_score"] || doc[:_rerank_score] ||
                  doc["_hybrid_score"] || doc[:_hybrid_score] ||
                  doc["_vscore"] || doc[:_vscore]
      score = quantize_score(raw_score, score_quantize)

      text = fetch_field(doc, text_wire, text_wire)
      meta = chunker.respond_to?(:chunk_with_meta) ? chunker.chunk_with_meta(text) : nil
      chunks = meta ? meta[:chunks] : Array(chunker.chunk(text))
      truncated = meta ? meta[:truncated] : false
      # A document that matched on its vector but carries no presentation
      # text yields no chunks (skipped, not an empty-content chunk).
      return [] if chunks.empty?

      source = source_transform ? source_transform.call(doc) : doc
      count = chunks.length
      chunks.each_with_index.map do |content, idx|
        Chunk.new(
          id: "#{object_id}##{idx}",
          content: content,
          score: score,
          source: source,
          metadata: {
            chunk_index: idx,
            chunk_count: count,
            chunks_truncated: truncated,
            object_id: object_id,
            class: klass.parse_class,
          },
        )
      end
    end

    # @!visibility private
    def quantize_score(score, quantize)
      return score if score.nil?
      f = score.to_f
      quantize ? ((f * 10).round / 10.0) : f
    end
  end

  # Discoverability alias. "RAG" ages badly as a term; `Retrieval` is
  # the canonical name.
  RAG = Retrieval
end
