require_relative "../../test_helper"

class TestEqualsLinkedPointer < Minitest::Test
  extend Minitest::Spec::DSL

  def test_equals_linked_pointer_constraint_exists
    # Test that the constraint is properly registered
    operation = :author.equals_linked_pointer({ through: :project, field: :owner })
    assert_instance_of Parse::Constraint::PointerEqualsLinkedPointerConstraint, operation
    # The constraint is returned directly for equals_linked_pointer
  end

  def test_constraint_build_with_valid_parameters
    constraint = Parse::Constraint::PointerEqualsLinkedPointerConstraint.new(
      :author,
      { through: :project, field: :owner }
    )

    result = constraint.build

    # Should return aggregation pipeline marker
    assert result.key?("__aggregation_pipeline")

    pipeline = result["__aggregation_pipeline"]
    assert_instance_of Array, pipeline
    assert_equal 3, pipeline.length

    # Check $addFields stage (first stage for pointer conversion)
    addfields_stage = pipeline[0]
    assert addfields_stage.key?("$addFields")

    # Check $lookup stage (second stage)
    lookup_stage = pipeline[1]
    assert lookup_stage.key?("$lookup")
    assert_equal "Project", lookup_stage["$lookup"]["from"]
    assert_equal "_p_project", lookup_stage["$lookup"]["localField"]
    assert_equal "_id", lookup_stage["$lookup"]["foreignField"]
    assert_equal "project_data", lookup_stage["$lookup"]["as"]

    # Check $match stage with $expr (third stage)
    match_stage = pipeline[2]
    assert match_stage.key?("$match")
    assert match_stage["$match"].key?("$expr")

    expr = match_stage["$match"]["$expr"]
    assert expr.key?("$eq")
    assert_equal 2, expr["$eq"].length
    assert_equal({ "$arrayElemAt" => ["$project_data._p_owner", 0] }, expr["$eq"][0])
    assert_equal "$_p_author", expr["$eq"][1]
  end

  def test_constraint_build_with_snake_case_fields
    constraint = Parse::Constraint::PointerEqualsLinkedPointerConstraint.new(
      :author_user,
      { through: :project_data, field: :owner_user }
    )

    result = constraint.build
    pipeline = result["__aggregation_pipeline"]

    # Check $addFields stage first
    addfields_stage = pipeline[0]
    assert addfields_stage.key?("$addFields")

    # Check field formatting (snake_case -> camelCase)
    lookup_stage = pipeline[1]
    assert_equal "ProjectDatum", lookup_stage["$lookup"]["from"]  # Rails pluralization: data -> datum
    assert_equal "_p_projectData", lookup_stage["$lookup"]["localField"]
    assert_equal "projectData_data", lookup_stage["$lookup"]["as"]

    match_stage = pipeline[2]
    expr = match_stage["$match"]["$expr"]
    assert_equal({ "$arrayElemAt" => ["$projectData_data._p_ownerUser", 0] }, expr["$eq"][0])
    assert_equal "$_p_authorUser", expr["$eq"][1]
  end

  def test_constraint_validation_missing_through
    constraint = Parse::Constraint::PointerEqualsLinkedPointerConstraint.new(
      :author,
      { field: :owner }
    )

    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_constraint_validation_missing_field
    constraint = Parse::Constraint::PointerEqualsLinkedPointerConstraint.new(
      :author,
      { through: :project }
    )

    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_constraint_validation_invalid_value
    constraint = Parse::Constraint::PointerEqualsLinkedPointerConstraint.new(
      :author,
      "invalid"
    )

    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_query_requires_aggregation_pipeline_detection
    query = Parse::Query.new("ObjectA")

    # Initially should not require pipeline
    refute query.requires_aggregation_pipeline?

    # Add equals_linked_pointer constraint
    query.where(:author.equals_linked_pointer => { through: :project, field: :owner })

    # Debug: check the compiled where clause structure
    compiled_where = query.compile_where
    # puts "Compiled where: #{compiled_where.inspect}"

    # Now should require pipeline
    assert query.requires_aggregation_pipeline?
  end

  def test_query_build_aggregation_pipeline
    query = Parse::Query.new("ObjectA")
    query.where(:author.equals_linked_pointer => { through: :project, field: :owner })

    # build_aggregation_pipeline returns [pipeline, has_lookup_stages] tuple
    pipeline, _has_lookup_stages = query.build_aggregation_pipeline

    assert_instance_of Array, pipeline
    # Pipeline has $match (with $expr), $addFields, and $lookup stages
    assert_equal 3, pipeline.length

    # Stages can be in any order, so look for each type
    addfields_stage = pipeline.find { |s| s.key?("$addFields") }
    assert addfields_stage, "Should have $addFields stage"

    lookup_stage = pipeline.find { |s| s.key?("$lookup") }
    assert lookup_stage, "Should have $lookup stage"

    match_stage = pipeline.find { |s| s.key?("$match") }
    assert match_stage, "Should have $match stage"
    assert match_stage["$match"].key?("$expr")
  end

  def test_query_build_aggregation_pipeline_with_regular_constraints
    query = Parse::Query.new("ObjectA")
    query.where(:status => "active")
    query.where(:author.equals_linked_pointer => { through: :project, field: :owner })

    # build_aggregation_pipeline returns [pipeline, has_lookup_stages] tuple
    pipeline, _has_lookup_stages = query.build_aggregation_pipeline

    assert_instance_of Array, pipeline
    # Pipeline is optimized: regular $match and $expr $match are merged into single $match
    # So we have: merged $match, $addFields, $lookup = 3 stages
    assert_equal 3, pipeline.length

    # The merged $match has both constraints in $and
    match_stage = pipeline.find { |s| s.key?("$match") }
    assert match_stage, "Should have $match stage"

    # The $match should have $and with both constraints merged
    assert match_stage["$match"].key?("$and"), "Match should use $and for merged constraints"
    and_conditions = match_stage["$match"]["$and"]

    # Check for status constraint inside $and
    has_status = and_conditions.any? { |c| c["status"] == "active" }
    assert has_status, "Should have status constraint in $and"

    # Check for $expr constraint inside $and
    has_expr = and_conditions.any? { |c| c.key?("$expr") }
    assert has_expr, "Should have $expr constraint in $and"

    # Should have $addFields stage
    addfields_stage = pipeline.find { |s| s.key?("$addFields") }
    assert addfields_stage, "Should have $addFields stage"

    # Should have $lookup stage
    lookup_stage = pipeline.find { |s| s.key?("$lookup") }
    assert lookup_stage, "Should have $lookup stage"
  end

  def test_query_build_aggregation_pipeline_with_limit_and_skip
    query = Parse::Query.new("ObjectA")
    query.where(:author.equals_linked_pointer => { through: :project, field: :owner })
    query.limit(10)
    query.skip(5)

    # build_aggregation_pipeline returns [pipeline, has_lookup_stages] tuple
    pipeline, _has_lookup_stages = query.build_aggregation_pipeline

    # Should include limit and skip stages
    assert pipeline.any? { |stage| stage.key?("$limit") && stage["$limit"] == 10 }
    assert pipeline.any? { |stage| stage.key?("$skip") && stage["$skip"] == 5 }
  end

  # ===== Tests for DoesNotEqualLinkedPointerConstraint =====

  def test_does_not_equal_linked_pointer_constraint_exists
    # Test that the constraint is properly registered
    operation = :project.does_not_equal_linked_pointer({ through: :capture, field: :project })
    assert_instance_of Parse::Constraint::DoesNotEqualLinkedPointerConstraint, operation
  end

  def test_does_not_equal_constraint_build_with_valid_parameters
    constraint = Parse::Constraint::DoesNotEqualLinkedPointerConstraint.new(
      :project,
      { through: :capture, field: :project }
    )

    result = constraint.build

    # Should return aggregation pipeline marker
    assert result.key?("__aggregation_pipeline")

    pipeline = result["__aggregation_pipeline"]
    assert_instance_of Array, pipeline
    assert_equal 3, pipeline.length

    # Check $addFields stage first
    addfields_stage = pipeline[0]
    assert addfields_stage.key?("$addFields")

    # Check $lookup stage
    lookup_stage = pipeline[1]
    assert lookup_stage.key?("$lookup")
    assert_equal "Capture", lookup_stage["$lookup"]["from"]
    assert_equal "_p_capture", lookup_stage["$lookup"]["localField"]
    assert_equal "_id", lookup_stage["$lookup"]["foreignField"]
    assert_equal "capture_data", lookup_stage["$lookup"]["as"]

    # Check $match stage with $expr using $ne (not equal)
    match_stage = pipeline[2]
    assert match_stage.key?("$match")
    assert match_stage["$match"].key?("$expr")

    expr = match_stage["$match"]["$expr"]
    assert expr.key?("$ne")  # Should use $ne instead of $eq
    assert_equal 2, expr["$ne"].length
    assert_equal({ "$arrayElemAt" => ["$capture_data._p_project", 0] }, expr["$ne"][0])
    assert_equal "$_p_project", expr["$ne"][1]
  end

  def test_does_not_equal_constraint_validation_missing_through
    constraint = Parse::Constraint::DoesNotEqualLinkedPointerConstraint.new(
      :project,
      { field: :project }
    )

    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_does_not_equal_constraint_validation_missing_field
    constraint = Parse::Constraint::DoesNotEqualLinkedPointerConstraint.new(
      :project,
      { through: :capture }
    )

    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_does_not_equal_constraint_validation_invalid_value
    constraint = Parse::Constraint::DoesNotEqualLinkedPointerConstraint.new(
      :project,
      "invalid"
    )

    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_query_with_does_not_equal_linked_pointer_constraint
    query = Parse::Query.new("Asset")
    query.where(:project.does_not_equal_linked_pointer => { through: :capture, field: :project })

    # Should require aggregation pipeline
    assert query.requires_aggregation_pipeline?

    # build_aggregation_pipeline returns [pipeline, has_lookup_stages] tuple
    pipeline, _has_lookup_stages = query.build_aggregation_pipeline
    assert_instance_of Array, pipeline
    assert_equal 3, pipeline.length

    # Stages can be in any order, so look for each type
    addfields_stage = pipeline.find { |s| s.key?("$addFields") }
    assert addfields_stage, "Should have $addFields stage"

    lookup_stage = pipeline.find { |s| s.key?("$lookup") }
    assert lookup_stage, "Should have $lookup stage"

    match_stage = pipeline.find { |s| s.key?("$match") }
    assert match_stage, "Should have $match stage"
    assert match_stage["$match"].key?("$expr")
    assert match_stage["$match"]["$expr"].key?("$ne")
  end

  def test_mixed_equals_and_does_not_equal_constraints
    # Test that both constraint types work together (though this would be an unusual case)
    query = Parse::Query.new("Asset")
    query.where(:status => "active")
    query.where(:project.equals_linked_pointer => { through: :capture, field: :owner })
    query.where(:creator.does_not_equal_linked_pointer => { through: :capture, field: :creator })

    assert query.requires_aggregation_pipeline?

    # build_aggregation_pipeline returns [pipeline, has_lookup_stages] tuple
    pipeline, _has_lookup_stages = query.build_aggregation_pipeline

    # Pipeline is optimized: all consecutive $match stages are merged
    # Should have: merged $match, $addFields (x2), $lookup (x2) = 5 stages
    assert pipeline.length >= 4, "Pipeline should have at least 4 stages"

    # The $match stage should contain the status constraint (possibly merged with $expr)
    match_stage = pipeline.find { |s| s.key?("$match") }
    assert match_stage, "Should have $match stage"

    # Status constraint can be at top level or inside $and (if merged)
    match_content = match_stage["$match"]
    has_status = match_content["status"] == "active" ||
      (match_content["$and"].is_a?(Array) && match_content["$and"].any? { |c| c["status"] == "active" })
    assert has_status, "Should have $match for status constraint"
  end
end
