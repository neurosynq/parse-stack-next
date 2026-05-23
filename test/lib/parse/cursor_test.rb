# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/autorun"

class CursorTest < Minitest::Test
  # Mock query for testing cursor without real Parse server
  class MockQuery
    attr_reader :table, :constraints, :orders, :page_size, :fetch_count

    def initialize(table = "TestClass")
      @table = table
      @constraints = []
      @orders = []
      @page_size = nil
      @fetch_count = 0
      @mock_results = []
    end

    def dup
      copy = MockQuery.new(@table)
      copy.instance_variable_set(:@constraints, @constraints.dup)
      copy.instance_variable_set(:@orders, @orders.dup)
      copy.instance_variable_set(:@mock_results, @mock_results)
      copy.instance_variable_set(:@page_size, @page_size)
      copy
    end

    def order(*orderings)
      @orders.concat(orderings)
      self
    end

    def clear(item)
      case item
      when :order
        @orders = []
      end
      self
    end

    def where(conditions)
      @constraints << conditions
      self
    end

    def limit(count)
      @page_size = count
      self
    end

    def results
      @fetch_count += 1
      # Return mock results based on fetch count
      return @mock_results if @mock_results.is_a?(Array) && !@mock_results.empty?
      []
    end

    def set_mock_results(results)
      @mock_results = results
    end
  end

  # Mock parse object
  class MockParseObject
    attr_reader :id, :created_at

    def initialize(id:, created_at: nil)
      @id = id
      @created_at = created_at || Time.now
    end
  end

  def test_cursor_initialization
    query = MockQuery.new
    cursor = Parse::Cursor.new(query, limit: 50)

    assert_equal 50, cursor.page_size
    assert_nil cursor.position
    assert_equal 0, cursor.pages_fetched
    assert_equal 0, cursor.items_fetched
    refute cursor.exhausted?
    assert cursor.more_pages?
  end

  def test_cursor_default_limit
    query = MockQuery.new
    cursor = Parse::Cursor.new(query)

    assert_equal 100, cursor.page_size
  end

  def test_cursor_default_ordering
    query = MockQuery.new
    cursor = Parse::Cursor.new(query)

    assert_equal :createdAt, cursor.order_field
    assert_equal :asc, cursor.order_direction
  end

  def test_cursor_custom_ordering
    query = MockQuery.new
    # Create order using the Symbol extension
    order = :updated_at.desc
    cursor = Parse::Cursor.new(query, order: order)

    # The field is stored as the symbol passed to the order
    assert_equal :updated_at, cursor.order_field
    assert_equal :desc, cursor.order_direction
  end

  def test_cursor_reset
    query = MockQuery.new
    cursor = Parse::Cursor.new(query)

    # Simulate some pagination state
    cursor.instance_variable_set(:@position, "abc123")
    cursor.instance_variable_set(:@pages_fetched, 5)
    cursor.instance_variable_set(:@items_fetched, 50)
    cursor.instance_variable_set(:@exhausted, true)

    # Reset
    cursor.reset!

    assert_nil cursor.position
    assert_equal 0, cursor.pages_fetched
    assert_equal 0, cursor.items_fetched
    refute cursor.exhausted?
  end

  def test_cursor_stats
    query = MockQuery.new
    cursor = Parse::Cursor.new(query, limit: 25)

    cursor.instance_variable_set(:@position, "abc123")
    cursor.instance_variable_set(:@pages_fetched, 4)
    cursor.instance_variable_set(:@items_fetched, 100)
    cursor.instance_variable_set(:@exhausted, true)

    stats = cursor.stats

    assert_equal 4, stats[:pages_fetched]
    assert_equal 100, stats[:items_fetched]
    assert_equal 25, stats[:page_size]
    assert stats[:exhausted]
    assert_equal "abc123", stats[:position]
  end

  def test_cursor_next_page_empty_results
    query = MockQuery.new
    query.set_mock_results([])

    cursor = Parse::Cursor.new(query)
    page = cursor.next_page

    assert_empty page
    assert cursor.exhausted?
  end

  def test_cursor_next_page_with_results
    query = MockQuery.new
    results = [
      MockParseObject.new(id: "obj1"),
      MockParseObject.new(id: "obj2"),
      MockParseObject.new(id: "obj3"),
    ]
    query.set_mock_results(results)

    cursor = Parse::Cursor.new(query, limit: 10)
    page = cursor.next_page

    assert_equal 3, page.size
    assert_equal 1, cursor.pages_fetched
    assert_equal 3, cursor.items_fetched
    # Exhausted because we got less than page_size
    assert cursor.exhausted?
  end

  def test_cursor_enumerable
    query = MockQuery.new
    cursor = Parse::Cursor.new(query)

    # Cursor includes Enumerable
    assert cursor.respond_to?(:map)
    assert cursor.respond_to?(:select)
    assert cursor.respond_to?(:each)
    assert cursor.respond_to?(:to_a)
  end

  def test_cursor_each_returns_enumerator_without_block
    query = MockQuery.new
    cursor = Parse::Cursor.new(query)

    enum = cursor.each
    assert enum.is_a?(Enumerator)
  end

  def test_cursor_each_page_returns_enumerator_without_block
    query = MockQuery.new
    cursor = Parse::Cursor.new(query)

    enum = cursor.each_page
    assert enum.is_a?(Enumerator)
  end

  def test_query_cursor_method
    # Test that Query has the cursor method
    # This requires a real query, but we can at least test the method exists
    query = Parse::Query.new("TestClass")
    assert query.respond_to?(:cursor)

    cursor = query.cursor(limit: 50)
    assert cursor.is_a?(Parse::Cursor)
    assert_equal 50, cursor.page_size
  end

  # ============================================
  # Resumable Cursor (Serialization) Tests
  # ============================================

  def test_cursor_serialize_returns_json_string
    query = Parse::Query.new("TestClass")
    cursor = Parse::Cursor.new(query, limit: 50)

    json = cursor.serialize
    assert json.is_a?(String), "serialize should return a string"

    # Should be valid JSON
    parsed = JSON.parse(json)
    assert parsed.is_a?(Hash), "serialize should return valid JSON hash"
  end

  def test_cursor_serialize_includes_required_fields
    query = Parse::Query.new("TestClass")
    cursor = Parse::Cursor.new(query, limit: 75)

    json = cursor.serialize
    parsed = JSON.parse(json, symbolize_names: true)

    assert_equal "TestClass", parsed[:class_name], "Should include class_name"
    assert_equal 75, parsed[:page_size], "Should include page_size"
    assert_equal "createdAt", parsed[:order_field].to_s, "Should include order_field"
    assert_equal "asc", parsed[:order_direction].to_s, "Should include order_direction"
    assert parsed.key?(:version), "Should include version for compatibility"
  end

  def test_cursor_serialize_preserves_pagination_state
    query = Parse::Query.new("TestClass")
    cursor = Parse::Cursor.new(query, limit: 25)

    # Simulate pagination progress
    cursor.instance_variable_set(:@position, "abc123")
    cursor.instance_variable_set(:@last_object_id, "abc123")
    cursor.instance_variable_set(:@pages_fetched, 3)
    cursor.instance_variable_set(:@items_fetched, 75)
    cursor.instance_variable_set(:@exhausted, false)

    json = cursor.serialize
    parsed = JSON.parse(json, symbolize_names: true)

    assert_equal "abc123", parsed[:position], "Should preserve position"
    assert_equal "abc123", parsed[:last_object_id], "Should preserve last_object_id"
    assert_equal 3, parsed[:pages_fetched], "Should preserve pages_fetched"
    assert_equal 75, parsed[:items_fetched], "Should preserve items_fetched"
    assert_equal false, parsed[:exhausted], "Should preserve exhausted state"
  end

  def test_cursor_to_json_alias
    query = Parse::Query.new("TestClass")
    cursor = Parse::Cursor.new(query)

    # to_json should be an alias for serialize
    assert_equal cursor.serialize, cursor.to_json
  end

  def test_cursor_serialize_with_date_value
    query = Parse::Query.new("TestClass")
    cursor = Parse::Cursor.new(query, limit: 50, order: :created_at.desc)

    # Set a DateTime value for last_order_value
    test_time = DateTime.new(2024, 1, 15, 12, 30, 45)
    cursor.instance_variable_set(:@last_order_value, test_time)

    json = cursor.serialize
    parsed = JSON.parse(json, symbolize_names: true)

    # Date should be serialized as Parse Date type
    assert parsed[:last_order_value].is_a?(Hash), "Date should be serialized as hash"
    assert_equal "Date", parsed[:last_order_value][:__type], "Should have __type Date"
    assert parsed[:last_order_value][:iso].is_a?(String), "Should have iso string"
  end

  def test_cursor_deserialize_validates_required_fields
    # Missing required fields should raise ArgumentError
    invalid_json = JSON.generate({ page_size: 50 })

    assert_raises(ArgumentError) do
      Parse::Cursor.deserialize(invalid_json)
    end
  end

  def test_cursor_deserialize_rejects_unknown_class
    json = JSON.generate({
      class_name: "NonExistentClass12345",
      page_size: 50,
      order_field: "createdAt",
      order_direction: "asc",
    })

    assert_raises(ArgumentError) do
      Parse::Cursor.deserialize(json)
    end
  end

  def test_cursor_from_json_alias
    # from_json should be an alias for deserialize
    assert Parse::Cursor.respond_to?(:from_json)
    assert Parse::Cursor.respond_to?(:deserialize)
  end

  def test_cursor_serialize_with_custom_order
    query = Parse::Query.new("TestClass")
    cursor = Parse::Cursor.new(query, limit: 100, order: :updated_at.desc)

    json = cursor.serialize
    parsed = JSON.parse(json, symbolize_names: true)

    assert_equal "updated_at", parsed[:order_field].to_s
    assert_equal "desc", parsed[:order_direction].to_s
  end

  def test_cursor_serialize_includes_constraints
    query = Parse::Query.new("TestClass")
    query.where(:name.eq => "Test")
    cursor = Parse::Cursor.new(query, limit: 50)

    json = cursor.serialize
    parsed = JSON.parse(json, symbolize_names: true)

    assert parsed.key?(:constraints), "Should include constraints"
  end

  # ============================================
  # Page Size Validation Tests
  # ============================================

  def test_page_size_maximum_allowed
    query = MockQuery.new
    cursor = Parse::Cursor.new(query, limit: 1000)

    assert_equal 1000, cursor.page_size, "Should allow max page size of 1000"
  end

  def test_page_size_exceeds_maximum_raises_error
    query = MockQuery.new

    error = assert_raises(ArgumentError) do
      Parse::Cursor.new(query, limit: 1001)
    end

    assert_match(/Page size 1001 exceeds maximum allowed/, error.message)
    assert_match(/1000/, error.message)
  end

  def test_page_size_minimum_is_one
    query = MockQuery.new
    cursor = Parse::Cursor.new(query, limit: 0)

    assert_equal 1, cursor.page_size, "Minimum page size should be 1"

    cursor2 = Parse::Cursor.new(query, limit: -5)
    assert_equal 1, cursor2.page_size, "Negative limit should become 1"
  end

  def test_max_page_size_constant
    assert_equal 1000, Parse::Cursor::MAX_PAGE_SIZE
    assert_equal 100, Parse::Cursor::DEFAULT_PAGE_SIZE
  end
end
