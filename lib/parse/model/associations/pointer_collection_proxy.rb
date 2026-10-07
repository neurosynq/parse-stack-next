# encoding: UTF-8
# frozen_string_literal: true

require "active_model"
require "active_support"
require "active_support/inflector"
require "active_support/core_ext/object"
require_relative "collection_proxy"

module Parse
  # A PointerCollectionProxy is a collection proxy that only allows Parse Pointers (Objects)
  # to be part of the collection. This is done by typecasting the collection to a particular
  # Parse class. Ex. An Artist may have several Song objects. Therefore an Artist could have a
  # column :songs, that is an array (collection) of Song (Parse::Object subclass) objects.
  class PointerCollectionProxy < CollectionProxy

    # @!attribute [rw] collection
    #  The internal backing store of the collection.
    #  @note If you modify this directly, it is highly recommended that you
    #   call {CollectionProxy#notify_will_change!} to notify the dirty tracking system.
    #  @return [Array<Parse::Object>]
    #  @see CollectionProxy#collection
    def collection=(c)
      notify_will_change!
      @collection = c
    end

    # Add Parse::Objects to the collection.
    # @overload add(parse_object)
    #  Add a Parse::Object or Parse::Pointer to this collection.
    #  @param parse_object [Parse::Object,Parse::Pointer] the object to add
    # @overload add(parse_objects)
    #  Add an array of Parse::Objects or Parse::Pointers to this collection.
    #  @param parse_objects [Array<Parse::Object,Parse::Pointer>] the array to append.
    # An objectId String is accepted and becomes a pointer of the declared
    # class.
    # @raise [ArgumentError] if an item is nil, of another Parse class, or
    #  cannot be turned into a pointer.
    # @return [Array<Parse::Object>] the collection
    def add(*items)
      items = typecast_items(items)
      return @collection if items.empty?
      notify_will_change!
      items.each { |item| collection.push(item) }
      @collection
    end

    alias_method :push, :add

    # Add items that are not already part of the collection.
    # @param items [Array<Parse::Object,Parse::Pointer,String>] items to uniquely add
    # @raise [ArgumentError] (see #add)
    # @return [Array<Parse::Object>] the collection
    def add_unique(*items)
      items = typecast_items(items)
      return @collection if items.empty?
      notify_will_change!
      @collection = collection | items
      @collection
    end

    alias_method :push_unique, :add_unique

    # @see #add
    def <<(*list)
      add(*list)
      self
    end

    # Replace the contents of the collection. The items are validated as in
    # {#add}.
    # @param items [Array<Parse::Object,Parse::Pointer,String>] the new contents.
    # @raise [ArgumentError] (see #add)
    # @return [self]
    def replace(items)
      super(typecast_items(Array(items.is_a?(Parse::CollectionProxy) ? items.to_a : items)))
    end

    # Removes Parse::Objects from the collection.
    # @overload remove(parse_object)
    #  Remove a Parse::Object or Parse::Pointer to this collection.
    #  @param parse_object [Parse::Object,Parse::Pointer] the object to remove
    # @overload remove(parse_objects)
    #  Remove an array of Parse::Objects or Parse::Pointers from this collection.
    #  @param parse_objects [Array<Parse::Object,Parse::Pointer>] the array of objects to remove.
    # An objectId String removes the object of the declared class with that id.
    # @return [Array<Parse::Object>] the collection
    def remove(*items)
      items = typecast_items(items, strict: false)
      return @collection if items.empty?
      notify_will_change!
      items.each { |item| collection.delete item }
      @collection
    end

    alias_method :delete, :remove

    # Atomically add a set of Parse::Objects to this collection.
    # @see CollectionProxy#add!
    # @see #add_unique!
    def add!(*items)
      super(*typecast_items(items))
    end

    # Atomically add a set of Parse::Objects to this collection for those not already
    # in the collection.
    # @see CollectionProxy#add_unique!
    # @see #add!
    def add_unique!(*items)
      super(*typecast_items(items))
    end

    # Atomically remove a set of Parse::Objects to this collection.
    # @see CollectionProxy#remove!
    def remove!(*items)
      super(*typecast_items(items, strict: false))
    end

    # Force fetch the set of pointer objects in this collection.
    # @see Array.fetch_objects!
    def fetch!
      collection.fetch_objects!
    end

    # Fetch the set of pointer objects in this collection.
    # @see Array.fetch_objects
    def fetch
      collection.fetch_objects
    end

    # Encode the collection as JSON.
    # By default, returns Parse::Pointers for backward compatibility when saving.
    # Set `pointers_only: false` to get full hydrated objects for API responses.
    # @param opts [Hash] options for serialization
    # @option opts [Boolean] :pointers_only (true) When true (default), converts all
    #   Parse objects to pointer format. Set to false to serialize full objects.
    # @option opts [Boolean] :only_fetched (true) When true (default when pointers_only
    #   is false), only serialize fields that were actually fetched. This prevents
    #   autofetch from being triggered during serialization of partially hydrated objects.
    # @example Default - pointers for storage
    #   post.assets.as_json
    #   # => [{"__type"=>"Pointer", "className"=>"Document", "objectId"=>"abc"}, ...]
    # @example Full objects for API responses (only fetched fields, no autofetch)
    #   post.assets.as_json(pointers_only: false)
    #   # => [{"objectId"=>"abc", "file"=>{...}, "caption"=>"...", ...}, ...]
    def as_json(opts = nil)
      opts ||= {}

      # Normalize string keys to symbols to avoid conflicts with defaults
      opts = opts.transform_keys { |k| k.is_a?(String) ? k.to_sym : k }

      # Check if pointers_only was explicitly set, otherwise default to true
      pointers_only = opts.fetch(:pointers_only, true)

      # Default to pointers_only: true for backward compatibility
      # When pointers_only is false, default only_fetched to true to prevent
      # autofetch during serialization of partially hydrated objects
      defaults = { pointers_only: true }
      unless pointers_only
        defaults[:only_fetched] = true unless opts.key?(:only_fetched)
      end
      opts = defaults.merge(opts)
      super(opts)
    end

    private

    # Convert the given items to Parse objects of the collection's class.
    # Parse objects and pointers are kept, pointer hashes are built, and an
    # objectId String becomes a pointer of the declared class.
    # @param items [Array] the items to convert (nested arrays are flattened).
    # @param strict [Boolean] when true, an item that cannot be converted, or
    #  belongs to another Parse class, raises. When false it is skipped.
    # @raise [ArgumentError] in strict mode, for an invalid item.
    # @return [Array<Parse::Pointer>]
    def typecast_items(items, strict: true)
      items.flatten.each_with_object([]) do |item, list|
        obj = typecast_item(item)
        if obj.nil?
          next unless strict
          raise ArgumentError, "Invalid item #{item.inspect} for #{collection_label}: " \
                               "expected a Parse::Object, Parse::Pointer or objectId String."
        end
        unless item_class_allowed?(obj.parse_class)
          next unless strict
          raise ArgumentError, "Invalid item for #{collection_label}: expected a " \
                               "#{@parse_class} object, got #{obj.parse_class}."
        end
        list << obj
      end
    end

    # The server returns the field's array as pointer hashes. Each entry
    # becomes an object of the declared class, reusing the local object with
    # the same id so fetched data is kept. The array is adopted only when
    # the declared class is a registered model and every entry is a pointer
    # to that class; anything else (another class, a bare string, a value
    # that is not a pointer) makes the operation apply locally instead,
    # rather than relabeling the entry as the declared class.
    # @return [Array<Parse::Pointer>, nil]
    def adopt_server_items(value)
      return nil if @parse_class.blank? || Parse::Model.find_class(@parse_class).nil?
      local_by_id = {}
      collection.to_a.each do |item|
        id = item.respond_to?(:id) ? item.id : nil
        local_by_id[id] ||= item if id.present?
      end
      value.map do |entry|
        class_name, object_id = server_pointer_parts(entry)
        return nil unless object_id.is_a?(String) && object_id.present?
        return nil unless Parse::Model.same_parse_class?(class_name, @parse_class)
        local_by_id[object_id] || typecast_item(entry) || (return nil)
      end
    end

    # @return [Array(String, String), nil] the className and objectId of a
    #   pointer entry from a server reply, or nil when it is not a pointer.
    def server_pointer_parts(entry)
      case entry
      when Parse::Pointer
        [entry.parse_class, entry.id]
      when Hash
        type = entry["__type"] || entry[:__type]
        return nil unless %w[Pointer Object].include?(type.to_s)
        [entry["className"] || entry[:className], entry["objectId"] || entry[:objectId]]
      end
    end

    # @return [Parse::Pointer, nil] the item as a Parse object, or nil.
    def typecast_item(item)
      case item
      when Parse::Pointer
        item
      when Hash
        type = item["__type"] || item[:__type]
        return nil if type.present? && !%w[Pointer Object].include?(type.to_s)
        # A pointer hash is wire data: with a declared class its className
        # is ignored (with a warning), as for server data.
        [item].parse_objects(@parse_class.presence).first
      when String
        return nil if item.blank? || @parse_class.blank?
        Parse::Object.build({ Parse::Model::TYPE_FIELD => Parse::Model::TYPE_POINTER,
                              Parse::Model::KEY_CLASS_NAME => @parse_class,
                              Parse::Model::OBJECT_ID => item }, @parse_class)
      end
    end

    # @return [Boolean] whether an item of `klass` may be part of this
    #   collection. The class is checked when the declared class is a
    #   registered model; a declaration naming no model (for example a
    #   has_many whose `as:` was left to default) keeps accepting any class.
    def item_class_allowed?(klass)
      return true if @parse_class.blank? || Parse::Model.find_class(@parse_class).nil?
      klass.present? && Parse::Model.same_parse_class?(klass, @parse_class)
    end

    def collection_label
      owner = @delegate.respond_to?(:parse_class) ? @delegate.parse_class : @delegate.class
      @key ? "#{owner}##{@key}" : self.class.name
    end
  end
end
