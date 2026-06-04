# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Coverage for the `tools:` named-profile presets (e.g. `:lean`) added for
# token-economy: a lean readonly surface costs ~1/3 the tools/list tokens.
class ToolProfilesTest < Minitest::Test
  def setup
    Parse.setup(server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse",
                app_id: "x", api_key: "y", master_key: "z")
    Parse::Agent.suppress_master_key_warning = true
  end

  def teardown
    Parse::Agent.suppress_master_key_warning = false
  end

  def test_lean_profile_narrows_to_minimal_read_surface
    agent = Parse::Agent.new(permissions: :readonly, tools: :lean)
    tools = agent.allowed_tools.sort
    assert_equal Parse::Agent::TOOL_PROFILES[:lean].sort, tools
    assert_includes tools, :query_class
    assert_includes tools, :get_schema
    refute_includes tools, :group_by
    refute_includes tools, :atlas_text_search
    refute_includes tools, :export_data
  end

  def test_profiles_are_symbol_only_string_stays_invalid
    # A bare String is not a profile — it remains the existing "invalid
    # value" contract (avoids ambiguity with a single tool name).
    err = assert_raises(ArgumentError) do
      Parse::Agent.new(permissions: :readonly, tools: "lean")
    end
    assert_match(/must be nil, an Array of names, or a Hash/, err.message)
  end

  def test_lean_profile_is_materially_cheaper_than_full_surface
    full = Parse::Agent.new(permissions: :readonly).allowed_tools
    lean = Parse::Agent.new(permissions: :readonly, tools: :lean).allowed_tools
    full_bytes = JSON.generate(Parse::Agent::Tools.definitions(full, format: :mcp)).bytesize
    lean_bytes = JSON.generate(Parse::Agent::Tools.definitions(lean, format: :mcp)).bytesize
    assert lean_bytes < full_bytes / 2,
           "lean surface (#{lean_bytes}B) should be < half the full surface (#{full_bytes}B)"
  end

  def test_profile_cannot_elevate_above_permission_tier
    # `:lean` lists only read tools, but even if a profile named a write
    # tool, the tier intersection in allowed_tools would still exclude it.
    agent = Parse::Agent.new(permissions: :readonly, tools: :lean)
    refute_includes agent.allowed_tools, :create_object
    refute_includes agent.allowed_tools, :delete_object
  end

  def test_unknown_profile_raises_rather_than_silently_exposing_full_surface
    err = assert_raises(ArgumentError) do
      Parse::Agent.new(permissions: :readonly, tools: :leen)
    end
    assert_match(/unknown profile/, err.message)
    assert_match(/lean/, err.message)
  end

  def test_array_and_hash_forms_still_work
    arr = Parse::Agent.new(permissions: :readonly, tools: [:query_class])
    assert_equal [:query_class], arr.allowed_tools
    hsh = Parse::Agent.new(permissions: :readonly, tools: { except: [:export_data] })
    refute_includes hsh.allowed_tools, :export_data
    assert_includes hsh.allowed_tools, :query_class
  end
end
