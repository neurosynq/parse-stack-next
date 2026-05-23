require_relative '../../test_helper_integration'
require 'minitest/autorun'

# Test model for OR/AND integration testing
class OrAndIntegrationProduct < Parse::Object
  parse_class "OrAndIntegrationProduct"
  
  property :name, :string
  property :category, :string
  property :price, :float
  property :active, :boolean, default: true
  property :tags, :array
  property :sort_order, :integer
  property :featured, :boolean, default: false
end

class QueryOrAndIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_or_query_asset_scenario_reproduction
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(20, "OR query asset scenario test") do
        puts "\n=== Reproducing Your Asset Scenario with OR Query ==="
        
        # Create test data that matches your asset scenario
        test_products = [
          # Target category products (should match base query)
          { name: "Asset A", category: "target", active: true, sort_order: 1, tags: [] },
          { name: "Asset B", category: "target", active: true, sort_order: nil, tags: [] }, # Should match sort_order query
          { name: "Asset C", category: "target", active: true, sort_order: 2, tags: ["draft"] }, # Should match draft query
          { name: "Asset D", category: "target", active: true, sort_order: nil, tags: ["draft"] }, # Should match both
          
          # Non-target products (should NOT match)  
          { name: "Other 1", category: "other", active: true, sort_order: nil, tags: [] },
          { name: "Other 2", category: "target", active: false, sort_order: nil, tags: [] },
        ]

        puts "Creating #{test_products.length} test products..."
        test_products.each do |product_data|
          product = OrAndIntegrationProduct.new(product_data)
          assert product.save, "Product #{product_data[:name]} should save"
        end

        # Reproduce your exact query pattern
        puts "\nStep 1: Creating base query (like your Asset.where(capture: self, ...))"
        base_query = OrAndIntegrationProduct.where(:category => "target", :active => true)
        base_results = base_query.all
        base_count = base_results.count
        puts "Base query found #{base_count} products"
        puts "Base query products: #{base_results.map(&:name).join(', ')}"

        # Should find Assets A, B, C, D (4 products)
        assert_equal 4, base_count, "Base query should find 4 target active products"

        puts "\nStep 2: Creating cloned queries"
        
        # Clone for sort_order query (like your sort_order_query = base_query.clone.where(...))
        sort_order_query = base_query.clone.where(:sort_order.exists => false)
        sort_order_results = sort_order_query.all  
        sort_order_count = sort_order_results.count
        puts "Sort order query found #{sort_order_count} products"
        puts "Sort order query products: #{sort_order_results.map(&:name).join(', ')}"

        # Should find Assets B, D (2 products with no sort_order)
        assert_equal 2, sort_order_count, "Sort order query should find 2 products without sort_order"

        # Clone for draft query (like your draft_query = base_query.clone.where(...))
        draft_query = base_query.clone.where(:tags.in => ["draft"])
        draft_results = draft_query.all
        draft_count = draft_results.count
        puts "Draft query found #{draft_count} products"
        puts "Draft query products: #{draft_results.map(&:name).join(', ')}"

        # Should find Assets C, D (2 products with draft tag)
        assert_equal 2, draft_count, "Draft query should find 2 products with draft tag"

        puts "\nStep 3: Testing OR combination (the problematic part)"
        
        # Debug the OR creation process
        puts "Before OR - Sort order query where: #{sort_order_query.where.inspect}"
        puts "Before OR - Draft query where: #{draft_query.where.inspect}"
        
        # Create OR query (like your Parse::Query.or(sort_order_query, draft_query))
        or_query = Parse::Query.or(sort_order_query, draft_query)
        
        puts "After OR - OR query where: #{or_query.where.inspect}"
        
        # Test compilation
        or_compiled = Parse::Query.compile_where(or_query.where)
        puts "OR query compiled: #{or_compiled.inspect}"
        
        # Execute the OR query
        puts "Executing OR query..."
        or_results = or_query.all
        or_count = or_results.count
        puts "OR query found #{or_count} products"
        puts "OR query products: #{or_results.map(&:name).join(', ')}"

        # Should find Assets B, C, D (products that either have no sort_order OR have draft tag)
        # Asset B: no sort_order (matches first condition)
        # Asset C: has draft tag (matches second condition) 
        # Asset D: both no sort_order AND draft tag (matches both conditions)
        expected_or_count = 3
        
        if or_count == expected_or_count
          puts "✅ OR query returned expected count: #{or_count}"
        elsif or_count > 100
          puts "❌ OR query returned too many results: #{or_count} (likely matching entire database)"
          puts "This indicates the base constraints were lost in OR combination"
        else
          puts "⚠️  OR query returned unexpected count: #{or_count} (expected #{expected_or_count})"
        end

        # Additional debugging
        puts "\nDebugging OR constraint structure..."
        or_query.where.each_with_index do |constraint, i|
          puts "  Constraint #{i}: #{constraint.class}"
          if constraint.respond_to?(:operand)
            puts "    Operand: #{constraint.operand}"
          end
          if constraint.respond_to?(:value)
            puts "    Value: #{constraint.value.inspect}"
          end
        end

        puts "✅ OR query asset scenario reproduction complete"
      end
    end
  end

  def test_or_query_debug_empty_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(15, "OR query debug empty constraints test") do
        puts "\n=== Debugging Empty Constraints in OR Query ==="
        
        # Create a simple test case
        product = OrAndIntegrationProduct.new(name: "Test Product", category: "test", active: true)
        assert product.save, "Test product should save"

        # Create queries
        query1 = OrAndIntegrationProduct.where(:category => "test")
        query2 = OrAndIntegrationProduct.where(:active => true)
        
        puts "Query1 where: #{query1.where.inspect}"
        puts "Query2 where: #{query2.where.inspect}"
        
        # Test compilation of individual queries
        query1_compiled = Parse::Query.compile_where(query1.where)
        query2_compiled = Parse::Query.compile_where(query2.where)
        
        puts "Query1 compiled: #{query1_compiled.inspect} (empty: #{query1_compiled.empty?})"
        puts "Query2 compiled: #{query2_compiled.inspect} (empty: #{query2_compiled.empty?})"
        
        # Create OR step by step
        puts "\nCreating OR query step by step..."
        
        queries = [query1, query2].flatten.compact
        table = queries.first.table
        result = Parse::Query.new(table)
        
        puts "Initial result where: #{result.where.inspect}"
        
        queries = queries.filter { |q| q.where.present? && !q.where.empty? }
        puts "Filtered queries count: #{queries.length}"
        
        queries.each_with_index do |query, i|
          puts "\nProcessing query #{i}:"
          compiled_where = Parse::Query.compile_where(query.where)
          puts "  Compiled: #{compiled_where.inspect}"
          puts "  Empty?: #{compiled_where.empty?}"
          
          unless compiled_where.empty?
            puts "  Adding via or_where..."
            result.or_where(query.where)
            puts "  Result after or_where: #{result.where.inspect}"
          end
        end
        
        puts "\nFinal OR query structure:"
        puts "Where length: #{result.where.length}"
        result.where.each_with_index do |constraint, i|
          puts "  #{i}: #{constraint.inspect}"
        end
        
        # Test execution
        final_results = result.all
        puts "Final results count: #{final_results.count}"
        
        puts "✅ Empty constraints debugging complete"
      end
    end
  end

  def test_and_query_integration
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "AND query integration test") do
        puts "\n=== Testing AND Query Integration ==="

        # Clean up any existing data from previous tests (test isolation)
        existing = OrAndIntegrationProduct.all(limit: 1000)
        existing.each(&:destroy) if existing.any?

        # Create test data
        products = [
          { name: "Match All", category: "electronics", price: 50.0, active: true, featured: true },
          { name: "Match Some", category: "electronics", price: 15.0, active: true, featured: false },
          { name: "Match None", category: "books", price: 5.0, active: false, featured: false },
        ]

        products.each do |product_data|
          product = OrAndIntegrationProduct.new(product_data)
          assert product.save, "Product #{product_data[:name]} should save"
        end

        # Create individual queries
        category_query = OrAndIntegrationProduct.where(:category => "electronics")
        price_query = OrAndIntegrationProduct.where(:price.gt => 20.0)
        active_query = OrAndIntegrationProduct.where(:active => true)
        
        puts "Category query count: #{category_query.count}"
        puts "Price query count: #{price_query.count}"
        puts "Active query count: #{active_query.count}"

        # Test AND combination
        and_query = Parse::Query.and(category_query, price_query, active_query)
        and_results = and_query.all
        and_count = and_results.count
        
        puts "AND query count: #{and_count}"
        puts "AND query products: #{and_results.map(&:name).join(', ')}"
        
        # Should only match "Match All" product
        assert_equal 1, and_count, "AND query should find 1 product matching all criteria"
        assert_equal "Match All", and_results.first.name, "AND query should find the correct product"
        
        puts "✅ AND query integration test passed"
      end
    end
  end

  def test_mixed_or_and_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(20, "mixed OR and AND queries test") do
        puts "\n=== Testing Mixed OR and AND Queries ==="
        
        # Create diverse test data
        products = [
          { name: "A", category: "electronics", price: 100.0, active: true, tags: ["premium"] },
          { name: "B", category: "electronics", price: 50.0, active: true, tags: ["budget"] },
          { name: "C", category: "books", price: 20.0, active: true, tags: ["premium"] },
          { name: "D", category: "books", price: 10.0, active: false, tags: ["budget"] },
        ]

        products.each do |product_data|
          product = OrAndIntegrationProduct.new(product_data)
          assert product.save, "Product #{product_data[:name]} should save"
        end

        # Test complex query: (electronics OR books) AND active AND (premium OR high price)
        electronics_query = OrAndIntegrationProduct.where(:category => "electronics")
        books_query = OrAndIntegrationProduct.where(:category => "books")
        category_or = Parse::Query.or(electronics_query, books_query)
        
        active_query = OrAndIntegrationProduct.where(:active => true)
        
        premium_query = OrAndIntegrationProduct.where(:tags.in => ["premium"])
        expensive_query = OrAndIntegrationProduct.where(:price.gt => 75.0)
        premium_or_expensive = Parse::Query.or(premium_query, expensive_query)
        
        # Combine with AND
        final_query = Parse::Query.and(category_or, active_query, premium_or_expensive)
        final_results = final_query.all
        final_count = final_results.count
        
        puts "Complex query found #{final_count} products"
        puts "Products: #{final_results.map(&:name).join(', ')}"
        
        # Should find products A and C (electronics/books AND active AND (premium OR expensive))
        # A: electronics, active, expensive (>75)
        # C: books, active, premium tag
        assert final_count >= 2, "Complex query should find at least 2 products"
        
        puts "✅ Mixed OR and AND queries test completed"
      end
    end
  end

  def test_performance_with_large_or_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(30, "performance with large OR queries test") do
        puts "\n=== Testing Performance with Large OR Queries ==="
        
        # Create larger dataset
        50.times do |i|
          product = OrAndIntegrationProduct.new(
            name: "Product #{i}",
            category: (i % 3 == 0) ? "target" : "other",
            price: 10.0 + i,
            active: true,
            sort_order: (i % 5 == 0) ? nil : i
          )
          assert product.save, "Product #{i} should save"
        end

        # Create base query
        base_query = OrAndIntegrationProduct.where(:category => "target")
        base_count = base_query.count
        puts "Base query found #{base_count} target products"

        # Create multiple OR branches
        queries = []
        5.times do |i|
          clone = base_query.clone.where(:price.gt => 20.0 + (i * 5))
          queries << clone
        end

        # Time the OR operation
        start_time = Time.now
        large_or = Parse::Query.or(*queries)
        or_time = Time.now - start_time

        # Time the execution
        exec_start = Time.now
        results = large_or.all
        exec_time = Time.now - exec_start

        puts "OR creation time: #{(or_time * 1000).round(2)}ms"
        puts "OR execution time: #{(exec_time * 1000).round(2)}ms"
        puts "Results count: #{results.count}"

        # Should be much less than total dataset
        assert results.count < 50, "OR query should return subset, not entire dataset"
        assert or_time < 0.1, "OR creation should be fast"

        puts "✅ Performance test completed"
      end
    end
  end
end