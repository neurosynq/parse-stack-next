# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/live_query"

# Define a test model for event tests
class EventTestSong < Parse::Object
  parse_class "Song"
  property :title, :string
  property :artist, :string
  property :plays, :integer
end

class TestLiveQueryEvent < Minitest::Test
  extend Minitest::Spec::DSL

  def setup
    @object_data = {
      "className" => "Song",
      "objectId" => "abc123",
      "title" => "Hey Jude",
      "artist" => "Beatles",
      "plays" => 1000,
      "createdAt" => "2024-01-01T00:00:00.000Z",
      "updatedAt" => "2024-01-02T00:00:00.000Z",
    }

    @original_data = {
      "className" => "Song",
      "objectId" => "abc123",
      "title" => "Hey Jude",
      "artist" => "Beatles",
      "plays" => 500,
      "createdAt" => "2024-01-01T00:00:00.000Z",
      "updatedAt" => "2024-01-01T12:00:00.000Z",
    }
  end

  def test_create_event
    event = Parse::LiveQuery::Event.new(
      type: :create,
      class_name: "Song",
      object_data: @object_data,
      request_id: 1,
    )

    assert event.create?
    refute event.update?
    refute event.delete?
    refute event.enter?
    refute event.leave?

    assert_equal :create, event.type
    assert_equal "Song", event.class_name
    assert_equal 1, event.request_id
    assert_equal "abc123", event.parse_object_id
    assert_nil event.original
    refute_nil event.received_at
  end

  def test_update_event_with_original
    event = Parse::LiveQuery::Event.new(
      type: :update,
      class_name: "Song",
      object_data: @object_data,
      original_data: @original_data,
      request_id: 2,
    )

    assert event.update?
    refute event.create?

    refute_nil event.object
    refute_nil event.original

    # Check that objects are Parse::Object instances
    assert_kind_of Parse::Object, event.object
    assert_kind_of Parse::Object, event.original
  end

  def test_delete_event
    event = Parse::LiveQuery::Event.new(
      type: :delete,
      class_name: "Song",
      object_data: @object_data,
      request_id: 3,
    )

    assert event.delete?
  end

  def test_enter_event
    event = Parse::LiveQuery::Event.new(
      type: :enter,
      class_name: "Song",
      object_data: @object_data,
      original_data: @original_data,
      request_id: 4,
    )

    assert event.enter?
    refute_nil event.original
  end

  def test_leave_event
    event = Parse::LiveQuery::Event.new(
      type: :leave,
      class_name: "Song",
      object_data: @object_data,
      original_data: @original_data,
      request_id: 5,
    )

    assert event.leave?
    refute_nil event.original
  end

  def test_string_type_converted_to_symbol
    event = Parse::LiveQuery::Event.new(
      type: "create",
      class_name: "Song",
      object_data: @object_data,
      request_id: 6,
    )

    assert_equal :create, event.type
    assert event.create?
  end

  def test_to_h
    event = Parse::LiveQuery::Event.new(
      type: :update,
      class_name: "Song",
      object_data: @object_data,
      original_data: @original_data,
      request_id: 7,
    )

    hash = event.to_h

    assert_equal :update, hash[:type]
    assert_equal "Song", hash[:class_name]
    assert_equal "abc123", hash[:object_id]
    assert_equal 7, hash[:request_id]
    refute_nil hash[:received_at]
    refute_nil hash[:object]
    refute_nil hash[:original]
  end

  def test_raw_payload_preserved
    raw = { "op" => "create", "extra" => "data" }

    event = Parse::LiveQuery::Event.new(
      type: :create,
      class_name: "Song",
      object_data: @object_data,
      request_id: 8,
      raw: raw,
    )

    assert_equal raw, event.raw
  end

  def test_nil_object_data
    event = Parse::LiveQuery::Event.new(
      type: :delete,
      class_name: "Song",
      object_data: nil,
      request_id: 9,
    )

    assert_nil event.object
    assert_nil event.parse_object_id
  end
end
