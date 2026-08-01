# encoding: UTF-8
# frozen_string_literal: true

require "digest"

module Parse
  module Cache
    # Owns the physical layout of every key this SDK writes to a shared cache
    # backend, and the patterns used to delete them again.
    #
    # A single object generates keys *and* the patterns that clear them, so the
    # two can never disagree. Previously the caching middleware composed keys
    # from a `cache_namespace:` it held privately while `Parse::Cache::Redis`
    # held a separate `namespace`, and `Parse::Client#clear_cache!` cleared
    # using only the latter. A client namespaced at the middleware but not at
    # the wrapper would therefore delete every SDK key on the database rather
    # than its own.
    #
    # Layout:
    #
    #   parse-stack:<version>:<app_scope>[:<namespace>]:<family>[:T:<tenant>]:<rest>
    #
    # Every clear is a strict prefix of this, so narrowing the scope can only
    # ever delete a subset:
    #
    #   all of this client   parse-stack:v1:<app_scope>[:<ns>]:*
    #   one family           parse-stack:v1:<app_scope>[:<ns>]:<family>:*
    #   one tenant           parse-stack:v1:<app_scope>[:<ns>]:<family>:T:<tenant>:*
    #
    # `app_scope` is a digest of the Parse application id and server URL rather
    # than the raw values. Two apps sharing one Redis with no namespace
    # configured would otherwise collide, and a raw application id could carry
    # glob metacharacters (`*`, `[`) that would silently widen a SCAN pattern.
    # The digest is fixed-length and glob-safe by construction.
    #
    # Create-locks are deliberately NOT part of this layout. They keep the
    # historical `parse-stack:foc:v1:` prefix from {Parse::Model::CreateLock}.
    # Moving them would mean that during a rolling deploy two workers compute
    # different lock keys, stop contending on the same key, and silently lose
    # mutual exclusion for the length of the deploy.
    class Keyspace
      # Root segment for every key this SDK owns.
      ROOT = "parse-stack"

      # Layout version. Bump only for a breaking key-shape change, which
      # orphans every existing entry and therefore needs a migration note.
      VERSION = "v1"

      # Occupies the namespace position when no namespace is configured. Chosen
      # because {#normalize_segment} rejects it as caller input, so a caller can
      # never collide with the unnamespaced keyspace by naming their namespace
      # after the sentinel.
      NO_NAMESPACE = "_"

      # Key families. `cache` is the Faraday response cache, `idn` is
      # session-token identity, `role` is role closures.
      FAMILIES = %i[cache idn role].freeze

      # Length of the truncated app/server digest. 12 hex characters is 48
      # bits, which is ample for distinguishing apps on one database while
      # keeping keys readable.
      SCOPE_DIGEST_LENGTH = 12

      # Characters that carry meaning in a Redis glob pattern. A namespace or
      # tenant containing one of these could widen a SCAN pattern beyond its
      # intended scope, so they are rejected at construction rather than
      # escaped, since a caller passing one is a configuration bug.
      # `:` is included deliberately alongside the glob metacharacters. It is the
      # segment separator, so a namespace of `foo:bar` would forge an extra
      # segment and make the pattern for `foo` also match `foo:bar`, which is
      # the same subset violation the sentinel above prevents.
      GLOB_METACHARS = /[\*\?\[\]\\\x00:]/.freeze

      # @return [String] digest identifying the Parse app and server.
      attr_reader :app_scope

      # @return [String, nil] the raw Parse application id. Retained alongside
      #   the digest because Parse Server's own cache keys use it verbatim
      #   (`<appId>:role:<userId>`), so an attached read needs the original
      #   even though our own layout uses the digest.
      attr_reader :app_id

      # @return [String, nil] validated namespace, or nil when unset.
      attr_reader :namespace

      # @return [String] layout version segment.
      attr_reader :version

      # @param app_id [String, nil] the Parse application id.
      # @param server_url [String, nil] the Parse server URL.
      # @param namespace [String, nil] optional operator-supplied namespace.
      # @param version [String] layout version, for tests and migrations.
      # @raise [ArgumentError] if the namespace is unusable as a key segment.
      def initialize(app_id: nil, server_url: nil, namespace: nil, version: VERSION)
        @app_id = app_id&.to_s
        @app_scope = self.class.digest_scope(app_id, server_url)
        @namespace = normalize_segment(namespace, "namespace")
        @version = version.to_s
      end

      # Digest of the app id and server URL. Public so callers can compare two
      # keyspaces for equivalence without reaching into internals.
      #
      # @return [String] fixed-length, glob-safe hex digest.
      def self.digest_scope(app_id, server_url)
        material = "#{app_id}\x00#{server_url}"
        Digest::SHA256.hexdigest(material)[0, SCOPE_DIGEST_LENGTH]
      end

      # Prefix shared by every key this keyspace owns, across all families.
      # @return [String]
      def root_prefix
        # The namespace segment is ALWAYS emitted, using NO_NAMESPACE when unset.
        # Without it an unnamespaced root is a strict prefix of every namespaced
        # root for the same app, so `<root>:*` would also delete every named
        # namespace's keys. Narrowing must only ever delete a subset, and a
        # sentinel is the only way to keep the segment count fixed.
        [ROOT, @version, @app_scope, @namespace || NO_NAMESPACE].join(":")
      end

      # Prefix for one family.
      # @param family [Symbol, String]
      # @return [String]
      # @raise [ArgumentError] on an unknown family.
      def family_prefix(family)
        "#{root_prefix}:#{assert_family!(family)}"
      end

      # Build a key for the `idn` or `role` families.
      #
      # Neither takes an auth discriminator: a role key is keyed by user id and
      # an identity key by session token, so the key already *is* the auth
      # identity. Only the response cache has one URL yielding different bodies
      # to different callers, and it uses {#cache_key}.
      #
      # @param family [Symbol, String] `:idn` or `:role`.
      # @param segments [Array<String>] trailing key segments, joined with `:`.
      #   Not validated for glob characters: they are only ever written and read
      #   as literal keys, never used as a SCAN pattern.
      # @param tenant [String, nil] ambient cache tenant, if any.
      # @return [String]
      # @raise [ArgumentError] if called for the `cache` family.
      def key(family, *segments, tenant: nil)
        if family.to_sym == :cache
          raise ArgumentError,
                "Parse::Cache::Keyspace: use #cache_key for the cache family, " \
                "so the auth discriminator cannot be omitted"
        end
        parts = [family_prefix(family)]
        parts << "T:#{normalize_segment(tenant, "tenant")}" unless tenant.nil?
        parts.concat(segments.map(&:to_s))
        parts.join(":")
      end

      # Build a response-cache key.
      #
      # `auth:` is mandatory and has no default. A master-key request bypasses
      # ACL, CLP and `protectedFields`, so the same URL returns a strictly
      # fuller body than a session-token request, and two different sessions can
      # differ from each other through `protectedFields` entity rules and row
      # ACLs. Collapsing those into one key would serve privileged fields to an
      # unprivileged caller out of the cache, so the key cannot be built without
      # stating which auth produced the body.
      #
      # The URL is digested and placed *before* the discriminator so that every
      # auth variant of one resource shares a prefix, which is what makes
      # {#resource_pattern} able to invalidate a write for all callers rather
      # than only the three variants the old `delete_cache_variants` could name.
      #
      # @param url [String] the request URL.
      # @param auth [Symbol, String] `:anon`, `:master`, or a session-token digest.
      # @param tenant [String, nil] ambient cache tenant, if any.
      # @return [String]
      def cache_key(url, auth:, tenant: nil)
        "#{resource_prefix(url, tenant: tenant)}:#{normalize_auth(auth)}"
      end

      # Pattern matching every auth variant of one resource. Used to invalidate
      # a resource on write for all callers, including sessions this process
      # has never seen.
      #
      # @param url [String] the request URL.
      # @param tenant [String, nil] ambient cache tenant, if any.
      # @return [String]
      def resource_pattern(url, tenant: nil)
        "#{resource_prefix(url, tenant: tenant)}:*"
      end

      # Glob pattern selecting keys to clear. With no arguments it selects
      # every key this keyspace owns and nothing else.
      #
      # @param family [Symbol, String, nil] narrow to one family.
      # @param tenant [String, nil] narrow to one tenant. Requires `family`,
      #   since tenant is positioned inside the family segment.
      # @return [String]
      # @raise [ArgumentError] if a tenant is given without a family.
      def pattern(family: nil, tenant: nil)
        if tenant && family.nil?
          raise ArgumentError,
                "Parse::Cache::Keyspace#pattern requires a family: when a tenant: is given"
        end
        return "#{root_prefix}:*" if family.nil?

        prefix = family_prefix(family)
        return "#{prefix}:*" if tenant.nil?
        "#{prefix}:T:#{normalize_segment(tenant, "tenant")}:*"
      end

      # Whether two keyspaces address the same key space. Used to detect a
      # client reconfigured with a different namespace or app.
      # @return [Boolean]
      def ==(other)
        other.is_a?(Keyspace) && other.root_prefix == root_prefix
      end

      alias eql? ==

      def hash
        root_prefix.hash
      end

      def to_s
        root_prefix
      end

      def inspect
        "#<Parse::Cache::Keyspace #{root_prefix}>"
      end

      # Auth discriminator for an anonymous (unauthenticated) request.
      AUTH_ANON = "anon"

      # Auth discriminator for a master-key request.
      AUTH_MASTER = "mk"

      # A session-token discriminator must look like the truncated SHA-256 the
      # caching middleware produces. Anything else is a caller bug, and a raw
      # token must never reach a key.
      TOKEN_DIGEST_RE = /\A[0-9a-f]{16,64}\z/.freeze

      private

      # Prefix shared by every auth variant of one resource.
      def resource_prefix(url, tenant: nil)
        parts = [family_prefix(:cache)]
        parts << "T:#{normalize_segment(tenant, "tenant")}" unless tenant.nil?
        parts << Digest::SHA256.hexdigest(url.to_s)
        parts.join(":")
      end

      def normalize_auth(auth)
        case auth
        when :anon, "anon" then AUTH_ANON
        when :master, "master", "mk" then AUTH_MASTER
        when String
          unless auth.match?(TOKEN_DIGEST_RE)
            raise ArgumentError,
                  "Parse::Cache::Keyspace auth: must be :anon, :master, or a hex " \
                  "session-token digest; a raw session token must never be used as " \
                  "a key segment"
          end
          auth
        else
          raise ArgumentError,
                "Parse::Cache::Keyspace auth: must be :anon, :master, or a hex " \
                "session-token digest; got #{auth.class}"
        end
      end

      def assert_family!(family)
        sym = family.to_sym
        unless FAMILIES.include?(sym)
          raise ArgumentError,
                "Parse::Cache::Keyspace family must be one of #{FAMILIES.join(", ")}; got #{family.inspect}"
        end
        sym.to_s
      end

      # Normalize an operator-supplied key segment. Returns nil for an
      # absent/empty value so callers can treat "unset" uniformly.
      def normalize_segment(value, label)
        return nil if value.nil?
        unless value.is_a?(String) || value.is_a?(Symbol)
          raise ArgumentError,
                "Parse::Cache::Keyspace #{label} must be a String or Symbol; got #{value.class}"
        end
        segment = value.to_s.chomp(":")
        return nil if segment.empty?
        if segment == NO_NAMESPACE
          raise ArgumentError,
                "Parse::Cache::Keyspace #{label} must not be #{NO_NAMESPACE.inspect}; " \
                "that value is reserved for the unnamespaced keyspace"
        end
        if segment.match?(GLOB_METACHARS)
          raise ArgumentError,
                "Parse::Cache::Keyspace #{label} must not contain \":\", Redis glob " \
                "characters (*, ?, [, ], \\), or NUL; got #{value.inspect}. \":\" is the " \
                "segment separator, so allowing it would let one value forge extra key " \
                "segments and escape its own part of the keyspace. A single trailing " \
                "\":\" is stripped for convenience, so \"web\" and \"web:\" are equivalent."
        end
        segment
      end
    end
  end
end
