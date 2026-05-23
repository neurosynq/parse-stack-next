# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module AtlasSearch
    # Manages Atlas Search index discovery and caching.
    # Uses $listSearchIndexes aggregation stage to discover available indexes.
    #
    # @example List indexes
    #   indexes = Parse::AtlasSearch::IndexManager.list_indexes("Song")
    #   # => [{"name" => "default", "status" => "READY", ...}]
    #
    # @example Check if index is ready
    #   IndexManager.index_ready?("Song", "song_search")
    #   # => true
    module IndexManager
      class << self
        # List all search indexes for a collection (cached).
        # Uses the $listSearchIndexes aggregation stage.
        #
        # @param collection_name [String] the Parse collection name
        # @param force_refresh [Boolean] bypass cache and fetch fresh data
        # @return [Array<Hash>] array of index definitions with keys:
        #   - id: String - the index ID
        #   - name: String - the index name
        #   - status: String - "READY", "BUILDING", etc.
        #   - queryable: Boolean - whether the index is queryable
        #   - mappings: Hash - field mappings definition
        def list_indexes(collection_name, force_refresh: false)
          return cached_indexes(collection_name) if !force_refresh && cache_valid?(collection_name)

          # $listSearchIndexes must be the first and only stage in pipeline
          pipeline = [{ "$listSearchIndexes" => {} }]

          begin
            results = Parse::MongoDB.aggregate(collection_name, pipeline)
            cache_indexes(collection_name, results)
            results
          rescue => e
            handle_list_error(e, collection_name)
          end
        end

        # Check if a search index exists for a collection
        # @param collection_name [String] the Parse collection name
        # @param index_name [String] the index name to check
        # @return [Boolean] true if index exists
        def index_exists?(collection_name, index_name)
          indexes = list_indexes(collection_name)
          indexes.any? { |idx| idx["name"] == index_name }
        end

        # Check if a search index exists and is ready to query
        # @param collection_name [String] the Parse collection name
        # @param index_name [String] the index name to check
        # @return [Boolean] true if index exists and is queryable
        def index_ready?(collection_name, index_name)
          indexes = list_indexes(collection_name)
          index = indexes.find { |idx| idx["name"] == index_name }
          index.present? && index["queryable"] == true
        end

        # Get a specific index definition
        # @param collection_name [String] the Parse collection name
        # @param index_name [String] the index name
        # @return [Hash, nil] the index definition or nil if not found
        def get_index(collection_name, index_name)
          indexes = list_indexes(collection_name)
          indexes.find { |idx| idx["name"] == index_name }
        end

        # Validate that an index exists and is ready
        # @param collection_name [String] the Parse collection name
        # @param index_name [String] the index name to validate
        # @raise [IndexNotFound] if the index doesn't exist or isn't ready
        def validate_index!(collection_name, index_name)
          unless index_ready?(collection_name, index_name)
            available = list_indexes(collection_name).map { |i| i["name"] }.join(", ")
            raise IndexNotFound,
              "Atlas Search index '#{index_name}' not found or not ready on collection '#{collection_name}'. " \
              "Available indexes: #{available.presence || "none"}"
          end
        end

        # Clear the index cache
        # @param collection_name [String, nil] specific collection to clear, or nil for all
        def clear_cache(collection_name = nil)
          if collection_name
            index_cache.delete(collection_name)
          else
            @index_cache = {}
          end
        end

        private

        def index_cache
          @index_cache ||= {}
        end

        def cached_indexes(collection_name)
          index_cache.dig(collection_name, :indexes) || []
        end

        def cache_valid?(collection_name)
          entry = index_cache[collection_name]
          return false unless entry
          # Cache entries don't expire - use clear_cache or force_refresh to update
          true
        end

        def cache_indexes(collection_name, indexes)
          index_cache[collection_name] = {
            indexes: indexes,
            cached_at: Time.now,
          }
        end

        def handle_list_error(error, collection_name)
          msg = error.message.to_s.downcase
          if msg.include?("not available") ||
             msg.include?("atlas") ||
             msg.include?("command not found") ||
             msg.include?("unrecognized") ||
             msg.include?("not supported")
            raise NotAvailable,
              "Atlas Search is not available for collection '#{collection_name}'. " \
              "Ensure you're using MongoDB Atlas with Search enabled, or a local Atlas deployment. " \
              "Original error: #{error.message}"
          end
          raise error
        end
      end
    end
  end
end
