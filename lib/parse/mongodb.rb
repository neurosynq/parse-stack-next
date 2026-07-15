# encoding: UTF-8
# frozen_string_literal: true

require "date"
require "set"
require "time"
require_relative "pipeline_security"
require_relative "clp_scope"
require_relative "acl_scope"

module Parse
  # Direct MongoDB access module for bypassing Parse Server.
  # Provides read-only direct access to MongoDB for performance-critical queries.
  #
  # @example Enable direct MongoDB queries
  #   Parse::MongoDB.configure(
  #     uri: "mongodb://localhost:27017/parse",
  #     enabled: true
  #   )
  #
  # @example Using direct queries
  #   # Returns Parse objects, queried directly from MongoDB
  #   songs = Song.query(:plays.gt => 1000).results_direct
  #   first_song = Song.query(:plays.gt => 1000).first_direct
  #
  # == Field Name Conventions
  #
  # When writing aggregation pipelines for direct MongoDB queries, use MongoDB's native
  # field naming conventions:
  #
  # - *Regular fields*: Use camelCase (e.g., `releaseDate`, `playCount`, `firstName`)
  # - *Pointer fields*: Use `_p_` prefix (e.g., `_p_author`, `_p_album`)
  # - *Built-in dates*: Use `_created_at` and `_updated_at`
  # - *Field references*: Use `$fieldName` syntax (e.g., `$releaseDate`, `$_p_author`)
  #
  # Results are automatically converted to Ruby-friendly format:
  # - Field names converted to snake_case (`totalPlays` → `total_plays`)
  # - Custom aggregation results wrapped in `AggregationResult` for method access
  # - Parse documents returned as proper `Parse::Object` instances
  #
  # @example Aggregation pipeline with MongoDB field names
  #   pipeline = [
  #     { "$match" => { "releaseDate" => { "$lt" => Time.now } } },
  #     { "$group" => { "_id" => "$_p_artist", "totalPlays" => { "$sum" => "$playCount" } } }
  #   ]
  #   results = Song.query.aggregate(pipeline, mongo_direct: true).results
  #
  #   # Results use snake_case and support method access
  #   results.first.total_plays  # => 5000
  #   results.first["totalPlays"] # => 5000 (original key also works)
  #
  # == Date Comparisons
  #
  # MongoDB stores dates in UTC. When comparing dates in aggregation pipelines:
  # - Use Ruby `Time` objects for comparisons (automatically converted to BSON dates)
  # - Ruby `Date` objects (without time) are stored as midnight UTC
  # - For accurate date-only comparisons, use `Time.utc(year, month, day)`
  #
  # @example Date comparison in aggregation
  #   # Compare with a specific UTC time
  #   cutoff = Time.utc(2024, 1, 1, 0, 0, 0)
  #   pipeline = [{ "$match" => { "releaseDate" => { "$gte" => cutoff } } }]
  #
  # @example Using the date conversion helper
  #   # Safely convert any date/time to MongoDB-compatible UTC Time
  #   cutoff = Parse::MongoDB.to_mongodb_date(Date.new(2024, 1, 1))  # => Time UTC
  #   cutoff = Parse::MongoDB.to_mongodb_date("2024-01-01")          # => Time UTC
  #   cutoff = Parse::MongoDB.to_mongodb_date(Time.now)              # => Time UTC
  #
  # @note Requires the 'mongo' gem to be installed. Add to your Gemfile:
  #   gem 'mongo', '~> 2.18'
  module MongoDB
    # Error raised when mongo gem is not available
    class GemNotAvailable < StandardError; end

    # Error raised when direct MongoDB is not enabled
    class NotEnabled < StandardError; end

    # Error raised when MongoDB connection fails
    class ConnectionError < StandardError; end

    # Error raised when a denied operator is detected in a raw filter or
    # pipeline forwarded through {Parse::MongoDB.find} or
    # {Parse::MongoDB.aggregate}. Currently blocks $where, $function, and
    # $accumulator, which all execute server-side JavaScript.
    class DeniedOperator < StandardError; end

    # Error raised when an index mutation primitive is invoked but the
    # writer connection has not been configured via {.configure_writer}.
    class WriterNotConfigured < StandardError; end

    # Error raised when an index mutation primitive is invoked but one of
    # the triple-gate conditions is not satisfied (writer URI configured
    # AND `Parse::MongoDB.index_mutations_enabled = true` AND
    # `ENV["PARSE_MONGO_INDEX_MUTATIONS"] == "1"`). The message names the
    # missing gate so operators get an actionable error.
    class MutationsDisabled < StandardError; end

    # Error raised when an index mutation targets a Parse-internal
    # collection (`_User`, `_Role`, `_Session`, etc.) without explicit
    # `allow_system_classes: true` opt-in, or when the collection name
    # fails the Parse-class regex.
    class ForbiddenCollection < StandardError; end

    # Error raised when {.configure_writer} validates the connected role
    # and finds privileges that exceed `createIndex`/`dropIndex` + reads.
    # The writer connection is meant strictly for index management; any
    # role granting `insert`, `update`, `remove`, `dropCollection`, etc.
    # is rejected fail-closed.
    class WriterRoleTooPermissive < StandardError; end

    # Error raised when MongoDB cancels a query because it exceeded the
    # requested maxTimeMS budget (MongoDB error code 50 / MaxTimeMSExpired).
    # This is the DB-side counterpart to {Parse::Agent::ToolTimeoutError} and
    # is raised by {Parse::MongoDB.aggregate} / {Parse::MongoDB.find} when the
    # driver reports code 50.
    #
    # @example Handling a DB-level timeout
    #   begin
    #     Parse::MongoDB.aggregate("Song", pipeline, max_time_ms: 5000)
    #   rescue Parse::MongoDB::ExecutionTimeout => e
    #     puts "#{e.collection_name} timed out after #{e.max_time_ms}ms"
    #   end
    class ExecutionTimeout < StandardError
      # @return [Integer] the maxTimeMS budget that was exceeded
      attr_reader :max_time_ms
      # @return [String] the collection that was being queried
      attr_reader :collection_name

      # @param collection_name [String] the MongoDB collection
      # @param max_time_ms [Integer] the budget in milliseconds that was exceeded
      def initialize(collection_name:, max_time_ms:)
        @max_time_ms = max_time_ms
        @collection_name = collection_name
        super("Query on '#{collection_name}' exceeded max_time_ms=#{max_time_ms}ms — narrow filter or add index")
      end
    end

    # Threshold above which `Parse::MongoDB.find` emits a deprecation warning
    # when called without an explicit `:limit` option. A future major release
    # will enforce this as a hard default limit. Callers should pass an
    # explicit `:limit` (including `:limit => 0` for unbounded) to silence the
    # warning.
    DEFAULT_FIND_LIMIT = 1000

    # Environment variable names consulted (in priority order) when
    # {.configure} is called without an explicit `uri:` argument.
    # `ANALYTICS_DATABASE_URI` is listed first so deployments can point
    # direct-read traffic at a dedicated analytics replica without
    # disturbing the primary `DATABASE_URI` that Parse Server uses for
    # writes. `DATABASE_URI` is the fallback for deployments where the
    # direct path reads from the same node as Parse Server.
    ENV_URI_KEYS = %w[ANALYTICS_DATABASE_URI DATABASE_URI].freeze

    # Environment variable consulted as part of the triple gate for
    # index mutations. The check is performed on every call (not just at
    # configure time) so a SIGHUP / process-supervisor that flips the
    # variable can revoke without restart.
    MUTATION_ENV_KEY = "PARSE_MONGO_INDEX_MUTATIONS"

    # Parse-internal collections that must not receive index mutations
    # without explicit `allow_system_classes: true`. A unique index on
    # `_Session.session_token`, for example, would break auth on the
    # first duplicate token write.
    PARSE_INTERNAL_CLASSES = %w[
      _User _Role _Session _Installation _Audience _Idempotency
      _PushStatus _JobStatus _Hooks _GlobalConfig _SCHEMA
    ].freeze

    # Mongo privilege actions the writer role MAY hold. Anything outside
    # this set causes {.configure_writer} to refuse with
    # {WriterRoleTooPermissive}. Reads are allowed; mutations are
    # scoped to index management only.
    #
    # The Atlas Search actions (`createSearchIndexes`, `dropSearchIndex`,
    # `updateSearchIndex`, `listSearchIndexes`) are included so a writer
    # role provisioned for search-index management passes the privilege
    # probe. Operators who do not grant those actions in their Mongo role
    # simply cannot invoke the search-index primitives — the SDK allowlist
    # does not auto-grant; it only refuses to reject roles that legitimately
    # hold these specific actions.
    WRITER_ALLOWED_ACTIONS = %w[
      createIndex dropIndex
      createSearchIndexes dropSearchIndex updateSearchIndex listSearchIndexes
      listIndexes listCollections collStats
      find listDatabases connPoolStats serverStatus
    ].freeze

    class << self
      # @!attribute [rw] enabled
      #   Feature flag to enable/disable direct MongoDB queries.
      #   @return [Boolean]
      attr_accessor :enabled

      # @!attribute [rw] uri
      #   MongoDB connection URI.
      #   @return [String]
      attr_accessor :uri

      # @!attribute [rw] database
      #   MongoDB database name (extracted from URI or set manually).
      #   @return [String]
      attr_accessor :database

      # @!attribute [r] client
      #   The MongoDB client instance (memoized).
      #   @return [Mongo::Client]
      attr_reader :client

      # Check if the mongo gem is available
      # @return [Boolean] true if mongo gem is loaded
      def gem_available?
        return @gem_available if defined?(@gem_available)
        @gem_available = begin
            require "mongo"
            true
          rescue LoadError
            false
          end
      end

      # Ensure mongo gem is loaded, raise error if not
      # @raise [GemNotAvailable] if mongo gem is not installed
      def require_gem!
        return if gem_available?
        raise GemNotAvailable,
          "The 'mongo' gem is required for direct MongoDB queries. " \
          "Add 'gem \"mongo\"' to your Gemfile and run 'bundle install'."
      end

      # Configure direct MongoDB access.
      #
      # When `uri:` is omitted, the value is resolved from the first
      # environment variable in {ENV_URI_KEYS} that is set (so
      # `ANALYTICS_DATABASE_URI` wins over `DATABASE_URI`). Raises
      # `ArgumentError` if neither argument nor any env var supplied a URI.
      #
      # @param uri [String, nil] MongoDB connection URI. When nil, falls
      #   back to env-var resolution.
      # @param enabled [Boolean] whether to enable direct queries (default: true)
      # @param database [String, nil] database name (optional, extracted
      #   from URI if not provided)
      # @param verify_role [Boolean] when true (the default), run a
      #   `connectionStatus` role check after configuring and emit a
      #   warning if the authenticated user appears to have write
      #   privileges. The direct path is read-only; a writeable role
      #   means a bug in the gem (or in caller code touching
      #   `Parse::MongoDB.client` directly) could write through it.
      #   Set to false to skip the check (no connection attempt during
      #   configure).
      # @raise [ArgumentError] if no URI can be resolved
      # @example Explicit URI
      #   Parse::MongoDB.configure(
      #     uri: "mongodb://user:pass@localhost:27017/parse?authSource=admin",
      #     enabled: true
      #   )
      # @example Env-var resolution (ANALYTICS_DATABASE_URI preferred,
      #   falls back to DATABASE_URI)
      #   Parse::MongoDB.configure(enabled: true)
      def configure(uri: nil, enabled: true, database: nil, verify_role: true)
        require_gem!
        resolved = uri || resolve_uri_from_env
        if resolved.nil? || resolved.to_s.empty?
          raise ArgumentError,
                "Parse::MongoDB.configure requires a `uri:` argument or one of " \
                "#{ENV_URI_KEYS.join(", ")} set in the environment."
        end
        @uri = resolved
        @enabled = enabled
        @database = database || extract_database_from_uri(resolved)
        @client = nil # Reset client on reconfigure
        warn_if_writeable_role! if verify_role && enabled
      end

      # @return [String, nil] the first env-var URI found, in
      #   {ENV_URI_KEYS} priority order, or nil if none is set.
      def resolve_uri_from_env
        ENV_URI_KEYS.each do |key|
          value = ENV[key]
          return value if value && !value.empty?
        end
        nil
      end

      # Check if direct MongoDB queries are available and enabled
      # @return [Boolean]
      def available?
        gem_available? && enabled? && uri.present?
      end

      # Check if direct queries are enabled
      # @return [Boolean]
      def enabled?
        @enabled == true
      end

      # MongoDB privilege "actions" that indicate write capability. Used by
      # {.read_only?} to classify the authenticated user's role.
      WRITE_ACTIONS = %w[
        insert update remove
        createCollection dropCollection
        createIndex dropIndex
        applyOps dropDatabase
        renameCollectionSameDB enableSharding
      ].freeze

      # Probe whether the authenticated user on the configured URI has any
      # write privileges. Issues the `connectionStatus` command with
      # `showPrivileges: true` — a read-only call that returns the user's
      # role-derived privilege list.
      #
      # Return values:
      # - `true`  — user's privileges include no entries from {WRITE_ACTIONS}
      #   on the configured database. The role is observable read-only.
      # - `false` — at least one write action was found.
      # - `nil`   — couldn't determine (no privilege list returned, command
      #   not supported, network failure). Treat as "unknown" — don't
      #   trust either answer.
      #
      # Caveats:
      # - This is a ROLE check, not a transport check. A `readPreference=
      #   secondary` URI with a write-capable user is still write-capable;
      #   the driver routes writes to primary regardless of read preference.
      # - Some MongoDB configurations restrict the user's visibility into
      #   their own privileges; an empty privilege list returns `nil`,
      #   not `true`.
      # - Atlas Data Federation, BI Connector, and other non-standard
      #   endpoints may respond differently or refuse the command — also
      #   `nil`.
      #
      # @return [Boolean, nil]
      def read_only?
        return nil unless available?
        result = client.database.command(connectionStatus: 1, showPrivileges: true).first
        privileges = result && result.dig("authInfo", "authenticatedUserPrivileges")
        return nil if privileges.nil? || privileges.empty?
        write_set = WRITE_ACTIONS.to_set
        has_write = privileges.any? do |priv|
          Array(priv["actions"]).any? { |a| write_set.include?(a.to_s) }
        end
        !has_write
      rescue StandardError
        nil
      end

      # Emit a warning when {.read_only?} reports a writeable role. Called
      # from {.configure} when `verify_role: true`. Silent on `true`
      # (correctly read-only) and on `nil` (couldn't determine — too noisy
      # to surface in normal operation).
      # @api private
      def warn_if_writeable_role!
        case read_only?
        when false
          warn "[Parse::MongoDB] WARNING: the URI configured for direct " \
               "queries authenticates a user with write privileges. The " \
               "direct path is read-only by design; using a read-only " \
               "role bounds the blast radius if caller code touches " \
               "`Parse::MongoDB.client` directly. See " \
               "docs/mongodb_direct_guide.md for routing direct reads at " \
               "an analytics replica."
        end
      end

      # Get or create the MongoDB client
      # @return [Mongo::Client]
      # @raise [GemNotAvailable] if mongo gem is not installed
      # @raise [NotEnabled] if direct MongoDB is not enabled
      # @raise [ConnectionError] if connection fails
      def client
        require_gem!
        raise NotEnabled, "Direct MongoDB queries are not enabled. Call Parse::MongoDB.configure first." unless available?

        @client ||= begin
            ::Mongo::Client.new(uri)
          rescue => e
            raise ConnectionError, "Failed to connect to MongoDB: #{e.message}"
          end
      end

      # Reset the client connection (useful for testing)
      def reset!
        @client&.close rescue nil
        @client = nil
        @enabled = false
        @uri = nil
        @database = nil
        remove_instance_variable(:@gem_available) if defined?(@gem_available)
        reset_writer!
      end

      # Get a MongoDB collection
      # @param name [String] the collection name
      # @return [Mongo::Collection]
      def collection(name)
        client[name]
      end

      # Normalize a Parse-style read-preference value into the Mongo Ruby
      # driver's `:mode` symbol. Accepts `nil` (returns `nil`), the five
      # documented Parse strings (`PRIMARY`, `PRIMARY_PREFERRED`,
      # `SECONDARY`, `SECONDARY_PREFERRED`, `NEAREST`) in any case with
      # hyphens or underscores, and the equivalent symbol form. Unknown
      # values produce a warning and return `nil` so the operation falls
      # back to the client default rather than failing.
      # @param value [String, Symbol, nil]
      # @return [Symbol, nil]
      def normalize_read_preference(value)
        return nil if value.nil?
        token = value.to_s.tr("-", "_").downcase
        valid = %w[primary primary_preferred secondary secondary_preferred nearest].freeze
        unless valid.include?(token)
          warn "[Parse::MongoDB] Invalid read_preference #{value.inspect}; ignoring."
          return nil
        end
        token.to_sym
      end

      # ---- Writer connection (index mutations) -----------------------------
      #
      # The writer is a SECOND `Mongo::Client` configured against a
      # write-capable Mongo role. It is intentionally distinct from the
      # reader (`@client` above) so the existing analytics path keeps its
      # read-only posture. The writer is reachable ONLY through the named
      # primitives below — `create_index`, `drop_index`, `writer_indexes`.
      # The underlying `Mongo::Client` is never returned to caller code,
      # to bound blast radius if any in-process actor reaches one of the
      # mutation methods. All mutations go through {.assert_mutations_allowed!}.

      # @!attribute [rw] index_mutations_enabled
      #   Ruby-side gate (one of the three required for mutations). Default
      #   `false`. Must be flipped to `true` explicitly in code (typically
      #   in a rake task initializer, never in a web-process initializer).
      #   @return [Boolean]
      attr_accessor :index_mutations_enabled

      # Configure the writer connection used for index mutations.
      # Opens a second `Mongo::Client` against `uri:`. The connection is
      # validated via `connectionStatus` and rejected fail-closed if its
      # role grants destructive privileges (insert/update/remove/
      # dropCollection/dropDatabase/etc.). The client is stored privately
      # and is not exposed through any public accessor.
      #
      # @param uri [String] writer URI, must be distinct from the reader
      #   `@uri`. Typically points at the same replica set with a different
      #   Mongo user holding only `createIndex`/`dropIndex` privileges.
      # @param enabled [Boolean] when false, `configure_writer` records
      #   the URI but does NOT open the connection. Use this to lay
      #   wiring in code without activating the writer until a separate
      #   call sets `Parse::MongoDB.index_mutations_enabled = true`.
      # @param verify_role [Boolean] when true (default), run the
      #   privilege check on the configured user and raise
      #   {WriterRoleTooPermissive} if it exceeds {WRITER_ALLOWED_ACTIONS}.
      #   Disable only in test fixtures.
      # @raise [ArgumentError] when `uri:` is missing or matches the
      #   reader URI verbatim.
      # @raise [WriterRoleTooPermissive] when the role check fails.
      def configure_writer(uri:, enabled: true, verify_role: true)
        require_gem!
        raise ArgumentError, "configure_writer requires a uri:" if uri.nil? || uri.to_s.empty?
        if @uri && @uri.to_s == uri.to_s
          raise ArgumentError,
                "configure_writer URI must differ from the reader URI. " \
                "The writer is meant for a separately-credentialed Mongo role."
        end
        @writer_uri = uri
        @writer_enabled = enabled
        @writer_client&.close rescue nil
        @writer_client = nil
        if enabled
          # Eagerly open so a misconfigured URI fails fast at configure time.
          assert_writer_role_acceptable! if verify_role
        end
      end

      # @return [Boolean] true when {.configure_writer} has been called
      #   with `enabled: true` and the connection is reachable.
      def writer_configured?
        !@writer_uri.nil? && @writer_enabled == true
      end

      # @return [Boolean] true iff `ENV[MUTATION_ENV_KEY] == "1"`.
      def mutations_env_enabled?
        ENV[MUTATION_ENV_KEY].to_s == "1"
      end

      # Run all three gates. Returns nil on success; raises with a
      # message naming the missing gate otherwise.
      # @raise [WriterNotConfigured, MutationsDisabled]
      def assert_mutations_allowed!
        unless writer_configured?
          raise WriterNotConfigured,
                "Index mutations require Parse::MongoDB.configure_writer(uri: ...) " \
                "to be called with a write-capable Mongo role URI distinct from the reader."
        end
        unless @index_mutations_enabled == true
          raise MutationsDisabled,
                "Index mutations are disabled. Set Parse::MongoDB.index_mutations_enabled = true " \
                "explicitly (typically in a rake-task initializer, not in a web-process initializer)."
        end
        unless mutations_env_enabled?
          raise MutationsDisabled,
                "Index mutations require ENV[#{MUTATION_ENV_KEY.inspect}] == '1'. " \
                "Set this only in environments where index mutations are intended " \
                "(rake tasks, maintenance scripts), never on web/worker dynos."
        end
        nil
      end

      # Reset the writer connection and clear gate state. Called from
      # {.reset!}; can be invoked directly for granular teardown.
      def reset_writer!
        @writer_client&.close rescue nil
        @writer_client = nil
        @writer_uri = nil
        @writer_enabled = false
      end

      # Create an index on the named collection. Triple-gated; refuses
      # Parse-internal collections unless `allow_system_classes: true`.
      # Idempotent: if an index with identical key+options already exists,
      # returns `:exists` without issuing the create.
      #
      # @param collection_name [String] target collection / Parse class
      # @param keys [Hash{String,Symbol => Integer,String}] index key spec.
      #   Values are `1` (asc), `-1` (desc), `"2dsphere"`, `"text"`, `"hashed"`.
      # @param name [String, nil] optional index name. When nil, Mongo
      #   generates `field_dir_field_dir` automatically.
      # @param unique [Boolean] uniqueness constraint.
      # @param sparse [Boolean] sparse index (skip docs missing the key).
      # @param partial_filter [Hash, nil] partial index filter expression.
      # @param expire_after [Integer, nil] TTL in seconds.
      # @param allow_system_classes [Boolean] opt-in to mutate Parse-internal
      #   collections (`_User`, `_Role`, etc.). Default false. Audit-logged.
      # @return [Symbol] `:created` on success, `:exists` when an
      #   identically-specified index was already present.
      # @raise [WriterNotConfigured, MutationsDisabled, ForbiddenCollection]
      def create_index(collection_name, keys, name: nil, unique: false, sparse: false,
                       partial_filter: nil, expire_after: nil, allow_system_classes: false)
        assert_mutations_allowed!
        assert_collection_allowed!(collection_name, allow_system_classes: allow_system_classes)
        spec_keys = normalize_index_keys(keys)
        existing = writer_indexes(collection_name, allow_system_classes: allow_system_classes)
        if index_matches?(existing, spec_keys, name: name, unique: unique, sparse: sparse,
                          partial_filter: partial_filter, expire_after: expire_after)
          audit_writer_event(:create_index_skipped, collection_name, keys: spec_keys, name: name)
          return :exists
        end
        opts = build_index_options(name: name, unique: unique, sparse: sparse,
                                   partial_filter: partial_filter, expire_after: expire_after)
        audit_writer_event(:create_index, collection_name, keys: spec_keys, name: name, opts: opts)
        writer_collection(collection_name).indexes.create_one(spec_keys, **opts)
        :created
      end

      # Drop a named index. Requires the operator-supplied `confirm:`
      # string to match `"drop:#{collection}:#{name}"` so a stale shell
      # session against the wrong environment can't accidentally drop
      # something via a rerun.
      #
      # @param collection_name [String] target collection
      # @param name [String] index name to drop
      # @param confirm [String] must equal `"drop:#{collection_name}:#{name}"`
      # @param allow_system_classes [Boolean] opt-in for Parse-internal
      # @return [Symbol] `:dropped` on success, `:absent` when the index
      #   did not exist (idempotent).
      def drop_index(collection_name, name, confirm:, allow_system_classes: false)
        assert_mutations_allowed!
        assert_collection_allowed!(collection_name, allow_system_classes: allow_system_classes)
        expected = "drop:#{collection_name}:#{name}"
        unless confirm.to_s == expected
          raise ArgumentError,
                "drop_index confirmation mismatch. Pass confirm: #{expected.inspect} " \
                "to drop #{name.inspect} from #{collection_name.inspect}."
        end
        existing = writer_indexes(collection_name, allow_system_classes: allow_system_classes)
        unless existing.any? { |i| (i["name"] || i[:name]) == name }
          audit_writer_event(:drop_index_absent, collection_name, name: name)
          return :absent
        end
        audit_writer_event(:drop_index, collection_name, name: name)
        writer_collection(collection_name).indexes.drop_one(name)
        :dropped
      end

      # List indexes on a collection via the WRITER connection. Distinct
      # from {.indexes} which uses the reader. Used by {.create_index}
      # for the idempotency check so the existence read is performed on
      # the same connection that will issue the create.
      # @param collection_name [String]
      # @param allow_system_classes [Boolean]
      # @return [Array<Hash>]
      def writer_indexes(collection_name, allow_system_classes: false)
        assert_collection_allowed!(collection_name, allow_system_classes: allow_system_classes)
        # NOTE: listing does not require the mutation gate — operators
        # can inspect what's there even when mutations are disabled,
        # which is useful for `parse:mongo:indexes:plan` dry-runs that
        # don't intend to mutate.
        unless writer_configured?
          raise WriterNotConfigured,
                "writer_indexes requires configure_writer to have been called."
        end
        begin
          writer_collection(collection_name).indexes.to_a
        rescue StandardError => e
          # Mongo raises NamespaceNotFound (code 26) when the collection
          # has not been created yet — listing indexes on a non-existent
          # collection is "no indexes" from the SDK's perspective. Match
          # by code AND by message substring because the driver's exact
          # class path varies across versions.
          return [] if mongo_namespace_not_found?(e)
          raise
        end
      end

      # List Atlas Search indexes via the WRITER connection. Distinct
      # from {.list_search_indexes} which uses the reader's aggregate
      # path. Used by the search-index mutation primitives below for the
      # existence check so the read is performed on the same connection
      # that will issue the mutation. Returns `[]` for collections that
      # do not yet exist.
      #
      # @param collection_name [String]
      # @param allow_system_classes [Boolean]
      # @return [Array<Hash>] raw search-index documents
      # @raise [WriterNotConfigured, ForbiddenCollection]
      def writer_search_indexes(collection_name, allow_system_classes: false)
        assert_collection_allowed!(collection_name, allow_system_classes: allow_system_classes)
        unless writer_configured?
          raise WriterNotConfigured,
                "writer_search_indexes requires configure_writer to have been called."
        end
        begin
          writer_collection(collection_name)
            .aggregate([{ "$listSearchIndexes" => {} }]).to_a
        rescue StandardError => e
          return [] if mongo_namespace_not_found?(e)
          raise
        end
      end

      # Create an Atlas Search index. Triple-gated like {.create_index};
      # refuses Parse-internal collections unless `allow_system_classes:
      # true`. Idempotent on name: if a search index with the same name
      # already exists, returns `:exists` without issuing the create.
      # The mapping definition of the existing index is NOT diffed — use
      # {.update_search_index} to change a definition.
      #
      # The build runs ASYNCHRONOUSLY on the Atlas Search node. This
      # method returns as soon as the command is accepted; the index is
      # not queryable until its status transitions to `READY`. Poll
      # {Parse::AtlasSearch::IndexManager.index_ready?} to confirm.
      #
      # @param collection_name [String] target collection / Parse class
      # @param name [String] the search index name. Must match
      #   `/\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/`.
      # @param definition [Hash] the search index definition (e.g.
      #   `{ mappings: { dynamic: true } }`). String/symbol keys both
      #   accepted; converted to string keys before submission.
      # @param allow_system_classes [Boolean] opt-in to mutate Parse-
      #   internal collections. Default false. Audit-logged.
      # @return [Symbol] `:created` on submission, `:exists` when a
      #   search index with that name already exists.
      # @raise [WriterNotConfigured, MutationsDisabled, ForbiddenCollection, ArgumentError]
      def create_search_index(collection_name, name, definition, allow_system_classes: false)
        assert_mutations_allowed!
        assert_collection_allowed!(collection_name, allow_system_classes: allow_system_classes)
        validate_search_index_name!(name)
        validate_search_index_definition!(definition)
        existing = writer_search_indexes(collection_name, allow_system_classes: allow_system_classes)
        if existing.any? { |i| (i["name"] || i[:name]).to_s == name.to_s }
          audit_writer_event(:create_search_index_skipped, collection_name, name: name)
          return :exists
        end
        audit_writer_event(:create_search_index, collection_name, name: name)
        writer_client.database.command(
          createSearchIndexes: collection_name.to_s,
          indexes: [{ name: name.to_s, definition: stringify_keys_deep(definition) }],
        )
        :created
      end

      # Drop a named Atlas Search index. Requires the operator-supplied
      # `confirm:` string to match `"drop_search:#{collection}:#{name}"`.
      # The token deliberately differs from {.drop_index}'s `"drop:"`
      # prefix so a token meant for a regular index cannot be replayed
      # against a search index with the same name (and vice versa).
      #
      # The drop is asynchronous on the Atlas Search node but typically
      # completes quickly; the local cache in
      # {Parse::AtlasSearch::IndexManager} should be invalidated by the
      # caller (the IndexManager wrapper does this).
      #
      # @param collection_name [String] target collection
      # @param name [String] search index name to drop
      # @param confirm [String] must equal
      #   `"drop_search:#{collection_name}:#{name}"`
      # @param allow_system_classes [Boolean] opt-in for Parse-internal
      # @return [Symbol] `:dropped` on success, `:absent` when no such
      #   search index existed (idempotent).
      # @raise [WriterNotConfigured, MutationsDisabled, ForbiddenCollection, ArgumentError]
      def drop_search_index(collection_name, name, confirm:, allow_system_classes: false)
        assert_mutations_allowed!
        assert_collection_allowed!(collection_name, allow_system_classes: allow_system_classes)
        expected = "drop_search:#{collection_name}:#{name}"
        unless confirm.to_s == expected
          raise ArgumentError,
                "drop_search_index confirmation mismatch. Pass confirm: #{expected.inspect} " \
                "to drop search index #{name.inspect} from #{collection_name.inspect}."
        end
        existing = writer_search_indexes(collection_name, allow_system_classes: allow_system_classes)
        unless existing.any? { |i| (i["name"] || i[:name]).to_s == name.to_s }
          audit_writer_event(:drop_search_index_absent, collection_name, name: name)
          return :absent
        end
        audit_writer_event(:drop_search_index, collection_name, name: name)
        writer_client.database.command(
          dropSearchIndex: collection_name.to_s,
          name: name.to_s,
        )
        :dropped
      end

      # Replace the definition of an existing Atlas Search index. The
      # rebuild runs asynchronously on the Atlas Search node; the new
      # mapping is not live until the index's status transitions back to
      # `READY`. Poll {Parse::AtlasSearch::IndexManager.index_ready?}
      # to confirm.
      #
      # Raises `ArgumentError` if no search index with that name exists
      # — use {.create_search_index} for new indexes. The mapping diff
      # is not computed; the command is issued unconditionally for
      # existing indexes (Atlas itself handles "definition unchanged"
      # cases gracefully).
      #
      # @param collection_name [String]
      # @param name [String] existing search index name
      # @param definition [Hash] replacement definition
      # @param allow_system_classes [Boolean]
      # @return [Symbol] `:updated` on submission
      # @raise [WriterNotConfigured, MutationsDisabled, ForbiddenCollection, ArgumentError]
      def update_search_index(collection_name, name, definition, allow_system_classes: false)
        assert_mutations_allowed!
        assert_collection_allowed!(collection_name, allow_system_classes: allow_system_classes)
        validate_search_index_name!(name)
        validate_search_index_definition!(definition)
        existing = writer_search_indexes(collection_name, allow_system_classes: allow_system_classes)
        unless existing.any? { |i| (i["name"] || i[:name]).to_s == name.to_s }
          audit_writer_event(:update_search_index_absent, collection_name, name: name)
          raise ArgumentError,
                "update_search_index: no Atlas Search index named #{name.inspect} " \
                "on collection #{collection_name.inspect}. Use create_search_index to create one."
        end
        audit_writer_event(:update_search_index, collection_name, name: name)
        writer_client.database.command(
          updateSearchIndex: collection_name.to_s,
          name: name.to_s,
          definition: stringify_keys_deep(definition),
        )
        :updated
      end

      private

      # The active writer collection handle. Private — never exposed in
      # a public accessor. The only sites that hold a `Mongo::Collection`
      # from the writer are the mutation methods above.
      def writer_collection(name)
        writer_client[name]
      end

      def writer_client
        require_gem!
        unless writer_configured?
          raise WriterNotConfigured,
                "Writer is not configured. Call Parse::MongoDB.configure_writer(uri:) first."
        end
        @writer_client ||= begin
            # min_pool_size: 0 — keep idle pool drained when not in use.
            # The writer should be a rare-use connection.
            ::Mongo::Client.new(@writer_uri, min_pool_size: 0, max_pool_size: 2,
                                              server_selection_timeout: 10,
                                              socket_timeout: 10,
                                              connect_timeout: 5,
                                              monitoring: false)
          rescue => e
            raise ConnectionError, "Failed to connect writer client: #{e.message}"
          end
      end

      def assert_writer_role_acceptable!
        result = writer_client.database.command(connectionStatus: 1, showPrivileges: true).first
        privileges = result && result.dig("authInfo", "authenticatedUserPrivileges")
        if privileges.nil?
          # Can't verify — fail closed for the writer (the reader can
          # tolerate :unknown, the writer cannot).
          raise WriterRoleTooPermissive,
                "Could not verify writer role privileges (connectionStatus returned no privilege list). " \
                "Writer must be explicitly bound to a role granting only #{WRITER_ALLOWED_ACTIONS.inspect}."
        end
        allowed = WRITER_ALLOWED_ACTIONS.to_set
        actions_seen = privileges.flat_map { |p| Array(p["actions"]) }.map(&:to_s).uniq
        extras = actions_seen.reject { |a| allowed.include?(a) }
        unless extras.empty?
          raise WriterRoleTooPermissive,
                "Writer role grants disallowed actions: #{extras.inspect}. " \
                "Writer must be bound to a role granting only #{WRITER_ALLOWED_ACTIONS.inspect}. " \
                "Create a dedicated Mongo user with the parse_index_admin role pattern."
        end
        nil
      end

      def assert_collection_allowed!(collection_name, allow_system_classes:)
        name = collection_name.to_s
        # Parse-internal classes start with `_` (e.g. `_User`, `_Role`).
        # Parse Relation join collections are `_Join:<field>:<ParentClass>`
        # where the parent class may itself start with `_` (e.g. the
        # canonical `Parse::Role.users` relation → `_Join:users:_Role`).
        # Allow both shapes here; the dedicated denylist below produces
        # the clearer error for top-level Parse-internal names.
        unless name.match?(/\A(_?[A-Za-z][A-Za-z0-9_]*|_Join:[A-Za-z][A-Za-z0-9_]*:_?[A-Za-z][A-Za-z0-9_]*)\z/)
          raise ForbiddenCollection,
                "Collection name #{name.inspect} must be either a Parse class " \
                "(matches /\\A_?[A-Za-z][A-Za-z0-9_]*\\z/) or a Parse Relation " \
                "join collection (matches /\\A_Join:<field>:<ParentClass>\\z/)."
        end
        if PARSE_INTERNAL_CLASSES.include?(name) && !allow_system_classes
          raise ForbiddenCollection,
                "Index mutations against Parse-internal collection #{name.inspect} are forbidden. " \
                "Pass allow_system_classes: true to opt in (audit-logged at WARN)."
        end
        nil
      end

      def normalize_index_keys(keys)
        unless keys.is_a?(Hash) && !keys.empty?
          raise ArgumentError, "Index keys must be a non-empty Hash like { field: 1 }; got #{keys.inspect}"
        end
        keys.each_with_object({}) do |(field, dir), h|
          h[field.to_s] = dir
        end
      end

      def build_index_options(name:, unique:, sparse:, partial_filter:, expire_after:)
        opts = {}
        opts[:name] = name if name
        opts[:unique] = true if unique
        opts[:sparse] = true if sparse
        opts[:partial_filter_expression] = partial_filter if partial_filter
        opts[:expire_after] = expire_after if expire_after
        opts
      end

      # Whether the existing index list contains an entry matching the
      # requested spec. Compared by key signature first (canonical
      # ordering), then by the small set of options that meaningfully
      # change index semantics (`unique`, `sparse`, `partialFilterExpression`,
      # `expireAfterSeconds`). When `name:` is supplied, the existing
      # index's name must also match.
      def index_matches?(existing, keys, name:, unique:, sparse:, partial_filter:, expire_after:)
        existing.any? do |idx|
          ex_keys = stringify_keys(idx["key"] || idx[:key])
          next false unless ex_keys == stringify_keys(keys)
          next false if name && (idx["name"] || idx[:name]) != name
          next false if !!unique != (idx["unique"] == true)
          next false if !!sparse != (idx["sparse"] == true)
          next false if (partial_filter || nil) != (idx["partialFilterExpression"] || nil)
          next false if expire_after && idx["expireAfterSeconds"] != expire_after
          true
        end
      end

      def stringify_keys(hash)
        return {} if hash.nil?
        hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end

      # MongoDB raises NamespaceNotFound (code 26) when `listIndexes`
      # runs against a collection that does not exist yet. Match by
      # error code AND by message substring — the driver class path
      # for `Mongo::Error::OperationFailure` is stable but the response-
      # parsing path that surfaces the code has varied across versions.
      def mongo_namespace_not_found?(err)
        return true if err.respond_to?(:code) && err.code == 26
        msg = err.message.to_s
        msg.include?("NamespaceNotFound") || msg.include?("ns does not exist")
      end

      # Emit a structured audit line for writer events. Matches the
      # `[Parse::*:SECURITY]` warn-line style used elsewhere in the gem.
      def audit_writer_event(event, collection_name, **fields)
        payload = fields.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
        warn "[Parse::MongoDB:WRITER] event=#{event} collection=#{collection_name.inspect} " \
             "pid=#{Process.pid} #{payload}"
      end

      # Atlas Search index names share the URL/path space with Mongo
      # commands; constrain them to a conservative identifier shape to
      # avoid surprises from operators pasting whitespace, slashes, or
      # control characters into a definition file.
      def validate_search_index_name!(name)
        s = name.to_s
        unless s.match?(/\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/)
          raise ArgumentError,
                "Atlas Search index name #{name.inspect} is invalid. " \
                "Must match /\\A[A-Za-z][A-Za-z0-9_-]{0,63}\\z/."
        end
      end

      def validate_search_index_definition!(definition)
        unless definition.is_a?(Hash) && !definition.empty?
          raise ArgumentError,
                "Atlas Search index definition must be a non-empty Hash; got #{definition.inspect}"
        end
      end

      # Mongo's command parser tolerates symbol keys at the top level of
      # the command Hash, but nested driver serialization for arbitrary
      # mapping shapes (e.g. `fields: { title: { type: "string" } }`) is
      # safer with string keys throughout. Mirrors {#stringify_keys} but
      # recurses into Arrays and Hashes.
      def stringify_keys_deep(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_keys_deep(v) }
        when Array
          value.map { |v| stringify_keys_deep(v) }
        else
          value
        end
      end

      public

      # Re-expose `collection` as public after the private block above.
      # (Ruby's `private` is sticky to the end of the class body; the
      # writer-internal methods above are intentionally private but
      # `collection` and the existing public surface must remain public.)
      #
      # No-op marker — the actual `public` reset happens below by
      # explicitly listing the methods to re-publish.

      # @deprecated Retained for backwards compatibility. The canonical list now lives
      #   in {Parse::PipelineSecurity::DENIED_OPERATORS}.
      DENIED_OPERATORS = Parse::PipelineSecurity::DENIED_OPERATORS

      # @!visibility private
      # Default BFS depth for role-graph expansion. Real-world role graphs
      # are 2-4 deep; 6 leaves headroom for unusual hierarchies without
      # encouraging runaway $graphLookup fan-out on pathological inputs.
      ROLE_GRAPH_DEFAULT_DEPTH = 6

      # @!visibility private
      # Hard ceiling on accepted `max_depth:` for the role-graph helpers.
      # Anything above raises `ArgumentError` — the helpers do not silently
      # clamp because a caller passing 100 is a bug worth surfacing.
      # Lowered from 20 to 6 (matches DEFAULT_DEPTH) to prevent the helper
      # from being used as a `$graphLookup` DoS amplifier on pathological
      # role hierarchies. Real-world Parse `_Role` graphs are 2-4 deep;
      # callers needing more should examine why their hierarchy is so
      # deep before raising this ceiling.
      ROLE_GRAPH_MAX_DEPTH = 6

      # @!visibility private
      # Hardcoded `maxTimeMS` budget for the role-graph aggregations. Both
      # the forward (user → roles) and reverse (role → users) helpers run
      # under this cap; an attacker who synthesizes a deep / fan-out-heavy
      # role graph cannot extend execution beyond this budget.
      ROLE_GRAPH_MAX_TIME_MS = 5000

      # @!visibility private
      # Strict regex for Parse objectIds passed into the role-graph helpers.
      # Parse Server's default IDs are 10 alphanumeric chars; configurable
      # custom-ID rules permit `_`/`-` and lengths up to 64. The regex fails
      # closed on NUL bytes, Unicode RTL marks, dotted forms, etc.
      ROLE_GRAPH_ID_RE = /\A[A-Za-z0-9_\-]{1,64}\z/

      # Resolve every role name a user inherits via a single
      # `$graphLookup` aggregation against the Parse role-subscription and
      # role-inheritance join tables.
      #
      # This is the mongo-direct fast path that {Parse::Role.all_for_user}
      # falls into when an explicit authorization scope is provided.
      # The pipeline shape is hardcoded; only `user_id` and `max_depth`
      # are interpolated, and both are validated against {ROLE_GRAPH_ID_RE}
      # / {ROLE_GRAPH_MAX_DEPTH}.
      #
      # The call bypasses {Parse::MongoDB.aggregate} on purpose: that
      # entry point injects an `_rperm` `$match` and rewrites
      # `$lookup` / `$graphLookup` stages with the same predicate, which
      # would filter every `_Join:*:_Role` row to zero (those join
      # collections have no `_rperm` column). {Parse::PipelineSecurity.validate_filter!}
      # still runs against the constructed pipeline as belt-and-braces
      # protection against a future regression that interpolates a caller
      # value into a denied operator.
      #
      # If `_Join:roles:_Role` doesn't exist (the app uses flat roles
      # without inheritance), MongoDB treats the missing collection as
      # empty and `$graphLookup` returns no parents — the result collapses
      # to direct subscriptions only, matching the Parse-Server-backed walk.
      #
      # ## Authorization contract
      #
      # The helper requires an EXPLICIT per-call authorization:
      #
      #   * `master: true` — explicit master-mode opt-in. Bypasses
      #     `_Role` CLP. Use for admin tooling, analytics jobs, and
      #     any code path that legitimately needs to read role graphs
      #     across users.
      #
      #   * `as: <User|Pointer>` — caller scope. The supplied user must
      #     be permitted to `find` on `_Role` under the cached CLP, or
      #     {Parse::CLPScope::Denied} is raised. `_Role`'s default CLP
      #     is master-only, so this path will fail closed unless the
      #     operator has explicitly opened `_Role` CLP for the user.
      #
      # Passing neither raises `ArgumentError`. The previous behavior
      # (gated only on the process-level `master_key_available?`
      # boolean — a check on the SDK's boot config, not the caller's
      # authority) is removed — it provided no per-call authorization.
      #
      # ## Return-value contract
      # - `Set<String>` on success (possibly empty if the user has no
      #   direct subscriptions).
      # - `nil` when the fast path is unavailable (mongo gem missing,
      #   {Parse::MongoDB.available?} false). Callers fall back to the
      #   Parse-Server N+1 walk.
      # - Raises {Parse::MongoDB::ExecutionTimeout} on Mongo timeout
      #   (attack-signal — do not silently fall back), `ArgumentError`
      #   on input-validation failure or missing authorization, and
      #   propagates other `Mongo::Error` subclasses that aren't
      #   recognized as benign availability errors.
      #
      # @param user_id [String] a Parse `_User.objectId`.
      # @param max_depth [Integer] BFS depth bound. See
      #   {ROLE_GRAPH_DEFAULT_DEPTH} for the default and
      #   {ROLE_GRAPH_MAX_DEPTH} for the upper bound.
      # @param master [Boolean] when `true`, bypass `_Role` CLP. Mutually
      #   exclusive with `as:`.
      # @param as [Parse::User, Parse::Pointer, nil] caller-scope user.
      #   When provided (and `master:` is not), the scope is resolved
      #   via {Parse::ACLScope.resolve!} and the resulting permission
      #   set is checked against `_Role` CLP before the pipeline runs.
      # @return [Set<String>, nil] resolved role names, or nil when the
      #   fast path is unavailable.
      # @raise [ArgumentError] when neither `master:` nor `as:` is
      #   supplied, or when both are supplied.
      # @raise [Parse::CLPScope::Denied] when `as:` is supplied and the
      #   scope cannot `find` on `_Role`.
      def role_names_for_user(user_id, max_depth: ROLE_GRAPH_DEFAULT_DEPTH, master: false, as: nil)
        authorize_role_graph_call!(:role_names_for_user, master: master, as: as)
        validate_role_graph_id!(user_id, "user_id")
        depth = validate_role_graph_depth!(max_depth)
        return Set.new if depth <= 0
        return nil unless available?

        graph_depth = depth - 1
        pipeline = build_user_role_names_pipeline(user_id, graph_depth)
        Parse::PipelineSecurity.validate_filter!(
          pipeline, allow_internal_fields: true,
        )

        result_set = nil
        ActiveSupport::Notifications.instrument(
          "parse.mongodb.role_graph",
          direction: :forward, target_id: user_id, depth: depth,
        ) do |payload|
          docs = collection("_Join:users:_Role").aggregate(
            pipeline, max_time_ms: ROLE_GRAPH_MAX_TIME_MS,
          ).to_a
          names = Array(docs.first && docs.first["names"])
          result_set = Set.new(
            names.reject { |n| n.nil? || n.to_s.empty? }.map(&:to_s),
          )
          payload[:result_count] = result_set.size
        end
        result_set
      rescue NotEnabled, GemNotAvailable
        nil
      rescue StandardError => e
        if defined?(::Mongo::Error::OperationFailure) &&
           e.is_a?(::Mongo::Error::OperationFailure)
          raise_if_timeout!(e, "_Join:users:_Role", ROLE_GRAPH_MAX_TIME_MS)
        end
        raise
      end

      # Resolve every `_User.objectId` whose effective role set includes
      # `role_id` — i.e., direct members of `role_id` PLUS direct members
      # of any descendant role in `role_id`'s inheritance subtree.
      #
      # Walks DOWN the inheritance tree via `$graphLookup` against
      # `_Join:roles:_Role` (parent → children → grandchildren), then
      # joins to `_Join:users:_Role` to pluck member ids, and finally
      # filters out tombstoned `_User` rows so the fast path matches
      # the soft-delete semantics the Parse-Server-backed path gets for
      # free via REST CLP enforcement.
      #
      # When called with a scoped `as:` argument (not master mode),
      # the `_User` `$lookup` sub-pipeline is augmented with an
      # `_rperm` `$match` so the joined `_User` rows are filtered to
      # ones the scope can read. Without this, the join leaks
      # `_User._id` regardless of caller authorization.
      #
      # Same authorization contract, return-value contract, and
      # error-policy as {role_names_for_user}.
      #
      # @param role_id [String] a Parse `_Role.objectId`.
      # @param max_depth [Integer] BFS depth bound.
      # @param master [Boolean] when `true`, bypass `_Role` CLP and the
      #   `_User` `_rperm` filter on the join. Mutually exclusive with
      #   `as:`.
      # @param as [Parse::User, Parse::Pointer, nil] caller-scope user.
      #   When provided, the scope is resolved via
      #   {Parse::ACLScope.resolve!}, the resulting permission set is
      #   checked against `_Role` CLP, and the resolved `_rperm`
      #   allow-set is injected into the `_User` join sub-pipeline.
      # @return [Set<String>, nil] resolved `_User.objectId`s, or nil
      #   when the fast path is unavailable.
      # @raise [ArgumentError] when neither `master:` nor `as:` is
      #   supplied, or when both are supplied.
      # @raise [Parse::CLPScope::Denied] when `as:` is supplied and the
      #   scope cannot `find` on `_Role`.
      def users_in_role_subtree(role_id, max_depth: ROLE_GRAPH_DEFAULT_DEPTH, master: false, as: nil)
        resolution = authorize_role_graph_call!(
          :users_in_role_subtree, master: master, as: as,
        )
        validate_role_graph_id!(role_id, "role_id")
        depth = validate_role_graph_depth!(max_depth)
        return Set.new if depth <= 0
        return nil unless available?

        graph_depth = depth - 1
        # Caller-scope path injects the resolved _rperm allow-set into
        # the _User sub-pipeline so the join honors row-level ACL.
        # Master mode leaves the sub-pipeline unscoped — the explicit
        # `master: true` is the operator's intent.
        rperm_allow = nil
        unless resolution.nil? || resolution.master?
          rperm_allow = resolution.permission_strings
        end
        pipeline = build_role_subtree_users_pipeline(
          role_id, graph_depth, rperm_allow: rperm_allow,
        )
        Parse::PipelineSecurity.validate_filter!(
          pipeline, allow_internal_fields: true,
        )

        result_set = nil
        ActiveSupport::Notifications.instrument(
          "parse.mongodb.role_graph",
          direction: :reverse, target_id: role_id, depth: depth,
        ) do |payload|
          docs = collection("_Join:roles:_Role").aggregate(
            pipeline, max_time_ms: ROLE_GRAPH_MAX_TIME_MS,
          ).to_a
          ids = Array(docs.first && docs.first["user_ids"])
          result_set = Set.new(
            ids.reject { |i| i.nil? || i.to_s.empty? }.map(&:to_s),
          )
          payload[:result_count] = result_set.size
        end
        result_set
      rescue NotEnabled, GemNotAvailable
        nil
      rescue StandardError => e
        if defined?(::Mongo::Error::OperationFailure) &&
           e.is_a?(::Mongo::Error::OperationFailure)
          raise_if_timeout!(e, "_Join:roles:_Role", ROLE_GRAPH_MAX_TIME_MS)
        end
        raise
      end

      # @!visibility private
      # True when the SDK's default client has a non-empty master key in
      # its boot configuration. This is a **process-level configuration
      # check**, NOT a per-call authorization check — it tells you that
      # the SDK was constructed with a master key, not that the caller
      # presented one. The two states are very different: a scoped agent
      # (acl_user / acl_role / session_token) running in a process whose
      # default client was booted with a master key will still see this
      # method return `true`, even though the caller has no master-key
      # authority.
      #
      # Retained for backwards-compat callers that introspect SDK boot
      # state. **Never use as an authorization gate**; use
      # {.authorize_role_graph_call!} (or the equivalent path-specific
      # check) for per-call authorization.
      def master_key_available?
        return false unless defined?(Parse) && Parse.respond_to?(:client)
        c = begin
              Parse.client
            rescue StandardError
              nil
            end
        return false if c.nil?
        key = c.respond_to?(:master_key) ? c.master_key : nil
        key.is_a?(String) && !key.empty?
      end

      # @!visibility private
      # Backwards-compat alias for {.master_key_available?}. Prefer the
      # new name in new code — `available?` reflects the actual meaning
      # ("the SDK has a master key it could use") more clearly than
      # `configured?` (which sounded like "the caller has master-key
      # authority"). Same warning applies: never an authorization gate.
      def master_key_configured?
        master_key_available?
      end

      # @!visibility private
      # Enforce per-call authorization for the role-graph helpers.
      # Caller must supply either `master: true` OR an explicit
      # `as: <User|Pointer>` scope; passing both is rejected. When `as:`
      # is supplied, the scope is resolved through
      # {Parse::ACLScope.resolve!} and the resulting permission set is
      # checked against `_Role` CLP via {Parse::CLPScope.permits?}. CLP
      # denial raises {Parse::CLPScope::Denied}. Master mode bypasses
      # the CLP check (analytics jobs, admin tooling).
      #
      # @param method_name [Symbol] caller's method name, for error msgs.
      # @param master [Boolean] explicit master-mode opt-in.
      # @param as [Parse::User, Parse::Pointer, nil] caller-scope user.
      # @return [Parse::ACLScope::Resolution] the resolved auth state.
      #   `resolution.master?` is true in master mode; otherwise the
      #   resolution carries the user's permission strings.
      # @raise [ArgumentError] when neither (or both) of `master:`/`as:`
      #   are provided.
      # @raise [Parse::CLPScope::Denied] when the resolved scope cannot
      #   `find` on `_Role`.
      def authorize_role_graph_call!(method_name, master:, as:)
        if master == true && !as.nil?
          raise ArgumentError,
                "Parse::MongoDB.#{method_name}: pass exactly one of " \
                "`master: true` or `as: <Parse::User|Parse::Pointer>`. " \
                "They are mutually exclusive."
        end

        if master == true
          return Parse::ACLScope::Resolution.new(
            mode: :master, permission_strings: nil, user_id: nil, session: nil,
          )
        end

        if as.nil?
          raise ArgumentError,
                "Parse::MongoDB.#{method_name}: refusing to enumerate the " \
                "role graph without an explicit authorization scope. Pass " \
                "`master: true` for admin/analytics use, OR `as: current_user` " \
                "to run under the caller's scope (subject to `_Role` CLP)."
        end

        resolution = Parse::ACLScope.resolve!({ acl_user: as }, method_name: method_name)
        unless resolution.master?
          perms = resolution.permission_strings
          unless Parse::CLPScope.permits?(Parse::Model::CLASS_ROLE, :find, perms)
            raise Parse::CLPScope::Denied.new(
              Parse::Model::CLASS_ROLE, :find,
              "Parse::MongoDB.#{method_name}: scope cannot `find` on " \
              "#{Parse::Model::CLASS_ROLE.inspect} under the current CLP. " \
              "Pass `master: true` to bypass, or grant the scope `find` " \
              "permission on _Role.",
            )
          end
        end
        resolution
      end

      # @!visibility private
      # Format-only validation: confirms `id` is a non-empty String of
      # up to 64 chars matching {ROLE_GRAPH_ID_RE}. Does **not** check
      # that the id exists in `_User` / `_Role` — that lookup would
      # require a second round-trip and would itself be subject to
      # authorization. The authorization contract enforced via
      # {.authorize_role_graph_call!} is the primary defense; this
      # validator is defense-in-depth against control-char injection
      # and oversize-string DoS in the `$match` predicate.
      def validate_role_graph_id!(id, name)
        unless id.is_a?(String) && ROLE_GRAPH_ID_RE.match?(id)
          raise ArgumentError,
                "Parse::MongoDB role-graph helpers require #{name} to match #{ROLE_GRAPH_ID_RE.inspect}; got #{id.inspect}"
        end
      end

      # @!visibility private
      def validate_role_graph_depth!(max_depth)
        unless max_depth.is_a?(Integer) && max_depth <= ROLE_GRAPH_MAX_DEPTH
          raise ArgumentError,
                "Parse::MongoDB role-graph helpers require max_depth to be an Integer no greater than #{ROLE_GRAPH_MAX_DEPTH}; got #{max_depth.inspect}"
        end
        max_depth
      end

      # @!visibility private
      def build_user_role_names_pipeline(user_id, graph_depth)
        pipeline = [
          { "$match" => { "relatedId" => user_id } },
          { "$graphLookup" => {
              "from" => "_Join:roles:_Role",
              "startWith" => "$owningId",
              "connectFromField" => "owningId",
              "connectToField" => "relatedId",
              "as" => "parent_chain",
              "maxDepth" => graph_depth,
          } },
          { "$project" => {
              "_id" => 0,
              "role_ids" => {
                "$setUnion" => [["$owningId"], "$parent_chain.owningId"],
              },
          } },
          { "$unwind" => "$role_ids" },
          { "$group" => { "_id" => nil, "ids" => { "$addToSet" => "$role_ids" } } },
          { "$lookup" => {
              "from" => "_Role",
              "localField" => "ids",
              "foreignField" => "_id",
              "as" => "roles",
          } },
          { "$project" => { "_id" => 0, "names" => "$roles.name" } },
        ]
        # Defense-in-depth: hardcoded-shape assertions catch any future
        # regression that interpolates a caller value into a
        # graph-traversal field. The validator can't tell the difference
        # between an SDK-built constant and a tainted value once the
        # pipeline is assembled, so we check here at the boundary.
        assert_user_role_names_pipeline_shape!(pipeline, user_id, graph_depth)
        pipeline
      end

      # @!visibility private
      def build_role_subtree_users_pipeline(role_id, graph_depth, rperm_allow: nil)
        # `_User` sub-pipeline: by default filter only tombstones; when
        # a scoped caller is in effect, also filter on _rperm so the
        # join honors row-level ACL. Master mode passes `rperm_allow: nil`
        # and gets the unscoped form (the explicit master opt-in is the
        # operator's intent).
        user_match = {
          "$expr" => { "$in" => ["$_id", "$$ids"] },
          "_tombstone" => { "$exists" => false },
        }
        if rperm_allow.is_a?(Array) && rperm_allow.any?
          user_match.merge!(Parse::ACL.read_predicate(rperm_allow))
        end

        pipeline = [
          { "$match" => { "owningId" => role_id } },
          { "$graphLookup" => {
              "from" => "_Join:roles:_Role",
              "startWith" => "$relatedId",
              "connectFromField" => "relatedId",
              "connectToField" => "owningId",
              "as" => "descendant_chain",
              "maxDepth" => graph_depth,
          } },
          { "$project" => {
              "_id" => 0,
              "role_ids" => {
                "$setUnion" => [["$relatedId"], "$descendant_chain.relatedId"],
              },
          } },
          { "$unwind" => "$role_ids" },
          { "$group" => { "_id" => nil, "ids" => { "$addToSet" => "$role_ids" } } },
          { "$project" => {
              "_id" => 0,
              "ids" => { "$setUnion" => ["$ids", [role_id]] },
          } },
          { "$lookup" => {
              "from" => "_Join:users:_Role",
              "localField" => "ids",
              "foreignField" => "owningId",
              "as" => "subscriptions",
          } },
          { "$project" => {
              "_id" => 0,
              "user_id_candidates" => "$subscriptions.relatedId",
          } },
          # Filter tombstoned _User rows AND project only `_id` server-side
          # via pipeline-form $lookup (3.6+). Without this, a role with N
          # members pulls N full _User docs (hashed_password, session
          # tokens, _auth_data_*) over the wire just to read `_id`. That
          # shape DoSes on a large role; the pipeline-form keeps the wire
          # payload bounded to N `_id` strings.
          #
          # When `rperm_allow` is non-empty (caller-scope path), the
          # `_rperm` match is folded into the sub-pipeline filter so the
          # join honors row-level ACL.
          { "$lookup" => {
              "from" => "_User",
              "let" => { "ids" => "$user_id_candidates" },
              "pipeline" => [
                { "$match" => user_match },
                { "$project" => { "_id" => 1 } },
              ],
              "as" => "active_users",
          } },
          { "$project" => {
              "_id" => 0,
              "user_ids" => "$active_users._id",
          } },
        ]
        # Defense-in-depth shape assertions (see comment in
        # build_user_role_names_pipeline for rationale).
        assert_role_subtree_users_pipeline_shape!(pipeline, role_id, graph_depth)
        pipeline
      end

      # @!visibility private
      # Hardcoded-shape assertion for build_user_role_names_pipeline.
      # Designed to fail loudly if a future change interpolates a caller
      # value into `connectFromField` / `connectToField` / `from` /
      # `startWith`. These fields drive the BFS direction in MongoDB; a
      # caller value here would be a query-injection primitive.
      def assert_user_role_names_pipeline_shape!(pipeline, user_id, graph_depth)
        raise "role-graph pipeline shape regression: $match.relatedId must equal user_id" \
          unless pipeline[0].is_a?(Hash) && pipeline[0]["$match"].is_a?(Hash) &&
                 pipeline[0]["$match"]["relatedId"] == user_id
        gl = pipeline[1] && pipeline[1]["$graphLookup"]
        raise "role-graph pipeline shape regression: missing $graphLookup stage" \
          unless gl.is_a?(Hash)
        raise "role-graph pipeline shape regression: $graphLookup.from must be a hardcoded String" \
          unless gl["from"] == "_Join:roles:_Role"
        raise "role-graph pipeline shape regression: $graphLookup.connectFromField must be hardcoded" \
          unless gl["connectFromField"] == "owningId"
        raise "role-graph pipeline shape regression: $graphLookup.connectToField must be hardcoded" \
          unless gl["connectToField"] == "relatedId"
        raise "role-graph pipeline shape regression: $graphLookup.startWith must be hardcoded" \
          unless gl["startWith"] == "$owningId"
        raise "role-graph pipeline shape regression: $graphLookup.maxDepth must be Integer" \
          unless gl["maxDepth"].is_a?(Integer) && gl["maxDepth"] == graph_depth
      end

      # @!visibility private
      # Hardcoded-shape assertion for build_role_subtree_users_pipeline.
      def assert_role_subtree_users_pipeline_shape!(pipeline, role_id, graph_depth)
        raise "role-graph pipeline shape regression: $match.owningId must equal role_id" \
          unless pipeline[0].is_a?(Hash) && pipeline[0]["$match"].is_a?(Hash) &&
                 pipeline[0]["$match"]["owningId"] == role_id
        gl = pipeline[1] && pipeline[1]["$graphLookup"]
        raise "role-graph pipeline shape regression: missing $graphLookup stage" \
          unless gl.is_a?(Hash)
        raise "role-graph pipeline shape regression: $graphLookup.from must be a hardcoded String" \
          unless gl["from"] == "_Join:roles:_Role"
        raise "role-graph pipeline shape regression: $graphLookup.connectFromField must be hardcoded" \
          unless gl["connectFromField"] == "relatedId"
        raise "role-graph pipeline shape regression: $graphLookup.connectToField must be hardcoded" \
          unless gl["connectToField"] == "owningId"
        raise "role-graph pipeline shape regression: $graphLookup.startWith must be hardcoded" \
          unless gl["startWith"] == "$relatedId"
        raise "role-graph pipeline shape regression: $graphLookup.maxDepth must be Integer" \
          unless gl["maxDepth"].is_a?(Integer) && gl["maxDepth"] == graph_depth
        # Final _User $lookup carries the hardcoded foreign collection.
        user_lookup = pipeline.find { |s| s.dig("$lookup", "from") == "_User" }
        raise "role-graph pipeline shape regression: missing _User $lookup stage" \
          unless user_lookup.is_a?(Hash)
      end

      # Execute an aggregation pipeline directly on MongoDB
      # @param collection_name [String] the collection name
      # @param pipeline [Array<Hash>] the aggregation pipeline stages
      # @param max_time_ms [Integer, nil] optional server-side time limit in milliseconds.
      #   When provided, MongoDB will cancel the query if it exceeds this budget and
      #   the driver error is translated to {Parse::MongoDB::ExecutionTimeout}.
      #   Pass `nil` (the default) for no cap.
      # @return [Array<Hash>] the raw results from MongoDB
      # @param rewrite_lookups [Boolean, nil] when true (default `nil` --
      #   reads `Parse.rewrite_lookups`), auto-rewrite LLM-style $lookup
      #   stages against logical class names into the Parse-on-Mongo
      #   column form when the foreign class declares `parse_reference`.
      # @param allow_internal_fields [Boolean] when true, skip the
      #   internal-fields denylist check (e.g. for SDK-generated ACL
      #   filters produced by {Parse::Query#readable_by_role} and friends
      #   that legitimately reference `_rperm`/`_wperm`). The
      #   DENIED_OPERATORS walk, forensic-operator-in-`$expr` check, and
      #   internal-field `$`-reference string check all still run.
      #   Passed `true` only from the SDK direct-execution sites that
      #   build their pipeline entirely from {Parse::Query#compile_where}:
      #   `Parse::Query#results_direct`, `#first_direct` (via
      #   `results_direct`), `#count_direct`, `#distinct_direct`,
      #   `#atlas_search` builder-block, and the two `#group_by_*` direct
      #   paths. The Agent MCP tool path and `Aggregation#execute_direct!`
      #   keep the default `false` so attacker-controlled or user-supplied
      #   aggregate stages cannot reach internal columns.
      # @param session_token [String, nil] when provided, the SDK
      #   resolves the token to the requesting user + role subscription
      #   (via {Parse::AtlasSearch::Session}) and prepends an
      #   `_rperm` `$match` stage to the pipeline so the result set
      #   simulates Parse Server's row-level ACL enforcement. This
      #   path is the only ACL boundary on a mongo-direct call — the
      #   underlying Mongo connection is admin-credentialed at
      #   `Parse::MongoDB.configure` time, so the SDK *is* the
      #   enforcement layer. Mutually exclusive with `master:`.
      # @param master [Boolean, nil] pass `true` to explicitly bypass
      #   the SDK's row-ACL injection (analytics jobs, admin tooling
      #   that legitimately needs to read across users). Mutually
      #   exclusive with `session_token:`.
      # @raise [Parse::MongoDB::DeniedOperator] if the pipeline contains
      #   a server-side JS or data-mutating operator at any depth.
      # @raise [Parse::MongoDB::ExecutionTimeout] if the query exceeds max_time_ms
      # @raise [Parse::ACLScope::ACLRequired] when neither
      #   `session_token:` nor `master: true` is supplied and
      #   {Parse::ACLScope.require_session_token} is enabled.
      def aggregate(collection_name, pipeline, max_time_ms: nil, rewrite_lookups: nil, allow_internal_fields: false, session_token: nil, master: nil, acl_user: nil, acl_role: nil, read_preference: nil, hint: nil)
        # AS::N envelope. Payload is intentionally metadata-only —
        # `stage_count`, `stage_types`, `collection`, `scope`,
        # `result_count`, `max_time_ms`, `read_preference`. Pipeline
        # bodies are NOT included: they routinely embed user-id
        # strings, tenant identifiers, search terms, and other PII
        # that has no business in a log line or an APM span. The
        # `parse.mongodb.role_graph` notification (emitted lower in
        # this module) nests as a child event when role expansion
        # runs inside the surrounding aggregate. `result_count` and
        # `scope` are seeded nil so subscribers see a stable key set
        # even on the raise path (where the block exits before either
        # is written).
        instrument_payload = {
          collection: collection_name,
          stage_count: pipeline.is_a?(Array) ? pipeline.size : 0,
          stage_types: __extract_stage_types(pipeline),
          max_time_ms: max_time_ms,
          read_preference: read_preference&.to_s,
          scope: nil,
          result_count: nil,
        }
        ActiveSupport::Notifications.instrument("parse.mongodb.aggregate", instrument_payload) do |payload|
        # Resolve auth kwargs into a Parse::ACLScope::Resolution. The
        # call MUTATES the temporary kwargs hash (popping the auth
        # entries) before the resolution; we package them into a hash
        # here only so the shared helper can stay path-agnostic. The
        # hash is local and discarded after the call.
        auth_kwargs = {
          session_token: session_token,
          master: master,
          acl_user: acl_user,
          acl_role: acl_role,
        }.compact
        resolution = Parse::ACLScope.resolve!(auth_kwargs, method_name: :aggregate)
        payload[:scope] = __scope_label(resolution)

        # Validate BEFORE rewrite so the security denylist is applied to the
        # caller's original pipeline (which an attacker controls), not to
        # the gem-rewritten form (which it doesn't). Matches the ordering
        # used by Parse::Query#aggregate and Parse::Agent::Tools.aggregate.
        assert_no_denied_operators!(pipeline, allow_internal_fields: allow_internal_fields)

        # Wave-3 TRACK-CLP-4: refuse any caller-supplied `$<field>`
        # reference that names a protectedField for the queried class
        # in the current scope. The post-fetch redact strips by NAME,
        # so a pipeline can launder a protected value through a
        # `$project: { renamed: "$ssn" }` (and similar) clauses and
        # bypass the strip silently. Catching the reference here at
        # parse-time refuses the join with `Parse::CLPScope::Denied`
        # so the bypass surfaces as an explicit error rather than a
        # quiet exfiltration. Master mode short-circuits inside the
        # scanner (no protected set on master).
        Parse::PipelineSecurity.refuse_protected_field_references!(
          pipeline, collection_name, resolution,
        )

        pipeline = Parse::LookupRewriter.auto_rewrite(
          pipeline, class_name: collection_name, enabled: rewrite_lookups,
        )

        # Three-layer ACL simulation on the mongo-direct path:
        #
        # 1. Top-level $match: filter the queried collection's rows by
        #    the session's _rperm allow-set. Mirrors Parse Server's
        #    REST find behavior.
        # 2. Pipeline rewriter: every $lookup / $unionWith / $graphLookup /
        #    $facet sub-pipeline gets the same _rperm filter embedded
        #    so joined rows from other collections are filtered at the
        #    database. Without this, includes/joins would silently leak
        #    rows the requesting session has no permission to read.
        # 3. Post-fetch redaction: walk the returned documents and
        #    scrub any embedded sub-documents whose stored _rperm
        #    doesn't match the perms set. Catches cases the rewriter
        #    can't reach (e.g., :object columns embedding raw pointer
        #    hashes, or caller-supplied $lookup stages that escaped
        #    rewriting because of unusual shapes).
        #
        # The security validator already ran on the caller's original
        # pipeline above; the injected stages reference `_rperm` but
        # are SDK-generated (not attacker-controlled), so no
        # re-validation is needed before they're handed to MongoDB.
        if (acl_stage = Parse::ACLScope.match_stage_for(resolution))
          pipeline = prepend_or_fold_acl_match(pipeline, acl_stage)
        end
        pipeline = Parse::ACLScope.rewrite_pipeline(pipeline, resolution)

        # Class-Level Permissions boundary check. Parse Server's REST
        # aggregate endpoint runs master-key-only and does NOT enforce
        # CLP; the mongo-direct path bypasses Parse Server entirely so
        # the SDK is the only enforcement layer. Refuse the call when
        # the resolved scope can't `find` on the collection. Master-
        # key (resolution.master? / nil permission_strings) bypasses.
        perms_for_clp = resolution&.permission_strings
        unless resolution.nil? || resolution.master?
          unless Parse::CLPScope.permits?(collection_name, :find, perms_for_clp)
            raise Parse::CLPScope::Denied.new(
              collection_name, :find,
              "CLP refuses find on '#{collection_name}' for the current scope.",
            )
          end
        end

        # Resolve the pointerFields constraint (if any) BEFORE running
        # the query — we apply the filter post-fetch but want to fail
        # loudly when the scope can't satisfy the constraint at all
        # (acl_role-only / public agents have no user_id to match).
        pointer_fields = nil
        unless resolution.nil? || resolution.master?
          pointer_fields = Parse::CLPScope.pointer_fields_for(collection_name, :find)
          if pointer_fields && resolution.user_id.nil?
            raise Parse::CLPScope::Denied.new(
              collection_name, :find,
              "CLP requires user identity (pointerFields=#{pointer_fields.inspect}) " \
              "but the current scope has no user_id.",
            )
          end
        end

        agg_opts = {}
        agg_opts[:max_time_ms] = max_time_ms if max_time_ms
        # Forced index hint (Query#hint). Mirrors Parse Server's REST `hint`
        # on the mongo-direct path so a bad plan diagnosed with `explain` can
        # be corrected here too. Accepts an index name (String) or a key
        # pattern (Hash).
        agg_opts[:hint] = hint unless hint.nil?
        coll = collection(collection_name)
        if (mode = normalize_read_preference(read_preference))
          coll = coll.with(read: { mode: mode })
        end
        results = coll.aggregate(pipeline, agg_opts).to_a
        Parse::ACLScope.redact_results!(results, resolution)

        # Post-fetch pointerFields filter: drop rows where none of the
        # named pointer fields references the requesting user. Skipped
        # for master-key and when the CLP has no pointerFields entry.
        if pointer_fields
          results = Parse::CLPScope.filter_by_pointer_fields(
            results, pointer_fields, resolution.user_id,
          )
        end

        # Protected fields stripping. Resolve the field set per the
        # session's claim composition and walk-delete from every
        # row + embedded sub-document. Top-level $project would also
        # work but doesn't reach inside `$lookup`-included sub-docs,
        # so the post-walker is the defense-in-depth layer.
        unless resolution.nil? || resolution.master?
          strip_set = Parse::CLPScope.protected_fields_for(
            collection_name, perms_for_clp,
          )
          Parse::CLPScope.redact_protected_fields!(results, strip_set) if strip_set.any?

          # Process-level floor: recursively strip Parse-internal credential
          # columns (_hashed_password, _session_token, _auth_data_*, _rperm,
          # ...) from every row AND every embedded sub-document. The
          # protectedFields strip above is keyed on the OUTER class, and the
          # ACL sub-doc walk only DROPS ACL-failing sub-docs — neither covers
          # a foreign class (e.g. _User / _Session) pulled in via $lookup /
          # $graphLookup / $unionWith under an arbitrary alias. Runs last, for
          # scoped (non-master) callers only; master is unredacted by design.
          results.each do |row|
            Parse::PipelineSecurity.redact_internal_fields_deep!(row)
          end
        end

        payload[:result_count] = results.size
        results
        end
      rescue => e
        raise_if_timeout!(e, collection_name, max_time_ms)
        raise
      end

      # Inject the scoped ACL `$match` at the front of a pipeline — UNLESS
      # the first stage is `$geoNear`, which MongoDB requires to be
      # pipeline stage 0. In that case fold the ACL predicate into
      # `$geoNear.query` (a candidate-document pre-filter, semantically
      # equivalent to a leading `$match`) so the stage-0 invariant holds
      # and the scoped geo query still enforces `_rperm`.
      #
      # A scoped `geo_near` previously failed CLOSED here: the prepended
      # `$match` pushed `$geoNear` off stage 0 and MongoDB rejected the
      # whole pipeline. Post-fetch redaction (protectedFields / sub-doc /
      # internal-field) runs regardless, so folding loses no enforcement.
      #
      # @param pipeline [Array<Hash>]
      # @param acl_stage [Hash] `{ "$match" => <predicate> }` from
      #   {Parse::ACLScope.match_stage_for}.
      # @return [Array<Hash>] a new pipeline; caller stages are not mutated.
      def prepend_or_fold_acl_match(pipeline, acl_stage)
        geo_key = geo_near_stage_key(pipeline.first)
        return [acl_stage] + pipeline unless geo_key

        match_pred = acl_stage["$match"] || acl_stage[:$match]
        geo = pipeline.first[geo_key].dup
        # Match the stage's own key style: reuse an existing `query` key of
        # either type, else follow the `$geoNear` key's type (string stage
        # → "query", symbol stage → :query). The Mongo driver normalizes
        # either way, but keeping one style avoids a duplicate query key.
        q_key =
          if geo.key?("query") then "query"
          elsif geo.key?(:query) then :query
          elsif geo_key.is_a?(String) then "query"
          else :query
          end
        existing = geo[q_key]
        geo[q_key] =
          if existing.is_a?(Hash) && !existing.empty?
            { "$and" => [existing, match_pred] }
          else
            match_pred
          end
        new_first = pipeline.first.dup
        new_first[geo_key] = geo
        [new_first] + pipeline[1..]
      end

      # @return [Symbol, String, nil] the `$geoNear` key (symbol or string
      #   form) if `stage` is a `$geoNear` stage, else nil.
      def geo_near_stage_key(stage)
        return nil unless stage.is_a?(Hash)
        return :$geoNear if stage.key?(:$geoNear)
        return "$geoNear" if stage.key?("$geoNear")
        nil
      end

      # Execute a `$geoNear` aggregation against a collection, returning
      # documents sorted by proximity to `near` along with their computed
      # distance. `$geoNear` is the aggregation-pipeline analogue of
      # `$nearSphere`; the headline differences are that it emits the
      # distance value on each returned doc (`distance_field:`) and that
      # downstream pipeline stages can compose with the proximity sort.
      #
      # A `2dsphere` index on the queried geo field is **required**; the
      # operation errors loudly without one (no silent collection scan).
      # `$geoNear` must be the first stage in the pipeline — Parse::MongoDB
      # places it correctly. The Mongo default 100-document cap was removed
      # in recent server versions, so pass an explicit `limit:` whenever
      # the caller would otherwise drain the entire collection.
      #
      # @example
      #   center = Parse::GeoPoint.new(32.7157, -117.1611)
      #   Parse::MongoDB.geo_near("Place",
      #     near: center,
      #     max_distance: 5,
      #     unit: :km,
      #     query: { category: "Park" },
      #     limit: 25,
      #   )
      #   # Each result document carries a `dist.calculated` field (meters).
      #
      # @param collection_name [String] the MongoDB collection name. Use
      #   `klass.parse_class` when starting from a Parse::Object subclass.
      # @param near [Parse::GeoPoint, Hash, Array] the anchor point.
      #   Accepts a {Parse::GeoPoint}, a GeoJSON `Point` Hash, or a
      #   `[longitude, latitude]` Array. Modern Mongo (8.0+) strictly
      #   validates GeoJSON-shaped input, so {Parse::GeoPoint} is preferred.
      # @param distance_field [String] output field name on each result
      #   document for the computed distance. Dot notation is permitted
      #   (e.g. `"dist.calculated"`). Defaults to `"distance"`.
      # @param max_distance [Numeric, nil] inclusive upper bound on
      #   distance. With a 2dsphere index, the wire unit is **meters**;
      #   pass `unit:` to convert from km or miles. With a legacy 2d
      #   index the wire unit is radians (advanced; caller's burden).
      # @param min_distance [Numeric, nil] inclusive lower bound, same
      #   unit semantics as `max_distance`.
      # @param unit [Symbol] one of `:meters` (default), `:km` /
      #   `:kilometers`, `:miles`. Converts the user-supplied `max_distance`
      #   and `min_distance` to meters before serializing.
      # @param spherical [Boolean] use spherical geometry. Defaults to
      #   `true` — the conventional pairing with 2dsphere + GeoJSON. Set
      #   to `false` only when querying a legacy planar 2d index.
      # @param query [Hash, nil] additional filter applied to candidate
      #   documents. Cannot contain a `$near` predicate (Mongo rejects).
      # @param include_locs [String, nil] when set, the matched location
      #   value is added to each result under this field name. Useful for
      #   documents that may hold multiple geo fields.
      # @param key [String, nil] explicit geo field path. Required when
      #   the collection has multiple geo indexes; otherwise Mongo picks
      #   the unique 2d/2dsphere index automatically.
      # @param distance_multiplier [Numeric, nil] post-computation scalar
      #   applied to every returned distance. The 2dsphere + meters path
      #   typically does not need this; legacy 2d callers can pass an
      #   Earth-radius constant to convert radians to km/miles.
      # @param limit [Integer, nil] when provided, appends a `$limit`
      #   stage. The Mongo default 100-doc cap is no longer applied
      #   automatically — set `limit:` (or pass `:limit => 0` to mean
      #   "unbounded; I really mean it") to control the size.
      # @param additional_stages [Array<Hash>] extra pipeline stages to
      #   append after `$geoNear` (and after `$limit` if any). Useful for
      #   `$lookup` joins, `$project` field shaping, etc. Each stage
      #   passes through the standard security validation.
      # @param max_time_ms [Integer, nil] server-side time limit; same
      #   semantics as {.aggregate}.
      # @return [Array<Hash>] documents enriched with `distance_field`
      #   (and `include_locs` when requested), in nearest-first order.
      # @raise [ArgumentError] when `near` is not a recognized point form
      #   or when `unit` is unknown.
      # @raise [Parse::MongoDB::DeniedOperator] if `query:` or
      #   `additional_stages:` contain a denied operator.
      # @raise [Parse::MongoDB::ExecutionTimeout] if the query exceeds
      #   `max_time_ms`.
      def geo_near(collection_name,
                   near:,
                   distance_field: "distance",
                   max_distance: nil,
                   min_distance: nil,
                   unit: :meters,
                   spherical: true,
                   query: nil,
                   include_locs: nil,
                   key: nil,
                   distance_multiplier: nil,
                   limit: nil,
                   additional_stages: [],
                   max_time_ms: nil,
                   session_token: nil,
                   master: nil,
                   acl_user: nil,
                   acl_role: nil,
                   read_preference: nil)
        stage = { :$geoNear => {
          near: geojson_point_for(near),
          distanceField: distance_field.to_s,
          spherical: spherical ? true : false,
        } }

        max_meters = convert_distance_to_meters(max_distance, unit) if max_distance
        min_meters = convert_distance_to_meters(min_distance, unit) if min_distance
        stage[:$geoNear][:maxDistance] = max_meters if max_meters
        stage[:$geoNear][:minDistance] = min_meters if min_meters
        stage[:$geoNear][:query] = query if query.is_a?(Hash) && !query.empty?
        stage[:$geoNear][:includeLocs] = include_locs.to_s if include_locs
        stage[:$geoNear][:key] = key.to_s if key
        stage[:$geoNear][:distanceMultiplier] = distance_multiplier if distance_multiplier

        pipeline = [stage]
        pipeline << { :$limit => limit } if limit && limit > 0
        pipeline.concat(Array(additional_stages))

        aggregate(collection_name, pipeline,
                  max_time_ms: max_time_ms,
                  session_token: session_token,
                  master: master,
                  acl_user: acl_user,
                  acl_role: acl_role,
                  read_preference: read_preference)
      end

      # Execute a find query directly on MongoDB
      # @param collection_name [String] the collection name
      # @param filter [Hash] the query filter
      # @param options [Hash] additional options (limit, skip, sort, projection, max_time_ms).
      #   When :limit is omitted, DEFAULT_FIND_LIMIT is applied before the
      #   cursor is materialized and a warning is emitted if the cap is hit.
      #   Pass `limit: 0` to explicitly request unbounded behavior.
      #   When :max_time_ms is provided, MongoDB will cancel the query if it
      #   exceeds the budget; the driver error is translated to
      #   {Parse::MongoDB::ExecutionTimeout}.
      # @return [Array<Hash>] the raw results from MongoDB
      # @raise [Parse::MongoDB::DeniedOperator] if the filter contains
      #   $where, $function, or $accumulator at any depth.
      # @raise [Parse::MongoDB::ExecutionTimeout] if the query exceeds max_time_ms
      def find(collection_name, filter = {}, **options)
        max_time_ms = options.delete(:max_time_ms)
        # Metadata-only AS::N payload: collection, presence-of-filter
        # (NOT body), projection keys (column names, not values), limit,
        # max_time_ms, result_count. Filter / projection bodies are
        # excluded because they routinely embed user-id strings,
        # tenant IDs, and other PII that has no business in a log line
        # or a span. The `find` payload deliberately has no `:scope`
        # field — `Parse::MongoDB.find` takes no ACL kwargs, so there
        # is no resolution to label. Shared subscribers that handle
        # both event names must treat `payload[:scope]` as optional.
        # `result_count` is seeded nil so subscribers see a stable key
        # set even on the raise path.
        projection_keys =
          if options[:projection].is_a?(Hash)
            options[:projection].keys.map(&:to_s)
          end
        instrument_payload = {
          collection: collection_name,
          has_filter: filter.is_a?(Hash) && !filter.empty?,
          projection_keys: projection_keys,
          limit: options[:limit],
          max_time_ms: max_time_ms,
          result_count: nil,
        }
        ActiveSupport::Notifications.instrument("parse.mongodb.find", instrument_payload) do |payload|
        allow_internal_fields = options.delete(:allow_internal_fields) || false
        assert_no_denied_operators!(filter, allow_internal_fields: allow_internal_fields)
        cursor = collection(collection_name).find(filter)
        explicit_limit = options.key?(:limit)
        applied_default_limit = false

        if explicit_limit
          cursor = cursor.limit(options[:limit]) if options[:limit] > 0
        else
          # Apply the hard default BEFORE to_a so we never materialize an
          # unbounded result set. Fetch one extra row so we can detect when
          # callers hit the cap and warn them.
          cursor = cursor.limit(DEFAULT_FIND_LIMIT + 1)
          applied_default_limit = true
        end

        cursor = cursor.skip(options[:skip]) if options[:skip]
        cursor = cursor.sort(options[:sort]) if options[:sort]
        cursor = cursor.projection(options[:projection]) if options[:projection]
        cursor = cursor.hint(options[:hint]) unless options[:hint].nil?
        cursor = cursor.max_time_ms(max_time_ms) if max_time_ms
        results = cursor.to_a

        if applied_default_limit && results.size > DEFAULT_FIND_LIMIT
          # Trim the sentinel row and warn — the caller asked for everything
          # but the result set is larger than the safety cap.
          results = results.first(DEFAULT_FIND_LIMIT)
          warn "[Parse::MongoDB.find] on '#{collection_name}' truncated to " \
               "#{DEFAULT_FIND_LIMIT} rows (no :limit specified). Pass an " \
               "explicit :limit to control the size, or :limit => 0 for " \
               "unbounded behavior."
        end

        payload[:result_count] = results.size
        results
        end
      rescue => e
        raise_if_timeout!(e, collection_name, max_time_ms)
        raise
      end

      # List Atlas Search indexes for a collection
      # Uses the $listSearchIndexes aggregation stage.
      # @param collection_name [String] the collection name
      # @return [Array<Hash>] array of search index definitions
      # @note Requires MongoDB Atlas or local Atlas deployment
      def list_search_indexes(collection_name)
        aggregate(collection_name, [{ "$listSearchIndexes" => {} }])
      end

      # List regular MongoDB indexes for a collection.
      # Hits the system catalog via the driver's `indexes.list` and returns
      # the raw definitions — distinct from {.list_search_indexes}, which
      # only enumerates Atlas Search indexes. Operator-facing introspection
      # used by `Parse::Core::Describe`.
      #
      # @param collection_name [String] the Parse collection / class name
      # @return [Array<Hash>] each entry includes at least `"name"` and
      #   `"key"` (`{ field => 1 | -1 | "text" | "2dsphere" }`), plus
      #   driver-reported flags like `"unique"`, `"sparse"`,
      #   `"partialFilterExpression"`, and `"expireAfterSeconds"` when set.
      def indexes(collection_name)
        collection(collection_name).indexes.to_a
      rescue StandardError => e
        # `listIndexes` raises NamespaceNotFound on collections that
        # haven't been created yet — treat as "no indexes" so describe
        # and plan paths degrade gracefully on empty databases.
        return [] if mongo_namespace_not_found?(e)
        raise
      end

      # Per-index usage statistics via the `$indexStats` aggregation
      # stage. Returns a Hash keyed by index name with `{ops:, since:}`
      # for each — `ops` is the number of times the index has been
      # accessed since the last MongoDB restart, `since` is the timestamp
      # of that restart (i.e. the start of the counting window). Empty
      # Hash on access error so callers (e.g. `Model.describe(:indexes,
      # network: true, usage: true)`) degrade gracefully when the
      # authenticated role lacks `clusterMonitor` (the minimum privilege
      # `$indexStats` requires).
      #
      # **Admin-only.** This is a metadata-disclosure surface (which
      # indexes are hot fingerprints which classes hold interesting
      # data) and so requires explicit `master: true` to invoke. The
      # previous behavior hard-coded `master: true` internally, which
      # was a copy-paste-lethal pattern for any future row-returning
      # path. Callers without master scope raise `ArgumentError`
      # internally; that error is caught by the method's own
      # degrade-to-empty rescue so existing best-effort callers
      # (`Parse::Model.describe(:indexes, usage: true)`) continue to
      # surface `usage_available: false` instead of blowing up — but
      # the `ArgumentError` is the loud signal for anyone introducing
      # a new caller that forgets the opt-in. Direct callers that
      # disable the rescue (test mocks, callers wrapping with their
      # own error handling) will see the `ArgumentError` propagate.
      #
      # @param collection_name [String]
      # @param master [Boolean] explicit master-mode opt-in. Required.
      # @return [Hash{String => Hash}] `{ index_name => { ops:, since: } }`,
      #   or `{}` when called without `master: true` (degrade-to-empty
      #   rescue).
      def index_stats(collection_name, master: false)
        unless master == true
          raise ArgumentError,
                "Parse::MongoDB.index_stats is admin-only and requires `master: true`. " \
                "$indexStats discloses cluster metadata; pass `master: true` to confirm " \
                "the caller is authorized. Callers without master scope (e.g. agent " \
                "tools, request handlers) must not invoke this method."
        end
        results = aggregate(collection_name, [{ "$indexStats" => {} }], master: true)
        results.each_with_object({}) do |row, h|
          name = row["name"] || row[:name]
          next unless name
          accesses = row["accesses"] || row[:accesses] || {}
          h[name] = {
            ops:   (accesses["ops"] || accesses[:ops]).to_i,
            since: accesses["since"] || accesses[:since],
          }
        end
      rescue StandardError
        # Lack of clusterMonitor / Atlas BI restriction / NamespaceNotFound
        # all surface here — `usage:` is best-effort by design.
        {}
      end

      # Convert a MongoDB document to Parse REST API format
      # This transforms MongoDB's internal field names to Parse's format:
      # - _id -> objectId
      # - _created_at -> createdAt
      # - _updated_at -> updatedAt
      # - _p_fieldName -> fieldName (as pointer)
      # - _acl -> ACL (with r/w converted to read/write)
      # - Removes other internal fields (_rperm, _wperm, _hashed_password, etc.)
      #
      # @param doc [Hash] the MongoDB document
      # @param class_name [String] the Parse class name
      # @return [Hash] the Parse-formatted hash
      def convert_document_to_parse(doc, class_name = nil)
        return nil unless doc.is_a?(Hash)

        result = {}

        doc.each do |key, value|
          key_str = key.to_s

          case key_str
          when "_id"
            # MongoDB _id becomes Parse objectId
            # Guard against BSON::ObjectId not being defined when mongo gem is not loaded
            result["objectId"] = if defined?(BSON::ObjectId) && value.is_a?(BSON::ObjectId)
                value.to_s
              else
                value
              end
          when "_created_at"
            # MongoDB _created_at becomes Parse createdAt
            result["createdAt"] = convert_date_to_parse(value)
          when "_updated_at"
            # MongoDB _updated_at becomes Parse updatedAt
            result["updatedAt"] = convert_date_to_parse(value)
          when /^_p_(.+)$/
            # Pointer fields: _p_author -> author
            field_name = $1
            result[field_name] = convert_pointer_to_parse(value)
          when "_acl"
            # Convert MongoDB ACL format (r/w) to Parse format (read/write)
            result["ACL"] = convert_acl_to_parse(value)
          when /^_included_(.+)$/
            # Included/resolved pointer field from $lookup - convert embedded document
            # This handles eager loading: _included_artist -> artist (as full object)
            field_name = $1
            if value.is_a?(Hash)
              # Recursively convert the embedded document to Parse format
              result[field_name] = convert_document_to_parse(value)
            elsif value.nil?
              # Preserve nil for unresolved optional relationships
              result[field_name] = nil
            else
              result[field_name] = value
            end
          when /^_include_id_/
            # Skip temporary lookup ID fields (used internally for $lookup)
            next
          when "_rperm", "_wperm", "_hashed_password", "_email_verify_token",
               "_perishable_token", "_tombstone", "_failed_login_count",
               "_account_lockout_expires_at", "_session_token"
            # Skip internal Parse Server fields (not needed since we use _acl)
            next
          when /^_/
            # Skip other internal fields starting with underscore
            next
          else
            # Regular fields - recursively convert nested documents
            result[key_str] = convert_value_to_parse(value)
          end
        end

        # Add className if provided
        result["className"] = class_name if class_name

        result
      end

      # Convert multiple MongoDB documents to Parse format
      # @param docs [Array<Hash>] the MongoDB documents
      # @param class_name [String] the Parse class name
      # @return [Array<Hash>] the Parse-formatted hashes
      def convert_documents_to_parse(docs, class_name = nil)
        docs.map { |doc| convert_document_to_parse(doc, class_name) }
      end

      # Convert a raw MongoDB aggregation row, coercing values (BSON ObjectIds,
      # dates, nested documents) but preserving all field names including `_id`.
      # Unlike {.convert_document_to_parse}, this does NOT rename `_id` to
      # `objectId`, because aggregation `$group` stages reuse `_id` as the
      # group key (e.g. a pointer string like `"Workspace$abc"`) rather than as a
      # Parse object identifier.
      #
      # @param doc [Hash] a raw MongoDB aggregation result row
      # @return [Hash] the coerced hash with stringified keys
      def convert_aggregation_document(doc)
        return nil unless doc.is_a?(Hash)
        doc.each_with_object({}) do |(key, value), result|
          result[key.to_s] = convert_value_to_parse(value)
        end
      end

      # Convert a date value to a UTC Time object suitable for MongoDB queries.
      # MongoDB stores all dates in UTC, so this helper ensures consistent date handling
      # when building aggregation pipelines or direct queries.
      #
      # @param value [Date, Time, DateTime, String, nil] the date value to convert
      # @return [Time, nil] a UTC Time object, or nil if value is nil
      # @raise [ArgumentError] if the value cannot be parsed as a date
      #
      # @example Converting different date types
      #   Parse::MongoDB.to_mongodb_date(Date.new(2024, 1, 15))
      #   # => 2024-01-15 00:00:00 UTC
      #
      #   Parse::MongoDB.to_mongodb_date(Time.now)
      #   # => 2024-11-30 12:30:45 UTC (converted to UTC)
      #
      #   Parse::MongoDB.to_mongodb_date("2024-01-15")
      #   # => 2024-01-15 00:00:00 UTC
      #
      #   Parse::MongoDB.to_mongodb_date("2024-01-15T10:30:00Z")
      #   # => 2024-01-15 10:30:00 UTC
      #
      # @example Using in aggregation pipelines
      #   cutoff = Parse::MongoDB.to_mongodb_date(Date.today - 30)
      #   pipeline = [{ "$match" => { "createdAt" => { "$gte" => cutoff } } }]
      #   results = Song.query.aggregate(pipeline, mongo_direct: true).results
      #
      # @example Using with query constraints
      #   # For date comparisons in queries, this ensures UTC consistency
      #   start_date = Parse::MongoDB.to_mongodb_date(params[:start_date])
      #   end_date = Parse::MongoDB.to_mongodb_date(params[:end_date])
      #   songs = Song.query(:release_date.gte => start_date, :release_date.lt => end_date)
      def to_mongodb_date(value)
        return nil if value.nil?

        case value
        when ::Time
          value.utc
        when ::DateTime
          value.to_time.utc
        when ::Date
          # Convert Date to midnight UTC
          ::Time.utc(value.year, value.month, value.day)
        when ::String
          # Parse string dates - try ISO 8601 first, then Date.parse
          begin
            if value =~ /T/
              # ISO 8601 with time component
              ::Time.parse(value).utc
            else
              # Date-only string, convert to midnight UTC
              date = ::Date.parse(value)
              ::Time.utc(date.year, date.month, date.day)
            end
          rescue ::ArgumentError => e
            raise ::ArgumentError, "Cannot parse '#{value}' as a date: #{e.message}"
          end
        when ::Integer
          # Assume Unix timestamp
          ::Time.at(value).utc
        else
          raise ::ArgumentError, "Cannot convert #{value.class} to MongoDB date. " \
                "Expected Date, Time, DateTime, String, or Integer."
        end
      end

      private

      # Cardinality cap on the `stage_types` payload field. A
      # pathological caller sending a 10k-stage pipeline shouldn't
      # be able to bloat every AS::N subscriber's log line.
      INSTRUMENT_STAGE_TYPES_LIMIT = 32

      # Extract the top-level operator name from each pipeline stage
      # (e.g. `["$match", "$lookup", "$project"]`). Returns an empty
      # array on anything non-Array; non-Hash entries become `nil`
      # and are pruned. Capped at {INSTRUMENT_STAGE_TYPES_LIMIT}.
      def __extract_stage_types(pipeline)
        return [] unless pipeline.is_a?(Array)
        types = pipeline.first(INSTRUMENT_STAGE_TYPES_LIMIT).map do |stage|
          stage.is_a?(Hash) ? stage.keys.first.to_s : nil
        end
        types.compact
      end

      # Map a {Parse::ACLScope::Resolution} to a stable, low-cardinality
      # scope label for the AS::N payload. Four values:
      # `:master` (master-key path), `:user` (session-token with a
      # resolved user_id, OR `acl_user:`), `:role` (`acl_role:` —
      # session mode but no user_id), `:anon` (public — neither
      # token nor master supplied).
      def __scope_label(resolution)
        return :anon if resolution.nil?
        return :master if resolution.master?
        return :anon if resolution.public?
        resolution.user_id ? :user : :role
      end

      # MongoDB error code for MaxTimeMSExpired
      MONGO_MAX_TIME_MS_EXPIRED_CODE = 50

      # Inspect a driver exception and raise {ExecutionTimeout} if it carries
      # error code 50 (MaxTimeMSExpired). Otherwise, the original exception is
      # re-raised by the caller.
      #
      # @param err [StandardError] the exception to inspect
      # @param collection_name [String] the collection name (for the timeout error)
      # @param max_time_ms [Integer, nil] the budget that was exceeded (may be nil)
      # @return [void]
      # @raise [Parse::MongoDB::ExecutionTimeout] when code == 50
      def raise_if_timeout!(err, collection_name, max_time_ms)
        return unless defined?(::Mongo::Error::OperationFailure)
        return unless err.is_a?(::Mongo::Error::OperationFailure)
        return unless err.respond_to?(:code) && err.code == MONGO_MAX_TIME_MS_EXPIRED_CODE

        raise ExecutionTimeout.new(
          collection_name: collection_name.to_s,
          max_time_ms: max_time_ms,
        )
      end

      def extract_database_from_uri(uri)
        return nil unless uri
        # Extract database name from MongoDB URI
        # Format: mongodb://[user:pass@]host[:port]/database[?options]
        if uri =~ %r{mongodb(?:\+srv)?://[^/]+/([^?]+)}
          $1
        end
      end

      def convert_date_to_parse(value)
        case value
        when Time, DateTime
          { "__type" => "Date", "iso" => value.utc.iso8601(3) }
        when Date
          { "__type" => "Date", "iso" => value.to_time.utc.iso8601(3) }
        when String
          # Already a string date, wrap in Parse format
          { "__type" => "Date", "iso" => value }
        else
          value
        end
      end

      def convert_pointer_to_parse(value)
        return nil if value.nil?

        if value.is_a?(String) && value.include?("$")
          # Parse pointer format: "ClassName$objectId"
          class_name, object_id = value.split("$", 2)
          {
            "__type" => "Pointer",
            "className" => class_name,
            "objectId" => object_id,
          }
        else
          value
        end
      end

      # Convert MongoDB ACL format to Parse REST API format
      # MongoDB uses short keys: { "*": { r: true, w: false }, "userId": { r: true, w: true } }
      # Parse uses full keys: { "*": { read: true }, "userId": { read: true, write: true } }
      # @param value [Hash] the MongoDB ACL hash
      # @return [Hash] the Parse-formatted ACL hash
      def convert_acl_to_parse(value)
        return nil if value.nil?
        return value unless value.is_a?(Hash)

        result = {}
        value.each do |entity, permissions|
          entity_str = entity.to_s
          next unless permissions.is_a?(Hash)

          parsed_perms = {}
          # Convert r -> read, w -> write
          if permissions["r"] == true || permissions[:r] == true
            parsed_perms["read"] = true
          end
          if permissions["w"] == true || permissions[:w] == true
            parsed_perms["write"] = true
          end
          # Also handle if already in full format
          if permissions["read"] == true || permissions[:read] == true
            parsed_perms["read"] = true
          end
          if permissions["write"] == true || permissions[:write] == true
            parsed_perms["write"] = true
          end

          result[entity_str] = parsed_perms if parsed_perms.any?
        end
        result
      end

      def convert_value_to_parse(value)
        case value
        when Hash
          if value["__type"]
            # Already a Parse type, return as-is
            value
          elsif value[:__type]
            # Symbol keys, convert to string keys
            value.transform_keys(&:to_s)
          elsif (geojson = detect_geojson_geometry(value))
            # MongoDB stores GeoJSON natively for any 2dsphere-indexed
            # field. Translate the two geometries Parse Server models
            # (Point/Polygon) back into their Parse wire-format hashes so
            # the caller's downstream code can treat mongo-direct results
            # identically to Parse REST responses. Other geometry types
            # (LineString, MultiPolygon, etc.) are left as raw GeoJSON
            # hashes since Parse Server has no schema slot for them.
            geojson
          else
            # Regular hash, recursively convert
            value.transform_values { |v| convert_value_to_parse(v) }
          end
        when Array
          value.map { |v| convert_value_to_parse(v) }
        when Time, DateTime
          convert_date_to_parse(value)
        when Date
          convert_date_to_parse(value)
        else
          # Handle BSON::ObjectId if mongo gem is loaded
          if defined?(BSON::ObjectId) && value.is_a?(BSON::ObjectId)
            value.to_s
          else
            value
          end
        end
      end

      # Coerce a user-supplied point value to a GeoJSON `Point` literal.
      # Accepts a {Parse::GeoPoint}, an already-shaped GeoJSON Point
      # Hash, or a `[longitude, latitude]` numeric Array.
      # @!visibility private
      def geojson_point_for(value)
        case value
        when Parse::GeoPoint
          { type: "Point", coordinates: [value.longitude, value.latitude] }
        when Hash
          hash = value.respond_to?(:symbolize_keys) ? value.symbolize_keys : value
          type = hash[:type] || hash["type"]
          coords = hash[:coordinates] || hash["coordinates"]
          unless type.to_s == "Point" && coords.is_a?(Array) && coords.length == 2 &&
                 coords.all? { |n| n.is_a?(Numeric) }
            raise ArgumentError, "[Parse::MongoDB.geo_near] `near:` hash must be a GeoJSON Point."
          end
          { type: "Point", coordinates: [coords[0].to_f, coords[1].to_f] }
        when Array
          unless value.length == 2 && value.all? { |n| n.is_a?(Numeric) }
            raise ArgumentError, "[Parse::MongoDB.geo_near] `near:` array must be [longitude, latitude]."
          end
          { type: "Point", coordinates: [value[0].to_f, value[1].to_f] }
        else
          raise ArgumentError, "[Parse::MongoDB.geo_near] `near:` must be a Parse::GeoPoint, " \
                               "GeoJSON Point Hash, or [longitude, latitude] Array."
        end
      end

      METERS_PER_KILOMETER = 1_000.0
      METERS_PER_MILE = 1_609.344

      # Convert a user-supplied distance + unit to meters (the wire unit
      # for `$geoNear` against a 2dsphere index).
      # @!visibility private
      def convert_distance_to_meters(value, unit)
        return value.to_f if unit == :meters || unit.nil?
        case unit
        when :km, :kilometers then value.to_f * METERS_PER_KILOMETER
        when :miles then value.to_f * METERS_PER_MILE
        else
          raise ArgumentError, "[Parse::MongoDB.geo_near] `unit:` must be :meters, :km, or :miles."
        end
      end

      # Detect a GeoJSON Point or Polygon geometry hash and convert it to
      # the equivalent Parse REST wire-format hash. Returns nil when the
      # input is not a recognized geometry, leaving the caller free to
      # treat it as a generic hash.
      # @return [Hash, nil]
      def detect_geojson_geometry(value)
        type = value["type"] || value[:type]
        coords = value["coordinates"] || value[:coordinates]
        return nil unless type.is_a?(String) && coords.is_a?(Array)

        case type
        when "Point"
          return nil unless coords.length == 2 && coords.all? { |n| n.is_a?(Numeric) }
          lng, lat = coords
          { "__type" => "GeoPoint", "latitude" => lat.to_f, "longitude" => lng.to_f }
        when "Polygon"
          # GeoJSON Polygon outer ring -> Parse [lat, lng] pairs.
          return nil unless coords.first.is_a?(Array)
          pairs = coords.first.map do |pair|
            return nil unless pair.is_a?(Array) && pair.length == 2 &&
                              pair[0].is_a?(Numeric) && pair[1].is_a?(Numeric)
            [pair[1].to_f, pair[0].to_f]
          end
          { "__type" => "Polygon", "coordinates" => pairs }
        end
      end

      public

      # Walk a filter hash or aggregation pipeline (Hash or Array) and
      # raise {DeniedOperator} if any nested key matches an entry in
      # {Parse::PipelineSecurity::DENIED_OPERATORS}.
      #
      # @param node [Hash, Array, Object] structure to walk.
      # @param allow_internal_fields [Boolean] when true, skip the
      #   {Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST} check.
      #   Forwarded to {Parse::PipelineSecurity.validate_filter!}. The
      #   DENIED_OPERATORS walk still runs. Intended only for callers
      #   that built the pipeline via {Parse::Query}'s own constraint
      #   DSL (e.g. {Parse::Query#readable_by_role}); raw user-supplied
      #   pipelines (Agent MCP tools) must keep the default `false`.
      #
      # Public for testability and for callers that want to validate
      # input before forwarding to {.find} / {.aggregate}.
      def assert_no_denied_operators!(node, allow_internal_fields: false)
        Parse::PipelineSecurity.validate_filter!(node, allow_internal_fields: allow_internal_fields)
        nil
      rescue Parse::PipelineSecurity::Error => e
        raise DeniedOperator, e.message
      end
    end

    # Initialize defaults
    @enabled = false
    @uri = nil
    @database = nil
    @client = nil
  end
end
