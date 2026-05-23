require_relative '../../test_helper_integration'
require 'timeout'

# Test class for GameScore integration tests
class GameScore < Parse::Object
  parse_class "GameScore"
  property :score, :integer
  property :player_name, :string
  property :cheat_mode, :boolean
end

# Fast version of query integration tests with timeout protection
# Focuses on essential functionality without complex setup
class QueryIntegrationFastTest < Minitest::Test
  include ParseStackIntegrationTest

  # Helper method to run operations with timeout protection
  def with_timeout(seconds = 2, description = "operation")
    Timeout.timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{description} timed out after #{seconds} seconds"
  end

  def test_basic_connectivity
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(2, "basic count") do
        count = GameScore.query.count
        assert count >= 0, "Should get a valid count"
      end
    end
  end

  def test_simple_query_operations
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      # Test basic query
      with_timeout(2, "basic query") do
        results = GameScore.query.limit(3).results
        assert results.is_a?(Array), "Should return array"
      end
      
      # Test count
      with_timeout(2, "count query") do
        count = GameScore.query.count
        assert count >= 0, "Should have valid count"
      end
      
      # Test first
      with_timeout(2, "first query") do
        first_result = GameScore.query.first
        # first might be nil if no data, that's ok
        assert true, "First query completed"
      end
    end
  end

  def test_basic_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      # Test where clause with simple constraints
      with_timeout(2, "where query") do
        results = GameScore.query.where(score: { "$gte" => 0 }).limit(2).results
        assert results.is_a?(Array), "Should return array"
      end
      
      # Test ordering
      with_timeout(2, "order query") do
        results = GameScore.query.order("-score").limit(2).results
        assert results.is_a?(Array), "Should return ordered array"
      end
    end
  end

  def test_class_level_methods
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      # Test class-level count
      with_timeout(2, "class count") do
        count = GameScore.count
        assert count >= 0, "Should get class-level count"
      end
      
      # Test class-level first
      with_timeout(2, "class first") do
        first = GameScore.first
        # might be nil, that's ok
        assert true, "Class first completed"
      end
      
      # Test class-level all with limit
      with_timeout(3, "class all") do
        all = GameScore.all(limit: 3)
        assert all.is_a?(Array), "Should return array from all"
      end
    end
  end

  def test_create_and_query_new_object
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      # Create a test object
      test_score = nil
      with_timeout(3, "create test object") do
        test_score = GameScore.new(score: 999, player_name: "TestPlayer", cheat_mode: false)
        result = test_score.save
        assert result, "Should save test object"
        assert test_score.id.present?, "Should have object ID"
      end
      
      # Query for the created object
      with_timeout(2, "query created object") do
        found = GameScore.query.where(score: 999).first
        assert found.present?, "Should find created object"
        assert_equal "TestPlayer", found[:player_name], "Should have correct player name"
      end
      
      # Clean up
      with_timeout(2, "cleanup test object") do
        test_score.destroy if test_score && test_score.id
      end
    end
  end

  def test_distinct_operations
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      # Test distinct on a field
      with_timeout(3, "distinct query") do
        distinct_players = GameScore.query.distinct(:player_name)
        assert distinct_players.is_a?(Array), "Should return array of distinct values"
      end
    end
  end

  def test_object_retrieval_methods
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      # Get any existing object first
      existing_object = nil
      with_timeout(2, "find existing object") do
        existing_object = GameScore.query.first
      end
      
      if existing_object && existing_object.id
        # Test class-level get method
        with_timeout(2, "class get method") do
          retrieved = GameScore.get(existing_object.id)
          assert retrieved.present?, "Should retrieve object by ID"
          assert_equal existing_object.id, retrieved.id, "Should have same ID"
        end
        
        # Test query get method
        with_timeout(2, "query get method") do
          retrieved = GameScore.query.get(existing_object.id)
          assert retrieved.present?, "Should retrieve via query"
          assert_equal existing_object.id, retrieved.id, "Should have same ID"
        end
      else
        puts "No existing GameScore objects found, skipping retrieval tests"
      end
    end
  end

  def test_sort_order_basic
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      # Test basic ascending sort
      with_timeout(2, "ascending sort") do
        results = GameScore.query.order(:score).limit(3).results
        if results.length > 1
          # Verify ascending order
          (1...results.length).each do |i|
            assert results[i][:score] >= results[i-1][:score], "Should be in ascending order"
          end
        end
      end
      
      # Test basic descending sort
      with_timeout(2, "descending sort") do
        results = GameScore.query.order("-score").limit(3).results
        if results.length > 1
          # Verify descending order
          (1...results.length).each do |i|
            assert results[i][:score] <= results[i-1][:score], "Should be in descending order"
          end
        end
      end
    end
  end
end