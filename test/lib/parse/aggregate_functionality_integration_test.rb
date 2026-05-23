require_relative '../../test_helper_integration'
require 'minitest/autorun'

# Test models for aggregate functionality testing
class AggregateFunctionalityUser < Parse::Object
  parse_class "AggregateFunctionalityUser"
  property :name, :string
  property :age, :integer
  property :city, :string
  property :salary, :integer
  property :active, :boolean
end

class AggregateFunctionalityIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  
  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end
  
  def test_aggregate_from_query_converts_standard_query_to_pipeline
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(25, "aggregate_from_query test") do
        puts "\n=== Testing aggregate_from_query: Standard Query to Pipeline ==="
        
        # Create test users
        user1 = AggregateFunctionalityUser.new(name: "Alice", age: 30, city: "Seattle", salary: 90000, active: true)
        user2 = AggregateFunctionalityUser.new(name: "Bob", age: 25, city: "Portland", salary: 75000, active: true)
        user3 = AggregateFunctionalityUser.new(name: "Carol", age: 35, city: "Seattle", salary: 110000, active: false)
        
        assert user1.save, "User 1 should save"
        assert user2.save, "User 2 should save"
        assert user3.save, "User 3 should save"
        
        puts "Created 3 test users"
        
        # Create a query with constraints that would normally be used with .results
        query = AggregateFunctionalityUser.where(:active => true)
                                          .where(:salary.gte => 80000)
                                          .order(:salary.desc)
                                          .limit(5)
        
        puts "Created query: active users with salary >= 80k, ordered by salary desc, limit 5"
        
        # Convert to aggregate pipeline and execute
        aggregation = query.aggregate_from_query
        results = aggregation.results
        
        puts "Aggregate pipeline results: #{results.length} users found"
        
        # Should find user1 (Alice) but not user2 (salary too low) or user3 (inactive)
        assert results.length >= 1, "Should find at least 1 matching user"
        assert results.length <= 2, "Should not find more than 2 users matching criteria"
        
        # Check that results are Parse objects with correct properties
        results.each do |user|
          if user.respond_to?(:active)
            assert user.active == true, "All results should be active users"
          else
            # Handle case where it's a hash
            active_val = user.is_a?(Hash) ? user['active'] : user.attributes['active']
            assert active_val == true, "All results should be active users"
          end
        end
        
        puts "✅ aggregate_from_query successfully converts standard query to pipeline"
      end
    end
  end
  
  def test_aggregate_method_auto_appends_constraints_to_custom_pipeline
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(25, "auto-append constraints test") do
        puts "\n=== Testing aggregate(): Auto-Append Constraints to Custom Pipeline ==="
        
        # Create test users with variety for aggregation
        users_data = [
          { name: "David", age: 40, city: "Seattle", salary: 120000, active: true },
          { name: "Eva", age: 35, city: "Seattle", salary: 100000, active: true },
          { name: "Frank", age: 28, city: "Portland", salary: 85000, active: true },
          { name: "Grace", age: 32, city: "Portland", salary: 95000, active: false },
          { name: "Henry", age: 45, city: "Denver", salary: 130000, active: true }
        ]
        
        users_data.each_with_index do |data, index|
          user = AggregateFunctionalityUser.new(data)
          assert user.save, "User #{index + 1} should save"
        end
        
        puts "Created 5 test users across 3 cities"
        
        # Create query with WHERE and ORDER constraints
        constrained_query = AggregateFunctionalityUser.where(:active => true)
                                                      .where(:salary.gte => 90000)
                                                      .order(:city.asc)
                                                      .limit(3)
        
        puts "Created query: active users with salary >= 90k, ordered by city, limit 3"
        
        # Define custom aggregation pipeline (group by city)
        custom_pipeline = [
          {
            "$group" => {
              "_id" => "$city",
              "userCount" => { "$sum" => 1 },
              "avgSalary" => { "$avg" => "$salary" },
              "users" => { "$push" => "$name" }
            }
          },
          {
            "$sort" => { "avgSalary" => -1 }
          }
        ]
        
        puts "Defined custom pipeline: group by city, calculate avg salary"
        
        # Execute - should auto-prepend WHERE constraints and auto-append ORDER/LIMIT
        aggregation = constrained_query.aggregate(custom_pipeline)
        results = aggregation.results
        
        puts "Custom pipeline with auto-constraints results: #{results.length} cities"
        
        # Should only include cities with active users earning >= 90k
        assert results.length >= 1, "Should find at least 1 city with qualifying users"
        
        # Verify the auto-appended constraints worked
        results.each_with_index do |city_result, index|
          puts "  Result #{index + 1}: #{city_result.class} - #{city_result.inspect}"
          
          # Handle Parse::Object vs Hash results
          if city_result.respond_to?(:attributes)
            city_data = city_result.attributes
          elsif city_result.is_a?(Hash)
            city_data = city_result
          else
            city_data = {}
          end
          
          city_name = city_data['objectId'] || city_result.id rescue nil
          avg_salary = city_data['avgSalary']
          user_count = city_data['userCount']
          
          puts "    City: #{city_name}, Users: #{user_count}, Avg Salary: $#{avg_salary&.to_i}"
          
          # Verify constraints were applied
          if avg_salary
            assert avg_salary >= 90000, "Average salary should be >= 90k due to WHERE constraint"
          end
          if user_count
            assert user_count >= 1, "Should have at least 1 user per city group"
          end
        end
        
        puts "✅ aggregate() method successfully auto-appends query constraints"
      end
    end
  end

  def test_where_followed_by_group_by_pipeline_structure
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do  
      with_timeout(25, "where + group_by pipeline structure test") do
        puts "\n=== Testing WHERE + GROUP_BY Pipeline Structure ==="
        
        # Create test users for pipeline structure verification
        users_data = [
          { name: "Alice", age: 30, city: "Seattle", salary: 95000, active: true },
          { name: "Bob", age: 28, city: "Seattle", salary: 85000, active: true },
          { name: "Carol", age: 35, city: "Portland", salary: 110000, active: true },
          { name: "Dave", age: 32, city: "Portland", salary: 90000, active: false },
          { name: "Eve", age: 29, city: "Denver", salary: 88000, active: true }
        ]
        
        users_data.each_with_index do |data, index|
          user = AggregateFunctionalityUser.new(data)
          assert user.save, "User #{index + 1} should save"
        end
        
        puts "Created 5 test users for pipeline structure testing"
        
        # Create a query with WHERE constraints
        where_query = AggregateFunctionalityUser.where(:active => true)
                                                .where(:salary.gte => 85000)
        
        puts "Created WHERE query: active users with salary >= 85k"
        
        # Define GROUP BY aggregation pipeline
        group_by_pipeline = [
          {
            "$group" => {
              "_id" => "$city",
              "totalUsers" => { "$sum" => 1 },
              "avgSalary" => { "$avg" => "$salary" },
              "minSalary" => { "$min" => "$salary" },
              "maxSalary" => { "$max" => "$salary" },
              "userNames" => { "$push" => "$name" }
            }
          },
          {
            "$sort" => { "avgSalary" => -1 }
          },
          {
            "$project" => {
              "_id" => 1,
              "totalUsers" => 1, 
              "avgSalary" => { "$round" => ["$avgSalary", 0] },
              "salaryRange" => { "$subtract" => ["$maxSalary", "$minSalary"] },
              "userNames" => 1
            }
          }
        ]
        
        puts "Defined GROUP BY pipeline: group by city, calculate stats, sort by avg salary"
        
        # Execute and get the aggregation object to examine pipeline structure
        aggregation = where_query.aggregate(group_by_pipeline)
        actual_pipeline = aggregation.instance_variable_get(:@pipeline)
        
        puts "\n--- Pipeline Structure Examination ---"
        puts "Generated pipeline has #{actual_pipeline.length} stages:"
        
        require 'json'
        actual_pipeline.each_with_index do |stage, index|
          stage_name = stage.keys.first
          puts "  Stage #{index + 1}: #{stage_name}"
        end
        
        puts "\nFull pipeline structure:"
        puts JSON.pretty_generate(actual_pipeline)
        
        # Verify expected pipeline structure
        puts "\n--- Pipeline Structure Verification ---"
        
        # Stage 1: Should be $match from WHERE constraints
        assert actual_pipeline[0].key?("$match"), "First stage should be $match from WHERE constraints"
        match_stage = actual_pipeline[0]["$match"]
        
        assert match_stage.key?("active"), "$match should include active constraint"
        assert_equal true, match_stage["active"], "active should be true"
        
        assert match_stage.key?("salary"), "$match should include salary constraint"
        
        # Handle both flat and nested salary constraint formats, with string or symbol keys
        salary_constraint = match_stage["salary"]
        if salary_constraint.is_a?(Hash)
          # Check for both string and symbol keys
          gte_value = salary_constraint["$gte"] || salary_constraint[:$gte]
          if gte_value
            assert_equal 85000, gte_value, "salary $gte should be 85000"
          else
            puts "  DEBUG: salary constraint structure: #{salary_constraint.inspect}"
            assert false, "salary constraint should have $gte field"
          end
        elsif salary_constraint.is_a?(Integer)
          # Direct value match - this might happen with certain constraint formats
          assert salary_constraint >= 85000, "salary constraint should be >= 85000"
        else
          puts "  DEBUG: salary constraint structure: #{salary_constraint.inspect}"
          assert false, "salary constraint should have recognizable structure"
        end
        
        puts "✅ Stage 1: $match stage correctly applied WHERE constraints"
        
        # Stage 2: Should be $group from custom pipeline
        assert actual_pipeline[1].key?("$group"), "Second stage should be $group from custom pipeline"
        group_stage = actual_pipeline[1]["$group"]
        
        assert_equal "$city", group_stage["_id"], "$group should group by city"
        assert group_stage.key?("totalUsers"), "$group should have totalUsers aggregation"
        assert group_stage.key?("avgSalary"), "$group should have avgSalary aggregation"
        assert group_stage.key?("userNames"), "$group should have userNames aggregation"
        
        puts "✅ Stage 2: $group stage correctly preserves custom aggregation logic"
        
        # Stage 3: Should be $sort from custom pipeline
        assert actual_pipeline[2].key?("$sort"), "Third stage should be $sort from custom pipeline"
        sort_stage = actual_pipeline[2]["$sort"]
        
        assert_equal(-1, sort_stage["avgSalary"], "$sort should sort by avgSalary descending")
        
        puts "✅ Stage 3: $sort stage correctly preserves custom sorting"
        
        # Stage 4: Should be $project from custom pipeline
        assert actual_pipeline[3].key?("$project"), "Fourth stage should be $project from custom pipeline"
        project_stage = actual_pipeline[3]["$project"]
        
        assert project_stage.key?("avgSalary"), "$project should transform avgSalary"
        assert project_stage.key?("salaryRange"), "$project should calculate salaryRange"
        
        puts "✅ Stage 4: $project stage correctly preserves custom projections"
        
        # Verify no extra stages were added (since this query has no order/limit/skip)
        assert_equal 4, actual_pipeline.length, "Pipeline should have exactly 4 stages"
        
        puts "✅ Pipeline length is correct (no extra stages added)"
        
        # Execute the pipeline to verify it works correctly
        puts "\n--- Pipeline Execution Verification ---"
        results = aggregation.results
        puts "Pipeline execution returned #{results.length} city groups"
        
        assert results.length >= 2, "Should find at least 2 cities with qualifying users"
        
        # Verify results structure matches our expectations
        results.each_with_index do |city_result, index|
          # Handle Parse::Object vs Hash results
          if city_result.respond_to?(:attributes)
            city_data = city_result.attributes
            city_id = city_result.id
          elsif city_result.is_a?(Hash)
            city_data = city_result
            city_id = city_result['objectId']
          else
            city_data = {}
            city_id = nil
          end
          
          total_users = city_data['totalUsers']
          avg_salary = city_data['avgSalary']
          user_names = city_data['userNames']
          
          puts "  City #{index + 1}: #{city_id}"
          puts "    Users: #{total_users}, Avg Salary: $#{avg_salary}"
          puts "    Names: #{user_names&.join(', ')}" if user_names
          
          # Verify aggregation worked correctly
          if total_users
            assert total_users >= 1, "Each city should have at least 1 user"
          end
          if avg_salary
            assert avg_salary >= 85000, "Average salary should reflect WHERE constraint (>= 85k)"
          end
        end
        
        puts "\n✅ Pipeline execution produces expected results"
        puts "✅ WHERE + GROUP_BY pipeline structure test completed successfully"
      end
    end
  end

  def test_where_to_aggregate_then_group_by_produces_same_pipeline
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(25, "where.aggregate_from_query + group_by pipeline comparison test") do
        puts "\n=== Testing WHERE.aggregate_from_query + GROUP_BY == WHERE.aggregate(GROUP_BY) ==="
        
        # Create the same WHERE query as before
        where_query = AggregateFunctionalityUser.where(:active => true)
                                                .where(:salary.gte => 85000)
        
        puts "Created WHERE query: active users with salary >= 85k"
        
        # Define the same GROUP BY pipeline stages
        group_by_stages = [
          {
            "$group" => {
              "_id" => "$city",
              "totalUsers" => { "$sum" => 1 },
              "avgSalary" => { "$avg" => "$salary" },
              "minSalary" => { "$min" => "$salary" },
              "maxSalary" => { "$max" => "$salary" },
              "userNames" => { "$push" => "$name" }
            }
          },
          {
            "$sort" => { "avgSalary" => -1 }
          },
          {
            "$project" => {
              "_id" => 1,
              "totalUsers" => 1, 
              "avgSalary" => { "$round" => ["$avgSalary", 0] },
              "salaryRange" => { "$subtract" => ["$maxSalary", "$minSalary"] },
              "userNames" => 1
            }
          }
        ]
        
        puts "Defined GROUP BY stages for comparison"
        
        # Method 1: where_query.aggregate(group_by_stages) - auto-appends WHERE constraints
        aggregation1 = where_query.aggregate(group_by_stages)
        pipeline1 = aggregation1.instance_variable_get(:@pipeline)
        
        puts "\n--- Method 1: where_query.aggregate(group_by_stages) ---"
        puts "Pipeline 1 has #{pipeline1.length} stages"
        
        # Method 2: where_query.aggregate_from_query(group_by_stages) - converts WHERE to pipeline + appends stages
        aggregation2 = where_query.aggregate_from_query(group_by_stages)
        pipeline2 = aggregation2.instance_variable_get(:@pipeline)
        
        puts "\n--- Method 2: where_query.aggregate_from_query(group_by_stages) ---"
        puts "Pipeline 2 has #{pipeline2.length} stages"
        
        # Compare pipeline structures
        puts "\n--- Pipeline Comparison ---"
        
        require 'json'
        puts "\nPipeline 1 (aggregate method):"
        puts JSON.pretty_generate(pipeline1)
        
        puts "\nPipeline 2 (aggregate_from_query method):"
        puts JSON.pretty_generate(pipeline2)
        
        # Verify they are identical
        puts "\n--- Pipeline Identity Verification ---"
        
        assert_equal pipeline1.length, pipeline2.length, "Both pipelines should have the same number of stages"
        puts "✅ Both pipelines have #{pipeline1.length} stages"
        
        # Compare each stage
        pipeline1.each_with_index do |stage1, index|
          stage2 = pipeline2[index]
          stage_name = stage1.keys.first
          
          puts "Comparing Stage #{index + 1}: #{stage_name}"
          
          # Deep comparison of stage content
          assert_equal stage1, stage2, "Stage #{index + 1} (#{stage_name}) should be identical in both pipelines"
          puts "  ✅ Stage #{index + 1} (#{stage_name}) is identical"
        end
        
        puts "\n✅ Both pipelines are structurally identical!"
        
        # Execute both pipelines to verify they produce the same results
        puts "\n--- Result Comparison ---"
        
        results1 = aggregation1.results
        results2 = aggregation2.results
        
        puts "Pipeline 1 results: #{results1.length} cities"
        puts "Pipeline 2 results: #{results2.length} cities"
        
        assert_equal results1.length, results2.length, "Both pipelines should return the same number of results"
        
        # Compare result content (this is tricky with Parse objects, so we'll just verify key metrics)
        if results1.length > 0 && results2.length > 0
          # Sort both result sets by city name for consistent comparison
          sorted_results1 = results1.sort_by { |r| r.respond_to?(:id) ? r.id : r['objectId'] }
          sorted_results2 = results2.sort_by { |r| r.respond_to?(:id) ? r.id : r['objectId'] }
          
          sorted_results1.each_with_index do |result1, index|
            result2 = sorted_results2[index]
            
            # Get city names for comparison
            city1 = result1.respond_to?(:id) ? result1.id : result1['objectId']
            city2 = result2.respond_to?(:id) ? result2.id : result2['objectId']
            
            assert_equal city1, city2, "City names should match in both result sets"
            puts "  ✅ City #{index + 1}: #{city1} appears in both result sets"
          end
        end
        
        puts "\n✅ Both pipelines produce equivalent results!"
        
        puts "\n" + "="*80
        puts "CONCLUSION: where_query.aggregate(stages) == where_query.aggregate_from_query(stages)"
        puts "Both methods produce identical MongoDB aggregation pipelines"
        puts "="*80
      end
    end
  end
end