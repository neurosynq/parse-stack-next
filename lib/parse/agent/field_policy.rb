# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # Per-agent field narrowing.
    #
    # A class's `agent_fields` declaration is the CEILING: the most any agent
    # may read. A `Parse::Agent.new(fields: { "Post" => [:title, :status] })`
    # policy NARROWS that ceiling for one agent (one MCP deployment), so a
    # user-facing assistant and an analytics endpoint in the same process can
    # expose different subsets of the same model. A policy can never widen
    # past the ceiling, and a sub-agent's policy intersects its parent's.
    #
    # The effective allowlist is resolved by
    # {Parse::Agent::MetadataRegistry.field_allowlist}, which every
    # enforcement point already calls (projection, `where:`/`keys:` checks,
    # aggregation pipelines, Atlas Search fields, schema output, exports,
    # `semantic_search` chunk text). This module supplies the narrowing for
    # the agent whose tool is currently executing: {Parse::Agent::Tools.invoke}
    # wraps every tool call in {.with}, so the policy applies without
    # threading the agent through each helper.
    #
    # The scope is fiber-local (`Thread.current[]`), and tools run on the
    # calling fiber (`Timeout.timeout` yields in place), so concurrent
    # requests on different threads never see each other's policy.
    module FieldPolicy
      SCOPE_KEY = :parse_agent_field_policy_scope

      module_function

      # Run the block with `agent`'s field narrowing in effect.
      #
      # @param agent [Parse::Agent, nil]
      # @return the block's value
      def with(agent)
        previous = Thread.current[SCOPE_KEY]
        Thread.current[SCOPE_KEY] = agent
        yield
      ensure
        Thread.current[SCOPE_KEY] = previous
      end

      # @return [Parse::Agent, nil] the agent whose tool is executing.
      def current_agent
        Thread.current[SCOPE_KEY]
      end

      # Wire-format field names the current agent narrows `class_name` to, or
      # nil when the agent places no narrowing on that class (or no agent is
      # in scope).
      #
      # @param class_name [String]
      # @return [Array<String>, nil]
      def narrowing_for(class_name)
        agent = current_agent
        return nil unless agent.respond_to?(:field_narrowing_for)
        agent.field_narrowing_for(class_name)
      end
    end
  end
end
