require_relative "../../../test_helper"

class TestSchemaBasedPointer < Minitest::Test
  
  def setup
    @query = Parse::Query.new("TestClass")
    
    # Mock the schema response to include Team class
    mock_response = Object.new
    def mock_response.success?
      true
    end
    def mock_response.result
      {
        "results" => [
          { "className" => "Team" },
          { "className" => "TestClass" },
          { "className" => "Post" }
        ]
      }
    end
    
    # Mock Parse.client.schemas to return our mock response
    mock_client = Object.new
    def mock_client.schemas
      @mock_response
    end
    mock_client.instance_variable_set(:@mock_response, mock_response)
    
    # Override Parse::Client.client(:default) for this test  
    Parse::Client.instance_variable_get(:@clients)[:default] = mock_client
    
    # Reset and reload known parse classes with mocked data
    Parse::Query.reset_known_parse_classes!
  end
  
  def test_convert_pointer_value_with_schema_parse_pointer
    # Test Parse::Pointer conversion
    pointer = Parse::Pointer.new("Team", "team123")
    
    # Test to MongoDB format
    result = @query.send(:convert_pointer_value_with_schema, pointer, :team, to_mongodb_format: true)
    assert_equal "Team$team123", result
    
    # Test to return pointers
    result = @query.send(:convert_pointer_value_with_schema, pointer, :team, return_pointers: true)
    assert_equal pointer, result
    
    # Test default (return object ID)
    result = @query.send(:convert_pointer_value_with_schema, pointer, :team)
    assert_equal "team123", result
  end
  
  def test_convert_pointer_value_with_schema_hash
    # Test pointer hash conversion
    pointer_hash = { "__type" => "Pointer", "className" => "Team", "objectId" => "team123" }
    
    # Test to MongoDB format
    result = @query.send(:convert_pointer_value_with_schema, pointer_hash, :team, to_mongodb_format: true)
    assert_equal "Team$team123", result
    
    # Test to return pointers
    result = @query.send(:convert_pointer_value_with_schema, pointer_hash, :team, return_pointers: true)
    assert result.is_a?(Parse::Pointer)
    assert_equal "Team", result.parse_class
    assert_equal "team123", result.id
    
    # Test default (return object ID)
    result = @query.send(:convert_pointer_value_with_schema, pointer_hash, :team)
    assert_equal "team123", result
  end
  
  def test_convert_pointer_value_with_schema_mongodb_string
    # Test MongoDB format string
    mongo_string = "Team$team123"
    
    # Test to MongoDB format (should stay same)
    result = @query.send(:convert_pointer_value_with_schema, mongo_string, :team, to_mongodb_format: true)
    assert_equal "Team$team123", result
    
    # Test to return pointers
    result = @query.send(:convert_pointer_value_with_schema, mongo_string, :team, return_pointers: true)
    assert result.is_a?(Parse::Pointer)
    assert_equal "Team", result.parse_class
    assert_equal "team123", result.id
    
    # Test default (return object ID)
    result = @query.send(:convert_pointer_value_with_schema, mongo_string, :team)
    assert_equal "team123", result
  end
  
  def test_convert_pointer_value_with_schema_non_pointer_field
    # Test with non-pointer field
    string_value = "regular_string"
    
    # Should pass through unchanged for non-pointer fields
    result = @query.send(:convert_pointer_value_with_schema, string_value, :name)
    assert_equal "regular_string", result
    
    result = @query.send(:convert_pointer_value_with_schema, string_value, :name, return_pointers: true)
    assert_equal "regular_string", result
  end
  
  def test_convert_pointer_value_with_schema_nil_values
    # Test nil handling
    result = @query.send(:convert_pointer_value_with_schema, nil, :team)
    assert_nil result
    
    result = @query.send(:convert_pointer_value_with_schema, "", :team)
    assert_equal "", result
  end
  
  def test_to_pointers_with_field_parameter
    # Test to_pointers with field parameter
    values = [
      Parse::Pointer.new("Team", "team1"),
      { "__type" => "Pointer", "className" => "Team", "objectId" => "team2" },
      "Team$team3"
    ]
    
    result = @query.send(:to_pointers, values, :team)
    
    assert_equal 3, result.length
    assert result.all? { |p| p.is_a?(Parse::Pointer) }
    assert_equal ["team1", "team2", "team3"], result.map(&:id)
    assert result.all? { |p| p.parse_class == "Team" }
  end
  
  def test_to_pointers_backward_compatibility
    # Test that to_pointers still works without field parameter
    values = [
      { "__type" => "Pointer", "className" => "Team", "objectId" => "team1" },
      "Team$team2"
    ]
    
    result = @query.send(:to_pointers, values)
    
    assert_equal 2, result.length
    assert result.all? { |p| p.is_a?(Parse::Pointer) }
    assert_equal ["team1", "team2"], result.map(&:id)
  end
end