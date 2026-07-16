# encoding: UTF-8
# frozen_string_literal: true

module Parse
  # Schema introspection and migration tools for Parse Server.
  # Provides utilities to compare local Ruby models with server schema,
  # generate migration scripts, and manage schema changes.
  #
  # @example Inspecting server schema
  #   schema = Parse::Schema.fetch("Song")
  #   puts schema.fields  # => { "title" => "String", "duration" => "Number" }
  #
  # @example Comparing local model to server
  #   diff = Parse::Schema.diff(Song)
  #   puts diff.missing_on_server  # Fields in model but not on server
  #   puts diff.missing_locally    # Fields on server but not in model
  #
  # @example Generating migration
  #   migration = Parse::Schema.migration(Song)
  #   migration.apply!  # Apply changes to server
  #
  module Schema
    # Opt-in default Class Level Permissions applied to NEWLY-CREATED
    # classes during {Schema::Migration#apply!}. Only used when the
    # model class does not declare its own CLPs via
    # `set_class_level_permissions`. Existing server classes are NEVER
    # rewritten by this setting — the migrator only emits
    # `classLevelPermissions` on the initial `create_schema` call.
    #
    # Default is `nil` (no CLPs sent — Parse Server's wide-open default
    # applies). Setting this to a restrictive Hash (e.g. require master
    # key, or require an authenticated user) gives integrators a single
    # toggle to make new classes safe-by-default without touching every
    # model.
    #
    # @example Lock new classes to authenticated reads + master-key writes
    #   Parse::Schema.default_class_level_permissions = {
    #     "find"     => { "requiresAuthentication" => true },
    #     "get"      => { "requiresAuthentication" => true },
    #     "count"    => { "requiresAuthentication" => true },
    #     "create"   => {},
    #     "update"   => {},
    #     "delete"   => {},
    #     "addField" => {},
    #   }
    #
    # @return [Hash, nil]
    @default_class_level_permissions = nil
    class << self
      attr_accessor :default_class_level_permissions
    end

    # Parse field type mappings to Ruby types
    TYPE_MAP = {
      "String" => :string,
      "Number" => :integer,
      "Boolean" => :boolean,
      "Date" => :date,
      "File" => :file,
      "GeoPoint" => :geopoint,
      "Polygon" => :polygon,
      "Array" => :array,
      "Object" => :object,
      "Pointer" => :pointer,
      "Relation" => :relation,
      "Bytes" => :bytes,
    }.freeze

    # Reverse mapping from Ruby types to Parse types
    REVERSE_TYPE_MAP = {
      string: "String",
      integer: "Number",
      float: "Number",
      boolean: "Boolean",
      date: "Date",
      file: "File",
      geopoint: "GeoPoint",
      geo_point: "GeoPoint",
      polygon: "Polygon",
      array: "Array",
      object: "Object",
      pointer: "Pointer",
      relation: "Relation",
      bytes: "Bytes",
      acl: "ACL",
    }.freeze

    class << self
      # Fetch all schemas from the Parse Server.
      # @param client [Parse::Client] optional client to use
      # @return [Array<SchemaInfo>] array of schema information objects
      def all(client: nil)
        client ||= Parse.client
        response = client.schemas
        return [] unless response.success?

        results = response.result.is_a?(Hash) ? response.result["results"] : response.result
        (results || []).map { |data| SchemaInfo.new(data) }
      end

      # Fetch schema for a specific class.
      # @param class_name [String, Class] the Parse class name or model class
      # @param client [Parse::Client] optional client to use
      # @return [SchemaInfo, nil] the schema info or nil if not found
      def fetch(class_name, client: nil)
        class_name = class_name.parse_class if class_name.respond_to?(:parse_class)
        client ||= Parse.client
        response = client.schema(class_name)
        return nil unless response.success?
        SchemaInfo.new(response.result)
      end

      # Compare a local Parse::Object model with its server schema.
      # @param model_class [Class] a Parse::Object subclass
      # @param client [Parse::Client] optional client to use
      # @return [SchemaDiff] the differences between local and server schema
      def diff(model_class, client: nil)
        raise ArgumentError, "Expected a Parse::Object subclass" unless model_class < Parse::Object

        server_schema = fetch(model_class.parse_class, client: client)
        SchemaDiff.new(model_class, server_schema)
      end

      # Generate a migration for a model class.
      # @param model_class [Class] a Parse::Object subclass
      # @param client [Parse::Client] optional client to use
      # @return [Migration] a migration object
      def migration(model_class, client: nil)
        diff_result = diff(model_class, client: client)
        Migration.new(model_class, diff_result, client: client)
      end

      # Check if a class exists on the server.
      # @param class_name [String, Class] the Parse class name or model class
      # @param client [Parse::Client] optional client to use
      # @return [Boolean] true if the class exists
      def exists?(class_name, client: nil)
        !fetch(class_name, client: client).nil?
      end

      # Get all class names from the server.
      # @param client [Parse::Client] optional client to use
      # @return [Array<String>] array of class names
      def class_names(client: nil)
        all(client: client).map(&:class_name)
      end
    end

    # Represents schema information for a Parse class.
    class SchemaInfo
      attr_reader :class_name, :fields, :indexes, :class_level_permissions

      def initialize(data)
        @class_name = data["className"]
        @fields = parse_fields(data["fields"] || {})
        @indexes = data["indexes"] || {}
        @class_level_permissions = data["classLevelPermissions"] || {}
        @raw = data
      end

      # Get field names.
      # @return [Array<String>] field names
      def field_names
        @fields.keys
      end

      # Get field type for a specific field.
      # @param field_name [String, Symbol] the field name
      # @return [Symbol, nil] the Ruby type symbol or nil
      def field_type(field_name)
        @fields[field_name.to_s]&.dig(:type)
      end

      # Get pointer target class for a field.
      # @param field_name [String, Symbol] the field name
      # @return [String, nil] the target class name or nil
      def pointer_target(field_name)
        @fields[field_name.to_s]&.dig(:target_class)
      end

      # Check if a field exists.
      # @param field_name [String, Symbol] the field name
      # @return [Boolean]
      def has_field?(field_name)
        @fields.key?(field_name.to_s)
      end

      # Check if this is a built-in Parse class.
      # @return [Boolean]
      def builtin?
        @class_name.start_with?("_")
      end

      # Get raw schema data.
      # @return [Hash]
      def to_h
        @raw
      end

      private

      def parse_fields(fields_hash)
        result = {}
        fields_hash.each do |name, info|
          type_str = info["type"]
          ruby_type = TYPE_MAP[type_str] || type_str.to_s.downcase.to_sym
          result[name] = {
            type: ruby_type,
            target_class: info["targetClass"],
            required: info["required"] || false,
            default_value: info["defaultValue"],
          }
        end
        result
      end
    end

    # Represents the difference between local model and server schema.
    class SchemaDiff
      attr_reader :model_class, :server_schema

      def initialize(model_class, server_schema)
        @model_class = model_class
        @server_schema = server_schema
      end

      # Check if server schema exists.
      # @return [Boolean]
      def server_exists?
        !@server_schema.nil?
      end

      # Fields defined locally but missing on server.
      #
      # Iterates the model's `field_map` (one entry per canonical property,
      # canonical name => wire column name) rather than `fields` (which carries
      # both the snake_case and camelCase keys for every property and therefore
      # double-counts multi-word fields). The wire name resolved from
      # `field_map` is the authoritative server column — including custom
      # `field:` mappings — so this both dedupes and fixes custom-column
      # detection. Result is keyed by the CANONICAL (snake) name with the type
      # taken from `fields[name]`.
      # @return [Hash] canonical field name => type pairs
      def missing_on_server
        server = server_exists? ? server_field_names : []
        missing = {}
        @model_class.field_map.each do |name, wire|
          next if core_field?(name)
          next if server.include?(wire.to_s)
          missing[name] = @model_class.fields[name]
        end
        missing
      end

      # Fields on server but not defined locally.
      # @return [Hash] field name => type pairs
      def missing_locally
        return {} unless server_exists?

        server = @server_schema.fields
        local = local_field_names
        missing = {}
        server.each do |name, info|
          # Skip core fields
          next if %w[objectId createdAt updatedAt ACL].include?(name)
          missing[name] = info[:type] unless local.include?(name) || local.include?(name.underscore.to_sym)
        end
        missing
      end

      # Fields with type mismatches.
      #
      # Iterates `field_map` (canonical name => wire column) rather than
      # deriving the server key with `camelize(:lower)`, so a property with a
      # custom `field:` wire column (e.g. `property :post_id, field:
      # "postIdentifier"`) resolves to its real server column instead of a
      # camelized guess. This both dedupes multi-word fields (which appear
      # under two keys in `fields`) and matches the `missing_on_server`
      # resolution path, so type drift on custom-mapped columns is no longer
      # silently skipped.
      # @return [Hash] canonical field name => { local: type, server: type }
      def type_mismatches
        return {} unless server_exists?

        mismatches = {}
        @model_class.field_map.each do |name, wire|
          next if core_field?(name)
          local_type = @model_class.fields[name]
          next if local_type.nil?
          server_type = @server_schema.field_type(wire.to_s)
          next unless server_type

          # Normalize types for comparison
          normalized_local = normalize_type(local_type)
          normalized_server = normalize_type(server_type)

          if normalized_local != normalized_server
            mismatches[name] = { local: local_type, server: server_type }
          end
        end
        mismatches
      end

      # Check if schemas are in sync.
      #
      # Strict / bidirectional: requires the local and server schemas to match
      # in BOTH directions — no fields missing on the server, no fields missing
      # locally, and no type mismatches. A server that is a strict superset of
      # the local model is NOT "in sync" by this measure (use
      # {#server_covers_local?} for the one-way local ⊆ server check).
      # @return [Boolean]
      def in_sync?
        missing_on_server.empty? && missing_locally.empty? && type_mismatches.empty?
      end

      # Check whether the server schema covers every locally-defined field.
      #
      # One-way (local ⊆ server): true when nothing the model declares is
      # missing on the server and there are no type mismatches. Unlike
      # {#in_sync?}, this ignores server-only columns, so a server that is a
      # strict superset of the local model still satisfies it. This is the
      # predicate that determines whether a migration has any work to do —
      # extra server columns are not something the migrator would add.
      # @return [Boolean]
      def server_covers_local?
        missing_on_server.empty? && type_mismatches.empty?
      end

      # Generate a human-readable summary.
      # @return [String]
      def summary
        lines = ["Schema diff for #{@model_class.parse_class}:"]

        if !server_exists?
          lines << "  - Class does not exist on server"
        elsif in_sync?
          lines << "  - Schemas are in sync"
        else
          unless missing_on_server.empty?
            lines << "  Missing on server:"
            missing_on_server.each { |n, t| lines << "    + #{n}: #{t}" }
          end
          unless missing_locally.empty?
            lines << "  Missing locally:"
            missing_locally.each { |n, t| lines << "    - #{n}: #{t}" }
          end
          unless type_mismatches.empty?
            lines << "  Type mismatches:"
            type_mismatches.each { |n, m| lines << "    ~ #{n}: local=#{m[:local]}, server=#{m[:server]}" }
          end
        end

        lines.join("\n")
      end

      private

      def local_fields
        @model_class.fields.reject { |k, _| core_field?(k) }
      end

      def local_field_names
        local_fields.keys.map(&:to_s)
      end

      def server_field_names
        @server_schema&.field_names || []
      end

      def core_field?(name)
        %i[id object_id created_at updated_at acl objectId createdAt updatedAt ACL].include?(name.to_sym)
      end

      def normalize_type(type)
        case type.to_sym
        when :integer, :float, :number then :number
        when :geo_point then :geopoint
        else type.to_sym
        end
      end
    end

    # Represents a schema migration to be applied.
    class Migration
      attr_reader :model_class, :diff, :client

      def initialize(model_class, diff, client: nil)
        @model_class = model_class
        @diff = diff
        @client = client || Parse.client
      end

      # Check if migration is needed.
      #
      # A migration is needed when the class does not yet exist on the server,
      # or when the server does not already cover every locally-defined field.
      # Defined in terms of the one-way {SchemaDiff#server_covers_local?} rather
      # than the strict bidirectional {SchemaDiff#in_sync?} so that a server
      # which is a strict superset of the local model (extra server-only
      # columns the migrator would never add) does not report a "needed"
      # migration with zero operations.
      # @return [Boolean]
      def needed?
        !@diff.server_exists? || !@diff.server_covers_local?
      end

      # Get the operations that would be performed.
      # @return [Array<Hash>] list of operations
      def operations
        ops = []

        unless @diff.server_exists?
          ops << { action: :create_class, class_name: @model_class.parse_class }
        end

        @diff.missing_on_server.each do |name, type|
          ops << {
            action: :add_field,
            field: @model_class.field_map[name].to_s,
            type: REVERSE_TYPE_MAP[type] || "String",
          }
        end

        ops
      end

      # Preview the migration without applying.
      # @return [String] human-readable preview
      def preview
        return "No migration needed" unless needed?

        lines = ["Migration for #{@model_class.parse_class}:"]
        operations.each do |op|
          case op[:action]
          when :create_class
            lines << "  CREATE CLASS #{op[:class_name]}"
          when :add_field
            lines << "  ADD FIELD #{op[:field]} (#{op[:type]})"
          end
        end
        lines.join("\n")
      end

      # Apply the migration to the server.
      # @param dry_run [Boolean] if true, only preview without applying
      # @return [Hash] results of the migration
      def apply!(dry_run: false)
        return { status: :skipped, message: "No migration needed" } unless needed?

        if dry_run
          return { status: :preview, operations: operations, preview: preview }
        end

        results = { status: :success, applied: [], errors: [] }

        # Create class if needed
        unless @diff.server_exists?
          schema = build_schema
          response = @client.create_schema(@model_class.parse_class, schema)
          if response.success?
            results[:applied] << { action: :create_class, class_name: @model_class.parse_class }
          else
            results[:errors] << { action: :create_class, error: response.error }
            results[:status] = :partial
          end
          return results
        end

        # Add missing fields
        @diff.missing_on_server.each do |name, type|
          field_name = @model_class.field_map[name].to_s
          field_schema = { "fields" => { field_name => field_definition(type) } }

          response = @client.update_schema(@model_class.parse_class, field_schema)
          if response.success?
            results[:applied] << { action: :add_field, field: field_name, type: type }
          else
            results[:errors] << { action: :add_field, field: field_name, error: response.error }
            results[:status] = :partial
          end
        end

        results[:status] = :failed if results[:applied].empty? && results[:errors].any?
        results
      end

      private

      def build_schema
        fields = {}
        # Iterate `field_map` (canonical name => wire column) rather than
        # `fields`, which carries both the snake_case and camelCase keys for
        # every property and would emit a duplicate/phantom column for each
        # multi-word or custom-`field:` property.
        @model_class.field_map.each do |name, wire|
          next if %i[id object_id created_at updated_at acl objectId createdAt updatedAt ACL].include?(name)
          fields[wire.to_s] = field_definition(@model_class.fields[name])
        end

        # Add pointer targets. `references` is keyed by the wire column name
        # (the `parse_field`), so use it as-is — do not re-camelize, which
        # would corrupt custom `field:` pointer columns.
        @model_class.references.each do |name, target_class|
          field_name = name.to_s
          fields[field_name] = {
            "type" => "Pointer",
            "targetClass" => target_class.to_s,
          }
        end

        schema = { "className" => @model_class.parse_class, "fields" => fields }
        # Attach CLPs only for newly-created classes when the integrator
        # has opted in via `Parse::Schema.default_class_level_permissions=`.
        # Per-model CLPs declared via `set_class_level_permissions` win
        # if present.
        clps = model_class_level_permissions
        schema["classLevelPermissions"] = clps if clps
        schema
      end

      # Resolve CLPs for the model being migrated. Returns:
      # - the model's explicitly-declared CLPs if it has any (looked up
      #   via the conventional accessor names some Parse-Stack models
      #   ship with), OR
      # - {Parse::Schema.default_class_level_permissions} if set, OR
      # - `nil` to leave `classLevelPermissions` off the schema body so
      #   Parse Server uses its built-in defaults.
      def model_class_level_permissions
        %i[class_level_permissions classLevelPermissions clp].each do |reader|
          next unless @model_class.respond_to?(reader)
          val = @model_class.public_send(reader)
          return val if val.is_a?(Hash) && !val.empty?
        end
        Parse::Schema.default_class_level_permissions
      end

      def field_definition(type)
        parse_type = REVERSE_TYPE_MAP[type.to_sym] || "String"
        { "type" => parse_type }
      end
    end
  end
end
