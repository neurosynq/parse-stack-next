# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"

# Test model classes (defined at top level)
class ProductOperatorTest < Parse::Object
  parse_class "ProductOperatorTest"
  property :name, :string
  property :description, :string
  property :category, :string
  property :tags, :array
  property :price, :integer
  property :created_date, :date
end

class EventOperatorTest < Parse::Object
  parse_class "EventOperatorTest"
  property :name, :string
  property :event_date, :date
  property :status, :string
end

# Tests for regex, string, size, and date operators with MongoDB direct queries
class MongoDBOperatorsIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds = 30, &block)
    Timeout.timeout(seconds, &block)
  end

  # ==========================================================================
  # Test: Regex and String Operators
  # ==========================================================================

  def test_regex_and_string_operators_with_mongodb_direct
    with_parse_server do
      with_timeout(60) do
        puts "\n=== Testing Regex and String Operators ==="

        # Create test data
        products = [
          ProductOperatorTest.new(name: "iPhone 15 Pro", description: "Latest Apple smartphone", category: "Electronics", tags: ["phone", "apple", "premium"], price: 999),
          ProductOperatorTest.new(name: "iPhone 14", description: "Previous generation Apple phone", category: "Electronics", tags: ["phone", "apple"], price: 799),
          ProductOperatorTest.new(name: "Samsung Galaxy S24", description: "Android flagship phone", category: "Electronics", tags: ["phone", "android", "samsung"], price: 899),
          ProductOperatorTest.new(name: "MacBook Pro", description: "Apple laptop computer", category: "Computers", tags: ["laptop", "apple", "premium"], price: 1999),
          ProductOperatorTest.new(name: "iPad Air", description: "Apple tablet device", category: "Tablets", tags: ["tablet", "apple"], price: 599),
          ProductOperatorTest.new(name: "AirPods Pro", description: "Wireless earbuds by Apple", category: "Accessories", tags: ["audio", "apple", "wireless"], price: 249),
        ]
        products.each(&:save!)
        puts "Created #{products.length} test products"

        # Configure MongoDB direct
        begin
          require "mongo"
          require_relative "../../../lib/parse/mongodb"
          Parse::MongoDB.configure(uri: "mongodb://admin:password@localhost:27019/parse?authSource=admin", enabled: true)
          puts "MongoDB direct enabled: #{Parse::MongoDB.enabled?}"
        rescue LoadError => e
          skip "MongoDB gem not available: #{e.message}"
        end

        # --- Test 1: Regex/Like (case insensitive) ---
        puts "\n--- Test: Regex/Like operator ---"

        # Via Parse Server
        parse_results = ProductOperatorTest.query(:name.like => /iphone/i).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:name.like => /iphone/i): #{parse_names.inspect}"

        # Via MongoDB Direct
        direct_results = ProductOperatorTest.query(:name.like => /iphone/i).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:name.like => /iphone/i): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Regex results should match"
        assert_equal 2, direct_names.length, "Should find 2 iPhones"

        # --- Test 2: starts_with ---
        puts "\n--- Test: starts_with operator ---"

        parse_results = ProductOperatorTest.query(:name.starts_with => "iPhone").all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:name.starts_with => 'iPhone'): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:name.starts_with => "iPhone").results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:name.starts_with => 'iPhone'): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "starts_with results should match"
        assert_equal 2, direct_names.length, "Should find 2 products starting with iPhone"

        # --- Test 2b: ends_with ---
        puts "\n--- Test: ends_with operator ---"

        parse_results = ProductOperatorTest.query(:name.ends_with => "Pro").all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:name.ends_with => 'Pro'): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:name.ends_with => "Pro").results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:name.ends_with => 'Pro'): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "ends_with results should match"
        assert_equal 3, direct_names.length, "Should find 3 products ending with Pro"

        # --- Test 2c: ends_with with special characters ---
        puts "\n--- Test: ends_with with special characters ---"

        # Add a product with special characters in name for testing
        special_product = ProductOperatorTest.new(name: "Test File v1.0", description: "Test", category: "Test", tags: ["test"], price: 1)
        special_product.save!

        parse_results = ProductOperatorTest.query(:name.ends_with => "v1.0").all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:name.ends_with => 'v1.0'): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:name.ends_with => "v1.0").results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:name.ends_with => 'v1.0'): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "ends_with with special chars results should match"
        assert_equal 1, direct_names.length, "Should find 1 product ending with v1.0"

        # --- Test 3: Regex with description field ---
        puts "\n--- Test: Regex on description ---"

        parse_results = ProductOperatorTest.query(:description.like => /apple/i).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:description.like => /apple/i): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:description.like => /apple/i).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:description.like => /apple/i): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Description regex results should match"

        # --- Test 4: Array size operator ---
        puts "\n--- Test: Array size operator ---"

        parse_results = ProductOperatorTest.query(:tags.size => 3).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:tags.size => 3): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:tags.size => 3).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:tags.size => 3): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Size results should match"
        assert_equal 4, direct_names.length, "Should find 4 products with 3 tags"

        # --- Test 5: Array size with comparison ---
        puts "\n--- Test: Array size with comparison ---"

        parse_results = ProductOperatorTest.query(:tags.size => { :gte => 3 }).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:tags.size => { gte: 3 }): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:tags.size => { :gte => 3 }).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:tags.size => { gte: 3 }): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Size gte results should match"

        # --- Test 6: Combined regex + other constraints ---
        puts "\n--- Test: Regex + price constraint ---"

        parse_results = ProductOperatorTest.query(:name.like => /iphone/i, :price.lt => 900).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (regex + price < 900): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:name.like => /iphone/i, :price.lt => 900).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (regex + price < 900): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Combined regex + price results should match"
        assert_equal 1, direct_names.length, "Should find 1 iPhone under 900"

        # --- Test 7: Count with regex ---
        puts "\n--- Test: Count with regex ---"

        parse_count = ProductOperatorTest.query(:name.like => /iphone/i).count
        direct_count = ProductOperatorTest.query(:name.like => /iphone/i).count_direct
        puts "Parse Server count: #{parse_count}"
        puts "MongoDB Direct count: #{direct_count}"

        assert_equal parse_count, direct_count, "Regex counts should match"

        puts "\n✅ All regex and string operator tests passed!"
      end
    end
  end

  # ==========================================================================
  # Test: Date Operators
  # ==========================================================================

  def test_date_operators_with_mongodb_direct
    with_parse_server do
      with_timeout(60) do
        puts "\n=== Testing Date Operators ==="

        # Create test data with various dates
        now = Time.now.utc
        events = [
          EventOperatorTest.new(name: "Past Event 1", event_date: now - (30 * 24 * 60 * 60), status: "completed"),  # 30 days ago
          EventOperatorTest.new(name: "Past Event 2", event_date: now - (7 * 24 * 60 * 60), status: "completed"),   # 7 days ago
          EventOperatorTest.new(name: "Today Event", event_date: now, status: "active"),                             # today
          EventOperatorTest.new(name: "Future Event 1", event_date: now + (7 * 24 * 60 * 60), status: "scheduled"), # 7 days from now
          EventOperatorTest.new(name: "Future Event 2", event_date: now + (30 * 24 * 60 * 60), status: "scheduled"), # 30 days from now
        ]
        events.each(&:save!)
        puts "Created #{events.length} test events"

        # Configure MongoDB direct
        begin
          require "mongo"
          require_relative "../../../lib/parse/mongodb"
          Parse::MongoDB.configure(uri: "mongodb://admin:password@localhost:27019/parse?authSource=admin", enabled: true)
        rescue LoadError => e
          skip "MongoDB gem not available: #{e.message}"
        end

        # --- Test 1: Date greater than (future events) ---
        puts "\n--- Test: Date greater than (future events) ---"

        parse_results = EventOperatorTest.query(:event_date.gt => now).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:event_date.gt => now): #{parse_names.inspect}"

        direct_results = EventOperatorTest.query(:event_date.gt => now).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:event_date.gt => now): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Future events should match"
        assert_equal 2, direct_names.length, "Should find 2 future events"

        # --- Test 2: Date less than (past events) ---
        puts "\n--- Test: Date less than (past events) ---"

        parse_results = EventOperatorTest.query(:event_date.lt => now).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:event_date.lt => now): #{parse_names.inspect}"

        direct_results = EventOperatorTest.query(:event_date.lt => now).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:event_date.lt => now): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Past events should match"
        assert_equal 2, direct_names.length, "Should find 2 past events"

        # --- Test 3: Date between (range query) ---
        puts "\n--- Test: Date between (range query) ---"

        start_date = now - (10 * 24 * 60 * 60)  # 10 days ago
        end_date = now + (10 * 24 * 60 * 60)    # 10 days from now

        parse_results = EventOperatorTest.query(:event_date.gte => start_date, :event_date.lte => end_date).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (between -10 and +10 days): #{parse_names.inspect}"

        direct_results = EventOperatorTest.query(:event_date.gte => start_date, :event_date.lte => end_date).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (between -10 and +10 days): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Date range results should match"
        assert_equal 3, direct_names.length, "Should find 3 events in range"

        # --- Test 4: Date + status combined ---
        puts "\n--- Test: Date + status combined ---"

        parse_results = EventOperatorTest.query(:event_date.gt => now, :status => "scheduled").all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (future + scheduled): #{parse_names.inspect}"

        direct_results = EventOperatorTest.query(:event_date.gt => now, :status => "scheduled").results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (future + scheduled): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Combined date + status results should match"

        # --- Test 5: Order by date ---
        puts "\n--- Test: Order by date ---"

        parse_results = EventOperatorTest.query.order(:event_date.asc).all
        parse_names = parse_results.map(&:name)
        puts "Parse Server (order by date asc): #{parse_names.inspect}"

        direct_results = EventOperatorTest.query.order(:event_date.asc).results_direct
        direct_names = direct_results.map(&:name)
        puts "MongoDB Direct (order by date asc): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Date ordering should match"
        assert_equal "Past Event 1", direct_names.first, "Oldest event should be first"

        puts "\n✅ All date operator tests passed!"
      end
    end
  end

  # ==========================================================================
  # Test: Array Contains and Comparison Operators
  # ==========================================================================

  def test_array_and_comparison_operators_with_mongodb_direct
    with_parse_server do
      with_timeout(60) do
        puts "\n=== Testing Array and Comparison Operators ==="

        # Create fresh test data
        products = [
          ProductOperatorTest.new(name: "Product A", tags: ["electronics", "premium", "wireless"], price: 100),
          ProductOperatorTest.new(name: "Product B", tags: ["electronics", "budget"], price: 50),
          ProductOperatorTest.new(name: "Product C", tags: ["home", "premium"], price: 200),
          ProductOperatorTest.new(name: "Product D", tags: ["electronics"], price: 75),
          ProductOperatorTest.new(name: "Product E", tags: [], price: 25),
        ]
        products.each(&:save!)
        puts "Created #{products.length} test products"

        # Configure MongoDB direct
        begin
          require "mongo"
          require_relative "../../../lib/parse/mongodb"
          Parse::MongoDB.configure(uri: "mongodb://admin:password@localhost:27019/parse?authSource=admin", enabled: true)
        rescue LoadError => e
          skip "MongoDB gem not available: #{e.message}"
        end

        # --- Test 1: Array contains (in) ---
        puts "\n--- Test: Array contains ---"

        parse_results = ProductOperatorTest.query(:tags.in => ["premium"]).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:tags.in => ['premium']): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:tags.in => ["premium"]).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:tags.in => ['premium']): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Array contains results should match"

        # --- Test 2: Array contains all ---
        puts "\n--- Test: Array contains_all ---"

        parse_results = ProductOperatorTest.query(:tags.contains_all => ["electronics", "premium"]).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:tags.contains_all => ['electronics', 'premium']): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:tags.contains_all => ["electronics", "premium"]).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:tags.contains_all => ['electronics', 'premium']): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Contains all results should match"

        # --- Test 3: Empty array ---
        puts "\n--- Test: Empty array ---"

        parse_results = ProductOperatorTest.query(:tags.empty_or_nil => true).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:tags.empty_or_nil => true): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:tags.empty_or_nil => true).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:tags.empty_or_nil => true): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Empty array results should match"
        assert_includes direct_names, "Product E", "Should find product with empty tags"

        # --- Test 4: Price range (between) ---
        puts "\n--- Test: Price between ---"

        parse_results = ProductOperatorTest.query(:price.gte => 50, :price.lte => 100).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (50 <= price <= 100): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:price.gte => 50, :price.lte => 100).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (50 <= price <= 100): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Price range results should match"

        # --- Test 5: Not equal ---
        puts "\n--- Test: Not equal ---"

        parse_results = ProductOperatorTest.query(:price.ne => 100).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (:price.ne => 100): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:price.ne => 100).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (:price.ne => 100): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Not equal results should match"

        # --- Test 6: Combined array + price ---
        puts "\n--- Test: Combined array + price ---"

        parse_results = ProductOperatorTest.query(:tags.in => ["electronics"], :price.lt => 100).all
        parse_names = parse_results.map(&:name).sort
        puts "Parse Server (electronics + price < 100): #{parse_names.inspect}"

        direct_results = ProductOperatorTest.query(:tags.in => ["electronics"], :price.lt => 100).results_direct
        direct_names = direct_results.map(&:name).sort
        puts "MongoDB Direct (electronics + price < 100): #{direct_names.inspect}"

        assert_equal parse_names, direct_names, "Combined array + price results should match"

        puts "\n✅ All array and comparison operator tests passed!"
      end
    end
  end
end
