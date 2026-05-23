# encoding: UTF-8
# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "errors"
require_relative "mcp_dispatcher"
require_relative "cancellation_token"

module Parse
  class Agent
    # Rack adapter that exposes Parse::Agent::MCPDispatcher as a mountable
    # Rack endpoint. Downstream applications can mount this inside Sinatra,
    # Rails, or any Rack-compatible router at an arbitrary path and behind
    # their own authentication gate.
    #
    # The adapter enforces the same transport-level invariants as MCPServer
    # (method, content-type, body-size, and JSON-parse checks) and then
    # delegates to Parse::Agent::MCPDispatcher.call for all protocol handling.
    #
    # == SSE Streaming (MCP progress notifications)
    #
    # When constructed with `streaming: true`, requests that include
    # `Accept: text/event-stream` receive an SSE response instead of a single
    # JSON body. The server holds the connection open and emits
    # `notifications/progress` events from two sources:
    #
    # 1. Time-based heartbeats every `heartbeat_interval` seconds while
    #    the dispatcher runs (progress field = elapsed seconds).
    # 2. Tool-internal progress reported by the tool itself via
    #    `agent.report_progress(progress:, total:, message:)`. Works for
    #    both built-in tools and custom tools registered through
    #    `Parse::Agent::Tools.register`.
    #
    # Heartbeats are automatically suppressed once a tool reports its own
    # progress, so the `progressToken` carries a single coherent stream.
    # A final `response` event carries the complete JSON-RPC response,
    # after which the stream closes.
    #
    # This lets LLM clients observe progress on long-running tool calls (such
    # as aggregate pipelines) rather than timing out silently.
    #
    # Streaming requires a Rack server that supports streaming response bodies
    # (Puma, Falcon, Unicorn). WEBrick buffers the full body before writing,
    # so SSE streaming has no effect on the standalone MCPServer — operators
    # using MCPServer directly should leave `streaming: false` (the default).
    #
    # To disable Nginx response buffering for SSE endpoints, set:
    #   proxy_buffering off;
    # or rely on the `X-Accel-Buffering: no` header this class emits
    # automatically on every SSE response.
    #
    # When `streaming: false` (default), an `Accept: text/event-stream` request
    # receives a plain JSON response — the adapter is permissive per the MCP
    # spec, which does not require SSE support.
    #
    # @example Block form (most common)
    #   app = Parse::Agent::MCPRackApp.new do |env|
    #     token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
    #     agent = MyAuth.agent_for_token!(token)  # raises Unauthorized if invalid
    #     agent
    #   end
    #
    # @example Keyword argument form
    #   factory = ->(env) { Parse::Agent.new(permissions: :readonly) }
    #   app = Parse::Agent::MCPRackApp.new(agent_factory: factory)
    #
    # @example With SSE streaming enabled
    #   app = Parse::Agent::MCPRackApp.new(streaming: true) { |env| ... }
    #
    # @example Mounted in Rails routes.rb
    #   mount Parse::Agent::MCPRackApp.new { |env| ... }, at: "/mcp"
    #
    class MCPRackApp
      # Maximum allowed request body size in bytes (matches MCPServer::MAX_BODY_SIZE).
      DEFAULT_MAX_BODY_SIZE = 1_048_576  # 1 MB

      # JSON nesting depth limit (matches MCPServer::MAX_JSON_NESTING).
      MAX_JSON_NESTING = 20

      # Default heartbeat interval in seconds when streaming is enabled.
      DEFAULT_HEARTBEAT_INTERVAL = 2

      # Standard Content-Type for all JSON responses. Frozen template — call
      # {#json_headers} to obtain a per-response mutable copy that composes
      # with Rack middleware that decorates response headers (e.g. Sinatra's
      # xss_header / json_csrf / common_logger).
      JSON_CONTENT_TYPE = { "Content-Type" => "application/json" }.freeze

      # SSE response headers. X-Accel-Buffering disables Nginx proxy buffering.
      # Frozen template — call {#sse_headers} to obtain a per-response copy.
      SSE_HEADERS = {
        "Content-Type"      => "text/event-stream",
        "Cache-Control"     => "no-cache",
        "Connection"        => "keep-alive",
        "X-Accel-Buffering" => "no",
      }.freeze

      # Drop env keys that would have come from underscore-form HTTP header
      # names. The Rack-spec-compliant interpretation of HTTP headers maps
      # `X-MCP-API-Key` and `X_MCP_API_KEY` to the same env key
      # (`HTTP_X_MCP_API_KEY`); a misbehaving upstream server that forwards
      # the underscore-form lets an attacker overwrite trusted reverse-proxy-
      # injected headers.
      #
      # This helper is invoked automatically at the top of {#call}, so any
      # MCPRackApp mounted in a Rack 3+ pipeline (which exposes the original
      # header list via `rack.headers`) gets defense-in-depth scrubbing
      # without operator opt-in. On Rack 2 / pre-3 servers `rack.headers` is
      # not set and the helper is a no-op; operators on those stacks must
      # configure their upstream (e.g. Nginx `underscores_in_headers off`)
      # OR mount this helper as an explicit middleware.
      #
      # The standalone `MCPServer` rewrites its own `build_rack_env` to drop
      # underscore-form names before they reach this app, so the standalone
      # path is covered regardless of Rack version.
      #
      # @example Explicit middleware (Rack 2 / pre-3 deployments)
      #   class StripSmuggledHeaders
      #     def initialize(app); @app = app; end
      #     def call(env)
      #       Parse::Agent::MCPRackApp.strip_underscore_smuggled_headers!(env)
      #       @app.call(env)
      #     end
      #   end
      #
      # @param env [Hash] the Rack env, mutated in place
      # @return [Hash] the same env, for chaining
      def self.strip_underscore_smuggled_headers!(env)
        # Rack 3+ preserves the original header list in env["rack.headers"]
        # (a Rack::Headers instance or Hash). When present, we can identify
        # which env keys came from an underscore-form header and delete
        # them, even if a dashed-form sibling arrived too.
        if env["rack.headers"].respond_to?(:each)
          suspect = []
          env["rack.headers"].each do |name, _|
            suspect << name if name.is_a?(String) && name.include?("_")
          end
          suspect.each do |name|
            env.delete("HTTP_#{name.upcase.tr("-", "_")}")
          end
        end
        env
      end

      # @param agent_factory [Proc, nil] callable invoked with the Rack env on
      #   every request. Must return a Parse::Agent or raise
      #   Parse::Agent::Unauthorized. Mutually exclusive with a block.
      # @param max_body_size [Integer] reject bodies larger than this many bytes.
      #   Defaults to DEFAULT_MAX_BODY_SIZE.
      # @param logger [#warn, nil] optional logger. When set, auth failures are
      #   warned at class-name level, and internal errors include a backtrace.
      # @param streaming [Boolean] enable SSE streaming for clients that send
      #   `Accept: text/event-stream`. Defaults to false for backward
      #   compatibility. Has no effect on WEBrick-backed deployments (see
      #   class documentation).
      # @param heartbeat_interval [Numeric] seconds between progress heartbeat
      #   events when streaming is active. Defaults to DEFAULT_HEARTBEAT_INTERVAL.
      #   Ignored when `streaming: false`.
      # @param max_concurrent_dispatchers [Integer, nil] when set, limits the
      #   number of concurrently active dispatcher threads across all SSE
      #   connections served by this app instance. When the limit is reached a
      #   new SSE request immediately receives a 503 JSON-RPC error envelope
      #   (`-32000` "server busy") rather than spawning another dispatcher.
      #   Defaults to `nil` (unlimited). Use `active_dispatcher_count` to
      #   monitor current concurrency from operator tooling.
      # @param pre_auth_rate_limiter [#check!, nil] optional rate limiter
      #   consulted at the top of every request, BEFORE the agent_factory is
      #   invoked. Closes the factory-amplification DoS where each malformed
      #   request burns a Parse Server round-trip (factories typically
      #   validate session tokens by calling out). Must respond to `#check!`
      #   and raise an exception responding to `#retry_after` (such as
      #   `Parse::Agent::RateLimiter::RateLimitExceeded`) when exhausted.
      #   Defaults to `nil` (no pre-auth limiter). On exhaustion the request
      #   is rejected with HTTP 429 and a `Retry-After` header.
      # @param allowed_origins [Array<String>, nil] when set, the `Origin`
      #   request header must match one of these entries (case-insensitive,
      #   exact host match — wildcard via leading `.` matches subdomains).
      #   `nil` (default) skips the check. Browsers always send `Origin`
      #   on cross-origin POST; native clients (curl, ruby HTTP client,
      #   SDK-to-SDK) typically don't, and an absent `Origin` is treated
      #   as allowed regardless of this setting. The default loopback
      #   bind makes this check optional in development; operators who
      #   bind MCP to a routable interface should configure it.
      # @param require_custom_header [String, nil] when set (e.g.
      #   `"X-MCP-Client"`), requests must carry that header with any
      #   non-empty value. Custom headers can't be set by a `<form>`
      #   CSRF and force a CORS preflight on browser `fetch()`, so this
      #   gate closes the browser-driven attack surface entirely. Pair
      #   with `allowed_origins` for defense in depth.
      # @param health_path [String, nil] when set (e.g. `"/health"`),
      #   `GET` requests to that exact path return `200 {"status":"ok"}`
      #   without invoking the agent_factory, without authentication,
      #   without rate-limiting, and without applying the
      #   `allowed_origins` / `require_custom_header` CSRF gates.
      #   Intended as a liveness probe for load balancers and
      #   orchestrators (Kubernetes, ECS, Consul) that cannot present a
      #   matching `Origin` or custom header. Because the probe sits
      #   ahead of the pre-auth rate limiter, operators should
      #   front-edge rate-limit the path at the LB/Nginx layer if
      #   public-facing. The response intentionally contains no
      #   version, build, or counter information — fingerprint-minimal
      #   by design. `nil` (default) disables the endpoint entirely;
      #   empty-string values are coerced to `nil`. Any non-GET method
      #   on the path falls through to the standard 405 handler.
      # @raise [ArgumentError] if both or neither of agent_factory/block are given.
      def initialize(agent_factory: nil, max_body_size: DEFAULT_MAX_BODY_SIZE,
                     logger: nil, streaming: false,
                     heartbeat_interval: DEFAULT_HEARTBEAT_INTERVAL,
                     max_concurrent_dispatchers: nil,
                     pre_auth_rate_limiter: nil,
                     allowed_origins: nil,
                     require_custom_header: nil,
                     health_path: nil, &block)
        if agent_factory && block
          raise ArgumentError, "Provide agent_factory: OR a block, not both"
        end
        unless agent_factory || block
          raise ArgumentError, "Either agent_factory: keyword or a block is required"
        end
        if pre_auth_rate_limiter && !pre_auth_rate_limiter.respond_to?(:check!)
          raise ArgumentError, "pre_auth_rate_limiter must respond to #check!"
        end

        @agent_factory              = agent_factory || block
        @max_body_size              = max_body_size
        @logger                     = logger
        @streaming                  = streaming
        @heartbeat_interval         = heartbeat_interval
        @max_concurrent_dispatchers = max_concurrent_dispatchers
        @pre_auth_rate_limiter      = pre_auth_rate_limiter
        @allowed_origins            = normalize_allowed_origins(allowed_origins)
        @required_custom_header     = normalize_required_custom_header(require_custom_header)
        @health_path                = health_path.is_a?(String) && !health_path.empty? ? health_path : nil
        # Per-app registry of in-flight cancellable requests. Keyed by
        # [correlation_id, request_id]. A `notifications/cancelled` POST
        # whose `params.requestId` matches an entry trips the registered
        # CancellationToken. Scoped per-instance, not per-process: this
        # registry does not span multiple MCPRackApp mount points within
        # a process, nor multiple processes in a clustered deployment.
        @cancellation_registry      = CancellationRegistry.new

        # Warn operators who enable streaming without a concurrency cap.
        # An unbounded SSE endpoint with orphaned dispatcher threads is
        # a practical DoS surface — a slow or hostile client opening
        # connections faster than tools complete can exhaust the host's
        # thread pool and downstream Parse connection pool. Leaving the
        # default as `nil` (unlimited) preserves backward compatibility,
        # but we tell the operator once at construction.
        if streaming && @max_concurrent_dispatchers.nil?
          line = "[Parse::Agent::MCPRackApp] streaming: true with max_concurrent_dispatchers: nil (unlimited). " \
                 "Set a finite cap (e.g. 100, or 2x your Puma max_threads) to bound the orphan-thread DoS surface. " \
                 "See docs/mcp_guide.md for sizing guidance."
          if @logger
            @logger.warn(line)
          else
            warn line
          end
        end
      end

      # Returns the number of currently live dispatcher threads spawned by any
      # SSEBody across all MCPRackApp instances in this process. Threads are
      # counted by the `:parse_mcp_dispatcher` thread-local tag set when each
      # dispatcher_thread is started. Use this for operator dashboards or health
      # checks; do NOT use it to make flow-control decisions at runtime (use
      # the `max_concurrent_dispatchers:` constructor option for that).
      def self.active_dispatcher_count
        Thread.list.count { |t| t[:parse_mcp_dispatcher] }
      end

      # Rack interface.
      #
      # @param env [Hash] Rack environment
      # @return [Array(Integer, Hash, #each)] Rack triple
      def call(env)
        # 0. Defense-in-depth: strip underscore-form HTTP headers from env
        #    before any subsequent lookup reads HTTP_X_MCP_API_KEY / etc.
        #    No-op on Rack < 3 (where env["rack.headers"] is absent); on
        #    Rack 3+ this removes any HTTP_* env key whose original header
        #    name contained an underscore. Closes the smuggling path where
        #    a hostile client sends `X_MCP_API_Key: ...` alongside a
        #    trusted reverse-proxy-injected `X-MCP-API-Key: ...` and the
        #    underscored form collapses-and-overwrites the trusted slot.
        self.class.strip_underscore_smuggled_headers!(env)

        # 0a. Liveness probe. When `health_path:` is configured, a GET to
        #     that exact path returns `{"status":"ok"}` without auth,
        #     rate-limiting, or factory invocation. Intentionally
        #     fingerprint-minimal: no version, no build, no counter —
        #     a load balancer needs "is it up?", not "what is it?".
        if @health_path && env["PATH_INFO"] == @health_path && env["REQUEST_METHOD"] == "GET"
          return [200, json_headers, ['{"status":"ok"}']]
        end

        # 0b. NEW-MCP-6: pre-auth rate limit. Runs BEFORE the agent_factory
        #     so a malformed body / missing key / empty `{}` cannot force
        #     the operator-supplied factory to round-trip to Parse Server
        #     on every request. Off by default (constructor kwarg).
        if @pre_auth_rate_limiter
          begin
            @pre_auth_rate_limiter.check!
          rescue StandardError => e
            retry_after = e.respond_to?(:retry_after) ? e.retry_after : nil
            headers = json_headers.dup
            headers["Retry-After"] = retry_after.ceil.to_s if retry_after && retry_after > 0
            return [429, headers, [json_rpc_error(-32_000, "Too Many Requests")]]
          end
        end

        # 0c. DELETE /  — MCP 2025-06-18 Streamable HTTP session
        #     termination. A client signals it is done with a session by
        #     sending DELETE with the same `Mcp-Session-Id` header it
        #     received from initialize. Per spec the server MAY support
        #     this; if it doesn't, it MUST return 405. We support it.
        #
        #     Stateless-agent reality: the factory builds a fresh agent
        #     per request, so there is no server-side session store to
        #     evict. What DELETE meaningfully does is cancel any
        #     in-flight requests still running under that correlation_id
        #     so worker threads exit instead of completing wasted work.
        #     The cancellation_registry returns 0 when nothing matches
        #     (also the "unknown session" case) — we don't probe-leak by
        #     differentiating known vs unknown ids in the response.
        #
        #     Sanitized through Parse::Agent#correlation_id= via a
        #     throwaway agent so a malicious header value (CRLF, shell
        #     metachars) is silently rejected rather than reaching the
        #     registry as a key.
        if env["REQUEST_METHOD"] == "DELETE"
          sid = env["HTTP_MCP_SESSION_ID"].to_s
          if sid.empty?
            return [400, json_headers, [json_rpc_error(-32_600, "Missing Mcp-Session-Id")]]
          end
          clean_sid = sanitize_session_id(sid)
          if clean_sid.nil?
            return [400, json_headers, [json_rpc_error(-32_600, "Invalid Mcp-Session-Id")]]
          end
          @cancellation_registry.cancel_all_for(clean_sid, reason: :session_terminated)
          return [204, json_headers, [""]]
        end

        # 1. Method check — only POST is accepted.
        unless env["REQUEST_METHOD"] == "POST"
          return [405,
                  json_headers.merge("Allow" => "POST"),
                  [json_rpc_error(-32_700, "method_not_allowed")]]
        end

        # 2. Content-type check — must be application/json (charset ignored).
        content_type = env["CONTENT_TYPE"].to_s.split(";").first.to_s.strip.downcase
        unless content_type == "application/json"
          return [415, json_headers, [json_rpc_error(-32_700, "Unsupported Media Type: Content-Type must be application/json")]]
        end

        # 2b. Origin allowlist. Browsers always send an `Origin` header
        #     on cross-origin POST; native clients typically don't.
        #     When configured, a non-empty `Origin` must match the
        #     allowlist or the request is rejected with 403.
        #     Missing/empty `Origin` is allowed regardless — native
        #     clients (curl, SDK-to-SDK) shouldn't be broken by a
        #     CSRF defense aimed at browsers.
        if @allowed_origins
          origin = env["HTTP_ORIGIN"].to_s.strip
          unless origin.empty? || origin_allowed?(origin)
            @logger&.warn("[Parse::Agent::MCPRackApp] Origin refused: #{origin.inspect}")
            return [403, json_headers, [json_rpc_error(-32_700, "Origin not allowed")]]
          end
        end

        # 2c. Required custom header (CSRF defense-in-depth). A header
        #     like `X-MCP-Client` cannot be set by a `<form>` CSRF and
        #     forces a CORS preflight on browser `fetch()`. When
        #     configured, the header must be present and (if a value
        #     was supplied to the constructor) match.
        if @required_custom_header
          header_env_key, expected_value = @required_custom_header
          actual = env[header_env_key].to_s
          if actual.empty? || (expected_value && actual != expected_value)
            return [403, json_headers, [json_rpc_error(-32_700, "Required custom header missing or invalid")]]
          end
        end

        # 3. Body size limit — read one byte beyond limit to detect oversized bodies
        #    without buffering the full stream.
        raw_body = env["rack.input"].read(@max_body_size + 1)
        if raw_body.bytesize > @max_body_size
          return [413, json_headers, [json_rpc_error(-32_700, "Payload Too Large: body exceeds #{@max_body_size} bytes")]]
        end

        # 4. JSON parse.
        begin
          body = JSON.parse(raw_body.empty? ? "{}" : raw_body, max_nesting: MAX_JSON_NESTING)
        rescue JSON::ParserError, JSON::NestingError
          return [400, json_headers, [json_rpc_error(-32_700, "Parse error: invalid JSON")]]
        end

        # 4b. NEW-MCP-6: refuse obviously-malformed JSON-RPC envelopes
        #     BEFORE invoking the agent_factory. The factory typically
        #     hits Parse Server (token validation, audit logging), so a
        #     barrage of empty `{}` or missing-method bodies otherwise
        #     amplifies into a Parse Server load problem. Empty-object
        #     and missing-method requests cannot possibly be valid
        #     JSON-RPC, so we shortcut to -32600 (Invalid Request).
        unless body.is_a?(Hash) && body["method"].is_a?(String) && !body["method"].empty?
          return [400, json_headers, [json_rpc_error(-32_600, "Invalid Request")]]
        end

        # 4c. MCP-Protocol-Version header validation (MCP 2025-06-18
        #     Streamable HTTP). The spec says:
        #       - The client MUST send `MCP-Protocol-Version: <ver>`
        #         on every request AFTER initialize.
        #       - If absent on a non-initialize request, the server
        #         SHOULD assume `2025-03-26` for backwards compatibility.
        #       - If present but not a version the server supports,
        #         the server MUST respond `400 Bad Request`.
        #     Initialize requests are exempt — initialize IS the
        #     negotiation, so the header is meaningless there.
        #     Cancellation notifications are also exempt because they
        #     may be sent by a client that has not (yet) completed
        #     initialize against this transport instance (e.g. a
        #     reconnecting client cancelling a pre-disconnect request).
        unless body["method"] == "initialize" ||
               body["method"] == "notifications/cancelled"
          requested = env["HTTP_MCP_PROTOCOL_VERSION"]
          if requested.is_a?(String) && !requested.empty? &&
             !Parse::Agent::MCPDispatcher::SUPPORTED_PROTOCOL_VERSIONS.include?(requested)
            return [400, json_headers,
                    [json_rpc_error(-32_600,
                                    "Unsupported MCP-Protocol-Version: #{requested}",
                                    id: body["id"])]]
          end
        end

        # 5. Agent factory — auth gate. Rescue Unauthorized first, then catch-all
        #    for unexpected factory errors.
        begin
          agent = @agent_factory.call(env)
        rescue Parse::Agent::Unauthorized => e
          @logger.warn("[Parse::Agent::MCPRackApp] Unauthorized: #{e.class.name}") if @logger
          return [401, json_headers, [unauthorized_body]]
        rescue StandardError => e
          if @logger
            @logger.warn("[Parse::Agent::MCPRackApp] Factory error: #{e.class.name}")
            @logger.warn(e.backtrace.join("\n")) if e.backtrace
          end
          return [500, json_headers, [json_rpc_error(-32_603, "Internal error")]]
        end

        # 5b. Thread the conversation correlation id through. Source
        #     header: the MCP 2025-06-18 Streamable HTTP spec-canonical
        #     `Mcp-Session-Id` (Rack env key `HTTP_MCP_SESSION_ID`).
        #
        #     Only fills it when the factory hasn't already assigned one
        #     — application code that needs to override the
        #     client-supplied id (e.g., bind to an internal session
        #     record) can do so in the factory and we don't stomp on it.
        #     The Parse::Agent#correlation_id= setter sanitizes the
        #     value; an invalid header is silently dropped.
        if agent && agent.respond_to?(:correlation_id=) &&
           agent.correlation_id.nil? &&
           (sid = env["HTTP_MCP_SESSION_ID"])
          agent.correlation_id = sid
        end

        # 5b-i. Server-assigned Mcp-Session-Id on initialize. Per MCP
        #     2025-06-18 Streamable HTTP, the server SHOULD assign a
        #     fresh session id during initialize when the client did not
        #     supply one, and return it on the response so the client
        #     can echo it on subsequent requests. Stateless-agent
        #     reality: the SDK does not maintain a server-side session
        #     store — the id is best-effort correlation only (used for
        #     audit-log threading and cancellation routing). We do not
        #     refuse subsequent requests carrying an "unknown" id.
        if body.is_a?(Hash) && body["method"] == "initialize" &&
           agent && agent.respond_to?(:correlation_id=) &&
           agent.correlation_id.nil?
          agent.correlation_id = SecureRandom.uuid
        end

        # 5c. notifications/cancelled — special-cased BEFORE the dispatcher.
        #     A JSON-RPC notification has no `id`, expects no response
        #     body, and must trip the in-flight request whose
        #     `(correlation_id, request_id)` matches. We require the
        #     cancelling request to carry the same Mcp-Session-Id
        #     (sanitized into agent.correlation_id above) as the original
        #     request — otherwise an attacker who guesses sequential
        #     JSON-RPC ids could cancel arbitrary in-flight requests.
        #
        #     Failures (no correlation_id, no requestId, no match) are
        #     silent no-ops to avoid a probe oracle. The response is
        #     always 202 Accepted with an empty body.
        if body.is_a?(Hash) && body["method"] == "notifications/cancelled"
          request_id = body.dig("params", "requestId")
          if agent.respond_to?(:correlation_id) && agent.correlation_id && request_id
            @cancellation_registry.cancel(
              agent.correlation_id,
              request_id,
              reason: :notifications_cancelled,
            )
          end
          return [202, json_headers, [""]]
        end

        # 6. Branch on streaming preference. Transport-level errors (steps 1-5)
        #    always return plain JSON regardless of the Accept header.
        if @streaming && env["HTTP_ACCEPT"].to_s.include?("text/event-stream")
          serve_sse(body, agent)
        else
          serve_json(body, agent)
        end
      end

      private

      # ---------------------------------------------------------------------------
      # Response paths
      # ---------------------------------------------------------------------------

      # Dispatch synchronously and return a single JSON Rack response.
      #
      # @param body  [Hash] parsed JSON-RPC request body.
      # @param agent [Parse::Agent] authenticated agent.
      # @return [Array] Rack triple with Array<String> body.
      def serve_json(body, agent)
        result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent, logger: @logger)
        headers = json_headers
        merge_session_header!(headers, body, agent)
        # When the dispatcher returns body: nil (a JSON-RPC notification
        # like notifications/cancelled has no response), the Rack body
        # is an empty string — NOT the literal "null". The HTTP-level
        # success/empty-body shape is what the spec calls for and is
        # what every MCP client expects after sending a notification.
        return [result[:status], headers, [""]] if result[:body].nil?

        [result[:status], headers, [JSON.generate(result[:body])]]
      end

      # Return a streaming Rack response that emits SSE progress events while
      # the dispatcher runs, followed by a final `response` event.
      #
      # The response body is an SSEBody instance whose `#each` method blocks
      # (reading from an internal Queue) until the worker thread signals
      # completion. All `yield` calls happen on the thread/fiber that drives
      # `#each` (the Rack server's I/O thread); the worker thread only pushes
      # to the Queue, avoiding Fiber cross-thread violations.
      #
      # When `max_concurrent_dispatchers` is set and the current count of live
      # dispatcher threads meets or exceeds that limit, the request is rejected
      # immediately with a 503 JSON-RPC error (-32000 "server busy") rather
      # than spawning another dispatcher thread. The check is performed here
      # (before SSEBody is constructed) so the 503 is returned as a plain JSON
      # response triple, not as an SSE stream.
      #
      # @param body  [Hash] parsed JSON-RPC request body.
      # @param agent [Parse::Agent] authenticated agent.
      # @return [Array] Rack triple with SSEBody or a 503 JSON error as the body.
      def serve_sse(body, agent)
        # NOTE: this check is not mutex-protected, so two concurrent requests
        # arriving within the same scheduling quantum can both pass the check
        # and each spawn a dispatcher_thread, briefly exceeding the limit by
        # one slot. The check is a best-effort soft cap, not a hard guarantee.
        # This is intentional — mutex overhead on the hot path is undesirable,
        # and brief overrun by 1 is acceptable under Puma's thread-per-request
        # model.
        if @max_concurrent_dispatchers &&
           MCPRackApp.active_dispatcher_count >= @max_concurrent_dispatchers
          return [503, json_headers,
                  [json_rpc_error(-32_000, "server busy", id: body["id"])]]
        end

        progress_token = body.dig("params", "_meta", "progressToken") || SecureRandom.uuid
        req_id         = body["id"]
        interval       = @heartbeat_interval
        logger         = @logger

        # Register a cancellation token in the per-app registry so a
        # subsequent notifications/cancelled with a matching
        # (correlation_id, request_id) can trip it. Registration happens
        # synchronously here — BEFORE SSEBody spawns the dispatcher_thread
        # in #each — so a fast-arriving cancel from the same client cannot
        # race against an empty registry.
        #
        # The registry hands back an opaque entry_id; on_close passes it
        # to deregister so a sibling request that reused the same
        # (correlation_id, request_id) key cannot have its token evicted
        # when this request closes.
        cancellation_token = Parse::Agent::CancellationToken.new
        correlation_id     = agent.respond_to?(:correlation_id) ? agent.correlation_id : nil
        registry_entry_id  = @cancellation_registry.register(correlation_id, req_id, cancellation_token)
        registry           = @cancellation_registry

        # The block receives the SSEBody's progress_callback so tools can
        # emit `notifications/progress` events through it. The callback is
        # safe to pass even when no tool calls it — SSEBody only writes to
        # the queue when invoked, and the JSON path never reaches this code.
        sse_body = SSEBody.new(
          progress_token, req_id, interval, logger,
          cancellation_token: cancellation_token,
          on_close: -> { registry.deregister(correlation_id, req_id, registry_entry_id) if registry_entry_id },
        ) do |progress_callback|
          Parse::Agent::MCPDispatcher.call(
            body:               body,
            agent:              agent,
            logger:             logger,
            progress_callback:  progress_callback,
            cancellation_token: cancellation_token,
          )
        end

        headers = sse_headers
        merge_session_header!(headers, body, agent)
        [200, headers, sse_body]
      end

      # ---------------------------------------------------------------------------
      # SSE body class
      # ---------------------------------------------------------------------------

      # Rack body object that emits MCP progress notifications over SSE.
      #
      # `#each` is the only public interface (besides `#close`). It is driven
      # by the Rack server on whatever thread/fiber handles response writing.
      # The dispatcher call and heartbeat timer both run on a dedicated worker
      # thread so they do not block the calling fiber.
      #
      # == Two sources of progress events
      #
      # SSEBody emits `notifications/progress` events from two sources:
      #
      # 1. **Time-based heartbeats.** The worker thread emits a heartbeat
      #    every `@interval` seconds while the dispatcher is running. The
      #    `progress` field is elapsed seconds; `total` is omitted. The
      #    heartbeat uses a dedicated server-generated `progressToken`
      #    distinct from any client-supplied token so the elapsed-seconds
      #    scale never appears alongside tool-reported work units on the
      #    same token (the MCP spec requires per-token monotonicity).
      #
      # 2. **Tool-internal progress.** Tools call `agent.report_progress(...)`
      #    which invokes the callback exposed by `#progress_callback`. The
      #    callback pushes an event using the client-supplied or
      #    server-generated `progressToken` with the tool-supplied
      #    `progress`, optional `total`, and optional `message`.
      #
      # Once a tool starts reporting its own progress, the heartbeat
      # loop suppresses further time-based events to reduce stream
      # noise — the tool's reports already carry liveness signal. When
      # the tool never calls `report_progress`, heartbeats continue
      # firing for the lifetime of the dispatcher.
      #
      # Wire format for each SSE event (note: trailing blank line is required
      # by the SSE spec):
      #
      #   event: progress\n
      #   data: <json>\n
      #   \n
      #
      # @api private
      class SSEBody
        # Sentinel pushed to the queue when the worker is done.
        DONE = :__sse_done__

        # Callback exposed to the dispatcher block. Calling this with
        # keyword args `progress:`, `total:`, `message:` pushes a
        # tool-progress `notifications/progress` event to the SSE queue
        # and marks the worker as "tool is reporting" so subsequent
        # time-based heartbeats are suppressed.
        #
        # @return [Proc]
        attr_reader :progress_callback

        # @param progress_token [String] MCP progressToken value.
        # @param req_id         [Object] JSON-RPC request id (may be nil).
        # @param interval       [Numeric] heartbeat period in seconds.
        # @param logger         [#warn, nil] optional logger.
        # @param cancellation_token [Parse::Agent::CancellationToken, nil]
        #   token tripped by {#close} (client disconnect) and by
        #   `notifications/cancelled` lookups. Tools cooperate by checking
        #   `agent.cancelled?`.
        # @param on_close [Proc, nil] callback invoked from {#close} after
        #   the worker has been terminated. Used by MCPRackApp to
        #   deregister the cancellation token from the per-app registry.
        # @param dispatcher_blk [Proc] called with one argument (the
        #   {#progress_callback} Proc); must return the same
        #   `{ status:, body: }` hash that MCPDispatcher.call returns.
        def initialize(progress_token, req_id, interval, logger,
                       cancellation_token: nil, on_close: nil, &dispatcher_blk)
          @progress_token         = progress_token
          # Heartbeats use a dedicated server-generated progressToken so
          # the elapsed-seconds scale of heartbeats never appears on the
          # same MCP progressToken as work-unit values reported by tools.
          # The MCP spec requires `progress` to increase monotonically
          # per progressToken; mixing the two scales would violate it
          # at the boundary where a tool first reports.
          @heartbeat_token        = "parse-stack:heartbeat:#{SecureRandom.uuid}"
          @req_id                 = req_id
          @interval               = interval
          @logger                 = logger
          @dispatcher_blk         = dispatcher_blk
          @cancellation_token     = cancellation_token
          @on_close               = on_close
          @queue                  = Queue.new
          @worker                 = nil
          # Flipped to true by #each when the DONE sentinel is consumed.
          # #close uses this to decide whether to trip the cancellation
          # token (false = client disconnect) or skip the trip (true =
          # the request finished on its own). Reads and writes happen
          # under @close_mutex below.
          @completed_normally     = false
          # Volatile flag flipped by the progress_callback the first time a
          # tool reports. Heartbeats now use a separate progressToken so
          # the flag is no longer a spec-correctness gate, but we keep
          # it as a small bandwidth optimization — once a tool is
          # actively reporting, time-based heartbeats are noise.
          @tool_progress_reported = false
          @progress_callback      = build_progress_callback
          # Deregistration callbacks for the Tools/Prompts subscribe
          # bindings. Set when the worker starts (so a request that is
          # never driven via #each does not register a stale entry) and
          # cleared in #close.
          @unsubscribe_tools      = nil
          @unsubscribe_prompts    = nil
          # Guards concurrent invocations of #close. Rack servers
          # sometimes call close from both the I/O fiber's ensure and a
          # separate disconnect-handler thread; without a mutex the
          # subscriber-deregister and on_close paths can run twice.
          @close_mutex            = Mutex.new
          @closed                 = false
        end

        # Rack body interface — called once by the Rack server.
        #
        # Starts a worker thread that runs the dispatcher and emits periodic
        # heartbeats via the queue, then loops reading from the queue and
        # yielding formatted SSE strings until the final response is sent.
        #
        # @yield [String] SSE-formatted event strings.
        def each
          start_worker
          loop do
            msg = @queue.pop
            if msg == DONE
              @close_mutex.synchronize { @completed_normally = true }
              break
            end
            yield msg
          end
        ensure
          close
        end

        # Terminate the stream and clean up.
        #
        # When called BEFORE the stream completed normally (the DONE
        # sentinel was not consumed by {#each}), this is interpreted as
        # a client disconnect and:
        #
        # 1. The cancellation token (if any) is tripped BEFORE the
        #    worker is killed, so tools that observe `agent.cancelled?`
        #    at a checkpoint can exit cooperatively. The kill becomes
        #    the fallback for tools stuck inside a blocking I/O call.
        #
        # When called AFTER normal completion, the token is NOT tripped
        # — the request finished on its own; cancellation would only
        # confuse a tool that races to check the flag.
        #
        # Either path:
        #   - Kills the worker thread if still alive.
        #   - Invokes the on_close hook so MCPRackApp can deregister
        #     the token from its per-app registry. Failures in the hook
        #     are logged and swallowed — close must always succeed.
        #
        # Cancellation note: blocking I/O calls (MongoDB query, Parse
        # REST roundtrip) do not observe the token until they return.
        # The Ruby-level `Timeout.timeout` already wrapping each tool is
        # the hard upper bound on wasted work; cancellation reduces it,
        # not eliminates it.
        def close
          # Idempotent — concurrent invocations from the I/O fiber and
          # a disconnect-handler thread short-circuit after the first
          # caller wins the mutex.
          completed_normally = nil
          @close_mutex.synchronize do
            return if @closed
            @closed = true
            completed_normally = @completed_normally
          end
          unless completed_normally
            @cancellation_token&.cancel!(reason: :client_disconnect)
          end
          @worker&.kill if @worker&.alive?
          @worker = nil
          # Deregister listChanged subscribers BEFORE the on_close hook
          # so a subsequent registry mutation cannot push events into
          # the queue after the stream has ended.
          begin
            @unsubscribe_tools&.call
            @unsubscribe_prompts&.call
          rescue StandardError => e
            line = "[Parse::Agent::MCPRackApp::SSEBody] unsubscribe error: #{e.class}: #{e.message}"
            if @logger
              @logger.warn(line)
            else
              warn line
            end
          ensure
            @unsubscribe_tools   = nil
            @unsubscribe_prompts = nil
          end
          if @on_close
            begin
              @on_close.call
            rescue StandardError => e
              line = "[Parse::Agent::MCPRackApp::SSEBody] on_close error: #{e.class}: #{e.message}"
              if @logger
                @logger.warn(line)
              else
                warn line
              end
            end
          end
          @on_close = nil
        end

        private

        def start_worker
          # Subscribe to listChanged events BEFORE spawning the worker
          # so any registry mutation that races with the start of the
          # stream is captured. The callbacks push the corresponding
          # MCP notification onto the same queue the worker writes to.
          queue = @queue
          @unsubscribe_tools = Parse::Agent::Tools.subscribe do
            queue << build_list_changed_event("notifications/tools/list_changed")
          end
          @unsubscribe_prompts = Parse::Agent::Prompts.subscribe do
            queue << build_list_changed_event("notifications/prompts/list_changed")
          end

          @worker = Thread.new do
            Thread.current[:parse_mcp_sse_worker] = true
            started_at = Time.now
            result     = nil

            begin
              # Run the dispatcher in the background. Meanwhile emit heartbeats
              # every @interval seconds until the call completes OR until a
              # tool starts reporting its own progress (@tool_progress_reported).
              #
              # Cancellation note: if the consumer disconnects (close is called),
              # the outer @worker is killed but dispatcher_thread is orphaned and
              # runs to completion. A proper cancellation mechanism (e.g. passing
              # a cancel token into MCPDispatcher) is a separate deferred item
              # (see CHANGELOG / project plans).
              #
              # Each dispatcher_thread is tagged with :parse_mcp_dispatcher so
              # operators can observe concurrency via
              # Parse::Agent::MCPRackApp.active_dispatcher_count. Orphaned
              # dispatchers (from client disconnects) are counted until they
              # complete naturally. Forcible kill is intentionally not attempted
              # here — killing threads inside MCPDispatcher.call risks leaving
              # agent state corrupt. The max_concurrent_dispatchers: constructor
              # option provides a concurrency cap that fires 503 before a new
              # dispatcher is admitted.
              dispatcher_thread = Thread.new do
                Thread.current[:parse_mcp_dispatcher] = true
                begin
                  # The block receives the SSEBody's progress callback so
                  # tools running inside MCPDispatcher.call can emit
                  # notifications/progress events without coupling to
                  # SSEBody internals.
                  result = @dispatcher_blk.call(@progress_callback)
                rescue StandardError => e
                  # Log the unexpected failure (MCPDispatcher.call normally catches
                  # StandardError internally; anything reaching here is unusual).
                  line = "[Parse::Agent::MCPRackApp::SSEBody] Dispatcher error: #{e.class}: #{e.message}"
                  if @logger
                    @logger.warn(line)
                  else
                    warn line
                  end
                  result = { status: 200, body: build_error_envelope(e) }
                end
              end

              while dispatcher_thread.alive?
                dispatcher_thread.join(@interval)
                # Skip the heartbeat when the tool has already reported
                # work-unit progress on the same progressToken. Mixing
                # elapsed-seconds heartbeats with work-unit values would
                # break MCP's increasing-progress convention.
                if dispatcher_thread.alive? && !@tool_progress_reported
                  elapsed = (Time.now - started_at).round(1)
                  @queue << build_progress_event(elapsed)
                end
              end

              # Final response event followed by the done sentinel.
              @queue << build_response_event(result[:body])
              @queue << DONE
            rescue StandardError => e
              # Worker-level safety net for unexpected failures between the
              # dispatcher loop and the queue writes.
              line = "[Parse::Agent::MCPRackApp::SSEBody] Worker error: #{e.class}: #{e.message}"
              if @logger
                @logger.warn(line)
              else
                warn line
              end
              @queue << build_response_event(build_error_envelope(e))
              @queue << DONE
            ensure
              # Belt-and-suspenders: guarantee the DONE sentinel is always
              # pushed regardless of how the worker thread terminates (including
              # Thread.kill / Interrupt / NoMemoryError which bypass rescue).
              # If DONE was already pushed above the rescue nil is a no-op.
              @queue << DONE rescue nil
            end
          end
        end

        # Format a time-based heartbeat `notifications/progress` SSE event.
        #
        # Heartbeats use a dedicated server-generated progressToken
        # (`@heartbeat_token`), independent of the tool's progressToken.
        # The MCP spec requires `progress` to increase monotonically
        # per progressToken; mixing elapsed-seconds heartbeats with
        # work-unit tool reports on the same token would break that.
        # The `total` field is omitted (rather than nil) so the wire
        # shape matches the spec's optional-field convention.
        #
        # @param elapsed [Float] seconds elapsed since the stream started.
        # @return [String] SSE event string (includes trailing blank line).
        def build_progress_event(elapsed)
          data = JSON.generate({
            "jsonrpc" => "2.0",
            "method"  => "notifications/progress",
            "params"  => {
              "progressToken" => @heartbeat_token,
              "progress"      => elapsed,
            },
          })
          "event: progress\ndata: #{data}\n\n"
        end

        # Format a `notifications/tools/list_changed` or
        # `notifications/prompts/list_changed` SSE event. Both
        # notifications have no `params` — the wire shape is just the
        # JSON-RPC envelope with `method` set. SSE event name is
        # "message" since this is not a progress notification (the
        # progress event name is reserved for progress notifications).
        #
        # @param method [String] full MCP method string.
        # @return [String] SSE event string (includes trailing blank line).
        def build_list_changed_event(method)
          data = JSON.generate({
            "jsonrpc" => "2.0",
            "method"  => method,
          })
          "event: message\ndata: #{data}\n\n"
        end

        # Format a tool-internal `notifications/progress` SSE event.
        #
        # The `message` field requires MCP protocol version 2025-03-26 or
        # later. The dispatcher advertises 2025-06-18, so this is safe for
        # current clients. The field is omitted from the wire when nil.
        #
        # @param progress [Numeric]      tool-reported progress value.
        # @param total    [Numeric, nil] tool-reported total, or nil.
        # @param message  [String, nil]  optional status string, or nil.
        # @return [String] SSE event string (includes trailing blank line).
        def build_tool_progress_event(progress, total, message)
          params = {
            "progressToken" => @progress_token,
            "progress"      => progress,
          }
          params["total"]   = total   unless total.nil?
          params["message"] = message if message
          data = JSON.generate({
            "jsonrpc" => "2.0",
            "method"  => "notifications/progress",
            "params"  => params,
          })
          "event: progress\ndata: #{data}\n\n"
        end

        # Build the callback the dispatcher block passes into
        # `MCPDispatcher.call(progress_callback:)`. The callback pushes a
        # tool-progress SSE event to the worker's queue and marks the
        # tool-reporting flag so subsequent time-based heartbeats are
        # suppressed. Exceptions raised by the JSON encoder or the queue
        # are logged via the injected logger and swallowed — a malformed
        # progress report must never abort the underlying tool.
        #
        # The returned Proc is thread-safe by virtue of Queue#<< being
        # thread-safe. The flag write race documented in {#initialize}
        # has a worst-case impact of one extra heartbeat.
        def build_progress_callback
          logger = @logger
          lambda do |progress:, total: nil, message: nil|
            begin
              @tool_progress_reported = true
              @queue << build_tool_progress_event(progress, total, message)
            rescue StandardError => e
              line = "[Parse::Agent::MCPRackApp::SSEBody] progress_callback error: #{e.class}: #{e.message}"
              if logger
                logger.warn(line)
              else
                warn line
              end
            end
            nil
          end
        end

        # Format the final `response` SSE event.
        #
        # @param body [Hash] JSON-RPC response envelope.
        # @return [String] SSE event string (includes trailing blank line).
        def build_response_event(body)
          "event: response\ndata: #{JSON.generate(body)}\n\n"
        end

        # Build an internal-error JSON-RPC envelope (id may be nil at this layer).
        def build_error_envelope(error)
          {
            "jsonrpc" => "2.0",
            "id"      => @req_id,
            "error"   => { "code" => -32_603, "message" => "Internal error" },
          }
        end
      end

      # ---------------------------------------------------------------------------
      # Cancellation registry
      # ---------------------------------------------------------------------------

      # Per-app store of in-flight cancellable requests. Lookups for
      # cancellation are keyed by `[correlation_id, request_id]`, but
      # every {#register} returns an opaque entry-id token that
      # uniquely identifies the registration. {#deregister} requires
      # that entry-id and removes the matching token only when it
      # still owns the slot — so a second registration under the same
      # `(correlation_id, request_id)` key cannot cause the first
      # registration's `on_close` to evict the wrong token.
      #
      # SSEBody registers an entry before spawning its dispatcher_thread
      # and deregisters via the MCPRackApp-supplied on_close hook. A
      # `notifications/cancelled` POST calls {#cancel} to trip the
      # matching CancellationToken.
      #
      # Identity binding: cancellation requires the cancelling request's
      # `Mcp-Session-Id` (sanitized into `agent.correlation_id`) to
      # match the original request's. This prevents an attacker who
      # guesses sequential JSON-RPC request ids from cancelling other
      # clients' in-flight requests. A registration with a nil
      # correlation_id is dropped silently (cancellation is disabled for
      # the request).
      #
      # Scope: per MCPRackApp instance. Cancellation does NOT span
      # multiple mount points within a process, nor multiple processes
      # in a clustered deployment.
      #
      # @api private
      class CancellationRegistry
        def initialize
          @entries = {}
          @mutex   = Mutex.new
        end

        # Register a cancellation token for the given session and
        # request id pair. Returns an opaque entry-id that the caller
        # must pass to {#deregister} to release the slot. If multiple
        # registrations land on the same key (legitimate id-reuse by
        # the same session, or a request retry), only the latest
        # registration is reachable for {#cancel}; older entries can
        # still be safely released via their entry-id even though they
        # no longer "own" the slot.
        #
        # @param correlation_id [String, nil] session identity (nil
        #   disables cancellation for the registration).
        # @param request_id     [Object] JSON-RPC request id (any
        #   JSON-encodable value).
        # @param token          [Parse::Agent::CancellationToken]
        # @return [String, nil] opaque entry-id, or nil when
        #   registration was refused (no correlation_id).
        def register(correlation_id, request_id, token)
          return nil if correlation_id.nil? || correlation_id.to_s.empty?
          entry_id = SecureRandom.uuid
          @mutex.synchronize do
            @entries[[correlation_id, request_id]] = [entry_id, token]
          end
          entry_id
        end

        # Release a previously-registered entry. Removes the slot only
        # when the current owner matches the passed entry-id, so a
        # stale on_close from a request whose slot was overwritten by
        # a sibling registration cannot evict the sibling's token.
        # Idempotent.
        #
        # @return [Boolean] true if this call removed the entry.
        def deregister(correlation_id, request_id, entry_id)
          return false if correlation_id.nil? || correlation_id.to_s.empty?
          return false if entry_id.nil?
          @mutex.synchronize do
            current = @entries[[correlation_id, request_id]]
            if current && current[0] == entry_id
              @entries.delete([correlation_id, request_id])
              true
            else
              false
            end
          end
        end

        # Trip the matching token. Silent no-op when the entry is
        # missing — by design, to avoid a probe oracle.
        #
        # @return [Boolean] true if a matching token was tripped.
        def cancel(correlation_id, request_id, reason: :notifications_cancelled)
          return false if correlation_id.nil? || correlation_id.to_s.empty?
          entry = @mutex.synchronize { @entries[[correlation_id, request_id]] }
          return false unless entry
          entry[1].cancel!(reason: reason)
          true
        end

        # Trip every token registered under the given correlation_id.
        # Used by `DELETE /` session termination — when a client tears
        # down its session, any in-flight requests still running under
        # that correlation_id are cancelled so worker threads exit
        # promptly instead of carrying a doomed result to completion.
        #
        # Silent no-op when no entries match (or correlation_id is
        # blank). Returns the number of tokens tripped.
        def cancel_all_for(correlation_id, reason: :session_terminated)
          return 0 if correlation_id.nil? || correlation_id.to_s.empty?
          tokens = @mutex.synchronize do
            keys = @entries.keys.select { |(cid, _)| cid == correlation_id }
            keys.map { |k| @entries.delete(k)[1] }
          end
          tokens.each { |t| t.cancel!(reason: reason) }
          tokens.size
        end

        # @return [Integer] number of currently-registered tokens. Used
        #   by tests and operator dashboards.
        def size
          @mutex.synchronize { @entries.size }
        end
      end

      # ---------------------------------------------------------------------------
      # Response-header helpers
      # ---------------------------------------------------------------------------

      # Return a per-response copy of the JSON content-type header hash. Always
      # returns a fresh, unfrozen hash so Rack middleware that decorates
      # response headers (Sinatra's xss_header, json_csrf, common_logger,
      # rack-deflater, etc.) can mutate the result without FrozenError, and
      # so that cross-request mutation cannot leak through a shared singleton.
      def json_headers
        JSON_CONTENT_TYPE.dup
      end

      # Return a per-response copy of the SSE header hash. See {#json_headers}.
      def sse_headers
        SSE_HEADERS.dup
      end

      # Sanitize an `Mcp-Session-Id` header value with the same rules as
      # {Parse::Agent#correlation_id=} (URL-safe ASCII, ≤128 chars).
      # Returns the cleaned string, or nil if the input fails the regex.
      # Used by the DELETE handler before passing the value to the
      # cancellation registry; reproducing the regex here keeps the
      # transport layer from instantiating a throwaway Parse::Agent just
      # to borrow its setter.
      # Same character set as {Parse::Agent::CORRELATION_ID_RE}, redeclared
      # here so this file doesn't depend on agent.rb's load order.
      SESSION_ID_RE = /\A[A-Za-z0-9._\-]+\z/.freeze

      def sanitize_session_id(value)
        return nil if value.nil?
        s = value.to_s
        return nil unless SESSION_ID_RE.match?(s)
        s[0, 128]
      end

      # When the request being responded to is `initialize` and the agent
      # carries a (server-assigned or factory-bound) correlation_id,
      # advertise it as the spec-canonical `Mcp-Session-Id` response
      # header so the client can echo it on subsequent requests. The
      # header is emitted ONLY on the initialize response — non-init
      # responses don't carry it, both to avoid leaking the id on every
      # reply and because the client already knows it.
      def merge_session_header!(headers, body, agent)
        return unless body.is_a?(Hash) && body["method"] == "initialize"
        return unless agent && agent.respond_to?(:correlation_id)
        sid = agent.correlation_id
        return if sid.nil? || sid.to_s.empty?
        headers["Mcp-Session-Id"] = sid
      end

      # ---------------------------------------------------------------------------
      # JSON-RPC envelope helpers
      # ---------------------------------------------------------------------------

      # Build a sanitized JSON-RPC 2.0 error envelope.
      #
      # The id defaults to null because most transport-level errors occur before
      # the body has been parsed. Pass `id:` explicitly when the request id is
      # available (e.g. the 503 server-busy response returned from serve_sse
      # after successful body parsing).
      #
      # @param code    [Integer] JSON-RPC error code.
      # @param message [String] sanitized error message.
      # @param id      [Object] JSON-RPC request id; defaults to nil.
      # @return [String] JSON string.
      def json_rpc_error(code, message, id: nil)
        JSON.generate({
          "jsonrpc" => "2.0",
          "id" => id,
          "error" => { "code" => code, "message" => message },
        })
      end

      # Fixed 401 body — no exception details leak to the caller.
      def unauthorized_body
        JSON.generate({
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => { "code" => -32_001, "message" => "Unauthorized" },
        })
      end

      # Normalize the allowed-origins kwarg into a frozen Array of
      # downcased entries. Returns nil when the caller passed nil or an
      # empty array (no check configured). Each entry retains its
      # leading-`.` form for subdomain wildcards.
      def normalize_allowed_origins(value)
        return nil if value.nil?
        arr = Array(value).map { |v| v.to_s.strip.downcase }.reject(&:empty?)
        arr.empty? ? nil : arr.freeze
      end

      # Normalize the `require_custom_header:` kwarg into a
      # `[env_key, expected_value]` pair, or nil when no check is
      # configured. Accepts:
      #   - String header name ("X-MCP-Client") → require presence,
      #     any non-empty value passes.
      #   - Hash { "X-MCP-Client" => "expected-value" } → require
      #     presence AND exact match.
      def normalize_required_custom_header(value)
        return nil if value.nil?
        case value
        when String
          name = value.to_s.strip
          return nil if name.empty?
          [header_env_key(name), nil]
        when Hash
          return nil if value.empty?
          name, expected = value.first
          name = name.to_s.strip
          return nil if name.empty?
          [header_env_key(name), expected.to_s]
        else
          raise ArgumentError,
            "require_custom_header must be a String header name or a Hash { name => expected_value }, " \
            "got #{value.class}"
        end
      end

      # Map an HTTP header name to its Rack env key.
      def header_env_key(name)
        "HTTP_#{name.upcase.tr("-", "_")}"
      end

      # Match an incoming `Origin` header value against
      # `@allowed_origins`. Comparison is case-insensitive on host and
      # scheme. Wildcard via leading `.` matches subdomains:
      # `.example.com` matches `app.example.com` and `example.com`.
      def origin_allowed?(origin)
        return false unless @allowed_origins
        normalized = origin.downcase
        @allowed_origins.any? do |entry|
          if entry.start_with?(".")
            # Strip scheme to compare host
            origin_host = normalized.sub(%r{\Ahttps?://}, "")
            entry_bare = entry[1..]
            origin_host == entry_bare || origin_host.end_with?(".#{entry_bare}") || origin_host.end_with?(entry)
          else
            normalized == entry
          end
        end
      end
    end
  end
end
