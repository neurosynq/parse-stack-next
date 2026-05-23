# encoding: UTF-8
# frozen_string_literal: true

require_relative "model"
require_relative "geopoint"

module Parse

  # This class manages the Polygon data type that Parse Server provides to
  # store geographic shapes. To define a Polygon property, use the `:polygon`
  # data type. A polygon must contain at least three distinct vertices.
  # Each coordinate pair is in `[latitude, longitude]` order (Parse-style),
  # matching {Parse::GeoPoint} and the Parse REST wire format.
  #
  # @example
  #   class Region < Parse::Object
  #     property :area, :polygon
  #   end
  #
  #   # Three accepted constructor forms
  #   triangle = Parse::Polygon.new [[0, 0], [0, 1], [1, 0]]
  #   triangle = Parse::Polygon.new [
  #     Parse::GeoPoint.new(0, 0),
  #     Parse::GeoPoint.new(0, 1),
  #     Parse::GeoPoint.new(1, 0),
  #   ]
  #   copy = Parse::Polygon.new(triangle)
  #
  #   region = Region.new
  #   region.area = triangle
  #   region.save
  #
  # The ring is not auto-closed by this class; Parse Server will close it
  # on persist. Equality (`==`) is element-wise, so an open ring and the
  # same ring with its first point repeated at the end compare as different.
  class Polygon < Model
    include Enumerable

    # The default attributes in a Parse Polygon hash. The values are type
    # hints used by the serializer; the keys are the serialized field names.
    ATTRIBUTES = { __type: :string, coordinates: :array }.freeze

    # The minimum number of distinct vertices required by Parse Server.
    MIN_VERTICES = 3

    # @return [Parse::Model::TYPE_POLYGON]
    def self.parse_class; TYPE_POLYGON; end
    # @return [Parse::Model::TYPE_POLYGON]
    def parse_class; self.class.parse_class; end

    alias_method :__type, :parse_class

    # @return [Array<Array<Float>>] the polygon ring as an array of [lat, lng] pairs.
    attr_reader :coordinates

    # The initializer accepts an array of [lat, lng] pairs, an array of
    # {Parse::GeoPoint} objects, or another {Parse::Polygon}.
    # @example
    #   Parse::Polygon.new [[0, 0], [0, 1], [1, 0]]
    #   Parse::Polygon.new [Parse::GeoPoint.new(0, 0), Parse::GeoPoint.new(0, 1), Parse::GeoPoint.new(1, 0)]
    #   Parse::Polygon.new(other_polygon)
    #
    # @param value [Array, Parse::Polygon, Hash] the polygon coordinates.
    def initialize(value = nil)
      @coordinates = []
      self.coordinates = value unless value.nil?
    end

    # Convenience factory accepting vertices as positional arguments.
    # Each argument may be a {Parse::GeoPoint} or a `[lat, lng]` pair.
    # @example
    #   Parse::Polygon.from_points([0, 0], [0, 1], [1, 0])
    #   Parse::Polygon.from_points(gp1, gp2, gp3)
    # @return [Parse::Polygon]
    def self.from_points(*points)
      new(points)
    end

    # Build a {Parse::Polygon} from a GeoJSON `Polygon` geometry object.
    # GeoJSON uses `[longitude, latitude]` axis order and wraps the ring
    # one level deeper than Parse's wire format; this method performs both
    # transformations. Accepts a closed or open outer ring; the closing
    # vertex (when present and equal to the first) is preserved.
    # Only the outer ring is consumed — GeoJSON inner rings (holes) are
    # silently dropped because Parse Server's Polygon type does not
    # support holes.
    # @example
    #   Parse::Polygon.from_geojson("type" => "Polygon", "coordinates" => [[[-117.6, 32.8], [-117.5, 32.8], [-117.5, 32.9], [-117.6, 32.8]]])
    # @param geojson [Hash] a GeoJSON Polygon geometry object.
    # @return [Parse::Polygon]
    # @raise [ArgumentError] if the input is not a valid GeoJSON Polygon.
    def self.from_geojson(geojson)
      raise ArgumentError, "[Parse::Polygon] from_geojson expects a Hash." unless geojson.is_a?(Hash)
      hash = geojson.respond_to?(:symbolize_keys) ? geojson.symbolize_keys : geojson
      type = hash[:type] || hash["type"]
      rings = hash[:coordinates] || hash["coordinates"]
      unless type.to_s == "Polygon" && rings.is_a?(Array) && rings.first.is_a?(Array)
        raise ArgumentError, "[Parse::Polygon] from_geojson expects a GeoJSON Polygon with a nested coordinates array."
      end
      outer = rings.first
      pairs = outer.map do |(lng, lat)|
        raise ArgumentError, "[Parse::Polygon] GeoJSON ring entries must be [lng, lat] numeric pairs." \
          unless lng.is_a?(Numeric) && lat.is_a?(Numeric)
        [lat.to_f, lng.to_f]
      end
      new(pairs)
    end

    # Deep-copy the internal coordinate array so `dup` / `clone` produce a
    # polygon whose mutation does not affect the original.
    # @!visibility private
    def initialize_copy(other)
      super
      @coordinates = other.coordinates.map(&:dup)
    end

    # Set the polygon coordinates. Accepts:
    # - an Array of [lat, lng] pairs
    # - an Array of {Parse::GeoPoint} objects
    # - a Hash with a `coordinates` key (the Parse REST wire shape)
    # - another {Parse::Polygon}
    def coordinates=(value)
      coords =
        case value
        when Parse::Polygon
          # Duplicate so external mutation of the source doesn't leak in.
          value.coordinates.map { |pair| pair.dup }
        when Hash
          hash = value.respond_to?(:symbolize_keys) ? value.symbolize_keys : value
          normalize_array(hash[:coordinates] || hash["coordinates"] || [])
        when Array
          normalize_array(value)
        else
          raise ArgumentError, "[Parse::Polygon] Cannot build polygon from #{value.class}: " \
                               "expected Array of [lat,lng] pairs, Array of Parse::GeoPoint, or Parse::Polygon."
        end

      @coordinates = coords
      _validate
      @coordinates
    end

    # @return [Hash] the attribute hint hash used by the JSON serializer.
    def attributes
      ATTRIBUTES
    end

    # @return [Array<Array<Float>>] the coordinates in `[[lat, lng], ...]` form.
    def to_a
      @coordinates.map(&:dup)
    end

    # @return [Hash] the Parse REST wire representation of this polygon.
    def as_json(*_args)
      { __type: parse_class, coordinates: @coordinates.map(&:dup) }
    end

    # @return [Array<Parse::GeoPoint>] the vertices as GeoPoint objects.
    def geo_points
      @coordinates.map { |(lat, lng)| Parse::GeoPoint.new(lat, lng) }
    end

    # Yield each vertex as a {Parse::GeoPoint}. Including {Enumerable} gives
    # `map`, `select`, `to_a`, etc. for free.
    # @yieldparam point [Parse::GeoPoint]
    # @return [Enumerator] if no block is given.
    def each(&block)
      return enum_for(:each) unless block_given?
      @coordinates.each { |(lat, lng)| yield Parse::GeoPoint.new(lat, lng) }
      self
    end

    # The axis-aligned bounding box of the polygon as `[[min_lat, min_lng],
    # [max_lat, max_lng]]`. Returns `nil` for an empty polygon.
    # @return [Array<Array<Float>>, nil]
    def bounds
      return nil if @coordinates.empty?
      lats = @coordinates.map(&:first)
      lngs = @coordinates.map(&:last)
      [[lats.min, lngs.min], [lats.max, lngs.max]]
    end

    # Planar area in degrees-squared, computed via the shoelace formula. This
    # is a Cartesian approximation and is useful for relative comparison only.
    # For surface-area in square meters use a proper geodesic library.
    # @return [Float] non-negative planar area.
    def area
      return 0.0 if @coordinates.length < MIN_VERTICES
      sum = 0.0
      n = @coordinates.length
      n.times do |i|
        lat_i, lng_i = @coordinates[i]
        lat_j, lng_j = @coordinates[(i + 1) % n]
        sum += (lng_i * lat_j) - (lng_j * lat_i)
      end
      (sum.abs / 2.0)
    end

    # Shoelace-weighted polygon centroid in `[lat, lng]` form. Falls back to
    # the vertex average when the polygon has zero area (e.g. a degenerate
    # ring of collinear points). Returns `nil` for an empty polygon.
    # @return [Array<Float>, nil]
    def centroid
      return nil if @coordinates.empty?
      n = @coordinates.length
      return @coordinates.first.dup if n == 1

      sum_a = 0.0
      sum_lat = 0.0
      sum_lng = 0.0
      n.times do |i|
        lat_i, lng_i = @coordinates[i]
        lat_j, lng_j = @coordinates[(i + 1) % n]
        cross = (lng_i * lat_j) - (lng_j * lat_i)
        sum_a += cross
        sum_lat += (lat_i + lat_j) * cross
        sum_lng += (lng_i + lng_j) * cross
      end

      if sum_a.abs < 1e-12
        # Degenerate ring — fall back to vertex average so callers always
        # get a usable point.
        lat = @coordinates.map(&:first).sum / n
        lng = @coordinates.map(&:last).sum / n
        return [lat, lng]
      end

      factor = 1.0 / (3.0 * sum_a)
      [sum_lat * factor, sum_lng * factor]
    end

    # GeoJSON (RFC 7946) representation of this polygon. GeoJSON requires
    # `[longitude, latitude]` axis order (the inverse of Parse) and a closed
    # ring nested one level deeper than Parse's wire format. This method
    # performs both transformations so the result drops directly into
    # Leaflet, Mapbox, PostGIS, and other standard GIS tools.
    # @example
    #   polygon.to_geojson
    #   # => {"type" => "Polygon", "coordinates" => [[[lng, lat], [lng, lat], ...]]}
    # @return [Hash] a GeoJSON `Polygon` geometry object.
    def to_geojson
      ring = @coordinates.map { |(lat, lng)| [lng, lat] }
      # GeoJSON requires the ring to be explicitly closed.
      ring << ring.first.dup if !ring.empty? && ring.first != ring.last
      { "type" => "Polygon", "coordinates" => [ring] }
    end

    # Well-Known Text representation (`POLYGON((lng lat, lng lat, ...))`).
    # The output uses `longitude latitude` axis order — matching the OGC
    # WKT spec — and includes the closing vertex if not already present.
    # @return [String] the WKT string, suitable for PostGIS `ST_GeomFromText`.
    def to_wkt
      return "POLYGON EMPTY" if @coordinates.empty?
      ring = @coordinates.map { |(lat, lng)| [lng, lat] }
      ring << ring.first.dup if ring.first != ring.last
      "POLYGON((#{ring.map { |(lng, lat)| "#{lng} #{lat}" }.join(", ")}))"
    end

    # Element-wise equality. Two polygons are equal if their coordinate
    # arrays match exactly. An open ring and its closed form are NOT equal,
    # matching the JS SDK.
    def ==(other)
      return false unless other.is_a?(Parse::Polygon)
      @coordinates == other.coordinates
    end

    # Client-side ray-casting point-in-polygon test. Mirrors
    # `Parse.Polygon#containsPoint` in the JS SDK. Boundary behavior is
    # not guaranteed (a point exactly on an edge may return either result).
    # @param point [Parse::GeoPoint, Array<Numeric>] the point to test.
    # @return [Boolean]
    def contains_point?(point)
      lat, lng =
        case point
        when Parse::GeoPoint then [point.latitude, point.longitude]
        when Array then [point[0].to_f, point[1].to_f]
        else
          raise ArgumentError, "[Parse::Polygon] contains_point? expects a Parse::GeoPoint or [lat,lng] Array."
        end

      ring = @coordinates
      return false if ring.size < MIN_VERTICES

      inside = false
      j = ring.size - 1
      (0...ring.size).each do |i|
        lat_i, lng_i = ring[i]
        lat_j, lng_j = ring[j]
        intersect = ((lng_i > lng) != (lng_j > lng)) &&
                    (lat < (lat_j - lat_i) * (lng - lng_i) / ((lng_j - lng_i).nonzero? || 1e-12) + lat_i)
        inside = !inside if intersect
        j = i
      end
      inside
    end

    # Returns `true` when the outer ring is wound counter-clockwise
    # (as required by RFC 7946 / GeoJSON for exterior rings, and by
    # MongoDB 8+ / Atlas for polygons used in `$geoWithin` and
    # `$geoIntersects` against `2dsphere` indexes). Uses the shoelace
    # signed-area test with longitude on the x-axis and latitude on the
    # y-axis. Degenerate rings (fewer than {MIN_VERTICES} vertices)
    # return `true` because winding is undefined.
    # @return [Boolean]
    def counter_clockwise?
      n = @coordinates.length
      return true if n < MIN_VERTICES
      sum = 0.0
      n.times do |i|
        lat_i, lng_i = @coordinates[i]
        lat_j, lng_j = @coordinates[(i + 1) % n]
        sum += (lng_i * lat_j) - (lng_j * lat_i)
      end
      sum > 0
    end

    # Reverses the coordinate ring in place if it is currently wound
    # clockwise so the polygon satisfies the RFC 7946 / MongoDB 8+
    # counter-clockwise outer-ring requirement. Returns `self` so calls
    # chain. Idempotent: calling on an already-CCW polygon is a no-op.
    # @return [Parse::Polygon]
    def ensure_counter_clockwise!
      @coordinates.reverse! unless counter_clockwise?
      self
    end

    # @!visibility private
    def inspect
      "#<Polygon #{@coordinates.inspect}>"
    end

    private

    # @!visibility private
    def normalize_array(array)
      raise ArgumentError, "[Parse::Polygon] coordinates must be an Array" unless array.is_a?(Array)

      array.map do |entry|
        case entry
        when Parse::GeoPoint
          finite_pair!(entry.latitude.to_f, entry.longitude.to_f)
        when Array
          unless entry.length == 2 && entry[0].is_a?(Numeric) && entry[1].is_a?(Numeric)
            raise ArgumentError, "[Parse::Polygon] each coordinate must be a 2-element [lat,lng] numeric pair."
          end
          finite_pair!(entry[0].to_f, entry[1].to_f)
        when Hash
          hash = entry.respond_to?(:symbolize_keys) ? entry.symbolize_keys : entry
          lat = hash[:latitude] || hash[:lat] || hash["latitude"] || hash["lat"]
          lng = hash[:longitude] || hash[:lng] || hash["longitude"] || hash["lng"]
          raise ArgumentError, "[Parse::Polygon] coordinate hash needs latitude/longitude." if lat.nil? || lng.nil?
          unless lat.is_a?(Numeric) && lng.is_a?(Numeric)
            raise ArgumentError, "[Parse::Polygon] coordinate hash latitude/longitude must be numeric."
          end
          finite_pair!(lat.to_f, lng.to_f)
        else
          raise ArgumentError, "[Parse::Polygon] unsupported coordinate entry #{entry.inspect}."
        end
      end
    end

    # @!visibility private
    # Reject NaN / Infinity at the door. `Float::NAN.is_a?(Numeric)` is
    # true (`NaN.between?(...)` returns false silently) so the earlier
    # type check is insufficient — a polygon containing NaN gets accepted
    # and then errors mid-pipeline when MongoDB tries to build the
    # `2dsphere` index, cascading transaction-level failures.
    def finite_pair!(lat, lng)
      unless lat.finite? && lng.finite?
        raise ArgumentError, "[Parse::Polygon] coordinates must be finite numerics; got [#{lat}, #{lng}]."
      end
      [lat, lng]
    end

    # @!visibility private
    def _validate
      distinct = @coordinates.uniq
      if distinct.length < MIN_VERTICES
        warn "[Parse::Polygon] Polygon has #{distinct.length} distinct vertices; Parse Server requires at least #{MIN_VERTICES}."
      end

      # TRACK-QUERY-5: out-of-range lat/lng previously warned; now
      # raises. MongoDB's `2dsphere` index rejects polygons with lat
      # outside [-90, 90] or lng outside [-180, 180] at index-rebuild
      # time; failing fast at construction prevents a tenant-wide
      # write failure later.
      @coordinates.each do |(lat, lng)|
        unless lat.nil? || lat.between?(Parse::GeoPoint::LAT_MIN, Parse::GeoPoint::LAT_MAX)
          raise ArgumentError, "[Parse::Polygon] Latitude (#{lat}) is not between " \
                               "#{Parse::GeoPoint::LAT_MIN} and #{Parse::GeoPoint::LAT_MAX}."
        end
        unless lng.nil? || lng.between?(Parse::GeoPoint::LNG_MIN, Parse::GeoPoint::LNG_MAX)
          raise ArgumentError, "[Parse::Polygon] Longitude (#{lng}) is not between " \
                               "#{Parse::GeoPoint::LNG_MIN} and #{Parse::GeoPoint::LNG_MAX}."
        end
      end

      if @coordinates.length >= MIN_VERTICES && !counter_clockwise?
        warn "[Parse::Polygon] Outer ring is wound clockwise. MongoDB 8+ and " \
             "Atlas reject CW outer rings for 2dsphere $geoWithin/$geoIntersects " \
             "queries; call #ensure_counter_clockwise! before persisting or " \
             "querying against a 2dsphere index."
      end
    end
  end
end
