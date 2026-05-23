# encoding: UTF-8
# frozen_string_literal: true

require_relative '../../test_helper'

class ArrayConstraintsUnitTest < Minitest::Test
  # Mock pointer class for testing - mimics Parse::Pointer behavior
  class MockPointer
    attr_reader :id, :parse_class

    def initialize(id: nil, parse_class: "TestClass")
      @id = id
      @parse_class = parse_class
    end

    def pointer?
      true
    end

    # Make it respond to pointer method like Parse objects do
    def pointer
      self
    end
  end

  # ==========================================================================
  # Test: Unsaved object validation (nil ID)
  # ==========================================================================

  def test_set_equals_raises_error_for_unsaved_pointer
    puts "\n=== Testing set_equals constraint with unsaved objects ==="

    # Create a mock unsaved pointer (nil ID)
    unsaved_pointer = MockPointer.new(id: nil)

    query = Parse::Query.new("TestClass")

    error = assert_raises(ArgumentError) do
      query.where(:categories.set_equals => [unsaved_pointer])
      # Trigger constraint compilation
      query.pipeline
    end

    assert_match(/Cannot use unsaved objects/, error.message)
    assert_match(/missing ID/, error.message)
    puts "✅ set_equals correctly raises error for unsaved objects"
  end

  def test_eq_array_raises_error_for_unsaved_pointer
    puts "\n=== Testing eq_array constraint with unsaved objects ==="

    unsaved_pointer = MockPointer.new(id: nil)

    query = Parse::Query.new("TestClass")

    error = assert_raises(ArgumentError) do
      query.where(:categories.eq_array => [unsaved_pointer])
      query.pipeline
    end

    assert_match(/Cannot use unsaved objects/, error.message)
    puts "✅ eq_array correctly raises error for unsaved objects"
  end

  def test_neq_raises_error_for_unsaved_pointer
    puts "\n=== Testing neq constraint with unsaved objects ==="

    unsaved_pointer = MockPointer.new(id: nil)

    query = Parse::Query.new("TestClass")

    error = assert_raises(ArgumentError) do
      query.where(:categories.neq => [unsaved_pointer])
      query.pipeline
    end

    assert_match(/Cannot use unsaved objects/, error.message)
    puts "✅ neq correctly raises error for unsaved objects"
  end

  def test_not_set_equals_raises_error_for_unsaved_pointer
    puts "\n=== Testing not_set_equals constraint with unsaved objects ==="

    unsaved_pointer = MockPointer.new(id: nil)

    query = Parse::Query.new("TestClass")

    error = assert_raises(ArgumentError) do
      query.where(:categories.not_set_equals => [unsaved_pointer])
      query.pipeline
    end

    assert_match(/Cannot use unsaved objects/, error.message)
    puts "✅ not_set_equals correctly raises error for unsaved objects"
  end

  def test_subset_of_raises_error_for_unsaved_pointer
    puts "\n=== Testing subset_of constraint with unsaved objects ==="

    unsaved_pointer = MockPointer.new(id: nil)

    query = Parse::Query.new("TestClass")

    error = assert_raises(ArgumentError) do
      query.where(:categories.subset_of => [unsaved_pointer])
      query.pipeline
    end

    assert_match(/Cannot use unsaved objects/, error.message)
    puts "✅ subset_of correctly raises error for unsaved objects"
  end

  # ==========================================================================
  # Test: Saved pointers work correctly
  # ==========================================================================

  def test_set_equals_accepts_saved_pointer
    puts "\n=== Testing set_equals constraint with saved objects ==="

    saved_pointer = MockPointer.new(id: "abc123")

    query = Parse::Query.new("TestClass")
    query.where(:categories.set_equals => [saved_pointer])

    # Should build without error
    pipeline = query.pipeline
    assert pipeline.is_a?(Array), "Should generate pipeline"
    assert pipeline.any? { |stage| stage["$match"] }, "Pipeline should have $match stage"

    puts "✅ set_equals correctly accepts saved objects with IDs"
  end

  def test_eq_array_accepts_saved_pointer
    puts "\n=== Testing eq_array constraint with saved objects ==="

    saved_pointer = MockPointer.new(id: "xyz789")

    query = Parse::Query.new("TestClass")
    query.where(:categories.eq_array => [saved_pointer])

    pipeline = query.pipeline
    assert pipeline.is_a?(Array), "Should generate pipeline"

    puts "✅ eq_array correctly accepts saved objects with IDs"
  end

  # ==========================================================================
  # Test: Mixed saved/unsaved raises error
  # ==========================================================================

  def test_mixed_saved_unsaved_raises_error
    puts "\n=== Testing constraint with mixed saved/unsaved objects ==="

    saved_pointer = MockPointer.new(id: "abc123")
    unsaved_pointer = MockPointer.new(id: nil)

    query = Parse::Query.new("TestClass")

    error = assert_raises(ArgumentError) do
      query.where(:categories.set_equals => [saved_pointer, unsaved_pointer])
      query.pipeline
    end

    assert_match(/Cannot use unsaved objects/, error.message)
    puts "✅ Correctly raises error when array contains unsaved objects"
  end

  # ==========================================================================
  # Test: Simple value arrays work correctly
  # ==========================================================================

  def test_set_equals_with_simple_values
    puts "\n=== Testing set_equals constraint with simple values ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.set_equals => ["rock", "pop"])

    pipeline = query.pipeline
    assert pipeline.is_a?(Array), "Should generate pipeline"

    # Check the pipeline has the right structure
    match_stage = pipeline.find { |stage| stage["$match"] }
    assert match_stage, "Should have $match stage"
    assert match_stage["$match"]["$expr"], "Should use $expr"
    assert match_stage["$match"]["$expr"]["$setEquals"], "Should use $setEquals"

    puts "✅ set_equals correctly builds pipeline for simple values"
  end

  def test_eq_array_with_simple_values
    puts "\n=== Testing eq_array constraint with simple values ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.eq_array => ["rock", "pop"])

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage["$match"]["$expr"]["$eq"], "Should use $eq for exact order"

    puts "✅ eq_array correctly builds pipeline for simple values"
  end

  # ==========================================================================
  # Test: Size constraint edge cases
  # ==========================================================================

  def test_size_constraint_with_zero
    puts "\n=== Testing size constraint with zero ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.size => 0)

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage, "Should have $match stage"
    assert match_stage["$match"]["$expr"], "Should use $expr"

    puts "✅ size constraint correctly handles zero"
  end

  def test_size_constraint_with_comparison
    puts "\n=== Testing size constraint with comparison operators ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.size => { gt: 2, lte: 10 })

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage, "Should have $match stage"
    expr = match_stage["$match"]["$expr"]
    assert expr["$and"], "Should use $and for multiple comparisons"

    puts "✅ size constraint correctly handles comparison operators"
  end

  def test_arr_empty_constraint
    puts "\n=== Testing arr_empty constraint ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.arr_empty => true)

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage, "Should have $match stage"
    # Check for size == 0
    expr = match_stage["$match"]["$expr"]
    assert expr["$eq"], "Should use $eq for empty check"

    puts "✅ arr_empty constraint correctly builds pipeline"
  end

  def test_arr_nempty_constraint
    puts "\n=== Testing arr_nempty constraint ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.arr_nempty => true)

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage, "Should have $match stage"
    # Check for size > 0
    expr = match_stage["$match"]["$expr"]
    assert expr["$gt"], "Should use $gt for non-empty check"

    puts "✅ arr_nempty constraint correctly builds pipeline"
  end

  # ==========================================================================
  # Test: Empty array handling
  # ==========================================================================

  def test_set_equals_with_empty_array
    puts "\n=== Testing set_equals with empty array ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.set_equals => [])

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage, "Should have $match stage"
    # Should generate valid pipeline for empty array comparison
    assert match_stage["$match"]["$expr"]["$setEquals"], "Should use $setEquals even for empty array"

    puts "✅ set_equals correctly handles empty array"
  end

  def test_eq_array_with_empty_array
    puts "\n=== Testing eq_array with empty array ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.eq_array => [])

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage, "Should have $match stage"
    assert match_stage["$match"]["$expr"]["$eq"], "Should use $eq for empty array"

    puts "✅ eq_array correctly handles empty array"
  end
end
