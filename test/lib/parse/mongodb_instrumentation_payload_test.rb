# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
require "active_support/notifications"

# PII-leak regression insurance for `parse.mongodb.aggregate` and
# `parse.mongodb.find`. The payload schema is a public contract: APM
# converters, OTel exporters, and the bundled slow-query subscriber
# all read these keys. Adding a field that ferries pipeline bodies,
# filter bodies, projection values, or row contents into subscriber
# context is exactly the regression this test catches.
#
# Pure unit test — mocks the Mongo collection so no Docker / live
# Mongo is required. We do exercise enough of the auth-resolve and
# pipeline-walk paths that the payload reflects real production
# wiring (scope label resolves, stage_types extracts, result_count
# lands inside the block, etc.).
class MongoDBInstrumentationPayloadTest < Minitest::Test
  AGGREGATE_KEYS = %i[
    collection stage_count stage_types max_time_ms read_preference
    scope result_count
  ].freeze

  FIND_KEYS = %i[
    collection has_filter projection_keys limit max_time_ms result_count
  ].freeze

  def setup
    Parse::MongoDB.reset! if Parse::MongoDB.respond_to?(:reset!)
    @captured_pipelines = {}
    @captured_filters = {}
    ensure_client_with_master_key!("master-key-for-tests")
    install_mock_collection
  end

  def teardown
    Parse::MongoDB.reset! if Parse::MongoDB.respond_to?(:reset!)
  end

  # --------------------------------------------------------------
  # Aggregate payload contract
  # --------------------------------------------------------------

  def test_aggregate_payload_has_exact_key_set
    payload = capture_payload("parse.mongodb.aggregate") do
      Parse::MongoDB.aggregate(
        "Song",
        [{ "$match" => { "artist" => "x" } }, { "$limit" => 10 }],
        max_time_ms: 1500,
        master: true,
      )
    end
    assert_equal AGGREGATE_KEYS.sort, payload.keys.sort,
      "aggregate payload key set drifted — review whether the new key is PII-safe"
  end

  def test_aggregate_payload_field_types
    payload = capture_payload("parse.mongodb.aggregate") do
      Parse::MongoDB.aggregate(
        "Song",
        [{ "$match" => { "artist" => "x" } }, { "$limit" => 10 }],
        max_time_ms: 1500,
        master: true,
      )
    end
    assert_equal "Song", payload[:collection]
    assert_equal 2, payload[:stage_count]
    assert_equal ["$match", "$limit"], payload[:stage_types]
    assert_equal 1500, payload[:max_time_ms]
    assert_equal :master, payload[:scope]
    assert_kind_of Integer, payload[:result_count]
  end

  def test_aggregate_payload_excludes_pipeline_bodies
    payload = capture_payload("parse.mongodb.aggregate") do
      Parse::MongoDB.aggregate(
        "Song",
        [{ "$match" => { "ssn" => "555-12-3456", "email" => "x@y.z" } }],
        master: true,
      )
    end
    serialized = payload.inspect
    refute_includes serialized, "555-12-3456",
      "pipeline filter values must not appear in AS::N payload"
    refute_includes serialized, "x@y.z",
      "pipeline filter values must not appear in AS::N payload"
  end

  def test_aggregate_payload_stage_types_capped
    big_pipeline = Array.new(100) { { "$match" => {} } }
    payload = capture_payload("parse.mongodb.aggregate") do
      Parse::MongoDB.aggregate("Song", big_pipeline, master: true)
    end
    assert_equal 100, payload[:stage_count]
    assert_operator payload[:stage_types].size, :<=, 32,
      "stage_types must be capped to bound subscriber cardinality"
  end

  def test_aggregate_payload_seeds_scope_and_result_count_for_raise_path
    payload = capture_payload("parse.mongodb.aggregate") do
      begin
        Parse::MongoDB.aggregate(
          "Song",
          [{ "$out" => "leak" }],
          master: true,
        )
      rescue StandardError
        # denied stage — we only care that AS::N fires
      end
    end
    assert AGGREGATE_KEYS.all? { |k| payload.key?(k) },
      "raise path must still expose the full payload key set; missing: " \
      "#{(AGGREGATE_KEYS - payload.keys).inspect}"
  end

  # --------------------------------------------------------------
  # Find payload contract
  # --------------------------------------------------------------

  def test_find_payload_has_exact_key_set
    payload = capture_payload("parse.mongodb.find") do
      Parse::MongoDB.find(
        "Song",
        { "artist" => "x" },
        projection: { "title" => 1, "artist" => 1 },
        limit: 25,
        max_time_ms: 1000,
      )
    end
    assert_equal FIND_KEYS.sort, payload.keys.sort,
      "find payload key set drifted — review whether the new key is PII-safe"
  end

  def test_find_payload_field_types_and_pii_safety
    payload = capture_payload("parse.mongodb.find") do
      Parse::MongoDB.find(
        "Song",
        { "ssn" => "555-12-3456" },
        projection: { "title" => 1 },
        limit: 25,
      )
    end
    assert_equal "Song", payload[:collection]
    assert_equal true, payload[:has_filter]
    assert_equal ["title"], payload[:projection_keys]
    assert_equal 25, payload[:limit]
    refute_includes payload.inspect, "555-12-3456",
      "find filter values must not appear in AS::N payload"
    refute_includes payload.inspect, "ssn",
      "find filter keys must not appear in AS::N payload"
  end

  def test_find_payload_omits_scope_field
    payload = capture_payload("parse.mongodb.find") do
      Parse::MongoDB.find("Song", {}, limit: 1)
    end
    refute payload.key?(:scope),
      "find payload deliberately has no :scope — subscribers must treat it as optional"
  end

  # --------------------------------------------------------------
  # helpers
  # --------------------------------------------------------------

  private

  def capture_payload(event_name)
    captured = nil
    sub = ActiveSupport::Notifications.subscribe(event_name) do |_n, _s, _f, _id, payload|
      captured = payload
    end
    begin
      yield
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
    refute_nil captured, "expected #{event_name} to fire"
    captured
  end

  def ensure_client_with_master_key!(master_key)
    if Parse::Client.client?
      Parse.client.instance_variable_set(:@master_key, master_key)
    else
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        master_key: master_key,
      )
    end
  end

  def install_mock_collection
    captured_pipelines = @captured_pipelines
    captured_filters = @captured_filters

    mock_client = Object.new
    mock_client.define_singleton_method(:[]) do |coll_name|
      mock_collection = Object.new
      mock_collection.define_singleton_method(:aggregate) do |pipeline, _opts = {}|
        captured_pipelines[coll_name] = pipeline
        view = Object.new
        view.define_singleton_method(:to_a) { [] }
        view
      end
      mock_collection.define_singleton_method(:find) do |filter|
        captured_filters[coll_name] = filter
        cursor = Object.new
        cursor.define_singleton_method(:limit) { |_| cursor }
        cursor.define_singleton_method(:skip) { |_| cursor }
        cursor.define_singleton_method(:sort) { |_| cursor }
        cursor.define_singleton_method(:projection) { |_| cursor }
        cursor.define_singleton_method(:max_time_ms) { |_| cursor }
        cursor.define_singleton_method(:to_a) { [] }
        cursor
      end
      mock_collection
    end

    Parse::MongoDB.instance_variable_set(:@enabled, true)
    Parse::MongoDB.instance_variable_set(:@uri, "mongodb://localhost:27017/test")
    Parse::MongoDB.instance_variable_set(:@gem_available, true)
    Parse::MongoDB.instance_variable_set(:@client, mock_client)
  end
end
