# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# call_method results are projected recursively: an embedded child object is
# filtered through its own class's effective allowlist, not only the parent's.
class SerializeNestedPolicyTest < Minitest::Test
  class SNChild < Parse::Object
    parse_class "SerializeNestedChild"
    property :name, :string
    property :secret, :string
    agent_fields :name, :secret
  end

  class SNParent < Parse::Object
    parse_class "SerializeNestedParent"
    property :title, :string
    belongs_to :child, as: :serialize_nested_child
    agent_fields :title, :child
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse", application_id: "test",
                  api_key: "test", master_key: "test-master")
    end
  end

  def agent
    Parse::Agent.new(permissions: :readonly, fields: { SNChild => %i[name] })
  end

  def serialize(value, a = agent)
    Parse::Agent::FieldPolicy.with(a) { Parse::Agent::Tools.send(:serialize_result, value, agent: a) }
  end

  def child_json
    { "__type" => "Object", "className" => "SerializeNestedChild", "objectId" => "c1",
      "name" => "kid", "secret" => "do-not-leak" }
  end

  STAMP = "2026-01-01T00:00:00.000Z"

  # Real Parse::Object#as_json, no stubbing: a parent fetched with its
  # belongs_to child included serializes the child as a full embedded object.
  def test_fetched_belongs_to_child_is_projected
    parent = SNParent.build({
      "objectId" => "p1", "createdAt" => STAMP, "updatedAt" => STAMP, "title" => "p",
      "child" => { "__type" => "Object", "className" => "SerializeNestedChild", "objectId" => "c1",
                   "createdAt" => STAMP, "updatedAt" => STAMP, "name" => "kid", "secret" => "do-not-leak" },
    })
    raw = parent.as_json
    assert_equal "do-not-leak", raw.dig("child", "secret"), "precondition: as_json embeds the child's fields"
    out = serialize(parent)
    refute_includes JSON.generate(out), "do-not-leak"
    assert_equal "kid", out["child"]["name"]
    assert_equal "p", out["title"]
  end

  # An unsaved child (no objectId) assigned to an unsaved parent: as_json
  # still embeds it as an Object, and it is still projected.
  def test_unsaved_belongs_to_child_is_projected
    parent = SNParent.new(title: "p")
    parent.child = SNChild.new(name: "kid", secret: "do-not-leak")
    raw = parent.as_json
    assert_nil raw["child"]["objectId"], "precondition: the child has no objectId"
    assert_equal "do-not-leak", raw.dig("child", "secret")
    out = serialize(parent)
    refute_includes JSON.generate(out), "do-not-leak"
    assert_equal "kid", out["child"]["name"]
  end

  def test_object_json_inside_a_plain_hash_is_projected
    out = serialize({ "items" => [child_json] })
    refute_includes JSON.generate(out), "do-not-leak"
    assert_equal "kid", out["items"].first["name"]
  end

  def test_unrestricted_agent_still_sees_the_class_ceiling
    out = serialize({ "item" => child_json }, Parse::Agent.new(permissions: :readonly))
    assert_equal "do-not-leak", out["item"]["secret"]
  end

  def test_unsaved_embedded_object_without_an_id_is_projected
    unsaved = { "__type" => "Object", "className" => "SerializeNestedChild",
                "name" => "kid", "secret" => "do-not-leak" }
    out = serialize({ "draft" => unsaved })
    refute_includes JSON.generate(out), "do-not-leak"
    assert_equal "kid", out["draft"]["name"]
  end

  def test_aggregation_rows_drop_parse_server_internal_columns
    row = Parse::AggregationResult.new(
      { "_id" => "g1", "total" => 3, "_rperm" => ["*"], "_hashed_password" => "h",
        "nested" => { "_auth_data_github" => { "id" => "1" }, "ok" => 1 } },
    )
    out = serialize(row)
    assert_equal 3, out["total"]
    refute out.key?("_rperm")
    refute out.key?("_hashed_password")
    assert_equal({ "ok" => 1 }, out["nested"])
  end

end
