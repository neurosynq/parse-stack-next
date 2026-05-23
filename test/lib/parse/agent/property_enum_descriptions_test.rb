# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Tests for the `_enum:` option on `property`, which documents the per-value
# semantics of an enum-shaped string column for an LLM. The mechanism is
# orthogonal to the existing `enum:` validation option — `enum:` constrains
# the value set, `_enum:` describes each value.
class PropertyEnumDescriptionsTest < Minitest::Test
  class PEDMembership < Parse::Object
    parse_class "PEDMembership"

    property :grant, :string, _description: "Scope of the membership grant",
                              _enum: {
                                team:         "Member of a team within the org",
                                project:      "Member of a single project under a team",
                                organization: "Member of the org as a whole",
                              }
    property :account_level, :string, _enum: {
      basic:         "Default tier",
      paid:          "Active paid subscription",
      complimentary: "Granted by support; non-billable",
    }
    property :active, :boolean
    property :title, :string
  end

  class PEDNoEnum < Parse::Object
    parse_class "PEDNoEnum"
    property :name, :string
  end

  # Fixture exercising the `field:` alias path. The schema returns the
  # column under its alias name (`"ExtStatus"`), not the snake_case Ruby
  # symbol — without the field_map reverse lookup the description/enum
  # entries silently dropped because `"ExtStatus".underscore.to_sym` is
  # `:ext_status`, not `:external_status`.
  class PEDAliased < Parse::Object
    parse_class "PEDAliased"
    property :external_status, :string, field: :ExtStatus,
                                        _description: "Status from upstream system",
                                        _enum: { active: "Currently operational",
                                                 retired: "End-of-life" }
  end

  # Fixture covering edge cases: empty _enum: hash (should no-op) and
  # _enum: on a non-string type (footgun — the implementation stringifies
  # value keys unconditionally; this test pins that behavior so a future
  # change is intentional, not accidental).
  class PEDEdgeCases < Parse::Object
    parse_class "PEDEdgeCases"
    property :empty_enum, :string, _enum: {}
    property :count, :integer, _enum: { 1 => "low", 2 => "high" }
  end

  # ============================================================
  # DSL storage
  # ============================================================

  def test_property_enum_descriptions_stores_normalized_string_keys
    enums = PEDMembership.property_enum_descriptions
    assert enums.key?(:grant), "grant should be stored under its property symbol"
    assert_equal({
      "team"         => "Member of a team within the org",
      "project"      => "Member of a single project under a team",
      "organization" => "Member of the org as a whole",
    }, enums[:grant])
  end

  def test_property_enum_descriptions_is_frozen
    enums = PEDMembership.property_enum_descriptions[:grant]
    assert enums.frozen?, "value hash should be frozen to prevent mutation by callers"
  end

  def test_property_enum_descriptions_empty_when_undeclared
    assert_empty PEDNoEnum.property_enum_descriptions
    refute PEDMembership.property_enum_descriptions.key?(:active),
           "properties without _enum: should not produce a hash entry"
  end

  def test_property_with_description_and_enum_both_render
    descs = PEDMembership.property_descriptions
    assert_equal "Scope of the membership grant", descs[:grant]
    refute_nil PEDMembership.property_enum_descriptions[:grant]
  end

  def test_agent_metadata_serialization_includes_property_enum_descriptions
    serialized = PEDMembership.agent_metadata
    assert serialized.key?(:property_enum_descriptions),
           "agent_metadata serialization must expose property_enum_descriptions"
    assert_equal "Member of a team within the org",
                 serialized[:property_enum_descriptions][:grant]["team"]
  end

  def test_property_enum_descriptions_do_not_leak_between_classes
    # Per-class @property_enum_descriptions storage means declaring _enum:
    # on one class must NOT surface those entries on a sibling. Pins the
    # isolation in case a future refactor accidentally promotes the hash
    # to a shared global or up the inheritance chain.
    assert_empty PEDNoEnum.property_enum_descriptions,
                 "sibling class without _enum: must have an empty enum hash"
    refute PEDNoEnum.property_enum_descriptions.key?(:grant),
           "sibling class must not see _enum: entries declared on a different class"
  end

  def test_empty_enum_hash_is_a_noop
    refute PEDEdgeCases.property_enum_descriptions.key?(:empty_enum),
           "_enum: {} should not produce a storage entry"
  end

  def test_enum_on_integer_property_stringifies_keys
    # Pins the documented footgun: _enum: on a non-string column doesn't
    # raise, but value keys are stringified. The CHANGELOG and yardoc
    # both call this out as userland's responsibility.
    enum = PEDEdgeCases.property_enum_descriptions[:count]
    refute_nil enum, "_enum: on integer column still stores (no type guard)"
    assert_equal %w[1 2], enum.keys.sort,
                 "value keys are stringified regardless of column type — userland must keep _enum: on string columns"
  end

  # ============================================================
  # field: alias path
  # ============================================================

  def test_enrich_fields_resolves_description_under_field_alias
    # Server returns the column as "ExtStatus" (the alias), not the
    # snake_case Ruby symbol. The reverse field_map lookup must find
    # :external_status from "ExtStatus" and recover the description.
    server_schema = {
      "className" => "PEDAliased",
      "fields"    => { "ExtStatus" => { "type" => "String" } },
    }
    result = Parse::Agent::MetadataRegistry.enriched_schema("PEDAliased", server_schema)
    assert_equal "Status from upstream system", result["fields"]["ExtStatus"]["description"]
  end

  def test_enrich_fields_resolves_allowed_values_under_field_alias
    server_schema = {
      "className" => "PEDAliased",
      "fields"    => { "ExtStatus" => { "type" => "String" } },
    }
    result = Parse::Agent::MetadataRegistry.enriched_schema("PEDAliased", server_schema)
    values = result["fields"]["ExtStatus"]["allowed_values"]
    refute_nil values, "_enum: declared on an aliased property must surface under the alias name"
    assert_equal 2, values.size
    assert_includes values.map { |v| v["value"] }, "active"
  end

  # ============================================================
  # enrich_fields integration
  # ============================================================

  def test_enrich_fields_emits_allowed_values_for_enum_property
    server_schema = {
      "className" => "PEDMembership",
      "fields"    => {
        "objectId"     => { "type" => "String" },
        "grant"        => { "type" => "String" },
        "accountLevel" => { "type" => "String" },
        "active"       => { "type" => "Boolean" },
      },
    }
    result = Parse::Agent::MetadataRegistry.enriched_schema("PEDMembership", server_schema)
    grant = result["fields"]["grant"]
    assert grant["allowed_values"].is_a?(Array), "allowed_values should be an array"
    assert_equal 3, grant["allowed_values"].size
    team = grant["allowed_values"].find { |v| v["value"] == "team" }
    assert_equal "Member of a team within the org", team["description"]
  end

  def test_enrich_fields_handles_snake_case_property_against_camel_case_column
    # account_level (Ruby snake_case symbol) declared with _enum:,
    # surfaced under accountLevel (lowerCamelCase wire name) in the schema.
    # The 3-key lookup in enrich_fields must reach the descriptions hash.
    server_schema = {
      "className" => "PEDMembership",
      "fields"    => {
        "accountLevel" => { "type" => "String" },
      },
    }
    result = Parse::Agent::MetadataRegistry.enriched_schema("PEDMembership", server_schema)
    account = result["fields"]["accountLevel"]
    refute_nil account["allowed_values"], "snake_case _enum: should match camelCase wire name"
    paid = account["allowed_values"].find { |v| v["value"] == "paid" }
    assert_equal "Active paid subscription", paid["description"]
  end

  def test_enrich_fields_omits_allowed_values_when_no_enum_declared
    server_schema = {
      "className" => "PEDMembership",
      "fields"    => {
        "active" => { "type" => "Boolean" },
        "title"  => { "type" => "String" },
      },
    }
    result = Parse::Agent::MetadataRegistry.enriched_schema("PEDMembership", server_schema)
    refute result["fields"]["active"].key?("allowed_values")
    refute result["fields"]["title"].key?("allowed_values")
  end

  # ============================================================
  # format_fields_detailed surface
  # ============================================================

  def test_format_schema_surfaces_allowed_values_in_field_entry
    server_schema = {
      "className" => "PEDMembership",
      "fields"    => {
        "grant"        => { "type" => "String" },
        "accountLevel" => { "type" => "String" },
        "active"       => { "type" => "Boolean" },
      },
    }
    enriched  = Parse::Agent::MetadataRegistry.enriched_schema("PEDMembership", server_schema)
    formatted = Parse::Agent::ResultFormatter.format_schema(enriched)
    grant_field = formatted[:fields].find { |f| f[:name] == "grant" }
    assert grant_field[:allowed_values].is_a?(Array)
    assert_equal "Member of a team within the org",
                 grant_field[:allowed_values].find { |v| v["value"] == "team" }["description"]
    active_field = formatted[:fields].find { |f| f[:name] == "active" }
    refute active_field.key?(:allowed_values), "non-enum fields must not carry an allowed_values key"
  end
end
