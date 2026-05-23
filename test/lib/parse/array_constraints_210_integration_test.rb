require_relative '../../test_helper_integration'
require 'timeout'

# Tests for Parse Stack 2.1.10 array constraint features
class ArrayConstraints210IntegrationTest < Minitest::Test
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
  class TaggedItem210 < Parse::Object
    parse_class "TaggedItem210"
    property :name, :string
    property :tags, :array
  end

  # Test model with array of hashes (for elem_match)
  class OrderItem < Parse::Object
    parse_class "OrderItem210"
    property :name, :string
    property :items, :array  # Array of hashes like { product: "SKU", quantity: 5, price: 10.0 }
  end

  # ==========================================================================
  # Test 1: :any constraint (alias for $in)
  # ==========================================================================
  def test_any_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing :any Constraint (alias for $in) ==="

      with_timeout(10, "creating test data") do
        TaggedItem210.new(name: "rock_only", tags: ["rock"]).save
        TaggedItem210.new(name: "pop_only", tags: ["pop"]).save
        TaggedItem210.new(name: "rock_and_pop", tags: ["rock", "pop"]).save
        TaggedItem210.new(name: "jazz_only", tags: ["jazz"]).save
        TaggedItem210.new(name: "classical", tags: ["classical", "baroque"]).save
      end

      with_timeout(5, "testing :any constraint") do
        begin
          # Test :tags.any => ["rock", "pop"] - should match items containing ANY of these
          results = TaggedItem210.query(:tags.any => ["rock", "pop"]).all
          names = results.map(&:name).sort

          puts "Query: :tags.any => ['rock', 'pop']"
          puts "Results: #{names.inspect}"

          # Should match: rock_only, pop_only, rock_and_pop
          # Should NOT match: jazz_only, classical
          assert_includes names, "rock_only", "any should match items with rock"
          assert_includes names, "pop_only", "any should match items with pop"
          assert_includes names, "rock_and_pop", "any should match items with rock or pop"
          refute_includes names, "jazz_only", "any should NOT match items without rock or pop"
          refute_includes names, "classical", "any should NOT match items without rock or pop"

          assert_equal 3, results.length, "Should find exactly 3 items"

          puts "✅ :any constraint works correctly!"
        rescue => e
          puts "❌ :any constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 2: :none constraint (alias for $nin)
  # ==========================================================================
  def test_none_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing :none Constraint (alias for $nin) ==="

      with_timeout(10, "creating test data") do
        TaggedItem210.new(name: "rock_only", tags: ["rock"]).save
        TaggedItem210.new(name: "pop_only", tags: ["pop"]).save
        TaggedItem210.new(name: "rock_and_pop", tags: ["rock", "pop"]).save
        TaggedItem210.new(name: "jazz_only", tags: ["jazz"]).save
        TaggedItem210.new(name: "classical", tags: ["classical", "baroque"]).save
      end

      with_timeout(5, "testing :none constraint") do
        begin
          # Test :tags.none => ["rock", "pop"] - should match items containing NONE of these
          results = TaggedItem210.query(:tags.none => ["rock", "pop"]).all
          names = results.map(&:name).sort

          puts "Query: :tags.none => ['rock', 'pop']"
          puts "Results: #{names.inspect}"

          # Should match: jazz_only, classical
          # Should NOT match: rock_only, pop_only, rock_and_pop
          refute_includes names, "rock_only", "none should NOT match items with rock"
          refute_includes names, "pop_only", "none should NOT match items with pop"
          refute_includes names, "rock_and_pop", "none should NOT match items with rock or pop"
          assert_includes names, "jazz_only", "none should match items without rock or pop"
          assert_includes names, "classical", "none should match items without rock or pop"

          assert_equal 2, results.length, "Should find exactly 2 items"

          puts "✅ :none constraint works correctly!"
        rescue => e
          puts "❌ :none constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 3: :superset_of constraint (alias for $all)
  # ==========================================================================
  def test_superset_of_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing :superset_of Constraint (alias for $all) ==="

      with_timeout(10, "creating test data") do
        TaggedItem210.new(name: "rock_only", tags: ["rock"]).save
        TaggedItem210.new(name: "rock_and_pop", tags: ["rock", "pop"]).save
        TaggedItem210.new(name: "rock_pop_jazz", tags: ["rock", "pop", "jazz"]).save
        TaggedItem210.new(name: "pop_only", tags: ["pop"]).save
      end

      with_timeout(5, "testing :superset_of constraint") do
        begin
          # Test :tags.superset_of => ["rock", "pop"] - should match items containing ALL of these
          results = TaggedItem210.query(:tags.superset_of => ["rock", "pop"]).all
          names = results.map(&:name).sort

          puts "Query: :tags.superset_of => ['rock', 'pop']"
          puts "Results: #{names.inspect}"

          # Should match: rock_and_pop, rock_pop_jazz (both have rock AND pop)
          # Should NOT match: rock_only (missing pop), pop_only (missing rock)
          assert_includes names, "rock_and_pop", "superset_of should match exact set"
          assert_includes names, "rock_pop_jazz", "superset_of should match superset"
          refute_includes names, "rock_only", "superset_of should NOT match if missing elements"
          refute_includes names, "pop_only", "superset_of should NOT match if missing elements"

          assert_equal 2, results.length, "Should find exactly 2 items"

          puts "✅ :superset_of constraint works correctly!"
        rescue => e
          puts "❌ :superset_of constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 4: :elem_match constraint (native $elemMatch)
  # ==========================================================================
  def test_elem_match_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing :elem_match Constraint ==="

      with_timeout(10, "creating test data") do
        # Create orders with items arrays containing hashes
        OrderItem.new(
          name: "order1",
          items: [
            { "product" => "SKU001", "quantity" => 5, "price" => 10.0 },
            { "product" => "SKU002", "quantity" => 2, "price" => 25.0 }
          ]
        ).save

        OrderItem.new(
          name: "order2",
          items: [
            { "product" => "SKU001", "quantity" => 10, "price" => 10.0 },
            { "product" => "SKU003", "quantity" => 1, "price" => 100.0 }
          ]
        ).save

        OrderItem.new(
          name: "order3",
          items: [
            { "product" => "SKU002", "quantity" => 3, "price" => 25.0 },
            { "product" => "SKU004", "quantity" => 7, "price" => 15.0 }
          ]
        ).save
      end

      with_timeout(5, "testing :elem_match constraint") do
        begin
          # Test :items.elem_match - find orders with SKU001 and quantity > 7
          results = OrderItem.query(:items.elem_match => {
            "product" => "SKU001",
            "quantity" => { "$gt" => 7 }
          }).all
          names = results.map(&:name)

          puts "Query: :items.elem_match => { product: 'SKU001', quantity: { $gt: 7 } }"
          puts "Results: #{names.inspect}"

          # Should match: order2 (has SKU001 with quantity 10)
          # Should NOT match: order1 (SKU001 quantity is 5), order3 (no SKU001)
          assert_equal 1, results.length, "Should find exactly 1 order"
          assert_equal "order2", results.first.name, "Should find order2"

          puts "✅ :elem_match constraint works correctly!"
        rescue => e
          puts "❌ :elem_match constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 5: :subset_of constraint (uses aggregation)
  # ==========================================================================
  def test_subset_of_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing :subset_of Constraint ==="

      with_timeout(10, "creating test data") do
        TaggedItem210.new(name: "rock_only", tags: ["rock"]).save
        TaggedItem210.new(name: "rock_and_pop", tags: ["rock", "pop"]).save
        TaggedItem210.new(name: "rock_and_metal", tags: ["rock", "metal"]).save  # metal not in allowed set
        TaggedItem210.new(name: "empty", tags: []).save
      end

      with_timeout(5, "testing :subset_of constraint") do
        begin
          # Test :tags.subset_of => ["rock", "pop", "jazz"] - tags must only contain elements from this set
          results = TaggedItem210.query(:tags.subset_of => ["rock", "pop", "jazz"]).all
          names = results.map(&:name).sort

          puts "Query: :tags.subset_of => ['rock', 'pop', 'jazz']"
          puts "Results: #{names.inspect}"

          # Should match: rock_only (["rock"] subset of allowed), rock_and_pop, empty ([] is subset of anything)
          # Should NOT match: rock_and_metal (contains "metal" which is not in allowed set)
          assert_includes names, "rock_only", "subset_of should match when all elements in allowed set"
          assert_includes names, "rock_and_pop", "subset_of should match when all elements in allowed set"
          assert_includes names, "empty", "subset_of should match empty array (empty set is subset of any set)"
          refute_includes names, "rock_and_metal", "subset_of should NOT match when element not in allowed set"

          assert_equal 3, results.length, "Should find exactly 3 items"

          puts "✅ :subset_of constraint works correctly!"
        rescue => e
          puts "❌ :subset_of constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 6: :first constraint (uses aggregation)
  # ==========================================================================
  def test_first_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing :first Constraint ==="

      with_timeout(10, "creating test data") do
        TaggedItem210.new(name: "featured_first", tags: ["featured", "rock", "pop"]).save
        TaggedItem210.new(name: "rock_first", tags: ["rock", "featured", "pop"]).save
        TaggedItem210.new(name: "featured_only", tags: ["featured"]).save
        TaggedItem210.new(name: "no_featured", tags: ["rock", "pop"]).save
        TaggedItem210.new(name: "empty", tags: []).save
      end

      with_timeout(5, "testing :first constraint") do
        begin
          # Test :tags.first => "featured" - first element must be "featured"
          results = TaggedItem210.query(:tags.first => "featured").all
          names = results.map(&:name).sort

          puts "Query: :tags.first => 'featured'"
          puts "Results: #{names.inspect}"

          # Should match: featured_first, featured_only
          # Should NOT match: rock_first (featured is not first), no_featured, empty
          assert_includes names, "featured_first", "first should match when first element matches"
          assert_includes names, "featured_only", "first should match single-element array"
          refute_includes names, "rock_first", "first should NOT match when element is not first"
          refute_includes names, "no_featured", "first should NOT match when element not present"
          refute_includes names, "empty", "first should NOT match empty array"

          assert_equal 2, results.length, "Should find exactly 2 items"

          puts "✅ :first constraint works correctly!"
        rescue => e
          puts "❌ :first constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end

  # ==========================================================================
  # Test 7: :last constraint (uses aggregation)
  # ==========================================================================
  def test_last_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      puts "\n=== Testing :last Constraint ==="

      with_timeout(10, "creating test data") do
        TaggedItem210.new(name: "archived_last", tags: ["rock", "pop", "archived"]).save
        TaggedItem210.new(name: "archived_middle", tags: ["rock", "archived", "pop"]).save
        TaggedItem210.new(name: "archived_only", tags: ["archived"]).save
        TaggedItem210.new(name: "no_archived", tags: ["rock", "pop"]).save
        TaggedItem210.new(name: "empty", tags: []).save
      end

      with_timeout(5, "testing :last constraint") do
        begin
          # Test :tags.last => "archived" - last element must be "archived"
          results = TaggedItem210.query(:tags.last => "archived").all
          names = results.map(&:name).sort

          puts "Query: :tags.last => 'archived'"
          puts "Results: #{names.inspect}"

          # Should match: archived_last, archived_only
          # Should NOT match: archived_middle (archived is not last), no_archived, empty
          assert_includes names, "archived_last", "last should match when last element matches"
          assert_includes names, "archived_only", "last should match single-element array"
          refute_includes names, "archived_middle", "last should NOT match when element is not last"
          refute_includes names, "no_archived", "last should NOT match when element not present"
          refute_includes names, "empty", "last should NOT match empty array"

          assert_equal 2, results.length, "Should find exactly 2 items"

          puts "✅ :last constraint works correctly!"
        rescue => e
          puts "❌ :last constraint failed: #{e.class} - #{e.message}"
          puts e.backtrace.first(5).join("\n")
          raise
        end
      end
    end
  end
end
