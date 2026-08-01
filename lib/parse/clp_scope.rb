# encoding: UTF-8
# frozen_string_literal: true

require "set"
require_relative "model/clp"

module Parse
  module CLPScope
    class Denied < StandardError
      attr_reader :class_name, :operation

      def initialize(class_name, operation, reason = nil)
        @class_name = class_name
        @operation = operation
        super(reason || "CLP denied: #{operation} on #{class_name}")
      end
    end

    OPERATIONS = %i[find count get create update delete].freeze

    EMPTY_SET = Set.new.freeze
    private_constant :EMPTY_SET

    # Cache-entry shape. `kind:` is the disposition of the most recent
    # schema-fetch attempt:
    #
    # - `:cached_clp`  — schema fetch succeeded and returned a non-empty
    #   `classLevelPermissions` map. {permits?} evaluates against it.
    # - `:no_clp`      — schema fetch succeeded but the class has no CLP
    #   configured (or it's an empty hash). Parse Server treats this as
    #   public-default, so {permits?} returns true for all operations.
    # - `:unresolvable` — schema fetch FAILED (network error, 5xx,
    #   unexpected exception, missing client). FAIL CLOSED:
    #   {permits?} returns false for every non-master query. Without
    #   this, a transient schema-endpoint outage would silently turn an
    #   admin-only class into public-readable for the duration of the
    #   outage — every mongo-direct caller was getting unfiltered rows
    #   because `permits?` returned true on `entry.nil?`.
    #
    # `fetched_at` is a monotonic clock reading used by {stale?} so
    # the SDK isn't fooled by NTP adjustments.
    #
    # `clp` is `nil` for `:no_clp` and `:unresolvable`; readers must
    # branch on `kind` before dereferencing.
    CacheEntry = Struct.new(:kind, :clp, :fetched_at, keyword_init: true)

    # Result of evaluating a single CLP branch for object-access inspection.
    # This is intentionally richer than {permits?}: Parse Server only applies
    # pointer permissions when no public/user/role branch already grants the
    # operation, and callers must then inspect the target row before answering.
    AccessEvaluation = Struct.new(
      :status, :via, :pointer_fields, :role_claims, :reason,
      keyword_init: true,
    ) do
      def allowed?
        status == :allowed
      end

      def denied?
        status == :denied
      end

      def unknown?
        status == :unknown
      end

      def row_check_required?
        status == :allowed && pointer_fields&.any?
      end
    end

    # Positive-cache TTL (seconds): how long a successful schema fetch
    # is reused. Mirrors the previous module-level `@cache_ttl` knob;
    # kept identical to preserve backwards-compatible cache behavior.
    POSITIVE_TTL = 3600

    # Negative-cache TTL (seconds): how long we remember that a class's
    # schema was unresolvable. Short so a transient network blip doesn't
    # gridlock the application for an hour, but non-zero so a permanent
    # failure (auth credential rotated, schema endpoint disabled)
    # doesn't melt the schema endpoint with a thundering herd of retries
    # at request rate.
    NEGATIVE_TTL = 5

    @cache = {}
    @cache_mutex = Mutex.new
    @cache_ttl = POSITIVE_TTL

    class << self
      attr_accessor :cache_ttl, :schema_client

      def permits?(class_name, op, permission_strings, client: nil)
        return true if permission_strings.nil?  # master-key bypass
        return true unless OPERATIONS.include?(op)

        entry = fetch(class_name, client: client)
        # `fetch` never returns nil now — it returns an `:unresolvable`
        # CacheEntry on failure so callers must branch on `kind`.
        case entry.kind
        when :unresolvable
          # FAIL CLOSED. The SDK is the only enforcement layer on the
          # mongo-direct path; without a verified CLP we can't tell
          # whether the class is public or admin-only, and the safe
          # default is to refuse rather than silently surrender row
          # filtering. Operators who want a different posture can
          # pre-populate the cache via {.__cache_put} from a startup
          # hook or static config.
          warn_unresolvable_once!(class_name)
          return false
        when :no_clp
          # Schema fetch succeeded; class has no CLP configured.
          # Parse Server's default is public, so permit.
          return true
        end

        op_map = entry.clp[op.to_s] || entry.clp[op]
        # nil op_map: the operation has no CLP entry. Parse Server's
        # default is public, so permit.
        return true if op_map.nil?
        # Empty op_map (`delete: {}` etc.): nobody but master-key.
        # Master-key already short-circuited above, so deny here.
        return false if op_map.is_a?(Hash) && op_map.empty?

        claim_set = permission_strings.is_a?(Set) ? permission_strings : permission_strings.to_set

        op_map.each do |principal, allowed|
          case principal.to_s
          when "*"
            return true if allowed == true
          when "requiresAuthentication"
            return true if allowed == true && claim_set.any? { |e| user_identity?(e) }
          when "pointerFields"
            # Value is an Array of pointer field names, not a boolean.
            # At the boundary, permit iff the claim set has a user
            # identity to satisfy the constraint with; the actual
            # row-by-row check runs post-fetch via {.pointer_fields_for}.
            next if allowed.nil? || (allowed.respond_to?(:empty?) && allowed.empty?)
            return true if claim_set.any? { |e| user_identity?(e) }
          else
            # Bare userObjectId or "role:Name" — claim-set match.
            return true if allowed == true && claim_set.include?(principal.to_s)
          end
        end

        false
      end

      def assert_permitted!(class_name, op, permission_strings, client: nil)
        return if permits?(class_name, op, permission_strings, client: client)
        raise Denied.new(class_name, op,
                         "CLP refuses #{op} on '#{class_name}' for the current scope.")
      end

      def pointer_fields_for(class_name, op, client: nil)
        entry = fetch(class_name, client: client)
        # No CLP at all, or schema unresolvable: there's no
        # pointerFields constraint to apply. (For :unresolvable the
        # caller's `permits?` already failed closed; this helper just
        # returns nil so a post-fetch row-filter step is skipped.)
        return nil if entry.kind == :no_clp || entry.kind == :unresolvable
        op_map = entry.clp[op.to_s] || entry.clp[op]
        return nil unless op_map.is_a?(Hash)
        fields = op_map["pointerFields"] || op_map[:pointerFields]
        return nil if fields.nil?
        arr = Array(fields).map(&:to_s)
        arr.empty? ? nil : arr
      end

      # Return Parse Server's top-level `readUserFields` or
      # `writeUserFields` row constraint for an operation. Unlike an
      # operation's `pointerFields` grant, these keys live alongside the
      # operation maps in `classLevelPermissions` and therefore need their
      # own lookup.
      #
      # @param class_name [String] Parse class name.
      # @param op [Symbol] CLP operation.
      # @return [Array<String>, nil] pointer field names, or nil when the
      #   operation has no corresponding user-field constraint.
      def user_fields_for(class_name, op, client: nil)
        key = case op.to_sym
          when :find, :get, :count then "readUserFields"
          when :create, :update, :delete then "writeUserFields"
          end
        return nil if key.nil?

        entry = fetch(class_name, client: client)
        return nil if entry.kind == :no_clp || entry.kind == :unresolvable

        fields = entry.clp[key] || entry.clp[key.to_sym]
        arr = Array(fields).map(&:to_s)
        arr.empty? ? nil : arr
      end

      # Evaluate the same mutually-exclusive CLP branches Parse Server uses
      # before applying a query to a particular row. Public, direct-user, and
      # role grants bypass pointer constraints. `requiresAuthentication` does
      # not: when pointer/user fields exist, a concrete authenticated `_User`
      # id must still match the row.
      #
      # Unlike {permits?}, schema lookup failures are reported as `:unknown`
      # rather than collapsed into a denial. Authorization-enforcing callers
      # can still fail closed by accepting only {AccessEvaluation#allowed?}.
      #
      # @param class_name [String] Parse class name.
      # @param op [Symbol] one of {OPERATIONS}.
      # @param claims [Enumerable<String>] public, user, and role claims.
      # @param authenticated [Boolean] whether authentication is established.
      # @param user_id [String, nil] concrete authenticated `_User.objectId`.
      # @param client [Parse::Client] application whose schema owns the CLP.
      # @return [AccessEvaluation]
      def evaluate_access(class_name, op, claims:, authenticated:, user_id: nil, client: nil)
        op = op.to_sym
        unless OPERATIONS.include?(op)
          return access_evaluation(:unknown, reason: :unsupported_operation)
        end

        entry = fetch(class_name, client: client)
        case entry.kind
        when :unresolvable
          return access_evaluation(:unknown, reason: :clp_unresolvable)
        when :no_clp
          return access_evaluation(:allowed, via: :public_default)
        end

        op_map = entry.clp[op.to_s] || entry.clp[op]
        # Parse Server treats an omitted operation map as public. Because that
        # is already a base grant, grouped pointer fields do not narrow it.
        return access_evaluation(:allowed, via: :public_default) if op_map.nil?
        unless op_map.is_a?(Hash)
          return access_evaluation(:unknown, reason: :malformed_clp)
        end

        claim_set = claims.is_a?(Set) ? claims : Set.new(Array(claims).map(&:to_s))
        role_claims = op_map.each_with_object([]) do |(principal, allowed), memo|
          key = principal.to_s
          memo << key if allowed == true && key.start_with?("role:")
        end.freeze

        if op_map["*"] == true || op_map[:"*"] == true
          return access_evaluation(:allowed, via: :public, role_claims: role_claims)
        end

        direct_claim = op_map.find do |principal, allowed|
          key = principal.to_s
          allowed == true && key != "*" && key != "requiresAuthentication" &&
            key != "pointerFields" && claim_set.include?(key)
        end
        if direct_claim
          return access_evaluation(
                   :allowed,
                   via: direct_claim.first.to_s.start_with?("role:") ? :role : :user,
                   role_claims: role_claims,
                 )
        end

        pointer_fields = pointer_fields_from(entry.clp, op)
        requires_authentication =
          op_map["requiresAuthentication"] == true || op_map[:requiresAuthentication] == true

        if pointer_fields.any?
          if authenticated == true && !user_id.to_s.empty?
            return access_evaluation(
                     :allowed,
                     via: :pointer,
                     pointer_fields: pointer_fields,
                     role_claims: role_claims,
                   )
          end

          status = authenticated == true ? :unknown : :denied
          reason = authenticated == true ? :concrete_user_required : :authentication_required
          return access_evaluation(status, role_claims: role_claims, reason: reason)
        end

        if requires_authentication && authenticated == true
          return access_evaluation(:allowed, via: :authenticated, role_claims: role_claims)
        end

        reason = requires_authentication ? :authentication_required : :clp_denied
        access_evaluation(:denied, role_claims: role_claims, reason: reason)
      end

      def protected_fields_for(class_name, permission_strings, client: nil)
        return EMPTY_SET if permission_strings.nil?

        entry = fetch(class_name, client: client)
        # No CLP / unresolvable: nothing to strip. For :unresolvable,
        # `permits?` already refused the query, so this branch is only
        # reached when callers ask for the protected-fields set directly
        # (e.g. for documentation or audit tooling).
        return EMPTY_SET if entry.kind == :no_clp || entry.kind == :unresolvable
        protected_map = entry.clp["protectedFields"] || entry.clp[:protectedFields]
        return EMPTY_SET if protected_map.nil? || protected_map.empty?

        strip = Set.new(Array(protected_map["*"] || protected_map[:"*"]).map(&:to_s))

        claim_set = permission_strings.is_a?(Set) ? permission_strings : permission_strings.to_set
        claim_set.each do |claim|
          next if claim == "*"
          override = protected_map[claim.to_s] || protected_map[claim.to_sym]
          next if override.nil?
          override_set = Set.new(Array(override).map(&:to_s))
          strip &= override_set
        end

        strip.freeze
      end

      def redact_protected_fields!(documents, strip_set)
        return documents if documents.nil? || documents.empty?
        return documents if strip_set.nil? || strip_set.empty?
        documents.each { |doc| walk_and_delete!(doc, strip_set) }
        documents
      end

      def filter_by_pointer_fields(documents, pointer_fields, user_id)
        return documents if pointer_fields.nil? || pointer_fields.empty?
        return [] if user_id.nil? || user_id.to_s.empty?
        documents.select { |doc| any_pointer_matches?(doc, pointer_fields, user_id.to_s) }
      end

      def invalidate!(class_name, client: nil)
        class_key = class_name.to_s
        @cache_mutex.synchronize do
          if client
            @cache.delete(cache_key(class_key, client))
          else
            @cache.delete_if { |(_scope, cached_class), _entry| cached_class == class_key }
          end
        end
        nil
      end

      def reset_cache!
        @cache_mutex.synchronize { @cache.clear }
        # Also drop the unresolvable-class warned-once registry so
        # tests that assert on `warn` emission for a class don't get
        # silenced by an earlier test's call.
        @warned_unresolvable_classes = Set.new
        nil
      end

      def cache_stats
        @cache_mutex.synchronize do
          {
            size: @cache.size,
            class_names: @cache.keys.map(&:last).uniq.sort,
            scopes: @cache.keys.map(&:first).uniq.sort,
          }
        end
      end

      # Test/operator-facing hook: pre-populate the cache with a known
      # CLP for `class_name`. An empty/nil `clp` is recorded as
      # `:no_clp` (matches the public-default semantics Parse Server
      # exposes when no CLP is configured); a non-empty `clp` is
      # recorded as `:cached_clp` (the standard happy path).
      def __cache_put(class_name, clp:, client: nil)
        normalized = clp || {}
        kind = normalized.empty? ? :no_clp : :cached_clp
        entry = CacheEntry.new(kind: kind, clp: normalized, fetched_at: monotonic_now)
        @cache_mutex.synchronize { @cache[cache_key(class_name, client)] = entry }
        entry
      end

      # Reset the unresolvable-class one-shot warning registry.
      # Test-only — prevents warned-once state from leaking across
      # the suite and silencing assertions on warning emission.
      # @!visibility private
      def reset_warning_state!
        @warned_unresolvable_classes = Set.new
      end

      private

      # Always returns a {CacheEntry}. On schema-fetch failure (network
      # error, unsuccessful response, raised exception, missing client)
      # the entry has `kind: :unresolvable` and is held for
      # {NEGATIVE_TTL} seconds to suppress request-rate retries against
      # an unhealthy schema endpoint without locking the application
      # into a permanently-stale denial.
      #
      # An empty `class_name` short-circuits to an `:unresolvable`
      # entry — `permits?` will refuse the call rather than dispatching
      # `schema("")` to the upstream client.
      def fetch(class_name, client: nil)
        class_key = class_name.to_s
        return unresolvable_entry if class_key.empty?

        resolved_client = client || schema_client || default_client_safe
        key = cache_key(class_key, resolved_client)

        cached = @cache_mutex.synchronize { @cache[key] }
        return cached if cached && !stale?(cached)

        entry = if resolved_client.nil?
            # No client configured (Parse.setup never called, etc.) —
            # treat as unresolvable so we fail closed instead of
            # crashing inside the begin block with NoMethodError.
            unresolvable_entry
          else
            begin
              response = resolved_client.schema(class_key)
              if response&.success?
                schema = response.result || {}
                clp = schema["classLevelPermissions"] || {}
                kind = clp.empty? ? :no_clp : :cached_clp
                CacheEntry.new(kind: kind, clp: clp, fetched_at: monotonic_now)
              else
                unresolvable_entry
              end
            rescue StandardError
              unresolvable_entry
            end
          end

        @cache_mutex.synchronize { @cache[key] = entry }
        entry
      end

      def unresolvable_entry
        CacheEntry.new(kind: :unresolvable, clp: nil, fetched_at: monotonic_now)
      end

      # `stale?` is TTL-domain-aware: positive entries use `@cache_ttl`
      # (defaults to {POSITIVE_TTL} = 3600s), unresolvable entries use
      # the much shorter {NEGATIVE_TTL} (5s) so the next attempt can
      # quickly recover from a transient failure. Both are evaluated in
      # the same monotonic clock domain to avoid NTP-related drift.
      def stale?(entry)
        return false if entry.fetched_at.nil?
        ttl = entry.kind == :unresolvable ? NEGATIVE_TTL : @cache_ttl
        return false if ttl.nil?
        return false if ttl.respond_to?(:infinite?) && ttl.infinite?
        (monotonic_now - entry.fetched_at) > ttl
      end

      # `default_client` raises if no client is configured; wrap it so
      # `fetch` can fall through to {unresolvable_entry} instead.
      def default_client_safe
        default_client
      rescue StandardError
        nil
      end

      # Emit a one-shot-per-class warning when `permits?` first denies
      # because the schema is unresolvable. Without this, a quiet
      # outage would silently break every scoped query; with it,
      # operators see a single banner per class and can investigate.
      def warn_unresolvable_once!(class_name)
        @warned_unresolvable_classes ||= Set.new
        key = class_name.to_s
        return if @warned_unresolvable_classes.include?(key)
        @warned_unresolvable_classes << key
        warn "[Parse::CLPScope:SECURITY] schema for '#{key}' is " \
             "unresolvable (network error, 5xx, missing client, or " \
             "raised exception); FAILING CLOSED on all non-master " \
             "queries for this class for the next #{NEGATIVE_TTL}s. " \
             "Investigate the schema endpoint or pre-populate the " \
             "cache via Parse::CLPScope.__cache_put. Subsequent " \
             "denials for the same class will not re-warn."
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def default_client
        Parse::Client.client(:default)
      end

      # Cache CLP by Parse application, not merely by class name. Two clients
      # can legitimately point at different applications that both contain a
      # `Document` class with unrelated permissions.
      def cache_key(class_name, client = nil)
        resolved_client = client || schema_client || default_client_safe
        scope = if resolved_client.nil?
            "client:none"
          elsif resolved_client.respond_to?(:server_url) &&
                resolved_client.respond_to?(:application_id)
            "app:#{resolved_client.server_url}\u0000#{resolved_client.application_id}"
          else
            "client:#{resolved_client.object_id}"
          end
        [scope.freeze, class_name.to_s.freeze].freeze
      end

      def access_evaluation(status, via: nil, pointer_fields: EMPTY_SET,
                                    role_claims: EMPTY_SET, reason: nil)
        AccessEvaluation.new(
          status: status,
          via: via,
          pointer_fields: Array(pointer_fields).map(&:to_s).uniq.freeze,
          role_claims: Array(role_claims).map(&:to_s).uniq.freeze,
          reason: reason,
        ).freeze
      end

      def pointer_fields_from(clp, op)
        op_map = clp[op.to_s] || clp[op]
        per_operation = if op_map.is_a?(Hash)
            op_map["pointerFields"] || op_map[:pointerFields]
          end
        grouped_key = case op.to_sym
          when :find, :get, :count then "readUserFields"
          when :create, :update, :delete then "writeUserFields"
          end
        grouped = grouped_key && (clp[grouped_key] || clp[grouped_key.to_sym])
        (Array(per_operation) + Array(grouped)).map(&:to_s).reject(&:empty?).uniq.freeze
      end

      def user_identity?(entry)
        s = entry.to_s
        s != "*" && !s.start_with?("role:")
      end

      def walk_and_delete!(node, strip_set)
        case node
        when Hash
          strip_set.each { |k| node.delete(k) }
          node.each_value { |v| walk_and_delete!(v, strip_set) }
        when Array
          node.each { |v| walk_and_delete!(v, strip_set) }
        end
        node
      end

      def any_pointer_matches?(doc, pointer_fields, user_id)
        return false unless doc.is_a?(Hash)
        pointer_fields.any? do |field|
          val = doc[field] || doc[field.to_sym]
          if val.is_a?(Hash)
            return true if user_pointer_matches?(val, user_id)
          elsif val.is_a?(Array)
            return true if val.any? { |v| user_pointer_matches?(v, user_id) }
          end
          mongo_val = doc["_p_#{field}"] || doc[:"_p_#{field}"]
          if mongo_val.is_a?(String) && mongo_val.include?("$")
            klass, oid = mongo_val.split("$", 2)
            return true if klass == Parse::Model::CLASS_USER && oid == user_id
          end
          false
        end
      end

      def user_pointer_matches?(value, user_id)
        return false unless value.is_a?(Hash)
        type = value["__type"] || value[:__type]
        klass = value["className"] || value[:className]
        oid = value["objectId"] || value[:objectId]
        type == Parse::Model::TYPE_POINTER && klass == Parse::Model::CLASS_USER && oid == user_id
      end
    end

    @cache_ttl = POSITIVE_TTL
    @warned_unresolvable_classes = Set.new
  end
end
