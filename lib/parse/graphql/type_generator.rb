# encoding: UTF-8
# frozen_string_literal: true

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

      # Generate types for a list of models in one call. Two-pass:
      # creates empty stub classes for every model first so cross-class
      # references resolve regardless of declaration order.
      #
      # @param model_classes [Array<Class>] Parse::Object subclasses.
      # @return [Hash{String => Class}] registry of generated types
      #   keyed by Parse class name.
      def self.generate_all(model_classes)
        registry = {}
        # Pass 1: stub classes registered by parse_class name.
        model_classes.each do |model|
          validate!(model)
          registry[model.parse_class] = build_stub(model)
        end
        # Pass 2: populate fields. Cross-references now resolve.
        model_classes.each do |model|
          new(model, registry: registry, _prebuilt: registry[model.parse_class]).populate_fields
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
        details = collisions.map { |gql, parse| "#{gql} ← #{parse.join(', ')}" }.join('; ')
        raise "Parse::GraphQL::TypeGenerator: graphql_name collisions: #{details}. " \
              "Parse class names that differ only by underscores collapse to the same " \
              "GraphQL type name. Rename or generate the conflicting classes separately."
      end

      # Generate a single type. If the model has belongs_to / has_many
      # references to other Parse classes, those targets must already be
      # in the registry — otherwise an error is raised at field-emit
      # time. Prefer `generate_all` when you have a graph of models.
      #
      # @param model_class [Class] a Parse::Object subclass.
      # @param registry [Hash, nil] shared registry; mutated in place.
      # @return [Class] anonymous `GraphQL::Schema::Object` subclass.
      def self.generate(model_class, registry: nil)
        validate!(model_class)
        registry ||= {}
        stub = registry[model_class.parse_class] ||= build_stub(model_class)
        new(model_class, registry: registry, _prebuilt: stub).populate_fields
        stub
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

      def initialize(model_class, registry:, _prebuilt:)
        @model_class = model_class
        @registry = registry
        @klass = _prebuilt
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
          target = registry_lookup!(target_class_name)
          @klass.field(accessor, target, null: true)
        end
      end

      def emit_has_one_fields
        return unless @model_class.respond_to?(:has_one_associations)
        @model_class.has_one_associations.each do |name, meta|
          target = registry_lookup!(meta[:target_class])
          @klass.field(name, target, null: true)
        end
      end

      def emit_has_many_fields
        return unless @model_class.respond_to?(:has_many_associations)
        @model_class.has_many_associations.each do |name, meta|
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
