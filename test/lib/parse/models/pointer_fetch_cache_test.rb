# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Unit tests for Pointer#fetch_cache! and Pointer#fetch cache option
class PointerFetchCacheTest < Minitest::Test
  # Test model for pointer fetch tests
  class TestCapture < Parse::Object
    parse_class "Capture"
    property :title, :string
    property :status, :string
    property :notes, :string
  end

  def setup
    @pointer = Parse::Pointer.new("Capture", "testObjectId123")
  end

  # ============================================================
  # Tests for Pointer#fetch_cache! method existence
  # ============================================================

  def test_pointer_responds_to_fetch_cache
    assert_respond_to @pointer, :fetch_cache!,
      "Pointer should respond to fetch_cache!"
  end

  def test_pointer_fetch_cache_accepts_keys_parameter
    # Verify method accepts keys: parameter without raising ArgumentError
    # Track what the client receives
    received_opts = nil

    mock_client = Object.new
    mock_client.define_singleton_method(:fetch_object) do |class_name, id, **opts|
      received_opts = opts
      response = Object.new
      response.define_singleton_method(:error?) { true }
      response
    end

    @pointer.stub :client, mock_client do
      result = @pointer.fetch_cache!(keys: [:title, :status])
      assert_nil result, "Should return nil on error response"
      assert_equal true, received_opts[:cache], "Should pass cache: true to client"
      assert_equal "title,status", received_opts[:query][:keys], "Should include keys in query"
    end
  end

  def test_pointer_fetch_cache_accepts_includes_parameter
    # Verify method accepts includes: parameter without raising ArgumentError
    received_opts = nil

    mock_client = Object.new
    mock_client.define_singleton_method(:fetch_object) do |class_name, id, **opts|
      received_opts = opts
      response = Object.new
      response.define_singleton_method(:error?) { true }
      response
    end

    @pointer.stub :client, mock_client do
      result = @pointer.fetch_cache!(includes: [:project])
      assert_nil result, "Should return nil on error response"
      assert_equal true, received_opts[:cache], "Should pass cache: true to client"
      assert_equal "project", received_opts[:query][:include], "Should include project in query includes"
    end
  end

  def test_pointer_fetch_cache_accepts_both_keys_and_includes
    # Verify method accepts both parameters
    received_opts = nil

    mock_client = Object.new
    mock_client.define_singleton_method(:fetch_object) do |class_name, id, **opts|
      received_opts = opts
      response = Object.new
      response.define_singleton_method(:error?) { true }
      response
    end

    @pointer.stub :client, mock_client do
      result = @pointer.fetch_cache!(keys: [:title], includes: [:project])
      assert_nil result, "Should return nil on error response"
      assert_equal true, received_opts[:cache], "Should pass cache: true to client"
      assert_equal "title", received_opts[:query][:keys], "Should include title in query keys"
      assert_equal "project", received_opts[:query][:include], "Should include project in query includes"
    end
  end

  # ============================================================
  # Tests for Pointer#fetch cache: parameter
  # ============================================================

  def test_pointer_fetch_accepts_cache_true
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, true

    mock_client = Minitest::Mock.new
    mock_client.expect :fetch_object, mock_response, [String, String], query: nil, cache: true

    @pointer.stub :client, mock_client do
      result = @pointer.fetch(cache: true)
      assert_nil result
    end
  end

  def test_pointer_fetch_accepts_cache_false
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, true

    mock_client = Minitest::Mock.new
    mock_client.expect :fetch_object, mock_response, [String, String], query: nil, cache: false

    @pointer.stub :client, mock_client do
      result = @pointer.fetch(cache: false)
      assert_nil result
    end
  end

  def test_pointer_fetch_accepts_cache_write_only
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, true

    mock_client = Minitest::Mock.new
    mock_client.expect :fetch_object, mock_response, [String, String], query: nil, cache: :write_only

    @pointer.stub :client, mock_client do
      result = @pointer.fetch(cache: :write_only)
      assert_nil result
    end
  end

  def test_pointer_fetch_accepts_cache_integer_ttl
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, true

    mock_client = Minitest::Mock.new
    mock_client.expect :fetch_object, mock_response, [String, String], query: nil, cache: 300

    @pointer.stub :client, mock_client do
      result = @pointer.fetch(cache: 300)
      assert_nil result
    end
  end

  def test_pointer_fetch_without_cache_does_not_pass_cache_option
    mock_response = Minitest::Mock.new
    mock_response.expect :error?, true

    # When cache: nil is not passed, opts should be empty
    mock_client = Minitest::Mock.new
    mock_client.expect :fetch_object, mock_response, [String, String], query: nil

    @pointer.stub :client, mock_client do
      result = @pointer.fetch
      assert_nil result
    end
  end

  # ============================================================
  # Tests for fetch_cache! delegating to fetch with cache: true
  # ============================================================

  def test_fetch_cache_calls_fetch_with_cache_true
    # Track what parameters fetch receives
    fetch_called_with = nil

    @pointer.define_singleton_method(:fetch) do |keys: nil, includes: nil, cache: nil|
      fetch_called_with = { keys: keys, includes: includes, cache: cache }
      nil
    end

    @pointer.fetch_cache!

    assert_equal true, fetch_called_with[:cache],
      "fetch_cache! should call fetch with cache: true"
    assert_nil fetch_called_with[:keys],
      "fetch_cache! with no args should pass keys: nil"
    assert_nil fetch_called_with[:includes],
      "fetch_cache! with no args should pass includes: nil"
  end

  def test_fetch_cache_passes_keys_to_fetch
    fetch_called_with = nil

    @pointer.define_singleton_method(:fetch) do |keys: nil, includes: nil, cache: nil|
      fetch_called_with = { keys: keys, includes: includes, cache: cache }
      nil
    end

    @pointer.fetch_cache!(keys: [:title, :status])

    assert_equal [:title, :status], fetch_called_with[:keys],
      "fetch_cache! should pass keys to fetch"
    assert_equal true, fetch_called_with[:cache],
      "fetch_cache! should always pass cache: true"
  end

  def test_fetch_cache_passes_includes_to_fetch
    fetch_called_with = nil

    @pointer.define_singleton_method(:fetch) do |keys: nil, includes: nil, cache: nil|
      fetch_called_with = { keys: keys, includes: includes, cache: cache }
      nil
    end

    @pointer.fetch_cache!(includes: [:project, :author])

    assert_equal [:project, :author], fetch_called_with[:includes],
      "fetch_cache! should pass includes to fetch"
    assert_equal true, fetch_called_with[:cache],
      "fetch_cache! should always pass cache: true"
  end
end
