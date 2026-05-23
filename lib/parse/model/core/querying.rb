# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../query"

module Parse
  module Core
    # Defines the querying methods applied to a Parse::Object.
    module Querying

      # This feature is a small subset of the
      # {http://guides.rubyonrails.org/active_record_querying.html#scopes
      # ActiveRecord named scopes} feature. Scoping allows you to specify
      # commonly-used queries which can be referenced as class method calls and
      # are chainable with other scopes. You can use every {Parse::Query}
      # method previously covered such as `where`, `includes` and `limit`.
      #
      #  class Article < Parse::Object
      #    property :published, :boolean
      #    scope :published, -> { query(published: true) }
      #  end
      #
      # This is the same as defining your own class method for the query.
      #
      #  class Article < Parse::Object
      #    def self.published
      #      query(published: true)
      #    end
      #  end
      #
      # You can also chain scopes and pass parameters. In addition, boolean and
      # enumerated properties have automatically generated scopes for you to use.
      #
      #  class Article < Parse::Object
      #    scope :published, -> { query(published: true) }
      #
      #    property :comment_count, :integer
      #    property :category
      #    property :approved, :boolean
      #
      #    scope :published_and_commented, -> { published.where :comment_count.gt => 0 }
      #    scope :popular_topics, ->(name) { published_and_commented.where category: name }
      #  end
      #
      #  # simple scope
      #  Article.published # => where published is true
      #
      #  # chained scope
      #  Article.published_and_commented # published is true and comment_count > 0
      #
      #  # scope with parameters
      #  Article.popular_topic("music") # => popular music articles
      #  # equivalent: where(published: true, :comment_count.gt => 0, category: name)
      #
      #  # automatically generated scope
      #  Article.approved(category: "tour") # => where approved: true, category: 'tour'
      #
      # If you would like to turn off automatic scope generation for property types,
      # set the option `:scope` to false when declaring the property.
      # @param name [Symbol] the name of the scope.
      # @param body [Proc] the proc related to the scope.
      # @raise ArgumentError if body parameter does not respond to `call`
      # @return [Symbol] the name of the singleton method created.
      def scope(name, body)
        unless body.respond_to?(:call)
          raise ArgumentError, "The scope body needs to be callable."
        end

        name = name.to_sym
        if respond_to?(name, true)
          puts "Creating scope :#{name}. Will overwrite existing method #{self}.#{name}."
        end

        define_singleton_method(name) do |*args, &block|
          if body.arity.zero?
            res = body.call
            res.conditions(*args) if args.present?
          else
            res = body.call(*args)
          end

          _q = res || query

          if _q.is_a?(Parse::Query)
            klass = self
            _q.define_singleton_method(:method_missing) do |m, *args, &chained_block|
              if klass.respond_to?(m, true)
                # must be a scope
                klass_scope = klass.send(m, *args)
                if klass_scope.is_a?(Parse::Query)
                  # merge constraints
                  add_constraints(klass_scope.constraints)
                  # if a block was passed, execute the query, otherwise return the query
                  return chained_block.present? ? results(&chained_block) : self
                end # if
                klass = nil # help clean up ruby gc
                return klass_scope
              end
              klass = nil # help clean up ruby gc
              return results.send(m, *args, &chained_block)
            end
          end

          Parse::Query.apply_auto_introspection!(_q)

          return _q if block.nil?
          _q.results(&block)
        end
      end

      # Creates a new {Parse::Query} with the given constraints for this class.
      # @example
      #  # assume Post < Parse::Object
      #  query = Post.query(:updated_at.before => DateTime.now)
      # @return [Parse::Query] a new query with the given constraints for this
      #  Parse::Object subclass.
      def query(constraints = {})
        Parse::Query.new self.parse_class, constraints
      end

      alias_method :where, :query

      # @param conditions (see Parse::Query#where)
      # @return (see Parse::Query#where)
      # @see Parse::Query#where
      def literal_where(conditions = {})
        query.where(conditions)
      end

      # This methods allow you to efficiently iterate over all the records in the collection
      # (lower memory cost) at a minor cost of performance. This method utilizes
      # the `created_at` field of Parse records to order and iterate over *all* matching records,
      # therefore you should not use this method if you want to perform a query
      # with constraints against the `created_at` field or need specific type of ordering.
      # If you need to use `:created_at` in your constraints, consider using {Parse::Core::Querying#all} or
      # {Parse::Core::Actions::ClassMethods#save_all}
      # @param constraints [Hash] a set of query constraints.
      # @yield a block which will iterate through each matching record.
      # @example
      #
      #  post = Post.first
      #  # iterate over all comments matching conditions
      #  Comment.each(post: post) do |comment|
      #     # ...
      #  end
      # @return [Parse::Object] the last Parse::Object record processed.
      # @note You cannot use *:created_at* as a constraint.
      # @raise ArgumentError if :created_at is detected in the constraints argument.
      # @see Parse::Core::Querying.all
      # @see Parse::Core::Actions.save_all
      def each(constraints = {}, &block)
        # verify we don't hvae created at as a constraint, otherwise this will not work
        invalid_constraints = constraints.keys.any? do |k|
          (k == :created_at || k == :createdAt) ||
          (k.is_a?(Parse::Operation) && (k.operand == :created_at || k.operand == :createdAt))
        end
        if invalid_constraints
          raise ArgumentError, "[#{self.class}.each] Special method each()" \
                               "cannot be used with a :created_at constraint."
        end
        batch_size = 250
        start_cursor = first(order: :created_at.asc, keys: :created_at)
        constraints.merge! cache: false, limit: batch_size, order: :created_at.asc
        _all_query = query(constraints) # used for reference in loop below
        cursor = start_cursor
        # the exclusion set is a set of ids not to include the next query.
        exclusion_set = []
        loop do
          _q = query(constraints.dup)
          _q.where(:created_at.on_or_after => cursor.created_at)
          # set of ids not to include in the next query. non-performant, but accurate.
          _q.where(:id.nin => exclusion_set) unless exclusion_set.empty?
          results = _q.results # get results

          break cursor if results.empty? # break if no results
          results.each(&block)
          next_cursor = results.last
          # break if we got less than the maximum requested
          break next_cursor if results.count < batch_size
          # break if the next object is the same as the current object.
          break next_cursor if cursor.id == next_cursor.id
          # The exclusion set is used in the case where multiple records have the exact
          # same created_at date (down to the microsecond). This prevents getting the same
          # record in the next query request.
          exclusion_set = results.select { |r| r.created_at == next_cursor.created_at }.map(&:id)
          results = nil
          cursor = next_cursor
        end
      end

      # Fetch all matching objects in this collection matching the constraints.
      # This will be the most common way when querying Parse objects for a subclass.
      # When no block is passed, all objects are returned. Using a block is more memory
      # efficient as matching objects are fetched in batches and discarded after the iteration
      # is completed.
      # @param constraints [Hash] a set of {Parse::Query} constraints.
      # @yield a block to iterate with each matching object.
      # @example
      #
      #  songs = Song.all( ... expressions ...) # => array of Parse::Objects
      #  # memory efficient for large amounts of records.
      #  Song.all( ... expressions ...) do |song|
      #      # ... do something with song..
      #  end
      #
      # @note This method will continually query for records by automatically
      #   incrementing the *:skip* parameter until no more results are returned
      #   by the server.
      # @return [Array<Parse::Object>] an array of matching objects. If a block is passed,
      #  an empty array is returned.
      def all(constraints = { limit: :max }, &block)
        constraints = constraints.reverse_merge({ limit: :max })
        prepared_query = query(constraints)
        return prepared_query.results(&block) if block_given?
        prepared_query.results
      end

      # Returns the first item matching the constraint.
      # @overload first(count = 1)
      #  @param count [Interger] The number of items to return.
      #  @example
      #   Object.first(2) # => an array of the first 2 objects in the collection.
      #  @return [Parse::Object] if count == 1
      #  @return [Array<Parse::Object>] if count > 1
      # @overload first(constraints = {})
      #  @param constraints [Hash] a set of {Parse::Query} constraints.
      #  @example
      #   Object.first( :name => "Anthony" )
      #  @return [Parse::Object] the first matching object.
      def first(constraints = {})
        fetch_count = 1
        if constraints.is_a?(Numeric)
          fetch_count = constraints.to_i
          constraints = {}
        end
        constraints.merge!({ limit: fetch_count })
        res = query(constraints).results
        return res.first if fetch_count == 1
        return res.first fetch_count
      end

      # Returns the most recently created object (ordered by created_at descending).
      # @overload latest(count = 1)
      #  @param count [Integer] The number of items to return.
      #  @example
      #   Object.latest(3) # => an array of the 3 most recently created objects.
      #  @return [Parse::Object] if count == 1
      #  @return [Array<Parse::Object>] if count > 1
      # @overload latest(constraints = {})
      #  @param constraints [Hash] a set of {Parse::Query} constraints.
      #   Supports a :limit key to override the default limit of 1.
      #  @example
      #   Object.latest(category: "news") # => most recent object in news category
      #   Object.latest(:user.eq => user, limit: 5) # => 5 most recent for user
      #  @return [Parse::Object] the most recently created object matching constraints.
      def latest(constraints = {})
        fetch_count = 1
        if constraints.is_a?(Numeric)
          fetch_count = constraints.to_i
          constraints = {}
        else
          # Allow limit to be specified in constraints hash
          fetch_count = constraints.delete(:limit) || 1
        end
        constraints.merge!({ limit: fetch_count, order: :created_at.desc })
        res = query(constraints).results
        return res.first if fetch_count == 1
        return res.first fetch_count
      end

      # Returns the most recently updated object (ordered by updated_at descending).
      # @overload last_updated(count = 1)
      #  @param count [Integer] The number of items to return.
      #  @example
      #   Object.last_updated(5) # => an array of the 5 most recently updated objects.
      #  @return [Parse::Object] if count == 1
      #  @return [Array<Parse::Object>] if count > 1
      # @overload last_updated(constraints = {})
      #  @param constraints [Hash] a set of {Parse::Query} constraints.
      #   Supports a :limit key to override the default limit of 1.
      #  @example
      #   Object.last_updated(status: "active") # => most recently updated active object
      #   Object.last_updated(:user.eq => user, limit: 3) # => 3 most recently updated for user
      #  @return [Parse::Object] the most recently updated object matching constraints.
      def last_updated(constraints = {})
        fetch_count = 1
        if constraints.is_a?(Numeric)
          fetch_count = constraints.to_i
          constraints = {}
        else
          # Allow limit to be specified in constraints hash
          fetch_count = constraints.delete(:limit) || 1
        end
        constraints.merge!({ limit: fetch_count, order: :updated_at.desc })
        res = query(constraints).results
        return res.first if fetch_count == 1
        return res.first fetch_count
      end

      # Creates a count request which is more performant when counting objects.
      # @example
      #  # number of songs with a like count greater than 20.
      #  count = Song.count( :like_count.gt => 20 )
      # @param constraints (see #all)
      # @return [Interger] the number of records matching the query.
      # @see Parse::Query#count
      def count(constraints = {})
        query(constraints).count
      end

      # Counts the number of distinct values for a specified field.
      # Uses MongoDB aggregation pipeline to efficiently count unique values.
      # @example
      #  # get count of unique genres for songs with play_count > 100
      #  distinct_genres_count = Song.count_distinct(:genre, :play_count.gt => 100)
      #  # get total number of unique users
      #  unique_users = User.count_distinct(:objectId)
      # @param field [Symbol|String] The name of the field to count distinct values for.
      # @param constraints (see #all)
      # @return [Integer] the number of distinct values
      # @see Parse::Query#count_distinct
      def count_distinct(field, constraints = {})
        query(constraints).count_distinct(field)
      end

      # Finds the distinct values for a specified field across a single
      # collection or view and returns the results in an array.
      # @example
      #  # get a list of unique city names for users who are older than 21.
      #  cities = User.distinct(:city, :age.gt => 21 )
      # @param field The name of the field to use for unique aggregation.
      # @param constraints (see #all)
      # @return [Array] a list of distinct values
      # @see Parse::Query#distinct
      def distinct(field, constraints = {})
        query(constraints).distinct(field)
      end

      # Find objects matching the constraint ordered by the descending created_at date.
      # @param constraints (see #all)
      # @return [Array<Parse::Object>]
      def newest(constraints = {})
        constraints.merge!(order: :created_at.desc)
        _q = query(constraints)
        _q.define_singleton_method(:method_missing) { |m, *args, &block| self.results.send(m, *args, &block) }
        _q
      end

      # Find objects matching the constraint ordered by the ascending created_at date.
      # @param constraints (see #all)
      # @return [Array<Parse::Object>]
      def oldest(constraints = {})
        constraints.merge!(order: :created_at.asc)
        _q = query(constraints)
        _q.define_singleton_method(:method_missing) { |m, *args, &block| self.results.send(m, *args, &block) }
        _q
      end

      # Create a cursor-based paginator for efficiently traversing large datasets.
      # This is more efficient than skip/offset pagination for large result sets.
      #
      # @example Basic usage
      #   cursor = Song.cursor(limit: 100, order: :created_at.desc)
      #   cursor.each_page do |page|
      #     process(page)
      #   end
      #
      # @example With constraints
      #   cursor = Song.cursor(artist: "Artist Name", limit: 50)
      #   cursor.each { |song| puts song.title }
      #
      # @param constraints [Hash] query constraints to apply
      # @param limit [Integer] number of items per page (default: 100)
      # @param order [Symbol, Parse::Order] the ordering for pagination
      # @return [Parse::Cursor] a cursor for paginating results
      # @see Parse::Cursor
      def cursor(constraints = {}, limit: 100, order: nil)
        query(constraints).cursor(limit: limit, order: order)
      end

      # Subscribe to real-time updates for objects in this collection.
      # Uses Parse LiveQuery WebSocket connection to receive push notifications
      # when objects are created, updated, deleted, or enter/leave the query results.
      #
      # @example Basic subscription (all objects)
      #   subscription = Song.subscribe
      #   subscription.on(:create) { |song| puts "New song: #{song.title}" }
      #   subscription.on(:update) { |song, original| puts "Updated!" }
      #   subscription.on(:delete) { |song| puts "Deleted!" }
      #
      # @example Subscribe with query constraints
      #   subscription = Song.subscribe(where: { artist: "Beatles" })
      #   subscription.on_create { |song| puts "New Beatles song!" }
      #
      # @example With field filtering
      #   subscription = User.subscribe(where: { status: "online" }, fields: ["name", "avatar"])
      #   subscription.on_update { |user| puts "User changed: #{user.name}" }
      #
      # @example With session token for ACL-aware subscriptions
      #   subscription = PrivateData.subscribe(session_token: current_user.session_token)
      #
      # @param where [Hash] query constraints for the subscription
      # @param fields [Array<String>] specific fields to watch for changes (nil = all fields)
      # @param session_token [String] session token for ACL-aware subscriptions
      # @param client [Parse::LiveQuery::Client] custom LiveQuery client (optional)
      # @return [Parse::LiveQuery::Subscription] the subscription object
      # @see Parse::LiveQuery::Subscription
      # @see Parse::Query#subscribe
      def subscribe(where: {}, fields: nil, session_token: nil, client: nil)
        query(where).subscribe(fields: fields, session_token: session_token, client: client)
      end

      # Find objects for a given objectId in this collection. The result is a list
      # (or single item) of the objects that were successfully found.
      # By default, bypasses the cache to ensure fresh data from the server.
      # @example
      #  Object.find "<objectId>"
      #  Object.find "<objectId>", "<objectId>"....
      #  Object.find ["<objectId>", "<objectId>"]
      #  Object.find "<objectId>", cache: true  # opt-in to cache
      # @param parse_ids [String] the objectId to find.
      # @param type [Symbol] the fetching methodology to use if more than one id was passed.
      #  - *:parallel* : Utilizes parrallel HTTP requests to fetch all objects requested.
      #  - *:batch* : This uses a batch fetch request using a contained_in clause.
      # @param compact [Boolean] whether to remove nil items from the returned array for objects
      #  that were not found.
      # @param cache [Boolean, Symbol] caching mode. Defaults to :write_only when Parse.cache_write_on_fetch is true.
      #   - :write_only (default) - skip cache read, but update cache with fresh data
      #   - true - read from and write to cache
      #   - false - completely bypass cache (no read or write)
      # @return [Parse::Object] if only one id was provided as a parameter.
      # @return [Array<Parse::Object>] if more than one id was provided as a parameter.
      def find(*parse_ids, type: :parallel, compact: true, cache: nil)
        # flatten the list of Object ids.
        parse_ids.flatten!
        parse_ids.compact!
        # determines if the result back to the call site is an array or a single result
        as_array = parse_ids.count > 1
        results = []

        # Default to write-only cache mode - find always gets fresh data
        # but updates cache for future cached reads. Controlled by feature flag.
        if cache.nil?
          cache = Parse.cache_write_on_fetch ? :write_only : false
        end

        # Extract cache option for client requests
        client_opts = { cache: cache }

        if type == :batch
          # use a .in query with the given id as a list
          query = self.class.query(:id.in => parse_ids)
          query.cache = cache
          results = query.results
        else
          # use Parallel to make multiple threaded requests for finding these objects.
          # The benefit of using this as default is that each request goes to a specific URL
          # which is better than Query request (table scan). This in turn allows for caching of
          # individual objects.
          results = parse_ids.threaded_map do |parse_id|
            next nil unless parse_id.present?
            response = client.fetch_object(parse_class, parse_id, **client_opts)
            next nil if response.error?
            Parse::Object.build response.result, parse_class
          end
        end
        # removes any nil items in the array
        results.compact! if compact

        as_array ? results : results.first
      end

      alias_method :get, :find

      # Find objects with caching enabled. This is a convenience method that calls
      # find with cache: true.
      # @example
      #  Object.find_cached "<objectId>"
      #  Object.find_cached "<objectId>", "<objectId>"....
      # @param parse_ids [String] the objectId(s) to find.
      # @param type [Symbol] the fetching methodology (:parallel or :batch).
      # @param compact [Boolean] whether to remove nil items from the returned array.
      # @return [Parse::Object] if only one id was provided as a parameter.
      # @return [Array<Parse::Object>] if more than one id was provided as a parameter.
      # @see #find
      def find_cached(*parse_ids, type: :parallel, compact: true)
        find(*parse_ids, type: type, compact: compact, cache: true)
      end
    end # Querying
  end
end
