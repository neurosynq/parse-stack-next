# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # Validates MongoDB aggregation pipelines to prevent security vulnerabilities.
    #
    # Enforces a strict whitelist of allowed aggregation stages and blocks
    # dangerous stages that can write data or execute arbitrary code.
    #
    # @example
    #   Parse::Agent::PipelineValidator.validate!([
    #     { "$match" => { "status" => "active" } },
    #     { "$group" => { "_id" => "$category", "count" => { "$sum" => 1 } } }
    #   ])
    #   # => true
    #
    #   Parse::Agent::PipelineValidator.validate!([{ "$out" => "hacked" }])
    #   # => raises PipelineSecurityError
    #
    module PipelineValidator
      extend self

      # Security error for blocked or dangerous pipeline operations
      class PipelineSecurityError < SecurityError
        attr_reader :stage, :reason

        def initialize(message, stage: nil, reason: nil)
          @stage = stage
          @reason = reason
          super(message)
        end
      end

      # Stages that are ALWAYS blocked - they can write data or execute code
      # These are blocked regardless of permission level
      BLOCKED_STAGES = %w[
        $out
        $merge
        $function
        $accumulator
        $collMod
        $createIndex
        $dropIndex
      ].freeze

      # Whitelist of safe read-only aggregation stages
      ALLOWED_STAGES = %w[
        $match
        $group
        $sort
        $project
        $limit
        $skip
        $unwind
        $lookup
        $count
        $addFields
        $set
        $unset
        $bucket
        $bucketAuto
        $facet
        $sample
        $sortByCount
        $replaceRoot
        $replaceWith
        $redact
        $graphLookup
        $unionWith
      ].freeze

      # Maximum pipeline depth to prevent DoS via deeply nested structures
      MAX_PIPELINE_DEPTH = 10

      # Maximum number of stages to prevent resource exhaustion
      MAX_STAGES = 20

      # Validate an aggregation pipeline for security issues.
      #
      # @param pipeline [Array<Hash>] the aggregation pipeline stages
      # @raise [PipelineSecurityError] if pipeline contains blocked or unknown stages
      # @return [true] if pipeline is valid
      def validate!(pipeline)
        raise PipelineSecurityError.new(
          "Pipeline must be an array",
          reason: :invalid_type,
        ) unless pipeline.is_a?(Array)

        raise PipelineSecurityError.new(
          "Pipeline cannot be empty",
          reason: :empty_pipeline,
        ) if pipeline.empty?

        raise PipelineSecurityError.new(
          "Pipeline exceeds maximum #{MAX_STAGES} stages (got #{pipeline.size})",
          reason: :too_many_stages,
        ) if pipeline.size > MAX_STAGES

        pipeline.each_with_index do |stage, idx|
          validate_stage!(stage, idx)
        end

        true
      end

      # Check if a pipeline is valid without raising.
      #
      # @param pipeline [Array<Hash>] the aggregation pipeline
      # @return [Boolean] true if valid, false otherwise
      def valid?(pipeline)
        validate!(pipeline)
        true
      rescue PipelineSecurityError
        false
      end

      private

      # Validate a single pipeline stage
      def validate_stage!(stage, idx, depth: 0)
        raise PipelineSecurityError.new(
          "Stage #{idx} must be a Hash, got #{stage.class}",
          stage: idx,
          reason: :invalid_stage_type,
        ) unless stage.is_a?(Hash)

        raise PipelineSecurityError.new(
          "Stage #{idx} exceeds maximum nesting depth of #{MAX_PIPELINE_DEPTH}",
          stage: idx,
          reason: :max_depth_exceeded,
        ) if depth > MAX_PIPELINE_DEPTH

        stage.each do |key, value|
          key_str = key.to_s

          # Check for blocked stages FIRST - these are security violations
          if BLOCKED_STAGES.include?(key_str)
            raise PipelineSecurityError.new(
              "SECURITY: Stage '#{key_str}' is blocked - it can write data or execute code. " \
              "This stage is not allowed regardless of permission level.",
              stage: idx,
              reason: :blocked_stage,
            )
          end

          # Whitelist check for top-level stage operators
          if key_str.start_with?("$") && depth == 0
            unless ALLOWED_STAGES.include?(key_str)
              raise PipelineSecurityError.new(
                "Unknown aggregation stage '#{key_str}' is not in the allowed whitelist. " \
                "Allowed stages: #{ALLOWED_STAGES.join(", ")}",
                stage: idx,
                reason: :unknown_stage,
              )
            end
          end

          # Recursively validate nested structures for hidden blocked operators
          validate_nested!(value, idx, depth: depth + 1)
        end
      end

      # Recursively validate nested values for blocked operators
      def validate_nested!(value, stage_idx, depth:)
        raise PipelineSecurityError.new(
          "Stage #{stage_idx} exceeds maximum nesting depth of #{MAX_PIPELINE_DEPTH}",
          stage: stage_idx,
          reason: :max_depth_exceeded,
        ) if depth > MAX_PIPELINE_DEPTH

        case value
        when Hash
          value.each do |k, v|
            key_str = k.to_s

            # Block dangerous operators even when nested (e.g., inside $facet)
            if BLOCKED_STAGES.include?(key_str)
              raise PipelineSecurityError.new(
                "SECURITY: Nested operator '#{key_str}' is blocked in stage #{stage_idx}. " \
                "Blocked operators cannot be used anywhere in the pipeline.",
                stage: stage_idx,
                reason: :nested_blocked_stage,
              )
            end

            validate_nested!(v, stage_idx, depth: depth + 1)
          end
        when Array
          value.each { |v| validate_nested!(v, stage_idx, depth: depth + 1) }
        end
        # Primitives (String, Integer, etc.) are always safe
      end
    end
  end
end
