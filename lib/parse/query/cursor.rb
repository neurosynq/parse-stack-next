# encoding: UTF-8
# frozen_string_literal: true

module Parse
  # A cursor-based pagination iterator for efficiently traversing large datasets.
  #
  # Unlike skip/offset pagination which becomes increasingly slow for large datasets,
  # cursor-based pagination uses the last seen objectId to efficiently fetch the next page.
  # This approach maintains consistent performance regardless of how deep into the dataset
  # you paginate.
  #
  # @example Basic usage with each_page
  #   cursor = Song.cursor(limit: 100, order: :created_at.desc)
  #   cursor.each_page do |page|
  #     process(page)
  #   end
  #
  # @example Using each to iterate over individual items
  #   Song.cursor(limit: 50).each do |song|
  #     puts song.title
  #   end
  #
  # @example With constraints
  #   cursor = Song.cursor(artist: "Artist Name", limit: 25)
  #   cursor.each_page { |page| process(page) }
  #
  # @example Manual pagination control
  #   cursor = User.cursor(limit: 100)
  #   first_page = cursor.next_page
  #   second_page = cursor.next_page
  #   cursor.reset! # Start over from the beginning
  #
  class Cursor
    include Enumerable

    # Maximum page size allowed (Parse Server limit)
    MAX_PAGE_SIZE = 1000

    # Default page size
    DEFAULT_PAGE_SIZE = 100

    # @return [Parse::Query] the base query for this cursor
    attr_reader :query

    # @return [Integer] the number of items per page
    attr_reader :page_size

    # @return [String, nil] the current cursor position (objectId of last item)
    attr_reader :position

    # @return [Integer] the number of pages fetched so far
    attr_reader :pages_fetched

    # @return [Integer] the total number of items fetched so far
    attr_reader :items_fetched

    # @return [Symbol] the field to order by for cursor positioning
    attr_reader :order_field

    # @return [Symbol] the order direction (:asc or :desc)
    attr_reader :order_direction

    # Create a new cursor-based paginator.
    #
    # @param query [Parse::Query] the base query to paginate
    # @param limit [Integer] the number of items per page (default: 100, max: 1000)
    # @param order [Parse::Order, Symbol] the ordering for pagination.
    #   Defaults to :created_at.asc for stable ordering.
    #   Note: cursor pagination requires a stable sort order.
    # @raise [ArgumentError] if limit exceeds MAX_PAGE_SIZE
    def initialize(query, limit: DEFAULT_PAGE_SIZE, order: nil)
      @query = query.dup
      @page_size = validate_page_size(limit)
      @position = nil
      @pages_fetched = 0
      @items_fetched = 0
      @exhausted = false

      # Set up ordering - cursor pagination needs a stable order
      setup_ordering(order)
    end

    # Validate and normalize the page size.
    # @param limit [Integer] the requested page size
    # @return [Integer] the validated page size
    # @raise [ArgumentError] if limit exceeds MAX_PAGE_SIZE
    def validate_page_size(limit)
      size = [limit.to_i, 1].max

      if size > MAX_PAGE_SIZE
        raise ArgumentError, "Page size #{size} exceeds maximum allowed (#{MAX_PAGE_SIZE}). " \
                            "Parse Server limits queries to #{MAX_PAGE_SIZE} results."
      end

      size
    end
    private :validate_page_size

    # Check if more pages are available.
    # @return [Boolean] true if more pages may be available
    def more_pages?
      !@exhausted
    end

    # Check if the cursor has been exhausted (no more results).
    # @return [Boolean] true if all results have been fetched
    def exhausted?
      @exhausted
    end

    # Fetch the next page of results.
    # @return [Array<Parse::Object>] the next page of results
    # @return [Array] empty array if no more results
    def next_page
      return [] if @exhausted

      # Build the page query
      page_query = build_page_query

      # Execute the query
      results = page_query.results

      # Update state
      if results.empty? || results.size < @page_size
        @exhausted = true
      end

      unless results.empty?
        @pages_fetched += 1
        @items_fetched += results.size
        @position = extract_cursor_position(results.last)
      end

      results
    end

    # Reset the cursor to the beginning.
    # @return [self]
    def reset!
      @position = nil
      @pages_fetched = 0
      @items_fetched = 0
      @exhausted = false
      self
    end

    # Iterate over each page of results.
    # @yield [Array<Parse::Object>] each page of results
    # @return [self]
    def each_page
      return enum_for(:each_page) unless block_given?

      while more_pages?
        page = next_page
        break if page.empty?
        yield page
      end

      self
    end

    # Iterate over each individual item.
    # This is provided for Enumerable compatibility.
    # @yield [Parse::Object] each item in the result set
    # @return [self]
    def each(&block)
      return enum_for(:each) unless block_given?

      each_page do |page|
        page.each(&block)
      end

      self
    end

    # Fetch all results at once.
    # Use with caution on large datasets.
    # @return [Array<Parse::Object>] all matching objects
    def all
      results = []
      each_page { |page| results.concat(page) }
      results
    end

    # Get current cursor statistics.
    # @return [Hash] statistics about the cursor pagination
    def stats
      {
        pages_fetched: @pages_fetched,
        items_fetched: @items_fetched,
        page_size: @page_size,
        exhausted: @exhausted,
        position: @position,
        order_field: @order_field,
        order_direction: @order_direction
      }
    end

    # Serialize the cursor state to a JSON string for persistence.
    # Useful for background jobs that may be interrupted and resumed.
    #
    # @example Save cursor state for later
    #   cursor = Song.cursor(limit: 100)
    #   cursor.next_page
    #   state = cursor.serialize
    #   # Store state in Redis, database, etc.
    #
    # @example Resume in a background job
    #   state = redis.get("cursor:#{job_id}")
    #   cursor = Parse::Cursor.deserialize(state)
    #   cursor.each_page { |page| process(page) }
    #
    # @return [String] JSON string containing cursor state
    def serialize
      require 'json'
      state = {
        class_name: @query.table,
        constraints: @query.constraints(true),
        page_size: @page_size,
        position: @position,
        last_order_value: serialize_value(@last_order_value),
        last_object_id: @last_object_id,
        pages_fetched: @pages_fetched,
        items_fetched: @items_fetched,
        exhausted: @exhausted,
        order_field: @order_field,
        order_direction: @order_direction,
        version: 1  # For future compatibility
      }
      JSON.generate(state)
    end

    # Alias for serialize
    # @return [String] JSON string containing cursor state
    def to_json
      serialize
    end

    # Deserialize a cursor from a previously serialized state.
    #
    # @param json_string [String] the serialized cursor state
    # @return [Parse::Cursor] a cursor restored to the saved state
    # @raise [ArgumentError] if the JSON is invalid or missing required fields
    #
    # @example Resume a cursor
    #   cursor = Parse::Cursor.deserialize(saved_state)
    #   cursor.each_page { |page| process(page) }
    def self.deserialize(json_string)
      require 'json'
      state = JSON.parse(json_string, symbolize_names: true)

      # Validate required fields
      required = [:class_name, :page_size, :order_field, :order_direction]
      missing = required.select { |f| state[f].nil? }
      unless missing.empty?
        raise ArgumentError, "Invalid cursor state: missing #{missing.join(', ')}"
      end

      # Get the model class
      klass = Parse::Model.find_class(state[:class_name])
      unless klass
        raise ArgumentError, "Unknown Parse class: #{state[:class_name]}"
      end

      # Rebuild the query
      query = klass.query(state[:constraints] || {})

      # Create the cursor with the original order
      order = state[:order_direction].to_sym == :desc ?
        state[:order_field].to_s.to_sym.desc :
        state[:order_field].to_s.to_sym.asc

      cursor = new(query, limit: state[:page_size], order: order)

      # Restore state
      cursor.instance_variable_set(:@position, state[:position])
      cursor.instance_variable_set(:@last_order_value, deserialize_value(state[:last_order_value]))
      cursor.instance_variable_set(:@last_object_id, state[:last_object_id])
      cursor.instance_variable_set(:@pages_fetched, state[:pages_fetched] || 0)
      cursor.instance_variable_set(:@items_fetched, state[:items_fetched] || 0)
      cursor.instance_variable_set(:@exhausted, state[:exhausted] || false)

      cursor
    end

    # Alias for deserialize
    # @param json_string [String] the serialized cursor state
    # @return [Parse::Cursor] a cursor restored to the saved state
    def self.from_json(json_string)
      deserialize(json_string)
    end

    private

    # Serialize a value for JSON storage (handles dates, etc.)
    def serialize_value(value)
      case value
      when DateTime, Time
        { '__type' => 'Date', 'iso' => value.utc.iso8601(3) }
      when Date
        { '__type' => 'Date', 'iso' => value.to_datetime.utc.iso8601(3) }
      else
        value
      end
    end

    # Deserialize a value from JSON storage
    def self.deserialize_value(value)
      return value unless value.is_a?(Hash) && value['__type'] == 'Date'
      DateTime.parse(value['iso'])
    end

    # Set up the ordering for cursor pagination.
    # Cursor pagination requires a stable sort order.
    def setup_ordering(order)
      if order.nil?
        # Default to created_at ascending for stable pagination
        @order_field = :createdAt
        @order_direction = :asc
        @query.order(:created_at.asc)
      elsif order.is_a?(Parse::Order)
        @order_field = order.field.to_sym
        @order_direction = order.direction
        @query.clear(:order)
        @query.order(order)
      elsif order.respond_to?(:to_sym)
        # Handle plain symbol like :created_at (without .desc/.asc)
        order_obj = Parse::Order.new(order)
        @order_field = order_obj.field.to_sym
        @order_direction = order_obj.direction
        @query.clear(:order)
        @query.order(order)
      else
        @order_field = :createdAt
        @order_direction = :asc
        @query.order(:created_at.asc)
      end

      # Always add objectId as secondary sort for stability
      # This ensures consistent ordering when primary sort values are equal
      unless @order_field == :objectId
        secondary_order = @order_direction == :desc ? :objectId.desc : :objectId.asc
        @query.order(secondary_order)
      end
    end

    # Build the query for the next page.
    def build_page_query
      page_query = @query.dup
      page_query.limit(@page_size)

      if @position && @last_order_value && @last_object_id
        # Use composite cursor constraint to handle ties correctly:
        # (field < last_value) OR (field = last_value AND objectId < last_id)
        # This ensures no records are skipped when multiple records have the same order field value.
        or_constraint = build_cursor_constraint
        page_query.add_constraints([or_constraint])
      end

      page_query
    end

    # Build the OR constraint for cursor positioning.
    # Returns: (field < last_value) OR (field = last_value AND objectId < last_id)
    # for descending order, or the inverse for ascending.
    def build_cursor_constraint
      formatted_field = Parse::Query.format_field(@order_field)

      if @order_direction == :desc
        # Descending: (field < last_value) OR (field = last_value AND objectId < last_id)
        clause1 = { formatted_field => { "$lt" => format_cursor_value(@last_order_value) } }
        clause2 = {
          formatted_field => format_cursor_value(@last_order_value),
          "objectId" => { "$lt" => @last_object_id }
        }
      else
        # Ascending: (field > last_value) OR (field = last_value AND objectId > last_id)
        clause1 = { formatted_field => { "$gt" => format_cursor_value(@last_order_value) } }
        clause2 = {
          formatted_field => format_cursor_value(@last_order_value),
          "objectId" => { "$gt" => @last_object_id }
        }
      end

      Parse::Constraint::CompoundQueryConstraint.new(:or, [clause1, clause2])
    end

    # Format cursor value for use in constraint.
    # Handles Date/Time objects that need ISO8601 formatting for Parse.
    def format_cursor_value(value)
      case value
      when DateTime, Time
        { "__type" => "Date", "iso" => value.utc.iso8601(3) }
      when Date
        { "__type" => "Date", "iso" => value.to_datetime.utc.iso8601(3) }
      else
        value
      end
    end

    # Extract cursor position from the last item in a page.
    def extract_cursor_position(item)
      return nil unless item

      # Store both the order field value and objectId for precise cursor positioning
      @last_order_value = get_field_value(item, @order_field)
      @last_object_id = item.id

      item.id
    end

    # Get the value of a field from an item.
    def get_field_value(item, field)
      case field
      when :createdAt, :created_at
        item.created_at
      when :updatedAt, :updated_at
        item.updated_at
      when :objectId, :id
        item.id
      else
        # Try the field as a method
        if item.respond_to?(field)
          item.send(field)
        elsif item.respond_to?(:attributes) && item.attributes[field.to_s]
          item.attributes[field.to_s]
        else
          nil
        end
      end
    end
  end
end
