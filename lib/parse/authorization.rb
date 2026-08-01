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

      # Drop every entry.
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
      end

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
        @identity_cache.invalidate(session_token.to_s)
      end

      # Forget one user's cached role closure. Call after any `_Role.users`
      # mutation affecting them.
      # @param user_id [String]
      def invalidate_user_roles(user_id)
        return if user_id.nil?
        @role_cache.invalidate(user_id.to_s)
      end

      # Drop every entry in both planes.
      def reset_caches!
        @identity_cache.clear if @identity_cache.respond_to?(:clear)
        @role_cache.clear if @role_cache.respond_to?(:clear)
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

        response = begin
            @client.current_user(session_token)
          rescue => e
            raise InvalidSession, "session token lookup failed: #{e.class}: #{e.message}"
          end
        raise InvalidSession, "session token invalid or expired" if response.nil? || response.error?

        result = response.result
        user_id = result.is_a?(Hash) ? (result["objectId"] || result[:objectId]) : nil
        raise InvalidSession, "session token resolved no user objectId" if user_id.nil? || user_id.to_s.empty?

        user_id = user_id.to_s
        store_user_id(session_token, user_id)
        user_id
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
      def store_user_id(session_token, user_id)
        cache = @identity_cache
        if generation_capable?(cache)
          cache.set(session_token, { "user_id" => user_id, "gen" => cache.generation(user_id) },
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
            Parse::Role.all_for_user(pointer, max_depth: ROLE_GRAPH_MAX_DEPTH)
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
