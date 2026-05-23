# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # Cooperative cancellation token used by Parse::Agent::MCPDispatcher
    # and Parse::Agent::MCPRackApp to signal in-flight tool calls that the
    # client wants to stop work.
    #
    # The token is cooperative — tools must poll `cancelled?` at safe
    # checkpoints (tool entry, after each Parse/Mongo roundtrip,
    # between chunks). A tool that is blocked inside a synchronous I/O
    # call will not observe the cancellation until the I/O returns.
    # The Ruby-level `Timeout.timeout` already wrapping every tool call
    # remains the hard upper bound on wasted work.
    #
    # Cancellation is triggered from two paths:
    #
    # 1. **SSE client disconnect.** `MCPRackApp::SSEBody#close` invokes
    #    `cancel!(reason: :client_disconnect)` on the token before
    #    killing the worker thread.
    # 2. **`notifications/cancelled` JSON-RPC notification.** A separate
    #    POST whose `params.requestId` matches an in-flight request
    #    trips the token associated with that request (after a session
    #    identity check — see MCPRackApp for details).
    #
    # @example Polling at a checkpoint
    #   def my_tool(agent, **)
    #     return cancelled_result if agent.cancelled?
    #     data = expensive_io_call
    #     return cancelled_result if agent.cancelled?
    #     transform_and_return(data)
    #   end
    #
    # @example Operator-facing cancel
    #   token = Parse::Agent::CancellationToken.new
    #   agent.cancellation_token = token
    #   # later, from another thread:
    #   token.cancel!(reason: :user_requested)
    class CancellationToken
      # @return [Symbol, String, nil] reason supplied to {#cancel!}, or nil
      #   if the token has not been cancelled.
      attr_reader :reason

      def initialize
        @cancelled = false
        @reason    = nil
        # Mutex protects the read-modify-write in {#cancel!} so a
        # concurrent cancel from notifications/cancelled and client
        # disconnect cannot lose a reason or partially update state.
        # The hot poll path (#cancelled?) reads the boolean ivar
        # directly — atomic on MRI and on each major Ruby
        # implementation we ship against.
        @mutex     = Mutex.new
      end

      # @return [Boolean] true once {#cancel!} has been called at least once.
      def cancelled?
        @cancelled
      end

      # Trip the token. Idempotent — subsequent calls are no-ops and do
      # not overwrite the original reason.
      #
      # @param reason [Symbol, String, nil] short tag identifying the
      #   trigger (e.g. `:client_disconnect`, `:notifications_cancelled`,
      #   `:user_requested`).
      # @return [Boolean] true if this call actually flipped the state,
      #   false if the token was already cancelled.
      def cancel!(reason: nil)
        @mutex.synchronize do
          return false if @cancelled
          @cancelled = true
          @reason    = reason
          true
        end
      end
    end
  end
end
