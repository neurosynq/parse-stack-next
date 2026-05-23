require_relative "../../test_helper_integration"
require "securerandom"

# Docker-gated integration test that proves the mongo-direct role-graph
# helpers agree with the existing Parse-Server-backed walk on a real
# three-level role hierarchy with users at each level. This is a
# CORRECTNESS assertion — without it, a direction-inverted $graphLookup
# would silently ship and only surface as an ACL bug under load.
#
# Requires: Docker stack from scripts/docker/docker-compose.test.yml AND
# Parse::MongoDB.configure(uri: ANALYTICS_DATABASE_URI, enabled: true).
class MongoDBRoleGraphIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def setup
    @test_users = []
    @test_roles = []
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Mongo-direct integration tests require ANALYTICS_DATABASE_URI" unless ENV["ANALYTICS_DATABASE_URI"]
    super
    @original_master_key = Parse.client.master_key if Parse::Client.client?
    Parse::MongoDB.configure(
      uri: ENV["ANALYTICS_DATABASE_URI"],
      enabled: true,
      verify_role: false,
    )
  end

  def teardown
    @test_roles.each { |r| r.destroy rescue nil }
    @test_users.each { |u| u.destroy rescue nil }
    Parse::MongoDB.reset! if Parse::MongoDB.respond_to?(:reset!)
    super
  end

  def test_forward_walk_matches_parse_server_path_three_levels
    Parse::Test::ServerHelper.setup
    with_parse_server do
      tag = SecureRandom.hex(3)
      # Admin → Moderator → Editor (parent on the left).
      admin = Parse::Role.find_or_create("RGAdmin_#{tag}")
      moderator = Parse::Role.find_or_create("RGModerator_#{tag}")
      editor = Parse::Role.find_or_create("RGEditor_#{tag}")
      @test_roles += [admin, moderator, editor]

      # Wire inheritance per the SDK semantics: parent.add_child_role(child)
      # places child INTO parent.roles. Users of `child` inherit `parent`'s
      # permissions.
      admin.add_child_role(moderator).save
      moderator.add_child_role(editor).save

      # One user at each level.
      editor_user = signup_test_user(tag, "editor")
      moderator_user = signup_test_user(tag, "mod")
      admin_user = signup_test_user(tag, "admin")
      editor.add_user(editor_user).save
      moderator.add_user(moderator_user).save
      admin.add_user(admin_user).save

      [editor_user, moderator_user, admin_user].each do |user|
        ps_path_result = run_with_mongo_disabled do
          Parse::Role.all_for_user(user, max_depth: 5)
        end
        mongo_path_result = Parse::Role.all_for_user(user, max_depth: 5, master: true)

        assert_kind_of Set, ps_path_result
        assert_kind_of Set, mongo_path_result
        assert_equal ps_path_result, mongo_path_result,
          "mongo-direct forward path must match Parse-Server path for #{user.username}"
      end

      # Editor user should inherit ALL THREE role names (editor + moderator + admin).
      names = Parse::Role.all_for_user(editor_user, max_depth: 5, master: true)
      assert names.include?("RGEditor_#{tag}")
      assert names.include?("RGModerator_#{tag}"),
        "editor must inherit Moderator (parent of Editor)"
      assert names.include?("RGAdmin_#{tag}"),
        "editor must inherit Admin (grandparent of Editor)"
    end
  end

  def test_reverse_walk_returns_all_members_of_subtree
    Parse::Test::ServerHelper.setup
    with_parse_server do
      tag = SecureRandom.hex(3)
      admin = Parse::Role.find_or_create("RGRevAdmin_#{tag}")
      moderator = Parse::Role.find_or_create("RGRevModerator_#{tag}")
      editor = Parse::Role.find_or_create("RGRevEditor_#{tag}")
      @test_roles += [admin, moderator, editor]

      admin.add_child_role(moderator).save
      moderator.add_child_role(editor).save

      editor_user = signup_test_user(tag, "editor")
      moderator_user = signup_test_user(tag, "mod")
      admin_user = signup_test_user(tag, "admin")
      editor.add_user(editor_user).save
      moderator.add_user(moderator_user).save
      admin.add_user(admin_user).save

      ps_path = run_with_mongo_disabled { admin.all_users(max_depth: 5).map(&:id).sort }
      mongo_path = admin.all_users(max_depth: 5, master: true).map(&:id).sort

      assert_equal ps_path, mongo_path,
        "mongo-direct reverse path must agree with Parse-Server path"

      # Admin's subtree should include all three users (admin holds the
      # capabilities, but the practical question is "who carries admin's
      # role:Admin permission" — that's anyone in admin or any descendant).
      assert_includes mongo_path, admin_user.id
      assert_includes mongo_path, moderator_user.id
      assert_includes mongo_path, editor_user.id
    end
  end

  private

  def signup_test_user(tag, label)
    username = "rg_#{label}_#{tag}"
    password = "p_#{SecureRandom.hex(6)}"
    user = Parse::User.signup(username, password)
    @test_users << user
    user
  end

  def run_with_mongo_disabled
    was_enabled = Parse::MongoDB.instance_variable_get(:@enabled)
    Parse::MongoDB.instance_variable_set(:@enabled, false)
    yield
  ensure
    Parse::MongoDB.instance_variable_set(:@enabled, was_enabled)
  end
end
