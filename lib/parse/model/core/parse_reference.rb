# encoding: UTF-8
# frozen_string_literal: true

require "active_support/concern"
require "securerandom"

module Parse
  module Core
    # Declarative self-referential identifier field for Parse::Object
    # subclasses. When `parse_reference` is declared on a class, every newly-
    # created instance gets a string field auto-populated with the canonical
    # `"ClassName$objectId"` form via an `after_create` callback. The value
    # mirrors Parse Server's internal pointer-column format (`_p_workspace` ->
    # `"Workspace$xyz"`), which makes direct MongoDB queries, `$lookup` joins, and
    # cross-class analytics trivial: a single equality match on one column.
    #
    # Mechanics:
    #
    # * The initial `save` creates the row and returns the server-assigned
    #   objectId. An after_create callback then sets the reference field and
    #   triggers a follow-up `save` — two REST round-trips per new object.
    #   The callback is a no-op on subsequent saves once the field matches
    #   the canonical value.
    # * The DSL is opt-in. Classes that don't call `parse_reference` get no
    #   field, no callback, and no extra writes.
    # * The field is logically constant once set (objectId and parse_class
    #   are both immutable for the object). The DSL auto-installs three
    #   protections:
    #   1. `protect_fields("*", [field_name])` so non-master clients never
    #      see the column on reads.
    #   2. `guard field_name, :set_once` so once the after_create populates
    #      the field, no further write (client or master) can change it.
    #      Master-key requests do NOT bypass `:set_once` once the value is
    #      present, so a buggy migration or admin script cannot corrupt
    #      the canonical reference.
    #   3. A `before_save` callback (`_recompute_<field_name>!`) that
    #      force-recomputes the value to `"ClassName$objectId"` whenever
    #      the field's current value diverges from the canonical form. In
    #      the Parse Server `beforeSave` webhook flow this runs after
    #      `apply_field_guards!` and corrects any spoofed value that may
    #      have come from a non-gem client (other SDK, or a direct REST
    #      POST that includes a poisoned `parseReference` on create —
    #      `:set_once` allows the first write, so this callback is the
    #      belt to that suspenders).
    # * Inherits cleanly into `Parse::User`, `Parse::Installation`, and
    #   other system-class subclasses. The reference format becomes
    #   `"_User$objectId"`, `"_Installation$objectId"`, etc., matching
    #   Parse Server's own `_p_user`/`_p_installation` column format.
    # * Batch / transaction caveat: `Parse::Object.transaction` and
    #   `Parse::Object.save_all` set the server-assigned objectId via
    #   `instance_variable_set` without running the `:create` callback
    #   chain. Objects created through those paths therefore do NOT have
    #   the parse_reference auto-populated. Use the
    #   {ClassMethods#populate_parse_references!} batch helper or call
    #   `obj._assign_<field>!` manually after the transaction commits.
    #
    # == `precompute: true` — server requirements and threat model
    #
    # The `precompute: true` option client-generates the objectId in a
    # `before_create` callback and embeds both `objectId` and the canonical
    # reference in the initial POST body, eliminating the follow-up
    # `update!` that the default after_create flow issues. Two requirements
    # must hold for this to work end-to-end:
    #
    # 1. Parse Server must be started with `allowCustomObjectId: true`
    #    (`PARSE_SERVER_ALLOW_CUSTOM_OBJECT_ID=true`). Without that flag,
    #    Parse Server rejects any create whose body contains `objectId`
    #    with `error: objectId is an invalid field name` (HTTP 400, code
    #    105) before any cloud-code hooks run.
    # 2. The save must run with master-key authority. The DSL enforces
    #    this SDK-side: `_precompute_<field>!` is a no-op when the
    #    instance has a per-save session token set (`with_session` /
    #    `set_session_token`) or when no `master_key` is configured on
    #    `Parse::Client`. In either case the legacy after_create
    #    `_assign_<field>!` flow takes over, costing one extra round-trip
    #    but staying within the session's permissions. The local @id
    #    falls back to the server-assigned id (no client id is generated
    #    or forwarded), so the resulting `parseReference` is correct.
    #
    # The SDK gate protects parse-stack callers, but `allowCustomObjectId`
    # is a server-global flag — it also lets the JS SDK, iOS SDK, raw
    # REST callers, and any other client using the same Parse Server pick
    # their own `objectId` on create. That permits objectId-squatting
    # ("admin", "root", colliding with another tenant's id), id-spoofing
    # on classes whose ACL allows public create, and a few subtle CLP
    # bypass shapes when a class's class-level permissions key off
    # `objectId` patterns. To enforce master-only client objectIds across
    # ALL SDKs, register a Cloud Code `beforeSave` hook that rejects
    # client-supplied ids from non-master sessions, e.g.:
    #
    #   Parse.Cloud.beforeSave("MyClass", req => {
    #     if (req.original === undefined && req.object.id && !req.master) {
    #       throw "Client-supplied objectId not allowed";
    #     }
    #   });
    #
    # `req.original === undefined` narrows to creates (no prior state);
    # `req.object.id` is the client-supplied id; `!req.master` excludes
    # legitimate master-key creates including this gem's precompute path.
    # Apply per-class for the classes that declare
    # `parse_reference precompute: true`, or globally on every class via
    # `Parse.Cloud.beforeSave(Parse.Object, ...)` if the application has
    # no legitimate non-master custom-id use case.
    #
    # @example default field name
    #   class Post < Parse::Object
    #     parse_reference   # local :parse_reference -> remote "parseReference"
    #   end
    #   post = Post.create(title: "Hi")
    #   post.parse_reference   # => "Post$abc123"
    #
    # @example custom local name
    #   class Event < Parse::Object
    #     parse_reference :ref
    #   end
    #
    # @example custom local AND remote names
    #   class Activity < Parse::Object
    #     parse_reference :ref, field: "refKey"
    #   end
    #
    # @example works on system class subclasses (for normal Parse::Object
    #   creates -- NOT for Parse::User#signup!, which goes through a
    #   distinct REST endpoint and does not run the `:create` callback
    #   chain. On a User subclass, populate the reference manually after
    #   signup: `user._assign_parse_reference!`.)
    #   class User < Parse::User
    #     parse_reference
    #   end
    module ParseReference
      extend ActiveSupport::Concern

      # The separator between class name and object id. Matches Parse Server's
      # own pointer-column format (e.g. `_p_workspace = "Workspace$abcd1234"`).
      SEPARATOR = "$".freeze

      # Length of a Parse Server objectId. Matches the format the server itself
      # produces and what the JS/iOS SDKs generate for offline-mode local ids.
      OBJECT_ID_LENGTH = 10

      # Generate a Parse-compatible objectId: 10 characters drawn from
      # [A-Za-z0-9]. Used by the precompute path so a `before_create` callback
      # can assign `@id` (and the canonical reference string) before the
      # initial POST, eliminating the second round-trip that the default
      # after_create approach requires.
      #
      # 62^10 ≈ 8.39e17 keyspace; collision probability is negligible at any
      # practical scale. Parse Server accepts client-assigned `objectId` in
      # POST bodies (the JS/iOS SDKs use this for offline mode) and rejects
      # duplicates with a specific error code rather than silently overwriting.
      def self.generate_object_id
        SecureRandom.alphanumeric(OBJECT_ID_LENGTH)
      end

      # Build a canonical "Class$id" reference string. Returns nil if either
      # piece is blank — callers wiring this into other systems can use the
      # nil to skip writing the field.
      def self.format(parse_class, id)
        return nil if parse_class.to_s.empty? || id.to_s.empty?
        "#{parse_class}#{SEPARATOR}#{id}"
      end

      # Split a "Class$id" string into [class_name, object_id]. Returns
      # [nil, nil] for nil input; raises ArgumentError on malformed input
      # (anything else than a string containing the separator).
      def self.parse(string)
        return [nil, nil] if string.nil?
        unless string.is_a?(String) && string.include?(SEPARATOR)
          raise ArgumentError, "not a parse_reference: #{string.inspect}"
        end
        string.split(SEPARATOR, 2)
      end

      module ClassMethods
        # Declare a self-referential identifier field on this class.
        # See {Parse::Core::ParseReference} for full documentation.
        #
        # @param field_name [Symbol] local property name (default :parse_reference)
        # @param field [String, nil] remote Parse column name; defaults to the
        #   camelCased form of `field_name`
        # @param precompute [Boolean] when true, generate the objectId
        #   client-side in a `before_create` callback and embed the canonical
        #   reference in the initial POST body, eliminating the second
        #   round-trip. When false (default) the value is set via an
        #   `after_create` callback that issues a follow-up `update!`.
        # @return [Symbol] the registered field name
        def parse_reference(field_name = :parse_reference, field: nil, precompute: false,
                            index: true, unique_index: true)
          field_name = field_name.to_sym
          unless field_name.to_s =~ /\A[a-z_][a-z0-9_]*\z/i
            raise ArgumentError,
                  "parse_reference field name must match /\\A[a-z_][a-z0-9_]*\\z/i, got #{field_name.inspect}"
          end
          remote = field || field_name.to_s.camelize(:lower)
          property field_name, :string, field: remote

          # Auto-register a MongoDB index declaration for this field. The
          # synchronize_create correctness floor (CHANGELOG 4.4.0) relies on
          # a unique index on the dedup tuple — auto-registering removes
          # the operator-must-remember failure mode. The index is unique
          # AND sparse by default: sparse so that
          # `Parse.populate_parse_references!` backfill can walk rows with
          # NULL values without tripping the unique constraint on the
          # second NULL. Operators can opt out per-field:
          #   - `index: false`        — skip registration entirely
          #   - `unique_index: false` — register the index but drop the
          #     unique constraint (cheaper lookups without the dedup guarantee)
          # The declaration is inert at load time; it ships through the
          # standard `Parse::Schema::IndexMigrator` plan/apply path so the
          # writer URI + triple gate still gates actual mutation.
          if index && respond_to?(:mongo_index)
            opts = { sparse: true }
            opts[:unique] = true if unique_index
            mongo_index field_name, **opts
          end

          # Auto-install read-side hiding: clients shouldn't see the
          # internal reference column. Master/admin reads (which is how
          # analytics queries and direct Mongo lookups run) are unaffected
          # because protect_fields("*", ...) only applies to non-master
          # reads. Merge into any existing "*" protected fields rather
          # than overwriting (the underlying set_protected_fields method
          # replaces by pattern).
          if respond_to?(:protect_fields) && respond_to?(:class_permissions)
            existing = class_permissions.protected_fields_for("*") rescue []
            merged = (existing + [field_name.to_s]).uniq
            protect_fields("*", merged)
          end

          # Auto-install write-side protection: once the after_create
          # populates the value, nothing (including master) can rewrite
          # it. :set_once allows the first transition from blank to a
          # value, then locks the field forever.
          if respond_to?(:guard)
            guard field_name, :set_once
          end

          # Define a helper that computes the canonical value and writes
          # via `update!` (bypassing the user's save/create callback
          # chain so this internal bookkeeping write doesn't double-fire
          # after_save hooks the user has on the class).
          method_name = :"_assign_#{field_name}!"
          define_method(method_name) do
            return unless id.present?
            target = Parse::Core::ParseReference.format(self.class.parse_class, id)
            return if public_send(field_name) == target
            public_send("#{field_name}=", target)
            ok = update!
            unless ok
              Parse.logger&.warn(
                "[Parse::ParseReference] Failed to persist #{self.class.parse_class}##{id} " \
                "#{field_name} = #{target.inspect}; object exists without its reference field. " \
                "errors=#{errors.full_messages.inspect rescue nil}"
              )
            end
            ok
          end

          # Expose the configured field name as a class-level reader so
          # the batch-populate helper and other introspection code can
          # find it without re-parsing the class body.
          @_parse_reference_fields ||= []
          @_parse_reference_fields << field_name
          singleton_class.send(:attr_reader, :_parse_reference_fields) unless singleton_class.method_defined?(:_parse_reference_fields)

          # Register the after_create callback, but only if this exact
          # method isn't already in the callback chain. Re-declaration in a
          # subclass (or accidental double-declaration in the same class)
          # otherwise stacks multiple invocations and produces multiple
          # extra REST writes per create. The check inspects the chain by
          # filter name so it correctly handles both fresh registration
          # and inheritance from a parent that already declared.
          already_registered = _create_callbacks.any? do |cb|
            (cb.filter.to_sym rescue cb.filter) == method_name
          end
          after_create method_name unless already_registered

          # Belt-and-suspenders: on every save where the field's current
          # value diverges from the canonical "ClassName$objectId" form,
          # force-recompute it. This callback runs in two contexts:
          #
          # 1. Gem-side save flow — fires before `before_create`, so on a
          #    fresh object (id blank) it's a no-op; on a subsequent
          #    `_assign_<field>!`-triggered `update!` the value already
          #    matches so it's also a no-op.
          # 2. Parse Server `beforeSave` webhook flow — Parse::Webhooks
          #    deserializes the incoming object, runs `apply_field_guards!`
          #    (which reverts disallowed client writes per the `:set_once`
          #    guard above), then invokes `prepare_save!` which fires this
          #    `:save` callback chain. The object's id has been assigned by
          #    Parse Server at this point. If any value slipped past the
          #    guard (master-key write, or first-write on create), this
          #    callback overwrites it with the canonical value. The
          #    enforcement happens server-side regardless of which SDK
          #    originated the save.
          recompute_method = :"_recompute_#{field_name}!"
          define_method(recompute_method) do
            return unless id.present?
            target = Parse::Core::ParseReference.format(self.class.parse_class, id)
            return if target.nil?
            return if public_send(field_name) == target
            public_send("#{field_name}=", target)
          end

          already_recomputing = _save_callbacks.any? do |cb|
            cb.kind == :before && (cb.filter.to_sym rescue cb.filter) == recompute_method
          end
          before_save recompute_method unless already_recomputing

          if precompute
            precompute_method = :"_precompute_#{field_name}!"
            define_method(precompute_method) do
              # Precompute is master-key-only. Parse Server rejects a
              # client-supplied `objectId` in the create body unless its
              # `allowCustomObjectId` option is enabled, and even with that
              # global flag on, accepting client-set objectIds from
              # non-master sessions is an objectId-squatting risk
              # (attacker picks "admin", "root", or collides with another
              # tenant's id). Skip precompute when this save won't run as
              # master: an explicit per-save session token is present
              # (`with_session` / `set_session_token`), or no master key is
              # configured on the client at all. In those cases the legacy
              # after_create `_assign_<field>!` flow takes over, costing
              # one extra round-trip but staying within whatever
              # permissions the requesting session has.
              return if _session_token.present?
              return unless client.respond_to?(:master_key) && client.master_key.present?

              if id.blank?
                @id = Parse::Core::ParseReference.generate_object_id
              end
              target = Parse::Core::ParseReference.format(self.class.parse_class, id)
              # We just client-assigned @id, so the instance now satisfies
              # `pointer?` (objectId present, timestamps blank). The property
              # accessor's autofetch heuristic — and the setter's
              # prepare_for_dirty_tracking! pre-fetch — would both fire a GET
              # against an id Parse Server has not seen yet, producing a 101
              # Object not found and aborting the create. Suppress autofetch
              # for the duration of this callback's writes; the actual create
              # POST that follows includes both objectId and parse_reference,
              # so server state is unaffected.
              was_disabled = autofetch_disabled?
              disable_autofetch!
              begin
                return if public_send(field_name) == target
                public_send("#{field_name}=", target)
              ensure
                enable_autofetch! unless was_disabled
              end
            end

            already_precomputing = _create_callbacks.any? do |cb|
              (cb.filter.to_sym rescue cb.filter) == precompute_method
            end
            # before_create runs inside Parse::Object#create, AFTER the
            # save dispatcher has already chosen the create-vs-update path
            # (actions.rb:795). Setting @id here therefore cannot reroute
            # the save. `new?` remains correct because it also checks
            # @created_at, which is still nil at this point.
            before_create precompute_method unless already_precomputing
          end

          field_name
        end

        # Populate the parse_reference field for an array of already-saved
        # objects. Use after `Parse::Object.transaction` or `save_all`
        # (both of which bypass the `:create` callback chain) so the
        # canonical reference still lands in MongoDB. Each object gets an
        # individual `update!` call -- callers wanting tighter batching
        # can wrap multiple updates in their own `Parse::Object.transaction`.
        #
        # Objects that already have a populated reference, or that lack an
        # objectId, are skipped silently.
        #
        # @example
        #   posts = []
        #   Post.transaction do |batch|
        #     3.times { posts << Post.new(title: "hi").tap { |p| batch.add(p) } }
        #   end
        #   Post.populate_parse_references!(posts)   # second round-trip per object
        #
        # @param objects [Array<Parse::Object>] objects to populate
        # @return [Array<Parse::Object>] the objects that were updated
        def populate_parse_references!(objects)
          return [] if objects.nil? || objects.empty?
          fields_to_populate = Array(@_parse_reference_fields)
          return [] if fields_to_populate.empty?
          updated = []
          objects.each do |obj|
            next unless obj.is_a?(self) && obj.id.present?
            changed_any = false
            fields_to_populate.each do |field_name|
              method = :"_assign_#{field_name}!"
              next unless obj.respond_to?(method)
              before = obj.public_send(field_name)
              obj.public_send(method)
              changed_any ||= (obj.public_send(field_name) != before)
            end
            updated << obj if changed_any
          end
          updated
        end
      end
    end
  end
end
