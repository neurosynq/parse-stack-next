require_relative '../../test_helper'

class ACLConstraintsUnitTest < Minitest::Test
  
  def test_readable_by_constraint_generates_aggregation_pipeline
    puts "\n=== Testing ACL readable_by Constraint Generation ==="
    
    # Test single role string - should now generate aggregation pipeline
    query = Parse::Query.new("Post")
    query.readable_by("Admin")
    
    # Should not have regular where clause for ACL constraints
    compiled = query.compile
    
    # Should generate aggregation pipeline instead
    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["role:Admin", "*"] } },
            { "_rperm" => { "$exists" => false } }
          ]
        }
      }
    ]
    
    assert_equal expected_pipeline, pipeline, "Should generate aggregation pipeline for ACL constraints"
    puts "✅ Single role constraint generates pipeline: #{pipeline.inspect}"
    
    # Test multiple roles
    query2 = Parse::Query.new("Post")
    query2.readable_by(["Admin", "Editor"])
    
    pipeline2 = query2.pipeline
    expected_pipeline2 = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["role:Admin", "role:Editor", "*"] } },
            { "_rperm" => { "$exists" => false } }
          ]
        }
      }
    ]
    
    assert_equal expected_pipeline2, pipeline2, "Should generate aggregation pipeline for multiple roles"
    puts "✅ Multiple roles constraint generates pipeline: #{pipeline2.inspect}"
  end
  
  def test_writable_by_constraint_generates_aggregation_pipeline
    puts "\n=== Testing ACL writable_by Constraint Generation ==="
    
    # Test single role string - should now generate aggregation pipeline
    query = Parse::Query.new("Post")
    query.writable_by("Admin")
    
    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_wperm" => { "$in" => ["role:Admin", "*"] } },
            { "_wperm" => { "$exists" => false } }
          ]
        }
      }
    ]
    
    assert_equal expected_pipeline, pipeline, "Should generate aggregation pipeline for writable constraint"
    puts "✅ Single role writable constraint generates pipeline: #{pipeline.inspect}"
    
    # Test multiple roles
    query2 = Parse::Query.new("Post")
    query2.writable_by(["Admin", "Editor"])
    
    pipeline2 = query2.pipeline
    expected_pipeline2 = [
      {
        "$match" => {
          "$or" => [
            { "_wperm" => { "$in" => ["role:Admin", "role:Editor", "*"] } },
            { "_wperm" => { "$exists" => false } }
          ]
        }
      }
    ]
    
    assert_equal expected_pipeline2, pipeline2, "Should generate aggregation pipeline for multiple writable roles"
    puts "✅ Multiple roles writable constraint generates pipeline: #{pipeline2.inspect}"
  end
  
  def test_pipeline_method_returns_stages_for_acl_constraints
    puts "\n=== Testing Pipeline Method ==="
    
    # ACL constraints should now use aggregation pipelines to access _rperm/_wperm fields
    query = Parse::Query.new("Post")
    query.readable_by("Admin")
    
    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["role:Admin", "*"] } },
            { "_rperm" => { "$exists" => false } }
          ]
        }
      }
    ]
    
    assert_equal expected_pipeline, pipeline, "ACL constraints should generate aggregation pipelines"
    assert query.requires_aggregation?, "Query should require aggregation"
    puts "✅ Pipeline method returns aggregation stages for ACL constraints"
    puts "Pipeline: #{pipeline.inspect}"
  end
  
  def test_constraint_chaining_with_acl
    puts "\n=== Testing ACL Constraint Chaining ==="
    
    # Test chaining ACL constraints with other constraints
    query = Parse::Query.new("Post")
    query.where(:title.in => ["Post 1", "Post 2"])
    query.readable_by("Admin")
    query.where(:published => true)
    
    compiled = query.compile
    puts "✅ Chained constraints: #{compiled[:where]}"
    
    # Should contain both regular constraints and ACL constraint
    assert compiled[:where].include?("_rperm"), "Should include _rperm constraint"
    assert compiled[:where].include?('"published":true'), "Should include regular constraints"
    assert compiled[:where].include?('"title":{"$in":["Post 1","Post 2"]}'), "Should include in constraint"
  end
  
end