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

    # TRACK-QUERY-2: `_rperm` lives inside the aggregation pipeline,
    # NOT the REST `where` payload. Pre-fix, the `__aggregation_pipeline`
    # marker leaked into `compile[:where]` and `_rperm` appeared as a
    # substring of the encoded JSON. Now `compile_where` strips internal
    # markers, so the ACL constraint surfaces via `query.pipeline` only.
    pipeline_json = query.pipeline.to_json
    assert_includes pipeline_json, "_rperm",
                    "ACL pipeline should still include _rperm (aggregation path)"
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
          "_rperm" => { "$exists" => true, "$eq" => [] },
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
          "_wperm" => { "$exists" => true, "$eq" => [] },
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
          "_rperm" => { "$exists" => true, "$eq" => [] },
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
          "_wperm" => { "$exists" => true, "$eq" => [] },
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
    # The `$exists: true` guard is required: a missing `_rperm` is public per
    # Parse Server, and `$nin` matches missing-field docs, so without the
    # guard not_publicly_readable would return the public rows it must exclude.
    expected_pipeline = [
      {
        "$match" => {
          "_rperm" => { "$exists" => true, "$nin" => ["*"] },
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "not_publicly_readable should query for '*' NOT in _rperm and exclude missing-_rperm (public) rows"
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
          "_wperm" => { "$exists" => true, "$nin" => ["*"] },
        },
      },
    ]

    assert_equal expected_pipeline, pipeline, "not_publicly_writable should query for '*' NOT in _wperm and exclude missing-_wperm (public) rows"
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
          "_rperm" => { "$exists" => true, "$eq" => [] },
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

    # TRACK-QUERY-2: ACL constraint lives in the aggregation pipeline,
    # not in `compile[:where]`. See test_constraint_chaining_with_acl.
    pipeline_json = query.pipeline.to_json
    assert_includes pipeline_json, "_rperm",
                    "ACL pipeline should still include _rperm (aggregation path)"
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

    # TRACK-QUERY-2: ACL constraint lives in the aggregation pipeline,
    # not in `compile[:where]`. See test_constraint_chaining_with_acl.
    pipeline_json = query.pipeline.to_json
    assert_includes pipeline_json, "_rperm",
                    "ACL pipeline should still include _rperm (aggregation path)"
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

  # Regression guard for the mongo-direct ACL routing fix: the Aggregation
  # built for an ACL filter (readable_by/publicly_readable/etc.) must carry
  # +allow_internal_fields: true+ so the SDK-built `_rperm`/`_wperm` $match
  # passes Parse::PipelineSecurity's internal-fields denylist. Without the
  # flag, every readable_by/publicly_readable query that auto-routes through
  # mongo-direct raises Parse::PipelineSecurity::Error on the _rperm reference.
  def test_acl_aggregation_marks_internal_fields_allowed
    puts "\n=== Testing ACL aggregation forwards allow_internal_fields ==="
    require "parse/pipeline_security"

    %i[publicly_readable publicly_writable].each do |method|
      query = Parse::Query.new("Post").public_send(method)
      agg = query.send(:execute_aggregation_pipeline)

      assert agg.instance_variable_get(:@allow_internal_fields),
        "#{method} aggregation must forward allow_internal_fields: true"

      # The pipeline must survive the exact security check the mongo-direct
      # sink runs (allow_internal_fields equal to the forwarded flag).
      Parse::PipelineSecurity.validate_filter!(
        agg.pipeline,
        allow_internal_fields: agg.instance_variable_get(:@allow_internal_fields),
      )
    end

    # readable_by with an explicit permission string routes the same way.
    agg = Parse::Query.new("Post").readable_by("role:Admin").send(:execute_aggregation_pipeline)
    assert agg.instance_variable_get(:@allow_internal_fields),
      "readable_by aggregation must forward allow_internal_fields: true"

    puts "✅ ACL aggregations forward allow_internal_fields and pass the security validator"
  end

  # Guard the credential-field boundary: a plain (non-ACL) aggregation must
  # NOT relax the internal-fields denylist, so user-supplied pipelines can't
  # smuggle references to password hashes / session tokens through the
  # mongo-direct sink.
  def test_non_acl_aggregation_keeps_internal_fields_guard
    puts "\n=== Testing non-ACL aggregation keeps internal-fields guard ==="

    agg = Parse::Query.new("Post").where(title: "x")
                      .aggregate([{ "$group" => { "_id" => "$title" } }])

    refute agg.instance_variable_get(:@allow_internal_fields),
      "non-ACL aggregate must keep allow_internal_fields: false (credential guard intact)"

    puts "✅ Non-ACL aggregation keeps the internal-fields guard"
  end

  # #1 regression: the scalar aggregation terminals (sum/average/min/max/
  # count_distinct/distinct) and the user-facing #aggregate all funnel through
  # Query#aggregate. An ACL filter there must mark the pipeline so the
  # mongo-direct sink allows the SDK-built _rperm/_wperm reference.
  def test_aggregate_with_acl_filter_forwards_allow_internal_fields
    puts "\n=== Testing #aggregate with ACL filter forwards allow_internal_fields ==="

    agg = Parse::Query.new("Post").publicly_readable
                      .aggregate([{ "$group" => { "_id" => "$genre" } }])

    assert agg.instance_variable_get(:@allow_internal_fields),
      "ACL-filtered aggregate must forward allow_internal_fields: true"
    # The compiled pipeline must still carry the _rperm $match (it is not
    # dropped) so the filter actually applies on whichever engine runs it.
    assert agg.pipeline.to_json.include?("_rperm"),
      "ACL $match must survive into the aggregate() pipeline"

    puts "✅ ACL-filtered aggregate forwards the flag and keeps the _rperm match"
  end

  # #1 security regression: a scoped (scope_to_user / scope_to_role /
  # session_token) aggregation terminal must NOT silently fall back to Parse
  # Server's REST /aggregate endpoint, which is master-key-only and enforces
  # neither ACL nor CLP. When mongo-direct is unavailable it must fail closed.
  def test_scoped_aggregation_terminal_fails_closed_without_mongo_direct
    puts "\n=== Testing scoped aggregation fails closed without mongo-direct ==="

    skip "requires Parse::MongoDB NOT enabled for this assertion" if defined?(Parse::MongoDB) && Parse::MongoDB.enabled?

    user = Parse::User.new(objectId: "scopedUser1")

    # A scoped query with NO internal fields (pure scope bypass) must refuse
    # to run a scalar aggregation over REST-as-master.
    err = assert_raises(Parse::Query::MongoDirectRequired) do
      Parse::Query.new("Post").where(genre: "rock").scope_to_user(user)
                  .aggregate([{ "$group" => { "_id" => nil, "t" => { "$sum" => "$plays" } } }])
    end
    assert_match(/scoped aggregation/i, err.message)

    # An UNSCOPED ACL aggregate keeps the REST fallback (master-key correctness
    # edge, not an enforcement bypass) — it must NOT raise.
    Parse::Query.new("Post").publicly_readable
                .aggregate([{ "$group" => { "_id" => "$genre" } }])

    puts "✅ Scoped aggregation fails closed; unscoped keeps REST fallback"
  end

  # #3/#4: empty intent ([] / nil / "none" / :none) and Symbol values must
  # COMPILE at the Query level (they previously raised ArgumentError despite
  # being documented), and map to the right shapes.
  def test_readable_by_accepts_empty_and_symbol_values
    puts "\n=== Testing readable_by accepts [] / nil / :none / :public ==="

    empty = [{ "$match" => { "_rperm" => { "$exists" => true, "$eq" => [] } } }]
    [[], nil, "none", :none].each do |v|
      assert_equal empty, Parse::Query.new("Post").readable_by(v).pipeline,
        "readable_by(#{v.inspect}) should compile to the explicit-empty match"
    end

    public_shape = [{ "$match" => { "$or" => [
      { "_rperm" => { "$in" => ["*"] } },
      { "_rperm" => { "$exists" => false } },
    ] } }]
    [:public, :everyone, :world, "public", "*"].each do |v|
      assert_equal public_shape, Parse::Query.new("Post").readable_by(v).pipeline,
        "readable_by(#{v.inspect}) should map to the public wildcard"
    end

    puts "✅ readable_by accepts empty + symbol values"
  end

  # #6: strict: true compiles an exact match — no implicit public, no
  # missing-field branch.
  def test_readable_by_strict_kwarg
    puts "\n=== Testing readable_by(strict: true) ==="

    inclusive = Parse::Query.new("Post").readable_by("role:Admin").pipeline
    assert inclusive.first["$match"].key?("$or"), "default is public-inclusive ($or)"

    strict = Parse::Query.new("Post").readable_by("role:Admin", strict: true).pipeline
    assert_equal [{ "$match" => { "_rperm" => { "$in" => ["role:Admin"] } } }], strict,
      "strict: true should be an exact $in with no public/missing branches"

    puts "✅ readable_by strict mode produces an exact match"
  end

  # #5: the British :writeable_by spelling now resolves to the SAME
  # public-inclusive, role-expanding implementation as :writable_by.
  def test_writeable_by_is_alias_of_writable_by
    puts "\n=== Testing writeable_by == writable_by ==="

    american = Parse::Query.new("Post").where(:ACL.writable_by => "role:Admin").pipeline
    british  = Parse::Query.new("Post").where(:ACL.writeable_by => "role:Admin").pipeline
    assert_equal american, british, "writeable_by must compile identically to writable_by"
    assert american.first["$match"].key?("$or"), "both are public-inclusive"

    puts "✅ writeable_by is a true alias of writable_by"
  end

  # #8/#9: the new chained negation methods exist, and a mistyped permission
  # is NOT silently swallowed.
  def test_negation_methods_and_no_silent_swallow
    puts "\n=== Testing not_readable_by/not_writable_by + no silent swallow ==="

    q = Parse::Query.new("Post").not_readable_by("role:Admin")
    match = q.pipeline.first["$match"]["_rperm"]
    # not readable by Admin also excludes publicly-readable rows -> "*" added.
    assert_equal({ "$exists" => true, "$nin" => ["role:Admin", "*"] }, match)

    assert_respond_to Parse::Query.new("Post"), :not_writable_by

    # An unrecognized array element must RAISE, not vanish from the filter.
    assert_raises(ArgumentError) do
      Parse::Query.new("Post").readable_by(["role:Admin", 12345]).pipeline
    end
    # An unsupported Symbol must RAISE too.
    assert_raises(ArgumentError) do
      Parse::Query.new("Post").readable_by(:bogus).pipeline
    end

    puts "✅ negation methods present; bad permissions raise instead of vanishing"
  end

  # #1 (second sink): aggregate_from_query is a separate public pipeline sink.
  # It must (a) fold the SDK ACL $match into the pipeline rather than dropping
  # it, and (b) fail closed for a scoped query when mongo-direct is disabled.
  def test_aggregate_from_query_applies_acl_and_fails_closed_when_scoped
    puts "\n=== Testing aggregate_from_query ACL retention + scoped fail-closed ==="

    agg = Parse::Query.new("Post").publicly_readable
                      .aggregate_from_query([{ "$group" => { "_id" => "$genre" } }])
    assert agg.instance_variable_get(:@allow_internal_fields),
      "aggregate_from_query must forward allow_internal_fields for an ACL filter"
    assert agg.pipeline.to_json.include?("_rperm"),
      "aggregate_from_query must fold the ACL $match into the pipeline (not drop it)"

    if !(defined?(Parse::MongoDB) && Parse::MongoDB.enabled?)
      user = Parse::User.new(objectId: "scopedU")
      assert_raises(Parse::Query::MongoDirectRequired) do
        Parse::Query.new("Post").scope_to_user(user)
                    .aggregate_from_query([{ "$group" => { "_id" => nil } }])
      end
    end

    # A caller-supplied stage that smuggles an internal field must NOT flip the
    # sanction (only the SDK-built portion counts).
    sneaky = Parse::Query.new("Post").where(title: "x")
                         .aggregate_from_query([{ "$match" => { "_rperm" => { "$in" => ["x"] } } }])
    refute sneaky.instance_variable_get(:@allow_internal_fields),
      "additional_stages must not be able to sanction internal-field references"

    puts "✅ aggregate_from_query applies ACL filters and fails closed when scoped"
  end
end
