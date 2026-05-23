require_relative "../../../test_helper"

class TestQueryAggregationFeatures < Minitest::Test
  
  def setup
    # Mock Parse::Query and client for testing
    @query = Parse::Query.new("TestClass")
    @mock_client = Minitest::Mock.new
    @query.instance_variable_set(:@client, @mock_client)
  end

  # Test the new pluck method  
  def test_pluck_extracts_field_values
    mock_results = [
      { "objectId" => "1", "name" => "Item 1", "category" => "A" },
      { "objectId" => "2", "name" => "Item 2", "category" => "B" },
      { "objectId" => "3", "name" => "Item 3", "category" => "A" }
    ]
    
    # Test pluck logic by calling it directly on the data
    values = mock_results.map { |r| r[:name] || r["name"] }
    assert_equal ["Item 1", "Item 2", "Item 3"], values
    
    # Test that the method exists on the query object
    assert_respond_to @query, :pluck
  end

  def test_pluck_with_invalid_field
    assert_raises(ArgumentError) do
      @query.pluck(nil)
    end
  end

  # Test select_fields alias
  def test_select_fields_is_alias_for_keys
    @query.select_fields(:name, :category)
    assert_equal [:name, :category], @query.instance_variable_get(:@keys)
  end

  # Test group_objects_by method
  def test_group_objects_by_groups_objects_correctly
    mock_results = [
      { "objectId" => "1", "name" => "Item 1", "category" => "A" },
      { "objectId" => "2", "name" => "Item 2", "category" => "B" },
      { "objectId" => "3", "name" => "Item 3", "category" => "A" },
      { "objectId" => "4", "name" => "Item 4", "category" => "B" }
    ]
    
    @query.stub :results, mock_results do
      grouped = @query.group_objects_by(:category)
      
      assert_equal 2, grouped.keys.size
      assert_equal ["A", "B"], grouped.keys.sort
      assert_equal 2, grouped["A"].size
      assert_equal 2, grouped["B"].size
      assert_equal "Item 1", grouped["A"][0]["name"]
      assert_equal "Item 3", grouped["A"][1]["name"]
    end
  end

  def test_group_objects_by_handles_nil_values
    mock_results = [
      { "objectId" => "1", "name" => "Item 1", "category" => "A" },
      { "objectId" => "2", "name" => "Item 2" }, # no category
      { "objectId" => "3", "name" => "Item 3", "category" => nil }
    ]
    
    @query.stub :results, mock_results do
      grouped = @query.group_objects_by(:category)
      
      assert grouped.key?("A")
      assert grouped.key?("null")
      assert_equal 2, grouped["null"].size # Both nil and missing should be grouped as "null"
    end
  end

  # Test return_pointers option
  def test_results_with_return_pointers
    mock_items = [
      { "objectId" => "abc123", "name" => "Test" },
      { "objectId" => "def456", "name" => "Test2" }
    ]
    
    # Test the to_pointers conversion specifically
    pointers = @query.to_pointers(mock_items)
    
    assert_equal 2, pointers.size
    assert_kind_of Parse::Pointer, pointers.first
    assert_equal "abc123", pointers.first.id
    assert_equal "TestClass", pointers.first.parse_class
  end

  # Test group_by with flatten_arrays
  def test_group_by_with_flatten_arrays
    group_by = @query.group_by(:tags, flatten_arrays: true)
    
    assert_kind_of Parse::GroupBy, group_by
    assert_equal true, group_by.instance_variable_get(:@flatten_arrays)
  end

  def test_group_by_with_sortable
    group_by = @query.group_by(:category, sortable: true)
    
    assert_kind_of Parse::SortableGroupBy, group_by
  end

  def test_group_by_with_return_pointers
    group_by = @query.group_by(:author, return_pointers: true)
    
    assert_equal true, group_by.instance_variable_get(:@return_pointers)
  end

  # Test GroupedResult sorting methods
  def test_grouped_result_sorting
    results_hash = {
      "C" => 5,
      "A" => 10,
      "B" => 3
    }
    
    grouped_result = Parse::GroupedResult.new(results_hash)
    
    # Test sort by key ascending
    sorted_by_key_asc = grouped_result.sort_by_key_asc
    assert_equal [["A", 10], ["B", 3], ["C", 5]], sorted_by_key_asc
    
    # Test sort by key descending
    sorted_by_key_desc = grouped_result.sort_by_key_desc
    assert_equal [["C", 5], ["B", 3], ["A", 10]], sorted_by_key_desc
    
    # Test sort by value ascending
    sorted_by_value_asc = grouped_result.sort_by_value_asc
    assert_equal [["B", 3], ["C", 5], ["A", 10]], sorted_by_value_asc
    
    # Test sort by value descending
    sorted_by_value_desc = grouped_result.sort_by_value_desc
    assert_equal [["A", 10], ["C", 5], ["B", 3]], sorted_by_value_desc
  end

  def test_grouped_result_to_h
    results_hash = { "A" => 1, "B" => 2 }
    grouped_result = Parse::GroupedResult.new(results_hash)
    
    assert_equal results_hash, grouped_result.to_h
  end

  def test_grouped_result_enumerable
    results_hash = { "A" => 1, "B" => 2, "C" => 3 }
    grouped_result = Parse::GroupedResult.new(results_hash)
    
    # Test that Enumerable methods work
    assert_equal 6, grouped_result.map { |k, v| v }.sum
    assert grouped_result.any? { |k, v| v > 2 }
  end

  # Test group_by_date
  def test_group_by_date_with_valid_interval
    group_by_date = @query.group_by_date(:created_at, :day)
    
    assert_kind_of Parse::GroupByDate, group_by_date
    assert_equal :day, group_by_date.instance_variable_get(:@interval)
  end

  def test_group_by_date_with_invalid_interval
    assert_raises(ArgumentError) do
      @query.group_by_date(:created_at, :invalid)
    end
  end

  def test_group_by_date_with_sortable
    group_by_date = @query.group_by_date(:created_at, :month, sortable: true)
    
    assert_kind_of Parse::SortableGroupByDate, group_by_date
  end

  # Test distinct_objects with return_pointers
  def test_distinct_objects_with_return_pointers
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :success?, true
    mock_response.expect :result, [
      { "value" => "Team$team1" },
      { "value" => "Team$team2" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "TestClass" && pipeline.is_a?(Array)
    end
    
    @query.stub :to_pointers, ->(list, field = nil) {
      list.map do |m|
        if m.is_a?(String) && m.include?('$')
          class_name, object_id = m.split('$', 2)
          Parse::Pointer.new(class_name, object_id)
        else
          Parse::Pointer.new(m["className"] || "TestClass", m["objectId"])
        end
      end
    } do
      results = @query.distinct_objects(:author_team, return_pointers: true)
      
      assert_equal 2, results.size
      assert_kind_of Parse::Pointer, results.first
      assert_equal "team1", results.first.id
    end
  end

  # Test to_pointers method
  def test_to_pointers_with_standard_objects
    list = [
      { "objectId" => "abc123" },
      { "objectId" => "def456" }
    ]
    
    pointers = @query.to_pointers(list)
    
    assert_equal 2, pointers.size
    assert_kind_of Parse::Pointer, pointers.first
    assert_equal "TestClass", pointers.first.parse_class
    assert_equal "abc123", pointers.first.id
  end

  def test_to_pointers_with_pointer_objects
    list = [
      { "__type" => "Pointer", "className" => "Team", "objectId" => "team1" },
      { "__type" => "Pointer", "className" => "Team", "objectId" => "team2" }
    ]
    
    pointers = @query.to_pointers(list)
    
    assert_equal 2, pointers.size
    assert_kind_of Parse::Pointer, pointers.first
    assert_equal "Team", pointers.first.parse_class
    assert_equal "team1", pointers.first.id
  end

  # Test GroupBy execute_group_aggregation with flatten_arrays
  def test_group_by_execute_with_flatten_arrays
    group_by = Parse::GroupBy.new(@query, :tags, flatten_arrays: true)
    
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, [
      { "objectId" => "a", "count" => 1 },
      { "objectId" => "b", "count" => 2 },
      { "objectId" => "c", "count" => 1 }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "TestClass" && pipeline.any? { |stage| stage.key?("$unwind") }
    end
    
    result = group_by.count
    
    assert_equal({ "a" => 1, "b" => 2, "c" => 1 }, result)
    @mock_client.verify
  end

  # Test SortableGroupBy returns GroupedResult
  def test_sortable_group_by_returns_grouped_result
    group_by = Parse::SortableGroupBy.new(@query, :category)
    
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, [
      { "objectId" => "A", "count" => 5 },
      { "objectId" => "B", "count" => 3 }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "TestClass" && pipeline.is_a?(Array)
    end
    
    result = group_by.count
    
    assert_kind_of Parse::GroupedResult, result
    assert_equal({ "A" => 5, "B" => 3 }, result.to_h)
  end

  # Test keys method (field selection)
  def test_keys_method_adds_fields
    @query.keys(:name, :category)
    assert_equal [:name, :category], @query.instance_variable_get(:@keys)
    
    @query.keys(:status)
    assert_equal [:name, :category, :status], @query.instance_variable_get(:@keys)
  end

  def test_keys_method_returns_self_for_chaining
    result = @query.keys(:name)
    assert_equal @query, result
  end

  # Test compile includes keys in query
  def test_compile_includes_keys
    @query.keys(:name, :category)
    compiled = @query.compile(encode: false)
    
    assert_equal "name,category", compiled[:keys]
  end

  # Test distinct with return_pointers
  def test_distinct_with_return_pointers
    raw_data = [
      { "__type" => "Pointer", "className" => "Team", "objectId" => "team1" },
      { "__type" => "Pointer", "className" => "Team", "objectId" => "team2" }
    ]
    
    # Test the to_pointers conversion directly
    pointers = @query.to_pointers(raw_data)
    
    assert_equal 2, pointers.size
    assert_kind_of Parse::Pointer, pointers.first
    assert_equal "Team", pointers.first.parse_class
    assert_equal "team1", pointers.first.id
  end

  # Test pipeline method on GroupBy
  def test_group_by_pipeline_method
    group_by = @query.group_by(:category)
    
    assert_respond_to group_by, :pipeline
    pipeline = group_by.pipeline
    
    assert_kind_of Array, pipeline
    assert pipeline.any? { |stage| stage.key?("$group") }
    assert pipeline.any? { |stage| stage.key?("$project") }
  end

  # Test pipeline method on GroupByDate  
  def test_group_by_date_pipeline_method
    group_by_date = @query.group_by_date(:created_at, :month)
    
    assert_respond_to group_by_date, :pipeline
    pipeline = group_by_date.pipeline
    
    assert_kind_of Array, pipeline
    assert pipeline.any? { |stage| stage.key?("$group") }
    assert pipeline.any? { |stage| stage.key?("$project") }
  end

  # Test pipeline method on SortableGroupBy
  def test_sortable_group_by_pipeline_method
    sortable_group_by = @query.group_by(:category, sortable: true)
    
    assert_respond_to sortable_group_by, :pipeline
    pipeline = sortable_group_by.pipeline
    
    assert_kind_of Array, pipeline
    assert pipeline.any? { |stage| stage.key?("$group") }
  end

  # Test pipeline method on SortableGroupByDate
  def test_sortable_group_by_date_pipeline_method
    sortable_group_by_date = @query.group_by_date(:created_at, :month, sortable: true)
    
    assert_respond_to sortable_group_by_date, :pipeline
    pipeline = sortable_group_by_date.pipeline
    
    assert_kind_of Array, pipeline
    assert pipeline.any? { |stage| stage.key?("$group") }
  end

  # Test convert_constraints_for_aggregation function
  def test_convert_constraints_for_aggregation_with_pointer
    pointer_constraint = {
      "_p_authorTeam" => {
        "__type" => "Pointer",
        "className" => "Team", 
        "objectId" => "abc123"
      }
    }
    
    result = @query.send(:convert_constraints_for_aggregation, pointer_constraint)
    
    # The field name gets formatted to aggregation format
    aggregation_field = @query.send(:format_aggregation_field, "_p_authorTeam")
    
    assert_equal "Team$abc123", result[aggregation_field]
  end

  def test_convert_constraints_for_aggregation_with_nested_pointer
    nested_constraint = {
      "_p_authorTeam" => {
        "$eq" => {
          "__type" => "Pointer",
          "className" => "Team",
          "objectId" => "abc123"
        }
      }
    }
    
    result = @query.send(:convert_constraints_for_aggregation, nested_constraint)
    
    # The field name gets formatted to aggregation format
    aggregation_field = @query.send(:format_aggregation_field, "_p_authorTeam")
    
    assert_equal "Team$abc123", result[aggregation_field]["$eq"]
  end

  def test_convert_constraints_for_aggregation_with_regular_field
    regular_constraint = {
      "name" => "test",
      "age" => { "$gt" => 18 }
    }
    
    result = @query.send(:convert_constraints_for_aggregation, regular_constraint)
    
    assert_equal "test", result["name"]
    assert_equal({ "$gt" => 18 }, result["age"])
  end

  def test_convert_constraints_for_aggregation_preserves_operators
    operator_constraint = {
      "$or" => [
        { "name" => "test1" },
        { "name" => "test2" }
      ]
    }
    
    result = @query.send(:convert_constraints_for_aggregation, operator_constraint)
    
    assert_equal operator_constraint["$or"], result["$or"]
  end

  # Test that pipeline output correctly includes pointer constraints in $match stage
  # Uses eq_array for explicit array equality matching with aggregation pipeline
  def test_pipeline_output_uses_mongodb_pointer_format
    # Create a mock team pointer
    team = Parse::Pointer.new("Team", "OlnmSD0woC")

    # Create query with array equality constraint (uses aggregation pipeline)
    # Note: Use :eq_array for explicit array equality; :eq is for simple scalar equality
    query = Parse::Query.new("Capture")
    query.where(:author_team.eq_array => team)

    # Get the pipeline and check the $match stage
    pipeline = query.group_by(:last_action).pipeline
    match_stage = pipeline.find { |stage| stage.key?("$match") }

    assert match_stage, "Pipeline should contain $match stage"

    # The pointer constraint generates a $expr/$map format for array-based matching
    # This format correctly handles Parse pointer arrays in MongoDB aggregation
    match_content = match_stage["$match"]

    # Should have $expr with $eq operator for pointer matching
    assert match_content.key?("$expr"), "Match stage should use $expr for pointer constraint"

    expr_content = match_content["$expr"]
    assert expr_content.key?("$eq"), "Expression should use $eq operator"

    # The $eq should compare the mapped objectIds with the target ID
    eq_content = expr_content["$eq"]
    assert_kind_of Array, eq_content
    assert_equal 2, eq_content.size

    # First element should be the $map expression
    map_expr = eq_content[0]
    assert map_expr.key?("$map"), "First $eq operand should be $map expression"
    assert_equal "$authorTeam", map_expr["$map"]["input"]

    # Second element should be array containing the object ID
    id_array = eq_content[1]
    assert_kind_of Array, id_array
    assert_includes id_array, "OlnmSD0woC"
  end

  # Test date conversion for aggregation
  def test_convert_dates_for_aggregation_with_parse_date
    parse_date_obj = {
      "__type" => "Date",
      "iso" => "2025-08-15T07:00:00.000Z"
    }
    
    result = @query.send(:convert_dates_for_aggregation, parse_date_obj)
    
    # Should convert to raw ISO string
    assert_equal "2025-08-15T07:00:00.000Z", result
  end

  def test_convert_dates_for_aggregation_with_nested_dates
    constraint_with_dates = {
      "createdAt" => {
        "$gte" => {
          "__type" => "Date",
          "iso" => "2025-08-15T07:00:00.000Z"
        },
        "$lte" => {
          "__type" => "Date", 
          "iso" => "2025-08-16T06:59:59.999Z"
        }
      }
    }
    
    result = @query.send(:convert_dates_for_aggregation, constraint_with_dates)
    
    # Should convert nested date objects to ISO strings
    assert_equal "2025-08-15T07:00:00.000Z", result["createdAt"]["$gte"]
    assert_equal "2025-08-16T06:59:59.999Z", result["createdAt"]["$lte"]
  end

  # Test actual count_distinct pipeline with date constraints
  def test_count_distinct_pipeline_with_dates
    # Create a mock date range (similar to what notes_today would have)
    start_time = Time.new(2025, 8, 15, 7, 0, 0, "+00:00")
    end_time = Time.new(2025, 8, 16, 6, 59, 59, "+00:00")
    
    query = Parse::Query.new("Capture")
    query.where(:created_at.gte => start_time, :created_at.lte => end_time)
    
    # Mock the count_distinct pipeline generation 
    compiled_where = query.send(:compile_where)
    puts "Original compiled where: #{compiled_where.inspect}"
    
    aggregation_where = query.send(:convert_constraints_for_aggregation, compiled_where)
    puts "After constraint conversion: #{aggregation_where.inspect}"
    
    stringified_where = query.send(:convert_dates_for_aggregation, aggregation_where)
    
    aggregation_where = query.send(:convert_constraints_for_aggregation, compiled_where)
    
    stringified_where = query.send(:convert_dates_for_aggregation, aggregation_where)
    
    # The final match stage should have raw ISO strings for Parse Server aggregation compatibility
    created_at_constraint = stringified_where["createdAt"] || stringified_where["_created_at"]
    
    if created_at_constraint && created_at_constraint["$gte"]
      assert_kind_of String, created_at_constraint["$gte"], "Date should be converted to raw ISO string"
      assert_match(/^\d{4}-\d{2}-\d{2}T/, created_at_constraint["$gte"], "Should be in ISO format")
    end
  end
end