# Caching

Parse Stack Next has several independent caches. They do not share a
configuration knob, a TTL, or a backend, and only some of them are shared
across processes. This document describes each one: what it stores, how its key
is built, what bounds its staleness, and what happens when its backend goes
away.

If you only want the short version: configure `cache:` and `expires:` for the
HTTP response cache, turn on `cache_keyspace: true` so clearing is scoped, and
remember that every other cache in the table below is process-local unless you
explicitly move it to Redis.

## Overview

| Plane | Stores | Key | Default TTL | Shared across workers |
|---|---|---|---|---|
| HTTP response cache (`Parse::Middleware::Caching`) | body and headers of successful `GET` responses | request URL plus an auth discriminator | `expires:` (3 seconds) | Only if the store is (Redis yes, Moneta memory no) |
| Identity plane (`view.identity`) | session token to user id | token, under the `idn` keyspace family | `client.authorization.identity_cache_ttl` (3600) | Yes |
| Role plane (`view.roles`) | user id to role-name closure | user id, under the `role` keyspace family | `client.authorization.role_cache_ttl` (30) | Yes |
| Authorization default caches (`Parse::Authorization::MemoryCache`) | the same two mappings | token / user id | same two TTLs | No |
| Upstream role reader (`store.upstream_roles`) | nothing, it is read-only, and role resolution does not consume it | `<appId>:role:<userId>` written by Parse Server | n/a, entries age out upstream | Reads Parse Server's database |
| CLP schema cache (`Parse::CLPScope`) | class-level permissions per class | class name | `POSITIVE_TTL` 3600, `NEGATIVE_TTL` 5 | No |
| Atlas index catalog (`Parse::AtlasSearch::IndexManager`) | search index definitions per collection | collection name | `DEFAULT_CACHE_TTL` 300 | No |
| Embedding cache (`Parse::Embeddings::Cache`) | query-side embedding vectors | provider, model, dimensions, input type, digest of input | 600, disabled by default | No, unless given a Moneta store |
| Audience cache (`Parse::Audience`) | audience objects by name | audience name | `DEFAULT_CACHE_TTL` 300 | No |
| Rank-fusion probe (`Parse::VectorSearch::Hybrid`) | whether the cluster supports `$rankFusion` | collection name | `PROBE_CACHE_TTL` 3600 | No |
| Model registry (`Parse::Model`) | Parse class name to Ruby class | class name | none | No |
| Known classes (`Parse::Query.known_parse_classes`) | class names from the schema endpoint | n/a, one list | none, memoized once | No |
| Client config (`Parse::Client#config`) | the application config hash | n/a, per client | none, until `config!` | No |
| Webhook replay guard (`Parse::Webhooks::ReplayProtection`) | digests of seen webhook deliveries | request id and body digest | `DEFAULT_REPLAY_WINDOW` 300, 10,000 entries | No |
| Create-locks and `Parse::Lock` | lock ownership tokens | `parse-stack:foc:v1:<digest>`, `parse-stack:lock:v1:<digest>` | 3 seconds, capped at 30 | Only on a Redis-backed store |

Process-local means one copy per Ruby process. Two Puma workers, or a web dyno
and a worker dyno, each keep their own, and nothing invalidates the other's.
That is fine for a schema cache and dangerous for anything you expect to
revoke.

## Setting up a backend

### Any Moneta store

The `cache:` option accepts any [Moneta](https://github.com/minad/moneta) store,
or anything that responds to `[]`, `key?`, `delete`, and `store`. The client
validates that surface at setup and raises `ArgumentError` otherwise.

```ruby
Parse.setup(
  server_url: ENV.fetch("PARSE_SERVER_URL"),
  application_id: ENV.fetch("PARSE_APP_ID"),
  master_key: ENV.fetch("PARSE_MASTER_KEY"),
  cache: Moneta.new(:Memory),
  expires: 10,
)
```

There is no default store. With `cache:` unset, the caching middleware is never
added to the connection and nothing is cached. With a store configured but
`expires:` at 0 or unset, the client warns and skips the middleware entirely,
which is the most common reason a cache appears to do nothing. The default when
you do pass a store is `expires: 3`.

A `Moneta.new(:Memory)` store is process-local. It is a reasonable default for
tests and for a single-process deployment, and it is the wrong choice behind
multiple workers: a write through worker A does not invalidate worker B's copy,
so B keeps serving the stale body until its own TTL expires.

### `Parse::Cache::Redis`

The bundled wrapper adds a connection pool, an optional namespace that flows
automatically into the client, JSON value encoding, atomic lock primitives, and
scoped clearing.

```ruby
store = Parse::Cache::Redis.new(
  url: "redis://localhost:6379/0",
  namespace: "web",
  pool_size: 10,
)

Parse.setup(cache: store, expires: 10, cache_keyspace: true, ...)
```

Passing a `redis://` URL string to `cache:` builds the same wrapper for you.

Use the wrapper rather than a bare `Moneta.new(:Redis, ...)`. Moneta serializes
values with Marshal by default, so every cache read would `Marshal.load` bytes
returned by Redis, which is a remote-code-execution primitive when that Redis is
shared, unauthenticated, or reachable over a plaintext connection. The wrapper
forces `value_serializer: nil` and encodes values as JSON itself. If you supply
your own Moneta store, build it with `value_serializer: nil`.

The wrapper refuses a Moneta `prefix:` option, because it would rewrite the
physical key layout underneath the SCAN patterns that scoped clearing depends
on. Use `namespace:` instead.

### Pool sizing

Each pooled backend is one Redis connection, and each cache operation checks one
out. Per Faraday request:

* cache hit: `key?` then `[]`, so 2 checkouts
* `GET` miss followed by a successful store: `key?`, three variant deletes, and
  one `store` in the completion callback, so up to 5 checkouts
* non-`GET` write: the variant deletes, so about 3 checkouts, plus one more for
  the scoped SCAN when a keyspace is configured

The worst case is the write-through-after-miss path, not the hit path. Start at
`pool_size = RAILS_MAX_THREADS` and raise it if you see
`ConnectionPool::TimeoutError` on the `parse.cache.error` notification. The
checkout timeout defaults to 5 seconds, and the middleware turns that error into
a passthrough request rather than raising to your code.

### The `expires: false` caveat

The wrapper passes `expires: true` to the Moneta Redis adapter. That flag is
what makes the adapter honor the per-key TTL the caching middleware supplies on
each `store` call. Passing `expires: false` yourself disables it, and the
adapter then ignores every per-call TTL, so cached responses live until
something explicitly deletes them.

That is almost always wrong here. Response-cache entries are scoped to an auth
identity, so entries written for a session token would outlive the token's
validity with no bound at all. Only pass `expires: false` if you are managing
key lifetime entirely outside the SDK.

## Response caching

There is one HTTP response cache. It is a Faraday middleware, it stores the
body and headers of successful `GET` responses, and it keys them by the request
URL.

This is the point most people get wrong: "query caching" and "object caching"
are not two systems. `Post.find("abc")` issues a `GET` to
`/classes/Post/abc`, and `Post.query(status: "published").results` issues a
`GET` to `/classes/Post/?where=...`. Both go through the same middleware and
land in the same store. The only difference is the URL being cached, and the
default opt-in posture described below.

A response is stored only when all of the following hold:

* the method is `GET`
* the status is 200, 203, 300, 301, or 302
* the body is present
* the `content-length` response header is between 20 and 1,250,000

The `content-length` requirement is a real constraint, not a formality. A
response that arrives without that header is not cached, because the middleware
reads the header and compares the integer value.

### Opt-in, and `Parse.default_query_cache`

Object fetches cache by default once a store is configured. Queries do not: a
new `Parse::Query` initializes its `cache` attribute from
`Parse.default_query_cache`, which is `false`, and a query with caching off
sends `Cache-Control: no-cache`, which turns the middleware into a passthrough
for that request.

```ruby
# Opt in per query.
Post.all(limit: 500, cache: true)

# Opt in for a specific duration, in seconds.
Post.query(:published.eq => true, :cache => 300).results

# Opt out for a single query.
Post.query(status: "draft", cache: false).results

# Flip the global default to opt-out behavior.
Parse.default_query_cache = true
```

The client warns once at setup when the middleware is enabled while
`Parse.default_query_cache` is false, so that the opt-in behavior is not a
surprise.

### Per-request headers

The client translates the `cache:` request option into three headers the
middleware consumes and then strips before the request goes out:

| Option | Header | Effect |
|---|---|---|
| `cache: false` | `Cache-Control: no-cache` | Neither read nor write for this request |
| `cache: <Integer>` | `X-Parse-Stack-Cache-Expires` | Overrides the TTL for this request |
| `cache: :write_only` | `X-Parse-Stack-Cache-Write-Only` | Skip the read, still write the fresh response |
| `cache: true` | none | Use the middleware default TTL |

Write-only mode is what `fetch!` and `reload!` use by default, so a refresh
always contacts the server and simultaneously refreshes the cached copy for
later readers. Set `Parse.cache_write_on_fetch = false` to make those calls
bypass the cache in both directions instead. `fetch_cache!` is the opposite:
`fetch!` with `cache: true`, which will accept a cached body.

### Invalidation on write

Any non-`GET` request evicts the cached entry for the same URL. With a keyspace
configured, the eviction is a pattern delete across every auth variant of that
resource, which reaches entries belonging to sessions this process has never
seen. Without a keyspace, the middleware can only name the variants it knows
about (the caller's own entry, the anonymous one, and the master-key one), so
other sessions' copies survive until their TTL.

Invalidation matches the exact URL, and query URLs carry their `where`
parameters. Saving one `Post` therefore evicts `/classes/Post/<id>` but not the
cached result of `/classes/Post/?where={"status":"published"}`. Cached list
results are bounded by TTL alone. Keep `expires:` short if your application
caches queries.

A cache miss on a `GET` also opportunistically deletes stale sibling variants of
the same URL, so an old entry from a different request flavor does not linger.

### Idempotency and retries

Request idempotency and response caching are mostly orthogonal. Parse Server's
idempotency applies to writes, and it is off by default and labelled
experimental there; the middleware caches only `GET` responses, so on the
caching path the two never meet. Three points are worth knowing anyway.

* Cache keys are built from the URL digest and the auth discriminator only. No
  request header contributes, so a per-request id cannot fragment the cache into
  one entry per request.
* A write the server rejects as a duplicate still triggers the non-`GET`
  invalidation on this side. Note that Parse Server rejects such a request with
  `DUPLICATE_REQUEST` rather than replaying the original response, so the extra
  eviction is wasted work, never a wrong answer.
* Ordering matters if a retry layer is ever added below the cache. The caching
  middleware sits directly above the adapter, and a hit returns before the
  adapter runs, so anything registered below it does not execute on a hit.

## Auth scoping of cached responses

The cache key carries an auth discriminator, and this is a correctness property
rather than an optimization.

The same URL returns different bodies to different callers. A master-key request
bypasses ACL, class-level permissions, and `protectedFields`, so it receives a
strictly fuller body than a session request. Two different sessions can also
differ from each other, through row ACLs and through `protectedFields` entity
rules. Collapsing those into one entry would hand privileged fields to an
unprivileged caller straight out of the cache.

So the key includes one of three things:

* `mk` for a master-key request
* the first 32 hex characters of the SHA-256 of the session token
* `anon` for an unauthenticated request

Raw session tokens never become key material. With a keyspace configured, the
URL digest is placed before the discriminator, so every auth variant of one
resource shares a prefix, which is exactly what lets a write invalidate the
resource for all callers with a single pattern delete.

One consequence worth planning for: a heavily multi-user endpoint produces one
cache entry per session per URL. Cardinality scales with active sessions, not
with distinct resources.

## Identity and role caching

Mongo-direct queries do not go through Parse Server, so Parse Server's
per-request ACL enforcement does not apply to them. The SDK enforces ACL itself
on that path, and to do so it needs two facts about the caller:

1. the `_User.objectId` behind the session token
2. the transitive closure of role names that user inherits

Both are expensive. The first is a `/users/me` round-trip. The second walks the
`_Role` graph. `Parse::Authorization` resolves and caches them, one context per
`Parse::Client`, reachable as `client.authorization`. Three consumers reach
through it: Atlas Search, `Parse::MongoDB.aggregate`-backed aggregates, and
direct queries. The result feeds `permission_strings`, which is the sole input
to both the `_rperm` match and the class-level-permission gate used by
`Parse::ACLScope`, `Parse::AtlasSearch`, `Query#results_direct`, and
`Query#count_direct`.

State lives on the client rather than at module level because a token belongs
to one application. A set of module-level globals would let a token minted by
a secondary application resolve against the default application's caches, or
worse, match a different user with the same token shape there. `client:` is
therefore required with no default below the `Parse::Authorization.configure`
boundary described next.

### The process-local defaults

Out of the box both caches are `Parse::Authorization::MemoryCache`, a
mutex-guarded hash with per-entry TTL. TTLs come from
`client.authorization.identity_cache_ttl` (3600 seconds) and
`client.authorization.role_cache_ttl` (30 seconds). The identity plane is named
for what it stores: one user id per token, never a `_Session` row or session
object, so `identity_cache` replaces the older `session_cache` name that
invited readers to reason about `_Session` semantics that were never involved.
The asymmetry between the two TTLs is deliberate: a stale token-to-user mapping
only extends the life of a revoked session, while a stale role closure produces
a wrong access-control decision, so the role TTL is short enough that a grant
or revoke lands within seconds.

These caches are per process. Each Puma worker and each dyno resolves and holds
its own copy, and `context.invalidate` in one process does not reach the
others. Expired entries are dropped lazily when the key is next read, so a
process that sees a large number of distinct tokens holds them until each is
read again or until `context.reset_caches!` runs.

### The shared planes

A keyspaced `Parse::Cache::Redis` exposes two planes shaped for those slots:

```ruby
store = Parse::Cache::Redis.new(url: "redis://localhost:6379/0")
Parse.setup(cache: store, expires: 10, cache_keyspace: true, ...)

view = Parse.client.sdk_cache   # the scoped view derived at setup
Parse::Authorization.configure(
  identity_cache: view.identity(ttl: 3600),
  role_cache:     view.roles(ttl: 30),
)
```

`Parse::Authorization.configure` is a boundary convenience for the common
single-application case: it configures the default client's context, the same
one `Parse.client.authorization` returns. It is not the source of truth, the
context is. For a named secondary client, configure its own context directly
instead:

```ruby
other_client.authorization.configure(
  identity_cache: view.identity(ttl: 3600),
  role_cache:     view.roles(ttl: 30),
)
```

Both require `cache_keyspace: true`; without a keyspace they raise
`ArgumentError` rather than writing into an unscoped key space. Each plane
writes inside its own keyspace family, so clearing one reaches neither the other
nor the response cache.

Two behaviors to know before you rely on these:

* Values round-trip through JSON. The identity plane stores a user id string,
  which survives that intact. The role plane receives a Ruby `Set` from the
  resolver, and the resolver accepts a cached role value only when it reads back
  as a `Set`, which a JSON round-trip does not produce. In practice the shared
  role plane does not serve hits to the Atlas Search resolver today, and role
  lookups fall back to the role-graph walk. The process-local default does serve
  hits, because it holds the object itself.
* Sub-TTL revocation is automatic for both triggers, as long as
  `client.authorization.identity_cache` and `client.authorization.role_cache`
  are set to planes from the SAME view `Parse::Cache::Invalidation` was
  installed against (the pattern shown above: both derived from
  `Parse.client.sdk_cache`). The `after_logout` trigger invalidates the identity
  entry using the same raw session token the resolver stores it under, so a
  logout on any client (mobile SDK, dashboard, Node cloud code) evicts the
  shared entry immediately rather than waiting out `identity_cache_ttl`.
  Likewise, a `_User` write bumps that user's generation, and the resolver
  checks it on every read, so a stale entry is rejected the moment the bump
  lands rather than surviving until the TTL expires. You still may want an
  explicit `client.authorization.invalidate(token)` /
  `.invalidate_user_roles(user_id)` call from your own logout / role-mutation
  code paths for a deployment that has not wired up the webhook endpoint the
  triggers depend on. The deprecated `Parse::AtlasSearch::Session.invalidate` /
  `.invalidate_user_roles` forms still work through 5.x: they delegate to the
  default client's context, so they can only ever address `Parse.client`.

On a Redis outage these planes behave differently from the response cache.
The response cache degrades to a passthrough request; the identity and role
planes do not swallow connection errors, so a scoped mongo-direct query raises
rather than silently running with reduced permissions. That fails closed, which
is the right direction, but it does mean the planes are on the critical path for
scoped queries once you install them.

## Reading Parse Server's own role cache

Parse Server caches each user's transitive role closure under
`<appId>:role:<userId>` as a JSON array of `role:NAME` strings. Attaching to it
lets you reuse the value the server itself computed instead of walking the
graph, which is most useful when a webhook payload already supplies a trusted
user id. This is optional, and nothing in the SDK reads it unless you attach it
and call it.

**Role resolution does not consume it.** `Parse::Authorization` always computes
its own closure, and the value read here never changes an ACL decision. The
only built-in integration is the compare-only path below. If you want the
upstream value, call `roles_for` yourself and decide what to do with it. The
reason for the split is that the moment a value is consumed it becomes an
authorization input, and this one comes from a database the SDK does not own,
so it stays observable until the two closures have been reconciled against your
own traffic:

```ruby
Parse::Authorization.configure(
  upstream_role_reader:   store.scoped(keyspace).upstream_roles,
  compare_upstream_roles: true,
)

ActiveSupport::Notifications.subscribe("parse.cache.role_compare") do |*, payload|
  # payload: user_digest, matched, upstream_nil, computed_size,
  #          upstream_size, only_in_ours, only_in_upstream
  Metrics.increment("role_compare.#{payload[:matched] ? "match" : "divergent"}")
end
```

Role names and raw user ids are kept out of the payload; the user is
identified by a truncated digest.

```ruby
store = Parse::Cache::Redis.new(
  url:             "redis://localhost:6379/0",  # the SDK's own cache
  parse_cache_url: "redis://localhost:6379/1",  # Parse Server's cache, read-only
)

store.verify_upstream_isolation!
roles = store.upstream_roles.roles_for(user_id)  # Set of bare role names, or nil
```

**The two URLs must address different Redis databases.** On released Parse
Server, a `_Role` write clears the cache with `FLUSHDB`. On a shared database
that deletes the SDK's cached responses and, more seriously, its
`parse-stack:foc:v1:*` create-locks, so a `first_or_create!` holding a lock at
that moment silently loses mutual exclusion. See
[parse-server#10617](https://github.com/parse-community/parse-server/issues/10617).

`verify_upstream_isolation!` answers in two steps. It scans the SDK's own
database for a key shaped like one Parse Server would have written, and if that
finds nothing it writes a random sentinel to the SDK's database and asks the
upstream connection to read it back. The scan alone can only prove sharing: an
empty result looks the same on a separate database and on a shared one where
Parse Server has not cached a role closure yet, which is the state of a stack
you have just deployed and are most likely to be checking. Only the sentinel
establishes the negative.

| Return | Meaning |
|---|---|
| `true` | Isolation established. The sentinel was not visible upstream. |
| `false` | Sharing established, and warned about. |
| `:unknown` | Neither could be shown. Truthy, so `if store.verify_upstream_isolation!` behaves as before. |

`:unknown` is what the restricted credential below produces: the sentinel read
comes back NOPERM, and a denial says nothing about which database denied it.
Grant the reader `GET` on `parse-stack:probe:*` if you want a definite answer,
or confirm the two databases differ by hand.

Comparing URL strings cannot substitute for any of this: `localhost` against
`127.0.0.1`, CNAMEs, Sentinel and Cluster topologies, and a database selected
outside the URL all defeat it. It warns rather than refusing to boot, because
the hazard disappears on a server carrying the scoped-clear fix, and it routes
through the same `on_degraded:` handling as the lock code so you can escalate
it to a raise.

The attachment is strictly read-only. The SDK never writes that keyspace,
because its own closure is depth-capped while Parse Server's is not, and writing
a subset into a cache the server treats as authoritative would under-permission
users.

Every failure degrades to a miss, and the caller recomputes: a missing key,
malformed JSON, a value that is not an array of `role:`-prefixed strings, more
than 4096 roles, a role name longer than 256 characters, a remaining TTL that
cannot be read or exceeds 60 seconds, an entry older than the SDK's last role
invalidation, or any transport error. It never fails open.

Reading that database makes it part of your authorization trust base, since
those role names feed `permission_strings`. Restrict the credential:

```
ACL SETUSER parse-stack-role-reader on >SECRET \
  ~<appId>:role:* resetchannels -@all +get +pttl
```

`+pttl` is required alongside `+get`. The freshness check derives an entry's
write time from its remaining TTL, and cannot run without it.

## Invalidation

Four mechanisms bound staleness. They stack; none of them replaces the TTL.

**Writes through this SDK.** Every non-`GET` evicts the response-cache entries
for that exact URL, as described above.

**Webhook triggers.** When a keyspace is configured, `Parse::Cache::Invalidation`
registers triggers so that a change made by any client, including a mobile SDK,
the dashboard, or Node cloud code, invalidates the planes the same way an SDK
write does:

| Trigger | Class | Effect |
|---|---|---|
| `after_save`, `after_delete` | `_Role` | Clear the whole role plane and stamp its invalidation epoch |
| `after_save`, `after_delete` | `_User` | Bump that user's identity generation |
| `after_logout` | `_Session` | Invalidate the identity entry for that token digest |

The role plane is cleared wholesale rather than per user, because a role write
does not say which users it affected: membership and hierarchy arrive as
relation deltas, and the cached value is a flattened closure, so a change to a
parent role reaches every member of every child. Under a scoped SCAN that is
cheap. The epoch stamp exists so that a role entry read from Parse Server's own
cache, which is not cleared on a `_Role` delete, is rejected if it predates the
invalidation.

These triggers require a webhook endpoint that Parse Server can reach and that
you have registered. Where that is not the case, the TTL is the only bound. Pass
`cache_invalidation_hooks: false` to skip registration.

**Explicit calls.** `client.authorization.invalidate(token)`,
`client.authorization.invalidate_user_roles(user_id)`, and
`client.authorization.reset_caches!` operate on whichever caches are installed
in that client's context. The deprecated `Parse::AtlasSearch::Session.invalidate`,
`.invalidate_user_roles`, and `.reset_caches!` forms still work through 5.x:
they delegate to the default client's context and are slated for removal in
6.0. `Parse::CLPScope.invalidate!(class_name)` and
`Parse::AtlasSearch.refresh_indexes(collection)` do the same for their planes.

**TTL.** Everything else. In particular: cached query results after an unrelated
write, the CLP schema cache within its hour, the Atlas index catalog within its
five minutes, and identity entries in a process whose webhook did not fire.

## Locking

`Parse::Lock` and the internal create-lock used by `first_or_create!` and
`create_or_update!` share the cache backend, so their behavior depends on how
you configured it.

`first_or_create!` derives a key from the class name, the auth context, and the
canonicalized query attributes, then holds `parse-stack:foc:v1:<digest>` for the
duration of the find-and-create. `Parse::Lock.acquire` does the same for a key
you supply, under `parse-stack:lock:v1:<digest>`. The prefixes differ so the two
namespaces cannot collide even for identical names.

```ruby
Parse::Lock.acquire("import:#{batch_id}", ttl: 10) do
  run_batch_import(batch_id)
end

Subscription.first_or_create!({ workspace: workspace, plan: "pro" })
```

Defaults: `ttl` 3 seconds, clamped to 1 to 30; `wait` 2 seconds, clamped to 0 to
30. The TTL is a crash-recovery floor, not a cap on your work. If the critical
section outruns the TTL, the lease expires while you are still inside it, a
second caller can acquire, and `Parse::Lock` warns on release that mutual
exclusion was not guaranteed for the overrun window. There is no fencing token
the protected resource checks, so this is mutual exclusion with a deadline, not
exactly-once execution. Make the protected operation idempotent, and keep a
unique index on the constrained tuple as the correctness floor beneath
`first_or_create!`.

Key derivation uses HMAC-SHA256 when a secret is configured, through
`PARSE_STACK_LOCK_SECRET` or `Parse.synchronize_create_secret`, and plain
SHA-256 otherwise. With a cross-process store and no configured secret the SDK
warns once, because lock keys are then deterministic: anyone with write access
to the same Redis can plant a key under a guessable digest and pin that lock
until TTL expiry. Set the secret, or point
`Parse.synchronize_create_store` at a Redis database separate from the response
cache.

### Degraded stores

A store is degraded when it is nil, when it does not implement `create`, or when
the bottom Moneta adapter is a Memory or Null adapter. In that case the lock
falls back to a per-key in-process `Mutex`: threads inside one process serialize,
and separate processes do not. `on_degraded:` decides how loudly you hear about
it.

| Mode | Behavior |
|---|---|
| `:warn` | One warning per call, the default |
| `:warn_throttled` | One warning per process per 60 seconds |
| `:proceed` | Silent |
| `:raise` | `Parse::Lock::UnavailableError` or `Parse::CreateLockUnavailableError` |

Use `:raise` in a multi-worker deployment. The failure that is easy to miss is
asymmetric degradation: if one worker has `Parse.synchronize_create_store` wired
to Redis and another does not, they derive different keys for the same logical
lock and quietly fail to exclude each other, and only the degraded worker warns.

On a Redis outage, acquisition errors are treated as "someone else holds it", so
the caller polls until the `wait` budget elapses and then raises a timeout. The
block never runs without the lock.

## Multi-tenancy

Two mechanisms, at different levels.

`namespace:` on the wrapper (or `cache_namespace:` on `Parse.setup`) is a static
prefix, one per client. Use it when several applications share a Redis database.
A wrapper's namespace flows into the client automatically, and an explicit
`cache_namespace:` wins if both are set.

`Parse.with_cache_tenant` is dynamic and ambient, held in fiber-local state for
the duration of a block. Use it when one client serves many tenants.

```ruby
Parse.with_cache_tenant(tenant_id) do
  Post.query(:published.eq => true, :cache => 60).results
end
```

The tenant composes into the key between the namespace and the auth
discriminator, as `T:<tenant>`, which keeps tenant prefixes unambiguously
distinct from the 32-character hex of a token digest and from `mk`. Scope values
must match `/\A[A-Za-z0-9_\-]{1,256}\z/`; a colon is refused, because
`with_cache_tenant("a:T:b")` would otherwise be indistinguishable from a nested
pair of scopes and would break the SCAN isolation the feature exists to provide.
Passing `nil` clears the scope for that block.

This is a cache-key boundary, not an access-control boundary. It keeps tenant A's
cached response from being served on tenant B's request. Data-layer isolation is
still the job of ACL, class-level permissions, and per-class agent scoping.

Clearing is scoped along the same layout. `family:` / `tenant:` / `scope:` are
scoped-view operations. Call them on `Parse.client.sdk_cache` (the view the
client derived at setup with `cache_keyspace: true`), never on `Parse.cache`
or a bare backend, neither of which has a keyspace to scope against.

What happens if you get that wrong depends on the store, and the safer
outcome is not the default one:

- **`Parse::Cache::Redis`** raises `ArgumentError`, because it can see that
  it has no keyspace to interpret `family:` against and refuses to widen a
  narrowing request into a `FLUSHDB`.
- **Any other Moneta store** does something worse and quieter. `Moneta#clear`
  takes an options hash and ignores keys it does not recognize, so
  `store.clear(family: :role)` clears the ENTIRE store and returns normally.

Route the call through `sdk_cache` rather than relying on the store to catch
the mistake:

```ruby
Parse.client.clear_cache!                             # everything this client wrote
Parse.client.sdk_cache.clear(family: :role)           # one family
Parse.client.sdk_cache.clear(family: :cache, tenant: "acme") # one tenant of one family
Parse.client.sdk_cache.clear(scope: "legacy_prefix")  # an explicit prefix
store.flush_db!                                       # the whole database, ops tooling only
```

A `tenant:` requires a `family:`, since the tenant segment sits inside the
family. Scope strings are rejected if they contain Redis glob metacharacters, so
`scope: "*"` cannot become a full flush by accident.

## Operations and troubleshooting

### The cache seems inert

Work down this list.

1. Is `expires:` set and greater than 0? A store with no expiry means the
   middleware was never installed, and the client warns at setup.
2. Is this a query? Queries do not cache unless you pass `cache: true` or set
   `Parse.default_query_cache = true`.
3. Is the response cacheable? It needs a `GET`, a cacheable status, a non-empty
   body, and a `content-length` between 20 and 1,250,000.
4. Is something sending `cache: false`? Health checks and count-only probes do
   so deliberately.
5. Is this a `fetch!` or `reload!`? Those default to write-only mode, which by
   design never reads from the cache. Use `fetch_cache!` to accept a cached body.
6. Is the caller a different session? Entries are not shared across auth
   identities, so the first request for each session is always a miss.
7. Is the store process-local? A Moneta memory store behind several workers hits
   only when the same worker handles the repeat.
8. Has something set `Parse::Middleware::Caching.enabled = false`? That is the
   process-wide off switch.

To watch it live, set `Parse::Middleware::Caching.logging = true`, which prints
a line per hit, or subscribe to the notifications below. Hits also carry an
`X-Cache-Response` header on the response.

### Instrumentation

All events are `ActiveSupport::Notifications`.

| Event | Payload |
|---|---|
| `parse.cache.hit` | `event`, `namespace`, `cache_tenant`, `method`, `url_path` |
| `parse.cache.miss` | the same, plus `reason` when the miss was forced |
| `parse.cache.store` | the same, plus `duration_ms` |
| `parse.cache.delete` | the same, emitted on an invalidating write |
| `parse.cache.error` | the same, plus `error` (the exception class name only) |
| `parse.cache.evict` | `pattern_digest`, `deleted`, `duration_ms` |
| `parse.synchronize_create.acquired` | `key_digest`, `wait_ms` |
| `parse.synchronize_create.contended` | `key_digest`, `elapsed_ms` |
| `parse.synchronize_create.timeout` | `key_digest`, `waited_ms` |
| `parse.synchronize_create.released` | `key_digest`, `held_ms` |
| `parse.embeddings.embed` | provider, model, dimensions, and `cached: true` on a cache hit |

The payloads are deliberately reduced. Cache keys are never emitted, because
they contain a hashed session-token prefix that would be a side channel for
enumerating which user has data at which URL. URLs appear as path only, since
Parse encodes query JSON into the query string. Errors appear as a class name,
never a message or backtrace.

Subscribers run synchronously on the request thread. A blocking subscriber
blocks every cached request for as long as it runs, and an exception raised
inside one surfaces as a request failure. Keep them to counter increments or
non-blocking sinks.

### Safe and unsafe clearing

`Parse::Client#clear_cache!` calls `clear` on the store. What that means depends
on the store:

* With a keyspace configured, it is a scoped SCAN and delete over this client's
  own keys. This is the safe case, and the reason to set `cache_keyspace: true`.
* With no keyspace but a namespace, it is a scoped SCAN over `<namespace>:*`.
* With neither, `Parse::Cache::Redis` falls back to `FLUSHDB`, and a plain
  Moneta store clears everything it holds.

That fallback is the dangerous one on a shared database. It removes other
applications' data, and it removes the SDK's own `parse-stack:foc:v1:*`
create-locks, so any `first_or_create!` holding one at that moment loses its
mutual exclusion without any error being raised.

Scoped eviction uses `UNLINK` where the client supports it, so a large clear does
not stall the server the way `DEL` would, and it reports what it removed on
`parse.cache.evict`. `flush_db!` remains available as the explicit, deliberate
full flush for tooling that owns the whole database.

### The other caches

Most of the remaining planes have a targeted reset, and all of them are
process-local, so a reset applies to the calling process only.

```ruby
Parse::CLPScope.invalidate!("Post")            # one class
Parse::CLPScope.reset_cache!                   # all classes
Parse::CLPScope.cache_stats                    # size and class names

Parse::AtlasSearch.refresh_indexes("Post")     # one collection, or nil for all
Parse::AtlasSearch::IndexManager.cache_ttl = 60

Parse::Embeddings::Cache.enable!(max_entries: 2048, ttl: 600)
Parse::Embeddings::Cache.stats                 # enabled, hits, misses, size
Parse::Embeddings::Cache.clear!

Parse::Audience.cache_ttl = 600
Parse::Audience.clear_cache!

Parse::VectorSearch::Hybrid.clear_probe_cache
Parse::Query.reset_known_parse_classes!
Parse.client.config!                           # force re-fetch of the app config
```

Two of these deserve a note. The CLP cache fails closed: when a schema fetch
fails, the class is recorded as unresolvable for 5 seconds and every non-master
query against it is refused, rather than being allowed to run with no row
filtering. And the embedding cache is disabled by default; when you enable it
with a shared Moneta store, build that store with `value_serializer: nil` for
the same Marshal reason described earlier. Its keys hash the input text, so
plaintext never lands in the backing store.
