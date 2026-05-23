# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Tests for the agent_fields / agent_usage DSL added to Parse::Object via
# Parse::Agent::MetadataDSL, plus the schema-enrichment and key-projection
# behavior that depends on them.
class AgentFieldAllowlistTest < Minitest::Test
  # Fixture model: declares both a field allowlist and a usage hint, plus
  # several noisy fields that must NOT surface to the agent.
  class FixtureTeam < Parse::Object
    parse_class "FixtureTeam"

    agent_description "A workspace grouping users on a project"
    agent_usage <<~USAGE
      `status` values: "active" | "archived" | "frozen".
      `member_count` is denormalized; recompute via _User pointer.
    USAGE
    agent_fields :name, :status, :member_count

    property :name, :string
    property :status, :string
    property :member_count, :integer
    property :legacy_settings_blob, :object
    property :sync_token, :string
  end

  # Fixture with no agent_fields declaration — should not be filtered.
  class FixtureUnfiltered < Parse::Object
    parse_class "FixtureUnfiltered"
    agent_description "Class without an allowlist"
    property :foo, :string
    property :bar, :integer
  end

  # ============================================================
  # DSL: agent_fields
  # ============================================================

  def test_agent_fields_stores_allowlist_as_symbols
    assert_equal %i[name status member_count], FixtureTeam.agent_field_allowlist
  end

  def test_agent_fields_returns_empty_when_undeclared
    assert_equal [], FixtureUnfiltered.agent_field_allowlist
  end

  class FixtureCoerce < Parse::Object
    parse_class "FixtureCoerce"
    agent_fields "alpha", :beta
  end

  def test_agent_fields_accepts_strings_and_normalizes_to_symbols
    assert_equal %i[alpha beta], FixtureCoerce.agent_field_allowlist
  end

  def test_agent_fields_allowlist_is_frozen
    assert_predicate FixtureTeam.agent_field_allowlist, :frozen?
  end

  # ============================================================
  # DSL: agent_usage
  # ============================================================

  def test_agent_usage_stores_text
    refute_nil FixtureTeam.agent_usage
    assert_match(/status.*values/, FixtureTeam.agent_usage)
  end

  def test_agent_usage_returns_nil_when_undeclared
    assert_nil FixtureUnfiltered.agent_usage
  end

  class FixtureUsage < Parse::Object
    parse_class "FixtureUsage"
    agent_usage "   hello   \n"
  end

  def test_agent_usage_strips_whitespace_and_freezes
    assert_equal "hello", FixtureUsage.agent_usage
    assert_predicate FixtureUsage.agent_usage, :frozen?
  end

  # ============================================================
  # has_agent_metadata? / agent_metadata
  # ============================================================

  class FixtureHasFields < Parse::Object
    parse_class "FixtureHasFields"
    agent_fields :only_field
  end

  class FixtureHasUsage < Parse::Object
    parse_class "FixtureHasUsage"
    agent_usage "hint"
  end

  def test_has_agent_metadata_includes_allowlist_and_usage
    assert FixtureHasFields.has_agent_metadata?, "agent_fields declaration alone should mark metadata as present"
    assert FixtureHasUsage.has_agent_metadata?, "agent_usage declaration alone should mark metadata as present"
  end

  def test_agent_metadata_serializes_field_allowlist_and_usage
    meta = FixtureTeam.agent_metadata
    assert_equal %i[name status member_count], meta[:field_allowlist]
    assert_match(/status.*values/, meta[:usage])
  end

  # ============================================================
  # MetadataRegistry.enriched_schema field filtering
  # ============================================================

  def test_enriched_schema_filters_fields_to_allowlist_plus_system_fields
    # Parse Server schemas serialize column names in lowerCamelCase wire format
    # ("memberCount", "legacySettingsBlob"), so the allowlist comparison must
    # also operate in wire-format. Snake_case Ruby property names declared
    # via `agent_fields :member_count` are normalized through field_map.
    server_schema = {
      "className" => "FixtureTeam",
      "fields" => {
        "objectId" => { "type" => "String" },
        "createdAt" => { "type" => "Date" },
        "updatedAt" => { "type" => "Date" },
        "ACL" => { "type" => "ACL" },
        "name" => { "type" => "String" },
        "status" => { "type" => "String" },
        "memberCount" => { "type" => "Number" },
        "legacySettingsBlob" => { "type" => "Object" },
        "syncToken" => { "type" => "String" },
      },
    }

    result = Parse::Agent::MetadataRegistry.enriched_schema("FixtureTeam", server_schema)
    expected_keys = %w[objectId createdAt updatedAt name status memberCount].sort
    assert_equal expected_keys, result["fields"].keys.sort
    refute result["fields"].key?("ACL"), "ACL must not pass through allowlist"
    refute result["fields"].key?("legacySettingsBlob"), "non-allowlisted columns must be filtered"
  end

  def test_enriched_schema_strips_noisy_per_field_metadata
    server_schema = {
      "className" => "FixtureTeam",
      "fields" => {
        "name" => { "type" => "String", "indexed" => true, "required" => true, "defaultValue" => "" },
        "status" => { "type" => "String", "defaultValue" => "active" },
      },
    }

    result = Parse::Agent::MetadataRegistry.enriched_schema("FixtureTeam", server_schema)
    refute result["fields"]["name"].key?("indexed"), "indexed metadata must be stripped"
    refute result["fields"]["name"].key?("defaultValue"), "empty-string defaultValue must be stripped"
    assert_equal true, result["fields"]["name"]["required"]
    assert_equal "active", result["fields"]["status"]["defaultValue"], "meaningful defaultValue is kept"
  end

  def test_enriched_schema_surfaces_usage
    server_schema = { "className" => "FixtureTeam", "fields" => {} }
    result = Parse::Agent::MetadataRegistry.enriched_schema("FixtureTeam", server_schema)
    assert_match(/status.*values/, result["usage"])
  end

  def test_enriched_schema_unfiltered_class_passes_all_fields_through
    server_schema = {
      "className" => "FixtureUnfiltered",
      "fields" => {
        "objectId" => { "type" => "String" },
        "ACL" => { "type" => "ACL" },
        "foo" => { "type" => "String" },
        "bar" => { "type" => "Number" },
      },
    }
    result = Parse::Agent::MetadataRegistry.enriched_schema("FixtureUnfiltered", server_schema)
    assert result["fields"].key?("ACL"), "no allowlist means no filtering"
    assert result["fields"].key?("foo")
    assert result["fields"].key?("bar")
  end

  # ============================================================
  # MetadataRegistry.field_allowlist (used by Tools to push keys server-side)
  # ============================================================

  def test_field_allowlist_returns_strings_with_system_fields
    # Wire format: `:member_count` -> `field_map[:member_count]` -> `:memberCount`
    # System fields always pass through.
    allowlist = Parse::Agent::MetadataRegistry.field_allowlist("FixtureTeam")
    %w[name status memberCount objectId createdAt updatedAt].each do |f|
      assert_includes allowlist, f
    end
    refute_includes allowlist, "member_count",
      "allowlist must use wire-format column names, not snake_case Ruby names"
  end

  def test_field_allowlist_returns_nil_for_unfiltered_class
    assert_nil Parse::Agent::MetadataRegistry.field_allowlist("FixtureUnfiltered")
  end

  def test_field_allowlist_returns_nil_for_unknown_class
    assert_nil Parse::Agent::MetadataRegistry.field_allowlist("NoSuchClassAnywhere")
  end

  # ============================================================
  # Regression: snake_case agent_fields must map to camelCase wire names
  # ============================================================
  #
  # Reproduces the defect where `agent_fields :device_type` was compared
  # case-sensitively against Parse Server's `"deviceType"` wire-format column
  # and silently stripped from `enriched_schema`, `keys:` projection, and
  # pipeline access policy. The user-reported symptom was that every snake_case
  # field on `_Installation` (deviceType, appName, appIdentifier, appVersion,
  # appBuildNumber) vanished from the schema get_schema returned to the LLM.

  class FixtureDeviceLog < Parse::Object
    parse_class "FixtureDeviceLog"
    agent_fields :user, :device_type, :app_name, :app_identifier, :app_version, :app_build_number
    belongs_to :user
    property :device_type, :string
    property :app_name, :string
    property :app_identifier, :string
    property :app_version, :string
    property :app_build_number, :integer
  end

  def test_field_allowlist_normalizes_snake_case_to_wire_format
    allowlist = Parse::Agent::MetadataRegistry.field_allowlist("FixtureDeviceLog")
    refute_nil allowlist
    %w[user deviceType appName appIdentifier appVersion appBuildNumber].each do |wire|
      assert_includes allowlist, wire,
        "snake_case agent_fields entry must surface in wire-format (#{wire})"
    end
    refute_includes allowlist, "device_type",
      "snake_case form must not leak through — keys: projection would no-op against the server"
    refute_includes allowlist, "app_name"
  end

  def test_enriched_schema_keeps_snake_case_declared_fields_when_server_uses_camel_case
    server_schema = {
      "className" => "FixtureDeviceLog",
      "fields" => {
        "objectId" => { "type" => "String" },
        "createdAt" => { "type" => "Date" },
        "updatedAt" => { "type" => "Date" },
        "ACL" => { "type" => "ACL" },
        "user" => { "type" => "Pointer", "targetClass" => "_User" },
        "deviceType" => { "type" => "String" },
        "appName" => { "type" => "String" },
        "appIdentifier" => { "type" => "String" },
        "appVersion" => { "type" => "String" },
        "appBuildNumber" => { "type" => "Number" },
        "internalNotes" => { "type" => "String" },
      },
    }

    result = Parse::Agent::MetadataRegistry.enriched_schema("FixtureDeviceLog", server_schema)
    expected = %w[objectId createdAt updatedAt user deviceType appName appIdentifier appVersion appBuildNumber].sort
    assert_equal expected, result["fields"].keys.sort,
      "every snake_case allowlist entry must survive enrichment against the camelCase server schema"
    refute result["fields"].key?("ACL")
    refute result["fields"].key?("internalNotes"), "fields outside the allowlist must still be stripped"
  end

  # Property declared with an explicit `field:` alias — field_map carries the
  # custom wire name, which must take priority over the columnize fallback.

  class FixtureAliasedProperty < Parse::Object
    parse_class "FixtureAliasedProperty"
    agent_fields :external_id, :name
    property :external_id, :string, field: :ExternalReferenceCode
    property :name, :string
  end

  def test_field_allowlist_honors_property_field_alias
    allowlist = Parse::Agent::MetadataRegistry.field_allowlist("FixtureAliasedProperty")
    refute_nil allowlist
    assert_includes allowlist, "ExternalReferenceCode",
      "field_map must take priority over columnize so `field:` aliases resolve correctly"
    assert_includes allowlist, "name"
    refute_includes allowlist, "externalId",
      "columnize fallback must not override an explicit field_map entry"
    refute_includes allowlist, "external_id"
  end

  def test_enriched_schema_keeps_field_aliased_property_under_aliased_wire_name
    server_schema = {
      "className" => "FixtureAliasedProperty",
      "fields" => {
        "objectId" => { "type" => "String" },
        "ExternalReferenceCode" => { "type" => "String" },
        "name" => { "type" => "String" },
        "secret" => { "type" => "String" },
      },
    }
    result = Parse::Agent::MetadataRegistry.enriched_schema("FixtureAliasedProperty", server_schema)
    assert result["fields"].key?("ExternalReferenceCode")
    assert result["fields"].key?("name")
    refute result["fields"].key?("secret")
  end

  # Defense-in-depth: a developer who aliases a property to a Parse Server
  # internal column (`field: :_hashed_password`) and then lists it in
  # `agent_fields` must still be refused — the wire-name verbatim path
  # bypasses columnize's underscore-stripping, but the explicit denylist
  # check catches it.

  class FixtureAliasToInternalColumn < Parse::Object
    parse_class "FixtureAliasToInternalColumn"
    agent_fields :pw, :safe_field
    property :pw, :string, field: :_hashed_password
    property :safe_field, :string
  end

  def test_field_allowlist_drops_internal_column_aliases
    allowlist = Parse::Agent::MetadataRegistry.field_allowlist("FixtureAliasToInternalColumn")
    refute_nil allowlist
    refute_includes allowlist, "_hashed_password",
      "INTERNAL_FIELDS_DENYLIST entries must be dropped from the agent surface even when a `property field:` alias maps to them"
    assert_includes allowlist, "safeField",
      "non-internal entries must continue to surface"
  end
end
