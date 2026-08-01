# encoding: UTF-8
# frozen_string_literal: true

require "digest"
require "json"
require "set"

module Parse
  module Cache
    # Read-only consumer of Parse Server's own role cache.
    #
    # Parse Server caches `<appId>:role:<userId>` as a JSON array of
    # `"role:NAME"` strings representing the transitive closure. When the SDK
    # already holds a user id from a trusted source (a webhook payload, most
    # usefully), reading that entry skips the role-graph walk entirely, and the
    # value was computed by Parse Server's own code so there is no divergence
    # between our closure and the one the server enforces.
    #
    # **We never write this keyspace.** Our closure is depth-capped while Parse
    # Server's is not, so injecting ours would hand the server a strict subset
    # in a deep hierarchy, which it would then read back as authoritative and
    # under-permission users in windows that are close to undiagnosable.
    #
    # **Trust.** This makes the Parse Server cache database part of the SDK's
    # authorization trust base: the array feeds `permission_strings`, which is
    # the only input to both the `_rperm` match and the CLP gate on the
    # mongo-direct path. Anyone who can write that database can grant themselves
    # roles. The credential should be restricted accordingly:
    #
    #     ACL SETUSER parse-stack-role-reader on >SECRET \
    #       ~<appId>:role:* resetchannels -@all +get +pttl
    #
    # `+pttl` is required alongside `+get`: the freshness guard below cannot run
    # without it, and PTTL is a separate ACL command from GET.
    class UpstreamRoles
      # Parse Server's `RedisCacheAdapter` default TTL, used to derive an
      # entry's write time from its remaining TTL. Configurable because an
      # operator supplies the adapter instance and may have passed another.
      DEFAULT_UPSTREAM_TTL_MS = 30_000

      # Reject an entry whose remaining TTL exceeds this. Neither Parse Server
      # entry carries its own write time, so a very long TTL means either a
      # misconfigured adapter or a value we cannot age, and an un-ageable
      # authorization input is not one to trust.
      DEFAULT_MAX_TTL_MS = 60_000

      # Caps on the decoded array. Role counts scale with tenants, so these are
      # generous: a low cap would be an outage, not a safeguard. An unbounded
      # array becomes an unbounded `$in` sent to MongoDB.
      MAX_ROLE_COUNT = 4096
      MAX_ROLE_NAME_LENGTH = 256

      # Role names may legitimately contain `/` and `:` (scoped conventions such
      # as `owner/t:<id>/p:<id>` are common), so this only excludes control
      # characters and the NUL byte. A tighter pattern would reject every role
      # in such an app and fail closed into total loss of role access.
      INVALID_ROLE_NAME = /[\x00-\x1f\x7f]/.freeze

      attr_reader :app_id

      # @param client [Object] a redis-rb-shaped client answering `get` and
      #   `pttl`. Injected rather than constructed so tests and alternative
      #   transports work, and so the caller owns connection lifecycle.
      # @param app_id [String] Parse application id, used to build the key.
      # @param roles_plane [Parse::Cache::SubCache, nil] our own role plane,
      #   consulted for the invalidation epoch.
      # @param upstream_ttl_ms [Integer] Parse Server's configured entry TTL.
      # @param max_ttl_ms [Integer] reject entries with more remaining than this.
      def initialize(client:, app_id:, roles_plane: nil,
                     upstream_ttl_ms: DEFAULT_UPSTREAM_TTL_MS,
                     max_ttl_ms: DEFAULT_MAX_TTL_MS)
        @client = client
        @app_id = app_id.to_s
        @roles_plane = roles_plane
        @upstream_ttl_ms = upstream_ttl_ms
        @max_ttl_ms = max_ttl_ms
      end

      # Key Parse Server writes for a user's role closure.
      # @return [String]
      def key_for(user_id)
        "#{@app_id}:role:#{user_id}"
      end

      # Read and validate the upstream closure.
      #
      # @param user_id [String]
      # @return [Set<String>, nil] bare role names (no `role:` prefix), or nil
      #   on any miss, malformed value, stale entry, or transport error. Every
      #   failure is a miss, so the caller falls back to computing the closure
      #   itself. This never fails open.
      def roles_for(user_id)
        return nil if user_id.nil? || user_id.to_s.empty?
        key = key_for(user_id)

        raw = @client.get(key)
        return nil if raw.nil?

        ttl = safe_pttl(key)
        return nil unless usable_ttl?(ttl)
        return nil unless fresh?(ttl)

        decode(raw)
      rescue StandardError
        # Transport failures, malformed JSON, anything: treat as a miss. Note
        # the deliberate absence of the exception message, which would carry the
        # key and therefore the user id.
        nil
      end

      # Whether the entry is newer than our last role invalidation.
      #
      # Parse Server does not clear its role cache on a `_Role` delete, so
      # without this gate a delete we handled would be undone by reading their
      # surviving entry. Neither entry records its write time, so it is derived
      # from what remains of the configured TTL.
      def fresh?(pttl_ms)
        return true if @roles_plane.nil?
        elapsed_ms = @upstream_ttl_ms - pttl_ms
        written_at = Time.now.to_f - (elapsed_ms / 1000.0)
        @roles_plane.fresh_since_epoch?(written_at)
      end

      # Whether our own database also holds Parse Server's cache entries, which
      # means the two are the same database.
      #
      # The probe deliberately runs against OUR connection, looking for THEIR
      # key pattern, rather than the reverse. An earlier version wrote a
      # sentinel on our side and tried to read it back through the upstream
      # client, which cannot work under the credential this class documents:
      # that ACL permits only `<appId>:role:*`, so reading a
      # `parse-stack:probe:*` key returns NOPERM. The rescue then swallowed it
      # and reported the databases as isolated, so the check passed exactly when
      # it was least able to see anything.
      #
      # Inverting it also removes the write. We never need to create a key to
      # answer the question, and our own connection has the permissions to scan
      # its own database.
      #
      # **This can only ever prove sharing, never isolation.** A `false`
      # return means "no Parse-Server-shaped key was seen", which is what a
      # genuinely separate database looks like AND what a shared database
      # looks like before Parse Server has cached its first role closure. A
      # freshly deployed stack is in that second state, and it is exactly
      # when an operator is most likely to run the check. Callers must not
      # report `false` as "isolated"; see
      # {Parse::Cache::Redis#verify_upstream_isolation!}, which pairs this
      # with a sentinel round-trip that CAN establish the negative.
      #
      # @param scanner [Object] our own store, answering `scan_exist?` or a
      #   redis-rb-shaped `scan`.
      # @return [Boolean] true when Parse Server's keys are visible in our
      #   database. False means only "not detected".
      def shares_database_with?(scanner)
        pattern = "#{@app_id}:role:*"
        client = scanner.respond_to?(:scan) ? scanner : nil
        return false if client.nil?

        cursor = "0"
        # Bounded: a handful of iterations is enough to answer "are any of their
        # keys here", and an unbounded scan on a large database would be a
        # startup stall.
        8.times do
          cursor, keys = client.scan(cursor, match: pattern, count: 100)
          # Callers that use a broad pattern are responsible for filtering out
          # anything that is not a genuine Parse Server entry before it reaches
          # here. `Parse::Cache::Redis` wraps its client in a scanner that
          # keeps only keys matching the upstream `<appId>:role:<userId>`
          # shape, so the filtering lives next to the wiring rather than being
          # duplicated in both places.
          return true unless keys.empty?
          break if cursor == "0"
        end
        false
      rescue StandardError
        # Cannot tell. Report not-shared so a probe failure never blocks
        # startup; the warning path is advisory, not a gate.
        false
      end

      private

      def safe_pttl(key)
        return nil unless @client.respond_to?(:pttl)
        @client.pttl(key)
      rescue StandardError
        nil
      end

      # -1 means no expiry, -2 means the key vanished between GET and PTTL, nil
      # means we could not ask. An entry we cannot age is one we cannot trust.
      def usable_ttl?(ttl)
        return false if ttl.nil?
        ttl = ttl.to_i
        return false if ttl.negative?
        return false if ttl > @max_ttl_ms
        true
      end

      # Validate strictly and strip exactly one `role:` prefix. Our own
      # `role_names` set holds bare names and re-adds the prefix when building
      # permission strings, so reading prefixed values straight through would
      # yield `role:role:X` and silently under-permission every query.
      def decode(raw)
        parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
        return nil unless parsed.is_a?(Array)
        return Set.new if parsed.empty?
        return nil if parsed.size > MAX_ROLE_COUNT

        names = Set.new
        parsed.each do |entry|
          return nil unless entry.is_a?(String)
          return nil if entry.length > MAX_ROLE_NAME_LENGTH
          return nil unless entry.start_with?("role:")
          name = entry.sub(/\Arole:/, "")
          return nil if name.empty?
          return nil if name == "*"
          return nil if name.match?(INVALID_ROLE_NAME)
          names << name
        end
        names
      end
    end
  end
end
