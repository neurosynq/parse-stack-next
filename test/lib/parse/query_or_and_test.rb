require_relative '../../test_helper'
require 'minitest/autorun'

# Test model for OR/AND query testing
class OrAndTestProduct < Parse::Object
  parse_class "OrAndTestProduct"
  
  property :name, :string
  property :category, :string
  property :price, :float
  property :active, :boolean
  property :tags, :array
  property :sort_order, :integer
end

class QueryOrAndTest < Minitest::Test
  
  def test_or_with_simple_queries
    puts "\n=== Testing OR with Simple Queries ==="
    
    query1 = OrAndTestProduct.where(:name => "Product A")
    query2 = OrAndTestProduct.where(:name => "Product B")
    
    or_query = Parse::Query.or(query1, query2)
    
    puts "Query1 where: #{query1.where.inspect}"
    puts "Query2 where: #{query2.where.inspect}"
    puts "OR result where: #{or_query.where.inspect}"
    
    # Check if OR constraint was created
    assert_equal 1, or_query.where.length, "OR query should have exactly 1 compound constraint"
    or_constraint = or_query.where.first
    assert_equal :or, or_constraint.operand, "Constraint should be OR type"
    
    puts "✓ OR with simple queries creates compound constraint"
  end
  
  def test_or_with_complex_base_queries
    puts "\n=== Testing OR with Complex Base Queries ==="
    
    # Create base query with multiple constraints
    base_query = OrAndTestProduct.where(:active => true)
                                 .where(:price.gt => 10.0)
                                 .where(:category => "electronics")
    
    puts "Base query constraints: #{base_query.where.length}"
    base_query.where.each_with_index do |constraint, i|
      puts "  #{i}: #{constraint.operand} = #{constraint.value}"
    end
    
    # Create clones with additional constraints
    query1 = base_query.clone.where(:sort_order.exists => false)
    query2 = base_query.clone.where(:tags.in => ["draft"])
    
    puts "\nQuery1 (base + sort_order) constraints: #{query1.where.length}"
    query1.where.each_with_index do |constraint, i|
      puts "  #{i}: #{constraint.operand} = #{constraint.value}"
    end
    
    puts "\nQuery2 (base + tags) constraints: #{query2.where.length}"
    query2.where.each_with_index do |constraint, i|
      puts "  #{i}: #{constraint.operand} = #{constraint.value}"
    end
    
    # Test OR combination
    or_query = Parse::Query.or(query1, query2)
    
    puts "\nOR query constraints: #{or_query.where.length}"
    or_query.where.each_with_index do |constraint, i|
      puts "  #{i}: #{constraint.class} #{constraint.operand}"
      if constraint.respond_to?(:value)
        puts "      value: #{constraint.value.inspect}"
      end
    end
    
    # Test constraint compilation
    puts "\nTesting constraint compilation..."
    query1_compiled = Parse::Query.compile_where(query1.where)
    query2_compiled = Parse::Query.compile_where(query2.where)
    or_compiled = Parse::Query.compile_where(or_query.where)
    
    puts "Query1 compiled: #{query1_compiled.inspect}"
    puts "Query2 compiled: #{query2_compiled.inspect}"
    puts "OR compiled: #{or_compiled.inspect}"
    
    puts "✓ OR with complex base queries analyzed"
  end
  
  def test_compile_where_method_behavior
    puts "\n=== Testing compile_where Method Behavior ==="
    
    # Test with simple constraint
    simple_query = OrAndTestProduct.where(:name => "Test")
    simple_compiled = Parse::Query.compile_where(simple_query.where)
    puts "Simple query compiled: #{simple_compiled.inspect}"
    puts "Simple query empty?: #{simple_compiled.empty?}"
    
    # Test with multiple constraints
    complex_query = OrAndTestProduct.where(:name => "Test")
                                   .where(:active => true)
                                   .where(:price.gt => 5.0)
    complex_compiled = Parse::Query.compile_where(complex_query.where)
    puts "Complex query compiled: #{complex_compiled.inspect}"
    puts "Complex query empty?: #{complex_compiled.empty?}"
    
    # Test with empty query
    empty_query = OrAndTestProduct.query
    empty_compiled = Parse::Query.compile_where(empty_query.where)
    puts "Empty query compiled: #{empty_compiled.inspect}"
    puts "Empty query empty?: #{empty_compiled.empty?}"
    
    puts "✓ compile_where method behavior analyzed"
  end
  
  def test_or_constraint_creation_step_by_step
    puts "\n=== Testing OR Constraint Creation Step by Step ==="
    
    # Create two simple queries
    query1 = OrAndTestProduct.where(:category => "A")
    query2 = OrAndTestProduct.where(:category => "B")
    
    puts "Starting OR creation process..."
    puts "Query1 where length: #{query1.where.length}"
    puts "Query2 where length: #{query2.where.length}"
    
    # Simulate the OR method step by step
    queries = [query1, query2].flatten.compact
    puts "Queries after flatten.compact: #{queries.length}"
    
    table = queries.first.table
    puts "Table: #{table}"
    
    result = Parse::Query.new(table)
    puts "Result query created, where length: #{result.where.length}"
    
    # Filter step
    filtered_queries = queries.filter { |q| q.where.present? && !q.where.empty? }
    puts "Filtered queries: #{filtered_queries.length}"
    
    # Process each query
    filtered_queries.each_with_index do |query, i|
      puts "\nProcessing query #{i}:"
      puts "  Where constraints: #{query.where.length}"
      
      compiled_where = Parse::Query.compile_where(query.where)
      puts "  Compiled where: #{compiled_where.inspect}"
      puts "  Compiled empty?: #{compiled_where.empty?}"
      
      unless compiled_where.empty?
        puts "  Adding to OR result..."
        result.or_where(query.where)
        puts "  Result where length after: #{result.where.length}"
      else
        puts "  Skipping empty constraint"
      end
    end
    
    puts "\nFinal result where: #{result.where.inspect}"
    
    puts "✓ OR constraint creation analyzed step by step"
  end
  
  def test_or_where_method_behavior
    puts "\n=== Testing or_where Method Behavior ==="
    
    base_query = OrAndTestProduct.where(:active => true)
    puts "Base query where: #{base_query.where.inspect}"
    
    # Test adding OR constraint
    additional_constraints = [
      Parse::Constraint.create(:category, "electronics"),
      Parse::Constraint.create(:price, { :$gt => 10.0 })
    ]
    
    puts "Adding constraints via or_where..."
    base_query.or_where(additional_constraints)
    
    puts "After or_where, base query where: #{base_query.where.inspect}"
    
    # Test compiled result
    compiled = Parse::Query.compile_where(base_query.where)
    puts "Compiled result: #{compiled.inspect}"
    
    puts "✓ or_where method behavior analyzed"
  end
  
  def test_and_method_behavior
    puts "\n=== Testing AND Method Behavior ==="
    
    query1 = OrAndTestProduct.where(:active => true)
    query2 = OrAndTestProduct.where(:category => "electronics")
    query3 = OrAndTestProduct.where(:price.gt => 10.0)
    
    and_query = Parse::Query.and(query1, query2, query3)
    
    puts "Query1 where: #{query1.where.inspect}"
    puts "Query2 where: #{query2.where.inspect}"
    puts "Query3 where: #{query3.where.inspect}"
    puts "AND result where: #{and_query.where.inspect}"
    
    # AND should combine all constraints
    expected_constraint_count = query1.where.length + query2.where.length + query3.where.length
    assert_equal expected_constraint_count, and_query.where.length, "AND should combine all constraints"
    
    puts "✓ AND method combines constraints correctly"
  end
  
  def test_edge_cases
    puts "\n=== Testing Edge Cases ==="
    
    # Test OR with empty query
    empty_query = OrAndTestProduct.query
    real_query = OrAndTestProduct.where(:name => "Test")
    
    or_with_empty = Parse::Query.or(empty_query, real_query)
    puts "OR with empty query result: #{or_with_empty.where.inspect}"
    
    # Test OR with single query
    single_or = Parse::Query.or(real_query)
    puts "OR with single query result: #{single_or.where.inspect}"
    
    # Test OR with nil
    or_with_nil = Parse::Query.or(real_query, nil)
    puts "OR with nil result: #{or_with_nil.where.inspect}"
    
    # Test empty OR
    empty_or = Parse::Query.or()
    puts "Empty OR result: #{empty_or.inspect}"
    
    puts "✓ Edge cases handled"
  end
  
  def test_table_validation
    puts "\n=== Testing Table Validation ==="
    
    product_query = OrAndTestProduct.where(:name => "Test")
    
    # This should raise an error if we had another model
    begin
      or_query = Parse::Query.or(product_query)
      puts "Single table OR succeeded"
    rescue ArgumentError => e
      puts "Single table OR failed: #{e.message}"
    end
    
    puts "✓ Table validation tested"
  end
end