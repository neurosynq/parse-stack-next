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

  def test_child_embedded_in_a_parent_object_is_projected
    parent = SNParent.new(title: "p")
    parent.define_singleton_method(:as_json) do |*|
      { "__type" => "Object", "className" => "SerializeNestedParent", "objectId" => "p1",
        "title" => "p", "child" => {
          "__type" => "Object", "className" => "SerializeNestedChild", "objectId" => "c1",
          "name" => "kid", "secret" => "do-not-leak",
        } }
    end
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
end
