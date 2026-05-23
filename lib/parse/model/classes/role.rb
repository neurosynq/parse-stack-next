# encoding: UTF-8
# frozen_string_literal: true
# Note: Do not require "../object" here - this file is loaded from object.rb
# and adding that require would create a circular dependency.
# user.rb is also loaded from object.rb before this file.

module Parse
  # This class represents the data and columns contained in the standard Parse `_Role` collection.
  # Roles allow the an application to group a set of {Parse::User} records with the same set of
  # permissions, so that specific records in the database can have {Parse::ACL}s related to a role
  # than trying to add all the users in a group.
  #
  # The default schema for {Role} is as follows:
  #
  #   class Parse::Role < Parse::Object
  #      # See Parse::Object for inherited properties...
  #
  #      property :name
  #
  #      # A role may have child roles.
  #      has_many :roles, through: :relation
  #
  #      # The set of users who belong to this role.
  #      has_many :users, through: :relation
  #   end
  #
  # @example Creating and managing roles
  #   # Create an admin role
  #   admin = Parse::Role.create(name: "Admin")
  #
  #   # Add users to the role
  #   admin.add_user(user1)
  #   admin.add_users(user2, user3)
  #   admin.save
  #
  #   # Create role hierarchy
  #   moderator = Parse::Role.create(name: "Moderator")
  #   admin.add_child_role(moderator)  # Admins inherit Moderator permissions
  #   admin.save
  #
  #   # Query users in role (including child roles)
  #   all_users = admin.all_users  # Includes users from child roles
  #
  # @see Parse::Object
  class Role < Parse::Object
    parse_class Parse::Model::CLASS_ROLE
    # @!attribute name
    # @return [String] the name of this role.
    property :name
    # This attribute is mapped as a `has_many` Parse relation association with the {Parse::Role} class,
    # as roles can be associated with multiple child roles to support role inheritance.
    # The roles Parse relation provides a mechanism to create a hierarchical inheritable types of permissions
    # by assigning child roles.
    # @return [RelationCollectionProxy<Role>] a collection of Roles.
    has_many :roles, through: :relation
    # This attribute is mapped as a `has_many` Parse relation association with the {Parse::User} class.
    # @return [RelationCollectionProxy<User>] a Parse relation of users belonging to this role.
    has_many :users, through: :relation

    class << self
      # Find a role by its name.
      # @param role_name [String] the name of the role to find.
      # @return [Parse::Role, nil] the role if found, nil otherwise.
      # @example
      #   admin = Parse::Role.find_by_name("Admin")
      def find_by_name(role_name)
        query(name: role_name).first
      end

      # Find or create a role by name.
      # @param role_name [String] the name of the role.
      # @param acl [Parse::ACL] optional ACL to set on creation.
      # @return [Parse::Role] the existing or newly created role.
      # @example
      #   admin = Parse::Role.find_or_create("Admin")
      def find_or_create(role_name, acl: nil)
        role = find_by_name(role_name)
        return role if role

        role = new(name: role_name)
        role.acl = acl if acl
        role.save
        role
      end

      # Get all role names in the system.
      # @return [Array<String>] array of role names.
      def all_names
        query.results.map(&:name)
      end

      # Check if a role with the given name exists.
      # @param role_name [String] the name to check.
      # @return [Boolean] true if role exists.
      def exists?(role_name)
        query(name: role_name).count > 0
      end
    end

    # Add a single user to this role.
    # @param user [Parse::User] the user to add.
    # @return [self] returns self for chaining.
    # @example
    #   role.add_user(user).save
    def add_user(user)
      users.add(user)
      self
    end

    # Add multiple users to this role.
    # @param user_list [Array<Parse::User>] users to add.
    # @return [self] returns self for chaining.
    # @example
    #   role.add_users(user1, user2, user3).save
    def add_users(*user_list)
      users.add(user_list.flatten)
      self
    end

    # Remove a single user from this role.
    # @param user [Parse::User] the user to remove.
    # @return [self] returns self for chaining.
    def remove_user(user)
      users.remove(user)
      self
    end

    # Remove multiple users from this role.
    # @param user_list [Array<Parse::User>] users to remove.
    # @return [self] returns self for chaining.
    def remove_users(*user_list)
      users.remove(user_list.flatten)
      self
    end

    # Add a child role to this role's hierarchy.
    # Users in the child role will inherit permissions from this role.
    # @param role [Parse::Role] the child role to add.
    # @return [self] returns self for chaining.
    # @example
    #   admin.add_child_role(moderator)  # Admins can do what Moderators can
    def add_child_role(role)
      roles.add(role)
      self
    end

    # Add multiple child roles to this role's hierarchy.
    # @param role_list [Array<Parse::Role>] child roles to add.
    # @return [self] returns self for chaining.
    def add_child_roles(*role_list)
      roles.add(role_list.flatten)
      self
    end

    # Remove a child role from this role's hierarchy.
    # @param role [Parse::Role] the child role to remove.
    # @return [self] returns self for chaining.
    def remove_child_role(role)
      roles.remove(role)
      self
    end

    # Remove multiple child roles from this role's hierarchy.
    # @param role_list [Array<Parse::Role>] child roles to remove.
    # @return [self] returns self for chaining.
    def remove_child_roles(*role_list)
      roles.remove(role_list.flatten)
      self
    end

    # Check if a user belongs to this role (direct membership only).
    # @param user [Parse::User] the user to check.
    # @return [Boolean] true if user is a direct member.
    def has_user?(user)
      return false unless user.is_a?(Parse::User) && user.id.present?
      users.query.where(objectId: user.id).count > 0
    end

    # Check if a role is a direct child of this role.
    # @param role [Parse::Role] the role to check.
    # @return [Boolean] true if role is a direct child.
    def has_child_role?(role)
      return false unless role.is_a?(Parse::Role) && role.id.present?
      roles.query.where(objectId: role.id).count > 0
    end

    # Get all users belonging to this role, including users from child roles recursively.
    # @param max_depth [Integer] maximum recursion depth to prevent infinite loops.
    # @return [Array<Parse::User>] all users in the role hierarchy.
    # @example
    #   all_users = admin_role.all_users
    def all_users(max_depth: 10)
      return [] if max_depth <= 0

      # Get direct users
      direct_users = users.all

      # Get users from child roles recursively
      child_roles = roles.all
      child_users = child_roles.flat_map do |child_role|
        child_role.all_users(max_depth: max_depth - 1)
      end

      (direct_users + child_users).uniq { |u| u.id }
    end

    # Get all child roles recursively.
    # @param max_depth [Integer] maximum recursion depth to prevent infinite loops.
    # @return [Array<Parse::Role>] all child roles in the hierarchy.
    def all_child_roles(max_depth: 10)
      return [] if max_depth <= 0

      direct_children = roles.all
      nested_children = direct_children.flat_map do |child|
        child.all_child_roles(max_depth: max_depth - 1)
      end

      (direct_children + nested_children).uniq { |r| r.id }
    end

    # Get the count of direct users in this role.
    # @return [Integer] number of direct users.
    def users_count
      users.query.count
    end

    # Get the count of direct child roles.
    # @return [Integer] number of direct child roles.
    def child_roles_count
      roles.query.count
    end

    # Get the total count of users including child roles.
    # @return [Integer] total user count in hierarchy.
    def total_users_count
      all_users.count
    end
  end
end
