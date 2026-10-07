# encoding: UTF-8
# frozen_string_literal: true

require "active_support"
require "active_support/inflector"
require "active_support/core_ext/object"
require_relative "pointer_collection_proxy"

module Parse
  # The RelationCollectionProxy is similar to a PointerCollectionProxy except that
  # there is no actual "array" object in Parse. Parse treats relation through an
  # intermediary table (a.k.a. join table). Whenever a developer wants the
  # contents of a collection, the foreign table needs to be queried instead.
  # In this scenario, the parse_class: initializer argument should be passed in order to
  # know which remote table needs to be queried in order to fetch the items of the collection.
  #
  # Unlike managing an array of Pointers, relations in Parse are done throug atomic operations,
  # which have a specific API. The design of this proxy is to maintain two sets of lists,
  # items to be added to the relation and a separate list of items to be removed from the
  # relation.
  #
  # Because this relationship is based on queryable Parse table, we are also able to
  # not just get all the items in a collection, but also provide additional constraints to
  # get matching items within the relation collection.
  #
  # When creating a Relation proxy, all the delegate methods defined in the superclasses
  # need to be implemented, in addition to a few others with the key parameter:
  # _relation_query and _commit_relation_updates . :'key'_relation_query should return a
  # Parse::Query object that is properly tied to the foreign table class related to this object column.
  # Example, if an Artist has many Song objects, then the query to be returned by this method
  # should be a Parse::Query for the class 'Song'.
  # Because relation changes are separate from object changes, you can call save on a
  # relation collection to save the current add and remove operations. Because the delegate needs
  # to be informed of the changes being committed, it will be notified
  # through :'key'_commit_relation_updates message. The delegate is also in charge of
  # clearing out the change information for the collection if saved successfully.
  # @see PointerCollectionProxy
  class RelationCollectionProxy < PointerCollectionProxy
    define_attribute_methods :additions, :removals
    # @!attribute [r] removals
    #  The objects that have been newly removed to this collection
    # @return [Array<Parse::Object>]
    # @!attribute [r] additions
    #  The objects that have been newly added to this collection
    # @return [Array<Parse::Object>]
    attr_reader :additions, :removals

    def initialize(collection = nil, delegate: nil, key: nil, parse_class: nil)
      super
      @additions = []
      @removals = []
    end

    # The items of the relation. The first access queries the server for the
    # related objects, then applies the additions and removals that have not
    # been saved yet. An owner without an objectId has nothing on the server,
    # so no query is sent for it.
    # @return [Array<Parse::Object>]
    def collection
      unless @loaded
        fetched = owner_saved? ? forward(:"#{@key}_fetch!") : nil
        list = fetched.to_a.reject { |item| @removals.include?(item) }
        @additions.each { |item| list.push(item) unless list.include?(item) }
        @collection = list
        @loaded = true
      end
      @collection
    end

    # You can get items within the collection relation filtered by a specific set
    # of query constraints.
    def all(constraints = {}, &block)
      # An unsaved owner has no relation on the server yet.
      unless owner_saved?
        return block_given? ? collection.each(&block) : collection
      end
      q = query({ limit: :max }.merge(constraints))
      if block_given?
        # if we have a query, then use the Proc with it (more efficient)
        return q.present? ? q.results(&block) : collection.each(&block)
      end
      # if no block given, get all the results
      q.present? ? q.results : collection
    end

    # Ask the delegate to return a query for this collection type
    def query(constraints = {})
      q = forward :"#{@key}_relation_query"

      # Apply constraints if provided (excluding limit which is handled differently)
      query_constraints = constraints.except(:limit)
      if query_constraints.present?
        q = q.where(query_constraints)
      end

      # Apply limit if specified
      if constraints[:limit].present?
        q = q.limit(constraints[:limit])
      end

      q
    end

    # Return a query with limit applied - allows chaining like relation.limit(5).all
    def limit(count)
      query(limit: count)
    end

    # Add Parse::Objects to the relation. The change is staged and sent with
    # the next save of the owner. Staging does not query the relation.
    # Adding an item that is already staged has no further effect.
    # @overload add(parse_object)
    #  Add a Parse::Object or Parse::Pointer to this relation.
    #  @param parse_object [Parse::Object,Parse::Pointer] the object to add
    # @overload add(parse_objects)
    #  Add an array of Parse::Objects or Parse::Pointers to this relation.
    #  @param parse_objects [Array<Parse::Object,Parse::Pointer>] the array to append.
    # @raise [ArgumentError] if an item is nil, of another Parse class, or
    #  cannot be turned into a pointer.
    # @return [Array<Parse::Object>] the collection
    def add(*items)
      items = typecast_items(items)
      return @collection if items.empty?

      notify_will_change!
      additions_will_change!
      removals_will_change!
      items.each do |item|
        @additions.push(item) unless @additions.include?(item)
        @removals.delete(item)
        @collection.push(item) if @loaded && !@collection.include?(item)
      end
      @collection
    end

    alias_method :push, :add

    # Same as {#add}: a relation never holds an object twice.
    def add_unique(*items)
      add(*items)
    end

    alias_method :push_unique, :add_unique

    # Removes Parse::Objects from the relation. The change is staged and sent
    # with the next save of the owner. Staging does not query the relation.
    # @overload remove(parse_object)
    #  Remove a Parse::Object or Parse::Pointer to this relation.
    #  @param parse_object [Parse::Object,Parse::Pointer] the object to remove
    # @overload remove(parse_objects)
    #  Remove an array of Parse::Objects or Parse::Pointers from this relation.
    #  @param parse_objects [Array<Parse::Object,Parse::Pointer>] the array of objects to remove.
    # @return [Array<Parse::Object>] the collection
    def remove(*items)
      items = typecast_items(items, strict: false)
      return @collection if items.empty?
      notify_will_change!
      additions_will_change!
      removals_will_change!
      # An unsaved owner has nothing on the server to remove.
      saved = owner_saved?
      items.each do |item|
        @removals.push(item) if saved && !@removals.include?(item)
        @additions.delete(item)
        @collection.delete(item)
      end
      @collection
    end

    alias_method :delete, :remove

    # Stage the removal of every object in the relation. This loads the
    # relation to know what to remove.
    # @return [Array<Parse::Object>] the (now empty) collection.
    def clear
      remove(*collection.to_a)
      @collection
    end

    # Stage the changes that make the relation hold exactly `items`.
    # @return [self]
    def replace(items)
      items = typecast_items(Array(items.is_a?(Parse::CollectionProxy) ? items.to_a : items))
      current = collection.to_a
      stale = current.reject { |item| items.include?(item) }
      remove(*stale) if stale.any?
      fresh = items.reject { |item| current.include?(item) }
      add(*fresh) if fresh.any?
      self
    end

    # Atomically add a set of Parse::Objects to this relation.
    # This is done by making the API request directly with Parse server. On
    # success the loaded collection includes the items, and a staged
    # removal of the same items is dropped so a later save does not undo it.
    # On an owner that has not been saved yet the items are staged as in
    # {#add} and sent with the next save.
    # @return [Boolean] whether the operation succeeded.
    def add!(*items)
      return false unless @delegate.respond_to?(:op_add_relation!)
      items = typecast_items(items)
      return true if items.empty?
      return add(*items) && true unless owner_saved?
      return false unless @delegate.send(:op_add_relation!, @key, items.parse_pointers)
      items.each do |item|
        @removals.delete(item)
        @collection.push(item) if @loaded && !@collection.include?(item)
      end
      true
    end

    # @see #add!
    def add_unique!(*items)
      add!(*items)
    end

    # Atomically remove a set of Parse::Objects from this relation.
    # This is done by making the API request directly with Parse server. On
    # success the items leave the loaded collection, and a staged addition
    # of the same items is dropped.
    # @return [Boolean] whether the operation succeeded.
    def remove!(*items)
      return false unless @delegate.respond_to?(:op_remove_relation!)
      items = typecast_items(items, strict: false)
      return true if items.empty?
      return remove(*items) && true unless owner_saved?
      return false unless @delegate.send(:op_remove_relation!, @key, items.parse_pointers)
      items.each do |item|
        @additions.delete(item)
        @collection.delete(item)
      end
      true
    end

    # Marks the staged additions and removals as saved. Called after the
    # owner is saved successfully, so the operations are not sent again by a
    # later save.
    def changes_applied!
      @additions = []
      @removals = []
      super
    end

    # Drops the staged additions and removals. The items are reloaded from
    # the server on the next access.
    def rollback!
      super
      @additions = []
      @removals = []
      reset!
      @collection
    end

    # Save the changes to the relation
    def save
      unless @removals.empty? && @additions.empty?
        forward :"#{@key}_commit_relation_updates"
      end
    end

    # @see #add
    def <<(*list)
      list.each { |d| add(d) }
      @collection
    end

    private

    attr_writer :additions, :removals

    # @return [Boolean] whether the owner has an objectId to query by.
    def owner_saved?
      !(@delegate.respond_to?(:id) && @delegate.id.blank?)
    end

    # ActiveModel reads the current value when a change starts. Read the
    # items directly: going through {#collection} would query the whole
    # relation just to stage an add or remove.
    def _read_attribute(attr)
      attr.to_s == "collection" ? @collection : super
    end
  end
end
