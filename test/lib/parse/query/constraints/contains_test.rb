require_relative "../../../../test_helper"

class TestContainsConstraint < Minitest::Test
  extend Minitest::Spec::DSL
  include ConstraintTests

  def setup
    @klass = Parse::Constraint::ContainsConstraint
    @key = :$regex
    @operand = :contains
    @keys = [:contains]
    @skip_scalar_values_test = true
  end

  def build(value)
    if value.is_a?(String)
      escaped_value = Regexp.escape(value)
      regex_pattern = ".*#{escaped_value}.*"
      { "field" => { "$regex" => regex_pattern, "$options" => "i" } }
    else
      { "field" => { @key.to_s => Parse::Constraint.formatted_value(value) } }
    end
  end

  def test_with_string_value
    constraint = @klass.new(:title, "parse")
    expected = { title: { :$regex => ".*parse.*", :$options => "i" } }
    assert_equal expected, constraint.build
  end

  def test_with_special_regex_characters
    constraint = @klass.new(:title, "parse.server+test")
    # Should escape special regex characters
    expected = { title: { :$regex => ".*parse\\.server\\+test.*", :$options => "i" } }
    assert_equal expected, constraint.build
  end

  def test_invalid_value_raises_error
    constraint = @klass.new(:title, 123)
    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_empty_string
    constraint = @klass.new(:title, "")
    expected = { title: { :$regex => ".*.*", :$options => "i" } }
    assert_equal expected, constraint.build
  end
end
