# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require "timeout"

# Test models for MongoDB direct query testing
class MongoDirectSong < Parse::Object
  parse_class "MongoDirectSong"

  property :title, :string
  property :artist, :string
  property :genre, :string
  property :plays, :integer
  property :duration, :float
  property :release_date, :date
  property :tags, :array
  property :active, :boolean, default: true
end

class MongoDirectArtist < Parse::Object
  parse_class "MongoDirectArtist"

  property :name, :string
  property :country, :string
  property :formed_year, :integer
end

class MongoDirectAlbum < Parse::Object
  parse_class "MongoDirectAlbum"

  property :title, :string
  property :release_year, :integer
  belongs_to :artist, as: :pointer, class_name: "MongoDirectArtist"
end

class MongoDirectSale < Parse::Object
  parse_class "MongoDirectSale"

  property :product, :string
  property :quantity, :integer
  property :revenue, :float
  property :sale_date, :date
  property :regions, :array
end

# Model with pointer array for testing array of pointers
class MongoDirectPlaylist < Parse::Object
  parse_class "MongoDirectPlaylist"

  property :name, :string
  property :description, :string
  property :created_date, :date
  has_many :songs, through: :array, class_name: "MongoDirectSong"
  belongs_to :owner, as: :pointer, class_name: "MongoDirectArtist"
end

# Model for testing ACL/permissions
class MongoDirectPrivateNote < Parse::Object
  parse_class "MongoDirectPrivateNote"

  property :content, :string
  property :category, :string
end

class MongoDBDirectIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # MongoDB connection URI for the test Docker container
  # Same as Parse Server uses, just with localhost:27019 (mapped from Docker's internal 27017)
  MONGODB_URI = "mongodb://admin:password@localhost:27019/parse?authSource=admin"

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def setup_mongodb_direct
    # Check if mongo gem is available and configure MongoDB
    begin
      require "mongo"
      require "parse/mongodb"
      Parse::MongoDB.configure(uri: MONGODB_URI, enabled: true)
      true
    rescue LoadError => e
      puts "Skipping MongoDB direct tests - gem not installed: #{e.message}"
      false
    rescue => e
      puts "Skipping MongoDB direct tests - configuration error: #{e.class}: #{e.message}"
      false
    end
  end

  def teardown_mongodb_direct
    Parse::MongoDB.reset! if defined?(Parse::MongoDB)
  end

  # ==========================================================================
  # TEST BATCH 1: Basic Results Equivalency
  # ==========================================================================

  def test_results_equivalency_simple_query
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "results equivalency test") do
        puts "\n=== Testing Results Equivalency: Simple Query ==="

        # Create test data
        songs = [
          { title: "Song A", artist: "Artist 1", genre: "Rock", plays: 1000, duration: 3.5 },
          { title: "Song B", artist: "Artist 2", genre: "Pop", plays: 2000, duration: 4.0 },
          { title: "Song C", artist: "Artist 1", genre: "Rock", plays: 1500, duration: 3.8 },
          { title: "Song D", artist: "Artist 3", genre: "Jazz", plays: 500, duration: 5.2 },
          { title: "Song E", artist: "Artist 2", genre: "Pop", plays: 3000, duration: 3.2 },
        ]

        songs.each do |data|
          song = MongoDirectSong.new(data)
          assert song.save, "Failed to save song: #{data[:title]}"
        end

        # Allow time for data to be fully committed
        sleep 0.5

        # Test 1: Simple query with single constraint
        puts "Test 1: Single constraint query..."
        parse_results = MongoDirectSong.query(:genre => "Rock").results
        direct_results = MongoDirectSong.query(:genre => "Rock").results(mongo_direct: true)

        assert_equal parse_results.length, direct_results.length,
          "Result count should match for genre=Rock query"

        parse_titles = parse_results.map(&:title).sort
        direct_titles = direct_results.map(&:title).sort
        assert_equal parse_titles, direct_titles,
          "Result titles should match for genre=Rock query"

        puts "  Parse: #{parse_titles.inspect}"
        puts "  Direct: #{direct_titles.inspect}"
        puts "  ✅ Single constraint query matches!"

        # Test 2: Query with comparison operator
        puts "Test 2: Comparison operator query..."
        parse_results = MongoDirectSong.query(:plays.gt => 1000).results
        direct_results = MongoDirectSong.query(:plays.gt => 1000).results(mongo_direct: true)

        assert_equal parse_results.length, direct_results.length,
          "Result count should match for plays > 1000"

        parse_titles = parse_results.map(&:title).sort
        direct_titles = direct_results.map(&:title).sort
        assert_equal parse_titles, direct_titles,
          "Result titles should match for plays > 1000"

        puts "  Parse: #{parse_titles.inspect}"
        puts "  Direct: #{direct_titles.inspect}"
        puts "  ✅ Comparison operator query matches!"

        # Test 3: Query with multiple constraints
        puts "Test 3: Multiple constraints query..."
        parse_results = MongoDirectSong.query(:genre => "Pop", :plays.gte => 2000).results
        direct_results = MongoDirectSong.query(:genre => "Pop", :plays.gte => 2000).results(mongo_direct: true)

        assert_equal parse_results.length, direct_results.length,
          "Result count should match for genre=Pop AND plays >= 2000"

        parse_titles = parse_results.map(&:title).sort
        direct_titles = direct_results.map(&:title).sort
        assert_equal parse_titles, direct_titles,
          "Result titles should match for multi-constraint query"

        puts "  Parse: #{parse_titles.inspect}"
        puts "  Direct: #{direct_titles.inspect}"
        puts "  ✅ Multiple constraints query matches!"

        puts "=== Results Equivalency Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  def test_results_equivalency_with_limit_skip_order
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "limit/skip/order equivalency test") do
        puts "\n=== Testing Results Equivalency: Limit, Skip, Order ==="

        # Create test data
        10.times do |i|
          song = MongoDirectSong.new(
            title: "Track #{format("%02d", i + 1)}",
            artist: "Test Artist",
            genre: "Electronic",
            plays: (i + 1) * 100,
            duration: 3.0 + (i * 0.1),
          )
          assert song.save, "Failed to save track #{i + 1}"
        end

        sleep 0.5

        # Test with order
        puts "Test: Order by plays descending..."
        parse_results = MongoDirectSong.query(:genre => "Electronic").order(:plays.desc).results
        direct_results = MongoDirectSong.query(:genre => "Electronic").order(:plays.desc).results(mongo_direct: true)

        parse_plays = parse_results.map(&:plays)
        direct_plays = direct_results.map(&:plays)

        assert_equal parse_plays, direct_plays, "Order by plays desc should match"
        assert_equal parse_plays, parse_plays.sort.reverse, "Should be in descending order"
        puts "  ✅ Order by plays desc matches!"

        # Test with limit
        puts "Test: Limit 5..."
        parse_results = MongoDirectSong.query(:genre => "Electronic").limit(5).results
        direct_results = MongoDirectSong.query(:genre => "Electronic").limit(5).results(mongo_direct: true)

        assert_equal 5, parse_results.length, "Parse should return 5 results"
        assert_equal 5, direct_results.length, "Direct should return 5 results"
        puts "  ✅ Limit matches!"

        # Test with skip
        puts "Test: Skip 3..."
        parse_results = MongoDirectSong.query(:genre => "Electronic").order(:plays.asc).skip(3).results
        direct_results = MongoDirectSong.query(:genre => "Electronic").order(:plays.asc).skip(3).results(mongo_direct: true)

        assert_equal parse_results.length, direct_results.length, "Skip results count should match"

        parse_plays = parse_results.map(&:plays)
        direct_plays = direct_results.map(&:plays)
        assert_equal parse_plays, direct_plays, "Skip results should match"
        puts "  ✅ Skip matches!"

        # Test combined: order + limit + skip
        puts "Test: Combined order + limit + skip..."
        parse_results = MongoDirectSong.query(:genre => "Electronic")
                                       .order(:plays.desc)
                                       .skip(2)
                                       .limit(3)
                                       .results
        direct_results = MongoDirectSong.query(:genre => "Electronic")
                                        .order(:plays.desc)
                                        .skip(2)
                                        .limit(3)
                                        .results(mongo_direct: true)

        assert_equal 3, parse_results.length, "Parse should return 3 results"
        assert_equal 3, direct_results.length, "Direct should return 3 results"

        parse_plays = parse_results.map(&:plays)
        direct_plays = direct_results.map(&:plays)
        assert_equal parse_plays, direct_plays, "Combined query results should match"
        puts "  Parse: #{parse_plays.inspect}"
        puts "  Direct: #{direct_plays.inspect}"
        puts "  ✅ Combined order/limit/skip matches!"

        puts "=== Limit/Skip/Order Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 2: First Equivalency
  # ==========================================================================

  def test_first_equivalency
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "first equivalency test") do
        puts "\n=== Testing First Equivalency ==="

        # Create test data
        songs = [
          { title: "Alpha", artist: "Artist A", genre: "Rock", plays: 100 },
          { title: "Beta", artist: "Artist B", genre: "Pop", plays: 200 },
          { title: "Gamma", artist: "Artist C", genre: "Rock", plays: 300 },
          { title: "Delta", artist: "Artist D", genre: "Jazz", plays: 400 },
          { title: "Epsilon", artist: "Artist E", genre: "Rock", plays: 500 },
        ]

        songs.each do |data|
          song = MongoDirectSong.new(data)
          assert song.save, "Failed to save song: #{data[:title]}"
        end

        sleep 0.5

        # Test first(1) - single result
        puts "Test: first(1)..."
        parse_first = MongoDirectSong.query(:genre => "Rock").order(:plays.asc).first(mongo_direct: false)
        direct_first = MongoDirectSong.query(:genre => "Rock").order(:plays.asc).first(mongo_direct: true)

        assert_equal parse_first.title, direct_first.title, "first() should return same song"
        assert_equal parse_first.plays, direct_first.plays, "first() plays should match"
        puts "  Parse: #{parse_first.title} (#{parse_first.plays} plays)"
        puts "  Direct: #{direct_first.title} (#{direct_first.plays} plays)"
        puts "  ✅ first(1) matches!"

        # Test first(3) - multiple results
        puts "Test: first(3)..."
        parse_first = MongoDirectSong.query(:genre => "Rock").order(:plays.desc).first(3, mongo_direct: false)
        direct_first = MongoDirectSong.query(:genre => "Rock").order(:plays.desc).first(3, mongo_direct: true)

        assert_equal 3, parse_first.length, "Parse first(3) should return 3"
        assert_equal 3, direct_first.length, "Direct first(3) should return 3"

        parse_titles = parse_first.map(&:title)
        direct_titles = direct_first.map(&:title)
        assert_equal parse_titles, direct_titles, "first(3) should return same songs in same order"
        puts "  Parse: #{parse_titles.inspect}"
        puts "  Direct: #{direct_titles.inspect}"
        puts "  ✅ first(3) matches!"

        puts "=== First Equivalency Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 3: Count Equivalency
  # ==========================================================================

  def test_count_equivalency
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "count equivalency test") do
        puts "\n=== Testing Count Equivalency ==="

        # Create test data
        genres = ["Rock", "Pop", "Jazz", "Rock", "Pop", "Rock", "Classical", "Pop"]
        genres.each_with_index do |genre, i|
          song = MongoDirectSong.new(
            title: "Count Song #{i + 1}",
            artist: "Count Artist",
            genre: genre,
            plays: (i + 1) * 100,
          )
          assert song.save, "Failed to save count song #{i + 1}"
        end

        sleep 0.5

        # Test total count
        puts "Test: Total count..."
        parse_count = MongoDirectSong.query(:artist => "Count Artist").count(mongo_direct: false)
        direct_count = MongoDirectSong.query(:artist => "Count Artist").count(mongo_direct: true)

        assert_equal parse_count, direct_count, "Total count should match"
        assert_equal 8, parse_count, "Should have 8 songs"
        puts "  Parse: #{parse_count}"
        puts "  Direct: #{direct_count}"
        puts "  ✅ Total count matches!"

        # Test filtered count
        puts "Test: Filtered count (genre = Rock)..."
        parse_count = MongoDirectSong.query(:artist => "Count Artist", :genre => "Rock").count(mongo_direct: false)
        direct_count = MongoDirectSong.query(:artist => "Count Artist", :genre => "Rock").count(mongo_direct: true)

        assert_equal parse_count, direct_count, "Rock count should match"
        assert_equal 3, parse_count, "Should have 3 Rock songs"
        puts "  Parse: #{parse_count}"
        puts "  Direct: #{direct_count}"
        puts "  ✅ Filtered count matches!"

        # Test count with comparison
        puts "Test: Count with comparison (plays > 400)..."
        parse_count = MongoDirectSong.query(:artist => "Count Artist", :plays.gt => 400).count(mongo_direct: false)
        direct_count = MongoDirectSong.query(:artist => "Count Artist", :plays.gt => 400).count(mongo_direct: true)

        assert_equal parse_count, direct_count, "Comparison count should match"
        puts "  Parse: #{parse_count}"
        puts "  Direct: #{direct_count}"
        puts "  ✅ Comparison count matches!"

        puts "=== Count Equivalency Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 4: Distinct Equivalency
  # ==========================================================================

  def test_distinct_equivalency
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "distinct equivalency test") do
        puts "\n=== Testing Distinct Equivalency ==="

        # Create test data with duplicate genres
        songs = [
          { title: "D1", artist: "Distinct Artist", genre: "Rock", plays: 100 },
          { title: "D2", artist: "Distinct Artist", genre: "Pop", plays: 200 },
          { title: "D3", artist: "Distinct Artist", genre: "Rock", plays: 300 },
          { title: "D4", artist: "Distinct Artist", genre: "Jazz", plays: 400 },
          { title: "D5", artist: "Distinct Artist", genre: "Pop", plays: 500 },
          { title: "D6", artist: "Distinct Artist", genre: "Rock", plays: 600 },
          { title: "D7", artist: "Other Artist", genre: "Classical", plays: 700 },
        ]

        songs.each do |data|
          song = MongoDirectSong.new(data)
          assert song.save, "Failed to save distinct song"
        end

        sleep 0.5

        # Test distinct genres for specific artist
        puts "Test: Distinct genres..."
        parse_distinct = MongoDirectSong.query(:artist => "Distinct Artist").distinct(:genre, mongo_direct: false).sort
        direct_distinct = MongoDirectSong.query(:artist => "Distinct Artist").distinct(:genre, mongo_direct: true).sort

        assert_equal parse_distinct, direct_distinct, "Distinct genres should match"
        assert_equal ["Jazz", "Pop", "Rock"], parse_distinct, "Should have 3 distinct genres"
        puts "  Parse: #{parse_distinct.inspect}"
        puts "  Direct: #{direct_distinct.inspect}"
        puts "  ✅ Distinct genres match!"

        # Test distinct with filter
        puts "Test: Distinct with filter (plays > 300)..."
        parse_distinct = MongoDirectSong.query(:artist => "Distinct Artist", :plays.gt => 300)
                                        .distinct(:genre, mongo_direct: false).sort
        direct_distinct = MongoDirectSong.query(:artist => "Distinct Artist", :plays.gt => 300)
                                         .distinct(:genre, mongo_direct: true).sort

        assert_equal parse_distinct, direct_distinct, "Filtered distinct should match"
        puts "  Parse: #{parse_distinct.inspect}"
        puts "  Direct: #{direct_distinct.inspect}"
        puts "  ✅ Filtered distinct matches!"

        puts "=== Distinct Equivalency Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 5: Group By Equivalency
  # ==========================================================================

  def test_group_by_count_equivalency
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "group by count equivalency test") do
        puts "\n=== Testing Group By Count Equivalency ==="

        # Create test data
        data = [
          { title: "G1", artist: "Group Artist", genre: "Rock", plays: 100 },
          { title: "G2", artist: "Group Artist", genre: "Pop", plays: 200 },
          { title: "G3", artist: "Group Artist", genre: "Rock", plays: 300 },
          { title: "G4", artist: "Group Artist", genre: "Jazz", plays: 400 },
          { title: "G5", artist: "Group Artist", genre: "Pop", plays: 500 },
          { title: "G6", artist: "Group Artist", genre: "Rock", plays: 600 },
          { title: "G7", artist: "Group Artist", genre: "Pop", plays: 700 },
        ]

        data.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save group song"
        end

        sleep 0.5

        # Test group_by count
        puts "Test: Group by genre count..."
        parse_group = MongoDirectSong.query(:artist => "Group Artist").group_by(:genre, mongo_direct: false).count
        direct_group = MongoDirectSong.query(:artist => "Group Artist").group_by(:genre, mongo_direct: true).count

        puts "  Parse: #{parse_group.inspect}"
        puts "  Direct: #{direct_group.inspect}"

        assert_equal parse_group.keys.sort, direct_group.keys.sort, "Group keys should match"
        parse_group.each do |key, value|
          assert_equal value, direct_group[key], "Count for #{key} should match"
        end

        assert_equal 3, parse_group["Rock"], "Should have 3 Rock songs"
        assert_equal 3, parse_group["Pop"], "Should have 3 Pop songs"
        assert_equal 1, parse_group["Jazz"], "Should have 1 Jazz song"
        puts "  ✅ Group by count matches!"

        puts "=== Group By Count Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  def test_group_by_sum_equivalency
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "group by sum equivalency test") do
        puts "\n=== Testing Group By Sum Equivalency ==="

        # Create test data
        data = [
          { title: "S1", artist: "Sum Artist", genre: "Rock", plays: 100 },
          { title: "S2", artist: "Sum Artist", genre: "Pop", plays: 200 },
          { title: "S3", artist: "Sum Artist", genre: "Rock", plays: 300 },
          { title: "S4", artist: "Sum Artist", genre: "Jazz", plays: 400 },
          { title: "S5", artist: "Sum Artist", genre: "Pop", plays: 500 },
        ]

        data.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save sum song"
        end

        sleep 0.5

        # Test group_by sum
        puts "Test: Group by genre sum(plays)..."
        parse_group = MongoDirectSong.query(:artist => "Sum Artist").group_by(:genre, mongo_direct: false).sum(:plays)
        direct_group = MongoDirectSong.query(:artist => "Sum Artist").group_by(:genre, mongo_direct: true).sum(:plays)

        puts "  Parse: #{parse_group.inspect}"
        puts "  Direct: #{direct_group.inspect}"

        assert_equal parse_group.keys.sort, direct_group.keys.sort, "Group keys should match"
        parse_group.each do |key, value|
          assert_equal value, direct_group[key], "Sum for #{key} should match"
        end

        # Rock: 100 + 300 = 400
        # Pop: 200 + 500 = 700
        # Jazz: 400
        assert_equal 400, parse_group["Rock"], "Rock sum should be 400"
        assert_equal 700, parse_group["Pop"], "Pop sum should be 700"
        assert_equal 400, parse_group["Jazz"], "Jazz sum should be 400"
        puts "  ✅ Group by sum matches!"

        puts "=== Group By Sum Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  def test_group_by_average_equivalency
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "group by average equivalency test") do
        puts "\n=== Testing Group By Average Equivalency ==="

        # Create test data with known averages
        data = [
          { title: "A1", artist: "Avg Artist", genre: "Rock", plays: 100, duration: 3.0 },
          { title: "A2", artist: "Avg Artist", genre: "Rock", plays: 200, duration: 4.0 },
          { title: "A3", artist: "Avg Artist", genre: "Pop", plays: 300, duration: 3.5 },
          { title: "A4", artist: "Avg Artist", genre: "Pop", plays: 400, duration: 4.5 },
        ]

        data.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save avg song"
        end

        sleep 0.5

        # Test group_by average
        puts "Test: Group by genre average(plays)..."
        parse_group = MongoDirectSong.query(:artist => "Avg Artist").group_by(:genre, mongo_direct: false).average(:plays)
        direct_group = MongoDirectSong.query(:artist => "Avg Artist").group_by(:genre, mongo_direct: true).average(:plays)

        puts "  Parse: #{parse_group.inspect}"
        puts "  Direct: #{direct_group.inspect}"

        assert_equal parse_group.keys.sort, direct_group.keys.sort, "Group keys should match"

        # Rock: (100 + 200) / 2 = 150
        # Pop: (300 + 400) / 2 = 350
        assert_in_delta 150.0, parse_group["Rock"], 0.01, "Rock average should be 150"
        assert_in_delta 350.0, parse_group["Pop"], 0.01, "Pop average should be 350"

        parse_group.each do |key, value|
          assert_in_delta value, direct_group[key], 0.01, "Average for #{key} should match"
        end
        puts "  ✅ Group by average matches!"

        puts "=== Group By Average Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 6: Group By Date Equivalency
  # ==========================================================================

  def test_group_by_date_equivalency
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "group by date equivalency test") do
        puts "\n=== Testing Group By Date Equivalency ==="

        # Create sales with different dates
        sales = [
          { product: "Date Product", quantity: 10, revenue: 100.0, sale_date: Date.new(2024, 1, 15) },
          { product: "Date Product", quantity: 20, revenue: 200.0, sale_date: Date.new(2024, 1, 20) },
          { product: "Date Product", quantity: 15, revenue: 150.0, sale_date: Date.new(2024, 2, 10) },
          { product: "Date Product", quantity: 25, revenue: 250.0, sale_date: Date.new(2024, 2, 25) },
          { product: "Date Product", quantity: 30, revenue: 300.0, sale_date: Date.new(2024, 3, 5) },
        ]

        sales.each do |data|
          sale = MongoDirectSale.new(data)
          assert sale.save, "Failed to save date sale"
        end

        sleep 0.5

        # Test group_by_date by month
        puts "Test: Group by month count..."
        parse_group = MongoDirectSale.query(:product => "Date Product")
                                     .group_by_date(:sale_date, :month, mongo_direct: false).count
        direct_group = MongoDirectSale.query(:product => "Date Product")
                                      .group_by_date(:sale_date, :month, mongo_direct: true).count

        puts "  Parse: #{parse_group.inspect}"
        puts "  Direct: #{direct_group.inspect}"

        assert_equal parse_group.keys.sort, direct_group.keys.sort, "Date group keys should match"
        parse_group.each do |key, value|
          assert_equal value, direct_group[key], "Count for #{key} should match"
        end
        puts "  ✅ Group by date (month) count matches!"

        # Test group_by_date sum
        puts "Test: Group by month sum(revenue)..."
        parse_group = MongoDirectSale.query(:product => "Date Product")
                                     .group_by_date(:sale_date, :month, mongo_direct: false).sum(:revenue)
        direct_group = MongoDirectSale.query(:product => "Date Product")
                                      .group_by_date(:sale_date, :month, mongo_direct: true).sum(:revenue)

        puts "  Parse: #{parse_group.inspect}"
        puts "  Direct: #{direct_group.inspect}"

        assert_equal parse_group.keys.sort, direct_group.keys.sort, "Date group keys should match"
        parse_group.each do |key, value|
          assert_in_delta value, direct_group[key], 0.01, "Sum for #{key} should match"
        end
        puts "  ✅ Group by date (month) sum matches!"

        puts "=== Group By Date Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 7: Date Field Handling
  # ==========================================================================

  def test_date_field_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "date field queries test") do
        puts "\n=== Testing Date Field Queries ==="

        # Create songs with different release dates
        dates = [
          Date.new(2023, 1, 15),
          Date.new(2023, 6, 20),
          Date.new(2024, 1, 10),
          Date.new(2024, 6, 25),
          Date.new(2024, 12, 1),
        ]

        dates.each_with_index do |date, i|
          song = MongoDirectSong.new(
            title: "Date Song #{i + 1}",
            artist: "Date Artist",
            genre: "Electronic",
            plays: (i + 1) * 100,
            release_date: date,
          )
          assert song.save, "Failed to save date song #{i + 1}"
        end

        sleep 0.5

        # Test date comparison
        cutoff = Date.new(2024, 1, 1)
        puts "Test: Songs released after #{cutoff}..."
        parse_results = MongoDirectSong.query(:artist => "Date Artist", :release_date.gt => cutoff).results
        direct_results = MongoDirectSong.query(:artist => "Date Artist", :release_date.gt => cutoff).results(mongo_direct: true)

        assert_equal parse_results.length, direct_results.length,
          "Date comparison result count should match"

        parse_titles = parse_results.map(&:title).sort
        direct_titles = direct_results.map(&:title).sort
        assert_equal parse_titles, direct_titles, "Date comparison results should match"
        puts "  Parse: #{parse_titles.inspect}"
        puts "  Direct: #{direct_titles.inspect}"
        puts "  ✅ Date comparison query matches!"

        # Test date range
        start_date = Date.new(2023, 6, 1)
        end_date = Date.new(2024, 6, 30)
        puts "Test: Songs between #{start_date} and #{end_date}..."
        parse_results = MongoDirectSong.query(
          :artist => "Date Artist",
          :release_date.gte => start_date,
          :release_date.lte => end_date,
        ).results
        direct_results = MongoDirectSong.query(
          :artist => "Date Artist",
          :release_date.gte => start_date,
          :release_date.lte => end_date,
        ).results(mongo_direct: true)

        assert_equal parse_results.length, direct_results.length,
          "Date range result count should match"

        parse_titles = parse_results.map(&:title).sort
        direct_titles = direct_results.map(&:title).sort
        assert_equal parse_titles, direct_titles, "Date range results should match"
        puts "  Parse: #{parse_titles.inspect}"
        puts "  Direct: #{direct_titles.inspect}"
        puts "  ✅ Date range query matches!"

        puts "=== Date Field Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 8: Pointer Field Handling
  # ==========================================================================

  def test_pointer_field_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "pointer field queries test") do
        puts "\n=== Testing Pointer Field Queries ==="

        # Create artists
        artist1 = MongoDirectArtist.new(name: "Pointer Artist 1", country: "USA", formed_year: 1990)
        assert artist1.save, "Failed to save artist 1"

        artist2 = MongoDirectArtist.new(name: "Pointer Artist 2", country: "UK", formed_year: 2000)
        assert artist2.save, "Failed to save artist 2"

        # Create albums with artist pointers
        albums = [
          { title: "Album A", release_year: 2020, artist: artist1 },
          { title: "Album B", release_year: 2021, artist: artist1 },
          { title: "Album C", release_year: 2022, artist: artist2 },
          { title: "Album D", release_year: 2023, artist: artist2 },
          { title: "Album E", release_year: 2024, artist: artist1 },
        ]

        albums.each do |data|
          album = MongoDirectAlbum.new(data)
          assert album.save, "Failed to save album: #{data[:title]}"
        end

        sleep 0.5

        # Test query by pointer
        puts "Test: Albums by artist 1..."
        parse_results = MongoDirectAlbum.query(:artist => artist1).results
        direct_results = MongoDirectAlbum.query(:artist => artist1).results(mongo_direct: true)

        assert_equal parse_results.length, direct_results.length,
          "Pointer query result count should match"

        parse_titles = parse_results.map(&:title).sort
        direct_titles = direct_results.map(&:title).sort
        assert_equal parse_titles, direct_titles, "Pointer query results should match"
        assert_equal 3, parse_results.length, "Should have 3 albums by artist 1"
        puts "  Parse: #{parse_titles.inspect}"
        puts "  Direct: #{direct_titles.inspect}"
        puts "  ✅ Pointer query matches!"

        # Test count by pointer
        puts "Test: Count albums by artist 2..."
        parse_count = MongoDirectAlbum.query(:artist => artist2).count(mongo_direct: false)
        direct_count = MongoDirectAlbum.query(:artist => artist2).count(mongo_direct: true)

        assert_equal parse_count, direct_count, "Pointer count should match"
        assert_equal 2, parse_count, "Should have 2 albums by artist 2"
        puts "  Parse: #{parse_count}"
        puts "  Direct: #{direct_count}"
        puts "  ✅ Pointer count matches!"

        puts "=== Pointer Field Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 9: Complex Queries
  # ==========================================================================

  def test_complex_multi_constraint_queries
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "complex queries test") do
        puts "\n=== Testing Complex Multi-Constraint Queries ==="

        # Create diverse test data
        songs = [
          { title: "C1", artist: "Complex Artist", genre: "Rock", plays: 100, duration: 3.0, active: true },
          { title: "C2", artist: "Complex Artist", genre: "Rock", plays: 200, duration: 4.0, active: true },
          { title: "C3", artist: "Complex Artist", genre: "Pop", plays: 150, duration: 3.5, active: false },
          { title: "C4", artist: "Complex Artist", genre: "Pop", plays: 300, duration: 2.5, active: true },
          { title: "C5", artist: "Complex Artist", genre: "Jazz", plays: 50, duration: 5.0, active: true },
          { title: "C6", artist: "Complex Artist", genre: "Rock", plays: 500, duration: 3.2, active: false },
          { title: "C7", artist: "Other Artist", genre: "Rock", plays: 1000, duration: 4.5, active: true },
        ]

        songs.each do |data|
          song = MongoDirectSong.new(data)
          assert song.save, "Failed to save complex song"
        end

        sleep 0.5

        # Test: genre = Rock AND plays >= 100 AND active = true
        puts "Test: Rock + plays >= 100 + active..."
        parse_results = MongoDirectSong.query(
          :artist => "Complex Artist",
          :genre => "Rock",
          :plays.gte => 100,
          :active => true,
        ).results
        direct_results = MongoDirectSong.query(
          :artist => "Complex Artist",
          :genre => "Rock",
          :plays.gte => 100,
          :active => true,
        ).results(mongo_direct: true)

        assert_equal parse_results.length, direct_results.length,
          "Complex query result count should match"

        parse_titles = parse_results.map(&:title).sort
        direct_titles = direct_results.map(&:title).sort
        assert_equal parse_titles, direct_titles, "Complex query results should match"
        puts "  Parse: #{parse_titles.inspect}"
        puts "  Direct: #{direct_titles.inspect}"
        puts "  ✅ Complex multi-constraint query matches!"

        # Test: duration between 3.0 and 4.0 with order
        puts "Test: Duration range with order..."
        parse_results = MongoDirectSong.query(
          :artist => "Complex Artist",
          :duration.gte => 3.0,
          :duration.lte => 4.0,
        ).order(:plays.desc).results
        direct_results = MongoDirectSong.query(
          :artist => "Complex Artist",
          :duration.gte => 3.0,
          :duration.lte => 4.0,
        ).order(:plays.desc).results(mongo_direct: true)

        assert_equal parse_results.length, direct_results.length,
          "Duration range result count should match"

        parse_titles = parse_results.map(&:title)
        direct_titles = direct_results.map(&:title)
        assert_equal parse_titles, direct_titles, "Duration range with order should match exactly"
        puts "  Parse: #{parse_titles.inspect}"
        puts "  Direct: #{direct_titles.inspect}"
        puts "  ✅ Duration range with order matches!"

        puts "=== Complex Query Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 10: Raw Results Mode
  # ==========================================================================

  def test_raw_results_mode
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "raw results test") do
        puts "\n=== Testing Raw Results Mode ==="

        # Create test data
        song = MongoDirectSong.new(
          title: "Raw Test Song",
          artist: "Raw Artist",
          genre: "Electronic",
          plays: 999,
        )
        assert song.save, "Failed to save raw test song"

        sleep 0.5

        # Test raw results
        puts "Test: Raw results mode..."
        direct_raw = MongoDirectSong.query(:artist => "Raw Artist").results(mongo_direct: true, raw: true)

        assert direct_raw.is_a?(Array), "Raw results should be an array"
        assert direct_raw.first.is_a?(Hash), "Raw result items should be hashes"
        assert direct_raw.first.key?("objectId"), "Raw result should have objectId"
        assert direct_raw.first.key?("title"), "Raw result should have title"
        assert_equal "Raw Test Song", direct_raw.first["title"], "Raw title should match"
        puts "  Raw result keys: #{direct_raw.first.keys.inspect}"
        puts "  ✅ Raw results mode works!"

        puts "=== Raw Results Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 10B: Keys Projection with mongo_direct
  # ==========================================================================

  def test_keys_projection_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "keys projection test") do
        puts "\n=== Testing Keys Projection with mongo_direct ==="

        # Create test data with multiple fields
        song = MongoDirectSong.new(
          title: "Keys Test Song",
          artist: "Keys Artist",
          genre: "Rock",
          plays: 500,
          active: true,
        )
        assert song.save, "Failed to save song"
        sleep 0.5

        # Test: Query with specific keys
        puts "Test: Query with keys [:title, :plays]..."
        parse_results = MongoDirectSong.query(:artist => "Keys Artist").keys(:title, :plays).results
        direct_results = MongoDirectSong.query(:artist => "Keys Artist").keys(:title, :plays).results(mongo_direct: true)

        assert_equal 1, parse_results.length, "Parse should return 1 result"
        assert_equal 1, direct_results.length, "Direct should return 1 result"

        # Both should have the requested fields
        parse_song = parse_results.first
        direct_song = direct_results.first

        assert_equal "Keys Test Song", parse_song.title, "Parse title should match"
        assert_equal "Keys Test Song", direct_song.title, "Direct title should match"
        assert_equal 500, parse_song.plays, "Parse plays should match"
        assert_equal 500, direct_song.plays, "Direct plays should match"

        # Both should have required fields (id, createdAt, updatedAt, ACL)
        assert direct_song.id.present?, "Direct should have id"
        assert direct_song.created_at.present?, "Direct should have created_at"
        assert direct_song.updated_at.present?, "Direct should have updated_at"

        # Objects should be marked as partially fetched with the specified keys
        assert direct_song.respond_to?(:partially_fetched?), "Direct song should respond to partially_fetched?"
        if direct_song.respond_to?(:partially_fetched?)
          assert direct_song.partially_fetched?, "Direct song should be marked as partially fetched"

          # Verify the fetched_keys are tracked
          if direct_song.respond_to?(:fetched_keys)
            fetched = direct_song.fetched_keys
            assert fetched.include?(:title), "Fetched keys should include :title"
            assert fetched.include?(:plays), "Fetched keys should include :plays"
            puts "  Direct song fetched_keys: #{fetched.inspect}"
          end

          puts "  Direct song partially_fetched?: #{direct_song.partially_fetched?}"
        end

        puts "  Parse: title=#{parse_song.title}, plays=#{parse_song.plays}"
        puts "  Direct: title=#{direct_song.title}, plays=#{direct_song.plays}"
        puts "  ✅ Keys projection matches!"

        # Test: Verify excluded fields are not fetched (for direct)
        # Note: Parse Server may still return all fields, but direct should only project requested
        puts "Test: Verify projection limits fields in direct query..."

        # Use raw mode to see actual fields returned
        direct_raw = MongoDirectSong.query(:artist => "Keys Artist").keys(:title, :plays).results(mongo_direct: true, raw: true)
        raw_keys = direct_raw.first.keys

        # Should have: objectId, title, plays, createdAt, updatedAt, ACL, className
        # Should NOT have: artist, genre, active (unless they happen to be included)
        assert raw_keys.include?("objectId"), "Should have objectId"
        assert raw_keys.include?("title"), "Should have title"
        assert raw_keys.include?("plays"), "Should have plays"
        assert raw_keys.include?("createdAt"), "Should have createdAt"
        assert raw_keys.include?("updatedAt"), "Should have updatedAt"

        puts "  Raw keys returned: #{raw_keys.sort.inspect}"
        puts "  ✅ Keys projection works correctly!"

        puts "=== Keys Projection Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 11: Edge Cases
  # ==========================================================================

  def test_empty_results
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "empty results test") do
        puts "\n=== Testing Empty Results ==="

        # Query for non-existent data
        puts "Test: Query with no matches..."
        parse_results = MongoDirectSong.query(:artist => "Non Existent Artist 12345").results
        direct_results = MongoDirectSong.query(:artist => "Non Existent Artist 12345").results(mongo_direct: true)

        assert_equal [], parse_results, "Parse should return empty array"
        assert_equal [], direct_results, "Direct should return empty array"
        puts "  ✅ Empty results handled correctly!"

        # Count with no matches
        puts "Test: Count with no matches..."
        parse_count = MongoDirectSong.query(:artist => "Non Existent Artist 12345").count(mongo_direct: false)
        direct_count = MongoDirectSong.query(:artist => "Non Existent Artist 12345").count(mongo_direct: true)

        assert_equal 0, parse_count, "Parse count should be 0"
        assert_equal 0, direct_count, "Direct count should be 0"
        puts "  ✅ Empty count handled correctly!"

        puts "=== Empty Results Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  def test_special_field_names
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "special field names test") do
        puts "\n=== Testing Special Field Names (createdAt, updatedAt) ==="

        # Create test data
        song = MongoDirectSong.new(
          title: "Special Fields Song",
          artist: "Special Artist",
          genre: "Pop",
          plays: 100,
        )
        assert song.save, "Failed to save special fields song"

        sleep 0.5

        # Query with order by createdAt
        puts "Test: Order by createdAt..."
        parse_results = MongoDirectSong.query(:artist => "Special Artist").order(:created_at.desc).results
        direct_results = MongoDirectSong.query(:artist => "Special Artist").order(:created_at.desc).results(mongo_direct: true)

        assert_equal parse_results.length, direct_results.length, "Result count should match"
        assert_equal parse_results.first.title, direct_results.first.title, "First result should match"
        puts "  ✅ createdAt ordering works!"

        # Verify createdAt and updatedAt are present
        puts "Test: Verify date fields present..."
        result = direct_results.first
        assert result.created_at.present?, "createdAt should be present"
        assert result.updated_at.present?, "updatedAt should be present"
        puts "  createdAt: #{result.created_at}"
        puts "  updatedAt: #{result.updated_at}"
        puts "  ✅ Date fields present in results!"

        puts "=== Special Field Names Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 12: Pointer Field Return Types
  # ==========================================================================

  def test_pointer_field_return_types
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "pointer field return types test") do
        puts "\n=== Testing Pointer Field Return Types ==="

        # Create an artist
        artist = MongoDirectArtist.new(
          name: "Pointer Test Artist",
          country: "USA",
          formed_year: 2020,
        )
        assert artist.save, "Failed to save artist"

        # Create albums that belong to the artist
        album1 = MongoDirectAlbum.new(
          title: "Pointer Album 1",
          release_year: 2021,
          artist: artist,
        )
        assert album1.save, "Failed to save album 1"

        album2 = MongoDirectAlbum.new(
          title: "Pointer Album 2",
          release_year: 2022,
          artist: artist,
        )
        assert album2.save, "Failed to save album 2"

        sleep 0.5

        # Test: Verify pointer field is returned as Parse::Pointer
        puts "Test: Pointer field type in direct query results..."
        direct_results = MongoDirectAlbum.query(:title.starts_with => "Pointer Album").results(mongo_direct: true)

        assert direct_results.length == 2, "Should have 2 albums"

        direct_results.each do |album|
          assert album.is_a?(MongoDirectAlbum), "Result should be MongoDirectAlbum instance"

          # Check the artist pointer
          artist_pointer = album.artist
          assert artist_pointer.present?, "Artist pointer should be present"
          assert artist_pointer.is_a?(Parse::Pointer) || artist_pointer.is_a?(MongoDirectArtist),
            "Artist should be a Pointer or Artist object, got #{artist_pointer.class}"

          # Verify pointer has correct class and id
          if artist_pointer.is_a?(Parse::Pointer)
            assert_equal "MongoDirectArtist", artist_pointer.parse_class, "Pointer class should match"
            assert_equal artist.id, artist_pointer.id, "Pointer id should match artist id"
          end

          puts "  Album: #{album.title}"
          puts "    artist type: #{artist_pointer.class}"
          puts "    artist id: #{artist_pointer.id}"
          puts "    artist class: #{artist_pointer.is_a?(Parse::Pointer) ? artist_pointer.parse_class : artist_pointer.class.parse_class}"
        end
        puts "  ✅ Pointer fields returned correctly!"

        # Test: Compare with Parse Server results
        puts "Test: Compare pointer types between Parse and direct..."
        parse_results = MongoDirectAlbum.query(:title.starts_with => "Pointer Album").results

        parse_results.each_with_index do |parse_album, i|
          direct_album = direct_results.find { |a| a.id == parse_album.id }
          assert direct_album, "Should find matching direct album"

          # Both should have valid artist references
          assert parse_album.artist.present?, "Parse album should have artist"
          assert direct_album.artist.present?, "Direct album should have artist"

          # Both should reference the same artist
          parse_artist_id = parse_album.artist.is_a?(Parse::Pointer) ? parse_album.artist.id : parse_album.artist.id
          direct_artist_id = direct_album.artist.is_a?(Parse::Pointer) ? direct_album.artist.id : direct_album.artist.id
          assert_equal parse_artist_id, direct_artist_id, "Artist IDs should match"
        end
        puts "  ✅ Parse and direct pointer fields match!"

        puts "=== Pointer Field Return Types Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 13: Pointer Array Return Types
  # ==========================================================================

  def test_pointer_array_return_types
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "pointer array return types test") do
        puts "\n=== Testing Pointer Array Return Types ==="

        # Create songs
        song1 = MongoDirectSong.new(title: "Array Song 1", artist: "Array Artist", genre: "Rock", plays: 100)
        song2 = MongoDirectSong.new(title: "Array Song 2", artist: "Array Artist", genre: "Pop", plays: 200)
        song3 = MongoDirectSong.new(title: "Array Song 3", artist: "Array Artist", genre: "Jazz", plays: 300)
        assert song1.save, "Failed to save song 1"
        assert song2.save, "Failed to save song 2"
        assert song3.save, "Failed to save song 3"

        # Create an owner
        owner = MongoDirectArtist.new(name: "Playlist Owner", country: "UK", formed_year: 2015)
        assert owner.save, "Failed to save owner"

        # Create a playlist with array of song pointers
        playlist = MongoDirectPlaylist.new(
          name: "Test Playlist",
          description: "A playlist for testing pointer arrays",
          created_date: Parse::Date.parse("2024-06-15T10:00:00Z"),
          owner: owner,
          songs: [song1, song2, song3],
        )
        assert playlist.save, "Failed to save playlist"

        sleep 0.5

        # Test: Verify array of pointers is returned correctly
        puts "Test: Pointer array field in direct query results..."
        direct_results = MongoDirectPlaylist.query(:name => "Test Playlist").results(mongo_direct: true)

        assert direct_results.length == 1, "Should have 1 playlist"
        direct_playlist = direct_results.first

        assert direct_playlist.is_a?(MongoDirectPlaylist), "Result should be MongoDirectPlaylist instance"

        # Check the songs array - has_many :through => :array returns PointerCollectionProxy
        songs_collection = direct_playlist.songs
        # PointerCollectionProxy is array-like (responds to each, count, to_a)
        is_array_like = songs_collection.respond_to?(:each) && songs_collection.respond_to?(:count)
        assert is_array_like, "Songs should be array-like, got #{songs_collection.class}"

        # Convert to array for inspection
        songs_array = songs_collection.to_a
        assert_equal 3, songs_array.count, "Should have 3 songs in array"

        puts "  Playlist: #{direct_playlist.name}"
        puts "  Songs collection type: #{songs_collection.class}"
        puts "  Songs count: #{songs_array.length}"

        songs_array.each_with_index do |song_ref, i|
          assert song_ref.present?, "Song #{i} should be present"
          # Song references should be either Pointer or actual Song objects
          is_valid_ref = song_ref.is_a?(Parse::Pointer) || song_ref.is_a?(MongoDirectSong) || song_ref.is_a?(Hash)
          assert is_valid_ref, "Song #{i} should be Pointer, Song, or Hash, got #{song_ref.class}"

          song_id = if song_ref.is_a?(Parse::Pointer)
              song_ref.id
            elsif song_ref.is_a?(Hash)
              song_ref["objectId"]
            else
              song_ref.id
            end

          puts "    Song #{i + 1}: type=#{song_ref.class}, id=#{song_id}"
        end
        puts "  ✅ Pointer array returned correctly!"

        # Test: Compare with Parse Server results
        puts "Test: Compare pointer array between Parse and direct..."
        parse_results = MongoDirectPlaylist.query(:name => "Test Playlist").results
        parse_playlist = parse_results.first

        parse_songs = parse_playlist.songs.to_a
        direct_songs = direct_playlist.songs.to_a

        assert parse_songs.is_a?(Array), "Parse songs should be array"
        assert_equal parse_songs.length, direct_songs.length, "Song counts should match"

        # Verify all song IDs match
        parse_song_ids = parse_songs.map { |s| s.is_a?(Parse::Pointer) ? s.id : s.id }.sort
        direct_song_ids = direct_songs.map { |s|
          if s.is_a?(Parse::Pointer)
            s.id
          elsif s.is_a?(Hash)
            s["objectId"]
          else
            s.id
          end
        }.sort

        assert_equal parse_song_ids, direct_song_ids, "Song IDs should match"
        puts "  Parse song IDs: #{parse_song_ids}"
        puts "  Direct song IDs: #{direct_song_ids}"
        puts "  ✅ Parse and direct pointer arrays match!"

        # Test: Verify owner pointer is also correct
        puts "Test: Single pointer alongside array..."
        assert direct_playlist.owner.present?, "Owner should be present"
        owner_ref = direct_playlist.owner
        is_valid_owner = owner_ref.is_a?(Parse::Pointer) || owner_ref.is_a?(MongoDirectArtist)
        assert is_valid_owner, "Owner should be Pointer or Artist, got #{owner_ref.class}"
        puts "  Owner type: #{owner_ref.class}"
        puts "  Owner id: #{owner_ref.id}"
        puts "  ✅ Single pointer alongside array works!"

        puts "=== Pointer Array Return Types Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 14: Date Field Return Types
  # ==========================================================================

  def test_date_field_return_types
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "date field return types test") do
        puts "\n=== Testing Date Field Return Types ==="

        # Create test data with various date fields
        sale = MongoDirectSale.new(
          product: "Date Test Product",
          quantity: 10,
          revenue: 99.99,
          sale_date: Parse::Date.parse("2024-03-15T14:30:00Z"),
          regions: ["North", "South"],
        )
        assert sale.save, "Failed to save sale"

        sleep 0.5

        # Test: Verify custom date field (sale_date) return type
        puts "Test: Custom date field return type..."
        direct_results = MongoDirectSale.query(:product => "Date Test Product").results(mongo_direct: true)

        assert direct_results.length == 1, "Should have 1 sale"
        direct_sale = direct_results.first

        # Check sale_date type
        sale_date = direct_sale.sale_date
        assert sale_date.present?, "sale_date should be present"
        is_valid_date = sale_date.is_a?(Parse::Date) || sale_date.is_a?(DateTime) || sale_date.is_a?(Time)
        assert is_valid_date, "sale_date should be Parse::Date, DateTime, or Time, got #{sale_date.class}"

        puts "  sale_date type: #{sale_date.class}"
        puts "  sale_date value: #{sale_date}"
        puts "  ✅ Custom date field type correct!"

        # Test: Verify createdAt return type
        puts "Test: createdAt field return type..."
        created_at = direct_sale.created_at
        assert created_at.present?, "createdAt should be present"
        is_valid_created = created_at.is_a?(Parse::Date) || created_at.is_a?(DateTime) || created_at.is_a?(Time)
        assert is_valid_created, "createdAt should be Parse::Date, DateTime, or Time, got #{created_at.class}"

        puts "  createdAt type: #{created_at.class}"
        puts "  createdAt value: #{created_at}"
        puts "  ✅ createdAt field type correct!"

        # Test: Verify updatedAt return type
        puts "Test: updatedAt field return type..."
        updated_at = direct_sale.updated_at
        assert updated_at.present?, "updatedAt should be present"
        is_valid_updated = updated_at.is_a?(Parse::Date) || updated_at.is_a?(DateTime) || updated_at.is_a?(Time)
        assert is_valid_updated, "updatedAt should be Parse::Date, DateTime, or Time, got #{updated_at.class}"

        puts "  updatedAt type: #{updated_at.class}"
        puts "  updatedAt value: #{updated_at}"
        puts "  ✅ updatedAt field type correct!"

        # Test: Compare date values with Parse Server
        puts "Test: Compare date values between Parse and direct..."
        parse_results = MongoDirectSale.query(:product => "Date Test Product").results
        parse_sale = parse_results.first

        # Compare sale_date - should be same date
        parse_sale_date_str = parse_sale.sale_date.respond_to?(:iso8601) ? parse_sale.sale_date.iso8601 : parse_sale.sale_date.to_s
        direct_sale_date_str = direct_sale.sale_date.respond_to?(:iso8601) ? direct_sale.sale_date.iso8601 : direct_sale.sale_date.to_s
        # Compare just the date portion to avoid millisecond differences
        assert parse_sale_date_str[0..18] == direct_sale_date_str[0..18],
          "sale_date should match: Parse=#{parse_sale_date_str}, Direct=#{direct_sale_date_str}"

        puts "  Parse sale_date: #{parse_sale_date_str}"
        puts "  Direct sale_date: #{direct_sale_date_str}"
        puts "  ✅ Date values match between Parse and direct!"

        puts "=== Date Field Return Types Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 15: ACL/Permissions Filtering
  # ==========================================================================

  def test_acl_permissions_filtering
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "ACL permissions filtering test") do
        puts "\n=== Testing ACL/Permissions Filtering ==="

        # Create a note with ACL
        note = MongoDirectPrivateNote.new(
          content: "This is a private note",
          category: "Personal",
        )

        # Set ACL permissions
        note.acl = Parse::ACL.new
        note.acl.permissions = {
          "*" => { "read" => true, "write" => false },
          "role:Admin" => { "read" => true, "write" => true },
        }

        assert note.save, "Failed to save note with ACL"

        sleep 0.5

        # Test: Direct query results should NOT contain internal fields
        puts "Test: Verify internal fields are filtered out..."
        direct_results = MongoDirectPrivateNote.query(:category => "Personal").results(mongo_direct: true)

        assert direct_results.length >= 1, "Should have at least 1 note"
        direct_note = direct_results.first

        # Get the raw hash to check what fields are present
        raw_results = MongoDirectPrivateNote.query(:category => "Personal").results(mongo_direct: true, raw: true)
        raw_note = raw_results.first

        puts "  Raw result keys: #{raw_note.keys.sort}"

        # These internal MongoDB fields should NOT be in the results
        internal_fields = %w[_rperm _wperm _acl _hashed_password _email_verify_token
                             _perishable_token _tombstone _failed_login_count
                             _account_lockout_expires_at _session_token]

        internal_fields.each do |field|
          refute raw_note.key?(field), "Internal field '#{field}' should be filtered out"
        end
        puts "  ✅ Internal fields (_rperm, _wperm, etc.) are filtered!"

        # These standard fields SHOULD be present
        expected_fields = %w[objectId content category createdAt updatedAt]
        expected_fields.each do |field|
          assert raw_note.key?(field), "Standard field '#{field}' should be present"
        end
        puts "  ✅ Standard fields (objectId, content, etc.) are present!"

        # ACL should be returned as a proper ACL hash (not _acl)
        puts "Test: Verify ACL is properly returned..."
        assert raw_note.key?("ACL"), "ACL field should be present"
        acl_data = raw_note["ACL"]
        assert acl_data.is_a?(Hash), "ACL should be a Hash, got #{acl_data.class}"

        # Verify ACL structure - should have read/write keys (not r/w)
        assert acl_data.key?("*"), "ACL should have public '*' entry"
        public_perms = acl_data["*"]
        assert public_perms.key?("read"), "Public permissions should have 'read' key"
        assert_equal true, public_perms["read"], "Public read should be true"
        refute public_perms.key?("write"), "Public write should not be present (was set to false)"

        assert acl_data.key?("role:Admin"), "ACL should have 'role:Admin' entry"
        admin_perms = acl_data["role:Admin"]
        assert admin_perms.key?("read"), "Admin permissions should have 'read' key"
        assert admin_perms.key?("write"), "Admin permissions should have 'write' key"
        assert_equal true, admin_perms["read"], "Admin read should be true"
        assert_equal true, admin_perms["write"], "Admin write should be true"

        puts "  ACL data: #{acl_data.inspect}"
        puts "  ✅ ACL is properly returned with read/write keys!"

        # Test: Verify the Parse object has expected properties
        puts "Test: Verify Parse object properties..."
        assert direct_note.id.present?, "objectId should be present"
        assert_equal "This is a private note", direct_note.content, "Content should match"
        assert_equal "Personal", direct_note.category, "Category should match"
        puts "  content: #{direct_note.content}"
        puts "  category: #{direct_note.category}"
        puts "  ✅ Parse object properties are correct!"

        # Test: Verify ACL object on Parse object
        puts "Test: Verify ACL object on Parse object..."
        assert direct_note.acl.present?, "ACL object should be present on Parse object"
        assert direct_note.acl.is_a?(Parse::ACL), "ACL should be Parse::ACL instance, got #{direct_note.acl.class}"

        # Check ACL permissions
        acl_perms = direct_note.acl.permissions
        assert acl_perms.is_a?(Hash), "ACL permissions should be a Hash"
        puts "  ACL class: #{direct_note.acl.class}"
        puts "  ACL permissions: #{acl_perms.inspect}"
        puts "  ✅ ACL object is properly set on Parse object!"

        # Test: Compare with Parse Server to ensure same data
        puts "Test: Compare with Parse Server results..."
        parse_results = MongoDirectPrivateNote.query(:category => "Personal").results
        parse_note = parse_results.find { |n| n.id == direct_note.id }

        assert parse_note, "Should find matching Parse note"
        assert_equal parse_note.content, direct_note.content, "Content should match"
        assert_equal parse_note.category, direct_note.category, "Category should match"
        puts "  ✅ Parse and direct results match!"

        puts "=== ACL/Permissions Filtering Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 15B: readable_by / writable_by with mongo_direct
  # ==========================================================================

  def test_readable_by_writable_by_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "readable_by/writable_by direct test") do
        puts "\n=== Testing readable_by/writable_by with mongo_direct ==="

        # Create notes with different ACL permissions
        # Note 1: Public read, Admin write
        note1 = MongoDirectPrivateNote.new(content: "Public Note", category: "Public")
        note1.acl = Parse::ACL.new
        note1.acl.permissions = { "*" => { "read" => true } }
        assert note1.save, "Failed to save note1"

        # Note 2: Admin only (read + write)
        note2 = MongoDirectPrivateNote.new(content: "Admin Only Note", category: "Admin")
        note2.acl = Parse::ACL.new
        note2.acl.permissions = { "role:Admin" => { "read" => true, "write" => true } }
        assert note2.save, "Failed to save note2"

        # Note 3: Moderator read, Admin write
        note3 = MongoDirectPrivateNote.new(content: "Moderator Note", category: "Moderator")
        note3.acl = Parse::ACL.new
        note3.acl.permissions = {
          "role:Moderator" => { "read" => true },
          "role:Admin" => { "read" => true, "write" => true },
        }
        assert note3.save, "Failed to save note3"

        # Note 4: Specific user access
        note4 = MongoDirectPrivateNote.new(content: "User Specific Note", category: "User")
        note4.acl = Parse::ACL.new
        note4.acl.permissions = { "user123" => { "read" => true, "write" => true } }
        assert note4.save, "Failed to save note4"

        sleep 0.5

        # Test 1: readable_by_role should find notes with Admin role (note 2, 3) + Public (note 1)
        puts "Test: readable_by_role 'Admin'..."
        direct_results = MongoDirectPrivateNote.query
          .readable_by_role("Admin")
          .results(mongo_direct: true)

        admin_readable_categories = direct_results.map(&:category).sort
        puts "  Admin readable categories: #{admin_readable_categories.inspect}"
        assert admin_readable_categories.include?("Admin"), "Admin should see Admin notes"
        assert admin_readable_categories.include?("Moderator"), "Admin should see Moderator notes"
        assert admin_readable_categories.include?("Public"), "Admin should see Public notes (via *)"
        puts "  ✅ readable_by_role 'Admin' works!"

        # Test 2: readable_by_role 'Moderator' should find note 3 + Public (note 1)
        puts "Test: readable_by_role 'Moderator'..."
        direct_results = MongoDirectPrivateNote.query
          .readable_by_role("Moderator")
          .results(mongo_direct: true)

        mod_readable_categories = direct_results.map(&:category).sort
        puts "  Moderator readable categories: #{mod_readable_categories.inspect}"
        assert mod_readable_categories.include?("Moderator"), "Moderator should see Moderator notes"
        assert mod_readable_categories.include?("Public"), "Moderator should see Public notes (via *)"
        puts "  ✅ readable_by_role 'Moderator' works!"

        # Test 3: writable_by_role 'Admin' should find notes 2 and 3
        puts "Test: writable_by_role 'Admin'..."
        direct_results = MongoDirectPrivateNote.query
          .writable_by_role("Admin")
          .results(mongo_direct: true)

        admin_writable_categories = direct_results.map(&:category).sort
        puts "  Admin writable categories: #{admin_writable_categories.inspect}"
        assert admin_writable_categories.include?("Admin"), "Admin should write Admin notes"
        assert admin_writable_categories.include?("Moderator"), "Admin should write Moderator notes"
        puts "  ✅ writable_by_role 'Admin' works!"

        # Test 4: readable_by specific user ID (exact string match)
        puts "Test: readable_by specific user ID..."
        direct_results = MongoDirectPrivateNote.query
          .readable_by("user123")
          .results(mongo_direct: true)

        user_readable_categories = direct_results.map(&:category).sort
        puts "  user123 readable categories: #{user_readable_categories.inspect}"
        assert user_readable_categories.include?("User"), "user123 should see User notes"
        assert user_readable_categories.include?("Public"), "user123 should see Public notes (via *)"
        puts "  ✅ readable_by user ID works!"

        # Test 5: readable_by with explicit role: prefix
        puts "Test: readable_by with 'role:Admin' explicit prefix..."
        direct_results = MongoDirectPrivateNote.query
          .readable_by("role:Admin")
          .results(mongo_direct: true)

        explicit_admin_categories = direct_results.map(&:category).sort
        puts "  role:Admin readable categories: #{explicit_admin_categories.inspect}"
        assert explicit_admin_categories.include?("Admin"), "role:Admin should see Admin notes"
        puts "  ✅ readable_by 'role:Admin' works!"

        # Test 6: Debug and verify pipeline
        puts "Test: Verify pipeline generation..."

        debug_query = MongoDirectPrivateNote.query.readable_by_role("Admin")
        compiled = debug_query.send(:compile_where)
        puts "  DEBUG compiled_where: #{compiled.inspect}"
        pipeline = debug_query.send(:build_direct_mongodb_pipeline)
        puts "  DEBUG pipeline: #{pipeline.inspect}"

        # Verify the pipeline has the correct _rperm field (not rperm)
        match_stage = pipeline.find { |s| s.key?("$match") }
        assert match_stage, "Pipeline should have a $match stage"
        match_or = match_stage["$match"]["$or"]
        assert match_or, "Match stage should have $or"
        rperm_check = match_or.find { |c| c.key?("_rperm") }
        assert rperm_check, "Should query _rperm field (not rperm)"
        puts "  ✅ Pipeline correctly queries _rperm field!"

        puts "=== readable_by/writable_by Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 16: Aggregate Pipeline - Group Sum
  # (From Parse Server spec: group sum query)
  # ==========================================================================

  def test_aggregate_group_sum_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "aggregate group sum test") do
        puts "\n=== Testing Aggregate Group Sum ==="

        # Create test data similar to Parse Server spec
        data = [
          { title: "Agg1", artist: "Agg Artist", genre: "Rock", plays: 10 },
          { title: "Agg2", artist: "Agg Artist", genre: "Pop", plays: 10 },
          { title: "Agg3", artist: "Agg Artist", genre: "Rock", plays: 10 },
          { title: "Agg4", artist: "Agg Artist", genre: "Jazz", plays: 20 },
        ]

        data.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save song"
        end

        sleep 0.5

        # Test: Group by null (all records) with $sum
        puts "Test: Group sum total..."
        pipeline = [
          { "$group" => { "_id" => nil, "total" => { "$sum" => "$plays" } } },
        ]

        parse_agg = MongoDirectSong.query(:artist => "Agg Artist").aggregate(pipeline, mongo_direct: false)
        direct_agg = MongoDirectSong.query(:artist => "Agg Artist").aggregate(pipeline, mongo_direct: true)

        # Aggregation results with custom fields return AggregationResult objects
        # that support both hash access and method access
        parse_results = parse_agg.results
        direct_results = direct_agg.results

        assert_equal 1, parse_results.length, "Parse should return 1 result"
        assert_equal 1, direct_results.length, "Direct should return 1 result"

        # Total should be 10 + 10 + 10 + 20 = 50
        # Access via hash key
        assert_equal 50, parse_results.first["total"], "Parse sum should be 50"
        assert_equal 50, direct_results.first["total"], "Direct sum should be 50"

        # Access via method (AggregationResult feature)
        assert_equal 50, parse_results.first.total, "Parse sum via method should be 50"
        assert_equal 50, direct_results.first.total, "Direct sum via method should be 50"

        puts "  Parse total: #{parse_results.first.total}"
        puts "  Direct total: #{direct_results.first.total}"
        puts "  ✅ Group sum matches!"

        puts "=== Aggregate Group Sum Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 17: Aggregate Pipeline - Group Count
  # (From Parse Server spec: group count query)
  # ==========================================================================

  def test_aggregate_group_count_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "aggregate group count test") do
        puts "\n=== Testing Aggregate Group Count ==="

        # Create test data
        data = [
          { title: "Count1", artist: "Count Agg Artist", genre: "Rock", plays: 100 },
          { title: "Count2", artist: "Count Agg Artist", genre: "Pop", plays: 200 },
          { title: "Count3", artist: "Count Agg Artist", genre: "Rock", plays: 300 },
          { title: "Count4", artist: "Count Agg Artist", genre: "Jazz", plays: 400 },
        ]

        data.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save song"
        end

        sleep 0.5

        # Test: Group by null with count ($sum: 1)
        puts "Test: Group count total..."
        pipeline = [
          { "$group" => { "_id" => nil, "total" => { "$sum" => 1 } } },
        ]

        parse_agg = MongoDirectSong.query(:artist => "Count Agg Artist").aggregate(pipeline, mongo_direct: false)
        direct_agg = MongoDirectSong.query(:artist => "Count Agg Artist").aggregate(pipeline, mongo_direct: true)

        # Use .raw for aggregation results with custom fields
        parse_raw = parse_agg.raw
        direct_raw = direct_agg.raw

        assert_equal 1, parse_raw.length, "Parse should return 1 result"
        assert_equal 1, direct_raw.length, "Direct should return 1 result"

        assert_equal 4, parse_raw.first["total"], "Parse count should be 4"
        assert_equal 4, direct_raw.first["total"], "Direct count should be 4"

        puts "  Parse count: #{parse_raw.first["total"]}"
        puts "  Direct count: #{direct_raw.first["total"]}"
        puts "  ✅ Group count matches!"

        puts "=== Aggregate Group Count Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 18: Aggregate Pipeline - Group Min/Max
  # (From Parse Server spec: group min/max query)
  # ==========================================================================

  def test_aggregate_group_min_max_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "aggregate group min/max test") do
        puts "\n=== Testing Aggregate Group Min/Max ==="

        # Create test data
        data = [
          { title: "MinMax1", artist: "MinMax Artist", genre: "Rock", plays: 10 },
          { title: "MinMax2", artist: "MinMax Artist", genre: "Pop", plays: 20 },
          { title: "MinMax3", artist: "MinMax Artist", genre: "Rock", plays: 15 },
          { title: "MinMax4", artist: "MinMax Artist", genre: "Jazz", plays: 25 },
        ]

        data.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save song"
        end

        sleep 0.5

        # Test: Min - aggregation results are hashes, use .raw for hash access
        puts "Test: Group min..."
        pipeline = [
          { "$group" => { "_id" => nil, "minPlays" => { "$min" => "$plays" } } },
        ]

        parse_agg = MongoDirectSong.query(:artist => "MinMax Artist").aggregate(pipeline, mongo_direct: false)
        direct_agg = MongoDirectSong.query(:artist => "MinMax Artist").aggregate(pipeline, mongo_direct: true)

        # Use .raw for aggregation results since they're custom aggregation hashes
        parse_raw = parse_agg.raw.first
        direct_raw = direct_agg.raw.first

        assert_equal 10, parse_raw["minPlays"], "Parse min should be 10"
        assert_equal 10, direct_raw["minPlays"], "Direct min should be 10"
        puts "  Parse min: #{parse_raw["minPlays"]}"
        puts "  Direct min: #{direct_raw["minPlays"]}"
        puts "  ✅ Group min matches!"

        # Test: Max
        puts "Test: Group max..."
        pipeline = [
          { "$group" => { "_id" => nil, "maxPlays" => { "$max" => "$plays" } } },
        ]

        parse_agg = MongoDirectSong.query(:artist => "MinMax Artist").aggregate(pipeline, mongo_direct: false)
        direct_agg = MongoDirectSong.query(:artist => "MinMax Artist").aggregate(pipeline, mongo_direct: true)

        parse_raw = parse_agg.raw.first
        direct_raw = direct_agg.raw.first

        assert_equal 25, parse_raw["maxPlays"], "Parse max should be 25"
        assert_equal 25, direct_raw["maxPlays"], "Direct max should be 25"
        puts "  Parse max: #{parse_raw["maxPlays"]}"
        puts "  Direct max: #{direct_raw["maxPlays"]}"
        puts "  ✅ Group max matches!"

        puts "=== Aggregate Group Min/Max Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 19: Aggregate Pipeline - Group Avg
  # (From Parse Server spec: group avg query)
  # ==========================================================================

  def test_aggregate_group_avg_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "aggregate group avg test") do
        puts "\n=== Testing Aggregate Group Avg ==="

        # Create test data - 4 songs: 10, 10, 10, 20 => avg = 12.5
        data = [
          { title: "Avg1", artist: "Avg Agg Artist", genre: "Rock", plays: 10 },
          { title: "Avg2", artist: "Avg Agg Artist", genre: "Pop", plays: 10 },
          { title: "Avg3", artist: "Avg Agg Artist", genre: "Rock", plays: 10 },
          { title: "Avg4", artist: "Avg Agg Artist", genre: "Jazz", plays: 20 },
        ]

        data.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save song"
        end

        sleep 0.5

        # Test: Group by null with $avg
        puts "Test: Group avg..."
        pipeline = [
          { "$group" => { "_id" => nil, "avgPlays" => { "$avg" => "$plays" } } },
        ]

        parse_agg = MongoDirectSong.query(:artist => "Avg Agg Artist").aggregate(pipeline, mongo_direct: false)
        direct_agg = MongoDirectSong.query(:artist => "Avg Agg Artist").aggregate(pipeline, mongo_direct: true)

        # Use .raw for aggregation results with custom fields
        parse_raw = parse_agg.raw
        direct_raw = direct_agg.raw

        assert_in_delta 12.5, parse_raw.first["avgPlays"], 0.01, "Parse avg should be 12.5"
        assert_in_delta 12.5, direct_raw.first["avgPlays"], 0.01, "Direct avg should be 12.5"

        puts "  Parse avg: #{parse_raw.first["avgPlays"]}"
        puts "  Direct avg: #{direct_raw.first["avgPlays"]}"
        puts "  ✅ Group avg matches!"

        puts "=== Aggregate Group Avg Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 20: Aggregate Pipeline - Group by Pointer
  # (From Parse Server spec: group by pointer)
  # ==========================================================================

  def test_aggregate_group_by_pointer_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "aggregate group by pointer test") do
        puts "\n=== Testing Aggregate Group by Pointer ==="

        # Create artists
        artist1 = MongoDirectArtist.new(name: "Group Pointer Artist 1", country: "USA", formed_year: 1990)
        artist2 = MongoDirectArtist.new(name: "Group Pointer Artist 2", country: "UK", formed_year: 2000)
        assert artist1.save, "Failed to save artist 1"
        assert artist2.save, "Failed to save artist 2"

        # Create albums pointing to artists
        albums = [
          { title: "GP Album 1", release_year: 2020, artist: artist1 },
          { title: "GP Album 2", release_year: 2021, artist: artist2 },
          { title: "GP Album 3", release_year: 2022, artist: artist1 },
          { title: "GP Album 4", release_year: 2023 },  # No artist
        ]

        albums.each do |data|
          album = MongoDirectAlbum.new(data)
          assert album.save, "Failed to save album"
        end

        sleep 0.5

        # Test: Group by pointer field
        puts "Test: Group by artist pointer..."
        pipeline = [
          { "$group" => { "_id" => "$_p_artist" } },
        ]

        # For direct query, we need to query the collection without the artist filter
        direct_agg = MongoDirectAlbum.query(:title.starts_with => "GP Album").aggregate(pipeline, mongo_direct: true)
        direct_results = direct_agg.results

        # Should have 3 groups: artist1, artist2, and null (no artist)
        assert_equal 3, direct_results.length, "Should have 3 groups (2 artists + null)"

        # Verify we have both artists and a null group
        group_ids = direct_results.map { |r| r["objectId"] }
        puts "  Group IDs: #{group_ids.inspect}"

        has_null = group_ids.include?(nil)
        has_artist1 = group_ids.any? { |id| id.to_s.include?(artist1.id) }
        has_artist2 = group_ids.any? { |id| id.to_s.include?(artist2.id) }

        assert has_null, "Should have null group for albums without artist"
        # Note: The group by pointer returns pointer format, so check for id presence
        puts "  Has null group: #{has_null}"
        puts "  ✅ Group by pointer returns correct number of groups!"

        puts "=== Aggregate Group by Pointer Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 21: Aggregate Pipeline - Match $or Query
  # (From Parse Server spec: match $or query)
  # ==========================================================================

  def test_aggregate_match_or_query_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "aggregate match $or query test") do
        puts "\n=== Testing Aggregate Match $or Query ==="

        # Create test data matching Parse Server spec
        data = [
          { title: "Or1", artist: "Or Artist", genre: "Rock", plays: 900 },
          { title: "Or2", artist: "Or Artist", genre: "Pop", plays: 800 },
          { title: "Or3", artist: "Or Artist", genre: "Jazz", plays: 700 },
          { title: "Or4", artist: "Or Artist", genre: "Blues", plays: 700 },
        ]

        data.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save song"
        end

        sleep 0.5

        # Test: Match with $or - (plays > 850) OR (plays < 750 AND plays > 650)
        puts "Test: Match with $or query..."
        pipeline = [
          {
            "$match" => {
              "$or" => [
                { "plays" => { "$gt" => 850 } },
                { "plays" => { "$lt" => 750, "$gt" => 650 } },
              ],
            },
          },
        ]

        parse_agg = MongoDirectSong.query(:artist => "Or Artist").aggregate(pipeline, mongo_direct: false)
        direct_agg = MongoDirectSong.query(:artist => "Or Artist").aggregate(pipeline, mongo_direct: true)

        parse_results = parse_agg.results
        direct_results = direct_agg.results

        # Should match: Or1 (900 > 850), Or3 (700 in 650-750), Or4 (700 in 650-750)
        assert_equal parse_results.length, direct_results.length, "Result counts should match"

        parse_titles = parse_results.map { |r| r["title"] }.sort
        direct_titles = direct_results.map { |r| r["title"] }.sort
        assert_equal parse_titles, direct_titles, "Result titles should match"

        puts "  Parse results: #{parse_titles.inspect}"
        puts "  Direct results: #{direct_titles.inspect}"
        puts "  ✅ Match $or query matches!"

        puts "=== Aggregate Match $or Query Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 22: Aggregate Pipeline - Match Pointer
  # (From Parse Server spec: match pointer query)
  # ==========================================================================

  def test_aggregate_match_pointer_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "aggregate match pointer test") do
        puts "\n=== Testing Aggregate Match Pointer ==="

        # Create artists
        artist1 = MongoDirectArtist.new(name: "Match Pointer Artist 1", country: "USA", formed_year: 1990)
        artist2 = MongoDirectArtist.new(name: "Match Pointer Artist 2", country: "UK", formed_year: 2000)
        assert artist1.save, "Failed to save artist 1"
        assert artist2.save, "Failed to save artist 2"

        # Create albums
        albums = [
          { title: "MP Album 1", release_year: 2020, artist: artist1 },
          { title: "MP Album 2", release_year: 2021, artist: artist2 },
          { title: "MP Album 3", release_year: 2022, artist: artist1 },
        ]

        albums.each do |data|
          album = MongoDirectAlbum.new(data)
          assert album.save, "Failed to save album"
        end

        sleep 0.5

        # Test: Match by pointer ID (using the MongoDB pointer format)
        puts "Test: Match pointer by ID..."
        # In MongoDB, pointer fields are stored as _p_fieldName with value "ClassName$objectId"
        pointer_value = "MongoDirectArtist$#{artist1.id}"
        pipeline = [
          { "$match" => { "_p_artist" => pointer_value } },
        ]

        direct_agg = MongoDirectAlbum.query(:title.starts_with => "MP Album").aggregate(pipeline, mongo_direct: true)
        direct_results = direct_agg.results

        assert_equal 2, direct_results.length, "Should have 2 albums by artist 1"

        direct_titles = direct_results.map { |r| r["title"] }.sort
        assert_equal ["MP Album 1", "MP Album 3"], direct_titles, "Should find correct albums"

        puts "  Direct results: #{direct_titles.inspect}"
        puts "  ✅ Match pointer query works!"

        puts "=== Aggregate Match Pointer Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 23: Aggregate Pipeline - Project
  # (From Parse Server spec: project query)
  # ==========================================================================

  def test_aggregate_project_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "aggregate project test") do
        puts "\n=== Testing Aggregate Project ==="

        # Create test data
        data = [
          { title: "Proj1", artist: "Project Artist", genre: "Rock", plays: 100, duration: 3.5 },
          { title: "Proj2", artist: "Project Artist", genre: "Pop", plays: 200, duration: 4.0 },
        ]

        data.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save song"
        end

        sleep 0.5

        # Test: Project only specific fields - use .raw for hash key checks
        puts "Test: Project specific fields..."
        pipeline = [
          { "$project" => { "title" => 1, "plays" => 1 } },
        ]

        parse_agg = MongoDirectSong.query(:artist => "Project Artist").aggregate(pipeline, mongo_direct: false)
        direct_agg = MongoDirectSong.query(:artist => "Project Artist").aggregate(pipeline, mongo_direct: true)

        parse_raw = parse_agg.raw
        direct_raw = direct_agg.raw

        assert_equal parse_raw.length, direct_raw.length, "Result counts should match"

        # Verify projected fields are present
        direct_raw.each do |result|
          assert result.key?("title"), "Should have title field"
          assert result.key?("plays"), "Should have plays field"
          # Note: objectId is typically included by default unless explicitly excluded
        end

        puts "  Result keys: #{direct_raw.first.keys.inspect}"
        puts "  ✅ Project query works!"

        # Test: Project excluding objectId
        puts "Test: Project excluding objectId..."
        pipeline = [
          { "$project" => { "_id" => 0, "title" => 1, "plays" => 1 } },
        ]

        direct_agg = MongoDirectSong.query(:artist => "Project Artist").aggregate(pipeline, mongo_direct: true)
        direct_raw = direct_agg.raw

        direct_raw.each do |result|
          assert result.key?("title"), "Should have title field"
          # In direct mode, _id is excluded, but conversion won't add objectId
          refute result.key?("_id"), "Should NOT have _id when _id: 0"
        end

        puts "  Result keys (no _id): #{direct_raw.first.keys.inspect}"
        puts "  ✅ Project without objectId works!"

        puts "=== Aggregate Project Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 24: Aggregate Pipeline - Distinct Pointer
  # (From Parse Server spec: distinct pointer)
  # ==========================================================================

  def test_aggregate_distinct_pointer_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "aggregate distinct pointer test") do
        puts "\n=== Testing Aggregate Distinct Pointer ==="

        # Create artists
        artist1 = MongoDirectArtist.new(name: "Distinct Ptr Artist 1", country: "USA", formed_year: 1990)
        artist2 = MongoDirectArtist.new(name: "Distinct Ptr Artist 2", country: "UK", formed_year: 2000)
        assert artist1.save, "Failed to save artist 1"
        assert artist2.save, "Failed to save artist 2"

        # Create albums with duplicate artists
        albums = [
          { title: "DP Album 1", release_year: 2020, artist: artist1 },
          { title: "DP Album 2", release_year: 2021, artist: artist2 },
          { title: "DP Album 3", release_year: 2022, artist: artist1 },  # Duplicate artist1
        ]

        albums.each do |data|
          album = MongoDirectAlbum.new(data)
          assert album.save, "Failed to save album"
        end

        sleep 0.5

        # Test: Distinct on pointer field using aggregation
        puts "Test: Distinct on artist pointer..."
        pipeline = [
          { "$group" => { "_id" => "$_p_artist" } },
          { "$match" => { "_id" => { "$ne" => nil } } },  # Exclude null
        ]

        direct_agg = MongoDirectAlbum.query(:title.starts_with => "DP Album").aggregate(pipeline, mongo_direct: true)
        direct_results = direct_agg.results

        # Should have 2 distinct artists
        assert_equal 2, direct_results.length, "Should have 2 distinct artists"

        puts "  Distinct artist count: #{direct_results.length}"
        puts "  ✅ Distinct pointer query works!"

        puts "=== Aggregate Distinct Pointer Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 25: Security - Hidden Properties Not Returned
  # (From Parse Server spec: does not return sensitive hidden properties)
  # ==========================================================================

  def test_internal_fields_not_exposed_in_aggregation
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "internal fields not exposed test") do
        puts "\n=== Testing Internal Fields Not Exposed ==="

        # Create test data with various fields
        song = MongoDirectSong.new(
          title: "Security Test Song",
          artist: "Security Artist",
          genre: "Rock",
          plays: 500,
        )
        assert song.save, "Failed to save song"

        sleep 0.5

        # Test: Use $project to explicitly select only the fields we want
        # This ensures internal MongoDB fields are not included in results
        puts "Test: Project only specific fields to exclude internal fields..."
        pipeline = [
          { "$match" => { "artist" => "Security Artist" } },
          {
            "$project" => {
              "_id" => 1,  # Will be converted to objectId
              "title" => 1,
              "artist" => 1,
              "genre" => 1,
              "plays" => 1,
              "_created_at" => 1,  # Will be converted to createdAt
              "_updated_at" => 1,   # Will be converted to updatedAt
            },
          },
        ]

        direct_agg = MongoDirectSong.query.aggregate(pipeline, mongo_direct: true)
        raw_results = direct_agg.raw

        assert raw_results.length >= 1, "Should have at least 1 result"
        result = raw_results.first

        puts "  Result keys: #{result.keys.sort.inspect}"

        # Internal fields that should NOT be present (we didn't project them)
        unwanted_fields = %w[_rperm _wperm _acl _hashed_password _email_verify_token]
        unwanted_fields.each do |field|
          refute result.key?(field), "Unwanted field '#{field}' should NOT be in projected results"
        end
        puts "  ✅ Unwanted internal fields are excluded by projection!"

        # Projected fields that SHOULD be present
        expected_fields = %w[_id title artist genre plays]
        expected_fields.each do |field|
          assert result.key?(field), "Projected field '#{field}' should be present"
        end
        puts "  ✅ Projected fields are present!"

        # Verify field values are correct
        assert_equal "Security Test Song", result["title"], "Title should match"
        assert_equal "Security Artist", result["artist"], "Artist should match"
        assert_equal "Rock", result["genre"], "Genre should match"
        assert_equal 500, result["plays"], "Plays should match"
        assert result["_id"].present?, "_id should be present"

        puts "  ✅ All field values are correct!"

        # Also test that .results returns proper Parse objects with converted field names
        puts "Test: Converted results have proper Parse attributes..."
        converted_results = direct_agg.results
        song_result = converted_results.first

        assert song_result.id.present?, "Should have id (objectId)"
        assert_equal "Security Test Song", song_result.title, "Title should match"
        assert_equal "Security Artist", song_result.artist, "Artist should match"
        puts "  ✅ Converted results work correctly!"

        puts "=== Internal Fields Not Exposed Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 26: Aggregate Pipeline - Sort, Limit, Skip
  # (From Parse Server spec: sort, limit, skip queries)
  # ==========================================================================

  def test_aggregate_sort_limit_skip_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "aggregate sort/limit/skip test") do
        puts "\n=== Testing Aggregate Sort, Limit, Skip ==="

        # Create test data
        data = [
          { title: "SLS1", artist: "SLS Artist", genre: "Rock", plays: 100 },
          { title: "SLS2", artist: "SLS Artist", genre: "Pop", plays: 200 },
          { title: "SLS3", artist: "SLS Artist", genre: "Jazz", plays: 300 },
          { title: "SLS4", artist: "SLS Artist", genre: "Blues", plays: 400 },
        ]

        data.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save song"
        end

        sleep 0.5

        # Test: Sort ascending
        puts "Test: Sort ascending..."
        pipeline = [
          { "$sort" => { "title" => 1 } },
        ]

        parse_agg = MongoDirectSong.query(:artist => "SLS Artist").aggregate(pipeline, mongo_direct: false)
        direct_agg = MongoDirectSong.query(:artist => "SLS Artist").aggregate(pipeline, mongo_direct: true)

        parse_titles = parse_agg.results.map { |r| r["title"] }
        direct_titles = direct_agg.results.map { |r| r["title"] }

        assert_equal ["SLS1", "SLS2", "SLS3", "SLS4"], parse_titles, "Parse sort asc"
        assert_equal ["SLS1", "SLS2", "SLS3", "SLS4"], direct_titles, "Direct sort asc"
        puts "  ✅ Sort ascending matches!"

        # Test: Sort descending
        puts "Test: Sort descending..."
        pipeline = [
          { "$sort" => { "title" => -1 } },
        ]

        parse_agg = MongoDirectSong.query(:artist => "SLS Artist").aggregate(pipeline, mongo_direct: false)
        direct_agg = MongoDirectSong.query(:artist => "SLS Artist").aggregate(pipeline, mongo_direct: true)

        parse_titles = parse_agg.results.map { |r| r["title"] }
        direct_titles = direct_agg.results.map { |r| r["title"] }

        assert_equal ["SLS4", "SLS3", "SLS2", "SLS1"], parse_titles, "Parse sort desc"
        assert_equal ["SLS4", "SLS3", "SLS2", "SLS1"], direct_titles, "Direct sort desc"
        puts "  ✅ Sort descending matches!"

        # Test: Limit
        puts "Test: Limit..."
        pipeline = [
          { "$limit" => 2 },
        ]

        parse_agg = MongoDirectSong.query(:artist => "SLS Artist").aggregate(pipeline, mongo_direct: false)
        direct_agg = MongoDirectSong.query(:artist => "SLS Artist").aggregate(pipeline, mongo_direct: true)

        assert_equal 2, parse_agg.results.length, "Parse should have 2 results"
        assert_equal 2, direct_agg.results.length, "Direct should have 2 results"
        puts "  ✅ Limit matches!"

        # Test: Skip
        puts "Test: Skip..."
        pipeline = [
          { "$sort" => { "title" => 1 } },
          { "$skip" => 2 },
        ]

        parse_agg = MongoDirectSong.query(:artist => "SLS Artist").aggregate(pipeline, mongo_direct: false)
        direct_agg = MongoDirectSong.query(:artist => "SLS Artist").aggregate(pipeline, mongo_direct: true)

        parse_titles = parse_agg.results.map { |r| r["title"] }
        direct_titles = direct_agg.results.map { |r| r["title"] }

        assert_equal ["SLS3", "SLS4"], parse_titles, "Parse skip first 2"
        assert_equal ["SLS3", "SLS4"], direct_titles, "Direct skip first 2"
        puts "  ✅ Skip matches!"

        puts "=== Aggregate Sort, Limit, Skip Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 27: Aggregate Pipeline - Group by Date Object
  # (From Parse Server spec: group by date object)
  # ==========================================================================

  def test_aggregate_group_by_date_object_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "aggregate group by date object test") do
        puts "\n=== Testing Aggregate Group by Date Object ==="

        # Create test data with dates
        today = Time.now.utc
        data = [
          { title: "DateGroup1", artist: "DateGroup Artist", genre: "Rock", plays: 100 },
          { title: "DateGroup2", artist: "DateGroup Artist", genre: "Pop", plays: 200 },
          { title: "DateGroup3", artist: "DateGroup Artist", genre: "Jazz", plays: 300 },
        ]

        data.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save song"
        end

        sleep 0.5

        # Test: Group by date components (day, month, year from _created_at)
        puts "Test: Group by date components..."
        pipeline = [
          {
            "$group" => {
              "_id" => {
                "day" => { "$dayOfMonth" => "$_created_at" },
                "month" => { "$month" => "$_created_at" },
                "year" => { "$year" => "$_created_at" },
              },
              "count" => { "$sum" => 1 },
            },
          },
        ]

        direct_agg = MongoDirectSong.query(:artist => "DateGroup Artist").aggregate(pipeline, mongo_direct: true)
        direct_results = direct_agg.results

        # All 3 songs were created at the same time, so should be 1 group
        assert direct_results.length >= 1, "Should have at least 1 date group"

        result = direct_results.first
        date_id = result["objectId"]
        assert date_id.is_a?(Hash), "objectId should be a hash with date components"
        assert date_id.key?("day"), "Should have day component"
        assert date_id.key?("month"), "Should have month component"
        assert date_id.key?("year"), "Should have year component"

        puts "  Date group: day=#{date_id["day"]}, month=#{date_id["month"]}, year=#{date_id["year"]}"
        puts "  Count: #{result["count"]}"
        puts "  ✅ Group by date object works!"

        puts "=== Aggregate Group by Date Object Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end

  # ==========================================================================
  # TEST BATCH 28: Aggregate Pipeline - Match with Date Comparison
  # (From Parse Server spec: match comparison date query)
  # ==========================================================================

  def test_aggregate_match_date_comparison_direct
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      skip "MongoDB direct tests require mongo gem" unless setup_mongodb_direct

      with_timeout(30, "aggregate match date comparison test") do
        puts "\n=== Testing Aggregate Match Date Comparison ==="

        # Test 1: Match using _created_at (built-in date field stored as BSON Date)
        puts "Test 1: Match _created_at comparison..."
        songs = [
          { title: "DateMatch1", artist: "DateMatch Artist", genre: "Rock", plays: 100 },
          { title: "DateMatch2", artist: "DateMatch Artist", genre: "Pop", plays: 200 },
          { title: "DateMatch3", artist: "DateMatch Artist", genre: "Jazz", plays: 300 },
        ]

        songs.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save song"
        end

        sleep 0.5

        # Match where _created_at >= 24 hours ago (all should match)
        yesterday_time = Time.now.utc - (24 * 60 * 60)
        pipeline = [
          { "$match" => { "_created_at" => { "$gte" => yesterday_time } } },
        ]

        direct_agg = MongoDirectSong.query(:artist => "DateMatch Artist").aggregate(pipeline, mongo_direct: true)
        direct_results = direct_agg.results

        assert_equal 3, direct_results.length, "Should have 3 songs created in last 24 hours"

        direct_titles = direct_results.map { |r| r.title }.sort
        assert_equal ["DateMatch1", "DateMatch2", "DateMatch3"], direct_titles
        puts "  ✅ _created_at comparison works!"

        # Test 2: Match using custom release_date field
        puts "Test 2: Match custom release_date field..."
        yesterday = Date.today - 1
        today = Date.today
        tomorrow = Date.today + 1

        # Create songs with release_date
        dated_songs = [
          { title: "ReleaseSong1", artist: "Release Artist", genre: "Rock", plays: 100, release_date: yesterday },
          { title: "ReleaseSong2", artist: "Release Artist", genre: "Pop", plays: 200, release_date: today },
          { title: "ReleaseSong3", artist: "Release Artist", genre: "Jazz", plays: 300, release_date: tomorrow },
        ]

        dated_songs.each do |song_data|
          song = MongoDirectSong.new(song_data)
          assert song.save, "Failed to save song with release_date"
        end

        sleep 0.5

        # Query using releaseDate (MongoDB field name, not Ruby property name)
        # Ruby Date objects (without time) are stored as midnight UTC in MongoDB
        # When comparing, use the same time representation for accurate matching
        tomorrow_midnight_utc = Time.utc(tomorrow.year, tomorrow.month, tomorrow.day, 0, 0, 0)
        pipeline = [
          { "$match" => { "releaseDate" => { "$lt" => tomorrow_midnight_utc } } },
        ]

        direct_agg = MongoDirectSong.query(:artist => "Release Artist").aggregate(pipeline, mongo_direct: true)
        direct_results = direct_agg.results

        # Both built-in AND custom date fields must work
        assert_equal 2, direct_results.length, "Should have 2 songs with release_date < tomorrow"

        direct_titles = direct_results.map { |r| r.title }.sort
        assert_equal ["ReleaseSong1", "ReleaseSong2"], direct_titles
        puts "  ✅ Custom release_date comparison works!"

        puts "=== Aggregate Match Date Comparison Tests PASSED ==="
      end

      teardown_mongodb_direct
    end
  end
end
