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
      # Maximum length of a regex or wildcard query string. Atlas Search uses
      # Lucene's bounded regex evaluator; long patterns and full-string
      # wildcards force a state-machine explosion or whole-index scan and can
      # be used to DoS the search node.
      MAX_PATTERN_LENGTH = 256

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
        validate_query_length!(query, "text")
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
        validate_query_length!(query, "phrase")
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
        validate_query_length!(query, "autocomplete")
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
      # @raise [ArgumentError] if `query` is empty, too long, or begins with
      #   a leading wildcard (`*` or `?`) which forces a full-index scan.
      def wildcard(query:, path:, allow_analyzed_field: nil)
        validate_pattern!(query, kind: "wildcard")
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
      # @raise [ArgumentError] if `query` is empty, too long, or starts with
      #   an unbounded match (`.*`, `.+`, `*`, `?`) that would scan the full
      #   index.
      def regex(query:, path:, allow_analyzed_field: nil)
        validate_pattern!(query, kind: "regex")
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

      # Atlas Search `geoShape` operator. Filters documents where the
      # indexed geometry has the specified relation to a query geometry.
      # Requires the indexed field to be mapped with `{type: "geo",
      # indexShapes: true}`.
      #
      # Note: Atlas Search uses Cartesian (planar) distance, NOT the
      # 2dsphere geodesic distance used by core MongoDB geo operators.
      # For shapes spanning large areas the two engines can return
      # different result sets.
      #
      # @param path [String, Symbol] the indexed `geo` field.
      # @param relation [Symbol, String] one of :contains, :disjoint,
      #   :intersects, :within. `:within` is not valid with LineString /
      #   Point query geometries.
      # @param geometry [Hash, Parse::Polygon, Parse::GeoPoint,
      #   Parse::GeoJSON::Geometry] the query geometry. Parse-native
      #   types are auto-converted to their GeoJSON form.
      # @param score [Hash, nil] optional `score` modifier.
      # @return [self] for chaining
      def geo_shape(path:, relation:, geometry:, score: nil)
        op = {
          "path" => path.to_s,
          "relation" => relation.to_s,
          "geometry" => coerce_geojson_geometry(geometry),
        }
        op["score"] = score if score
        @operators << { "geoShape" => op }
        self
      end

      # Atlas Search `geoWithin` operator. Returns documents whose
      # indexed point is inside the supplied region. Exactly one of
      # `box:`, `circle:`, `geometry:` must be provided.
      #
      # - `box`: `[bottom_left, top_right]` — each entry may be a
      #   {Parse::GeoPoint} or a GeoJSON Point Hash.
      # - `circle`: `{center: <GeoPoint|Hash>, radius: <meters>}`.
      #   Radius is measured in meters and must be non-negative.
      # - `geometry`: a GeoJSON Polygon or MultiPolygon (Hash, a
      #   {Parse::Polygon}, or {Parse::GeoJSON::MultiPolygon}).
      #
      # @param path [String, Symbol] the indexed `geo` field.
      # @param box [Array, nil] `[bottom_left, top_right]` point pair.
      # @param circle [Hash, nil] `{center:, radius:}`.
      # @param geometry [Hash, Parse::Polygon, Parse::GeoJSON::Geometry, nil]
      # @param score [Hash, nil] optional `score` modifier.
      # @return [self] for chaining
      def geo_within(path:, box: nil, circle: nil, geometry: nil, score: nil)
        provided = [box, circle, geometry].count { |v| !v.nil? }
        if provided != 1
          raise ArgumentError, "[Parse::AtlasSearch] geo_within requires exactly one of " \
                               "box:, circle:, or geometry: (got #{provided})."
        end

        op = { "path" => path.to_s }
        op["score"] = score if score

        if box
          unless box.is_a?(Array) && box.length == 2
            raise ArgumentError, "[Parse::AtlasSearch] geo_within `box:` must be [bottom_left, top_right]."
          end
          op["box"] = {
            "bottomLeft" => coerce_geojson_point(box[0]),
            "topRight" => coerce_geojson_point(box[1]),
          }
        elsif circle
          unless circle.is_a?(Hash)
            raise ArgumentError, "[Parse::AtlasSearch] geo_within `circle:` must be a Hash."
          end
          center = circle[:center] || circle["center"]
          radius = circle[:radius] || circle["radius"]
          unless radius.is_a?(Numeric) && radius >= 0
            raise ArgumentError, "[Parse::AtlasSearch] geo_within `circle: { radius: }` must be a non-negative number (meters)."
          end
          op["circle"] = { "center" => coerce_geojson_point(center), "radius" => radius.to_f }
        else
          op["geometry"] = coerce_geojson_geometry(geometry)
        end

        @operators << { "geoWithin" => op }
        self
      end

      # Atlas Search `near` operator on a geo path. SCORING operator —
      # blends "distance from origin" into the document score; it does
      # not strictly filter by distance. Combine with a `compound.must`
      # text/exists clause to bound the result set.
      #
      # `pivot` is the distance (in meters) at which the score is halved:
      # `score = pivot / (pivot + distance)`. Smaller pivot = steeper
      # falloff, more weight on the closest hits.
      #
      # @param path [String, Symbol] the indexed `geo` field.
      # @param origin [Parse::GeoPoint, Hash, Array] anchor point.
      # @param pivot [Numeric] half-score distance in meters.
      # @param score [Hash, nil] optional `score` modifier (advanced).
      # @return [self] for chaining
      def near(path:, origin:, pivot:, score: nil)
        unless pivot.is_a?(Numeric) && pivot > 0
          raise ArgumentError, "[Parse::AtlasSearch] near `pivot:` must be a positive number (meters)."
        end
        op = {
          "path" => path.to_s,
          "origin" => coerce_geojson_point(origin),
          "pivot" => pivot.to_f,
        }
        op["score"] = score if score
        @operators << { "near" => op }
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

      # Coerce a user-supplied point value to a GeoJSON Point Hash.
      # Accepts Parse::GeoPoint, an already-shaped GeoJSON Point Hash,
      # or a `[longitude, latitude]` Array. The Hash is returned with
      # string keys so it serializes cleanly through `$search`.
      def coerce_geojson_point(value)
        case value
        when Parse::GeoPoint
          { "type" => "Point", "coordinates" => [value.longitude, value.latitude] }
        when Hash
          h = value.respond_to?(:symbolize_keys) ? value.symbolize_keys : value
          type = h[:type] || h["type"]
          coords = h[:coordinates] || h["coordinates"]
          unless type.to_s == "Point" && coords.is_a?(Array) && coords.length == 2 &&
                 coords.all? { |n| n.is_a?(Numeric) }
            raise ArgumentError, "[Parse::AtlasSearch] expected a GeoJSON Point hash."
          end
          { "type" => "Point", "coordinates" => [coords[0].to_f, coords[1].to_f] }
        when Array
          unless value.length == 2 && value.all? { |n| n.is_a?(Numeric) }
            raise ArgumentError, "[Parse::AtlasSearch] point Array must be [longitude, latitude]."
          end
          { "type" => "Point", "coordinates" => [value[0].to_f, value[1].to_f] }
        else
          raise ArgumentError, "[Parse::AtlasSearch] cannot coerce #{value.class} to a GeoJSON Point."
        end
      end

      # Coerce a user-supplied geometry value to a GeoJSON geometry Hash.
      # Accepts any Parse::GeoJSON::Geometry subclass, Parse::Polygon,
      # Parse::GeoPoint, or a raw GeoJSON Hash (validated minimally).
      def coerce_geojson_geometry(value)
        case value
        when Parse::GeoJSON::Geometry then value.to_geojson
        when Parse::Polygon then value.to_geojson
        when Parse::GeoPoint then value.to_geojson
        when Hash
          h = value.respond_to?(:symbolize_keys) ? value.symbolize_keys : value
          type = h[:type] || h["type"]
          unless type.is_a?(String) && (h[:coordinates] || h["coordinates"])
            raise ArgumentError, "[Parse::AtlasSearch] GeoJSON geometry hash needs both `type` and `coordinates`."
          end
          { "type" => type, "coordinates" => (h[:coordinates] || h["coordinates"]) }
        else
          raise ArgumentError, "[Parse::AtlasSearch] cannot coerce #{value.class} to a GeoJSON geometry."
        end
      end

      # Reject empty, non-String, or oversized query strings. Applies
      # to every operator that takes a `query:` value (`text`,
      # `autocomplete`, `wildcard`, `regex`, `phrase`). Long patterns
      # are a denial-of-service vector against Atlas Search regardless
      # of operator type.
      def validate_query_length!(query, op_name)
        unless query.is_a?(String) && !query.empty?
          raise ArgumentError, "#{op_name} query must be a non-empty String"
        end
        if query.length > MAX_PATTERN_LENGTH
          raise ArgumentError,
            "#{op_name} query exceeds #{MAX_PATTERN_LENGTH} chars (#{query.length}). " \
            "Long patterns are denial-of-service vectors against Atlas Search."
        end
        nil
      end

      # Reject empty, oversized, or leading-wildcard patterns. Leading
      # wildcards on `wildcard` / `regex` operators force Atlas Search to
      # evaluate against every term in the index, which is both very slow
      # and a denial-of-service vector when the input is user-controlled.
      def validate_pattern!(query, kind:)
        validate_query_length!(query, kind)
        if kind == "wildcard"
          if query.start_with?("*") || query.start_with?("?")
            raise ArgumentError,
              "wildcard query may not begin with '*' or '?'; leading wildcards " \
              "force a full-index scan. Anchor the pattern with a literal prefix."
          end
        else # regex
          if query.start_with?(".*") || query.start_with?(".+") ||
             query.start_with?("*") || query.start_with?("?")
            raise ArgumentError,
              "regex query may not begin with '.*', '.+', '*', or '?'; " \
              "unbounded leading matches force a full-index scan. Anchor the " \
              "pattern with a literal prefix."
          end
        end
        nil
      end

      # Reject a `path` value that itself encodes a wildcard scanning
      # every indexed field (`{ "wildcard" => "*" }` or any leading
      # `*`/`?` wildcard). Used to harden pattern operators against
      # the `path` channel — `path: { wildcard: "*" }` reaches every
      # field in the index even when the `query` is anchored. The
      # top-level `Parse::AtlasSearch.search` call uses this for its
      # default-field fallback, but a caller-supplied hash payload
      # to `build_compound` must not be able to opt back in.
      def validate_path_for_pattern!(path, op_name)
        return unless path.is_a?(Hash)
        wildcard = path["wildcard"] || path[:wildcard]
        return if wildcard.nil?
        unless wildcard.is_a?(String) && !wildcard.empty?
          raise ArgumentError, "#{op_name} path.wildcard must be a non-empty String"
        end
        if wildcard.length > MAX_PATTERN_LENGTH
          raise ArgumentError,
            "#{op_name} path.wildcard exceeds #{MAX_PATTERN_LENGTH} chars."
        end
        if wildcard.start_with?("*") || wildcard.start_with?("?")
          raise ArgumentError,
            "#{op_name} path.wildcard may not begin with '*' or '?'; a leading " \
            "wildcard on the path scans every indexed field."
        end
        nil
      end

      # Recursively validate the query/path payloads inside an
      # operator hash supplied to {build_compound} via
      # `must:`/`should:`/`filter:`/`must_not:`. The caller-supplied
      # Hash form bypasses {#wildcard}/{#regex}/{#text}/{#autocomplete}
      # entirely, so this is the only gate the structural payload
      # passes through before reaching Atlas Search.
      #
      # Walks the `compound`/`must`/`mustNot`/`should`/`filter`
      # branches one level deep — the SDK-public API does not need
      # deeper-than-one nesting for the compound shapes we support.
      def validate_operator_payload!(op)
        return unless op.is_a?(Hash)
        op.each do |key, value|
          case key.to_s
          when "wildcard"
            next unless value.is_a?(Hash)
            q = value["query"] || value[:query]
            validate_pattern!(q, kind: "wildcard") if q
            validate_path_for_pattern!(value["path"] || value[:path], "wildcard")
          when "regex"
            next unless value.is_a?(Hash)
            q = value["query"] || value[:query]
            validate_pattern!(q, kind: "regex") if q
            validate_path_for_pattern!(value["path"] || value[:path], "regex")
          when "text"
            next unless value.is_a?(Hash)
            q = value["query"] || value[:query]
            validate_query_length!(q, "text") if q
            validate_path_for_pattern!(value["path"] || value[:path], "text")
          when "autocomplete"
            next unless value.is_a?(Hash)
            q = value["query"] || value[:query]
            validate_query_length!(q, "autocomplete") if q
            validate_path_for_pattern!(value["path"] || value[:path], "autocomplete")
          when "phrase"
            next unless value.is_a?(Hash)
            q = value["query"] || value[:query]
            validate_query_length!(q, "phrase") if q
          when "compound"
            next unless value.is_a?(Hash)
            %w[must mustNot should filter].each do |branch|
              Array(value[branch] || value[branch.to_sym]).each { |child| validate_operator_payload!(child) }
            end
          end
        end
      end

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
        # If it's a SearchBuilder, build it and extract the operator.
        # The nested operators were validated when they were added
        # through #wildcard/#regex/#text/#autocomplete on that builder,
        # so no re-check is required.
        if op.is_a?(SearchBuilder)
          built = op.build
          # Extract the operator from the built stage
          built["$search"].except("index")
        elsif op.is_a?(Hash)
          # Hash operator payload supplied directly by the caller --
          # this is the only path where validate_pattern! has NOT
          # already run. Refuse leading-wildcard regex/wildcard
          # patterns and oversized query strings before forwarding
          # to Atlas Search.
          validate_operator_payload!(op)
          op
        else
          op
        end
      end
    end
  end
end
