# encoding: UTF-8
# frozen_string_literal: true

require "moneta"
require "json"
require "securerandom"
require_relative "pool"
require_relative "keyspace"
require_relative "sub_cache"
require_relative "upstream_roles"
require_relative "scoped_view"

module Parse
  module Cache
    # Ergonomic Redis cache builder for Parse Stack. Composes a
    # ConnectionPool of Moneta-Redis stores and carries an optional
    # `namespace` that `Parse::Client` will pick up automatically — there
    # is no need to also pass `cache_namespace:` to `Parse.setup` when
    # using this wrapper.
    #
    # Usage:
    #   Parse.setup(
    #     cache: Parse::Cache::Redis.new(
    #       url: "redis://localhost:6379/0",
    #       namespace: "app_x",
    #       pool_size: 10,
    #     ),
    #     expires: 60,
    #     ...
    #   )
    #
    # The instance is a Moneta-compatible store (it delegates the four
    # methods the Faraday caching middleware uses — `[]`, `key?`,
    # `delete`, `store` — to a pooled backend), so it can be passed
    # directly to `Parse.setup(cache:)` / `Parse::Client.new(cache:)`.
    class Redis
      # @return [String, nil] cache key namespace prefix (or nil if not set).
      attr_reader :namespace

      # @return [Integer] pool size.
      attr_reader :pool_size

      # @return [String] Redis connection URL.
      attr_reader :url

      # There is deliberately no `keyspace` reader/writer and no `keyspace:`
      # constructor option on this class anymore. This backend is a shared
      # connection pool: several {Parse::Client} instances (several Parse
      # apps, or several tenants) pointing one `Parse::Cache::Redis` at the
      # same Redis is a normal, supported deployment. A mutable keyspace
      # binding on the SHARED object was not, because a second client
      # calling `keyspace = ks_b` rebound the one `@keyspace` ivar out from
      # under the first: client A's caching middleware kept using A's
      # keyspace object (captured at construction) while `clear`, `identity`,
      # `roles`, and the memoized `upstream_roles` on this now-shared object
      # answered with B's. A stopped invalidating its own entries, or a
      # scoped `clear` issued through A deleted B's keys instead.
      #
      # {#scoped} replaces that mutable path entirely: it hands back a
      # {Parse::Cache::ScopedView} carrying its own keyspace and its own
      # memoized identity/roles/upstream_roles, so two callers can share this
      # backend's connection pool without ever being able to share, or steal,
      # keyspace ownership.
      #
      # Derive a per-client view over this shared backend.
      #
      # @param keyspace [Parse::Cache::Keyspace]
      # @return [Parse::Cache::ScopedView]
      def scoped(keyspace)
        Parse::Cache::ScopedView.new(backend: self, keyspace: keyspace)
      end

      # @return [String, nil] Parse Server's cache database URL, when attached.
      attr_reader :parse_cache_url

      # Read-only view of Parse Server's role cache, or nil when not attached.
      #
      # Uses a raw redis-rb client rather than the Moneta pool: Moneta's Redis
      # adapter issues a MULTI/PEXPIRE pipeline on every read when built with
      # `expires:`, which a credential restricted to `+get +pttl` rejects with
      # NOPERM.
      #
      # This backend-level reader has no keyspace, and therefore no app id or
      # role-plane freshness gate to scope itself with: {#scoped} is the only
      # way to bind one to an app. Its `app_id` is nil, so `key_for` /
      # `roles_for` on this instance can never match a real Parse Server
      # entry (which is always `<appId>:role:<userId>`). They will only
      # ever report a miss. Prefer `backend.scoped(keyspace).upstream_roles`
      # for any real read. This method is NOT used by
      # {#verify_upstream_isolation!}, which needs a database-wide probe
      # rather than one scoped to a single (missing) app id and builds its
      # own reader.
      # @return [Parse::Cache::UpstreamRoles, nil]
      def upstream_roles
        return nil if @parse_cache_url.nil?
        @upstream_roles ||= UpstreamRoles.new(client: upstream_client, app_id: nil, roles_plane: nil)
      end

      # Verify the attached endpoint is a different database from ours, and warn
      # if not.
      #
      # Deliberately a warning rather than a refusal: the hazard comes entirely
      # from the upstream FLUSHDB bug, so it disappears on a server carrying the
      # scoped-clear fix, and refusing to boot would be permanently wrong there.
      # It routes through the existing degraded-lock path so the caller's
      # `on_degraded:` decides whether to warn or raise, because the consequence
      # that is not merely a performance loss is a create-lock deleted mid-hold,
      # which silently removes `first_or_create!` mutual exclusion.
      #
      # Three outcomes, because two of them were previously collapsed into
      # one and the collapse hid a false negative:
      #
      # - `true`: isolation positively established. A sentinel written to our
      #   database was NOT visible through the upstream connection.
      # - `false`: sharing positively established, and warned about.
      # - `:unknown`: neither could be established. Truthy, so callers that
      #   branch on truthiness behave as before, but distinguishable for
      #   callers that want to escalate. This is what a credential restricted
      #   to `~<appId>:role:*` produces: the sentinel read comes back NOPERM,
      #   which says nothing about which database it was denied on.
      #
      # The scan alone cannot return `true`. It only ever finds a
      # Parse-Server-shaped key or fails to, and "no such key" is equally
      # consistent with a separate database and with a shared one on which
      # Parse Server has not yet cached a role. A stack that was just
      # deployed is in that second state, which is precisely when an operator
      # runs this check, so treating the empty scan as proof of isolation
      # returned a confident "isolated" for the shared case it exists to
      # catch.
      #
      # @return [Boolean, :unknown] see above.
      def verify_upstream_isolation!(on_degraded: :warn_throttled)
        return true if @parse_cache_url.nil?
        # Deliberately NOT {#upstream_roles}: this backend has no keyspace
        # (and therefore no app id: that can only come from {#scoped} now)
        # to build a reader from, and there is no single "the" app id to use
        # here anyway: this backend can be shared by clients of more than one
        # app (see {#scoped}), and this check is a database-sharing probe,
        # not a per-app one.
        #
        # `UpstreamRoles#shares_database_with?` scans for
        # `"#{app_id}:role:*"`. Two wrong ways to pick `app_id` were tried and
        # rejected here, in favor of a third:
        #
        # - `nil` turns that into the literal pattern `":role:*"`, which never
        #   matches a real Parse Server key (`<appId>:role:<userId>`, no
        #   leading colon), so the probe always reports "isolated", even on
        #   a database that is genuinely shared. Silently disables the exact
        #   warning this method exists to raise.
        # - A bare `"*"` wildcard produces `"*:role:*"`. Redis (and
        #   `File.fnmatch`) glob `*` crosses `:` just like any other
        #   character, so that pattern ALSO matches this SDK's own role-plane
        #   keys (`parse-stack:v1:<scope>:<ns>:role:<userId>`). The probe
        #   would report "shared" as soon as the role plane held anything,
        #   even on a database that is genuinely isolated. A permanent false
        #   positive is worse than the false negative it replaced: it trains
        #   operators to ignore the warning.
        #
        # The fix keeps the broad `"*"` wildcard (so this still catches ANY
        # app's cached role, not one we'd have to already know the id of) but
        # filters this SDK's own `parse-stack:`-rooted keys out of what the
        # scanner hands back, so `shares_database_with?` never sees them and
        # can only match a genuine Parse Server entry.
        reader = UpstreamRoles.new(client: upstream_client, app_id: "*")
        # The probe scans OUR database for THEIR key pattern, so it needs a
        # scannable client rather than this Moneta-shaped wrapper.
        shared = @pool.pool.with do |store|
          reader.shares_database_with?(ExcludeOwnKeysScanner.new(backend_client(store)))
        end

        unless shared
          # The scan found nothing, which does not distinguish a separate
          # database from a shared one Parse Server has not written to yet.
          # Settle it by writing a key only we can have written and asking
          # the upstream connection whether it can see it.
          #
          # Only two of the three outcomes return. `:shared` deliberately
          # falls through to the warning path below, which is the same
          # handling a positive scan gets.
          case sentinel_probe
          when :isolated then return true
          when :unknown
            warn "[Parse::Cache::Redis] could not verify that parse_cache_url addresses a " \
                 "different Redis database than url. The probe key was neither readable nor " \
                 "conclusively absent through the upstream connection, which is what a " \
                 "credential restricted to ~<appId>:role:* produces. Confirm the two " \
                 "databases differ by hand, or grant the reader GET on parse-stack:probe:* " \
                 "so this check can answer. " \
                 "See https://github.com/parse-community/parse-server/issues/10617"
            return :unknown
          end
        end

        if defined?(Parse::LockBackend)
          Parse::LockBackend.handle_degraded(
            on_degraded, "cache:shared-database", source: "Parse::Cache::Redis"
          )
        end
        warn "[Parse::Cache::Redis] parse_cache_url resolves to the same Redis database as " \
             "url. Parse Server clears its cache with FLUSHDB on every _Role write, which " \
             "deletes this SDK's cached responses and its parse-stack:foc:v1:* create-locks, " \
             "so first_or_create! loses cross-process mutual exclusion. Point the two at " \
             "different databases (redis://host/0 and redis://host/1), or run a Parse Server " \
             "carrying the scoped-clear fix. " \
             "See https://github.com/parse-community/parse-server/issues/10617"
        false
      end

      # Note: there is no `identity` / `roles` plane accessor on this class.
      # Both require a keyspace, and a keyspace can only ever be bound
      # through {#scoped} now, never directly on this shared backend. Use
      # `backend.scoped(keyspace).identity` / `.roles` instead.

      # @param url [String] Redis URL (e.g. `"redis://localhost:6379/0"`).
      # @param namespace [String, nil] optional key prefix so multiple Parse
      #   apps can share one Redis without colliding. When non-nil, the
      #   namespace is automatically forwarded to the caching middleware
      #   as `cache_namespace:`.
      # @param pool_size [Integer] number of pooled Moneta-Redis stores.
      #   Defaults to 5 (the Puma default thread count).
      #
      #   **Sizing math (per Faraday request):**
      #   - cache hit: `key?` + `[]` = **2 checkouts**
      #   - GET miss + successful store: `key?` + 3 variant deletes
      #     (anonymous + master-key sibling + final key) + 1 `store` in
      #     `on_complete` = **up to 5 checkouts**
      #   - non-GET write (POST/PUT/DELETE): 3 variant deletes =
      #     **3 checkouts**
      #
      #   The worst case (5) is on the write-through-after-miss path, not
      #   the hit path. Rule of thumb: start at `pool_size = RAILS_MAX_THREADS`,
      #   then bump it up if you observe `ConnectionPool::TimeoutError` in
      #   `parse.cache.error` notifications (the middleware swallows that
      #   error into a passthrough request rather than raising to the caller).
      # @param pool_timeout [Numeric] seconds to wait for a backend
      #   checkout before raising `ConnectionPool::TimeoutError`. Defaults
      #   to 5s. The caching middleware catches that error and falls back
      #   to a passthrough request rather than raising to the caller.
      # @param moneta_options [Hash] extra options passed through to
      #   `Moneta.new(:Redis, ...)` (e.g. `:db`, `:connect_timeout`).
      #   `expires: true` is set automatically so per-key TTLs supplied
      #   by the caching middleware (the `:expires` Faraday option) are
      #   honored by Redis. Pass `expires: false` here to opt out — but
      #   note that doing so causes cached responses to live forever,
      #   which is rarely what you want for a session-token-scoped
      #   response cache.
      def initialize(url:, namespace: nil, pool_size: 5, pool_timeout: 5,
                     parse_cache_url: nil, **moneta_options)
        @url = url
        # Parse Server's own cache database, read-only and optional. It must NOT
        # be the same database as `url:`: on released Parse Server a `_Role`
        # write FLUSHDBs the whole database, which would take this SDK's
        # response cache and, worse, its create-locks with it.
        @parse_cache_url = parse_cache_url
        @namespace = normalize_namespace(namespace)
        # A caller-supplied Moneta `prefix:` silently rewrites the physical key
        # layout underneath us, which would break every SCAN pattern this class
        # builds and quietly restore the unscoped-clear behavior the keyspace
        # exists to prevent. Reject it rather than trying to compose with it.
        if moneta_options.key?(:prefix)
          raise ArgumentError,
                "Parse::Cache::Redis does not accept a Moneta prefix: option; it would " \
                "change the physical key layout that scoped clearing depends on. Use " \
                "namespace: instead."
        end
        @pool_size = pool_size
        @pool_timeout = pool_timeout
        # Default expires: true so per-call `expires:` (the TTL the
        # Faraday caching middleware passes on store) is honored. The
        # Moneta-Redis adapter ignores per-call expires unless the
        # store was constructed with this flag. Without it, cached
        # session-scoped REST responses outlive their token's
        # validity. Callers can still pass `expires: false` to opt out.
        merged_options = { expires: true }.merge(moneta_options)
        # SECURITY: disable Moneta's value serializer so cached values are NOT
        # Marshal-encoded. We JSON-(de)serialize values ourselves in #store /
        # #[] (see #encode_value / #decode_value). The default Moneta-Redis
        # value serializer is Marshal, which would `Marshal.load` whatever
        # bytes come back from Redis on every cache hit — an arbitrary-code-
        # execution primitive if the Redis cache is shared, unauthenticated,
        # or reachable through a plaintext `redis://` MITM. Forcing nil here
        # (overriding any caller-supplied `value_serializer:`/`serializer:`)
        # keeps that gadget-deserialization vector closed regardless of how
        # the wrapper is configured. Keys keep the default (:marshal) encoding:
        # they are only ever written and SCAN/DEL-compared as opaque strings,
        # never `Marshal.load`ed from Redis content, so they are not a
        # deserialization vector.
        merged_options = merged_options.merge(value_serializer: nil)
        @moneta_options = merged_options
        @closed = false
        @pool = Pool.new(size: pool_size, timeout: pool_timeout) do
          Moneta.new(:Redis, { url: url }.merge(merged_options))
        end
      end

      def [](key)
        decode_value(@pool[key])
      end

      def key?(key)
        @pool.key?(key)
      end

      def delete(key)
        @pool.delete(key)
      end

      def store(key, value, options = {})
        @pool.store(key, encode_value(value), options)
      end

      # Atomic SETNX. Required so `Parse::CreateLock` can acquire
      # cross-process locks when this wrapper is the configured cache /
      # `synchronize_create_store`. Returns `true` only when the key did
      # not already exist. The value goes through the same JSON encoding
      # as {#store} so a later {#[]} read round-trips instead of decoding
      # to nil. (Parse::LockBackend never hits this path on this wrapper —
      # it prefers the raw-Redis {#lock_acquire}/{#lock_release} pair.)
      def create(key, value, options = {})
        @pool.create(key, encode_value(value), options)
      end

      # Atomic counter increment. Forwarded for Moneta surface parity.
      def increment(key, amount = 1, options = {})
        @pool.increment(key, amount, options)
      end

      # Lua compare-and-delete: delete `key` only if its current value
      # equals `expected`. Atomic on the Redis server (the GET, the
      # compare, and the DEL are one script invocation), which closes the
      # check-then-delete race in a naive GET-then-DEL release where the
      # lease can expire and be re-acquired by another holder between the
      # two commands.
      LOCK_RELEASE_SCRIPT = <<~LUA
        if redis.call('get', KEYS[1]) == ARGV[1] then
          return redis.call('del', KEYS[1])
        else
          return 0
        end
      LUA

      # Atomically acquire a lock: SET key=owner only if absent, with a
      # native expiry. Used by {Parse::LockBackend} for {Parse::Lock} and
      # {Parse::CreateLock}. Deliberately bypasses Moneta's `create` —
      # `Moneta.new(:Redis)` marshals keys (and, by default, values), so a
      # raw-Redis compare-and-delete on a Moneta-encoded blob would be
      # fragile and coupled to Moneta's serializer config. Routing acquire
      # AND release through plain-string raw Redis here keeps one consistent
      # encoding across both ends of the lock and makes the keys human-
      # inspectable in Redis (`parse-stack:lock:v1:<digest>`). Lock keys are
      # short-lived (TTL ≤ 30s) so there is no migration concern when a
      # deploy flips encodings.
      #
      # @param key [String] plain-string lock key.
      # @param owner [String] unique-per-acquisition owner token.
      # @param ttl [Integer] seconds until the key self-clears.
      # @return [Boolean] true when the key was set (lock acquired).
      def lock_acquire(key, owner, ttl)
        @pool.pool.with do |store|
          redis = backend_client(store)
          # redis-rb returns "OK" on success, nil when NX fails.
          !!redis.set(key, owner, nx: true, ex: ttl)
        end
      end

      # Atomically release a lock via compare-and-delete. Only the holder
      # whose `owner` token still matches the stored value deletes the
      # key — a holder whose lease already expired and was re-acquired by
      # someone else is a no-op, never a cross-holder delete.
      #
      # @param key [String] plain-string lock key.
      # @param owner [String] the owner token from {#lock_acquire}.
      # @return [Boolean] true when this owner's key was deleted.
      def lock_release(key, owner)
        @pool.pool.with do |store|
          redis = backend_client(store)
          redis.eval(LOCK_RELEASE_SCRIPT, keys: [key], argv: [owner]).to_i == 1
        end
      end

      # Clear cached entries belonging to this wrapper. Required for
      # `Parse::Client#clear_cache!` compatibility.
      #
      # **Namespace-scoped when a namespace is set:** the wrapper walks
      # `<namespace>:*` via Redis SCAN and DELs the matching keys,
      # leaving other tenants on the same DB untouched. When no
      # namespace is configured the wrapper falls back to `FLUSHDB` on
      # the backing DB — same blast radius as previous versions, but
      # only for unnamespaced deployments. To opt into the wide
      # FLUSHDB explicitly (e.g. ops tooling), call {#flush_db!}.
      #
      # @param scope [String, nil] explicit namespace prefix to scan-delete.
      #   When provided, overrides the wrapper's configured `@namespace` and
      #   SCAN-deletes `<scope>:*` regardless of how the wrapper was built.
      #   This is the safe escape hatch for tenants that share a non-
      #   namespaced wrapper but still want to evict only their own keys
      #   without `FLUSHDB`-ing siblings (and without wiping
      #   `parse-stack:foc:v1:*` create-lock keys that live on the same DB).
      #   The scope must be a non-empty String; the trailing `:` is added
      #   automatically and any trailing `:` in the input is stripped so
      #   `"tenant_x"` and `"tenant_x:"` are equivalent.
      #
      # This backend never has a keyspace of its own (see {#scoped}), so
      # `family:` / `tenant:` cannot be honored here: interpreting them needs
      # a `root_prefix`, and only a {Parse::Cache::ScopedView} has one.
      #
      # Passing either is therefore a hard error rather than a silent
      # no-op. Ignoring them would take the `else` branch below and issue
      # `FLUSHDB`, so a caller asking to clear ONE family on an unnamespaced
      # backend would wipe the entire database: every other family, every
      # other app sharing the backend, and the `parse-stack:foc:v1:*`
      # create-locks whose loss silently removes `first_or_create!` mutual
      # exclusion. A request to narrow must never widen. Use
      # `backend.scoped(keyspace).clear(family:)` instead.
      #
      # @raise [ArgumentError] when `family:` or `tenant:` is given.
      def clear(scope: nil, family: nil, tenant: nil)
        unless family.nil? && tenant.nil?
          raise ArgumentError,
                "Parse::Cache::Redis#clear cannot honor family:/tenant: without a keyspace, " \
                "and ignoring them here would fall through to FLUSHDB. " \
                "Call backend.scoped(keyspace).clear(family:, tenant:) instead."
        end

        if scope
          prefix = validate_scope!(scope)
          delete_keys_matching!("#{prefix}:*")
        elsif @namespace
          delete_keys_matching!("#{@namespace}:*")
        else
          @pool.clear
        end
        self
      end

      # Delete every key matching a glob pattern. Exposed so the caching
      # middleware can evict all auth variants of one resource on write, which
      # it cannot do by naming keys: it has no way to enumerate the entries
      # belonging to sessions this process has never seen.
      #
      # This backend never has a keyspace of its own (see {#scoped}), so a
      # direct call here is always a no-op: there is no root_prefix to
      # confine the pattern to. Callers with a keyspace should call
      # `backend.scoped(keyspace).delete_matching(pattern)` instead, which
      # confines the pattern to that view's own root_prefix before it ever
      # reaches Redis.
      #
      # @param pattern [String] a Redis glob pattern.
      # @return [Integer] number of keys removed. Always 0 on this backend.
      def delete_matching(pattern)
        0
      end

      # Issue `FLUSHDB` on the backing Redis DB, regardless of whether a
      # namespace is configured. Evicts every key on the selected DB,
      # including unrelated tenants — use only for ops tooling that
      # owns the whole DB.
      def flush_db!
        @pool.clear
        self
      end

      # Close all pooled connections. Safe to call multiple times.
      def close
        return if @closed
        @closed = true
        @pool.close
      end

      private

      # Redis-rb-shaped decorator used only by {#verify_upstream_isolation!}.
      # Wraps the raw scan-capable client and strips this SDK's own keys
      # (everything rooted under `Parse::Cache::Keyspace::ROOT`, i.e.
      # `"parse-stack:"`) out of every SCAN batch before
      # `UpstreamRoles#shares_database_with?` ever sees it. That is what lets
      # the isolation probe use a broad, app-id-less `"*"` pattern (catching
      # ANY app's Parse-Server-shaped role cache key) without the glob also
      # matching this SDK's own role-plane keys
      # (`parse-stack:v1:<scope>:<ns>:role:<userId>`), which would otherwise
      # make the probe report "shared" as soon as the role plane held
      # anything, on a database that is in fact isolated.
      class ExcludeOwnKeysScanner
        OWN_PREFIX = "#{Keyspace::ROOT}:"
        private_constant :OWN_PREFIX

        def initialize(client)
          @client = client
        end

        def scan(cursor, match:, count: 100)
          cursor, keys = @client.scan(cursor, match: match, count: count)
          [cursor, keys.reject { |k| k.start_with?(OWN_PREFIX) }]
        end
      end
      private_constant :ExcludeOwnKeysScanner

      def upstream_client
        @upstream_client ||= begin
          require "redis"
          ::Redis.new(url: @parse_cache_url)
        end
      end

      # Write a random key to OUR database and ask the upstream connection to
      # read it back. This is the only direction that can establish isolation:
      # a key that just appeared on our database and is not visible through
      # the other connection proves the two are not the same database.
      #
      # The value is random too, so a stale key from a previous run cannot be
      # mistaken for this run's sentinel.
      #
      # An earlier version of this check did the round-trip and treated a nil
      # read as isolated, full stop. That is wrong under the restricted
      # credential this SDK documents (`~<appId>:role:* ... +get +pttl`),
      # where reading anything else raises NOPERM. redis-rb surfaces that as
      # a `CommandError`, which is distinguishable from a nil, so the two are
      # kept apart here instead of both meaning "isolated".
      #
      # @return [:shared, :isolated, :unknown]
      def sentinel_probe
        token = SecureRandom.hex(16)
        key = "#{Keyspace::ROOT}:probe:#{token}"
        begin
          # Raw client, not Moneta: the upstream read is a plain GET and must
          # see the same bytes we wrote, unmediated by a key/value serializer.
          @pool.pool.with { |store| backend_client(store).set(key, token, ex: SENTINEL_TTL) }
        rescue StandardError
          # Cannot write, so cannot establish anything.
          return :unknown
        end

        begin
          seen = upstream_client.get(key)
          return :shared if seen == token
          # A non-nil value that is not our token means something else owns
          # this key, which should be impossible. Do not call that isolated.
          return :unknown unless seen.nil?
          :isolated
        rescue StandardError
          # NOPERM, a transport failure, a Cluster CROSSSLOT: all say nothing
          # about which database the key lives on.
          :unknown
        ensure
          begin
            @pool.pool.with { |store| backend_client(store).del(key) }
          rescue StandardError
            # The TTL collects it.
          end
        end
      end

      # Seconds the probe key lives if the explicit delete does not land.
      SENTINEL_TTL = 10
      private_constant :SENTINEL_TTL

      # Serialize a cache value to a JSON String before handing it to Moneta
      # (which stores it raw, since the value serializer is disabled — see the
      # constructor). JSON is used instead of Marshal so the read side never
      # `Marshal.load`s attacker-influenced Redis bytes. Cache values written
      # by the caching middleware are `{ "headers" => ..., "body" => ... }`
      # hashes of strings, which round-trip losslessly through JSON.
      def encode_value(value)
        JSON.generate(value)
      end

      # Decode a JSON String read back from Moneta/Redis. Returns nil on a
      # miss or on any value that is not valid JSON — most importantly, legacy
      # Marshal-encoded entries written before this wrapper switched to JSON.
      # Treating an undecodable value as a miss makes the caller refetch and
      # re-store it in the JSON format, and ensures a hostile non-JSON blob can
      # at worst yield a cache miss, never a deserialized Ruby object graph.
      def decode_value(raw)
        return nil if raw.nil?
        JSON.parse(raw)
      rescue JSON::ParserError, EncodingError, TypeError
        # ParserError covers malformed and hostile-depth JSON
        # (JSON::NestingError subclasses it); TypeError covers a
        # non-String blob from a misconfigured store. All are misses.
        nil
      end

      def delete_keys_matching!(pattern)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        deleted = 0
        @pool.pool.with do |store|
          redis = backend_client(store)
          # SCAN-UNLINK loop. `count:` is a hint to the server; the actual
          # batch size returned varies. Loop until the cursor wraps back
          # to "0".
          #
          # UNLINK reclaims memory on a background thread, so a large scoped
          # eviction does not stall the server the way DEL would. It has been
          # available since Redis 4.0; fall back to DEL on anything older or on
          # a client that does not expose it.
          unlink = redis.respond_to?(:unlink)
          cursor = "0"
          loop do
            cursor, keys = redis.scan(cursor, match: pattern, count: 1000)
            unless keys.empty?
              unlink ? redis.unlink(*keys) : redis.del(*keys)
              deleted += keys.size
            end
            break if cursor == "0"
          end
        end
        instrument_eviction(pattern, deleted, started)
        deleted
      end

      # Emit a structured event for a scoped eviction so operators can see how
      # much a clear actually removed and how long it took. The pattern is a
      # key prefix, so it is digested rather than logged: a response-cache
      # pattern embeds a URL digest and a tenant, and the identity family's
      # keys are derived from session tokens.
      def instrument_eviction(pattern, deleted, started)
        return unless defined?(ActiveSupport::Notifications)
        ActiveSupport::Notifications.instrument(
          "parse.cache.evict",
          pattern_digest: Digest::SHA256.hexdigest(pattern.to_s)[0, 16],
          deleted: deleted,
          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2),
        )
      rescue StandardError
        # Instrumentation must never turn a successful eviction into a failure.
        nil
      end

      def backend_client(moneta_store)
        # Walk down the Moneta proxy chain (Expires → Adapter → redis-rb)
        # until we reach an object that quacks like the redis-rb client
        # (i.e. responds to #scan). Moneta wraps the actual adapter when
        # `expires: true` is passed, and the adapter then exposes the
        # underlying redis-rb client via `#backend` (modern releases) or
        # the `@backend` ivar (older releases).
        node = moneta_store
        12.times do
          return node if node.respond_to?(:scan)
          if node.respond_to?(:backend)
            node = node.backend
          elsif node.instance_variable_defined?(:@backend)
            node = node.instance_variable_get(:@backend)
          elsif node.instance_variable_defined?(:@adapter)
            node = node.instance_variable_get(:@adapter)
          else
            break
          end
          break if node.nil?
        end
        node
      end

      def normalize_namespace(ns)
        s = ns.to_s.chomp(":")
        s.empty? ? nil : s
      end

      # Validate a caller-supplied `scope:` for `clear(scope:)`. Returns the
      # normalized prefix or raises ArgumentError. We enforce:
      #
      # - must be a String (Symbol / Integer / nil would silently `.to_s`
      #   under `normalize_namespace` and expand the deletion target —
      #   `scope: 0` would clear `0:*`)
      # - must be non-empty after trimming a trailing `:`
      # - must not contain Redis SCAN glob metacharacters (`*`, `?`, `[`,
      #   `]`, `\`) — otherwise `scope: "*"` would SCAN-delete the whole
      #   DB, defeating the whole point of having `flush_db!` as the
      #   explicit wide-blast-radius escape hatch
      # - must not contain a null byte (defense-in-depth against keys
      #   crafted to terminate early in some Redis client paths)
      GLOB_METACHARS = /[\*\?\[\]\\\x00]/.freeze
      private_constant :GLOB_METACHARS

      def validate_scope!(scope)
        unless scope.is_a?(String)
          raise ArgumentError, "scope: must be a String (got #{scope.class})"
        end
        prefix = scope.chomp(":")
        if prefix.empty?
          raise ArgumentError, "scope: must be a non-empty namespace string"
        end
        if prefix.match?(GLOB_METACHARS)
          raise ArgumentError,
                "scope: must not contain Redis SCAN glob characters (*, ?, [, ], \\, or NUL); " \
                "use flush_db! for a full-DB flush"
        end
        prefix
      end
    end
  end
end
