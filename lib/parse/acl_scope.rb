# encoding: UTF-8
# frozen_string_literal: true

require "set"
require_relative "model/acl"
require_relative "clp_scope"

module Parse
  # Shared identity-resolution helper for query paths that simulate
  # Parse Server's row-level ACL enforcement client-side because they
  # bypass Parse Server entirely.
  #
  # The mongo-direct entry points (`Parse::MongoDB.aggregate`,
  # `.geo_near`, `Parse::Query#results_direct`, `#count_direct`) talk
  # to MongoDB through a connection authenticated by the URI configured
  # in `Parse::MongoDB.configure`. From MongoDB's perspective that
  # connection has full access — `_rperm` is just another field, not
  # a security boundary. The SDK is therefore the *only* layer
  # enforcing the row-level ACL that Parse Server would apply on a
  # REST find. {ACLScope} produces the inputs that injection needs:
  # the `_rperm` permission-string set for a session (`["*",
  # userObjectId, "role:Admin", ...]`), so callers can prepend a
  # `$match` stage built via {Parse::ACL.read_predicate}.
  #
  # Atlas Search uses the same pattern through
  # `Parse::AtlasSearch::Session`; this module reuses that resolver
  # (token → user_id → role expansion + caching) and adds a
  # path-agnostic kwarg-popping front door so every mongo-direct entry
  # point can speak the same auth vocabulary.
  module ACLScope
    # Raised when a query path is configured to require an explicit
    # session-token or master mode and the caller supplied neither.
    # Mirror of `Parse::AtlasSearch::ACLRequired`; both are accepted
    # at SDK boundaries with the path's own name.
    class ACLRequired < StandardError; end

    # Outcome of resolving a single mongo-direct call's auth kwargs.
    # @!attribute mode
    #   @return [Symbol] one of `:session`, `:master`, `:public`.
    #     `:session` means the caller passed a valid `session_token:`;
    #     `:master` means the caller passed `master: true`; `:public`
    #     means neither was supplied and the path's `require_session_token`
    #     toggle is off, so the SDK falls through to public-only ACL
    #     semantics.
    # @!attribute permission_strings
    #   @return [Array<String>, nil] the `_rperm` allow-set ready to
    #     hand to {Parse::ACL.read_predicate}. `nil` for `:master` —
    #     no injection runs on the master path.
    # @!attribute user_id
    #   @return [String, nil] the resolved user_id, or `nil` for
    #     `:master` and `:public`.
    # @!attribute session
    #   @return [Parse::AtlasSearch::Session::Resolved, nil] the
    #     underlying resolved-session struct (carries role-name set),
    #     `nil` for `:master`.
    # @!attribute strict_role
    #   @return [Boolean] when `true`, downstream predicate construction
    #     (see {.match_stage_for} and {.rewrite_pipeline}) suppresses the
    #     implicit `"*"` (public) grant. Only meaningful for role-scoped
    #     resolutions where the caller wants to see ONLY rows whose
    #     `_rperm` explicitly includes one of the resolved role names,
    #     not every public-readable row in the collection. Defaults to
    #     `false` for backwards compatibility. Note: even with
    #     `strict_role: true`, rows with NO `_rperm` field still pass
    #     (Parse-Server treats absent `_rperm` as public-default); the
    #     knob only suppresses the `"*"` subscription in the `$in` set.
    Resolution = Struct.new(:mode, :permission_strings, :user_id, :session, :strict_role, keyword_init: true) do
      def master?; mode == :master; end
      def session?; mode == :session; end
      def public?; mode == :public; end
      def strict_role?; strict_role == true; end
    end

    class << self
      # When `true`, every call to {.resolve!} that did NOT receive
      # `session_token:` or `master: true` raises {ACLRequired} instead
      # of falling through to the public-only banner-and-continue path.
      # Mirror of `Parse::AtlasSearch.require_session_token`. Default
      # is `false` to preserve backwards compatibility with mongo-direct
      # callsites that pre-date the session-token kwarg.
      # @return [Boolean]
      attr_accessor :require_session_token

      # Resolve the auth-related kwargs (`:session_token`, `:master`)
      # off `options` and return a {Resolution} describing which mode
      # the call will run in. **Mutates `options`** by `delete`-ing
      # the auth kwargs so the caller can forward the remaining hash
      # to its underlying transport without leaking them.
      #
      # @param options [Hash] kwargs Hash the caller will forward;
      #   `:session_token` and `:master` are removed in place.
      # @param method_name [Symbol] for error messages — typically the
      #   public entry-point name (`:aggregate`, `:geo_near`,
      #   `:results_direct`).
      # @return [Resolution]
      # @raise [ArgumentError] when both `session_token:` and
      #   `master: true` are supplied — they are mutually exclusive.
      # @raise [ACLRequired] when neither is supplied and
      #   {.require_session_token} is `true`.
      def resolve!(options, method_name:)
        session_token = options.delete(:session_token)
        master = options.delete(:master)
        acl_user = options.delete(:acl_user)
        acl_role = options.delete(:acl_role)
        # `strict_role:` is only meaningful for the `acl_role:` branch
        # below — it tells `resolve_for_role` to suppress the implicit
        # `"*"` grant in the resulting permission set. We `delete` it
        # unconditionally to avoid forwarding it to the underlying
        # transport, and silently ignore on the non-role paths
        # (session-token / acl_user / master / public) where it has no
        # meaning. Defaults to `false` so the auto-public grant remains
        # the legacy behavior.
        strict_role = options.delete(:strict_role) == true

        provided = [session_token, master == true ? master : nil, acl_user, acl_role].compact
        if provided.length > 1
          raise ArgumentError,
                "Parse::ACLScope.#{method_name}: cannot pass more than one of " \
                "session_token:, master: true, acl_user:, or acl_role:. Pick one."
        end

        if acl_user
          # Pre-resolved User-pointer path used by
          # Parse::Query#scope_to_user. Mirrors the session-token path
          # but skips the /users/me round-trip; role expansion still
          # runs via Parse::Role.all_for_user.
          return resolve_for_user(acl_user)
        end

        if acl_role
          # Role-only path used by Parse::Query#scope_to_role.
          # Simulates "what would a user holding this role see"
          # without minting a session token or knowing a specific
          # user — useful for service-account-style queries (cron
          # jobs, internal reporting, agentic tooling) where the
          # caller wants role-grade access without a per-user
          # identity. Parent-role inheritance applies (passing
          # "scope:admin" includes any role "scope:admin" inherits
          # from).
          return resolve_for_role(acl_role, strict_role: strict_role)
        end

        if session_token
          require_atlas_session!
          resolved = Parse::AtlasSearch::Session.resolve(session_token)
          return Resolution.new(
            mode: :session,
            permission_strings: resolved.permission_strings,
            user_id: resolved.user_id,
            session: resolved,
          )
        end

        if master == true
          return Resolution.new(mode: :master, permission_strings: nil, user_id: nil, session: nil)
        end

        if @require_session_token == true
          raise ACLRequired,
                "Parse::#{method_name} requires session_token: or master: true. " \
                "Mongo-direct queries bypass Parse Server's ACL enforcement, so " \
                "the SDK refuses to run them without an explicit identity or an " \
                "explicit master-mode opt-in. Flip Parse::ACLScope.require_session_token " \
                "= false to allow public-only fallback."
        end

        warn_no_acl_context_once!(method_name)
        require_atlas_session!
        anonymous = Parse::AtlasSearch::Session::Resolved.new(nil, Set.new)
        Resolution.new(
          mode: :public,
          permission_strings: anonymous.permission_strings,
          user_id: nil,
          session: anonymous,
        )
      end

      # Compile the `_rperm` `$match` stage to prepend to a mongo-direct
      # pipeline. Returns `nil` on the master path (no injection), for
      # `nil` resolutions (defensive — should never happen in normal
      # use), and for legacy (non-strict-role) resolutions with an
      # empty/nil perm set. Strict-role resolutions FAIL CLOSED: even
      # an empty perm set still emits a $match (`$in: []` plus the
      # `$exists: false` branch) so the caller cannot accidentally see
      # every row. The shape comes straight from
      # {Parse::ACL.read_predicate} and matches what
      # {Parse::AtlasSearch} injects on its `$search` pipelines.
      #
      # @param resolution [Resolution, nil]
      # @return [Hash, nil] a `$match` pipeline stage, or `nil`.
      def match_stage_for(resolution)
        return nil if resolution.nil? || resolution.master?
        perms = resolution.permission_strings
        strict = resolution.respond_to?(:strict_role?) && resolution.strict_role?
        # Legacy (non-strict) behavior: an empty/nil perm set means
        # nothing to inject, fall through with no $match. Strict-role
        # mode FAIL-CLOSED: even an empty resolved-role set must still
        # produce a predicate so the caller doesn't accidentally see
        # every row. With `include_public: false` and empty perms, the
        # predicate becomes `{$or: [{_rperm: {$in: []}}, {_rperm:
        # {$exists: false}}]}` — only no-_rperm rows pass, which is
        # the conservative interpretation.
        return nil if !strict && (perms.nil? || perms.empty?)
        perms = [] if perms.nil?
        # `strict_role?` (defaults to `false`) suppresses the implicit
        # `"*"` append that Parse::ACL.read_predicate normally performs.
        # Used by role-scoped resolutions that opted into strict mode
        # so a service-account-style query for, say, `acl_role:
        # "scope:reporting"` does NOT see every public-readable row in
        # the queried class.
        { "$match" => Parse::ACL.read_predicate(perms, include_public: !strict) }
      end

      # Walk an aggregation pipeline and rewrite every join-style stage
      # so its sub-results are filtered against the resolution's
      # `_rperm` allow-set. Without this rewriting, a top-level
      # `$match` injection only filters the queried collection's rows;
      # any rows pulled in via `$lookup`, `$unionWith`, or
      # `$graphLookup` are visible to the requesting session regardless
      # of their stored ACL — a silent SDK-side ACL bypass on
      # included/joined data.
      #
      # The rewriter handles:
      #
      #   * **`$lookup`** — both simple (`from`/`localField`/`foreignField`)
      #     and pipeline forms. Simple form is upgraded to the
      #     combined form (Mongo 5.0+) by appending an `_rperm` match
      #     to its `pipeline`. Pipeline form prepends the same stage.
      #   * **`$unionWith`** — the unioned collection's rows are
      #     filtered by prepending an `_rperm` match to its `pipeline`
      #     (constructing one if absent).
      #   * **`$graphLookup`** — appends an `_rperm` match by way of
      #     a `restrictSearchWithMatch` clause (MongoDB's documented
      #     mechanism for filtering traversed rows).
      #   * **`$facet`** — recursive: each facet branch is itself a
      #     pipeline; rewrite every branch independently.
      #
      # Returns a NEW Array; the input pipeline is not mutated.
      # Master and nil-resolution pass through unchanged. Legacy
      # (non-strict-role) empty-perms resolutions also pass through.
      # Strict-role empty-perms FAIL CLOSED (same contract as
      # {.match_stage_for}): the ACL match is still injected so joined
      # collections are filtered, not exposed.
      #
      # @param pipeline [Array<Hash>] the aggregation pipeline.
      # @param resolution [Resolution, nil]
      # @return [Array<Hash>] the rewritten pipeline.
      def rewrite_pipeline(pipeline, resolution)
        return pipeline if pipeline.nil? || pipeline.empty?
        return pipeline if resolution.nil? || resolution.master?
        perms = resolution.permission_strings
        strict = resolution.respond_to?(:strict_role?) && resolution.strict_role?
        # Same fail-closed contract as {.match_stage_for}: legacy mode
        # passes through unmodified when perms are empty, strict-role
        # mode still emits the conservative predicate.
        return pipeline if !strict && (perms.nil? || perms.empty?)
        perms = [] if perms.nil?

        # Mirror the `strict_role?` handling in {.match_stage_for} so
        # the predicate prepended to $lookup / $unionWith / $graphLookup
        # / $facet sub-pipelines also suppresses the implicit `"*"`
        # grant for strict-role resolutions.
        acl_match = { "$match" => Parse::ACL.read_predicate(perms, include_public: !strict) }
        # Pass `perms` alongside `acl_match` so every join-style stage
        # rewriter can fire {Parse::CLPScope.permits?} on its joined
        # target class. Without this gate, a scoped session that lacked
        # `find` on `_User` could still surface `_User` rows by reading
        # them through `$lookup.from: "_User"` inside an aggregation
        # rooted on a public class. The agent dispatcher already had
        # this gate; the rewriter is the shared SDK-level layer so the
        # mongo-direct path enforces it independent of whether an agent
        # made the call.
        pipeline.map { |stage| rewrite_stage(stage, acl_match, perms) }
      end

      # Walk the result documents and redact every embedded sub-document
      # whose stored `_rperm` does not include any of the resolution's
      # permission strings. This is the second enforcement layer — the
      # pipeline rewriter catches what it can reach, this catches what
      # leaked through (raw `:object` columns embedding pointer-shaped
      # hashes, `$lookup` stages the rewriter couldn't rewrite, etc.).
      #
      # Redaction is in-place tree mutation. Each embedded sub-document
      # carrying `_rperm` is either kept as-is, replaced with `nil`
      # (when value is a scalar field), or removed from its containing
      # Array (when value is an array element). Sub-documents without
      # `_rperm` are treated as public-readable and pass through. The
      # top-level documents are NOT redacted by this walk — the
      # top-level `$match` injection already filtered those.
      #
      # @param documents [Array<Hash>] the result rows.
      # @param resolution [Resolution, nil]
      # @return [Array<Hash>] the same Array, with embedded sub-docs
      #   redacted in place.
      def redact_results!(documents, resolution)
        return documents if documents.nil? || documents.empty?
        return documents if resolution.nil? || resolution.master?
        perms = resolution.permission_strings
        return documents if perms.nil? || perms.empty?

        perms_set = perms.is_a?(Set) ? perms : perms.to_set
        documents.each { |doc| redact_subdocs!(doc, perms_set, top: true) }
        documents
      end

      private

      # Apply the rewriter to a single pipeline stage. Operator-aware:
      # only join-style stages are touched. Everything else passes
      # through verbatim. `perms` is threaded down so the cross-class
      # CLP gate (Wave-3 TRACK-ACL-3) can challenge each joined class.
      def rewrite_stage(stage, acl_match, perms)
        return stage unless stage.is_a?(Hash)
        op_key, op_val = stage.first
        case op_key.to_s
        when "$lookup"
          { op_key => rewrite_lookup(op_val, acl_match, perms) }
        when "$unionWith"
          { op_key => rewrite_union_with(op_val, acl_match, perms) }
        when "$graphLookup"
          { op_key => rewrite_graph_lookup(op_val, acl_match, perms) }
        when "$facet"
          { op_key => rewrite_facet(op_val, acl_match, perms) }
        else
          stage
        end
      end

      # Cross-class CLP gate. Raises {Parse::CLPScope::Denied} when
      # the current scope cannot `find` rows of `target_class`. Master
      # mode is already short-circuited in {.rewrite_pipeline} (it
      # never reaches the rewriters), so reaching this helper means
      # `perms` is a real claim set. Centralized here to avoid drift
      # between the three join-style rewriters.
      def assert_join_target_permitted!(target, perms)
        return if target.nil?
        target_str = target.to_s
        return if target_str.empty?
        # RT-7 / NEW-4: hard internal-collection floor FIRST, independent of
        # CLP. This must run on EVERY join target on the direct
        # Parse::MongoDB.aggregate path. LookupRewriter.auto_rewrite (the other
        # caller of assert_collection_allowed!) is skipped when rewrite_lookups
        # is off or the root class can't be resolved, so relying on it alone
        # leaves a gap: an internal collection (`_SCHEMA`/`_Hooks`/`_Audit`/
        # `_GlobalConfig`/...) whose CLP fetch returns :no_clp would pass the
        # permits? check below. The floor refuses those outright while still
        # admitting the SDK data classes (`_User`/`_Role`/`_Installation`/
        # `_Session`), which then face the per-scope CLP `find` gate.
        Parse::PipelineSecurity.assert_collection_allowed!(target_str)
        return if Parse::CLPScope.permits?(target_str, :find, perms)
        raise Parse::CLPScope::Denied.new(
          target_str, :find,
          "Joined class '#{target_str}' refuses :find for current scope.",
        )
      end

      def rewrite_lookup(spec, acl_match, perms)
        # String shorthand `{$lookup: "Collection"}` is not a real
        # Mongo form; defensively leave it alone.
        return spec unless spec.is_a?(Hash)
        # Gate FIRST so a CLP-denied join is refused before the
        # rewriter spends work rebuilding the sub-pipeline. `from`
        # accepts string or symbol — normalize via the gate.
        target = spec["from"] || spec[:from]
        assert_join_target_permitted!(target, perms)
        spec = spec.dup
        existing_pipeline = spec["pipeline"] || spec[:pipeline] || []
        # Walk the sub-pipeline recursively so nested $lookup /
        # $unionWith / $graphLookup inside the join's pipeline are
        # themselves CLP-gated and ACL-rewritten against the SAME
        # `perms` set. (Mongo evaluates the sub-pipeline in the
        # joined collection's context, but the requesting session is
        # unchanged; permissions don't elevate by traversing a join.)
        rewritten_inner = existing_pipeline.map { |s| rewrite_stage(s, acl_match, perms) }
        new_pipeline = [acl_match] + rewritten_inner
        spec["pipeline"] = new_pipeline
        spec.delete(:pipeline) # symbol form was promoted to string form
        spec
      end

      def rewrite_union_with(spec, acl_match, perms)
        # `$unionWith` accepts either a String (collection name only)
        # or a Hash `{coll:, pipeline:}`. Post the target from
        # either shape so the CLP gate fires before the String→Hash
        # upgrade — denying access to the joined class BEFORE we go
        # to the trouble of building out an upgraded sub-pipeline.
        target =
          if spec.is_a?(String)
            spec
          elsif spec.is_a?(Hash)
            spec["coll"] || spec[:coll]
          end
        assert_join_target_permitted!(target, perms)

        if spec.is_a?(String)
          return { "coll" => spec, "pipeline" => [acl_match] }
        end
        return spec unless spec.is_a?(Hash)
        spec = spec.dup
        existing_pipeline = spec["pipeline"] || spec[:pipeline] || []
        rewritten_inner = existing_pipeline.map { |s| rewrite_stage(s, acl_match, perms) }
        spec["pipeline"] = [acl_match] + rewritten_inner
        spec.delete(:pipeline)
        spec
      end

      def rewrite_graph_lookup(spec, acl_match, perms)
        return spec unless spec.is_a?(Hash)
        # Same CLP gate, same reasoning — $graphLookup reads from a
        # different collection in the same session's authority.
        target = spec["from"] || spec[:from]
        assert_join_target_permitted!(target, perms)
        spec = spec.dup
        # `$graphLookup` doesn't accept a sub-pipeline. Its filter hook
        # is `restrictSearchWithMatch`, which is a $match-predicate (no
        # `$match` wrapper). Combine with any existing restriction via
        # `$and`.
        acl_predicate = acl_match["$match"]
        existing = spec["restrictSearchWithMatch"] || spec[:restrictSearchWithMatch]
        combined =
          if existing.nil? || (existing.respond_to?(:empty?) && existing.empty?)
            acl_predicate
          else
            { "$and" => [existing, acl_predicate] }
          end
        spec["restrictSearchWithMatch"] = combined
        spec.delete(:restrictSearchWithMatch)
        spec
      end

      def rewrite_facet(spec, acl_match, perms)
        return spec unless spec.is_a?(Hash)
        spec.each_with_object({}) do |(branch_name, branch_pipeline), out|
          out[branch_name] =
            if branch_pipeline.is_a?(Array)
              # Recurse with the same perms — facet branches are
              # evaluated in the requesting session's authority, not
              # elevated.
              branch_pipeline.map { |s| rewrite_stage(s, acl_match, perms) }
            else
              branch_pipeline
            end
        end
      end

      # Maximum recursion depth for {.redact_subdocs!}. Bounds the
      # walker so a self-referential (cyclic) result-row Hash — which
      # MongoDB doesn't normally produce, but which a malicious or
      # buggy upstream replaying an unsanitized payload could
      # construct — cannot trigger a SystemStackError. The default of
      # 32 comfortably covers realistic Parse Server result shapes
      # (which rarely exceed ~6 levels of nesting via $lookup +
      # embedded pointer hashes) while leaving enough headroom that
      # legitimate deeply-nested aggregation outputs aren't truncated.
      DEFAULT_REDACT_MAX_DEPTH = 32

      # Walk one document, redacting embedded sub-documents that don't
      # satisfy the perms set. The `top:` flag is `true` on the entry
      # call (the result row itself, which the top-level $match
      # already filtered) so we descend into its fields but don't
      # redact the row itself.
      #
      # `depth:` decrements on each recursion; on exhaustion the
      # subtree is treated as "redact" — the conservative choice (drop
      # the offending branch rather than recurse-forever). Raising
      # would abort the entire result set on one bad row, which is
      # noisier than the redactor's protocol elsewhere.
      def redact_subdocs!(node, perms_set, top: false, depth: DEFAULT_REDACT_MAX_DEPTH)
        # Depth exhausted: treat the subtree as ACL-failing and let
        # the caller drop it. Conservative-by-construction; the
        # alternative (return `nil` and silently pass the subtree
        # through) would let a deeply-nested or cyclic payload bypass
        # both ACL enforcement AND the recursion bound.
        return :__redact if depth <= 0

        case node
        when Hash
          if !top && node.key?("_rperm") && !rperm_matches?(node["_rperm"], perms_set)
            # Caller (an Array#map!-style step or scalar field clear)
            # handles the removal; signal back with :__redact.
            return :__redact
          end
          node.each do |key, value|
            next if key == "_rperm" || key == "_wperm" # leave ACL fields intact
            outcome = redact_subdocs!(value, perms_set, depth: depth - 1)
            if outcome == :__redact
              node[key] = nil
            elsif outcome.is_a?(Array)
              node[key] = outcome
            end
          end
          nil
        when Array
          filtered = node.each_with_object([]) do |element, acc|
            outcome = redact_subdocs!(element, perms_set, depth: depth - 1)
            if outcome == :__redact
              # drop ACL-failing element
            elsif outcome.is_a?(Array)
              acc << outcome
            else
              acc << element
            end
          end
          filtered
        else
          nil
        end
      end

      # Decide whether an embedded sub-document's stored `_rperm` field
      # satisfies the current scope's permission set.
      #
      # Convention (matches Parse Server's behavior on top-level rows):
      # - `nil`/absent `_rperm` = public-readable. Permit.
      # - Array `_rperm` = standard storage form. Intersect with the
      #   permission set; permit on any match.
      # - Anything else (String, Hash, Integer, ...) = malformed.
      #   FAIL CLOSED: we don't know how to interpret the field, so
      #   refuse rather than silently allow. A malformed `_rperm`
      #   typically indicates upstream data corruption, a schema drift,
      #   or — worst case — an attacker who managed to overwrite the
      #   field with a value that bypasses naive type-tolerant matchers.
      #   The previous behavior treated non-Array as nil (public),
      #   which silently surrendered the redaction guarantee. We warn
      #   once per `_rperm` value-class seen so operators can spot the
      #   corruption rather than just discovering rows disappear.
      def rperm_matches?(stored_rperm, perms_set)
        return true if stored_rperm.nil?
        unless stored_rperm.is_a?(Array)
          warn_malformed_rperm_once!(stored_rperm.class)
          return false
        end
        stored_rperm.any? { |entry| perms_set.include?(entry) }
      end

      # Emit a one-shot-per-process `warn` the first time a given
      # non-Array `_rperm` value-class is observed. Keyed on the value
      # class (String / Hash / Integer / etc.) so each distinct
      # corruption shape surfaces at least once but doesn't spam the
      # logs at request rate. Stored on the singleton (mirrors the
      # `@no_acl_warned` pattern); avoids the `@@class_var` cross-
      # inheritance leakage Ruby warns about.
      def warn_malformed_rperm_once!(value_class)
        @warned_malformed_rperm_classes ||= Set.new
        return if @warned_malformed_rperm_classes.include?(value_class)
        @warned_malformed_rperm_classes << value_class
        warn "[Parse::ACLScope:SECURITY] Encountered malformed _rperm of " \
             "type #{value_class}; the SDK fails CLOSED on non-Array " \
             "_rperm to avoid silently surrendering row-level " \
             "redaction. This usually indicates upstream data " \
             "corruption or schema drift — investigate the document(s) " \
             "with the malformed field. Subsequent occurrences of the " \
             "same value-class will not re-warn."
      end

      public

      # Build a {Resolution} directly from a pre-resolved User pointer
      # (or User instance). Role-expansion runs through
      # {Parse::Role.all_for_user} — same path the
      # session-token resolver uses — but the token-to-user step is
      # skipped because the caller already has the user. Used by
      # {Parse::Query#scope_to_user} and any external code that wants
      # to feed a User directly into the ACL simulation without going
      # through a session token.
      # @param user [Parse::User, Parse::Pointer]
      # @return [Resolution]
      def resolve_for_user(user)
        # SECURITY: className must be `_User` (or the legacy `User`
        # alias). Without this check, any duck-typed object exposing
        # `#id` — including a `Parse::Pointer` to a foreign class
        # such as `Order` or `AuditLog` — would be accepted, and its
        # raw `user.id` would land verbatim in `perms` below. Parse
        # objectIds are 10-char alphanumerics with no class
        # segregation, so a foreign-class pointer whose objectId
        # happened to equal a real `_User` objectId would simulate
        # that user for ACL purposes (id-collision impersonation).
        # The two acceptable shapes are a `Parse::User` instance or
        # a `Parse::Pointer` whose `parse_class` is `_User`/`User`.
        valid_user_class =
          user.is_a?(Parse::User) ||
          (user.is_a?(Parse::Pointer) &&
           [Parse::Model::CLASS_USER, "User"].include?(user.parse_class))
        unless valid_user_class
          got_class = user.respond_to?(:parse_class) ? user.parse_class.inspect : "<no className>"
          raise ArgumentError,
                "Parse::ACLScope.resolve_for_user requires a Parse::User or a " \
                "Pointer with className '_User'; got #{user.class}/#{got_class}. " \
                "Refusing - non-_User pointer ids would land in the ACL " \
                "permission_strings and grant cross-class id-collision " \
                "impersonation."
        end
        unless user.respond_to?(:id) && user.id.is_a?(String) && !user.id.empty?
          raise ArgumentError,
                "Parse::ACLScope.resolve_for_user expects a Parse::User or " \
                "User Pointer with a non-empty objectId."
        end

        role_names =
          begin
            require_relative "model/classes/role"
            Parse::Role.all_for_user(user, max_depth: 10)
          rescue StandardError
            Set.new
          end

        perms = ["*", user.id]
        role_names.each { |name| perms << "role:#{name}" if name && !name.empty? }
        perms.uniq!

        require_atlas_session!
        Resolution.new(
          mode: :session,
          permission_strings: perms,
          user_id: user.id,
          session: Parse::AtlasSearch::Session::Resolved.new(user.id, role_names),
        )
      end

      # Build a {Resolution} for a role-only scope: no user_id, just
      # the role's name plus every role it transitively inherits from
      # (parent-role chain). Useful for service-account-style queries
      # ("see as if a user with the `admin` role were asking") without
      # minting a session token or knowing a specific user.
      #
      # The inheritance walk uses {Parse::Role#all_parent_role_names},
      # which is the same upward traversal {Parse::Role.all_for_user}
      # uses to compose user permissions — so the perms set is
      # consistent with what a real user holding the role would see.
      #
      # Accepts either a {Parse::Role} instance or a role name String
      # (with or without the `"role:"` prefix). A String input
      # triggers a `_Role.find_by(name:)` lookup and raises
      # ArgumentError when the role doesn't exist.
      #
      # @param role [Parse::Role, String]
      # @param strict_role [Boolean] when `true`, the returned
      #   {Resolution} signals downstream predicate construction to
      #   suppress the implicit `"*"` grant. The resolved permission
      #   set drops `"*"` (so a role-scoped query does NOT see every
      #   public-readable row in the queried class). Defaults to
      #   `false` for backwards compatibility — legacy callers that
      #   used `acl_role:` continue to see public rows as before. Note:
      #   even in strict mode, rows with no `_rperm` field continue to
      #   match because Parse Server treats them as public-default; see
      #   {.match_stage_for} for the precise predicate shape.
      # @return [Resolution]
      # @raise [ArgumentError] when the role cannot be resolved.
      def resolve_for_role(role, strict_role: false)
        require_relative "model/classes/role"
        role_obj =
          case role
          when Parse::Role then role
          when String, Symbol
            name = role.to_s.sub(/\Arole:/, "")
            raise ArgumentError, "[Parse::ACLScope] role name must be non-empty." if name.empty?
            found = Parse::Role.first(name: name)
            raise ArgumentError, "[Parse::ACLScope] no _Role found with name #{name.inspect}." if found.nil?
            found
          else
            raise ArgumentError, "[Parse::ACLScope] resolve_for_role expects Parse::Role or String."
          end

        names =
          begin
            role_obj.all_parent_role_names(max_depth: 10)
          rescue StandardError
            Set.new([role_obj.name].compact)
          end

        # In strict mode the permission set omits the implicit `"*"`
        # so the resulting predicate only matches rows whose `_rperm`
        # contains one of the resolved role names (plus the standard
        # `_rperm: {$exists: false}` branch — see Resolution#strict_role
        # docs). In legacy mode `"*"` is included so role-scoped
        # callers also see every public-readable row.
        perms = strict_role ? [] : ["*"]
        names.each { |n| perms << "role:#{n}" if n && !n.empty? }
        perms.uniq!

        require_atlas_session!
        Resolution.new(
          mode: :session,
          permission_strings: perms,
          user_id: nil,
          session: Parse::AtlasSearch::Session::Resolved.new(nil, names),
          strict_role: strict_role,
        )
      end

      # Reset the "no ACL context" banner state AND the malformed
      # `_rperm` one-shot registry. Test-only — without this hook the
      # warned-once registries would persist across the suite and
      # warning-presence assertions in later tests would flake.
      # @!visibility private
      def reset_warning_state!
        @no_acl_warned = false
        @warned_malformed_rperm_classes = Set.new
      end

      private

      # Emit the once-per-process security banner the first time a
      # mongo-direct path runs without `session_token:` and without
      # `master: true`. Mirrors {Parse::AtlasSearch}'s warned-once
      # pattern.
      def warn_no_acl_context_once!(method_name)
        return if @no_acl_warned == true
        @no_acl_warned = true
        warn "[Parse::ACLScope:SECURITY] #{method_name} called without " \
             "session_token: or master: true. Mongo-direct paths bypass " \
             "Parse Server's ACL enforcement; the pipeline will enforce " \
             "public-only semantics (only documents readable by `\"*\"` " \
             "or with no _rperm). Pass session_token: for per-user " \
             "filtering, or master: true to confirm the master-mode " \
             "bypass is intentional. Set Parse::ACLScope.require_session_token " \
             "= true to make this misuse an error instead of a warning."
      end

      # Lazily load the Atlas Search session resolver — it carries the
      # token-cache / role-cache plumbing this module reuses. Loads
      # `atlas_search.rb` (not just `atlas_search/session.rb`) so the
      # parent module's session_cache / role_cache are initialized.
      # Loading session.rb in isolation leaves Parse::AtlasSearch
      # without its memory caches and Session.lookup_user_id crashes
      # with NoMethodError. Keeping the require lazy means apps that
      # never call an auth-resolving path don't pay the load cost.
      def require_atlas_session!
        return if defined?(Parse::AtlasSearch) && Parse::AtlasSearch.respond_to?(:session_cache) &&
                  !Parse::AtlasSearch.session_cache.nil?
        require_relative "atlas_search"
      end
    end

    @require_session_token = false
    @no_acl_warned = false
    @warned_malformed_rperm_classes = Set.new
  end
end
