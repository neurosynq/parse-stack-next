# encoding: UTF-8
# frozen_string_literal: true

require "json"
require "securerandom"
require "digest"
require_relative "errors"
require_relative "mcp_dispatcher"
require_relative "mcp_subscriptions"
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
    # == Transport (`transport: :streamable_http`)
    #
    # The MCP 2025-06-18 "Streamable HTTP" transport is the recommended,
    # primary transport. Rather than toggling its constituent pieces
    # individually (`streaming:` for POST→SSE, `notifications:` for the
    # server→client `GET /` stream), pass `transport: :streamable_http` to
    # enable the whole transport with one switch:
    #
    #   app = Parse::Agent::MCPRackApp.new(transport: :streamable_http) { |env| ... }
    #
    # That is exactly equivalent to `streaming: true, notifications: true`.
    # `resource_subscriptions: true` may still be added alongside it to
    # upgrade the server→client bus from the plain notification posture to
    # the LiveQuery-backed resource-subscription posture.
    #
    # `transport:` is a closed enum — `:streamable_http`, `:legacy`, or `nil`.
    # `:legacy` and `nil` both select the historical default (no streaming, no
    # server→client stream); the standalone SSE/JSON behavior remains a
    # supported fallback. Passing `transport: :streamable_http` together with
    # an explicit `streaming:` or `notifications:` raises `ArgumentError`,
    # since the switch already owns those toggles.
    #
    # The default is unchanged (`transport: nil`): an existing
    # `MCPRackApp.new { ... }` keeps its non-streaming JSON behavior. A
    # streaming-capable Rack server (Puma, Falcon, Unicorn) is required for
    # `:streamable_http` to have any effect — the WEBrick-backed `MCPServer`
    # buffers responses and cannot deliver it.
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

      # Default bound on concurrently-active streaming dispatchers — and,
      # separately, on concurrently-open listening streams — when the
      # `max_concurrent_dispatchers:` constructor argument is omitted. Finite by
      # default so that enabling a streaming surface (request-scoped SSE or the
      # long-lived `GET /` stream) does not silently expose an unbounded
      # orphan-thread DoS surface. The cap is applied SEPARATELY to each
      # surface, so the effective ceiling across both is up to 2x this value.
      # Pass an explicit `nil` to knowingly opt into the unbounded surface.
      DEFAULT_MAX_CONCURRENT_DISPATCHERS = 100

      # Seconds to wait for a human's elicitation reply before failing
      # closed (refusing the destructive op). Generous by default — a
      # human-in-the-loop approver needs time the tool timeout doesn't
      # allow. Tune via `approval_timeout:`.
      DEFAULT_APPROVAL_TIMEOUT = 300

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

      # Process-wide live-listening-stream counter (see
      # {.active_listening_stream_count}). Class-instance state shared across all
      # MCPRackApp instances in the process.
      @listening_stream_count = 0
      @listening_stream_mutex = Mutex.new

      # Process-wide CUMULATIVE counter of GENUINE orphaned dispatchers — a
      # client disconnected (stream closed before its response was delivered)
      # WHILE the dispatcher thread was still running (see
      # {.abandoned_dispatcher_count}). It deliberately excludes the
      # already-finished-but-undelivered case (dispatcher had pushed its
      # response but the client dropped before {#each} popped it), which is a
      # delivery miss, not an orphan holding a connection-pool slot. A monotonic
      # counter (not a live gauge like the two above): operators watch its rate
      # of increase to detect a disconnect storm against slow tools, which is the
      # orphan-thread pressure signal. (The companion
      # `parse.agent.mcp_dispatcher_abandoned` notification fires for EVERY
      # premature close and carries a `dispatcher_alive` flag, so subscribers can
      # also observe the delivery-miss case and filter on `dispatcher_alive:
      # true` for orphans.) The orphaned dispatcher is cooperatively cancelled
      # (its token is tripped) and bounded in duration by the per-tool Timeout
      # and the clean MongoDB/REST I/O timeouts; it is intentionally NOT
      # force-killed (see {SSEBody#close} for why a hard kill would risk
      # connection-pool corruption).
      @abandoned_dispatcher_count = 0
      @abandoned_dispatcher_mutex = Mutex.new

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
      # @param max_concurrent_dispatchers [Integer, nil] limits the number of
      #   concurrently active dispatcher threads across all SSE connections
      #   served by this app instance (and, separately, the number of open
      #   listening streams). When the limit is reached a new SSE request
      #   immediately receives a 503 JSON-RPC error envelope (`-32000` "server
      #   busy") rather than spawning another dispatcher.
      #
      #   Defaults to a finite {DEFAULT_MAX_CONCURRENT_DISPATCHERS} (100) — so a
      #   streaming surface is bounded out of the box rather than unbounded.
      #   Pass an explicit positive `Integer` to set the cap, or `nil` to
      #   knowingly opt into the unbounded surface (which warns at
      #   construction). A non-positive or non-integer value raises
      #   `ArgumentError`. Use `active_dispatcher_count` to monitor current
      #   concurrency from operator tooling.
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
      # @param resource_subscriptions [Boolean] enable MCP resource
      #   subscriptions (`resources/subscribe` + `notifications/resources/updated`)
      #   bridged onto Parse LiveQuery. Defaults to false. When true, this app
      #   accepts a `GET` with `Accept: text/event-stream` and an
      #   `Mcp-Session-Id` header as a long-lived server→client listening
      #   stream, and advertises the `resources.subscribe` capability on
      #   `initialize` — but ONLY while LiveQuery is enabled
      #   (`Parse.live_query_enabled = true`) and available (a `live_query_url`
      #   is configured). Requires a streaming-capable Rack server (Puma,
      #   Falcon); WEBrick buffers responses and cannot hold the listening
      #   stream open. See docs/mcp_guide.md for the credential-scoping and
      #   single-process caveats.
      # @param subscription_manager [Parse::Agent::MCPSubscriptions::Manager, nil]
      #   inject a pre-built manager (tests, or to share a clustered-notifier
      #   adapter). Takes precedence over `resource_subscriptions:`. When nil
      #   and `resource_subscriptions: true`, a default in-process manager is
      #   constructed.
      # @param transport [Symbol, nil] MCP transport selector. Pass
      #   `:streamable_http` to enable the full MCP 2025-06-18 Streamable HTTP
      #   transport in one switch — exactly equivalent to `streaming: true,
      #   notifications: true` (POST→SSE plus the server→client `GET /`
      #   stream). `resource_subscriptions: true` may still be combined to
      #   upgrade the bus to its LiveQuery-backed posture. `:legacy` (or the
      #   default `nil`) selects the historical non-streaming behavior; the
      #   standalone SSE/JSON path stays a supported fallback. Any other value
      #   raises `ArgumentError`. Passing `:streamable_http` together with an
      #   explicit `streaming:` or `notifications:` also raises, since the
      #   switch already owns those toggles. Requires a streaming-capable Rack
      #   server (Puma, Falcon, Unicorn); has no effect under WEBrick.
      # @raise [ArgumentError] if both or neither of agent_factory/block are given.
      def initialize(agent_factory: nil, max_body_size: DEFAULT_MAX_BODY_SIZE,
                     logger: nil, streaming: nil,
                     heartbeat_interval: DEFAULT_HEARTBEAT_INTERVAL,
                     max_concurrent_dispatchers: DEFAULT_MAX_CONCURRENT_DISPATCHERS,
                     pre_auth_rate_limiter: nil,
                     allowed_origins: nil,
                     require_custom_header: nil,
                     resource_subscriptions: false,
                     subscription_manager: nil,
                     notifications: nil,
                     transport: nil,
                     approval_timeout: DEFAULT_APPROVAL_TIMEOUT,
                     principal_resolver: nil,
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

        # `transport:` is the consolidation switch over the granular
        # `streaming:` / `notifications:` toggles. `streaming` and
        # `notifications` default to nil (not false) precisely so we can tell
        # "operator left it alone" from "operator explicitly set it" and raise
        # on a conflicting combination instead of silently letting the switch
        # win. Closed enum — unknown values fail closed.
        unless transport.nil? || %i[legacy streamable_http].include?(transport)
          raise ArgumentError,
                "transport: must be :streamable_http, :legacy, or nil, got #{transport.inspect}"
        end
        if transport == :streamable_http
          unless streaming.nil? && notifications.nil?
            raise ArgumentError,
                  "transport: :streamable_http already enables streaming and the server-initiated " \
                  "notification stream; do not also pass streaming:/notifications: " \
                  "(resource_subscriptions: may still be combined to upgrade the bus to LiveQuery)"
          end
          streaming     = true
          notifications = true
        end
        # Collapse the nil sentinel to the historical default for the
        # remainder of the constructor (and @streaming below).
        streaming     = false if streaming.nil?
        notifications = false if notifications.nil?

        @agent_factory              = agent_factory || block
        @max_body_size              = max_body_size
        @logger                     = logger
        @streaming                  = streaming
        @heartbeat_interval         = heartbeat_interval
        # The dispatcher cap defaults to the finite DEFAULT_MAX_CONCURRENT_DISPATCHERS
        # (set in the signature). An explicit positive Integer overrides it; an
        # explicit nil knowingly opts into the unbounded surface; anything else
        # is a config error and raises.
        validate_max_concurrent_dispatchers!(max_concurrent_dispatchers)
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

        # Elicitation (human-in-the-loop approval) state, shared across
        # this app's requests and its GET listening streams. The
        # capability registry records (per session) whether the client
        # advertised `elicitation` at initialize; the pending registry
        # holds server→client requests awaiting a reply. Both are cheap
        # and always present; they only do work when
        # Parse::Agent.require_approval_for opts a tier in.
        @elicitation_capabilities   = Parse::Agent::ClientCapabilityRegistry.new
        @pending_elicitations       = Parse::Agent::PendingElicitationRegistry.new
        @approval_timeout           = approval_timeout

        # Binds each MCP session id to the principal that established it so a
        # listening stream can't be hijacked by another authenticated caller.
        # Same per-instance / single-process scope as @cancellation_registry.
        @session_owners             = SessionOwnerRegistry.new
        if principal_resolver && !principal_resolver.respond_to?(:call)
          raise ArgumentError, "principal_resolver must respond to #call"
        end
        @principal_resolver         = principal_resolver

        # Listening-stream coordinator (the server→client broadcast bus
        # backing resource subscriptions, MCP elicitation, and
        # general-purpose server-initiated notifications). An injected
        # manager wins. Otherwise:
        #   - `resource_subscriptions: true` builds a LiveQuery-backed
        #     manager whose `supported?` resolves live (advertises
        #     `resources.subscribe` and serves subscribe POSTs).
        #   - `notifications: true` (without resource subscriptions) builds
        #     a manager in `supported: false` posture: the GET listening
        #     stream + `#notify` bus work, but `resources.subscribe` stays
        #     unadvertised and subscribe POSTs fail closed. This is the
        #     decoupling lever — a server can push arbitrary notifications
        #     without enabling LiveQuery resource subscriptions.
        # nil disables the GET listening stream entirely.
        @subscription_manager =
          if subscription_manager
            subscription_manager
          elsif resource_subscriptions
            Parse::Agent::MCPSubscriptions::Manager.new(logger: @logger)
          elsif notifications
            Parse::Agent::MCPSubscriptions::Manager.new(logger: @logger, supported: false)
          end

        # Warn operators who enable a streaming surface AND have explicitly
        # opted into an unbounded dispatcher cap. Both request-scoped SSE
        # (streaming:) and the long-lived GET listening stream
        # (resource_subscriptions:/notifications:, which set
        # @subscription_manager) spawn per-connection threads; an unbounded
        # endpoint is a practical DoS surface — a slow or hostile client opening
        # connections faster than they close can exhaust the host thread pool and
        # downstream Parse connection pool. The cap bounds each surface
        # SEPARATELY, so the effective ceiling is up to 2x max_concurrent_dispatchers
        # across both. The default is now the finite DEFAULT_MAX_CONCURRENT_DISPATCHERS,
        # so a nil here means the operator deliberately chose `nil` (unbounded) —
        # we warn once at construction so the choice is visible.
        if (streaming || @subscription_manager) && @max_concurrent_dispatchers.nil?
          surface = streaming ? "streaming: true" : "resource_subscriptions/notifications"
          line = "[Parse::Agent::MCPRackApp] #{surface} with an explicitly unbounded dispatcher cap " \
                 "(max_concurrent_dispatchers: nil). This is an orphan-thread DoS surface. " \
                 "Prefer the finite default (#{DEFAULT_MAX_CONCURRENT_DISPATCHERS}) or pass a value sized to " \
                 "~2x your Puma max_threads. See docs/mcp_guide.md for sizing guidance."
          if @logger
            @logger.warn(line)
          else
            warn line
          end
        end
      end

      # The listening-stream coordinator backing this app's server→client
      # bus, or nil when neither resource subscriptions nor notifications
      # are enabled. Exposed so a clustered/Redis notifier adapter or an
      # out-of-band publisher can reach the bus directly. Direct
      # `#publish` accepts arbitrary messages (notifications OR id-bearing
      # requests); prefer {#notify} for the validated notification path.
      # @return [Parse::Agent::MCPSubscriptions::Manager, nil]
      attr_reader :subscription_manager

      # Push a server-initiated JSON-RPC NOTIFICATION to a session's open
      # listening stream. This is the public front door for application
      # code to deliver unsolicited `notifications/*` events (the GET
      # stream must be open for the session — open it client-side with a
      # `GET` carrying `Accept: text/event-stream` + `Mcp-Session-Id`).
      #
      # The envelope is built server-side as a notification — it never
      # carries an `id`, which is what distinguishes it from the
      # server-initiated *request* path (e.g. elicitation/create). A
      # caller wanting an id-bearing request uses the internal
      # `subscription_manager.publish` seam, not this method.
      #
      # @param session_id [String] the target session (Mcp-Session-Id).
      # @param method [String] a non-empty JSON-RPC method, e.g.
      #   `"notifications/custom"`.
      # @param params [Hash, nil] optional params object.
      # @return [Boolean] true if a listening stream received it; false
      #   when notifications are disabled or no stream is attached.
      # @raise [ArgumentError] when `method` is blank or not a String.
      def notify(session_id, method:, params: nil)
        unless method.is_a?(String) && !method.empty?
          raise ArgumentError, "notify: method must be a non-empty String"
        end
        return false unless @subscription_manager
        envelope = { "jsonrpc" => "2.0", "method" => method }
        envelope["params"] = params unless params.nil?
        !!@subscription_manager.publish(session_id, envelope)
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

      # Process-wide count of currently-open GET listening streams across all
      # MCPRackApp instances. A listening stream is long-lived (the server→client
      # notification channel) — each pins a server worker thread in #each plus a
      # heartbeat thread — so it is bounded SEPARATELY from request-scoped SSE
      # dispatchers (which #each, dispatch once, then close). Used as the soft
      # cap in {#serve_listening_stream}. Maintained by {ListeningStreamBody}
      # via {.adjust_listening_stream_count}; unlike a Thread.list scan this is
      # an explicit counter because the heartbeat thread is intentionally not
      # tagged as a dispatcher.
      def self.active_listening_stream_count
        @listening_stream_mutex.synchronize { @listening_stream_count }
      end

      # @api private — bump the live listening-stream counter by `delta`
      #   (+1 when a stream begins iterating, -1 when it closes).
      def self.adjust_listening_stream_count(delta)
        @listening_stream_mutex.synchronize { @listening_stream_count += delta }
      end

      # Process-wide CUMULATIVE count of GENUINE orphaned dispatchers — a client
      # disconnect that closed the stream while the dispatcher thread was still
      # running. Excludes already-finished-but-undelivered closes (a delivery
      # miss, not an orphan). Unlike {.active_dispatcher_count} /
      # {.active_listening_stream_count} this is a monotonic total, not a live
      # gauge — operators alert on its *rate* of increase, the orphan-thread
      # pressure signal under a disconnect-against-slow-tools storm. EVERY
      # premature close (orphan or delivery-miss) also emits a
      # `parse.agent.mcp_dispatcher_abandoned` ActiveSupport::Notifications event
      # carrying `dispatcher_alive:`, so subscribers wanting the broader
      # delivery-miss signal can filter there. Reset is not supported (counters
      # are process-lifetime); subtract a baseline if you need a windowed delta.
      def self.abandoned_dispatcher_count
        @abandoned_dispatcher_mutex.synchronize { @abandoned_dispatcher_count }
      end

      # @api private — increment the cumulative abandoned-dispatcher counter.
      #   Called by {SSEBody#close} on the client-disconnect path.
      def self.record_abandoned_dispatcher!
        @abandoned_dispatcher_mutex.synchronize { @abandoned_dispatcher_count += 1 }
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
          # Wake any tool thread blocked on an elicitation reply for this
          # session (it returns `unavailable` → fail closed) and drop the
          # session's cached elicitation capability.
          @pending_elicitations.abort_all_for(clean_sid, :session_terminated)
          @elicitation_capabilities.forget(clean_sid)
          # Tear down any resource subscriptions and the listening stream
          # bound to this session so a terminated session leaves no LiveQuery
          # sockets behind.
          @subscription_manager&.detach_listener(clean_sid)
          # Drop the owner binding so the id can be reclaimed after explicit
          # termination (only here — not on mere stream close, so a reconnect
          # keeps its claim).
          @session_owners.forget(clean_sid)
          return [204, json_headers, [""]]
        end

        # 0d. GET listening stream — the MCP 2025-06-18 Streamable HTTP
        #     server→client channel that carries unsolicited
        #     `notifications/resources/updated`. Only when resource
        #     subscriptions are enabled, the client opted into SSE, and a
        #     valid Mcp-Session-Id is present. Authenticated via the same
        #     agent_factory as POST: the session id is a server-issued
        #     bearer capability (returned on initialize), so possession of
        #     it plus a valid agent gates the stream.
        if env["REQUEST_METHOD"] == "GET" && @subscription_manager &&
           env["HTTP_ACCEPT"].to_s.include?("text/event-stream")
          return serve_listening_stream(env)
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
        #     A method-less JSON-RPC RESPONSE ({jsonrpc,id,result|error}) is
        #     NOT malformed: it is the client's reply to a server-issued
        #     elicitation/create request. Let it through here; it is routed
        #     (session-bound) after the agent_factory resolves the session.
        unless (body.is_a?(Hash) && body["method"].is_a?(String) && !body["method"].empty?) ||
               elicitation_reply?(body)
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
               body["method"] == "notifications/cancelled" ||
               elicitation_reply?(body)
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

        # 5a-i. Surface the silent-ungated-writes footgun. A write/admin agent
        #     served over MCP with no approval tier configured runs every
        #     destructive tool without a human gate; warn once per process so
        #     the operator notices (mirrors the unrestricted-endpoints warning).
        if agent.respond_to?(:permissions) &&
           %i[write admin].include?(agent.permissions) &&
           Parse::Agent.require_approval_for.empty?
          Parse::Agent.warn_mcp_writes_unguarded!
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

        # 5b-ii. Capture the client's elicitation capability at initialize.
        #     The server reads (does not advertise) the client's
        #     `capabilities.elicitation`; the approval gate consults this
        #     per session before attempting a server→client prompt.
        if body.is_a?(Hash) && body["method"] == "initialize" &&
           agent.respond_to?(:correlation_id) && agent.correlation_id
          supported = !!(body.dig("params", "capabilities", "elicitation"))
          @elicitation_capabilities.set(agent.correlation_id, supported)
          # Authoritatively bind this session to the initializing principal so
          # only the same principal can later attach a listening stream for it
          # (owner-binding; see SessionOwnerRegistry).
          @session_owners.bind(agent.correlation_id, principal_fingerprint(agent, env))
        end

        # 5b-iii. Elicitation reply ingress. A method-less JSON-RPC
        #     RESPONSE is the client's answer to a server-issued
        #     elicitation/create. Route it into the pending registry,
        #     session-bound by the same `correlation_id` the cancellation
        #     path uses, so one session can never answer another's prompt.
        #     Failures (no correlation_id, no match) are silent 202 no-ops
        #     to avoid a probe oracle — exactly like notifications/cancelled.
        if elicitation_reply?(body)
          route_elicitation_reply(agent, body)
          return [202, json_headers, [""]]
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
      # True when `body` is a JSON-RPC RESPONSE (no "method"; carries an
      # "id" plus "result" or "error") — the client's reply to a
      # server-issued elicitation/create request.
      def elicitation_reply?(body)
        body.is_a?(Hash) && !body.key?("method") && body.key?("id") &&
          (body.key?("result") || body.key?("error"))
      end

      # Route an elicitation reply into the pending registry, bound to the
      # answering session's correlation id. Silent no-op on any miss.
      def route_elicitation_reply(agent, body)
        correlation_id = agent.respond_to?(:correlation_id) ? agent.correlation_id : nil
        elic_id = body["id"]
        return if correlation_id.nil? || elic_id.nil?
        @pending_elicitations.deliver(correlation_id, elic_id, map_elicitation_action(body))
      end

      # Map an elicitation reply envelope to an approval action symbol.
      # An `error` reply, an unknown/declined action, or an `accept` whose
      # `content.approve` is explicitly false all map toward refusal.
      def map_elicitation_action(body)
        return :cancel if body.key?("error")
        result = body["result"]
        return :cancel unless result.is_a?(Hash)
        case result["action"]
        when "accept"
          content = result["content"]
          if content.is_a?(Hash) && content.key?("approve") && content["approve"] == false
            :decline
          else
            :accept
          end
        when "decline"
          :decline
        else
          :cancel
        end
      end

      # Build the per-request MCP elicitation approval gate, or nil when no
      # tier opts in (the common path). The gate self-fails-closed: with no
      # subscription manager (no GET stream / non-streaming transport) its
      # listener check returns false, so a required approval is REFUSED
      # rather than silently executed.
      def build_approval_gate(agent)
        return nil if Parse::Agent.require_approval_for.empty?
        return nil unless agent.respond_to?(:correlation_id)
        mgr = @subscription_manager
        Parse::Agent::MCPElicitationGate.new(
          correlation_id:   agent.correlation_id,
          pending:          @pending_elicitations,
          publish:          ->(cid, req) { mgr ? !!mgr.publish(cid, req) : false },
          capability_check: ->(cid) { @elicitation_capabilities.get(cid) },
          listener_check:   ->(cid) { mgr ? mgr.listener?(cid) : false },
          timeout:          @approval_timeout,
        )
      end

      def serve_json(body, agent)
        result = Parse::Agent::MCPDispatcher.call(
          body: body, agent: agent, logger: @logger,
          subscription_manager: @subscription_manager,
          approval_gate: build_approval_gate(agent),
        )
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
            body:                 body,
            agent:                agent,
            logger:               logger,
            progress_callback:    progress_callback,
            cancellation_token:   cancellation_token,
            subscription_manager: @subscription_manager,
            approval_gate:        build_approval_gate(agent),
          )
        end

        headers = sse_headers
        merge_session_header!(headers, body, agent)
        [200, headers, sse_body]
      end

      # Serve a long-lived GET listening SSE stream for resource-subscription
      # delivery (MCP 2025-06-18 Streamable HTTP server→client channel).
      #
      # Unlike {#serve_sse} (response-scoped: one dispatch then close), this
      # stream outlives any single request — it stays open emitting
      # `notifications/resources/updated` for the session's subscriptions until
      # the client disconnects or the session is terminated via DELETE.
      #
      # Authenticated via the same `agent_factory` as POST. The `Mcp-Session-Id`
      # header keys the listener; it is a server-issued capability (returned on
      # `initialize`), so possession + a valid agent gates the stream. The agent
      # itself is not retained — subscriptions (and their credentials) are
      # created by the `resources/subscribe` POST, not here.
      #
      # @param env [Hash] Rack env.
      # @return [Array] Rack triple with a {ListeningStreamBody}, or an error.
      def serve_listening_stream(env)
        begin
          agent = @agent_factory.call(env)
        rescue Parse::Agent::Unauthorized
          @logger&.warn("[Parse::Agent::MCPRackApp] Unauthorized listening stream")
          return [401, json_headers, [unauthorized_body]]
        rescue StandardError => e
          @logger&.warn("[Parse::Agent::MCPRackApp] Factory error (listening): #{e.class.name}")
          return [500, json_headers, [json_rpc_error(-32_603, "Internal error")]]
        end

        session_id = sanitize_session_id(env["HTTP_MCP_SESSION_ID"].to_s)
        if session_id.nil? || session_id.empty?
          return [400, json_headers, [json_rpc_error(-32_600, "Missing or invalid Mcp-Session-Id")]]
        end

        # The origin allowlist (when configured) guards the listening stream
        # the same way it guards POST — a browser-driven cross-origin GET to
        # an SSE endpoint is the analogous CSRF surface.
        if @allowed_origins
          origin = env["HTTP_ORIGIN"].to_s.strip
          unless origin.empty? || origin_allowed?(origin)
            return [403, json_headers, [json_rpc_error(-32_700, "Origin not allowed")]]
          end
        end

        # Owner-binding: only the principal that established this session (or,
        # for an id that never went through initialize, the first principal to
        # attach) may open its listening stream. A different authenticated
        # caller who knows/guesses the id is refused, closing the
        # cross-session subscribe/evict hijack.
        #
        # We return a distinguishable 403 on mismatch (vs 200 when the id is
        # unclaimed). That is a deliberate, narrow existence oracle —
        # acceptable because server-assigned ids are SecureRandom.uuid and so
        # infeasible to enumerate. (Contrast the cancellation/elicitation
        # paths, which return a uniform 202 because their ids are
        # client-chosen and guessable.)
        unless @session_owners.authorize_attach(session_id, principal_fingerprint(agent, env))
          @logger&.warn("[Parse::Agent::MCPRackApp] Listening stream denied: session owned by another principal")
          return [403, json_headers, [json_rpc_error(-32_600, "Mcp-Session-Id is owned by another principal")]]
        end

        # Soft cap on concurrent listening streams, mirroring serve_sse's
        # dispatcher cap. Listening streams are bounded SEPARATELY from
        # request-scoped SSE dispatchers and reuse the same configured ceiling,
        # so total streaming thread exposure can reach 2x max_concurrent_dispatchers
        # (up to N request SSE + N listening streams), not N. Like serve_sse the
        # check is best-effort (not lock-protected against the per-stream
        # increment in #each), so a burst can briefly overshoot — acceptable for
        # a soft cap.
        if @max_concurrent_dispatchers &&
           MCPRackApp.active_listening_stream_count >= @max_concurrent_dispatchers
          return [503, json_headers, [json_rpc_error(-32_000, "server busy")]]
        end

        body = ListeningStreamBody.new(@subscription_manager, session_id, @heartbeat_interval, @logger)
        [200, sse_headers, body]
      end

      # Derive a stable, privacy-preserving principal fingerprint for the
      # authenticated agent, used to owner-bind MCP sessions.
      #
      # An operator `principal_resolver:` callable wins (it lets a
      # master-key-everywhere deployment that authenticates users upstream
      # supply a real per-user identity). Otherwise the agent's own scope is
      # used: a hashed session_token, then acl_user, then acl_role. A bare
      # master-key agent with no scope falls back to the shared "mk"
      # fingerprint — owner-binding is then a no-op (documented), since all
      # such agents are indistinguishable admins.
      #
      # @param agent [Parse::Agent]
      # @param env [Hash] the Rack env (passed to the resolver).
      # @return [String]
      def principal_fingerprint(agent, env)
        if @principal_resolver
          resolved = @principal_resolver.call(agent, env)
          return "op:#{Digest::SHA256.hexdigest(resolved.to_s)[0, 32]}" unless resolved.nil? || resolved.to_s.empty?
        end
        if agent.respond_to?(:session_token) && !agent.session_token.to_s.empty?
          return "st:#{Digest::SHA256.hexdigest(agent.session_token.to_s)[0, 32]}"
        end
        # acl_user / acl_role scopes are the RAW constructor input, which may be
        # a Parse::User / Parse::Pointer / Parse::Role object whose bare #to_s
        # is a per-instance `#<...:0x...>` string — using that directly would
        # give the initialize and GET agents different fingerprints and
        # false-reject the legitimate owner. Derive a stable id the same way
        # #auth_context does: objectId for user/pointer scopes, role name for
        # role scopes. (These are unverified constructor assertions, so the
        # fingerprint is only as trustworthy as the factory's identity
        # assignment — same caveat as the "mk" case; session_token is verified.)
        if agent.respond_to?(:acl_user_scope) && agent.acl_user_scope
          s = agent.acl_user_scope
          id = s.respond_to?(:id) ? s.id : s.to_s
          return "au:#{id}" unless id.nil? || id.to_s.empty?
        end
        if agent.respond_to?(:acl_role_scope) && agent.acl_role_scope
          s = agent.acl_role_scope
          name = s.respond_to?(:name) ? s.name : s.to_s.sub(/\Arole:/, "")
          return "ar:#{name}" unless name.nil? || name.to_s.empty?
        end
        "mk"
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
        # @param heartbeat_waiter [Proc, nil] test hook. Called as
        #   `waiter.call(dispatcher_thread, interval)` once per heartbeat
        #   iteration; must block until either the dispatcher finishes or
        #   `interval` elapses. Default delegates to
        #   `dispatcher_thread.join(interval)`. Tests inject a queue-driven
        #   waiter so heartbeat cadence is deterministic and not subject
        #   to OS scheduler jitter.
        def initialize(progress_token, req_id, interval, logger,
                       cancellation_token: nil, on_close: nil,
                       heartbeat_waiter: nil, &dispatcher_blk)
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
          @heartbeat_waiter       = heartbeat_waiter ||
                                    Thread.current[:parse_mcp_sse_heartbeat_waiter] ||
                                    ->(t, i) { t.join(i) }
          @queue                  = Queue.new
          @worker                 = nil
          # The dispatcher thread spawned inside @worker. Published under
          # @close_mutex once started so {#close} can snapshot its liveness for
          # the abandonment signal. Never force-killed (see #close).
          @dispatcher_thread      = nil
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
        # 1. The cancellation token (if any) is tripped, so a tool that
        #    observes `agent.cancelled?` at a checkpoint exits
        #    cooperatively. The orphaned dispatcher is NOT force-killed
        #    (see below); its lifetime is bounded by the per-tool
        #    Timeout and the clean MongoDB/REST I/O deadlines.
        # 2. The abandonment is recorded — a `parse.agent.mcp_dispatcher_abandoned`
        #    notification is emitted for every premature close, and the
        #    process-wide {MCPRackApp.abandoned_dispatcher_count} counter is
        #    bumped when the dispatcher was still running (a genuine orphan) —
        #    so operators can see disconnect-against-slow-tool pressure even
        #    though each orphan is individually bounded.
        #
        # When called AFTER normal completion, neither happens — the
        # request finished on its own; cancellation would only confuse a
        # tool that races to check the flag, and there is nothing to
        # report.
        #
        # Either path:
        #   - Kills the WORKER thread (the heartbeat loop) if still alive.
        #   - Invokes the on_close hook so MCPRackApp can deregister
        #     the token from its per-app registry. Failures in the hook
        #     are logged and swallowed — close must always succeed.
        #
        # Why the dispatcher is not force-killed: a `Thread#kill` (or a
        # foreign `Thread#raise`) skips the DB driver's rescue-based
        # connection-invalidation, so `connection_pool`'s `ensure` could
        # return a half-used connection to the pool and corrupt a later
        # request that reuses it. Blocking I/O calls do not observe the
        # cancellation token, but they ARE bounded by the per-tool
        # `Timeout.timeout` (Tools::TOOL_TIMEOUTS, 5–60s) and the clean
        # MongoDB `socket_timeout` (10s) / REST `timeout` (30s) deadlines,
        # which reclaim the connection-pool slot through the driver's
        # clean error path. Cooperative cancellation reduces wasted work;
        # the bounded timeouts cap it; a forcible kill is intentionally
        # avoided.
        def close
          # Idempotent — concurrent invocations from the I/O fiber and
          # a disconnect-handler thread short-circuit after the first
          # caller wins the mutex.
          completed_normally = nil
          dispatcher_alive   = false
          @close_mutex.synchronize do
            return if @closed
            @closed = true
            completed_normally = @completed_normally
            dispatcher_alive   = @dispatcher_thread&.alive? || false
          end
          unless completed_normally
            @cancellation_token&.cancel!(reason: :client_disconnect)
            record_abandonment(dispatcher_alive)
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

        # Record a client-disconnect abandonment. `dispatcher_alive` reports
        # whether the dispatcher was still running at close time (true = a
        # genuine mid-flight orphan holding its slot; false = it had already
        # finished but the DONE sentinel was never consumed — a delivery miss).
        #
        # The cumulative counter tracks GENUINE orphans only (gated on
        # `dispatcher_alive`), matching {MCPRackApp.abandoned_dispatcher_count}'s
        # contract. The `parse.agent.mcp_dispatcher_abandoned` notification fires
        # for EVERY premature close and carries the flag, so subscribers can see
        # delivery misses too and filter on `dispatcher_alive: true` for orphans.
        # Best-effort and fully guarded — observability must never break stream
        # teardown.
        #
        # Subscriber discipline matches the rest of the SDK's instrumentation:
        # subscribers run synchronously on the thread that calls close (a Rack
        # I/O fiber or a disconnect-handler thread); keep them cheap.
        def record_abandonment(dispatcher_alive)
          MCPRackApp.record_abandoned_dispatcher! if dispatcher_alive
          return unless defined?(ActiveSupport::Notifications)
          ActiveSupport::Notifications.instrument(
            "parse.agent.mcp_dispatcher_abandoned",
            reason:            :client_disconnect,
            dispatcher_alive:  dispatcher_alive,
            request_id:        @req_id,
          )
        rescue StandardError => e
          line = "[Parse::Agent::MCPRackApp::SSEBody] abandonment-record error: #{e.class}: #{e.message}"
          @logger ? @logger.warn(line) : warn(line)
        end

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
              # Cancellation contract on client disconnect (close is called):
              # the outer @worker is killed and the dispatcher thread is
              # cooperatively cancelled — {#close} trips the cancellation token
              # so a tool checking `agent.cancelled?` at a checkpoint exits
              # promptly. The dispatcher is NOT force-killed: a `Thread#kill`
              # (or a foreign `Thread#raise`) would skip the DB driver's
              # rescue-based connection-invalidation, so connection_pool's
              # ensure could check a half-used connection back in and corrupt a
              # subsequent request. Instead the orphan's lifetime is bounded by
              # (a) for BUILT-IN tools, the per-tool `Timeout.timeout` budget
              # (Tools::TOOL_TIMEOUTS, 5–60s, applied inside each built-in tool
              # via Tools.with_timeout) and (b) the clean MongoDB `socket_timeout`
              # (10s) / REST `timeout` (30s) I/O deadlines, which DO route through
              # the driver's clean error path. For CUSTOM registered tools the
              # handler IS wrapped by Tools.invoke in its declared `timeout:`
              # (default 30s; register rejects a non-positive value), so a
              # blocking or looping custom handler is bounded just like a
              # built-in. (A handler that swallows ToolTimeoutError or blocks in
              # an uninterruptible C call can still evade Timeout, but the default
              # path is bounded.) The
              # max_concurrent_dispatchers: cap still bounds how MANY orphans can
              # exist; the abandonment counter + `parse.agent.mcp_dispatcher_abandoned`
              # notification surface how OFTEN it happens (see {#close} and
              # {.abandoned_dispatcher_count}).
              #
              # Each dispatcher thread is tagged with :parse_mcp_dispatcher so
              # operators can observe live concurrency via
              # {.active_dispatcher_count}. The spawn and the publish to
              # @dispatcher_thread happen together under @close_mutex so a
              # concurrent {#close} (e.g. an out-of-band disconnect-handler
              # thread) observes the thread as either entirely absent or fully
              # published — never a created-but-unpublished orphan it would
              # miscount as a delivery miss.
              dispatcher_thread = nil
              @close_mutex.synchronize do
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
                @dispatcher_thread = dispatcher_thread
              end

              while dispatcher_thread.alive?
                @heartbeat_waiter.call(dispatcher_thread, @interval)
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
      # Listening stream body (resource subscriptions)
      # ---------------------------------------------------------------------------

      # Rack body for the long-lived GET listening stream that carries
      # `notifications/resources/updated` to a subscribing client.
      #
      # On {#each} it registers a delivery callback with the
      # {Parse::Agent::MCPSubscriptions::Manager} keyed by the session id, then
      # blocks reading from an internal queue and yields SSE-formatted
      # notification events as they are published by the LiveQuery bridge. A
      # periodic SSE comment heartbeat keeps the connection warm and surfaces a
      # dead socket as a write error so the Rack server invokes {#close}.
      #
      # {#close} detaches the listener and tears down every LiveQuery
      # subscription bound to the session — so a dropped stream leaves no
      # LiveQuery sockets behind. Re-opening the stream requires the client to
      # re-issue its `resources/subscribe` calls (subscriptions do not survive a
      # listening-stream disconnect in this single-process implementation).
      #
      # The publish callback runs on a LiveQuery dispatcher / debounce thread
      # and only pushes to the thread-safe queue; all `yield`s happen on the
      # Rack I/O thread driving {#each}, mirroring {SSEBody}'s threading model.
      #
      # @api private
      class ListeningStreamBody
        DONE = :__listening_done__

        # @param manager [Parse::Agent::MCPSubscriptions::Manager]
        # @param session_id [String] sanitized Mcp-Session-Id.
        # @param heartbeat_interval [Numeric] SSE comment heartbeat period in
        #   seconds; `<= 0` disables heartbeats.
        # @param logger [#warn, nil]
        def initialize(manager, session_id, heartbeat_interval, logger)
          @manager            = manager
          @session_id         = session_id
          @heartbeat_interval = heartbeat_interval
          @logger             = logger
          @queue              = Queue.new
          @heartbeat          = nil
          @closed             = false
          @counted            = false
          @close_mutex        = Mutex.new
        end

        # Rack body interface — called once by the Rack server.
        # @yield [String] SSE-formatted event / comment strings.
        def each
          queue = @queue
          # Count this stream against the concurrent-listening-stream soft cap.
          # Incrementing here (in #each, not the constructor) means a body the
          # Rack server never iterates — or a client that disconnects before
          # iteration — never inflates the counter; the matching decrement is in
          # #close, which #each's `ensure` always runs.
          MCPRackApp.adjust_listening_stream_count(1)
          @counted = true
          @manager.attach_listener(@session_id) do |notification|
            queue << format_event(notification)
          end
          # Initial comment flushes response headers and confirms the stream.
          yield ": connected\n\n"
          start_heartbeat
          loop do
            msg = @queue.pop
            break if msg == DONE
            yield msg
          end
        ensure
          close
        end

        # Terminate the stream: stop heartbeats, detach the listener, and tear
        # down the session's LiveQuery subscriptions. Idempotent.
        def close
          @close_mutex.synchronize do
            return if @closed
            @closed = true
          end
          # Balance the #each increment exactly once (close is idempotent via
          # @closed, and only #each sets @counted).
          MCPRackApp.adjust_listening_stream_count(-1) if @counted
          @heartbeat&.kill
          @heartbeat = nil
          begin
            @manager.detach_listener(@session_id)
          rescue StandardError => e
            line = "[Parse::Agent::MCPRackApp::ListeningStreamBody] detach error: #{e.class}: #{e.message}"
            @logger ? @logger.warn(line) : warn(line)
          end
          @queue << DONE rescue nil
        end

        private

        def start_heartbeat
          return unless @heartbeat_interval && @heartbeat_interval > 0
          queue    = @queue
          interval = @heartbeat_interval
          @heartbeat = Thread.new do
            loop do
              sleep interval
              queue << ": keep-alive\n\n"
            end
          end
        end

        # SSE wire form for a server→client notification. Event name "message"
        # (not "progress"/"response", which are reserved for the request-scoped
        # SSE path).
        def format_event(notification)
          "event: message\ndata: #{JSON.generate(notification)}\n\n"
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
      # Binds an MCP session id to the principal that established it, so a
      # listening stream (the server→client notification channel) can only be
      # attached by the same principal — closing the cross-session hijack where
      # any authenticated caller who knows/guesses another session's id could
      # subscribe to its notifications or evict its listener via overwrite.
      #
      # Trust model and limitations (mirrored in the docs):
      #
      # - **Initialize-bound vs TOFU.** A session established through an
      #   `initialize` POST is bound to that caller's principal authoritatively.
      #   A session id that was never seen by `initialize` (the decoupled
      #   `notifications:` bus, where app code pushes to arbitrary ids) is
      #   claimed trust-on-first-use by whoever attaches a listener first;
      #   subsequent attaches by a different principal are refused. TOFU is
      #   strictly better than the prior bearer model (eviction-after-claim is
      #   closed) but a first-mover attacker can still claim an unused id — so
      #   notification-bus ids should be high-entropy.
      # - **Per-instance / single-process**, exactly like CancellationRegistry:
      #   it does not span Puma workers or survive restart. In a cluster the
      #   GET stream and the initialize POST may land on different workers, so
      #   the initialize-binding degrades to TOFU there.
      # - **Principal fidelity depends on the factory.** The fingerprint is
      #   derived from the agent the factory builds (session_token → acl_user →
      #   acl_role), or an operator-supplied `principal_resolver`. A
      #   master-key-everywhere factory yields one shared "mk" principal, so
      #   owner-binding is a no-op unless a `principal_resolver` (or
      #   per-user impersonation) supplies a real identity.
      #
      # LRU-bounded so an initialize-without-DELETE stream of sessions can't
      # grow it without limit; evicting an active owner just downgrades it to
      # TOFU on the next attach.
      class SessionOwnerRegistry
        DEFAULT_MAX_ENTRIES = 10_000

        def initialize(max_entries: DEFAULT_MAX_ENTRIES)
          @owners = {} # session_id => principal fingerprint (insertion-ordered for LRU)
          @max    = max_entries
          @mutex  = Mutex.new
        end

        # Authoritatively bind a session to a principal (initialize). A
        # re-initialize by the same caller refreshes the binding.
        def bind(session_id, fingerprint)
          return if blank?(session_id) || blank?(fingerprint)
          @mutex.synchronize do
            @owners.delete(session_id)
            @owners[session_id] = fingerprint
            evict_lru!
          end
        end

        # Authorize a listening-stream attach. Returns true when the session is
        # unclaimed (claims it TOFU for this principal) or already owned by this
        # principal (refreshing its LRU position); false on a principal
        # mismatch. Blank inputs fail closed.
        def authorize_attach(session_id, fingerprint)
          return false if blank?(session_id) || blank?(fingerprint)
          @mutex.synchronize do
            owner = @owners[session_id]
            if owner.nil?
              @owners[session_id] = fingerprint
              evict_lru!
              true
            elsif owner == fingerprint
              @owners.delete(session_id)
              @owners[session_id] = owner
              true
            else
              false
            end
          end
        end

        # Drop a session's owner binding (explicit DELETE termination). Not
        # called on mere stream close, so a reconnecting owner keeps its claim
        # and an attacker can't grab the id during a brief disconnect.
        def forget(session_id)
          return if blank?(session_id)
          @mutex.synchronize { @owners.delete(session_id) }
        end

        # @return [Integer] current number of bound sessions (tests/metrics).
        def size
          @mutex.synchronize { @owners.size }
        end

        private

        # Hash preserves insertion order; #shift drops the oldest (LRU) entry.
        def evict_lru!
          @owners.shift while @owners.size > @max
        end

        def blank?(value)
          value.nil? || value.to_s.empty?
        end
      end

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

      # Validate the `max_concurrent_dispatchers:` argument. A positive Integer
      # caps the streaming surface; an explicit `nil` is a knowing opt-in to the
      # unbounded surface (warned about at construction); anything else is a
      # code-level config error and raises loudly.
      #
      # @param value [Object] the constructor argument.
      # @raise [ArgumentError] when value is neither nil nor a positive Integer.
      def validate_max_concurrent_dispatchers!(value)
        return if value.nil?
        unless value.is_a?(Integer) && value >= 1
          raise ArgumentError,
                "max_concurrent_dispatchers must be a positive Integer or nil (unbounded), got #{value.inspect}"
        end
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
