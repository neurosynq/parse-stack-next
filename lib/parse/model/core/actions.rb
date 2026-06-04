# encoding: UTF-8
# frozen_string_literal: true

require "active_model"
require "active_support"
require "active_support/inflector"
require "active_support/core_ext"
require "time"
require_relative "../../client/request"
require_relative "fetching"

module Parse
  class Query

    # Supporting the `first_or_create` class method to be used in scope chaining with queries.
    # @!visibility private
    def first_or_create(query_attrs = {}, resource_attrs = {})
      conditions(query_attrs)
      klass = Parse::Model.find_class self.table
      if klass.blank?
        raise ArgumentError, "Parse model with class name #{self.table} is not registered."
      end
      hash_constraints = constraints(true)
      klass.first_or_create(hash_constraints, resource_attrs)
    end

    # Supporting the `save_all` method to be used in scope chaining with queries.
    # @!visibility private
    def save_all(expressions = {}, &block)
      conditions(expressions)
      klass = Parse::Model.find_class self.table
      if klass.blank?
        raise ArgumentError, "Parse model with class name #{self.table} is not registered."
      end
      hash_constraints = constraints(true)

      klass.save_all(hash_constraints, &block) if block_given?
      klass.save_all(hash_constraints)
    end
  end

  # A Parse::RelationAction is special operation that adds one object to a relational
  # table as to another. Depending on the polarity of the action, the objects are
  # either added or removed from the relation. This class is used to generate the proper
  # hash request formats Parse needs in order to modify relational information for classes.
  class RelationAction
    # @!visibility private
    ADD = "AddRelation"
    # @!visibility private
    REMOVE = "RemoveRelation"
    # @!attribute polarity
    # @return [Boolean] whether it is an addition (true) or removal (false) action.
    # @!attribute key
    # @return [String] the name of the Parse field (column).
    # @!attribute objects
    # @return [Array<Parse::Object>] the set of objects in this relation action.
    attr_accessor :polarity, :key, :objects

    # @param field [String] the name of the Parse field tied to this relation.
    # @param polarity [Boolean] whether this is an addition (true) or removal (false) action.
    # @param objects [Array<Parse::Object>] the set of objects tied to this relation action.
    def initialize(field, polarity: true, objects: [])
      @key = field.to_s
      self.polarity = polarity
      @objects = Array.wrap(objects).compact
    end

    # @return [Hash] a hash representing a relation operation.
    def as_json(*args)
      { @key => {
        "__op" => (@polarity == true ? ADD : REMOVE),
        "objects" => objects.parse_pointers,
      } }.as_json
    end
  end
end

# This module is mainly all the basic orm operations. To support batching actions,
# we use temporary Request objects have contain the operation to be performed (in some cases).
# This allows to group a list of Request methods, into a batch for sending all at once to Parse.
module Parse

  # An error raised when a save failure occurs.
  class RecordNotSaved < StandardError
    # @return [Parse::Object] the Parse::Object that failed to save.
    attr_reader :object

    # @param object [Parse::Object] the object that failed.
    def initialize(object)
      @object = object
    end
  end

  module Core
    # Defines some of the save, update and destroy operations for Parse objects.
    module Actions
      # @!visibility private
      def self.included(base)
        base.extend(ClassMethods)
        # Per-class override for the synchronize-create lock. `nil` means
        # "inherit from `Parse.synchronize_create_default`". Set to true/false
        # on a subclass to force-on or force-off for that class and its
        # descendants. Use ActiveSupport::class_attribute so inheritance works
        # naturally; mirrors `signup_on_save` (user.rb:178) and `field_guards`
        # (field_guards.rb:55).
        if base.respond_to?(:class_attribute)
          base.class_attribute :synchronize_create_default, instance_writer: false
          base.synchronize_create_default = nil
        end
      end

      # Class methods applied to Parse::Object subclasses.
      module ClassMethods

        # Execute a set of operations as an atomic transaction.
        # All operations will be executed in sequence, and if any fail,
        # the entire transaction will be rolled back.
        #
        # @example Basic transaction
        #   Parse::Object.transaction do |batch|
        #     user = User.first
        #     user.username = "new_username"
        #     batch.add(user)
        #
        #     post = Post.new(author: user, title: "New Post")
        #     batch.add(post)
        #   end
        #
        # @example Using the block return for automatic batching
        #   results = Parse::Object.transaction do
        #     user1 = User.first
        #     user1.score = 100
        #
        #     user2 = User.first(username: "player2")
        #     user2.score = 200
        #
        #     [user1, user2]  # Return array of objects to save
        #   end
        #
        # @param retries [Integer] number of times to retry on transaction conflict (error 251)
        # @yield [Parse::BatchOperation] the batch operation to add requests to
        # @return [Array<Parse::Response>] the responses from the transaction
        # @raise [Parse::Error] if the transaction fails
        def transaction(retries: 5, &block)
          raise ArgumentError, "Block required for transaction" unless block_given?

          batch = Parse::BatchOperation.new(nil, transaction: true)

          # Store original state of objects for rollback
          original_states = {}
          tracked_objects = []

          # Wrap the batch to capture objects being added
          batch_wrapper = Object.new
          batch_wrapper.define_singleton_method(:is_a?) do |klass|
            klass == Parse::BatchOperation || super(klass)
          end
          batch_wrapper.define_singleton_method(:kind_of?) do |klass|
            klass == Parse::BatchOperation || super(klass)
          end
          batch_wrapper.define_singleton_method(:instance_of?) do |klass|
            klass == Parse::BatchOperation
          end
          batch_wrapper.define_singleton_method(:add) do |obj|
            # Store original state when object is first added to transaction.
            # Use obj.object_id (Ruby identity) as the key because Parse::Object#hash
            # and #eql? treat all unsaved objects (nil id) as equal, which would cause
            # only the first unsaved object to be tracked.
            if obj.respond_to?(:attributes) && obj.respond_to?(:id) && !original_states.key?(obj.object_id)
              original_states[obj.object_id] = {
                object: obj,
                attributes: obj.attributes.dup,
                changed_attributes: obj.instance_variable_get(:@changed_attributes)&.dup || {},
                id: obj.id,
                mutations_from_database: obj.instance_variable_get(:@mutations_from_database),
                mutations_before_last_save: obj.instance_variable_get(:@mutations_before_last_save),
              }
              tracked_objects << obj
            end
            batch.add(obj)
          end

          # Forward other methods to the real batch
          batch_wrapper.define_singleton_method(:method_missing) do |method, *args, &block|
            batch.send(method, *args, &block)
          end

          result = yield(batch_wrapper)

          # If block returns objects, add them to batch
          if result.respond_to?(:change_requests)
            batch_wrapper.add(result)
          elsif result.is_a?(Array)
            result.each { |obj| batch_wrapper.add(obj) if obj.respond_to?(:change_requests) }
          end

          # Submit with retry logic for transaction conflicts
          attempts = 0
          begin
            attempts += 1
            responses = batch.submit

            # Check for success
            if responses.all?(&:success?)
              # Update tracked objects with data from successful responses
              # Match responses to objects using the request tag (Ruby object_id)
              # Build hash lookup once for O(n) instead of O(n²) linear search
              objects_by_id = tracked_objects.each_with_object({}) { |o, h| h[o.object_id] = o }
              requests = batch.requests
              requests.zip(responses).each do |request, response|
                next unless request && response && response.success?
                result = response.result
                next unless result.is_a?(Hash)

                # Find the object matching this request's tag
                obj = objects_by_id[request.tag]
                next unless obj

                # Update object with response data (objectId, createdAt, updatedAt)
                if result["objectId"]
                  obj.instance_variable_set(:@id, result["objectId"])
                end
                if result["createdAt"]
                  obj.instance_variable_set(:@created_at, Parse::Date.parse(result["createdAt"]))
                end
                if result["updatedAt"]
                  obj.instance_variable_set(:@updated_at, Parse::Date.parse(result["updatedAt"]))
                elsif result["createdAt"]
                  obj.instance_variable_set(:@updated_at, Parse::Date.parse(result["createdAt"]))
                end

                # Apply any additional attributes returned by beforeSave hooks
                obj.set_attributes!(result) if obj.respond_to?(:set_attributes!)

                # Clear change tracking since save was successful
                obj.send(:clear_changes!) if obj.respond_to?(:clear_changes!, true)
              end

              return responses
            else
              # Find first error
              error_response = responses.find { |r| !r.success? }

              # Rollback local object states
              original_states.each_value do |state|
                obj = state[:object]
                obj.instance_variable_set(:@attributes, state[:attributes])
                obj.instance_variable_set(:@changed_attributes, state[:changed_attributes])
                obj.instance_variable_set(:@id, state[:id])
                # Restore change tracking state
                obj.instance_variable_set(:@mutations_from_database, state[:mutations_from_database])
                obj.instance_variable_set(:@mutations_before_last_save, state[:mutations_before_last_save])
              end

              raise Parse::Error, "Transaction failed: #{error_response.error}"
            end
          rescue Parse::Error => e
            # Retry on transaction conflict (error code 251)
            if e.message.include?("251") && attempts < retries
              sleep(0.1 * attempts) # Exponential backoff
              retry
            end

            # Rollback local object states on final failure
            original_states.each_value do |state|
              obj = state[:object]
              obj.instance_variable_set(:@attributes, state[:attributes])
              obj.instance_variable_set(:@changed_attributes, state[:changed_attributes])
              obj.instance_variable_set(:@id, state[:id])
              # Restore change tracking state
              obj.instance_variable_set(:@mutations_from_database, state[:mutations_from_database])
              obj.instance_variable_set(:@mutations_before_last_save, state[:mutations_before_last_save])
            end

            raise e
          end
        end

        # @!attribute raise_on_save_failure
        # By default, we return `true` or `false` for save and destroy operations.
        # If you prefer to have `Parse::Object` raise an exception instead, you
        # can tell to do so either globally or on a per-model basis. When a save
        # fails, it will raise a {Parse::RecordNotSaved}.
        #
        # When enabled, if an error is returned by Parse due to saving or
        # destroying a record, due to your `before_save` or `before_delete`
        # validation cloud code triggers, `Parse::Object` will return the a
        # {Parse::RecordNotSaved} exception type. This exception has an instance
        # method of `#object` which contains the object that failed to save.
        # @example
        #  # globally across all models
        #  Parse::Model.raise_on_save_failure = true
        #  Song.raise_on_save_failure = true # per-model
        #
        #  # or per-instance raise on failure
        #  song.save!
        #
        # @return [Boolean] whether to raise a {Parse::RecordNotSaved}
        #   when an object fails to save.
        attr_writer :raise_on_save_failure

        def raise_on_save_failure
          return @raise_on_save_failure unless @raise_on_save_failure.nil?
          Parse::Model.raise_on_save_failure
        end

        # Finds the first object matching the query conditions, or creates a new
        # unsaved object with the attributes. This method takes the possibility of two hashes,
        # therefore make sure you properly wrap the contents of the input with `{}`.
        # @example
        #   Parse::User.first_or_create({ ..query conditions..})
        #   Parse::User.first_or_create({ ..query conditions..}, {.. resource_attrs ..})
        # @param query_attrs [Hash] a set of query constraints that also are applied.
        # @param resource_attrs [Hash] a set of additional attribute values to be applied only if an object was not found.
        # @return [Parse::Object] a Parse::Object, whether found by the query or newly created.
        def first_or_create(query_attrs = {}, resource_attrs = {})
          query_attrs = query_attrs.symbolize_keys
          resource_attrs = resource_attrs.symbolize_keys
          obj = query(query_attrs).first

          if obj.blank?
            # Object not found, create new one with query_attrs + resource_attrs
            merged_attrs = query_attrs.merge(resource_attrs)
            obj = self.new merged_attrs
          end
          # If object exists, return it as-is without any modifications

          obj
        end

        # Finds the first object matching the query conditions, or creates a new
        # *saved* object with the attributes. This method is similar to {first_or_create}
        # but will also {save!} the object if it was newly created.
        #
        # When `synchronize:` is enabled (per-call, per-class via
        # `synchronize_create_default`, or globally via
        # `Parse.synchronize_create_default`), the find→create→save sequence is
        # serialized through {Parse::CreateLock} so concurrent callers
        # with identical `query_attrs` cannot both create. The lock requires a
        # Moneta cache store (Redis recommended); on a process-local store the
        # lock degrades to a per-key Mutex. A MongoDB unique index on the
        # constrained fields is the correctness floor — on Parse code 137
        # (DuplicateValue) the wrapper re-queries inside the held lock and
        # returns the winner.
        #
        # @example
        #   obj = Parse::User.first_or_create!({ ..query conditions..})
        #   obj = Parse::User.first_or_create!({ ..query conditions..}, {.. resource_attrs ..})
        # @example Per-call lock opt-in
        #   User.first_or_create!({ email: e }, { name: n }, synchronize: true)
        # @example Per-call with tuning
        #   User.first_or_create!({ email: e }, {}, synchronize: { ttl: 5, wait: 1.0 })
        # @example Auth-context threading
        #   User.first_or_create!({ email: e }, {}, session: current_user.session_token)
        # @param query_attrs [Hash] a set of query constraints that also are applied.
        # @param resource_attrs [Hash] a set of attribute values to be applied if an object was not found.
        # @param synchronize [Boolean, Hash, nil] override the synchronize-create lock. `nil` (default) defers
        #   to the per-class `synchronize_create_default` or the module-level `Parse.synchronize_create_default`.
        #   `true` enables with defaults; `false` opts out; a Hash enables with custom options merged over
        #   `Parse.synchronize_create_options`.
        # @param session [String, Parse::User, nil] session token (or object answering :session_token) threaded
        #   through both the query and the save so the entire find→create flow runs under one auth identity.
        # @param master_key [Boolean, nil] when explicitly `false`, disables master key for both halves.
        # @return [Parse::Object] a Parse::Object, whether found by the query or newly created.
        # @raise {Parse::RecordNotSaved} if the save fails
        # @raise {Parse::CreateLockTimeoutError} when synchronized and the wait budget is exceeded
        # @raise {Parse::CreateLockInvalidKey} when query_attrs cannot be canonicalized for a stable lock key
        # @see #first_or_create
        def first_or_create!(query_attrs = {}, resource_attrs = {}, synchronize: nil, session: nil, master_key: nil)
          query_attrs = query_attrs.symbolize_keys
          resource_attrs = resource_attrs.symbolize_keys

          enabled, sync_opts = _resolve_synchronize_flag(synchronize)
          return _first_or_create_unsynchronized!(query_attrs, resource_attrs, session: session, master_key: master_key) unless enabled

          _assert_synchronize_class_allowed!
          options = _merged_synchronize_options(sync_opts)
          session_token = _extract_session_token(session)

          # Split query_attrs into the constraint subset (what
          # determines lock identity) and the query-shape options
          # (`:cache`, `:limit`, `:order`, ACL helpers, …) that
          # `Parse::Query#conditions` absorbs as query parameters.
          # Without this, a caller passing the documented `cache:
          # 30.seconds` escape hatch alongside their constraints
          # tripped `Parse::CreateLock.canonicalize_value` on the
          # `ActiveSupport::Duration` — see 4.4.2 changelog. The
          # original `query_attrs` is still forwarded to
          # `_scoped_first` below; `conditions()` extracts the option
          # keys on the find side, so the cache TTL still applies.
          lock_attrs = query_attrs.reject { |k, _| Parse::Query.option_key?(k) }
          _assert_lock_attrs_have_constraints!(query_attrs, lock_attrs)

          Parse::CreateLock.synchronize(
            parse_class: parse_class,
            query_attrs: lock_attrs,
            options: options,
            session_token: session_token,
            master_key: master_key,
          ) do
            obj = _scoped_first(query_attrs, session: session, master_key: master_key)
            next obj if obj

            obj = self.new query_attrs.merge(resource_attrs)
            begin
              session ? obj.save!(session: session) : obj.save!
              obj
            rescue Parse::RecordNotSaved => e
              winner = _recover_from_duplicate_value(e, query_attrs, session: session, master_key: master_key)
              raise unless winner
              winner
            rescue Parse::Error::DuplicateRequestError
              # A transparently-retried create landed but lost its response;
              # server idempotency rejected the replay. Re-find the row the
              # original attempt created and return it.
              winner = _recover_from_duplicate_request(query_attrs, session: session, master_key: master_key)
              raise unless winner
              winner
            end
          end
        end

        # Creates a new object with the given attributes and saves it.
        # This is equivalent to calling `new(attrs).save!`.
        # @example
        #   song = Song.create!(title: "New Song", artist: "Artist")
        # @param attrs [Hash] the attributes for the new object.
        # @return [Parse::Object] the newly created and saved object.
        # @raise {Parse::RecordNotSaved} if the save fails
        def create!(attrs = {})
          obj = new(attrs)
          obj.save!
          obj
        end

        # Finds the first object matching the query conditions and updates it with the attributes,
        # or creates a new *saved* object with the attributes. Saves new objects or existing objects with changes.
        # See {#first_or_create!} for the synchronize-create lock semantics — they apply identically here.
        # @example
        #   Parse::User.create_or_update!({ ..query conditions..}, {.. resource_attrs ..})
        # @param query_attrs [Hash] a set of query constraints that also are applied.
        # @param resource_attrs [Hash] a set of attribute values to be applied to found objects or used for creation.
        # @param synchronize (see #first_or_create!)
        # @param session (see #first_or_create!)
        # @param master_key (see #first_or_create!)
        # @return [Parse::Object] a Parse::Object, whether found by the query or newly created.
        # @raise {Parse::RecordNotSaved} if the save fails
        def create_or_update!(query_attrs = {}, resource_attrs = {}, synchronize: nil, session: nil, master_key: nil)
          query_attrs = query_attrs.symbolize_keys
          resource_attrs = resource_attrs.symbolize_keys

          enabled, sync_opts = _resolve_synchronize_flag(synchronize)
          return _create_or_update_unsynchronized!(query_attrs, resource_attrs, session: session, master_key: master_key) unless enabled

          _assert_synchronize_class_allowed!
          options = _merged_synchronize_options(sync_opts)
          session_token = _extract_session_token(session)

          # See #first_or_create! for the partition rationale — strip
          # Parse::Query option keys before lock canonicalization.
          lock_attrs = query_attrs.reject { |k, _| Parse::Query.option_key?(k) }
          _assert_lock_attrs_have_constraints!(query_attrs, lock_attrs)

          Parse::CreateLock.synchronize(
            parse_class: parse_class,
            query_attrs: lock_attrs,
            options: options,
            session_token: session_token,
            master_key: master_key,
          ) do
            obj = _scoped_first(query_attrs, session: session, master_key: master_key)

            if obj.nil?
              obj = self.new query_attrs.merge(resource_attrs)
              begin
                session ? obj.save!(session: session) : obj.save!
              rescue Parse::RecordNotSaved => e
                winner = _recover_from_duplicate_value(e, query_attrs, session: session, master_key: master_key)
                raise unless winner
                obj = winner
              rescue Parse::Error::DuplicateRequestError
                # See #first_or_create! — recover the row a retried create
                # already landed (it already carries resource_attrs).
                winner = _recover_from_duplicate_request(query_attrs, session: session, master_key: master_key)
                raise unless winner
                obj = winner
              end
            end

            if !obj.new? && !resource_attrs.empty?
              has_changes = resource_attrs.any? do |key, value|
                obj.respond_to?(key) && obj.send(key) != value
              end
              if has_changes
                obj.apply_attributes!(resource_attrs, dirty_track: true)
                begin
                  session ? obj.save!(session: session) : obj.save!
                rescue Parse::Error::DuplicateRequestError
                  # A retried update (PUT) landed but lost its response; re-find
                  # the now-updated row and return it.
                  winner = _recover_from_duplicate_request(query_attrs, session: session, master_key: master_key)
                  raise unless winner
                  obj = winner
                end
              end
            end

            obj
          end
        end

        # @!visibility private
        # Resolves the per-call synchronize kwarg against per-class and module
        # defaults. Returns [enabled?, options_hash].
        #
        # Precedence (most specific wins):
        #   per-call true/false  →  per-class default  →  Parse.synchronize_create_default
        # A Hash kwarg implies `true` with custom options. `nil` defers up the chain.
        def _resolve_synchronize_flag(synchronize)
          case synchronize
          when true
            [true, {}]
          when false
            [false, {}]
          when Hash
            [true, synchronize]
          when nil
            cls_default = respond_to?(:synchronize_create_default) ? synchronize_create_default : nil
            case cls_default
            when true
              [true, {}]
            when false
              [false, {}]
            when Hash
              [true, cls_default]
            else
              [Parse.synchronize_create_default ? true : false, {}]
            end
          else
            raise ArgumentError, "synchronize: must be true, false, nil, or an options Hash (got #{synchronize.class})"
          end
        end

        # @!visibility private
        def _merged_synchronize_options(per_call)
          base = Parse.synchronize_create_options || {}
          base.merge(per_call || {})
        end

        # @!visibility private
        # Enforce {Parse.synchronize_classes} allowlist. Inheritance is
        # **transitive** for Class entries (`self <= entry`): allowlisting
        # `User` automatically allowlists every subclass of `User`. To gate
        # per-class without inheritance, pass entries as Strings — they
        # match only `self.name` / `parse_class` literally. See the
        # `Parse.synchronize_classes` docstring in lib/parse/stack.rb.
        def _assert_synchronize_class_allowed!
          allowlist = Parse.synchronize_classes
          return if allowlist.nil? || allowlist.empty?
          allowed = allowlist.any? do |entry|
            (entry.is_a?(Class) && self <= entry) ||
              entry.to_s == self.name ||
              entry.to_s == parse_class
          end
          return if allowed
          raise Parse::CreateLockUnavailableError,
                "#{self} is not in Parse.synchronize_classes allowlist; either add it or pass synchronize: false"
        end

        # @!visibility private
        # Confirm that after partitioning query_attrs into
        # constraints + query-shape options, at least one constraint
        # remained. If not, raise a specific error explaining the
        # likely mistake before `Parse::CreateLock.synchronize` does
        # — its generic "non-empty query_attrs" message would mislead
        # the caller who can see a non-empty `query_attrs` argument
        # right there in their code.
        #
        # Two distinguished cases:
        # - `query_attrs` was empty to begin with → generic empty
        #   error (the user really did pass nothing).
        # - `query_attrs` was non-empty but every key was a query
        #   option (`:cache`, `:limit`, …) → specific error naming the
        #   partitioned-out keys so the user can fix their call.
        def _assert_lock_attrs_have_constraints!(query_attrs, lock_attrs)
          return unless lock_attrs.empty?
          if query_attrs.empty?
            raise Parse::CreateLockInvalidKey,
                  "synchronize requires at least one constraint key in query_attrs (got an empty Hash)"
          end
          option_keys = query_attrs.keys.select { |k| Parse::Query.option_key?(k) }
          raise Parse::CreateLockInvalidKey,
                "synchronize requires at least one constraint key in query_attrs; " \
                "every key passed (#{option_keys.inspect}) is a Parse::Query option " \
                "(`:cache`, `:limit`, `:order`, ACL helpers, …) and is partitioned " \
                "out of the lock identity. Add a constraint key (e.g. the unique " \
                "field your callsite is finding-or-creating against), or pass " \
                "`synchronize: false` if you don't need cross-process locking."
        end

        # @!visibility private
        # Extract a session token string from either a String or an object
        # answering :session_token (e.g. Parse::User, Parse::Session). Returns
        # nil when session is nil so the canonical lock key picks the
        # "default" auth-context marker.
        def _extract_session_token(session)
          return nil if session.nil?
          return session if session.is_a?(String)
          return session.session_token if session.respond_to?(:session_token)
          raise ArgumentError, "session: must be a String token or an object responding to :session_token (got #{session.class})"
        end

        # @!visibility private
        # Run `query(constraints).first` with explicit auth scoping so the
        # synchronized find runs under the same identity as the subsequent
        # save. When session/master_key are unset, falls through to the
        # client default exactly as the legacy non-synchronized path.
        def _scoped_first(query_attrs, session: nil, master_key: nil)
          q = query(query_attrs)
          if session
            q.session_token = session.respond_to?(:session_token) ? session.session_token : session
          end
          q.use_master_key = master_key unless master_key.nil?
          q.first
        end

        # @!visibility private
        # When a save inside the lock fails with Parse code 137 (DuplicateValue),
        # re-query inside the still-held lock and return the row that won the
        # race. Returns nil when the error was something other than 137 or the
        # winner cannot be located. The caller raises the original exception in
        # the nil case.
        def _recover_from_duplicate_value(error, query_attrs, session: nil, master_key: nil)
          obj = error.respond_to?(:object) ? error.object : nil
          return nil unless obj
          res = obj.instance_variable_get(:@_last_response)
          return nil unless res && res.respond_to?(:code) && res.code == Parse::Client::DuplicateValueError::CODE
          _scoped_first(query_attrs, session: session, master_key: master_key)
        end

        # @!visibility private
        # Recovery for a request-id idempotency duplicate
        # ({Parse::Error::DuplicateRequestError}, Parse code 159): the create's
        # POST was rejected as a duplicate, which means a prior — transparently
        # retried — attempt already created the row but lost its response. Re-find
        # the row by the identifying `query_attrs` and return it (the row was
        # created with `query_attrs.merge(resource_attrs)`, so it already carries
        # the resource attributes). Returns nil if it cannot be located, in which
        # case the caller re-raises the original error. Relies on `query_attrs`
        # actually identifying the row — the same assumption the duplicate-value
        # recovery and `first_or_create!`'s own find already make.
        def _recover_from_duplicate_request(query_attrs, session: nil, master_key: nil)
          _scoped_first(query_attrs, session: session, master_key: master_key)
        end

        # @!visibility private
        # The pre-synchronize behavior of `first_or_create!`, factored out so
        # the synchronize wrapper can short-circuit when disabled. Preserves
        # the legacy contract: query → build → save! if new.
        def _first_or_create_unsynchronized!(query_attrs, resource_attrs, session: nil, master_key: nil)
          obj = _scoped_first(query_attrs, session: session, master_key: master_key)
          if obj.nil?
            obj = self.new query_attrs.merge(resource_attrs)
          end
          if obj.new?
            begin
              session ? obj.save!(session: session) : obj.save!
            rescue Parse::Error::DuplicateRequestError
              winner = _recover_from_duplicate_request(query_attrs, session: session, master_key: master_key)
              raise unless winner
              obj = winner
            end
          end
          obj
        end

        # @!visibility private
        def _create_or_update_unsynchronized!(query_attrs, resource_attrs, session: nil, master_key: nil)
          obj = _scoped_first(query_attrs, session: session, master_key: master_key)
          if obj.nil?
            obj = self.new query_attrs.merge(resource_attrs)
            begin
              session ? obj.save!(session: session) : obj.save!
            rescue Parse::Error::DuplicateRequestError
              winner = _recover_from_duplicate_request(query_attrs, session: session, master_key: master_key)
              raise unless winner
              obj = winner
            end
          elsif !resource_attrs.empty?
            has_changes = resource_attrs.any? do |key, value|
              obj.respond_to?(key) && obj.send(key) != value
            end
            if has_changes
              obj.apply_attributes!(resource_attrs, dirty_track: true)
              begin
                session ? obj.save!(session: session) : obj.save!
              rescue Parse::Error::DuplicateRequestError
                winner = _recover_from_duplicate_request(query_attrs, session: session, master_key: master_key)
                raise unless winner
                obj = winner
              end
            end
          end
          obj
        end

        # Auto save all objects matching the query constraints. This method is
        # meant to be used with a block. Any objects that are modified in the block
        # will be batched for a save operation. This uses the `updated_at` field to
        # continue to query for all matching objects that have not been updated.
        # If you need to use `:updated_at` in your constraints, consider using {Parse::Core::Querying#all} or
        # {Parse::Core::Querying#each}
        # @param constraints [Hash] a set of query constraints.
        # @yield a block which will iterate through each matching object.
        # @example
        #
        #  post = Post.first
        #  Comments.save_all( post: post) do |comment|
        #    # .. modify comment ...
        #    # it will automatically be saved
        #  end
        # @note You cannot use *:updated_at* as a constraint.
        # @return [Boolean] true if all saves succeeded and there were no errors.
        def save_all(constraints = {}, &block)
          invalid_constraints = constraints.keys.any? do |k|
            (k == :updated_at || k == :updatedAt) ||
            (k.is_a?(Parse::Operation) && (k.operand == :updated_at || k.operand == :updatedAt))
          end
          if invalid_constraints
            raise ArgumentError,
              "[#{self}] Special method save_all() cannot be used with an :updated_at constraint."
          end

          force = false
          batch_size = 250
          iterator_block = nil
          if block_given?
            iterator_block = block
            force ||= false
          else
            # if no block given, assume you want to just save all objects
            # regardless of modification.
            force = true
          end
          # Only generate the comparison block once.
          # updated_comparison_block = Proc.new { |x| x.updated_at }

          anchor_date = Parse::Date.now
          constraints.merge! :updated_at.on_or_before => anchor_date
          constraints.merge! cache: false
          # oldest first, so we create a reduction-cycle
          constraints.merge! order: :updated_at.asc, limit: batch_size
          update_query = query(constraints)
          #puts "Setting Anchor Date: #{anchor_date}"
          cursor = nil
          has_errors = false
          loop do
            results = update_query.results

            break if results.empty?

            # verify we didn't get duplicates fetches
            if cursor.is_a?(Parse::Object) && results.any? { |x| x.id == cursor.id }
              warn "[#{self}.save_all] Unbounded update detected with id #{cursor.id}."
              has_errors = true
              break cursor
            end

            results.each(&iterator_block) if iterator_block.present?
            # we don't need to refresh the objects in the array with the results
            # since we will be throwing them away. Force determines whether
            # to save these objects regardless of whether they are dirty.
            batch = results.save(merge: false, force: force)

            # faster version assuming sorting order wasn't messed up
            cursor = results.last
            # slower version, but more accurate
            # cursor_item = results.max_by(&updated_comparison_block).updated_at
            # puts "[Parse::SaveAll] Updated #{results.count} records updated <= #{cursor.updated_at}"

            break if results.count < batch_size # we didn't hit a cap on results.
            if cursor.is_a?(Parse::Object)
              update_query.where :updated_at.gte => cursor.updated_at

              if cursor.updated_at.present? && cursor.updated_at > anchor_date
                warn "[#{self}.save_all] Reached anchor date  #{anchor_date} < #{cursor.updated_at}"
                break cursor
              end
            end

            has_errors ||= batch.error?
          end
          not has_errors
        end
      end # ClassMethods

      # Perform an atomic operation on this field. This operation is done on the
      # Parse server which guarantees the atomicity of the operation. This is the low-level
      # API on performing atomic operations on properties for classes. These methods do not
      # update the current instance with any changes the server may have made to satisfy this
      # operation.
      #
      # @param field [String] the name of the field in the Parse collection.
      # @param op_hash [Hash] The operation hash. It may also be of type {Parse::RelationAction}.
      # @return [Boolean] whether the operation was successful.
      def operate_field!(field, op_hash)
        field = field.to_sym
        field = self.field_map[field] || field
        if op_hash.is_a?(Parse::RelationAction)
          op_hash = op_hash.as_json
        else
          op_hash = { field => op_hash }.as_json
        end

        # If the object hasn't been saved yet (no id), we can't make field operations
        # Return true to indicate the operation was "successful" locally
        return true if id.nil?

        response = client.update_object(parse_class, id, op_hash, session_token: _session_token)
        if response.error?
          puts "[#{parse_class}:#{field} Operation] #{response.error}"
        end
        response.success?
      end

      # Perform an atomic add operation to the array field.
      # @param field [String] the name of the field in the Parse collection.
      # @param objects [Array] the set of items to add to this field.
      # @return [Boolean] whether it was successful
      # @see #operate_field!
      def op_add!(field, objects)
        operate_field! field, { __op: :Add, objects: objects }
      end

      # Perform an atomic add unique operation to the array field. The objects will
      # only be added if they don't already exists in the array for that particular field.
      # @param field [String] the name of the field in the Parse collection.
      # @param objects [Array] the set of items to add uniquely to this field.
      # @return [Boolean] whether it was successful
      # @see #operate_field!
      def op_add_unique!(field, objects)
        operate_field! field, { __op: :AddUnique, objects: objects }
      end

      # Perform an atomic remove operation to the array field.
      # @param field [String] the name of the field in the Parse collection.
      # @param objects [Array] the set of items to remove to this field.
      # @return [Boolean] whether it was successful
      # @see #operate_field!
      def op_remove!(field, objects)
        operate_field! field, { __op: :Remove, objects: objects }
      end

      # Perform an atomic delete operation on this field.
      # @param field [String] the name of the field in the Parse collection.
      # @return [Boolean] whether it was successful
      # @see #operate_field!
      def op_destroy!(field)
        result = operate_field! field, { __op: :Delete }.freeze
        if result
          # Also update the local state to reflect the deletion
          field_sym = field.to_sym
          if self.class.fields[field_sym].present?
            set_attribute_method = "#{field}_set_attribute!"
            if respond_to?(set_attribute_method)
              send(set_attribute_method, nil, true) # Set to nil with dirty tracking
            else
              instance_variable_set(:"@#{field}", nil)
              send("#{field}_will_change!") if respond_to?("#{field}_will_change!")
            end
          end
        end
        result
      end

      # Perform an atomic add operation on this relational field.
      # @param field [String] the name of the field in the Parse collection.
      # @param objects [Array<Parse::Object>] the set of objects to add to this relational field.
      # @return [Boolean] whether it was successful
      # @see #operate_field!
      def op_add_relation!(field, objects = [])
        objects = [objects] unless objects.is_a?(Array)
        return false if objects.empty?
        relation_action = Parse::RelationAction.new(field, polarity: true, objects: objects)
        operate_field! field, relation_action
      end

      # Perform an atomic remove operation on this relational field.
      # @param field [String] the name of the field in the Parse collection.
      # @param objects [Array<Parse::Object>] the set of objects to remove to this relational field.
      # @return [Boolean] whether it was successful
      # @see #operate_field!
      def op_remove_relation!(field, objects = [])
        objects = [objects] unless objects.is_a?(Array)
        return false if objects.empty?
        relation_action = Parse::RelationAction.new(field, polarity: false, objects: objects)
        operate_field! field, relation_action
      end

      # Atomically increment or decrement a specific field.
      # @param field [String] the name of the field in the Parse collection.
      # @param amount [Integer] the amoun to increment. Use negative values to decrement.
      # @see #operate_field!
      def op_increment!(field, amount = 1)
        unless amount.is_a?(Numeric)
          raise ArgumentError, "Amount should be numeric"
        end
        result = operate_field! field, { __op: :Increment, amount: amount.to_i }.freeze
        if result
          # Also update the local state to reflect the increment
          field_sym = field.to_sym
          current_value = self[field_sym] || 0
          new_value = current_value + amount.to_i
          set_attribute_method = "#{field}_set_attribute!"
          if respond_to?(set_attribute_method)
            send(set_attribute_method, new_value, true) # Set new value with dirty tracking
          else
            self[field_sym] = new_value
          end
        end
        result
      end

      # @return [Parse::Request] a destroy_request for the current object.
      def destroy_request
        return nil unless @id.present?
        uri = self.uri_path
        r = Request.new(:delete, uri)
        r.tag = object_id
        r
      end

      # @return [String] the API uri path for this class.
      def uri_path
        self.client.url_prefix.path + Client.uri_path(self)
      end

      # Creates an array of all possible operations that need to be performed
      # on this object. This includes all property and relational operation changes.
      # @param force [Boolean] whether this object should be saved even if does not have
      #  pending changes.
      # @return [Array<Parse::Request>] the list of API requests.
      def change_requests(force = false)
        requests = []
        # get the URI path for this object.
        uri = self.uri_path

        # generate the request to update the object (PUT)
        if attribute_changes? || force
          # if it's new, then we should call :post for creating the object.
          method = new? ? :post : :put
          r = Request.new(method, uri, body: attribute_updates)
          r.tag = object_id
          requests << r
        end

        # if the object is not new, then we can also add all the relational changes
        # we need to perform.
        if @id.present? && relation_changes?
          relation_change_operations.each do |ops|
            next if ops.empty?
            r = Request.new(:put, uri, body: ops)
            r.tag = object_id
            requests << r
          end
        end
        requests
      end

      # This methods sends an update request for this object with the any change
      # information based on its local attributes. The bang implies that it will send
      # the request even though it is possible no changes were performed. This is useful
      # in kicking-off an beforeSave / afterSave hooks
      # Save the object regardless of whether there are changes. This would call
      # any beforeSave and afterSave cloud code hooks you have registered for this class.
      # @return [Boolean] true/false whether it was successful.
      def update!(raw: false, force: false)
        if valid? == false
          errors.full_messages.each do |msg|
            warn "[#{parse_class}] warning: #{msg}"
          end
        end
        if force == true && attribute_changes?.blank? && !new?
          # if we are forcing an update, but there are no attribute changes,
          # we should still mark the updated_at field as changed so that
          # the server updates it.
          if self.class.fields[:updated_at].present?
            self.updated_at = Time.now.utc
            self.updated_at_will_change! if respond_to?(:updated_at_will_change!)
          end
        end
        response = client.update_object(parse_class, id, attribute_updates, session_token: _session_token)
        @_last_response = response
        if response.success?
          result = response.result
          # Because beforeSave hooks can change the fields we are saving, any items that were
          # changed, are returned to us and we should apply those locally to be in sync.
          set_attributes!(result)
        end
        puts "Error updating #{self.parse_class}: #{response.error}" if response.error?
        return response if raw
        response.success?
      end

      # Save all the changes related to this object.
      # @param force [Boolean] whether to send the update even if there are no changes.
      # @return [Boolean] true/false whether it was successful.
      def update(force: false)
        return true unless attribute_changes? || force
        update!(force: force)
      end

      # Internal method to perform update with :update callbacks.
      # Called from save() for existing objects.
      # @param force [Boolean] whether to send the update even if there are no changes.
      # @return [Boolean] true/false whether it was successful.
      # @!visibility private
      def perform_update(force: false)
        return true unless attribute_changes? || force
        run_callbacks :update do
          update!(force: force)
        end
      end

      # Save the object as a new record, running all callbacks.
      # @return [Boolean] true/false whether it was successful.
      def create
        run_callbacks :create do
          body = attribute_updates
          # Forward a client-assigned objectId when a `before_create` callback
          # set it (e.g. `parse_reference precompute: true`). attribute_updates
          # excludes BASE_KEYS, so @id must be merged explicitly. Parse Server
          # accepts an objectId in the create POST body and rejects duplicates
          # with a typed error rather than silently overwriting.
          body[Parse::Model::OBJECT_ID] = @id if @id.present?
          res = client.create_object(parse_class, body, session_token: _session_token)
          # Retain the response so wrappers (e.g. synchronize_create) can
          # inspect the Parse error code on failure (notably 137 DuplicateValue).
          @_last_response = res
          unless res.error?
            result = res.result
            @id = result[Parse::Model::OBJECT_ID] || @id
            @created_at = result["createdAt"] || @created_at
            #if the object is created, updatedAt == createdAt
            @updated_at = result["updatedAt"] || result["createdAt"] || @updated_at
            # Because beforeSave hooks can change the fields we are saving, any items that were
            # changed, are returned to us and we should apply those locally to be in sync.
            set_attributes!(result)
          end
          puts "Error creating #{self.parse_class}: #{res.error}" if res.error?
          res.success?
        end
      end

      # @!visibility private
      def _session_token
        if @_session_token.respond_to?(:session_token)
          @_session_token = @_session_token.session_token
        end
        @_session_token
      end

      # @!visibility private
      def _validate_session_token!(token, action = :save)
        return nil if token.nil? # user explicitly requests no session token
        token = token.session_token if token.respond_to?(:session_token)
        return token if token.is_a?(String) && token.present?
        raise ArgumentError, "#{self.class}##{action} error: Invalid session token passed (#{token})"
      end

      # saves the object. If the object has not changed, it is a noop. If it is new,
      # we will create the object. If the object has an id, we will update the record.
      #
      # You may pass a session token to the `session` argument to perform this actions
      # with the privileges of a certain user.
      #
      # Callback order:
      # 1. before_validation / around_validation / after_validation
      # 2. before_save / around_save
      # 3. before_create or before_update / around_create or around_update
      # 4. [actual save operation]
      # 5. after_create or after_update
      # 6. after_save
      #
      # You can define before and after :save callbacks
      # autoraise: set to true will automatically raise an exception if the save fails
      # @raise {Parse::RecordNotSaved} if the save fails
      # @raise ArgumentError if a non-nil value is passed to `session` that doesn't provide a session token string.
      # @param session [String] a session token in order to apply ACLs to this operation.
      # @param autoraise [Boolean] whether to raise an exception if the save fails.
      # @param force [Boolean] whether to run callbacks and send request even if there are no changes.
      # @param validate [Boolean] whether to run validations (default: true).
      # @return [Boolean] whether the save was successful.
      def save(session: nil, autoraise: false, force: false, validate: true)
        # Prevent saving objects that have been fetched and found to be deleted
        if _deleted?
          error_msg = "Cannot save deleted object. Object with id '#{@id}' no longer exists on the server."
          raise Parse::Error::ProtocolError, error_msg
        end

        @_session_token = _validate_session_token! session, :save
        return true unless changed? || force

        # Run validations (validation callbacks are now triggered by valid? method)
        # Pass context so `on: :create` and `on: :update` options work with callbacks
        if validate
          validation_context = new? ? :create : :update
          validation_passed = valid?(validation_context)

          unless validation_passed
            if self.class.raise_on_save_failure || autoraise.present?
              raise Parse::RecordNotSaved.new(self), "Validation failed: #{errors.full_messages.join(", ")}"
            end
            return false
          end
        end

        success = false

        # Track if callbacks are halted by a before_save hook returning false
        callback_executed = false
        run_callbacks :save do
          callback_executed = true
          #first process the create/update action if any
          #then perform any relation changes that need to be performed
          success = new? ? create : perform_update(force: force)

          # if the save was successful and we have relational changes
          # let's update send those next.
          if success
            if relation_changes?
              # get the list of changed keys
              changed_attribute_keys = changed - relations.keys.map(&:to_s)
              clear_attribute_changes(changed_attribute_keys)
              success = update_relations
              if success
                changes_applied!
                clear_partial_fetch_state!
              elsif self.class.raise_on_save_failure || autoraise.present?
                raise Parse::RecordNotSaved.new(self), "Failed updating relations. #{self.parse_class} partially saved."
              end
            else
              changes_applied!
              clear_partial_fetch_state!
            end
          elsif self.class.raise_on_save_failure || autoraise.present?
            raise Parse::RecordNotSaved.new(self), "Failed to create or save attributes. #{self.parse_class} was not saved."
          end
        end #callbacks

        # If callbacks were halted (before_save returned false), return false
        return false unless callback_executed

        @_session_token = nil
        success
      end

      # Save this object and raise an exception if it fails.
      # @raise {Parse::RecordNotSaved} if the save fails
      # @raise ArgumentError if a non-nil value is passed to `session` that doesn't provide a session token string.
      # @param session (see #save)
      # @param force (see #save)
      # @return (see #save)
      def save!(session: nil, force: false)
        save(autoraise: true, session: session, force: force)
      end

      # Returns true if this object has been fetched and found to be deleted from the server.
      # Deleted objects cannot be saved.
      # @return [Boolean] true if the object is marked as deleted
      def _deleted?
        @_deleted == true
      end

      # Delete this record from the Parse collection. Only valid if this object has an `id`.
      # This will run all the `destroy` callbacks.
      # @param session [String] a session token if you want to apply ACLs for a user in this operation.
      # @raise ArgumentError if a non-nil value is passed to `session` that doesn't provide a session token string.
      # @return [Boolean] whether the operation was successful.
      def destroy(session: nil)
        @_session_token = _validate_session_token! session, :destroy
        return false if new?
        success = false
        run_callbacks :destroy do
          res = client.delete_object parse_class, id, session_token: _session_token
          success = res.success?
          if success
            @id = nil
            changes_applied!
          elsif self.class.raise_on_save_failure
            raise Parse::RecordNotSaved.new(self), "Failed to create or save attributes. #{self.parse_class} was not saved."
          end
          # Your create action methods here
        end
        @_session_token = nil
        success
      end

      # Runs all the registered `before_save` related callbacks.
      def prepare_save!
        # With terminator configured, run_callbacks will return false if any callback returns false
        # We track if the block executes to know if callbacks were halted
        callback_success = false
        run_callbacks(:save) do
          callback_success = true
          true
        end
        callback_success
      end

      # @return [Hash] a hash of the list of changes made to this instance.
      def changes_payload
        h = attribute_updates
        if relation_changes?
          r = relation_change_operations.select { |s| s.present? }.first
          h.merge!(r) if r.present?
        end
        #h.merge!(className: parse_class) unless h.empty?
        h.as_json
      end

      alias_method :update_payload, :changes_payload

      # Generates an array with two entries for addition and removal operations. The first entry
      # of the array will contain a hash of all the change operations regarding adding new relational
      # objects. The second entry in the array is a hash of all the change operations regarding removing
      # relation objects from this field.
      # @return [Array] an array with two hashes; the first is a hash of all the addition operations and
      #  the second hash, all the remove operations.
      def relation_change_operations
        return [{}, {}] unless relation_changes?

        additions = []
        removals = []
        # go through all the additions of a collection and generate an action to add.
        relation_updates.each do |field, collection|
          if collection.additions.count > 0
            additions.push Parse::RelationAction.new(field, objects: collection.additions, polarity: true)
          end
          # go through all the additions of a collection and generate an action to remove.
          if collection.removals.count > 0
            removals.push Parse::RelationAction.new(field, objects: collection.removals, polarity: false)
          end
        end
        # merge all additions and removals into one large hash
        additions = additions.reduce({}) { |m, v| m.merge! v.as_json }
        removals = removals.reduce({}) { |m, v| m.merge! v.as_json }
        [additions, removals]
      end

      # Saves and updates all the relational changes for made to this object.
      # @return [Boolean] whether all the save or update requests were successful.
      def update_relations
        # relational saves require an id
        return false unless @id.present?
        # verify we have relational changes before we do work.
        return true unless relation_changes?
        raise "Unable to update relations for a new object." if new?
        # get all the relational changes (both additions and removals)
        additions, removals = relation_change_operations

        responses = []
        # Send parallel Parse requests for each of the items to update.
        # since we will have multiple responses, we will track it in array
        [removals, additions].threaded_each do |ops|
          next if ops.empty? #if no operations to be performed, then we are done
          responses << client.update_object(parse_class, @id, ops, session_token: _session_token)
        end
        # check if any of them ended up in error
        has_error = responses.any? { |response| response.error? }
        # if everything was ok, find the last response to be returned and update
        #their fields in case beforeSave made any changes.
        unless has_error || responses.empty?
          result = responses.last.result #last result to come back
          set_attributes!(result)
        end #unless
        has_error == false
      end

      # Performs mass assignment using a hash with the ability to modify dirty tracking.
      # This is an internal method used to set properties on the object while controlling
      # whether they are dirty tracked. Each defined property has a method defined with the
      # suffix `_set_attribute!` that can will be called if it is contained in the hash.
      # @example
      #  object.set_attributes!( {"myField" => value}, false)
      #
      #  # equivalent to calling the specific method.
      #  object.myField_set_attribute!(value, false)
      # @param hash [Hash] the hash containing all the attribute names and values.
      # @param dirty_track [Boolean] whether the assignment should be tracked in the change tracking
      #  system.
      # @return [Hash]
      def set_attributes!(hash, dirty_track = false)
        return unless hash.is_a?(Hash)
        hash.each do |k, v|
          next if k == Parse::Model::OBJECT_ID || k == Parse::Model::ID
          method = "#{k}_set_attribute!"
          send(method, v, dirty_track) if respond_to?(method)
        end
      end

      # Clears changes information on all collections (array and relations) and all
      # local attributes.
      def changes_applied!
        # find all fields that are of type :array
        fields(:array) do |key, v|
          proxy = send(key)
          # clear changes
          proxy.changes_applied! if proxy.respond_to?(:changes_applied!)
        end

        # for all relational fields,
        relations.each do |key, v|
          proxy = send(key)
          # clear changes if they support the method.
          proxy.changes_applied! if proxy.respond_to?(:changes_applied!)
        end
        changes_applied
      end
    end
  end
end
