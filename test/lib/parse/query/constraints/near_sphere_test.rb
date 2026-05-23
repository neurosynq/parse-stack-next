require_relative "../../../../test_helper"

class TestNearSphereQueryConstraint < Minitest::Test
  extend Minitest::Spec::DSL
  include ConstraintTests

  def setup
    @klass = Parse::Constraint::NearSphereQueryConstraint
    @key = :$nearSphere
    @operand = :near
    @keys = [:near]
    @skip_scalar_values_test = true
  end

  def build(value)
    { "field" => { @key.to_s => value } }
  end

  def test_max_miles_emits_distance_in_miles
    gp = Parse::GeoPoint.new 32.7157, -117.1611
    compiled = User.query(:location.near => gp.max_miles(10)).compile_where["location"]
    assert_equal compiled[:$maxDistanceInMiles], 10.0
    refute compiled.key?(:$maxDistanceInKilometers)
  end

  def test_max_kilometers_emits_distance_in_kilometers
    gp = Parse::GeoPoint.new 32.7157, -117.1611
    compiled = User.query(:location.near => gp.max_kilometers(10)).compile_where["location"]
    assert_equal compiled[:$maxDistanceInKilometers], 10.0
    refute compiled.key?(:$maxDistanceInMiles)
  end

  def test_no_max_distance_omits_distance_keys
    gp = Parse::GeoPoint.new 32.7157, -117.1611
    compiled = User.query(:location.near => gp).compile_where["location"]
    refute compiled.key?(:$maxDistanceInMiles)
    refute compiled.key?(:$maxDistanceInKilometers)
    refute compiled.key?(:$maxDistance)
  end

  def test_max_radians_emits_raw_maxDistance
    gp = Parse::GeoPoint.new 32.7157, -117.1611
    compiled = User.query(:location.near => gp.max_radians(0.001)).compile_where["location"]
    assert_equal compiled[:$maxDistance], 0.001
    refute compiled.key?(:$maxDistanceInMiles)
    refute compiled.key?(:$maxDistanceInKilometers)
  end

  def test_rejects_whole_sphere_max_distance_km
    # TRACK-QUERY-3: caps max distance at π radians (~20015 km) to
    # prevent `$nearSphere` from defeating the 2dsphere index.
    gp = Parse::GeoPoint.new 32.7157, -117.1611
    err = assert_raises(ArgumentError) do
      User.query(:location.near => gp.max_kilometers(1e9)).compile
    end
    assert_match(/whole-sphere coverage/i, err.message)
  end

  def test_rejects_whole_sphere_max_distance_radians
    gp = Parse::GeoPoint.new 32.7157, -117.1611
    err = assert_raises(ArgumentError) do
      User.query(:location.near => gp.max_radians(4.0)).compile
    end
    assert_match(/whole-sphere coverage/i, err.message)
  end
end
