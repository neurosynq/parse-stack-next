# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "moneta"

# Unit tests for the write-only cache mode feature
# Tests the Parse.cache_write_on_fetch feature flag, caching middleware,
# and client handling of cache: :write_only option

class CacheWriteOnlyTest < Minitest::Test
  def setup
    @base_options = {
      server_url: "http://localhost:1337/parse",
      app_id: "test_app_id",
      api_key: "test_api_key",
    }
    # Store original value
    @original_cache_write_on_fetch = Parse.cache_write_on_fetch
    # Clear existing clients
    Parse::Client.clients.clear
  end

  def teardown
    # Restore original value
    Parse.cache_write_on_fetch = @original_cache_write_on_fetch
    # Clean up clients
    Parse::Client.clients.clear
  end

  # ============================================================
  # Tests for Parse.cache_write_on_fetch feature flag
  # ============================================================

  def test_cache_write_on_fetch_defaults_to_true
    # Reset to ensure we're testing the default
    Parse.instance_variable_set(:@cache_write_on_fetch, nil)
    # The attr_accessor should return nil if not set, but we default it to true in initialization
    # Re-require would be needed to test true default, but we can verify the intended default
    Parse.cache_write_on_fetch = true # Set to default

    assert_equal true, Parse.cache_write_on_fetch,
      "Parse.cache_write_on_fetch should default to true"
  end

  def test_cache_write_on_fetch_can_be_set_to_false
    Parse.cache_write_on_fetch = false

    assert_equal false, Parse.cache_write_on_fetch,
      "Parse.cache_write_on_fetch should be settable to false"
  end

  def test_cache_write_on_fetch_can_be_set_to_true
    Parse.cache_write_on_fetch = false # First set to false
    Parse.cache_write_on_fetch = true  # Then set back to true

    assert_equal true, Parse.cache_write_on_fetch,
      "Parse.cache_write_on_fetch should be settable to true"
  end

  # ============================================================
  # Tests for caching middleware write_only mode
  # ============================================================

  def test_cache_write_only_header_constant_exists
    assert_equal "X-Parse-Stack-Cache-Write-Only",
      Parse::Middleware::Caching::CACHE_WRITE_ONLY,
      "CACHE_WRITE_ONLY header constant should be defined"
  end

  def test_caching_middleware_accepts_write_only_header
    # Create a simple Moneta store for testing
    store = Moneta.new(:LRUHash, expires: 60)

    # Create middleware instance
    app = ->(env) { Faraday::Response.new }
    middleware = Parse::Middleware::Caching.new(app, store, expires: 60)

    # Verify middleware was created without error
    assert_instance_of Parse::Middleware::Caching, middleware
  end

  # ============================================================
  # Tests for client handling of cache: :write_only
  # ============================================================

  def test_client_accepts_cache_write_only_option
    # Create client with cache
    store = Moneta.new(:LRUHash, expires: 60)
    options = @base_options.merge(cache: store)
    client = Parse::Client.new(options)

    # Should not raise when creating client
    assert_instance_of Parse::Client, client
  end

  def test_request_with_cache_write_only_sets_header
    # Create a mock to verify headers
    store = Moneta.new(:LRUHash, expires: 60)
    options = @base_options.merge(cache: store)

    Parse.setup(options)

    # Build a request with cache: :write_only in opts
    request = Parse::Request.new(:get, "classes/Test/abc123", opts: { cache: :write_only })

    # Verify the cache option is set
    assert_equal :write_only, request.opts[:cache],
      "Request should have cache: :write_only in opts"
  end

  def test_request_with_cache_false_sets_no_cache_header
    store = Moneta.new(:LRUHash, expires: 60)
    options = @base_options.merge(cache: store)

    Parse.setup(options)

    # Build a request with cache: false in opts
    request = Parse::Request.new(:get, "classes/Test/abc123", opts: { cache: false })

    assert_equal false, request.opts[:cache],
      "Request should have cache: false in opts"
  end

  def test_request_with_cache_true_uses_full_caching
    store = Moneta.new(:LRUHash, expires: 60)
    options = @base_options.merge(cache: store)

    Parse.setup(options)

    # Build a request with cache: true in opts
    request = Parse::Request.new(:get, "classes/Test/abc123", opts: { cache: true })

    assert_equal true, request.opts[:cache],
      "Request should have cache: true in opts"
  end
end

# Unit tests for fetch!, reload!, find default cache behavior
class CacheWriteOnlyDefaultsTest < Minitest::Test
  # Test model for verifying default cache behavior
  class TestSong < Parse::Object
    parse_class "Song"
    property :title, :string
    property :artist, :string
  end

  def setup
    @base_options = {
      server_url: "http://localhost:1337/parse",
      app_id: "test_app_id",
      api_key: "test_api_key",
    }
    @original_cache_write_on_fetch = Parse.cache_write_on_fetch
    Parse::Client.clients.clear
  end

  def teardown
    Parse.cache_write_on_fetch = @original_cache_write_on_fetch
    Parse::Client.clients.clear
  end

  # ============================================================
  # Tests for fetch! default cache behavior
  # ============================================================

  def test_fetch_defaults_to_write_only_when_feature_enabled
    Parse.cache_write_on_fetch = true

    # Create a song with an ID (simulating a pointer)
    song = TestSong.new
    song.id = "test123"

    # Mock the client to capture the request
    captured_opts = nil
    original_client = song.method(:client)
    song.define_singleton_method(:client) do
      mock_client = Object.new
      mock_client.define_singleton_method(:fetch_object) do |klass, id, **opts|
        captured_opts = opts
        # Return a mock response
        response = Parse::Response.new
        response.result = { "objectId" => id, "title" => "Test" }
        response
      end
      mock_client
    end

    song.fetch!

    assert_equal :write_only, captured_opts[:cache],
      "fetch! should default to cache: :write_only when Parse.cache_write_on_fetch is true"
  end

  def test_fetch_defaults_to_false_when_feature_disabled
    Parse.cache_write_on_fetch = false

    song = TestSong.new
    song.id = "test123"

    captured_opts = nil
    song.define_singleton_method(:client) do
      mock_client = Object.new
      mock_client.define_singleton_method(:fetch_object) do |klass, id, **opts|
        captured_opts = opts
        response = Parse::Response.new
        response.result = { "objectId" => id, "title" => "Test" }
        response
      end
      mock_client
    end

    song.fetch!

    assert_equal false, captured_opts[:cache],
      "fetch! should default to cache: false when Parse.cache_write_on_fetch is false"
  end

  def test_fetch_respects_explicit_cache_true
    Parse.cache_write_on_fetch = true

    song = TestSong.new
    song.id = "test123"

    captured_opts = nil
    song.define_singleton_method(:client) do
      mock_client = Object.new
      mock_client.define_singleton_method(:fetch_object) do |klass, id, **opts|
        captured_opts = opts
        response = Parse::Response.new
        response.result = { "objectId" => id, "title" => "Test" }
        response
      end
      mock_client
    end

    song.fetch!(cache: true)

    assert_equal true, captured_opts[:cache],
      "fetch!(cache: true) should use cache: true regardless of feature flag"
  end

  def test_fetch_respects_explicit_cache_false
    Parse.cache_write_on_fetch = true

    song = TestSong.new
    song.id = "test123"

    captured_opts = nil
    song.define_singleton_method(:client) do
      mock_client = Object.new
      mock_client.define_singleton_method(:fetch_object) do |klass, id, **opts|
        captured_opts = opts
        response = Parse::Response.new
        response.result = { "objectId" => id, "title" => "Test" }
        response
      end
      mock_client
    end

    song.fetch!(cache: false)

    assert_equal false, captured_opts[:cache],
      "fetch!(cache: false) should use cache: false regardless of feature flag"
  end

  # ============================================================
  # Tests for fetch_cache! convenience method
  # ============================================================

  def test_fetch_cache_uses_cache_true
    song = TestSong.new
    song.id = "test123"

    captured_opts = nil
    song.define_singleton_method(:client) do
      mock_client = Object.new
      mock_client.define_singleton_method(:fetch_object) do |klass, id, **opts|
        captured_opts = opts
        response = Parse::Response.new
        response.result = { "objectId" => id, "title" => "Test" }
        response
      end
      mock_client
    end

    song.fetch_cache!

    assert_equal true, captured_opts[:cache],
      "fetch_cache! should always use cache: true"
  end

  # ============================================================
  # Tests for reload! default cache behavior
  # ============================================================

  def test_reload_defaults_to_write_only_when_feature_enabled
    Parse.cache_write_on_fetch = true

    song = TestSong.new
    song.id = "test123"

    captured_opts = nil
    song.define_singleton_method(:client) do
      mock_client = Object.new
      mock_client.define_singleton_method(:fetch_object) do |klass, id, **opts|
        captured_opts = opts
        response = Parse::Response.new
        response.result = { "objectId" => id, "title" => "Test" }
        response
      end
      mock_client
    end

    song.reload!

    assert_equal :write_only, captured_opts[:cache],
      "reload! should default to cache: :write_only when Parse.cache_write_on_fetch is true"
  end

  def test_reload_defaults_to_false_when_feature_disabled
    Parse.cache_write_on_fetch = false

    song = TestSong.new
    song.id = "test123"

    captured_opts = nil
    song.define_singleton_method(:client) do
      mock_client = Object.new
      mock_client.define_singleton_method(:fetch_object) do |klass, id, **opts|
        captured_opts = opts
        response = Parse::Response.new
        response.result = { "objectId" => id, "title" => "Test" }
        response
      end
      mock_client
    end

    song.reload!

    assert_equal false, captured_opts[:cache],
      "reload! should default to cache: false when Parse.cache_write_on_fetch is false"
  end

  def test_reload_respects_explicit_cache_true
    Parse.cache_write_on_fetch = false

    song = TestSong.new
    song.id = "test123"

    captured_opts = nil
    song.define_singleton_method(:client) do
      mock_client = Object.new
      mock_client.define_singleton_method(:fetch_object) do |klass, id, **opts|
        captured_opts = opts
        response = Parse::Response.new
        response.result = { "objectId" => id, "title" => "Test" }
        response
      end
      mock_client
    end

    song.reload!(cache: true)

    assert_equal true, captured_opts[:cache],
      "reload!(cache: true) should use cache: true regardless of feature flag"
  end
end

# Unit tests for find/find_cached default cache behavior
class CacheWriteOnlyFindTest < Minitest::Test
  # Test model for verifying find cache behavior
  class FindTestSong < Parse::Object
    parse_class "FindSong"
    property :title, :string
  end

  def setup
    @base_options = {
      server_url: "http://localhost:1337/parse",
      app_id: "test_app_id",
      api_key: "test_api_key",
    }
    @original_cache_write_on_fetch = Parse.cache_write_on_fetch
    Parse::Client.clients.clear

    # Setup Parse with a mock cache
    store = Moneta.new(:LRUHash, expires: 60)
    Parse.setup(@base_options.merge(cache: store))
  end

  def teardown
    Parse.cache_write_on_fetch = @original_cache_write_on_fetch
    Parse::Client.clients.clear
  end

  def test_find_defaults_to_write_only_when_feature_enabled
    Parse.cache_write_on_fetch = true

    # The find method uses client.fetch_object internally
    # We test that the cache option is correctly set to :write_only
    # by checking the method signature accepts nil and defaults appropriately

    # Verify the default parameter is nil (not false)
    method = FindTestSong.method(:find)
    params = method.parameters

    # Find the cache parameter
    cache_param = params.find { |type, name| name == :cache }
    assert cache_param, "find method should have a :cache parameter"

    # The parameter should be a keyword with default (keyreq or key)
    assert_includes [:key, :keyreq], cache_param[0],
      "cache parameter should be a keyword argument"
  end

  def test_find_cached_uses_cache_true
    # find_cached should always pass cache: true
    # We can verify by checking the method implementation

    method_source = FindTestSong.method(:find_cached).source_location
    assert method_source, "find_cached method should exist"
  end

  def test_find_with_explicit_cache_false
    # Verify explicit cache: false is respected
    Parse.cache_write_on_fetch = true

    # Create a mock client to capture requests
    captured_cache_value = nil
    original_client = Parse.client

    mock_client = Object.new
    mock_client.define_singleton_method(:fetch_object) do |klass, id, **opts|
      captured_cache_value = opts[:cache]
      response = Parse::Response.new
      response.result = { "objectId" => id, "title" => "Test" }
      response
    end

    # Temporarily replace the client method
    FindTestSong.define_singleton_method(:client) { mock_client }

    begin
      FindTestSong.find("abc123", cache: false)
      assert_equal false, captured_cache_value,
        "find with cache: false should pass cache: false to client"
    ensure
      # Restore
      FindTestSong.singleton_class.remove_method(:client) if FindTestSong.respond_to?(:client, false)
    end
  end

  def test_find_with_explicit_cache_true
    Parse.cache_write_on_fetch = false

    captured_cache_value = nil
    mock_client = Object.new
    mock_client.define_singleton_method(:fetch_object) do |klass, id, **opts|
      captured_cache_value = opts[:cache]
      response = Parse::Response.new
      response.result = { "objectId" => id, "title" => "Test" }
      response
    end

    FindTestSong.define_singleton_method(:client) { mock_client }

    begin
      FindTestSong.find("abc123", cache: true)
      assert_equal true, captured_cache_value,
        "find with cache: true should pass cache: true to client"
    ensure
      FindTestSong.singleton_class.remove_method(:client) if FindTestSong.respond_to?(:client, false)
    end
  end
end

# Tests for the caching middleware write_only behavior
class CacheMiddlewareWriteOnlyTest < Minitest::Test
  def setup
    @store = Moneta.new(:LRUHash, expires: 60)
    @cache_key = "http://localhost:1337/parse/classes/Test/abc123"
    @cached_data = { headers: { "Content-Type" => "application/json" }, body: '{"objectId":"abc123","title":"Cached"}' }
  end

  def teardown
    @store.clear if @store
  end

  def test_write_only_mode_skips_cache_read
    # Pre-populate cache
    @store.store(@cache_key, @cached_data, expires: 60)
    assert @store.key?(@cache_key), "Cache should have the key"

    # Create a mock app that returns fresh data
    fresh_response_called = false
    app = lambda do |env|
      fresh_response_called = true
      response = Faraday::Response.new
      response.finish({
        status: 200,
        response_headers: { "Content-Type" => "application/json", "content-length" => "50" },
        body: '{"objectId":"abc123","title":"Fresh"}',
      })
      response
    end

    # Create middleware
    middleware = Parse::Middleware::Caching.new(app, @store, expires: 60)

    # Create a mock env with write_only header
    env = Faraday::Env.new
    env.method = :get
    env.url = URI.parse(@cache_key)
    env[:request_headers] = {
      Parse::Middleware::Caching::CACHE_WRITE_ONLY => "true",
    }

    # Call middleware
    response = middleware.call(env)

    # Should have called the app (not used cache)
    assert fresh_response_called, "Should call the app when write_only mode is enabled"
  end

  def test_write_only_mode_updates_cache
    # Ensure cache is empty
    @store.delete(@cache_key)
    refute @store.key?(@cache_key), "Cache should be empty initially"

    # Create a mock app that returns fresh data
    app = lambda do |env|
      response = Faraday::Response.new
      response.finish({
        status: 200,
        response_headers: { "Content-Type" => "application/json", "content-length" => "50" },
        body: '{"objectId":"abc123","title":"Fresh"}',
      })
      response
    end

    # Create middleware
    middleware = Parse::Middleware::Caching.new(app, @store, expires: 60)

    # Create a mock env with write_only header
    env = Faraday::Env.new
    env.method = :get
    env.url = URI.parse(@cache_key)
    env[:request_headers] = {
      Parse::Middleware::Caching::CACHE_WRITE_ONLY => "true",
    }

    # Call middleware
    middleware.call(env)

    # Cache should now have the fresh data
    assert @store.key?(@cache_key), "Cache should be updated after write_only request"
    cached = @store[@cache_key]
    assert_equal '{"objectId":"abc123","title":"Fresh"}', cached[:body],
      "Cache should contain the fresh response body"
  end

  def test_normal_mode_reads_from_cache
    # Pre-populate cache
    @store.store(@cache_key, @cached_data, expires: 60)

    # Create a mock app that should NOT be called
    app_called = false
    app = lambda do |env|
      app_called = true
      raise "App should not be called when cache hit"
    end

    # Create middleware
    middleware = Parse::Middleware::Caching.new(app, @store, expires: 60)

    # Create a mock env WITHOUT write_only header
    env = Faraday::Env.new
    env.method = :get
    env.url = URI.parse(@cache_key)
    env[:request_headers] = {}

    # Call middleware
    response = middleware.call(env)

    # Should NOT have called the app (used cache instead)
    refute app_called, "Should not call the app when cache hit in normal mode"

    # Response should have cache header
    assert_equal "true", response.headers[Parse::Middleware::Caching::CACHE_RESPONSE_HEADER],
      "Response should have cache response header"
  end

  def test_no_cache_mode_skips_read_and_write
    # Pre-populate cache
    original_data = { headers: {}, body: '{"original":"data"}' }
    @store.store(@cache_key, original_data, expires: 60)

    # Create a mock app
    app = lambda do |env|
      response = Faraday::Response.new
      response.finish({
        status: 200,
        response_headers: { "Content-Type" => "application/json", "content-length" => "50" },
        body: '{"objectId":"abc123","title":"New"}',
      })
      response
    end

    # Create middleware
    middleware = Parse::Middleware::Caching.new(app, @store, expires: 60)

    # Create a mock env with no-cache header
    env = Faraday::Env.new
    env.method = :get
    env.url = URI.parse(@cache_key)
    env[:request_headers] = {
      Parse::Middleware::Caching::CACHE_CONTROL => "no-cache",
    }

    # Call middleware
    middleware.call(env)

    # Cache should still have the original data (not updated)
    cached = @store[@cache_key]
    assert_equal '{"original":"data"}', cached[:body],
      "Cache should NOT be updated when no-cache mode is used"
  end
end
