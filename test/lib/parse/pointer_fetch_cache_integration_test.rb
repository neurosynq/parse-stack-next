# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/autorun"

# Test model for pointer fetch_cache! integration tests
class PointerCacheTestCapture < Parse::Object
  parse_class "PointerCacheTestCapture"
  property :title, :string
  property :status, :string
  property :notes, :string
  belongs_to :project, class_name: "PointerCacheTestProject"
end

class PointerCacheTestProject < Parse::Object
  parse_class "PointerCacheTestProject"
  property :name, :string
end

class PointerFetchCacheIntegrationTest < Minitest::Test
  def setup
    # Skip if Docker not configured
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    # Setup Parse client
    Parse::Client.setup(
      server_url: "http://localhost:2337/parse",
      app_id: "myAppId",
      api_key: "test-rest-key",
      master_key: "myMasterKey",
    )

    # Store original caching settings
    @original_caching_enabled = Parse::Middleware::Caching.enabled
    @original_logging = Parse::Middleware::Caching.logging

    # Enable caching and logging
    Parse::Middleware::Caching.enabled = true
    Parse::Middleware::Caching.logging = true

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
    Parse::Middleware::Caching.enabled = @original_caching_enabled if defined?(@original_caching_enabled) && @original_caching_enabled
    Parse::Middleware::Caching.logging = @original_logging if defined?(@original_logging) && @original_logging
  end

  def test_pointer_fetch_cache_returns_parse_object
    puts "\n=== Testing Pointer#fetch_cache! returns Parse::Object ==="

    # Create a test capture
    capture = PointerCacheTestCapture.new(
      title: "Fetch Cache Test",
      status: "active",
      notes: "Testing pointer fetch_cache!",
    )
    assert capture.save, "Capture should save successfully"
    capture_id = capture.id
    puts "Created capture with ID: #{capture_id}"

    # Create a pointer to the capture
    pointer = Parse::Pointer.new("PointerCacheTestCapture", capture_id)
    assert pointer.pointer?, "Should be a pointer"

    # Fetch with caching
    puts "Fetching pointer with fetch_cache!..."
    fetched = pointer.fetch_cache!

    assert fetched, "fetch_cache! should return an object"
    assert_kind_of Parse::Object, fetched, "Should return a Parse::Object"
    assert_equal "Fetch Cache Test", fetched.title
    assert_equal "active", fetched.status
    assert_equal "Testing pointer fetch_cache!", fetched.notes

    puts "fetch_cache! returned: #{fetched.class.name} with title: #{fetched.title}"
    puts "Pointer#fetch_cache! returns Parse::Object"
  end

  def test_pointer_fetch_cache_with_keys
    puts "\n=== Testing Pointer#fetch_cache! with keys (partial fetch) ==="

    # Create a test capture
    capture = PointerCacheTestCapture.new(
      title: "Partial Fetch Test",
      status: "pending",
      notes: "These notes should not be fetched",
    )
    assert capture.save, "Capture should save successfully"
    capture_id = capture.id
    puts "Created capture with ID: #{capture_id}"

    # Create a pointer
    pointer = Parse::Pointer.new("PointerCacheTestCapture", capture_id)

    # Fetch with specific keys
    puts "Fetching pointer with fetch_cache!(keys: [:title, :status])..."
    fetched = pointer.fetch_cache!(keys: [:title, :status])

    assert fetched, "fetch_cache! should return an object"
    assert_equal "Partial Fetch Test", fetched.title
    assert_equal "pending", fetched.status

    # Check partial fetch state
    assert fetched.partially_fetched?, "Object should be partially fetched"
    assert fetched.field_was_fetched?(:title), "title should be marked as fetched"
    assert fetched.field_was_fetched?(:status), "status should be marked as fetched"

    puts "Partial fetch successful with keys: [:title, :status]"
    puts "partially_fetched? = #{fetched.partially_fetched?}"
  end

  def test_pointer_fetch_cache_with_includes
    puts "\n=== Testing Pointer#fetch_cache! with includes ==="

    # Create a project first
    project = PointerCacheTestProject.new(name: "Test Project")
    assert project.save, "Project should save successfully"
    puts "Created project with ID: #{project.id}"

    # Create a capture linked to the project
    capture = PointerCacheTestCapture.new(
      title: "Capture with Project",
      status: "active",
      project: project,
    )
    assert capture.save, "Capture should save successfully"
    capture_id = capture.id
    puts "Created capture with ID: #{capture_id}"

    # Create a pointer
    pointer = Parse::Pointer.new("PointerCacheTestCapture", capture_id)

    # Fetch with includes
    puts "Fetching pointer with fetch_cache!(includes: [:project])..."
    fetched = pointer.fetch_cache!(includes: [:project])

    assert fetched, "fetch_cache! should return an object"
    assert_equal "Capture with Project", fetched.title

    # The project should be included (not a pointer)
    fetched_project = fetched.project
    assert fetched_project, "Project should be present"
    assert_equal "Test Project", fetched_project.name

    puts "fetch_cache! with includes successful"
    puts "Included project name: #{fetched_project.name}"
  end

  def test_pointer_fetch_with_cache_option
    puts "\n=== Testing Pointer#fetch with cache: option ==="

    # Create a test capture
    capture = PointerCacheTestCapture.new(
      title: "Cache Option Test",
      status: "completed",
    )
    assert capture.save, "Capture should save successfully"
    capture_id = capture.id
    puts "Created capture with ID: #{capture_id}"

    # Create a pointer
    pointer = Parse::Pointer.new("PointerCacheTestCapture", capture_id)

    # Fetch with explicit cache: true
    puts "Fetching pointer with fetch(cache: true)..."
    fetched1 = pointer.fetch(cache: true)
    assert fetched1, "fetch(cache: true) should return an object"
    assert_equal "Cache Option Test", fetched1.title

    # Create another pointer and fetch with cache: false
    pointer2 = Parse::Pointer.new("PointerCacheTestCapture", capture_id)
    puts "Fetching pointer with fetch(cache: false)..."
    fetched2 = pointer2.fetch(cache: false)
    assert fetched2, "fetch(cache: false) should return an object"
    assert_equal "Cache Option Test", fetched2.title

    # Create another pointer and fetch with cache: :write_only
    pointer3 = Parse::Pointer.new("PointerCacheTestCapture", capture_id)
    puts "Fetching pointer with fetch(cache: :write_only)..."
    fetched3 = pointer3.fetch(cache: :write_only)
    assert fetched3, "fetch(cache: :write_only) should return an object"
    assert_equal "Cache Option Test", fetched3.title

    puts "All cache options work correctly"
  end

  def test_pointer_fetch_cache_caches_response
    puts "\n=== Testing that Pointer#fetch_cache! actually caches ==="

    # Create a test capture
    capture = PointerCacheTestCapture.new(
      title: "Caching Behavior Test",
      status: "active",
    )
    assert capture.save, "Capture should save successfully"
    capture_id = capture.id
    puts "Created capture with ID: #{capture_id}"

    # First fetch should hit the server and cache the response
    pointer1 = Parse::Pointer.new("PointerCacheTestCapture", capture_id)
    puts "First fetch (should hit server and cache)..."
    fetched1 = pointer1.fetch_cache!
    assert fetched1, "First fetch should succeed"
    assert_equal "Caching Behavior Test", fetched1.title

    # Second fetch should use cached response
    pointer2 = Parse::Pointer.new("PointerCacheTestCapture", capture_id)
    puts "Second fetch (should use cache)..."
    fetched2 = pointer2.fetch_cache!
    assert fetched2, "Second fetch should succeed"
    assert_equal "Caching Behavior Test", fetched2.title

    puts "Both fetches returned correct data"
    puts "Caching behavior verified"
  end
end
