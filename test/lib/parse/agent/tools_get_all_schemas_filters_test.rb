# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Unit tests for the names: / prefix: arguments on get_all_schemas. The
# filters are caller-supplied projections on top of the existing
# hidden-class catalog filter. Hidden classes must remain hidden even when
# named explicitly.
class ToolsGetAllSchemasFiltersTest < Minitest::Test
  # Mock client whose #schemas returns a pre-defined catalog. Mirrors the
  # Parse::Response shape consumed by Tools.get_all_schemas.
  class FakeSchemasClient
    def initialize(catalog)
      @catalog = catalog
    end

    def schemas(_opts = {})
      response = Object.new
      catalog = @catalog
      response.define_singleton_method(:success?) { true }
      response.define_singleton_method(:results)  { catalog }
      response.define_singleton_method(:result)   { { "results" => catalog } }
      response.define_singleton_method(:error)    { nil }
      response
    end
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
    @catalog = [
      { "className" => "Capture", "fields" => { "title" => { "type" => "String" } } },
      { "className" => "Project", "fields" => { "name"  => { "type" => "String" } } },
      { "className" => "CaptureRevision", "fields" => { "body" => { "type" => "String" } } },
      { "className" => "_User", "fields" => { "username" => { "type" => "String" } } },
    ]
    @agent = Parse::Agent.new
    @agent.instance_variable_set(:@client, FakeSchemasClient.new(@catalog))
  end

  def test_no_filter_returns_full_catalog
    result = Parse::Agent::Tools.get_all_schemas(@agent)
    names = (result[:custom] + result[:built_in]).map { |c| c[:name] }
    assert_equal %w[Capture CaptureRevision Project _User].sort, names.sort
  end

  def test_names_filter_restricts_to_explicit_class_set
    result = Parse::Agent::Tools.get_all_schemas(@agent, names: %w[Capture Project])
    names = (result[:custom] + result[:built_in]).map { |c| c[:name] }
    assert_equal %w[Capture Project].sort, names.sort
  end

  def test_prefix_filter_restricts_to_matching_class_names
    result = Parse::Agent::Tools.get_all_schemas(@agent, prefix: "Cap")
    names = (result[:custom] + result[:built_in]).map { |c| c[:name] }
    assert_equal %w[Capture CaptureRevision].sort, names.sort
  end

  def test_names_and_prefix_compose_as_intersection
    # Both filters applied: must be in the names set AND match the prefix.
    result = Parse::Agent::Tools.get_all_schemas(@agent,
                                                names: %w[Capture CaptureRevision Project],
                                                prefix: "Capture")
    names = (result[:custom] + result[:built_in]).map { |c| c[:name] }
    assert_equal %w[Capture CaptureRevision].sort, names.sort
  end

  def test_empty_names_array_is_a_noop
    # `names: []` (caller cleared the list) must NOT collapse to zero
    # results. An empty array means "no filter".
    result = Parse::Agent::Tools.get_all_schemas(@agent, names: [])
    names = (result[:custom] + result[:built_in]).map { |c| c[:name] }
    assert_equal 4, names.size
  end

  def test_empty_prefix_string_is_a_noop
    result = Parse::Agent::Tools.get_all_schemas(@agent, prefix: "")
    names = (result[:custom] + result[:built_in]).map { |c| c[:name] }
    assert_equal 4, names.size
  end

  def test_names_filter_cannot_surface_a_hidden_class
    # The hidden-class catalog filter runs BEFORE the names: filter. So
    # passing the name of a hidden class explicitly cannot probe for it.
    test = self
    hidden_method = Parse::Agent::MetadataRegistry.method(:hidden_class_names)
    Parse::Agent::MetadataRegistry.define_singleton_method(:hidden_class_names) { ["Capture"] }
    begin
      result = Parse::Agent::Tools.get_all_schemas(test.instance_variable_get(:@agent),
                                                  names: %w[Capture Project])
      names = (result[:custom] + result[:built_in]).map { |c| c[:name] }
      refute_includes names, "Capture",
                      "hidden class must not be returned even when named explicitly"
      assert_includes names, "Project"
    ensure
      Parse::Agent::MetadataRegistry.define_singleton_method(:hidden_class_names, &hidden_method)
    end
  end
end
