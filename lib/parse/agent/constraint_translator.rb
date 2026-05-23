# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # The ConstraintTranslator converts JSON-style query constraints
    # (like those from LLM function calls) into Parse REST API format.
    #
    # It enforces strict security validation:
    # - Blocks dangerous operators that allow code execution ($where, $function, etc.)
    # - Rejects unknown operators (whitelist-based approach)
    # - Limits query depth to prevent DoS attacks
    #
    # @example Basic translation
    #   ConstraintTranslator.translate({
    #     "plays" => { "$gte" => 1000 },
    #     "artist" => "Beatles"
    #   })
    #   # => {"plays" => {"$gte" => 1000}, "artist" => "Beatles"}
    #
    # @example Blocked operator raises SecurityError
    #   ConstraintTranslator.translate({ "$where" => "this.a > 1" })
    #   # => raises ConstraintSecurityError
    #
    module ConstraintTranslator
      extend self

      # Security error for blocked operators that allow code execution
      class ConstraintSecurityError < SecurityError
        attr_reader :operator, :reason

        def initialize(message, operator: nil, reason: nil)
          @operator = operator
          @reason = reason
          super(message)
        end
      end

      # Validation error for unknown/invalid operators
      class InvalidOperatorError < StandardError
        attr_reader :operator

        def initialize(message, operator: nil)
          @operator = operator
          super(message)
        end
      end

      # Operators that are BLOCKED - they allow arbitrary code execution
      # These are blocked regardless of permission level
      BLOCKED_OPERATORS = %w[
        $where
        $function
        $accumulator
        $expr
      ].freeze

      # Whitelist of allowed Parse query operators
      ALLOWED_OPERATORS = %w[
        $lt $lte $gt $gte $ne $eq
        $in $nin $all $exists
        $regex $options
        $text $search
        $near $nearSphere $geoWithin $geoIntersects
        $centerSphere $box $polygon $geometry
        $maxDistance $maxDistanceInMiles
        $maxDistanceInKilometers $maxDistanceInRadians
        $relatedTo $inQuery $notInQuery
        $containedIn $containsAll
        $select $dontSelect
        $or $and $nor
      ].freeze

      # Operators whose value carries an inner sub-query of the shape
      # +{className:, where:, key:}+. Each must be validated through
      # {Tools.assert_class_accessible!} so the LLM cannot reach into a
      # hidden class via the sub-query, and the inner +where+ must be
      # recursively re-translated so blocked operators inside it are
      # also caught.
      CROSS_CLASS_OPERATORS = %w[
        $inQuery $notInQuery $select $dontSelect
      ].freeze

      # Field-name keys (non-operator) that are never permitted in a
      # caller-supplied where: constraint, regardless of class or permission
      # level. These are internal Parse Server columns whose presence in a
      # $match filter creates a 1-bit-per-query oracle that can exfiltrate
      # bcrypt hashes, session tokens, or reset tokens character-by-character
      # via count deltas. The list covers:
      #
      # - Exact names (lowercased storage form and camelCase API form)
      # - A prefix that catches per-provider columns stored as
      #   `_auth_data_facebook`, `_auth_data_google`, etc.
      #
      # Mirrored in Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST so
      # the aggregate pipeline path is covered independently (the two
      # modules can be loaded in any order; duplication is intentional).
      DENIED_WHERE_KEYS = %w[
        _hashed_password _password_history
        _session_token _sessionToken
        _email_verify_token _perishable_token
        _failed_login_count _account_lockout_expires_at
        _rperm _wperm
        _auth_data
      ].freeze

      # Prefix-based check (catches _auth_data_facebook, _auth_data_google, …).
      DENIED_WHERE_KEY_PREFIXES = %w[_auth_data_].freeze

      # Maximum query depth to prevent DoS via deeply nested structures
      MAX_QUERY_DEPTH = 8

      # NEW-TOOLS-7: cap $regex pattern length. Patterns larger than this
      # are rejected before reaching MongoDB. 256 is generous for the
      # legitimate analyst-facing patterns the agent surface is designed
      # for (prefix anchors, simple character classes) while keeping the
      # worst-case backtracking cost on any one pattern bounded.
      MAX_REGEX_PATTERN_LENGTH = 256

      # Allowed $options flag characters. MongoDB accepts i (case
      # insensitive), m (multi-line), x (extended/whitespace-ignored),
      # s (dot-all). The dot-all `s` flag is intentionally omitted: it
      # makes `.` cross newlines, which extends the search frontier on
      # multi-line text fields and amplifies catastrophic-backtracking
      # cost for the worst patterns. `imx` covers every real use case
      # the agent surface needs.
      ALLOWED_REGEX_OPTIONS = "imx"

      # Heuristic for nested-quantifier ReDoS patterns (catastrophic
      # backtracking). Matches a quantifier (`+` or `*`) INSIDE a
      # parenthesized group that is itself followed by a quantifier
      # (`+`, `*`, or `?`) — the structural shape that drives
      # exponential time on adversarial inputs (`(a+)+`, `(a*)*`,
      # `(x|y)+?` are all reachable). Stricter than the audit's
      # suggested heuristic, which would false-positive on innocuous
      # patterns like `^foo.*bar.*$`. Anchored prefixes without
      # nested-quantifier-groups (`^bar(a+)+` is still refused; plain
      # `^foo.*` is not).
      REDOS_NESTED_QUANTIFIER_RE = /\([^)]*[+*][^)]*\)[+*?]/.freeze

      # Translate JSON constraints to Parse query format.
      # Validates all operators against the security whitelist.
      #
      # @param constraints [Hash] the query constraints from LLM
      # @raise [ConstraintSecurityError] if blocked operators are used
      # @raise [InvalidOperatorError] if unknown operators are used
      # @return [Hash] translated constraints for Parse REST API
      # @param constraints [Hash] the query constraints from LLM
      # @param agent [Parse::Agent, nil] optional agent context for per-agent
      #   class-filter enforcement on embedded cross-class operators
      #   (`$inQuery` / `$select`). Passed positionally (not keyword) so a
      #   bracket-less Hash literal at the call site — `translate("key" => val)`
      #   — continues to parse as a single positional Hash under Ruby 3+
      #   kwargs separation. Adding a kwarg would have turned the same call
      #   into "empty kwargs + missing positional arg."
      def translate(constraints, agent = nil)
        return {} if constraints.nil? || constraints.empty?

        raise InvalidOperatorError.new(
          "Constraints must be a Hash, got #{constraints.class}",
          operator: nil,
        ) unless constraints.is_a?(Hash)

        constraints.transform_keys(&:to_s).each_with_object({}) do |(key, value), result|
          # Check for blocked operators at the root level
          if key.start_with?("$")
            validate_operator!(key)
          end
          # H1 / M1: reject keys that reference internal Parse Server columns.
          # These enable bcrypt-hash and session-token oracle attacks via
          # count deltas even when operators are otherwise clean.
          assert_where_key_permitted!(key)
          result[columnize(key)] = translate_value(value, depth: 0, agent: agent)
        end
      end

      # Check if constraints are valid without raising.
      #
      # @param constraints [Hash] the query constraints
      # @return [Boolean] true if valid, false otherwise
      def valid?(constraints)
        translate(constraints)
        true
      rescue ConstraintSecurityError, InvalidOperatorError
        false
      end

      private

      # Translate a single value, handling nested operators
      #
      # @param value [Object] the value to translate
      # @param depth [Integer] current nesting depth
      # @return [Object] the translated value
      def translate_value(value, depth:, agent: nil)
        raise InvalidOperatorError.new(
          "Query exceeds maximum depth of #{MAX_QUERY_DEPTH}",
          operator: nil,
        ) if depth > MAX_QUERY_DEPTH

        case value
        when Hash
          translate_hash_value(value, depth: depth, agent: agent)
        when Array
          value.map { |v| translate_value(v, depth: depth + 1, agent: agent) }
        else
          value
        end
      end

      # Translate a hash value (could be operators or a pointer/object)
      def translate_hash_value(hash, depth:, agent: nil)
        # Check if it's a Parse type (Pointer, Date, File, GeoPoint)
        return hash if parse_type?(hash)

        # Check if all keys are operators
        if hash.keys.all? { |k| k.to_s.start_with?("$") }
          hash.transform_keys(&:to_s).each_with_object({}) do |(op, val), result|
            validate_operator!(op)
            # NEW-TOOLS-7: validate $regex / $options operands before
            # forwarding to MongoDB.
            assert_regex_operand_safe!(op, val) if op == "$regex" || op == "$options"
            result[op] = if CROSS_CLASS_OPERATORS.include?(op)
                           translate_cross_class_value(op, val, depth: depth + 1, agent: agent)
                         else
                           translate_value(val, depth: depth + 1, agent: agent)
                         end
          end
        else
          # Regular nested object - translate keys to columnized format.
          # Apply the internal-field key denylist at every nesting level so
          # a key nested inside $and/$or/$nor cannot bypass the top-level check.
          hash.transform_keys(&:to_s).each_with_object({}) do |(k, v), result|
            assert_where_key_permitted!(k)
            result[columnize(k)] = translate_value(v, depth: depth + 1, agent: agent)
          end
        end
      end

      # Translate the value of a cross-class operator
      # (+$inQuery+/+$notInQuery+/+$select+/+$dontSelect+). The value
      # carries an embedded +className+ that must be validated against
      # the active accessibility policy, and an embedded +where+ that
      # must be recursively translated so blocked operators (e.g.
      # +$where+ nested inside) cannot smuggle through.
      def translate_cross_class_value(op, val, depth:, agent: nil)
        return val unless val.is_a?(Hash)
        val = val.transform_keys(&:to_s)
        embedded_class_name = nil
        embedded_where = nil

        if op == "$select" || op == "$dontSelect"
          # Shape: { "query" => { "className" => "X", "where" => {...} }, "key" => "field" }
          query_part = val["query"]
          if query_part.is_a?(Hash)
            query_part = query_part.transform_keys(&:to_s)
            embedded_class_name = query_part["className"]
            embedded_where = query_part["where"]
          end
        else
          # $inQuery / $notInQuery shape: { "className" => "X", "where" => {...} }
          embedded_class_name = val["className"]
          embedded_where = val["where"]
        end

        if embedded_class_name
          assert_embedded_class_accessible!(op, embedded_class_name, agent: agent)
        end

        # Recursively translate the inner where clause so denied
        # operators inside it surface immediately.
        #
        # NOTE: `translate`'s second parameter is POSITIONAL (see the
        # signature comment at line 149-153 for the Ruby-3 kwargs
        # rationale). Passing `agent: agent` here would bundle the
        # agent into a Hash literal `{agent: <Parse::Agent>}` and pass
        # that Hash as the positional `agent` argument, so the inner
        # `assert_embedded_class_accessible!` would call
        # `Tools.assert_class_accessible!(class_name, agent: <Hash>)`
        # — the per-agent class-filter check then crashes on
        # `Hash#class_filter_permits?` and the `rescue StandardError`
        # wraps the NoMethodError as ConstraintSecurityError, silently
        # disabling the per-agent class filter on every nested
        # cross-class hop. Keep this call POSITIONAL.
        if embedded_where.is_a?(Hash)
          translated_where = translate(embedded_where, agent)
          new_val = val.dup
          if op == "$select" || op == "$dontSelect"
            query_part = new_val["query"].transform_keys(&:to_s)
            query_part["where"] = translated_where
            new_val["query"] = query_part
          else
            new_val["where"] = translated_where
          end
          val = new_val
        end

        # Then recursively walk the rest for depth/operator enforcement.
        translate_value(val, depth: depth, agent: agent)
      end

      # Hook into the agent-side accessibility check when the agent
      # module is loaded; in pure-unit contexts where +Parse::Agent::Tools+
      # has not been loaded, default to a no-op rather than raising —
      # the strict check is enforced wherever the agent dispatches.
      def assert_embedded_class_accessible!(op, class_name, agent: nil)
        if defined?(Parse::Agent::Tools) && Parse::Agent::Tools.respond_to?(:assert_class_accessible!)
          begin
            Parse::Agent::Tools.assert_class_accessible!(class_name, agent: agent)
          rescue Parse::Agent::AccessDenied
            # Preserve the original AccessDenied so the upstream rescue in
            # Parse::Agent#execute maps it to `error_code: :access_denied` with
            # the correct `denial_kind:` (`:hidden_class`, `:class_filter`, etc.)
            # in the audit payload. Wrapping it as ConstraintSecurityError would
            # collapse it to the generic `:security_blocked` code and erase the
            # SOC-relevant subcode.
            raise
          rescue StandardError => e
            raise ConstraintSecurityError.new(
              "SECURITY: operator '#{op}' references inaccessible className " \
              "'#{class_name}': #{e.message}",
              operator: op,
              reason: :cross_class_denied,
            )
          end
        end
      end

      # Check if hash represents a Parse type
      def parse_type?(hash)
        return false unless hash.is_a?(Hash)
        type = hash["__type"] || hash[:__type]
        %w[Pointer Date File GeoPoint Bytes Polygon Relation].include?(type)
      end

      # NEW-TOOLS-7: validate $regex / $options operands.
      #
      # MongoDB's regex engine is PCRE (not RE2), so adversarial patterns
      # with nested quantifiers (`(a+)+`, `(a*)*`, `(.|.)+`) cause
      # catastrophic backtracking — quadratic-to-exponential matching
      # cost per document. The agent surface lacks a per-pattern
      # complexity gate at the Mongo level, so refuse the worst shapes
      # at the SDK boundary. Three checks:
      #
      #   1. $regex must be a String. No Hash/Array/Numeric values.
      #   2. Pattern length ≤ MAX_REGEX_PATTERN_LENGTH (256 chars).
      #   3. Pattern must not match the nested-quantifier heuristic
      #      (REDOS_NESTED_QUANTIFIER_RE).
      #
      # For $options:
      #
      #   1. Must be a String.
      #   2. Length ≤ 8 (defensive — real-world usage is 0-3 chars).
      #   3. Every character must appear in ALLOWED_REGEX_OPTIONS (imx).
      #      The `s` (dot-all) flag is intentionally rejected.
      #
      # @raise [ConstraintSecurityError] on any rule violation.
      def assert_regex_operand_safe!(op, val)
        if op == "$regex"
          unless val.is_a?(String)
            raise ConstraintSecurityError.new(
              "$regex value must be a String (got #{val.class})",
              operator: op,
              reason: :invalid_regex,
            )
          end
          if val.length > MAX_REGEX_PATTERN_LENGTH
            raise ConstraintSecurityError.new(
              "$regex pattern length #{val.length} exceeds " \
              "#{MAX_REGEX_PATTERN_LENGTH} character cap. " \
              "Narrow the pattern (e.g. anchored prefix `^xyz`) or filter " \
              "via a non-regex constraint.",
              operator: op,
              reason: :regex_too_long,
            )
          end
          if REDOS_NESTED_QUANTIFIER_RE.match?(val)
            raise ConstraintSecurityError.new(
              "$regex pattern #{val.inspect} contains a nested quantifier " \
              "(`(...x+...)+` shape) that can trigger catastrophic " \
              "backtracking on MongoDB's PCRE engine. Rewrite the pattern " \
              "without nested quantifier groups.",
              operator: op,
              reason: :regex_redos,
            )
          end
        elsif op == "$options"
          unless val.is_a?(String)
            raise ConstraintSecurityError.new(
              "$options value must be a String (got #{val.class})",
              operator: op,
              reason: :invalid_regex,
            )
          end
          if val.length > 8
            raise ConstraintSecurityError.new(
              "$options string is suspiciously long (#{val.length} chars).",
              operator: op,
              reason: :invalid_regex,
            )
          end
          unrecognized = val.chars.reject { |c| ALLOWED_REGEX_OPTIONS.include?(c) }
          unless unrecognized.empty?
            raise ConstraintSecurityError.new(
              "$options contains disallowed flag(s) " \
              "#{unrecognized.uniq.inspect}. Allowed flags: " \
              "#{ALLOWED_REGEX_OPTIONS.chars.inspect}. The dot-all " \
              "`s` flag is intentionally rejected.",
              operator: op,
              reason: :invalid_regex,
            )
          end
        end
      end

      # Refuse field-name keys that reference internal Parse Server columns.
      # Applies to every top-level key in a where: constraint hash. Operators
      # ($xxx) bypass this check — they are validated separately by
      # validate_operator!.
      #
      # @param key [String] a non-operator constraint key.
      # @raise [ConstraintSecurityError] when the key is in DENIED_WHERE_KEYS
      #   or starts with a DENIED_WHERE_KEY_PREFIXES entry.
      def assert_where_key_permitted!(key)
        return if key.start_with?("$") # operators handled separately

        k = key.to_s
        if DENIED_WHERE_KEYS.include?(k) ||
           DENIED_WHERE_KEY_PREFIXES.any? { |prefix| k.start_with?(prefix) }
          raise ConstraintSecurityError.new(
            "SECURITY: Field key '#{k}' is an internal Parse Server column and " \
            "must not appear in a where: constraint. Querying against this field " \
            "creates an oracle that can exfiltrate credential or token data via " \
            "count deltas.",
            operator: k,
            reason: :denied_internal_field,
          )
        end
      end

      # Validate an operator is allowed (strict whitelist enforcement).
      #
      # @param op [String] the operator to validate
      # @raise [ConstraintSecurityError] if operator is blocked
      # @raise [InvalidOperatorError] if operator is unknown
      def validate_operator!(op)
        op_str = op.to_s

        # Check blocklist FIRST - these are security violations
        if BLOCKED_OPERATORS.include?(op_str)
          raise ConstraintSecurityError.new(
            "SECURITY: Operator '#{op_str}' is blocked - it allows arbitrary code execution. " \
            "This operator is not allowed regardless of permission level.",
            operator: op_str,
            reason: :code_execution,
          )
        end

        # Strict whitelist validation - reject anything unknown
        unless ALLOWED_OPERATORS.include?(op_str)
          raise InvalidOperatorError.new(
            "Unknown query operator '#{op_str}' is not allowed. " \
            "Allowed operators: #{ALLOWED_OPERATORS.join(", ")}",
            operator: op_str,
          )
        end
      end

      # Convert field name to Parse column format (camelCase with lowercase first letter)
      # Matches Parse::Query.field_formatter behavior
      def columnize(field)
        return field if field.start_with?("_") # Preserve special fields like _User

        # Convert snake_case to camelCase
        field.to_s.gsub(/_([a-z])/) { ::Regexp.last_match(1).upcase }
             .sub(/^([A-Z])/) { ::Regexp.last_match(1).downcase }
      end
    end
  end
end
