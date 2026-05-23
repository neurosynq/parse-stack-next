require_relative "../../../../test_helper"

class TestPolygonContainsQueryConstraint < Minitest::Test
  extend Minitest::Spec::DSL
  include ConstraintTests

  def setup
    @klass = Parse::Constraint::PolygonContainsQueryConstraint
    @key = :$geoIntersects
    @operand = :polygon_contains
    @keys = [:polygon_contains]
    @skip_scalar_values_test = true

    @miami = Parse::GeoPoint.new 25.7823198, -80.2660226
  end

  def build(value)
    { "field" => { @key => { :$point => value } } }
  end

  def test_compiled_query_with_geopoint
    expected = {
      "area" => {
        "$geoIntersects" => {
          "$point" => { :__type => "GeoPoint", :latitude => 25.7823198, :longitude => -80.2660226 },
        },
      },
    }
    query = User.query(:area.polygon_contains => @miami)
    assert_equal query.compile_where.as_json, expected.as_json
  end

  def test_compiled_query_with_array
    expected = {
      "area" => {
        "$geoIntersects" => {
          "$point" => { :__type => "GeoPoint", :latitude => 25.7823198, :longitude => -80.2660226 },
        },
      },
    }
    query = User.query(:area.polygon_contains => [25.7823198, -80.2660226])
    assert_equal query.compile_where.as_json, expected.as_json
  end

  def test_argument_error
    assert_raises(ArgumentError) { User.query(:area.polygon_contains => "not a point").compile }
    assert_raises(ArgumentError) { User.query(:area.polygon_contains => [1]).compile }
    assert_raises(ArgumentError) { User.query(:area.polygon_contains => [1, "x"]).compile }
    # Hash branch must be GeoPoint-shaped — reject Polygon hash, $where injection, missing __type.
    assert_raises(ArgumentError) do
      User.query(:area.polygon_contains => { __type: "Polygon", coordinates: [[0, 0], [0, 1], [1, 0]] }).compile
    end
    assert_raises(ArgumentError) do
      User.query(:area.polygon_contains => { :$where => "sleep(5000)" }).compile
    end
    assert_raises(ArgumentError) do
      User.query(:area.polygon_contains => { latitude: 1.0, longitude: 2.0 }).compile
    end
  end

  def test_accepts_geopoint_wire_hash
    expected_point = { :__type => "GeoPoint", :latitude => 25.7823198, :longitude => -80.2660226 }
    query = User.query(:area.polygon_contains => { __type: "GeoPoint", latitude: 25.7823198, longitude: -80.2660226 })
    compiled = query.compile_where["area"][:$geoIntersects][:$point]
    assert_equal compiled, expected_point
  end
end
