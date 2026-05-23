require_relative "../../../test_helper"

class PolygonRoundTripModel < Parse::Object
  parse_class "PolygonRoundTrip"
  property :area, :polygon
end

class TestPolygon < Minitest::Test
  TRIANGLE = [[0.0, 0.0], [0.0, 1.0], [1.0, 0.0]].freeze
  BERMUDA = [[32.3078, -64.7505], [25.7823, -80.2660], [18.3848, -66.0934]].freeze

  def setup
    @triangle = Parse::Polygon.new(TRIANGLE.map(&:dup))
    @bermuda = Parse::Polygon.new(BERMUDA.map(&:dup))
  end

  def test_constants
    assert_equal Parse::Polygon::MIN_VERTICES, 3
    assert_equal Parse::Polygon.parse_class, "Polygon"
    assert_equal @triangle.parse_class, "Polygon"
    assert_instance_of Parse::Polygon, @triangle
  end

  def test_initializer_from_array_of_pairs
    poly = Parse::Polygon.new(TRIANGLE.map(&:dup))
    assert_equal poly.coordinates, TRIANGLE.map(&:dup)
  end

  def test_initializer_from_array_of_geopoints
    points = [
      Parse::GeoPoint.new(0, 0),
      Parse::GeoPoint.new(0, 1),
      Parse::GeoPoint.new(1, 0),
    ]
    poly = Parse::Polygon.new(points)
    assert_equal poly.coordinates, TRIANGLE.map(&:dup)
  end

  def test_initializer_from_polygon
    copy = Parse::Polygon.new(@triangle)
    assert_equal copy, @triangle
    refute_same copy.coordinates, @triangle.coordinates
  end

  def test_initializer_from_wire_hash
    poly = Parse::Polygon.new(__type: "Polygon", coordinates: TRIANGLE.map(&:dup))
    assert_equal poly.coordinates, TRIANGLE.map(&:dup)
  end

  def test_initializer_empty
    poly = Parse::Polygon.new
    assert_equal poly.coordinates, []
  end

  def test_rejects_non_pair_entry
    assert_raises(ArgumentError) { Parse::Polygon.new([[0, 0], [1], [2, 2]]) }
    assert_raises(ArgumentError) { Parse::Polygon.new([[0, 0], "bad", [2, 2]]) }
  end

  def test_rejects_unsupported_root
    assert_raises(ArgumentError) { Parse::Polygon.new("string") }
  end

  def test_equality_element_wise
    same = Parse::Polygon.new(TRIANGLE.map(&:dup))
    assert_equal same, @triangle

    closed = Parse::Polygon.new(TRIANGLE.map(&:dup) + [TRIANGLE.first.dup])
    refute_equal closed, @triangle
  end

  def test_to_a
    assert_equal @triangle.to_a, TRIANGLE.map(&:dup)
    refute_same @triangle.to_a, @triangle.coordinates
  end

  def test_as_json_wire_format
    json = @bermuda.as_json
    assert_equal json[:__type], "Polygon"
    assert_equal json[:coordinates], BERMUDA.map(&:dup)
  end

  def test_attribute_definitions
    att = @triangle.attributes
    assert_equal att[:__type], :string
    assert_equal att[:coordinates], :array
  end

  def test_geo_points
    points = @triangle.geo_points
    assert_equal points.length, 3
    assert(points.all? { |p| p.is_a?(Parse::GeoPoint) })
    assert_equal points.first.latitude, 0.0
  end

  def test_contains_point_inside
    poly = Parse::Polygon.new [[0.0, 0.0], [0.0, 10.0], [10.0, 10.0], [10.0, 0.0]]
    assert poly.contains_point?(Parse::GeoPoint.new(5.0, 5.0))
    assert poly.contains_point?([5.0, 5.0])
  end

  def test_contains_point_outside
    poly = Parse::Polygon.new [[0.0, 0.0], [0.0, 10.0], [10.0, 10.0], [10.0, 0.0]]
    refute poly.contains_point?(Parse::GeoPoint.new(20.0, 20.0))
  end

  def test_contains_point_invalid_arg
    assert_raises(ArgumentError) { @triangle.contains_point?("not a point") }
  end

  def test_warns_below_min_vertices
    out, _err = capture_io do
      Parse::Polygon.new [[0.0, 0.0], [1.0, 1.0]]
    end
    # Warnings go to $stderr via Kernel#warn, captured by capture_io
    assert_match(/distinct vertices/, _err)
  end

  def test_property_round_trip_through_format_value
    instance = PolygonRoundTripModel.new
    instance.area = TRIANGLE.map(&:dup)
    assert_instance_of Parse::Polygon, instance.area
    assert_equal instance.area.coordinates, TRIANGLE.map(&:dup)
  end

  def test_property_accepts_wire_hash
    instance = PolygonRoundTripModel.new
    instance.area = { "__type" => "Polygon", "coordinates" => TRIANGLE.map(&:dup) }
    assert_instance_of Parse::Polygon, instance.area
    assert_equal instance.area.coordinates, TRIANGLE.map(&:dup)
  end

  def test_find_class_dispatch
    assert_equal Parse::Model.find_class("Polygon"), Parse::Polygon
  end

  def test_schema_field_type
    field = PolygonRoundTripModel.schema[:fields][:area]
    assert_equal field[:type], "Polygon"
  end

  def test_dup_deep_copies_coordinates
    copy = @triangle.dup
    copy.coordinates.first[0] = 99.0
    refute_equal copy.coordinates.first[0], @triangle.coordinates.first[0],
                 "dup must not share the inner coordinates array"
  end

  def test_clone_deep_copies_coordinates
    copy = @triangle.clone
    copy.coordinates.first[0] = 99.0
    refute_equal copy.coordinates.first[0], @triangle.coordinates.first[0]
  end

  def test_from_points_class_method
    poly = Parse::Polygon.from_points([0, 0], [0, 1], [1, 0])
    assert_equal poly.coordinates, TRIANGLE
  end

  def test_from_points_with_geopoints
    poly = Parse::Polygon.from_points(
      Parse::GeoPoint.new(0, 0),
      Parse::GeoPoint.new(0, 1),
      Parse::GeoPoint.new(1, 0),
    )
    assert_equal poly.coordinates, TRIANGLE
  end

  def test_enumerable_each_yields_geopoints
    # Polygon#to_a (defined on the class) still returns [[lat,lng]...] pairs.
    # Enumerable#each yields Parse::GeoPoint objects; use #entries or
    # an explicit block to access them.
    points = @triangle.entries
    assert_equal points.length, 3
    assert(points.all? { |p| p.is_a?(Parse::GeoPoint) })
  end

  def test_enumerable_map
    lats = @triangle.map(&:latitude)
    assert_equal lats, [0.0, 0.0, 1.0]
  end

  def test_bounds
    poly = Parse::Polygon.new [[0.0, 0.0], [2.0, 5.0], [-1.0, 3.0]]
    assert_equal poly.bounds, [[-1.0, 0.0], [2.0, 5.0]]
  end

  def test_bounds_empty
    assert_nil Parse::Polygon.new.bounds
  end

  def test_area_unit_square
    unit_square = Parse::Polygon.new [[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0]]
    assert_in_delta unit_square.area, 1.0, 1e-9
  end

  def test_area_triangle
    triangle = Parse::Polygon.new [[0.0, 0.0], [0.0, 2.0], [2.0, 0.0]]
    assert_in_delta triangle.area, 2.0, 1e-9
  end

  def test_area_empty_polygon
    assert_equal Parse::Polygon.new.area, 0.0
  end

  def test_centroid_of_unit_square
    unit_square = Parse::Polygon.new [[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0]]
    lat, lng = unit_square.centroid
    assert_in_delta lat, 0.5, 1e-9
    assert_in_delta lng, 0.5, 1e-9
  end

  def test_centroid_degenerate_polygon_falls_back_to_average
    # Collinear points have zero area; centroid should fall back to average.
    line = Parse::Polygon.new [[0.0, 0.0], [0.0, 1.0], [0.0, 2.0]]
    lat, lng = line.centroid
    assert_in_delta lat, 0.0, 1e-9
    assert_in_delta lng, 1.0, 1e-9
  end

  def test_centroid_empty
    assert_nil Parse::Polygon.new.centroid
  end

  def test_to_geojson_axis_swap_and_closure
    poly = Parse::Polygon.new [[0.0, 0.0], [0.0, 1.0], [1.0, 0.0]]
    gj = poly.to_geojson
    assert_equal gj["type"], "Polygon"
    # GeoJSON nests the ring one level deeper.
    ring = gj["coordinates"].first
    # Axis-swapped to [lng, lat].
    assert_equal ring.first, [0.0, 0.0]
    assert_equal ring[1], [1.0, 0.0]
    assert_equal ring[2], [0.0, 1.0]
    # Closed ring — first equals last.
    assert_equal ring.first, ring.last
  end

  def test_to_geojson_preserves_already_closed_ring
    poly = Parse::Polygon.new [[0.0, 0.0], [0.0, 1.0], [1.0, 0.0], [0.0, 0.0]]
    gj = poly.to_geojson
    ring = gj["coordinates"].first
    assert_equal ring.length, 4 # not duplicated
    assert_equal ring.first, ring.last
  end

  def test_to_wkt
    poly = Parse::Polygon.new [[0.0, 0.0], [0.0, 1.0], [1.0, 0.0]]
    wkt = poly.to_wkt
    # Axis-swapped to "lng lat", closing vertex appended.
    assert_equal wkt, "POLYGON((0.0 0.0, 1.0 0.0, 0.0 1.0, 0.0 0.0))"
  end

  def test_to_wkt_empty
    assert_equal Parse::Polygon.new.to_wkt, "POLYGON EMPTY"
  end

  def test_counter_clockwise_for_ccw_ring
    # Standard CCW triangle (lng=x, lat=y): (0,0) → (1,0) → (0,1)
    poly = Parse::Polygon.new [[0.0, 0.0], [0.0, 1.0], [1.0, 0.0]]
    assert poly.counter_clockwise?
  end

  def test_counter_clockwise_false_for_cw_ring
    # Same vertices, reversed: (0,0) → (0,1) → (1,0) — clockwise in (lng=x, lat=y).
    poly = Parse::Polygon.new [[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]]
    refute poly.counter_clockwise?
  end

  def test_counter_clockwise_degenerate
    # Polygons with fewer than 3 vertices have undefined winding;
    # the helper returns true so callers don't reverse degenerate rings.
    assert Parse::Polygon.new([]).counter_clockwise?
    assert Parse::Polygon.new([[0.0, 0.0], [0.0, 1.0]]).counter_clockwise?
  end

  def test_ensure_counter_clockwise_reverses_cw_ring
    poly = Parse::Polygon.new [[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]] # CW
    refute poly.counter_clockwise?
    poly.ensure_counter_clockwise!
    assert poly.counter_clockwise?
    assert_equal poly.coordinates, [[0.0, 1.0], [1.0, 0.0], [0.0, 0.0]]
  end

  def test_ensure_counter_clockwise_idempotent_on_ccw
    poly = Parse::Polygon.new [[0.0, 0.0], [0.0, 1.0], [1.0, 0.0]] # CCW
    original = poly.coordinates.map(&:dup)
    poly.ensure_counter_clockwise!
    assert_equal poly.coordinates, original
  end

  def test_rejects_nan_coordinates
    # TRACK-QUERY-5: Float::NAN.is_a?(Numeric) is true; finite? check is
    # the only thing keeping a polygon with NaN out of a 2dsphere index.
    assert_raises(ArgumentError) do
      Parse::Polygon.new([[Float::NAN, 0.0], [1.0, 0.0], [0.0, 1.0]])
    end
  end

  def test_rejects_infinity_coordinates
    assert_raises(ArgumentError) do
      Parse::Polygon.new([[0.0, Float::INFINITY], [1.0, 0.0], [0.0, 1.0]])
    end
  end

  def test_rejects_lat_out_of_range
    # TRACK-QUERY-5: out-of-range lat/lng previously warned; now raises
    # to prevent index-rebuild failures.
    assert_raises(ArgumentError) do
      Parse::Polygon.new([[91.0, 0.0], [0.0, 0.0], [0.0, 1.0]])
    end
  end

  def test_rejects_lng_out_of_range
    assert_raises(ArgumentError) do
      Parse::Polygon.new([[0.0, 181.0], [1.0, 0.0], [0.0, 1.0]])
    end
  end

  def test_from_geojson_round_trip
    poly = Parse::Polygon.from_geojson(
      "type" => "Polygon",
      "coordinates" => [[[0.0, 0.0], [1.0, 0.0], [0.0, 1.0], [0.0, 0.0]]],
    )
    # GeoJSON axis order is [lng, lat]; Parse stores [lat, lng].
    assert_equal poly.coordinates.first, [0.0, 0.0]
    assert_equal poly.coordinates[1], [0.0, 1.0]
  end
end
