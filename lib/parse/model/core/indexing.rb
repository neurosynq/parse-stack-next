# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Core
    # Model-declarative MongoDB index DSL. Mixed into Parse::Object so
    # subclasses can declare the indexes they expect to exist on their
    # collection. Declarations are inert at load time — they only land
    # on MongoDB when {Parse::Schema::IndexMigrator} reads them and
    # `apply_indexes!` is invoked through the writer connection.
    #
    # SECURITY POSTURE — purely declarative. No network I/O, no class
    # introspection that could leak data, no LLM-visible surface. The
    # validation rules below run at declaration time so a typo
    # surfaces as a load-time error, not a runtime surprise during
    # `rake parse:mongo:indexes:apply` in prod.
    #
    # @example Declaring indexes
    #   class Car < Parse::Object
    #     property :make, :string
    #     property :model, :string
    #     property :year, :integer
    #     property :tags, :array
    #     property :location, :geopoint
    #     belongs_to :owner, as: :user
    #
    #     mongo_index :make, :model, :year                 # compound
    #     mongo_index :vin, unique: true
    #     mongo_index :owner                               # → _p_owner (pointer auto-rewrite)
    #     mongo_geo_index :location                        # 2dsphere
    #     mongo_index :tags                                # array column
    #     # mongo_index :tags, :categories                 # REJECTED: parallel arrays
    #   end
    module Indexing
      # MongoDB limits each collection to 64 indexes total (including
      # the implicit `_id_` index). The migrator's plan phase reports
      # remaining capacity using this constant.
      MAX_INDEXES_PER_COLLECTION = 64

      # Parse-managed array columns we can know about without
      # introspecting actual data. Used by {#assert_at_most_one_array_field!}
      # to catch parallel-array compounds at declaration time even when
      # the parallel field is the `_rperm`/`_wperm` ACL array.
      PARSE_MANAGED_ARRAY_FIELDS = %w[_rperm _wperm].to_set.freeze

      # Wire-format column names that hold Parse-internal secret material
      # (password hashes, session tokens, verification tokens, auth provider
      # blobs). The DSL refuses to declare an index on any of these because
      # a queryable index on bcrypt hashes or session tokens turns
      # `$indexStats` / collection-scan access into a credential-enumeration
      # oracle. Parse Server already manages the legitimate indexes for
      # these columns (see {Parse::Schema::IndexMigrator::PARSE_MANAGED_INDEX_PATTERNS});
      # this guard exists so a typo or malicious PR can't add a new one.
      SENSITIVE_FIELDS = %w[
        _hashed_password _session_token _email_verify_token
        _perishable_token _password_history authData _auth_data
      ].freeze

      # Storage for declared indexes. Each entry is a frozen Hash with
      # the keys `:keys`, `:options`, `:declared_for` (the source-of-truth
      # symbol list from the `mongo_index` call, for diagnostics).
      # @return [Array<Hash>]
      def mongo_index_declarations
        @mongo_index_declarations ||= []
      end

      # Declare a regular (B-tree) index on one or more fields. Symbols
      # in `fields` are looked up against the class's `references` table
      # — pointers auto-rewrite to `_p_<field>` so callers think in
      # property names. Use `mongo_geo_index` for 2dsphere indexes.
      #
      # @param fields [Array<Symbol>] property names; compound indexes
      #   are formed by passing more than one. Order matters for query
      #   prefix matching (MongoDB compound-index rule).
      # @param unique [Boolean]
      # @param sparse [Boolean]
      # @param partial [Hash, nil] partial-index filter expression. Owner
      #   is responsible for lifecycle — Parse Server will not manage it.
      # @param expire_after [Integer, nil] TTL in seconds (only valid on
      #   single-field indexes per MongoDB's TTL rules).
      # @param name [String, nil] explicit index name; defaults to
      #   `field_dir_field_dir` via MongoDB's auto-naming.
      # @return [Hash] the registered declaration (frozen)
      # @raise [ArgumentError] when validation rules fail (no fields,
      #   unknown field, parallel arrays, relation field, etc.)
      def mongo_index(*fields, unique: false, sparse: false, partial: nil,
                      expire_after: nil, name: nil)
        register_index(fields, key_value: 1, unique: unique, sparse: sparse,
                       partial: partial, expire_after: expire_after, name: name)
      end

      # Sugar for a 2dsphere geospatial index. Geopoint columns are
      # stored in Mongo as GeoJSON `{ type: "Point", coordinates: [lng, lat] }`
      # which `2dsphere` indexes natively.
      def mongo_geo_index(field, sparse: false, name: nil)
        register_index([field], key_value: "2dsphere", unique: false,
                       sparse: sparse, partial: nil, expire_after: nil, name: name)
      end

      # Declare an index on a Parse Relation's join collection. Relations
      # are stored in `_Join:<field>:<ParentClass>` collections — these
      # have no Ruby model, so an `add_index :field` against the parent
      # class would index the wrong collection. This method routes the
      # declaration to the correct join-collection name, with the
      # conventional column shape: `owningId` is the parent-side foreign
      # key, `relatedId` is the related-side.
      #
      # Default: single declaration on `{owningId: 1}` — the forward
      # lookup ("what's related to this owner"), which is the dominant
      # pattern for most Parse Relation queries.
      #
      # `bidirectional: true` adds a second declaration on
      # `{relatedId: 1}` — the reverse lookup ("which owners contain
      # this related object"). For high-traffic auth patterns like
      # `Parse::Role.users`, the reverse direction is often the
      # heavier-used index.
      #
      # Uniqueness on a *single-direction* relation index is NOT
      # supported — `unique: true` on just `owningId` (or just
      # `relatedId`) would assert each owner can hold at most one
      # related, contradicting `has_many`. That mistake is rejected at
      # declaration time.
      #
      # `dedup: true` is semantically different and IS supported: it
      # registers a compound `{owningId: 1, relatedId: 1}` unique index
      # on the join collection. The compound key prevents duplicate
      # `(owner, related)` pair rows from accumulating (a real failure
      # mode under concurrent `.add` calls on a Parse Relation), without
      # constraining how many distinct relateds an owner may hold or
      # vice versa. Default off — the index buys correctness at the
      # cost of a write-time uniqueness check on every relation insert,
      # and existing collections with duplicate pairs will fail the
      # migrator's apply step until reconciled.
      #
      # @example Canonical case — role membership with dedup
      #   class Parse::Role < Parse::Object
      #     has_many :users, through: :relation
      #     mongo_relation_index :users, bidirectional: true, dedup: true
      #     # creates: _Join:users:_Role { owningId: 1 }
      #     #         _Join:users:_Role { relatedId: 1 }
      #     #         _Join:users:_Role { owningId: 1, relatedId: 1 } unique
      #   end
      #
      # @param field [Symbol] the relation field name (must be declared
      #   via `has_many :field, through: :relation`)
      # @param bidirectional [Boolean] when true, register two
      #   declarations — one each for owningId and relatedId
      # @param dedup [Boolean] when true, also register a compound
      #   `{owningId: 1, relatedId: 1}` unique index that prevents
      #   duplicate-pair membership rows
      # @param unique [Boolean] rejected — see above
      # @raise [ArgumentError] when `field` is not a declared relation
      #   or `unique:` is passed
      # @return [Array<Hash>] the registered declarations
      def mongo_relation_index(field, bidirectional: false, dedup: false, unique: false)
        if unique
          raise ArgumentError,
                "#{self}.mongo_relation_index does not support unique: — uniqueness on " \
                "a single-direction relation column breaks has_many semantics. Use " \
                "`dedup: true` for a compound `{owningId, relatedId}` unique index that " \
                "prevents duplicate-pair membership without constraining cardinality."
        end
        field = field.to_sym
        unless respond_to?(:relations) && relations.key?(field)
          raise ArgumentError,
                "#{self}.mongo_relation_index requires #{field.inspect} to be declared " \
                "via `has_many :#{field}, through: :relation`. Got non-relation field."
        end
        join_collection = "_Join:#{field}:#{parse_class}"
        decls = [register_relation_index(join_collection, "owningId", source: field)]
        decls << register_relation_index(join_collection, "relatedId", source: field) if bidirectional
        if dedup
          decls << register_relation_dedup_index(join_collection, source: field)
        end
        decls
      end

      # Dry-run reconciliation between declared indexes and what's on
      # the collection. Delegates to {Parse::Schema::IndexMigrator}.
      # @return [Hash{String=>Hash}] keyed by collection name; one entry
      #   per unique target collection across the declaration list
      #   (parent collection + any `_Join:*` collections from
      #   `mongo_relation_index`).
      def indexes_plan
        Parse::Schema::IndexMigrator.new(self).plan
      end

      # Apply additive index changes via the writer connection. Pass
      # `drop: true` to also drop orphan indexes; each drop carries its
      # own audit log and confirmation envelope.
      # @return [Hash] see {Parse::Schema::IndexMigrator#apply!}
      def apply_indexes!(drop: false)
        Parse::Schema::IndexMigrator.new(self).apply!(drop: drop)
      end

      private

      def register_index(fields, key_value:, unique:, sparse:, partial:,
                         expire_after:, name:)
        fields = fields.flatten.map(&:to_sym)
        if fields.empty?
          raise ArgumentError, "#{self}.mongo_index requires at least one field name"
        end
        if expire_after && fields.size > 1
          raise ArgumentError,
                "#{self}.mongo_index expire_after is only valid on single-field indexes; " \
                "got #{fields.inspect}"
        end

        # Sensitive-field check runs BEFORE wire-key resolution so that
        # non-`_`-prefixed Parse-internal columns (e.g. `authData`) are
        # caught even when they aren't declared as properties on the
        # subclass — otherwise `resolve_index_field_name` would reject
        # them as "unknown field" and the operator might add the property
        # to silence the error, defeating the guard.
        assert_no_sensitive_raw_fields!(fields)

        wire_keys = fields.each_with_object({}) do |sym, h|
          h[resolve_index_field_name(sym)] = key_value
        end
        assert_not_id_field!(wire_keys)
        assert_not_sensitive_field!(wire_keys)
        assert_at_most_one_array_field!(fields, wire_keys)

        declaration = {
          keys:          wire_keys,
          options:       {
            unique: unique, sparse: sparse,
            partial_filter: partial, expire_after: expire_after, name: name,
          }.reject { |_, v| v.nil? || v == false }.freeze,
          declared_for:  fields.dup.freeze,
          collection:    nil, # nil sentinel means "use the model's parse_class"
        }.freeze

        if mongo_index_declarations.any? { |d| d[:keys] == declaration[:keys] && d[:options] == declaration[:options] && d[:collection] == declaration[:collection] }
          # Idempotent redeclaration — same class re-opened or sub-class
          # inherited; don't accumulate duplicates.
          return declaration
        end
        mongo_index_declarations << declaration
        declaration
      end

      # Register one direction of a relation index. The declaration
      # carries an explicit `:collection` override so the migrator routes
      # the apply call to the `_Join:*` collection name instead of the
      # model's `parse_class`.
      def register_relation_index(collection, column, source:)
        decl = {
          keys:         { column => 1 }.freeze,
          options:      {}.freeze,
          declared_for: [source].freeze,
          collection:   collection,
        }.freeze
        if mongo_index_declarations.any? { |d| d[:keys] == decl[:keys] && d[:collection] == collection }
          return decl
        end
        mongo_index_declarations << decl
        decl
      end

      # Register the compound `{owningId: 1, relatedId: 1}` unique index
      # on a relation join collection — the dedup form of
      # `mongo_relation_index`. Compound uniqueness on both columns
      # together is the *correctness* form: it forbids duplicate
      # `(owner, related)` pair rows from accumulating without
      # constraining how many distinct relateds an owner may hold.
      # That is semantically different from `unique:` on a single
      # column (which `mongo_relation_index` continues to reject).
      def register_relation_dedup_index(collection, source:)
        decl = {
          keys:         { "owningId" => 1, "relatedId" => 1 }.freeze,
          options:      { unique: true }.freeze,
          declared_for: [source].freeze,
          collection:   collection,
        }.freeze
        if mongo_index_declarations.any? { |d| d[:keys] == decl[:keys] && d[:options] == decl[:options] && d[:collection] == collection }
          return decl
        end
        mongo_index_declarations << decl
        decl
      end

      # Translate a property symbol to the wire-format column name a
      # MongoDB index must reference. Pointer fields (declared via
      # `belongs_to`) live in Mongo at `_p_<field>` and the SDK already
      # tracks them in the class's `references` map. Relations
      # (declared via `has_many :foo, through: :relation`) live in a
      # separate `_Join:<field>:<ClassName>` collection and CAN NOT be
      # indexed on the parent — reject those at declaration.
      def resolve_index_field_name(sym)
        sym = sym.to_sym
        if respond_to?(:relations) && relations.key?(sym)
          raise ArgumentError,
                "#{self}.mongo_index cannot index #{sym.inspect}: it is a Parse Relation, " \
                "stored in a separate _Join:#{sym}:#{self} collection. Index on the join " \
                "collection directly via Parse::MongoDB.create_index if needed."
        end
        if respond_to?(:references) && references.key?(sym)
          # Pointer field — Parse stores as _p_<field>
          return "_p_#{references_field_for(sym)}"
        end
        # Regular property or already-wire-format string (`_rperm` etc.)
        wire = if respond_to?(:field_map) && field_map[sym]
            field_map[sym].to_s
          else
            sym.to_s
          end
        # Sanity check: the field should be declared, OR start with an
        # underscore (internal Parse column the operator is targeting
        # intentionally), OR be a valid property name.
        unless internal_or_declared?(sym, wire)
          raise ArgumentError,
                "#{self}.mongo_index references unknown field #{sym.inspect}. " \
                "Declare the property first (`property #{sym.inspect}, :string`) " \
                "or pass an internal column name like :_rperm explicitly."
        end
        wire
      end

      # The `references` map stores `parse_field => target_class_name`.
      # For pointer auto-rewrite we want the wire-format pointer column
      # (`_p_<parseField>`), so we look up the parse field name matching
      # the symbol passed to `mongo_index`.
      def references_field_for(sym)
        # `references` is keyed by the wire-format field. For
        # `belongs_to :owner, as: :user` the entry is `owner => "_User"`,
        # so the symbol matches the key directly.
        if respond_to?(:field_map) && field_map[sym]
          field_map[sym].to_s
        else
          sym.to_s
        end
      end

      def internal_or_declared?(sym, wire)
        return true if PARSE_MANAGED_ARRAY_FIELDS.include?(wire)
        return true if wire.start_with?("_")
        return true if respond_to?(:fields) && fields.key?(sym)
        return true if respond_to?(:attributes) && attributes.key?(sym)
        false
      end

      # MongoDB's primary key index (`_id_`, on the `_id` column) is
      # auto-created and auto-maintained for every collection. Declaring
      # an additional index on `_id` is at best redundant (same key as
      # the primary) and at worst conflicts with the unique constraint.
      # The migrator already protects `_id_` from drop via
      # `PARSE_MANAGED_INDEX_PATTERNS`; this guard prevents the
      # corresponding mistake on the create side at class load.
      def assert_not_id_field!(wire_keys)
        if wire_keys.keys.include?("_id")
          raise ArgumentError,
                "#{self}: cannot declare an index on `_id` — MongoDB's primary key " \
                "index (`_id_`) is auto-managed and protected from modification."
        end
      end

      # Refuse to declare an index against any Parse-internal secret column
      # (see {SENSITIVE_FIELDS}). The migrator's drop-protection list
      # ({Parse::Schema::IndexMigrator::PARSE_MANAGED_INDEX_PATTERNS}) only
      # blocks *removal* of existing Parse-managed indexes; it does not
      # prevent CREATION of a new index targeting bcrypt hashes / session
      # tokens / verification tokens. Refuse those at declaration time so a
      # typo (`mongo_index :_hashed_password`) or malicious change does not
      # silently install a credential-enumeration oracle.
      def assert_not_sensitive_field!(wire_keys)
        sensitive = wire_keys.keys & SENSITIVE_FIELDS
        return if sensitive.empty?
        raise_sensitive_field_error!(sensitive)
      end

      # Pre-resolve guard for sensitive raw field symbols. Catches cases
      # like `mongo_index :authData` where the field is a Parse-internal
      # column but not `_`-prefixed (so `internal_or_declared?` would
      # otherwise reject it as "unknown" and the operator might add a
      # benign-looking `property :authData, :hash` to silence that error,
      # which would then pass through to `resolve_index_field_name`
      # without ever hitting the wire-key denylist).
      def assert_no_sensitive_raw_fields!(fields)
        names = fields.map(&:to_s)
        sensitive = names & SENSITIVE_FIELDS
        return if sensitive.empty?
        raise_sensitive_field_error!(sensitive)
      end

      def raise_sensitive_field_error!(sensitive)
        raise ArgumentError,
              "#{self}.mongo_index cannot target sensitive Parse-internal columns: " \
              "#{sensitive.inspect}. These hold password hashes, session tokens, or " \
              "verification tokens; a queryable index would turn $indexStats / " \
              "collection-scan access into a credential-enumeration oracle. Parse " \
              "Server manages the legitimate indexes on these columns itself."
      end

      # MongoDB allows at most one array-typed field per compound index
      # ("cannot index parallel arrays" — server error). Catch it at
      # declaration time so a `mongo_index :tags, :categories`-style
      # mistake fails when the class is loaded, not when the migrator
      # tries to apply it.
      def assert_at_most_one_array_field!(field_syms, wire_keys)
        return if field_syms.size <= 1
        pairs = field_syms.zip(wire_keys.keys)
        arrays = pairs.select { |sym, wire| array_typed?(sym, wire) }
        if arrays.size > 1
          names = arrays.map { |sym, _| sym }
          raise ArgumentError,
                "#{self}.mongo_index cannot combine multiple array-typed fields " \
                "(#{names.inspect}) in a compound index — MongoDB rejects " \
                "parallel arrays. Index each array separately."
        end
      end

      def array_typed?(sym, wire)
        return true if PARSE_MANAGED_ARRAY_FIELDS.include?(wire)
        return true if respond_to?(:fields) && fields[sym] == :array
        false
      end
    end
  end
end
