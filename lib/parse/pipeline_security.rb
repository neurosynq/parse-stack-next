# encoding: UTF-8
# frozen_string_literal: true

module Parse
  # Canonical security validator for MongoDB aggregation pipelines and
  # filter hashes that the SDK forwards to the driver or to Parse Server.
  #
  # Previously the codebase had three different validators with three
  # different rule sets:
  #
  # - `Parse::Agent::PipelineValidator` — strict allowlist for the Agent
  #   (read-only paths only)
  # - `Parse::Query#validate_pipeline!` — outer-stage-only denylist
  # - `Parse::MongoDB.assert_no_denied_operators!` — recursive denylist of
  #   server-side JS operators
  #
  # `Parse::AtlasSearch.convert_filter_for_mongodb` was a complete
  # passthrough that bypassed all three. A user-supplied filter containing
  # `$where`/`$expr`/`$function`/`$regex` was injected straight into the
  # pipeline `$match` stage, bypassing every existing constraint guard.
  #
  # This module consolidates the rules. Every entry point that forwards a
  # caller-supplied pipeline or filter to MongoDB now routes through one
  # of the two public methods here:
  #
  # - {validate_pipeline!} — strict mode (allowlist + size/depth caps).
  #   Used by `Parse::Agent` and by `Parse::Query#aggregate` for
  #   user-facing aggregation entry points.
  #
  # - {validate_filter!} — permissive mode (recursive denylist only).
  #   Used by `Parse::MongoDB.find/aggregate` and Atlas Search filter
  #   passthrough where the pipeline is constructed by SDK code but a
  #   user-controlled filter hash is interpolated. Refuses
  #   `$where`/`$function`/`$accumulator` and the data-mutating stages
  #   at any nesting depth.
  #
  # == Policy: allowlist top-level, denylist recursive
  #
  # Strict mode enforces {ALLOWED_STAGES} ONLY at the top-level stage
  # key — nested sub-pipelines (inside `$lookup.pipeline`,
  # `$unionWith.pipeline`, `$facet.*`, `$graphLookup`) are walked with
  # the operator denylist but NOT with the stage allowlist. This is
  # intentional: Atlas Search and uncommon-but-legitimate read stages
  # like `$densify` and `$fill` must be allowed inside sub-pipelines
  # even when the outer pipeline is strict-validated. The denylist is
  # the security boundary; the allowlist is a shape check.
  #
  # == Caveat for {Parse::Query#aggregate} callers
  #
  # `Parse::Query#aggregate` routes through {validate_filter!}, not
  # {validate_pipeline!}, so user-supplied pipelines are checked
  # against the denylist only. Permissive mode does NOT block
  # `$lookup`, `$graphLookup`, or `$unionWith` reading from arbitrary
  # collections — these are legitimate read stages but powerful enough
  # to cross Parse ACL/CLP boundaries when the source collection lacks
  # row-level enforcement. **Never pass raw attacker-controlled input
  # into `Parse::Query#aggregate`.** Construct the pipeline in SDK code
  # and interpolate only validated values.
  #
  # == Capability gap: `$expr`
  #
  # `$expr` itself is not in {DENIED_OPERATORS}. The recursive walker
  # catches `$function`/`$accumulator` nested inside `$expr`, so the
  # immediate JavaScript-execution risk is closed. A future Atlas
  # operator gated under `$expr` would slip until {DENIED_OPERATORS}
  # is extended. Defense-in-depth callers concerned about expensive
  # aggregation expressions (`$regexMatch` ReDoS, large `$reduce`
  # loops) should validate user input shape before reaching this
  # module.
  module PipelineSecurity
    # Raised when a pipeline or filter contains a forbidden stage or
    # operator. Inherits from `Parse::Error` so callers can rescue both
    # this and other Parse SDK errors with one rescue clause.
    class Error < Parse::Error
      attr_reader :stage, :operator, :reason

      def initialize(message, stage: nil, operator: nil, reason: nil)
        @stage = stage
        @operator = operator
        @reason = reason
        super(message)
      end
    end

    # Operators that are ALWAYS refused at any nesting depth. These either
    # execute server-side JavaScript (`$where`, `$function`,
    # `$accumulator`) or mutate the database (`$out`, `$merge`) or the
    # server itself (`$collMod`, `$createIndex`, `$dropIndex`,
    # `$planCacheSetFilter`, `$planCacheClear`). None of them are needed
    # for read queries.
    DENIED_OPERATORS = %w[
      $where $function $accumulator
      $out $merge
      $collMod $createIndex $dropIndex
      $planCacheSetFilter $planCacheClear
    ].freeze

    # Field-reference paths (string values inside `$expr` whose first
    # byte is `$`) that point at server-internal columns and must never
    # be reachable from a user-influenced pipeline. A boolean expression
    # inside `$expr` over any of these is a 1-bit-per-query side channel
    # that bisects the value of a bcrypt hash, session token, or
    # password-reset token. Names match Parse Server's internal column
    # layout (cf. MongoStorageAdapter).
    DENIED_FIELD_REFS = %w[
      $_hashed_password $_password_history
      $_session_token $_sessionToken
      $sessionToken $session_token
      $_email_verify_token $_perishable_token
      $_failed_login_count $_account_lockout_expires_at
      $_rperm $_wperm
      $_auth_data
    ].freeze

    # String prefix for per-provider auth-data field references inside $expr.
    # Parse Server stores per-provider columns as `_auth_data_facebook`,
    # `_auth_data_google`, etc. — none of these should be reachable from a
    # user-influenced pipeline. The prefix `$_auth_data_` covers all of them
    # without requiring an exhaustive list.
    DENIED_FIELD_REF_PREFIXES = %w[$_auth_data_].freeze

    # MongoDB collection names that an SDK aggregation IS permitted to
    # name in `from:`/`coll:`. Any name starting with `_` outside this
    # set is refused as an internal Parse Server collection. The four
    # entries here are the only `_`-prefixed collections that hold
    # Parse SDK data classes; everything else with a leading `_` is
    # server-managed state (`_SCHEMA` discloses class-level
    # permissions; `_Hooks` discloses Cloud Code webhook URLs + secret
    # keys; `_GraphQLConfig` discloses GraphQL schema state; `_Audit`
    # holds operational telemetry; `_Idempotency`/`_PushStatus`/
    # `_JobStatus`/`_JobSchedule`/`_GlobalConfig`/`_Audience` hold
    # internal Parse Server bookkeeping).
    ALLOWED_UNDERSCORE_COLLECTIONS = %w[_User _Role _Installation _Session].freeze

    # Field names that are internal to Parse Server's storage layout
    # and must never appear in returned documents. Most are stripped
    # by `Parse::MongoDB.convert_document_to_parse`, but a raw-result
    # path (`raw: true`) bypasses that conversion and would otherwise
    # surface the bcrypt hash, session token, or reset token.
    #
    # `sessionToken` / `session_token` (no leading underscore) are the
    # credential column on `_Session` rows. Unlike the `_User`-side
    # `_session_token`, the Session class declares it as a regular
    # property, so without this entry a master-key agent that has had
    # the class explicitly unhidden would receive raw bearer tokens in
    # every row of a `query_class("_Session")` response. The denylist
    # is the process-level floor — independent of class-visibility
    # state — so even a deliberate `agent_unhidden` on `_Session` (or
    # a compromised superadmin tool) cannot exfiltrate active tokens.
    INTERNAL_FIELDS_DENYLIST = %w[
      _hashed_password _password_history
      _session_token _sessionToken
      sessionToken session_token
      _email_verify_token _perishable_token
      _failed_login_count _account_lockout_expires_at
      _rperm _wperm _tombstone
      _auth_data
    ].freeze

    # Prefix covering per-provider auth-data columns (`_auth_data_facebook`,
    # `_auth_data_google`, …). Used by strip_internal_fields and by the
    # walk_for_denied! field-name screen.
    INTERNAL_FIELDS_PREFIX_DENYLIST = %w[_auth_data_].freeze

    # The credential / sensitive subset of {INTERNAL_FIELDS_DENYLIST}. These
    # columns must NEVER appear as a user-influenced `$match` field name —
    # even on a pipeline that runs with `allow_internal_fields: true` (which
    # exists to permit SDK-emitted `_rperm`/`_wperm` references from
    # `readable_by_role` / `publicly_readable`). A `$match`/`$count` on a
    # password hash, session/reset token, or auth-data column is a credential-
    # exfiltration oracle (bisect the value char-by-char), and these columns
    # have NO legitimate SDK query use — so the `allow_internal_fields` escape
    # hatch must not relax them. Derived from {INTERNAL_FIELDS_DENYLIST} minus
    # the ACL/bookkeeping columns (`_rperm`/`_wperm`/`_tombstone`) the ACL DSL
    # legitimately emits, so the two lists never drift.
    CREDENTIAL_FIELDS_DENYLIST = (INTERNAL_FIELDS_DENYLIST - %w[_rperm _wperm _tombstone]).freeze

    # Forensic string-introspection operators. When any of these
    # appears INSIDE `$expr` with a field-reference input string, the
    # query becomes a per-character oracle even though the operator
    # itself is otherwise legitimate. Refused inside `$expr` regardless
    # of the input — the validator does not try to introspect operand
    # shapes deeply, and these operators have no legitimate use against
    # Parse-Server-managed columns from an SDK aggregation.
    FORENSIC_OPERATORS = %w[
      $regexMatch $regexFind $regexFindAll
      $substr $substrBytes $substrCP
      $indexOfBytes $indexOfCP
      $strLenBytes $strLenCP
      $strcasecmp
    ].freeze

    # Top-level pipeline stages permitted by the strict validator. The
    # set covers Parse-Stack's own aggregation use, plus Atlas Search
    # entry points (`$search`, `$searchMeta`, `$listSearchIndexes`) so
    # that `Parse::AtlasSearch` calls do not break. `$vectorSearch` is
    # included for `Parse::VectorSearch` — like `$search`, it is a
    # read-only Atlas index stage and must be the FIRST stage of the
    # pipeline (Atlas refuses it otherwise). `$rankFusion` (Atlas 8.0+)
    # is the native server-side reciprocal-rank-fusion stage used by
    # `Parse::VectorSearch::Hybrid` — also a read-only stage-0 operator.
    ALLOWED_STAGES = %w[
      $match $group $sort $project $limit $skip $unwind $lookup
      $count $addFields $set $unset $bucket $bucketAuto $facet
      $sample $sortByCount $replaceRoot $replaceWith $redact
      $graphLookup $unionWith
      $search $searchMeta $listSearchIndexes $vectorSearch $rankFusion
    ].freeze

    # Atlas operators that are valid only as the FIRST stage of a
    # pipeline (Atlas refuses them anywhere else). They are present in
    # {ALLOWED_STAGES} so the SDK's own modules — `Parse::AtlasSearch`
    # and `Parse::VectorSearch` — can emit them; both of those modules
    # bypass {validate_pipeline!} and build their pipelines internally.
    # Caller-supplied pipelines (e.g. through `Parse::Agent::Tools.aggregate`)
    # must NOT include these stages: the Agent's tenant-scope `$match`
    # prepend would push them off stage 0, and the proper agent surface
    # for full-text and vector search is the dedicated
    # `atlas_search` / `semantic_search` tools, not raw aggregate.
    STAGE0_ONLY_ATLAS_STAGES = %w[
      $search $searchMeta $vectorSearch $listSearchIndexes $rankFusion
    ].freeze

    # Cap on the length of a caller-supplied `$regex` (or the `regex:`
    # field inside `$regexMatch` / `$regexFind` / `$regexFindAll`)
    # pattern string. ReDoS protection: doesn't catch every pathological
    # pattern (small patterns like `(a+)+$` can still backtrack
    # catastrophically), but caps the worst class of caller-shipped
    # patterns and stops the "1MB regex" denial-of-service shape that an
    # attacker could send through `vector_filter:` / `filter:` /
    # `where:`. Legitimate Parse-Server queries are well under this.
    MAX_REGEX_PATTERN_LENGTH = 512

    # Cap on number of top-level stages in a strict-validated pipeline.
    MAX_PIPELINE_STAGES = 20

    # Cap on nested object/array depth during recursive walks. Stops a
    # caller from forcing the validator into a near-infinite traversal.
    # Legitimate Parse-generated pipelines with `$facet` containing
    # `$lookup` with `let` and correlated sub-pipelines (`$match.$expr.
    # $and.[…]`) can reach depth 12+ on a normal read, so we keep
    # comfortable headroom above the real ceiling.
    MAX_DEPTH = 20

    module_function

    # Strict validation: pipeline must be a non-empty Array of Hashes,
    # each Hash's top-level key must be in {ALLOWED_STAGES}, and no
    # entry in {DENIED_OPERATORS} may appear at any nesting depth.
    #
    # @param pipeline [Array<Hash>] the aggregation pipeline.
    # @raise [Error] if validation fails.
    # @return [true]
    def validate_pipeline!(pipeline)
      unless pipeline.is_a?(Array)
        raise Error.new("Pipeline must be an Array, got #{pipeline.class}", reason: :invalid_type)
      end
      if pipeline.empty?
        raise Error.new("Pipeline cannot be empty", reason: :empty_pipeline)
      end
      if pipeline.size > MAX_PIPELINE_STAGES
        raise Error.new(
          "Pipeline exceeds maximum of #{MAX_PIPELINE_STAGES} stages (got #{pipeline.size})",
          reason: :too_many_stages,
        )
      end

      pipeline.each_with_index do |stage, idx|
        validate_stage!(stage, idx)
      end
      true
    end

    # Permissive validation: walks the given Hash or Array (or anything
    # else, which is a no-op) and refuses any nested key that appears
    # in {DENIED_OPERATORS}. Does NOT check the top-level stage
    # allowlist or the stage count cap. Used by direct-MongoDB sinks
    # where callers have explicit intent and want flexibility in stage
    # selection, but server-side JS and data-mutating operators must
    # still be refused.
    #
    # @param node [Hash, Array, Object] the structure to walk.
    # @param allow_internal_fields [Boolean] when true, skip the
    #   {INTERNAL_FIELDS_DENYLIST} check (e.g. for SDK-generated ACL
    #   filters that legitimately reference `_rperm`/`_wperm` via
    #   {Parse::Query#readable_by_role} and friends). The
    #   {DENIED_OPERATORS} walk and forensic-operator gating still
    #   apply. Default `false` for callers that forward raw,
    #   user-influenced pipelines (e.g. Agent MCP tools).
    # @raise [Error] if a denied operator is found at any depth.
    # @return [true]
    def validate_filter!(node, allow_internal_fields: false)
      walk_for_denied!(node, depth: 0, allow_internal_fields: allow_internal_fields)
      true
    end

    # @return [Boolean] true if the pipeline passes strict validation.
    def valid_pipeline?(pipeline)
      validate_pipeline!(pipeline)
      true
    rescue Error
      false
    end

    # @return [Boolean] true if the node passes permissive validation.
    def valid_filter?(node)
      validate_filter!(node)
      true
    rescue Error
      false
    end

    # Refuses any collection name reserved for Parse Server's internal
    # state. Accepts the four SDK-data system classes (`_User`,
    # `_Role`, `_Installation`, `_Session`) and any non-`_`-prefixed
    # name. Used by `LookupRewriter` and by the Agent's pipeline
    # walker to enforce a hard floor independent of any per-Agent
    # `MetadataRegistry.hidden?` policy.
    #
    # @param name [String, Symbol, nil] the collection name from
    #   `from:`/`coll:`. `nil` is treated as "no collection named" --
    #   the caller passes through.
    # @raise [Error] when `name` is `_`-prefixed and not in
    #   {ALLOWED_UNDERSCORE_COLLECTIONS}.
    def assert_collection_allowed!(name)
      return if name.nil?
      str = name.to_s
      return if str.empty?
      return unless str.start_with?("_")
      return if ALLOWED_UNDERSCORE_COLLECTIONS.include?(str)
      raise Error.new(
        "SECURITY: Collection '#{str}' is reserved for Parse Server's internal " \
        "state and is not reachable from an SDK aggregation pipeline.",
        operator: str,
        reason: :denied_internal_collection,
      )
    end

    # Strip {INTERNAL_FIELDS_DENYLIST} keys from a Hash document (one
    # level deep -- raw search documents are flat). Returns a new
    # Hash; the input is not mutated. Non-Hash inputs return unchanged
    # so callers can pipe arbitrary cursor entries through this.
    def strip_internal_fields(doc)
      return doc unless doc.is_a?(Hash)
      doc.each_with_object({}) do |(key, value), out|
        k = key.to_s
        next if INTERNAL_FIELDS_DENYLIST.include?(k)
        next if INTERNAL_FIELDS_PREFIX_DENYLIST.any? { |prefix| k.start_with?(prefix) }
        out[key] = value
      end
    end

    # Depth bound for {redact_internal_fields_deep!}. `$lookup`/`$graphLookup`/
    # `$unionWith` embed foreign documents at shallow alias depth, so this is
    # generous; the bound exists only to fail safe on cyclic/pathological docs.
    INTERNAL_REDACT_MAX_DEPTH = 32

    # Recursively delete {INTERNAL_FIELDS_DENYLIST} / {INTERNAL_FIELDS_PREFIX_DENYLIST}
    # keys from `node` AND every embedded sub-document/array element, in place.
    #
    # This is the process-level floor that stops Parse-Server-internal
    # credential columns (`_hashed_password`, `_session_token`, `_auth_data_*`,
    # `_rperm`/`_wperm`, ...) from reaching a scoped caller through ANY result
    # shape — most importantly a foreign-class document pulled in via
    # `$lookup`/`$graphLookup`/`$unionWith` under an arbitrary alias. Neither
    # the per-class protectedFields strip (keyed on the OUTER class) nor the
    # ACL sub-document walk (which only DROPS ACL-failing sub-docs, never
    # strips field names) covers that alias. Unlike {strip_internal_fields}
    # (one level, non-mutating), this walks the whole tree and mutates in
    # place so it can run as the last step over a result set.
    #
    # Structural columns (`_id`, `_p_*`, `_created_at`, `_updated_at`, `_acl`)
    # are intentionally NOT in the denylist, so object/ACL reconstruction is
    # unaffected.
    #
    # @param node [Object] a result row (Hash), array, or scalar.
    # @return [Object] the same node, mutated.
    def redact_internal_fields_deep!(node, depth: INTERNAL_REDACT_MAX_DEPTH)
      case node
      when Hash
        # Always clean the current level (even at the depth floor) so an
        # embedded document sitting exactly at the bound is still scrubbed.
        node.delete_if do |key, _value|
          ks = key.to_s
          INTERNAL_FIELDS_DENYLIST.include?(ks) ||
            INTERNAL_FIELDS_PREFIX_DENYLIST.any? { |prefix| ks.start_with?(prefix) }
        end
        node.each_value { |v| redact_internal_fields_deep!(v, depth: depth - 1) } if depth > 0
      when Array
        node.each { |el| redact_internal_fields_deep!(el, depth: depth - 1) } if depth > 0
      end
      node
    end

    # Wave-3 TRACK-CLP-4: refuse caller-supplied pipelines that
    # reference a protected field via `$<field>` on the RHS of a
    # `$project` / `$addFields` / `$set` / `$group` / `$bucket` /
    # `$replaceWith` / `$lookup.let` clause.
    #
    # The protectedFields enforcement layer (CLPScope.redact_protected_fields!)
    # strips the field by NAME from the result rows. But a pipeline
    # can launder a protected field through a rename:
    #
    #   { "$addFields" => { "ssn_copy" => "$ssn" } }
    #   { "$project"   => { "renamed"  => "$ssn", "objectId" => 1 } }
    #   { "$group"     => { "_id" => "$ssn", "n" => { "$sum" => 1 } } }
    #
    # The post-fetch strip walks the rows and deletes `ssn` keys, but
    # the value is now stored under `ssn_copy` / `renamed` / `_id`,
    # so the strip walks past it. This scanner runs BEFORE the pipeline
    # reaches Mongo: any `$<field>` string whose unprefixed name is in
    # the class's protected-fields set raises {Parse::CLPScope::Denied}
    # so the caller knows the join was refused, rather than silently
    # leaking the renamed value.
    #
    # Variable references (`$$ROOT`, `$$CURRENT`, `$$user_var`) are
    # NOT field references — they're aggregation variables. The walker
    # checks the leading `$` is single, not double, before treating the
    # string as a field path.
    #
    # Master mode + nil resolution short-circuit at the entry: the
    # walker is a no-op when the caller can read everything anyway.
    #
    # @param pipeline [Array<Hash>] the caller-supplied pipeline,
    #   before SDK-side ACL stages are prepended.
    # @param collection_name [String] the queried collection / class.
    # @param resolution [Parse::ACLScope::Resolution, nil] the resolved
    #   scope; nil-or-master short-circuits.
    # @raise [Parse::CLPScope::Denied] when any nested string in the
    #   pipeline names a protected field via `$<name>` syntax.
    # @return [void]
    def refuse_protected_field_references!(pipeline, collection_name, resolution)
      return if resolution.nil? || (resolution.respond_to?(:master?) && resolution.master?)
      return if pipeline.nil? || pipeline.empty?
      perms = resolution.respond_to?(:permission_strings) ? resolution.permission_strings : nil
      return if perms.nil?

      # Lazy-require to avoid forcing CLPScope load order when the
      # caller hasn't otherwise needed it.
      require_relative "clp_scope" unless defined?(Parse::CLPScope)

      protected_set = Parse::CLPScope.protected_fields_for(collection_name, perms)
      return if protected_set.nil? || protected_set.empty?

      pipeline.each_with_index do |stage, idx|
        walk_for_protected_ref!(stage, protected_set, collection_name, "pipeline[#{idx}]")
      end
      nil
    end

    # @!visibility private
    def walk_for_protected_ref!(node, protected_set, class_name, path)
      case node
      when String
        # Field-reference syntax is `$<path>` — variable refs start
        # with `$$` (e.g. `$$ROOT`, `$$<userVarFromLet>`) and aren't
        # field references; skip them.
        return if node.empty?
        return unless node.start_with?("$")
        return if node.start_with?("$$")
        # Path may be dotted (`$ssn.area`). The protectedFields list
        # is a set of top-level column names per Parse Server's CLP
        # schema, so we compare against the first segment.
        head = node.sub(/\A\$/, "").split(".").first
        return if head.nil? || head.empty?
        # `$_id` is the canonical primary-key reference; never on the
        # protected list and would otherwise short-circuit common
        # aggregations like `{$group: {_id: "$_id"}}`.
        return if head == "_id"
        if protected_set.include?(head)
          raise Parse::CLPScope::Denied.new(
            class_name, :read,
            "Pipeline at #{path} references protectedField '#{head}' " \
            "via field-reference '#{node}'. ProtectedFields cannot be " \
            "laundered through a $project/$addFields/$group rename — " \
            "the post-fetch strip walks by name and would miss the " \
            "renamed value, leaking the protected column.",
          )
        end
      when Array
        node.each_with_index do |child, i|
          walk_for_protected_ref!(child, protected_set, class_name, "#{path}[#{i}]")
        end
      when Hash
        node.each do |key, value|
          # Recurse into every value. Hash keys are field NAMES in
          # most contexts, not references — we don't need to gate them
          # because the post-fetch redact would still strip a key
          # literally named "ssn". The bypass is the VALUE-side
          # field-reference string.
          walk_for_protected_ref!(value, protected_set, class_name, "#{path}.#{key}")
        end
      end
      nil
    end
    private_class_method :walk_for_protected_ref!

    # @!visibility private
    def validate_stage!(stage, idx)
      unless stage.is_a?(Hash)
        raise Error.new(
          "Pipeline stage #{idx} must be a Hash, got #{stage.class}",
          stage: idx,
          reason: :invalid_stage_type,
        )
      end

      stage.each do |key, value|
        key_str = key.to_s

        if DENIED_OPERATORS.include?(key_str)
          raise Error.new(
            "SECURITY: Pipeline stage #{idx} uses denied operator '#{key_str}'. " \
            "This operator either executes server-side JavaScript or mutates data, " \
            "and is refused at any nesting depth.",
            stage: idx,
            operator: key_str,
            reason: :denied_operator,
          )
        end

        if key_str.start_with?("$") && !ALLOWED_STAGES.include?(key_str)
          raise Error.new(
            "SECURITY: Unknown aggregation stage '#{key_str}' at index #{idx} is not in the " \
            "allowed stage list. Allowed: #{ALLOWED_STAGES.join(", ")}.",
            stage: idx,
            operator: key_str,
            reason: :unknown_stage,
          )
        end

        walk_for_denied!(value, depth: 1, stage_idx: idx)
      end
    end
    private_class_method :validate_stage!

    # @!visibility private
    def walk_for_denied!(node, depth:, stage_idx: nil, inside_expr: false, allow_internal_fields: false)
      if depth > MAX_DEPTH
        raise Error.new(
          "Pipeline nesting depth exceeded (#{MAX_DEPTH}). " \
          "Refusing to walk pathologically nested structures.",
          stage: stage_idx,
          reason: :max_depth_exceeded,
        )
      end

      case node
      when Hash
        node.each do |key, value|
          key_str = key.to_s
          if DENIED_OPERATORS.include?(key_str)
            raise Error.new(
              "SECURITY: Nested denied operator '#{key_str}' found at nesting depth #{depth}" \
              "#{stage_idx ? " inside stage #{stage_idx}" : ""}. " \
              "This operator either executes server-side JavaScript or mutates data, " \
              "and is refused at any depth.",
              stage: stage_idx,
              operator: key_str,
              reason: :nested_denied_operator,
            )
          end
          # H1 / M1: refuse any Hash key — at any nesting depth — that
          # names an internal Parse Server column. These appear as $match
          # field names in aggregation pipelines and create the same
          # oracle as the where:-constraint path in ConstraintTranslator.
          # Operators ($-prefixed) are excluded because they are validated
          # separately by DENIED_OPERATORS.
          #
          # CREDENTIAL columns (password hash, session/reset token, auth data)
          # are refused UNCONDITIONALLY — `allow_internal_fields` (which exists
          # so SDK-emitted `_rperm`/`_wperm` references survive on the mongo-
          # direct path) must NOT relax them, or a `*_direct` terminal becomes
          # a credential-bisection oracle. The remaining internal columns
          # (`_rperm`/`_wperm`/`_tombstone`) stay gated by allow_internal_fields.
          if !key_str.start_with?("$")
            is_credential = CREDENTIAL_FIELDS_DENYLIST.include?(key_str) ||
                            INTERNAL_FIELDS_PREFIX_DENYLIST.any? { |prefix| key_str.start_with?(prefix) }
            is_internal = INTERNAL_FIELDS_DENYLIST.include?(key_str) ||
                          INTERNAL_FIELDS_PREFIX_DENYLIST.any? { |prefix| key_str.start_with?(prefix) }
            if is_credential || (is_internal && !allow_internal_fields)
              raise Error.new(
                "SECURITY: Pipeline references internal Parse Server field " \
                "'#{key_str}' at nesting depth #{depth}" \
                "#{stage_idx ? " inside stage #{stage_idx}" : ""}. " \
                "This column (password hash, session token, auth data, or ACL " \
                "pointer) must not appear in a user-influenced pipeline — " \
                "it enables credential exfiltration via count/match oracles.",
                stage: stage_idx,
                operator: key_str,
                reason: :denied_internal_field,
              )
            end
          end
          # Cap caller-supplied regex pattern length. Catches the two
          # shapes Mongo accepts: the find-form `{ field: { $regex: "..." } }`
          # (key == "$regex", value a String), and the aggregation-form
          # `{ $regexMatch: { input: ..., regex: "..." } }` (key ==
          # "$regexMatch"/"$regexFind"/"$regexFindAll", value a Hash with
          # a "regex"/"pattern" String inside). Stops a multi-KB pattern
          # from reaching MongoDB regardless of where in the pipeline it
          # appears.
          if key_str == "$regex" && value.is_a?(String) && value.bytesize > MAX_REGEX_PATTERN_LENGTH
            raise Error.new(
              "SECURITY: $regex pattern exceeds #{MAX_REGEX_PATTERN_LENGTH} bytes " \
              "(got #{value.bytesize}). Long caller-supplied regex patterns are a " \
              "ReDoS vector; refuse caller-supplied regexes longer than this cap.",
              stage: stage_idx,
              operator: "$regex",
              reason: :regex_pattern_too_long,
            )
          end
          if %w[$regexMatch $regexFind $regexFindAll].include?(key_str) && value.is_a?(Hash)
            pat = value["regex"] || value[:regex] || value["pattern"] || value[:pattern]
            if pat.is_a?(String) && pat.bytesize > MAX_REGEX_PATTERN_LENGTH
              raise Error.new(
                "SECURITY: #{key_str} regex pattern exceeds #{MAX_REGEX_PATTERN_LENGTH} bytes " \
                "(got #{pat.bytesize}). Refuse caller-supplied regexes longer than this cap.",
                stage: stage_idx,
                operator: key_str,
                reason: :regex_pattern_too_long,
              )
            end
          end
          child_inside_expr = inside_expr || key_str == "$expr"
          if child_inside_expr && FORENSIC_OPERATORS.include?(key_str)
            raise Error.new(
              "SECURITY: Forensic operator '#{key_str}' inside $expr at nesting depth #{depth}" \
              "#{stage_idx ? " inside stage #{stage_idx}" : ""}. " \
              "String-introspection operators inside $expr enable per-character " \
              "side-channel exfiltration of password hashes, session tokens, and " \
              "reset tokens.",
              stage: stage_idx,
              operator: key_str,
              reason: :forensic_operator_in_expr,
            )
          end
          walk_for_denied!(value, depth: depth + 1, stage_idx: stage_idx, inside_expr: child_inside_expr, allow_internal_fields: allow_internal_fields)
        end
      when Array
        node.each { |item| walk_for_denied!(item, depth: depth + 1, stage_idx: stage_idx, inside_expr: inside_expr, allow_internal_fields: allow_internal_fields) }
      when String
        # Refuse any `$<field>` reference string that names an internal
        # Parse Server column, regardless of whether it appears inside
        # `$expr` or as a plain projection/grouping expression value.
        #
        # The previous guard was `inside_expr && ...`, which only fired
        # when the string appeared nested under a `$expr` key. That missed
        # the common aggregation shapes:
        #   { "$project" => { "x" => "$_hashed_password" } }
        #   { "$group"   => { "_id" => "$_hashed_password" } }
        #   { "$addFields" => { "copy" => "$_auth_data_facebook" } }
        # In all three cases the string reaches `walk_for_denied!` as a
        # plain Hash value, not under `$expr`, so `inside_expr` was false
        # and the check was skipped — leaking the internal field reference
        # to MongoDB on classes that had no `agent_fields` allowlist.
        #
        # Internal-field reference strings have no legitimate use outside
        # `$expr`, so broadening the guard to unconditional is safe.
        if DENIED_FIELD_REFS.include?(node) ||
           DENIED_FIELD_REF_PREFIXES.any? { |prefix| node.start_with?(prefix) }
          raise Error.new(
            "SECURITY: Field-reference '#{node}' at nesting depth #{depth}" \
            "#{stage_idx ? " inside stage #{stage_idx}" : ""}. " \
            "This column is internal to Parse Server (password hash, session " \
            "token, reset token, auth data, or ACL pointer) and must not appear " \
            "in a user-influenced pipeline.",
            stage: stage_idx,
            operator: node,
            reason: :denied_field_ref_in_expr,
          )
        end
      end
      # Other primitives (Integer, etc.) are always safe.
      nil
    end
    private_class_method :walk_for_denied!
  end
end
