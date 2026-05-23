require_relative '../../test_helper_integration'

# Test models for aggregation grouping testing
class AggregationProduct < Parse::Object
  parse_class "AggregationProduct"
  
  property :name, :string
  property :category, :string
  property :price, :float
  property :tags, :array
  property :metadata, :object
  property :launch_date, :date
  property :in_stock, :boolean, default: true
end

class AggregationSale < Parse::Object
  parse_class "AggregationSale"
  
  property :product_name, :string
  property :quantity, :integer
  property :revenue, :float
  property :sale_date, :date
  property :customer_regions, :array
  property :payment_methods, :array
end

class AggregationGroupingIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_sortable_grouping_functionality
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "sortable grouping test") do
        puts "\n=== Testing Sortable Grouping Functionality ==="

        # Create test products with different categories and prices
        products = [
          { name: "Laptop Pro", category: "electronics", price: 1299.99, tags: ["computer", "work"], launch_date: Date.new(2023, 6, 15) },
          { name: "Smartphone X", category: "electronics", price: 899.99, tags: ["phone", "mobile"], launch_date: Date.new(2023, 8, 20) },
          { name: "Coffee Mug", category: "kitchen", price: 15.99, tags: ["drink", "ceramic"], launch_date: Date.new(2023, 3, 10) },
          { name: "Desk Chair", category: "furniture", price: 249.99, tags: ["office", "comfort"], launch_date: Date.new(2023, 5, 5) },
          { name: "Gaming Mouse", category: "electronics", price: 79.99, tags: ["gaming", "computer"], launch_date: Date.new(2023, 7, 12) },
          { name: "Table Lamp", category: "furniture", price: 89.99, tags: ["lighting", "home"], launch_date: Date.new(2023, 4, 18) },
          { name: "Headphones", category: "electronics", price: 199.99, tags: ["audio", "wireless"], launch_date: Date.new(2023, 9, 3) }
        ]

        products.each do |product_data|
          product = AggregationProduct.new(product_data)
          assert product.save, "Product #{product_data[:name]} should save"
        end

        # Test basic sortable grouping by category
        puts "Testing basic sortable grouping by category..."
        sortable_group = AggregationProduct.query.group_by(:category, sortable: true)
        results = sortable_group.count.to_h

        assert results.is_a?(Hash), "Results should be a hash"
        assert results.keys.length >= 3, "Should have at least 3 categories"
        
        # Verify structure of sortable grouping results
        assert results.key?("electronics"), "Should have electronics group"
        assert results["electronics"] >= 4, "Electronics should have at least 4 products"
        assert results.key?("furniture"), "Should have furniture group"
        assert results.key?("kitchen"), "Should have kitchen group"

        puts "✅ Basic sortable grouping works correctly"

        # Test sortable grouping with sorting capabilities
        puts "Testing sortable grouping with sorting capabilities..."
        sortable_query = AggregationProduct.query.group_by(:category, sortable: true)
        sortable_results = sortable_query.count
        
        # Test sorting capabilities of GroupedResult
        sorted_by_key = sortable_results.sort_by_key_asc
        assert sorted_by_key.is_a?(Array), "Sorted results should be an array of [key, value] pairs"
        assert sorted_by_key.length >= 3, "Should have sorted category pairs"
        
        # Test hash conversion
        hash_results = sortable_results.to_h
        assert hash_results.is_a?(Hash), "Should convert to hash"
        assert hash_results["electronics"] >= 4, "Electronics should have products"

        puts "✅ Sortable grouping capabilities work correctly"

        # Test sortable grouping with additional aggregation stages
        puts "Testing sortable grouping with aggregation pipeline..."
        expensive_products = AggregationProduct.query
                                              .where(:price.gt => 100)
                                              .group_by(:category, sortable: true)
        expensive_results = expensive_products.count.to_h

        assert expensive_results.is_a?(Hash), "Expensive results should be a hash"
        # Should have fewer total items when filtered
        total_expensive = expensive_results.values.sum
        assert total_expensive <= 7, "Should have fewer items when expensive filter applied"

        puts "✅ Sortable grouping with pipeline constraints works correctly"
      end
    end
  end

  def test_flatten_arrays_functionality
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "flatten arrays test") do
        puts "\n=== Testing Flatten Arrays Functionality ==="

        # Create test sales with array fields
        sales = [
          { 
            product_name: "Laptop Pro", 
            quantity: 2, 
            revenue: 2599.98,
            sale_date: Date.new(2023, 9, 15),
            customer_regions: ["north", "west"],
            payment_methods: ["credit", "paypal"]
          },
          { 
            product_name: "Smartphone X", 
            quantity: 1, 
            revenue: 899.99,
            sale_date: Date.new(2023, 9, 16),
            customer_regions: ["south", "east", "central"],
            payment_methods: ["credit"]
          },
          { 
            product_name: "Coffee Mug", 
            quantity: 5, 
            revenue: 79.95,
            sale_date: Date.new(2023, 9, 17),
            customer_regions: ["north"],
            payment_methods: ["cash", "debit", "credit"]
          }
        ]

        sales.each do |sale_data|
          sale = AggregationSale.new(sale_data)
          assert sale.save, "Sale for #{sale_data[:product_name]} should save"
        end

        # Test flatten_arrays on customer_regions field
        puts "Testing flatten_arrays on customer_regions..."
        flattened_regions = AggregationSale.query.group_by(:customer_regions, flatten_arrays: true)
        region_results = flattened_regions.count

        assert region_results.is_a?(Hash), "Results should be a hash"
        
        # Should have individual regions as separate groups
        expected_regions = ["north", "west", "south", "east", "central"]
        expected_regions.each do |region|
          assert region_results.key?(region), "Should have #{region} as a group key"
        end

        # Verify counts - north appears in 2 sales, others appear in 1 each
        assert_equal 2, region_results["north"], "North region should appear in 2 sales"
        assert_equal 1, region_results["west"], "West region should appear in 1 sale"

        puts "✅ Flatten arrays on customer_regions works correctly"

        # Test flatten_arrays on payment_methods field
        puts "Testing flatten_arrays on payment_methods..."
        flattened_payments = AggregationSale.query.group_by(:payment_methods, flatten_arrays: true)
        payment_results = flattened_payments.count

        expected_payments = ["credit", "paypal", "cash", "debit"]
        expected_payments.each do |payment|
          assert payment_results.key?(payment), "Should have #{payment} as a group key"
        end

        # Credit appears in all 3 sales
        assert_equal 3, payment_results["credit"], "Credit should appear in 3 sales"

        # PayPal, cash, debit each appear in 1 sale
        assert_equal 1, payment_results["paypal"], "PayPal should appear in 1 sale"

        puts "✅ Flatten arrays on payment_methods works correctly"

        # Test flatten_arrays with additional constraints
        puts "Testing flatten_arrays with query constraints..."
        high_value_regions = AggregationSale.query
                                          .where(:revenue.gt => 500)
                                          .group_by(:customer_regions, flatten_arrays: true)
        high_value_results = high_value_regions.count

        # Should only include regions from high-value sales (Laptop Pro and Smartphone X)
        assert high_value_results.key?("north"), "Should include north (from laptop)"
        assert high_value_results.key?("west"), "Should include west (from laptop)"
        assert high_value_results.key?("south"), "Should include south (from smartphone)"

        puts "✅ Flatten arrays with constraints works correctly"
      end
    end
  end

  def test_group_by_date_functionality
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(25, "group by date test") do
        puts "\n=== Testing Group By Date Functionality ==="

        # Create test sales across different dates and times
        sales_data = [
          { product_name: "Morning Sale 1", quantity: 1, revenue: 100.0, sale_date: DateTime.new(2023, 9, 15, 9, 30) },
          { product_name: "Morning Sale 2", quantity: 2, revenue: 200.0, sale_date: DateTime.new(2023, 9, 15, 10, 45) },
          { product_name: "Afternoon Sale", quantity: 1, revenue: 150.0, sale_date: DateTime.new(2023, 9, 15, 14, 20) },
          { product_name: "Next Day Sale 1", quantity: 3, revenue: 300.0, sale_date: DateTime.new(2023, 9, 16, 11, 15) },
          { product_name: "Next Day Sale 2", quantity: 1, revenue: 75.0, sale_date: DateTime.new(2023, 9, 16, 16, 45) },
          { product_name: "Weekend Sale", quantity: 2, revenue: 250.0, sale_date: DateTime.new(2023, 9, 17, 12, 0) },
          { product_name: "Next Week Sale", quantity: 1, revenue: 120.0, sale_date: DateTime.new(2023, 9, 22, 10, 30) }
        ]

        sales_data.each do |sale_data|
          sale = AggregationSale.new(sale_data)
          assert sale.save, "Sale #{sale_data[:product_name]} should save"
        end

        # Test daily grouping
        puts "Testing daily grouping..."
        daily_sales = AggregationSale.query.group_by_date(:sale_date, :day)
        daily_results = daily_sales.count

        assert daily_results.is_a?(Hash), "Results should be a hash"
        assert daily_results.keys.length >= 4, "Should have at least 4 different days"

        # Verify we have some data
        total_sales = daily_results.values.sum
        assert_equal 7, total_sales, "Should have all 7 sales distributed across days"

        puts "✅ Daily grouping works correctly"

        # Test monthly grouping
        puts "Testing monthly grouping..."
        monthly_sales = AggregationSale.query.group_by_date(:sale_date, :month)
        monthly_results = monthly_sales.count

        # All sales are in September 2023, so should have 1 group
        assert monthly_results.keys.length >= 1, "Should have at least 1 month group"
        
        # Verify total count
        total_monthly_sales = monthly_results.values.sum
        assert_equal 7, total_monthly_sales, "September 2023 should have all 7 sales"

        puts "✅ Monthly grouping works correctly"

        # Test hourly grouping
        puts "Testing hourly grouping..."
        hourly_sales = AggregationSale.query.group_by_date(:sale_date, :hour)
        hourly_results = hourly_sales.count

        assert hourly_results.keys.length >= 6, "Should have multiple hour groups"
        
        # Verify total count
        total_hourly_sales = hourly_results.values.sum
        assert_equal 7, total_hourly_sales, "Should have all 7 sales distributed across hours"

        puts "✅ Hourly grouping works correctly"

        # Test group_by_date with return_pointers option
        puts "Testing group_by_date with return_pointers..."
        daily_with_pointers = AggregationSale.query.group_by_date(:sale_date, :day, return_pointers: true)
        pointer_results = daily_with_pointers.count

        assert pointer_results.is_a?(Hash), "Results should be a hash"
        # Verify total count
        total_pointer_sales = pointer_results.values.sum
        assert_equal 7, total_pointer_sales, "Should have all 7 sales with return_pointers option"

        puts "✅ Group by date with return_pointers works correctly"

        # Test group_by_date with constraints
        puts "Testing group_by_date with query constraints..."
        high_revenue_daily = AggregationSale.query
                                          .where(:revenue.gt => 150)
                                          .group_by_date(:sale_date, :day)
        constrained_results = high_revenue_daily.count

        # Should only include sales with revenue > 150
        total_high_revenue_count = constrained_results.values.sum
        assert total_high_revenue_count <= 7, "Should have fewer sales when constrained"
        assert total_high_revenue_count >= 3, "Should have some high-revenue sales"

        puts "✅ Group by date with constraints works correctly"
      end
    end
  end

  def test_combined_grouping_features
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(25, "combined grouping features test") do
        puts "\n=== Testing Combined Grouping Features ==="

        # Create comprehensive test data
        products = [
          { name: "Product A", category: "tech", price: 299.99, tags: ["gadget", "popular"], launch_date: Date.new(2023, 6, 15) },
          { name: "Product B", category: "tech", price: 199.99, tags: ["gadget", "budget"], launch_date: Date.new(2023, 7, 10) },
          { name: "Product C", category: "home", price: 89.99, tags: ["furniture", "popular"], launch_date: Date.new(2023, 8, 5) }
        ]

        products.each do |product_data|
          product = AggregationProduct.new(product_data)
          assert product.save, "Product #{product_data[:name]} should save"
        end

        # Test sortable grouping with flatten_arrays
        puts "Testing sortable grouping with flatten_arrays..."
        sortable_flattened = AggregationProduct.query.group_by(:tags, 
                                                               flatten_arrays: true, 
                                                               sortable: true)
        combined_results = sortable_flattened.count.to_h

        assert combined_results.is_a?(Hash), "Results should be a hash"
        
        # Should have individual tags as groups
        expected_tags = ["gadget", "popular", "budget", "furniture"]
        expected_tags.each do |tag|
          assert combined_results.key?(tag), "Should have #{tag} as a group key"
        end

        # Verify we have the expected tag counts
        assert_equal 2, combined_results["popular"], "Popular tag should appear in 2 products"
        assert_equal 2, combined_results["gadget"], "Gadget tag should appear in 2 products"

        puts "✅ Combined sortable grouping with flatten_arrays works correctly"

        # Test group_by_date with additional pipeline stages
        puts "Testing group_by_date with complex aggregation..."
        complex_date_group = AggregationProduct.query
                                             .where(:price.gt => 150)
                                             .group_by_date(:launch_date, :month, return_pointers: false)
        complex_results = complex_date_group.count

        assert complex_results.is_a?(Hash), "Results should be a hash"
        
        # Should have fewer products when filtered by price
        total_expensive_products = complex_results.values.sum
        assert total_expensive_products <= 3, "Should have fewer products when price filtered"
        assert total_expensive_products >= 2, "Should have some expensive products"

        puts "✅ Complex group_by_date aggregation works correctly"

        puts "✅ All combined grouping features work correctly"
      end
    end
  end
end