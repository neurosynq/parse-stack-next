# Direct MongoDB Integration Guide

Parse Stack can talk to MongoDB directly, bypassing Parse Server's REST
layer for read-heavy workloads. This guide covers the configuration, the
read paths, the storage-format details you need to know to write working
aggregation pipelines, and the `parse_reference` optimization that makes
multi-collection `$lookup` joins fast.

Direct MongoDB is **read-only**. Writes must go through Parse Server so
beforeSave/afterSave hooks, ACLs, and schema validation still apply.

**v4.4.0:** the direct read path now applies row-level ACL, Class-Level
Permissions, and `protectedFields` enforcement SDK-side when the caller
declares a scope (`session_token:`, `acl_user:`, or `acl_role:`). See
[Security](#security) for the full enforcement contract. Master-key
calls and unscoped calls still bypass these layers — they're the
explicit opt-out for analytics and admin workloads.

---

## When to use it

The direct path is the right tool when one or more of the following is
true:

- The query reads a high-cardinality result set and the REST round-trip
  dominates latency.
- You need an aggregation pipeline (`$group`, `$bucket`, `$facet`,
  `$lookup`) that Parse Server's `/aggregate` endpoint doesn't accept or
  doesn't pass through cleanly. **Note:** Parse Server's REST aggregate
  requires master key AND enforces neither ACL nor CLP, so any
  user-context aggregation should run through the direct path with a
  scope (where the SDK enforces) rather than through REST aggregate
  (where nothing does).
- You need analytics-style joins across Parse classes, which the REST
  layer can't perform efficiently.
- You want to drive the query against a MongoDB secondary replica
  (read preference is configured at the driver, not at Parse Server).
- You need ACL/CLP-enforced aggregation against a user-context scope
  (v4.4.0).

The direct path is the **wrong** tool when:

- You're writing data — direct writes bypass every beforeSave/afterSave
  hook and ACL/CLP check in Parse Server. Always write through Parse
  Server.
- The deployment is a Parse Server-only environment where the gem doesn't
  have direct MongoDB access (most production Parse Server hosts).
- You need ACL/CLP enforcement and you call without supplying a scope
  kwarg. An unscoped direct call runs in master-key posture and skips
  the SDK enforcement layers. Either declare a scope or use REST
  find/get/count (where Parse Server applies the enforcement itself).

---

## Configuration

### Gemfile

```ruby
gem "mongo", "~> 2.18"
```

The `mongo` driver gem is **not** a hard dependency of Parse Stack. The
direct path raises `Parse::MongoDB::GemNotAvailable` if you try to use it
without the gem present.

### Connection

```ruby
require "parse/mongodb"

Parse::MongoDB.configure(
  uri: "mongodb://user:pass@host:27017/parse?authSource=admin",
  enabled: true,
)
```

The database name is extracted from the URI path (`/parse` in the
example); override it explicitly with `database: "name"` if your URI
doesn't include one.

### Env-var resolution (recommended)

When `uri:` is omitted, `configure` resolves the URI from environment
variables in priority order:

1. `ANALYTICS_DATABASE_URI` — dedicated direct-read endpoint, typically
   pointed at an analytics replica.
2. `DATABASE_URI` — Parse Server's primary connection. Fallback for
   deployments where direct reads share the primary cluster.

```ruby
# In deployment config:
#   ANALYTICS_DATABASE_URI=mongodb+srv://analytics_ro:...@cluster.mongodb.net/parse?...
#   DATABASE_URI=mongodb+srv://parse_rw:...@cluster.mongodb.net/parse

# In code -- no URI hard-coded:
Parse::MongoDB.configure(enabled: true)
```

`ANALYTICS_DATABASE_URI` taking priority lets operators point direct
traffic at a dedicated analytics endpoint without touching Parse Server's
primary `DATABASE_URI`. Configure both: Parse Server keeps writing
against `DATABASE_URI`; the gem's direct-read path reads from
`ANALYTICS_DATABASE_URI`.

`configure` raises `ArgumentError` if neither a `uri:` argument nor any
of the env vars is set.

### Feature flag

`Parse::MongoDB.enabled?` returns `true` only after `configure` has run
and `enabled: true` was set. Use the flag to gate code paths so
deployments without direct access fall back gracefully:

```ruby
if Parse::MongoDB.available?
  songs = Song.query(genre: "Jazz").results_direct
else
  songs = Song.query(genre: "Jazz").results
end
```

`available?` also checks that the `mongo` gem is loaded; prefer it over
`enabled?` for control-flow.

---

## Read paths

There are four entry points, listed from highest level to lowest.

### `Query#results_direct`

```ruby
songs = Song.query(:plays.gt => 1000)
            .order(:plays.desc)
            .limit(50)
            .results_direct
```

Compiles the query's `where`/`order`/`limit`/`skip` into an aggregation
pipeline, runs it through MongoDB directly, and decodes the documents
into `Parse::Object` instances. Returns a `Parse::Object` array.

Options:

- `raw: true` — skip decoding and return Parse-formatted JSON hashes.
- `max_time_ms: 5000` — cancel the query if MongoDB exceeds the budget
  (raises `Parse::MongoDB::ExecutionTimeout`).
- `session_token: <bearer>`, `acl_user: <Parse::User>`, `acl_role: <name>`,
  or `master: true` (v4.4.0) — declare the authorization scope. The
  SDK applies ACL + CLP + `protectedFields` enforcement when a scope
  is supplied; see [Security](#security) for the full enforcement
  contract. Omitting all four falls through to public-only semantics
  (with a one-time `[Parse::ACLScope:SECURITY]` banner).

```ruby
# User-context read: SDK enforces ACL + CLP for the user's claim set
Song.query.results_direct(session_token: current_user.session_token)

# Pre-resolved User pointer: skips /users/me, same enforcement
Song.query.results_direct(acl_user: current_user)

# Service-account / analytics: explicit master-mode opt-out
Song.query(:plays.gt => 1000).results_direct(master: true)
```

The convenience helpers `scope_to_user(user)` / `scope_to_role(role)`
set the same kwargs on the query for chainable composition.

Related: `first_direct(n)` for the first N rows, `count_direct` for a
count-only query. Both accept the same auth kwargs.

### `Query#aggregate(pipeline, mongo_direct: true)`

```ruby
pipeline = [
  { "$group" => { "_id" => "$genre", "total_plays" => { "$sum" => "$plays" } } },
  { "$sort"  => { "total_plays" => -1 } },
]
agg = Song.query.aggregate(pipeline, mongo_direct: true)
agg.results
```

`Query#aggregate` prepends the query's `where`/`order`/`limit`/`skip` as
pipeline stages, then appends `pipeline`, then dispatches via direct
MongoDB. The return is a `Parse::Query::Aggregation` instance with
`.results`, `.raw`, and `.result_pointers` accessors.

`mongo_direct: nil` (the default) lets Parse Stack decide; it auto-flips
to `true` when the constraint compiler produced `$inQuery`/`$notInQuery`
`$lookup` stages (which Parse Server's REST aggregate endpoint can't
execute) and `Parse::MongoDB.enabled?` is true.

### `Parse::MongoDB.aggregate(class_name, pipeline)`

```ruby
pipeline = [{ "$match" => { "releaseDate" => { "$gte" => Time.utc(2024, 1, 1) } } }]
raw_docs = Parse::MongoDB.aggregate("Song", pipeline, max_time_ms: 3000)
```

Raw entry point. Accepts the class name (which is also the MongoDB
collection name — `User` is `_User`, etc.) and an aggregation pipeline.
Returns raw MongoDB documents — no Parse-format conversion is applied.
Use `Parse::MongoDB.convert_documents_to_parse(raw_docs, "Song")` to
convert into the Parse JSON shape, then `Song.new(doc)` or
`Song.find(doc["objectId"])` to hydrate objects.

Authorization kwargs (v4.4.0) — pass at most ONE:

- `session_token: <bearer>` — round-trips Parse Server's `/users/me`
  to resolve the user and expand role subscription.
- `acl_user: <Parse::User or Pointer>` — pre-resolved identity, skips
  the token round-trip. Role expansion runs via `Parse::Role.all_for_user`.
- `acl_role: <Parse::Role or name>` — service-account scope; no user_id,
  just the role + transitively inherited roles.
- `master: true` — explicit ACL/CLP opt-out (analytics, admin).

The full enforcement contract (ACL row-level + CLP + `protectedFields`)
runs when any of the first three is supplied. See [Security](#security)
for what each layer does and why master-mode bypasses everything.

### `Parse::MongoDB.find(class_name, filter, **options)`

```ruby
raw = Parse::MongoDB.find(
  "Song",
  { "genre" => "Rock" },
  limit: 100, sort: { "plays" => -1 },
)
```

Convenience wrapper around `db.find`. Accepts `limit:`, `skip:`, `sort:`,
`projection:`, `max_time_ms:`. When `:limit` is omitted the call applies
`DEFAULT_FIND_LIMIT = 1000` and warns; pass `limit: 0` to opt out.

### Geo queries

Three geo query constraints land in v4.4.0 alongside a direct
`Parse::MongoDB.geo_near` aggregation helper. All four operate on
MongoDB GeoJSON geometries via `2dsphere` indexes, so the queried
column must be indexed (`mongo_geo_index :location` on the model, or
manual `db.collection.createIndex({location: "2dsphere"})`).

| Constraint                    | Generates              | Routing                                  |
| ----------------------------- | ---------------------- | ---------------------------------------- |
| `:field.near_sphere => point` | `$nearSphere`          | REST or mongo-direct (Parse Server supports both). |
| `:field.within_sphere => [point, radius, :miles]` | `$geoWithin: $centerSphere` | **Mongo-direct only** — `$centerSphere` is not a Parse Server REST operator. The constraint emits `__mongo_direct_only` and the query auto-routes to `results_direct`. |
| `:field.geo_intersects => geometry` | `$geoIntersects: $geometry` | Mongo-direct only. |
| `:field.polygon_contains => point` | `$geoIntersects: $point` | REST or mongo-direct. |
| `:field.within_polygon => polygon` | `$geoWithin: $polygon` | REST when value is a GeoPoint array; mongo-direct when value is `Parse::Polygon`. |

```ruby
class Place < Parse::Object
  property :location, :geopoint
  mongo_geo_index :location
end

near_me = Place.query(:location.near_sphere => Parse::GeoPoint.new(37.7749, -122.4194))
within_5mi = Place.query(:location.within_sphere => [Parse::GeoPoint.new(37.7749, -122.4194), 5, :miles])
in_bbox = Place.query(:location.geo_intersects => bbox_geojson)
```

For constraints that auto-route to mongo-direct (`within_sphere`,
`geo_intersects`, and `within_polygon` with a `Parse::Polygon`), the
caller's auth scope must reach the mongo-direct path the same way it
does for any other mongo-direct query — `master:`, `session_token:`,
`acl_user:`, or `acl_role:` resolution applies.

#### `Parse::MongoDB.geo_near(class_name, near:, **options)`

```ruby
results = Parse::MongoDB.geo_near(
  "Place",
  near: Parse::GeoPoint.new(37.7749, -122.4194),
  distance_field: "distance_meters",
  max_distance: 5_000,           # meters
  spherical: true,                # default
  query: { "category" => "cafe" }, # additional $match
  limit: 50,
  session_token: request_session, # or master:/acl_user:/acl_role:
)
```

Builds and runs a `$geoNear` aggregation stage. `$geoNear` must be the
first stage of any pipeline that uses it, so this helper handles stage
ordering for you. Returns each document with the configured
`distanceField` populated.

**Coordinate-order convention**: `near:` accepts `Parse::GeoPoint` or
a GeoJSON `{type:"Point", coordinates:[lng,lat]}` Hash. Prefer
`Parse::GeoPoint` to avoid axis-order mistakes — GeoJSON uses
`[lng,lat]` while the rest of the Parse SDK uses `[lat,lng]`.

#### Winding order (MongoDB 8+ / Atlas)

MongoDB 8+ and recent Atlas releases enforce RFC 7946 for polygons
used in `$geoWithin` / `$geoIntersects` against `2dsphere` indexes:
the outer ring must be wound counter-clockwise. `Parse::Polygon` ships
with `counter_clockwise?` and `ensure_counter_clockwise!` helpers, and
`Parse::Polygon#_validate` emits a warning when an outer ring is
clockwise. `to_geojson` does not auto-correct — call
`polygon.ensure_counter_clockwise!` before persisting or querying if
you can't guarantee the input.

---

## Storage-format reference

Parse Server stores documents in MongoDB with a specific shape. To write
aggregation pipelines that match, you need to know the column names.

| Parse field             | MongoDB column         | Notes                                                         |
| ----------------------- | ---------------------- | ------------------------------------------------------------- |
| `objectId`              | `_id`                  | String, 10 chars in the standard Parse format.                |
| `createdAt`             | `_created_at`          | BSON Date.                                                    |
| `updatedAt`             | `_updated_at`          | BSON Date.                                                    |
| `ACL`                   | `_acl`                 | Short-key form: `{ "<userId>": { "r": true, "w": true } }`.   |
| Pointer field `author`  | `_p_author`            | String `"AuthorClass$abc123"`. Embedded `__type` is *not* used in this column. |
| Array of pointers       | `field`                | Array of `{ __type: "Pointer", className:, objectId: }` hashes. |
| Relation                | `_Join:field:Class`    | Separate collection. Each row: `{ owningId:, relatedId: }`.   |
| `parseReference`        | `parseReference`       | Optional. Mirrors `_p_` form: `"ClassName$objectId"`. See below. |
| Regular fields          | `fieldName` (camelCase) | The Parse "remote name". Local snake-case is gem-side only.   |

### Field references in pipeline expressions

Inside `$match`, `$project`, `$expr`, etc., refer to fields by their
MongoDB column name with a `$` prefix:

```ruby
{ "$match" => { "$expr" => { "$gt" => ["$plays", "$threshold"] } } }
{ "$project" => { "_p_author" => 1, "name" => 1, "createdAt" => "$_created_at" } }
```

#### Pipeline-local aliases (4.4.2+)

The `$author` → `$_p_author` / `$createdAt` → `$_created_at` rewrite
inside expression values is **schema-aware**: a `$field` reference whose
name is neither a declared Parse property on the queried class nor one
of the universal built-ins (`objectId` / `createdAt` / `updatedAt`)
passes through verbatim. This means aliases introduced by an upstream
`$project` / `$addFields` / `$set` / `$group` stage survive into
downstream stages exactly as you wrote them, and result rows are keyed
by the literal spelling the caller used.

```ruby
pipeline = [
  { "$group"   => { "_id"             => nil,
                    "contributor_set" => { "$addToSet" => "$_p_user" } } },
  { "$project" => { "contributor_count" => { "$size" => "$contributor_set" } } },
]

Parse::MongoDB.aggregate("Post", pipeline)
# => [{ "contributor_count" => 27 }]
#    row keyed by the literal alias, no read-side translation needed
```

Naming caveat: an alias whose name shadows a declared Parse property
will be resolved by the schema-aware walker as the property in
downstream stages — `$group { author: ... }` followed by a downstream
`$author` reference becomes `$_p_author` (storage column), not the
alias. Avoid alias names that collide with declared property names; the
constraint is general to MongoDB aggregation, not specific to parse-stack.

### System classes

Parse system classes use a `_`-prefixed collection name:

- `User` → `_User`
- `Role` → `_Role`
- `Installation` → `_Installation`
- `Session` → `_Session`

Always pass the prefixed form to `Parse::MongoDB.aggregate` /
`Parse::MongoDB.find`. The `Parse::Query` path resolves the alias for
you, but the direct API does not.

### Dates

MongoDB stores dates as BSON `Date` (UTC). Compare with Ruby `Time`
objects, which the driver serializes as BSON dates automatically:

```ruby
cutoff = Time.utc(2024, 1, 1)
{ "$match" => { "_created_at" => { "$gte" => cutoff } } }
```

The `Parse::MongoDB.to_mongodb_date(value)` helper coerces `Date`,
`DateTime`, `Time`, ISO 8601 strings, and Unix timestamps to a UTC `Time`
suitable for matching.

---

## Pointer joins and `parse_reference`

Joining across Parse classes with the raw storage layout is awkward
because the local side stores `_p_author = "Author$abc123"` while the
foreign collection's `_id = "abc123"`. Three lookup forms exist; pick
based on whether the foreign class declares `parse_reference`.

### Recommended: declare `parse_reference` on the foreign class

```ruby
class Author < Parse::Object
  property :name, :string
  parse_reference
end

class Post < Parse::Object
  belongs_to :author, class_name: "Author"
end
```

`parse_reference` adds a `parseReference` column to the foreign class,
populated automatically with the canonical `"ClassName$objectId"` string.
This mirrors the local `_p_*` column format exactly, so `$lookup`
collapses to a one-field equality:

```ruby
pipeline = [
  { "$lookup" => {
    "from"         => "Author",
    "localField"   => "_p_author",
    "foreignField" => "parseReference",
    "as"           => "author_doc",
  } },
]
Parse::MongoDB.aggregate("Post", pipeline)
```

This form is the fastest (single equality on a hashable string column —
add an index on `parseReference` for foreign collections that grow
large) and the simplest to reason about.

#### Precompute mode

For high-write classes, declare with `precompute: true` so the canonical
value is embedded in the initial create POST and no follow-up `update!`
fires:

```ruby
class Author < Parse::Object
  parse_reference precompute: true
end
```

The trade-off: the gem generates the `objectId` client-side
(`SecureRandom.alphanumeric(10)`, matching Parse Server's own format)
instead of letting the server assign one.

#### Backfilling existing rows

When you enable `parse_reference` on a class that already has data, run
the rake task to populate the column on every existing row:

```
bundle exec rake parse:references:populate CLASS=Author
```

`DRY_RUN=true` previews counts without writing; `BATCH_SIZE=N` tunes the
page size (default 100). `rake parse:references:list` lists every loaded
class that declares `parse_reference`.

### Without `parse_reference`: the `$split` form

When the foreign class doesn't have `parseReference`, extract the
`objectId` from `_p_*` and match on the foreign `_id`:

```ruby
pipeline = [
  { "$lookup" => {
    "from"     => "Author",
    "let"      => { "aid" => {
      "$arrayElemAt" => [{ "$split" => ["$_p_author", { "$literal" => "$" }] }, 1],
    } },
    "pipeline" => [
      { "$match" => { "$expr" => { "$eq" => ["$_id", "$$aid"] } } },
    ],
    "as"       => "author_doc",
  } },
]
```

The `{ "$literal" => "$" }` form is required because MongoDB treats
unescaped `$` as a field reference.

### LLM-generated pipelines: `Parse::LookupRewriter` (auto-wired)

LLMs trained on standard MongoDB syntax produce lookups against logical
class names and pretty field names:

```ruby
# What the LLM writes -- matches nothing in raw Parse-on-Mongo storage:
llm_pipeline = [
  { "$lookup" => {
    "from"         => "Author",
    "localField"   => "author",
    "foreignField" => "_id",
    "as"           => "author_doc",
  } },
]

# Run it through Parse::MongoDB.aggregate -- the gem auto-rewrites:
Parse::MongoDB.aggregate("Post", llm_pipeline)
# Internally translated to: localField: "_p_author", foreignField: "parseReference"
```

`Parse.rewrite_lookups = true` (the default) auto-applies the rewriter at
three entry points:

- `Parse::Query#aggregate(pipeline, ..., rewrite_lookups:)`
- `Parse::MongoDB.aggregate(class, pipeline, ..., rewrite_lookups:)`
- `Parse::Agent::Tools.aggregate(..., pipeline:, rewrite_lookups:)`

The auto path uses **`fallback: :preserve` mode** — it only rewrites
stages whose foreign class declares `parse_reference`. Lookups against
foreign classes without `parse_reference` are left untouched (they'll
return empty arrays unless the caller already wrote `_p_*` form). Use
`Parse::LookupRewriter.rewrite(pipeline, local_class:, fallback: :split)`
to get the `let`/`pipeline`/`$arrayElemAt`+`$split` fallback explicitly.

The rewriter handles:

- **Forward joins** — local `belongs_to` resolved to `_p_*`/`parseReference`.
- **Reverse joins** — when the LLM writes the inverse direction (start
  from `Post`, attach `Comment`s with `_p_post` back-pointers).
- **`$split` fallback** (explicit-call mode only) — when the foreign class
  doesn't declare `parse_reference`, extract the objectId from `_p_*`.
- **System-class collection rename** — `from: "User"` → `from: "_User"`.
  Applied to `$lookup.from`, `$unionWith.from`/`coll`, and `$graphLookup.from`.
- **Sub-pipeline recursion** — walks into `$lookup.pipeline`,
  `$unionWith.pipeline`, and `$facet.*`. (`$graphLookup` does not accept
  a sub-pipeline.)
- **Idempotency** — stages already in `_p_*`/`parseReference` form pass
  through unchanged, so SDK-generated pipelines (which already use the
  correct columns) are not double-rewritten.

#### Controls

| Surface | Default | Override |
| ------- | ------- | -------- |
| Global | `Parse.rewrite_lookups = true` | Set `false` to disable everywhere |
| Per `Query#aggregate` | follows global | `Song.query.aggregate(pipe, rewrite_lookups: false)` |
| Per `Parse::MongoDB.aggregate` | follows global | `Parse::MongoDB.aggregate(class, pipe, rewrite_lookups: false)` |
| Per `Tools.aggregate` (agent) | follows global | tool-call `rewrite_lookups: false` |

#### Limitations

- **`$graphLookup` pointer-join translation.** Only the `from:` collection
  alias is rewritten. The `connectFromField`/`connectToField` pair is not
  translated to `_p_*`/`parseReference` form because the typical
  `$graphLookup` use case (recursive hierarchies over the same collection)
  doesn't need it. Callers using `$graphLookup` against pointer columns
  must supply the Parse-on-Mongo column names themselves.
- **Polymorphic pointers** — the rewriter relies on `belongs_to :field,
  class_name: "Foo"` to resolve the target class. A pointer field that
  can hold instances of multiple classes is left alone.
- **Embedded pointer arrays** — array fields of pointer hashes
  (`__type: "Pointer", className:, objectId:`) are not the same as
  `_p_*` pointer-string columns and aren't rewriteable. The rewriter
  passes them through unchanged.

---

## Result conversion

`Parse::MongoDB.aggregate` returns raw documents — keys are the
underscore-prefixed MongoDB column names, values are BSON types. Three
helpers convert to friendlier shapes:

- **`Parse::MongoDB.convert_documents_to_parse(docs, class_name)`** —
  renames `_id` → `objectId`, `_created_at` → `createdAt`, `_p_*` →
  embedded `{__type: "Pointer", ...}`, `_acl` → Parse `ACL` format.
  Strips internal fields per `Parse::PipelineSecurity::INTERNAL_FIELDS_DENYLIST`
  — `_rperm`, `_wperm`, `_hashed_password`, `_password_history`,
  `_session_token`/`_sessionToken` (the `_User`-side internal columns),
  `sessionToken`/`session_token` (the `_Session`-class wire columns, added
  in v4.3.0), `_email_verify_token`, `_perishable_token`,
  `_failed_login_count`, `_account_lockout_expires_at`, `_tombstone`,
  `_auth_data` and any `_auth_data_<provider>` prefix.
- **`Parse::MongoDB.convert_aggregation_document(doc)`** — for `$group`
  rows where `_id` is the group key, not a document id. Coerces values
  but preserves all keys including `_id`.
- **`Query::Aggregation#results`** — branches per-row: documents with
  `_created_at`/`_updated_at` get decoded as `Parse::Object`; the rest
  are wrapped as `Parse::AggregationResult` so the group key stays
  accessible via `result._id` or `result.id`.

### Embedded pointer fields

`_p_author = "Author$abc"` becomes `author = { __type: "Pointer",
className: "Author", objectId: "abc" }`. If your `$lookup` populated the
joined document into the `author_doc` array, you can `$unwind` it and
project it under the canonical pointer field name:

```ruby
{ "$lookup"   => { "from" => "Author", "localField" => "_p_author",
                   "foreignField" => "parseReference",
                   "as" => "_included_author" } },
{ "$unwind"  => { "path" => "$_included_author", "preserveNullAndEmptyArrays" => true } },
```

The `_included_` prefix is recognized by `convert_documents_to_parse`
and the embedded document is hoisted to the un-prefixed name on output
(`_included_author` → `author`).

---

## Security

Direct MongoDB bypasses Parse Server entirely. **Critical Parse Server
behavior to know:** the REST `POST /aggregate/<Class>` endpoint REQUIRES
the master key and enforces NEITHER CLP nor ACL — there is no session-
token authorization model for REST aggregate at all. So any aggregation
workload (mongo-direct OR REST aggregate through Parse Server) only gets
ACL/CLP enforcement if the SDK applies it.

As of **v4.4.0**, the SDK applies that enforcement on the mongo-direct
path when the caller supplies a scope. Five layers compose:

### Layer 1: Pipeline-security denylist (always on)

`Parse::PipelineSecurity` refuses dangerous operators at any depth in
the pipeline — whether at the top level or nested inside
`$lookup.pipeline`, `$facet.*`, `$expr`, etc.:

- **Denied operators:** `$where`, `$function`, `$accumulator`, `$out`,
  `$merge`, `$collMod`, `$createIndex`, `$dropIndex`,
  `$planCacheSetFilter`, `$planCacheClear`. All execute server-side
  JavaScript or mutate database state.
- **Permissive mode** (`Parse::Query#aggregate`): denylist only,
  no stage-allowlist enforcement. Atlas Search, `$densify`, `$fill`,
  and other uncommon read stages pass through.
- **Strict mode** (`Parse::PipelineSecurity.validate_pipeline!`): explicit
  allowlist for callers that need it; this is what the LLM agent's
  `aggregate` tool uses.

`$lookup`, `$graphLookup`, and `$unionWith` are NOT denied — they're
legitimate read stages — but they read from arbitrary collections. Never
pass attacker-controlled input into a pipeline; build the pipeline in
trusted code and interpolate only validated values.

### Layer 2: Row-level ACL enforcement (`Parse::ACLScope`) — scoped only

When `Parse::MongoDB.aggregate` is called with `session_token:`,
`acl_user:`, or `acl_role:`, the SDK runs a three-step row-level ACL
simulation that matches Parse Server's REST find behavior:

1. **Top-level `$match` injection** — filters the queried collection's
   rows by the session's `_rperm` allow-set.
2. **Pipeline rewriter** — every `$lookup` / `$unionWith` / `$graphLookup` /
   `$facet` sub-pipeline gets the same `_rperm` filter embedded so joined
   rows from other collections are filtered at the database. Without
   this, includes/joins would silently leak rows the requesting session
   has no permission to read.
3. **Post-fetch redaction** — walks returned documents and scrubs any
   embedded sub-documents whose stored `_rperm` doesn't match the
   session's claim set. Catches cases the rewriter can't reach (raw
   `$lookup` shapes, `:object` columns embedding pointer-shaped hashes).

```ruby
# session-token mode — SDK round-trips /users/me to expand the user's
# roles, then injects all three layers
Parse::MongoDB.aggregate("Document", pipeline, session_token: user.token)

# acl_user mode — pre-resolved Parse::User, skips the token round-trip
Parse::MongoDB.aggregate("Document", pipeline, acl_user: current_user)

# acl_role mode — service-account scope ("see as if a user holding this
# role were asking"); no user_id in the claim set
Parse::MongoDB.aggregate("Document", pipeline, acl_role: "scope:audit")

# master mode — explicit ACL bypass for admin / analytics workloads
Parse::MongoDB.aggregate("Document", pipeline, master: true)
```

All four kwargs are mutually exclusive — passing two raises
`ArgumentError`. Calling `aggregate` with NONE of them in a production
deployment emits a one-time `[Parse::ACLScope:SECURITY]` banner to
stderr and falls through to public-only ACL semantics. Set
`Parse::ACLScope.require_session_token = true` to make missing-auth
calls raise `Parse::ACLScope::ACLRequired` instead — recommended for
hardened deployments.

### Layer 3: Class-Level Permissions (`Parse::CLPScope`) — scoped only

After ACL injection, the SDK consults `Parse::CLPScope.permits?` against
the queried class's `classLevelPermissions` (cached from `_SCHEMA` with
a 1-hour default TTL):

- **Boundary refusal** — `Parse::CLPScope::Denied` is raised before the
  pipeline runs when the resolved scope's claim set doesn't satisfy the
  class's `find` CLP. Master-key callers bypass.
- **`pointerFields` CLP** — when the class declares
  `find: { pointerFields: ["owner"] }`, the SDK runs the query then
  drops rows where none of the named pointer fields references the
  requesting user. `acl_role`-only scopes (no user_id) are refused at
  the boundary because no row can satisfy the constraint.

Cache control for long-lived processes:

```ruby
Parse::CLPScope.cache_ttl = 3600            # default seconds
Parse::CLPScope.invalidate!("Document")     # bust on schema change
Parse::CLPScope.reset_cache!                # process-wide
```

### Layer 4: `protectedFields` stripping — scoped only

The CLP's `protectedFields` map is resolved against the session's claim
set:

- Start with the `"*"` defaults — fields stripped from everyone by
  default.
- For every claim-set entry that matches a key in the map, intersect
  with that entry's strip-list. Parse Server's documented behavior is
  that a field is stripped only when every applicable pattern agrees
  to strip it; a `role:Admin => []` entry therefore lifts all
  protection for an admin-roled session.

The strip set is applied via a post-fetch walker that recurses through
every result row and every embedded sub-document. The walker reaches
`$lookup`-included rows that a top-level `$project: { ssn: 0 }` couldn't
cover.

### Layer 5: Master-key escape hatch

`master: true` (or omitting all four identity kwargs) bypasses Layers
2-4 entirely. Master-key has always been the explicit ACL/CLP opt-out;
the construction banner is the operator-visibility signal. Use master
mode for analytics jobs, admin tooling, and service-account workloads
that have no per-user identity to enforce against.

### Net effect

The mongo-direct path now matches Parse Server's REST find/get/count
authorization model for scoped callers and is the SAFER aggregation
path for any user-context workload — REST aggregate has no ACL/CLP
enforcement at all, while mongo-direct with a scope gets all of it.

### Vector search inherits the 5-layer enforcement

`Klass.find_similar(vector:, k:)` (and the `text:` variant that
auto-embeds) is built on top of `Parse::MongoDB.aggregate` — the
$vectorSearch stage is prepended, then the same Layer 1-5 chain runs
against the result rows. Vector search inherits the pipeline-security
denylist, `_rperm` ACL match, CLP read enforcement, `protectedFields`
stripping, and master-key escape hatch automatically. There is no
REST-aggregate path for vector search: scoped callers MUST use the
mongo-direct path because Parse Server's REST `/aggregate` endpoint is
master-key-only and would bypass every per-row ACL and CLP check.
Built-in vector tools auto-promote `mongo_direct: false` to `true` for
any agent that carries a `session_token`, `acl_user`, `acl_role`, or
non-master scope so this enforcement always runs. See the
[Atlas Vector Search Guide](./atlas_vector_search_guide.md) for the
full API surface.

`Parse::Retrieval.retrieve` and the `semantic_search` agent tool (v5.2)
build directly on `find_similar`, so they inherit this exact Layer 1-5
mongo-direct enforcement. The earlier RAG plan's "two-stage" REST
re-query was intentionally NOT adopted — there is no REST vector path,
and `acl_user:` / `acl_role:` scopes have no REST equivalent, so the
post-`$vectorSearch` `_rperm` `$match` is the single enforcement
boundary. The retrieval layer adds a tenant-scope fold into the Atlas
pre-filter on top of this, never a substitute for it.

### Timeouts

```ruby
Parse::MongoDB.aggregate("Song", pipeline, max_time_ms: 5000)
Parse::MongoDB.find("Song", filter, limit: 100, max_time_ms: 5000)
```

Plumbs into MongoDB's `maxTimeMS` option. When the driver cancels with
error code 50, the gem translates it into
`Parse::MongoDB::ExecutionTimeout(collection_name:, max_time_ms:)`.

### Default `find` limit

`Parse::MongoDB.find` applies a `DEFAULT_FIND_LIMIT = 1000` cap when
`:limit` is omitted and warns when the cap is hit. Pass `limit: 0` for
unbounded behavior, or an explicit `limit:` to silence the warning.

### Pointer-shape strictness (4.4.3+)

Parse stores pointer columns on disk as `"ClassName$objectId"`. A query
that passes a bare objectId string against a pointer column matches
nothing — the value's shape doesn't line up with the stored form. The
SDK normally rewrites the most common shapes (a single `Parse::Pointer`,
a `{__type: "Pointer", ...}` hash, a peer-pointer in an `$in` array) but
cannot always infer the target class from a bare string alone.

Default behavior is backwards-compatible: emit a one-shot warning via
`Parse.logger` and leave the value as-is, so the query returns zero
rows. For LLM agents and CI this is the worst failure mode — "0 results"
reads as a real answer instead of a mistake. Enable strict mode to flip
the warning into a raise:

```ruby
Parse.strict_pointer_shapes = true            # in code
# or set in the environment:
#   PARSE_STRICT_POINTER_SHAPES=true
```

With the flag on, an unresolvable pointer-shape constraint raises
`Parse::Query::PointerShapeError` with a message that names the column,
the operator, the offending value, and the accepted shapes. Recommended
for test/CI runs and any agent-driven workload; leave off in production
if you have callers relying on the legacy silent-zero behavior.

---

## Routing to analytics / secondary nodes

The MongoDB driver picks the node to read from based on the read
preference encoded in the connection URI. Routing direct traffic at
non-primary nodes is the standard way to keep heavy aggregations off
the cluster's write path.

### Generic secondary

```ruby
Parse::MongoDB.configure(
  uri: "mongodb://host/parse?readPreference=secondaryPreferred",
  enabled: true,
)
```

### MongoDB Atlas analytics nodes

In Atlas, dedicated analytics nodes are tagged with `nodeType: ANALYTICS`.
The driver routes there when the URI carries the matching read-preference
tag:

```
mongodb+srv://analytics_ro:<pwd>@<cluster>.mongodb.net/parse?\
readPreference=secondary&\
readPreferenceTags=nodeType:ANALYTICS&\
readPreferenceTags=
```

The **trailing empty `readPreferenceTags=`** is a fallback — if no
analytics node is reachable, the driver falls through to any secondary.
Drop the empty tag if you'd rather have the query fail than land on a
regular secondary:

```
...?readPreference=secondary&readPreferenceTags=nodeType:ANALYTICS
```

Pair this with `ANALYTICS_DATABASE_URI`:

```bash
# Production env:
ANALYTICS_DATABASE_URI="mongodb+srv://analytics_ro:...@cluster.mongodb.net/parse?readPreference=secondary&readPreferenceTags=nodeType:ANALYTICS&readPreferenceTags="
DATABASE_URI="mongodb+srv://parse_rw:...@cluster.mongodb.net/parse"
```

`Parse::MongoDB.configure(enabled: true)` picks up the analytics URI
automatically; Parse Server keeps using `DATABASE_URI` for OLTP.

### Role check at configure time

When `verify_role: true` (the default), `Parse::MongoDB.configure` runs a
`connectionStatus` probe against the configured URI and emits a warning
if the authenticated user has any write actions in its privilege list.
The probe is a read-only call — no writes occur.

```
[Parse::MongoDB] WARNING: the URI configured for direct queries
authenticates a user with write privileges. The direct path is
read-only by design; using a read-only role bounds the blast radius
if caller code touches `Parse::MongoDB.client` directly.
```

Pass `verify_role: false` to skip the check (no connection is attempted
during `configure`). Call `Parse::MongoDB.read_only?` explicitly when you
want the value:

- `true` — the user has no write actions on the configured database.
- `false` — at least one write action was found (the warning fires for
  this case).
- `nil`  — couldn't determine. Empty privilege list, command not
  supported on this endpoint, or network failure.

`read_only?` checks the **role**, not the transport. A
`readPreference=secondary` URI with a write-capable user is still
write-capable; the driver routes writes to primary regardless of read
preference. Use a read-only Atlas user (or equivalent on self-hosted
MongoDB) to bound the blast radius.

### Why a connection-string approach is "good enough" in practice

The combination is **read-only role + analytics-tagged URI**:

- The role (`analytics_ro` in the example) is read-only at the Atlas
  user level — even if a client ignored the read preference and hit the
  primary, the worst it can do is run a query there. That's a
  performance concern (stealing OLTP resources), not a correctness or
  security one.
- The connection string is what keeps load off the primary and
  electable secondaries in the normal case.

For most analytics workloads this is enough. The read-only role bounds
the blast radius; the URI controls routing.

### Strict isolation (when the connection string isn't enough)

If you must hard-guarantee that direct queries cannot touch primary or
electable secondaries — for example, because you want to give the
endpoint to an external workspace or an autonomous agent — the connection
string alone is insufficient. The options:

- **Atlas SQL / BI Connector.** Issue the user a JDBC/SQL endpoint that
  Atlas pre-pins to analytics nodes. The endpoint can't be used to hit
  any other node.
- **Atlas Data Federation.** Define a federated database backed
  exclusively by the analytics node tier; expose only that endpoint to
  the consumer.

Both options trade flexibility (the consumer no longer has the full
MongoDB driver API) for hard isolation. Use them when the consumer is
untrusted; stay with the URI-routing approach when the consumer is your
own application code.

### Per-query read preference (Parse Server REST path only)

`Query#read_pref` is also available for queries routed through Parse
Server's REST aggregate endpoint, which forwards the value as the
`readPreference` query option. It does NOT apply to direct MongoDB —
direct reads always use the read preference baked into the connection
URI.

---

## Index management

The reader URI configured via `Parse::MongoDB.configure` is read-only
by policy. A second, separately-credentialed **writer URI** is used
exclusively for MongoDB index management (and any future maintenance
write tooling). The writer is opt-in, off by default, and gated by
three independent flags that every mutation re-checks per call.

### Reader-side primitives (always available)

- **`Parse::MongoDB.indexes(collection_name)`** — returns the raw
  index definitions on a collection. Used by `Model.describe(:indexes)`
  and by the migrator's plan path. Returns `[]` on `NamespaceNotFound`
  (collections that haven't been created yet).
- **`Parse::MongoDB.list_search_indexes(collection_name)`** — Atlas
  Search indexes only (different mechanism — `$listSearchIndexes`).
- **`Parse::MongoDB.index_stats(collection_name)`** — per-index ops
  counters via `$indexStats`. Returns `Hash{name => {ops:, since:}}`.
  Requires `clusterMonitor` privilege on the reader; returns `{}`
  when not granted so callers degrade gracefully.

### Model DSL: `mongo_index` / `unique_index_on` / `mongo_geo_index` / `mongo_relation_index`

Index declarations are class-level metadata on `Parse::Object`
subclasses. They run validation at registration time so a typo,
unknown field, parallel-array compound, or `_id` reference fails
when the class loads.

```ruby
class Car < Parse::Object
  property :make, :string
  property :model, :string
  property :year, :integer
  property :tags, :array
  property :location, :geopoint
  belongs_to :owner, as: :user
  has_many :drivers, through: :relation, as: :user
  parse_reference

  mongo_index :make, :model, :year         # compound
  mongo_index :vin, unique: true
  unique_index_on :registration            # dedup floor; unique { registration: 1 }
  mongo_index :owner                       # pointer auto-rewrites to _p_owner
  mongo_geo_index :location                # 2dsphere on GeoJSON Point
  mongo_index :tags                        # array field
  mongo_relation_index :drivers, bidirectional: true
  # → _Join:drivers:Car { owningId: 1 } and { relatedId: 1 }
end
```

Validation rules enforced at declaration time:

- Unknown field → `ArgumentError`. `mongo_index :nonexistent_field` fails at load.
- Parallel arrays → `ArgumentError`. A compound declaration that includes
  more than one array-typed field (including the Parse-managed
  `_rperm` / `_wperm`) raises with "cannot index parallel arrays".
- Relation fields on the wrong DSL → `ArgumentError`. `mongo_index :drivers`
  is rejected because relations live in a separate `_Join:` collection;
  use `mongo_relation_index :drivers`.
- `_id` declarations → `ArgumentError`. The MongoDB primary key index
  (`_id_`) is auto-managed and protected from modification.
- `expire_after` on compound → `ArgumentError`. TTL indexes only support
  single-field declarations per MongoDB's rules.
- `unique:` on `mongo_relation_index` → `ArgumentError`. A
  single-direction unique on a `has_many :through: :relation` would
  contradict `has_many` semantics. For no-duplicate-pair subscription,
  declare a compound unique index directly via `Parse::MongoDB.create_index`.

`parse_reference` auto-registers a unique-sparse index declaration on
the configured field (the synchronize_create correctness floor relies
on this index existing). The sparse flag ensures `populate_parse_references!`
backfill workflows are not blocked by multiple NULLs colliding on the
unique constraint. Opt out per-field:

```ruby
class Author < Parse::Object
  parse_reference                              # default: unique+sparse index registered
  # parse_reference unique_index: false        # index without unique constraint
  # parse_reference index: false               # no index registered
end
```

### `unique_index_on` — the `first_or_create!` correctness floor

`unique_index_on(*fields, sparse: false, partial: nil, name: nil)` declares
a unique index on the exact dedup tuple that `first_or_create!` and
`create_or_update!` key on. It is thin sugar over
`mongo_index(*fields, unique: true, …)` — same registration, same validation
(sensitive-field guard, pointer auto-rewrite, parallel-array / relation /
`_id` rejection), same `apply_indexes!` writer path — but the name states the
intent: these fields are the create-or-update identity.

```ruby
class Subscription < Parse::Object
  property :email, :string
  belongs_to :tenant, as: :user

  unique_index_on :email, :tenant   # key: { email: 1, _p_tenant: 1 } unique
end

Subscription.apply_indexes!          # provisions the index via the writer gate
```

**Why it matters.** The Redis-backed `synchronize:` lock on `first_or_create!`
is a *latency optimization*: in the common path it collapses concurrent
callers so only one issues the create. The unique index is the *correctness
floor* that survives the lock being bypassed — a Redis outage, a TTL expiring
between the existence check and the write, a caller passing
`synchronize: false`, or two app servers whose lock secrets disagree. When a
race slips past the lock, the loser's insert fails with `DuplicateValue`
(Parse error 137), which `first_or_create!` rescues and resolves to the
winning row. Lock plus index make the net invariant — *exactly one row, every
caller sees the same id* — hold under any race, not just the happy path.

**Defaults are non-sparse, on purpose.** The index key is kept identical to
the query `first_or_create!` re-runs on recovery (`_scoped_first` on the same
`query_attrs`), so a 137 always corresponds to a row the recovery query can
find. A sparse or partial index that fires on a condition the recovery query
doesn't reproduce would surface a 137 the rescue can't resolve, and the error
would re-raise. `sparse:` only changes behavior for a document missing *every*
field in the tuple — a compound sparse index indexes a doc when it has at
least one key, and `first_or_create!` always writes the full tuple, so sparse
never weakens the floor. Leave it off unless out-of-band writers create
tuple-less rows you want excluded.

For "unique within a subset" — unique email per tenant, but rows with no
tenant may repeat — a partial filter is the right tool, **not** `sparse:`
(a compound sparse index still collides two rows that share the present
fields). You own the filter's lifecycle and must keep the recovery query
consistent with it:

```ruby
# Unique email per tenant; tenant-less rows are not constrained.
unique_index_on :email, :tenant,
                partial: { "_p_tenant" => { "$exists" => true } }
```

### Migrator: `indexes_plan` (dry-run) / `apply_indexes!` (mutate)

`Parse::Schema::IndexMigrator` reconciles declared indexes against the
actual MongoDB state. The plan classifies each declaration into
`to_create`, `in_sync`, or `conflicts`. Comparison is by **key
signature**, not by name — MongoDB's auto-generated `field_dir_field_dir`
names align with declarations that didn't pass `name:` explicitly.

```ruby
# Dry-run — reader-only, doesn't need writer config:
Car.indexes_plan
# => { "Car" => { to_create: [...], in_sync: [...], orphans: [...],
#                 conflicts: [...], parse_managed: [...],
#                 capacity_used: 8, capacity_after: 13,
#                 capacity_remaining: 51, capacity_ok: true },
#      "_Join:drivers:Car" => { ... } }

# Apply — additive by default, requires writer + triple gate:
Car.apply_indexes!
# => { "Car" => { created: [...], skipped_exists: [...],
#                 dropped: [], conflicts: [], capacity_blocked: false },
#      "_Join:drivers:Car" => { ... } }

# Opt-in drops:
Car.apply_indexes!(drop: true)   # drops orphans (per-call confirmation envelope)
```

Plan is a Hash keyed by target collection — one entry per unique
collection across the declaration list. The parent collection
(`Car`) and any join collections (`_Join:drivers:Car`) are reported
separately so drift is detectable per collection.

The migrator never proposes drops against Parse-managed indexes
(`_id_`, `_username_unique`, `_email_unique`, `_session_token_*`,
`_email_verify_token_*`, `_perishable_token_*`, `_account_lockout_*`,
`case_insensitive_*`). They appear in `parse_managed:` for
transparency but are excluded from `orphans:` regardless of `drop:`.

The migrator also enforces the 64-indexes-per-collection MongoDB
limit at plan time. `apply!` returns `{capacity_blocked: true, ...}`
when projected `existing + to_create` would exceed 64, without
issuing any creates.

### Writer URI + triple-gate

`Parse::MongoDB.configure_writer(uri:, enabled: true, verify_role: true)`
opens a second `Mongo::Client` against a write-capable role URI. The
writer is the only path through which index mutations reach MongoDB.
The underlying client is held privately — there's no public accessor.

```ruby
# Typically in a rake-task initializer, NEVER in a web-process initializer:
Parse::MongoDB.configure_writer(uri: ENV["MONGO_WRITER_URI"])
Parse::MongoDB.index_mutations_enabled = true
# ENV["PARSE_MONGO_INDEX_MUTATIONS"] = "1" is also required (see below)
```

Operator-safety checks:

- The writer URI must be **string-distinct** from the reader URI
  (`Parse::MongoDB.uri`). Catches `configure_writer(uri: ENV["DATABASE_URI"])`
  copy-paste mistakes.
- `verify_role: true` runs `connectionStatus` against the writer
  URI and **refuses fail-closed** (`WriterRoleTooPermissive`) if the
  authenticated user holds any action outside the writer allowlist
  (`createIndex`, `dropIndex`, plus a small set of read actions for
  introspection). Override with `verify_role: false` for test fixtures
  only.

Every mutation re-checks **all three gates** on every call — not just
at configure time, so a SIGHUP / supervisor env flip can revoke
without restart:

1. `Parse::MongoDB.configure_writer` was called and is enabled
2. `Parse::MongoDB.index_mutations_enabled == true` (default `false`,
   must be flipped in code)
3. `ENV["PARSE_MONGO_INDEX_MUTATIONS"] == "1"`

Missing any gate → raises with a message naming the missing lever:
`WriterNotConfigured` for gate 1, `MutationsDisabled` for gates 2 / 3.

### Mutation primitives (writer-only)

The migrator drives all mutations through these, but they're also
directly callable:

```ruby
Parse::MongoDB.create_index("Song", { title: 1, artist: 1 }, name: "title_artist")
# => :created  (or :exists when an identical spec already exists)

Parse::MongoDB.drop_index("Song", "old_index",
                          confirm: "drop:Song:old_index")
# => :dropped  (or :absent when the index isn't present — idempotent)
```

`drop_index` requires the `confirm:` string to equal
`"drop:#{collection}:#{name}"` literally. Stops accidental drops from
re-running a rake task after a context switch (wrong env shell, stale
terminal).

Mutations are denied against Parse-internal collections (`_User`,
`_Role`, `_Session`, `_Installation`, `_Audience`, `_Idempotency`,
`_PushStatus`, `_JobStatus`, `_Hooks`, `_GlobalConfig`, `_SCHEMA`)
unless `allow_system_classes: true` is passed explicitly. The
migrator passes this automatically for `_Join:*` collections only
(joins themselves aren't on the denylist, but their parent class
might be — e.g. `_Join:users:_Role`).

Every writer event emits a `[Parse::MongoDB:WRITER]` audit line with
the event kind, collection, PID, and operation-specific fields. Match
the `[Parse::Agent:SECURITY]` style used elsewhere in the gem.

#### Atlas Search index primitives

The writer also exposes parallel primitives for managing Atlas Search
indexes. Same triple-gate, same denylist, same audit channel — but
the commands are `createSearchIndexes` / `dropSearchIndex` /
`updateSearchIndex` (sent via `database.command`, since Atlas Search
indexes are not regular Mongo indexes). The writer role must hold
the corresponding privileges, all of which are present in
`WRITER_ALLOWED_ACTIONS`.

```ruby
# Submit an index. The Atlas Search build runs ASYNC on the search
# node; this returns as soon as the command is accepted.
Parse::MongoDB.create_search_index(
  "Song", "song_search",
  { mappings: { dynamic: false, fields: { title: { type: "string" } } } },
)
# => :created  (or :exists when an index of that name already exists)

# Replace the definition of an existing index. Same async rebuild.
Parse::MongoDB.update_search_index(
  "Song", "song_search",
  { mappings: { dynamic: true } },
)
# => :updated  (raises ArgumentError when no index by that name exists)

# Drop. Confirm token uses the "drop_search:" prefix (deliberately
# distinct from "drop:" so a token meant for a regular index cannot
# be replayed against a search index of the same name, and vice versa).
Parse::MongoDB.drop_search_index(
  "Song", "song_search",
  confirm: "drop_search:Song:song_search",
)
# => :dropped  (or :absent — idempotent)
```

Idempotency on `create_search_index` is name-based, not
definition-based: a duplicate-name create silently returns `:exists`
without diffing the mapping. To change a definition, call
`update_search_index` explicitly.

Use `Parse::AtlasSearch::IndexManager.{create_index,drop_index,update_index}`
as wrappers when you want the IndexManager's status cache to be
invalidated automatically. The bare `Parse::MongoDB.*` primitives do
not touch that cache — direct callers must
`Parse::AtlasSearch::IndexManager.clear_cache(collection_name)`
themselves.

#### Waiting for an async Atlas Search build

Atlas Search builds transition through `BUILDING` to `READY`. The
documented anti-pattern is `until index_ready?; sleep 2; end` — the
IndexManager's 300-second status cache locks in the first
`queryable: false` reading and never sees the transition. Use the
helper:

```ruby
case Parse::AtlasSearch::IndexManager.wait_for_ready(
  "Song", "song_search", timeout: 600, interval: 5,
)
when :ready   then # index is queryable
when :failed  then raise "search index build failed"
when :timeout then raise "did not reach READY within 600s"
end
```

`wait_for_ready` passes `force_refresh: true` to `list_indexes` on
every poll, so the cache cannot lock in the BUILDING state.

#### Atlas Search DSL: `mongo_search_index`

For declarative provisioning (analogous to `mongo_index`):

```ruby
class Song < Parse::Object
  property :title, :string
  property :artist, :string

  mongo_search_index "song_search", {
    mappings: { dynamic: false, fields: {
      title:  { type: "string", analyzer: "lucene.standard" },
      artist: { type: "string" },
    } },
  }
end

Song.search_indexes_plan
# => { collection: "Song", declared: [...], existing: [...],
#      atlas_available: true, to_create: [...], in_sync: [...],
#      drifted: [...], orphans: [...] }

Song.apply_search_indexes!                       # additive only
Song.apply_search_indexes!(update: true)         # also rebuild drifted
Song.apply_search_indexes!(drop: true)           # also drop orphans
Song.apply_search_indexes!(wait: true, timeout: 600)  # block until READY
```

`mongo_search_index` accepts a third `type:` kwarg (`"search"` default,
or `"vectorSearch"`). Multiple declarations per class are supported
— each must use a unique name. Same-name redeclaration is idempotent
on identical content; redeclaration with a different definition or
type raises at class-load.

Drift detection is **detect-and-refuse**, never auto-apply. A
declared definition that diverges from Atlas's `latestDefinition`
appears in `:drifted` and is reported only — the operator opts into
the rebuild with `update: true`. Mapping diff is fragile (Atlas may
normalize defaults), so an over-eager auto-update would silently
rebuild production indexes on every deploy.

Orphan handling is **report-only by default**. Search indexes
present on the collection but not declared via `mongo_search_index`
appear in `:orphans` and are dropped only under `drop: true`. Each
drop carries its own `drop_search:<coll>:<name>` confirm-token
envelope automatically; you don't supply the token at the DSL level.

### Rake tasks

```bash
# Dry-run across every Parse::Object subclass that declares mongo_index:
rake parse:mongo:indexes:plan

# Filter to one class:
rake parse:mongo:indexes:plan CLASS=Car

# Apply additive changes (requires writer URI + index_mutations_enabled + env var):
PARSE_MONGO_INDEX_MUTATIONS=1 rake parse:mongo:indexes:apply

# Also drop orphans:
PARSE_MONGO_INDEX_MUTATIONS=1 DROP=true rake parse:mongo:indexes:apply

# Search-index counterparts (require mongo_search_index declarations):
rake parse:mongo:search_indexes:plan
PARSE_MONGO_INDEX_MUTATIONS=1 rake parse:mongo:search_indexes:apply
PARSE_MONGO_INDEX_MUTATIONS=1 UPDATE=true rake parse:mongo:search_indexes:apply   # rebuild drifted
PARSE_MONGO_INDEX_MUTATIONS=1 DROP=true   rake parse:mongo:search_indexes:apply   # drop orphans
PARSE_MONGO_INDEX_MUTATIONS=1 WAIT=true   rake parse:mongo:search_indexes:apply   # block until READY
```

The `apply` task re-states all three gates up-front with
operator-readable error messages so a missing configuration surfaces
as one readable failure rather than N stack traces. The
`search_indexes:apply` task uses the same three gates, plus `UPDATE`
/ `DROP` / `WAIT` / `WAIT_TIMEOUT` env vars to control drift /
orphan / readiness behavior.

### Inspection via `Model.describe(:indexes, network: true)`

```ruby
Car.describe(:indexes, network: true)
# => { class_name: "Car",
#      indexes: {
#        available: true, count: 7,
#        indexes: [ { name: "_id_", implicit_id: true, key: {"_id" => 1}, ... }, ... ],
#        declared: [...], drift: { to_create: [...], in_sync: [...], orphans: [...], conflicts: [...] },
#        parse_managed: ["_id_"],
#        capacity: { used: 7, after: 7, remaining: 57, ok: true },
#        relations: { "_Join:drivers:Car" => { ... } } } }

# Optional $indexStats usage counters:
Car.describe(:indexes, network: true, usage: true)
# Each index entry gains a :usage sub-hash with ops + since timestamp.
# Top-level :usage_available reports whether the role can run $indexStats.
```

---

## Quick start

```ruby
# 1. Gemfile
# gem "mongo", "~> 2.18"

# 2. Connect (resolves ANALYTICS_DATABASE_URI, falling back to DATABASE_URI)
require "parse/mongodb"
Parse::MongoDB.configure(enabled: true)

# 3. Model
class Post < Parse::Object
  property :title, :string
  belongs_to :author, class_name: "Author"
end

class Author < Parse::Object
  property :name, :string
  parse_reference
end

# 4. Query
posts_with_authors = Parse::MongoDB.aggregate("Post", [
  { "$lookup" => {
    "from"         => "Author",
    "localField"   => "_p_author",
    "foreignField" => "parseReference",
    "as"           => "_included_author",
  } },
  { "$unwind" => { "path" => "$_included_author",
                   "preserveNullAndEmptyArrays" => true } },
  { "$limit" => 100 },
])

# 5. Convert
Parse::MongoDB.convert_documents_to_parse(posts_with_authors, "Post").each do |doc|
  puts "#{doc["title"]} by #{doc.dig("author", "name")}"
end
```

---

## Troubleshooting

**`Parse::MongoDB::GemNotAvailable`.** The `mongo` gem isn't installed.
Add it to your Gemfile.

**`Parse::MongoDB::NotEnabled`.** You forgot
`Parse::MongoDB.configure(uri:, enabled: true)` or `enabled: false` was
passed.

**`$lookup` returns empty arrays.** Either the `localField` isn't
`_p_*` (you wrote the logical Parse name, not the MongoDB column), or
the foreign class doesn't have `parseReference` populated (declare
`parse_reference` and backfill via rake, or switch to the `$split`
form).

**Pipeline returns documents but `convert_documents_to_parse` strips
fields.** Internal fields starting with `_` (other than `_id`,
`_p_*`, `_created_at`, `_updated_at`, `_acl`, `_included_*`) are
dropped intentionally. Project them under a non-underscore name in the
pipeline.

**`Parse::MongoDB::DeniedOperator`.** A `$where` / `$function` /
`$accumulator` / mutation operator appeared somewhere in the pipeline.
The validator walks recursively; the operator might be nested deep
inside `$facet` or `$lookup.pipeline`.

**`Parse::MongoDB::ExecutionTimeout`.** The query exceeded the
`max_time_ms` budget. Narrow the filter, add an index, or raise the
budget.

**Aggregation results come back missing fields.** When `$group` is in
the pipeline, the resulting `_id` is the group key, not a document id.
Use `Query::Aggregation#results` (which returns
`Parse::AggregationResult` instances) instead of decoding rows as
`Parse::Object`.
