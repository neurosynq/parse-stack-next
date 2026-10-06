# encoding: UTF-8
# frozen_string_literal: true

require "active_support"
require "active_support/inflector"
require "active_support/core_ext"
# Note: Do not require "../object" here - this file is loaded from object.rb
# and adding that require would create a circular dependency.

module Parse
  # Create all Parse::Object subclasses, including their properties and inferred
  # associations by importing the schema for the remote collections in a Parse
  # application. Uses the default configured client.
  # @return [Array] an array of created Parse::Object subclasses.
  # @see Parse::Model::Builder.build!
  def self.auto_generate_models!
    Parse.schemas.map do |schema|
      Parse::Model::Builder.build!(schema)
    end
  end

  # Namespace where `Parse.auto_generate_models!` installs dynamically
  # generated `Parse::Object` subclasses derived from server-side schema.
  # Isolating them here prevents server-returned className strings from
  # rebinding top-level constants like ::File, ::Logger, ::Process.
  module Generated
  end

  class Model
    # This class provides a method to automatically generate Parse::Object subclasses, including
    # their properties and inferred associations by importing the schema for the remote collections
    # in a Parse application.
    class Builder
      # Regex matching className strings safe to install as a Ruby constant.
      # Server-returned className must satisfy this; otherwise we refuse to
      # touch the global namespace.
      VALID_CLASS_NAME = /\A_?[A-Za-z][A-Za-z0-9_]{0,127}\z/.freeze

      # Parse Server system classes that ship with the SDK as hand-written
      # subclasses (Parse::User, Parse::Role, etc.). Schema-driven builds
      # must NOT install additional fields or associations on these — a
      # compromised Parse Server could otherwise inject an `is_admin`
      # property onto the real `Parse::User` class, or a `password_history`
      # accessor onto `_Session`, by returning a poisoned schema.
      PROTECTED_SYSTEM_CLASSES = %w[
        _User _Role _Session _Installation _Product _Audience _PushStatus
        _JobStatus _JobSchedule _Hooks _GlobalConfig _SCHEMA _GraphQLConfig
        _Idempotency _Audit
      ].freeze

      # Builds a ruby Parse::Object subclass with the provided schema information.
      # @param schema [Hash] the Parse-formatted hash schema for a collection. This hash
      #  should two keys:
      #  * className: Contains the name of the collection.
      #  * field: A hash containg the column fields and their type.
      # @raise ArgumentError when the className could not be inferred from the schema.
      # @return [Array] an array of Parse::Object subclass constants.
      def self.build!(schema)
        unless schema.is_a?(Hash)
          raise ArgumentError, "Schema parameter should be a Parse schema hash object."
        end
        schema = schema.with_indifferent_access
        fields = schema[:fields] || {}
        className = schema[:className]

        if className.blank?
          raise ArgumentError, "No valid className provided for schema hash"
        end

        # Strictly validate the server-returned className before any constant
        # resolution. This blocks schema-poisoning attacks where a malicious
        # or compromised Parse Server returns a className like "File",
        # "Kernel", or "../foo" intending to either rebind a Ruby built-in
        # constant via const_set or trigger arbitrary autoload via const_get.
        parse_class_name = className.to_parse_class
        unless parse_class_name.is_a?(String) && parse_class_name =~ VALID_CLASS_NAME
          raise ArgumentError, "Unsafe className from schema: #{className.inspect}"
        end

        # Prefer the registered Parse::Object descendant lookup (never touches
        # top-level constants). Only fall back to constant lookup within the
        # Parse::Generated namespace, never on ::Object.
        klass = Parse::Model.find_class(className)
        if klass.nil?
          if Parse::Generated.const_defined?(parse_class_name, false)
            klass = Parse::Generated.const_get(parse_class_name, false)
          end
        end
        if klass.nil?
          klass = ::Class.new(Parse::Object)
          Parse::Generated.const_set(parse_class_name, klass)
          # The default parse_class comes from the Ruby name, which here is
          # namespaced ("Parse::Generated::Post"). Bind the server class name.
          klass.parse_class(className.to_s)
        end
        unless klass.is_a?(Class) && klass <= Parse::Object
          raise ArgumentError, "Resolved class #{klass.inspect} for #{className.inspect} is not a Parse::Object subclass"
        end

        # Refuse to install schema-derived fields on protected system
        # classes. The class is still returned (so callers that call
        # build! purely for the class lookup continue to work) but no
        # attacker-controlled belongs_to/has_many/property is added.
        if PROTECTED_SYSTEM_CLASSES.include?(className.to_s)
          return klass
        end

        base_fields = Parse::Properties::BASE.keys
        class_fields = klass.field_map.values + [:className]
        fields.each do |field, type|
          field = field.to_sym
          next if base_fields.include?(field) || class_fields.include?(field)
          next unless type.respond_to?(:[]) && type[:type].present?

          data_type = type[:type].to_s.downcase.to_sym
          # A model's field registry shares one namespace between Ruby
          # names and server columns, so a column whose name another column
          # already claimed as its Ruby name (`foo_bar` after `fooBar`)
          # cannot be mapped. Skip it instead of aborting the whole build.
          if klass.fields.key?(field) || klass.field_map.key?(field)
            builder_warn "skipping column #{className}.#{field}: its name is already " \
                         "used by another column of the same class"
            next
          end
          key = safe_accessor_name(klass, field, data_type)
          next if key.nil?

          begin
            if data_type == :pointer
              klass.belongs_to key, as: safe_target_class(type[:targetClass]), field: field
            elsif data_type == :relation
              klass.has_many key, through: :relation, as: safe_target_class(type[:targetClass]), field: field
            else
              # A renamed accessor must not get an alias under the column
              # name, which is the method it was renamed to avoid.
              opts = { field: field }
              opts[:alias] = false if key.to_s != field.to_s.underscore
              klass.property key, data_type, **opts
            end
          rescue StandardError, SystemStackError => e
            builder_warn "skipping column #{className}.#{field}: #{e.class}: #{e.message}"
            next
          end
          # Hydration from server JSON dispatches on `<column>_set_attribute!`.
          # The association and property DSLs only alias that hook when the
          # column name itself is free as a method, so add it for a renamed
          # accessor (`class` -> `class_field`).
          setter = :"#{field}_set_attribute!"
          target = :"#{key}_set_attribute!"
          if setter != target && !klass.method_defined?(setter) && klass.method_defined?(target)
            klass.send(:alias_method, setter, target)
          end
          class_fields.push(field)
        end
        klass
      end

      # Suffix appended to a column's Ruby accessor name when the natural
      # (underscored) name is unusable.
      RENAMED_ACCESSOR_SUFFIX = "_field"

      # @!visibility private
      # Chooses the Ruby accessor name for server column `field`. The natural
      # name is `field.underscore`. It is replaced with `<name>_field` (then
      # `<name>_field2`, ...) when it would shadow a method every
      # Parse::Object relies on (`class`, `hash`, `save`, `send`,
      # `object_id`, `changes`, ...), when a boolean column's class-level
      # scope would shadow a class method (`freeze`, `name`), or when another
      # column already claimed it (`fooBar` and `foo_bar` both underscore to
      # `foo_bar`). The server column name is unchanged (it is kept with
      # `field:`). Returns nil, after a warning, when no safe name exists.
      # @return [Symbol, nil]
      def self.safe_accessor_name(klass, field, data_type)
        natural = field.to_s.underscore
        unless natural.match?(/\A[a-z_][a-zA-Z0-9_]*\z/)
          builder_warn "skipping column #{klass.parse_class}.#{field}: not a valid Ruby method name"
          return nil
        end
        candidates = [natural, "#{natural}#{RENAMED_ACCESSOR_SUFFIX}"]
        candidates.concat((2..9).map { |n| "#{natural}#{RENAMED_ACCESSOR_SUFFIX}#{n}" })
        name = candidates.find { |c| !accessor_conflict?(klass, c.to_sym, data_type) }
        if name.nil?
          builder_warn "skipping column #{klass.parse_class}.#{field}: no free Ruby accessor name"
          return nil
        end
        if name != natural
          builder_warn "column #{klass.parse_class}.#{field} is exposed as ##{name} " \
                       "because ##{natural} would clash with an existing method or column"
        end
        name.to_sym
      end

      # @!visibility private
      # Whether defining accessor `key` on `klass` would replace an existing
      # method or reuse a name another column already maps to.
      def self.accessor_conflict?(klass, key, data_type)
        return true if klass.fields.key?(key) || klass.field_map.key?(key)
        return true if klass.respond_to?(:relations) && klass.relations.key?(key)
        instance_names = [key, :"#{key}=", :"#{key}_changed?", :"#{key}_was"]
        instance_names << :"#{key}?" if data_type == :boolean
        return true if instance_names.any? { |m| method_taken?(klass, m) }
        # Boolean columns also get a class-level scope named after the key.
        return true if data_type == :boolean && klass.respond_to?(key, true)
        false
      end

      # @!visibility private
      def self.method_taken?(klass, name)
        klass.method_defined?(name) || klass.private_method_defined?(name)
      end

      # @!visibility private
      def self.builder_warn(message)
        warn "[Parse::Model::Builder] #{message}"
      end

      # @!visibility private
      # Validates a server-returned `targetClass` string before forwarding
      # it to `belongs_to`/`has_many`. Returns `nil` for missing or
      # invalid values so the association DSL falls back to its inferred
      # default rather than installing an attacker-controlled class name
      # (which could pivot a later type-confusion bypass).
      def self.safe_target_class(target)
        return nil if target.nil? || target.to_s.empty?
        s = target.to_s
        return nil unless s =~ VALID_CLASS_NAME
        s
      end
    end
  end
end
