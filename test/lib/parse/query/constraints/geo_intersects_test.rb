require_relative "../../../../test_helper"

class TestGeoIntersectsGeometryQueryConstraint < Minitest::Test
  extend Minitest::Spec::DSL
  include ConstraintTests

  def setup
    @klass = Parse::Constraint::GeoIntersectsGeometryQueryConstraint
    @key = :$geoIntersects
    @operand = :geo_intersects
    @keys = [:geo_intersects]
    @skip_scalar_values_test = true
  end

  def build(value)
    { "field" => { @key => { :$geometry => value } } }
  end

  def test_compiles_polygon
    poly = Parse::Polygon.new([[0, 0], [0, 1], [1, 0]])
    q = User.query(:area.geo_intersects => poly)
    compiled = q.compile_where["area"][:$geoIntersects][:$geometry]
    assert_equal compiled["type"], "Polygon"
  end

  def test_compiles_linestring
    ls = Parse::GeoJSON::LineString.new([[-122.4, 37.7], [-122.39, 37.78]])
    q = User.query(:route.geo_intersects => ls)
    compiled = q.compile_where["route"][:$geoIntersects][:$geometry]
    assert_equal compiled["type"], "LineString"
    assert_equal compiled["coordinates"], [[-122.4, 37.7], [-122.39, 37.78]]
  end

  def test_compiles_multi_polygon
    mp = Parse::GeoJSON::MultiPolygon.new([[[[0, 0], [1, 0], [1, 1], [0, 0]]]])
    q = User.query(:regions.geo_intersects => mp)
    compiled = q.compile_where["regions"][:$geoIntersects][:$geometry]
    assert_equal compiled["type"], "MultiPolygon"
  end

  def test_compiles_geopoint
    gp = Parse::GeoPoint.new(32.7, -117.1)
    q = User.query(:area.geo_intersects => gp)
    compiled = q.compile_where["area"][:$geoIntersects][:$geometry]
    assert_equal compiled["type"], "Point"
    assert_equal compiled["coordinates"], [-117.1, 32.7]
  end

  def test_compiles_raw_geojson_hash
    geom = { "type" => "Polygon", "coordinates" => [[[0, 0], [1, 0], [1, 1], [0, 0]]] }
    q = User.query(:area.geo_intersects => geom)
    compiled = q.compile_where["area"][:$geoIntersects][:$geometry]
    assert_equal compiled["type"], "Polygon"
  end

  def test_emits_mongo_direct_marker
    poly = Parse::Polygon.new([[0, 0], [0, 1], [1, 0]])
    q = User.query(:area.geo_intersects => poly)
    # TRACK-QUERY-2: the marker now lives in compile_markers; compile_where
    # is the public wire-shape and must NOT contain `__`-prefixed markers.
    refute q.compile_where.key?("__mongo_direct_only"),
           "compile_where must strip __ routing markers (QUERY-2)"
    assert q.compile_markers.key?("__mongo_direct_only"),
           "compile_markers must retain the routing marker for the routing layer"
    assert q.requires_mongo_direct?
  end

  def test_rejects_unsupported_value
    assert_raises(ArgumentError) { User.query(:area.geo_intersects => "string").compile }
    assert_raises(ArgumentError) { User.query(:area.geo_intersects => { "type" => "Polygon" }).compile }
  end

  def test_rejects_non_allowlisted_geojson_type
    # TRACK-QUERY-6: defense-in-depth — only RFC 7946 geometry types
    # may pass through `geo_intersects`. Forbids `$where`, `Polygon\0`,
    # or any non-geometry string.
    assert_raises(ArgumentError) do
      User.query(:area.geo_intersects => { "type" => "$where", "coordinates" => [] }).compile
    end
    assert_raises(ArgumentError) do
      User.query(:area.geo_intersects => { "type" => "EvilType", "coordinates" => [[0, 0]] }).compile
    end
    # Sanity check: a valid GeoJSON type is still accepted.
    poly = { "type" => "Polygon", "coordinates" => [[[0, 0], [1, 0], [1, 1], [0, 0]]] }
    refute_raises(ArgumentError) { User.query(:area.geo_intersects => poly).compile }
  end

  def test_master_key_gate_raises_when_disabled
    poly = Parse::Polygon.new([[0, 0], [0, 1], [1, 0]])
    q = User.query(:area.geo_intersects => poly)
    q.use_master_key = false
    err = assert_raises(Parse::Query::MongoDirectRequired) { q.assert_mongo_direct_routable! }
    assert_match(/master.key/i, err.message)
  end

  def test_master_key_gate_falls_through_to_enabled_check
    # Default use_master_key is true; the next gate is Parse::MongoDB.enabled?
    poly = Parse::Polygon.new([[0, 0], [0, 1], [1, 0]])
    q = User.query(:area.geo_intersects => poly)
    err = assert_raises(Parse::Query::MongoDirectRequired) { q.assert_mongo_direct_routable! }
    assert_match(/not enabled|configure/i, err.message)
  end

  def test_scope_to_user_satisfies_gate_without_master_key
    poly = Parse::Polygon.new([[0, 0], [0, 1], [1, 0]])
    q = User.query(:area.geo_intersects => poly)
    q.use_master_key = false
    q.scope_to_user(Parse::Pointer.new("_User", "abc123"))
    # Master-key gate passes; the next gate (Parse::MongoDB.enabled?) fires.
    err = assert_raises(Parse::Query::MongoDirectRequired) { q.assert_mongo_direct_routable! }
    refute_match(/master.key/i, err.message)
    assert_match(/not enabled|configure/i, err.message)
  end

  def test_scope_to_user_rejects_non_user_arg
    q = User.query(:area.geo_intersects => Parse::Polygon.new([[0, 0], [0, 1], [1, 0]]))
    assert_raises(ArgumentError) { q.scope_to_user("not a user") }
    assert_raises(ArgumentError) { q.scope_to_user(nil) }
  end

  def test_acl_permission_set_includes_user_id_and_public
    q = User.query
    q.scope_to_user(Parse::Pointer.new("_User", "abc123"))
    perms = q.acl_permission_set
    assert_includes perms, "abc123"
    assert_includes perms, "*"
  end

  def test_acl_permission_set_nil_without_scope
    assert_nil User.query.acl_permission_set
  end
end
