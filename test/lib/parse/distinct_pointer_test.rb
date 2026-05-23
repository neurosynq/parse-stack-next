require_relative "../../test_helper"

class TestDistinctPointer < Minitest::Test

  def setup
    @mock_client = Minitest::Mock.new
    @query = Parse::Query.new("Asset")
    @query.client = @mock_client
  end

  def test_distinct_with_pointer_field_returns_strings_by_default
    # Mock response with MongoDB string format
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :result, [
      { "value" => "Team$abc123" },
      { "value" => "Team$def456" },
      { "value" => "Team$ghi789" }
    ]
    # Define respond_to? to return true for the methods we expect
    def mock_response.respond_to?(method)
      [:error?, :result].include?(method) || super
    end
    
    expected_pipeline = [
      { "$group" => { "_id" => "$project" } },
      { "$project" => { "_id" => 0, "value" => "$_id" } }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && pipeline.is_a?(Array)
    end
    
    result = @query.distinct(:project)
    
    # Should return object IDs as strings by default (extracted from MongoDB pointer format)
    assert_equal 3, result.size
    assert_kind_of String, result.first
    assert_equal "abc123", result.first
    assert_equal "def456", result[1]
    assert_equal "ghi789", result[2]
    
    @mock_client.verify
    mock_response.verify
  end

  def test_distinct_with_non_pointer_field_returns_values_as_is
    # Mock response with regular string values
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :result, [
      { "value" => "video" },
      { "value" => "image" },
      { "value" => "audio" }
    ]
    # Define respond_to? to return true for the methods we expect
    def mock_response.respond_to?(method)
      [:error?, :result].include?(method) || super
    end
    
    expected_pipeline = [
      { "$group" => { "_id" => "$category" } },
      { "$project" => { "_id" => 0, "value" => "$_id" } }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && pipeline.is_a?(Array)
    end
    
    result = @query.distinct(:category)
    
    # Should return strings as-is
    assert_equal ["video", "image", "audio"], result
    assert_kind_of String, result.first
    
    @mock_client.verify
    mock_response.verify
  end

  def test_distinct_with_return_pointers_true_uses_to_pointers_method
    # Mock response with mixed formats
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :result, [
      { "value" => "Team$abc123" },
      { "value" => "Team$def456" }
    ]
    # Define respond_to? to return true for the methods we expect
    def mock_response.respond_to?(method)
      [:error?, :result].include?(method) || super
    end
    
    expected_pipeline = [
      { "$group" => { "_id" => "$project" } },
      { "$project" => { "_id" => 0, "value" => "$_id" } }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && pipeline.is_a?(Array)
    end
    
    result = @query.distinct(:project, return_pointers: true)
    
    # Should explicitly use to_pointers method
    assert_equal 2, result.size
    assert_kind_of Parse::Pointer, result.first
    assert_equal "Team", result.first.parse_class
    assert_equal "abc123", result.first.id
    
    @mock_client.verify
    mock_response.verify
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

  def test_distinct_does_not_convert_invalid_string_formats
    # Mock response with non-pointer strings
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, false
    mock_response.expect :result, [
      { "value" => "not-a-pointer" },
      { "value" => "also$not$valid" },
      { "value" => "$invalid" }
    ]
    # Define respond_to? to return true for the methods we expect
    def mock_response.respond_to?(method)
      [:error?, :result].include?(method) || super
    end
    
    expected_pipeline = [
      { "$group" => { "_id" => "$name" } },
      { "$project" => { "_id" => 0, "value" => "$_id" } }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response do |table, pipeline, **kwargs|
      table == "Asset" && pipeline.is_a?(Array)
    end
    
    result = @query.distinct(:name)
    
    # Should return strings as-is since they don't match pointer format
    assert_equal ["not-a-pointer", "also$not$valid", "$invalid"], result
    assert_kind_of String, result.first
    
    @mock_client.verify
    mock_response.verify
  end
end