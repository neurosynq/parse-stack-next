require_relative "../../../../test_helper"

class TestMatchesKeyInQueryConstraint < Minitest::Test
  extend Minitest::Spec::DSL
  include ConstraintTests

  def setup
    @klass = Parse::Constraint::MatchesKeyInQueryConstraint
    @key = :$select
    @operand = :matches_key_in_query
    @keys = [:matches_key, :matches_key_in_query]
    @skip_scalar_values_test = true
  end

  def build(value)
    # For this constraint, we expect a different format since it's key-based matching
    if value.is_a?(Parse::Query)
      compiled_query = Parse::Constraint.formatted_value(value)
      { "field" => { @key.to_s => { key: "field", query: compiled_query } } }
    elsif value.is_a?(Hash) && value[:query].is_a?(Parse::Query)
      compiled_query = Parse::Constraint.formatted_value(value[:query])
      remote_key = value[:key] || "field"
      { "field" => { @key.to_s => { key: remote_key, query: compiled_query } } }
    else
      { "field" => { @key.to_s => Parse::Constraint.formatted_value(value) } }
    end
  end

  def test_with_parse_query
    query = Parse::Query.new("Customer", active: true)
    constraint = @klass.new(:company, query)

    expected_query = { where: { "active" => true }, className: "Customer" }
    expected = { company: { :$select => { key: :company, query: expected_query } } }

    assert_equal expected, constraint.build
  end

  def test_with_hash_containing_query
    query = Parse::Query.new("Customer", active: true)
    value = { key: "company_name", query: query }
    constraint = @klass.new(:company, value)

    expected_query = { where: { "active" => true }, className: "Customer" }
    expected = { company: { :$select => { key: "company_name", query: expected_query } } }

    assert_equal expected, constraint.build
  end

  def test_invalid_query_raises_error
    invalid_value = "not a query"
    constraint = @klass.new(:company, invalid_value)

    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_invalid_hash_query_raises_error
    invalid_hash = { key: "company", query: "not a query" }
    constraint = @klass.new(:company, invalid_hash)

    assert_raises(ArgumentError) do
      constraint.build
    end
  end
end
