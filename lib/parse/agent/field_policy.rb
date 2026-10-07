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
    # The scope lives in fiber storage (`Fiber[]`), which child fibers and
    # threads inherit when they are created. Concurrent requests on
    # different threads never see each other's policy, and work a custom
    # tool hands to a thread or fiber it starts stays narrowed.
    module FieldPolicy
      SCOPE_KEY = :parse_agent_field_policy_scope

      module_function

      # Run the block with `agent`'s field narrowing in effect.
      #
      # @param agent [Parse::Agent, nil]
      # @return the block's value
      #
      # Scopes nest: a tool that builds another agent and invokes it (even one
      # constructed without `parent:`) runs under BOTH policies, so the inner
      # call can only narrow further, never escape the outer agent's policy.
      def with(agent)
        previous = Fiber[SCOPE_KEY]
        Fiber[SCOPE_KEY] = (previous || []) + [agent]
        yield
      ensure
        Fiber[SCOPE_KEY] = previous
      end

      # @return [Parse::Agent, nil] the innermost agent whose tool is executing.
      def current_agent
        Fiber[SCOPE_KEY]&.last
      end

      # Wire-format field names the current agent narrows `class_name` to, or
      # nil when the agent places no narrowing on that class (or no agent is
      # in scope).
      #
      # @param class_name [String]
      # @return [Array<String>, nil]
      def narrowing_for(class_name)
        stack = Fiber[SCOPE_KEY]
        return nil if stack.nil? || stack.empty?
        result = nil
        stack.uniq.each do |agent|
          next unless agent.respond_to?(:field_narrowing_for)
          names = agent.field_narrowing_for(class_name)
          next if names.nil?
          result = result ? (result & names) : names
        end
        result
      end
    end
  end
end
