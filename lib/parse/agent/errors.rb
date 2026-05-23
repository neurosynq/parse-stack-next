# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # Error hierarchy for agent operations.
    #
    # Defined in a standalone file so the MCP transport layer
    # (Parse::Agent::MCPRackApp, Parse::Agent::MCPDispatcher) can rescue
    # these classes without transitively loading the full Parse::Agent
    # implementation. A downstream Rack mount only needs to know that
    # `raise Parse::Agent::Unauthorized` works.

    # Base error class for all agent errors
    class AgentError < StandardError; end

    # Security-related errors (blocked operations, injection attempts).
    # These should NEVER be swallowed - always re-raise.
    class SecurityError < AgentError; end

    # Validation errors for invalid input
    class ValidationError < AgentError; end

    # Timeout errors for long-running operations
    class ToolTimeoutError < AgentError
      attr_reader :tool_name, :timeout

      def initialize(tool_name, timeout)
        @tool_name = tool_name
        @timeout = timeout
        super("Tool '#{tool_name}' timed out after #{timeout} seconds")
      end
    end

    # Raised by agent tools when a request targets a Parse class that has
    # been marked `agent_hidden` (see Parse::Agent::MetadataDSL). The
    # rescue path in Parse::Agent#execute translates this to a
    # `:access_denied` error_response without leaking the class name to
    # the wire beyond the sanitized message the caller used.
    class AccessDenied < AgentError
      attr_reader :class_name, :kind, :denied_field, :allowed_fields, :suggested_rewrite

      # @param class_name [String, nil] the Parse class being refused. May be
      #   nil when the denial is not class-scoped (e.g., an env-gate refusal
      #   triggered by a `call_method` invocation of a :write method).
      # @param message [String, nil] optional override for the message. When
      #   not provided, a default "Class 'X' is not accessible to this agent"
      #   message is used.
      # @param kind [Symbol, nil] a finer-grained denial subcode. Lets MCP
      #   consumers branch on the specific refusal reason without parsing
      #   prose. Known values:
      #     :hidden_class            — target class is `agent_hidden`
      #     :field_denied            — projection/sort/match/expr field is
      #                                outside the class's `agent_fields`
      #                                allowlist
      #     :storage_form_field_ref  — same as :field_denied but the
      #                                offending name is the Parse-on-Mongo
      #                                storage column (`_p_*`); the rewrite
      #                                hint points at the bare pointer name
      # @param denied_field [String, nil] the offending column / field name
      #   when the refusal is field-scoped. Nil for class-scoped denials.
      # @param allowed_fields [Array<String>, nil] the class's effective
      #   `agent_fields` allowlist (capped for wire compactness). Nil when
      #   the refusal is not field-scoped.
      # @param suggested_rewrite [String, nil] a one-shot rewrite suggestion
      #   the caller can apply to fix the request. Currently emitted for
      #   storage-form references (e.g., "use `$author` instead of `$_p_author`").
      def initialize(class_name = nil, message = nil,
                     kind: nil, denied_field: nil, allowed_fields: nil,
                     suggested_rewrite: nil)
        @class_name        = class_name.to_s
        @kind              = kind
        @denied_field      = denied_field
        @allowed_fields    = allowed_fields&.map(&:to_s)
        @suggested_rewrite = suggested_rewrite
        super(message || "Class '#{@class_name}' is not accessible to this agent")
      end

      # Structured details for the error_response payload. Returns a Hash
      # with only the populated keys so the wire envelope doesn't carry
      # unused nil fields.
      def to_details
        {
          kind:              kind,
          denied_field:      denied_field,
          allowed_fields:    allowed_fields,
          suggested_rewrite: suggested_rewrite,
        }.compact
      end
    end

    # Authentication failure for MCP transport adapters. Custom auth blocks
    # passed to Parse::Agent::MCPRackApp should raise this (or a subclass) to
    # signal an unauthenticated/unauthorized request; the transport layer
    # catches it and renders a sanitized 401 response.
    class Unauthorized < AgentError
      attr_reader :reason

      def initialize(message = "Unauthorized", reason: nil)
        @reason = reason
        super(message)
      end
    end

    # Raised at construction when an agent built with `parent:` would
    # exceed the inherited recursion depth budget. Defends against
    # delegate_to_subagent (or any tool that constructs a Parse::Agent
    # inside its handler) recursing without bound.
    #
    # The budget is decremented on every inherited construction; the
    # zero-floor agent can still execute its own tools, but constructing
    # another sub-agent with `parent: zero_floor_agent` raises this error.
    class RecursionLimitExceeded < AgentError
      attr_reader :depth

      def initialize(message = nil, depth: nil)
        @depth = depth
        super(message || "Parse::Agent recursion depth exhausted (depth=#{depth.inspect}). " \
                          "A sub-agent attempted to construct another sub-agent past the " \
                          "configured recursion_depth: cap.")
      end
    end

    # Raised inside the +call_method+ tool when the resolved
    # +ClassName.method_name+ is excluded by the agent instance's
    # +methods:+ filter. The execute() rescue maps this to a
    # +:tool_filtered+ error_code so consumers can distinguish "the
    # filter excluded this method" from "this method isn't declared
    # agent-callable" (a Parse::Error) or "the tier doesn't allow it"
    # (a +:permission_denied+).
    class MethodFiltered < AgentError; end
  end
end
