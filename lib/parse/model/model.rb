# encoding: UTF-8
# frozen_string_literal: true

require "active_model"
require "active_support"
require "active_support/inflector"
require "active_support/core_ext/object"
require "active_model/serializers/json"
require_relative "../client"

module Parse
  # Find a corresponding Parse::Object subclass for this string or symbol
  # @param className [String] The name of the Parse class as string (ex. "_User")
  # @return [Class] The proper subclass matching the className.
  def self.classify(className)
    Parse::Model.find_class className.to_parse_class
  end

  # The core model of all Parse-Stack classes. This class works by providing a
  # baseline for all subclass objects to support ActiveModel features such as
  # serialization, dirty tracking, callbacks, etc.
  # @see ActiveModel
  class Model
    include Client::Connectable # allows easy default Parse::Client access
    include ::ActiveModel::Model
    include ::ActiveModel::Serializers::JSON # support for JSON Serializers
    include ::ActiveModel::Dirty # adds dirty tracking support
    include ::ActiveModel::Conversion
    extend ::ActiveModel::Callbacks # callback support on save, update, delete, etc.
    extend ::ActiveModel::Naming # provides the methods for getting class names from Model classes

    # Add dirty? methods as aliases for changed? methods
    # These provide compatibility with expected API
    def dirty?(field = nil)
      if field.nil?
        changed?
      else
        field_changed = "#{field}_changed?"
        respond_to?(field_changed) ? send(field_changed) : false
      end
    end

    # The name of the field in a hash that contains information about the type
    # of data the hash represents.
    TYPE_FIELD = "__type".freeze

    # The objectId field in Parse Objects.
    OBJECT_ID = "objectId".freeze
    # @see OBJECT_ID
    ID = "id".freeze

    # The key field for getting class information.
    KEY_CLASS_NAME = "className".freeze
    # @deprecated Use OBJECT_ID instead.
    KEY_OBJECT_ID = "objectId".freeze
    # The key field for getting the created at date of an object hash.
    KEY_CREATED_AT = "createdAt"
    # The key field for getting the updated at date of an object hash.
    KEY_UPDATED_AT = "updatedAt"
    # The collection for Users in Parse. Used by Parse::User.
    CLASS_USER = "_User"
    # The collection for Installations in Parse. Used by Parse::Installation.
    CLASS_INSTALLATION = "_Installation"
    # The collection for revocable Sessions in Parse. Used by Parse::Session.
    CLASS_SESSION = "_Session"
    # The collection for Roles in Parse. Used by Parse::Role.
    CLASS_ROLE = "_Role"
    # The collection for to store Products (in-App purchases) in Parse. Used by Parse::Product.
    CLASS_PRODUCT = "_Product"
    # The collection for Audiences in Parse. Used by Parse::Audience.
    CLASS_AUDIENCE = "_Audience"
    # The collection for Push Status in Parse. Used by Parse::PushStatus.
    CLASS_PUSH_STATUS = "_PushStatus"
    # The collection for background job status in Parse. Used by Parse::JobStatus.
    CLASS_JOB_STATUS = "_JobStatus"
    # The collection for scheduled background jobs in Parse. Used by Parse::JobSchedule.
    CLASS_JOB_SCHEDULE = "_JobSchedule"
    # The internal schema collection in Parse. Managed by Parse Server.
    CLASS_SCHEMA = "_SCHEMA"
    # The type label for hashes containing file data. Used by Parse::File.
    TYPE_FILE = "File"
    # The type label for hashes containing geopoints. Used by Parse::GeoPoint.
    TYPE_GEOPOINT = "GeoPoint"
    # The type label for hashes containing polygons. Used by Parse::Polygon.
    TYPE_POLYGON = "Polygon"
    # The type label for hashes containing a Parse object. Used by Parse::Object and subclasses.
    TYPE_OBJECT = "Object"
    # The type label for hashes containing a Parse date object. Used by Parse::Date.
    TYPE_DATE = "Date"
    # The type label for hashes containing 'byte' data. Used by Parse::Bytes.
    TYPE_BYTES = "Bytes"
    # The type label for hashes containing ACL data. Used by Parse::ACL
    TYPE_ACL = "ACL"
    # The type label for hashes storing numeric data.
    TYPE_NUMBER = "Number"
    # The type label for hashes containing a Parse pointer.
    TYPE_POINTER = "Pointer"
    # The type label for hashes representing relational data.
    TYPE_RELATION = "Relation"

    # To support being able to have different ruby class names from the 'table'
    # names used in Parse, we will need to have a dynamic lookup system where
    # when a parse class name received, we go through all of our subclasses to determine
    # which Parse::Object subclass is responsible for handling this Parse table class.
    # The cache is held as a class-instance variable on the singleton (rather than a
    # `@@class_var`) and guarded by a Mutex so concurrent encode/decode paths cannot
    # tear the underlying Hash. Class-instance state also keeps the cache out of any
    # subclass's reach, matching the per-class-state convention used elsewhere in
    # the SDK (see Parse::ACLScope `@no_acl_warned`).
    @model_cache = {}
    @model_cache_mutex = Mutex.new

    class << self
      # @!visibility private
      attr_reader :model_cache, :model_cache_mutex
      # @!attribute self.raise_on_save_failure
      # By default, we return `true` or `false` for save and destroy operations.
      # If you prefer to have `Parse::Object` raise an exception instead, you
      # can tell to do so either globally or on a per-model basis. When a save
      # fails, it will raise a `Parse::RecordNotSaved`.
      #
      # @example
      #   Parse::Model.raise_on_save_failure = true # globally across all models
      #   Song.raise_on_save_failure = true          # per-model
      #
      #   # or per-instance raise on failure
      #   song.save!
      #
      # When enabled, if an error is returned by Parse due to saving or
      # destroying a record, due to your `before_save` or `before_delete`
      # validation cloud code triggers, `Parse::Object` will return the a
      # `Parse::RecordNotSaved` exception type. This exception has an
      # instance method of `#object` which contains the object that failed to save.
      #
      # @return [Boolean]

      def raise_on_save_failure
        @global_raise_on_save_failure ||= false
      end

      def raise_on_save_failure=(bool)
        @global_raise_on_save_failure = bool
      end
    end

    # Find a Parse::Model subclass matching this type or Pares collection name.
    # This helper method is useful to find the corresponding class ruby Parse::Object subclass that handles
    # the provided parse class.
    #
    # @example
    #  Parse::Model.find_class('_User') # => Parse::User
    #  Parse::Model.find_class('_Date') # => Parse::Date
    #  Parse::Model.find_class('Installation') # => Parse::Installation
    #
    #  class Artist < Parse::Object
    #    parse_class "Musician"
    #  end
    #
    #  Parse::Model.find_class("Musician") # => Artist
    #
    # @param str [String] the class name
    # @return [Parse::Object] a Parse::Object subclass or a specific Parse type.
    def self.find_class(str)
      return Parse::File if str == TYPE_FILE
      return Parse::GeoPoint if str == TYPE_GEOPOINT
      return Parse::Polygon if str == TYPE_POLYGON
      return Parse::Date if str == TYPE_DATE
      return Parse::Bytes if str == TYPE_BYTES
      # return Parse::User if str == "User"
      # return Parse::Installation if str == "Installation"

      str = str.to_s
      # Basically go through all Parse::Object subclasses and see who is has a parse_class
      # set to this string. We will cache the results for future use.
      #
      # Anonymous descendants (`Class.new(Parse::Object)` without an
      # assigned constant) have `model_name.name == nil`, and the default
      # `parse_class` implementation calls `model_name.name` and raises
      # `ActiveModel::Name: Class name cannot be blank`. An unrescued
      # raise here poisons every subsequent `find_class` call (cf.
      # canonical-filter lookups, hidden-class registry, ACLScope role
      # expansion). Some tests, however, override `parse_class` on an
      # anonymous subclass to return a literal String — those are still
      # legitimate findables. Rescue per-descendant so the iteration
      # continues past the unnamed-and-default-parse_class case while
      # still considering anonymous-but-overridden ones.
      # Reference Parse::Model directly: this class method is inherited by
      # subclasses (e.g. Parse::Object.find_class), so a bare `@model_cache`
      # would resolve on the subclass singleton — which has no cache. The
      # cache lives on Parse::Model itself.
      Parse::Model.model_cache_mutex.synchronize do
        cached = Parse::Model.model_cache[str]
        return cached if cached

        result = Parse::Object.descendants.find do |f|
          begin
            cls = f.parse_class
          rescue StandardError
            next false
          end
          cls == str || cls == "_#{str}"
        end
        Parse::Model.model_cache[str] = result if result
        result
      end
    end

    # Whether two Parse class-name strings denote the same class. This is the
    # canonical equality used to suppress spurious className-mismatch warnings.
    # Two names are the same class when they are string-equal, when one is the
    # leading-underscore system form of the other (+User+ <-> +_User+, +Role+
    # <-> +_Role+, +Installation+ <-> +_Installation+, +Session+ <->
    # +_Session+), or when both resolve to the same registered +Parse::Object+
    # subclass (covers custom +parse_class+ table mappings).
    #
    # The underscore rule is what makes the comparison correct independent of
    # autoload order — at declaration time {find_class} may not yet have
    # +Parse::User+ registered (so a +belongs_to :user+ captures +"User"+
    # rather than +"_User"+), but the server always emits the +_User+ storage
    # form, and both denote the same class. The rule matches exactly one
    # system prefix underscore, so a malformed +"__User"+ is not conflated
    # with +"_User"+.
    #
    # These warnings are an ADVISORY type-confusion signal, not the
    # enforcement mechanism: every call site that consults this method builds
    # the resulting object from the declared/trusted class regardless of the
    # incoming className (see +Parse::Object.build+, which always uses the
    # +table+ argument the caller passes). A false-positive here can therefore
    # only suppress a log line — it can never route a pointer of the wrong
    # class into a typed slot. Distinct classes still compare unequal (+User+
    # vs +_Session+, +User+ vs +_Role+, and +nil+), so a genuinely mismatched
    # pointer still surfaces in logs.
    #
    # @param a [String, Symbol, nil] a Parse class name.
    # @param b [String, Symbol, nil] a Parse class name.
    # @return [Boolean] true when both names denote the same Parse class.
    def self.same_parse_class?(a, b)
      return true if a == b
      return false if a.nil? || b.nil?
      a = a.to_s
      b = b.to_s
      return true if a == b
      return true if (a == "_#{b}" && !b.start_with?("_")) ||
                     (b == "_#{a}" && !a.start_with?("_"))
      ka = find_class(a)
      !ka.nil? && ka == find_class(b)
    end
  end
end

# Add extensions to the String class.
class String
  # This method returns a camel-cased version of the string with the first letter
  # of the string in lower case. This is the standard naming convention for Parse columns
  # and property fields. This has special exception to the string "id", which returns
  # "objectId". This is the default name filtering method for all defined properties and
  # query keys in Parse::Query.
  #
  # @example
  #  "my_field".columnize # => "myField"
  #  "MyDataColumn".columnize # => "myDataColumn"
  #  "id".columnize # => "objectId" (special)
  #
  # @return [String]
  # @see Parse::Query.field_formatter
  def columnize
    return Parse::Model::OBJECT_ID if self == Parse::Model::ID
    u = "_".freeze
    (first == u ? sub(u, "") : self).camelize(:lower)
  end

  # Convert a string to a Parse class name. This method tries to find a
  # responsible Parse::Object subclass that potentially matches the given string.
  # If no match is found, it returns the camelized version of the string. This method
  # is used internally for matching association attributes to registered
  # Parse::Object subclasses. The method can also singularize the name before
  # performing conversion.
  #
  # @example
  #  "users".to_parse_class(singularize: true) # => "_User"
  #  "users".to_parse_class # => "Users"
  #  "song_data".to_parse_class # => "SongData"
  #
  # @param singularize [Boolean] whether the string should be singularized first before performing conversion.
  # @return [String] the matching Parse class for this string.
  def to_parse_class(singularize: false)
    final_class = singularize ? self.singularize.camelize : self.camelize
    klass = Parse::Model.find_class(final_class) || Parse::Model.find_class(self)
    #handles the case that a class has a custom parse table
    final_class = klass.parse_class if klass.present?
    final_class
  end
end

# Add extensions to the Symbol class.
class Symbol
  # @return [String] a lower-first-camelcased version of the symbol
  # @see String#columnize
  def columnize
    to_s.columnize.to_sym
  end

  # @see String#singularize
  def singularize
    to_s.singularize
  end

  # @see String#camelize
  def camelize
    to_s.camelize
  end

  # @see String#to_parse_class
  def to_parse_class(singularize: false)
    to_s.to_parse_class(singularize: singularize)
  end
end
