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
  #   # Create role hierarchy. Parse Server's _Role semantics: when role X
  #   # holds role Y in its `roles` relation, USERS OF Y INHERIT X'S
  #   # PERMISSIONS — not the other way around. So if you want Admins to
  #   # have everything Moderators can do, you must put Admin into the
  #   # Moderator role's `roles` relation:
  #   moderator = Parse::Role.create(name: "Moderator")
  #   moderator.add_child_role(admin)  # Admins inherit Moderator permissions
  #   moderator.save
  #
  #   # Query users in role (including child roles whose users implicitly
  #   # have this role through Parse's inheritance):
  #   all_users = moderator.all_users  # includes Admin's users transitively
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

    # Parse Server requires every _Role row to ship with an ACL (the
    # requirement is hard-coded in SchemaController.requiredColumns and
    # cannot be disabled by config). We default to master-only (ACL = {})
    # so anonymous clients cannot enumerate the role graph or read
    # membership. Parse Server's internal role expansion runs with master
    # context (Auth#getRolesForUser), so ACL evaluation continues to work
    # without a public-read grant. Apps that need broader access should
    # pass `acl:` to find_or_create / assign `role.acl=` explicitly.
    acl_policy :private

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

      # Return the transitive upward closure of role names a user
      # inherits permissions from.
      #
      # Parse Server `_Role` inheritance: when role `X` holds role `Y`
      # in its `roles` relation, users of `Y` inherit `X`'s
      # permissions. So given a user `U`, the permission set is built
      # by:
      #
      #   1. Querying for every role `D` where `U` is a direct member
      #      (`_Role.users` contains `U`).
      #   2. For each direct role `D`, walking upward to every role
      #      `P` that lists `D` in its `roles` relation. Repeat until
      #      no new parents are found.
      #
      # This is the correct primitive for building `_rperm` predicates
      # (e.g., {ACLReadableByConstraint}, {ACLWritableByConstraint},
      # and the Atlas Search ACL `$match` injection). The legacy walk
      # via {#all_child_roles} on the user's direct roles traverses
      # the wrong direction and over-grants — it returns roles whose
      # users include the input user through inheritance, not the
      # roles the input user inherits permissions from.
      #
      # Cycle-safe: a visited-id set guards against pathological
      # `_Role.roles` cycles (e.g. A→B→A).
      #
      # @param user [Parse::User, Parse::Pointer, String, nil] the
      #   user to expand. A `Parse::Pointer` must be on the `_User`
      #   class. A `String` is treated as a `_User` objectId. `nil`
      #   returns an empty set (anonymous).
      # @param max_depth [Integer] maximum BFS depth (default: 10).
      # @param master [Boolean] when `true`, opt in to the mongo-direct
      #   fast path under master-mode (bypasses `_Role` CLP). Use for
      #   admin/analytics code paths that legitimately need a
      #   master-scope view of the role graph.
      # @param as [Parse::User, Parse::Pointer, nil] when supplied,
      #   opt in to the mongo-direct fast path under the caller's
      #   scope (subject to `_Role` CLP). The scope is forwarded
      #   verbatim to {Parse::MongoDB.role_names_for_user}; CLP denial
      #   raises {Parse::CLPScope::Denied}.
      # @return [Set<String>] role names (no `role:` prefix) the user
      #   transitively inherits permissions from, including direct
      #   memberships. Empty set for anonymous or no-membership users.
      # @note When neither `master:` nor `as:` is supplied, the
      #   mongo-direct fast path is **skipped**; the method falls
      #   through to the Parse-Server walk
      #   (`Parse::Role.all(users: user_pointer)`) which goes through
      #   the default Parse::Client. This preserves backward
      #   compatibility for the many SDK-internal call sites that
      #   compose ACL scopes (acl_scope, atlas_search session,
      #   query/constraints) — none of those have a caller scope to
      #   forward. The fast path is opt-in for performance-conscious
      #   callers that can supply explicit authorization.
      # @example
      #   names = Parse::Role.all_for_user(user, master: true)  # admin/analytics
      #   names = Parse::Role.all_for_user(user, as: current_user)  # scope-checked
      def all_for_user(user, max_depth: 10, master: false, as: nil)
        names = Set.new
        return names if user.nil? || max_depth <= 0

        user_pointer = role_lookup_pointer_for(user)
        return names if user_pointer.nil?

        # The fast path is opt-in. When neither `master:` nor `as:` is
        # supplied, skip it entirely — the underlying mongo helper
        # would raise ArgumentError, and we don't want to surprise
        # the many backward-compat call sites (acl_scope.resolve_for_user,
        # atlas_search Session.role_names_for, query/constraints' ACL
        # constraint building, agent default-scope composition) that
        # have no scope to forward.
        if master == true || !as.nil?
          fast_path_result = all_for_user_mongo_fast_path(
            user_pointer.id, max_depth, master: master, as: as,
          )
          if fast_path_result.is_a?(Set)
            ActiveSupport::Notifications.instrument(
              "parse.role.expand",
              direction: :forward, target_id: user_pointer.id,
              depth: max_depth, source: :mongo_direct,
              result_count: fast_path_result.size,
            )
            return fast_path_result
          end
        end

        begin
          direct_roles = Parse::Role.all(users: user_pointer)
        rescue
          return names
        end

        result = expand_inheritance_upward(direct_roles, max_depth: max_depth)
        ActiveSupport::Notifications.instrument(
          "parse.role.expand",
          direction: :forward, target_id: user_pointer.id,
          depth: max_depth, source: :parse_server,
          result_count: result.size,
        )
        result
      end

      # @!visibility private
      # Try the mongo-direct fast path for {.all_for_user}. Returns the
      # resolved `Set<String>` on success, or `nil` when the fast path
      # is unavailable (mongo not configured, or a benign availability
      # error). Attack-signal errors (timeouts, denied operators,
      # CLP::Denied, ArgumentError on missing auth) are propagated.
      def all_for_user_mongo_fast_path(user_id, max_depth, master: false, as: nil)
        return nil unless defined?(Parse::MongoDB)
        return nil unless Parse::MongoDB.respond_to?(:role_names_for_user)
        Parse::MongoDB.role_names_for_user(
          user_id, max_depth: max_depth, master: master, as: as,
        )
      rescue StandardError => e
        # Fall back to Parse-Server path on benign availability errors
        # (lost connection mid-query). Propagate everything else —
        # ExecutionTimeout, DeniedOperator, CLPScope::Denied,
        # ArgumentError, and any unrecognized Mongo::Error subclass —
        # so attack signals aren't masked by a silent slow-path retry.
        if defined?(::Mongo::Error::ConnectionFailure) &&
           e.is_a?(::Mongo::Error::ConnectionFailure)
          # Emit a structured event so operators can observe the
          # fast-path-unavailable rate (e.g. analytics-replica
          # connection flapping). The fallback to the Parse-Server
          # walk that follows enforces ACL on its own; this notification
          # exists solely to surface the discrepancy.
          ActiveSupport::Notifications.instrument(
            "parse.role.fast_path_unavailable",
            reason: "connection_failure", direction: :forward,
            target_id: user_id, depth: max_depth,
          )
          nil
        else
          raise
        end
      end

      # Walk upward from a starting frontier of {Parse::Role} objects
      # through the `_Role.roles` inverse relation, collecting every
      # role name reachable. Used by {.all_for_user} (frontier = the
      # user's direct roles) and {Parse::Role#all_parent_role_names}
      # (frontier = the role itself).
      #
      # The starting frontier is INCLUDED in the returned set, because
      # the semantics is "every role name whose presence in `_rperm`
      # grants access" — direct membership counts.
      #
      # @param starting_roles [Array<Parse::Role>] roles to begin the
      #   upward traversal from.
      # @param max_depth [Integer] maximum BFS depth.
      # @return [Set<String>] role names (no `role:` prefix) including
      #   the starting frontier and every transitive parent.
      def expand_inheritance_upward(starting_roles, max_depth: 10)
        names = Set.new
        visited_ids = Set.new
        frontier = []

        Array(starting_roles).each do |role|
          next if role.nil? || role.id.nil?
          next if visited_ids.include?(role.id)
          visited_ids << role.id
          names << role.name if role.respond_to?(:name) && role.name.present?
          frontier << role
        end

        depth = 0
        while frontier.any? && depth < max_depth
          next_frontier = []
          frontier.each do |role|
            next if role.nil? || role.id.nil?
            begin
              parents = Parse::Role.all(roles: role)
            rescue
              next
            end
            parents.each do |parent|
              next if parent.nil? || parent.id.nil?
              next if visited_ids.include?(parent.id)
              visited_ids << parent.id
              names << parent.name if parent.respond_to?(:name) && parent.name.present?
              next_frontier << parent
            end
          end
          frontier = next_frontier
          depth += 1
        end

        names
      end

      private

      # @!visibility private
      # Coerce caller-supplied user argument into a `Parse::Pointer`
      # on `_User` suitable for an inverse-relation query. Returns
      # `nil` when the input cannot be resolved to a `_User` id, in
      # which case {.all_for_user} returns an empty set without
      # issuing a network call.
      def role_lookup_pointer_for(user)
        if user.is_a?(Parse::User)
          return nil unless user.id.present?
          user
        elsif user.is_a?(Parse::Pointer)
          klass = user.parse_class
          return nil unless klass == Parse::Model::CLASS_USER || klass == "User"
          return nil unless user.id.present?
          user
        elsif user.is_a?(String) && !user.strip.empty?
          Parse::Pointer.new(Parse::Model::CLASS_USER, user)
        else
          nil
        end
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
    #
    # **The method name is misleading — prefer {#grant_capabilities_to!}
    # or {#inherits_capabilities_from!}.** `add_child_role` mutates the
    # receiver's `roles` relation; per Parse Server semantics, putting
    # role Y in role X's `roles` relation grants X's capabilities to
    # users-of-Y. The "child" terminology has the inheritance direction
    # exactly inverted from intuitive org-chart reading. Retained for
    # backward compatibility and as the low-level structural primitive;
    # new callers should use the direction-explicit semantic methods.
    #
    # IMPORTANT — Parse Server _Role inheritance semantics: when role X
    # holds role Y in its `roles` relation, **users of Y inherit X's
    # permissions** (not the other way around). So calling
    # `admin.add_child_role(moderator)` does NOT grant Moderator's
    # capabilities to Admin; it grants Admin's capabilities to every
    # Moderator user — privilege escalation.
    #
    # If you want Admins to have everything Moderators can do, you need
    # to add ADMIN to MODERATOR's roles relation:
    #
    #   moderator.add_child_role(admin)  # Admins now have Moderator capabilities
    #
    # Direction-explicit replacements:
    #
    #   admin.inherits_capabilities_from!(moderator)   # admin perspective
    #   moderator.grant_capabilities_to!(admin)        # moderator perspective
    #
    # Both bang variants auto-save and return self.
    #
    # @param role [Parse::Role] the role to add to this role's `roles` relation.
    # @return [self] returns self for chaining.
    # @raise [ArgumentError] when `role` is `self` (a self-loop in the `_Role.roles` relation produces an infinite recursion on lookup and serves no permission purpose).
    def add_child_role(role)
      assert_not_self_reference!(role, :add_child_role)
      roles.add(role)
      self
    end

    # Add multiple child roles to this role's hierarchy. See
    # {#add_child_role} for the inheritance-direction caveat.
    # @param role_list [Array<Parse::Role>] roles to add.
    # @return [self] returns self for chaining.
    # @raise [ArgumentError] when any entry in `role_list` is `self`.
    def add_child_roles(*role_list)
      flat = role_list.flatten
      flat.each { |r| assert_not_self_reference!(r, :add_child_roles) }
      roles.add(flat)
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

    # Grant this role's capabilities to the given role's users. Reads as:
    # "users with `grantee` now have `self`'s capabilities."
    # Equivalent to `self.add_child_role(grantee)` but unambiguous about
    # the direction of inheritance.
    #
    # Non-saving — the caller must call `self.save` to persist. See
    # {#grant_capabilities_to!} for the auto-saving variant.
    #
    # @param grantee [Parse::Role] the role whose users will inherit this role's permissions.
    # @return [self] returns self for chaining.
    # @example
    #   moderator.grant_capabilities_to(admin).save
    #   # → Admin users can now do anything Moderator users can
    def grant_capabilities_to(grantee)
      assert_not_self_reference!(grantee, :grant_capabilities_to)
      roles.add(grantee)
      self
    end

    # Auto-saving variant of {#grant_capabilities_to}. Performs the
    # relation mutation AND persists `self` in one call. Returns `self`
    # consistently so the caller can chain or store the result without
    # tracking which object was mutated. Prefer this in tests and
    # one-shot scripts where batching multiple mutations isn't needed.
    #
    # @param grantee [Parse::Role] the role whose users will inherit this role's permissions.
    # @return [self] the mutated and persisted self.
    # @raise [Parse::RecordNotSaved] if the save fails.
    # @example
    #   moderator.grant_capabilities_to!(admin)
    #   # → Admin users can now do anything Moderator users can. Persisted.
    def grant_capabilities_to!(grantee)
      grant_capabilities_to(grantee)
      save!
      self
    end

    # Inverse spelling of {#grant_capabilities_to}: "this role's users
    # inherit `source`'s capabilities". Performs the relation mutation
    # on `source`, not on `self`.
    #
    # **Save target.** The mutation lives on `source.roles`. To persist,
    # the caller must save `source`, NOT `self`. This asymmetry exists
    # because Parse Server stores the relation on the role that holds
    # the `roles` list, and that role is `source`. The non-bang form is
    # retained for callers that need to batch multiple mutations on
    # `source` before a single save; prefer {#inherits_capabilities_from!}
    # for the one-shot case where the auto-save matches intent.
    #
    # @param source [Parse::Role] the role whose capabilities this role's users acquire.
    # @return [Parse::Role] the `source` role (caller still needs to .save it
    #   if not using the bang variant).
    # @example Non-saving (must save source separately)
    #   admin.inherits_capabilities_from(moderator)
    #   moderator.save
    # @example Auto-saving via the bang variant
    #   admin.inherits_capabilities_from!(moderator)
    #   # → Admin users can now do anything Moderator users can. Persisted.
    def inherits_capabilities_from(source)
      assert_not_self_reference!(source, :inherits_capabilities_from)
      source.roles.add(self)
      source
    end

    # Auto-saving variant of {#inherits_capabilities_from}. Performs the
    # mutation on `source.roles` AND saves `source` for you, then
    # returns `self` so the caller can keep working with the role they
    # called the method on. Resolves the most common stumbling block
    # with {#inherits_capabilities_from}: the "save target" asymmetry.
    #
    # @param source [Parse::Role] the role whose capabilities this role's users acquire.
    # @return [self] the role that now inherits (caller's original receiver).
    # @raise [Parse::RecordNotSaved] if the save of `source` fails.
    # @example
    #   admin.inherits_capabilities_from!(moderator)
    #   # → Admin users can now do anything Moderator users can. Persisted.
    def inherits_capabilities_from!(source)
      inherits_capabilities_from(source)
      source.save!
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
    #
    # Cycle-safe: a `visited` set guards against pathological
    # `_Role.roles` cycles (e.g. A→B→A) that would otherwise cause
    # exponential per-node query fan-out.
    #
    # @param max_depth [Integer] maximum recursion depth.
    # @param visited [Set] internal cycle-detection accumulator.
    # @param master [Boolean] when `true`, opt in to the mongo-direct
    #   fast path under master-mode. The follow-up `_User` fetch also
    #   runs unscoped — used for admin/analytics paths that need a
    #   master-key view of every member.
    # @param as [Parse::User, Parse::Pointer, nil] when supplied, opt
    #   in to the mongo-direct fast path under the caller's scope. The
    #   `_Role` CLP is checked on entry, the `_User` `_rperm` allow-set
    #   is folded into the join sub-pipeline (so the fast path returns
    #   only members the scope is allowed to read), and the follow-up
    #   `Parse::MongoDB.aggregate` call to hydrate the user rows runs
    #   under the same scope (so `_User` ACL fires for both the join
    #   filter AND the post-fetch hydration).
    # @return [Array<Parse::User>] all users in the role hierarchy.
    # @note When neither `master:` nor `as:` is supplied, the
    #   mongo-direct fast path is skipped; the method falls through
    #   to the Parse-Server walk through the per-relation query
    #   interface, which goes through the default Parse::Client.
    # @example
    #   all_users = admin_role.all_users(master: true)
    #   visible = admin_role.all_users(as: current_user)
    def all_users(max_depth: 10, visited: Set.new, master: false, as: nil)
      return [] if max_depth <= 0
      return [] if id.nil? || visited.include?(id)

      # The fast path is opt-in (same rationale as {.all_for_user}).
      if master == true || !as.nil?
        fast_path = all_users_mongo_fast_path(max_depth, master: master, as: as)
        if fast_path.is_a?(Array)
          ActiveSupport::Notifications.instrument(
            "parse.role.expand",
            direction: :reverse, target_id: id, depth: max_depth,
            source: :mongo_direct, result_count: fast_path.size,
          )
          return fast_path
        end
      end

      visited << id

      direct_users = users.all

      child_roles = roles.all
      child_users = child_roles.flat_map do |child_role|
        child_role.all_users(max_depth: max_depth - 1, visited: visited)
      end

      result = (direct_users + child_users).uniq { |u| u.id }
      ActiveSupport::Notifications.instrument(
        "parse.role.expand",
        direction: :reverse, target_id: id, depth: max_depth,
        source: :parse_server, result_count: result.size,
      )
      result
    end

    # @!visibility private
    # Try the mongo-direct fast path for {#all_users}. Returns an Array
    # of hydrated {Parse::User} objects on success, or `nil` when the
    # fast path is unavailable. Attack-signal errors propagate.
    #
    # When `master: true`, the `_User` follow-up fetch runs through
    # `Parse::User.all` (default client, master-key). When `as: <user>`
    # is supplied, the follow-up runs through `Parse::MongoDB.aggregate`
    # with the caller scope so `_User` ACL fires both server-side
    # (sub-pipeline `_rperm` match in the role-subtree join, see
    # MONGO-4) AND on the hydration query (full _User row-level ACL
    # filtering before the rows hit the wire).
    def all_users_mongo_fast_path(max_depth, master: false, as: nil)
      return nil unless defined?(Parse::MongoDB)
      return nil unless Parse::MongoDB.respond_to?(:users_in_role_subtree)
      ids = Parse::MongoDB.users_in_role_subtree(
        id, max_depth: max_depth, master: master, as: as,
      )
      return nil if ids.nil?
      return [] if ids.empty?

      if master == true
        # Master path: master-keyed default client returns every row.
        Parse::User.all(:objectId.in => ids.to_a)
      else
        # Scoped path: route through Parse::MongoDB.aggregate so _User
        # ACL is enforced by the SDK on the hydration query. The
        # aggregate already strips protectedFields and filters by
        # _rperm/CLP under the resolved scope.
        hydrate_users_under_scope(ids.to_a, as)
      end
    rescue StandardError => e
      if defined?(::Mongo::Error::ConnectionFailure) &&
         e.is_a?(::Mongo::Error::ConnectionFailure)
        # Emit a structured event so operators can monitor fast-path
        # availability separate from the role-graph notification.
        ActiveSupport::Notifications.instrument(
          "parse.role.fast_path_unavailable",
          reason: "connection_failure", direction: :reverse,
          target_id: id, depth: max_depth,
        )
        nil
      else
        raise
      end
    end

    # @!visibility private
    # Hydrate a list of `_User.objectId`s into {Parse::User} instances
    # via `Parse::MongoDB.aggregate` under the supplied scope. This is
    # the scoped-path hydration that goes through the SDK's ACL
    # enforcement (top-level _rperm match, CLP, protectedFields strip)
    # instead of the master-keyed `Parse::User.all`.
    #
    # Returns an Array of {Parse::User} instances (possibly empty).
    def hydrate_users_under_scope(ids, as_scope)
      return [] if ids.nil? || ids.empty?
      pipeline = [
        { "$match" => { "_id" => { "$in" => ids.map(&:to_s) } } },
      ]
      raw = Parse::MongoDB.aggregate(
        Parse::Model::CLASS_USER, pipeline,
        allow_internal_fields: true, acl_user: as_scope,
      )
      raw.map do |doc|
        parse_doc = Parse::MongoDB.convert_document_to_parse(
          doc, Parse::Model::CLASS_USER,
        )
        Parse::User.new(parse_doc) if parse_doc
      end.compact
    end
    private :hydrate_users_under_scope

    # Get the set of role names whose presence in a `_rperm` array
    # grants access to this role's members. That's the role itself
    # plus every role `P` that lists this role in its `roles` relation,
    # transitively upward — because users of this role inherit `P`'s
    # permissions under Parse Server's role-inheritance semantics
    # (see {#add_child_role}).
    #
    # The instance-side analogue to {Parse::Role.all_for_user}; the
    # two share an internal BFS via
    # {Parse::Role.expand_inheritance_upward}. Use this method when
    # compiling an ACL predicate around a role argument, e.g.
    # `:ACL.readable_by => admin_role`: the role itself contributes
    # `"role:Admin"`, and any role whose `.roles` relation contains
    # `admin_role` also grants Admins access through inheritance.
    #
    # The legacy {#all_child_roles} walk is NOT a substitute. Child
    # roles inherit FROM this role (their members get this role's
    # capabilities), so child-role names in `_rperm` would not grant
    # this role's members anything — the walk traverses the wrong
    # direction for ACL composition.
    #
    # @param max_depth [Integer] maximum BFS depth (default: 10).
    # @return [Set<String>] role names (no `role:` prefix) including
    #   `self.name` and every transitive parent.
    # @example
    #   permission_strings = admin.all_parent_role_names.map { |n| "role:#{n}" }
    def all_parent_role_names(max_depth: 10)
      Parse::Role.expand_inheritance_upward([self], max_depth: max_depth)
    end

    # Get all child roles recursively. Cycle-safe; see {#all_users}.
    # @param max_depth [Integer] maximum recursion depth.
    # @param visited [Set] internal cycle-detection accumulator.
    # @return [Array<Parse::Role>] all child roles in the hierarchy.
    def all_child_roles(max_depth: 10, visited: Set.new)
      return [] if max_depth <= 0
      return [] if id.nil? || visited.include?(id)
      visited << id

      direct_children = roles.all
      nested_children = direct_children.flat_map do |child|
        child.all_child_roles(max_depth: max_depth - 1, visited: visited)
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

    private

    # @!visibility private
    # Refuses a `_Role.roles` mutation that would point a role at itself.
    # The visited-Set guard in {#all_users} / {#all_child_roles} prevents
    # the recursion blowup at read time, but a persisted self-loop still
    # wastes one round-trip per traversal and has no permission effect
    # under Parse Server's role-expansion rules. Reject at write time.
    def assert_not_self_reference!(role, method_name)
      raise ArgumentError,
            "#{method_name} requires a Parse::Role argument (got #{role.class})" unless role.is_a?(Parse::Role)
      same_instance = role.equal?(self)
      same_id = id.present? && role.id.present? && role.id == id
      if same_instance || same_id
        raise ArgumentError,
              "#{method_name} cannot point a role at itself " \
              "(role #{name.inspect}/#{id.inspect}); self-loops in the " \
              "_Role.roles relation serve no permission purpose."
      end
    end
  end
end
