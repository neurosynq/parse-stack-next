# encoding: UTF-8
# frozen_string_literal: true

require "faraday"
require "moneta"
require "connection_pool"
require "digest"
require "securerandom"
require "json"
require_relative "protocol"

module Parse
  module Middleware
    # This is a caching middleware for Parse queries using Moneta. The caching
    # middleware will cache all GET requests made to the Parse REST API as long
    # as the API responds with a successful non-empty result payload.
    #
    # Whenever an object is created or updated, the corresponding entry in the cache
    # when fetching the particular record (using the specific non-Query based API)
    # will be cleared.
    class Caching < Faraday::Middleware
      include Parse::Protocol

      # List of status codes that can be cached:
      # * 200 - 'OK'
      # * 203 - 'Non-Authoritative Information'
      # * 300 - 'Multiple Choices'
      # * 301 - 'Moved Permanently'
      # * 302 - 'Found'
      # * 404 - 'Not Found' - removed
      # * 410 - 'Gone' - removed
      CACHEABLE_HTTP_CODES = [200, 203, 300, 301, 302].freeze
      # Cache control header
      CACHE_CONTROL = "Cache-Control"
      # Request env key for the content length
      CONTENT_LENGTH_KEY = "content-length"
      # Header in response that is sent if this is a cached result
      CACHE_RESPONSE_HEADER = "X-Cache-Response"
      # Header in request to set caching information for the middleware.
      CACHE_EXPIRES_DURATION = "X-Parse-Stack-Cache-Expires"
      # Header in request to enable write-only cache mode (skip read, still write)
      CACHE_WRITE_ONLY = "X-Parse-Stack-Cache-Write-Only"
      # Paths whose responses are never cached. `users/me` and `sessions/me`
      # answer "who owns this token", so a cached copy keeps a logged-out or
      # revoked token resolving to its user until the entry expires. The
      # credential endpoints carry a password and must never be stored.
      UNCACHEABLE_PATH_RE = %r{/(?:users/me|sessions/me|login|verifyPassword|logout)/?\z}.freeze
      # Prefix of the per-resource version keys. See {#version_keys}.
      LEGACY_VERSION_PREFIX = "rv"
      # Prefix of the per-class version keys folded into collection reads
      # (queries, aggregates). See {#version_keys}.
      CLASS_VERSION_PREFIX = "cv"
      # Request header BodyBuilder sets when it re-sends a long GET as a POST.
      METHOD_OVERRIDE = "X-Http-Method-Override"
      # Paths that name a Parse class, optionally followed by an object id.
      CLASS_PATH_RE = %r{(?:\A|/)(?:classes|aggregate|purge|schemas)/([^/]+)(?:/([^/]+))?/?\z}.freeze
      # Built-in class endpoints, optionally followed by an object id.
      SYSTEM_CLASS_PATH_RE = %r{(?:\A|/)(users|roles|installations|sessions)(?:/([^/]+))?/?\z}.freeze
      # Class names for the built-in class endpoints.
      SYSTEM_CLASSES = {
        "users" => "_User", "roles" => "_Role",
        "installations" => "_Installation", "sessions" => "_Session",
      }.freeze
      # Path of the batch endpoint, whose body names the resources it writes.
      BATCH_PATH_RE = %r{(?:\A|/)batch/?\z}.freeze

      class << self
        # @!attribute enabled
        # @return [Boolean] whether the caching middleware should be enabled.
        attr_writer :enabled

        # @!attribute logging
        # @return [Boolean] whether the logging should be enabled.
        attr_accessor :logging

        # @!attribute cache_session_requests
        # Whether reads made with a session token are cached. Off by default.
        #
        # A cached session read is answered without contacting Parse Server,
        # so it cannot notice that the session was revoked (logout,
        # {Parse::Session#destroy}, `logout_all!`, a password change) or that
        # the user lost a role or row access through a change the SDK did not
        # make. With this off, every session read reaches Parse Server, which
        # checks the token and the current ACLs and CLPs each time. Master-key
        # and anonymous reads are cached as before. Turning this on trades that
        # guarantee for speed: a revoked or narrowed session keeps reading its
        # cached responses until they expire.
        #
        # Only `true` enables it; any other value (including the String
        # `"true"` read from an environment variable) leaves session reads
        # uncached. A client can override this default with
        # `Parse.setup(cache_session_requests: true)` (the middleware option
        # of the same name).
        # @return [Boolean]
        attr_writer :cache_session_requests

        def cache_session_requests
          @cache_session_requests == true
        end

        def enabled
          @enabled = true if @enabled.nil?
          @enabled
        end

        # @return [Boolean] whether caching is enabled.
        def caching?
          @enabled
        end
      end

      # @!attribute [rw] store
      # The internal moneta cache store instance.
      # @return [Moneta::Transformer,Moneta::Expires]
      attr_accessor :store

      # @!attribute [rw] expires
      # The expiration time in seconds for this particular request.
      # @return [Integer]
      attr_accessor :expires

      # Creates a new caching middleware.
      # @param adapter [Faraday::Adapter] An instance of the Faraday adapter
      #  used for the connection. Defaults Faraday::Adapter::NetHttp.
      # @param store [Moneta] An instance of the Moneta cache store to use.
      # @param opts [Hash] additional options.
      # @option opts [Integer] :expires the default expiration for a cache entry.
      # @raise ArgumentError, if `store` is not a Moneta::Transformer or Moneta::Expires instance.
      def initialize(adapter, store, opts = {})
        super(adapter)
        @store = store
        @opts = { expires: 0 }
        @opts.merge!(opts) if opts.is_a?(Hash)
        @expires = @opts[:expires]
        # Per-middleware override of {.cache_session_requests}; nil defers to
        # the class-level default.
        @cache_session_requests =
          @opts.key?(:cache_session_requests) ? (@opts[:cache_session_requests] == true) : nil
        # Optional cache key namespace so two Parse apps sharing one Redis don't
        # collide (e.g. `mk:/classes/Song/abc` is the same path for both apps).
        # When set, keys become `<namespace>:<existing-prefix>:<url>`. Empty
        # string is treated as nil. Trailing `:` is stripped once so users can
        # pass either `"app_x"` or `"app_x:"`.
        ns = @opts[:namespace].to_s
        ns = ns.chomp(":")
        @namespace = ns.empty? ? nil : ns

        # The keyspace owns physical key layout and the patterns that clear it,
        # so key generation and eviction cannot drift apart. Previously this
        # middleware composed keys from its own `@namespace` while
        # `Parse::Cache::Redis` held a separate one, and `clear_cache!` used
        # only the latter: a client namespaced here but not there would clear
        # every SDK key on the database instead of its own.
        #
        # When no keyspace is supplied the middleware keeps writing legacy
        # un-prefixed keys, so an upgrade that does not opt in behaves exactly
        # as before.
        @keyspace = @opts[:keyspace]
        # During the transition, also delete the pre-keyspace form of a key on
        # invalidation. Without this, a rolling deploy has new workers writing
        # keyspaced keys while old workers still read legacy ones, so a write
        # served by a new worker never invalidates what an old worker serves.
        @delete_legacy_variants = @opts.fetch(:delete_legacy_variants, true)

        unless [:key?, :[], :delete, :store].all? { |method| @store.respond_to?(method) }
          raise ArgumentError, "Caching store object must a Moneta key/value store."
        end
      end

      # Thread-safety
      # @!visibility private
      def call(env)
        dup.call!(env)
      end

      # @!visibility private
      def call!(env)
        @request_headers = env[:request_headers]

        # get default caching state
        @enabled = self.class.enabled
        # disable cache for this request if "no-cache" was passed
        if @request_headers[CACHE_CONTROL] == "no-cache"
          @enabled = false
        end

        # Check for write-only mode (skip cache read, still write to cache)
        # This is useful for fetch!/reload! which want fresh data but should update cache
        @write_only = @request_headers[CACHE_WRITE_ONLY] == "true"

        # get the expires information from header (per-request) or instance default
        if @request_headers[CACHE_EXPIRES_DURATION].to_i > 0
          @expires = @request_headers[CACHE_EXPIRES_DURATION].to_i
        end

        # cleanup
        @request_headers.delete(CACHE_CONTROL)
        @request_headers.delete(CACHE_EXPIRES_DURATION)
        @request_headers.delete(CACHE_WRITE_ONLY)

        # if caching is enabled and we have a valid cache duration, use cache
        # otherwise work as a passthrough.
        return @app.call(env) unless @enabled && @store.present? && @expires > 0

        url = env.url
        method = env.method

        # Identity and credential endpoints are passthrough: never read, never
        # stored. See UNCACHEABLE_PATH_RE.
        return @app.call(env) if url.path.to_s.match?(UNCACHEABLE_PATH_RE)

        # A long query that BodyBuilder re-sent as a POST with a GET method
        # override is a read. It is never cached (only GETs are), and treating
        # it as a write would retire every cached query of its class each
        # time a long query ran.
        return @app.call(env) if method != :get && @request_headers[METHOD_OVERRIDE].to_s.casecmp?("GET")

        # A session read is never read from or stored in the cache unless the
        # application opted in (see {.cache_session_requests}): a cached answer
        # would keep serving a revoked or narrowed session until it expired.
        # The token header is set by the request layer from the effective
        # session (an explicit `session_token:`, `Parse.with_session`, or a
        # session-bound client), so this one check covers all three. Writes
        # made with a session still run the invalidation below.
        # Read the ambient cache tenant first so the bypass event carries it.
        @cache_tenant = Parse.respond_to?(:current_cache_tenant) ? Parse.current_cache_tenant : nil
        if method == :get && @request_headers.key?(SESSION_TOKEN) && !cache_session_requests?
          instrument_cache(:bypass, method: method, url_path: url.path, reason: :session)
          return @app.call(env)
        end

        @cache_key = url.to_s

        # Auth discriminator. A master-key request bypasses ACL, CLP and
        # protectedFields, so the same URL returns a strictly fuller body than a
        # session request, and two sessions can differ from each other through
        # protectedFields entity rules and row ACLs. These must never share a
        # cache entry or the cache would hand privileged fields to an
        # unprivileged caller.
        #
        # Both layouts also bind every key to the application id and the
        # credential that produced it (`@legacy_auth`, see {#versioned_key}).
        # Without that, a client configured with a different application id
        # or a wrong master/REST key, sharing the same store, was served
        # another application's cached private rows: the URL alone matched.
        # `@old_shape_key` is the pre-credential key shape, kept only so a
        # write still evicts entries written by older SDK versions during a
        # rolling deploy.
        @cache_auth = :anon
        app_id = @request_headers[APP_ID].to_s
        if @request_headers.key?(SESSION_TOKEN)
          @session_token = @request_headers[SESSION_TOKEN]
          hashed_token = Digest::SHA256.hexdigest(@session_token.to_s)[0, 32]
          @cache_auth = hashed_token
          @old_shape_key = "#{hashed_token}:#{@cache_key}" # prefix with hashed token
          @legacy_auth = "s:#{credential_digest(app_id, @session_token)}"
        elsif @request_headers.key?(MASTER_KEY)
          @cache_auth = :master
          @old_shape_key = "mk:#{@cache_key}" # prefix for master key requests
          @legacy_auth = "mk:#{credential_digest(app_id, @request_headers[MASTER_KEY])}"
        else
          @old_shape_key = @cache_key
          @legacy_auth = "an:#{credential_digest(app_id, @request_headers[API_KEY])}"
        end
        @cache_key = "#{@legacy_auth}:#{@cache_key}"
        @app_id = app_id

        # Optional ambient cache-tenant scope from `Parse.with_cache_tenant`.
        # When present, composes between the configured namespace and the
        # token/mk prefix as `T:<tenant>:` so a SCAN-delete over
        # `<namespace>:T:<tenant>:*` evicts exactly one tenant, and
        # `<namespace>:*` still evicts the whole namespace cleanly. The
        # `T:` discriminator makes tenant prefixes unambiguously
        # distinguishable from session-token hex prefixes (32-char hex)
        # and from `mk:`, so legacy cache entries written before the
        # tenant feature don't accidentally re-hydrate into a tenanted
        # request and vice versa.
        if @cache_tenant
          @cache_key = "T:#{@cache_tenant}:#{@cache_key}"
          @old_shape_key = "T:#{@cache_tenant}:#{@old_shape_key}"
        end

        # Namespace outermost so a SCAN over `<namespace>:*` evicts a whole
        # tenant/app cleanly without touching another app's entries.
        if @namespace
          @cache_key = "#{@namespace}:#{@cache_key}"
          @old_shape_key = "#{@namespace}:#{@old_shape_key}"
        end

        # Keep the legacy key base for versioning below. The live key is
        # built by {#versioned_key} once the versions are known, in the
        # keyspace form when one is configured.
        @legacy_cache_key = @cache_key
        @cache_key = nil

        url_path = url.path

        begin
          # Resolve the current versions and fold them into the key, in both
          # layouts. The resource version retires every credential variant
          # of a resource on a write to it; collection reads also carry the
          # class version, which any write to the class replaces (see
          # {#version_keys}).
          #
          # A read establishes its versions BEFORE the request goes out,
          # creating any that are missing, and later stores its response
          # only under those. Resolving them after the response instead let
          # a read that started before a write but finished after it adopt
          # the versions the write had just created and store its older
          # body under them, so a revoked row was served to every later
          # reader. A write only reads them: `nil` means a version does not
          # exist yet, so no entry bound to it can be live.
          @versions = method == :get ? establish_versions(url) : read_versions(url)
          @cache_key = @versions ? versioned_key(url, @versions) : nil
          # Skip cache read if write_only mode is enabled
          if method == :get && @cache_key.present? && !@write_only && @store.key?(@cache_key)
            # Debug-log the URL **path only** — `url.to_s` would include the
            # query string, which Parse encodes JSON `where=` into and may
            # contain PII. Same redaction discipline as the AS::N payload.
            puts("[Parse::Cache] Hit >> #{url_path}") if self.class.logging.present?
            response = Faraday::Response.new
            begin
              cache_data = @store[@cache_key] # previous cached response
            rescue => e
              # Log only the class name — some Moneta/Redis drivers echo the
              # offending key in `e.message`, and our key contains a hashed
              # session-token prefix that we treat as side-channel material.
              puts "[Parse::Cache] Error: #{e.class.name}"
              instrument_cache(:error, method: method, url_path: url_path, error: e.class.name)
              cache_data = nil
            end

            # check if the store was from a legacy parse-stack cache value which
            # is stored as Faraday::Env. T\he new system stores less content in a simple hash
            # for improved interoperability and access time.
            body = nil
            response_headers = nil
            if cache_data.is_a?(Faraday::Env)
              body = cache_data.respond_to?(:body) ? cache_data.body : nil
              response_headers = cache_data.response_headers || {}
            elsif cache_data.is_a?(Hash)
              # New entries are stored with string keys so they survive a
              # JSON round-trip (the Redis cache wrapper serializes values as
              # JSON, not Marshal — see Parse::Cache::Redis). Fall back to
              # symbol keys for legacy in-memory / Marshal-backed entries
              # written before that switch.
              body = cache_data["body"] || cache_data[:body]
              response_headers = cache_data["headers"] || cache_data[:headers] || {}
            end

            if cache_data.present? && body.present?
              response_headers[CACHE_RESPONSE_HEADER] = "true"
              response.finish({ status: 200, response_headers: response_headers, body: body })
              instrument_cache(:hit, method: method, url_path: url_path)
              return response
            else
              delete_cache_variants(url)
              instrument_cache(:miss, method: method, url_path: url_path, reason: :empty_payload)
            end
          elsif method == :get && !@write_only
            # GET miss: opportunistically clear any sibling variants of the
            # current namespace (anonymous `<url>` and master-key `mk:<url>`
            # under the same namespace) so a stale variant from a prior
            # request flavor doesn't linger until TTL.
            #
            # When @namespace is set we deliberately do NOT touch the bare
            # un-namespaced `<url>` / `mk:<url>` keys — those could belong to
            # another Parse app sharing the Redis DB, and cross-namespace
            # eviction would be a blast-radius bug, not a fix. Operators
            # upgrading an SDK that previously wrote un-namespaced keys
            # should evict those once at upgrade time via SCAN.
            delete_cache_variants(url)
            instrument_cache(:miss, method: method, url_path: url_path)
          elsif method == :get && @write_only
            delete_cache_variants(url)
            instrument_cache(:miss, method: method, url_path: url_path, reason: :write_only)
          elsif method != :get
            #non GET requets should clear the cache for that same resource path.
            #ex. a POST to /1/classes/Artist/<objectId> should delete the cache for a GET
            # request for the same '/1/classes/Artist/<objectId>' where objectId are equivalent
            @write_targets = write_targets(env, url)
            delete_cache_variants(url, resource: true)
            instrument_cache(:delete, method: method, url_path: url_path)
          end
          # `Redis::CommandError` covers the failures a scoped eviction can now
          # produce that a plain GET/SET never did: a NOPERM from a restricted
          # ACL, an UNLINK the server does not implement, and a CROSSSLOT refusal
          # under Redis Cluster. Without it those escape the middleware and turn a
          # cache problem into a failed application request, which inverts the
          # whole point of the cache being optional.
        rescue *cache_store_errors => e
          # if the cache store fails to connect, catch the exception but proceed
          # with the regular request, but turn off caching for this request. It is possible
          # that the cache connection resumes at a later point, so this is temporary.
          @enabled = false
          puts "[Parse::Cache] Error: #{e.class.name}"
          instrument_cache(:error, method: method, url_path: url_path, error: e.class.name)
        end

        @app.call(env).on_complete do |response_env|
          # Only cache GET requests with valid HTTP status codes whose content-length
          # is between 20 bytes and 1MB. Otherwise they could be errors, successes and empty result sets.

          if @enabled && method == :get && CACHEABLE_HTTP_CODES.include?(response_env.status) &&
             response_env.body.present? && response_env.response_headers[CONTENT_LENGTH_KEY].to_i.between?(20, 1_250_000)
            store_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            begin
              # Store only under the versions established before dispatch,
              # and only if none of them changed while the request was in
              # flight. A change means a write landed during the request, so
              # this body may predate it (a row whose ACL was just revoked,
              # for instance) and must not be cached under any version.
              if @versions && @cache_key && read_versions(url) == @versions
                # Store with string keys (and a plain Hash of headers) so the
                # value round-trips losslessly through the Redis cache
                # wrapper's JSON serialization. The read path above reads
                # string keys first with a symbol-key fallback for legacy
                # entries.
                @store.store(@cache_key,
                             { "headers" => response_env.response_headers.to_h, "body" => response_env.body },
                             expires: @expires)
                duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - store_start) * 1000.0).round(3)
                instrument_cache(:store, method: method, url_path: url_path, duration_ms: duration_ms)
              elsif self.class.logging.present?
                puts("[Parse::Cache] Skip store, version changed in flight >> #{url_path}")
              end
            rescue => e
              puts "[Parse::Cache] Store Error: #{e.class.name}"
              instrument_cache(:error, method: method, url_path: url_path, error: e.class.name)
            end
          end # if

          # Retire the written resources again once the server has applied
          # the write. A reader that established the versions the pre-write
          # bump created, and then fetched the pre-write state, would
          # otherwise cache it under live versions; a row whose ACL was just
          # revoked would then stay readable until the entry expired. The
          # second bump makes that reader's versions stale, so its in-flight
          # check skips the store, or its stored entry becomes unreachable.
          if @write_targets
            begin
              bump_versions(url, @write_targets)
            rescue => e
              puts "[Parse::Cache] Error: #{e.class.name}"
              instrument_cache(:error, method: method, url_path: url_path, error: e.class.name)
            end
          end
        end
      end

      private

      # Store errors that disable caching for the request rather than fail
      # it. The Redis and connection_pool classes are listed only when those
      # libraries are loaded: naming an unloaded constant in a `rescue`
      # raises NameError while the rescue is evaluated, so a TypeError from a
      # memory or other non-Redis store would escape as
      # "uninitialized constant Redis" instead of falling back.
      #
      # @return [Array<Class>]
      def cache_store_errors
        errors = [::TypeError, Errno::EINVAL, Errno::ECONNREFUSED]
        if defined?(::Redis)
          # In redis-rb 5, CannotConnectError, TimeoutError and
          # ConnectionError are siblings under BaseConnectionError, and
          # ReadOnlyError (a replica after failover) sits under CommandError.
          # Each name is checked on its own because older releases lack some.
          %w[BaseConnectionError CannotConnectError TimeoutError ConnectionError
             CommandError ReadOnlyError].each do |name|
            errors << ::Redis.const_get(name) if ::Redis.const_defined?(name, false)
          end
        end
        # redis-rb 5 is built on redis-client, whose errors can surface
        # unwrapped from some code paths.
        errors << ::RedisClient::Error if defined?(::RedisClient::Error)
        errors << ::ConnectionPool::TimeoutError if defined?(::ConnectionPool::TimeoutError)
        errors.uniq
      end

      # Emit an ActiveSupport::Notifications event under the `parse.cache.*`
      # namespace.
      #
      # **Payload shape (stable):** `{ event:, namespace:, cache_tenant:,
      # method:, url_path:, [reason:], [duration_ms:], [error:] }`.
      # `cache_tenant` is the active `Parse.with_cache_tenant` value, or nil.
      #
      # **Security invariants:**
      # - The cache key is NEVER emitted. The key contains a hashed
      #   session-token prefix that would be a side-channel for "this user
      #   has data at this URL" enumeration.
      # - `url_path` is `URI#path` only — query strings are stripped because
      #   Parse encodes query JSON there (potentially long or PII-bearing).
      # - `error` is `Exception#class.name` only — never the exception
      #   message or backtrace.
      # - `namespace` is whatever the SDK consumer configured at setup. Treat
      #   subscribers as you would your application log sink: they observe
      #   the namespace, the HTTP method, and the URL path of every cached
      #   GET / invalidating write.
      #
      # **Subscriber discipline:** ActiveSupport::Notifications runs
      # subscribers **synchronously on the Faraday request thread**. A
      # blocking subscriber (e.g. synchronous I/O to a slow sink) blocks
      # every cached request for the duration of its work, and an exception
      # raised inside a subscriber will surface as a request failure. Keep
      # subscribers cheap — counter increments, in-memory accumulators, or
      # non-blocking sinks like StatsD-over-UDP.
      # @!visibility private
      def instrument_cache(event, **extra)
        return unless defined?(ActiveSupport::Notifications)
        payload = {
          event: event,
          namespace: @namespace,
          cache_tenant: @cache_tenant,
        }.merge!(extra)
        ActiveSupport::Notifications.instrument("parse.cache.#{event}", payload)
      end

      # Whether this middleware caches session reads: its own
      # `cache_session_requests:` option when given, else the class default.
      # @!visibility private
      def cache_session_requests?
        @cache_session_requests.nil? ? self.class.cache_session_requests : @cache_session_requests
      end

      # Delete the canonical cache_key plus its legacy un-namespaced and
      # master-key-prefixed variants. Called on both GET misses (defensive
      # cleanup of stale pre-namespace entries) and non-GET writes (cache
      # invalidation for the resource).
      # @!visibility private
      # @param resource [Boolean] when true, evict every auth variant of this
      #   resource, not just the caller's own entry. Only a write should do
      #   that. On a GET miss this method is called defensively to clear stale
      #   siblings, and evicting resource-wide there would destroy other
      #   sessions' perfectly valid entries on every single cache miss.
      def delete_cache_variants(url, resource: false)
        delete_keyspace_variants(url) if resource && @keyspace
        delete_legacy_variants(url) if legacy_variants?
        @store.delete @cache_key if @cache_key # final key
        # A write replaces the versions of everything it touched, which
        # retires every credential variant in either layout: other sessions'
        # entries included, which a delete cannot name. This is what stops a
        # user whose read access was just revoked from reading the cached
        # copy, directly or through a cached query over the class.
        bump_versions(url, @write_targets || [url.path]) if resource
      end

      # Digest binding a legacy cache key to the application and the
      # credential that authorized the request. Truncated SHA-256: the key is
      # never a credential, only a discriminator.
      # @!visibility private
      def credential_digest(app_id, credential)
        Digest::SHA256.hexdigest("#{app_id}\x00#{credential}")[0, 32]
      end

      # Version keys a read of this URL is bound to: the resource version
      # for its path and, for a collection read (a query, an aggregate, or a
      # list of a built-in class), the version of the class.
      #
      # The resource version is keyed by application and URL path (no query
      # string), and NOT by credential or tenant, so a write through any
      # caller retires the entries of every caller. Using the path means a
      # write to `classes/Post/abc` also retires `classes/Post/abc?include=...`.
      #
      # The class version is what retires cached queries. A query result for
      # `classes/Post?where=...` can contain any Post, so a write to one
      # (an update, an ACL change, a delete, a create, or a batch touching
      # the class) replaces the class version and every cached Post query
      # becomes unreachable. Single-object reads do not carry it, so a write
      # to one object leaves other objects' cached reads alone.
      # @!visibility private
      # @return [Array<String>]
      def version_keys(url)
        keys = [version_key(LEGACY_VERSION_PREFIX, "#{url_origin(url)}#{url.path}")]
        class_name, object_id = class_scope(url.path)
        if class_name && object_id.nil?
          keys << version_key(CLASS_VERSION_PREFIX, "#{url_origin(url)}\x00#{class_name}")
        end
        keys
      end

      # Store key for one version. Truncated SHA-256 of the application id
      # and the material, so no path or class name appears in the key. In
      # the keyspace layout it sits in the cache family, outside any tenant,
      # so a write under one tenant retires every tenant's entries and a
      # whole-keyspace clear still removes it.
      # @!visibility private
      def version_key(prefix, material)
        digest = Digest::SHA256.hexdigest("#{@app_id}\x00#{material}")[0, 32]
        return "#{@keyspace.family_prefix(:cache)}:#{prefix}:#{digest}" if @keyspace
        key = "#{prefix}:#{digest}"
        @namespace ? "#{@namespace}:#{key}" : key
      end

      # @!visibility private
      def url_origin(url)
        "#{url.scheme}://#{url.host}:#{url.port}"
      end

      # The class a path addresses and the object id, if any.
      # @!visibility private
      # @return [Array(String, String), nil] `[class_name, object_id_or_nil]`.
      def class_scope(path)
        path = path.to_s
        if (m = path.match(CLASS_PATH_RE))
          [m[1], m[2]]
        elsif (m = path.match(SYSTEM_CLASS_PATH_RE))
          [SYSTEM_CLASSES[m[1]], m[2]]
        end
      end

      # @!visibility private
      # @return [Array<String>, nil] the current versions, or nil when any
      #   of them does not exist yet.
      def read_versions(url)
        versions = version_keys(url).map { |key| read_version(key) }
        versions.include?(nil) ? nil : versions
      end

      # The current versions, creating any that do not exist yet. Called
      # before a read is dispatched, so the read is bound to versions that
      # exist before the server answers it.
      # @!visibility private
      # @return [Array<String>]
      def establish_versions(url)
        version_keys(url).map { |key| establish_version(key) }
      end

      # The current value of one version key, creating it when missing.
      #
      # Creation must not overwrite a version a concurrent write just
      # bumped: the reader would then hold a version the write never
      # retires. Where the store has an atomic set-if-absent (`create`),
      # a lost race simply adopts the winner's value. Otherwise the value
      # is written and read back, and whatever the store then holds is the
      # version used. A write that landed in between still makes its
      # post-response bump, which the in-flight check in {#call!} detects.
      # @!visibility private
      # @return [String]
      def establish_version(key)
        current = read_version(key)
        return current if current
        version = SecureRandom.hex(8)
        if store_creates?
          begin
            return version if @store.create(key, version, expires: legacy_version_ttl)
            current = read_version(key)
            return current if current
          rescue NotImplementedError
            # Fall through to a plain write and read-back.
          end
        end
        @store.store(key, version, expires: legacy_version_ttl)
        read_version(key) || version
      end

      # @!visibility private
      # @return [String, nil]
      def read_version(key)
        value = @store[key]
        value.is_a?(String) && !value.empty? ? value : nil
      end

      # Whether the store offers an atomic set-if-absent.
      # @!visibility private
      def store_creates?
        return false unless @store.respond_to?(:create)
        return true unless @store.respond_to?(:supports?)
        !!@store.supports?(:create)
      end

      # Replace a version with a fresh random one. A random value rather
      # than a counter: if the version key expires and is recreated, a
      # counter could return to a value that older entries still carry and
      # bring them back. A fresh nonce never matches an old entry.
      # @!visibility private
      # @return [String] the new version.
      def write_version(key)
        version = SecureRandom.hex(8)
        @store.store(key, version, expires: legacy_version_ttl)
        version
      end

      # Replace the resource version of every written path and the class
      # version of every class those paths belong to.
      # @!visibility private
      def bump_versions(url, paths)
        origin = url_origin(url)
        keys = []
        paths.each do |path|
          keys << version_key(LEGACY_VERSION_PREFIX, "#{origin}#{path}")
          class_name, = class_scope(path)
          keys << version_key(CLASS_VERSION_PREFIX, "#{origin}\x00#{class_name}") if class_name
        end
        keys.uniq.each { |key| write_version(key) }
      end

      # Paths a write touches: the request path, plus every non-GET sub-request
      # of a batch. A batch body that cannot be read contributes nothing
      # beyond the batch path itself.
      # @!visibility private
      # @return [Array<String>]
      def write_targets(env, url)
        targets = [url.path]
        return targets unless url.path.to_s.match?(BATCH_PATH_RE)
        mount = url.path.to_s.sub(BATCH_PATH_RE, "")
        batch_requests(env.body).each do |sub|
          next unless sub.is_a?(Hash)
          next if (sub["method"] || sub[:method]).to_s.casecmp?("GET")
          path = (sub["path"] || sub[:path]).to_s
          next if path.empty?
          path = path.start_with?("/") ? path : "#{mount}/#{path}"
          targets << path.split("?", 2).first
        end
        targets.uniq
      end

      # @!visibility private
      def batch_requests(body)
        body = JSON.parse(body) if body.is_a?(String)
        list = body.is_a?(Hash) ? (body["requests"] || body[:requests]) : nil
        list.is_a?(Array) ? list : []
      rescue JSON::ParserError
        []
      end

      # The version key only needs to outlive the entries bound to it. When it
      # expires first, those entries become unreachable (a miss), never stale.
      # @!visibility private
      def legacy_version_ttl
        [@expires.to_i * 2, 60].max
      end

      # The live cache key for a read bound to `versions`. Both layouts bind
      # the key to the credential that produced the body (`@legacy_auth`: a
      # digest of the application id with the session token, master key or
      # REST key actually sent), so a wrong master key or another REST key
      # cannot read an entry cached under the right one.
      #
      # In the keyspace layout the credential digest and the versions are
      # folded into the auth segment, after the URL digest, so
      # {Parse::Cache::Keyspace#resource_pattern} still matches every
      # credential and version variant of a resource.
      # @!visibility private
      def versioned_key(url, versions)
        tag = versions.join(".")
        if @keyspace
          auth = Digest::SHA256.hexdigest("#{@legacy_auth}\x00#{tag}")[0, 32]
          @keyspace.cache_key(url, auth: auth, tenant: @cache_tenant)
        else
          "#{@legacy_cache_key}#v=#{tag}"
        end
      end

      # Whether to also evict the pre-keyspace key shape. Always true before a
      # keyspace is configured, since that shape is the only one in use.
      # @!visibility private
      def legacy_variants?
        @keyspace.nil? || @delete_legacy_variants
      end

      # Evict every auth variant of this resource, not just the caller's own.
      #
      # The old two-variant delete could name the anonymous and master-key
      # siblings but had no way to enumerate *other sessions'* entries, so a
      # write by one user left every other user holding a stale copy until TTL.
      # A scan-capable store can express that as one pattern; anything else
      # falls back to the variants we can name.
      # @!visibility private
      def delete_keyspace_variants(url)
        pattern = @keyspace.resource_pattern(url, tenant: @cache_tenant)
        if @store.respond_to?(:delete_matching)
          @store.delete_matching(pattern)
        else
          # Pre-credential key shapes, from before entries were bound to the
          # credential and versions. A store that cannot match a pattern has
          # no way to name the current variants of other callers; the
          # version bump in {#delete_cache_variants} retires those instead.
          @store.delete @keyspace.cache_key(url, auth: :anon, tenant: @cache_tenant)
          @store.delete @keyspace.cache_key(url, auth: :master, tenant: @cache_tenant)
          @store.delete @keyspace.cache_key(url, auth: @cache_auth, tenant: @cache_tenant)
        end
      end

      # Evict the pre-keyspace key shape so a rolling deploy does not leave old
      # workers serving entries that a new worker's write should have killed.
      # @!visibility private
      def delete_legacy_variants(url)
        if @namespace
          # Namespaced: only delete our app's variants so a write through
          # client A doesn't blow away client B's cache when both share Redis.
          @store.delete "#{@namespace}:#{url.to_s}"
          @store.delete "#{@namespace}:mk:#{url.to_s}"
        else
          @store.delete url.to_s # regular
          @store.delete "mk:#{url.to_s}" # master key cache-key
        end
        # The caller's own entry in the pre-credential shape.
        @store.delete @old_shape_key if @old_shape_key
      end
    end #Caching
  end #Middleware
end
