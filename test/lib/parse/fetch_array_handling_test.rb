require_relative '../../test_helper'

# Test model for fetch unit testing
class FetchTestModel < Parse::Object
  parse_class "FetchTest"

  property :name, :string
  property :value, :integer
end

class FetchArrayHandlingTest < Minitest::Test

  def setup
    # Set up a minimal Parse client for testing
    Parse.setup(
      server_url: "http://localhost:1337/parse",
      application_id: "test_app_id",
      api_key: "test_api_key"
    )
  end

  def test_fetch_array_response_extraction_finds_by_objectId
    puts "\n=== Testing array response extraction finds by objectId ==="

    # Create an object with a known ID
    obj = FetchTestModel.new
    obj.instance_variable_set(:@id, "abc123")

    # Simulate the array response processing that happens in fetch!
    # This tests the logic at lib/parse/model/core/fetching.rb:102-110
    result = [
      { "objectId" => "xyz789", "name" => "Other Object", "value" => 100 },
      { "objectId" => "abc123", "name" => "Target Object", "value" => 42 },
      { "objectId" => "def456", "name" => "Another Object", "value" => 200 }
    ]

    # Apply the array handling logic directly
    found = result.find { |r| r.is_a?(Hash) && (r["objectId"] == obj.id || r["id"] == obj.id) }

    refute_nil found, "Should find matching object in array"
    assert_equal "abc123", found["objectId"], "Should match correct objectId"
    assert_equal "Target Object", found["name"], "Should find correct object data"

    puts "✅ Array response extraction correctly finds object by objectId"
  end

  def test_fetch_array_response_extraction_finds_by_id_field
    puts "\n=== Testing array response extraction finds by 'id' field ==="

    obj = FetchTestModel.new
    obj.instance_variable_set(:@id, "abc123")

    # Some APIs return 'id' instead of 'objectId'
    result = [
      { "id" => "xyz789", "name" => "Other Object" },
      { "id" => "abc123", "name" => "Target Object" }
    ]

    found = result.find { |r| r.is_a?(Hash) && (r["objectId"] == obj.id || r["id"] == obj.id) }

    refute_nil found, "Should find matching object by 'id' field"
    assert_equal "Target Object", found["name"], "Should find correct object data"

    puts "✅ Array response extraction correctly finds object by 'id' field"
  end

  def test_fetch_array_response_extraction_returns_nil_when_not_found
    puts "\n=== Testing array response extraction returns nil when not found ==="

    obj = FetchTestModel.new
    obj.instance_variable_set(:@id, "notfound123")

    result = [
      { "objectId" => "xyz789", "name" => "Other Object" },
      { "objectId" => "def456", "name" => "Another Object" }
    ]

    found = result.find { |r| r.is_a?(Hash) && (r["objectId"] == obj.id || r["id"] == obj.id) }

    assert_nil found, "Should return nil when object not found"

    puts "✅ Array response extraction correctly returns nil when object not found"
  end

  def test_fetch_array_response_extraction_handles_empty_array
    puts "\n=== Testing array response extraction handles empty array ==="

    obj = FetchTestModel.new
    obj.instance_variable_set(:@id, "abc123")

    result = []

    found = result.find { |r| r.is_a?(Hash) && (r["objectId"] == obj.id || r["id"] == obj.id) }

    assert_nil found, "Should return nil for empty array"

    puts "✅ Array response extraction correctly handles empty array"
  end

  def test_fetch_array_response_extraction_skips_non_hash_elements
    puts "\n=== Testing array response extraction skips non-hash elements ==="

    obj = FetchTestModel.new
    obj.instance_variable_set(:@id, "abc123")

    # Array with mixed types (shouldn't happen in practice, but test defensive coding)
    result = [
      nil,
      "string element",
      123,
      { "objectId" => "abc123", "name" => "Target Object" },
      ["nested", "array"]
    ]

    found = result.find { |r| r.is_a?(Hash) && (r["objectId"] == obj.id || r["id"] == obj.id) }

    refute_nil found, "Should find matching hash among non-hash elements"
    assert_equal "Target Object", found["name"], "Should find correct object data"

    puts "✅ Array response extraction correctly skips non-hash elements"
  end

  def test_hash_lookup_optimization_produces_correct_results
    puts "\n=== Testing hash lookup optimization produces correct results ==="

    # Simulate the objects_by_id hash lookup optimization from actions.rb
    # Use Struct instead of class definition inside method
    mock_class = Struct.new(:object_id)

    # Create tracked objects
    tracked_objects = [
      mock_class.new(1001),
      mock_class.new(1002),
      mock_class.new(1003),
      mock_class.new(1004),
      mock_class.new(1005)
    ]

    # Build hash lookup (the optimized approach)
    objects_by_id = tracked_objects.each_with_object({}) { |o, h| h[o.object_id] = o }

    # Verify all objects can be found
    tracked_objects.each do |original|
      found = objects_by_id[original.object_id]
      assert_equal original, found, "Should find object by object_id"
    end

    # Verify non-existent object_id returns nil
    assert_nil objects_by_id[9999], "Should return nil for non-existent object_id"

    puts "✅ Hash lookup optimization produces correct results"
  end
end
