require_relative "../../../../test_helper"

class TestTimeRangeConstraint < Minitest::Test
  extend Minitest::Spec::DSL
  include ConstraintTests

  def setup
    @klass = Parse::Constraint::TimeRangeConstraint
    @key = nil # This constraint doesn't map to a single key
    @operand = :between_dates
    @keys = [:between_dates]
    @skip_scalar_values_test = true
  end

  def build(value)
    if value.is_a?(Array) && value.length == 2
      start_date, end_date = value
      formatted_start = Parse::Constraint.formatted_value(start_date)
      formatted_end = Parse::Constraint.formatted_value(end_date)
      
      { "field" => { 
        "$gte" => formatted_start,
        "$lte" => formatted_end
      } }
    else
      { "field" => Parse::Constraint.formatted_value(value) }
    end
  end

  def test_with_date_array
    start_date = DateTime.new(2023, 1, 1)
    end_date = DateTime.new(2023, 12, 31)
    constraint = @klass.new(:created_at, [start_date, end_date])
    
    expected_start = { __type: "Date", iso: start_date.utc.iso8601(3) }
    expected_end = { __type: "Date", iso: end_date.utc.iso8601(3) }
    expected = { created_at: { :$gte => expected_start, :$lte => expected_end } }
    
    assert_equal expected, constraint.build
  end

  def test_with_time_array
    start_time = Time.new(2023, 6, 1, 12, 0, 0)
    end_time = Time.new(2023, 6, 30, 18, 0, 0)
    constraint = @klass.new(:created_at, [start_time, end_time])
    
    expected_start = { __type: "Date", iso: start_time.utc.iso8601(3) }
    expected_end = { __type: "Date", iso: end_time.utc.iso8601(3) }
    expected = { created_at: { :$gte => expected_start, :$lte => expected_end } }
    
    assert_equal expected, constraint.build
  end

  def test_invalid_single_value_raises_error
    constraint = @klass.new(:created_at, DateTime.now)
    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_invalid_three_element_array_raises_error
    constraint = @klass.new(:created_at, [DateTime.now, DateTime.now, DateTime.now])
    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_invalid_empty_array_raises_error
    constraint = @klass.new(:created_at, [])
    assert_raises(ArgumentError) do
      constraint.build
    end
  end
end