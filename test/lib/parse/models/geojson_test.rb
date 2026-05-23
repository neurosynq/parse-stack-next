require_relative "../../../test_helper"

class TestParseGeoJSON < Minitest::Test
  def test_geopoint_to_geojson_axis_swap
    gp = Parse::GeoPoint.new(32.8233, -117.6542)
    gj = gp.to_geojson
    assert_equal gj["type"], "Point"
    # GeoJSON: [lng, lat]
    assert_equal gj["coordinates"], [-117.6542, 32.8233]
  end

  def test_geopoint_from_geojson_axis_swap
    gp = Parse::GeoPoint.from_geojson("type" => "Point", "coordinates" => [-117.6542, 32.8233])
    assert_instance_of Parse::GeoPoint, gp
    assert_equal gp.latitude, 32.8233
    assert_equal gp.longitude, -117.6542
  end

  def test_geopoint_from_geojson_rejects_wrong_type
    assert_raises(ArgumentError) do
      Parse::GeoPoint.from_geojson("type" => "Polygon", "coordinates" => [[[0, 0], [1, 0], [0, 1], [0, 0]]])
    end
  end

  def test_geopoint_from_geojson_rejects_non_hash
    assert_raises(ArgumentError) { Parse::GeoPoint.from_geojson("not a hash") }
    assert_raises(ArgumentError) { Parse::GeoPoint.from_geojson("type" => "Point") }
  end

  def test_polygon_from_geojson_axis_swap
    gj = { "type" => "Polygon", "coordinates" => [[[-117.6, 32.8], [-117.5, 32.8], [-117.5, 32.9], [-117.6, 32.8]]] }
    poly = Parse::Polygon.from_geojson(gj)
    assert_instance_of Parse::Polygon, poly
    # Parse internal format is [lat, lng] — axis-swapped from GeoJSON.
    assert_equal poly.coordinates.first, [32.8, -117.6]
    assert_equal poly.coordinates[1], [32.8, -117.5]
  end

  def test_polygon_from_geojson_drops_holes
    # GeoJSON polygons can have inner rings (holes); we keep only the outer.
    gj = { "type" => "Polygon", "coordinates" => [
      [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]],
      [[3, 3], [5, 3], [5, 5], [3, 3]], # hole
    ] }
    poly = Parse::Polygon.from_geojson(gj)
    assert_equal poly.coordinates.length, 5 # only outer ring
  end

  def test_polygon_from_geojson_rejects_wrong_type
    assert_raises(ArgumentError) { Parse::Polygon.from_geojson("type" => "Point", "coordinates" => [0, 0]) }
  end

  def test_round_trip_geopoint
    gp = Parse::GeoPoint.new(32.8233, -117.6542)
    decoded = Parse::GeoPoint.from_geojson(gp.to_geojson)
    assert_equal decoded, gp
  end

  def test_round_trip_polygon_closes_ring
    # GeoJSON requires closed rings, so to_geojson appends the closing
    # vertex. The round-trip therefore preserves the original points and
    # adds the closing point.
    poly = Parse::Polygon.new([[32.8, -117.6], [32.8, -117.5], [32.9, -117.5]])
    decoded = Parse::Polygon.from_geojson(poly.to_geojson)
    assert_equal decoded.coordinates, [[32.8, -117.6], [32.8, -117.5], [32.9, -117.5], [32.8, -117.6]]
  end

  # ---- LineString ----

  def test_line_string_initializer_from_pairs
    ls = Parse::GeoJSON::LineString.new([[-122.4, 37.7], [-122.39, 37.78]])
    assert_equal ls.coordinates, [[-122.4, 37.7], [-122.39, 37.78]]
  end

  def test_line_string_initializer_from_geopoints
    ls = Parse::GeoJSON::LineString.new([
      Parse::GeoPoint.new(37.7, -122.4),
      Parse::GeoPoint.new(37.78, -122.39),
    ])
    assert_equal ls.coordinates, [[-122.4, 37.7], [-122.39, 37.78]]
  end

  def test_line_string_initializer_from_hash
    ls = Parse::GeoJSON::LineString.new("type" => "LineString", "coordinates" => [[-122.4, 37.7], [-122.39, 37.78]])
    assert_equal ls.coordinates, [[-122.4, 37.7], [-122.39, 37.78]]
  end

  def test_line_string_rejects_wrong_type
    assert_raises(ArgumentError) do
      Parse::GeoJSON::LineString.new("type" => "Polygon", "coordinates" => [[[0, 0]]])
    end
  end

  def test_line_string_to_geojson
    ls = Parse::GeoJSON::LineString.new([[-122.4, 37.7], [-122.39, 37.78]])
    gj = ls.to_geojson
    assert_equal gj["type"], "LineString"
    assert_equal gj["coordinates"], [[-122.4, 37.7], [-122.39, 37.78]]
  end

  def test_line_string_geo_points
    ls = Parse::GeoJSON::LineString.new([[-122.4, 37.7], [-122.39, 37.78]])
    points = ls.geo_points
    assert_equal points.length, 2
    assert_equal points.first.latitude, 37.7
    assert_equal points.first.longitude, -122.4
  end

  def test_line_string_warns_below_min_points
    _, err = capture_io { Parse::GeoJSON::LineString.new([[-122.4, 37.7]]) }
    assert_match(/at least 2/, err)
  end

  def test_line_string_equality
    a = Parse::GeoJSON::LineString.new([[-122.4, 37.7], [-122.39, 37.78]])
    b = Parse::GeoJSON::LineString.new([[-122.4, 37.7], [-122.39, 37.78]])
    assert_equal a, b
  end

  def test_line_string_dup_deep_copy
    ls = Parse::GeoJSON::LineString.new([[-122.4, 37.7], [-122.39, 37.78]])
    copy = ls.dup
    copy.coordinates.first[0] = 99.0
    refute_equal copy.coordinates.first[0], ls.coordinates.first[0]
  end

  # ---- MultiPolygon ----

  def test_multi_polygon_round_trip
    coords = [
      [[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]],
      [[[5, 5], [6, 5], [6, 6], [5, 6], [5, 5]]],
    ]
    mp = Parse::GeoJSON::MultiPolygon.new(coords)
    assert_equal mp.to_geojson["type"], "MultiPolygon"
    assert_equal mp.to_geojson["coordinates"], coords.map { |poly| poly.map { |ring| ring.map { |p| p.map(&:to_f) } } }
  end

  def test_multi_polygon_to_polygons
    coords = [
      [[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]],
      [[[5, 5], [6, 5], [6, 6], [5, 6], [5, 5]]],
    ]
    mp = Parse::GeoJSON::MultiPolygon.new(coords)
    polys = mp.polygons
    assert_equal polys.length, 2
    assert(polys.all? { |p| p.is_a?(Parse::Polygon) })
    # Axis swap back to [lat, lng]
    assert_equal polys.first.coordinates.first, [0.0, 0.0]
  end

  def test_multi_polygon_warns_on_unclosed_ring
    _, err = capture_io do
      Parse::GeoJSON::MultiPolygon.new([[[[0, 0], [1, 0], [1, 1], [0, 1]]]]) # missing closing point
    end
    assert_match(/not closed/, err)
  end

  # ---- Geometry.from_geojson dispatch ----

  def test_geometry_dispatch_linestring
    g = Parse::GeoJSON::Geometry.from_geojson("type" => "LineString", "coordinates" => [[-122.4, 37.7], [-122.39, 37.78]])
    assert_instance_of Parse::GeoJSON::LineString, g
  end

  def test_geometry_dispatch_multipolygon
    g = Parse::GeoJSON::Geometry.from_geojson("type" => "MultiPolygon", "coordinates" => [[[[0, 0], [1, 0], [1, 1], [0, 0]]]])
    assert_instance_of Parse::GeoJSON::MultiPolygon, g
  end

  def test_geometry_dispatch_rejects_unknown_type
    assert_raises(ArgumentError) do
      Parse::GeoJSON::Geometry.from_geojson("type" => "Pentagon", "coordinates" => [])
    end
  end

  # ---- NaN / Infinity rejection (TRACK-QUERY-5) ----

  def test_line_string_rejects_nan_coordinates
    assert_raises(ArgumentError) do
      Parse::GeoJSON::LineString.new([[Float::NAN, 0.0], [1.0, 1.0]])
    end
  end

  def test_line_string_rejects_infinity_coordinates
    assert_raises(ArgumentError) do
      Parse::GeoJSON::LineString.new([[0.0, Float::INFINITY], [1.0, 1.0]])
    end
  end

  def test_multi_polygon_rejects_nan_coordinates
    assert_raises(ArgumentError) do
      Parse::GeoJSON::MultiPolygon.new([[[[Float::NAN, 0.0], [1.0, 0.0], [1.0, 1.0], [Float::NAN, 0.0]]]])
    end
  end

  def test_multi_polygon_rejects_infinity_coordinates
    assert_raises(ArgumentError) do
      Parse::GeoJSON::MultiPolygon.new([[[[0.0, 0.0], [Float::INFINITY, 0.0], [1.0, 1.0], [0.0, 0.0]]]])
    end
  end
end
