require_relative "../../../../test_helper"

class TestWithinSphereQueryConstraint < Minitest::Test
  extend Minitest::Spec::DSL
  include ConstraintTests

  def setup
    @klass = Parse::Constraint::WithinSphereQueryConstraint
    @key = :$geoWithin
    @operand = :within_sphere
    @keys = [:within_sphere]
    @skip_scalar_values_test = true

    @center = Parse::GeoPoint.new 32.7157, -117.1611
  end

  def build(value)
    { "field" => { @key => { :$centerSphere => value } } }
  end

  def test_compiled_query_with_km
    query = User.query(:location.within_sphere => [@center, 10, :km])
    expected_radians = 10.0 / Parse::Constraint::WithinSphereQueryConstraint::KM_PER_RADIAN
    compiled = query.compile_where["location"][:$geoWithin][:$centerSphere]
    assert_in_delta compiled[1], expected_radians, 1e-9
    # MongoDB convention: [longitude, latitude] inside $centerSphere.
    assert_equal compiled[0], [@center.longitude, @center.latitude]
  end

  def test_compiled_query_with_miles
    query = User.query(:location.within_sphere => [@center, 5, :miles])
    expected_radians = 5.0 / Parse::Constraint::WithinSphereQueryConstraint::MILES_PER_RADIAN
    compiled = query.compile_where["location"][:$geoWithin][:$centerSphere]
    assert_in_delta compiled[1], expected_radians, 1e-9
  end

  def test_compiled_query_radians_default
    query = User.query(:location.within_sphere => [@center, 0.001])
    compiled = query.compile_where["location"][:$geoWithin][:$centerSphere]
    assert_in_delta compiled[1], 0.001, 1e-12
  end

  def test_kilometers_alias
    query = User.query(:location.within_sphere => [@center, 10, :kilometers])
    expected_radians = 10.0 / Parse::Constraint::WithinSphereQueryConstraint::KM_PER_RADIAN
    compiled = query.compile_where["location"][:$geoWithin][:$centerSphere]
    assert_in_delta compiled[1], expected_radians, 1e-9
  end

  def test_argument_errors
    assert_raises(ArgumentError) { User.query(:location.within_sphere => "bad").compile }
    assert_raises(ArgumentError) { User.query(:location.within_sphere => [@center]).compile }
    assert_raises(ArgumentError) { User.query(:location.within_sphere => ["not a point", 5, :km]).compile }
    assert_raises(ArgumentError) { User.query(:location.within_sphere => [@center, -1, :km]).compile }
    assert_raises(ArgumentError) { User.query(:location.within_sphere => [@center, 0, :km]).compile }
    assert_raises(ArgumentError) { User.query(:location.within_sphere => [@center, 5, :furlongs]).compile }
  end

  def test_rejects_whole_sphere_radius_km
    # TRACK-QUERY-3: caps at π radians (~20015 km) to prevent
    # full-collection scans / DoS via attacker-controlled radii.
    err = assert_raises(ArgumentError) do
      User.query(:location.within_sphere => [@center, 1e9, :km]).compile
    end
    assert_match(/whole-sphere coverage/i, err.message)
  end

  def test_rejects_whole_sphere_radius_radians
    err = assert_raises(ArgumentError) do
      User.query(:location.within_sphere => [@center, 4.0, :radians]).compile
    end
    assert_match(/whole-sphere coverage/i, err.message)
  end

  def test_accepts_radius_exactly_at_cap
    # π radians is the boundary; values up to and including π are valid.
    refute_raises(ArgumentError) do
      User.query(:location.within_sphere => [@center, Math::PI, :radians]).compile
    end
  end
end
