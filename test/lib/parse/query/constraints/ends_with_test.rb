require_relative "../../../../test_helper"

class TestEndsWithConstraint < Minitest::Test
  extend Minitest::Spec::DSL
  include ConstraintTests

  def setup
    @klass = Parse::Constraint::EndsWithConstraint
    @key = :$regex
    @operand = :ends_with
    @keys = [:ends_with]
    @skip_scalar_values_test = true
  end

  def build(value)
    if value.is_a?(String)
      escaped_value = Regexp.escape(value)
      regex_pattern = "#{escaped_value}$"
      { "field" => { "$regex" => regex_pattern, "$options" => "i" } }
    else
      { "field" => { @key.to_s => Parse::Constraint.formatted_value(value) } }
    end
  end

  def test_with_string_value
    constraint = @klass.new(:filename, ".pdf")
    expected = { filename: { :$regex => "\\.pdf$", :$options => "i" } }
    assert_equal expected, constraint.build
  end

  def test_with_special_regex_characters
    constraint = @klass.new(:filename, ".tar.gz")
    # Should escape special regex characters
    expected = { filename: { :$regex => "\\.tar\\.gz$", :$options => "i" } }
    assert_equal expected, constraint.build
  end

  def test_with_complex_special_characters
    constraint = @klass.new(:name, "test+file[1].txt")
    # Should escape +, [, ], and .
    expected = { name: { :$regex => "test\\+file\\[1\\]\\.txt$", :$options => "i" } }
    assert_equal expected, constraint.build
  end

  def test_invalid_value_raises_error
    constraint = @klass.new(:filename, 123)
    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_empty_string
    constraint = @klass.new(:filename, "")
    expected = { filename: { :$regex => "$", :$options => "i" } }
    assert_equal expected, constraint.build
  end

  def test_value_too_long_raises_error
    long_value = "a" * 501
    constraint = @klass.new(:filename, long_value)
    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_symbol_method_registration
    assert Parse::Operation.operators.key?(:ends_with), "ends_with should be registered"
  end

  def test_query_integration
    query = Parse::Query.new("TestClass")
    query.where(:email.ends_with => "@example.com")
    where_clause = query.compile_where
    assert_equal({ "email" => { :$regex => "@example\\.com$", :$options => "i" } }, where_clause)
  end
end
