# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# Tests for the tool category metadata + category-filtered tools/list.
# Category is a Parse Stack extension that lets MCP clients narrow the
# tools/list response and lets the agent emit `_meta.category` on every
# MCP tool descriptor.
class ToolCategoriesTest < Minitest::Test
  T = Parse::Agent::Tools

  def setup
    T.reset_registry!
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
  end

  def teardown
    T.reset_registry!
    T.reset_subscribers!
  end

  # ---- Built-in categorization -------------------------------------------

  EXPECTED_BUILTIN_CATEGORIES = {
    get_all_schemas:    "schema",
    get_schema:         "schema",
    query_class:        "query",
    count_objects:      "query",
    get_object:         "query",
    get_objects:        "query",
    get_sample_objects: "query",
    explain_query:      "query",
    aggregate:          "aggregate",
    call_method:        "mutation",
    export_data:        "export",
  }.freeze

  def test_every_builtin_carries_expected_category
    EXPECTED_BUILTIN_CATEGORIES.each do |name, category|
      assert_equal category, T.category_for(name),
                   "#{name} should be in category '#{category}'"
    end
  end

  def test_category_for_unknown_tool_returns_nil
    assert_nil T.category_for(:nonexistent_tool_xyz)
  end

  # ---- BUILTIN_CATEGORIES summary ----------------------------------------

  def test_builtin_categories_constant_covers_every_used_category
    used_categories = EXPECTED_BUILTIN_CATEGORIES.values.uniq
    used_categories.each do |cat|
      assert T::BUILTIN_CATEGORIES.key?(cat),
             "BUILTIN_CATEGORIES should describe '#{cat}'"
    end
    assert T::BUILTIN_CATEGORIES.key?("custom"),
           "BUILTIN_CATEGORIES should describe the default 'custom' category"
  end

  # ---- definitions() with category filter --------------------------------

  def test_definitions_with_no_category_returns_full_allowlist
    defs = T.definitions(EXPECTED_BUILTIN_CATEGORIES.keys, format: :mcp)
    assert_equal EXPECTED_BUILTIN_CATEGORIES.size, defs.size
  end

  def test_definitions_with_category_filter_narrows_response
    defs = T.definitions(EXPECTED_BUILTIN_CATEGORIES.keys, format: :mcp, category: "query")
    names = defs.map { |d| d[:name] }
    assert_equal %w[count_objects explain_query get_object get_objects get_sample_objects query_class].sort,
                 names.sort
  end

  def test_definitions_with_unknown_category_returns_empty_array
    defs = T.definitions(EXPECTED_BUILTIN_CATEGORIES.keys, format: :mcp, category: "nonexistent")
    assert_empty defs
  end

  def test_category_filter_is_case_insensitive
    defs = T.definitions(EXPECTED_BUILTIN_CATEGORIES.keys, format: :mcp, category: "AGGREGATE")
    names = defs.map { |d| d[:name] }
    assert_equal %w[aggregate], names
  end

  # ---- MCP descriptor includes _meta.category ----------------------------

  def test_mcp_descriptor_emits_meta_category
    defs = T.definitions([:aggregate, :query_class], format: :mcp)
    defs.each do |d|
      meta = d[:_meta]
      refute_nil meta, "MCP descriptor should carry _meta for #{d[:name]}"
      assert_kind_of String, meta[:category]
      refute meta[:category].empty?, "_meta.category should be non-empty"
    end
  end

  # ---- register() respects category --------------------------------------

  def test_register_default_category_is_custom
    T.register(
      name: :__cat_test_a,
      description: "x",
      parameters: { type: "object", properties: {} },
      permission: :readonly,
      handler: ->(_a, **_kw) { { ok: true } },
    )
    assert_equal "custom", T.category_for(:__cat_test_a)
  end

  def test_register_accepts_explicit_category
    T.register(
      name: :__cat_test_b,
      description: "x",
      parameters: { type: "object", properties: {} },
      permission: :readonly,
      category: "analytics",
      handler: ->(_a, **_kw) { { ok: true } },
    )
    assert_equal "analytics", T.category_for(:__cat_test_b)
  end

  def test_register_refuses_empty_category
    assert_raises(ArgumentError) do
      T.register(
        name: :__cat_test_c,
        description: "x",
        parameters: { type: "object", properties: {} },
        permission: :readonly,
        category: "",
        handler: ->(_a, **_kw) { { ok: true } },
      )
    end
  end

  def test_registered_tool_descriptor_carries_meta_category
    T.register(
      name: :__cat_test_d,
      description: "x",
      parameters: { type: "object", properties: {} },
      permission: :readonly,
      category: "analytics",
      handler: ->(_a, **_kw) { { ok: true } },
    )
    defs = T.definitions([:__cat_test_d], format: :mcp)
    assert_equal "analytics", defs.first[:_meta][:category]
  end

  def test_category_filter_applies_to_registered_tools
    T.register(
      name: :__cat_test_e,
      description: "x",
      parameters: { type: "object", properties: {} },
      permission: :readonly,
      category: "analytics",
      handler: ->(_a, **_kw) { { ok: true } },
    )
    defs = T.definitions([:__cat_test_e, :aggregate], format: :mcp, category: "analytics")
    names = defs.map { |d| d[:name] }
    assert_equal %w[__cat_test_e], names
  end

  # ============================================================
  # list_tools discovery built-in
  # ============================================================

  def test_list_tools_returns_summary_with_name_category_description
    agent = Parse::Agent.new(permissions: :readonly)
    result = T.list_tools(agent)

    assert result[:tools].is_a?(Array)
    assert result[:tools].any?
    result[:tools].each do |row|
      assert row.key?(:name)
      assert row.key?(:category)
      assert row.key?(:description)
      # NO inputSchema / parameters — that's the point of the summary
      # tool. Full schemas are reserved for tools/list.
      refute row.key?(:inputSchema)
      refute row.key?(:parameters)
    end
  end

  def test_list_tools_carries_builtin_categories_map
    agent = Parse::Agent.new(permissions: :readonly)
    result = T.list_tools(agent)
    assert_equal T::BUILTIN_CATEGORIES, result[:categories]
  end

  def test_list_tools_includes_every_builtin_readonly_tool_by_default
    agent = Parse::Agent.new(permissions: :readonly)
    result = T.list_tools(agent)
    names = result[:tools].map { |t| t[:name] }
    # Every readonly built-in must be present in the catalog.
    %w[get_all_schemas get_schema query_class count_objects get_object
       get_objects get_sample_objects aggregate explain_query call_method
       export_data list_tools].each do |required|
      assert_includes names, required, "list_tools must catalog #{required}"
    end
  end

  def test_list_tools_with_category_filter_returns_only_matching
    agent = Parse::Agent.new(permissions: :readonly)
    result = T.list_tools(agent, category: "schema")
    names = result[:tools].map { |t| t[:name] }
    assert_equal %w[get_all_schemas get_schema].sort, names.sort
  end

  def test_list_tools_in_registry_is_readonly
    assert_includes Parse::Agent::PERMISSION_LEVELS[:readonly], :list_tools
  end
end
