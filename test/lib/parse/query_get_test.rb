# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for Parse::Query#get. Verifies the table name is handed to
# Parse::Object.build as a String so its own Parse::Model.find_class lookup
# (which understands `parse_class` aliasing) resolves the record's class
# correctly, instead of pre-resolving to a Class via Object.const_get.
class QueryGetTest < Minitest::Test
  class QueryGetTestMusician < Parse::Object
    parse_class "QueryGetTestArtist"
    property :name, :string
  end

  def mock_client_returning(result)
    mock_client = Object.new
    mock_client.define_singleton_method(:fetch_object) do |klass, id|
      response = Parse::Response.new
      response.result = result
      response
    end
    mock_client
  end

  def test_get_resolves_aliased_parse_class
    query = Parse::Query.new("QueryGetTestArtist")
    mock_client = mock_client_returning("objectId" => "abc123", "name" => "Miles")
    query.define_singleton_method(:client) { mock_client }

    object = query.get("abc123")

    assert_instance_of QueryGetTestMusician, object
    assert_equal "abc123", object.id
    assert_equal "Miles", object.name
  end

  def test_get_returns_pointer_with_correct_class_name_for_unregistered_table
    query = Parse::Query.new("QueryGetTestNoSuchTable")
    mock_client = mock_client_returning("objectId" => "xyz789")
    query.define_singleton_method(:client) { mock_client }

    object = query.get("xyz789")

    assert_instance_of Parse::Pointer, object
    assert_equal "xyz789", object.id
    assert_equal "QueryGetTestNoSuchTable", object.parse_class
  end
end
