# encoding: UTF-8
# frozen_string_literal: true

require_relative "client"
require_relative "query/operation"
require_relative "query/constraints"
require_relative "query/ordering"
require_relative "query/cursor"
require_relative "query/n_plus_one_detector"
require "active_model"
require "active_model/serializers/json"
require "active_support"
require "active_support/inflector"
require "active_support/core_ext"

module Parse
  # The {Parse::Query} class provides the lower-level querying interface for
  # your Parse collections by utilizing the {http://docs.parseplatform.org/rest/guide/#queries
  # REST Querying interface}. This is the main engine behind making Parse queries
  # on remote collections. It takes a set of constraints and generates the
  # proper hash parameters that are passed to an API request in order to retrive
  # matching results. The querying design pattern is inspired from
  # {http://datamapper.org/ DataMapper} where symbols are overloaded with
  # specific methods with attached values.
  #
  # At the core of each item is a {Parse::Operation}. An operation is
  # made up of a field name and an operator. Therefore calling
  # something like :name.eq, defines an equality operator on the field
  # name. Using {Parse::Operation}s with values, we can build different types of
  # constraints, known as {Parse::Constraint}s.
  #
  # This component can be used on its own without defining your models as all
  # results are provided in hash form.
  #
  # *Field-Formatter*
  #
  # By convention in Ruby (see
  # {https://github.com/bbatsov/ruby-style-guide#snake-case-symbols-methods-vars Style Guide}),
  # symbols and variables are expressed in lower_snake_case form. Parse, however,
  # prefers column names in {String#columnize} format (ex. `objectId`,
  # `createdAt` and `updatedAt`). To keep in line with the style
  # guides between the languages, we do the automatic conversion of the field
  # names when compiling the query. This feature can be overridden by changing the
  # value of {Parse::Query.field_formatter}.
  #
  #  # default uses :columnize
  #  query = Parse::User.query :field_one => 1, :FieldTwo => 2, :Field_Three => 3
  #  query.compile_where # => {"fieldOne"=>1, "fieldTwo"=>2, "fieldThree"=>3}
  #
  #  # turn off
  #  Parse::Query.field_formatter = nil
  #  query = Parse::User.query :field_one => 1, :FieldTwo => 2, :Field_Three => 3
  #  query.compile_where # => {"field_one"=>1, "FieldTwo"=>2, "Field_Three"=>3}
  #
  #  # force everything camel case
  #  Parse::Query.field_formatter = :camelize
  #  query = Parse::User.query :field_one => 1, :FieldTwo => 2, :Field_Three => 3
  #  query.compile_where # => {"FieldOne"=>1, "FieldTwo"=>2, "FieldThree"=>3}
  #
  # Most of the constraints supported by Parse are available to `Parse::Query`.
  # Assuming you have a column named `field`, here are some examples. For an
  # explanation of the constraints, please see
  # {http://docs.parseplatform.org/rest/guide/#queries Parse Query Constraints documentation}.
  # You can build your own custom query constraints by creating a `Parse::Constraint`
  # subclass. For all these `where` clauses assume `q` is a `Parse::Query` object.
  class Query
    extend ::ActiveModel::Callbacks
    include Parse::Client::Connectable
    include Enumerable

    # Known Parse classes for fast validation - dynamically loaded from schema
    def self.known_parse_classes
      @known_parse_classes ||= begin
          # Get all classes from Parse schema
          response = Parse.client.schemas
          schema_classes = response.success? ? response.result.dig("results")&.map { |cls| cls["className"] } || [] : []
          # Add built-in Parse classes
          built_in_classes = %w[_User _Role _Session _Installation _Audience User Role Session Installation Audience]
          (built_in_classes + schema_classes).uniq.freeze
        rescue
          # Fallback to built-in classes if schema query fails (e.g., during testing without server)
          %w[_User _Role _Session _Installation _Audience User Role Session Installation Audience].freeze
        end
    end

    # Allow resetting the cached known classes (useful for testing)
    def self.reset_known_parse_classes!
      @known_parse_classes = nil
    end
    # @!group Callbacks
    #
    # @!method before_prepare
    #   A callback called before the query is compiled
    #   @yield A block to execute for the callback.
    #   @see ActiveModel::Callbacks
    # @!method after_prepare
    #   A callback called after the query is compiled
    #   @yield A block to execute for the callback.
    #   @see ActiveModel::Callbacks
    # @!endgroup
    define_model_callbacks :prepare, only: [:after, :before]
    # A query needs to be tied to a Parse table name (Parse class)
    # The client object is of type Parse::Client in order to send query requests.
    # You can modify the default client being used by all Parse::Query objects by setting
    # Parse::Query.client. You can override individual Parse::Query object clients
    # by changing their client variable to a different Parse::Client object.

    # @!attribute [rw] table
    #  @return [String] the name of the Parse collection to query against.
    # @!attribute [rw] client
    #  @return [Parse::Client] the client to use for the API Query request.
    # @!attribute [rw] key
    #  This parameter is used to support `select` queries where you have to
    #  pass a `key` parameter for matching different tables.
    #  @return [String] the foreign key to match against.
    # @!attribute [rw] cache
    #  Set whether this query should be cached and for how long. This parameter
    #  is used to cache queries when using {Parse::Middleware::Caching}. If
    #  the caching middleware is configured, all queries will be cached for the
    #  duration allowed by the cache, and therefore some queries could return
    #  cached results. To disable caching and cached results for this specific query,
    #  you may set this field to `false`. To specify the specific amount of time
    #  you want this query to be cached, set a duration (in number of seconds) that
    #  the caching middleware should cache this request.
    #  @example
    #   # find all users with name "Bob"
    #   query = Parse::Query.new("_User", :name => "Bob")
    #
    #   query.cache = true # (default) cache using default cache duration.
    #
    #   query.cache = 1.day # cache for 86400 seconds
    #
    #   query.cache = false # do not cache or use cache results
    #
    #   # You may optionally pass this into the constraint hash.
    #   query = Parse::Query.new("_User", :name => "Bob", :cache => 1.day)
    #
    #  @return [Boolean] if set to true or false on whether it should use the default caching
    #   length set when configuring {Parse::Middleware::Caching}.
    #  @return [Integer] if set to a number of seconds to cache this specific request
    #   with the {Parse::Middleware::Caching}.
    # @!attribute [rw] use_master_key
    #  True or false on whether we should send the master key in this request. If
    #  You have provided the master_key when initializing Parse, then all requests
    #  will send the master key by default. This feature is useful when you want to make
    #  a particular query be performed with public credentials, or on behalf of a user using
    #  a {session_token}. Default is set to true.
    #  @see #session_token
    #  @example
    #   # disable use of the master_key in the request.
    #   query = Parse::Query.new("_User", :name => "Bob", :master_key => false)
    #  @return [Boolean] whether we should send the master key in this request.
    # @!attribute [rw] session_token
    #  Set the session token to send with this API request. A session token is tied to
    #  a logged in {Parse::User}. When sending a session_token in the request,
    #  this performs the query on behalf of the user (with their allowed privileges).
    #  Using the short hand (inline) form, you can also pass an authenticated {Parse::User} instance
    #  or a {Parse::Session} instance.
    #  @example
    #   # perform this query as user represented by session_token
    #   query = Parse::Query.new("_User", :name => "Bob")
    #   query.session_token = "r:XyX123..."
    #
    #   # or inline
    #   query = Parse::Query.new("_User", :name => "Bob", :session => "r:XyX123...")
    #
    #   # or with a logged in user object
    #   user = Parse::User.login('user','pass') # => logged in user'
    #   user.session_token # => "r:XyZ1234...."
    #   query = Parse::Query.new("_User", :name => "Bob", :session => user)
    #  @raise ArgumentError if a non-nil value is passed that doesn't provide a session token string.
    #  @note Using a session_token automatically disables sending the master key in the request.
    #  @return [String] the session token to send with this API request.
    # @!attribute [rw] read_preference
    #  Set the MongoDB read preference for this query. This allows directing
    #  read queries to secondary replicas for load balancing.
    #  @example
    #   query = Parse::Query.new("_User")
    #   query.read_preference = :secondary  # read from secondary replicas
    #   # Valid values: :primary, :primary_preferred, :secondary, :secondary_preferred, :nearest
    #  @return [Symbol, String] the read preference for this query.
    attr_reader :table, :session_token
    attr_writer :client
    attr_accessor :key, :cache, :use_master_key, :verbose_aggregate, :read_preference

    # We have a special class method to handle field formatting. This turns
    # the symbol keys in an operand from one key to another. For example, we can
    # have the keys like :cost_rate in a query be translated to "costRate" when we
    # build the query string before sending to Parse. This would allow you to have
    # underscore case for your ruby code, while still maintaining camelCase in Parse.
    # The default field formatter method is :columnize (which is camel case with the first letter
    # in lower case). You can specify a different method to call by setting the Parse::Query.field_formatter
    # variable with the symbol name of the method to call on the object. You can set this to nil
    # if you do not want any field formatting to be performed.

    @field_formatter = :columnize
    @allow_scope_introspection = false
    class << self

      # @!attribute allow_scope_introspection
      # The attribute will prevent automatically fetching results of a scope when
      # using the console. This is useful when you want to see the queries of scopes
      # instead of automatically returning the results.
      # @return [Boolean] true to have scopes return query objects instead of results when
      #  running in the console.

      # @!attribute field_formatter
      # The method to use when converting field names to Parse column names. Default is {String#columnize}.
      # By convention Parse uses lowercase-first camelcase syntax for field/column names, but ruby
      # uses snakecase. To support this methodology we process all field constraints through the method
      # defined by the field formatter. You may set this to nil to turn off this functionality.
      # @return [Symbol] The filter method to process column and field names. Default {String#columnize}.

      attr_accessor :field_formatter, :allow_scope_introspection

      # @param str [String] the string to format
      # @return [String] formatted string using {Parse::Query.field_formatter}.
      def format_field(str)
        res = str.to_s.strip
        if field_formatter.present? && res.respond_to?(field_formatter)
          res = res.send(field_formatter)
        end
        res
      end

      # Convert camelCase string to snake_case
      # @param str [String] the camelCase string
      # @return [String] the snake_case string
      def to_snake_case(str)
        str.to_s.underscore
      end

      # Parses keys patterns to build a map of nested fetched keys.
      # Handles arbitrary nesting depth (e.g., "a.b.c.d" creates entries for a, b, c).
      # For example, ["project.name", "project.status", "author.email"] becomes:
      # { project: [:name, :status], author: [:email] }
      # @param keys [Array<Symbol, String>] the keys patterns (may include dot notation for nested fields)
      # @return [Hash] a map of nested field names to their fetched keys
      def parse_keys_to_nested_keys(keys)
        return {} if keys.nil? || keys.empty?

        nested_map = {}

        keys.each do |key_path|
          parts = key_path.to_s.split(".")
          # Skip keys without dots - they're top-level fields, not nested
          next if parts.length < 2

          # Process each level of nesting
          # For path "a.b.c.d": a gets b, b gets c, c gets d
          parts.each_with_index do |part, index|
            field_name = part.to_sym
            nested_map[field_name] ||= []

            # If there's a next part, add it to this field's nested keys
            if index < parts.length - 1
              next_field = parts[index + 1].to_sym
              nested_map[field_name] << next_field unless nested_map[field_name].include?(next_field)
            end
          end
        end

        nested_map
      end

      # Helper method to create a query with constraints for a specific Parse collection.
      # Also sets the default limit count to `:max`.
      # @param table [String] the name of the Parse collection to query. (ex. "_User")
      # @param constraints [Hash] a set of query constraints.
      # @return [Query] a new query for the Parse collection with the passed in constraints.
      def all(table, constraints = { limit: :max })
        self.new(table, constraints.reverse_merge({ limit: :max }))
      end

      # This methods takes a set of constraints and merges them to build a final
      # `where` constraint clause for sending to the Parse backend.
      # @param where [Array] an array of {Parse::Constraint} objects.
      # @return [Hash] a hash representing the compiled query
      def compile_where(where)
        constraint_reduce(where)
      end

      # @!visibility private
      def constraint_reduce(clauses)
        # @todo Need to add proper constraint merging
        clauses.reduce({}) do |clause, subclause|
          #puts "Merging Subclause: #{subclause.as_json}"

          subclause_json = subclause.as_json || {}

          # Special handling for aggregation pipeline constraints
          # Instead of overwriting, concatenate the pipeline arrays
          if clause.key?("__aggregation_pipeline") && subclause_json.key?("__aggregation_pipeline")
            clause["__aggregation_pipeline"].concat(subclause_json["__aggregation_pipeline"])
            # Don't merge the __aggregation_pipeline key using deep_merge
            subclause_without_pipeline = subclause_json.reject { |k, v| k == "__aggregation_pipeline" }
            clause.deep_merge!(subclause_without_pipeline)
          else
            clause.deep_merge!(subclause_json)
          end

          clause
        end
      end

      # Applies special singleton methods to a query instance in order to
      # automatically fetch results when using any ruby console.
      # @!visibility private
      def apply_auto_introspection!(query)
        unless @allow_scope_introspection
          query.define_singleton_method(:to_s) { self.results.to_s }
          query.define_singleton_method(:inspect) { self.results.to_a.inspect }
        end
      end
    end

    # @!attribute [r] client
    # @return [Parse::Client] the client to use for making the API request.
    # @see Parse::Client::Connectable
    def client
      # use the set client or the default client.
      @client ||= self.class.client
    end

    # Clear a specific clause of this query. This can be one of: :where, :order,
    # :includes, :skip, :limit, :count, :keys or :results.
    # @param item [:Symbol] the clause to clear.
    # @return [self]
    def clear(item = :results)
      case item
      when :where
        # an array of Parse::Constraint subclasses
        @where = []
      when :order
        # an array of Parse::Order objects
        @order = []
      when :includes
        @includes = []
      when :skip
        @skip = 0
      when :limit
        @limit = nil
      when :count
        @count = 0
      when :keys
        @keys = []
      end
      @results = nil
      self # chaining
    end

    # Constructor method to create a query with constraints for a specific Parse collection.
    # Also sets the default limit count to `:max`.
    # @overload new(table)
    #   Create a query for this Parse collection name.
    #   @example
    #     Parse::Query.new "_User"
    #     Parse::Query.new "_Installation", :device_type => 'ios'
    #   @param table [String] the name of the Parse collection to query. (ex. "_User")
    #   @param constraints [Hash] a set of query constraints.
    # @overload new(parseSubclass)
    #   Create a query for this Parse model (or anything that responds to {Parse::Object.parse_class}).
    #   @example
    #     Parse::Query.new Parse::User
    #     # assume Post < Parse::Object
    #     Parse::Query.new Post, like_count.gt => 0
    #   @param parseSubclass [Parse::Object] the Parse model constant
    #   @param constraints [Hash] a set of query constraints.
    # @return [Query] a new query for the Parse collection with the passed in constraints.
    def initialize(table, constraints = {})
      table = table.to_s.to_parse_class if table.is_a?(Symbol)
      table = table.parse_class if table.respond_to?(:parse_class)
      raise ArgumentError, "First parameter should be the name of the Parse class (table)" unless table.is_a?(String)
      @count = 0 #non-zero/1 implies a count query request
      @where = []
      @order = []
      @keys = []
      @includes = []
      @limit = nil
      @skip = 0
      @table = table
      @cache = Parse.default_query_cache
      @use_master_key = true
      @verbose_aggregate = false
      conditions constraints
    end # initialize

    # Add a set of query expressions and constraints.
    # @example
    #  query.conditions({:field.gt => value})
    # @param expressions [Hash] containing key value pairs of Parse::Operations
    #   and their value.
    # @return [self]
    def conditions(expressions = {})
      expressions.each do |expression, value|
        # Normalize to symbol for comparison (handles both string and symbol keys)
        expr_sym = expression.respond_to?(:to_sym) ? expression.to_sym : expression

        if expr_sym == :order
          order value
        elsif expr_sym == :keys
          keys value
        elsif expr_sym == :key
          keys [value]
        elsif expr_sym == :skip
          skip value
        elsif expr_sym == :limit
          limit value
        elsif expr_sym == :include || expr_sym == :includes
          includes(value)
        elsif expr_sym == :cache
          self.cache = value
        elsif expr_sym == :use_master_key
          self.use_master_key = value
        elsif expr_sym == :session
          # you can pass a session token or a Parse::Session
          self.session_token = value
        elsif expr_sym == :read_preference
          self.read_preference = value
          # ACL convenience query options
        elsif expr_sym == :readable_by
          readable_by(value)
        elsif expr_sym == :writable_by
          writable_by(value)
        elsif expr_sym == :readable_by_role
          readable_by_role(value)
        elsif expr_sym == :writable_by_role
          writable_by_role(value)
        elsif expr_sym == :publicly_readable
          publicly_readable if value
        elsif expr_sym == :publicly_writable
          publicly_writable if value
        elsif expr_sym == :privately_readable || expr_sym == :master_key_read_only
          privately_readable if value
        elsif expr_sym == :privately_writable || expr_sym == :master_key_write_only
          privately_writable if value
        elsif expr_sym == :private_acl || expr_sym == :master_key_only
          private_acl if value
        elsif expr_sym == :not_publicly_readable
          not_publicly_readable if value
        elsif expr_sym == :not_publicly_writable
          not_publicly_writable if value
        else
          add_constraint(expression, value)
        end
      end # each
      self #chaining
    end

    alias_method :query, :conditions
    alias_method :append, :conditions

    def table=(t)
      @table = t.to_s.camelize
    end

    def session_token=(value)
      if value.respond_to?(:session_token) && value.session_token.is_a?(String)
        value = value.session_token
      end

      if value.nil? || (value.is_a?(String) && value.present?)
        @session_token = value
      else
        raise ArgumentError, "Invalid session token passed to query."
      end
    end

    # returns the query clause for the particular clause
    # @param clause_name [Symbol] One of supported clauses to return: :keys,
    #  :where, :order, :includes, :limit, :skip
    # @return [Object] the content of the clause for this query.
    def clause(clause_name = :where)
      return unless [:keys, :where, :order, :includes, :limit, :skip].include?(clause_name)
      instance_variable_get "@#{clause_name}".to_sym
    end

    # Restrict the fields returned by the query. This is useful for larger query
    # results set where some of the data will not be used, which reduces network
    # traffic and deserialization performance.
    # @example
    #  # results only contain :name field
    #  Song.all :keys => :name
    #
    #  # multiple keys
    #  Song.all :keys => [:name,:artist]
    # @note Use this feature with caution when working with the results, as
    #    values for the fields not specified in the query will be omitted in
    #    the resulting object.
    # @param fields [Array] the name of the fields to return.
    # @return [self]
    def keys(*fields)
      @keys ||= []
      fields.flatten.each do |field|
        if field.nil? == false && field.respond_to?(:to_s)
          @keys.push Query.format_field(field).to_sym
        end
      end
      @keys.uniq!
      @results = nil if fields.count > 0
      self # chaining
    end

    alias_method :select_fields, :keys

    # Extract values for a specific field from all matching objects.
    # This is similar to keys() but returns an array of the actual field values
    # instead of objects with only those fields selected.
    # @param field [Symbol, String] the field name to extract values for.
    # @return [Array] an array of field values from all matching objects.
    # @example
    #   # Get all asset names
    #   Asset.query.pluck(:name)
    #   # => ["video1.mp4", "image1.jpg", "audio1.mp3"]
    #
    #   # Get all author team IDs
    #   Asset.query.pluck(:author_team)
    #   # => [{"__type"=>"Pointer", "className"=>"Team", "objectId"=>"abc123"}, ...]
    #
    #   # Get created dates
    #   Asset.query.pluck(:created_at)
    #   # => [2024-11-24 10:30:00 UTC, 2024-11-25 14:20:00 UTC, ...]
    def pluck(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `pluck`."
      end

      # Use keys to select only the field we want for efficiency
      query_with_field = self.dup.keys(field)

      # Get the results and extract the field values
      objects = query_with_field.results
      formatted_field = Query.format_field(field)

      objects.map do |obj|
        if obj.respond_to?(:attributes)
          # For Parse objects, get the attribute value
          obj.attributes[field.to_s] || obj.attributes[formatted_field.to_s]
        elsif obj.is_a?(Hash)
          # For raw JSON objects
          obj[field.to_s] || obj[formatted_field.to_s]
        else
          # Fallback - try to access as method
          obj.respond_to?(field) ? obj.send(field) : nil
        end
      end
    end

    # Add a sorting order for the query.
    # @example
    #  # order updated_at ascending order
    #  Song.all :order => :updated_at
    #
    #  # first order by highest like_count, then by ascending name.
    #  # Note that ascending is the default if not specified (ex. `:name.asc`)
    #  Song.all :order => [:like_count.desc, :name]
    # @param ordering [Parse::Order] an ordering
    # @return [self]
    def order(*ordering)
      @order ||= []
      ordering.flatten.each do |order|
        order = Order.new(order) if order.respond_to?(:to_sym)
        if order.is_a?(Order)
          order.field = Query.format_field(order.field)
          @order.push order
        end
      end #value.each
      @results = nil if ordering.count > 0
      self #chaining
    end #order

    # Use with limit to paginate through results. Default is 0.
    # @example
    #  # get the next 3 songs after the first 10
    #  Song.all :limit => 3, :skip => 10
    # @param amount [Integer] The number of records to skip.
    # @return [self]
    def skip(amount)
      @skip = [0, amount.to_i].max
      @results = nil
      self #chaining
    end

    # Limit the number of objects returned by the query. The default is 100, with
    # Parse allowing a maximum of 1000. The framework also allows a value of
    # `:max`. Utilizing this will have the framework continually intelligently
    # utilize `:skip` to continue to paginate through results until no more results
    # match the query criteria. When utilizing `all()`, `:max` is the default
    # option for `:limit`.
    # @example
    #  Song.all :limit => 1 # same as Song.first
    #  Song.all :limit => 2025 # large limits supported.
    #  Song.all :limit => :max # as many records as possible.
    # @param count [Integer,Symbol] The number of records to return. You may pass :max
    #  to get as many records as possible (Parse-Server dependent).
    # @return [self]
    def limit(count)
      if count.is_a?(Numeric)
        @limit = [0, count.to_i].max
      elsif count == :max
        @limit = :max
      else
        @limit = nil
      end

      @results = nil
      self #chaining
    end

    # Set the MongoDB read preference for this query.
    # This allows directing read queries to secondary replicas for load balancing.
    # @example
    #  Song.query.read_preference(:secondary).results
    #  Song.query.read_preference(:nearest).results
    # @param preference [Symbol, String] the read preference.
    #   Valid values: :primary, :primary_preferred, :secondary, :secondary_preferred, :nearest
    # @return [self]
    def read_pref(preference)
      @read_preference = preference
      self
    end

    def related_to(field, pointer)
      raise ArgumentError, "Object value must be a Parse::Pointer type" unless pointer.is_a?(Parse::Pointer)
      add_constraint field.to_sym.related_to, pointer
      self #chaining
    end

    # Set a list of Parse Pointer columns to be fetched for matching records.
    # You may chain multiple columns with the `.` operator.
    # @example
    #  # assuming an 'Artist' has a pointer column for a 'Manager'
    #  # and a Song has a pointer column for an 'Artist'.
    #
    #  # include the full artist object
    #  Song.all(:includes => [:artist])
    #
    #  # Chaining - fetches the artist and the artist's manager for matching songs
    #  Song.all :includes => ['artist.manager']
    # @param fields [Array] the list of Pointer columns to fetch.
    # @return [self]
    def includes(*fields)
      @includes ||= []
      fields.flatten.each do |field|
        if field.nil? == false && field.respond_to?(:to_s)
          @includes.push Query.format_field(field).to_sym
        end
      end
      @includes.uniq!
      @results = nil if fields.count > 0
      self # chaining
    end

    # alias for includes
    def include(*fields)
      includes(*fields)
    end

    # Combine a list of {Parse::Constraint} objects
    # @param list [Array<Parse::Constraint>] an array of Parse::Constraint subclasses.
    # @return [self]
    def add_constraints(list)
      list = Array.wrap(list).select { |m| m.is_a?(Parse::Constraint) }
      @where = @where + list
      self
    end

    # Add a constraint to the query. This is mainly used internally for compiling constraints.
    # @example
    #  # add where :field equals "value"
    #  query.add_constraint(:field.eq, "value")
    #
    #  # add where :like_count is greater than 20
    #  query.add_constraint(:like_count.gt, 20)
    #
    #  # same, but ignore field formatting
    #  query.add_constraint(:like_count.gt, 20, filter: false)
    #
    # @param operator [Parse::Operator] an operator object containing the operation and operand.
    # @param value [Object] the value for the constraint.
    # @param opts [Object] A set of options. Passing :filter with false, will skip field formatting.
    # @see Query#format_field
    # @return [self]
    def add_constraint(operator, value = nil, opts = {})
      @where ||= []
      constraint = operator # assume Parse::Constraint
      unless constraint.is_a?(Parse::Constraint)
        constraint = Parse::Constraint.create(operator, value)
      end
      return unless constraint.is_a?(Parse::Constraint)
      # to support select queries where you have to pass a `key` parameter for matching
      # different tables.
      if constraint.operand == :key || constraint.operand == "key"
        @key = constraint.value
        return
      end

      unless opts[:filter] == false
        constraint.operand = Query.format_field(constraint.operand)
      end
      @where.push constraint
      @results = nil
      self #chaining
    end

    # @param raw [Boolean] whether to return the hash form of the constraints.
    # @return [Array<Parse::Constraint>] if raw is false, an array of constraints
    #  composing the :where clause for this query.
    # @return [Hash] if raw i strue, an hash representing the constraints.
    def constraints(raw = false)
      raw ? where_constraints : @where
    end

    # Formats the current set of Parse::Constraint instances in the where clause
    # as an expression hash.
    # @return [Hash] the set of constraints
    def where_constraints
      @where.reduce({}) { |memo, constraint| memo[constraint.operation] = constraint.value; memo }
    end

    # Add additional query constraints to the `where` clause. The `where` clause
    # is based on utilizing a set of constraints on the defined column names in
    # your Parse classes. The constraints are implemented as method operators on
    # field names that are tied to a value. Any symbol/string that is not one of
    # the main expression keywords described here will be considered as a type of
    # query constraint for the `where` clause in the query.
    # @example
    #  # parts of a single where constraint
    #  { :column.constraint => value }
    # @see Parse::Constraint
    # @param conditions [Hash] a set of constraints for this query.
    # @param opts [Hash] a set of options when adding the constraints. This is
    #  specific for each Parse::Constraint.
    # @return [self]
    def where(expressions = nil, opts = {})
      return @where if expressions.nil?
      if expressions.is_a?(Hash)
        # Route through conditions to handle special keywords like :keys, :include, etc.
        conditions(expressions)
      end
      self #chaining
    end

    # Combine two where clauses into an OR constraint. Equivalent to the `$or`
    # Parse query operation. This is useful if you want to find objects that
    # match several queries. We overload the `|` operator in order to have a
    # clean syntax for joining these `or` operations.
    # @example
    #  query = Player.where(:wins.gt => 150)
    #  query.or_where(:wins.lt => 5)
    #  # where wins > 150 || wins < 5
    #  results = query.results
    #
    #  # or_query = query1 | query2 | query3 ...
    #  # ex. where wins > 150 || wins < 5
    #  query = Player.where(:wins.gt => 150) | Player.where(:wins.lt => 5)
    #  results = query.results
    # @param where_clauses [Array<Parse::Constraint>] a list of Parse::Constraint objects to combine.
    # @return [Query] the combined query with an OR clause.
    def or_where(where_clauses = [])
      where_clauses = where_clauses.where if where_clauses.is_a?(Parse::Query)
      where_clauses = Parse::Query.new(@table, where_clauses).where if where_clauses.is_a?(Hash)
      return self if where_clauses.blank?
      # we can only have one compound query constraint. If we need to add another OR clause
      # let's find the one we have (if any)
      compound = @where.find { |f| f.is_a?(Parse::Constraint::CompoundQueryConstraint) }
      # create a set of clauses that are not an OR clause.
      remaining_clauses = @where.select { |f| f.is_a?(Parse::Constraint::CompoundQueryConstraint) == false }
      # if we don't have a OR clause to reuse, then create a new one with then
      # current set of constraints
      if compound.blank?
        initial_constraints = Parse::Query.compile_where(remaining_clauses)
        # Only include initial constraints if they're not empty
        initial_values = initial_constraints.empty? ? [] : [initial_constraints]
        compound = Parse::Constraint::CompoundQueryConstraint.new :or, initial_values
      end
      # then take the where clauses from the second query and append them.
      new_constraints = Parse::Query.compile_where(where_clauses)
      # Only add new constraints if they're not empty
      unless new_constraints.empty?
        compound.value.push new_constraints
      end
      #compound = Parse::Constraint::CompoundQueryConstraint.new :or, [remaining_clauses, or_where_query.where]
      @where = [compound]
      self #chaining
    end

    # @see #or_where
    # @return [Query] the combined query with an OR clause.
    def |(other_query)
      raise ArgumentError, "Parse queries must be of the same class #{@table}." unless @table == other_query.table
      copy_query = self.clone
      copy_query.or_where other_query.where
      copy_query
    end

    # Queries can be made using distinct, allowing you find unique values for a specified field.
    # For this to be performant, please remember to index your database.
    # @example
    #   # Return a set of unique city names
    #   # for users who are greater than 21 years old
    #   Parse::Query.all(distinct: :age)
    #   query = Parse::Query.new("_User")
    #   query.where :age.gt => 21
    #   # triggers query
    #   query.distinct(:city) #=> ["San Diego", "Los Angeles", "San Juan"]
    # @note This feature requires use of the Master Key in the API.
    # @param field [Symbol|String] The name of the field used for filtering.
    # @param mongo_direct [Boolean] if true, queries MongoDB directly bypassing Parse Server.
    #   Requires Parse::MongoDB to be configured. Default: false.
    # @version 1.8.0
    def distinct(field, return_pointers: false, mongo_direct: false)
      # Use direct MongoDB query if requested
      return distinct_direct(field, return_pointers: return_pointers) if mongo_direct

      if field.nil? || !field.respond_to?(:to_s) || field.is_a?(Hash) || field.is_a?(Array)
        raise ArgumentError, "Invalid field name passed to `distinct`."
      end

      # Format field for aggregation
      formatted_field = format_aggregation_field(field)

      # Build the aggregation pipeline for distinct values
      pipeline = [
        { "$group" => { "_id" => "$#{formatted_field}" } },
        { "$project" => { "_id" => 0, "value" => "$_id" } },
      ]

      # Add match stage if there are where conditions
      compiled_where = compile_where
      if compiled_where.present?
        # Convert field names for aggregation context and handle dates
        aggregation_where = convert_constraints_for_aggregation(compiled_where)
        stringified_where = convert_dates_for_aggregation(aggregation_where)
        pipeline.unshift({ "$match" => stringified_where })
      end

      # Use the Aggregation class to execute
      aggregation = aggregate(pipeline, verbose: @verbose_aggregate)
      raw_results = aggregation.raw

      # Extract values from the results
      values = raw_results.map { |item| item["value"] }.compact

      # Use schema-based approach to handle pointer field results
      parse_class = Parse::Model.const_get(@table) rescue nil
      is_pointer = parse_class && is_pointer_field?(parse_class, field, formatted_field)

      if is_pointer && values.any?
        # Convert all values using schema information
        converted_values = values.map do |value|
          convert_pointer_value_with_schema(value, field, return_pointers: return_pointers)
        end
        converted_values
      elsif return_pointers
        # Explicit conversion requested - try to convert using schema or fallback to string detection
        if values.any? && values.first.is_a?(String) && values.first.include?("$")
          to_pointers(values, field)
        else
          values.map { |value| convert_pointer_value_with_schema(value, field, return_pointers: true) }
        end
      else
        # Fallback to original string detection for backward compatibility
        if values.any? && values.first.is_a?(String) && values.first.include?("$") && values.first.match(/^[A-Za-z]\w*\$\w+$/)
          first_class_name = values.first.split("$", 2)[0]
          if values.all? { |v| v.is_a?(String) && v.start_with?("#{first_class_name}$") }
            values.map { |value| value.split("$", 2)[1] }
          else
            values
          end
        else
          values
        end
      end
    end

    # Convenience method for distinct queries that always return Parse::Pointer objects for pointer fields.
    # This is equivalent to calling distinct(field, return_pointers: true).
    # @param field [Symbol, String] the field name to get distinct values for
    # @return [Array] array of distinct values, with pointer fields converted to Parse::Pointer objects
    def distinct_pointers(field)
      distinct(field, return_pointers: true)
    end

    # Perform a count query.
    # @example
    #  # get number of songs with a play_count > 10
    #  Song.count :play_count.gt => 10
    #
    #  # same
    #  query = Parse::Query.new("Song")
    #  query.where :play_count.gt => 10
    #  query.count
    # @return [Integer] the count result
    # @param mongo_direct [Boolean] if true, queries MongoDB directly bypassing Parse Server.
    #   Requires Parse::MongoDB to be configured. Default: false.
    def count(mongo_direct: false)
      # Use direct MongoDB query if requested
      return count_direct if mongo_direct

      # Check if this query requires aggregation pipeline processing
      if requires_aggregation_pipeline?
        # Build aggregation pipeline with $count stage
        pipeline, has_lookup_stages = build_aggregation_pipeline
        pipeline << { "$count" => "count" }

        # Auto-detect if MongoDB direct is needed
        use_mongo_direct = false
        if has_lookup_stages && defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
          use_mongo_direct = true
        end

        # Execute aggregation
        aggregation = Aggregation.new(self, pipeline, verbose: @verbose_aggregate, mongo_direct: use_mongo_direct)
        response = aggregation.execute!

        # Extract count from aggregation result
        if use_mongo_direct
          # MongoDB direct returns raw array
          return 0 if response.nil? || response.empty?
          response.first["count"] || 0
        else
          return 0 if response.error? || !response.result.is_a?(Array) || response.result.empty?
          response.result.first["count"] || 0
        end
      else
        # Use standard count endpoint for non-aggregation queries
        old_value = @count
        @count = 1
        res = client.find_objects(@table, compile.as_json, **_opts).count
        @count = old_value
        res
      end
    end

    # Perform a count distinct query using MongoDB aggregation pipeline.
    # This counts the number of distinct values for a given field.
    # @param field [Symbol|String] The name of the field to count distinct values for.
    # @example
    #  # get number of distinct genres in songs
    #  Song.count_distinct(:genre)
    #  # same using query instance
    #  query = Parse::Query.new("Song")
    #  query.where(:play_count.gt => 10)
    #  query.count_distinct(:artist)
    # @return [Integer] the count of distinct values
    # @note This feature requires MongoDB aggregation pipeline support in Parse Server.
    def count_distinct(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `count_distinct`."
      end

      # Format field name according to Parse conventions
      # Handle special MongoDB field mappings for aggregation
      formatted_field = case field.to_s
        when "created_at", "createdAt"
          "_created_at"
        when "updated_at", "updatedAt"
          "_updated_at"
        else
          Query.format_field(field)
        end

      # Build the aggregation pipeline
      pipeline = [
        { "$group" => { "_id" => "$#{formatted_field}" } },
        { "$count" => "distinctCount" },
      ]

      # Use the Aggregation class to execute
      # The aggregate method will automatically handle where conditions
      aggregation = aggregate(pipeline, verbose: @verbose_aggregate)
      raw_results = aggregation.raw

      # Extract the count from the response
      if raw_results.is_a?(Array) && raw_results.first
        raw_results.first["distinctCount"] || 0
      else
        0
      end
    end

    # @yield a block yield for each object in the result
    # @return [Array]
    # @see Array#each
    def each(&block)
      return results.enum_for(:each) unless block_given? # Sparkling magic!
      results.each(&block)
    end

    # @yield a block yield for each object in the result
    # @return [Array]
    # @see Array#map
    def map(&block)
      return results.enum_for(:map) unless block_given? # Sparkling magic!
      results.map(&block)
    end

    # @yield a block yield for each object in the result
    # @return [Array]
    # @see Array#select
    def select(&block)
      return results.enum_for(:select) unless block_given? # Sparkling magic!
      results.select(&block)
    end

    # @return [Array]
    # @see Array#to_a
    def to_a
      results.to_a
    end

    # @overload first(limit = 1)
    #   @param limit [Integer] the number of first items to return.
    #   @return [Parse::Object] the first object from the result.
    # @overload first(constraints = {})
    #   @param constraints [Hash] query constraints to apply before fetching.
    #   @return [Parse::Object] the first object from the result.
    # @param mongo_direct [Boolean] if true, queries MongoDB directly bypassing Parse Server.
    #   Requires Parse::MongoDB to be configured. Default: false.
    # @note Supports all constraint options like :keys, :includes, :order, etc.
    def first(limit_or_constraints = 1, mongo_direct: false, **options)
      # Use direct MongoDB query if requested
      if mongo_direct
        return first_direct(limit_or_constraints)
      end

      fetch_count = 1
      if limit_or_constraints.is_a?(Hash)
        conditions(limit_or_constraints)
        # Check if limit was set in constraints, otherwise use 1
        # Handle :max case - if @limit is :max, default to 1 for first()
        fetch_count = (@limit.is_a?(Numeric) ? @limit : nil) || 1
        # Set @limit to ensure query only fetches the needed records
        @results = nil if @limit != fetch_count
        @limit = fetch_count
      else
        fetch_count = limit_or_constraints.to_i
        @results = nil if @limit != fetch_count
        @limit = fetch_count
      end
      # Apply any additional keyword options as conditions (e.g., keys:, includes:)
      conditions(options) unless options.empty?
      fetch_count == 1 ? results.first : results.first(fetch_count)
    end

    # Returns the most recently created object(s) (ordered by created_at descending).
    # @param limit [Integer] the number of items to return (default: 1).
    # @return [Parse::Object] if limit == 1
    # @return [Array<Parse::Object>] if limit > 1
    # @note Supports all constraint options like :keys, :includes, :limit, etc.
    # @example
    #   query.latest                          # single most recent
    #   query.latest(5)                       # 5 most recent
    #   query.latest(:user.eq => x)           # most recent for user
    #   query.latest(:user.eq => x, limit: 5) # 5 most recent for user
    def latest(limit = 1, **options)
      # Allow limit to be overridden via options
      limit = options.delete(:limit) if options.key?(:limit)
      @results = nil if @limit != limit
      @limit = limit
      # Add created_at descending order if not already present
      order(:created_at.desc) unless @order.any? { |o| o.operand == :created_at }
      # Apply any additional keyword options as conditions (e.g., keys:, includes:)
      conditions(options) unless options.empty?
      limit == 1 ? results.first : results.first(limit)
    end

    # Returns the most recently updated object(s) (ordered by updated_at descending).
    # @param limit [Integer] the number of items to return (default: 1).
    # @return [Parse::Object] if limit == 1
    # @return [Array<Parse::Object>] if limit > 1
    # @note Supports all constraint options like :keys, :includes, :limit, etc.
    # @example
    #   query.last_updated                          # single most recently updated
    #   query.last_updated(5)                       # 5 most recently updated
    #   query.last_updated(:user.eq => x)           # most recently updated for user
    #   query.last_updated(:user.eq => x, limit: 5) # 5 most recently updated for user
    def last_updated(limit = 1, **options)
      # Allow limit to be overridden via options
      limit = options.delete(:limit) if options.key?(:limit)
      @results = nil if @limit != limit
      @limit = limit
      # Add updated_at descending order if not already present
      order(:updated_at.desc) unless @order.any? { |o| o.operand == :updated_at }
      # Apply any additional keyword options as conditions (e.g., keys:, includes:)
      conditions(options) unless options.empty?
      limit == 1 ? results.first : results.first(limit)
    end

    # Retrieve a single object by its objectId.
    # @param object_id [String] the objectId to retrieve.
    # @return [Parse::Object] the object with the given ID.
    # @raise [Parse::Error] if the object is not found.
    def get(object_id)
      parse_class = Object.const_get(@table) if Object.const_defined?(@table)
      parse_class ||= Parse::Object

      response = client.fetch_object(@table, object_id)
      if response.error?
        raise Parse::Error.new(response.error_code, response.message)
      end

      Parse::Object.build(response.result, parse_class)
    end

    # max_results is used to iterate through as many API requests as possible using
    # :skip and :limit paramter.
    # @!visibility private
    def max_results(raw: false, return_pointers: false, on_batch: nil, discard_results: false, &block)
      compiled_query = compile
      batch_size = 100
      results = []
      # determine if there is a user provided hard limit
      _limit = (@limit.is_a?(Numeric) && @limit > 0) ? @limit : nil
      compiled_query[:skip] ||= 0

      loop do
        # always reset the batch size
        compiled_query[:limit] = batch_size

        # if a hard limit was set by the user, then if the remaining amount
        # is less than the batch size, set the new limit to the remaining amount.
        unless _limit.nil?
          compiled_query[:limit] = _limit if _limit < batch_size
        end

        response = fetch!(compiled_query)
        break if response.error? || response.results.empty?

        items = response.results
        items = if raw
            items
          elsif return_pointers
            to_pointers(items)
          else
            decode(items)
          end
        # if a block is provided, we do not keep the results after processing.
        if block_given?
          items.each(&block)
        else
          # concat results unless discard_results is true
          results += items unless discard_results
        end

        on_batch.call(items) if on_batch.present?
        # if we get less than the maximum set of results, most likely the next
        # query will return emtpy results - no need to perform it.
        break if items.count < compiled_query[:limit]

        # if we have a set limit, then subtract from the total amount the user requested
        # from the total in the current result set. Break if we've reached our limit.
        unless _limit.nil?
          _limit -= items.count
          break if _limit < 1
        end

        # add to the skip count for the next iteration
        compiled_query[:skip] += batch_size
      end
      results
    end

    # @!visibility private
    def _opts
      opts = {}
      opts[:cache] = self.cache || false
      opts[:use_master_key] = self.use_master_key
      opts[:session_token] = self.session_token
      # for now, don't cache requests where we disable master_key or provide session token
      # if opts[:use_master_key] == false || opts[:session_token].present?
      #   opts[:cache] = false
      # end
      opts
    end

    # @!visibility private
    # Build headers for the query request
    def _headers
      headers = {}
      if read_preference.present?
        pref = read_preference.to_s.upcase.gsub("_", " ").split.join("_")
        # Normalize common formats
        pref = case pref
          when "PRIMARY" then "PRIMARY"
          when "PRIMARY_PREFERRED", "PRIMARYPREFERRED" then "PRIMARY_PREFERRED"
          when "SECONDARY" then "SECONDARY"
          when "SECONDARY_PREFERRED", "SECONDARYPREFERRED" then "SECONDARY_PREFERRED"
          when "NEAREST" then "NEAREST"
          else pref
          end
        if Parse::Protocol::READ_PREFERENCES.include?(pref)
          headers[Parse::Protocol::READ_PREFERENCE] = pref
        else
          warn "[ParseQuery] Invalid read preference: #{read_preference}. Valid values: #{Parse::Protocol::READ_PREFERENCES.join(", ")}"
        end
      end
      headers
    end

    # Performs the fetch request for the query.
    # @param compiled_query [Hash] the compiled query
    # @return [Parse::Response] a response for a query request.
    def fetch!(compiled_query)
      response = client.find_objects(@table, compiled_query.as_json, headers: _headers, **_opts)
      if response.error?
        puts "[ParseQuery] #{response.error}"
      end
      response
    end

    alias_method :execute!, :fetch!

    # Executes the query and builds the result set of Parse::Objects that matched.
    # When this method is passed a block, the block is yielded for each matching item
    # in the result, and the items are not returned. This methodology is more performant
    # as large quantifies of objects are fetched in batches and all of them do
    # not have to be kept in memory after the query finishes executing. This is the recommended
    # method of processing large result sets.
    # @example
    #  query = Parse::Query.new("_User", :created_at.before => DateTime.now)
    #  users = query.results # => Array of Parse::User objects.
    #
    #  query = Parse::Query.new("_User", limit: :max)
    #
    #  query.results do |user|
    #   # recommended; more memory efficient
    #  end
    #
    # @param raw [Boolean] whether to get the raw hash results of the query instead of
    #   a set of Parse::Object subclasses.
    # @yield a block to iterate for each object that matched the query.
    # @return [Array<Hash>] if raw is set to true, a set of Parse JSON hashes.
    # @return [Array<Parse::Object>] if raw is set to false, a list of matching Parse::Object subclasses.
    # @param mongo_direct [Boolean] if true, queries MongoDB directly bypassing Parse Server.
    #   Requires Parse::MongoDB to be configured. Default: false.
    def results(raw: false, return_pointers: false, mongo_direct: false, &block)
      # Use direct MongoDB query if requested
      if mongo_direct
        return results_direct(raw: raw, &block)
      end

      if @results.nil?
        if block_given?
          max_results(raw: raw, return_pointers: return_pointers, &block)
        elsif @limit.is_a?(Numeric) || requires_aggregation_pipeline?
          # Check if this query requires aggregation pipeline processing
          if requires_aggregation_pipeline?
            # Use Aggregation class which handles both Parse Server and MongoDB direct
            aggregation = execute_aggregation_pipeline
            if raw
              items = aggregation.raw
            elsif return_pointers
              items = to_pointers(aggregation.raw)
            else
              items = aggregation.results
            end
            return items.each(&block) if block_given?
            @results = items
          else
            response = fetch!(compile)
            return [] if response.error?
            items = if raw
                response.results
              elsif return_pointers
                to_pointers(response.results)
              else
                decode(response.results)
              end
            return items.each(&block) if block_given?
            @results = items
          end
        else
          @results = max_results(raw: raw, return_pointers: return_pointers)
        end
      end
      @results
    end

    # Check if this query contains constraints that require aggregation pipeline processing
    # @return [Boolean] true if aggregation pipeline is required
    def requires_aggregation_pipeline?
      return false if @where.empty?

      compiled_where = compile_where

      # Check if the compiled where itself has aggregation pipeline marker
      return true if compiled_where.key?("__aggregation_pipeline")

      # Check if any of the constraint values has aggregation pipeline marker
      compiled_where.values.any? { |constraint|
        constraint.is_a?(Hash) && constraint.key?("__aggregation_pipeline")
      }
    end

    # Returns raw unprocessed results from the query (hash format)
    # @yield a block to iterate for each raw object that matched the query
    # @return [Array<Hash>] raw Parse JSON hash results
    def raw(&block)
      results(raw: true, &block)
    end

    # Returns only pointer objects for all matching results
    # This is memory efficient for large result sets where you only need pointers
    # @yield a block to iterate for each pointer object that matched the query
    # @return [Array<Parse::Pointer>] array of Parse::Pointer objects
    def result_pointers(&block)
      results(return_pointers: true, &block)
    end

    # Alias for result_pointers for consistency
    alias_method :results_pointers, :result_pointers

    # Execute the query directly against MongoDB, bypassing Parse Server.
    # This is useful for performance-critical read operations.
    #
    # @example Basic usage
    #   songs = Song.query(:plays.gt => 1000).results_direct
    #
    # @example With raw results
    #   raw_docs = Song.query(:artist => "Beatles").results_direct(raw: true)
    #
    # @param raw [Boolean] if true, returns raw MongoDB documents converted to Parse format
    #   instead of Parse::Object instances (default: false)
    # @yield a block to iterate for each object that matched the query
    # @return [Array<Parse::Object>] if raw is false, a list of Parse::Object subclasses
    # @return [Array<Hash>] if raw is true, Parse-formatted JSON hashes
    # @raise [Parse::MongoDB::GemNotAvailable] if mongo gem is not installed
    # @raise [Parse::MongoDB::NotEnabled] if direct MongoDB is not configured
    # @note This is a read-only operation. Direct MongoDB queries cannot modify data.
    # @see Parse::MongoDB.configure
    def results_direct(raw: false, &block)
      require_relative "mongodb"
      Parse::MongoDB.require_gem!

      unless Parse::MongoDB.available?
        raise Parse::MongoDB::NotEnabled,
          "Direct MongoDB queries are not enabled. " \
          "Call Parse::MongoDB.configure(uri: 'mongodb://...', enabled: true) first."
      end

      # Build the aggregation pipeline for direct MongoDB execution
      pipeline = build_direct_mongodb_pipeline

      # Execute the aggregation directly on MongoDB
      raw_results = Parse::MongoDB.aggregate(@table, pipeline)

      # Convert MongoDB documents to Parse format
      parse_results = Parse::MongoDB.convert_documents_to_parse(raw_results, @table)

      if raw
        return parse_results.each(&block) if block_given?
        return parse_results
      end

      # Convert to Parse objects
      items = decode(parse_results)
      return items.each(&block) if block_given?
      items
    end

    # Execute the query directly against MongoDB and return the first result.
    # This is useful for performance-critical single-object lookups.
    #
    # @example Basic usage
    #   song = Song.query(:objectId => "abc123").first_direct
    #
    # @example With limit
    #   top_songs = Song.query(:plays.gt => 1000).order(:plays.desc).first_direct(5)
    #
    # @param limit_or_constraints [Integer, Hash] either the number of results to return,
    #   or a hash of additional constraints to apply
    # @return [Parse::Object, nil] the first matching object, or nil if none found
    # @return [Array<Parse::Object>] if limit > 1, an array of matching objects
    # @raise [Parse::MongoDB::GemNotAvailable] if mongo gem is not installed
    # @raise [Parse::MongoDB::NotEnabled] if direct MongoDB is not configured
    # @note This is a read-only operation. Direct MongoDB queries cannot modify data.
    # @see Parse::MongoDB.configure
    def first_direct(limit_or_constraints = 1)
      if limit_or_constraints.is_a?(Hash)
        conditions(limit_or_constraints)
        limit_or_constraints = 1
      end

      count = limit_or_constraints.to_i
      count = 1 if count <= 0

      # Set limit for single/few results
      original_limit = @limit
      @limit = count

      begin
        items = results_direct
      ensure
        @limit = original_limit
      end

      count == 1 ? items.first : items.first(count)
    end

    # Execute a count query directly against MongoDB, bypassing Parse Server.
    # This is useful for performance-critical count operations.
    #
    # @example Basic usage
    #   count = Song.query(:plays.gt => 1000).count_direct
    #
    # @example With additional constraints
    #   active_users = User.query(:status => "active").count_direct
    #
    # @return [Integer] the count of matching documents
    # @raise [Parse::MongoDB::GemNotAvailable] if mongo gem is not installed
    # @raise [Parse::MongoDB::NotEnabled] if direct MongoDB is not configured
    # @note This is a read-only operation. Direct MongoDB queries cannot modify data.
    # @see Parse::MongoDB.configure
    def count_direct
      require_relative "mongodb"
      Parse::MongoDB.require_gem!

      unless Parse::MongoDB.available?
        raise Parse::MongoDB::NotEnabled,
          "Direct MongoDB queries are not enabled. " \
          "Call Parse::MongoDB.configure(uri: 'mongodb://...', enabled: true) first."
      end

      # Build the aggregation pipeline for direct MongoDB execution
      pipeline = build_direct_mongodb_pipeline

      # Remove limit and skip for count (we want total count)
      pipeline = pipeline.reject { |stage| stage.key?("$limit") || stage.key?("$skip") }

      # Add count stage
      pipeline << { "$count" => "count" }

      # Execute the aggregation directly on MongoDB
      raw_results = Parse::MongoDB.aggregate(@table, pipeline)

      # Extract count from result
      return 0 if raw_results.empty?
      raw_results.first["count"] || 0
    end

    # Execute a distinct query directly against MongoDB, bypassing Parse Server.
    # Returns unique values for the specified field.
    #
    # @example Basic usage
    #   cities = User.query(:age.gt => 21).distinct_direct(:city)
    #   # => ["San Diego", "Los Angeles", "New York"]
    #
    # @example With pointer fields
    #   artists = Song.query(:plays.gt => 1000).distinct_direct(:artist, return_pointers: true)
    #   # => [#<Parse::Pointer:Artist@abc123>, #<Parse::Pointer:Artist@def456>]
    #
    # @param field [Symbol, String] the field name to get distinct values for
    # @param return_pointers [Boolean] if true, converts pointer values to Parse::Pointer objects
    # @return [Array] array of distinct values
    # @raise [Parse::MongoDB::GemNotAvailable] if mongo gem is not installed
    # @raise [Parse::MongoDB::NotEnabled] if direct MongoDB is not configured
    # @note This is a read-only operation. Direct MongoDB queries cannot modify data.
    # @see Parse::MongoDB.configure
    def distinct_direct(field, return_pointers: false)
      require_relative "mongodb"
      Parse::MongoDB.require_gem!

      unless Parse::MongoDB.available?
        raise Parse::MongoDB::NotEnabled,
          "Direct MongoDB queries are not enabled. " \
          "Call Parse::MongoDB.configure(uri: 'mongodb://...', enabled: true) first."
      end

      if field.nil? || !field.respond_to?(:to_s) || field.is_a?(Hash) || field.is_a?(Array)
        raise ArgumentError, "Invalid field name passed to `distinct_direct`."
      end

      # Convert field name for direct MongoDB access
      mongo_field = convert_field_for_direct_mongodb(Query.format_field(field))

      # Build the base pipeline with match constraints
      pipeline = []

      # Add match stage from query constraints
      compiled_where = compile_where
      if compiled_where.present?
        regular_constraints = compiled_where.reject { |f, _| f == "__aggregation_pipeline" }
        if regular_constraints.any?
          mongo_constraints = convert_constraints_for_direct_mongodb(regular_constraints)
          pipeline << { "$match" => mongo_constraints }
        end
      end

      # Add group and project stages for distinct
      pipeline << { "$group" => { "_id" => "$#{mongo_field}" } }
      pipeline << { "$project" => { "_id" => 0, "value" => "$_id" } }

      # Execute the aggregation directly on MongoDB
      raw_results = Parse::MongoDB.aggregate(@table, pipeline)

      # Extract values from results
      values = raw_results.map { |doc| doc["value"] }.compact

      # Handle pointer conversion if needed
      if return_pointers || field_is_pointer?(Query.format_field(field))
        values = values.map do |value|
          if value.is_a?(String) && value.include?("$")
            # MongoDB pointer format: "ClassName$objectId"
            class_name, object_id = value.split("$", 2)
            Parse::Pointer.new(class_name, object_id)
          else
            value
          end
        end
      end

      values
    end

    # Convenience method for distinct_direct that always returns Parse::Pointer objects for pointer fields.
    # @param field [Symbol, String] the field name to get distinct values for
    # @return [Array] array of distinct values, with pointer fields as Parse::Pointer objects
    # @see #distinct_direct
    def distinct_direct_pointers(field)
      distinct_direct(field, return_pointers: true)
    end

    #----------------------------------------------------------------
    # ATLAS SEARCH METHODS
    #----------------------------------------------------------------

    # Execute a full-text search using MongoDB Atlas Search.
    # Combines existing query constraints with Atlas Search capabilities.
    #
    # Supports both simple options hash API and builder block for complex queries.
    #
    # @example Simple text search
    #   songs = Song.query(:plays.gt => 1000).atlas_search("love ballad", fields: [:title, :lyrics])
    #
    # @example With fuzzy matching
    #   songs = Song.query.atlas_search("lvoe", fuzzy: true, limit: 20)
    #
    # @example Complex search with builder block
    #   songs = Song.query.atlas_search do |search|
    #     search.text(query: "love", path: [:title, :lyrics])
    #     search.phrase(query: "broken heart", path: :lyrics, slop: 2)
    #     search.with_highlight(path: :lyrics)
    #   end
    #
    # @param query [String, nil] the search query text (required unless using block)
    # @param options [Hash] search options
    # @option options [String] :index search index name (default: "default")
    # @option options [Array<String>, String, Symbol] :fields fields to search
    # @option options [Boolean] :fuzzy enable fuzzy matching (default: false)
    # @option options [Integer] :fuzzy_max_edits max edit distance for fuzzy (1 or 2)
    # @option options [Symbol, String] :highlight_field field to return highlights for
    # @option options [Integer] :limit max results to return (overrides query limit)
    # @option options [Integer] :skip number of results to skip (overrides query skip)
    # @option options [Boolean] :raw return raw MongoDB documents (default: false)
    # @yield [SearchBuilder] optional block to configure complex search
    #
    # @return [Parse::AtlasSearch::SearchResult] search result object
    # @raise [Parse::AtlasSearch::NotAvailable] if Atlas Search is not configured
    #
    # @see Parse::AtlasSearch.search
    # @see Parse::AtlasSearch::SearchBuilder
    def atlas_search(query = nil, **options, &block)
      require_relative "atlas_search"

      unless Parse::AtlasSearch.available?
        raise Parse::AtlasSearch::NotAvailable,
          "Atlas Search is not available. " \
          "Call Parse::AtlasSearch.configure(enabled: true) after configuring Parse::MongoDB."
      end

      # Determine limit and skip from query or options
      limit = options[:limit] || (@limit.is_a?(Numeric) && @limit > 0 ? @limit : 100)
      skip_val = options[:skip] || (@skip > 0 ? @skip : 0)

      if block_given?
        # Builder block mode
        index_name = options[:index] || Parse::AtlasSearch.default_index
        builder = Parse::AtlasSearch::SearchBuilder.new(index_name: index_name)
        yield builder

        # Build pipeline: $search must be first
        pipeline = [builder.build]

        # Add score projection
        pipeline << { "$addFields" => { "_score" => { "$meta" => "searchScore" } } }

        # Add existing query constraints as $match
        compiled_where = compile_where
        if compiled_where.present?
          regular_constraints = compiled_where.reject { |f, _| f == "__aggregation_pipeline" }
          if regular_constraints.any?
            mongo_constraints = convert_constraints_for_direct_mongodb(regular_constraints)
            pipeline << { "$match" => mongo_constraints }
          end
        end

        # Add sort, skip, limit
        pipeline << { "$sort" => { "_score" => -1 } }
        pipeline << { "$skip" => skip_val } if skip_val > 0
        pipeline << { "$limit" => limit }

        # Execute
        raw_results = Parse::MongoDB.aggregate(@table, pipeline)

        # Convert results
        if options[:raw]
          Parse::AtlasSearch::SearchResult.new(results: raw_results, raw_results: raw_results)
        else
          parse_results = Parse::MongoDB.convert_documents_to_parse(raw_results, @table)
          objects = parse_results.map { |doc| Parse.decode(doc) }.compact
          Parse::AtlasSearch::SearchResult.new(results: objects, raw_results: raw_results)
        end
      else
        # Simple options API - delegate to AtlasSearch module
        raise ArgumentError, "query string is required when not using a block" if query.nil?

        # Merge query constraints as filter
        compiled_where = compile_where
        if compiled_where.present?
          regular_constraints = compiled_where.reject { |f, _| f == "__aggregation_pipeline" }
          options[:filter] = (options[:filter] || {}).merge(regular_constraints) if regular_constraints.any?
        end

        options[:class_name] = @table
        options[:limit] = limit
        options[:skip] = skip_val

        Parse::AtlasSearch.search(@table, query, **options)
      end
    end

    # Execute an autocomplete search using MongoDB Atlas Search.
    # Provides search-as-you-type functionality for a specific field.
    #
    # @example Basic autocomplete
    #   result = Song.query.atlas_autocomplete("lov", field: :title)
    #   result.suggestions # => ["Love Story", "Lovely Day", "Love Me Do"]
    #
    # @example With fuzzy matching and filters
    #   result = Song.query(:genre => "Pop").atlas_autocomplete("bea",
    #     field: :title,
    #     fuzzy: true,
    #     limit: 5
    #   )
    #
    # @param query [String] the partial search query (prefix)
    # @param field [Symbol, String] the field configured for autocomplete (required)
    # @param options [Hash] autocomplete options
    # @option options [String] :index search index name (default: "default")
    # @option options [Boolean] :fuzzy enable fuzzy matching (default: false)
    # @option options [String] :token_order "any" or "sequential" (default: "any")
    # @option options [Integer] :limit max suggestions to return (default: 10)
    # @option options [Boolean] :raw return raw documents (default: false)
    #
    # @return [Parse::AtlasSearch::AutocompleteResult] autocomplete result
    # @raise [Parse::AtlasSearch::NotAvailable] if Atlas Search is not configured
    # @raise [Parse::AtlasSearch::InvalidSearchParameters] if field is not provided
    #
    # @see Parse::AtlasSearch.autocomplete
    def atlas_autocomplete(query, field:, **options)
      require_relative "atlas_search"

      unless Parse::AtlasSearch.available?
        raise Parse::AtlasSearch::NotAvailable,
          "Atlas Search is not available. " \
          "Call Parse::AtlasSearch.configure(enabled: true) after configuring Parse::MongoDB."
      end

      # Merge query constraints as filter
      compiled_where = compile_where
      if compiled_where.present?
        regular_constraints = compiled_where.reject { |f, _| f == "__aggregation_pipeline" }
        options[:filter] = (options[:filter] || {}).merge(regular_constraints) if regular_constraints.any?
      end

      # Use query limit if set and no explicit limit provided
      options[:limit] ||= (@limit.is_a?(Numeric) && @limit > 0 ? @limit : 10)
      options[:class_name] = @table

      Parse::AtlasSearch.autocomplete(@table, query, field: field, **options)
    end

    # Execute a faceted search using MongoDB Atlas Search.
    # Returns search results along with aggregated facet counts for filtering.
    #
    # @example Faceted search by genre and decade
    #   facets = {
    #     genre: { type: :string, path: :genre, num_buckets: 10 },
    #     decade: { type: :number, path: :year, boundaries: [1970, 1980, 1990, 2000, 2010] }
    #   }
    #   result = Song.query(:plays.gt => 100).atlas_facets("rock", facets)
    #
    #   result.total_count  # => 1500
    #   result.facets[:genre]
    #   # => [{ value: "Rock", count: 500 }, { value: "Pop Rock", count: 200 }, ...]
    #
    # @param query [String, nil] the search query text (nil for match-all)
    # @param facets [Hash] facet definitions with the following structure:
    #   - name [Symbol] => Hash with:
    #     - :type [Symbol] - :string, :number, or :date
    #     - :path [Symbol, String] - the field path
    #     - :num_buckets [Integer] - (string only) max number of buckets
    #     - :boundaries [Array] - (number/date only) bucket boundaries
    #     - :default [String] - (number/date only) default bucket name
    # @param options [Hash] search options (same as atlas_search)
    #
    # @return [Parse::AtlasSearch::FacetedResult] faceted result with results, facets, and total_count
    # @raise [Parse::AtlasSearch::NotAvailable] if Atlas Search is not configured
    #
    # @see Parse::AtlasSearch.faceted_search
    def atlas_facets(query, facets, **options)
      require_relative "atlas_search"

      unless Parse::AtlasSearch.available?
        raise Parse::AtlasSearch::NotAvailable,
          "Atlas Search is not available. " \
          "Call Parse::AtlasSearch.configure(enabled: true) after configuring Parse::MongoDB."
      end

      # Merge query constraints as filter
      compiled_where = compile_where
      if compiled_where.present?
        regular_constraints = compiled_where.reject { |f, _| f == "__aggregation_pipeline" }
        options[:filter] = (options[:filter] || {}).merge(regular_constraints) if regular_constraints.any?
      end

      # Use query limit/skip if set
      options[:limit] ||= (@limit.is_a?(Numeric) && @limit > 0 ? @limit : 100)
      options[:skip] ||= (@skip > 0 ? @skip : 0)
      options[:class_name] = @table

      Parse::AtlasSearch.faceted_search(@table, query, facets, **options)
    end

    # Build an aggregation pipeline optimized for direct MongoDB execution.
    # This differs from build_aggregation_pipeline in that it uses MongoDB's
    # native field names (_id, _created_at, _updated_at, _p_* for pointers).
    #
    # @return [Array<Hash>] MongoDB aggregation pipeline stages
    # @api private
    def build_direct_mongodb_pipeline
      pipeline = []

      # Compile the where clause and convert for direct MongoDB access
      compiled_where = compile_where

      if compiled_where.present?
        # Remove aggregation pipeline marker if present
        regular_constraints = compiled_where.reject { |field, _| field == "__aggregation_pipeline" }

        if regular_constraints.any?
          # Convert field names and values for direct MongoDB access
          mongo_constraints = convert_constraints_for_direct_mongodb(regular_constraints)
          pipeline << { "$match" => mongo_constraints } if mongo_constraints.any?
        end

        # Handle aggregation pipeline stages (from empty_or_nil, set_equals, etc.)
        if compiled_where.key?("__aggregation_pipeline")
          compiled_where["__aggregation_pipeline"].each do |stage|
            pipeline << convert_stage_for_direct_mongodb(stage)
          end
        end
      end

      # Add sort stage if order is specified
      if @order.any?
        sort_spec = {}
        @order.each do |order_clause|
          # Handle both Parse::Order objects and string representations
          if order_clause.is_a?(Parse::Order)
            field = order_clause.field.to_s
            direction = order_clause.direction == :desc ? -1 : 1
            sort_spec[convert_field_for_direct_mongodb(field)] = direction
          elsif order_clause.is_a?(String)
            # Parse order clause (e.g., "-createdAt" or "name")
            if order_clause.start_with?("-")
              field = order_clause[1..-1]
              sort_spec[convert_field_for_direct_mongodb(field)] = -1
            else
              sort_spec[convert_field_for_direct_mongodb(order_clause)] = 1
            end
          end
        end
        pipeline << { "$sort" => sort_spec } if sort_spec.any?
      end

      # Add include/eager loading $lookup stages if @includes is populated
      # These stages resolve pointer fields to full objects
      if @includes.any?
        include_stages = build_include_lookup_stages(@includes)
        pipeline.concat(include_stages)
      end

      # Add skip stage if specified
      pipeline << { "$skip" => @skip } if @skip > 0

      # Add limit stage if specified
      pipeline << { "$limit" => @limit } if @limit.is_a?(Numeric) && @limit > 0

      # Add $project stage if specific keys are requested
      # Always include required fields: _id, _created_at, _updated_at, _acl
      if @keys.any?
        project_stage = {
          "_id" => 1,
          "_created_at" => 1,
          "_updated_at" => 1,
          "_acl" => 1,
        }
        @keys.each do |key|
          mongo_field = convert_field_for_direct_mongodb(key.to_s)
          project_stage[mongo_field] = 1
        end
        pipeline << { "$project" => project_stage }
      end

      # Optimize pipeline by merging consecutive $match stages
      deduplicate_consecutive_match_stages(pipeline)
    end

    # Build $lookup stages for included pointer fields in direct MongoDB queries.
    # This enables eager loading of related objects when using results_direct.
    #
    # @param includes [Array<Symbol>] the fields to include (from @includes)
    # @return [Array<Hash>] MongoDB $lookup stages for each included field
    # @api private
    def build_include_lookup_stages(includes)
      return [] if includes.nil? || includes.empty?

      stages = []
      includes.each do |field|
        # Handle nested includes (e.g., 'artist.label') - only process first level
        field_str = field.to_s
        base_field = field_str.split(".").first.to_sym

        # Get target class from model references
        target_class = get_pointer_target_class(base_field)
        next unless target_class

        # MongoDB pointer field name
        mongo_pointer_field = "_p_#{base_field}"
        lookup_result_field = "_included_#{base_field}"
        lookup_id_field = "_include_id_#{base_field}"

        # Stage 1: Extract objectId from pointer string using $split
        # Parse pointers are stored as "ClassName$objectId"
        stages << {
          "$addFields" => {
            lookup_id_field => {
              "$arrayElemAt" => [
                { "$split" => ["$#{mongo_pointer_field}", { "$literal" => "$" }] },
                1,
              ],
            },
          },
        }

        # Stage 2: $lookup to join with target collection
        stages << {
          "$lookup" => {
            "from" => target_class,
            "localField" => lookup_id_field,
            "foreignField" => "_id",
            "as" => lookup_result_field,
          },
        }

        # Stage 3: Unwind the array (since $lookup returns array, but we want single object)
        stages << {
          "$unwind" => {
            "path" => "$#{lookup_result_field}",
            "preserveNullAndEmptyArrays" => true,
          },
        }

        # Stage 4: Clean up temporary lookup ID field
        stages << {
          "$unset" => lookup_id_field,
        }
      end

      stages
    end

    # Get the target class name for a pointer field from model references.
    # Uses the model's references hash which maps field names to target class names.
    #
    # @param field [Symbol] the field name
    # @return [String, nil] the target class name or nil if not found
    # @api private
    def get_pointer_target_class(field)
      begin
        klass = Parse::Model.find_class(@table)
        return nil unless klass.respond_to?(:references)

        references = klass.references
        return nil if references.nil? || references.empty?

        # Check both the field name and its formatted Parse field name
        formatted_field = Query.format_field(field).to_sym

        # Try direct lookup first, then formatted field
        target = references[field] || references[formatted_field]

        # Also check field_map for aliased fields
        if target.nil? && klass.respond_to?(:field_map)
          mapped_field = klass.field_map[field]
          target = references[mapped_field] if mapped_field
        end

        target
      rescue NameError, StandardError
        nil
      end
    end

    # Convert constraints for direct MongoDB execution.
    # @param constraints [Hash] the compiled where constraints
    # @return [Hash] constraints with MongoDB-native field names
    # @api private
    def convert_constraints_for_direct_mongodb(constraints)
      return constraints unless constraints.is_a?(Hash)

      result = {}
      constraints.each do |field, value|
        field_str = field.to_s

        # Skip special operators
        if field_str.start_with?("$")
          # Recursively convert nested constraints in $and, $or, $nor
          if value.is_a?(Array) && %w[$and $or $nor].include?(field_str)
            result[field_str] = value.map { |v| convert_constraints_for_direct_mongodb(v) }
          else
            result[field_str] = value
          end
          next
        end

        # Convert field name for MongoDB
        mongo_field = convert_field_for_direct_mongodb(field_str)

        # Convert value
        result[mongo_field] = convert_value_for_direct_mongodb(field_str, value)
      end

      result
    end

    # Convert a field name for direct MongoDB access.
    # @param field [String] the Parse field name
    # @return [String] the MongoDB field name
    # @api private
    def convert_field_for_direct_mongodb(field)
      field_str = field.to_s

      # MongoDB internal fields should pass through unchanged
      # These start with underscore and are used internally by MongoDB/Parse
      return field_str if field_str =~ /^_/ && %w[
        _id _created_at _updated_at _acl _rperm _wperm
        _hashed_password _email_verify_token _perishable_token
        _tombstone _failed_login_count _account_lockout_expires_at _session_token
      ].include?(field_str)

      # Also preserve pointer field references (e.g., _p_artist)
      return field_str if field_str.start_with?("_p_")

      # Apply field formatting for regular fields
      field_str = Query.format_field(field)

      case field_str
      when "objectId"
        "_id"
      when "createdAt"
        "_created_at"
      when "updatedAt"
        "_updated_at"
      else
        # Check if this is a pointer field using schema
        if field_is_pointer?(field_str)
          "_p_#{field_str}"
        else
          field_str
        end
      end
    end

    # Convert a value for direct MongoDB execution.
    # @param field [String] the field name (for context)
    # @param value [Object] the value to convert
    # @return [Object] the converted value
    # @api private
    def convert_value_for_direct_mongodb(field, value)
      case value
      when Hash
        # Handle both string and symbol keys for __type checks
        type_value = value["__type"] || value[:__type]

        if type_value == "Pointer"
          # Convert Parse pointer to MongoDB pointer string format
          class_name = value["className"] || value[:className]
          object_id = value["objectId"] || value[:objectId]
          "#{class_name}$#{object_id}"
        elsif type_value == "Date"
          # Convert Parse Date format to Time object for BSON Date
          iso_value = value["iso"] || value[:iso]
          Time.parse(iso_value).utc
        else
          # Recursively convert nested hash (for operators like $gt, $in, etc.)
          # Convert symbol keys to strings for MongoDB
          converted = {}
          value.each do |k, v|
            key_str = k.to_s
            converted[key_str] = convert_value_for_direct_mongodb(field, v)
          end
          converted
        end
      when Parse::Pointer
        "#{value.parse_class}$#{value.id}"
      when Parse::Date
        # Parse::Date extends DateTime - convert to Time for BSON Date
        value.to_time.utc
      when Time
        value.utc
      when DateTime
        value.to_time.utc
      when Date
        value.to_time.utc
      when Array
        value.map { |v| convert_value_for_direct_mongodb(field, v) }
      else
        value
      end
    end

    # Convert an aggregation stage for direct MongoDB execution.
    # @param stage [Hash] a single pipeline stage
    # @return [Hash] the converted stage
    # @api private
    def convert_stage_for_direct_mongodb(stage)
      return stage unless stage.is_a?(Hash)

      result = {}
      stage.each do |operator, value|
        case operator
        when "$match"
          result["$match"] = convert_constraints_for_direct_mongodb(value)
        when "$project"
          result["$project"] = convert_projection_for_direct_mongodb(value)
        when "$sort"
          result["$sort"] = convert_sort_for_direct_mongodb(value)
        when "$group"
          result["$group"] = convert_group_for_direct_mongodb(value)
        else
          result[operator] = value
        end
      end
      result
    end

    # Convert projection fields for direct MongoDB.
    # @api private
    def convert_projection_for_direct_mongodb(projection)
      return projection unless projection.is_a?(Hash)

      result = {}
      projection.each do |field, value|
        mongo_field = convert_field_for_direct_mongodb(field)
        result[mongo_field] = value.is_a?(String) && value.start_with?("$") ?
          "$#{convert_field_for_direct_mongodb(value[1..-1])}" : value
      end
      result
    end

    # Convert sort specification for direct MongoDB.
    # @api private
    def convert_sort_for_direct_mongodb(sort)
      return sort unless sort.is_a?(Hash)

      result = {}
      sort.each do |field, direction|
        mongo_field = convert_field_for_direct_mongodb(field)
        result[mongo_field] = direction
      end
      result
    end

    # Convert $group stage for direct MongoDB.
    # @api private
    def convert_group_for_direct_mongodb(group)
      return group unless group.is_a?(Hash)

      result = {}
      group.each do |field, value|
        if field == "_id"
          result["_id"] = convert_group_id_for_direct_mongodb(value)
        else
          result[field] = value
        end
      end
      result
    end

    # Convert $group _id specification for direct MongoDB.
    # @api private
    def convert_group_id_for_direct_mongodb(id_spec)
      case id_spec
      when String
        if id_spec.start_with?("$")
          "$#{convert_field_for_direct_mongodb(id_spec[1..-1])}"
        else
          id_spec
        end
      when Hash
        result = {}
        id_spec.each do |k, v|
          result[k] = convert_group_id_for_direct_mongodb(v)
        end
        result
      else
        id_spec
      end
    end

    # Create a cursor-based paginator for efficiently traversing large datasets.
    #
    # Cursor-based pagination is more efficient than skip/offset pagination for large
    # datasets because it uses the last seen objectId to fetch the next page, rather
    # than skipping over records.
    #
    # @example Basic usage
    #   cursor = Song.query(:artist => "Artist").cursor(limit: 100)
    #   cursor.each_page do |page|
    #     process(page)
    #   end
    #
    # @example Iterating over individual items
    #   Song.query.cursor(limit: 50).each do |song|
    #     puts song.title
    #   end
    #
    # @example With custom ordering
    #   cursor = User.query.cursor(limit: 100, order: :created_at.desc)
    #   cursor.each_page { |page| process(page) }
    #
    # @param limit [Integer] the number of items per page (default: 100)
    # @param order [Parse::Order, Symbol] the ordering for pagination.
    #   Defaults to :created_at.asc for stable ordering.
    # @return [Parse::Cursor] a cursor object for paginating results
    # @see Parse::Cursor
    def cursor(limit: 100, order: nil)
      Parse::Cursor.new(self, limit: limit, order: order)
    end

    # Subscribe to real-time updates for objects matching this query.
    # Uses Parse LiveQuery WebSocket connection to receive push notifications
    # when objects are created, updated, deleted, or enter/leave the query results.
    #
    # @example Basic subscription
    #   subscription = Song.query(:artist => "Beatles").subscribe
    #   subscription.on(:create) { |song| puts "New song: #{song.title}" }
    #   subscription.on(:update) { |song, original| puts "Updated!" }
    #   subscription.on(:delete) { |song| puts "Deleted: #{song.id}" }
    #
    # @example With field filtering
    #   subscription = User.query(:status => "active").subscribe(fields: ["name", "email"])
    #   subscription.on_update { |user| puts "User updated: #{user.name}" }
    #
    # @example With session token for ACL-aware subscriptions
    #   subscription = PrivateData.query.subscribe(session_token: current_user.session_token)
    #
    # @param fields [Array<String>] specific fields to watch for changes (nil = all fields)
    # @param session_token [String] session token for ACL-aware subscriptions
    # @param client [Parse::LiveQuery::Client] custom LiveQuery client (optional)
    # @return [Parse::LiveQuery::Subscription] the subscription object
    # @see Parse::LiveQuery::Subscription
    def subscribe(fields: nil, session_token: nil, client: nil)
      require_relative "live_query"

      lq_client = client || Parse::LiveQuery.client
      lq_client.subscribe(
        @table,
        where: compile_where,
        fields: fields,
        session_token: session_token || @session_token,
      )
    end

    # Returns the query execution plan from MongoDB.
    # This is useful for analyzing query performance and understanding
    # which indexes are being used.
    #
    # @example Get execution plan for a query
    #   Song.query(:plays.gt => 1000).explain
    #   # Returns detailed execution plan showing index usage, stages, etc.
    #
    # @example Analyze a complex query
    #   query = User.query(:email.like => "%@example.com").order(:createdAt.desc)
    #   plan = query.explain
    #   puts "Index used: #{plan['queryPlanner']['winningPlan']['stage']}"
    #
    # @return [Hash] the query execution plan from MongoDB
    # @note This feature requires MongoDB explain support in Parse Server.
    #   The format of the returned plan depends on the MongoDB version.
    def explain
      compiled_query = compile
      compiled_query[:explain] = true
      response = client.find_objects(@table, compiled_query.as_json, **_opts)
      if response.error?
        puts "[ParseQuery:Explain] #{response.error}"
        return {}
      end
      response.result
    end

    # Merge consecutive $match stages in an aggregation pipeline.
    # This optimization combines redundant stages that can occur when building
    # pipelines from multiple constraint sources. Identical stages are deduplicated,
    # and non-identical consecutive $match stages are merged using $and.
    # @param pipeline [Array<Hash>] the aggregation pipeline stages
    # @return [Array<Hash>] the optimized pipeline with merged $match stages
    # @api private
    def deduplicate_consecutive_match_stages(pipeline)
      return pipeline if pipeline.empty?

      result = []
      pipeline.each do |stage|
        if stage.is_a?(Hash) && stage.key?("$match") &&
           result.last.is_a?(Hash) && result.last.key?("$match")
          prev_match = result.last["$match"]
          curr_match = stage["$match"]

          # Skip if identical
          next if prev_match == curr_match

          # Merge the two $match stages using $and
          # Handle cases where either side might already have $and
          prev_conditions = prev_match.key?("$and") ? prev_match["$and"] : [prev_match]
          curr_conditions = curr_match.key?("$and") ? curr_match["$and"] : [curr_match]

          # Replace the previous $match with the merged version
          result[-1] = { "$match" => { "$and" => prev_conditions + curr_conditions } }
        else
          result << stage
        end
      end
      result
    end

    # Create an Aggregation object for executing arbitrary MongoDB pipelines
    # @param pipeline [Array<Hash>] the MongoDB aggregation pipeline stages
    # @param verbose [Boolean] whether to print verbose debug output for the aggregation
    # @return [Aggregation] an aggregation object that can be executed
    # @example
    #   pipeline = [
    #     { "$match" => { "status" => "active" } },
    #     { "$group" => { "_id" => "$category", "count" => { "$sum" => 1 } } }
    #   ]
    #   aggregation = Asset.query.aggregate(pipeline)
    #   results = aggregation.results
    #   raw_results = aggregation.raw
    #   pointer_results = aggregation.result_pointers
    #
    #   # With verbose output
    #   aggregation = Asset.query.aggregate(pipeline, verbose: true)
    #   # With MongoDB direct (required for $inQuery constraints in aggregation)
    #   aggregation = Asset.query.aggregate(pipeline, mongo_direct: true)
    # Pipeline stages that are blocked to prevent data exfiltration or destructive operations.
    BLOCKED_PIPELINE_STAGES = %w[$out $merge $planCacheSetFilter $planCacheClear $function $accumulator $collMod $createIndex $dropIndex].freeze

    def aggregate(pipeline, verbose: nil, mongo_direct: nil)
      validate_pipeline!(pipeline)

      # Automatically prepend query constraints as pipeline stages
      complete_pipeline = []
      lookup_stages = []  # Track if we have $inQuery constraints

      # Add $match stage from where constraints if any exist
      unless @where.empty?
        where_clause = Parse::Query.compile_where(@where)
        if where_clause.any?
          # Collect match conditions and stages
          initial_match_conditions = []
          aggregation_match_conditions = []
          non_match_stages = []
          post_lookup_match = {}

          # Extract regular constraints (everything except __aggregation_pipeline)
          regular_constraints = where_clause.reject { |field, _| field == "__aggregation_pipeline" }

          if regular_constraints.any?
            # Handle dates first
            date_converted = convert_dates_for_aggregation(regular_constraints)

            # Extract $inQuery/$notInQuery and convert to $lookup stages
            if has_subquery_constraints?(date_converted)
              lookup_result = extract_subquery_to_lookup_stages(date_converted)
              date_converted = lookup_result[:constraints]
              lookup_stages = lookup_result[:lookup_stages]
              post_lookup_match = lookup_result[:post_lookup_match]
            end

            # Convert field names for aggregation context and handle pointers
            if date_converted.any?
              match_stage = convert_constraints_for_aggregation(date_converted)
              initial_match_conditions << match_stage
            end
          end

          # Extract aggregation pipeline stages
          if where_clause.key?("__aggregation_pipeline")
            where_clause["__aggregation_pipeline"].each do |stage|
              if stage.is_a?(Hash) && stage.key?("$match")
                aggregation_match_conditions << stage["$match"]
              else
                non_match_stages << stage
              end
            end
          end

          # Stage 1: Initial $match with regular constraints
          if initial_match_conditions.any?
            if initial_match_conditions.length == 1
              complete_pipeline << { "$match" => initial_match_conditions.first }
            else
              complete_pipeline << { "$match" => { "$and" => initial_match_conditions } }
            end
          end

          # Stage 2: $lookup stages for subqueries ($addFields, $lookup)
          if lookup_stages.any?
            lookup_stages.each do |stage|
              next if stage.key?("$project")
              complete_pipeline << stage
            end

            # Stage 3: Post-lookup $match
            if post_lookup_match.any?
              complete_pipeline << { "$match" => post_lookup_match }
            end

            # Note: Skip cleanup $project stage - see build_aggregation_pipeline for reasoning
          end

          # Stage 5: Aggregation $match conditions
          if aggregation_match_conditions.any?
            if aggregation_match_conditions.length == 1
              complete_pipeline << { "$match" => aggregation_match_conditions.first }
            else
              complete_pipeline << { "$match" => { "$and" => aggregation_match_conditions } }
            end
          end

          # Stage 6: Non-$match stages from aggregation pipeline
          complete_pipeline.concat(non_match_stages)
        end
      end

      # Append the provided pipeline stages
      complete_pipeline.concat(pipeline)

      # Add $sort stage from order constraints if any exist
      unless @order.empty?
        sort_stage = {}
        @order.each do |order_obj|
          # order_obj is a Parse::Order object with field and direction
          field_name = order_obj.field.to_s
          direction = order_obj.direction == :desc ? -1 : 1
          sort_stage[field_name] = direction
        end
        complete_pipeline << { "$sort" => sort_stage } if sort_stage.any?
      end

      # Add $skip stage if specified
      if @skip > 0
        complete_pipeline << { "$skip" => @skip }
      end

      # Add $limit stage if specified
      if @limit.is_a?(Numeric) && @limit > 0
        complete_pipeline << { "$limit" => @limit }
      end

      # Auto-detect if mongo_direct is needed (when $inQuery constraints are present and MongoDB is available)
      use_mongo_direct = mongo_direct
      if use_mongo_direct.nil? && lookup_stages && lookup_stages.any? && defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
        use_mongo_direct = true
      end

      # Optimize pipeline by merging consecutive $match stages
      complete_pipeline = deduplicate_consecutive_match_stages(complete_pipeline)

      Aggregation.new(self, complete_pipeline, verbose: verbose, mongo_direct: use_mongo_direct || false)
    end

    # Validates that a pipeline does not contain blocked stages or dangerous operators.
    # @param pipeline [Array<Hash>] the aggregation pipeline stages.
    # @raise [ArgumentError] if a blocked stage or dangerous operator is found.
    def validate_pipeline!(pipeline)
      pipeline.each do |stage|
        next unless stage.is_a?(Hash)
        stage.each_key do |key|
          if BLOCKED_PIPELINE_STAGES.include?(key.to_s)
            raise ArgumentError, "Aggregation pipeline stage '#{key}' is blocked for security reasons"
          end
        end
        # Block $where inside $match stages
        if stage.key?("$match") && stage["$match"].is_a?(Hash)
          validate_no_where_operator!(stage["$match"])
        end
      end
    end

    # Recursively checks a hash for $where operators.
    # @param hash [Hash] the hash to check.
    # @raise [ArgumentError] if $where is found.
    def validate_no_where_operator!(hash)
      hash.each do |key, value|
        if key.to_s == "$where"
          raise ArgumentError, "The $where operator is blocked for security reasons"
        end
        validate_no_where_operator!(value) if value.is_a?(Hash)
        if value.is_a?(Array)
          value.each { |v| validate_no_where_operator!(v) if v.is_a?(Hash) }
        end
      end
    end

    # Converts the current query into an aggregate pipeline and executes it.
    # This method automatically converts all query constraints (where, order, limit, skip, etc.)
    # into MongoDB aggregation pipeline stages.
    # @param additional_stages [Array<Hash>] optional additional pipeline stages to append
    # @param verbose [Boolean] whether to print verbose debug output for the aggregation
    # @return [Aggregation] an aggregation object that can be executed
    # @example
    #   # Convert a regular query to aggregate pipeline
    #   query = User.where(:age.gte => 18).order(:name).limit(10)
    #   aggregation = query.aggregate_from_query
    #   results = aggregation.results
    #
    #   # With additional pipeline stages
    #   aggregation = query.aggregate_from_query([
    #     { "$group" => { "_id" => "$department", "count" => { "$sum" => 1 } } }
    #   ])
    def aggregate_from_query(additional_stages = [], verbose: nil, mongo_direct: nil)
      # Build pipeline from current query constraints
      pipeline, has_lookup_stages = build_query_aggregate_pipeline

      # Append any additional stages
      pipeline.concat(additional_stages) if additional_stages.any?

      # Auto-detect if mongo_direct is needed (when $inQuery constraints are present and MongoDB is available)
      use_mongo_direct = mongo_direct
      if use_mongo_direct.nil? && has_lookup_stages && defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
        use_mongo_direct = true
      end

      # Create Aggregation directly to avoid double-applying constraints
      Aggregation.new(self, pipeline, verbose: verbose, mongo_direct: use_mongo_direct || false)
    end

    private

    # Builds a complete aggregation pipeline from the current query's constraints
    # @return [Array] Two element array: [pipeline, has_lookup_stages]
    def build_query_aggregate_pipeline
      pipeline = []
      has_lookup_stages = false

      # Add $match stage from where constraints
      unless @where.empty?
        where_clause = Parse::Query.compile_where(@where)
        if where_clause.any?
          # Handle $inQuery/$notInQuery constraints by converting to $lookup stages
          if has_subquery_constraints?(where_clause)
            lookup_result = extract_subquery_to_lookup_stages(where_clause)
            remaining_constraints = lookup_result[:constraints]
            lookup_stages = lookup_result[:lookup_stages]
            post_lookup_match = lookup_result[:post_lookup_match]
            has_lookup_stages = lookup_stages.any?

            # First add match for remaining constraints
            if remaining_constraints.any?
              match_stage = convert_for_aggregation(remaining_constraints)
              pipeline << { "$match" => match_stage }
            end

            # Add lookup stages
            lookup_stages.each do |stage|
              next if stage.key?("$project")
              pipeline << stage
            end

            # Add post-lookup match
            if post_lookup_match.any?
              pipeline << { "$match" => post_lookup_match }
            end
          else
            # Convert dates and other Parse-specific types for MongoDB aggregation
            match_stage = convert_for_aggregation(where_clause)
            pipeline << { "$match" => match_stage }
          end
        end
      end

      # Add $sort stage from order constraints
      unless @order.empty?
        sort_stage = {}
        @order.each do |order_obj|
          # order_obj is a Parse::Order object with field and direction
          field_name = order_obj.field.to_s
          direction = order_obj.direction == :desc ? -1 : 1
          sort_stage[field_name] = direction
        end
        pipeline << { "$sort" => sort_stage } if sort_stage.any?
      end

      # Add $skip stage if specified
      if @skip > 0
        pipeline << { "$skip" => @skip }
      end

      # Add $limit stage if specified
      if @limit.is_a?(Numeric) && @limit > 0
        pipeline << { "$limit" => @limit }
      end

      # Add $project stage if specific keys are requested
      unless @keys.empty?
        project_stage = {}
        @keys.each { |key| project_stage[key] = 1 }
        pipeline << { "$project" => project_stage }
      end

      [pipeline, has_lookup_stages]
    end

    # Converts Parse query constraints to MongoDB aggregation format
    # @param constraints [Hash] the compiled where constraints
    # @return [Hash] constraints formatted for MongoDB aggregation
    def convert_for_aggregation(constraints)
      # Handle nested constraints and convert Parse-specific types
      case constraints
      when Hash
        # Check if this is a Parse Date hash and convert to raw ISO string
        if constraints.keys == [:__type, :iso] && constraints[:__type] == "Date"
          return constraints[:iso]
        end

        # Check if this is a Parse Pointer hash and convert to MongoDB format
        if constraints.keys.sort == [:__type, :className, :objectId].sort && constraints[:__type] == "Pointer"
          return "#{constraints[:className]}$#{constraints[:objectId]}"
        end
        if constraints.keys.sort == ["__type", "className", "objectId"].sort && constraints["__type"] == "Pointer"
          return "#{constraints["className"]}$#{constraints["objectId"]}"
        end

        result = {}
        constraints.each do |key, value|
          result[key] = convert_for_aggregation(value)
        end
        result
      when Array
        constraints.map { |item| convert_for_aggregation(item) }
      when Parse::Date
        # Convert Parse::Date to raw ISO string for aggregation (Parse Server expects raw ISO strings in aggregation pipelines)
        constraints.iso
      when Time
        # Convert Ruby Time objects to raw ISO string for aggregation (Parse Server expects raw ISO strings in aggregation pipelines)
        constraints.utc.iso8601(3)
      when DateTime
        # Convert Ruby DateTime objects to raw ISO string for aggregation (Parse Server expects raw ISO strings in aggregation pipelines)
        constraints.utc.iso8601(3)
      when Parse::Object, Parse::Pointer
        # Convert Parse objects/pointers to MongoDB pointer format for aggregation
        # Parse Server expects "ClassName$objectId" format in aggregation pipelines, not Parse API format
        "#{constraints.parse_class}$#{constraints.id}"
      else
        constraints
      end
    end

    public

    # Alias for consistency
    alias_method :aggregate_pipeline, :aggregate

    # Execute an aggregation pipeline for queries with pipeline constraints
    # @return [Aggregation] the aggregation object (use .results to get Parse objects)
    def execute_aggregation_pipeline
      pipeline, has_lookup_stages = build_aggregation_pipeline

      # Determine if MongoDB direct should be used:
      # 1. Explicit opt-in via @acl_query_mongo_direct = true
      # 2. Auto-detect when lookup stages use $split with $literal (to parse pointer format),
      #    Parse Server's REST API can't handle it correctly
      # 3. Auto-detect when querying internal fields like _rperm or _wperm (ACL fields),
      #    Parse Server blocks these for security - must use MongoDB direct
      use_mongo_direct = false

      # Check for explicit mongo_direct preference first
      if defined?(@acl_query_mongo_direct) && !@acl_query_mongo_direct.nil?
        use_mongo_direct = @acl_query_mongo_direct
      elsif defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
        # Auto-detect based on pipeline contents
        if has_lookup_stages || pipeline_uses_internal_fields?(pipeline)
          use_mongo_direct = true
        end
      end

      # Create Aggregation directly to avoid double-applying constraints
      # The aggregate() method would redundantly add where constraints again
      Aggregation.new(self, pipeline, verbose: @verbose_aggregate, mongo_direct: use_mongo_direct)
    end

    # Check if the pipeline references internal Parse fields that require MongoDB direct access
    # @param pipeline [Array] the aggregation pipeline stages
    # @return [Boolean] true if internal fields are used
    def pipeline_uses_internal_fields?(pipeline)
      internal_fields = %w[_rperm _wperm _acl]
      pipeline_json = pipeline.to_json
      internal_fields.any? { |field| pipeline_json.include?(field) }
    end

    # Build the complete aggregation pipeline from constraints
    # Pipeline order: $match (regular) -> $lookup (subqueries) -> $match (post-lookup) -> $match (aggregation) -> non-$match stages -> limit/skip
    # @return [Array] Two element array: [pipeline, has_lookup_stages]
    def build_aggregation_pipeline
      pipeline = []
      compiled_where = compile_where
      has_lookup_stages = false

      # Collect match conditions and stages
      initial_match_conditions = []
      aggregation_match_conditions = []
      non_match_stages = []
      lookup_stages = []
      post_lookup_match = {}

      # Extract regular constraints (everything except __aggregation_pipeline)
      regular_constraints = compiled_where.reject { |field, _|
        field == "__aggregation_pipeline"
      }

      # Process regular constraints
      if regular_constraints.any?
        # Convert symbols to strings and handle date objects for MongoDB aggregation
        stringified_constraints = convert_dates_for_aggregation(JSON.parse(regular_constraints.to_json))

        # Extract $inQuery/$notInQuery and convert to $lookup stages
        if has_subquery_constraints?(stringified_constraints)
          lookup_result = extract_subquery_to_lookup_stages(stringified_constraints)
          stringified_constraints = lookup_result[:constraints]
          lookup_stages = lookup_result[:lookup_stages]
          post_lookup_match = lookup_result[:post_lookup_match]
          has_lookup_stages = lookup_stages.any?
        end

        # Convert remaining pointer field names and values to MongoDB aggregation format
        if stringified_constraints.any?
          stringified_constraints = convert_constraints_for_aggregation(stringified_constraints)
          initial_match_conditions << stringified_constraints
        end
      end

      # Extract aggregation pipeline stages (from empty_or_nil, set_equals, etc.)
      if compiled_where.key?("__aggregation_pipeline")
        compiled_where["__aggregation_pipeline"].each do |stage|
          if stage.is_a?(Hash) && stage.key?("$match")
            # Aggregation $match conditions go after lookup
            aggregation_match_conditions << stage["$match"]
          else
            # Non-$match stages go directly to pipeline
            non_match_stages << stage
          end
        end
      end

      # Stage 1: Initial $match with regular constraints (before lookup)
      # This filters down the dataset before the expensive $lookup
      if initial_match_conditions.any?
        if initial_match_conditions.length == 1
          pipeline << { "$match" => initial_match_conditions.first }
        else
          pipeline << { "$match" => { "$and" => initial_match_conditions } }
        end
      end

      # Stage 2: $lookup stages for subqueries ($addFields, $lookup)
      # These join with related collections and filter based on subquery conditions
      if lookup_stages.any?
        # Add $addFields and $lookup stages (skip $project stages)
        lookup_stages.each do |stage|
          next if stage.key?("$project")
          pipeline << stage
        end

        # Stage 3: Post-lookup $match to filter based on lookup results
        if post_lookup_match.any?
          pipeline << { "$match" => post_lookup_match }
        end

        # Note: We intentionally skip cleanup $project stage because:
        # 1. Parse Server's aggregation result processing ignores unknown fields
        # 2. Using $project with exclusions can cause issues in some MongoDB versions
        # 3. The temporary lookup fields (_lookup_*_id, _lookup_*_result) won't affect the output
      end

      # Stage 5: Aggregation $match conditions (from empty_or_nil, set_equals, etc.)
      if aggregation_match_conditions.any?
        if aggregation_match_conditions.length == 1
          pipeline << { "$match" => aggregation_match_conditions.first }
        else
          pipeline << { "$match" => { "$and" => aggregation_match_conditions } }
        end
      end

      # Stage 6: Non-$match stages from aggregation pipeline
      pipeline.concat(non_match_stages)

      # Stage 7: Add limit if specified
      if @limit.is_a?(Numeric) && @limit > 0
        pipeline << { "$limit" => @limit }
      end

      # Stage 8: Add skip if specified
      if @skip > 0
        pipeline << { "$skip" => @skip }
      end

      # Optimize pipeline by merging consecutive $match stages
      pipeline = deduplicate_consecutive_match_stages(pipeline)

      [pipeline, has_lookup_stages]
    end

    # Extract $inQuery and $notInQuery constraints and build $lookup stages for them.
    # This converts Parse subquery constraints into MongoDB $lookup stages that join
    # with the related collection and filter based on the subquery conditions.
    # Uses raw MongoDB field names (_p_field) and returns results via .raw aggregation.
    # @param constraints [Hash] the compiled where constraints
    # @return [Hash] with :constraints (remaining), :lookup_stages, and :post_lookup_match
    def extract_subquery_to_lookup_stages(constraints)
      return { constraints: constraints, lookup_stages: [], post_lookup_match: {} } unless constraints.is_a?(Hash)

      remaining_constraints = {}
      lookup_stages = []
      post_lookup_match = {}

      constraints.each do |field, value|
        # Check for both string and symbol keys
        has_in_query = value.is_a?(Hash) && (value.key?("$inQuery") || value.key?(:"$inQuery"))
        has_not_in_query = value.is_a?(Hash) && (value.key?("$notInQuery") || value.key?(:"$notInQuery"))

        if has_in_query || has_not_in_query
          is_in_query = has_in_query
          # Get the subquery config using the correct key type
          in_query_key = value.key?("$inQuery") ? "$inQuery" : :"$inQuery"
          not_in_query_key = value.key?("$notInQuery") ? "$notInQuery" : :"$notInQuery"
          subquery_config = value[is_in_query ? in_query_key : not_in_query_key]
          # Handle both string and symbol keys in the subquery config
          class_name = subquery_config["className"] || subquery_config[:className]
          where_clause = subquery_config["where"] || subquery_config[:where] || {}

          # Format field name for the pointer
          formatted_field = Query.format_field(field)
          mongo_pointer_field = "_p_#{formatted_field}"
          lookup_result_field = "_lookup_#{formatted_field}_result"
          lookup_id_field = "_lookup_#{formatted_field}_id"

          # Stage 1: Extract objectId from the pointer field using $split
          # Parse Server stores pointers as _p_fieldName with format "ClassName$objectId"
          # Use $literal to escape the $ character in the delimiter
          lookup_stages << {
            "$addFields" => {
              lookup_id_field => {
                "$arrayElemAt" => [
                  { "$split" => ["$#{mongo_pointer_field}", { "$literal" => "$" }] },
                  1,
                ],
              },
            },
          }

          # Stage 2: $lookup to join with the related collection
          # Build pipeline to match on _id and apply where conditions
          lookup_pipeline = [
            { "$match" => { "$expr" => { "$eq" => ["$_id", "$$lookupId"] } } },
          ]

          # Add where conditions to lookup pipeline if present
          if where_clause.any?
            converted_where = convert_dates_for_aggregation(where_clause)
            converted_where = convert_constraints_for_aggregation(converted_where)
            lookup_pipeline << { "$match" => converted_where }
          end

          lookup_stages << {
            "$lookup" => {
              "from" => class_name,
              "let" => { "lookupId" => "$#{lookup_id_field}" },
              "pipeline" => lookup_pipeline,
              "as" => lookup_result_field,
            },
          }

          # Match based on whether lookup returned results
          if is_in_query
            # $inQuery: keep documents where lookup found matches
            post_lookup_match[lookup_result_field] = { "$ne" => [] }
          else
            # $notInQuery: keep documents where lookup found no matches
            post_lookup_match[lookup_result_field] = { "$eq" => [] }
          end
        elsif value.is_a?(Hash)
          # Recursively handle nested constraints
          nested = extract_subquery_to_lookup_stages(value)
          if nested[:lookup_stages].any?
            lookup_stages.concat(nested[:lookup_stages])
            post_lookup_match.merge!(nested[:post_lookup_match])
            remaining_constraints[field] = nested[:constraints]
          else
            remaining_constraints[field] = value
          end
        else
          remaining_constraints[field] = value
        end
      end

      { constraints: remaining_constraints, lookup_stages: lookup_stages, post_lookup_match: post_lookup_match }
    end

    # Build a $filter condition expression from where constraints
    # @param where [Hash] the where constraints
    # @return [Hash] MongoDB expression for $filter cond
    def build_filter_condition(where)
      conditions = where.map do |field, value|
        if value.is_a?(Hash)
          # Handle operators like $gt, $lt, etc.
          value.map do |op, val|
            { op => ["$$item.#{field}", val] }
          end
        else
          # Simple equality
          { "$eq" => ["$$item.#{field}", value] }
        end
      end.flatten

      if conditions.length == 1
        conditions.first
      else
        { "$and" => conditions }
      end
    end

    # Check if constraints contain $inQuery or $notInQuery that need resolution
    # @param constraints [Hash] the compiled where constraints
    # @return [Boolean] true if subquery constraints are present
    def has_subquery_constraints?(constraints)
      return false unless constraints.is_a?(Hash)

      constraints.any? do |field, value|
        if value.is_a?(Hash)
          # Check for both string and symbol keys since constraints can come from
          # different sources (JSON parsing vs Ruby symbol keys)
          value.key?("$inQuery") || value.key?(:"$inQuery") ||
          value.key?("$notInQuery") || value.key?(:"$notInQuery") ||
          has_subquery_constraints?(value)
        else
          false
        end
      end
    end

    alias_method :result, :results

    # Similar to {#results} but takes an additional set of conditions to apply. This
    # method helps support the use of class and instance level scopes.
    # @param expressions (see #conditions)
    # @yield (see #results)
    # @return [Array<Hash>] if raw is set to true, a set of Parse JSON hashes.
    # @return [Array<Parse::Object>] if raw is set to false, a list of matching Parse::Object subclasses.
    # @see #results
    def all(expressions = { limit: :max }, &block)
      conditions(expressions)
      return results(&block) if block_given?
      results
    end

    # Builds objects based on the set of Parse JSON hashes in an array.
    # @param list [Array<Hash>] a list of Parse JSON hashes
    # @return [Array<Parse::Object>] an array of Parse::Object subclasses.
    def decode(list)
      # Pass fetched keys for partial fetch tracking (only if keys were specified)
      fetch_keys = @keys.present? && @keys.any? ? @keys : nil

      # Parse keys (not includes) to build nested fetched keys map
      # Keys like ["project.name", "project.status"] define which subfields to fetch on nested objects
      nested_keys = Parse::Query.parse_keys_to_nested_keys(@keys) if @keys.present?

      list.map { |m| Parse::Object.build(m, @table, fetched_keys: fetch_keys, nested_fetched_keys: nested_keys) }.compact
    end

    # Validates includes against keys and field types, printing debug warnings for:
    # 1. Non-pointer fields that are included (unnecessary include)
    # 2. Pointer fields that are included but also have subfield keys (redundant keys)
    # Skips validation for includes with dot notation (internal references).
    # Can be disabled by setting Parse.warn_on_query_issues = false
    # @!visibility private
    def validate_includes_vs_keys
      return unless Parse.warn_on_query_issues
      return if @includes.empty?

      # Get the model class to check field types
      klass = Parse::Model.find_class(@table)
      return unless klass.respond_to?(:fields)

      fields = klass.fields

      @includes.each do |inc|
        inc_str = inc.to_s

        # Skip includes with dots - these are internal references (e.g., "project.owner")
        next if inc_str.include?(".")

        inc_sym = inc_str.to_sym
        field_type = fields[inc_sym]

        # Check if the field is a pointer, relation, or array type
        # Arrays can contain pointers (has_many :through => :array) and need include to resolve them
        is_includable_field = [:pointer, :relation, :array].include?(field_type)

        if !is_includable_field && field_type.present?
          # Warn: non-object field doesn't need to be included
          puts "[Parse::Query] Warning: '#{inc_str}' is a #{field_type} field, not a pointer/relation/array - it does not need to be included (silence with Parse.warn_on_query_issues = false)"
        elsif is_includable_field
          # Check if there are keys with dot notation for this field
          subfield_keys = @keys.select { |k| k.to_s.start_with?("#{inc_str}.") }

          if subfield_keys.any?
            # Warn: including the full object makes subfield keys unnecessary
            puts "[Parse::Query] Warning: including '#{inc_str}' returns the full object - keys #{subfield_keys.map(&:to_s).inspect} are unnecessary (silence with Parse.warn_on_query_issues = false)"
          end
        end
      end
    end

    private :validate_includes_vs_keys

    # Builds Parse::Pointer objects based on the set of Parse JSON hashes in an array.
    # @param list [Array<Hash>] a list of Parse JSON hashes
    # @param field [Symbol, String, nil] optional field name for schema-based conversion
    # @return [Array<Parse::Pointer>] an array of Parse::Pointer instances.
    def to_pointers(list, field = nil)
      list.map do |m|
        if field
          # Use schema-based conversion when field is provided
          converted = convert_pointer_value_with_schema(m, field, return_pointers: true)
          if converted.is_a?(Parse::Pointer)
            converted
          elsif m.is_a?(String) && m.include?("$")
            # Fallback to string parsing if schema conversion didn't work
            class_name, object_id = m.split("$", 2)
            if class_name && object_id
              Parse::Pointer.new(class_name, object_id)
            end
          else
            nil
          end
        else
          # Original logic for backward compatibility
          if m.is_a?(Hash)
            if m["__type"] == "Pointer" && m["className"] && m["objectId"]
              # Parse pointer object - use the className from the pointer
              Parse::Pointer.new(m["className"], m["objectId"])
            elsif m["objectId"]
              # Standard Parse object with objectId - use the query table name
              Parse::Pointer.new(@table, m["objectId"])
            end
          elsif m.is_a?(String) && m.include?("$")
            # Handle MongoDB pointer string format: "ClassName$objectId"
            class_name, object_id = m.split("$", 2)
            if class_name && object_id
              Parse::Pointer.new(class_name, object_id)
            end
          end
        end
      end.compact
    end

    # @return [Hash]
    def as_json(*args)
      compile.as_json
    end

    # Returns a compiled query without encoding the where clause.
    # @param includeClassName [Boolean] whether to include the class name of the collection
    #  in the resulting compiled query.
    # @return [Hash] a hash representing the prepared query request.
    def prepared(includeClassName: false)
      compile(encode: false, includeClassName: includeClassName)
    end

    # Complies the query and runs all prepare callbacks.
    # @param encode [Boolean] whether to encode the `where` clause to a JSON string.
    # @param includeClassName [Boolean] whether to include the class name of the collection.
    # @return [Hash] a hash representing the prepared query request.
    # @see #before_prepare
    # @see #after_prepare
    def compile(encode: true, includeClassName: false)
      # Validate includes vs keys before compiling
      validate_includes_vs_keys

      run_callbacks :prepare do
        q = {} #query
        q[:limit] = @limit if @limit.is_a?(Numeric) && @limit > 0
        q[:skip] = @skip if @skip > 0

        q[:include] = @includes.join(",") unless @includes.empty?
        q[:keys] = @keys.join(",") unless @keys.empty?
        q[:order] = @order.join(",") unless @order.empty?
        unless @where.empty?
          q[:where] = Parse::Query.compile_where(@where)
          q[:where] = q[:where].to_json if encode
        end

        if @count && @count > 0
          # if count is requested
          q[:limit] = 0
          q[:count] = 1
        end
        if includeClassName
          q[:className] = @table
        end
        q
      end
    end

    # @return [Hash] a hash representing just the `where` clause of this query.
    def compile_where
      self.class.compile_where(@where || [])
    end

    # Returns the aggregation pipeline for this query if it contains pipeline-based constraints
    # @return [Array] the aggregation pipeline stages, or empty array if no pipeline needed
    def pipeline
      pipeline_stages = []

      # Check if any constraints generate aggregation pipelines
      @where.each do |constraint|
        if constraint.respond_to?(:as_json)
          constraint_json = constraint.as_json
          if constraint_json.is_a?(Hash) && constraint_json.has_key?("__aggregation_pipeline")
            pipeline_stages.concat(constraint_json["__aggregation_pipeline"])
          end
        end
      end

      pipeline_stages
    end

    # Check if this query requires aggregation pipeline execution
    # @return [Boolean] true if the query contains pipeline-based constraints
    def requires_aggregation?
      !pipeline.empty?
    end

    # Retruns a formatted JSON string representing the query, useful for debugging.
    # @return [String]
    def pretty
      JSON.pretty_generate(as_json)
    end

    # Calculate the sum of values for a specific field.
    # @param field [Symbol, String] the field name to sum.
    # @return [Numeric] the sum of all values for the field, or 0 if no results.
    def sum(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `sum`."
      end

      # Format field name according to Parse conventions
      formatted_field = format_aggregation_field(field)

      # Build the aggregation pipeline
      pipeline = [
        { "$group" => { "_id" => nil, "total" => { "$sum" => "$#{formatted_field}" } } },
      ]

      execute_basic_aggregation(pipeline, "sum", field, "total")
    end

    # Calculate the average of values for a specific field.
    # @param field [Symbol, String] the field name to average.
    # @return [Float] the average of all values for the field, or 0 if no results.
    def average(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `average`."
      end

      # Format field name according to Parse conventions
      formatted_field = format_aggregation_field(field)

      # Build the aggregation pipeline
      pipeline = [
        { "$group" => { "_id" => nil, "avg" => { "$avg" => "$#{formatted_field}" } } },
      ]

      execute_basic_aggregation(pipeline, "average", field, "avg")
    end

    alias_method :avg, :average

    # Find the minimum value for a specific field.
    # @param field [Symbol, String] the field name to find minimum for.
    # @return [Object] the minimum value for the field, or nil if no results.
    def min(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `min`."
      end

      # Format field name according to Parse conventions
      formatted_field = format_aggregation_field(field)

      # Build the aggregation pipeline
      pipeline = [
        { "$group" => { "_id" => nil, "min" => { "$min" => "$#{formatted_field}" } } },
      ]

      execute_basic_aggregation(pipeline, "min", field, "min")
    end

    # Find the maximum value for a specific field.
    # @param field [Symbol, String] the field name to find maximum for.
    # @return [Object] the maximum value for the field, or nil if no results.
    def max(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `max`."
      end

      # Format field name according to Parse conventions
      formatted_field = format_aggregation_field(field)

      # Build the aggregation pipeline
      pipeline = [
        { "$group" => { "_id" => nil, "max" => { "$max" => "$#{formatted_field}" } } },
      ]

      execute_basic_aggregation(pipeline, "max", field, "max")
    end

    # Group results by a specific field and return a GroupBy object for chaining aggregations.
    # @param field [Symbol, String] the field name to group by.
    # @param flatten_arrays [Boolean] if true, arrays will be flattened before grouping.
    #   This allows counting/aggregating individual array elements across all records.
    # @param sortable [Boolean] if true, returns a SortableGroupBy that supports sorting results.
    # @param return_pointers [Boolean] if true, converts Parse pointer group keys to Parse::Pointer objects.
    # @return [GroupBy, SortableGroupBy] an object that supports chaining aggregation methods.
    # @example
    #   Asset.group_by(:category).count
    #   Asset.where(:status => "active").group_by(:project).sum(:file_size)
    #   Asset.group_by(:media_format).average(:duration)
    #
    #   # Array flattening example:
    #   # Record 1: tags = ["a", "b"]
    #   # Record 2: tags = ["b", "c"]
    #   Asset.group_by(:tags, flatten_arrays: true).count
    #   # => {"a" => 1, "b" => 2, "c" => 1}
    #
    #   # Sortable results:
    #   Asset.group_by(:category, sortable: true).count.sort_by_value_desc
    #   # => [["video", 45], ["image", 23], ["audio", 12]]
    #
    #   # Return Parse::Pointer objects for pointer fields:
    #   Asset.group_by(:author_team, return_pointers: true).count
    #   # => {#<Parse::Pointer @parse_class="Team" @id="team1"> => 5, ...}
    # @param mongo_direct [Boolean] if true, queries MongoDB directly bypassing Parse Server.
    #   Requires Parse::MongoDB to be configured. Default: false.
    def group_by(field, flatten_arrays: false, sortable: false, return_pointers: false, mongo_direct: false)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `group_by`."
      end

      if sortable
        SortableGroupBy.new(self, field, flatten_arrays: flatten_arrays, return_pointers: return_pointers, mongo_direct: mongo_direct)
      else
        GroupBy.new(self, field, flatten_arrays: flatten_arrays, return_pointers: return_pointers, mongo_direct: mongo_direct)
      end
    end

    # Group Parse objects by a field value and return arrays of actual objects.
    # Unlike group_by which uses aggregation for counts/sums, this fetches all objects
    # and groups them in Ruby, returning the actual Parse object instances.
    # @param field [Symbol, String] the field name to group by.
    # @param return_pointers [Boolean] if true, returns Parse::Pointer objects instead of full objects.
    # @return [Hash] a hash with field values as keys and arrays of Parse objects as values.
    # @example
    #   # Get arrays of actual Asset objects grouped by category
    #   Asset.query.group_objects_by(:category)
    #   # => {
    #   #   "video" => [#<Asset:video1>, #<Asset:video2>, ...],
    #   #   "image" => [#<Asset:image1>, #<Asset:image2>, ...],
    #   #   "audio" => [#<Asset:audio1>, ...]
    #   # }
    #
    #   # Get Parse::Pointer objects instead (memory efficient)
    #   Asset.query.group_objects_by(:category, return_pointers: true)
    #   # => {
    #   #   "video" => [#<Parse::Pointer>, #<Parse::Pointer>, ...],
    #   #   "image" => [#<Parse::Pointer>, ...],
    #   #   "audio" => [#<Parse::Pointer>, ...]
    #   # }
    def group_objects_by(field, return_pointers: false)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `group_objects_by`."
      end

      # Fetch all objects that match the query
      objects = results(return_pointers: return_pointers)

      # Group objects by the specified field value
      grouped = {}
      objects.each do |obj|
        # Get the field value for grouping
        field_value = if obj.respond_to?(:attributes)
            # For Parse objects, try multiple field access patterns
            obj.attributes[field.to_s] ||
            obj.attributes[Query.format_field(field).to_s] ||
            (obj.respond_to?(field) ? obj.send(field) : nil)
          elsif obj.is_a?(Hash)
            # For raw JSON objects, try multiple field access patterns
            obj[field.to_s] ||
            obj[Query.format_field(field).to_s] ||
            obj[field.to_sym] ||
            obj[Query.format_field(field).to_sym]
          else
            # Fallback - try to access as method
            obj.respond_to?(field) ? obj.send(field) : nil
          end

        # Handle nil field values
        group_key = field_value.nil? ? "null" : field_value

        # Convert Parse pointer values to readable format for grouping key
        if group_key.is_a?(Hash) && group_key["__type"] == "Pointer"
          group_key = "#{group_key["className"]}##{group_key["objectId"]}"
        end

        # Initialize array if this is the first object for this group
        grouped[group_key] ||= []
        grouped[group_key] << obj
      end

      grouped
    end

    # Convert query results to a formatted table display.
    # @param columns [Array<Symbol, String, Hash>] column definitions. Can be:
    #   - Symbol/String: field name (e.g., :object_id, :name) or dot notation (e.g., "project.team.name")
    #   - Hash: { field: :custom_name, header: "Custom Header" }
    #   - Hash: { block: ->(obj) { obj.some_calculation }, header: "Calculated" }
    # @param format [Symbol] output format (:ascii, :csv, :json)
    # @param headers [Array<String>] custom headers (overrides auto-generated ones)
    # @return [String] formatted table
    # @example
    #   # Basic usage with object fields
    #   Project.query.to_table([:object_id, :name, :address])
    #
    #   # With dot notation for related objects
    #   Asset.query.to_table([
    #     :object_id,
    #     "project.name",        # Access project name through relationship
    #     "project.team.name",   # Access team name through project->team relationship
    #     :file_size
    #   ])
    #
    #   # With custom headers and calculated columns
    #   Project.query.to_table([
    #     { field: :object_id, header: "ID" },
    #     { field: "team.name", header: "Team Name" },
    #     { field: :address, header: "Project Address" },
    #     { block: ->(proj) { proj.notes.count }, header: "Note Count" }
    #   ])
    #
    #   # Your specific example:
    #   Project.query.to_table([
    #     :object_id,
    #     { field: :name, header: "Project Name" },
    #     { field: :address, header: "Project Address" },
    #     { block: ->(p) { p.notes&.count || 0 }, header: "Note Count" }
    #   ])
    def to_table(columns = nil, format: :ascii, headers: nil, sort_by: nil, sort_order: :asc)
      objects = results
      return format_empty_table(format) if objects.empty?

      # Auto-detect columns if not provided
      if columns.nil?
        columns = auto_detect_columns(objects.first)
      end

      # Build table data
      table_data = build_table_data(objects, columns, headers)

      # Sort table data if sort_by is specified
      if sort_by
        sort_table_data!(table_data, sort_by, sort_order)
      end

      # Format based on requested format
      case format
      when :ascii
        format_ascii_table(table_data)
      when :csv
        format_csv_table(table_data)
      when :json
        format_json_table(table_data)
      else
        raise ArgumentError, "Unsupported format: #{format}. Use :ascii, :csv, or :json"
      end
    end

    # Group results by a date field at specified time intervals.
    # @param field [Symbol, String] the date field name to group by.
    # @param interval [Symbol] the time interval (:year, :month, :week, :day, :hour).
    # @param sortable [Boolean] if true, returns a SortableGroupByDate that supports sorting results.
    # @param return_pointers [Boolean] if true, converts Parse pointer values to Parse::Pointer objects.
    #   Note: This is primarily for consistency - date groupings typically use formatted date strings as keys.
    # @return [GroupByDate, SortableGroupByDate] an object that supports chaining aggregation methods.
    # @example
    #   Capture.group_by_date(:created_at, :day).count
    #   Asset.group_by_date(:created_at, :month).sum(:file_size)
    #   Capture.where(:project => project_id).group_by_date(:created_at, :week).average(:duration)
    #
    #   # Sortable date results:
    #   Asset.group_by_date(:created_at, :day, sortable: true).count.sort_by_value_desc
    #   # => [["2024-11-25", 45], ["2024-11-24", 23], ...]
    # @param mongo_direct [Boolean] if true, queries MongoDB directly bypassing Parse Server.
    #   Requires Parse::MongoDB to be configured. Default: false.
    def group_by_date(field, interval, sortable: false, return_pointers: false, timezone: nil, mongo_direct: false)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `group_by_date`."
      end

      unless [:year, :month, :week, :day, :hour, :minute, :second].include?(interval.to_sym)
        raise ArgumentError, "Invalid interval. Must be one of: :year, :month, :week, :day, :hour, :minute, :second"
      end

      if sortable
        SortableGroupByDate.new(self, field, interval.to_sym, return_pointers: return_pointers, timezone: timezone, mongo_direct: mongo_direct)
      else
        GroupByDate.new(self, field, interval.to_sym, return_pointers: return_pointers, timezone: timezone, mongo_direct: mongo_direct)
      end
    end

    # Enhanced distinct method that automatically populates Parse pointer objects at the server level.
    # Uses aggregation pipeline to efficiently populate objects instead of post-processing.
    # @param field [Symbol, String] the field name to get distinct values for.
    # @return [Array] array of distinct values, with Parse pointers populated as full objects.
    # @example
    #   # Basic usage (returns raw values for non-pointer fields)
    #   Asset.query.distinct_objects(:media_format)
    #   # => ["video", "audio", "photo"]
    #
    #   # Auto-populate Parse pointer objects (much faster than manual conversion)
    #   Asset.query.distinct_objects(:author_team)
    #   # => [#<Team:0x123 @attributes={"name"=>"Team A", ...}>, ...]
    def distinct_objects(field, return_pointers: false)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `distinct_objects`."
      end

      # Use aggregation pipeline to get distinct values with populated objects
      execute_distinct_with_population(field, return_pointers: return_pointers)
    end

    private

    # Auto-detect columns from first object for table display.
    # @param obj [Parse::Object, Hash] first object to inspect
    # @return [Array<Symbol>] array of field names
    def auto_detect_columns(obj)
      if obj.respond_to?(:attributes)
        # Parse object - use common fields
        common_fields = [:object_id]
        obj.attributes.keys.reject { |k| k.start_with?("_") }.each do |key|
          common_fields << key.to_sym
        end
        common_fields.first(5) # Limit to first 5 fields
      elsif obj.is_a?(Hash)
        # Hash object
        obj.keys.map(&:to_sym).first(5)
      else
        [:object_id, :to_s]
      end
    end

    # Build table data structure with headers and rows.
    # @param objects [Array] array of objects to convert
    # @param columns [Array] column definitions
    # @param headers [Array<String>] custom headers
    # @return [Hash] { headers: [...], rows: [[...], [...]] }
    def build_table_data(objects, columns, headers)
      # Generate headers
      table_headers = headers || columns.map do |col|
        case col
        when Symbol, String
          col.to_s.gsub("_", " ").split.map(&:capitalize).join(" ")
        when Hash
          col[:header] || col[:field]&.to_s&.gsub("_", " ")&.split&.map(&:capitalize)&.join(" ") || "Custom"
        else
          "Unknown"
        end
      end

      # Generate rows
      table_rows = objects.map do |obj|
        columns.map do |col|
          extract_column_value(obj, col)
        end
      end

      { headers: table_headers, rows: table_rows }
    end

    # Extract value for a column from an object.
    # @param obj [Object] the object to extract from
    # @param col [Symbol, String, Hash] column definition
    # @return [String] formatted column value
    def extract_column_value(obj, col)
      value = case col
        when Symbol, String
          extract_field_value(obj, col)
        when Hash
          if col[:block]
            # Custom block evaluation
            begin
              col[:block].call(obj)
            rescue => e
              "Error: #{e.message}"
            end
          elsif col[:field]
            extract_field_value(obj, col[:field])
          else
            "N/A"
          end
        else
          "Unknown"
        end

      # Format the value for display
      format_table_value(value)
    end

    # Extract field value from object (similar to pluck logic).
    # Supports dot notation for nested attributes (e.g., "project.team.name").
    # @param obj [Object] object to extract from
    # @param field [Symbol, String] field name or dot-notation path
    # @return [Object] field value
    def extract_field_value(obj, field)
      field_path = field.to_s.split(".")
      current_obj = obj

      field_path.each do |segment|
        current_obj = extract_single_field_value(current_obj, segment)
        break if current_obj.nil?
      end

      current_obj
    end

    # Extract a single field value from an object (no dot notation).
    # @param obj [Object] object to extract from
    # @param field [String] single field name
    # @return [Object] field value
    def extract_single_field_value(obj, field)
      if obj.respond_to?(:attributes)
        # Parse objects - try multiple access patterns
        value = obj.attributes[field] ||
                obj.attributes[Query.format_field(field)] ||
                (obj.respond_to?(field) ? obj.send(field) : nil)

        # If it's a Parse pointer, try to resolve it
        if value.is_a?(Hash) && value["__type"] == "Pointer"
          resolve_parse_pointer(value)
        else
          value
        end
      elsif obj.is_a?(Hash)
        # Hash objects
        obj[field] || obj[field.to_sym] ||
        obj[Query.format_field(field)] || obj[Query.format_field(field).to_sym]
      else
        # Other objects
        obj.respond_to?(field) ? obj.send(field) : nil
      end
    end

    # Attempt to resolve a Parse pointer to the actual object.
    # @param pointer [Hash] Parse pointer hash
    # @return [Object] resolved object or pointer hash if resolution fails
    def resolve_parse_pointer(pointer)
      return pointer unless pointer["className"] && pointer["objectId"]

      begin
        # Resolve via the registered Parse::Object subclass map rather than
        # Object.const_get — never let a server-returned className trigger
        # autoload of arbitrary constants. find_class returns nil for unknown
        # names (no exception).
        model_class = Parse::Model.find_class(pointer["className"])
        if model_class && model_class.is_a?(Class) && model_class < Parse::Object
          resolved_obj = model_class.find(pointer["objectId"])
          return resolved_obj if resolved_obj
        end
      rescue Parse::Error
        # If we can't resolve, fall back to displaying pointer info
      end

      # Return pointer representation if resolution failed
      pointer
    end

    # Sort table data by specified column.
    # @param table_data [Hash] hash with :headers and :rows keys
    # @param sort_by [String, Symbol, Integer] column to sort by (name, index, or header text)
    # @param sort_order [Symbol] :asc or :desc
    def sort_table_data!(table_data, sort_by, sort_order)
      headers = table_data[:headers]
      rows = table_data[:rows]

      # Find the column index to sort by
      sort_index = case sort_by
        when Integer
          raise ArgumentError, "Column index #{sort_by} out of range" if sort_by < 0 || sort_by >= headers.size
          sort_by
        when String, Symbol
          # Try to find by header name first
          index = headers.find_index { |h| h.downcase == sort_by.to_s.downcase }

          # If not found by header, try by formatted field name
          if index.nil?
            formatted_sort_by = sort_by.to_s.gsub("_", " ").split.map(&:capitalize).join(" ")
            index = headers.find_index { |h| h.downcase == formatted_sort_by.downcase }
          end

          if index.nil?
            raise ArgumentError, "Column '#{sort_by}' not found. Available columns: #{headers.join(", ")}"
          end

          index
        else
          raise ArgumentError, "sort_by must be a column name, header text, or column index"
        end

      # Sort rows by the specified column
      sorted_rows = rows.sort do |a, b|
        val_a = a[sort_index]
        val_b = b[sort_index]

        # Handle different data types for comparison
        comparison = compare_table_values(val_a, val_b)
        sort_order == :desc ? -comparison : comparison
      end

      table_data[:rows] = sorted_rows
    end

    # Compare two values for table sorting.
    # @param a [Object] first value
    # @param b [Object] second value
    # @return [Integer] -1, 0, or 1 for comparison
    def compare_table_values(a, b)
      # Handle nil values
      return 0 if a.nil? && b.nil?
      return -1 if a.nil?
      return 1 if b.nil?

      # Convert to strings and try numeric comparison first
      a_str = a.to_s
      b_str = b.to_s

      # Try to parse as numbers for proper numeric sorting
      a_num = Float(a_str) rescue nil
      b_num = Float(b_str) rescue nil

      if a_num && b_num
        a_num <=> b_num
      else
        a_str.downcase <=> b_str.downcase
      end
    end

    # Format a value for table display.
    # @param value [Object] value to format
    # @return [String] formatted string
    def format_table_value(value)
      case value
      when nil
        "null"
      when String
        value.length > 50 ? "#{value[0..47]}..." : value
      when Parse::Pointer
        "#{value.parse_class}##{value.id}"
      when Hash
        if value["__type"] == "Pointer"
          "#{value["className"]}##{value["objectId"]}"
        else
          value.to_s.length > 50 ? "#{value.to_s[0..47]}..." : value.to_s
        end
      when Time, DateTime
        value.strftime("%Y-%m-%d %H:%M")
      when Numeric
        value.to_s
      when Array
        "[#{value.size} items]"
      else
        value.to_s.length > 50 ? "#{value.to_s[0..47]}..." : value.to_s
      end
    end

    # Format ASCII table.
    # @param data [Hash] table data with headers and rows
    # @return [String] formatted ASCII table
    def format_ascii_table(data)
      headers = data[:headers]
      rows = data[:rows]

      # Calculate column widths
      col_widths = headers.map.with_index do |header, i|
        max_width = [header.length, *rows.map { |row| row[i].to_s.length }].max
        [max_width, 3].max # Minimum width of 3
      end

      # Build table
      result = []

      # Top border
      result << "+" + col_widths.map { |w| "-" * (w + 2) }.join("+") + "+"

      # Headers
      header_row = "|" + headers.map.with_index { |h, i| " #{h.ljust(col_widths[i])} " }.join("|") + "|"
      result << header_row

      # Header separator
      result << "+" + col_widths.map { |w| "-" * (w + 2) }.join("+") + "+"

      # Rows
      rows.each do |row|
        row_str = "|" + row.map.with_index { |cell, i| " #{cell.to_s.ljust(col_widths[i])} " }.join("|") + "|"
        result << row_str
      end

      # Bottom border
      result << "+" + col_widths.map { |w| "-" * (w + 2) }.join("+") + "+"

      result.join("\n")
    end

    # Format CSV table.
    # @param data [Hash] table data with headers and rows
    # @return [String] CSV formatted string
    def format_csv_table(data)
      require "csv"

      csv_string = CSV.generate do |csv|
        csv << data[:headers]
        data[:rows].each { |row| csv << row }
      end

      csv_string
    end

    # Format JSON table.
    # @param data [Hash] table data with headers and rows
    # @return [String] JSON formatted string
    def format_json_table(data)
      headers = data[:headers]
      rows = data[:rows]

      table_objects = rows.map do |row|
        headers.zip(row).to_h
      end

      JSON.pretty_generate(table_objects)
    end

    # Format empty table for given format.
    # @param format [Symbol] output format
    # @return [String] empty table representation
    def format_empty_table(format)
      case format
      when :ascii
        "No results found."
      when :csv
        ""
      when :json
        "[]"
      end
    end

    # Execute distinct aggregation with object population at server level.
    # @param field [Symbol, String] the field name to get distinct values for.
    # @param return_pointers [Boolean] whether to return Parse::Pointer objects instead of full objects.
    # @return [Array] array of distinct values with populated objects or pointers.
    def execute_distinct_with_population(field, return_pointers: false)
      # First get the distinct pointer values using regular distinct
      distinct_values = distinct(field, return_pointers: true)

      # Filter out non-pointer values (e.g., nil, scalar values)
      pointer_values = distinct_values.select { |v| v.is_a?(Parse::Pointer) }

      if return_pointers
        # Return the pointers directly
        pointer_values
      else
        # Fetch the full objects for each distinct pointer
        return [] if pointer_values.empty?

        # Group pointers by class to fetch efficiently
        pointers_by_class = pointer_values.group_by(&:parse_class)

        objects = []
        pointers_by_class.each do |class_name, pointers|
          puts "Fetching #{pointers.size} objects for class #{class_name}" if @verbose_aggregate
          # Get the Parse class
          klass = Parse::Model.find_class(class_name)
          next unless klass

          # Fetch all objects for this class in one query
          object_ids = pointers.map(&:id)
          fetched = klass.all(:objectId.in => object_ids)
          objects.concat(fetched)
        end

        objects
      end
    end

    # Execute a basic aggregation pipeline and extract the result
    # @param pipeline [Array] the base pipeline stages (without $match)
    # @param operation [String] the operation name for debugging
    # @param field [Symbol, String] the field being aggregated
    # @param result_key [String] the key to extract from the result
    # @return [Object] the aggregation result
    def execute_basic_aggregation(pipeline, operation, field, result_key)
      # Add match stage if there are where conditions
      compiled_where = compile_where
      if compiled_where.present?
        # Convert field names for aggregation context and handle dates
        aggregation_where = convert_constraints_for_aggregation(compiled_where)
        stringified_where = convert_dates_for_aggregation(aggregation_where)
        pipeline.unshift({ "$match" => stringified_where })
      end

      # Use the Aggregation class to execute
      aggregation = aggregate(pipeline, verbose: @verbose_aggregate)
      raw_results = aggregation.raw

      # Extract the result from the response
      if raw_results.is_a?(Array) && raw_results.first
        raw_results.first[result_key]
      else
        nil  # Return nil for all operations when there are no results
      end
    end

    # Format field names for aggregation pipelines
    # @param field [Symbol, String] the field name to format
    # @return [String] the formatted field name
    def format_aggregation_field(field)
      case field.to_s
      when "created_at", "createdAt"
        "createdAt"  # Parse Server uses createdAt for aggregation
      when "updated_at", "updatedAt"
        "updatedAt"  # Parse Server uses updatedAt for aggregation
      else
        # If field already has _p_ prefix, it's already in aggregation format
        if field.to_s.start_with?("_p_")
          field.to_s
        else
          formatted = Query.format_field(field)
          # For pointer fields, MongoDB stores them with _p_ prefix
          # Check if this field is defined as a pointer in the Parse class
          parse_class = Parse::Model.const_get(@table) rescue nil
          if parse_class && is_pointer_field?(parse_class, field, formatted)
            "_p_#{formatted}"
          else
            formatted
          end
        end
      end
    end

    # Check if a field is a pointer field by looking at the Parse class definition
    # @param parse_class [Class] the Parse::Object subclass
    # @param field [Symbol, String] the original field name (e.g., :author_team)
    # @param formatted_field [String] the formatted field name (e.g., "authorTeam")
    # @return [Boolean] true if the field is a pointer field
    def is_pointer_field?(parse_class, field, formatted_field)
      return false unless parse_class.respond_to?(:fields)

      # Check both the original field name and the formatted field name
      fields_to_check = [field.to_s, field.to_sym, formatted_field.to_s, formatted_field.to_sym]

      fields_to_check.any? do |f|
        parse_class.fields[f] == :pointer
      end
    end

    # Get the target class name for a pointer field from the schema
    # @param parse_class [Class] the Parse::Object subclass
    # @param field [Symbol, String] the field name
    # @return [String, nil] the target class name or nil if not found
    def get_pointer_target_class_for(parse_class, field)
      return nil unless parse_class.respond_to?(:fields) && parse_class.respond_to?(:references)

      # Check both the original field name and formatted versions
      fields_to_check = [field.to_s, field.to_sym]
      formatted_field = Query.format_field(field)
      fields_to_check += [formatted_field.to_s, formatted_field.to_sym]

      fields_to_check.each do |f|
        # Check if it's a pointer field
        if parse_class.fields[f.to_sym] == :pointer
          # Get the target class from references
          target_class = parse_class.references[f.to_sym]
          return target_class if target_class
        end
      end

      nil
    end

    # Check if a field is a pointer field using schema information
    # @param field [Symbol, String] the field name to check
    # @return [Boolean] true if the field is a pointer field
    def field_is_pointer?(field)
      begin
        parse_class = Parse::Model.const_get(@table)
        return false unless parse_class.respond_to?(:fields)

        # If the field already has _p_ prefix, strip it to get the original field name
        original_field = field.to_s.start_with?("_p_") ? field.to_s[3..-1] : field

        # Check both the original field name and formatted versions
        fields_to_check = [original_field.to_s, original_field.to_sym]
        formatted_field = Query.format_field(original_field)
        fields_to_check += [formatted_field.to_s, formatted_field.to_sym]

        fields_to_check.each do |f|
          return true if parse_class.fields[f.to_sym] == :pointer
        end

        false
      rescue NameError
        # If the model class doesn't exist, fall back to checking the server schema
        fetch_and_check_server_schema(field)
      end
    end

    # Check server schema for pointer field information (fallback method)
    # @param field [Symbol, String] the field name to check
    # @return [Boolean] true if the field is a pointer field according to server schema
    def fetch_and_check_server_schema(field)
      # TODO: Implement actual server schema checking if needed
      # For now, return false as a safe fallback for tests
      false
    end

    # Detect if a field is likely a pointer field based on the values being used
    # @param value [Object] the constraint value to analyze
    # @return [Boolean] true if the values suggest this is a pointer field
    def detect_pointer_field_from_values(value)
      # Direct pointer object or hash
      return true if value.is_a?(Parse::Pointer)
      return true if value.is_a?(Hash) && value["__type"] == "Pointer"

      # Check nested operators (like $in, $ne, etc.)
      if value.is_a?(Hash)
        value.each do |op, op_value|
          if op_value.is_a?(Array)
            # Check if array contains pointer objects
            return true if op_value.any? { |v| v.is_a?(Parse::Pointer) || (v.is_a?(Hash) && v["__type"] == "Pointer") }
          elsif op_value.is_a?(Parse::Pointer) || (op_value.is_a?(Hash) && op_value["__type"] == "Pointer")
            return true
          end
        end
      end

      false
    end

    # Convert various pointer representations using schema information
    # @param value [Object] the value to potentially convert (String, Hash, Parse::Pointer)
    # @param field_name [Symbol, String] the field name for schema lookup
    # @param options [Hash] conversion options
    # @option options [Boolean] :return_pointers (false) whether to return Parse::Pointer objects
    # @option options [Boolean] :to_mongodb_format (false) whether to convert to "ClassName$objectId" format
    # @return [Object] converted value or original value if no conversion needed
    def convert_pointer_value_with_schema(value, field_name, **options)
      return value unless value # nil/empty values pass through

      parse_class = Parse::Model.const_get(@table) rescue nil
      is_pointer = parse_class && is_pointer_field?(parse_class, field_name, Query.format_field(field_name))
      target_class = parse_class ? get_pointer_target_class_for(parse_class, field_name) : nil

      case value
      when Parse::Pointer
        if options[:to_mongodb_format]
          "#{value.parse_class}$#{value.id}"
        elsif options[:return_pointers]
          value
        else
          value.id # Just return the object ID
        end
      when Hash
        if value["__type"] == "Pointer" && value["className"] && value["objectId"]
          if options[:to_mongodb_format]
            "#{value["className"]}$#{value["objectId"]}"
          elsif options[:return_pointers]
            Parse::Pointer.new(value["className"], value["objectId"])
          else
            value["objectId"] # Just return the object ID
          end
        else
          value # Not a pointer hash
        end
      when String
        # Handle MongoDB format strings ("ClassName$objectId") first - regardless of schema
        if value.include?("$") && value.match(/^[A-Za-z_]\w*\$\w+$/)
          class_name, object_id = value.split("$", 2)

          # Validate that the class_name is a known Parse class
          is_valid_class = self.class.known_parse_classes.include?(class_name) ||
                           begin
                             # Only do expensive lookup if not in known set
                             Parse::Model.find_class(class_name) ||
                             class_name.constantize.ancestors.include?(Parse::Object)
                           rescue NameError, TypeError
                             false
                           end

          if is_valid_class
            if options[:to_mongodb_format]
              value # Already in MongoDB format
            elsif options[:return_pointers]
              Parse::Pointer.new(class_name, object_id)
            else
              object_id # Just return the object ID
            end
          else
            # Not a valid Parse class, treat as regular string
            value
          end
        elsif is_pointer && target_class
          # Plain object ID with known target class from schema
          if options[:to_mongodb_format]
            "#{target_class}$#{value}"
          elsif options[:return_pointers]
            Parse::Pointer.new(target_class, value)
          else
            value # Already just an object ID
          end
        else
          value # Not recognizable as pointer or not a pointer field
        end
      else
        value # Unknown type, pass through
      end
    end

    # Convert constraint field names to aggregation format (e.g., authorTeam -> _p_authorTeam for pointers)
    # @param constraints [Hash] the constraints hash to convert
    # @return [Hash] the converted constraints with aggregation-compatible field names
    def convert_constraints_for_aggregation(constraints)
      return constraints unless constraints.is_a?(Hash)

      result = {}
      constraints.each do |field, value|
        # Skip special Parse operators
        if field.to_s.start_with?("$")
          result[field] = value
          next
        end

        # Convert field name to aggregation format
        # If field already has _p_ prefix, don't reformat it
        if field.to_s.start_with?("_p_")
          aggregation_field = field.to_s
        else
          # Check if we can detect this is a pointer field from the values
          is_pointer_from_values = detect_pointer_field_from_values(value)
          if is_pointer_from_values
            formatted = Query.format_field(field)
            aggregation_field = "_p_#{formatted}"
          else
            aggregation_field = format_aggregation_field(field)
          end
        end

        # Convert pointer values to MongoDB format (ClassName$objectId)
        if value.is_a?(Hash) && value["__type"] == "Pointer"
          result[aggregation_field] = "#{value["className"]}$#{value["objectId"]}"
          # Handle Parse::Pointer objects
        elsif value.is_a?(Parse::Pointer)
          result[aggregation_field] = "#{value.parse_class}$#{value.id}"
          # Handle nested constraint operators (like $in, $ne, etc.)
        elsif value.is_a?(Hash)
          converted_value = {}
          value.each do |op, op_value|
            if op_value.is_a?(Hash) && op_value["__type"] == "Pointer"
              converted_value[op] = "#{op_value["className"]}$#{op_value["objectId"]}"
            elsif op_value.is_a?(Parse::Pointer)
              converted_value[op] = "#{op_value.parse_class}$#{op_value.id}"
            elsif op_value.is_a?(Array) && (op.to_s == "$in" || op.to_s == "$nin")
              # Handle arrays of pointers for $in and $nin operators
              # Check if the original field is a pointer field using schema or values
              is_pointer_field = field_is_pointer?(field) || detect_pointer_field_from_values(value)

              converted_value[op] = op_value.map do |item|
                if item.is_a?(Hash) && item["__type"] == "Pointer"
                  "#{item["className"]}$#{item["objectId"]}"
                elsif item.is_a?(Parse::Pointer)
                  "#{item.parse_class}$#{item.id}"
                elsif is_pointer_field && item.is_a?(String)
                  # For pointer fields with string IDs, try to get the class name from:
                  # 1. The schema definition (most reliable)
                  # 2. Other Parse::Pointer objects in the same array
                  # 3. Other pointer hash objects in the same array
                  class_name = nil

                  # First try to get it from the schema
                  parse_class = Parse::Model.const_get(@table) rescue nil
                  if parse_class
                    class_name = get_pointer_target_class_for(parse_class, field)
                  end

                  # If not found in schema, try to infer from other items in the array
                  if class_name.nil?
                    op_value.each do |v|
                      if v.is_a?(Parse::Pointer)
                        class_name = v.parse_class
                        break
                      elsif v.is_a?(Hash) && v["__type"] == "Pointer"
                        class_name = v["className"]
                        break
                      end
                    end
                  end

                  if class_name
                    "#{class_name}$#{item}"
                  else
                    # Can't determine class name - leave string as-is
                    item
                  end
                else
                  item
                end
              end
            else
              converted_value[op] = op_value
            end
          end
          result[aggregation_field] = converted_value
        else
          result[aggregation_field] = value
        end
      end

      result
    end

    # Convert Ruby Date/Time objects for aggregation pipelines to raw ISO strings.
    # Parse Server expects dates in raw ISO string format in aggregation pipelines, not the Parse Date object format.
    # @param obj [Object] the object to convert (Hash, Array, or value)
    # @return [Object] the converted object with dates converted to raw ISO strings
    def convert_dates_for_aggregation(obj)
      case obj
      when Hash
        # Handle Parse's JSON date format: {"__type": "Date", "iso": "..."} or {:__type => "Date", :iso => "..."}
        if (obj["__type"] == "Date" || obj[:__type] == "Date") && (obj["iso"] || obj[:iso])
          # Convert Parse Date format to raw ISO string
          obj["iso"] || obj[:iso]
        else
          # Recursively convert nested hashes
          converted_hash = {}
          obj.each do |key, value|
            converted_hash[key] = convert_dates_for_aggregation(value)
          end
          converted_hash
        end
      when Array
        obj.map { |v| convert_dates_for_aggregation(v) }
      when Time, DateTime
        # Convert Ruby Time/DateTime objects to raw ISO string
        obj.utc.iso8601(3)
      when Date
        # Convert Ruby Date objects to raw ISO string
        obj.to_time.utc.iso8601(3)
      else
        obj
      end
    end

    # Combines multiple queries with OR logic using full pipeline approach
    # Each query's complete constraint set becomes one branch of the OR condition
    # @param queries [Array<Parse::Query>] the queries to combine with OR logic
    # @return [Parse::Query] a new query with OR constraints
    # @raise [ArgumentError] if the queries don't all target the same Parse class
    def self.or(*queries)
      queries = queries.flatten.compact
      return nil if queries.empty?

      # Get the table from the first query
      table = queries.first.table

      # Ensure all queries are for the same table
      unless queries.all? { |q| q.table == table }
        raise ArgumentError, "All queries passed to Parse::Query.or must be for the same Parse class."
      end

      # Start with an empty query for this table
      result = self.new(table)

      # Filter to only queries that have constraints
      queries = queries.filter { |q| q.where.present? && !q.where.empty? }

      # Add each query's complete constraint set as an OR branch
      queries.each do |query|
        # Compile the where constraints to check if they result in empty conditions
        compiled_where = Parse::Query.compile_where(query.where)
        unless compiled_where.empty?
          result.or_where(query.where)
        end
      end

      result
    end

    # Combines multiple queries with AND logic using full pipeline approach
    # Each query's complete constraint set is ANDed together
    # @param queries [Array<Parse::Query>] the queries to combine with AND logic
    # @return [Parse::Query] a new query with AND constraints
    # @raise [ArgumentError] if the queries don't all target the same Parse class
    def self.and(*queries)
      queries = queries.flatten.compact
      return nil if queries.empty?

      # Get the table from the first query
      table = queries.first.table

      # Ensure all queries are for the same table
      unless queries.all? { |q| q.table == table }
        raise ArgumentError, "All queries passed to Parse::Query.and must be for the same Parse class."
      end

      # Start with an empty query for this table
      result = self.new(table)

      # Filter to only queries that have constraints
      queries = queries.filter { |q| q.where.present? && !q.where.empty? }

      # Add each query's complete constraint set with AND logic
      # Multiple constraints in a query are implicitly ANDed together by Parse
      queries.each do |query|
        # Compile the where constraints to check if they result in empty conditions
        compiled_where = Parse::Query.compile_where(query.where)
        unless compiled_where.empty?
          # Directly append constraints to result's where array
          # (where method only accepts Hash, but query.where returns Array<Constraint>)
          result.instance_variable_get(:@where).concat(query.where)
        end
      end

      result
    end

    public

    # Creates a deep copy of this query object, allowing independent modifications
    # @return [Parse::Query] a new query object with the same constraints
    # @note The @client and @results instance variables are intentionally NOT cloned.
    #   The cloned query will use the default client when executed.
    def clone
      cloned_query = Parse::Query.new(self.instance_variable_get(:@table))
      # Note: :client is intentionally excluded - it contains non-serializable objects
      # (Redis connections, Faraday connections) and should be obtained lazily
      [:count, :where, :order, :keys, :includes, :limit, :skip, :cache, :use_master_key].each do |param|
        if instance_variable_defined?(:"@#{param}")
          value = instance_variable_get(:"@#{param}")
          if value.is_a?(Array) || value.is_a?(Hash)
            # Use Marshal for deep copy of complex constraint objects
            begin
              cloned_value = Marshal.load(Marshal.dump(value))
            rescue => e
              # Fallback to shallow copy if Marshal fails
              puts "[Parse::Query.clone] Marshal failed for #{param}: #{e.message}, falling back to dup"
              cloned_value = value.dup
            end
          else
            cloned_value = value
          end
          cloned_query.instance_variable_set(:"@#{param}", cloned_value)
        end
      end
      cloned_query.instance_variable_set(:@results, nil)
      cloned_query
    end

    # Filter by ACL read permissions using exact permission strings.
    # Strings are used as-is (user IDs or "role:RoleName" format).
    # Use "public" for public access, "none" or [] for no read permissions.
    #
    # @param permission [Parse::User, Parse::Role, String, Array] the permission to check
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query. If nil (default),
    #   auto-detects based on query complexity. Set to false to force Parse Server aggregation.
    # @return [Parse::Query] returns self for method chaining
    # @note This uses MongoDB aggregation pipeline because Parse Server restricts
    #   direct queries on internal ACL fields (_rperm/_wperm).
    # @example
    #   Song.query.readable_by("user123")           # Objects readable by user ID
    #   Song.query.readable_by("role:Admin")        # Objects readable by Admin role
    #   Song.query.readable_by(current_user)        # Objects readable by user object
    #   Song.query.readable_by("public")            # Publicly readable objects
    #   Song.query.readable_by("none")              # Objects with no read permissions
    #   Song.query.readable_by([])                  # Objects with no read permissions (empty ACL)
    #   Song.query.readable_by([], mongo_direct: true)  # Force MongoDB direct query
    def readable_by(permission, mongo_direct: nil)
      @acl_query_mongo_direct = mongo_direct unless mongo_direct.nil?
      where(:ACL.readable_by => permission)
      self
    end

    # Filter by ACL read permissions using role names (adds "role:" prefix).
    #
    # @param role_name [Parse::Role, String, Array] the role name(s) to check
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.readable_by_role("Admin")              # Objects readable by Admin role
    #   Song.query.readable_by_role(["Admin", "Editor"])  # Objects readable by Admin or Editor
    #   Song.query.readable_by_role(admin_role)           # Objects readable by Role object
    def readable_by_role(role_name, mongo_direct: nil)
      @acl_query_mongo_direct = mongo_direct unless mongo_direct.nil?
      where(:ACL.readable_by_role => role_name)
      self
    end

    # Filter by ACL write permissions using exact permission strings.
    # Strings are used as-is (user IDs or "role:RoleName" format).
    # Use "public" for public access, "none" or [] for no write permissions.
    #
    # @param permission [Parse::User, Parse::Role, String, Array] the permission to check
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query. If nil (default),
    #   auto-detects based on query complexity. Set to false to force Parse Server aggregation.
    # @return [Parse::Query] returns self for method chaining
    # @note This uses MongoDB aggregation pipeline because Parse Server restricts
    #   direct queries on internal ACL fields (_rperm/_wperm).
    # @example
    #   Song.query.writable_by("user123")           # Objects writable by user ID
    #   Song.query.writable_by("role:Admin")        # Objects writable by Admin role
    #   Song.query.writable_by(current_user)        # Objects writable by user object
    #   Song.query.writable_by("public")            # Publicly writable objects
    #   Song.query.writable_by("none")              # Objects with no write permissions
    #   Song.query.writable_by([])                  # Objects with no write permissions (empty ACL)
    #   Song.query.writable_by([], mongo_direct: true)  # Force MongoDB direct query
    def writable_by(permission, mongo_direct: nil)
      @acl_query_mongo_direct = mongo_direct unless mongo_direct.nil?
      where(:ACL.writable_by => permission)
      self
    end

    # Filter by ACL write permissions using role names (adds "role:" prefix).
    #
    # @param role_name [Parse::Role, String, Array] the role name(s) to check
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.writable_by_role("Admin")              # Objects writable by Admin role
    #   Song.query.writable_by_role(["Admin", "Editor"])  # Objects writable by Admin or Editor
    #   Song.query.writable_by_role(admin_role)           # Objects writable by Role object
    def writable_by_role(role_name, mongo_direct: nil)
      @acl_query_mongo_direct = mongo_direct unless mongo_direct.nil?
      where(:ACL.writable_by_role => role_name)
      self
    end

    # ============================================================
    # ACL Convenience Query Methods
    # ============================================================

    # Find objects that are publicly readable (anyone can read).
    # Matches objects where _rperm contains "*".
    #
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.publicly_readable.results
    #   Song.query.publicly_readable.where(genre: "Rock").results
    def publicly_readable(mongo_direct: nil)
      readable_by("*", mongo_direct: mongo_direct)
    end

    # Find objects that are publicly writable (anyone can write).
    # Matches objects where _wperm contains "*".
    # Useful for security audits to find potentially insecure objects.
    #
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.publicly_writable.results  # Security audit!
    def publicly_writable(mongo_direct: nil)
      writable_by("*", mongo_direct: mongo_direct)
    end

    # Find objects with no read permissions (master key only).
    # Matches objects where _rperm is empty or doesn't exist.
    #
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.privately_readable.results
    #   Song.query.master_key_read_only.results  # Alias
    def privately_readable(mongo_direct: nil)
      readable_by("none", mongo_direct: mongo_direct)
    end

    alias_method :master_key_read_only, :privately_readable

    # Find objects with no write permissions (master key only).
    # Matches objects where _wperm is empty or doesn't exist.
    #
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.privately_writable.results
    #   Song.query.master_key_write_only.results  # Alias
    def privately_writable(mongo_direct: nil)
      writable_by("none", mongo_direct: mongo_direct)
    end

    alias_method :master_key_write_only, :privately_writable

    # Find objects with completely private ACL (no read AND no write permissions).
    # Only accessible with master key.
    #
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.private_acl.results
    #   Song.query.master_key_only.results  # Alias
    def private_acl(mongo_direct: nil)
      privately_readable(mongo_direct: mongo_direct)
      privately_writable(mongo_direct: mongo_direct)
    end

    alias_method :master_key_only, :private_acl

    # Find objects that are NOT publicly readable.
    # Matches objects where _rperm does NOT contain "*".
    #
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.not_publicly_readable.results
    def not_publicly_readable(mongo_direct: nil)
      @acl_query_mongo_direct = mongo_direct unless mongo_direct.nil?
      where(:ACL.not_readable_by => "*")
      self
    end

    # Find objects that are NOT publicly writable.
    # Matches objects where _wperm does NOT contain "*".
    #
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.not_publicly_writable.results
    def not_publicly_writable(mongo_direct: nil)
      @acl_query_mongo_direct = mongo_direct unless mongo_direct.nil?
      where(:ACL.not_writable_by => "*")
      self
    end
  end # Query

  # Wrapper class for custom aggregation results (from $group, $project, etc.)
  # Provides both hash-style access and method-style access to fields.
  # Field names are automatically converted from camelCase to snake_case.
  #
  # @example
  #   result = AggregationResult.new({ "_id" => "Rock", "totalPlays" => 500 })
  #   result["_id"]        # => "Rock"
  #   result[:total_plays] # => 500
  #   result.total_plays   # => 500
  #
  class AggregationResult
    # @param data [Hash] the raw aggregation result hash
    def initialize(data)
      @data = {}
      @raw_data = data

      # Convert keys to snake_case and store
      data.each do |key, value|
        snake_key = Parse::Query.to_snake_case(key.to_s)
        @data[snake_key.to_sym] = value
        @data[key.to_s] = value  # Also keep original key for hash access
      end
    end

    # Hash-style access with string or symbol keys
    # @param key [String, Symbol] the field name
    # @return [Object] the field value
    def [](key)
      @data[key.to_s] || @data[key.to_sym]
    end

    # Check if a key exists
    # @param key [String, Symbol] the field name
    # @return [Boolean]
    def key?(key)
      @data.key?(key.to_s) || @data.key?(key.to_sym)
    end

    # Get all keys (snake_case symbols)
    # @return [Array<Symbol>]
    def keys
      @data.keys.select { |k| k.is_a?(Symbol) }
    end

    # Convert to hash with snake_case symbol keys
    # @return [Hash]
    def to_h
      @data.select { |k, _| k.is_a?(Symbol) }
    end

    # Convert to hash (alias)
    alias_method :to_hash, :to_h

    # Get the raw data as originally received
    # @return [Hash]
    def raw
      @raw_data
    end

    # Method-style access to fields
    def method_missing(method_name, *args, &block)
      key = method_name.to_sym
      if @data.key?(key)
        @data[key]
      else
        super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      @data.key?(method_name.to_sym) || super
    end

    def inspect
      "#<Parse::AggregationResult #{to_h.inspect}>"
    end
  end

  # Helper class for executing arbitrary MongoDB aggregation pipelines.
  # Provides a consistent interface with results, raw, and result_pointers methods.
  class Aggregation
    # @param query [Parse::Query] the base query object
    # @param pipeline [Array<Hash>] the MongoDB aggregation pipeline stages
    # @param verbose [Boolean, nil] whether to print verbose output (nil means use query's setting)
    # @param mongo_direct [Boolean] if true, uses MongoDB directly bypassing Parse Server (required for $literal)
    def initialize(query, pipeline, verbose: nil, mongo_direct: false)
      @query = query
      @pipeline = pipeline
      @cached_response = nil
      @mongo_direct = mongo_direct
      # Use provided verbose setting, or fall back to query's verbose_aggregate setting
      @verbose = verbose.nil? ? @query.instance_variable_get(:@verbose_aggregate) : verbose
    end

    # Execute the aggregation pipeline and cache the response
    # @return [Parse::Response, Array] the aggregation response or raw results for mongo_direct
    def execute!
      return @cached_response if @cached_response

      if @verbose
        puts "[VERBOSE AGGREGATE] Custom aggregation pipeline:"
        puts JSON.pretty_generate(@pipeline)
        puts "[VERBOSE AGGREGATE] Sending to: #{@query.instance_variable_get(:@table)}"
        puts "[VERBOSE AGGREGATE] Using MongoDB direct: #{@mongo_direct}"
      end

      if @mongo_direct && defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
        @cached_response = execute_direct!
      else
        @cached_response = @query.client.aggregate_pipeline(
          @query.instance_variable_get(:@table),
          @pipeline,
          headers: {},
          **@query.send(:_opts),
        )
      end

      if @verbose
        if @mongo_direct && defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
          puts "[VERBOSE AGGREGATE] Response result count: #{@cached_response&.count}"
        else
          puts "[VERBOSE AGGREGATE] Response success?: #{@cached_response.success?}"
          puts "[VERBOSE AGGREGATE] Response result count: #{@cached_response.result&.count}"
        end
      end

      @cached_response
    end

    # Execute aggregation directly on MongoDB
    # @return [Array<Hash>] raw MongoDB results
    def execute_direct!
      table = @query.instance_variable_get(:@table)
      Parse::MongoDB.aggregate(table, @pipeline)
    end

    # Returns processed results from the aggregation.
    # - Standard Parse documents (with objectId) are returned as Parse::Object instances
    # - Custom aggregation results (from $group, $project, etc.) are returned as
    #   AggregationResult objects that support both hash access and method access
    #
    # @yield a block to iterate for each object in the result
    # @return [Array<Parse::Object, AggregationResult>] array of results
    def results(&block)
      response = execute!

      if @mongo_direct && defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
        # For MongoDB direct, convert raw results to Parse objects or AggregationResult
        return [] if response.nil? || response.empty?
        converted = Parse::MongoDB.convert_documents_to_parse(response, @query.instance_variable_get(:@table))
        items = converted.map { |item| convert_aggregation_item(item) }
      else
        return [] if response.error?
        items = response.result.map { |item| convert_aggregation_item(item) }
      end

      return items.each(&block) if block_given?
      items
    end

    private

    # Convert an aggregation result item to the appropriate type
    # @param item [Hash] the aggregation result hash
    # @return [Parse::Object, AggregationResult] Parse object for documents, AggregationResult for custom results
    def convert_aggregation_item(item)
      if looks_like_parse_document?(item)
        @query.send(:decode, [item]).first
      else
        AggregationResult.new(item)
      end
    end

    # Check if a hash looks like a standard Parse document
    # @param hash [Hash] the hash to check
    # @return [Boolean] true if it has a non-nil objectId field
    def looks_like_parse_document?(hash)
      id = hash["objectId"] || hash[:objectId]
      !id.nil? && id != ""
    end

    public

    # Alias for results
    alias_method :all, :results

    # Returns raw unprocessed results from the aggregation
    # @yield a block to iterate for each raw object in the result
    # @return [Array<Hash>] raw Parse JSON hash results
    def raw(&block)
      response = execute!
      return [] if response.respond_to?(:error?) && response.error?

      items = response.respond_to?(:result) ? response.result : response
      items = [] unless items.is_a?(Array)
      return items.each(&block) if block_given?
      items
    end

    # Returns only pointer objects for all matching results
    # @yield a block to iterate for each pointer object in the result
    # @return [Array<Parse::Pointer>] array of Parse::Pointer objects
    def result_pointers(&block)
      response = execute!

      if @mongo_direct && defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
        return [] if response.nil? || response.empty?
        # Convert MongoDB results to Parse format first
        converted = Parse::MongoDB.convert_documents_to_parse(response, @query.instance_variable_get(:@table))
        items = @query.send(:to_pointers, converted)
      else
        return [] if response.error?
        items = @query.send(:to_pointers, response.result)
      end

      return items.each(&block) if block_given?
      items
    end

    # Alias for result_pointers
    alias_method :results_pointers, :result_pointers

    # Returns the first result from the aggregation
    # @param limit [Integer] number of results to return
    # @return [Parse::Object, Array<Parse::Object>] the first object(s)
    def first(limit = 1)
      items = results.first(limit)
      limit == 1 ? items.first : items
    end

    # Returns the count of results
    # @return [Integer] the number of results
    def count
      response = execute!
      if @mongo_direct && defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
        response.nil? ? 0 : response.count
      else
        response.error? ? 0 : response.result.count
      end
    end

    # Check if there are any results
    # @return [Boolean] true if there are results
    def any?
      count > 0
    end

    # Check if there are no results
    # @return [Boolean] true if there are no results
    def empty?
      count == 0
    end

    # Add additional pipeline stages
    # @param stages [Array<Hash>] additional pipeline stages to append
    # @return [Aggregation] self for chaining
    def add_stages(*stages)
      @pipeline.concat(stages.flatten)
      @cached_response = nil # Clear cache when pipeline changes
      self
    end

    # Create a new Aggregation with additional stages (non-mutating)
    # @param stages [Array<Hash>] additional pipeline stages to append
    # @return [Aggregation] new aggregation object with combined pipeline
    def with_stages(*stages)
      Aggregation.new(@query, @pipeline + stages.flatten, verbose: @verbose)
    end
  end

  # Helper class for handling group_by aggregations with method chaining.
  # Supports count, sum, average, min, max operations on grouped data.
  # Can optionally flatten array fields before grouping to count individual array elements.
  class GroupBy
    # @param query [Parse::Query] the base query to group
    # @param group_field [Symbol, String] the field to group by
    # @param flatten_arrays [Boolean] whether to flatten array fields before grouping
    # @param return_pointers [Boolean] whether to return Parse::Pointer objects for pointer values
    # @param mongo_direct [Boolean] whether to query MongoDB directly bypassing Parse Server
    def initialize(query, group_field, flatten_arrays: false, return_pointers: false, mongo_direct: false)
      @query = query
      @group_field = group_field
      @flatten_arrays = flatten_arrays
      @return_pointers = return_pointers
      @mongo_direct = mongo_direct
    end

    # Returns the MongoDB aggregation pipeline that would be used for a count operation.
    # This is useful for debugging and understanding the generated pipeline.
    # @return [Array<Hash>] the MongoDB aggregation pipeline
    # @example
    #   Capture.where(:author_team.eq => team).group_by(:last_action).pipeline
    #   # => [{"$match"=>{"authorTeam"=>"Team$abc123"}}, {"$group"=>{"_id"=>"$lastAction", "count"=>{"$sum"=>1}}}, {"$project"=>{"_id"=>0, "objectId"=>"$_id", "count"=>1}}]
    def pipeline
      # Format the group field name
      formatted_group_field = @query.send(:format_aggregation_field, @group_field)

      # Build the aggregation pipeline (same logic as execute_group_aggregation)
      pipeline = []

      # Add match stage if there are where conditions
      compiled_where = @query.send(:compile_where)
      if compiled_where.present?
        # Collect all match conditions to merge into a single $match stage
        match_conditions = []
        non_match_stages = []

        # Extract regular constraints (everything except __aggregation_pipeline)
        regular_constraints = compiled_where.reject { |k, _| k == "__aggregation_pipeline" }
        if regular_constraints.present?
          aggregation_where = @query.send(:convert_constraints_for_aggregation, regular_constraints)
          stringified_where = @query.send(:convert_dates_for_aggregation, aggregation_where)
          match_conditions << stringified_where
        end

        # Extract aggregation pipeline stages and merge $match stages
        if compiled_where.key?("__aggregation_pipeline")
          compiled_where["__aggregation_pipeline"].each do |stage|
            if stage.is_a?(Hash) && stage.key?("$match")
              # Extract the $match condition for merging
              match_conditions << stage["$match"]
            else
              # Non-$match stages go directly to pipeline
              non_match_stages << stage
            end
          end
        end

        # Combine all match conditions into a single $match stage
        if match_conditions.any?
          if match_conditions.length == 1
            pipeline << { "$match" => match_conditions.first }
          else
            # Use $and to combine multiple match conditions
            pipeline << { "$match" => { "$and" => match_conditions } }
          end
        end

        # Add any non-$match stages from the aggregation pipeline
        pipeline.concat(non_match_stages)
      end

      # Add unwind stage if flatten_arrays is enabled
      if @flatten_arrays
        pipeline << { "$unwind" => "$#{formatted_group_field}" }
      end

      # Add group and project stages (using count as example aggregation)
      pipeline.concat([
        {
          "$group" => {
            "_id" => "$#{formatted_group_field}",
            "count" => { "$sum" => 1 },
          },
        },
        {
          "$project" => {
            "_id" => 0,
            "objectId" => "$_id",
            "count" => 1,
          },
        },
      ])

      pipeline
    end

    # Returns raw unprocessed aggregation results
    # @param operation [String] the aggregation operation
    # @param aggregation_expr [Hash] the MongoDB aggregation expression
    # @return [Array<Hash>] raw aggregation results
    def raw(operation, aggregation_expr)
      formatted_group_field = @query.send(:format_aggregation_field, @group_field)
      pipeline = build_pipeline(formatted_group_field, aggregation_expr)

      response = @query.client.aggregate_pipeline(
        @query.instance_variable_get(:@table),
        pipeline,
        headers: {},
        **@query.send(:_opts),
      )

      response.result || []
    end

    # Count the number of items in each group.
    # @return [Hash] a hash with group values as keys and counts as values.
    # @example
    #   Asset.group_by(:category).count
    #   # => {"image" => 45, "video" => 23, "audio" => 12}
    def count
      execute_group_aggregation("count", { "$sum" => 1 })
    end

    # Sum a field for each group.
    # @param field [Symbol, String] the field to sum within each group.
    # @return [Hash] a hash with group values as keys and sums as values.
    # @example
    #   Asset.group_by(:project).sum(:file_size)
    #   # => {"Project1" => 1024000, "Project2" => 512000}
    def sum(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `sum`."
      end

      formatted_field = @query.send(:format_aggregation_field, field)
      execute_group_aggregation("sum", { "$sum" => "$#{formatted_field}" })
    end

    # Calculate average of a field for each group.
    # @param field [Symbol, String] the field to average within each group.
    # @return [Hash] a hash with group values as keys and averages as values.
    # @example
    #   Asset.group_by(:category).average(:duration)
    #   # => {"video" => 120.5, "audio" => 45.2}
    def average(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `average`."
      end

      formatted_field = @query.send(:format_aggregation_field, field)
      execute_group_aggregation("average", { "$avg" => "$#{formatted_field}" })
    end

    alias_method :avg, :average

    # Find minimum value of a field for each group.
    # @param field [Symbol, String] the field to find minimum for within each group.
    # @return [Hash] a hash with group values as keys and minimum values as values.
    def min(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `min`."
      end

      formatted_field = @query.send(:format_aggregation_field, field)
      execute_group_aggregation("min", { "$min" => "$#{formatted_field}" })
    end

    # Find maximum value of a field for each group.
    # @param field [Symbol, String] the field to find maximum for within each group.
    # @return [Hash] a hash with group values as keys and maximum values as values.
    def max(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `max`."
      end

      formatted_field = @query.send(:format_aggregation_field, field)
      execute_group_aggregation("max", { "$max" => "$#{formatted_field}" })
    end

    private

    # Execute a group aggregation operation.
    # @param operation [String] the operation name for debugging.
    # @param aggregation_expr [Hash] the MongoDB aggregation expression.
    # @return [Hash] the grouped results.
    def execute_group_aggregation(operation, aggregation_expr)
      # Format the group field name
      formatted_group_field = @query.send(:format_aggregation_field, @group_field)

      # Use direct MongoDB if enabled
      if @mongo_direct
        return execute_group_aggregation_direct(operation, aggregation_expr, formatted_group_field)
      end

      # Build the aggregation pipeline
      # Note: We don't add $match stage here because @query.aggregate() will automatically
      # add match stages from the query's where conditions
      pipeline = []

      # Add unwind stage if flatten_arrays is enabled
      if @flatten_arrays
        pipeline << { "$unwind" => "$#{formatted_group_field}" }
      end

      # Add group and project stages
      pipeline.concat([
        {
          "$group" => {
            "_id" => "$#{formatted_group_field}",
            "count" => aggregation_expr,
          },
        },
        {
          "$project" => {
            "_id" => 0,
            "objectId" => "$_id",
            "count" => 1,
          },
        },
      ])

      # Use the Aggregation class to execute
      aggregation = @query.aggregate(pipeline, verbose: @query.instance_variable_get(:@verbose_aggregate))
      raw_results = aggregation.raw

      # Convert array of results to hash
      if raw_results.is_a?(Array)
        result_hash = {}
        raw_results.each do |item|
          # Parse Server returns group key as "objectId" with $project stage
          key = item["objectId"]
          value = item["count"]

          # Handle null/nil group keys
          if key.nil?
            key = "null"
          elsif @return_pointers && key.is_a?(Hash)
            # Convert Parse pointer objects to Parse::Pointer instances
            if key["__type"] == "Pointer" && key["className"] && key["objectId"]
              key = Parse::Pointer.new(key["className"], key["objectId"])
            elsif key["objectId"] && key["className"]
              # Handle full Parse objects as pointers
              key = Parse::Pointer.new(key["className"], key["objectId"])
            end
          end

          result_hash[key] = value
        end
        result_hash
      else
        {}
      end
    end

    # Execute a group aggregation operation directly on MongoDB.
    # @param operation [String] the operation name for debugging.
    # @param aggregation_expr [Hash] the MongoDB aggregation expression.
    # @param formatted_group_field [String] the formatted group field name.
    # @return [Hash] the grouped results.
    def execute_group_aggregation_direct(operation, aggregation_expr, formatted_group_field)
      require_relative "mongodb"
      Parse::MongoDB.require_gem!

      unless Parse::MongoDB.available?
        raise Parse::MongoDB::NotEnabled,
          "Direct MongoDB queries are not enabled. " \
          "Call Parse::MongoDB.configure(uri: 'mongodb://...', enabled: true) first."
      end

      # Convert field name for direct MongoDB access
      mongo_group_field = @query.send(:convert_field_for_direct_mongodb, formatted_group_field)

      # Build the pipeline with match constraints
      pipeline = []

      # Add match stage from query constraints
      compiled_where = @query.send(:compile_where)
      if compiled_where.present?
        regular_constraints = compiled_where.reject { |f, _| f == "__aggregation_pipeline" }
        if regular_constraints.any?
          mongo_constraints = @query.send(:convert_constraints_for_direct_mongodb, regular_constraints)
          pipeline << { "$match" => mongo_constraints }
        end
      end

      # Add unwind stage if flatten_arrays is enabled
      if @flatten_arrays
        pipeline << { "$unwind" => "$#{mongo_group_field}" }
      end

      # Convert aggregation expression field references for direct MongoDB
      converted_expr = convert_aggregation_expr_for_direct(aggregation_expr)

      # Add group and project stages
      pipeline.concat([
        {
          "$group" => {
            "_id" => "$#{mongo_group_field}",
            "count" => converted_expr,
          },
        },
        {
          "$project" => {
            "_id" => 0,
            "value" => "$_id",
            "count" => 1,
          },
        },
      ])

      # Execute directly on MongoDB
      raw_results = Parse::MongoDB.aggregate(@query.instance_variable_get(:@table), pipeline)

      # Convert array of results to hash
      result_hash = {}
      raw_results.each do |item|
        key = item["value"]
        value = item["count"]

        # Handle null/nil group keys
        if key.nil?
          key = "null"
        elsif @return_pointers && key.is_a?(String) && key.include?("$")
          # Convert MongoDB pointer format to Parse::Pointer
          class_name, object_id = key.split("$", 2)
          key = Parse::Pointer.new(class_name, object_id)
        end

        result_hash[key] = value
      end
      result_hash
    end

    # Convert aggregation expression field references for direct MongoDB.
    # @param expr [Hash] the aggregation expression
    # @return [Hash] the converted expression
    def convert_aggregation_expr_for_direct(expr)
      return expr unless expr.is_a?(Hash)

      result = {}
      expr.each do |op, value|
        if value.is_a?(String) && value.start_with?("$")
          # Field reference - convert field name
          field = value[1..-1]
          result[op] = "$#{@query.send(:convert_field_for_direct_mongodb, field)}"
        else
          result[op] = value
        end
      end
      result
    end
  end

  # Wrapper class for grouped results that provides sorting capabilities.
  # Allows sorting grouped results by keys (group names) or values (aggregation results)
  # in ascending or descending order.
  class GroupedResult
    include Enumerable

    # @param results [Hash] the grouped results hash
    def initialize(results)
      @results = results
    end

    # Return the raw hash results
    # @return [Hash] the grouped results
    def to_h
      @results
    end

    # Iterate over each key-value pair
    def each(&block)
      @results.each(&block)
    end

    # Sort by keys (group names) in ascending order
    # @return [Array<Array>] array of [key, value] pairs sorted by key ascending
    def sort_by_key_asc
      @results.sort_by { |k, v| k }
    end

    # Sort by keys (group names) in descending order
    # @return [Array<Array>] array of [key, value] pairs sorted by key descending
    def sort_by_key_desc
      @results.sort_by { |k, v| k }.reverse
    end

    # Sort by values (aggregation results) in ascending order
    # @return [Array<Array>] array of [key, value] pairs sorted by value ascending
    def sort_by_value_asc
      @results.sort_by { |k, v| v }
    end

    # Sort by values (aggregation results) in descending order
    # @return [Array<Array>] array of [key, value] pairs sorted by value descending
    def sort_by_value_desc
      @results.sort_by { |k, v| v }.reverse
    end

    # Convert sorted results back to a hash
    # @param sorted_pairs [Array<Array>] array of [key, value] pairs
    # @return [Hash] sorted results as hash
    def to_sorted_hash(sorted_pairs)
      sorted_pairs.to_h
    end

    # Convert grouped results to a formatted table.
    # @param format [Symbol] output format (:ascii, :csv, :json)
    # @param headers [Array<String>] custom headers (default: ["Group", "Count"])
    # @return [String] formatted table
    # @example
    #   Asset.group_by(:category, sortable: true).count.to_table
    #   Asset.group_by(:category).sum(:file_size).to_table(headers: ["Category", "Total Size"])
    def to_table(format: :ascii, headers: ["Group", "Count"])
      pairs = @results.to_a

      # Build table data
      table_data = {
        headers: headers,
        rows: pairs.map { |key, value| [format_group_key(key), format_group_value(value)] },
      }

      # Format based on requested format
      case format
      when :ascii
        format_grouped_ascii_table(table_data)
      when :csv
        format_grouped_csv_table(table_data)
      when :json
        format_grouped_json_table(table_data)
      else
        raise ArgumentError, "Unsupported format: #{format}. Use :ascii, :csv, or :json"
      end
    end

    private

    # Format group key for display
    def format_group_key(key)
      case key
      when Parse::Pointer
        "#{key.parse_class}##{key.id}"
      when nil
        "null"
      else
        key.to_s
      end
    end

    # Format group value for display
    def format_group_value(value)
      case value
      when Numeric
        value.to_s
      when nil
        "null"
      else
        value.to_s
      end
    end

    # Format ASCII table for grouped results
    def format_grouped_ascii_table(data)
      headers = data[:headers]
      rows = data[:rows]

      return "No results found." if rows.empty?

      # Calculate column widths
      col_widths = headers.map.with_index do |header, i|
        max_width = [header.length, *rows.map { |row| row[i].to_s.length }].max
        [max_width, 3].max
      end

      # Build table
      result = []

      # Top border
      result << "+" + col_widths.map { |w| "-" * (w + 2) }.join("+") + "+"

      # Headers
      header_row = "|" + headers.map.with_index { |h, i| " #{h.ljust(col_widths[i])} " }.join("|") + "|"
      result << header_row

      # Header separator
      result << "+" + col_widths.map { |w| "-" * (w + 2) }.join("+") + "+"

      # Rows
      rows.each do |row|
        row_str = "|" + row.map.with_index { |cell, i| " #{cell.to_s.ljust(col_widths[i])} " }.join("|") + "|"
        result << row_str
      end

      # Bottom border
      result << "+" + col_widths.map { |w| "-" * (w + 2) }.join("+") + "+"

      result.join("\n")
    end

    # Format CSV table for grouped results
    def format_grouped_csv_table(data)
      require "csv"

      CSV.generate do |csv|
        csv << data[:headers]
        data[:rows].each { |row| csv << row }
      end
    end

    # Format JSON table for grouped results
    def format_grouped_json_table(data)
      headers = data[:headers]
      rows = data[:rows]

      table_objects = rows.map do |row|
        headers.zip(row).to_h
      end

      JSON.pretty_generate(table_objects)
    end
  end

  # Sortable version of GroupBy that returns GroupedResult objects instead of plain hashes.
  # Provides the same aggregation methods but with sorting capabilities.
  class SortableGroupBy < GroupBy
    # Count the number of items in each group.
    # @return [GroupedResult] a sortable result object.
    def count
      results = super
      GroupedResult.new(results)
    end

    # Sum a field for each group.
    # @param field [Symbol, String] the field to sum within each group.
    # @return [GroupedResult] a sortable result object.
    def sum(field)
      results = super
      GroupedResult.new(results)
    end

    # Calculate average of a field for each group.
    # @param field [Symbol, String] the field to average within each group.
    # @return [GroupedResult] a sortable result object.
    def average(field)
      results = super
      GroupedResult.new(results)
    end

    alias_method :avg, :average

    # Find minimum value of a field for each group.
    # @param field [Symbol, String] the field to find minimum for within each group.
    # @return [GroupedResult] a sortable result object.
    def min(field)
      results = super
      GroupedResult.new(results)
    end

    # Find maximum value of a field for each group.
    # @param field [Symbol, String] the field to find maximum for within each group.
    # @return [GroupedResult] a sortable result object.
    def max(field)
      results = super
      GroupedResult.new(results)
    end
  end

  # Helper class for handling group_by_date aggregations with method chaining.
  # Groups data by time intervals (year, month, week, day, hour) and supports aggregation operations.
  class GroupByDate
    # @param query [Parse::Query] the base query to group
    # @param date_field [Symbol, String] the date field to group by
    # @param interval [Symbol] the time interval (:year, :month, :week, :day, :hour, :minute)
    # @param timezone [String] the timezone for date operations (e.g., "America/New_York", "+05:00")
    # @param mongo_direct [Boolean] whether to query MongoDB directly bypassing Parse Server
    def initialize(query, date_field, interval, return_pointers: false, timezone: nil, mongo_direct: false)
      @query = query
      @date_field = date_field
      @interval = interval
      @return_pointers = return_pointers
      @timezone = timezone
      @mongo_direct = mongo_direct
    end

    # Returns the MongoDB aggregation pipeline that would be used for a count operation.
    # This is useful for debugging and understanding the generated pipeline.
    # @return [Array<Hash>] the MongoDB aggregation pipeline
    # @example
    #   Capture.where(:author_team.eq => team).group_by_date(:created_at, :month).pipeline
    #   # => [{"$match"=>{"authorTeam"=>"Team$abc123"}}, {"$group"=>{"_id"=>{"year"=>{"$year"=>"$createdAt"}, "month"=>{"$month"=>"$createdAt"}}, "count"=>{"$sum"=>1}}}, {"$project"=>{"_id"=>0, "objectId"=>"$_id", "count"=>1}}]
    def pipeline
      # Format the date field name
      formatted_date_field = @query.send(:format_aggregation_field, @date_field)

      # Build the aggregation pipeline (same logic as execute_date_aggregation)
      pipeline = []

      # Add match stage if there are where conditions
      compiled_where = @query.send(:compile_where)
      if compiled_where.present?
        # Convert field names for aggregation context and handle dates
        aggregation_where = @query.send(:convert_constraints_for_aggregation, compiled_where)
        stringified_where = @query.send(:convert_dates_for_aggregation, aggregation_where)
        pipeline << { "$match" => stringified_where }
      end

      # Create date grouping expression based on interval using shared method
      date_expr = build_date_group_expression(formatted_date_field)

      # Add group and project stages (using count as example aggregation)
      pipeline.concat([
        {
          "$group" => {
            "_id" => date_expr,
            "count" => { "$sum" => 1 },
          },
        },
        {
          "$project" => {
            "_id" => 0,
            "objectId" => "$_id",
            "count" => 1,
          },
        },
      ])

      pipeline
    end

    # Count the number of items in each time period.
    # @return [Hash] a hash with formatted date strings as keys and counts as values.
    # @example
    #   Capture.group_by_date(:created_at, :day).count
    #   # => {"2024-11-24" => 45, "2024-11-25" => 23}
    def count
      execute_date_aggregation("count", { "$sum" => 1 })
    end

    # Sum a field for each time period.
    # @param field [Symbol, String] the field to sum within each time period.
    # @return [Hash] a hash with formatted date strings as keys and sums as values.
    # @example
    #   Asset.group_by_date(:created_at, :month).sum(:file_size)
    #   # => {"2024-11" => 1024000, "2024-12" => 512000}
    def sum(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `sum`."
      end

      formatted_field = @query.send(:format_aggregation_field, field)
      execute_date_aggregation("sum", { "$sum" => "$#{formatted_field}" })
    end

    # Calculate average of a field for each time period.
    # @param field [Symbol, String] the field to average within each time period.
    # @return [Hash] a hash with formatted date strings as keys and averages as values.
    def average(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `average`."
      end

      formatted_field = @query.send(:format_aggregation_field, field)
      execute_date_aggregation("average", { "$avg" => "$#{formatted_field}" })
    end

    alias_method :avg, :average

    # Find minimum value of a field for each time period.
    # @param field [Symbol, String] the field to find minimum for within each time period.
    # @return [Hash] a hash with formatted date strings as keys and minimum values as values.
    def min(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `min`."
      end

      formatted_field = @query.send(:format_aggregation_field, field)
      execute_date_aggregation("min", { "$min" => "$#{formatted_field}" })
    end

    # Find maximum value of a field for each time period.
    # @param field [Symbol, String] the field to find maximum for within each time period.
    # @return [Hash] a hash with formatted date strings as keys and maximum values as values.
    def max(field)
      if field.nil? || !field.respond_to?(:to_s)
        raise ArgumentError, "Invalid field name passed to `max`."
      end

      formatted_field = @query.send(:format_aggregation_field, field)
      execute_date_aggregation("max", { "$max" => "$#{formatted_field}" })
    end

    private

    # Execute a date-based group aggregation operation.
    # @param operation [String] the operation name for debugging.
    # @param aggregation_expr [Hash] the MongoDB aggregation expression.
    # @return [Hash] the grouped results with formatted date keys.
    def execute_date_aggregation(operation, aggregation_expr)
      # Format the date field name
      formatted_date_field = @query.send(:format_aggregation_field, @date_field)

      # Use direct MongoDB if enabled
      if @mongo_direct
        return execute_date_aggregation_direct(operation, aggregation_expr, formatted_date_field)
      end

      # Build the date grouping expression based on interval
      date_group_expr = build_date_group_expression(formatted_date_field)

      # Build the aggregation pipeline
      pipeline = [
        {
          "$group" => {
            "_id" => date_group_expr,
            "count" => aggregation_expr,
          },
        },
        # Sort by date to get chronological order
        { "$sort" => { "_id" => 1 } },
        {
          "$project" => {
            "_id" => 0,
            "objectId" => "$_id",
            "count" => 1,
          },
        },
      ]

      # Add match stage if there are where conditions
      compiled_where = @query.send(:compile_where)
      if compiled_where.present?
        # Convert field names for aggregation context and handle dates
        aggregation_where = @query.send(:convert_constraints_for_aggregation, compiled_where)
        stringified_where = @query.send(:convert_dates_for_aggregation, aggregation_where)
        pipeline.unshift({ "$match" => stringified_where })
      end

      # Execute the pipeline aggregation
      if @query.instance_variable_get(:@verbose_aggregate)
        puts "[VERBOSE AGGREGATE] Pipeline for group_by_date(:#{@date_field}, :#{@interval}).#{operation}:"
        puts JSON.pretty_generate(pipeline)
        puts "[VERBOSE AGGREGATE] Sending to: #{@query.instance_variable_get(:@table)}"
      end

      response = @query.client.aggregate_pipeline(
        @query.instance_variable_get(:@table),
        pipeline,
        headers: {},
        **@query.send(:_opts),
      )

      if @query.instance_variable_get(:@verbose_aggregate)
        puts "[VERBOSE AGGREGATE] Response success?: #{response.success?}"
        puts "[VERBOSE AGGREGATE] Response result: #{response.result.inspect}"
        puts "[VERBOSE AGGREGATE] Response error: #{response.error.inspect}" unless response.success?
      end

      # Convert array of results to hash with formatted date strings
      if response.success? && response.result.is_a?(Array)
        result_hash = {}
        response.result.each do |item|
          # Parse Server returns group key as "objectId" with $project stage
          date_key = item["objectId"]
          value = item["count"]

          # Format the date key for display
          formatted_key = format_date_key(date_key)
          result_hash[formatted_key] = value
        end
        result_hash
      else
        {}
      end
    end

    # Execute a date-based group aggregation operation directly on MongoDB.
    # @param operation [String] the operation name for debugging.
    # @param aggregation_expr [Hash] the MongoDB aggregation expression.
    # @param formatted_date_field [String] the formatted date field name.
    # @return [Hash] the grouped results with formatted date keys.
    def execute_date_aggregation_direct(operation, aggregation_expr, formatted_date_field)
      require_relative "mongodb"
      Parse::MongoDB.require_gem!

      unless Parse::MongoDB.available?
        raise Parse::MongoDB::NotEnabled,
          "Direct MongoDB queries are not enabled. " \
          "Call Parse::MongoDB.configure(uri: 'mongodb://...', enabled: true) first."
      end

      # Convert date field for direct MongoDB (createdAt -> _created_at, etc.)
      mongo_date_field = @query.send(:convert_field_for_direct_mongodb, formatted_date_field)

      # Build the date grouping expression with MongoDB field name
      date_group_expr = build_date_group_expression_for_direct(mongo_date_field)

      # Convert aggregation expression field references for direct MongoDB
      converted_expr = convert_aggregation_expr_for_direct(aggregation_expr)

      # Build the pipeline with match constraints
      pipeline = []

      # Add match stage from query constraints
      compiled_where = @query.send(:compile_where)
      if compiled_where.present?
        regular_constraints = compiled_where.reject { |f, _| f == "__aggregation_pipeline" }
        if regular_constraints.any?
          mongo_constraints = @query.send(:convert_constraints_for_direct_mongodb, regular_constraints)
          pipeline << { "$match" => mongo_constraints }
        end
      end

      # Add group, sort, and project stages
      pipeline.concat([
        {
          "$group" => {
            "_id" => date_group_expr,
            "count" => converted_expr,
          },
        },
        { "$sort" => { "_id" => 1 } },
        {
          "$project" => {
            "_id" => 0,
            "value" => "$_id",
            "count" => 1,
          },
        },
      ])

      # Execute directly on MongoDB
      raw_results = Parse::MongoDB.aggregate(@query.instance_variable_get(:@table), pipeline)

      # Convert array of results to hash with formatted date strings
      result_hash = {}
      raw_results.each do |item|
        date_key = item["value"]
        value = item["count"]

        # Format the date key for display
        formatted_key = format_date_key(date_key)
        result_hash[formatted_key] = value
      end
      result_hash
    end

    # Build the MongoDB date grouping expression for direct MongoDB access.
    # @param field_name [String] the MongoDB field name (e.g., "_created_at").
    # @return [Hash] the MongoDB date grouping expression.
    def build_date_group_expression_for_direct(field_name)
      # Helper to create date operator with optional timezone
      date_op = lambda do |operator|
        if @timezone
          { operator => { "date" => "$#{field_name}", "timezone" => @timezone } }
        else
          { operator => "$#{field_name}" }
        end
      end

      case @interval
      when :year
        date_op.call("$year")
      when :month
        {
          "year" => date_op.call("$year"),
          "month" => date_op.call("$month"),
        }
      when :week
        {
          "year" => date_op.call("$year"),
          "week" => date_op.call("$week"),
        }
      when :day
        {
          "year" => date_op.call("$year"),
          "month" => date_op.call("$month"),
          "day" => date_op.call("$dayOfMonth"),
        }
      when :hour
        {
          "year" => date_op.call("$year"),
          "month" => date_op.call("$month"),
          "day" => date_op.call("$dayOfMonth"),
          "hour" => date_op.call("$hour"),
        }
      when :minute
        {
          "year" => date_op.call("$year"),
          "month" => date_op.call("$month"),
          "day" => date_op.call("$dayOfMonth"),
          "hour" => date_op.call("$hour"),
          "minute" => date_op.call("$minute"),
        }
      when :second
        {
          "year" => date_op.call("$year"),
          "month" => date_op.call("$month"),
          "day" => date_op.call("$dayOfMonth"),
          "hour" => date_op.call("$hour"),
          "minute" => date_op.call("$minute"),
          "second" => date_op.call("$second"),
        }
      else
        # Default to day if unknown interval
        {
          "year" => date_op.call("$year"),
          "month" => date_op.call("$month"),
          "day" => date_op.call("$dayOfMonth"),
        }
      end
    end

    # Convert aggregation expression field references for direct MongoDB.
    # @param expr [Hash] the aggregation expression
    # @return [Hash] the converted expression
    def convert_aggregation_expr_for_direct(expr)
      return expr unless expr.is_a?(Hash)

      result = {}
      expr.each do |op, value|
        if value.is_a?(String) && value.start_with?("$")
          # Field reference - convert field name
          field = value[1..-1]
          result[op] = "$#{@query.send(:convert_field_for_direct_mongodb, field)}"
        else
          result[op] = value
        end
      end
      result
    end

    # Build the MongoDB date grouping expression based on the interval.
    # @param field_name [String] the formatted date field name.
    # @return [Hash] the MongoDB date grouping expression.
    def build_date_group_expression(field_name)
      # Helper to create date operator with optional timezone
      date_op = lambda do |operator|
        if @timezone
          { operator => { "date" => "$#{field_name}", "timezone" => @timezone } }
        else
          { operator => "$#{field_name}" }
        end
      end

      case @interval
      when :year
        date_op.call("$year")
      when :month
        {
          "year" => date_op.call("$year"),
          "month" => date_op.call("$month"),
        }
      when :week
        {
          "year" => date_op.call("$year"),
          "week" => date_op.call("$week"),
        }
      when :day
        {
          "year" => date_op.call("$year"),
          "month" => date_op.call("$month"),
          "day" => date_op.call("$dayOfMonth"),
        }
      when :hour
        {
          "year" => date_op.call("$year"),
          "month" => date_op.call("$month"),
          "day" => date_op.call("$dayOfMonth"),
          "hour" => date_op.call("$hour"),
        }
      when :minute
        {
          "year" => date_op.call("$year"),
          "month" => date_op.call("$month"),
          "day" => date_op.call("$dayOfMonth"),
          "hour" => date_op.call("$hour"),
          "minute" => date_op.call("$minute"),
        }
      when :second
        {
          "year" => date_op.call("$year"),
          "month" => date_op.call("$month"),
          "day" => date_op.call("$dayOfMonth"),
          "hour" => date_op.call("$hour"),
          "minute" => date_op.call("$minute"),
          "second" => date_op.call("$second"),
        }
      end
    end

    # Format the date key from MongoDB result for display.
    # @param date_key [Object] the date key from MongoDB grouping.
    # @return [String] a formatted date string.
    def format_date_key(date_key)
      case @interval
      when :year
        date_key.to_s
      when :month
        return "null" if date_key.nil? || !date_key.is_a?(Hash)
        year = date_key["year"]
        month = date_key["month"]
        return "null" if year.nil? || month.nil?
        sprintf("%04d-%02d", year, month)
      when :week
        return "null" if date_key.nil? || !date_key.is_a?(Hash)
        year = date_key["year"]
        week = date_key["week"]
        return "null" if year.nil? || week.nil?
        sprintf("%04d-W%02d", year, week)
      when :day
        return "null" if date_key.nil? || !date_key.is_a?(Hash)
        year = date_key["year"]
        month = date_key["month"]
        day = date_key["day"]
        return "null" if year.nil? || month.nil? || day.nil?
        sprintf("%04d-%02d-%02d", year, month, day)
      when :hour
        return "null" if date_key.nil? || !date_key.is_a?(Hash)
        year = date_key["year"]
        month = date_key["month"]
        day = date_key["day"]
        hour = date_key["hour"]
        return "null" if year.nil? || month.nil? || day.nil? || hour.nil?
        sprintf("%04d-%02d-%02d %02d:00", year, month, day, hour)
      when :minute
        return "null" if date_key.nil? || !date_key.is_a?(Hash)
        year = date_key["year"]
        month = date_key["month"]
        day = date_key["day"]
        hour = date_key["hour"]
        minute = date_key["minute"]
        return "null" if year.nil? || month.nil? || day.nil? || hour.nil? || minute.nil?
        sprintf("%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
      when :second
        return "null" if date_key.nil? || !date_key.is_a?(Hash)
        year = date_key["year"]
        month = date_key["month"]
        day = date_key["day"]
        hour = date_key["hour"]
        minute = date_key["minute"]
        second = date_key["second"]
        return "null" if year.nil? || month.nil? || day.nil? || hour.nil? || minute.nil? || second.nil?
        sprintf("%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
      end
    end
  end

  # Sortable version of GroupByDate that returns GroupedResult objects instead of plain hashes.
  # Provides the same aggregation methods but with sorting capabilities.
  class SortableGroupByDate < GroupByDate
    # Count the number of items in each time period.
    # @return [GroupedResult] a sortable result object.
    def count
      results = super
      GroupedResult.new(results)
    end

    # Sum a field for each time period.
    # @param field [Symbol, String] the field to sum within each time period.
    # @return [GroupedResult] a sortable result object.
    def sum(field)
      results = super
      GroupedResult.new(results)
    end

    # Calculate average of a field for each time period.
    # @param field [Symbol, String] the field to average within each time period.
    # @return [GroupedResult] a sortable result object.
    def average(field)
      results = super
      GroupedResult.new(results)
    end

    alias_method :avg, :average

    # Find minimum value of a field for each time period.
    # @param field [Symbol, String] the field to find minimum for within each time period.
    # @return [GroupedResult] a sortable result object.
    def min(field)
      results = super
      GroupedResult.new(results)
    end

    # Find maximum value of a field for each time period.
    # @param field [Symbol, String] the field to find maximum for within each time period.
    # @return [GroupedResult] a sortable result object.
    def max(field)
      results = super
      GroupedResult.new(results)
    end
  end
end # Parse
