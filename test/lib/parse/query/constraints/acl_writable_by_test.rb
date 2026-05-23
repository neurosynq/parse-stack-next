require_relative "../../../../test_helper"
require "minitest/autorun"

class ACLWritableByConstraintTest < Minitest::Test
  def setup
    @constraint_class = Parse::Constraint::ACLWritableByConstraint
  end

  def test_single_role_string
    puts "\n=== Testing Single Role String ==="

    # Note: strings are used as-is without automatic "role:" prefix
    # Use writable_by_role for automatic prefix, or explicitly include "role:" in string
    constraint = @constraint_class.new(:ACL, "Admin")
    result = constraint.build

    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_wperm" => { "$in" => ["Admin", "*"] } },
              { "_wperm" => { "$exists" => false } },
            ],
          },
        },
      ],
    }
    assert_equal expected, result, "Should create ACL constraint for single string (used as-is)"
    puts "✅ Single role string constraint works correctly"
  end

  def test_role_string_with_prefix
    puts "\n=== Testing Role String with Prefix ==="

    constraint = @constraint_class.new(:ACL, "role:Admin")
    result = constraint.build

    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_wperm" => { "$in" => ["role:Admin", "*"] } },
              { "_wperm" => { "$exists" => false } },
            ],
          },
        },
      ],
    }
    assert_equal expected, result, "Should handle role: prefix correctly"
    puts "✅ Role string with prefix constraint works correctly"
  end

  def test_array_of_role_strings
    puts "\n=== Testing Array of Role Strings ==="

    # Note: strings are used as-is without automatic "role:" prefix
    constraint = @constraint_class.new(:ACL, ["Admin", "Moderator"])
    result = constraint.build

    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_wperm" => { "$in" => ["Admin", "Moderator", "*"] } },
              { "_wperm" => { "$exists" => false } },
            ],
          },
        },
      ],
    }
    assert_equal expected, result, "Should create ACL constraint for multiple strings (used as-is)"
    puts "✅ Array of role strings constraint works correctly"
  end

  def test_user_object
    puts "\n=== Testing User Object ==="

    # Mock user object
    user = Object.new
    user.define_singleton_method(:id) { "user123" }
    user.define_singleton_method(:is_a?) { |klass| klass == Parse::User }

    # Mock the role query to return no roles for simplicity
    Parse::Role.define_singleton_method(:all) { [] }

    constraint = @constraint_class.new(:ACL, user)
    result = constraint.build

    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_wperm" => { "$in" => ["user123", "*"] } },
              { "_wperm" => { "$exists" => false } },
            ],
          },
        },
      ],
    }
    assert_equal expected, result, "Should create ACL constraint for user object"
    puts "✅ User object constraint works correctly"
  end

  def test_user_pointer
    puts "\n=== Testing User Pointer ==="

    # Mock user pointer
    user_pointer = Object.new
    user_pointer.define_singleton_method(:parse_class) { "User" }
    user_pointer.define_singleton_method(:id) { "user456" }
    user_pointer.define_singleton_method(:is_a?) { |klass| klass == Parse::Pointer }

    constraint = @constraint_class.new(:ACL, user_pointer)
    result = constraint.build

    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_wperm" => { "$in" => ["user456", "*"] } },
              { "_wperm" => { "$exists" => false } },
            ],
          },
        },
      ],
    }
    assert_equal expected, result, "Should create ACL constraint for user pointer"
    puts "✅ User pointer constraint works correctly"
  end

  def test_mixed_array
    puts "\n=== Testing Mixed Array ==="

    # Mock user object
    user = Object.new
    user.define_singleton_method(:id) { "user789" }
    user.define_singleton_method(:is_a?) { |klass| klass == Parse::User }

    # Mock user pointer
    user_pointer = Object.new
    user_pointer.define_singleton_method(:parse_class) { "User" }
    user_pointer.define_singleton_method(:id) { "user101" }
    user_pointer.define_singleton_method(:is_a?) { |klass| klass == Parse::Pointer }

    # Mock the role query to return no roles for simplicity
    Parse::Role.define_singleton_method(:all) { [] }

    # Note: "Admin" is used as-is (no automatic prefix), "role:Moderator" already has prefix
    constraint = @constraint_class.new(:ACL, [user, user_pointer, "Admin", "role:Moderator"])
    result = constraint.build

    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_wperm" => { "$in" => ["user789", "user101", "Admin", "role:Moderator", "*"] } },
              { "_wperm" => { "$exists" => false } },
            ],
          },
        },
      ],
    }
    assert_equal expected, result, "Should handle mixed array of users and strings (strings used as-is)"
    puts "✅ Mixed array constraint works correctly"
  end

  def test_wperm_field
    puts "\n=== Testing _wperm Field ==="

    # Note: strings are used as-is without automatic "role:" prefix
    constraint = @constraint_class.new(:_wperm, ["Admin", "Moderator"])
    result = constraint.build

    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_wperm" => { "$in" => ["Admin", "Moderator", "*"] } },
              { "_wperm" => { "$exists" => false } },
            ],
          },
        },
      ],
    }
    assert_equal expected, result, "Should create _wperm constraint with public access (strings as-is)"
    puts "✅ _wperm field constraint works correctly"
  end

  def test_wperm_with_user
    puts "\n=== Testing _wperm with User ==="

    # Mock user object
    user = Object.new
    user.define_singleton_method(:id) { "user123" }
    user.define_singleton_method(:is_a?) { |klass| klass == Parse::User }

    # Mock the role query to return no roles for simplicity
    Parse::Role.define_singleton_method(:all) { [] }

    # Note: "Admin" string is used as-is without automatic "role:" prefix
    constraint = @constraint_class.new(:_wperm, [user, "Admin"])
    result = constraint.build

    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_wperm" => { "$in" => ["user123", "Admin", "*"] } },
              { "_wperm" => { "$exists" => false } },
            ],
          },
        },
      ],
    }
    assert_equal expected, result, "Should create _wperm constraint with user ID and string (as-is)"
    puts "✅ _wperm with user constraint works correctly"
  end

  def test_empty_permissions_error
    puts "\n=== Testing Empty Permissions Error ==="

    # Mock empty user object
    user = Object.new
    user.define_singleton_method(:id) { nil }
    user.define_singleton_method(:is_a?) { |klass| klass == Parse::User }

    assert_raises(ArgumentError) do
      constraint = @constraint_class.new(:ACL, user)
      constraint.build
    end
    puts "✅ Empty permissions raises error correctly"
  end

  def test_invalid_type_error
    puts "\n=== Testing Invalid Type Error ==="

    assert_raises(ArgumentError) do
      constraint = @constraint_class.new(:ACL, 123)
      constraint.build
    end
    puts "✅ Invalid type raises error correctly"
  end

  def test_role_object
    puts "\n=== Testing Role Object ==="

    # Mock role object
    role = Object.new
    role.define_singleton_method(:name) { "TestRole" }
    role.define_singleton_method(:is_a?) { |klass| klass == Parse::Role }

    constraint = @constraint_class.new(:ACL, role)
    result = constraint.build

    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_wperm" => { "$in" => ["role:TestRole", "*"] } },
              { "_wperm" => { "$exists" => false } },
            ],
          },
        },
      ],
    }
    assert_equal expected, result, "Should create ACL constraint for role object"
    puts "✅ Role object constraint works correctly"
  end

  def test_comparison_with_readable_by
    puts "\n=== Testing Difference from readable_by ==="

    # Note: strings are used as-is without automatic "role:" prefix
    readable_constraint = Parse::Constraint::ACLReadableByConstraint.new(:ACL, "Admin")
    writable_constraint = @constraint_class.new(:ACL, "Admin")

    readable_result = readable_constraint.build
    writable_result = writable_constraint.build

    # Should be the same structure but checking different permissions
    # Both use strings as-is without automatic "role:" prefix
    expected_readable = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_rperm" => { "$in" => ["Admin", "*"] } },
              { "_rperm" => { "$exists" => false } },
            ],
          },
        },
      ],
    }
    expected_writable = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_wperm" => { "$in" => ["Admin", "*"] } },
              { "_wperm" => { "$exists" => false } },
            ],
          },
        },
      ],
    }

    assert_equal expected_readable, readable_result, "readable_by should check read permissions"
    assert_equal expected_writable, writable_result, "writable_by should check write permissions"
    refute_equal readable_result, writable_result, "readable_by and writable_by should generate different queries"
    puts "✅ writable_by correctly differs from readable_by"
  end
end
