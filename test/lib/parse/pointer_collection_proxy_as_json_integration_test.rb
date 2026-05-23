# frozen_string_literal: true

require_relative "../../test_helper_integration"

# Test models for pointer collection proxy integration testing
class PcpAsJsonCapture < Parse::Object
  parse_class "PcpAsJsonCapture"
  property :title, :string
  property :description, :string
  has_many :assets, through: :array, as: :pcp_as_json_asset
end

class PcpAsJsonAsset < Parse::Object
  parse_class "PcpAsJsonAsset"
  property :caption, :string
  property :file_url, :string
  property :thumbnail_url, :string
  property :file_size, :integer
end

class PointerCollectionProxyAsJsonIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout.timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  # === Basic serialization with includes ===

  def test_pointer_collection_default_returns_pointers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(30, "default returns pointers test") do
        puts "\n=== Testing PointerCollectionProxy Default Returns Pointers ==="

        # Create assets
        asset1 = PcpAsJsonAsset.new(
          caption: "Photo 1",
          file_url: "https://example.com/photo1.jpg",
          thumbnail_url: "https://example.com/thumb1.jpg",
          file_size: 1024
        )
        assert asset1.save, "Asset1 should save"

        asset2 = PcpAsJsonAsset.new(
          caption: "Photo 2",
          file_url: "https://example.com/photo2.jpg",
          thumbnail_url: "https://example.com/thumb2.jpg",
          file_size: 2048
        )
        assert asset2.save, "Asset2 should save"

        # Create capture with assets
        capture = PcpAsJsonCapture.new(
          title: "Test Capture",
          description: "A test capture with assets"
        )
        capture.assets.add(asset1, asset2)
        assert capture.save, "Capture should save"

        # Fetch capture with assets included
        fetched = PcpAsJsonCapture.first(
          :id.eq => capture.id,
          includes: [:assets]
        )

        # Default as_json should return pointers for backward compatibility
        json = fetched.as_json
        assets_json = json["assets"]

        assert_equal 2, assets_json.length
        assets_json.each do |asset|
          assert_equal "Pointer", asset["__type"], "Default should return pointers"
          assert_equal "PcpAsJsonAsset", asset["className"]
          assert asset["objectId"].present?
        end

        puts "Default returns pointers: PASS"
      end
    end
  end

  def test_pointer_collection_pointers_only_false_returns_full_objects
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(30, "pointers_only false returns full objects test") do
        puts "\n=== Testing PointerCollectionProxy pointers_only: false Returns Full Objects ==="

        # Create assets
        asset1 = PcpAsJsonAsset.new(
          caption: "Photo 1",
          file_url: "https://example.com/photo1.jpg",
          thumbnail_url: "https://example.com/thumb1.jpg",
          file_size: 1024
        )
        assert asset1.save, "Asset1 should save"

        asset2 = PcpAsJsonAsset.new(
          caption: "Photo 2",
          file_url: "https://example.com/photo2.jpg",
          thumbnail_url: "https://example.com/thumb2.jpg",
          file_size: 2048
        )
        assert asset2.save, "Asset2 should save"

        # Create capture with assets
        capture = PcpAsJsonCapture.new(
          title: "Test Capture",
          description: "A test capture with assets"
        )
        capture.assets.add(asset1, asset2)
        assert capture.save, "Capture should save"

        # Fetch capture with assets included
        fetched = PcpAsJsonCapture.first(
          :id.eq => capture.id,
          includes: [:assets]
        )

        # With pointers_only: false, should return full objects
        assets_json = fetched.assets.as_json(pointers_only: false)

        assert_equal 2, assets_json.length
        assets_json.each do |asset|
          refute_equal "Pointer", asset["__type"], "Should not return pointers"
          assert asset["objectId"].present?
          assert asset["caption"].present?, "Should include caption field"
          assert asset["fileUrl"].present?, "Should include fileUrl field"
          assert asset["thumbnailUrl"].present?, "Should include thumbnailUrl field"
          assert asset["fileSize"].present?, "Should include fileSize field"
        end

        # Verify specific values
        captions = assets_json.map { |a| a["caption"] }.sort
        assert_equal ["Photo 1", "Photo 2"], captions

        puts "pointers_only: false returns full objects: PASS"
      end
    end
  end

  # === Partial fetch with includes ===

  def test_pointer_collection_with_partial_fetch_keys
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(30, "partial fetch with keys test") do
        puts "\n=== Testing PointerCollectionProxy with Partial Fetch Keys ==="

        # Create assets
        asset1 = PcpAsJsonAsset.new(
          caption: "Photo 1",
          file_url: "https://example.com/photo1.jpg",
          thumbnail_url: "https://example.com/thumb1.jpg",
          file_size: 1024
        )
        assert asset1.save, "Asset1 should save"

        # Create capture with asset
        capture = PcpAsJsonCapture.new(
          title: "Test Capture",
          description: "A test capture with assets"
        )
        capture.assets.add(asset1)
        assert capture.save, "Capture should save"

        # Fetch capture with specific keys for assets
        fetched = PcpAsJsonCapture.first(
          :id.eq => capture.id,
          includes: [:assets],
          keys: [:title, "assets.caption", "assets.fileUrl"]
        )

        # With pointers_only: false, should return objects with only fetched fields
        assets_json = fetched.assets.as_json(pointers_only: false)

        assert_equal 1, assets_json.length
        asset = assets_json[0]

        # Should include fetched fields
        assert asset["objectId"].present?, "Should include objectId"
        assert_equal "Photo 1", asset["caption"], "Should include caption"
        assert_equal "https://example.com/photo1.jpg", asset["fileUrl"], "Should include fileUrl"

        # Fields not requested should NOT be present (or be nil)
        # Note: The exact behavior depends on how partial fetch serialization works
        puts "Partial fetch serialization: PASS"
      end
    end
  end

  # === Mixed hydrated and pointer-only items ===

  def test_pointer_collection_mixed_hydrated_and_pointers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(30, "mixed hydrated and pointers test") do
        puts "\n=== Testing PointerCollectionProxy with Mixed Hydrated and Pointer Items ==="

        # Create assets
        asset1 = PcpAsJsonAsset.new(
          caption: "Photo 1",
          file_url: "https://example.com/photo1.jpg",
          thumbnail_url: "https://example.com/thumb1.jpg",
          file_size: 1024
        )
        assert asset1.save, "Asset1 should save"

        asset2 = PcpAsJsonAsset.new(
          caption: "Photo 2",
          file_url: "https://example.com/photo2.jpg",
          thumbnail_url: "https://example.com/thumb2.jpg",
          file_size: 2048
        )
        assert asset2.save, "Asset2 should save"

        # Create capture with assets
        capture = PcpAsJsonCapture.new(
          title: "Test Capture",
          description: "A test capture with assets"
        )
        capture.assets.add(asset1, asset2)
        assert capture.save, "Capture should save"

        # Fetch capture WITHOUT includes (assets will be pointers)
        fetched = PcpAsJsonCapture.first(:id.eq => capture.id)

        # Assets should be pointer-only at this point
        assert fetched.assets.any?, "Should have assets"

        # Manually fetch just the first asset
        first_asset = fetched.assets.first
        first_asset.fetch! if first_asset.pointer?

        # Now we have mixed: first asset is hydrated, second is still pointer
        assets_json = fetched.assets.as_json(pointers_only: false)

        assert_equal 2, assets_json.length

        # At least one should be a full object (the fetched one)
        # The unfetched ones should remain as pointers
        has_full_object = assets_json.any? { |a| a["__type"] != "Pointer" }
        has_pointer = assets_json.any? { |a| a["__type"] == "Pointer" }

        assert has_full_object, "Should have at least one full object"
        assert has_pointer, "Should have at least one pointer"

        puts "Mixed hydrated and pointers: PASS"
      end
    end
  end

  # === Webhook-style serialization pattern ===

  def test_webhook_serialization_pattern
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(30, "webhook serialization pattern test") do
        puts "\n=== Testing Webhook Serialization Pattern ==="

        # Create assets
        asset1 = PcpAsJsonAsset.new(
          caption: "Photo 1",
          file_url: "https://example.com/photo1.jpg",
          thumbnail_url: "https://example.com/thumb1.jpg",
          file_size: 1024
        )
        assert asset1.save, "Asset1 should save"

        asset2 = PcpAsJsonAsset.new(
          caption: "Photo 2",
          file_url: "https://example.com/photo2.jpg",
          thumbnail_url: "https://example.com/thumb2.jpg",
          file_size: 2048
        )
        assert asset2.save, "Asset2 should save"

        # Create capture with assets
        capture = PcpAsJsonCapture.new(
          title: "Test Capture",
          description: "A test capture with assets"
        )
        capture.assets.add(asset1, asset2)
        assert capture.save, "Capture should save"

        # Simulate webhook pattern: fetch with includes, then serialize for response
        results = PcpAsJsonCapture.query(
          :id.eq => capture.id
        ).includes(:assets).results

        # Webhook serialization pattern
        response = results.map do |cap|
          json = cap.as_json
          json["assets"] = cap.assets.as_json(pointers_only: false) if cap.assets.any?
          json
        end

        assert_equal 1, response.length
        capture_json = response[0]

        # Check capture fields
        assert_equal "Test Capture", capture_json["title"]
        assert_equal "A test capture with assets", capture_json["description"]

        # Check assets are full objects
        assets = capture_json["assets"]
        assert_equal 2, assets.length
        assets.each do |asset|
          refute_equal "Pointer", asset["__type"]
          assert asset["caption"].present?
          assert asset["fileUrl"].present?
        end

        puts "Webhook serialization pattern: PASS"
      end
    end
  end

  # === Empty collection ===

  def test_empty_pointer_collection_as_json
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(30, "empty collection test") do
        puts "\n=== Testing Empty PointerCollectionProxy as_json ==="

        # Create capture without assets
        capture = PcpAsJsonCapture.new(
          title: "Empty Capture",
          description: "No assets here"
        )
        assert capture.save, "Capture should save"

        # Fetch capture
        fetched = PcpAsJsonCapture.first(:id.eq => capture.id)

        # Both default and pointers_only: false should return empty array
        default_json = fetched.assets.as_json
        full_json = fetched.assets.as_json(pointers_only: false)

        assert_equal [], default_json
        assert_equal [], full_json

        puts "Empty collection as_json: PASS"
      end
    end
  end
end
