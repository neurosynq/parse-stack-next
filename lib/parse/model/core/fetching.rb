# encoding: UTF-8
# frozen_string_literal: true

require "time"
require "parallel"

module Parse
  # Combines a set of core functionality for {Parse::Object} and its subclasses.
  module Core
    # Defines the record fetching interface for instances of Parse::Object.
    module Fetching
      # Returns a thread-safe mutex for fetch operations.
      # Each instance gets its own mutex to prevent concurrent fetch operations
      # on the same object from causing race conditions.
      # @return [Mutex] the mutex used for thread-safe fetching
      # @!visibility private
      def fetch_mutex
        @fetch_mutex ||= Mutex.new
      end

      # Non-serializable instance variables that should be excluded from Marshal.
      # - @fetch_mutex: Mutex objects cannot be marshalled
      # - @client: HTTP client objects contain non-serializable connections
      NON_SERIALIZABLE_IVARS = [:@fetch_mutex, :@client].freeze

      # Custom marshal serialization to exclude non-serializable instance variables.
      # @return [Hash] instance variables suitable for Marshal serialization
      # @!visibility private
      def marshal_dump
        instance_variables.each_with_object({}) do |var, hash|
          next if NON_SERIALIZABLE_IVARS.include?(var)
          hash[var] = instance_variable_get(var)
        end
      end

      # Custom marshal deserialization to restore instance variables.
      # @param data [Hash] the serialized instance variables
      # @!visibility private
      def marshal_load(data)
        data.each do |var, value|
          instance_variable_set(var, value)
        end
        # @fetch_mutex will be lazily initialized when needed
      end

      # Force fetches and updates the current object with the data contained in the Parse collection.
      # The changes applied to the object are not dirty tracked.
      # @param keys [Array<Symbol, String>, nil] optional list of fields to fetch (partial fetch).
      #   If provided, only these fields will be fetched and the object will be marked as partially fetched.
      #   Use dot notation for nested fields (e.g., "author.name") - Parse automatically resolves the pointer.
      # @param includes [Array<String>, nil] optional list of pointer fields to resolve as FULL objects.
      #   Only needed when you want the complete nested object without field restrictions.
      # @param preserve_changes [Boolean] if true, re-apply local dirty values to fetched fields.
      #   By default (false), fetched fields accept server values and local changes are discarded.
      #   Unfetched fields always preserve their dirty state regardless of this setting.
      # @param opts [Hash] a set of options to pass to the client request.
      # @return [self] the current object, useful for chaining.
      # @example Full fetch
      #   post.fetch!
      # @example Partial fetch with specific keys
      #   post.fetch!(keys: [:title, :content])
      # @example Partial fetch with nested fields (pointer auto-resolved)
      #   post.fetch!(keys: ["title", "author.name", "author.email"])
      # @example Full nested object (includes required for full resolution)
      #   post.fetch!(keys: [:title, :author], includes: [:author])
      # @example Preserve local changes during fetch
      #   post.fetch!(keys: [:title], preserve_changes: true)
      def fetch!(keys: nil, includes: nil, preserve_changes: false, **opts)
        # Normalize keys and includes arrays once at the start for performance
        keys_array = keys.present? ? Array(keys) : nil
        includes_array = includes.present? ? Array(includes) : nil

        # Build formatted keys once (reused for query and tracking)
        formatted_keys = keys_array&.map { |k| Parse::Query.format_field(k) }

        # Build query parameters for partial fetch
        query = {}
        query[:keys] = formatted_keys.join(",") if formatted_keys
        query[:include] = includes_array.map(&:to_s).join(",") if includes_array

        response = client.fetch_object(parse_class, id, query: query.presence, **opts)
        if response.error?
          puts "[Fetch Error] #{response.code}: #{response.error}"
          # Raise appropriate error based on response code
          case response.code
          when 101 # Object not found
            raise Parse::Error::ProtocolError, "Object not found"
          else
            raise Parse::Error::ProtocolError, response.error
          end
        end

        # Handle empty results gracefully - clear the object rather than error
        result = response.result
        if result.nil? || (result.is_a?(Array) && result.empty?)
          # Mark object as deleted and clear the ID
          @_deleted = true
          @id = nil
          clear_changes!
          return self
        end

        # Handle case where result is an Array (e.g., batch operations or certain API responses)
        # This is unexpected for single-object fetch but handled defensively
        if result.is_a?(Array)
          warn "[Parse::Fetch] Unexpected array response for fetch_object (id: #{id}). This may indicate an API issue."
          result = result.find { |r| r.is_a?(Hash) && (r["objectId"] == id || r["id"] == id) }
          if result.nil?
            warn "[Parse::Fetch] Object #{id} not found in array response - marking as deleted"
            @_deleted = true
            @id = nil
            clear_changes!
            return self
          end
        end

        # If we successfully fetched data, ensure the object is not marked as deleted
        @_deleted = false

        # Capture dirty fields and their local values BEFORE applying server data
        dirty_fields = {}
        if respond_to?(:changed)
          begin
            changed_attrs = changed
            if changed_attrs.respond_to?(:each)
              changed_attrs.each do |attr|
                # Only capture if object responds to the attribute getter
                if respond_to?(attr)
                  begin
                    dirty_fields[attr.to_sym] = send(attr)
                  rescue NoMethodError => e
                    # Skip this attribute if its getter raises NoMethodError
                    warn "[Parse::Fetch] Skipping dirty field :#{attr}: #{e.message}"
                  end
                end
              end
            end
          rescue NoMethodError => e
            # Handle ActiveModel 8.x compatibility issues where `changed` method itself fails
            # due to unexpected state (e.g., after transaction rollback)
            warn "[Parse::Fetch] Warning: changed tracking unavailable: #{e.message}"
          end
        end

        # Determine if this is a partial fetch
        is_partial_fetch = keys_array.present?

        if is_partial_fetch
          # Build the new fetched keys list (top-level keys only, without nested paths)
          # Reuse formatted_keys instead of calling format_field again
          new_keys = formatted_keys.map { |k| k.split('.').first.to_sym }
          new_keys << :id unless new_keys.include?(:id)
          new_keys << :objectId unless new_keys.include?(:objectId)
          new_keys.uniq!

          # If already selectively fetched, merge with existing keys
          if has_selective_keys?
            @_fetched_keys = (@_fetched_keys + new_keys).uniq
          else
            @_fetched_keys = new_keys
          end

          # Parse keys with dot notation into nested fetched keys and merge
          new_nested_keys = Parse::Query.parse_keys_to_nested_keys(keys_array)
          if new_nested_keys.present?
            if @_nested_fetched_keys.present?
              # Merge nested keys
              new_nested_keys.each do |field, nested|
                @_nested_fetched_keys[field] ||= []
                @_nested_fetched_keys[field] = (@_nested_fetched_keys[field] + nested).uniq
              end
            else
              @_nested_fetched_keys = new_nested_keys
            end
          end
        else
          # Full fetch - clear partial fetch tracking
          @_fetched_keys = nil
          @_nested_fetched_keys = nil
        end

        # Apply attributes from server (only keys in result get updated)
        apply_attributes!(result, dirty_track: false)

        begin
          clear_changes!
        rescue => e
          # Log the error for debugging purposes
          warn "[Parse::Fetch] Warning: clear_changes! failed: #{e.class}: #{e.message}"
          # If clear_changes! fails, manually reset change tracking
          @changed_attributes = {} if instance_variable_defined?(:@changed_attributes)
          @mutations_from_database = nil if instance_variable_defined?(:@mutations_from_database)
          @mutations_before_last_save = nil if instance_variable_defined?(:@mutations_before_last_save)
        end

        # Handle previously dirty fields based on preserve_changes setting
        dirty_fields.each do |attr, local_value|
          attr_sym = attr.to_sym

          # Skip base fields (id, objectId, created_at, updated_at) - they should always accept server values
          next if Parse::Properties::BASE_KEYS.include?(attr_sym)

          # Determine the remote field name for this attribute
          remote_field = self.field_map[attr_sym]&.to_s || attr.to_s

          # Check if this field was in the server response (i.e., was fetched)
          field_in_response = result.key?(remote_field) || result.key?(attr.to_s)

          if field_in_response
            # Field was fetched from server
            current_server_value = send(attr)

            if preserve_changes
              # Re-apply local value - ActiveModel will mark dirty if value differs
              setter = "#{attr}="
              send(setter, local_value) if respond_to?(setter)
            else
              # Default behavior: accept server value, warn if local value was different
              if current_server_value != local_value
                puts "[Parse::Fetch] Field :#{attr} had unsaved changes that were discarded (local: #{local_value.inspect}, server: #{current_server_value.inspect}). Use preserve_changes: true to keep local changes."
              end
              # Server value is already applied, nothing more to do
            end
          else
            # Field was NOT fetched - always preserve dirty state
            # Use will_change! to mark as dirty since clear_changes! cleared the flag
            will_change_method = "#{attr}_will_change!"
            send(will_change_method) if respond_to?(will_change_method)
          end
        end

        self
      end

      # Fetches the object from the Parse data store. Unlike fetchIfNeeded, this always
      # fetches from the server and updates the local object with fresh data.
      # @overload fetch
      #   Full fetch - fetches all fields
      #   @return [self] the current object with updated data
      # @overload fetch(return_object)
      #   Legacy signature for backward compatibility.
      #   @param return_object [Boolean] if true returns self, if false returns raw JSON
      #   @return [self, Hash] the object or raw JSON data
      #   @deprecated Use fetch or fetch_json instead
      # @overload fetch(keys:, includes:, preserve_changes:)
      #   Partial fetch - fetches only specified fields
      #   @param keys [Array<Symbol, String>, nil] optional list of fields to fetch (partial fetch).
      #     If provided, only these fields will be fetched and the object will be marked as partially fetched.
      #     Use dot notation for nested fields (e.g., "author.name") - pointer auto-resolved.
      #   @param includes [Array<String>, nil] optional list of pointer fields to resolve as FULL objects.
      #     Only needed when you want the complete nested object without field restrictions.
      #   @param preserve_changes [Boolean] if true, re-apply local dirty values to fetched fields.
      #     By default (false), fetched fields accept server values.
      #   @return [self] the current object with updated data.
      # @example Full fetch
      #   post.fetch
      # @example Partial fetch with specific keys
      #   post.fetch(keys: [:title, :content])
      # @example Partial fetch with nested fields (pointer auto-resolved)
      #   post.fetch(keys: ["title", "author.name", "author.email"])
      # @example Preserve local changes during fetch
      #   post.fetch(keys: [:title], preserve_changes: true)
      def fetch(return_object = nil, keys: nil, includes: nil, preserve_changes: false)
        # Handle legacy signature: fetch(true) or fetch(false)
        if return_object == false
          return fetch_json(keys: keys, includes: includes)
        end
        # For fetch(), fetch(true), or fetch(keys: ..., includes: ..., preserve_changes: ...)
        fetch!(keys: keys, includes: includes, preserve_changes: preserve_changes)
        self
      end

      # Returns raw JSON data from the server without updating the current object.
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
      # @return [Parse::Object] the fetched Parse::Object (self if already fetched).
      def fetch_object
        fetch
      end

      # Validates includes against keys for fetch operations, printing debug warnings for:
      # 1. Non-pointer fields that are included (unnecessary include)
      # 2. Pointer fields that are included but also have subfield keys (redundant keys)
      # Skips validation for includes with dot notation (internal references).
      # Can be disabled by setting Parse.warn_on_query_issues = false
      # @param keys [Array] the keys array
      # @param includes [Array] the includes array
      # @!visibility private
      def validate_fetch_includes_vs_keys(keys, includes)
        return unless Parse.warn_on_query_issues
        return if includes.nil? || includes.empty?

        keys_array = Array(keys).map(&:to_s)
        fields = self.class.respond_to?(:fields) ? self.class.fields : {}

        Array(includes).each do |inc|
          inc_str = inc.to_s

          # Skip includes with dots - these are internal references (e.g., "project.owner")
          next if inc_str.include?('.')

          inc_sym = inc_str.to_sym
          field_type = fields[inc_sym]

          # Check if the field is a pointer or relation type
          is_object_field = [:pointer, :relation].include?(field_type)

          if !is_object_field && field_type.present?
            # Warn: non-object field doesn't need to be included
            puts "[Parse::Fetch] Warning: '#{inc_str}' is a #{field_type} field, not a pointer/relation - it does not need to be included (silence with Parse.warn_on_query_issues = false)"
          elsif is_object_field
            # Check if there are keys with dot notation for this field
            subfield_keys = keys_array.select { |k| k.start_with?("#{inc_str}.") }

            if subfield_keys.any?
              # Warn: including the full object makes subfield keys unnecessary
              puts "[Parse::Fetch] Warning: including '#{inc_str}' returns the full object - keys #{subfield_keys.inspect} are unnecessary (silence with Parse.warn_on_query_issues = false)"
            end
          end
        end
      end
      private :validate_fetch_includes_vs_keys

      # Autofetches the object based on a key that is not part {Parse::Properties::BASE_KEYS}.
      # If the key is not a Parse standard key, and the current object is in a
      # Pointer state or was selectively fetched, then fetch the data related to
      # this record from the Parse data store.
      # Uses a mutex for thread safety to prevent race conditions in multi-threaded contexts.
      # @param key [String] the name of the attribute being accessed.
      # @param source_info [Hash] optional info about where this autofetch was triggered from
      #   (used for N+1 detection with belongs_to associations)
      # @return [Boolean]
      def autofetch!(key, source_info: nil)
        key = key.to_sym

        # Autofetch if object is a pointer OR was selectively fetched
        # Skip if autofetch is disabled for this instance
        needs_fetch = pointer? || has_selective_keys?
        return unless needs_fetch &&
                      !autofetch_disabled? &&
                      key != :acl &&
                      !Parse::Properties::BASE_KEYS.include?(key) &&
                      respond_to?(:fetch)

        # Capture caller stack BEFORE mutex for better error tracebacks
        # Filter out internal parse-stack frames to show where user code accessed the field
        caller_stack = caller.reject { |frame| frame.include?('/lib/parse/') }

        # Use mutex for thread-safe check-and-fetch pattern
        fetch_mutex.synchronize do
          # Double-check inside mutex (another thread may have fetched)
          return if !pointer? && !has_selective_keys?

          is_pointer_fetch = pointer?

          # Track for N+1 detection if enabled
          if is_pointer_fetch && Parse.warn_on_n_plus_one
            # Check for source info in the registry (set by belongs_to getter)
            n_plus_one_source = Parse::NPlusOneDetector.lookup_source(self)
            source_class = source_info&.dig(:source_class) || n_plus_one_source&.dig(:source_class) || self.class.name
            association = source_info&.dig(:association) || n_plus_one_source&.dig(:association) || key
            Parse::NPlusOneDetector.track_autofetch(
              source_class: source_class,
              association: association,
              target_class: self.class.name,
              object_id: id
            )
          end

          # If autofetch_raise_on_missing_keys is enabled, raise an error instead of fetching
          # This helps developers identify where they need to add keys to their queries
          if Parse.autofetch_raise_on_missing_keys
            error = Parse::AutofetchTriggeredError.new(self.class, id, key, is_pointer: is_pointer_fetch)
            error.set_backtrace(caller_stack)
            raise error
          end

          # Log info about autofetch being triggered (conditional on warn_on_query_issues)
          if Parse.warn_on_query_issues
            if is_pointer_fetch
              puts "[Parse::Autofetch] Fetching #{self.class}##{id} - pointer accessed field :#{key} (silence with Parse.warn_on_query_issues = false)"
            else
              puts "[Parse::Autofetch] Fetching #{self.class}##{id} - field :#{key} was not included in partial fetch (silence with Parse.warn_on_query_issues = false)"
            end
          end

          # Autofetch always preserves changes - it's an implicit background operation
          # that shouldn't discard user modifications
          send :fetch, keys: nil, includes: nil, preserve_changes: true
        end
      end

      # Prepares object for dirty tracking by fetching if needed.
      # Must be called BEFORE will_change! to prevent autofetch from wiping dirty state.
      #
      # When will_change! captures the old value by calling the getter, it may trigger
      # autofetch if the object is a pointer. That autofetch calls clear_changes! which
      # wipes the dirty tracking state will_change! is trying to set up.
      #
      # By fetching first, the object is no longer a pointer, so will_change! can
      # proceed without triggering another fetch.
      #
      # For selective fetch objects, this also marks the field as fetched to prevent
      # autofetch during will_change!'s getter call.
      #
      # @param key [Symbol] the name of the attribute being set
      # @return [void]
      def prepare_for_dirty_tracking!(key)
        # Fetch before will_change! to prevent clear_changes! interference
        if pointer? && !autofetch_disabled?
          autofetch!(key)
        end

        # Mark selective fetch fields as fetched to prevent autofetch during will_change!
        if has_selective_keys? && !field_was_fetched?(key)
          @_fetched_keys ||= []
          @_fetched_keys << key unless @_fetched_keys.include?(key)
        end
      end
    end
  end
end

class Array

  # Perform a threaded each iteration on a set of array items.
  # @param threads [Integer] the maximum number of threads to spawn/
  # @yield the block for the each iteration.
  # @return [self]
  # @see Array#each
  # @see https://github.com/grosser/parallel Parallel
  def threaded_each(threads = 2, &block)
    Parallel.each(self, { in_threads: threads }, &block)
  end

  # Perform a threaded map operation on a set of array items.
  # @param threads [Integer] the maximum number of threads to spawn
  # @yield the block for the map iteration.
  # @return [Array] the resultant array from the map.
  # @see Array#map
  # @see https://github.com/grosser/parallel Parallel
  def threaded_map(threads = 2, &block)
    Parallel.map(self, { in_threads: threads }, &block)
  end

  # Fetches all the objects in the array even if they are not in a Pointer state.
  # @param lookup [Symbol] The methodology to use for HTTP requests. Use :parallel
  #  to fetch all objects in parallel HTTP requests. Set to anything else to
  #  perform requests serially.
  # @return [Array<Parse::Object>] an array of fetched Parse::Objects.
  # @see Array#fetch_objects
  def fetch_objects!(lookup = :parallel)
    # this gets all valid parse objects from the array
    items = valid_parse_objects
    lookup == :parallel ? items.threaded_each(2, &:fetch!) : items.each(&:fetch!)
    #self.replace items
    self #return for chaining.
  end

  # Fetches all the objects in the array that are in Pointer state.
  # @param lookup [Symbol] The methodology to use for HTTP requests. Use :parallel
  #  to fetch all objects in parallel HTTP requests. Set to anything else to
  #  perform requests serially.
  # @return [Array<Parse::Object>] an array of fetched Parse::Objects.
  # @see Array#fetch_objects!
  def fetch_objects(lookup = :parallel)
    items = valid_parse_objects
    lookup == :parallel ? items.threaded_each(2, &:fetch) : items.each(&:fetch)
    #self.replace items
    self
  end
end
