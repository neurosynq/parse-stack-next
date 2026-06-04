![parse_stack_next - The Ruby stack for Parse Server](https://raw.githubusercontent.com/neurosynq/parse-stack-next/main/assets/parse-stack-next-banner.png)

# Parse Stack Next

A full-featured Ruby client SDK for [Parse Server](http://parseplatform.org/). [parse-stack-next](https://github.com/neurosynq/parse-stack-next) is a Ruby client SDK, REST client, and Active Model ORM for [Parse Server](http://parseplatform.org/), combining a low-level API client, a query engine, an object-relational mapper (ORM), and a Cloud Code Webhooks rack application in a single gem.

### What's new in 5.2

- **5.2.1 — Webhook triggers receive the full Parse object** — trigger handlers (`beforeSave`/`afterSave`/…) now get the complete server object (`createdAt`/`updatedAt`, `ACL`, internal fields); only live credentials (session tokens, password hashes) are stripped. `Parse::Object#existed?` / `#new?` are reliable in `afterSave`, `afterSave` updates carry dirty tracking, and the model lifecycle runs in ActiveModel order — `before_save → before_create` then `after_create → after_save` — so `before_create` now fires for REST/JS/Auth0 creates (and `after_save` no longer double-fires). See [Cloud Code Triggers](#cloud-code-triggers)
- **Retrieval layer — `Parse::Retrieval` (`Parse::RAG`)** — `Parse::Retrieval.retrieve(query:, klass:, k:, filter:, tenant_scope:, …)` embeds a natural-language query, runs Atlas `$vectorSearch` through the existing ACL-enforcing `find_similar`, and splits each retrieved document's text field into scored `Parse::Retrieval::Chunk`s. Chunking is presentation-only (embedding stays one-vector-per-record), via `Parse::Retrieval::Chunker::FixedSizeOverlap(size:, overlap:, by:, max_chunks_per_document:)` (subclass `Chunker::Base` for custom strategies). ACL is mongo-direct (no REST two-stage); tenant scope folds into the Atlas pre-filter
- **`semantic_search` agent tool + `agent_searchable`** — declare `agent_searchable field:, filter_fields:` on a model to expose it to the readonly, client-safe `semantic_search` tool. The handler enforces the full agent envelope: searchable-class allowlist, recursive underscore-key refusal + filter-field allowlist on input, `field_allowlist` projection plus tenant-scope re-assertion on output, and score quantization in non-admin contexts
- **MCP elicitation — human-in-the-loop approval** — opt in with `Parse::Agent.require_approval_for = [:write, :admin]` to require spec-native `elicitation/create` approval before destructive tool calls. A pluggable `agent.approval_gate` (reachable on the non-MCP path too) shows the dry-run diff and blocks on the client's reply; `call_method` resolves the *effective* tier from the target `agent_method`. Fails closed (no capability / no listening stream / non-streaming transport / timeout → refuse); replies are session-bound
- **Agent impersonation** — `Parse::Agent.new(impersonate_user:, impersonate_mint:, impersonation_label:)` / `agent.impersonate(user)` resolve a real session token for a `_User` (reuse an active `_Session`, or mint a restricted one) and bind it as if `session_token:` had been passed. Master-key-required, fail-closed, with an audit label on `parse.agent.tool_call`
- **`Parse::Agent::PromptHardening`** — schema-string sanitization (drops non-identifier field names, strips control/zero-width chars, marker-wraps descriptions) on `get_schema`/`get_all_schemas`; embedded-marker scrubbing of untrusted tool content (`prompt_marker_strict` to refuse); operator canary phrases (`prompt_injection_canaries` + `parse.agent.prompt_injection_detected`, `canary_action = :refuse`); `Parse::Agent::PROMPT_VERSION` via `agent.describe[:prompt][:version]`; and a one-time warning when `allowed_llm_endpoints` is unrestricted
- **Agent telemetry + provenance** — embedding cost on `parse.agent.tool_call` (`embed_calls` / `embed_tokens` / `embed_cost_usd` via `Parse::Agent.embed_cost_per_million_tokens`); optional per-row `_source` citations (`{ class, tool, object_id }`) on read-tool results via `Parse::Agent.include_source_provenance`
- **General-purpose server-initiated notifications** — `Parse::Agent::MCPRackApp.new(notifications: true)` opens the GET listening-stream bus without LiveQuery resource subscriptions; `MCPRackApp#notify(session_id, method:, params:)` pushes arbitrary `notifications/*` to a session
- **Token economy** — `Parse::Agent.new(tools: :lean)` narrows the readonly surface to six core tools (~7.9K → ~2.6K `tools/list` tokens); read tools strip the raw `ACL` map and `get_objects`/Atlas tools share `query_class`'s compact normalization; `semantic_search` hoists each chunk's parent into a `documents` map (sent once, not per chunk) and enforces a `max_total_tokens:` budget (default 20K) with a `budget_truncated` signal; a failing `tools/call` forwards `error_code` / `retry_after` / `details` under MCP `_meta`; `get_schema` suggests near-match class names on a typo; `Parse::Agent.measure_embeddings { … }` scopes ingestion embedding cost. See [`docs/mcp_guide.md`](./docs/mcp_guide.md#token-economy)

See [CHANGELOG.md](./CHANGELOG.md) for the full 5.2 entry.

### What's new in 5.1

- **`Parse::File` URL normalization + presigned-URL stash** — `Parse::File#url=` and `attributes=` now strip signed-URL query parameters (`X-Amz-Signature`, `AWSAccessKeyId`, `Key-Pair-Id`, etc.) before storage; the bare canonical URL lands in `@url`, and the original signed URL is stashed in `file.presigned_url` with a data-driven expiry in `file.presigned_url_expires_at`. New `file.presigned_url_valid?(buffer: 60)` predicate, configurable `Parse::File.signed_url_policy = :strip | :raise`, and `Parse::File.log_filter` / `log_filter_strict` regexes for `lograge` / Sentry / Honeybadger scrubbers. `Parse::File#inspect` no longer emits the URL — see CHANGELOG for the error-reporter payload migration callout
- **`Parse::Lock` — public TTL-bounded mutual-exclusion primitive** — `Parse::Lock.acquire(key, ttl:, wait:) { … }` exposes the Redis-backed lock previously hidden inside `first_or_create!` as a first-class API. In-process `Mutex` fallback for memory-backed caches, fails closed on backend errors, HMAC-keyed via `PARSE_STACK_LOCK_SECRET`, namespace-separated from `first_or_create!` so the two cannot collide
- **LiveQuery ergonomics** — autoloaded (no explicit `require 'parse/live_query'`); connections are **ACL-scoped by default** (build an admin, ACL-bypassing connection explicitly with `Parse::LiveQuery::Client.new(use_master_key: true)` — master-key authorization is per-connection, not per-subscription); `Query#subscribe` / `Klass.subscribe` accept a block yielded the `Subscription` *before* the subscribe frame is sent so `sub.on(:create) { … }` callbacks are wired before any server event can arrive; `Parse::LiveQuery.run_until_signal!(client:) { … }` is a signal-safe shutdown helper for long-running consumers
- **Image embeddings** — new `embed_image` class macro for `:file`-typed source properties plus `Voyage#embed_image` (`voyage-multimodal-3`, 1024-dim) and `Cohere#embed_image` (`embed-v4.0`, 1536-dim). URL-only routing in v5.1 (bytes-fetch with MIME-sniff lands later); operator-gated via the `Parse::Embeddings.trust_provider_url_fetch = "PROVIDER_EGRESS_VERIFIED"` sentinel plus a `Parse::Embeddings.allowed_image_hosts` CDN allowlist
- **Tenant-aware cache namespacing** — `Parse.with_cache_tenant(scope) { … }` composes the tenant into the response-cache key as `<base>:T:<tenant>:…` so a multi-tenant app sharing one Redis gets per-tenant key isolation and per-tenant SCAN-delete eviction without per-tenant `Parse::Client.new` plumbing. Fiber-local, restored on block exit, AS::N payloads carry `:cache_tenant`
- **`_User` field-visibility DSL** — `Parse::User.master_only_fields(*fields)` and `Parse::User.self_visible_fields(*fields, via: :self)` declare admin-only and owner-only field protections on `_User`. Requires Parse Server's `protectedFieldsOwnerExempt: false` server option (the SDK emits a one-time advisory at class declaration so the dependency is surfaced before deploy). Parse Server's default for this option is changing to `false` in a future version; until your server adopts that default, set it explicitly
- **`Parse::Installation` `belongs_to :user`** — read `installation.user` to find which user a device is currently signed in as. Symmetric `Parse::User#has_many :installations` for targeted-push grouping (master-key-only by Parse Server design; see the YARD for the owner-identity caveat)
- **`Parse.setup` / `live_query_url:` fixes** — `Parse.setup` is no longer a silent no-op on re-invocation; `Parse.setup(live_query_url: …)` and `live_query: { … }` options no longer raise `ArgumentError`; `ws://` against non-loopback hosts is refused unless `live_query: { allow_insecure: true }` is also passed
- **MCP `structuredContent` for 5 more tools** — `aggregate`, `export_data`, `atlas_text_search`, `atlas_autocomplete`, `atlas_faceted_search` now emit `structuredContent` with declared `outputSchema`s (sixteen of the built-in catalog now structured)
- **MCP resource subscriptions (LiveQuery bridge)** — opt-in `Parse::Agent::MCPRackApp.new(resource_subscriptions: true)` serves `resources/subscribe` and pushes `notifications/resources/updated` over a long-lived `GET` listening stream, backed by Parse LiveQuery. Subscribing to a class's `count` / `samples` resource opens a debounced LiveQuery subscription; the `resources.subscribe` capability is advertised only when LiveQuery is enabled and available. Credential-scoped per agent — session-token agents see only readable rows, master-key agents use a dedicated admin connection, and `acl_user:` / `acl_role:` agents are refused (no LiveQuery equivalent). See [`docs/mcp_guide.md`](./docs/mcp_guide.md#resource-subscriptions-livequery-bridge)
- **New ACL / CLP / `protectedFields` guide** — [`docs/acl_clp_guide.md`](./docs/acl_clp_guide.md) is the canonical reference for the five enforcement layers, the system-class CLP matrix (including the hardcoded master-key-only classes), the `_User` field-visibility recipe, role hierarchy direction, and the REST-aggregate vs `Parse::MongoDB.aggregate` enforcement asymmetry

See [CHANGELOG.md](./CHANGELOG.md) for the full 5.1 entry, including breaking changes, migration callouts, and the round-by-round security review notes.

### What's new in 5.0

- **RAG foundation** — `:vector` property type, `Parse::Embeddings` provider registry shipping built-in adapters for OpenAI, Cohere (v3 + v4.0 Matryoshka text-mode), Voyage (incl. open-weight `voyage-4-nano` and `voyage-multimodal-3` text-mode), Jina v3/v4/v5/code, Qwen 3 (DashScope), and a generic `LocalHTTP` client for Ollama / LM Studio / vLLM / TEI. `Klass.find_similar(vector:/text:, k:)` over Atlas `$vectorSearch`, and an `embed` class macro that digest-tracks source fields so vectors only recompute when content changes
- **`Parse::Cache::Redis`** — Moneta-compatible Redis cache wrapper with a built-in `ConnectionPool`, optional `cache_namespace:` for multi-tenant Redis sharing, and graceful degrade on pool saturation
- **`ActiveSupport::Notifications` instrumentation** — `parse.cache.*`, `parse.mongodb.aggregate`, `parse.mongodb.find`, and `parse.embeddings.embed` events with stable, PII-safe payload schemas; in-core slow-query log via `Parse.slow_query_threshold_ms`
- **MCP transport hardening** — Streamable HTTP `Mcp-Session-Id` header (renamed from `X-MCP-Session-Id`, **breaking**), `MCP-Protocol-Version` validation, `DELETE /` session termination, structured-content (`outputSchema`) on built-in tools, optional `health_path:` liveness probe
- **`Parse::GraphQL::TypeGenerator`** — generate `graphql-ruby` types directly from your `Parse::Object` subclasses (no Parse Server round-trip), with `:vector` columns surfaced as `[Float]` and association registries (`has_one_associations`, `has_many_associations`) populated at DSL time
- **LiveQuery promoted to stable** — the experimental warning is removed; `Parse.live_query_enabled = true` is retained as a network-egress safety toggle, not a stability gate
- **Server-version deprecation warning** — one-shot warning when connecting to Parse Server below the supported floor (currently 7.0.0); silence with `Parse.suppress_server_version_warning = true`
- **`mongo_relation_index :field, dedup: true`** — register a compound `{owningId, relatedId}` UNIQUE on relation join collections to prevent duplicate-pair subscriptions without breaking `has_many` semantics

See [CHANGELOG.md](./CHANGELOG.md) for the full 5.0 entry, including security-hardening notes and Ruby 3.x cleanup.

### Core capabilities

- MongoDB Aggregation Framework support
- **MongoDB Atlas Search** — full-text search, autocomplete, faceted search with direct MongoDB access
- **Direct MongoDB Queries** — bypass Parse Server's REST surface for high-performance reads, with SDK-side ACL/CLP/`protectedFields` enforcement for scoped agents
- **Schema Introspection & Migration** — compare local models with server schema and generate migrations
- **Enhanced Role Management** — helper methods for role hierarchies, user membership, and subscription queries
- **Read Preference Support** — route reads to MongoDB secondary replicas
- **Class-Level Permissions (CLP)** — define and filter protected fields based on roles and user ownership
- Advanced ACL query constraints (`readable_by`, `writable_by`)
- **Owner-aware default ACL policy** (`acl_policy :owner_else_private`) — per-class defaults granting read/write only to the record's owner, with a secure or public fallback for server-context creates
- Full transaction support with automatic retry
- Comprehensive integration testing with Docker
- Enhanced change tracking and webhooks
- Request idempotency with `Retry-After` header support
- Timezone support for date operations
- Partial fetch with smart autofetch and serialization control
- Multi-Factor Authentication (MFA/2FA) support
- LiveQuery real-time subscriptions with TLS/SSL, circuit breaker, and health monitoring
- AI/LLM agent integration (MCP-spec compliant) with security hardening — rate limiting, injection protection, agent ACL scopes

Below is a [quick start guide](#overview). See also the [Usage Guide](./docs/usage_guide.md) for practical examples covering queries, aggregation, ACLs, and more.

> **Note:** API reference docs are published at [neurosynq.github.io/parse-stack-next](https://neurosynq.github.io/parse-stack-next/index.html). Generated via YARD from the current source; covers the full 5.x surface.

### Credits

This project (`parse-stack-next`) is a continuation of the [Parse Stack framework](https://github.com/modernistik/parse-stack) originally created by [Modernistik](https://www.modernistik.com). We are grateful for their foundational work and continue to build upon it under the [neurosynq](https://github.com/neurosynq) organization.

### Code Status
[![Gem Version](https://img.shields.io/gem/v/parse-stack-next.svg)](https://rubygems.org/gems/parse-stack-next)
[![Downloads](https://img.shields.io/gem/dt/parse-stack-next.svg)](https://rubygems.org/gems/parse-stack-next)
[![Releases](https://img.shields.io/github/v/release/neurosynq/parse-stack-next)](https://github.com/neurosynq/parse-stack-next/releases)

#### Tutorial Videos

The following videos were recorded for the original parse-stack gem. The model, query, and association surface they cover is unchanged in parse-stack-next, so they remain a useful introduction; see the [Usage Guide](./docs/usage_guide.md) for v5.x-specific features (vector search, Redis cache, agent tools).

1. Getting Started: https://youtu.be/zoYSGmciDlQ
2. Custom Classes and Relations: https://youtu.be/tfSesotfU7w
3. Working with Existing Schemas: https://youtu.be/EJGPT7YWyXA

Any other questions, please post them on StackOverflow with the proper parse-stack / parse-server / ruby tags.

## Installation

Add this line to your application's `Gemfile`:
```ruby
gem 'parse-stack-next'
```
And then execute:
```bash
$ bundle
```
Or install it yourself as:
```bash
$ gem install parse-stack-next
```

> **Note:** The Ruby require path and module namespace are unchanged. You still `require 'parse/stack'` and reference classes under `Parse::Object`, `Parse::Query`, etc. Only the gem name on RubyGems has changed.
### Rack / Sinatra
Parse-Stack API, models and webhooks easily integrate in your existing Rack/Sinatra based applications.

### Rails
Parse-Stack comes with support for Rails by adding additional rake tasks and generators. After adding `parse-stack-next` as a gem dependency in your Gemfile and running `bundle`, you should run the install script:
```bash
$ rails g parse_stack:install
```

### Interactive Command Line Playground
You can also used the bundled `parse-console` command line to connect and interact with your Parse Server and its data in an IRB-like console. This is useful for trying concepts and debugging as it will automatically connect to your Parse Server, and if provided the master key, automatically generate all the models entities.

```bash
$ parse-console -h # see all options
$ parse-console -v -a myAppId -m myMasterKey http://localhost:2337/parse
Server : http://localhost:2337/parse
App Id : myAppId
Master : true
2.4.0 > Parse::User.first
```

## Overview
Parse-Stack is a full stack framework that utilizes several ideas behind [DataMapper](http://datamapper.org/docs/find.html) and [ActiveModel](https://github.com/rails/rails/tree/master/activemodel) to manage and maintain larger scale ruby applications and tools that utilize the [Parse Server Platform](http://parseplatform.org/). If you are familiar with these technologies, the framework should feel familiar to you.

```ruby
require 'parse/stack'

Parse.setup server_url: 'http://localhost:2337/parse',
            app_id: APP_ID,
            api_key: REST_API_KEY,
            master_key: YOUR_MASTER_KEY # optional

# Automatically build models based on your Parse application schemas.
Parse.auto_generate_models!

# or define custom Subclasses (Highly Recommended)
class Song < Parse::Object
  property :name
  property :play, :integer
  property :audio_file, :file
  property :tags, :array
  property :released, :date
  belongs_to :artist
  # `like` is a Parse Relation to User class
  has_many :likes, as: :user, through: :relation

  # deny public write to Song records by default
  set_default_acl :public, read: true, write: false
end

class Artist < Parse::Object
  property :name
  property :genres, :array
  has_many :fans, as: :user
  has_one :manager, as: :user

  scope :recent, ->(x) { query(:created_at.after => x) }
end

# updates schemas for your Parse app based on your models (non-destructive)
Parse.auto_upgrade!

# login
user = Parse::User.login(username, passwd)

artist = Artist.new(name: "Frank Sinatra", genres: ["swing", "jazz"])
artist.fans << user
artist.save

# Query
artist = Artist.first(:name.like => /Sinatra/, :genres.in => ['swing'])

# more examples
song = Song.new name: "Fly Me to the Moon"
song.artist = artist
# Parse files - upload a file and attach to object
song.audio_file = Parse::File.create("http://path_to.mp3")

# relations - find a User matching username and add it to relation.
song.likes.add Parse::User.first(username: "persaud")

# saves both attributes and relations
song.save

# find songs
songs = Song.all(artist: artist, :plays.gt => 100, :released.on_or_after => 30.days.ago)

songs.each { |s| s.tags.add "awesome" }
# batch saves
songs.save

# Call Cloud Code functions
result = Parse.call_function :myFunctionName, {param: value}

```

## Release History

**Current version: 5.0.1** | **Ruby 3.2+ required**

The 5.0 highlights (vector search / RAG, pooled Redis cache, AS::N instrumentation, MCP transport hardening, GraphQL type generation) are summarized in the [What's new in 5.0](#whats-new-in-50) section above. Earlier releases are recorded below.

Per-version detail lives in [CHANGELOG.md](./CHANGELOG.md) and on the [Releases page](https://github.com/neurosynq/parse-stack-next/releases). The compact summary below is the major-line view.

### 4.x — MongoDB index management, agent ACL scope, CLP enforced on mongo-direct, and `parse-stack-next` debut

- **`mongo_index` DSL** (`mongo_index`, `mongo_geo_index`, `mongo_relation_index`) with class-load validation (pointer auto-rewrite, parallel-array rejection, `_id` guard, 64-per-collection cap). `parse_reference` fields auto-register a unique-sparse index.
- **Index migration tooling** — `Parse::MongoDB.configure_writer` (separate write connection, triple-gated), `Parse::Schema::IndexMigrator` (plan / apply with optional orphan drop), and `rake parse:mongo:indexes:plan` / `:apply`.
- **`Model.describe`** — operator introspection aggregator (local declarations + optional server fetch covering schema, CLP, default ACLs, Atlas Search, MongoDB indexes).
- **CLP + `protectedFields` enforced on mongo-direct** — `Parse::CLPScope` gates `Parse::MongoDB.aggregate` for scoped agents (`session_token:` / `acl_user:` / `acl_role:`) and strips protected fields from result rows. This is the only first-class enforcement surface for ACL + CLP + protectedFields on scoped reads; Parse Server's REST aggregate enforces neither.
- **`Parse::Agent.new(acl_user:|acl_role:)`** — declared agent identity without a session token; built-in tools auto-promote to mongo-direct. Sub-agent identity must be a subset of the parent's reach.
- **Pipeline correctness** — schema-aware `$author` → `$_p_author` rewriter respects pipeline-local aliases; forward-pass field tracking through `$group`/`$addFields`/`$set`/`$lookup.as`; pointer `query_hint:` surfaced in `get_schema`.
- **`Parse.strict_pointer_shapes`** — opt-in flag that converts unresolvable pointer-shape constraints into a `PointerShapeError` raise (recommended for test/CI and LLM-driven workloads).
- **`first_or_create!` / `create_lock` accept `Parse::Operation` keys** in `synchronize:`, fixing filter-lock fingerprint collisions on inequality/range constraints.
- **Security & modernization** — Ruby 3.2 floor, Rails/ActiveSupport 6.1 floor, CI on Ruby 3.2–3.5. LiveQuery TLS hostname verification. Webhook endpoint fails closed when no key is configured. `Parse::Error.new(code, message)` two-argument constructor. `include`d pointer fields auto-added to `keys` when an allowlist is set.
- **4.5.0 — first release of this gem.** `parse-stack-next` debuts on RubyGems under the [neurosynq](https://github.com/neurosynq) organization, continuing from the upstream `parse-stack` 4.4.x line. The Ruby require path (`require 'parse/stack'`) and the `Parse::*` namespace are unchanged from upstream — only the gem name on RubyGems is new.

### 3.x — Atlas Search, MongoDB-direct, CLP, AI agent, push, MFA, LiveQuery

- **MongoDB Atlas Search** — full-text search, autocomplete, faceted search.
- **Direct MongoDB queries** — `results_direct`, `first_direct`, `count_direct` bypassing Parse Server's REST surface.
- **Schema tools** — `Parse::Schema.diff`, `Parse::Schema.migration`, plus `read_pref(:secondary)` for replica reads.
- **Role management** — `find_or_create`, `add_users`, `add_child_role`, `all_users` (with hierarchy walks).
- **Class-Level Permissions (CLP)** declared in models — `set_clp :find, public: true`, `protect_fields "*", [:internal_notes]`.
- **AI/LLM agent** — `Parse::Agent` with natural-language queries over a tool interface.
- **Push builder API** — `to_channel`, `with_alert`, `silent!`, `send!`; installation channels (`subscribe`, `unsubscribe`).
- **Session lifecycle** — `expired?`, `time_remaining`, `logout_all!`.
- **MFA** — TOTP and SMS two-factor authentication.
- **LiveQuery** — real-time WebSocket subscriptions (promoted to stable in 5.0).
- **Ruby 3.1 floor** (3.0 reached EOL March 2024).

### 2.x — aggregation, transactions, idempotency, ACL constraints

- **Transactions** — `Parse::Object.transaction` with automatic retry.
- **MongoDB aggregation** — `group_by`, `count_distinct`, custom pipelines.
- **ACL query constraints** — `readable_by`, `writable_by`, `publicly_readable`.
- **Request idempotency** — automatic duplicate prevention, enabled by default.
- **Change tracking** — works correctly in `after_save` hooks.
- **Breaking from 1.x** — Ruby 3.0 floor, Faraday 2.x (no `faraday_middleware`), `distinct` returns object IDs by default (pass `return_pointers: true` for pointers), `constaint` → `constraint` typo fix.

### 1.x — initial Parse Server SDK

The 1.x line is the original [`modernistik/parse-stack`](https://github.com/modernistik/parse-stack) — Active Model ORM, REST client, query DSL, associations, and Cloud Code webhooks for Parse Server. `parse-stack-next` is a continuation of that work; the first release published under the new gem name is **4.5.0** (above), on RubyGems as [`parse-stack-next`](https://rubygems.org/gems/parse-stack-next).

## Table of Contents

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->


- [Architecture](#architecture)
  - [Parse::Client](#parseclient)
  - [Parse::Query](#parsequery)
  - [Parse::Object](#parseobject)
  - [Parse::Webhooks](#parsewebhooks)
- [Field Naming Conventions](#field-naming-conventions)
- [Connection Setup](#connection-setup)
  - [Connection Options](#connection-options)
- [Working With Existing Schemas](#working-with-existing-schemas)
- [Parse Config](#parse-config)
- [Core Classes](#core-classes)
  - [Parse::Pointer](#parsepointer)
  - [Parse::File](#parsefile)
  - [Parse::Date](#parsedate)
  - [Parse::GeoPoint](#parsegeopoint)
    - [Calculating Distances between locations](#calculating-distances-between-locations)
  - [Parse::Bytes](#parsebytes)
  - [Parse::TimeZone](#parsetimezone)
  - [Parse::ACL](#parseacl)
  - [Parse::CLP (Class-Level Permissions)](#parseclp-class-level-permissions)
    - [Defining CLPs in Models](#defining-clps-in-models)
    - [Filtering Data for Webhook Responses](#filtering-data-for-webhook-responses)
    - [Protected Fields Intersection Logic](#protected-fields-intersection-logic)
    - [Push CLPs to Parse Server](#push-clps-to-parse-server)
    - [Fetch and Inspect CLPs](#fetch-and-inspect-clps)
    - [Owner-Based Access with userField](#owner-based-access-with-userfield)
  - [Parse::Session](#parsesession)
  - [Parse::Installation](#parseinstallation)
  - [Parse::Product](#parseproduct)
  - [Parse::Role](#parserole)
  - [Parse::JobStatus](#parsejobstatus)
  - [Parse::JobSchedule](#parsejobschedule)
  - [Parse::User](#parseuser)
    - [Signup](#signup)
      - [Third-Party Services](#third-party-services)
    - [Login and Sessions](#login-and-sessions)
    - [Linking and Unlinking](#linking-and-unlinking)
    - [Request Password Reset](#request-password-reset)
- [Modeling and Subclassing](#modeling-and-subclassing)
  - [Defining Properties](#defining-properties)
    - [Accessor Aliasing](#accessor-aliasing)
    - [Property Options](#property-options)
      - [`:required`](#required)
      - [`:field`](#field)
      - [`:default`](#default)
      - [`:alias`](#alias)
      - [`:symbolize`](#symbolize)
      - [`:enum`](#enum)
      - [`:scope`](#scope)
  - [Associations](#associations)
    - [Belongs To](#belongs-to)
      - [Options](#options)
        - [`:required`](#required-1)
        - [`:as`](#as)
        - [`:field`](#field-1)
    - [Has One](#has-one)
    - [Has Many](#has-many)
      - [Query](#query)
      - [Array](#array)
      - [Parse Relation](#parse-relation)
      - [Options](#options-1)
        - [`:through`](#through)
        - [`:scope_only`](#scope_only)
- [Creating, Saving and Deleting Records](#creating-saving-and-deleting-records)
  - [Create](#create)
  - [Upsert Operations](#upsert-operations)
    - [first_or_create](#first_or_create)
    - [first_or_create!](#first_or_create_bang)
    - [create_or_update!](#create_or_update_bang)
  - [Saving](#saving)
  - [Saving applying User ACLs](#saving-applying-user-acls)
    - [Raising an exception when save fails](#raising-an-exception-when-save-fails)
  - [Enhanced Object Fetching](#enhanced-object-fetching)
  - [Modifying Associations](#modifying-associations)
  - [Batch Requests](#batch-requests)
  - [Atomic Transactions](#atomic-transactions)
  - [Magic `save_all`](#magic-save_all)
  - [Deleting](#deleting)
- [Fetching, Finding and Counting Records](#fetching-finding-and-counting-records)
  - [Auto-Fetching Associations](#auto-fetching-associations)
- [Advanced Querying](#advanced-querying)
  - [Results Caching](#results-caching)
  - [Counting](#counting)
  - [Count Distinct](#count-distinct)
  - [Aggregation Functions](#aggregation-functions)
  - [Group By Operations](#group-by-operations)
  - [Distinct Aggregation](#distinct-aggregation)
  - [Query Expressions](#query-expressions)
    - [:order](#order)
    - [:keys](#keys)
    - [:includes](#includes)
    - [:limit](#limit)
    - [:skip](#skip)
  - [Cursor-Based Pagination](#cursor-based-pagination)
    - [:cache](#cache)
    - [:use_master_key](#use_master_key)
    - [:session](#session)
    - [:where](#where)
- [Query Constraints](#query-constraints)
    - [Equals](#equals)
    - [Less Than](#less-than)
    - [Less Than or Equal To](#less-than-or-equal-to)
    - [Greater Than](#greater-than)
    - [Greater Than or Equal](#greater-than-or-equal)
    - [Not Equal To](#not-equal-to)
    - [Nullability Check](#nullability-check)
    - [Exists](#exists)
    - [Contained In](#contained-in)
    - [Not Contained In](#not-contained-in)
    - [Contains All](#contains-all)
    - [Regex Matching](#regex-matching)
    - [Select](#select)
    - [Reject](#reject)
    - [Matches Query](#matches-query)
    - [Excludes Query](#excludes-query)
    - [Matches Object Id](#matches-object-id)
  - [Geo Queries](#geo-queries)
    - [Max Distance Constraint](#max-distance-constraint)
    - [Bounding Box Constraint](#bounding-box-constraint)
    - [Polygon Area Constraint](#polygon-area-constraint)
    - [Full Text Search Constraint](#full-text-search-constraint)
  - [Relational Queries](#relational-queries)
  - [Compound Queries](#compound-queries)
- [Query Scopes](#query-scopes)
- [Calling Cloud Code Functions](#calling-cloud-code-functions)
- [Calling Background Jobs](#calling-background-jobs)
- [Active Model Callbacks](#active-model-callbacks)
- [Schema Upgrades and Migrations](#schema-upgrades-and-migrations)
- [Push Notifications](#push-notifications)
  - [Builder Pattern API](#builder-pattern-api)
  - [Silent Push](#silent-push-ios-background-notifications)
  - [Rich Push](#rich-push-ios-notification-extensions)
  - [Localization](#localization)
  - [Badge Management](#badge-management)
  - [Saved Audiences](#saved-audiences)
  - [Push Status Tracking](#push-status-tracking)
  - [Installation Channel Management](#installation-channel-management)
- [Analytics](#analytics)
- [Cloud Code Webhooks](#cloud-code-webhooks)
  - [Cloud Code Functions](#cloud-code-functions)
  - [Cloud Code Triggers](#cloud-code-triggers)
    - [Trigger object state](#trigger-object-state)
  - [Mounting Webhooks Application](#mounting-webhooks-application)
  - [Register Webhooks](#register-webhooks)
- [Parse REST API Client](#parse-rest-api-client)
  - [Request Caching](#request-caching)
- [Atlas Search](#atlas-search)
  - [Setup](#setup)
  - [Full-Text Search](#full-text-search)
  - [Autocomplete](#autocomplete-search-as-you-type)
  - [Faceted Search](#faceted-search)
  - [Search Builder](#search-builder-advanced)
  - [Query Integration](#query-integration)
  - [Index Management](#index-management)
  - [Creating Search Indexes](#creating-search-indexes)
- [Contributing](#contributing)
- [Testing](#testing)
  - [Docker Integration Tests](#docker-integration-tests)
  - [Unit Tests](#unit-tests)
  - [Contributing Tests](#contributing-tests)
- [License](#license)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Architecture
The architecture of `Parse::Stack` is broken into four main components.

### [Parse::Client](https://neurosynq.github.io/parse-stack-next/Parse/Client.html)
This class is the core and low level API for the Parse Server REST interface that is used by the other components. It can manage multiple sessions, which means you can have multiple client instances pointing to different Parse Server applications at the same time. It handles sending raw requests as well as providing Request/Response objects for all API handlers. The connection engine is Faraday, which means it is open to add any additional middleware for features you'd like to implement.

### [Parse::Query](https://neurosynq.github.io/parse-stack-next/Parse/Query.html)
This class implements the [Parse REST Querying](http://docs.parseplatform.org/rest/guide/#queries) interface in the [DataMapper finder syntax style](http://datamapper.org/docs/find.html). It compiles a set of query constraints and utilizes `Parse::Client` to send the request and provide the raw results. This class can be used without the need to define models.

### [Parse::Object](https://neurosynq.github.io/parse-stack-next/Parse/Object.html)
This component is main class for all object relational mapping subclasses for your application. It provides features in order to map your remote Parse records to a local ruby object. It implements the Active::Model interface to provide a lot of additional features, CRUD operations, querying, including dirty tracking, JSON serialization, save/destroy callbacks and others. While we are overlooking some functionality, for simplicity, you will mainly be working with Parse::Object as your superclass. While not required, it is highly recommended that you define a model (Parse::Object subclass) for all the Parse classes in your application.

### [Parse::Webhooks](https://neurosynq.github.io/parse-stack-next/Parse/Webhooks.html)
Parse provides a feature called [Cloud Code Webhooks](http://blog.parse.com/announcements/introducing-cloud-code-webhooks/). For most applications, save/delete triggers and cloud functions tend to be implemented by Parse's own hosted Javascript solution called Cloud Code. However, Parse provides the ability to have these hooks utilize your hosted solution instead of their own, since their environment is limited in terms of resources and tools.

## Field Naming Conventions
By convention in Ruby (see [Style Guide](https://github.com/bbatsov/ruby-style-guide#snake-case-symbols-methods-vars)), symbols and variables are expressed in lower_snake_case form. Parse, however, prefers column names in **lower-first camel case** (ex. `objectId`, `createdAt` and `updatedAt`). To keep in line with the style guides between the languages, we do the automatic conversion of the field names when compiling the query. As an additional exception to this rule, the field key of `id` will automatically be converted to the `objectId` field when used. If you do not want this to happen, you can turn off or change the value `Parse::Query.field_formatter` as shown below. Though we recommend leaving the default `:columnize` if possible.

```ruby
# default uses :columnize
query = Parse::User.query :field_one => 1, :FieldTwo => 2, :Field_Three => 3
query.compile_where # {"fieldOne"=>1, "fieldTwo"=>2, "fieldThree"=>3}

# turn off
Parse::Query.field_formatter = nil
query = Parse::User.query :field_one => 1, :FieldTwo => 2, :Field_Three => 3
query.compile_where # {"field_one"=>1, "FieldTwo"=>2, "Field_Three"=>3}

# force everything camel case
Parse::Query.field_formatter = :camelize
query = Parse::User.query :field_one => 1, :FieldTwo => 2, :Field_Three => 3
query.compile_where # {"FieldOne"=>1, "FieldTwo"=>2, "FieldThree"=>3}

```


## Connection Setup
To connect to a Parse server, you will need a minimum of an `application_id`, an `api_key` and a `server_url`. To connect to the server endpoint, you use the `Parse.setup()` method below.

```ruby
  Parse.setup app_id: "YOUR_APP_ID",
              api_key: "YOUR_API_KEY",
              master_key: "YOUR_MASTER_KEY", # optional
              server_url: 'https://localhost:2337/parse' #default
```

If you wish to add additional connection middleware to the stack, you may do so by utilizing passing a block to the setup method.

```ruby
  Parse.setup( ... ) do |conn|
    # conn is a Faraday connection object
    conn.use Your::Middleware
    conn.response :logger
    # ....
  end
```

Calling `setup` will create the default `Parse::Client` session object that will be used for all models and requests in the stack. You may retrive this client by calling the class `client` method. It is possible to create different client connections and have different models point to different Parse applications and endpoints at the same time.

```ruby
  default_client = Parse.client
                   # alias Parse::Client.client(:default)
```

### Connection Options
There are additional connection options that you may pass the setup method when creating a `Parse::Client`.

#### `:server_url`
The server url of your Parse Server if you are not using the hosted Parse service. By default it will use `PARSE_SERVER_URL` environment variable available or fall back to `https://localhost:2337/parse` if not specified.

#### `:app_id`
The Parse application id. By default it will use `PARSE_SERVER_APPLICATION_ID` environment variable if not specified.

#### `:api_key`
The Parse REST API Key. By default it will use `PARSE_SERVER_REST_API_KEY` environment variable if not specified.

#### `:master_key` _(optional)_
The Parse application master key. If this key is set, it will be sent on every request sent by the client and your models. By default it will use `PARSE_SERVER_MASTER_KEY` environment variable if not specified.

#### `:logging`
Controls request/response logging. Accepts:
- `true` - Enable logging at `:info` level (logs method, URL, status, timing)
- `:debug` - Enable verbose logging with headers and body content
- `:warn` - Only log errors and warnings
- `false` or `nil` - Disable logging (default)

```ruby
Parse.setup(logging: true, ...)      # info level
Parse.setup(logging: :debug, ...)    # verbose with body content
```

#### `:logger`
A custom Logger instance for request/response logging. Defaults to `Logger.new(STDOUT)`.

```ruby
Parse.setup(logging: true, logger: Rails.logger, ...)
```

You can also configure logging programmatically after setup:

```ruby
Parse.logging_enabled = true     # Enable/disable
Parse.log_level = :debug         # :info, :debug, or :warn
Parse.logger = Rails.logger      # Custom logger
Parse.log_max_body_length = 1000 # Truncate body after N chars (default: 500)
```

#### `:adapter`
The HTTP connection adapter. By default, Parse Stack uses `:net_http_persistent` for connection pooling, which significantly improves performance by reusing HTTP connections. Set `connection_pooling: false` to use the standard `Net::HTTP` adapter instead.

```ruby
# Use a custom adapter (overrides connection_pooling setting)
Parse.setup(adapter: :excon, ...)
```

#### `:connection_pooling`
Controls HTTP connection pooling for improved performance. Enabled by default using the `net_http_persistent` adapter.

**Benefits:**
- 30-70% latency reduction by eliminating TCP/SSL handshakes per request
- Reduced server load through connection reuse
- Better performance for high-throughput applications

```ruby
# Default: connection pooling enabled
Parse.setup(server_url: "...", app_id: "...", api_key: "...")

# Disable connection pooling
Parse.setup(connection_pooling: false, ...)

# Custom pool configuration
Parse.setup(
  connection_pooling: {
    pool_size: 5,      # Connections per thread (default: 1)
    idle_timeout: 60,  # Seconds before closing idle connections (default: 5)
    keep_alive: 60     # HTTP Keep-Alive timeout in seconds
  },
  ...
)
```

**Configuration Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `pool_size` | 1 | Number of connections per thread. Increase if making parallel requests within a thread. |
| `idle_timeout` | 5 | Seconds before closing idle connections. Set higher (30-60s) for frequently-used servers. |
| `keep_alive` | - | HTTP Keep-Alive timeout. Should be less than your Parse Server's `keepAliveTimeout`. |

**Recommended settings for Heroku:**
```ruby
Parse.setup(
  connection_pooling: { pool_size: 2, idle_timeout: 60, keep_alive: 60 },
  ...
)
```

If `faraday-net_http_persistent` is not available, Parse Stack automatically falls back to the standard adapter with a warning.

#### `:cache`
A caching adapter of type `Moneta::Transformer`. Caching queries and object fetches can help improve the performance of your application, even if it is for a few seconds. Only successful `GET` object fetches and queries (non-empty) will be cached. You may set the default expiration time with the `expires` option. See related: [Moneta](https://github.com/minad/moneta). At any point in time you may clear the cache by calling the `clear_cache!` method on the client connection.

```ruby
  store = Moneta.new :Redis, url: 'redis://localhost:6379'
   # use a Redis cache store with an automatic expire of 10 seconds.
  Parse.setup(cache: store, expires: 10, ...)
```

As a shortcut, if you are planning on using REDIS and have configured the use of `redis` in your `Gemfile`, you can just pass the REDIS connection string directly to the cache option.

```ruby
  Parse.setup(cache: 'redis://localhost:6379', ...)
```

Redis is the recommended cache backend for multi-process / multi-dyno deployments: an in-memory `Moneta.new(:Memory)` store is local to a single Ruby process, so two Puma workers (or two web dynos) each hold their own cache and a write through one will not invalidate the other. A shared Redis backend gives every process the same view, and the existing PUT/POST/DELETE invalidation in `Parse::Middleware::Caching` runs against the shared store. Cache reads degrade gracefully on `Redis::CannotConnectError` / `Redis::TimeoutError` — the middleware disables caching for the failing request and lets the underlying GET pass through to Parse Server.

The cache surface is opt-in at two layers. Object fetches (`Model.find(id)`, `obj.reload!` in non-write-only mode) cache by default once a store is configured. Query results do **not** cache by default — pass `cache: true` per call (e.g. `Song.all(limit: 500, cache: true)`) or set `Parse.default_query_cache = true` for opt-out behavior. Both layers honor `cache: false` / `Cache-Control: no-cache` to skip the cache for an individual request.

#### `:expires`
Sets the default cache expiration time (in seconds) for successful non-empty `GET` requests when using the caching middleware. The default value is 3 seconds. If `:expires` is set to 0, caching will be disabled. You can always clear the current state of the cache using the `clear_cache!` method on your `Parse::Client` instance.

#### `:faraday`
You may pass a hash of options that will be passed to the `Faraday` constructor.

### Global Settings

#### `Parse.warn_on_query_issues`
Controls whether query validation warnings are displayed. When enabled (default: `true`), Parse-Stack will print helpful warnings about common query mistakes:

- Warning when including non-pointer fields (e.g., including a string field that doesn't need `include`)
- Warning when including a pointer AND specifying subfield keys (redundant - the full object makes the subfield keys unnecessary)

```ruby
# Disable query validation warnings globally
Parse.warn_on_query_issues = false

# Example warnings that may be shown when enabled:
# [Parse::Query] Warning: 'filename' is a string field, not a pointer/relation - it does not need to be included
# [Parse::Query] Warning: including 'project' returns the full object - keys ["project.name"] are unnecessary
```

#### N+1 Query Detection

Parse Stack can detect N+1 query patterns - a common performance issue where accessing associations in a loop triggers separate queries for each item.

**Enable Detection:**
```ruby
# Warning mode (logs warnings)
Parse.n_plus_one_mode = :warn

# Or use the legacy API
Parse.warn_on_n_plus_one = true
```

**Example:**
```ruby
Parse.n_plus_one_mode = :warn

songs = Song.all(limit: 100)
songs.each do |song|
  song.artist.name  # Warning: N+1 query detected!
end

# Output:
# [Parse::N+1] Warning: N+1 query detected on Song.artist (3 separate fetches for Artist)
#   Location: app/controllers/songs_controller.rb:42 in `index`
#   Suggestion: Use `.includes(:artist)` to eager-load this association
```

**Fix with Includes:**
```ruby
# Eager-load associations to avoid N+1
songs = Song.all(limit: 100, includes: [:artist])
songs.each do |song|
  song.artist.name  # No warning - already loaded
end
```

**Available Modes:**

| Mode | Behavior |
|------|----------|
| `:ignore` | Detection disabled (default) |
| `:warn` | Log warnings when N+1 detected |
| `:raise` | Raise `Parse::NPlusOneQueryError` - ideal for CI/tests |

**Strict Mode for CI/Tests:**
```ruby
# In test_helper.rb or rails_helper.rb
Parse.n_plus_one_mode = :raise

# Now N+1 queries will fail your tests!
```

**Custom Callbacks:**
```ruby
# Track N+1 patterns in your metrics
Parse.on_n_plus_one do |source_class, association, target_class, count, location|
  StatsD.increment("n_plus_one.#{source_class}.#{association}")
end
```

**Configuration:**
```ruby
Parse.configure_n_plus_one do |config|
  config.detection_window = 5.0   # Seconds to track related fetches (default: 2.0)
  config.fetch_threshold = 5      # Fetches to trigger warning (default: 3)
end
```

## Working With Existing Schemas
If you already have a Parse application with defined schemas and collections, you can have Parse-Stack automatically generate the ruby Parse::Object subclasses instead of writing them on your own. Through this process, the framework will download all the defined schemas of all your collections, and infer the properties and associations defined. While this method is useful for getting started with the framework with an existing app, we highly recommend defining your own models. This would allow you to customize and utilize all the features available in Parse Stack.

```ruby
  # after you have called Parse.setup
  # Assume you have a Song and Artist collections defined remotely
  Parse.auto_generate_models!

  # You can now use them as if you defined them
  artist = Artist.first
  Song.all(artist: artist)
```

You can always combine both approaches by defining special attributes before you auto generate your models:

```ruby
  # create a Song class, but only create the artist array pointer association.
  class Song < Parse::Object
    has_many :artists, through: :array
  end

  # Now let Parse Stack generate the rest of the properties and associations
  # based on your remote schema. Assume there is a `title` field for the `Song`
  # collection.
  Parse.auto_generate_models!

  song = Song.first
  song.artists # created with our definition above
  song.title # auto-generated property

```

## [Parse Config](https://neurosynq.github.io/parse-stack-next/Parse/API/Config.html)
Getting your configuration variables once you have a default client setup can be done with `Parse.config`. The first time this method is called, Parse-Stack will get the configuration from Parse Server, and cache it. To force a reload of the config, use `config!`. You

```ruby
  Parse.setup( ... )

  val = Parse.config["myKey"]
  val = Parse.config["myKey"] # cached

  # update a config with Parse
  Parse.set_config "myKey", "someValue"

  # batch update several
  Parse.update_config({fieldEnabled: true, searchMiles: 50})

  # Force fetch of config!
  val = Parse.config!["myKey"]

```

## Core Classes
While some native data types are similar to the ones supported by Ruby natively, other ones are more complex and require their dedicated classes.

### [Parse::Pointer](https://neurosynq.github.io/parse-stack-next/Parse/Pointer.html)
An important concept is the `Parse::Pointer` class. This is the superclass of `Parse::Object` and represents the pointer type in Parse. A `Parse::Pointer` only contains data about the specific Parse class and the `id` for the object. Therefore, creating an instance of any Parse::Object subclass with only the `:id` field set will be considered in "pointer" state even though its specific class is not `Parse::Pointer` type. The only case that you may have a Parse::Pointer is in the case where an object was received for one of your classes and the framework has no registered class handler for it. Using the example above, assume you have the tables `Post`, `Comment` and `Author` defined in your remote Parse application, but have only defined `Post` and `Commentary` locally.

```ruby
 # assume the following
class Post < Parse::Object
end

class Commentary < Parse::Object
  parse_class "Comment"
	belongs_to :post
	#'Author' class not defined locally
	belongs_to :author
end

comment = Commentary.first
comment.post? # true because it is non-nil
comment.artist? # true because it is non-nil

# both are true because they are in a Pointer state
comment.post.pointer? # true
comment.author.pointer? # true

 # we have defined a Post class handler
comment.post # <Post @parse_class="Post", @id="xdqcCqfngz">

 # we have not defined an Author class handler
comment.author # <Parse::Pointer @parse_class="Author", @id="hZLbW6ofKC">


comment.post.fetch # fetch the relation
comment.post.pointer? # false, it is now a full object.
```

#### Auto-fetch on Property Access

When you have a `Parse::Pointer` for a registered model class, you can access properties directly and the object will be automatically fetched:

```ruby
# Create a pointer (not yet fetched)
pointer = Post.pointer("abc123")
pointer.pointer? # true - no data yet

# Accessing a property auto-fetches and returns the value
pointer.title # Fetches the object, returns "My Post Title"

# Subsequent accesses use the cached fetched object (no additional network request)
pointer.content # Returns content without another fetch
pointer.author  # Returns author without another fetch

# The pointer remembers the fetched object
pointer.pointer? # false - now has data
```

This auto-fetch behavior respects the `Parse.autofetch_raise_on_missing_keys` setting:

```ruby
Parse.autofetch_raise_on_missing_keys = true
pointer = Post.pointer("abc123")
pointer.title # Raises Parse::AutofetchTriggeredError instead of fetching
```

The effect is that for any unknown classes that the framework encounters, it will generate Parse::Pointer instances until you define those classes with valid properties and associations. While this might be ok for some classes you do not use, we still recommend defining all your Parse classes locally in the framework.

### [Parse::File](https://neurosynq.github.io/parse-stack-next/Parse/File.html)
This class represents a Parse file pointer. `Parse::File` has helper methods to upload Parse files directly to Parse and manage file associations with your classes. Using our Song class example:

```ruby
  song = Song.first
  file = song.audio_file # Parse::File
  file.url # URL in the Parse file storage system

  file = File.open("file_path.jpg")
  contents = file.read
  file = Parse::File.new("myimage.jpg", contents , "image/jpeg")
  file.saved? # false. Hasn't been uploaded to Parse
  file.save # uploads to Parse.

  file.url # https://files.parsetfss.com/....

  # or create and upload a remote file (auto-detected mime type)
  file = Parse::File.create(some_url)
  song.file = file
  song.save

```

The default MIME type for all files is `image/jpeg`. This can be default can be changed by setting a value to `Parse::File.default_mime_type`. Other ways of creating a `Parse::File` are provided below. The created Parse::File is not uploaded until you call `save`.

```ruby
  # urls
  file = Parse::File.new "http://example.com/image.jpg"
  file.name # image.jpg

  # file objects
  file = Parse::File.new File.open("myimage.jpg")

  # non-image files work too
  file = Parse::File.new "http://www.example.com/something.pdf"
  file.mime_type = "application/octet-stream" #set the mime-type!

  # or another Parse::File object
  file = Parse::File.new parse_file
```

If you are using displaying these files on a secure site and want to make sure that urls returned by a call to `url` are `https`, you can set `Parse::File.force_ssl` to true.

```ruby
# Assume file is a Parse::File

file.url # => http://www.example.com/file.png

Parse::File.force_ssl = true # make all urls be https

file.url # => https://www.example.com/file.png

```

### [Parse::Date](https://neurosynq.github.io/parse-stack-next/Parse/Date.html)
This class manages dates in the special JSON format it requires for properties of type `:date`. `Parse::Date` subclasses `DateTime`, which allows you to use any features or methods available to `DateTime` with `Parse::Date`. While the conversion between `Time` and `DateTime` objects to a `Parse::Date` object is done implicitly for you, you can use the added special methods, `DateTime#parse_date` and `Time#parse_date`, for special occasions.

```ruby
  song = Song.first
  song.released = DateTime.now # converted to Parse::Date
  song.save # ok
```

### [Parse::GeoPoint](https://neurosynq.github.io/parse-stack-next/Parse/GeoPoint.html)
This class manages the GeoPoint data type that Parse provides to support geo-queries. To define a GeoPoint property, use the `:geopoint` data type. Please note that latitudes should not be between -90.0 and 90.0, and longitudes should be between -180.0 and 180.0.

```ruby
  class PlaceObject < Parse::Object
    property :location, :geopoint
  end

  san_diego = Parse::GeoPoint.new(32.8233, -117.6542)
  los_angeles = Parse::GeoPoint.new [34.0192341, -118.970792]
  san_diego == los_angeles # false

  place = PlaceObject.new
  place.location = san_diego
  place.save
```

#### Calculating Distances between locations
We include helper methods to calculate distances between GeoPoints: `distance_in_miles` and `distance_in_km`.

```ruby
	san_diego = Parse::GeoPoint.new(32.8233, -117.6542)
	los_angeles = Parse::GeoPoint.new [34.0192341, -118.970792]

	# Haversine calculations
	san_diego.distance_in_miles(los_angeles)
	# ~112.33 miles

	san_diego.distance_in_km(los_angeles)
	# ~180.793 km
```

### [Parse::Bytes](https://neurosynq.github.io/parse-stack-next/Parse/Bytes.html)
The `Bytes` data type represents the storage format for binary content in a Parse column. The content is needs to be encoded into a base64 string.

```ruby
  bytes = Parse::Bytes.new( base64_string )
  # or use helper method
  bytes = Parse::Bytes.new
  bytes.encode( content ) # same as Base64.encode64

  decoded = bytes.decoded # same as Base64.decode64
```

### [Parse::TimeZone](https://neurosynq.github.io/parse-stack-next/Parse/TimeZone.html)
While Parse does not provide a native time zone data type, Parse-Stack provides a class to make it easier to manage time zone attributes, usually stored IANA string identifiers, with your ruby code. This is done by utilizing the features provided by [`ActiveSupport::TimeZone`](http://api.rubyonrails.org/classes/ActiveSupport/TimeZone.html). In addition to setting a column as a time zone field, we also add special validations to verify it is of the right IANA identifier.

```ruby
class Event < Parse::Object
  # an event occurs in a time zone.
  property :time_zone, :timezone, default: 'America/Los_Angeles'
end

event = Event.new
event.time_zone.name # => 'America/Los_Angeles'
event.time_zone.valid? # => true

event.time_zone.zone # => ActiveSupport::TimeZone
event.time_zone.formatted_offset # => "-08:00"

event.time_zone = 'Europe/Paris'
event.time_zone.formatted_offset # => +01:00"

event.time_zone = 'Galaxy/Andromeda'
event.time_zone.valid? # => false
```

### [Parse::ACL](https://neurosynq.github.io/parse-stack-next/Parse/ACL.html)
The `ACL` class represents the access control lists for each record. An ACL is represented by a JSON object with the keys being `Parse::User` object ids or the special key of `*`, which indicates the public access permissions.
The value of each key in the hash is a [`Parse::ACL::Permission`](https://neurosynq.github.io/parse-stack-next/Parse/ACL/Permission.html) object which defines the boolean permission state for `read` and `write`.

The example below illustrates a Parse ACL JSON object where there is a public read permission, but public write is prevented. In addition, the user with id `3KmCvT7Zsb` and the `Admins` role, are allowed to both read and write on this record.

```json
{
  "*": { "read": true },
  "3KmCvT7Zsb": {  "read": true, "write": true },
  "role:Admins": {  "read": true, "write": true }
}
```

All `Parse::Object` subclasses have an `acl` property by default. With this property, you can apply and delete permissions for this particular Parse object record.

```ruby
  user = Parse::User.first
  artist = Artist.first

  artist.acl # "*": { "read": true, "write": true }

  # apply public read, but no public write
  artist.acl.everyone true, false

  # allow user to have read and write access
  artist.acl.apply user.id, true, true

  # remove all permissions for this user id
  artist.acl.delete user.id

  # allow the 'Admins' role read and write
  artist.acl.apply_role "Admins", true, true

  # remove write from all attached privileges
  artist.acl.no_write!

  # remove all attached privileges
  artist.acl.master_key_only!

  artist.save
```
You may also set default ACLs for newly created instances of your subclasses using `set_default_acl`:

```ruby
class AdminData < Parse::Object

  # Disable public read and write
  set_default_acl :public, read: false, write: false

  # but allow members of the Admin role to read and write
  set_default_acl 'Admin', role: true, read: true, write: true

end

data = AdminData.new
data.acl # => ACL({"role:Admin"=>{"read"=>true, "write"=>true}})
```

#### Declarative ACL Policy (`acl_policy`)

For owner-aware defaults — where the record's ACL should grant read/write to a specific user pointer at save time — declare an `acl_policy` instead of (or in addition to) `set_default_acl`. The policy is resolved by a `before_save` callback that walks `as: user` → owner-field pointer → policy fallback, and stamps the resolved ACL onto the record. Any explicit `obj.acl = …` change by the caller is always respected.

There are four policies:

| Policy | When an owner is resolvable | When no owner is resolvable |
|---|---|---|
| `:public` | public read + write | public read + write |
| `:public_read` | public read, master-key write | public read, master-key write |
| `:private` | master-key only | master-key only |
| `:owner_else_public` | owner read + write only | public read + write |
| `:owner_else_private` | owner read + write only | master-key only |
| `:owner_but_public_read` | owner read + write *and* public read | public read, master-key write |

`:public_read` (v5.0+) stamps `{"*": {"read": true}}` — anyone can read the row, but no client can mutate it through ACL (only the master key can write). Useful for catalog / lookup / reference data.

`:owner_but_public_read` (v5.0+) is the "single-author public post" case: the resolved owner gets full R/W and the rest of the world gets read-only access in the same ACL — `{"*": {"read": true}, "<ownerId>": {"read": true, "write": true}}`. When no owner resolves at save (no `as:` and no resolvable `owner:` field), it degrades to `:public_read` semantics rather than the all-or-nothing fallback used by the `:owner_else_*` family.

```ruby
class Post < Parse::Object
  property :title, :string
  belongs_to :author, as: :user

  # Posts grant read/write to their author; server-side creates with no
  # author resolvable fall back to master-key-only.
  acl_policy :owner_else_private, owner: :author
end

# Owner resolved from the belongs_to pointer:
Post.create!(title: "draft", author: current_user)
# => ACL { "<current_user.id>": { read: true, write: true } }

# Or pass the owner explicitly with `as:`:
Post.create!(title: "draft", as: current_user)

# Server-side, no owner: master-key-only fallback.
Post.create!(title: "system note")
# => ACL { } (only the master key can read or write)
```

Resolution order at save (only when the caller has not set the ACL):

1. `obj.acl = …` or in-place mutation of `obj.acl` by the caller — always wins
2. `as: user` passed at construction
3. Owner pointer from the property named by `owner:`
4. The "else" half of the policy — public R/W or master-key-only

The `:as` key may be a `Parse::User`, a `Parse::Pointer` to a user, or a raw `objectId` string. It is popped from the opts hash before attributes are applied, so it never reaches `apply_attributes!` and never appears as a property.

Subclasses inherit the parent's policy and owner field. Classes that already call `set_default_acl` are detected automatically and opt out of the policy resolver, so legacy callers retain pre-4.1 behavior without changes.

Owner resolution is strictly type-gated. The `as:` kwarg and any `owner:` pointer accept a `Parse::User` instance, a `Parse::Pointer` whose `parse_class == "_User"`, or a raw `objectId` `String`. Pointers to non-User classes and arbitrary objects responding to `#id` are silently rejected and the policy falls through to its else-half, so a stray pointer to a non-user record cannot accidentally grant ACL access to a user record that happens to share the same `objectId`.

You may not combine `acl_policy` with `set_default_acl` on the same class — the two APIs have ambiguous interactions at save time. Calling the second one raises `ArgumentError`. Pick one configuration approach per class.

#### Self-Owned Users (`owner: :self`)

`Parse::User` records are special: the record IS the owner. The SDK provides `owner: :self` as a Parse::User-only shorthand for "this user owns themselves." The save-time resolver pre-generates a Parse-compatible `objectId` client-side (via the same helper that backs `parse_reference precompute: true`) when none is set, then stamps the ACL as `{ <generated-id>: { read: true, write: true } }`. The signup body then carries both the `objectId` and the `ACL` in a single POST.

```ruby
class Parse::User
  # New users: only the user can read or write their own profile.
  acl_policy :owner_else_private, owner: :self
end

new_user = Parse::User.new(username: "alice", password: "secret")
new_user.save
# Single roundtrip. After save, new_user.id is a 10-char Parse id and
# the persisted record's ACL is { "<that id>": { read: true, write: true } }.
# Other clients (including unauthenticated) cannot see this user.
```

`owner: :self` is rejected at class-definition time on any non-User class — there's no sensible interpretation when the record's `objectId` is not a user id.

The signup request body normally has `objectId` and `ACL` stripped (a security mitigation against client-planted permissive ACLs). When `owner: :self` is declared, those two fields are allowed through only when they match the narrow self-only ownership pattern: `objectId` is the 10-char Parse format, and `ACL` has exactly one entry granting `read+write` to that same `objectId`. Any deviation — multiple keys, a `*` (public) entry, a `role:` entry, half-permissions, mismatched id — still triggers the full strip and Parse Server applies its own default.

`acl_policy ..., owner: :self` is orthogonal to `parse_reference precompute: true`. Both reuse `Parse::Core::ParseReference.generate_object_id` for client-side id generation; neither installs the other's side effects. Declare both if you want both the ACL self-ownership AND the canonical reference column.

#### Breaking Change in v4.1: Secure-by-Default ACL Policy

Starting with v4.1, the gem-wide default ACL policy for `Parse::Object` subclasses is `:owner_else_private`. Records created with no resolvable owner (no `as:` kwarg, no `owner:` field) and no class-level `acl_policy` or `set_default_acl` declaration are saved with an empty ACL — readable and writable only with the master key.

**This is a behavioral change.** Pre-4.1, the same class would have produced records with public read + public write. Applications that depend on the historical default for client-side reads of unowned records will see those reads return empty result sets until they update their model declarations.

Migration recipes:

```ruby
# A class whose records should remain publicly readable + writable:
class PublicNotice < Parse::Object
  property :body, :string
  acl_policy :public
end

# A class whose records belong to a user:
class JournalEntry < Parse::Object
  property :text, :string
  belongs_to :author, as: :user
  acl_policy :owner_else_private, owner: :author
end

# A class whose records are written client-side but readable by anyone:
class Post < Parse::Object
  property :title, :string
  belongs_to :author, as: :user
  acl_policy :owner_else_public, owner: :author
end
```

When a class explicitly opts into a permissive policy (`:public` or `:owner_else_public`), a one-time per-class warning is emitted on first instance creation to make the choice visible in logs:

```
[Parse::Stack security] PublicNotice uses permissive default ACL policy
`public`. New records can be modified by anyone unless an owner is
resolved at save. Call `acl_policy :owner_else_private` or `:private`
in the class to silence this warning.
```

The warning fires once per class per process and is automatically suppressed for the SDK's own built-in classes (`Parse::User`, `Parse::Installation`, `Parse::Session`, `Parse::Role`, `Parse::Product`, `Parse::PushStatus`, `Parse::Audience`, `Parse::JobStatus`, `Parse::JobSchedule`). To silence it globally — for example in test suites or in applications that have reviewed and accepted permissive defaults — set either:

```ruby
Parse::Object.suppress_permissive_acl_warning = true
# or, via the environment:
ENV["PARSE_SUPPRESS_PERMISSIVE_ACL_WARNING"] = "1"
```

For more information about Parse record ACLs, see the documentation at  [Security](http://docs.parseplatform.org/rest/guide/#security)

### Parse::CLP (Class-Level Permissions)

Class-Level Permissions (CLPs) control access at the schema level, determining who can perform operations on a class and which fields are visible to different users/roles. Unlike ACLs (which are per-object), CLPs apply to the entire class.

#### Defining CLPs in Models

Use the `set_clp` and `protect_fields` DSL methods to define CLPs:

```ruby
class Song < Parse::Object
  property :title, :string
  property :artist, :string
  property :internal_notes, :string
  property :royalty_data, :string
  belongs_to :owner

  # Set operation-level permissions
  set_clp :find, public: true
  set_clp :get, public: true
  set_clp :create, public: false, roles: ["Admin", "Editor"]
  set_clp :update, public: false, roles: ["Admin", "Editor"]
  set_clp :delete, public: false, roles: ["Admin"]

  # Protect fields from certain users (use camelCase for JSON field names)
  protect_fields "*", [:internalNotes, :royaltyData]  # Hidden from everyone
  protect_fields "role:Admin", []                      # Admins see everything
  protect_fields "userField:owner", []                 # Owners see their own data
end
```

**Supported Operations:** `:find`, `:get`, `:count`, `:create`, `:update`, `:delete`, `:addField`

**Supported Patterns:**
- `"*"` - Public (everyone)
- `"role:RoleName"` - Users with specific role
- `"userField:fieldName"` - Users referenced in a pointer field
- `"authenticated"` - Any authenticated user
- User objectId string - Specific user

#### Filtering Data for Webhook Responses

When returning data from webhooks, use `filter_for_user` to apply CLP field protection:

```ruby
# In a webhook handler
def after_find(request)
  user = request.user
  roles = Song.roles_for_user(user)

  # Filter each object for the requesting user
  filtered_results = request.objects.map do |song|
    song.filter_for_user(user, roles: roles)
  end

  # Or use the class method for arrays
  filtered_results = Song.filter_results_for_user(request.objects, user, roles: roles)

  { objects: filtered_results }
end
```

#### Protected Fields Intersection Logic

When a user matches multiple patterns, the protected fields are the **intersection** of all matching patterns. A field is only hidden if it's protected by ALL patterns that apply to the user:

```ruby
protect_fields "*", [:owner, :secret, :internal]  # Hide from everyone
protect_fields "role:Admin", [:owner]             # Admins: only owner hidden
protect_fields "userField:owner", []              # Owners see everything

# User with Admin role matches "*" and "role:Admin":
# - "*" protects: [owner, secret, internal]
# - "role:Admin" protects: [owner]
# - Intersection: [owner] - only this field is hidden
# - "secret" and "internal" become visible (cleared by role pattern)

# An empty array [] means "no fields protected" (user sees everything)
# If ANY matching pattern has [], the intersection is empty (nothing hidden)
```

#### Push CLPs to Parse Server

CLPs are automatically included when upgrading schemas:

```ruby
# Include CLPs in schema upgrade (default)
Song.auto_upgrade!

# Skip CLPs during schema upgrade
Song.auto_upgrade!(include_clp: false)

# Update only CLPs (no schema changes)
Song.update_clp!
```

#### Fetch and Inspect CLPs

```ruby
# Fetch current CLPs from server
clp = Song.fetch_clp

# Check operation permissions
clp.find_allowed?("*")           # => true (public find allowed)
clp.create_allowed?("*")         # => false (public create denied)
clp.role_allowed?(:create, "Admin")  # => true
clp.requires_authentication?(:update)  # => false

# Get protected fields for a pattern
clp.protected_fields_for("*")          # => ["internalNotes", "royaltyData"]
clp.protected_fields_for("role:Admin") # => []

# Use fetched CLP for filtering
filtered = song.filter_for_user(user, roles: roles, clp: clp)
```

#### Owner-Based Access with userField

The `userField:fieldName` pattern allows owners (users referenced in a pointer field) to have different visibility:

```ruby
class Document < Parse::Object
  property :content, :string
  property :secret, :string
  belongs_to :owner

  # Hide secret and owner from everyone
  protect_fields "*", [:secret, :owner]
  # But owners of the document can see everything
  protect_fields "userField:owner", []
end

# When filtering:
doc_data = {
  "content" => "Public content",
  "secret" => "Private data",
  "owner" => { "objectId" => "user123", "__type" => "Pointer" }
}

clp = Document.class_permissions

# Owner sees everything
clp.filter_fields(doc_data, user: "user123")
# => { "content" => "...", "secret" => "...", "owner" => {...} }

# Non-owner has protected fields hidden
clp.filter_fields(doc_data, user: "other_user")
# => { "content" => "..." }
```

This also works with arrays of pointers (e.g., `owners: [user1, user2]`).

### [Parse::Session](https://neurosynq.github.io/parse-stack-next/Parse/Session.html)
This class represents the data and columns contained in the standard Parse `_Session` collection. You may add additional properties and methods to this class. See [Session API Reference](https://neurosynq.github.io/parse-stack-next/Parse/Session.html). You may call `Parse.use_shortnames!` to use `Session` in addition to `Parse::Session`.

You can get a specific `Parse::Session` given a session_token by using the `session` method. You can also find the user tied to a specific Parse session or session token with `Parse::User.session`.

```ruby
session = Parse::Session.session(token)

session.user # the Parse user for this session

# or fetch user with a session token
user = Parse::User.session(token)

# save an object with the privileges (ACLs) of this user
some_object.save( session: user.session_token )

# delete an object with the privileges of this user
some_object.destroy( session: user.session_token )

```

### [Parse::Installation](https://neurosynq.github.io/parse-stack-next/Parse/Installation.html)
This class represents the data and columns contained in the standard Parse `_Installation` collection. You may add additional properties and methods to this class. See [Installation API Reference](https://neurosynq.github.io/parse-stack-next/Parse/Installation.html). You may call `Parse.use_shortnames!` to use `Installation` in addition to `Parse::Installation`.

### [Parse::Product](https://neurosynq.github.io/parse-stack-next/Parse/Product.html)
This class represents the data and columns contained in the standard Parse `_Product` collection. You may add additional properties and methods to this class. See [Product API Reference](https://neurosynq.github.io/parse-stack-next/Parse/Product.html). You may call `Parse.use_shortnames!` to use `Product` in addition to `Parse::Product`.

The `_Product` collection backs the original Parse iOS SDK's `PFProduct` downloadable-content in-app-purchase flow. That feature was tied to hosted Parse and is not actively used by modern Parse Server deployments — most apps now verify in-app purchase receipts directly against the Apple App Store or Google Play. The class is retained for backwards compatibility with legacy applications that still read or write product metadata. It is also marked `agent_hidden` by default so it does not surface through MCP / agent tooling; applications that genuinely need agent access can call `Parse::Product.agent_unhidden` at boot.

### [Parse::Role](https://neurosynq.github.io/parse-stack-next/Parse/Role.html)
This class represents the data and columns contained in the standard Parse `_Role` collection. You may add additional properties and methods to this class. See [Roles API Reference](https://neurosynq.github.io/parse-stack-next/Parse/Role.html). You may call `Parse.use_shortnames!` to use `Role` in addition to `Parse::Role`.

#### Default ACL (master-only)
Parse Server requires every `_Role` row to ship with an ACL — the requirement is hard-coded in `SchemaController.requiredColumns` and cannot be disabled by config. `Parse::Role` declares `acl_policy :private`, so every role saved without an explicit ACL is stamped with `{}` (master-key only). This is intentional: anonymous and authenticated-but-non-master clients cannot enumerate role names, read subscription, or walk the role hierarchy. Parse Server's internal role-subscription expansion (used during ACL evaluation) runs with master context, so the master-only default does not break permission checks on other classes.

To opt into broader access, pass an explicit ACL:

```ruby
acl = Parse::ACL.new
acl.everyone(true, false) # public read, no public write
admin = Parse::Role.find_or_create("Admin", acl: acl)

# or on an instance:
role = Parse::Role.new(name: "Editor")
role.acl = acl
role.save
```

The explicit ACL bypasses the policy resolver — caller-supplied ACLs are never overwritten.

#### Role Management Helpers

Parse::Role provides convenient methods for managing users and role hierarchies:

```ruby
# Find or create roles
admin = Parse::Role.find_by_name("Admin")
moderator = Parse::Role.find_or_create("Moderator")

# Manage users
admin.add_user(user).save
admin.add_users(user1, user2, user3).save
admin.remove_user(user).save
admin.has_user?(user)  # => true

# Role hierarchy (Admins inherit Moderator permissions)
admin.add_child_role(moderator).save
admin.has_child_role?(moderator)  # => true
admin.all_child_roles              # => All child roles recursively
admin.all_users                    # => Users from this role AND child roles

# Counts
admin.users_count        # Direct users
admin.child_roles_count  # Direct child roles
admin.total_users_count  # All users including child roles
```

### [Parse::JobStatus](https://neurosynq.github.io/parse-stack-next/Parse/JobStatus.html)

This class represents the data and columns contained in the standard Parse `_JobStatus` collection. Parse Server writes a row here every time a background job — registered server-side via `Parse.Cloud.job(...)` — runs, recording its outcome and any status/message updates emitted via `request.message(...)`.

This Ruby SDK cannot *define* a job (cloud-code registrations live in server-side JavaScript), but you can read from `_JobStatus` to display the most recent run of a job, count failed runs, or sweep old history rows. `Parse::JobStatus` is marked `agent_hidden` by default — `_JobStatus` carries operational signal (job names, error traces, scheduler parameters) that an LLM-driven agent should not enumerate unsolicited. Applications that need agent visibility can call `Parse::JobStatus.agent_unhidden` at boot.

```ruby
# Did the nightly cleanup run today? What's the latest state?
latest = Parse::JobStatus.latest_for("nightlyCleanup")
puts "#{latest.status} at #{latest.created_at}"
puts "Duration: #{latest.duration}s" if latest.finished?

# Find failed jobs in the last 24h
yesterday = Time.now - 86_400
Parse::JobStatus.failed.where(:created_at.gt => yesterday).all

# Status scopes
Parse::JobStatus.running       # => Parse::Query
Parse::JobStatus.succeeded     # => Parse::Query
Parse::JobStatus.failed        # => Parse::Query
Parse::JobStatus.recent(limit: 50)

# Instance predicates
js.running?    # status == "running"
js.succeeded?  # status == "succeeded"
js.failed?     # status == "failed"
js.finished?   # finished_at present OR status terminal
js.duration    # finished_at - created_at, or nil while in-flight
```

#### Cleanup helper

Parse Server does not garbage-collect `_JobStatus` rows on its own; long-running deployments accumulate run history indefinitely. `Parse::JobStatus.cleanup_older_than!` mirrors `Parse::Installation.cleanup_stale_tokens!` for this case:

```ruby
# Default: only destroy rows in a terminal state (succeeded/failed)
# and older than 30 days. Orphaned `status == "running"` rows (from a
# crashed worker) are PRESERVED so an in-flight job is never reaped
# mid-execution.
deleted_count = Parse::JobStatus.cleanup_older_than!(days: 30)

# Explicit orphan cleanup: drop the status guard.
Parse::JobStatus.cleanup_older_than!(days: 7, terminal_only: false)
```

The helper requires master-key access (Parse Server's default `_JobStatus` CLP). Run from a periodic cron or scheduled job to keep `_JobStatus` from growing unboundedly.

### [Parse::JobSchedule](https://neurosynq.github.io/parse-stack-next/Parse/JobSchedule.html)

This class represents the data and columns contained in the standard Parse `_JobSchedule` collection. Rows here define recurring runs for background jobs registered via `Parse.Cloud.job(...)`. The collection is populated by the Parse Dashboard's "Schedule a Job" UI.

**Note:** Parse Server itself does not auto-trigger jobs from `_JobSchedule` rows. The actual dispatch is performed by external scheduling tooling (e.g. `parse-server-scheduler`, dashboard-driven cron wrappers, or a sidecar process) that reads `_JobSchedule` and fires `POST /parse/jobs/<name>` at the appropriate times. Run-status rows then appear in `Parse::JobStatus`.

`Parse::JobSchedule` is marked `agent_hidden` by default because `params` may carry credentials or destination configuration written by external schedulers.

```ruby
schedule = Parse::JobSchedule.for_job("nightlyCleanup").first
schedule.time_of_day   # => "03:00:00"
schedule.days_of_week  # => ["mon","tue","wed","thu","fri"]
schedule.parsed_params # => { "dryRun" => false }  — JSON-decoded
```

`params` is stored on the wire as a JSON-encoded **string** per Parse Server's canonical schema (Object columns reject `$` and `.` in nested keys, which would otherwise break common payload shapes). Use `#parsed_params` to decode; it returns `nil` for blank or invalid JSON instead of raising. `last_run` is a raw `Number` whose unit is scheduler-defined — most external schedulers write `Date.now()` milliseconds, but the canonical schema does not pin a unit.

### [Parse::User](https://neurosynq.github.io/parse-stack-next/Parse/User.html)
This class represents the data and columns contained in the standard Parse `_User` collection. You may add additional properties and methods to this class. See [User API Reference](https://neurosynq.github.io/parse-stack-next/Parse/User.html). You may call `Parse.use_shortnames!` to use `User` in addition to `Parse::User`.

#### Signup
You can signup new users in two ways. You can either use a class method `Parse::User.signup` to create a new user with the minimum fields of username, password and email, or create a `Parse::User` object can call the `signup!` method. If signup fails, it will raise the corresponding exception.

```ruby
user = Parse::User.signup(username, password, email)

#or
user = Parse::User.new username: "user", password: "s3cret"
user.signup!
```

##### Third-Party Services
You can signup users using third-party services like Facebook and Twitter as described in: [Signing Up and Logging In](http://docs.parseplatform.org/rest/guide/#signing-up). To do this with Parse-Stack, you can call the `Parse::User.autologin_service` method by passing the service name and the corresponding authentication hash data. For a listing of supported third-party authentication services, see [OAuth](http://docs.parseplatform.org/parse-server/guide/#oauth-and-3rd-party-authentication).

```ruby
fb_auth = {}
fb_auth[:id] = "123456789"
fb_auth[:access_token] = "SaMpLeAAiZBLR995wxBvSGNoTrEaL"
fb_auth[:expiration_date] = "2025-02-21T23:49:36.353Z"

# signup or login a user with this auth data.
user = Parse::User.autologin_service(:facebook, fb_auth)
```

You may also combine both approaches of signing up a new user with a third-party service and set additional custom fields. For this, use the method `Parse::User.create`.

```ruby
# or to signup a user with additional data, but linked to Facebook
data = {
  username: "johnsmith",
  name: "John",
  email: "user@example.com",
  authData: { facebook: fb_auth }
}
user = Parse::User.create data
```

#### Login and Sessions
With the `Parse::User` class, you can also perform login and logout functionality. The class special accessors for `session_token` and `session` to manage its authentication state. This will allow you to authenticate users as well as perform Parse queries as a specific user using their session token. To login a user, use the `Parse::User.login` method by supplying the corresponding username and password, or if you already have a user record, use `login!` with the proper password.

```ruby
user = Parse::User.login(username,password)
user.session_token # session token from a Parse::Session
user.session # Parse::Session tied to the token

 # You can login user records
user = Parse::User.first
user.session_token # nil

passwd = 'p_n7!-e8' # corresponding password
user.login!(passwd) # true

user.session_token # 'r:pnktnjyb996sj4p156gjtp4im'

 # logout to delete the session
user.logout
```

If you happen to already have a valid session token, you can use it to retrieve the corresponding Parse::User.

```ruby
# finds user with session token
user = Parse::User.session(session_token)

user.logout # deletes the corresponding session
```

#### Linking and Unlinking
You can link or unlink user accounts with third-party services like Facebook and Twitter as described in: [Linking and Unlinking Users](http://docs.parseplatform.org/rest/guide/#linking-users). To do this, you must first get the corresponding authentication data for the specific service, and then apply it to the user using the linking and unlinking methods. Each method returns true or false if the action was successful. For a listing of supported third-party authentication services, see [OAuth](http://docs.parseplatform.org/parse-server/guide/#oauth-and-3rd-party-authentication).

```ruby

user = Parse::User.first

fb_auth = { ... } # Facebook auth data

# Link this user's Facebook account with Parse
user.link_auth_data! :facebook, fb_auth

# Unlinks this user's Facebook account from Parse
user.unlink_auth_data! :facebook
```

#### Request Password Reset
You can reset a user's password using the `Parse::User.request_password_reset` method.

```ruby
user = Parse::User.first

# pass a user object
Parse::User.request_password_reset user
# or email
Parse::User.request_password_reset("user@example.com")
```

#### Multi-Factor Authentication (MFA)

Parse-Stack provides comprehensive MFA support that integrates with Parse Server's built-in MFA adapter. This enables TOTP (Time-based One-Time Password) authentication with apps like Google Authenticator, Authy, or 1Password.

**Prerequisites:**
- Parse Server must have the MFA adapter enabled
- Add optional gems to your Gemfile: `gem 'rotp'` and `gem 'rqrcode'`

**Parse Server Configuration:**
```javascript
{
  auth: {
    mfa: {
      enabled: true,
      options: ["TOTP"],
      digits: 6,
      period: 30,
      algorithm: "SHA1"
    }
  }
}
```

**Setting Up MFA:**
```ruby
# Configure the issuer name shown in authenticator apps
Parse::MFA.configure do |config|
  config[:issuer] = "MyApp"
end

# Step 1: Generate a TOTP secret
secret = Parse::MFA.generate_secret

# Step 2: Display QR code to the user
qr_svg = user.mfa_qr_code(secret, issuer: "MyApp")
# Render in HTML: <%= raw qr_svg %>

# Step 3: User scans QR and enters code from their authenticator
recovery_codes = user.setup_mfa!(secret: secret, token: "123456")
# IMPORTANT: Display recovery codes to user - they can only see them once!
```

**Logging In with MFA:**
```ruby
# Login with username, password, and MFA token
user = Parse::User.login_with_mfa("username", "password", "123456")

# Check if MFA is required before login
if Parse::User.mfa_required?("username")
  # Prompt for MFA token
end
```

**Managing MFA:**
```ruby
# Check MFA status
user.mfa_enabled?  # => true
user.mfa_status    # => :enabled, :disabled, or :unknown

# Disable MFA (requires current token)
user.disable_mfa!(current_token: "123456")

# Admin reset (master key) — authorized_by must be a Parse::User
user.disable_mfa_master_key!(authorized_by: admin_user)
```

**SMS MFA (requires Parse Server SMS callback):**
```ruby
# Initiate SMS setup
user.setup_sms_mfa!(mobile: "+1234567890")

# Confirm with received code
user.confirm_sms_mfa!(mobile: "+1234567890", token: "123456")
```

**Error Handling:**
```ruby
begin
  user = Parse::User.login_with_mfa(username, password, token)
rescue Parse::MFA::RequiredError
  # MFA token was not provided but is required
rescue Parse::MFA::VerificationError
  # Invalid MFA token
end
```


## Modeling and Subclassing
For the general case, your Parse classes should inherit from `Parse::Object`. `Parse::Object` utilizes features from `ActiveModel` to add several features to each instance of your subclass. These include `Dirty`, `Conversion`, `Callbacks`, `Naming` and `Serializers::JSON`.

To get started use the `property` and `has_many` methods to setup declarations for your fields. Properties define literal values that are columns in your Parse class. These can be any of the base Parse data types. You will not need to define classes for the basic Parse class types - this includes "\_User", "\_Installation", "\_Session" and "\_Role". These are mapped to `Parse::User`, `Parse::Installation`, `Parse::Session` and `Parse::Role` respectively.

To get started, you define your classes based on `Parse::Object`. By default, the name of the class is used as the name of the remote Parse class. For a class `Post`, we will assume there is a remote camel-cased Parse table called `Post`. If you need to map the local class name to a different remote class, use the `parse_class` method.

```ruby
class Post < Parse::Object
	# assumes Parse class "Post"
end

class Commentary < Parse::Object
	# set remote class "Comment"
	parse_class "Comment"
end
```

### Defining Properties
Properties are considered a literal-type of association. This means that a defined local property maps directly to a column name for that remote Parse class which contain the value. **All properties are implicitly formatted to map to a lower-first camelcase version in Parse (remote).** Therefore a local property defined as `like_count`, would be mapped to the remote column of `likeCount` automatically. The only special behavior to this rule is the `:id` property which maps to `objectId` in Parse. This implicit conversion mapping is the default behavior, but can be changed on a per-property basis. All Parse data types are supported and all Parse::Object subclasses already provide definitions for `:id` (objectId), `:created_at` (createdAt), `:updated_at` (updatedAt) and `:acl` (ACL) properties.

- **:string** (_default_) - a generic string. Can be used as an enum field, see [Enum](#enum).
- **:integer** (alias **:int**) - basic number. Will also generate atomic `_increment!` helper method.
- **:float** - a floating numeric value. Will also generate atomic `_increment!` helper method.
- **:boolean** (alias **:bool**) - true/false value. This will also generate a class scope helper. See [Query Scopes](#query-scopes).
- **:date** - a Parse date type. See [Parse::Date](#parsedate).
- **:timezone** - a time zone object. See [Parse::TimeZone](#parsetimezone).
- **:array** - a heterogeneous list with dirty tracking. See [Parse::CollectionProxy](https://github.com/modernistik/parse-stack/blob/master/lib/parse/model/associations/collection_proxy.rb).
- **:file** - a Parse file type. See [Parse::File](#parsefile).
- **:geopoint** - a GeoPoint type. See [Parse::GeoPoint](#parsegeopoint).
- **:bytes** - a Parse bytes data type managed as base64. See [Parse::Bytes](#parsebytes).
- **:object** - an object "hash" data type. See [ActiveSupport::HashWithIndifferentAccess](http://apidock.com/rails/ActiveSupport/HashWithIndifferentAccess).

For completeness, the `:id` and `:acl` data types are also defined in order to handle the Parse `objectId` field and the `ACL` object. Those are special and should not be used in your class (unless you know what you are doing). New data types can be implemented through the internal `typecast` interface. **TODO: discuss `typecast` interface in the future**

When declaring a `:boolean` data type, it will also create a special method that uses the `?` convention. As an example, if you have a property named `approved`, the normal getter `obj.approved` can return true, false or nil based on the value in Parse. However with the `obj.approved?` method, it will return true if it set to true, false for any other value.

When declaring an `:integer` or `:float` type, it will also create a special method that performs
an atomic increment of that field through the `_increment!` and `_decrement!` methods. If you have
defined a property named `like_count` for one of these numeric types, which would create the normal getter/setter `obj.like_count`; you can now also call `obj.like_count_increment!` or `obj.like_count_decrement!` to perform the atomic operations (done server side) on this field. You may also pass an amount as an argument to these helper methods such as `obj.like_count_increment!(3)`.

Using the example above, we can add the base properties to our classes.

```ruby
class Post < Parse::Object
  property :title
  property :content, :string # explicit

  # treat the values of this field as symbols instead of strings.
  property :category, :string, symbolize: true

  # maybe a count of comments.
  property :comment_count, :integer, default: 0

  # use lambda to access the instance object.
  # Set draft_date to the created_at date if empty.
  property :draft_date, :date, default: lambda { |x| x.created_at }
  # the published date. Maps to "publishDate"
  property :publish_date, :date, default: lambda { |x| DateTime.now }

  # maybe whether it is currently visible
  property :visible, :boolean

  # a list using
  property :tags, :array

  # string column as enumerated type. see :enum
  property :status, enum: [:active, :archived]

  # Maps to "featuredImage" column representing a File.
  property :featured_image, :file

  property :location, :geopoint

  # Support bytes
  property :data, :bytes

  # A field that contains time zone information (ex. 'America/Los_Angeles')
  property :time_zone, :timezone

  # store SEO information. Make sure we map it to the column
  # "SEO", otherwise it would have implicitly used "seo"
  # as the remote column name
  property :seo, :object, field: "SEO"
end
```

After properties are defined, you can use appropriate getter and setter methods to modify the values. As properties become modified, the model will keep track of the changes using the [dirty tracking feature of ActiveModel](http://api.rubyonrails.org/classes/ActiveModel/Dirty.html). If an attribute is modified in-place then make use of **[attribute_name]_will_change!** to mark that the attribute is changing. Otherwise ActiveModel can't track changes to in-place attributes.

To support dirty tracking on properties of data type of `:array`, we utilize a proxy class called `Parse::CollectionProxy`. This class has special functionality which allows lazy loading of content as well and keeping track of the changes that are made. While you are able to access the internal array on the collection through the `#collection` method, it is important not to make in-place edits to the object. You should use the preferred methods of `#add` and `#remove` to modify the contents of the collection. When `#save` is called on the object, the changes will be committed to Parse.

```ruby
post = Post.first
post.tags.each do |tag|
  puts tag
end
post.tags.empty? # false
post.tags.count # 3
array = post.tags.to_a # get array

# Add
post.tags.add "music", "tech"
post.tags.remove "stuff"
post.save # commit changes
```

#### Accessor Aliasing
To enable easy conversion between incoming Parse attributes, which may be different than the locally labeled attribute, we make use of aliasing accessors with their remote field names. As an example, for a `Post` instance and its `publish_date` property, it would have an accessor defined for both `publish_date` and `publishDate` (or whatever value you passed as the `:field` option) that map to the same attribute. We highly discourage turning off this feature, but if you need to, you can pass the value of `false` to the `:alias` option when defining the property.

```ruby
 # These are equivalent
post.publish_date = DateTime.now
post.publishDate = DateTime.now
post.publish_date == post.publishDate

post.seo # ok
post.SEO # the alias method since 'field: "SEO"'
```

#### Property Options
These are the supported options when defining properties. Parse::Objects are backed by `ActiveModel`, which means you can add additional validations and features supported by that library.

##### `:required`
A boolean property. This option provides information to the property builder that it is a required property. The requirement is not strongly enforced for a save, which means even though the value for the property may not be present, saves and updates can be successfully performed. However, the setting `required` to true, it will set some ActiveModel validations on the property to be used when calling `valid?`. By default it will add a `validates_presence_of` for the property key. If the data type of the property is either `:integer` or `:float`, it will also add a `validates_numericality_of` validation. Default `false`.

##### `:field`
This option allows you to set the name of the remote column for the Parse table. Using this will explicitly set the remote property name to the value of this option. The value provided for this option will affect the name of the alias method that is generated when `alias` option is used. **By default, the name of the remote column is the lower-first camelcase version of the property name. As an example, for a property with key `:my_property_name`, the framework will implicitly assume that the remote column is `myPropertyName`.**

##### `:default`
This option provides you to set a default value for a specific property when the getter accessor method is used and the internal value of the instance object's property is nil. It can either take a literal value or a Proc/lambda.

```ruby
class SomeClass < Parse::Object
	# default value
	property :category, default: "myValue"
	# default value Proc style
	property :date, default: lambda { |x| DateTime.now }
end
```

##### `:alias`
A boolean property. It is highly recommended that this is set to true, which is the default. This option allows for the generation of the additional accessors with the value of `:field`. By allowing two accessors methods, aliased to each other, allows for easier importing and automatic object instantiation based on Parse object JSON data into the Parse::Object subclass.

##### `:symbolize`
A boolean property. This option is only available for fields with data type of `:string`. This allows you to utilize the values for this property as symbols instead of the literal strings, which is Parse's storage format. This feature is useful if a particular property represents a set of enumerable states described in string form. As an example, if you have a `Post` object which has a set of publish states stored in Parse as "draft","scheduled", and "published" - we can use ruby symbols to make our code easier.

```ruby
class Post < Parse::Object
	property :state, :string, symbolize: true
end

post = Post.first
 # the value returned is auto-symbolized
if post.state == :draft
	# will be converted to string when updated in Parse
	post.state = :published
	post.save
end
```

##### `:enum`
The enum option allows you to define an array of possible values that the particular `:string` property should hold. This feature has similarities in the methods and accessors generated for you as described in [ActiveRecord::Enum](http://edgeapi.rubyonrails.org/classes/ActiveRecord/Enum.html). Using the example in that documentation:

```ruby
class Conversation < Parse::Object
  property :status, enum: [ :active, :archived ]
end

Conversation.statuses # => [ :active, :archived ]

# named scopes
Conversation.active # where status: :active
Conversation.archived(limit: 10) # where status: :archived, limit 10

conversation.active! # sets status to active!
conversation.active? # => true
conversation.status  # => :active

conversation.archived!
conversation.archived? # => true
conversation.status    # => :archived

# equivalent
conversation.status = "archived"
conversation.status = :archived

# allowed by the setter
conversation.status = :banana
conversation.status_valid? # => false

```

Similar to [ActiveRecord::Enum](http://edgeapi.rubyonrails.org/classes/ActiveRecord/Enum.html), you can use the `:_prefix` or `:_suffix` options when you need to define multiple enums with same values. If the passed value is true, the methods are prefixed/suffixed with the name of the enum. It is also possible to supply a custom value:

```ruby
class Conversation < Parse::Object
  property :status, enum: [:active, :archived], _suffix: true
  property :comments_status, enum: [:active, :inactive], _prefix: :comments
  # combined
  property :discussion, enum: [:casual, :business], _prefix: :talk, _suffix: true
end

Conversation.statuses # => [:active, :archived]
Conversation.comments # => [:active, :inactive]
Conversation.talks # => [:casual, :business]

# affects scopes names
Conversation.archived_status
Conversation.comments_inactive
Conversation.business_talk

conversation.active_status!
conversation.archived_status? # => false

conversation.status = :banana
conversation.valid_status? # => false

conversation.comments_inactive!
conversation.comments_active? # => false

conversation.casual_talk!
conversation.business_talk? # => false
```

##### `:scope`
A boolean property. For some data types like `:boolean` and enums, some [query scopes](#query-scopes) are generated to more easily query data. To prevent generating these scopes for a particular property, set this value to `false`.

### Associations
Parse supports a three main types of relational associations. One type of relation is the `One-to-One` association. This is implemented through a specific column in Parse with a Pointer data type. This pointer column, contains a local value that refers to a different record in a separate Parse table. This association is implemented using the `:belongs_to` feature. The second association is of `One-to-Many`. This is implemented is in Parse as a Array type column that contains a list of of Parse pointer objects. It is recommended by Parse that this array does not exceed 100 items for performance reasons. This feature is implemented using the `:has_many` operation with the plural name of the local Parse class. The last association type is a Parse Relation. These can be used to implement a large `Many-to-Many` association without requiring an explicit intermediary Parse table or class. This feature is also implemented using the `:has_many` method but passing the option of `:relation`.

#### Belongs To
This association creates a one-to-one association with another Parse model. This association says that this class contains a foreign pointer column which references a different class. Utilizing the `belongs_to` method in defining a property in a Parse::Object subclass sets up an association between the local table and a foreign table. Specifying the `belongs_to` in the class, tells the framework that the Parse table contains a local column in its schema that has a reference to a record in a foreign table. The argument to `belongs_to` should be the singularized version of the foreign Parse::Object class. you should specify the foreign table as the snake_case singularized version of the foreign table class. It is important to note that the reverse relationship is not generated automatically.

```ruby
class Author < Parse::Object
	property :name
end

class Comment < Parse::Object
	belongs_to :user # Parse::User
end

class Post < Parse::Object
	belongs_to :author
end

post = Post.first
 # Follow the author pointer and get name
post.author.name

other_author = Author.first
 # change author by setting new pointer
post.author = other_author
post.save
```

##### Options
You can override some of the default functionality when creating both `belongs_to`, `has_one` and `has_many` associations.

###### `:required`
A boolean property. Setting the requirement, automatically creates an ActiveModel validation of `validates_presence_of` for the association. This will not prevent the save, but affects the validation check when `valid?` is called on an instance. Default is false.

###### `:as`
This option allows you to override the foreign Parse class that this association refers while allowing you to have a different accessor name. As an example, you may have a class `Band` which has a `manager` who is of type `Parse::User` and a set of band members, represented by the class `Artist`. You can override the default casting class as follows:

```ruby
 # represents a member of a band or group
class Artist < Parse::Object
end

class Band < Parse::Object
	belongs_to :manager, as: :user
	belongs_to :lead_singer, as: :artist
	belongs_to :drummer, as: :artist
end

band = Band.first
band.manager # Parse::User object
band.lead_singer # Artist object
band.drummer # Artist object
```

###### `:field`
This option allows you to set the name of the remote Parse column for this property. Using this will explicitly set the remote property name to the value of this option. The value provided for this option will affect the name of the alias method that is generated when `alias` option is used. **By default, the name of the remote column is the lower-first camel case version of the property name. As an example, for a property with key `:my_property_name`, the framework will implicitly assume that the remote column is `myPropertyName`.**

> **Pairing `belongs_to`/`has_many` when you override `:as` or `:field`.** A
> `belongs_to`'s storage column comes from its **key** (or its explicit
> `:field`), *not* from the class chosen by `:as`. A `has_many` on the inverse
> side independently derives the column it queries from the **owning class
> name**. These two defaults only line up automatically when you don't override
> them — so if you customize one side, set `has_many ..., field:` to the exact
> column the `belongs_to` writes, or the `has_many` query silently returns zero
> results (it queries a column that does not exist, with no error). For example,
> if `Post belongs_to :author, as: :workspace` (stored in column `author`), the
> inverse must be `Workspace has_many :posts, as: :post, field: :author`.

#### [Has One](https://neurosynq.github.io/parse-stack-next/Parse/Associations/HasOne.html)
The `has_one` creates a one-to-one association with another Parse class. This association says that the other class in the association contains a foreign pointer column which references instances of this class. If your model contains a column that is a Parse pointer to another class, you should use `belongs_to` for that association instead.

Defining a `has_one` property generates a helper query method to fetch a particular record from a foreign class. This is useful for setting up the inverse relationship accessors of a `belongs_to`. In the case of the `has_one` relationship, the `:field` option represents the name of the column of the foreign class where the Parse pointer is stored. By default, the lower-first camel case version of the Parse class name is used.

In the example below, a `Band` has a local column named `manager` which has a pointer to a `Parse::User` record. This setups up the accessor for `Band` objects to access the band's manager.

```ruby
# every band has a manager
class Band < Parse::Object
	belongs_to :manager, as: :user
end

band = Band.first id: '12345'
# the user represented by this manager
user = band.manger

```

Since we know there is a column named `manager` in the `Band` class that points to a single `Parse::User`, you can setup the inverse association read accessor in the `Parse::User` class. Note, that to change the association, you need to modify the `manager` property on the band instance since it contains the `belongs_to` property.

```ruby
# every user manages a band
class Parse::User
  # inverse relationship to `Band.belongs_to :manager`
  has_one :band, field: :manager
end

user = Parse::User.first
# use the generated has_one accessor `band`.
user.band # similar to query: Band.first(:manager => user)

```

You may optionally use `has_one` with scopes, in order to fine tune the query result. Using the example above, you can customize the query with a scope that only fetches the association if the band is approved. If the association cannot be fetched, `nil` is returned.

```ruby
# adding to previous example
class Band < Parse::Object
  property :approved, :boolean
  property :approved_date, :date
end

# every user manages a band
class Parse::User
  has_one :recently_approved, ->{ where(order: :approved_date.desc) }, field: :manager, as: :band
  has_one :band_by_status, ->(status) { where(approved: status) },  field: :manager, as: :band
end

# gets the band most recently approved
user.recently_approved
# equivalent: Band.first(manager: user, order: :approved_date.desc)

# fetch the managed band that is not approved
user.band_by_status(false)
# equivalent: Band.first(manager: user, approved: false)

```

#### [Has Many](https://neurosynq.github.io/parse-stack-next/Parse/Associations/HasMany.html)
Parse has many ways to implement one-to-many and many-to-many associations: `Array`, `Parse Relation` or through a `Query`. How you decide to implement your associations, will affect how `has_many` works in Parse-Stack. Parse natively supports one-to-many and many-to-many relationships using `Array` and `Relations`, as described in [Relational Data](http://docs.parseplatform.org/js/guide/#relational-data). Both of these methods require you define a specific column type in your Parse table that will be used to store information about the association.

In addition to `Array` and `Relation`, Parse-Stack also implements the standard `has_many` behavior prevalent in other frameworks through a query where the associated class contains a foreign pointer to the local class, usually the inverse of a `belongs_to`. This requires that the associated class has a defined column
that contains a pointer the refers to the defining class.

##### Query
In this implementation, a `has_many` association for a Parse class requires that another Parse class will have a foreign pointer that refers to instances of this class. This is the standard way that `has_many` relationships work in most databases systems. This is usually the case when you have a class that has a `belongs_to` relationship to instances of the local class.

In the example below, many songs belong to a specific artist. We set this association by setting `:belongs_to` relationship from `Song` to `Artist`. Knowing there is a column in `Song` that points to instances of an `Artist`, we can setup a `has_many` association to `Song` instances in the `Artist` class. Doing so will generate a helper query method on the `Artist` instance objects.

```ruby
class Song < Parse::Object
  property :released, :date
  # this class will have a pointer column to an Artist
  belongs_to :artist
end

class Artist < Parse::Object
  has_many :songs
end

artist = Artist.first

artist.songs # => [all songs belonging to artist]
# equivalent: Song.all(artist: artist)

# filter also by release date
artist.songs(:released.after => 1.year.ago)
# equivalent: Song.all(artist: artist, :released.after => 1.year.ago)

```

In order to modify the associated objects (ex. `songs`), you must modify their corresponding `belongs_to` field (in this case `song.artist`), to another record and save it.

Options for `has_many` using this approach are `:as` and `:field`. The `:as` option behaves similarly to the `:belongs_to` counterpart. The `:field` option can be used to override the derived column name located in the foreign class. The default value for `:field` is the columnized version of the Parse subclass `parse_class` method.

```ruby
class Parse::User
  # since the foreign column name is :agent
  has_many :artists, field: :agent
end

class Artist < Parse::Object
  belongs_to :manager, as: :user, field: :agent
end

artist.manager # => Parse::User object

user.artists # => [artists where :agent column is user]
```

When using this approach, you may also employ the use of scopes to filter the particular data from the `has_many` association.

```ruby
class Artist
  has_many :songs, ->(timeframe) { where(:created_at.after => timeframe) }
end

artist.songs(6.months.ago)
# => [artist's songs created in the last 6 months]

```

You may also call property methods in your scopes related to the local class. You also have access to the instance object for the local class through a special `:i` method in the scope.

```ruby
class Concert
  property :city
  belongs_to :artist
end

class Artist
  property :hometown
  has_many :local_concerts, -> { where(:city => hometown) }, as: :concerts
end

# assume
artist.hometown = "San Diego"

# artist's concerts in their hometown of 'San Diego'
artist.local_concerts
# equivalent: Concert.all(artist: artist, city: artist.hometown)

```

##### Array
In this implementation, you can designate a column to be of `Array` type that contains a list of Parse pointers. Parse-Stack supports this by passing the option `through: :array` to the `has_many` method. If you use this approach, it is recommended that this is used for associations where the quantity is less than 100 in order to maintain query and fetch performance. You would be in charge of maintaining the array with the proper list of Parse pointers that are associated to the object. Parse-Stack does help by wrapping the array in a [Parse::PointerCollectionProxy](https://github.com/modernistik/parse-stack/blob/master/lib/parse/model/associations/pointer_collection_proxy.rb) which provides dirty tracking.

```ruby
class Artist < Parse::Object
end

class Band < Parse::Object
	has_many :artists, through: :array
end

artist = Artist.first

# find all bands that contain this artist
bands = Band.all( :artists.in => [artist.pointer] )

band = bands.first
band.artists # => [array of Artist pointers]

# remove artists
band.artists.remove artist

# add artist
band.artists.add artist

# save changes
band.save
```

##### Parse Relation
Other than the use of arrays, Parse supports native one-to-many and many-to-many associations through what is referred to as a [Parse Relation](http://docs.parseplatform.org/js/guide/#many-to-many-relationships). This is implemented by defining a column to be of type `Relation` which refers to a foreign class. Parse-Stack supports this by passing the `through: :relation` option to the `has_many` method. Designating a column as a Parse relation to another class type, will create a one-way intermediate "join-list" between the local class and the foreign class. One important distinction of this compared to other types of data stores (ex. PostgresSQL) is that:

1. The inverse relationship association is not available automatically. Therefore, having a column of `artists` in a `Band` class that relates to members of the band (as `Artist` class), does not automatically make a set of `Band` records available to `Artist` records for which they have been related. If you need to maintain both the inverse relationship between a foreign class to its associations, you will need to manually manage that by adding two Parse relation columns in each class, or by creating a separate class (ex. `ArtistBands`) that is used as a join table.
2. Querying the relation is actually performed against the implicit join table, not the local one.
3. Applying query constraints for a set of records within a relation is performed against the foreign table class, not the class having the relational column.

The Parse documentation provides more details on associations, see [Parse Relations Guide](http://docs.parseplatform.org/ios/guide/#relations). Parse-Stack will handle the work for (2) and (3) automatically.

In the example below, a `Band` can have thousands of `Fans`. We setup a `Relation<Fan>` column in the `Band` class that references the `Fan` class. Parse-Stack provides methods to manage the relationship under the [Parse::RelationCollectionProxy](https://github.com/modernistik/parse-stack/blob/master/lib/parse/model/associations/relation_collection_proxy.rb) class.

```ruby

class Fan < Parse::Object
  # .. lots of properties ...
	property :location, :geopoint
end

class Band < Parse::Object
	has_many :fans, through: :relation 
end

band = Band.first

 # the number of fans in the relation
band.fans.count

# get the first object in relation
fan = bands.fans.first # => Parse::User object

# use `add` or `remove` to modify relations
band.fans.add user
band.fans.add_unique user # no op
bands.fans.remove user

# updates the relation as well as changes to `band`
band.fans.save

# Find 50 fans who are near San Diego, CA
downtown = Parse::GeoPoint.new(32.82, -117.23)
fans = band.fans.all :location.near => downtown

```

You can perform atomic additions and removals of objects from `has_many` relations. Parse allows this by providing a specific atomic operation request. You can use the methods below to perform these types of atomic operations. __Note: The operation is performed directly on Parse server and not on your instance object.__

```ruby

# atomically add/remove
band.artists.add! objects  # { __op: :AddUnique }
band.artists.remove! objects  # { __op: :AddUnique }

# atomically add unique Artist
band.artists.add_unique! objects  # { __op: :AddUnique }

# atomically add/remove relations
band.fans.add! users # { __op: :Add }
band.fans.remove! users # { __op: :Remove }

# atomically perform a delete operation on this field name
# this should set it as `undefined`.
band.op_destroy!("category") # { __op: :Delete }

```

You can also perform queries against class entities to find related objects. Assume
that users can like a band. The `Band` class can have a `likes` column that is
a Parse relation to the `Parse::User` class containing the users who have liked a
specific band.

```ruby
  # assume the schema
  class Band < Parse::Object
    # likes is a Parse relation column of user objects.
    has_many :likes, through: :relation, as: :user
  end
```

You can now find all `Parse::User` records that have "liked" a specific band. *In the
example below, the `:likes` key refers to the `likes` column defined in the `Band`
collection which contains the set of user records.*

```ruby
  band = Band.first # get a band
  # find all users who have liked this band, where :likes is a column
  # in the Band collection - NOT in the User collection.
  users = Parse::User.all :likes.related_to => band

  # or use the relation accessor in band. It is equivalent since Band is
  # declared with a :has_many association.
  band.likes.all # => array of Parse::Users who liked the band
```
You can also find all bands that a specific user has liked.

```ruby
  user = Parse::User.first
  # find all bands where this user is contained in the `likes` Parse relation column
  # of the Band collection
  bands_liked_by_user = Band.all :likes => user
```

##### Options
Options for `has_many` are the same as the `belongs_to` counterpart with support for `:required`, `:as` and `:field`. It has these additional options.

###### `:through`
This sets the type of the `has_many` relation whose possible values are `:array`, `:relation` or `:query` (implicit default). If set to `:array`, it defines the column in Parse as being an array of Parse pointer objects and will be managed locally using a `Parse::PointerCollectionProxy`. If set to `:relation`, it defines a column of type Parse Relation with the foreign class and will be managed locally using a `Parse::RelationCollectionProxy`. If set to `:query`, no storage is required on the local class as the associated records will be fetched using a Parse query.

###### `:scope_only`
Setting this option to `true`, makes the association fetch based only on the scope provided and does not use the local instance object as a foreign pointer in the query. This allows for cases where another property of the local class, is needed to match the resulting records in the association.

In the example below, the `Post` class does not have a `:belongs_to` association to `Author`, but using the author's name, we can find related posts.

```ruby

class Author < Parse::Object
  property :name
  has_many :posts, ->{ where :tags.in => name.downcase }, scope_only: true
end

class Post < Parse::Object
  property :tags, :array
end

author.posts # => Posts where author's name is a tag
# equivalent: Post.all( :tags.in => artist.name.downcase )

```

## Creating, Saving and Deleting Records
This section provides some of the basic methods when creating, updating and deleting objects from Parse. Additional documentation for these APIs can be found under [Parse::Core::Actions](https://neurosynq.github.io/parse-stack-next/Parse/Core/Actions.html). To illustrate the various methods available for saving Parse records, we use this example class:

```ruby

class Artist < Parse::Object
  property :name
  belongs_to :manager, as: :user
end

class Song < Parse::Object
	property :name
	property :audio_file, :file
	property :released, :date
	property :available, :boolean, default: true
	belongs_to :artist
	has_many :fans, as: :user, through: :relation
end
```

### Create
To create a new object you can call `#new` while passing a hash of attributes you want to set. You can then use the property accessors to also modify individual properties. As you modify properties, you can access dirty tracking state and data using the generated [`ActiveModel::Dirty`](http://api.rubyonrails.org/classes/ActiveModel/Dirty.html) features. When you are ready to commit the new object to Parse, you can call `#save`.

```ruby
song = Song.new name: "My Old Song"
song.new? # true
song.id # nil
song.released = DateTime.now
song.changed? # true
song.changed # ['name', 'released']
song.name_changed? # true

# commit changes
song.save

song.new? # false
song.id # 'hZLbW6ofKC'
song.name = "My New Song"
song.name_was # "My Old Song"
song.changed # ['name']

```

## Upsert Operations
Parse-Stack provides Rails-style upsert methods that follow ActiveRecord conventions for finding or creating objects with optimized performance.

### first_or_create
Find the first object matching the query conditions, or create a new **unsaved** object with the attributes. This follows Rails conventions where existing objects are returned unchanged, and new objects are created but not automatically saved.

```ruby
# Find existing song or create new unsaved object
song = Song.first_or_create(name: "Awesome Song", available: true)
if song.new?
  song.released = 1.day.from_now
  song.save  # Manually save when ready
end

# If found, returns existing object unchanged
song = Song.first_or_create(name: "Awesome Song", available: true)
song.id # 'xyz1122df' - found existing object
```

You can separate query conditions from creation attributes by using two hash parameters:

```ruby
# Query by name, but set additional attributes only if creating
song = Song.first_or_create(
  { name: "Long Way Home" },           # Query conditions  
  { released: DateTime.now, genre: "rock" }  # Additional attributes for new objects
)
```

### first_or_create!
Similar to `first_or_create`, but automatically saves new objects. Existing objects are returned unchanged.

```ruby
# Find existing OR create and save new object
song = Song.first_or_create!(name: "New Song", available: true)
song.id # Always has an objectId (either found or newly saved)
```

### create_or_update!
Find the first object matching query conditions and update it with new attributes, or create a new saved object. Includes performance optimizations to skip saves when no changes are detected.

```ruby
# Update existing song or create new one
song = Song.create_or_update!(
  { name: "My Song" },                    # Query conditions
  { released: Time.now, plays: 100 }     # Attributes to update/set
)

# Performance optimization: no save occurs if attributes are identical
song = Song.create_or_update!(
  { name: "My Song" },
  { released: song.released }  # Same value - no save performed
)
```

**Key Benefits:**
- **Performance optimized**: Only saves when actual changes are detected
- **Rails conventions**: `first_or_create` doesn't modify existing objects
- **Flexible**: Separate query and attribute parameters for complex scenarios
- **Batch friendly**: Unsaved objects can be grouped for efficient batch operations

#### Concurrency-safe upsert with `synchronize:`

By default `first_or_create!` and `create_or_update!` have a TOCTOU window: two concurrent callers can both find no match, both create, and both succeed — producing duplicates. Pass `synchronize: true` to serialize the find→create→save sequence through a Moneta-backed mutex (typically Redis):

```ruby
# Per-call opt-in
User.first_or_create!({ email: e }, { name: n }, synchronize: true)

# Tune the lock parameters per call
Order.create_or_update!({ ref: r }, { status: "open" },
                        synchronize: { ttl: 5, wait: 1.0 })

# Enable globally for the whole app
Parse.synchronize_create_default = true
# or set ENV["PARSE_STACK_SYNCHRONIZE_CREATE"]=true at process start

# Per-class default
class User < Parse::Object
  self.synchronize_create_default = true
end

# Pass synchronize: false to override the global / per-class default
User.first_or_create!({ email: e }, {}, synchronize: false)

# Restrict the lock surface to specific classes (recommended when enabling globally)
Parse.synchronize_classes = [User, Device, Subscription]
```

The lock is a *latency optimization*; the durable correctness floor is a MongoDB unique index on the dedup tuple, declared on the model with `unique_index_on`:

```ruby
class User < Parse::Object
  property :email, :string
  unique_index_on :email          # provisioned via User.apply_indexes!
end
```

When such an index exists, the synchronize wrapper rescues Parse code 137 (DuplicateValue) and re-queries inside the held lock to return the winner. On a process-local Moneta store (no Redis), the lock degrades to a per-key `Mutex` and emits a `[Parse::CreateLock]` warning. Configure `Parse.synchronize_create_secret` (or `ENV["PARSE_STACK_LOCK_SECRET"]`) to HMAC the lock keys against `query_attrs` content exposure via Redis MONITOR / snapshots.

### Saving
To commit a new record or changes to an existing record to Parse, use the `#save` method. The method will automatically detect whether it is a new object or an existing one and call the appropriate workflow. The use of ActiveModel dirty tracking allows us to send only the changes that were made to the object when saving. **Saving a record will take care of both saving all the changed properties, and associations. However, any modified linked objects (ex. belongs_to) need to be saved independently.**

```ruby
 song = Song.new(name: "Awesome Song") # Pass in a hash to the new method
 song.name = "Super Song" # Set individual property

 # Set multiple properties at once
 song.attributes = { name: "Best Song", released: DateTime.now }

 song.artist = Artist.first
 song.artist.name = "New Band Name"
 # add a fan to this song. Note this is a Parse Relation
 song.fans.add = Parse::User.first

 # saves changed properties, associations and relations.
 song.save

 song.artist.save # to commit the changes made to 'name'.

 songs = Song.all( :available => false)
 songs.each { |song| song.available = true }

 # uses a Parse batch operation for efficiency
 songs.save # save the rest of the items
```

The save operation can handle both creating and updating existing objects. If you do not want to update the association data of a changed object, you may use the `#update` method to only save the changed property values. In the case where you want to force update an object even though it has not changed, to possibly trigger your `before_save` hooks, you can use the `#update!` method. In addition, just like with other ActiveModel objects, you may call `reload!` to fetch the current record again from the data store.

> **Note:** because of dirty tracking, `#save` is a no-op when the object has no changed fields — it returns `true` **without** issuing a request. A `true` return therefore does not guarantee a server write occurred (assigning a property its current value leaves the object unchanged). To force callbacks and a write even when nothing changed, pass `save(force: true)` or use `#update!`.

### Saving applying User ACLs
You may save and delete objects from Parse on behalf of a logged in user by passing the session token to the call to `save` or `destroy`. Doing so will allow Parse to apply the ACLs of this user against the record to see if the user is authorized to read or write the record. See [Parse::Actions](https://neurosynq.github.io/parse-stack-next/Parse/Core/Actions.html).

```ruby
  user = Parse::User.login('myuser','pass')

  song = Song.first
  song.title = "My New Title"
  # save this song as if you were this user.
  # If the user does not have access rights, it will fail
  song.save session: user.session_token
  # shorthand: song.save session: user
```

#### Raising an exception when save fails
By default, we return `true` or `false` for save and destroy operations. If you prefer to have `Parse::Object` raise an exception instead, you can tell to do so either globally or on a per-model basis. When a save fails, it will raise a `Parse::RecordNotSaved`.

```ruby
 # globally across all models
 Parse::Model.raise_on_save_failure = true
 Song.raise_on_save_failure = true  # per-model

 # or per-instance raise on failure
 song.save!
```

When enabled, if an error is returned by Parse due to saving or destroying a record, due to your `before_save` or `before_delete` validation cloud code triggers, `Parse::Object` will return the a `Parse::RecordNotSaved` exception type. This exception has an instance method of `#object` which contains the object that failed to save.

## Enhanced Object Fetching
Parse-Stack provides enhanced methods for fetching object data from Parse Server with improved consistency and flexibility.

### fetch and fetch_object
Both `Parse::Pointer` and `Parse::Object` support enhanced fetching methods that provide consistent behavior across different object types.

```ruby
# Enhanced fetch method with returnObject parameter (defaults to true)
pointer = Parse::Pointer.new("Song", "xyz123")
song_object = pointer.fetch(true)  # Returns fetched Parse::Object
song_data = pointer.fetch(false)   # Returns raw hash data

# Convenience method - always returns object
song_object = pointer.fetch_object  # Equivalent to fetch(true)

# Same methods work on existing Parse::Object instances
song = Song.first
refreshed_song = song.fetch_object  # Re-fetches and returns object
```

**Key Features:**
- **Consistent API**: Same methods work for both `Parse::Pointer` and `Parse::Object`
- **Flexible return types**: Choose between object instances or raw data
- **Change tracking preservation**: Fetched objects maintain proper dirty tracking state
- **Backwards compatible**: Existing `fetch` behavior preserved

### Partial Fetch on Existing Objects

You can partially fetch specific fields on existing objects or pointers using the `keys:` and `includes:` parameters. This is useful when you only need specific fields without fetching the entire object.

```ruby
# Partial fetch on a pointer - returns a new partially fetched object
pointer = Post.pointer("abc123")
post = pointer.fetch(keys: [:title, :content])
post.partially_fetched?           # true
post.field_was_fetched?(:title)   # true
post.field_was_fetched?(:author)  # false

# Partial fetch on an existing object - updates self
post = Post.find("abc123")
post.fetch(keys: [:view_count])   # Fetches only view_count, updates self

# Incremental partial fetch - keys are merged
post = Post.first(keys: [:title])
post.field_was_fetched?(:title)   # true
post.field_was_fetched?(:content) # false
post.fetch(keys: [:content])      # Add content to fetched keys
post.field_was_fetched?(:title)   # true - still tracked
post.field_was_fetched?(:content) # true - now tracked
```

#### Nested Fields with Dot Notation

Use dot notation in `keys:` to fetch specific fields from related objects. Parse Server automatically resolves the pointer.

```ruby
# Partial fetch with nested fields (pointer auto-resolved)
post = Post.pointer("abc123").fetch(keys: ["author.name", "author.email"])
post.author.pointer?                    # false - expanded to object
post.author.partially_fetched?          # true
post.author.field_was_fetched?(:name)   # true
post.author.field_was_fetched?(:age)    # false

# Access unfetched nested field triggers autofetch
post.author.age  # Automatically fetches the full author object
```

#### fetch_json for Raw Data

Use `fetch_json` to get raw JSON data without updating the object:

```ruby
post = Post.find("abc123")
json = post.fetch_json(keys: [:title, :view_count])
# json is a Hash: {"objectId" => "abc123", "title" => "...", "viewCount" => 100}
# post is unchanged
```

#### Dirty Tracking During Fetch

By default, `fetch` discards local changes to fetched fields and applies server values. Use `preserve_changes: true` to keep local changes.

```ruby
# Default behavior: server values are applied, local changes discarded
post = Post.find("abc123")
post.title = "Modified Title"
post.fetch                    # Warning logged, local change discarded
post.title                    # => "Original Title" (server value)
post.title_changed?           # false

# Preserve local changes with preserve_changes: true
post = Post.find("abc123")
post.title = "Modified Title"
post.fetch(preserve_changes: true)  # Local changes preserved
post.title                          # => "Modified Title"
post.title_changed?                 # true

# Unfetched dirty fields are ALWAYS preserved (regardless of preserve_changes)
post = Post.find("abc123")
post.title = "Modified Title"
post.category = "tech"
post.fetch(keys: [:title])    # Only fetch title, not category
post.title_changed?           # false - title was fetched, server value applied
post.category_changed?        # true - category NOT fetched, dirty preserved
post.category                 # => "tech" (local value preserved)
```

**Important:** Base fields (`id`, `created_at`, `updated_at`) always accept server values regardless of `preserve_changes` setting.

#### Dirty Tracking on Embedded/Pointer Objects

When you have an embedded object (e.g., from a `belongs_to` association) that's in pointer state (has `id` but not yet fully fetched), setting fields on it will correctly mark those fields as dirty. The object will be auto-fetched before the change is tracked.

```ruby
# report has an embedded scheduled_report that's in pointer state
report = Report.first(id: "abc123")
scheduled = report.scheduled_report  # Pointer state (only has id)

# Setting a field auto-fetches and correctly tracks the change
scheduled.status = :completed
scheduled.dirty?          # => true
scheduled.status_changed? # => true
scheduled.save            # Saves the change to Parse
```

#### Array Dirty Tracking

For `has_many` associations (arrays of pointers), only structural changes to the array mark the parent as dirty:

```ruby
artist = Artist.first
artist.songs.clear_changes!

# Modifying a nested object does NOT mark parent dirty
artist.songs.first.plays = 100
artist.dirty?        # => false (array structure unchanged)
artist.songs.first.dirty?  # => true (the song itself is dirty)

# Adding/removing items DOES mark parent dirty
artist.songs.add(new_song)
artist.dirty?        # => true (array structure changed)

artist.songs.remove(old_song)
artist.dirty?        # => true
```

#### Object Identity and Equality

Parse objects are compared by identity (`parse_class` and `id`), not by their field values or dirty state:

```ruby
# Pointer, partial object, and full object with same id are equal
pointer = Song.pointer("abc123")
partial = Song.first(id: "abc123", keys: [:title])
full = Song.find("abc123")

pointer == partial  # => true (same id)
partial == full     # => true (same id)

# Works correctly with array operations
[pointer, partial, full].uniq.size  # => 1 (all same identity)
```

### Modifying Associations
Similar to `:array` types of properties, a `has_many` association is backed by a collection proxy class and requires the use of `#add` and `#remove` to modify the contents of the association in order for it to correctly manage changes and updates with Parse. Using `has_many` for associations has the additional functionality that we will only add items to the association if they are of a `Parse::Pointer` or `Parse::Object` type. By default, these associations are fetched with only pointer data. To fetch all the objects in the association, you can call `#fetch` or `#fetch!` on the collection. Note that because the framework supports chaining, it is better to only request the objects you need by utilizing their accessors.

```ruby
  class Artist < Parse::Object
    has_many :songs # array association
  end

  artist = Artist.first
  artist.songs # Song pointers

  # fetch all the objects in this association
  artist.songs.fetch # fetches with parallel requests

  # add another song
  artist.songs.add Song.first
  artist.songs.remove other_song
  artist.save # commits changes
```

For the cases when you want to modify the items in this association without having to fetch all the objects in the association, we provide the methods `#add!`, `#add_unique!`, `#remove!` and `#destroy` that perform atomic Parse operations. These Parse operations are made directly to Parse compared to the non-bang versions which are batched with the rest of the pending object changes.

```ruby
  artist = Artist.first
  artist.songs.add! song # Add operation
  artist.songs.add_unique! other_song # AddUnique operation
  artist.songs.remove! another_song # Remove operation
  artist.save # no-op. (no operations were sent directly to Parse)

  artist.songs.destroy! # Delete operation of all Songs
```

The `has_many` Parse Relation associations are handled similarly as in the array cases above. However, since a Parse Relation represents a separate table, there are additional methods provided in order to query the intermediate relational table.

```ruby
  song = Song.first

  # Standard methods, but through relation table
  song.fans.count # efficient counting
  song.fans.add user
  song.fans.remove another_user
  song.save # commit changes

  # OR use to commit ONLY relational changes
  song.fans.save

  # Additional filtering methods

  # Find objects within the relation that match query constraints
  song.fans.all( ... constraints ... )

  # get a foreign relational query, related to this object
  query = song.fans.query

  # Atomic operations
  song.fans.add! user # AddRelation operation
  song.fans.remove! user # RemoveRelation operation
  song.fans.destroy! #noop since Relations cannot be emptied.

```

### Batch Requests
Batch requests are supported implicitly and intelligently through an extension of Array. When an array of `Parse::Object` subclasses is saved, Parse-Stack will batch all possible save operations for the objects in the array that have changed. It will also batch save 50 at a time until all items in the array are saved. The objects do not have to be of the same collection in order to be supported in the batch request. *Note: Parse does not allow batch saving Parse::User objects.*

```ruby
songs = Songs.first 1000 #first 1000 songs
songs.each do |song|
  .... modify them ...
end

# will batch save 50 items at a time until all are saved.
songs.save

# you can also destroy a set of objects
songs.destroy
```

### Magic `save_all`
By default, all Parse queries have a maximum fetch limit of 1000. While using the `:max` option, Parse-Stack can increase this up to 11,000. In the cases where you need to update a large number of objects, you can utilize the `Parse::Object#save_all` method to fetch, modify and save objects.

This methodology works by continually fetching and saving older records related to the time you begin a `save_all` request (called an "anchor date"), until there are no records left to update. To enable this to work, you must have confidence that any modifications you make to the records will successfully save through you validations that may be present in your `before_save`. This is important, as saving a record will set its `updated_at` date to one newer than the "anchor date" of when the `save_all` started. This `save_all` process will stop whenever no more records match the provided constraints that are older than the "anchor date", or when an object that was previously updated, is seen again in a future fetch (_which means the object failed to save_). Note that `save_all` will automatically manage the correct `updated_at` constraints in the query, so it is recommended that you do not use it as part of the initial constraints.

```ruby
  # Add any constraints except `updated_at`.
  Song.save_all( available: false) do |song|
    song.available = true # make all songs available
    # only objects that were modified will be updated
  	# do not call save. We will batch objects for saving.
  end
```

If you plan on using this feature in a lot of places, we recommend making sure you have set a MongoDB index of at least `{ "_updated_at" : 1 }`.

## Atomic Transactions
Parse-Stack provides full atomic transaction support to ensure data consistency across multiple operations. All operations within a transaction either succeed completely or fail completely with automatic rollback.

### Basic Transaction Usage
Use `Parse::Object.transaction` with a block to group operations atomically:

```ruby
# Explicit batch operations
Parse::Object.transaction do |batch|
  # Update existing objects
  user = Parse::User.first
  user.score = 100
  batch.add(user)
  
  # Create new objects
  achievement = Achievement.new(user: user, name: "High Score")
  batch.add(achievement)
  
  # All operations execute atomically
end
```

### Auto-Batching with Return Values
You can also return objects from the transaction block for automatic batching:

```ruby
# Objects returned from block are automatically batched
Parse::Object.transaction do
  user1 = Parse::User.first
  user1.score = 200
  
  user2 = Parse::User.first(username: "player2")
  user2.score = 150
  
  [user1, user2]  # Auto-batched for atomic save
end
```

### Transaction Features
- **Atomic operations**: All operations succeed or all fail with rollback
- **Automatic retries**: Conflicts (error 251) are automatically retried with configurable limits
- **Mixed operations**: Support create, update, and delete operations in single transaction
- **Error handling**: Comprehensive error handling with meaningful exception messages
- **Object ID assignment**: New objects automatically receive their `objectId`, `createdAt`, and `updatedAt` from the server response after successful transaction

```ruby
# Transaction with custom retry limit and error handling
begin
  Parse::Object.transaction(retries: 10) do |batch|
    # Complex business operations
    order = Order.create!(items: cart_items, customer: customer)
    inventory.update!(quantity: inventory.quantity - order.total_items)
    customer.update!(last_order: order)

    [order, inventory, customer]
  end
rescue Parse::Error => e
  puts "Transaction failed: #{e.message}"
  # Handle failure (all changes rolled back)
end
```

### Transaction Object Updates

When you create new objects within a transaction, their `objectId`, `createdAt`, and `updatedAt` fields are automatically populated after the transaction succeeds:

```ruby
products = []

Parse::Object.transaction do |batch|
  3.times do |i|
    product = Product.new(name: "Product #{i}", price: i * 10)
    products << product
    batch.add(product)
  end
end

# After successful transaction, all objects have their IDs
products.each do |p|
  puts "#{p.name}: #{p.id}"  # IDs are now populated
end
```

### Deleting
You can destroy a Parse record, just call the `#destroy` method. It will return a boolean value whether it was successful.

```ruby
 song = Song.first
 song.destroy

 # or in a batch
 songs = Song.all :limit => 10
 songs.destroy # uses batch operation
```

## Fetching, Finding and Counting Records

```ruby
 song = Song.find "<objectId>"
        Song.get  "<objectId>" # alias

 song1, song2 = Song.find("<objectId>", "<objectId2>", ...) # fetches in parallel with threads

 count = Song.count( constraints ) # performs a count operation

 query = Song.where( constraints ) # returns a Parse::Query with where clauses
 song = Song.first( ... constraints ... ) # first Song matching constraints
 s1, s2, s3 = Song.first(3) # get first 3 records from Parse.

 song = Song.latest( ... constraints ... ) # most recently created Song matching constraints
 recent_songs = Song.latest(5) # get 5 most recently created Songs
 
 song = Song.last_updated( ... constraints ... ) # most recently updated Song matching constraints  
 updated_songs = Song.last_updated(3) # get 3 most recently updated Songs

 songs = Song.all( ... expressions ...) # get matching Song records. See Advanced Querying

 # memory efficient for large amounts of records if you don't need all the objects.
 # Does not return results after loop.
 Song.all( ... expressions ...) do |song|
   # ... do something with song..
 end

```

### Auto-Fetching Associations
All associations in are fetched lazily by default. If you wish to include objects as part of your query results you can use the `:includes` expression.

```ruby
  song = Song.first
  song.artist.pointer? # true, not fetched

  # find songs and include the full artist object for each
  song = Song.first(:includes => :artist)
  song.artist.pointer? # false (Full object already available)

```

However, Parse-Stack performs automatic fetching of associations when the associated classes and their properties are locally defined. Using our Artist and Song examples. In this example, the Song object fetched only has a pointer object in its `#artist` field. However, because the framework knows there is a `Artist#name` property, calling `#name` on the artist pointer will automatically go to Parse to fetch the associated object and provide you with the value.

```ruby
  song = Song.first
  # artist is automatically fetched
  song.artist.name

  # You can manually do the same with `fetch` and `fetch!`
  song.artist.fetch # considered "fetch if needed". No-op if not needed.
  song.artist.fetch! # force fetch regardless of state.
```

This also works for all associations types.

```ruby
  song = Song.first
  # automatically fetches all pointers in the chain
  song.artist.manager.username # Parse::User's username

  # Fetches Parse Relation objects
  song.fans.first.username # the fan's username
```

### Partial Fetch and Autofetch Behavior

Parse-Stack supports partial fetches, where you can query for objects with only specific fields included using the `:keys` parameter. This is useful for optimizing queries when you don't need all fields.

```ruby
# Fetch only specific fields
post = Post.first(keys: [:id, :title, :author])
post.partially_fetched? # true
post.field_was_fetched?(:title) # true
post.field_was_fetched?(:content) # false

# Accessing an unfetched field triggers autofetch
content = post.content # Automatically fetches the full object from Parse
```

#### Fetch Status Methods

Parse objects can be in one of three states, and you can check the status using these methods:

| Method | Pointer | Partially Fetched | Fully Fetched |
|--------|---------|-------------------|---------------|
| `pointer?` | `true` | `false` | `false` |
| `partially_fetched?` | `false` | `true` | `false` |
| `fully_fetched?` | `false` | `false` | `true` |
| `fetched?` | `false` | `true` | `true` |

```ruby
# Pointer state (only id, no data fetched)
pointer = Post.pointer("abc123")
pointer.pointer?           # => true
pointer.partially_fetched? # => false
pointer.fully_fetched?     # => false
pointer.fetched?           # => false

# Partially/selectively fetched (specific keys only)
partial = Post.first(keys: [:title, :author])
partial.pointer?           # => false
partial.partially_fetched? # => true
partial.fully_fetched?     # => false
partial.fetched?           # => true

# Fully fetched (all fields available)
full = Post.first
full.pointer?           # => false
full.partially_fetched? # => false
full.fully_fetched?     # => true
full.fetched?           # => true
```

The `fetched?` method returns `true` for any object with data (either partially or fully fetched). Use `fully_fetched?` if you need to check that all fields are available, or `partially_fetched?` to check if only specific keys were fetched.

#### Serialization of Partially Fetched Objects

By default, calling `as_json` or `to_json` on a partially fetched object will only serialize the fields that were fetched. This prevents autofetch from being triggered during serialization and is particularly useful for webhook responses.

```ruby
# Default behavior (Parse.serialize_only_fetched_fields = true)
user = User.first(keys: [:id, :first_name, :email])
user.to_json  # Only includes id, first_name, email (plus metadata)

# Useful for webhook responses - returns only requested fields
Parse::Webhooks.route :function, :getWorkspaceMembers do
  users = User.all(:id.in => user_ids, keys: [:id, :first_name, :icon_image])
  users  # Returns only the requested fields, no autofetch triggered
end

# Disable globally if needed
Parse.serialize_only_fetched_fields = false

# Or override per-call
user.as_json(only_fetched: false)  # Serialize all fields (may trigger autofetch)
```

#### Autofetch Behavior with `disable_autofetch!`

You can disable automatic fetching on an object using `disable_autofetch!`. This is useful when you want strict control over network requests:

```ruby
post = Post.first(keys: [:id, :title])
post.disable_autofetch!

# Now accessing unfetched fields raises an error
post.content # Raises Parse::UnfetchedFieldAccessError
```

**Autofetch behavior by object type:**

1. **`Parse::Pointer` objects** (created via `Model.pointer("id")`):
   - Accessing any property automatically fetches the full object and returns the value
   - The fetched object is cached, so subsequent property accesses don't trigger additional fetches
   - With `autofetch_raise_on_missing_keys` enabled, raises `Parse::AutofetchTriggeredError` instead

2. **`Parse::Object` in pointer state** (objects with only `id`, no fetched data):
   - Accessing an unfetched field triggers autofetch by default
   - With `disable_autofetch!`, accessing any field returns `nil` (backward compatible behavior)

3. **Partially fetched objects** (objects fetched with `:keys` parameter):
   - Accessing an unfetched field triggers autofetch by default
   - With `disable_autofetch!`, raises `Parse::UnfetchedFieldAccessError` (strict behavior)
   - Autofetch preserves any nested embedded data on pointer fields (e.g., `author.name` won't be lost)

```ruby
# Parse::Pointer auto-fetch (new in 2.1.6)
pointer = Song.pointer("abc123")
pointer.title # Auto-fetches and returns title

# Parse::Object in pointer state
song = Song.new(id: "abc123") # Just a pointer, no data fetched
song.disable_autofetch!
song.title # Returns nil (backward compatible behavior)

# Partially fetched object behavior
song = Song.first(id: "abc123", keys: [:id, :artist])
song.disable_autofetch!
song.artist # Works - this field was fetched
song.title # Raises Parse::UnfetchedFieldAccessError (strict behavior)
```

**Rationale:** Pointer objects have historically always returned `nil` for unfetched fields - this is well-understood behavior that existing applications depend on. Partially fetched objects are a newer feature where it's less obvious which fields are available, so raising explicit errors helps catch bugs early. `Parse::Pointer` objects now support auto-fetch on property access for convenience.

#### Debugging Autofetch with `autofetch_raise_on_missing_keys`

During development, you can enable `Parse.autofetch_raise_on_missing_keys` to identify all places in your code where autofetch is being triggered. This helps you add the necessary keys to your queries to avoid unnecessary network requests:

```ruby
# Enable globally for debugging
Parse.autofetch_raise_on_missing_keys = true

# Now accessing unfetched fields raises an error with helpful info
post = Post.first(keys: [:title])
post.content # Raises Parse::AutofetchTriggeredError
# => "Autofetch triggered on Post#abc123 - field :content was not included in partial fetch. Add :content to your query keys."

# For pointers, the message suggests using includes
song = Song.pointer("xyz789")
song.title # Raises Parse::AutofetchTriggeredError
# => "Autofetch triggered on Song#xyz789 - pointer accessed field :title. Add this field to your includes or fetch the object first."
```

This is particularly useful when optimizing your application's network usage. Enable it in development/test environments to catch all autofetch triggers, then add the appropriate keys or includes to your queries.

```ruby
# Example workflow:
# 1. Enable in development
Parse.autofetch_raise_on_missing_keys = true

# 2. Run your code - errors will tell you exactly which fields are missing
# 3. Add the fields to your queries:
Post.first(keys: [:title, :content, :author])  # Add missing fields

# 4. Disable when done debugging
Parse.autofetch_raise_on_missing_keys = false
```

## Advanced Querying
The `Parse::Query` class provides the lower-level querying interface for your Parse tables using the default `Parse::Client` session created when `setup()` was called. This component can be used on its own without defining your models as all results are provided in hash form. By convention in Ruby (see [Style Guide](https://github.com/bbatsov/ruby-style-guide#snake-case-symbols-methods-vars)), symbols and variables are expressed in lower_snake_case form. Parse, however, prefers column names in **lower-first camel case** (ex. `objectId`, `createdAt` and `updatedAt`). To keep in line with the style guides between the languages, we do the automatic conversion of the field names when compiling the query. As an additional exception to this rule, the field key of `id` will automatically be converted to the `objectId` field when used. This feature can be overridden by changing the value of `Parse::Query.field_formatter`.

```ruby
# default uses :columnize
query = Parse::User.query :field_one => 1, :FieldTwo => 2, :Field_Three => 3
query.compile_where # {"fieldOne"=>1, "fieldTwo"=>2, "fieldThree"=>3}

# turn off
Parse::Query.field_formatter = nil
query = Parse::User.query :field_one => 1, :FieldTwo => 2, :Field_Three => 3
query.compile_where # {"field_one"=>1, "FieldTwo"=>2, "Field_Three"=>3}

# force everything camel case
Parse::Query.field_formatter = :camelize
query = Parse::User.query :field_one => 1, :FieldTwo => 2, :Field_Three => 3
query.compile_where # {"FieldOne"=>1, "FieldTwo"=>2, "FieldThree"=>3}

```

Simplest way to perform query, is to pass the Parse class as the first parameter and the set of expressions.

```ruby
 query = Parse::Query.new("Song", {.... expressions ....})
 # or with Object classes
 query = Song.query({ .. expressions ..})

 # Print the prepared query
 query.prepared

 # Get results
 query.results # get results as Parse::Object(s)
 query.results(raw: true) # get the raw hash results

 query.first # first results matching constraints
 query.first(3) # gets first 3 results matching constraints

 query.count # perform a count operation instead
```

For large results set where you may want to operate on objects and may not need to keep all the objects in memory, you can use the block version of the API to iterate through all the records more efficiently.

```ruby

 # For large results set, you can use the block version to iterate over each matching record
 query.each do |record|
	# ... do something with record ...
	# block version does not return results
 end

```

### Results Caching
When a query API is made, the results are cached in the query object in case you need access to the results multiple times. This is only true as long as no modifications to the query parameters are made. You can force clear the locally stored results by calling `clear()` on the query instance.

```ruby
 query = Parse::Query.new("Song")
 query.where :field => value

 query.results # makes request
 # no query parameters changed, therefore same results
 query.results # no API request

 # if you modify the query or call 'clear'
 query.clear
 query.results # makes API request

```

### Counting
If you only need to know the result count for a query, provide count a
non-zero value. However, if you need to perform a count query, use `count()` method instead.

```ruby
 # get number of songs with a play_count > 10
 Song.count :play_count.gt => 10

 # same
 query = Parse::Query.new("Song")
 query.where :play_count.gt => 10
 query.count

```

### Count Distinct
Counts the number of distinct values for a specified field using MongoDB aggregation pipeline. This is more efficient than getting distinct values and counting them, especially for large datasets.

```ruby
 # get count of unique genres for songs with play_count > 100
 distinct_genres_count = Song.count_distinct(:genre, :play_count.gt => 100)

 # get total number of unique artists
 unique_artists = Song.count_distinct(:artist)

 # same using query instance
 query = Parse::Query.new("Song") 
 query.where(:play_count.gt => 1000)
 query.count_distinct(:artist)
 # => 15
```

**Note:** This feature requires MongoDB aggregation pipeline support in Parse Server.

### Aggregation Functions

Parse-Stack supports MongoDB aggregation functions for performing calculations across collections. These functions are efficient server-side operations.

```ruby
# Calculate sum of all scores
total_score = User.sum(:score)
# => 1547

# Find minimum and maximum values
min_age = User.min(:age)      # => 18
max_age = User.max(:age)      # => 65

# Calculate average rating
avg_rating = Product.average(:rating)  # => 4.2
# Or use the alias
avg_rating = Product.avg(:rating)      # => 4.2

# With query constraints
high_scores = User.where(:level.gt => 5).sum(:score)
recent_avg = Post.where(:created_at.after => 1.week.ago).avg(:views)
```

**Note:** These features require MongoDB aggregation pipeline support in Parse Server.

### Group By Operations

Group records by field values and perform aggregations on each group. Supports both server-side aggregation and client-side object grouping.

```ruby
# Basic grouping with count
User.group_by(:department).count
# => {"Engineering" => 45, "Marketing" => 23, "Sales" => 67}

# Group with other aggregations
User.group_by(:department).sum(:salary)
# => {"Engineering" => 450000, "Marketing" => 230000, "Sales" => 670000}

User.group_by(:department).avg(:salary)
# => {"Engineering" => 10000, "Marketing" => 10000, "Sales" => 10000}

# Group by date intervals
Post.group_by_date(:created_at, :month).count
# => {"2024-01" => 45, "2024-02" => 32, "2024-03" => 28}

Post.group_by_date(:created_at, :day).sum(:views)
# => {"2024-03-01" => 1200, "2024-03-02" => 950, ...}

# Sortable grouping (returns GroupedResult with sorting methods)
result = User.group_by(:city, sortable: true).count
result.sort_by_key_asc     # Sort by city name
result.sort_by_value_desc  # Sort by count (highest first)
result.to_table           # Display as formatted table

# Group actual objects (not aggregated - returns full Parse objects)
users_by_city = User.group_objects_by(:city)
# => {"New York" => [user1, user2, ...], "Austin" => [user3, user4, ...]}

# Advanced options
User.group_by(:tags, flatten_arrays: true).count  # Flatten array fields
User.group_by(:workspace, return_pointers: true).count # Use pointers for efficiency
```

**Available aggregation methods:** `count`, `sum(field)`, `min(field)`, `max(field)`, `avg(field)`
**Date intervals:** `:year`, `:month`, `:week`, `:day`, `:hour`

### Distinct Aggregation
Finds the distinct values for a specified field across a single collection or
view and returns the results in an array. You may mix this with additional query constraints.

**⚠️ Breaking Change in v1.12.0**: For pointer fields, `distinct` now returns object IDs directly by default instead of full pointer hash objects like `{"__type"=>"Pointer", "className"=>"Workspace", "objectId"=>"abc123"}`. Use `return_pointers: true` to get Parse::Pointer objects.

```ruby
 # Return a list of unique city names
 # for users created in the last 10 days.
 User.distinct :city, :created_at.after => 10.days.ago
 # ex. ["San Diego", "Los Angeles", "San Juan"]

 # For pointer fields, now returns object IDs by default (v1.12.0+)
 Document.distinct(:author_workspace)
 # => ["team1", "team2", "team3"]  # Just the object IDs

 # Pre-v1.12.0 behavior returned full pointer hashes:
 # [{"__type"=>"Pointer", "className"=>"Workspace", "objectId"=>"team1"}, ...]
 
 # To get Parse::Pointer objects in v1.12.0+
 Document.distinct(:author_workspace, return_pointers: true)
 # => [#<Parse::Pointer @parse_class="Workspace" @id="team1">, ...]

 # same using query instance
 query = Parse::Query.new("_User")
 query.where :created_at.after => 10.days.ago
 query.distinct(:city) #=> ["San Diego", "Los Angeles", "San Juan"]

```

### Query Expressions
The set of supported expressions based on what is available through the Parse REST API. _For those who don't prefer the DataMapper style syntax, we have provided method accessors for each of the expressions._ A full description of supported query  operations, please refer to the [`Parse::Query`](https://neurosynq.github.io/parse-stack-next/Parse/Query.html) API reference.

#### :order
Specify a field to sort by.

```ruby
 # order updated_at ascending order
 Song.all :order => :updated_at

 # first order by highest like_count, then by ascending name.
 # Note that ascending is the default if not specified (ex. `:name.asc`)
 Song.all :order => [:like_count.desc, :name]
```

#### :keys
Restrict the fields returned by the query. This is useful for larger query results set where some of the data will not be used, which reduces network traffic and deserialization performance. _Use this feature with caution when working with the results, as values for the fields not specified in the query will be omitted in the resulting object._

```ruby
 # results only contain :name field
 Song.all :keys => :name

 # multiple keys
 Song.all :keys => [:name,:artist]
```

#### :includes
Use on Pointer columns to return the full object. You may chain multiple columns with the `.` operator.

```ruby
 # assuming an 'Artist' has a pointer column for a 'Manager'
 # and a Song has a pointer column for an 'Artist'.

 # include the full artist object
 Song.all(:includes => :artist)

 # Chaining
 Song.all :includes => [:artist, 'artist.manager']

```

#### :limit
Limit the number of objects returned by the query. The default is 100, with Parse allowing a maximum of 1000. The framework also allows a value of `:max`. Utilizing this will have the framework continually intelligently utilize `:skip` to continue to paginate through results until an empty result set is received or the `:skip` limit is reached. When utilizing `all()`, `:max` is the default option for `:limit`.

```ruby
 Song.all :limit => 1 # same as Song.first
 Song.all :limit => 1000 # maximum allowed by Parse
 Song.all :limit => :max
```

#### :skip
Use with limit to paginate through results. Default is 0.

```ruby
 # get the next 3 songs after the first 10
 Song.all :limit => 3, :skip => 10
```

> **Note:** For large datasets, skip-based pagination becomes increasingly slow. Consider using [Cursor-Based Pagination](#cursor-based-pagination) instead.

### Cursor-Based Pagination

For efficiently traversing large datasets, Parse Stack provides cursor-based pagination which maintains consistent performance regardless of how deep you paginate.

**Why use cursors instead of skip/offset?**
- **Consistent performance**: Skip-based pagination slows down as offset increases; cursors don't
- **No skipped/duplicate records**: Handles records added/deleted during pagination
- **Memory efficient**: Fetches one page at a time

```ruby
# Basic usage - iterate over pages
cursor = Song.cursor(limit: 100)
cursor.each_page do |page|
  process(page)
end

# Iterate over individual items
Song.cursor(limit: 50).each do |song|
  puts song.title
end

# With query constraints
cursor = Song.query(:artist => "Artist Name").cursor(limit: 100)
cursor.each_page { |page| process(page) }

# With custom ordering
cursor = Song.cursor(limit: 100, order: :created_at.desc)

# Manual pagination control
cursor = User.cursor(limit: 100)
first_page = cursor.next_page
second_page = cursor.next_page
cursor.reset!  # Start over
```

**Cursor Statistics:**
```ruby
cursor.stats
# => { pages_fetched: 5, items_fetched: 500, page_size: 100, exhausted: true, ... }

cursor.more_pages?  # true/false
cursor.exhausted?   # true/false
```

**Resumable Cursors (for background jobs):**

Cursors can be serialized and resumed later - perfect for jobs that may be interrupted:

```ruby
# Save cursor state
cursor = Song.cursor(limit: 100)
cursor.next_page  # Process first page
state = cursor.serialize
Redis.set("job:#{job_id}:cursor", state)

# Resume later (even in a different process)
state = Redis.get("job:#{job_id}:cursor")
cursor = Parse::Cursor.deserialize(state)
cursor.each_page { |page| process(page) }  # Continues where it left off
```

#### :cache
A `true`, `false` or integer value. If you are using the built-in caching middleware, `Parse::Middleware::Caching`, setting this to `true` will use a previously cached result if available. Setting to `false` will prevent caching. You may pass an integer value, which will allow this request to be cached for the specified number of seconds. **The default value is `false`** (queries do not use cache unless explicitly enabled).

```ruby
# explicitly use cache for this request
Song.all limit: 500, cache: true

# cache this particular request for 60 seconds
Song.all limit: 500, cache: 1.minute

# don't use cache (default behavior)
Song.all limit: 500, cache: false
```

To change the default caching behavior globally, use the `Parse.default_query_cache` configuration:

```ruby
# Enable cache by default (opt-out behavior)
Parse.default_query_cache = true
Song.first                           # Uses cache
Song.query(cache: false).first       # Explicitly bypasses cache

# Disable cache by default (opt-in behavior, this is the default)
Parse.default_query_cache = false
Song.first                           # Does NOT use cache
Song.query(cache: true).first        # Explicitly uses cache
```

You may access the shared cache for the default client connection through `Parse.cache`. This is useful if you
want to utilize the same cache store for other purposes.

```ruby
# Access the cache instance for other uses
Parse.cache["key"] = "value"
Parse.cache["key"] # => "value"

# or with Parse queries and objects
Parse.cache.fetch("all:song:records") do |key|
  results = Song.all # or other complex query or operation
  # store it in the cache, but expires in 30 seconds
  Parse.cache.store(key, results, expires: 30)
end

```

#### :use_master_key
A true/false value. If you provided a master key as part of `Parse.setup()`, it will be sent on every request. However, if you wish to disable sending the master key on a particular request in order for the record ACLs to be enforced, you may pass `false`. If `false` is passed, caching will be disabled for this request.

```ruby
# disable sending the master key in the request if configured
Song.all limit: 3, use_master_key: false
```

As of v5.0, `Parse::Query` initializes `@use_master_key` to `nil` (tri-state: "no caller preference") rather than `true`. Server-mode behavior is unchanged — when nothing in the call chain expresses a preference, the request layer still sends the master key. The difference matters for `Parse.client_mode = true` processes and inside `Parse.with_session(user) { … }` blocks: the previous `true` default short-circuited those resolutions and silently master-key-stamped queries. Explicitly passing `use_master_key: true` (or calling `query.use_master_key = true`) still forces the header. `Parse::Query#assert_mongo_direct_routable!` treats a configured master key on the client as an ambient credential in server mode: direct-only constraints (Atlas Search-shaped operators, etc.) route through the mongo-direct path as long as `Parse.client_mode` is false and `use_master_key` was not explicitly set to `false`. The gate still raises `Parse::Query::MongoDirectRequired` for client-mode processes or queries that explicitly opt out of the master key without supplying a `session_token` / `.scope_to_user(user)` / `.scope_to_role(role)`.

#### :session
This will make sure that the query is performed on behalf (and with the privileges) of an authenticated user which will cause record ACLs to be enforced. If a session token is provided, caching will be disabled for this request. You may pass a string representing the session token, an authenticated `Parse::User` instance or a `Parse::Session` instance.

```ruby
# disable sending the master key in the request if configured
# and perform this request as a Parse user represented by this token
Song.all limit: 3, session: "<session_token>"
Song.all limit: 3, session: user # a logged-in Parse::User
Song.all limit: 3, session: session # Parse::Session
```

#### :where
The `where` clause is based on utilizing a set of constraints on the defined column names in your Parse classes. The constraints are implemented as method operators on field names that are tied to a value. Any symbol/string that is not one of the main expression keywords described here will be considered as a type of query constraint for the `where` clause in the query. See the section `Query Constraints` for examples of available query constraints.

```ruby
# parts of a single where constraint
{ :column.constraint => value }
```

## [Query Constraints](https://neurosynq.github.io/parse-stack-next/Parse/Constraint.html)
Most of the constraints supported by Parse are available to `Parse::Query`. Assuming you have a column named `field`, here are some examples. For an explanation of the constraints, please see [Parse Query Constraints documentation](http://docs.parseplatform.org/rest/guide/#queries). You can build your own custom query constraints by creating a `Parse::Constraint` subclass. For all these `where` clauses assume `q` is a `Parse::Query` object.

#### Equals
Default query constraint for matching a field to a single value.

```ruby
q.where :field => value
# (alias) :field.eq => value
```

If you want to see if a particular field contains a specific Parse::Object (pointer), you can use the following:

```ruby
# find rows where the `field` contains a Parse "_User" pointer with the specified objectId.
q.where :field => Parse::Pointer.new("_User", "anObjectId")
# alias using subclass helper
q.where :field => Parse::User.pointer("anObjectId")
# alias using `:id` constraint. We will infer :user maps to class "_User" (Parse::User)
q.where :user.id => "anObjectId"
```

#### Less Than
Equivalent to the `$lt` Parse query operation. The alias `before` is provided for readability.

```ruby
q.where :field.lt => value
# or alias
q.where :field.before => value
# ex. :createdAt.before => DateTime.now
```

#### Less Than or Equal To
Equivalent to the `$lte` Parse query operation. The alias `on_or_before` is provided for readability.

```ruby
q.where :field.lte => value
# or alias
q.where :field.on_or_before => value
# ex. :createdAt.on_or_before => DateTime.now
```

#### Greater Than
Equivalent to the `$gt` Parse query operation. The alias `after` is provided for readability.

```ruby
q.where :field.gt => value
# or alias
q.where :field.after => value
# ex. :createdAt.after => DateTime.now
```

#### Greater Than or Equal
Equivalent to the `$gte` Parse query operation. The alias `on_or_after` is provided for readability.

```ruby
q.where :field.gte => value
# or alias
q.where :field.on_or_after => value
# ex. :createdAt.on_or_after => DateTime.now
```

#### Not Equal To
Equivalent to the `$ne` Parse query operation. Where a particular field is not equal to value.

```ruby
q.where :field.not => value
```

#### Nullability Check
Provides a mechanism using the equality operator to check for `(undefined)` values.

```ruby
q.where :field.null => true|false
```

#### Exists
Equivalent to the `#exists` Parse query operation. Checks whether a value is set for key. The difference between this operation and the nullability check is when using compound queries with location.

```ruby
q.where :field.exists => true|false
```

#### Contained In
Equivalent to the `$in` Parse query operation. Checks whether the value in the column field is contained in the set of values in the target array. If the field is an array data type, it checks whether at least one value in the field array is contained in the set of values in the target array.

```ruby
# ex. :score.in => [1,3,5,7,9]
q.where :field.in => [item1,item2,...]
# alias
q.where :field.contained_in => [item1,item2,...]
```

#### Not Contained In
Equivalent to the `$nin` Parse query operation. Checks whether the value in the column field is __not__ contained in the set of values in the target array. If the field is an array data type, it checks whether at least one value in the field array is __not__ contained in the set of values in the target array.

```ruby
# ex. :player_name.not_in => ['Jonathan', 'Dario', 'Shawn']
q.where :field.not_in => [item1,item2,...]
# alias
q.where :field.not_contained_in => [item1,item2,...]
```

#### Contains All
Equivalent to the `$all` Parse query operation. Checks whether the value in the column field contains all of the given values provided in the array. Note that the `field` column should be of type `Array` in your Parse class.

```ruby
 # ex. :array_key.all => [2,3,4]
 q.where :field.all => [item1, item2,...]
 # alias
 q.where :field.contains_all => [item1,item2,...]
```

#### Advanced Array Constraints
Parse Server doesn't natively support `$size` or exact array equality queries. Parse-Stack provides these via MongoDB aggregation pipelines.

##### Array Size
Match arrays by their length:

```ruby
# Exact size
q.where :tags.size => 2          # arrays with exactly 2 elements

# Size comparisons
q.where :tags.size => { gt: 3 }      # size > 3
q.where :tags.size => { gte: 2 }     # size >= 2
q.where :tags.size => { lt: 5 }      # size < 5
q.where :tags.size => { lte: 4 }     # size <= 4
q.where :tags.size => { ne: 0 }      # size != 0
q.where :tags.size => { gte: 2, lt: 10 }  # range: 2 <= size < 10

# Empty/non-empty shortcuts (index-friendly)
q.where :tags.arr_empty => true     # empty arrays (uses { field: [] })
q.where :tags.arr_empty => false    # non-empty arrays
q.where :tags.arr_nempty => true    # non-empty arrays (alias)

# Empty OR nil/missing - combines both checks
q.where :tags.empty_or_nil => true  # matches [] OR nil/missing
q.where :tags.empty_or_nil => false # matches non-empty arrays only

# Not empty - opposite of empty_or_nil
q.where :tags.not_empty => true     # must exist AND have elements
q.where :tags.not_empty => false    # matches [] OR nil/missing
```

**Performance Note:** `arr_empty` and `empty_or_nil` use index-friendly equality checks (`{ field: [] }`) instead of `$size: 0` for better MongoDB index utilization.

##### Array Equality (Order-Dependent)
Match arrays with exact elements in exact order:

```ruby
# Matches ["rock", "pop"] but NOT ["pop", "rock"]
q.where :tags.eq => ["rock", "pop"]
q.where :tags.eq_array => ["rock", "pop"]  # alias

# NOT equal (order-dependent)
q.where :tags.neq => ["rock", "pop"]  # excludes exact match only
```

##### Array Set Equality (Order-Independent)
Match arrays with same elements regardless of order:

```ruby
# Matches both ["rock", "pop"] AND ["pop", "rock"]
q.where :tags.set_equals => ["rock", "pop"]

# NOT set equal - excludes both orderings
q.where :tags.not_set_equals => ["rock", "pop"]
```

##### Pointer Arrays
All array constraints work with `has_many :through => :array` relations:

```ruby
# Find products with exactly these categories (any order)
Product.query(:categories.set_equals => [cat1, cat2])

# Find products with more than 3 categories
Product.query(:categories.size => { gt: 3 })
```

**Note:** Array constraints using aggregation pipelines require MongoDB 3.6+.

##### Readable Array Aliases
More readable aliases for common array operations:

```ruby
# Any/None - readable aliases for $in/$nin
q.where :tags.any => ["rock", "pop"]    # matches if contains any (same as :tags.in)
q.where :tags.none => ["jazz", "blues"] # matches if contains none (same as :tags.nin)

# Superset - readable alias for $all
q.where :tags.superset_of => ["rock", "pop"]  # must have all (same as :tags.all)
```

##### Element Match (Arrays of Objects)
Match array elements using multiple criteria with `$elemMatch`:

```ruby
# Find posts where comments has an element matching multiple conditions
q.where :comments.elem_match => { author: user, approved: true }

# Works with nested objects
q.where :items.elem_match => { product: "SKU123", quantity: { "$gt" => 5 } }
```

##### Subset Of
Match arrays that only contain elements from a given set:

```ruby
# Find items where tags only include elements from the allowed list
q.where :tags.subset_of => ["rock", "pop", "jazz", "classical"]
# ["rock", "pop"] matches, ["rock", "metal"] does NOT match
```

##### First/Last Element
Match based on the first or last element of an array:

```ruby
# First element equals value
q.where :tags.first => "featured"   # first tag is "featured"

# Last element equals value
q.where :tags.last => "archived"    # last tag is "archived"
```

#### Regex Matching
Equivalent to the `$regex` Parse query operation. Requires that a field value match a regular expression.

```ruby
# ex. :name.like => /Bob/i
q.where :field.like => /ruby_regex/i
# alias
q.where :field.regex => /abc/
```

#### Select
Equivalent to the `$select` Parse query operation. This matches a value for a key in the result of a different query.

```ruby
q.where :field.select => { key: "field", query: query }

# example
value = { key: 'city', query: Artist.where(:fan_count.gt => 50) }
q.where :hometown.select => value

# if the local field is the same name as the foreign table field, you can omit hash
# assumes key: 'city'
q.where :city.select => Artist.where(:fan_count.gt => 50)
```

#### Reject
Equivalent to the `$dontSelect` Parse query operation. Requires that a field's value not match a value for a key in the result of a different query.

```ruby
q.where :field.reject => { key: :other_field, query: query }

# example
value = { key: 'city', query: Artist.where(:fan_count.gt => 50) }
q.where :hometown.reject => value

# if the local field is the same name as the foreign table field, you can omit hash
# assumes key: 'city'
q.where :city.reject => Artist.where(:fan_count.gt => 50)
```

#### Matches Query
Equivalent to the `$inQuery` Parse query operation. Useful if you want to retrieve objects where a field contains an object that matches another query.

```ruby
q.where :field.matches => query
# ex. :post.matches => Post.where(:image.exists => true )
q.where :field.in_query => query # alias
```

#### Excludes Query
Equivalent to the `$notInQuery` Parse query operation. Useful if you want to retrieve objects where a field contains an object that does not match another query.

```ruby
q.where :field.excludes => query
# ex. :post.excludes => Post.where(:image.exists => true
q.where :field.not_in_query => query # alias
```

#### Matches Key in Query
Equivalent to using the `$select` Parse query operation for joining queries where fields from different classes match. This is useful for performing join-like operations where you want to find objects where a field's value equals another field's value from a different query.

```ruby
# Find users where user.company equals customer.company
customer_query = Customer.where(:active => true)
user_query = User.where(:company.matches_key => { key: "company", query: customer_query })

# If the local field has the same name as the remote field, you can omit the key
# assumes key: 'company'  
user_query = User.where(:company.matches_key => customer_query)

# Alias methods
q.where :field.matches_key_in_query => query
```

#### Does Not Match Key in Query  
Equivalent to using the `$dontSelect` Parse query operation for joining queries where fields from different classes do NOT match. This is the inverse of the "Matches Key in Query" constraint.

```ruby
# Find users where user.company does NOT equal customer.company
customer_query = Customer.where(:active => true)
user_query = User.where(:company.does_not_match_key => { key: "company", query: customer_query })

# If the local field has the same name as the remote field, you can omit the key
# assumes key: 'company'
user_query = User.where(:company.does_not_match_key => customer_query)

# Alias methods
q.where :field.does_not_match_key_in_query => query
```

#### Starts With
Equivalent to using the `$regex` Parse query operation with a prefix pattern. This is useful for autocomplete functionality and prefix matching.

```ruby
# Find users whose name starts with "John"
User.where(:name.starts_with => "John")
# Generates: "name": { "$regex": "^John", "$options": "i" }

# Case-insensitive prefix matching with special characters
User.where(:email.starts_with => "john.doe+")
# Automatically escapes special regex characters
```

#### Contains
Equivalent to using the `$regex` Parse query operation with a contains pattern. This is useful for case-insensitive text search within fields.

```ruby
# Find posts whose title contains "parse"
Post.where(:title.contains => "parse")
# Generates: "title": { "$regex": ".*parse.*", "$options": "i" }

# Search in descriptions
Post.where(:description.contains => "server setup")
# Automatically escapes special regex characters
```


#### Date Range
A convenience constraint that combines greater-than-or-equal and less-than-or-equal constraints for date/time range queries.

```ruby
# Find events between two dates
start_date = DateTime.new(2023, 1, 1)
end_date = DateTime.new(2023, 12, 31)
Event.where(:created_at.between_dates => [start_date, end_date])
# Generates: "created_at": { "$gte": start_date, "$lte": end_date }

# Works with Time objects too
Event.where(:updated_at.between_dates => [1.week.ago, Time.now])
```

#### Matches Object Id
Sometimes you want to find rows where a particular Parse object exists. You can do so by passing a the Parse::Object subclass or a Parse::Pointer. In some cases you may only have the "objectId" of the record you are looking for. For convenience, you can also use the `id` constraint. This will assume that the name of the field matches a particular Parse class you have defined. Assume the following:

```ruby
# where this Parse object equals the object in the column `field`.
q.where :field => Parse::Pointer("Field", "someObjectId")
# => "field":{"__type":"Pointer","className":"Field","objectId":"someObjectId"}}

# alias, shorthand when we infer `:field` maps to `Field` parse class.
q.where :field.id => "someObjectId"
# => "field":{"__type":"Pointer","className":"Field","objectId":"someObjectId"}}

```
It is always important to be thoughtful in naming column names in associations as
close to their foreign Parse class names. This enables more expressive syntax while reducing
code. The `id` also supports any object or pointer object. These are all equivalent:

```ruby
q.where :user    => User.pointer("xyx123")
q.where :user.id => "xyx123"
q.where :user.id => User.pointer("xyx123")
# All produce
# => "user":{"__type":"Pointer","className":"_User","objectId":"xyx123"}}
```

##### Additional Examples

```ruby

class Artist < Parse::Object
  # as described before
end

class Song < Parse::Object
  belongs_to :artist
end

artist = Artist.first # get any artist
artist_id = artist.id # ex. artist.id

# find all songs for this artist object
Song.all :artist => artist
```

In some cases, you do not have the Parse object, but you have its `objectId`. You can use the objectId in the query as follows:

```ruby
# shorthand if you are using convention. Will infer class `Artist`
Song.all :artist.id => artist_id

# other approaches, same result
Song.all :artist => Artist.pointer(artist_id)
Song.all :artist => Parse::Pointer.new("Artist", artist_id)

# "id" safely pointers and strings for supporting these types of API patterns
def find_songs(artist)
  Song.all :artist.id => artist
end

# all ok
songs = find_songs artist_id # by a string ObjectId
songs = find_songs artist # or by an object or pointer
songs = find_songs Artist.pointer(artist_id)

```

### [Geo Queries](https://neurosynq.github.io/parse-stack-next/Parse/Constraint/NearSphereQueryConstraint.html)
Equivalent to the `$nearSphere` Parse query operation. This is only applicable if the field is of type `GeoPoint`. This will query Parse and return a list of results ordered by distance with the nearest object being first.

```ruby
q.where :field.near => geopoint

# example
geopoint = Parse::GeoPoint.new(30.0, -20.0)
PlaceObject.all :location.near => geopoint
```

#### Max Distance Constraint
If you wish to constrain the geospatial query to a maximum number of __miles__, you can utilize the `max_miles` method on a `Parse::GeoPoint` object. This is equivalent to the `$maxDistanceInMiles` constraint used with `$nearSphere`.

```ruby
q.where :field.near => geopoint.max_miles(distance)
# or provide a triplet includes max miles constraint
q.where :field.near => [lat, lng, miles]

# example
geopoint = Parse::GeoPoint.new(30.0, -20.0)
PlaceObject.all :location.near => geopoint.max_miles(10)
```

We will support `$maxDistanceInKilometers` (for kms) and `$maxDistanceInRadians` (for radian angle) in the future.

#### [Bounding Box Constraint](https://neurosynq.github.io/parse-stack-next/Parse/Constraint/WithinGeoBoxQueryConstraint.html)
Equivalent to the `$within` Parse query operation and `$box` geopoint constraint. The rectangular bounding box is defined by a southwest point as the first parameter, followed by the a northeast point. Please note that Geo box queries that cross the international date lines are not currently supported by Parse.

```ruby
# GeoPoint bounding box
q.where :field.within_box => [soutwestGeoPoint, northeastGeoPoint]

# example
sw = Parse::GeoPoint.new 32.82, -117.23 # San Diego
ne = Parse::GeoPoint.new 36.12, -115.31 # Las Vegas

# get all PlaceObjects inside this bounding box
PlaceObject.all :location.within_box => [sw,ne]
```

#### [Polygon Area Constraint](https://neurosynq.github.io/parse-stack-next/Parse/Constraint/WithinPolygonQueryConstraint.html)
Equivalent to the `$geoWithin` Parse query operation and `$polygon` geopoint constraint. The polygon area is described by a list of `Parse::GeoPoint` objects and should contain 3 or more points. This feature is only available in Parse-Server version 2.4.2 and later.

```ruby
 # As many points as you want, minimum 3
 q.where :field.within_polygon => [geopoint1, geopoint2, geopoint3]

 # Polygon for the Bermuda Triangle
 bermuda  = Parse::GeoPoint.new 32.3078000,-64.7504999 # Bermuda
 miami    = Parse::GeoPoint.new 25.7823198,-80.2660226 # Miami, FL
 san_juan = Parse::GeoPoint.new 18.3848232,-66.0933608 # San Juan, PR

 # get all sunken ships inside the Bermuda Triangle
 SunkenShip.all :location.within_polygon => [bermuda, san_juan, miami]
```

#### [Full Text Search Constraint](https://neurosynq.github.io/parse-stack-next/Parse/Constraint/FullTextSearchQueryConstraint.html)
Equivalent to the `$text` Parse query operation and `$search` parameter constraint for efficient search capabilities. By creating indexes on one or more columns your strings are turned into tokens for full text search functionality. The `$search` key can take any number of parameters in hash form. *Requires Parse Server 2.5.0 or later*

```ruby
 # Do a full text search on "anthony"
 q.where :field.text_search => "anthony"

 # perform advance searches
 q.where :field.text_search => {term: "anthony", case_insensitive: true}
 # equivalent
 q.where :field.text_search => {:$term => "anthony", :$caseInsensitive => true}
```

You may use the following keys for the parameters clause.

| Parameter | Use |
| :--- | :----- |
| `$term`               | Specify a field to search (**Required**)|
| `$language`           | Determines the list of stop words and the rules for tokenizer.|
| `$caseSensitive`      | Enable or disable case sensitive search.|
| `$diacriticSensitive` | Enable or disable diacritic sensitive search.|

For additional details, please see [Query on String Values](https://docs.parseplatform.org/rest/guide/#queries-on-string-values).

### Relational Queries
Equivalent to the `$relatedTo` Parse query operation. If you want to retrieve objects that are members of a `Relation` field in your Parse class.

```ruby
q.where :field.related_to => pointer
q.where :field.rel => pointer # alias
```

In the example below, imagine you have a `Post` collection that has a Parse relation column `likes`
which has the set of users who have liked a certain post. You would use the `Parse::Users` class to query
against the `post` record of interest against the `likes` column of the `Post` collection.

```ruby
# assume Post class definition
class Post < Parse::Object
  # Parse relation to Parse::User records who've liked a post
  has_many :likes, through: :relation, as: :user
end

post = Post.first
# find all Users who have liked this post object,
# where 'likes' is a column on the Post class.
users = Parse::User.all :likes.rel => post

# or use the relation accessor declared in Post
users = post.likes.all # same result

# or find posts that a certain user has liked
user = Parse::User.first
# likes is a Parse relation in the Post collection that contains User records
liked_posts_by_user = Post.all :likes => user
```

### Compound Queries
Equivalent to the `$or` Parse query operation. This is useful if you want to find objects that match several queries. We overload the `|` operator in order to have a clean syntax for joining these `or` operations.

```ruby
or_query = query1 | query2 | query3 ...

# ex. where wins > 150 || wins < 5
query = Player.where(:wins.gt => 150) | Player.where(:wins.lt => 5)
results = query.results
```

If you do not prefer the syntax you may use the `or_where` method to chain multiple `Parse::Query` instances.

```ruby
query = Player.where(:wins.gt => 150)
query.or_where(:wins.lt => 5)
# where wins > 150 || wins < 5
results = query.results
```

### Query Composition and Cloning

Parse-Stack provides additional methods for composing and cloning queries, making it easier to build complex queries programmatically.

#### Query Cloning
Create independent copies of query objects for separate modifications:

```ruby
base_query = Song.where(:genre => "rock")
query1 = base_query.clone.where(:year.gt => 2000)  # Rock songs after 2000
query2 = base_query.clone.where(:duration.lt => 180) # Short rock songs

# Original query remains unchanged
base_results = base_query.results
newer_rock = query1.results
short_rock = query2.results
```

#### Combining Multiple Queries
Combine multiple independent queries using class methods for cleaner composition:

```ruby
# OR logic - combine multiple queries with OR
popular_songs = Song.where(:play_count.gt => 1000)
recent_songs = Song.where(:created_at.gt => 1.month.ago)
trending_songs = Song.where(:trending => true)

# Any song that is popular OR recent OR trending
combined_or = Parse::Query.or(popular_songs, recent_songs, trending_songs)
results = combined_or.results

# AND logic - combine multiple queries with AND  
rock_songs = Song.where(:genre => "rock")
long_songs = Song.where(:duration.gt => 300)
popular_songs = Song.where(:play_count.gt => 500)

# Songs that are rock AND long AND popular
combined_and = Parse::Query.and(rock_songs, long_songs, popular_songs)
results = combined_and.results
```

These composition methods work seamlessly with aggregation pipelines and all other query operations.

## Query Scopes
This feature is a small subset of the [ActiveRecord named scopes](http://guides.rubyonrails.org/active_record_querying.html#scopes) feature. Scoping allows you to specify commonly-used queries which can be referenced as class method calls and are chainable with other scopes. You can use every `Parse::Query` method previously covered such as `where`, `includes` and `limit`.

```ruby

class Article < Parse::Object
  property :published, :boolean
  scope :published, -> { query(published: true) }
end
```

This is the same as defining your own class method for the query.

```ruby
class Article < Parse::Object
  def self.published
    query(published: true)
  end
end
```

You can also chain scopes and pass parameters. In addition, boolean and enumerated properties have automatically generated scopes for you to use.

```ruby

class Article < Parse::Object
  scope :published, -> { query(published: true) }

  property :comment_count, :integer
  property :category
  property :approved, :boolean

  scope :published_and_commented, -> { published.where :comment_count.gt => 0 }
  scope :popular_topics, ->(name) { published_and_commented.where category: name }
end

# simple scope
Article.published # => where published is true

# chained scope
Article.published_and_commented # published is true and comment_count > 0

# scope with parameters
Article.popular_topic("music") # => popular music articles
# equivalent: where(published: true, :comment_count.gt => 0, category: name)

# automatically generated scope
Article.approved(category: "tour") # => where approved: true, category: 'tour'

```

If you would like to turn off automatic scope generation for property types, set the option `:scope` to false when declaring the property.

## Calling Cloud Code Functions
You can call on your defined Cloud Code functions using the `call_function()` method. The result will be `nil` in case of errors or the value of the `result` field in the Parse response.

### Basic Usage

```ruby
params = {}
# use the explicit name of the function
result = Parse.call_function 'functionName', params

# to get the raw Response object
response = Parse.call_function 'functionName', params, raw: true
response.result unless response.error?
```

### Authenticated Cloud Function Calls

You can call cloud functions with user session tokens for authenticated requests:

```ruby
# Using session token option
user = Parse::User.login("username", "password")
result = Parse.call_function('functionName', params, session_token: user.session_token)

# Using convenience method
result = Parse.call_function_with_session('functionName', params, user.session_token)

# Using master key for administrative operations
result = Parse.call_function('functionName', params, master_key: true)
```

### Advanced Options

```ruby
# Using a specific client connection
result = Parse.call_function('functionName', params, client: :my_client)

# Combining options
result = Parse.call_function('functionName', params, 
  session_token: user.session_token,
  raw: true,
  client: :default
)
```

## Calling Background Jobs
You can trigger background jobs that you have configured in your Parse application as follows.

### Basic Usage

```ruby
params = {}
# use explicit name of the job
result = Parse.trigger_job :myJobName, params

# to get the raw Response object
response = Parse.trigger_job :myJobName, params, raw: true
response.result unless response.error?
```

### Authenticated Job Triggers

Background jobs can also be triggered with authentication:

```ruby
# Using session token option
user = Parse::User.login("username", "password")
result = Parse.trigger_job('myJobName', params, session_token: user.session_token)

# Using convenience method
result = Parse.trigger_job_with_session('myJobName', params, user.session_token)

# Using master key for administrative operations
result = Parse.trigger_job('myJobName', params, master_key: true)
```

## Active Model Callbacks
All `Parse::Object` subclasses extend [`ActiveModel::Callbacks`](http://api.rubyonrails.org/classes/ActiveModel/Callbacks.html) for `#save` and `#destroy` operations. You can setup internal hooks for `before` and `after`.

```ruby

class Song < Parse::Object
	# ex. before save callback
	before_save do
		self.name = self.name.titleize
    # make sure global acls are set
		acl.everyone(true, false) if new?
	end

  after_create do
    puts "New object successfully saved."
  end

end

song = Song.new name: "my title"
puts song.name # 'my title'
song.save # runs :save callbacks
puts song.name # 'My Title'

```

There are also a special `:create` callback. A `before_create` will be called whenever a unsaved object will be saved, and `after_create` will be called when a previously unsaved object successfully saved for the first time.

### Callback Halting
ActiveModel callbacks can now halt operations by returning `false`. When a `before_save` or `before_create` callback returns `false`, the save operation will be prevented:

```ruby
class Song < Parse::Object
  before_save :validate_song

  private

  def validate_song
    if name.blank?
      puts "Song name cannot be blank"
      return false  # This will halt the save operation
    end
    true
  end
end
```

### Validation Context (on: :create / on: :update)

Parse Stack supports ActiveRecord-style validation context for `before_validation`, `after_validation`, and `around_validation` callbacks. This allows you to run callbacks only when creating or updating objects:

```ruby
class Project < Parse::Object
  property :name, :string, required: true
  property :status, :string, required: true
  property :owner, :pointer
  property :completed_at, :date

  # Set defaults only when creating new objects
  before_validation :set_defaults, on: :create

  # Validate completion date only on updates
  validates :completed_at, presence: true, on: :update, if: -> { status == "completed" }

  def set_defaults
    self.status ||= "pending"
    self.owner ||= current_team_owner
  end
end
```

**Why use `before_validation` instead of `before_create`?**

The callback order is: `before_validation` → validations → `before_save` → `before_create` → save

If you need to set default values for required fields, `before_create` runs *after* validations, so the validation will fail before your defaults are applied. Use `before_validation on: :create` instead:

```ruby
class Task < Parse::Object
  property :name, :string, required: true
  property :priority, :integer, required: true

  # This WON'T work - before_create runs AFTER validation
  before_create do
    self.priority ||= 1  # Too late! Validation already failed
  end

  # This WILL work - before_validation runs BEFORE validation
  before_validation :set_priority_default, on: :create

  def set_priority_default
    self.priority ||= 1  # Sets default before validation runs
  end
end

# Now this works:
task = Task.new(name: "My Task")
task.save  # priority is set to 1 before validation
```

### Enhanced Change Tracking
Parse objects now support both standard ActiveModel dirty tracking and enhanced change tracking for after_save hooks:

```ruby
class Product < Parse::Object
  property :name, :string
  property :price, :float
  
  after_save :send_price_alert
  
  def send_price_alert
    # Use *_was_changed? methods in after_save hooks
    if price_was_changed? && price_was < price
      AlertService.send("Price increased from $#{price_was} to $#{price}")
    end
  end
end
```

The `*_was_changed?` methods work correctly in after_save contexts by using `previous_changes`, while standard `*_changed?` methods maintain their normal ActiveModel behavior.

## Schema Upgrades and Migrations
You may change your local Parse ruby classes by adding new properties. To easily propagate the changes to your Parse Server application (MongoDB), you can call `auto_upgrade!` on the class to perform an non-destructive additive schema change. This will create the new columns in Parse for the properties you have defined in your models. Parse Stack will calculate the changes and only modify the tables which need new columns to be added.  This feature does require the use of the master key when configuring the client. *It will NOT destroy columns or data.*

```ruby
  # auto_upgrade! requires use of master key
  # upgrade the a class individually
  Song.auto_upgrade!

  # upgrade all classes for the default client connection.
  Parse.auto_upgrade!

```

### Inspecting Schema Differences

`Parse::Schema.diff(Klass)` returns a `SchemaDiff` describing how your local
model and the server schema differ:

- `#missing_on_server` — fields declared locally but absent on the server (what `auto_upgrade!` would add).
- `#missing_locally` — columns present on the server but not declared in your model (e.g. dashboard-added fields). Informational only; never removed.
- `#type_mismatches` — fields whose local type differs from the server's.
- `#in_sync?` — `true` only when all three are empty (strict, **bidirectional** equality).
- `#server_covers_local?` — `true` when every field your model declares is present on the server (`missing_on_server.empty? && type_mismatches.empty?`). One-way: server-only columns are ignored.
- `#summary` — a human-readable report of the above.

```ruby
diff = Parse::Schema.diff(Post)
puts diff.summary
diff.missing_on_server   # => { published: :boolean }
diff.missing_locally     # => { "legacyFlag" => :boolean }
```

**CI convergence check.** Do **not** gate CI on `in_sync?` — it is
bidirectional and returns `false` whenever the server has extra columns (a
dashboard-added field, or a column owned by another service), even right after
a successful `auto_upgrade!`. Gate on the one-way check instead:

```ruby
diff = Parse::Schema.diff(Post)
unless diff.server_covers_local?
  abort "Post schema not converged:\n#{diff.summary}"
end
```

Server-only columns (`missing_locally`) are expected and safe — `auto_upgrade!`
is purely additive and never drops them.

## Push Notifications
Push notifications are implemented through the `Parse::Push` class. To send push notifications through the REST API, you must enable `REST push enabled?` option in the `Push Notification Settings` section of the `Settings` page in your Parse application. Push notifications targeting uses the Installation Parse class to determine which devices receive the notification. You can provide any query constraint, similar to using `Parse::Query`, in order to target the specific set of devices you want given the columns you have configured in your `Installation` class.

### Builder Pattern API

The recommended way to send push notifications is using the fluent builder pattern:

```ruby
# Simple channel push
Parse::Push.new
  .to_channel("news")
  .with_alert("Breaking news!")
  .send!

# Rich push with all options
Parse::Push.new
  .to_channels("sports", "alerts")
  .with_title("Game Alert")
  .with_body("Your workspace is playing now!")
  .with_badge(1)
  .with_sound("alert.caf")
  .with_data(game_id: "12345", action: "open_game")
  .schedule(1.hour.from_now)
  .expires_in(3600)
  .send!

# Query-based targeting
Parse::Push.new
  .to_query { |q| q.where(device_type: "ios", :app_version.gte => "2.0") }
  .with_alert("iOS 2.0+ users only")
  .send!

# Class method shortcuts
Parse::Push.to_channel("alerts").with_alert("Important!").send!
```

### Silent Push (iOS Background Notifications)

Send background notifications that wake the app without displaying an alert:

```ruby
Parse::Push.new
  .to_channel("sync")
  .silent!
  .with_data(action: "refresh", resource: "users")
  .send!
```

### Rich Push (iOS Notification Extensions)

Send rich notifications with images, categories, and mutable content:

```ruby
Parse::Push.new
  .to_channel("media")
  .with_title("New Photo")
  .with_body("Check out this photo!")
  .with_image("https://example.com/photo.jpg")  # Auto-enables mutable-content
  .with_category("PHOTO_ACTIONS")
  .send!
```

### Localization

Send language-specific messages based on device locale:

```ruby
Parse::Push.new
  .to_channel("international")
  .with_alert("Default message")
  .with_localized_alerts(
    en: "Hello!",
    fr: "Bonjour!",
    es: "Hola!",
    de: "Hallo!"
  )
  .with_localized_titles(
    en: "Welcome",
    fr: "Bienvenue"
  )
  .send!
```

### Badge Management

```ruby
# Increment badge by 1
Parse::Push.new.to_channel("messages").increment_badge.with_alert("New!").send!

# Increment by custom amount
Parse::Push.new.to_channel("bulk").increment_badge(5).with_alert("5 new!").send!

# Clear badge
Parse::Push.new.to_channel("read").clear_badge.silent!.send!
```

### Saved Audiences

Target pre-defined audiences stored in the `_Audience` collection:

```ruby
# Target by audience name
Parse::Push.new
  .to_audience("VIP Users")
  .with_alert("Exclusive offer!")
  .send!

# Manage audiences
audience = Parse::Audience.new(name: "Premium iOS", query: { "deviceType" => "ios", "premium" => true })
audience.save

Parse::Audience.find_by_name("VIP Users")
Parse::Audience.installation_count("VIP Users")
```

### Push Status Tracking

Track push delivery status via the `_PushStatus` collection:

```ruby
status = Parse::PushStatus.find(push_id)

status.succeeded?      # => true
status.num_sent        # => 1250
status.num_failed      # => 12
status.success_rate    # => 99.05
status.sent_per_type   # => {"ios" => 800, "android" => 450}

# Query scopes
Parse::PushStatus.succeeded.all
Parse::PushStatus.failed.all
Parse::PushStatus.recent.limit(10)
```

### Installation Channel Management

Manage channel subscriptions on installations:

```ruby
installation = Parse::Installation.first

# Subscribe/unsubscribe
installation.subscribe("news", "weather")
installation.unsubscribe("sports")
installation.subscribed_to?("news")  # => true

# Query channels
Parse::Installation.all_channels              # All unique channels
Parse::Installation.subscribers("news").all   # Installations in channel
Parse::Installation.subscribers_count("news") # Count subscribers
```

### Traditional API

The traditional API is still supported:

```ruby
push = Parse::Push.new
push.send("Hello World!")  # to everyone

# Channel push
push = Parse::Push.new
push.channels = ["mychannel"]
push.send "You are subscribed!"

# Advanced targeting
push = Parse::Push.new
push.where :device_type.in => ['ios','android'], :location.near => some_geopoint
push.alert = "Hello World!"
push.sound = "soundfile.caf"
push.data = { uri: "app://deep_link_path" }
push.send
```

## Analytics

`Parse.track_event(name, dimensions: {}, **opts)` (v5.0+) is the top-level shortcut for sending events to Parse Server's `POST /events/<name>` endpoint. The dimensions hash MUST be passed via the `dimensions:` keyword — under Ruby 3 kwarg separation, loose symbol arguments are absorbed by `**opts` and never reach the POST body. The event name is validated against `[\w\-\.]` at the SDK boundary so the value cannot escape the `/events/` path segment.

```ruby
# Server-side, master-key in process
Parse.track_event("post_viewed", dimensions: { source: "feed", workspace: "w1" })

# No dimensions
Parse.track_event("AppOpened")

# Client-mode, scoped to a session
Parse.track_event("search",
  dimensions: { query: "tabby cats" },
  session_token: user.session_token, use_master_key: false,
)
```

Parse Server's default `analyticsAdapter` is a no-op: events POST'd are accepted (HTTP 200) but are not persisted and cannot be read back through the SDK. Operators who wire in a custom adapter decide what (if anything) to do with each event. The legacy parse.com eight-dimension cap does NOT apply to Parse Server out of the box. If you need to query analytics events from the SDK, persist them to a regular `Parse::Object` subclass instead. The underlying request is a blocking HTTP POST — wrap in a thread or background job if you do not want it on the request path.

## AI Agent Integration

Parse Stack includes first-class support for AI/LLM agents to interact with your Parse data through a standardized tool interface, including an MCP 2025-06-18 Streamable HTTP transport. This enables natural language querying and intelligent data exploration with rate limiting, prompt-injection protection, and per-agent ACL scoping.

### Basic Usage

```ruby
require 'parse/stack'

# Create an agent
agent = Parse::Agent.new

# Execute tools directly
result = agent.execute(:get_all_schemas)
result = agent.execute(:query_class, class_name: "Song", limit: 10)
result = agent.execute(:count_objects, class_name: "Song", where: { plays: { "$gte" => 1000 } })

# High-level aggregation helpers (v4.2.1) — no pipeline authoring needed
result = agent.execute(:group_by, class_name: "Song", field: "genre",
                       sort: "value_desc", limit: 10)
result = agent.execute(:group_by_date, class_name: "Song", field: "createdAt",
                       interval: "day", timezone: "America/New_York")
result = agent.execute(:distinct, class_name: "Song", field: "artist")

# Ask natural language questions (requires LLM endpoint)
response = agent.ask("How many songs have more than 1000 plays?")
puts response[:answer]
```

### Permission Levels

Agents support three permission levels:

```ruby
# Readonly (default) - queries only
agent = Parse::Agent.new(permissions: :readonly)

# Write - adds create/update
agent = Parse::Agent.new(permissions: :write)

# Admin - full access including delete
agent = Parse::Agent.new(permissions: :admin)
```

### Client Mode (v5.0)

When `Parse::Agent` is constructed against a `Parse::Client` that carries no master key and a non-empty `session_token:`, it switches to *client mode*. The dispatch ceiling is a small allowlist of session-token REST tools (`list_tools`, `get_object`, `get_objects`, `query_class`, `count_objects`, `get_sample_objects`, and — gated by `allow_mutations:` — `create_object`, `update_object`, `delete_object`). Aggregate, atlas-search, schema-introspection, explain, and generic `call_method` are refused because they require either the master key or a direct MongoDB connection.

```ruby
# An unprivileged client + a user's session token
Parse.setup(server_url: "...", application_id: "...", api_key: "...")  # no master_key
agent = Parse::Agent.new(session_token: user.session_token)

agent.client_mode?      # => true
agent.allow_mutations?  # => false (default in client mode)

# Read tools work; Parse Server enforces ACL + CLP + protectedFields natively.
agent.execute(:query_class, class_name: "Post", limit: 10)

# Mutations are opt-in per agent:
writer = Parse::Agent.new(session_token: user.session_token, allow_mutations: true)
writer.execute(:create_object, class_name: "Post", fields: { title: "Hi" })
```

Custom tools default to master-key-only. Mark a registered tool eligible for client mode with `Parse::Agent::Tools.register(:my_tool, ..., client_safe: true)`; the handler is then responsible for routing through `agent.client` with `agent.session_token` (never the master key). Sub-agents cannot widen the parent's `allow_mutations:` gate.

### Agent Metadata DSL

Annotate your models with agent-friendly metadata:

```ruby
class Song < Parse::Object
  agent_visible  # Include in agent schema listings
  agent_description "A music track in the catalog"

  property :title, :string, _description: "The song title"
  property :plays, :integer, _description: "Total play count"
  property :archived, :boolean

  # Per-class "valid state" predicate applied by default on every read tool
  # (query_class, count_objects, aggregate). Opt out per-call with
  # `apply_canonical_filter: false`.
  agent_canonical_filter "archived" => { "$ne" => true }

  # Expose methods with permission levels
  agent_readonly :find_popular, "Find songs with high play counts"
  agent_write :increment_plays, "Increment the play counter"

  def self.find_popular(min_plays: 1000)
    query(:plays.gte => min_plays).limit(100)
  end
end
```

### MCP Server

Parse Stack exposes the Model Context Protocol (MCP) so external AI agents — Claude Desktop, Cursor, Continue.dev, and any MCP-compatible client — can query schemas, run aggregations, call tools, and read prompts over a standard JSON-RPC interface. Three deployment modes are available:

- **Standalone HTTP server** — a WEBrick process for dedicated MCP deployments.
- **Rack-mountable adapter** — embed inside an existing Sinatra or Rails application behind your own auth gate.
- **Direct in-process dispatcher** — a pure function for custom transports and unit-testable handlers.

See [`docs/mcp_guide.md`](docs/mcp_guide.md) for the complete guide covering authentication, custom tool/prompt registration, rate limiting in per-request topologies, `ActiveSupport::Notifications` instrumentation, SSE progress streaming, and the security model.

**Standalone server (dual-gated for safety):**

```bash
# Step 1: Set environment variable
export PARSE_MCP_ENABLED=true
```

```ruby
# Step 2: Connect to your Parse Server FIRST — the agent's tools query it,
# so without an active client every tool call raises a connection error.
Parse.setup(
  server_url:     ENV["PARSE_SERVER_URL"],   # e.g. "https://api.example.com/parse"
  application_id: ENV["PARSE_APP_ID"],
  api_key:        ENV["PARSE_REST_API_KEY"],
  master_key:     ENV["PARSE_MASTER_KEY"],    # master-key agent (full read access)
)

# Then enable and start the MCP server.
Parse.mcp_server_enabled = true
Parse::Agent.enable_mcp!(port: 3001)
Parse::Agent::MCPServer.run(api_key: ENV["MCP_API_KEY"])
```

Both the environment variable AND the code flag must be set. This prevents accidental enablement in production.

**Embedded in Rails / Sinatra:**

```ruby
# config/routes.rb
mount Parse::Agent.rack_app { |env|
  token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
  user  = MyAuth.verify!(token)  # raises Parse::Agent::Unauthorized on bad token
  Parse::Agent.new(permissions: :readonly, session_token: user.session_token)
}, at: "/mcp"
```

The `agent_factory` block runs per request — wire it to your existing JWT, OAuth, or session-token authentication. Raising `Parse::Agent::Unauthorized` produces a sanitized 401; any other exception becomes a sanitized 500. The `enable_mcp!` and `mcp_server_enabled` prerequisites apply only to the standalone server, not to embedded mode.

**Custom transports:** `Parse::Agent::MCPDispatcher.call(body:, agent:)` is a pure function returning `{status:, body:}`. Use it for stdio transports, in-process tests, or your own protocol envelope.

### Security

> **Master-key default (read this first).** `Parse::Agent.new` without a
> `session_token:` runs every tool call with the application **master key**.
> Master-key mode **bypasses Parse ACLs and Class-Level Permissions** — the
> only safety net is the class-, field-, and pipeline-level layer:
> `agent_visible` / `agent_hidden`, `agent_fields`, `agent_canonical_filter`,
> `tenant_id`, and `PipelineValidator`. Per-row enforcement is **not**
> applied. The first master-key construction in a process emits a one-time
> `[Parse::Agent:SECURITY]` banner to stderr; silence it with
> `Parse::Agent.suppress_master_key_warning = true` for intentional
> global-MCP deployments. For per-user enforcement, pass a session token
> (the `Parse::Agent.rack_app` factory pattern above is the recommended
> wiring):
>
> ```ruby
> agent = Parse::Agent.new(session_token: user.session_token)
> ```

Built-in protections:
- **Rate limiting**: 60 requests/minute default
- **Pipeline validation**: Blocks dangerous aggregation stages (`$out`, `$merge`, `$function`)
- **Permission levels**: Restrict agent capabilities (readonly/write/admin)
- **Class/field allowlist**: `agent_visible` / `agent_hidden` / `agent_fields` per model
- **Per-agent class allowlist** (v4.3.0): `Parse::Agent.new(classes: { only: [Ticket, Customer] })` narrows a single agent instance to a subset of classes, enforced at six dispatch sites (top-level, include resolution, `$lookup`, `$inQuery`/`$select`, post-fetch redaction, group-by). Composes with the global `agent_hidden` registry — `only:` cannot re-enable a globally hidden class.
- **Master-key-except scope** (v4.3.0): `agent_hidden(except: :master_key)` permits master-key agents (internal admin / dev tooling) to address a class while still refusing session-bound (user-facing) agents.
- **Credential-column floor**: `sessionToken`, `_hashed_password`, `_auth_data*`, `_rperm`/`_wperm`, etc. stripped from every response regardless of class visibility. Applied at the post-fetch walker so a deliberate `agent_unhidden` cannot leak credentials.
- **Built-in hidden defaults** (v4.3.0): `Parse::Product` and `Parse::Session` are `agent_hidden` by default. Call `Parse::Product.agent_unhidden` or `Parse::Session.agent_hidden(except: :master_key)` to opt back in.
- **Canonical filter**: per-class `agent_canonical_filter` prepended to every read
- **Tenant scoping**: `tenant_id:` constructor kwarg applied to all queries

See [`docs/mcp_guide.md`](docs/mcp_guide.md) for the full reference — per-agent filter composition rules, audit-payload keys (`:classes_only`, `:denial_kind`, etc.), and the dual-axis class hiding model.

Configure LLM endpoint via environment:
```bash
export LLM_ENDPOINT="http://127.0.0.1:1234/v1"
export LLM_MODEL="qwen2.5-7b-instruct"
```

### Multi-turn Conversations

Agents support multi-turn conversations with context maintained across questions:

```ruby
agent = Parse::Agent.new

# Initial question
agent.ask("How many users are there?")

# Follow-up questions maintain context
agent.ask_followup("What about admins?")
agent.ask_followup("Show me the most recent 5")

# Clear history to start fresh
agent.clear_conversation!
```

### Token Usage & Cost Estimation

Track LLM token usage and estimate costs:

```ruby
agent = Parse::Agent.new(pricing: { prompt: 0.01, completion: 0.03 })

agent.ask("How many users?")
agent.ask_followup("What about admins?")

# Check token usage
puts agent.token_usage
# => { prompt_tokens: 450, completion_tokens: 120, total_tokens: 570 }

# Get estimated cost
puts agent.estimated_cost  # => 0.0234

# Reset counters
agent.reset_token_counts!
```

### Callbacks/Hooks

Register callbacks for debugging, logging, and custom behavior:

```ruby
agent = Parse::Agent.new

# Before tool execution
agent.on_tool_call { |tool, args| puts "Calling: #{tool}" }

# After tool execution
agent.on_tool_result { |tool, args, result| log_result(tool, result) }

# On any error
agent.on_error { |error, context| notify_slack(error) }

# After LLM response
agent.on_llm_response { |response| log_llm_usage(response) }
```

### Streaming Support

Stream responses as they arrive from the LLM:

```ruby
agent.ask_streaming("Analyze user growth trends") do |chunk|
  print chunk
end
```

**Important Limitation:** Streaming mode does **not** support tool calls. The agent cannot query the database or perform Parse operations while streaming. Use `ask` for database queries:

```ruby
# DON'T: This won't query the database
agent.ask_streaming("How many users?") { |c| print c }

# DO: Use ask for database queries
result = agent.ask("How many users?")
```

### Conversation Export/Import

Serialize and restore conversation state:

```ruby
agent = Parse::Agent.new
agent.ask("How many users?")
agent.ask_followup("What about admins?")

# Export state
state = agent.export_conversation
File.write("conversation.json", state)

# Later, restore in a new session
new_agent = Parse::Agent.new
new_agent.import_conversation(File.read("conversation.json"))
new_agent.ask_followup("Show me the most recent ones")
```

### Configuration Options

Additional agent configuration:

```ruby
# Custom system prompt
agent = Parse::Agent.new(system_prompt: "You are a music database expert...")

# Or append to the default prompt
agent = Parse::Agent.new(system_prompt_suffix: "Focus on performance data.")

# Configure operation log size (circular buffer, default: 1000)
agent = Parse::Agent.new(max_log_size: 5000)

# Access debugging info
agent.last_request   # Last LLM request sent
agent.last_response  # Last LLM response received
agent.operation_log  # Recent operations
```

## Cloud Code Webhooks
Parse Parse allows you to receive Cloud Code webhooks on your own hosted server. The `Parse::Webhooks` class is a lightweight Rack application that routes incoming Cloud Code webhook requests and payloads to locally registered handlers. The payloads are `Parse::Webhooks::Payload` type of objects that represent that data that Parse sends webhook handlers. You can register any of the Cloud Code webhook trigger hooks (`beforeSave`, `afterSave`, `beforeDelete`, `afterDelete`) and function hooks.

### Cloud Code Functions
You can use the `route()` method to register handler blocks. The last value returned by the block will be returned back to the client in a success response. If `error!(value)` is called inside the block, we will return the correct Parse error response with the value you provided.

```ruby
# Register handling the 'helloWorld' function.
Parse::Webhooks.route(:function, :helloWorld) do
  #  use the Parse::Webhooks::Payload instance methods in this block
  name = params['name'].to_s #function params
  puts "CloudCode Webhook helloWorld called in Ruby!"
  # will return proper error response
  # error!("Missing argument 'name'.") unless name.present?

  name.present? ? "Hello #{name}!" : "Hello World!"
end

# Advanced: you can register handlers through classes if you prefer
# Parse::Webhooks.route :function, :myFunc, MyClass.method(:my_func)
```

If you have registered this webhook (see instructions below), you should be able to test it out by running curl using the command below.

```bash
curl -X POST \
  -H "X-Parse-Application-Id: ${APPLICATION_ID}" \
  -H "X-Parse-REST-API-Key: ${REST_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{}' \
  https://localhost:2337/parse/functions/helloWorld
```

If you are creating `Parse::Object` subclasses, you may also register them there to keep common code and functionality centralized.

```ruby
class Song < Parse::Object

  webhook :function, :mySongFunction do
    the_user = user # available if a Parse user made the call
    str = params["str"]

    # ... get the list of matching songs the user has access to.
    results = Songs.all(:name.like => /#{str}/, :session => the_user)
    # Helper method for logging
    wlog "Found #{results.count} for #{the_user.username}"

    results
  end

end

```

You may optionally, register these functions outside of classes (recommended).

```ruby
Parse::Webhooks.route :function, :mySongFunction do
  # .. do stuff ..
  str = params["str"]
  results = Songs.all(:name.like => /#{str}/, :session => user)
  results
end
```

### Cloud Code Triggers
You can register webhooks to handle the different object triggers: `:before_save`, `:after_save`, `:before_delete` and `:after_delete`. The `payload` object, which is an instance of `Parse::Webhooks::Payload`, contains several properties that represent the payload. One of the most important ones is `parse_object`, which will provide you with the instance of your specific Parse object.

The `parse_object` handed to your handler is the **full object as Parse Server sent it** — `createdAt`/`updatedAt`, `ACL`, and internal fields all survive (only live credentials — session tokens and password hashes — are stripped; `Parse::User` additionally protects `authData` on `payload.user`). Both `:before_save` and `:after_save` objects carry **dirty tracking** of what changed (`name_changed?`, `changes`), and `Parse::Object#existed?` / `#new?` are reliable inside `:after_save`. See [Trigger object state](#trigger-object-state) below.

```ruby
  # recommended way
  class Artist < Parse::Object
    # ... properties ...

    # setup after save for Artist
    webhook :after_save do
      puts "User: #{user.username}" if user.present? # Parse::User
      artist = parse_object # Artist
      # no need for return in after save
    end

  end

  # or the explicit way
  Parse::Webhooks.route :after_save, :Artist do
    puts "User: #{user.username}" if user.present? # Parse::User
    artist = parse_object # Artist
    # no need for return in after save
  end
```

For any `after_*` hook, return values are not needed since Parse does not utilize them. You may also register as many `after_save` or `after_delete` handlers as you prefer, all of them will be called.

> **Your model's `after_save` callbacks run here too.** When an `after_save` /
> `after_create` trigger fires, the webhook rebuilds the `Parse::Object` from the
> payload and runs that model's ActiveModel `after_save` / `after_create`
> callbacks — so a `webhook :after_save` block and a model `after_save :method`
> callback are part of the same flow. They fire **exactly once** per save: for
> saves initiated by this Ruby SDK (recognized by the `_RB_` request-id prefix
> together with the master key), Parse Stack already ran them locally after the
> REST response, so the webhook skips them to avoid double-firing side effects;
> for saves from other clients (JS / iOS / REST), the webhook runs them, since
> the SDK never had the chance.

#### Trigger object state

Because the trigger payload is server-authoritative, the `parse_object` your
handler receives is the complete object, and the usual `Parse::Object`
introspection works inside the trigger:

| What you want to know | In `:before_save` | In `:after_save` |
|---|---|---|
| Is this a create or an update? | `parse_object.new?` (`true` = create) | `parse_object.existed?` (`false` = create) or `payload.original.nil?` |
| What changed? | `name_changed?`, `changes`, `changed` | `name_changed?`, `changes`, `changed` (relative to the prior state) |
| Server timestamps | not yet assigned (`new?` create) | `created_at` / `updated_at` populated |
| The prior stored values | `payload.original_parse_object` | `payload.original_parse_object` |

Use `new?` in `:before_save` and `existed?` in `:after_save`. In `:after_save`
the object is already persisted, so `new?` is `false` for both creates and
updates — `existed?` (`created_at != updated_at`) is the create/update signal,
equivalently `payload.original.nil?`.

```ruby
Parse::Webhooks.route :after_save, :Post do
  post = parse_object
  if post.existed?
    Search.reindex(post) if post.title_changed?   # update
  else
    post.create_default_associations!             # first save
  end
  true
end
```

**Lifecycle callback order.** Parse Server has no separate `beforeCreate` /
`afterCreate` triggers — only `beforeSave` and `afterSave`. The SDK runs your
model's ActiveModel callbacks in canonical order across the two webhooks:

```
beforeSave webhook :  before_save  →  before_create   (before_create only for new objects)
   [Parse Server persists]
afterSave  webhook :  after_create →  after_save      (after_create only for new objects)
```

So a model `before_create` / `after_create` callback runs for objects created by
**any** client (REST / JS cloud code / Auth0 / iOS), not just Ruby-model saves —
provided the corresponding trigger is registered with Parse Server (see
[Register Webhooks](#register-webhooks)). These callbacks fire **once** per save;
Ruby-SDK-initiated saves run them locally and the webhook skips them to avoid
double-firing. `:if`/`:unless` conditions on these callbacks are honored.

> **`before_update` / `after_update` do not run from webhooks.** The webhook
> layer runs `before_save` / `before_create` / `after_create` / `after_save`
> only. The `:update`-specific callbacks fire on Ruby-model saves but **not**
> for client-initiated (REST / JS / Auth0) saves, because Parse Server has no
> `beforeUpdate` / `afterUpdate` trigger. For update-time logic that must run
> for all clients, use `before_save` / `after_save` and branch on `existed?`.

> **Keep `after_save` handlers fast.** Parse Server **waits** for the `after_save`
> webhook response before returning to the saving client (only LiveQuery events
> are truly fire-and-forget), so a slow handler adds latency to that client's
> save. And because Parse Server swallows afterSave errors and never retries the
> trigger, blocking on slow work buys you no durability. Do trivial work inline
> and hand anything slow, external, or must-not-be-lost (notifications,
> downstream writes) to a background job/worker, returning quickly. This matters
> most for client-initiated saves, where the callback runs inside the webhook —
> Ruby-SDK saves run it in-process after their own REST response instead.

`before_save` and `before_delete` hooks have special functionality and multiple ways to halt operations:

1. **Using `error!` method**: Calling `error!` will return an error response to Parse Server
2. **Returning `false`**: Webhook blocks can return `false` to halt the operation
3. **ActiveModel callbacks**: When the webhook returns a Parse object, its `before_save` callbacks are executed and can halt by returning `false`

Any of these approaches will prevent Parse from saving the object in `before_save` or deleting the object in `before_delete`.

For `before_save` webhooks, the object returned by the block becomes the response. We recommend modifying the `parse_object` provided (which has dirty tracking) and returning it. This automatically calls your model-specific `before_save` callbacks and sends the proper payload back to Parse. For more details, see [Cloud Code BeforeSave Webhooks](http://docs.parseplatform.org/cloudcode/guide/#beforesave-triggers)

```ruby
# recommended way
class Artist < Parse::Object
  property :name
  property :location, :geopoint

  # setup after save for Artist
  webhook :before_save do
    the_user = user # Parse::User
    artist = parse_object # Artist
    # artist object will have dirty tracking information

    artist.new? # true if this is a new object

    # default San Diego
    artist.location ||= Parse::GeoPoint.new(32.82, -117.23)

    # Multiple ways to halt the save:
    
    # Method 1: Using error! (returns error response)
    error!("Name cannot be empty") if artist.name.blank?
    
    # Method 2: Return false to halt (returns error response)
    return false if artist.location.nil?

    if artist.name_changed?
      wlog "The artist name changed!"
      # .. do something if `name` has changed
    end

    # *important* returns a special hash of changed values
    artist
  end
  
  # ActiveModel callback halting example
  before_save :validate_artist
  
  def validate_artist
    if some_complex_validation_fails?
      # Method 3: ActiveModel callback returns false (halts via webhook integration)
      return false
    end
    true
  end

  webhook :before_delete do
    # prevent deleting Artist records
    error!("You can't delete an Artist")
  end

end

```

### Mounting Webhooks Application
The app can be mounted like any regular Rack-based application.

```ruby
  # Rack (add this to config.ru)
  map "/webhooks" do
    run Parse::Webhooks
  end

  # or in Padrino (add this to apps.rb)
  Padrino.mount('Parse::Webhooks', :cascade => true).to('/webhooks')

  # or in Rails (add this in routes.rb)
  Rails.application.routes.draw do
    mount Parse::Webhooks, :at => '/webhooks'
  end
```

### Register Webhooks
Once you have locally setup all your trigger and function routes, you can write a small rake task to automatically register these hooks with your Parse application. To do this, you can configure a `HOOKS_URL` variable to be used as the endpoint. If you are using a service like Heroku, this would be the name of the heroku app url followed by your configured mount point.

```ruby
# ex. https://12345678.ngrok.com/webhooks
HOOKS_URL = ENV["HOOKS_URL"]

# Register locally setup handlers with Parse
task :register_hooks do
  # Parse.setup(....) if needed
  Parse::Webhooks.register_functions! HOOKS_URL
  Parse::Webhooks.register_triggers! HOOKS_URL
end

# Remove all webhooks!
task :remove_hooks do
  # Parse.setup(....) if needed
  Parse::Webhooks.remove_all_functions!
  Parse::Webhooks.remove_all_triggers!
end

```

However, we have predefined a few rake tasks you can use in your application. Just require `parse/stack/tasks` in your `Rakefile` and call `Parse::Stack.load_tasks`. This is useful for web frameworks like `Padrino`. Note that if you are using Parse-Stack with Rails, this is automatically done for you through the Railtie.

```ruby
  # Add to your Rakefile (if not using Rails)
  require 'parse/stack/tasks' # add this line
  Parse::Stack.load_tasks # add this line
```

Then you can see the tasks available by typing `rake -T`.

## Parse REST API Client
While in most cases you do not have to work with `Parse::Client` directly, you can still utilize it for any raw requests that are not supported by the framework. We provide support for most of the [Parse REST API](http://docs.parseplatform.org/rest/guide/#quick-reference) endpoints as helper methods, however you can use the `request()` method to make your own API requests. Parse::Client will handle header authentication, request/response generation and caching.

```ruby
client = Parse::Client.new(application_id: <string>, api_key: <string>) do |conn|
	# .. optional: configure additional middleware
end

 # Use API helper methods...
 client.config
 client.create_object "Artist", {name: "Hector Lavoe"}
 client.call_function "myCloudFunction", { key: "value"}

 # or use low-level request method
 client.request :get, "/1/users", query: {} , headers: {}
 client.request :post, "/1/users/<objectId>", body: {} , headers: {}

```

If you are already have setup a client that is being used by your defined models, you can access the current client with the following API:

```ruby
  # current Parse::Client used by this model
  client = Song.client

  # you can also have multiple clients
  client = Parse::Client.client #default client session
  client = Parse::Client.client(:other_session)

```

##### Options
- **app_id**: Your Parse application identifier.
- **api_key**: Your REST API key corresponding to the provided `application_id`.
- **master_key**: The master secret key for the application. If this is provided, `api_key` may be unnecessary.
- **logging**: A boolean value to add additional logging messages.
- **cache**: A [Moneta](https://github.com/minad/moneta) cache store that can be used to cache API requests. We recommend use a cache store that supports native expires like [Redis](http://redis.io). For more information see `Parse::Middleware::Caching`. Disabled by default.
- **expires**: When used with the `cache` option, sets the expiration time of cached API responses. The default is 3 seconds.
- **adapter**: The connection adapter to use. Defaults to `Faraday.default_adapter`.

### Request Caching
For high traffic applications that may be performing several server tasks on similar objects, you may utilize request caching. Caching is provided by a the `Parse::Middleware::Caching` class which utilizes a [Moneta store](https://github.com/minad/moneta) object to cache GET url requests that have allowable status codes (ex. HTTP 200, etc). The cache entry for the url will be removed when it is either considered expired (based on the `expires` option) or if a non-GET request is made with the same url. Using this feature appropriately can dramatically reduce your API request usage.

```ruby
store = Moneta.new :Redis, url: 'redis://localhost:6379'
 # use a Redis cache store with an automatic expire of 10 seconds.
Parse.setup(cache: store, expires: 10, ...)

user = Parse::User.first # request made
same_user = Parse::User.first # cached result

# you may clear the cache at any time
# clear the cache for the default session
Parse::Client.client.clear_cache!

# or through the client accessor of a model
Song.client.clear_cache!
```

You can always access the default shared cache through `Parse.cache` and utilize it
for other purposes in your application:

```ruby
# Access the cache instance for other uses
Parse.cache["key"] = "value"
Parse.cache["key"] # => "value"

# or with Parse queries and objects
Parse.cache.fetch("all:records") do |key|
  results = Song.all # or other complex query or operation
  # store it in the cache, but expires in 30 seconds
  Parse.cache.store(key, results, expires: 30)
end

```

## Direct MongoDB Access

Parse-Stack provides direct MongoDB access for performance-critical operations that bypass Parse Server. This is useful for read-heavy operations and advanced features like Atlas Search.

### Configuration

```ruby
# Configure direct MongoDB access
Parse::MongoDB.configure(
  uri: "mongodb://localhost:27017/parse",
  enabled: true
)

# Check if available
Parse::MongoDB.available?  # => true
```

### Query Methods

Execute queries directly against MongoDB using familiar Parse-Stack query syntax:

```ruby
# Execute query directly - returns Parse objects
songs = Song.query(:plays.gt => 1000).results_direct

# Get first result directly
song = Song.query(:plays.gt => 1000).order(:plays.desc).first_direct

# Get count directly
count = Song.query(:plays.gt => 1000).count_direct

# Get first N results
top_songs = Song.query(:plays.gt => 1000).order(:plays.desc).first_direct(5)

# Get raw Parse-formatted hashes instead of objects
hashes = Song.query(:plays.gt => 1000).results_direct(raw: true)
```

**Supported Operators:**

All standard query operators work with MongoDB direct:

```ruby
# Comparison operators
Song.query(:plays.gt => 1000, :rating.gte => 4).results_direct

# Date range queries
Event.query(:event_date.gt => Time.now).results_direct
Event.query(:event_date.gte => start_date, :event_date.lte => end_date).results_direct

# Array operators
Song.query(:tags.size => 3).results_direct
Song.query(:tags.contains_all => ["rock", "classic"]).results_direct
Song.query(:tags.empty_or_nil => true).results_direct

# String/Regex operators
Product.query(:name.like => /iphone/i).results_direct
Product.query(:name.starts_with => "iPhone").results_direct

# Relational queries (in_query/not_in_query)
Song.query(:artist.in_query => Artist.query(:verified => true)).results_direct

# Complex combinations
Song.query(
  :artist.in_query => Artist.query(:verified => true),
  :tags.empty_or_nil => false,
  :plays.gt => 1000
).results_direct
```

**Include/Eager Loading:**

Eager load related objects via MongoDB `$lookup`:

```ruby
# Include related artist data (resolved via $lookup)
songs = Song.query(:plays.gt => 1000).includes(:artist).results_direct
songs.each do |song|
  puts "#{song.title} by #{song.artist.name}"  # No additional queries!
end

# Multiple includes
songs = Song.query.includes(:artist, :album).results_direct
```

### Low-Level Direct Access

For advanced use cases, access MongoDB directly:

```ruby
# Direct find with options
docs = Parse::MongoDB.find("Song", { plays: { "$gt" => 1000 } },
  limit: 10,
  sort: { plays: -1 }
)

# Aggregation pipelines
results = Parse::MongoDB.aggregate("Song", [
  { "$match" => { "genre" => "Rock" } },
  { "$group" => { "_id" => "$artist", "total" => { "$sum" => "$plays" } } }
])

# List Atlas Search indexes
indexes = Parse::MongoDB.list_search_indexes("Song")
```

### Document Conversion

MongoDB documents are automatically converted to Parse format:
- `_id` → `objectId`
- `_created_at` → `createdAt`
- `_updated_at` → `updatedAt`
- `_p_fieldName` → `fieldName` (pointers)
- `_acl` → `ACL` (with r/w → read/write)
- BSON dates → Parse Date format

### Performance Benefits

- Bypasses Parse Server REST API overhead
- Direct MongoDB aggregation pipeline execution
- Automatic pointer resolution with `$lookup`
- Native BSON date handling
- Ideal for read-heavy operations and analytics

### Keys Projection

Use `keys` with `mongo_direct` to fetch only specific fields, returning partially fetched objects:

```ruby
songs = Song.query(:genre => "Rock")
            .keys(:title, :plays)
            .results(mongo_direct: true)

song = songs.first
song.title              # => "My Song"
song.partially_fetched? # => true
song.fetched_keys       # => [:title, :plays, :id, :objectId]
```

Required fields (`objectId`, `createdAt`, `updatedAt`, `ACL`) are always included.

### Aggregation Results

Custom aggregation results support both hash and method access with automatic camelCase to snake_case conversion:

```ruby
pipeline = [
  { "$group" => { "_id" => "$genre", "totalPlays" => { "$sum" => "$playCount" } } }
]
results = Song.query.aggregate(pipeline, mongo_direct: true).results

results.first.total_plays   # => 5000 (method access)
results.first["totalPlays"] # => 5000 (hash access)
```

### Field Name Conventions

When writing aggregation pipelines, use MongoDB's native field names:

| Field Type | Ruby Property | MongoDB Field |
|------------|---------------|---------------|
| Regular fields | `release_date` | `releaseDate` |
| Pointer fields | `artist` | `_p_artist` |
| Built-in dates | `created_at` | `_created_at` |

```ruby
pipeline = [
  { "$match" => { "releaseDate" => { "$lt" => Time.utc(2024, 1, 1) } } },
  { "$group" => { "_id" => "$_p_artist", "total" => { "$sum" => "$playCount" } } }
]
```

### ACL Filtering

Filter objects by ACL permissions using MongoDB's `_rperm` and `_wperm` fields:

**`readable_by` / `writable_by`** - Exact permission strings:
```ruby
Song.query.readable_by("user123").results(mongo_direct: true)       # User ID
Song.query.readable_by("role:Admin").results(mongo_direct: true)    # Role (explicit prefix)
Song.query.readable_by(current_user).results(mongo_direct: true)    # User object
Song.query.readable_by("public").results(mongo_direct: true)        # Public access (alias for "*")
Song.query.readable_by("none").results(mongo_direct: true)          # Empty _rperm (master key only)
```

**`readable_by_role` / `writable_by_role`** - Adds "role:" prefix automatically:
```ruby
Song.query.readable_by_role("Admin").results(mongo_direct: true)              # → "role:Admin"
Song.query.readable_by_role(admin_role).results(mongo_direct: true)           # Role object
Song.query.writable_by_role(["Admin", "Editor"]).results(mongo_direct: true)  # Multiple roles
```

**Note:** Requires the `mongo` gem. Add `gem 'mongo'` to your Gemfile.

### ACL Dirty Tracking

Parse-Stack provides intelligent dirty tracking for ACL objects, correctly handling in-place modifications and content comparison.

**`acl_was` Posts Original State:**

When modifying an ACL in place (via `apply`, `apply_role`, etc.), `acl_was` correctly returns the state *before* any modifications:

```ruby
obj = MyObject.find(id)
obj.clear_changes!

# Original ACL is empty
obj.acl.as_json  # => {}

# Modify ACL in place
obj.acl.apply(:public, true, false)
obj.acl.apply_role("Admin", true, true)

# acl_was correctly shows original state
obj.acl_was.as_json  # => {} (not the mutated state)
obj.acl.as_json      # => {"*"=>{"read"=>true}, "role:Admin"=>{"read"=>true, "write"=>true}}
obj.acl_changed?     # => true
```

**Content-Based Comparison:**

Setting an ACL to identical values does not mark the object as dirty:

```ruby
subscription = Subscription.find(id)
subscription.clear_changes!

# Rebuild ACL to the same values (common in before_save hooks)
subscription.acl = Parse::ACL.new
subscription.acl.apply(:public, true, false)
subscription.acl.apply_role("Admin", true, true)
# ... same permissions as before ...

# If content is identical, object is NOT dirty
subscription.acl_changed?  # => false
subscription.dirty?        # => false
subscription.save          # No unnecessary server request
```

**New Objects:**

New objects always include ACL in changes to ensure it's sent on first save:

```ruby
obj = MyObject.new(title: "Test")
obj.acl = Parse::ACL.new
obj.acl.apply(:public, true, false)

obj.new?                      # => true
obj.changed.include?("acl")   # => true (always included for new objects)
```

**Implementation Notes:**

The ACL dirty tracking system uses several techniques to ensure correctness:
- A snapshot of the ACL is captured before any in-place modifications via `acl_will_change!`
- Content comparison uses JSON serialization to detect actual changes vs reference changes
- The `changed` method safely duplicates arrays before modification to avoid interfering with ActiveModel internals
- Nil-safe checks prevent errors when ACL is unset

## Atlas Search

MongoDB Atlas Search integration provides full-text search, autocomplete, and faceted search capabilities directly through MongoDB.

### Setup

```ruby
# Configure MongoDB and Atlas Search
Parse::MongoDB.configure(uri: "mongodb+srv://...", enabled: true)
Parse::AtlasSearch.configure(enabled: true, default_index: "default")

# Recommended for new deployments — refuse calls without an explicit
# ACL posture (session_token: or master: true). See "Session-Scoped
# Search" below.
Parse::AtlasSearch.require_session_token = true
```

### Session-Scoped Search

Atlas Search runs `$search` aggregations directly against MongoDB and
therefore bypasses Parse Server's per-request ACL evaluation. To enforce
the same `_rperm` semantics the REST API enforces, pass `session_token:`
on the call — the SDK resolves the token to a user, expands the user's
inherited role set, and injects a `_rperm` `$match` stage into the
pipeline.

```ruby
# Session-scoped — results filtered to documents readable by the user
# whose session token this is, including documents permitted by any
# role the user inherits (Parse::Role.all_for_user).
result = Parse::AtlasSearch.search("Song", "love",
                                    session_token: request.session_token,
                                    limit: 10)

# Master-key-equivalent — explicit ACL bypass. Use for analytics jobs,
# admin tooling, or anywhere ACL is enforced upstream.
result = Parse::AtlasSearch.search("Song", "love", master: true)

# Passing neither emits a one-time [Parse::AtlasSearch:SECURITY]
# banner and falls through to public-only ACL semantics. Set
# `Parse::AtlasSearch.require_session_token = true` to make the
# missing-auth call an `ACLRequired` error instead.
```

Caching for session-token lookups is configurable:

```ruby
Parse::AtlasSearch.session_cache_ttl = 3600  # token → user_id
Parse::AtlasSearch.role_cache_ttl    = 120   # user_id → role names

# Force re-resolution after logout / role mutation:
Parse::AtlasSearch::Session.invalidate(token)
Parse::AtlasSearch::Session.invalidate_user_roles(user_id)
```

Notes:

- `faceted_search` cannot ACL-filter `$searchMeta` bucket counts and
  raises `Parse::AtlasSearch::FacetedSearchNotACLSafe` when a
  `session_token:` is supplied. Run with `master: true` (or fall back
  to multiple `search` calls with explicit `filter:` constraints).
- The session resolver follows Parse Server's role-inheritance
  direction: a user's permissions include any role whose `roles`
  relation transitively contains a role the user directly belongs
  to. See `Parse::Role.all_for_user` for the primitive.

### Full-Text Search

```ruby
# Basic search
result = Parse::AtlasSearch.search("Song", "love ballad")
result.each { |song| puts "#{song.title} (score: #{song.search_score})" }

# Search with options
result = Parse::AtlasSearch.search("Song", "love",
  fields: [:title, :lyrics],    # Limit to specific fields
  fuzzy: true,                   # Enable fuzzy matching
  limit: 20,                     # Max results
  highlight_field: :title        # Get highlighted matches
)

# Access highlights
result.each do |song|
  puts song.search_highlights if song.respond_to?(:search_highlights)
end
```

### Autocomplete (Search-as-you-type)

```ruby
# Basic autocomplete
result = Parse::AtlasSearch.autocomplete("Song", "Lov", field: :title)
result.suggestions  # => ["Love Story", "Lovely Day", "Love Me Do"]

# With fuzzy matching
result = Parse::AtlasSearch.autocomplete("Song", "lvoe",
  field: :title,
  fuzzy: true,
  limit: 5
)
```

### Faceted Search

```ruby
# Define facets
facets = {
  genre: { type: :string, path: :genre, num_buckets: 10 },
  decade: { type: :number, path: :year, boundaries: [1970, 1980, 1990, 2000, 2010, 2020] }
}

# Execute faceted search
result = Parse::AtlasSearch.faceted_search("Song", "rock", facets, limit: 20)

# Access facet counts
result.facets[:genre]
# => [{ value: "Rock", count: 150 }, { value: "Alternative", count: 45 }, ...]

result.total_count  # => 195
result.results      # => matching Song objects
```

### Search Builder (Advanced)

For complex searches, use the fluent SearchBuilder:

```ruby
builder = Parse::AtlasSearch::SearchBuilder.new(index_name: "song_search")

# Chain multiple operators
builder
  .text(query: "love", path: :title, fuzzy: true)
  .phrase(query: "broken heart", path: :lyrics, slop: 2)
  .range(path: :plays, gte: 1000)
  .with_highlight(path: :title)
  .with_count

# Build the $search stage
search_stage = builder.build

# Use in aggregation pipeline
pipeline = [search_stage, { "$limit" => 10 }]
results = Parse::MongoDB.aggregate("Song", pipeline)
```

### Query Integration

Atlas Search is also available directly on queries:

```ruby
# Search through Query
songs = Song.query.atlas_search("love ballad", fields: [:title, :lyrics], limit: 10)

# Autocomplete through Query
suggestions = Song.query.atlas_autocomplete("Lov", field: :title)

# Faceted search through Query
result = Song.query.atlas_facets("rock", { genre: { type: :string, path: :genre } })
```

### Index Management

```ruby
# List indexes for a collection
indexes = Parse::AtlasSearch.indexes("Song")
# => [{ "name" => "default", "queryable" => true, ... }]

# Check if index is ready
Parse::AtlasSearch.index_ready?("Song", "default")  # => true

# Refresh index cache
Parse::AtlasSearch.refresh_indexes("Song")
```

### Creating Search Indexes

Atlas Search requires indexes to be created on your MongoDB Atlas cluster. Indexes define which fields are searchable and how they should be analyzed.

**Via MongoDB Atlas UI:**
1. Navigate to your cluster → **Atlas Search** tab
2. Click **Create Search Index**
3. Select your database and collection
4. Define your index mappings

**Via MongoDB Shell:**

```javascript
// Basic dynamic index (indexes all fields)
db.Song.createSearchIndex("default", {
  mappings: { dynamic: true }
});

// Index with autocomplete support
db.Song.createSearchIndex("default", {
  mappings: {
    fields: {
      title: [
        { type: "string" },
        { type: "autocomplete", tokenization: "edgeGram", minGrams: 2, maxGrams: 15 }
      ],
      genre: [
        { type: "string" },
        { type: "stringFacet" }
      ]
    }
  }
});

// Check index status
db.Song.getSearchIndexes();
```

**Parse Collection Names:**
- Custom classes use their class name directly: `Song`, `Artist`, `Album`
- Built-in classes have underscore prefixes: `_User`, `_Role`, `_Session`

**Local Development:**

For local development, use MongoDB Atlas Local:

```bash
docker run -d -p 27017:27017 mongodb/mongodb-atlas-local:latest
```

Or use the provided Docker Compose setup - see [CHANGELOG.md](./CHANGELOG.md) for detailed index examples and [Testing](#testing) for Docker-based setup.

**Note:** Atlas Search requires MongoDB Atlas or a local Atlas deployment. See [Testing](#testing) for Docker-based local setup.

## Contributing

Bug reports and pull requests are welcome on GitHub at [https://github.com/neurosynq/parse-stack-next](https://github.com/neurosynq/parse-stack-next).

This project is a fork of the original [Parse Stack](https://github.com/modernistik/parse-stack) by [Modernistik](https://www.modernistik.com).

## Testing

Parse Stack includes comprehensive integration tests that require a Parse Server instance for full functionality testing. The tests are designed to work with Docker for easy setup and consistency across environments.

### Docker Integration Tests

The integration tests use Docker Compose to spin up a Parse Server instance with MongoDB and Redis. This ensures tests run in a clean, isolated environment.

#### Prerequisites

- Docker and Docker Compose installed
- Ruby environment with bundler

#### Setup and Running Tests

1. **Enable Docker Tests**: Set the environment variable to enable Docker-based tests:
   ```bash
   export PARSE_TEST_USE_DOCKER=true
   ```

2. **Run All Integration Tests**: Execute the full test suite:
   ```bash
   bundle exec rake test
   ```

3. **Run Specific Test Suites**: Run individual test files for focused testing:
   ```bash
   # Cache integration tests
   bundle exec ruby test/lib/parse/cache_integration_test.rb
   
   # Model associations tests
   bundle exec ruby test/lib/parse/model_associations_test.rb
   
   # Query and aggregation tests
   bundle exec ruby test/lib/parse/query_aggregate_test.rb
   
   # Request idempotency tests
   bundle exec ruby test/lib/parse/request_idempotency_test.rb
   
   # Webhook callback tests
   bundle exec ruby test/lib/parse/webhook_callbacks_test.rb
   
   # Cloud config tests
   bundle exec ruby test/lib/parse/cloud_config_test.rb
   ```

#### Test Categories

**Core Feature Tests:**
- **Cache Integration**: Redis caching, invalidation, TTL, authentication contexts
- **Date and Timezone**: UTC handling, timezone conversions, DST transitions  
- **Batch Operations**: Atomic transactions, rollback scenarios, error handling
- **Model Associations**: `has_many`, `has_one`, `belongs_to` with all approaches

**Advanced Feature Tests:**
- **Query Operations**: Pointer handling, contains/nin operators, complex queries
- **Aggregation Pipelines**: MongoDB aggregations, field conversions, date operations
- **Cloud Config**: Reading/writing config variables, data validation, edge cases
- **Request Idempotency**: Duplicate prevention, thread safety, configuration
- **Webhook Callbacks**: Ruby vs client detection, callback coordination

#### Docker Configuration

The integration stack is defined in `scripts/docker/docker-compose.test.yml`
(Parse Server, MongoDB, Redis, and the Parse Dashboard); the Atlas Search stack
is in `scripts/docker/docker-compose.atlas.yml`. It is deliberately isolated
from any other Parse test system on the same host — a dedicated Compose project,
a private port block, and a dedicated database name — so two Parse stacks can
run side by side without colliding.

Default host ports (each overridable via the env var shown):

| Service              | Host port | Override env var      |
|----------------------|-----------|-----------------------|
| Parse Server         | 29337     | `PARSE_HOST_PORT`     |
| MongoDB (test)       | 29017     | `MONGO_HOST_PORT`     |
| Redis                | 29379     | `REDIS_HOST_PORT`     |
| Parse Dashboard      | 29040     | `DASHBOARD_HOST_PORT` |
| MongoDB Atlas Local  | 29020     | `ATLAS_HOST_PORT`     |

Identity and naming:

- Containers, network, and volumes are namespaced by the Compose project
  `psnext-it`. Override the prefix with `PSNEXT_PREFIX` (e.g.
  `PSNEXT_PREFIX=psnext-ci`) to run a second, fully separate copy of the stack.
- Parse database name: `parse_stack_next_it`. Atlas database: `parse_atlas_test`.
- Default credentials: app id `psnextItAppId`, master key `psnextItMasterKey`,
  REST key `psnext-it-rest-key` (override with `PARSE_APP_ID`,
  `PARSE_MASTER_KEY`, `PARSE_API_KEY`).

Bring the stack up and verify:

```bash
docker compose -f scripts/docker/docker-compose.test.yml up -d
curl -s http://localhost:29337/parse/health   # -> {"status":"ok"}
```

#### Environment Variables

The defaults above are baked into the Compose file and the test helpers, so the
suite is isolated out of the box. To re-point anything, export the variables in
your shell before running (nothing auto-loads `.env.test` — it is a committed
reference of the full set; `set -a; source .env.test; set +a` loads them all at
once). There are two sides — the containers and the Ruby client — and when you
move a port you set both so they agree:

```bash
# Required to route the suite at the Docker stack
export PARSE_TEST_USE_DOCKER=true

# Compose side — what the containers publish / use
export PSNEXT_PREFIX=psnext-it
export PARSE_HOST_PORT=29337
export MONGO_HOST_PORT=29017
export REDIS_HOST_PORT=29379
export PARSE_APP_ID=psnextItAppId
export PARSE_MASTER_KEY=psnextItMasterKey
export PARSE_API_KEY=psnext-it-rest-key

# Client side — what the Ruby test suite connects to
export PARSE_TEST_SERVER_URL=http://localhost:29337/parse
export PARSE_TEST_APP_ID=psnextItAppId
export PARSE_TEST_API_KEY=psnext-it-rest-key
export PARSE_TEST_MASTER_KEY=psnextItMasterKey
export PARSE_TEST_MONGO_URI="mongodb://admin:password@localhost:29017/parse_stack_next_it?authSource=admin"
export PARSE_TEST_REDIS_URL=redis://localhost:29379/0
export PARSE_TEST_LIVE_QUERY_URL=ws://localhost:29337
export ATLAS_URI="mongodb://localhost:29020/parse_atlas_test?directConnection=true"
```

#### Troubleshooting

**Common Issues:**

1. **Docker not running**: Ensure Docker daemon is running
   ```bash
   docker --version
   docker-compose --version
   ```

2. **Port conflicts**: The stack uses a dedicated `29xxx` block (29337 / 29017 /
   29379 / 29040 / 29020) specifically to avoid colliding with a default Parse
   setup (1337 / 27017 / 6379 / 4040). If something still holds one of those
   ports, override it (for example `PARSE_HOST_PORT=29338`) or stop the
   conflicting stack:
   ```bash
   docker compose -f scripts/docker/docker-compose.test.yml down
   ```

3. **Permission errors**: Ensure Docker has proper permissions
   ```bash
   sudo usermod -aG docker $USER  # Linux
   ```

**Test Debugging:**

Enable verbose logging for detailed test output:
```bash
PARSE_STACK_LOGGING=debug bundle exec ruby test/lib/parse/cache_integration_test.rb
```

**Docker Logs:**

View Parse Server logs during test runs:
```bash
docker-compose -f docker-compose.test.yml logs -f parse-server
```

### Unit Tests

For faster development cycles, unit tests can be run without Docker:

```bash
# Run only unit tests (no Docker required)
bundle exec ruby test/lib/parse/models/property_test.rb
bundle exec ruby test/lib/parse/query/basic_test.rb
```

Unit tests focus on:
- Object property definitions
- Query constraint building  
- Data type conversions
- Model validations
- Basic functionality

### Contributing Tests

When contributing to Parse Stack:

1. **Add Integration Tests**: For new features that interact with Parse Server
2. **Add Unit Tests**: For utility functions and data transformations
3. **Test Edge Cases**: Include error conditions and boundary values
4. **Document Test Scenarios**: Add clear descriptions of what each test validates

Example test structure:
```ruby
def test_new_feature
  puts "\n=== Testing New Feature ==="
  
  # Setup
  # Test execution  
  # Assertions
  # Cleanup (if needed)
  
  puts "✅ New feature test passed"
end
```

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).
