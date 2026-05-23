# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Pointer fields in `get_schema` output expose `target_class` (the
# className the column points at), but historically the LLM-facing
# response did not document the *value shapes* accepted when composing
# a where: constraint. That gap is what produces the "$in on a pointer
# returned 0" silent-zero failure mode — the analyst writes the wrong
# shape and gets a real-looking empty result. The `query_hint` line
# closes that gap: every Pointer field in the schema response now
# carries a one-line description of the accepted equality and $in/$nin
# shapes.
class ResultFormatterPointerHintTest < Minitest::Test
  def test_format_schema_emits_query_hint_for_pointer_fields
    schema = {
      "className" => "Membership",
      "fields"    => {
        "objectId" => { "type" => "String" },
        "team"     => { "type" => "Pointer", "targetClass" => "Team" },
        "user"     => { "type" => "Pointer", "targetClass" => "_User" },
        "name"     => { "type" => "String" },
      },
    }

    result = Parse::Agent::ResultFormatter.format_schema(schema)
    team_field = result[:fields].find { |f| f[:name] == "team" }
    user_field = result[:fields].find { |f| f[:name] == "user" }
    name_field = result[:fields].find { |f| f[:name] == "name" }

    refute_nil team_field
    refute_nil team_field[:query_hint], "Pointer fields must carry a query_hint"
    assert_match(/Pointer to Team/, team_field[:query_hint])
    assert_match(/\$in/, team_field[:query_hint])
    assert_match(/__type/, team_field[:query_hint])

    refute_nil user_field[:query_hint]
    assert_match(/_User/, user_field[:query_hint])

    # Non-pointer fields must not carry a query_hint — it's pointer-specific.
    refute name_field.key?(:query_hint), "non-pointer field must not carry query_hint"
  end

  def test_relation_targeting_hidden_class_suppresses_target_class
    # Mirrors the Pointer-side leak fix: Relation fields targeting an
    # agent_hidden class must not echo the target name in the
    # `target_class` field either.
    schema = {
      "className" => "ManifestParent",
      "fields"    => {
        "items" => { "type" => "Relation", "targetClass" => "RFPHiddenSecret" },
      },
    }
    result = Parse::Agent::ResultFormatter.format_schema(schema)
    rel = result[:fields].find { |f| f[:name] == "items" }
    refute_nil rel
    refute rel.key?(:target_class), "hidden Relation target must not leak"
  end

  def test_relation_fields_do_not_emit_query_hint_yet
    # Relations have different query semantics ($relatedTo, not $in on
    # the column directly) — leave them out of the v1 hint surface.
    schema = {
      "className" => "Project",
      "fields"    => {
        "members" => { "type" => "Relation", "targetClass" => "_User" },
      },
    }
    result = Parse::Agent::ResultFormatter.format_schema(schema)
    rel = result[:fields].find { |f| f[:name] == "members" }
    refute_nil rel
    assert_equal "_User", rel[:target_class]
    refute rel.key?(:query_hint), "Relation fields are out of scope for query_hint v1"
  end

  class RFPHiddenSecret < Parse::Object
    parse_class "RFPHiddenSecret"
    agent_hidden
  end

  def test_query_hint_suppresses_target_class_for_hidden_class_pointers
    # If the pointer targets a hidden class, neither `target_class`
    # nor the query_hint should leak the class name. The generic
    # `<targetClass>` placeholder is used so the LLM can still see
    # the *shapes* it must use.
    schema = {
      "className" => "Order",
      "fields"    => {
        "audit" => { "type" => "Pointer", "targetClass" => "RFPHiddenSecret" },
      },
    }
    result = Parse::Agent::ResultFormatter.format_schema(schema)
    field = result[:fields].find { |f| f[:name] == "audit" }
    refute_nil field
    refute field.key?(:target_class), "hidden targetClass must not leak"
    refute_match(/RFPHiddenSecret/, field[:query_hint].to_s)
    assert_match(/<targetClass>/, field[:query_hint])
  end

  def test_query_hint_uses_target_placeholder_when_target_class_missing
    schema = {
      "className" => "Weird",
      "fields"    => {
        "ptr" => { "type" => "Pointer" }, # no targetClass — degenerate but possible
      },
    }
    result = Parse::Agent::ResultFormatter.format_schema(schema)
    ptr = result[:fields].find { |f| f[:name] == "ptr" }
    refute_nil ptr
    refute_nil ptr[:query_hint], "query_hint should be emitted even when targetClass is missing"
    assert_match(/<targetClass>/, ptr[:query_hint])
  end
end
