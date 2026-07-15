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
          key = field.to_s.underscore.to_sym
          next if base_fields.include?(field) || class_fields.include?(field)

          data_type = type[:type].downcase.to_sym
          if data_type == :pointer
            klass.belongs_to key, as: safe_target_class(type[:targetClass]), field: field
          elsif data_type == :relation
            klass.has_many key, through: :relation, as: safe_target_class(type[:targetClass]), field: field
          else
            klass.property key, data_type, field: field
          end
          class_fields.push(field)
        end
        klass
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
