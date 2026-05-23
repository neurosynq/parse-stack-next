require_relative "../../../../test_helper"

class TestWithinPolygonQueryConstraint < Minitest::Test
  extend Minitest::Spec::DSL
  include ConstraintTests

  def setup
    @klass = Parse::Constraint::WithinPolygonQueryConstraint
    @key = :$geoWithin
    @operand = :within_polygon
    @keys = [:within_polygon]
    @skip_scalar_values_test = true

    @bermuda = Parse::GeoPoint.new 32.3078000, -64.7504999 # Bermuda
    @miami = Parse::GeoPoint.new 25.7823198, -80.2660226 # Miami, FL
    @san_juan = Parse::GeoPoint.new 18.3848232, -66.0933608 # San Juan, PR
    @san_diego = Parse::GeoPoint.new 32.9201332, -117.1088263
  end

  def build(value)
    { "field" => { @key => { :$polygon => value } } }
  end

  def test_argument_error
    triangle = [@bermuda, @miami] # missing one
    assert_raises(ArgumentError) { User.query(:location.within_polygon => nil).compile }
    assert_raises(ArgumentError) { User.query(:location.within_polygon => []).compile }
    assert_raises(ArgumentError) { User.query(:location.within_polygon => [@bermuda, 2343]).compile }
    assert_raises(ArgumentError) { User.query(:location.within_polygon => triangle).compile }
    triangle.push @san_juan
    refute_raises(ArgumentError) { User.query(:location.within_polygon => triangle).compile }
    quad = triangle + [@san_diego]
    refute_raises(ArgumentError) { User.query(:location.within_polygon => quad).compile }
  end

  def test_compiled_query
    triangle = [@bermuda, @miami, @san_juan]
    compiled_query = { "location" => { "$geoWithin" => { "$polygon" => [
      { :__type => "GeoPoint", :latitude => 32.3078, :longitude => -64.7504999 },
      { :__type => "GeoPoint", :latitude => 25.7823198, :longitude => -80.2660226 },
      { :__type => "GeoPoint", :latitude => 18.3848232, :longitude => -66.0933608 },
    ] } } }
    query = User.query(:location.within_polygon => [@bermuda, @miami, @san_juan])
    assert_equal query.compile_where.as_json, compiled_query.as_json

    compiled_query = { "location" => { "$geoWithin" => { "$polygon" => [
      { :__type => "GeoPoint", :latitude => 32.9201332, :longitude => -117.1088263 },
      { :__type => "GeoPoint", :latitude => 25.7823198, :longitude => -80.2660226 },
      { :__type => "GeoPoint", :latitude => 18.3848232, :longitude => -66.0933608 },
      { :__type => "GeoPoint", :latitude => 32.3078, :longitude => -64.7504999 },
    ] } } }
    query = User.query(:location.within_polygon => [@san_diego, @miami, @san_juan, @bermuda])
    assert_equal query.compile_where.as_json, compiled_query.as_json
  end

  def test_accepts_parse_polygon_literal
    polygon = Parse::Polygon.new([
      [@bermuda.latitude, @bermuda.longitude],
      [@miami.latitude, @miami.longitude],
      [@san_juan.latitude, @san_juan.longitude],
    ])
    compiled = User.query(:location.within_polygon => polygon).compile_where["location"]
    inner = compiled[:$geoWithin][:$polygon]
    # TRACK-QUERY-1: Polygon literal now compiles to the legacy
    # array-of-GeoPoint shape that Parse Server's $polygon operator
    # actually accepts. The {__type: "Polygon", coordinates: ...} wire
    # shape is invalid as a $polygon operand.
    assert_kind_of Array, inner
    assert_equal inner.length, 3
    assert_equal inner.first[:__type], "GeoPoint"
    assert_equal inner.first[:latitude], @bermuda.latitude
    assert_equal inner.first[:longitude], @bermuda.longitude
  end

  def test_polygon_literal_compiles_to_clean_rest_json
    # Polygon literal must produce a parse-able REST payload — no
    # __mongo_direct_only marker leaks, no Polygon wrapper hash.
    polygon = Parse::Polygon.new([
      [@bermuda.latitude, @bermuda.longitude],
      [@miami.latitude, @miami.longitude],
      [@san_juan.latitude, @san_juan.longitude],
    ])
    q = User.query(:location.within_polygon => polygon)
    compiled = q.compile_where
    refute_includes compiled.to_json, "__mongo_direct_only",
                    "compile_where must strip internal routing markers"
    refute_includes compiled.to_json, "Polygon",
                    "Polygon wrapper hash must not appear in $polygon operand"
    refute q.requires_mongo_direct?,
           "within_polygon with Polygon literal should NOT require mongo-direct"
  end
end
