# encoding: UTF-8
# frozen_string_literal: true

require_relative "client"
require_relative "pipeline_security"
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

    # Built-in Parse classes always considered known, independent of the
    # server schema. Used both as the seed for the dynamic list and as the
    # transient fallback when the schema fetch fails.
    BUILT_IN_PARSE_CLASSES = %w[
      _User _Role _Session _Installation _Audience
      User Role Session Installation Audience
    ].freeze

    # Mutex guarding lazy memoization of {known_parse_classes} so concurrent
    # first-callers don't each fire a `schemas` request and clobber the cache.
    @known_parse_classes_mutex = Mutex.new

    # Known Parse classes for fast validation - dynamically loaded from schema.
    #
    # The successful result is memoized; a failed schema fetch is NOT cached —
    # it returns the built-in fallback for this call only, so a transient
    # server outage during boot doesn't permanently strip every application-
    # defined class from the known set (which would make class-accessibility
    # checks reject custom classes for the process lifetime). The narrowed
    # rescue logs the failure instead of swallowing it silently.
    def self.known_parse_classes
      cached = @known_parse_classes
      return cached if cached

      @known_parse_classes_mutex.synchronize do
        # Re-check under the lock: a racing caller may have populated it.
        return @known_parse_classes if @known_parse_classes

        begin
          response = Parse.client.schemas
          schema_classes = response.success? ? response.results.map { |cls| cls["className"] } : []
          @known_parse_classes = (BUILT_IN_PARSE_CLASSES + schema_classes).uniq.freeze
        rescue Parse::Error, Faraday::Error => e
          # Don't cache the fallback — let the next call retry the fetch once
          # the server is reachable again.
          warn "[Parse::Query] schema fetch failed (#{e.class}: #{e.message}); " \
               "falling back to built-in classes for this check only."
          BUILT_IN_PARSE_CLASSES
        end
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

    # The set of symbol keys that {#conditions} treats as query-shape
    # options (cache TTL, ordering, limits, ACL convenience helpers,
    # session/master-key overrides) rather than as field-name
    # constraints. External callers that need to partition a
    # user-supplied constraints Hash into "real constraints vs query
    # options" — most notably `Parse::Object.first_or_create!` and
    # `Parse::Object.create_or_update!`, which must hand a Hash
    # containing ONLY constraint key/value pairs to
    # `Parse::CreateLock.canonicalize_attrs` — consult this set via
    # {.option_key?}.
    #
    # Keep this list in sync with the option branches at the top of
    # {#conditions}. Anything `conditions()` extracts as a query
    # parameter rather than a constraint belongs here.
    QUERY_OPTION_KEYS = [
      :order, :keys, :key, :skip, :limit,
      :include, :includes,
      :cache, :use_master_key, :session,
      :read_preference,
      :readable_by, :writable_by, :readable_by_role, :writable_by_role,
      :publicly_readable, :publicly_writable,
      :privately_readable, :master_key_read_only,
      :privately_writable, :master_key_write_only,
      :private_acl, :master_key_only,
      :not_publicly_readable, :not_publicly_writable,
    ].to_set.freeze

    class << self
      # Whether `key` is one of the {QUERY_OPTION_KEYS} that {#conditions}
      # absorbs as a query-shape option rather than a field-name
      # constraint. Accepts Symbol or String; returns false for any
      # other type (including `Parse::Operation`, which is always a
      # constraint).
      #
      # @note {QUERY_OPTION_KEYS} must be kept in sync with the
      #   option-branch keys recognized at the top of {#conditions}.
      #   When adding a new query option, update BOTH places — this
      #   predicate is the public-facing source of truth for callers
      #   that partition `query_attrs` into constraints vs options
      #   (notably {Parse::Object.first_or_create!} and
      #   {Parse::Object.create_or_update!} for lock canonicalization),
      #   and the option-branch in `conditions` is what actually
      #   absorbs the option onto the query.
      #
      # @param key [Object]
      # @return [Boolean]
      def option_key?(key)
        return false unless key.is_a?(Symbol) || key.is_a?(String)
        QUERY_OPTION_KEYS.include?(key.to_sym)
      end
    end

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

      # Process-wide `[table, field]` cache for warn-once dedup in
      # {#handle_unresolvable_pointer_in_array!}.
      def pointer_shape_warned
        @pointer_shape_warned ||= {}
      end

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
      #
      # `__`-prefixed internal routing markers (e.g. `"__mongo_direct_only"`
      # and `"__aggregation_pipeline"`) are stripped from the returned hash —
      # they are SDK-internal hints that must never reach Parse REST or
      # MongoDB. Use {compile_markers} (instance method `#compile_markers`)
      # to retrieve them for routing decisions / pipeline assembly.
      # @param where [Array] an array of {Parse::Constraint} objects.
      # @return [Hash] a hash representing the compiled query, with
      #   internal routing markers stripped.
      # One-shot process latch so {#warn_if_public_explain_restricted!} emits
      # the allowPublicExplain guidance at most once per process rather than on
      # every explain call.
      # @!visibility private
      def public_explain_warned?
        @public_explain_warned == true
      end

      # @!visibility private
      def public_explain_warned!
        @public_explain_warned = true
      end

      def compile_where(where)
        constraint_reduce(where).reject { |k, _| k.is_a?(String) && k.start_with?("__") }
      end

      # Return the un-stripped reduced hash so the routing/pipeline layer
      # can inspect `__`-prefixed markers (e.g. `"__mongo_direct_only"`,
      # `"__aggregation_pipeline"`). These markers are SDK-internal hints
      # and must never be sent to Parse REST or MongoDB — that's what
      # {compile_where} is for.
      # @param where [Array] an array of {Parse::Constraint} objects.
      # @return [Hash] the reduced hash including internal markers.
      def compile_markers(where)
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
      @exclude_keys = []
      @includes = []
      @limit = nil
      @skip = 0
      @table = table
      @cache = Parse.default_query_cache
      # Tri-state: `nil` means "no caller preference" — the request layer
      # then applies the master-key default, the `Parse.client_mode` flag,
      # and the `Parse.with_session` ambient as configured. Explicit
      # `true` / `false` (set via `use_master_key=` or the `use_master_key:`
      # constraint key) wins over both. A `true` default here would
      # silently smuggle the master-key header past every client-mode
      # query, so we deliberately leave the decision to the request layer
      # unless the caller said otherwise.
      @use_master_key = nil
      @verbose_aggregate = false
      @hint = nil
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

    # Set a server-side field denylist for this query.
    # When set, Parse Server excludes the named fields from each returned
    # object, complementing the {#keys} allowlist. The two options can be
    # combined: Parse Server first applies the {#keys} allowlist, then
    # strips any field names listed in +excludeKeys+.
    #
    # @note On the REST query path (+encode: true+ in {#compile}) this maps to
    #   Parse Server's path-scoped +excludeKeys+. On the mongo-direct path
    #   (explicit +.results_direct+, an auto-route, or an aggregation that
    #   auto-promotes — e.g. an +$inQuery+ pointer constraint that rewrites to
    #   a +$lookup+) the pipeline can only project the {#keys} allowlist, so
    #   the SDK honors the denylist as a post-fetch sanitize over the returned
    #   results instead. That mongo-direct sanitize is recursive by name: it
    #   strips EVERY key with a matching name at any depth, so excluding a
    #   field also removes a same-named field inside included/nested objects —
    #   broader than the REST path's top-level/dotted scoping. Reserved
    #   envelope fields (+objectId+, +className+, +__type+, +createdAt+,
    #   +updatedAt+, +ACL+ and their Mongo storage-form names) are never
    #   stripped, so object reconstruction is unaffected. The raw aggregation
    #   accessor (`aggregate(...).raw`) returns unredacted documents — the
    #   sanitize applies to the object/decoded result paths. +excludeKeys+ is a
    #   projection convenience, not an ACL/CLP boundary, so it does not affect
    #   access control.
    #
    # @example Omit a single sensitive field
    #   Post.query.exclude_keys(:secret_token).results
    #
    # @example Omit multiple fields
    #   Post.query.exclude_keys(:secret_token, :internal_notes).results
    #
    # @param fields [Array<Symbol, String>] the field names to exclude.
    # @return [self]
    def exclude_keys(*fields)
      @exclude_keys ||= []
      fields.flatten.each do |field|
        if field.nil? == false && field.respond_to?(:to_s)
          @exclude_keys.push Query.format_field(field).to_sym
        end
      end
      @exclude_keys.uniq!
      @results = nil if fields.count > 0
      self # chaining
    end

    # Extract values for a specific field from all matching objects.
    # This is similar to keys() but returns an array of the actual field values
    # instead of objects with only those fields selected.
    # @param field [Symbol, String] the field name to extract values for.
    # @return [Array] an array of field values from all matching objects.
    # @example
    #   # Get all asset names
    #   Document.query.pluck(:name)
    #   # => ["video1.mp4", "image1.jpg", "audio1.mp3"]
    #
    #   # Get all author workspace IDs
    #   Document.query.pluck(:author_workspace)
    #   # => [{"__type"=>"Pointer", "className"=>"Workspace", "objectId"=>"abc123"}, ...]
    #
    #   # Get created dates
    #   Document.query.pluck(:created_at)
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
    #
    #  # hash form: {field => :asc | :desc | "asc" | "desc"}
    #  Song.all :order => { :like_count => :desc, :name => :asc }
    # @param ordering [Parse::Order, Symbol, String, Hash] one or more
    #   ordering directives. A Hash maps field => direction. Unsupported
    #   argument types raise +ArgumentError+ rather than being silently
    #   dropped.
    # @return [self]
    def order(*ordering)
      @order ||= []
      # Don't flatten through Hashes — flatten only unpacks Arrays.
      ordering.flatten.each do |entry|
        case entry
        when Order
          entry.field = Query.format_field(entry.field)
          @order.push entry
        when Symbol, String
          o = Order.new(entry)
          o.field = Query.format_field(o.field)
          @order.push o
        when Hash
          entry.each do |field, direction|
            dir_sym = direction.is_a?(String) ? direction.downcase.to_sym : direction
            unless dir_sym == :asc || dir_sym == :desc
              raise ArgumentError,
                    "Invalid order direction #{direction.inspect} for field " \
                    "#{field.inspect}. Expected :asc or :desc."
            end
            o = Order.new(field, dir_sym)
            o.field = Query.format_field(o.field)
            @order.push o
          end
        else
          raise ArgumentError,
                "Invalid order argument #{entry.inspect}. Expected a Symbol, " \
                "String, Parse::Order (e.g. :field.asc / :field.desc), or " \
                "Hash of {field => :asc | :desc}."
        end
      end
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
      coerced =
        case amount
        when nil      then 0
        when Numeric  then amount.to_i
        when String
          unless amount =~ /\A-?\d+\z/
            raise ArgumentError,
                  "Invalid skip #{amount.inspect}. Expected an Integer, " \
                  "a numeric String, or nil."
          end
          amount.to_i
        else
          raise ArgumentError,
                "Invalid skip #{amount.inspect}. Expected an Integer, " \
                "a numeric String, or nil."
        end
      @skip = [0, coerced].max
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
    # @param count [Integer,Symbol,String,nil] The number of records to return.
    #  Pass +:max+ to fetch as many records as possible (Parse-Server dependent).
    #  Numeric strings (e.g. +"50"+) are coerced to Integer. Pass +nil+ to
    #  explicitly clear the limit. Any other value raises +ArgumentError+
    #  rather than silently disabling the limit.
    # @return [self]
    def limit(count)
      case count
      when nil
        @limit = nil
      when Numeric
        @limit = [0, count.to_i].max
      when :max
        @limit = :max
      when String
        unless count =~ /\A-?\d+\z/
          raise ArgumentError,
                "Invalid limit #{count.inspect}. Expected an Integer, :max, " \
                "a numeric String, or nil."
        end
        @limit = [0, count.to_i].max
      else
        raise ArgumentError,
              "Invalid limit #{count.inspect}. Expected an Integer, :max, " \
              "a numeric String, or nil."
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

    # Set a MongoDB index hint for this query.
    # Forces Parse Server (and the underlying MongoDB driver) to use the
    # named index instead of the query planner's choice. Useful for
    # benchmarking or for working around sub-optimal plan selection.
    # The hint is emitted in the compiled REST query body as the +hint+
    # parameter (supported by Parse Server 7.4.0+) AND forwarded to the
    # mongo-direct path — +results_direct+ / +count_direct+ / +distinct_direct+
    # pass it to {Parse::MongoDB.aggregate}/{Parse::MongoDB.find} as the Mongo
    # +hint+ option, so a plan diagnosed with {#explain} can be corrected on
    # either path.
    #
    # @example Force a specific index
    #   Post.query(:status => "published").hint("status_1_created_at_-1").results
    #
    # @param index_name [String, nil, :_read_] the index name or key pattern to use,
    #   or +nil+ to clear a previously set hint. Called with no arguments acts as a
    #   reader and returns the current hint value.
    # @return [String, nil, self]
    HINT_UNSET = :_hint_unset_ # @!visibility private
    def hint(index_name = HINT_UNSET)
      return @hint if index_name.equal?(HINT_UNSET)
      @hint = index_name
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
      reject_vector_constraint!(constraint)
      @where.push constraint
      @results = nil
      self #chaining
    end

    # @!visibility private
    # Raise {Parse::VectorSearch::ConstraintNotSupported} when a
    # constraint targets a declared `:vector` property with an operator
    # other than the narrow allow-list. Silent-no-op when the query's
    # `@table` doesn't map to a registered Parse::Object subclass, when
    # the subclass declares no `:vector` properties, or when the
    # operand doesn't match a declared vector field on the resolved
    # class.
    #
    # Allow-list: `$exists` (the constraint key for both `:exists` and
    # `:null`), and that's it. Backfill queries like
    # `Doc.query(:body_embedding.null => true)` are useful. Equality,
    # range, $in, $nin, $all, etc. on a 1536-float array are at best
    # surprising and at worst wrong.
    def reject_vector_constraint!(constraint)
      return unless @table
      klass = Parse::Model.find_class(@table)
      return unless klass.respond_to?(:vector_properties)
      vec_fields = klass.vector_properties
      return if vec_fields.nil? || vec_fields.empty?
      # `constraint.operand` may be either the local symbol (e.g.
      # `:body_embedding`) or the camel-cased remote field (e.g.
      # `:bodyEmbedding`) depending on whether Query.format_field has
      # already run. Resolve both shapes against the local set.
      operand_sym = constraint.operand.to_sym
      local_field =
        if vec_fields.key?(operand_sym)
          operand_sym
        elsif klass.respond_to?(:field_map)
          klass.field_map.find { |_local, remote| remote.to_sym == operand_sym }&.first
        end
      return unless local_field && vec_fields.key?(local_field)
      # `$exists` is the only constraint key that makes semantic sense
      # on a dense numeric array — "do you have an embedding yet?" is a
      # legitimate backfill query.
      return if constraint.class.key == :$exists
      op_keyword = constraint.class.key || :eq
      raise Parse::VectorSearch::ConstraintNotSupported,
            "#{klass}.#{local_field} is a :vector property; constraint `#{op_keyword}` " \
            "is not supported on vector fields. Vector queries must use " \
            "#{klass}.find_similar(vector:/text:) (which routes through Atlas " \
            "$vectorSearch); only :exists / :null are accepted in Parse::Query."
    end

    # @param raw [Boolean] whether to return the hash form of the constraints.
    # @return [Array<Parse::Constraint>] if raw is false, an array of constraints
    #  composing the :where clause for this query.
    # @return [Hash] if raw is true, a hash representing the constraints.
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
    # @param order [Symbol, nil] `:asc` or `:desc` to sort the distinct
    #   values MongoDB-side via a `$sort` stage after `$group`. Default: nil
    #   (no sort — the caller can `.sort` the returned Array in Ruby).
    # @version 1.8.0
    def distinct(field, return_pointers: false, mongo_direct: false, order: nil)
      # Explicit opt-in to direct MongoDB
      if mongo_direct
        return distinct_direct(field, return_pointers: return_pointers, order: order,
                               **mongo_direct_auth_kwargs)
      end

      # Auto-route to mongo-direct when the compiled where contains a
      # direct-only constraint. Same gate as #count / #results.
      if requires_mongo_direct?
        assert_mongo_direct_routable!
        return distinct_direct(field, return_pointers: return_pointers, order: order,
                               **mongo_direct_auth_kwargs)
      end

      # Auto-route scoped queries (session_token / acl_user / acl_role) to
      # mongo-direct: Parse Server's REST `/aggregate` endpoint is
      # master-key-only and enforces neither ACL nor CLP, so a scoped
      # `.distinct` call against REST would silently return unscoped
      # values. The mongo-direct path runs ACLScope + CLPScope before
      # `$group`, so distinct values reflect only ACL-readable rows.
      if distinct_query_is_scoped? && defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
        return distinct_direct(field, return_pointers: return_pointers, order: order,
                               **mongo_direct_auth_kwargs)
      end

      if field.nil? || !field.respond_to?(:to_s) || field.is_a?(Hash) || field.is_a?(Array)
        raise ArgumentError, "Invalid field name passed to `distinct`."
      end

      sort_dir = distinct_sort_direction(order)

      # Format field for aggregation
      formatted_field = format_aggregation_field(field)

      # Build the aggregation pipeline for distinct values
      pipeline = [{ "$group" => { "_id" => "$#{formatted_field}" } }]
      pipeline << { "$sort" => { "_id" => sort_dir } } if sort_dir
      pipeline << { "$project" => { "_id" => 0, "value" => "$_id" } }

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
    # @param order [Symbol, nil] forwarded to {#distinct}.
    # @return [Array] array of distinct values, with pointer fields converted to Parse::Pointer objects
    def distinct_pointers(field, order: nil)
      distinct(field, return_pointers: true, order: order)
    end

    # Normalize a user-supplied `order:` value for the distinct helpers to a
    # MongoDB `$sort` direction integer (`1`/`-1`), or `nil` for "no sort".
    # @!visibility private
    def distinct_sort_direction(order)
      return nil if order.nil?
      case order.to_sym
      when :asc then 1
      when :desc then -1
      else
        raise ArgumentError, "distinct(order: ...) must be :asc, :desc, or nil (got #{order.inspect})"
      end
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

      # Auto-route to mongo-direct when the compiled where contains a
      # direct-only constraint. Same gate as #results.
      if requires_mongo_direct?
        assert_mongo_direct_routable!
        return count_direct(**mongo_direct_auth_kwargs)
      end

      # Check if this query requires aggregation pipeline processing
      if requires_aggregation_pipeline?
        # Build aggregation pipeline with $count stage
        pipeline, has_lookup_stages = build_aggregation_pipeline
        pipeline << { "$count" => "count" }

        # Auto-detect if MongoDB direct is needed. Mirror the routing in
        # #execute_aggregation_pipeline: a pipeline that references internal
        # ACL columns (_rperm/_wperm via readable_by/publicly_readable and
        # friends) MUST run mongo-direct — Parse Server's REST aggregate
        # endpoint cannot express a $match on those columns — and the
        # mongo-direct sink must be told the references are sanctioned so
        # the PipelineSecurity internal-fields denylist lets them through.
        uses_internal_fields = pipeline_uses_internal_fields?(pipeline)
        scoped = distinct_query_is_scoped?
        use_mongo_direct = false
        if defined?(@acl_query_mongo_direct) && !@acl_query_mongo_direct.nil?
          use_mongo_direct = @acl_query_mongo_direct
        elsif (scoped || has_lookup_stages || uses_internal_fields) &&
              defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
          use_mongo_direct = true
        elsif scoped
          # Same fail-closed contract as #aggregate / #aggregate_from_query:
          # a scoped count must not fall back to REST /aggregate, which
          # would drop the scope and count rows the caller cannot read.
          raise_scoped_aggregation_requires_mongo_direct!
        end

        # Execute aggregation
        aggregation = Aggregation.new(self, pipeline, verbose: @verbose_aggregate,
                                      mongo_direct: use_mongo_direct,
                                      allow_internal_fields: uses_internal_fields)
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
        fetch_count =
          case limit_or_constraints
          when Numeric then limit_or_constraints.to_i
          when String
            unless limit_or_constraints =~ /\A-?\d+\z/
              raise ArgumentError,
                    "Invalid first() argument #{limit_or_constraints.inspect}. " \
                    "Expected an Integer, a numeric String, or a Hash of constraints."
            end
            limit_or_constraints.to_i
          else
            raise ArgumentError,
                  "Invalid first() argument #{limit_or_constraints.inspect}. " \
                  "Expected an Integer, a numeric String, or a Hash of constraints."
          end
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
        raise Parse::Error.new(response.code, response.error)
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
      # Only forward `use_master_key` when the caller actually set it.
      # Forwarding the default (`nil`) would make `opts.key?(:use_master_key)`
      # true in the request layer and short-circuit the
      # `Parse.client_mode` / ambient-session resolution paths. See the
      # init-block comment on `@use_master_key`.
      opts[:use_master_key] = self.use_master_key unless self.use_master_key.nil?
      opts[:session_token] = self.session_token unless self.session_token.nil?
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
      pref = normalized_read_preference
      headers[Parse::Protocol::READ_PREFERENCE] = pref if pref
      headers
    end

    # Normalize the query's `read_pref` value to the canonical Parse Server
    # token (`PRIMARY`, `PRIMARY_PREFERRED`, `SECONDARY`, `SECONDARY_PREFERRED`,
    # `NEAREST`). Parse Server's `_parseReadPreference` upcases the incoming
    # string and matches exactly these forms, so the SDK emits them verbatim.
    # @return [String, nil] the canonical token, or nil when no preference is
    #   set. Warns and returns nil on an unrecognized value.
    # @!visibility private
    def normalized_read_preference
      return nil unless read_preference.present?
      pref = read_preference.to_s.upcase.gsub("_", " ").split.join("_")
      pref = case pref
        when "PRIMARY" then "PRIMARY"
        when "PRIMARY_PREFERRED", "PRIMARYPREFERRED" then "PRIMARY_PREFERRED"
        when "SECONDARY" then "SECONDARY"
        when "SECONDARY_PREFERRED", "SECONDARYPREFERRED" then "SECONDARY_PREFERRED"
        when "NEAREST" then "NEAREST"
        else pref
        end
      return pref if Parse::Protocol::READ_PREFERENCES.include?(pref)
      warn "[ParseQuery] Invalid read preference: #{read_preference}. Valid values: #{Parse::Protocol::READ_PREFERENCES.join(", ")}"
      nil
    end

    # Proactive guidance for {#explain} on Parse Server 9.0+. PS 9.0 defaults
    # `allowPublicExplain` to false, so a NON-master explain is rejected unless
    # the operator re-enabled it server-side. That flag is not surfaced in
    # `/serverInfo`, so we cannot know for certain whether the call will be
    # allowed — we therefore WARN (one-shot) and still run the call:
    # `allowPublicExplain: true` servers return the plan; restricted servers
    # fail and {#explain}'s reactive enrichment explains why.
    #
    # We warn only when the query is clearly non-master (explicit
    # `use_master_key: false`, or a session-token scope) AND the server version
    # is known to restrict it — so a master-default explain (the common case)
    # and unknown-version servers don't get spurious noise.
    # @!visibility private
    def warn_if_public_explain_restricted!
      non_master = use_master_key == false ||
                   (session_token.present? && use_master_key != true)
      return unless non_master
      return unless client.respond_to?(:server_supports?) && client.respond_to?(:server_version)
      return if client.server_version.to_s.empty?      # known version only
      return if client.server_supports?(:public_explain)
      return if Parse::Query.public_explain_warned?
      Parse::Query.public_explain_warned!
      message = "[ParseQuery:Explain] Parse Server #{client.server_version} defaults " \
                "`allowPublicExplain` to false; a non-master explain will be rejected " \
                "unless the server enables it. Run explain with use_master_key: true, or " \
                "set `allowPublicExplain: true` in the server's databaseOptions."
      if defined?(Parse) && Parse.respond_to?(:logger) && Parse.logger
        Parse.logger.warn(message)
      else
        warn message
      end
    end

    # Honor the `exclude_keys` denylist on the mongo-direct path by redacting
    # the matching fields from the fetched results in Ruby — the mongo-direct
    # pipeline projects only the `keys` allowlist (Parse Server's REST
    # `excludeKeys` has no mongo-direct equivalent), so without this the
    # denylist would silently have no effect. This is a pure post-fetch
    # sanitize over the Parse-format result hashes; it does NOT change the
    # MongoDB query or pipeline.
    #
    # Semantics differ from the REST path: `excludeKeys` on REST is
    # path-scoped (top-level / dotted), whereas this drops EVERY key with a
    # matching name at ANY depth — so excluding `:name` also strips `name`
    # from included/nested objects. This matches the "recursively drop all
    # keys with that name" contract for the mongo-direct path.
    #
    # `exclude_keys` is a projection convenience, NOT an ACL/CLP boundary, so
    # this redaction is about returned-object shape, not access control.
    #
    # Decode-critical structural keys are never stripped, so a query can ask
    # to exclude e.g. `:objectId` without breaking object reconstruction.
    # @param results [Array<Hash>] Parse-format result hashes (mutated in place)
    # @return [Array<Hash>] the same array, with excluded keys removed
    # @!visibility private
    def redact_excluded_keys!(results)
      return results unless @exclude_keys&.any?
      names = @exclude_keys.map(&:to_s) - RESERVED_EXCLUDE_KEYS
      return results if names.empty?
      drop = names.to_set
      results.each { |row| recursively_drop_keys!(row, drop) }
      results
    end

    # Reserved fields that {#redact_excluded_keys!} never strips: dropping these
    # would break {#decode} (objectId / className / __type) or remove the
    # required Parse envelope. Both the Parse-format names (objectId, createdAt,
    # updatedAt, ACL) and their Mongo storage-form counterparts (_id,
    # _created_at, _updated_at, _acl) are guarded, so the redaction is safe even
    # if it is ever pointed at a raw Mongo document, and a caller can't break
    # reconstruction by excluding e.g. `:_id`. This is an SDK safety choice, not
    # an assertion about which fields Parse Server's REST `excludeKeys` strips.
    RESERVED_EXCLUDE_KEYS = %w[
      objectId className __type createdAt updatedAt ACL
      _id _created_at _updated_at _acl
    ].freeze

    # Recursively delete every key named in +names+ from a nested
    # Hash/Array structure, in place. Symbol and string keys both match.
    # @param value [Object] a Hash, Array, or scalar
    # @param names [Set<String>] the key names to drop
    # @!visibility private
    def recursively_drop_keys!(value, names)
      case value
      when Hash
        value.reject! { |k, _| names.include?(k.to_s) }
        value.each_value { |v| recursively_drop_keys!(v, names) }
      when Array
        value.each { |v| recursively_drop_keys!(v, names) }
      end
      value
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
        return results_direct(raw: raw, **mongo_direct_auth_kwargs, &block)
      end

      # Auto-route to mongo-direct when the compiled where contains a
      # constraint that Parse Server's REST find layer cannot express
      # (e.g. $geoIntersects with a full $geometry against a non-Point
      # column). Mirrors the existing aggregation auto-route at line
      # ~1321 below — the constraint emits a marker, the query layer
      # detects it, and routing happens transparently. The auth
      # context (use_master_key, scope_to_user, or session_token)
      # decides how ACL simulation runs through mongo-direct.
      if requires_mongo_direct?
        assert_mongo_direct_routable!
        return results_direct(raw: raw, **mongo_direct_auth_kwargs, &block)
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

    # Raised when a query contains a constraint that can only be executed
    # via the mongo-direct path but the caller hasn't enabled master-key
    # mode (or `Parse::MongoDB` isn't configured at all). The auto-route
    # refuses to silently bypass per-row ACL/CLP, so the developer must
    # opt in by setting `use_master_key = true` on the query and ensuring
    # `Parse::MongoDB.configure` has been called.
    class MongoDirectRequired < StandardError; end

    # Raised when a constraint value's shape cannot match the storage
    # form of the targeted column — e.g. bare objectId strings inside
    # `$in`/`$nin` arrays against a pointer column whose target class
    # cannot be inferred. Gated by {Parse.strict_pointer_shapes?}.
    class PointerShapeError < StandardError; end

    # Check if this query contains a constraint that can only be answered
    # via mongo-direct (e.g. `$geoIntersects` with a full `$geometry`
    # against a non-GeoPoint column — an operator Parse Server's REST
    # find layer does not expose). Direct-only constraints emit a
    # `"__mongo_direct_only"` marker which this predicate detects.
    # @return [Boolean]
    def requires_mongo_direct?
      return false if @where.empty?
      # Read from the un-stripped marker hash — `compile_where` removes
      # `__`-prefixed routing markers before they ship to Parse / Mongo.
      markers = compile_markers
      return true if markers.key?("__mongo_direct_only")
      markers.values.any? do |constraint|
        constraint.is_a?(Hash) && constraint.key?("__mongo_direct_only")
      end
    end

    # Whether this query carries a non-master-key auth scope. Used by
    # `#distinct` (and group_by aggregations) to decide whether to
    # auto-promote the REST aggregate path to mongo-direct so the SDK's
    # ACLScope / CLPScope enforcement actually runs. Also detects the
    # fiber-local ambient session set by Parse.with_session so that
    # aggregations inside a with_session block are treated as scoped —
    # consistent with how Parse::Client#request already scopes REST calls.
    # @return [Boolean]
    # @api private
    def distinct_query_is_scoped?
      return true if @session_token.is_a?(String) && !@session_token.empty?
      return true if @acl_user
      return true if @acl_role
      # An ambient Parse.with_session counts as scope ONLY when the query did
      # not explicitly request master-key mode — mirroring Parse::Client#request,
      # where an explicit use_master_key: true is a deliberate admin call that
      # skips the ambient session. Otherwise an admin aggregation inside a
      # with_session block would be wrongly forced to mongo-direct / fail-closed.
      unless use_master_key == true
        ambient = ambient_session_token
        return true if ambient.is_a?(String) && !ambient.empty?
      end
      false
    end

    # Fail closed for a scoped aggregation that would otherwise fall back
    # to REST /aggregate. That endpoint is master-key-only and enforces
    # neither ACL nor CLP, so letting a scoped query through would silently
    # run it unscoped as the master key. Every aggregation terminal that
    # routes a scoped query (aggregate, aggregate_from_query, count,
    # execute_aggregation_pipeline) raises through here.
    # @raise [MongoDirectRequired]
    # @api private
    def raise_scoped_aggregation_requires_mongo_direct!
      raise MongoDirectRequired,
        "[Parse::Query] This scoped aggregation (session_token / " \
        "scope_to_user / scope_to_role, or an active Parse.with_session " \
        "block) requires mongo-direct so the SDK can enforce ACL/CLP. " \
        "Parse Server's REST /aggregate endpoint is master-key-only and " \
        "enforces neither, so routing it there would silently run unscoped " \
        "as the master key. Enable mongo-direct via " \
        "Parse::MongoDB.configure(...), or rewrite without the " \
        "aggregation terminal."
    end

    # Scope a query to a specific user's row-level ACL when it auto-routes
    # through mongo-direct. The SDK records the user, computes the
    # effective `_rperm` allow-set (user objectId + `"*"` + every role
    # name the user inherits via {Parse::Role.all_for_user}), and prepends
    # a `{ _rperm: { $in: ... } }` `$match` to the mongo-direct pipeline
    # at execution time.
    #
    # **What this does NOT replicate:** class-level permissions (CLP),
    # anonymous-user public-access nuances, `beforeFind`/`afterFind`
    # cloud triggers, or any field-level redaction Parse Server might
    # otherwise apply. This is a row-ACL floor, not full enforcement
    # parity with the Parse Server REST path. The intended use case is
    # "I need this mongo-direct-only query from a session-tokened
    # context, and I accept the row-ACL floor as my filter."
    #
    # **Edge case — objects with missing `_rperm`:** Parse Server only
    # writes `_rperm` when an explicit ACL is applied; rows saved with
    # master-key access and no explicit ACL leave the field unset.
    # The injected filter is `{$or: [{_rperm: {$exists: false}},
    # {_rperm: {$in: perms}}]}`, treating missing-`_rperm` rows as
    # public-readable. Apps that store row-level ACL on every object
    # are unaffected by this fallback; apps that mix ACL'd and
    # public-default rows will see both classes of row through the
    # scoped query.
    #
    # The query MUST still satisfy {#assert_mongo_direct_routable!} —
    # either `use_master_key: true` OR `scope_to_user` is set. A call to
    # `scope_to_user` is treated as opt-in to mongo-direct routing for
    # the direct-only constraints in the where clause.
    #
    # @example
    #   Region.query(:area.geo_intersects => route)
    #         .scope_to_user(current_user)
    #         .results
    #
    # @param user [Parse::User, Parse::Pointer] the principal to scope by.
    # @return [self]
    def scope_to_user(user)
      raise ArgumentError, "[Parse::Query] scope_to_user requires a Parse::User or User Pointer." \
        unless user.respond_to?(:id) && user.id.is_a?(String)
      @acl_user = user
      self
    end

    # Role-based ACL scoping for service-account-style queries that
    # need "what would a user holding this role see" without minting a
    # session token or naming a specific user. The SDK uses
    # `Parse::Role#all_parent_role_names` to expand the role's
    # inheritance chain so passing `"scope:admin"` includes any role
    # `"scope:admin"` inherits from (e.g. `"scope:user"`).
    #
    # The resulting permission set is `["*", "role:<name>", ...]` —
    # no user_id slot. Documents whose `_rperm` would only grant a
    # specific user (and not any of the role names) are filtered out
    # of both the top-level result set and embedded sub-documents.
    #
    # Same routing rules as {#scope_to_user}: the query auto-routes
    # through mongo-direct when the where clause contains a
    # direct-only constraint, and the three-layer ACL simulation
    # (top-level `$match`, `$lookup` rewriter, post-fetch redactor)
    # runs through {Parse::ACLScope}.
    #
    # @example
    #   Region.query(:area.geo_intersects => route)
    #         .scope_to_role("scope:admin")
    #         .results
    #
    # @param role [Parse::Role, String] role to scope by. Strings may
    #   be supplied with or without the `"role:"` prefix; the SDK
    #   strips it. Unknown role names raise ArgumentError at first
    #   use.
    # @return [self]
    def scope_to_role(role)
      unless role.is_a?(Parse::Role) || role.is_a?(String) || role.is_a?(Symbol)
        raise ArgumentError, "[Parse::Query] scope_to_role requires a Parse::Role or role-name String."
      end
      # Normalize Symbol at the boundary so downstream
      # Parse::ACLScope#resolve_for_role only ever sees Parse::Role or
      # String. Without normalization, any String-only operation
      # (e.g. #start_with?, #sub) silently NoMethodErrors on Symbol.
      @acl_role = role.is_a?(Symbol) ? role.to_s : role
      self
    end

    # @return [Parse::User, Parse::Pointer, nil] the user the query was
    #   scoped to via {#scope_to_user}, or nil for unscoped queries.
    attr_reader :acl_user

    # @return [Parse::Role, String, Symbol, nil] the role the query
    #   was scoped to via {#scope_to_role}, or nil.
    attr_reader :acl_role

    # Compute the `_rperm` allow-set for {#acl_user}: the user's
    # objectId, `"*"` (public), and `"role:<Name>"` for every role the
    # user inherits via {Parse::Role.all_for_user}. Used by the
    # mongo-direct routing path to prepend the ACL `$match`.
    # @return [Array<String>, nil] the allow-set, or nil when no user
    #   is set.
    # @!visibility private
    def acl_permission_set
      return nil if @acl_user.nil?
      perms = [@acl_user.id, "*"]
      begin
        Parse::Role.all_for_user(@acl_user, max_depth: 5).each do |name|
          perms << "role:#{name}"
        end
      rescue StandardError
        # Best-effort role expansion. A transient lookup failure leaves
        # the user with their direct objectId + "*" allow-set, which
        # still floors the query rather than fails open.
      end
      perms.uniq
    end

    # Assert the conditions required to auto-route a query through
    # mongo-direct are met: a configured mongo-direct connection AND
    # one of three ACL contexts:
    #
    #   * `use_master_key: true` — full bypass (caller-responsible).
    #   * `scope_to_user(user)` — SDK injects `_rperm` from a
    #     pre-resolved User object.
    #   * `session_token=` — SDK resolves the token to a user, expands
    #     roles, injects the three-layer ACL simulation
    #     (top-level `$match`, `$lookup` rewriter, post-fetch
    #     redactor) via {Parse::MongoDB.aggregate}.
    #   * an active `Parse.with_session` block — the fiber-local ambient
    #     session token scopes the read the same way an explicit
    #     `session_token=` would (see {#mongo_direct_auth_kwargs}).
    #
    # Raises a clear {MongoDirectRequired} otherwise.
    # @!visibility private
    def assert_mongo_direct_routable!
      has_session = @session_token.is_a?(String) && !@session_token.empty?
      # An active `Parse.with_session` block scopes the read even on a
      # non-master client (client_mode, or a user-scoped client with no
      # master key), where `server_mode_master` is false. Without this the
      # query would raise instead of running scoped — and on a master
      # client the ambient is what `mongo_direct_auth_kwargs` forwards so
      # the read is scoped rather than silently master.
      has_ambient_session = !ambient_session_token.nil?
      # Mirror the request-layer auth resolution in Parse::Client#request:
      # when the process is in "server mode" — Parse.client_mode == false
      # AND the resolved Parse::Client has a master_key — and the caller
      # hasn't explicitly opted out via `use_master_key = false`, the
      # configured master key is the ambient credential. A mongo-direct
      # query in that posture is authorized by the same key the REST
      # path would have sent; the SDK should not force callers to repeat
      # `use_master_key: true` on every direct query.
      client_has_master_key = begin
        c = client
        c.respond_to?(:master_key) && !c.master_key.to_s.empty?
      rescue StandardError
        false
      end
      server_mode_master = (use_master_key != false) && !Parse.client_mode && client_has_master_key
      unless use_master_key || server_mode_master || @acl_user || @acl_role || has_session || has_ambient_session
        raise MongoDirectRequired,
          "[Parse::Query] This query uses a constraint that can only run " \
          "via mongo-direct. Mongo-direct bypasses Parse Server's enforcement, " \
          "so it requires one of: `use_master_key: true` (full bypass — caller " \
          "responsible for safety), `.scope_to_user(current_user)` (SDK injects " \
          "row-level `_rperm` filter from a pre-resolved User), " \
          "`.scope_to_role(\"admin\")` (SDK injects role-only filter with " \
          "parent-role inheritance), or `session_token = '...'` (SDK resolves " \
          "the token and runs the full three-layer ACL simulation). See " \
          "Parse::Query#scope_to_user, #scope_to_role, and Parse::ACLScope."
      end
      require_relative "mongodb"
      unless defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
        raise MongoDirectRequired,
          "[Parse::Query] This query requires mongo-direct routing but " \
          "`Parse::MongoDB` is not enabled. Call `Parse::MongoDB.configure(...)` " \
          "during application boot, or rewrite the query without the " \
          "direct-only constraint."
      end
    end

    # Compute the auth kwargs to forward when auto-routing through
    # mongo-direct. Resolves the three-way contract between
    # `use_master_key`, `scope_to_user`, and `session_token` so the
    # downstream layers (Parse::MongoDB.aggregate / Parse::ACLScope)
    # see exactly one auth mode.
    #
    #   * `scope_to_user` is set → forward `master: true` to skip the
    #     new ACLScope injection (the legacy pre-build_direct injection
    #     already adds the `_rperm` $match — we don't want to
    #     double-inject).
    #   * `session_token` is set → forward `session_token:` so
    #     Parse::ACLScope runs the full three-layer simulation.
    #   * Otherwise, the fiber-local ambient session set by
    #     `Parse.with_session` is forwarded as `session_token:` (unless
    #     the caller explicitly requested `use_master_key: true`), so a
    #     query that auto-routes to mongo-direct inside a `with_session`
    #     block is scoped to that user — matching what the REST path does
    #     in {Parse::Client#request}.
    #   * Otherwise (master-key path) → forward `master: true`.
    # @!visibility private
    def mongo_direct_auth_kwargs
      if @acl_user
        # Pre-resolved User pointer. Hand it to Parse::ACLScope as
        # acl_user: so the same three-layer simulation runs (top-level
        # $match + $lookup rewriter + post-fetch redactor). This
        # replaces the legacy direct in-pipeline injection in
        # build_direct_mongodb_pipeline so includes-generated $lookup
        # stages get filtered too.
        { acl_user: @acl_user }
      elsif @acl_role
        # Role-only scope: no user_id, just role:<name> with parent
        # inheritance via Parse::Role#all_parent_role_names.
        { acl_role: @acl_role }
      elsif @session_token.is_a?(String) && !@session_token.empty?
        { session_token: @session_token }
      elsif use_master_key != true && (ambient = ambient_session_token)
        # No explicit per-query scope, but a `Parse.with_session` block is
        # active. Mirror Parse::Client#request's precedence (ambient
        # session wins over the server-mode master default) so the read is
        # scoped to that user instead of silently running as master with
        # no ACL/CLP enforcement. An explicit `use_master_key: true` is a
        # deliberate admin call and skips the ambient, exactly as the REST
        # path does.
        { session_token: ambient }
      else
        { master: true }
      end
    end

    # The fiber-local ambient session token set by `Parse.with_session`,
    # or nil. A whitespace-only ambient is treated as absent so it cannot
    # block the master fallback and then fail a later presence check —
    # the same guard {Parse::Client#request} applies.
    # @return [String, nil]
    # @!visibility private
    def ambient_session_token
      return nil unless Parse.respond_to?(:current_session_token)
      ambient = Parse.current_session_token
      ambient if ambient.is_a?(String) && !ambient.strip.empty?
    end

    # Check if this query contains constraints that require aggregation pipeline processing
    # @return [Boolean] true if aggregation pipeline is required
    def requires_aggregation_pipeline?
      return false if @where.empty?

      # Markers (including __aggregation_pipeline) are stripped from the
      # public compile_where path; consult the marker view explicitly.
      markers = compile_markers

      # Check if the marker hash itself has aggregation pipeline marker
      return true if markers.key?("__aggregation_pipeline")

      # Check if any of the constraint values has aggregation pipeline marker
      markers.values.any? { |constraint|
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
    # @param max_time_ms [Integer, nil] optional server-side time limit in milliseconds.
    #   When provided, MongoDB will cancel the aggregation if it exceeds this budget and
    #   {Parse::MongoDB::ExecutionTimeout} is raised. Pass +nil+ (the default) for no cap.
    # @yield a block to iterate for each object that matched the query
    # @return [Array<Parse::Object>] if raw is false, a list of Parse::Object subclasses
    # @return [Array<Hash>] if raw is true, Parse-formatted JSON hashes
    # @raise [Parse::MongoDB::GemNotAvailable] if mongo gem is not installed
    # @raise [Parse::MongoDB::NotEnabled] if direct MongoDB is not configured
    # @raise [Parse::MongoDB::ExecutionTimeout] if the query exceeds max_time_ms
    # @note This is a read-only operation. Direct MongoDB queries cannot modify data.
    # @see Parse::MongoDB.configure
    def results_direct(raw: false, max_time_ms: nil, session_token: nil, master: nil, acl_user: nil, acl_role: nil, &block)
      require_relative "mongodb"
      Parse::MongoDB.require_gem!

      unless Parse::MongoDB.available?
        raise Parse::MongoDB::NotEnabled,
          "Direct MongoDB queries are not enabled. " \
          "Call Parse::MongoDB.configure(uri: 'mongodb://...', enabled: true) first."
      end

      # Build the aggregation pipeline for direct MongoDB execution
      pipeline = build_direct_mongodb_pipeline

      # When no explicit auth kwargs are provided by the caller, derive them
      # from the query's own auth state (session_token, acl_user, acl_role, or
      # master key) via mongo_direct_auth_kwargs — exactly the same fallback
      # used by distinct_direct, count_direct, and the requires_mongo_direct?
      # auto-route in results(). Without this, a plain .results_direct call on
      # a master-key client would resolve as anonymous and have the ACL match
      # stage filter out every row whose _rperm is [] (the default for objects
      # created without an explicit public-read ACL).
      if session_token.nil? && master.nil? && acl_user.nil? && acl_role.nil?
        auth = mongo_direct_auth_kwargs
        session_token = auth[:session_token]
        master        = auth[:master]
        acl_user      = auth[:acl_user]
        acl_role      = auth[:acl_role]
      end

      # Execute the aggregation directly on MongoDB. The pipeline was built
      # entirely from SDK constraint translation (no user-supplied stages),
      # so legitimate +_rperm+/+_wperm+ references emitted by
      # {#readable_by_role} and friends are sanctioned. The DENIED_OPERATORS
      # walk still runs at the MongoDB layer. When `session_token:` or
      # `master:` is supplied, Parse::MongoDB.aggregate adds the
      # three-layer ACL simulation (top-level $match, $lookup rewriter,
      # post-fetch redactor) before/after the pipeline executes.
      raw_results = Parse::MongoDB.aggregate(@table, pipeline,
                                             max_time_ms: max_time_ms,
                                             allow_internal_fields: true,
                                             session_token: session_token,
                                             master: master,
                                             acl_user: acl_user,
                                             acl_role: acl_role,
                                             read_preference: @read_preference,
                                             hint: @hint)

      # Convert MongoDB documents to Parse format
      parse_results = Parse::MongoDB.convert_documents_to_parse(raw_results, @table)

      # Honor exclude_keys on the mongo-direct path: the pipeline can only
      # project the keys allowlist, so apply the denylist here as a post-fetch
      # sanitize over the Parse-format hashes (before the raw/decode fork so
      # both shapes are redacted). Does not alter the MongoDB query.
      redact_excluded_keys!(parse_results)

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

      count =
        case limit_or_constraints
        when Numeric then limit_or_constraints.to_i
        when String
          unless limit_or_constraints =~ /\A-?\d+\z/
            raise ArgumentError,
                  "Invalid first_direct() argument #{limit_or_constraints.inspect}. " \
                  "Expected an Integer, a numeric String, or a Hash of constraints."
          end
          limit_or_constraints.to_i
        else
          raise ArgumentError,
                "Invalid first_direct() argument #{limit_or_constraints.inspect}. " \
                "Expected an Integer, a numeric String, or a Hash of constraints."
        end
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
    def count_direct(session_token: nil, master: nil, acl_user: nil, acl_role: nil)
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

      # When no explicit auth kwargs are provided, derive them from the
      # query's own auth state — same fallback as results_direct.
      if session_token.nil? && master.nil? && acl_user.nil? && acl_role.nil?
        auth = mongo_direct_auth_kwargs
        session_token = auth[:session_token]
        master        = auth[:master]
        acl_user      = auth[:acl_user]
        acl_role      = auth[:acl_role]
      end

      # SDK-built pipeline only — see results_direct for rationale.
      # ACL simulation runs inside Parse::MongoDB.aggregate when
      # session_token: or master: is supplied.
      raw_results = Parse::MongoDB.aggregate(@table, pipeline,
                                             allow_internal_fields: true,
                                             session_token: session_token,
                                             master: master,
                                             acl_user: acl_user,
                                             acl_role: acl_role,
                                             read_preference: @read_preference,
                                             hint: @hint)

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
    def distinct_direct(field, return_pointers: false, order: nil,
                        session_token: nil, master: nil, acl_user: nil, acl_role: nil)
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

      sort_dir = distinct_sort_direction(order)

      # Convert field name for direct MongoDB access
      mongo_field = convert_field_for_direct_mongodb(Query.format_field(field))

      # Build the base pipeline with match constraints
      pipeline = []

      # Add match stage from query constraints. `compile_where` already
      # strips `__`-prefixed routing markers, so the result is safe to
      # forward to MongoDB.
      compiled_where = compile_where
      if compiled_where.present?
        mongo_constraints = convert_constraints_for_direct_mongodb(compiled_where)
        pipeline << { "$match" => mongo_constraints } if mongo_constraints.any?
      end

      # Add group, optional sort, and project stages for distinct
      pipeline << { "$group" => { "_id" => "$#{mongo_field}" } }
      pipeline << { "$sort" => { "_id" => sort_dir } } if sort_dir
      pipeline << { "$project" => { "_id" => 0, "value" => "$_id" } }

      # SDK-built pipeline only — see results_direct for rationale.
      # Forward auth kwargs so Parse::MongoDB.aggregate runs the
      # three-layer ACL + CLP + protectedFields simulation for scoped
      # agents. Without this, distinct silently returns the unscoped
      # universe (CLP-1 enforcement asymmetry vs. #count / #results).
      # When no explicit auth kwargs are provided, derive from the
      # query's own auth state — same fallback as results_direct.
      if session_token.nil? && master.nil? && acl_user.nil? && acl_role.nil?
        auth = mongo_direct_auth_kwargs
        session_token = auth[:session_token]
        master        = auth[:master]
        acl_user      = auth[:acl_user]
        acl_role      = auth[:acl_role]
      end
      raw_results = Parse::MongoDB.aggregate(@table, pipeline,
                                             allow_internal_fields: true,
                                             read_preference: @read_preference,
                                             hint: @hint,
                                             session_token: session_token,
                                             master: master,
                                             acl_user: acl_user,
                                             acl_role: acl_role)

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
    # @param order [Symbol, nil] forwarded to {#distinct_direct}.
    # @return [Array] array of distinct values, with pointer fields as Parse::Pointer objects
    # @see #distinct_direct
    def distinct_direct_pointers(field, order: nil,
                                 session_token: nil, master: nil, acl_user: nil, acl_role: nil)
      distinct_direct(field, return_pointers: true, order: order,
                      session_token: session_token, master: master,
                      acl_user: acl_user, acl_role: acl_role)
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

        # SDK-built pipeline only — see results_direct for rationale.
        raw_results = Parse::MongoDB.aggregate(@table, pipeline,
                                               allow_internal_fields: true,
                                               read_preference: @read_preference,
                                             hint: @hint)

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
        # Forward the query's read_preference (set via `#read_pref`).
        # Without this, Atlas Search calls reached through the Query
        # bridge silently fall back to the client default even though
        # the query explicitly opted in to a secondary read — the
        # mongo-direct path (`#results_direct`) honors it, this one
        # used to drop it on the floor.
        if @read_preference && !options.key?(:read_preference)
          options[:read_preference] = @read_preference
        end

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
      # Forward the query's read_preference (set via `#read_pref`).
      # See #atlas_search for the parity rationale.
      if @read_preference && !options.key?(:read_preference)
        options[:read_preference] = @read_preference
      end

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
      # Forward the query's read_preference (set via `#read_pref`).
      # See #atlas_search for the parity rationale.
      if @read_preference && !options.key?(:read_preference)
        options[:read_preference] = @read_preference
      end

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

      # Mirror the REST compile() behavior: ensure each top-level included field
      # is also in @keys so the $project stage below does not strip the pointer
      # that the $lookup stage is supposed to expand.
      merge_includes_into_keys!

      # Compile the where clause and convert for direct MongoDB access.
      # `compile_where` already strips `__`-prefixed routing markers; use
      # `compile_markers` to recover the unfiltered hash for the
      # __aggregation_pipeline extraction below.
      compiled_where = compile_where
      markers = compile_markers

      # Note: the `_rperm` injection for scope_to_user no longer
      # happens here. It moved to Parse::MongoDB.aggregate via the
      # acl_user: kwarg so the same three-layer ACL simulation
      # (top-level $match + $lookup rewriter + post-fetch redactor)
      # runs for scope_to_user, session_token, and the public-only
      # fallback alike. See {#mongo_direct_auth_kwargs}.

      if compiled_where.present?
        # Convert field names and values for direct MongoDB access.
        # `compiled_where` is already marker-free, so no further
        # reject pass is required.
        mongo_constraints = convert_constraints_for_direct_mongodb(compiled_where)
        pipeline << { "$match" => mongo_constraints } if mongo_constraints.any?
      end

      # Handle aggregation pipeline stages (from empty_or_nil, set_equals, etc.)
      if markers.key?("__aggregation_pipeline")
        markers["__aggregation_pipeline"].each do |stage|
          pipeline << convert_stage_for_direct_mongodb(stage)
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

      # $relatedTo resolves a Parse Relation, which is stored in the
      # `_Join:<key>:<ParentClass>` collection — a join the SDK does NOT
      # translate on the mongo-direct path. Passed through verbatim it reaches
      # MongoDB as an unknown `$match` operator and fails with an opaque error;
      # and any future attempt to rewrite it into a `$lookup` would have to
      # re-implement the `_rperm` / protectedFields enforcement that the rest of
      # this path applies post-fetch. Parse Server's own `$relatedTo` was found
      # to bypass exactly that enforcement (GHSA-wmwx-jr2p-4j4r), so fail closed
      # here with a clear message rather than risk a silent leak: this query
      # must run via REST (the default), where Parse Server resolves the
      # relation under its own ACL / CLP enforcement.
      if constraints.key?("$relatedTo") || constraints.key?(:"$relatedTo")
        raise ArgumentError,
          "[Parse::Query] $relatedTo cannot run on the mongo-direct path; a " \
          "Parse Relation is resolved server-side via its join collection. Run " \
          "this query via REST (omit `mongo_direct:` / `.results_direct` and any " \
          "direct-only constraint), or express the membership as an `$inQuery` " \
          "against the relation's join collection."
      end

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

      # Any field name starting with underscore is non-user-facing and is
      # passed through verbatim. Parse user-facing properties never start
      # with `_` (the SDK columnizes snake_case to camelCase before save,
      # and Parse Server reserves the leading-underscore namespace), so a
      # field that does is one of:
      #   - a MongoDB/Parse Server internal column (`_id`, `_created_at`,
      #     `_acl`, `_rperm`, `_wperm`, `_hashed_password`,
      #     `_session_token`, `_email_verify_token`, ...)
      #   - a Parse-on-Mongo pointer storage column (`_p_<field>`)
      #   - an SDK-built pipeline-temp alias such as the
      #     `_lookup_<field>_result` / `_lookup_<field>_id` aliases that
      #     `extract_subquery_to_lookup_stages` introduces when an
      #     `$inQuery` constraint compiles to a `$lookup` stage
      # Columnizing any of these would corrupt the reference: the
      # previous behavior of routing `_lookup_project_result` through
      # `format_field` produced `lookupProjectResult` (leading underscore
      # stripped, snake_case to camelCase), and the post-lookup
      # `$match` then asked MongoDB for a column that didn't exist, so
      # every document silently satisfied the constraint.
      return field_str if field_str.start_with?("_")

      # Apply field formatting for regular fields
      formatted = Query.format_field(field)

      case formatted
      when "objectId"
        "_id"
      when "createdAt"
        "_created_at"
      when "updatedAt"
        "_updated_at"
      else
        # Schema-aware passthrough: only rewrite names that correspond
        # to a declared Parse property (or the universal built-ins
        # handled above). Anything else is treated as a pipeline-local
        # alias — `$group` accumulator name, `$project` computed field,
        # `$addFields` output — and the literal text passes through so
        # the reference matches the output key the upstream stage
        # produced.
        #
        # Concretely: `$status` on a class that declares `status`
        # remains `status` (`format_field` is a no-op for already-
        # camelCase names); `$author` on a class that declares a
        # pointer `author` becomes `$_p_author`; `$contributor_set`
        # (an alias the caller introduced in `$group`) stays
        # `$contributor_set` because no such property exists in the
        # schema. Callers reading the result row by `row[alias_name]`
        # see exactly the spelling they wrote into the pipeline.
        #
        # @note Two documented limitations of the schema-aware rule:
        #
        # 1. **Alias shadowing.** An alias whose name shadows a
        #    declared Parse property (`$group { author: ... }` where
        #    `author` is a pointer) is treated as the property —
        #    downstream `$author` references resolve to `$_p_author`,
        #    the storage column, not the alias. Avoid alias names that
        #    collide with declared property names. The same naming
        #    constraint MongoDB aggregation pipelines have generally;
        #    not unique to parse-stack.
        #
        # 2. **Undeclared server columns.** Conversely, a `$field`
        #    reference whose name corresponds to a column that exists
        #    on the server but is NOT declared as a property on the
        #    Ruby model passes through verbatim. The schema we consult
        #    is the SDK-side property registry; we do not introspect
        #    the live server schema on every translation. If you need
        #    references in mongo-direct pipelines to translate
        #    snake_case → camelCase or take a `_p_*` prefix, declare
        #    the corresponding property on the Ruby model. Workaround
        #    without declaring: write the storage-column name directly
        #    (`$_p_author`, `$companyName`), which short-circuits the
        #    walker via the leading-underscore / already-formatted
        #    paths.
        return field_str unless field_is_known_to_schema?(formatted)

        if field_is_pointer?(formatted)
          "_p_#{formatted}"
        else
          formatted
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
    #
    # Projection-shape stages ($project, $addFields, $set, $replaceRoot,
    # $replaceWith) and accumulator/grouping stages ($group) carry
    # aggregation expressions that can reference fields via $fieldName
    # strings. These references must be rewritten to the direct-MongoDB
    # column form (camelCase, _p_* for pointers, _id/_created_at/_updated_at
    # for built-ins). The rewrite walks recursively into $cond / $eq /
    # $switch / $expr argument arrays so a nested reference is not missed.
    # See {#rewrite_expression_for_direct_mongodb}.
    #
    # $match is special: its top-level keys are field-name constraints
    # (rewritten via the constraint converter), but the value of a top-level
    # $expr is an aggregation expression that must also be walked.
    # @param stage [Hash] a single pipeline stage
    # @return [Hash] the converted stage
    # @api private
    def convert_stage_for_direct_mongodb(stage)
      return stage unless stage.is_a?(Hash)

      result = {}
      stage.each do |operator, value|
        case operator.to_s
        when "$match"
          result[operator] = convert_match_for_direct_mongodb(value)
        when "$project"
          result[operator] = convert_projection_for_direct_mongodb(value)
        when "$sort"
          result[operator] = convert_sort_for_direct_mongodb(value)
        when "$group"
          result[operator] = convert_group_for_direct_mongodb(value)
        when "$addFields", "$set"
          result[operator] = convert_addfields_for_direct_mongodb(value)
        when "$replaceRoot"
          result[operator] = convert_replace_root_for_direct_mongodb(value)
        when "$replaceWith"
          # $replaceWith's argument is the new-root expression directly.
          result[operator] = rewrite_expression_for_direct_mongodb(value)
        else
          result[operator] = value
        end
      end
      result
    end

    # Convert a $match stage for direct MongoDB. Rewrites top-level
    # field-name keys via {#convert_constraints_for_direct_mongodb} and
    # additionally walks the value of a top-level $expr as an aggregation
    # expression so nested $fieldName references are rewritten.
    # @api private
    def convert_match_for_direct_mongodb(match)
      converted = convert_constraints_for_direct_mongodb(match)
      return converted unless converted.is_a?(Hash)

      # The constraint converter passes $expr through unchanged. Rewrite
      # its value here so e.g. {$expr: {$eq: ["$author", "$approver"]}}
      # becomes {$expr: {$eq: ["$_p_author", "$_p_approver"]}}.
      expr_key = converted.key?("$expr") ? "$expr" : (converted.key?(:"$expr") ? :"$expr" : nil)
      return converted unless expr_key

      result = converted.dup
      result[expr_key] = rewrite_expression_for_direct_mongodb(converted[expr_key])
      result
    end

    # Convert projection fields for direct MongoDB. Output-key aliases
    # pass through verbatim — what the caller writes is what the result
    # row will be keyed by. Values that are aggregation expressions
    # (e.g. `{ "$cond": [...] }`) are walked recursively so nested
    # `$fieldName` references reach the correct storage column via the
    # schema-aware rewriter in {#convert_field_for_direct_mongodb}.
    # @api private
    def convert_projection_for_direct_mongodb(projection)
      return projection unless projection.is_a?(Hash)

      result = {}
      projection.each do |field, value|
        result[field] = rewrite_expression_for_direct_mongodb(value)
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

    # Convert $group stage for direct MongoDB. Output-alias keys
    # (`_id`, accumulator names like `contributor_set`) pass through
    # verbatim so the result row uses whatever spelling the caller
    # wrote. Each value — the `_id` group-key expression and every
    # accumulator expression — is walked as an aggregation expression
    # so `$field` references inside reach the correct storage column
    # (`_p_*` for pointers, `_id`/`_created_at`/`_updated_at` for
    # built-ins, untouched for unknown names i.e. pipeline-local
    # aliases) via the schema-aware
    # {#convert_field_for_direct_mongodb}.
    # @api private
    def convert_group_for_direct_mongodb(group)
      return group unless group.is_a?(Hash)

      result = {}
      group.each do |field, value|
        result[field] = rewrite_expression_for_direct_mongodb(value)
      end
      result
    end

    # Convert a $addFields / $set stage for direct MongoDB. Same shape
    # as $project: `{ aliasName => <expression> }`. Output aliases pass
    # through verbatim; each value is walked as an aggregation
    # expression so storage-column references inside reach the correct
    # column via the schema-aware {#convert_field_for_direct_mongodb}.
    # @api private
    def convert_addfields_for_direct_mongodb(spec)
      return spec unless spec.is_a?(Hash)

      result = {}
      spec.each do |field, value|
        result[field] = rewrite_expression_for_direct_mongodb(value)
      end
      result
    end

    # Convert a $replaceRoot stage for direct MongoDB. Argument shape is
    # `{ newRoot: <expression> }`; only the newRoot value is an
    # expression. (Use {#rewrite_expression_for_direct_mongodb} directly
    # for $replaceWith, whose argument is the expression itself.)
    # @api private
    def convert_replace_root_for_direct_mongodb(spec)
      return rewrite_expression_for_direct_mongodb(spec) unless spec.is_a?(Hash)

      new_root_key = spec.key?("newRoot") ? "newRoot" : (spec.key?(:newRoot) ? :newRoot : nil)
      return rewrite_expression_for_direct_mongodb(spec) unless new_root_key

      result = spec.dup
      result[new_root_key] = rewrite_expression_for_direct_mongodb(spec[new_root_key])
      result
    end

    # Recursively rewrite field references inside an aggregation expression
    # to their direct-MongoDB column names.
    #
    # Walks Strings, Arrays, and Hashes:
    # - A String starting with `$` (but not `$$`, which denotes a `let`
    #   variable or system variable like `$$ROOT`) is treated as a field
    #   reference. Its root path segment is rewritten via
    #   {#convert_field_for_direct_mongodb}, preserving any dot-delimited
    #   tail. Already-rewritten `$_p_*` references pass through unchanged.
    # - Arrays and Hashes are recursed into, with one exception: the
    #   argument of `$literal` is a string constant, not a field
    #   reference, and must not be rewritten.
    # @param expr [Object] any node within an aggregation expression
    # @return [Object] the rewritten expression (input is not mutated)
    # @api private
    def rewrite_expression_for_direct_mongodb(expr)
      case expr
      when String
        return expr unless expr.start_with?("$")
        # $$varName (let bindings) and $$ROOT / $$CURRENT / $$NOW etc.
        return expr if expr.start_with?("$$")
        # Split off the root path segment so `$user.name` rewrites only
        # the root: `$_p_user.name`. Internal helper handles _p_* and
        # built-in passthroughs idempotently.
        head, sep, tail = expr[1..-1].partition(".")
        "$#{convert_field_for_direct_mongodb(head)}#{sep}#{tail}"
      when Array
        expr.map { |e| rewrite_expression_for_direct_mongodb(e) }
      when Hash
        result = {}
        expr.each do |k, v|
          # `$literal` wraps a string constant; its argument is not a
          # field reference and must be preserved verbatim.
          result[k] = k.to_s == "$literal" ? v : rewrite_expression_for_direct_mongodb(v)
        end
        result
      else
        expr
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
    # @param use_master_key [Boolean] an intent assertion, NOT a
    #   per-subscription elevation. Parse Server resolves `masterKey`
    #   once, at connect time, from the LiveQuery connect frame; the
    #   subscribe frame never carries it. This flag therefore only has
    #   effect when the underlying client is itself an admin connection
    #   (`Parse::LiveQuery::Client.new(use_master_key: true)` with a
    #   master key), in which case the entire socket is already elevated
    #   and ALL its subscriptions bypass ACL/CLP. On a non-admin
    #   connection `use_master_key: true` does not elevate the
    #   subscription and emits a security warning. A single socket cannot
    #   mix scoped and admin subscriptions — use separate connections for
    #   end-user (session-token-scoped) versus administrative
    #   (master-key-scoped) work.
    # @yield [subscription] runs the block with the freshly-constructed
    #   {Parse::LiveQuery::Subscription} BEFORE the subscribe frame is
    #   sent so caller-registered callbacks are wired before any server
    #   events can arrive. Optional.
    # @return [Parse::LiveQuery::Subscription] the subscription object
    # @see Parse::LiveQuery::Subscription
    def subscribe(fields: nil, keys: nil, watch: nil, session_token: nil, client: nil, use_master_key: false, &block)
      require_relative "live_query"

      lq_client = client || Parse::LiveQuery.client
      lq_client.subscribe(
        @table,
        where: compile_where,
        fields: fields,
        keys: keys,
        watch: watch,
        session_token: session_token || @session_token,
        use_master_key: use_master_key,
        &block
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
      warn_if_public_explain_restricted!
      compiled_query = compile
      compiled_query[:explain] = true
      response = client.find_objects(@table, compiled_query.as_json, headers: _headers, **_opts)
      if response.error?
        # Parse Server 9.0+ defaults `allowPublicExplain` to false, so a
        # non-master explain that worked on 8.x now returns a permission
        # error. Surface that as actionable guidance instead of a bare 403.
        if response.respond_to?(:permission_denied?) && response.permission_denied?
          puts "[ParseQuery:Explain] #{response.error} — Parse Server 9.0+ defaults " \
               "`allowPublicExplain` to false; query explain now requires the master key " \
               "(use_master_key: true) or `allowPublicExplain: true` in the server's " \
               "databaseOptions."
        else
          puts "[ParseQuery:Explain] #{response.error}"
        end
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
    #   aggregation = Document.query.aggregate(pipeline)
    #   results = aggregation.results
    #   raw_results = aggregation.raw
    #   pointer_results = aggregation.result_pointers
    #
    #   # With verbose output
    #   aggregation = Document.query.aggregate(pipeline, verbose: true)
    #   # With MongoDB direct (required for $inQuery constraints in aggregation)
    #   aggregation = Document.query.aggregate(pipeline, mongo_direct: true)
    # Pipeline stages that are blocked to prevent data exfiltration or destructive operations.
    # @deprecated Retained for backwards compatibility. The canonical list now lives in
    #   {Parse::PipelineSecurity::DENIED_OPERATORS} and is enforced recursively, not only
    #   at the top-level stage.
    BLOCKED_PIPELINE_STAGES = Parse::PipelineSecurity::DENIED_OPERATORS

    def aggregate(pipeline, verbose: nil, mongo_direct: nil, rewrite_lookups: nil, raw_values: false, raw_field_names: false)
      validate_pipeline!(pipeline)

      # Auto-rewrite LLM-style $lookup stages against logical Parse class
      # names into the Parse-on-Mongo column form (_p_*/parseReference) when
      # the foreign class declares parse_reference. Idempotent on already-
      # rewritten input. Controlled by Parse.rewrite_lookups (default true)
      # or the per-call `rewrite_lookups:` kwarg.
      pipeline = Parse::LookupRewriter.auto_rewrite(
        pipeline, class_name: @table, enabled: rewrite_lookups,
      )

      # Automatically prepend query constraints as pipeline stages
      complete_pipeline = []
      lookup_stages = []  # Track if we have $inQuery constraints

      # Add $match stage from where constraints if any exist
      unless @where.empty?
        # `compile_where` is marker-free; `compile_markers` carries the
        # __aggregation_pipeline stages we need to extract below.
        where_clause = compile_where
        markers = compile_markers
        if where_clause.any? || markers.key?("__aggregation_pipeline")
          # Collect match conditions and stages
          initial_match_conditions = []
          aggregation_match_conditions = []
          non_match_stages = []
          post_lookup_match = {}

          # `where_clause` is already marker-free; treat as regular constraints.
          regular_constraints = where_clause

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

          # Extract aggregation pipeline stages from the marker view.
          if markers.key?("__aggregation_pipeline")
            markers["__aggregation_pipeline"].each do |stage|
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

      # Optimize pipeline by merging consecutive $match stages
      complete_pipeline = deduplicate_consecutive_match_stages(complete_pipeline)

      # Auto-detect whether this aggregation must run via the direct-MongoDB
      # path instead of Parse Server's REST /aggregate endpoint. Three
      # independent triggers, each of which REST /aggregate cannot serve:
      #
      #   * $inQuery / $notInQuery → $lookup stages (the original trigger).
      #   * An SDK-injected ACL $match on the internal _rperm / _wperm columns
      #     (readable_by / publicly_readable / writable_by and friends). Parse
      #     Server's REST aggregate rejects a $match on those columns.
      #   * A scoped query (session_token / scope_to_user / scope_to_role).
      #     REST /aggregate is master-key-only and enforces NEITHER ACL NOR
      #     CLP, so a scoped aggregate sent over REST silently runs unscoped
      #     as the master key — leaking sums/min/max/distinct over rows the
      #     caller cannot read. This is the same enforcement asymmetry the
      #     #distinct / #count / #results auto-routes already guard against;
      #     the scalar terminals (sum/average/min/max/count_distinct) all
      #     funnel through here, so routing them here fixes every one.
      #
      # `allow_internal_fields` is forwarded for internal-field pipelines: the
      # caller-supplied `pipeline` arg was validated above (line ~3343) with
      # the internal-fields denylist active, so any _rperm/_wperm reference in
      # the merged pipeline is provably SDK-injected, never user input.
      uses_internal_fields = pipeline_uses_internal_fields?(complete_pipeline)
      scoped = distinct_query_is_scoped?
      mongo_ready = defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
      use_mongo_direct = mongo_direct

      if scoped
        # A scoped aggregation (session_token / scope_to_user / scope_to_role)
        # must NEVER reach Parse Server's REST /aggregate endpoint — it is
        # master-key-only and enforces NEITHER ACL NOR CLP, so it would run
        # unscoped as the master key. This holds even when the caller
        # explicitly passes `mongo_direct: false`: an explicit false cannot
        # opt a scoped query out of ACL/CLP enforcement. Promote to mongo-
        # direct, or fail closed when direct Mongo is unavailable (refuse
        # rather than leak unscoped rows).
        if mongo_ready
          use_mongo_direct = true
        else
          raise_scoped_aggregation_requires_mongo_direct!
        end
      elsif use_mongo_direct.nil?
        # Unscoped auto-routing: $inQuery/$notInQuery → $lookup pipelines and
        # SDK-injected internal-field ($rperm/_wperm) pipelines can't be served
        # by REST /aggregate, so prefer mongo-direct when available. An unscoped
        # internal-field pipeline keeps the REST fallback (a master-key
        # correctness edge, not an enforcement bypass).
        if (lookup_stages && lookup_stages.any?) || uses_internal_fields
          use_mongo_direct = true if mongo_ready
        end
      end

      # When the pipeline is bound for direct MongoDB, translate every stage
      # through the direct-MongoDB field rewriter so user-supplied stages
      # (which use logical Parse field names like `$author`) reach the
      # correct on-disk columns (`$_p_author`). The Parse Server route does
      # not need this — Parse Server applies its own translation on the
      # aggregate endpoint — so the rewrite is gated on use_mongo_direct.
      if use_mongo_direct
        complete_pipeline = translate_pipeline_for_direct_mongodb(complete_pipeline)
      end

      Aggregation.new(self, complete_pipeline, verbose: verbose, mongo_direct: use_mongo_direct || false,
                      allow_internal_fields: uses_internal_fields,
                      raw_values: raw_values, raw_field_names: raw_field_names)
    end

    # Apply the direct-MongoDB stage converter to every stage in a pipeline.
    # Idempotent on already-translated input (the per-stage converter
    # passes `_p_*` references through unchanged).
    # @param pipeline [Array<Hash>] aggregation pipeline
    # @return [Array<Hash>] a new pipeline with each stage translated
    # @api private
    def translate_pipeline_for_direct_mongodb(pipeline)
      return pipeline unless pipeline.is_a?(Array)
      pipeline.map { |stage| convert_stage_for_direct_mongodb(stage) }
    end

    # Validates that a pipeline does not contain dangerous operators. Uses the
    # permissive mode of {Parse::PipelineSecurity} (recursive denylist for $where,
    # $function, $accumulator, $out, $merge, $collMod, $createIndex, $dropIndex)
    # so that user code passing uncommon-but-legitimate read stages like
    # $densify or $fill continues to work. Strict allowlist validation is
    # available via {Parse::PipelineSecurity.validate_pipeline!} for callers
    # that want to opt in.
    #
    # @note Permissive mode does NOT block `$lookup`, `$graphLookup`, or
    #   `$unionWith` — these are legitimate read stages but can cross
    #   collection boundaries that Parse ACL/CLP does not enforce. Do not
    #   pass raw attacker-controlled input into {#aggregate}; construct the
    #   pipeline in SDK code and interpolate only validated values.
    #
    # @param pipeline [Array<Hash>] the aggregation pipeline stages.
    # @raise [ArgumentError] if a blocked stage or dangerous operator is found.
    def validate_pipeline!(pipeline)
      Parse::PipelineSecurity.validate_filter!(pipeline)
    rescue Parse::PipelineSecurity::Error => e
      raise ArgumentError, e.message
    end

    # @deprecated Retained for backwards compatibility. Use
    #   {Parse::PipelineSecurity.validate_filter!} for new code.
    # @param hash [Hash] the hash to check.
    # @raise [ArgumentError] if $where (or any other denied operator) is found.
    def validate_no_where_operator!(hash)
      Parse::PipelineSecurity.validate_filter!(hash)
    rescue Parse::PipelineSecurity::Error => e
      raise ArgumentError, e.message
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

      # `allow_internal_fields` is computed from the SDK-built portion ONLY
      # (before appending caller stages): build_query_aggregate_pipeline emits
      # the _rperm/_wperm $match for readable_by/etc., but `additional_stages`
      # is caller-supplied and NOT validated here, so we must not sanction an
      # internal-field reference the caller smuggled in. A scoped query still
      # routes to mongo-direct regardless (so ACL/CLP enforcement runs).
      uses_internal_fields = pipeline_uses_internal_fields?(pipeline)

      # Append any additional stages
      pipeline.concat(additional_stages) if additional_stages.any?

      # Same routing contract as #aggregate: $lookup subqueries, an SDK ACL
      # $match, or a scoped query each require the direct-MongoDB path (REST
      # /aggregate cannot express _rperm/_wperm and is master-key-only/
      # unenforced). A scoped query fails closed when mongo-direct is
      # unavailable rather than silently running unscoped as master.
      scoped = distinct_query_is_scoped?
      mongo_ready = defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
      use_mongo_direct = mongo_direct

      if scoped
        # A scoped aggregation must never reach REST /aggregate (master-key-
        # only, unenforced) — not even when the caller explicitly passes
        # mongo_direct: false. Promote to mongo-direct, or fail closed.
        if mongo_ready
          use_mongo_direct = true
        else
          raise_scoped_aggregation_requires_mongo_direct!
        end
      elsif use_mongo_direct.nil?
        if has_lookup_stages || uses_internal_fields
          use_mongo_direct = true if mongo_ready
        end
      end

      # Create Aggregation directly to avoid double-applying constraints
      Aggregation.new(self, pipeline, verbose: verbose, mongo_direct: use_mongo_direct || false,
                      allow_internal_fields: uses_internal_fields)
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

      # Fold in SDK-built aggregation-pipeline marker stages (the _rperm/_wperm
      # $match emitted by readable_by/publicly_readable/etc., plus set-equality
      # and empty_or_nil markers). `compile_where` strips these markers, so
      # without this extraction an ACL filter on `aggregate_from_query` would
      # be silently dropped — the same omission that affected `Query#count`.
      markers = compile_markers
      if markers.key?("__aggregation_pipeline")
        markers["__aggregation_pipeline"].each { |stage| pipeline << stage }
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

      # When the SDK-built pipeline references internal ACL columns
      # (_rperm/_wperm via readable_by/writable_by/publicly_readable and
      # friends, or _acl), the mongo-direct sink must be told these
      # references are sanctioned so the PipelineSecurity internal-fields
      # denylist lets them through. The pipeline here is built entirely
      # from SDK constraint translation (no caller-supplied stages), so
      # this is safe — same posture as results_direct/count_direct.
      uses_internal_fields = pipeline_uses_internal_fields?(pipeline)
      scoped = distinct_query_is_scoped?

      # Check for explicit mongo_direct preference first
      if defined?(@acl_query_mongo_direct) && !@acl_query_mongo_direct.nil?
        use_mongo_direct = @acl_query_mongo_direct
      elsif defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
        # Auto-detect based on pipeline contents and query scope
        if scoped || has_lookup_stages || uses_internal_fields
          use_mongo_direct = true
        end
      elsif scoped
        # Same fail-closed contract as #aggregate / #aggregate_from_query:
        # a scoped pipeline must not fall back to REST /aggregate, which
        # would drop the scope and return rows the caller cannot read.
        raise_scoped_aggregation_requires_mongo_direct!
      end

      # Create Aggregation directly to avoid double-applying constraints
      # The aggregate() method would redundantly add where constraints again
      Aggregation.new(self, pipeline, verbose: @verbose_aggregate, mongo_direct: use_mongo_direct,
                      allow_internal_fields: uses_internal_fields)
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
      # `compile_where` is already marker-free; `compile_markers` retains
      # the __aggregation_pipeline marker we need to extract stages from.
      compiled_where = compile_where
      markers = compile_markers
      has_lookup_stages = false

      # Collect match conditions and stages
      initial_match_conditions = []
      aggregation_match_conditions = []
      non_match_stages = []
      lookup_stages = []
      post_lookup_match = {}

      # `compiled_where` is already marker-free; use as-is.
      regular_constraints = compiled_where

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
      if markers.key?("__aggregation_pipeline")
        markers["__aggregation_pipeline"].each do |stage|
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

    # Ensures every top-level field referenced by an `include` is also present
    # in `keys`. Only runs when `keys` has already been set — without a keys
    # allowlist, all fields are returned and the merge is unnecessary.
    # @!visibility private
    def merge_includes_into_keys!
      return if @keys.nil? || @keys.empty?
      return if @includes.nil? || @includes.empty?

      @includes.each do |inc|
        top = inc.to_s.split(".", 2).first
        next if top.nil? || top.empty?
        sym = top.to_sym
        @keys.push(sym) unless @keys.include?(sym)
      end
      @keys.uniq!
    end
    private :merge_includes_into_keys!

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

      # When a `keys` allowlist is set alongside `include`, the parent pointer
      # field must also be in `keys` or Parse Server strips it before expanding
      # the include. Auto-add the top-level segment of each include so partial
      # fetches don't silently drop included pointers.
      merge_includes_into_keys!

      run_callbacks :prepare do
        q = {} #query
        q[:limit] = @limit if @limit.is_a?(Numeric) && @limit > 0
        q[:skip] = @skip if @skip > 0

        q[:include] = @includes.join(",") unless @includes.empty?
        q[:keys] = @keys.join(",") unless @keys.empty?
        q[:excludeKeys] = @exclude_keys.join(",") if encode && @exclude_keys&.any?
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
        # Read preference must ride the REST query body (restOptions), NOT a
        # header: Parse Server's middleware does not map any
        # `X-Parse-Read-Preference` header into request options, so the
        # header alone is silently ignored and the read always hits the
        # primary. `RestQuery` reads `readPreference` from restOptions, so
        # emitting it here is what actually routes the read. (The header is
        # still sent for any intermediary that honors it; it is harmless.)
        if encode && (pref = normalized_read_preference)
          q[:readPreference] = pref
        end
        q[:hint] = @hint if @hint
        if includeClassName
          q[:className] = @table
        end
        q
      end
    end

    # @return [Hash] a hash representing just the `where` clause of this
    #   query, with SDK-internal routing markers stripped.
    def compile_where
      self.class.compile_where(@where || [])
    end

    # @return [Hash] the un-stripped reduced where hash, including any
    #   SDK-internal markers like `"__mongo_direct_only"` and
    #   `"__aggregation_pipeline"`. Used by the routing layer to decide
    #   how to execute the query and by aggregation-pipeline builders
    #   to extract stages. Never ship this hash to Parse REST or MongoDB.
    # @!visibility private
    def compile_markers
      self.class.compile_markers(@where || [])
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
    #   Document.group_by(:category).count
    #   Document.where(:status => "active").group_by(:project).sum(:file_size)
    #   Document.group_by(:media_format).average(:duration)
    #
    #   # Array flattening example:
    #   # Record 1: tags = ["a", "b"]
    #   # Record 2: tags = ["b", "c"]
    #   Document.group_by(:tags, flatten_arrays: true).count
    #   # => {"a" => 1, "b" => 2, "c" => 1}
    #
    #   # Sortable results:
    #   Document.group_by(:category, sortable: true).count.sort_by_value_desc
    #   # => [["video", 45], ["image", 23], ["audio", 12]]
    #
    #   # Return Parse::Pointer objects for pointer fields:
    #   Document.group_by(:author_workspace, return_pointers: true).count
    #   # => {#<Parse::Pointer @parse_class="Workspace" @id="team1"> => 5, ...}
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
    #   # Get arrays of actual Document objects grouped by category
    #   Document.query.group_objects_by(:category)
    #   # => {
    #   #   "video" => [#<Document:video1>, #<Document:video2>, ...],
    #   #   "image" => [#<Document:image1>, #<Document:image2>, ...],
    #   #   "audio" => [#<Document:audio1>, ...]
    #   # }
    #
    #   # Get Parse::Pointer objects instead (memory efficient)
    #   Document.query.group_objects_by(:category, return_pointers: true)
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
    #   - Symbol/String: field name (e.g., :object_id, :name) or dot notation (e.g., "project.workspace.name")
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
    #   Document.query.to_table([
    #     :object_id,
    #     "project.name",        # Access project name through relationship
    #     "project.workspace.name",   # Access workspace name through project->workspace relationship
    #     :file_size
    #   ])
    #
    #   # With custom headers and calculated columns
    #   Project.query.to_table([
    #     { field: :object_id, header: "ID" },
    #     { field: "workspace.name", header: "Workspace Name" },
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
    #   Post.group_by_date(:created_at, :day).count
    #   Document.group_by_date(:created_at, :month).sum(:file_size)
    #   Post.where(:project => project_id).group_by_date(:created_at, :week).average(:duration)
    #
    #   # Sortable date results:
    #   Document.group_by_date(:created_at, :day, sortable: true).count.sort_by_value_desc
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
    #   Document.query.distinct_objects(:media_format)
    #   # => ["video", "audio", "photo"]
    #
    #   # Auto-populate Parse pointer objects (much faster than manual conversion)
    #   Document.query.distinct_objects(:author_workspace)
    #   # => [#<Workspace:0x123 @attributes={"name"=>"Workspace A", ...}>, ...]
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
    # Supports dot notation for nested attributes (e.g., "project.workspace.name").
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
    # @param field [Symbol, String] the original field name (e.g., :author_workspace)
    # @param formatted_field [String] the formatted field name (e.g., "authorWorkspace")
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

    # Handle a constraint value that is a bare String inside `$in`/`$nin`
    # against a column positively identified as a pointer, when the
    # target class cannot be resolved (no local belongs_to AND no peer
    # Pointer value to infer from). The storage form is
    # "ClassName$objectId"; matching it against a bare objectId returns
    # zero rows.
    #
    # Strict mode ({Parse.strict_pointer_shapes?}) raises
    # {Parse::Query::PointerShapeError}. Otherwise, emit a one-shot
    # warning via `Parse.logger` (keyed on `[table, field]`) and leave
    # the value unchanged for backwards compatibility.
    # @api private
    def handle_unresolvable_pointer_in_array!(field, op, item, op_value)
      msg = "Pointer-shape mismatch: #{@table}.#{field} is a pointer column " \
            "but #{op} array contains bare string #{item.inspect} and no peer " \
            "Pointer value to infer the target class. This query is " \
            "guaranteed to return zero rows. Pass Parse::Pointer objects, " \
            "{__type: 'Pointer', className: '<X>', objectId: '<id>'} hashes, " \
            "or include at least one such peer in the array so the target " \
            "class can be inferred."
      if Parse.strict_pointer_shapes?
        raise Parse::Query::PointerShapeError, msg
      end
      cache = self.class.pointer_shape_warned
      key = [@table.to_s, field.to_s]
      unless cache[key]
        cache[key] = true
        Parse.logger&.warn("[Parse::Query] #{msg}")
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

    # Whether the field name corresponds to a declared property of the
    # Parse class backing this query (of any type — pointer, string,
    # date, array, etc.) — i.e. something the on-disk MongoDB document
    # would have a column for. Used by
    # {#convert_field_for_direct_mongodb} to distinguish between
    # storage-column references (which must be rewritten to their
    # `_p_*` / camelCase form) and pipeline-local aliases introduced by
    # `$group` / `$project` / `$addFields` / `$set` (which must pass
    # through verbatim so a downstream `$alias` reference matches the
    # upstream output key the caller wrote).
    #
    # Fails open: if the Ruby class cannot be resolved (e.g. the
    # aggregation is running against a class that exists on the server
    # but has no SDK model declaration in this process), returns false
    # — unknown names then pass through unchanged, which matches the
    # pre-4.4.2 behavior of the affected callers.
    #
    # @note Source of truth is the SDK-side property registry
    #   (`parse_class.fields`). We deliberately do not introspect the
    #   live server schema per-call — schema fetches are slow,
    #   stateful, and would couple aggregation correctness to network
    #   reachability. Users that need a field to round-trip through
    #   the rewriter must declare it as a Parse property in the Ruby
    #   model. See {#convert_field_for_direct_mongodb} for the dual
    #   limitation (alias shadowing).
    #
    # @param field [Symbol, String]
    # @return [Boolean]
    # @api private
    def field_is_known_to_schema?(field)
      begin
        parse_class = Parse::Model.const_get(@table)
        return false unless parse_class.respond_to?(:fields)

        fields_to_check = [field.to_s, field.to_sym]
        formatted_field = Query.format_field(field)
        fields_to_check += [formatted_field.to_s, formatted_field.to_sym]

        fields_to_check.any? { |f| parse_class.fields.key?(f.to_sym) }
      rescue NameError
        false
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

    # Convert constraint field names to aggregation format (e.g., authorWorkspace -> _p_authorWorkspace for pointers)
    # @param constraints [Hash] the constraints hash to convert
    # @return [Hash] the converted constraints with aggregation-compatible field names
    def convert_constraints_for_aggregation(constraints)
      return constraints unless constraints.is_a?(Hash)

      result = {}
      constraints.each do |field, value|
        # Skip special Parse operators, but recurse into the boolean
        # combinators so a pointer-field rewrite is not bypassed when
        # the LLM (or any caller) wraps the constraint in $or/$and/$nor.
        # Without this, `{ "$or" => [{ "workspace" => { "$in" => ["bare"] } }] }`
        # would ship to MongoDB with `workspace` un-rewritten to `_p_workspace` —
        # the canonical silent-zero pattern.
        if field.to_s.start_with?("$")
          if value.is_a?(Array) && %w[$and $or $nor].include?(field.to_s)
            result[field] = value.map { |v|
              v.is_a?(Hash) ? convert_constraints_for_aggregation(v) : v
            }
          else
            result[field] = value
          end
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
                    # Pointer column, bare objectId, target class unresolvable.
                    # Storage form is "ClassName$objectId" so this comparison
                    # is guaranteed to return zero rows. Raise in strict mode;
                    # warn and pass through otherwise.
                    handle_unresolvable_pointer_in_array!(field, op, item, op_value)
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
      [:count, :where, :order, :keys, :exclude_keys, :includes, :limit, :skip, :cache, :use_master_key, :hint].each do |param|
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
    # @param permission [Parse::User, Parse::Role, Parse::Pointer, String, Symbol, Array]
    #   the permission to check. A `Parse::User` (or User pointer) expands to
    #   the user's objectId plus every role they inherit; a `Parse::Role` (or
    #   role name String / `:ACL.readable_by_role` form) expands up the role
    #   hierarchy. `"public"` / `:public` / `:everyone` / `:world` map to the
    #   `"*"` wildcard. `"none"` / `:none` / `[]` / `nil` match objects with no
    #   read permissions (explicit empty `_rperm`).
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query. If nil (default),
    #   auto-detects based on query complexity. Set to false to force Parse Server aggregation.
    # @param strict [Boolean] when false (default), the match is **inclusive**:
    #   it ALSO returns publicly-readable rows (`_rperm` contains `"*"`) and
    #   rows with a missing `_rperm` (public by absence), because those are
    #   genuinely readable by the principal. This is access-simulation
    #   semantics ("what can this principal read"). Pass `strict: true` for an
    #   **exact** match — only rows whose `_rperm` literally contains one of
    #   the resolved permissions, with no public/missing rows — which is what
    #   an ownership or security audit wants ("which rows explicitly grant
    #   this principal"). Equivalent to the `:ACL.readable_by_exact` operator.
    # @return [Parse::Query] returns self for method chaining
    # @note This uses MongoDB aggregation pipeline because Parse Server restricts
    #   direct queries on internal ACL fields (_rperm/_wperm).
    # @example
    #   Song.query.readable_by("user123")               # readable by user ID (+ public)
    #   Song.query.readable_by("role:Admin")            # readable by Admin role (+ public)
    #   Song.query.readable_by(current_user)            # by user object, roles expanded (+ public)
    #   Song.query.readable_by(:public)                 # publicly readable objects
    #   Song.query.readable_by("none")                  # objects with no read permissions
    #   Song.query.readable_by([])                      # objects with no read permissions (empty ACL)
    #   Song.query.readable_by("role:Admin", strict: true)  # ONLY rows that explicitly grant Admin
    def readable_by(permission, mongo_direct: nil, strict: false)
      @acl_query_mongo_direct = mongo_direct unless mongo_direct.nil?
      where((strict ? :ACL.readable_by_exact : :ACL.readable_by) => permission)
      self
    end

    # Filter by ACL read permissions using role names (adds "role:" prefix).
    #
    # @param role_name [Parse::Role, String, Array] the role name(s) to check
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @param strict [Boolean] when true, exact match only — no implicit public
    #   `"*"` and no missing-`_rperm` rows. See {#readable_by}.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.readable_by_role("Admin")              # Objects readable by Admin role
    #   Song.query.readable_by_role(["Admin", "Editor"])  # Objects readable by Admin or Editor
    #   Song.query.readable_by_role(admin_role)           # Objects readable by Role object
    def readable_by_role(role_name, mongo_direct: nil, strict: false)
      @acl_query_mongo_direct = mongo_direct unless mongo_direct.nil?
      where((strict ? :ACL.readable_by_role_exact : :ACL.readable_by_role) => role_name)
      self
    end

    # Filter by ACL write permissions using exact permission strings.
    # Strings are used as-is (user IDs or "role:RoleName" format).
    # Use "public" for public access, "none" or [] for no write permissions.
    #
    # @param permission [Parse::User, Parse::Role, Parse::Pointer, String, Symbol, Array]
    #   the permission to check. See {#readable_by} for value coercion and
    #   role expansion.
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query. If nil (default),
    #   auto-detects based on query complexity. Set to false to force Parse Server aggregation.
    # @param strict [Boolean] when true, exact match only — no implicit public
    #   `"*"` and no missing-`_wperm` rows. See {#readable_by}.
    # @return [Parse::Query] returns self for method chaining
    # @note This uses MongoDB aggregation pipeline because Parse Server restricts
    #   direct queries on internal ACL fields (_rperm/_wperm).
    # @example
    #   Song.query.writable_by("user123")               # writable by user ID (+ public)
    #   Song.query.writable_by("role:Admin")            # writable by Admin role (+ public)
    #   Song.query.writable_by(current_user)            # by user object, roles expanded (+ public)
    #   Song.query.writable_by(:public)                 # Publicly writable objects
    #   Song.query.writable_by("none")                  # objects with no write permissions
    #   Song.query.writable_by([])                      # objects with no write permissions (empty ACL)
    #   Song.query.writable_by("role:Admin", strict: true)  # ONLY rows that explicitly grant Admin
    def writable_by(permission, mongo_direct: nil, strict: false)
      @acl_query_mongo_direct = mongo_direct unless mongo_direct.nil?
      where((strict ? :ACL.writable_by_exact : :ACL.writable_by) => permission)
      self
    end

    # Filter by ACL write permissions using role names (adds "role:" prefix).
    #
    # @param role_name [Parse::Role, String, Array] the role name(s) to check
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @param strict [Boolean] when true, exact match only — no implicit public
    #   `"*"` and no missing-`_wperm` rows. See {#readable_by}.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.writable_by_role("Admin")              # Objects writable by Admin role
    #   Song.query.writable_by_role(["Admin", "Editor"])  # Objects writable by Admin or Editor
    #   Song.query.writable_by_role(admin_role)           # Objects writable by Role object
    def writable_by_role(role_name, mongo_direct: nil, strict: false)
      @acl_query_mongo_direct = mongo_direct unless mongo_direct.nil?
      where((strict ? :ACL.writable_by_role_exact : :ACL.writable_by_role) => role_name)
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

    # Find objects that are NOT readable by the given principal — i.e. hidden
    # from them. Excludes rows readable by the principal directly, via any role
    # they inherit, OR publicly (a public row is readable by everyone), and
    # excludes rows with a missing `_rperm` (public by absence).
    #
    # @param permission [Parse::User, Parse::Role, Parse::Pointer, String, Symbol, Array]
    #   the principal to hide from. See {#readable_by} for value coercion.
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.not_readable_by(current_user).results   # hidden from this user
    def not_readable_by(permission, mongo_direct: nil)
      @acl_query_mongo_direct = mongo_direct unless mongo_direct.nil?
      where(:ACL.not_readable_by => permission)
      self
    end

    # Find objects that are NOT writable by the given principal. See
    # {#not_readable_by} for the exclusion semantics (direct, role, public).
    #
    # @param permission [Parse::User, Parse::Role, Parse::Pointer, String, Symbol, Array]
    #   the principal to exclude. See {#readable_by} for value coercion.
    # @param mongo_direct [Boolean] if true, forces MongoDB direct query.
    # @return [Parse::Query] returns self for method chaining
    # @example
    #   Song.query.not_writable_by("role:Admin").results
    def not_writable_by(permission, mongo_direct: nil)
      @acl_query_mongo_direct = mongo_direct unless mongo_direct.nil?
      where(:ACL.not_writable_by => permission)
      self
    end

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
    # @return [Array<Hash>] the MongoDB aggregation pipeline stages this
    #   Aggregation will execute. Useful for previewing the routed pipeline
    #   before {#execute!}, for snapshot-based regression tests, and for
    #   debugging the REST-vs-mongo-direct translation.
    attr_reader :pipeline

    # @return [Boolean] whether {#execute!} will route through
    #   {Parse::MongoDB.aggregate} instead of Parse Server's REST
    #   `/aggregate` endpoint.
    attr_reader :mongo_direct

    # @param query [Parse::Query] the base query object
    # @param pipeline [Array<Hash>] the MongoDB aggregation pipeline stages
    # @param verbose [Boolean, nil] whether to print verbose output (nil means use query's setting)
    # @param mongo_direct [Boolean] if true, uses MongoDB directly bypassing Parse Server (required for $literal)
    # @param max_time_ms [Integer, nil] optional server-side time limit in milliseconds passed to
    #   {Parse::MongoDB.aggregate} when mongo_direct is true. Pass +nil+ (the default) for no cap.
    # @param raw_values [Boolean] when true, passes +rawValues: true+ to the Parse Server REST
    #   aggregate endpoint (PS 9.9.0+). Has no effect on the mongo-direct path.
    # @param raw_field_names [Boolean] when true, passes +rawFieldNames: true+ to the Parse Server
    #   REST aggregate endpoint (PS 9.9.0+). Has no effect on the mongo-direct path.
    # @param allow_internal_fields [Boolean] when true, the mongo-direct path
    #   forwards +allow_internal_fields: true+ to {Parse::MongoDB.aggregate} so
    #   SDK-built ACL `$match` stages that legitimately reference +_rperm+ /
    #   +_wperm+ (emitted by {Parse::Query#readable_by}, +#publicly_readable+,
    #   and friends) pass the pipeline-security internal-fields denylist —
    #   matching the parity already held by +results_direct+ / +count_direct+ /
    #   +distinct_direct+. Set +true+ ONLY when this Aggregation's pipeline was
    #   built entirely from SDK constraint translation (no caller-supplied
    #   stages); the credential-field guard (`_hashed_password`, session tokens,
    #   auth data) is what +allow_internal_fields+ relaxes, so it must never be
    #   set on a pipeline that interpolates user input. Defaults to +false+.
    def initialize(query, pipeline, verbose: nil, mongo_direct: false, max_time_ms: nil,
                   raw_values: false, raw_field_names: false, allow_internal_fields: false)
      @query = query
      @pipeline = pipeline
      @cached_response = nil
      @mongo_direct = mongo_direct
      @max_time_ms = max_time_ms
      @raw_values = raw_values
      @raw_field_names = raw_field_names
      @allow_internal_fields = allow_internal_fields
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
        # REST /aggregate is master-key-only. An ambient Parse.with_session
        # block would suppress the master key via session_token, causing a
        # 401/403. Force use_master_key unless the caller explicitly disabled
        # it (use_master_key: false is a deliberate client-mode decision).
        # `.dup` keeps the master-key flip local to this call even if `_opts`
        # ever returns a shared/memoized hash.
        rest_opts = @query.send(:_opts).dup
        rest_opts[:use_master_key] = true unless rest_opts[:use_master_key] == false
        @cached_response = @query.client.aggregate_pipeline(
          @query.instance_variable_get(:@table),
          @pipeline,
          headers: {},
          raw_values: @raw_values,
          raw_field_names: @raw_field_names,
          **rest_opts,
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
    # @param max_time_ms [Integer, nil] optional server-side time limit (milliseconds).
    #   Defaults to the value passed to {#initialize} via the +max_time_ms:+ keyword.
    # @return [Array<Hash>] raw MongoDB results
    def execute_direct!(max_time_ms: @max_time_ms)
      table = @query.instance_variable_get(:@table)
      auth_kwargs = @query.send(:mongo_direct_auth_kwargs)
      # Forward the parent query's index hint so `query.hint(...).aggregate(...)`
      # honors it on the mongo-direct path too (parity with results_direct /
      # count_direct / distinct_direct).
      hint = @query.instance_variable_get(:@hint)
      Parse::MongoDB.aggregate(table, @pipeline, max_time_ms: max_time_ms, hint: hint,
                               allow_internal_fields: @allow_internal_fields, **auth_kwargs)
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
        # For MongoDB direct, branch per-row on the *raw* document: real Parse
        # docs always carry _created_at / _updated_at, while $group rows reuse
        # _id as the group key. We must not feed group rows through
        # convert_document_to_parse, which would rename _id → objectId and
        # fool the Parse-document heuristic.
        return [] if response.nil? || response.empty?
        table = @query.instance_variable_get(:@table)
        items = response.map { |raw| convert_direct_aggregation_item(raw, table) }
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

    # Convert a raw MongoDB aggregation row from the mongo_direct path. Decides
    # based on the presence of Parse-document markers in the *raw* document.
    # @param raw [Hash] the raw MongoDB document (with _id, _created_at, etc.)
    # @param table [String] the Parse class name
    # @return [Parse::Object, AggregationResult]
    def convert_direct_aggregation_item(raw, table)
      if raw_is_parse_document?(raw)
        parse_doc = Parse::MongoDB.convert_document_to_parse(raw, table)
        # Honor exclude_keys on this mongo-direct aggregation path (e.g. the
        # $inQuery -> $lookup rewrite) by redacting the denylisted fields from
        # the converted document before decode. Mirrors results_direct.
        @query.send(:redact_excluded_keys!, [parse_doc])
        @query.send(:decode, [parse_doc]).first
      else
        AggregationResult.new(Parse::MongoDB.convert_aggregation_document(raw))
      end
    end

    # A raw MongoDB document is a real Parse object only if it carries the
    # internal timestamp fields Parse Server enforces on every row. $group /
    # $project rows that drop these are aggregation results, regardless of
    # whether _id is present.
    # @param raw [Hash] the raw MongoDB document
    # @return [Boolean]
    def raw_is_parse_document?(raw)
      return false unless raw.is_a?(Hash)
      raw.key?("_created_at") || raw.key?(:_created_at) ||
        raw.key?("_updated_at") || raw.key?(:_updated_at)
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
      @sort_target = nil    # nil | :key | :value | :size
      @sort_direction = nil # :asc | :desc
    end

    # Order grouped results by the group key, the aggregated value, or
    # (for {#list}) the size of the per-group array. The ordering is pushed
    # down into the aggregation pipeline as a `$sort` stage (plus a
    # `$addFields` helper for `:size`), so MongoDB does the sort and the
    # returned Hash preserves the order via Ruby's insertion semantics.
    #
    # @param spec [Hash, Symbol] one of:
    #   - `{ key: :asc | :desc }`  — sort by the group key
    #   - `{ value: :asc | :desc }` — sort by the aggregated value
    #     (count/sum/avg/min/max)
    #   - `{ size: :asc | :desc }` — sort by the length of the pushed
    #     array (only meaningful with {#list})
    #   - `:asc` or `:desc` — shorthand for `{ key: direction }`, matching
    #     Ruby's `Hash#sort` default of sorting by key.
    # @return [self]
    # @example Biggest groups first
    #   Document.group_by(:category).order(value: :desc).count
    # @example Alphabetical group keys
    #   Document.group_by(:category).order(key: :asc).count
    # @example Groups with the most members first
    #   Document.group_by(:category).order(size: :desc).list
    def order(spec)
      target, direction =
        case spec
        when Symbol
          [:key, spec]
        when Hash
          unless spec.size == 1
            raise ArgumentError, "order(...) expects a single pair, e.g. {value: :desc} (got #{spec.inspect})"
          end
          k, v = spec.first
          [k.to_sym, v.to_sym]
        else
          raise ArgumentError, "order(...) expects {key:|value:|size: => :asc|:desc} or :asc/:desc (got #{spec.inspect})"
        end

      unless %i[key value size].include?(target)
        raise ArgumentError, "order(...) target must be :key, :value, or :size (got #{target.inspect})"
      end
      unless %i[asc desc].include?(direction)
        raise ArgumentError, "order(...) direction must be :asc or :desc (got #{direction.inspect})"
      end

      @sort_target = target
      @sort_direction = direction
      self
    end

    # Sort grouped results by the group key. Alias for `order(key: direction)`,
    # mirroring Ruby's `Hash#sort` default. For value-based ordering use
    # {#order} explicitly (e.g. `.order(value: :desc)`).
    #
    # Note the asymmetry with chaining: `.sort.count` pushes the sort into
    # the aggregation pipeline and returns a `Hash` keyed by group, while
    # `.count.sort` first materializes the Hash and then calls `Hash#sort`,
    # which returns an `Array<[key, value]>`. Both order by key ascending
    # by default; this method exists so the pipeline form is also available.
    #
    # @param direction [Symbol] `:asc` (default) or `:desc`
    # @return [self]
    # @example
    #   Document.group_by(:category).sort.count        # group keys ascending
    #   Document.group_by(:category).sort(:desc).count # group keys descending
    def sort(direction = :asc)
      order(direction)
    end

    # Returns the MongoDB aggregation pipeline that would be used for a count operation.
    # This is useful for debugging and understanding the generated pipeline.
    # @return [Array<Hash>] the MongoDB aggregation pipeline
    # @example
    #   Post.where(:author_workspace.eq => workspace).group_by(:last_action).pipeline
    #   # => [{"$match"=>{"authorWorkspace"=>"Workspace$abc123"}}, {"$group"=>{"_id"=>"$lastAction", "count"=>{"$sum"=>1}}}, {"$project"=>{"_id"=>0, "objectId"=>"$_id", "count"=>1}}]
    def pipeline
      # This introspection builds the same shape as the count execution
      # path (`$sum: 1`), so reject order/aggregation combinations that
      # the count path would reject at runtime — otherwise the preview
      # silently produces a pipeline the SDK would never actually run.
      validate_sort_target_for_operation!("count")

      # Format the group field name
      formatted_group_field = @query.send(:format_aggregation_field, @group_field)

      # Build the aggregation pipeline (same logic as execute_group_aggregation)
      pipeline = []

      # Add match stage if there are where conditions. `compile_where`
      # is already marker-free; use `compile_markers` to extract
      # __aggregation_pipeline stages.
      compiled_where = @query.send(:compile_where)
      markers = @query.send(:compile_markers)
      if compiled_where.present? || markers.key?("__aggregation_pipeline")
        # Collect all match conditions to merge into a single $match stage
        match_conditions = []
        non_match_stages = []

        # `compiled_where` is marker-free already.
        regular_constraints = compiled_where
        if regular_constraints.present?
          aggregation_where = @query.send(:convert_constraints_for_aggregation, regular_constraints)
          stringified_where = @query.send(:convert_dates_for_aggregation, aggregation_where)
          match_conditions << stringified_where
        end

        # Extract aggregation pipeline stages and merge $match stages
        if markers.key?("__aggregation_pipeline")
          markers["__aggregation_pipeline"].each do |stage|
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

      # Add group stage (using count as example aggregation)
      pipeline << {
        "$group" => {
          "_id" => "$#{formatted_group_field}",
          "count" => { "$sum" => 1 },
        },
      }

      # Add $addFields + $sort stages if ordering was configured. Sort happens
      # before $project so we can reference `_id` (pre-rename) for :key sorts.
      add_fields = size_addfields_stage
      pipeline << add_fields if add_fields
      sort = sort_stage
      pipeline << sort if sort

      pipeline << {
        "$project" => {
          "_id" => 0,
          "objectId" => "$_id",
          "count" => 1,
        },
      }

      pipeline
    end

    # Returns raw unprocessed aggregation results
    # @param operation [String] the aggregation operation
    # @param aggregation_expr [Hash] the MongoDB aggregation expression
    # @return [Array<Hash>] raw aggregation results
    def raw(operation, aggregation_expr)
      formatted_group_field = @query.send(:format_aggregation_field, @group_field)

      # Build the same pipeline the count/sum/etc. terminals use, then delegate
      # to Query#aggregate. That central path handles scoped-query routing
      # (session_token / acl_user / acl_role / ambient Parse.with_session →
      # auto-promote to mongo-direct, or fail closed when unavailable) so a
      # scoped `raw` is never sent to the master-key-only REST /aggregate
      # endpoint, and it returns the raw Array<Hash> rows this method documents.
      # `$match` from the query's where constraints is added by Query#aggregate.
      pipeline = []
      pipeline << { "$unwind" => "$#{formatted_group_field}" } if @flatten_arrays
      pipeline << { "$group" => { "_id" => "$#{formatted_group_field}", "count" => aggregation_expr } }
      add_fields = size_addfields_stage
      pipeline << add_fields if add_fields
      sort = sort_stage
      pipeline << sort if sort
      pipeline << { "$project" => { "_id" => 0, "objectId" => "$_id", "count" => 1 } }

      @query.aggregate(pipeline, verbose: @query.instance_variable_get(:@verbose_aggregate)).raw || []
    end

    # Count the number of items in each group.
    # @return [Hash] a hash with group values as keys and counts as values.
    # @example
    #   Document.group_by(:category).count
    #   # => {"image" => 45, "video" => 23, "audio" => 12}
    def count
      execute_group_aggregation("count", { "$sum" => 1 })
    end

    # Sum a field for each group.
    # @param field [Symbol, String] the field to sum within each group.
    # @return [Hash] a hash with group values as keys and sums as values.
    # @example
    #   Document.group_by(:project).sum(:file_size)
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
    #   Document.group_by(:category).average(:duration)
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

    # Collect every document of each group into an array of Parse::Object
    # instances. Implemented as `$push: "$$ROOT"`, so each group's value is
    # the full set of underlying records (subject to the query's `where`
    # constraints).
    #
    # Use this when you want the actual records per group, not just an
    # aggregated scalar. Combine with `.order(size: :desc)` to surface the
    # largest groups first.
    #
    # @return [Hash{Object => Array<Parse::Object>}] mapping of group key to
    #   the Parse::Object instances in that group.
    # @example
    #   Document.where(:status => "active").group_by(:category).list
    #   # => {"image" => [<Document:...>, <Document:...>], "video" => [<Document:...>]}
    # @example Largest groups first
    #   Document.group_by(:category).order(size: :desc).list
    # @note On the Parse REST `/aggregate` path there is no ACL/CLP/protectedFields
    #   enforcement — that endpoint is master-key-only. On the mongo-direct path
    #   the SDK's ACL `$match` runs before `$group`, and both ACL redaction and
    #   protectedFields stripping recurse into pushed arrays, so scoped agents
    #   get correctly filtered records. The Array recursion that makes this
    #   safe lives in Parse::ACLScope#redact_subdocs! (lib/parse/acl_scope.rb)
    #   and Parse::CLPScope#walk_and_delete! (lib/parse/clp_scope.rb); if you
    #   change either of those, re-verify `.list` still strips correctly.
    def list
      table = @query.instance_variable_get(:@table)
      # `$push: "$$ROOT"` pushes the raw MongoDB-storage-format document
      # into the result array on BOTH the REST and mongo-direct paths —
      # Parse Server's aggregate envelope only rewrites the outermost row's
      # `_id` to `objectId`, not nested arrays. So `_id`, `_p_<field>`
      # pointer strings, `_acl`/`_rperm`/`_wperm`, and `_created_at`/
      # `_updated_at` all survive into the pushed docs and have to be
      # normalized to Parse shape before `Parse::Object.build` will produce
      # an instance with the right id, associations, ACL, and timestamps.
      require_relative "mongodb"
      build_object = lambda do |doc|
        parse_doc = Parse::MongoDB.convert_document_to_parse(doc, table)
        parse_doc ? Parse::Object.build(parse_doc, table) : nil
      end

      execute_group_aggregation("list", { "$push" => "$$ROOT" }) do |docs|
        next [] unless docs.is_a?(Array)
        docs.map(&build_object).compact
      end
    end

    private

    # Execute a group aggregation operation.
    # @param operation [String] the operation name for debugging.
    # @param aggregation_expr [Hash] the MongoDB aggregation expression.
    # @yieldparam raw_value [Object] the value MongoDB returned for the group
    #   (a scalar for count/sum/avg/min/max, an Array for `$push`-style
    #   accumulators). The yielded value replaces the row value in the
    #   returned Hash. When no block is given, the raw value is used as-is.
    # @return [Hash] the grouped results.
    def execute_group_aggregation(operation, aggregation_expr, &value_transformer)
      # Fail closed on order/aggregation combinations that MongoDB would
      # otherwise reject (or silently do the wrong thing) at runtime. The
      # alternatives are "$size on a non-array" (server error) and
      # lexicographic array compare (silently wrong), neither of which is
      # what the caller meant.
      validate_sort_target_for_operation!(operation)

      # Format the group field name
      formatted_group_field = @query.send(:format_aggregation_field, @group_field)

      # Auto-promote scoped queries to mongo-direct so the SDK's three-layer
      # enforcement (ACLScope `$match` injection, CLP find-permits, and
      # protectedFields stripping) actually runs. Parse Server's REST
      # `/aggregate` endpoint is master-key-only and enforces neither ACL
      # nor CLP — calling it with a session_token / acl_user / acl_role
      # query would silently return unscoped rows. The agent dispatcher
      # already does this auto-promotion (lib/parse/agent/tools.rb), this
      # is the equivalent at the Query layer for direct SDK callers.
      use_mongo_direct = @mongo_direct
      if !use_mongo_direct && query_is_scoped?
        if parse_mongodb_available?
          use_mongo_direct = true
        else
          @query.send(:raise_scoped_aggregation_requires_mongo_direct!)
        end
      end

      if use_mongo_direct
        return execute_group_aggregation_direct(operation, aggregation_expr, formatted_group_field, &value_transformer)
      end

      # Build the aggregation pipeline
      # Note: We don't add $match stage here because @query.aggregate() will automatically
      # add match stages from the query's where conditions
      pipeline = []

      # Add unwind stage if flatten_arrays is enabled
      if @flatten_arrays
        pipeline << { "$unwind" => "$#{formatted_group_field}" }
      end

      pipeline << {
        "$group" => {
          "_id" => "$#{formatted_group_field}",
          "count" => aggregation_expr,
        },
      }

      add_fields = size_addfields_stage
      pipeline << add_fields if add_fields
      sort = sort_stage
      pipeline << sort if sort

      pipeline << {
        "$project" => {
          "_id" => 0,
          "objectId" => "$_id",
          "count" => 1,
        },
      }

      # Use the Aggregation class to execute
      aggregation = @query.aggregate(pipeline, verbose: @query.instance_variable_get(:@verbose_aggregate))
      raw_results = aggregation.raw

      # Convert array of results to hash
      if raw_results.is_a?(Array)
        result_hash = {}
        raw_results.each do |item|
          # Parse Server's REST aggregate endpoint renames `_id` to `objectId`
          # in the response envelope; the MongoDB direct route does not.
          # When `aggregate` auto-fires mongo_direct (e.g., pipelines with
          # $lookup stages) the same group_by call returns `_id`-keyed rows
          # instead of `objectId`-keyed rows, so read both shapes.
          key = item["objectId"] || item["_id"]
          value = item["count"]
          value = value_transformer.call(value) if value_transformer

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
    # @yieldparam raw_value [Object] see {#execute_group_aggregation}.
    # @return [Hash] the grouped results.
    def execute_group_aggregation_direct(operation, aggregation_expr, formatted_group_field, &value_transformer)
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

      # Add match stage from query constraints. `compile_where` is
      # already marker-free, so the reject below is a no-op kept for
      # readability.
      compiled_where = @query.send(:compile_where)
      if compiled_where.present?
        mongo_constraints = @query.send(:convert_constraints_for_direct_mongodb, compiled_where)
        pipeline << { "$match" => mongo_constraints } if mongo_constraints.any?
      end

      # Add unwind stage if flatten_arrays is enabled
      if @flatten_arrays
        pipeline << { "$unwind" => "$#{mongo_group_field}" }
      end

      # Convert aggregation expression field references for direct MongoDB
      converted_expr = convert_aggregation_expr_for_direct(aggregation_expr)

      pipeline << {
        "$group" => {
          "_id" => "$#{mongo_group_field}",
          "count" => converted_expr,
        },
      }

      add_fields = size_addfields_stage
      pipeline << add_fields if add_fields
      sort = sort_stage
      pipeline << sort if sort

      pipeline << {
        "$project" => {
          "_id" => 0,
          "value" => "$_id",
          "count" => 1,
        },
      }

      # SDK-built pipeline only — see Parse::Query#results_direct for rationale.
      # Forward auth kwargs derived from the parent query so the
      # three-layer ACL + CLP simulation runs for scoped agents
      # (CLP-1 fix).
      auth_kwargs = @query.send(:mongo_direct_auth_kwargs)
      raw_results = Parse::MongoDB.aggregate(@query.instance_variable_get(:@table),
                                             pipeline,
                                             allow_internal_fields: true,
                                             **auth_kwargs)

      # Convert array of results to hash
      result_hash = {}
      raw_results.each do |item|
        key = item["value"]
        value = item["count"]
        value = value_transformer.call(value) if value_transformer

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

    # Build a `$sort` stage from the configured order, or nil if no
    # ordering was requested. Always sits between `$group` and `$project`
    # so we can reference the unrenamed `_id` (for :key) and the grouped
    # `count` field (for :value / :size).
    def sort_stage
      return nil unless @sort_target
      field =
        case @sort_target
        when :key then "_id"
        when :value then "count"
        when :size then "__order_size"
        end
      { "$sort" => { field => @sort_direction == :desc ? -1 : 1 } }
    end

    # Build the `$addFields` stage that precedes `$sort` when ordering by
    # `:size`. Computes `$size` of the grouped `count` field (which is
    # an array for `.list`). The synthetic `__order_size` field is dropped
    # by the explicit `$project` that follows.
    def size_addfields_stage
      return nil unless @sort_target == :size
      { "$addFields" => { "__order_size" => { "$size" => "$count" } } }
    end

    # Reject configured `.order(target:)` settings that are incompatible
    # with the about-to-run aggregation. MongoDB would otherwise either
    # raise (`$size` on a scalar) or silently do the wrong thing
    # (lexicographic compare on an array), so fail closed at the SDK with
    # a message the caller can act on.
    #
    # @param operation [String] the aggregation operation name passed to
    #   {#execute_group_aggregation} (e.g. "count", "sum", "list").
    def validate_sort_target_for_operation!(operation)
      return unless @sort_target

      if @sort_target == :size && operation != "list"
        raise ArgumentError,
          "order(size:) is only valid with .list — the grouped value " \
          "for `#{operation}` is a scalar, not an array. Use " \
          "order(value:) to sort by the aggregated number, or chain " \
          ".list before .order(size:)."
      end

      if @sort_target == :value && operation == "list"
        raise ArgumentError,
          "order(value:) is not supported with .list — the grouped " \
          "value is an array of objects and would be compared " \
          "lexicographically. Use order(size:) to sort groups by " \
          "their member count, or order(key:) to sort by group name."
      end
    end

    # Whether the parent query carries any non-master-key auth scope. A
    # session_token, acl_user, acl_role, or an active Parse.with_session
    # ambient means the caller expects ACL-filtered results — which only
    # the SDK's mongo-direct path provides. Used to decide whether to
    # auto-promote the REST aggregation path to mongo-direct.
    def query_is_scoped?
      st = @query.session_token
      return true if st.is_a?(String) && !st.empty?
      return true if @query.instance_variable_get(:@acl_user)
      return true if @query.instance_variable_get(:@acl_role)
      # Ambient Parse.with_session counts as scope only when the query did not
      # explicitly set use_master_key: true (matches Parse::Client#request
      # precedence — an explicit master-key call skips the ambient session).
      unless @query.use_master_key == true
        ambient = @query.send(:ambient_session_token)
        return true if ambient.is_a?(String) && !ambient.empty?
      end
      false
    end

    # Whether Parse::MongoDB is loaded and configured to accept direct
    # queries. Wrapped so the auto-promote check fails closed (stays on
    # the REST path) if the integrator hasn't opted in to mongo-direct,
    # rather than raising NotEnabled at execution time.
    def parse_mongodb_available?
      require_relative "mongodb"
      defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
    rescue LoadError, StandardError
      false
    end
  end

  # Wrapper class for grouped results that provides sorting capabilities.
  # Allows sorting grouped results by keys (group names) or values (aggregation results)
  # in ascending or descending order.
  class GroupedResult
    include Enumerable

    # @param results [Hash] the grouped results hash
    # @param operation [String, nil] the aggregation operation (e.g. "count", "sum", "average", "min", "max", "list")
    def initialize(results, operation = nil)
      @results = results
      @operation = operation
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
    # @param headers [Array<String>, nil] custom headers; if nil, defaults to ["Group", <op-derived header>]
    #   where the second header reflects the aggregation operation (e.g. "Average" for avg/average,
    #   "Sum" for sum, "Min"/"Max" for min/max, "Items" for list, "Count" otherwise).
    # @return [String] formatted table
    # @example
    #   Document.group_by(:category, sortable: true).count.to_table
    #   Document.group_by(:category).sum(:file_size).to_table(headers: ["Category", "Total Size"])
    def to_table(format: :ascii, headers: nil)
      headers ||= ["Group", default_value_header]
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

    # Derive a human-readable column header from the aggregation operation.
    # @return [String] the default second-column header
    def default_value_header
      case @operation&.to_s
      when "count"    then "Count"
      when "sum"      then "Sum"
      when "average", "avg" then "Average"
      when "min"      then "Min"
      when "max"      then "Max"
      when "list"     then "Items"
      else                 "Count"
      end
    end

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
      GroupedResult.new(results, "count")
    end

    # Sum a field for each group.
    # @param field [Symbol, String] the field to sum within each group.
    # @return [GroupedResult] a sortable result object.
    def sum(field)
      results = super
      GroupedResult.new(results, "sum")
    end

    # Calculate average of a field for each group.
    # @param field [Symbol, String] the field to average within each group.
    # @return [GroupedResult] a sortable result object.
    def average(field)
      results = super
      GroupedResult.new(results, "average")
    end

    alias_method :avg, :average

    # Find minimum value of a field for each group.
    # @param field [Symbol, String] the field to find minimum for within each group.
    # @return [GroupedResult] a sortable result object.
    def min(field)
      results = super
      GroupedResult.new(results, "min")
    end

    # Find maximum value of a field for each group.
    # @param field [Symbol, String] the field to find maximum for within each group.
    # @return [GroupedResult] a sortable result object.
    def max(field)
      results = super
      GroupedResult.new(results, "max")
    end

    # Collect Parse::Object instances per group.
    # @return [GroupedResult] a sortable result object.
    def list
      results = super
      GroupedResult.new(results, "list")
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
      @sort_target = nil    # nil | :key | :value (no :size — date groupings have no list accumulator yet)
      @sort_direction = nil # :asc | :desc
    end

    # Order date-grouped results by the date key or by the aggregated value.
    # When no ordering is configured the default is chronological by date
    # (the original behavior). The configured order is pushed into the
    # pipeline as a `$sort` stage.
    #
    # @param spec [Hash, Symbol] one of:
    #   - `{ key: :asc | :desc }`  — date order (asc is chronological)
    #   - `{ value: :asc | :desc }` — by aggregated value (count/sum/...)
    #   - `:asc`/`:desc` shorthand for `{ key: direction }`
    # @return [self]
    # @example Newest periods first
    #   Post.group_by_date(:created_at, :day).order(key: :desc).count
    # @example Busiest day first
    #   Post.group_by_date(:created_at, :day).order(value: :desc).count
    def order(spec)
      target, direction =
        case spec
        when Symbol
          [:key, spec]
        when Hash
          unless spec.size == 1
            raise ArgumentError, "order(...) expects a single pair, e.g. {value: :desc} (got #{spec.inspect})"
          end
          k, v = spec.first
          [k.to_sym, v.to_sym]
        else
          raise ArgumentError, "order(...) expects {key:|value: => :asc|:desc} or :asc/:desc (got #{spec.inspect})"
        end

      unless %i[key value].include?(target)
        raise ArgumentError, "order(...) target must be :key or :value for date groupings (got #{target.inspect})"
      end
      unless %i[asc desc].include?(direction)
        raise ArgumentError, "order(...) direction must be :asc or :desc (got #{direction.inspect})"
      end

      @sort_target = target
      @sort_direction = direction
      self
    end

    # Sort date-grouped results by date key (Ruby `Hash#sort` default).
    # @param direction [Symbol] `:asc` (default, chronological) or `:desc`
    # @return [self]
    def sort(direction = :asc)
      order(direction)
    end

    # Returns the MongoDB aggregation pipeline that would be used for a count operation.
    # This is useful for debugging and understanding the generated pipeline.
    # @return [Array<Hash>] the MongoDB aggregation pipeline
    # @example
    #   Post.where(:author_workspace.eq => workspace).group_by_date(:created_at, :month).pipeline
    #   # => [{"$match"=>{"authorWorkspace"=>"Workspace$abc123"}}, {"$group"=>{"_id"=>{"year"=>{"$year"=>"$createdAt"}, "month"=>{"$month"=>"$createdAt"}}, "count"=>{"$sum"=>1}}}, {"$project"=>{"_id"=>0, "objectId"=>"$_id", "count"=>1}}]
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

      # Add group, sort, and project stages (using count as example aggregation)
      pipeline.concat([
        {
          "$group" => {
            "_id" => date_expr,
            "count" => { "$sum" => 1 },
          },
        },
        sort_stage,
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
    #   Post.group_by_date(:created_at, :day).count
    #   # => {"2024-11-24" => 45, "2024-11-25" => 23}
    def count
      execute_date_aggregation("count", { "$sum" => 1 })
    end

    # Sum a field for each time period.
    # @param field [Symbol, String] the field to sum within each time period.
    # @return [Hash] a hash with formatted date strings as keys and sums as values.
    # @example
    #   Document.group_by_date(:created_at, :month).sum(:file_size)
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

      # Auto-promote scoped queries to mongo-direct. REST `/aggregate` is
      # master-key-only and enforces neither ACL nor CLP — a scoped query
      # (session_token / acl_user / acl_role, or an active
      # Parse.with_session block) must use the SDK's enforcement layers.
      # Fail closed if mongo-direct is unavailable rather than silently
      # returning unscoped rows. Mirrors the scoped-query gate in Query#aggregate.
      use_mongo_direct = @mongo_direct
      if !use_mongo_direct && query_is_scoped?
        if parse_mongodb_available?
          use_mongo_direct = true
        else
          @query.send(:raise_scoped_aggregation_requires_mongo_direct!)
        end
      end

      if use_mongo_direct
        return execute_date_aggregation_direct(operation, aggregation_expr, formatted_date_field)
      end

      # Build the date grouping expression based on interval
      date_group_expr = build_date_group_expression(formatted_date_field)

      # Build the aggregation pipeline. The $sort stage defaults to
      # chronological-ascending on the date `_id`, but is overridden by
      # any explicit `.order(...)` configuration.
      pipeline = [
        {
          "$group" => {
            "_id" => date_group_expr,
            "count" => aggregation_expr,
          },
        },
        sort_stage,
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

      # Parse Server's REST /aggregate endpoint is master-key-only. An active
      # Parse.with_session block sets a fiber-local ambient session token that
      # Parse::Client#request picks up and uses in place of the master key,
      # causing a 401/403 on this endpoint. Force use_master_key: true so the
      # ambient session cannot suppress it — unless the caller explicitly set
      # use_master_key: false (deliberate client-mode / session-token intent).
      # `.dup` keeps the master-key flip local to this call (see Aggregation#execute!).
      rest_opts = @query.send(:_opts).dup
      rest_opts[:use_master_key] = true unless rest_opts[:use_master_key] == false

      response = @query.client.aggregate_pipeline(
        @query.instance_variable_get(:@table),
        pipeline,
        headers: {},
        **rest_opts,
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
          # Parse Server's REST aggregate endpoint renames `_id` to `objectId`
          # in the response envelope; the MongoDB direct route does not.
          # When `aggregate` auto-fires mongo_direct (e.g., pipelines with
          # $lookup stages) the same group_by_date call returns `_id`-keyed
          # rows instead of `objectId`-keyed rows, so read both shapes.
          date_key = item["objectId"] || item["_id"]
          value = item["count"]

          # Format the date key for display
          formatted_key = format_date_key(date_key)
          result_hash[formatted_key] = value
        end
        result_hash
      else
        unless response.success?
          # Surface the failure (the result would otherwise be a silent `{}`)
          # through the configured logger rather than unconditional stderr.
          # Log the error code + message, not a full `inspect`, to avoid
          # echoing an unbounded server payload into logs.
          logger = Parse.respond_to?(:logger) ? Parse.logger : nil
          logger&.warn(
            "[Parse::GroupByDate] aggregate failed " \
            "(#{@query.instance_variable_get(:@table)} :#{@date_field} :#{@interval}): " \
            "code=#{response.code} #{response.error}"
          )
        end
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

      # Add match stage from query constraints. `compile_where` strips
      # `__`-prefixed markers already.
      compiled_where = @query.send(:compile_where)
      if compiled_where.present?
        mongo_constraints = @query.send(:convert_constraints_for_direct_mongodb, compiled_where)
        pipeline << { "$match" => mongo_constraints } if mongo_constraints.any?
      end

      # Add group, sort, and project stages. The $sort defaults to
      # chronological-ascending on `_id` and is overridden by .order(...).
      pipeline.concat([
        {
          "$group" => {
            "_id" => date_group_expr,
            "count" => converted_expr,
          },
        },
        sort_stage,
        {
          "$project" => {
            "_id" => 0,
            "value" => "$_id",
            "count" => 1,
          },
        },
      ])

      # SDK-built pipeline only — see Parse::Query#results_direct for rationale.
      # Forward auth kwargs derived from the parent query so the
      # three-layer ACL + CLP simulation runs for scoped agents
      # (CLP-1 fix).
      auth_kwargs = @query.send(:mongo_direct_auth_kwargs)
      raw_results = Parse::MongoDB.aggregate(@query.instance_variable_get(:@table),
                                             pipeline,
                                             allow_internal_fields: true,
                                             **auth_kwargs)

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

    # Build the `$sort` stage for the date grouping pipeline. Defaults to
    # `{ "_id" => 1 }` for chronological order, but is replaced when
    # `.order(...)` has been called.
    def sort_stage
      field = @sort_target == :value ? "count" : "_id"
      dir =
        if @sort_target.nil?
          1
        else
          @sort_direction == :desc ? -1 : 1
        end
      { "$sort" => { field => dir } }
    end

    # Mirror of {GroupBy#query_is_scoped?}. A session_token, acl_user,
    # acl_role, or an active Parse.with_session ambient means the caller
    # expects ACL-filtered results — which only the mongo-direct path
    # provides. Parse Server REST `/aggregate` is master-key-only and
    # unscoped.
    def query_is_scoped?
      st = @query.session_token
      return true if st.is_a?(String) && !st.empty?
      return true if @query.instance_variable_get(:@acl_user)
      return true if @query.instance_variable_get(:@acl_role)
      # Ambient Parse.with_session counts as scope only when the query did not
      # explicitly set use_master_key: true (matches Parse::Client#request
      # precedence — an explicit master-key call skips the ambient session).
      unless @query.use_master_key == true
        ambient = @query.send(:ambient_session_token)
        return true if ambient.is_a?(String) && !ambient.empty?
      end
      false
    end

    # Mirror of {GroupBy#parse_mongodb_available?}. Fails closed to the
    # REST path when Parse::MongoDB isn't configured.
    def parse_mongodb_available?
      require_relative "mongodb"
      defined?(Parse::MongoDB) && Parse::MongoDB.enabled?
    rescue LoadError, StandardError
      false
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
      GroupedResult.new(results, "count")
    end

    # Sum a field for each time period.
    # @param field [Symbol, String] the field to sum within each time period.
    # @return [GroupedResult] a sortable result object.
    def sum(field)
      results = super
      GroupedResult.new(results, "sum")
    end

    # Calculate average of a field for each time period.
    # @param field [Symbol, String] the field to average within each time period.
    # @return [GroupedResult] a sortable result object.
    def average(field)
      results = super
      GroupedResult.new(results, "average")
    end

    alias_method :avg, :average

    # Find minimum value of a field for each time period.
    # @param field [Symbol, String] the field to find minimum for within each time period.
    # @return [GroupedResult] a sortable result object.
    def min(field)
      results = super
      GroupedResult.new(results, "min")
    end

    # Find maximum value of a field for each time period.
    # @param field [Symbol, String] the field to find maximum for within each time period.
    # @return [GroupedResult] a sortable result object.
    def max(field)
      results = super
      GroupedResult.new(results, "max")
    end
  end
end # Parse
