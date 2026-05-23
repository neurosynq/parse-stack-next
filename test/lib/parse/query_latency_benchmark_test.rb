# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"

# Benchmark model for latency tests
class BenchmarkSong < Parse::Object
  parse_class "BenchmarkSong"
  property :title, :string
  property :plays, :integer
  property :genre, :string
  property :tags, :array
  property :release_date, :date
  belongs_to :artist, as: :pointer, through: :BenchmarkArtist
end

class BenchmarkArtist < Parse::Object
  parse_class "BenchmarkArtist"
  property :name, :string
  property :verified, :boolean
end

# Latency benchmark tests comparing Parse Server vs MongoDB Direct queries
class QueryLatencyBenchmarkTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds = 120, &block)
    Timeout.timeout(seconds, &block)
  end

  # Helper to measure execution time
  def measure_ms
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    [(elapsed * 1000).round(2), result]
  end

  # Helper to run multiple iterations and calculate stats
  def benchmark(iterations: 5, warmup: 1, &block)
    # Warmup runs (not counted)
    warmup.times { yield }

    # Measured runs
    times = iterations.times.map { measure_ms { yield }.first }

    {
      min: times.min.round(2),
      max: times.max.round(2),
      avg: (times.sum / times.length).round(2),
      median: times.sort[times.length / 2].round(2),
      times: times,
    }
  end

  # ==========================================================================
  # Test: Simple Query Latency Comparison
  # ==========================================================================

  def test_simple_query_latency_comparison
    with_parse_server do
      with_timeout(180) do
        puts "\n" + "=" * 70
        puts "BENCHMARK: Simple Query Latency Comparison"
        puts "=" * 70

        # Create test data
        puts "\nSeeding test data..."
        artists = 5.times.map do |i|
          a = BenchmarkArtist.new(name: "Artist #{i}", verified: i.even?)
          a.save!
          a
        end

        100.times do |i|
          s = BenchmarkSong.new(
            title: "Song #{i}",
            plays: rand(100..10000),
            genre: ["Rock", "Pop", "Jazz", "Classical", "Electronic"].sample,
            tags: ["tag1", "tag2", "tag3"].sample(rand(1..3)),
            release_date: Time.now - rand(0..365 * 5) * 24 * 60 * 60,
            artist: artists.sample,
          )
          s.save!
        end
        puts "Created 5 artists and 100 songs"

        # Configure MongoDB direct
        require "mongo"
        require_relative "../../../lib/parse/mongodb"
        Parse::MongoDB.configure(uri: "mongodb://admin:password@localhost:27019/parse?authSource=admin", enabled: true)

        puts "\n" + "-" * 70
        puts "Test 1: Simple equality query (genre = 'Rock')"
        puts "-" * 70

        # Parse Server (standard)
        parse_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(genre: "Rock").all
        end
        parse_count = BenchmarkSong.query(genre: "Rock").count

        # MongoDB Direct
        direct_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(genre: "Rock").results_direct
        end
        direct_count = BenchmarkSong.query(genre: "Rock").count_direct

        puts "Results: #{parse_count} songs (Parse), #{direct_count} songs (Direct)"
        puts "\nParse Server:   avg=#{parse_stats[:avg]}ms, min=#{parse_stats[:min]}ms, max=#{parse_stats[:max]}ms"
        puts "MongoDB Direct: avg=#{direct_stats[:avg]}ms, min=#{direct_stats[:min]}ms, max=#{direct_stats[:max]}ms"
        speedup = (parse_stats[:avg] / direct_stats[:avg]).round(2)
        puts "Speedup: #{speedup}x #{speedup > 1 ? "(Direct faster)" : "(Parse faster)"}"

        assert_equal parse_count, direct_count, "Result counts should match"

        puts "\n" + "-" * 70
        puts "Test 2: Range query (plays > 5000)"
        puts "-" * 70

        parse_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:plays.gt => 5000).all
        end
        parse_count = BenchmarkSong.query(:plays.gt => 5000).count

        direct_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:plays.gt => 5000).results_direct
        end
        direct_count = BenchmarkSong.query(:plays.gt => 5000).count_direct

        puts "Results: #{parse_count} songs (Parse), #{direct_count} songs (Direct)"
        puts "\nParse Server:   avg=#{parse_stats[:avg]}ms, min=#{parse_stats[:min]}ms, max=#{parse_stats[:max]}ms"
        puts "MongoDB Direct: avg=#{direct_stats[:avg]}ms, min=#{direct_stats[:min]}ms, max=#{direct_stats[:max]}ms"
        speedup = (parse_stats[:avg] / direct_stats[:avg]).round(2)
        puts "Speedup: #{speedup}x #{speedup > 1 ? "(Direct faster)" : "(Parse faster)"}"

        assert_equal parse_count, direct_count, "Result counts should match"

        puts "\n" + "-" * 70
        puts "Test 3: Date range query (last 180 days)"
        puts "-" * 70

        cutoff = Time.now - 180 * 24 * 60 * 60

        parse_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:release_date.gt => cutoff).all
        end
        parse_count = BenchmarkSong.query(:release_date.gt => cutoff).count

        direct_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:release_date.gt => cutoff).results_direct
        end
        direct_count = BenchmarkSong.query(:release_date.gt => cutoff).count_direct

        puts "Results: #{parse_count} songs (Parse), #{direct_count} songs (Direct)"
        puts "\nParse Server:   avg=#{parse_stats[:avg]}ms, min=#{parse_stats[:min]}ms, max=#{parse_stats[:max]}ms"
        puts "MongoDB Direct: avg=#{direct_stats[:avg]}ms, min=#{direct_stats[:min]}ms, max=#{direct_stats[:max]}ms"
        speedup = (parse_stats[:avg] / direct_stats[:avg]).round(2)
        puts "Speedup: #{speedup}x #{speedup > 1 ? "(Direct faster)" : "(Parse faster)"}"

        assert_equal parse_count, direct_count, "Result counts should match"

        puts "\n✅ Simple query latency comparison complete!"
      end
    end
  end

  # ==========================================================================
  # Test: Aggregation Query Latency Comparison
  # ==========================================================================

  def test_aggregation_query_latency_comparison
    with_parse_server do
      with_timeout(180) do
        puts "\n" + "=" * 70
        puts "BENCHMARK: Aggregation Query Latency Comparison"
        puts "=" * 70

        # Create test data
        puts "\nSeeding test data..."
        artists = 10.times.map do |i|
          a = BenchmarkArtist.new(name: "Artist #{i}", verified: i < 5)
          a.save!
          a
        end

        150.times do |i|
          s = BenchmarkSong.new(
            title: "Song #{i}",
            plays: rand(100..10000),
            genre: ["Rock", "Pop", "Jazz"].sample,
            tags: i < 100 ? ["featured", "popular"].sample(rand(1..2)) : [],
            artist: artists.sample,
          )
          s.save!
        end
        puts "Created 10 artists and 150 songs"

        # Configure MongoDB direct
        require "mongo"
        require_relative "../../../lib/parse/mongodb"
        Parse::MongoDB.configure(uri: "mongodb://admin:password@localhost:27019/parse?authSource=admin", enabled: true)

        puts "\n" + "-" * 70
        puts "Test 1: empty_or_nil (songs with no tags)"
        puts "-" * 70

        # Parse Server with empty_or_nil (uses aggregation)
        parse_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:tags.empty_or_nil => true).all
        end
        parse_count = BenchmarkSong.query(:tags.empty_or_nil => true).count

        # MongoDB Direct with empty_or_nil
        direct_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:tags.empty_or_nil => true).results_direct
        end
        direct_count = BenchmarkSong.query(:tags.empty_or_nil => true).count_direct

        puts "Results: #{parse_count} songs (Parse), #{direct_count} songs (Direct)"
        puts "\nParse Server:   avg=#{parse_stats[:avg]}ms, min=#{parse_stats[:min]}ms, max=#{parse_stats[:max]}ms"
        puts "MongoDB Direct: avg=#{direct_stats[:avg]}ms, min=#{direct_stats[:min]}ms, max=#{direct_stats[:max]}ms"
        speedup = (parse_stats[:avg] / direct_stats[:avg]).round(2)
        puts "Speedup: #{speedup}x #{speedup > 1 ? "(Direct faster)" : "(Parse faster)"}"

        assert_equal parse_count, direct_count, "Result counts should match"

        puts "\n" + "-" * 70
        puts "Test 2: not_empty (songs with tags)"
        puts "-" * 70

        # Parse Server with not_empty
        parse_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:tags.not_empty => true).all
        end
        parse_count = BenchmarkSong.query(:tags.not_empty => true).count

        # MongoDB Direct with not_empty
        direct_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:tags.not_empty => true).results_direct
        end
        direct_count = BenchmarkSong.query(:tags.not_empty => true).count_direct

        puts "Results: #{parse_count} songs (Parse), #{direct_count} songs (Direct)"
        puts "\nParse Server:   avg=#{parse_stats[:avg]}ms, min=#{parse_stats[:min]}ms, max=#{parse_stats[:max]}ms"
        puts "MongoDB Direct: avg=#{direct_stats[:avg]}ms, min=#{direct_stats[:min]}ms, max=#{direct_stats[:max]}ms"
        speedup = (parse_stats[:avg] / direct_stats[:avg]).round(2)
        puts "Speedup: #{speedup}x #{speedup > 1 ? "(Direct faster)" : "(Parse faster)"}"

        assert_equal parse_count, direct_count, "Result counts should match"

        puts "\n" + "-" * 70
        puts "Test 3: Combined empty_or_nil + range"
        puts "-" * 70

        # Parse Server with combined aggregation + range
        parse_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:tags.empty_or_nil => false, :plays.gt => 3000).all
        end
        parse_count = BenchmarkSong.query(:tags.empty_or_nil => false, :plays.gt => 3000).count

        # MongoDB Direct with combined aggregation + range
        direct_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:tags.empty_or_nil => false, :plays.gt => 3000).results_direct
        end
        direct_count = BenchmarkSong.query(:tags.empty_or_nil => false, :plays.gt => 3000).count_direct

        puts "Results: #{parse_count} songs (Parse), #{direct_count} songs (Direct)"
        puts "\nParse Server:   avg=#{parse_stats[:avg]}ms, min=#{parse_stats[:min]}ms, max=#{parse_stats[:max]}ms"
        puts "MongoDB Direct: avg=#{direct_stats[:avg]}ms, min=#{direct_stats[:min]}ms, max=#{direct_stats[:max]}ms"
        speedup = (parse_stats[:avg] / direct_stats[:avg]).round(2)
        puts "Speedup: #{speedup}x #{speedup > 1 ? "(Direct faster)" : "(Parse faster)"}"

        assert_equal parse_count, direct_count, "Result counts should match"

        puts "\n✅ Aggregation query latency comparison complete!"
      end
    end
  end

  # ==========================================================================
  # Test: Include/Eager Loading Latency Comparison
  # ==========================================================================

  def test_include_latency_comparison
    with_parse_server do
      with_timeout(180) do
        puts "\n" + "=" * 70
        puts "BENCHMARK: Include/Eager Loading Latency Comparison"
        puts "=" * 70

        # Create test data
        puts "\nSeeding test data..."
        artists = 20.times.map do |i|
          a = BenchmarkArtist.new(name: "Artist #{i}", verified: i.even?)
          a.save!
          a
        end

        100.times do |i|
          s = BenchmarkSong.new(
            title: "Song #{i}",
            plays: rand(100..10000),
            genre: ["Rock", "Pop", "Jazz"].sample,
            artist: artists.sample,
          )
          s.save!
        end
        puts "Created 20 artists and 100 songs"

        # Configure MongoDB direct
        require "mongo"
        require_relative "../../../lib/parse/mongodb"
        Parse::MongoDB.configure(uri: "mongodb://admin:password@localhost:27019/parse?authSource=admin", enabled: true)

        puts "\n" + "-" * 70
        puts "Test 1: Query WITHOUT includes"
        puts "-" * 70

        parse_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:plays.gt => 5000).limit(20).all
        end

        direct_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:plays.gt => 5000).limit(20).results_direct
        end

        puts "Parse Server:   avg=#{parse_stats[:avg]}ms, min=#{parse_stats[:min]}ms, max=#{parse_stats[:max]}ms"
        puts "MongoDB Direct: avg=#{direct_stats[:avg]}ms, min=#{direct_stats[:min]}ms, max=#{direct_stats[:max]}ms"
        speedup = (parse_stats[:avg] / direct_stats[:avg]).round(2)
        puts "Speedup: #{speedup}x #{speedup > 1 ? "(Direct faster)" : "(Parse faster)"}"

        puts "\n" + "-" * 70
        puts "Test 2: Query WITH includes (eager loading artist)"
        puts "-" * 70

        # Parse Server with includes
        parse_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:plays.gt => 5000).includes(:artist).limit(20).all
        end

        # MongoDB Direct with includes (uses $lookup)
        direct_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:plays.gt => 5000).includes(:artist).limit(20).results_direct
        end

        puts "Parse Server:   avg=#{parse_stats[:avg]}ms, min=#{parse_stats[:min]}ms, max=#{parse_stats[:max]}ms"
        puts "MongoDB Direct: avg=#{direct_stats[:avg]}ms, min=#{direct_stats[:min]}ms, max=#{direct_stats[:max]}ms"
        speedup = (parse_stats[:avg] / direct_stats[:avg]).round(2)
        puts "Speedup: #{speedup}x #{speedup > 1 ? "(Direct faster)" : "(Parse faster)"}"

        # Verify includes work correctly
        parse_songs = BenchmarkSong.query(:plays.gt => 5000).includes(:artist).limit(5).all
        direct_songs = BenchmarkSong.query(:plays.gt => 5000).includes(:artist).limit(5).results_direct

        puts "\nVerifying include data integrity..."
        parse_artists = parse_songs.map { |s| s.artist&.name }.compact.sort
        direct_artists = direct_songs.map { |s| s.artist&.name }.compact.sort
        puts "Parse artists:  #{parse_artists.first(3).inspect}..."
        puts "Direct artists: #{direct_artists.first(3).inspect}..."

        puts "\n" + "-" * 70
        puts "Test 3: N+1 Query Pattern (accessing artist without includes)"
        puts "-" * 70

        puts "This demonstrates why includes/eager loading matters:"

        # Without includes - causes N+1 queries
        no_include_stats = measure_ms do
          songs = BenchmarkSong.query(:plays.gt => 5000).limit(10).all
          songs.each { |s| s.artist.fetch if s.artist } # Force fetch each artist
        end

        # With includes - single query with $lookup
        with_include_stats = measure_ms do
          songs = BenchmarkSong.query(:plays.gt => 5000).includes(:artist).limit(10).results_direct
          songs.each { |s| s.artist&.name } # Already loaded
        end

        puts "Without includes (N+1): #{no_include_stats.first}ms"
        puts "With includes (Direct): #{with_include_stats.first}ms"
        speedup = (no_include_stats.first / with_include_stats.first).round(2)
        puts "Speedup: #{speedup}x"

        puts "\n✅ Include/eager loading latency comparison complete!"
      end
    end
  end

  # ==========================================================================
  # Test: Count Query Latency Comparison
  # ==========================================================================

  def test_count_latency_comparison
    with_parse_server do
      with_timeout(180) do
        puts "\n" + "=" * 70
        puts "BENCHMARK: Count Query Latency Comparison"
        puts "=" * 70

        # Create test data
        puts "\nSeeding test data..."
        200.times do |i|
          s = BenchmarkSong.new(
            title: "Song #{i}",
            plays: rand(100..10000),
            genre: ["Rock", "Pop", "Jazz", "Classical", "Electronic"].sample,
          )
          s.save!
        end
        puts "Created 200 songs"

        # Configure MongoDB direct
        require "mongo"
        require_relative "../../../lib/parse/mongodb"
        Parse::MongoDB.configure(uri: "mongodb://admin:password@localhost:27019/parse?authSource=admin", enabled: true)

        puts "\n" + "-" * 70
        puts "Test 1: Simple count"
        puts "-" * 70

        parse_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(genre: "Rock").count
        end
        parse_count = BenchmarkSong.query(genre: "Rock").count

        direct_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(genre: "Rock").count_direct
        end
        direct_count = BenchmarkSong.query(genre: "Rock").count_direct

        puts "Results: #{parse_count} (Parse), #{direct_count} (Direct)"
        puts "\nParse Server:   avg=#{parse_stats[:avg]}ms, min=#{parse_stats[:min]}ms, max=#{parse_stats[:max]}ms"
        puts "MongoDB Direct: avg=#{direct_stats[:avg]}ms, min=#{direct_stats[:min]}ms, max=#{direct_stats[:max]}ms"
        speedup = (parse_stats[:avg] / direct_stats[:avg]).round(2)
        puts "Speedup: #{speedup}x #{speedup > 1 ? "(Direct faster)" : "(Parse faster)"}"

        assert_equal parse_count, direct_count

        puts "\n" + "-" * 70
        puts "Test 2: Count with range constraint"
        puts "-" * 70

        parse_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:plays.gt => 5000).count
        end
        parse_count = BenchmarkSong.query(:plays.gt => 5000).count

        direct_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query(:plays.gt => 5000).count_direct
        end
        direct_count = BenchmarkSong.query(:plays.gt => 5000).count_direct

        puts "Results: #{parse_count} (Parse), #{direct_count} (Direct)"
        puts "\nParse Server:   avg=#{parse_stats[:avg]}ms, min=#{parse_stats[:min]}ms, max=#{parse_stats[:max]}ms"
        puts "MongoDB Direct: avg=#{direct_stats[:avg]}ms, min=#{direct_stats[:min]}ms, max=#{direct_stats[:max]}ms"
        speedup = (parse_stats[:avg] / direct_stats[:avg]).round(2)
        puts "Speedup: #{speedup}x #{speedup > 1 ? "(Direct faster)" : "(Parse faster)"}"

        assert_equal parse_count, direct_count

        puts "\n" + "-" * 70
        puts "Test 3: Total count (all records)"
        puts "-" * 70

        parse_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query.count
        end
        parse_count = BenchmarkSong.query.count

        direct_stats = benchmark(iterations: 10, warmup: 2) do
          BenchmarkSong.query.count_direct
        end
        direct_count = BenchmarkSong.query.count_direct

        puts "Results: #{parse_count} (Parse), #{direct_count} (Direct)"
        puts "\nParse Server:   avg=#{parse_stats[:avg]}ms, min=#{parse_stats[:min]}ms, max=#{parse_stats[:max]}ms"
        puts "MongoDB Direct: avg=#{direct_stats[:avg]}ms, min=#{direct_stats[:min]}ms, max=#{direct_stats[:max]}ms"
        speedup = (parse_stats[:avg] / direct_stats[:avg]).round(2)
        puts "Speedup: #{speedup}x #{speedup > 1 ? "(Direct faster)" : "(Parse faster)"}"

        assert_equal parse_count, direct_count

        puts "\n✅ Count query latency comparison complete!"
      end
    end
  end

  # ==========================================================================
  # Test: Summary Benchmark (all patterns)
  # ==========================================================================

  def test_latency_summary
    with_parse_server do
      with_timeout(300) do
        puts "\n" + "=" * 70
        puts "BENCHMARK SUMMARY: Parse Server vs MongoDB Direct"
        puts "=" * 70

        # Create test data
        puts "\nSeeding test data (200 songs, 20 artists)..."
        artists = 20.times.map do |i|
          a = BenchmarkArtist.new(name: "Artist #{i}", verified: i < 10)
          a.save!
          a
        end

        200.times do |i|
          s = BenchmarkSong.new(
            title: "Song #{i}",
            plays: rand(100..10000),
            genre: ["Rock", "Pop", "Jazz", "Classical"].sample,
            tags: i < 150 ? ["tag1", "tag2"].sample(rand(1..2)) : [],
            release_date: Time.now - rand(0..365) * 24 * 60 * 60,
            artist: artists.sample,
          )
          s.save!
        end

        # Configure MongoDB direct
        require "mongo"
        require_relative "../../../lib/parse/mongodb"
        Parse::MongoDB.configure(uri: "mongodb://admin:password@localhost:27019/parse?authSource=admin", enabled: true)

        results = []

        # Test patterns
        patterns = [
          { name: "Simple equality", query: -> { BenchmarkSong.query(genre: "Rock") } },
          { name: "Range query", query: -> { BenchmarkSong.query(:plays.gt => 5000) } },
          { name: "Date range", query: -> { BenchmarkSong.query(:release_date.gt => Time.now - 180 * 24 * 60 * 60) } },
          { name: "With limit", query: -> { BenchmarkSong.query(:plays.gt => 1000).limit(20) } },
          { name: "With order", query: -> { BenchmarkSong.query(:plays.gt => 1000).order(:plays.desc).limit(20) } },
          { name: "empty_or_nil", query: -> { BenchmarkSong.query(:tags.empty_or_nil => true) } },
          { name: "With includes", query: -> { BenchmarkSong.query(:plays.gt => 5000).includes(:artist).limit(20) } },
          { name: "Count query", query: -> { BenchmarkSong.query(:plays.gt => 3000) }, count_only: true },
        ]

        puts "\nRunning benchmarks (10 iterations each, 2 warmup)...\n"
        puts "-" * 70
        puts "| %-20s | %12s | %12s | %8s |" % ["Pattern", "Parse (ms)", "Direct (ms)", "Speedup"]
        puts "-" * 70

        patterns.each do |pattern|
          query_builder = pattern[:query]

          if pattern[:count_only]
            parse_stats = benchmark(iterations: 10, warmup: 2) do
              query_builder.call.count
            end

            direct_stats = benchmark(iterations: 10, warmup: 2) do
              query_builder.call.count_direct
            end
          else
            parse_stats = benchmark(iterations: 10, warmup: 2) do
              query_builder.call.all
            end

            direct_stats = benchmark(iterations: 10, warmup: 2) do
              query_builder.call.results_direct
            end
          end

          speedup = (parse_stats[:avg] / direct_stats[:avg]).round(2)
          results << {
            name: pattern[:name],
            parse: parse_stats[:avg],
            direct: direct_stats[:avg],
            speedup: speedup,
          }

          puts "| %-20s | %12.2f | %12.2f | %7.2fx |" % [
            pattern[:name],
            parse_stats[:avg],
            direct_stats[:avg],
            speedup,
          ]
        end

        puts "-" * 70

        # Calculate averages
        avg_parse = (results.map { |r| r[:parse] }.sum / results.length).round(2)
        avg_direct = (results.map { |r| r[:direct] }.sum / results.length).round(2)
        avg_speedup = (results.map { |r| r[:speedup] }.sum / results.length).round(2)

        puts "| %-20s | %12.2f | %12.2f | %7.2fx |" % ["AVERAGE", avg_parse, avg_direct, avg_speedup]
        puts "-" * 70

        puts "\n✅ Benchmark summary complete!"
        puts "\nNote: Results vary based on network latency, data size, and server load."
        puts "MongoDB Direct bypasses Parse Server's REST API for lower latency."
      end
    end
  end
end
