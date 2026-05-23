# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"

# Unit tests for maxTimeMS pushdown (Proposal #11).
# All tests here are pure unit tests — no Docker or live MongoDB required.
# The mongo gem IS present in the bundle so we can reference the real
# Mongo::Error::OperationFailure without hitting the network.
class MongoDBMaxTimeMsTest < Minitest::Test
  def setup
    Parse::MongoDB.reset! if Parse::MongoDB.respond_to?(:reset!)
  end

  def teardown
    Parse::MongoDB.reset! if Parse::MongoDB.respond_to?(:reset!)
  end

  # ============================================================
  # Parse::MongoDB::ExecutionTimeout constructor + message
  # ============================================================

  def test_execution_timeout_is_a_standard_error
    err = Parse::MongoDB::ExecutionTimeout.new(collection_name: "Song", max_time_ms: 5000)
    assert_kind_of StandardError, err
  end

  def test_execution_timeout_stores_max_time_ms
    err = Parse::MongoDB::ExecutionTimeout.new(collection_name: "Song", max_time_ms: 5000)
    assert_equal 5000, err.max_time_ms
  end

  def test_execution_timeout_stores_collection_name
    err = Parse::MongoDB::ExecutionTimeout.new(collection_name: "Song", max_time_ms: 5000)
    assert_equal "Song", err.collection_name
  end

  def test_execution_timeout_message_format
    err = Parse::MongoDB::ExecutionTimeout.new(collection_name: "Song", max_time_ms: 5000)
    assert_match(/Song/, err.message)
    assert_match(/5000/, err.message)
    assert_match(/max_time_ms/, err.message)
  end

  def test_execution_timeout_message_with_hint
    err = Parse::MongoDB::ExecutionTimeout.new(collection_name: "MyClass", max_time_ms: 25_000)
    assert_match(/narrow filter or add index/i, err.message)
  end

  # ============================================================
  # Parse::MongoDB.aggregate accepts max_time_ms: kwarg
  # ============================================================

  def test_aggregate_accepts_max_time_ms_kwarg_without_raising_wrong_error
    # The method should accept the kwarg; it raises NotEnabled (not ArgumentError)
    # because MongoDB is not configured in this test.
    # `master: true` is needed because Wave-3 CLPScope fails CLOSED on
    # unresolvable schemas — this test isn't exercising auth, so the
    # master-mode bypass keeps the focus on max_time_ms plumbing.
    err = assert_raises(RuntimeError, Parse::MongoDB::NotEnabled) do
      Parse::MongoDB.aggregate("Song", [{ "$match" => {} }], max_time_ms: 5000, master: true)
    end
    # Must be a not-enabled style error, not an unknown-keyword error
    refute_kind_of ArgumentError, err
  end

  def test_aggregate_passes_max_time_ms_to_driver
    received_opts = nil
    mock_view = Object.new
    mock_view.define_singleton_method(:to_a) { [] }

    mock_collection = Object.new
    mock_collection.define_singleton_method(:aggregate) do |_pipeline, opts = {}|
      received_opts = opts
      mock_view
    end

    configure_with_mock_client(mock_collection)

    # `master: true` bypasses Wave-3 fail-closed CLP; test focus is
    # max_time_ms pushdown, not auth.
    Parse::MongoDB.aggregate("Song", [{ "$match" => { "title" => "hello" } }],
                             max_time_ms: 7500, master: true)

    assert_equal({ max_time_ms: 7500 }, received_opts)
  ensure
    Parse::MongoDB.reset!
  end

  def test_aggregate_omits_max_time_ms_option_when_nil
    received_opts = nil
    mock_view = Object.new
    mock_view.define_singleton_method(:to_a) { [] }

    mock_collection = Object.new
    mock_collection.define_singleton_method(:aggregate) do |_pipeline, opts = {}|
      received_opts = opts
      mock_view
    end

    configure_with_mock_client(mock_collection)

    # `master: true` bypasses Wave-3 fail-closed CLP; test focus is
    # the absence of max_time_ms in opts when the kwarg isn't passed.
    Parse::MongoDB.aggregate("Song", [{ "$match" => { "title" => "hello" } }], master: true)

    assert_equal({}, received_opts, "No max_time_ms key should be passed when nil")
  ensure
    Parse::MongoDB.reset!
  end

  # ============================================================
  # Parse::MongoDB.find accepts max_time_ms: option
  # ============================================================

  def test_find_accepts_max_time_ms_without_raising_wrong_error
    err = assert_raises(RuntimeError, Parse::MongoDB::NotEnabled) do
      Parse::MongoDB.find("Song", {}, max_time_ms: 5000)
    end
    refute_kind_of ArgumentError, err
  end

  def test_find_passes_max_time_ms_to_cursor
    received_ms = nil
    mock_cursor = build_mock_cursor(results: [], on_max_time_ms: ->(ms) { received_ms = ms })

    mock_collection = Object.new
    mock_collection.define_singleton_method(:find) { |_filter| mock_cursor }

    configure_with_mock_client(mock_collection)

    Parse::MongoDB.find("Song", { "plays" => { "$gt" => 100 } }, limit: 10, max_time_ms: 3000)

    assert_equal 3000, received_ms
  ensure
    Parse::MongoDB.reset!
  end

  def test_find_omits_max_time_ms_call_when_nil
    max_time_ms_called = false
    mock_cursor = build_mock_cursor(
      results: [],
      on_max_time_ms: ->(_ms) { max_time_ms_called = true },
    )

    mock_collection = Object.new
    mock_collection.define_singleton_method(:find) { |_filter| mock_cursor }

    configure_with_mock_client(mock_collection)

    Parse::MongoDB.find("Song", {}, limit: 10)

    refute max_time_ms_called, "max_time_ms should not be called on cursor when option is nil"
  ensure
    Parse::MongoDB.reset!
  end

  # ============================================================
  # Driver error code 50 translation
  # ============================================================

  def test_aggregate_translates_code_50_to_execution_timeout
    driver_error = operation_failure_for(code: 50)

    mock_view = Object.new
    mock_view.define_singleton_method(:to_a) { raise driver_error }

    mock_collection = Object.new
    mock_collection.define_singleton_method(:aggregate) { |_, _opts = {}| mock_view }

    configure_with_mock_client(mock_collection)

    err = assert_raises(Parse::MongoDB::ExecutionTimeout) do
      # master: true → bypass Wave-3 fail-closed CLP; test exercises
      # the code-50 → ExecutionTimeout translation, not auth.
      Parse::MongoDB.aggregate("Song", [{ "$match" => {} }], max_time_ms: 500, master: true)
    end

    assert_equal 500, err.max_time_ms
    assert_equal "Song", err.collection_name
  ensure
    Parse::MongoDB.reset!
  end

  def test_find_translates_code_50_to_execution_timeout
    driver_error = operation_failure_for(code: 50)

    mock_cursor = build_mock_cursor(results: [], raise_on_to_a: driver_error)

    mock_collection = Object.new
    mock_collection.define_singleton_method(:find) { |_filter| mock_cursor }

    configure_with_mock_client(mock_collection)

    err = assert_raises(Parse::MongoDB::ExecutionTimeout) do
      Parse::MongoDB.find("Song", {}, limit: 5, max_time_ms: 500)
    end

    assert_equal 500, err.max_time_ms
    assert_equal "Song", err.collection_name
  ensure
    Parse::MongoDB.reset!
  end

  def test_non_code_50_operation_failure_is_not_translated
    driver_error = operation_failure_for(code: 11_000) # DuplicateKey

    mock_view = Object.new
    mock_view.define_singleton_method(:to_a) { raise driver_error }

    mock_collection = Object.new
    mock_collection.define_singleton_method(:aggregate) { |_, _opts = {}| mock_view }

    configure_with_mock_client(mock_collection)

    # Should re-raise the original driver error (not ExecutionTimeout).
    # master: true → bypass Wave-3 fail-closed CLP; test exercises
    # the non-code-50 passthrough, not auth.
    raised = assert_raises(StandardError) do
      Parse::MongoDB.aggregate("Song", [{ "$match" => {} }], max_time_ms: 500, master: true)
    end
    refute_kind_of Parse::MongoDB::ExecutionTimeout, raised
    assert_equal 11_000, raised.code
  ensure
    Parse::MongoDB.reset!
  end

  private

  # Configure Parse::MongoDB with a mock client double that returns
  # the given collection for any collection name.
  def configure_with_mock_client(mock_collection)
    mock_client = Object.new
    mock_client.define_singleton_method(:[]) { |_name| mock_collection }

    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, "mongodb://localhost:27017/test")
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@client, mock_client)
  end

  # Build a mock Mongo cursor that supports the chaining methods used by
  # Parse::MongoDB.find (.limit, .skip, .sort, .projection, .max_time_ms, .to_a).
  def build_mock_cursor(results:, on_max_time_ms: nil, raise_on_to_a: nil)
    cursor = Object.new
    %i[limit skip sort projection].each do |m|
      cursor.define_singleton_method(m) { |_arg| self }
    end
    cursor.define_singleton_method(:max_time_ms) do |ms|
      on_max_time_ms&.call(ms)
      self
    end
    cursor.define_singleton_method(:to_a) do
      raise raise_on_to_a if raise_on_to_a
      results
    end
    cursor
  end

  # Create a real subclass of Mongo::Error::OperationFailure whose #code
  # method returns the given integer. This avoids stubbing the real driver
  # class while ensuring is_a?(::Mongo::Error::OperationFailure) is true.
  #
  # Important: the parent initialize extracts @code from a response document;
  # passing a plain String leaves @code nil. We override the accessor via a
  # singleton method AFTER construction so the driver doesn't clobber it.
  def operation_failure_for(code:)
    require "mongo"
    # Instantiate with the parent's expected call signature (string message)
    # The parent sets @code from the response document which we don't supply,
    # leaving @code nil. We patch the singleton after construction.
    instance = ::Mongo::Error::OperationFailure.allocate
    # Initialize via StandardError so we can set the message without going
    # through the driver's response-document parsing.
    StandardError.instance_method(:initialize).bind(instance).call("MongoDB operation failure (code: #{code})")
    # Override #code on this singleton so raise_if_timeout! sees the right value
    instance.define_singleton_method(:code) { code }
    instance
  end
end
