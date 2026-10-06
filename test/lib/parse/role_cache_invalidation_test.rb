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
end
