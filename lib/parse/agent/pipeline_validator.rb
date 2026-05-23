# encoding: UTF-8
# frozen_string_literal: true

require_relative "../pipeline_security"

module Parse
  class Agent
    # Validates MongoDB aggregation pipelines to prevent security vulnerabilities.
    #
    # Thin compatibility wrapper around {Parse::PipelineSecurity}. The
    # actual stage allowlist, operator denylist, depth cap, and recursive
    # walk live there; this module preserves the `Parse::Agent::PipelineValidator.validate!`
    # entry point and the `PipelineSecurityError` exception class for
    # callers that pin to them.
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

      # Security error for blocked or dangerous pipeline operations.
      # Wraps the unified {Parse::PipelineSecurity::Error} for callers
      # that have rescued this class specifically.
      class PipelineSecurityError < SecurityError
        attr_reader :stage, :reason, :operator

        def initialize(message, stage: nil, reason: nil, operator: nil)
          @stage = stage
          @reason = reason
          @operator = operator
          super(message)
        end
      end

      # Mirrors of the canonical constants in {Parse::PipelineSecurity},
      # preserved as constants here so external callers reading
      # `Parse::Agent::PipelineValidator::BLOCKED_STAGES` continue to work.
      BLOCKED_STAGES = Parse::PipelineSecurity::DENIED_OPERATORS
      ALLOWED_STAGES = Parse::PipelineSecurity::ALLOWED_STAGES
      MAX_PIPELINE_DEPTH = Parse::PipelineSecurity::MAX_DEPTH
      MAX_STAGES = Parse::PipelineSecurity::MAX_PIPELINE_STAGES

      # Validate an aggregation pipeline for security issues.
      # Delegates to {Parse::PipelineSecurity.validate_pipeline!} and
      # translates its error into {PipelineSecurityError} for backwards
      # compatibility.
      #
      # @param pipeline [Array<Hash>] the aggregation pipeline stages
      # @raise [PipelineSecurityError] if pipeline contains blocked or unknown stages
      # @return [true] if pipeline is valid
      def validate!(pipeline)
        Parse::PipelineSecurity.validate_pipeline!(pipeline)
      rescue Parse::PipelineSecurity::Error => e
        raise PipelineSecurityError.new(
          e.message,
          stage: e.stage,
          reason: e.reason,
          operator: e.operator,
        )
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
    end
  end
end
