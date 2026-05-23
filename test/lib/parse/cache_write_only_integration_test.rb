# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "moneta"

# Integration tests for the write-only cache mode feature
# These tests require Docker with Parse Server running (PARSE_TEST_USE_DOCKER=true)

class WriteOnlyCacheProduct < Parse::Object
  parse_class "WriteOnlyCacheProduct"
  property :name, :string
  property :price, :float
  property :version, :integer
end

class CacheWriteOnlyIntegrationTest < Minitest::Test
  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    # Create a LRU cache with 60 second expiration
    @cache_store = Moneta.new(:LRUHash, expires: 60)

    # Setup Parse client with caching
    Parse::Client.clients.clear
    Parse.setup(
      server_url: "http://localhost:2337/parse",
      app_id: "myAppId",
      api_key: "test-rest-key",
      master_key: "myMasterKey",
      cache: @cache_store,
    )

    # Store original settings
    @original_caching_enabled = Parse::Middleware::Caching.enabled
    @original_logging = Parse::Middleware::Caching.logging
    @original_cache_write_on_fetch = Parse.cache_write_on_fetch

    # Enable caching
    Parse::Middleware::Caching.enabled = true
    Parse::Middleware::Caching.logging = true
    Parse.cache_write_on_fetch = true

    # Check server availability
    begin
      uri = URI("http://localhost:2337/parse/health")
      response = Net::HTTP.get_response(uri)
      skip "Parse Server not available" unless response.code == "200"
    rescue StandardError => e
      skip "Parse Server not available: #{e.message}"
    end
  end

  def teardown
    # Restore original settings
    Parse::Middleware::Caching.enabled = @original_caching_enabled if defined?(@original_caching_enabled)
    Parse::Middleware::Caching.logging = @original_logging if defined?(@original_logging)
    Parse.cache_write_on_fetch = @original_cache_write_on_fetch if defined?(@original_cache_write_on_fetch)
    @cache_store&.clear
  end

  # ============================================================
  # Tests for fetch! with write-only cache mode
  # ============================================================

  def test_fetch_write_only_gets_fresh_data_but_updates_cache
    puts "\n=== Test: fetch! write-only gets fresh data but updates cache ==="

    # Create a product
    product = WriteOnlyCacheProduct.new(name: "Write Only Test", price: 19.99, version: 1)
    assert product.save, "Product should save successfully"
    product_id = product.id

    # First, populate the cache with a cached read
    puts "Step 1: Populate cache with find_cached"
    cached_product = WriteOnlyCacheProduct.find_cached(product_id)
    assert_equal "Write Only Test", cached_product.name

    # Update the product directly via another save (simulating external update)
    puts "Step 2: Update product directly (simulating external change)"
    product.name = "Updated Name"
    product.version = 2
    assert product.save

    # Now fetch with write-only (default behavior)
    # Should get fresh data, not cached data
    puts "Step 3: fetch! should get fresh data (not cached)"
    fresh_product = WriteOnlyCacheProduct.new
    fresh_product.id = product_id
    fresh_product.fetch!

    assert_equal "Updated Name", fresh_product.name,
      "fetch! should return fresh data, not cached data"
    assert_equal 2, fresh_product.version

    # Verify the cache was updated with fresh data
    puts "Step 4: Verify cache was updated with fresh data"
    # Using find_cached should now return the updated data
    cached_after = WriteOnlyCacheProduct.find_cached(product_id)
    assert_equal "Updated Name", cached_after.name,
      "Cache should be updated with fresh data after fetch!"

    puts "PASS: fetch! write-only mode works correctly"
  end

  def test_fetch_with_cache_true_uses_cached_data_without_intervening_save
    puts "\n=== Test: fetch!(cache: true) uses cached data when no save intervenes ==="

    # Create a product
    product = WriteOnlyCacheProduct.new(name: "Cache True Test", price: 29.99, version: 1)
    assert product.save
    product_id = product.id

    # Populate cache
    puts "Step 1: Populate cache"
    WriteOnlyCacheProduct.find_cached(product_id)

    # Fetch with cache: true should use cached data (no intervening save to invalidate)
    puts "Step 2: fetch!(cache: true) should use cached data"
    cached_product = WriteOnlyCacheProduct.new
    cached_product.id = product_id
    cached_product.fetch!(cache: true)

    assert_equal "Cache True Test", cached_product.name,
      "fetch!(cache: true) should return cached data"
    assert_equal 1, cached_product.version

    puts "PASS: fetch!(cache: true) uses cached data"
  end

  def test_fetch_with_cache_false_bypasses_cache
    puts "\n=== Test: fetch!(cache: false) bypasses cache ==="

    # Create a product
    product = WriteOnlyCacheProduct.new(name: "Cache False Test", price: 39.99, version: 1)
    assert product.save
    product_id = product.id

    # Populate cache
    puts "Step 1: Populate cache"
    WriteOnlyCacheProduct.find_cached(product_id)

    # Fetch with cache: false should get fresh data
    puts "Step 2: fetch!(cache: false) should get fresh data"
    fresh_product = WriteOnlyCacheProduct.new
    fresh_product.id = product_id
    fresh_product.fetch!(cache: false)

    assert_equal "Cache False Test", fresh_product.name,
      "fetch!(cache: false) should return fresh data from server"

    puts "PASS: fetch!(cache: false) bypasses cache"
  end

  # ============================================================
  # Tests for reload! with write-only cache mode
  # ============================================================

  def test_reload_write_only_gets_fresh_data_but_updates_cache
    puts "\n=== Test: reload! write-only gets fresh data but updates cache ==="

    # Create a product
    product = WriteOnlyCacheProduct.new(name: "Reload Test", price: 49.99, version: 1)
    assert product.save
    product_id = product.id

    # Populate cache
    puts "Step 1: Populate cache"
    WriteOnlyCacheProduct.find_cached(product_id)

    # Create another instance and modify it (simulating external update)
    puts "Step 2: External update"
    other = WriteOnlyCacheProduct.find(product_id)
    other.name = "Externally Updated"
    other.version = 2
    assert other.save

    # Reload should get fresh data
    puts "Step 3: reload! should get fresh data"
    product.reload!

    assert_equal "Externally Updated", product.name,
      "reload! should return fresh data"
    assert_equal 2, product.version

    # Verify cache was updated
    puts "Step 4: Cache should be updated"
    cached = WriteOnlyCacheProduct.find_cached(product_id)
    assert_equal "Externally Updated", cached.name,
      "Cache should be updated after reload!"

    puts "PASS: reload! write-only mode works correctly"
  end

  # ============================================================
  # Tests for find with write-only cache mode
  # ============================================================

  def test_find_write_only_gets_fresh_data_but_updates_cache
    puts "\n=== Test: find write-only gets fresh data but updates cache ==="

    # Create a product
    product = WriteOnlyCacheProduct.new(name: "Find Test", price: 59.99, version: 1)
    assert product.save
    product_id = product.id

    # Populate cache
    puts "Step 1: Populate cache"
    WriteOnlyCacheProduct.find_cached(product_id)

    # Update directly
    puts "Step 2: Update product"
    product.name = "Find Updated"
    product.version = 2
    assert product.save

    # find should get fresh data (write-only by default)
    puts "Step 3: find should get fresh data"
    found = WriteOnlyCacheProduct.find(product_id)

    assert_equal "Find Updated", found.name,
      "find should return fresh data"
    assert_equal 2, found.version

    # Verify cache was updated
    puts "Step 4: Cache should be updated"
    cached = WriteOnlyCacheProduct.find_cached(product_id)
    assert_equal "Find Updated", cached.name,
      "Cache should be updated after find"

    puts "PASS: find write-only mode works correctly"
  end

  def test_find_cached_returns_cached_data_without_intervening_save
    puts "\n=== Test: find_cached returns cached data when no save intervenes ==="

    # Create a product
    product = WriteOnlyCacheProduct.new(name: "Find Cached Test", price: 69.99, version: 1)
    assert product.save
    product_id = product.id

    # Populate cache
    puts "Step 1: Populate cache"
    first = WriteOnlyCacheProduct.find_cached(product_id)
    assert_equal "Find Cached Test", first.name

    # find_cached again should return cached data
    puts "Step 2: find_cached should return cached data"
    cached = WriteOnlyCacheProduct.find_cached(product_id)

    assert_equal "Find Cached Test", cached.name,
      "find_cached should return cached data"
    assert_equal 1, cached.version

    puts "PASS: find_cached returns cached data"
  end

  # ============================================================
  # Tests for cache invalidation on save
  # ============================================================

  def test_save_invalidates_cache
    puts "\n=== Test: save invalidates cache for that object ==="

    product = WriteOnlyCacheProduct.new(name: "Invalidation Test", price: 79.99, version: 1)
    assert product.save
    product_id = product.id

    # Populate cache
    puts "Step 1: Populate cache"
    WriteOnlyCacheProduct.find_cached(product_id)

    # Save update — should invalidate cache
    puts "Step 2: Update and save (invalidates cache)"
    product.name = "After Save"
    product.version = 2
    assert product.save

    # find_cached should now get fresh data (cache was invalidated by save)
    puts "Step 3: find_cached should get fresh data after cache invalidation"
    cached = WriteOnlyCacheProduct.find_cached(product_id)
    assert_equal "After Save", cached.name,
      "Cache should be invalidated by save, returning fresh data"

    puts "PASS: save invalidates cache correctly"
  end

  # ============================================================
  # Tests for feature flag control
  # ============================================================

  def test_feature_flag_disabled_makes_fetch_bypass_cache
    puts "\n=== Test: Parse.cache_write_on_fetch = false bypasses cache ==="

    # Disable the feature flag
    Parse.cache_write_on_fetch = false

    # Create a product
    product = WriteOnlyCacheProduct.new(name: "Flag Test", price: 79.99, version: 1)
    assert product.save
    product_id = product.id

    # fetch! with flag disabled should get data from server
    puts "Step 1: fetch! with flag disabled"
    fresh = WriteOnlyCacheProduct.new
    fresh.id = product_id
    fresh.fetch!

    assert_equal "Flag Test", fresh.name,
      "fetch! should return data from server"

    puts "PASS: Feature flag control works correctly"
  ensure
    Parse.cache_write_on_fetch = true
  end

  # ============================================================
  # Tests for fetch_cache! convenience method
  # ============================================================

  def test_fetch_cache_reads_from_cache_without_intervening_save
    puts "\n=== Test: fetch_cache! reads from cache ==="

    # Create a product
    product = WriteOnlyCacheProduct.new(name: "Fetch Cache Test", price: 89.99, version: 1)
    assert product.save
    product_id = product.id

    # Populate cache
    puts "Step 1: Populate cache"
    WriteOnlyCacheProduct.find_cached(product_id)

    # fetch_cache! should use cached data (no intervening save to invalidate)
    puts "Step 2: fetch_cache! should use cached data"
    cached_product = WriteOnlyCacheProduct.new
    cached_product.id = product_id
    cached_product.fetch_cache!

    assert_equal "Fetch Cache Test", cached_product.name,
      "fetch_cache! should return cached data"
    assert_equal 1, cached_product.version

    puts "PASS: fetch_cache! reads from cache"
  end
end
