# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

class MongoDBDirectQueryTest < Minitest::Test
  # Tests for the Parse::MongoDB module and direct query functionality

  def setup
    # Reset MongoDB configuration before each test
    Parse::MongoDB.reset! if defined?(Parse::MongoDB) && Parse::MongoDB.respond_to?(:reset!)
  end

  def teardown
    # Clean up after tests
    Parse::MongoDB.reset! if defined?(Parse::MongoDB) && Parse::MongoDB.respond_to?(:reset!)
  end

  # ==========================================================================
  # Parse::MongoDB Module Tests
  # ==========================================================================

  def test_mongodb_module_exists
    require "parse/mongodb"
    assert defined?(Parse::MongoDB), "Parse::MongoDB module should be defined"
  end

  def test_mongodb_gem_not_available_error_class
    require "parse/mongodb"
    assert defined?(Parse::MongoDB::GemNotAvailable), "GemNotAvailable error class should be defined"
  end

  def test_mongodb_not_enabled_error_class
    require "parse/mongodb"
    assert defined?(Parse::MongoDB::NotEnabled), "NotEnabled error class should be defined"
  end

  def test_mongodb_connection_error_class
    require "parse/mongodb"
    assert defined?(Parse::MongoDB::ConnectionError), "ConnectionError class should be defined"
  end

  def test_mongodb_disabled_by_default
    require "parse/mongodb"
    refute Parse::MongoDB.enabled?, "MongoDB should be disabled by default"
  end

  def test_mongodb_not_available_when_not_configured
    require "parse/mongodb"
    refute Parse::MongoDB.available?, "MongoDB should not be available when not configured"
  end

  # ==========================================================================
  # Document Conversion Tests (without mongo gem)
  # ==========================================================================

  def test_convert_document_basic_fields
    require "parse/mongodb"

    # Mock BSON::ObjectId if mongo gem is not available
    mock_bson_object_id unless defined?(BSON::ObjectId)

    doc = {
      "_id" => "abc123",
      "title" => "Test Song",
      "plays" => 100,
    }

    result = Parse::MongoDB.convert_document_to_parse(doc, "Song")

    assert_equal "abc123", result["objectId"]
    assert_equal "Test Song", result["title"]
    assert_equal 100, result["plays"]
    assert_equal "Song", result["className"]
  end

  def test_convert_document_date_fields
    require "parse/mongodb"

    created_at = Time.utc(2024, 1, 15, 10, 30, 0)
    updated_at = Time.utc(2024, 1, 16, 12, 0, 0)

    doc = {
      "_id" => "abc123",
      "_created_at" => created_at,
      "_updated_at" => updated_at,
      "title" => "Test",
    }

    result = Parse::MongoDB.convert_document_to_parse(doc)

    assert_equal "Date", result["createdAt"]["__type"]
    assert_equal created_at.utc.iso8601(3), result["createdAt"]["iso"]
    assert_equal "Date", result["updatedAt"]["__type"]
    assert_equal updated_at.utc.iso8601(3), result["updatedAt"]["iso"]
  end

  def test_convert_document_pointer_fields
    require "parse/mongodb"

    doc = {
      "_id" => "song123",
      "_p_artist" => "Artist$artist456",
      "_p_album" => "Album$album789",
      "title" => "Great Song",
    }

    result = Parse::MongoDB.convert_document_to_parse(doc)

    assert_equal "Pointer", result["artist"]["__type"]
    assert_equal "Artist", result["artist"]["className"]
    assert_equal "artist456", result["artist"]["objectId"]

    assert_equal "Pointer", result["album"]["__type"]
    assert_equal "Album", result["album"]["className"]
    assert_equal "album789", result["album"]["objectId"]
  end

  def test_convert_document_skips_internal_fields
    require "parse/mongodb"

    doc = {
      "_id" => "abc123",
      "_rperm" => ["*"],
      "_wperm" => ["role:Admin"],
      "_acl" => { "*" => { "r" => true } },
      "_hashed_password" => "secret_hash",
      "_session_token" => "r:abc123",
      "title" => "Test",
    }

    result = Parse::MongoDB.convert_document_to_parse(doc)

    assert_equal "abc123", result["objectId"]
    assert_equal "Test", result["title"]
    refute result.key?("_rperm")
    refute result.key?("_wperm")
    refute result.key?("_acl")
    refute result.key?("_hashed_password")
    refute result.key?("_session_token")
  end

  def test_convert_document_handles_nil
    require "parse/mongodb"
    assert_nil Parse::MongoDB.convert_document_to_parse(nil)
  end

  def test_convert_document_handles_non_hash
    require "parse/mongodb"
    assert_nil Parse::MongoDB.convert_document_to_parse("not a hash")
    assert_nil Parse::MongoDB.convert_document_to_parse(123)
  end

  def test_convert_multiple_documents
    require "parse/mongodb"

    docs = [
      { "_id" => "1", "title" => "Song 1" },
      { "_id" => "2", "title" => "Song 2" },
      { "_id" => "3", "title" => "Song 3" },
    ]

    results = Parse::MongoDB.convert_documents_to_parse(docs, "Song")

    assert_equal 3, results.length
    assert_equal "1", results[0]["objectId"]
    assert_equal "Song 1", results[0]["title"]
    assert_equal "Song", results[0]["className"]
  end

  # ==========================================================================
  # Query Direct Method Tests (without mongo gem)
  # ==========================================================================

  def test_results_direct_raises_without_mongo_gem
    # This test verifies the error is raised when mongo gem is not available
    # and MongoDB is not configured
    require "parse/mongodb"

    # Create a simple query
    query = Parse::Query.new("TestClass")

    # Should raise GemNotAvailable or NotEnabled
    assert_raises(Parse::MongoDB::GemNotAvailable, Parse::MongoDB::NotEnabled) do
      query.results_direct
    end
  end

  def test_first_direct_raises_without_mongo_gem
    require "parse/mongodb"

    query = Parse::Query.new("TestClass")

    assert_raises(Parse::MongoDB::GemNotAvailable, Parse::MongoDB::NotEnabled) do
      query.first_direct
    end
  end

  # ==========================================================================
  # Pipeline Building Tests
  # ==========================================================================

  def test_build_direct_mongodb_pipeline_basic
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    query.where(:plays.gt => 100)

    pipeline = query.send(:build_direct_mongodb_pipeline)

    assert pipeline.is_a?(Array)
    assert pipeline.length >= 1, "Pipeline should have at least a $match stage"
  end

  def test_build_direct_mongodb_pipeline_with_limit
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    query.limit(10)

    pipeline = query.send(:build_direct_mongodb_pipeline)

    limit_stage = pipeline.find { |s| s.key?("$limit") }
    assert limit_stage, "Pipeline should have a $limit stage"
    assert_equal 10, limit_stage["$limit"]
  end

  def test_build_direct_mongodb_pipeline_with_skip
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    query.skip(20)

    pipeline = query.send(:build_direct_mongodb_pipeline)

    skip_stage = pipeline.find { |s| s.key?("$skip") }
    assert skip_stage, "Pipeline should have a $skip stage"
    assert_equal 20, skip_stage["$skip"]
  end

  def test_build_direct_mongodb_pipeline_with_order
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    query.order(:plays.desc)

    pipeline = query.send(:build_direct_mongodb_pipeline)

    sort_stage = pipeline.find { |s| s.key?("$sort") }
    assert sort_stage, "Pipeline should have a $sort stage"
    assert_equal(-1, sort_stage["$sort"]["plays"])
  end

  # ==========================================================================
  # Field Conversion Tests
  # ==========================================================================

  def test_convert_field_objectId_to_id
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    result = query.send(:convert_field_for_direct_mongodb, "objectId")
    assert_equal "_id", result
  end

  def test_convert_field_createdAt_to_created_at
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    result = query.send(:convert_field_for_direct_mongodb, "createdAt")
    assert_equal "_created_at", result
  end

  def test_convert_field_updatedAt_to_updated_at
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    result = query.send(:convert_field_for_direct_mongodb, "updatedAt")
    assert_equal "_updated_at", result
  end

  def test_convert_field_regular_field_unchanged
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    result = query.send(:convert_field_for_direct_mongodb, "title")
    assert_equal "title", result
  end

  # ==========================================================================
  # Value Conversion Tests
  # ==========================================================================

  def test_convert_value_parse_pointer
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    pointer = { "__type" => "Pointer", "className" => "Artist", "objectId" => "abc123" }

    result = query.send(:convert_value_for_direct_mongodb, "artist", pointer)
    assert_equal "Artist$abc123", result
  end

  def test_convert_value_parse_date
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    date = { "__type" => "Date", "iso" => "2024-01-15T10:30:00.000Z" }

    result = query.send(:convert_value_for_direct_mongodb, "releaseDate", date)
    # Date should be converted to Time object for BSON Date type
    assert_instance_of Time, result
    assert_equal Time.parse("2024-01-15T10:30:00.000Z").utc, result
  end

  def test_convert_value_parse_date_with_symbol_keys
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    # Symbol keys (as produced by constraint as_json with indifferent access)
    date = { :__type => "Date", :iso => "2024-01-15T10:30:00.000Z" }

    result = query.send(:convert_value_for_direct_mongodb, "releaseDate", date)
    # Date should be converted to Time object for BSON Date type
    assert_instance_of Time, result
    assert_equal Time.parse("2024-01-15T10:30:00.000Z").utc, result
  end

  def test_convert_value_nested_operators_with_symbol_keys
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    # Symbol keys (as produced by constraint as_json)
    value = { :$gt => { :__type => "Date", :iso => "2024-01-01T00:00:00.000Z" } }

    result = query.send(:convert_value_for_direct_mongodb, "releaseDate", value)
    # Keys should be converted to strings
    assert_equal ["$gt"], result.keys
    # Date value should be converted to Time object
    assert_instance_of Time, result["$gt"]
  end

  def test_convert_value_nested_operators
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    value = { "$gt" => 100, "$lt" => 500 }

    result = query.send(:convert_value_for_direct_mongodb, "plays", value)
    assert_equal 100, result["$gt"]
    assert_equal 500, result["$lt"]
  end

  def test_convert_value_array_of_pointers
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    pointers = [
      { "__type" => "Pointer", "className" => "Artist", "objectId" => "a1" },
      { "__type" => "Pointer", "className" => "Artist", "objectId" => "a2" },
    ]

    result = query.send(:convert_value_for_direct_mongodb, "artists", pointers)
    assert_equal ["Artist$a1", "Artist$a2"], result
  end

  # ==========================================================================
  # mongo_direct: true Parameter Tests
  # ==========================================================================

  def test_results_accepts_mongo_direct_parameter
    require "parse/mongodb"

    query = Parse::Query.new("Song")

    # Test that the method signature accepts mongo_direct parameter
    # Should raise because MongoDB is not configured, not because of invalid parameter
    assert_raises(Parse::MongoDB::GemNotAvailable, Parse::MongoDB::NotEnabled) do
      query.results(mongo_direct: true)
    end
  end

  def test_first_accepts_mongo_direct_parameter
    require "parse/mongodb"

    query = Parse::Query.new("Song")

    # Test that the method signature accepts mongo_direct parameter
    assert_raises(Parse::MongoDB::GemNotAvailable, Parse::MongoDB::NotEnabled) do
      query.first(mongo_direct: true)
    end
  end

  def test_first_with_limit_accepts_mongo_direct_parameter
    require "parse/mongodb"

    query = Parse::Query.new("Song")

    # Test that first(n, mongo_direct: true) works
    assert_raises(Parse::MongoDB::GemNotAvailable, Parse::MongoDB::NotEnabled) do
      query.first(5, mongo_direct: true)
    end
  end

  def test_count_accepts_mongo_direct_parameter
    require "parse/mongodb"

    query = Parse::Query.new("Song")

    assert_raises(Parse::MongoDB::GemNotAvailable, Parse::MongoDB::NotEnabled) do
      query.count(mongo_direct: true)
    end
  end

  def test_distinct_accepts_mongo_direct_parameter
    require "parse/mongodb"

    query = Parse::Query.new("Song")

    assert_raises(Parse::MongoDB::GemNotAvailable, Parse::MongoDB::NotEnabled) do
      query.distinct(:genre, mongo_direct: true)
    end
  end

  def test_group_by_accepts_mongo_direct_parameter
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    group = query.group_by(:genre, mongo_direct: true)

    # Verify the GroupBy object was created with mongo_direct flag
    assert group.is_a?(Parse::GroupBy), "Should return a GroupBy object"
    assert group.instance_variable_get(:@mongo_direct), "mongo_direct should be true"
  end

  def test_group_by_sortable_accepts_mongo_direct_parameter
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    group = query.group_by(:genre, sortable: true, mongo_direct: true)

    # Verify the SortableGroupBy object was created with mongo_direct flag
    assert group.is_a?(Parse::SortableGroupBy), "Should return a SortableGroupBy object"
    assert group.instance_variable_get(:@mongo_direct), "mongo_direct should be true"
  end

  def test_group_by_date_accepts_mongo_direct_parameter
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    group = query.group_by_date(:created_at, :month, mongo_direct: true)

    # Verify the GroupByDate object was created with mongo_direct flag
    assert group.is_a?(Parse::GroupByDate), "Should return a GroupByDate object"
    assert group.instance_variable_get(:@mongo_direct), "mongo_direct should be true"
  end

  def test_group_by_date_sortable_accepts_mongo_direct_parameter
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    group = query.group_by_date(:created_at, :day, sortable: true, mongo_direct: true)

    # Verify the SortableGroupByDate object was created with mongo_direct flag
    assert group.is_a?(Parse::SortableGroupByDate), "Should return a SortableGroupByDate object"
    assert group.instance_variable_get(:@mongo_direct), "mongo_direct should be true"
  end

  # ==========================================================================
  # Direct Method Aliases Tests
  # ==========================================================================

  def test_count_direct_raises_without_configuration
    require "parse/mongodb"

    query = Parse::Query.new("Song")

    assert_raises(Parse::MongoDB::GemNotAvailable, Parse::MongoDB::NotEnabled) do
      query.count_direct
    end
  end

  def test_distinct_direct_raises_without_configuration
    require "parse/mongodb"

    query = Parse::Query.new("Song")

    assert_raises(Parse::MongoDB::GemNotAvailable, Parse::MongoDB::NotEnabled) do
      query.distinct_direct(:genre)
    end
  end

  def test_distinct_direct_validates_field_parameter
    require "parse/mongodb"

    # Stub MongoDB as available to get past the availability check
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, "mongodb://localhost/test")

    query = Parse::Query.new("Song")

    # Test invalid field values raise ArgumentError
    assert_raises(ArgumentError) do
      query.distinct_direct(nil)
    end

    assert_raises(ArgumentError) do
      query.distinct_direct({ foo: "bar" })
    end

    assert_raises(ArgumentError) do
      query.distinct_direct(["field1", "field2"])
    end
  ensure
    Parse::MongoDB.reset!
  end

  # ==========================================================================
  # Pipeline Stage Tests
  # ==========================================================================

  def test_pipeline_includes_match_for_where_constraints
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    query.where(:genre => "Rock", :plays.gt => 100)

    pipeline = query.send(:build_direct_mongodb_pipeline)

    match_stage = pipeline.find { |s| s.key?("$match") }
    assert match_stage, "Pipeline should include $match stage"
    assert match_stage["$match"]["genre"], "Match should include genre constraint"
  end

  def test_pipeline_order_is_correct
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    query.where(:genre => "Rock")
    query.order(:plays.desc)
    query.skip(10)
    query.limit(5)

    pipeline = query.send(:build_direct_mongodb_pipeline)

    # Find stage indices
    match_idx = pipeline.find_index { |s| s.key?("$match") }
    sort_idx = pipeline.find_index { |s| s.key?("$sort") }
    skip_idx = pipeline.find_index { |s| s.key?("$skip") }
    limit_idx = pipeline.find_index { |s| s.key?("$limit") }

    # Verify order: match -> sort -> skip -> limit
    assert match_idx, "Should have match stage"
    assert sort_idx, "Should have sort stage"
    assert skip_idx, "Should have skip stage"
    assert limit_idx, "Should have limit stage"

    assert match_idx < sort_idx, "Match should come before sort"
    assert sort_idx < skip_idx, "Sort should come before skip"
    assert skip_idx < limit_idx, "Skip should come before limit"
  end

  def test_convert_constraints_handles_and_operator
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    constraints = {
      "$and" => [
        { "genre" => "Rock" },
        { "plays" => { "$gt" => 100 } },
      ],
    }

    result = query.send(:convert_constraints_for_direct_mongodb, constraints)

    assert result["$and"].is_a?(Array), "$and should remain an array"
    assert_equal 2, result["$and"].length, "$and should have 2 conditions"
  end

  def test_convert_constraints_handles_or_operator
    require "parse/mongodb"

    query = Parse::Query.new("Song")
    constraints = {
      "$or" => [
        { "genre" => "Rock" },
        { "genre" => "Pop" },
      ],
    }

    result = query.send(:convert_constraints_for_direct_mongodb, constraints)

    assert result["$or"].is_a?(Array), "$or should remain an array"
    assert_equal 2, result["$or"].length, "$or should have 2 conditions"
  end

  private

  # Mock BSON::ObjectId if the mongo gem is not installed
  def mock_bson_object_id
    return if defined?(BSON::ObjectId)

    # Create a mock BSON module with ObjectId class
    bson_module = Module.new
    object_id_class = Class.new do
      def initialize(value)
        @value = value
      end

      def to_s
        @value.to_s
      end
    end

    bson_module.const_set(:ObjectId, object_id_class)
    Object.const_set(:BSON, bson_module)
  end

  public

  # ==========================================================================
  # Include/Eager Loading Tests
  # ==========================================================================

  def test_convert_document_included_fields
    require "parse/mongodb"

    doc = {
      "_id" => "song123",
      "title" => "Test Song",
      "_included_artist" => {
        "_id" => "artist456",
        "name" => "Test Artist",
        "_created_at" => Time.utc(2024, 1, 15, 10, 30, 0),
      },
    }

    result = Parse::MongoDB.convert_document_to_parse(doc, "Song")

    assert_equal "song123", result["objectId"]
    assert_equal "Test Song", result["title"]

    # Included field should be converted with proper field name
    assert result.key?("artist"), "Should have artist field from _included_artist"
    assert result["artist"].is_a?(Hash), "artist should be a Hash"
    assert_equal "artist456", result["artist"]["objectId"]
    assert_equal "Test Artist", result["artist"]["name"]

    # Date fields should be converted
    assert result["artist"]["createdAt"].is_a?(Hash)
    assert_equal "Date", result["artist"]["createdAt"]["__type"]
  end

  def test_convert_document_included_nil_value
    require "parse/mongodb"

    doc = {
      "_id" => "song123",
      "title" => "Test Song",
      "_included_artist" => nil,  # Artist pointer was null
    }

    result = Parse::MongoDB.convert_document_to_parse(doc, "Song")

    assert_equal "song123", result["objectId"]
    assert_equal "Test Song", result["title"]
    assert result.key?("artist"), "Should have artist field even if nil"
    assert_nil result["artist"], "artist should be nil"
  end

  def test_convert_document_skips_include_id_fields
    require "parse/mongodb"

    doc = {
      "_id" => "song123",
      "title" => "Test Song",
      "_include_id_artist" => "artist456",  # Temporary lookup field
    }

    result = Parse::MongoDB.convert_document_to_parse(doc, "Song")

    assert_equal "song123", result["objectId"]
    assert_equal "Test Song", result["title"]
    refute result.key?("_include_id_artist"), "Should skip _include_id_* fields"
    refute result.key?("include_id_artist"), "Should not create stripped field"
  end

  def test_convert_document_multiple_includes
    require "parse/mongodb"

    doc = {
      "_id" => "song123",
      "title" => "Test Song",
      "_included_artist" => {
        "_id" => "artist456",
        "name" => "Test Artist",
      },
      "_included_album" => {
        "_id" => "album789",
        "title" => "Test Album",
        "year" => 2024,
      },
    }

    result = Parse::MongoDB.convert_document_to_parse(doc, "Song")

    assert_equal "song123", result["objectId"]
    assert_equal "Test Song", result["title"]

    # Both included fields should be converted
    assert result.key?("artist"), "Should have artist field"
    assert_equal "artist456", result["artist"]["objectId"]
    assert_equal "Test Artist", result["artist"]["name"]

    assert result.key?("album"), "Should have album field"
    assert_equal "album789", result["album"]["objectId"]
    assert_equal "Test Album", result["album"]["title"]
    assert_equal 2024, result["album"]["year"]
  end

  def test_convert_document_included_with_pointer_fields
    require "parse/mongodb"

    doc = {
      "_id" => "song123",
      "title" => "Test Song",
      "_included_artist" => {
        "_id" => "artist456",
        "name" => "Test Artist",
        "_p_label" => "Label$label789",  # Nested pointer in included document
      },
    }

    result = Parse::MongoDB.convert_document_to_parse(doc, "Song")

    # Artist's nested pointer should be converted
    assert result["artist"]["label"].is_a?(Hash)
    assert_equal "Pointer", result["artist"]["label"]["__type"]
    assert_equal "Label", result["artist"]["label"]["className"]
    assert_equal "label789", result["artist"]["label"]["objectId"]
  end
end
