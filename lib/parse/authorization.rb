# encoding: UTF-8
# frozen_string_literal: true

require "set"
require "digest"

module Parse
  # Resolution of a caller's identity and inherited roles, and the caches that
  # make that resolution cheap.
  #
  # **Why this is not part of Atlas Search.** It used to be. Session-token
  # resolution and role-closure expansion were written for
  # `Parse::AtlasSearch`, because `$search` was the first thing that ran
  # aggregations straight against MongoDB and therefore the first thing that
  # had to enforce ACLs itself. Everything since has reached back through it:
  # `Parse::ACLScope` called `Parse::AtlasSearch::Session.resolve`, and
  # `Parse::MongoDB.aggregate` calls `Parse::ACLScope`, so
  # `Parse::Query#results_direct` on a plain query with no `$search` anywhere
  # in it depended on the Atlas Search namespace to decide who the caller was.
  # That is backwards. Deciding who someone is and what they may read is
  # authorization infrastructure, and Atlas Search is one consumer of it:
  #
  #     Atlas Search ─┐
  #     Aggregates  ──┼─> Parse::Authorization ─> identity / role caches
  #     Direct query ─┘
  #
  # Policy that is genuinely about Atlas Search stays on Atlas Search:
  # `Parse::AtlasSearch.require_session_token` decides whether `$search` may
  # run anonymously, which is a question about that feature, not about
  # identity.
  #
  # **Two caches, because they invalidate on different events.**
  #
  #   * The **identity plane** maps a session token to a user id. Long TTL
  #     (1 hour), invalidated by logout and by a `_User` write. Named
  #     `identity_cache` rather than `session_cache` because it stores neither
  #     `_Session` rows nor session objects: it stores one string per token.
  #     The old name led readers to reason about `_Session` semantics that
  #     were never involved.
  #
  #   * The **role plane** maps a user id to a `Set` of role names. Short TTL
  #     (30 seconds), invalidated by any `_Role` write. Stale entries here
  #     produce wrong ACL decisions rather than merely slow ones, so the
  #     default is conservative.
  #
  # **State belongs to a client, not to the process.** A {Context} is owned by
  # one {Parse::Client} and reachable as `client.authorization`. Two named
  # clients pointed at two Parse applications must never resolve a token
  # against each other's caches or each other's `/users/me`, which is exactly
  # what a set of module-level globals allowed. {Parse::Authorization.configure}
  # exists as a boundary convenience and configures the DEFAULT client's
  # context; below the boundary, `client:` is required and has no default.
  module Authorization
    # Raised when a `session_token` cannot be resolved: an invalid token, an
    # expired session, or a `/users/me` that returned an error. Callers should
    # treat it as a 401-equivalent.
    class InvalidSession < StandardError; end

    # Default cache: a process-local hash with per-entry TTL, guarded by a
    # `Mutex`. Fine for a single process. Multi-process deployments (Puma
    # workers, Sidekiq processes) get one of these per process and should
    # install a shared plane instead, which is what
    # `Parse::Cache::Redis#scoped(...).identity` / `.roles` return.
    class MemoryCache
      def initialize
        @data = {}
        @mutex = Mutex.new
      end

      # @param key [String]
      # @return [Object, nil] the cached value, or `nil` when the key is
      #   missing or its TTL has elapsed. Expired entries are evicted lazily
      #   on read.
      def get(key)
        @mutex.synchronize do
          entry = @data[key]
          return nil if entry.nil?
          if entry[:expires_at] < Time.now
            @data.delete(key)
            return nil
          end
          entry[:value]
        end
      end

      # @param key [String]
      # @param value [Object]
      # @param ttl [Numeric] seconds until the entry expires.
      def set(key, value, ttl:)
        @mutex.synchronize do
          @data[key] = { value: value, expires_at: Time.now + ttl }
        end
      end

      # @param key [String] cache key to forget.
      def invalidate(key)
        @mutex.synchronize { @data.delete(key) }
      end

      # Drop every entry whose value equals `value`. Lets the identity plane
      # forget every token of one user after a revocation, since it is keyed
      # by token and holds the user id as the value.
      # @param value [Object]
      # @return [Integer] number of entries removed.
      def invalidate_value(value)
        @mutex.synchronize do
          before = @data.size
          @data.delete_if { |_key, entry| entry[:value] == value }
          before - @data.size
        end
      end

      # Drop every entry.
      def clear
        @mutex.synchronize { @data.clear }
      end
    end

    # Process-local record of session objectId to owning user id, kept apart
    # from the identity plane so no session token can ever read a record.
    # Entries expire after `ttl` and the map holds at most {MAX_ENTRIES},
    # dropping the oldest first. Values are stored typed
    # (`{"session_owner" => user_id}`) so a shared store passed in its place
    # cannot confuse a record with an identity entry either.
    class SessionOwnerMap
      MAX_ENTRIES = 10_000

      def initialize
        @data = {}
        @mutex = Mutex.new
      end

      def get(key)
        @mutex.synchronize do
          entry = @data[key]
          return nil if entry.nil?
          if entry[:expires_at] < Time.now
            @data.delete(key)
            return nil
          end
          entry[:value]
        end
      end

      def set(key, value, ttl:)
        @mutex.synchronize do
          @data.delete(key)
          @data[key] = { value: value, expires_at: Time.now + ttl }
          @data.shift while @data.size > MAX_ENTRIES
        end
      end

      def invalidate(key)
        @mutex.synchronize { @data.delete(key) }
      end

      def clear
        @mutex.synchronize { @data.clear }
      end
    end

    # The outcome of resolving a caller. `user_id` is the `_User.objectId`
    # owning the session, or `nil` for an anonymous caller. `role_names` is a
    # `Set` of bare role names (no `role:` prefix) the user inherits
    # permissions from.
    Resolved = Struct.new(:user_id, :role_names) do
      # The canonical `_rperm` / `_wperm` permission-string set for this
      # caller. Always includes `"*"`. Includes `user_id` when present, and
      # `"role:#{name}"` for each inherited role.
      # @return [Array<String>]
      def permission_strings
        out = ["*"]
        out << user_id if user_id && !user_id.empty?
        role_names.each { |name| out << "role:#{name}" if name && !name.empty? }
        out.uniq
      end

      # @return [Boolean] `true` for the anonymous case.
      def anonymous?
        user_id.nil? || user_id.empty?
      end
    end

    # Per-client authorization state: the two caches, their TTLs, and the
    # optional upstream-role reader.
    #
    # One of these is owned by each {Parse::Client}. It deliberately does NOT
    # own the HTTP client: it holds a back-reference and asks the client to
    # make the `/users/me` call, so there is exactly one place that knows how
    # to talk to a Parse application and it is the client itself.
    class Context
      # @return [Object] the identity plane. Maps session token to user id.
      attr_accessor :identity_cache

      # @return [Object] the role plane. Maps user id to a Set of role names.
      attr_accessor :role_cache

      # @return [Integer] identity-entry TTL in seconds.
      attr_accessor :identity_cache_ttl

      # @return [Integer] role-entry TTL in seconds.
      attr_accessor :role_cache_ttl

      # @return [#roles_for, nil] read-only reader for Parse Server's own role
      #   cache. Never consumed for authorization; see {#compare_upstream_roles}.
      attr_accessor :upstream_role_reader

      # @return [Boolean] when true, and a reader is set, every role
      #   resolution also reads the upstream closure and emits a
      #   `parse.cache.role_compare` event. The comparison NEVER changes what
      #   {#resolve} returns. The upstream value would become an authorization
      #   input the moment it were consumed, and it comes from a database this
      #   SDK does not own, so it stays observable-only until the two closures
      #   have been reconciled against real traffic.
      attr_accessor :compare_upstream_roles

      # @return [Parse::Client] the client this context authorizes for.
      attr_reader :client

      DEFAULT_IDENTITY_TTL = 3600
      DEFAULT_ROLE_TTL = 30

      # Depth cap for the role-graph walk. Bounds a cyclic or pathological
      # hierarchy; see {Parse::Role.all_for_user}.
      ROLE_GRAPH_MAX_DEPTH = 10

      def initialize(client:)
        @client = client
        @identity_cache = MemoryCache.new
        @role_cache = MemoryCache.new
        @identity_cache_ttl = DEFAULT_IDENTITY_TTL
        @role_cache_ttl = DEFAULT_ROLE_TTL
        @upstream_role_reader = nil
        @compare_upstream_roles = false
        # Bumped by every invalidation. A token resolution captures it before
        # calling `/users/me` and does not cache its answer when it moved, so
        # a resolve already in flight when a session is revoked cannot put
        # the revoked token back into the plane. A generation-capable plane
        # (the shared Redis identity plane) keeps a plane-wide counter too,
        # so the same holds across processes. See {#lookup_user_id}.
        @invalidation_epoch = 0
        @epoch_mutex = Mutex.new
        @session_owner_cache = SessionOwnerMap.new
      end

      # Where {#remember_session_owner} records which user owns a session
      # objectId. A separate store from the identity plane, so a session
      # token can never read a record. Defaults to a process-local
      # {SessionOwnerMap}; set a shared store (anything with `get`, `set`
      # with `ttl:`, `invalidate`, and `clear`) to share records across
      # processes.
      # @return [Object]
      attr_accessor :session_owner_cache

      # Apply settings, leaving anything not passed unchanged.
      # @return [self]
      def configure(identity_cache: nil, role_cache: nil,
                    identity_cache_ttl: nil, role_cache_ttl: nil,
                    upstream_role_reader: nil, compare_upstream_roles: nil)
        @identity_cache = identity_cache unless identity_cache.nil?
        @role_cache = role_cache unless role_cache.nil?
        @identity_cache_ttl = identity_cache_ttl unless identity_cache_ttl.nil?
        @role_cache_ttl = role_cache_ttl unless role_cache_ttl.nil?
        @upstream_role_reader = upstream_role_reader unless upstream_role_reader.nil?
        @compare_upstream_roles = compare_upstream_roles unless compare_upstream_roles.nil?
        self
      end

      # Resolve a session token to the requesting user and the transitive set
      # of role names whose `role:NAME` permission strings should be checked
      # against `_rperm`.
      #
      # A `nil` or empty token yields an anonymous {Resolved}. The caller
      # decides whether that is acceptable; `Parse::ACLScope.require_session_token`
      # and `Parse::AtlasSearch.require_session_token` are where that policy
      # lives.
      #
      # The two lookups are cached independently, so several sessions
      # belonging to one user share a single role-graph walk.
      #
      # @param session_token [String, nil]
      # @return [Resolved]
      # @raise [InvalidSession] when `/users/me` cannot resolve the token.
      def resolve(session_token)
        return Resolved.new(nil, Set.new) if session_token.nil? || session_token.to_s.empty?

        user_id = lookup_user_id(session_token.to_s)
        Resolved.new(user_id, lookup_role_names(user_id))
      end

      # Resolve a user id that is already trusted, skipping `/users/me`.
      # Used by the `acl_user:` path, which has a User pointer rather than a
      # token.
      # @param user_id [String]
      # @return [Resolved]
      def resolve_user(user_id)
        return Resolved.new(nil, Set.new) if user_id.nil? || user_id.to_s.empty?
        Resolved.new(user_id.to_s, lookup_role_names(user_id.to_s))
      end

      # Forget one session token. Call from a logout path that revokes
      # out-of-band; `Parse::Cache::Invalidation` does this automatically from
      # the `_Session` `after_logout` trigger when webhooks are installed.
      #
      # The role plane is keyed by user id and is unaffected; use
      # {#invalidate_user_roles} for that.
      # @param session_token [String]
      def invalidate(session_token)
        return if session_token.nil?
        bump_invalidation_epoch!
        @identity_cache.invalidate(session_token.to_s)
      end

      # Forget every cached identity entry that resolves to `user_id`. Call
      # after an event that revokes the user's sessions: a password change,
      # account deletion, a session destroy, or "log out everywhere". The SDK
      # calls it itself on those paths.
      #
      # The identity plane is keyed by token, so there is no direct way to
      # name a user's entries. A generation-capable plane (the keyspaced
      # Redis identity plane) bumps the user's generation, which rejects
      # every entry for that user, including tokens this process never
      # resolved. The default {MemoryCache} drops the matching values. A
      # custom plane that supports neither is left to its TTL.
      #
      # The role entry is dropped too: it is cheap to rebuild and a deleted
      # user should not keep a role closure around.
      # @param user_id [String]
      # @return [void]
      def invalidate_user(user_id)
        return if user_id.nil? || user_id.to_s.empty?
        uid = user_id.to_s
        bump_invalidation_epoch!
        cache = @identity_cache
        if generation_capable?(cache) && cache.respond_to?(:bump_generation)
          cache.bump_generation(uid)
        elsif cache.respond_to?(:invalidate_value)
          cache.invalidate_value(uid)
        end
        @role_cache.invalidate(uid)
        nil
      end

      # Forget one user's cached role closure. Call after any `_Role.users`
      # mutation affecting them.
      # @param user_id [String]
      def invalidate_user_roles(user_id)
        return if user_id.nil?
        @role_cache.invalidate(user_id.to_s)
      end

      # Forget every cached role closure. Call after a `_Role.roles` hierarchy
      # change, which can affect any user holding a role in that hierarchy.
      def invalidate_all_roles
        @role_cache.clear if @role_cache.respond_to?(:clear)
      end

      # Drop every entry in both planes.
      def reset_caches!
        bump_invalidation_epoch!
        @identity_cache.clear if @identity_cache.respond_to?(:clear)
        @role_cache.clear if @role_cache.respond_to?(:clear)
        # A plane clear takes the plane-wide marker with it. Bump it again so
        # it does not sit at a value a lookup that started before the reset
        # could have captured.
        bump_plane_epoch!
      end

      # Record which user owns a session objectId, so a later delete of that
      # session can drop the owner's cached identities even when the delete
      # can no longer read the session row (it is already gone, or not
      # visible to the caller). Only the owner's user id is stored, never the
      # token. Called when a `_Session` row with both is loaded from the
      # server. The entry lives as long as an identity entry.
      # @param session_id [String]
      # @param user_id [String]
      # @return [void]
      def remember_session_owner(session_id, user_id)
        return if session_id.to_s.empty? || user_id.to_s.empty?
        @session_owner_cache.set(session_id.to_s, { "session_owner" => user_id.to_s }, ttl: @identity_cache_ttl)
        nil
      rescue StandardError
        nil
      end

      # The owner recorded by {#remember_session_owner}, or nil.
      # @param session_id [String]
      # @return [String, nil]
      def session_owner(session_id)
        return nil if session_id.to_s.empty?
        value = @session_owner_cache.get(session_id.to_s)
        owner = value.is_a?(Hash) ? value["session_owner"] : nil
        owner.is_a?(String) && !owner.empty? ? owner : nil
      rescue StandardError
        nil
      end

      def inspect
        "#<Parse::Authorization::Context client=#{@client.respond_to?(:application_id) ? @client.application_id : @client.class}>"
      end

      private

      # Resolve token to user id through the identity plane, falling through
      # to `/users/me` on this context's OWN client. Threading the client here
      # is the substance of the refactor: a global resolver would have asked
      # `Parse.client`, so a token minted by a secondary application would be
      # validated against the default application and either fail or, worse,
      # match a different user with the same token shape.
      def lookup_user_id(session_token)
        cached = cached_user_id(session_token)
        return cached unless cached.nil?

        # Captured before `/users/me`: an invalidation that lands while the
        # lookup is in flight must win over the answer it returns. The plane
        # marker is created first if a clear removed it, so the snapshot
        # never holds "no marker", which a concurrent reset also produces.
        ensure_plane_marker!
        snapshot = invalidation_snapshot
        prior_uid, prior_gen = prior_generation(session_token)

        response = begin
            # cache: false: a revoked or expired token must not re-resolve
            # from a cached /users/me response after its identity entry is
            # evicted or invalidated. The identity plane above is the only
            # cache on this path, so its TTL and invalidation hooks bound
            # revocation.
            @client.current_user(session_token, cache: false)
          rescue => e
            raise InvalidSession, "session token lookup failed: #{e.class}: #{e.message}"
          end
        raise InvalidSession, "session token invalid or expired" if response.nil? || response.error?

        result = response.result
        user_id = result.is_a?(Hash) ? (result["objectId"] || result[:objectId]) : nil
        raise InvalidSession, "session token resolved no user objectId" if user_id.nil? || user_id.to_s.empty?

        user_id = user_id.to_s
        # A stale entry for the same user tells us its generation from
        # before the lookup; storing under it lets a bump made across
        # processes during the lookup still reject the entry.
        store_unless_invalidated(session_token, user_id, snapshot,
                                 gen: prior_uid == user_id ? prior_gen : nil)
        user_id
      end

      # Cache a resolved identity only if no invalidation happened since
      # `snapshot` was taken, without a window between the check and the
      # write.
      #
      # Every invalidation bumps the counters BEFORE it drops entries. The
      # write is checked before and re-checked after; a change seen by the
      # second check evicts what was just written. So an invalidation either
      # bumped before the re-check (the entry is evicted here) or bumped
      # after it, which means it also drops entries after the write (the
      # entry is removed, or its generation goes stale, by the invalidation
      # itself). Either way the revoked identity does not stay cached. The
      # plane-wide counter extends this to invalidations made by other
      # processes sharing a generation-capable plane.
      def store_unless_invalidated(session_token, user_id, snapshot, gen: nil)
        return unless snapshot_usable?(snapshot)
        return unless invalidation_snapshot == snapshot
        store_user_id(session_token, user_id, gen: gen)
        return if invalidation_snapshot == snapshot
        @identity_cache.invalidate(session_token)
      rescue StandardError
        # Not caching is always safe: the next read resolves again.
        begin
          @identity_cache.invalidate(session_token)
        rescue StandardError
          nil
        end
      end

      # The process counter plus, on a generation-capable plane, the
      # plane-wide counter shared by every process using that plane.
      def invalidation_snapshot
        [current_invalidation_epoch, plane_epoch]
      end

      # A snapshot whose plane counter could not be read cannot prove that no
      # other process invalidated during the lookup, so it never caches.
      #
      # An absent marker on a plane that keeps one is not usable either: a
      # reset in another process deletes the marker before it installs a new
      # one, so "absent" before and after the write cannot prove that no reset
      # ran in between. The re-check after the write compares against a
      # present marker, so reading it absent there evicts the write.
      def snapshot_usable?(snapshot)
        snapshot[1] != :unavailable && snapshot[1] != :absent
      end

      # Create the plane-wide marker when the plane keeps one and it is
      # missing (a fresh plane, or one a reset has just cleared).
      def ensure_plane_marker!
        cache = @identity_cache
        if cache.respond_to?(:invalidation_nonce)
          cache.bump_invalidation_nonce if cache.invalidation_nonce.nil?
        elsif generation_capable?(cache) && cache.respond_to?(:bump_generation)
          gen = cache.generation(PLANE_EPOCH_SUBJECT)
          cache.bump_generation(PLANE_EPOCH_SUBJECT) if gen.nil? || gen.to_i.zero?
        end
      rescue StandardError
        nil
      end

      def bump_invalidation_epoch!
        @epoch_mutex.synchronize { @invalidation_epoch += 1 }
        bump_plane_epoch!
      end

      def current_invalidation_epoch
        @epoch_mutex.synchronize { @invalidation_epoch }
      end

      # Reserved generation subject for the plane-wide invalidation counter
      # on a custom generation-capable plane without an invalidation nonce.
      # Parse objectIds are alphanumeric, so it cannot name a real user.
      PLANE_EPOCH_SUBJECT = "~identity-invalidations"

      # The plane-wide invalidation marker: a random nonce replaced on every
      # invalidation when the plane offers one ({Parse::Cache::SubCache}
      # does), else a generation counter. nil when the plane has neither,
      # `:absent` when the plane keeps one but it is missing (fresh or just
      # cleared), `:unavailable` when reading it failed. A nonce never repeats, so a
      # plane clear that drops it cannot make an old value come back.
      def plane_epoch
        cache = @identity_cache
        if cache.respond_to?(:invalidation_nonce)
          nonce = cache.invalidation_nonce
          return nonce.nil? ? :absent : nonce
        end
        return nil unless generation_capable?(cache)
        gen = cache.generation(PLANE_EPOCH_SUBJECT)
        gen.nil? || gen.to_i.zero? ? :absent : gen
      rescue StandardError
        :unavailable
      end

      def bump_plane_epoch!
        cache = @identity_cache
        if cache.respond_to?(:bump_invalidation_nonce)
          cache.bump_invalidation_nonce
        elsif generation_capable?(cache) && cache.respond_to?(:bump_generation)
          cache.bump_generation(PLANE_EPOCH_SUBJECT)
        end
      rescue StandardError
        nil
      end

      # The user id and that user's current generation from a stale entry
      # already stored for the token, read before `/users/me`.
      # @return [Array(String, Object), Array(nil, nil)]
      def prior_generation(session_token)
        cache = @identity_cache
        return [nil, nil] unless generation_capable?(cache)
        raw = cache.get(session_token)
        uid = raw.is_a?(Hash) ? (raw["user_id"] || raw[:user_id]) : nil
        return [nil, nil] if uid.nil?
        [uid.to_s, cache.generation(uid.to_s)]
      rescue StandardError
        [nil, nil]
      end

      # Read the identity plane and, where the plane supports it, check that
      # the entry's generation is still current.
      #
      # A `_User` write bumps that generation (see
      # {Parse::Cache::Invalidation}), so a modified or revoked user's cached
      # entries are rejected on the very next read instead of staying
      # resolvable for the rest of {#identity_cache_ttl}. The default
      # {MemoryCache} has no generation contract, so this feature-detects and
      # falls back to trusting the bare value, adding no round trip.
      #
      # @return [String, nil] `nil` on any miss: absent, stale generation, or
      #   a shape this reader does not recognize. An unrecognized shape
      #   includes a bare `String` written by a generation-capable plane
      #   before generations existed; treating it as a miss costs one
      #   re-resolution rather than trusting it unchecked.
      def cached_user_id(session_token)
        cache = @identity_cache
        raw = cache.get(session_token)
        return nil if raw.nil?

        unless generation_capable?(cache)
          return raw.is_a?(String) ? raw : nil
        end

        return nil unless raw.is_a?(Hash)
        user_id = raw["user_id"] || raw[:user_id]
        gen = raw.key?("gen") ? raw["gen"] : raw[:gen]
        return nil if user_id.nil? || gen.nil?
        return nil unless cache.generation_current?(user_id, gen)
        user_id
      end

      # Write the identity entry, tagging it with the subject's current
      # generation when the plane can track one.
      def store_user_id(session_token, user_id, gen: nil)
        cache = @identity_cache
        if generation_capable?(cache)
          gen = cache.generation(user_id) if gen.nil?
          cache.set(session_token, { "user_id" => user_id, "gen" => gen },
                    ttl: @identity_cache_ttl)
        else
          cache.set(session_token, user_id, ttl: @identity_cache_ttl)
        end
      end

      def generation_capable?(cache)
        cache.respond_to?(:generation) && cache.respond_to?(:generation_current?)
      end

      # Resolve user id to a Set of role names through the role plane,
      # falling through to {Parse::Role.all_for_user}.
      #
      # Ordinary failures degrade to an empty set rather than raising: a
      # Parse Server hiccup during the role walk must not turn every query
      # into a 500, and the cost is a query that misses role-restricted rows.
      #
      # The three re-raised classes are deliberate exceptions to that. A
      # denied-operator probe, a timeout exhaustion, and a CLP denial are
      # attack signals or explicit policy denials. Swallowing them would
      # downgrade the caller to public-only permissions AND hide the signal
      # from the operator, which is the worst of both.
      def lookup_role_names(user_id)
        return Set.new if user_id.nil? || user_id.empty?

        cached = @role_cache.get(user_id)
        if cached.is_a?(Set)
          compare_with_upstream(user_id, cached)
          return cached
        end

        pointer = Parse::Pointer.new(Parse::Model::CLASS_USER, user_id)
        names = begin
            # `client:` matters as much here as it does for the token
            # lookup above. Without it the identity resolves against THIS
            # client while its role closure is walked against the default
            # application, so a user of application B would be granted
            # application A's roles by name.
            Parse::Role.all_for_user(pointer, max_depth: ROLE_GRAPH_MAX_DEPTH, client: @client)
          rescue Parse::MongoDB::DeniedOperator,
                 Parse::MongoDB::ExecutionTimeout,
                 Parse::CLPScope::Denied
            raise
          rescue
            Set.new
          end
        @role_cache.set(user_id, names, ttl: @role_cache_ttl)
        compare_with_upstream(user_id, names)
        names
      end

      # Opt-in, compare-only read of Parse Server's own role cache. This never
      # changes what {#lookup_role_names} returns: `computed` is already
      # decided by the time this runs. Its only job is to emit an event so the
      # two closures can be compared out-of-band before anything is switched
      # to consume the upstream value.
      #
      # Inert unless both the switch and a reader are set, so it costs one
      # boolean check when off. Every exception is swallowed: this is
      # instrumentation and must never affect resolution.
      def compare_with_upstream(user_id, computed)
        return unless @compare_upstream_roles
        reader = @upstream_role_reader
        return if reader.nil?

        upstream = begin
            reader.roles_for(user_id)
          rescue StandardError
            nil
          end

        emit_role_compare(user_id, computed, upstream)
        nil
      rescue StandardError
        nil
      end

      # Emit `parse.cache.role_compare`. Follows the redaction discipline of
      # `Parse::Middleware::Caching#instrument_cache` and
      # `Parse::CreateLock#instrument`: no role names and no raw user id in
      # the payload, a truncated digest only.
      def emit_role_compare(user_id, computed, upstream)
        return unless defined?(ActiveSupport::Notifications)

        upstream_nil = upstream.nil?
        only_in_ours = upstream_nil ? computed.size : (computed - upstream).size
        only_in_upstream = upstream_nil ? 0 : (upstream - computed).size

        ActiveSupport::Notifications.instrument("parse.cache.role_compare", {
          user_digest: Digest::SHA256.hexdigest(user_id.to_s)[0, 16],
          upstream_nil: upstream_nil,
          matched: !upstream_nil && only_in_ours.zero? && only_in_upstream.zero?,
          computed_size: computed.size,
          upstream_size: upstream_nil ? nil : upstream.size,
          only_in_ours: only_in_ours,
          only_in_upstream: only_in_upstream,
        })
        nil
      rescue StandardError
        nil
      end
    end

    class << self
      # Configure the DEFAULT client's authorization context.
      #
      # This is a boundary convenience, matching the shape already used for
      # `Parse::AtlasSearch.search(..., client: Parse.client)`: the common
      # single-application case should not have to name the client. It is
      # explicitly NOT the source of truth. The state lives on
      # `client.authorization`, one context per client, which is what stops
      # two named clients resolving tokens against each other's caches. To
      # configure a secondary application, call
      # `other_client.authorization.configure(...)` directly.
      #
      # @return [Parse::Authorization::Context] the default client's context.
      def configure(**kwargs)
        Parse.client.authorization.configure(**kwargs)
      end

      # Resolve a session token against a specific client.
      #
      # `client:` is required and has no default. Below the API boundary
      # there is no such thing as "the" client, and defaulting to
      # `Parse.client` here is precisely the bug this module exists to close:
      # a token belonging to application B would be validated against
      # application A.
      #
      # @param session_token [String, nil]
      # @param client [Parse::Client]
      # @return [Resolved]
      def resolve(session_token, client:)
        raise ArgumentError, "Parse::Authorization.resolve requires client:" if client.nil?
        client.authorization.resolve(session_token)
      end

      # @see Context#resolve_user
      def resolve_user(user_id, client:)
        raise ArgumentError, "Parse::Authorization.resolve_user requires client:" if client.nil?
        client.authorization.resolve_user(user_id)
      end
    end
  end
end
