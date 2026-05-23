# encoding: UTF-8
# frozen_string_literal: true

require_relative "atlas_search/index_manager"
require_relative "atlas_search/search_builder"
require_relative "atlas_search/result"

module Parse
  # Atlas Search module for MongoDB Atlas full-text search capabilities.
  # Provides direct access to Atlas Search features bypassing Parse Server.
  #
  # @example Enable Atlas Search
  #   Parse::MongoDB.configure(uri: "mongodb+srv://...", enabled: true)
  #   Parse::AtlasSearch.configure(enabled: true, default_index: "default")
  #
  # @example Full-text search
  #   result = Parse::AtlasSearch.search("Song", "love", index: "song_search")
  #   result.results.each { |song| puts song.title }
  #
  # @example Autocomplete
  #   result = Parse::AtlasSearch.autocomplete("Song", "lov", field: :title)
  #   result.suggestions # => ["Love Story", "Lovely Day", "Love Me Do"]
  #
  # @note Requires the 'mongo' gem and a MongoDB Atlas cluster with Search enabled.
  #   Also works with local Atlas deployments created via `atlas deployments setup --type local`.
  module AtlasSearch
    # Error raised when Atlas Search is not available
    class NotAvailable < StandardError; end

    # Error raised when search index is not found
    class IndexNotFound < StandardError; end

    # Error raised for invalid search parameters
    class InvalidSearchParameters < StandardError; end

    class << self
      # @!attribute [rw] enabled
      #   Feature flag to enable/disable Atlas Search.
      #   @return [Boolean]
      attr_accessor :enabled

      # @!attribute [rw] default_index
      #   Default search index name to use when none specified.
      #   @return [String]
      attr_accessor :default_index

      # Configure Atlas Search (uses Parse::MongoDB connection)
      # @param enabled [Boolean] whether to enable Atlas Search (default: true)
      # @param default_index [String] default search index name (default: "default")
      # @example
      #   Parse::AtlasSearch.configure(enabled: true, default_index: "default")
      def configure(enabled: true, default_index: "default")
        Parse::MongoDB.require_gem!
        @enabled = enabled
        @default_index = default_index
        IndexManager.clear_cache
      end

      # Check if Atlas Search is available and enabled
      # @return [Boolean]
      def available?
        return false unless defined?(Parse::MongoDB)
        Parse::MongoDB.available? && enabled?
      end

      # Check if Atlas Search is enabled
      # @return [Boolean]
      def enabled?
        @enabled == true
      end

      # Reset Atlas Search configuration
      def reset!
        @enabled = false
        @default_index = "default"
        IndexManager.clear_cache
      end

      # List search indexes for a collection (cached)
      # @param collection_name [String] the Parse collection name
      # @return [Array<Hash>] array of index definitions
      def indexes(collection_name)
        IndexManager.list_indexes(collection_name)
      end

      # Check if a search index exists and is ready
      # @param collection_name [String] the Parse collection name
      # @param index_name [String] the index name to check (default: default_index)
      # @return [Boolean] true if index exists and is queryable
      def index_ready?(collection_name, index_name = nil)
        IndexManager.index_ready?(collection_name, index_name || @default_index)
      end

      # Force refresh the index cache for a collection
      # @param collection_name [String] the Parse collection name (nil to clear all)
      def refresh_indexes(collection_name = nil)
        IndexManager.clear_cache(collection_name)
      end

      #----------------------------------------------------------------
      # SEARCH OPERATIONS
      #----------------------------------------------------------------

      # Perform a full-text search using Atlas Search.
      #
      # @param collection_name [String] the Parse collection name (e.g., "Song")
      # @param query [String] the search query text
      # @param options [Hash] search options
      # @option options [String] :index search index name (default: configured default_index)
      # @option options [Array<String>, String, Symbol] :fields fields to search (default: all indexed fields)
      # @option options [Boolean] :fuzzy enable fuzzy matching (default: false)
      # @option options [Integer] :fuzzy_max_edits max edit distance for fuzzy (1 or 2, default: 2)
      # @option options [Symbol, String] :highlight_field field to return highlights for
      # @option options [Integer] :limit max results to return (default: 100)
      # @option options [Integer] :skip number of results to skip (default: 0)
      # @option options [Hash] :filter additional constraints to apply
      # @option options [Hash] :sort sort specification (default: by relevance score)
      # @option options [Boolean] :raw return raw MongoDB documents (default: false)
      # @option options [String] :class_name Parse class name for object conversion
      #
      # @return [Parse::AtlasSearch::SearchResult] search result object
      #
      # @example Basic search
      #   result = Parse::AtlasSearch.search("Song", "love ballad")
      #   result.results.each { |song| puts song.title }
      #
      # @example Search with fuzzy matching and field restriction
      #   result = Parse::AtlasSearch.search("Song", "lvoe",
      #     fields: [:title, :lyrics],
      #     fuzzy: true,
      #     limit: 20
      #   )
      def search(collection_name, query, **options)
        require_available!
        validate_search_params!(query)

        index_name = options[:index] || @default_index
        fields = normalize_fields(options[:fields])
        limit = options[:limit] || 100
        skip_val = options[:skip] || 0

        # Build the $search stage
        builder = SearchBuilder.new(index_name: index_name)

        if fields.present?
          fields.each do |field|
            builder.text(query: query, path: field, fuzzy: options[:fuzzy])
          end
        else
          builder.text(query: query, path: { "wildcard" => "*" }, fuzzy: options[:fuzzy])
        end

        if options[:highlight_field]
          builder.with_highlight(path: options[:highlight_field])
        end

        # Build the full pipeline
        pipeline = [builder.build]

        # Add score projection
        pipeline << { "$addFields" => { "_score" => { "$meta" => "searchScore" } } }

        # Add highlights projection if requested
        if options[:highlight_field]
          pipeline << { "$addFields" => { "_highlights" => { "$meta" => "searchHighlights" } } }
        end

        # Add filter stage if provided
        if options[:filter]
          mongo_filter = convert_filter_for_mongodb(options[:filter], collection_name)
          pipeline << { "$match" => mongo_filter }
        end

        # Add sort (default by score)
        sort_spec = options[:sort] || { "_score" => -1 }
        pipeline << { "$sort" => sort_spec }

        # Add pagination
        pipeline << { "$skip" => skip_val } if skip_val > 0
        pipeline << { "$limit" => limit }

        # Execute the search
        raw_results = Parse::MongoDB.aggregate(collection_name, pipeline)

        # Convert results
        class_name = options[:class_name] || collection_name
        process_search_results(raw_results, class_name, options[:raw])
      end

      # Perform an autocomplete search for search-as-you-type functionality.
      #
      # @param collection_name [String] the Parse collection name
      # @param query [String] the partial search query (prefix)
      # @param field [Symbol, String] the field configured for autocomplete
      # @param options [Hash] autocomplete options
      # @option options [String] :index search index name (default: configured default_index)
      # @option options [Boolean] :fuzzy enable fuzzy matching (default: false)
      # @option options [Integer] :fuzzy_max_edits max edit distance (1 or 2, default: 1)
      # @option options [String] :token_order "any" or "sequential" (default: "any")
      # @option options [Integer] :limit max suggestions to return (default: 10)
      # @option options [Hash] :filter additional constraints
      # @option options [Boolean] :raw return raw documents (default: false)
      #
      # @return [Parse::AtlasSearch::AutocompleteResult] autocomplete result
      #
      # @example Basic autocomplete
      #   result = Parse::AtlasSearch.autocomplete("Song", "lov", field: :title)
      #   result.suggestions # => ["Love Story", "Lovely Day", "Love Me Do"]
      def autocomplete(collection_name, query, field:, **options)
        require_available!

        raise InvalidSearchParameters, "field is required for autocomplete" if field.nil?
        raise InvalidSearchParameters, "query must be a non-empty string" if query.nil? || query.to_s.strip.empty?

        index_name = options[:index] || @default_index
        limit = options[:limit] || 10
        field_str = field.to_s

        # Build autocomplete search stage
        builder = SearchBuilder.new(index_name: index_name)
        builder.autocomplete(
          query: query.to_s,
          path: field_str,
          fuzzy: options[:fuzzy],
          token_order: options[:token_order],
        )

        pipeline = [builder.build]

        # Add score
        pipeline << { "$addFields" => { "_score" => { "$meta" => "searchScore" } } }

        # Add filter if provided
        if options[:filter]
          mongo_filter = convert_filter_for_mongodb(options[:filter], collection_name)
          pipeline << { "$match" => mongo_filter }
        end

        # Sort by score and limit
        pipeline << { "$sort" => { "_score" => -1 } }
        pipeline << { "$limit" => limit }

        raw_results = Parse::MongoDB.aggregate(collection_name, pipeline)

        # Extract suggestions (the field values)
        suggestions = raw_results.map { |doc| doc[field_str] }.compact.uniq

        # Convert to full objects if needed
        class_name = options[:class_name] || collection_name
        results = if options[:raw]
            raw_results
          else
            parse_results = Parse::MongoDB.convert_documents_to_parse(raw_results, class_name)
            parse_results.map { |doc| build_parse_object(doc, class_name) }.compact
          end

        AutocompleteResult.new(suggestions: suggestions, results: results)
      end

      # Perform a faceted search with category counts.
      #
      # @param collection_name [String] the Parse collection name
      # @param query [String, nil] the search query text (nil for match-all)
      # @param facets [Hash] facet definitions
      # @param options [Hash] search options (same as #search)
      #
      # @return [Parse::AtlasSearch::FacetedResult] faceted result
      #
      # @example Faceted search by genre and year
      #   facets = {
      #     genre: { type: :string, path: :genre },
      #     decade: { type: :number, path: :year, boundaries: [1970, 1980, 1990, 2000, 2010] }
      #   }
      #   result = Parse::AtlasSearch.faceted_search("Song", "rock", facets)
      #   result.facets[:genre] # => [{ value: "Rock", count: 150 }, ...]
      def faceted_search(collection_name, query, facets, **options)
        require_available!

        index_name = options[:index] || @default_index
        limit = options[:limit] || 100
        skip_val = options[:skip] || 0

        # Build facet definitions for $searchMeta
        facet_definitions = build_facet_definitions(facets)

        search_meta_stage = {
          "$searchMeta" => {
            "index" => index_name,
            "facet" => {
              "facets" => facet_definitions,
            },
          },
        }

        # Add operator for the search query if present
        if query.present?
          fields = normalize_fields(options[:fields])
          if fields.present?
            should_clauses = fields.map do |field|
              { "text" => { "query" => query, "path" => field } }
            end
            search_meta_stage["$searchMeta"]["facet"]["operator"] = {
              "compound" => { "should" => should_clauses, "minimumShouldMatch" => 1 },
            }
          else
            search_meta_stage["$searchMeta"]["facet"]["operator"] = {
              "text" => { "query" => query, "path" => { "wildcard" => "*" } },
            }
          end
        end

        # Execute facet query
        facet_pipeline = [search_meta_stage]
        facet_results_raw = Parse::MongoDB.aggregate(collection_name, facet_pipeline)

        # Extract facet results
        facet_data = {}
        total_count = 0

        if facet_results_raw.first
          raw = facet_results_raw.first
          total_count = raw.dig("count", "total") || 0

          if raw["facet"]
            facets.keys.each do |facet_name|
              bucket_key = facet_name.to_s
              if raw["facet"][bucket_key]
                facet_data[facet_name] = raw["facet"][bucket_key]["buckets"].map do |bucket|
                  { value: bucket["_id"], count: bucket["count"] }
                end
              end
            end
          end
        end

        # Get actual results with regular $search
        results = if limit > 0 && query.present?
            search(collection_name, query, **options.merge(limit: limit, skip: skip_val)).results
          else
            []
          end

        FacetedResult.new(results: results, facets: facet_data, total_count: total_count)
      end

      private

      def require_available!
        Parse::MongoDB.require_gem!
        unless available?
          raise NotAvailable,
            "Atlas Search is not available. Ensure Parse::MongoDB is configured " \
            "and Parse::AtlasSearch.configure(enabled: true) has been called."
        end
      end

      def validate_search_params!(query)
        raise InvalidSearchParameters, "query must be a string" unless query.is_a?(String)
        raise InvalidSearchParameters, "query cannot be empty" if query.strip.empty?
      end

      def normalize_fields(fields)
        return nil if fields.nil?
        Array(fields).map(&:to_s)
      end

      def convert_filter_for_mongodb(filter, collection_name)
        # For now, pass through as-is. Could integrate with Query's constraint conversion
        filter
      end

      def build_facet_definitions(facets)
        definitions = {}

        facets.each do |name, config|
          path = config[:path].to_s
          facet_def = { "path" => path }

          case config[:type]
          when :string
            facet_def["type"] = "string"
            facet_def["numBuckets"] = config[:num_buckets] || 10
          when :number
            facet_def["type"] = "number"
            facet_def["boundaries"] = config[:boundaries] if config[:boundaries]
            facet_def["default"] = config[:default] if config[:default]
          when :date
            facet_def["type"] = "date"
            facet_def["boundaries"] = config[:boundaries].map do |d|
              d.respond_to?(:iso8601) ? d.iso8601 : d
            end if config[:boundaries]
            facet_def["default"] = config[:default] if config[:default]
          end

          definitions[name.to_s] = facet_def
        end

        definitions
      end

      def build_parse_object(doc, class_name)
        # Try to use Parse::Object.build if available, otherwise return the hash
        if defined?(Parse::Object) && Parse::Object.respond_to?(:build)
          Parse::Object.build(doc, class_name)
        else
          # Fallback: return hash with class info
          doc["className"] ||= class_name
          doc
        end
      end

      def process_search_results(raw_results, class_name, raw_mode)
        if raw_mode
          SearchResult.new(results: raw_results, raw_results: raw_results)
        else
          parse_results = Parse::MongoDB.convert_documents_to_parse(raw_results, class_name)
          objects = parse_results.each_with_index.map do |doc, idx|
            obj = build_parse_object(doc, class_name)
            raw_doc = raw_results[idx]
            # Attach search metadata from original raw document (scores are stripped during conversion)
            if obj && raw_doc["_score"]
              obj.instance_variable_set(:@_search_score, raw_doc["_score"])
              # Define accessor if not already defined
              unless obj.respond_to?(:search_score)
                obj.define_singleton_method(:search_score) { @_search_score }
              end
            end
            if obj && raw_doc["_highlights"]
              obj.instance_variable_set(:@_search_highlights, raw_doc["_highlights"])
              unless obj.respond_to?(:search_highlights)
                obj.define_singleton_method(:search_highlights) { @_search_highlights }
              end
            end
            obj
          end.compact
          SearchResult.new(results: objects, raw_results: raw_results)
        end
      end
    end

    # Initialize defaults
    @enabled = false
    @default_index = "default"
  end
end
