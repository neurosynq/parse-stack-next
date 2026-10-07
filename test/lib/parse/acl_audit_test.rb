require_relative "../../test_helper"

# Regression tests for ACL dirty-tracking and key-resolution defects:
# rollback! restoring in-place ACL edits, delete() of role and public
# entries, Permission-level mutators notifying the owning object,
# apply_role with a prefixed name, string "false" flags, and eql?/hash.
class ACLAuditPost < Parse::Object
  parse_class "ACLAuditPost"
  property :title, :string
end

class ACLAuditPublicRead < Parse::Object
  parse_class "ACLAuditPublicRead"
  property :t, :string
  acl_policy :public_read
end

class ACLAuditTest < Minitest::Test
  PUBLIC_AND_OWNER = { "*" => { "read" => true }, "u1" => { "read" => true, "write" => true } }.freeze

  def fetched(acl = PUBLIC_AND_OWNER)
    ACLAuditPost.build({
      "objectId" => "P1",
      "createdAt" => "2026-01-01T00:00:00.000Z",
      "updatedAt" => "2026-01-01T00:00:00.000Z",
      "title" => "t",
      "ACL" => acl,
    })
  end

  def sent_acl(obj)
    obj.changes_payload["ACL"]&.as_json
  end

  # --- rollback! and the ACL change history ---

  def test_dup_does_not_share_permissions
    a = Parse::ACL.new(PUBLIC_AND_OWNER)
    b = a.dup
    b.apply("u2", true, true)
    b.permissions["u1"].no_write!
    assert_equal PUBLIC_AND_OWNER, a.as_json
    refute a.permissions["u1"].equal?(b.permissions["u1"])
  end

  def test_rollback_undoes_in_place_grant
    o = fetched
    o.acl.apply("attacker", true, true)
    o.rollback!
    assert_equal PUBLIC_AND_OWNER, o.acl.as_json
    refute o.changed?

    # The rolled-back grant must not ride along with a later save.
    o.title = "new"
    assert_nil sent_acl(o)
  end

  def test_rollback_undoes_delete_and_permission_edit
    o = fetched
    o.acl.delete("u1")
    o.rollback!
    assert_equal PUBLIC_AND_OWNER, o.acl.as_json

    o = fetched
    o.acl.permissions["u1"].no_write!
    o.rollback!
    assert_equal PUBLIC_AND_OWNER, o.acl.as_json
  end

  def test_change_history_records_distinct_old_and_new
    o = fetched
    o.acl.delete("u1")
    old_acl, new_acl = o.changes["acl"]
    assert_equal PUBLIC_AND_OWNER, old_acl.as_json
    assert_equal({ "*" => { "read" => true } }, new_acl.as_json)
  end

  # --- delete() key resolution ---

  def test_delete_public_symbol
    o = fetched
    o.acl.delete(:public)
    assert o.changed?
    assert_equal({ "u1" => { "read" => true, "write" => true } }, sent_acl(o))
  end

  def test_delete_role_object_and_role_name
    acl = { "role:Admin" => { "read" => true }, "u1" => { "read" => true } }

    o = fetched(acl)
    o.acl.delete(Parse::Role.build({ "objectId" => "R1", "name" => "Admin" }))
    assert_equal({ "u1" => { "read" => true } }, sent_acl(o))

    o = fetched(acl)
    o.acl.delete("Admin")
    assert_equal({ "u1" => { "read" => true } }, sent_acl(o))

    o = fetched(acl)
    o.acl.delete("role:Admin")
    assert_equal({ "u1" => { "read" => true } }, sent_acl(o))
  end

  def test_delete_user_forms_still_work
    o = fetched
    o.acl.delete(Parse::User.pointer("u1"))
    assert_equal({ "*" => { "read" => true } }, sent_acl(o))
  end

  def test_delete_missing_key_is_not_a_change
    o = fetched
    assert_nil o.acl.delete("nobody")
    refute o.changed?
  end

  # --- Permission-level mutators notify the owning object ---

  def test_permission_mutators_mark_fetched_object_dirty
    %i[no_read! read_false].each do |op|
      o = fetched
      perm = o.acl.permissions["*"]
      op == :no_read! ? perm.no_read! : perm.read!(false)
      assert o.changed?, "#{op} should mark the object dirty"
      assert_equal({ "u1" => { "read" => true, "write" => true } }, sent_acl(o))
    end

    o = fetched
    o.acl.permissions["u1"].no_write!
    assert_equal({ "*" => { "read" => true }, "u1" => { "read" => true } }, sent_acl(o))

    o = fetched
    o.acl.permissions["*"].write!
    assert_equal({ "*" => { "read" => true, "write" => true }, "u1" => { "read" => true, "write" => true } }, sent_acl(o))
  end

  def test_permission_noop_mutation_is_not_a_change
    o = fetched
    o.acl.permissions["*"].read!(true)
    refute o.changed?
  end

  def test_permission_revoke_on_new_object_is_kept
    n = ACLAuditPublicRead.new(t: "x")
    n.acl.permissions["*"].no_read!
    # The save-time policy resolver must treat the revoke as caller intent
    # and leave it alone instead of re-stamping public read.
    n.send(:_resolve_default_acl)
    assert_equal({}, n.acl.as_json)
  end

  def test_shared_permission_is_copied_not_shared
    perm = Parse::ACL.permission(true, false)
    a = Parse::ACL.new
    b = Parse::ACL.new
    a.apply("u1", perm)
    b.apply("u1", perm)
    b.permissions["u1"].no_read!
    assert_equal({ "u1" => { "read" => true } }, a.as_json)
    assert_equal({}, b.as_json)
  end

  # --- apply_role with an already-prefixed key ---

  def test_apply_role_accepts_prefixed_name
    acl = Parse::ACL.new
    acl.apply_role("role:Admin", true, true)
    acl.apply_role("Mods", true, false)
    assert_equal({ "role:Admin" => { "read" => true, "write" => true }, "role:Mods" => { "read" => true } }, acl.as_json)
  end

  # --- string flags ---

  def test_string_false_is_a_denial
    acl = Parse::ACL.new({ "u1" => { "read" => "false", "write" => true }, "u2" => { "read" => "true" } })
    assert_equal({ "u1" => { "write" => true }, "u2" => { "read" => true } }, acl.as_json)
    refute Parse::ACL::Permission.new("false", "0").present?
    assert_equal false, Parse::ACL::Permission.new(true).tap { |p| p.read!("false") }.read
  end

  # --- eql? / hash ---

  def test_eql_and_hash_agree_with_equality
    a = Parse::ACL.new({ "*" => { "read" => true } })
    b = Parse::ACL.new({ "*" => { "read" => true } })
    assert_equal a, b
    assert a.eql?(b)
    assert_equal a.hash, b.hash
    assert_equal 1, [a, b].uniq.size
    assert_equal :x, { a => :x }[b]
    # == still accepts a Hash, but eql? does not, since their hashes differ.
    assert a == { "*" => { "read" => true } }
    refute a.eql?({ "*" => { "read" => true } })
    refute a.eql?(Parse::ACL.new({ "*" => { "write" => true } }))

    p1 = Parse::ACL.permission(true, false)
    p2 = Parse::ACL.permission(true, false)
    assert p1.eql?(p2)
    assert_equal p1.hash, p2.hash
  end
end
