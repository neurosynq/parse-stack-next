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
      DEFAULT_K = 5

      # @param agent [Parse::Agent]
      # @return [Hash] `{ chunks: Array<Hash>, count: Integer }`
      def semantic_search(agent, class_name: nil, query: nil, k: DEFAULT_K,
                          filter: nil, vector_filter: nil,
                          chunk_size: nil, chunk_overlap: nil, chunk_by: nil,
                          **_ignored)
        klass = Parse::Agent::MetadataRegistry.resolve_searchable!(class_name)
        cname = klass.parse_class

        unless query.is_a?(String) && !query.strip.empty?
          raise Parse::Agent::ValidationError, "semantic_search: `query` must be a non-empty String."
        end

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

        # Non-admin agents get quantized scores (membership-inference
        # defense); admin agents get full precision. Keyed on the
        # permission tier, not master-key posture.
        score_quantize = (agent.permissions != :admin)
        vector_field = Parse::Agent::MetadataRegistry.searchable_field(cname)

        chunks = Parse::Retrieval.retrieve(
          query: query,
          klass: klass,
          field: vector_field,
          k: clamp_k(k),
          filter: filter,
          vector_filter: vector_filter,
          chunker: build_chunker(chunk_size, chunk_overlap, chunk_by),
          tenant_scope: scope,
          score_quantize: score_quantize,
          source_transform: source_projector(agent, cname, scope),
          **agent.acl_scope_kwargs,
        )

        { chunks: chunks.map(&:to_h), count: chunks.length }
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
          Parse::Agent::Tools.redact_hidden_classes!(projected, agent: agent)
        end
      end

      # @!visibility private
      def convert_to_parse_form(raw_doc, cname)
        Parse::MongoDB.convert_documents_to_parse([raw_doc], cname).first || raw_doc
      rescue StandardError
        # If conversion is unavailable for any reason, fall back to the
        # raw hit; project_object_to_allowlist still strips to the
        # allowlist (fail-closed: unknown keys are dropped, not surfaced).
        raw_doc
      end

      # @!visibility private
      def clamp_k(k)
        n = k.to_i
        n = DEFAULT_K if n <= 0
        [n, MAX_K].min
      end

      # @!visibility private
      def build_chunker(size, overlap, by)
        return nil if size.nil? && overlap.nil? && by.nil?
        Parse::Retrieval::Chunker::FixedSizeOverlap.new(
          size: (size || 800).to_i,
          overlap: (overlap || 100).to_i,
          by: (by || :chars).to_sym,
        )
      rescue ArgumentError => e
        raise Parse::Agent::ValidationError, "semantic_search: invalid chunker options — #{e.message}"
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
          "chunk_size"    => { "type" => "integer", "description" => "Override chunk window size." },
          "chunk_overlap" => { "type" => "integer", "description" => "Override chunk overlap." },
          "chunk_by"      => { "type" => "string", "enum" => %w[chars tokens], "description" => "Chunk unit." },
        },
        "required" => %w[class_name query],
      }.freeze

      # MCP outputSchema → mirrored as structuredContent on results.
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
                "source"  => { "type" => "object" },
                "metadata" => { "type" => "object" },
              },
            },
          },
          "count" => { "type" => "integer" },
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
