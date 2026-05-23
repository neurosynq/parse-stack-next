require_relative "../../../test_helper"

class TestGroupByAggregation < Minitest::Test
  
  def setup
    @query = Parse::Query.new("Asset")
    @mock_client = Minitest::Mock.new
    @query.instance_variable_set(:@client, @mock_client)
  end

  # Test GroupBy aggregation pipeline building
  def test_group_by_count_builds_correct_pipeline
    group_by = Parse::GroupBy.new(@query, :category)
    
    expected_pipeline = [
      { "$group" => { "_id" => "$category", "count" => { "$sum" => 1 } } },
      { "$project" => { "_id" => 0, "objectId" => "$_id", "count" => 1 } }
    ]
    
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, []
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && pipeline == expected_pipeline
    end
    
    group_by.count
    @mock_client.verify
  end

  def test_group_by_sum_builds_correct_pipeline
    group_by = Parse::GroupBy.new(@query, :project)
    
    expected_pipeline = [
      { "$group" => { "_id" => "$project", "count" => { "$sum" => "$fileSize" } } },
      { "$project" => { "_id" => 0, "objectId" => "$_id", "count" => 1 } }
    ]
    
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, []
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && pipeline.any? { |stage| 
        stage["$group"] && stage["$group"]["count"]["$sum"] == "$fileSize"
      }
    end
    
    group_by.sum(:file_size)
    @mock_client.verify
  end

  def test_group_by_average_builds_correct_pipeline
    group_by = Parse::GroupBy.new(@query, :category)
    
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, []
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && pipeline.any? { |stage| 
        stage["$group"] && stage["$group"]["count"]["$avg"] == "$duration"
      }
    end
    
    group_by.average(:duration)
    @mock_client.verify
  end

  def test_group_by_min_max_operations
    group_by = Parse::GroupBy.new(@query, :category)
    
    # Test min
    mock_response_min = Minitest::Mock.new
    mock_response_min.expect :success?, true
    mock_response_min.expect :result, [{ "objectId" => "video", "count" => 30 }]
    
    @mock_client.expect :aggregate_pipeline, mock_response_min do |table, pipeline, **kwargs|
      table == "Asset" && pipeline.any? { |stage| 
        stage["$group"] && stage["$group"]["count"]["$min"]
      }
    end
    
    result = group_by.min(:duration)
    assert_equal({ "video" => 30 }, result)
    
    # Test max
    mock_response_max = Minitest::Mock.new
    mock_response_max.expect :success?, true
    mock_response_max.expect :result, [{ "objectId" => "video", "count" => 180 }]
    
    @mock_client.expect :aggregate_pipeline, mock_response_max do |table, pipeline, **kwargs|
      table == "Asset" && pipeline.any? { |stage| 
        stage["$group"] && stage["$group"]["count"]["$max"]
      }
    end
    
    result = group_by.max(:duration)
    assert_equal({ "video" => 180 }, result)
    
    @mock_client.verify
  end

  # Test flatten_arrays option adds $unwind stage
  def test_flatten_arrays_adds_unwind_stage
    group_by = Parse::GroupBy.new(@query, :tags, flatten_arrays: true)
    
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, [
      { "objectId" => "nature", "count" => 5 },
      { "objectId" => "city", "count" => 3 }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && begin
        # Should have $unwind stage before $group
        unwind_index = pipeline.find_index { |stage| stage.key?("$unwind") }
        group_index = pipeline.find_index { |stage| stage.key?("$group") }
        
        unwind_index && group_index && unwind_index < group_index &&
        pipeline[unwind_index]["$unwind"] == "$tags"
      end
    end
    
    result = group_by.count
    assert_equal({ "nature" => 5, "city" => 3 }, result)
    @mock_client.verify
  end

  # Test with where conditions adds $match stage
  def test_group_by_with_where_conditions
    @query.where(:status => "active")
    group_by = Parse::GroupBy.new(@query, :category)
    
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, []
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && pipeline.first.key?("$match") && 
      pipeline.first["$match"]["status"] == "active"
    end
    
    group_by.count
    @mock_client.verify
  end

  # Test return_pointers option converts keys
  def test_group_by_with_return_pointers
    group_by = Parse::GroupBy.new(@query, :author_team, return_pointers: true)
    
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, [
      { 
        "objectId" => { 
          "__type" => "Pointer", 
          "className" => "Team", 
          "objectId" => "team1" 
        }, 
        "count" => 5 
      }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && pipeline.is_a?(Array)
    end
    
    result = group_by.count
    
    # The key should be converted to a Parse::Pointer
    assert_equal 1, result.size
    pointer_key = result.keys.first
    assert_kind_of Parse::Pointer, pointer_key
    assert_equal "Team", pointer_key.parse_class
    assert_equal "team1", pointer_key.id
    assert_equal 5, result[pointer_key]
    
    @mock_client.verify
  end

  # Test handling of nil/null group keys
  def test_group_by_handles_null_keys
    group_by = Parse::GroupBy.new(@query, :optional_field)
    
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, [
      { "objectId" => nil, "count" => 3 },
      { "objectId" => "value", "count" => 2 }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && pipeline.is_a?(Array)
    end
    
    result = group_by.count
    
    assert_equal({ "null" => 3, "value" => 2 }, result)
    @mock_client.verify
  end

  # Test GroupByDate functionality
  def test_group_by_date_with_different_intervals
    intervals = [:year, :month, :week, :day, :hour]
    
    intervals.each do |interval|
      group_by_date = @query.group_by_date(:created_at, interval)
      
      assert_equal interval, group_by_date.instance_variable_get(:@interval)
      assert_kind_of Parse::GroupByDate, group_by_date
    end
  end

  def test_group_by_date_builds_correct_pipeline
    group_by_date = Parse::GroupByDate.new(@query, :created_at, :month)
    
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    # Allow result to be called multiple times
    mock_response.expect :result, [
      { "objectId" => { "year" => 2024, "month" => 11 }, "count" => 45 }
    ]
    mock_response.expect :result, [
      { "objectId" => { "year" => 2024, "month" => 11 }, "count" => 45 }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && begin
        # Should have $group with date operators
        group_stage = pipeline.find { |stage| stage.key?("$group") }
        group_stage && group_stage["$group"]["_id"]["year"] && 
        group_stage["$group"]["_id"]["month"]
      end
    end
    
    result = group_by_date.count
    
    assert_equal({ "2024-11" => 45 }, result)
    @mock_client.verify
  end

  # Test chaining of where conditions with group_by
  def test_chaining_where_with_group_by
    result = @query
      .where(:status => "active")
      .where(:category.in => ["video", "audio"])
      .group_by(:project)
    
    assert_kind_of Parse::GroupBy, result
    
    # Verify where conditions are preserved
    compiled_where = @query.send(:compile_where)
    assert compiled_where["status"]
    assert compiled_where["category"]
  end

  # Test error handling
  def test_group_by_with_invalid_field
    assert_raises(ArgumentError) do
      @query.group_by(nil)
    end
    
    assert_raises(ArgumentError) do
      @query.group_by_date(nil, :day)
    end
  end

  def test_aggregation_methods_with_invalid_field
    group_by = @query.group_by(:category)
    
    assert_raises(ArgumentError) do
      group_by.sum(nil)
    end
    
    assert_raises(ArgumentError) do
      group_by.average(nil)
    end
    
    assert_raises(ArgumentError) do
      group_by.min(nil)
    end
    
    assert_raises(ArgumentError) do
      group_by.max(nil)
    end
  end

  # Test chaining where conditions with date constraints and group_by_date
  def test_chaining_date_filters_with_group_by_date
    # Set up date range
    start_time = Time.new(2025, 8, 1, 0, 0, 0, "+00:00")
    end_time = Time.new(2025, 8, 31, 23, 59, 59, "+00:00")
    
    # Create query with date filters
    result = @query
      .where(:created_at.gte => start_time)
      .where(:created_at.lte => end_time)
      .where(:status => "active")
      .group_by_date(:created_at, :day)
    
    assert_kind_of Parse::GroupByDate, result
    
    # Verify where conditions are preserved in the query
    compiled_where = @query.send(:compile_where)
    assert compiled_where["createdAt"], "createdAt filter should be present"
    assert compiled_where["status"], "status filter should be present"
    
    # Check that date constraints have the correct format
    created_at_constraint = compiled_where["createdAt"]
    assert created_at_constraint[:$gte], "Should have $gte constraint"
    assert created_at_constraint[:$lte], "Should have $lte constraint"
    
    # Verify the date format is Parse Date format
    gte_constraint = created_at_constraint[:$gte]
    lte_constraint = created_at_constraint[:$lte]
    
    assert_equal "Date", gte_constraint[:__type], "Should have Parse Date type"
    assert gte_constraint[:iso], "Should have ISO string"
    assert_equal "Date", lte_constraint[:__type], "Should have Parse Date type" 
    assert lte_constraint[:iso], "Should have ISO string"
  end

  # Test that the aggregation pipeline properly handles date filters for match stages
  def test_group_by_date_with_date_filters_pipeline_generation
    start_time = Time.new(2025, 8, 1, 0, 0, 0, "+00:00")
    end_time = Time.new(2025, 8, 31, 23, 59, 59, "+00:00")
    
    query = @query
      .where(:created_at.gte => start_time)
      .where(:created_at.lte => end_time)
      .where(:status => "active")
    
    group_by_date = Parse::GroupByDate.new(query, :created_at, :day)
    
    # Mock response
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    # Allow result to be called multiple times
    mock_response.expect :result, [
      { "objectId" => { "year" => 2025, "month" => 8, "day" => 1 }, "count" => 10 },
      { "objectId" => { "year" => 2025, "month" => 8, "day" => 2 }, "count" => 15 }
    ]
    mock_response.expect :result, [
      { "objectId" => { "year" => 2025, "month" => 8, "day" => 1 }, "count" => 10 },
      { "objectId" => { "year" => 2025, "month" => 8, "day" => 2 }, "count" => 15 }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && begin
        # Should have $match stage with date constraints
        match_stage = pipeline.find { |stage| stage.key?("$match") }

        if match_stage
          created_at_match = match_stage["$match"]["createdAt"]
          status_match = match_stage["$match"]["status"]

          # Verify date constraints are present (could be ISO string or symbol keys)
          # The actual format depends on how the query is compiled
          gte_value = created_at_match[:$gte] || created_at_match["$gte"]
          lte_value = created_at_match[:$lte] || created_at_match["$lte"]

          created_at_match &&
          gte_value.is_a?(String) &&  # ISO date string format
          lte_value.is_a?(String) &&  # ISO date string format
          status_match == "active"
        else
          false
        end
      end
    end
    
    result = group_by_date.count
    
    expected_result = { "2025-08-01" => 10, "2025-08-02" => 15 }
    assert_equal expected_result, result
    @mock_client.verify
  end
end