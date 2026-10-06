# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module VectorSearch
    # Derives an Atlas `vectorSearch` index definition from a model's
    # declarations, so the index an operator deploys matches what the SDK
    # will query instead of being written by hand.
    #
    # Sources, all read from the model:
    #
    # * the `:vector` property: path, `numDimensions` (`dimensions:`),
    #   `similarity` (`similarity:`, default `cosine`), and the optional
    #   index-side `quantization:` (`:scalar` / `:binary`);
    # * `agent_searchable filter_fields:`, the fields the agent tool lets a
    #   caller pass as `vector_filter:` (pointer fields map to their
    #   `_p_<column>` storage path, matching the pointer translation
    #   {Parse::Retrieval.retrieve} applies);
    # * the `agent_tenant_scope` field, which retrieval folds into
    #   `$vectorSearch.filter` on every scoped query.
    #
    # Output is deterministic: the vector entry first, then filter entries
    # sorted by path, keys in a fixed order. Generating is side-effect free;
    # applying an index stays explicit through
    # {Parse::Schema::SearchIndexMigrator} (declare it with the
    # `vector_search_index` model macro and run `apply_search_indexes!`).
    #
    # @example
    #   class Article < Parse::Object
    #     property :embedding, :vector, dimensions: 1024, similarity: :dotProduct,
    #                                   quantization: :scalar
    #     agent_searchable field: :embedding, filter_fields: %i[category]
    #     vector_search_index "article_vec"   # generated; applied explicitly
    #   end
    #
    #   Parse::VectorSearch::IndexDefinition.build(Article)
    #   # => { "fields" => [
    #   #      { "type" => "vector", "path" => "embedding", "numDimensions" => 1024,
    #   #        "similarity" => "dotProduct", "quantization" => "scalar" },
    #   #      { "type" => "filter", "path" => "category" } ] }
    module IndexDefinition
      # Similarity emitted when the property declares none. Atlas requires
      # one; cosine is the safe choice for unit-normalized embeddings.
      DEFAULT_SIMILARITY = "cosine"

      # Index-side quantization values accepted on a `:vector` property.
      QUANTIZATIONS = %w[scalar binary].freeze

      # Key order for each field entry, so serialized output is stable.
      VECTOR_KEY_ORDER = %w[type path numDimensions similarity quantization].freeze

      module_function

      # Build the definition for one `:vector` field of `model_class`.
      #
      # @param model_class [Class] a Parse::Object subclass.
      # @param field [Symbol, String, nil] the `:vector` property; may be
      #   omitted when the class declares exactly one searchable vector.
      # @return [Hash] a string-keyed `{ "fields" => [...] }` definition.
      # @raise [ArgumentError] when the field cannot be resolved.
      def build(model_class, field: nil)
        field_sym = resolve_field!(model_class, field)
        meta = model_class.vector_properties.fetch(field_sym)

        vector = {
          "type" => "vector",
          "path" => field_sym.to_s,
          "numDimensions" => meta[:dimensions],
          "similarity" => (meta[:similarity] || DEFAULT_SIMILARITY).to_s,
        }
        vector["quantization"] = meta[:quantization].to_s if meta[:quantization]

        filters = filter_paths(model_class).map { |path| { "type" => "filter", "path" => path } }
        { "fields" => [order_keys(vector)] + filters }
      end

      # Preview the declaration a `vector_search_index` macro would apply.
      #
      # @return [Hash] `{ name:, type: "vectorSearch", definition: }`.
      def preview(model_class, name:, field: nil)
        { name: name.to_s, type: "vectorSearch", definition: build(model_class, field: field) }
      end

      # Structured, deterministic comparison of a declared definition with a
      # live one. Accepts either definitions or index documents carrying
      # `latestDefinition` (the shape `$listSearchIndexes` returns).
      #
      # @param declared [Hash] the generated (or declared) definition.
      # @param live [Hash, nil] the live definition or index document.
      # @return [Hash] `{ in_sync:, vector: { key => { declared:, live: } },
      #   filters_missing: [...], filters_extra: [...] }`. `vector` lists
      #   only differing keys; `filters_missing` are declared filter paths
      #   absent from the live index (scoped queries on them fail
      #   Atlas-side), `filters_extra` are live paths not declared.
      def diff(declared, live)
        declared_defn = definition_of(declared)
        live_defn = definition_of(live)

        d_vec = vector_entry(declared_defn)
        l_vec = vector_entry(live_defn)
        vector_changes = {}
        (VECTOR_KEY_ORDER - %w[type]).each do |key|
          dv = normalize_vector_value(key, d_vec[key])
          lv = normalize_vector_value(key, l_vec[key])
          vector_changes[key] = { declared: dv, live: lv } unless dv == lv
        end

        d_filters = filter_paths_of(declared_defn)
        l_filters = filter_paths_of(live_defn)
        missing = (d_filters - l_filters).sort
        extra = (l_filters - d_filters).sort

        {
          in_sync: vector_changes.empty? && missing.empty? && extra.empty?,
          vector: vector_changes,
          filters_missing: missing,
          filters_extra: extra,
        }
      end

      # @!visibility private
      def resolve_field!(model_class, field)
        unless model_class.respond_to?(:vector_properties)
          raise ArgumentError, "#{model_class.inspect} declares no :vector properties."
        end
        props = model_class.vector_properties
        searchable = props.keys.reject { |k| props[k][:searchable] == false }
        if field
          sym = field.to_sym
          unless searchable.include?(sym)
            raise ArgumentError,
                  "#{model_class}: :#{sym} is not a searchable :vector property " \
                  "(searchable: #{searchable.inspect})."
          end
          return sym
        end
        return searchable.first if searchable.length == 1
        raise ArgumentError,
              "#{model_class}: cannot infer the vector field (searchable: #{searchable.inspect}); " \
              "pass field:."
      end

      # @!visibility private
      # Filter paths the SDK pre-filters on for this class, deduplicated and
      # sorted. Tenant path matches the resolution the migrator's
      # augmentation and first-query drift check use.
      def filter_paths(model_class)
        paths = []
        class_name = model_class.parse_class
        if defined?(Parse::Agent::MetadataRegistry)
          Parse::Agent::MetadataRegistry.searchable_filter_fields(class_name).each do |f|
            paths << storage_path(model_class, f)
          end
          rule = Parse::Agent::MetadataRegistry.tenant_scope_rule(class_name)
          paths << wire_name(model_class, rule[:field]) if rule
        end
        paths.compact.uniq.sort
      end

      # @!visibility private
      def storage_path(model_class, field)
        wire = wire_name(model_class, field)
        type = model_class.respond_to?(:fields) ? model_class.fields[field.to_sym] : nil
        type == :pointer ? "_p_#{wire}" : wire
      end

      # @!visibility private
      def wire_name(model_class, field)
        sym = field.to_sym
        fmap = model_class.respond_to?(:field_map) ? model_class.field_map : {}
        (fmap[sym] || sym.to_s.columnize).to_s
      end

      # @!visibility private
      def order_keys(entry)
        VECTOR_KEY_ORDER.each_with_object({}) { |k, h| h[k] = entry[k] if entry.key?(k) }
      end

      # @!visibility private
      def definition_of(value)
        return {} unless value.is_a?(Hash)
        inner = value["latestDefinition"] || value[:latestDefinition] ||
                value[:definition] || value["definition"]
        inner.is_a?(Hash) ? inner : value
      end

      # @!visibility private
      def fields_of(defn)
        Array(defn["fields"] || defn[:fields]).select { |f| f.is_a?(Hash) }
      end

      # @!visibility private
      def vector_entry(defn)
        entry = fields_of(defn).find { |f| (f["type"] || f[:type]).to_s == "vector" } || {}
        entry.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end

      # @!visibility private
      def filter_paths_of(defn)
        fields_of(defn).select { |f| (f["type"] || f[:type]).to_s == "filter" }
                       .map { |f| (f["path"] || f[:path]).to_s }.uniq.sort
      end

      # @!visibility private
      # An absent `quantization` means none on both sides; numbers compare
      # as integers; everything else as strings.
      def normalize_vector_value(key, value)
        case key
        when "quantization"
          value.nil? || value.to_s.empty? ? "none" : value.to_s
        when "numDimensions"
          value.nil? ? nil : Integer(value)
        else
          value&.to_s
        end
      end
    end
  end

  module Schema
    class << self
      # Generate the Atlas `vectorSearch` index definition for a model's
      # `:vector` field. See {Parse::VectorSearch::IndexDefinition.build}.
      #
      # @return [Hash]
      def vector_index_definition(model_class, field: nil)
        Parse::VectorSearch::IndexDefinition.build(model_class, field: field)
      end
    end
  end
end
