# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/atlas_search"

# Unit tests for Parse::AtlasSearch module.
# These tests do not require a MongoDB connection and test the module structure,
# configuration, error classes, and builder functionality.
class AtlasSearchTest < Minitest::Test
  def setup
    Parse::AtlasSearch.reset!
  end

  def teardown
    Parse::AtlasSearch.reset!
  end

  #----------------------------------------------------------------
  # MODULE STRUCTURE TESTS
  #----------------------------------------------------------------

  def test_module_exists
    assert defined?(Parse::AtlasSearch)
  end

  def test_error_classes_defined
    assert defined?(Parse::AtlasSearch::NotAvailable)
    assert defined?(Parse::AtlasSearch::IndexNotFound)
    assert defined?(Parse::AtlasSearch::InvalidSearchParameters)
  end

  def test_error_classes_inherit_from_standard_error
    assert Parse::AtlasSearch::NotAvailable < StandardError
    assert Parse::AtlasSearch::IndexNotFound < StandardError
    assert Parse::AtlasSearch::InvalidSearchParameters < StandardError
  end

  #----------------------------------------------------------------
  # CONFIGURATION TESTS
  #----------------------------------------------------------------

  def test_disabled_by_default
    assert_equal false, Parse::AtlasSearch.enabled?
  end

  def test_default_index_is_default
    assert_equal "default", Parse::AtlasSearch.default_index
  end

  def test_not_available_when_disabled
    refute Parse::AtlasSearch.available?
  end

  def test_reset_clears_configuration
    # First configure
    Parse::AtlasSearch.instance_variable_set(:@enabled, true)
    Parse::AtlasSearch.instance_variable_set(:@default_index, "custom")

    # Then reset
    Parse::AtlasSearch.reset!

    assert_equal false, Parse::AtlasSearch.enabled?
    assert_equal "default", Parse::AtlasSearch.default_index
  end

  #----------------------------------------------------------------
  # INDEX MANAGER TESTS
  #----------------------------------------------------------------

  def test_index_manager_module_exists
    assert defined?(Parse::AtlasSearch::IndexManager)
  end

  def test_index_manager_clear_cache
    # Should not raise
    Parse::AtlasSearch::IndexManager.clear_cache
    Parse::AtlasSearch::IndexManager.clear_cache("SomeCollection")
  end

  def test_index_manager_index_exists_method
    assert_respond_to Parse::AtlasSearch::IndexManager, :index_exists?
  end

  def test_index_manager_get_index_method
    assert_respond_to Parse::AtlasSearch::IndexManager, :get_index
  end

  def test_index_manager_validate_index_method
    assert_respond_to Parse::AtlasSearch::IndexManager, :validate_index!
  end

  def test_index_manager_index_ready_method
    assert_respond_to Parse::AtlasSearch::IndexManager, :index_ready?
  end

  def test_index_manager_list_indexes_method
    assert_respond_to Parse::AtlasSearch::IndexManager, :list_indexes
  end

  def test_index_manager_clear_cache_specific_collection
    # Manually populate cache
    cache = Parse::AtlasSearch::IndexManager.instance_variable_get(:@index_cache) || {}
    cache["TestCollection"] = { indexes: [{ "name" => "test" }], cached_at: Time.now }
    cache["OtherCollection"] = { indexes: [{ "name" => "other" }], cached_at: Time.now }
    Parse::AtlasSearch::IndexManager.instance_variable_set(:@index_cache, cache)

    # Clear specific collection
    Parse::AtlasSearch::IndexManager.clear_cache("TestCollection")

    # Verify only that collection was cleared
    updated_cache = Parse::AtlasSearch::IndexManager.instance_variable_get(:@index_cache)
    refute updated_cache.key?("TestCollection")
    assert updated_cache.key?("OtherCollection")
  end

  def test_index_manager_clear_cache_all
    # Manually populate cache
    cache = { "A" => { indexes: [] }, "B" => { indexes: [] } }
    Parse::AtlasSearch::IndexManager.instance_variable_set(:@index_cache, cache)

    # Clear all
    Parse::AtlasSearch::IndexManager.clear_cache

    updated_cache = Parse::AtlasSearch::IndexManager.instance_variable_get(:@index_cache)
    assert_empty updated_cache
  end

  #----------------------------------------------------------------
  # SEARCH BUILDER TESTS
  #----------------------------------------------------------------

  def test_search_builder_exists
    assert defined?(Parse::AtlasSearch::SearchBuilder)
  end

  def test_search_builder_initialization
    builder = Parse::AtlasSearch::SearchBuilder.new(index_name: "test_index")
    assert_equal "test_index", builder.index_name
  end

  def test_search_builder_default_index
    builder = Parse::AtlasSearch::SearchBuilder.new
    assert_equal "default", builder.index_name
  end

  def test_search_builder_text_operator
    builder = Parse::AtlasSearch::SearchBuilder.new(index_name: "test")
    builder.text(query: "love", path: :title)

    stage = builder.build
    assert_equal "test", stage["$search"]["index"]
    assert stage["$search"]["text"]
    assert_equal "love", stage["$search"]["text"]["query"]
    assert_equal "title", stage["$search"]["text"]["path"]
  end

  def test_search_builder_text_with_multiple_paths
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.text(query: "love", path: [:title, :lyrics])

    stage = builder.build
    assert_equal ["title", "lyrics"], stage["$search"]["text"]["path"]
  end

  def test_search_builder_text_with_fuzzy
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.text(query: "love", path: :title, fuzzy: true)

    stage = builder.build
    assert stage["$search"]["text"]["fuzzy"]
    assert_equal 2, stage["$search"]["text"]["fuzzy"]["maxEdits"]
  end

  def test_search_builder_text_with_fuzzy_options
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.text(query: "love", path: :title, fuzzy: { "maxEdits" => 1 })

    stage = builder.build
    assert_equal({ "maxEdits" => 1 }, stage["$search"]["text"]["fuzzy"])
  end

  def test_search_builder_phrase_operator
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.phrase(query: "broken heart", path: :lyrics, slop: 2)

    stage = builder.build
    assert_equal "broken heart", stage["$search"]["phrase"]["query"]
    assert_equal "lyrics", stage["$search"]["phrase"]["path"]
    assert_equal 2, stage["$search"]["phrase"]["slop"]
  end

  def test_search_builder_autocomplete_operator
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.autocomplete(query: "lov", path: :title)

    stage = builder.build
    assert_equal "lov", stage["$search"]["autocomplete"]["query"]
    assert_equal "title", stage["$search"]["autocomplete"]["path"]
  end

  def test_search_builder_autocomplete_with_fuzzy
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.autocomplete(query: "lov", path: :title, fuzzy: true)

    stage = builder.build
    assert stage["$search"]["autocomplete"]["fuzzy"]
    assert_equal 1, stage["$search"]["autocomplete"]["fuzzy"]["maxEdits"]
  end

  def test_search_builder_autocomplete_with_token_order
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.autocomplete(query: "lov", path: :title, token_order: "sequential")

    stage = builder.build
    assert_equal "sequential", stage["$search"]["autocomplete"]["tokenOrder"]
  end

  def test_search_builder_wildcard_operator
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.wildcard(query: "lov*", path: :title)

    stage = builder.build
    assert_equal "lov*", stage["$search"]["wildcard"]["query"]
  end

  def test_search_builder_regex_operator
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.regex(query: "^[Ll]ove", path: :title)

    stage = builder.build
    assert_equal "^[Ll]ove", stage["$search"]["regex"]["query"]
  end

  def test_search_builder_range_operator
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.range(path: :plays, gte: 1000, lt: 5000)

    stage = builder.build
    assert_equal "plays", stage["$search"]["range"]["path"]
    assert_equal 1000, stage["$search"]["range"]["gte"]
    assert_equal 5000, stage["$search"]["range"]["lt"]
  end

  def test_search_builder_exists_operator
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.exists(path: :lyrics)

    stage = builder.build
    assert_equal "lyrics", stage["$search"]["exists"]["path"]
  end

  def test_search_builder_compound_query
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.text(query: "love", path: :title)
    builder.text(query: "heart", path: :lyrics)

    stage = builder.build
    assert stage["$search"]["compound"]
    assert_equal 2, stage["$search"]["compound"]["must"].length
  end

  def test_search_builder_with_highlight
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.text(query: "love", path: :title)
    builder.with_highlight(path: :title)

    stage = builder.build
    assert stage["$search"]["highlight"]
    assert_equal "title", stage["$search"]["highlight"]["path"]
  end

  def test_search_builder_with_highlight_options
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.text(query: "love", path: :title)
    builder.with_highlight(path: :title, max_chars_to_examine: 1000, max_num_passages: 3)

    stage = builder.build
    assert_equal 1000, stage["$search"]["highlight"]["maxCharsToExamine"]
    assert_equal 3, stage["$search"]["highlight"]["maxNumPassages"]
  end

  def test_search_builder_with_count
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.text(query: "love", path: :title)
    builder.with_count

    stage = builder.build
    assert stage["$search"]["count"]
    assert_equal "total", stage["$search"]["count"]["type"]
  end

  def test_search_builder_raises_without_operators
    builder = Parse::AtlasSearch::SearchBuilder.new
    assert_raises(Parse::AtlasSearch::InvalidSearchParameters) do
      builder.build
    end
  end

  def test_search_builder_with_fuzzy_config
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.with_fuzzy(max_edits: 1, prefix_length: 2, max_expansions: 100)

    # The fuzzy config is stored but applied to subsequent text operators
    assert_equal 1, builder.instance_variable_get(:@fuzzy_config)["maxEdits"]
    assert_equal 2, builder.instance_variable_get(:@fuzzy_config)["prefixLength"]
    assert_equal 100, builder.instance_variable_get(:@fuzzy_config)["maxExpansions"]
  end

  def test_search_builder_range_with_date
    builder = Parse::AtlasSearch::SearchBuilder.new
    test_time = Time.utc(2024, 6, 15, 12, 30, 45)
    builder.range(path: :created_at, gte: test_time)

    stage = builder.build
    assert_equal "2024-06-15T12:30:45.000Z", stage["$search"]["range"]["gte"]
  end

  def test_search_builder_range_with_datetime
    builder = Parse::AtlasSearch::SearchBuilder.new
    test_datetime = DateTime.new(2024, 6, 15, 12, 30, 45)
    builder.range(path: :updated_at, lt: test_datetime)

    stage = builder.build
    assert stage["$search"]["range"]["lt"].start_with?("2024-06-15")
  end

  def test_search_builder_range_with_date_object
    builder = Parse::AtlasSearch::SearchBuilder.new
    test_date = Date.new(2024, 6, 15)
    builder.range(path: :release_date, lte: test_date)

    stage = builder.build
    lte_value = stage["$search"]["range"]["lte"]
    # Should be converted to ISO8601 string
    assert lte_value.is_a?(String), "Date should be converted to string, got #{lte_value.class}"
    assert lte_value.include?("2024-06-15"), "Should contain the date"
  end

  #----------------------------------------------------------------
  # BUILD_COMPOUND TESTS
  #----------------------------------------------------------------

  def test_search_builder_build_compound_with_must
    builder = Parse::AtlasSearch::SearchBuilder.new(index_name: "test")
    must_op = { "text" => { "query" => "love", "path" => "title" } }

    stage = builder.build_compound(must: must_op)

    assert_equal "test", stage["$search"]["index"]
    assert stage["$search"]["compound"]["must"]
    assert_equal 1, stage["$search"]["compound"]["must"].length
  end

  def test_search_builder_build_compound_with_must_not
    builder = Parse::AtlasSearch::SearchBuilder.new
    must_not_op = { "text" => { "query" => "explicit", "path" => "lyrics" } }

    stage = builder.build_compound(must_not: must_not_op)

    assert stage["$search"]["compound"]["mustNot"]
    assert_equal "explicit", stage["$search"]["compound"]["mustNot"].first["text"]["query"]
  end

  def test_search_builder_build_compound_with_should
    builder = Parse::AtlasSearch::SearchBuilder.new
    should_ops = [
      { "text" => { "query" => "rock", "path" => "genre" } },
      { "text" => { "query" => "pop", "path" => "genre" } },
    ]

    stage = builder.build_compound(should: should_ops, minimum_should_match: 1)

    assert_equal 2, stage["$search"]["compound"]["should"].length
    assert_equal 1, stage["$search"]["compound"]["minimumShouldMatch"]
  end

  def test_search_builder_build_compound_with_filter
    builder = Parse::AtlasSearch::SearchBuilder.new
    filter_op = { "range" => { "path" => "plays", "gte" => 1000 } }

    stage = builder.build_compound(filter: filter_op)

    assert stage["$search"]["compound"]["filter"]
    assert_equal 1000, stage["$search"]["compound"]["filter"].first["range"]["gte"]
  end

  def test_search_builder_build_compound_full
    builder = Parse::AtlasSearch::SearchBuilder.new(index_name: "custom")
    builder.with_highlight(path: :title)
    builder.with_count

    stage = builder.build_compound(
      must: { "text" => { "query" => "love", "path" => "title" } },
      must_not: { "text" => { "query" => "hate", "path" => "title" } },
      should: { "text" => { "query" => "heart", "path" => "lyrics" } },
      filter: { "range" => { "path" => "year", "gte" => 2000 } },
      minimum_should_match: 1,
    )

    assert_equal "custom", stage["$search"]["index"]
    assert stage["$search"]["compound"]["must"]
    assert stage["$search"]["compound"]["mustNot"]
    assert stage["$search"]["compound"]["should"]
    assert stage["$search"]["compound"]["filter"]
    assert_equal 1, stage["$search"]["compound"]["minimumShouldMatch"]
    assert stage["$search"]["highlight"]
    assert stage["$search"]["count"]
  end

  def test_search_builder_build_compound_with_nested_builder
    inner_builder = Parse::AtlasSearch::SearchBuilder.new
    inner_builder.text(query: "love", path: :title)

    outer_builder = Parse::AtlasSearch::SearchBuilder.new
    stage = outer_builder.build_compound(must: inner_builder)

    # The inner builder should be converted to an operator
    assert stage["$search"]["compound"]["must"]
  end

  def test_search_builder_chaining
    builder = Parse::AtlasSearch::SearchBuilder.new
      .text(query: "love", path: :title)
      .with_highlight(path: :title)
      .with_count

    stage = builder.build
    assert stage["$search"]["text"]
    assert stage["$search"]["highlight"]
    assert stage["$search"]["count"]
  end

  #----------------------------------------------------------------
  # RESULT CLASSES TESTS
  #----------------------------------------------------------------

  def test_search_result_exists
    assert defined?(Parse::AtlasSearch::SearchResult)
  end

  def test_search_result_initialization
    result = Parse::AtlasSearch::SearchResult.new(results: [1, 2, 3])
    assert_equal [1, 2, 3], result.results
    assert_equal 3, result.count
    refute result.empty?
  end

  def test_search_result_empty
    result = Parse::AtlasSearch::SearchResult.new(results: [])
    assert result.empty?
    assert_equal 0, result.count
  end

  def test_search_result_enumerable
    result = Parse::AtlasSearch::SearchResult.new(results: [1, 2, 3])
    assert_equal [2, 4, 6], result.map { |x| x * 2 }
  end

  def test_search_result_first_and_last
    result = Parse::AtlasSearch::SearchResult.new(results: [1, 2, 3])
    assert_equal 1, result.first
    assert_equal 3, result.last
  end

  def test_search_result_index_access
    result = Parse::AtlasSearch::SearchResult.new(results: [:a, :b, :c])
    assert_equal :b, result[1]
  end

  def test_autocomplete_result_exists
    assert defined?(Parse::AtlasSearch::AutocompleteResult)
  end

  def test_autocomplete_result_initialization
    result = Parse::AtlasSearch::AutocompleteResult.new(
      suggestions: ["Love Story", "Lovely Day"],
      results: [],
    )
    assert_equal ["Love Story", "Lovely Day"], result.suggestions
    assert_equal 2, result.count
    refute result.empty?
  end

  def test_autocomplete_result_first
    result = Parse::AtlasSearch::AutocompleteResult.new(
      suggestions: ["Love Story", "Lovely Day"],
      results: [],
    )
    assert_equal "Love Story", result.first
  end

  def test_faceted_result_exists
    assert defined?(Parse::AtlasSearch::FacetedResult)
  end

  def test_faceted_result_initialization
    facets = {
      genre: [{ value: "Rock", count: 100 }, { value: "Pop", count: 50 }],
    }
    result = Parse::AtlasSearch::FacetedResult.new(
      results: [1, 2],
      facets: facets,
      total_count: 150,
    )

    assert_equal [1, 2], result.results
    assert_equal 150, result.total_count
    assert_equal 2, result.count
  end

  def test_faceted_result_facet_access
    facets = {
      genre: [{ value: "Rock", count: 100 }],
      "decade" => [{ value: 1980, count: 50 }],
    }
    result = Parse::AtlasSearch::FacetedResult.new(
      results: [],
      facets: facets,
      total_count: 0,
    )

    assert_equal [{ value: "Rock", count: 100 }], result.facet(:genre)
    assert_equal [{ value: 1980, count: 50 }], result.facet("decade")
  end

  def test_faceted_result_facet_names
    facets = { genre: [], year: [], artist: [] }
    result = Parse::AtlasSearch::FacetedResult.new(
      results: [],
      facets: facets,
      total_count: 0,
    )

    assert_equal [:genre, :year, :artist], result.facet_names
  end

  def test_faceted_result_enumerable
    result = Parse::AtlasSearch::FacetedResult.new(
      results: [1, 2, 3],
      facets: {},
      total_count: 3,
    )
    assert_equal [2, 4, 6], result.map { |x| x * 2 }
  end
end

# Integration tests for Atlas Search (requires MongoDB Atlas or local Atlas deployment)
class AtlasSearchIntegrationTest < Minitest::Test
  def setup
    skip_unless_atlas_available
    Parse::AtlasSearch.configure(enabled: true, default_index: "default")
  end

  def teardown
    Parse::AtlasSearch.reset!
  end

  private

  def skip_unless_atlas_available
    skip "Atlas Search integration tests require ATLAS_TEST=true" unless ENV["ATLAS_TEST"]
    skip "Parse::MongoDB must be configured" unless Parse::MongoDB.available?
  end
end
