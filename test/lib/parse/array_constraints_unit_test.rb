# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

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

  def test_arr_empty_constraint_true
    puts "\n=== Testing arr_empty => true constraint (uses equality) ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.arr_empty => true)

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage, "Should have $match stage"
    # arr_empty => true now uses direct equality { field: [] } for index usage
    assert_equal [], match_stage["$match"]["tags"], "Should use equality with empty array"

    puts "✅ arr_empty => true correctly uses equality (index-friendly)"
  end

  def test_arr_empty_constraint_false
    puts "\n=== Testing arr_empty => false constraint (uses $ne []) ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.arr_empty => false)

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage, "Should have $match stage"
    # arr_empty => false uses $ne [] which is index-friendly
    tags_condition = match_stage["$match"]["tags"]
    assert_equal [], tags_condition["$ne"], "Should use $ne => []"

    puts "✅ arr_empty => false correctly uses $ne [] (index-friendly)"
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

  # ==========================================================================
  # Test: $setEquals wraps field reference in $ifNull so missing fields
  # don't raise "All operands of $setEquals must be arrays" (error 17044)
  # on legacy documents that lack the field.
  # ==========================================================================

  def test_set_equals_simple_values_wraps_field_in_ifnull
    query = Parse::Query.new("TestClass")
    query.where(:tags.set_equals => ["rock", "pop"])

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }
    set_equals = match_stage["$match"]["$expr"]["$setEquals"]

    assert_equal({ "$ifNull" => ["$tags", []] }, set_equals[0],
                 "First operand should wrap field reference in $ifNull => []")
    assert_equal ["rock", "pop"], set_equals[1], "Second operand is the target value array"
  end

  def test_set_equals_pointer_array_wraps_map_input_in_ifnull
    saved_pointer = MockPointer.new(id: "abc123")

    query = Parse::Query.new("TestClass")
    query.where(:categories.set_equals => [saved_pointer])

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }
    set_equals = match_stage["$match"]["$expr"]["$setEquals"]

    map_op = set_equals[0]["$map"]
    assert map_op, "First operand should be a $map expression for pointer arrays"
    assert_equal({ "$ifNull" => ["$categories", []] }, map_op["input"],
                 "$map input should wrap field reference in $ifNull => []")
    assert_equal "p", map_op["as"]
    assert_equal "$$p.objectId", map_op["in"]
    assert_equal ["abc123"], set_equals[1]
  end

  def test_not_set_equals_simple_values_wraps_field_in_ifnull
    query = Parse::Query.new("TestClass")
    query.where(:tags.not_set_equals => ["rock", "pop"])

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }
    set_equals = match_stage["$match"]["$expr"]["$not"]["$setEquals"]

    assert_equal({ "$ifNull" => ["$tags", []] }, set_equals[0],
                 "First operand should wrap field reference in $ifNull => [] inside $not")
    assert_equal ["rock", "pop"], set_equals[1]
  end

  def test_not_set_equals_pointer_array_wraps_map_input_in_ifnull
    saved_pointer = MockPointer.new(id: "abc123")

    query = Parse::Query.new("TestClass")
    query.where(:categories.not_set_equals => [saved_pointer])

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }
    set_equals = match_stage["$match"]["$expr"]["$not"]["$setEquals"]

    map_op = set_equals[0]["$map"]
    assert map_op, "First operand should be a $map expression for pointer arrays inside $not"
    assert_equal({ "$ifNull" => ["$categories", []] }, map_op["input"],
                 "$map input should wrap field reference in $ifNull => []")
    assert_equal ["abc123"], set_equals[1]
  end

  # ==========================================================================
  # Sibling-constraint missing-field defenses. Same shape as the set_equals fix:
  # eq_array, neq, subset_of, first, and last all wrap field references in
  # $ifNull => [] so missing-field documents don't crash $map / $setIsSubset
  # and are treated consistently as []. Behavior alignment with arr_empty,
  # empty_or_nil, and size.
  # ==========================================================================

  def test_eq_array_simple_values_wraps_field_in_ifnull
    query = Parse::Query.new("TestClass")
    query.where(:tags.eq_array => ["rock", "pop"])

    eq = query.pipeline.find { |s| s["$match"] }["$match"]["$expr"]["$eq"]
    assert_equal({ "$ifNull" => ["$tags", []] }, eq[0])
    assert_equal ["rock", "pop"], eq[1]
  end

  def test_eq_array_pointer_wraps_map_input_in_ifnull
    saved = MockPointer.new(id: "abc")
    query = Parse::Query.new("TestClass")
    query.where(:categories.eq_array => [saved])

    eq = query.pipeline.find { |s| s["$match"] }["$match"]["$expr"]["$eq"]
    assert_equal({ "$ifNull" => ["$categories", []] }, eq[0]["$map"]["input"])
  end

  def test_neq_simple_values_wraps_field_in_ifnull
    query = Parse::Query.new("TestClass")
    query.where(:tags.neq => ["rock", "pop"])

    ne = query.pipeline.find { |s| s["$match"] }["$match"]["$expr"]["$ne"]
    assert_equal({ "$ifNull" => ["$tags", []] }, ne[0])
  end

  def test_neq_pointer_wraps_map_input_in_ifnull
    saved = MockPointer.new(id: "abc")
    query = Parse::Query.new("TestClass")
    query.where(:categories.neq => [saved])

    ne = query.pipeline.find { |s| s["$match"] }["$match"]["$expr"]["$ne"]
    assert_equal({ "$ifNull" => ["$categories", []] }, ne[0]["$map"]["input"])
  end

  def test_subset_of_simple_values_wraps_field_in_ifnull
    query = Parse::Query.new("TestClass")
    query.where(:tags.subset_of => ["rock", "pop", "jazz"])

    subset = query.pipeline.find { |s| s["$match"] }["$match"]["$expr"]["$setIsSubset"]
    assert_equal({ "$ifNull" => ["$tags", []] }, subset[0])
    assert_equal ["rock", "pop", "jazz"], subset[1]
  end

  def test_subset_of_pointer_wraps_map_input_in_ifnull
    saved = MockPointer.new(id: "abc")
    query = Parse::Query.new("TestClass")
    query.where(:categories.subset_of => [saved])

    subset = query.pipeline.find { |s| s["$match"] }["$match"]["$expr"]["$setIsSubset"]
    assert_equal({ "$ifNull" => ["$categories", []] }, subset[0]["$map"]["input"])
  end

  def test_first_simple_value_wraps_arrayelemat_input_in_ifnull
    query = Parse::Query.new("TestClass")
    query.where(:tags.first => "rock")

    eq = query.pipeline.find { |s| s["$match"] }["$match"]["$expr"]["$eq"]
    assert_equal({ "$ifNull" => ["$tags", []] }, eq[0]["$arrayElemAt"][0])
    assert_equal 0, eq[0]["$arrayElemAt"][1]
  end

  def test_last_simple_value_wraps_arrayelemat_input_in_ifnull
    query = Parse::Query.new("TestClass")
    query.where(:tags.last => "pop")

    eq = query.pipeline.find { |s| s["$match"] }["$match"]["$expr"]["$eq"]
    assert_equal({ "$ifNull" => ["$tags", []] }, eq[0]["$arrayElemAt"][0])
    assert_equal(-1, eq[0]["$arrayElemAt"][1])
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

  # ==========================================================================
  # Test: empty_or_nil constraint
  # ==========================================================================

  def test_empty_or_nil_constraint_true
    puts "\n=== Testing empty_or_nil => true constraint ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.empty_or_nil => true)

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage, "Should have $match stage"
    or_conditions = match_stage["$match"]["$or"]
    assert or_conditions, "Should use $or for empty_or_nil"
    assert_equal 3, or_conditions.length, "Should have 3 conditions (empty, not exists, nil)"

    # Check for empty array condition (now uses $exists + $eq for reliability)
    assert or_conditions.any? { |c|
      c["tags"].is_a?(Hash) && c["tags"]["$exists"] == true && c["tags"]["$eq"] == []
    }, "Should match empty array with $exists and $eq"
    # Check for exists => false condition
    assert or_conditions.any? { |c| c["tags"].is_a?(Hash) && c["tags"]["$exists"] == false }, "Should match non-existent field"
    # Check for nil condition (now uses explicit $eq)
    assert or_conditions.any? { |c| c["tags"].is_a?(Hash) && c["tags"]["$eq"] == nil }, "Should match nil value with $eq"

    puts "✅ empty_or_nil => true correctly builds $or with 3 conditions"
  end

  def test_empty_or_nil_constraint_false
    puts "\n=== Testing empty_or_nil => false constraint ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.empty_or_nil => false)

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage, "Should have $match stage"
    and_conditions = match_stage["$match"]["$and"]
    assert and_conditions, "Should use $and for non-empty check"
    assert_equal 3, and_conditions.length, "Should have 3 conditions"

    # Check for exists => true condition
    assert and_conditions.any? { |c| c["tags"].is_a?(Hash) && c["tags"]["$exists"] == true }, "Should check $exists => true"
    # Check for $ne => nil condition
    assert and_conditions.any? { |c| c["tags"].is_a?(Hash) && c["tags"]["$ne"] == nil }, "Should check $ne => nil"
    # Check for $ne => [] condition
    assert and_conditions.any? { |c| c["tags"].is_a?(Hash) && c["tags"]["$ne"] == [] }, "Should check $ne => []"

    puts "✅ empty_or_nil => false correctly builds $and with 3 conditions"
  end

  # ==========================================================================
  # Test: not_empty constraint (opposite of empty_or_nil)
  # ==========================================================================

  def test_not_empty_constraint_true
    puts "\n=== Testing not_empty => true constraint ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.not_empty => true)

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage, "Should have $match stage"
    and_conditions = match_stage["$match"]["$and"]
    assert and_conditions, "Should use $and for non-empty check"
    assert_equal 3, and_conditions.length, "Should have 3 conditions"

    puts "✅ not_empty => true correctly builds $and with 3 conditions"
  end

  def test_not_empty_constraint_false
    puts "\n=== Testing not_empty => false constraint ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.not_empty => false)

    pipeline = query.pipeline
    match_stage = pipeline.find { |stage| stage["$match"] }

    assert match_stage, "Should have $match stage"
    or_conditions = match_stage["$match"]["$or"]
    assert or_conditions, "Should use $or for not_empty => false"
    assert_equal 3, or_conditions.length, "Should have 3 conditions"

    puts "✅ not_empty => false correctly builds empty/nil check"
  end

  def test_empty_or_nil_requires_boolean
    puts "\n=== Testing empty_or_nil validation ==="

    query = Parse::Query.new("TestClass")

    error = assert_raises(ArgumentError) do
      query.where(:tags.empty_or_nil => "yes")
      query.pipeline
    end

    assert_match(/must be true or false/, error.message)

    puts "✅ empty_or_nil correctly validates boolean input"
  end

  def test_not_empty_requires_boolean
    puts "\n=== Testing not_empty validation ==="

    query = Parse::Query.new("TestClass")

    error = assert_raises(ArgumentError) do
      query.where(:tags.not_empty => "yes")
      query.pipeline
    end

    assert_match(/must be true or false/, error.message)

    puts "✅ not_empty correctly validates boolean input"
  end

  # ==========================================================================
  # Test: Combined constraints (pipeline + regular constraints)
  # ==========================================================================

  def test_combined_constraints_in_pipeline
    puts "\n=== Testing combined constraints in pipeline ==="

    query = Parse::Query.new("TestClass")
    query.where(category: "reports")
    query.where(:tags.empty_or_nil => true)

    # Use build_aggregation_pipeline to test the pipeline structure
    # Returns [pipeline, has_lookup_stages] tuple
    pipeline, _has_lookup_stages = query.send(:build_aggregation_pipeline)

    # Should have $match stages for both constraints
    # (MongoDB efficiently combines multiple $match stages internally)
    match_stages = pipeline.select { |stage| stage.key?("$match") }
    assert match_stages.length >= 1, "Should have at least 1 $match stage"

    # Verify both constraints are present in the pipeline
    all_matches = match_stages.map { |s| s["$match"] }

    # The pipeline combines constraints inside $and when both regular and aggregation constraints exist
    # Check for regular constraint (may be at top level or inside $and)
    has_category = all_matches.any? do |m|
      m["category"] == "reports" ||
        (m["$and"].is_a?(Array) && m["$and"].any? { |c| c["category"] == "reports" })
    end
    assert has_category, "Should include regular category constraint"

    # Check for the $or from empty_or_nil (may be at top level or inside $and)
    has_or = all_matches.any? do |m|
      m["$or"].is_a?(Array) ||
        (m["$and"].is_a?(Array) && m["$and"].any? { |c| c["$or"].is_a?(Array) })
    end
    assert has_or, "Should include $or from empty_or_nil constraint"

    puts "✅ Combined constraints correctly present in pipeline"
  end

  def test_single_aggregation_constraint_not_wrapped_in_and
    puts "\n=== Testing single aggregation constraint (no unnecessary $and) ==="

    query = Parse::Query.new("TestClass")
    query.where(:tags.empty_or_nil => true)

    # Returns [pipeline, has_lookup_stages] tuple
    pipeline, _has_lookup_stages = query.send(:build_aggregation_pipeline)

    match_stages = pipeline.select { |stage| stage.key?("$match") }
    assert_equal 1, match_stages.length, "Should have exactly 1 $match stage"

    match_content = match_stages.first["$match"]

    # Single constraint should NOT be wrapped in $and
    refute match_content.key?("$and"), "Single constraint should not be wrapped in $and"
    assert match_content.key?("$or"), "Should directly have $or from empty_or_nil"

    puts "✅ Single aggregation constraint not wrapped in unnecessary $and"
  end
end
