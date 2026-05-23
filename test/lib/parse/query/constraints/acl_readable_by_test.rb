require_relative '../../../../test_helper'
require 'minitest/autorun'

class ACLReadableByConstraintTest < Minitest::Test
  
  def setup
    @constraint_class = Parse::Constraint::ACLReadableByConstraint
  end
  
  def test_single_role_string
    puts "\n=== Testing Single Role String ==="
    
    constraint = @constraint_class.new(:ACL, "Admin")
    result = constraint.build
    
    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_rperm" => { "$in" => ["role:Admin", "*"] } },
              { "_rperm" => { "$exists" => false } }
            ]
          }
        }
      ]
    }
    assert_equal expected, result, "Should create ACL constraint for single role"
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
              { "_rperm" => { "$in" => ["role:Admin", "*"] } },
              { "_rperm" => { "$exists" => false } }
            ]
          }
        }
      ]
    }
    assert_equal expected, result, "Should handle role: prefix correctly"
    puts "✅ Role string with prefix constraint works correctly"
  end
  
  def test_array_of_role_strings
    puts "\n=== Testing Array of Role Strings ==="
    
    constraint = @constraint_class.new(:ACL, ["Admin", "Moderator"])
    result = constraint.build
    
    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_rperm" => { "$in" => ["role:Admin", "role:Moderator", "*"] } },
              { "_rperm" => { "$exists" => false } }
            ]
          }
        }
      ]
    }
    assert_equal expected, result, "Should create ACL constraint for multiple roles"
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
              { "_rperm" => { "$in" => ["user123", "*"] } },
              { "_rperm" => { "$exists" => false } }
            ]
          }
        }
      ]
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
              { "_rperm" => { "$in" => ["user456", "*"] } },
              { "_rperm" => { "$exists" => false } }
            ]
          }
        }
      ]
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
    
    constraint = @constraint_class.new(:ACL, [user, user_pointer, "Admin", "role:Moderator"])
    result = constraint.build
    
    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_rperm" => { "$in" => ["user789", "user101", "role:Admin", "role:Moderator", "*"] } },
              { "_rperm" => { "$exists" => false } }
            ]
          }
        }
      ]
    }
    assert_equal expected, result, "Should handle mixed array of users and roles"
    puts "✅ Mixed array constraint works correctly"
  end
  
  def test_rperm_field
    puts "\n=== Testing _rperm Field ==="
    
    constraint = @constraint_class.new(:_rperm, ["Admin", "Moderator"])
    result = constraint.build
    
    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_rperm" => { "$in" => ["role:Admin", "role:Moderator", "*"] } },
              { "_rperm" => { "$exists" => false } }
            ]
          }
        }
      ]
    }
    assert_equal expected, result, "Should create _rperm constraint with public access"
    puts "✅ _rperm field constraint works correctly"
  end
  
  def test_rperm_with_user
    puts "\n=== Testing _rperm with User ==="
    
    # Mock user object
    user = Object.new
    user.define_singleton_method(:id) { "user123" }
    user.define_singleton_method(:is_a?) { |klass| klass == Parse::User }
    
    # Mock the role query to return no roles for simplicity
    Parse::Role.define_singleton_method(:all) { [] }
    
    constraint = @constraint_class.new(:_rperm, [user, "Admin"])
    result = constraint.build
    
    expected = {
      "__aggregation_pipeline" => [
        {
          "$match" => {
            "$or" => [
              { "_rperm" => { "$in" => ["user123", "role:Admin", "*"] } },
              { "_rperm" => { "$exists" => false } }
            ]
          }
        }
      ]
    }
    assert_equal expected, result, "Should create _rperm constraint with user ID and roles"
    puts "✅ _rperm with user constraint works correctly"
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
              { "_rperm" => { "$in" => ["role:TestRole", "*"] } },
              { "_rperm" => { "$exists" => false } }
            ]
          }
        }
      ]
    }
    assert_equal expected, result, "Should create ACL constraint for role object"
    puts "✅ Role object constraint works correctly"
  end
end