# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Saving a role drops cached role closures for the users whose membership
# changed, and all closures when the role hierarchy changed, so grants and
# revocations reach mongo-direct ACL resolution without waiting for the
# role-cache TTL.
class RoleCacheInvalidationTest < Minitest::Test
  class FakeAuth
    attr_reader :users, :all

    def initialize
      @users = []
      @all = 0
    end

    def invalidate_user_roles(id) = @users << id
    def invalidate_all_roles = @all += 1
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1/parse", application_id: "a", api_key: "k")
    end
  end

  def run_callbacks_for(role, auth)
    role.client.stub(:authorization, auth) do
      role.send(:_capture_role_membership_changes)
      role.send(:_invalidate_role_caches)
    end
  end

  def test_membership_change_invalidates_those_users
    role = Parse::Role.build({ "objectId" => "r1", "name" => "Editor",
                               "createdAt" => "2026-01-01T00:00:00.000Z",
                               "updatedAt" => "2026-01-01T00:00:00.000Z" }, "_Role")
    role.users.add(Parse::User.new(objectId: "u1"))
    role.users.remove(Parse::User.new(objectId: "u2"))
    auth = FakeAuth.new
    run_callbacks_for(role, auth)
    assert_equal %w[u1 u2], auth.users.sort
    assert_equal 0, auth.all
  end

  def test_hierarchy_change_invalidates_all_closures
    role = Parse::Role.new(name: "Editor")
    role.roles.add(Parse::Role.new(objectId: "r2", name: "Viewer"))
    auth = FakeAuth.new
    run_callbacks_for(role, auth)
    assert_equal 1, auth.all
  end

  def test_unchanged_role_invalidates_nothing
    role = Parse::Role.new(name: "Editor")
    auth = FakeAuth.new
    run_callbacks_for(role, auth)
    assert_empty auth.users
    assert_equal 0, auth.all
  end

  # Atomic relation operations write without a save, so they invalidate too.
  def test_atomic_relation_ops_invalidate
    role = Parse::Role.build({ "objectId" => "r1", "name" => "Editor",
                               "createdAt" => "2026-01-01T00:00:00.000Z",
                               "updatedAt" => "2026-01-01T00:00:00.000Z" }, "_Role")
    auth = FakeAuth.new
    ok = Parse::Response.new({ "updatedAt" => "2026-01-02T00:00:00.000Z" })
    role.client.stub(:authorization, auth) do
      role.client.stub(:update_object, ->(*_a, **_k) { ok }) do
        assert role.op_remove_relation!(:users, [Parse::User.new(objectId: "u9")])
        assert role.op_add_relation!(:roles, [Parse::Role.new(objectId: "r2", name: "V")])
      end
    end
    assert_equal ["u9"], auth.users
    assert_equal 1, auth.all
  end

  # Saving the relation proxy on its own goes through the atomic relation
  # operations, so it invalidates too.
  def test_relation_proxy_save_invalidates
    role = Parse::Role.build({ "objectId" => "r1", "name" => "Editor",
                               "createdAt" => "2026-01-01T00:00:00.000Z",
                               "updatedAt" => "2026-01-01T00:00:00.000Z" }, "_Role")
    role.define_singleton_method(:users_fetch!) { [] }
    role.define_singleton_method(:roles_fetch!) { [] }
    auth = FakeAuth.new
    ok = Parse::Response.new({ "updatedAt" => "2026-01-02T00:00:00.000Z" })
    role.client.stub(:authorization, auth) do
      role.client.stub(:update_object, ->(*_a, **_k) { ok }) do
        role.users.add(Parse::User.new(objectId: "u4"))
        assert role.users.save
        role.roles.add(Parse::Role.new(objectId: "r2", name: "V"))
        assert role.roles.save
      end
    end
    assert_equal ["u4"], auth.users
    assert_equal 1, auth.all
  end

end
