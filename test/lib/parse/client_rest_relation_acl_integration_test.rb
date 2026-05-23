require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# End-to-end coverage for +AddRelation+ / +RemoveRelation+ ops on a
# +has_many :through => :relation+ association under client mode.
# Parse Server's relation update path is a regular PUT against the
# parent row carrying an +__op: AddRelation+ / +RemoveRelation+ body,
# so the relation-mutate authorization gate IS the parent row's ACL.
# Tests pin:
#
#   1. The owning user (write-permitted by the parent row's ACL) can
#      add and remove relation entries under session-token auth.
#   2. A non-owner user (write-denied by the parent row's ACL) cannot
#      mutate the relation — the SDK surfaces the rejection rather than
#      silently smuggling a master key.
class RelAclProject < Parse::Object
  parse_class "RelAclProject"
  # We need row-level ACL enforcement here, so don't use :public. We
  # explicitly stamp ACL at save time below.
  property :title, :string
  has_many :collaborators, as: "RelAclMember", through: :relation
end

class RelAclMember < Parse::Object
  parse_class "RelAclMember"
  acl_policy :public
  property :name, :string
end

class ClientRestRelationAclIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  # --------------------------------------------------------------------
  # Happy path: owning user can mutate the relation.
  # --------------------------------------------------------------------
  def test_owner_can_add_and_remove_relation_under_session_token
    owner, owner_pwd = seed_client_user("rel_owner")

    project = nil
    member1 = nil
    member2 = nil
    with_master_key do
      acl = Parse::ACL.new
      acl.apply(owner.id, true, true) # owner read + write
      project = RelAclProject.new(title: "p1", ACL: acl)
      assert project.save
      @test_context.track(project)

      member1 = RelAclMember.new(name: "m1"); assert member1.save; @test_context.track(member1)
      member2 = RelAclMember.new(name: "m2"); assert member2.save; @test_context.track(member2)
    end

    as_client do
      me = Parse::User.login!(owner.username, owner_pwd)

      Parse.with_session(me.session_token) do
        # Refetch under session to pick up the ACL state.
        owned = RelAclProject.find(project.id)
        owned.collaborators.add member1, member2
        assert owned.save, "owner must be able to commit AddRelation under session auth"
      end
    end

    # Master-key verification: the relation entries actually landed.
    with_master_key do
      reloaded = RelAclProject.find(project.id)
      count = reloaded.collaborators.count
      assert_equal 2, count, "two collaborators must be persisted (got #{count})"
    end

    # Removal under same session.
    as_client do
      me = Parse::User.login!(owner.username, owner_pwd)
      Parse.with_session(me.session_token) do
        owned = RelAclProject.find(project.id)
        owned.collaborators.remove member1
        assert owned.save, "owner must be able to commit RemoveRelation under session auth"
      end
    end

    with_master_key do
      reloaded = RelAclProject.find(project.id)
      assert_equal 1, reloaded.collaborators.count
    end
  end

  # --------------------------------------------------------------------
  # Authorization boundary: a different user cannot mutate the relation
  # on an owner-private row. The SDK must surface the rejection.
  # --------------------------------------------------------------------
  def test_non_owner_cannot_mutate_relation_under_session_token
    owner, _owner_pwd = seed_client_user("rel_owner2")
    intruder, intruder_pwd = seed_client_user("rel_intruder")

    project = nil
    member = nil
    with_master_key do
      acl = Parse::ACL.new
      acl.apply(owner.id, true, true) # ONLY owner read+write
      project = RelAclProject.new(title: "p2", ACL: acl)
      assert project.save
      @test_context.track(project)

      member = RelAclMember.new(name: "outside"); assert member.save; @test_context.track(member)
    end

    # Drop down to raw PUT to dodge the autofetch on relation accessors
    # — the intruder can't read the row, so accessing collaborators on a
    # Pointer-shaped proxy would 404 on the autofetch BEFORE we get to
    # exercise the AddRelation auth gate. We want to pin the AddRelation
    # rejection itself.
    response = nil
    as_client do
      me = Parse::User.login!(intruder.username, intruder_pwd)

      Parse.with_session(me.session_token) do
        body = {
          collaborators: {
            "__op" => "AddRelation",
            "objects" => [member.pointer.as_json],
          },
        }
        response = Parse.client.update_object(
          "RelAclProject", project.id, body,
          session_token: me.session_token,
        )
      end
    end

    refute response.success?,
           "non-owner AddRelation must NOT silently succeed (got: #{response.inspect})"

    # Server-side ground truth: the relation must still be empty.
    with_master_key do
      reloaded = RelAclProject.find(project.id)
      assert_equal 0, reloaded.collaborators.count,
                   "no relation entries should have landed from the intruder's attempt"
    end
  end
end
