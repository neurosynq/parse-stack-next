require_relative "../../test_helper"

class ACLConstraintsUnitTest < Minitest::Test
  def test_readable_by_constraint_generates_aggregation_pipeline
    puts "\n=== Testing ACL readable_by Constraint Generation ==="

    # Test single string - readable_by uses strings as-is (user IDs, role names with prefix, or "*")
    # Note: The constraint automatically includes "*" (public access) and checks for missing _rperm
    query = Parse::Query.new("Post")
    query.readable_by("role:Admin")  # Explicit role prefix

    # Should generate aggregation pipeline with $or for public access fallback
    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["role:Admin", "*"] } },
            { "_rperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "Should generate aggregation pipeline for ACL constraints"
    puts "✅ Single role constraint generates pipeline: #{pipeline.inspect}"

    # Test multiple values (mix of user IDs and role names)
    query2 = Parse::Query.new("Post")
    query2.readable_by(["user123", "role:Editor"])

    pipeline2 = query2.pipeline
    expected_pipeline2 = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["user123", "role:Editor", "*"] } },
            { "_rperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline2, pipeline2, "Should generate aggregation pipeline for mixed values"
    puts "✅ Multiple values constraint generates pipeline: #{pipeline2.inspect}"
  end

  def test_writable_by_constraint_generates_aggregation_pipeline
    puts "\n=== Testing ACL writable_by Constraint Generation ==="

    # Test single string - writable_by uses strings as-is
    # Note: The constraint automatically includes "*" (public access) and checks for missing _wperm
    query = Parse::Query.new("Post")
    query.writable_by("role:Admin")  # Explicit role prefix

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_wperm" => { "$in" => ["role:Admin", "*"] } },
            { "_wperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "Should generate aggregation pipeline for writable constraint"
    puts "✅ Single role writable constraint generates pipeline: #{pipeline.inspect}"

    # Test multiple values
    query2 = Parse::Query.new("Post")
    query2.writable_by(["user123", "role:Editor"])

    pipeline2 = query2.pipeline
    expected_pipeline2 = [
      {
        "$match" => {
          "$or" => [
            { "_wperm" => { "$in" => ["user123", "role:Editor", "*"] } },
            { "_wperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline2, pipeline2, "Should generate aggregation pipeline for multiple writable values"
    puts "✅ Multiple values writable constraint generates pipeline: #{pipeline2.inspect}"
  end

  def test_pipeline_method_returns_stages_for_acl_constraints
    puts "\n=== Testing Pipeline Method ==="

    # ACL constraints use aggregation pipelines to access _rperm/_wperm fields
    query = Parse::Query.new("Post")
    query.readable_by("role:Admin")  # Use explicit role prefix

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["role:Admin", "*"] } },
            { "_rperm" => { "$exists" => false } },
          ],
        },
      },
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

  def test_readable_by_public_asterisk
    puts "\n=== Testing readable_by with '*' (public access) ==="

    query = Parse::Query.new("Post")
    query.readable_by("*")

    pipeline = query.pipeline
    # When querying for "*", it's already included so no duplication
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["*"] } },
            { "_rperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "Should generate pipeline for public access"
    puts "✅ readable_by('*') generates correct pipeline"
  end

  def test_readable_by_public_alias
    puts "\n=== Testing readable_by with 'public' alias ==="

    query = Parse::Query.new("Post")
    query.readable_by("public")

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["*"] } },
            { "_rperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    # "public" should be converted to "*"
    assert_equal expected_pipeline, pipeline, "Should convert 'public' to '*'"
    puts "✅ readable_by('public') generates correct pipeline"
  end

  def test_writable_by_public_asterisk
    puts "\n=== Testing writable_by with '*' (public access) ==="

    query = Parse::Query.new("Post")
    query.writable_by("*")

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_wperm" => { "$in" => ["*"] } },
            { "_wperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "Should generate pipeline for public write access"
    puts "✅ writable_by('*') generates correct pipeline"
  end

  def test_writable_by_public_alias
    puts "\n=== Testing writable_by with 'public' alias ==="

    query = Parse::Query.new("Post")
    query.writable_by("public")

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_wperm" => { "$in" => ["*"] } },
            { "_wperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "Should convert 'public' to '*' for write"
    puts "✅ writable_by('public') generates correct pipeline"
  end

  # ============================================================
  # ACL Convenience Query Methods Unit Tests
  # ============================================================

  def test_publicly_readable_convenience_method
    puts "\n=== Testing publicly_readable Convenience Method ==="

    query = Parse::Query.new("Post")
    query.publicly_readable

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["*"] } },
            { "_rperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "publicly_readable should query for '*' in _rperm"
    puts "✅ publicly_readable generates correct pipeline"
  end

  def test_publicly_writable_convenience_method
    puts "\n=== Testing publicly_writable Convenience Method ==="

    query = Parse::Query.new("Post")
    query.publicly_writable

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_wperm" => { "$in" => ["*"] } },
            { "_wperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "publicly_writable should query for '*' in _wperm"
    puts "✅ publicly_writable generates correct pipeline"
  end

  def test_privately_readable_convenience_method
    puts "\n=== Testing privately_readable Convenience Method ==="

    query = Parse::Query.new("Post")
    query.privately_readable

    pipeline = query.pipeline
    # privately_readable finds documents where _rperm is empty array (master key only)
    # Note: if _rperm is missing/undefined, Parse treats it as publicly readable
    expected_pipeline = [
      {
        "$match" => {
          "_rperm" => { "$eq" => [] },
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "privately_readable should query for empty _rperm"
    puts "✅ privately_readable generates correct pipeline"
  end

  def test_privately_writable_convenience_method
    puts "\n=== Testing privately_writable Convenience Method ==="

    query = Parse::Query.new("Post")
    query.privately_writable

    pipeline = query.pipeline
    # privately_writable finds documents where _wperm is empty array (master key only)
    expected_pipeline = [
      {
        "$match" => {
          "_wperm" => { "$eq" => [] },
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "privately_writable should query for empty _wperm"
    puts "✅ privately_writable generates correct pipeline"
  end

  def test_master_key_read_only_alias
    puts "\n=== Testing master_key_read_only Alias ==="

    query = Parse::Query.new("Post")
    query.master_key_read_only

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "_rperm" => { "$eq" => [] },
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "master_key_read_only should be alias for privately_readable"
    puts "✅ master_key_read_only alias works correctly"
  end

  def test_master_key_write_only_alias
    puts "\n=== Testing master_key_write_only Alias ==="

    query = Parse::Query.new("Post")
    query.master_key_write_only

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "_wperm" => { "$eq" => [] },
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "master_key_write_only should be alias for privately_writable"
    puts "✅ master_key_write_only alias works correctly"
  end

  def test_private_acl_combines_both_constraints
    puts "\n=== Testing private_acl Combines Both Constraints ==="

    query = Parse::Query.new("Post")
    query.private_acl

    pipeline = query.pipeline

    # Should have two $match stages - one for _rperm and one for _wperm
    assert_equal 2, pipeline.size, "private_acl should generate 2 pipeline stages"

    # Check that both _rperm and _wperm constraints are present (looking for empty array)
    rperm_stage = pipeline.find { |stage| stage["$match"]&.dig("_rperm", "$eq") == [] }
    wperm_stage = pipeline.find { |stage| stage["$match"]&.dig("_wperm", "$eq") == [] }

    assert rperm_stage, "Should have _rperm constraint"
    assert wperm_stage, "Should have _wperm constraint"

    puts "✅ private_acl generates both read and write constraints"
  end

  def test_master_key_only_alias
    puts "\n=== Testing master_key_only Alias ==="

    query = Parse::Query.new("Post")
    query.master_key_only

    pipeline = query.pipeline

    # Should have two $match stages
    assert_equal 2, pipeline.size, "master_key_only should be alias for private_acl"
    puts "✅ master_key_only alias works correctly"
  end

  def test_not_publicly_readable_convenience_method
    puts "\n=== Testing not_publicly_readable Convenience Method ==="

    query = Parse::Query.new("Post")
    query.not_publicly_readable

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "_rperm" => { "$nin" => ["*"] },
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "not_publicly_readable should query for '*' NOT in _rperm"
    puts "✅ not_publicly_readable generates correct pipeline"
  end

  def test_not_publicly_writable_convenience_method
    puts "\n=== Testing not_publicly_writable Convenience Method ==="

    query = Parse::Query.new("Post")
    query.not_publicly_writable

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "_wperm" => { "$nin" => ["*"] },
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "not_publicly_writable should query for '*' NOT in _wperm"
    puts "✅ not_publicly_writable generates correct pipeline"
  end

  # ============================================================
  # Hash Key Support in where/conditions Unit Tests
  # ============================================================

  def test_readable_by_hash_key_in_where
    puts "\n=== Testing readable_by: Hash Key in where ==="

    query = Parse::Query.new("Post")
    query.where(readable_by: "role:Admin")

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["role:Admin", "*"] } },
            { "_rperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "readable_by: hash key should work in where"
    puts "✅ readable_by: hash key works in where"
  end

  def test_writable_by_hash_key_in_where
    puts "\n=== Testing writable_by: Hash Key in where ==="

    query = Parse::Query.new("Post")
    query.where(writable_by: "role:Editor")

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_wperm" => { "$in" => ["role:Editor", "*"] } },
            { "_wperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "writable_by: hash key should work in where"
    puts "✅ writable_by: hash key works in where"
  end

  def test_readable_by_role_hash_key_in_where
    puts "\n=== Testing readable_by_role: Hash Key in where ==="

    query = Parse::Query.new("Post")
    query.where(readable_by_role: "Admin")

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["role:Admin", "*"] } },
            { "_rperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "readable_by_role: should auto-add role: prefix"
    puts "✅ readable_by_role: hash key works in where"
  end

  def test_writable_by_role_hash_key_in_where
    puts "\n=== Testing writable_by_role: Hash Key in where ==="

    query = Parse::Query.new("Post")
    query.where(writable_by_role: "Editor")

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_wperm" => { "$in" => ["role:Editor", "*"] } },
            { "_wperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "writable_by_role: should auto-add role: prefix"
    puts "✅ writable_by_role: hash key works in where"
  end

  def test_publicly_readable_hash_key_in_where
    puts "\n=== Testing publicly_readable: Hash Key in where ==="

    query = Parse::Query.new("Post")
    query.where(publicly_readable: true)

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["*"] } },
            { "_rperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "publicly_readable: true should work in where"
    puts "✅ publicly_readable: hash key works in where"
  end

  def test_privately_readable_hash_key_in_where
    puts "\n=== Testing privately_readable: Hash Key in where ==="

    query = Parse::Query.new("Post")
    query.where(privately_readable: true)

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "_rperm" => { "$eq" => [] },
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "privately_readable: true should work in where"
    puts "✅ privately_readable: hash key works in where"
  end

  def test_private_acl_hash_key_in_where
    puts "\n=== Testing private_acl: Hash Key in where ==="

    query = Parse::Query.new("Post")
    query.where(private_acl: true)

    pipeline = query.pipeline

    # Should have two $match stages
    assert_equal 2, pipeline.size, "private_acl: true should generate 2 pipeline stages"
    puts "✅ private_acl: hash key works in where"
  end

  def test_combined_hash_keys_in_where
    puts "\n=== Testing Combined Hash Keys in where ==="

    query = Parse::Query.new("Post")
    query.where(readable_by: "user123", title: "Test Post", limit: 10)

    compiled = query.compile

    # Should have both ACL constraint and regular constraint
    assert compiled[:where].include?("_rperm"), "Should include _rperm constraint"
    assert compiled[:where].include?('"title":"Test Post"'), "Should include title constraint"
    assert_equal 10, compiled[:limit], "Should have limit set"

    puts "✅ Combined hash keys work correctly"
  end

  def test_readable_by_with_array_in_hash
    puts "\n=== Testing readable_by: with Array in Hash ==="

    query = Parse::Query.new("Post")
    query.where(readable_by: ["user123", "role:Admin"])

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "$or" => [
            { "_rperm" => { "$in" => ["user123", "role:Admin", "*"] } },
            { "_rperm" => { "$exists" => false } },
          ],
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "readable_by: with array should work"
    puts "✅ readable_by: with array works in where"
  end

  # ============================================================
  # Convenience Methods Chaining Tests
  # ============================================================

  def test_convenience_methods_chain_with_other_constraints
    puts "\n=== Testing Convenience Methods Chain with Other Constraints ==="

    query = Parse::Query.new("Post")
    query.publicly_readable
         .where(published: true)
         .order(:createdAt.desc)
         .limit(10)

    compiled = query.compile

    assert compiled[:where].include?("_rperm"), "Should include _rperm constraint"
    assert compiled[:where].include?('"published":true'), "Should include published constraint"
    assert_equal "-createdAt", compiled[:order], "Should have order set"
    assert_equal 10, compiled[:limit], "Should have limit set"

    puts "✅ Convenience methods chain correctly with other constraints"
  end

  def test_multiple_acl_convenience_methods
    puts "\n=== Testing Multiple ACL Convenience Methods ==="

    query = Parse::Query.new("Post")
    query.publicly_readable
    query.not_publicly_writable

    pipeline = query.pipeline

    # Should have two $match stages
    assert_equal 2, pipeline.size, "Should have 2 pipeline stages"

    # publicly_readable generates $or with _rperm.$in
    rperm_stage = pipeline.find { |stage| stage.dig("$match", "$or", 0, "_rperm", "$in") }
    # not_publicly_writable generates _wperm.$nin
    wperm_stage = pipeline.find { |stage| stage.dig("$match", "_wperm", "$nin") }

    assert rperm_stage, "Should have readable constraint"
    assert wperm_stage, "Should have not writable constraint"

    puts "✅ Multiple ACL convenience methods work together"
  end
end
