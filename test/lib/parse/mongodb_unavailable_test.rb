# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
require "parse/atlas_search"

# Tests for Parse::MongoDB and Parse::AtlasSearch behavior when
# the mongo gem is not installed or MongoDB is not properly configured.
class MongoDBUnavailableTest < Minitest::Test
  def setup
    Parse::MongoDB.reset!
    Parse::AtlasSearch.reset!
  end

  def teardown
    Parse::MongoDB.reset!
    Parse::AtlasSearch.reset!
  end

  # ==========================================================================
  # MONGO GEM NOT INSTALLED TESTS
  # ==========================================================================

  def test_gem_available_returns_false_when_gem_not_installed
    # Simulate gem not installed by stubbing the method
    Parse::MongoDB.stub(:gem_available?, false) do
      refute Parse::MongoDB.gem_available?
    end
  end

  def test_require_gem_raises_gem_not_available_when_not_installed
    Parse::MongoDB.stub(:gem_available?, false) do
      error = assert_raises(Parse::MongoDB::GemNotAvailable) do
        Parse::MongoDB.require_gem!
      end

      assert_match(/mongo.*gem.*required/i, error.message)
      assert_match(/Gemfile/i, error.message)
    end
  end

  def test_configure_raises_gem_not_available_when_gem_not_installed
    Parse::MongoDB.stub(:gem_available?, false) do
      error = assert_raises(Parse::MongoDB::GemNotAvailable) do
        Parse::MongoDB.configure(uri: "mongodb://localhost:27017/test")
      end

      assert_match(/mongo.*gem.*required/i, error.message)
    end
  end

  def test_client_raises_gem_not_available_when_gem_not_installed
    # First enable MongoDB without actually calling configure (to bypass gem check there)
    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, "mongodb://localhost:27017/test")

    Parse::MongoDB.stub(:gem_available?, false) do
      error = assert_raises(Parse::MongoDB::GemNotAvailable) do
        Parse::MongoDB.client
      end

      assert_match(/mongo.*gem.*required/i, error.message)
    end
  end

  def test_available_returns_false_when_gem_not_installed
    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, "mongodb://localhost:27017/test")

    Parse::MongoDB.stub(:gem_available?, false) do
      refute Parse::MongoDB.available?
    end
  end

  def test_results_direct_raises_gem_not_available_specifically
    Parse::MongoDB.stub(:gem_available?, false) do
      query = Parse::Query.new("TestClass")

      error = assert_raises(Parse::MongoDB::GemNotAvailable) do
        query.results_direct
      end

      assert_match(/mongo.*gem.*required/i, error.message)
    end
  end

  def test_first_direct_raises_gem_not_available_specifically
    Parse::MongoDB.stub(:gem_available?, false) do
      query = Parse::Query.new("TestClass")

      error = assert_raises(Parse::MongoDB::GemNotAvailable) do
        query.first_direct
      end

      assert_match(/mongo.*gem.*required/i, error.message)
    end
  end

  def test_count_direct_raises_gem_not_available_specifically
    Parse::MongoDB.stub(:gem_available?, false) do
      query = Parse::Query.new("TestClass")

      error = assert_raises(Parse::MongoDB::GemNotAvailable) do
        query.count_direct
      end

      assert_match(/mongo.*gem.*required/i, error.message)
    end
  end

  def test_distinct_direct_raises_gem_not_available_specifically
    Parse::MongoDB.stub(:gem_available?, false) do
      query = Parse::Query.new("TestClass")

      error = assert_raises(Parse::MongoDB::GemNotAvailable) do
        query.distinct_direct(:field)
      end

      assert_match(/mongo.*gem.*required/i, error.message)
    end
  end

  # ==========================================================================
  # MONGODB URI NOT PROVIDED TESTS
  # ==========================================================================

  def test_available_returns_false_when_uri_is_nil
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, nil)

    refute Parse::MongoDB.available?
  end

  def test_available_returns_false_when_uri_is_empty_string
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, "")

    refute Parse::MongoDB.available?
  end

  def test_available_returns_false_when_uri_is_blank
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, "   ")

    refute Parse::MongoDB.available?
  end

  def test_client_raises_not_enabled_when_uri_not_provided
    # Enable but don't set URI
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, nil)

    error = assert_raises(Parse::MongoDB::NotEnabled) do
      Parse::MongoDB.client
    end

    assert_match(/not enabled/i, error.message)
    assert_match(/configure/i, error.message)
  end

  def test_results_direct_raises_not_enabled_when_uri_not_provided
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, nil)

    query = Parse::Query.new("TestClass")

    error = assert_raises(Parse::MongoDB::NotEnabled) do
      query.results_direct
    end

    assert_match(/not enabled/i, error.message)
  end

  def test_first_direct_raises_not_enabled_when_uri_not_provided
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, nil)

    query = Parse::Query.new("TestClass")

    error = assert_raises(Parse::MongoDB::NotEnabled) do
      query.first_direct
    end

    assert_match(/not enabled/i, error.message)
  end

  # ==========================================================================
  # MONGODB ENABLED BUT NOT CONFIGURED TESTS
  # ==========================================================================

  def test_available_returns_false_when_not_enabled
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@enabled, false)
    Parse::MongoDB.instance_variable_set(:@uri, "mongodb://localhost:27017/test")

    refute Parse::MongoDB.available?
  end

  def test_available_requires_all_three_conditions
    # Test each combination
    combinations = [
      { gem: true, enabled: true, uri: "mongodb://localhost/test", expected: true },
      { gem: false, enabled: true, uri: "mongodb://localhost/test", expected: false },
      { gem: true, enabled: false, uri: "mongodb://localhost/test", expected: false },
      { gem: true, enabled: true, uri: nil, expected: false },
      { gem: true, enabled: true, uri: "", expected: false },
      { gem: false, enabled: false, uri: nil, expected: false },
    ]

    combinations.each do |combo|
      Parse::MongoDB.instance_variable_set(:@gem_available, combo[:gem])
      Parse::MongoDB.instance_variable_set(:@enabled, combo[:enabled])
      Parse::MongoDB.instance_variable_set(:@uri, combo[:uri])

      if combo[:expected]
        assert Parse::MongoDB.available?,
          "Expected available? to be true for gem=#{combo[:gem]}, enabled=#{combo[:enabled]}, uri=#{combo[:uri].inspect}"
      else
        refute Parse::MongoDB.available?,
          "Expected available? to be false for gem=#{combo[:gem]}, enabled=#{combo[:enabled]}, uri=#{combo[:uri].inspect}"
      end
    end
  end

  # ==========================================================================
  # ATLAS SEARCH WHEN MONGODB UNAVAILABLE TESTS
  # ==========================================================================

  def test_atlas_search_configure_raises_gem_not_available
    Parse::MongoDB.stub(:gem_available?, false) do
      error = assert_raises(Parse::MongoDB::GemNotAvailable) do
        Parse::AtlasSearch.configure(enabled: true)
      end

      assert_match(/mongo.*gem.*required/i, error.message)
    end
  end

  def test_atlas_search_not_available_when_mongodb_not_available
    Parse::MongoDB.stub(:available?, false) do
      Parse::AtlasSearch.instance_variable_set(:@enabled, true)
      refute Parse::AtlasSearch.available?
    end
  end

  def test_atlas_search_not_available_when_not_enabled
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, "mongodb://localhost:27017/test")

    Parse::AtlasSearch.instance_variable_set(:@enabled, false)

    refute Parse::AtlasSearch.available?
  end

  def test_atlas_search_search_raises_not_available_when_mongodb_unavailable
    # Gem is available, but MongoDB is not configured
    Parse::MongoDB.stub(:gem_available?, true) do
      Parse::MongoDB.stub(:available?, false) do
        Parse::AtlasSearch.instance_variable_set(:@enabled, true)

        error = assert_raises(Parse::AtlasSearch::NotAvailable) do
          Parse::AtlasSearch.search("Song", "love")
        end

        assert_match(/not available/i, error.message)
        assert_match(/MongoDB.*configured/i, error.message)
      end
    end
  end

  def test_atlas_search_autocomplete_raises_not_available_when_mongodb_unavailable
    # Gem is available, but MongoDB is not configured
    Parse::MongoDB.stub(:gem_available?, true) do
      Parse::MongoDB.stub(:available?, false) do
        Parse::AtlasSearch.instance_variable_set(:@enabled, true)

        error = assert_raises(Parse::AtlasSearch::NotAvailable) do
          Parse::AtlasSearch.autocomplete("Song", "lov", field: :title)
        end

        assert_match(/not available/i, error.message)
      end
    end
  end

  def test_atlas_search_faceted_search_raises_not_available_when_mongodb_unavailable
    # Gem is available, but MongoDB is not configured
    Parse::MongoDB.stub(:gem_available?, true) do
      Parse::MongoDB.stub(:available?, false) do
        Parse::AtlasSearch.instance_variable_set(:@enabled, true)

        facets = { genre: { type: :string, path: :genre } }

        error = assert_raises(Parse::AtlasSearch::NotAvailable) do
          Parse::AtlasSearch.faceted_search("Song", "rock", facets)
        end

        assert_match(/not available/i, error.message)
      end
    end
  end

  def test_atlas_search_search_raises_gem_not_available_when_gem_missing
    Parse::MongoDB.stub(:gem_available?, false) do
      Parse::AtlasSearch.instance_variable_set(:@enabled, true)

      error = assert_raises(Parse::MongoDB::GemNotAvailable) do
        Parse::AtlasSearch.search("Song", "love")
      end

      assert_match(/mongo.*gem.*required/i, error.message)
    end
  end

  # ==========================================================================
  # ERROR MESSAGE QUALITY TESTS
  # ==========================================================================

  def test_gem_not_available_error_includes_installation_instructions
    Parse::MongoDB.stub(:gem_available?, false) do
      error = assert_raises(Parse::MongoDB::GemNotAvailable) do
        Parse::MongoDB.require_gem!
      end

      # Should include helpful installation instructions
      assert_match(/gem.*mongo/i, error.message)
      assert_match(/Gemfile/i, error.message)
      assert_match(/bundle install/i, error.message)
    end
  end

  def test_not_enabled_error_includes_configuration_instructions
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@enabled, false)
    Parse::MongoDB.instance_variable_set(:@uri, nil)

    error = assert_raises(Parse::MongoDB::NotEnabled) do
      Parse::MongoDB.client
    end

    # Should mention how to configure
    assert_match(/configure/i, error.message)
  end

  def test_atlas_search_not_available_error_includes_both_requirements
    # Gem is available, but MongoDB is not configured
    Parse::MongoDB.stub(:gem_available?, true) do
      Parse::MongoDB.stub(:available?, false) do
        Parse::AtlasSearch.instance_variable_set(:@enabled, true)

        error = assert_raises(Parse::AtlasSearch::NotAvailable) do
          Parse::AtlasSearch.search("Song", "love")
        end

        # Should mention both MongoDB and AtlasSearch configuration
        assert_match(/MongoDB.*configured/i, error.message)
        assert_match(/AtlasSearch.*configure/i, error.message)
      end
    end
  end

  # ==========================================================================
  # RESET BEHAVIOR TESTS
  # ==========================================================================

  def test_reset_clears_all_mongodb_state
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, "mongodb://localhost:27017/test")
    Parse::MongoDB.instance_variable_set(:@database, "test")

    Parse::MongoDB.reset!

    refute Parse::MongoDB.enabled?
    assert_nil Parse::MongoDB.uri
    assert_nil Parse::MongoDB.database
    refute Parse::MongoDB.available?
  end

  def test_reset_clears_all_atlas_search_state
    Parse::AtlasSearch.instance_variable_set(:@enabled, true)
    Parse::AtlasSearch.instance_variable_set(:@default_index, "custom_index")

    Parse::AtlasSearch.reset!

    refute Parse::AtlasSearch.enabled?
    assert_equal "default", Parse::AtlasSearch.default_index
  end

  # ==========================================================================
  # AGGREGATE AND DIRECT QUERY METHOD TESTS
  # ==========================================================================

  def test_aggregate_with_mongo_direct_falls_back_to_parse_server_when_unavailable
    # When mongo_direct: true but MongoDB is not enabled, the Aggregation class
    # gracefully falls back to Parse Server. This is intentional degradation.
    # If Parse Server is also not configured, we get a Parse connection error.
    Parse::MongoDB.stub(:enabled?, false) do
      query = Parse::Query.new("Song")
      pipeline = [{ "$match" => { "genre" => "Rock" } }]

      # Falls back to Parse Server, which will fail if not configured
      error = assert_raises(Parse::Error::ConnectionError) do
        query.aggregate(pipeline, mongo_direct: true).results
      end

      assert_match(/setup/i, error.message)
    end
  end

  def test_aggregate_mongo_direct_checks_enabled_not_available
    # Verify that Aggregation checks enabled? for the mongo_direct path
    # This ensures graceful fallback when MongoDB connection fails but is configured
    Parse::MongoDB.instance_variable_set(:@enabled, false)

    query = Parse::Query.new("Song")
    aggregation = query.aggregate([{ "$match" => {} }], mongo_direct: true)

    # The mongo_direct flag is stored but execution checks enabled?
    assert aggregation.instance_variable_get(:@mongo_direct)
  end

  def test_results_with_mongo_direct_true_raises_when_unavailable
    Parse::MongoDB.stub(:available?, false) do
      query = Parse::Query.new("Song")

      error = assert_raises(Parse::MongoDB::NotEnabled) do
        query.results(mongo_direct: true)
      end

      assert_match(/not enabled/i, error.message)
    end
  end

  def test_first_with_mongo_direct_true_raises_when_unavailable
    Parse::MongoDB.stub(:available?, false) do
      query = Parse::Query.new("Song")

      error = assert_raises(Parse::MongoDB::NotEnabled) do
        query.first(mongo_direct: true)
      end

      assert_match(/not enabled/i, error.message)
    end
  end

  def test_count_with_mongo_direct_true_raises_when_unavailable
    Parse::MongoDB.stub(:available?, false) do
      query = Parse::Query.new("Song")

      error = assert_raises(Parse::MongoDB::NotEnabled) do
        query.count(mongo_direct: true)
      end

      assert_match(/not enabled/i, error.message)
    end
  end
end
