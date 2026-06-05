# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

class TestContainedByConstraint < Minitest::Test
  extend Minitest::Spec::DSL
  include ConstraintTests

  def setup
    @klass = Parse::Constraint::ContainedByConstraint
    @key = :$containedBy
    @operand = :contained_by
    @keys = [:contained_by]
  end

  def build(value)
    { "field" => { @key.to_s => [Parse::Constraint.formatted_value(value)].flatten.compact } }
  end

  def test_contained_by_operator_registered_on_symbol
    assert_respond_to :tags, :contained_by
  end

  def test_constraint_keyword_is_dollar_contained_by
    assert_equal :$containedBy, Parse::Constraint::ContainedByConstraint.key
  end

  def test_constraint_operand_is_contained_by
    assert_equal :contained_by, Parse::Constraint::ContainedByConstraint.operand
  end

  def test_compile_produces_correct_hash
    q = Parse::Query.new("Post")
    q.where :tags.contained_by => ["ruby", "rails", "parse"]
    compiled = q.compile(encode: false)
    where = compiled[:where]
    assert where.key?("tags"), "compiled where should have 'tags' key"
    # key is emitted as a symbol by constraint#build
    assert_equal({ :"$containedBy" => ["ruby", "rails", "parse"] }, where["tags"])
  end

  def test_compile_wraps_scalar_in_array
    q = Parse::Query.new("Post")
    q.where :tags.contained_by => "ruby"
    compiled = q.compile(encode: false)
    assert_equal({ :"$containedBy" => ["ruby"] }, compiled[:where]["tags"])
  end

  def test_constraint_instance_has_correct_key
    op = :tags.contained_by
    assert_instance_of Parse::Operation, op
    assert_kind_of Parse::Constraint::ContainedByConstraint, op.constraint
    assert_equal :$containedBy, op.constraint.key
  end
end
