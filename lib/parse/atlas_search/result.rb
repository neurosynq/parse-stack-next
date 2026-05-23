# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module AtlasSearch
    # Result container for full-text search operations.
    # Provides access to results with relevance scores.
    #
    # @example Iterating results
    #   result = Parse::AtlasSearch.search("Song", "love")
    #   result.each do |song|
    #     puts "#{song.title} (score: #{song.search_score})"
    #   end
    #
    # @example Checking results
    #   result.empty?  # => false
    #   result.count   # => 25
    class SearchResult
      include Enumerable

      # @return [Array<Parse::Object>] the search results (Parse objects or raw hashes)
      attr_reader :results

      # @return [Array<Hash>] the raw MongoDB documents
      attr_reader :raw_results

      # @param results [Array] the processed search results
      # @param raw_results [Array<Hash>] the raw MongoDB documents
      def initialize(results:, raw_results: nil)
        @results = results
        @raw_results = raw_results || results
      end

      # @return [Integer] the number of results
      def count
        @results.size
      end

      alias_method :size, :count
      alias_method :length, :count

      # @return [Boolean] true if there are no results
      def empty?
        @results.empty?
      end

      # Iterate over results
      # @yield [Object] each result object
      def each(&block)
        @results.each(&block)
      end

      # @return [Object, nil] the first result
      def first
        @results.first
      end

      # @return [Object, nil] the last result
      def last
        @results.last
      end

      # Access result by index
      # @param index [Integer] the index
      # @return [Object, nil] the result at the index
      def [](index)
        @results[index]
      end

      # @return [Array] the results as an array
      def to_a
        @results.to_a
      end
    end

    # Result container for autocomplete search operations.
    # Provides both suggestions (field values) and full objects.
    #
    # @example Using suggestions
    #   result = Parse::AtlasSearch.autocomplete("Song", "lov", field: :title)
    #   result.suggestions # => ["Love Story", "Lovely Day", "Love Me Do"]
    #
    # @example Accessing full objects
    #   result.results.each do |song|
    #     puts "#{song.title} by #{song.artist}"
    #   end
    class AutocompleteResult
      # @return [Array<String>] the autocomplete suggestions (field values)
      attr_reader :suggestions

      # @return [Array<Parse::Object>] the full Parse objects
      attr_reader :results

      # @param suggestions [Array<String>] the autocomplete suggestions
      # @param results [Array] the full Parse objects
      def initialize(suggestions:, results:)
        @suggestions = suggestions
        @results = results
      end

      # @return [Integer] the number of suggestions
      def count
        @suggestions.size
      end

      alias_method :size, :count

      # @return [Boolean] true if there are no suggestions
      def empty?
        @suggestions.empty?
      end

      # Iterate over suggestions
      # @yield [String] each suggestion
      def each(&block)
        @suggestions.each(&block)
      end

      # @return [String, nil] the first suggestion
      def first
        @suggestions.first
      end

      # @return [Array<String>] the suggestions as an array
      def to_a
        @suggestions.to_a
      end
    end

    # Result container for faceted search operations.
    # Provides results, facet counts, and total count.
    #
    # @example Using facets
    #   result = Parse::AtlasSearch.faceted_search("Song", "rock", facets)
    #   result.facets[:genre].each do |bucket|
    #     puts "#{bucket[:value]}: #{bucket[:count]}"
    #   end
    #
    # @example Total count
    #   puts "Total matches: #{result.total_count}"
    class FacetedResult
      include Enumerable

      # @return [Array<Parse::Object>] the search results
      attr_reader :results

      # @return [Hash] the facet results with counts
      #   Format: { facet_name: [{ value: "value", count: 123 }, ...] }
      attr_reader :facets

      # @return [Integer] the total number of matching documents
      attr_reader :total_count

      # @param results [Array] the search results
      # @param facets [Hash] the facet results
      # @param total_count [Integer] the total matching document count
      def initialize(results:, facets:, total_count:)
        @results = results
        @facets = facets
        @total_count = total_count
      end

      # @return [Integer] the number of returned results
      def count
        @results.size
      end

      alias_method :size, :count

      # @return [Boolean] true if there are no results
      def empty?
        @results.empty?
      end

      # Iterate over results
      # @yield [Object] each result object
      def each(&block)
        @results.each(&block)
      end

      # @return [Object, nil] the first result
      def first
        @results.first
      end

      # Get facet buckets for a specific facet
      # @param name [Symbol, String] the facet name
      # @return [Array<Hash>, nil] the facet buckets or nil if facet doesn't exist
      def facet(name)
        @facets[name.to_sym] || @facets[name.to_s]
      end

      # @return [Array<Symbol>] the available facet names
      def facet_names
        @facets.keys
      end

      # @return [Array] the results as an array
      def to_a
        @results.to_a
      end
    end
  end
end
