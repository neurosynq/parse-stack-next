require_relative "../../test_helper"

# Tests for the class-level access DSL shortcuts (master_only_class!,
# unlistable_class!, set_class_access) that compose around the existing
# set_clp primitive.

class ClassAccessAuditLog < Parse::Object
  parse_class "ClassAccessAuditLog"
  property :event, :string
  master_only_class!
end

class ClassAccessInvitation < Parse::Object
  parse_class "ClassAccessInvitation"
  property :code, :string
  set_class_access(
    find:   :master,
    count:  :master,
    get:    :public,
    create: :authenticated,
    update: :master,
    delete: :master,
  )
end

class ClassAccessArticle < Parse::Object
  parse_class "ClassAccessArticle"
  property :title, :string
  set_class_access(
    find:   :public,
    get:    :public,
    create: "Admin",
    update: ["Admin", "Editor"],
    delete: "Admin",
  )
end

class ClassAccessUnlistableThing < Parse::Object
  parse_class "ClassAccessUnlistableThing"
  property :name, :string
  unlistable_class!
end

class ClassAccessDslTest < Minitest::Test
  def perms(klass)
    klass.class_permissions.permissions
  end

  def test_master_only_class_locks_every_operation
    Parse::CLP::OPERATIONS.each do |op|
      assert_equal({}, perms(ClassAccessAuditLog)[op],
                   "operation #{op.inspect} must be master-only (empty perm)")
    end
  end

  def test_unlistable_class_locks_find_and_count_only
    p = perms(ClassAccessUnlistableThing)
    assert_equal({}, p[:find], "find must be master-only")
    assert_equal({}, p[:count], "count must be master-only")
    refute p.key?(:get), "get not touched by unlistable_class!"
    refute p.key?(:create), "create not touched by unlistable_class!"
    refute p.key?(:update), "update not touched by unlistable_class!"
    refute p.key?(:delete), "delete not touched by unlistable_class!"
  end

  def test_set_class_access_master_modes
    p = perms(ClassAccessInvitation)
    assert_equal({}, p[:find], ":master => empty perm")
    assert_equal({}, p[:count], ":master => empty perm")
    assert_equal({}, p[:update])
    assert_equal({}, p[:delete])
  end

  def test_set_class_access_public_mode
    p = perms(ClassAccessInvitation)
    assert_equal({ "*" => true }, p[:get], ":public => {* => true}")
  end

  def test_set_class_access_authenticated_mode
    p = perms(ClassAccessInvitation)
    assert_equal({ "requiresAuthentication" => true }, p[:create],
                 ":authenticated => {requiresAuthentication => true}")
  end

  def test_set_class_access_single_role_as_string
    p = perms(ClassAccessArticle)
    assert_equal({ "role:Admin" => true }, p[:create],
                 "String role spec maps to role: prefix")
  end

  def test_set_class_access_array_of_roles
    p = perms(ClassAccessArticle)
    assert_equal({ "role:Admin" => true, "role:Editor" => true }, p[:update],
                 "Array of roles produces multi-role permission")
  end

  def test_set_class_access_public_simple
    p = perms(ClassAccessArticle)
    assert_equal({ "*" => true }, p[:find])
    assert_equal({ "*" => true }, p[:get])
  end

  def test_set_class_access_rejects_unknown_operation
    klass = Class.new(Parse::Object) do
      def self.parse_class; "BadOp"; end
    end
    err = assert_raises(ArgumentError) { klass.set_class_access(unknownOp: :master) }
    assert_match(/Unknown CLP operation/, err.message)
  end

  def test_set_class_access_rejects_unknown_value
    klass = Class.new(Parse::Object) do
      def self.parse_class; "BadValue"; end
    end
    err = assert_raises(ArgumentError) { klass.set_class_access(find: 12345) }
    assert_match(/Unknown class_access value/, err.message)
  end

  def test_serialized_clp_round_trips_through_as_json
    # Sanity that the DSL output is what we'd send to Parse Server.
    json = ClassAccessInvitation.class_permissions.as_json
    assert_equal({}, json["find"])
    assert_equal({ "*" => true }, json["get"])
    assert_equal({ "requiresAuthentication" => true }, json["create"])
  end
end
