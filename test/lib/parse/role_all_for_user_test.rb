# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for Parse::Role.all_for_user — the upward role-inheritance
# traversal that backs the :ACL.readable_by / :ACL.writable_by query
# constraints (after the constraint-bug fix) and the Atlas Search ACL
# $match injection.
#
# Parse Server _Role inheritance: when role X holds role Y in its
# `roles` relation, users of Y inherit X's permissions. So given a
# user U, the permission set is the upward closure starting from U's
# direct roles.
#
# The traversal is implemented as:
#   1. Parse::Role.all(users: user_pointer) — direct memberships
#   2. BFS via Parse::Role.all(roles: <each_visited_role>) — parents
#
# These tests stub Parse::Role.all to control the role graph without
# a live Parse Server.
class RoleAllForUserTest < Minitest::Test
  # OpenStruct-based mock Role. Carries id and name so cycle
  # detection and result accumulation work. Mocks `users` and
  # `roles` relations are not exercised by the upward walk; we only
  # need id+name.
  Role = Struct.new(:id, :name)

  def setup
    @user_pointer = Parse::Pointer.new("_User", "U1")
  end

  def teardown
    # Restore Parse::Role.all to its original behavior. The stubs in
    # each test patch the singleton method; restore the class so
    # later tests are unaffected.
    if Parse::Role.singleton_class.method_defined?(:__original_all)
      Parse::Role.singleton_class.send(:alias_method, :all, :__original_all)
      Parse::Role.singleton_class.send(:remove_method, :__original_all)
    end
  end

  # Patch Parse::Role.all to dispatch on the kwargs the helper
  # passes — `users:` for the direct-roles step, `roles:` for the
  # upward BFS. Other kwargs return nil.
  def stub_role_graph(direct_for_user:, parents_for: {})
    parents_lookup = Hash.new { |_, _| [] }
    parents_for.each { |role, parents| parents_lookup[role.id] = parents }

    unless Parse::Role.singleton_class.method_defined?(:__original_all)
      Parse::Role.singleton_class.send(:alias_method, :__original_all, :all)
    end

    Parse::Role.define_singleton_method(:all) do |**kwargs|
      if kwargs.key?(:users)
        direct_for_user
      elsif kwargs.key?(:roles)
        role = kwargs[:roles]
        rid = role.respond_to?(:id) ? role.id : nil
        parents_lookup[rid] || []
      else
        []
      end
    end
  end

  def test_nil_user_returns_empty_set
    assert_equal Set.new, Parse::Role.all_for_user(nil)
  end

  def test_empty_string_user_returns_empty_set
    assert_equal Set.new, Parse::Role.all_for_user("")
  end

  def test_user_with_no_roles_returns_empty_set
    stub_role_graph(direct_for_user: [])
    assert_equal Set.new, Parse::Role.all_for_user(@user_pointer)
  end

  def test_direct_membership_only
    member = Role.new("R1", "Member")
    stub_role_graph(direct_for_user: [member])
    names = Parse::Role.all_for_user(@user_pointer)
    assert_equal Set["Member"], names
  end

  def test_single_parent_role_via_upward_walk
    member = Role.new("R1", "Member")
    admin  = Role.new("R2", "Admin")
    # Admin.roles contains Member -> Member's users inherit Admin's
    # permissions, i.e. Admin is a PARENT in the upward walk.
    stub_role_graph(direct_for_user: [member], parents_for: { member => [admin] })

    names = Parse::Role.all_for_user(@user_pointer)
    assert_equal Set["Member", "Admin"], names
  end

  def test_chain_walks_all_the_way_up
    a = Role.new("R1", "A") # direct
    b = Role.new("R2", "B") # parent of A
    c = Role.new("R3", "C") # parent of B
    stub_role_graph(
      direct_for_user: [a],
      parents_for: { a => [b], b => [c] },
    )
    names = Parse::Role.all_for_user(@user_pointer)
    assert_equal Set["A", "B", "C"], names
  end

  def test_diamond_does_not_revisit
    a = Role.new("R1", "A")
    b = Role.new("R2", "B")
    c = Role.new("R3", "C")
    d = Role.new("R4", "D") # diamond apex — parent of both B and C
    stub_role_graph(
      direct_for_user: [a],
      parents_for: { a => [b, c], b => [d], c => [d] },
    )
    names = Parse::Role.all_for_user(@user_pointer)
    assert_equal Set["A", "B", "C", "D"], names
  end

  def test_cycle_does_not_loop
    a = Role.new("R1", "A")
    b = Role.new("R2", "B")
    # A → B → A cycle
    stub_role_graph(
      direct_for_user: [a],
      parents_for: { a => [b], b => [a] },
    )
    names = Parse::Role.all_for_user(@user_pointer)
    assert_equal Set["A", "B"], names
  end

  def test_max_depth_cutoff
    chain = (1..5).map { |i| Role.new("R#{i}", "L#{i}") }
    parents_for = {}
    chain.each_cons(2) { |child, parent| parents_for[child] = [parent] }

    stub_role_graph(direct_for_user: [chain.first], parents_for: parents_for)
    names = Parse::Role.all_for_user(@user_pointer, max_depth: 2)
    # Direct + 2 upward steps: L1 (direct), L2, L3. L4 and L5 are
    # beyond the budget.
    assert_includes names, "L1"
    assert_includes names, "L2"
    assert_includes names, "L3"
    refute_includes names, "L5"
  end

  def test_lookup_failure_returns_empty_set
    Parse::Role.define_singleton_method(:all) do |**_|
      raise StandardError, "simulated Parse Server outage"
    end
    assert_equal Set.new, Parse::Role.all_for_user(@user_pointer)
  end

  def test_string_user_id_is_coerced_to_pointer
    member = Role.new("R1", "Member")
    # Box the captured kwargs so the closure assignment lands in the
    # outer binding (a bare `seen = ...` inside the block would shadow
    # to a local).
    captured = []
    Parse::Role.define_singleton_method(:all) do |**kwargs|
      captured << kwargs
      kwargs.key?(:users) ? [member] : []
    end
    Parse::Role.all_for_user("U1")
    direct_call = captured.find { |k| k.key?(:users) }
    refute_nil direct_call, "string objectId should be coerced to _User pointer"
    pointer = direct_call[:users]
    assert_equal "U1", pointer.id
    assert_equal Parse::Model::CLASS_USER, pointer.parse_class
  end

  def test_pointer_on_non_user_class_returns_empty
    not_a_user = Parse::Pointer.new("_Role", "R1")
    Parse::Role.define_singleton_method(:all) { |**_| raise "should not be called" }
    assert_equal Set.new, Parse::Role.all_for_user(not_a_user)
  end
end

# Companion tests for Parse::Role#all_parent_role_names — the
# instance-side analogue used by the ACL constraints' Role-input
# path (`:ACL.readable_by => admin_role`).
class RoleAllParentRoleNamesTest < Minitest::Test
  Role = RoleAllForUserTest::Role

  def teardown
    if Parse::Role.singleton_class.method_defined?(:__original_all)
      Parse::Role.singleton_class.send(:alias_method, :all, :__original_all)
      Parse::Role.singleton_class.send(:remove_method, :__original_all)
    end
  end

  def stub_parents(parents_for)
    unless Parse::Role.singleton_class.method_defined?(:__original_all)
      Parse::Role.singleton_class.send(:alias_method, :__original_all, :all)
    end
    Parse::Role.define_singleton_method(:all) do |**kwargs|
      if kwargs.key?(:roles)
        role = kwargs[:roles]
        rid = role.respond_to?(:id) ? role.id : nil
        parents_for[rid] || []
      else
        []
      end
    end
  end

  def test_includes_self_and_parents
    # Build a real Parse::Role instance so the method dispatches.
    role = Parse::Role.new(name: "Admin")
    role.id = "R1"

    moderator = Role.new("R2", "Moderator")
    stub_parents("R1" => [moderator])

    names = role.all_parent_role_names
    assert_includes names, "Admin"
    assert_includes names, "Moderator"
  end

  def test_nil_id_returns_empty_set
    role = Parse::Role.new(name: "DangerousButUnsaved")
    assert_equal Set.new, role.all_parent_role_names
  end
end

# Tests for the fast-path opt-in contract introduced as part of the
# MONGO-1/2/3 fix series.
#
# - TRACK-MONGO-1: `Parse::Role.all_for_user` only triggers the
#   mongo-direct fast path when `master:` or `as:` is supplied. The
#   bare backward-compat call (used from acl_scope, atlas_search
#   Session, query/constraints, agent default-scope) skips the fast
#   path and falls through to the Parse-Server walk.
# - TRACK-MONGO-2: `Parse::User#acl_roles` defaults `as:` to self
#   so the CLP gate on _Role applies; with default _Role CLP
#   (master-only), the call raises CLPScope::Denied.
# - TRACK-MONGO-3: `Parse::Role#all_users` accepts `as:` and routes
#   the User-hydration follow-up through Parse::MongoDB.aggregate so
#   _User ACL fires (instead of the master-keyed Parse::User.all).
# - TRACK-MONGO-8: fast-path ConnectionFailure swallows emit
#   `parse.role.fast_path_unavailable` instrumentation.
class RoleFastPathAuthorizationTest < Minitest::Test
  VALID_ID = "AHYeeptUZU"

  def setup
    @user_pointer = Parse::Pointer.new(Parse::Model::CLASS_USER, "U1")
    Parse::CLPScope.reset_cache!
  end

  def teardown
    Parse::CLPScope.reset_cache!
    if Parse::Role.singleton_class.method_defined?(:__original_all)
      Parse::Role.singleton_class.send(:alias_method, :all, :__original_all)
      Parse::Role.singleton_class.send(:remove_method, :__original_all)
    end
    if Parse::MongoDB.singleton_class.method_defined?(:__original_role_names_for_user)
      Parse::MongoDB.singleton_class.send(
        :alias_method, :role_names_for_user, :__original_role_names_for_user,
      )
      Parse::MongoDB.singleton_class.send(
        :remove_method, :__original_role_names_for_user,
      )
    end
    if Parse::MongoDB.singleton_class.method_defined?(:__original_users_in_role_subtree)
      Parse::MongoDB.singleton_class.send(
        :alias_method, :users_in_role_subtree, :__original_users_in_role_subtree,
      )
      Parse::MongoDB.singleton_class.send(
        :remove_method, :__original_users_in_role_subtree,
      )
    end
  end

  # --------------------------------------------------------------
  # MONGO-1: backward-compat / fast-path opt-in
  # --------------------------------------------------------------

  def test_all_for_user_without_master_or_as_does_not_invoke_mongo_fast_path
    fast_path_called = false
    intercept_mongo_role_names_for_user! do |_id, **_kwargs|
      fast_path_called = true
      Set.new
    end
    # The slow path queries Parse::Role.all(users: ptr); stub it to
    # return empty so we don't hit the network.
    unless Parse::Role.singleton_class.method_defined?(:__original_all)
      Parse::Role.singleton_class.send(:alias_method, :__original_all, :all)
    end
    Parse::Role.define_singleton_method(:all) { |**_| [] }

    Parse::Role.all_for_user(@user_pointer)
    refute fast_path_called,
      "fast path must NOT run when neither master: nor as: is supplied"
  end

  def test_all_for_user_with_master_invokes_mongo_fast_path
    captured = {}
    intercept_mongo_role_names_for_user! do |id, **kwargs|
      captured[:id] = id
      captured[:master] = kwargs[:master]
      captured[:as] = kwargs[:as]
      Set.new(["Admin"])
    end

    result = Parse::Role.all_for_user(@user_pointer, master: true)
    assert_equal Set["Admin"], result
    assert_equal "U1", captured[:id]
    assert_equal true, captured[:master]
    assert_nil captured[:as]
  end

  def test_all_for_user_with_as_invokes_mongo_fast_path_with_scope
    captured = {}
    intercept_mongo_role_names_for_user! do |id, **kwargs|
      captured[:id] = id
      captured[:master] = kwargs[:master]
      captured[:as] = kwargs[:as]
      Set.new(["Member"])
    end

    scope_user = Parse::User.new
    scope_user.id = "OPERATOR"
    result = Parse::Role.all_for_user(@user_pointer, as: scope_user)
    assert_equal Set["Member"], result
    assert_equal "U1", captured[:id]
    assert_equal false, captured[:master]
    assert_equal scope_user, captured[:as]
  end

  # --------------------------------------------------------------
  # MONGO-8: ConnectionFailure → notification
  # --------------------------------------------------------------

  def test_all_for_user_mongo_fast_path_emits_notification_on_connection_failure
    ensure_mongo_connection_failure_defined!
    intercept_mongo_role_names_for_user! do |_id, **_kwargs|
      raise ::Mongo::Error::ConnectionFailure, "lost mongo socket"
    end

    events = []
    subscriber = ActiveSupport::Notifications.subscribe(
      "parse.role.fast_path_unavailable",
    ) { |*args| events << ActiveSupport::Notifications::Event.new(*args) }

    result = Parse::Role.all_for_user_mongo_fast_path("U1", 5, master: true)
    assert_nil result, "ConnectionFailure must swallow → nil for slow-path fallback"
    assert_equal 1, events.size, "must emit fast_path_unavailable on swallow"
    payload = events.first.payload
    assert_equal "connection_failure", payload[:reason]
    assert_equal :forward, payload[:direction]
    assert_equal "U1", payload[:target_id]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  # --------------------------------------------------------------
  # MONGO-2: User#acl_roles is scope-checked by default
  # --------------------------------------------------------------

  def test_user_acl_roles_defaults_to_self_scope_and_routes_through_clp
    # Default CLP for _Role is master-only (empty find op-map).
    # When the user-as-self scope hits the CLP gate, it raises Denied.
    Parse::CLPScope.__cache_put(Parse::Model::CLASS_ROLE, clp: { "find" => {} })

    victim = Parse::User.new
    victim.id = "VICTIM"
    err = assert_raises(Parse::CLPScope::Denied) do
      victim.acl_roles
    end
    assert_equal Parse::Model::CLASS_ROLE, err.class_name
    assert_equal :find, err.operation
  end

  def test_user_acl_roles_with_master_bypasses_clp_check
    Parse::CLPScope.__cache_put(Parse::Model::CLASS_ROLE, clp: { "find" => {} })
    intercept_mongo_role_names_for_user! do |_id, **kwargs|
      assert_equal true, kwargs[:master]
      assert_nil kwargs[:as]
      Set.new(["Admin"])
    end

    user = Parse::User.new
    user.id = "U1"
    assert_equal Set["Admin"], user.acl_roles(master: true)
  end

  def test_user_acl_roles_with_open_role_clp_succeeds_for_self
    # Operator has explicitly opened _Role.find for any authenticated
    # user (requiresAuthentication: true). The CLP gate now permits
    # the user-as-self scope.
    Parse::CLPScope.__cache_put(
      Parse::Model::CLASS_ROLE,
      clp: { "find" => { "requiresAuthentication" => true } },
    )
    intercept_mongo_role_names_for_user! do |id, **kwargs|
      assert_equal "U1", id
      assert_kind_of Parse::User, kwargs[:as]
      assert_equal "U1", kwargs[:as].id
      Set.new(["Member"])
    end

    user = Parse::User.new
    user.id = "U1"
    assert_equal Set["Member"], user.acl_roles
  end

  def test_user_acl_roles_without_id_returns_empty_set
    user = Parse::User.new
    assert_equal Set.new, user.acl_roles
  end

  # --------------------------------------------------------------
  # MONGO-3: Role#all_users routes hydration through scope
  # --------------------------------------------------------------

  def test_role_all_users_with_as_routes_hydration_through_aggregate
    captured = { ids: nil, scope: nil }
    intercept_mongo_users_in_role_subtree! do |id, **kwargs|
      assert_equal "ADMIN-ID", id
      assert_kind_of Parse::User, kwargs[:as]
      Set.new(["U1", "U2"])
    end

    aggregate_called = 0
    Parse::MongoDB.singleton_class.send(:alias_method, :__original_aggregate, :aggregate)
    Parse::MongoDB.define_singleton_method(:aggregate) do |coll, pipe, **kwargs|
      aggregate_called += 1
      captured[:coll] = coll
      captured[:pipe] = pipe
      captured[:scope] = kwargs[:acl_user]
      captured[:ids] = pipe[0]["$match"]["_id"]["$in"]
      []
    end

    role = Parse::Role.new(name: "Admin")
    role.id = "ADMIN-ID"
    scope_user = Parse::User.new
    scope_user.id = "OPERATOR"
    role.all_users(as: scope_user)

    assert_equal 1, aggregate_called,
      "scoped hydration must route through Parse::MongoDB.aggregate"
    assert_equal Parse::Model::CLASS_USER, captured[:coll]
    assert_equal ["U1", "U2"].sort, captured[:ids].sort
    assert_equal scope_user, captured[:scope]
  ensure
    if Parse::MongoDB.singleton_class.method_defined?(:__original_aggregate)
      Parse::MongoDB.singleton_class.send(:alias_method, :aggregate, :__original_aggregate)
      Parse::MongoDB.singleton_class.send(:remove_method, :__original_aggregate)
    end
  end

  def test_role_all_users_without_master_or_as_skips_fast_path
    fast_path_called = false
    intercept_mongo_users_in_role_subtree! do |_id, **_kwargs|
      fast_path_called = true
      Set.new
    end

    role = Parse::Role.new(name: "Admin")
    role.id = "ADMIN-ID"
    # Stub the relation accessors so the slow-path walk returns empty
    # without touching the network.
    role.define_singleton_method(:users) do
      collection = Object.new
      collection.define_singleton_method(:all) { [] }
      collection
    end
    role.define_singleton_method(:roles) do
      collection = Object.new
      collection.define_singleton_method(:all) { [] }
      collection
    end

    role.all_users
    refute fast_path_called,
      "fast path must NOT run when neither master: nor as: is supplied"
  end

  def test_role_all_users_mongo_fast_path_emits_notification_on_connection_failure
    ensure_mongo_connection_failure_defined!
    intercept_mongo_users_in_role_subtree! do |_id, **_kwargs|
      raise ::Mongo::Error::ConnectionFailure, "replica down"
    end

    events = []
    subscriber = ActiveSupport::Notifications.subscribe(
      "parse.role.fast_path_unavailable",
    ) { |*args| events << ActiveSupport::Notifications::Event.new(*args) }

    role = Parse::Role.new(name: "Admin")
    role.id = "ADMIN-ID"
    result = role.all_users_mongo_fast_path(5, master: true)
    assert_nil result
    assert_equal 1, events.size
    payload = events.first.payload
    assert_equal "connection_failure", payload[:reason]
    assert_equal :reverse, payload[:direction]
    assert_equal "ADMIN-ID", payload[:target_id]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  private

  def intercept_mongo_role_names_for_user!(&block)
    unless Parse::MongoDB.singleton_class.method_defined?(:__original_role_names_for_user)
      Parse::MongoDB.singleton_class.send(
        :alias_method, :__original_role_names_for_user, :role_names_for_user,
      )
    end
    Parse::MongoDB.define_singleton_method(:role_names_for_user) do |id, **kwargs|
      block.call(id, **kwargs)
    end
  end

  def intercept_mongo_users_in_role_subtree!(&block)
    unless Parse::MongoDB.singleton_class.method_defined?(:__original_users_in_role_subtree)
      Parse::MongoDB.singleton_class.send(
        :alias_method, :__original_users_in_role_subtree, :users_in_role_subtree,
      )
    end
    Parse::MongoDB.define_singleton_method(:users_in_role_subtree) do |id, **kwargs|
      block.call(id, **kwargs)
    end
  end

  # The bundled `mongo` gem version does not define
  # `Mongo::Error::ConnectionFailure` directly (it has been replaced
  # by `Mongo::Error::SocketError` / `ConnectionPerished` in modern
  # drivers). The role-graph code still references the legacy name
  # under `defined?(::Mongo::Error::ConnectionFailure)`; define a stub
  # in test so the rescue path is exercisable.
  def ensure_mongo_connection_failure_defined!
    require "mongo"
    return if defined?(::Mongo::Error::ConnectionFailure)
    ::Mongo::Error.const_set(:ConnectionFailure, Class.new(::Mongo::Error))
  end
end
