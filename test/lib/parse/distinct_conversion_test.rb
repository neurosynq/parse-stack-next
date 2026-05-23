require_relative "../../test_helper"

class TestDistinctConversion < Minitest::Test

  def setup
    @query = Parse::Query.new("Asset")
  end

  def test_to_pointers_handles_mongodb_string_format
    strings = ["Team$abc123", "User$def456", "Project$ghi789"]
    
    result = @query.to_pointers(strings)
    
    assert_equal 3, result.size
    assert_kind_of Parse::Pointer, result.first
    assert_equal "Team", result[0].parse_class
    assert_equal "abc123", result[0].id
    assert_equal "User", result[1].parse_class  
    assert_equal "def456", result[1].id
    assert_equal "Project", result[2].parse_class
    assert_equal "ghi789", result[2].id
  end

  def test_to_pointers_handles_mixed_formats
    mixed_list = [
      # MongoDB string format
      "Team$abc123",
      # Parse pointer hash format
      { "__type" => "Pointer", "className" => "User", "objectId" => "def456" },
      # Standard Parse object hash format
      { "objectId" => "ghi789" }
    ]
    
    result = @query.to_pointers(mixed_list)
    
    assert_equal 3, result.size
    assert_equal "Team", result[0].parse_class
    assert_equal "abc123", result[0].id
    assert_equal "User", result[1].parse_class
    assert_equal "def456", result[1].id
    assert_equal "Asset", result[2].parse_class  # Uses query table name
    assert_equal "ghi789", result[2].id
  end

  def test_distinct_auto_detects_pointer_strings_and_converts
    # Test the auto-detection logic in distinct method
    values = ["Team$abc123", "Team$def456", "Team$ghi789"]
    
    # Mock the internal workings to test just the conversion logic
    @query.stub :compile_where, {} do
      @query.stub :aggregate, mock_aggregation(values) do
        # This should auto-detect pointer format and return object IDs by default
        result = @query.distinct(:project)
        
        assert_equal 3, result.size
        assert_equal ["abc123", "def456", "ghi789"], result
        assert_kind_of String, result.first
      end
    end
  end

  def test_distinct_does_not_convert_regular_strings
    # Test with regular string values
    values = ["video", "image", "audio"]
    
    @query.stub :compile_where, {} do
      @query.stub :aggregate, mock_aggregation(values) do
        result = @query.distinct(:category)
        
        # Should return strings as-is
        assert_equal ["video", "image", "audio"], result
        assert_kind_of String, result.first
      end
    end
  end

  def test_distinct_does_not_convert_invalid_pointer_strings
    # Test with strings that contain $ but aren't valid pointer format
    values = ["not-a-pointer", "also$not$valid", "$invalid", "Class$", "$objectId"]
    
    @query.stub :compile_where, {} do
      @query.stub :aggregate, mock_aggregation(values) do
        result = @query.distinct(:name)
        
        # Should return strings as-is since they don't match valid pointer format
        assert_equal values, result
        assert_kind_of String, result.first
      end
    end
  end

  def test_distinct_mixed_pointer_and_regular_strings
    # Test with mix of different pointer classes - should return as-is due to inconsistency
    values = ["Team$abc123", "User$def456", "Project$ghi789"]
    
    @query.stub :compile_where, {} do
      @query.stub :aggregate, mock_aggregation(values) do
        result = @query.distinct(:mixed_field)
        
        # Should return original strings since they don't all have the same className prefix
        assert_equal 3, result.size
        assert_equal ["Team$abc123", "User$def456", "Project$ghi789"], result
        assert_kind_of String, result.first
      end
    end
  end

  def test_distinct_with_return_pointers_converts_to_pointers
    # Test with return_pointers: true option
    values = ["Team$abc123", "Team$def456", "Team$ghi789"]
    
    @query.stub :compile_where, {} do
      @query.stub :aggregate, mock_aggregation(values) do
        result = @query.distinct(:project, return_pointers: true)
        
        # Should return Parse::Pointer objects when explicitly requested
        assert_equal 3, result.size
        assert_kind_of Parse::Pointer, result.first
        assert_equal "Team", result[0].parse_class
        assert_equal "abc123", result[0].id
        assert_equal "Team", result[1].parse_class
        assert_equal "def456", result[1].id
        assert_equal "Team", result[2].parse_class
        assert_equal "ghi789", result[2].id
      end
    end
  end

  def test_pointer_string_regex_pattern
    # Test the regex pattern used for detecting MongoDB pointer strings
    valid_patterns = ["Team$abc123", "User$def456", "MyClass$12345abc", "A$1"]
    invalid_patterns = ["$missing_class", "MissingId$", "no-dollar", "Team$", "$123", "Class$$double"]
    
    valid_patterns.each do |pattern|
      assert pattern.match(/^[A-Za-z]\w*\$[\w\d]+$/), "Pattern #{pattern} should be valid"
      class_name, object_id = pattern.split('$', 2)
      assert class_name && object_id, "Pattern #{pattern} should split correctly"
      refute class_name.empty?, "Class name should not be empty for #{pattern}"
      refute object_id.empty?, "Object ID should not be empty for #{pattern}"
    end
    
    invalid_patterns.each do |pattern|
      refute pattern.match(/^[A-Za-z]\w*\$[\w\d]+$/), "Pattern #{pattern} should be invalid"
    end
  end

  private

  def mock_aggregation(values)
    mock_agg = Minitest::Mock.new
    raw_results = values.map { |v| { "value" => v } }
    mock_agg.expect :raw, raw_results
    mock_agg
  end
end