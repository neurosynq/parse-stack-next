# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Tests that Query#aggregate forwards raw_values: and raw_field_names: through
# the Aggregation object to the REST aggregate endpoint (Parse Server 9.9.0+).
class TestAggregateRawValues < Minitest::Test

  # A tiny stub that records the call arguments to aggregate_pipeline.
  class SpyClient
    attr_reader :last_class_name, :last_pipeline, :last_raw_values, :last_raw_field_names

    def aggregate_pipeline(class_name, pipeline, raw_values: false, raw_field_names: false, **opts)
      @last_class_name   = class_name
      @last_pipeline     = pipeline
      @last_raw_values   = raw_values
      @last_raw_field_names = raw_field_names
      stub_response
    end

    private

    def stub_response
      resp = Minitest::Mock.new
      resp.expect :present?, false
      resp.expect :error?, true
      resp.expect :result, []
      resp
    end
  end

  def setup
    @query = Parse::Query.new("Post")
    @spy   = SpyClient.new
    @query.instance_variable_set(:@client, @spy)
  end

  # --- Query#aggregate interface -----------------------------------------

  def test_aggregate_accepts_raw_values_kwarg
    assert_silent do
      @query.aggregate([{ "$match" => {} }], raw_values: true).execute!
    end
  end

  def test_aggregate_accepts_raw_field_names_kwarg
    assert_silent do
      @query.aggregate([{ "$match" => {} }], raw_field_names: true).execute!
    end
  end

  def test_aggregate_defaults_both_flags_to_false
    @query.aggregate([{ "$match" => {} }]).execute!
    assert_equal false, @spy.last_raw_values
    assert_equal false, @spy.last_raw_field_names
  end

  def test_aggregate_forwards_raw_values_true
    @query.aggregate([{ "$match" => {} }], raw_values: true).execute!
    assert_equal true, @spy.last_raw_values
  end

  def test_aggregate_forwards_raw_field_names_true
    @query.aggregate([{ "$match" => {} }], raw_field_names: true).execute!
    assert_equal true, @spy.last_raw_field_names
  end

  def test_aggregate_forwards_both_flags_together
    @query.aggregate([{ "$match" => {} }], raw_values: true, raw_field_names: true).execute!
    assert_equal true, @spy.last_raw_values
    assert_equal true, @spy.last_raw_field_names
  end

  # --- API module: aggregate_pipeline body shape --------------------------
  # Exercises Parse::API::Aggregate#aggregate_pipeline directly by including
  # the module into a lightweight stub that captures the query hash.

  class APIStub
    include Parse::API::Aggregate

    attr_reader :last_query

    def request(method, path, query: {}, headers: {}, opts: {})
      @last_query = query
      stub_response
    end

    private

    def stub_response
      resp = Minitest::Mock.new
      resp.expect :present?, false
      resp
    end
  end

  def api_stub
    @api_stub ||= APIStub.new
  end

  def test_api_aggregate_pipeline_omits_raw_values_by_default
    api_stub.aggregate_pipeline("Post", [])
    refute api_stub.last_query.key?(:rawValues),
      "rawValues should not appear in the query when not set"
  end

  def test_api_aggregate_pipeline_omits_raw_field_names_by_default
    api_stub.aggregate_pipeline("Post", [])
    refute api_stub.last_query.key?(:rawFieldNames),
      "rawFieldNames should not appear in the query when not set"
  end

  def test_api_aggregate_pipeline_adds_raw_values_true
    api_stub.aggregate_pipeline("Post", [], raw_values: true)
    assert_equal true, api_stub.last_query[:rawValues]
  end

  def test_api_aggregate_pipeline_adds_raw_field_names_true
    api_stub.aggregate_pipeline("Post", [], raw_field_names: true)
    assert_equal true, api_stub.last_query[:rawFieldNames]
  end

  def test_api_aggregate_pipeline_adds_both_flags
    api_stub.aggregate_pipeline("Post", [], raw_values: true, raw_field_names: true)
    assert_equal true, api_stub.last_query[:rawValues]
    assert_equal true, api_stub.last_query[:rawFieldNames]
  end

  def test_api_aggregate_pipeline_pipeline_json_still_present
    api_stub.aggregate_pipeline("Post", [{ "$match" => { "status" => "published" } }], raw_values: true)
    assert api_stub.last_query.key?(:pipeline),
      "pipeline: key must still be present alongside rawValues"
  end
end
