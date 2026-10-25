# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# A constraint keyed by a property's declared server name must reach the
# declared storage column on the mongo-direct path. Before the fix an
# unscoped `OwnerRef` columnized to `ownerRef`, which no property declares,
# so it passed through as `OwnerRef` instead of `_p_OwnerRef`, and a `$ne` /
# `$nin` / `$exists: false` on that missing column matched every row.
class DirectDeclaredFieldNameTest < Minitest::Test
  class DeclaredNameWidget < Parse::Object
    parse_class "DeclaredNameWidget"
    belongs_to :owner_ref, as: :user, field: "OwnerRef"
    belongs_to :author, as: :user
    property :display_name, :string, field: "DisplayName"
    property :plain_title, :string
  end

  def setup
    Parse.setup(server_url: "http://localhost:1337/parse",
                application_id: "test", api_key: "test") unless Parse::Client.client?
  end

  def query
    Parse::Query.new("DeclaredNameWidget")
  end

  def convert_unscoped(field)
    query.send(:convert_field_for_direct_mongodb, field)
  end

  def convert_scoped(field)
    q = query
    Parse::Query.with_field_aliases("DeclaredNameWidget") { q.send(:convert_field_for_direct_mongodb, field) }
  end

  def test_declared_server_name_of_pointer_resolves_to_storage_column
    assert_equal "_p_OwnerRef", convert_unscoped("OwnerRef")
    assert_equal "_p_OwnerRef", convert_scoped("OwnerRef")
  end

  def test_ruby_name_of_pointer_resolves_to_storage_column
    assert_equal "_p_OwnerRef", convert_unscoped("owner_ref")
    assert_equal "_p_OwnerRef", convert_unscoped(:owner_ref)
  end

  def test_declared_server_name_of_plain_field_resolves
    assert_equal "DisplayName", convert_unscoped("DisplayName")
    assert_equal "DisplayName", convert_unscoped("display_name")
  end

  def test_default_names_unchanged
    assert_equal "_p_author", convert_unscoped("author")
    assert_equal "plainTitle", convert_unscoped("plain_title")
    assert_equal "_id", convert_unscoped("objectId")
    assert_equal "_created_at", convert_unscoped("createdAt")
    assert_equal "_p_OwnerRef", convert_unscoped("_p_OwnerRef")
  end

  def test_pipeline_local_alias_passes_through
    assert_equal "contributor_set", convert_unscoped("contributor_set")
    assert_equal "totalPlays", convert_scoped("totalPlays")
  end

  def test_unscoped_negative_constraints_target_pointer_column
    q = query
    ptr = { "__type" => "Pointer", "className" => "_User", "objectId" => "abc" }
    assert_equal({ "_p_OwnerRef" => { "$ne" => "_User$abc" } },
                 q.send(:convert_constraints_for_direct_mongodb, { "OwnerRef" => { "$ne" => ptr } }))
    assert_equal({ "_p_OwnerRef" => { "$nin" => ["_User$abc"] } },
                 q.send(:convert_constraints_for_direct_mongodb, { "OwnerRef" => { "$nin" => [ptr] } }))
    assert_equal({ "_p_OwnerRef" => { "$exists" => false } },
                 q.send(:convert_constraints_for_direct_mongodb, { "OwnerRef" => { "$exists" => false } }))
  end

  def test_public_pipeline_uses_storage_column
    ptr = Parse::Pointer.new("_User", "abc")
    [
      DeclaredNameWidget.query("OwnerRef" => { "$ne" => ptr }),
      DeclaredNameWidget.query(:OwnerRef.ne => ptr),
      DeclaredNameWidget.query(:owner_ref.ne => ptr),
    ].each do |q|
      match = q.send(:build_direct_mongodb_pipeline).find { |s| s.key?("$match") }["$match"]
      assert_equal({ "_p_OwnerRef" => { "$ne" => "_User$abc" } }, match)
    end
    match = DeclaredNameWidget.query(:OwnerRef.exists => false)
      .send(:build_direct_mongodb_pipeline).find { |s| s.key?("$match") }["$match"]
    assert_equal({ "_p_OwnerRef" => { "$exists" => false } }, match)
  end

  def test_dotted_ref_head_resolves
    q = query
    assert_equal "$_p_OwnerRef", q.send(:rewrite_expression_for_direct_mongodb, "$OwnerRef")
  end
end
