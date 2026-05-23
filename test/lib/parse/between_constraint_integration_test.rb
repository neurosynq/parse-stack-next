require_relative "../../test_helper_integration"

# Test models for between constraint testing
class BetweenTestProduct < Parse::Object
  parse_class "BetweenTestProduct"

  property :name, :string
  property :price, :float
  property :rating, :float
  property :stock_count, :integer
  property :release_date, :date
  property :featured, :boolean, default: false
end

class BetweenTestUser < Parse::Object
  parse_class "BetweenTestUser"

  property :name, :string
  property :age, :integer
  property :height, :float  # in cm
  property :join_date, :date
  property :score, :integer
  property :last_name, :string
end

class BetweenConstraintIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_between_constraint_with_numbers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "between constraint with numbers test") do
        puts "\n=== Testing Between Constraint with Numbers ==="

        # Create test products with different prices
        product1 = BetweenTestProduct.new(name: "Cheap Product", price: 5.99, rating: 3.0, stock_count: 100)
        assert product1.save, "Cheap product should save"

        product2 = BetweenTestProduct.new(name: "Mid-range Product", price: 25.50, rating: 4.2, stock_count: 50)
        assert product2.save, "Mid-range product should save"

        product3 = BetweenTestProduct.new(name: "Premium Product", price: 99.99, rating: 4.8, stock_count: 10)
        assert product3.save, "Premium product should save"

        product4 = BetweenTestProduct.new(name: "Luxury Product", price: 199.99, rating: 5.0, stock_count: 5)
        assert product4.save, "Luxury product should save"

        # Test between constraint with float prices
        mid_range_products = BetweenTestProduct.query
          .where(:price.between => [20.0, 100.0])
          .results

        assert_equal 2, mid_range_products.length, "Should find 2 products with prices between 20-100"
        prices = mid_range_products.map(&:price)
        assert_includes prices, 25.50, "Should include mid-range product"
        assert_includes prices, 99.99, "Should include premium product"
        refute_includes prices, 5.99, "Should not include cheap product"
        refute_includes prices, 199.99, "Should not include luxury product"

        # Test between constraint with integer stock counts
        low_stock_products = BetweenTestProduct.query
          .where(:stock_count.between => [1, 20])
          .results

        assert_equal 2, low_stock_products.length, "Should find 2 products with low stock"
        stock_counts = low_stock_products.map(&:stock_count)
        assert_includes stock_counts, 10, "Should include premium product stock"
        assert_includes stock_counts, 5, "Should include luxury product stock"

        # Test between constraint with ratings
        high_rated_products = BetweenTestProduct.query
          .where(:rating.between => [4.0, 5.0])
          .results

        assert_equal 3, high_rated_products.length, "Should find 3 highly rated products"
        ratings = high_rated_products.map(&:rating)
        assert_includes ratings, 4.2, "Should include mid-range product"
        assert_includes ratings, 4.8, "Should include premium product"
        assert_includes ratings, 5.0, "Should include luxury product"

        puts "✅ Between constraint with numbers works correctly"
      end
    end
  end

  def test_between_constraint_with_dates
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "between constraint with dates test") do
        puts "\n=== Testing Between Constraint with Dates ==="

        # Create test users with different join dates
        old_user = BetweenTestUser.new(
          name: "Old User",
          age: 45,
          height: 175.0,
          join_date: Date.parse("2020-01-15"),
          score: 100,
        )
        assert old_user.save, "Old user should save"

        recent_user1 = BetweenTestUser.new(
          name: "Recent User 1",
          age: 28,
          height: 168.5,
          join_date: Date.parse("2023-06-10"),
          score: 85,
        )
        assert recent_user1.save, "Recent user 1 should save"

        recent_user2 = BetweenTestUser.new(
          name: "Recent User 2",
          age: 32,
          height: 180.2,
          join_date: Date.parse("2023-11-20"),
          score: 92,
        )
        assert recent_user2.save, "Recent user 2 should save"

        new_user = BetweenTestUser.new(
          name: "New User",
          age: 26,
          height: 165.0,
          join_date: Date.parse("2024-08-01"),
          score: 75,
        )
        assert new_user.save, "New user should save"

        # Test between constraint with dates
        start_date = Date.parse("2023-01-01")
        end_date = Date.parse("2023-12-31")

        users_2023 = BetweenTestUser.query
          .where(:join_date.between => [start_date, end_date])
          .results

        assert_equal 2, users_2023.length, "Should find 2 users who joined in 2023"
        names = users_2023.map(&:name)
        assert_includes names, "Recent User 1", "Should include Recent User 1"
        assert_includes names, "Recent User 2", "Should include Recent User 2"
        refute_includes names, "Old User", "Should not include Old User"
        refute_includes names, "New User", "Should not include New User"

        # Test between with Time objects
        start_time = Time.parse("2023-06-01")
        end_time = Time.parse("2024-12-31")

        recent_users = BetweenTestUser.query
          .where(:join_date.between => [start_time, end_time])
          .results

        assert_equal 3, recent_users.length, "Should find 3 users who joined recently"
        recent_names = recent_users.map(&:name)
        assert_includes recent_names, "Recent User 1", "Should include Recent User 1"
        assert_includes recent_names, "Recent User 2", "Should include Recent User 2"
        assert_includes recent_names, "New User", "Should include New User"

        puts "✅ Between constraint with dates works correctly"
      end
    end
  end

  def test_between_constraint_with_combined_filters
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "between constraint with combined filters test") do
        puts "\n=== Testing Between Constraint with Combined Filters ==="

        # Create test users with various attributes
        user1 = BetweenTestUser.new(name: "Young Tall User", age: 22, height: 185.0, score: 88)
        assert user1.save, "User 1 should save"

        user2 = BetweenTestUser.new(name: "Adult Average User", age: 35, height: 172.0, score: 75)
        assert user2.save, "User 2 should save"

        user3 = BetweenTestUser.new(name: "Adult Tall User", age: 40, height: 188.0, score: 92)
        assert user3.save, "User 3 should save"

        user4 = BetweenTestUser.new(name: "Young Short User", age: 25, height: 160.0, score: 80)
        assert user4.save, "User 4 should save"

        # Test multiple between constraints
        adult_tall_users = BetweenTestUser.query
          .where(:age.between => [30, 50])
          .where(:height.between => [175.0, 190.0])
          .results

        assert_equal 1, adult_tall_users.length, "Should find 1 adult tall user"
        assert_equal "Adult Tall User", adult_tall_users.first.name, "Should be the Adult Tall User"

        # Test between constraint with other constraints
        young_high_scorers = BetweenTestUser.query
          .where(:age.between => [20, 30])
          .where(:score.gt => 85)
          .results

        assert_equal 1, young_high_scorers.length, "Should find 1 young high scorer"
        assert_equal "Young Tall User", young_high_scorers.first.name, "Should be the Young Tall User"

        # Test between constraint with ordering
        ordered_adults = BetweenTestUser.query
          .where(:age.between => [30, 50])
          .order(:age.asc)
          .results

        assert_equal 2, ordered_adults.length, "Should find 2 adults"
        assert_equal 35, ordered_adults.first.age, "First should be younger adult"
        assert_equal 40, ordered_adults.last.age, "Last should be older adult"

        puts "✅ Between constraint with combined filters works correctly"
      end
    end
  end

  def test_between_constraint_edge_cases_and_errors
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "between constraint edge cases test") do
        puts "\n=== Testing Between Constraint Edge Cases and Error Handling ==="

        # Create test data
        product = BetweenTestProduct.new(name: "Test Product", price: 50.0, stock_count: 25)
        assert product.save, "Test product should save"

        # Test with exact boundary values
        boundary_products = BetweenTestProduct.query
          .where(:price.between => [50.0, 50.0])
          .results

        assert_equal 1, boundary_products.length, "Should find product at exact boundary"

        # Test with wider range that includes the product
        wider_products = BetweenTestProduct.query
          .where(:price.between => [25.0, 100.0])
          .results

        assert_equal 1, wider_products.length, "Should find product in wider range"

        # Test with no matching results
        no_results = BetweenTestProduct.query
          .where(:price.between => [100.0, 200.0])
          .results

        assert_empty no_results, "Should return empty array when no matches"

        # Test error handling for invalid input
        assert_raises(ArgumentError) do
          BetweenTestProduct.query.where(:price.between => [50.0]).results
        end

        assert_raises(ArgumentError) do
          BetweenTestProduct.query.where(:price.between => [50.0, 75.0, 100.0]).results
        end

        assert_raises(ArgumentError) do
          BetweenTestProduct.query.where(:price.between => 50.0).results
        end

        puts "✅ Between constraint edge cases and error handling work correctly"
      end
    end
  end

  def test_between_constraint_vs_manual_gte_lte
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "between vs manual gte/lte comparison test") do
        puts "\n=== Testing Between Constraint vs Manual GTE/LTE ==="

        # Create test data
        5.times do |i|
          user = BetweenTestUser.new(name: "User #{i}", age: 20 + i * 5, score: 70 + i * 5)
          assert user.save, "User #{i} should save"
        end

        # Test between constraint
        between_users = BetweenTestUser.query
          .where(:age.between => [25, 35])
          .order(:age.asc)
          .results

        # Test equivalent manual constraints
        manual_users = BetweenTestUser.query
          .where(:age.gte => 25)
          .where(:age.lte => 35)
          .order(:age.asc)
          .results

        # Results should be identical
        assert_equal between_users.length, manual_users.length, "Both approaches should return same count"
        assert_equal 3, between_users.length, "Should find 3 users in age range"

        between_users.zip(manual_users).each_with_index do |(between_user, manual_user), index|
          assert_equal between_user.id, manual_user.id, "User #{index} should be the same in both results"
          assert_equal between_user.age, manual_user.age, "Ages should match"
        end

        puts "✅ Between constraint produces same results as manual GTE/LTE"
      end
    end
  end

  def test_between_constraint_with_strings
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "between constraint with strings test") do
        puts "\n=== Testing Between Constraint with Strings (Alphabetical) ==="

        # Create test users with names spanning the alphabet
        user_names = [
          ["Alice", "Anderson"],
          ["Bob", "Baker"],
          ["Charlie", "Chen"],
          ["David", "Davis"],
          ["Emma", "Evans"],
          ["Frank", "Foster"],
          ["Grace", "Green"],
          ["Henry", "Harris"],
        ]

        user_names.each_with_index do |(first, last), index|
          user = BetweenTestUser.new(
            name: first,
            last_name: last,
            age: 25 + index,
            score: 70 + index * 3,
          )
          assert user.save, "User #{first} should save"
        end

        # Test between constraint with first names (alphabetical range)
        middle_alphabet_users = BetweenTestUser.query
          .where(:name.between => ["Charlie", "Frank"])
          .order(:name.asc)
          .results

        assert_equal 4, middle_alphabet_users.length, "Should find 4 users with names C-F"
        names = middle_alphabet_users.map(&:name)
        expected_names = ["Charlie", "David", "Emma", "Frank"]
        assert_equal expected_names, names, "Should include names from Charlie to Frank alphabetically"

        # Test between constraint with last names
        middle_last_names = BetweenTestUser.query
          .where(:last_name.between => ["Chen", "Foster"])
          .order(:last_name.asc)
          .results

        assert_equal 4, middle_last_names.length, "Should find 4 users with last names Chen-Foster"
        last_names = middle_last_names.map(&:last_name)
        expected_last_names = ["Chen", "Davis", "Evans", "Foster"]
        assert_equal expected_last_names, last_names, "Should include last names from Chen to Foster alphabetically"

        # Test exact boundary matching with strings
        exact_boundary = BetweenTestUser.query
          .where(:name.between => ["Emma", "Emma"])
          .results

        assert_equal 1, exact_boundary.length, "Should find exactly Emma"
        assert_equal "Emma", exact_boundary.first.name, "Should be Emma"

        # Test case sensitivity (uppercase vs lowercase)
        case_sensitive_test = BetweenTestUser.query
          .where(:name.between => ["alice", "emma"])
          .results

        # In most database systems, uppercase letters come before lowercase in ASCII/Unicode sorting
        # So "Alice" < "alice", which means this query might not match as expected
        # The exact behavior depends on Parse Server's string comparison implementation
        puts "Case sensitive test returned #{case_sensitive_test.length} results"

        # Test string ranges that include special characters (if any exist)
        wide_range_test = BetweenTestUser.query
          .where(:name.between => ["A", "Z"])
          .results

        assert_equal 8, wide_range_test.length, "Should find all users with names A-Z"

        # Test empty range (no matches)
        no_matches = BetweenTestUser.query
          .where(:name.between => ["Zach", "Zoe"])
          .results

        assert_empty no_matches, "Should find no users with names Zach-Zoe"

        puts "✅ Between constraint with strings works correctly"
      end
    end
  end

  def test_between_constraint_string_vs_manual_comparison
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "string between vs manual comparison test") do
        puts "\n=== Testing String Between vs Manual String Comparison ==="

        # Create test data with various names
        names = ["Apple", "Banana", "Cherry", "Date", "Elderberry"]
        names.each_with_index do |name, index|
          user = BetweenTestUser.new(name: name, age: 20 + index, score: 80 + index)
          assert user.save, "User #{name} should save"
        end

        # Test between constraint for strings
        between_users = BetweenTestUser.query
          .where(:name.between => ["Banana", "Date"])
          .order(:name.asc)
          .results

        # Test equivalent manual string constraints
        manual_users = BetweenTestUser.query
          .where(:name.gte => "Banana")
          .where(:name.lte => "Date")
          .order(:name.asc)
          .results

        # Results should be identical
        assert_equal between_users.length, manual_users.length, "Both approaches should return same count"
        assert_equal 3, between_users.length, "Should find 3 users with names Banana-Date"

        between_users.zip(manual_users).each_with_index do |(between_user, manual_user), index|
          assert_equal between_user.id, manual_user.id, "User #{index} should be the same in both results"
          assert_equal between_user.name, manual_user.name, "Names should match"
        end

        expected_names = ["Banana", "Cherry", "Date"]
        actual_names = between_users.map(&:name)
        assert_equal expected_names, actual_names, "Should return names in alphabetical order"

        puts "✅ String between constraint produces same results as manual string comparison"
      end
    end
  end
end
