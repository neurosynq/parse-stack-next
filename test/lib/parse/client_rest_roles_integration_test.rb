require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# Role-based ACL enforcement, observed from the SDK-as-client side. The
# theme is "role membership grants/denies access at row level" — the SDK
# must thread the user's session token through, and Parse Server must
# expand the role graph server-side.
#
# Two role shapes are exercised:
#   1. Flat role: user is a direct member of Admin; rows ACL'd to
#      `role:Admin` are readable/writable by that user.
#   2. Hierarchical role: SuperAdmin contains Admin as a child role.
#      SuperAdmin members inherit access to rows ACL'd to `role:Admin`.
#
# Per Parse Server, "child" roles are roles that have THIS role in their
# `roles` relation — i.e. the parent grants its own access to anyone in
# the child's expansion graph. The SDK's `add_child_role` writes that
# relation; `getAllRolesForUser` (server-side) expands transitively when
# evaluating ACL.
class ClientRoleDoc < Parse::Object
  parse_class "ClientRoleDoc"
  # `:private` policy stamps `{}` on save (master-only). Tests
  # override the ACL explicitly with role grants so we observe role
  # enforcement, not policy fallback.
  acl_policy :private
  property :title, :string
  property :body, :string
end

class ClientRestRolesIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @admin_user,    @admin_password    = seed_client_user("role_admin")
    @member_user,   @member_password   = seed_client_user("role_member")
    @outsider_user, @outsider_password = seed_client_user("role_outsider")

    # Roles are created under master key (CLP on _Role is master-only
    # by default in Parse Server, regardless of role suffixes).
    with_master_key do
      @admin_role  = Parse::Role.find_or_create(role_name("Admin"))
      @admin_role.add_users(@admin_user).save
      @member_role = Parse::Role.find_or_create(role_name("Member"))
      @member_role.add_users(@member_user).save
    end
  end

  # Unique role names per test run so concurrent runs / partial cleanup
  # don't collide with stale Parse::Role rows.
  def role_name(base)
    @role_suffix ||= SecureRandom.hex(3)
    "#{base}_#{@role_suffix}"
  end

  # --------------------------------------------------------------------
  # Admin role member can READ a row ACL'd to `role:Admin`; an outsider
  # who is in NO role cannot.
  # --------------------------------------------------------------------
  def test_admin_role_member_can_read_role_acl_row
    doc = nil
    with_master_key do
      doc = ClientRoleDoc.new(title: "admin-only", body: "x")
      doc.acl.apply_role(@admin_role.name, true, true)
      assert doc.save
      @test_context.track(doc)
    end

    as_client do
      admin = Parse::User.login(@admin_user.username, @admin_password)
      seen = ClientRoleDoc.query.tap { |q| q.session_token = admin.session_token }
                          .where(objectId: doc.id).first
      refute_nil seen, "Admin role member must see role:Admin-ACL'd row"
      assert_equal "admin-only", seen.title

      outsider = Parse::User.login(@outsider_user.username, @outsider_password)
      blocked = ClientRoleDoc.query.tap { |q| q.session_token = outsider.session_token }
                             .where(objectId: doc.id).first
      assert_nil blocked, "user in no role must NOT see role:Admin-ACL'd row"
    end
  end

  # --------------------------------------------------------------------
  # Admin role member can WRITE to a row that grants write only to
  # `role:Admin`. A Member-role user (read granted) cannot.
  # --------------------------------------------------------------------
  def test_role_acl_blocks_write_from_wrong_role
    doc = nil
    with_master_key do
      doc = ClientRoleDoc.new(title: "v1", body: "rw=admin,r=member")
      # Read for member, read+write for admin. Public denied.
      doc.acl.everyone(false, false)
      doc.acl.apply_role(@member_role.name, true, false)
      doc.acl.apply_role(@admin_role.name, true, true)
      assert doc.save
      @test_context.track(doc)
    end

    as_client do
      member = Parse::User.login(@member_user.username, @member_password)
      seen_by_member = ClientRoleDoc.query.tap { |q| q.session_token = member.session_token }
                                    .where(objectId: doc.id).first
      refute_nil seen_by_member, "Member role grants read"

      # Member tries to write — must be rejected.
      seen_by_member.title = "tampered-by-member"
      err = assert_raises(Parse::Error, Parse::RecordNotSaved, StandardError) do
        seen_by_member.save!(session: member.session_token)
      end
      assert_match(/permission|forbidden|acl|not allowed|not saved|object not found/i, err.message,
                   "Member-role-only-read user must not be able to write, got: #{err.message}")

      # Admin can write.
      admin = Parse::User.login(@admin_user.username, @admin_password)
      seen_by_admin = ClientRoleDoc.query.tap { |q| q.session_token = admin.session_token }
                                   .where(objectId: doc.id).first
      seen_by_admin.title = "v2-by-admin"
      assert seen_by_admin.save(session: admin.session_token),
             "Admin role grants write — save must succeed"

      with_master_key do
        unchanged = ClientRoleDoc.find(doc.id)
        assert_equal "v2-by-admin", unchanged.title,
                     "row title must reflect admin's authorized write, not member's blocked one"
      end
    end
  end

  # --------------------------------------------------------------------
  # Role hierarchy: SuperAdmin contains Admin as a child role. The
  # SuperAdmin member should INHERIT Admin's access to a `role:Admin`
  # row via Parse Server's role-graph expansion. A plain Member must
  # still not see it.
  # --------------------------------------------------------------------
  def test_role_hierarchy_grants_parent_access_to_child_role_rows
    super_user, super_password = seed_client_user("role_super")
    super_role = nil
    with_master_key do
      super_role = Parse::Role.find_or_create(role_name("SuperAdmin"))
      super_role.add_users(super_user).save
      # Inheritance direction: SuperAdmin users want to inherit Admin's
      # capabilities. Per Parse Server semantics, that requires putting
      # SuperAdmin into Admin's `roles` relation — NOT the reverse. Use
      # the direction-explicit method to avoid the documented gotcha
      # in `add_child_role`.
      super_role.inherits_capabilities_from!(@admin_role)
    end

    doc = nil
    with_master_key do
      doc = ClientRoleDoc.new(title: "for-admins", body: "y")
      doc.acl.apply_role(@admin_role.name, true, true)
      assert doc.save
      @test_context.track(doc)
    end

    as_client do
      su = Parse::User.login(super_user.username, super_password)
      seen = ClientRoleDoc.query.tap { |q| q.session_token = su.session_token }
                          .where(objectId: doc.id).first
      refute_nil seen, "SuperAdmin (parent of Admin) must inherit Admin's ACL access"

      member = Parse::User.login(@member_user.username, @member_password)
      blocked = ClientRoleDoc.query.tap { |q| q.session_token = member.session_token }
                             .where(objectId: doc.id).first
      assert_nil blocked, "Member (no admin lineage) must NOT see role:Admin row"
    end
  end

  # --------------------------------------------------------------------
  # Self-modification of a _Role row from a client (non-master) is
  # rejected by Parse Server's default _Role CLP. The SDK must NOT
  # silently strip the write — it must surface the error so callers
  # don't think a role change took effect when it didn't.
  # --------------------------------------------------------------------
  def test_client_cannot_mutate_role_without_master_key
    as_client do
      admin = Parse::User.login(@admin_user.username, @admin_password)
      response = Parse.client.update_object(
        "_Role", @admin_role.id,
        { "name" => "hijacked_#{SecureRandom.hex(2)}" },
        session_token: admin.session_token, use_master_key: false,
      )
      refute response.success?,
             "non-master role mutation must fail; Parse Server defaults _Role to master-only writes"
      assert_match(/permission|forbidden|master|not allowed|object not found|acl/i,
                   response.error.to_s,
                   "expected an auth-class rejection, got: #{response.error.inspect}")
    end
  end
end
