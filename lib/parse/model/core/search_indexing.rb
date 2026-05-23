# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Core
    # Model-declarative Atlas Search index DSL. Mixed into Parse::Object
    # so subclasses can declare the Atlas Search indexes they expect to
    # exist on their collection. Declarations are inert at load time —
    # they only land on Atlas when {Parse::Schema::SearchIndexMigrator}
    # reads them and `apply_search_indexes!` is invoked through the
    # writer connection.
    #
    # Parallels {Parse::Core::Indexing} (the regular `mongo_index` DSL)
    # but with three meaningful differences:
    #
    #   - **Multi-per-class.** A single model can declare several search
    #     indexes (one for full-text, one for autocomplete, one for
    #     vector search), each with a unique name.
    #   - **Definition is opaque.** The DSL doesn't introspect field
    #     references — Atlas owns the mapping schema. The DSL validates
    #     name shape and Hash-non-emptiness only; everything else is
    #     forwarded to Atlas verbatim.
    #   - **Async build.** Mutations don't return a "READY" guarantee
    #     — the migrator's rake task is fire-and-forget by default,
    #     `WAIT=true` opts into polling via
    #     {Parse::AtlasSearch::IndexManager.wait_for_ready}.
    #
    # SECURITY POSTURE — purely declarative. No network I/O at
    # declaration time, no class introspection. The validation rules
    # below surface typos as load-time errors instead of runtime
    # surprises during `rake parse:mongo:search_indexes:apply` in prod.
    #
    # @example Declaring search indexes
    #   class Song < Parse::Object
    #     property :title, :string
    #     property :artist, :string
    #
    #     mongo_search_index "song_search", {
    #       mappings: { dynamic: false, fields: {
    #         title:  { type: "string", analyzer: "lucene.standard" },
    #         artist: { type: "string" },
    #       } },
    #     }
    #     mongo_search_index "song_autocomplete", {
    #       mappings: { fields: {
    #         title: { type: "autocomplete", tokenization: "edgeGram" },
    #       } },
    #     }
    #   end
    module SearchIndexing
      # Atlas Search index name shape. Same regex used at the
      # {Parse::MongoDB.create_search_index} layer.
      INDEX_NAME_PATTERN = /\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/.freeze

      # Allowed `type:` values for `mongo_search_index`. `search` is the
      # default and covers the conventional text-search / autocomplete /
      # faceted-search use cases; `vectorSearch` is for vector similarity
      # indexes. Atlas rejects any other value at command time, but we
      # check at declaration time so the typo doesn't survive to prod.
      ALLOWED_INDEX_TYPES = %w[search vectorSearch].freeze

      # Storage for declared search indexes. Each entry is a frozen Hash
      # with keys `:name`, `:definition`, `:type`.
      # @return [Array<Hash>]
      def mongo_search_index_declarations
        @mongo_search_index_declarations ||= []
      end

      # Declare an Atlas Search index for this model's collection.
      #
      # @param name [String] the search index name. Must match
      #   {INDEX_NAME_PATTERN}.
      # @param definition [Hash] the search index definition (mappings,
      #   analyzers, etc.). Forwarded verbatim to Atlas after
      #   string-keyed normalization at apply time. Must be a non-empty
      #   Hash.
      # @param type [String] one of {ALLOWED_INDEX_TYPES}. Default
      #   `"search"`.
      # @return [Hash] the registered declaration (frozen)
      # @raise [ArgumentError] when validation fails, or when a
      #   declaration with the same name was already registered on this
      #   class with a different definition or type (idempotent
      #   redeclaration with identical content returns the existing
      #   entry).
      def mongo_search_index(name, definition, type: "search")
        name_str = name.to_s
        unless name_str.match?(INDEX_NAME_PATTERN)
          raise ArgumentError,
                "#{self}.mongo_search_index name #{name.inspect} must match #{INDEX_NAME_PATTERN.inspect}"
        end
        unless definition.is_a?(Hash) && !definition.empty?
          raise ArgumentError,
                "#{self}.mongo_search_index #{name_str.inspect} requires a non-empty Hash definition; got #{definition.inspect}"
        end
        type_str = type.to_s
        unless ALLOWED_INDEX_TYPES.include?(type_str)
          raise ArgumentError,
                "#{self}.mongo_search_index #{name_str.inspect} type=#{type.inspect} must be one of #{ALLOWED_INDEX_TYPES.inspect}"
        end

        declaration = {
          name:       name_str,
          definition: deep_freeze(definition),
          type:       type_str,
        }.freeze

        existing = mongo_search_index_declarations.find { |d| d[:name] == name_str }
        if existing
          # Idempotent redeclaration with identical content — common in
          # autoloading / class-reopening setups. Re-declarations that
          # disagree on definition or type fail loudly so the operator
          # notices the conflict at class load instead of at apply time.
          if existing[:definition] == declaration[:definition] && existing[:type] == declaration[:type]
            return existing
          end
          raise ArgumentError,
                "#{self}.mongo_search_index #{name_str.inspect} re-declared with a different " \
                "definition or type. Each name may have one declaration per class. " \
                "Use a unique name for the new index, or update the existing declaration in place."
        end

        mongo_search_index_declarations << declaration
        declaration
      end

      # Dry-run reconciliation between declared search indexes and what
      # exists on Atlas. Delegates to {Parse::Schema::SearchIndexMigrator}.
      # @return [Hash] see {Parse::Schema::SearchIndexMigrator#plan}
      def search_indexes_plan
        Parse::Schema::SearchIndexMigrator.new(self).plan
      end

      # Apply declared search-index changes via the writer connection.
      #
      # @param update [Boolean] when true, drift-detected indexes are
      #   updated via `updateSearchIndex`. When false (default), drift
      #   is reported and the index is left untouched (operator must
      #   either re-declare to match or explicitly opt-in to update).
      # @param drop [Boolean] when true, orphan search indexes (those
      #   on the collection but not declared) are dropped.
      # @param wait [Boolean] when true, block on
      #   {Parse::AtlasSearch::IndexManager.wait_for_ready} after every
      #   create / update to confirm the build completed before
      #   returning.
      # @param timeout [Integer] wait timeout in seconds (when `wait:
      #   true`). Default 600.
      # @return [Hash] see {Parse::Schema::SearchIndexMigrator#apply!}
      def apply_search_indexes!(update: false, drop: false, wait: false, timeout: 600)
        Parse::Schema::SearchIndexMigrator.new(self).apply!(
          update: update, drop: drop, wait: wait, timeout: timeout,
        )
      end

      private

      # Recursive deep-freeze so a stored declaration can't be mutated
      # post-registration by code that holds a reference to the original
      # `definition` Hash.
      def deep_freeze(value)
        case value
        when Hash
          value.each { |_, v| deep_freeze(v) }
          value.freeze
        when Array
          value.each { |v| deep_freeze(v) }
          value.freeze
        else
          value.freeze if value.respond_to?(:freeze) && !value.frozen? rescue value
          value
        end
      end
    end
  end
end
