# encoding: UTF-8
# frozen_string_literal: true

require_relative "keyspace"
require_relative "moneta_surface"

module Parse
  module Cache
    # An immutable, per-client view over one shared {Parse::Cache::Redis}
    # backend.
    #
    # {Parse::Cache::Redis} is a connection pool: sharing ONE backend across
    # several {Parse::Client} instances (one Redis, several Parse apps) is a
    # normal and supported deployment. What is not supported is sharing
    # *ownership* of a single keyspace binding, which is what the old
    # `Parse::Cache::Redis#keyspace=` setter allowed: client B calling
    # `keyspace = ks_b` on a backend client A already configured rebinds the
    # one `@keyspace` ivar out from under A. A's caching middleware had
    # already captured A's keyspace object and keeps writing/reading under
    # it, while `clear`, `identity`, `roles`, and the memoized
    # `upstream_roles` on the now-shared backend answer with B's keyspace
    # instead. A stops invalidating its own entries, or worse, a scoped
    # `clear` issued through A now deletes B's keys.
    #
    # A `ScopedView` closes that hole by never mutating the backend at all.
    # `Parse::Cache::Redis#scoped(keyspace)` hands back one of these per
    # caller, each carrying its own keyspace and its own memoized
    # `identity` / `roles` / `upstream_roles` planes, all backed by the same
    # underlying connection pool:
    #
    #   backend  = Parse::Cache::Redis.new(url: redis_url)
    #   view_a   = backend.scoped(keyspace_a)
    #   view_b   = backend.scoped(keyspace_b)
    #
    # `view_a` and `view_b` share `backend`'s pooled Redis connections but
    # can never see or clear each other's keys.
    #
    # **Moneta surface.** Implements `[]`, `key?`, `delete`, `store` (and
    # `create` / `increment` when the backend supports them) by delegating
    # straight to the backend, so a view is a drop-in replacement anywhere a
    # bare `Parse::Cache::Redis` was accepted: most importantly, the Faraday
    # caching middleware.
    #
    # **Locks are NOT scoped.** `lock_acquire` / `lock_release` delegate to
    # the backend unchanged, still using the historical
    # `parse-stack:foc:v1:` prefix from {Parse::CreateLock}. During a
    # rolling deploy two workers must compute the SAME lock key regardless of
    # which client/keyspace they were configured with, or `first_or_create!`
    # silently loses cross-process mutual exclusion for the length of the
    # deploy.
    #
    # **No `flush_db!`.** A whole-database flush is a connection-level
    # operation, not something a scoped view over one client's slice of the
    # keyspace should be able to trigger.
    class ScopedView
      include Parse::Cache::MonetaSurface

      # @return [Parse::Cache::Keyspace] this view's key layout. Fixed at
      #   construction; there is no setter, so a view can never be rebound to
      #   a different keyspace after the fact.
      attr_reader :keyspace

      # @return [Parse::Cache::Redis] the shared backend this view reads and
      #   writes through. Exposed for introspection (e.g. tests asserting two
      #   views share one connection pool). The backend itself has no
      #   keyspace concept at all anymore ({#scoped} is the only way to
      #   associate a keyspace with it), so there is nothing on the backend
      #   left to rebind out from under this or any other view.
      attr_reader :backend

      # @param backend [Parse::Cache::Redis] the shared connection pool.
      # @param keyspace [Parse::Cache::Keyspace] this view's key layout.
      # @raise [ArgumentError] if `keyspace` is not a Parse::Cache::Keyspace.
      def initialize(backend:, keyspace:)
        unless keyspace.is_a?(Parse::Cache::Keyspace)
          raise ArgumentError,
                "Parse::Cache::ScopedView keyspace must be a Parse::Cache::Keyspace; got #{keyspace.class}"
        end
        @backend = backend
        # The keyspace itself has no setters to begin with, but freezing it
        # here is a cheap extra guarantee that nothing downstream (this view
        # included) can mutate the layout this view was constructed with.
        @keyspace = keyspace.freeze

        # `create` and `increment` are only defined when the backend itself
        # supports them, so `respond_to?(:create)` on a view accurately
        # reflects what the backend can actually do rather than always
        # claiming support and raising NoMethodError on first use.
        if @backend.respond_to?(:create)
          define_singleton_method(:create) do |key, value, options = {}|
            @backend.create(key, value, options)
          end
        end
        if @backend.respond_to?(:increment)
          define_singleton_method(:increment) do |key, amount = 1, options = {}|
            @backend.increment(key, amount, options)
          end
        end
        # Value-preserving TTL. SubCache feature-detects this to avoid the
        # re-store that would lose a concurrent generation increment.
        if @backend.respond_to?(:expire)
          define_singleton_method(:expire) do |key, ttl|
            @backend.expire(key, ttl)
          end
        end
      end

      # --- Moneta response-cache interface ---------------------------------
      # Delegate straight to the shared backend. These four methods are all
      # the Faraday caching middleware requires, so a view is a drop-in
      # replacement for a bare Parse::Cache::Redis.

      # `load` is the read primitive, delegated to the backend so the options
      # argument reaches something that can honor it. Deriving it from `[]`
      # here is what produced infinite recursion in an earlier version.
      def load(key, options = {})
        @backend.load(key, options || {})
      end

      def [](key)
        load(key, {})
      end

      def key?(key, options = {})
        @backend.key?(key, options || {})
      end

      def delete(key, options = {})
        @backend.delete(key, options || {})
      end

      def store(key, value, options = {})
        @backend.store(key, value, options || {})
      end

      # --- scoped eviction --------------------------------------------------

      # Clear cached entries belonging to THIS view's keyspace, and nothing
      # else: never anything from another view over the same backend.
      #
      # @param scope [String, nil] explicit namespace prefix to scan-delete,
      #   narrowed inside this view's root_prefix. See
      #   {Parse::Cache::Redis#clear} for the exact semantics; the difference
      #   here is that there is no unscoped/FLUSHDB fallback branch to fall
      #   into, because a view always has a keyspace.
      # @param family [Symbol, String, nil] narrow to one family.
      # @param tenant [String, nil] narrow to one tenant (requires `family`).
      # @return [self]
      def clear(scope: nil, family: nil, tenant: nil)
        if scope
          prefix = @backend.send(:validate_scope!, scope)
          raw_delete_matching!("#{@keyspace.root_prefix}:#{prefix}:*")
        else
          raw_delete_matching!(@keyspace.pattern(family: family, tenant: tenant))
        end
        self
      end

      # Delete every key matching a glob pattern, refusing anything outside
      # this view's own keyspace.
      #
      # The check requires the segment boundary (`root_prefix` followed by
      # `:`), not a bare string prefix: every pattern this keyspace actually
      # generates ({Parse::Cache::Keyspace#pattern},
      # {Parse::Cache::Keyspace#resource_pattern}) is `"<root_prefix>:..."`,
      # so this rejects nothing legitimate. A bare `start_with?(root_prefix)`
      # would accept a pattern belonging to a DIFFERENT namespace that merely
      # shares a prefix: a view whose namespace is `"foo"` would happily
      # delete_matching a pattern for namespace `"foobar"`, since the string
      # `"...:foobar:..."` starts with `"...:foo"`.
      #
      # @param pattern [String] a Redis glob pattern.
      # @return [Integer] number of keys removed.
      def delete_matching(pattern)
        return 0 if pattern.nil? || pattern.to_s.empty?
        return 0 unless pattern.to_s.start_with?("#{@keyspace.root_prefix}:")
        raw_delete_matching!(pattern)
      end

      # --- identity / role / upstream planes, one instance per view --------
      # Never shared with the backend's own (legacy, unscoped) `identity` /
      # `roles` / `upstream_roles`, and never shared between two views over
      # the same backend.

      # @param ttl [Integer, nil]
      # @return [Parse::Cache::SubCache]
      def identity(ttl: nil)
        @identity ||= Parse::Cache::SubCache.new(store: self, keyspace: @keyspace, family: :idn, ttl: ttl)
      end

      # @param ttl [Integer, nil]
      # @return [Parse::Cache::SubCache]
      def roles(ttl: nil)
        @roles ||= Parse::Cache::SubCache.new(store: self, keyspace: @keyspace, family: :role, ttl: ttl)
      end

      # Read-only consumer of Parse Server's own role cache, scoped to this
      # view's app id and role plane. See {Parse::Cache::Redis#upstream_roles}
      # for the full rationale; the only difference here is that the app id
      # and roles plane come from THIS view's keyspace, never a sibling
      # view's.
      # @return [Parse::Cache::UpstreamRoles, nil]
      def upstream_roles
        return nil if @backend.parse_cache_url.nil?
        @upstream_roles ||= Parse::Cache::UpstreamRoles.new(
          client: @backend.send(:upstream_client),
          app_id: @keyspace.app_id,
          roles_plane: roles,
        )
      end

      # --- locks: unscoped, delegated straight to the backend ---------------

      # @see Parse::Cache::Redis#lock_acquire
      def lock_acquire(key, owner, ttl)
        @backend.lock_acquire(key, owner, ttl)
      end

      # @see Parse::Cache::Redis#lock_release
      def lock_release(key, owner)
        @backend.lock_release(key, owner)
      end

      def inspect
        "#<Parse::Cache::ScopedView #{@keyspace.root_prefix}>"
      end

      private

      # Unguarded SCAN+UNLINK against the shared backend. Safe to call here
      # because both public callers above ({#clear}, {#delete_matching})
      # have already confined `pattern` to this view's own root_prefix
      # before reaching this point.
      def raw_delete_matching!(pattern)
        @backend.send(:delete_keys_matching!, pattern)
      end

    end

    # Raised when a keyspaced client is asked to clear a cache store that
    # cannot restrict the clear to its own keyspace.
    class UnscopedClearRefused < StandardError; end

    # Keyspace wrapper for a cache store that is not a
    # {Parse::Cache::Redis} and therefore cannot produce a
    # {Parse::Cache::ScopedView}.
    #
    # `cache_keyspace: true` used to leave such a store installed bare. Key
    # composition still worked, because the caching middleware receives the
    # keyspace directly, so the deployment looked correctly keyspaced. But
    # `Parse::Client#clear_cache!` called the store's own `clear`, and on a
    # plain `Moneta.new(:Redis)` that is `FLUSHDB`. Asking for keyspacing and
    # receiving a database-wide flush inverts the entire point of the option:
    # it deletes other applications' entries and, on a shared database, the
    # `parse-stack:foc:v1:*` create-locks, so a `first_or_create!` holding a
    # lock at that moment silently loses mutual exclusion.
    #
    # This wrapper keeps the store usable for reads and writes and makes the
    # clear honest. Where the store can enumerate its keys (Moneta's
    # `each_key` feature), the clear is scan-and-delete confined to the
    # keyspace, matching what a `ScopedView` does. Where it cannot, the clear
    # raises rather than widening: a store that cannot express "delete only
    # my keys" has no safe answer, and the wrong answer is unrecoverable.
    class KeyspacedStore
      include Parse::Cache::MonetaSurface

      # @return [Parse::Cache::Keyspace]
      attr_reader :keyspace

      # @return [Object] the wrapped store. Named `wrapped` rather than
      #   `store` because `store` is Moneta's writer method, which this class
      #   must keep implementing for the Faraday caching middleware.
      attr_reader :wrapped

      def initialize(store:, keyspace:)
        unless keyspace.is_a?(Parse::Cache::Keyspace)
          raise ArgumentError,
                "Parse::Cache::KeyspacedStore keyspace must be a Parse::Cache::Keyspace; got #{keyspace.class}"
        end
        @wrapped = store
        @keyspace = keyspace.freeze

        # Mirror the wrapped store's optional capabilities rather than always
        # claiming them, so `respond_to?` stays truthful and callers that
        # feature-detect (the create-lock path, SubCache's atomic increment)
        # get the same answer they would from the store itself.
        # `fetch` and `each_key` are deliberately NOT in this list.
        #
        # `fetch` must come from {Parse::Cache::MonetaSurface}, which routes
        # through this wrapper's own `load`. Delegating it handed the call
        # straight to the wrapped store and skipped the wrapper entirely.
        #
        # `each_key` is defined below with keyspace filtering. Delegating it
        # enumerated the WHOLE store, so `sdk_cache.each_key` returned the
        # application's keys alongside the SDK's, which is precisely the
        # confusion this class exists to prevent.
        %i[create increment expire features lock_acquire lock_release].each do |name|
          next unless wrapped_supports?(name)
          define_singleton_method(name) { |*args, **kw, &blk| @wrapped.public_send(name, *args, **kw, &blk) }
        end

        # Only claim `each_key` when the wrapped store can genuinely enumerate.
        if wrapped_supports?(:each_key)
          define_singleton_method(:each_key) do |&blk|
            return enum_for(:each_key) unless blk
            prefix = "#{@keyspace.root_prefix}:"
            @wrapped.each_key { |k| blk.call(k) if k.to_s.start_with?(prefix) }
            self
          end
        end

        # Probe arity ONCE instead of rescuing at call time. See #key?.
        @options_aware = %i[key? delete].to_h { |name| [name, accepts_options?(name)] }
      end

      # --- Moneta response-cache interface ---------------------------------

      # Delegated primitives. `load` falls back to `[]` for a wrapped store
      # that predates Moneta's options argument, so an older custom store
      # still works and simply ignores the hint.
      def load(key, options = {})
        return @wrapped.load(key, options || {}) if @wrapped.respond_to?(:load)
        @wrapped[key]
      end

      def [](key) = load(key, {})
      def store(key, value, options = {}) = @wrapped.store(key, value, options || {})

      # Options are forwarded when the wrapped store can take them, decided
      # by arity at construction.
      #
      # This used to call with options and `rescue ArgumentError` to retry
      # without them. That is wrong twice over: a store's own argument
      # validation also raises ArgumentError, so a genuine rejection was
      # retried rather than surfaced, and for `delete` the retry meant the
      # deletion could run TWICE, once before the raise and once after.
      # Deciding from arity is exact and happens once.
      def key?(key, options = {})
        return @wrapped.key?(key, options || {}) if @options_aware[:key?]
        @wrapped.key?(key)
      end

      def delete(key, options = {})
        return @wrapped.delete(key, options || {}) if @options_aware[:delete]
        @wrapped.delete(key)
      end

      # Delete every entry under this keyspace, and nothing else.
      #
      # @raise [Parse::Cache::UnscopedClearRefused] when the wrapped store
      #   cannot enumerate its keys, and therefore cannot clear within a
      #   keyspace. Use a {Parse::Cache::Redis} for scoped clearing, or call
      #   `client.cache.clear` to take the unscoped clear deliberately.
      # @return [self]
      def clear(scope: nil, family: nil, tenant: nil)
        prefix =
          if scope
            "#{@keyspace.root_prefix}:#{scope.to_s.sub(/:\z/, "")}:"
          else
            pattern = @keyspace.pattern(family: family, tenant: tenant)
            pattern.sub(/\*\z/, "")
          end

        unless wrapped_supports?(:each_key)
          raise UnscopedClearRefused,
                "#{@wrapped.class} cannot enumerate its keys, so it cannot clear only the entries " \
                "under #{@keyspace.root_prefix}. Refusing rather than falling back to an " \
                "unscoped clear, which on a Redis-backed store is FLUSHDB and would delete " \
                "other applications' entries and any parse-stack:foc:v1:* create-locks. " \
                "Use Parse::Cache::Redis for scoped clearing, or call " \
                "client.cache.clear to take the unscoped clear deliberately."
        end

        # Collect before deleting: mutating during enumeration is undefined
        # across Moneta adapters.
        doomed = []
        @wrapped.each_key { |k| doomed << k if k.to_s.start_with?(prefix) }
        doomed.each { |k| @wrapped.delete(k) }
        self
      end

      # @param pattern [String] a glob pattern, refused unless it sits inside
      #   this keyspace.
      # @return [Integer] number of keys removed.
      def delete_matching(pattern)
        return 0 if pattern.nil? || pattern.to_s.empty?
        return 0 unless pattern.to_s.start_with?("#{@keyspace.root_prefix}:")
        return 0 unless wrapped_supports?(:each_key)

        doomed = []
        @wrapped.each_key { |k| doomed << k if File.fnmatch(pattern, k.to_s, File::FNM_NOESCAPE) }
        doomed.each { |k| @wrapped.delete(k) }
        doomed.size
      end

      def inspect
        "#<Parse::Cache::KeyspacedStore #{@keyspace.root_prefix} over #{@wrapped.class}>"
      end

      private

      # Whether the wrapped store genuinely provides a capability.
      #
      # `respond_to?` is not enough for a Moneta store. Moneta defines every
      # optional method on every store and has the unsupported ones raise
      # `NotImplementedError`, so `Moneta.new(:Null).respond_to?(:each_key)`
      # is true while calling it raises. Advertising it on that basis made
      # this wrapper claim `each_key`, `create`, and `increment` for a store
      # that has none of them, and a scoped `clear` then leaked
      # `NotImplementedError` instead of the `UnscopedClearRefused` this class
      # promises. `supports?` is Moneta's own answer to that question.
      #
      # It only covers Moneta's feature vocabulary, so anything outside it
      # (`expire`, the lock pair) still falls back to `respond_to?`.
      MONETA_FEATURES = %i[create increment each_key].freeze
      private_constant :MONETA_FEATURES

      def wrapped_supports?(name)
        return false unless @wrapped.respond_to?(name)
        return true unless MONETA_FEATURES.include?(name)
        return true unless @wrapped.respond_to?(:supports?)
        !!@wrapped.supports?(name)
      rescue StandardError
        false
      end

      # @return [Boolean] whether the wrapped method takes an options argument.
      def accepts_options?(name)
        arity = @wrapped.method(name).arity
        arity.negative? || arity >= 2
      rescue NameError
        false
      end

    end
  end
end
