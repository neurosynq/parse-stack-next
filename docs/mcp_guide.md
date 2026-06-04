# Parse Stack MCP Guide

## Overview

The Model Context Protocol (MCP) is a standardized JSON-RPC 2.0-based interface that lets external tools and agents interact with a server's capabilities in a structured way. Parse Stack exposes an MCP layer so any MCP-compatible client can query Parse data, inspect schemas, count objects, run aggregations, and invoke registered tools without writing application-specific integration code.

Three deployment modes are available:

- **Standalone HTTP server (`MCPServer`)** — a WEBrick process for dedicated MCP deployments.
- **Rack-mountable adapter (`MCPRackApp`)** — embeds inside an existing Sinatra or Rails application.
- **Direct in-process dispatcher (`MCPDispatcher`)** — a pure function for in-process usage, custom transports, and testing.

---

## Deployment Modes

### Standalone HTTP server (MCPServer)

`Parse::Agent::MCPServer` wraps `Parse::Agent::MCPRackApp` in a WEBrick process. It is the fastest path to a working MCP endpoint and is well-suited for dedicated tooling services.

**Prerequisites.** The server requires both an environment variable and a programmatic flag before `enable_mcp!` will proceed:

```ruby
# config/initializers/parse_mcp.rb (or equivalent boot file)
ENV["PARSE_MCP_ENABLED"] = "true"          # must be set in the environment
Parse.mcp_server_enabled = true            # must be set in code
```

**Starting the server:**

```ruby
Parse::Agent.enable_mcp!

Parse::Agent::MCPServer.run(
  port:        3001,
  host:        "127.0.0.1",     # default; do not bind to 0.0.0.0 without a firewall
  permissions: :readonly,        # :readonly, :write, or :admin
  api_key:     ENV["MCP_API_KEY"]
)
```

As of v4.1.0, the constructor refuses non-loopback binds without an API key. Hosts `127.0.0.1`, `::1`, and `localhost` accept `api_key: nil`; any other host requires either an explicit `api_key:` keyword or the `MCP_API_KEY` environment variable, or `ArgumentError` is raised at construction time. Empty-string `api_key:` is treated as unset.

**Inject a shared rate limiter.** For multi-process or multi-host deployments, pass a Redis-backed limiter:

```ruby
shared_limiter = MyRedisRateLimiter.new(limit: 100, window: 60)
Parse::Agent::MCPServer.run(
  port:         3001,
  permissions:  :readonly,
  api_key:      ENV["MCP_API_KEY"],
  rate_limiter: shared_limiter,
)
```

The limiter must respond to `#check!` and raise `Parse::Agent::RateLimitExceeded` on exhaustion. The constructor raises `ArgumentError` if either contract is violated.

`MCPServer.run` is blocking. Trap signals are installed automatically (`INT`, `TERM` -> graceful shutdown).

**Authentication.** When `api_key` is set, every request to `/mcp` must include the `X-MCP-API-Key` header. The comparison uses `ActiveSupport::SecurityUtils.secure_compare` to prevent timing attacks.

**Additional endpoints exposed by the standalone server:**

| Path | Auth required | Purpose |
|------|--------------|---------|
| `/mcp` | Yes (if api_key set) | MCP JSON-RPC endpoint |
| `/health` | No | Monitoring / liveness check: `{"status":"ok","mcp_enabled":true}` |
| `/tools` | Yes (if api_key set) | Human-readable tool list |

Wire your load balancer's health check to `/health`.

---

### Embedded in a Rack app (MCPRackApp)

**`enable_mcp!` is not required for embedded mode.** The `ENV["PARSE_MCP_ENABLED"]` and `Parse.mcp_server_enabled` prerequisites gate only the standalone `MCPServer.run` entry point. `MCPRackApp` and `Parse::Agent.rack_app` work without either.

`Parse::Agent::MCPRackApp` is a Rack endpoint that accepts an **agent factory** — a callable (block or `agent_factory:` keyword, not both) invoked on every request. The factory is responsible for authenticating the request and returning a configured `Parse::Agent`. It must raise `Parse::Agent::Unauthorized` to signal any authentication failure.

The preferred construction is via the `Parse::Agent.rack_app` convenience method, which loads the adapter on demand:

```ruby
Parse::Agent.rack_app { |env| ... }
```

The verbose form `Parse::Agent::MCPRackApp.new { |env| ... }` is equivalent and is the underlying implementation.

**Transport-level checks** run before the factory is called:

- Only `POST` requests are accepted (405 otherwise).
- `Content-Type` must be `application/json` (415 otherwise).
- Body is capped at 1 MB by default (413 otherwise).
- JSON must be valid and not exceed nesting depth 20 (400 otherwise).

After those checks pass, the factory is called. If it raises `Parse::Agent::Unauthorized`, the adapter returns a sanitized 401 with a fixed JSON-RPC error body — no exception detail leaks to the caller. Any other exception from the factory returns a 500 with the same `"Internal error"` wire message.

#### 1. Rails

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mcp_app = Parse::Agent.rack_app(logger: Rails.logger) do |env|
    header = env["HTTP_AUTHORIZATION"].to_s
    token  = header.delete_prefix("Bearer ").strip

    raise Parse::Agent::Unauthorized.new("missing token", reason: :missing) if token.empty?

    # Replace with your real verification (Devise, JWT, Auth0, etc.)
    payload = MyJWTVerifier.verify!(token)  # raises on bad/expired token

    # Map application roles to Parse::Agent permission levels
    perms = payload["admin"] ? :write : :readonly

    # Use a shared Redis-backed limiter (see Rate Limiting section)
    Parse::Agent.new(
      permissions:  perms,
      session_token: payload["parse_session_token"],
      rate_limiter:  $shared_redis_limiter
    )
  rescue MyJWTVerifier::ExpiredToken
    raise Parse::Agent::Unauthorized.new("token expired", reason: :expired)
  rescue MyJWTVerifier::InvalidToken
    raise Parse::Agent::Unauthorized.new("token invalid", reason: :invalid)
  end

  mount mcp_app, at: "/mcp"
end
```

#### 2. Sinatra

Define the Rack app as a constant inside your Sinatra class, then mount it from `config.ru` using `Rack::Builder`'s `map`. Sinatra's class body does not expose the `map` DSL — it belongs to the outer builder context.

```ruby
# app.rb
require "sinatra/base"
require "parse-stack"

class MyApp < Sinatra::Base
  MCP_APP = Parse::Agent.rack_app do |env|
    token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ").strip
    raise Parse::Agent::Unauthorized.new("missing token", reason: :missing) if token.empty?

    begin
      payload = MyJWTVerifier.verify!(token)
    rescue MyJWTVerifier::InvalidToken => e
      raise Parse::Agent::Unauthorized.new(e.message, reason: :invalid)
    end

    Parse::Agent.new(
      permissions:   payload["admin"] ? :write : :readonly,
      session_token: payload["parse_session_token"],
      rate_limiter:  $shared_redis_limiter
    )
  end

  get("/") { "ok" }
end
```

```ruby
# config.ru
require_relative "app"

map("/mcp") { run MyApp::MCP_APP }
run MyApp
```

#### 3. Plain Rack

```ruby
# config.ru
require "parse-stack"

Parse.connect("myapp",
  server_url:  ENV["PARSE_SERVER_URL"],
  app_id:      ENV["PARSE_APP_ID"],
  master_key:  ENV["PARSE_MASTER_KEY"]
)

mcp_app = Parse::Agent.rack_app do |env|
  api_key = env["HTTP_X_MCP_API_KEY"].to_s
  unless ActiveSupport::SecurityUtils.secure_compare(ENV["MCP_API_KEY"], api_key)
    raise Parse::Agent::Unauthorized.new("bad key", reason: :bad_api_key)
  end

  Parse::Agent.new(permissions: :readonly, rate_limiter: $shared_redis_limiter)
end

map("/mcp") { run mcp_app }
map("/")    { run ->(env) { [200, {"Content-Type" => "text/plain"}, ["ok"]] } }
```

#### MCP progress notifications via SSE (opt-in)

**WEBrick cannot stream.** The standalone `MCPServer` is WEBrick-based and buffers the full response before sending. Setting `streaming: true` on an `MCPRackApp` mounted under WEBrick silently degrades to a single buffered response with concatenated SSE events. SSE streaming requires a Rack server that supports streaming response bodies — **Puma, Falcon, or Unicorn**. Verify your deployment uses one of these before relying on `streaming: true`.

`MCPRackApp` supports Server-Sent Events for clients that want `notifications/progress` heartbeats:

```ruby
mcp_app = Parse::Agent.rack_app(streaming: true) do |env|
  # ... auth factory ...
end
```

```ruby
mcp_app = Parse::Agent.rack_app(
  streaming: true,
  heartbeat_interval: 5,  # seconds between progress events (default 2)
) do |env|
  # ...
end
```

Tune `heartbeat_interval` to your client's tolerance; default 2 seconds is appropriate for most LLM clients.

When `streaming: true` is set and the client sends `Accept: text/event-stream`, the server holds the connection open and emits `notifications/progress` heartbeats every 2 seconds. Normal (non-streaming) clients are unaffected because the default is `streaming: false`.

**Client requirements:**
- Send `Accept: text/event-stream` in the request headers.
- Be prepared for an indefinitely open response until the tool call completes.

**Nginx configuration.** Add `X-Accel-Buffering: no` to prevent Nginx from buffering the SSE stream:

```nginx
location /mcp {
  proxy_pass http://backend;
  proxy_set_header X-Accel-Buffering no;
}
```

#### Tool-internal progress reporting (v4.2)

Tools can emit their own `notifications/progress` events through the same SSE stream. Built-in tools and custom tools registered via `Parse::Agent::Tools.register` both receive the agent as their first argument; calling `agent.report_progress(progress:, total: nil, message: nil)` from inside the tool sends a `notifications/progress` event when the request was served by the streaming transport. On the JSON path (or anywhere without an active progress callback) the call is a silent no-op.

```ruby
Parse::Agent::Tools.register(
  name: :process_records,
  description: "Process records with progress reporting",
  parameters: { "type" => "object", "properties" => { "limit" => { "type" => "integer" } } },
  permission: :readonly,
  handler: ->(agent, limit: 100, **) {
    records = fetch_batch(limit)
    records.each_with_index do |rec, i|
      transform(rec)
      agent.report_progress(progress: i + 1, total: records.size, message: "Processing")
    end
    { success: true, data: { processed: records.size } }
  },
)
```

Wire shape of the emitted event:

```json
{
  "jsonrpc": "2.0",
  "method":  "notifications/progress",
  "params": {
    "progressToken": "<client-supplied or auto-generated>",
    "progress": 42,
    "total":    100,
    "message":  "Processing"
  }
}
```

The `progressToken` follows the request: clients that supplied `params._meta.progressToken` see that token echoed in every event; otherwise the server auto-generates one. The `message` field is optional and omitted from the wire when nil. `message` requires MCP protocol 2025-03-26 or later, which `Parse::Agent::MCPDispatcher` advertises by default in v4.2 (`PROTOCOL_VERSION = "2025-06-18"`).

**Heartbeat suppression.** As soon as a tool reports its own progress, the time-based heartbeat loop stops emitting events for the remainder of the request. The shared `progressToken` then carries a single coherent stream of work-unit progress. Tools that never call `report_progress` keep getting elapsed-seconds heartbeats as before.

#### Cancellation (v4.2)

Cooperative cancellation lets clients abort an in-flight long-running tool call. Cancellation is triggered from two paths:

1. **`notifications/cancelled` JSON-RPC notification.** The client sends a second POST while the original request is still streaming. The body is shaped:
   ```json
   {
     "jsonrpc": "2.0",
     "method":  "notifications/cancelled",
     "params":  { "requestId": 42, "reason": "user pressed stop" }
   }
   ```
   The server responds with HTTP `202 Accepted` and an empty body (this is a notification — no JSON-RPC response is required or returned).

2. **SSE client disconnect.** When the underlying TCP connection closes (browser tab closed, network drop), Rack calls `SSEBody#close`, which trips the same cancellation token.

**Identity binding (required for `notifications/cancelled`).** The cancelling request **must** carry the same `Mcp-Session-Id` header as the original request. The header is sanitized into `agent.correlation_id` and used as half of the registry key (the JSON-RPC `requestId` is the other half). Cancellation without a matching `Mcp-Session-Id` is a silent no-op — this prevents an attacker who guesses sequential JSON-RPC ids from cancelling other clients' in-flight requests. Failures (no session id, no matching entry, mismatched session id) all return `202` so the response shape is not a probe oracle.

**Cooperative checkpoints.** Cancellation is observed at safe points inside tool execution, not by forcibly killing the dispatcher thread. The two checkpoints built into `Parse::Agent#execute` are:

- **Before the tool runs** — catches "cancelled while queued behind the rate limiter / permission gate."
- **After the tool returns** — catches "cancelled while the tool's blocking I/O was running."

Tools with internal loops (e.g. `export_data` between chunks) can add their own checks via `agent.cancelled?`. A custom tool that wants to cooperate looks like:

```ruby
handler: ->(agent, **kwargs) {
  return { success: false, error: "Cancelled by client", cancelled: true } if agent.cancelled?
  data = fetch_records(kwargs)
  return { success: false, error: "Cancelled by client", cancelled: true } if agent.cancelled?
  { success: true, data: data }
}
```

**Honest limits.** Cancellation reduces wasted work; it does not stop a tool mid-flight inside a blocking I/O call (MongoDB query, Parse REST roundtrip). The Ruby-level `Timeout.timeout` already wrapping each tool remains the hard upper bound — see the **Tool timeout table** in the Performance section. Real MongoDB cursor cancellation via `killCursors` is a separate deferred item and would require deeper integration with the Mongo Ruby driver.

**Wire shape for cancelled tools.** The dispatcher detects `cancelled: true` (or `agent.cancelled?` returning true after the tool returns) and translates the result into:

```json
{
  "content":   [ { "type": "text", "text": "Cancelled by client (notifications_cancelled)" } ],
  "isError":   true,
  "cancelled": true
}
```

The stream still emits the `response` SSE event before closing so clients do not have to distinguish "cancelled," "crashed," and "network died."

**Scope and limitations.**
- The cancellation registry is per `MCPRackApp` instance. Cancellation does not span multiple mount points within a process, nor multiple processes in a clustered deployment.
- Clients that do not set `Mcp-Session-Id` lose cancellation but keep every other MCP feature.
- The standalone WEBrick-backed `MCPServer` does not support streaming and therefore does not support cancellation; calls return a single buffered response with no opportunity to interrupt.

---

### Direct in-process dispatcher (MCPDispatcher)

`Parse::Agent::MCPDispatcher.call` is a pure function: it takes an already-parsed body Hash and a `Parse::Agent` instance and returns `{ status: Integer, body: Hash }`. It performs no I/O, no HTTP parsing, and no authentication. The `body` value is the JSON-RPC response envelope (a Ruby Hash with string keys) — the caller is responsible for serializing it to JSON and writing it to the wire.

```ruby
require "parse/agent/mcp_dispatcher"

body   = JSON.parse(raw_request_body)   # caller parses
agent  = Parse::Agent.new(permissions: :readonly)

result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent)

# result[:status] => 200 (or 401 for Unauthorized)
# result[:body]   => { "jsonrpc" => "2.0", "id" => ..., "result" => {...} }

response_json = JSON.generate(result[:body])
```

The dispatcher accepts an optional `logger:` keyword for routing internal-error diagnostics:

```ruby
result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent, logger: my_logger)
```

`MCPRackApp` forwards its `logger:` argument to the dispatcher automatically, so transport-level and handler-level diagnostics land in the same operator log.

**`MCPDispatcher` never raises.** All `StandardError` subclasses are caught and translated into JSON-RPC `-32603` error envelopes. The wire-level message in that envelope is the literal string `"Internal error"` — no class name, no message text, no backtrace. The class name and message are emitted to the logger (or `$stderr` via `Kernel#warn` as fallback) and are operator-only. `Parse::Agent::Unauthorized` produces a `-32001` error with HTTP status 401 in the returned hash.

Common uses for the direct dispatcher:

- Unit testing — construct agents with fixture data and call the dispatcher directly without starting a server. See the Testing section.
- Custom transports — WebSockets, stdio, or any other channel that delivers a parsed body.
- Composing inside a larger MCP server that handles its own routing and auth.

---

## Connecting Claude Desktop (stdio bridge)

Parse Stack speaks MCP over **HTTP** (the standalone server and the
Rack adapter both expose a JSON-RPC-over-HTTP endpoint). Claude Desktop,
however, launches MCP servers as local **stdio** subprocesses — it does
not dial an HTTP URL directly. Bridge the two with
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote), a small stdio↔HTTP
proxy that Claude Desktop runs as the subprocess and which forwards to your
HTTP endpoint.

1. Start the Parse Stack MCP endpoint over HTTP (standalone or Rack — see
   Deployment Modes above) and note its URL and the bearer token your
   `agent_factory` expects, e.g. `http://localhost:3001/` with
   `Authorization: Bearer <token>`.

2. Add the bridge to `claude_desktop_config.json` (macOS:
   `~/Library/Application Support/Claude/claude_desktop_config.json`;
   Windows: `%APPDATA%\Claude\claude_desktop_config.json`):

   ```json
   {
     "mcpServers": {
       "parse-stack": {
         "command": "npx",
         "args": [
           "-y",
           "mcp-remote",
           "http://localhost:3001/",
           "--header",
           "Authorization: Bearer ${PARSE_MCP_TOKEN}"
         ],
         "env": {
           "PARSE_MCP_TOKEN": "your-mcp-token"
         }
       }
     }
   }
   ```

3. Restart Claude Desktop. The Parse Stack tools (`query_class`,
   `get_schema`, `semantic_search`, …) appear in the client.

Notes:

- `mcp-remote` requires Node.js on the machine running Claude Desktop.
- For a public endpoint, terminate TLS in front of the HTTP server and use
  an `https://` URL; the bearer token rides the `Authorization` header.
- The same bridge works for any stdio-only MCP client (e.g. some IDE
  integrations). Clients that support remote MCP connectors natively can
  point at the HTTP URL without the bridge.
- Approval workflows (elicitation) need the streaming/listening-stream
  prerequisites described under Approval Workflows — confirm the bridge and
  client forward the SSE channel before relying on human-in-the-loop gating.

---

## Resource Subscriptions (LiveQuery bridge)

MCP lets a client `resources/subscribe` to a resource URI and then receive
unsolicited `notifications/resources/updated` messages whenever the underlying
data changes. Parse Stack bridges that surface onto Parse LiveQuery: a
subscribed `parse://<Class>/count` or `parse://<Class>/samples` resource is
backed by a LiveQuery subscription on `<Class>`, and any matching
create/update/delete/enter/leave event is debounced into a single coarse
update for that URI. The client re-reads the resource via `resources/read` to
obtain the new value — row payloads are never streamed through the resource
surface.

This is opt-in and requires a streaming-capable Rack server (Puma, Falcon —
WEBrick buffers responses and cannot hold the listening stream open) plus
LiveQuery enabled and configured.

```ruby
# Boot: enable LiveQuery and point it at the server.
Parse.setup(
  server_url:     "https://your-parse-server.com/parse",
  application_id: "your_app_id",
  api_key:        "your_api_key",
  live_query_url: "wss://your-parse-server.com",
)
Parse.live_query_enabled = true

# Mount the Rack app with resource subscriptions enabled.
app = Parse::Agent::MCPRackApp.new(resource_subscriptions: true) do |env|
  token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
  MyAuth.agent_for_token!(token) # returns a Parse::Agent or raises Unauthorized
end
```

When enabled and LiveQuery is available, the `initialize` handshake advertises
`resources.subscribe: true`. When LiveQuery is not enabled/available — or on
the WEBrick `MCPServer`, which cannot stream — the capability stays
`subscribe: false` and `resources/subscribe` returns a "not supported" error.
The capability is a contract: it is never advertised unless the server can
actually deliver updates.

### Protocol flow

1. **`initialize`** — the response carries a server-issued `Mcp-Session-Id`
   header. The client echoes it on every subsequent request.
2. **`GET` listening stream** — the client opens a long-lived `GET` to the same
   endpoint with `Accept: text/event-stream` and the `Mcp-Session-Id` header.
   This is the server→client channel; it stays open and emits
   `notifications/resources/updated` events until the client disconnects.
3. **`resources/subscribe`** — a normal `POST` with
   `{ "uri": "parse://Post/count" }`. Returns an empty result; updates begin
   flowing on the listening stream.
4. **`resources/unsubscribe`** — stops one subscription. `DELETE` with the
   session id tears the whole session down.

Only `count` and `samples` resources are subscribable. `schema` is rejected
with an invalid-params error because schema changes are not LiveQuery events.

### Access control (important)

The bridge enforces the same scope rules as the rest of the SDK. LiveQuery
filters events server-side using the credential on the subscribe frame, so the
subscription's credentials are derived from the subscribing agent:

| Agent scope | LiveQuery credential | Events seen |
|-------------|----------------------|-------------|
| session-token agent | that session token | only rows the user can read (ACL/CLP enforced by Parse Server) |
| master-key agent | master key | every event |
| `acl_user:` / `acl_role:` agent | **refused** | none — see below |

`acl_user:` / `acl_role:` agents are an SDK-side, mongo-direct-only construct
with no Parse Server REST or LiveQuery equivalent (Parse Server has no
"act as this user pointer / role" handshake). Bridging them would force a
silent downgrade to either master key (a row-level leak) or an unscoped
session, so the bridge **fails closed** and refuses the subscription with a
security error. Subscribe with a session-token or master-key agent instead.

Because Parse Server fixes ACL-bypass authorization at LiveQuery *connect*
time (there is no per-subscription master key), the bridge keeps two
connections and routes by credential: master-posture subscriptions ride a
dedicated **admin** connection
(`Parse::LiveQuery::Client.new(use_master_key: true)`), while session-token
subscriptions ride a normal connection and pass their token per subscription.
Either way, an update only fires for an object the subscription's scope is
permitted to read — LiveQuery filters events by ACL server-side. (Whether a
master connection additionally surfaces master-key-only rows depends on the
Parse Server version and its `masterKeyIps` configuration.)

### Operational notes and limitations

- **Single-process.** Subscription state lives in the `MCPRackApp` instance
  (like the cancellation registry), so in a clustered / multi-process
  deployment a LiveQuery event observed on one worker does not reach a
  listening stream held on another. The delivery seam
  (`Parse::Agent::MCPSubscriptions::Notifier`) is isolated so a Redis-backed
  pub/sub adapter can be supplied later without changing the bridge or the
  dispatcher; pass it via `subscription_manager:`.
- **Subscriptions do not survive a listening-stream reconnect.** Closing the
  `GET` stream tears down the session's LiveQuery subscriptions; a client that
  reconnects must re-issue its `resources/subscribe` calls.
- **Session id is a bearer capability.** The listening stream authenticates via
  the agent factory and keys delivery off the server-issued `Mcp-Session-Id`,
  which the client must keep secret — possession of a valid session id (plus a
  valid agent) is sufficient to attach. This matches the cancellation model.
- **Per-session cap.** A client that subscribes but never opens (or later
  drops) its listening stream leaves LiveQuery subscriptions running until the
  session is torn down. A per-session ceiling (default 100, configurable on the
  manager) bounds that footprint.

---

## Approval Workflows (MCP elicitation)

`:write` / `:admin` tier tool calls can require human approval before they run,
using the MCP 2025-06-18 spec-native `elicitation/create` channel. Off by
default, so existing clients are unaffected.

```ruby
# Opt tiers in (process-wide). Has teeth only when an approval gate is installed
# (the MCP transport installs one per session; see below).
Parse::Agent.require_approval_for = [:write, :admin]
```

The approval gate is a pluggable `agent.approval_gate` consulted inside
`Parse::Agent#execute` — so it is reachable on the non-MCP path and
unit-testable with a fake approver. `Parse::Agent::MCPElicitationGate` is the
spec-native implementation; `Parse::Agent::NullGate` (the default) approves.

Round-trip over the streaming transport:

1. A `tools/call` for a gated tier pauses before execution. The server builds an
   `elicitation/create` request whose payload carries the **approval preview**
   (for `call_method` the *effective* tier is resolved from the target
   `agent_method`'s declared permission, so write/admin methods invoked through
   the readonly `call_method` tool are gated correctly). The preview is a real
   before/after only for methods that declare `supports_dry_run`; for the
   built-in `update_object` / `delete_object` it is the proposed `{ tool, args }`
   call, **not** a fetched before/after of the target row.
2. The request is pushed to the client over the open **GET listening stream**
   (the same bus as resource subscriptions).
3. The client replies with a JSON-RPC response (`{ result: { action: "accept" |
   "decline" | "cancel" } }`) as a separate POST. The server routes it,
   session-bound, into a pending registry that wakes the blocked tool thread.
4. `accept` → the tool runs. Anything else → a structured refusal; the tool
   never executes.

Client capability + transport requirements (the server READS, does not
advertise, the client's `elicitation` capability at `initialize`):

```ruby
Parse::Agent::MCPRackApp.new(
  streaming: true,
  resource_subscriptions: true,   # or notifications: true — either opens the GET bus
  approval_timeout: 300,          # seconds to wait for a human; default 300
  agent_factory: ->(env) { ... },
)
```

**Three prerequisites — miss any one and every gated write fails closed,
which looks like a bug rather than a config gap:**

1. **`streaming: true`** on the `MCPRackApp` (it defaults to `false`). Approval
   needs a server→client request, which only the streaming transport can send.
2. **An open GET bus** — `notifications: true` *or* `resource_subscriptions:
   true`. `notifications: true` is the lighter choice if you don't need
   LiveQuery resource subscriptions. Without a bus there is no channel to
   deliver `elicitation/create`.
3. **A concurrent server (Puma), not the bundled `MCPServer`.** The bundled
   server runs on WEBrick and is non-streaming, so approval can never round-trip
   there — mount {Parse::Agent.rack_app} under Puma for any deployment that uses
   approval.

Operator aid: a write/admin agent served over MCP with `require_approval_for`
empty emits a one-time `[Parse::Agent:SECURITY]` warning (writes run ungated).
Approval round-trips also emit a `parse.agent.approval` `ActiveSupport::Notifications`
event carrying `outcome`, `reason`, and the measured wait — subscribe to it to
spot a non-answering client holding a dispatcher thread for the full
`approval_timeout` (default 300s).

**Fails closed.** When approval is required but the client did not advertise the
`elicitation` capability, no listening stream is open, the transport is
non-streaming (WEBrick), or the approver times out, the destructive operation is
**refused** — never blocked forever, never silently executed. Replies are bound
to the answering session's `Mcp-Session-Id`, so one session cannot answer (or
guess the id of) another's prompt.

---

## Server-initiated Notifications (general purpose)

The GET listening-stream bus also backs arbitrary server→client notifications,
without requiring LiveQuery resource subscriptions:

```ruby
app = Parse::Agent::MCPRackApp.new(streaming: true, notifications: true,
                                   agent_factory: ->(env) { ... })

# From application code that holds the app reference:
app.notify("the-session-id", method: "notifications/custom", params: { foo: 1 })
```

`notifications: true` builds the listening-stream manager in a `supported:
false` posture: the GET stream and `#notify` work, but `resources.subscribe`
stays unadvertised and `resources/subscribe` POSTs fail closed. `#notify` builds
a JSON-RPC **notification** (never an `id` — that distinguishes it from the
server-initiated *request* used by elicitation) and returns `false` when no
stream is attached for the session. `app.subscription_manager` is exposed for an
out-of-band / clustered publisher that needs the lower-level `publish` seam.

---

## Built-in Agent Hardening & Telemetry

5.2 adds several agent-side controls, all configured on `Parse::Agent`:

- **Impersonation** — `Parse::Agent.new(impersonate_user: <id|Pointer|User>,
  impersonate_mint: false, impersonation_label:)` (or `agent.impersonate(user)`
  / `agent.stop_impersonating!`) resolves a real session token for a `_User`
  (reusing an active `_Session`, or minting a restricted one with
  `impersonate_mint: true`) and binds it as if `session_token:` had been passed.
  Master-key client required; fails closed if no session resolves. An
  `impersonation_label:` (also usable with `acl_role:`) is emitted on the
  `parse.agent.tool_call` payload alongside `impersonated_user_id`.
- **Prompt hardening** (`Parse::Agent::PromptHardening`) — schema descriptions
  surfaced by `get_schema` / `get_all_schemas` are sanitized (non-identifier
  field names dropped with a `[Parse::Agent:PROMPT]` warning, control/zero-width
  chars stripped, capped, marker-wrapped); untrusted tool content has embedded
  wrapper markers neutralized (`Parse::Agent.prompt_marker_strict = true` to
  refuse instead). Operator canary phrases via
  `Parse::Agent.prompt_injection_canaries = ["IGNORE PREVIOUS", /system:/i]`
  emit `parse.agent.prompt_injection_detected`; set
  `Parse::Agent.canary_action = :refuse` to raise on a hit.
  `Parse::Agent::PROMPT_VERSION` is surfaced via
  `agent.describe[:prompt][:version]`. A one-time warning fires when
  `allowed_llm_endpoints` is left unrestricted (nil).
- **Embedding-cost telemetry** — embedding calls made inside a tool span add
  `embed_calls`, `embed_tokens`, and (when
  `Parse::Agent.embed_cost_per_million_tokens` is set) `embed_cost_usd` to the
  `parse.agent.tool_call` payload. The per-tool span does **not** cover
  corpus/ingestion embeds fired at `Model.save` time (typically the dominant
  spend) — wrap those in `Parse::Agent.measure_embeddings { … }`, which returns
  `{ calls:, tokens:, cost_usd: }` for the work done on the calling thread:

  ```ruby
  stats = Parse::Agent.measure_embeddings do
    KnowledgeArticle.save_all(batch)   # embed-on-save
  end
  stats # => { calls: 1200, tokens: 4_300_000, cost_usd: 0.43 }
  ```

  Thread-local: embeds fanned out to other threads/fibers are not captured —
  measure inside each worker. `Parse::Agent.embed_cost_usd(tokens)` converts a
  token count to USD using the configured rate (nil when unset).
- **Provenance** — `Parse::Agent.include_source_provenance = true` (default
  false) stamps each read-tool row with `_source = { class, tool, object_id }`,
  applied after field-allowlist projection and redaction.
- **`semantic_search` tool** — registered readonly + `client_safe`; opt a model
  in with `agent_searchable field:, filter_fields:`. See the
  [Atlas Vector Search Guide](./atlas_vector_search_guide.md#retrieval-rag).

### Runtime denial gates

Beyond the permission-tier and env-gate checks, several gates refuse a tool
call at runtime based on its arguments. They fail closed; a caller sees a
structured error (the built-in tools return `{ success: false, error:,
error_code: }`, which surfaces as `isError: true` over MCP). Knowing them up
front avoids discovering each only on impact:

| Gate | When it fires | Surfaced as |
|------|---------------|-------------|
| Missing tenant scope | A searchable class has no `agent_tenant_scope` while other classes do (tenant-aware deployment) | `Parse::Agent::MissingTenantScope` (search path); a one-time `[Parse::Agent:SECURITY]` lint warning on the general query path |
| No tenant binding | A scoped class is queried by an agent whose tenant value resolves to `nil` | `Parse::Agent::AccessDenied` (`kind: :tenant`) |
| Hidden class | A tool targets an `agent_hidden` class (or one outside a per-instance `classes:` allowlist) | `Parse::Agent::AccessDenied` (`kind: :hidden_class`) / off-allowlist refusal |
| Reserved underscore key | A `filter:` / `vector_filter:` / `where:` contains an underscore-prefixed key (`_rperm`, `_p_*`, …) at any depth | `ArgumentError` / `ValidationError` (recursive refusal) |
| Filter-field allowlist | A `filter:` / `vector_filter:` names a field not in the class's `agent_searchable filter_fields:` | `ValidationError` naming the offending field(s) |
| `text_field` not embedded | `semantic_search` `text_field:` names a field that isn't a declared `embed` source | `ValidationError` listing the allowed sources |
| Tool filtered | A tool/method removed by a per-instance `tools:` / `methods:` filter is invoked | `error_code: :tool_filtered` |
| Approval denied/unavailable | A gated write/admin op is rejected or the approver is unreachable | `error_code: :approval_denied` |

---

## Token Economy

The MCP surface is paid for in LLM context tokens — the tool schemas sent every
session, and the data every tool returns. 5.2 adds controls to keep that cost
down.

### Lean tool profile

A full `:readonly` `tools/list` payload is roughly **7.9K context tokens** every
session. For small-context models or token-sensitive deployments, the `:lean`
profile narrows the surface to the six core read tools (`get_all_schemas`,
`get_schema`, `query_class`, `count_objects`, `get_object`, `aggregate`) —
about **2.6K tokens, a ~67% reduction**:

```ruby
Parse::Agent.new(permissions: :readonly, tools: :lean)
```

A profile is an allowlist: it composes with the permission tier and can only
narrow, never elevate. Profiles are Symbol-only (`Parse::Agent::TOOL_PROFILES`);
for finer control still pass an explicit Array or `{ only:, except: }`. An
unknown profile raises rather than silently exposing the full surface.

### Leaner tool responses

Read tools return rows in an LLM-friendly form (Pointers as `{_type, class,
id}`, Dates as bare ISO strings) and now **strip the raw `ACL` map** — it is
operationally useless to a model (effective authority is enforced server-side
regardless) and is pure token overhead plus a minor role/user-id disclosure.
`get_objects` and the Atlas Search tools now go through the same normalization
`query_class` always used, instead of shipping raw wire-form.

Defaults that bound response size: `query_class` `limit:` defaults to 100 (cap
1000) with the rendered array capped at 50 (`truncated_note`); `aggregate`
auto-injects a terminal `$limit: 200`. Pass a smaller `limit:` / project fewer
fields via `keys:` when you want a tighter result.

### `semantic_search` — deduped sources and a token budget

The `semantic_search` result hoists each chunk's parent record **once** into a
`documents` map keyed by `objectId`, instead of duplicating the full source on
every chunk — map a chunk back to its source via `metadata.object_id`:

```jsonc
{
  "chunks": [
    { "id": "a#0", "score": 0.82, "content": "…", "metadata": { "object_id": "a", "chunk_index": 0 } },
    { "id": "a#1", "score": 0.82, "content": "…", "metadata": { "object_id": "a", "chunk_index": 1 } }
  ],
  "documents": { "a": { "objectId": "a", "title": "…" } },
  "count": 2
}
```

A `max_total_tokens` budget (default 20,000; estimated as chars/4) trims the
lowest-ranked chunks so a few long documents can't silently blow the context
window — the count caps (`k * max_chunks_per_document`) bound the chunk *count*
but not their total size. When the budget trims, the result adds
`budget_truncated: true` and `budget_dropped: <n>` so the truncation is never
silent. Pass `max_total_tokens: 0` to disable.

### Structured error metadata on the wire

A failing `tools/call` already carries `error_code` and a structured `details:`
hash (e.g. `allowed_fields`, `suggested_rewrite`) and `retry_after` — these are
now forwarded on the MCP error envelope under `_meta` (`parse.error_code`,
`parse.retry_after`, `parse.details`) so a client can branch deterministically
and honor `retry_after` instead of re-parsing the prose message. The
human-readable `content` text is unchanged.

`get_schema` on a mistyped class name now raises a `ValidationError` carrying a
"Did you mean: …?" hint (near matches from the locally-known classes), so the
model self-corrects in one retry instead of falling back to a full
`get_all_schemas` sweep.

---

## Custom Authentication

The agent factory pattern gives you full control over authentication. Every request passes through the factory before any Parse operation is attempted.

**Complete example:**

```ruby
agent_factory = lambda do |env|
  # 1. Extract the bearer token from the Authorization header.
  raw = env["HTTP_AUTHORIZATION"].to_s
  token = raw.delete_prefix("Bearer ").strip

  if token.empty?
    raise Parse::Agent::Unauthorized.new("Authorization header missing", reason: :missing)
  end

  # 2. Verify the token (JWT, Auth0, Devise session, or static comparison).
  #    For static API keys, always use secure_compare:
  #
  #    unless ActiveSupport::SecurityUtils.secure_compare(ENV["STATIC_KEY"], token)
  #      raise Parse::Agent::Unauthorized.new("bad key", reason: :bad_api_key)
  #    end
  #
  #    For JWT:
  payload = MyJWTVerifier.verify!(token)  # raises on invalid/expired

  # 3. Map the verified identity to permissions.
  perms = case payload["role"]
    when "admin" then :write        # see WARNING below
    else              :readonly
  end

  # 4. Return a configured agent. The factory chooses ONE identity input
  #    (mutually exclusive — passing two raises ArgumentError):
  #
  #      session_token: <string>  — bearer-token identity; SDK validates via
  #                                 /users/me at construction (best-effort)
  #      acl_user:      <Parse::User|Pointer> — pre-resolved identity, skips
  #                                 the token round-trip; v4.4.0+
  #      acl_role:      <name>    — service-account scoping ("see as if a
  #                                 user holding this role were asking"); v4.4.0+
  #
  #    Omitting all three runs in master-key posture (banner-warned at
  #    construction; the right choice for ops/admin agents).
  Parse::Agent.new(
    permissions:   perms,
    session_token: payload["parse_session_token"],  # optional; scopes queries to user ACLs
    rate_limiter:  $shared_redis_limiter             # required for per-request deployments
  )

rescue MyJWTVerifier::ExpiredToken
  raise Parse::Agent::Unauthorized.new("token expired", reason: :expired)
rescue MyJWTVerifier::InvalidToken
  raise Parse::Agent::Unauthorized.new("token invalid", reason: :invalid)
end
```

**`Parse::Agent::Unauthorized` contract:**

```ruby
raise Parse::Agent::Unauthorized.new("human-readable message", reason: :symbol)
```

The `reason:` keyword is available as `e.reason` on the exception object. Any middleware that rescues `Unauthorized` upstream of `MCPRackApp` can read it. `MCPRackApp` itself logs only the exception class name (not `e.reason`) when a `logger:` is provided. The `reason` is never included in any HTTP response body.

The response the client always receives for an authentication failure is the fixed sanitized envelope:

```json
{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Unauthorized"}}
```

Only `Parse::Agent::Unauthorized` should escape the factory. Any other exception becomes a 500 response with `"Internal error"` as the wire message. Rescue and re-raise all anticipated failures as `Unauthorized` or allow unexpected errors to propagate as-is.

**WARNING: `:admin` permissions over HTTP.** The `:admin` permission level enables destructive tools (`delete_object`, `create_class`, `delete_class`). Do not grant `:admin` in an HTTP-exposed agent factory unless you have explicitly considered what happens when that endpoint is called with a stolen credential, a misconfigured reverse proxy, or a logic error in your authorization check. Prefer `:write` for mutation access and reserve `:admin` for internal tooling behind a network boundary.

---

## Rate Limiting in Per-Request Deployments

### The problem

The bundled `Parse::Agent::RateLimiter` is an in-process sliding-window counter stored on the `Parse::Agent` instance. It works correctly in deployments that reuse a single agent across requests:

```
Standalone MCPServer
  creates ONE Parse::Agent at startup
  rate_limiter state persists across all requests  (correct)
```

When `MCPRackApp` calls an agent factory on every request, a new `Parse::Agent` is created each time. Because `RateLimiter` state lives on the instance, it resets on every call:

```
MCPRackApp (per-request factory)
  request 1 -> new Parse::Agent -> new RateLimiter (0 requests recorded)
  request 2 -> new Parse::Agent -> new RateLimiter (0 requests recorded)
  effectively no rate limiting
```

The same problem exists in miniature whenever a tool handler constructs a sub-agent inside its block — a fresh `Parse::Agent.new` produces a fresh limiter, so an attacker who can induce delegation amplifies the per-process budget linearly with delegation depth × branching. The v4.2 `parent:` kwarg closes that case automatically (see [Per-Agent Tool Filtering & Sub-Agent Delegation](#per-agent-tool-filtering--sub-agent-delegation-v42)); the shared external limiter pattern below covers the cross-request case at the MCPRackApp boundary.

### The solution

Inject a shared, externally-stateful limiter:

```ruby
$shared_redis_limiter = MyRedisRateLimiter.new(
  key:    "mcp_rate_limit",
  limit:  60,
  window: 60
)

mcp_app = Parse::Agent.rack_app do |env|
  # ... auth ...
  Parse::Agent.new(
    permissions:  :readonly,
    rate_limiter: $shared_redis_limiter
  )
end
```

### Injected limiter protocol

An injected limiter must satisfy this interface:

```ruby
# The limiter must respond to #check! and raise
# Parse::Agent::RateLimitExceeded when the budget is exhausted.
# Parse::Agent::RateLimitExceeded is a top-level alias for
# Parse::Agent::RateLimiter::RateLimitExceeded.

class MyRedisRateLimiter
  def initialize(key:, limit:, window:)
    @key    = key
    @limit  = limit
    @window = window
  end

  def check!
    remaining = redis_sliding_window_increment(@key, @limit, @window)
    if remaining < 0
      raise Parse::Agent::RateLimitExceeded.new(
        retry_after: @window,
        limit:       @limit,
        window:      @window
      )
    end
    true
  end

  private

  def redis_sliding_window_increment(key, limit, window)
    # Your Redis INCR / EXPIRE or sorted-set sliding window implementation.
    # Return the number of remaining slots (negative means over limit).
  end
end
```

`Parse::Agent#initialize` validates the injected limiter at construction time:

```ruby
# Raises ArgumentError immediately if the limiter does not respond to #check!
Parse::Agent.new(rate_limiter: bad_object)
# => ArgumentError: rate_limiter must respond to #check!
```

**Fail-closed behavior.** If the injected limiter raises an error that is not `Parse::Agent::RateLimitExceeded` (for example, a `Redis::ConnectionError` when the backing store is unavailable), `Agent#execute` translates it into a synthetic `RateLimitExceeded` with a randomized `retry_after` between 1.0 and 5.0 seconds. This prevents the Redis-down condition from being distinguishable from a real rate limit signal. The original error is emitted to `$stderr` via `Kernel#warn` with the format `"[Parse::Agent] rate limiter failure: <Class>: <message>"` — it is operator-only and never reaches the client.

The `Parse::Agent::RateLimitExceeded` constant is a stable top-level alias — external limiters should raise it directly rather than the nested `Parse::Agent::RateLimiter::RateLimitExceeded`.

Per-user rate limiting follows the same pattern: key the Redis counter on the verified user identity extracted during authentication.

---

## Custom Tools

Prior to v4.1.0, adding application-specific tools required wrapping the dispatcher or monkey-patching the `Tools` module. v4.1.0 closes this gap with `Parse::Agent::Tools.register`.

### Registering custom tools

Register before the `MCPRackApp` or `MCPServer` starts handling requests. Registration is thread-safe (guarded by a mutex internally), but the registry is global to the process. Registering the same name again replaces the previous registration.

```ruby
Parse::Agent::Tools.register(
  name:        :breakdown_posts,
  description: "Count posts grouped by user/project/workspace/tenant with optional date window",
  parameters:  {
    type: "object",
    properties: {
      group_by: {
        type: "string",
        enum: ["user", "project", "workspace", "tenant"],
        description: "Dimension to group by"
      },
      since: {
        type: "string",
        description: "ISO8601 lower bound (inclusive)"
      }
    },
    required: ["group_by"]
  },
  permission: :readonly,
  category:   "analytics",   # optional; defaults to "custom"
  timeout:    30,
  handler:    ->(agent, **args) { MyApp::BreakdownService.call(**args) }
)
```

The optional `category:` kwarg (v4.2.1) assigns the tool to a discovery category surfaced via `_meta.category` on every MCP tool descriptor and consumable by the `list_tools` discovery built-in. See [Tool Categories & `list_tools`](#tool-categories--list_tools) below for details. Defaults to `"custom"`; refuses empty strings.

**How registered tools integrate with the runtime:**
- They appear in `tools/list` responses alongside built-in tools, filtered by the current agent's permission level (a tool registered with `permission: :write` will not appear for a `:readonly` agent).
- Tool calls route through `Agent#execute`, which means they go through permission checking, rate limiting, and `ActiveSupport::Notifications` instrumentation exactly like built-in tools.
- The handler lambda receives the agent instance as its first argument and keyword arguments matching the parameters schema.
- The registry is global to the process. To make a registered tool visible only to some sessions (e.g., a dashboard-only `emit_artifact` tool), use the v4.2 per-agent `tools:` filter in the agent factory rather than registering the tool conditionally. See [Per-Agent Tool Filtering & Sub-Agent Delegation](#per-agent-tool-filtering--sub-agent-delegation-v42).

**Handler return contract.** Your handler must return one of:
- `{success: true, data: <Hash or Array>}` on success — the dispatcher wraps `data` in the MCP `content` envelope.
- `{success: false, error: <String>, error_code: <Symbol>}` on failure — surfaces as `isError: true` in the tool result with your message.

Any other shape is treated as an internal error. Arguments arrive as keyword arguments with **symbol keys** (`args[:since]`, not `args["since"]`), matching Ruby's `**kwargs` convention, regardless of the JSON Schema using string keys.

**Registered handlers are trusted code.** Specifically, handlers:
- Receive the bare `Parse::Agent` and can read its `session_token`, `acl_scope`, `acl_scope_kwargs`, `acl_permission_strings`, `acl_read_match_stage`, and `acl_write_match_stage` to apply the agent's identity to their own queries.
- **Bypass the COLLSCAN preflight check** when they query Parse directly (via `.results_direct`, `Parse::MongoDB`, or `Parse::Object#query`). Implement your own indexing discipline.
- **Bypass the `agent_fields` allowlist** when they return raw `Parse::Object` instances. Project fields manually in the handler.
- Bypass `max_time_ms` pushdown — Parse Server's REST surface does not accept `maxTimeMS`, so built-in tools enforce timeouts only via Ruby's `Timeout.timeout` (with the known limitation that it cannot safely interrupt native I/O mid-syscall). If you need a database-level time budget in your handler, query through `Parse::MongoDB.find` / `Parse::MongoDB.aggregate` directly with the `max_time_ms:` keyword; cancellation surfaces as `Parse::MongoDB::ExecutionTimeout`.
- Are responsible for forwarding the agent's ACL scope. Handlers that hit REST under an `acl_user:` / `acl_role:` agent (via `agent.client.find_objects(..., **agent.request_opts)`) will raise `Parse::ACLScope::ACLRequired` — fail-closed, since REST can't honor non-session scope. The remedy is to call `Parse::MongoDB.aggregate(class, pipeline, **agent.acl_scope_kwargs)` or `Parse::Query.new(class).results_direct(**agent.acl_scope_kwargs)` from inside the handler; both apply the SDK's `_rperm` `$match` + `Parse::CLPScope` enforcement automatically.

**Optional v4.2 helpers available to registered handlers** — see the Streaming, Cancellation, and Structured Tool Output sections under [Embedded in a Rack app](#embedded-in-a-rack-app-mcprackapp) for the full wire shape and constraints:
- `agent.report_progress(progress:, total: nil, message: nil)` — emit MCP `notifications/progress` events. Silent no-op on the JSON path.
- `agent.cancelled?` — poll the cooperative cancellation flag. Return `{success: false, error: "Cancelled by client", cancelled: true}` from the handler to short-circuit cleanly; the dispatcher's post-run checkpoint also catches uncooperative handlers and translates the response automatically.
- `Tools.register(..., output_schema:)` — declare a JSON Schema Hash for the tool's structured output. The schema surfaces in `tools/list` as `outputSchema`, and `tools/call` responses for that tool include a `structuredContent` field mirroring the handler's data Hash alongside the existing `content` text array.

Register at boot from code you control. Never accept registrations from configuration files at runtime.

Registering a name that matches a built-in tool replaces the built-in in `tools/list` and `tools/call` responses. To restore built-in-only state (useful in test teardown, parallel to `Parse::Agent::Prompts.reset_registry!`), call `Parse::Agent::Tools.reset_registry!`.

**v4.1.0 and later:** use `Parse::Agent::Tools.register` as shown above.

**Pre-4.1.0 workaround:** wrap the dispatcher:

```ruby
# Pre-4.1.0 only — dispatcher-wrap pattern
original_call = Parse::Agent::MCPDispatcher.method(:call)

module CustomDispatch
  def self.call(body:, agent:, logger: nil)
    if body.dig("method") == "tools/call" &&
       body.dig("params", "name") == "breakdown_posts"
      # handle it here, return { status: 200, body: jsonrpc_result }
    else
      original_call.call(body: body, agent: agent, logger: logger)
    end
  end
end
```

---

## Tool Categories & `list_tools`

Built-in and registered tools carry a `category:` field that lets clients filter the tool surface by purpose without parsing prose descriptions. Categories also feed the `list_tools` discovery built-in (added in v4.2.1), which returns a lightweight catalog of names + categories + one-line descriptions — significantly cheaper than `tools/list`'s full input-schema dump.

### Built-in categories

| Category   | Built-in tools                                                                                          | Purpose                                                                |
|------------|---------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------|
| `schema`   | `get_all_schemas`, `get_schema`                                                                         | Class introspection                                                    |
| `query`    | `query_class`, `count_objects`, `get_object`, `get_objects`, `get_sample_objects`, `explain_query`      | Read-only data access                                                  |
| `aggregate`| `aggregate`, `group_by`, `group_by_date`, `distinct`                                                     | MongoDB aggregation pipelines and high-level group/distinct helpers    |
| `mutation` | `call_method`                                                                                            | Domain-action methods declared via `agent_method`                      |
| `export`   | `export_data`                                                                                            | Bulk data export in CSV/Markdown/text                                  |
| `discovery`| `list_tools`                                                                                             | The catalog tool itself                                                |

`Parse::Agent::Tools::BUILTIN_CATEGORIES` is a frozen hash mapping each category to its human-readable one-liner. Application-registered tools default to `"custom"` unless they pass `category:` to `Tools.register`.

### `_meta.category` on every MCP descriptor

Every tool descriptor emitted by `tools/list` carries a `_meta` block:

```jsonc
{
  "name":        "query_class",
  "description": "Fetch records from a Parse class ...",
  "inputSchema": {...},
  "_meta":       { "category": "query" }
}
```

The MCP 2025-06-18 spec permits `_meta` on tool descriptors for server-specific extensions. Older clients ignore unknown fields.

### Server-side category filter on `tools/list`

`tools/list` accepts an optional non-standard `category` param. Vanilla MCP clients omit it and see the full allowed-tools list (backward-compatible). Clients that know about the extension can pass a category to filter the response server-side:

```jsonc
// Request — load only the aggregation surface
{ "jsonrpc": "2.0", "id": 1, "method": "tools/list",
  "params": { "category": "aggregate" } }

// Response — only built-ins (and registrations) in that category
{ "tools": [
    { "name": "aggregate", "description": "...", "inputSchema": {...},
      "_meta": { "category": "aggregate" } }
  ] }
```

Category comparison is case-insensitive. Unknown categories return an empty `tools` array (not an error). The filter never widens permission: a `:readonly` agent requesting `category: "mutation"` still excludes any `:write` registered method tool.

### The `list_tools` built-in

For LLMs that want to decide which tool to load BEFORE paying the cost of full input schemas, call `list_tools` instead of `tools/list`:

```ruby
agent.execute(:list_tools)
# => {
#   success: true,
#   data: {
#     tools: [
#       { name: "get_all_schemas", category: "schema",    description: "List every Parse class ..." },
#       { name: "get_schema",      category: "schema",    description: "Return the fields, types ..." },
#       { name: "query_class",     category: "query",     description: "Fetch records from a Parse class ..." },
#       # ...
#     ],
#     categories: {
#       "schema"    => "Class introspection ...",
#       "query"     => "Read-only data access ...",
#       "aggregate" => "MongoDB aggregation pipelines ...",
#       "mutation"  => "Domain-action methods declared via agent_method.",
#       "export"    => "Bulk data export in CSV, Markdown, or fixed-width text.",
#       "custom"    => "Application-registered tools not assigned to a built-in category.",
#       "discovery" => "..."
#     }
#   }
# }
```

Pass `category:` to narrow further:

```ruby
agent.execute(:list_tools, category: "schema")
# => { success: true, data: { tools: [
#   { name: "get_all_schemas", ... },
#   { name: "get_schema",      ... }
# ], categories: {...} } }
```

`list_tools` honors the agent's `allowed_tools` so it never reveals tools the caller's permission tier or `tools:` filter excludes. Permission tier: `:readonly`.

### Resolving a tool's category programmatically

```ruby
Parse::Agent::Tools.category_for(:aggregate)   # => "aggregate"
Parse::Agent::Tools.category_for(:unknown_xyz) # => nil
```

---

## Per-Agent Tool Filtering & Sub-Agent Delegation (v4.2)

The agent constructor accepts four kwargs that let a single MCP mount serve multiple **agent flavors** — different tool sets per session — and let tool handlers construct **sub-agents** that inherit shared state without resetting rate-limit budgets, severing audit correlation, or silently elevating auth scope.

The four kwargs compose; each can be used independently. None of them changes the existing permission-tier or env-gate behavior: the filter narrows on top of the tier-permitted set, never elevates.

### `tools:` — per-instance tool name filter

Overlay the permission-tier output of `allowed_tools` with an allowlist, a denylist, or both.

```ruby
# Allowlist (Array shorthand)
agent = Parse::Agent.new(tools: [:query_class, :get_schema])

# Allowlist + denylist (Hash form)
agent = Parse::Agent.new(tools: { only: [:query_class, :get_schema, :aggregate],
                                  except: [:aggregate] })

# Denylist only
agent = Parse::Agent.new(tools: { except: [:emit_artifact] })

# Named profile (Symbol) — :lean narrows to the six core read tools
# (~67% smaller tools/list). See "Token Economy" above.
agent = Parse::Agent.new(tools: :lean)
```

**Resolution order** is strict: env-gates ▷ permission tier ▷ per-instance filter. The filter cannot elevate — `tools: { only: [:delete_object] }` on a `:readonly` agent still excludes `delete_object` because `delete_object` is not in the readonly tier's permitted set in the first place.

**Names are normalized to Symbols.** The Array form (`tools: [...]`) is shorthand for `{only: array}`. The Hash form rejects keys other than `:only` / `:except` with `ArgumentError`; bad value types (e.g. `only: "string"`) raise the same.

**Unknown names are lazy-resolved.** A name not currently in the global registry emits a `warn` typo guard but is still threaded through the filter — so a tool registered after agent construction still resolves correctly. To raise at construction instead of warn, set `Parse::Agent.strict_tool_filter = true` (global) or pass `strict_tool_filter: true` to the constructor.

### `methods:` — per-`agent_method` filter through `call_method`

Closes the `call_method` aperture: without this kwarg, `tools: { only: [:call_method] }` exposes every declared `agent_method` across every class. The `methods:` filter is applied inside `call_method` dispatch, after the per-class `agent_method_allowed?` and tier checks have already passed.

```ruby
# Allow archive on any class, plus set_client_description only on Project
agent = Parse::Agent.new(methods: [:archive, "Project.set_client_description"])

# Deny one specific qualified method
agent = Parse::Agent.new(methods: { except: ["Account.delete_account"] })
```

Entries are bare method names (`:archive` — matches the method on any class) or qualified names (`"Project.archive"` — matches only on that class). Both forms coexist in the same Set; matching is an OR.

The filter **narrows declared methods** — it cannot expose a method that was not declared via the `agent_method` DSL, and it cannot bypass tier checks (`agent_can_call?`) or env-gates (`PARSE_AGENT_ALLOW_WRITE_TOOLS`, `PARSE_AGENT_ALLOW_SCHEMA_OPS`). A filtered-out invocation returns `error_code: :tool_filtered`.

Unlike `tools:`, `methods:` does no typo validation. The universe of declared `agent_method`s depends on which `Parse::Object` subclasses have been loaded at construction time, so validation would produce false positives.

**Authoring `agent_method` bodies with ACL scope (v4.4.0).** `call_method` injects the active agent into the method body when the method's signature declares an `agent:` keyword (or `**kwargs`). The method body can then forward `agent.acl_scope_kwargs` to internal queries it runs, or read `agent.acl_permission_strings` / `agent.acl_read_match_stage` / `agent.acl_write_match_stage` to build its own ACL filters:

```ruby
class Project < Parse::Object
  agent_method :archive, permission: :write, supports_dry_run: true,
               permitted_keys: [:reason]
  def archive(reason:, agent: nil, dry_run: false, **)
    return { would: "archive #{id}", reason: reason } if dry_run
    # Forward the agent's scope to any internal query — pre-filtering by
    # _wperm so the update only sees rows the agent's scope is allowed
    # to modify, defense-in-depth alongside Parse Server's own ACL.
    Audit.all(**agent.acl_scope_kwargs).each { |a| a.cancel! } if agent&.acl_scope
    update!(archived_at: Time.now, archive_reason: reason)
    { archived: true, objectId: id }
  end
end
```

Two things to know:
- The `agent:` kwarg is OPTIONAL. Methods without it in their signature don't receive it — backwards compatible with existing `agent_method` declarations.
- `call_method` does NOT auto-thread the scope into the method body. Honest authors will forget — make scope-aware `agent_method`s an explicit pattern in your codebase. `call_method` runs a CLP boundary check before dispatch (`:readonly` → CLP `:find`, `:write` → `:update`, `:admin` → `:delete`), so a class whose CLP doesn't grant the mapped op to the agent's scope is refused at the gate.

### `classes:` — per-instance class allowlist (v4.3.0)

Narrows a single agent instance to a subset of Parse classes. Compose with `tools:` and `methods:` to construct purpose-narrowed agents — a support bot that can read `Ticket` / `Customer` / `Conversation` and nothing else; an ops console scoped to `Installation` and `User`; a read-only audit agent that excludes `Session` and an `AuditLog` class.

```ruby
# Allowlist (Array shorthand) — Ticket + Customer + Conversation only
support = Parse::Agent.new(classes: [Ticket, Customer, Conversation])

# Allowlist + denylist (Hash form)
ops = Parse::Agent.new(classes: { only: [Parse::Installation, Parse::User] })

# Denylist only — read everything EXCEPT Session and AuditLog
audit = Parse::Agent.new(classes: { except: [Parse::Session, AuditLog] })
```

**Resolution order is strict:** identifier-format check ▷ global `agent_hidden` registry ▷ `agent_hidden(except: :master_key)` master-key bypass ▷ per-instance `classes:` filter. The per-instance filter is the **ceiling, not the floor** — it cannot re-enable a globally hidden class, and it cannot widen what `permissions:` or `agent_fields` would have allowed. It strictly narrows.

**Entries may be Ruby class constants, parse_class Strings, or Symbols.** Class constants expand through `MetadataRegistry.hidden_name_variants_for` so `Parse::User` matches `"_User"`, `"User"`, and any application-side alias declared via `parse_class`. `classes: { only: [Parse::User] }` and `classes: { only: ["_User"] }` produce the same effective gate.

**Six enforcement sites, not just the top-level gate.** The same filter applies at:

- `assert_class_accessible!` (top-level tool dispatch)
- `walk_pointer_path!` (refuses `include: ["author.session"]` when `Session` is off-allowlist)
- `walk_pipeline_stage!` (refuses `$lookup.from` / `$unionWith.coll` / `$graphLookup.from` to off-allowlist classes, recursively into `$facet` and `$lookup.pipeline` sub-stages)
- `ConstraintTranslator.translate` (refuses `$inQuery` / `$notInQuery` / `$select` / `$dontSelect` against off-allowlist classes, recursively into nested `where:`)
- `walk_and_redact` (post-fetch scrub — server-side `$lookup` output that surfaces an off-allowlist `className` is replaced with `{ __redacted: true }`)
- `redact_hidden_pointer_groups!` (`group_by` collapses off-allowlist group keys)

**Strict mode.** Unknown class names in `only:` warn at construction by default — the class universe is open via lazy autoload, so a name not currently loadable may resolve later. To raise at construction instead of warn:

```ruby
Parse::Agent.strict_class_filter = true               # process-wide default
# or
Parse::Agent.new(classes: { only: [Pots] }, strict_class_filter: true)  # per-instance
```

`except:` is never validated — an operator may proactively block a class not yet loaded.

**Sub-agent inheritance: intersect, never widen.** Unlike `tools:` (where a sub-agent's filter overrides the parent's outright), `classes:` is **intersected** with the parent's effective set so a sub-agent can NEVER widen the parent's data reach. A child `only:` that has no overlap with the parent's `only:` raises `ArgumentError` at construction. A child that omits `classes:` inherits the parent's filter verbatim. `except:` sets are unioned (a sub-agent cannot un-deny a class the parent denied). The asymmetry with `tools:` is intentional — class reach is data scope, closer to `permissions:` than to the UX-scoping `tools:` filter.

**Schema-catalog filtering.** `get_all_schemas` omits classes outside the per-agent allowlist from the catalog response so the LLM doesn't waste a tool call discovering classes it would be refused on.

**Denial code.** A refusal triggered by the per-instance filter raises `Parse::Agent::AccessDenied` with `kind: :class_filter`, distinct from the global `agent_hidden` denial which uses `kind: :hidden_class`. Lets SOC tooling distinguish operator-narrowing from policy-level denials without parsing the message prose.

### `filters:` — per-instance per-class query filter (v4.4.0)

Accepts a Hash mapping Parse class to a constraint Hash that AND-merges into every query the agent runs against that class. Fills the gap left by the three existing primitives: class-global `agent_canonical_filter` (same constraint for every agent), agent-wide `tenant_id:` (single-field), and the per-agent `classes:` allowlist (binary visibility, not constraint). Use this when an agent needs to never see specific rows that the class permits in general — soft-delete partitioning that varies by agent role, compliance flags that differ per consumer, per-agent draft/published scoping.

```ruby
support_agent = Parse::Agent.new(
  classes: { only: [Ticket, Customer, Conversation] },
  filters: {
    Ticket   => { archived: false, spam: false },
    Customer => { test_user: false },
    :default => { tenant_active: true },      # AND'd into every class's query
  },
)
```

**Composition order — all AND-merged:**

1. Caller's `where:` argument (passed to a tool call)
2. Class-level `agent_canonical_filter` (model-level DSL, applies to every agent)
3. Per-agent per-class `filters:[Class]` (this kwarg)
4. Per-agent `filters:[:default]` (cross-cutting agent-level entry)
5. Tenant scope (when bound)

When all five compose, the final wire `where:` is a top-level `$and` array containing each non-empty layer; subscribers can recover which layer contributed which clause by reading them positionally.

**`:default` semantics.** When a class has both an explicit entry AND `:default`, the two merge with class-specific keys winning on field conflicts (more specific declaration takes precedence). A `filters: { Account => { test_user: false }, :default => { tenant_active: true } }` produces `{ test_user: false, tenant_active: true }` for `Account` queries. `:default` is meant for cross-cutting agent-level invariants — soft-delete exclusion, tenant-active flag, region pinning — that apply uniformly.

**Class identifier acceptance.** Hash keys may be Ruby class constants (`Parse::User`), parse_class Strings (`"_User"`), or Symbols. Class constants expand through `MetadataRegistry.hidden_name_variants_for` so `filter_for(Parse::User)` and `filter_for("_User")` return the same Hash. `:default` is reserved for the cross-cutting entry.

**Construction-time validation.** Every constraint Hash is run through `Parse::Agent::ConstraintTranslator.valid?` at `Parse::Agent.new` time, so a typo'd operator (`{ "$gtt" => 5 }`) or unknown operator raises `ArgumentError` at boot — not at the first tool call. Catches the common operator-misspelling failure mode at the developer's editor.

**`get_object(id)` is filtered too.** When a per-agent filter is declared for a class, `get_object(class_name:, object_id:)` rewrites internally to a `find_objects` with `where: { objectId: id, ...filter }, limit: 1`. Without this, an agent with `filters: { Account => { test_user: false } }` could still pull a specific test-user row by passing the ID directly — defeating the operator's narrowing intent. When the filter excludes the row, the call returns the standard `Object not found: <Class>#<id>` envelope, identical to a genuine missing-row case so the agent can't use deliberate-fetch attempts as an oracle for filtered-out IDs.

Note that the class-level `agent_canonical_filter` is intentionally NOT applied on `get_object(id)` — its semantic is "this class is normally queried in valid state Y," not "this agent must never see X." A caller who already has the ID gets the record as-is even when it falls outside the class's "valid state." The per-agent filter is treated differently because its semantic IS authorization.

**Pipeline emission.** When the aggregate pipeline path applies the filter, the class-canonical and per-agent filters emit as SEPARATE `$match` stages so `explain_query` output and audit trails can distinguish which restriction came from which layer.

**Inspecting the resolved filter.** `agent.filter_for(class_name)` returns the AND-composed constraint Hash for a class (per-class entry AND `:default`), or `nil` when nothing applies. Useful when application code needs to reason about what the agent would have applied — debugging "why is this query returning zero rows," surfacing the effective scope in a developer console, or constructing a manual query that mirrors the agent's reach.

**Sub-agent inheritance.** Parent's filters are inherited and the child's filters merge ON TOP with the child's keys winning on field conflicts. New class keys in the child are added; new keys in the parent are inherited verbatim. Like the `classes:` allowlist, inheritance is narrow-only: a sub-agent cannot relax a parent's filter, only tighten it.

**Phase 1: static Hashes only.** The constraint values are Hash literals frozen at construction. Runtime-computed filters (Procs that re-evaluate per call) are tracked as a Phase 2 follow-up — most "dynamic" cases are already covered by `tenant_id:` or by constructing a fresh agent per request with the right filter baked in.

### `parent:` — sub-agent inheritance

When a tool handler constructs a sub-agent inside its block, pass `parent:` so the sub inherits the shared state and auth scope of the parent:

```ruby
Parse::Agent::Tools.register(
  name: :delegate_to_billing,
  description: "Hand a billing question to a specialist sub-agent",
  parameters: { type: "object", properties: { question: { type: "string" } }, required: ["question"] },
  permission: :readonly,
  handler: ->(agent, question:, **_) do
    sub = Parse::Agent.new(
      permissions: agent.permissions,
      parent: agent,                       # inherits limiter, correlation, depth, auth scope
      tools: { only: BILLING_TOOL_SET },   # narrows the sub's surface to the billing toolset
    )
    sub.ask(question)
  end,
)
```

**What is inherited:**

| State | Inherited unless explicit override | Why |
|-------|-----------------------------------|-----|
| `rate_limiter` | Yes | Without sharing, the sub gets a fresh budget and an attacker who can induce delegation amplifies the per-process limit linearly with delegation depth × branching. |
| `correlation_id` | Yes | Without it, the sub's tool calls fire `parse.agent.tool_call` notifications with no `:correlation_id`, severing the audit thread for the LLM turn. |
| `session_token` | Yes (security-critical) | Without it, a session-token parent silently produces a master-key sub-agent — the constructor default is `nil`, which means master-key mode. This was the v4.2 advisor-flagged blocker; do not undo. |
| `acl_user` (v4.4.0) | Yes (security-critical) | When the parent was constructed with `acl_user:` and the child supplies none of `session_token:` / `acl_user:` / `acl_role:`, the parent's identity inherits verbatim. Inheritance is conditional on the child supplying NO identity at all — explicit overrides on the child resolve normally and then face the subset check below. |
| `acl_role` (v4.4.0) | Yes (security-critical) | Same rule as `acl_user`. A child that omits identity inherits the parent's role scope; one that supplies its own identity falls through to the subset check. |
| `tenant_id` | Yes (security-critical) | Without it, a tenant-bound parent produces an unbound sub-agent that escapes `agent_tenant_scope` rules. |
| `recursion_depth` | Always (decremented) | The parent's budget is authoritative — the explicit `recursion_depth:` kwarg is ignored on inherited construction. |

**What is NOT inherited (but is clamped):**

| State | Why not |
|-------|---------|
| `permissions` | The default of `:readonly` means `Parse::Agent.new(parent: write_agent)` produces a `:readonly` sub-agent. A sub-agent is at most as privileged as the parent by tier; this is enforced by a clamp check at construction, not by inheritance. An explicit override is accepted only if `≤ parent.permissions` — `Parse::Agent.new(parent: readonly_parent, permissions: :admin)` raises `ArgumentError`. Pass `permissions: parent.permissions` to maintain parity intentionally. |
| `client` | The constructor default `:default` resolves to the same client in standard single-app deployments. Explicit passes through. |
| `tools:` / `methods:` filters | The whole point of constructing a sub-agent is usually to give it a NARROWER surface. Explicit passes through. |

**The clamp invariant:** `sub.permissions ≤ parent.permissions` always holds. The default `:readonly` is always safe regardless of parent tier; only explicit overrides hit the clamp check, and overrides that exceed the parent's tier raise at construction. This is the structural guarantee that a `delegate_to_subagent` chain cannot escape the parent's tier through sub-agent construction — the only path to a more-privileged agent is at the MCP factory, where the explicit elevation is auditable.

**ACL-scope subset invariant (v4.4.0):** when the parent carries a resolved ACL scope (session_token / acl_user / acl_role), an explicit child override must resolve to a `permission_strings` set that is a SUBSET of the parent's. A tool handler that tries `Parse::Agent.new(parent: user_scoped, acl_role: "admin")` raises `ArgumentError` at construction because the child's claim set would include `"role:admin"`, which the parent's claim set does not. The same applies to a different `acl_user:` (different user_id), or to a child that resolves to master-key while the parent was scoped. This closes the analogous footgun for the acl_user / acl_role identity axis — the precedent of session_token swap is misleading because session tokens are externally verified by Parse Server, while `acl_user:` and `acl_role:` are unverified constructor assertions. A master-key parent (`@acl_scope.nil?`) allows any child scope because the parent already has unrestricted reach.

### Developer introspection — `agent.describe` / `describe_for` / `would_permit?` (v4.4.0)

Three helpers on every agent for answering "why is this agent refusing this call?" and "what can this agent actually see?" without parsing audit payloads or tracing through tool implementations. NOT exposed to the LLM — operator-side observability only.

**`agent.describe`** returns a Hash listing every layer that gates the agent:

```ruby
support = Parse::Agent.new(
  permissions: :readonly,
  session_token: user.session_token,
  classes: { only: [Ticket, Customer] },
  filters: { Ticket => { archived: false } },
  tools:   { except: [:emit_artifact] },
)

support.describe
# => {
#   agent_id:       "abc...",
#   permissions:    :readonly,
#   auth:           { mode: :session_token, fingerprint: "f8a9b2c1" },
#   tenant_id:      nil,
#   classes:        { only: ["Customer", "Ticket"], except: nil },
#   tools:          { only: nil, except: [:emit_artifact], effective: [...] },
#   methods:        { only: nil, except: nil },
#   filters:        { "Ticket" => ["archived"] },          # field names, not values
#   hidden_classes: ["_Product", "_Session"],
#   per_class:      { "Ticket" => {...}, "Customer" => {...} },
#   strict_modes:   { tool_filter: false, class_filter: false },
#   correlation_id: nil,
# }
```

Pass `pretty: true` for a multi-line String formatted for `puts` debugging — same data, human-readable rather than structured.

**`agent.describe_for(class_name)`** is the unbounded per-class lookup. Accepts Class constants, parse_class Strings, or Symbols:

```ruby
support.describe_for("Ticket")
# => {
#   class_name:              "Ticket",
#   accessible:              :permitted,
#   agent_fields:            [:subject, :status, :created_at, ...],
#   agent_canonical_filter:  { "draft" => { "$ne" => true } },
#   per_agent_filter:        { archived: false },                 # composed: per-class AND :default
#   tenant_scope:            { field: :tenant_id, value: "acme" },
#   large_fields:            [:body_html],
#   agent_methods:           ["archive", "reopen"],               # tier-filtered to what this agent can call
# }
```

**`agent.would_permit?(tool, class_name:)`** simulates the dispatch gate without invoking the tool. Lets a developer answer "why was this refused?" in one line:

```ruby
support.would_permit?(:query_class, class_name: "Ticket")
# => { allowed: true }

support.would_permit?(:create_object, class_name: "Ticket")
# => { allowed: false, reason: :tool_filtered, denied_at: :allowed_tools }

support.would_permit?(:query_class, class_name: "_User")
# => { allowed: false, reason: :class_filter, denied_at: :assert_class_accessible! }
```

The `reason:` Symbol mirrors the audit-payload `:denial_kind` discriminators (`:tool_filtered`, `:class_filter`, `:access_denied`, `:hidden_class`), so developer tooling and SOC subscribers branch on the same vocabulary.

**`session_token` is never echoed.** Master-key mode is shown as `{ mode: :master_key }` with no fingerprint. Session-token mode shows `{ mode: :session_token, fingerprint: "<8 hex>" }` — the first 8 hex characters of `SHA256(session_token)`. Two `describe` calls on the same session correlate to the same fingerprint without leaking the bearer token. Verified by test to never appear in Hash output, the `pretty: true` String, or `describe_for`.

**`:filters` summary echoes field names, not values.** A `filters: { Account => { user_id: "abc123" } }` shows as `{ "Account" => ["user_id"] }` in `describe[:filters]` — matching the same value-stripping policy used for the audit payload. Use `agent.filter_for(class_name)` directly when you need the constraint values themselves.

### `recursion_depth:` — sub-agent depth cap

Defends against any tool handler that constructs a sub-agent (e.g., the `delegate_to_subagent` recipe above) recursing without bound.

```ruby
# Use a tighter cap than the default for a single request
Parse::Agent.new(recursion_depth: 2)

# Change the global default
Parse::Agent.default_recursion_depth = 3
```

The default is **4**. The budget decrements on every inherited construction; a sub-agent that reaches `recursion_depth == 0` can still execute its own tools but cannot construct another sub-agent — that raises `Parse::Agent::RecursionLimitExceeded` at construction time. The error is intentionally a raise, not an `error_code:` — sub-agent construction is a programming-time choice, not a tool-dispatch decision, so it should surface immediately to the developer rather than be swallowed into the wire response.

### `Parse::Agent.strict_tool_filter` — boot-time unknown-name raise

Production deployments where `Kernel#warn` may be muted by the host process (some Passenger / Unicorn configurations with `$stderr` redirected to `/dev/null`) cannot rely on the lazy-allowlist warn for typo detection. Enable strict mode for boot-time crash on misconfiguration:

```ruby
# Global — applies to every Parse::Agent.new
Parse::Agent.strict_tool_filter = true

# Per-instance override — only this agent raises
Parse::Agent.new(tools: [...], strict_tool_filter: true)
```

`strict_tool_filter` applies only to `tools:`. The `methods:` filter is never validated against an "unknown name" list at construction (see the rationale in the `methods:` section above).

### Recipe: dashboard-only `emit_artifact` tool

The original v4.2 design motivation. A single `/mcp` mount serves both Claude Desktop external clients and the internal dashboard SPA; only the dashboard should see the `emit_artifact` tool:

```ruby
# At boot
Parse::Agent::Tools.register(
  name: :emit_artifact,
  description: "Persist a chart/table artifact for the dashboard to reload later.",
  parameters: { type: "object", properties: { ... } },
  permission: :readonly,
  handler: ->(agent, **args) { AdminInternal::Artifact.create!(**args, actor_sub: agent.correlation_id) },
)

# Mount
mount Parse::Agent.rack_app { |env|
  session = MyAuth.session_for(env)
  raise Parse::Agent::Unauthorized unless session

  base_args = {
    permissions:   :readonly,
    session_token: session.parse_token,
    tenant_id:     session.org_id,
  }

  if session.via_dashboard?
    Parse::Agent.new(**base_args)   # full registered surface — emit_artifact included
  else
    Parse::Agent.new(**base_args, tools: { except: [:emit_artifact] })
  end
}, at: "/mcp"
```

Per-request `tools/list` isolation is the load-bearing invariant for this pattern. The covering integration test is `test/lib/parse/agent/tool_filter_test.rb#test_mcp_dispatcher_tools_list_reflects_per_request_filter`.

---

## Conversational Client (MCPClient)

`Parse::Agent::MCPClient` wraps a `Parse::Agent` and adds an LLM round-trip layer. It translates the agent's MCP tool catalog into the provider's native function-calling schema, drives multi-turn tool-calling iterations, dispatches every tool the LLM invokes through `MCPDispatcher`, and returns a structured `Result` with the LLM's final answer plus token usage.

Use it when you need a natural-language interface to your Parse data without re-implementing the tool-translation and dispatch loop yourself.

### Provider setup

Three providers are supported. Select one via the `provider:` keyword or the `LLM_PROVIDER` environment variable:

| Provider | Value | Notes |
|----------|-------|-------|
| OpenAI | `:openai` | Uses the Chat Completions endpoint. Requires `LLM_API_KEY`. |
| Anthropic | `:anthropic` | Uses the Messages endpoint. Requires `LLM_API_KEY`. |
| LM Studio | `:lmstudio` | OpenAI-compatible; any local server (LM Studio, Ollama, vLLM). API key value is ignored. |

Default models when `LLM_MODEL` is not set: `gpt-4o-mini` (OpenAI), `claude-haiku-4-5` (Anthropic), `qwen2.5-7b-instruct` (LM Studio).

Default base URLs: `https://api.openai.com/v1` (OpenAI), `https://api.anthropic.com/v1` (Anthropic), `http://localhost:1234/v1` (LM Studio).

### Constructor

```ruby
require "parse/agent/mcp_client"

client = Parse::Agent::MCPClient.new(
  agent:           my_agent,        # required — a Parse::Agent instance
  provider:        :openai,         # required unless LLM_PROVIDER is set
  api_key:         ENV["LLM_API_KEY"],
  model:           "gpt-4o-mini",   # optional; overrides LLM_MODEL and default
  base_url:        nil,             # optional; overrides LLM_BASE_URL and default
  max_iterations:  8,               # cap on tool-call turns per ask (default 8)
  timeout:         90,              # per-request HTTP read timeout in seconds
  system_prompt:   nil,             # optional String prepended to every conversation
  pricing:         nil,             # override DEFAULT_PRICING table (Hash)
  auto_compact_at: nil,             # auto-compact threshold in tokens (Integer or nil)
)
```

`ArgumentError` is raised immediately if `provider` is missing, unknown, or if `api_key` is empty (except for `:lmstudio`, which ignores the value and fills a placeholder).

### Asking a question

```ruby
result = client.ask("How many users signed up in the last 24 hours?")

puts result.text         # the LLM's final answer as a String
result.tool_calls.each { |tc| puts "#{tc[:name]}: #{tc[:arguments].inspect}" }
puts result.usage        # "84 in + 120 out = 204 tokens   $0.000101"
```

`ask` resets conversation history by default (`reset: true`). Pass `reset: false` to continue from prior context:

```ruby
client.ask("How many users signed up in the last 24 hours?")
client.ask("And how many of those are in the Admin role?", reset: false)
```

### Result object

`ask` returns a `Parse::Agent::MCPClient::Result` struct:

| Attribute | Type | Description |
|-----------|------|-------------|
| `text` | String | The LLM's final-turn answer. |
| `tool_calls` | Array<Hash> | Ordered list of tools invoked. Each entry has `:name`, `:arguments`, and `:result`. |
| `transcript` | Array<Hash> | Full message log for the call (useful for debugging). |
| `usage` | `Usage` | Token counts and USD cost for this single `ask` call. |
| `client` | `MCPClient` | Back-reference to the originating client. |

`Result#reply(question)` continues the same conversation without resetting history:

```ruby
chain = client.ask("How many Song records do we have?")
            .reply("Which genre has the most?")
            .reply("And the fewest?")
puts chain.text
```

### Multi-turn sessions

History accumulates across `ask(..., reset: false)` calls. Read it at any point:

```ruby
client.history  # => Array of { role:, content: } hashes (a dup — safe to inspect)
```

Reset explicitly when you want to start fresh without constructing a new client:

```ruby
client.reset!
```

### Token usage and cost

```ruby
# Per-call usage from the most recent ask
puts client.last_call_usage   # "42 in + 65 out = 107 tokens   $0.000053"

# Running session totals (accumulates across every ask and compact! call)
puts client.usage             # "512 in + 890 out = 1402 tokens   $0.001231"
```

The `Usage` struct has fields `prompt_tokens`, `completion_tokens`, `total_tokens`, and `cost_usd` (USD dollars, not cents). Arithmetic via `+` is defined, so you can sum usages from separate clients.

Cost is computed from `DEFAULT_PRICING`, a table of list prices per million tokens keyed by model name. Override at construction time with `pricing:` or assign to `client.pricing` afterward:

```ruby
client.pricing = { "gpt-4o-mini" => { input: 0.15, output: 0.60 } }
```

Models not in the table default to zero cost.

### Session compaction

When a long session approaches the model's context limit, call `compact!` to replace the conversation history with an LLM-generated summary that preserves tool-retrieved facts:

```ruby
summary = client.compact!
# => "The database has 4,231 users, of which 87 are admins. The most active..."
```

`compact!` costs one extra LLM call; its token usage is folded into `client.usage`. After compacting, `client.history` contains a single system-tagged summary turn.

### Automatic compaction

Set `auto_compact_at:` at construction time to trigger compaction automatically when the session's running total crosses a threshold:

```ruby
client = Parse::Agent::MCPClient.new(
  agent:           my_agent,
  provider:        :openai,
  api_key:         ENV["LLM_API_KEY"],
  auto_compact_at: 50_000,   # compact when session exceeds 50k tokens
)
```

`max_iterations: 8` (the default) caps tool-call turns per `ask` call, providing implicit per-question cost protection independent of session length.

### End-to-end example

```ruby
require "parse-stack"
require "parse/agent"
require "parse/agent/mcp_client"

# Boot the Parse client (production app would use ENV vars or an initializer)
Parse.setup(
  server_url:     ENV["PARSE_SERVER_URL"],
  application_id: ENV["PARSE_APP_ID"],
  api_key:        ENV["PARSE_API_KEY"],
  master_key:     ENV["PARSE_MASTER_KEY"],
)

agent  = Parse::Agent.new(permissions: :readonly)
client = Parse::Agent::MCPClient.new(
  agent:           agent,
  provider:        :openai,
  api_key:         ENV["LLM_API_KEY"],
  model:           "gpt-4o-mini",
  max_iterations:  8,
  auto_compact_at: 40_000,
)

# Single question
result = client.ask("What are the five most recently created Song records?")
puts result.text

# Multi-turn chain using reply
client.ask("How many Song records are there in total?")
      .reply("Which artist appears most often?")
      .reply("Does that artist have any records created before 2024?")
      .tap { |r| puts r.text }

# Session cost summary
puts "Session total: #{client.usage}"
```

---

## Rake Tasks for Local Interaction

Three rake tasks give you immediate access to Parse data via the MCP agent layer: a conversational chat loop (`mcp:chat`), an IRB console with MCP helpers pre-bound (`mcp:console`), and a one-shot tool dispatcher (`mcp:tool`).

### Environment setup

All three tasks read configuration from `.env` (via `dotenv`) or from shell environment variables. Copy `.env.sample` to `.env` and fill in values:

```bash
cp .env.sample .env
```

The Parse connection block is required for all tasks:

```bash
PARSE_SERVER_URL=http://localhost:2337/parse
PARSE_APP_ID=myAppId
PARSE_API_KEY=myApiKey
PARSE_MASTER_KEY=myMasterKey
```

For `mcp:chat` and the optional LLM binding in `mcp:console`, add one provider stanza. Pick one:

```bash
# OpenAI (~$0.0001 per question with gpt-4o-mini)
LLM_PROVIDER=openai
LLM_API_KEY=sk-proj-...
LLM_MODEL=gpt-4o-mini

# Anthropic (~$0.001 per question with claude-haiku-4-5)
LLM_PROVIDER=anthropic
LLM_API_KEY=sk-ant-api03-...
LLM_MODEL=claude-haiku-4-5

# LM Studio (free, local — start the server first)
LLM_PROVIDER=lmstudio
LLM_MODEL=qwen2.5-7b-instruct
LLM_BASE_URL=http://localhost:1234/v1
LLM_API_KEY=lm-studio
```

See `.env.sample` for the complete template including optional fields.

**Sanity check.** Verify the Docker Parse Server is reachable before running tasks that require it:

```bash
curl http://localhost:2337/parse/health
# Expected: {"status":"ok"}
```

If that fails, start the test containers first: `docker-compose -f scripts/docker/docker-compose.test.yml up -d`.

### `rake mcp:chat` — conversational loop

A continuous chat session backed by `MCPClient`. Each input drives the LLM through tool calls against Parse and prints the final answer. History persists across turns within the session.

```bash
bundle exec rake mcp:chat
```

Requires `LLM_PROVIDER` and `LLM_API_KEY` in the environment (or `.env`). Aborts with a helpful message if `LLM_PROVIDER` is not set.

**Slash commands available inside the loop:**

| Command | Effect |
|---------|--------|
| `/reset` | Clear conversation history and start fresh. |
| `/compact` | Replace history with an LLM-generated summary (one extra call). Prints the token delta and a truncated preview. |
| `/tools` | Print every MCP tool available to the current agent (sorted). |
| `/trace` | Toggle per-turn tool-call trace output on or off. Also controlled by `MCP_CHAT_TRACE=true` in the environment at startup. |
| `/cost` | Print session token totals and USD cost, plus per-call figures from the last turn. |
| `/history` | Print the current conversation history (first 120 characters per turn). |
| `/exit` or `/quit` | End the session. Also: `Ctrl-D` or an empty line. |

```
$ bundle exec rake mcp:chat

Parse MCP Chat — openai / gpt-4o-mini
Permissions: readonly  |  Trace: off
Type your question. Slash commands: /reset /tools /trace /history /exit
======================================================================

> How many Song records do we have?

There are 4,231 Song records in the database.

> /cost
  session: 84 in + 121 out = 205 tokens   $0.0001
  last:    84 in + 121 out = 205 tokens   $0.000101

> /exit
bye
```

Override the default `:readonly` permission level with `MCP_AGENT_PERMISSIONS=write rake mcp:chat` if you need write-capable tools in the session.

### `rake mcp:console` — IRB REPL with MCP helpers

Drops you into an IRB session with a pre-configured `Parse::Agent` and a set of shortcut helpers bound at the top level. Useful for ad-hoc exploration, debugging custom tools, and testing query shapes interactively.

```bash
bundle exec rake mcp:console
```

**Helpers available in the session:**

| Helper | Description |
|--------|-------------|
| `agent` | The configured `Parse::Agent` instance. |
| `tools` | Print all available tool names (sorted), return count. |
| `schemas` | Print all visible class names grouped by custom / built-in, return combined list. |
| `t(name, **kwargs)` | Invoke a tool by name. Returns the raw result hash. |
| `q(class_name, **opts)` | Shortcut for `t(:query_class, class_name:, **opts)`. |
| `count(class_name)` | Shortcut for `t(:count_objects, class_name:)`. |
| `schema(class_name)` | Shortcut for `t(:get_schema, class_name:)`. |
| `dispatch(method, params={})` | Build and dispatch a raw MCP JSON-RPC call. Returns the dispatcher result hash. |
| `prompts` | Print all registered and built-in prompt names, return count. |
| `render_prompt(name, args={})` | Render a prompt to its message envelope. |

When `LLM_PROVIDER` (and `LLM_API_KEY` for cloud providers) is set in the environment, the console also binds `mcp` as a `Parse::Agent::MCPClient` instance, enabling natural-language queries inline:

```ruby
irb> mcp.ask("how many students are there?")
irb> _.reply("just for Ms. Vasquez")   # _ is the last Result; reply continues the conversation
```

Example session:

```ruby
irb> tools
# count_objects
# get_object
# query_class
# ...

irb> schemas
# Custom:   Song, Album, Comment
# Built-in: _User, _Role, _Session
# => ["Song", "Album", "Comment", "_User", "_Role", "_Session"]

irb> q("Song", limit: 3, where: { "genre" => "Rock" })
# => { success: true, data: { results: [...], count: 3 } }

irb> count("Song")
# => { success: true, data: { count: 4231, class_name: "Song" } }

irb> dispatch("initialize")
# => { status: 200, body: { "jsonrpc" => "2.0", "result" => { ... } } }
```

### `rake "mcp:tool[name,jsonArgs]"` — one-shot tool dispatch

Execute a single tool call from the command line without entering IRB. Arguments are passed as a JSON object. The result is printed as pretty JSON; the task exits with status `0` on success, `1` on failure.

```bash
# Count objects in a class
bundle exec rake "mcp:tool[count_objects,{\"class_name\":\"_User\"}]"

# Query with a where clause
bundle exec rake "mcp:tool[query_class,{\"class_name\":\"Song\",\"limit\":5,\"where\":{\"genre\":\"Rock\"}}]"

# Fetch a schema
bundle exec rake "mcp:tool[get_schema,{\"class_name\":\"_User\"}]"
```

The tool name maps directly to a built-in or registered tool. Use `bundle exec rake mcp:console` then type `tools` if you need to enumerate available names.

The permission level defaults to `:readonly`. Override with `MCP_AGENT_PERMISSIONS`:

```bash
MCP_AGENT_PERMISSIONS=write bundle exec rake "mcp:tool[create_class,{\"class_name\":\"Playlist\"}]"
```

---

## Prompts

Prompts are named instruction templates that an MCP client can request by name, optionally passing arguments. The dispatcher exposes them via `prompts/list` and `prompts/get`.

### Built-in prompts

| Name | Description |
|------|-------------|
| `parse_conventions` | Generic Parse platform conventions (objectId shape, pointer/date formats, system classes). Fetch once and prepend to your LLM system message. |
| `parse_relations` | ASCII diagram of class relationships derived from `belongs_to` and `has_many :through => :relation`. Accepts an optional `classes` argument (comma-separated subset). |
| `explore_database` | Survey all Parse classes: list them, count each, and summarize what each appears to store. |
| `class_overview` | Describe a class in detail: schema, total count, and sample objects. Requires `class_name`. |
| `count_by` | Count objects in a class grouped by a field. Requires `class_name` and `group_by`. |
| `recent_activity` | Show the most recently created objects in a class. Requires `class_name`; optional `limit` (default 10, max 100). |
| `find_relationship` | Find objects in one class related to a given object in another via a pointer field. Requires `parent_class`, `parent_id`, `child_class`, `pointer_field`. |
| `created_in_range` | Count and sample objects created within a date range. Requires `class_name` and `since` (ISO8601); optional `until`. |

### Registering custom prompts

Register before the `MCPRackApp` or `MCPServer` starts handling requests. Registration is thread-safe (guarded by an internal mutex), but the registry is global to the process.

```ruby
Parse::Agent::Prompts.register(
  name:        "team_health",
  description: "Summary of workspace activity in the last 30 days",
  arguments: [
    { "name" => "team_id", "description" => "Parse objectId of the workspace", "required" => true }
  ],
  renderer: ->(args) {
    since = (Time.now - 30 * 86400).utc.iso8601
    "Show activity for workspace #{args["team_id"]} since #{since}. " \
    "Use count_objects and query_class to report events, members, and recent changes."
  }
)
```

A renderer lambda may return either:

- A `String` — used directly as the MCP message text. Description defaults to `"Parse analytics prompt: <name>"`.
- A `Hash` with `:description` and `:text` keys — both are used verbatim. This is the only way to customize the per-render description.

```ruby
# Hash form — overrides description per render
renderer: ->(args) {
  {
    description: "Workspace #{args["team_id"]} health report",
    text:        "Analyze workspace #{args["team_id"]} activity since #{Time.now - 30 * 86400}."
  }
}
```

Registering a name that matches a built-in replaces the built-in in `prompts/list` and `prompts/get` responses. To restore built-in-only state (useful in test teardown), call `Parse::Agent::Prompts.reset_registry!`.

---

## MCP Protocol Surface

All requests must be HTTP `POST` to the mounted path with `Content-Type: application/json`.

### Supported methods

| Method | Description |
|--------|-------------|
| `initialize` | MCP handshake. Returns protocol version, server capabilities, and server name/version. |
| `tools/list` | Returns all tools available to the current agent (filtered by permission level). Includes custom registered tools. Every descriptor carries a `_meta.category` field (v4.2.1). Accepts an optional non-standard `category` param to narrow the response server-side; see [Tool Categories & `list_tools`](#tool-categories--list_tools). |
| `tools/call` | Executes a named tool with arguments. Tool-level errors return `isError: true` in `content`, not a JSON-RPC `error` field. The built-in `list_tools` tool (v4.2.1) returns a lightweight catalog (`name`+`category`+`description` only) and is significantly cheaper than `tools/list` for discovery. |
| `prompts/list` | Returns all available prompts (built-in plus registered). |
| `prompts/get` | Renders a named prompt with arguments. Returns `{ description, messages }`. |
| `resources/list` | Lists virtual resources for each Parse class: `parse://<ClassName>/schema`, `/count`, `/samples`. Fixed in the same release as `agent_hidden` — see note below. |
| `resources/templates/list` | Returns the three URI templates (`parse://{className}/{schema,count,samples}`) clients can use to build resource URIs without scraping `resources/list`. See **Resource templates** below. |
| `resources/read` | Reads a resource by URI. Supported kinds: `schema`, `count`, `samples`. |
| `ping` | No-op. Returns an empty result `{}`. |
| `notifications/initialized` | Client signal that the `initialize` handshake completed. JSON-RPC notification (no `id`, no response body). The dispatcher performs no work — accepting the method prevents spurious `-32601 "Method not found"` errors at clients that send it (Claude Desktop, MCP Inspector, Cursor). |
| `notifications/cancelled` | Cooperative cancellation of an in-flight request. JSON-RPC notification (no `id`, no response body). See **Cancellation** section. |
| `notifications/tools/list_changed` | Server → client SSE-only notification fired when `Parse::Agent::Tools.register` or `Tools.reset_registry!` mutates the registry. See **listChanged notifications** below. |
| `notifications/prompts/list_changed` | Server → client SSE-only notification fired when `Parse::Agent::Prompts.register` or `Prompts.reset_registry!` mutates the registry. |

**`resources/list` bug fix.** Earlier versions of `MCPDispatcher#handle_resources_list` read `result[:data][:classes]` from the `get_all_schemas` response — a key that does not exist in the envelope returned by `ResultFormatter#format_schemas`, which uses `{ total:, note:, built_in: [...], custom: [...] }`. This caused every call to `resources/list` from external MCP clients (Claude Desktop, Cursor, Continue.dev, MCP Inspector) to return an empty resource catalog. The handler now reads the `custom` and `built_in` arrays from the correct keys. Each Parse class produces three resource URIs: `parse://<Class>/schema`, `parse://<Class>/count`, and `parse://<Class>/samples`. If you were previously seeing an empty `resources/list` response, no change to your client configuration is needed — the fix is server-side.

**Resource templates (v4.2).** `resources/templates/list` returns three RFC 6570 URI templates so clients can build resource URIs for any Parse class without scraping the full `resources/list` enumeration. The response shape is:

```json
{
  "resourceTemplates": [
    { "uriTemplate": "parse://{className}/schema",  "name": "Parse class schema",         "mimeType": "application/json", "description": "..." },
    { "uriTemplate": "parse://{className}/count",   "name": "Parse class object count",   "mimeType": "application/json", "description": "..." },
    { "uriTemplate": "parse://{className}/samples", "name": "Parse class sample objects", "mimeType": "application/json", "description": "..." }
  ]
}
```

Three properties worth knowing:

- **Templates are static server metadata.** The handler does not call `get_all_schemas` or any other agent tool — templates describe the URI shape, not the set of resources that exist. Clients combine the template with a `className` they discovered through `tools/list`, `resources/list`, or their own knowledge.
- **`{className}` is unconstrained on the wire.** The class-name placeholder is validated when the client actually calls `resources/read parse://<expanded-name>/<kind>`; unknown or malformed names refuse there with a `-32602`. The template surface deliberately does not enumerate which classes are valid because that would leak across `agent_hidden` boundaries.
- **`resources/list` is still authoritative for enumeration.** Use templates when a client wants to construct a resource URI for a known class name without re-polling. Use `resources/list` when a client wants to discover which classes have resources to fetch.

**Pagination.** `tools/list` and `prompts/list` return the full registry in a single response — there is no `cursor`/`nextCursor` pagination. The MCP spec marks pagination as optional for these endpoints. With dozens of registered tools and prompts the response stays small; practical experience suggests keeping each registry under roughly 100 entries before considering grouping, namespacing, or pruning. Aggregate-style features like `resources/list` (which scales with the Parse class count) are similarly unpaginated.

**MCP protocol version.** `Parse::Agent::MCPDispatcher::PROTOCOL_VERSION` advertises `"2025-06-18"`. Earlier releases pinned `"2024-11-05"`; the bump in v4.2 enables the optional `message` field on `notifications/progress` (added in 2025-03-26) and the `outputSchema` / `structuredContent` fields (2025-06-18) that registered tools may opt into via `Parse::Agent::Tools.register(..., output_schema:)`. Forward-compatible with additive 2025-06-18 fields (`annotations`, resource links) that this gem does not emit. Clients negotiating an older version still interpret the supported methods and capability shape correctly. To track a still-newer MCP revision, update this constant and verify the `initialize` handshake response, the capability declaration shape, and any new error codes against the target version's schema.

**Capability advertisement.** The `initialize` response declares:

```json
{
  "tools":     { "listChanged": true  },
  "resources": { "subscribe": false, "listChanged": false },
  "prompts":   { "listChanged": true  }
}
```

`tools.listChanged` and `prompts.listChanged` were `false` prior to v4.2. They now match the SSE broadcast behavior described in the next subsection. `resources.listChanged` and `resources.subscribe` remain `false` — resource list mutations require an explicit deploy and are not signaled to clients at runtime.

### listChanged notifications

When an application calls `Parse::Agent::Tools.register`, `Tools.reset_registry!`, `Parse::Agent::Prompts.register`, or `Prompts.reset_registry!` at runtime, every live SSE-streaming MCP client receives a `notifications/tools/list_changed` (or `.../prompts/list_changed`) event. The wire shape is a JSON-RPC notification with no `params`:

```json
{ "jsonrpc": "2.0", "method": "notifications/tools/list_changed" }
```

Per spec, clients are expected to re-fetch the corresponding list (`tools/list` or `prompts/list`) to see the updated state. The server does not include the new state inline.

**Subscription lifecycle.** `MCPRackApp::SSEBody` subscribes to both registries when its worker thread starts (`#each` is called) and deregisters on `#close`. Deregistration runs BEFORE the on_close hook fires so a subsequent registry mutation cannot push events into a queue belonging to a stream that has already ended.

**Scope.** Broadcast is per-process and SSE-only:
- JSON-path requests cannot receive notifications. Clients on the JSON path see the new state on their next `tools/list` or `prompts/list` poll.
- The standalone WEBrick-backed `MCPServer` does not support streaming and therefore does not deliver listChanged events.
- Notifications are not replicated across processes in a clustered deployment — each node broadcasts only to its own connected clients.

**Subscribing from application code.** Application code that wants to react to registry changes (audit logging, cache invalidation) can call `Parse::Agent::Tools.subscribe { ... }`. The block receives no arguments and is invoked synchronously on the thread that triggered the mutation. The return value is a `Proc` that, when called with no arguments, deregisters the subscriber:

```ruby
unsubscribe = Parse::Agent::Tools.subscribe do
  Rails.logger.info "[mcp] tools registry changed; current names: #{Parse::Agent::Tools.all_tool_names.inspect}"
end
# later, at shutdown:
unsubscribe.call
```

Subscriber callbacks must be fast and non-blocking; long work belongs in a thread or queue that the callback posts to. Exceptions raised by a subscriber are caught and logged via `Kernel#warn` — one bad subscriber cannot break the registry or prevent other subscribers from firing.

### Structured tool output

Registered tools may declare an `outputSchema` via `Parse::Agent::Tools.register(..., output_schema:)`. When declared, the schema surfaces on the `tools/list` response as `outputSchema` for that tool's descriptor, and `tools/call` responses for that tool carry both the existing human-readable `content` array AND a `structuredContent` field mirroring the handler's result data Hash:

```ruby
Parse::Agent::Tools.register(
  name:          :record_summary,
  description:   "Summarize a record by id",
  parameters:    { "type" => "object", "properties" => { "id" => { "type" => "string" } }, "required" => ["id"] },
  permission:    :readonly,
  output_schema: {
    "type" => "object",
    "properties" => {
      "id"    => { "type" => "string" },
      "title" => { "type" => "string" },
      "score" => { "type" => "number" }
    },
    "required" => ["id", "title"]
  },
  handler: ->(_agent, id:) { { id: id, title: lookup(id).title, score: lookup(id).score } }
)
```

The `tools/call` response for this tool ships with both forms:

```json
{
  "content":           [{ "type": "text", "text": "{\n  \"id\": \"abc\", ...\n}" }],
  "structuredContent": { "id": "abc", "title": "...", "score": 0.91 },
  "isError":           false
}
```

Per MCP 2025-06-18 expectations, clients should prefer `structuredContent` over parsing `content` text. The text content is unchanged from prior versions so legacy clients keep working unmodified.

**Built-in tool coverage (v5.0+).** Eleven built-in tools now declare `outputSchema` and emit `structuredContent` automatically: `count_objects`, `get_object`, `get_objects`, `get_sample_objects`, `distinct`, `group_by`, `group_by_date`, `list_tools`, `get_all_schemas`, `get_schema`, and `query_class`. The dispatcher mirrors each tool's result `data` Hash into `structuredContent` in addition to the existing text `content` array. `query_class` declares a permissive superset envelope (single `type: "object"` root, as MCP requires) that admits both the default JSON row shape (`{class_name, result_count, pagination, results, ...}`) and the `format: "csv" | "markdown" | "table"` text shape (`{class_name, format, headers, row_count, output}`) — clients disambiguate via the presence of `format`.

**Remaining text-only built-ins.** `aggregate`, `export_data`, `atlas_text_search`, `atlas_autocomplete`, `atlas_faceted_search`, `explain_query`, and `call_method` continue to emit text-only output. `explain_query` mirrors MongoDB's version-dependent explain shape and `call_method` returns application-defined values, so both may stay text-only indefinitely; the Atlas + aggregate tools will opt in as their envelope shapes stabilize.

**Custom tools.** The `output_schema:` parameter on `Tools.register` remains optional; tools registered without it produce the same text-only wire shape they did in 4.1.

### Batch pointer resolution: `get_objects`

When you need to dereference multiple pointers, use `get_objects(class_name:, ids:, include:)` instead of N separate `get_object` calls. The batch tool resolves all IDs in a single Parse API request and is significantly cheaper for both latency and tokens.

```ruby
result = agent.execute(:get_objects,
  class_name: "User",
  ids:        ["abc123", "def456", "xyz789"],
  include:    ["workspace"]      # optional pointer fields to resolve
)
# result[:data] =>
# {
#   class_name: "User",
#   objects:    { "abc123" => {...user}, "def456" => {...user} },
#   missing:    ["xyz789"],   # ids that did not match any document
#   requested:  3,
#   found:      2
# }
```

Three contract details worth knowing:

- **50-id cap.** The tool deduplicates `ids` and rejects calls where the deduplicated count exceeds 50. Use `query_class` with a `where: { "objectId" => { "$in" => [...] } }` filter for larger sets.
- **Hash-keyed response.** `objects` is a Hash keyed by `objectId`, not an Array, so client code can look up by id without scanning. Missing ids appear in the separate `missing` array.
- **agent_fields allowlist inheritance.** If the underlying class declares `agent_fields :only, :these` in its model, the batch fetch applies the same allowlist as a `keys:` projection — PII trimming is consistent with the single-object `get_object` path.

### Error codes

| Code | Name | When used |
|------|------|-----------|
| `-32700` | Parse error | Body is invalid JSON, wrong content-type, or body exceeds size limit. |
| `-32601` | Method not found | The `method` string is not one of the supported methods above. |
| `-32602` | Invalid params | Missing or malformed arguments (tool name, resource URI, prompt arguments). |
| `-32603` | Internal error | Unexpected `StandardError` inside a handler. Wire body is the literal string `"Internal error"` — no class name, no message, no backtrace. Class and message are emitted to the operator's logger only. |
| `-32001` | Unauthorized | `Parse::Agent::Unauthorized` raised by the agent factory or a tool. HTTP status 401. |

For tool-call failures that are not protocol errors (a query that returns no results, a class that does not exist), the dispatcher returns HTTP 200 with `isError: true` inside the `content` array — not a JSON-RPC error code.

### Tool-result `error_code` and structured `details:` (v4.2.1)

When a tool fails inside `Parse::Agent#execute`, the failure envelope returned to MCP clients carries an `error_code:` symbol naming the broad category (`:access_denied`, `:invalid_argument`, `:invalid_query`, `:permission_denied`, `:tool_filtered`, `:rate_limited`, `:timeout`, `:cancelled`, `:security_blocked`, `:parse_error`, `:tool_error`).

For `:access_denied` refusals, the envelope additionally carries a `details:` block populated from `Parse::Agent::AccessDenied#to_details`. It lets consumers branch on the specific refusal reason — and, when applicable, auto-rewrite the failing request — without parsing the prose `error:` message:

```ruby
agent.execute(:aggregate, class_name: "Post",
  pipeline: [{ "$group" => { "_id" => "$_p_author", "n" => { "$sum" => 1 } } }]
)
# => {
#   success:    false,
#   error:      "field reference '$_p_author' (\"_p_author\") outside agent_fields allowlist. " \
#               "Allowed: author, title, createdAt, ... Hint: '_p_author' is the Parse-on-Mongo " \
#               "storage column for the 'author' pointer field — reference 'author' directly (e.g. '$author')",
#   error_code: :access_denied,
#   details: {
#     kind:              :storage_form_field_ref,
#     denied_field:      "_p_author",
#     allowed_fields:    ["author", "title", "createdAt", "updatedAt", "objectId"],
#     suggested_rewrite: "$author"
#   }
# }
```

Known `details[:kind]` subcodes for `:access_denied`:

| Subcode | When emitted |
|---------|--------------|
| `:hidden_class` | Target class is marked `agent_hidden` (or its alias resolves to one). Unconditional refusal; the agent's `classes:` filter doesn't apply. |
| `:class_filter` | v4.3.0+. Target class is outside the per-agent `classes:` allowlist. Distinct from `:hidden_class` so SOC tooling can separate operator narrowing from policy-level denials. Fires from any of the six enforcement sites: top-level dispatch, include resolution, `$lookup.from`, `$inQuery`/`$select` cross-class operators, post-fetch redaction, and `group_by` group-key collapse. |
| `:field_denied` | Projection/sort/match/expression field is outside the class's `agent_fields` allowlist |
| `:storage_form_field_ref` | Same as `:field_denied`, but the offending name is the Parse-on-Mongo storage column (`_p_*`); `details[:suggested_rewrite]` points at the bare pointer field name |

`details[:allowed_fields]` is capped at the first 20 entries for wire compactness. When the class has more, the prose `error:` message includes a `+N more` suffix; the structured array is preview-only.

The top-level `error_code` stays at `:access_denied` for back-compat with consumers that only branch on it. The new subcode is purely additive — clients that ignore `details:` see no change in behavior.

**On the wire (5.2+):** `error_code`, `retry_after`, and `details` are forwarded on the MCP tool-error envelope under `_meta` — `parse.error_code`, `parse.retry_after`, `parse.details` — so a spec-compliant client can branch deterministically (and honor `retry_after`) without parsing the prose `content` text. The `content` text and `isError: true` are unchanged.

---

## Performance and Timeouts

### Tool timeout table

Each tool runs inside a `Timeout.timeout` block. The default timeouts are:

| Tool | Timeout (seconds) |
|------|--------------------|
| `aggregate` | 60 |
| `query_class` | 30 |
| `explain_query` | 30 |
| `call_method` | 60 |
| `get_all_schemas` | 15 |
| `get_schema` | 10 |
| `count_objects` | 20 |
| `get_object` | 10 |
| `get_sample_objects` | 15 |

Custom tools registered via `Parse::Agent::Tools.register` default to 30 seconds unless a `timeout:` value is supplied.

When a timeout fires, `Agent#execute` returns `{ success: false, error_code: :timeout }` with a message suggesting the client narrow the filter or add an index.

### MongoDB `maxTimeMS` pushdown

The `query_class` and `aggregate` tools push the tool timeout (minus a 5-second buffer) down to MongoDB as `maxTimeMS`. This ensures that if the Ruby-level `Timeout` fires, MongoDB also cancels the query rather than continuing to consume server resources.

When MongoDB cancels an operation due to `maxTimeMS`, it raises `Parse::MongoDB::ExecutionTimeout`. `Agent#execute` catches this and returns:

```ruby
{ success: false, error_code: :timeout, error: "Query exceeded time limit. Narrow the filter or add an index." }
```

### Response size cap

`MCPDispatcher` enforces `MAX_TOOL_RESPONSE_BYTES = 4_194_304` (4 MiB) on serialized tool results. When a `tools/call` response would exceed this limit, the dispatcher takes one of two paths depending on the tool:

**`query_class` — truncate-and-annotate (partial success).** Instead of refusing outright, the dispatcher samples the rows, identifies the heaviest field by per-record bytes, drops that field from every row, and re-serializes. If still over budget it additionally trims trailing rows. The recovered response is returned as `isError: false` with a `_truncated` annotation block:

```ruby
{
  results: [...],
  _truncated: {
    reason:         "response_exceeded_max_bytes",
    dropped_fields: ["full_text"],
    kept_count:     7,
    original_count: 50,
    next_skip:      107,            # only present when rows were trimmed
    hint:           "Field 'full_text' was dropped and only the first 7 of 50 rows fit the 4194304-byte cap. " \
                    "Call query_class(skip: 107) to fetch the next page, or get_object(class_name: <class>, " \
                    "object_id: <id>) for the dropped field.",
  }
}
```

`next_skip` adds the caller's original `skip:` so consecutive `query_class` calls advance through the same dataset instead of looping. Stale `result_count`, `truncated`, and `truncated_note` fields (from `ResultFormatter`'s 50-row display cap) are stripped from the recovered envelope so `_truncated` is the sole authoritative source on cardinality. The hint deliberately mentions `get_object` so an LLM can fetch the dropped field for a specific row of interest without re-paginating.

**Other tools — structural refusal with diagnostic.** `aggregate`, `export_data`, `get_object`, `get_objects` all retain `isError: true` refusal. The refusal message includes a per-field byte diagnostic naming the heaviest fields and a POSITIVE `keys:` projection list the caller can use on retry:

```
Tool result exceeded 4194304 bytes (5234567). Largest fields by bytes:
full_text (~98 KB/record), description (52 B/record), title (12 B/record).
Try keys: "objectId,createdAt,updatedAt,title,description" (drops the heaviest field).
Narrow the query: lower limit:, project fewer fields via keys:/select:, or add stricter where: constraints.
```

The positive keep-list is intentional — asking the model to subtract (`"excluding 'full_text'"`) produces unreliable retries (Mongo-style `keys: "-full_text"` or dropped `keys:` entirely). Field NAMES appear in the diagnostic; field VALUES never do. The diagnostic respects upstream access control: the sampler walks data that has already passed through `redact_hidden_classes!` and any `agent_fields` projection, so it cannot fingerprint hidden-class contents or PII-trimmed fields.

The oversized payload is never buffered to the wire in either path — the cap check happens before any HTTP write.

### `explain_query` and COLLSCAN refusal

To detect and block full-collection scans at the tool level, set the global opt-in flag:

```ruby
Parse::Agent.refuse_collscan = true
```

With this flag set, `explain_query` will return an error if the query plan shows a `COLLSCAN` (full collection scan) stage, rather than executing it. This is useful in production environments where unindexed queries against large collections can cause performance problems.

**Refusal response shape.** When `refuse_collscan = true` blocks a query, the tool returns `success: false` with:

```ruby
{
  success: false,
  error: "COLLSCAN on #{class_name} — query would scan the full collection",
  error_code: :security_blocked,
  refused: true,
  reason: "COLLSCAN on #{class_name}",
  suggestion: "Add a filter on an indexed field, or call explain_query directly to inspect the plan."
}
```

The `winning_plan` field is included only when `Parse::Agent.expose_explain = true` (default false). Exposing the plan is an index-topology enumeration oracle — keep it false for untrusted callers.

**Security caveat: COLLSCAN refusal is an enumeration oracle.** Even with `expose_explain = false`, the binary refused/not-refused signal lets an authenticated caller probe `where:` clauses across the schema and learn which fields are unindexed. Do not enable `refuse_collscan` on deployments serving untrusted or multi-tenant callers without additional rate-limiting and audit logging. Treat the refusal mechanism as a performance guard for cooperative clients, not a security boundary.

Per-class override via the `agent_allow_collscan` DSL — for small lookup tables (Roles, Config, feature flags) where a scan is cheap and expected, and forcing an index would be pointless:

```ruby
class Role < Parse::Object
  agent_allow_collscan  # small lookup table, scan is fine
end

class FeatureFlag < Parse::Object
  agent_allow_collscan
end
```

The DSL takes no arguments — its presence in the class body opts that class out. Without `refuse_collscan` set globally, the per-class declaration is a no-op (no extra overhead).

---

## Observability

### MCPRackApp logger

Pass a logger at construction time and `MCPRackApp` will emit:

- Auth failures at `warn` level: `"[Parse::Agent::MCPRackApp] Unauthorized: <ExceptionClass>"` (class name only, no message).
- Factory errors (non-Unauthorized) at `warn` level: `"[Parse::Agent::MCPRackApp] Factory error: <ExceptionClass>"` followed by the backtrace.

```ruby
Parse::Agent.rack_app(logger: Rails.logger) do |env|
  # ... factory ...
end
```

### MCPDispatcher logger

When `MCPRackApp` has a logger, it is forwarded to `MCPDispatcher.call(logger: ...)` automatically. The dispatcher emits internal errors in the format:

```
[Parse::Agent::MCPDispatcher] <ExceptionClass>: <exception message>
```

This line goes to the logger when one is provided, or to `$stderr` via `Kernel#warn` when not. It is the only place the exception class and message are visible — they are never included in the wire response.

### ActiveSupport::Notifications

Every tool call dispatched through `Agent#execute` fires the `"parse.agent.tool_call"` notification. The payload is sanitized: sensitive argument keys (`where:`, `pipeline:`, `session_token:`, `password:`, etc.) are stripped before the payload is published.

**Payload keys:**

| Key | Type | Present |
|-----|------|---------|
| `:tool` | Symbol | Always |
| `:args_keys` | Array<Symbol> | Always — argument keys with SENSITIVE_LOG_KEYS removed |
| `:auth_type` | Symbol | Always — `:session_token` or `:master_key` |
| `:using_master_key` | Boolean | Always |
| `:permissions` | Symbol | Always — `:readonly`, `:write`, or `:admin` |
| `:agent_id` | Integer | Always — process-unique identifier (`Object#object_id`) for the dispatching agent instance |
| `:agent_depth` | Integer | Always — call-tree depth; `0` for a root agent, `+1` per inherited (`parent:`) construction |
| `:success` | Boolean | Always (set at block exit) |
| `:result_size` | Integer | Success only — serialized byte count |
| `:error_class` | String | Failure only — exception class name |
| `:error_code` | Symbol | Failure only — `:security_blocked`, `:access_denied`, `:invalid_query`, `:timeout`, `:rate_limited`, `:invalid_argument`, `:parse_error`, `:internal_error`, `:permission_denied`, `:tool_filtered`, or `:cancelled` |
| `:correlation_id` | String | Only when set — caller-supplied conversation/session identifier (see below) |
| `:parent_agent_id` | Integer | Only on sub-agents — the `agent_id` of the parent that constructed this instance via `parent:` |
| `:classes_only` | Array<String> | v4.3.0+ — when the agent was constructed with `classes: { only: [...] }`. Sorted canonical class-name strings (`["Post", "Topic"]`). |
| `:classes_except` | Array<String> | v4.3.0+ — when the agent was constructed with `classes: { except: [...] }`. |
| `:tools_only` | Array<Symbol> | v4.3.0+ — when the agent was constructed with `tools: { only: [...] }` or the Array shorthand. Sorted. |
| `:tools_except` | Array<Symbol> | v4.3.0+ — when the agent was constructed with `tools: { except: [...] }`. |
| `:methods_only` | Array<String> | v4.3.0+ — when the agent was constructed with `methods: { only: [...] }`. Bare names and `"Class.method"` qualified names mix. |
| `:methods_except` | Array<String> | v4.3.0+ — when the agent was constructed with `methods: { except: [...] }`. |
| `:filters` | Hash<String,Array<String>> | v4.4.0+ — when the agent was constructed with `filters: {...}`. Maps each filtered class name (or `"default"`) to the list of FIELD NAMES the filter constrains. Filter VALUES are intentionally NOT echoed — `filters: { Account => { user_id: "abc123" } }` would otherwise emit the user-identifying value on every audit-log line. Subscribers that need the actual constraint can call `agent.filter_for(class_name)` directly. |
| `:denial_kind` | Symbol | v4.3.0+, AccessDenied failure path only — one of `:hidden_class` (global `agent_hidden`), `:class_filter` (per-agent `classes:` narrowing), `:field_denied` (outside `agent_fields`), or `:storage_form_field_ref` (referenced `_p_*` pointer-storage column). Lets SOC tooling distinguish operator narrowing from policy-level denials without parsing the message prose. |

**Conversation correlation across multi-tool sessions.** Without correlation, individual tool-call events have no link between them — a Datadog dashboard sees "user X did query_class" and "user X did get_object" as independent points, with no way to know they belong to the same LLM turn. The dispatcher threads an optional correlation id through to every notification:

- **Header path (recommended for hosted MCP):** the client sends `Mcp-Session-Id: <opaque-id>` on every request in the conversation (the MCP 2025-06-18 Streamable HTTP spec-canonical name). `MCPRackApp` reads the header, sanitizes the value (charset `[A-Za-z0-9._-]`, max 128 chars — anything else is silently dropped to prevent log injection), and sets `agent.correlation_id` unless the factory has already supplied one. Notifications fired during that request carry the value as `payload[:correlation_id]`.

  **Server-assigned on `initialize`:** when the client omits the header on the `initialize` request, `MCPRackApp` generates a UUID, binds it to `agent.correlation_id`, and returns it in the `Mcp-Session-Id` response header. Clients echo that id on subsequent requests. A client-supplied `Mcp-Session-Id` on `initialize` is echoed back unchanged; a factory-bound `correlation_id` always wins over both. Only the `initialize` response carries the header — non-init responses don't, so the id is never leaked on every reply. The SDK does not maintain a server-side session store: the id is best-effort correlation only (audit threading + cancellation routing), and a subsequent request carrying an "unknown" id is NOT refused.

  **Session termination via `DELETE /`:** a `DELETE` carrying `Mcp-Session-Id` cancels every in-flight request registered under that correlation id and returns `204 No Content`. The header value is sanitized with the same regex as the request setter; missing or invalid values return `400`. The DELETE handler runs before the agent factory, so teardown traffic cannot force per-request agent construction.

- **Factory path (for application-bound sessions):** application code that already has an internal session identifier can override the client-supplied header by setting it inside the agent factory:

  ```ruby
  Parse::Agent.rack_app do |env|
    user  = authenticate!(env)
    agent = Parse::Agent.new(session_token: user.session_token)
    agent.correlation_id = "sess-#{user.current_session.id}"  # binds to YOUR record, not the client's header
    agent
  end
  ```

  When the factory has already set the id, `MCPRackApp` does NOT overwrite it with the header value, so the application's record wins.

- **Programmatic path (for non-Rack callers):** set `agent.correlation_id = "..."` before calling `MCPDispatcher.call(body:, agent:, ...)` directly. The notification payload picks it up the same way.

When unset (no header, no factory assignment), `payload[:correlation_id]` is omitted entirely — the key does not appear in the payload hash.

The same `Mcp-Session-Id` header is **required** for cooperative cancellation via `notifications/cancelled` — see the Cancellation section. Clients that thread the header through every request in a conversation get both correlated audit logs and cancellation; clients that don't lose both but keep every other MCP feature.

**Cancellation notification asymmetry.** A tool cancelled BEFORE it runs (via `agent.cancelled?` at the dispatcher's first checkpoint) does not fire `parse.agent.tool_call` — the tool never executed, so there is nothing to instrument. This matches how rate-limit and permission refusals are surfaced. A tool cancelled AFTER it returns (second checkpoint, "client cancelled while the tool's I/O was running") DOES fire the notification with `success: false, error_code: :cancelled`. Subscribers that count cancellations should expect the second shape; pre-run cancellations are visible to operators only via the wire response.

**Datadog / StatsD subscriber example:**

```ruby
ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |name, started, finished, _id, payload|
  duration_ms = ((finished - started) * 1000).round(2)

  tags = [
    "tool:#{payload[:tool]}",
    "permissions:#{payload[:permissions]}",
    "auth_type:#{payload[:auth_type]}",
    "success:#{payload[:success]}",
  ]

  if payload[:success]
    $statsd.histogram("parse.agent.tool.duration_ms", duration_ms, tags: tags)
    $statsd.increment("parse.agent.tool.success", tags: tags)
    if payload[:result_size]
      $statsd.histogram("parse.agent.tool.result_bytes", payload[:result_size], tags: tags)
    end
  else
    error_tags = tags + ["error_code:#{payload[:error_code]}"]
    $statsd.increment("parse.agent.tool.error", tags: error_tags)
    $statsd.histogram("parse.agent.tool.duration_ms", duration_ms, tags: error_tags)
  end
end
```

---

## Concurrency Contract

### What is thread-safe

- `Parse::Agent::MCPRackApp` is thread-safe. It holds no mutable state after construction; all per-request state lives in the agent instance created by the factory.
- `Parse::Agent::Prompts` registry uses an internal mutex. It is safe to call `Prompts.register` from any thread, but practical advice is to register all prompts at boot before serving requests.
- `Parse::Agent::Tools` registry follows the same threading model as `Prompts`.
- Per-request agent isolation: `MCPRackApp` constructs a fresh `Parse::Agent` per request via the agent factory. These agents share only the process-wide rate limiter passed as `rate_limiter:`. Per-instance state (`@conversation_history`, `@operation_log`, token counters) is scoped to a single request and discarded when it ends. This eliminates cross-request state leakage that was present when a single long-lived agent was shared.
- `Parse::Agent::CancellationToken` (`cancel!` / `cancelled?` / `reason`). `cancel!` is mutex-guarded so concurrent trips from the SSE disconnect path and a `notifications/cancelled` POST cannot lose a reason; the `cancelled?` poll path reads the boolean ivar directly (atomic on MRI).
- `Parse::Agent::MCPRackApp::CancellationRegistry`. Per-app mutex-guarded `(correlation_id, request_id) → token` store. `register` runs synchronously inside `serve_sse` BEFORE the dispatcher thread spawns, so a fast-arriving `notifications/cancelled` cannot race against an empty registry.

### What is NOT thread-safe

`Parse::Agent` itself is not safe to share across threads. The `@conversation_history`, `@operation_log`, token counters, and `@last_request`/`@last_response` attributes are not protected by a mutex. Create a new agent per request (the `MCPRackApp` factory pattern enforces this) or per thread.

If you are using the standalone `MCPServer`, it creates one agent per request internally via its own factory — you do not need to manage this yourself.

---

## Testing Your MCP Integration

The cleanest test approach is to call `MCPDispatcher.call` directly, bypassing HTTP entirely. Construct an agent with the permissions and state relevant to the scenario, pass a parsed body, and assert on the returned status and body.

```ruby
require "parse/agent/mcp_dispatcher"

# Happy path: tools/list
agent  = Parse::Agent.new(permissions: :readonly)
body   = { "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => {} }
result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent)

assert_equal 200, result[:status]
tools = result[:body]["result"]["tools"]
assert tools.any? { |t| t["name"] == "query_class" }
```

```ruby
# Unknown method -> -32601
body   = { "jsonrpc" => "2.0", "id" => 2, "method" => "no_such_method", "params" => {} }
result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent)

assert_equal 200, result[:status]
assert_equal(-32601, result[:body]["error"]["code"])
```

```ruby
# Invalid params -> -32602
body   = { "jsonrpc" => "2.0", "id" => 3, "method" => "tools/call",
           "params" => {} }   # missing "name"
result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent)

assert_equal 200, result[:status]
assert_equal(-32602, result[:body]["error"]["code"])
```

```ruby
# Test the Unauthorized path via MCPRackApp (factory-level auth test)
require "parse/agent/mcp_rack_app"

app = Parse::Agent::MCPRackApp.new do |env|
  raise Parse::Agent::Unauthorized.new("no key", reason: :missing)
end

env = {
  "REQUEST_METHOD" => "POST",
  "CONTENT_TYPE"   => "application/json",
  "rack.input"     => StringIO.new('{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}'),
}
status, _headers, body = app.call(env)

assert_equal 401, status
assert_equal(-32001, JSON.parse(body.first)["error"]["code"])
```

**Key properties of `MCPDispatcher.call`:**
- It never raises. All exceptions are caught and returned as error envelopes.
- The HTTP status in the returned hash is 200 for everything except `Unauthorized` (401). Even `-32603` internal errors return status 200.
- The dispatcher is stateless; you can call it in parallel from test threads without coordination.

**Running the MCP test suite without Docker.** The MCP transport, dispatcher, prompts, registered tools, and streaming all run without a live Parse Server:

```bash
for f in test/lib/parse/agent/mcp_{dispatcher,rack_app,integration,streaming}_test.rb \
         test/lib/parse/agent/prompts_test.rb \
         test/lib/parse/agent/tools_{registration,get_objects,collscan}_test.rb; do
  bundle exec ruby -Ilib:test "$f"
done
```

The end-to-end integration tests (`test/lib/parse/agent/mcp_server_e2e_test.rb`, `test/lib/parse/agent/tools_register_e2e_test.rb`, etc.) are gated on `PARSE_TEST_USE_DOCKER=true` and require the Docker Parse Server + MongoDB to be running.

### Testing with MCPClient (higher-level scenarios)

For tests that need a real LLM in the loop, `MCPClient` is more convenient than calling `MCPDispatcher.call` directly. Stub the agent's `execute` method to return canned data, then pass a real provider key:

```ruby
require "parse/agent/mcp_client"

# Stub agent — no Parse Server needed.
agent = Parse::Agent.new(permissions: :readonly)
agent.define_singleton_method(:execute) do |tool, **_kwargs|
  case tool
  when :count_objects then { success: true, data: { count: 42, class_name: "Song" } }
  else                     { success: false, error: "not stubbed", error_code: :internal_error }
  end
end

# Real LLM call — costs a few fractions of a cent with gpt-4o-mini.
client = Parse::Agent::MCPClient.new(
  agent:    agent,
  provider: :openai,
  api_key:  ENV["LLM_API_KEY"],
)

result = client.ask("How many songs are there?")
assert_match(/42/, result.text, "LLM should mention the count")
assert result.tool_calls.any? { |tc| tc[:name] == "count_objects" }
```

This pattern keeps test costs minimal (one LLM round-trip per assertion) while exercising the full MCPClient dispatch loop.

**Reference test files.** Eight integration test files under `test/lib/parse/agent/` cover real-LLM scenarios with live Parse Server data. Each is gated on `PARSE_TEST_USE_DOCKER=true` and a configured `LLM_PROVIDER`; they serve as reference patterns for writing your own:

| File | What it exercises |
|------|------------------|
| `mcp_real_llm_smoke_test.rb` | Wire-format regression check. Stubs `Agent#execute` with canned data; verifies the LLM receives `tools/list` correctly, picks the right tool, and can describe the result. No Docker required. |
| `mcp_real_llm_docker_integration_test.rb` | Full stack: real Parse Server, real agent, real LLM. Seeds fixture records and asks a cross-class pointer-traversal question. |
| `mcp_real_llm_schema_introspection_test.rb` | Schema discovery loop: exercises `get_all_schemas`, `get_schema`, `resources/list`, `resources/read`, and prompt rendering with a real LLM. |
| `mcp_real_llm_tiered_complexity_test.rb` | Five tiers of increasing difficulty (count, pointer query, multi-class sort, aggregation, outlier detection). Earlier tiers catch regressions cheaply; later tiers prove analytical depth. |
| `mcp_real_llm_temporal_analysis_test.rb` | Trend reasoning over ordered time-series data. Verifies the LLM fetches exam records in order and reasons about performance direction and variance. |
| `mcp_real_llm_time_query_test.rb` | Date-range filtering with Parse's `__type: "Date"` wire format. Confirms the LLM constructs correct `where:` clauses rather than raw ISO strings. |
| `mcp_real_llm_bias_detection_test.rb` | Statistical bias detection across teachers. Multi-class join + group-by reasoning to identify a grading outlier. |
| `mcp_real_llm_access_restriction_test.rb` | Access restriction surface. Verifies `agent_hidden` and `agent_fields` actually prevent PII from reaching the LLM's wire response, even when the LLM actively tries to access hidden data. |

---

## Schema Tool Filters: `get_all_schemas`

By default `get_all_schemas` returns every Parse class the agent can see, filtered through the `agent_hidden` catalog. On deployments with hundreds of classes the response can dominate the LLM's context window even though the caller only cares about a known subset.

Two additive keyword arguments (v4.2.1) narrow the response without changing the security model — both apply AFTER the `agent_hidden` filter, so passing the name of a hidden class explicitly cannot probe for its existence:

```ruby
# Pull only a known subset (exact match)
agent.execute(:get_all_schemas, names: %w[Post Project Workspace])
# => { custom: [{ name: "Post", ... }, { name: "Project", ... }, { name: "Workspace", ... }], ... }

# Pull every class whose name starts with a prefix (case-sensitive)
agent.execute(:get_all_schemas, prefix: "Post")
# => { custom: [{ name: "Post", ... }, { name: "PostRevision", ... }], ... }

# Compose as intersection
agent.execute(:get_all_schemas,
  names:  %w[Post PostRevision Project],
  prefix: "Post")
# => only Post + PostRevision (the names that ALSO match the prefix)
```

Both arguments default to nil (no filter, current behavior). An empty `names: []` array or empty `prefix: ""` string is also a no-op. Comparison is case-sensitive for exact match and prefix.

---

## Aggregation Auto-`$limit`

`aggregate` calls that do not supply their own terminal bound have a `{ "$limit" => 200 }` stage appended automatically. The cap exists for conversational safety — without it, a chatty LLM can issue a `$group` over a million-row table, stream every row back through the dispatcher, and exhaust both the response size budget and the model's context window.

**When auto-`$limit` fires.** Any pipeline whose last stage is not `$limit` or `$count`. Trailing presentational stages (`$sort`, `$project`, `$addFields`, `$unset`) do **not** count as cardinality-bounding, so a pipeline ending in `$sort` still gets the auto-limit.

**When it does not fire.** Pipelines whose terminal stage is `$limit` (caller has expressed an explicit bound) or `$count` (the result is a single scalar). Count-style analytics work unchanged:

```ruby
agent.execute(:aggregate, class_name: "Order",
  pipeline: [{ "$match" => { "status" => "paid" } }, { "$count" => "total" }]
)
# => { success: true, data: { ..., results: [{ "total" => 14_823 }] } }
# no auto_limited flag — terminal $count is a single value
```

**Response shape when limited.** The data envelope gains three extra keys, BUT only when the cap actually fired (`result_count >= AGGREGATE_DEFAULT_LIMIT`). A pipeline that lacked a terminal `$limit`/`$count` but returned fewer rows than the cap (e.g., a `$group` producing 6 buckets) does not pay the hint cost:

```ruby
{
  class_name:      "Song",
  pipeline_stages: 2,
  result_count:    200,
  results:         [...],
  auto_limited:    true,
  auto_limit:      200,
  hint:            "Pipeline auto-bounded with $limit:200 (no terminal $limit/$count supplied). " \
                   "Add an explicit { \"$limit\": N } stage at the end of your pipeline to control the cap, " \
                   "or call count_objects first to size the result before fetching rows."
}
```

The hint is intentionally instructive: a well-prompted LLM will read it and either add an explicit `$limit` matching the user's intent or call `count_objects` to size the request before re-running.

For exports beyond 200 rows, route through the `export_data` tool (see next section), which has its own row cap (`DEFAULT_EXPORT_ROW_CAP = 1_000`, raisable to `MAX_EXPORT_ROW_CAP = 10_000`) and returns a single formatted blob rather than a row array.

### Pointer compaction (`compact_pointers:`)

Aggregate results expose Parse pointer fields in their Parse-on-Mongo storage form: `_p_<field>: "<ClassName>$<objectId>"`. On a high-cardinality query that returns 130 rows of `_p_author: "_User$..."`, the repeated `_User$` prefix and the `_p_` column-name prefix together account for ~800 bytes of waste per call.

**Default-on compaction.** Every `aggregate` response is run through a compaction pass that rewrites `_p_<field>` keys to `<field>` and strips the `<ClassName>$` prefix from each value. The envelope picks up a top-level `pointer_classes:` map preserving the class information:

```ruby
agent.execute(:aggregate, class_name: "Post",
  pipeline: [{ "$match" => { "archived" => { "$ne" => true } } }, { "$project" => { "_p_author" => 1 } }]
)
# => {
#   class_name:       "Post",
#   result_count:     3,
#   results: [
#     { "objectId" => "row1", "author" => "alice1" },
#     { "objectId" => "row2", "author" => "bob222" },
#     { "objectId" => "row3", "author" => "carol3" },
#   ],
#   pointer_classes: { "author" => "_User" },
# }
```

**Safety rules.** Columns where the className varies row-to-row (anomalous), and columns where both `_p_<field>` and `<field>` already coexist in the same row, are LEFT UNCOMPRESSED. The pass also runs AFTER the hidden-class redaction walker, so `_p_*` strings referencing an `agent_hidden` class are scrubbed before compaction sees them.

**Opting out.** Pass `compact_pointers: false` to receive raw Parse-on-Mongo shapes. Consumers that parse `<ClassName>$<objectId>` strings directly should either set the flag to `false` or migrate to consuming the bare objectId and the `pointer_classes` envelope map.

```ruby
agent.execute(:aggregate, class_name: "Post",
  pipeline: [...],
  compact_pointers: false)
# Response keys back to raw _p_author: "_User$alice1" form; no pointer_classes
```

### Forward-pass field tracking on `agent_fields` (v4.4.3+)

The pipeline access-policy walker that enforces a class's `agent_fields` allowlist on projection-shape stages (`$project`, `$addFields`, `$set`, `$unset`, `$replaceRoot`, `$replaceWith`) now runs as a **forward pass** instead of a per-stage check against the source-class allowlist only. Each stage is validated against the effective set `(source_permitted ∪ available_so_far)`, where `available_so_far` accumulates fields introduced by upstream stages — `$group._id` and accumulator keys, `$addFields`/`$set` outputs, `$lookup.as`, `$bucket.output`, etc.

Schema-replacing stages (`$project`, `$group`, `$bucket`, `$bucketAuto`, `$replaceRoot`, `$replaceWith`, `$facet`, `$sortByCount`, `$count`) drop the source set; downstream stages can only reference the newly-introduced fields. This unblocks the canonical "group → filter → sort → limit" pattern that previously failed because synthetic accumulator outputs (`contributor_count`, `total_sum`) were checked against the source class's `agent_fields` allowlist and refused as `:field_denied`.

```ruby
# Post has agent_fields :only, [:objectId, :_p_author, :status]
# total_sum is NOT in agent_fields — but it's introduced by $group, so the
# downstream $match/$sort can reference it without a denial.
agent.execute(:aggregate, class_name: "Post", pipeline: [
  { "$group" => { "_id" => "$status",
                  "total_sum" => { "$sum" => "$amount" } } },
  { "$match" => { "total_sum" => { "$gt" => 100 } } },
  { "$sort"  => { "total_sum" => -1 } },
  { "$limit" => 10 },
])
```

The `:field_denied` refusal still fires when a stage tries to read a source-class field that isn't on the allowlist AND hasn't been introduced upstream. `$facet` sub-pipelines spawn their own forward-passes with the right starting state, so each facet branch enforces the allowlist independently from the position it diverged.

---

## High-Level Aggregation Helpers: `group_by` / `group_by_date` / `distinct` (v4.2.1)

Three category-`aggregate` tools that wrap the most common `$group` pipelines so an LLM doesn't have to author the MongoDB shape by hand. Each tool resolves pointer fields, formats the result keys, pushes sort+limit into the wire pipeline, and supports a `dry_run` mode for inspection.

All three are `:readonly` and inherit the same access-control gates as `aggregate`: `agent_hidden` class refusal, `agent_fields` allowlist enforcement on `field:` / `value_field:` / `where:` keys, tenant scope injection, COLLSCAN preflight on the leading `$match`, and hidden-class redaction on the response.

### `group_by`

Group records by a field and apply an aggregation:

```ruby
agent.execute(:group_by, class_name: "Post", field: "lastAction",
              operation: "count")
# => { success: true, data: {
#   class_name: "Post", field: "lastAction", operation: "count",
#   group_count: 4, limit: 200,
#   groups: [
#     { key: "submitted", value: 142 },
#     { key: "approved",  value:  88 },
#     { key: "rejected",  value:  12 },
#     { key: "draft",     value:   5 },
#   ]
# } }
```

**Operations.** `count` (default, no `value_field` needed), `sum`, `avg` / `average`, `min`, `max`. Non-`count` operations require `value_field:`.

**Pointer auto-detection.** When the local Parse model declares the field as `:pointer`, the handler emits `$_p_<field>` in the pipeline and strips the `<ClassName>$` prefix from the response keys, surfacing the class once in `pointer_class:`:

```ruby
agent.execute(:group_by, class_name: "Post", field: "author")
# => { ..., pointer_class: "_User",
#     groups: [{ key: "abc123", value: 47 }, { key: "def456", value: 31 }, ...] }
```

Call `get_objects(class_name: "_User", ids: ["abc123", "def456"])` to resolve the keys.

**Array flattening.** Pass `flatten_arrays: true` to `$unwind` the field before grouping so individual array elements are counted:

```ruby
agent.execute(:group_by, class_name: "Post", field: "tags", flatten_arrays: true)
# Each tag is counted once per row containing it.
```

**Top-K with wire-side sort+limit.** Pass `sort:` (`value_desc` / `value_asc` / `key_desc` / `key_asc`) and `limit:` and the handler appends `$sort` + `$limit` to the pipeline so MongoDB does the truncation — the bandwidth saving matters on high-cardinality fields:

```ruby
agent.execute(:group_by, class_name: "Order", field: "customerId",
              operation: "sum", value_field: "totalCents",
              sort: "value_desc", limit: 10)
# Top 10 spenders, sorted server-side, capped at 10 rows over the wire.
```

`limit:` defaults to 200, max 1000. The wire pipeline uses `limit + 1` so the handler can detect server-side truncation and set `truncated: true` on the envelope.

### `group_by_date`

Bucket records by a date field at an interval and aggregate. Same operation set as `group_by`, plus `interval:` and `timezone:`:

```ruby
agent.execute(:group_by_date, class_name: "Post",
              field: "createdAt", interval: "day",
              timezone: "America/New_York")
# => { success: true, data: {
#   class_name: "Post", field: "createdAt", interval: "day",
#   operation: "count", timezone: "America/New_York", sort: "key_asc",
#   groups: [
#     { key: "2024-11-24", value:  47 },
#     { key: "2024-11-25", value:  62 },
#     { key: "2024-11-26", value: 118 },
#   ]
# } }
```

**Interval enum.** `year`, `month`, `week`, `day`, `hour`, `minute`, `second`. The handler builds the correct combination of `$year` / `$month` / `$week` / `$dayOfMonth` / `$hour` / `$minute` / `$second` operators internally — the LLM doesn't have to know MongoDB's date-expression vocabulary.

**Key formatting.** Output keys are pre-formatted ISO strings — `"YYYY"`, `"YYYY-MM"`, `"YYYY-Www"`, `"YYYY-MM-DD"`, `"YYYY-MM-DD HH:00"`, etc. — rather than `{year:, month:, day:}` objects.

**Timezone.** Optional IANA name (`"America/New_York"`) or fixed offset (`"+05:00"`). When supplied, each date operator is wrapped in the `{date:, timezone:}` form Mongo expects. Default is UTC.

**Default sort.** `key_asc` (chronological). Override with `sort:` if you want value-based ordering.

### `distinct`

Return the distinct values of a field, optionally filtered:

```ruby
agent.execute(:distinct, class_name: "Document", field: "mediaFormat",
              where: { "archived" => { "$ne" => true } })
# => { success: true, data: {
#   class_name: "Document", field: "mediaFormat",
#   count: 3, values: ["video", "image", "audio"]
# } }
```

**Pointer fields.** When the field is a pointer, the values come back stripped of the `<ClassName>$` prefix and `pointer_class:` carries the class:

```ruby
agent.execute(:distinct, class_name: "Document", field: "authorWorkspace")
# => { ..., pointer_class: "Workspace",
#     values: ["alphaTeam", "betaTeam", "gammaTeam"] }
```

**Sort.** `asc` or `desc` (alphabetic/numeric on the values). Wire-side `$sort {_id: 1|-1}` is emitted; the response is in the database-sorted order.

**Limit.** Defaults to 1000, max 5000 (distinct results legitimately span more values than grouped counts).

### `dry_run: true` — inspect the pipeline without executing

All three tools accept `dry_run: true`, which returns the constructed MongoDB pipeline plus the resolved parameters and skips the actual aggregate call. Useful for:

- Inspecting how the tool resolved a pointer field (was the `_p_` prefix added?), a date interval, or a timezone before paying the round-trip.
- Composing multi-step analyses where `group_by` is one stage of a larger pipeline you intend to assemble and run via `aggregate`.
- Letting a power-user LLM mutate the pipeline (add a `$lookup`, change the `$sort`) before re-issuing through `aggregate`.

```ruby
agent.execute(:group_by, class_name: "Post", field: "author",
              operation: "sum", value_field: "elapsedMs",
              sort: "value_desc", limit: 10, dry_run: true)
# => { success: true, data: {
#   dry_run: true,
#   class_name: "Post",
#   parameters: { field: "author", operation: "sum", value_field: "elapsedMs",
#                 sort: "value_desc", limit: 10 },
#   pipeline: [
#     { "$group" => { "_id" => "$_p_author", "value" => { "$sum" => "$elapsedMs" } } },
#     { "$sort"  => { "value" => -1 } },
#     { "$limit" => 11 }
#   ],
#   hint: "dry_run mode — the pipeline above was constructed but NOT executed. " \
#         "Re-issue this call with dry_run: false to run it, or pass the pipeline " \
#         "to the aggregate tool (modified as needed) for full pipeline control."
# } }
```

**Security gates still apply.** `agent_hidden`, `agent_fields` allowlist enforcement, field-shape validation, tenant scope, and operation enum validation all run BEFORE the dry-run short-circuit. `dry_run` is a no-execute mode, not an authorization bypass — a request that would have been refused returns the same refusal envelope.

### Why these wrap `aggregate` instead of being the same tool

The `aggregate` tool stays general-purpose and accepts any (validated) MongoDB pipeline. These three are higher-leverage:

- **Naming reduces planning steps.** An LLM that sees `group_by` and `distinct` in `tools/list` doesn't have to derive the pipeline shape from "I need a count grouped by status."
- **Hidden behaviors are encoded once.** Pointer `_p_` prefix detection, date-bucket expression construction, ISO date-key formatting, top-K wire-pipeline assembly — every one of those is a common failure mode if the LLM hand-authors the equivalent `aggregate` call.
- **Top-K is correct by default.** `aggregate`'s auto-`$limit` truncates BEFORE sort if the LLM forgets the terminal `$sort` + `$limit` ordering. These tools place the bound after the accumulator, so `sort: "value_desc", limit: 10` is always a real top-10 query.

Use `aggregate` when you need `$lookup`, `$facet`, `$bucket`, multi-stage transformations, or anything else outside the group/distinct envelope. Use these helpers for the 80% case.

---

## `export_data` — CSV / Markdown / Text Table Export

`export_data` produces a single formatted text blob (CSV, GitHub-flavored Markdown table, or fixed-width ASCII table) from either a `query_class`-style read or an `aggregate`-style pipeline. It exists so that an LLM can hand the user a copy-pasteable artifact (e.g., "give me a CSV of all sophomores enrolled in Algebra II") without that data being streamed row-by-row into the model's context window — the formatted output ships back in a single tool result and is bounded by `MAX_TOOL_RESPONSE_BYTES` (4 MiB) at the dispatcher.

The tool is included in the `:readonly` permission set.

### When to use `query_class(format:)` instead

For the common case — a CSV/Markdown/text-table dump of a simple class query with no column aliasing — `query_class` accepts a `format:` keyword argument (v4.2.1) that produces the same envelope without requiring a separate tool:

```ruby
agent.execute(:query_class, class_name: "Song",
  where:  { artist: "Radiohead" },
  limit:  50,
  format: "csv")
# => { success: true, data: {
#   class_name: "Song",
#   format:     "csv",
#   headers:    ["objectId", "title", "artist", "plays"],
#   row_count:  50,
#   output:     "objectId,title,artist,plays\nabc,...\n..."
# } }
```

`format:` accepts `"json"` (default — the structured row envelope), `"csv"`, `"markdown"`, or `"table"`. Columns are inferred from the first row's keys (Parse-internal envelope keys skipped). The non-json paths use the same formatters as `export_data` but skip column aliasing, dotted-path extraction, and custom row caps.

Reach for `export_data` (instead of `query_class(format:)`) when you need:

- **Column aliasing** — `columns: [{ "subject.name" => "Subject Name" }]` to rename or extract nested values.
- **Aggregate-mode formatting** — passing a `pipeline:` instead of `where:` / `keys:`.
- **A larger row cap** — `query_class` is bounded by the standard `MAX_LIMIT = 1000`; `export_data` honors `row_cap:` up to `MAX_EXPORT_ROW_CAP = 10000`.

Both paths return the same `{class_name:, format:, headers:, row_count:, output:}` envelope shape.

### Modes

| Mode | Triggered by | Underlying call | Inherited gates |
|------|--------------|------------------|------------------|
| Query | `where:`, `keys:`, `include:`, `order:`, `limit:`, `skip:` (no `pipeline:`) | `client.find_objects` | `agent_hidden`, `agent_fields` allowlist intersection, include-path resolver, post-fetch redactor |
| Aggregate | `pipeline:` supplied | `client.aggregate_pipeline` | pipeline access policy walker (`$lookup` into hidden classes, field-level allowlist on `$project` / `$addFields`), post-fetch redactor |

When `pipeline:` is supplied, the query-mode args (`where:`, `keys:`, `include:`, `order:`, `limit:`, `skip:`) are ignored — pipeline mode takes priority.

Every access-control gate that protects `query_class` and `aggregate` also protects the corresponding `export_data` path — there is no `export_data`-specific bypass. Aggregate-mode exports run through the same `ensure_aggregate_terminal_limit` injection as `aggregate`, but the export-side row cap takes precedence.

### Output formats

`format:` accepts `"csv"` (default), `"markdown"`, or `"table"`. Any other value is rejected with `error_code: :invalid_argument`.

```ruby
agent.execute(:export_data, class_name: "Student", limit: 50)
# => { success: true, data: { format: "csv", row_count: 50, output: "name,grade,...\nAda,11,...\n..." } }

agent.execute(:export_data, class_name: "Student", limit: 50, format: "markdown")
# | name  | grade |
# | ---   | ---   |
# | Ada   | 11    |

agent.execute(:export_data, class_name: "Student", limit: 50, format: "table")
# +------+-------+
# | name | grade |
# +------+-------+
# | Ada  | 11    |
# +------+-------+
```

### Columns and aliasing

`columns:` is an ordered array of specs. Each spec is either a String (used as both field path and header) or a single-key Hash `{field => header}` for aliasing. Dotted paths walk into include-resolved pointer fields. When `columns:` is nil, headers are inferred from the first row's keys with Parse-internal fields (`__type`, `className`, `ACL`) excluded.

```ruby
agent.execute(:export_data,
  class_name: "Student",
  include:    ["subject"],
  columns:    [
    "name",                              # field=name,         header="name"
    { "grade" => "Year" },               # field=grade,        header="Year"
    { "subject.name" => "Subject" }      # field=subject.name, header="Subject"
  ],
  format: "csv"
)
```

Validation: each Hash must have exactly one key; any other value (including bare integers or multi-key hashes) is rejected with `:invalid_argument`.

### Row cap

| Knob | Value | Purpose |
|------|-------|---------|
| `DEFAULT_EXPORT_ROW_CAP` | `1_000` | Default when `row_cap:` is omitted. Sized so a 10-15 column CSV stays under ~80 KB / ~20k tokens. |
| `MAX_EXPORT_ROW_CAP`     | `10_000` | Hard ceiling regardless of `row_cap:` override. The dispatcher's 4 MiB response cap may still trim a wide-schema export below this. |

When the fetched result exceeds the effective cap, the tool emits the first `effective_cap` rows and sets `data[:truncated] = true`, `data[:available_rows]`, `data[:row_cap]`, and an instructional `data[:hint]` telling the caller to narrow with `where:` / `pipeline` filters or set `row_cap:` explicitly. `data[:row_count]` reflects what was actually emitted, not the upstream cardinality.

For artifacts larger than `MAX_EXPORT_ROW_CAP`, run the operator-side `rake "mcp:tool[export_data,...]"` task, which inherits no LLM context budget, or query the database directly from application code.

---

## Aggregation Results: `.raw` vs `.results`

When using the `aggregate` tool with a `$group` pipeline stage, the rows returned by MongoDB are not full Parse objects — they have no `_created_at` or `_updated_at` fields. v4.1.0 fixes `Aggregation#results` to distinguish these cases by checking for those timestamp fields on each raw document.

- **`.results`** on a `$group` pipeline: returns an array of `Parse::AggregationResult` objects (not `Parse::Object`). These are value objects with hash-like field access. They do not have `objectId`, `createdAt`, or `updatedAt`.
- **`.results`** on a pipeline that preserves full Parse documents (e.g., `$match` only): returns typed `Parse::Object` instances.
- **`.raw`**: returns the raw array of hashes from the aggregation response. Always works regardless of pipeline shape; prefer this in custom tool handlers when you need simple hash access.

Custom tool handlers that aggregate with `$group` should prefer `.raw` for straightforward hash access, or use `.results` with the awareness that the objects are `Parse::AggregationResult`, not `Parse::Object`, and therefore lack standard Parse object methods.

**`Parse::AggregationResult` interface.** Value object returned for non-document aggregation rows. Reading the source isn't required — the contract is small:

```ruby
row = result[:data][:results].first
# Original field names (string keys) — works for any pipeline output.
row["_id"]            # the $group key value
row["count"]
# Snake-cased symbol access — useful when the pipeline produces camelCase field names.
row[:total_plays]     # if the projection was { "totalPlays" => ... }
# Method-style access via method_missing — same snake-cased keys.
row.total_plays
# Convenience.
row.to_h              # Hash of snake-cased symbol keys to values
row.raw               # Hash of original keys as returned by MongoDB
```

What it does **not** have: `objectId`, `createdAt`, `updatedAt`, `save`, `destroy`, `acl`, or any Parse persistence methods. Treating one as a `Parse::Object` will raise `NoMethodError`. If a handler needs to differentiate at runtime, check `is_a?(Parse::AggregationResult)`.

```ruby
# In a custom tool handler:
result = agent.execute(:aggregate,
  class_name: "Song",
  pipeline: [
    { "$group" => { "_id" => "$genre", "count" => { "$sum" => 1 } } },
    { "$sort"  => { "count" => -1 } },
  ]
)

if result[:success]
  rows = result[:data][:results]   # Array of hashes: [{"_id"=>"Rock","count"=>4200}, ...]
  rows.each { |row| puts "#{row["_id"]}: #{row["count"]}" }
end
```

---

## Security Notes

**Static-token comparisons must use secure compare.** String equality (`==`) is vulnerable to timing attacks. Use `ActiveSupport::SecurityUtils.secure_compare` for any comparison of secrets:

```ruby
unless ActiveSupport::SecurityUtils.secure_compare(ENV["EXPECTED_KEY"], provided_key)
  raise Parse::Agent::Unauthorized.new("bad key", reason: :bad_api_key)
end
```

**Only `Parse::Agent::Unauthorized` should escape the agent factory.** Any other exception from the factory becomes a 500 response with `"Internal error"` as the wire message. Rescue and re-raise all anticipated failures as `Unauthorized`. Do not let exception messages from third-party libraries reach the caller — they may contain user data or internal stack details.

**The dispatcher sanitizes internal errors.** `MCPDispatcher` rescues `StandardError` and returns a `-32603` envelope containing the literal string `"Internal error"` — no class name, no message, no backtrace. The exception class and message are emitted to the operator's logger (or `$stderr`). This applies to handler-level errors; factory-level errors are handled by `MCPRackApp` before the dispatcher is called.

**`:admin` permissions over HTTP.** `:admin` enables `delete_object`, `create_class`, and `delete_class`. Do not grant `:admin` from an HTTP-exposed factory without explicit intent. Treat it as equivalent to granting master-key access to any bearer of a valid token.

**Body size and nesting limits.** `MCPRackApp` rejects bodies larger than 1 MB and JSON with nesting depth greater than 20. The size limit can be adjusted with `max_body_size:`:

```ruby
Parse::Agent.rack_app(max_body_size: 512_000) { |env| ... }
```

**Content-Length and Transfer-Encoding enforcement (MCPServer).** The standalone `MCPServer` rejects requests with `Transfer-Encoding: chunked` (411 Length Required), requests with a missing `Content-Length` header (411), and requests where `Content-Length` exceeds the body size limit (413). These checks run before the body is read, preventing WEBrick from dechunking an unbounded stream.

**Resource URIs are validated.** `resources/read` validates the URI against `parse://<ClassName>/<kind>` before calling any tool. Class names must match Parse's identifier pattern (`[A-Za-z_][A-Za-z0-9_]*`). This prevents injection of arbitrary class names through the resource layer.

**The `logger:` kwarg on `MCPRackApp`.** When a logger is provided, auth failures are logged with the exception class name only (not the message or the `reason` attribute). Factory errors (non-Unauthorized) are logged with class name and full backtrace. Production deployments should pass a logger so failures are observable without exposing internals to clients:

```ruby
Parse::Agent.rack_app(logger: Rails.logger) { |env| ... }
```

**Sub-agent auth-scope inheritance and permissions clamp (v4.2).** When a tool handler constructs a sub-agent with `Parse::Agent.new(parent: agent, ...)`, the sub inherits `session_token` and `tenant_id` from the parent unless explicitly overridden. Without this inheritance, a session-token parent would silently produce a master-key sub-agent — the constructor default `session_token: nil` resolves to master-key mode — escalating privilege through the very kwarg meant to close sub-agent footguns. Explicit overrides still work (`Parse::Agent.new(parent: agent, session_token: nil)` produces a master-key sub if that is genuinely what the handler wants), but the default is fail-safe inheritance. `permissions:` is NOT inherited and defaults to `:readonly`, but the constructor enforces a clamp: an explicit `permissions:` override on a sub-agent is accepted only if `≤ parent.permissions`, otherwise `ArgumentError` is raised at construction. The clamp is the structural guarantee that a delegation chain cannot escape the parent's tier through sub-agent construction. See [Per-Agent Tool Filtering & Sub-Agent Delegation](#per-agent-tool-filtering--sub-agent-delegation-v42) for the full inheritance table.

**Agent-level ACL scope: `session_token:` / `acl_user:` / `acl_role:` (v4.4.0).** `Parse::Agent.new` accepts three mutually-exclusive identity inputs. `session_token:` round-trips Parse Server's `/users/me` at construction (or defers to per-call REST if the server is unreachable). `acl_user:` takes a `Parse::User` or User-pointer and expands the user's role subscription via `Parse::Role.all_for_user` — no token round-trip, the SDK enforces the resulting `_rperm` filter itself. `acl_role:` is service-account-style scoping — no user_id, just the role plus parent-role inheritance. Master-key posture (none of the three supplied) remains the default and still emits the one-time `[Parse::Agent:SECURITY]` banner at construction. Every built-in tool reads `agent.acl_scope_kwargs` (single point of truth) to forward identity into `Parse::MongoDB.aggregate`, `Parse::Query#results_direct`, and `Parse::AtlasSearch.{search,autocomplete}`. Developer-registered tool handlers and `agent_method` bodies can reach `agent.acl_scope`, `agent.acl_permission_strings`, `agent.acl_read_match_stage` (a `_rperm` `$match`), or `agent.acl_write_match_stage` (a `_wperm` `$match`) to apply the agent's identity to their own queries.

**ACL composition on the mongo-direct aggregate path (v4.4.0).** When `aggregate` routes through `Parse::MongoDB.aggregate` (the default when `Parse::MongoDB.enabled?` is true), the agent layer derives the auth posture from the agent instance and forwards it to ACLScope — session-tokened / acl_user / acl_role agents get the same row-level `_rperm` `$match` injection regardless of identity mode; master-key agents pass `master: true` (the agent's class/field/tenant/canonical-filter gates are the security boundary for that posture). The posture is built in `Parse::Agent#acl_scope_kwargs`, not from tool-call JSON arguments; LLM-supplied `master:`, `session_token:`, `acl_user:`, or `acl_role:` kwargs are silently swallowed by the tool signature's `**_kwargs` catchall and never reach `Parse::MongoDB.aggregate`. An LLM cannot escalate from a scoped posture to master-key by injecting `master: true` into the tool arguments.

**REST aggregate is master-key-only — auto-promoted to mongo-direct for any scoped agent (v4.4.0).** Parse Server's REST `/aggregate` endpoint does NOT enforce ACL or CLP — it runs master-key-only. The agent's `aggregate` tool therefore auto-promotes `mongo_direct: false` to `mongo_direct: true` whenever the agent carries any scope (session_token / acl_user / acl_role); only the SDK's mongo-direct path applies the `_rperm` `$match` injection via ACLScope and the CLP gates via CLPScope. Master-key agents keep the REST route because they've already opted out of ACL enforcement at construction. `group_by` / `group_by_date` / `distinct` / `export_data` follow the same auto-promotion rule because they all flow through `Parse::MongoDB.aggregate` on the direct path.

**REST find / get / count still go through Parse Server (mostly) (v4.4.0).** Parse Server's REST `/classes/<Class>` and `/classes/<Class>/<id>` endpoints DO enforce CLP and ACL natively when a session_token is forwarded. So `query_class`, `get_object`, `get_objects`, `get_sample_objects`, and `count_objects` keep the REST path for session_token / master-key agents. The auto-route to `Parse::Query#results_direct` (mongo-direct) fires ONLY under `acl_user:` / `acl_role:` scope — REST has no "act as user-pointer" or "act as role" affordance, so REST cannot honor those scopes at all. `Parse::Agent#request_opts` raises `Parse::ACLScope::ACLRequired` for those scopes as a fail-closed defense against any tool that bypasses the auto-route.

**Class-Level Permissions and Protected Fields on mongo-direct (v4.4.0).** Because Parse Server's REST aggregate runs master-key-only, the SDK is the only enforcement layer for CLP / `protectedFields` on the mongo-direct path. `Parse::CLPScope` mirrors `Parse::ACLScope`'s architecture: scope-aware module with cached `_SCHEMA` lookups (`cache_ttl = 3600` default, `Parse::CLPScope.invalidate!(class_name)` for explicit busting), `permits?` boundary check per operation, post-fetch `pointerFields` row-filtering, and `protectedFields` strip walker. `Parse::MongoDB.aggregate` runs both layers automatically. The agent layer's `assert_class_accessible!` accepts an `op:` kwarg (`:find` / `:count` / `:get` / `:create` / `:update` / `:delete`) so every built-in tool refuses CLP-denied operations at the boundary BEFORE pipeline construction. `call_method` maps the target method's permission tier to a CLP op (`:readonly` → `:find`, `:write` → `:update`, `:admin` → `:delete`) and refuses if the class's CLP doesn't grant that op to the agent's scope. `$lookup` / `$graphLookup` / `$unionWith` targets are also CLP-gated through the existing pipeline access policy. The Parse Server REST route (`mongo_direct: false`, session_token agents on find/get/count) continues to enforce CLP through Parse Server itself, unchanged.

**Atlas Search per-tool refusal relaxed (v4.4.0).** `atlas_text_search` and `atlas_autocomplete` no longer require `session_token:` or `master_atlas: true` at the per-tool boundary. The SDK now enforces per-row ACL on these calls via `Parse::ACLScope`'s `_rperm` `$match` regardless of identity mode (session_token / acl_user / acl_role / master-key), so the operator's master-key construction is sufficient signal — the master-key banner at construction is the security-posture indicator. `atlas_faceted_search` retains its `master_atlas: true` requirement because `$searchMeta` bucket counts cannot be ACL-filtered at the `_rperm` level.

The corollary: a session-tokened or `acl_user`-scoped agent calling `aggregate` will see only rows whose `_rperm` permits the requesting user (including roles inherited via `Parse::Role.all_for_user`); `acl_role` agents see rows readable by the role + its parent roles. `protectedFields` defined in the class's CLP are stripped from every returned row and every embedded `$lookup`-included sub-document. Pre-4.4.0, mongo-direct aggregate ran with admin Mongo credentials and no SDK-side enforcement — a real CLP/ACL gap that this release closes.

---

## Client Mode — Session-Token-Only Agents (v5.0)

`Parse::Agent` automatically enters *client mode* when its underlying `Parse::Client` carries **no `master_key`** AND the constructor was given a **non-empty `session_token:`**. Client mode is a *posture*, not a separate class — the same `Parse::Agent` instance answers `agent.client_mode? => true` and applies a tighter dispatch ceiling to itself. The two complementary postures:

| Posture       | `master_key` configured? | `session_token:` supplied? | Dispatch surface | ACL/CLP enforced by |
|---------------|:------------------------:|:--------------------------:|------------------|---------------------|
| **client mode** | no                     | yes (required)             | session-token REST allowlist | Parse Server (native) |
| **master-key** | yes                     | optional (scopes if set)   | full tool catalog | SDK (`ACLScope` + `CLPScope` on mongo-direct) |

A `Parse::Client` with no `master_key` AND no `session_token:` is **not** client mode — it is the legacy no-master construction that still emits the `[Parse::Agent:SECURITY]` banner. It's preserved for back-compat with test harnesses that drive the SDK without auth.

### Detection and surface ceiling

```ruby
Parse.setup(server_url: "...", application_id: "...", api_key: "...")  # no master_key
agent = Parse::Agent.new(session_token: user.session_token)

agent.client_mode?      # => true
agent.allow_mutations?  # => false (default in client mode)
```

The client-mode dispatch ceiling is a small allowlist; every other built-in tool is refused at the boundary:

- **Read tools (always allowed):** `list_tools`, `get_object`, `get_objects`, `query_class`, `count_objects`, `get_sample_objects`
- **Mutation tools (gated by `allow_mutations:`):** `create_object`, `update_object`, `delete_object`
- **Refused at the ceiling:** `aggregate`, `atlas_text_search`, `atlas_autocomplete`, `atlas_faceted_search`, `find_similar`, `group_by`, `group_by_date`, `distinct`, `explain_query`, `export_data`, `get_all_schemas`, `get_schema`, `create_class`, `delete_class`, `call_method`, and every registered custom tool whose `register(...)` call did not pass `client_safe: true`.

The refused tools all require either the application master key (REST `/aggregate`, `/schemas`) or a direct MongoDB connection (atlas-search, mongo-direct queries) — neither of which a client-mode agent has. Refusing at the dispatch ceiling rather than at first REST call gives the LLM an immediate `:access_denied` error envelope it can recover from, instead of a 403 from Parse Server somewhere downstream.

### `allow_mutations:` — per-agent write gate

```ruby
# Default: client-mode agents are read-only
reader = Parse::Agent.new(session_token: user.session_token)
reader.execute(:create_object, class_name: "Post", fields: { title: "x" })
# => { success: false, error_code: :access_denied,
#      error: "Raw mutation tool 'create_object' is disabled. Pass allow_mutations: true to enable." }

# Opt in per agent
writer = Parse::Agent.new(session_token: user.session_token, allow_mutations: true)
writer.execute(:create_object, class_name: "Post", fields: { title: "x" })  # → posts to /classes/Post with the session token
```

The gate AND-composes with the existing `PARSE_AGENT_ALLOW_WRITE_TOOLS` and `PARSE_AGENT_ALLOW_RAW_CRUD` env vars — both env vars and `allow_mutations: true` must agree before `create_object` / `update_object` / `delete_object` dispatch. In master-key mode `allow_mutations:` defaults to `true` so existing master-key agents continue to use the env vars alone (back-compat). Explicit `allow_mutations: false` on a master-key agent disables raw CRUD for that agent even when the env vars are set.

### `acl_user:` / `acl_role:` are refused on no-master clients

```ruby
Parse::Agent.new(acl_user: some_user_pointer)
# => ArgumentError: acl_user:/acl_role: require a Parse::Client with a master_key
#    configured. The current client has no master_key. Use session_token: to bind
#    a per-user identity instead, or configure a master-key client for scoped
#    aggregations.
```

Both `acl_user:` and `acl_role:` are SDK-side constructor assertions — the SDK *asserts* "act as this user" or "act as this role" and then enforces the resulting `_rperm` filter itself, on a mongo-direct query path. Without a master key the SDK cannot reach that path, and Parse Server's REST surface has no "act as user-pointer" or "act as role" affordance, so honoring them would silently downgrade to anonymous. The constructor fails fast and points the caller at `session_token:` (the only verified identity model available to a no-master client).

### `client_safe:` — eligibility flag for custom tools

```ruby
Parse::Agent::Tools.register(
  name:        :my_read_helper,
  description: "Compute something from session-scoped data",
  parameters:  { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
  permission:  :readonly,
  client_safe: true,  # opt-in; default is false (master-key only)
  handler:     ->(args, agent:) {
    # IMPORTANT: thread agent.request_opts (NOT just session_token:) so the
    # request also carries use_master_key: false. In a deployment where the
    # process-default Parse::Client carries a master key, omitting
    # use_master_key: false here would silently escalate to master-key
    # posture and bypass Parse Server's session-token authorization.
    agent.client.fetch_object("MyClass", args[:id], **agent.request_opts)
  },
)
```

Custom tools default to master-key-only — a registered tool is refused at the client-mode dispatch ceiling unless its author explicitly declared `client_safe: true`. The flag is an eligibility assertion from the tool author: *"this handler does not touch the master key, does not call mongo-direct aggregates, and is safe for a session-token-only agent."* The companion predicate `Parse::Agent::Tools.client_safe?(name)` reports the resolved eligibility of any built-in or registered tool.

**Canonical handler pattern: `**agent.request_opts`.** Always splat `agent.request_opts` into the underlying `Parse::Client` call rather than threading `session_token: agent.session_token` alone. `request_opts` sets both `session_token:` and `use_master_key: false` (and raises `Parse::ACLScope::ACLRequired` for scoped postures that REST cannot honor). The `session_token:`-alone pattern works only when the process has no master key configured anywhere — the safer pattern works in every deployment.

### Sub-agent inheritance

```ruby
parent = Parse::Agent.new(session_token: user.session_token, allow_mutations: true)
child  = Parse::Agent.new(parent: parent)
child.client_mode?       # => true  (inherits the parent's client + session_token)
child.allow_mutations?   # => true  (inherits the parent's gate)

narrower = Parse::Agent.new(parent: parent, allow_mutations: false)
narrower.allow_mutations?  # => false (sub may narrow)

Parse::Agent.new(parent: reader_without_mutations, allow_mutations: true)
# => ArgumentError: sub-agent cannot widen parent's allow_mutations gate
```

The `allow_mutations:` gate composes with the existing sub-agent subset rules (`permissions:` clamp, `tools:` narrowing, `classes:` allowlist intersection) — a sub-agent may narrow but never widen, including the mutation gate.

### Refusal message shape (operator-distinguishable)

Four different refusal reasons each produce a distinct `:error_code` and message shape so SOC tooling can branch on them without parsing prose. Messages below are paraphrased for table width — the actual messages in `lib/parse/agent.rb` are longer; the column shows the opening clause and key tokens.

| Refusal | Opening clause / key token | `:error_code` | Carries class name? |
|---------|-----------------------------|---------------|----------------------|
| Operator `tools:` filter | `"Tool 'X' is not enabled for this agent instance (excluded by the configured tools: filter)."` | `:tool_filtered` | No |
| Mutation gate | `"Raw mutation tool 'create_object' is disabled for this client-mode agent. Construct the agent with allow_mutations: true …"` | `:access_denied` | No |
| Mode ceiling | `"Tool 'aggregate' is not available to client-mode agents. …"` | `:access_denied` | No |
| `agent_hidden` class | `"Class 'StudentSSN' is not accessible to this agent"` | `:access_denied` | Yes (the class name in the request) |

**Resolution order at dispatch:** operator filter ▷ mutation gate ▷ mode ceiling ▷ in-tool class gate. Operator-filter precedence is deliberate — when a tool is excluded by both the operator's `tools: { except: [...] }` AND the mutation gate (or the mode ceiling), the operator-filter message wins so the operator looks at the right knob first. The mode-ceiling message names the tool, not the class — even when the request would have hit an `agent_hidden` class, the ceiling fires first for a refused tool, so the LLM does not learn anything about the class. For tools that pass the ceiling (e.g. `query_class`) the in-tool `assert_class_accessible!` runs next and the `agent_hidden` message echoes the class name supplied by the caller.

---

## `agent_hidden` — Per-Class Agent-Surface Denial

`agent_hidden` is a model-level DSL declaration that blocks all agent access to a Parse class. It is the strongest access-restriction primitive in the DSL — stronger than `agent_fields` (which trims visible fields) and unrelated to `agent_visible` (which is an opt-in filter for the relation diagram, not an access restriction).

### Declaring a hidden class

```ruby
class StudentSSN < Parse::Object
  parse_class "StudentSSN"
  property :student_name, :string
  property :ssn, :string
  agent_hidden
end
```

`agent_hidden` takes no arguments by default. Its presence in the class body registers the class in a process-wide hidden registry.

### `agent_hidden(except: :master_key)` — relaxed scope (v4.3.0)

Marks a class hidden from session-bound agents (user-facing MCP, per-user tooling) while permitting master-key agents (internal admin / dev MCP / customer-support bots) to address it:

```ruby
class Parse::Session
  # Hidden from session-bound agents; reachable by master-key agents.
  # Default in v4.3.0+; an application that explicitly needs session_token
  # access can re-declare or call agent_unhidden.
  agent_hidden(except: :master_key)
end
```

Use this for collections where a debugging tool legitimately needs read access but no per-user agent ever should — `_Session` is the canonical case. The field-level `INTERNAL_FIELDS_DENYLIST` floor (sessionToken, _hashed_password, _auth_data, _rperm/_wperm) still strips credential columns from every response regardless, so even a master-key superadmin tool that reaches `_Session` cannot exfiltrate active tokens.

Re-declaring `agent_hidden` with a different `except:` scope is last-write-wins: an application that wants to relax parse-stack's default strict-hidden state on `_Session` can call `Parse::Session.agent_hidden(except: :master_key)` at boot to override the default. The composition order at dispatch:

1. Global hidden? → if yes and `except:` is nil, refuse all agents.
2. Global hidden? + `except: :master_key` → permit only when `agent.session_token` is empty.
3. Per-agent `classes:` allowlist (v4.3.0 — see the `Parse::Agent.new(classes:)` section above) → can further narrow but cannot re-enable.

### `agent_unhidden` — reverse the default (v4.3.0)

Cancels a prior `agent_hidden` declaration so the class is reachable by every agent surface again. The intended use is opt-in restoration of a class that parse-stack hides by default — e.g. an application that genuinely uses `_Product` (vestigial Parse iOS IAP feature, hidden by default in v4.3.0+) can opt back in at boot:

```ruby
# config/initializers/parse_stack.rb
Parse::Product.agent_unhidden
```

The call emits a one-line `[Parse::Agent:SECURITY]` audit banner identifying the unhidden class and reminding the operator that master-key agents bypass per-row ACL/CLP enforcement, so per-class `agent_fields` / `agent_canonical_filter` / `tenant_id` are the only remaining access boundary. Silenceable via the same `Parse::Agent.suppress_master_key_warning = true` flag that silences the master-key construction banner.

Returns `true` only when a previous hidden state was actually cleared, `false` for a no-op call on a never-hidden class (Hash#delete? semantics); no banner emits on a no-op so the warning isn't trained-away by repetition.

### Built-in hidden classes (v4.3.0)

Four parse-stack core classes are now `agent_hidden` by default:

| Class | Why | How to restore |
|-------|-----|----------------|
| `Parse::Product` | The `_Product` collection is a vestigial Parse iOS in-app-purchase feature that almost no modern application uses. Exposing it just adds noise to schema listings and tool-selection prompts. | `Parse::Product.agent_unhidden` at boot. |
| `Parse::Session` | `_Session` holds active session tokens; surfacing it under the master-key default risks credential leakage. The `sessionToken` column is also on the `INTERNAL_FIELDS_DENYLIST` floor so it's stripped from every response even when the class is reachable. | `Parse::Session.agent_unhidden` for full restoration, or `Parse::Session.agent_hidden(except: :master_key)` to keep it off the user-facing surface while permitting internal admin tooling. |
| `Parse::JobStatus` | `_JobStatus` carries operational signal — registered job names, status messages, error traces, scheduler parameters. An agent enumerating these can fingerprint the server's internals and surface error detail an end-user-facing tool shouldn't reveal. | `Parse::JobStatus.agent_unhidden` for full restoration, or `Parse::JobStatus.agent_hidden(except: :master_key)` for internal-tooling-only access. |
| `Parse::JobSchedule` | `_JobSchedule` rows are scheduler configuration; the `params` column can carry credentials or destination configuration written by external scheduling tooling. | `Parse::JobSchedule.agent_unhidden` for full restoration, or `Parse::JobSchedule.agent_hidden(except: :master_key)` for internal-tooling-only access. |

### What changes when a class is hidden

**Catalog:** The class disappears from `get_all_schemas`, `tools/list`, and `resources/list` responses. MCP clients that enumerate the schema will not see it.

**Tool calls:** Every built-in tool that accepts a `class_name` argument (`query_class`, `count_objects`, `get_object`, `get_objects`, `get_sample_objects`, `aggregate`, `explain_query`, `get_schema`) returns a structured denial immediately, before any request reaches Parse Server:

```ruby
{
  success:    false,
  error:      "Class 'StudentSSN' is not accessible to this agent",
  error_code: :access_denied,
}
```

**`ActiveSupport::Notifications`:** The `parse.agent.tool_call` event is still fired for denied calls, with `success: false`, `error_code: :access_denied`, and `error_class: "Parse::Agent::AccessDenied"`. This lets your Datadog / Splunk subscriber detect probing attempts without parsing wire responses.

**Database:** The records still exist in MongoDB. Direct application code (`Parse::Object#query`, `Parse::MongoDB.*`) is completely unaffected. `agent_hidden` is an agent-surface denial, not a database-level ACL.

### Relationship with `agent_fields`

`agent_fields` and `agent_hidden` solve different problems:

| DSL | Effect | When to use |
|-----|--------|-------------|
| `agent_fields :name, :status` | Trims visible fields; class remains queryable | Expose safe analytics columns; hide PII columns in a queryable class |
| `agent_hidden` | Removes class from all agent surfaces entirely | Entire class is sensitive (SSNs, billing, password tokens) |

### Security caveats

**Registered tool handlers are trusted code.** Custom tools registered via `Parse::Agent::Tools.register` receive the raw `Parse::Agent` instance and can call `Parse::Object#query`, `Parse::MongoDB.find`, or `.results_direct` directly in their handler body. The `agent_hidden` denial does not propagate into handler bodies — those handlers are first-party code you control. This is by design. See the "Registered handlers are trusted code" callout in the Custom Tools section.

**Hidden vs. non-existent — the error-code oracle.** The `:access_denied` error code is distinct from the generic runtime error returned when a class simply does not exist. An authenticated caller who can enumerate class names can therefore distinguish "hidden" from "doesn't exist" by comparing `error_code` values. If you need to conceal even the existence of a class, the current implementation does not provide that guarantee — the access denial message includes the class name supplied by the caller.

**Pointer-include resolution is gated by a two-layer defense.** Earlier releases had a known gap where an `include: ["hidden_class"]` on a non-hidden parent could exfiltrate a hidden child via the server-resolved pointer. As of v4.1.0 this is closed by two complementary mechanisms:

1. **Include-path resolver (request-time).** Every tool that accepts `include:` (`query_class`, `get_object`, `get_objects`, `export_data`) walks each dotted path through the parent class's `belongs_to` / `has_one` references and refuses the call with `:access_denied` if the terminal class is hidden. Both camelCase and snake_case segment names are resolved. `get_sample_objects` does not accept `include:` and relies on the redactor alone.
2. **Post-fetch redactor (response-time, defense in depth).** The result set from every read tool — including aggregate responses, `$lookup` outputs, and free-form `include:` names the resolver couldn't bind — is walked and any nested object whose `className` matches a hidden class is replaced with a placeholder `{ "className" => "<Class>", "__redacted" => true }`. The hidden record's fields never leave the dispatcher.

   The walker also matches Parse-on-Mongo pointer-storage strings (`"<ClassName>$<objectId>"`) under ANY containing key, not only under `_p_*` storage-column keys. A raw aggregate pipeline that re-projects the storage column under an arbitrary output name — `{ "$project" => { "leak" => "$_p_secret" } }` or `{ "$group" => { "_id" => "$_p_secret" } }` — produces rows of the form `{ "leak" => "HiddenClass$abc123" }` where the containing key is not `_p_*`. The walker now scrubs every String value whose extracted class name is in `MetadataRegistry.hidden_class_names`, so hidden objectIds cannot be exfiltrated through a rebound key. The same scrub fires on `group_by` and `distinct` `$group._id` values via `redact_hidden_pointer_groups!` before the result reaches `ResultFormatter`.

If you have application-level handlers that should bypass redaction, query through `Parse::Object#query` or `Parse::MongoDB.find` directly — both guards are scoped to the agent-tool boundary, not the application data layer.

### Usage example with allowlist complement

A common pattern is to pair a fully hidden SSN table with a sibling student table that exposes only safe analytics fields:

```ruby
# Fully hidden — no agent surface at all
class StudentSSN < Parse::Object
  parse_class "StudentSSN"
  property :student_name, :string
  property :ssn, :string
  agent_hidden
end

# Queryable, but only analytics-safe fields are visible
class Student < Parse::Object
  property :name, :string
  property :enrolled_year, :integer
  property :subject, :string
  property :email, :string  # hidden by allowlist
  agent_fields :name, :enrolled_year, :subject
end
```

With this setup, `get_all_schemas` returns `Student` (with `email` stripped) and omits `StudentSSN` entirely. `count_objects("StudentSSN")` returns `error_code: :access_denied`. `query_class("Student")` returns objects projected to `name`, `enrolled_year`, and `subject`.

---

## `agent_large_fields` — Schema-Level Size Hints

`agent_large_fields` is a model-level declaration that flags fields known to carry large payloads (long text bodies, embedded documents, base64-encoded blobs, raw HTML, JSON blobs). The hint surfaces through `get_schema` as `large_field: true` on each declared field, so an LLM client can project the field away with `keys:` in its FIRST `query_class` call rather than discovering the size by hitting the 4 MiB response cap and having to retry.

### Declaration

```ruby
class Article < Parse::Object
  parse_class "Article"
  property :title, :string
  property :body, :string
  property :raw_html, :string
  property :author, :pointer, class_name: "_User"
  agent_large_fields :body, :raw_html
end
```

`agent_large_fields` takes a splat of field names (symbols or strings). The declaration is class-level metadata; it does not affect storage, queries, or any non-agent code path.

### What changes in `get_schema`

The flagged fields gain a `large_field: true` key in the field info object:

```ruby
{
  name: "body",
  type: "string",
  required: false,
  large_field: true
}
```

An LLM that reads the schema before issuing a query learns the field is heavy and can preemptively project it away:

```ruby
agent.execute(:query_class, class_name: "Article",
                            keys: ["objectId", "title", "author"])
# omits body and raw_html — response stays well under the cap
```

When the LLM specifically needs the heavy field for one record, it can fetch that record with `get_object` — one large body fits comfortably under the 4 MiB cap.

### Restrictions

**Pointer and Relation types are never flagged.** Even when explicitly named in `agent_large_fields`, the schema annotation is suppressed for `Pointer`/`Relation` field types. The stored value for a pointer is a small reference (`{className, objectId}` or a parse-reference string); only `include:` resolution materializes the underlying record, which is a query-time concern and not a schema-time hint. Annotating the pointer would be misleading.

### Relationship to other size guardrails

`agent_large_fields` is the **proactive** layer. It tells the LLM "this field is heavy" before the first query. Three reactive layers sit underneath it:

1. **`query_class` truncate-and-annotate** — if the LLM didn't read the schema or ignored it, an oversized response is silently recovered by dropping the heaviest field and returning a partial-success `_truncated` block. See "Response size cap" in the Performance section.
2. **Oversize diagnostic on other tools** — `aggregate`/`export_data`/`get_object` refusals include a per-field byte ranking and a positive `keys:` recommendation so the LLM can retry correctly.
3. **`MAX_TOOL_RESPONSE_BYTES` floor** — 4 MiB hard ceiling regardless of all of the above.

Using `agent_large_fields` proactively eliminates the cost of layers (1) and (2) on classes where the developer already knows which columns are heavy. Layers (2) and (3) catch cases the declaration didn't anticipate.

---

## `_description:` and `_enum:` — Field-Level Schema Documentation

Two options on `property` carry per-field metadata to an LLM through `get_schema`. They're orthogonal to the validation-side `enum:` option and the `agent_fields` allowlist — they purely document what a field means and what its allowed values are, so an LLM composing a `where:` constraint doesn't have to infer semantics from the field name alone.

### Declaration

```ruby
class Subscription < Parse::Object
  parse_class "Subscription"

  property :title, :string,
           _description: "Display title for this subscription grant"

  property :grant, :string,
           _description: "Scope of the subscription grant",
           _enum: {
             workspace:    "Member of a workspace within the tenant",
             project:      "Member of a single project under a workspace",
             tenant:       "Member of the tenant as a whole",
           }

  property :account_level, :string,
           _enum: {
             basic:         "Default tier",
             paid:          "Active paid subscription",
             complimentary: "Granted by support; non-billable",
           }
end
```

`_description:` takes a single string. `_enum:` takes a Hash mapping each allowed value (Symbol or String) to a per-value description. Value keys are stringified at declaration time to match the wire-format shape an LLM will see in query constraints (the schema always reports `value: "workspace"`, never `value: :workspace`).

### Surface in `get_schema`

Both annotations show up per-field in the `fields[]` array:

```ruby
agent.execute(:get_schema, class_name: "Subscription")
# => {
#   success: true,
#   data: {
#     class_name: "Subscription",
#     fields: [
#       { name: "title", type: "string", required: false,
#         description: "Display title for this subscription grant" },
#       { name: "grant", type: "string", required: false,
#         description: "Scope of the subscription grant",
#         allowed_values: [
#           { "value" => "workspace", "description" => "Member of a workspace within the tenant" },
#           { "value" => "project",   "description" => "Member of a single project under a workspace" },
#           { "value" => "tenant",    "description" => "Member of the tenant as a whole" }
#         ] },
#       { name: "accountLevel", type: "string", required: false,
#         allowed_values: [...] },
#       ...
#     ]
#   }
# }
```

`allowed_values` is an array of `{value, description}` objects so the JSON shape round-trips cleanly through MCP without depending on Hash-ordering semantics in the consumer. The `value` is always a string; the `description` is the LLM-facing prose.

### Resolution against `field:` aliases

The lookup honors `field_map`, so a property declared with an explicit `field:` alias still resolves correctly when the server returns the column under its alias:

```ruby
property :external_status, :string,
         field: :ExtStatus,
         _description: "Status from upstream system",
         _enum: { active: "Currently operational", retired: "End-of-life" }
```

The schema response surfaces both `description:` and `allowed_values:` under `"ExtStatus"` (the wire name), not under `"external_status"` (the Ruby symbol). This is the same `field_map` lookup pattern the `agent_fields` allowlist uses — declarations on aliased properties are recovered by reversing the map at enrichment time.

### `enum:` vs `_enum:` — separate concerns

The two options are orthogonal:

| Option | Role | Effect |
|--------|------|--------|
| `enum: [:active, :retired]` | Validation | Restricts which values can be saved; raises on save with a value outside the set. |
| `_enum: { active: "...", retired: "..." }` | Documentation | Surfaces per-value descriptions to the LLM via `allowed_values:` on `get_schema`. |

Declaring both on the same property is supported and idiomatic. The gem does NOT cross-validate — `_enum:` keys can drift from `enum:` values without raising. Userland is responsible for keeping them in sync; the `audit_metadata` helper (below) flags neither divergence today.

### Intended for string-typed columns only

Value keys are stringified unconditionally, so declaring `_enum:` on an integer/boolean column will surface string-shaped values that won't match the column in a `where:` filter:

```ruby
# Footgun — don't do this
property :count, :integer, _enum: { 1 => "low", 2 => "high" }
# get_schema reports allowed_values: [{ "value" => "1", ... }, { "value" => "2", ... }]
# An LLM that copies `where: { count: "1" }` gets zero matches (column is integer).
```

The gem doesn't raise on the declaration — keeping `_enum:` on string-typed properties is userland's responsibility.

---

## Pointer-field `query_hint` in `get_schema` (v4.4.3+)

Pointer columns are stored on disk as `"ClassName$objectId"`. A `where:` constraint that passes a bare objectId without the surrounding Pointer shape matches nothing, and an LLM seeing `type: "Pointer"` alone has no signal about which value shapes are accepted. The schema formatter auto-emits a `query_hint:` on every Pointer field describing the SDK-accepted shapes inline, so the LLM doesn't have to query a sample row or guess.

```ruby
agent.execute(:get_schema, class_name: "Post")
# => {
#   success: true,
#   data: {
#     class_name: "Post",
#     fields: [
#       { name: "author", type: "Pointer", required: true,
#         target_class: "_User",
#         query_hint:   'Pointer to _User. Equality: { "author" => "<objectId>" } ' \
#                       'or { "author" => { "__type" => "Pointer", ' \
#                       '"className" => "_User", "objectId" => "<id>" } }. ' \
#                       '$in/$nin: { "author" => { "$in" => ["<id1>", "<id2>"] } } ' \
#                       '(bare objectIds; the SDK normalizes against the pointer storage shape).' },
#       ...
#     ]
#   }
# }
```

**Hidden-target collapse.** When the target class is registered as `agent_hidden` (the LLM is not allowed to know it exists), `target_class:` is suppressed and `query_hint:` collapses the class name to a `<targetClass>` placeholder so the hint still describes the shape without leaking the target's identity:

```ruby
# Subscription.belongs_to :user, class_name: "_User"
# and _User is agent_hidden in this agent's posture
# => { name: "user", type: "Pointer",
#      query_hint: 'Pointer to <targetClass>. Equality: { "user" => "<objectId>" } ' \
#                  'or { "user" => { "__type" => "Pointer", ' \
#                  '"className" => "<targetClass>", "objectId" => "<id>" } }. ' \
#                  '$in/$nin: { "user" => { "$in" => ["<id1>", "<id2>"] } } ...' }
```

The hint mirrors the shapes the SDK actually normalizes through `convert_constraints_for_aggregation` (mongo-direct) and the REST `find_objects` path — the bare-objectId `$in` form works because the query rewriter rebuilds the storage-form match from the array. The fully-qualified Pointer hash form also works in both code paths. Stating both inline removes the silent-zero failure mode where an LLM writes `where: { author: "abc123" }` against a Pointer column and reads the empty result as a real answer instead of a shape mismatch — pair with `Parse.strict_pointer_shapes = true` to convert any remaining unresolvable shapes into a `PointerShapeError` raise.

---

## `agent_join_fields` — Narrow Projection on Includes

`agent_join_fields` is a model-level declaration that controls how this class is projected when it shows up as an **included pointer** on another class's query. The direct-query `agent_fields` allowlist is typically the full "what the agent may see" set; the join-projection list is the narrower "what's interesting when I'm a foreign key" set. Without it, an `include:` of a heavy class on a high-cardinality parent query produces a wire payload dominated by fields the LLM never reads.

### The bug it fixes

The reported reproducer: a `query_class(class_name: "Subscription", keys: ["user", "title", "active", "createdAt"], include: ["user"])` against a 6-row Subscription query. The included `_User` records carried full S3 presigned image URLs (~600 chars each on two columns), a 17-entry `workspaces[]` pointer array, an `tenants[]` array, and 13 other fields per row. The user objects accounted for ~85% of the response payload, while the LLM only ever consumed `firstName`/`lastName`/`email`/`lastActiveAt`/`category` — maybe 5% of the materialized user.

`keys:` on the parent class trimmed the parent rows correctly, but Parse Server returned the included user untouched because no dotted-path projection was specified for the join. `agent_join_fields` is the developer-friendly way to declare the projection once at the model layer instead of per-call.

### Declaration

```ruby
class Parse::User
  # Direct-query allowlist — the upper bound on what an agent ever sees
  # from _User on a `query_class("_User", ...)` call.
  agent_fields :first_name, :last_name, :email, :icon_image, :source_image,
               :workspaces, :tenants, :last_active_at, :category

  # Heavy fields — stripped from any join even without an agent_join_fields
  # declaration (see "Resolution order" below).
  agent_large_fields :icon_image, :source_image

  # Narrower projection used when _User shows up as a join target. The agent
  # gets these fields automatically when another class's query includes :user
  # — no per-call dotted-path keys needed.
  agent_join_fields :first_name, :last_name, :email, :last_active_at, :category
end
```

### Subset invariant

When both `agent_fields` and `agent_join_fields` are declared, **every entry in `agent_join_fields` MUST also appear in `agent_fields`**. The direct-query allowlist is the security upper bound on what the agent sees; the join-projection list can only tighten it, never widen it. A violation raises `ArgumentError` at class load time so the misconfiguration surfaces immediately rather than at first query.

Declaring `agent_join_fields` without `agent_fields` is allowed — it means "no direct-query allowlist (so the agent sees the full row on a direct `query_class`), but on a join project to these only."

### Auto-projection on `include:`

`query_class`, `get_object`, `get_objects`, and `export_data` all run **keys-on-include auto-projection** when:

1. The caller passes a non-empty `keys:` array.
2. The caller names a bare pointer field in both `keys:` and `include:`.
3. The caller does NOT pass any `<pointer>.*` dotted path for that same pointer.

When all three hold and the joined class has an annotation that produces a non-empty projection, the SDK appends dotted-path keys to the wire `keys:` parameter so Parse Server returns only the projected subfields of the included record. The bare-pointer entry stays in `keys:` so the pointer column itself is returned at the parent level.

#### Resolution order

For the auto-projection to fire, the joined class needs at least one of: `agent_join_fields`, `agent_fields`, or `agent_large_fields`. Resolution is first-match-wins:

| Tier | Joined class declares...                  | Projection set                          | Source flag                  |
|------|-------------------------------------------|-----------------------------------------|------------------------------|
| 1    | `agent_join_fields`                       | The declared list (wire format)         | `:join_fields`               |
| 2    | `agent_fields` (no `agent_join_fields`)   | `agent_fields - agent_large_fields`     | `:allowlist_minus_large`     |
| 3    | only `agent_large_fields`                 | `field_map.keys - agent_large_fields`   | `:field_map_minus_large`     |
| 4    | none of the above                         | nil (no projection — full record)       | n/a                          |

Tier 3 ("strip mode") projects to the set of fields the Ruby model declares via `property` minus the large set. Server-side columns not declared as a `property` on the Ruby class won't come back — an honest trade-off, since the SDK can only project to fields it can name.

`ALWAYS_KEEP_FIELDS` (`objectId`, `createdAt`, `updatedAt`) is unioned into every projection so pointer dereferencing always works. `Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST` entries (`_hashed_password`, `_password_history`, `_session_token`, `_email_verify_token`, `_perishable_token`, `_failed_login_count`, `_account_lockout_expires_at`, `_rperm`, `_wperm`, `_tombstone`, `_auth_data`, and the `_auth_data_<provider>` prefix) are always filtered out at the end, identical to `MetadataRegistry.field_allowlist`, so an accidental `property :pw, field: :_hashed_password` mapping cannot leak through the join surface.

The internal-field denylist behaves as a **per-process floor** that holds independent of any `agent_fields` allowlist declaration on the joined class. Even on a class with no `agent_fields` declared, the join surface, the constraint translator (`where:` keys on every read tool), and the pipeline walker (`$project` / `$group._id` / `$addFields` / `$match` keys and `$<field>` reference strings at any nesting depth, not only inside `$expr`) all refuse internal-field names. The denylist is the security boundary; the allowlist is the documentation/projection convenience layered on top.

#### Suppression — caller intent overrides the auto-projection

Pass any `<pointer>.*` dotted path in `keys:` and auto-projection is suppressed for that pointer. The caller signaled "I named exactly what I want." The behavior matches verbatim:

```ruby
# Auto-projection fires (bare pointer in keys + include)
agent.execute(:query_class,
  class_name: "Subscription",
  keys:    ["user", "title"],
  include: ["user"])
# => wire keys: "user,title,user.firstName,user.lastName,user.email,user.category,user.objectId,user.createdAt,user.updatedAt"

# Auto-projection SUPPRESSED (caller passed user.* dotted path)
agent.execute(:query_class,
  class_name: "Subscription",
  keys:    ["user.iconImage", "title"],
  include: ["user"])
# => wire keys: "user.iconImage,title"  (no auto-expansion)
```

The auto-projection also doesn't fire when:

- `keys:` is absent entirely (caller chose full-row mode).
- The bare pointer name is NOT in `keys:` (caller didn't ask for the pointer at the parent level either — Parse Server wouldn't return it).
- The include is multi-hop (`include: ["user.workspace"]`) — only one-hop targets get auto-projected; deeper hops materialize fully. Keeps the rewrite bounded and avoids walking the full RelationGraph at query time.

### Response envelope: `truncated_include_fields`

When auto-projection fires, `query_class`, `get_object`, and `get_objects` add a `truncated_include_fields` key to the response envelope listing, per pointer, which wire-format fields were actively dropped:

```ruby
agent.execute(:query_class,
  class_name: "Subscription",
  keys:    ["user", "title", "active"],
  include: ["user"],
  limit:   10)
# => {
#   class_name: "Subscription",
#   result_count: 10,
#   results: [...],
#   truncated_include_fields: {
#     "user" => ["iconImage", "sourceImage", "workspaces", "tenants"]
#   }
# }
```

The LLM can read the envelope, see what was dropped, and re-ask with explicit dotted paths if it actually needs a dropped field (`keys: ["user.iconImage"]`). Suppressed entirely when no auto-projection fired, so the envelope stays minimal for the common case.

### When `agent_join_fields` is NOT what you need

If the join-relevant fields ARE the same as the direct-query fields (common for small, narrow classes), don't declare `agent_join_fields` — tier 2 (`agent_fields - agent_large_fields`) handles it correctly. The new DSL exists for classes like `_User` where the direct-query allowlist is broad but the per-join projection should be narrow.

`agent_join_fields` does NOT replace `agent_fields`. It does NOT control direct-query projection. It only tightens the auto-projection that fires on `include:` resolution.

### `get_sample_objects` is not affected

`get_sample_objects` does not accept an `include:` parameter, so auto-projection never fires there. Sample queries always project to the parent class's `agent_fields` allowlist (when declared) and never resolve pointers.

### Discovery via `get_schema`

Both `agent_fields` and `agent_join_fields` are echoed as top-level keys on the `get_schema` response when declared. The allowlist is already enforced by stripping non-allowed fields from the response, but enforcement-by-omission left consumers guessing what they could write in `keys:` — the explicit echo closes that gap:

```ruby
agent.execute(:get_schema, class_name: "Subscription")
# => {
#   success: true,
#   data: {
#     class_name:        "Subscription",
#     type:              "custom",
#     fields:            [...],                         # already trimmed to the allowlist
#     agent_fields:      ["user", "title", "active", "grant", "accountLevel"],
#     agent_join_fields: ["title", "active"],           # narrower set used on `include:` resolution
#     ...
#   }
# }
```

Wire-format names. `ALWAYS_KEEP_FIELDS` (objectId / createdAt / updatedAt) are excluded from the echo to keep it minimal — those are always available and would only noise up the list. Storage-form columns (`_p_*` pointer columns) and other Parse-internal underscored fields are never addressable through agent tools regardless of what userland passes to `agent_fields`; the `get_schema` tool description spells this out explicitly so the LLM stops trying.

Both echoes are suppressed when the corresponding DSL is not declared. A class with no `agent_fields` declaration produces a `get_schema` response with no `agent_fields:` key (rather than an empty array), so the absence-of-key form means "no allowlist; ask `query_class` for whatever fields you want and the LLM-facing schema is the full set."

---

## Operator Environment Gates for Write & Schema Tools

`Parse::Agent::Tools` exposes a write surface (`create_object`, `update_object`, `delete_object`, `create_class`, `delete_class`) and a write surface for declared methods (`call_method` invoking `agent_method :name, permission: :write` or `:admin`). Both surfaces are gated by per-agent `permissions:` AND by process-wide environment variables — defense in depth against a misconfigured factory that accidentally constructs a `:write` or `:admin` agent in production.

### The four env vars

| Variable | Gates | Required for |
|----------|-------|--------------|
| `PARSE_AGENT_ALLOW_WRITE_TOOLS` | broad write category | `call_method` of an `agent_method :foo, permission: :write` |
| `PARSE_AGENT_ALLOW_SCHEMA_OPS`  | broad admin category | `call_method` of an `agent_method :foo, permission: :admin` |
| `PARSE_AGENT_ALLOW_RAW_CRUD`    | narrow raw CRUD | raw `create_object` / `update_object` / `delete_object` (additionally requires `WRITE_TOOLS`) |
| `PARSE_AGENT_ALLOW_RAW_SCHEMA`  | narrow raw schema | raw `create_class` / `delete_class` (additionally requires `SCHEMA_OPS`) |

Truthy values: `1`, `true`, `yes`, `on` (case-insensitive). Anything else (including unset) means disabled.

### AND semantics for raw tools

The raw CRUD and raw schema tools require BOTH the broad gate AND the narrow gate:

- `create_object` requires `PARSE_AGENT_ALLOW_WRITE_TOOLS=true` AND `PARSE_AGENT_ALLOW_RAW_CRUD=true`.
- `create_class` requires `PARSE_AGENT_ALLOW_SCHEMA_OPS=true` AND `PARSE_AGENT_ALLOW_RAW_SCHEMA=true`.

This lets a deployment enable intent-based writes via `agent_method` (set only the broad gate) WITHOUT exposing the generic create/update/delete surface (the narrow gate stays unset).

### Recommended deployment posture

| Goal | WRITE_TOOLS | SCHEMA_OPS | RAW_CRUD | RAW_SCHEMA |
|------|-------------|------------|----------|------------|
| Read-only (default) | unset | unset | unset | unset |
| Intent-based writes via declared `agent_method` only | `true` | unset | unset | unset |
| Add admin-level agent_methods | `true` | `true` | unset | unset |
| Add raw create/update/delete (escape hatch) | `true` | unset | `true` | unset |
| Operator-only: entire surface | `true` | `true` | `true` | `true` |

The first non-default row is the recommended posture for most agent-facing deployments. Every mutation has to be declared explicitly on a Parse::Object subclass as an `agent_method`, with a method body that owns validation, normalization, and side effects. The LLM never touches `.save` directly; it calls named domain operations (`set_client_description`, `archive_user`, etc.).

### Refusal shape

When a gate refuses, `Parse::Agent#execute` returns:

```ruby
{
  success:    false,
  error_code: :access_denied,
  error:      "Raw CRUD tool 'create_object' is disabled. " \
              "Required: PARSE_AGENT_ALLOW_WRITE_TOOLS=true AND PARSE_AGENT_ALLOW_RAW_CRUD=true. " \
              "Prefer declaring an agent_method on the target class for an intent-based " \
              "write path that requires only PARSE_AGENT_ALLOW_WRITE_TOOLS."
}
```

The error message names the missing variables specifically, so an operator who sees the refusal in a log knows which env var to set. When one of the two is already set the message names only the still-missing one. The `error_code` is always `:access_denied` regardless of which gate was missing — same code as `agent_hidden` refusals — so a downstream subscriber can rate-limit, alert, or audit on the single code.

### Programmatic introspection

`Parse::Agent.write_tools_enabled?`, `Parse::Agent.schema_ops_enabled?`, `Parse::Agent.raw_crud_enabled?`, and `Parse::Agent.raw_schema_enabled?` are class-method predicates returning the current state of each gate. Useful in startup smoke tests:

```ruby
abort "production agent must run read-only" if Parse::Agent.raw_schema_enabled?
```

---

## `agent_tenant_scope` — Multi-Tenant Data Isolation

`agent_tenant_scope` is a model-level declaration that enforces per-tenant data scoping on every read tool. It closes the highest-blast-radius gap in a naive multi-tenant deployment: a factory that authenticated the user but forgot to inject `{ org_id: ... }` into every `query_class` call would silently leak across tenants. The DSL makes that mistake structurally impossible.

### Declaration

```ruby
class Order < Parse::Object
  parse_class "Order"
  property :org_id, :string
  property :total, :float
  property :status, :string

  # Every read tool now filters by tenant_id = agent.tenant_id automatically.
  agent_tenant_scope :tenant_id, from: ->(agent) { agent.tenant_id }
end
```

Two arguments:
- `field` (Symbol or String) — the Parse field to scope on (e.g., `:tenant_id`, `:account_id`, `:workspace_id`).
- `from:` (Proc / lambda) — a callable receiving the agent instance and returning the scope value to filter by. Return `nil` to signal "this agent has no tenant binding" — the call is then refused unless a bypass declaration covers the agent.

### Setting the agent's tenant binding

Agents declare their tenant in the factory:

```ruby
Parse::Agent.rack_app do |env|
  user = MyAuth.verify!(env)
  Parse::Agent.new(
    permissions:   :readonly,
    session_token: user.session_token,
    tenant_id:     user.org_id,
  )
end
```

`tenant_id:` is an arbitrary value (String, Integer, etc.) that the per-class `from:` callable interprets. It doesn't have to be called `org_id` — that's the field name on Parse::Object; `tenant_id` is the agent-level binding.

### Enforcement across read tools

The scope is enforced at every read tool entry point:

| Tool | Enforcement mechanism |
|------|------------------------|
| `query_class`, `count_objects`, `get_sample_objects` | Merge `{ <field> => <value> }` into the effective `where:` after constraint translation. |
| `aggregate`, `export_data` (pipeline mode) | Prepend a `$match` stage at pipeline index 0 with the scope filter. |
| `export_data` (query mode) | Same as `query_class`. |
| `get_object`, `get_objects` | After fetching, verify each returned record's scope field matches the agent's bound value. Mismatch refuses with `:access_denied`. |

**Why `get_object` refuses instead of filtering.** Silently returning "not found" for cross-tenant ids would create an oracle for "does this id exist in another tenant" — the timing or refusal signal differs from a truly missing id. Refusing with `:access_denied` makes the cross-tenant attempt visible in the audit log and indistinguishable to the caller from "I'm not authorized to know whether this exists."

### Spoof protection for caller-supplied `where:`

If the LLM passes its own scope-field value (e.g., `where: { org_id: "other_tenant" }`), the merge logic compares against the agent's bound value:

- **Matching value** (caller's value equals the scope value, in either snake_case or camelCase) → passes through. The caller's filter is redundant but not wrong.
- **Mismatching value** → refused with `:access_denied`. The LLM cannot spoof the tenant filter.

Both `"org_id"` / `:org_id` (snake_case) and `"orgId"` / `:orgId` (camelCase wire format) are checked, so an LLM passing the field name in either form is handled consistently.

### Bypass for admin / operator agents

Some agents — operator tooling, batch processes, master-key admin agents — legitimately need cross-tenant access. Declare a bypass condition per class:

```ruby
class Order < Parse::Object
  agent_tenant_scope :org_id, from: ->(agent) { agent.tenant_id }
  agent_tenant_scope_bypass { |agent| agent.permissions == :admin }
end
```

The block receives the agent and returns truthy to bypass enforcement. A bypass block that raises is treated as not-bypassed (fail closed). Without a bypass declaration, any agent with `tenant_id: nil` hitting a scoped class is refused outright.

### Known limitation: `$lookup` / `$graphLookup` / `$unionWith` sub-pipelines

Tenant scope is applied as a `$match` stage at the TOP-level pipeline only. Sub-pipelines inside `$lookup`, `$graphLookup`, and `$unionWith` are NOT automatically scoped. Multi-tenant deployments that use `agent_tenant_scope` should pick one of:

1. **Disable lookup auto-rewrite for tenant-bound agents** — `Parse.rewrite_lookups = false` (per-process), or pass `rewrite_lookups: false` per call. The LLM can still issue lookups using the explicit `_p_*` form, but the convenience auto-rewrite of logical-name joins is off.
2. **Refuse lookups from tenant-bound agents entirely** — application code rejects pipelines containing `$lookup` / `$graphLookup` / `$unionWith` when `agent.tenant_id` is set.
3. **Mark joinable cross-tenant classes as `agent_hidden`** — the most permissive joining-class is unreachable to the agent.

The proper fix (recursive scope injection into sub-pipelines) is tracked as a follow-up; see [SECURITY_GUIDE.md](../SECURITY_GUIDE.md) for the threat model and posture recommendations.

---

## `agent_canonical_filter` — Per-Class "Valid State" Predicate

Many Parse classes have a "live records" subset that every legitimate read should respect — soft-delete columns (`archived`), publication flags (`published`), validity windows, tombstone markers, etc. Without a mechanism that codifies this subset, an LLM that drops to raw `aggregate` for a question `query_class` couldn't answer will silently include rows the application would have hidden, producing counts that disagree with the rest of the system.

`agent_canonical_filter` declares the predicate ONCE on the model class. Every read tool the agent exposes applies it BY DEFAULT to every call, and `get_schema` surfaces it so callers that opt out can reproduce the predicate manually.

### Declaration

```ruby
class Post < Parse::Object
  property :title,      :string
  property :archived,  :boolean
  property :published, :boolean

  # MongoDB-style match expression. Same shape that query_class's `where:`
  # accepts. Keys are stringified at declaration time.
  agent_canonical_filter "archived"  => { "$ne" => true },
                         "published" => true
end
```

The DSL accepts any well-formed where-expression Hash and validates it at class load time through `Parse::PipelineSecurity.validate_filter!`. Declarations containing `$where`, `$function`, or `$accumulator` raise `ArgumentError` at registration rather than being silently accepted and prepended past the per-request `PipelineValidator` at call time. Internal-field keys (`_hashed_password`, `_session_token`, `_rperm`, `_wperm`, the `_auth_data_<provider>` prefix, etc.) are also refused at registration. Normal Mongo query operators (`$ne`, `$gt`, `$in`, `$exists`, etc.) and references to user-defined fields are allowed.

### Where the filter is applied

The canonical filter is applied across every read surface the agent exposes:

- **`query_class`** and **`count_objects`** — merged with the caller's `where:` via top-level `$and` so caller constraints compose rather than override. When the caller passed no `where:`, the canonical filter is used directly.
- **`aggregate`** — prepended as a `$match` stage. When a tenant-scope `$match` is already at index 0, the canonical filter sits at index 1 so tenant isolation stays first for auditability.
- **`group_by`**, **`group_by_date`**, **`distinct`** — prepended as a `$match` stage before the group/unwind stages so derived counts reflect the same "valid state" subset as `query_class`.
- **`explain_query`** — the canonical predicate is included in the explained `where:` so the reported plan matches what `query_class` would actually execute.
- **`get_sample_objects`** — included in the sample's effective `where:` so sample rows are drawn from the same subset as a normal query.
- **`export_via_query`** and **`export_via_aggregate`** (the two backends behind `export_data`) — applied so an export is never a path to soft-deleted or otherwise excluded rows that the conversational tools hide.

ID-based reads (`get_object`, `get_objects`) intentionally do NOT apply the canonical filter. The caller named a specific objectId and is asking for that exact row; redacting it because it failed a `archived => { "$ne" => true }` predicate would surprise legitimate callers fetching a soft-deleted record by ID for audit or restoration. Hidden-class refusal still applies — `agent_hidden` is the access boundary; `agent_canonical_filter` is a default predicate.

### Per-call opt-out

```ruby
# Count all posts, including soft-deleted ones
agent.execute(:count_objects, class_name: "Post",
  apply_canonical_filter: false)
```

`apply_canonical_filter: false` is a per-call escape hatch on `query_class`, `count_objects`, and `aggregate`. The class-level declaration stays "applied" — the opt-out is a deliberate signal that the caller wants the full unfiltered collection for this one query. The opt-out keyword is intentionally NOT exposed on `group_by` / `group_by_date` / `distinct` / `explain_query` / `get_sample_objects` / `export_data`: those derived views must remain consistent with `query_class` for pagination cursors, plan explanations, and exports to agree with the count/list pair. A caller that genuinely needs an unfiltered group or export can drop to `aggregate` with `apply_canonical_filter: false`.

### Discovery via `get_schema`

When a class declares `agent_canonical_filter`, `get_schema(class_name)` surfaces it as `canonical_filter:` so a caller that opts out can reproduce the predicate in its own `where:`:

```ruby
agent.execute(:get_schema, class_name: "Post")
# => {
#   success: true,
#   data: {
#     class_name:       "Post",
#     type:             "custom",
#     fields:           [...],
#     canonical_filter: { "archived" => { "$ne" => true }, "published" => true },
#     ...
#   }
# }
```

### Programmatic lookup

```ruby
Parse::Agent::MetadataRegistry.canonical_filter("Post")
# => { "archived" => { "$ne" => true }, "published" => true }
Parse::Agent::MetadataRegistry.canonical_filter("ClassWithoutFilter")
# => nil
```

### Interaction with other gates

The canonical filter applies AFTER `assert_class_accessible!` (so `agent_hidden` classes still refuse before the predicate enters the picture) and AFTER tenant-scope injection (so the canonical predicate composes with — never replaces — tenant isolation). It applies BEFORE the COLLSCAN preflight, so a canonical predicate that adds an indexed column to the effective `where:` can help a class pass the preflight that would otherwise refuse it.

The filter is NOT a security boundary on its own — it does NOT prevent reading soft-deleted rows when the caller explicitly opts out. Use `agent_hidden` for classes the agent must never touch and `agent_fields` to redact specific columns. Use `agent_canonical_filter` for the "what counts as a live record" predicate every read should honor by default.

---

## `agent_method` Dry-Run Previews

When a developer-declared `agent_method` performs writes, an LLM caller can preview the effect of the write before committing. This reduces the risk of an LLM driven by ambiguous prompts performing destructive operations the user didn't actually want.

### Opting in: `supports_dry_run: true`

```ruby
class Client < Parse::Object
  property :description, :string
  property :status, :string

  agent_method :archive, permission: :admin, supports_dry_run: true
  def archive(dry_run: false)
    if dry_run
      return {
        would_archive:  id,
        current_status: status,
        side_effects:   ["notifies_owner", "logs_audit_entry"],
      }
    end

    self.status = "archived"
    save!
    notify_owner!
    AuditLog.record!(action: :archived, client_id: id)
    { archived_at: Time.now.utc.iso8601 }
  end
end
```

The author writes both branches: the dry-run path describes what WOULD happen; the real path performs the operation. The MCP layer simply forwards the `dry_run` kwarg — it doesn't try to intercept `save!` magically (which would break side effects).

### LLM call shape

```ruby
agent.execute(:call_method,
  class_name:  "Client",
  method_name: "archive",
  object_id:   "abc123",
  arguments:   { dry_run: true })
# => { success: true, data: { result: { would_archive: "abc123", ... } } }

# After user confirmation, re-issue without dry_run:
agent.execute(:call_method,
  class_name:  "Client",
  method_name: "archive",
  object_id:   "abc123")
# => { success: true, data: { result: { archived_at: "..." } } }
```

### Universal preview when the method does not declare `supports_dry_run`

When the LLM passes `dry_run: true` to an `agent_method` that did NOT declare `supports_dry_run: true`, `call_method` returns a structural preview envelope WITHOUT invoking the method body. The agent confirms the call would pass every gate it enforces (permission tier, mass-assignment guards, `permitted_keys`, instance-method object resolution) and reports the call that would have been made — but cannot produce a method-side preview, so the response is flagged `supports_real_dry_run: false`:

```ruby
agent.execute(:call_method,
  class_name:  "Widget",
  method_name: "deactivate",
  object_id:   "w_001",
  arguments:   { dry_run: true })
# => {
#   success: true,
#   data: {
#     class_name:            "Widget",
#     method:                "deactivate",
#     object_id:             "w_001",
#     dry_run:               true,
#     supports_real_dry_run: false,
#     would_call: {
#       class:     "Widget",
#       method:    "deactivate",
#       type:      "instance",
#       object_id: "w_001",
#       args:      {}      # dry_run stripped from echoed args
#     },
#     note: "The method 'Widget.deactivate' did not declare supports_dry_run: true, ..."
#   }
# }
```

This makes preview universally safe to call without requiring every method author to opt in. The wrapper layer can always report what the call WOULD do; the `supports_real_dry_run: false` flag tells the caller "no author-side preview was consulted, so the response can't tell you what state changes would actually occur."

When the method DID declare `supports_dry_run: true` (the snippet above), behavior is unchanged: the kwarg is forwarded and the method produces its own preview.

When the caller passes `dry_run: false` (or any other falsy value) to a method that did NOT declare dry-run support, the kwarg is stripped before forwarding so the method body never sees the unexpected keyword argument; the call executes normally.

### Interaction with env gates

The dry-run gate fires AFTER the env-gate check. A `:write` method called with `dry_run: true` still requires `PARSE_AGENT_ALLOW_WRITE_TOOLS=true` on the server. Preview does NOT bypass the operator-level kill switch — an operator who has disabled writes entirely sees no preview attempts succeed.

### `permitted_keys` disclosure and `Parse::Agent.agent_debug`

`get_schema` emits the full contract for each declared `agent_method`: `name`, `type` (class vs. instance), `permission`, `description`, `supports_dry_run`, and `parameters` (when set). One field — `permitted_keys` — is gated behind a separate flag because it names the exact attributes a `call_method` invocation is permitted to write, and that set IS the write-side authorization boundary. Disclosing it on every `get_schema` response enumerates the boundary for any consumer and gives an LLM the precise field list to fuzz when probing for `permitted_keys` gaps.

`Parse::Agent.agent_debug` (class accessor, default `false`) controls the disclosure:

```ruby
# Production posture (the default): permitted_keys omitted from get_schema
Parse::Agent.agent_debug = false

# Trusted internal environments where the LLM needs the full method
# contract to construct correct call_method payloads:
Parse::Agent.agent_debug = true

# Predicate form for tooling that branches on the setting:
Parse::Agent.agent_debug?  # => false / true
```

When `agent_debug` is left at the default, `format_methods` omits the `permitted_keys` key entirely (via `.compact`); the rest of the method contract is unaffected. Set the flag to `true` only in environments where every consumer of the MCP surface is already trusted to know the write boundary — agent development sandboxes, internal-only operator tooling, or test suites that need to assert against the full contract. The flag is independent of `suppress_master_key_warning`, `refuse_collscan`, `expose_explain`, and `strict_tool_filter`; you can enable it on its own without changing any other security posture.

---

## Pagination `next_call` Hint

`query_class` responses now include an explicit `next_call:` block when `has_more: true`. LLMs follow explicit next-step instructions much more reliably than computing pagination arithmetic from `pagination.limit + pagination.skip`.

### Response shape

```ruby
{
  class_name:    "Order",
  result_count:  100,
  pagination:    { limit: 100, skip: 0, has_more: true },
  next_call: {
    tool:      "query_class",
    arguments: {
      class_name: "Order",
      limit:     100,
      skip:      100,
      where:     { "status" => "paid" },   # threaded through from original call
      keys:      ["objectId", "total"],
      order:     "-createdAt",
    }
  },
  results: [...]
}
```

When `has_more: false`, the `next_call:` field is absent (not nil — `.compact` strips it from the response hash).

The literal arguments returned in `next_call.arguments` include all the optional projection/filter arguments from the original call, so the LLM doesn't need to remember `where:` / `keys:` / `order:` / `include:` across the multi-turn pagination loop.

### Interaction with truncate-and-annotate

When a `query_class` response triggers the dispatcher's truncate-and-annotate recovery (see "Response size cap"), `next_call:` is stripped from the recovered envelope. Its skip arithmetic (`skip + limit`) is stale because the truncation's `next_skip` uses a smaller resume offset (`original_skip + fit_count`). The `_truncated` block becomes the sole authoritative pagination signal in that case.

---

## Cost Telemetry Fields

`parse.agent.tool_call` notifications now include token-and-cost estimates so a downstream dashboard can alert on per-conversation LLM input-token spend.

### Payload fields

| Key | Type | Present |
|-----|------|---------|
| `:est_input_tokens` | Integer | Success path, when `:result_size` is non-nil |
| `:est_cost_usd` | Numeric | Success path, when `:est_input_tokens` is present AND `Parse::Agent.token_cost_per_million_input` is set |

Both fields are absent on the failure path (no work done → no tokens to charge for).

### Configuring the cost rate

```ruby
# config/initializers/parse_agent_cost.rb
Parse::Agent.token_cost_per_million_input = 3.00  # USD per million input tokens
```

The rate matches your LLM provider's input pricing for the model the upstream client uses. The default is `nil`, which omits the `:est_cost_usd` field entirely so dashboards don't see a constant-zero metric.

### Heuristic accuracy

`est_input_tokens` is computed as `result_size / 4` (integer division). This is the industry-standard back-of-envelope for English JSON content and is accurate to ~20%. Operators who need exact counts should run their own tokenizer in a notification subscriber:

```ruby
ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |_n, _s, _f, _id, payload|
  next unless payload[:result_size]
  exact_tokens = TIKTOKEN.count(payload[:result_text])  # if you stash result text somewhere
  # ... record to your own metric ...
end
```

### Per-correlation dashboards

Combined with the `:correlation_id` field, operators can compute "tokens spent in conversation X" or "cost for this LLM session" by grouping events. Example StatsD shape:

```ruby
ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |_n, _s, _f, _id, payload|
  next unless payload[:est_input_tokens]
  tags = ["correlation_id:#{payload[:correlation_id] || 'none'}", "tool:#{payload[:tool]}"]
  $statsd.count("parse.agent.tokens.input", payload[:est_input_tokens], tags: tags)
  $statsd.count("parse.agent.cost.usd", payload[:est_cost_usd], tags: tags) if payload[:est_cost_usd]
end
```

---

## `Parse::Agent.audit_metadata` — Boot-Time Metadata Audit

The agent surface depends on opt-in metadata: classes that haven't declared `agent_description` are invisible in `get_all_schemas` summaries; properties without `_description:` ship to the LLM with no semantic context; typos in `agent_fields` declarations silently miss after the field-map translation. `Parse::Agent.audit_metadata` walks the Parse::Object subclass set and returns a structured report of these gaps so operators can wire the check into a boot warning, a Rake task, or a CI gate.

### Programmatic use

```ruby
audit = Parse::Agent.audit_metadata
# => {
#   classes_audited:                28,
#   visible_classes_declared:       true,   # opt-in mode vs back-compat fallback
#   missing_class_descriptions:     ["PostMetric", "PostSnapshot"],
#   missing_field_descriptions:     {
#     "Post"    => [:category, :status, ...],
#     "Subscription" => [:grant, :active]
#   },
#   unresolvable_allowlist_entries: {
#     "PostStatus" => [:statys]              # likely typo of :status
#   },
#   canonical_filter_summary:       {
#     "Post" => { "archived" => { "$ne" => true }, "published" => true }
#   }
# }

if audit[:missing_class_descriptions].any?
  raise "Refusing to boot: #{audit[:missing_class_descriptions].size} classes missing agent_description"
end
```

The hash always carries the six top-level keys regardless of findings. `missing_field_descriptions`, `unresolvable_allowlist_entries`, and `canonical_filter_summary` are empty hashes when there's nothing to report. The keys never disappear — consumers can `data[:missing_class_descriptions].any?` without nil-check guards.

### Field-description scope

When a class declares `agent_fields`, the missing-description check is scoped to the **allowlist** — those are the fields the LLM will actually see, so those are the ones worth describing. When no allowlist is declared, the check covers every property declared on the class. System fields (`object_id`, `created_at`, `updated_at`, `ACL`) are always excluded from the report.

### What it skips

Two classes of skip prevent noise that would discourage adoption:

1. **`agent_hidden` classes.** A class marked `agent_hidden` is intentionally opaque to every agent surface, so the audit doesn't pretend the missing description on it is a gap. The skip is whole-row — the class never appears in any of the four sections, even if it declares a canonical filter or allowlist typos.
2. **Parse system classes.** `_`-prefixed `parse_class` names (`_User`, `_Role`, `_Session`, `_Installation`, `_Product`, `_Audience`) are framework-supplied by parse-stack and don't benefit from userland-authored `agent_description`. Without this skip, every application that hadn't opted into `agent_visible` mode would see the system classes flooding `missing_class_descriptions`. Apps that genuinely want to document the system classes can still call `agent_description` on `Parse::User` etc. — the skip suppresses the "missing" reports, not legitimate declarations.

### Interactive use

```ruby
Parse::Agent::MetadataAudit.print_summary
# Parse::Agent metadata audit
# ========================================
# Classes audited: 28 (agent_visible mode)
#
# Missing class descriptions (2):
#   - PostMetric
#   - PostSnapshot
#
# Missing field descriptions (7 across 2 classes):
#   Post (5):
#     category, status, archived, published, author
#   Subscription (2):
#     grant, active
#
# Unresolvable allowlist entries:
#   PostStatus: statys
#
# Canonical filters declared (1):
#   Post: {"archived" => {"$ne" => true}, "published" => true}
```

`print_summary` writes to `$stdout` by default; pass `io:` to redirect. Returns the same hash that `audit_metadata` returns, so a Rake task can both display and process the findings in one call.

### Audit scope: `agent_visible` vs back-compat fallback

When at least one class has been marked `agent_visible`, that registry IS the canonical list to audit — the developer has explicitly said "these are the agent-facing classes." When no class has opted in, the audit walks every loaded `Parse::Object` subclass (back-compat mode) and reports against that. The `visible_classes_declared` field in the result tells consumers which path was taken.

In back-compat mode the descendant walk picks up every Ruby subclass loaded into the process, including test fixtures and lazily-loaded models. This is rarely a problem in production but can produce noisy results in test contexts where many fixture classes accumulate. Applications that want a tightly-scoped audit should opt into `agent_visible` mode by marking the production-facing classes.

### Suggested boot integration

```ruby
# config/initializers/parse_agent_audit.rb
Rails.application.config.after_initialize do
  audit = Parse::Agent.audit_metadata

  if audit[:missing_class_descriptions].any?
    Rails.logger.warn "[parse-agent] #{audit[:missing_class_descriptions].size} classes " \
                      "missing agent_description: #{audit[:missing_class_descriptions].inspect}"
  end

  if audit[:unresolvable_allowlist_entries].any?
    # Typos in agent_fields silently miss; fail closed in production
    raise "agent_fields entries don't resolve to known properties: " \
          "#{audit[:unresolvable_allowlist_entries].inspect}"
  end
end
```

The audit does not enforce anything on its own — it only reports. Operators decide what's a warning vs. a fail-closed condition for their deployment.
