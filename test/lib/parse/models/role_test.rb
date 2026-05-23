require_relative "../../../test_helper"

class TestRole < Minitest::Test
  CORE_FIELDS = Parse::Object.fields.merge({
    :id => :string,
    :created_at => :date,
    :updated_at => :date,
    :acl => :acl,
    :objectId => :string,
    :createdAt => :date,
    :updatedAt => :date,
    :ACL => :acl,
    :name => :string,
  })

  def test_properties
    assert Parse::Role < Parse::Object
    assert_equal CORE_FIELDS, Parse::Role.fields
    assert_empty Parse::Role.references
    # Note: :users relation uses "User" (Ruby class name) not "_User" (Parse internal name)
    # This is because has_many :users infers the class name from :users symbol
    assert_equal({ :roles => Parse::Model::CLASS_ROLE, :users => "User" }, Parse::Role.relations)
  end

  # Test class methods
  def test_class_method_find_by_name_exists
    assert_respond_to Parse::Role, :find_by_name
  end

  def test_class_method_find_or_create_exists
    assert_respond_to Parse::Role, :find_or_create
  end

  def test_class_method_all_names_exists
    assert_respond_to Parse::Role, :all_names
  end

  def test_class_method_exists_method
    assert_respond_to Parse::Role, :exists?
  end

  # Test instance methods for user management
  def test_add_user_method_exists
    role = Parse::Role.new
    assert_respond_to role, :add_user
  end

  def test_add_users_method_exists
    role = Parse::Role.new
    assert_respond_to role, :add_users
  end

  def test_remove_user_method_exists
    role = Parse::Role.new
    assert_respond_to role, :remove_user
  end

  def test_remove_users_method_exists
    role = Parse::Role.new
    assert_respond_to role, :remove_users
  end

  # Test instance methods for role hierarchy
  def test_add_child_role_method_exists
    role = Parse::Role.new
    assert_respond_to role, :add_child_role
  end

  def test_add_child_roles_method_exists
    role = Parse::Role.new
    assert_respond_to role, :add_child_roles
  end

  def test_remove_child_role_method_exists
    role = Parse::Role.new
    assert_respond_to role, :remove_child_role
  end

  def test_remove_child_roles_method_exists
    role = Parse::Role.new
    assert_respond_to role, :remove_child_roles
  end

  # Test query methods
  def test_has_user_method_exists
    role = Parse::Role.new
    assert_respond_to role, :has_user?
  end

  def test_has_child_role_method_exists
    role = Parse::Role.new
    assert_respond_to role, :has_child_role?
  end

  def test_all_users_method_exists
    role = Parse::Role.new
    assert_respond_to role, :all_users
  end

  def test_all_child_roles_method_exists
    role = Parse::Role.new
    assert_respond_to role, :all_child_roles
  end

  # Test count methods
  def test_users_count_method_exists
    role = Parse::Role.new
    assert_respond_to role, :users_count
  end

  def test_child_roles_count_method_exists
    role = Parse::Role.new
    assert_respond_to role, :child_roles_count
  end

  def test_total_users_count_method_exists
    role = Parse::Role.new
    assert_respond_to role, :total_users_count
  end

  # Test method arity (they return self for chaining)
  def test_add_user_method_arity
    role = Parse::Role.new
    # Method takes exactly 1 argument
    assert_equal 1, role.method(:add_user).arity
  end

  def test_add_users_method_arity
    role = Parse::Role.new
    # Method takes variable args
    assert_equal(-1, role.method(:add_users).arity)
  end

  def test_add_child_role_method_arity
    role = Parse::Role.new
    # Method takes exactly 1 argument
    assert_equal 1, role.method(:add_child_role).arity
  end

  # Test has_user returns false for invalid input
  def test_has_user_returns_false_for_non_user
    role = Parse::Role.new(name: "TestRole")
    refute role.has_user?("not a user")
  end

  def test_has_user_returns_false_for_user_without_id
    role = Parse::Role.new(name: "TestRole")
    user = Parse::User.new
    refute role.has_user?(user)
  end

  # Test has_child_role returns false for invalid input
  def test_has_child_role_returns_false_for_non_role
    role = Parse::Role.new(name: "TestRole")
    refute role.has_child_role?("not a role")
  end

  def test_has_child_role_returns_false_for_role_without_id
    role = Parse::Role.new(name: "TestRole")
    child = Parse::Role.new(name: "Child")
    refute role.has_child_role?(child)
  end

  # Test all_users with max_depth protection
  def test_all_users_respects_max_depth
    role = Parse::Role.new(name: "TestRole")
    # At depth 0, should return empty array
    result = role.all_users(max_depth: 0)
    assert_equal [], result
  end

  # Test all_child_roles with max_depth protection
  def test_all_child_roles_respects_max_depth
    role = Parse::Role.new(name: "TestRole")
    # At depth 0, should return empty array
    result = role.all_child_roles(max_depth: 0)
    assert_equal [], result
  end
end
