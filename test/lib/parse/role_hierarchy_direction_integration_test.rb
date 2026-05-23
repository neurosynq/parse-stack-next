require_relative "../../test_helper_integration"
require "securerandom"

# Integration test that proves +Parse::Role#add_child_role+ matches the
# Parse Server _Role inheritance direction the SDK documentation now
# states (corrected as part of NEW-AUTH-1).
#
# Parse Server _Role semantics: when role X holds role Y in its `roles`
# relation, USERS OF Y inherit X's permissions — not the other way
# around. So after +admin.add_child_role(moderator).save+, every user in
# Moderator effectively has Admin's permissions.
#
# This test creates a user belonging ONLY to the Moderator role, saves
# +admin.add_child_role(moderator)+, then logs that user in and reads a
# doc whose ACL grants read to the Admin role exclusively. The read
# must succeed — that is the proof that the documented direction
# matches the server's actual role-expansion behavior.
class RoleHierarchyDirectionIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  class HierTestDoc < Parse::Object
    parse_class "HierTestDoc"
    property :title, :string
  end

  def setup
    @test_users = []
    @test_roles = []
    @test_docs = []
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  def teardown
    @test_docs.each { |d| d.destroy rescue nil }
    @test_roles.each { |r| r.destroy rescue nil }
    @test_users.each { |u| u.destroy rescue nil }
    super
  end

  def test_add_child_role_grants_child_role_users_the_parent_roles_permissions
    Parse::Test::ServerHelper.setup
    with_parse_server do
      # Unique role names so reruns don't collide on the _Role uniqueness
      # constraint (Parse::Role.name).
      tag = SecureRandom.hex(3)
      admin = Parse::Role.find_or_create("Admin_#{tag}")
      moderator = Parse::Role.find_or_create("Moderator_#{tag}")
      @test_roles += [admin, moderator]

      # Create a user who belongs ONLY to Moderator (not Admin).
      username = "modonly_#{tag}"
      password = "p_#{SecureRandom.hex(6)}"
      mod_user = Parse::User.signup(username, password)
      @test_users << mod_user
      moderator.add_user(mod_user).save
      refute admin.has_user?(mod_user), "precondition: user must not be a direct Admin"

      # Wire the hierarchy as the SDK documents it. Per Parse Server
      # semantics this places moderator INTO admin.roles, which means
      # users of Moderator now inherit Admin's permissions.
      admin.add_child_role(moderator)
      assert admin.save, "save admin.add_child_role(moderator)"

      # Doc readable ONLY by the Admin role.
      doc = HierTestDoc.new(title: "AdminOnly_#{tag}")
      doc.acl = Parse::ACL.new
      doc.acl.apply_role(admin.name, read: true, write: false)
      doc.acl.apply(:public, read: false, write: false)
      assert doc.save, "save admin-only doc"
      @test_docs << doc

      # Log the moderator-only user in to obtain a session-scoped client
      # context. The read must use that session — NOT the master key —
      # for the test to actually exercise Parse Server's role expansion.
      logged_in = Parse::User.login(username, password)
      assert logged_in, "moderator-only user must be able to log in"
      assert logged_in.session_token.present?, "session token expected"

      # Fetch the doc with the session-scoped user. This call carries
      # the session token in its headers (no master key), so the server
      # will deny it unless its _Role expansion concludes that the
      # session user effectively has the Admin role.
      response = Parse::User.client.fetch_object(
        HierTestDoc.parse_class, doc.id,
        session_token: logged_in.session_token
      )
      assert response.success?,
             "Moderator-only user must be able to read an Admin-ACL doc " \
             "after admin.add_child_role(moderator). This is the documented " \
             "Parse Server _Role direction (users of child inherit parent's " \
             "permissions). If this assertion fails the SDK documentation " \
             "is reversed relative to the server. Server error: #{response.error.inspect}"
      assert_equal doc.id, response.result["objectId"]
    end
  end
end
