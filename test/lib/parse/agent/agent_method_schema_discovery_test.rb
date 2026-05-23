# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Verifies that get_schema surfaces the FULL contract for every
# declared `agent_method`: supports_dry_run, permitted_keys,
# parameters. Lets `call_method` consumers discover the call shape
# without needing prior knowledge of the method names.
class AgentMethodSchemaDiscoveryTest < Minitest::Test
  class DiscMethodSample < Parse::Object
    parse_class "DiscMethodSample"
    property :title, :string

    def self.archive(dry_run: false, mode: "default")
      { archived: 1, mode: mode } unless dry_run
    end

    def self.list_things(limit: 10)
      { count: limit }
    end

    def rename(new_title:)
      self.title = new_title
      self
    end

    agent_method :archive, "Archive things",
                 permission: :admin, supports_dry_run: true,
                 permitted_keys: [:mode],
                 parameters: { type: "object", properties: { mode: { type: "string" } } }

    agent_method :list_things, "List recent things"

    agent_method :rename, "Rename this thing", permission: :write,
                 permitted_keys: [:new_title]
  end

  def test_format_methods_includes_supports_dry_run_when_declared
    methods = DiscMethodSample.agent_methods_for(:admin)
    formatted = Parse::Agent::MetadataRegistry.send(:format_methods, methods)
    archive = formatted.find { |m| m[:name] == "archive" }
    assert_equal true, archive[:supports_dry_run]
  end

  def test_format_methods_omits_supports_dry_run_when_not_declared
    methods = DiscMethodSample.agent_methods_for(:readonly)
    formatted = Parse::Agent::MetadataRegistry.send(:format_methods, methods)
    list = formatted.find { |m| m[:name] == "list_things" }
    refute list.key?(:supports_dry_run),
           "supports_dry_run should be absent from the response when the method didn't declare it"
  end

  def test_format_methods_includes_permitted_keys_when_declared
    # permitted_keys is only disclosed when agent_debug is enabled; verify
    # it surfaces correctly in that mode.
    original = Parse::Agent.agent_debug
    Parse::Agent.agent_debug = true
    methods = DiscMethodSample.agent_methods_for(:write)
    formatted = Parse::Agent::MetadataRegistry.send(:format_methods, methods)
    rename = formatted.find { |m| m[:name] == "rename" }
    assert_equal %w[new_title], rename[:permitted_keys]
  ensure
    Parse::Agent.agent_debug = original
  end

  def test_format_methods_omits_permitted_keys_when_not_declared
    methods = DiscMethodSample.agent_methods_for(:readonly)
    formatted = Parse::Agent::MetadataRegistry.send(:format_methods, methods)
    list = formatted.find { |m| m[:name] == "list_things" }
    refute list.key?(:permitted_keys)
  end

  def test_format_methods_includes_parameters_when_declared
    methods = DiscMethodSample.agent_methods_for(:admin)
    formatted = Parse::Agent::MetadataRegistry.send(:format_methods, methods)
    archive = formatted.find { |m| m[:name] == "archive" }
    assert_kind_of Hash, archive[:parameters]
    assert_equal "object", archive[:parameters][:type]
    assert archive[:parameters][:properties].key?(:mode)
  end

  def test_existing_keys_still_present
    # Regression: the original schema-surface contract still holds.
    methods = DiscMethodSample.agent_methods_for(:admin)
    formatted = Parse::Agent::MetadataRegistry.send(:format_methods, methods)
    archive = formatted.find { |m| m[:name] == "archive" }
    assert_equal "class", archive[:type]
    assert_equal "admin", archive[:permission]
    assert_equal "Archive things", archive[:description]
  end
end
