# encoding: UTF-8
# frozen_string_literal: true

require "time"
require "date"

module Parse
  module AtlasSearch
    # Builder for constructing $search aggregation pipeline stages.
    # Supports fluent interface for complex queries.
    #
    # @example Simple text search
    #   builder = SearchBuilder.new(index_name: "default")
    #   builder.text(query: "love", path: :title)
    #   stage = builder.build
    #   # => { "$search" => { "index" => "default", "text" => { "query" => "love", "path" => "title" } } }
    #
    # @example Complex compound query
    #   builder = SearchBuilder.new
    #   builder.text(query: "love", path: [:title, :lyrics])
    #   builder.phrase(query: "broken heart", path: :lyrics, slop: 2)
    #   builder.with_highlight(path: :lyrics)
    #   stage = builder.build
    class SearchBuilder
      attr_reader :index_name, :operators, :highlight_config, :count_config

      def initialize(index_name: nil)
        @index_name = index_name || Parse::AtlasSearch.default_index || "default"
        @operators = []
        @highlight_config = nil
        @count_config = nil
        @fuzzy_config = nil
      end

      # Add a text search operator
      # @param query [String] the search query
      # @param path [String, Symbol, Array, Hash] field(s) to search
      # @param fuzzy [Boolean, Hash] fuzzy matching options
      # @param score [Hash] custom score modifiers
      # @param synonyms [String] synonym mapping name
      # @return [self] for chaining
      def text(query:, path:, fuzzy: nil, score: nil, synonyms: nil)
        operator = {
          "text" => {
            "query" => query,
            "path" => normalize_path(path),
          },
        }

        if fuzzy
          operator["text"]["fuzzy"] = fuzzy.is_a?(Hash) ? fuzzy : { "maxEdits" => 2 }
        end

        operator["text"]["score"] = score if score
        operator["text"]["synonyms"] = synonyms if synonyms

        @operators << operator
        self
      end

      # Add a phrase search operator
      # @param query [String] the phrase to search for
      # @param path [String, Symbol, Array] field(s) to search
      # @param slop [Integer] number of words between phrase terms (default: 0)
      # @return [self] for chaining
      def phrase(query:, path:, slop: nil)
        operator = {
          "phrase" => {
            "query" => query,
            "path" => normalize_path(path),
          },
        }

        operator["phrase"]["slop"] = slop if slop

        @operators << operator
        self
      end

      # Add an autocomplete operator (requires autocomplete index type)
      # @param query [String] the partial text to autocomplete
      # @param path [String, Symbol] the field with autocomplete index
      # @param fuzzy [Boolean, Hash] fuzzy matching options
      # @param token_order [String] "any" or "sequential"
      # @return [self] for chaining
      def autocomplete(query:, path:, fuzzy: nil, token_order: nil)
        operator = {
          "autocomplete" => {
            "query" => query,
            "path" => path.to_s,
          },
        }

        if fuzzy
          operator["autocomplete"]["fuzzy"] = fuzzy.is_a?(Hash) ? fuzzy : {
            "maxEdits" => 1,
            "prefixLength" => 1,
          }
        end

        operator["autocomplete"]["tokenOrder"] = token_order if token_order

        @operators << operator
        self
      end

      # Add a wildcard search operator
      # @param query [String] the wildcard pattern (* and ? supported)
      # @param path [String, Symbol, Array] field(s) to search
      # @param allow_analyzed_field [Boolean] allow searching analyzed fields
      # @return [self] for chaining
      def wildcard(query:, path:, allow_analyzed_field: nil)
        operator = {
          "wildcard" => {
            "query" => query,
            "path" => normalize_path(path),
          },
        }

        operator["wildcard"]["allowAnalyzedField"] = allow_analyzed_field unless allow_analyzed_field.nil?

        @operators << operator
        self
      end

      # Add a regex search operator
      # @param query [String] the regex pattern
      # @param path [String, Symbol, Array] field(s) to search
      # @param allow_analyzed_field [Boolean] allow searching analyzed fields
      # @return [self] for chaining
      def regex(query:, path:, allow_analyzed_field: nil)
        operator = {
          "regex" => {
            "query" => query,
            "path" => normalize_path(path),
          },
        }

        operator["regex"]["allowAnalyzedField"] = allow_analyzed_field unless allow_analyzed_field.nil?

        @operators << operator
        self
      end

      # Add a range search operator for numeric/date fields
      # @param path [String, Symbol] the field to search
      # @param gt [Numeric, Time, Date] greater than value
      # @param gte [Numeric, Time, Date] greater than or equal value
      # @param lt [Numeric, Time, Date] less than value
      # @param lte [Numeric, Time, Date] less than or equal value
      # @return [self] for chaining
      def range(path:, gt: nil, gte: nil, lt: nil, lte: nil)
        operator = {
          "range" => {
            "path" => path.to_s,
          },
        }

        operator["range"]["gt"] = format_range_value(gt) if gt
        operator["range"]["gte"] = format_range_value(gte) if gte
        operator["range"]["lt"] = format_range_value(lt) if lt
        operator["range"]["lte"] = format_range_value(lte) if lte

        @operators << operator
        self
      end

      # Add an exists operator to match documents where field exists
      # @param path [String, Symbol] the field to check
      # @return [self] for chaining
      def exists(path:)
        @operators << { "exists" => { "path" => path.to_s } }
        self
      end

      # Add global fuzzy configuration for subsequent text operators
      # @param max_edits [Integer] maximum edit distance (1 or 2)
      # @param prefix_length [Integer] number of characters that must match exactly
      # @param max_expansions [Integer] maximum number of variations to generate
      # @return [self] for chaining
      def with_fuzzy(max_edits: 2, prefix_length: 0, max_expansions: 50)
        @fuzzy_config = {
          "maxEdits" => max_edits,
          "prefixLength" => prefix_length,
          "maxExpansions" => max_expansions,
        }
        self
      end

      # Enable highlighting for search results
      # @param path [String, Symbol, Array] field(s) to highlight
      # @param max_chars_to_examine [Integer] max characters to analyze for highlights
      # @param max_num_passages [Integer] max number of highlight passages
      # @return [self] for chaining
      def with_highlight(path: nil, max_chars_to_examine: nil, max_num_passages: nil)
        @highlight_config = {}
        @highlight_config["path"] = normalize_path(path) if path
        @highlight_config["maxCharsToExamine"] = max_chars_to_examine if max_chars_to_examine
        @highlight_config["maxNumPassages"] = max_num_passages if max_num_passages
        self
      end

      # Enable count metadata in results
      # @param type [String] count type - "total" or "lowerBound"
      # @return [self] for chaining
      def with_count(type: "total")
        @count_config = { "type" => type }
        self
      end

      # Build the $search aggregation stage
      # @return [Hash] the $search stage
      # @raise [InvalidSearchParameters] if no operators have been added
      def build
        if @operators.empty?
          raise InvalidSearchParameters, "At least one search operator must be specified"
        end

        search_stage = { "$search" => { "index" => @index_name } }

        # Single operator or compound
        if @operators.length == 1
          search_stage["$search"].merge!(@operators.first)
        else
          # Multiple operators become a compound query with "must" clauses
          search_stage["$search"]["compound"] = { "must" => @operators }
        end

        # Add highlight config
        search_stage["$search"]["highlight"] = @highlight_config if @highlight_config

        # Add count config
        search_stage["$search"]["count"] = @count_config if @count_config

        search_stage
      end

      # Build a compound query explicitly
      # @param must [Array, Hash] operators that must match
      # @param must_not [Array, Hash] operators that must not match
      # @param should [Array, Hash] operators where at least one should match
      # @param filter [Array, Hash] operators for filtering (no scoring impact)
      # @param minimum_should_match [Integer] minimum number of should clauses to match
      # @return [Hash] the $search stage with compound query
      def build_compound(must: nil, must_not: nil, should: nil, filter: nil, minimum_should_match: nil)
        compound = {}

        compound["must"] = Array.wrap(must).map { |op| extract_operator(op) } if must
        compound["mustNot"] = Array.wrap(must_not).map { |op| extract_operator(op) } if must_not
        compound["should"] = Array.wrap(should).map { |op| extract_operator(op) } if should
        compound["filter"] = Array.wrap(filter).map { |op| extract_operator(op) } if filter
        compound["minimumShouldMatch"] = minimum_should_match if minimum_should_match

        search_stage = {
          "$search" => {
            "index" => @index_name,
            "compound" => compound,
          },
        }

        search_stage["$search"]["highlight"] = @highlight_config if @highlight_config
        search_stage["$search"]["count"] = @count_config if @count_config

        search_stage
      end

      private

      def normalize_path(path)
        case path
        when Array
          path.map(&:to_s)
        when Hash
          # Wildcard path: { "wildcard" => "*" }
          path.transform_keys(&:to_s)
        else
          path.to_s
        end
      end

      def format_range_value(value)
        case value
        when ::Time, ::DateTime
          value.utc.iso8601(3)
        when ::Date
          value.to_time.utc.iso8601(3)
        else
          value
        end
      end

      def extract_operator(op)
        # If it's a SearchBuilder, build it and extract the operator
        if op.is_a?(SearchBuilder)
          built = op.build
          # Extract the operator from the built stage
          built["$search"].except("index")
        elsif op.is_a?(Hash)
          op
        else
          op
        end
      end
    end
  end
end
