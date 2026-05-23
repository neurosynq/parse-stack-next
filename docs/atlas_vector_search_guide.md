# Atlas Vector Search Guide

Parse Stack v5.0 ships first-class support for MongoDB Atlas
`$vectorSearch` against Parse classes. This guide covers the full
surface: declaring `:vector` properties, registering embedding
providers, running `find_similar` queries, the `embed` write-side
macro, Atlas index management, AS::N telemetry, and the constraint and
logging behavior callers need to know about.

For the underlying mongo-direct enforcement model that vector search
inherits, see [mongodb_direct_guide.md](./mongodb_direct_guide.md).

---

## When to use vector search

Use Atlas vector search when:

* You need semantic similarity ("articles about X" where "about X" is
  a meaning, not a substring) rather than substring / token matches.
* Your records have a natural text or image embedding source (title +
  body, transcript, caption, etc.).
* You are already running on MongoDB Atlas, or on a self-managed
  cluster with the search/vectorSearch extension available. Atlas
  Local works for development and integration tests.

Do NOT use vector search for:

* Exact / substring matching — use Parse's normal query operators or
  Atlas `$search` text indexes (see Atlas Search docs).
* Tiny corpora (< a few hundred docs) where a brute-force cosine in
  application code would be cheaper than maintaining an index.

---

## Declaring a `:vector` property

`:vector` is a first-class Parse property type. The declaration
captures the vector's width, the provider that produces it, the model
name, and the similarity function the Atlas index will use.

```ruby
class Document < Parse::Object
  property :title, :string
  property :body,  :string

  property :body_embedding, :vector,
           dimensions: 1536,
           provider:   :openai,
           model:      "text-embedding-3-small",
           similarity: :cosine
end
```

* `dimensions:` (required) — fixed output width. Must match what the
  registered provider returns and what the Atlas vectorSearch index
  declares. Mismatches raise `Parse::Embeddings::InvalidResponseError`
  on write or `Parse::VectorSearch::InvalidQueryVector` on read.
* `provider:` — name registered via `Parse::Embeddings.register` or
  `Parse::Embeddings.configure`. Required for the `embed` macro and for
  the `find_similar(text:)` overload; optional if you only ever pass
  pre-computed `vector:` Arrays.
* `model:` — stable identifier, persisted to `embedding_meta` and used
  in cache keys. Changing this on an existing field is a migration —
  see the §Re-embedding section below.
* `similarity:` — one of `:cosine`, `:dotProduct`, `:euclidean`.
  Determines how the Atlas index ranks. Pick `:cosine` for normalized
  text embeddings; `:dotProduct` for raw OpenAI/Cohere output if you
  want to skip the unit-normalize step.

### Storage shape

`:vector` properties serialize as plain BSON arrays of floats. There
is no Parse-side wrapper class on the wire. In memory they are
`Parse::Vector` instances which respond to `to_a`, `dimensions`, and
arithmetic helpers.

### Constraint refusal

Vector fields are NOT general-purpose query targets. The query builder
refuses every operator on `:vector` columns except `:exists` and
`:null`. Attempting `where(body_embedding: <Array>)` or
`where(:body_embedding.gt => 0.5)` raises at query build time — semantic
similarity must go through `find_similar`, not the normal `where` DSL.

### Body builder compaction

When `Parse::Object#inspect` or the request logger has to print a
record carrying a vector, the formatter replaces the array with a
compact `<vector dims=N>` placeholder once the length is ≥ 32. This
keeps multi-thousand-dim arrays out of error trackers and stack
traces. The wire payload itself is unchanged.

---

## Registering an embedding provider

`Parse::Embeddings` is a pluggable registry. v5.0 ships seven built-in
providers:

* `Parse::Embeddings::OpenAI` — text-only. `text-embedding-3-small`
  (1536-dim, default), `text-embedding-3-large` (3072-dim, Matryoshka via
  `dimensions:`), legacy `text-embedding-ada-002`. Forwards
  `OpenAI-Organization` / `OpenAI-Project` headers when supplied.
* `Parse::Embeddings::Cohere` — v3 family (`embed-english-v3.0`,
  `embed-multilingual-v3.0`, and `-light-v3.0` siblings; 1024 / 384 dim)
  plus `embed-v4.0` (1536 native, 128k token context, Matryoshka-
  truncatable to {256, 512, 1024, 1536} via `dimensions:`). `embed-v4.0`
  is Cohere's text+image multimodal endpoint at the network boundary;
  this release wires the **text path only** — `embed_image` lands in
  v5.1.
* `Parse::Embeddings::Voyage` — voyage-4 family (`voyage-4-large` 2048,
  Matryoshka; `voyage-4` 1024; `voyage-4-lite` 512; `voyage-4-nano` 256),
  voyage-3 family, domain models (`voyage-code-3`, `voyage-finance-2`,
  `voyage-law-2`), and `voyage-multimodal-3` (1024-dim, 32k token
  context, routes to `/v1/multimodalembeddings` with the wrapped
  `{inputs: [{content: [{type: "text", text: ...}]}]}` envelope). Text
  inputs only in v5.0 — image content rows land in v5.1.
* `Parse::Embeddings::Jina` — `jina-embeddings-v3` (1024, Matryoshka
  32–1024), `jina-embeddings-v4` (2048, Matryoshka), v5 family
  (`jina-embeddings-v5-text-{small,nano}`,
  `jina-embeddings-v5-omni-{small,nano}` — omni accepts plain-text
  here), and `jina-code-embeddings-{0.5b,1.5b}`. Distinguishes
  `input_type:` via Jina's `task` field
  (`retrieval.query` / `retrieval.passage` / `classification` /
  `separation`). Rerankers and image-only models are out of scope.
* `Parse::Embeddings::Qwen` — `qwen3-embedding-0.6b` (1024),
  `qwen3-embedding-4b` (2560), `qwen3-embedding-8b` (4096), all
  Matryoshka. Targets Alibaba Cloud DashScope's OpenAI-compatible
  endpoint; operators in mainland China override `base_url:` to
  `https://dashscope.aliyuncs.com/compatible-mode/v1`. Same checkpoints
  are open-weight on Hugging Face (Apache 2.0) — self-host with
  `LocalHTTP`.
* `Parse::Embeddings::LocalHTTP` — generic OpenAI-compatible client for
  self-hosted gateways (Ollama, LM Studio, vLLM, Text Embeddings
  Inference, llama.cpp). Configure-time SSRF gate refuses loopback /
  RFC1918 / link-local / cloud-metadata bases unless opted in with
  `allow_private_endpoint: true` (emits a `Kernel#warn` audit line).
* `Parse::Embeddings::Fixture` — deterministic, zero-network. Used by
  the test suite. Auto-registered under `:fixture`, no setup required.

### Production: OpenAI

```ruby
Parse::Embeddings.configure do |c|
  c.providers[:openai] = Parse::Embeddings::OpenAI.new(
    api_key: ENV.fetch("OPENAI_API_KEY"),
    model:   "text-embedding-3-small",
  )
end
```

The OpenAI provider self-bounds at 30 s read / 5 s connect with
capped exponential retry on 429 and 5xx. There is no implicit
wall-clock deadline imposed by `find_similar` or by the `embed`
macro — the provider is responsible for bounding its own request
time. Custom providers MUST follow the same convention.

### Tests: Fixture

```ruby
provider = Parse::Embeddings.provider(:fixture)  # zero-config
vec = provider.embed_text(["hello"]).first       # deterministic
```

Vectors are derived from SHA-256 over `(model_name, input_type, input)`
and unit-normalized. Same input always yields the same vector;
`:search_query` and `:search_document` yield different vectors for the
same string, so cache-key bugs and input-type confusion in higher
layers surface in tests rather than only against real providers in
production.

### Custom providers

Subclass `Parse::Embeddings::Provider` and override `embed_text`,
`dimensions`, and `model_name`. Call `instrument_embed(input_count,
input_type) { ... }` inside `embed_text` to emit the standard AS::N
event (see §Telemetry below). Always call `validate_response!` before
returning so off-by-one batches and NaN/±Inf poisoning surface as
typed `InvalidResponseError` at the provider boundary, not deep inside
a later `$vectorSearch` call.

---

## Creating the Atlas vectorSearch index

`find_similar` requires a deployed Atlas vectorSearch index covering
the target field. Create one via `Parse::AtlasSearch::IndexCatalog`:

```ruby
Parse::AtlasSearch::IndexCatalog.create_index(
  "Document",                       # Parse class / collection name
  "body_embedding_v1",              # index name (your choice)
  {
    type: "vectorSearch",
    fields: [
      {
        type: "vector",
        path: "body_embedding",
        numDimensions: 1536,
        similarity: "cosine",
      },
      # Optional: filter fields for pre-search $match acceleration.
      { type: "filter", path: "tag" },
      { type: "filter", path: "_rperm" },
    ],
  },
)
```

Including `_rperm` as a filter field lets the per-row ACL match
short-circuit at the index level — strongly recommended for any
field that ACL-scoped agents will search against.

Index creation runs asynchronously. Use `wait_for_ready` to block
until the index is queryable:

```ruby
Parse::AtlasSearch::IndexCatalog.wait_for_ready(
  "Document", "body_embedding_v1", timeout: 600,
)
# => :ready | :failed | :timeout
```

Auto-discovery: when `find_similar` is called without an explicit
`index:` kwarg, the catalog scans the collection's vectorSearch
indexes for one whose definition covers the requested `path`. The
first match wins; pass `index:` explicitly when you have more than
one covering index and want a specific one.

---

## Running similarity queries: `find_similar`

```ruby
# Pre-computed vector
hits = Document.find_similar(vector: query_embedding, k: 10)

# Auto-embed query text using the field's declared provider
hits = Document.find_similar(text: "ruby parse stack", k: 10)

hits.first.vector_score   # => Float, Atlas vectorSearchScore
hits.first.title          # => String, normal Parse attribute
```

Full kwarg surface:

* `vector:` — `Array<Float>` or `Parse::Vector`. Mutually exclusive
  with `text:`.
* `text:` — `String`. Embedded with `input_type: :search_query` using
  the field's declared `provider:`. Capped at 256 KiB; chunk client-
  side before calling if larger.
* `k:` — number of hits to return (default 10).
* `field:` — explicit `:vector` property. Auto-resolves when the class
  has exactly one; required when multiple are declared.
* `filter:` — post-`$vectorSearch` `$match`. Use for ordinary Parse-
  side filtering (e.g. `{ status: "published" }`).
* `vector_filter:` — Atlas-native pre-search filter. Fields must be
  declared `type: "filter"` in the index. Faster than `filter:` when
  the field is filter-indexed.
* `index:` — explicit vectorSearch index name. Skips auto-discovery.
* `num_candidates:` — HNSW search width hint. Higher = better recall,
  slower. Default ~10×k.
* `max_time_ms:` — server-side timeout; translates to
  `Parse::MongoDB::ExecutionTimeout` on cancel.
* `raw:` — when true, return raw `BSON::Document` hashes (each carries
  `_vscore`). When false (default), build `Parse::Object` instances.
* `session_token:` / `master:` / `acl_user:` / `acl_role:` — scope
  kwargs forwarded to the underlying `Parse::MongoDB.aggregate` so the
  5-layer enforcement (denylist, ACL `_rperm` match, CLP,
  protectedFields, master-key escape) runs against the result rows.

### Dimension validation

`find_similar` compares the query vector's length to the property's
declared `dimensions:` before sending the pipeline. A mismatch raises
`Parse::VectorSearch::InvalidQueryVector` locally, before Atlas sees
it — callers get "expected 1536, got 768" instead of a server-side
error after a round-trip.

### ACL/CLP inheritance

Vector search routes through `Parse::MongoDB.aggregate`. Every layer
documented in [mongodb_direct_guide.md §Security](./mongodb_direct_guide.md#security)
applies to vector search result rows too:

1. Pipeline-security denylist (always on).
2. Row-level ACL `_rperm` match — scoped agents only.
3. CLP read enforcement — scoped agents only.
4. `protectedFields` stripping — scoped agents only.
5. Master-key escape hatch.

**REST `/aggregate` is NOT a valid path for vector search with a
scoped caller.** Parse Server's REST aggregate endpoint is master-
key-only and would bypass every per-row ACL and CLP check. The built-
in agent tools auto-promote `mongo_direct: false` to `true` for any
agent carrying `session_token`, `acl_user`, `acl_role`, or a non-
master scope so this enforcement always runs.

---

## Managing embeddings on write: `embed` macro

The `embed` class macro declares which source fields feed a managed
vector. The embedding is recomputed automatically on save whenever
the source fields change.

```ruby
class Document < Parse::Object
  property :title, :string
  property :body,  :string
  property :body_embedding, :vector, dimensions: 1536, provider: :openai

  embed :title, :body, into: :body_embedding
end

doc = Document.new(title: "hello", body: "world")
doc.save        # provider :openai called once; body_embedding populated

doc.body = "updated body"
doc.save        # provider called again; new embedding written

doc.save        # no source field changed → zero provider calls
```

Mechanics:

* A `<into>_digest` `:string` sibling field is auto-declared (override
  with `digest_field:`). The before_save callback computes SHA-256 over
  the concatenated source text; if it matches the stored digest AND
  the target vector is non-nil, the callback returns without
  contacting the provider.
* The target `:vector` property is **write-protected**. Direct
  assignment (`doc.body_embedding = some_vector`) raises
  `ProtectedFieldError`. The guard lifts only inside the managed
  write path. This prevents silent desync between the stored vector
  and the digest.
* Source fields are concatenated with `"\n\n"`, `nil` and blank values
  skipped. If every source is blank, the target and digest are both
  cleared on save.

### Single vector per record (v5.0)

`embed` produces exactly one vector per record. There is no built-in
chunker. Long source text whose concatenation exceeds the provider's
per-call token budget will be truncated provider-side, and the
resulting vector will represent only the leading portion of the
document.

For long-form content in v5.0, two options:

1. **Pre-chunk client-side** and write each chunk as its own
   `Parse::Object` record with its own `embed` declaration.
2. **Dedicated `Chunk` subclass** that `belongs_to` the parent, with
   `embed :content, into: :embedding` on the chunk class itself. Run
   similarity search against the chunk collection, then hydrate
   parents as needed.

A built-in chunker plus a `semantic_search` agent tool are scheduled
for v5.1.

### Re-embedding existing rows

Changing `model:`, `dimensions:`, or `provider:` on an existing
`:vector` property is a migration. Workflow:

1. Add the new property alongside the old one
   (`property :body_embedding_v2, :vector, ...`) and an `embed` block
   targeting it.
2. Backfill: iterate existing rows, force a save (or null+save) to
   trigger the new directive. The old field stays valid for reads.
3. Once backfill completes, deploy a new vectorSearch index covering
   the new field and migrate `find_similar` callers.
4. Drop the old property.

Do NOT mutate the model in place — the digest mechanism will see
unchanged source text and skip recompute, leaving stale vectors.

---

## Telemetry: `parse.embeddings.embed` AS::N

Every provider emits `parse.embeddings.embed` via
`ActiveSupport::Notifications.instrument`. Subscribe to track cost,
latency, and error rate across all embedding spend:

```ruby
ActiveSupport::Notifications.subscribe("parse.embeddings.embed") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  StatsD.increment(
    "parse.embeddings.embed",
    tags: [
      "provider:#{event.payload[:provider]}",
      "model:#{event.payload[:model]}",
      "input_type:#{event.payload[:input_type]}",
      "error:#{event.payload[:error] || 'none'}",
    ],
  )
  StatsD.histogram("parse.embeddings.tokens", event.payload[:total_tokens]) if event.payload[:total_tokens]
  StatsD.timing("parse.embeddings.duration_ms", event.duration)
end
```

Payload contract (keys always present; values may be nil):

| Key            | Type          | Notes                                                                   |
| -------------- | ------------- | ----------------------------------------------------------------------- |
| `:provider`    | `String`      | `provider.class.name` (e.g. `"Parse::Embeddings::OpenAI"`)              |
| `:model`       | `String`      | `provider.model_name`                                                   |
| `:dimensions`  | `Integer`     | `provider.dimensions`                                                   |
| `:input_count` | `Integer`     | batch size                                                              |
| `:input_type`  | `Symbol`      | `:search_query` / `:search_document`                                    |
| `:total_tokens`| `Integer`/nil | provider-reported usage; nil for Fixture and providers without usage    |
| `:cached`      | `Boolean`     | always false in v5.0; reserved for v5.1 embed cache                     |
| `:error`       | `String`/nil  | `exception.class.name` when the block raised — class name only         |

Notes:

* `:error` is the **class name**, never the message. Provider
  exceptions can contain user-supplied text from the API; surfacing
  only the class name keeps PII out of operator dashboards.
* Pre-validation failures (`embed_text` called with non-Array, or
  with non-String elements) do **not** emit an event. The validation
  runs before the instrument block so caller-shape errors aren't
  recorded as embed attempts.
* Subscribers run **synchronously on the request thread**. A slow
  subscriber blocks every embed call. Push to non-blocking sinks
  (StatsD-over-UDP, batched OTel exporters) rather than doing
  filesystem or HTTP I/O inside the subscriber.

---

## Logging and PII considerations

When `find_similar(text:)` is called, the query text is sent over the
wire to the embedding provider. Operators with global Faraday request
logging enabled on the embedding connection will capture the full
query text in the JSON request body. Treat `text:` as user-visible
content for log-handling purposes; redact at the Faraday middleware
layer if your logging pipeline retains payloads.

The vector itself never appears in OpenAI request bodies (text in,
floats out). Vectors only flow through the Parse↔Mongo path, where
the body builder's `<vector dims=N>` compaction prevents them from
landing in stdout / error trackers.

---

## Troubleshooting

**`NoVectorProperty: no :vector property declared on this class`**
The class has no field declared as `:vector`. Add one.

**`AmbiguousVectorField: class declares multiple :vector properties`**
Pass `field: :which_one` to disambiguate.

**`IndexNotResolved: no vectorSearch index found covering Class.field`**
Create the index (see §Creating the Atlas vectorSearch index) or pass
`index:` explicitly.

**`InvalidQueryVector: expected 1536, got 768`**
The query vector's length doesn't match the declared `dimensions:`.
Almost always means the query embedding came from a different model
than the stored embeddings.

**`EmbedderNotConfigured`**
The `:vector` property has no `provider:` declared but `find_similar`
was called with `text:`. Either declare a provider on the property, or
pass an explicit `vector:` Array.

**`ProtectedFieldError: <Class>#<field> is managed by 'embed'`**
User code tried to assign directly to a managed vector field. Update
the declared source fields instead and save.

**`InvalidResponseError: response length 5 != input count 4`**
The provider returned a different number of vectors than inputs. The
provider has a bug — the validation in
`Parse::Embeddings::Provider#validate_response!` caught it before the
misaligned vectors could be stored.

**Atlas Local: index stays `BUILDING` forever**
Atlas Local's internal supervisor periodically restarts `mongod`
during replica-set sync. Use `IndexCatalog.wait_for_ready` (which
bypasses the IndexManager's 300-second cache via `force_refresh: true`
on every poll) rather than a `until index_ready?; sleep` loop.

---

## Reference

Key files:

* `lib/parse/embeddings.rb` — registry, `Configuration`, `register`,
  `provider`, `configure`.
* `lib/parse/embeddings/provider.rb` — abstract base, `validate_response!`,
  `instrument_embed`, AS::N payload contract.
* `lib/parse/embeddings/openai.rb` — OpenAI provider.
* `lib/parse/embeddings/cohere.rb` — Cohere v3 + v4.0 text-mode provider.
* `lib/parse/embeddings/voyage.rb` — Voyage text + multimodal-3
  text-mode provider.
* `lib/parse/embeddings/jina.rb` — Jina v3 / v4 / v5 / code provider.
* `lib/parse/embeddings/qwen.rb` — Qwen3-Embedding via DashScope.
* `lib/parse/embeddings/local_http.rb` — generic OpenAI-compatible
  local-gateway client.
* `lib/parse/embeddings/fixture.rb` — deterministic test provider.
* `lib/parse/model/core/vector_searchable.rb` — `find_similar`.
* `lib/parse/model/core/embed_managed.rb` — `embed` macro.
* `lib/parse/vector_search.rb` — low-level `Parse::VectorSearch.search`.
* `lib/parse/atlas_search/index_manager.rb` — `IndexCatalog.create_index`,
  `find_vector_index`, `wait_for_ready`.
* `lib/parse/mongodb.rb` — direct MongoDB access, 5-layer enforcement.
