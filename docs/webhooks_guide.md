# Cloud Code Webhooks Guide

Webhooks are how `parse-stack-next` runs **server-side** trigger logic. They are
the bridge between Parse Server and your Ruby code: Parse Server calls back into
a Ruby Rack app on a matching trigger, and your model's ActiveModel callbacks
(and any webhook blocks) run there.

This is a server-side-only concern. A pure client (or a server with no
registered webhooks) runs all of its trigger logic locally in ActiveModel and
nothing inside Parse Server.

## Why register a webhook at all

A `Parse::Object`'s ActiveModel callbacks run in the process that initiates the
save:

- A **Ruby-initiated** save (this SDK) runs `before_save`, `after_create`, etc.
  locally, before/after the REST call.
- A save from a **non-Ruby client** — the JS/Swift SDKs, a raw REST call, or the
  Parse Dashboard — never touches your Ruby process. That trigger logic is
  simply skipped server-side.

Registering a webhook closes that gap. Once Parse Server has a `beforeSave`
webhook for a class, it calls your Ruby app on every save from every client, and
your callbacks run server-side for all of them.

**The rule:** your ActiveModel logic applies to non-Ruby clients **only if the
webhook is registered.**

## ActiveModel hooks vs Parse Server triggers

The SDK exposes the full ActiveModel lifecycle on every `Parse::Object`. Parse
Server, separately, exposes a fixed set of webhook trigger types. They are not
one-to-one — the SDK maps between them.

### ActiveModel callbacks (Ruby side)

| Callback | Fires |
|----------|-------|
| `before_validation` / `after_validation` | around local validation |
| `before_save` / `after_save` | around every save (create **and** update) |
| `before_create` / `after_create` | around the first save of a new object |
| `before_update` / `after_update` | around saves of an existing object |
| `before_destroy` / `after_destroy` | around delete |

### Parse Server webhook trigger types (server side)

| Trigger | className | Notes |
|---------|-----------|-------|
| `beforeSave` / `afterSave` | a class | create **and** update |
| `beforeDelete` / `afterDelete` | a class | |
| `beforeFind` / `afterFind` | a class | |
| `beforeLogin` / `afterLogin` | `_User` | login-side hooks |
| `afterLogout` | `_Session` | |
| `beforePasswordResetRequest` | `_User` | |
| `beforeSave` / `afterSave` / `beforeDelete` / `beforeFind` / `afterFind` | `@File` | file triggers |
| `beforeConnect` | `@Connect` | LiveQuery connection (connection-global) |
| `beforeSubscribe` / `afterEvent` | a class | LiveQuery subscription / events |

### How they relate

- **`beforeSave` / `afterSave` carry the create variants.** Parse Server has **no
  `beforeCreate` / `afterCreate` trigger** — it rejects them. The SDK runs your
  `before_create` / `after_create` callbacks *inside* the `beforeSave` /
  `afterSave` handler, gated on whether the object is new. So **registering a
  `beforeSave` webhook enables both `before_save` and `before_create`**;
  registering `afterSave` enables both `after_save` and `after_create`.

  Asking for a create webhook fails fast with guidance:

  ```ruby
  Post.webhook(:after_create) { … }
  # ArgumentError: There is no after_create webhook. Register `webhook :after_save`
  # instead — your after_create ActiveModel callbacks run inside the after_save
  # handler for new objects (registering after_save enables BOTH the after_save
  # and after_create callbacks).
  ```

- **Trigger order is honored.** Within the save handler the SDK runs callbacks in
  ActiveModel order: `before_save` then `before_create` on the way in,
  `after_create` then `after_save` on the way out.

- **`@File` and `@Connect` are pseudo-classes.** File triggers register against
  the `@File` className; the connection-global LiveQuery trigger uses `@Connect`.
  The SDK accepts both for the full register/fetch/delete lifecycle.

- **`beforeFind` / `afterFind` are result-side, not object-side.** Unlike the
  save/delete triggers, a find payload carries no single `object` — `beforeFind`
  exposes the incoming `query` (via `payload.query`) and `afterFind` exposes the
  matched rows (via `payload.objects`). And unlike `afterSave` (whose return
  value Parse Server ignores), **`afterFind` is result-rewriting**: whatever the
  handler returns *replaces* the rows sent to the client, so it can filter or
  redact results. It also adds a webhook round-trip to every matching query, so
  register it deliberately.

  One non-obvious detail the SDK handles for you: **Parse Server does not put the
  class name anywhere in the find payload body** — the matched objects omit
  `className` and there is no top-level one. The SDK derives the class from the
  webhook URL path (`<endpoint>/<trigger>/<className>`) so your `afterFind` /
  `beforeFind` block routes correctly and `payload.parse_class` resolves. (If you
  build a `Payload` yourself in a test, pass the class as the second argument:
  `Parse::Webhooks::Payload.new(body, "MyClass")`.)

  Because the class is resolved from the route, declared `:vector` columns are
  stripped from `afterFind` `payload.objects` by default, exactly as they are
  from `object`/`original`/`update` on the other triggers (a
  `vector_visibility :public` class keeps them). One consequence to keep in
  mind: an `afterFind` handler that returns `payload.objects` to pass results
  through passes the *vector-scrubbed* rows on to the client — which matches the
  `as_json` default (an `owner_only` class never exposes vectors anyway). Return
  your own array if you need different columns.

- **Auth triggers (`beforeLogin` / `afterLogin` / `afterLogout` /
  `beforePasswordResetRequest`) and LiveQuery triggers (`beforeConnect` /
  `beforeSubscribe` / `afterEvent`) are routed as first-class shapes** — they
  are not object save/delete triggers, so **none of them run ActiveModel
  `save` / `create` / `destroy` callbacks**, even the login/logout/reset ones
  that carry a `_User` or `_Session`.

  Identify them with the matching predicates — `before_login?`, `after_login?`,
  `after_logout?`, `before_password_reset_request?`, `before_connect?`,
  `before_subscribe?`, `after_event?` — or the category helpers `auth_trigger?`
  / `live_query_trigger?`. Useful accessors by shape:

  | Trigger | what the payload carries |
  |---------|--------------------------|
  | `beforeLogin` | the user being authenticated as **`payload.parse_object`** (a `_User`). `payload.user` is **`nil`** — auth isn't complete yet. |
  | `afterLogin` | both `payload.parse_object` and `payload.user` (the now-authenticated user). |
  | `afterLogout` | the session as `payload.parse_object` (a `_Session`). |
  | `beforePasswordResetRequest` | the target user as `payload.parse_object`. |
  | `beforeConnect` | connection-global: no object; the caller token (if any) in `payload.session_token`; counts in `payload.clients` / `payload.subscriptions`. |
  | `beforeSubscribe` | shaped like `beforeFind` — `payload.query` / `payload.parse_query`; className comes from the route. Caller token in `payload.session_token`. |
  | `afterEvent` | the event type in `payload.event` (`create` / `enter` / `update` / `leave` / `delete`), plus `payload.object` / `payload.original`. |

  > The login footgun: during `beforeLogin` reach for `payload.parse_object`,
  > **not** `payload.user` (which is `nil`). For connect/subscribe the live
  > session token is at the top level of the payload, not nested under a user —
  > the SDK captures it into `payload.session_token` (so `payload.user_client` /
  > `payload.user_agent` work) and keeps it out of `as_json` and the request log.

  **Response contract — what you return matters only for the `before*` ones.**
  Parse Server **ignores the response body for all seven** of these triggers
  (its webhook response handler resolves `{}` regardless). The *only* way a
  handler affects the operation is by **rejecting** it, and only the `before*`
  variants can be rejected (an `after*` trigger fires after the fact):

  ```ruby
  Parse::Webhooks.route(:before_login, "_User") do |payload|
    error!("account suspended") if payload.parse_object.suspended?  # denies login
    # returning false also denies (mapped to the error response); anything else
    # — including the user object — succeeds as a no-op
  end

  Parse::Webhooks.route(:after_event, "Post") do |payload|
    AuditLog.record(payload.event, payload.parse_id)  # observe-only; return value ignored
  end
  ```

  Note the asymmetry with `before_save`: Parse Server treats a `{success:false}`
  body as **allow** (only an `{error}` body rejects). So "return `false` to deny
  login" only works because the SDK converts that `false` into an error response
  for you. `error!(message)` is the explicit, message-carrying form.

  **LiveQuery delivery caveat.** `beforeConnect` / `beforeSubscribe` /
  `afterEvent` fire inside the LiveQuery server. They are delivered to an HTTP
  webhook **only in a co-located, single-process LiveQuery setup**; with a
  separate LiveQuery server they are in-process (`Parse.Cloud`) only.
  `beforeConnect` in particular carries a live client handle that does not
  serialize over HTTP, so it is effectively in-process-only. Register them when
  you know your topology supports it.

## Defining and registering webhooks

```ruby
Parse::Webhooks.key = ENV.fetch("PARSE_WEBHOOK_KEY") # matches Parse Server's webhookKey

class Post < Parse::Object
  property :title, :string

  before_save  :normalize           # runs server-side once beforeSave is registered
  after_create :index_for_search    # runs inside the afterSave handler for new posts

  webhook :before_save do           # optional block, in addition to callbacks
    parse_object                    # return the object (or `false` to halt the save)
  end
end
```

Register with Parse Server (once, at deploy — requires the master key).
`endpoint` is the public HTTPS URL where the Rack app is reachable:

```ruby
Parse::Webhooks.register_functions!("https://hooks.example.com/webhooks")
Parse::Webhooks.register_triggers!("https://hooks.example.com/webhooks")
```

Mount the Rack app (`config.ru`):

```ruby
require_relative "app/webhooks"
run Parse::Webhooks
```

See [`examples/webhook_server.rb`](../examples/webhook_server.rb) for a complete,
runnable setup.

## Auditing trigger coverage

The wiring above has three independent moving parts, and a callback runs
server-side only when all three line up:

1. the model's **ActiveModel callback** (`after_save :send_email`),
2. a **local webhook route** so the router has a handler to run (the
   `webhook :after_save` block, or `Parse::Webhooks.route(:after_save, "Post")`),
3. the **server trigger** registered with Parse Server (`register_triggers!`),
   so Parse Server actually POSTs to your app.

Declaring the callback alone does nothing for a non-Ruby client — the save
never touches your Ruby process. It is easy for these three to drift: a new
`after_save` callback with no block, a `webhook` block you never registered, or
a stale server trigger pointing at a class whose block was removed.

`Parse::Webhooks.trigger_audit` cross-references all three across every
registered class and reports the gaps. The server comparison reads the
master-key-only `hooks/triggers` endpoint, so it needs a master-key client;
pass `network: false` to audit callbacks against local routes only.

```ruby
puts Parse::Webhooks.trigger_audit(pretty: true)        # human-readable summary
report = Parse::Webhooks.trigger_audit                  # Hash report
Parse::Webhooks.trigger_audit(network: false)           # local-only, no master key
```

The audit emits four kinds of findings:

- **`callbacks_inert`** — a model has callbacks mapping to a trigger
  (`after_save` / `after_create` → `afterSave`, etc.) but the local block and/or
  the server trigger is missing, so they never fire for non-Ruby clients. The
  `missing:` list says which piece to add. This is the headline gap.
- **`route_not_registered`** — a local `webhook :X` block exists but the trigger
  isn't on the server, so Parse Server never calls it. Fix by running
  `register_triggers!`.
- **`orphan_server_trigger`** — a server trigger is registered but no local block
  handles it; every matching operation pays a webhook round-trip that does
  nothing.
- **`local_only_callbacks`** — informational: `before_update` / `after_update`
  and `before_validation` / `after_validation` callbacks have **no** Parse Server
  trigger that can run them (the webhook router runs only the save and create
  chains). They fire for Ruby-initiated saves but never for non-Ruby clients,
  and no registration changes that.

Wire it into CI or a deploy check to fail fast on a coverage gap:

```ruby
inert = Parse::Webhooks.trigger_audit[:summary][:findings][:callbacks_inert].to_i
abort "Webhook coverage gaps detected" if inert.positive?
```

## Returning a value from a handler

A handler block runs with `self` bound to the `Parse::Webhooks::Payload`, so
inside it you can call `parse_object`, `params`, `error!`, etc. directly. The
value the handler produces is what Parse Server receives: for `before_save`,
return the (possibly mutated) `parse_object` to allow the write, or `false` /
`error!` to reject it.

You can set that value either with an explicit `return` or by letting it be the
block's last expression — both work:

```ruby
Parse::Webhooks.route :before_save, :Post do
  post = parse_object

  return post if post.title.present?   # explicit early return
  error! "title is required"           # raise to reject the save
end

# Equivalent, using the last-expression value:
Parse::Webhooks.route :before_save, :Post do
  post = parse_object
  post.title.present? ? post : error!("title is required")
end
```

The legacy proc idioms remain valid too — `next value` and `break value` both
set the result. `return`, like anywhere in Ruby, ends the handler immediately,
so nothing written after it in the same block runs. To run work *after* the
response, use [`after_response`](#deferring-work-until-after-the-response)
rather than writing code after the `return`.

## Deferring work until after the response

`payload.after_response { … }` (alias `defer`) registers a block to run **after**
the webhook response has been sent to Parse Server — off the critical path of the
save or function the client is waiting on. The handler still returns its value
synchronously (that value is the response Parse Server acts on); the deferred
block runs afterward. Use it for follow-up work that should not add latency:
search indexing, cache warming, fan-out notifications.

```ruby
Parse::Webhooks.route :after_save, :Post do
  post = parse_object
  after_response { SearchIndex.reindex(post.id) }   # runs after the reply is sent
  post
end
```

How it runs:

- **Under Puma or Unicorn** the block is enqueued on `rack.after_reply` and runs
  once the response is flushed to the socket, on the same worker thread — so it
  adds nothing to the client's round-trip.
- **On a server without `rack.after_reply`** (e.g. WEBrick) it falls back to a
  detached thread per request with deferred work — there is no pool or cap, so
  under high request volume those threads can accumulate. Run the webhook app
  under **Puma or Unicorn in production** (both provide `rack.after_reply`, which
  runs the work on the existing worker thread with no extra thread spawned); the
  thread fallback is best treated as a development-server convenience.
- Multiple `after_response` blocks run in registration order, and each is
  isolated — one raising affects neither the response nor the others.
- `self` inside the block is the payload, so `parse_object`, `params`, etc. are
  available (it closes over the handler's scope).

Things to know before relying on it:

- **Success path only.** Deferred blocks run only when the handler produced a
  successful response. If a `before_save` rejects the write (`error!`, a raise,
  or returning `false`), its registered `after_response` blocks do **not** run.
- **"After the response" is not "after the row commits."** The block runs after
  the *response* is flushed. For `before_save` that is before Parse Server has
  committed the write; even for `after_save` the SDK does not guarantee commit
  ordering relative to the deferred block. Do not rely on the persisted row being
  readable inside it.
- **In-process and best-effort.** The work runs in the web worker and does not
  survive a restart, crash, or deploy. For work that *must* happen — payment
  capture, irreversible side effects — hand it to a durable job queue
  (Sidekiq / ActiveJob) instead; `after_response` is for latency-shedding, not
  durability.
- **Mounted-app only.** Deferred blocks are drained by the `Parse::Webhooks` Rack
  app. Invoking a handler directly (`Parse::Webhooks.run_function`, or calling
  `call_route` in a unit test) does not run them — `after_response` is a no-op
  there.
- **Capturing `user_client` / `user_agent` extends the token's lifetime.** A
  deferred block closes over the payload, so referencing `payload.user_client` /
  `payload.user_agent` (or `payload.session_token`) keeps the caller's live
  session token in memory until the block finishes — beyond the synchronous
  request. That is fine and expected when the deferred work needs to act as the
  caller; just don't capture them when the work doesn't need the user's
  authority (use a master-key client instead), so the token isn't pinned longer
  than necessary.

## Latency: webhooks are synchronous

Every registered webhook adds a **separate, synchronous HTTP round-trip** to the
client's operation. Parse Server **waits for the webhook to return before
proceeding** — and it waits even on `afterSave`, despite the afterSave return
value being a no-op.

This has direct design consequences for `afterSave` (and `afterDelete`):

- **Enqueue, don't execute.** Treat `after_save` as a place to hand work to a
  background job, not to do long-running logic inline. Anything slow here is
  added latency on every save, for every client. For in-process follow-up that
  doesn't need a durable queue, [`after_response`](#deferring-work-until-after-the-response)
  moves it off the client's round-trip; for anything that *must* happen, use a
  real job queue.
- **Avoid saving other objects during an afterSave.** Each cascading save fires
  its own webhooks, which can fire more — a latency cascade. If you must, do it
  in a background job, not inline in the handler.

`beforeSave` is necessarily inline (it can mutate or reject the write), so keep
it lean and deterministic.

## Server-side dedup: two distinct mechanisms

Two different "dedup" systems protect webhook handling. They solve different
problems — don't conflate them.

### 1. Ruby-initiated dedup (keep logic local, prevent double-runs)

When a save is initiated by **this SDK with the master key**, Parse Stack tags
the request as trusted-Ruby-initiated (an `_RB_` request-id marker plus the
master key). It has already run the model's `before_save` / `after_save` /
`after_create` ActiveModel callbacks **locally**. The webhook therefore does
**not** re-run those callbacks — that would double-fire side effects (e.g. an
`after_save :send_email` would send two emails per save).

The intent is to keep trigger logic local when possible and run it exactly once.
Note that any logic in the **webhook block itself** still runs; only the
duplicate ActiveModel callback pass is skipped. A spoofed `_RB_` marker without
the master key does not get this treatment — the callbacks run in the webhook as
usual.

### 2. Server-initiated replay / freshness protection (inbound)

This protects the webhook endpoint against **replayed inbound POSTs** —
`lib/parse/webhooks/replay_protection.rb`:

- **Always-on body + request-id dedup.** A bounded LRU records a digest of each
  `(request_id, body)`; a duplicate seen within `replay_window_seconds` is
  rejected with `"Webhook replay detected."`. No cooperation from Parse Server is
  required; this stops in-window replays.
- **Opt-in HMAC freshness verification.** Set a `signing_secret` and the receiver
  verifies two headers:
  - `X-Parse-Webhook-Timestamp` — Unix epoch seconds; requests outside
    `signing_max_skew_seconds` (default 300) are rejected as stale.
  - `X-Parse-Webhook-Signature` — hex HMAC-SHA256 of `"#{timestamp}.#{body}"`
    keyed with the signing secret.

```ruby
Parse::Webhooks::ReplayProtection.signing_secret = ENV["PARSE_WEBHOOK_SIGNING_SECRET"]
Parse::Webhooks::ReplayProtection.replay_window_seconds = 120
Parse::Webhooks::ReplayProtection.signing_max_skew_seconds = 300
```

This is **inbound** protection and is unrelated to request **idempotency**
(`X-Parse-Request-Id`), which dedups the SDK's own **outbound** retries on the
Parse Server side. Different direction, different mechanism.
