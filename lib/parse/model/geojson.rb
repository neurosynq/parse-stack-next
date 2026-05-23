# encoding: UTF-8
# frozen_string_literal: true

require_relative "model"
require_relative "geopoint"

module Parse
  # GeoJSON-native geometry wrappers for types that Parse Server's schema
  # does NOT model directly but that MongoDB's `2dsphere` index supports
  # natively. These classes are designed for callers that go through the
  # mongo-direct surface (`Parse::MongoDB`) or Atlas Search, where stored
  # geometry can be richer than the `GeoPoint` / `Polygon` types Parse
  # Server exposes.
  #
  # **Axis order.** Unlike {Parse::GeoPoint} and {Parse::Polygon}, which
  # store coordinates in Parse-native `[latitude, longitude]` order to
  # match the REST wire format, every class under `Parse::GeoJSON` stores
  # coordinates in GeoJSON-native `[longitude, latitude]` order. The
  # namespace itself is the axis-order signal — pick the namespace based
  # on which side of the boundary you're working on.
  #
  # **Storage.** These geometries live in `:object` Parse columns. Parse
  # Server treats the value as an opaque hash on read and write; MongoDB
  # will happily index it on a `2dsphere` index regardless of whether
  # Parse Server's schema knows the type exists.
  module GeoJSON
    # Base class for GeoJSON geometry wrappers. Subclasses define `TYPE`
    # and `#valid_coordinates?` and inherit the round-trip plumbing.
    class Geometry < Parse::Model
      # @return [Array] the raw coordinates array, in GeoJSON nesting and
      #   `[longitude, latitude]` axis order. Shape varies by subclass.
      attr_reader :coordinates

      # @return [String] the GeoJSON `type` discriminator (`"Point"`,
      #   `"LineString"`, `"Polygon"`, `"MultiPolygon"`, etc.).
      def self.geojson_type
        const_get(:TYPE)
      end

      def geojson_type
        self.class.geojson_type
      end

      # The initializer accepts either a GeoJSON Hash (`{type:, coordinates:}`),
      # a plain coordinates Array, or another instance of the same class.
      def initialize(value = nil)
        @coordinates = []
        self.coordinates = value unless value.nil?
      end

      def coordinates=(value)
        coords =
          case value
          when self.class
            deep_copy_array(value.coordinates)
          when Hash
            hash = value.respond_to?(:symbolize_keys) ? value.symbolize_keys : value
            type = hash[:type] || hash["type"]
            if type && type.to_s != self.class.geojson_type
              raise ArgumentError, "[#{self.class}] expected GeoJSON type " \
                                   "#{self.class.geojson_type.inspect}, got #{type.inspect}."
            end
            normalize(hash[:coordinates] || hash["coordinates"] || [])
          when Array
            normalize(value)
          else
            raise ArgumentError, "[#{self.class}] cannot build from #{value.class}: " \
                                 "expected GeoJSON Hash, coordinates Array, or another #{self.class}."
          end
        @coordinates = coords
        validate!
        @coordinates
      end

      # @return [Hash] the standard GeoJSON `{type:, coordinates:}` hash.
      def to_geojson
        { "type" => geojson_type, "coordinates" => deep_copy_array(@coordinates) }
      end
      alias_method :as_json, :to_geojson

      # @return [String] the JSON form, suitable for direct shipment to
      #   any GeoJSON-aware consumer.
      def to_json(*args)
        to_geojson.to_json(*args)
      end

      def ==(other)
        return false unless other.is_a?(self.class)
        @coordinates == other.coordinates
      end

      def inspect
        "#<#{self.class.name} #{@coordinates.inspect}>"
      end

      # @!visibility private
      def initialize_copy(other)
        super
        @coordinates = deep_copy_array(other.coordinates)
      end

      # Build any GeoJSON geometry from its wire-format Hash. Dispatches to
      # the matching subclass based on the `type` field.
      # @example
      #   Parse::GeoJSON::Geometry.from_geojson(line_string_hash) # => Parse::GeoJSON::LineString
      # @return [Parse::GeoJSON::Geometry]
      def self.from_geojson(hash)
        raise ArgumentError, "[Parse::GeoJSON::Geometry] expected a Hash." unless hash.is_a?(Hash)
        h = hash.respond_to?(:symbolize_keys) ? hash.symbolize_keys : hash
        type = (h[:type] || h["type"]).to_s
        klass = TYPE_REGISTRY[type]
        raise ArgumentError, "[Parse::GeoJSON::Geometry] unsupported GeoJSON type #{type.inspect}." if klass.nil?
        klass.new(h)
      end

      private

      def deep_copy_array(arr)
        arr.map { |entry| entry.is_a?(Array) ? deep_copy_array(entry) : entry }
      end

      def normalize(_value)
        raise NotImplementedError, "subclass must implement #normalize"
      end

      def validate!
        # subclasses may override
      end
    end

    # `LineString` — an ordered sequence of `[longitude, latitude]` points
    # describing a path. The most common applications are GPS tracks,
    # delivery routes, road segments, and trail centerlines.
    #
    # GeoJSON requires ≥ 2 points; this class warns when the constraint
    # is violated rather than raising, matching {Parse::GeoPoint} /
    # {Parse::Polygon} validation style.
    #
    # @example
    #   Parse::GeoJSON::LineString.new [[-122.4, 37.7], [-122.39, 37.78]]
    class LineString < Geometry
      TYPE = "LineString"
      MIN_POINTS = 2

      # @return [Array<Parse::GeoPoint>] the path as Parse::GeoPoint objects
      #   (axis-swapped back to Parse's `[lat, lng]`).
      def geo_points
        @coordinates.map { |(lng, lat)| Parse::GeoPoint.new(lat, lng) }
      end

      private

      def normalize(value)
        raise ArgumentError, "[Parse::GeoJSON::LineString] coordinates must be an Array." unless value.is_a?(Array)
        value.map do |pair|
          case pair
          when Parse::GeoPoint
            finite_lnglat!(pair.longitude.to_f, pair.latitude.to_f)
          when Array
            unless pair.length == 2 && pair[0].is_a?(Numeric) && pair[1].is_a?(Numeric)
              raise ArgumentError, "[Parse::GeoJSON::LineString] each coordinate must be a [lng, lat] numeric pair."
            end
            finite_lnglat!(pair[0].to_f, pair[1].to_f)
          else
            raise ArgumentError, "[Parse::GeoJSON::LineString] unsupported coordinate entry #{pair.inspect}."
          end
        end
      end

      # Reject NaN / Infinity at the door. `Float::NAN.is_a?(Numeric)`
      # is true so the earlier type check is insufficient; persisting
      # a line with NaN errors mid-pipeline at `2dsphere` index rebuild
      # time.
      def finite_lnglat!(lng, lat)
        unless lng.finite? && lat.finite?
          raise ArgumentError, "[Parse::GeoJSON::LineString] coordinates must be finite numerics; got [#{lng}, #{lat}]."
        end
        [lng, lat]
      end

      def validate!
        return if @coordinates.empty?
        if @coordinates.length < MIN_POINTS
          warn "[Parse::GeoJSON::LineString] requires at least #{MIN_POINTS} points; got #{@coordinates.length}."
        end
      end
    end

    # `MultiPolygon` — an Array of Polygons, each Polygon an Array of
    # linear rings, each ring an Array of `[lng, lat]` pairs. The canonical
    # use case is administrative or territorial regions made up of
    # disjoint pieces (Hawaii, Indonesia, multi-island service areas,
    # postal-code clusters).
    #
    # GeoJSON nesting depth is 4: `coordinates[polygon][ring][point][lng_or_lat]`.
    # Each ring must contain ≥ 4 points and be explicitly closed.
    #
    # @example
    #   Parse::GeoJSON::MultiPolygon.new [
    #     [[[ 0, 0], [ 1, 0], [ 1, 1], [ 0, 1], [ 0, 0]]],
    #     [[[ 5, 5], [ 6, 5], [ 6, 6], [ 5, 6], [ 5, 5]]],
    #   ]
    class MultiPolygon < Geometry
      TYPE = "MultiPolygon"
      MIN_RING_POINTS = 4

      # @return [Array<Parse::Polygon>] each member polygon as a
      #   {Parse::Polygon} (with axis swap back to Parse's `[lat, lng]`).
      #   Inner rings (holes) are dropped because {Parse::Polygon} does
      #   not support them.
      def polygons
        @coordinates.map do |rings|
          outer = rings.first
          Parse::Polygon.new(outer.map { |(lng, lat)| [lat.to_f, lng.to_f] })
        end
      end

      private

      def normalize(value)
        raise ArgumentError, "[Parse::GeoJSON::MultiPolygon] coordinates must be an Array." unless value.is_a?(Array)
        value.map do |polygon|
          unless polygon.is_a?(Array)
            raise ArgumentError, "[Parse::GeoJSON::MultiPolygon] each polygon must be an Array of rings."
          end
          polygon.map do |ring|
            unless ring.is_a?(Array)
              raise ArgumentError, "[Parse::GeoJSON::MultiPolygon] each ring must be an Array of [lng, lat] pairs."
            end
            ring.map do |pair|
              unless pair.is_a?(Array) && pair.length == 2 &&
                     pair[0].is_a?(Numeric) && pair[1].is_a?(Numeric)
                raise ArgumentError, "[Parse::GeoJSON::MultiPolygon] each coordinate must be a [lng, lat] numeric pair."
              end
              # Reject NaN / Infinity; see LineString#finite_lnglat!
              # for the same rationale.
              lng = pair[0].to_f
              lat = pair[1].to_f
              unless lng.finite? && lat.finite?
                raise ArgumentError, "[Parse::GeoJSON::MultiPolygon] coordinates must be finite " \
                                     "numerics; got [#{lng}, #{lat}]."
              end
              [lng, lat]
            end
          end
        end
      end

      def validate!
        @coordinates.each_with_index do |polygon, i|
          polygon.each_with_index do |ring, j|
            next if ring.empty?
            if ring.length < MIN_RING_POINTS
              warn "[Parse::GeoJSON::MultiPolygon] polygon[#{i}].ring[#{j}] has #{ring.length} points; " \
                   "GeoJSON requires at least #{MIN_RING_POINTS}."
            elsif ring.first != ring.last
              warn "[Parse::GeoJSON::MultiPolygon] polygon[#{i}].ring[#{j}] is not closed (first != last)."
            end
          end
        end
      end
    end

    # Dispatch table for {Geometry.from_geojson}. Kept here at the end so
    # subclasses are registered after their constants are defined.
    Geometry::TYPE_REGISTRY = {
      "LineString" => LineString,
      "MultiPolygon" => MultiPolygon,
    }.freeze
  end
end
