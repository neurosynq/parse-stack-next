# encoding: UTF-8
# frozen_string_literal: true

require_relative "../pipeline_security"

module Parse
  module GraphQL
    # Generates `GraphQL::Schema::Object` subclasses from Parse::Object
    # subclasses by reading the class-level property and association
    # registries: `fields`, `field_map`, `references` (belongs_to),
    # `has_one_associations`, `has_many_associations`, and `relations`.
    #
    # v1 scope: type shape only. Default graphql-ruby field resolution
    # invokes the same-named method on the underlying Ruby object, and
    # Parse::Object subclasses already expose typed accessors
    # (`song.album`, `band.fans`, etc.) — so no resolvers are emitted.
    # Pagination arguments, Loaders, and Relay connections are deferred
    # until query/mutation passthrough lands (TODO §7).
    #
    # == Schema shape, not an authorization layer
    #
    # The generated types describe the shape of a Parse class. They do not
    # authorize anything. Default graphql-ruby resolution reads whatever is
    # on the object handed to the resolver, so the resolvers (or the objects
    # passed to them) must enforce ACL, CLP, and protectedFields for the
    # requesting user. The usual way is to resolve through queries run with
    # that user's session token, so Parse Server applies its own checks.
    # Omitting a field from a type does not stop a resolver from loading or
    # returning it through another path.
    #
    # == Field policy
    #
    # Output is deterministic: the same model and the same options always
    # produce the same fields. Without `protected_fields: :fetch`, no CLP
    # cache or ambient state is consulted.
    #
    # * Credential denylist (always on). Session tokens, auth data,
    #   passwords, device tokens, and every column in
    #   {Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST} (see
    #   {SENSITIVE_FIELD_NAMES}) are dropped, matched by local accessor or
    #   wire name. The denylist only keeps known credential columns out; it
    #   is not a substitute for protectedFields.
    # * `exclude_fields:` drops caller-listed fields.
    # * `protected_fields:` applies the class's public (`"*"`)
    #   protectedFields, only when supplied or explicitly fetched. With the
    #   default (`nil`) no protectedFields lookup happens at all, so a field
    #   such as `_User.email` is emitted unless it is excluded or supplied
    #   here. Pass a Hash (`{ "ClassName" => [:field, ...] }`) to supply the
    #   lists, or `:fetch` to load each class's CLP from the server through
    #   `Parse::CLPScope.protected_fields_for` (a schema request per class,
    #   which includes `Parse::CLPScope.default_protected_fields`). A failed
    #   fetch raises {ProtectedFieldsUnavailable}.
    # * `include_sensitive:` emits a field the denylist or protectedFields
    #   would drop. `exclude_fields:` still wins over it.
    #
    # has_many fields are emitted as plain unpaginated lists (`[Type]`), and
    # nested selections are not bounded here. A schema built from these
    # types should set `max_depth` and `max_complexity` (graphql-ruby schema
    # class methods) so a single query cannot walk an unbounded object graph.
    #
    # Cross-class references (pointers, has_many) require all referenced
    # model types to be in the registry BEFORE field emission. Use
    # `generate_all` to codegen a list of models in one call (two-pass:
    # stub classes first, then add fields), or `generate` with an
    # explicit `registry:` hash if you want incremental control.
    class TypeGenerator
      # Maps Parse property `:type` symbols to graphql-ruby built-ins.
      # Cross-class references (`:pointer`, `:relation`) are NOT in this
      # map — they need the target class and are handled per-field.
      # Nil mappings fall through to the JSON scalar with a warning.
      SCALAR_TYPE_MAP = {
        string: ::GraphQL::Types::String,
        integer: ::GraphQL::Types::Int,
        float: ::GraphQL::Types::Float,
        # A :number property may hold fractional values, which GraphQL's
        # 32-bit Int cannot represent, so it is exposed as Float.
        number: ::GraphQL::Types::Float,
        boolean: ::GraphQL::Types::Boolean,
        date: ::GraphQL::Types::ISO8601DateTime,
        timezone: ::GraphQL::Types::String,
        phone: ::GraphQL::Types::String,
        email: ::GraphQL::Types::String,
        # Parse Bytes is a `{__type: Bytes, base64: ...}` wrapper, not a
        # bare string — the accessor returns the wrapped object, so
        # falling through to the JSON scalar (with a warn) is safer than
        # ::String.to_s on the hash. Subscribers needing structured byte
        # access should declare a `:string` property containing the base64.
        bytes: nil,
        polygon: nil, # JSON fallback (GeoJSON-shaped, multi-ring)
        # Parse vector columns are bounded-length Float arrays
        # (embeddings). Emit as a typed list of Floats, not JSON.
        vector: [::GraphQL::Types::Float],
        array: nil,   # JSON fallback (no element type known)
        object: nil,  # JSON fallback
      }.freeze

      # Property types that are deliberately omitted. ACL is internal
      # authz metadata; exposing it via GraphQL would leak authorization
      # shape into clients. The objectId is exposed under the canonical
      # `id: ID` field separately.
      OMITTED_TYPES = %i[acl].freeze

      # Credential field names that are never emitted, whatever their
      # declared type. Compared against both the local accessor and the
      # Parse wire name. Columns starting with `_auth_data_` are also
      # dropped.
      SENSITIVE_FIELD_NAMES = (
        %w[session_token sessionToken auth_data authData password
           device_token deviceToken] +
        Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST
      ).to_set.freeze

      # Prefixes of credential columns that are never emitted.
      SENSITIVE_FIELD_PREFIXES = Parse::PipelineSecurity::INTERNAL_FIELDS_PREFIX_DENYLIST

      # Raised when `protected_fields: :fetch` was requested and a class's
      # CLP could not be loaded. The generator refuses to emit the type
      # rather than emit fields the caller asked to have filtered.
      class ProtectedFieldsUnavailable < StandardError; end

      # Generate types for a list of models in one call. Two-pass:
      # creates empty stub classes for every model first so cross-class
      # references resolve regardless of declaration order.
      #
      # The result is a schema shape, not an authorization layer: resolvers
      # must enforce ACL, CLP, and protectedFields for the requesting user
      # (for example by resolving through queries run with that user's
      # session token). has_many fields are unpaginated lists, so set
      # `max_depth` and `max_complexity` on the schema.
      #
      # @param model_classes [Array<Class>] Parse::Object subclasses.
      # @param include_sensitive [Array<Symbol, String>] fields to emit even
      #   though they are in {SENSITIVE_FIELD_NAMES} or the class's public
      #   protectedFields. Matched by local accessor or wire name.
      # @param exclude_fields [Array<Symbol, String>, Hash] fields never to
      #   emit. An Array applies to every class; a Hash maps a Parse class
      #   name or model class to that class's Array. Matched by local
      #   accessor or wire name, and applied even over `include_sensitive:`.
      # @param protected_fields [nil, :fetch, Hash] source of each class's
      #   public protectedFields. `nil` (default) performs no lookup.
      #   `:fetch` loads each class's CLP from the server and raises
      #   {ProtectedFieldsUnavailable} when it cannot. A Hash maps a Parse
      #   class name or model class to its protected field list.
      # @return [Hash{String => Class}] registry of generated types
      #   keyed by Parse class name.
      # @raise [ProtectedFieldsUnavailable] when `protected_fields: :fetch`
      #   cannot load a class's CLP.
      def self.generate_all(model_classes, include_sensitive: [], exclude_fields: [], protected_fields: nil)
        validate_protected_fields_option!(protected_fields)
        registry = {}
        # Pass 1: stub classes registered by parse_class name.
        model_classes.each do |model|
          validate!(model)
          registry[model.parse_class] = build_stub(model)
        end
        # Pass 2: populate fields. Cross-references now resolve.
        model_classes.each do |model|
          new(model, registry: registry, _prebuilt: registry[model.parse_class],
                     include_sensitive: include_sensitive,
                     exclude_fields: exclude_fields,
                     protected_fields: protected_fields).populate_fields
        end
        detect_name_collisions!(registry)
        registry
      end

      # graphql-ruby requires unique `graphql_name` across the schema.
      # `build_stub` strips underscores so `_User` and `User` collapse
      # to the same name. Raise a clear error rather than letting
      # graphql-ruby's `DuplicateNamesError` surface at schema-build
      # time, which doesn't say which Parse classes collided.
      def self.detect_name_collisions!(registry)
        by_gql_name = registry.each_with_object({}) do |(parse_name, type), acc|
          (acc[type.graphql_name] ||= []) << parse_name
        end
        collisions = by_gql_name.select { |_, names| names.size > 1 }
        return if collisions.empty?
        details = collisions.map { |gql, parse| "#{gql} ← #{parse.join(", ")}" }.join("; ")
        raise "Parse::GraphQL::TypeGenerator: graphql_name collisions: #{details}. " \
              "Parse class names that differ only by underscores collapse to the same " \
              "GraphQL type name. Rename or generate the conflicting classes separately."
      end

      # Generate a single type. If the model has belongs_to / has_many
      # references to other Parse classes, those targets must already be
      # in the registry — otherwise an error is raised at field-emit
      # time. Prefer `generate_all` when you have a graph of models.
      #
      # The result is a schema shape, not an authorization layer; see
      # {generate_all}.
      #
      # @param model_class [Class] a Parse::Object subclass.
      # @param registry [Hash, nil] shared registry; mutated in place.
      # @param include_sensitive [Array<Symbol, String>] see {generate_all}.
      # @param exclude_fields [Array<Symbol, String>, Hash] see {generate_all}.
      # @param protected_fields [nil, :fetch, Hash] see {generate_all}.
      # @return [Class] anonymous `GraphQL::Schema::Object` subclass.
      # @raise [ProtectedFieldsUnavailable] see {generate_all}.
      def self.generate(model_class, registry: nil, include_sensitive: [], exclude_fields: [], protected_fields: nil)
        validate!(model_class)
        validate_protected_fields_option!(protected_fields)
        registry ||= {}
        stub = registry[model_class.parse_class] ||= build_stub(model_class)
        new(model_class, registry: registry, _prebuilt: stub,
                         include_sensitive: include_sensitive,
                         exclude_fields: exclude_fields,
                         protected_fields: protected_fields).populate_fields
        stub
      end

      def self.validate_protected_fields_option!(value)
        return if value.nil? || value == :fetch || value.is_a?(Hash)
        raise ArgumentError,
              "Parse::GraphQL::TypeGenerator: protected_fields: must be nil, :fetch, " \
              "or a Hash of class name => field list, got #{value.inspect}"
      end

      # Look up a per-class option keyed by Parse class name (String or
      # Symbol) or by the model class itself.
      def self.per_class_value(map, model_class)
        name = model_class.parse_class
        [name, name.to_sym, model_class].each do |key|
          return map[key] if map.key?(key)
        end
        nil
      end

      def self.validate!(model_class)
        unless model_class.is_a?(Class) && model_class < Parse::Object
          raise ArgumentError,
                "Parse::GraphQL::TypeGenerator requires a Parse::Object subclass, got #{model_class.inspect}"
        end
      end

      def self.build_stub(model_class)
        type_name = model_class.parse_class.tr("_", "")
        description_text = "Generated GraphQL type for Parse class #{model_class.parse_class}."
        Class.new(::GraphQL::Schema::Object) do
          graphql_name type_name
          description description_text
        end
      end

      def initialize(model_class, registry:, _prebuilt:, include_sensitive: [],
                     exclude_fields: [], protected_fields: nil)
        @model_class = model_class
        @registry = registry
        @klass = _prebuilt
        @include_sensitive = Array(include_sensitive).map(&:to_s).to_set
        excluded = exclude_fields.is_a?(Hash) ? self.class.per_class_value(exclude_fields, model_class) : exclude_fields
        @exclude_fields = Array(excluded).map(&:to_s).to_set
        @protected_fields_option = protected_fields
      end

      def populate_fields
        emit_scalar_fields
        emit_belongs_to_fields
        emit_has_one_fields
        emit_has_many_fields
        @klass
      end

      private

      # Iterate over local accessor names from field_map so we never
      # register the same field twice (Parse stores both local and
      # remote names in `fields`).
      def emit_scalar_fields
        skip_keys = pointer_field_keys | relation_field_keys | array_assoc_field_keys
        emitted = {}

        @model_class.field_map.each do |local_key, _remote_field|
          next if skip_keys.include?(local_key)
          next if withheld?(local_key)
          parse_type = @model_class.fields[local_key]
          next if parse_type.nil?
          next if OMITTED_TYPES.include?(parse_type)

          gql_type = scalar_graphql_type(parse_type, local_key)
          next if gql_type.nil?

          # objectId → expose as canonical `id: ID!` per GraphQL idiom.
          if local_key == :id
            next if emitted[:id]
            @klass.field :id, ::GraphQL::Types::ID, null: false
            emitted[:id] = true
          else
            next if emitted[local_key]
            @klass.field(local_key, gql_type, null: true)
            emitted[local_key] = true
          end
        end
      end

      def emit_belongs_to_fields
        @model_class.references.each do |parse_field, target_class_name|
          accessor = field_to_accessor(parse_field)
          next if withheld?(accessor)
          target = registry_lookup!(target_class_name)
          @klass.field(accessor, target, null: true)
        end
      end

      def emit_has_one_fields
        return unless @model_class.respond_to?(:has_one_associations)
        @model_class.has_one_associations.each do |name, meta|
          next if withheld?(name)
          target = registry_lookup!(meta[:target_class])
          @klass.field(name, target, null: true)
        end
      end

      def emit_has_many_fields
        return unless @model_class.respond_to?(:has_many_associations)
        @model_class.has_many_associations.each do |name, meta|
          next if withheld?(name)
          target = registry_lookup!(meta[:target_class])
          @klass.field(name, [target], null: true)
        end
      end

      # -----------------------------------------------------------------
      # helpers
      # -----------------------------------------------------------------

      def scalar_graphql_type(parse_type, field_name)
        case parse_type
        when :file then Parse::GraphQL::Types::ParseFile
        when :geopoint then Parse::GraphQL::Types::ParseGeoPoint
        when :pointer, :relation
          nil # handled by emit_belongs_to_fields / emit_has_many_fields
        else
          mapped = SCALAR_TYPE_MAP[parse_type]
          return mapped unless mapped.nil?
          # nil mapping → JSON fallback. Warn so authors know to narrow.
          warn "[Parse::GraphQL] #{@model_class.parse_class}.#{field_name}: " \
               "Parse type #{parse_type.inspect} has no specific GraphQL " \
               "type; emitting as JSON scalar."
          Parse::GraphQL::Types::JSON
        end
      end

      # True when a field must not be emitted. Order: an explicit
      # `exclude_fields:` entry always drops the field; `include_sensitive:`
      # then keeps it; otherwise a credential name or a public protectedField
      # from the `protected_fields:` source drops it.
      def withheld?(local_key)
        local = local_key.to_s
        remote = (@model_class.field_map[local_key.to_sym] || local).to_s
        names = [local, remote]
        return true if names.any? { |n| @exclude_fields.include?(n) }
        return false if names.any? { |n| @include_sensitive.include?(n) }
        return true if names.any? { |n| sensitive_name?(n) }
        names.any? { |n| public_protected_fields.include?(n) }
      end

      def sensitive_name?(name)
        SENSITIVE_FIELD_NAMES.include?(name) ||
          SENSITIVE_FIELD_PREFIXES.any? { |prefix| name.start_with?(prefix) }
      end

      # Public protectedFields for this class from the explicit
      # `protected_fields:` source. `nil` performs no lookup, a Hash supplies
      # the list, and `:fetch` loads the CLP from the server.
      def public_protected_fields
        return @public_protected_fields if defined?(@public_protected_fields)
        list = case @protected_fields_option
               when nil then []
               when :fetch then fetch_public_protected_fields
               when Hash then self.class.per_class_value(@protected_fields_option, @model_class)
               end
        @public_protected_fields = Array(list).map(&:to_s).to_set
      end

      # Loads the class's CLP through Parse::CLPScope, which the caller opted
      # into with `protected_fields: :fetch`. Parse::CLPScope records a failed
      # schema request as unresolvable and reports an empty protected set for
      # it, so resolvability is checked first and a failure raises instead of
      # emitting every field.
      def fetch_public_protected_fields
        class_name = @model_class.parse_class
        evaluation = Parse::CLPScope.evaluate_access(class_name, :get, claims: ["*"], authenticated: false)
        if evaluation.reason == :clp_unresolvable
          raise ProtectedFieldsUnavailable,
                "Parse::GraphQL::TypeGenerator: could not load the CLP for #{class_name} " \
                "(protected_fields: :fetch). Check the schema request, or supply " \
                "protected_fields: as a Hash."
        end
        # strict: an entry that expires and fails to refetch after the check
        # above raises instead of reading as "nothing protected".
        Parse::CLPScope.protected_fields_for(class_name, ["*"], strict: true)
      rescue ProtectedFieldsUnavailable
        raise
      rescue StandardError => e
        raise ProtectedFieldsUnavailable,
              "Parse::GraphQL::TypeGenerator: could not load protectedFields for " \
              "#{class_name} (protected_fields: :fetch): #{e.class}: #{e.message}"
      end

      def registry_lookup!(target_class_name)
        target = @registry[target_class_name]
        if target.nil?
          raise "Parse::GraphQL::TypeGenerator: no generated type found for " \
                "#{target_class_name.inspect}. Call generate_all with all " \
                "referenced models, or generate #{target_class_name} first " \
                "into the shared `registry:` hash."
        end
        target
      end

      def pointer_field_keys
        return @pointer_field_keys if defined?(@pointer_field_keys)
        # references stores parse_field => target. Map to local accessors.
        @pointer_field_keys = @model_class.references.keys.map do |parse_field|
          field_to_accessor(parse_field)
        end.to_set
      end

      def relation_field_keys
        @relation_field_keys ||= @model_class.relations.keys.map(&:to_sym).to_set
      end

      # `has_many through: :array` stores the field as `:array` in
      # `fields` — exclude it from scalar emission so it's not emitted
      # twice (once as JSON, once as `[Type]`).
      def array_assoc_field_keys
        return @array_assoc_field_keys if defined?(@array_assoc_field_keys)
        keys = []
        if @model_class.respond_to?(:has_many_associations)
          @model_class.has_many_associations.each_value do |meta|
            keys << meta[:field] if meta[:storage] == :array && meta[:field]
          end
        end
        @array_assoc_field_keys = keys.map(&:to_sym).to_set
      end

      # Reverse field_map: parse_field (remote) → local accessor symbol.
      def field_to_accessor(parse_field)
        @model_class.field_map.each do |local, remote|
          return local if remote.to_sym == parse_field.to_sym
        end
        parse_field.to_sym
      end
    end
  end
end
