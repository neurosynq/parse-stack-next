require_relative '../../test_helper_integration'

# Test classes for distinct pointer integration tests
class Team < Parse::Object
  parse_class "Team"
  property :name, :string
end

class Asset < Parse::Object
  parse_class "Asset" 
  property :name, :string
  property :category, :string
  property :project, :pointer, class_name: 'Team'
end

class DistinctPointerIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_distinct_with_pointer_field_returns_parse_pointers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "distinct pointer field test") do
        # Create test data with pointer relationships
        
        # Create some Team objects
        team1 = Team.new(name: "Team Alpha")
        team2 = Team.new(name: "Team Beta")
        team3 = Team.new(name: "Team Gamma")
        
        assert team1.save, "Should save team1"
        assert team2.save, "Should save team2" 
        assert team3.save, "Should save team3"
        
        # Create Asset objects that point to teams
        asset1 = Asset.new(
          name: "Asset 1",
          project: team1.pointer
        )
        asset2 = Asset.new(
          name: "Asset 2", 
          project: team2.pointer
        )
        asset3 = Asset.new(
          name: "Asset 3",
          project: team1.pointer  # Same team as asset1
        )
        asset4 = Asset.new(
          name: "Asset 4",
          project: team3.pointer
        )
        
        assert asset1.save, "Should save asset1"
        assert asset2.save, "Should save asset2"
        assert asset3.save, "Should save asset3"
        assert asset4.save, "Should save asset4"
        
        # Test distinct on pointer field
        query = Parse::Query.new("Asset")
        result = query.distinct_pointers(:project)
        
        # Should return Parse::Pointer objects for distinct teams
        assert_equal 3, result.size, "Should return 3 distinct teams"
        
        result.each do |pointer|
          assert_kind_of Parse::Pointer, pointer, "Each result should be a Parse::Pointer"
          assert_equal "Team", pointer.parse_class, "Pointer should be for Team class"
          assert pointer.id.present?, "Pointer should have an ID"
        end
        
        # Verify the distinct team IDs match our created teams
        result_ids = result.map(&:id).sort
        expected_ids = [team1.id, team2.id, team3.id].sort
        assert_equal expected_ids, result_ids, "Should return pointers to all three teams"
        
        puts "✅ Distinct pointer field returns Parse::Pointer objects correctly"
      end
    end
  end

  def test_distinct_with_non_pointer_field_returns_values
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "distinct non-pointer field test") do
        # Create test data with string categories
        
        asset1 = Asset.new(
          name: "Video Asset",
          category: "video"
        )
        asset2 = Asset.new(
          name: "Image Asset",
          category: "image"
        )
        asset3 = Asset.new(
          name: "Audio Asset", 
          category: "audio"
        )
        asset4 = Asset.new(
          name: "Another Video",
          category: "video"  # Duplicate category
        )
        
        assert asset1.save, "Should save asset1"
        assert asset2.save, "Should save asset2"
        assert asset3.save, "Should save asset3"
        assert asset4.save, "Should save asset4"
        
        # Test distinct on non-pointer field
        query = Parse::Query.new("Asset")
        result = query.distinct(:category)
        
        # Should return string values
        assert_equal 3, result.size, "Should return 3 distinct categories"
        
        result.each do |category|
          assert_kind_of String, category, "Each result should be a String"
        end
        
        # Verify the distinct categories
        expected_categories = ["video", "image", "audio"]
        assert_equal expected_categories.sort, result.sort, "Should return all three categories"
        
        puts "✅ Distinct non-pointer field returns string values correctly"
      end
    end
  end

  def test_distinct_with_return_pointers_true_option
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "distinct with return_pointers option test") do
        # Create test data
        team1 = Team.new(name: "Test Team 1")
        team2 = Team.new(name: "Test Team 2")
        
        assert team1.save, "Should save team1"
        assert team2.save, "Should save team2"
        
        asset1 = Asset.new(
          name: "Asset One",
          project: team1.pointer
        )
        asset2 = Asset.new(
          name: "Asset Two",
          project: team2.pointer
        )
        
        assert asset1.save, "Should save asset1"
        assert asset2.save, "Should save asset2"
        
        # Test distinct with explicit return_pointers: true
        query = Parse::Query.new("Asset")
        result = query.distinct(:project, return_pointers: true)
        
        # Should return Parse::Pointer objects
        assert_equal 2, result.size, "Should return 2 distinct teams"
        
        result.each do |pointer|
          assert_kind_of Parse::Pointer, pointer, "Each result should be a Parse::Pointer"
          assert_equal "Team", pointer.parse_class, "Pointer should be for Team class"
        end
        
        result_ids = result.map(&:id).sort
        expected_ids = [team1.id, team2.id].sort
        assert_equal expected_ids, result_ids, "Should return pointers to both teams"
        
        puts "✅ Distinct with return_pointers: true works correctly"
      end
    end
  end

  def test_distinct_with_mixed_pointer_formats
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "distinct with mixed pointer formats test") do
        # Create teams
        team1 = Team.new(name: "Mixed Format Team 1")
        team2 = Team.new(name: "Mixed Format Team 2")
        
        assert team1.save, "Should save team1"
        assert team2.save, "Should save team2"
        
        # Create assets with different ways of setting pointer relationships
        asset1 = Asset.new(
          name: "Asset with pointer object",
          project: team1.pointer
        )
        
        asset2 = Asset.new(
          name: "Asset with hash pointer",
          project: {
            "__type" => "Pointer",
            "className" => "Team", 
            "objectId" => team2.id
          }
        )
        
        assert asset1.save, "Should save asset1"
        assert asset2.save, "Should save asset2"
        
        # Test distinct - should handle both formats
        query = Parse::Query.new("Asset")
        result = query.distinct_pointers(:project)
        
        assert_equal 2, result.size, "Should return 2 distinct teams"
        
        result.each do |pointer|
          assert_kind_of Parse::Pointer, pointer, "Each result should be a Parse::Pointer"
          assert_equal "Team", pointer.parse_class, "Pointer should be for Team class"
        end
        
        result_ids = result.map(&:id).sort
        expected_ids = [team1.id, team2.id].sort
        assert_equal expected_ids, result_ids, "Should return pointers to both teams"
        
        puts "✅ Distinct handles mixed pointer formats correctly"
      end
    end
  end

  def test_distinct_with_null_pointer_values
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "distinct with null pointer values test") do
        # Create test data with some null pointer values
        team1 = Team.new(name: "Only Team")
        assert team1.save, "Should save team1"
        
        # Asset with pointer
        asset1 = Asset.new(
          name: "Asset with team",
          project: team1.pointer
        )
        
        # Asset without pointer (null/undefined project)
        asset2 = Asset.new(
          name: "Asset without team"
          # project field intentionally omitted
        )
        
        assert asset1.save, "Should save asset1"
        assert asset2.save, "Should save asset2"
        
        # Test distinct - should handle null values appropriately
        query = Parse::Query.new("Asset")
        result = query.distinct_pointers(:project)
        
        # Should return at least the team pointer, may or may not include null
        assert result.size >= 1, "Should return at least 1 result"
        assert result.size <= 2, "Should return at most 2 results (team + null)"
        
        # Find the non-null result
        non_null_result = result.find { |r| r.is_a?(Parse::Pointer) }
        assert non_null_result, "Should have at least one non-null pointer result"
        assert_equal "Team", non_null_result.parse_class, "Non-null result should be Team pointer"
        assert_equal team1.id, non_null_result.id, "Should point to the created team"
        
        puts "✅ Distinct handles null pointer values correctly"
      end
    end
  end

  def test_distinct_performance_with_large_dataset
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    skip "Performance test - enable manually" unless ENV['RUN_PERFORMANCE_TESTS'] == 'true'

    with_parse_server do
      with_timeout(30, "distinct performance test") do
        # Create a moderate number of teams and assets for performance testing
        num_teams = 10
        num_assets = 50
        
        teams = []
        (1..num_teams).each do |i|
          team = Team.new(name: "Performance Team #{i}")
          assert team.save, "Should save team #{i}"
          teams << team
        end
        
        # Create assets distributed across teams
        (1..num_assets).each do |i|
          team = teams[i % num_teams]  # Distribute across teams
          asset = Asset.new(
            name: "Performance Asset #{i}",
            project: team.pointer
          )
          assert asset.save, "Should save asset #{i}"
        end
        
        # Test distinct performance
        start_time = Time.now
        
        query = Parse::Query.new("Asset")
        result = query.distinct_pointers(:project)
        
        end_time = Time.now
        duration = end_time - start_time
        
        assert_equal num_teams, result.size, "Should return #{num_teams} distinct teams"
        assert duration < 5.0, "Distinct query should complete within 5 seconds (took #{duration}s)"
        
        result.each do |pointer|
          assert_kind_of Parse::Pointer, pointer, "Each result should be a Parse::Pointer"
          assert_equal "Team", pointer.parse_class, "Pointer should be for Team class"
        end
        
        puts "✅ Distinct performance test completed in #{duration}s"
      end
    end
  end

  def test_distinct_default_behavior_returns_ids
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "distinct default behavior test") do
        # Create teams
        team1 = Team.new(name: "Default Test Team 1")
        team2 = Team.new(name: "Default Test Team 2")
        
        assert team1.save, "Should save team1"
        assert team2.save, "Should save team2"
        
        # Create assets
        asset1 = Asset.new(name: "Asset 1", project: team1.pointer)
        asset2 = Asset.new(name: "Asset 2", project: team2.pointer)
        
        assert asset1.save, "Should save asset1"
        assert asset2.save, "Should save asset2"
        
        # Test distinct without return_pointers - should return IDs
        query = Parse::Query.new("Asset")
        result = query.distinct(:project)
        
        assert_equal 2, result.size, "Should return 2 distinct team IDs"
        
        result.each do |id|
          assert_kind_of String, id, "Each result should be a String ID"
          assert id.present?, "ID should not be empty"
        end
        
        # Verify the IDs match our created teams
        result_ids = result.sort
        expected_ids = [team1.id, team2.id].sort
        assert_equal expected_ids, result_ids, "Should return IDs of both teams"
        
        puts "✅ Distinct default behavior returns IDs correctly"
      end
    end
  end
end