# encoding: UTF-8
# frozen_string_literal: true

require "set"
require_relative "../clp_scope"

module Parse
  module AtlasSearch
    # Resolves session tokens to user identities and inherited role
    # sets for ACL-scoped Atlas Search queries.
    #
    # Atlas Search runs aggregations directly against MongoDB and
    # therefore bypasses Parse Server's per-request ACL enforcement.
    # To compile a `_rperm` `$match` stage (see {Parse::ACL.read_predicate})
    # the caller needs to know two things about the requesting
    # session:
    #
    #   1. The `_User.objectId` that owns the session.
    #   2. The transitive upward closure of role names that user
    #      inherits permissions from (cf. {Parse::Role.all_for_user}).
    #
    # Both lookups can be expensive — token → user requires a
    # `/users/me` round-trip, and user → roles can require multiple
    # `_Role` queries to walk the inheritance graph. Both are cached
    # separately so a single agent turn that runs several Atlas Search
    # tools amortizes the cost.
    #
    # Two distinct caches:
    #
    #   * `session_cache`: maps `session_token` to `user_id`. Long
    #     TTL (1 hour default), invalidation profile is logout. Apps
    #     that need sub-TTL revocation must call {.invalidate}
    #     explicitly from their logout path.
    #
    #   * `role_cache`: maps `user_id` to a `Set` of role names. Short
    #     TTL (2 minutes default), invalidation profile is role-graph
    #     mutation. Stale role data here yields incorrect ACL
    #     decisions, so the default is conservatively short.
    #
    # The default cache implementation is process-local
    # ({MemoryCache}) and guarded by a `Mutex`. Apps that need shared
    # cross-process caching (Redis, Memcached) may install a
    # replacement via {AtlasSearch.session_cache=} /
    # {AtlasSearch.role_cache=}; the replacement must respond to
    # `get(key)`, `set(key, value, ttl:)`, and `invalidate(key)`.
    module Session
      # Raised when a `session_token` cannot be resolved — invalid
      # token, expired session, or `/users/me` returned an error.
      # Atlas Search callers should treat this as a 401-equivalent.
      class InvalidSession < StandardError; end

      # Default cache: in-memory hash with per-entry TTL, guarded by a
      # `Mutex`. Suitable for single-process apps. Apps running
      # multi-process (Puma workers, Sidekiq processes) get a per-
      # process cache — install a shared cache through
      # {AtlasSearch.session_cache=} for cross-process sharing.
      class MemoryCache
        def initialize
          @data = {}
          @mutex = Mutex.new
        end

        # @param key [String]
        # @return [Object, nil] the cached value, or `nil` when the key
        #   is missing or its TTL has elapsed. Expired entries are
        #   evicted lazily on read.
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

        # Drop every entry. Used by {Session.reset_caches!} and by
        # tests that need a clean slate.
        def clear
          @mutex.synchronize { @data.clear }
        end
      end

      # Value returned by {Session.resolve}. `user_id` is the
      # `_User.objectId` owning the session, or `nil` for an anonymous
      # caller. `role_names` is a `Set` of role names (no `role:`
      # prefix) the user inherits permissions from, computed via
      # {Parse::Role.all_for_user}.
      Resolved = Struct.new(:user_id, :role_names) do
        # Build the canonical `_rperm`/`_wperm` permission-string set
        # for this session. Always includes `"*"` (public). Includes
        # `user_id` when present. Includes `"role:#{name}"` for each
        # inherited role.
        # @return [Array<String>]
        def permission_strings
          out = ["*"]
          out << user_id if user_id && !user_id.empty?
          role_names.each { |name| out << "role:#{name}" if name && !name.empty? }
          out.uniq
        end

        # @return [Boolean] `true` for the anonymous-session case.
        def anonymous?
          user_id.nil? || user_id.empty?
        end
      end

      class << self
        # Resolve a `session_token` to the requesting user and the
        # transitive set of role names whose `role:NAME` permission
        # strings should be checked against `_rperm`.
        #
        # `nil` or empty `session_token` → anonymous {Resolved} with
        # `user_id: nil` and an empty `role_names` set. The caller
        # decides whether to refuse the request (the
        # `require_session_token` toggle on {Parse::AtlasSearch}) or
        # treat as public-only.
        #
        # Cache layering: token-to-user_id is checked first; on hit
        # the slower `/users/me` round-trip is skipped. User-to-roles
        # is then checked independently (a single user shared across
        # sessions amortizes the role lookup).
        #
        # @param session_token [String, nil] the `X-Parse-Session-Token`
        #   value from the requesting session.
        # @return [Resolved]
        # @raise [InvalidSession] when the token cannot be resolved by
        #   `/users/me` (404 / 209 invalid session token / 401).
        def resolve(session_token)
          return Resolved.new(nil, Set.new) if session_token.nil? || session_token.to_s.empty?

          user_id = lookup_user_id(session_token.to_s)
          role_names = lookup_role_names(user_id)
          Resolved.new(user_id, role_names)
        end

        # Forget a `session_token` entry from the session-token cache.
        # Apps that revoke sessions out-of-band (logout, password
        # reset, admin revoke) should call this from the same path so
        # subsequent Atlas Search requests don't act on the stale
        # `user_id` mapping. The `role_names` cache is keyed on
        # `user_id` and is not affected — call {.invalidate_user_roles}
        # to clear that separately.
        # @param session_token [String]
        def invalidate(session_token)
          return if session_token.nil?
          Parse::AtlasSearch.session_cache.invalidate(session_token.to_s)
        end

        # Forget cached role membership for a `user_id`. Call after any
        # `_Role.users` mutation that affects this user (role grant /
        # revoke, role-graph reshape).
        # @param user_id [String]
        def invalidate_user_roles(user_id)
          return if user_id.nil?
          Parse::AtlasSearch.role_cache.invalidate(user_id.to_s)
        end

        # Drop every cached entry across both caches. Useful in tests
        # and in startup hooks for processes that fork after warming
        # the cache.
        def reset_caches!
          Parse::AtlasSearch.session_cache.clear if Parse::AtlasSearch.session_cache.respond_to?(:clear)
          Parse::AtlasSearch.role_cache.clear if Parse::AtlasSearch.role_cache.respond_to?(:clear)
        end

        private

        # @!visibility private
        # Resolve session_token → user_id via cache, falling through
        # to `/users/me`. Raises {InvalidSession} on lookup failure;
        # the caller is responsible for refusing the request.
        def lookup_user_id(session_token)
          cache = Parse::AtlasSearch.session_cache
          cached = cache.get(session_token)
          return cached if cached

          response = begin
              Parse.client.current_user(session_token)
            rescue => e
              raise InvalidSession, "session token lookup failed: #{e.class}: #{e.message}"
            end
          raise InvalidSession, "session token invalid or expired" if response.nil? || response.error?

          result = response.result
          user_id = result.is_a?(Hash) ? (result["objectId"] || result[:objectId]) : nil
          raise InvalidSession, "session token resolved no user objectId" if user_id.nil? || user_id.to_s.empty?

          user_id = user_id.to_s
          cache.set(session_token, user_id, ttl: Parse::AtlasSearch.session_cache_ttl)
          user_id
        end

        # @!visibility private
        # Resolve user_id → Set<role_name> via cache, falling through
        # to {Parse::Role.all_for_user}. Failures degrade silently to
        # an empty set rather than raising — a Parse Server hiccup
        # during the role walk must not turn every search call into a
        # 500, and the worst case is a query that misses some
        # role-restricted documents.
        #
        # ATLAS-7: explicitly re-raise the exceptions that signal
        # attacks or policy denials BEFORE the generic rescue. Without
        # this, a denied-operator probe (DeniedOperator), a timeout
        # exhaustion (ExecutionTimeout), or a CLP denial during role
        # graph traversal would silently downgrade to an empty role
        # set — the caller would then run with public-only perms,
        # missing role-restricted rows but also masking the attack
        # signal from the operator. These exception classes are SDK
        # contracts the caller must surface upward.
        def lookup_role_names(user_id)
          return Set.new if user_id.nil? || user_id.empty?

          cache = Parse::AtlasSearch.role_cache
          cached = cache.get(user_id)
          return cached if cached.is_a?(Set)

          pointer = Parse::Pointer.new(Parse::Model::CLASS_USER, user_id)
          names = begin
              Parse::Role.all_for_user(pointer, max_depth: 10)
            rescue Parse::MongoDB::DeniedOperator,
                   Parse::MongoDB::ExecutionTimeout,
                   Parse::CLPScope::Denied
              # Re-raise: these are attack signals or explicit policy
              # denials and must NOT be swallowed into a fail-open
              # public-only ACL state.
              raise
            rescue
              Set.new
            end
          cache.set(user_id, names, ttl: Parse::AtlasSearch.role_cache_ttl)
          names
        end
      end
    end
  end
end
