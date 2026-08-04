require_relative "../../../../test_helper"

class TestBetweenConstraint < Minitest::Test
  extend Minitest::Spec::DSL
  include ConstraintTests

  def setup
    @klass = Parse::Constraint::BetweenConstraint
    @key = nil # This constraint doesn't map to a single key
    @operand = :between
    @keys = [:between]
    @skip_scalar_values_test = true
  end

  def build(value)
    if value.is_a?(Array) && value.length == 2
      min_value, max_value = value
      { "field" => {
        "$gte" => Parse::Constraint.formatted_value(min_value),
        "$lte" => Parse::Constraint.formatted_value(max_value),
      } }
    else
      { "field" => Parse::Constraint.formatted_value(value) }
    end
  end

  def test_with_numeric_array
    constraint = @klass.new(:age, [5, 25])
    expected = { age: { :$gte => 5, :$lte => 25 } }
    assert_equal expected, constraint.build
  end

  def test_with_inclusive_range
    constraint = @klass.new(:age, 5..25)
    expected = { age: { :$gte => 5, :$lte => 25 } }
    assert_equal expected, constraint.build
  end

  def test_with_exclusive_range
    constraint = @klass.new(:age, 5...25)
    expected = { age: { :$gte => 5, :$lt => 25 } }
    assert_equal expected, constraint.build
  end

  def test_with_date_range
    start_date = DateTime.new(2023, 1, 1)
    end_date = DateTime.new(2023, 12, 31)
    constraint = @klass.new(:created_at, start_date...end_date)

    expected_start = { __type: "Date", iso: start_date.utc.iso8601(3) }
    expected_end = { __type: "Date", iso: end_date.utc.iso8601(3) }
    expected = { created_at: { :$gte => expected_start, :$lt => expected_end } }

    assert_equal expected, constraint.build
  end

  def test_with_beginless_range
    constraint = @klass.new(:age, ..25)
    expected = { age: { :$lte => 25 } }
    assert_equal expected, constraint.build
  end

  def test_with_endless_range
    constraint = @klass.new(:age, 5..)
    expected = { age: { :$gte => 5 } }
    assert_equal expected, constraint.build
  end

  def test_with_endless_exclusive_range
    constraint = @klass.new(:age, 5...)
    expected = { age: { :$gte => 5 } }
    assert_equal expected, constraint.build
  end

  def test_invalid_single_value_raises_error
    constraint = @klass.new(:age, 25)
    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_invalid_one_element_array_raises_error
    constraint = @klass.new(:age, [25])
    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_invalid_three_element_array_raises_error
    constraint = @klass.new(:age, [5, 15, 25])
    assert_raises(ArgumentError) do
      constraint.build
    end
  end
end
