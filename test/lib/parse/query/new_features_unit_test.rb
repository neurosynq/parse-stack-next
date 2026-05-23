require_relative "../../../test_helper"

class TestNewQueryFeatures < Minitest::Test
  def setup
    @query = Parse::Query.new("TestClass")
  end

  # Test basic functionality without complex mocking

  def test_select_fields_alias_works
    @query.select_fields(:name, :category)
    assert_equal [:name, :category], @query.instance_variable_get(:@keys)
  end

  def test_keys_method_adds_fields_correctly
    @query.keys(:name)
    assert_equal [:name], @query.instance_variable_get(:@keys)

    @query.keys(:category, :status)
    assert_equal [:name, :category, :status], @query.instance_variable_get(:@keys)
  end

  def test_keys_method_returns_self_for_chaining
    result = @query.keys(:name)
    assert_equal @query, result
  end

  def test_keys_method_handles_invalid_fields
    @query.keys(nil, "", :valid_field)

    # nil gets filtered out, empty string becomes empty symbol, valid_field becomes validField
    expected_keys = [:"", :validField]
    assert_equal expected_keys, @query.instance_variable_get(:@keys)
  end

  def test_compile_includes_keys_in_query
    @query.keys(:name, :category)
    compiled = @query.compile(encode: false)

    assert_equal "name,category", compiled[:keys]
  end

  def test_group_by_creates_correct_object
    group_by = @query.group_by(:category)

    assert_kind_of Parse::GroupBy, group_by
    assert_equal :category, group_by.instance_variable_get(:@group_field)
    assert_equal false, group_by.instance_variable_get(:@flatten_arrays)
    assert_equal false, group_by.instance_variable_get(:@return_pointers)
  end

  def test_group_by_with_flatten_arrays_option
    group_by = @query.group_by(:tags, flatten_arrays: true)

    assert_kind_of Parse::GroupBy, group_by
    assert_equal true, group_by.instance_variable_get(:@flatten_arrays)
  end

  def test_group_by_with_return_pointers_option
    group_by = @query.group_by(:author, return_pointers: true)

    assert_kind_of Parse::GroupBy, group_by
    assert_equal true, group_by.instance_variable_get(:@return_pointers)
  end

  def test_group_by_with_sortable_option
    group_by = @query.group_by(:category, sortable: true)

    assert_kind_of Parse::SortableGroupBy, group_by
  end

  def test_group_by_with_all_options
    group_by = @query.group_by(:tags, flatten_arrays: true, sortable: true, return_pointers: true)

    assert_kind_of Parse::SortableGroupBy, group_by
    assert_equal true, group_by.instance_variable_get(:@flatten_arrays)
    assert_equal true, group_by.instance_variable_get(:@return_pointers)
  end

  def test_group_by_date_creates_correct_object
    group_by_date = @query.group_by_date(:created_at, :day)

    assert_kind_of Parse::GroupByDate, group_by_date
    assert_equal :created_at, group_by_date.instance_variable_get(:@date_field)
    assert_equal :day, group_by_date.instance_variable_get(:@interval)
  end

  def test_group_by_date_with_sortable_option
    group_by_date = @query.group_by_date(:created_at, :month, sortable: true)

    assert_kind_of Parse::SortableGroupByDate, group_by_date
  end

  def test_group_by_date_validates_interval
    valid_intervals = [:year, :month, :week, :day, :hour]

    valid_intervals.each do |interval|
      group_by_date = @query.group_by_date(:created_at, interval)
      assert_kind_of Parse::GroupByDate, group_by_date
    end

    assert_raises(ArgumentError) do
      @query.group_by_date(:created_at, :invalid)
    end
  end

  def test_group_by_validates_field
    assert_raises(ArgumentError) do
      @query.group_by(nil)
    end

    assert_raises(ArgumentError) do
      @query.group_by_date(nil, :day)
    end
  end

  def test_grouped_result_initialization_and_basic_methods
    results_hash = { "A" => 10, "B" => 5, "C" => 15 }
    grouped_result = Parse::GroupedResult.new(results_hash)

    assert_equal results_hash, grouped_result.to_h
    assert_kind_of Hash, grouped_result.to_h
  end

  def test_grouped_result_sorting_methods
    results_hash = { "C" => 5, "A" => 10, "B" => 3 }
    grouped_result = Parse::GroupedResult.new(results_hash)

    # Test sort by key ascending
    sorted_by_key_asc = grouped_result.sort_by_key_asc
    expected_key_asc = [["A", 10], ["B", 3], ["C", 5]]
    assert_equal expected_key_asc, sorted_by_key_asc

    # Test sort by key descending
    sorted_by_key_desc = grouped_result.sort_by_key_desc
    expected_key_desc = [["C", 5], ["B", 3], ["A", 10]]
    assert_equal expected_key_desc, sorted_by_key_desc

    # Test sort by value ascending
    sorted_by_value_asc = grouped_result.sort_by_value_asc
    expected_value_asc = [["B", 3], ["C", 5], ["A", 10]]
    assert_equal expected_value_asc, sorted_by_value_asc

    # Test sort by value descending
    sorted_by_value_desc = grouped_result.sort_by_value_desc
    expected_value_desc = [["A", 10], ["C", 5], ["B", 3]]
    assert_equal expected_value_desc, sorted_by_value_desc
  end

  def test_grouped_result_to_sorted_hash
    results_hash = { "C" => 5, "A" => 10, "B" => 3 }
    grouped_result = Parse::GroupedResult.new(results_hash)

    sorted_pairs = grouped_result.sort_by_value_desc
    sorted_hash = grouped_result.to_sorted_hash(sorted_pairs)

    expected_hash = { "A" => 10, "C" => 5, "B" => 3 }
    assert_equal expected_hash, sorted_hash
  end

  def test_grouped_result_enumerable_methods
    results_hash = { "A" => 1, "B" => 2, "C" => 3 }
    grouped_result = Parse::GroupedResult.new(results_hash)

    # Test that it includes Enumerable
    assert grouped_result.respond_to?(:each)
    assert grouped_result.respond_to?(:map)
    assert grouped_result.respond_to?(:select)

    # Test enumerable behavior
    sum = grouped_result.map { |k, v| v }.sum
    assert_equal 6, sum

    high_values = grouped_result.select { |k, v| v > 2 }
    assert_equal [["C", 3]], high_values
  end

  def test_to_pointers_with_standard_objects
    list = [
      { "objectId" => "abc123", "name" => "Test1" },
      { "objectId" => "def456", "name" => "Test2" },
    ]

    pointers = @query.to_pointers(list)

    assert_equal 2, pointers.size
    assert_kind_of Parse::Pointer, pointers.first
    assert_equal "TestClass", pointers.first.parse_class
    assert_equal "abc123", pointers.first.id
  end

  def test_to_pointers_with_pointer_objects
    list = [
      { "__type" => "Pointer", "className" => "Team", "objectId" => "team1" },
      { "__type" => "Pointer", "className" => "Team", "objectId" => "team2" },
    ]

    pointers = @query.to_pointers(list)

    assert_equal 2, pointers.size
    assert_kind_of Parse::Pointer, pointers.first
    assert_equal "Team", pointers.first.parse_class
    assert_equal "team1", pointers.first.id
  end

  def test_to_pointers_handles_mixed_data
    list = [
      { "objectId" => "abc123" },  # Standard object
      { "__type" => "Pointer", "className" => "Team", "objectId" => "team1" },  # Pointer object
      { "name" => "invalid" },  # Invalid object (no objectId)
      nil,  # Nil value
    ]

    pointers = @query.to_pointers(list)

    # Should only create pointers for valid objects
    assert_equal 2, pointers.size
    assert_equal "TestClass", pointers.first.parse_class
    assert_equal "Team", pointers.last.parse_class
  end

  def test_pluck_validates_field
    # Test that validation happens before any network calls
    begin
      @query.pluck(nil)
      flunk "Expected ArgumentError"
    rescue ArgumentError => e
      assert_match(/Invalid field name/, e.message)
    end
  end

  def test_group_objects_by_validates_field
    assert_raises(ArgumentError) do
      @query.group_objects_by(nil)
    end
  end

  # Test method chaining works correctly
  def test_method_chaining
    result = @query
      .where(:status => "active")
      .keys(:name, :category)
      .order(:name)
      .limit(10)

    assert_equal @query, result
    assert_equal [:name, :category], @query.instance_variable_get(:@keys)
    assert_equal 10, @query.instance_variable_get(:@limit)
  end

  def test_group_by_inheritance_hierarchy
    # Test that SortableGroupBy inherits from GroupBy
    sortable_group_by = Parse::SortableGroupBy.new(@query, :category)
    assert_kind_of Parse::GroupBy, sortable_group_by

    # Test that SortableGroupByDate inherits from GroupByDate
    sortable_group_by_date = Parse::SortableGroupByDate.new(@query, :created_at, :day)
    assert_kind_of Parse::GroupByDate, sortable_group_by_date
  end

  def test_class_constants_exist
    # Verify all the new classes are defined
    assert defined?(Parse::GroupBy)
    assert defined?(Parse::SortableGroupBy)
    assert defined?(Parse::GroupByDate)
    assert defined?(Parse::SortableGroupByDate)
    assert defined?(Parse::GroupedResult)
  end
end
