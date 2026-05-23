# encoding: UTF-8
# frozen_string_literal: true

require_relative "model"

module Parse

  # This class manages the GeoPoint data type that Parse provides to support
  # geo-queries. To define a GeoPoint property, use the `:geopoint` data type.
  # Please note that latitudes should not be between -90.0 and 90.0, and
  # longitudes should be between -180.0 and 180.0.
  # @example
  #   class PlaceObject < Parse::Object
  #     property :location, :geopoint
  #   end
  #
  #   san_diego = Parse::GeoPoint.new(32.8233, -117.6542)
  #   los_angeles = Parse::GeoPoint.new [34.0192341, -118.970792]
  #   san_diego == los_angeles # false
  #
  #   place = PlaceObject.new
  #   place.location = san_diego
  #   place.save
  #
  class GeoPoint < Model
    # The default attributes in a Parse GeoPoint hash.
    ATTRIBUTES = { __type: :string, latitude: :float, longitude: :float }.freeze

    # @return [Float] latitude value between -90.0 and 90.0
    attr_reader :latitude
    # @return [Float] longitude value between -180.0 and 180.0
    attr_reader :longitude
    # The key field for latitude
    FIELD_LAT = "latitude".freeze
    # The key field for longitude
    FIELD_LNG = "longitude".freeze

    # The minimum latitude value.
    LAT_MIN = -90.0
    # The maximum latitude value.
    LAT_MAX = 90.0
    # The minimum longitude value.
    LNG_MIN = -180.0
    # The maximum longitude value.
    LNG_MAX = 180.0

    alias_method :lat, :latitude
    alias_method :lng, :longitude
    # @return [Model::TYPE_GEOPOINT]
    def self.parse_class; TYPE_GEOPOINT; end
    # @return [Model::TYPE_GEOPOINT]
    def parse_class; self.class.parse_class; end

    alias_method :__type, :parse_class

    # The initializer can create a GeoPoint with a hash, array or values.
    # @example
    #  san_diego = Parse::GeoPoint.new(32.8233, -117.6542)
    #  san_diego = Parse::GeoPoint.new [32.8233, -117.6542]
    #  san_diego = Parse::GeoPoint.new { latitude: 32.8233, longitude: -117.6542}
    #
    # @param latitude [Numeric] The latitude value between LAT_MIN and LAT_MAX.
    # @param longitude [Numeric] The longitude value between LNG_MIN and LNG_MAX.
    def initialize(latitude = nil, longitude = nil)
      @latitude = @longitude = 0.0
      if latitude.is_a?(Hash) || latitude.is_a?(Array)
        self.attributes = latitude
      elsif latitude.is_a?(Numeric) && longitude.is_a?(Numeric)
        @latitude = latitude
        @longitude = longitude
      elsif latitude.is_a?(GeoPoint)
        @latitude = latitude.latitude
        @longitude = latitude.longitude
      end

      _validate_point
    end

    # @!visibility private
    def _validate_point
      unless @latitude.nil? || @latitude.between?(LAT_MIN, LAT_MAX)
        warn "[Parse::GeoPoint] Latitude (#{@latitude}) is not between #{LAT_MIN}, #{LAT_MAX}!"
        warn "Attempting to use GeoPoint’s with latitudes outside these ranges will raise an exception in a future release."
      end

      unless @longitude.nil? || @longitude.between?(LNG_MIN, LNG_MAX)
        warn "[Parse::GeoPoint] Longitude (#{@longitude}) is not between #{LNG_MIN}, #{LNG_MAX}!"
        warn "Attempting to use GeoPoint’s with longitude outside these ranges will raise an exception in a future release."
      end
    end

    # @return [Hash] attributes for a Parse GeoPoint.
    def attributes
      ATTRIBUTES
    end

    # Helper method for performing geo-queries with radial miles constraints
    # @return [Array] containing [lat,lng,miles]
    def max_miles(m)
      m = 0 if m.nil?
      [@latitude, @longitude, m]
    end

    # Helper method for performing geo-queries with a radial kilometer
    # constraint. Used with `:field.near => gp.max_kilometers(N)` to compile
    # a `$nearSphere` + `$maxDistanceInKilometers` query against Parse Server.
    # @return [Array] containing `[lat, lng, kilometers, :km]`
    def max_kilometers(km)
      km = 0 if km.nil?
      [@latitude, @longitude, km, :km]
    end
    alias_method :max_km, :max_kilometers

    # Helper method for performing geo-queries with a radial radians
    # constraint. Used with `:field.near => gp.max_radians(R)` to compile
    # a `$nearSphere` + `$maxDistance` query against Parse Server (raw
    # `$maxDistance` is measured in radians). Convert from miles/km by
    # dividing by mean-Earth-radius (~3958.8 miles or ~6371 km).
    # @return [Array] containing `[lat, lng, radians, :radians]`
    def max_radians(rad)
      rad = 0 if rad.nil?
      [@latitude, @longitude, rad, :radians]
    end

    def latitude=(l)
      @latitude = l
      _validate_point
    end

    def longitude=(l)
      @longitude = l
      _validate_point
    end

    # Setting lat and lng for an GeoPoint can be done using a hash with the attributes set
    # or with an array of two items where the first is the lat and the second is the lng (ex. [32.22,-118.81])
    def attributes=(h)
      if h.is_a?(Hash)
        h = h.symbolize_keys
        @latitude = h[:latitude].to_f || h[:lat].to_f || @latitude
        @longitude = h[:longitude].to_f || h[:lng].to_f || @longitude
      elsif h.is_a?(Array) && h.count == 2
        @latitude = h.first.to_f
        @longitude = h.last.to_f
      end
      _validate_point
    end

    # @return [Boolean] true if two geopoints are equal based on lat and lng.
    def ==(g)
      return false unless g.is_a?(GeoPoint)
      @latitude == g.latitude && @longitude == g.longitude
    end

    # Helper method for reducing the precision of a geopoint.
    # @param precision [Integer] The number of floating digits to keep.
    # @return [GeoPoint] Reduces the precision of a geopoint.
    def estimated(precision = 2)
      Parse::GeoPoint.new(@latitude.to_f.round(precision), @longitude.round(precision))
    end

    # Returns a tuple containing latitude and longitude
    # @return [Array]
    def to_a
      [@latitude, @longitude]
    end

    # GeoJSON (RFC 7946) representation of this point. GeoJSON requires
    # `[longitude, latitude]` axis order — the inverse of Parse's wire
    # format — so this method performs the swap. Useful when handing the
    # value to Leaflet/Mapbox/PostGIS, or when constructing literals for
    # MongoDB-direct geo queries (which use GeoJSON internally).
    # @example
    #   geopoint.to_geojson
    #   # => {"type" => "Point", "coordinates" => [-117.6542, 32.8233]}
    # @return [Hash] a GeoJSON `Point` geometry object.
    def to_geojson
      { "type" => "Point", "coordinates" => [@longitude, @latitude] }
    end

    # Build a {Parse::GeoPoint} from a GeoJSON `Point` geometry object.
    # Accepts either symbol or string keys and the standard
    # `[longitude, latitude]` axis order; performs the swap to Parse's
    # `[latitude, longitude]` internal storage.
    # @example
    #   Parse::GeoPoint.from_geojson("type" => "Point", "coordinates" => [-117.6542, 32.8233])
    # @param geojson [Hash] a GeoJSON Point geometry object.
    # @return [Parse::GeoPoint]
    # @raise [ArgumentError] if the input is not a valid GeoJSON Point.
    def self.from_geojson(geojson)
      raise ArgumentError, "[Parse::GeoPoint] from_geojson expects a Hash." unless geojson.is_a?(Hash)
      hash = geojson.respond_to?(:symbolize_keys) ? geojson.symbolize_keys : geojson
      type = hash[:type] || hash["type"]
      coords = hash[:coordinates] || hash["coordinates"]
      # Mirror Parse::Polygon.from_geojson: require both coordinates to
      # be finite Numerics. Without this check, non-numeric entries
      # (`"evil"`, `{"$where": "..."}`, `nil`) silently coerce to 0.0
      # via `.to_f`, producing a null-island point that matches
      # ACL-relevant proximity queries unintentionally. NaN / Infinity
      # similarly produce silent geo bugs and 2dsphere index errors.
      unless type.to_s == "Point" && coords.is_a?(Array) && coords.length == 2 &&
             coords[0].is_a?(Numeric) && coords[1].is_a?(Numeric) &&
             coords[0].finite? && coords[1].finite?
        raise ArgumentError, "[Parse::GeoPoint] from_geojson expects a GeoJSON Point with " \
                             "two finite numeric coordinates."
      end
      Parse::GeoPoint.new(coords[1].to_f, coords[0].to_f)
    end

    # @!visibility private
    def inspect
      "#<GeoPoint [#{@latitude},#{@longitude}]>"
    end

    # Calculate the distance in miles to another GeoPoint using Haversine.
    # You may also call this method with a latitude and longitude.
    # @example
    #   point.distance_in_miles(geotpoint)
    #   point.distance_in_miles(lat, lng)
    #
    # @param geopoint [GeoPoint]
    # @param lng [Float] Longitude assuming that the first parameter
    # is longitude instead of a GeoPoint.
    # @return [Float] number of miles between geopoints.
    # @see #distance_in_km
    def distance_in_miles(geopoint, lng = nil)
      distance_in_km(geopoint, lng) * 0.621371
    end

    # Calculate the distance in kilometers to another GeoPoint using Haversine
    # method. You may also call this method with a latitude and longitude.
    # @example
    #   point.distance_in_km(geotpoint)
    #   point.distance_in_km(lat, lng)
    #
    # @param geopoint [GeoPoint]
    # @param lng [Float] Longitude assuming that the first parameter is a latitude instead of a GeoPoint.
    # @return [Float] number of miles between geopoints.
    # @see #distance_in_miles
    def distance_in_km(geopoint, lng = nil)
      unless geopoint.is_a?(Parse::GeoPoint)
        geopoint = Parse::GeoPoint.new(geopoint, lng)
      end

      dtor = Math::PI / 180
      r = 6378.14
      r_lat1 = self.latitude * dtor
      r_lng1 = self.longitude * dtor
      r_lat2 = geopoint.latitude * dtor
      r_lng2 = geopoint.longitude * dtor

      delta_lat = r_lat1 - r_lat2
      delta_lng = r_lng1 - r_lng2

      a = (Math::sin(delta_lat / 2.0) ** 2).to_f + (Math::cos(r_lat1) * Math::cos(r_lat2) * (Math::sin(delta_lng / 2.0) ** 2))
      c = 2.0 * Math::atan2(Math::sqrt(a), Math::sqrt(1.0 - a))
      d = r * c
      d
    end
  end
end
