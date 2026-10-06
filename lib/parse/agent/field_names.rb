# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # Per-agent data-field naming mode for tool output.
    #
    # `Parse::Agent.new(field_names: :server)` asks for data fields in the
    # exact names Parse returns or the model declares through its
    # `field_map` (`createdAt`, `totalPlays`, `ExternalID`), with no
    # snake_case conversion anywhere a tool would otherwise apply one.
    # `:default` (or omitting the option) keeps every tool's existing output.
    #
    # Only data-field keys are affected. MCP protocol keys and SDK envelope
    # keys (`chunks`, `documents`, `object_id`, `next_call`, ...) keep their
    # contracts, and "server names" never means raw MongoDB storage columns
    # (`_p_author`, `_rperm`, `_session_token`). Naming is presentation only:
    # every access check (ACL/CLP, protectedFields, class and per-agent field
    # policies) resolves against canonical field identities before output.
    #
    # Like {FieldPolicy}, the mode is scoped fiber-locally around each tool
    # call by {Parse::Agent::Tools.invoke}, so concurrent agents with
    # different modes never see each other's setting and nothing global is
    # mutated.
    module FieldNames
      SCOPE_KEY = :parse_agent_field_names_scope

      module_function

      # Run the block with `agent`'s naming mode in effect.
      def with(agent)
        previous = Fiber[SCOPE_KEY]
        Fiber[SCOPE_KEY] = agent
        yield
      ensure
        Fiber[SCOPE_KEY] = previous
      end

      # @return [Symbol] `:server` or `:default` for the agent whose tool is
      #   executing; `:default` outside a tool call.
      def current_mode
        agent = Fiber[SCOPE_KEY]
        mode = agent.respond_to?(:field_names_mode) ? agent.field_names_mode : nil
        mode || :default
      end

      # @return [Boolean] true when the executing agent asked for server names.
      def server?
        current_mode == :server
      end
    end
  end
end
