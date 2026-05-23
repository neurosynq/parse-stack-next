# encoding: UTF-8
# frozen_string_literal: true

module Parse

  # This class allows you to define custom data types for your model fields. You
  # can define a subclass that implements the {DataType.typecast} method to
  # convert to and from a value for serialization. The {Parse::ACL} class is
  # implemented in this fashion.
  class DataType
    include ::ActiveModel::Model
    include ::ActiveModel::Serializers::JSON

    # @return [Hash] the set of attributes for this data type.
    def attributes
      {}
    end

    # Transform an incoming value to another. The default implementation does
    # returns the original value. This method should return an instance of a
    # DataType subclass.
    # @param value [Object] the input value to be typecasted.
    # @param opts [Hash] a set of options to be used when typecasting.
    # @return [Object]
    def self.typecast(value, **opts)
      value
    end

    # Serialize this DataType into an JSON object hash format to be saved to Parse.
    # The default implementation returns an empty hash.
    # @return [Hash]
    def as_json(*args)
      {}.as_json
    end
  end

  # An ACL represents the dirty-trackable Parse Permissions object used for
  # each record. In Parse, it is composed a hash-like object that represent
  # {Parse::User} objectIds and/or a set of {Parse::Role} names. For each entity
  # (ex. User/Role/Public), you can define read/write privileges on a particular
  # record through a {Parse::ACL::Permission} instance.
  #
  # If you want to give privileges for an action (ex. read/write),
  # you set that particular permission it to true. If you want to deny a
  # permission, then you set it to false. Any denied permissions will not be
  # part of the final hash structure that is sent to parse, as omission of a permission
  # means denial.
  #
  # An ACL is represented by a JSON object with the keys being Parse::User object
  # ids or the special key of "*", which indicates the public access permissions.
  # The value of each key in the hash is a {Parse::ACL::Permission} object which
  # defines the boolean permission state for read and write.
  # The example below illustrates a Parse ACL JSON object where there is a *public*
  # read permission, but public write is prevented. In addition, the user with
  # id "*3KmCvT7Zsb*" is allowed to both read and write this record, and the "*Admins*"
  # role is also allowed write access.
  #
  #  {
  #    "*": { "read": true },
  #    "3KmCvT7Zsb": {  "read": true, "write": true },
  #    "role:Admins": { "write": true }
  #  }
  #
  # All Parse::Object subclasses have an acl property by default. With this
  # property, you can apply and delete permissions for this particular Parse
  # object record.
  #  user = Parse::User.first
  #  artist = Artist.first
  #
  #  artist.acl # "*": { "read": true, "write": true }
  #
  #  # apply public read, but no public write
  #  artist.acl.everyone true, false
  #
  #
  #  # allow user to have read and write access
  #  artist.acl.apply user.id, true, true
  #
  #  # remove all permissions for this user id
  #  artist.acl.delete user.id
  #
  #  # allow the 'Admins' role read and write
  #  artist.acl.apply_role "Admins", true, true
  #
  #  # remove write from all attached privileges
  #  artist.acl.no_write!
  #
  #  # remove all attached privileges
  #  artist.acl.master_key_only!
  #
  #  artist.save
  #
  # You may also set default ACLs for your subclasses by using {Parse::Object.set_default_acl}.
  # These will be get applied for newly created instances. All subclasses have
  # public read and write enabled by default.
  #
  #  class AdminData < Parse::Object
  #
  #    # Disable public read and write
  #    set_default_acl :public, read: true, write: false
  #
  #    # Allow Admin roles to read/write
  #    set_default_acl 'Admin', role: true, read: true, write: true
  #
  #  end
  #
  #  data = AdminData.new
  #  data.acl # => ACL({"role:Admin"=>{"read"=>true, "write"=>true}})
  #
  # For more information about Parse record ACLs, see the documentation on
  # {http://docs.parseplatform.org/rest/guide/#security Security}.
  class ACL < DataType

    # @!attribute delegate
    #  The instance object to be notified of changes. The delegate must support
    #  receiving a {Parse::Object#acl_will_change!} method.
    # @return [Parse::Object]
    attr_accessor :permissions, :delegate

    # @!attribute [rw] permissions
    # Contains a hash structure of permissions, with keys mapping to either Public '*',
    # a role name or an objectId for a user and values of type {ACL::Permission}. If you
    # modify this attribute directly, you should call {Parse::Object#acl_will_change!}
    # on the target object in order for dirty tracking to register changes.
    # @example
    #  object.acl.permissions
    #  # => { "*": { "read": true }, "3KmCvT7Zsb": {  "read": true, "write": true } }
    # @return [Hash] a hash of permissions.
    def permissions
      @permissions ||= {}
    end

    # The key field value for public permissions.
    PUBLIC = "*".freeze

    # Create a new ACL with default Public read/write permissions and any
    # overrides from the input hash format.
    # @param acls [Hash] a Parse-compatible hash acl format.
    # @param owner [Parse::Object] a delegate to receive notifications of acl changes.
    #  This delegate must support receiving `acl_will_change!` method.
    def initialize(acls = nil, owner: nil)
      acls = acls.as_json if acls.is_a?(ACL)
      self.attributes = acls if acls.is_a?(Hash)
      @delegate = owner
    end

    # Create a new ACL with default Public read/write permissions and any
    # overrides from the input hash format.
    # @param read [Boolean] the read permissions for PUBLIC (default: true)
    # @param write [Boolean] the write permissions for PUBLIC (default: true)
    # @version 1.7.0
    def self.everyone(read = true, write = true)
      acl = Parse::ACL.new
      acl.everyone(read, write)
      acl
    end

    # Create a new ACL::Permission instance with the supplied read and write values.
    # @param read [Boolean] the read permission value
    # @param write [Boolean] the write permission value.
    # @return [ACL::Permission]
    # @see ACL::Permission
    def self.permission(read, write = nil)
      ACL::Permission.new(read, write)
    end
    # Determines whether two ACLs or a Parse-ACL hash is equivalent to this object.
    # @example
    #  acl = Parse::ACL.new
    #  # create a public read-only ACL
    #  acl.apply :public, true, false
    #  acl.as_json # => {'*' => { "read" => true }}
    #
    #  create a second instance with similar privileges
    #  acl2 = Parse::ACL.everyone(true, false)
    #  acl2.as_json # => {'*' => { "read" => true }}
    #
    #  acl == acl2 # => true
    #  acl == {'*' => { "read" => true }} # hash ok too
    #
    #  acl2.apply_role 'Admin', true, true # rw for Admins
    #  acl == acl2 # => false
    #
    # @return [Boolean] whether two ACLs have the same set of privileges.
    def ==(other_acl)
      return false unless other_acl.is_a?(self.class) || other_acl.is_a?(Hash)
      as_json == other_acl.as_json
    end

    # Set the public read and write permissions.
    # @param read [Boolean] the read permission state.
    # @param write [Boolean] the write permission state.
    # @return [Hash] the current public permissions.
    def everyone(read, write)
      apply(PUBLIC, read, write)
      permissions[PUBLIC]
    end

    alias_method :world, :everyone

    # Calls `acl_will_change!` on the delegate when the permissions have changed.
    # All {Parse::Object} subclasses implement this method.
    def will_change!
      @delegate.acl_will_change! if @delegate.respond_to?(:acl_will_change!)
    end

    # Removes a permission for an objectId or user.
    # @overload delete(object)
    #  @param object [Parse::User] the user to revoke permissions.
    # @overload delete(id)
    #  @param id [String] the objectId to revoke permissions.
    def delete(id)
      id = id.id if id.is_a?(Parse::Pointer)
      if id.present? && permissions.has_key?(id)
        will_change!
        permissions.delete(id)
      end
    end

    # Apply a new permission with a given objectId, tag or :public.
    # @overload apply(user, read = nil, write = nil)
    #  Set the read and write permissions for this user on this ACL.
    #  @param user [Parse::User] the user object.
    #  @param read [Boolean] the read permission.
    #  @param write [Boolean] the write permission.
    # @overload apply(role, read = nil, write = nil)
    #  Set the read and write permissions for this role object on this ACL.
    #  @param role [Parse::Role] the role object.
    #  @param read [Boolean] the read permission.
    #  @param write [Boolean] the write permission.
    # @overload apply(id, read = nil, write = nil)
    #  Set the read and write permissions for this objectId on this ACL.
    #  @param id [String|:public] the objectId for a {Parse::User}. If :public is passed,
    #      then the {Parse::ACL::PUBLIC} read and write permissions will be modified.
    #  @param read [Boolean] the read permission.
    #  @param write [Boolean] the write permission.
    # @return [Hash] the current set of permissions.
    # @see #apply_role
    def apply(id, read = nil, write = nil)
      return apply_role(id, read, write) if id.is_a?(Parse::Role)
      id = id.id if id.is_a?(Parse::Pointer)
      unless id.present?
        raise ArgumentError, "Invalid argument applying ACLs: must be either objectId, role or :public"
      end
      id = PUBLIC if id.to_sym == :public
      # create a new Permissions
      permission = ACL.permission(read, write)
      # if the input is already an Permission object, then set it directly
      permission = read if read.is_a?(Parse::ACL::Permission)
      if permission.is_a?(ACL::Permission)
        if permissions[id.to_s] != permission
          will_change! # dirty track
          permissions[id.to_s] = permission
        end
      end

      permissions
    end; 
    alias_method :add, :apply

    # Apply a {Parse::Role} to this ACL.
    # @overload apply_role(role, read = nil, write = nil)
    #  @param role [Parse::Role] the role object.
    #  @param read [Boolean] the read permission.
    #  @param write [Boolean] the write permission.
    # @overload apply_role(role_name, read = nil, write = nil)
    #  @param role_name [String] the name of the role.
    #  @param read [Boolean] the read permission.
    #  @param write [Boolean] the write permission.
    def apply_role(name, read = nil, write = nil)
      name = name.name if name.is_a?(Parse::Role)
      apply("role:#{name}", read, write)
    end; 
    alias_method :add_role, :apply_role

    # Used for object conversion when formatting the input/output value in
    # Parse::Object properties
    # @param value [Hash] a Parse ACL hash to construct a Parse::ACL instance.
    # @param delegate [Object] any object that would need to be notified of changes.
    # @return [ACL]
    # @see Parse::DataType
    def self.typecast(value, delegate = nil)
      ACL.new(value, owner: delegate)
    end

    # Used for JSON serialization. Only if an attribute is non-nil, do we allow it
    # in the Permissions hash, since omission means denial of priviledge. If the
    # permission value has neither read or write, then the entire record has been denied
    # all privileges
    # @return [Hash]
    def attributes
      permissions.select { |k, v| v.present? }.as_json
    end

    # @!visibility private
    def attributes=(h)
      return unless h.is_a?(Hash)
      will_change!
      @permissions ||= {}
      h.each do |k, v|
        apply(k, v)
      end
    end

    # @!visibility private
    def inspect
      "ACL(#{as_json.inspect})"
    end

    # @return [Hash]
    def as_json(*args)
      permissions.select { |k, v| v.present? }.as_json
    end

    # @return [Boolean] true if there are any permissions.
    def present?
      permissions.values.any? { |v| v.present? }
    end

    # Removes all ACLs, which only allows requests using the Parse Server master key
    # to query and modify the object.
    # @example
    #  object.acl
    #  #    { "*":          { "read" : true },
    #  #      "3KmCvT7Zsb": { "read" : true, "write": true },
    #  #      "role:Admins": { "write": true }
    #  #     }
    #  object.acl.master_key_only!
    #  # Outcome:
    #  #    { }
    # @version 1.7.2
    # @return [Hash] The cleared permissions hash
    def master_key_only!
      will_change!
      @permissions = {}
    end; 
    alias_method :clear!, :master_key_only!

    # Grants read permission on all existing users and roles attached to this object.
    # @example
    #  object.acl
    #  #    { "*":          { "read" : true },
    #  #      "3KmCvT7Zsb": { "read" : true, "write": true },
    #  #      "role:Admins": { "write": true }
    #  #     }
    #  object.acl.all_read!
    #  # Outcome:
    #  #    { "*":          { "read" : true },
    #  #      "3KmCvT7Zsb": { "read" : true, "write": true },
    #  #      "role:Admins": { "read" : true, "write": true}
    #  #     }
    # @version 1.7.2
    # @return [Array] list of ACL keys
    def all_read!
      will_change!
      permissions.keys.each do |perm|
        permissions[perm].read! true
      end
    end

    # Grants write permission on all existing users and roles attached to this object.
    # @example
    #  object.acl
    #  #    { "*":          { "read" : true },
    #  #      "3KmCvT7Zsb": { "read" : true, "write": true },
    #  #      "role:Admins": { "write": true }
    #  #     }
    #  object.acl.all_write!
    #  # Outcome:
    #  #    { "*":          { "read" : true, "write": true },
    #  #      "3KmCvT7Zsb": { "read" : true, "write": true },
    #  #      "role:Admins": { "write": true }
    #  #     }
    # @version 1.7.2
    # @return [Array] list of ACL keys
    def all_write!
      will_change!
      permissions.keys.each do |perm|
        permissions[perm].write! true
      end
    end

    # Denies read permission on all existing users and roles attached to this object.
    # @example
    #  object.acl
    #  #    { "*":          { "read" : true },
    #  #      "3KmCvT7Zsb": { "read" : true, "write": true },
    #  #      "role:Admins": { "write": true }
    #  #     }
    #  object.acl.no_read!
    #  # Outcome:
    #  #    { "*":          nil,
    #  #      "3KmCvT7Zsb": { "write": true },
    #  #      "role:Admins": { "write": true }
    #  #     }
    # @version 1.7.2
    # @return [Array] list of ACL keys
    def no_read!
      will_change!
      permissions.keys.each do |perm|
        permissions[perm].read! false
      end
    end

    # Denies write permission on all existing users and roles attached to this object.
    # @example
    #  object.acl
    #  #    { "*":          { "read" : true },
    #  #      "3KmCvT7Zsb": { "read" : true, "write": true },
    #  #      "role:Admins": { "write": true }
    #  #     }
    #  object.acl.no_write!
    #  # Outcome:
    #  #    { "*":          { "read" : true },
    #  #      "3KmCvT7Zsb": { "read" : true },
    #  #      "role:Admins": nil
    #  #     }
    # @version 1.7.2
    # @return [Array] list of ACL keys
    def no_write!
      will_change!
      permissions.keys.each do |perm|
        permissions[perm].write! false
      end
    end

    # Returns an array of all user IDs and role names that have read access to this object.
    # @return [Array<String>] list of user IDs and role names (e.g., ["*", "user123", "role:Admin"])
    def readable_by
      permissions.select { |k, v| v.read }.keys
    end

    # Returns an array of all user IDs and role names that have write access to this object.
    # @return [Array<String>] list of user IDs and role names (e.g., ["*", "user123", "role:Admin"])
    def writeable_by
      permissions.select { |k, v| v.write }.keys
    end
    alias_method :writable_by, :writeable_by

    # Checks if a specific user or role (or any in an array) has read access to this object.
    # When passed an array of strings, returns true if ANY of the users/roles have read access (OR logic).
    # When passed a Parse::User object or pointer, automatically fetches and checks the user's roles as well.
    # @param user_or_role [String, Parse::User, Parse::Pointer, Array<String>] the user ID, role name, user object, user pointer, or array of user IDs/role names
    # @return [Boolean] true if the user/role (or any in the array) has read access
    # @example
    #   acl.readable_by?("user123")                    # Check single user ID
    #   acl.readable_by?("Admin")                      # Check single role name
    #   acl.readable_by?(user_object)                  # Check user + their roles
    #   acl.readable_by?(user_pointer)                 # Check user pointer + their roles
    #   acl.readable_by?(["user123", "Admin"])         # Check array (OR logic)
    def readable_by?(user_or_role)
      # Handle arrays - check if ANY item in the array has read access (OR logic)
      if user_or_role.is_a?(Array)
        # For arrays, just check each string value directly (no User object expansion)
        return user_or_role.any? do |item|
          key = normalize_permission_key(item)
          key && permissions[key]&.read == true
        end
      end

      # Handle Parse::Pointer to User - expand to include user ID and roles
      if user_or_role.is_a?(Parse::Pointer) || (user_or_role.respond_to?(:parse_class) && user_or_role.respond_to?(:id))
        # Check if it's a pointer to a User
        if user_or_role.respond_to?(:parse_class) && (user_or_role.parse_class == "User" || user_or_role.parse_class == "_User")
          permissions_to_check = []

          # Add the user ID from the pointer
          user_id = user_or_role.respond_to?(:id) ? user_or_role.id : nil
          permissions_to_check << user_id if user_id.present?

          # Query roles directly using the user pointer (no need to fetch the full user)
          begin
            if user_id.present? && defined?(Parse::Role)
              user_roles = Parse::Role.all(users: user_or_role)
              user_roles.each do |role|
                permissions_to_check << "role:#{role.name}" if role.respond_to?(:name) && role.name.present?
              end
            end
          rescue => e
            # If role fetching fails, continue with just the user ID
          end

          # Check if any of the user's permissions (user ID or roles) have read access
          return readable_by?(permissions_to_check) if permissions_to_check.any?
          return false
        end
      end

      # If it's a User object, expand it to include the user ID and all their roles
      if user_or_role.is_a?(Parse::User) || (user_or_role.respond_to?(:is_a?) && user_or_role.is_a?(Parse::User))
        permissions_to_check = []

        # Add the user ID
        permissions_to_check << user_or_role.id if user_or_role.respond_to?(:id) && user_or_role.id.present?

        # Fetch and add all the user's roles
        begin
          if user_or_role.respond_to?(:id) && user_or_role.id.present? && defined?(Parse::Role)
            user_roles = Parse::Role.all(users: user_or_role)
            user_roles.each do |role|
              permissions_to_check << "role:#{role.name}" if role.respond_to?(:name) && role.name.present?
            end
          end
        rescue => e
          # If role fetching fails, continue with just the user ID
        end

        # Check if any of the user's permissions (user ID or roles) have read access
        # Use array checking logic (OR)
        return readable_by?(permissions_to_check) if permissions_to_check.any?
        return false
      end

      # Single string value - check directly
      key = normalize_permission_key(user_or_role)
      return false unless key
      permissions[key]&.read == true
    end

    # Checks if a specific user or role (or any in an array) has write access to this object.
    # When passed an array of strings, returns true if ANY of the users/roles have write access (OR logic).
    # When passed a Parse::User object or pointer, automatically fetches and checks the user's roles as well.
    # @param user_or_role [String, Parse::User, Parse::Pointer, Array<String>] the user ID, role name, user object, user pointer, or array of user IDs/role names
    # @return [Boolean] true if the user/role (or any in the array) has write access
    # @example
    #   acl.writeable_by?("user123")                   # Check single user ID
    #   acl.writeable_by?("Admin")                     # Check single role name
    #   acl.writeable_by?(user_object)                 # Check user + their roles
    #   acl.writeable_by?(user_pointer)                # Check user pointer + their roles
    #   acl.writeable_by?(["user123", "Admin"])        # Check array (OR logic)
    def writeable_by?(user_or_role)
      # Handle arrays - check if ANY item in the array has write access (OR logic)
      if user_or_role.is_a?(Array)
        # For arrays, just check each string value directly (no User object expansion)
        return user_or_role.any? do |item|
          key = normalize_permission_key(item)
          key && permissions[key]&.write == true
        end
      end

      # Handle Parse::Pointer to User - expand to include user ID and roles
      if user_or_role.is_a?(Parse::Pointer) || (user_or_role.respond_to?(:parse_class) && user_or_role.respond_to?(:id))
        # Check if it's a pointer to a User
        if user_or_role.respond_to?(:parse_class) && (user_or_role.parse_class == "User" || user_or_role.parse_class == "_User")
          permissions_to_check = []

          # Add the user ID from the pointer
          user_id = user_or_role.respond_to?(:id) ? user_or_role.id : nil
          permissions_to_check << user_id if user_id.present?

          # Query roles directly using the user pointer (no need to fetch the full user)
          begin
            if user_id.present? && defined?(Parse::Role)
              user_roles = Parse::Role.all(users: user_or_role)
              user_roles.each do |role|
                permissions_to_check << "role:#{role.name}" if role.respond_to?(:name) && role.name.present?
              end
            end
          rescue => e
            # If role fetching fails, continue with just the user ID
          end

          # Check if any of the user's permissions (user ID or roles) have write access
          return writeable_by?(permissions_to_check) if permissions_to_check.any?
          return false
        end
      end

      # If it's a User object, expand it to include the user ID and all their roles
      if user_or_role.is_a?(Parse::User) || (user_or_role.respond_to?(:is_a?) && user_or_role.is_a?(Parse::User))
        permissions_to_check = []

        # Add the user ID
        permissions_to_check << user_or_role.id if user_or_role.respond_to?(:id) && user_or_role.id.present?

        # Fetch and add all the user's roles
        begin
          if user_or_role.respond_to?(:id) && user_or_role.id.present? && defined?(Parse::Role)
            user_roles = Parse::Role.all(users: user_or_role)
            user_roles.each do |role|
              permissions_to_check << "role:#{role.name}" if role.respond_to?(:name) && role.name.present?
            end
          end
        rescue => e
          # If role fetching fails, continue with just the user ID
        end

        # Check if any of the user's permissions (user ID or roles) have write access
        # Use array checking logic (OR)
        return writeable_by?(permissions_to_check) if permissions_to_check.any?
        return false
      end

      # Single string value - check directly
      key = normalize_permission_key(user_or_role)
      return false unless key
      permissions[key]&.write == true
    end
    alias_method :writable_by?, :writeable_by?
    alias_method :can_read?, :readable_by?
    alias_method :can_write?, :writeable_by?

    # Checks if the object has public read access.
    # @return [Boolean] true if public can read this object
    def public_read?
      permissions[PUBLIC]&.read == true
    end

    # Checks if the object has public write access.
    # @return [Boolean] true if public can write to this object
    def public_write?
      permissions[PUBLIC]&.write == true
    end

    # Checks if the object has no read permissions for anyone (master key only).
    # @return [Boolean] true if no one has read access
    def no_read?
      permissions.values.none? { |v| v.read }
    end

    # Checks if the object has no write permissions for anyone (master key only).
    # @return [Boolean] true if no one has write access
    def no_write?
      permissions.values.none? { |v| v.write }
    end

    # Checks if the object is read-only (has read permissions but no write permissions).
    # @return [Boolean] true if object has read access but no write access
    def read_only?
      permissions.values.any? { |v| v.read } && permissions.values.none? { |v| v.write }
    end

    # Checks if the object is write-only (has write permissions but no read permissions).
    # @return [Boolean] true if object has write access but no read access
    def write_only?
      permissions.values.any? { |v| v.write } && permissions.values.none? { |v| v.read }
    end

    # Returns an array of all user IDs and role names that have both read and write access.
    # @return [Array<String>] list of user IDs and role names with full access
    def owners
      permissions.select { |k, v| v.read && v.write }.keys
    end

    # Checks if a specific user or role (or any in an array) has both read and write access to this object.
    # When passed an array of strings, returns true if ANY of the users/roles have both read and write access (OR logic).
    # When passed a Parse::User object or pointer, automatically fetches and checks the user's roles as well.
    # @param user_or_role [String, Parse::User, Parse::Pointer, Array<String>] the user ID, role name, user object, user pointer, or array of user IDs/role names
    # @return [Boolean] true if the user/role (or any in the array) has both read and write access
    # @example
    #   acl.owner?("user123")                          # Check single user ID
    #   acl.owner?("Admin")                            # Check single role name
    #   acl.owner?(user_object)                        # Check user + their roles
    #   acl.owner?(user_pointer)                       # Check user pointer + their roles
    #   acl.owner?(["user123", "Admin"])               # Check array (OR logic)
    def owner?(user_or_role)
      # Handle arrays - check if ANY item in the array is an owner (OR logic)
      if user_or_role.is_a?(Array)
        # For arrays, just check each string value directly (no User object expansion)
        return user_or_role.any? do |item|
          key = normalize_permission_key(item)
          next false unless key
          perm = permissions[key]
          perm&.read == true && perm&.write == true
        end
      end

      # Handle Parse::Pointer to User - expand to include user ID and roles
      if user_or_role.is_a?(Parse::Pointer) || (user_or_role.respond_to?(:parse_class) && user_or_role.respond_to?(:id))
        # Check if it's a pointer to a User
        if user_or_role.respond_to?(:parse_class) && (user_or_role.parse_class == "User" || user_or_role.parse_class == "_User")
          permissions_to_check = []

          # Add the user ID from the pointer
          user_id = user_or_role.respond_to?(:id) ? user_or_role.id : nil
          permissions_to_check << user_id if user_id.present?

          # Query roles directly using the user pointer (no need to fetch the full user)
          begin
            if user_id.present? && defined?(Parse::Role)
              user_roles = Parse::Role.all(users: user_or_role)
              user_roles.each do |role|
                permissions_to_check << "role:#{role.name}" if role.respond_to?(:name) && role.name.present?
              end
            end
          rescue => e
            # If role fetching fails, continue with just the user ID
          end

          # Check if any of the user's permissions (user ID or roles) are owners
          return owner?(permissions_to_check) if permissions_to_check.any?
          return false
        end
      end

      # If it's a User object, expand it to include the user ID and all their roles
      if user_or_role.is_a?(Parse::User) || (user_or_role.respond_to?(:is_a?) && user_or_role.is_a?(Parse::User))
        permissions_to_check = []

        # Add the user ID
        permissions_to_check << user_or_role.id if user_or_role.respond_to?(:id) && user_or_role.id.present?

        # Fetch and add all the user's roles
        begin
          if user_or_role.respond_to?(:id) && user_or_role.id.present? && defined?(Parse::Role)
            user_roles = Parse::Role.all(users: user_or_role)
            user_roles.each do |role|
              permissions_to_check << "role:#{role.name}" if role.respond_to?(:name) && role.name.present?
            end
          end
        rescue => e
          # If role fetching fails, continue with just the user ID
        end

        # Check if any of the user's permissions (user ID or roles) are owners
        # Use array checking logic (OR)
        return owner?(permissions_to_check) if permissions_to_check.any?
        return false
      end

      # Single string value - check directly
      key = normalize_permission_key(user_or_role)
      return false unless key
      perm = permissions[key]
      perm&.read == true && perm&.write == true
    end

    # Checks if the ACL has no permissions (master key only access).
    # @return [Boolean] true if no permissions exist
    def empty?
      permissions.empty? || permissions.values.none? { |v| v.present? }
    end
    alias_method :master_key_only?, :empty?
    alias_method :master_only?, :empty?

    private

    # Normalizes a user or role input to the appropriate permission key format.
    # @param user_or_role [String, Parse::User, Parse::Role] the input to normalize
    # @return [String, nil] the normalized key or nil if invalid
    def normalize_permission_key(user_or_role)
      case user_or_role
      when String
        # Handle role names, user IDs, or public
        if user_or_role == "*" || user_or_role.to_sym == :public
          PUBLIC
        elsif user_or_role.start_with?("role:")
          user_or_role
        else
          # Could be a role name without prefix or a user ID
          # Check if it exists as-is first, then try as role
          if permissions.key?(user_or_role)
            user_or_role
          elsif permissions.key?("role:#{user_or_role}")
            "role:#{user_or_role}"
          else
            user_or_role # Return as-is, might be a user ID
          end
        end
      when Parse::User
        user_or_role.id if user_or_role.respond_to?(:id)
      when Parse::Role
        "role:#{user_or_role.name}" if user_or_role.respond_to?(:name)
      when Parse::Pointer
        user_or_role.id if user_or_role.respond_to?(:id)
      when Symbol
        user_or_role == :public ? PUBLIC : user_or_role.to_s
      else
        nil
      end
    end

    public

    # The Permission class tracks the read and write permissions for a specific
    # ACL entry. The value of an Parse-ACL hash only contains two keys: "read" and "write".
    #
    #  # Example of the ACL format
    #   { "*":          { "read": true },
    #     "3KmCvT7Zsb": { "read": true, "write": true },
    #     "role:Admins": { "write": true }
    #   }
    # This would be managed as:
    #   { "*":          ACL::Permission.new(true),
    #     "3KmCvT7Zsb": ACL::Permission.new(true, true)
    #     "role:Amdins": ACL::Permission.new(false,true)
    #   }
    #
    class Permission
      include ::ActiveModel::Model
      include ::ActiveModel::Serializers::JSON

      # The *read* permission state.
      # @return [Boolean] whether this permission is allowed.
      attr_reader :read

      # The *write* permission state.
      # @return [Boolean] whether this permission is allowed.
      attr_reader :write

      # Create a new permission with the given read and write privileges.
      # @overload new(read = nil, write = nil)
      #  @param read [Boolean] whether reading is allowed.
      #  @param write [Boolean] whether writing is allowed.
      #  @example
      #   ACL::Permission.new(true, false)
      # @overload new(hash)
      #  @param hash [Hash] a key value pair for read/write permissions.
      #  @example
      #   ACL::Permission.new({read: true, write: false})
      #
      def initialize(r_perm = nil, w_perm = nil)
        if r_perm.is_a?(Hash)
          r_perm = r_perm.symbolize_keys
          @read = r_perm[:read].present?
          @write = r_perm[:write].present?
        else
          @read = r_perm.present?
          @write = w_perm.present?
        end
      end

      # @return [Boolean] whether two permission instances have the same permissions.
      def ==(per)
        return false unless per.is_a?(self.class)
        @read == per.read && @write == per.write
      end

      # @return [Hash] A Parse-compatible ACL-hash. Omission or false on a
      #  priviledge means don't include it
      def as_json(*args)
        h = {}
        h[:read] = true if @read
        h[:write] = true if @write
        h.empty? ? nil : h.as_json
      end

      # @return [Hash]
      def attributes
        h = {}
        h.merge!(read: :boolean) if @read
        h.merge!(write: :boolean) if @write
        h
      end

      # @!visibility private
      def inspect
        as_json.inspect
      end

      # @return [Boolean] whether there is at least one permission set to true.
      def present?
        @read.present? || @write.present?
      end

      # Sets the *read* value of the permission. Defaults to true.
      # @note Setting the value in this manner is not dirty tracked.
      # @version 1.7.2
      # @return [void]
      def read!(value = true)
        @read = value
      end

      # Sets the *write* value of the permission. Defaults to true.
      # @note Setting the value in this manner is not dirty tracked.
      # @version 1.7.2
      # @return [void]
      def write!(value = true)
        @write = value
      end

      # Sets the *read* value of the permission to false.
      # @version 1.7.2
      # @return [void]
      def no_read!
        @write = false
      end

      # Sets the *write* value of the permission to false.
      # @version 1.7.2
      # @return [void]
      def no_write!
        @write = false
      end
    end
  end
end
