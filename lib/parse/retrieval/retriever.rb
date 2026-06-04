# encoding: UTF-8
# frozen_string_literal: true

require_relative "chunker"
require_relative "chunk"

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
    # @param hybrid [Object, nil] reserved — raises {NotImplementedError}
    #   if truthy. Hybrid (vector + lexical) retrieval lands in a later
    #   release; the kwarg locks the API shape now.
    # @param rerank [Object, nil] reserved — raises {NotImplementedError}
    #   if non-nil. Cross-encoder rerank lands in a later release.
    # @param scope_opts [Hash] ACL/CLP scope kwargs forwarded verbatim to
    #   `find_similar`: `session_token:` / `acl_user:` / `acl_role:` /
    #   `master:`.
    # @return [Array<Parse::Retrieval::Chunk>] descending by score; chunk
    #   order within a document is positional.
    def retrieve(query:, klass: nil, field: nil, text_field: nil, k: 10,
                 filter: nil, vector_filter: nil, chunker: nil,
                 tenant_scope: nil, score_quantize: false,
                 source_transform: nil, hybrid: nil, rerank: nil,
                 **scope_opts)
      raise NotImplementedError,
            "Parse::Retrieval.retrieve: `hybrid:` is reserved for a future release." if hybrid
      raise NotImplementedError,
            "Parse::Retrieval.retrieve: `rerank:` is reserved for a future release." if rerank

      # `class:` alias (reserved word — arrives via **scope_opts).
      klass ||= scope_opts.delete(:class)
      klass = resolve_class!(klass)

      unless query.is_a?(String) && !query.strip.empty?
        raise ArgumentError, "Parse::Retrieval.retrieve: `query:` must be a non-empty String."
      end

      resolved_text_field = (text_field || infer_text_field!(klass)).to_sym
      merged_vector_filter = fold_tenant_scope(klass, vector_filter, tenant_scope)
      chunker ||= default_chunker

      raw_hits = klass.find_similar(
        text: query,
        k: k,
        field: field,
        filter: filter,
        vector_filter: merged_vector_filter,
        raw: true,
        **scope_opts,
      )
      return [] if raw_hits.nil? || raw_hits.empty?

      text_wire = wire_name(klass, resolved_text_field)

      raw_hits.flat_map do |doc|
        build_chunks_for(doc, klass, text_wire, score_quantize, source_transform, chunker)
      end
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
    def build_chunks_for(doc, klass, text_wire, score_quantize, source_transform, chunker)
      object_id = (doc["_id"] || doc[:_id] || doc["objectId"] || doc[:objectId]).to_s
      raw_score = doc["_vscore"] || doc[:_vscore]
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
