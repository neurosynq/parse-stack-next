# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Tests for the top-level `agent_fields` / `agent_join_fields` echo on
# `get_schema`. The allowlist is enforced by stripping non-allowed fields
# from the response, but enforcement-by-omission left consumers guessing
# what they could write in `keys:` — these tests pin the explicit echo
# that closes that gap.
class GetSchemaAllowlistEchoTest < Minitest::Test
  class GSEAllowlisted < Parse::Object
    parse_class "GSEAllowlisted"

    agent_description "Class with both a direct allowlist and a join projection"
    agent_fields :name, :status, :member_count, :icon_image
    agent_large_fields :icon_image
    agent_join_fields :name, :status

    property :name, :string
    property :status, :string
    property :member_count, :integer
    property :icon_image, :string
    property :legacy_blob, :object
  end

  class GSEUnfiltered < Parse::Object
    parse_class "GSEUnfiltered"
    property :name, :string
  end

  # ============================================================
  # enriched_schema sets schema["agent_fields"] in wire format
  # ============================================================

  def test_enriched_schema_sets_agent_fields_in_wire_format
    server_schema = {
      "className" => "GSEAllowlisted",
      "fields"    => {
        "objectId"    => { "type" => "String" },
        "createdAt"   => { "type" => "Date" },
        "updatedAt"   => { "type" => "Date" },
        "ACL"         => { "type" => "ACL" },
        "name"        => { "type" => "String" },
        "status"      => { "type" => "String" },
        "memberCount" => { "type" => "Number" },
        "iconImage"   => { "type" => "String" },
        "legacyBlob"  => { "type" => "Object" },
      },
    }
    result = Parse::Agent::MetadataRegistry.enriched_schema("GSEAllowlisted", server_schema)
    refute_nil result["agent_fields"]
    # snake_case agent_fields entries should resolve through field_map to lowerCamelCase wire names
    %w[name status memberCount iconImage].each do |wire|
      assert_includes result["agent_fields"], wire, "expected wire name #{wire} in echo"
    end
    # ALWAYS_KEEP_FIELDS are implicit and excluded from the echo to avoid noise
    refute_includes result["agent_fields"], "objectId"
    refute_includes result["agent_fields"], "createdAt"
    refute_includes result["agent_fields"], "updatedAt"
  end

  def test_enriched_schema_sets_agent_join_fields_when_declared
    server_schema = { "className" => "GSEAllowlisted", "fields" => {} }
    result = Parse::Agent::MetadataRegistry.enriched_schema("GSEAllowlisted", server_schema)
    refute_nil result["agent_join_fields"]
    assert_includes result["agent_join_fields"], "name"
    assert_includes result["agent_join_fields"], "status"
    refute_includes result["agent_join_fields"], "iconImage",
                    "join fields should be the narrower set; iconImage is in agent_fields but not agent_join_fields"
  end

  def test_enriched_schema_omits_echoes_when_no_allowlist_declared
    server_schema = {
      "className" => "GSEUnfiltered",
      "fields"    => { "name" => { "type" => "String" } },
    }
    result = Parse::Agent::MetadataRegistry.enriched_schema("GSEUnfiltered", server_schema)
    refute result.key?("agent_fields"), "agent_fields echo must be omitted when not declared"
  end

  # ============================================================
  # format_schema lifts the echo into the top-level result envelope
  # ============================================================

  def test_format_schema_surfaces_agent_fields_at_top_level
    server_schema = {
      "className" => "GSEAllowlisted",
      "fields"    => {
        "name"        => { "type" => "String" },
        "status"      => { "type" => "String" },
        "memberCount" => { "type" => "Number" },
      },
    }
    enriched  = Parse::Agent::MetadataRegistry.enriched_schema("GSEAllowlisted", server_schema)
    formatted = Parse::Agent::ResultFormatter.format_schema(enriched)
    assert formatted[:agent_fields].is_a?(Array)
    assert_includes formatted[:agent_fields], "name"
  end

  def test_format_schema_surfaces_agent_join_fields_at_top_level
    server_schema = { "className" => "GSEAllowlisted", "fields" => {} }
    enriched  = Parse::Agent::MetadataRegistry.enriched_schema("GSEAllowlisted", server_schema)
    formatted = Parse::Agent::ResultFormatter.format_schema(enriched)
    assert formatted[:agent_join_fields].is_a?(Array)
    assert_includes formatted[:agent_join_fields], "name"
    assert_includes formatted[:agent_join_fields], "status"
  end

  def test_format_schema_omits_echoes_for_unfiltered_class
    server_schema = {
      "className" => "GSEUnfiltered",
      "fields"    => { "name" => { "type" => "String" } },
    }
    enriched  = Parse::Agent::MetadataRegistry.enriched_schema("GSEUnfiltered", server_schema)
    formatted = Parse::Agent::ResultFormatter.format_schema(enriched)
    refute formatted.key?(:agent_fields), "echo must not appear when no allowlist is declared"
    refute formatted.key?(:agent_join_fields)
  end

  # ============================================================
  # Sanity: existing field-trimming behavior is preserved
  # ============================================================

  def test_existing_field_trimming_is_unaffected_by_echo
    server_schema = {
      "className" => "GSEAllowlisted",
      "fields"    => {
        "name"       => { "type" => "String" },
        "legacyBlob" => { "type" => "Object" },
      },
    }
    result = Parse::Agent::MetadataRegistry.enriched_schema("GSEAllowlisted", server_schema)
    refute result["fields"].key?("legacyBlob"),
           "fields hash should still be filtered to the allowlist regardless of the new echo"
  end
end
