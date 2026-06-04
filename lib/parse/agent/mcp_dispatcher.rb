# encoding: UTF-8
# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "prompts"

module Parse
  class Agent
    # Pure JSON-RPC dispatch layer for the MCP protocol.
    #
    # MCPDispatcher translates an already-parsed JSON-RPC request body into a
    # JSON-RPC response envelope without touching any I/O, HTTP transport, or
    # authentication. Callers are responsible for:
    #   - Parsing the raw request body into a Hash.
    #   - Authenticating the request and constructing a Parse::Agent instance.
    #   - Serializing the returned Hash back to JSON and writing it to the wire.
    #
    # This design lets the same dispatch logic serve WEBrick (MCPServer),
    # Rack (MCPRackApp), and in-process tests without duplication.
    #
    # @example Basic usage
    #   body  = JSON.parse(raw_request_body)
    #   agent = Parse::Agent.new(permissions: :readonly)
    #   result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent)
    #   # => { status: 200, body: { "jsonrpc" => "2.0", "id" => 1, "result" => {...} } }
    #
    module MCPDispatcher
      # MCP protocol version advertised in the `initialize` handshake.
      # Matches MCPServer::PROTOCOL_VERSION.
      #
      # Bumped from 2024-11-05 to 2025-06-18 in v4.2 alongside tool-internal
      # progress reporting. The changes from 2024-11-05 → 2025-06-18 that
      # affect the surface this gem implements are all additive:
      #   - notifications/progress accepts an optional `message` field
      #     (2025-03-26).
      #   - Tool descriptors may carry `annotations`, `outputSchema`, and
      #     tool results may carry `structuredContent` / resource links
      #     (2025-06-18). The dispatcher does not emit these fields — they
      #     are forward-compatible no-ops.
      #
      # Clients negotiating an older version (e.g. 2024-11-05-only) will
      # still interpret the `initialize` capability shape and supported
      # methods correctly; the wire-level differences only matter for the
      # additive fields above.
      PROTOCOL_VERSION = "2025-06-18"

      # Protocol versions the dispatcher is willing to negotiate. Per the
      # MCP lifecycle spec the server MUST echo the client's requested
      # version when supported, or fall back to a version it does
      # support. This list reflects the versions whose wire shape and
      # method set are compatible with the handlers below — additions
      # from 2024-11-05 → 2025-06-18 are all additive and forward-
      # compatible no-ops for older clients.
      SUPPORTED_PROTOCOL_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze

      # Server capability advertisement (mirrors MCPServer::CAPABILITIES).
      #
      # `tools.listChanged` and `prompts.listChanged` are advertised as
      # true in v4.2: Parse::Agent::MCPRackApp's SSEBody subscribes to
      # Parse::Agent::Tools.subscribe and Parse::Agent::Prompts.subscribe
      # and broadcasts `notifications/tools/list_changed` /
      # `notifications/prompts/list_changed` onto every live SSE stream
      # when an application calls `Tools.register`,
      # `Tools.reset_registry!`, `Prompts.register`, or
      # `Prompts.reset_registry!` at runtime. Standalone MCPServer
      # callers (WEBrick, no streaming) cannot receive notifications;
      # they still see the latest registry state on the next
      # `tools/list` / `prompts/list` poll.
      CAPABILITIES = {
        "tools"     => { "listChanged" => true  },
        "resources" => { "subscribe"   => false, "listChanged" => false },
        "prompts"   => { "listChanged" => true  },
      }.freeze

      # Parse class-name identifier regex — used to validate resource URIs.
      # Matches Parse's class-name convention: letter/underscore start, up to 128
      # chars, alphanumeric/underscore body.
      IDENTIFIER_RE = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze

      # Maximum serialized response body for a single tools/call. Prevents a
      # wide-schema query with limit=1000 from producing tens of megabytes
      # of JSON before the response is written. When exceeded, the dispatcher
      # returns an isError tool result instructing the client to narrow the
      # query, NOT a JSON-RPC transport error.
      MAX_TOOL_RESPONSE_BYTES = 4_194_304  # 4 MiB

      # Dispatch a JSON-RPC request body to the appropriate handler.
      #
      # @param body [Hash] already-parsed JSON-RPC request body with string keys.
      #   Expected shape: { "jsonrpc" => "2.0", "method" => String,
      #                     "params"  => Hash,   "id"     => Any }
      # @param agent [Parse::Agent] an authenticated agent instance.
      # @return [Hash] always `{ status: Integer, body: Hash }`.
      #   `status` is the HTTP status code (200 for all successful dispatches,
      #   including JSON-RPC `error` responses; 401 only for Unauthorized).
      #   `body` is the full JSON-RPC response envelope (string keys) containing
      #   `"jsonrpc"`, `"id"`, and either `"result"` or `"error"`.
      #
      # @raise nothing — all exceptions are caught and translated to error envelopes.
      #
      # Error codes used:
      #   -32700  Parse error        (body is not a Hash or missing "method")
      #   -32601  Method not found   (unknown method name)
      #   -32602  Invalid params     (bad arguments, SecurityError, ValidationError)
      #   -32603  Internal error     (unexpected StandardError — class name only, no message)
      #   -32001  Unauthorized       (Parse::Agent::Unauthorized) → HTTP 401
      #
      # @note Parse::Agent::Prompts contract observed from prompts.rb:
      #   `Prompts.list` returns an Array of prompt descriptor Hashes (builtins
      #   merged with any registered custom prompts).
      #   `Prompts.render(name, args)` returns the full MCP envelope Hash
      #   `{ "description" => String, "messages" => [...] }` — already shaped.
      #   It raises `Parse::Agent::ValidationError` for unknown prompt names and
      #   for missing/invalid required arguments. The dispatcher passes the
      #   envelope through as-is and lets rescue handle ValidationError → -32602.
      # @param logger [#warn, nil] optional logger for internal errors. When
      #   not provided, falls back to `Kernel#warn` → $stderr. Wire from the
      #   transport layer (MCPRackApp forwards its logger here automatically).
      # @param progress_callback [#call, nil] callback the dispatcher
      #   installs on the agent for the duration of the request, so tools
      #   can emit MCP `notifications/progress` events via
      #   `agent.report_progress(...)`. Set by Parse::Agent::MCPRackApp on
      #   the SSE path; nil for the JSON path. The callback signature is
      #   `call(progress:, total:, message:)` (keyword args), and it is
      #   cleared from the agent in an ensure block before this method
      #   returns.
      # @param cancellation_token [Parse::Agent::CancellationToken, nil]
      #   cooperative cancellation token the dispatcher installs on the
      #   agent for the duration of the request. Tools check
      #   `agent.cancelled?` at safe checkpoints; cancelled tool results
      #   are translated into a JSON-RPC `isError` content envelope by
      #   {#handle_tools_call}. Cleared from the agent in an ensure block
      #   before this method returns.
      # @param subscription_manager [Parse::Agent::MCPSubscriptions::Manager, nil]
      #   the per-transport resource-subscription coordinator. When present and
      #   {Parse::Agent::MCPSubscriptions::Manager#supported? supported}, the
      #   `initialize` handshake advertises the `resources.subscribe` capability
      #   and `resources/subscribe` / `resources/unsubscribe` are routed to it.
      #   nil (the default, and the only option on non-streaming transports like
      #   the WEBrick MCPServer) leaves the capability unadvertised and those
      #   methods returning a "not supported" error.
      def self.call(body:, agent:, logger: nil, progress_callback: nil, cancellation_token: nil,
                    subscription_manager: nil, approval_gate: nil)
        # Snapshot any prior callback/token already on the agent (e.g. a
        # token a parent dispatcher installed before a tool handler
        # invoked us recursively, or values pre-set by the application).
        # We restore these in the ensure block so we never clobber state
        # we did not install. Without snapshot-restore, two interleaved
        # dispatches on the same shared agent would race: the second
        # request's ensure would null the first request's still-needed
        # token.
        prev_progress_callback   = agent.progress_callback   if agent.respond_to?(:progress_callback)
        prev_cancellation_token  = agent.cancellation_token  if agent.respond_to?(:cancellation_token)
        prev_approval_gate       = agent.approval_gate        if agent.respond_to?(:approval_gate)

        # Install the progress callback and cancellation token on the
        # agent for the duration of the dispatch. Cleared in the ensure
        # block below so a per-request agent that is recycled (or
        # accidentally retained) never carries a stale callback or token
        # across requests.
        #
        # Note: a single Parse::Agent instance is NOT safe to drive from
        # two threads concurrently — the snapshot-restore pattern here
        # only handles sequential interleave. MCPRackApp's `agent_factory:`
        # is documented to return a fresh agent per request.
        agent.progress_callback   = progress_callback   if progress_callback   && agent.respond_to?(:progress_callback=)
        agent.cancellation_token  = cancellation_token  if cancellation_token  && agent.respond_to?(:cancellation_token=)
        # Install the per-session approval gate (MCP elicitation) so
        # agent.execute can request human approval for destructive tools.
        # Restored in the ensure block like the other per-request state.
        agent.approval_gate       = approval_gate        if approval_gate       && agent.respond_to?(:approval_gate=)

        # Guard: body must be a Hash with a "method" key.
        unless body.is_a?(Hash) && body.key?("method")
          id = body.is_a?(Hash) ? body["id"] : nil
          return { status: 200, body: jsonrpc_error(id, -32700, "Invalid Request") }
        end

        method = body["method"]
        params = body["params"] || {}
        id     = body["id"]

        # JSON-RPC notifications MUST NOT carry an `id` field. Reject
        # `notifications/*` methods that include one — silently treating
        # them as no-op notifications leaves a client expecting a
        # response hanging until its read timeout.
        if method.is_a?(String) && method.start_with?("notifications/") && body.key?("id") && !id.nil?
          return { status: 200, body: jsonrpc_error(id, -32600, "Invalid Request: notifications must not carry an id") }
        end

        result_hash = dispatch(method, params, agent, id, logger, subscription_manager)
        { status: result_hash[:status], body: result_hash[:body] }

      rescue Parse::Agent::Unauthorized => e
        { status: 401, body: jsonrpc_error(body.is_a?(Hash) ? body["id"] : nil, -32001, "Unauthorized") }
      rescue StandardError => e
        # Do not leak the exception class name (gem fingerprinting). Server-
        # side log goes to the injected logger when set, otherwise $stderr.
        log_internal_error(logger, e)
        { status: 200, body: jsonrpc_error(body.is_a?(Hash) ? body["id"] : nil, -32603, "Internal error") }
      ensure
        # Restore the prior callback/token state captured above. This
        # avoids clobbering a token installed by an outer scope when
        # this dispatch ran as a nested invocation, and avoids leaving
        # this request's token visible to a sibling dispatch on a
        # shared agent.
        if agent.respond_to?(:progress_callback=)
          agent.progress_callback  = prev_progress_callback
        end
        if agent.respond_to?(:cancellation_token=)
          agent.cancellation_token = prev_cancellation_token
        end
        if agent.respond_to?(:approval_gate=)
          agent.approval_gate = prev_approval_gate
        end
      end

      # Emit an internal-error diagnostic. The class+message are operator-only;
      # never reach the wire.
      def self.log_internal_error(logger, error)
        line = "[Parse::Agent::MCPDispatcher] #{error.class}: #{error.message}"
        if logger
          logger.warn(line)
        else
          warn line
        end
      end
      private_class_method :log_internal_error

      # ---------------------------------------------------------------------------
      # Private helpers
      # ---------------------------------------------------------------------------

      # Route the method string to its handler, wrap the result in a JSON-RPC
      # envelope, and return { status:, body: }.
      #
      # @api private
      def self.dispatch(method, params, agent, id, logger = nil, subscription_manager = nil)
        result = case method
          when "initialize"
            handle_initialize(params, subscription_manager)
          when "tools/list"
            handle_tools_list(params, agent)
          when "tools/call"
            handle_tools_call(params, agent)
          when "resources/list"
            handle_resources_list(params, agent)
          when "resources/templates/list"
            handle_resources_templates_list(params, agent)
          when "resources/read"
            handle_resources_read(params, agent)
          when "resources/subscribe"
            handle_resources_subscribe(params, agent, subscription_manager)
          when "resources/unsubscribe"
            handle_resources_unsubscribe(params, agent, subscription_manager)
          when "prompts/list"
            handle_prompts_list(params)
          when "prompts/get"
            handle_prompts_get(params)
          when "ping"
            {}
          when "notifications/cancelled"
            # JSON-RPC notification (no id, no response). The dispatcher
            # accepts this method as a recognized no-op so unknown-method
            # errors are not returned to callers that send it through the
            # standalone (non-Rack) transports. The actual cancellation
            # effect is implemented by Parse::Agent::MCPRackApp, which
            # special-cases the method before reaching the dispatcher to
            # consult its (correlation_id, request_id) registry and trip
            # the matching CancellationToken.
            { __notification__: true }
          when "notifications/initialized"
            # JSON-RPC notification sent by the client after the
            # `initialize` handshake completes. Per spec the server
            # performs no action and sends no response — the dispatcher
            # accepts the method as a recognized no-op so clients that
            # send it (Claude Desktop, MCP Inspector, etc.) do not see
            # a `-32601 Method not found` error.
            { __notification__: true }
          else
            return { status: 200, body: jsonrpc_error(id, -32601, "Method not found: #{method}") }
          end

        # JSON-RPC notifications carry no `id` and require no response.
        # Return a 200 with a nil body so the transport layer can write
        # an empty response (or, for the standalone MCPServer that always
        # writes the response, an empty JSON object).
        return { status: 200, body: nil } if result.is_a?(Hash) && result[:__notification__]

        # result is a Hash; if it carries an :error or "error" key the handler
        # wants a JSON-RPC error envelope, otherwise it's a result.
        err = result[:error] || result["error"]
        if err
          { status: 200, body: jsonrpc_envelope(id, error: err) }
        else
          { status: 200, body: jsonrpc_envelope(id, result: result) }
        end

      rescue Parse::Agent::Unauthorized => e
        { status: 401, body: jsonrpc_error(id, -32001, "Unauthorized") }
      rescue Parse::Agent::AccessDenied
        # Class-authorization denial (agent_hidden / classes: allowlist), e.g.
        # from the resources/subscribe gate. Map to -32602 with a generic
        # message — do NOT echo the class name, so a denied subscribe can't be
        # used to probe which hidden classes exist.
        { status: 200, body: jsonrpc_error(id, -32602, "Invalid params") }
      rescue Parse::Agent::SecurityError
        { status: 200, body: jsonrpc_error(id, -32602, "Invalid params") }
      rescue Parse::Agent::ValidationError => e
        { status: 200, body: jsonrpc_error(id, -32602, e.message) }
      rescue ArgumentError => e
        # ArgumentError from prompts/render (matches current handle_prompts_get behavior).
        { status: 200, body: jsonrpc_error(id, -32602, e.message) }
      rescue StandardError => e
        log_internal_error(logger, e)
        { status: 200, body: jsonrpc_error(id, -32603, "Internal error") }
      end
      private_class_method :dispatch

      # ---------------------------------------------------------------------------
      # Handlers — each returns a plain Hash that becomes the JSON-RPC `result`.
      # If the handler needs to signal a protocol-level error it returns a Hash
      # with an :error key (same convention as mcp_server.rb).
      # ---------------------------------------------------------------------------

      # Handle the `initialize` MCP handshake.
      #
      # Per the MCP lifecycle spec, the server MUST echo the client's
      # requested `protocolVersion` when it can support that version,
      # and SHOULD respond with another supported version otherwise so
      # the client can decide to proceed or disconnect. Strict clients
      # disconnect on a version they did not request — silently always
      # returning the server's preferred version locks those clients
      # out.
      #
      # @param subscription_manager [Parse::Agent::MCPSubscriptions::Manager, nil]
      #   when supported, flips the advertised `resources.subscribe` capability
      #   to true. See {#capabilities_for}.
      # @return [Hash] protocol version, capabilities, and server info.
      def self.handle_initialize(params, subscription_manager = nil)
        requested = params.is_a?(Hash) ? params["protocolVersion"] : nil
        negotiated =
          if requested.is_a?(String) && SUPPORTED_PROTOCOL_VERSIONS.include?(requested)
            requested
          else
            PROTOCOL_VERSION
          end
        {
          "protocolVersion" => negotiated,
          "capabilities"    => capabilities_for(subscription_manager),
          "serverInfo"      => {
            "name"    => "parse-stack-mcp",
            "version" => Parse::Stack::VERSION,
          },
        }
      end
      private_class_method :handle_initialize

      # Compute the advertised capability object for this transport.
      #
      # `resources.subscribe` is advertised as `true` ONLY when a subscription
      # manager is wired AND reports itself supported (LiveQuery enabled +
      # available, on a streaming transport that can hold a listening channel).
      # Advertising a capability is a contract: we never claim `subscribe: true`
      # unless the server can actually deliver `notifications/resources/updated`.
      # On the WEBrick MCPServer (no streaming) and on the Rack app when
      # subscriptions are disabled, this falls back to the base CAPABILITIES
      # with `subscribe: false`.
      #
      # @param manager [Parse::Agent::MCPSubscriptions::Manager, nil]
      # @return [Hash]
      def self.capabilities_for(manager)
        return CAPABILITIES unless manager.respond_to?(:supported?) && manager.supported?
        CAPABILITIES.merge(
          "resources" => CAPABILITIES["resources"].merge("subscribe" => true),
        )
      end
      private_class_method :capabilities_for

      # Handle `tools/list`.
      #
      # Accepts an optional non-standard `category` param (Parse Stack
      # extension). Vanilla MCP clients omit it and receive the full
      # allowed-tools list unchanged. Clients that know about the
      # extension can pass a category string ("schema", "query",
      # "aggregate", "mutation", "export", or any custom value) to
      # filter the response server-side. Tool descriptors always carry
      # `_meta.category` for client-side filtering as well.
      #
      # @param params [Hash] JSON-RPC params (optional `category`).
      # @param agent [Parse::Agent] used to retrieve allowed tool definitions.
      # @return [Hash] `{ "tools" => [...] }`
      def self.handle_tools_list(params, agent)
        category = params.is_a?(Hash) ? params["category"] : nil
        { "tools" => agent.tool_definitions(format: :mcp, category: category) }
      end
      private_class_method :handle_tools_list

      # Handle `tools/call`.
      #
      # Tool execution failures (agent returns `success: false`) are returned as
      # MCP tool errors (`isError: true` in content) — NOT as a JSON-RPC `error`
      # field. This matches the MCP spec distinction between protocol errors and
      # tool-level errors.
      #
      # @param agent [Parse::Agent] used to execute the named tool.
      # @return [Hash] MCP content envelope (always a `result`, never `error`).
      def self.handle_tools_call(params, agent)
        tool_name = params["name"]
        arguments = params["arguments"] || {}

        unless tool_name
          return { error: { "code" => -32602, "message" => "Missing tool name" } }
        end

        sym_args = arguments.transform_keys(&:to_sym)
        result   = agent.execute(tool_name.to_sym, **sym_args)

        # Cancellation short-circuit. Tools cooperate by returning a
        # `success: false, cancelled: true` envelope when `agent.cancelled?`
        # is observed at a checkpoint. The dispatcher additionally double-
        # checks `agent.cancelled?` after execute returns, catching the case
        # where the cancellation landed after the tool's last checkpoint
        # but before it returned (the tool finished its work normally; we
        # still honor the client's intent by not surfacing the result).
        if result[:cancelled] || (agent.respond_to?(:cancelled?) && agent.cancelled?)
          return {
            "content" => [
              { "type" => "text", "text" => (result[:error] || "Cancelled by client").to_s },
            ],
            "isError"   => true,
            "cancelled" => true,
          }
        end

        if result[:success]
          text = JSON.pretty_generate(result[:data])
          if text.bytesize > MAX_TOOL_RESPONSE_BYTES
            # For row-shaped and hash-of-records tool results, try to recover
            # with a partial success: drop the heaviest field from all rows
            # (and trailing rows/records if needed) and annotate the response
            # with a _truncated block. Models handle partial success much
            # better than full refusal — they continue the task instead of
            # restarting. Other tools fall through to the structural refusal.
            recovered_text =
              if %w[query_class get_objects aggregate].include?(tool_name)
                attempt_truncate_response(result[:data], MAX_TOOL_RESPONSE_BYTES, tool_name)
              end

            if recovered_text
              {
                "content" => [
                  { "type" => "text", "text" => recovered_text },
                ],
                "isError" => false,
              }
            else
              # Refuse oversized tool results structurally — give the LLM
              # client a clear signal to narrow the request instead of silently
              # buffering tens of MB. isError: true (not a JSON-RPC error) so
              # the model can adapt mid-loop.
              diagnosis = diagnose_oversize(result[:data])
              msg = +"Tool result exceeded #{MAX_TOOL_RESPONSE_BYTES} bytes (#{text.bytesize})."
              msg << " #{diagnosis}" if diagnosis
              msg << " Narrow the query: lower limit:, project fewer fields via keys:/select:, or add stricter where: constraints."
              {
                "content" => [
                  { "type" => "text", "text" => msg },
                ],
                "isError" => true,
              }
            end
          else
            envelope = {
              "content" => [
                { "type" => "text", "text" => text },
              ],
              "isError" => false,
            }
            # MCP 2025-06-18 structured output: when the tool declared
            # an outputSchema via Tools.register(..., output_schema:),
            # mirror the result data as `structuredContent`. The text
            # content stays as the human-readable representation; the
            # structured form is the machine-readable truth.
            if Parse::Agent::Tools.output_schema_for(tool_name)
              envelope["structuredContent"] = result[:data]
            end
            envelope
          end
        else
          {
            "content" => [
              { "type" => "text", "text" => result[:error].to_s },
            ],
            "isError" => true,
          }
        end
      end
      private_class_method :handle_tools_call

      # Sample the tool's result envelope and produce a one-line diagnostic
      # naming the fields that contribute the most bytes per record. Returns
      # nil if the data shape isn't amenable to per-field analysis. Called
      # only on the oversize-refusal path — sampling cost is acceptable
      # because the request is already failing.
      #
      # Invariants the sampler relies on (must hold by construction in
      # Parse::Agent::Tools before the result reaches the dispatcher):
      #   1. `redact_hidden_classes!` has already walked the rows and
      #      replaced embedded objects whose className matches a hidden
      #      class with a `{className, __redacted: true}` placeholder. The
      #      sampler therefore cannot fingerprint hidden-class field
      #      contents via byte sizing.
      #   2. The `agent_fields` allowlist has already projected the rows so
      #      that disallowed fields are not present. The byte-per-field
      #      breakdown therefore covers only fields the caller was already
      #      permitted to see.
      #
      # @api private
      def self.diagnose_oversize(data)
        return nil unless data.is_a?(Hash)

        # export_data short-circuit: without per-column byte sampling, an
        # unranked column list is actively misleading — models read
        # left-to-right as a size ordering. Return nil and let the generic
        # narrowing guidance carry the message.
        return nil if data[:output].is_a?(String) && data[:headers].is_a?(Array)

        rows =
          if data[:results].is_a?(Array)         then data[:results]
          elsif data["results"].is_a?(Array)     then data["results"]
          elsif data[:objects].is_a?(Hash)       then data[:objects].values
          elsif data["objects"].is_a?(Hash)      then data["objects"].values
          elsif data[:object].is_a?(Hash)        then [data[:object]]
          elsif data["object"].is_a?(Hash)       then [data["object"]]
          end

        return nil unless rows.is_a?(Array) && rows.any?

        sample = rows.first(5).select { |r| r.is_a?(Hash) }
        return nil if sample.empty?

        bytes_per_field = Hash.new(0)
        sample.each do |row|
          row.each do |k, v|
            bytes_per_field[k.to_s] += v.to_json.bytesize
          rescue StandardError, SystemStackError
            # Unserializable value or pointer-cycle recursion limit — skip
            # the field rather than fail the diagnostic.
            next
          end
        end

        return nil if bytes_per_field.empty?

        sorted    = bytes_per_field.sort_by { |_, b| -b }
        top       = sorted.first(3)
        n         = sample.size.to_f
        largest   = sorted.first[0]

        # Produce a POSITIVE keys: list rather than asking the LLM to
        # subtract. `keys:` is inclusive — models that see "excluding 'X'"
        # sometimes emit Mongo-style `keys: "-X"` (wrong) or drop keys:
        # altogether (worse). Constructing a complete keep-list removes
        # that retry misfire entirely.
        keep_fields = bytes_per_field.keys - [largest]
        keep_fields = (keep_fields | TRUNCATION_ALWAYS_KEEP).uniq

        formatted = top.map { |k, b| "#{k} (~#{humanize_bytes(b / n)}/record)" }.join(", ")
        "Largest fields by bytes: #{formatted}. " \
          "Try keys: #{keep_fields.join(",").inspect} (drops the heaviest field)."
      end
      private_class_method :diagnose_oversize

      # Fields that should always be retained in any `keys:` projection.
      # objectId is required for pointer dereferencing and follow-up
      # `get_object` calls; createdAt/updatedAt are nearly free and almost
      # always wanted.
      # @api private
      TRUNCATION_ALWAYS_KEEP = %w[objectId createdAt updatedAt].freeze
      private_constant :TRUNCATION_ALWAYS_KEEP

      # Identify the heaviest field by total bytes across a sample of rows.
      # Returns the field name as a String, or nil if no fields can be sized.
      #
      # Rescues SystemStackError on cyclic hashes so one bad row never aborts
      # the whole diagnostic.
      #
      # @api private
      def self.find_heaviest_field(sample_rows)
        bytes_per_field = Hash.new(0)
        sample_rows.each do |row|
          next unless row.is_a?(Hash)
          row.each do |k, v|
            bytes_per_field[k.to_s] += v.to_json.bytesize
          rescue StandardError, SystemStackError
            next
          end
        end
        return nil if bytes_per_field.empty?

        bytes_per_field.max_by { |_, b| b }.first
      end
      private_class_method :find_heaviest_field

      # Try to recover from an oversize tool response by dropping the heaviest
      # field from every row (and trailing rows/records if the field alone
      # isn't enough). Returns the serialized recovered text on success, or
      # nil if the response can't fit even one row/record.
      #
      # Branches on data shape:
      #   - data[:results].is_a?(Array)   → row-array path (query_class, aggregate)
      #   - data[:objects].is_a?(Hash)    → hash-of-records path (get_objects)
      #
      # The recovered payload includes a `_truncated` annotation block so
      # an LLM client can detect the partial-success path and continue:
      #   - reason         — fixed string identifying the trigger
      #   - dropped_fields — array of field names removed from every row/record
      #   - kept_count     — rows/records actually emitted
      #   - original_count — rows/records the underlying tool produced
      #   - next_skip      — (query_class only) set when rows were dropped; pass
      #     this as `skip:` to resume pagination through the same dataset
      #   - dropped_for_size — (get_objects only) IDs moved out of `objects`
      #     because even the field-trimmed records didn't fit within the cap
      #   - hint           — short instruction telling the model how to
      #     recover the dropped field for a specific record
      #
      # @param data [Hash] the tool's result[:data] hash.
      # @param max_bytes [Integer] byte cap for the serialized response.
      # @param tool_name [String] caller tool name — drives hint wording
      #   and whether next_skip pagination applies.
      # @return [String, nil] recovered JSON text, or nil if unrecoverable.
      # @api private
      def self.attempt_truncate_response(data, max_bytes, tool_name)
        return nil unless data.is_a?(Hash)

        if (data[:results] || data["results"]).is_a?(Array)
          attempt_truncate_row_array(data, max_bytes, tool_name)
        elsif (data[:objects] || data["objects"]).is_a?(Hash)
          attempt_truncate_objects_hash(data, max_bytes)
        end
      end
      private_class_method :attempt_truncate_response

      # Row-array recovery path for query_class and aggregate.
      # @api private
      def self.attempt_truncate_row_array(data, max_bytes, tool_name)
        rows = data[:results] || data["results"]
        return nil unless rows.is_a?(Array) && rows.any?

        sample   = rows.first(5).select { |r| r.is_a?(Hash) }
        return nil if sample.empty?

        heaviest = find_heaviest_field(sample)
        return nil unless heaviest

        # Drop the heaviest field from every row (shallow copy — leaves
        # the caller's original hashes untouched).
        trimmed_rows = rows.map do |row|
          row.is_a?(Hash) ? row.reject { |k, _| k.to_s == heaviest } : row
        end

        # Read the caller's effective skip so next_skip can resume rather
        # than reset pagination. Only relevant for query_class; aggregate
        # pipelines are deterministic and not paginatable.
        pagination    = data[:pagination] || data["pagination"] || {}
        original_skip = (pagination[:skip] || pagination["skip"] || 0).to_i

        # The recovered envelope must strip stale cardinality keys so the
        # LLM can't mistake the trimmed body for the full result set.
        # `_truncated.original_count` carries the original cardinality.
        # `truncated:`/`truncated_note:` come from ResultFormatter's row-
        # display cap (50 rows) — a different concern from our byte cap.
        # Stripping both ensures the only authoritative truncation signal
        # in the recovered envelope is the `_truncated` block we own here.
        #
        # For aggregate, also strip the top-level :hint (auto-limit message)
        # so the _truncated.hint is the sole guidance in the envelope.
        candidate = data.dup
        candidate.delete(:result_count)
        candidate.delete("result_count")
        candidate.delete(:truncated)
        candidate.delete("truncated")
        candidate.delete(:truncated_note)
        candidate.delete("truncated_note")
        if tool_name == "aggregate"
          candidate.delete(:hint)
          candidate.delete("hint")
        end

        # next_call from ResultFormatter is stale after truncation: its skip
        # is skip+limit, but the trimmed recovery path uses a smaller resume
        # offset (original_skip + fit_count). Strip it so the _truncated
        # block is the sole authoritative pagination signal.
        candidate.delete(:next_call)
        candidate.delete("next_call")

        initial_hint =
          if tool_name == "aggregate"
            "Field '#{heaviest}' was dropped from all rows to fit the #{max_bytes}-byte response cap. " \
            "Narrow the pipeline with a $match or $project stage to reduce result size, " \
            "or call get_object(class_name: <class>, object_id: <id>) for the dropped field."
          else
            "Field '#{heaviest}' was dropped from all rows to fit the #{max_bytes}-byte response cap. " \
            "To retrieve it for a specific row, call get_object(class_name: <class>, object_id: <id>)."
          end

        annotation = {
          reason:         "response_exceeded_max_bytes",
          dropped_fields: [heaviest],
          kept_count:     trimmed_rows.size,
          original_count: rows.size,
          hint:           initial_hint,
        }

        # First try: heaviest field dropped, all rows kept.
        candidate[:results]    = trimmed_rows
        candidate[:_truncated] = annotation
        text = JSON.pretty_generate(candidate)
        return text if text.bytesize <= max_bytes

        # Still over budget — also drop trailing rows. Estimate fit count
        # from the trimmed sample, then verify and back off by one if the
        # estimator overshoots (JSON overhead).
        sample_after = trimmed_rows.first([5, trimmed_rows.size].min)
        sample_text  = JSON.pretty_generate(sample_after)
        per_row      = sample_text.bytesize / sample_after.size.to_f

        envelope_data  = candidate.merge(results: [])
        envelope_bytes = JSON.pretty_generate(envelope_data).bytesize
        budget = max_bytes - envelope_bytes - 256  # safety margin
        return nil if budget <= 0 || per_row <= 0

        fit_count = (budget / per_row).floor
        fit_count = [fit_count, trimmed_rows.size].min
        return nil if fit_count < 1

        loop do
          candidate[:results]                 = trimmed_rows.first(fit_count)
          candidate[:_truncated][:kept_count] = fit_count

          if tool_name == "query_class"
            # next_skip is relative to the same dataset the caller already
            # paginated through — add the original skip so consecutive
            # query_class calls advance instead of looping on page 0.
            resume_skip = original_skip + fit_count
            candidate[:_truncated][:next_skip] = resume_skip
            candidate[:_truncated][:hint] =
              "Field '#{heaviest}' was dropped and only the first #{fit_count} of #{rows.size} rows fit " \
              "the #{max_bytes}-byte cap. Call query_class(skip: #{resume_skip}) to fetch the next page, " \
              "or get_object(class_name: <class>, object_id: <id>) for the dropped field."
          else
            # aggregate: pipelines are deterministic, not paginatable.
            candidate[:_truncated][:hint] =
              "Field '#{heaviest}' was dropped and only the first #{fit_count} of #{rows.size} rows fit " \
              "the #{max_bytes}-byte cap. Narrow the pipeline with a $match or $project stage to reduce " \
              "result size, or call get_object(class_name: <class>, object_id: <id>) for the dropped field."
          end

          text = JSON.pretty_generate(candidate)
          return text if text.bytesize <= max_bytes

          fit_count -= 1
          return nil if fit_count < 1
        end
      end
      private_class_method :attempt_truncate_row_array

      # Hash-of-records recovery path for get_objects.
      #
      # The `objects` hash maps objectId → record. We drop the heaviest field
      # from every record; if still over budget, we move trailing records out
      # of `objects` into a `dropped_for_size:` list in the `_truncated`
      # annotation. The existing `missing:` array is left untouched — it
      # represents IDs that did not exist on the server, not IDs we dropped
      # for size reasons.
      #
      # @api private
      def self.attempt_truncate_objects_hash(data, max_bytes)
        objects = data[:objects] || data["objects"]
        return nil unless objects.is_a?(Hash) && objects.any?

        sample   = objects.values.first(5).select { |r| r.is_a?(Hash) }
        return nil if sample.empty?

        heaviest = find_heaviest_field(sample)
        return nil unless heaviest

        # Drop the heaviest field from every record value (shallow copy).
        trimmed_objects = objects.transform_values do |rec|
          rec.is_a?(Hash) ? rec.reject { |k, _| k.to_s == heaviest } : rec
        end

        # Build a candidate envelope. `found` and `requested` still reflect
        # server reality, as does `missing`. `_truncated.kept_count` is the
        # authoritative "what made it into this response" count.
        candidate = data.dup

        annotation = {
          reason:          "response_exceeded_max_bytes",
          dropped_fields:  [heaviest],
          kept_count:      trimmed_objects.size,
          original_count:  objects.size,
          dropped_for_size: [],
          hint:            "Field '#{heaviest}' was dropped from all records to fit the #{max_bytes}-byte response cap. " \
                           "To retrieve it for a specific record, call get_object(class_name: <class>, object_id: <id>).",
        }

        # First try: heaviest field dropped, all records kept.
        candidate[:objects]    = trimmed_objects
        candidate[:_truncated] = annotation
        text = JSON.pretty_generate(candidate)
        return text if text.bytesize <= max_bytes

        # Still over budget — drop trailing records by insertion order.
        sample_after = trimmed_objects.values.first([5, trimmed_objects.size].min)
        sample_text  = JSON.pretty_generate(sample_after)
        per_rec      = sample_text.bytesize / sample_after.size.to_f

        envelope_data  = candidate.merge(objects: {})
        envelope_bytes = JSON.pretty_generate(envelope_data).bytesize
        budget = max_bytes - envelope_bytes - 256  # safety margin
        return nil if budget <= 0 || per_rec <= 0

        fit_count = (budget / per_rec).floor
        fit_count = [fit_count, trimmed_objects.size].min
        return nil if fit_count < 1

        loop do
          kept_keys    = trimmed_objects.keys.first(fit_count)
          dropped_keys = trimmed_objects.keys - kept_keys

          candidate[:objects]                      = trimmed_objects.slice(*kept_keys)
          candidate[:_truncated][:kept_count]      = fit_count
          candidate[:_truncated][:dropped_for_size] = dropped_keys
          candidate[:_truncated][:hint] =
            "Field '#{heaviest}' was dropped and only #{fit_count} of #{objects.size} records fit " \
            "the #{max_bytes}-byte cap. IDs in dropped_for_size were omitted. " \
            "Call get_object(class_name: <class>, object_id: <id>) to fetch any omitted record."

          text = JSON.pretty_generate(candidate)
          return text if text.bytesize <= max_bytes

          fit_count -= 1
          return nil if fit_count < 1
        end
      end
      private_class_method :attempt_truncate_objects_hash

      # @api private
      def self.humanize_bytes(n)
        n = n.to_f
        return "#{n.round} B"                              if n < 1024
        return "#{(n / 1024.0).round(1)} KB"               if n < 1_048_576
        "#{(n / 1_048_576.0).round(1)} MB"
      end
      private_class_method :humanize_bytes

      # Handle `resources/list`.
      #
      # Exposes three virtual resources per Parse class: schema, count, and
      # samples. Falls back to an empty list if the agent cannot fetch schemas.
      #
      # @param agent [Parse::Agent]
      # @return [Hash] `{ "resources" => [...] }`
      def self.handle_resources_list(_params, agent)
        result = agent.execute(:get_all_schemas)
        return { "resources" => [] } unless result[:success]

        # `get_all_schemas` returns a structured envelope from ResultFormatter:
        #   { total:, note:, built_in: [...], custom: [...] }
        # Earlier drafts of this handler read `result[:data][:classes]` (a key
        # that never existed), which produced an empty resource catalog for
        # every MCP client. We now concatenate `custom` and `built_in` and
        # fall back to the legacy `classes` key in case a custom agent
        # subclass returns the older shape.
        data      = result[:data] || {}
        classes   = (data[:custom] || []) + (data[:built_in] || [])
        classes   = data[:classes] || [] if classes.empty? && data[:classes]
        resources = classes.flat_map do |cls|
          name       = cls[:name]
          klass_desc = cls[:description] || "Parse class (#{cls[:type] || "Custom"})"
          [
            {
              "uri"         => "parse://#{name}/schema",
              "name"        => "#{name} schema",
              "description" => "Field definitions and types for #{name}. #{klass_desc}",
              "mimeType"    => "application/json",
            },
            {
              "uri"         => "parse://#{name}/count",
              "name"        => "#{name} count",
              "description" => "Total number of #{name} objects",
              "mimeType"    => "application/json",
            },
            {
              "uri"         => "parse://#{name}/samples",
              "name"        => "#{name} samples",
              "description" => "Five most recent #{name} objects",
              "mimeType"    => "application/json",
            },
          ]
        end
        { "resources" => resources }
      end
      private_class_method :handle_resources_list

      # Handle `resources/templates/list` (MCP 2025-06-18).
      #
      # Returns the three URI templates this server understands. Templates
      # use RFC 6570 simple-expansion syntax (`{className}`) so clients
      # can construct concrete URIs for any Parse class without scraping
      # `resources/list`. The class-name expansion is unconstrained on
      # the wire; the `resources/read` handler validates the expanded
      # class name against the identifier regex and refuses unknown or
      # malformed classes.
      #
      # The agent argument is unused — templates are server metadata, not
      # tied to a specific agent's view of the schema. It is accepted for
      # signature parity with sibling handlers.
      #
      # @param _agent [Parse::Agent] unused.
      # @return [Hash] `{ "resourceTemplates" => [...] }`
      def self.handle_resources_templates_list(_params, _agent)
        {
          "resourceTemplates" => [
            {
              "uriTemplate" => "parse://{className}/schema",
              "name"        => "Parse class schema",
              "description" => "Field definitions and types for a Parse class. Expand {className} with any class your agent can list via tools/list or resources/list.",
              "mimeType"    => "application/json",
            },
            {
              "uriTemplate" => "parse://{className}/count",
              "name"        => "Parse class object count",
              "description" => "Total number of objects in a Parse class.",
              "mimeType"    => "application/json",
            },
            {
              "uriTemplate" => "parse://{className}/samples",
              "name"        => "Parse class sample objects",
              "description" => "Five most recent objects from a Parse class.",
              "mimeType"    => "application/json",
            },
          ],
        }
      end
      private_class_method :handle_resources_templates_list

      # Handle `resources/read`.
      #
      # URI format: `parse://<ClassName>/<kind>` where kind is one of
      # `schema`, `count`, `samples`. The class name must match Parse's
      # identifier shape. Defaults to `schema` when kind is omitted.
      #
      # @param agent [Parse::Agent]
      # @return [Hash] MCP contents envelope or an error hash.
      def self.handle_resources_read(params, agent)
        uri   = params["uri"].to_s
        match = uri.match(%r{\Aparse://([A-Za-z_][A-Za-z0-9_]*)(?:/(schema|count|samples))?\z})
        return { error: { "code" => -32602, "message" => "Invalid resource URI: #{uri}" } } unless match

        class_name = match[1]
        kind       = match[2] || "schema"

        result = case kind
          when "schema"
            agent.execute(:get_schema, class_name: class_name)
          when "count"
            agent.execute(:count_objects, class_name: class_name)
          when "samples"
            agent.execute(:get_sample_objects, class_name: class_name, limit: 5)
          end

        if result[:success]
          {
            "contents" => [
              {
                "uri"      => uri,
                "mimeType" => "application/json",
                "text"     => JSON.pretty_generate(result[:data]),
              },
            ],
          }
        else
          { error: { "code" => -32603, "message" => result[:error].to_s } }
        end
      end
      private_class_method :handle_resources_read

      # Handle `resources/subscribe` (MCP 2025-06-18).
      #
      # Registers a LiveQuery-backed subscription for `params["uri"]` keyed by
      # the agent's session identity (`correlation_id`, sourced from the
      # `Mcp-Session-Id` header by the transport). Subsequent data changes are
      # debounced and delivered as `notifications/resources/updated` over the
      # session's GET listening stream.
      #
      # Per the MCP spec a successful subscribe returns an empty result. Errors
      # propagate as JSON-RPC errors:
      #   - manager absent / unsupported  → -32601 (capability not offered)
      #   - malformed or non-subscribable URI → -32602 (ValidationError)
      #   - agent scope with no LiveQuery equivalent → -32602 (SecurityError)
      #
      # @param manager [Parse::Agent::MCPSubscriptions::Manager, nil]
      # @return [Hash] empty result, or an `:error` hash when unsupported.
      def self.handle_resources_subscribe(params, agent, manager)
        return subscriptions_unsupported_error unless manager.respond_to?(:supported?) && manager.supported?
        manager.subscribe(
          session_id: agent_session_id(agent),
          uri:        params["uri"].to_s,
          agent:      agent,
        )
        {}
      end
      private_class_method :handle_resources_subscribe

      # Handle `resources/unsubscribe` (MCP 2025-06-18). Idempotent — stops the
      # LiveQuery subscription for the URI if one exists, returns an empty
      # result regardless.
      #
      # @param manager [Parse::Agent::MCPSubscriptions::Manager, nil]
      # @return [Hash] empty result, or an `:error` hash when unsupported.
      def self.handle_resources_unsubscribe(params, agent, manager)
        return subscriptions_unsupported_error unless manager.respond_to?(:supported?) && manager.supported?
        manager.unsubscribe(
          session_id: agent_session_id(agent),
          uri:        params["uri"].to_s,
        )
        {}
      end
      private_class_method :handle_resources_unsubscribe

      # The session identity used to key resource subscriptions. The transport
      # populates `agent.correlation_id` from `Mcp-Session-Id`.
      # @return [String, nil]
      def self.agent_session_id(agent)
        agent.respond_to?(:correlation_id) ? agent.correlation_id : nil
      end
      private_class_method :agent_session_id

      # Error hash returned when a subscribe/unsubscribe arrives but this
      # transport does not offer the capability. -32601 (method not found) is
      # the correct code per JSON-RPC for an unoffered method.
      # @return [Hash]
      def self.subscriptions_unsupported_error
        { error: { "code" => -32601, "message" => "Resource subscriptions are not supported by this server" } }
      end
      private_class_method :subscriptions_unsupported_error

      # Handle `prompts/list`.
      #
      # Delegates to `Parse::Agent::Prompts.list`, which returns an Array of
      # prompt descriptor Hashes. The dispatcher wraps the array into the MCP
      # envelope `{ "prompts" => [...] }`.
      #
      # @return [Hash] `{ "prompts" => [...] }`
      def self.handle_prompts_list(_params)
        { "prompts" => Parse::Agent::Prompts.list }
      end
      private_class_method :handle_prompts_list

      # Handle `prompts/get`.
      #
      # Fully delegates to `Parse::Agent::Prompts.render(name, args)`, which
      # returns the complete MCP messages envelope:
      #   { "description" => String, "messages" => [{ "role" => "user", ... }] }
      #
      # `Prompts.render` raises `Parse::Agent::ValidationError` for unknown
      # prompt names or missing/invalid required arguments. The `dispatch`
      # rescue clause converts those into JSON-RPC -32602 responses so the
      # message text (including "Unknown prompt: <name>") reaches the caller.
      #
      # Additionally, the rendered text is checked against MAX_TOOL_RESPONSE_BYTES.
      # If the first message's content text exceeds the cap, a JSON-RPC -32602
      # error hash is returned so the dispatcher's envelope path handles it
      # without raising. Large data belongs in tools, not prompts.
      #
      # @return [Hash] MCP messages envelope or an error hash with :error key.
      def self.handle_prompts_get(params)
        name   = params["name"].to_s
        args   = params["arguments"] || {}
        result = Parse::Agent::Prompts.render(name, args)

        # Guard against oversized prompt renderers. The renderer is untrusted
        # extension code; check defensively before returning to the caller.
        messages = result["messages"]
        if messages.is_a?(Array) && !messages.empty?
          text = messages.first.dig("content", "text").to_s
          if text.bytesize > MAX_TOOL_RESPONSE_BYTES
            return { error: { "code" => -32602, "message" => "Prompt output exceeded #{MAX_TOOL_RESPONSE_BYTES} bytes. Renderers should produce concise prompts; large data goes through tools, not prompts." } }
          end
        end

        result
      end
      private_class_method :handle_prompts_get

      # ---------------------------------------------------------------------------
      # Envelope helpers
      # ---------------------------------------------------------------------------

      # Build a complete JSON-RPC response envelope with string keys.
      #
      # @param id [Any] the JSON-RPC request id (may be nil for notifications).
      # @param result [Hash, nil] the result payload (mutually exclusive with error).
      # @param error  [Hash, nil] the error payload (mutually exclusive with result).
      # @return [Hash] JSON-RPC envelope with string keys.
      def self.jsonrpc_envelope(id, result: nil, error: nil)
        envelope = { "jsonrpc" => "2.0", "id" => id }
        if error
          envelope["error"] = error
        else
          envelope["result"] = result || {}
        end
        envelope
      end
      private_class_method :jsonrpc_envelope

      # Build a JSON-RPC error envelope.
      #
      # @param id      [Any]     the request id.
      # @param code    [Integer] JSON-RPC error code.
      # @param message [String]  human-readable error message (must NOT include
      #   raw query content, user data, or internal stack information).
      # @return [Hash] JSON-RPC error envelope with string keys.
      def self.jsonrpc_error(id, code, message)
        jsonrpc_envelope(id, error: { "code" => code, "message" => message })
      end
      private_class_method :jsonrpc_error
    end
  end
end
