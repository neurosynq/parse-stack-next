# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# ============================================================================
# Regression test for tool-schema validity.
#
# OpenAI's function-calling endpoint rejects any tool whose JSON Schema
# declares `type: "array"` without an accompanying `items` definition with
# `invalid_function_parameters`: "array schema missing items." Other strict
# JSON-Schema validators behave similarly. A single offending property
# anywhere in TOOL_DEFINITIONS breaks every LLM call that includes that
# tool — even when the LLM never invokes the broken tool — because OpenAI
# validates the entire tool list at request time.
#
# This test walks every built-in tool definition and asserts every array
# property (at any nesting depth) carries an `items` schema. It also
# checks a handful of structural invariants that, if violated, would make
# the schema unusable to LLMs (missing `name`, missing `parameters.type`,
# `required` referencing nonexistent properties, etc.).
# ============================================================================
class ToolsSchemaValidityTest < Minitest::Test
  TOOLS = Parse::Agent::Tools::TOOL_DEFINITIONS

  # ---- Array properties must declare `items` ------------------------------

  def test_every_array_property_has_items
    offenders = []
    TOOLS.each do |tool_name, defn|
      walk_array_props(defn.dig(:parameters), []) do |path, node|
        offenders << "#{tool_name}: #{path.join('.')} -> #{node.inspect}" unless node.key?(:items)
      end
    end
    assert_empty offenders,
                 "These array properties lack an `items` schema and will be rejected by OpenAI " \
                 "(invalid_function_parameters: \"array schema missing items.\"): \n  " +
                 offenders.join("\n  ")
  end

  # ---- Structural invariants ----------------------------------------------

  def test_every_tool_has_name_description_parameters
    TOOLS.each do |tool_name, defn|
      assert_equal tool_name.to_s, defn[:name], "#{tool_name} :name mismatch"
      refute_nil defn[:description], "#{tool_name} missing :description"
      refute_nil defn[:parameters],  "#{tool_name} missing :parameters"
    end
  end

  def test_every_parameters_block_is_an_object_schema
    TOOLS.each do |tool_name, defn|
      params = defn[:parameters]
      assert_equal "object", params[:type], "#{tool_name} :parameters type must be 'object'"
      assert_kind_of Hash, params[:properties], "#{tool_name} :properties must be a Hash"
    end
  end

  # ---- Output-schema invariants (MCP structuredContent) -------------------
  # Built-in tools that opt into MCP structuredContent declare :output_schema
  # at the TOOL_DEFINITIONS level. The same array-missing-items defect class
  # that breaks input parameters also breaks any client that validates
  # structuredContent against the advertised outputSchema (MCP 2025-06-18
  # SHOULD validation). Walk every declared output_schema with the same rule.

  def test_every_output_schema_array_property_has_items
    offenders = []
    TOOLS.each do |tool_name, defn|
      schema = defn[:output_schema]
      next if schema.nil?
      walk_array_props(schema, []) do |path, node|
        offenders << "#{tool_name}: output_schema.#{path.join('.')} -> #{node.inspect}" unless node.key?(:items)
      end
    end
    assert_empty offenders,
                 "These output_schema array properties lack an `items` schema:\n  " +
                 offenders.join("\n  ")
  end

  def test_every_output_schema_is_an_object_schema_when_declared
    TOOLS.each do |tool_name, defn|
      schema = defn[:output_schema]
      next if schema.nil?
      assert_equal "object", schema[:type],
                   "#{tool_name} :output_schema type must be 'object' (MCP requires an object envelope)"
      assert_kind_of Hash, schema[:properties],
                     "#{tool_name} :output_schema must declare :properties"
    end
  end

  def test_required_only_references_declared_properties
    offenders = []
    TOOLS.each do |tool_name, defn|
      params   = defn[:parameters]
      required = params[:required] || []
      declared = (params[:properties] || {}).keys.map(&:to_s)
      required.each do |r|
        offenders << "#{tool_name}: required key #{r.inspect} not in properties #{declared.inspect}" \
          unless declared.include?(r.to_s)
      end
    end
    assert_empty offenders, "Tools list `required` keys with no matching property:\n  " + offenders.join("\n  ")
  end

  private

  # Recursively walk a JSON-Schema-shaped Hash and yield every node whose
  # type is "array". Tracks the symbol path from the schema root so the
  # failure message can locate the offending property.
  def walk_array_props(node, path, &blk)
    return unless node.is_a?(Hash)
    yield(path, node) if node[:type] == "array"

    if (props = node[:properties]).is_a?(Hash)
      props.each { |k, v| walk_array_props(v, path + [k], &blk) }
    end
    if (items = node[:items]).is_a?(Hash)
      walk_array_props(items, path + [:items], &blk)
    end
    %i[oneOf anyOf allOf].each do |comb|
      next unless node[comb].is_a?(Array)
      node[comb].each_with_index do |sub, i|
        walk_array_props(sub, path + [:"#{comb}[#{i}]"], &blk)
      end
    end
  end
end
