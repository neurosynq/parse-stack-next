# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require "timeout"

class AgentIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Timeout helper method
  def with_timeout(seconds, description)
    Timeout.timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{description} timed out after #{seconds} seconds"
  end

  # Test models for agent testing
  class Song < Parse::Object
    parse_class "Song"
    property :title, :string
    property :artist, :string
    property :plays, :integer
    property :duration, :integer
    property :genre, :string
    property :release_date, :date
    belongs_to :album
  end

  class Album < Parse::Object
    parse_class "Album"
    property :name, :string
    property :year, :integer
    has_many :songs
  end

  def setup_test_data
    # Create albums
    @album1 = Album.new(name: "Greatest Hits", year: 2020)
    assert @album1.save, "Should save album1"

    @album2 = Album.new(name: "New Releases", year: 2024)
    assert @album2.save, "Should save album2"

    # Create songs with various data for testing queries
    songs_data = [
      { title: "Rock Anthem", artist: "The Rockers", plays: 5000, duration: 240, genre: "Rock", album: @album1 },
      { title: "Pop Hit", artist: "Pop Star", plays: 10000, duration: 180, genre: "Pop", album: @album1 },
      { title: "Jazz Night", artist: "Jazz Band", plays: 2000, duration: 300, genre: "Jazz", album: @album2 },
      { title: "Electronic Beat", artist: "DJ Mix", plays: 8000, duration: 210, genre: "Electronic", album: @album2 },
      { title: "Country Road", artist: "Country Singer", plays: 3500, duration: 200, genre: "Country", album: @album1 },
      { title: "Classical Suite", artist: "Orchestra", plays: 1500, duration: 600, genre: "Classical", album: @album2 },
      { title: "Hip Hop Flow", artist: "MC Rapper", plays: 12000, duration: 195, genre: "Hip Hop", album: @album1 },
      { title: "Blues Morning", artist: "Blues Man", plays: 2500, duration: 270, genre: "Blues", album: @album2 },
    ]

    @songs = []
    songs_data.each do |data|
      song = Song.new(data)
      assert song.save, "Should save song: #{data[:title]}"
      @songs << song
    end
  end

  # ============================================================
  # Schema Tests
  # ============================================================

  def test_get_all_schemas
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(3, "get all schemas") do
        result = agent.execute(:get_all_schemas)

        assert result[:success], "Should succeed: #{result[:error]}"
        assert result[:data][:total] >= 2, "Should have at least Song and Album classes"

        # New compact format separates built_in and custom classes
        custom_names = result[:data][:custom].map { |c| c[:name] }
        assert_includes custom_names, "Song", "Should include Song class"
        assert_includes custom_names, "Album", "Should include Album class"
      end
    end
  end

  def test_get_schema_for_specific_class
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(3, "get Song schema") do
        result = agent.execute(:get_schema, class_name: "Song")

        assert result[:success], "Should succeed: #{result[:error]}"
        assert_equal "Song", result[:data][:class_name]
        assert_equal "custom", result[:data][:type]

        field_names = result[:data][:fields].map { |f| f[:name] }
        assert_includes field_names, "title"
        assert_includes field_names, "artist"
        assert_includes field_names, "plays"
      end
    end
  end

  def test_get_schema_for_nonexistent_class
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      agent = Parse::Agent.new

      with_timeout(3, "get nonexistent schema") do
        result = agent.execute(:get_schema, class_name: "NonExistentClass")

        refute result[:success], "Should fail for nonexistent class"
        assert_match(/failed/i, result[:error])
      end
    end
  end

  # ============================================================
  # Query Tests
  # ============================================================

  def test_query_class_basic
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(3, "basic query") do
        result = agent.execute(:query_class, class_name: "Song")

        assert result[:success], "Should succeed: #{result[:error]}"
        assert_equal "Song", result[:data][:class_name]
        assert_equal 8, result[:data][:result_count]
        assert_equal 8, result[:data][:results].size
      end
    end
  end

  def test_query_class_with_where_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(3, "query with where") do
        result = agent.execute(:query_class,
                               class_name: "Song",
                               where: { "plays" => { "$gte" => 5000 } })

        assert result[:success], "Should succeed: #{result[:error]}"
        assert_equal 4, result[:data][:result_count], "Should have 4 songs with plays >= 5000"

        # Verify all results have plays >= 5000
        result[:data][:results].each do |song|
          assert song["plays"] >= 5000, "Each song should have plays >= 5000"
        end
      end
    end
  end

  def test_query_class_with_multiple_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(3, "query with multiple constraints") do
        result = agent.execute(:query_class,
                               class_name: "Song",
                               where: {
                                 "plays" => { "$gte" => 2000 },
                                 "genre" => "Rock",
                               })

        assert result[:success], "Should succeed: #{result[:error]}"
        assert_equal 1, result[:data][:result_count]
        assert_equal "Rock Anthem", result[:data][:results].first["title"]
      end
    end
  end

  def test_query_class_with_limit_and_skip
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(3, "query with pagination") do
        # First page
        result1 = agent.execute(:query_class,
                                class_name: "Song",
                                limit: 3,
                                skip: 0,
                                order: "title")

        assert result1[:success], "Should succeed: #{result1[:error]}"
        assert_equal 3, result1[:data][:results].size
        assert result1[:data][:pagination][:has_more], "Should have more results"

        # Second page
        result2 = agent.execute(:query_class,
                                class_name: "Song",
                                limit: 3,
                                skip: 3,
                                order: "title")

        assert result2[:success], "Should succeed: #{result2[:error]}"
        assert_equal 3, result2[:data][:results].size

        # Ensure no overlap
        titles1 = result1[:data][:results].map { |s| s["title"] }
        titles2 = result2[:data][:results].map { |s| s["title"] }
        assert_empty(titles1 & titles2, "Pages should not overlap")
      end
    end
  end

  def test_query_class_with_order
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(3, "query with descending order") do
        result = agent.execute(:query_class,
                               class_name: "Song",
                               order: "-plays",
                               limit: 3)

        assert result[:success], "Should succeed: #{result[:error]}"
        plays = result[:data][:results].map { |s| s["plays"] }
        assert_equal plays.sort.reverse, plays, "Should be sorted by plays descending"
        assert_equal 12000, plays.first, "Highest plays should be first"
      end
    end
  end

  def test_query_class_with_keys_selection
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(3, "query with field selection") do
        result = agent.execute(:query_class,
                               class_name: "Song",
                               keys: ["title", "artist"],
                               limit: 1)

        assert result[:success], "Should succeed: #{result[:error]}"
        song = result[:data][:results].first
        assert song["title"], "Should have title"
        assert song["artist"], "Should have artist"
        # objectId, createdAt, updatedAt are always included
        refute song.key?("plays"), "Should not have plays field"
        refute song.key?("duration"), "Should not have duration field"
      end
    end
  end

  # ============================================================
  # Count Tests
  # ============================================================

  def test_count_objects_all
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(3, "count all objects") do
        result = agent.execute(:count_objects, class_name: "Song")

        assert result[:success], "Should succeed: #{result[:error]}"
        assert_equal 8, result[:data][:count]
        assert_equal "Song", result[:data][:class_name]
      end
    end
  end

  def test_count_objects_with_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(3, "count with constraint") do
        result = agent.execute(:count_objects,
                               class_name: "Song",
                               where: { "genre" => "Rock" })

        assert result[:success], "Should succeed: #{result[:error]}"
        assert_equal 1, result[:data][:count]
      end
    end
  end

  # ============================================================
  # Get Object Tests
  # ============================================================

  def test_get_object_by_id
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new
      target_song = @songs.first

      with_timeout(3, "get object by id") do
        result = agent.execute(:get_object,
                               class_name: "Song",
                               object_id: target_song.id)

        assert result[:success], "Should succeed: #{result[:error]}"
        assert_equal target_song.id, result[:data][:object_id]
        assert_equal "Song", result[:data][:class_name]
        assert_equal target_song.title, result[:data][:object]["title"]
      end
    end
  end

  def test_get_object_not_found
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      agent = Parse::Agent.new

      with_timeout(3, "get nonexistent object") do
        result = agent.execute(:get_object,
                               class_name: "Song",
                               object_id: "nonexistent123")

        refute result[:success], "Should fail for nonexistent object"
        assert_match(/not found/i, result[:error])
      end
    end
  end

  # ============================================================
  # Sample Objects Tests
  # ============================================================

  def test_get_sample_objects
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(3, "get sample objects") do
        result = agent.execute(:get_sample_objects, class_name: "Song", limit: 3)

        assert result[:success], "Should succeed: #{result[:error]}"
        assert_equal "Song", result[:data][:class_name]
        assert_equal 3, result[:data][:sample_count]
        assert_equal 3, result[:data][:samples].size
        assert_match(/recently created/, result[:data][:note])
      end
    end
  end

  # ============================================================
  # Aggregation Tests
  # ============================================================

  def test_aggregate_group_by
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(5, "aggregate group by genre") do
        result = agent.execute(:aggregate,
                               class_name: "Song",
                               pipeline: [
                                 { "$group" => { "_id" => "$genre", "count" => { "$sum" => 1 } } },
                                 { "$sort" => { "count" => -1 } },
                               ])

        assert result[:success], "Should succeed: #{result[:error]}"
        assert result[:data][:results].size >= 1, "Should have aggregation results"

        # Each genre should have count of 1 since we have one song per genre
        result[:data][:results].each do |group|
          assert_equal 1, group["count"], "Each genre should have 1 song"
        end
      end
    end
  end

  def test_aggregate_sum
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(5, "aggregate sum of plays") do
        result = agent.execute(:aggregate,
                               class_name: "Song",
                               pipeline: [
                                 { "$group" => { "_id" => nil, "totalPlays" => { "$sum" => "$plays" } } },
                               ])

        assert result[:success], "Should succeed: #{result[:error]}"
        assert_equal 1, result[:data][:results].size

        expected_total = 5000 + 10000 + 2000 + 8000 + 3500 + 1500 + 12000 + 2500
        assert_equal expected_total, result[:data][:results].first["totalPlays"]
      end
    end
  end

  # ============================================================
  # Permission Tests
  # ============================================================

  def test_readonly_permission_denies_write
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      agent = Parse::Agent.new(permissions: :readonly)

      with_timeout(3, "attempt write with readonly") do
        result = agent.execute(:create_object,
                               class_name: "Song",
                               data: { title: "New Song" })

        refute result[:success], "Should deny write operation"
        assert_match(/permission denied/i, result[:error])
      end
    end
  end

  # ============================================================
  # Session Token Tests (ACL-scoped)
  # ============================================================

  def test_query_with_session_token
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      # Create a test user and get session token
      user = Parse::User.new(
        username: "agent_test_user_#{Time.now.to_i}",
        password: "test_password_123",
        email: "agent_test_#{Time.now.to_i}@example.com",
      )
      assert user.signup!, "Should create test user"

      agent = Parse::Agent.new(session_token: user.session_token)

      with_timeout(3, "query with session token") do
        result = agent.execute(:query_class, class_name: "Song", limit: 5)

        assert result[:success], "Should succeed with session token: #{result[:error]}"
        assert result[:data][:results].is_a?(Array)
      end
    end
  end

  # ============================================================
  # Explain Query Tests
  # ============================================================

  def test_explain_query
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(5, "setup test data") do
        setup_test_data
      end

      agent = Parse::Agent.new

      with_timeout(3, "explain query") do
        result = agent.execute(:explain_query,
                               class_name: "Song",
                               where: { "plays" => { "$gte" => 5000 } })

        assert result[:success], "Should succeed: #{result[:error]}"
        assert_equal "Song", result[:data][:class_name]
        assert result[:data][:explanation], "Should have explanation"
      end
    end
  end
end
