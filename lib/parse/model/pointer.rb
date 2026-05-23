# encoding: UTF-8
# frozen_string_literal: true

require "active_model"
require "active_support"
require "active_support/inflector"
require "active_support/core_ext"
require "active_model/serializers/json"
require_relative "model"

module Parse

  # The Pointer class represents the pointer type in Parse and is the superclass
  # of Parse::Object types. A pointer can be considered a type of Parse::Object
  # in which only the class name and id is known. In most cases, you may not
  # deal with Parse::Pointer objects directly if you have defined all your
  # Parse::Object subclasses.
  #
  # A `Parse::Pointer` only contains data about the specific Parse class and
  # the `id` for the object. Therefore, creating an instance of any
  # Parse::Object subclass with only the `:id` field set will be
  # considered in "pointer" state even though its specific class is not
  # `Parse::Pointer` type. The only case that you may have a Parse::Pointer
  # is in the case where an object was received for one of your classes and
  # the framework has no registered class handler for it.
  # Assume you have the tables `Post`, `Comment` and `Author` defined in your
  # remote Parse database, but have only defined `Post` and `Commentary`
  # locally.
  # @example
  #   class Post < Parse::Object
  #   end
  #
  #   class Commentary < Parse::Object
  # 	  belongs_to :post
  # 	  belongs_to :author
  #   end
  #
  #   comment = Commentary.first
  #   comment.post? # true because it is non-nil
  #   comment.artist? # true because it is non-nil
  #
  #   # both are true because they are in a Pointer state
  #   comment.post.pointer? # true
  #   comment.author.pointer? # true
  #
  #   # we have defined a Post class handler
  #   comment.post # <Post @parse_class="Post", @id="xdqcCqfngz">
  #
  #   # we have not defined an Author class handler
  #   comment.author # <Parse::Pointer @parse_class="Author", @id="hZLbW6ofKC">
  #
  #
  #   comment.post.fetch # fetch the relation
  #   comment.post.pointer? # false, it is now a full object.
  #
  # The effect is that for any unknown classes that the framework encounters,
  # it will generate Parse::Pointer instances until you define those classes
  # with valid properties and associations. While this might be ok for some
  # classes you do not use, we still recommend defining all your Parse classes
  # locally in the framework.
  #
  # Once you have a subclass, you may also create a Parse::Pointer object using
  # the _pointer_ method.
  # @example
  #   Parse::User.pointer("123456") # => Parse::Pointer for "_User" class
  #
  # @see Parse::Object
  class Pointer < Model
    # The default attributes in a Parse Pointer hash.
    ATTRIBUTES = { __type: :string, className: :string, objectId: :string }.freeze
    # @return [String] the name of the Parse class for this pointer.
    attr_accessor :parse_class
    # @return [String] the objectId field
    attr_accessor :id

    # @return [Model::TYPE_POINTER]
    def __type; Parse::Model::TYPE_POINTER; end

    alias_method :className, :parse_class
    # A Parse object as a className field and objectId. In ruby, we will use the
    # id attribute method, but for usability, we will also alias it to objectId
    alias_method :objectId, :id

    # A Parse pointer only requires the name of the remote Parse collection name,
    # and the `objectId` of the record.
    # @param table [String] The Parse class name in the Parse database.
    # @param oid [String] The objectId
    def initialize(table, oid)
      @parse_class = table.to_s
      @id = oid.to_s
    end

    # @return [String] the name of the collection for this Pointer.
    def parse_class
      @parse_class
    end

    # @return [String] a string representing the class and id of this instance.
    def sig
      "#{@parse_class}##{id || "new"}"
    end

    # @return [Hash]
    def attributes
      ATTRIBUTES
    end

    # @return [Hash] serialized JSON structure
    def json_hash
      JSON.parse to_json
    end

    # Create a new pointer with the current class name and id. While this may not make sense
    # for a pointer instance, Parse::Object subclasses use this inherited method to turn themselves into
    # pointer objects.
    # @example
    #  user = Parse::User.first
    #  user.pointer # => Parse::Pointer("_User", user.id)
    #
    # @return [Pointer] a new Pointer for this object.
    # @see Parse::Object
    def pointer
      Pointer.new parse_class, @id
    end

    # Whether this instance is in pointer state. A pointer is determined
    # if we have a parse class and an id, but no created_at or updated_at fields.
    # @return [Boolean] true if instance is in pointer state.
    def pointer?
      present? && @created_at.blank? && @updated_at.blank?
    end

    # Returns true if the data for this instance has been fetched. Because of some autofetching
    # mechanisms, this is useful to know whether the object already has data without actually causing
    # a fetch of the data.
    # @return [Boolean] true if not in pointer state.
    def fetched?
      present? && pointer? == false
    end

    # This method is a general implementation that gets overriden by Parse::Object subclass.
    # Given the class name and the id, we will go to Parse and fetch the actual record, returning the
    # Parse::Object by default.
    # @overload fetch
    #   Full fetch - fetches all fields
    #   @return [Parse::Object] the fetched Parse::Object, nil otherwise.
    # @overload fetch(return_object)
    #   Legacy signature for backward compatibility.
    #   @param return_object [Boolean] if true returns object, if false returns JSON
    #   @return [Parse::Object, Hash] the object or raw JSON data
    # @overload fetch(keys:, includes:)
    #   Partial fetch - fetches only specified fields
    #   @param keys [Array<Symbol, String>, nil] optional list of fields to fetch (partial fetch).
    #   @param includes [Array<String>, nil] optional list of pointer fields to expand.
    #   @return [Parse::Object] a partially fetched Parse::Object, nil otherwise.
    def fetch(return_object = nil, keys: nil, includes: nil)
      # Handle legacy signature: fetch(false) returns JSON
      if return_object == false
        return fetch_json(keys: keys, includes: includes)
      end

      # Build query parameters for partial fetch
      query = {}
      if keys.present?
        keys_array = Array(keys).map { |k| Parse::Query.format_field(k) }
        query[:keys] = keys_array.join(",")
      end
      if includes.present?
        includes_array = Array(includes).map(&:to_s)
        query[:include] = includes_array.join(",")
      end

      response = client.fetch_object(parse_class, id, query: query.presence)
      return nil if response.error?

      # Check if the result is empty - this indicates object not found
      result = response.result
      if result.nil? || (result.is_a?(Array) && result.empty?)
        return nil
      end

      # Convert the JSON result to a proper Parse::Object
      return nil unless result.is_a?(Hash)

      # Try to find the appropriate Parse class, fallback to Parse::Object
      klass = Parse::Model.find_class(parse_class) || Parse::Object

      # For partial fetch, build with fetched_keys tracking
      if keys.present?
        # Parse keys to get top-level field names and nested keys
        top_level_keys = Array(keys).map { |k| Parse::Query.format_field(k).split('.').first.to_sym }
        top_level_keys << :id unless top_level_keys.include?(:id)
        top_level_keys << :objectId unless top_level_keys.include?(:objectId)
        top_level_keys.uniq!

        # Parse dot notation into nested fetched keys
        nested_keys = Parse::Query.parse_keys_to_nested_keys(Array(keys))

        obj = klass.build(result, parse_class, fetched_keys: top_level_keys, nested_fetched_keys: nested_keys.presence)
      else
        # Full fetch - create without partial fetch tracking
        obj = klass.new(result)
      end

      obj.clear_changes! if obj.respond_to?(:clear_changes!)
      obj
    end

    # Returns raw JSON data from the server without creating an object.
    # @param keys [Array<Symbol, String>, nil] optional list of fields to fetch.
    # @param includes [Array<String>, nil] optional list of pointer fields to expand.
    # @return [Hash, nil] the raw JSON data or nil if error.
    def fetch_json(keys: nil, includes: nil)
      query = {}
      if keys.present?
        keys_array = Array(keys).map { |k| Parse::Query.format_field(k) }
        query[:keys] = keys_array.join(",")
      end
      if includes.present?
        includes_array = Array(includes).map(&:to_s)
        query[:include] = includes_array.join(",")
      end

      response = client.fetch_object(parse_class, id, query: query.presence)
      return nil if response.error?
      response.result
    end

    # Fetches the Parse object from the data store and returns a Parse::Object instance.
    # This is a convenience method that calls fetch.
    # @return [Parse::Object] the fetched Parse::Object, nil otherwise.
    def fetch_object
      fetch
    end

    # Two Parse::Pointers (or Parse::Objects) are equal if both of them have
    # the same Parse class and the same id.
    # @return [Boolean]
    def ==(o)
      return false unless o.is_a?(Pointer)
      #only equal if the Parse class and object ID are the same.
      self.parse_class == o.parse_class && id == o.id
    end

    alias_method :eql?, :==

    # Compute a hash-code for this object based on identity (class and id).
    # This is consistent with the == method which compares by parse_class and id.
    #
    # Two objects with the same class and id will have the same hash code
    # regardless of their dirty state or other attributes. This is important for:
    # - Array operations (uniq, &, |) to work correctly based on identity
    # - Hash key lookups to find objects by identity
    # - Set operations
    #
    # @return [Integer] hash code based on class name and object id
    def hash
      [parse_class, id].hash
    end

    # @return [Boolean] true if instance has a Parse class and an id.
    def present?
      parse_class.present? && @id.present?
    end

    # Access the pointer properties through hash accessor. This is done for
    # compatibility with the hash access of a Parse::Object. This method
    # returns nil if the key is not one of: :id, :objectId, or :className.
    # @param key [String] the name of the property.
    # @return [Object] the value for this key.
    def [](key)
      return nil unless [:id, :objectId, :className].include?(key.to_sym)
      send(key)
    end

    # Handles method calls for properties that exist on the target model class.
    # When a property is accessed on a Pointer, this will auto-fetch the object
    # and delegate the method call to the fetched object.
    #
    # If Parse.autofetch_raise_on_missing_keys is enabled, this will raise
    # Parse::AutofetchTriggeredError instead of fetching.
    #
    # @example
    #   pointer = Post.pointer("abc123")
    #   pointer.title  # auto-fetches and returns title
    #
    # @param method_name [Symbol] the method being called
    # @param args [Array] arguments to the method
    # @param block [Proc] optional block
    # @return [Object] the result of calling the method on the fetched object
    # @raise [Parse::AutofetchTriggeredError] if autofetch_raise_on_missing_keys is enabled
    def method_missing(method_name, *args, &block)
      # Try to find the model class for this pointer
      klass = Parse::Model.find_class(parse_class)

      # If no class is registered or the class doesn't have this field, use default behavior
      unless klass && klass.respond_to?(:fields) && klass.fields[method_name.to_s.chomp('=').to_sym]
        return super
      end

      # We have a registered class with this field - handle autofetch
      field_name = method_name.to_s.chomp('=').to_sym

      # If autofetch_raise_on_missing_keys is enabled, raise an error
      if Parse.autofetch_raise_on_missing_keys
        raise Parse::AutofetchTriggeredError.new(klass, id, field_name, is_pointer: true)
      end

      # Log info about autofetch being triggered
      if Parse.warn_on_query_issues
        puts "[Parse::Autofetch] Fetching #{parse_class}##{id} - pointer accessed field :#{field_name} (silence with Parse.warn_on_query_issues = false)"
      end

      # Fetch the object and delegate the method call
      @_fetched_object ||= fetch
      return nil unless @_fetched_object

      @_fetched_object.send(method_name, *args, &block)
    end

    # Indicates whether this object responds to methods that would trigger autofetch.
    # Returns true for properties defined on the target model class.
    #
    # @param method_name [Symbol] the method name to check
    # @param include_private [Boolean] whether to include private methods
    # @return [Boolean] true if the method can be handled
    def respond_to_missing?(method_name, include_private = false)
      klass = Parse::Model.find_class(parse_class)
      if klass && klass.respond_to?(:fields)
        field_name = method_name.to_s.chomp('=').to_sym
        return true if klass.fields[field_name]
      end
      super
    end

    # Set the pointer properties through hash accessor. This is done for
    # compatibility with the hash access of a Parse::Object. This method
    # does nothing if the key is not one of: :id, :objectId, or :className.
    # @param key (see #[])
    # @return [Object]
    def []=(key, value)
      return unless [:id, :objectId, :className].include?(key.to_sym)
      send("#{key}=", value)
    end
  end
end

# extensions
class Array
  # This method maps all the ids (String) of all Parse::Objects in the array.
  # @return [Array<String>] an array of strings of ids.
  def objectIds
    map { |m| m.is_a?(Parse::Pointer) ? m.id : nil }.compact
  end

  # Filter all objects in the array that do not inherit from Parse::Pointer or
  # Parse::Object.
  # @return [Array<Parse::Object,Parse::Pointer>] an array of Parse::Objects.
  def valid_parse_objects
    select { |s| s.is_a?(Parse::Pointer) }
  end

  # Convert all potential objects in the array to a list of Parse::Pointer instances.
  # The array can contain a mixture of objects types including JSON Parse-like hashes.
  # @return [Array<Parse::Pointer>] an array of Parse::Pointer objects.
  def parse_pointers(table = nil)
    self.map do |m|
      #if its an exact Parse::Pointer
      if m.is_a?(Parse::Pointer) || m.respond_to?(:pointer)
        next m.pointer
      elsif m.is_a?(Hash) && m[Parse::Model::KEY_CLASS_NAME] && m[Parse::Model::OBJECT_ID]
        next Parse::Pointer.new m[Parse::Model::KEY_CLASS_NAME], m[Parse::Model::OBJECT_ID]
      elsif m.is_a?(Hash) && m[:className] && m[:objectId]
        next Parse::Pointer.new m[:className], m[:objectId]
      end
      nil
    end.compact
  end
end
