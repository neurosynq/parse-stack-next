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
        $near $geoWithin $geoIntersects
        $centerSphere $box $polygon
        $relatedTo $inQuery $notInQuery
        $containedIn $containsAll
        $select $dontSelect
        $or $and $nor
      ].freeze

      # Maximum query depth to prevent DoS via deeply nested structures
      MAX_QUERY_DEPTH = 8

      # Translate JSON constraints to Parse query format.
      # Validates all operators against the security whitelist.
      #
      # @param constraints [Hash] the query constraints from LLM
      # @raise [ConstraintSecurityError] if blocked operators are used
      # @raise [InvalidOperatorError] if unknown operators are used
      # @return [Hash] translated constraints for Parse REST API
      def translate(constraints)
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
          result[columnize(key)] = translate_value(value, depth: 0)
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
      def translate_value(value, depth:)
        raise InvalidOperatorError.new(
          "Query exceeds maximum depth of #{MAX_QUERY_DEPTH}",
          operator: nil,
        ) if depth > MAX_QUERY_DEPTH

        case value
        when Hash
          translate_hash_value(value, depth: depth)
        when Array
          value.map { |v| translate_value(v, depth: depth + 1) }
        else
          value
        end
      end

      # Translate a hash value (could be operators or a pointer/object)
      def translate_hash_value(hash, depth:)
        # Check if it's a Parse type (Pointer, Date, File, GeoPoint)
        return hash if parse_type?(hash)

        # Check if all keys are operators
        if hash.keys.all? { |k| k.to_s.start_with?("$") }
          hash.transform_keys(&:to_s).each_with_object({}) do |(op, val), result|
            validate_operator!(op)
            result[op] = translate_value(val, depth: depth + 1)
          end
        else
          # Regular nested object - translate keys to columnized format
          hash.transform_keys { |k| columnize(k.to_s) }
              .transform_values { |v| translate_value(v, depth: depth + 1) }
        end
      end

      # Check if hash represents a Parse type
      def parse_type?(hash)
        return false unless hash.is_a?(Hash)
        type = hash["__type"] || hash[:__type]
        %w[Pointer Date File GeoPoint Bytes Polygon Relation].include?(type)
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
