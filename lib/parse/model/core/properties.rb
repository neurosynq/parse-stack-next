# encoding: UTF-8
# frozen_string_literal: true

require "active_model"
require "active_support"
require "active_support/inflector"
require "active_support/core_ext"
require "active_support/core_ext/object"
require "active_support/inflector"
require "active_model/serializers/json"
require "active_support/inflector"
require "active_model/serializers/json"
require "active_support/hash_with_indifferent_access"
require "time"

module Parse

  # This module provides support for handling all the different types of column data types
  # supported in Parse and mapping them between their remote names with their local ruby named attributes.
  module Properties
    # These are the base types supported by Parse.
    TYPES = [:string, :relation, :integer, :float, :boolean, :date, :array, :file, :geopoint, :polygon, :bytes, :object, :acl, :timezone, :phone, :email, :vector].freeze
    # These are the base mappings of the remote field name types.
    BASE = { objectId: :string, createdAt: :date, updatedAt: :date, ACL: :acl }.freeze
    # The list of properties that are part of all objects
    BASE_KEYS = [:id, :created_at, :updated_at].freeze
    # Attribute names refused on the mass-assignment path
    # (`Parse::Object#attributes=` and `apply_attributes!` with
    # `dirty_track: true`). Internal hydration from server responses uses
    # `dirty_track: false` and is unaffected, so server-issued
    # sessionTokens etc. still flow through during decoding.
    #
    # The list intentionally covers ONLY server-managed and security-
    # internal fields. User-facing properties like `acl` and `objectId`
    # are deliberately omitted because constructor calls like
    # `Document.new(acl: my_acl)` are legitimate developer code. Rails
    # applications receiving form input should use StrongParameters
    # (`params.permit(...)`) to filter attacker-controlled keys before
    # passing the hash to `Model.new` or `attributes=`.
    PROTECTED_MASS_ASSIGNMENT_KEYS = %w[
      sessionToken session_token
      roles _rperm _wperm
      _hashed_password _password_history
      authData _auth_data auth_data
      className __type
      createdAt created_at updatedAt updated_at
    ].freeze
    # Narrow subset of {PROTECTED_MASS_ASSIGNMENT_KEYS} that closes the
    # documented authentication / authorization mass-assignment attacks
    # (NEW-EXT-1) without breaking the legitimate "build a hydrated
    # object" pattern (`Klass.new("objectId" => id, "createdAt" => ts,
    # "field" => …)`). Applied by `Parse::Object#initialize` when
    # `trusted: false` (the default) so caller-supplied hashes — even
    # those bearing an `objectId` — cannot forge session tokens, ACL
    # row-permissions, password hashes, OAuth auth_data, or roles.
    #
    # Excluded from this narrow set on purpose:
    # - `createdAt` / `updatedAt`: timestamp integrity, not a security
    #   boundary. App code commonly rehydrates cached objects via
    #   `Klass.new(hash)` and expects timestamps to populate.
    # - `className` / `__type`: routing metadata. `Parse::Object.build`
    #   has its own className-mismatch guard; the in-memory value here
    #   is informational only.
    #
    # The wider {PROTECTED_MASS_ASSIGNMENT_KEYS} list still applies to
    # `Parse::Object#attributes=` and explicit
    # `apply_attributes!(dirty_track: true)` calls, where Rails-form
    # input is the expected source and timestamp forgery is also
    # undesirable.
    PROTECTED_INITIALIZE_KEYS = %w[
      sessionToken session_token
      roles _rperm _wperm
      _hashed_password _password_history
      authData _auth_data auth_data
    ].freeze
    # Default hash map of local attribute name to remote column name
    BASE_FIELD_MAP = { id: :objectId, created_at: :createdAt, updated_at: :updatedAt, acl: :ACL }.freeze
    # The delete operation hash.
    CORE_FIELDS = { id: :string, created_at: :date, updated_at: :date, acl: :acl }.freeze
    # The delete operation hash.
    DELETE_OP = { "__op" => "Delete" }.freeze
    # Shared stateless boolean caster used by {#format_value}. One instance
    # for the process lifetime — `cast` only consults a frozen FALSE_VALUES
    # set, so reuse is thread-safe.
    BOOLEAN_CASTER = ActiveModel::Type::Boolean.new.freeze
    # @!visibility private
    def self.included(base)
      base.extend(ClassMethods)
    end

    # Process-once deprecation warning emitted when an ACL is set through
    # mass-assignment (`Parse::Object#attributes=`). Setting ACL this way is
    # still permitted in this release for backward compatibility, but is a
    # mass-assignment foot-gun (a caller-supplied params hash bearing an
    # `ACL` key can grant public write). A future release may block it; the
    # supported path is the explicit `obj.acl =` setter. One-time so loops
    # over many records do not spam the log.
    # @!visibility private
    def self.warn_acl_mass_assignment_once!
      return if @acl_mass_assignment_warned
      @acl_mass_assignment_warned = true
      warn "[Parse::Stack:SECURITY] Setting `acl`/`ACL` via mass-assignment " \
           "(Parse::Object#attributes=) is deprecated and may be blocked in a " \
           "future release. A caller-supplied params hash bearing an ACL key can " \
           "grant unintended access — filter input with StrongParameters and set " \
           "ACL via the explicit `obj.acl = ...` setter instead."
    end

    # The class methods added to Parse::Objects
    module ClassMethods

      # The fields method returns a mapping of all local attribute names and their data type.
      # if type is passed, we return only the fields that matched that data type. If `type`
      # is provided, it will only return the fields that match the data type.
      # @param type [Symbol] a property type.
      # @return [Hash] the defined fields for this Parse collection with their data type.
      def fields(type = nil)
        # if it's Parse::Object, then only use the initial set, otherwise add the other base fields.
        @fields ||= (self == Parse::Object ? CORE_FIELDS : Parse::Object.fields).dup
        if type.present?
          type = type.to_sym
          return @fields.select { |k, v| v == type }
        end
        @fields
      end

      # @return [Hash] the field map for this subclass.
      def field_map
        @field_map ||= BASE_FIELD_MAP.dup
      end

      # @return [Hash] the fields that are marked as enums.
      def enums
        @enums ||= {}
      end

      # @return [Hash] semantic descriptions for properties (used by Parse::Agent).
      # Maps property names (symbols) to their description strings.
      def property_descriptions
        @property_descriptions ||= {}
      end

      # @return [Hash] per-value descriptions for enum-shaped string
      # properties (used by Parse::Agent). Maps property names (symbols)
      # to a `{ "value" => "description" }` hash. Orthogonal to the
      # existing `enum:` option on `property` — `enum:` validates the
      # set of allowed values, `_enum:` documents each one for an LLM.
      #
      # **Intended for string-typed columns only.** Value keys are
      # stringified at declaration time and the schema response carries
      # `{value: "1", ...}` regardless of the underlying column type.
      # Declaring `_enum:` on an integer/boolean column will surface
      # string-shaped values to the LLM that won't match the column
      # in a `where:` filter — userland is responsible for keeping
      # `_enum:` on string-typed properties.
      def property_enum_descriptions
        @property_enum_descriptions ||= {}
      end

      # @return [Hash] per-property metadata for `:vector`-typed fields.
      # Maps property names (symbols) to a frozen options hash:
      # `{ dimensions: Integer, provider: Symbol, model: String, similarity: Symbol }`.
      # `dimensions:` is required; the rest are optional and only carry
      # meaning for the embedding provider plumbing layered above this
      # type. Consumed by `Parse::Embeddings` and
      # `Parse::AtlasSearch::IndexCatalog` to resolve which vector index
      # to query for a given field.
      def vector_properties
        @vector_properties ||= {}
      end

      # Set the property fields for this class.
      # @return [Hash]
      def attributes=(hash)
        @attributes = BASE.merge(hash)
      end

      # @return [Hash] the fields that are marked as enums.
      def attributes
        @attributes ||= BASE.dup
      end

      # @return [Array] the list of fields that have defaults.
      def defaults_list
        @defaults_list ||= []
      end

      # property :songs, :array
      # property :my_date, :date, field: "myRemoteCOLUMNName"
      # property :my_int, :integer, required: true, default: ->{ rand(10) }

      # field: (literal column name in Parse)
      # required: (data_type)
      # default: (value or Proc)
      # alias: Whether to create the remote field alias getter/setters for this attribute

      # symbolize: Makes sure the saved and return value locally is in symbol format. useful
      # for enum type fields that are string columns in Parse. Ex. a booking_status for a field
      # could be either "submitted" or "completed" in Parse, however with symbolize, these would
      # be available as :submitted or :completed.

      # This is the class level property method to be used when declaring properties. This helps builds specific methods, formatters
      # and conversion handlers for property storing and saving data for a particular parse class.
      # The first parameter is the name of the local attribute you want to declare with its corresponding data type.
      # Declaring a `property :my_date, :date`, would declare the attribute my_date with a corresponding remote column called
      # "myDate" (lower-first-camelcase) with a Parse data type of Date.
      # You can override the implicit naming behavior by passing the option :field to override.
      def property(key, data_type = :string, **opts)
        key = key.to_sym
        ivar = :"@#{key}"
        will_change_method = :"#{key}_will_change!"
        set_attribute_method = :"#{key}_set_attribute!"

        if data_type.is_a?(Hash)
          opts.merge!(data_type)
          data_type = :string
          # future: automatically use :timezone datatype for timezone-like fields.
          # when the data_type was not specifically set.
          # data_type = :timezone if key == :time_zone || key == :timezone
        end

        # A property that names a pointer target — via `as:`/`class_name:` or an
        # explicit :pointer data type — is really a belongs_to association, not a
        # scalar column. Delegate so `property :rejected_by, as: :user` behaves
        # identically to `belongs_to :rejected_by, as: :user` instead of silently
        # storing a String (the `as:` option was previously dropped, leaving the
        # field as the default :string type). Reusing belongs_to keeps the
        # className-trust guard and autofetch/dirty-tracking in one place rather
        # than duplicating pointer handling here. `opts` is still raw user input
        # at this point (the defaults merge happens further down), so only an
        # explicitly-passed :field is forwarded and belongs_to defaults the rest.
        if opts.key?(:as) || opts.key?(:class_name) || data_type == :pointer
          forwarded = %i[as class_name field required _description _enum]
          bt_opts = {}
          forwarded.each { |o| bt_opts[o] = opts[o] if opts.key?(o) }
          # belongs_to has no scalar-property machinery (defaults, symbolize,
          # enum validation, alias toggles, scope generation). Surface — rather
          # than silently drop — any such option so a `default:`/`symbolize:` on
          # a pointer property isn't quietly ignored.
          dropped = opts.keys.map(&:to_sym) - forwarded
          unless dropped.empty?
            warn "[#{self}] property #{key.inspect} resolves to a pointer association; " \
                 "ignoring unsupported option(s) #{dropped.map(&:inspect).join(', ')} " \
                 "(not available on belongs_to)."
          end
          return belongs_to(key, bt_opts)
        end

        data_type = :timezone if data_type == :string && (key == :time_zone || key == :timezone)

        # allow :bool for :boolean
        data_type = :boolean if data_type == :bool
        data_type = :timezone if data_type == :time_zone
        data_type = :geopoint if data_type == :geo_point
        data_type = :polygon if data_type == :geo_polygon
        data_type = :integer if data_type == :int || data_type == :number
        data_type = :phone if data_type == :phone_number || data_type == :mobile || data_type == :e164
        data_type = :email if data_type == :email_address

        # set defaults
        opts = { required: false,
                 alias: true,
                 symbolize: false,
                 enum: nil,
                 scopes: true,
                 _prefix: nil,
                 _suffix: false,
                 _description: nil,  # Agent metadata: semantic description for LLMs
                 _enum: nil,         # Agent metadata: per-value enum descriptions ({ value => description })
                 field: key.to_s.camelize(:lower) }.merge(opts)
        #By default, the remote field name is a lower-first-camelcase version of the key
        # it can be overriden by the :field parameter
        parse_field = opts[:field].to_sym
        # If this property is already defined (either as a custom property on this class or as a
        # core property on a Parse::Object subclass), decide whether to silently apply non-structural
        # updates, raise, or warn-and-drop. Structural changes (different data type or different
        # remote field name) are almost always bugs — like declaring Installation#badge as :string
        # when the server stores it as :integer — so they raise when Parse.strict_property_redefinition
        # is enabled (the default). Non-structural redeclarations (same type, same remote field) are
        # allowed and may refine metadata such as :default, :_description, and :_enum without warning;
        # this covers class reopens that re-affirm an existing property after a parse-stack upgrade
        # adds the same definition upstream, or that bolt a default value onto an inherited field.
        if (self.fields[key].present? && BASE_FIELD_MAP[key].nil?) || (self < Parse::Object && BASE_FIELD_MAP.has_key?(key))
          existing_type = self.fields[key]
          existing_parse_field = self.field_map[key]
          if existing_type == data_type && existing_parse_field == parse_field
            # Non-structural redeclaration: apply safe metadata-only updates and bail out before
            # the rest of the method redefines getters/setters/validations/scopes.
            if opts.key?(:default)
              default_value = opts[:default]
              defaults_list.push(key) unless defaults_list.include?(key)
              define_method("#{key}_default") do
                default_value.is_a?(Proc) ? default_value.call(self) : default_value
              end
            end
            if opts[:_description].present?
              self.property_descriptions[key] = opts[:_description].to_s.freeze
            end
            if opts[:_enum].is_a?(Hash) && opts[:_enum].any?
              normalized = opts[:_enum].each_with_object({}) do |(value, desc), h|
                h[value.to_s] = desc.to_s.freeze
              end
              self.property_enum_descriptions[key] = normalized.freeze
            end
            return true
          end
          if Parse.strict_property_redefinition
            raise ArgumentError,
                  "Property #{self}##{key} is already defined as :#{existing_type} " \
                  "(remote field :#{existing_parse_field}); refusing to redeclare as :#{data_type} " \
                  "(remote field :#{parse_field}). Set Parse.strict_property_redefinition = false " \
                  "to fall back to warn-and-ignore behavior."
          end
          warn "Property #{self}##{key} already defined with data type :#{data_type}. Will be ignored."
          return false
        end
        # We keep the list of fields that are on the remote Parse store
        if self.fields[parse_field].present? || (self < Parse::Object && BASE.has_key?(parse_field))
          warn "Alias property #{self}##{parse_field} conflicts with previously defined property. Will be ignored."
          return false
          # raise ArgumentError
        end
        #dirty tracking. It is declared to use with ActiveModel DirtyTracking
        define_attribute_methods key

        # this hash keeps list of attributes (based on remote fields) and their data types
        self.attributes.merge!(parse_field => data_type)
        # this maps all the possible attribute fields and their data types. We use both local
        # keys and remote keys because when we receive a remote object that has the remote field name
        # we need to know what the data type conversion should be.
        self.fields.merge!(key => data_type, parse_field => data_type)
        # This creates a mapping between the local field and the remote field name.
        self.field_map.merge!(key => parse_field)

        # Store the property description for agent metadata if provided
        if opts[:_description].present?
          self.property_descriptions[key] = opts[:_description].to_s.freeze
        end

        # Store per-value enum descriptions for agent metadata if provided.
        # Accepts a Hash mapping each allowed value (Symbol or String) to a
        # description string. Stored with stringified value keys to match the
        # wire-format shape an LLM will see in query constraints. Distinct
        # from the existing `enum:` option, which is a validation construct.
        if opts[:_enum].is_a?(Hash) && opts[:_enum].any?
          normalized = opts[:_enum].each_with_object({}) do |(value, desc), h|
            h[value.to_s] = desc.to_s.freeze
          end
          self.property_enum_descriptions[key] = normalized.freeze
        end

        # if the field is marked as required, then add validations
        if opts[:required]
          # if integer or float, validate that it's a number
          if data_type == :integer || data_type == :float
            validates_numericality_of key
          end
          # validate that it is not empty
          validates_presence_of key
        end

        # timezone datatypes are basically enums based on IANA time zone identifiers.
        if data_type == :timezone
          validates_each key do |record, attribute, value|
            # Parse::TimeZone objects have a `valid?` method to determine if the timezone is valid.
            unless value.nil? || value.valid?
              record.errors.add(attribute, "field :#{attribute} must be a valid IANA time zone identifier.")
            end
          end # validates_each
        end # data_type == :timezone

        # phone datatypes validate E.164 format.
        if data_type == :phone
          validates_each key do |record, attribute, value|
            # Parse::Phone objects have a `valid?` method to determine if the phone is valid E.164.
            unless value.nil? || value.valid?
              record.errors.add(attribute, "field :#{attribute} must be a valid E.164 phone number (e.g., +14155551234).")
            end
          end # validates_each
        end # data_type == :phone

        # vector datatypes capture per-property embedding metadata
        # (dimensions, provider, model, similarity) and validate that
        # any assigned value matches the declared `dimensions:`.
        # `dimensions:` is required at declaration time — the field
        # cannot be safely indexed or compared against a query vector
        # without it.
        if data_type == :vector
          dims = opts[:dimensions] || opts[:dims]
          unless dims.is_a?(Integer) && dims > 0
            raise ArgumentError,
                  "Property #{self}##{key} :vector requires `dimensions:` as a positive Integer."
          end
          if dims > Parse::Vector::MAX_DIMENSIONS
            raise ArgumentError,
                  "Property #{self}##{key} :vector dimensions #{dims} exceeds max " \
                  "#{Parse::Vector::MAX_DIMENSIONS}."
          end
          vector_properties[key] = {
            dimensions: dims,
            provider: opts[:provider],
            model: opts[:model],
            similarity: opts[:similarity],
          }.freeze

          validates_each key do |record, attribute, value|
            next if value.nil?
            unless value.is_a?(Parse::Vector)
              record.errors.add(attribute, "field :#{attribute} must be a Parse::Vector.")
            else
              expected = record.class.vector_properties.dig(attribute, :dimensions)
              if expected && value.dimensions != expected
                record.errors.add(attribute,
                  "field :#{attribute} expected #{expected} dimensions, got #{value.dimensions}.")
              end
            end
          end # validates_each
        end # data_type == :vector

        # email datatypes validate email format.
        if data_type == :email
          validates_each key do |record, attribute, value|
            # Parse::Email objects have a `valid?` method to determine if the email is valid.
            unless value.nil? || value.valid?
              record.errors.add(attribute, "field :#{attribute} must be a valid email address.")
            end
          end # validates_each
        end # data_type == :email

        is_enum_type = opts[:enum].nil? == false

        if is_enum_type
          unless data_type == :string
            raise ArgumentError, "Property #{self}##{parse_field} :enum option is only supported on :string data types."
          end

          enum_values = opts[:enum]
          unless enum_values.is_a?(Array) && enum_values.empty? == false
            raise ArgumentError, "Property #{self}##{parse_field} :enum option must be an Array type of symbols."
          end
          opts[:symbolize] = true

          enum_values = enum_values.dup.map(&:to_sym).freeze

          self.enums.merge!(key => enum_values)
          allow_nil = opts[:required] == false
          validates key, inclusion: { in: enum_values }, allow_nil: allow_nil

          unless opts[:scopes] == false
            # You can use the :_prefix or :_suffix options when you need to define multiple enums with same values.
            # If the passed value is true, the methods are prefixed/suffixed with the name of the enum. It is also possible to supply a custom value:
            prefix = opts[:_prefix]
            unless opts[:_prefix].nil? || prefix.is_a?(Symbol) || prefix.is_a?(String)
              raise ArgumentError, "Enumeration option :_prefix must either be a symbol or string for #{self}##{key}."
            end

            unless opts[:_suffix].is_a?(TrueClass) || opts[:_suffix].is_a?(FalseClass)
              raise ArgumentError, "Enumeration option :_suffix must either be true or false for #{self}##{key}."
            end

            add_suffix = opts[:_suffix] == true
            prefix_or_key = (prefix.blank? ? key : prefix).to_sym

            class_method_name = prefix_or_key.to_s.pluralize.to_sym
            if singleton_class.method_defined?(class_method_name)
              raise ArgumentError, "You tried to define an enum named `#{key}` for #{self} " + "but this will generate a method  `#{self}.#{class_method_name}` " + " which is already defined. Try using :_suffix or :_prefix options."
            end

            define_singleton_method(class_method_name) { enum_values }

            method_name = add_suffix ? :"valid_#{prefix_or_key}?" : :"#{prefix_or_key}_valid?"
            define_method(method_name) do
              value = send(key) # call default getter
              return true if allow_nil && value.nil?
              enum_values.include?(value.to_s.to_sym)
            end

            enum_values.each do |enum|
              method_name = enum # default
              if add_suffix
                method_name = :"#{enum}_#{prefix_or_key}"
              elsif prefix.present?
                method_name = :"#{prefix}_#{enum}"
              end
              self.scope method_name, ->(ex = {}) { ex.merge!(key => enum); query(ex) }

              define_method("#{method_name}!") { send set_attribute_method, enum, true }
              define_method("#{method_name}?") { enum == send(key).to_s.to_sym }
            end
          end # unless scopes
        end # if is enum

        symbolize_value = opts[:symbolize]

        #only support symbolization of string data types
        if symbolize_value && (data_type == :string || data_type == :array) == false
          raise ArgumentError, "Tried to symbolize #{self}##{key}, but it is only supported on :string or :array data types."
        end

        # Here is the where the 'magic' begins. For each property defined, we will
        # generate special setters and getters that will take advantage of ActiveModel
        # helpers.
        # get the default value if provided (or Proc)
        default_value = opts[:default]
        unless default_value.nil?
          defaults_list.push(key) unless default_value.nil?

          define_method("#{key}_default") do
            # If the default object provided is a Proc, then run the proc, otherwise
            # we'll assume it's just a plain literal value
            default_value.is_a?(Proc) ? default_value.call(self) : default_value
          end
        end

        # We define a getter with the key

        define_method(key) do

          # we will get the value using the internal value of the instance variable
          # using the instance_variable_get
          value = instance_variable_get ivar

          # If the value is nil and this current Parse::Object instance is a pointer?
          # then someone is calling the getter for this, which means they probably want
          # its value - so let's go turn this pointer into a full object record.
          # Also autofetch if object was selectively fetched and this field wasn't included.
          should_autofetch = value.nil? && (pointer? || (has_selective_keys? && !field_was_fetched?(key)))
          if should_autofetch
            # If autofetch is disabled and we're accessing an unfetched field on a
            # selectively fetched object, raise an error to make the issue explicit
            if autofetch_disabled? && has_selective_keys? && !field_was_fetched?(key)
              raise Parse::UnfetchedFieldAccessError.new(key, self.class.name)
            end
            # call autofetch to fetch the entire record
            # and then get the ivar again cause it might have been updated.
            autofetch!(key)
            value = instance_variable_get ivar
          end

          # if value is nil (even after fetching), then lets see if the developer
          # set a default value for this attribute.
          if value.nil? && respond_to?("#{key}_default")
            value = send("#{key}_default")
            value = format_value(key, value, data_type)
            # lets set the variable with the updated value
            instance_variable_set ivar, value
            send will_change_method
          elsif value.nil? && data_type == :array
            value = Parse::CollectionProxy.new [], delegate: self, key: key
            instance_variable_set ivar, value
            # don't send the notification yet until they actually add something
            # which will be handled by the collection proxy.
            # send will_change_method
          end

          # if the value is a String (like an iso8601 date) and the data type of
          # this object is :date, then let's be nice and create a parse date for it.
          if value.is_a?(String) && data_type == :date
            value = format_value(key, value, data_type)
            instance_variable_set ivar, value
            send will_change_method
          end
          # finally return the value
          if symbolize_value
            if data_type == :string
              return value.respond_to?(:to_sym) ? value.to_sym : value
            elsif data_type == :array && value.is_a?(Array)
              # value.map(&:to_sym)
              return value.compact.map { |m| m.respond_to?(:to_sym) ? m.to_sym : m }
            end
          end

          value
        end

        # support question mark methods for boolean
        if data_type == :boolean
          if self.method_defined?("#{key}?")
            warn "Creating boolean helper :#{key}?. Will overwrite existing method #{self}##{key}?."
          end

          # returns true if set to true, false otherwise
          define_method("#{key}?") { (send(key) == true) }
          unless opts[:scopes] == false
            scope key, ->(opts = {}) { query(opts.merge(key => true)) }
          end
        elsif data_type == :integer || data_type == :float
          if self.method_defined?("#{key}_increment!")
            warn "Creating increment helper :#{key}_increment!. Will overwrite existing method #{self}##{key}_increment!."
          end

          define_method("#{key}_increment!") do |amount = 1|
            unless amount.is_a?(Numeric)
              raise ArgumentError, "Amount needs to be an integer"
            end
            result = self.op_increment!(key, amount)
            if result
              new_value = send(key).to_i + amount
              # set the updated value, with no dirty tracking
              self.send set_attribute_method, new_value, false
            end
            result
          end

          if self.method_defined?("#{key}_decrement!")
            warn "Creating decrement helper :#{key}_decrement!. Will overwrite existing method #{self}##{key}_decrement!."
          end

          define_method("#{key}_decrement!") do |amount = -1|
            unless amount.is_a?(Numeric)
              raise ArgumentError, "Amount needs to be an integer"
            end
            amount = -amount if amount > 0
            send("#{key}_increment!", amount)
          end
        end

        # The second method to be defined is a setter method. This is done by
        # defining :key with a '=' sign. However, to support setting the attribute
        # with and without dirty tracking, we really will just proxy it to another method

        define_method("#{key}=") do |val|
          #we proxy the method passing the value and true. Passing true to the
          # method tells it to make sure dirty tracking is enabled.
          self.send set_attribute_method, val, true
        end

        # This is the real setter method. Takes two arguments, the value to set
        # and whether to mark it as dirty tracked.
        define_method(set_attribute_method) do |val, track = true|
          # Each value has a data type, based on that we can treat the incoming
          # value as input, and format it to the correct storage format. This method is
          # defined in this file (instance method)
          val = format_value(key, val, data_type)
          # if dirty trackin is enabled, call the ActiveModel required method of _will_change!
          # this will grab the current value and keep a copy of it - but we only do this if
          # the new value being set is different from the current value stored.
          if track == true
            prepare_for_dirty_tracking!(key)
            send will_change_method unless val == instance_variable_get(ivar)
          end

          if symbolize_value
            if data_type == :string
              val = nil if val.blank?
              val = val.to_sym if val.respond_to?(:to_sym)
            elsif val.is_a?(Parse::CollectionProxy)
              items = val.collection.map { |m| m.respond_to?(:to_sym) ? m.to_sym : m }
              val.set_collection! items
            end
          end

          # if is_enum_type
          #
          # end
          # now set the instance value
          instance_variable_set ivar, val
        end

        # The core methods above support all attributes with the base local :key parameter
        # however, for ease of use and to handle that the incoming fields from parse have different
        # names, we will alias all those methods defined above with the defined parse_field.
        # if both the local name matches the calculated/provided remote column name, don't create
        # an alias method since it is the same thing. Ex. attribute 'username' would probably have the
        # remote column name also called 'username'.
        return true if parse_field == key

        # we will now create the aliases, however if the method is already defined
        # we warn the user unless the field is :objectId since we are in charge of that one.
        # this is because it is possible they want to override. You can turn off this
        # behavior by passing false to :alias

        if self.method_defined?(parse_field) == false && opts[:alias]
          alias_method parse_field, key
          alias_method "#{parse_field}=", "#{key}="
          alias_method "#{parse_field}_set_attribute!", set_attribute_method
        elsif parse_field.to_sym != :objectId
          warn "Alias property method #{self}##{parse_field} already defined."
        end
        true
      end # property
    end #ClassMethods

    # @return [Hash] a hash mapping of all property fields and their types.
    def field_map
      self.class.field_map
    end

    # @return returns the list of fields
    def fields(type = nil)
      self.class.fields(type)
    end

    # TODO: We can optimize
    # @return [Hash] returns the list of property attributes for this class.
    def attributes
      { __type: :string, :className => :string }.merge!(self.class.attributes)
    end

    # support for setting a hash of attributes on the object with a given dirty tracking value
    # if dirty_track: is set to false (default), attributes are set without dirty tracking.
    # Allos mass assignment of properties with a provided hash.
    # @param hash [Hash] the hash matching the property field names.
    # @param dirty_track [Boolean] whether dirty tracking be enabled. When true,
    #   permission-sensitive keys ({Parse::Properties::PROTECTED_MASS_ASSIGNMENT_KEYS})
    #   are skipped by default so attacker-controlled params cannot overwrite
    #   acl/roles/sessionToken/etc. Set explicitly via the typed property
    #   writers when the caller is trusted.
    # @param filter_protected [Boolean, nil] whether to filter out
    #   {Parse::Properties::PROTECTED_MASS_ASSIGNMENT_KEYS}. Defaults to
    #   +dirty_track+ for backwards-compat (the historical coupling). Callers
    #   can pass +true+ explicitly to filter even on the trusted hydration
    #   path (used by {Parse::Object#initialize} when constructed with
    #   +trusted: false+ but an +objectId+ is in the hash). +false+ explicitly
    #   preserves the legacy "server response" semantics.
    # @param protected_set [Array<String>, nil] override which key list to
    #   filter when +filter_protected+ is true. Defaults to the wider
    #   {Parse::Properties::PROTECTED_MASS_ASSIGNMENT_KEYS}.
    #   {Parse::Object#initialize} passes
    #   {Parse::Properties::PROTECTED_INITIALIZE_KEYS} here to allow
    #   legitimate hydration patterns (`Klass.new("objectId" => …,
    #   "createdAt" => …)`) while still refusing security-critical
    #   forgeries (`sessionToken`, `_rperm`, `authData`, …).
    # @return [Hash]
    def apply_attributes!(hash, dirty_track: false, filter_protected: nil, protected_set: nil)
      return unless hash.is_a?(Hash)

      filter_protected = dirty_track if filter_protected.nil?
      protected_set ||= Parse::Properties::PROTECTED_MASS_ASSIGNMENT_KEYS
      protected_keys = filter_protected ? protected_set : nil
      # Internal hydration path lifts objectId out of the response hash. The
      # mass-assignment path must not, or attacker-controlled params can
      # overwrite the primary key of an in-memory object.
      unless dirty_track
        @id ||= hash[Parse::Model::ID] || hash[Parse::Model::OBJECT_ID] || hash[:objectId]
      end
      hash.each do |key, value|
        next if protected_keys && protected_keys.include?(key.to_s)
        method = "#{key}_set_attribute!".freeze
        send(method, value, dirty_track) if respond_to?(method)
      end
    end

    # Supports mass assignment of attributes
    # @return (see #apply_attributes!)
    def attributes=(hash)
      return unless hash.is_a?(Hash)
      # `acl`/`ACL` is still accepted here (a user-facing property), but
      # mass-assigning an ACL from a caller-supplied hash — e.g. a Rails
      # controller doing `record.attributes = params` without
      # StrongParameters — lets an attacker grant themselves write by
      # sending `{"ACL" => {"*" => {"write" => true}}}`. Warn (once) so the
      # foot-gun is visible; callers should set ACL via the explicit
      # `obj.acl =` setter. The constructor path (`Klass.new(acl:)`) calls
      # apply_attributes! directly and is intentionally not warned.
      if hash.key?("ACL") || hash.key?("acl") || hash.key?(:ACL) || hash.key?(:acl)
        Parse::Properties.warn_acl_mass_assignment_once!
      end
      # - [:id, :objectId]
      # only overwrite @id if it hasn't been set.
      apply_attributes!(hash, dirty_track: true)
    end

    # Returns a hash of attributes for properties that have changed. This will
    # not include any of the base attributes (ex. id, created_at, etc).
    # This method helps generate the change payload that will be sent when saving
    # objects to Parse.
    # @param include_all [Boolean] whether to include all {Parse::Properties::BASE_KEYS} attributes.
    # @return [Hash]
    def attribute_updates(include_all = false)
      # TODO: Replace this algorithm with reduce()
      h = {}
      changed.each do |key|
        key = key.to_sym
        next if include_all == false && Parse::Properties::BASE_KEYS.include?(key)
        next unless fields[key].present?
        remote_field = self.field_map[key] || key
        h[remote_field] = send key
        h[remote_field] = { __op: :Delete } if h[remote_field].nil?
        # in the case that the field is a Parse object, generate a pointer
        # if it is a Parse::PointerCollectionProxy, then make sure we get a list of pointers.
        h[remote_field] = h[remote_field].parse_pointers if h[remote_field].is_a?(Parse::PointerCollectionProxy)
        # For regular CollectionProxy arrays containing Parse objects, convert to pointers for storage
        if h[remote_field].is_a?(Parse::CollectionProxy) && !h[remote_field].is_a?(Parse::PointerCollectionProxy)
          h[remote_field] = h[remote_field].as_json(pointers_only: true)
        end
        h[remote_field] = h[remote_field].pointer if h[remote_field].respond_to?(:pointer)
      end
      h
    end

    # @return [Boolean] true if any of the attributes have changed.
    def attribute_changes?
      changed.any? do |key|
        fields[key.to_sym].present?
      end
    end

    # Returns a formatted value based on the operation hash and data_type of the property.
    # For some values in Parse, they are specified as operation hashes which could include
    # Add, Remove, Delete, AddUnique and Increment.
    # @param key [Symbol] the name of the property
    # @param val [Hash] the Parse operation hash value.
    # @param data_type [Symbol] The data type of the property.
    # @return [Object]
    def format_operation(key, val, data_type)
      return val unless val.is_a?(Hash) && val["__op"].present?
      op = val["__op"]
      ivar = :"@#{key}"
      #handles delete case otherwise 'null' shows up in column
      if "Delete" == op
        val = nil
      elsif "Add" == op && data_type == :array
        val = (instance_variable_get(ivar) || []).to_a + (val["objects"] || [])
      elsif "Remove" == op && data_type == :array
        val = (instance_variable_get(ivar) || []).to_a - (val["objects"] || [])
      elsif "AddUnique" == op && data_type == :array
        objects = (val["objects"] || []).uniq
        original_items = (instance_variable_get(ivar) || []).to_a
        objects.reject! { |r| original_items.include?(r) }
        val = original_items + objects
      elsif "Increment" == op && data_type == :integer || data_type == :integer
        # for operations that increment by a certain amount, they come as a hash
        val = (instance_variable_get(ivar) || 0) + (val["amount"] || 0).to_i
      end
      val
    end

    # this method takes an input value and transforms it to the proper local format
    # depending on the data type that was set for a particular property key.
    # Return the internal representation of a property value for a given data type.
    # @param key [Symbol] the name of the property
    # @param val [Object] the value to format.
    # @param data_type [Symbol] provide a hint to the data_type of this value.
    # @return [Object]
    def format_value(key, val, data_type = nil)
      # if data_type wasn't passed, then get the data_type from the fields hash
      data_type ||= self.fields[key]

      val = format_operation(key, val, data_type)

      case data_type
      when :object
        val = val.with_indifferent_access if val.is_a?(Hash)
      when :array
        # All "array" types use a collection proxy
        val = val.to_a if val.is_a?(Parse::CollectionProxy) #all objects must be in array form
        val = [val] unless val.is_a?(Array) #all objects must be in array form
        val.compact! #remove any nil
        val = Parse::CollectionProxy.new val, delegate: self, key: key
      when :geopoint
        val = Parse::GeoPoint.new(val) unless val.blank?
      when :polygon
        val = Parse::Polygon.new(val) unless val.blank?
      when :file
        if val.is_a?(Hash) && val["__type"] == "File"
          val = Parse::File.new(val)
        elsif !val.blank?
          val = Parse::File.new(val)
        end
      when :bytes
        if val.is_a?(Hash) && val["__type"] == "Bytes"
          val = Parse::Bytes.new(val["base64"] || val[:base64])
        elsif !val.blank?
          val = Parse::Bytes.new(val)
        end
      when :integer
        if val.nil? || val.respond_to?(:to_i) == false
          val = nil
        else
          val = val.to_i
        end
      when :boolean
        # Coerce via ActiveModel's boolean caster rather than Ruby
        # truthiness. Plain `val ? true : false` treats every non-nil,
        # non-false object as true, so the strings "false", "0", and "off"
        # — exactly what arrives on the Rails-form / query-string ingestion
        # path — would coerce to `true` and silently flip a boolean the
        # wrong way (e.g. an `archived` or admin gate). ActiveModel maps the
        # string forms ("false"/"0"/"f"/"off"/"") to false/nil. Parse wire
        # JSON already sends real booleans, which pass through unchanged.
        val = val.nil? ? nil : BOOLEAN_CASTER.cast(val)
      when :string
        val = val.to_s unless val.blank?
      when :float
        val = val.to_f unless val.blank?
      when :acl
        # ACL types go through a special conversion
        val = ACL.typecast(val, self)
      when :date
        # if it respond to parse_date, then use that as the conversion.
        if val.respond_to?(:parse_date) && val.is_a?(Parse::Date) == false
          val = val.parse_date
          # if the value is a hash, then it may be the Parse hash format for an iso date.
        elsif val.is_a?(Hash) # val.respond_to?(:iso8601)
          iso_val = (val["iso"] || val[:iso]).to_s.strip.presence
          val = iso_val ? Parse::Date.parse(iso_val) : nil
        elsif val.is_a?(String)
          # if it's a string, try parsing the date
          val = (stripped = val.strip).present? ? Parse::Date.parse(stripped) : nil
          #elsif val.present?
          #  pus "[Parse::Stack] Invalid date value '#{val}' assigned to #{self.class}##{key}, it should be a Parse::Date or DateTime."
          #   raise ValueError, "Invalid date value '#{val}' assigned to #{self.class}##{key}, it should be a Parse::Date or DateTime."
        end
      when :timezone
        val = Parse::TimeZone.new(val) if val.present?
      when :phone
        val = Parse::Phone.new(val) if val.present?
      when :email
        val = Parse::Email.new(val) if val.present?
      when :vector
        # nil/blank → unset; coerce Arrays (and pass-through Parse::Vector)
        # to a Parse::Vector, which validates that every element is a
        # finite Numeric. Dimension mismatch is reported via
        # validates_each so callers can rescue ActiveModel::ValidationError
        # at save time rather than at every assignment; raising here
        # would break partial hydration where the dimension class-level
        # declaration may not yet be loaded.
        if val.nil?
          val = nil
        elsif val.is_a?(Parse::Vector)
          val = val
        elsif val.is_a?(Array)
          val = Parse::Vector.new(val)
        else
          raise ArgumentError,
                "Property #{self.class}##{key} :vector requires an Array or Parse::Vector " \
                "(got #{val.class})."
        end
      else
        # You can provide a specific class instead of a symbol format
        if data_type.respond_to?(:typecast)
          val = data_type.typecast(val)
        else
          warn "Property :#{key}: :#{data_type} has no valid data type"
          val = val #default
        end
      end
      val
    end
  end # Properties
end # Parse
