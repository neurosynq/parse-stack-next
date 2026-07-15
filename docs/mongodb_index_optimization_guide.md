# MongoDB Index Optimization Guide

How to think about MongoDB indexes when running Parse Server on top of
Mongo, and how to wield the `mongo_index` / `mongo_relation_index` DSL
in `parse-stack` to land the indexes you actually need without exhausting
the 64-per-collection budget.

This guide assumes familiarity with the API surface — see
[mongodb_direct_guide.md](./mongodb_direct_guide.md) for the
declaration / migration / writer-URI mechanics. This document is about
**WHEN to add an index, WHICH shape to use, and WHEN to drop one**.

---

## TL;DR

- Add an index for every read pattern you run more than ~once per
  second per host. Below that rate, a collection scan is usually fine.
- For compound indexes, order fields by **ESR**: Equality, Sort, Range.
- For Parse Relations, the reverse-direction index (`relatedId`) is
  often heavier-used than the forward — declare `bidirectional: true`.
- Drop indexes whose `$indexStats` ops counter stays at 0 across a few
  weeks of normal traffic.
- The 64-index-per-collection cap exists for a reason: every write
  pays the cost of every index. Don't index columns you only read.

---

## When to add an index

The right way to ask: **"is this query slow at production scale?"**
not "should I index this column?". An unindexed column is fine when:

- The collection has few documents (< 10k) — the scan is cheap.
- The query runs rarely (background jobs, admin tools, debugging).
- The query is selective enough that other indexes already prune the
  candidate set down to a small handful before the unindexed predicate runs.

An index is needed when:

- The query runs in a hot path — request response, agent tool, public
  API. Latency budget matters.
- The collection is large (> 100k documents).
- The query predicate selectivity is high — a small fraction of rows match.
- You're sorting on the column for paged results (`order(:field.desc)`).

### Read/write tradeoff

Every index costs **write amplification**: each `INSERT` / `UPDATE` /
`DELETE` rebuilds the entry in every index that touches the affected
fields. A collection with 8 indexes pays 8× the write cost of one
without. For high-throughput write paths, fewer indexes wins. For
read-heavy paths, more indexes wins.

Parse-stack collections are usually read-heavy (Parse apps tend to
read 10–100× more than they write), so the budget skews toward
indexing. But monitor it — `$indexStats` will tell you if you're
paying for an index nobody uses.

---

## Index types in parse-on-Mongo

| Type | DSL spelling | When to use |
|---|---|---|
| Regular B-tree | `mongo_index :field` | Equality, range, sort on a scalar field |
| Compound | `mongo_index :a, :b, :c` | Multi-field queries with a common prefix |
| Unique | `mongo_index :field, unique: true` | Enforce uniqueness at the DB layer |
| Unique dedup floor | `unique_index_on :a, :b` | Name the `first_or_create!` / `create_or_update!` dedup tuple; sugar for `unique: true` (non-sparse) |
| Sparse | `mongo_index :field, sparse: true` | Field present on only some documents |
| Partial | `mongo_index :field, partial: { … }` | Index only documents matching a filter |
| TTL | `mongo_index :field, expire_after: N` | Auto-delete documents N seconds after the timestamp |
| 2dsphere (geo) | `mongo_geo_index :location` | Geographic queries on `geopoint` columns |
| Relation | `mongo_relation_index :field, bidirectional: true` | Indexes on `_Join:*` collections |

Hashed and text indexes are intentionally not exposed via the DSL yet
— if you need them, declare via `Parse::MongoDB.create_index`
directly. Atlas Search indexes use a different mechanism (the
`createSearchIndexes` / `dropSearchIndex` / `updateSearchIndex`
commands) and are managed imperatively rather than via the DSL — see
the "Atlas Search indexes" section below.

---

## Compound indexes: the ESR rule

The single most important compound-index rule: **Equality, Sort,
Range** — in that order, left to right.

Given a query like:

```ruby
Song.query(:artist => "ArtistName",        # equality
           :released.between(2020, 2024))  # range
   .order(:plays.desc)                     # sort
```

The optimal index is:

```ruby
mongo_index :artist,   # E — equality narrows fastest
            :plays,    # S — sort piggybacks on index order
            :released  # R — range further narrows the sorted set
```

The MongoDB query planner uses the leftmost-prefix of a compound
index. So `{artist:1, plays:-1, released:1}` can serve:

- Queries on `artist` alone
- Queries on `artist` + `plays`
- Queries on `artist` + `plays` + `released`
- Sorts on `plays` after filtering by `artist`

It **cannot** efficiently serve:

- Queries on `plays` alone (no leftmost `artist`)
- Queries on `released` alone

When in doubt, run `Query#explain` and look at the `winningPlan` —
look for `IXSCAN` (index scan) vs `COLLSCAN` (full collection scan).

### Order matters: getting it wrong costs an index

Putting Range before Sort is the most common mistake:

```ruby
# WRONG ORDER for the query above:
mongo_index :artist, :released, :plays
# Mongo must scan a range first, then sort in memory — defeats the index.
```

The compound forms ONE index, so picking the wrong order means
declaring a SECOND index to fix it later — eating another slot from
your 64-per-collection budget.

### Sort direction matters less than you'd think

`{plays:-1}` and `{plays:1}` can both serve `.order(:plays)` AND
`.order(:plays.desc)` — MongoDB walks the index in either direction.
The direction only matters when the SORT crosses fields:

```ruby
# These two indexes are NOT interchangeable for serving
# .order(:released.asc, :plays.desc):
mongo_index :released, :plays           # serves released ASC, plays ASC
mongo_index :released, name: "rel_p_neg", # serves released ASC, plays DESC
# ...but in the second case you need {released:1, plays:-1} explicitly.
```

For most Parse models, single-direction indexes are fine. Worry about
multi-direction only when you have multi-field `order` clauses.

---

## Parse-Stack-specific patterns

### `belongs_to` → `_p_` pointer columns

Parse stores `belongs_to :owner` as the column `_p_owner` (typed
string `"User$objectId"`). The DSL auto-rewrites:

```ruby
class Post < Parse::Object
  belongs_to :owner, as: :user
  mongo_index :owner       # → declared as _p_owner under the hood
end
```

**Every `belongs_to` that you filter on regularly should be indexed.**
This is the single highest-payoff index pattern in Parse-on-Mongo
schemas — without it, "fetch all posts by this user" is a full scan
of `Post` for every request.

If you also sort, make it a compound:

```ruby
mongo_index :owner, :created_at  # belongs_to + chronological
```

### `parse_reference` uniqueness

Auto-registered by the `parse_reference` declaration as
`unique: true, sparse: true`. The synchronize_create correctness
floor depends on this index existing.

Opt out only when you're certain duplicates are intentional:

```ruby
parse_reference unique_index: false  # index without unique constraint
parse_reference index: false         # no index at all
```

### `_rperm` / `_wperm` ACL filtering

Parse stores per-row ACL as arrays in `_rperm` / `_wperm`. When the
SDK runs scoped queries (under `session_token:`, `acl_user:`, or
`acl_role:`), it injects a `$match` on `_rperm` that includes the
caller's claim set. Without an index on `_rperm`, every ACL-scoped
query is a collection scan with row-level filtering.

```ruby
# For any class with significant per-row ACLs:
mongo_index :_rperm   # ACL read predicate scan
# Don't compound with another array — Mongo's parallel-array rule
# applies. The DSL catches this at registration time.
```

For very heavy multi-tenant patterns, partial indexes on `_rperm`
serving specific role claim shapes can help — but that's a tuning
problem, not a default. Add `_rperm` indexes only where ACL queries
show up in `$indexStats`-derived hot lists.

### Relation join collections

Parse Relations store one document per (owner, related) edge in
`_Join:<field>:<ParentClass>`. The two columns are `owningId` (the
parent's objectId) and `relatedId` (the related's objectId). Both
are plain string objectIds, not BSON ObjectIds.

Two access patterns matter:

- **Forward**: "what's related to this owner?" — needs `{owningId: 1}`
- **Reverse**: "which owners contain this related object?" — needs `{relatedId: 1}`

For `Parse::Role.users`, the reverse direction is canonically the
heavier-used one (every auth call needs "which roles is this user
in?"). For most other relations, forward dominates.

```ruby
class Parse::Role < Parse::Object
  has_many :users, through: :relation
  mongo_relation_index :users, bidirectional: true
end
```

If only one direction is hot, drop `bidirectional:` and pay for just
one index from the budget.

---

## The 64-index-per-collection cap

MongoDB hard-caps indexes at 64 per collection. The migrator enforces
this at plan time — if `existing + to_create > 64`, `apply!` returns
`{capacity_blocked: true, ...}` without issuing any creates.

Parse Server auto-creates several indexes you don't see in
declarations (`_id_`, `_username_unique`, `_email_unique`,
`_session_token_*`, etc.). They count against your 64.

### Budget per collection size

Rough guidance for healthy budgets:

| Collection size | Reasonable index count |
|---|---|
| < 10k documents | 1–3 (just `_id_` plus the obvious belongs_to) |
| 10k – 1M | 5–12 |
| 1M – 100M | 10–25 |
| > 100M | 15–40, but tune aggressively |

If you're approaching 50 indexes on one collection, you've probably
duplicated work — multiple compounds that subsume each other. Audit
with `$indexStats`.

### How to choose what to drop

Use `Model.describe(:indexes, network: true, usage: true)`:

```ruby
Song.describe(:indexes, network: true, usage: true)
# Each index entry includes a :usage sub-hash with `ops` (count since
# last Mongo restart) and `since` (the restart timestamp).
```

Heuristics for dropping:

- **`ops == 0` and the Mongo restart was > 14 days ago** → almost
  certainly unused. The `since` field tells you the counting window;
  if it's recent, wait longer.
- **One compound subsumes another** → keep only the most-specific. A
  `{a:1, b:1, c:1}` index serves all queries on `{a:1}` alone and on
  `{a:1, b:1}`, so dropping those shorter compounds is safe IF the
  query planner picks the long one (verify with `explain`).
- **`ops` is < 1% of `_id_`'s ops** → the index is rarely useful;
  consider whether the queries that use it can be served by another
  index.

`$indexStats` resets on Mongo restart. Don't drop based on the first
day's data — sample a few weeks.

---

## Common mistakes

### Indexing every field

The reflex to "just add an index" creates a different problem: every
write hits every index. Saving a `Song` with 10 indexes is 10× the
work of saving one with 1.

**Better:** start with the indexes the obvious belongs_to columns and
`parse_reference` need, then add as you find slow queries.

### Wrong compound order

Putting Range or Sort before Equality means the index doesn't help
the predominant query — and now you've spent one of your 64 slots on
something useless.

**Better:** write the actual query first, then derive the index
ordering via ESR.

### Unique on null-heavy fields without sparse

A plain `unique: true` index treats `null` (and missing) as a value.
You can have ONE document with `field: null` before the constraint
fails.

**Better:** `unique: true, sparse: true` for "unique when present".
This is exactly what `parse_reference` auto-registers, and it's the
right pattern for any optional uniqueness constraint *on a single
field*.

**Sparse does NOT generalize to compound keys.** A compound sparse
index excludes a document only when it is missing *every* indexed
field; a document that has at least one key is still indexed. So for a
two-field tuple, two rows that share the present field and both omit
the other still collide under `sparse: true`. For "unique within a
subset" — e.g. unique `email` per `tenant`, but tenant-less rows may
repeat — use a **partial filter**, not sparse:

```ruby
unique_index_on :email, :tenant,
                partial: { "_p_tenant" => { "$exists" => true } }
```

For the `first_or_create!` / `create_or_update!` dedup tuple, prefer
`unique_index_on` (sugar for `unique: true`, **non-sparse** by default
so the index key matches the query the upsert re-runs on recovery). It
is the durable correctness floor behind the synchronize-create lock —
see the MongoDB Direct guide for the full rationale.

### Geo without proper coordinate order

GeoJSON `Point` coordinates are `[longitude, latitude]`, in that
order. Latitude-first will index but return wrong results for
proximity queries.

**Better:** `mongo_geo_index :location` and let parse-stack's
`Parse::GeoPoint` serializer handle the order. Avoid hand-crafted
`{type: "Point", coordinates: [...]}` documents.

### Parallel arrays in a compound

`mongo_index :tags, :categories` — both fields hold arrays — fails
at apply time with "cannot index parallel arrays". The DSL catches
this at registration, but the equivalent in raw `Parse::MongoDB.create_index`
calls bypasses the guard.

**Better:** declare two separate single-field indexes, or use
`Parse::MongoDB.create_index` with the same parallel-array guard
applied to the keys hash.

### Indexing `_id` explicitly

MongoDB auto-creates `_id_` (the primary key). Declaring `mongo_index :_id`
either creates a redundant index or triggers an `IndexOptionsConflict`.
The DSL rejects this at registration.

**Better:** trust the implicit `_id_`. Don't try to control it.

---

## Workflow: discover → plan → apply

Typical lifecycle for an index addition:

1. **Discover the slow query.** Use `Parse::Query#explain` (mongo-direct
   path) or `db.collection.explain()` to confirm a `COLLSCAN`. Look at
   `executionStats.totalDocsExamined` vs the actual result size — if
   they diverge, an index would help.

2. **Plan the index.** Apply ESR to the query shape. Pick the field
   order. Decide unique/sparse/partial.

3. **Declare in the model.** Add `mongo_index :a, :b, ...` to the
   model file. The class loads — validation runs.

4. **Plan in dry-run.** Run `Model.indexes_plan` (or the rake task)
   to confirm the migrator sees the declaration and classifies it as
   `to_create`. Verify capacity headroom.

5. **Apply.** With the writer URI configured and the triple-gate flipped:
   ```bash
   PARSE_MONGO_INDEX_MUTATIONS=1 rake parse:mongo:indexes:apply CLASS=Song
   ```
   The migrator is additive — never drops without `DROP=true`.

6. **Verify.** Re-run the slow query, check `explain` shows `IXSCAN`.
   Check `Model.describe(:indexes, network: true, usage: true)` shows
   ops counting up.

7. **Monitor.** Periodic `$indexStats` audits catch indexes that
   stopped being useful when query patterns shifted.

---

## Atlas Search indexes

Atlas Search indexes are a different beast from regular MongoDB indexes
and live on a different infrastructure path. They are NOT covered by
the `mongo_index` DSL or `parse:mongo:indexes:apply`. They are not
counted against the 64-index-per-collection cap (separate budget,
separate node). Use them for **full-text search, autocomplete, faceted
search, and vector similarity** — workloads a B-tree can't satisfy.

### When to reach for an Atlas Search index instead of a regular one

| Workload | Right tool |
|---|---|
| `find_by_title("exact match")` | regular index on `title` |
| `find_by_title_prefix("hel")` | regular index on `title` (uses `^hel` regex anchored) |
| Substring match: `title CONTAINS "ello"` | **Atlas Search** (`text` analyzer) |
| Misspelling tolerance: `helo` matches `hello` | **Atlas Search** (`text` + fuzzy) |
| Typeahead / autocomplete | **Atlas Search** (`autocomplete` field type) |
| Multi-field ranked search ("title OR body OR tags") | **Atlas Search** (compound query, BM25 scoring) |
| Facet counts (genre histogram) | **Atlas Search** (`$searchMeta`, `facet` operator) |
| Vector similarity (embeddings) | **Atlas Search** (`vectorSearch` index type) |

If the query plan compiles to a `$text` stage or a `^anchored` regex,
a regular index is enough. If the query needs ranking, fuzziness, or
analyzer-driven tokenization, you want Atlas Search.

### Declaring vs. managing

Regular indexes are **declared** on the model (`mongo_index :title`)
and reconciled by `parse:mongo:indexes:apply`. Atlas Search indexes
follow the same pattern with `mongo_search_index` + a parallel rake
task, but with looser semantics — definitions are opaque (the DSL
doesn't introspect field references; Atlas owns the mapping shape),
drift is reported-and-refused rather than auto-applied, and builds
run asynchronously so the rake task is fire-and-forget by default.

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
  mongo_search_index "song_autocomplete", {
    mappings: { fields: {
      title: { type: "autocomplete", tokenization: "edgeGram" },
    } },
  }
end

Song.search_indexes_plan        # dry-run
Song.apply_search_indexes!      # additive — only creates to_create
Song.apply_search_indexes!(update: true, wait: true)  # rebuild drifted, block until READY
```

If you don't want the DSL — for one-off scripts, a model that needs
analyzers that don't round-trip cleanly, or a vector-search index
whose definition lives in a separate JSON file — call the raw
`Parse::AtlasSearch::IndexManager` / `Parse::MongoDB` primitives
directly. Both routes use the same writer connection and the same
triple-gate.

The triple-gate (writer URI + `index_mutations_enabled` +
`ENV["PARSE_MONGO_INDEX_MUTATIONS"]`) applies the same way it does
for regular index mutations. The writer role additionally needs the
`createSearchIndexes` / `dropSearchIndex` / `updateSearchIndex` /
`listSearchIndexes` Mongo actions granted by your operator.

### Creating an Atlas Search index

```ruby
Parse::AtlasSearch::IndexManager.create_index(
  "Song",
  "song_search",
  {
    mappings: {
      dynamic: false,
      fields: {
        title:  { type: "string", analyzer: "lucene.standard" },
        artist: { type: "string", analyzer: "lucene.standard" },
        tags:   { type: "string" },
      },
    },
  },
)
# => :created  (build is async)
```

Return values mirror the regular-index primitives: `:created` on
submission, `:exists` when an index with that name is already present.
The wrapper (`Parse::AtlasSearch::IndexManager.create_index`) clears
the IndexManager's process-local index cache after a successful
submission so subsequent introspection sees the new index. The
underlying primitive (`Parse::MongoDB.create_search_index`) does NOT
touch the cache — callers using it directly must invalidate manually
via `IndexManager.clear_cache(collection_name)`.

**Idempotency is name-based, not definition-based.** If you re-run
`create_index` with a different `definition:` against an existing
name, the call returns `:exists` and silently does nothing. To change
a definition, call `update_index` explicitly.

### Dropping an Atlas Search index

```ruby
Parse::AtlasSearch::IndexManager.drop_index(
  "Song",
  "song_search",
  confirm: "drop_search:Song:song_search",
)
# => :dropped
```

The confirm-token prefix is `drop_search:` (not `drop:`) so a token
prepared for a regular `Parse::MongoDB.drop_index` call cannot be
replayed against a search index that happens to share its name, and
vice versa.

### Replacing an Atlas Search index definition

```ruby
Parse::AtlasSearch::IndexManager.update_index(
  "Song",
  "song_search",
  { mappings: { dynamic: true } },
)
# => :updated
```

`update_index` requires the named index to already exist (raises
`ArgumentError` otherwise — use `create_index` for new indexes). The
rebuild runs asynchronously; the new mapping is not live until the
index returns to `READY` status.

### Waiting for an async build (and a footgun)

Atlas Search builds are not synchronous. `create_index` and
`update_index` return as soon as the command is accepted; the index
transitions through `BUILDING` to `READY` over seconds to minutes
depending on collection size and definition complexity.

The naive polling pattern has a sharp edge — the IndexManager's
default cache TTL is 300 seconds, and a poll loop that hits
`index_ready?` immediately after a mutation will cache the
`queryable: false` BUILDING state for up to five minutes:

```ruby
# ANTI-PATTERN — caches the BUILDING state
Parse::AtlasSearch::IndexManager.create_index("Song", "song_search", definition)
until Parse::AtlasSearch::IndexManager.index_ready?("Song", "song_search")
  sleep 2
end
# Loops for the full TTL even after the index goes READY.
```

Use `wait_for_ready` instead — it polls `list_indexes` with
`force_refresh: true` on every iteration so the cache cannot lock in
the BUILDING state, and surfaces `:failed` and `:timeout` outcomes
explicitly:

```ruby
Parse::AtlasSearch::IndexManager.create_index("Song", "song_search", definition)

case Parse::AtlasSearch::IndexManager.wait_for_ready(
  "Song", "song_search", timeout: 600, interval: 5,
)
when :ready   then # index is queryable
when :failed  then raise "search index build failed"
when :timeout then raise "search index did not become ready within 600s"
end
```

If you have a reason to roll your own loop (custom timeout strategy,
sidecar process polling, etc.), pass `force_refresh: true` to
`list_indexes` on every iteration, or lower the cache TTL globally:

```ruby
Parse::AtlasSearch::IndexManager.cache_ttl = 30  # or 0 to disable
```

### Budget and write cost

Atlas Search indexes have a separate per-cluster limit set by Atlas
(typically generous — dozens per collection). They DO carry an
ongoing cost: every write to an indexed field triggers a search-side
update. The same "don't index what you don't search" discipline
applies — a `mappings.dynamic: true` index over a write-heavy
collection will silently double or triple your storage and update
load.

If you're paying for Atlas Search, prefer **explicit field mappings**
(`mappings.dynamic: false` with an enumerated `fields:` map) over
`dynamic: true` for any collection above ~10k docs or above modest
write throughput. Dynamic mappings are convenient for prototyping;
explicit mappings are correct for production.

### What lives where

| Concern | Path |
|---|---|
| `mongo_index :foo` declarations + migrator | `Parse::Core::Indexing`, `Parse::Schema::IndexMigrator` |
| `mongo_search_index "name", { mappings: { … } }` declarations + migrator | `Parse::Core::SearchIndexing`, `Parse::Schema::SearchIndexMigrator` |
| `Parse::MongoDB.create_index` / `drop_index` (regular indexes) | `lib/parse/mongodb.rb` |
| `Parse::MongoDB.create_search_index` / `drop_search_index` / `update_search_index` (Atlas) | `lib/parse/mongodb.rb` |
| `Parse::AtlasSearch::IndexManager.create_index` / `drop_index` / `update_index` (cache-invalidating wrappers) | `lib/parse/atlas_search/index_manager.rb` |
| `rake parse:mongo:search_indexes:plan` / `:apply` | `lib/parse/stack/tasks.rb` |
| Search query execution | `Parse::AtlasSearch.search` / `.autocomplete` / `.faceted_search` |

---

## When NOT to add an index

- **Low-cardinality columns.** Indexing a boolean `is_active` is
  almost never useful — the index points to ~half the collection.
  Better to filter with another index that already narrows the set.
- **Write-only / append-only collections.** Audit logs, event
  streams, telemetry data. Reads are rare; indexes pay the write
  cost without recouping it.
- **Columns you only access in `$lookup` from one side.** The
  foreign-side join column needs an index (the side you're looking
  INTO), but the local side doesn't need a duplicate.
- **Columns Parse Server already manages.** Don't shadow Parse's
  auto-managed indexes on `_User.username`, `_User.email`, etc.
  Parse maintains them; the migrator excludes them from drift
  analysis but won't stop you from creating a competing one.
- **As a "just in case".** Empty `ops` after a few weeks of
  production traffic is your answer.

---

## See also

- [mongodb_direct_guide.md](./mongodb_direct_guide.md) — the full
  direct-Mongo / index-management API reference (DSL spelling,
  writer URI, triple-gate, rake tasks)
- [acl_clp_guide.md](./acl_clp_guide.md) — security posture around
  the writer URI, role validation, and ACL/CLP enforcement on the
  mongo-direct path
- MongoDB official: <https://www.mongodb.com/docs/manual/indexes/>
- Parse Server source for auto-managed indexes:
  <https://github.com/parse-community/parse-server/blob/master/src/Adapters/Storage/Mongo/MongoStorageAdapter.js>
