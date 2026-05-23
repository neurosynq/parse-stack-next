require_relative '../../test_helper_integration'
require 'timeout'

class ArrayEqualityIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Timeout helper method
  def with_timeout(seconds, description)
    Timeout.timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{description} timed out after #{seconds} seconds"
  end

  # Test model with array field for simple values
  class TaggedItem < Parse::Object
    parse_class "TaggedItem"
    property :name, :string
    property :tags, :array
  end

  # Test model for has_many pointer arrays
  class Category < Parse::Object
    parse_class "ArrayTestCategory"
    property :name, :string
  end

  class Product < Parse::Object
    parse_class "ArrayTestProduct"
    property :name, :string
    has_many :categories, through: :array, class_name: "ArrayTestCategory"
  end

  # ==========================================================================
  # Test 1: Verify $all behavior (baseline)
  # ==========================================================================
  def test_all_constraint_matches_supersets
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing $all Constraint Behavior ==="

      with_timeout(10, "creating test data") do
        # Create items with different tag configurations
        TaggedItem.new(name: "exact_match", tags: ["rock", "pop"]).save
        TaggedItem.new(name: "superset", tags: ["rock", "pop", "jazz"]).save
        TaggedItem.new(name: "subset", tags: ["rock"]).save
        TaggedItem.new(name: "different_order", tags: ["pop", "rock"]).save
        TaggedItem.new(name: "no_match", tags: ["classical", "jazz"]).save
      end

      with_timeout(5, "testing $all constraint") do
        # Query using $all - should match items that CONTAIN all specified values
        results = TaggedItem.query(:tags.all => ["rock", "pop"]).all
        names = results.map(&:name).sort

        puts "Query: :tags.all => ['rock', 'pop']"
        puts "Results: #{names.inspect}"

        # $all should match: exact_match, superset, different_order (all contain both rock AND pop)
        assert_includes names, "exact_match", "$all should match exact array"
        assert_includes names, "superset", "$all should match superset (has more elements)"
        assert_includes names, "different_order", "$all should match regardless of order"
        refute_includes names, "subset", "$all should NOT match subset (missing pop)"
        refute_includes names, "no_match", "$all should NOT match when values are missing"

        puts "✅ $all behaves as expected - matches any array containing ALL specified values"
      end
    end
  end

  # ==========================================================================
  # Test 2: Test $size constraint (verify if Parse supports it)
  # ==========================================================================
  def test_size_constraint_support
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing $size Constraint Support ==="

      with_timeout(10, "creating test data") do
        TaggedItem.new(name: "two_tags", tags: ["a", "b"]).save
        TaggedItem.new(name: "three_tags", tags: ["a", "b", "c"]).save
        TaggedItem.new(name: "one_tag", tags: ["a"]).save
      end

      with_timeout(5, "testing $size constraint") do
        # Try using $size directly in the where clause
        begin
          # Method 1: Direct $size in where
          query = TaggedItem.query
          query.where "tags" => { "$size" => 2 }
          results = query.all

          puts "Query with $size: 2"
          puts "Results: #{results.map(&:name).inspect}"

          if results.length == 1 && results.first.name == "two_tags"
            puts "✅ $size IS supported by Parse Server!"
          else
            puts "⚠️ $size returned unexpected results: #{results.map(&:name)}"
          end
        rescue => e
          puts "❌ $size query failed: #{e.class} - #{e.message}"
          puts "   Parse Server likely does NOT support $size constraint"
        end
      end
    end
  end

  # ==========================================================================
  # Test 3: Test $all + $size combination for exact match
  # ==========================================================================
  def test_all_plus_size_for_exact_match
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing $all + $size Combination ==="

      with_timeout(10, "creating test data") do
        TaggedItem.new(name: "exact", tags: ["rock", "pop"]).save
        TaggedItem.new(name: "superset", tags: ["rock", "pop", "jazz"]).save
        TaggedItem.new(name: "reordered", tags: ["pop", "rock"]).save
      end

      with_timeout(5, "testing $all + $size combination") do
        begin
          # Try combining $all and $size
          query = TaggedItem.query
          query.where "tags" => { "$all" => ["rock", "pop"], "$size" => 2 }
          results = query.all

          puts "Query: $all => ['rock', 'pop'], $size => 2"
          puts "Results: #{results.map(&:name).inspect}"

          # Should match: exact, reordered (both have exactly 2 elements)
          # Should NOT match: superset (has 3 elements)
          names = results.map(&:name)

          if names.include?("exact") && names.include?("reordered") && !names.include?("superset")
            puts "✅ $all + $size combination works for exact array matching!"
          else
            puts "⚠️ Unexpected results - $all + $size may not work as expected"
          end
        rescue => e
          puts "❌ $all + $size query failed: #{e.class} - #{e.message}"
        end
      end
    end
  end

  # ==========================================================================
  # Test 4: MongoDB aggregation with $setEquals (order-independent)
  # ==========================================================================
  def test_set_equals_aggregation
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing $setEquals Aggregation ==="

      with_timeout(10, "creating test data") do
        TaggedItem.new(name: "exact", tags: ["rock", "pop"]).save
        TaggedItem.new(name: "superset", tags: ["rock", "pop", "jazz"]).save
        TaggedItem.new(name: "reordered", tags: ["pop", "rock"]).save
        TaggedItem.new(name: "different", tags: ["classical"]).save
      end

      with_timeout(5, "testing $setEquals aggregation") do
        begin
          # Use aggregation pipeline with $setEquals
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$setEquals" => ["$tags", ["rock", "pop"]]
                }
              }
            }
          ]

          aggregation = TaggedItem.query.aggregate(pipeline)
          results = aggregation.results

          puts "Aggregation pipeline: $setEquals => ['rock', 'pop']"
          puts "Results: #{results.map { |r| r['name'] || r[:name] || (r.name rescue nil) || r.inspect }.inspect}"

          # $setEquals should match items with exactly the same elements (order-independent)
          # Should match: exact, reordered
          # Should NOT match: superset, different
          names = results.map { |r| r['name'] || r[:name] || r.name rescue nil }.compact

          if names.include?("exact") && names.include?("reordered") &&
             !names.include?("superset") && !names.include?("different")
            puts "✅ $setEquals aggregation works for set equality!"
          else
            puts "⚠️ $setEquals results: #{names.inspect}"
          end
        rescue => e
          puts "❌ $setEquals aggregation failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
        end
      end
    end
  end

  # ==========================================================================
  # Test 5: MongoDB aggregation with $eq (order-dependent)
  # ==========================================================================
  def test_eq_aggregation_order_dependent
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing $eq Aggregation (Order-Dependent) ==="

      with_timeout(10, "creating test data") do
        TaggedItem.new(name: "exact_order", tags: ["rock", "pop"]).save
        TaggedItem.new(name: "reordered", tags: ["pop", "rock"]).save
        TaggedItem.new(name: "superset", tags: ["rock", "pop", "jazz"]).save
      end

      with_timeout(5, "testing $eq aggregation") do
        begin
          # Use aggregation pipeline with $eq for strict equality
          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$eq" => ["$tags", ["rock", "pop"]]
                }
              }
            }
          ]

          aggregation = TaggedItem.query.aggregate(pipeline)
          results = aggregation.results

          puts "Aggregation pipeline: $eq => ['rock', 'pop']"
          puts "Results: #{results.map { |r| r['name'] || r[:name] || (r.name rescue nil) || r.inspect }.inspect}"

          # $eq should only match items with exactly the same array (including order)
          # Should match: exact_order
          # Should NOT match: reordered, superset
          names = results.map { |r| r['name'] || r[:name] || r.name rescue nil }.compact

          if names.include?("exact_order") && !names.include?("reordered") && !names.include?("superset")
            puts "✅ $eq aggregation works for strict order-dependent equality!"
          elsif names.include?("exact_order") && names.include?("reordered")
            puts "⚠️ $eq appears to be order-independent in this context"
          else
            puts "⚠️ $eq results: #{names.inspect}"
          end
        rescue => e
          puts "❌ $eq aggregation failed: #{e.class} - #{e.message}"
        end
      end
    end
  end

  # ==========================================================================
  # Test 6: Parse pointers (has_many) array equality
  # ==========================================================================
  def test_pointer_array_set_equals
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing Pointer Array $setEquals ==="

      cat1 = cat2 = cat3 = nil
      prod_exact = prod_superset = prod_reordered = nil

      with_timeout(15, "creating test data") do
        # Create categories
        cat1 = Category.new(name: "Electronics")
        cat1.save
        cat2 = Category.new(name: "Computers")
        cat2.save
        cat3 = Category.new(name: "Accessories")
        cat3.save

        puts "Created categories: #{cat1.id}, #{cat2.id}, #{cat3.id}"

        # Create products with different category combinations
        prod_exact = Product.new(name: "exact_match")
        prod_exact.categories = [cat1, cat2]
        prod_exact.save

        prod_superset = Product.new(name: "superset")
        prod_superset.categories = [cat1, cat2, cat3]
        prod_superset.save

        prod_reordered = Product.new(name: "reordered")
        prod_reordered.categories = [cat2, cat1]
        prod_reordered.save

        puts "Created products with category arrays"
      end

      with_timeout(10, "testing pointer array $setEquals") do
        begin
          # For pointer arrays, we need to extract objectIds for comparison
          target_ids = [cat1.id, cat2.id]

          pipeline = [
            {
              "$match" => {
                "$expr" => {
                  "$setEquals" => [
                    { "$map" => { "input" => "$categories", "as" => "c", "in" => "$$c.objectId" } },
                    target_ids
                  ]
                }
              }
            }
          ]

          aggregation = Product.query.aggregate(pipeline)
          results = aggregation.results

          puts "Aggregation: $setEquals on categories objectIds => #{target_ids.inspect}"
          puts "Results: #{results.map { |r| r['name'] || r[:name] || (r.name rescue nil) || r.inspect }.inspect}"

          names = results.map { |r| r['name'] || r[:name] || r.name rescue nil }.compact

          if names.include?("exact_match") && names.include?("reordered") && !names.include?("superset")
            puts "✅ Pointer array $setEquals works!"
          else
            puts "⚠️ Pointer array results: #{names.inspect}"
          end
        rescue => e
          puts "❌ Pointer array $setEquals failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
        end
      end
    end
  end

  # ==========================================================================
  # Test 7: Direct array match in $match (simpler approach)
  # ==========================================================================
  def test_direct_array_match_aggregation
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing Direct Array Match in $match ==="

      with_timeout(10, "creating test data") do
        TaggedItem.new(name: "exact", tags: ["rock", "pop"]).save
        TaggedItem.new(name: "reordered", tags: ["pop", "rock"]).save
        TaggedItem.new(name: "superset", tags: ["rock", "pop", "jazz"]).save
      end

      with_timeout(5, "testing direct array match") do
        begin
          # Try direct array equality in $match
          pipeline = [
            { "$match" => { "tags" => ["rock", "pop"] } }
          ]

          aggregation = TaggedItem.query.aggregate(pipeline)
          results = aggregation.results

          puts "Aggregation: direct match tags => ['rock', 'pop']"
          puts "Results: #{results.map { |r| r['name'] || r[:name] || (r.name rescue nil) || r.inspect }.inspect}"

          names = results.map { |r| r['name'] || r[:name] || r.name rescue nil }.compact

          if names == ["exact"]
            puts "✅ Direct array match works for order-dependent equality!"
          elsif names.include?("exact") && names.include?("reordered")
            puts "⚠️ Direct match appears to be order-independent"
          else
            puts "⚠️ Direct match results: #{names.inspect}"
          end
        rescue => e
          puts "❌ Direct array match failed: #{e.class} - #{e.message}"
        end
      end
    end
  end

  # ==========================================================================
  # Test 8: Native :size constraint
  # ==========================================================================
  def test_native_size_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing Native :size Constraint ==="

      with_timeout(10, "creating test data") do
        TaggedItem.new(name: "two_tags", tags: ["a", "b"]).save
        TaggedItem.new(name: "three_tags", tags: ["a", "b", "c"]).save
        TaggedItem.new(name: "one_tag", tags: ["a"]).save
        TaggedItem.new(name: "empty_tags", tags: []).save
      end

      with_timeout(5, "testing :size constraint") do
        begin
          # Test :tags.size => 2
          results = TaggedItem.query(:tags.size => 2).all
          names = results.map(&:name)

          puts "Query: :tags.size => 2"
          puts "Results: #{names.inspect}"

          assert_equal 1, results.length, "Should find exactly 1 item with 2 tags"
          assert_equal "two_tags", results.first.name, "Should find two_tags item"

          # Test :tags.size => 3
          results = TaggedItem.query(:tags.size => 3).all
          names = results.map(&:name)

          puts "Query: :tags.size => 3"
          puts "Results: #{names.inspect}"

          assert_equal 1, results.length, "Should find exactly 1 item with 3 tags"
          assert_equal "three_tags", results.first.name, "Should find three_tags item"

          # Test :tags.size => 0
          results = TaggedItem.query(:tags.size => 0).all
          names = results.map(&:name)

          puts "Query: :tags.size => 0"
          puts "Results: #{names.inspect}"

          assert_equal 1, results.length, "Should find exactly 1 item with 0 tags"
          assert_equal "empty_tags", results.first.name, "Should find empty_tags item"

          puts "✅ :size constraint works correctly!"
        rescue => e
          puts "❌ :size constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 9: Native :set_equals constraint (order-independent)
  # ==========================================================================
  def test_native_set_equals_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing Native :set_equals Constraint ==="

      with_timeout(10, "creating test data") do
        TaggedItem.new(name: "exact", tags: ["rock", "pop"]).save
        TaggedItem.new(name: "reordered", tags: ["pop", "rock"]).save
        TaggedItem.new(name: "superset", tags: ["rock", "pop", "jazz"]).save
        TaggedItem.new(name: "different", tags: ["classical"]).save
      end

      with_timeout(5, "testing :set_equals constraint") do
        begin
          # Test :tags.set_equals => ["rock", "pop"]
          results = TaggedItem.query(:tags.set_equals => ["rock", "pop"]).all
          names = results.map(&:name).sort

          puts "Query: :tags.set_equals => ['rock', 'pop']"
          puts "Results: #{names.inspect}"

          # Should match: exact, reordered (same elements, any order)
          # Should NOT match: superset (has extra element), different
          assert_includes names, "exact", "set_equals should match exact array"
          assert_includes names, "reordered", "set_equals should match reordered array"
          refute_includes names, "superset", "set_equals should NOT match superset"
          refute_includes names, "different", "set_equals should NOT match different array"

          assert_equal 2, results.length, "Should find exactly 2 items"

          puts "✅ :set_equals constraint works correctly!"
        rescue => e
          puts "❌ :set_equals constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 10: Native :eq_array constraint (order-dependent)
  # ==========================================================================
  def test_native_eq_array_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing Native :eq_array Constraint ==="

      with_timeout(10, "creating test data") do
        TaggedItem.new(name: "exact_order", tags: ["rock", "pop"]).save
        TaggedItem.new(name: "reordered", tags: ["pop", "rock"]).save
        TaggedItem.new(name: "superset", tags: ["rock", "pop", "jazz"]).save
      end

      with_timeout(5, "testing :eq_array constraint") do
        begin
          # Test :tags.eq_array => ["rock", "pop"]
          results = TaggedItem.query(:tags.eq_array => ["rock", "pop"]).all
          names = results.map(&:name)

          puts "Query: :tags.eq_array => ['rock', 'pop']"
          puts "Results: #{names.inspect}"

          # Should match: exact_order (same elements, same order)
          # Should NOT match: reordered (different order), superset
          assert_includes names, "exact_order", "eq_array should match exact order"
          refute_includes names, "reordered", "eq_array should NOT match reordered"
          refute_includes names, "superset", "eq_array should NOT match superset"

          assert_equal 1, results.length, "Should find exactly 1 item"

          puts "✅ :eq_array constraint works correctly!"
        rescue => e
          puts "❌ :eq_array constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 11: Pointer array :set_equals constraint
  # ==========================================================================
  def test_pointer_array_set_equals_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing Pointer Array :set_equals Constraint ==="

      cat1 = cat2 = cat3 = nil

      with_timeout(15, "creating test data") do
        # Create categories
        cat1 = Category.new(name: "Electronics")
        cat1.save
        cat2 = Category.new(name: "Computers")
        cat2.save
        cat3 = Category.new(name: "Accessories")
        cat3.save

        puts "Created categories: #{cat1.id}, #{cat2.id}, #{cat3.id}"

        # Create products with different category combinations
        prod_exact = Product.new(name: "exact_match")
        prod_exact.categories = [cat1, cat2]
        prod_exact.save

        prod_superset = Product.new(name: "superset")
        prod_superset.categories = [cat1, cat2, cat3]
        prod_superset.save

        prod_reordered = Product.new(name: "reordered")
        prod_reordered.categories = [cat2, cat1]
        prod_reordered.save
      end

      with_timeout(10, "testing pointer array :set_equals") do
        begin
          # Test :categories.set_equals => [cat1, cat2]
          results = Product.query(:categories.set_equals => [cat1, cat2]).all
          names = results.map(&:name).sort

          puts "Query: :categories.set_equals => [cat1, cat2]"
          puts "Results: #{names.inspect}"

          # Should match: exact_match, reordered
          # Should NOT match: superset
          assert_includes names, "exact_match", "set_equals should match exact array"
          assert_includes names, "reordered", "set_equals should match reordered array"
          refute_includes names, "superset", "set_equals should NOT match superset"

          assert_equal 2, results.length, "Should find exactly 2 products"

          puts "✅ Pointer array :set_equals constraint works correctly!"
        rescue => e
          puts "❌ Pointer array :set_equals constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 12: Native :neq constraint (order-dependent not-equal)
  # ==========================================================================
  def test_native_neq_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing Native :neq Constraint ==="

      with_timeout(10, "creating test data") do
        TaggedItem.new(name: "exact_order", tags: ["rock", "pop"]).save
        TaggedItem.new(name: "reordered", tags: ["pop", "rock"]).save
        TaggedItem.new(name: "superset", tags: ["rock", "pop", "jazz"]).save
        TaggedItem.new(name: "different", tags: ["classical"]).save
      end

      with_timeout(5, "testing :neq constraint") do
        begin
          # Test :tags.neq => ["rock", "pop"] - should NOT match exact order
          results = TaggedItem.query(:tags.neq => ["rock", "pop"]).all
          names = results.map(&:name).sort

          puts "Query: :tags.neq => ['rock', 'pop']"
          puts "Results: #{names.inspect}"

          # Should match: reordered, superset, different (anything NOT exactly ["rock", "pop"])
          # Should NOT match: exact_order
          refute_includes names, "exact_order", "neq should NOT match exact order"
          assert_includes names, "reordered", "neq should match reordered"
          assert_includes names, "superset", "neq should match superset"
          assert_includes names, "different", "neq should match different"

          assert_equal 3, results.length, "Should find 3 items"

          puts "✅ :neq constraint works correctly!"
        rescue => e
          puts "❌ :neq constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 13: Native :nlike constraint (order-independent not-equal)
  # ==========================================================================
  def test_native_nlike_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing Native :nlike Constraint ==="

      with_timeout(10, "creating test data") do
        TaggedItem.new(name: "exact", tags: ["rock", "pop"]).save
        TaggedItem.new(name: "reordered", tags: ["pop", "rock"]).save
        TaggedItem.new(name: "superset", tags: ["rock", "pop", "jazz"]).save
        TaggedItem.new(name: "different", tags: ["classical"]).save
      end

      with_timeout(5, "testing :nlike constraint") do
        begin
          # Test :tags.nlike => ["rock", "pop"] - should NOT match any set-equal arrays
          results = TaggedItem.query(:tags.nlike => ["rock", "pop"]).all
          names = results.map(&:name).sort

          puts "Query: :tags.nlike => ['rock', 'pop']"
          puts "Results: #{names.inspect}"

          # Should match: superset, different (anything NOT set-equal to ["rock", "pop"])
          # Should NOT match: exact, reordered (both are set-equal)
          refute_includes names, "exact", "nlike should NOT match exact"
          refute_includes names, "reordered", "nlike should NOT match reordered"
          assert_includes names, "superset", "nlike should match superset"
          assert_includes names, "different", "nlike should match different"

          assert_equal 2, results.length, "Should find 2 items"

          puts "✅ :nlike constraint works correctly!"
        rescue => e
          puts "❌ :nlike constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 14: arr_empty and arr_nempty constraints
  # ==========================================================================
  def test_arr_empty_and_nempty_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing arr_empty and arr_nempty Constraints ==="

      with_timeout(10, "creating test data") do
        TaggedItem.new(name: "empty", tags: []).save
        TaggedItem.new(name: "one", tags: ["a"]).save
        TaggedItem.new(name: "two", tags: ["a", "b"]).save
      end

      with_timeout(5, "testing arr_empty and arr_nempty") do
        begin
          # Test :tags.arr_empty => true
          results = TaggedItem.query(:tags.arr_empty => true).all
          names = results.map(&:name)
          puts "Query: :tags.arr_empty => true"
          puts "Results: #{names.inspect}"
          assert_equal ["empty"], names, "arr_empty => true should find empty arrays"

          # Test :tags.arr_empty => false
          results = TaggedItem.query(:tags.arr_empty => false).all
          names = results.map(&:name).sort
          puts "Query: :tags.arr_empty => false"
          puts "Results: #{names.inspect}"
          assert_equal ["one", "two"], names, "arr_empty => false should find non-empty arrays"

          # Test :tags.arr_nempty => true
          results = TaggedItem.query(:tags.arr_nempty => true).all
          names = results.map(&:name).sort
          puts "Query: :tags.arr_nempty => true"
          puts "Results: #{names.inspect}"
          assert_equal ["one", "two"], names, "arr_nempty => true should find non-empty arrays"

          # Test :tags.arr_nempty => false
          results = TaggedItem.query(:tags.arr_nempty => false).all
          names = results.map(&:name)
          puts "Query: :tags.arr_nempty => false"
          puts "Results: #{names.inspect}"
          assert_equal ["empty"], names, "arr_nempty => false should find empty arrays"

          puts "✅ arr_empty and arr_nempty constraints work correctly!"
        rescue => e
          puts "❌ arr_empty/arr_nempty constraints failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 15: Size comparison operators (gt, gte, lt, lte, ne)
  # ==========================================================================
  def test_size_comparison_operators
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing Size Comparison Operators ==="

      with_timeout(10, "creating test data") do
        TaggedItem.new(name: "zero", tags: []).save
        TaggedItem.new(name: "one", tags: ["a"]).save
        TaggedItem.new(name: "two", tags: ["a", "b"]).save
        TaggedItem.new(name: "three", tags: ["a", "b", "c"]).save
        TaggedItem.new(name: "five", tags: ["a", "b", "c", "d", "e"]).save
      end

      with_timeout(10, "testing size comparison operators") do
        begin
          # Test :tags.size => { gt: 2 } - size > 2
          results = TaggedItem.query(:tags.size => { gt: 2 }).all
          names = results.map(&:name).sort
          puts "Query: :tags.size => { gt: 2 }"
          puts "Results: #{names.inspect}"
          assert_equal ["five", "three"], names, "gt: 2 should find three and five"

          # Test :tags.size => { gte: 3 } - size >= 3
          results = TaggedItem.query(:tags.size => { gte: 3 }).all
          names = results.map(&:name).sort
          puts "Query: :tags.size => { gte: 3 }"
          puts "Results: #{names.inspect}"
          assert_equal ["five", "three"], names, "gte: 3 should find three and five"

          # Test :tags.size => { lt: 2 } - size < 2
          results = TaggedItem.query(:tags.size => { lt: 2 }).all
          names = results.map(&:name).sort
          puts "Query: :tags.size => { lt: 2 }"
          puts "Results: #{names.inspect}"
          assert_equal ["one", "zero"], names, "lt: 2 should find zero and one"

          # Test :tags.size => { lte: 1 } - size <= 1
          results = TaggedItem.query(:tags.size => { lte: 1 }).all
          names = results.map(&:name).sort
          puts "Query: :tags.size => { lte: 1 }"
          puts "Results: #{names.inspect}"
          assert_equal ["one", "zero"], names, "lte: 1 should find zero and one"

          # Test :tags.size => { ne: 2 } - size != 2
          results = TaggedItem.query(:tags.size => { ne: 2 }).all
          names = results.map(&:name).sort
          puts "Query: :tags.size => { ne: 2 }"
          puts "Results: #{names.inspect}"
          assert_equal ["five", "one", "three", "zero"], names, "ne: 2 should exclude two"

          # Test combined: :tags.size => { gte: 1, lt: 3 } - 1 <= size < 3
          results = TaggedItem.query(:tags.size => { gte: 1, lt: 3 }).all
          names = results.map(&:name).sort
          puts "Query: :tags.size => { gte: 1, lt: 3 }"
          puts "Results: #{names.inspect}"
          assert_equal ["one", "two"], names, "gte: 1, lt: 3 should find one and two"

          puts "✅ Size comparison operators work correctly!"
        rescue => e
          puts "❌ Size comparison operators failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 16: Pointer array :size constraint
  # ==========================================================================
  def test_pointer_array_size_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing Pointer Array :size Constraint ==="

      with_timeout(15, "creating test data") do
        # Create categories
        cat1 = Category.new(name: "Cat1").tap(&:save)
        cat2 = Category.new(name: "Cat2").tap(&:save)
        cat3 = Category.new(name: "Cat3").tap(&:save)

        # Create products with different numbers of categories
        prod1 = Product.new(name: "one_cat")
        prod1.categories = [cat1]
        prod1.save

        prod2 = Product.new(name: "two_cats")
        prod2.categories = [cat1, cat2]
        prod2.save

        prod3 = Product.new(name: "three_cats")
        prod3.categories = [cat1, cat2, cat3]
        prod3.save
      end

      with_timeout(10, "testing pointer array :size") do
        begin
          # Test :categories.size => 2
          results = Product.query(:categories.size => 2).all
          names = results.map(&:name)

          puts "Query: :categories.size => 2"
          puts "Results: #{names.inspect}"

          assert_equal 1, results.length, "Should find exactly 1 product with 2 categories"
          assert_equal "two_cats", results.first.name, "Should find two_cats product"

          # Test :categories.size => 1
          results = Product.query(:categories.size => 1).all
          names = results.map(&:name)

          puts "Query: :categories.size => 1"
          puts "Results: #{names.inspect}"

          assert_equal 1, results.length, "Should find exactly 1 product with 1 category"
          assert_equal "one_cat", results.first.name, "Should find one_cat product"

          puts "✅ Pointer array :size constraint works correctly!"
        rescue => e
          puts "❌ Pointer array :size constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end
end
