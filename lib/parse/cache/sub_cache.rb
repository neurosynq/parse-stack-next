# encoding: UTF-8
# frozen_string_literal: true

require "digest"
require "set"

module Parse
  module Cache
    # A named plane within a {Parse::Cache::Keyspace}, exposing the
    # `get` / `set` / `invalidate` contract that `Parse::AtlasSearch`'s
    # `session_cache=` and `role_cache=` slots accept.
    #
    # The response cache speaks Moneta (`[]`, `key?`, `delete`, `store`) because
    # that is what the Faraday middleware requires. Identity and role resolution
    # speak a different, smaller contract. Rather than flattening both onto one
    # object, where `get` and `[]` would sit side by side and `clear` would be
    # ambiguous about which plane it cleared, each plane is its own object over
    # the same connection. This mirrors Parse Server's own
    # `CacheController` / `SubCache` split.
    class SubCache
      # @return [Symbol] the keyspace family this plane writes.
      attr_reader :family

      # @param store [Object] the backing store (a {Parse::Cache::Redis}).
      # @param keyspace [Parse::Cache::Keyspace] key layout owner.
      # @param family [Symbol] `:idn` or `:role`.
      # @param ttl [Integer, nil] default TTL in seconds.
      # @param digest_keys [Boolean] hash the logical key before it becomes part
      #   of a Redis key. Required for the identity plane: its logical key is a
      #   raw session token supplied by `Parse::AtlasSearch::Session`, and a raw
      #   token must never be written into a key, where MONITOR, SLOWLOG, and
      #   APM key capture would all expose it. Digesting here rather than at the
      #   call site also keeps `get`, `set`, and `invalidate` consistent by
      #   construction: a caller that digested for one and not another would
      #   silently delete a different key than it wrote.
      # Generation keys live this many times longer than the longest entry
      # they guard. Any factor above 1 is sufficient; 2 leaves margin for
      # clock skew and for an entry written moments before a bump.
      GENERATION_TTL_FACTOR = 2

      def initialize(store:, keyspace:, family:, ttl: nil, digest_keys: nil)
        @store = store
        @keyspace = keyspace
        @family = family.to_sym
        @ttl = ttl
        @digest_keys = digest_keys.nil? ? @family == :idn : digest_keys
      end

      # @return [Integer, nil] how long a generation key lives, or nil when
      #   this plane has no default TTL and generations must therefore be
      #   permanent. See {#bump_generation} for why the two are tied.
      def generation_ttl
        return nil if @ttl.nil?
        (@ttl * GENERATION_TTL_FACTOR).ceil
      end

      # @param key [String] the logical key (a token digest or user id).
      # @return [Object, nil] the stored value, or nil on a miss.
      def get(key)
        return nil if key.nil?
        decode(@store[@keyspace.key(@family, logical_key(key))])
      end

      # @param key [String] the logical key.
      # @param value [Object] a JSON-serializable value.
      # @param ttl [Integer, nil] seconds; falls back to the plane default.
      def set(key, value, ttl: nil)
        return value if key.nil?
        effective = clamp_ttl(ttl || @ttl)
        options = effective ? { expires: effective } : {}
        @store.store(@keyspace.key(@family, logical_key(key)), encode(value), options)
        value
      end

      # @param key [String] the logical key.
      def invalidate(key)
        return if key.nil?
        @store.delete(@keyspace.key(@family, logical_key(key)))
      end

      # Evict every entry in this plane, and nothing outside it.
      # @return [Integer] number of keys removed, when the store can report it.
      def clear
        return 0 unless @store.respond_to?(:delete_matching)
        @store.delete_matching(@keyspace.pattern(family: @family))
      end

      # Monotonic per-subject generation, used to invalidate entries that cannot
      # be named.
      #
      # A `_User` write tells us a user id, but identity entries are keyed by
      # session token and there is no reverse map, so the entries belonging to
      # that user cannot be enumerated. Bumping a generation the reader checks
      # invalidates all of them in O(1), including tokens this process has never
      # seen, without a master-key `_Session` query.
      #
      # **Generation keys expire, and their TTL must exceed the longest-lived
      # entry they guard.** One key per user id, written on every `_User`
      # webhook, is unbounded growth on a public signup flow: every account
      # that ever saves leaves a permanent key behind.
      #
      # The TTL cannot be chosen freely, because expiry resets the counter to
      # 0 and 0 is also the value for a user who has never been bumped. If a
      # generation expired while an entry written at generation 0 were still
      # alive, that entry would compare current again and come back from the
      # dead after having been invalidated. {#generation_ttl} is therefore
      # {GENERATION_TTL_FACTOR} times the plane's entry TTL, so every entry
      # predating a bump has expired on its own before the counter can reset.
      # {#set} clamps per-call TTLs to keep that invariant true.
      #
      # A plane with no default TTL keeps permanent generations: entries there
      # never expire, so no counter lifetime is safe.
      #
      # @param subject [String] the user id.
      # @return [Integer] the new generation.
      def bump_generation(subject)
        return 0 if subject.nil?
        key = generation_key(subject)
        ttl = generation_ttl
        # Prefer an atomic INCR. A read-then-write loses a concurrent bump, and
        # a lost bump means an entry that should have been invalidated stays
        # readable, which is the permissive direction.
        if @store.respond_to?(:increment)
          value = @store.increment(key).to_i
          # INCR does not set an expiry, and re-applying it on each bump is
          # what keeps an actively-bumped user's counter alive.
          refresh_generation_expiry(key, value, ttl)
          value
        else
          current = @store[key].to_i
          @store.store(key, current + 1, ttl ? { expires: ttl } : {})
          current + 1
        end
      end

      # @param subject [String] the user id.
      # @return [Integer] current generation, 0 when never bumped.
      def generation(subject)
        return 0 if subject.nil?
        @store[generation_key(subject)].to_i
      end

      # Whether a value carrying `gen` is still current for `subject`.
      # @return [Boolean]
      def generation_current?(subject, gen)
        generation(subject).to_i == gen.to_i
      end

      # Record that this plane was invalidated at `at`. Unlike a generation,
      # which answers "is this exact subject stale", the epoch answers "is an
      # entry written before now stale", which is what is needed to reject a
      # *foreign* cache entry whose write time can only be derived from its
      # remaining TTL.
      #
      # @param at [Float] wall-clock seconds; defaults to now.
      # @return [Float] the recorded epoch.
      def touch_epoch(at = Time.now.to_f)
        current = epoch
        # Never move the epoch backwards: clock skew between workers would
        # otherwise re-admit entries a previous invalidation had rejected.
        value = at > current ? at : current
        @store.store(epoch_key, value, {})
        value
      end

      # @return [Float] the last invalidation epoch, 0.0 when never set.
      def epoch
        @store[epoch_key].to_f
      end

      # Whether an entry written at `written_at` predates the last invalidation
      # and must therefore be treated as a miss.
      #
      # @param written_at [Float, nil] derived write time in wall-clock seconds.
      # @return [Boolean] true when the entry is safe to use.
      def fresh_since_epoch?(written_at)
        return false if written_at.nil?
        written_at.to_f >= epoch
      end

      private

      # Keep an entry from outliving the generation counter that invalidates
      # it. A caller passing `ttl:` greater than the plane default would
      # otherwise create exactly the resurrection window {#bump_generation}
      # describes: the counter expires back to 0, and an entry still alive
      # from before the bump compares current again.
      #
      # Shortening silently is the safe direction. The cost is an extra
      # resolution; the cost of the alternative is a session that stays
      # resolvable after it was invalidated.
      def clamp_ttl(requested)
        return requested if requested.nil?
        ceiling = @ttl
        return requested if ceiling.nil?
        requested > ceiling ? ceiling : requested
      end

      # Apply the expiry INCR does not set, WITHOUT rewriting the value.
      #
      # An earlier version fell back to `store(key, value, expires: ttl)`
      # when the backend had no `expire`. That is a lost update: two
      # concurrent bumps interleave as INCR(2), INCR(3), store(3), store(2),
      # and the counter moves BACKWARDS. Generation checks are equality
      # comparisons, so a counter that goes back to a previously issued value
      # re-admits every identity entry stamped with it. Those are exactly the
      # entries a `_User` write was invalidating, which makes the failure a
      # revoked session becoming resolvable again.
      #
      # Rewriting the value is therefore never acceptable here, no matter the
      # width of the window. Where the backend cannot set a TTL without
      # touching the value, the key simply stays non-expiring, which is the
      # behavior this method was added to improve on: unbounded, but correct.
      # {Parse::Cache::Redis} implements `expire` (PEXPIRE), so the Redis
      # deployments where growth actually matters do get the TTL.
      def refresh_generation_expiry(key, value, ttl)
        return if ttl.nil?
        return unless @store.respond_to?(:expire)
        @store.expire(key, ttl)
      rescue StandardError
        # A counter without an expiry is the pre-existing behavior: correct,
        # just unbounded. Never fail a webhook over it.
        nil
      end

      # Session tokens must not appear in keys; other logical keys (a user id)
      # are opaque already and stay readable for debugging.
      def logical_key(key)
        return key.to_s unless @digest_keys
        Digest::SHA256.hexdigest(key.to_s)[0, 32]
      end

      # The backing store serializes values as JSON, and `JSON.generate(Set)`
      # produces the string "#<Set: {...}>" rather than an array, so a Set
      # written straight through comes back as a String and every read misses.
      # `Parse::AtlasSearch` stores and expects a Set, so tag it and rebuild on
      # the way out.
      SET_TAG = "__set__"

      def encode(value)
        return { SET_TAG => value.to_a } if value.is_a?(Set)
        value
      end

      def decode(value)
        return Set.new(value[SET_TAG]) if value.is_a?(Hash) && value.key?(SET_TAG)
        value
      end

      # Epoch shares the family so a plane clear resets it, and sits under a
      # reserved segment so it cannot collide with a real entry.
      def epoch_key
        @keyspace.key(@family, "meta", "epoch")
      end

      # Generations live in the same family so a plane clear takes them with it,
      # and are namespaced under `gen:` so they cannot collide with an entry
      # whose logical key happens to be a user id.
      def generation_key(subject)
        @keyspace.key(@family, "gen", subject.to_s)
      end
    end
  end
end
