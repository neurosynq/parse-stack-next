# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

class TestCLP < Minitest::Test
  def setup
    @clp = Parse::CLP.new
  end

  # ==========================================================================
  # Basic CLP Structure Tests
  # ==========================================================================

  def test_operations_constant
    expected = %i[find get count create update delete addField]
    assert_equal expected, Parse::CLP::OPERATIONS
  end

  def test_new_clp_is_empty
    assert @clp.empty?
    refute @clp.present?
  end

  def test_set_permission_for_operation
    @clp.set_permission(:find, public_access: true)
    assert @clp.find_allowed?("*")
    assert @clp.public_access?(:find)
  end

  def test_set_permission_with_roles
    @clp.set_permission(:create, roles: ["Admin", "Editor"])
    assert @clp.role_allowed?(:create, "Admin")
    assert @clp.role_allowed?(:create, "Editor")
    refute @clp.role_allowed?(:create, "Member")
  end

  def test_set_permission_with_users
    @clp.set_permission(:delete, users: ["user123", "user456"])
    assert @clp.allowed?(:delete, "user123")
    assert @clp.allowed?(:delete, "user456")
    refute @clp.allowed?(:delete, "user789")
  end

  def test_set_permission_requires_authentication
    @clp.set_permission(:find, requires_authentication: true)
    assert @clp.requires_authentication?(:find)
    refute @clp.requires_authentication?(:get)
  end

  def test_invalid_operation_raises_error
    assert_raises(ArgumentError) do
      @clp.set_permission(:invalid_op, public_access: true)
    end
  end

  # ==========================================================================
  # Protected Fields Tests
  # ==========================================================================

  def test_set_protected_fields
    @clp.set_protected_fields("*", ["email", "phone"])
    assert_equal ["email", "phone"], @clp.protected_fields_for("*")
  end

  def test_set_protected_fields_with_symbols
    @clp.set_protected_fields("*", [:email, :phone])
    assert_equal ["email", "phone"], @clp.protected_fields_for("*")
  end

  def test_set_protected_fields_for_role
    @clp.set_protected_fields("role:Admin", [])
    assert_equal [], @clp.protected_fields_for("role:Admin")
  end

  def test_set_protected_fields_for_user_field
    @clp.set_protected_fields("userField:owner", [])
    assert_equal [], @clp.protected_fields_for("userField:owner")
  end

  def test_public_pattern_alias
    @clp.set_protected_fields(:public, ["secret"])
    assert_equal ["secret"], @clp.protected_fields_for("*")
  end

  def test_protected_fields_returns_copy
    @clp.set_protected_fields("*", ["email"])
    fields = @clp.protected_fields
    fields["*"] << "phone"
    assert_equal ["email"], @clp.protected_fields_for("*")
  end

  # ==========================================================================
  # Filter Fields Tests - Basic
  # ==========================================================================

  def test_filter_fields_returns_data_when_no_protected_fields
    data = { "name" => "Test", "email" => "test@test.com" }
    result = @clp.filter_fields(data, user: nil)
    assert_equal data, result
  end

  def test_filter_fields_hides_protected_fields_from_public
    @clp.set_protected_fields("*", ["email"])
    data = { "name" => "Test", "email" => "test@test.com" }

    result = @clp.filter_fields(data, user: nil)

    assert_equal({ "name" => "Test" }, result)
  end

  def test_filter_fields_hides_multiple_fields
    @clp.set_protected_fields("*", ["email", "phone"])
    data = { "name" => "Test", "email" => "test@test.com", "phone" => "123" }

    result = @clp.filter_fields(data, user: nil)

    assert_equal({ "name" => "Test" }, result)
  end

  def test_filter_fields_shows_all_when_empty_array
    @clp.set_protected_fields("*", [])
    data = { "name" => "Test", "email" => "test@test.com" }

    result = @clp.filter_fields(data, user: nil)

    assert_equal data, result
  end

  def test_filter_fields_handles_nil_data
    assert_nil @clp.filter_fields(nil, user: nil)
  end

  def test_filter_fields_handles_array_of_objects
    @clp.set_protected_fields("*", ["email"])
    data = [
      { "name" => "User1", "email" => "user1@test.com" },
      { "name" => "User2", "email" => "user2@test.com" }
    ]

    result = @clp.filter_fields(data, user: nil)

    assert_equal 2, result.length
    result.each do |item|
      assert item.key?("name")
      refute item.key?("email")
    end
  end

  # ==========================================================================
  # Filter Fields Tests - Role-Based
  # ==========================================================================

  def test_filter_fields_for_role_user
    @clp.set_protected_fields("*", ["secret"])
    @clp.set_protected_fields("role:Admin", [])  # Admins see everything

    data = { "name" => "Test", "secret" => "hidden" }

    # Without role - secret hidden
    result_public = @clp.filter_fields(data, user: nil, roles: [])
    refute result_public.key?("secret")

    # With Admin role - everything visible
    result_admin = @clp.filter_fields(data, user: "user1", roles: ["Admin"])
    assert_equal data, result_admin
  end

  def test_filter_fields_intersection_with_multiple_roles
    # Per Parse Server: intersection of protected fields for all matching patterns
    @clp.set_protected_fields("role:Role1", ["owner"])
    @clp.set_protected_fields("role:Role2", ["owner", "test"])

    data = { "name" => "Test", "owner" => "user1", "test" => "value" }

    # User has both roles - intersection is ["owner"]
    result = @clp.filter_fields(data, user: "user1", roles: ["Role1", "Role2"])

    refute result.key?("owner"), "owner should be hidden (in both role protections)"
    assert result.key?("test"), "test should be visible (only in Role2, intersection with Role1 clears it)"
  end

  def test_filter_fields_role_clears_public_protection
    # Role with empty array should clear protection
    @clp.set_protected_fields("*", ["secret"])
    @clp.set_protected_fields("role:Admin", [])

    data = { "name" => "Test", "secret" => "value" }

    result = @clp.filter_fields(data, user: "user1", roles: ["Admin"])
    assert result.key?("secret"), "Admin role should clear all protections"
  end

  # ==========================================================================
  # Filter Fields Tests - Authenticated Users
  # ==========================================================================

  def test_filter_fields_authenticated_pattern
    @clp.set_protected_fields("authenticated", ["internal"])

    data = { "name" => "Test", "internal" => "hidden" }

    # Unauthenticated - field visible (no * pattern, no authenticated pattern applies)
    result_unauth = @clp.filter_fields(data, user: nil, authenticated: false)
    assert_equal data, result_unauth

    # Authenticated - field hidden
    result_auth = @clp.filter_fields(data, user: "user1", authenticated: true)
    refute result_auth.key?("internal")
  end

  def test_filter_fields_intersection_public_and_authenticated
    # When both * and authenticated patterns exist, intersection applies
    @clp.set_protected_fields("*", ["owner", "testers"])
    @clp.set_protected_fields("authenticated", ["testers"])

    data = { "name" => "Test", "owner" => "user1", "testers" => ["user1"] }

    # Authenticated user - intersection of * and authenticated
    # * hides [owner, testers], authenticated hides [testers]
    # intersection = [testers]
    result = @clp.filter_fields(data, user: "user1", authenticated: true)

    assert result.key?("owner"), "owner should be visible (not in authenticated pattern)"
    refute result.key?("testers"), "testers should be hidden (in both patterns)"
  end

  # ==========================================================================
  # Filter Fields Tests - userField Pointer Permissions
  # ==========================================================================

  def test_filter_fields_user_field_single_pointer
    @clp.set_protected_fields("*", ["owner"])
    @clp.set_protected_fields("userField:owner", [])

    data = {
      "name" => "Test",
      "owner" => { "objectId" => "user1", "__type" => "Pointer" },
      "test" => "value"
    }

    # Owner can see owner field
    result_owner = @clp.filter_fields(data, user: "user1")
    assert result_owner.key?("owner"), "owner should see their own pointer field"

    # Non-owner cannot see owner field
    result_other = @clp.filter_fields(data, user: "user2")
    refute result_other.key?("owner"), "non-owner should not see owner field"
  end

  def test_filter_fields_user_field_array_of_pointers
    @clp.set_protected_fields("*", ["owners"])
    @clp.set_protected_fields("userField:owners", [])

    data = {
      "name" => "Test",
      "owners" => [
        { "objectId" => "user1", "__type" => "Pointer" },
        { "objectId" => "user2", "__type" => "Pointer" }
      ]
    }

    # User in array can see field
    result_user1 = @clp.filter_fields(data, user: "user1")
    assert result_user1.key?("owners")

    result_user2 = @clp.filter_fields(data, user: "user2")
    assert result_user2.key?("owners")

    # User not in array cannot see field
    result_user3 = @clp.filter_fields(data, user: "user3")
    refute result_user3.key?("owners")
  end

  def test_filter_fields_user_field_intersection_multiple_pointers
    # Per Parse Server spec: intersection when user matches multiple userField patterns
    @clp.set_protected_fields("*", ["owners", "owner", "test"])
    @clp.set_protected_fields("userField:owners", ["owners", "owner"])
    @clp.set_protected_fields("userField:owner", ["owner"])

    data = {
      "owners" => [{ "objectId" => "user1" }],
      "owner" => { "objectId" => "user1" },
      "test" => "value"
    }

    # User1 matches both userField patterns
    # userField:owners hides [owners, owner]
    # userField:owner hides [owner]
    # * hides [owners, owner, test]
    # All three match, intersection = [owner]
    result = @clp.filter_fields(data, user: "user1")

    assert result.key?("owners"), "owners visible (cleared by userField:owner)"
    refute result.key?("owner"), "owner hidden (in all three patterns)"
    assert result.key?("test"), "test visible (cleared by userField patterns)"
  end

  def test_filter_fields_ignores_nonexistent_pointer_field
    @clp.set_protected_fields("*", [])
    @clp.set_protected_fields("userField:nonexistent", ["owner"])

    data = {
      "owner" => { "objectId" => "user1" },
      "test" => "value"
    }

    # userField:nonexistent pattern should be ignored since field doesn't exist
    result = @clp.filter_fields(data, user: "user1")
    assert result.key?("owner")
    assert result.key?("test")
  end

  def test_filter_fields_per_object_in_array
    # Different objects may have different owners, filtering should be per-object
    @clp.set_protected_fields("*", ["owner"])
    @clp.set_protected_fields("userField:owner", [])

    data = [
      { "name" => "Obj1", "owner" => { "objectId" => "user1" } },
      { "name" => "Obj2", "owner" => { "objectId" => "user2" } },
      { "name" => "Obj3", "owner" => { "objectId" => "user2" } }
    ]

    result = @clp.filter_fields(data, user: "user1")

    # User1 owns Obj1, should see owner there
    assert result[0].key?("owner"), "user1 should see owner in their owned object"

    # User1 doesn't own Obj2 or Obj3
    refute result[1].key?("owner"), "user1 should not see owner in user2's object"
    refute result[2].key?("owner"), "user1 should not see owner in user2's object"
  end

  # ==========================================================================
  # Serialization Tests
  # ==========================================================================

  def test_as_json_basic
    @clp.set_permission(:find, public_access: true)
    @clp.set_permission(:get, public_access: true)
    @clp.set_protected_fields("*", ["email"])

    json = @clp.as_json

    assert_equal({ "*" => true }, json["find"])
    assert_equal({ "*" => true }, json["get"])
    assert_equal({ "*" => ["email"] }, json["protectedFields"])
  end

  def test_as_json_with_roles
    @clp.set_permission(:create, roles: ["Admin"])

    json = @clp.as_json

    assert_equal({ "role:Admin" => true }, json["create"])
  end

  def test_to_h_alias
    @clp.set_permission(:find, public_access: true)

    assert_equal @clp.as_json, @clp.to_h
  end

  # ==========================================================================
  # Parsing Server Data Tests
  # ==========================================================================

  def test_initialize_from_server_data
    server_data = {
      "find" => { "*" => true },
      "get" => { "*" => true, "requiresAuthentication" => true },
      "create" => { "role:Admin" => true },
      "protectedFields" => {
        "*" => ["email", "phone"],
        "role:Admin" => []
      }
    }

    clp = Parse::CLP.new(server_data)

    assert clp.find_allowed?("*")
    assert clp.get_allowed?("*")
    assert clp.requires_authentication?(:get)
    assert clp.role_allowed?(:create, "Admin")
    assert_equal ["email", "phone"], clp.protected_fields_for("*")
    assert_equal [], clp.protected_fields_for("role:Admin")
  end

  # ==========================================================================
  # Merge Tests
  # ==========================================================================

  def test_merge_creates_new_clp
    @clp.set_permission(:find, public_access: true)

    other = Parse::CLP.new
    other.set_permission(:get, public_access: true)

    merged = @clp.merge(other)

    assert merged.find_allowed?("*")
    assert merged.get_allowed?("*")

    # Original unchanged
    refute @clp.get_allowed?("*")
  end

  def test_merge_bang_modifies_in_place
    @clp.set_permission(:find, public_access: true)

    other = Parse::CLP.new
    other.set_permission(:get, public_access: true)

    @clp.merge!(other)

    assert @clp.find_allowed?("*")
    assert @clp.get_allowed?("*")
  end

  # ==========================================================================
  # Equality Tests
  # ==========================================================================

  def test_equality_with_same_permissions
    clp1 = Parse::CLP.new
    clp1.set_permission(:find, public_access: true)
    clp1.set_protected_fields("*", ["email"])

    clp2 = Parse::CLP.new
    clp2.set_permission(:find, public_access: true)
    clp2.set_protected_fields("*", ["email"])

    assert_equal clp1, clp2
  end

  def test_equality_with_hash
    @clp.set_permission(:find, public_access: true)

    assert_equal @clp, { "find" => { "*" => true } }
  end

  def test_dup_creates_deep_copy
    @clp.set_protected_fields("*", ["email"])

    copy = @clp.dup
    copy.set_protected_fields("*", ["email", "phone"])

    assert_equal ["email"], @clp.protected_fields_for("*")
    assert_equal ["email", "phone"], copy.protected_fields_for("*")
  end
end

# ==========================================================================
# Model DSL Integration Tests
# ==========================================================================

class TestCLPModelDSL < Minitest::Test
  # Test model with CLP definitions
  # Note: Protected fields use the JSON/camelCase field names since that's
  # what's used when filtering API responses
  class SecureDocument < Parse::Object
    parse_class "SecureDocument"

    property :title, :string
    property :content, :string
    property :internal_notes, :string
    property :secret_data, :string

    # Define CLPs
    set_clp :find, public: true
    set_clp :get, public: true
    set_clp :create, public: false, roles: ["Admin", "Editor"]
    set_clp :update, public: false, roles: ["Admin", "Editor"]
    set_clp :delete, public: false, roles: ["Admin"]

    # Define protected fields using camelCase (JSON field names)
    protect_fields "*", ["internalNotes", "secretData"]
    protect_fields "role:Admin", []
  end

  class OwnedDocument < Parse::Object
    parse_class "OwnedDocument"

    property :title, :string
    property :secret, :string
    belongs_to :owner

    protect_fields "*", [:secret, :owner]
    protect_fields "userField:owner", []
  end

  def test_class_permissions_returns_clp
    assert_instance_of Parse::CLP, SecureDocument.class_permissions
  end

  def test_clp_alias
    assert_equal SecureDocument.class_permissions, SecureDocument.clp
  end

  def test_set_clp_configures_operations
    clp = SecureDocument.class_permissions

    assert clp.find_allowed?("*")
    assert clp.get_allowed?("*")
    refute clp.create_allowed?("*")
    assert clp.role_allowed?(:create, "Admin")
    assert clp.role_allowed?(:create, "Editor")
    assert clp.role_allowed?(:delete, "Admin")
    refute clp.role_allowed?(:delete, "Editor")
  end

  def test_protect_fields_configures_protected_fields
    clp = SecureDocument.class_permissions

    # Uses camelCase as that's what matches JSON output
    assert_equal ["internalNotes", "secretData"], clp.protected_fields_for("*")
    assert_equal [], clp.protected_fields_for("role:Admin")
  end

  def test_filter_for_user_public
    doc = SecureDocument.new
    doc.title = "Test"
    doc.content = "Public content"
    doc.internal_notes = "Internal only"
    doc.secret_data = "Top secret"

    filtered = doc.filter_for_user(nil)

    assert filtered.key?("title")
    assert filtered.key?("content")
    refute filtered.key?("internalNotes"), "internalNotes should be hidden from public"
    refute filtered.key?("secretData"), "secretData should be hidden from public"
  end

  def test_filter_for_user_admin
    doc = SecureDocument.new
    doc.title = "Test"
    doc.content = "Public content"
    doc.internal_notes = "Internal only"
    doc.secret_data = "Top secret"

    filtered = doc.filter_for_user("admin_user_id", roles: ["Admin"])

    assert filtered.key?("title")
    assert filtered.key?("content")
    assert filtered.key?("internalNotes"), "Admin should see internalNotes"
    assert filtered.key?("secretData"), "Admin should see secretData"
  end

  def test_filter_results_for_user
    docs = [
      SecureDocument.new,
      SecureDocument.new
    ]
    docs[0].title = "Doc1"
    docs[0].internal_notes = "Note1"
    docs[1].title = "Doc2"
    docs[1].internal_notes = "Note2"

    filtered = SecureDocument.filter_results_for_user(docs, nil)

    assert_equal 2, filtered.length
    filtered.each do |doc|
      assert doc.key?("title")
      refute doc.key?("internalNotes"), "internalNotes should be hidden"
    end
  end

  def test_owned_document_owner_access
    # Reset CLP for fresh test
    OwnedDocument.instance_variable_set(:@class_permissions, nil)
    OwnedDocument.protect_fields "*", [:secret, :owner]
    OwnedDocument.protect_fields "userField:owner", []

    clp = OwnedDocument.class_permissions

    data = {
      "title" => "My Doc",
      "secret" => "shhh",
      "owner" => { "objectId" => "user1", "__type" => "Pointer" }
    }

    # Owner sees everything
    owner_result = clp.filter_fields(data, user: "user1")
    assert owner_result.key?("secret")
    assert owner_result.key?("owner")

    # Non-owner doesn't see protected fields
    other_result = clp.filter_fields(data, user: "user2")
    refute other_result.key?("secret")
    refute other_result.key?("owner")
  end
end

# =============================================================================
# Unit Tests for New CLP Features (3.2.1+)
# =============================================================================

class TestCLPDefaultPermissions < Minitest::Test
  def setup
    @clp = Parse::CLP.new
  end

  def test_set_default_permission_public
    @clp.set_default_permission(public_access: true)
    assert_equal({ "*" => true }, @clp.default_permission)
  end

  def test_set_default_permission_requires_auth
    @clp.set_default_permission(requires_authentication: true)
    assert_equal({ "requiresAuthentication" => true }, @clp.default_permission)
  end

  def test_set_default_permission_with_roles
    @clp.set_default_permission(roles: ["Admin", "Editor"])
    assert_equal({ "role:Admin" => true, "role:Editor" => true }, @clp.default_permission)
  end

  def test_as_json_includes_defaults_when_set
    @clp.set_default_permission(public_access: true)
    @clp.set_protected_fields("*", ["secret"])

    json = @clp.as_json

    # All operations should have default permission
    %w[find get count create update delete addField].each do |op|
      assert json.key?(op), "Should include #{op}"
      assert_equal({ "*" => true }, json[op])
    end

    assert json.key?("protectedFields")
  end

  def test_as_json_explicit_permissions_override_defaults
    @clp.set_default_permission(public_access: true)
    @clp.set_permission(:delete, roles: ["Admin"])

    json = @clp.as_json

    # Delete should have role permission, not default
    assert_equal({ "role:Admin" => true }, json["delete"])

    # Others should have default
    assert_equal({ "*" => true }, json["find"])
  end

  def test_as_json_without_defaults_excludes_undefined_operations
    @clp.set_permission(:find, public_access: true)
    @clp.set_protected_fields("*", ["secret"])

    json = @clp.as_json

    assert json.key?("find")
    refute json.key?("get"), "Should not include undefined operations without defaults"
    refute json.key?("create")
  end

  def test_as_json_include_defaults_false_overrides
    @clp.set_default_permission(public_access: true)
    @clp.set_permission(:find, public_access: true)

    json = @clp.as_json(include_defaults: false)

    assert json.key?("find")
    refute json.key?("get"), "Should not include defaults when include_defaults: false"
  end

  # This test covers the edge case that caused "Permission denied" errors:
  # When a model has only protect_fields (no set_default_clp), and auto_upgrade!
  # calls as_json(include_defaults: true), all operations should still be included
  # with public access as the fallback default.
  def test_as_json_include_defaults_true_without_set_default_permission
    # Only set protected fields, no set_default_permission or set_permission
    @clp.set_protected_fields("*", ["secret_field"])

    # This is what auto_upgrade! does
    json = @clp.as_json(include_defaults: true)

    # All operations should be included with public access (the fallback default)
    %w[find get count create update delete addField].each do |op|
      assert json.key?(op), "Should include #{op} operation"
      assert_equal({ "*" => true }, json[op], "#{op} should default to public access"
      )
    end

    # Protected fields should also be included
    assert json.key?("protectedFields")
    assert_equal ["secret_field"], json["protectedFields"]["*"]
  end
end

class TestCLPPointerPermissions < Minitest::Test
  def setup
    @clp = Parse::CLP.new
  end

  def test_set_read_user_fields
    @clp.set_read_user_fields(:owner, :collaborators)
    assert_equal %w[owner collaborators], @clp.read_user_fields
  end

  def test_set_write_user_fields
    @clp.set_write_user_fields(:owner)
    assert_equal %w[owner], @clp.write_user_fields
  end

  def test_as_json_includes_pointer_permissions
    @clp.set_read_user_fields(:owner, :editor)
    @clp.set_write_user_fields(:owner)

    json = @clp.as_json

    assert_equal %w[owner editor], json["readUserFields"]
    assert_equal %w[owner], json["writeUserFields"]
  end

  def test_parse_data_handles_pointer_permissions
    data = {
      "find" => { "*" => true },
      "readUserFields" => ["owner", "collaborators"],
      "writeUserFields" => ["owner"]
    }

    @clp.parse_data(data)

    assert_equal %w[owner collaborators], @clp.read_user_fields
    assert_equal %w[owner], @clp.write_user_fields
  end

  def test_pointer_permissions_constant
    assert_includes Parse::CLP::POINTER_PERMISSIONS, :readUserFields
    assert_includes Parse::CLP::POINTER_PERMISSIONS, :writeUserFields
  end
end

class TestCLPSnakeCaseConversion < Minitest::Test
  # Test model with snake_case properties
  class SnakeCaseDoc < Parse::Object
    property :internal_notes, :string
    property :secret_data, :string
    property :owner_user, :pointer, as: :user
    property :custom_field, :string, field: "myCustomField"
  end

  def teardown
    # Reset class permissions after each test
    SnakeCaseDoc.instance_variable_set(:@class_permissions, nil)
  end

  def test_protect_fields_converts_snake_case_to_camel_case
    SnakeCaseDoc.protect_fields "*", [:internal_notes, :secret_data]

    clp = SnakeCaseDoc.class_permissions
    fields = clp.protected_fields["*"]

    assert_includes fields, "internalNotes"
    assert_includes fields, "secretData"
    refute_includes fields, "internal_notes"
  end

  def test_protect_fields_uses_field_map_for_custom_fields
    SnakeCaseDoc.protect_fields "*", [:custom_field]

    clp = SnakeCaseDoc.class_permissions
    fields = clp.protected_fields["*"]

    assert_includes fields, "myCustomField"
    refute_includes fields, "customField"
  end

  def test_protect_fields_converts_userField_pattern
    SnakeCaseDoc.protect_fields "userField:owner_user", []

    clp = SnakeCaseDoc.class_permissions

    assert clp.protected_fields.key?("userField:ownerUser")
    refute clp.protected_fields.key?("userField:owner_user")
  end

  def test_set_clp_converts_pointer_fields
    SnakeCaseDoc.set_clp :update, pointer_fields: [:owner_user]

    clp = SnakeCaseDoc.class_permissions
    perm = clp.permissions[:update]

    # Pointer fields are stored as symbols internally
    assert perm["pointerFields"].include?(:ownerUser) || perm["pointerFields"].include?("ownerUser"),
      "Expected pointerFields to include ownerUser, got: #{perm['pointerFields'].inspect}"
  end

  def test_set_read_user_fields_converts_snake_case
    SnakeCaseDoc.set_read_user_fields :owner_user

    clp = SnakeCaseDoc.class_permissions

    assert_includes clp.read_user_fields, "ownerUser"
    refute_includes clp.read_user_fields, "owner_user"
  end

  def test_set_write_user_fields_converts_snake_case
    SnakeCaseDoc.set_write_user_fields :owner_user

    clp = SnakeCaseDoc.class_permissions

    assert_includes clp.write_user_fields, "ownerUser"
    refute_includes clp.write_user_fields, "owner_user"
  end
end

class TestCLPDefaultCLPMethod < Minitest::Test
  class DefaultCLPDoc < Parse::Object
    property :title, :string
  end

  def teardown
    DefaultCLPDoc.instance_variable_set(:@class_permissions, nil)
  end

  def test_set_default_clp_public
    DefaultCLPDoc.set_default_clp public: true

    json = DefaultCLPDoc.class_permissions.as_json

    %w[find get count create update delete addField].each do |op|
      assert json.key?(op), "Should include #{op}"
      assert_equal({ "*" => true }, json[op])
    end
  end

  def test_set_default_clp_requires_authentication
    DefaultCLPDoc.set_default_clp requires_authentication: true

    json = DefaultCLPDoc.class_permissions.as_json

    %w[find get count create update delete addField].each do |op|
      assert json.key?(op)
      assert_equal({ "requiresAuthentication" => true }, json[op])
    end
  end

  def test_set_default_clp_with_roles
    DefaultCLPDoc.set_default_clp roles: ["Admin"]

    json = DefaultCLPDoc.class_permissions.as_json

    %w[find get count create update delete addField].each do |op|
      assert json.key?(op)
      assert_equal({ "role:Admin" => true }, json[op])
    end
  end

  def test_set_default_clp_then_override_specific_operation
    DefaultCLPDoc.set_default_clp public: true
    DefaultCLPDoc.set_clp :delete, public: false, roles: ["Admin"]

    json = DefaultCLPDoc.class_permissions.as_json

    # Most operations should be public
    assert_equal({ "*" => true }, json["find"])
    assert_equal({ "*" => true }, json["get"])

    # Delete should be restricted
    assert_equal({ "role:Admin" => true }, json["delete"])
  end
end

class TestCLPCompleteCLPOutput < Minitest::Test
  class CompleteCLPDoc < Parse::Object
    property :title, :string
    property :secret, :string
    property :owner_user, :pointer, as: :user
  end

  def teardown
    CompleteCLPDoc.instance_variable_set(:@class_permissions, nil)
  end

  def test_complete_clp_has_all_components
    CompleteCLPDoc.set_default_clp public: true
    CompleteCLPDoc.set_clp :delete, roles: ["Admin"]
    CompleteCLPDoc.set_read_user_fields :owner_user
    CompleteCLPDoc.set_write_user_fields :owner_user
    CompleteCLPDoc.protect_fields "*", [:secret]
    CompleteCLPDoc.protect_fields "role:Admin", []

    json = CompleteCLPDoc.class_permissions.as_json

    # Operations
    assert json.key?("find")
    assert json.key?("get")
    assert json.key?("count")
    assert json.key?("create")
    assert json.key?("update")
    assert json.key?("delete")
    assert json.key?("addField")

    # Pointer permissions
    assert_equal ["ownerUser"], json["readUserFields"]
    assert_equal ["ownerUser"], json["writeUserFields"]

    # Protected fields
    assert json.key?("protectedFields")
    assert json["protectedFields"].key?("*")
    assert json["protectedFields"].key?("role:Admin")
  end
end
