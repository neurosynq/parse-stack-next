# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# `Parse::Object.new(as:)` accepts the ACL owner only from a Symbol key and
# only as a user, and `persisted?` means "exists on the server" so Rails
# forms re-render an edit with errors as an update.
class ObjectOwnerOptionAndPersistedTest < Minitest::Test
  class OwnedDoc < Parse::Object
    parse_class "OwnerOptionDoc"
    property :title, :string
    acl_policy :owner_else_private
  end

  def resolved_acl(obj)
    obj.send(:_resolve_default_acl)
    obj.acl.as_json
  end

  # --- as: -------------------------------------------------------------------

  def test_symbol_as_with_user_id_grants_owner
    acl = resolved_acl(OwnedDoc.new(title: "a", as: "user123"))
    assert_equal({ "user123" => { "read" => true, "write" => true } }, acl)
  end

  def test_symbol_as_with_user_object_and_pointer
    user = Parse::User.new("u1")
    assert_equal ["u1"], resolved_acl(OwnedDoc.new(as: user)).keys
    pointer = Parse::Pointer.new(Parse::Model::CLASS_USER, "u2")
    assert_equal ["u2"], resolved_acl(OwnedDoc.new(as: pointer)).keys
  end

  def test_string_as_key_is_dropped_and_ignored
    doc = OwnedDoc.new("title" => "a", "as" => "*")
    acl = resolved_acl(doc)
    refute acl.key?("*"), "form params must not make the record public"
    assert_equal({}, acl, "falls back to the private else-half")
    refute doc.respond_to?(:as), "the as key is not mass-assigned"
  end

  def test_indifferent_access_as_key_is_ignored
    params = ActiveSupport::HashWithIndifferentAccess.new("title" => "a", "as" => "user123")
    acl = resolved_acl(OwnedDoc.new(params))
    assert_equal({}, acl)
  end

  def test_caller_hash_is_not_mutated
    input = { title: "a", as: "user123" }
    OwnedDoc.new(input)
    assert_equal "user123", input[:as]
  end

  def test_refuses_public_role_and_non_user_owners
    ["*", "role:Admin", "", 42, Parse::Pointer.new("Post", "p1"),
     Parse::Pointer.new(Parse::Model::CLASS_USER, nil)].each do |bad|
      assert_raises(ArgumentError, "as: #{bad.inspect} must be refused") do
        OwnedDoc.new(title: "a", as: bad)
      end
    end
  end

  def test_nil_as_is_allowed
    assert_equal({}, resolved_acl(OwnedDoc.new(title: "a", as: nil)))
  end

  def test_owner_resolver_refuses_public_and_role_strings
    doc = OwnedDoc.new
    assert_nil doc.send(:_resolve_acl_owner_id, "*")
    assert_nil doc.send(:_resolve_acl_owner_id, "role:Admin")
    assert_equal "abc", doc.send(:_resolve_acl_owner_id, "abc")
  end

  # --- persisted? ------------------------------------------------------------

  def test_new_object_is_not_persisted
    refute OwnedDoc.new(title: "a").persisted?
  end

  def test_fetched_object_with_changes_is_persisted
    doc = OwnedDoc.build({ "objectId" => "d1", "title" => "a",
                           "createdAt" => "2026-01-01T00:00:00.000Z",
                           "updatedAt" => "2026-01-01T00:00:00.000Z" })
    assert doc.persisted?
    doc.title = "changed"
    assert doc.changed?
    assert doc.persisted?, "unsaved changes do not make a saved object new"
  end

  def test_object_with_id_and_no_timestamps_is_persisted
    assert OwnedDoc.new("d2").persisted?
    assert OwnedDoc.new(objectId: "d3").persisted?
  end

  def test_client_assigned_id_during_create_is_not_persisted
    doc = OwnedDoc.new(title: "a")
    seen = nil
    doc.stub(:create, -> {
      doc.instance_variable_set(:@id, "generated")
      seen = doc.persisted?
      false
    }) do
      doc.save
    end
    assert_equal false, seen, "an id assigned mid-create is not yet persisted"
  end
end
