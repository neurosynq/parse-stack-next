require_relative "../../test_helper_integration"
require "timeout"

# Test classes based on Parse Server examples
class GameScore < Parse::Object
  parse_class "GameScore"
  property :score, :integer
  property :player_name, :string
  property :cheat_mode, :boolean
  property :location, :geopoint
  # Note: created_at and updated_at are already defined as BASE_KEYS in Parse::Object
end

class Player < Parse::Object
  parse_class "Player"
  property :name, :string
  property :email, :string
  property :level, :integer
  property :wins, :integer
  property :losses, :integer
  property :hometown, :string
end

class Team < Parse::Object
  parse_class "Team"
  property :name, :string
  property :city, :string
  property :wins, :integer
  property :losses, :integer
  property :captain, :pointer, class_name: "Player"
  property :players, :array
end

class Comment < Parse::Object
  parse_class "Comment"
  property :text, :string
  property :author, :pointer, class_name: "Player"
  property :post, :pointer, class_name: "Post"
  property :likes, :integer
end

class Post < Parse::Object
  parse_class "Post"
  property :title, :string
  property :content, :string
  property :author, :pointer, class_name: "Player"
  property :tags, :array
  property :image, :file
end

# Port of JavaScript Query test suite focusing on GameScore data
# Tests query functionality against real Parse Server with existing data
class QueryIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Helper method to run operations with timeout protection
  def with_timeout(seconds = 2, description = "operation")
    Timeout.timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{description} timed out after #{seconds} seconds"
  end

  def setup_test_data
    # Create minimal test GameScore records efficiently
    scores = [
      { score: 100, player_name: "Alice", cheat_mode: false },
      { score: 250, player_name: "Bob", cheat_mode: true },
      { score: 150, player_name: "Charlie", cheat_mode: false },
    ]

    scores.each_with_index do |score_data, index|
      with_timeout(3, "creating test score #{index}") do
        game_score = GameScore.new(score_data)
        result = game_score.save
        unless result
          puts "Warning: Failed to save test score #{index}: #{game_score.errors.inspect}" if ENV["VERBOSE_TESTS"]
        end
      end
    end
  end

  def test_blanket_queries
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup_test_data") do
        setup_test_data
      end

      # Test basic query that should match all GameScore objects
      with_timeout(3, "basic query") do
        query = GameScore.query.limit(50)
        results = query.results

        assert results.length > 0, "Should find GameScore objects"

        # Verify all results are GameScore objects (limit check to avoid long loops)
        results.first(3).each do |result|
          puts "DEBUG: Checking result keys: #{result.keys}"
          assert_equal "GameScore", result.parse_class, "Should be GameScore objects"
          assert result.id.present?, "Should have object IDs"
        end
      end
    end
  end

  # Simple fast test to verify basic connectivity
  def test_simple_count
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(2, "simple count") do
        count = GameScore.query.count
        assert count >= 0, "Should get a valid count"
      end
    end
  end

  # Test just one simple operation without complex setup
  def test_simple_query_without_setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(2, "simple query") do
        # Just try to query existing data without creating new data
        query = GameScore.query.limit(1)
        results = query.results
        # Don't assert anything about results - just verify query doesn't hang
        assert true, "Query completed without timeout"
      end
    end
  end

  def test_equality_queries
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup_test_data") do
        setup_test_data
      end

      # Test equalTo query for score
      with_timeout(2, "score query") do
        query = GameScore.query.where(score: 100)
        results = query.results

        results.each do |result|
          assert_equal 100, result[:score], "Should have score of 100"
        end
      end

      # Test equalTo query for player_name
      with_timeout(2, "player_name query") do
        query = GameScore.query.where(player_name: "Alice")
        results = query.results

        results.each do |result|
          assert_equal "Alice", result[:player_name], "Should have player_name Alice"
        end
      end

      # Test equalTo query for boolean
      with_timeout(2, "boolean query") do
        query = GameScore.query.where(cheat_mode: true)
        results = query.results

        results.each do |result|
          assert_equal true, result[:cheat_mode], "Should have cheat_mode true"
        end
      end
    end
  end

  def test_inequality_queries
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test greater than query
      query = GameScore.query.where(score: { "$gt" => 150 })
      results = query.results

      results.each do |result|
        assert result[:score] > 150, "Score should be greater than 150, got #{result[:score]}"
      end

      # Test less than query
      query = GameScore.query.where(score: { "$lt" => 200 })
      results = query.results

      results.each do |result|
        assert result[:score] < 200, "Score should be less than 200, got #{result[:score]}"
      end

      # Test greater than or equal to
      query = GameScore.query.where(score: { "$gte" => 100 })
      results = query.results

      results.each do |result|
        assert result[:score] >= 100, "Score should be >= 100, got #{result[:score]}"
      end

      # Test less than or equal to
      query = GameScore.query.where(score: { "$lte" => 250 })
      results = query.results

      results.each do |result|
        assert result[:score] <= 250, "Score should be <= 250, got #{result[:score]}"
      end
    end
  end

  def test_contained_in_queries
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test containedIn query for player names
      query = GameScore.query.where(player_name: { "$in" => ["Alice", "Bob", "Charlie"] })
      results = query.results

      valid_names = ["Alice", "Bob", "Charlie"]
      results.each do |result|
        assert valid_names.include?(result[:player_name]),
               "Player name should be one of #{valid_names}, got #{result[:player_name]}"
      end

      # Test containedIn query for scores
      query = GameScore.query.where(score: { "$in" => [100, 150, 250] })
      results = query.results

      valid_scores = [100, 150, 250]
      results.each do |result|
        assert valid_scores.include?(result[:score]),
               "Score should be one of #{valid_scores}, got #{result[:score]}"
      end
    end
  end

  def test_not_contained_in_queries
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test notContainedIn query
      query = GameScore.query.where(player_name: { "$nin" => ["Alice", "Bob"] })
      results = query.results

      excluded_names = ["Alice", "Bob"]
      results.each do |result|
        refute excluded_names.include?(result[:player_name]),
               "Player name should not be one of #{excluded_names}, got #{result[:player_name]}"
      end
    end
  end

  def test_exists_queries
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test exists query for score field
      query = GameScore.query.where(score: { "$exists" => true })
      results = query.results

      results.each do |result|
        assert result[:score].present?, "Score field should exist and have a value"
      end

      # Test exists query for player_name field
      query = GameScore.query.where(player_name: { "$exists" => true })
      results = query.results

      results.each do |result|
        assert result[:player_name].present?, "Player name field should exist and have a value"
      end
    end
  end

  def test_regex_queries
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test regex query for names starting with specific letters
      query = GameScore.query.where(player_name: { "$regex" => "^A.*" })
      results = query.results

      results.each do |result|
        assert result[:player_name].start_with?("A"),
               "Player name should start with 'A', got #{result[:player_name]}"
      end

      # Test regex query for names containing specific letters
      query = GameScore.query.where(player_name: { "$regex" => ".*i.*" })
      results = query.results

      results.each do |result|
        assert result[:player_name].include?("i"),
               "Player name should contain 'i', got #{result[:player_name]}"
      end
    end
  end

  def test_compound_queries
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test compound query: high score AND cheat mode
      query = GameScore.query.where(
        score: { "$gt" => 200 },
        cheat_mode: true,
      )
      results = query.results

      results.each do |result|
        assert result[:score] > 200, "Score should be > 200"
        assert_equal true, result[:cheat_mode], "Cheat mode should be true"
      end

      # Test compound query: specific score range AND specific player
      query = GameScore.query.where(
        score: { "$gte" => 100, "$lte" => 200 },
        player_name: { "$in" => ["Alice", "Charlie"] },
      )
      results = query.results

      results.each do |result|
        assert result[:score] >= 100 && result[:score] <= 200,
               "Score should be between 100-200, got #{result[:score]}"
        assert ["Alice", "Charlie"].include?(result[:player_name]),
               "Player should be Alice or Charlie, got #{result[:player_name]}"
      end
    end
  end

  def test_limit_and_skip
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test limit
      query = GameScore.query.limit(3)
      results = query.results

      assert results.length <= 3, "Should return at most 3 results"

      # Test skip
      all_query = GameScore.query.limit(50)
      all_results = all_query.results

      if all_results.length > 2
        skip_query = GameScore.query.skip(2)
        skip_results = skip_query.results

        assert skip_results.length == (all_results.length - 2),
               "Skip should return #{all_results.length - 2} results, got #{skip_results.length}"
      end
    end
  end

  def test_ordering
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test ascending order by score
      query = GameScore.query.order(:score)
      results = query.results

      if results.length > 1
        previous_score = results.first[:score]
        results[1..-1].each do |result|
          current_score = result[:score]
          assert current_score >= previous_score,
                 "Scores should be in ascending order: #{previous_score} should be <= #{current_score}"
          previous_score = current_score
        end
      end

      # Test descending order by score
      query = GameScore.query.order("-score")
      results = query.results

      if results.length > 1
        previous_score = results.first[:score]
        results[1..-1].each do |result|
          current_score = result[:score]
          assert current_score <= previous_score,
                 "Scores should be in descending order: #{previous_score} should be >= #{current_score}"
          previous_score = current_score
        end
      end
    end
  end

  # Parse Stack Ruby SDK: Comprehensive Sort Order Tests
  def test_sort_order_comprehensive
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create varied test data for sorting
      test_data = [
        { score: 150, player_name: "Charlie", cheat_mode: false },
        { score: 300, player_name: "Alice", cheat_mode: true },
        { score: 100, player_name: "Bob", cheat_mode: false },
        { score: 250, player_name: "Diana", cheat_mode: true },
        { score: 75, player_name: "Eve", cheat_mode: false },
        { score: 400, player_name: "Alice", cheat_mode: true },  # Duplicate player name
        { score: 200, player_name: "Bob", cheat_mode: false },    # Duplicate player name
      ]

      test_data.each do |data|
        score = GameScore.new(data)
        assert score.save, "Should save test score"
      end

      # Test 1: Sort by score ascending (symbol)
      asc_by_score = GameScore.query.order(:score).results
      verify_ascending_order(asc_by_score, :score, "score ascending")

      # Test 2: Sort by score ascending (string)
      asc_by_score_str = GameScore.query.order("score").results
      verify_ascending_order(asc_by_score_str, :score, "score ascending (string)")

      # Test 3: Sort by score descending (string with minus)
      desc_by_score = GameScore.query.order("-score").results
      verify_descending_order(desc_by_score, :score, "score descending")

      # Test 4: Sort by player_name ascending
      asc_by_name = GameScore.query.order(:player_name).results
      verify_ascending_order(asc_by_name, :player_name, "player_name ascending")

      # Test 5: Sort by player_name descending
      desc_by_name = GameScore.query.order("-player_name").results
      verify_descending_order(desc_by_name, :player_name, "player_name descending")

      # Test 6: Sort by boolean field (cheat_mode)
      asc_by_cheat = GameScore.query.order(:cheat_mode).results
      # false should come before true in ascending order
      false_count = 0
      true_count = 0
      found_true = false

      asc_by_cheat.each do |result|
        if result[:cheat_mode] == false
          refute found_true, "All false values should come before true values in ascending order"
          false_count += 1
        else
          found_true = true
          true_count += 1
        end
      end

      assert false_count > 0, "Should have false values"
      assert true_count > 0, "Should have true values"
    end
  end

  # Parse Stack Ruby SDK: Multiple Sort Fields
  def test_multiple_sort_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create data with same player names but different scores
      test_data = [
        { score: 300, player_name: "Alice", cheat_mode: true },
        { score: 100, player_name: "Alice", cheat_mode: false },
        { score: 250, player_name: "Bob", cheat_mode: true },
        { score: 150, player_name: "Bob", cheat_mode: false },
        { score: 200, player_name: "Charlie", cheat_mode: false },
      ]

      test_data.each do |data|
        score = GameScore.new(data)
        assert score.save, "Should save test score"
      end

      # Test 1: Sort by player_name ASC, then score DESC
      multi_sort = GameScore.query.order(:player_name, "-score").results

      # Verify primary sort (player_name ascending)
      verify_ascending_order(multi_sort, :player_name, "primary sort: player_name")

      # Verify secondary sort within same player names
      current_player = nil
      player_scores = []

      multi_sort.each do |result|
        if current_player != result[:player_name]
          # Check previous player's scores were descending
          if player_scores.length > 1
            verify_descending_order_array(player_scores, "scores for #{current_player}")
          end

          current_player = result[:player_name]
          player_scores = [result[:score]]
        else
          player_scores << result[:score]
        end
      end

      # Check last player's scores
      if player_scores.length > 1
        verify_descending_order_array(player_scores, "scores for #{current_player}")
      end

      # Test 2: Sort by cheat_mode ASC, then player_name ASC, then score DESC
      triple_sort = GameScore.query.order(:cheat_mode, :player_name, "-score").results

      # Should have false cheat_mode values first, then true
      found_true_cheat = false
      triple_sort.each do |result|
        if result[:cheat_mode] == false
          refute found_true_cheat, "All false cheat_mode should come before true"
        else
          found_true_cheat = true
        end
      end
    end
  end

  # Parse Stack Ruby SDK: Sort Order with Constraints
  def test_sort_order_with_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test 1: Sort high scores in descending order
      high_scores = GameScore.query
        .where(score: { "$gte" => 200 })
        .order("-score")
        .results

      high_scores.each do |score|
        assert score[:score] >= 200, "Should only have high scores"
      end

      if high_scores.length > 1
        verify_descending_order(high_scores, :score, "high scores descending")
      end

      # Test 2: Sort cheaters by name
      cheater_scores = GameScore.query
        .where(cheat_mode: true)
        .order(:player_name)
        .results

      cheater_scores.each do |score|
        assert_equal true, score[:cheat_mode], "Should only have cheaters"
      end

      if cheater_scores.length > 1
        verify_ascending_order(cheater_scores, :player_name, "cheater names ascending")
      end

      # Test 3: Sort with containedIn and ordering
      specific_players = GameScore.query
        .where(player_name: { "$in" => ["Alice", "Bob", "Charlie"] })
        .order("-score")
        .results

      valid_names = ["Alice", "Bob", "Charlie"]
      specific_players.each do |score|
        assert valid_names.include?(score[:player_name]), "Should only have specific players"
      end

      if specific_players.length > 1
        verify_descending_order(specific_players, :score, "specific players by score desc")
      end
    end
  end

  # Parse Stack Ruby SDK: Sort Order Edge Cases
  def test_sort_order_edge_cases
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create data with edge cases
      test_data = [
        { score: 0, player_name: "", cheat_mode: false },        # Empty string
        { score: -100, player_name: "Negative", cheat_mode: false }, # Negative score
        { score: 999999, player_name: "A", cheat_mode: true },   # Very high score, single char name
        { score: 100, player_name: "Normal Player", cheat_mode: false },
      ]

      test_data.each do |data|
        score = GameScore.new(data)
        assert score.save, "Should save edge case score"
      end

      # Test 1: Sort by score including negative and zero
      all_scores = GameScore.query.order(:score).results
      verify_ascending_order(all_scores, :score, "all scores including negatives")

      # Test 2: Sort by name including empty string
      all_names = GameScore.query.order(:player_name).results
      verify_ascending_order(all_names, :player_name, "all names including empty")

      # Test 3: Limit with sort order
      top_3_scores = GameScore.query.order("-score").limit(3).results
      assert top_3_scores.length <= 3, "Should have at most 3 results"

      if top_3_scores.length > 1
        verify_descending_order(top_3_scores, :score, "top 3 scores")
      end

      # Test 4: Skip with sort order
      all_ordered = GameScore.query.order("-score").results
      if all_ordered.length > 2
        skip_2_scores = GameScore.query.order("-score").skip(2).results

        # Should be the same as all_ordered[2..-1]
        expected_scores = all_ordered[2..-1].map { |s| s[:score] }
        actual_scores = skip_2_scores.map { |s| s[:score] }

        assert_equal expected_scores, actual_scores, "Skip should return correct subset"
      end
    end
  end

  # Parse Stack Ruby SDK: Sort Order with Date Fields
  def test_sort_order_with_dates
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create posts at different times
      post1 = Post.new(title: "First Post", content: "Content 1")
      assert post1.save, "Should save first post"

      sleep(1) # Ensure different timestamps

      post2 = Post.new(title: "Second Post", content: "Content 2")
      assert post2.save, "Should save second post"

      sleep(1) # Ensure different timestamps

      post3 = Post.new(title: "Third Post", content: "Content 3")
      assert post3.save, "Should save third post"

      # Test 1: Sort by createdAt ascending (oldest first)
      oldest_first = Post.query.order(:created_at).results
      assert oldest_first.length >= 3, "Should have at least 3 posts"

      if oldest_first.length > 1
        previous_time = Time.parse(oldest_first.first.created_at.to_s)
        oldest_first[1..-1].each do |post|
          current_time = Time.parse(post.created_at.to_s)
          assert current_time >= previous_time, "Posts should be in chronological order"
          previous_time = current_time
        end
      end

      # Test 2: Sort by createdAt descending (newest first)
      newest_first = Post.query.order("-created_at").results

      if newest_first.length > 1
        previous_time = Time.parse(newest_first.first.created_at.to_s)
        newest_first[1..-1].each do |post|
          current_time = Time.parse(post.created_at.to_s)
          assert current_time <= previous_time, "Posts should be in reverse chronological order"
          previous_time = current_time
        end
      end

      # Test 3: Sort by updatedAt
      # Update the first post to change its updatedAt
      post1[:title] = "Updated First Post"
      assert post1.save, "Should update first post"

      newest_updated = Post.query.order("-updated_at").results

      if newest_updated.length > 1
        previous_time = Time.parse(newest_updated.first.updated_at.to_s)
        newest_updated[1..-1].each do |post|
          current_time = Time.parse(post.updated_at.to_s)
          assert current_time <= previous_time, "Posts should be ordered by update time"
          previous_time = current_time
        end
      end
    end
  end

  private

  def verify_ascending_order(results, field, description)
    return unless results.length > 1

    previous_value = results.first[field]
    results[1..-1].each do |result|
      current_value = result[field]
      assert current_value >= previous_value,
             "#{description}: #{previous_value} should be <= #{current_value}"
      previous_value = current_value
    end
  end

  def verify_descending_order(results, field, description)
    return unless results.length > 1

    previous_value = results.first[field]
    results[1..-1].each do |result|
      current_value = result[field]
      assert current_value <= previous_value,
             "#{description}: #{previous_value} should be >= #{current_value}"
      previous_value = current_value
    end
  end

  def verify_descending_order_array(values, description)
    return unless values.length > 1

    previous_value = values.first
    values[1..-1].each do |current_value|
      assert current_value <= previous_value,
             "#{description}: #{previous_value} should be >= #{current_value}"
      previous_value = current_value
    end
  end

  # Parse Stack Ruby SDK: Alternative Sort Order Syntax
  def test_sort_order_alternative_syntax
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test 1: Using order with asc/desc hash syntax
      asc_order_hash = GameScore.query.order(created_at: :asc).results
      if asc_order_hash.length > 1
        previous_time = Time.parse(asc_order_hash.first.created_at.to_s)
        asc_order_hash[1..-1].each do |score|
          current_time = Time.parse(score.created_at.to_s)
          assert current_time >= previous_time, "Should be in ascending chronological order"
          previous_time = current_time
        end
      end

      # Test 2: Using order with desc hash syntax
      desc_order_hash = GameScore.query.order(created_at: :desc).results
      if desc_order_hash.length > 1
        previous_time = Time.parse(desc_order_hash.first.created_at.to_s)
        desc_order_hash[1..-1].each do |score|
          current_time = Time.parse(score.created_at.to_s)
          assert current_time <= previous_time, "Should be in descending chronological order"
          previous_time = current_time
        end
      end

      # Test 3: Multiple fields with asc/desc hash syntax
      multi_order = GameScore.query.order(
        player_name: :asc,
        score: :desc,
      ).results

      verify_ascending_order(multi_order, :player_name, "player_name with hash syntax")

      # Test 4: Score ascending with hash syntax
      score_asc = GameScore.query.order(score: :asc).results
      verify_ascending_order(score_asc, :score, "score ascending with hash syntax")

      # Test 5: Score descending with hash syntax
      score_desc = GameScore.query.order(score: :desc).results
      verify_descending_order(score_desc, :score, "score descending with hash syntax")
    end
  end

  # Parse Stack Ruby SDK: Aggregation Function Tests
  def test_aggregation_functions
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create comprehensive test data for aggregation
      test_data = [
        { score: 100, player_name: "Alice", cheat_mode: false },
        { score: 250, player_name: "Alice", cheat_mode: true },
        { score: 150, player_name: "Bob", cheat_mode: false },
        { score: 300, player_name: "Bob", cheat_mode: true },
        { score: 75, player_name: "Charlie", cheat_mode: false },
        { score: 400, player_name: "Charlie", cheat_mode: true },
        { score: 200, player_name: "Diana", cheat_mode: false },
        { score: 50, player_name: "Eve", cheat_mode: false },
      ]

      test_data.each do |data|
        score = GameScore.new(data)
        assert score.save, "Should save aggregation test score"
      end

      # Test 1: Count aggregation
      total_count = GameScore.query.count
      assert_equal test_data.length, total_count, "Count should match test data length"

      # Count with constraints
      cheat_count = GameScore.query.where(cheat_mode: true).count
      fair_count = GameScore.query.where(cheat_mode: false).count
      assert_equal total_count, (cheat_count + fair_count), "Conditional counts should sum to total"

      # Test 2: Distinct aggregation
      distinct_players = GameScore.query.distinct(:player_name)
      expected_players = test_data.map { |d| d[:player_name] }.uniq.sort
      actual_players = distinct_players.sort
      assert_equal expected_players, actual_players, "Distinct players should match expected"

      # Distinct boolean values
      distinct_cheat_modes = GameScore.query.distinct(:cheat_mode)
      assert_equal [false, true].sort, distinct_cheat_modes.sort, "Should have both boolean values"

      # Test 3: Min/Max style queries (simulated with order + first/last)
      # Highest score
      max_score_result = GameScore.query.order("-score").first
      expected_max = test_data.map { |d| d[:score] }.max
      assert_equal expected_max, max_score_result[:score], "Should find maximum score"

      # Lowest score
      min_score_result = GameScore.query.order("score").first
      expected_min = test_data.map { |d| d[:score] }.min
      assert_equal expected_min, min_score_result[:score], "Should find minimum score"

      # Test 4: Group by simulation (using distinct + where queries)
      # Group by player and find their highest scores
      distinct_players.each do |player_name|
        player_scores = GameScore.query.where(player_name: player_name).order("-score").results
        highest_score = player_scores.first

        expected_scores = test_data.select { |d| d[:player_name] == player_name }
        expected_max = expected_scores.map { |d| d[:score] }.max

        assert_equal expected_max, highest_score[:score],
                     "Highest score for #{player_name} should be #{expected_max}"
      end

      # Test 5: Average simulation (manual calculation)
      all_scores = GameScore.query.limit(100).results
      scores_array = all_scores.map { |s| s[:score] }
      calculated_average = scores_array.sum.to_f / scores_array.length
      expected_average = test_data.map { |d| d[:score] }.sum.to_f / test_data.length

      assert_in_delta expected_average, calculated_average, 0.01,
                      "Calculated average should match expected"
    end
  end

  # Parse Stack Ruby SDK: Advanced Aggregation Patterns
  def test_advanced_aggregation_patterns
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create players first
      players = []
      ["Alice", "Bob", "Charlie"].each do |name|
        player = Player.new(
          name: name,
          email: "#{name.downcase}@example.com",
          level: rand(1..10),
          wins: rand(5..20),
          losses: rand(0..5),
        )
        assert player.save, "Should save player #{name}"
        players << player
      end

      # Create posts with relationships
      posts = []
      players.each_with_index do |player, index|
        2.times do |post_num|
          post = Post.new(
            title: "Post #{index}-#{post_num}",
            content: "Content by #{player[:name]}",
            author: player,
            tags: ["tag#{index}", "category#{post_num}"],
          )
          assert post.save, "Should save post"
          posts << post
        end
      end

      # Create comments with relationships
      posts.each do |post|
        rand(1..3).times do |comment_num|
          comment = Comment.new(
            text: "Comment #{comment_num} on #{post[:title]}",
            author: players.sample,
            post: post,
            likes: rand(0..10),
          )
          assert comment.save, "Should save comment"
        end
      end

      # Test 1: Count posts per author
      players.each do |player|
        post_count = Post.query.where(author: player).count
        expected_count = 2 # We created 2 posts per player
        assert_equal expected_count, post_count, "Should have correct post count for #{player[:name]}"
      end

      # Test 2: Count comments per post
      posts.each do |post|
        comment_count = Comment.query.where(post: post).count
        assert comment_count >= 1, "Each post should have at least 1 comment"
        assert comment_count <= 3, "Each post should have at most 3 comments"
      end

      # Test 3: Most liked comments (aggregation simulation)
      all_comments = Comment.query.order("-likes").results
      if all_comments.length > 0
        most_liked = all_comments.first
        all_comments.each do |comment|
          assert comment[:likes] <= most_liked[:likes],
                 "Most liked comment should have highest or equal likes"
        end
      end

      # Test 4: Posts with most comments (manual aggregation)
      post_comment_counts = {}
      posts.each do |post|
        count = Comment.query.where(post: post).count
        post_comment_counts[post.id] = count
      end

      max_comments = post_comment_counts.values.max
      most_commented_post_id = post_comment_counts.key(max_comments)
      most_commented_post = Post.get(most_commented_post_id)

      assert most_commented_post.present?, "Should find most commented post"
      actual_count = Comment.query.where(post: most_commented_post).count
      assert_equal max_comments, actual_count, "Comment count should match"

      # Test 5: Tag frequency analysis
      all_posts = Post.query.limit(50).results
      tag_frequency = {}

      all_posts.each do |post|
        tags = post[:tags] || []
        tags.each do |tag|
          tag_frequency[tag] = (tag_frequency[tag] || 0) + 1
        end
      end

      # Verify tag counts
      tag_frequency.each do |tag, count|
        actual_count = Post.query.where(tags: tag).count
        assert_equal count, actual_count, "Tag frequency should match query count for #{tag}"
      end
    end
  end

  # Parse Stack Ruby SDK: Performance-Oriented Aggregation Tests
  def test_performance_aggregation_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create larger dataset for performance testing
      start_time = Time.now

      10.times do |i|
        score = GameScore.new(
          score: rand(0..1000),
          player_name: "Player#{i % 10}", # 10 unique players
          cheat_mode: (i % 3 == 0), # Every 3rd is a cheat
        )
        assert score.save, "Should save performance test score #{i}"
      end

      creation_time = Time.now - start_time
      puts "Created 10 records in #{creation_time} seconds" if ENV["VERBOSE_TESTS"]

      # Test 1: Count query performance
      count_start = Time.now
      total_count = GameScore.query.count
      count_time = Time.now - count_start

      assert_equal 50, total_count, "Should have 50 total records"
      assert count_time < 1.0, "Count query should be fast (< 1 second)"

      # Test 2: Distinct query performance
      distinct_start = Time.now
      distinct_players = GameScore.query.distinct(:player_name)
      distinct_time = Time.now - distinct_start

      assert_equal 10, distinct_players.length, "Should have 10 distinct players"
      assert distinct_time < 1.0, "Distinct query should be fast (< 1 second)"

      # Test 3: Aggregation with constraints performance
      constraint_start = Time.now
      high_scores = GameScore.query.where(score: { "$gte" => 500 }).count
      all_scores = GameScore.query.where(score: { "$lt" => 500 }).count
      constraint_time = Time.now - constraint_start

      assert_equal 50, (high_scores + all_scores), "Constrained counts should sum to total"
      assert constraint_time < 1.0, "Constraint queries should be fast (< 1 second)"

      # Test 4: Top N query performance
      top_n_start = Time.now
      top_10_scores = GameScore.query.order("-score").limit(10).results
      top_n_time = Time.now - top_n_start

      assert_equal 10, top_10_scores.length, "Should get exactly 10 top scores"
      verify_descending_order(top_10_scores, :score, "top 10 scores")
      assert top_n_time < 1.0, "Top N query should be fast (< 1 second)"

      # Test 5: Complex aggregation simulation performance
      complex_start = Time.now

      # Find top 3 players by their best score
      player_best_scores = {}
      distinct_players.each do |player_name|
        best_score = GameScore.query
          .where(player_name: player_name)
          .order("-score")
          .first
        player_best_scores[player_name] = best_score[:score] if best_score
      end

      top_3_players = player_best_scores.sort_by { |name, score| -score }.first(3)
      complex_time = Time.now - complex_start

      assert_equal 3, top_3_players.length, "Should find top 3 players"
      assert complex_time < 2.0, "Complex aggregation should be reasonable (< 2 seconds)"

      # Verify top 3 are actually in descending order
      scores = top_3_players.map { |name, score| score }
      verify_descending_order_array(scores, "top 3 player scores")
    end
  end

  def test_count_queries
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test count of all GameScore objects
      query = GameScore.query
      count = query.count

      assert count > 0, "Should have at least some GameScore objects"

      # Test count with constraints
      query = GameScore.query.where(cheat_mode: true)
      cheat_count = query.count

      query = GameScore.query.where(cheat_mode: false)
      no_cheat_count = query.count

      total_query = GameScore.query
      total_count = total_query.count

      assert_equal total_count, (cheat_count + no_cheat_count),
                   "Cheat + no-cheat counts should equal total count"
    end
  end

  def test_distinct_queries
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test distinct player names
      query = GameScore.query
      distinct_names = query.distinct(:player_name)

      assert distinct_names.length > 0, "Should have distinct player names"

      # Verify no duplicates
      unique_names = distinct_names.uniq
      assert_equal distinct_names.length, unique_names.length,
                   "Distinct results should contain no duplicates"

      # Test distinct boolean values
      distinct_cheat_modes = query.distinct(:cheat_mode)

      # Should have at most 2 distinct boolean values (true/false)
      assert distinct_cheat_modes.length <= 2,
             "Should have at most 2 distinct boolean values"
    end
  end

  def test_first_and_get_queries
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Test first
      query = GameScore.query.order(:score)
      first_result = query.first

      assert first_result.present?, "Should return a first result"
      assert_equal "GameScore", first_result.parse_class, "Should be a GameScore object"

      # Test get by object ID using Parse Query
      object_id = first_result.id
      get_result = GameScore.query.get(object_id)

      assert get_result.present?, "Should get object by ID via query"
      assert_equal object_id, get_result.id, "Should return same object"
      assert_equal first_result[:score], get_result[:score], "Should have same score"
    end
  end

  # Parse Stack Ruby SDK: Direct Object Retrieval Methods
  def test_direct_object_retrieval_methods
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Get the first GameScore object to work with
      first_game_score = GameScore.first
      assert first_game_score.present?, "Should have at least one GameScore"

      object_id = first_game_score.id
      assert object_id.present?, "Should have an object ID"

      # Method 1: Class-level .get() method (Ruby SDK style)
      # This is the pattern you showed: Capture.get(c)
      retrieved_via_class = GameScore.get(object_id)

      assert retrieved_via_class.present?, "Should retrieve object via class .get() method"
      assert_equal object_id, retrieved_via_class.id, "Should have same object ID"
      assert_equal first_game_score[:score], retrieved_via_class[:score], "Should have same score"
      assert_equal first_game_score[:player_name], retrieved_via_class[:player_name], "Should have same player name"

      # Method 2: Query-based retrieval
      retrieved_via_query = GameScore.query.get(object_id)

      assert retrieved_via_query.present?, "Should retrieve object via query"
      assert_equal object_id, retrieved_via_query.id, "Should have same object ID"

      # Method 3: Query with where clause for objectId
      retrieved_via_where = GameScore.query.where(objectId: object_id).first

      assert retrieved_via_where.present?, "Should retrieve object via where objectId"
      assert_equal object_id, retrieved_via_where.id, "Should have same object ID"

      # Method 4: Query with constraint-style objectId
      retrieved_via_constraint = GameScore.query.where("objectId" => object_id).first

      assert retrieved_via_constraint.present?, "Should retrieve object via constraint"
      assert_equal object_id, retrieved_via_constraint.id, "Should have same object ID"

      # Verify all methods return equivalent objects
      assert_equal retrieved_via_class[:score], retrieved_via_query[:score], "Class vs Query should match"
      assert_equal retrieved_via_class[:score], retrieved_via_where[:score], "Class vs Where should match"
      assert_equal retrieved_via_class[:score], retrieved_via_constraint[:score], "Class vs Constraint should match"
    end
  end

  # Parse Stack Ruby SDK: Bulk Object Retrieval
  def test_bulk_object_retrieval
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Get multiple GameScore objects
      game_scores = GameScore.query.limit(3).results
      assert game_scores.length >= 2, "Should have at least 2 GameScore objects for testing"

      object_ids = game_scores.map(&:id)

      # Method 1: Query with containedIn for multiple IDs
      retrieved_multiple = GameScore.query.where(objectId: { "$in" => object_ids }).results

      assert retrieved_multiple.length == object_ids.length, "Should retrieve all requested objects"

      retrieved_ids = retrieved_multiple.map(&:id).sort
      assert_equal object_ids.sort, retrieved_ids, "Should retrieve exact same objects"

      # Method 2: Individual .get() calls (less efficient but sometimes necessary)
      individually_retrieved = object_ids.map { |id| GameScore.get(id) }

      assert individually_retrieved.all?(&:present?), "All individual retrievals should succeed"
      assert_equal object_ids.length, individually_retrieved.length, "Should retrieve all objects"

      # Verify both methods return equivalent data
      retrieved_multiple.each_with_index do |bulk_obj, index|
        individual_obj = individually_retrieved[index]
        assert_equal bulk_obj.id, individual_obj.id, "Objects should have same ID"
        assert_equal bulk_obj[:score], individual_obj[:score], "Objects should have same score"
      end
    end
  end

  # Parse Stack Ruby SDK: Object Retrieval Error Handling
  def test_object_retrieval_error_handling
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      # Test retrieving non-existent object
      fake_id = "nonexistent123"

      # Class-level .get() with non-existent ID
      assert_raises(Parse::Error) do
        GameScore.get(fake_id)
      end

      # Query-based retrieval with non-existent ID (should return nil, not raise)
      result = GameScore.query.where(objectId: fake_id).first
      assert_nil result, "Query for non-existent object should return nil"

      # Query.get() with non-existent ID should also raise error
      assert_raises(Parse::Error) do
        GameScore.query.get(fake_id)
      end
    end
  end

  # Parse Stack Ruby SDK: First vs Get vs Find patterns
  def test_ruby_sdk_retrieval_patterns
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      setup_test_data

      # Pattern 1: .first - gets first result from query
      first_by_score = GameScore.query.order(:score).first
      assert first_by_score.present?, "Should get first object by score"

      # Pattern 2: .first with conditions
      first_alice = GameScore.query.where(player_name: "Alice").first
      if first_alice.present?
        assert_equal "Alice", first_alice[:player_name], "Should be Alice's score"
      end

      # Pattern 3: Class-level .first (gets first from table)
      class_first = GameScore.first
      assert class_first.present?, "Should get first object from class"

      # Pattern 4: Class-level .all (gets all objects)
      all_scores = GameScore.all(limit: 50)
      assert all_scores.length > 0, "Should get all GameScore objects"
      assert all_scores.is_a?(Array), "Should return array of objects"

      # Pattern 5: Class-level .count
      total_count = GameScore.count
      assert total_count > 0, "Should have positive count"
      assert_equal all_scores.length, total_count, "Count should match all.length"

      # Pattern 6: Query chaining for specific retrieval
      high_score_alice = GameScore.query
        .where(player_name: "Alice")
        .where(score: { "$gte" => 100 })
        .order("-score")
        .first

      if high_score_alice.present?
        assert_equal "Alice", high_score_alice[:player_name], "Should be Alice"
        assert high_score_alice[:score] >= 100, "Should have high score"
      end
    end
  end

  # Parse Server Examples: Relational Queries
  def test_relational_queries_with_pointers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create test data based on Parse Server examples
      player1 = Player.new(name: "John Doe", email: "john@example.com", level: 10, wins: 15, losses: 3, hometown: "San Francisco")
      player2 = Player.new(name: "Jane Smith", email: "jane@example.com", level: 8, wins: 12, losses: 5, hometown: "New York")
      assert player1.save, "Should save player1"
      assert player2.save, "Should save player2"

      # Create posts with author relationships
      post1 = Post.new(title: "My First Post", content: "Hello world!", author: player1, tags: ["intro", "hello"])
      post2 = Post.new(title: "Game Strategy", content: "Tips for winning", author: player2, tags: ["strategy", "tips"])
      assert post1.save, "Should save post1"
      assert post2.save, "Should save post2"

      # Create comments with relationships to both posts and authors
      comment1 = Comment.new(text: "Great post!", author: player2, post: post1, likes: 5)
      comment2 = Comment.new(text: "Thanks for the tips", author: player1, post: post2, likes: 3)
      assert comment1.save, "Should save comment1"
      assert comment2.save, "Should save comment2"

      # Query posts by specific author (Parse Server Example: Relational Queries)
      posts_by_john = Post.query.where(author: player1).results
      assert_equal 1, posts_by_john.length, "Should find 1 post by John"
      assert_equal "My First Post", posts_by_john.first[:title], "Should be John's post"

      # Query comments on a specific post
      comments_on_post1 = Comment.query.where(post: post1).results
      assert_equal 1, comments_on_post1.length, "Should find 1 comment on post1"
      assert_equal "Great post!", comments_on_post1.first[:text], "Should be the correct comment"

      # Query comments by author
      comments_by_jane = Comment.query.where(author: player2).results
      assert_equal 1, comments_by_jane.length, "Should find 1 comment by Jane"
    end
  end

  # Parse Server Examples: Array Queries
  def test_array_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create posts with tag arrays (Parse Server Example: Array Queries)
      post1 = Post.new(title: "Tech News", content: "Latest updates", tags: ["tech", "news", "update"])
      post2 = Post.new(title: "Game Review", content: "Amazing game", tags: ["gaming", "review", "entertainment"])
      post3 = Post.new(title: "Tech Gaming", content: "Gaming tech", tags: ["tech", "gaming", "hardware"])

      assert post1.save && post2.save && post3.save, "Should save all posts"

      # Query posts that contain a specific tag
      tech_posts = Post.query.where(tags: "tech").results
      assert tech_posts.length >= 2, "Should find at least 2 tech posts"

      tech_posts.each do |post|
        assert post[:tags].include?("tech"), "Post should have 'tech' tag"
      end

      # Query posts that contain all specified tags (containsAll equivalent)
      tech_gaming_posts = Post.query.where(tags: { "$all" => ["tech", "gaming"] }).results
      assert_equal 1, tech_gaming_posts.length, "Should find 1 post with both tech and gaming tags"
      assert_equal "Tech Gaming", tech_gaming_posts.first[:title], "Should be the Tech Gaming post"

      # Query posts with any of the specified tags
      entertainment_posts = Post.query.where(tags: { "$in" => ["entertainment", "news"] }).results
      assert entertainment_posts.length >= 2, "Should find posts with entertainment or news tags"
    end
  end

  # Parse Server Examples: Geo Queries
  def test_geo_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create players with location data (Parse Server Example: Geo Queries)
      sf_location = Parse::GeoPoint.new(latitude: 37.7749, longitude: -122.4194)
      ny_location = Parse::GeoPoint.new(latitude: 40.7128, longitude: -74.0060)
      la_location = Parse::GeoPoint.new(latitude: 34.0522, longitude: -118.2437)

      player1 = Player.new(name: "SF Player", hometown: "San Francisco")
      player2 = Player.new(name: "NY Player", hometown: "New York")
      player3 = Player.new(name: "LA Player", hometown: "Los Angeles")

      assert player1.save && player2.save && player3.save, "Should save all players"

      # Create game scores with location data
      score1 = GameScore.new(score: 100, player_name: "SF Player", location: sf_location)
      score2 = GameScore.new(score: 200, player_name: "NY Player", location: ny_location)
      score3 = GameScore.new(score: 150, player_name: "LA Player", location: la_location)

      assert score1.save && score2.save && score3.save, "Should save all scores"

      # Query scores near a specific location (Parse Server Example: Geo Queries)
      # Find scores within ~500 miles of San Francisco
      nearby_scores = GameScore.query.where(
        location: {
          "$nearSphere" => sf_location,
          "$maxDistanceInMiles" => 500,
        },
      ).results

      assert nearby_scores.length >= 1, "Should find at least SF score"

      # Verify SF score is included
      sf_scores = nearby_scores.select { |score| score[:player_name] == "SF Player" }
      assert sf_scores.length == 1, "Should find SF player's score"
    end
  end

  # Parse Server Examples: Complex Queries
  def test_complex_parse_server_examples
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create comprehensive test data
      players = []
      5.times do |i|
        player = Player.new(
          name: "Player#{i + 1}",
          email: "player#{i + 1}@example.com",
          level: (i + 1) * 2,
          wins: (i + 1) * 3,
          losses: i,
          hometown: ["SF", "NY", "LA", "Chicago", "Boston"][i],
        )
        assert player.save, "Should save player #{i + 1}"
        players << player
      end

      # Create team with captain and players array
      team = Team.new(
        name: "Dream Team",
        city: "San Francisco",
        wins: 10,
        losses: 2,
        captain: players.first,
        players: players.map(&:id),
      )
      assert team.save, "Should save team"

      # Parse Server Example: Query players with high level AND many wins
      elite_players = Player.query.where(
        level: { "$gte" => 6 },
        wins: { "$gte" => 9 },
      ).results

      elite_players.each do |player|
        assert player[:level] >= 6, "Player level should be >= 6"
        assert player[:wins] >= 9, "Player wins should be >= 9"
      end

      # Parse Server Example: Query teams by captain
      teams_with_captain = Team.query.where(captain: players.first).results
      assert_equal 1, teams_with_captain.length, "Should find 1 team with this captain"
      assert_equal "Dream Team", teams_with_captain.first[:name], "Should be Dream Team"

      # Parse Server Example: Complex OR query
      # Find players from SF OR NY with high wins
      location_or_wins = Player.query.where(
        "$or" => [
          { hometown: { "$in" => ["SF", "NY"] } },
          { wins: { "$gte" => 12 } },
        ],
      ).results

      location_or_wins.each do |player|
        has_location = ["SF", "NY"].include?(player[:hometown])
        has_high_wins = player[:wins] >= 12
        assert (has_location || has_high_wins), "Player should match location OR wins criteria"
      end
    end
  end

  # Parse Server Examples: Aggregation-style Queries
  def test_aggregation_style_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create varied game score data for aggregation tests
      scores_data = [
        { score: 100, player_name: "Alice", cheat_mode: false },
        { score: 250, player_name: "Alice", cheat_mode: true },
        { score: 150, player_name: "Bob", cheat_mode: false },
        { score: 300, player_name: "Bob", cheat_mode: true },
        { score: 75, player_name: "Charlie", cheat_mode: false },
        { score: 400, player_name: "Charlie", cheat_mode: true },
      ]

      scores_data.each do |data|
        score = GameScore.new(data)
        assert score.save, "Should save score"
      end

      # Find highest score per player (simulating aggregation)
      players = GameScore.query.distinct(:player_name)

      players.each do |player_name|
        player_scores = GameScore.query
          .where(player_name: player_name)
          .order("-score")
          .results

        assert player_scores.length > 0, "Should find scores for #{player_name}"

        highest_score = player_scores.first
        player_scores[1..-1].each do |score|
          assert score[:score] <= highest_score[:score],
                 "Scores should be in descending order"
        end
      end

      # Count scores by cheat mode (simulating group by)
      cheat_count = GameScore.query.where(cheat_mode: true).count
      fair_count = GameScore.query.where(cheat_mode: false).count
      total_count = GameScore.query.count

      assert_equal total_count, (cheat_count + fair_count),
                   "Cheat + fair counts should equal total"
      assert cheat_count > 0, "Should have some cheat mode scores"
      assert fair_count > 0, "Should have some fair mode scores"

      # Find average-ish scores by getting middle values
      all_scores = GameScore.query.order(:score).results
      if all_scores.length >= 3
        middle_index = all_scores.length / 2
        median_score = all_scores[middle_index]

        assert median_score.present?, "Should find median score"
        assert median_score[:score].is_a?(Integer), "Median score should be an integer"
      end
    end
  end

  # Parse Server Examples: Date and Time Queries
  def test_date_and_time_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create posts with different timestamps
      now = Time.now
      yesterday = now - 24 * 60 * 60
      last_week = now - 7 * 24 * 60 * 60

      # Note: Parse Server automatically manages createdAt/updatedAt
      post1 = Post.new(title: "Recent Post", content: "New content")
      post2 = Post.new(title: "Old Post", content: "Old content")

      assert post1.save && post2.save, "Should save posts"

      # Query recent posts (Parse Server Example: Date Queries)
      # Find posts created in the last hour
      recent_cutoff = now - 60 * 60 # 1 hour ago

      recent_posts = Post.query.where(
        created_at: { "$gte" => recent_cutoff },
      ).results

      recent_posts.each do |post|
        created_time = Time.parse(post.created_at.to_s)
        assert created_time >= recent_cutoff, "Post should be recent"
      end

      # Find all posts (should include both)
      all_posts = Post.query.limit(50).results
      assert all_posts.length >= 2, "Should find at least 2 posts"
    end
  end

  # Test mixed where conditions with dates, strings, and numbers
  def test_mixed_where_conditions_with_dates
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      reset_database!

      # Create test data with various attributes
      now = Time.now
      hour_ago = now - 3600
      day_ago = now - 86400
      week_ago = now - 604800

      # Create players with different attributes and join dates
      players = []
      players << Player.new(name: "Alice", level: 10, wins: 5, hometown: "New York").tap { |p| p.save }
      players << Player.new(name: "Bob", level: 20, wins: 15, hometown: "Boston").tap { |p| p.save }
      players << Player.new(name: "Charlie", level: 30, wins: 25, hometown: "Chicago").tap { |p| p.save }
      players << Player.new(name: "Diana", level: 15, wins: 8, hometown: "Denver").tap { |p| p.save }
      players << Player.new(name: "Eve", level: 25, wins: 20, hometown: "Seattle").tap { |p| p.save }

      # Create game scores with different timestamps and scores
      scores = []
      scores << GameScore.new(player_name: "Alice", score: 100, cheat_mode: false).tap { |s| s.save }
      sleep 0.1 # Small delay to ensure different timestamps
      scores << GameScore.new(player_name: "Bob", score: 200, cheat_mode: false).tap { |s| s.save }
      sleep 0.1
      scores << GameScore.new(player_name: "Charlie", score: 300, cheat_mode: true).tap { |s| s.save }
      sleep 0.1
      scores << GameScore.new(player_name: "Diana", score: 150, cheat_mode: false).tap { |s| s.save }
      sleep 0.1
      scores << GameScore.new(player_name: "Eve", score: 250, cheat_mode: true).tap { |s| s.save }

      # Complex query with mixed conditions including dates
      recent_cutoff = now - 7200 # 2 hours ago

      # Find high-scoring games from recent time period where no cheating occurred
      results = GameScore.query
        .where(
          created_at: { "$gte" => recent_cutoff },
          score: { "$gte" => 150 },
          cheat_mode: false,
        )
        .order(:score.desc)
        .results

      assert results.length >= 2, "Should find at least 2 matching scores"
      results.each do |score|
        assert score.score >= 150, "Score should be at least 150"
        assert_equal false, score.cheat_mode, "Should not be cheating"
        created_time = Time.parse(score.created_at.to_s)
        assert created_time >= recent_cutoff, "Should be recent"
      end

      # Another mixed query: Players with high wins and specific hometown pattern
      high_level_players = Player.query
        .where(
          level: { "$gte" => 20 },
          wins: { "$lte" => 25 },
          hometown: { "$regex" => "^[BC]" }, # Starts with B or C
        )
        .results

      assert high_level_players.length >= 2, "Should find matching players"
      high_level_players.each do |player|
        assert player.level >= 20, "Level should be at least 20"
        assert player.wins <= 25, "Wins should be at most 25"
        assert player.hometown.match?(/^[BC]/), "Hometown should start with B or C"
      end

      # Test with date ranges and multiple conditions
      all_recent_scores = GameScore.query
        .where(
          created_at: { "$gte" => recent_cutoff, "$lte" => now },
          player_name: { "$in" => ["Alice", "Bob", "Charlie"] },
        )
        .results

      assert all_recent_scores.length >= 3, "Should find scores for Alice, Bob, and Charlie"
      player_names = all_recent_scores.map(&:player_name).uniq
      assert player_names.include?("Alice"), "Should include Alice"
      assert player_names.include?("Bob"), "Should include Bob"
      assert player_names.include?("Charlie"), "Should include Charlie"
    end
  end
end
