# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/autorun"

# Test model for collection proxy as_json testing
class CollectionTestSong < Parse::Object
  parse_class "CollectionTestSong"
  property :title, :string
  property :tags, :array           # Regular array (strings)
  property :related_songs, :array  # Array that will contain pointers
end

class CollectionProxyAsJsonTest < Minitest::Test
  def setup
    @song1 = CollectionTestSong.new(id: "song123", title: "Song 1")
    @song2 = CollectionTestSong.new(id: "song456", title: "Song 2")
    @pointer1 = Parse::Pointer.new("CollectionTestSong", "song789")
  end

  # === Regular Arrays (Primitives) ===

  def test_as_json_with_string_array
    proxy = Parse::CollectionProxy.new(["rock", "pop", "jazz"])

    result = proxy.as_json

    assert_equal ["rock", "pop", "jazz"], result
  end

  def test_as_json_with_integer_array
    proxy = Parse::CollectionProxy.new([1, 2, 3, 100])

    result = proxy.as_json

    assert_equal [1, 2, 3, 100], result
  end

  def test_as_json_with_mixed_primitives
    proxy = Parse::CollectionProxy.new(["hello", 42, true, 3.14])

    result = proxy.as_json

    assert_equal ["hello", 42, true, 3.14], result
  end

  def test_as_json_with_empty_array
    proxy = Parse::CollectionProxy.new([])

    result = proxy.as_json

    assert_equal [], result
  end

  # === Default behavior (full objects for API responses) ===

  def test_as_json_default_preserves_full_objects
    proxy = Parse::CollectionProxy.new([@song1, @song2])

    result = proxy.as_json

    # Default: should preserve full object serialization
    assert_equal 2, result.length
    # Objects serialize via their as_json which includes objectId
    result.each do |item|
      assert item.is_a?(Hash)
      assert item["objectId"].present? || item[:objectId].present?
    end
  end

  # === pointers_only: true (for storage/Parse webhooks) ===

  def test_as_json_pointers_only_converts_parse_objects
    proxy = Parse::CollectionProxy.new([@song1, @song2])

    result = proxy.as_json(pointers_only: true)

    expected = [
      { "__type" => "Pointer", "className" => "CollectionTestSong", "objectId" => "song123" },
      { "__type" => "Pointer", "className" => "CollectionTestSong", "objectId" => "song456" },
    ]
    assert_equal expected, result
  end

  def test_as_json_pointers_only_converts_single_object
    proxy = Parse::CollectionProxy.new([@song1])

    result = proxy.as_json(pointers_only: true)

    assert_equal 1, result.length
    assert_equal "Pointer", result[0]["__type"]
    assert_equal "CollectionTestSong", result[0]["className"]
    assert_equal "song123", result[0]["objectId"]
  end

  def test_as_json_pointers_only_converts_pointers
    proxy = Parse::CollectionProxy.new([@pointer1])

    result = proxy.as_json(pointers_only: true)

    expected = [
      { "__type" => "Pointer", "className" => "CollectionTestSong", "objectId" => "song789" },
    ]
    assert_equal expected, result
  end

  def test_as_json_pointers_only_with_mixed_objects_and_pointers
    proxy = Parse::CollectionProxy.new([@song1, @pointer1, @song2])

    result = proxy.as_json(pointers_only: true)

    assert_equal 3, result.length
    result.each do |item|
      assert_equal "Pointer", item["__type"]
      assert_equal "CollectionTestSong", item["className"]
      assert item["objectId"].present?
    end
  end

  def test_as_json_pointers_only_preserves_primitives
    proxy = Parse::CollectionProxy.new(["rock", "pop", 42])

    result = proxy.as_json(pointers_only: true)

    # Primitives don't respond to :pointer, so they stay as-is
    assert_equal ["rock", "pop", 42], result
  end

  # === Hash Values ===

  def test_as_json_with_hash_values
    proxy = Parse::CollectionProxy.new([{ key: "value" }, { foo: "bar" }])

    result = proxy.as_json

    assert_equal [{ "key" => "value" }, { "foo" => "bar" }], result
  end

  # === Verify pointer format is correct ===

  def test_pointer_format_has_correct_keys
    proxy = Parse::CollectionProxy.new([@song1])

    result = proxy.as_json(pointers_only: true)

    assert_equal %w[__type className objectId].sort, result[0].keys.sort
  end

  # === PointerCollectionProxy backwards compatibility ===

  def test_pointer_collection_proxy_still_works
    proxy = Parse::PointerCollectionProxy.new([@song1, @song2])

    result = proxy.as_json

    # PointerCollectionProxy always converts to pointers
    assert_equal 2, result.length
    result.each do |item|
      assert_equal "Pointer", item["__type"]
    end
  end

  # === String option key works too ===

  def test_as_json_pointers_only_with_string_key
    proxy = Parse::CollectionProxy.new([@song1])

    result = proxy.as_json("pointers_only" => true)

    assert_equal "Pointer", result[0]["__type"]
  end
end

# Test model for pointer collection proxy testing with has_many :through => :array
class PointerCollectionTestCapture < Parse::Object
  parse_class "PointerCollectionTestCapture"
  property :title, :string
  has_many :assets, through: :array, as: :pointer_collection_test_asset
end

class PointerCollectionTestAsset < Parse::Object
  parse_class "PointerCollectionTestAsset"
  property :caption, :string
  property :file_url, :string
  property :thumbnail_url, :string
end

class PointerCollectionProxyAsJsonTest < Minitest::Test
  def setup
    # Create "fetched" objects with timestamps (not pointer state)
    @asset1 = PointerCollectionTestAsset.new(
      "objectId" => "asset123",
      "caption" => "Photo 1",
      "fileUrl" => "https://example.com/photo1.jpg",
      "thumbnailUrl" => "https://example.com/thumb1.jpg",
      "createdAt" => "2024-01-01T00:00:00.000Z",
      "updatedAt" => "2024-01-01T00:00:00.000Z"
    )
    @asset2 = PointerCollectionTestAsset.new(
      "objectId" => "asset456",
      "caption" => "Photo 2",
      "fileUrl" => "https://example.com/photo2.jpg",
      "thumbnailUrl" => "https://example.com/thumb2.jpg",
      "createdAt" => "2024-01-01T00:00:00.000Z",
      "updatedAt" => "2024-01-01T00:00:00.000Z"
    )
    @pointer_only = PointerCollectionTestAsset.new("asset789") # Pointer-only (just objectId)
  end

  # === Default behavior (backward compatible - returns pointers) ===

  def test_as_json_default_returns_pointers
    proxy = Parse::PointerCollectionProxy.new([@asset1, @asset2])

    result = proxy.as_json

    # Default: should return pointers for backward compatibility
    assert_equal 2, result.length
    result.each do |item|
      assert_equal "Pointer", item["__type"]
      assert_equal "PointerCollectionTestAsset", item["className"]
    end
  end

  def test_as_json_default_with_single_object
    proxy = Parse::PointerCollectionProxy.new([@asset1])

    result = proxy.as_json

    assert_equal 1, result.length
    assert_equal "Pointer", result[0]["__type"]
    assert_equal "PointerCollectionTestAsset", result[0]["className"]
    assert_equal "asset123", result[0]["objectId"]
  end

  # === pointers_only: false (serialize full objects) ===

  def test_as_json_pointers_only_false_returns_full_objects
    proxy = Parse::PointerCollectionProxy.new([@asset1, @asset2])

    result = proxy.as_json(pointers_only: false)

    # Should serialize full objects, not pointers
    assert_equal 2, result.length
    result.each do |item|
      assert item.is_a?(Hash)
      # Should NOT have __type: Pointer
      refute_equal "Pointer", item["__type"]
      # Should have objectId
      assert item["objectId"].present?
    end
  end

  def test_as_json_pointers_only_false_includes_fetched_fields
    proxy = Parse::PointerCollectionProxy.new([@asset1])

    result = proxy.as_json(pointers_only: false)

    assert_equal 1, result.length
    item = result[0]

    # Should include the fields that were set
    assert_equal "asset123", item["objectId"]
    assert_equal "Photo 1", item["caption"]
    assert_equal "https://example.com/photo1.jpg", item["fileUrl"]
    assert_equal "https://example.com/thumb1.jpg", item["thumbnailUrl"]
  end

  def test_as_json_pointers_only_false_with_pointer_only_object_returns_pointer
    proxy = Parse::PointerCollectionProxy.new([@pointer_only])

    result = proxy.as_json(pointers_only: false)

    # Pointer-only objects should still return as pointers
    assert_equal 1, result.length
    item = result[0]
    assert_equal "Pointer", item["__type"]
    assert_equal "PointerCollectionTestAsset", item["className"]
    assert_equal "asset789", item["objectId"]
  end

  def test_as_json_pointers_only_false_mixed_hydrated_and_pointers
    proxy = Parse::PointerCollectionProxy.new([@asset1, @pointer_only, @asset2])

    result = proxy.as_json(pointers_only: false)

    assert_equal 3, result.length

    # First item: hydrated object
    assert_equal "asset123", result[0]["objectId"]
    assert_equal "Photo 1", result[0]["caption"]
    refute_equal "Pointer", result[0]["__type"]

    # Second item: pointer-only, should remain a pointer
    assert_equal "Pointer", result[1]["__type"]
    assert_equal "asset789", result[1]["objectId"]

    # Third item: hydrated object
    assert_equal "asset456", result[2]["objectId"]
    assert_equal "Photo 2", result[2]["caption"]
    refute_equal "Pointer", result[2]["__type"]
  end

  # === pointers_only: true (explicit) ===

  def test_as_json_pointers_only_true_returns_pointers
    proxy = Parse::PointerCollectionProxy.new([@asset1, @asset2])

    result = proxy.as_json(pointers_only: true)

    assert_equal 2, result.length
    result.each do |item|
      assert_equal "Pointer", item["__type"]
    end
  end

  # === only_fetched option (prevents autofetch) ===

  def test_as_json_pointers_only_false_defaults_only_fetched_true
    # Create a partially fetched object by setting selective keys
    partial_asset = PointerCollectionTestAsset.new(
      "objectId" => "partial123",
      "caption" => "Partial Photo"
    )
    # Mark it as selectively fetched (uses @_fetched_keys internally)
    partial_asset.instance_variable_set(:@_fetched_keys, Set.new([:id, :caption]))

    proxy = Parse::PointerCollectionProxy.new([partial_asset])

    # With pointers_only: false, only_fetched defaults to true
    result = proxy.as_json(pointers_only: false)

    assert_equal 1, result.length
    item = result[0]
    # Should include fetched fields
    assert_equal "partial123", item["objectId"]
    assert_equal "Partial Photo", item["caption"]
  end

  def test_as_json_can_override_only_fetched
    proxy = Parse::PointerCollectionProxy.new([@asset1])

    # Explicitly set only_fetched: false
    result = proxy.as_json(pointers_only: false, only_fetched: false)

    assert_equal 1, result.length
    assert_equal "Photo 1", result[0]["caption"]
  end

  # === String option keys work ===

  def test_as_json_pointers_only_false_with_string_key
    proxy = Parse::PointerCollectionProxy.new([@asset1])

    result = proxy.as_json("pointers_only" => false)

    assert_equal 1, result.length
    refute_equal "Pointer", result[0]["__type"]
    assert_equal "Photo 1", result[0]["caption"]
  end

  # === Empty collection ===

  def test_as_json_empty_collection
    proxy = Parse::PointerCollectionProxy.new([])

    result_default = proxy.as_json
    result_full = proxy.as_json(pointers_only: false)

    assert_equal [], result_default
    assert_equal [], result_full
  end
end
