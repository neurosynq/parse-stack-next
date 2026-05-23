# encoding: UTF-8
# frozen_string_literal: true

module Parse
  # Class-Level Permissions (CLP) for Parse Server classes.
  #
  # CLPs control access to a class at the schema level, determining who can
  # perform operations on the class and which fields are visible to different
  # users/roles.
  #
  # ## Protected Fields Behavior
  #
  # When a user matches multiple patterns (e.g., public "*", "authenticated", and a role),
  # the protected fields are the **intersection** of all matching patterns. This means
  # a field is only hidden if it's protected by ALL patterns that apply to the user.
  #
  # For example:
  # - `*` protects ["owner", "test"]
  # - `role:Admin` protects ["owner"]
  # - A user with Admin role matches both patterns
  # - Result: only "owner" is hidden (intersection), "test" is visible
  #
  # An empty array `[]` for a pattern means "no fields protected" (user sees everything).
  # If any matching pattern has an empty array, the intersection will also be empty.
  #
  # @example Defining CLPs in a model
  #   class Song < Parse::Object
  #     property :title, :string
  #     property :artist, :string
  #     property :internal_notes, :string  # Should be hidden from regular users
  #
  #     # Set class-level permissions
  #     set_clp :find, public: true
  #     set_clp :get, public: true
  #     set_clp :create, public: false, roles: ["Admin", "Editor"]
  #     set_clp :update, public: false, roles: ["Admin", "Editor"]
  #     set_clp :delete, public: false, roles: ["Admin"]
  #
  #     # Protect fields from certain users
  #     protect_fields "*", [:internal_notes, :secret_data]  # Hidden from everyone
  #     protect_fields "role:Admin", []  # Admins can see everything
  #   end
  #
  # @example Using userField for owner-based access
  #   class Document < Parse::Object
  #     property :content, :string
  #     property :secret, :string
  #     belongs_to :owner, as: :user
  #
  #     # Hide secret from everyone
  #     protect_fields "*", [:secret, :owner]
  #     # But owners can see their own document's secret
  #     protect_fields "userField:owner", []
  #   end
  #
  # @example Fetching CLPs from server
  #   clp = Song.fetch_clp
  #   clp.find_allowed?("role:Admin")  # => true
  #   clp.protected_fields_for("*")    # => ["internal_notes", "secret_data"]
  #
  # @see https://docs.parseplatform.org/rest/guide/#class-level-permissions
  class CLP
    # Valid CLP operation keys for permission-based access
    OPERATIONS = %i[find get count create update delete addField].freeze

    # Pointer-permission keys (users in these fields get read/write access)
    POINTER_PERMISSIONS = %i[readUserFields writeUserFields].freeze

    # All valid CLP keys
    ALL_KEYS = (OPERATIONS + POINTER_PERMISSIONS + [:protectedFields]).freeze

    # @return [Hash] the raw CLP hash
    attr_reader :permissions

    # Create a new CLP instance.
    # @param data [Hash] optional initial CLP data from Parse Server
    def initialize(data = nil)
      @permissions = {}
      @protected_fields = {}
      parse_data(data) if data.is_a?(Hash)
    end

    # Parse CLP data from Parse Server format.
    # @param data [Hash] CLP hash from server
    def parse_data(data)
      data.each do |key, value|
        key_sym = key.to_sym
        if key_sym == :protectedFields
          @protected_fields = value.transform_keys(&:to_s)
        elsif OPERATIONS.include?(key_sym)
          @permissions[key_sym] = value.transform_keys(&:to_s)
        elsif POINTER_PERMISSIONS.include?(key_sym)
          # readUserFields and writeUserFields are arrays of field names
          @permissions[key_sym] = Array(value)
        else
          # Store any other keys
          @permissions[key_sym] = value
        end
      end
    end

    # Set pointer-permission fields for read access.
    # Users pointed to by these fields can read the object.
    # @param fields [Array<String, Symbol>] pointer field names
    # @return [self]
    # @example
    #   clp.set_read_user_fields(:owner, :collaborators)
    def set_read_user_fields(*fields)
      @permissions[:readUserFields] = fields.flatten.map(&:to_s)
      self
    end

    # Set pointer-permission fields for write access.
    # Users pointed to by these fields can write to the object.
    # @param fields [Array<String, Symbol>] pointer field names
    # @return [self]
    # @example
    #   clp.set_write_user_fields(:owner)
    def set_write_user_fields(*fields)
      @permissions[:writeUserFields] = fields.flatten.map(&:to_s)
      self
    end

    # Get the read user fields.
    # @return [Array<String>] pointer field names for read access
    def read_user_fields
      @permissions[:readUserFields] || []
    end

    # Get the write user fields.
    # @return [Array<String>] pointer field names for write access
    def write_user_fields
      @permissions[:writeUserFields] || []
    end

    # Set permissions for a specific operation.
    # @param operation [Symbol] one of :find, :get, :count, :create, :update, :delete, :addField
    # @param public_access [Boolean, nil] whether public access is allowed
    # @param roles [Array<String>] role names that have access
    # @param users [Array<String>] user objectIds that have access
    # @param pointer_fields [Array<String>] pointer field names for userField access
    # @param requires_authentication [Boolean] whether authentication is required
    # @return [self]
    def set_permission(operation, public_access: nil, roles: [], users: [], pointer_fields: [], requires_authentication: false)
      operation = operation.to_sym
      raise ArgumentError, "Invalid operation: #{operation}" unless OPERATIONS.include?(operation)

      perm = {}

      # Handle public access
      # Note: Parse Server only accepts 'true' values for CLP permissions.
      # Setting public: false means "don't grant public access" which is
      # achieved by simply not including the "*" key (absence = no access).
      perm["*"] = true if public_access == true

      # Handle requiresAuthentication
      perm["requiresAuthentication"] = true if requires_authentication

      # Handle roles
      Array(roles).each do |role|
        role_key = role.start_with?("role:") ? role : "role:#{role}"
        perm[role_key] = true
      end

      # Handle users
      Array(users).each do |user_id|
        perm[user_id] = true
      end

      # Handle pointer fields (userField:fieldName pattern)
      Array(pointer_fields).each do |field|
        field_key = field.start_with?("pointerFields") ? field : "pointerFields"
        perm[field_key] ||= []
        perm[field_key] << field unless field.start_with?("pointerFields")
      end

      @permissions[operation] = perm
      self
    end

    # Set protected fields for a specific user/role pattern.
    # @param pattern [String] the pattern ("*", "role:RoleName", "userField:fieldName", or user objectId)
    # @param fields [Array<String, Symbol>] field names to protect (hide) from this pattern
    # @return [self]
    # @example
    #   clp.set_protected_fields("*", [:email, :phone])  # Hide from everyone
    #   clp.set_protected_fields("role:Admin", [])       # Admins see everything
    #   clp.set_protected_fields("userField:owner", [])  # Owners see everything
    def set_protected_fields(pattern, fields)
      pattern = "*" if pattern.to_sym == :public rescue pattern
      @protected_fields[pattern.to_s] = Array(fields).map(&:to_s)
      self
    end

    # Get protected fields for a specific pattern.
    # @param pattern [String] the pattern to look up
    # @return [Array<String>] the protected field names
    def protected_fields_for(pattern)
      @protected_fields[pattern.to_s] || []
    end

    # Get all protected fields configuration.
    # @return [Hash] pattern => [fields] mapping (deep copy)
    def protected_fields
      @protected_fields.transform_values(&:dup)
    end

    # Check if a specific pattern has access to an operation.
    # @param operation [Symbol] the operation to check
    # @param pattern [String] the pattern ("*", "role:RoleName", user objectId)
    # @return [Boolean]
    def allowed?(operation, pattern)
      perm = @permissions[operation.to_sym]
      return false unless perm

      # Check direct access
      return true if perm[pattern.to_s] == true
      return true if perm["*"] == true

      false
    end

    # Check if public access is allowed for an operation.
    # @param operation [Symbol] the operation to check
    # @return [Boolean]
    def public_access?(operation)
      allowed?(operation, "*")
    end

    # Check if a role has access to an operation.
    # @param operation [Symbol] the operation to check
    # @param role_name [String] the role name (with or without "role:" prefix)
    # @return [Boolean]
    def role_allowed?(operation, role_name)
      role_key = role_name.start_with?("role:") ? role_name : "role:#{role_name}"
      allowed?(operation, role_key)
    end

    # Convenience methods for checking specific operations
    %i[find get count create update delete addField].each do |op|
      define_method(:"#{op}_allowed?") do |pattern = "*"|
        allowed?(op, pattern)
      end
    end

    # Check if authentication is required for an operation.
    # @param operation [Symbol] the operation to check
    # @return [Boolean]
    def requires_authentication?(operation)
      perm = @permissions[operation.to_sym]
      return false unless perm
      perm["requiresAuthentication"] == true
    end

    # Filter fields from a hash based on protected fields for a user/role.
    # This is the core method for filtering webhook responses.
    #
    # Uses **intersection** logic: when a user matches multiple patterns,
    # only fields that are protected by ALL matching patterns are hidden.
    # This matches Parse Server's behavior.
    #
    # @param data [Hash] the data hash to filter
    # @param user [Parse::User, String, nil] the user making the request (or user ID)
    # @param roles [Array<String>] role names the user belongs to
    # @param authenticated [Boolean] whether the user is authenticated (affects "authenticated" pattern)
    # @return [Hash] filtered data with protected fields removed
    #
    # @example Filtering data for a regular user
    #   filtered = clp.filter_fields(song_data, user: current_user, roles: ["Member"])
    #
    # @example Filtering data in a webhook
    #   # In your webhook handler:
    #   clp = Song.fetch_clp
    #   filtered_data = clp.filter_fields(
    #     response_data,
    #     user: request_user,
    #     roles: user_roles
    #   )
    #
    # @example Filtering with authentication check
    #   # Authenticated users may have different visibility
    #   clp.filter_fields(data, user: user, roles: roles, authenticated: true)
    def filter_fields(data, user: nil, roles: [], authenticated: nil)
      return data if data.nil?
      return data.map { |item| filter_fields(item, user: user, roles: roles, authenticated: authenticated) } if data.is_a?(Array)
      return data unless data.is_a?(Hash)

      # Auto-detect authentication if not specified
      authenticated = user.present? if authenticated.nil?

      # Build list of patterns that apply to this user/context
      applicable_patterns = build_applicable_patterns(user, roles, authenticated, data)

      # Determine which fields to hide using intersection logic
      fields_to_hide = determine_fields_to_hide(applicable_patterns)

      # Return filtered data
      data.reject { |key, _| fields_to_hide.include?(key.to_s) }
    end

    # The default permission to use for operations not explicitly set.
    # When set, `as_json` will include this for all undefined operations.
    # @return [Hash, nil] the default permission hash (e.g., { "*" => true })
    attr_accessor :default_permission

    # Default public permission used as fallback when include_defaults is true
    # but no explicit default_permission has been set.
    DEFAULT_PUBLIC_PERMISSION = { "*" => true }.freeze

    # Convert to Parse Server CLP format.
    #
    # IMPORTANT: Parse Server interprets missing operations as {} (no access).
    # If you have protectedFields but no operations defined, the class becomes
    # effectively master-key-only. Use `set_default_permission` or `include_defaults`
    # to ensure all operations are included.
    #
    # @param include_defaults [Boolean] whether to include default permissions
    #   for operations that haven't been explicitly set. When true, uses
    #   @default_permission if set, otherwise falls back to public access.
    # @return [Hash] the CLP hash suitable for schema updates
    def as_json(include_defaults: nil)
      result = {}

      # Determine if we should include defaults
      # Auto-enable if any CLP settings exist and no explicit choice made
      should_include_defaults = if include_defaults.nil?
        present? && @default_permission
      else
        include_defaults
      end

      # Determine the default permission to use
      # Use explicit default_permission if set, otherwise fall back to public
      effective_default = @default_permission || DEFAULT_PUBLIC_PERMISSION

      # Add operation permissions
      OPERATIONS.each do |op|
        if @permissions[op]
          result[op.to_s] = @permissions[op]
        elsif should_include_defaults
          result[op.to_s] = effective_default.dup
        end
      end

      # Add pointer permissions (readUserFields, writeUserFields)
      POINTER_PERMISSIONS.each do |perm|
        result[perm.to_s] = @permissions[perm] if @permissions[perm]&.any?
      end

      # Add protected fields
      result["protectedFields"] = @protected_fields unless @protected_fields.empty?

      result
    end

    # Set the default permission for operations not explicitly configured.
    # This ensures that when CLPs are pushed to Parse Server, all operations
    # have explicit permissions (avoiding the implicit {} = no access behavior).
    #
    # @param public_access [Boolean] whether public access is allowed
    # @param requires_authentication [Boolean] whether authentication is required
    # @param roles [Array<String>] role names that have access
    # @return [self]
    # @example
    #   clp.set_default_permission(public_access: true)  # Default to public
    #   clp.set_default_permission(requires_authentication: true)  # Default to auth required
    def set_default_permission(public_access: nil, requires_authentication: false, roles: [])
      perm = {}
      perm["*"] = true if public_access == true
      perm["requiresAuthentication"] = true if requires_authentication
      Array(roles).each { |role| perm["role:#{role}"] = true }
      @default_permission = perm.empty? ? nil : perm
      self
    end

    alias_method :to_h, :as_json

    # Check if there are any CLP settings.
    # @return [Boolean]
    def present?
      @permissions.any? || @protected_fields.any?
    end

    # Check if this CLP is empty.
    # @return [Boolean]
    def empty?
      !present?
    end

    # Merge another CLP into this one (non-destructive).
    # @param other [CLP, Hash] the CLP to merge
    # @return [CLP] a new merged CLP
    def merge(other)
      other_data = other.is_a?(CLP) ? other.as_json : other
      new_clp = CLP.new(as_json)
      new_clp.parse_data(other_data)
      new_clp
    end

    # Merge another CLP into this one (destructive).
    # @param other [CLP, Hash] the CLP to merge
    # @return [self]
    def merge!(other)
      other_data = other.is_a?(CLP) ? other.as_json : other
      parse_data(other_data)
      self
    end

    # Create a deep copy of this CLP.
    # @return [CLP]
    def dup
      CLP.new(as_json)
    end

    # Equality check.
    # @param other [CLP, Hash] the other CLP to compare
    # @return [Boolean]
    def ==(other)
      return false unless other.is_a?(CLP) || other.is_a?(Hash)
      as_json == (other.is_a?(CLP) ? other.as_json : other)
    end

    def inspect
      "#<Parse::CLP #{as_json.inspect}>"
    end

    private

    # Build list of patterns that apply to a given user context.
    # All matching patterns will be used for intersection logic.
    #
    # @param user [Parse::User, String, nil] the user or user ID
    # @param roles [Array<String>] role names
    # @param authenticated [Boolean] whether user is authenticated
    # @param data [Hash] the data being filtered (for userField checks)
    # @return [Array<String>] all applicable patterns
    def build_applicable_patterns(user, roles, authenticated, data)
      patterns = []
      user_id = extract_user_id(user)

      # Check userField patterns (owner-based access)
      @protected_fields.keys.each do |pattern|
        next unless pattern.start_with?("userField:")

        field_name = pattern.sub("userField:", "")
        next unless data.key?(field_name) || data.key?(field_name.to_sym)

        # Get the field value (could be string key or symbol key)
        field_value = data[field_name] || data[field_name.to_sym]

        if user_id && user_matches_field?(user_id, field_value)
          patterns << pattern
        end
      end

      # Add role patterns for all roles the user belongs to
      Array(roles).each do |role|
        role_pattern = role.start_with?("role:") ? role : "role:#{role}"
        patterns << role_pattern if @protected_fields.key?(role_pattern)
      end

      # Add user-specific pattern if configured
      if user_id && @protected_fields.key?(user_id)
        patterns << user_id
      end

      # Add "authenticated" pattern if user is authenticated and pattern exists
      if authenticated && @protected_fields.key?("authenticated")
        patterns << "authenticated"
      end

      # Public pattern "*" always applies (for everyone)
      patterns << "*" if @protected_fields.key?("*")

      patterns
    end

    # Extract user ID from various user representations.
    # @param user [Parse::User, String, Hash, nil] user object, ID, or pointer hash
    # @return [String, nil] the user ID or nil
    def extract_user_id(user)
      return nil if user.nil?
      return user if user.is_a?(String)
      return user["objectId"] if user.is_a?(Hash) && user["objectId"]
      return user[:objectId] if user.is_a?(Hash) && user[:objectId]
      return user.id if user.respond_to?(:id)
      nil
    end

    # Check if a user ID matches a field value (pointer or array of pointers).
    # @param user_id [String] the user ID to check
    # @param field_value [Hash, Array, String, nil] the field value
    # @return [Boolean] true if the user matches
    def user_matches_field?(user_id, field_value)
      return false if field_value.nil? || user_id.nil?

      # Handle array of pointers (e.g., owners: [user1, user2])
      if field_value.is_a?(Array)
        return field_value.any? { |item| user_matches_field?(user_id, item) }
      end

      # Handle pointer hash (e.g., owner: { __type: "Pointer", objectId: "xxx" })
      if field_value.is_a?(Hash)
        return field_value["objectId"] == user_id || field_value[:objectId] == user_id
      end

      # Handle direct ID string
      field_value.to_s == user_id
    end

    # Determine which fields should be hidden based on applicable patterns.
    #
    # Uses **intersection** logic: a field is hidden only if it's protected
    # by ALL matching patterns. This matches Parse Server behavior.
    #
    # An empty array `[]` for any matching pattern means "no fields protected"
    # for that pattern, which clears protection (intersection with empty = empty).
    #
    # @param patterns [Array<String>] all applicable patterns
    # @return [Set<String>] field names to hide
    def determine_fields_to_hide(patterns)
      # If no patterns match, no fields are hidden
      return Set.new if patterns.empty?

      # Get protected fields for each matching pattern
      field_sets = patterns.map do |pattern|
        fields = @protected_fields[pattern]
        # Convert to Set for intersection operations
        # Empty array means "no protection" -> empty set
        fields.nil? ? nil : Set.new(fields)
      end.compact

      # If any pattern has no configuration, ignore it
      return Set.new if field_sets.empty?

      # If any pattern explicitly allows all fields (empty array),
      # then the intersection is empty (no fields hidden)
      return Set.new if field_sets.any?(&:empty?)

      # Intersect all field sets - only fields protected by ALL patterns are hidden
      field_sets.reduce { |result, fields| result & fields }
    end
  end
end
