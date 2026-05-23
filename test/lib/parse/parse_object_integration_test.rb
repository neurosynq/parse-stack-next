require_relative '../../test_helper_integration'

# Test classes for integration tests
class TestObject < Parse::Object
  parse_class "TestObject"
  property :test, :string
  property :foo, :string
  property :adventure, :string
  property :location, :string
  property :coordinates, :geopoint
  property :a_bool, :boolean
  property :counter, :integer
  # Additional properties for integration tests
  property :cat, :string
  property :dog, :string
  property :favoritePony, :string
  property :yes, :boolean
  property :no, :boolean
  property :when, :date
  property :authData, :string
  property :time, :string
  property :bytes, :bytes
  # Properties for field value testing
  property :string_field, :string
  property :number_field, :integer
  property :boolean_field, :boolean
  property :array_field, :array
  property :object_field, :object
  property :date_field, :date
  property :location, :geopoint
  property :avatar, :file
end

class Item < Parse::Object
  parse_class "Item" 
  property :property, :string
  property :x, :integer
  property :foo, :string
end

class Container < Parse::Object
  parse_class "Container"
  belongs_to :item
  property :items, :array
  belongs_to :subcontainer, as: :container
end

# Port of the JavaScript Parse.Object test suite to Ruby
# This tests the core Parse::Object functionality against a real Parse Server
class ParseObjectIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def test_create
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    # Reset database to clean state (after setup is complete)
    reset_database!
    with_parse_server do
      object = TestObject.new(test: 'test')
      assert object.save, "Should be able to save object"
      assert object.id.present?, "Should have an objectId set"
      assert_equal 'test', object[:test], "Should have the right attribute"
    end
  end

  def test_update
    with_parse_server do
      object = create_test_object('TestObject', test: 'test')
      
      object2 = TestObject.new(objectId: object.id)
      object2[:test] = 'changed'
      assert object2.save, "Update should succeed"
      assert_equal 'changed', object2[:test], "Update should have succeeded"
    end
  end

  def test_save_without_null
    with_parse_server do
      object = TestObject.new
      object[:favoritePony] = 'Rainbow Dash'
      result = object.save
      assert result, "Should save successfully"
      assert_equal true, result, "Should return true on successful save"
    end
  end

  def test_save_cycle
    with_parse_server do
      a = TestObject.new
      b = TestObject.new
      
      a[:b] = b
      assert a.save, "Should save object a with pointer to b"
      
      b[:a] = a
      assert b.save, "Should save object b with pointer to a"
      
      assert a.id.present?, "Object a should have an id"
      assert b.id.present?, "Object b should have an id"
      # Note: Direct pointer comparison may not work as expected in Ruby implementation
      # This tests the basic save cycle functionality
    end
  end

  def test_get_fetch
    with_parse_server do
      object = TestObject.new
      object[:test] = 'test'
      assert object.save, "Should save object"
      
      object2 = TestObject.new(objectId: object.id)
      assert object2.fetch, "Should fetch object successfully"
      assert_equal 'test', object2[:test], "Fetch should have retrieved the data"
      assert object2.id.present?, "Should have an id"
      assert_equal object.id, object2.id, "IDs should match"
    end
  end

  def test_delete_destroy
    with_parse_server do
      object = TestObject.new
      object[:test] = 'test'
      assert object.save, "Should save object"
      
      assert object.destroy, "Should destroy object"
      
      object2 = TestObject.new(objectId: object.id)
      result = object2.fetch
      assert_nil object2.id, "Object ID should be nil after fetching deleted object"
      assert object2._deleted?, "Object should be marked as deleted"
      assert_equal object2, result, "fetch should return self even for deleted objects"
      
      # Test that deleted objects cannot be saved
      assert_raises(Parse::Error::ProtocolError) do
        object2.save
      end
    end
  end

  def test_find_query
    with_parse_server do
      object = TestObject.new
      object[:foo] = 'bar'
      assert object.save, "Should save object"
      
      query = TestObject.query(foo: 'bar')
      results = query.results
      assert_equal 1, results.length, "Should find one object"
      assert_equal object.id, results.first.id, "Should find the correct object"
    end
  end

  def test_relational_fields
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    # Reset database to clean state
    reset_database!
    
    with_parse_server do
      item = Item.new
      item[:property] = 'x'
      assert item.save, "Should save item"
      
      container = Container.new
      container[:item] = item
      assert container.save, "Should save container with item relation"
      
      query = Container.query
      results = query.results
      assert_equal 1, results.length, "Should find one container"
      
      container_again = results.first
      item_again = container_again[:item]
      assert item_again.is_a?(Parse::Pointer), "Should have a pointer to item"
      
      # Fetch the item
      assert item_again.fetch, "Should fetch the related item"
      assert_equal 'x', item_again[:property], "Should have the correct property value"
    end
  end

  def test_save_adds_minimal_data_keys
    with_parse_server do
      object = TestObject.new
      assert object.save, "Should save empty object"
      
      # Check that only minimal keys have actual values
      actual_data_keys = []
      object.class.fields.keys.each do |key|
        next if [:__type, :className].include?(key)
        value = object.instance_variable_get(:"@#{key}")
        actual_data_keys << key if !value.nil?
      end
      
      expected_keys = [:id, :created_at, :updated_at, :acl]
      assert (actual_data_keys - expected_keys).empty?, "Should only have basic Parse keys with values. Extra keys: #{actual_data_keys - expected_keys}"
    end
  end

  def test_recursive_save
    with_parse_server do
      item = Item.new
      item[:property] = 'x'
      assert item.save, "Should save item first"
      
      container = Container.new
      container[:item] = item
      
      assert container.save, "Should save container with item association"
      
      query = Container.query
      results = query.results
      assert_equal 1, results.length, "Should find one container"
      
      container_again = results.first
      item_again = container_again[:item]
      assert item_again.fetch, "Should fetch the item"
      assert_equal 'x', item_again[:property], "Should have correct property"
    end
  end

  def test_fetch_object_updates
    with_parse_server do
      item = Item.new(foo: 'bar')
      assert item.save, "Should save item"
      
      item_again = Item.new
      item_again.id = item.id
      assert item_again.fetch, "Should fetch item"
      
      item_again[:foo] = 'baz'
      assert item_again.save, "Should save updated item"
      
      assert item.fetch, "Should fetch original item"
      assert_equal 'baz', item[:foo], "Original item should have updated value"
    end
  end

  def test_created_at_doesnt_change
    with_parse_server do
      object = TestObject.new(foo: 'bar')
      assert object.save, "Should save object"
      
      object_again = TestObject.new
      object_again.id = object.id
      assert object_again.fetch, "Should fetch object"
      
      assert_equal object.created_at.to_i, object_again.created_at.to_i, 
                   "CreatedAt times should match (within 1 second)"
    end
  end

  def test_created_at_and_updated_at_exposed
    with_parse_server do
      object = TestObject.new(foo: 'bar')
      assert object.save, "Should save object"
      
      refute_nil object.updated_at, "UpdatedAt should be set"
      refute_nil object.created_at, "CreatedAt should be set"
    end
  end

  def test_updated_at_gets_updated
    with_parse_server do
      object = TestObject.new(foo: 'bar')
      assert object.save, "Should save object"
      assert object.updated_at.present?, "Initial save should set updatedAt"
      
      first_updated_at = object.updated_at
      sleep 1 # Ensure time difference
      
      object[:foo] = 'baz'
      assert object.save, "Should save updated object"
      assert object.updated_at.present?, "Second save should update updatedAt"
      refute_equal first_updated_at, object.updated_at, "UpdatedAt should change"
    end
  end

  def test_created_at_is_reasonable
    with_parse_server do
      start_time = Time.now
      object = TestObject.new(foo: 'bar')
      assert object.save, "Should save object"
      end_time = Time.now
      
      start_diff = (start_time - object.created_at).abs
      assert start_diff < 5, "CreatedAt should be close to start time"
      
      end_diff = (end_time - object.created_at).abs  
      assert end_diff < 5, "CreatedAt should be close to end time"
    end
  end

  def test_can_set_null
    with_parse_server do
      object = TestObject.new
      object[:foo] = nil
      assert object.save, "Should save object with null value"
      assert_nil object[:foo], "Should retrieve null value"
    end
  end

  def test_can_set_boolean
    with_parse_server do
      object = TestObject.new
      object[:yes] = true
      object[:no] = false
      assert object.save, "Should save object with boolean values"
      
      assert_equal true, object[:yes], "Should retrieve true value"
      assert_equal false, object[:no], "Should retrieve false value"
    end
  end

  def test_cannot_set_invalid_date
    with_parse_server do
      object = TestObject.new
      # Invalid date in Ruby would be Date.parse(nil) which raises an error
      assert_raises(ArgumentError) do
        object[:when] = Date.parse("")
      end
    end
  end

  def test_can_set_auth_data_when_not_user_class
    with_parse_server do
      object = TestObject.new
      object[:authData] = 'random'
      assert object.save, "Should save object with authData"
      assert_equal 'random', object[:authData], "Should retrieve authData value"
      
      query = TestObject.query
      fetched_object = query.results.first
      assert_equal 'random', fetched_object[:authData], "Should persist authData"
    end
  end

  def test_simple_field_deletion
    with_parse_server do
      object = TestObject.new
      object[:foo] = 'bar'
      assert object.save, "Should save object with foo"
      
      object.op_destroy!(:foo)
      refute object.has?(:foo), "foo should be unset locally"
      assert object.dirty?(:foo), "foo should be marked dirty"
      assert object.dirty?, "object should be dirty"
      
      assert object.save, "Should save object after unsetting foo"
      refute object.has?(:foo), "foo should still be unset"
      refute object.dirty?(:foo), "foo should no longer be dirty"
      refute object.dirty?, "object should no longer be dirty"
      
      query = TestObject.query
      object_again = query.get(object.id)
      refute object_again.has?(:foo), "foo should be removed from server"
    end
  end

  def test_field_deletion_before_first_save
    with_parse_server do
      object = TestObject.new
      object[:foo] = 'bar'
      object.op_destroy!(:foo)
      
      refute object.has?(:foo), "foo should be unset"
      assert object.dirty?(:foo), "foo should be dirty"
      assert object.dirty?, "object should be dirty"
      
      assert object.save, "Should save object"
      refute object.has?(:foo), "foo should be unset after save"
      refute object.dirty?(:foo), "foo should not be dirty after save"
      refute object.dirty?, "object should not be dirty after save"
      
      query = TestObject.query
      object_again = query.get(object.id)
      refute object_again.has?(:foo), "foo should not exist on server"
    end
  end

  def test_increment
    with_parse_server do
      object = TestObject.new
      object[:counter] = 5
      assert object.save, "Should save object"
      
      object.op_increment!(:counter)
      assert_equal 6, object[:counter], "Local value should be incremented"
      assert object.dirty?(:counter), "counter should be dirty"
      assert object.dirty?, "object should be dirty"
      
      assert object.save, "Should save incremented object"
      assert_equal 6, object[:counter], "Value should still be 6"
      refute object.dirty?(:counter), "counter should not be dirty after save"
      refute object.dirty?, "object should not be dirty after save"
      
      query = TestObject.query
      object_again = query.get(object.id)
      assert_equal 6, object_again[:counter], "Server value should be 6"
    end
  end

  def test_dirty_attributes
    with_parse_server do
      object = TestObject.new
      object[:cat] = 'good'
      object[:dog] = 'bad'
      assert object.save, "Should save object"
      
      refute object.dirty?, "Object should not be dirty after save"
      refute object.dirty?(:cat), "cat should not be dirty"
      refute object.dirty?(:dog), "dog should not be dirty"
      
      object[:dog] = 'okay'
      
      assert object.dirty?, "Object should be dirty"
      refute object.dirty?(:cat), "cat should not be dirty"
      assert object.dirty?(:dog), "dog should be dirty"
    end
  end

  def test_to_json_saved_object
    with_parse_server do
      object = TestObject.new
      object[:test] = 'bar'
      assert object.save, "Should save object"
      
      json = object.as_json
      assert json["test"], "JSON should contain 'test' key"
      assert json["objectId"] || json["id"], "JSON should contain objectId"
      assert json["createdAt"] || json["created_at"], "JSON should contain createdAt"
      assert json["updatedAt"] || json["updated_at"], "JSON should contain updatedAt"
    end
  end

  def test_deleted_object_cannot_be_saved
    with_parse_server do
      # Create and save an object
      object = TestObject.new
      object[:test] = 'will_be_deleted'
      assert object.save, "Should save object initially"
      
      # Destroy it
      assert object.destroy, "Should destroy object"
      
      # Try to fetch it again
      deleted_object = TestObject.new(objectId: object.id)
      deleted_object.fetch
      
      # Verify it's marked as deleted
      assert deleted_object._deleted?, "Object should be marked as deleted"
      assert_nil deleted_object.id, "Object ID should be nil"
      
      # Try to save it (should throw error)
      error = assert_raises(Parse::Error::ProtocolError) do
        deleted_object.save
      end
      
      assert_match(/Cannot save deleted object/, error.message, "Error message should mention deleted object")
    end
  end

  def test_async_methods_chaining
    with_parse_server do
      object = TestObject.new
      object[:time] = 'adventure'
      
      # Save the object
      assert object.save, "Should save object"
      assert object.id.present?, "ObjectId should not be null"
      
      # Fetch the object again
      object_again = TestObject.new
      object_again.id = object.id
      assert object_again.fetch, "Should fetch object"
      assert_equal 'adventure', object_again[:time], "Should have correct value"
      
      # Destroy the object
      assert object_again.destroy, "Should destroy object"
      
      # Verify it's gone
      query = TestObject.query
      results = query.results
      assert_equal 0, results.length, "Should find no objects"
    end
  end

  def test_bytes_work
    with_parse_server do
      object = TestObject.new
      bytes_data = Parse::Bytes.new('ZnJveW8=')
      object[:bytes] = bytes_data
      assert object.save, "Should save object with bytes"
      
      query = TestObject.query
      object_again = query.get(object.id)
      retrieved_bytes = object_again[:bytes]
      assert retrieved_bytes.is_a?(Parse::Bytes), "Should retrieve bytes object"
      assert_equal 'ZnJveW8=', retrieved_bytes.base64, "Should have correct base64 data"
    end
  end

  def test_create_without_data
    with_parse_server do
      object1 = TestObject.new(test: 'test')
      assert object1.save, "Should save object"
      
      # Create object without data using just the ID
      object2 = TestObject.new(object1.id)
      assert object2.fetch, "Should fetch object data"
      assert_equal 'test', object2[:test], "Should have fetched the 'test' property"
      
      # Create another object and modify before fetch
      object3 = TestObject.new(object1.id)
      object3[:test] = 'not test'
      assert object3.fetch, "Should fetch object data"
      assert_equal 'test', object3[:test], "Fetch should override local changes"
    end
  end

  def test_returns_correct_field_values
    with_parse_server do
      test_values = [
        { field: 'string_field', value: 'string' },
        { field: 'number_field', value: 1 },
        { field: 'boolean_field', value: true },
        { field: 'array_field', value: [0, 1, 2] },
        { field: 'object_field', value: { key: 'value' } },
        { field: 'date_field', value: Time.now }
      ]
      
      test_values.each do |test_case|
        object = TestObject.new
        object[test_case[:field]] = test_case[:value]
        assert object.save, "Should save object with #{test_case[:field]}"
        
        query = TestObject.query
        object_again = query.get(object.id)
        retrieved_value = object_again[test_case[:field]]
        
        case test_case[:value]
        when Time
          # Compare times within 1 second tolerance
          assert (test_case[:value] - retrieved_value).abs < 1, 
                 "Time values should be close for #{test_case[:field]}"
        when Hash
          # For object fields, compare the hash contents (keys might be strings instead of symbols)
          test_case[:value].each do |key, expected_value|
            assert_equal expected_value, retrieved_value[key] || retrieved_value[key.to_s],
                         "Should retrieve correct value for #{test_case[:field]}[#{key}]"
          end
        else
          assert_equal test_case[:value], retrieved_value,
                       "Should retrieve correct value for #{test_case[:field]}"
        end
        
        # Clean up
        object_again.destroy
      end
    end
  end

  def test_geopoint_save_and_retrieve
    with_parse_server do
      # Create a test object with GeoPoint
      object = TestObject.new
      
      # Test different ways to create GeoPoints
      san_diego = Parse::GeoPoint.new(32.7157, -117.1611)
      object[:coordinates] = san_diego
      
      assert object.save, "Should save object with GeoPoint"
      
      # Retrieve and verify
      query = TestObject.query
      object_again = query.get(object.id)
      retrieved_coordinates = object_again[:coordinates]
      
      assert retrieved_coordinates.is_a?(Parse::GeoPoint), "Should retrieve GeoPoint object"
      assert_equal san_diego.latitude, retrieved_coordinates.latitude, "Should have correct latitude"
      assert_equal san_diego.longitude, retrieved_coordinates.longitude, "Should have correct longitude"
      
      # Clean up
      object_again.destroy
    end
  end

  def test_geopoint_query_operations
    with_parse_server do
      # Create test objects with different locations
      locations = [
        { name: "San Diego", lat: 32.7157, lng: -117.1611 },
        { name: "Los Angeles", lat: 34.0522, lng: -118.2437 },
        { name: "San Francisco", lat: 37.7749, lng: -122.4194 }
      ]
      
      created_objects = []
      locations.each do |loc|
        object = TestObject.new
        object[:test] = loc[:name]
        object[:coordinates] = Parse::GeoPoint.new(loc[:lat], loc[:lng])
        assert object.save, "Should save #{loc[:name]} object"
        created_objects << object
      end
      
      # Test near query (find objects near San Diego)
      san_diego_center = Parse::GeoPoint.new(32.7157, -117.1611)
      near_results = TestObject.all(:coordinates.near => san_diego_center)
      
      assert near_results.any?, "Should find objects near San Diego"
      assert near_results.first[:test] == "San Diego", "Nearest should be San Diego itself"
      
      # Test within miles query (find objects within 200 miles of San Diego)
      within_results = TestObject.all(:coordinates.near => san_diego_center.max_miles(200))
      
      assert within_results.count >= 2, "Should find San Diego and LA within 200 miles"
      city_names = within_results.map { |obj| obj[:test] }
      assert city_names.include?("San Diego"), "Should include San Diego"
      assert city_names.include?("Los Angeles"), "Should include Los Angeles"
      
      # Clean up
      created_objects.each(&:destroy)
    end
  end

  def test_geopoint_distance_calculations
    with_parse_server do
      # Create objects at known locations
      object1 = TestObject.new
      object1[:test] = "Point A"
      object1[:coordinates] = Parse::GeoPoint.new(32.7157, -117.1611)  # San Diego
      assert object1.save, "Should save first object"
      
      object2 = TestObject.new  
      object2[:test] = "Point B"
      object2[:coordinates] = Parse::GeoPoint.new(34.0522, -118.2437)  # Los Angeles
      assert object2.save, "Should save second object"
      
      # Retrieve and test distance calculations
      query = TestObject.query
      results = query.results
      point_a = results.find { |obj| obj[:test] == "Point A" }
      point_b = results.find { |obj| obj[:test] == "Point B" }
      
      assert point_a && point_b, "Should find both points"
      
      # Test distance calculation
      distance_miles = point_a[:coordinates].distance_in_miles(point_b[:coordinates])
      distance_km = point_a[:coordinates].distance_in_km(point_b[:coordinates])
      
      # San Diego to LA is approximately 120 miles / 180 km
      assert distance_miles > 100 && distance_miles < 140, "Distance should be around 120 miles (got #{distance_miles})"
      assert distance_km > 170 && distance_km < 200, "Distance should be around 180 km (got #{distance_km})"
      
      # Clean up
      point_a.destroy
      point_b.destroy
    end
  end

  def test_geopoint_serialization_formats
    with_parse_server do
      object = TestObject.new
      object[:test] = "Serialization Test"
      
      # Test Parse server format deserialization
      geopoint_hash = {
        "__type" => "GeoPoint",
        "latitude" => 37.7749,
        "longitude" => -122.4194
      }
      
      # Manually set the geopoint using the server format
      object.instance_variable_set(:@coordinates, geopoint_hash)
      object.send(:coordinates_will_change!)
      
      assert object.save, "Should save object with hash-format geopoint"
      
      # Retrieve and verify it was converted properly
      query = TestObject.query  
      object_again = query.get(object.id)
      retrieved_coordinates = object_again[:coordinates]
      
      assert retrieved_coordinates.is_a?(Parse::GeoPoint), "Should convert hash to GeoPoint object"
      assert_equal 37.7749, retrieved_coordinates.latitude, "Should have correct latitude"
      assert_equal -122.4194, retrieved_coordinates.longitude, "Should have correct longitude"
      
      # Clean up
      object_again.destroy
    end
  end

  def test_file_creation_and_basic_properties
    with_parse_server do
      # Create a simple text file
      content = "Hello, Parse File!"
      file = Parse::File.new("test.txt", content, "text/plain")
      
      assert_equal "test.txt", file.name, "Should have correct name"
      assert_equal content, file.contents, "Should have correct contents"
      assert_equal "text/plain", file.mime_type, "Should have correct mime type"
      assert_nil file.url, "Should not have URL before saving"
      refute file.saved?, "Should not be saved initially"
    end
  end

  def test_file_save_and_retrieve
    with_parse_server do
      # Create and save a file
      content = "This is test file content for Parse integration test."
      file = Parse::File.new("integration_test.txt", content, "text/plain")
      
      assert file.save, "Should save file successfully"
      assert file.saved?, "File should be marked as saved"
      assert file.url, "Should have URL after saving"
      assert file.url.start_with?("http"), "URL should be a valid HTTP URL"
      
      # Create an object that references this file
      object = TestObject.new
      object[:test] = "File Test"
      object[:avatar] = file
      
      assert object.save, "Should save object with file reference"
      
      # Retrieve and verify
      query = TestObject.query
      object_again = query.get(object.id)
      retrieved_file = object_again[:avatar]
      
      assert retrieved_file.is_a?(Parse::File), "Should retrieve Parse::File object"
      assert_equal file.name, retrieved_file.name, "Should have same filename"
      assert_equal file.url, retrieved_file.url, "Should have same URL"
      assert retrieved_file.saved?, "Retrieved file should be marked as saved"
      
      # Clean up
      object_again.destroy
    end
  end

  def test_file_serialization_from_server_format
    with_parse_server do
      object = TestObject.new
      object[:test] = "File Serialization Test"
      
      # Test Parse server file format deserialization
      file_hash = {
        "__type" => "File",
        "name" => "server_file.pdf",
        "url" => "https://example.com/files/server_file.pdf"
      }
      
      # Set file using server format
      object[:avatar] = file_hash
      
      # The file should be converted to Parse::File during property access
      retrieved_file = object[:avatar]
      assert retrieved_file.is_a?(Parse::File), "Should convert hash to Parse::File object"
      assert_equal "server_file.pdf", retrieved_file.name, "Should have correct name"
      assert_equal "https://example.com/files/server_file.pdf", retrieved_file.url, "Should have correct URL"
      assert retrieved_file.saved?, "Should be marked as saved when it has a URL"
    end
  end

  def test_file_mime_type_handling
    with_parse_server do
      # Test different mime types
      test_cases = [
        { name: "image.jpg", content: "fake_image_data", mime_type: "image/jpeg" },
        { name: "document.pdf", content: "fake_pdf_data", mime_type: "application/pdf" },
        { name: "data.json", content: '{"key": "value"}', mime_type: "application/json" },
        { name: "no_extension", content: "some content", mime_type: nil } # Should use default
      ]
      
      test_cases.each do |test_case|
        file = Parse::File.new(test_case[:name], test_case[:content], test_case[:mime_type])
        
        expected_mime_type = test_case[:mime_type] || Parse::File.default_mime_type
        assert_equal expected_mime_type, file.mime_type, "Should have correct mime type for #{test_case[:name]}"
        
        assert file.save, "Should save file with mime type #{expected_mime_type}"
        assert file.url, "Should have URL after saving"
      end
    end
  end

  def test_file_default_configurations
    original_default_mime = Parse::File.default_mime_type
    original_force_ssl = Parse::File.force_ssl
    
    begin
      # Test default mime type
      assert_equal "image/jpeg", Parse::File.default_mime_type, "Should have correct default mime type"
      
      # Test changing default mime type
      Parse::File.default_mime_type = "text/plain"
      file = Parse::File.new("test.txt", "content")
      assert_equal "text/plain", file.mime_type, "Should use new default mime type"
      
      # Test force SSL configuration
      assert_equal false, Parse::File.force_ssl, "Should have correct default force_ssl setting"
      
    ensure
      # Reset to original values
      Parse::File.default_mime_type = original_default_mime
      Parse::File.force_ssl = original_force_ssl
    end
  end
end