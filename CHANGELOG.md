## Parse-Stack Changelog

### 3.3.6

#### Fixes

- **FIXED**: `:field.set_equals` and `:field.not_set_equals` constraints no longer raise MongoDB error 17044 (`All operands of $setEquals must be arrays. 1-th argument is of type: missing`) when any matched document is missing the array field. Previously, the compiled aggregation passed `"$<field>"` directly into `$setEquals`, which resolves to `Missing` for legacy documents that predate the field's introduction (commonly seen on classes where an array property was added after the collection already had data). MongoDB then aborted the entire pipeline and Parse Server surfaced this as error 102, so even documents that did have the field were never returned. Both compile paths (simple value arrays and pointer arrays via `$map`) now wrap the field reference in `$ifNull => ["$<field>", []]`, coercing a missing or null field to an empty array. Set-equality semantics are preserved: a missing field and `[]` are now equivalent for matching purposes — both fail to match `set_equals: ["A","B"]` and both succeed to match `set_equals: []`. This mirrors the existing treatment of missing/empty fields in `:size`, `:arr_empty`, and `:empty_or_nil`. (`lib/parse/query/constraints.rb`)
- **FIXED**: `:field.subset_of` constraint no longer raises MongoDB error 17044 / 16554 on documents missing the field. Both the simple-value branch (`$setIsSubset` over a raw field reference) and the pointer-array branch (`$map` over a raw field reference, fed into `$setIsSubset`) now wrap the field in `$ifNull => ["$<field>", []]`. Semantics: the empty set is a subset of every set, so a document missing the field now matches `subset_of: ["a", "b"]` — consistent with treating a missing field as `[]`. (`lib/parse/query/constraints.rb`)
- **FIXED**: `:field.eq_array` and `:field.neq` pointer-array branches no longer raise a MongoDB type error when matched documents are missing the relation field. Both branches feed `"$<field>"` into `$map`, which fails on a missing field reference; both now wrap the input in `$ifNull => ["$<field>", []]`. The simple-value branches are also wrapped so that a missing field is treated as `[]` consistently — `eq_array: []` now matches a missing field, and `neq: []` no longer matches a missing field, aligning with the rest of the array-constraint family.  (`lib/parse/query/constraints.rb`)
- **IMPROVED**: `:field.first` and `:field.last` constraints now wrap field references in `$ifNull => ["$<field>", []]` for consistency with the rest of the array-constraint family. Previous behavior returned `null` from `$arrayElemAt` on missing fields, which was already non-crashing; the change is defensive and does not alter results. (`lib/parse/query/constraints.rb`)

### 3.3.5

#### Security Fixes

- **FIXED**: Stderr `warn` output for HTTP errors and cloud-code errors no longer bypasses the credential redaction filter. All twelve `warn` call sites in `Parse::Client` (HTTP 401/403/404/405/406/408/429/500/503, Parse error codes 1/2/100/155/209, plus `Parse.call_function` and `Parse.trigger_job` cloud-code errors) now route through a single `_safe_warn` helper that runs the response error string through `Parse::Middleware::BodyBuilder.redact` (stripping `password`, `token`, `sessionToken`, `session_token`, `access_token`, and `authData` values) and truncates to 200 characters. Previously, a cloud function calling `error!("auth failed for token #{token}")` or a Parse server error message containing credentials would be reflected verbatim to stderr on every failed request, bypassing the redaction middleware added in 3.3.2/3.3.3 for request/response body logging. Output format is preserved for backwards compatibility with log scrapers. (`lib/parse/client.rb`)

### 3.3.4

#### Improvements

- **NEW**: `Parse.call_function!`, `Parse.call_function_with_session!`, `Parse.trigger_job!`, and `Parse.trigger_job_with_session!` raise `Parse::Error::CloudCodeError` when the cloud function or job returns an error response, instead of silently returning nil. The error carries `function_name`, `code`, `http_status`, and the underlying `Parse::Response` for debugging. Use these variants when you want failures to propagate rather than be coerced to nil. (`lib/parse/client.rb`)
- **IMPROVED**: `Parse.call_function` and `Parse.trigger_job` now emit a `[Parse:CloudCodeError]` warning to stderr when the response indicates an error, instead of silently returning nil. Previously, both methods coerced any cloud-code error response to a nil return value with no log line, making misconfigured calls (missing session token, failed `error!()` in cloud code) invisible to callers and tests. The nil return is preserved for backwards compatibility; the warning surfaces the failure. Matches the existing warn-then-raise pattern used by other HTTP error paths in `Parse::Client#request`. (`lib/parse/client.rb`)
- **FIXED**: `Parse.call_function`, `Parse.trigger_job`, and their `!` variants no longer raise `TypeError` on unusual successful response bodies. Result extraction now guards against non-Hash response payloads (e.g., a bare string body) by returning the raw result rather than indexing into a non-Hash. (`lib/parse/client.rb`)

### 3.3.3

#### Security Fixes

- **FIXED**: Login rate limiter cleanup no longer wipes in-progress failure counters. The previous `delete_if` predicate removed every entry where `locked_until` was nil, which included pre-lockout counters (1-4 failures). An attacker could trigger cleanup by flooding unique usernames and reset a target account's failure counter, defeating rate limiting. Cleanup now only removes entries whose lockout has actually expired past the TTL. (`lib/parse/api/users.rb`)
- **FIXED**: Debug log header redaction expanded to cover all credential-bearing headers. Previously only `X-Parse-Master-Key` was skipped; `X-Parse-REST-API-Key`, `X-Parse-Session-Token`, `X-Parse-JavaScript-Key`, `Authorization`, and `Cookie` were printed verbatim when `Parse.logging = :debug` was enabled. (`lib/parse/client/body_builder.rb`)
- **FIXED**: Webhook payload debug logging now passes through the sensitive-field redactor. Previously `payload.as_json` was printed raw when `Parse::Webhooks.logging == :debug`, exposing any session tokens, passwords, or auth data carried in the payload. (`lib/parse/webhooks.rb`)
- **FIXED**: `Parse::Query#resolve_parse_pointer` now resolves server-returned `className` values via the registered `Parse::Model.find_class` registry instead of `Object.const_get`. Prevents attacker-influenced className strings from triggering autoload of arbitrary constants. (`lib/parse/query.rb`)

#### Improvements

- **IMPROVED**: HTTP retry delay on `429 Too Many Requests` and connection errors now uses deterministic exponential backoff with +/-25% jitter. The previous `[0, RETRY_DELAY, backoff_delay].sample` implementation had a one-in-three probability of retrying immediately, which amplified backpressure against upstream rate-limited servers. (`lib/parse/client.rb`)
- **DEPRECATED**: `Parse::MongoDB.find` now emits a deprecation warning when called without an explicit `:limit` option and the result exceeds `Parse::MongoDB::DEFAULT_FIND_LIMIT` (1000) rows. Existing callers continue to receive unbounded results, but a future major release will apply 1000 as a hard default to prevent unbounded `cursor.to_a` from exhausting memory. Pass an explicit `:limit` to silence the warning, or `:limit => 0` to preserve unbounded behavior long-term. (`lib/parse/mongodb.rb`)

#### Bug Fixes

- **FIXED**: `Parse::ACL::Permission#no_read!` now correctly sets `@read = false` instead of `@write = false`. The outer `Parse::ACL#no_read!` does not route through this method so no production code path relied on the buggy behavior, but the inner method was incorrect. (`lib/parse/model/acl.rb`)

### 3.3.2

#### Security Fixes

- **FIXED**: Login now uses POST instead of GET, preventing passwords from appearing in server logs, browser history, and URL query parameters.
- **FIXED**: Webhook key comparison now uses constant-time `ActiveSupport::SecurityUtils.secure_compare` to prevent timing attacks. Invalid webhook keys are no longer logged.
- **FIXED**: MCP server default binding changed from `0.0.0.0` to `127.0.0.1`, preventing unintended network exposure.
- **FIXED**: Field names in queries are now validated to block MongoDB operator injection (`$where`, `$function`, etc.).
- **FIXED**: Aggregation pipelines now block dangerous stages (`$out`, `$merge`) and `$where` operators inside `$match` stages.
- **FIXED**: Sensitive fields (passwords, tokens, auth data) are now redacted from debug log output.
- **NEW**: Client-side login rate limiting with exponential backoff after repeated failures to mitigate brute force attacks.
- **FIXED**: Session tokens in cache keys are now hashed with SHA-256 instead of stored as plaintext.
- **NEW**: MCP server now supports API key authentication via `MCP_API_KEY` env var or `api_key:` parameter. Requests must include `X-MCP-API-Key` header when configured.
- **FIXED**: JSON payloads in webhooks and MCP server are now limited to 1 MB size and 20 levels of nesting depth to prevent denial-of-service attacks.
- **FIXED**: Tool method invocation in MCP server now blocks dangerous methods (`eval`, `exec`, `system`, `send`, `method`, `binding`, etc.) to prevent code execution via user-controlled method names.
- **FIXED**: Blocked methods list moved to always-loaded `Parse::Agent::Tools` module, fixing load-order crash when MCP server is not enabled.
- **FIXED**: Login rate limiter is now thread-safe (Mutex-protected) with periodic cleanup of expired entries to prevent memory leaks.
- **FIXED**: MCP server now explicitly requires ActiveSupport modules, preventing load-order failures.
- **FIXED**: Session token cache key hash increased from 16 to 32 hex characters (128 bits) to reduce collision risk.
- **FIXED**: MCP `/tools` endpoint now requires API key authentication when configured, preventing unauthenticated schema enumeration.
- **FIXED**: Response body logging is now redacted alongside request logging, preventing session tokens from appearing in debug output.
- **NEW**: `require_https` option for `Parse::Client` raises an error when HTTP is used with a non-localhost server URL. Enable via `require_https: true` or `PARSE_REQUIRE_HTTPS=true`.
- **FIXED**: `login_with_mfa` now applies the same rate limiting and exponential backoff as the standard `login` method.
- **FIXED**: Aggregation pipeline blocklist expanded to also block `$function`, `$accumulator`, `$collMod`, `$createIndex`, and `$dropIndex` stages.

#### Bug Fixes

- **FIXED**: `Parse::Object.transaction` now correctly assigns `objectId`, `createdAt`, and `updatedAt` to all objects in the batch. Previously, only the first unsaved object received its server-assigned ID because `Parse::Object#hash` treats all unsaved objects as equal, causing Hash key collisions in the internal tracking map.
- **FIXED**: `AggregateTestComment` and `AggregateTestPost` test models now use `belongs_to` for pointer fields instead of `property :object`, which caused Parse Server schema mismatch errors when saving pointer values.

### 3.3.1
- Bundle update

### 3.3.0

#### Breaking Changes

- **BREAKING**: Minimum Ruby version is now 3.1 (previously 3.0). Ruby 3.0 reached end-of-life in March 2024.

#### Improvements

- **IMPROVED**: CI now tests against Ruby 3.1, 3.2, 3.3, and 3.4.

### 3.2.2

#### Improvements

- **IMPROVED**: `latest` and `last_updated` methods now support a `limit:` option when passing constraints. This allows fetching multiple recent records while also filtering by query conditions.

```ruby
# Class methods
Song.latest(:user.eq => user, limit: 5)       # 5 most recent for user
Song.last_updated(status: "active", limit: 10) # 10 most recently updated active

# Query instance methods
query.latest(:user.eq => x, limit: 5)
query.where(genre: "rock").last_updated(limit: 3)
```

- **IMPROVED**: `PointerCollectionProxy#as_json` now supports the `pointers_only` option. By default it returns pointers (preserving backward compatibility), but you can set `pointers_only: false` to serialize objects with their fetched fields. This is useful when returning `has_many :through => :array` relationships in webhook responses.

  When `pointers_only: false`:
  - Partially hydrated objects serialize only their fetched fields (no autofetch triggered)
  - Pointer-only objects (unfetched) remain as pointers
  - Fully hydrated objects serialize all their fields

```ruby
# Default behavior - pointers for storage (backward compatible)
capture.assets.as_json
# => [{"__type"=>"Pointer", "className"=>"Asset", "objectId"=>"abc"}, ...]

# Serialize with fetched fields (no autofetch, pointers stay as pointers)
capture.assets.as_json(pointers_only: false)
# => [{"objectId"=>"abc", "file"=>{...}, "caption"=>"My photo", ...}, ...]

# In webhooks, manually override assets serialization:
cloud_results.map do |capture|
  json = capture.as_json
  json['assets'] = capture.assets.as_json(pointers_only: false) if capture.assets.any?
  json
end
```

- **IMPROVED**: `Parse::Object#as_json` with `:only` option now automatically includes identification fields (`objectId`, `className`, `__type`, `id`) so serialized objects can always be properly identified. Use `strict: true` to disable this behavior for pure strict filtering.

```ruby
# Default: identification fields are always included
song.as_json(only: [:title, :artist])
# => {"objectId"=>"abc", "className"=>"Song", "__type"=>"Object", "title"=>"...", "artist"=>"..."}

# With strict: true, only exactly specified fields are included
song.as_json(only: [:title, :artist], strict: true)
# => {"title"=>"...", "artist"=>"..."}
```

- **NEW**: Added `:exclude` as an alias for `:except` in `as_json` for more intuitive field exclusion.

```ruby
# All three are equivalent:
song.as_json(except: [:acl, :created_at])
song.as_json(exclude_keys: [:acl, :created_at])
song.as_json(exclude: [:acl, :created_at])
```

### 3.2.1

#### New Features

- **NEW**: Added `set_default_clp` method to set a default permission for all CLP operations at once. This is important because Parse Server treats missing operations as `{}` (no access, master key only).

```ruby
class Document < Parse::Object
  # Set all operations to public by default
  set_default_clp public: true

  # Or require authentication for all operations
  set_default_clp requires_authentication: true

  # Or restrict all operations to specific roles
  set_default_clp roles: ["Admin", "Editor"]

  # Then override specific operations as needed
  set_clp :delete, public: false, roles: ["Admin"]
end
```

- **NEW**: Added `set_read_user_fields` and `set_write_user_fields` for pointer-based permissions. These allow users referenced by pointer fields to have read/write access to objects.

```ruby
class Document < Parse::Object
  belongs_to :owner, as: :user
  belongs_to :editor, as: :user

  # Owner can read, editor can write
  set_read_user_fields [:owner]
  set_write_user_fields [:editor]

  # Snake_case field names are auto-converted to camelCase
end
```

- **NEW**: Added `reset_clp!` method to reset CLPs to public defaults. Useful for clearing restrictive permissions that may have accumulated on the server.

```ruby
# Reset all CLPs to public access
Song.reset_clp!
```

#### Improvements

- **IMPROVED**: CLP methods now automatically convert snake_case Ruby property names to camelCase Parse Server field names. This provides consistency with the rest of the Parse Stack framework where you define properties in snake_case.

**`protect_fields` - field names and userField patterns:**

```ruby
class Document < Parse::Object
  property :internal_notes, :string
  property :secret_data, :string
  belongs_to :owner_user, as: :user

  # Field names are auto-converted
  protect_fields "*", [:internal_notes, :secret_data]
  # Converts to: ["internalNotes", "secretData"]

  # userField pattern field names are also converted
  protect_fields "userField:owner_user", []
  # Converts to: "userField:ownerUser"

  # Custom field mappings are respected
  property :custom_field, :string, field: "myCustomField"
  protect_fields "*", [:custom_field]
  # Converts to: ["myCustomField"]
end
```

**`set_clp` - pointer_fields parameter:**

```ruby
class Document < Parse::Object
  belongs_to :owner_field, as: :user
  belongs_to :editor_field, as: :user

  # pointer_fields are auto-converted
  set_clp :update, pointer_fields: [:owner_field, :editor_field]
  # Converts to: pointerFields: ["ownerField", "editorField"]
end
```

- **IMPROVED**: Added `include_defaults` parameter to `CLP#as_json`. When `true`, includes default permissions for all undefined operations (useful when pushing complete CLP to server).

```ruby
clp = Parse::CLP.new
clp.set_default_permission(public: true)
clp.set_permission(:delete, roles: ["Admin"])

# Without defaults - only explicitly set operations
clp.as_json
# => {"delete" => {"role:Admin" => true}}

# With defaults - all operations included
clp.as_json(include_defaults: true)
# => {"find" => {"*" => true}, "get" => {"*" => true}, ... "delete" => {"role:Admin" => true}}
```

#### Bug Fixes

- **FIXED**: `auto_upgrade!` now resets CLPs before applying new ones. Parse Server merges CLP updates rather than replacing them, so old restrictive permissions could persist and cause "Permission denied" errors. Now `auto_upgrade!` first resets CLPs to public defaults, then applies the model's CLP configuration.

- **FIXED**: `as_json(include_defaults: true)` now properly includes all operations even when no explicit `set_default_clp` is called. Previously, models with only `protect_fields` (no operation permissions) would send CLPs without operation keys, causing "Permission denied" errors. Now defaults to public access for all operations when `include_defaults: true`.

- **FIXED**: Test setup for role membership now correctly uses `add_users()` method for adding users to roles (roles use Parse Relations, not Array properties).

### 3.2.0

#### New Features

- **NEW**: Added comprehensive Class-Level Permissions (CLP) support for protecting fields and controlling access at the schema level. CLPs allow you to hide sensitive fields from users based on roles, user ownership, and authentication status.

**DSL for Defining CLPs:**

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

  # Protect fields from certain users
  protect_fields "*", [:internal_notes, :royalty_data]  # Hidden from everyone
  protect_fields "role:Admin", []                        # Admins see everything
  protect_fields "userField:owner", []                   # Owners see their own data
end
```

**Filter Data for Webhook Responses:**

```ruby
# Filter a single object for a user
filtered = song.filter_for_user(current_user, roles: ["Member"])

# Filter an array of results
filtered_results = Song.filter_results_for_user(songs, current_user, roles: user_roles)

# Use a custom or fetched CLP
server_clp = Song.fetch_clp
filtered = song.filter_for_user(current_user, roles: roles, clp: server_clp)
```

**Protected Fields Intersection Logic:**

When a user matches multiple patterns (e.g., public `*`, a role, and `userField:owner`), the protected fields are the **intersection** of all matching patterns. This matches Parse Server's behavior:

```ruby
protect_fields "*", [:owner, :secret, :internal]  # Hide from everyone
protect_fields "role:Admin", [:owner]             # Admins only see owner hidden
protect_fields "userField:owner", []              # Owners see everything

# A user with Admin role matching both "*" and "role:Admin":
# - Intersection: only "owner" is hidden (common to both patterns)
# - "secret" and "internal" are visible (cleared by role pattern)
```

**Push CLPs to Parse Server:**

```ruby
# Automatically includes CLPs in schema upgrades
Song.auto_upgrade!

# Update only CLPs without schema changes
Song.update_clp!

# Fetch current CLPs from server
clp = Song.fetch_clp
clp.find_allowed?("role:Admin")     # => true
clp.protected_fields_for("*")       # => ["internal_notes", "royalty_data"]
```

**Supported Patterns:**

- `"*"` - Public (everyone)
- `"role:RoleName"` - Users with specific role
- `"userField:fieldName"` - Users referenced in a pointer field
- `"authenticated"` - Any authenticated user
- `"userId"` - Specific user by objectId

### 3.1.12

#### New Features

- **NEW**: Added `ends_with` query constraint for matching string fields that end with a specific suffix. This complements the existing `starts_with` and `contains` constraints.

```ruby
# Find files ending with .pdf
Document.where(:filename.ends_with => ".pdf")
# Generates: {"filename": {"$regex": "\\.pdf$", "$options": "i"}}

# Find users with a specific email domain
User.where(:email.ends_with => "@example.com")

# Special regex characters are automatically escaped
Product.where(:sku.ends_with => "v1.0")
```

### 3.1.11

#### Bug Fixes

- **FIXED**: `auto_upgrade!` now skips read-only system classes (`_PushStatus`, `_SCHEMA`) during schema upgrades. These classes are managed automatically by Parse Server and cannot be created or modified via the schema API. Previously, running `rake parse:upgrade` would fail with "Class _PushStatus does not exist" if push notifications hadn't been used yet.

### 3.1.10

#### Performance Improvements

- **IMPROVED**: Aggregation pipeline optimization now automatically merges consecutive `$match` stages. This reduces redundant pipeline stages that can occur when building complex queries from multiple constraint sources.
  - Identical consecutive `$match` stages are deduplicated (removed)
  - Different consecutive `$match` stages are merged using `$and`
  - Non-consecutive `$match` stages (separated by `$lookup`, `$group`, etc.) are preserved

```ruby
# Before optimization (generated pipeline):
[
  { "$match" => { "status" => "active" } },
  { "$match" => { "status" => "active" } },  # Duplicate
  { "$match" => { "category" => "books" } }, # Different
  { "$group" => { "_id" => "$author" } }
]

# After optimization:
[
  { "$match" => { "$and" => [{ "status" => "active" }, { "category" => "books" }] } },
  { "$group" => { "_id" => "$author" } }
]
```

### 3.1.9

#### New Features

- **NEW**: Added `fetch_cache!` method to `Parse::Pointer`. This allows fetching a pointer with caching enabled, matching the API available on `Parse::Object`. Previously, calling `fetch_cache!` on a pointer would raise `NoMethodError`.

```ruby
# Fetch a pointer with caching enabled
capture = capture_pointer.fetch_cache!

# Partial fetch with caching
capture = capture_pointer.fetch_cache!(keys: [:title, :status])

# With includes
capture = capture_pointer.fetch_cache!(keys: [:title], includes: [:project])
```

- **NEW**: Added `cache:` parameter to `Parse::Pointer#fetch`. This allows controlling caching behavior when fetching pointers, consistent with `Parse::Object#fetch!`.

```ruby
# Fetch with full caching (read and write)
capture = pointer.fetch(cache: true)

# Fetch bypassing cache completely
capture = pointer.fetch(cache: false)

# Fetch with write-only cache (skip read, update cache)
capture = pointer.fetch(cache: :write_only)

# Fetch with specific TTL
capture = pointer.fetch(cache: 300)  # Cache for 5 minutes
```

### 3.1.8

#### Bug Fixes

- **FIXED**: Date property parsing now gracefully handles empty strings, whitespace-only strings, and hashes with missing/empty `iso` values. Previously, assigning an empty string (`""`) or a hash like `{"__type":"Date","iso":""}` to a `:date` property would raise `Date::Error: invalid date`. Now these values are converted to `nil` instead of crashing.

- **IMPROVED**: Date string values are now trimmed of leading/trailing whitespace before parsing. A date string like `"  2025-12-04T15:15:05.446Z  "` will now parse correctly instead of potentially failing.

The following date inputs now safely return `nil` instead of raising an error:
- Empty string: `""`
- Whitespace-only string: `"   "`
- Hash with empty iso: `{"__type":"Date","iso":""}`
- Hash with whitespace iso: `{"__type":"Date","iso":"   "}`
- Hash with missing iso: `{"__type":"Date"}`
- Hash with nil iso: `{"__type":"Date","iso":nil}`

### 3.1.7

#### Breaking Changes

- **CHANGED**: Query caching is now opt-in by default. Previously, queries used cache by default (`cache: true`). Now queries do NOT use cache unless explicitly enabled with `cache: true`. This provides more predictable behavior and ensures fresh data by default.

#### New Features

- **NEW**: Added `Parse.default_query_cache` configuration option to control the default caching behavior for queries:
  - `false` (default): Queries do NOT use cache unless explicitly enabled with `cache: true`
  - `true`: Queries use cache by default (opt-out behavior, previous behavior)

```ruby
# Default behavior (opt-in to cache)
Song.first                           # Does NOT use cache
Song.query(cache: true).first        # Explicitly uses cache

# To restore previous behavior (opt-out of cache)
Parse.default_query_cache = true
Song.first                           # Uses cache
Song.query(cache: false).first       # Explicitly bypasses cache
```

- **IMPROVED**: Added informative cache configuration messages during client setup:
  - Warns when a cache store is provided but `:expires` is not set (caching will be disabled)
  - Informs users about opt-in cache behavior and how to enable opt-out mode when caching is enabled

### 3.1.6

#### Code Quality Improvements

- **FIXED**: Resolved circular require warning between `api/all.rb` and `client.rb`. Removed redundant `require_relative` that was causing Ruby's "loading in progress, circular require considered harmful" warning.

- **FIXED**: Resolved 9 additional circular require warnings in model class files (`audience.rb`, `installation.rb`, `product.rb`, `push_status.rb`, `role.rb`, `session.rb`, `user.rb`), `builder.rb`, and `webhooks.rb`. These files are now loaded from their parent files without back-references.

- **FIXED**: Resolved 25+ "method redefined" warnings by changing `attr_accessor` to `attr_writer` or `attr_reader` where custom getters or setters were defined. Affected files include:
  - `client.rb` - `retry_limit`, `client`
  - `client/caching.rb` - `enabled`
  - `client/request.rb` - removed redundant `request_id` getter
  - `api/config.rb` - `config`
  - `api/server.rb` - `server_info`
  - `query.rb` - `table`, `session_token`, `client`
  - `query/operation.rb` - `operators`
  - `query/constraint.rb` - `precedence`
  - `query/ordering.rb` - `field`
  - `model/geopoint.rb` - `latitude`, `longitude`
  - `model/file.rb` - `url`, `default_mime_type`, `force_ssl`
  - `model/acl.rb` - `permissions`
  - `model/push.rb` - `query`, `channels`, `data`
  - `model/object.rb` - `parse_class`
  - `model/core/actions.rb` - `raise_on_save_failure`
  - `model/associations/collection_proxy.rb` - `collection`
  - `model/associations/belongs_to.rb` - `references`
  - `model/associations/has_many.rb` - `relations`
  - `model/classes/user.rb` - `session_token`
  - `webhooks.rb` - `key`

- **FIXED**: Resolved 15+ "assigned but unused variable" warnings by removing unused variables or prefixing with underscore:
  - `api/aggregate.rb` - removed unused `id` variable
  - `query.rb` - removed unused exception variables
  - `query/constraints.rb` - removed unused exception variables (multiple locations)
  - `model/acl.rb` - removed unused exception variables
  - `model/core/builder.rb` - removed unused exception variable
  - `model/core/querying.rb` - prefixed unused variable with underscore
  - `model/core/properties.rb` - removed unused `scope_name` variable
  - `model/validations/uniqueness_validator.rb` - prefixed unused variable
  - `model/associations/has_one.rb` - prefixed unused `ivar` variable
  - `model/classes/user.rb` - removed unused exception variables

- **FIXED**: Resolved 2 "character class has duplicated range" regex warnings in `query.rb` by simplifying `[\w\d]+` to `\w+` (since `\w` already includes digits).

- **FIXED**: Resolved 3 "`&` interpreted as argument prefix" warnings in `collection_proxy.rb` by using explicit parentheses: `collection.each(&block)` instead of `collection.each &block`.

- **UPDATED**: Updated `Parse::Installation` device_type enum to match current Parse Server device types: `ios`, `android`, `osx`, `tvos`, `watchos`, `web`, `expo`, `win`, `other`, `unknown`, `unsupported`. Removed obsolete Windows device types (`winrt`, `winphone`, `dotnet`). This provides automatic scope methods (e.g., `Installation.ios`, `Installation.tvos`, `Installation.unknown`) and predicate methods (e.g., `installation.osx?`, `installation.expo?`, `installation.unsupported?`).

- **NEW**: Added push notification validation in `Parse::Push` when targeting installations directly:
  - Raises `ArgumentError` if an installation object has no `device_token` (required for push delivery)
  - Warns if `device_type` is a known but unsupported type (`win`, `other`, `unknown`, `unsupported`)
  - Warns if `device_type` is an unrecognized value (may not receive push notifications)
  - Added `SUPPORTED_PUSH_DEVICE_TYPES` constant (`ios`, `android`, `osx`, `tvos`, `watchos`, `web`, `expo`)
  - Added `UNSUPPORTED_PUSH_DEVICE_TYPES` constant (`win`, `other`, `unknown`, `unsupported`)

### 3.1.5

#### Improvements

- **NEW**: Added "write-only" cache mode (`:write_only`) for fetch operations. This mode skips reading from cache (always gets fresh data from server) but writes the fresh data back to cache for future cached reads. This is now the default behavior for `fetch!`, `reload!`, and `find` operations.

- **IMPROVED**: `fetch!`, `reload!`, and `find` now use `:write_only` cache mode by default. This ensures you always get fresh data while keeping the cache updated for future `find_cached` or `fetch_cache!` calls. Previously, these operations used cached responses if caching was configured.

- **NEW**: Added `Parse.cache_write_on_fetch` configuration option to control the default caching behavior:
  - `true` (default): Use write-only cache mode - skip cache read, update cache with fresh data
  - `false`: Completely bypass cache (no read or write)

- **NEW**: Added `fetch_cache!` method as a convenience for fetching with full caching enabled (read from and write to cache).

- **NEW**: Added `find_cached` class method as a convenience for finding objects with full caching enabled.

```ruby
# Default behavior: write-only cache mode
# - Always gets fresh data from server (no cache read)
# - Updates cache with fresh data for future cached reads
song.fetch!                     # Fresh data, updates cache
song.reload!                    # Fresh data, updates cache
Song.find(id)                   # Fresh data, updates cache

# Full caching (read from and write to cache)
song.fetch!(cache: true)        # Use cached data if available
song.reload!(cache: true)       # Use cached data if available
Song.find(id, cache: true)      # Use cached data if available

# Convenience methods for full caching
song.fetch_cache!               # Fetch with full caching
song.fetch_cache!(keys: [:title])  # Partial fetch with caching
Song.find_cached(id)            # Find with full caching
Song.find_cached(id1, id2)      # Find multiple with caching

# Completely bypass cache (no read or write)
song.fetch!(cache: false)       # Bypass cache entirely
song.reload!(cache: false)      # Bypass cache entirely
Song.find(id, cache: false)     # Bypass cache entirely

# Disable write-only mode globally
Parse.cache_write_on_fetch = false
# Now fetch!/reload!/find will bypass cache entirely (same as cache: false)
```

#### Bug Fixes

- **FIXED**: Connection pooling `pool_size` option now works correctly. Previously, configuring `pool_size` in the `connection_pooling` hash would raise `NoMethodError: undefined method 'pool_size='` because `Net::HTTP::Persistent` only accepts `pool_size` as a constructor argument, not a setter. The fix passes `pool_size` as a keyword argument to the Faraday adapter instead of attempting to set it in the configuration block.

```ruby
# This now works correctly
Parse.setup(
  server_url: "https://your-server.com/parse",
  application_id: ENV['PARSE_APP_ID'],
  api_key: ENV['PARSE_REST_API_KEY'],
  connection_pooling: {
    pool_size: 5,        # Now correctly passed to Net::HTTP::Persistent constructor
    idle_timeout: 60,    # Set via setter (works as before)
    keep_alive: 60       # Set via setter (works as before)
  }
)
```

### 3.1.4

#### ACL Query Convenience Methods

- **NEW**: Added intuitive convenience methods for common ACL queries. These methods make it easy to find documents based on their permission status.

```ruby
# Find publicly accessible documents
Song.query.publicly_readable.results
Song.query.publicly_writable.results  # Security audit!

# Find master-key-only documents (empty permissions)
Song.query.privately_readable.results
Song.query.master_key_read_only.results  # Alias
Song.query.privately_writable.results
Song.query.master_key_write_only.results  # Alias

# Find completely private documents (no read AND no write)
Song.query.private_acl.results
Song.query.master_key_only.results  # Alias

# Find non-public documents
Song.query.not_publicly_readable.results
Song.query.not_publicly_writable.results
```

- **NEW**: ACL query options can now be passed as hash keys in `where`, `first`, `all`, etc.

```ruby
# Use readable_by:/writable_by: as hash keys
Song.where(readable_by: current_user, genre: "Rock").results
Song.first(writable_by: admin_role)
Song.all(publicly_readable: true)
Song.query(readable_by_role: "Admin", limit: 10).results

# Boolean flags for convenience methods
Song.all(privately_readable: true)
Song.all(not_publicly_writable: true)
Song.all(private_acl: true)  # Finds master-key-only documents
```

#### Role Hierarchy Expansion

- **NEW**: ACL queries now automatically expand role hierarchies. When you query with a `Parse::Role` object, the query includes all child roles (permissions flow DOWN the hierarchy).

```ruby
# Role hierarchy: Admin -> Moderator -> Editor
admin_role = Parse::Role.find_by_name("Admin")

# This query finds documents readable by Admin, Moderator, AND Editor
# because Admin has those roles as children
Song.query.readable_by(admin_role).results
```

- **NEW**: When querying with a `Parse::User`, the query automatically fetches all the user's roles AND expands their role hierarchies.

```ruby
user = Parse::User.current

# Finds documents readable by:
# - The user's ID directly
# - All roles the user belongs to
# - All child roles of those roles
Song.query.readable_by(user).results
```

#### ACL Constraint Consolidation

- **IMPROVED**: Consolidated `readable_by` and `writable_by` constraint registration. `ACLReadableByConstraint` and `ACLWritableByConstraint` are now the primary handlers, providing smart type handling with automatic role prefix addition and role hierarchy expansion.

```ruby
# Pass role objects - automatically adds "role:" prefix
Song.query.readable_by(admin_role)  # role:Admin

# Pass users - automatically includes all their roles
Song.query.readable_by(current_user)  # userId, role:Admin, role:Editor, ...

# Pass strings for raw permission values
Song.query.readable_by("role:Admin")  # Explicit role prefix
Song.query.readable_by("userId123")   # User ID
Song.query.readable_by("*")           # Public access
```

- **CLARIFIED**: The `privately_readable`/`privately_writable` queries now correctly look for documents with empty `_rperm`/`_wperm` arrays only. If `_rperm` is missing/undefined, Parse Server treats it as publicly readable (not private).

#### Code Quality Improvements

- **IMPROVED**: Extracted shared `AclConstraintHelpers` module for ACL query constraint classes (`ReadableByConstraint`, `WriteableByConstraint`, `NotReadableByConstraint`, `NotWriteableByConstraint`). This eliminates ~120 lines of duplicated `normalize_acl_keys` code and makes it easier to maintain ACL permission normalization logic.

```ruby
# All ACL constraints now share the same normalization logic via module inclusion
module Parse::Constraint::AclConstraintHelpers
  def normalize_acl_keys(value)
    # Handles Parse::User, Parse::Role, Parse::Pointer, symbols, strings
    # Returns normalized permission keys for ACL queries
  end
end

class ReadableByConstraint < Constraint
  include AclConstraintHelpers
  # ...
end
```

- **FIXED**: The `changed` method now uses `dup` before modifying the result array, preventing potential interference with ActiveModel's internal dirty tracking state.

```ruby
# Before: Could mutate ActiveModel's internal array
def changed
  result = super
  result = result - ["acl"] if ...
  result
end

# After: Safely operates on a copy
def changed
  result = super.dup
  result.delete("acl") if ...
  result
end
```

- **FIXED**: Added nil-safe check in `acl_changed?` to prevent `NoMethodError` when `@acl` is nil.

```ruby
# Before: Could raise NoMethodError if @acl is nil
acl_current_json = @acl.respond_to?(:as_json) ? @acl.as_json : @acl

# After: Safe navigation operator handles nil
acl_current_json = @acl&.respond_to?(:as_json) ? @acl.as_json : @acl
```

### 3.1.3

#### Private ACL by Default

- **NEW**: Added `default_acl_private` class setting and `private_acl!` convenience method to make new objects private by default (no public access, master key only).

```ruby
class PrivateDocument < Parse::Object
  private_acl!  # or: self.default_acl_private = true
end

doc = PrivateDocument.new(title: "Secret")
doc.acl.as_json  # => {} (no permissions, master key only)
doc.save  # Only accessible with master key
```

- **NEW**: Added `Parse::ACL.private` class method to create an empty ACL with no permissions.

```ruby
acl = Parse::ACL.private
acl.as_json  # => {}
```

#### ACL Query Improvements

- **FIXED**: `readable_by("*")` and `readable_by("public")` queries now work correctly. The aggregation pipeline automatically uses MongoDB direct access when querying internal ACL fields (`_rperm`, `_wperm`) that Parse Server blocks through its REST API.

```ruby
# Find all publicly readable documents
Post.query.readable_by("*").results
Post.query.readable_by("public").results

# Find all publicly writable documents
Post.query.writable_by("*").results
Post.query.writable_by("public").results
```

- **NEW**: Added support for querying objects with empty/no ACL permissions using `[]` or `"none"`. This finds objects that can only be accessed with the master key.

```ruby
# Find objects with NO read permissions (master key only)
Post.query.readable_by([]).results
Post.query.readable_by("none").results

# Find objects with NO write permissions (read-only, master key to write)
Post.query.writable_by([]).results
Post.query.writable_by("none").results
```

- **NEW**: Added `not_readable_by` and `not_writeable_by` constraints to find objects NOT accessible by specific users/roles.

```ruby
# Find objects hidden from a specific user
Post.query.where(:ACL.not_readable_by => current_user).results

# Find objects NOT publicly readable
Post.query.where(:ACL.not_readable_by => "*").results
Post.query.where(:ACL.not_readable_by => :public).results

# Find objects NOT writable by a role
Post.query.where(:ACL.not_writeable_by => "role:Editor").results
```

- **NEW**: Added `private_acl` / `master_key_only` constraint to find objects with completely empty ACLs.

```ruby
# Find all private objects (empty ACL, master key only)
Post.query.where(:ACL.private_acl => true).results
Post.query.where(:ACL.master_key_only => true).results

# Find all non-private objects (have some permissions)
Post.query.where(:ACL.private_acl => false).results
```

- **NEW**: Added `mongo_direct` option to ACL query methods for explicit control over query execution path.

```ruby
# Force MongoDB direct query (bypasses Parse Server)
Post.query.readable_by([], mongo_direct: true).results

# Force Parse Server aggregation (disable auto-detection)
Post.query.readable_by("user123", mongo_direct: false).results
```

#### ACL Dirty Tracking Improvements

- **FIXED**: `acl_was` now correctly captures the ACL state before in-place modifications. Previously, modifying an ACL in place (via `apply`, `apply_role`, etc.) caused `acl_was` to return the same mutated object as `acl`, making them appear identical.

```ruby
# Before fix: acl_was showed mutated state (wrong)
obj.acl = Parse::ACL.new
obj.clear_changes!
obj.acl.apply(:public, true, false)
obj.acl_was.as_json  # Was: {"*"=>{"read"=>true}} (same as acl!)

# After fix: acl_was shows original state (correct)
obj.acl_was.as_json  # Now: {} (original empty state)
```

- **NEW**: `acl_changed?` now compares actual ACL content, not just object references. Setting an ACL to identical values no longer marks the object as dirty.

```ruby
# Fetch object with existing ACL
membership = Membership.find(id)
original_acl = membership.acl.as_json  # {"*"=>{"read"=>true}, ...}
membership.clear_changes!

# Rebuild ACL to same values (e.g., in before_save hook)
membership.acl = Parse::ACL.new
membership.acl.apply(:public, true, false)
# ... rebuild to same permissions ...

# Object is NOT dirty if ACL content is identical
membership.acl_changed?  # => false (content is the same)
membership.dirty?        # => false (no actual changes)
```

- **NEW**: New objects always include ACL in changes (required for first save to server), even if content matches default.

#### Active Model Consistency

- **NEW**: Added `create!` class method for Active Model consistency. This is equivalent to `new(attrs).save!` and raises `Parse::RecordNotSaved` on failure.

```ruby
# Create and save in one call (raises on failure)
song = Song.create!(title: "New Song", artist: "Artist")
```

---

### 3.1.2

#### Validation Context Support

- **NEW**: The `save()` method now passes validation context (`:create` or `:update`) to validations and callbacks, matching ActiveRecord behavior. This enables context-aware validations and callbacks.

- **NEW**: `before_validation`, `after_validation`, and `around_validation` callbacks now support the `on:` option to run only on create or update:

```ruby
class Task < Parse::Object
  property :name, :string, required: true
  property :status, :string, required: true
  property :completed_at, :date

  # Set defaults only when creating new objects
  before_validation :set_defaults, on: :create

  # Require completion date only when updating
  validates :completed_at, presence: true, on: :update, if: -> { status == "completed" }

  def set_defaults
    self.status ||= "pending"
  end
end

# New object - before_validation on: :create runs, sets status to "pending"
task = Task.new(name: "My Task")
task.save  # status is automatically set to "pending"

# Existing object - before_validation on: :create does NOT run
task.status = "completed"
task.save  # completed_at validation runs because it's an update
```

This is particularly useful for setting default values before validation runs, solving the issue where `before_create` callbacks run after validation.

#### Bug Fixes

- **FIXED**: Query methods `first`, `latest`, and `last_updated` now properly accept keyword-style constraint options like `keys:`, `includes:`, etc. Previously, adding the `mongo_direct:` keyword argument broke Ruby's argument parsing, causing `ArgumentError: unknown keyword: :keys` when using these options.

```ruby
# These all work again:
Song.first(keys: [:title, :artist])
Song.query.first(keys: [:title], includes: [:album])
Song.query.latest(5, keys: [:title, :created_at])
Song.query.last_updated(keys: [:title])
```

---

### 3.1.1

#### Serialization Options for `as_json`

Added `:exclude_keys` option as an alias for `:except` to exclude specific fields when serializing Parse objects to JSON:

```ruby
# Exclude specific fields from JSON output
song.as_json(exclude_keys: [:created_at, :updated_at, :acl])
# => {"__type"=>"Object", "className"=>"Song", "title"=>"My Song", ...}

# Also works with the existing :except option
song.as_json(except: [:created_at, :updated_at])

# Combine with :only to limit fields
song.as_json(only: [:title, :artist])
```

**Note:** When both `:except` and `:exclude_keys` are provided, `:except` takes precedence. When `:only` is provided, it takes precedence over both exclusion options.

#### MongoDB Date Conversion Helper

New `Parse::MongoDB.to_mongodb_date` method for converting date values to UTC Time objects suitable for MongoDB queries. MongoDB stores all dates in UTC, and this helper ensures consistent date handling when building aggregation pipelines or direct queries.

```ruby
# Convert various date types to UTC Time for MongoDB
Parse::MongoDB.to_mongodb_date(Date.new(2024, 1, 15))
# => 2024-01-15 00:00:00 UTC

Parse::MongoDB.to_mongodb_date(Time.now)
# => 2024-12-01 12:30:45 UTC (converted to UTC)

Parse::MongoDB.to_mongodb_date("2024-01-15")
# => 2024-01-15 00:00:00 UTC

Parse::MongoDB.to_mongodb_date("2024-01-15T10:30:00-05:00")
# => 2024-01-15 15:30:00 UTC (timezone converted)

# Unix timestamps also supported
Parse::MongoDB.to_mongodb_date(1718451045)
# => 2024-06-15 12:30:45 UTC
```

**Supported input types:**
- `Time` - converted to UTC
- `DateTime` - converted to UTC Time
- `Date` - converted to midnight UTC
- `String` - parsed (ISO 8601 or date string) and converted to UTC
- `Integer` - treated as Unix timestamp
- `nil` - returns nil

**Example usage in aggregation pipelines:**
```ruby
# Get records from the last 30 days
cutoff = Parse::MongoDB.to_mongodb_date(Date.today - 30)
pipeline = [{ "$match" => { "_created_at" => { "$gte" => cutoff } } }]
results = Song.query.aggregate(pipeline, mongo_direct: true).results
```

#### Documentation: Optional Mongo Gem

The `mongo` gem is now explicitly documented as an optional dependency in the gemspec. Users who want to use MongoDB direct query features (`Parse::MongoDB`, `Parse::AtlasSearch`, `mongo_direct` query methods) should add it to their Gemfile:

```ruby
gem 'mongo', '~> 2.18'
```

The gem is loaded at runtime only when MongoDB features are used, so it doesn't affect users who don't need these features.

#### Bug Fixes

- **FIXED**: ActiveSupport constant resolution issue where `Date`, `Time`, and `DateTime` weren't matching correctly in `case` statements when ActiveSupport was loaded. Now uses explicit top-level constants (`::Date`, `::Time`, `::DateTime`) to ensure correct matching regardless of what other gems are loaded.

---

### 3.1.0

#### Enhanced Role Management

New helper methods for managing Parse roles and role hierarchies:

**Class Methods:**
```ruby
# Find a role by name
admin = Parse::Role.find_by_name("Admin")

# Find or create a role
moderator = Parse::Role.find_or_create("Moderator")

# Get all role names
Parse::Role.all_names  # => ["Admin", "Moderator", "User"]

# Check if role exists
Parse::Role.exists?("Admin")  # => true
```

**User Management:**
```ruby
role = Parse::Role.find_by_name("Admin")

# Add/remove single user
role.add_user(user).save
role.remove_user(user).save

# Add/remove multiple users
role.add_users(user1, user2, user3).save
role.remove_users(user1, user2).save

# Check membership
role.has_user?(user)  # => true
```

**Role Hierarchy:**
```ruby
admin = Parse::Role.find_by_name("Admin")
moderator = Parse::Role.find_by_name("Moderator")

# Create hierarchy (Admins inherit Moderator permissions)
admin.add_child_role(moderator).save

# Query hierarchy
admin.has_child_role?(moderator)  # => true
admin.all_child_roles             # => [moderator, ...]
admin.all_users                   # => Users from this role AND child roles

# Count methods
role.users_count         # Direct users count
role.child_roles_count   # Direct child roles count
role.total_users_count   # All users including child roles
```

#### HTTP 429 Retry-After Header Support

The client now respects the `Retry-After` HTTP header when handling rate limit (429) responses. This allows the server to specify exactly how long to wait before retrying:

```ruby
# Automatic - client will wait for the duration specified in Retry-After header
# before retrying, instead of using default exponential backoff

# The Response object now exposes:
response.headers              # => HTTP response headers
response.retry_after          # => Seconds to wait (parsed from Retry-After header)
```

Supports both formats:
- Integer seconds: `Retry-After: 30`
- HTTP-date: `Retry-After: Wed, 21 Oct 2025 07:28:00 GMT`

#### MongoDB Read Preference Support

Direct read queries to secondary replicas for load balancing:

```ruby
# Fluent API
songs = Song.query.read_pref(:secondary).where(genre: "Rock").results

# In conditions hash
songs = Song.query(genre: "Rock", read_preference: :secondary_preferred).results

# Valid values: :primary, :primary_preferred, :secondary, :secondary_preferred, :nearest
```

The read preference is sent via the `X-Parse-Read-Preference` header and is useful for:
- Load balancing read operations across replica set members
- Reading from geographically closer secondaries
- Reducing load on the primary for read-heavy applications

#### Schema Introspection and Migration Tools

New `Parse::Schema` module for inspecting and migrating Parse schemas:

**Schema Introspection:**
```ruby
# Fetch all schemas
schemas = Parse::Schema.all
schemas.each { |s| puts s.class_name }

# Fetch specific schema
schema = Parse::Schema.fetch("Song")
schema.field_names      # => ["objectId", "title", "duration", ...]
schema.field_type(:title)  # => :string
schema.pointer_target(:artist)  # => "Artist"
schema.has_field?(:title)  # => true
schema.builtin?            # => false (true for _User, _Role, etc.)
```

**Schema Comparison:**
```ruby
# Compare local model with server schema
diff = Parse::Schema.diff(Song)
diff.server_exists?        # => true
diff.in_sync?              # => false
diff.missing_on_server     # => { duration: :integer }
diff.missing_locally       # => { legacy_field: :string }
diff.type_mismatches       # => { count: { local: :integer, server: :string } }
diff.summary               # => Human-readable diff summary
```

**Schema Migration:**
```ruby
# Generate migration
migration = Parse::Schema.migration(Song)
migration.needed?          # => true
migration.preview          # => Human-readable migration plan
migration.operations       # => [{ action: :add_field, field: "duration", type: "Number" }]

# Apply migration (dry run first!)
result = migration.apply!(dry_run: true)

# Apply for real
result = migration.apply!
result[:status]   # => :success
result[:applied]  # => [{ action: :add_field, field: "duration", type: :integer }]
result[:errors]   # => []
```

#### MongoDB Atlas Search Integration

Full-text search, autocomplete, and faceted search capabilities via MongoDB Atlas Search. This feature bypasses Parse Server to query MongoDB directly for high-performance search operations.

##### Core Features

**Full-Text Search** with relevance scoring:
```ruby
# Configure
Parse::MongoDB.configure(uri: "mongodb+srv://...", enabled: true)
Parse::AtlasSearch.configure(enabled: true, default_index: "default")

# Search with scoring
result = Parse::AtlasSearch.search("Song", "love ballad")
result.each { |song| puts "#{song.title} (score: #{song.search_score})" }

# Advanced options
result = Parse::AtlasSearch.search("Song", "love",
  fields: [:title, :lyrics],
  fuzzy: true,
  limit: 20,
  highlight_field: :title
)
```

**Autocomplete** for search-as-you-type:
```ruby
result = Parse::AtlasSearch.autocomplete("Song", "Lov", field: :title)
result.suggestions  # => ["Love Story", "Lovely Day", "Love Me Do"]
```

**Faceted Search** with category counts:
```ruby
facets = {
  genre: { type: :string, path: :genre, num_buckets: 10 },
  decade: { type: :number, path: :year, boundaries: [1970, 1980, 1990, 2000, 2010, 2020] }
}
result = Parse::AtlasSearch.faceted_search("Song", "rock", facets)
result.facets[:genre]  # => [{ value: "Rock", count: 150 }, ...]
result.total_count     # => 195
```

##### Search Builder (Fluent API)

Build complex search queries with the chainable SearchBuilder:
```ruby
builder = Parse::AtlasSearch::SearchBuilder.new(index_name: "default")
builder
  .text(query: "love", path: :title, fuzzy: true)
  .phrase(query: "broken heart", path: :lyrics, slop: 2)
  .range(path: :plays, gte: 1000)
  .with_highlight(path: :title)
  .with_count

search_stage = builder.build
```

**Supported operators:** `text`, `phrase`, `autocomplete`, `wildcard`, `regex`, `range`, `exists`
**Compound queries:** Multiple operators automatically combined with compound/must

##### Query Integration

Atlas Search methods added to `Parse::Query`:
```ruby
# Full-text search
songs = Song.query.atlas_search("love ballad", fields: [:title], limit: 10)

# Autocomplete
suggestions = Song.query.atlas_autocomplete("Lov", field: :title)

# Faceted search
result = Song.query.atlas_facets("rock", { genre: { type: :string, path: :genre } })
```

##### Index Management

Automatic index discovery and caching:
```ruby
# List indexes (cached)
indexes = Parse::AtlasSearch.indexes("Song")

# Check if index is ready
Parse::AtlasSearch.index_ready?("Song", "default")

# Force refresh
Parse::AtlasSearch.refresh_indexes("Song")
```

##### Creating Atlas Search Indexes

Atlas Search requires indexes to be created on your MongoDB Atlas cluster (or Atlas Local for development). Indexes define which fields are searchable and how they should be analyzed.

**Via MongoDB Atlas UI:**

1. Navigate to your Atlas cluster → **Atlas Search** tab
2. Click **Create Search Index**
3. Select your database and collection (Parse uses the database name from your connection string)
4. Choose **JSON Editor** for full control, or **Visual Editor** for guided setup
5. Define your index (see examples below)

**Via MongoDB Shell (mongosh):**

```javascript
// Connect to your Atlas cluster
mongosh "mongodb+srv://cluster.mongodb.net/your_database"

// Create a basic search index
db.Song.createSearchIndex("default", {
  mappings: {
    dynamic: true  // Index all fields automatically
  }
});

// Check index status (wait for "queryable: true")
db.Song.getSearchIndexes();
```

**Common Index Definitions:**

*Basic full-text search on specific fields:*
```javascript
{
  "mappings": {
    "dynamic": false,
    "fields": {
      "title": { "type": "string", "analyzer": "lucene.standard" },
      "description": { "type": "string", "analyzer": "lucene.standard" },
      "tags": { "type": "string", "analyzer": "lucene.standard" }
    }
  }
}
```

*Autocomplete support (search-as-you-type):*
```javascript
{
  "mappings": {
    "fields": {
      "title": [
        { "type": "string", "analyzer": "lucene.standard" },
        {
          "type": "autocomplete",
          "analyzer": "lucene.standard",
          "tokenization": "edgeGram",
          "minGrams": 2,
          "maxGrams": 15
        }
      ]
    }
  }
}
```

*Faceted search with string and numeric facets:*
```javascript
{
  "mappings": {
    "dynamic": true,
    "fields": {
      "genre": [
        { "type": "string" },
        { "type": "stringFacet" }
      ],
      "year": [
        { "type": "number" },
        { "type": "numberFacet" }
      ],
      "rating": [
        { "type": "number" },
        { "type": "numberFacet" }
      ]
    }
  }
}
```

*Complete example with all features:*
```javascript
{
  "mappings": {
    "dynamic": true,
    "fields": {
      "title": [
        { "type": "string", "analyzer": "lucene.standard" },
        { "type": "autocomplete", "tokenization": "edgeGram", "minGrams": 2, "maxGrams": 15 }
      ],
      "artist": { "type": "string", "analyzer": "lucene.standard" },
      "lyrics": { "type": "string", "analyzer": "lucene.english" },
      "genre": [
        { "type": "string" },
        { "type": "stringFacet" }
      ],
      "plays": [
        { "type": "number" },
        { "type": "numberFacet" }
      ],
      "releaseDate": { "type": "date" }
    }
  }
}
```

**Parse Collection Names:**

Parse Server stores collections with their class names. Built-in classes have underscore prefixes:
- `_User` → User accounts
- `_Role` → Roles
- `_Session` → Sessions
- `Song` → Custom class "Song" (no prefix)

**Verifying Index Status:**

```ruby
# Check if index is ready before searching
if Parse::AtlasSearch.index_ready?("Song", "default")
  result = Parse::AtlasSearch.search("Song", "query")
else
  puts "Index still building..."
end

# List all indexes with their status
indexes = Parse::AtlasSearch.indexes("Song")
indexes.each do |idx|
  puts "#{idx['name']}: queryable=#{idx['queryable']}"
end
```

**Local Development with Atlas Local:**

For local development without an Atlas cluster, use MongoDB Atlas Local:

```bash
# Start Atlas Local via Docker
docker run -d -p 27017:27017 mongodb/mongodb-atlas-local:latest

# Or use the provided docker-compose
docker-compose -f scripts/docker/docker-compose.atlas.yml up -d
```

See `scripts/docker/atlas-init.js` for a complete example of seeding data and creating indexes programmatically.

##### Result Classes

- `Parse::AtlasSearch::SearchResult` - Enumerable results with scores
- `Parse::AtlasSearch::AutocompleteResult` - Suggestions with optional full objects
- `Parse::AtlasSearch::FacetedResult` - Results, facets, and total count

##### Error Classes

- `Parse::AtlasSearch::NotAvailable` - Atlas Search not configured
- `Parse::AtlasSearch::IndexNotFound` - Search index doesn't exist
- `Parse::AtlasSearch::InvalidSearchParameters` - Invalid search parameters

#### Direct MongoDB Query Methods

New query methods for executing queries directly against MongoDB, bypassing Parse Server for improved performance:

**Basic Usage:**
```ruby
# Configure MongoDB direct access
Parse::MongoDB.configure(uri: "mongodb://localhost:27017/parse", enabled: true)

# Execute query directly against MongoDB - returns Parse objects
songs = Song.query(:plays.gt => 1000).results_direct

# Get first result directly
song = Song.query(:plays.gt => 1000).order(:plays.desc).first_direct

# Get count directly
count = Song.query(:plays.gt => 1000).count_direct

# Get first N results
top_songs = Song.query(:plays.gt => 1000).order(:plays.desc).first_direct(5)
```

**Supported Operators:**
All standard query operators work with MongoDB direct:
- Comparison: `gt`, `gte`, `lt`, `lte`, `ne`
- Array: `in`, `nin`, `contains_all`, `size`, `empty_or_nil`, `not_empty`
- String: `like`, `starts_with`, `ends_with`, regex patterns
- Date: Range queries, comparisons with Time/DateTime objects
- Logical: `$and`, `$or`, `$nor`
- Relational: `in_query`, `not_in_query` (with aggregation pipeline)

```ruby
# Date range queries
future_events = Event.query(:event_date.gt => Time.now).results_direct

# Array size queries
popular = Song.query(:tags.size => 3).results_direct

# Regex queries
iphones = Product.query(:name.like => /iphone/i).results_direct

# Complex queries with in_query + empty_or_nil
songs = Song.query(
  :artist.in_query => Artist.query(:verified => true),
  :tags.empty_or_nil => false
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
```

**Raw Results:**
```ruby
# Get raw Parse-formatted hashes instead of objects
hashes = Song.query(:plays.gt => 1000).results_direct(raw: true)
```

**Performance Benefits:**
- Bypasses Parse Server REST API overhead
- Direct MongoDB aggregation pipeline execution
- Automatic pointer resolution with `$lookup`
- Native BSON date handling
- Ideal for read-heavy operations and analytics

#### Direct MongoDB Access

New `Parse::MongoDB` module for direct MongoDB queries bypassing Parse Server:

```ruby
# Configure
Parse::MongoDB.configure(uri: "mongodb://localhost:27017/parse", enabled: true)

# Direct queries
docs = Parse::MongoDB.find("Song", { plays: { "$gt" => 1000 } }, limit: 10)

# Aggregation pipelines
results = Parse::MongoDB.aggregate("Song", [
  { "$match" => { "genre" => "Rock" } },
  { "$group" => { "_id" => "$artist", "total" => { "$sum" => "$plays" } } }
])

# List Atlas Search indexes
indexes = Parse::MongoDB.list_search_indexes("Song")
```

**Features:**
- Direct `find` and `aggregate` operations
- Automatic MongoDB-to-Parse document conversion
- ACL format conversion (r/w → read/write)
- Pointer field handling (_p_fieldName → fieldName)
- Date type conversion

#### Keys Projection with mongo_direct

The `keys` method now works with `mongo_direct` queries, returning partially fetched objects:

```ruby
# Only fetch specific fields - returns partially fetched objects
songs = Song.query(:genre => "Rock")
            .keys(:title, :plays)
            .results(mongo_direct: true)

song = songs.first
song.title              # => "My Song"
song.plays              # => 500
song.partially_fetched? # => true
song.fetched_keys       # => [:title, :plays, :id, :objectId]
```

Required fields (`objectId`, `createdAt`, `updatedAt`, `ACL`) are always included automatically.

#### AggregationResult for Custom Aggregation Output

Custom aggregation results (from `$group`, `$project`, etc.) now return `AggregationResult` objects that support both hash access and method access:

```ruby
pipeline = [
  { "$group" => { "_id" => "$genre", "totalPlays" => { "$sum" => "$playCount" } } }
]
results = Song.query.aggregate(pipeline, mongo_direct: true).results

# Method access (snake_case)
results.first.total_plays  # => 5000

# Hash access (original key also works)
results.first["totalPlays"] # => 5000
results.first[:total_plays] # => 5000
```

- Standard Parse documents (with `objectId`) are returned as `Parse::Object` instances
- Custom aggregation output is wrapped in `AggregationResult`
- Field names automatically converted from camelCase to snake_case

#### Aggregation Pipeline Field Conventions

When writing aggregation pipelines for `mongo_direct`, use MongoDB's native field names:

| Field Type | Ruby Property | MongoDB Field |
|------------|---------------|---------------|
| Regular | `release_date` | `releaseDate` |
| Pointer | `artist` | `_p_artist` |
| Built-in dates | `created_at` | `_created_at` |
| Field reference | - | `$releaseDate` |

```ruby
# Use MongoDB field names in pipelines
pipeline = [
  { "$match" => { "releaseDate" => { "$lt" => Time.now } } },
  { "$group" => { "_id" => "$_p_artist", "total" => { "$sum" => "$playCount" } } }
]
results = Song.query.aggregate(pipeline, mongo_direct: true).results

# Results come back with snake_case access
results.first.total  # => 5000
```

**Date comparisons:** MongoDB stores dates in UTC. For date-only comparisons, use `Time.utc(year, month, day)`:

```ruby
cutoff = Time.utc(2024, 1, 1)
pipeline = [{ "$match" => { "releaseDate" => { "$gte" => cutoff } } }]
```

#### ACL Filtering with mongo_direct

Filter objects by ACL permissions using MongoDB's `_rperm` and `_wperm` fields directly:

**`readable_by` / `writable_by`** - Exact permission strings (no modification):
```ruby
# By user ID (exact match)
Song.query.readable_by("user123").results(mongo_direct: true)

# By role with explicit prefix
Song.query.readable_by("role:Admin").results(mongo_direct: true)

# By user object (auto-fetches user's roles)
Song.query.readable_by(current_user).results(mongo_direct: true)

# Special aliases
Song.query.readable_by("public")  # Alias for "*" (public access)
Song.query.readable_by("none")    # Objects with empty _rperm (master key only)
```

**`readable_by_role` / `writable_by_role`** - Automatically adds "role:" prefix:
```ruby
# By role name (adds "role:" prefix automatically)
Song.query.readable_by_role("Admin").results(mongo_direct: true)

# By Role object
Song.query.readable_by_role(admin_role).results(mongo_direct: true)

# Multiple roles
Song.query.writable_by_role(["Admin", "Editor"]).results(mongo_direct: true)
```

**Key differences:**
- `readable_by("Admin")` → queries for exact string "Admin" in `_rperm`
- `readable_by_role("Admin")` → queries for "role:Admin" in `_rperm`
- Public access (`*`) is always included in permission checks
- Works with `mongo_direct: true` for direct MongoDB queries

#### Docker Support for Atlas Search Testing

New Docker Compose configuration for local Atlas Search testing:

```bash
# Start Atlas Local with search support
docker-compose -f scripts/docker/docker-compose.atlas.yml up -d

# Run tests
ATLAS_URI="mongodb://localhost:27020/parse_atlas_test?directConnection=true" \
  ruby -Ilib:test test/lib/parse/atlas_search_integration_test.rb
```

**New files:**
- `scripts/docker/docker-compose.atlas.yml` - Docker setup for Atlas Local
- `scripts/docker/atlas-init.js` - Seeds test data and creates search indexes

**Note:** Requires the `mongo` gem. Add `gem 'mongo'` to your Gemfile.

### 3.0.2

#### Push Notification Enhancements

##### User Targeting Methods

New methods to target push notifications to specific users by their user object or objectId:

```ruby
# Target a single user
Parse::Push.to_user(current_user).with_alert("Hello!").send!
Parse::Push.to_user_id("abc123").with_alert("Hello!").send!

# Target multiple users
Parse::Push.to_users(user1, user2, user3).with_alert("Group message!").send!

# Arrays also work with singular methods
Parse::Push.to_user([user1, user2]).with_alert("Hello!").send!
```

**New Methods:**
- `to_user(user)` - Target a user (accepts `Parse::User`, pointer hash, objectId string, or array)
- `to_user_id(user_id)` - Target a user by objectId
- `to_users(*users)` - Target multiple users

##### Installation Targeting Methods

New methods to target push notifications to specific device installations:

```ruby
# Target a single installation
Parse::Push.to_installation(device).with_alert("Hello!").send!
Parse::Push.to_installation_id("xyz789").with_alert("Hello!").send!

# Target multiple installations
Parse::Push.to_installations(device1, device2).with_alert("Hello devices!").send!

# Arrays also work with singular methods
Parse::Push.to_installation([device1, device2]).with_alert("Hello!").send!
```

**New Methods:**
- `to_installation(installation)` - Target an installation (accepts `Parse::Installation`, hash, objectId string, or array)
- `to_installation_id(installation_id)` - Target an installation by objectId
- `to_installations(*installations)` - Target multiple installations

All methods support the fluent builder pattern and have both instance and class method versions.

#### Bug Fixes

##### Array Constraint Field Name Formatting

Fixed critical issue where array constraints (`empty_or_nil`, `not_empty`, `set_equals`, `eq_array`, etc.) were not correctly formatting field names for MongoDB aggregation queries. This caused queries to fail when:

- Using property names with snake_case that map to camelCase in Parse (e.g., `topic_list` → `topicList`)
- Combining array constraints with other query constraints (e.g., `Model.query(category: 'x', :topics.empty_or_nil => true)`)

**Fixes applied:**
- All 13 array constraints now use `Parse::Query.format_field` for proper field name conversion:
  - `set_equals` / `eq_set` - Match arrays with same elements (any order)
  - `eq_array` - Match arrays with exact order
  - `not_set_equals` / `neq_set` - Match arrays that differ
  - `neq_array` - Match arrays with different order/elements
  - `subset_of` - Match arrays that are subsets
  - `superset_of` - Match arrays that are supersets
  - `set_intersection` / `intersects` - Match arrays with common elements
  - `set_disjoint` / `disjoint` - Match arrays with no common elements
  - `empty_or_nil` - Match empty, nil, or missing arrays
  - `not_empty` - Match non-empty arrays
  - `arr_empty` - Match empty arrays
  - `arr_nempty` - Match non-empty arrays
  - `size` - Match arrays by size
- `build_aggregation_pipeline` now merges all `$match` stages into a single stage with `$and`
- `GroupBy.pipeline` uses the same merging logic for consistency
- `empty_or_nil` constraint now uses explicit `$eq` operators for more reliable MongoDB matching

**Before (broken):**
```ruby
# This returned incorrect results when topics: [] existed
Report.query(category: 'reports', :topics.empty_or_nil => true).count
# => over-counted or returned wrong results
```

**After (fixed):**
```ruby
# Now correctly matches documents where topics is [], nil, or missing
Report.query(category: 'reports', :topics.empty_or_nil => true).count
# => correct count matching .all.count
```

### 3.0.1

#### Agent Enhancements

##### Environment Variable Gating for MCP

The MCP server now requires an environment variable to be set for additional safety. This prevents accidental enablement in production.

```ruby
# Step 1: Set environment variable
# PARSE_MCP_ENABLED=true

# Step 2: Enable in code
Parse.mcp_server_enabled = true
Parse::Agent.enable_mcp!(port: 3001)
```

- Requires `PARSE_MCP_ENABLED=true` in environment AND `Parse.mcp_server_enabled = true` in code
- Startup warning when ENV is set but code flag isn't
- Helpful error messages showing exactly which step is missing

##### Conversation Support (Multi-turn)

Agents now support multi-turn conversations with history tracking:

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

**New Methods:**
- `ask_followup(prompt)` - Ask a follow-up question with conversation history
- `clear_conversation!` - Clear conversation history
- `conversation_history` - Access the conversation history array

##### Token Usage Tracking

Track LLM token usage across agent requests:

```ruby
agent = Parse::Agent.new
agent.ask("How many users?")
agent.ask_followup("What about admins?")

# Check token usage
puts agent.token_usage
# => { prompt_tokens: 450, completion_tokens: 120, total_tokens: 570 }

# Individual accessors
agent.total_prompt_tokens   # => 450
agent.total_completion_tokens  # => 120
agent.total_tokens          # => 570

# Reset counters
agent.reset_token_counts!
```

**New Methods:**
- `token_usage` - Get hash with all token counts
- `reset_token_counts!` - Reset counters to zero
- `total_prompt_tokens` - Total prompt tokens used
- `total_completion_tokens` - Total completion tokens used
- `total_tokens` - Total tokens used

##### Callback/Hooks System

Register callbacks for events to enable debugging, logging, and custom behavior:

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

**New Methods:**
- `on_tool_call(&block)` - Register callback before tool execution
- `on_tool_result(&block)` - Register callback after tool execution
- `on_error(&block)` - Register callback for errors
- `on_llm_response(&block)` - Register callback for LLM responses

##### Configurable System Prompt

Customize the system prompt for different use cases:

```ruby
# Replace the default system prompt entirely
agent = Parse::Agent.new(system_prompt: "You are a music database expert...")

# Or append to the default prompt
agent = Parse::Agent.new(system_prompt_suffix: "Focus on performance data.")
```

##### Cost Estimation

Estimate costs based on token usage with configurable rates:

```ruby
# Configure pricing (per 1K tokens)
agent = Parse::Agent.new(pricing: { prompt: 0.01, completion: 0.03 })

agent.ask("How many users?")
agent.ask_followup("What about admins?")

# Get estimated cost
puts agent.estimated_cost  # => 0.0234

# Or configure later
agent.configure_pricing(prompt: 0.015, completion: 0.06)
```

**New Methods:**
- `configure_pricing(prompt:, completion:)` - Set pricing per 1K tokens
- `estimated_cost` - Calculate estimated cost based on usage
- `pricing` - Access current pricing configuration

##### Last Request/Response Accessors

Access the last LLM exchange for debugging:

```ruby
agent.ask("How many users?")

# Inspect last request
agent.last_request
# => { messages: [...], model: "...", endpoint: "...", streaming: false }

# Inspect last response
agent.last_response
# => { message: {...}, usage: {...}, answer: "..." }
```

##### Export/Import Conversation

Serialize and restore conversation state for persistence:

```ruby
agent = Parse::Agent.new
agent.ask("How many users?")
agent.ask_followup("What about admins?")

# Export state
state = agent.export_conversation
File.write("conversation.json", state)

# Later, in a new session...
new_agent = Parse::Agent.new
new_agent.import_conversation(File.read("conversation.json"))
new_agent.ask_followup("Show me the most recent ones")
```

**New Methods:**
- `export_conversation` - Serialize conversation state to JSON
- `import_conversation(json_string, restore_permissions: false)` - Restore state

##### Streaming Support

Stream responses as they arrive from the LLM:

```ruby
# Stream to console
agent.ask_streaming("Analyze user growth trends") do |chunk|
  print chunk
end

# Stream to WebSocket
agent.ask_streaming("Generate a report") do |chunk|
  websocket.send(chunk)
end
```

**Important Limitation:** Streaming mode does **not** support tool calls. This means the agent cannot query the database, call cloud functions, or perform any Parse operations while streaming.

**When to use `ask_streaming`:**
- Generating text summaries or explanations based on prior context
- Reformatting or analyzing data already retrieved
- General conversation without database access

**When to use `ask` instead:**
- Queries requiring database access ("How many users are there?")
- Operations that modify data
- Any request that needs Parse tool execution

```ruby
# DON'T: This won't query the database
agent.ask_streaming("How many users are in the system?") { |c| print c }
# Result: LLM will respond without actual data

# DO: Use ask for database queries
result = agent.ask("How many users are in the system?")
# Result: Agent uses count_objects tool to get real data
```

##### Configurable Operation Log Size

The agent operation log now uses a circular buffer with configurable size to prevent unbounded memory growth:

```ruby
# Default: 1000 entries
agent = Parse::Agent.new

# Custom size
agent = Parse::Agent.new(max_log_size: 5000)

# Access the log
agent.operation_log  # => Array of recent operations
agent.max_log_size   # => 5000
```

#### LiveQuery Enhancements

##### Frame Read Timeout

Added configurable frame read timeout to prevent indefinite socket blocking:

```ruby
Parse::LiveQuery.configure do |config|
  config.frame_read_timeout = 30.0  # seconds (default: 30)
end
```

- Timeout protection when reading WebSocket frames
- Prevents hung connections from blocking indefinitely
- Configurable via `frame_read_timeout` setting

#### Audience Cache Improvements

Added periodic cleanup of expired cache entries in `Parse::Audience` to prevent memory leaks:

- Automatic cleanup of stale cache entries
- Prevents unbounded cache growth in long-running processes

#### Bug Fixes

##### Array Pointer Storage/Query Compatibility

Fixed an issue where arrays containing Parse objects weren't stored in proper pointer format, causing `.in`/`.nin` queries to fail.

**Before (broken):**
```ruby
# Objects stored as full hashes, not pointers
library.featured_authors = [author1, author2]
library.save

# Query couldn't match because format mismatch
Library.where(:featured_authors.in => [author1]).results
# => [] (empty, even though data exists)
```

**After (fixed):**
```ruby
# Objects automatically converted to pointer format on save
library.featured_authors = [author1, author2]
library.save

# Query now works correctly
Library.where(:featured_authors.in => [author1]).results
# => [library] (correctly finds matching records)
```

**New Feature: `pointers_only` option for `CollectionProxy#as_json`**

Added a `pointers_only` option to control serialization behavior:

```ruby
# Default: Full objects preserved (for API responses)
team.members.as_json
# => [{"objectId"=>"abc", "name"=>"Alice", "email"=>"alice@test.com", ...}, ...]

# With pointers_only: Converts to pointer format (for Parse storage/webhooks)
team.members.as_json(pointers_only: true)
# => [{"__type"=>"Pointer", "className"=>"Member", "objectId"=>"abc"}, ...]
```

**Technical Details:**
- During `save`, `attribute_updates` automatically uses `as_json(pointers_only: true)` for `CollectionProxy` fields
- This ensures arrays are stored correctly in Parse and can be queried with `.in`/`.nin`/`.all` constraints
- Default `as_json` behavior preserves full objects for API responses (e.g., webhook returns with includes)
- Regular arrays (strings, integers, etc.) are unaffected
- `PointerCollectionProxy` (used by `has_many through: :array`) continues to always convert to pointers

**Atomic Operations Also Fixed:**

The `add!`, `add_unique!`, and `remove!` methods on `CollectionProxy` now correctly convert Parse objects to pointer format:

```ruby
library.featured_authors.add!(author1)        # Works correctly now
library.featured_authors.add_unique!(author2) # Works correctly now
library.featured_authors.remove!(author1)     # Works correctly now
```

---

### 3.0.0

#### New Features: Push Notifications Enhancement

Comprehensive improvements to the Push notification system with a fluent builder pattern API, iOS silent push support, rich push support, and Installation channel management.

##### Push Builder Pattern API

New fluent API for building push notifications with method chaining:

```ruby
# Fluent builder pattern
Parse::Push.new
  .to_channel("news")
  .with_title("Breaking News")
  .with_body("Major event happening now!")
  .with_badge(1)
  .with_sound("alert.caf")
  .with_data(article_id: "12345")
  .schedule(Time.now + 3600)
  .expires_in(7200)
  .send!

# Class method shortcuts
Parse::Push.to_channel("news").with_alert("Hello!").send!
Parse::Push.to_channels("sports", "weather").with_alert("Update").send!

# Query-based targeting
Parse::Push.new
  .to_query { |q| q.where(device_type: "ios", :app_version.gte => "2.0") }
  .with_alert("iOS 2.0+ users only")
  .send!
```

**Builder Methods:**
- `to_channel(channel)` / `to_channels(*channels)` - Target specific channels
- `to_query { |q| }` - Target via query constraints on Installation
- `with_alert(message)` / `with_body(body)` - Set the alert message
- `with_title(title)` - Set notification title
- `with_badge(count)` - Set badge number
- `with_sound(name)` - Set sound file
- `with_data(hash)` - Add custom payload data
- `schedule(time)` - Schedule for future delivery
- `expires_at(time)` / `expires_in(seconds)` - Set expiration
- `send!` - Send with error raising

**Class Methods:**
- `Parse::Push.to_channel(channel)` - Create push targeting a channel
- `Parse::Push.to_channels(*channels)` - Create push targeting multiple channels
- `Parse::Push.channels` - Alias for `Parse::Installation.all_channels`

##### Silent Push Support (iOS)

Support for iOS background/silent push notifications using `content-available`:

```ruby
# Silent push for background data sync
Parse::Push.new
  .to_channel("sync")
  .silent!
  .with_data(action: "refresh", resource: "users")
  .send!
```

- `content_available` attribute for iOS background notifications
- `silent!` builder method to enable content-available
- `content_available?` predicate method
- Payload automatically includes `content-available: 1` when enabled

##### Rich Push Support (iOS)

Support for iOS rich notifications with images, categories, and mutable content:

```ruby
# Rich push with image
Parse::Push.new
  .to_channel("media")
  .with_title("New Photo")
  .with_body("Check out this photo!")
  .with_image("https://example.com/photo.jpg")
  .with_category("PHOTO_ACTIONS")
  .send!
```

- `mutable_content` attribute for notification service extensions
- `category` attribute for action buttons
- `image_url` attribute for image attachments
- `with_image(url)` - Set image URL (auto-enables mutable-content)
- `with_category(name)` - Set notification category
- `mutable!` - Enable mutable-content explicitly
- `mutable_content?` predicate method

##### Installation Channel Management

New methods on `Parse::Installation` for managing channel subscriptions:

```ruby
# Instance methods
installation = Parse::Installation.first
installation.subscribe("news", "weather")      # Subscribe and save
installation.unsubscribe("sports")              # Unsubscribe and save
installation.subscribed_to?("news")             # Check subscription

# Class methods
Parse::Installation.all_channels                # List all unique channels
Parse::Installation.subscribers_count("news")   # Count channel subscribers
Parse::Installation.subscribers("news")         # Query for subscribers
  .where(device_type: "ios")
  .all
```

**Instance Methods:**
- `subscribe(*channels)` - Subscribe to channels and save
- `unsubscribe(*channels)` - Unsubscribe from channels and save
- `subscribed_to?(channel)` - Check if subscribed to a channel

**Class Methods:**
- `all_channels` - List all unique channel names across installations
- `subscribers_count(channel)` - Count subscribers to a channel
- `subscribers(channel)` - Get a query for channel subscribers

##### Push Localization

Support for language-specific push notifications. Parse Server automatically sends the appropriate message based on device locale:

```ruby
# Localized push notification
Parse::Push.new
  .to_channel("international")
  .with_alert("Default message")
  .with_title("Default title")
  .with_localized_alerts(
    en: "Hello!",
    fr: "Bonjour!",
    es: "Hola!",
    de: "Hallo!"
  )
  .with_localized_titles(
    en: "Welcome",
    fr: "Bienvenue",
    es: "Bienvenido",
    de: "Willkommen"
  )
  .send!

# Or add one language at a time
Parse::Push.new
  .with_localized_alert(:en, "Hello!")
  .with_localized_alert(:fr, "Bonjour!")
  .with_localized_title(:en, "Welcome")
  .send!
```

- `with_localized_alert(lang, message)` - Add alert for specific language
- `with_localized_title(lang, title)` - Add title for specific language
- `with_localized_alerts(hash)` - Set multiple localized alerts at once
- `with_localized_titles(hash)` - Set multiple localized titles at once
- Payload includes `alert-{lang}` and `title-{lang}` keys

##### Badge Increment

Support for incrementing badge counts instead of setting absolute values:

```ruby
# Increment badge by 1
Parse::Push.new
  .to_channel("messages")
  .with_alert("New message!")
  .increment_badge
  .send!

# Increment badge by custom amount
Parse::Push.new
  .to_channel("bulk")
  .with_alert("5 new items!")
  .increment_badge(5)
  .send!

# Clear badge (set to 0)
Parse::Push.new
  .to_channel("read")
  .silent!
  .clear_badge
  .send!
```

- `increment_badge(amount = 1)` - Increment badge by amount (default: 1)
- `clear_badge` - Set badge to 0
- Uses Parse Server's `Increment` operation for atomic updates

##### Saved Audiences (Parse::Audience)

New `Parse::Audience` class for working with the `_Audience` collection. Audiences are pre-defined groups of installations that can be targeted for push notifications:

```ruby
# Target a saved audience
Parse::Push.new
  .to_audience("VIP Users")
  .with_alert("Exclusive offer!")
  .send!

# Or by audience ID
Parse::Push.new
  .to_audience_id("abc123")
  .with_alert("Hello!")
  .send!

# Create and manage audiences
audience = Parse::Audience.new(
  name: "iOS Premium Users",
  query: { "deviceType" => "ios", "premium" => true }
)
audience.save

# Query audience stats
Parse::Audience.find_by_name("VIP Users")
Parse::Audience.installation_count("VIP Users")
Parse::Audience.installations("VIP Users").all
```

**Instance Methods:**
- `query_constraint` - Get the audience's query constraints
- `installation_count` - Count matching installations
- `installations` - Get query for matching installations

**Class Methods:**
- `find_by_name(name)` - Find audience by name
- `installation_count(name)` - Count installations for audience
- `installations(name)` - Query installations for audience

##### Push Status Tracking (Parse::PushStatus)

New `Parse::PushStatus` class for tracking push delivery status from the `_PushStatus` collection:

```ruby
# Query push status
status = Parse::PushStatus.find(push_id)

# Check status
status.succeeded?      # => true
status.failed?         # => false
status.complete?       # => true
status.in_progress?    # => false

# Get metrics
status.num_sent        # => 1250
status.num_failed      # => 12
status.success_rate    # => 99.05
status.sent_per_type   # => {"ios" => 800, "android" => 450}

# Get summary
status.summary
# => { status: "succeeded", sent: 1250, failed: 12, success_rate: 99.05, ... }

# Query scopes
Parse::PushStatus.succeeded.all    # All successful pushes
Parse::PushStatus.failed.all       # All failed pushes
Parse::PushStatus.recent.limit(10) # Recent pushes
Parse::PushStatus.running.all      # Currently sending
```

**Status Predicates:**
- `pending?`, `scheduled?`, `running?`, `succeeded?`, `failed?`
- `complete?` - True if succeeded or failed
- `in_progress?` - True if pending, scheduled, or running

**Metrics Methods:**
- `total_attempted` - num_sent + num_failed
- `success_rate` - Percentage of successful sends
- `failure_rate` - Percentage of failed sends
- `summary` - Hash with all key metrics

**Query Scopes:**
- `pending`, `scheduled`, `running`, `succeeded`, `failed`
- `recent` - Ordered by creation time descending

#### New Features: Session Management

Comprehensive session management with expiration checking, query scopes, and bulk operations.

##### Session Expiration Checking

```ruby
session = Parse::Session.first

# Check if session has expired
session.expired?          # => false
session.valid?            # => true (opposite of expired?)

# Get remaining time
session.time_remaining    # => 3542.5 (seconds until expiration)

# Check if expiring soon
session.expires_within?(1.hour)  # => true if expires within 1 hour

# Revoke this session
session.revoke!
```

##### Session Query Scopes

```ruby
# Query for active sessions
Parse::Session.active.all

# Query for expired sessions
Parse::Session.expired.all

# Query sessions for a specific user
Parse::Session.for_user(user).all
Parse::Session.for_user("userId123").all

# Count active sessions for user
Parse::Session.active_count_for_user(user)

# Revoke all sessions for a user
Parse::Session.revoke_all_for_user(user)

# Revoke all except current session
Parse::Session.revoke_all_for_user(user, except: current_session_token)
```

##### User Session Management

```ruby
user = Parse::User.first

# Logout from all devices
user.logout_all!

# Logout from all devices except current
user.logout_all!(keep_current: true)

# Get count of active sessions
user.active_session_count

# Get all sessions for user
user.sessions

# Check if logged in on multiple devices
user.multi_session?
```

#### New Features: Installation Management

Enhanced Installation management with device type scopes, badge management, and stale token detection.

##### Device Type Scopes

```ruby
# Query by device type
Parse::Installation.ios.all
Parse::Installation.android.all
Parse::Installation.by_device_type(:winrt).all

# Instance predicates
installation.ios?      # => true if iOS device
installation.android?  # => true if Android device
```

##### Badge Management

```ruby
# Reset badge for a specific installation
installation.reset_badge!

# Increment badge
installation.increment_badge!      # +1
installation.increment_badge!(5)   # +5

# Bulk reset badges for a channel
Parse::Installation.reset_badges_for_channel("news")

# Reset all badges for a device type
Parse::Installation.reset_all_badges           # iOS (default)
Parse::Installation.reset_all_badges(:android)
```

##### Stale Token Detection

Identify and clean up inactive installations:

```ruby
# Query for stale installations (not updated in 90 days by default)
Parse::Installation.stale_tokens.all
Parse::Installation.stale_tokens(days: 30).all

# Count stale installations
Parse::Installation.stale_count(days: 60)

# Clean up stale installations (use with caution!)
Parse::Installation.cleanup_stale_tokens!(days: 180)

# Check individual installation
installation.stale?              # true if not updated in 90 days
installation.stale?(days: 30)    # custom threshold
installation.days_since_update   # => 45 (days since last update)
```

#### Tests Added

- `test/lib/parse/push_test.rb` - 93 unit tests for Push functionality (includes localization, badge increment, audience targeting)
- `test/lib/parse/installation_channels_test.rb` - 16 unit tests for Installation channels
- `test/lib/parse/push_integration_test.rb` - 23 integration tests for Push (includes localization, Audience, PushStatus)
- `test/lib/parse/session_management_test.rb` - 16 unit tests for Session management
- `test/lib/parse/installation_management_test.rb` - 30 unit tests for Installation management
- `test/lib/parse/array_constraints_unit_test.rb` - 23 unit tests for array constraints

#### New Features: Query Constraints

##### Array Empty/Nil Constraints

New index-friendly constraints for querying empty and nil arrays:

```ruby
# Match empty arrays (uses equality, index-friendly)
query.where(:tags.arr_empty => true)

# Match non-empty arrays
query.where(:tags.arr_empty => false)

# Match empty OR nil/missing (combines both checks)
query.where(:tags.empty_or_nil => true)

# Match only non-empty arrays (must exist and have elements)
query.where(:tags.not_empty => true)
```

**Performance Improvements:**
- `arr_empty => true` now uses `{ field: [] }` equality instead of `$size: 0` for better MongoDB index utilization
- `arr_empty => false` now uses `{ field: { $ne: [] } }` instead of `$size > 0`

**New Constraints:**
- `empty_or_nil` - Matches arrays that are empty `[]` OR nil/missing fields
- `not_empty` - Matches arrays that have at least one element (must exist, not nil, not empty)

#### New Classes

- `Parse::Audience` - Represents the `_Audience` collection for saved push audiences
- `Parse::PushStatus` - Represents the `_PushStatus` collection for push delivery tracking

#### New Feature: Multi-Factor Authentication (MFA)

Comprehensive MFA support that integrates with Parse Server's built-in MFA adapter for TOTP and SMS-based two-factor authentication.

**Features:**
- TOTP (Time-based One-Time Password) support with authenticator apps (Google Authenticator, Authy, 1Password, etc.)
- SMS OTP integration via Parse Server's SMS callback
- QR code generation for easy authenticator app setup
- Recovery codes for account access
- MFA status checking and management

**Prerequisites:**
- Parse Server must have MFA adapter enabled in auth configuration
- Optional gems: `rotp` (for TOTP), `rqrcode` (for QR codes)

**Parse Server Configuration:**
```javascript
{
  auth: {
    mfa: {
      enabled: true,
      options: ["TOTP"],  // or ["SMS", "TOTP"]
      digits: 6,
      period: 30,
      algorithm: "SHA1"
    }
  }
}
```

**Usage Examples:**

```ruby
# Configure MFA issuer name (shown in authenticator apps)
Parse::MFA.configure do |config|
  config[:issuer] = "MyApp"
end

# Step 1: Generate a secret
secret = Parse::MFA.generate_secret

# Step 2: Show QR code to user
qr_svg = user.mfa_qr_code(secret, issuer: "MyApp")
# Render in HTML: <%= raw qr_svg %>

# Step 3: User scans QR and enters code from authenticator
recovery_codes = user.setup_mfa!(secret: secret, token: "123456")
# IMPORTANT: Display recovery codes to user - they can only see them once!

# Login with MFA
user = Parse::User.login_with_mfa("username", "password", "123456")

# Check MFA status
user.mfa_enabled?  # => true
user.mfa_status    # => :enabled, :disabled, or :unknown

# Disable MFA (requires current token for verification)
user.disable_mfa!(current_token: "123456")

# Admin reset (requires master key)
user.disable_mfa_admin!

# SMS MFA setup (requires Parse Server SMS callback)
user.setup_sms_mfa!(mobile: "+1234567890")
user.confirm_sms_mfa!(mobile: "+1234567890", token: "123456")
```

**Class Methods:**
- `Parse::MFA.generate_secret` - Generate a new TOTP secret
- `Parse::MFA.provisioning_uri(secret, account)` - Get otpauth:// URI
- `Parse::MFA.qr_code(secret, account)` - Generate QR code SVG
- `Parse::MFA.verify(secret, code)` - Verify a TOTP code locally
- `Parse::User.login_with_mfa(username, password, token)` - Login with MFA
- `Parse::User.mfa_required?(username)` - Check if user requires MFA

**Instance Methods on User:**
- `setup_mfa!(secret:, token:)` - Enable TOTP MFA, returns recovery codes
- `setup_sms_mfa!(mobile:)` - Initiate SMS MFA setup
- `confirm_sms_mfa!(mobile:, token:)` - Confirm SMS MFA
- `disable_mfa!(current_token:)` - Disable MFA with verification
- `disable_mfa_admin!` - Admin disable without verification (master key)
- `mfa_enabled?` - Check if MFA is enabled
- `mfa_status` - Get MFA status (:enabled, :disabled, :unknown)
- `mfa_qr_code(secret)` - Generate QR code for this user
- `mfa_provisioning_uri(secret)` - Get provisioning URI for this user

**Errors:**
- `Parse::MFA::VerificationError` - Invalid MFA token
- `Parse::MFA::RequiredError` - MFA required but token not provided
- `Parse::MFA::AlreadyEnabledError` - MFA is already set up
- `Parse::MFA::NotEnabledError` - MFA is not enabled
- `Parse::MFA::DependencyError` - Required gem (rotp/rqrcode) not available

**Files Added:**
- `lib/parse/two_factor_auth.rb` - Core MFA module
- `lib/parse/two_factor_auth/user_extension.rb` - User class MFA methods
- `test/lib/parse/mfa_test.rb` - MFA unit tests

#### New Feature: LiveQuery (Experimental)

Real-time data subscriptions using WebSocket connections to Parse Server's LiveQuery feature. Includes production-ready components for reliability and performance.

##### WebSocket Client
- Full WebSocket RFC 6455 implementation
- Automatic reconnection with exponential backoff and jitter
- TLS/SSL support with configurable certificate verification
- Message size limits to prevent memory exhaustion (default: 1MB)

##### Health Monitoring
- Ping/pong keep-alive mechanism
- Stale connection detection
- Automatic reconnection on connection loss

##### Circuit Breaker Pattern
- Prevents connection hammering when server is unavailable
- Three states: closed (normal), open (blocking), half_open (testing)
- Configurable failure threshold and reset timeout

##### Event Queue with Backpressure
- Bounded queue prevents memory exhaustion during high event rates
- Three strategies: `:block`, `:drop_oldest`, `:drop_newest`
- Configurable queue size and drop callbacks

##### TLS/SSL Security
Configurable certificate verification modes for secure WebSocket connections:
- `:verify_peer` (default) - Full certificate validation, recommended for production
- `:verify_none` - Skip certificate validation, use only for development/testing

##### Configuration
```ruby
Parse::LiveQuery.configure do |config|
  config.url = "wss://your-server.com"

  # TLS/SSL verification
  config.tls_verify_mode = :verify_peer  # :verify_peer (default) or :verify_none

  # Message size protection (default: 1MB)
  config.max_message_size = 1_048_576    # bytes

  # Health monitoring
  config.ping_interval = 30.0        # seconds between pings
  config.pong_timeout = 10.0         # seconds to wait for pong

  # Circuit breaker
  config.circuit_failure_threshold = 5
  config.circuit_reset_timeout = 60.0

  # Event queue backpressure
  config.event_queue_size = 1000
  config.backpressure_strategy = :drop_oldest

  # Logging
  config.logging_enabled = true
  config.log_level = :debug
end
```

##### Usage
```ruby
# Subscribe to changes
client = Parse::LiveQuery::Client.new(
  url: "wss://your-server.com",
  application_id: "your_app_id",
  client_key: "your_client_key"
)

subscription = client.subscribe("Song", where: { "plays" => { "$gt" => 1000 } })

subscription.on(:create) { |song| puts "New hit: #{song['title']}" }
subscription.on(:update) { |song, original| puts "Updated: #{song['title']}" }
subscription.on(:delete) { |song| puts "Deleted: #{song['objectId']}" }
subscription.on(:enter) { |song| puts "Now matches query" }
subscription.on(:leave) { |song| puts "No longer matches" }

# Check health
puts client.health_monitor.health_info

# Graceful shutdown
client.close
```

##### Files Added
- `lib/parse/live_query.rb` - Main module and client
- `lib/parse/live_query/configuration.rb` - Centralized configuration
- `lib/parse/live_query/logging.rb` - Structured logging module
- `lib/parse/live_query/health_monitor.rb` - Ping/pong and stale detection
- `lib/parse/live_query/circuit_breaker.rb` - Circuit breaker pattern
- `lib/parse/live_query/event_queue.rb` - Bounded queue with backpressure
- `lib/parse/live_query/subscription.rb` - Subscription management

##### Tests Added
- `test/lib/parse/live_query/client_test.rb`
- `test/lib/parse/live_query/configuration_test.rb`
- `test/lib/parse/live_query/logging_test.rb`
- `test/lib/parse/live_query/health_monitor_test.rb`
- `test/lib/parse/live_query/circuit_breaker_test.rb`
- `test/lib/parse/live_query/event_queue_test.rb`

#### New Feature: Fetch Key Validation

New configuration option to validate keys in partial fetch operations, helping catch typos and undefined field references early.

```ruby
# Default behavior: validation enabled
song.fetch!(keys: [:title, :nonexistent_field])
# => [Parse::Fetch] Warning: unknown keys [:nonexistent_field] for Song.
#    These fields are not defined on the model. (silence with Parse.validate_query_keys = false)

# Disable key validation (useful for dynamic schemas)
Parse.validate_query_keys = false

# Or disable all query warnings globally
Parse.warn_on_query_issues = false
```

**Configuration Options:**
- `Parse.validate_query_keys = true` (default) - Warn about undefined keys in fetch operations
- `Parse.validate_query_keys = false` - Disable key validation (for dynamic schemas)
- Validation only runs when both `validate_query_keys` AND `warn_on_query_issues` are `true`

#### New Features: AI/LLM Agent Integration (Experimental)

Parse Stack now includes experimental support for AI/LLM agents to interact with your Parse data through a standardized tool interface. This enables natural language querying and intelligent data exploration.

##### Parse::Agent

The `Parse::Agent` class provides a programmatic interface for AI agents to execute database operations:

```ruby
# Create an agent
agent = Parse::Agent.new

# Execute tools directly
result = agent.execute(:get_all_schemas)
result = agent.execute(:query_class, class_name: "Song", limit: 10)
result = agent.execute(:count_objects, class_name: "Song", where: { plays: { "$gte" => 1000 } })

# Ask natural language questions (requires LLM endpoint)
response = agent.ask("How many songs have more than 1000 plays?")
puts response[:answer]
```

**Permission Levels:**
- `:readonly` (default) - Query, count, schema, and aggregation operations
- `:write` - Adds create/update object operations
- `:admin` - Full access including delete operations

**Available Tools:**
- `get_all_schemas` - List all classes with field counts
- `get_schema` - Get detailed field info for a class
- `query_class` - Query objects with constraints
- `count_objects` - Count objects matching constraints
- `get_object` - Fetch a single object by ID
- `get_sample_objects` - Get sample objects to understand data format
- `aggregate` - Run MongoDB aggregation pipelines
- `explain_query` - Get query execution plan
- `call_method` - Call agent-allowed methods on models

##### MCP Server (Model Context Protocol)

An HTTP server that exposes Parse data to external AI agents via the Model Context Protocol:

```ruby
# Enable MCP server (experimental)
Parse.mcp_server_enabled = true
Parse::Agent.enable_mcp!(port: 3001)
Parse::Agent::MCPServer.run(port: 3001)
```

**Endpoints:**
- `GET /health` - Health check
- `GET /tools` - List available tools
- `POST /mcp` - Execute tool calls

##### Agent Metadata DSL

New DSL methods to annotate your models with agent-friendly metadata:

```ruby
class Song < Parse::Object
  # Mark class as visible to agents (filters schema listing)
  agent_visible

  # Class description for agent context
  agent_description "A music track in the catalog"

  # Property descriptions
  property :title, :string, _description: "The song title"
  property :plays, :integer, _description: "Total play count"
  property :artist, :pointer, _description: "The performing artist"

  # Expose methods to agents with permission levels
  agent_readonly :find_popular, "Find songs with high play counts"
  agent_write :increment_plays, "Increment the play counter"
  agent_admin :reset_stats, "Reset all statistics"

  def self.find_popular(min_plays: 1000)
    query(:plays.gte => min_plays).limit(100)
  end

  def increment_plays
    self.plays ||= 0
    self.plays += 1
    save
  end

  def self.reset_stats
    # Admin-only operation
  end
end
```

**DSL Methods:**
- `agent_visible` - Include this class in agent schema listings
- `agent_description "text"` - Set class description
- `property :name, :type, _description: "text"` - Set field description
- `agent_method :name, "description"` - Expose a method (default: readonly)
- `agent_readonly :name, "description"` - Expose as readonly
- `agent_write :name, "description"` - Require write permission
- `agent_admin :name, "description"` - Require admin permission

##### Token-Optimized Schema Output

Schema responses are optimized for LLM token efficiency with a compact format:

```ruby
# get_all_schemas returns compact format
{
  total: 5,
  note: "Use get_schema(class_name) for detailed field info",
  built_in: [{ name: "_User", fields: 8 }, { name: "_Role", fields: 3 }],
  custom: [
    { name: "Song", fields: 5, desc: "A music track", methods: 2 },
    { name: "Artist", fields: 3 }
  ]
}
```

##### Security Features (Hardened in 3.0.0)

Comprehensive security measures protect against injection attacks, resource exhaustion, and unauthorized access.

**Rate Limiting (Thread-Safe Sliding Window):**
```ruby
# Default: 60 requests per 60-second window
agent = Parse::Agent.new

# Custom rate limit
agent = Parse::Agent.new(
  rate_limit: 100,      # requests per window
  rate_window: 60       # window in seconds
)

# Check rate limit status
agent.rate_limiter.remaining   # => 57 (requests left)
agent.rate_limiter.retry_after # => nil (or seconds if limited)
agent.rate_limiter.stats       # => { limit: 60, used: 3, remaining: 57, ... }
```

**Aggregation Pipeline Validation:**
Pipelines are validated against a strict whitelist before execution.

| Blocked (Security Risk) | Reason |
|------------------------|--------|
| `$out` | Writes data to collections |
| `$merge` | Writes/modifies data |
| `$function` | Executes arbitrary JavaScript |
| `$accumulator` | Executes arbitrary JavaScript |

| Allowed (Read-Only) |
|--------------------|
| `$match`, `$group`, `$sort`, `$project`, `$limit`, `$skip`, `$unwind`, `$lookup`, `$count`, `$addFields`, `$set`, `$bucket`, `$bucketAuto`, `$facet`, `$sample`, `$sortByCount`, `$replaceRoot`, `$replaceWith`, `$redact`, `$graphLookup`, `$unionWith` |

```ruby
# Blocked operations raise PipelineSecurityError
begin
  agent.execute(:aggregate,
    class_name: "Song",
    pipeline: [{ "$out" => "hacked" }]
  )
rescue Parse::Agent::PipelineValidator::PipelineSecurityError => e
  puts "Security violation: #{e.message}"
end
```

**Query Constraint Validation:**
Query operators are validated against a strict whitelist to prevent code injection.

| Blocked (Security Risk) | Reason |
|------------------------|--------|
| `$where` | Executes arbitrary JavaScript |
| `$function` | Executes arbitrary JavaScript |
| `$accumulator` | Executes arbitrary JavaScript |
| `$expr` | Can enable injection attacks |

Unknown operators are rejected immediately (no configurable permissive mode).

**Tool Timeouts:**
Per-tool timeouts prevent runaway operations:

| Tool | Timeout |
|------|---------|
| `aggregate` | 60 seconds |
| `call_method` | 60 seconds |
| `query_class` | 30 seconds |
| `explain_query` | 30 seconds |
| `count_objects` | 20 seconds |
| Others | 10-15 seconds |

**Audit Logging:**
All operations are logged with authentication context. Master key usage is prominently logged for security auditing:
```
[Parse::Agent:AUDIT] Master key operation: query_class at 2024-01-15T10:30:00Z
```

**Error Handling Hierarchy:**
Security errors are never swallowed - they are always re-raised to the caller:
- `PipelineSecurityError` - Blocked aggregation stages
- `ConstraintSecurityError` - Blocked query operators
- `RateLimitExceeded` - Rate limit exceeded (includes `retry_after`)
- `ToolTimeoutError` - Operation timeout

##### Environment Variables

Configure the `ask` method's LLM endpoint via environment:

```bash
export LLM_ENDPOINT="http://127.0.0.1:1234/v1"  # Default: LM Studio
export LLM_MODEL="qwen2.5-7b-instruct"           # Model name
```

```ruby
# Or pass directly
agent.ask("How many users?",
  llm_endpoint: "http://localhost:1234/v1",
  model: "gpt-4"
)
```

#### Bug Fixes

- **FIXED**: Removed dead `@fetch_lock` code that was set but never checked in `autofetch!`
- **IMPROVED**: Marshal serialization now excludes `@client` in addition to `@fetch_mutex`

### 2.3.0

#### New Features: HTTP Connection Pooling (Default)

Parse Stack now uses HTTP persistent connections by default for significantly improved performance.

##### Connection Pooling Benefits
- **30-70% latency reduction** for typical Parse Server deployments
- **Eliminates per-request overhead**: TCP handshake, SSL/TLS handshake, DNS lookups
- **~95% reduction** in Parse Server connection overhead
- **Memory efficient**: Reuses connections instead of creating new ones

##### Configuration
```ruby
# Default: connection pooling enabled (net_http_persistent adapter)
Parse.setup(
  server_url: "https://your-parse-server.com/parse",
  application_id: "your-app-id",
  api_key: "your-api-key"
)

# Custom pool configuration
Parse.setup(
  server_url: "https://your-parse-server.com/parse",
  application_id: "your-app-id",
  api_key: "your-api-key",
  connection_pooling: {
    pool_size: 5,      # Connections per thread (default: 1)
    idle_timeout: 60,  # Close idle connections after 60s (default: 5)
    keep_alive: 60     # HTTP Keep-Alive timeout in seconds
  }
)

# Disable connection pooling if needed
Parse.setup(
  server_url: "https://your-parse-server.com/parse",
  application_id: "your-app-id",
  api_key: "your-api-key",
  connection_pooling: false  # Uses standard Net::HTTP (one connection per request)
)

# Explicit adapter still takes priority
Parse.setup(
  adapter: :test,  # Your explicit adapter choice wins
  connection_pooling: true  # Ignored when adapter is specified
)
```

##### Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `pool_size` | 1 | Connections per thread. Increase for parallel requests within a thread. |
| `idle_timeout` | 5 | Seconds before closing idle connections. Use 30-60s for frequently-used servers. |
| `keep_alive` | - | HTTP Keep-Alive timeout. Should be ≤ Parse Server's `keepAliveTimeout`. |

##### Implementation Details
- Uses `faraday-net_http_persistent` adapter via Faraday
- Thread-safe per-thread connection pools
- Configurable pool size, idle timeout, and keep-alive settings
- Backward compatible: set `connection_pooling: false` for previous behavior
- Explicit `:adapter` option always takes priority over `:connection_pooling`
- **Graceful fallback**: If `faraday-net_http_persistent` is unavailable, automatically falls back to the standard adapter with a warning

#### New Features: Cursor-Based Pagination

New `Parse::Cursor` class for efficiently traversing large datasets without the performance penalty of skip/offset pagination.

##### Benefits
- **Consistent performance**: Unlike skip/offset which slows down as you go deeper, cursor pagination maintains consistent speed
- **No skipped records**: Handles records added/deleted during pagination without missing or duplicating
- **Memory efficient**: Fetches one page at a time

##### Usage
```ruby
# Basic usage with each_page
cursor = Song.cursor(limit: 100, order: :created_at.desc)
cursor.each_page do |page|
  process(page)
end

# Iterate over individual items
Song.cursor(limit: 50).each do |song|
  puts song.title
end

# With query constraints
cursor = Song.query(artist: "Artist Name").cursor(limit: 25)
cursor.each_page { |page| process(page) }

# Manual pagination control
cursor = User.cursor(limit: 100)
first_page = cursor.next_page
second_page = cursor.next_page
cursor.reset!  # Start over from the beginning

# Get all results at once (use with caution on large datasets)
all_songs = Song.cursor(limit: 100).all

# Check cursor statistics
cursor.stats  # => { pages_fetched: 5, items_fetched: 500, ... }
```

##### API
- `cursor(limit:, order:)` - Create a cursor from a query or model class
- `next_page` - Fetch the next page of results
- `each_page { |page| }` - Iterate over pages
- `each { |item| }` - Iterate over individual items (Enumerable)
- `all` - Fetch all results at once
- `reset!` - Reset cursor to beginning
- `more_pages?` / `exhausted?` - Check pagination status
- `stats` - Get pagination statistics
- `serialize` / `to_json` - Save cursor state for later
- `Parse::Cursor.deserialize(json)` / `from_json` - Resume from saved state

##### Resumable Cursors
Cursors can be serialized and resumed later - perfect for background jobs that may be interrupted:

```ruby
# Save cursor state before job ends
cursor = Song.cursor(limit: 100)
cursor.next_page  # Process first page
state = cursor.serialize
Redis.set("job:#{job_id}:cursor", state)

# Resume in another job/process
state = Redis.get("job:#{job_id}:cursor")
cursor = Parse::Cursor.deserialize(state)
cursor.each_page { |page| process(page) }  # Continues from where it left off
```

#### New Features: N+1 Query Detection

New `Parse::NPlusOneDetector` to detect and warn about N+1 query patterns that can cause performance issues.

##### What is N+1?
N+1 queries occur when you load a collection and then access an association on each item, triggering a separate query for each. This is inefficient and can be avoided by eager-loading.

##### Enable Detection
```ruby
# Enable N+1 detection with warning mode (default when enabled)
Parse.warn_on_n_plus_one = true
# Or use the new mode API for more control:
Parse.n_plus_one_mode = :warn
```

##### Strict Mode for CI/Tests
```ruby
# Raise exceptions instead of warnings - ideal for CI pipelines
Parse.n_plus_one_mode = :raise

songs = Song.all(limit: 100)
songs.each do |song|
  song.artist.name  # Raises Parse::NPlusOneQueryError!
end
```

##### Available Modes
| Mode | Behavior |
|------|----------|
| `:ignore` | Detection disabled (default) |
| `:warn` | Log warnings when N+1 detected |
| `:raise` | Raise `Parse::NPlusOneQueryError` (for CI/tests) |

##### Example Warning
```ruby
songs = Song.all(limit: 100)
songs.each do |song|
  song.artist.name  # Warning: N+1 query detected on Song.artist
end

# Output:
# [Parse::N+1] Warning: N+1 query detected on Song.artist (3 separate fetches for Artist)
#   Location: app/controllers/songs_controller.rb:42 in `index`
#   Suggestion: Use `.includes(:artist)` to eager-load this association
```

##### Fix N+1 with Includes
```ruby
# Use includes to eager-load associations
songs = Song.all(limit: 100, includes: [:artist])
songs.each do |song|
  song.artist.name  # No warning - artist was eager-loaded
end
```

##### Custom Callbacks
```ruby
# Register callback for metrics/logging
Parse.on_n_plus_one do |source_class, association, target_class, count, location|
  MyMetrics.increment("n_plus_one.#{source_class}.#{association}")
end

# Get summary of detected patterns
Parse.n_plus_one_summary
# => { patterns_detected: 2, associations: [...] }

# Reset tracking
Parse.reset_n_plus_one_tracking!
```

##### Configuration
- Detection window: 2 seconds (fetches within this window are grouped)
- Threshold: 3 fetches before warning
- Thread-safe: Each thread has independent tracking
- Memory-safe: Automatic cleanup of stale entries in long-running processes

#### Bug Fixes & Improvements

- **IMPROVED**: Aggregation pipeline now correctly handles `__aggregation_pipeline` stages when combining with regular constraints
- **IMPROVED**: Better whitespace formatting in SortableGroupBy pipeline generation

### 2.2.0

#### New Features: Validations DSL

Parse Stack now includes Rails-style validations with a custom uniqueness validator that queries Parse Server.

##### Validation Callbacks
- **NEW**: `before_validation` callback - runs before validations execute
  ```ruby
  before_validation :normalize_data
  ```

- **NEW**: `after_validation` callback - runs after validations complete
  ```ruby
  after_validation :log_validation_result
  ```

- **NEW**: `around_validation` callback - wraps validation execution
  ```ruby
  around_validation :track_validation_time
  ```

##### Uniqueness Validator
- **NEW**: `validates :field, uniqueness: true` - Queries Parse Server to ensure field uniqueness
  ```ruby
  class User < Parse::Object
    property :email, :string
    property :username, :string

    validates :email, uniqueness: true
    validates :username, uniqueness: { case_sensitive: false }
  end
  ```

- **NEW**: Case-insensitive uniqueness checking
  ```ruby
  validates :username, uniqueness: { case_sensitive: false }
  ```

- **NEW**: Scoped uniqueness (unique within a subset)
  ```ruby
  validates :employee_id, uniqueness: { scope: :organization }
  ```

- **NEW**: Custom error messages
  ```ruby
  validates :email, uniqueness: { message: "is already registered" }
  ```

#### New Features: Complete Callback Lifecycle

Extended callback system with full before/after/around support for all lifecycle events.

##### Update Callbacks
- **NEW**: `before_update` callback - runs before updating an existing record
- **NEW**: `after_update` callback - runs after updating an existing record
- **NEW**: `around_update` callback - wraps the update operation
  ```ruby
  class Song < Parse::Object
    before_update :log_changes
    after_update :notify_listeners
    around_update :track_update_timing
  end
  ```

##### Around Callbacks for All Events
- **NEW**: `around_validation` callback support
- **NEW**: `around_create` callback support
- **NEW**: `around_save` callback support
- **NEW**: `around_update` callback support
- **NEW**: `around_destroy` callback support

##### Validation Integration
- **IMPROVED**: Validations now run automatically during save (configurable with `validate: true/false`)
- **IMPROVED**: Failed validations halt the save operation and return `false`
- **IMPROVED**: Error messages are available via `object.errors`

#### New Features: Performance Profiling Middleware

New Faraday middleware for profiling Parse API requests with detailed timing information.

##### Enable Profiling
```ruby
Parse.profiling_enabled = true
```

##### Access Profile Data
```ruby
# Get recent profiles
Parse.recent_profiles.each do |profile|
  puts "#{profile[:method]} #{profile[:url]}: #{profile[:duration_ms]}ms"
end

# Get aggregate statistics
stats = Parse.profiling_statistics
puts "Total requests: #{stats[:count]}"
puts "Average time: #{stats[:avg_ms]}ms"
puts "Min/Max: #{stats[:min_ms]}ms / #{stats[:max_ms]}ms"

# Breakdown by method and status
stats[:by_method]  # => { "GET" => 10, "POST" => 5, "PUT" => 3 }
stats[:by_status]  # => { 200 => 15, 201 => 3 }
```

##### Register Callbacks
```ruby
Parse.on_request_complete do |profile|
  # Log to monitoring system, update metrics, etc.
  puts "Request completed in #{profile[:duration_ms]}ms"
end
```

##### Profile Data Structure
Each profile includes:
- `method` - HTTP method (GET, POST, PUT, DELETE)
- `url` - Request URL (sensitive params filtered)
- `status` - HTTP status code
- `duration_ms` - Total request duration in milliseconds
- `started_at` - ISO8601 timestamp of request start
- `completed_at` - ISO8601 timestamp of request completion
- `request_size` - Size of request body in bytes
- `response_size` - Size of response body in bytes

##### Security
- Session tokens, master keys, and API keys are automatically filtered from URLs
- Maximum 100 profiles kept in memory (configurable via `MAX_PROFILES`)

#### New Features: Query Explain

New method to get query execution plans from MongoDB for performance analysis.

##### Usage
```ruby
# Get execution plan for a query
plan = Song.query(:plays.gt => 1000).explain

# Analyze complex queries
query = User.query(:email.like => "%@example.com").order(:createdAt.desc)
plan = query.explain
```

##### Notes
- Returns raw MongoDB explain output
- Format depends on MongoDB version
- Useful for understanding index usage and query performance

### 2.1.10

#### New Features: Additional Array Constraints

##### Readable Array Query Aliases
- **NEW**: `:field.any => [values]` - Alias for `$in`, matches if field contains any of the values
  ```ruby
  Item.query(:tags.any => ["rock", "pop"])  # Same as :tags.in => [...]
  ```

- **NEW**: `:field.none => [values]` - Alias for `$nin`, matches if field contains none of the values
  ```ruby
  Item.query(:tags.none => ["jazz", "classical"])  # Excludes these tags
  ```

- **NEW**: `:field.superset_of => [values]` - Semantic alias for `all`, matches if field contains all values
  ```ruby
  Item.query(:tags.superset_of => ["rock", "pop"])  # Must have both tags
  ```

##### Element Matching for Arrays of Objects
- **NEW**: `:field.elem_match => { criteria }` - Match array elements with multiple criteria
  ```ruby
  # Find posts where comments array has a comment by user that's approved
  Post.query(:comments.elem_match => { author: user, approved: true })
  ```

##### Set Operations
- **NEW**: `:field.subset_of => [values]` - Match arrays that only contain elements from the given set
  ```ruby
  # Find items where tags only include elements from the allowed list
  Item.query(:tags.subset_of => ["rock", "pop", "jazz"])
  ```

##### Positional Element Matching
- **NEW**: `:field.first => value` - Match if first array element equals value
  ```ruby
  Item.query(:tags.first => "featured")  # First tag is "featured"
  ```

- **NEW**: `:field.last => value` - Match if last array element equals value
  ```ruby
  Item.query(:tags.last => "archived")  # Last tag is "archived"
  ```

#### New Features: Request/Response Logging Middleware

##### Structured Logging
- **NEW**: Parse::Middleware::Logging - Faraday middleware for detailed request/response logging
  ```ruby
  # Enable via setup
  Parse.setup(
    app_id: "...",
    api_key: "...",
    logging: true,           # or :debug for verbose, :warn for errors only
    logger: Rails.logger     # optional custom logger
  )

  # Or configure programmatically
  Parse.logging_enabled = true
  Parse.log_level = :debug
  Parse.logger = Logger.new("parse.log")
  ```

##### Configuration Options
- `Parse.logging_enabled` - Enable/disable logging
- `Parse.log_level` - Set level (:info, :debug, :warn)
- `Parse.logger` - Custom logger instance
- `Parse.log_max_body_length` - Maximum body length before truncation (default: 500)

##### Log Output Format
- Request: `▶ POST /parse/classes/Song`
- Response: `◀ 201 (45ms)` or `✗ 400 (23ms) - 101: Object not found`
- Debug mode includes headers and truncated body content
- Sensitive data (API keys, session tokens) automatically filtered

#### Constraint Summary (All Array Constraints)

| Constraint | Description | Uses |
|------------|-------------|------|
| `:field.any => [...]` | Contains any (alias for `$in`) | Native |
| `:field.none => [...]` | Contains none (alias for `$nin`) | Native |
| `:field.superset_of => [...]` | Contains all (alias for `$all`) | Native |
| `:field.elem_match => { }` | Array element matches criteria | Aggregation ($elemMatch) |
| `:field.subset_of => [...]` | Only contains from set | Aggregation |
| `:field.first => val` | First element equals | Aggregation |
| `:field.last => val` | Last element equals | Aggregation |

### 2.1.9

#### New Features: Advanced Array Query Constraints

Parse Server doesn't natively support `$size` or exact array equality queries. This release adds comprehensive array query constraints using MongoDB aggregation pipelines under the hood.

**Requirements:** MongoDB 3.6+ is required for these array constraint features (uses `$expr`, `$map`, `$setEquals`).

##### Array Size Constraints
- **NEW**: `:field.size => n` - Match arrays with exact size
  ```ruby
  # Find items with exactly 2 tags
  TaggedItem.query(:tags.size => 2)
  ```

- **NEW**: Size comparison operators via hash
  ```ruby
  :tags.size => { gt: 3 }       # size > 3
  :tags.size => { gte: 2 }      # size >= 2
  :tags.size => { lt: 5 }       # size < 5
  :tags.size => { lte: 4 }      # size <= 4
  :tags.size => { ne: 0 }       # size != 0
  :tags.size => { gte: 2, lt: 10 }  # 2 <= size < 10 (range)
  ```

- **NEW**: `:field.arr_empty => true/false` - Match empty arrays
- **NEW**: `:field.arr_nempty => true/false` - Match non-empty arrays

##### Array Equality Constraints (Order-Dependent)
- **NEW**: `:field.eq => [values]` / `:field.eq_array => [values]`
  - Matches arrays with exact elements in exact order
  - `["rock", "pop"]` matches `["rock", "pop"]` but NOT `["pop", "rock"]`
  ```ruby
  TaggedItem.query(:tags.eq => ["rock", "pop"])
  ```

- **NEW**: `:field.neq => [values]`
  - Matches arrays that are NOT exactly equal (order matters)
  ```ruby
  TaggedItem.query(:tags.neq => ["rock", "pop"])  # Excludes exact match
  ```

##### Array Set Equality Constraints (Order-Independent)
- **NEW**: `:field.set_equals => [values]`
  - Matches arrays with same elements regardless of order
  - `["rock", "pop"]` matches both `["rock", "pop"]` AND `["pop", "rock"]`
  ```ruby
  TaggedItem.query(:tags.set_equals => ["rock", "pop"])
  ```

- **NEW**: `:field.not_set_equals => [values]`
  - Matches arrays that do NOT have the same set of elements
  ```ruby
  TaggedItem.query(:tags.not_set_equals => ["rock", "pop"])  # Excludes set-equal arrays
  ```

##### Pointer Array Support
All array constraints work with `has_many :through => :array` pointer arrays:
```ruby
# Find products with exactly these 2 categories (any order)
Product.query(:categories.set_equals => [cat1, cat2])

# Find products with more than 3 categories
Product.query(:categories.size => { gt: 3 })
```

#### Constraint Summary Table

| Constraint | Description | Order Matters? |
|------------|-------------|----------------|
| `:field.size => n` | Exact array length | N/A |
| `:field.size => { gt: n }` | Array length comparisons | N/A |
| `:field.arr_empty => true` | Empty arrays only | N/A |
| `:field.arr_nempty => true` | Non-empty arrays only | N/A |
| `:field.eq_array => [...]` | Exact match (order matters) | Yes |
| `:field.neq_array => [...]` | Not exact match | Yes |
| `:field.set_equals => [...]` | Set equality (any order) | No |
| `:field.not_set_equals => [...]` | Not set equal | No |

### 2.1.8

#### Bug Fixes
- **FIXED**: `fetch!` now handles array responses gracefully
  - When `client.fetch_object` returns an array instead of a single hash (e.g., in certain batch/transaction scenarios), `fetch!` now finds the matching object by `objectId`
  - Previously threw `NoMethodError: undefined method 'key?' for Array`
- **FIXED**: Transaction objects now receive their IDs after successful create
  - After a successful transaction with new objects, each object's `objectId`, `createdAt`, and `updatedAt` are now properly set from the server response
  - Uses request tags to match responses back to original objects
- **FIXED**: ActiveModel 8.x compatibility in `fetch!` error handling
  - Added error handling for `changed` method calls that can fail when object state is corrupted (e.g., after transaction rollback)
  - Prevents crashes when ActiveModel's mutation tracker encounters unexpected attribute types

### 2.1.7

#### Bug Fixes
- **FIXED**: Setting fields on pointer/embedded objects now correctly marks them as dirty
  - When setting a field on an object in pointer state (has `id` but not yet fetched), the autofetch that triggered during dirty tracking setup would call `clear_changes!`, wiping out the dirty state before it could be established
  - The setter now fetches the object BEFORE calling `will_change!` if it's a pointer, ensuring dirty tracking works correctly
  - Affects property setters, `belongs_to` setters, and `has_many` setters
  - **Behavioral change**: When assigning to a field on a pointer object, `changes` now shows the server value as the old value instead of `nil`. For example, if you assign `obj.title = "New Title"` on a pointer, `obj.changes["title"]` will return `["Server Value", "New Title"]` instead of `[nil, "New Title"]`. This is because the object is now fetched before dirty tracking begins.
- **FIXED**: `hash` method now consistent with `==` for Parse objects
  - Previously, `hash` included `changes.to_s` which meant two objects with the same `id` but different dirty states would have different hashes
  - This violated Ruby's contract that `a == b` implies `a.hash == b.hash`
  - Now `hash` is based only on `parse_class` and `id`, consistent with `==`
  - This fixes issues with `Array#uniq`, `Set`, and `Hash` operations on Parse objects

#### Behavior Clarification
- **Array dirty tracking**: Modifying a nested object's properties (e.g., `obj.items[0].active = false`) does NOT mark the parent as dirty - only structural changes to the array (add/remove items) mark the parent dirty
- **Object identity**: Pointers, partially fetched objects, and fully fetched objects with the same `id` are all considered equal for comparison and array operations

### 2.1.6

#### Bug Fixes
- **FIXED**: Autofetch no longer wipes out nested embedded data on pointer fields
  - When accessing an unfetched field triggered autofetch (full fetch), embedded data on pointer fields (e.g., `user.first_name`) was being replaced with bare pointers
  - The `belongs_to` setter now preserves existing embedded objects when the server returns a bare pointer with the same ID
- **FIXED**: `field_was_fetched?` now properly handles nil `@_fetched_keys`
  - Previously crashed with `NoMethodError: undefined method 'include?' for nil:NilClass` when called on fully fetched objects
- **FIXED**: `partially_fetched?` now correctly returns `false` for fully fetched objects
  - Previously returned `true` for any non-pointer object, even after a full fetch
  - Now returns `true` only for objects fetched with specific keys (selective/partial fetch)
- **FIXED**: `as_json` with `:only` option now works correctly with Parse::Object
  - ActiveModel's `:only` option uses string comparison, but Parse::Object returned symbol keys
  - Added `attribute_names_for_serialization` override to return string keys for compatibility

#### New Features
- **NEW**: `Parse::Pointer` now supports auto-fetch when accessing model properties
  - Accessing a property on a pointer will automatically fetch the object and return the property value
  - If `Parse.autofetch_raise_on_missing_keys` is enabled, raises `AutofetchTriggeredError` instead
  - Fetched object is cached for subsequent property accesses on the same pointer
- **NEW**: `Parse.serialize_only_fetched_fields` configuration option (default: `true`)
  - When enabled, `as_json`/`to_json` on partially fetched objects only serializes fetched fields
  - Prevents autofetch from being triggered during JSON serialization
  - Particularly useful for webhook responses where you want to return partial data efficiently
  - Override per-call with `object.as_json(only_fetched: false)` to serialize all fields
- **NEW**: `has_selective_keys?` method to check if object was fetched with specific keys
  - Internal method for autofetch logic, separate from `partially_fetched?`
- **NEW**: `fully_fetched?` method to check if object is fully fetched with all fields available
  - Returns `true` when object has all fields (not a pointer, not selectively fetched)
- **NEW**: `fetched?` now returns `true` for both fully and partially fetched objects
  - Returns `true` for any object with data (not just a pointer)
  - Use `fully_fetched?` to check if all fields are available
  - Use `partially_fetched?` to check if only specific keys were fetched

#### Usage Examples: Serialization Control
```ruby
# Default behavior (Parse.serialize_only_fetched_fields = true)
# Only fetched fields are serialized, preventing autofetch during serialization
user = User.first(id: user_id, keys: [:id, :first_name, :last_name, :email])
user.to_json  # Only includes id, first_name, last_name, email (plus metadata)

# Useful for webhook responses returning partial data
Parse::Webhooks.route :function, :getTeamMembers do
  users = User.all(:id.in => user_ids, keys: [:id, :first_name, :last_name, :icon_image])
  users  # Returns only the requested fields, no autofetch triggered
end

# Disable globally if needed
Parse.serialize_only_fetched_fields = false

# Or override per-call
user.as_json(only_fetched: false)  # Will serialize all fields (may trigger autofetch)

# Explicit opt-in when global setting is disabled
Parse.serialize_only_fetched_fields = false
user.as_json(only_fetched: true)  # Only serializes fetched fields
```

#### Usage Examples: Pointer Auto-fetch
```ruby
# Create a pointer (not yet fetched)
pointer = Post.pointer("abc123")

# Accessing a property auto-fetches and returns the value
pointer.title  # => "My Post Title" (fetches object, returns title)

# Subsequent accesses use the cached object
pointer.content  # => "Post content..." (no additional fetch)

# With autofetch_raise_on_missing_keys enabled
Parse.autofetch_raise_on_missing_keys = true
pointer = Post.pointer("abc123")
pointer.title  # => raises Parse::AutofetchTriggeredError
```

#### Usage Examples: Fetch Status Methods
```ruby
# Pointer state (only id, no data fetched)
pointer = Post.pointer("abc123")
pointer.pointer?           # => true
pointer.partially_fetched? # => false
pointer.fully_fetched?     # => false
pointer.fetched?           # => false

# Selectively fetched (specific keys only)
partial = Post.first(keys: [:title, :author])
partial.pointer?           # => false
partial.partially_fetched? # => true
partial.fully_fetched?     # => false
partial.fetched?           # => true  # has data!

# Fully fetched (all fields)
full = Post.first
full.pointer?           # => false
full.partially_fetched? # => false
full.fully_fetched?     # => true
full.fetched?           # => true
```

### 2.1.5

#### Bug Fixes
- **FIXED**: `Parse::Object#as_json` now correctly returns serialized pointer hash when object is in pointer state
  - Previously returned the `Parse::Pointer` object instead of its JSON representation
  - This caused `__type` and `className` to be stripped when serializing pointers in `Parse.call_function` parameters
- **FIXED**: Added `marshal_dump` and `marshal_load` methods to properly serialize Parse objects with `@fetch_mutex`
  - Fixes `Marshal failed: no _dump_data is defined for class Thread::Mutex` error in `Query.clone`
  - The mutex is excluded from serialization and lazily re-initialized when needed

#### New: Partial Fetch on Existing Objects
- **NEW**: `fetch(keys:, includes:, preserve_changes:)` method to partially fetch specific fields on an existing object
- **NEW**: `fetch!(keys:, includes:, preserve_changes:)` method with same functionality (updates self)
- **NEW**: `Pointer#fetch(keys:, includes:)` returns a properly typed, partially fetched object
- **NEW**: `fetch_json(keys:, includes:)` method to fetch raw JSON without updating the object
- **NEW**: Incremental partial fetch - calling `fetch(keys: [...])` on already partially fetched objects merges the new keys
- **NEW**: `preserve_changes:` parameter (default: `false`) controls whether local dirty values are preserved during fetch:
  - `preserve_changes: false` (default): Fetched fields accept server values, local changes are discarded with a debug warning
  - `preserve_changes: true`: Local dirty values are re-applied to fetched fields, maintaining dirty state
  - Unfetched fields always preserve their dirty state regardless of this setting
- **IMPROVED**: Thread-safe autofetch using Mutex instead of simple boolean lock
- **IMPROVED**: Autofetch now always preserves dirty changes (uses `preserve_changes: true` internally)
  - Manual `.fetch()` calls still default to `preserve_changes: false` for explicit control
  - Autofetch is an implicit background operation that shouldn't discard user modifications
- **NEW**: `Parse.autofetch_raise_on_missing_keys` configuration option for debugging
  - When `true`, raises `Parse::AutofetchTriggeredError` instead of auto-fetching
  - Helps identify where additional keys are needed in queries to avoid network requests
  - Error message includes the class, object ID, and missing field name
- **IMPROVED**: Better error logging in `clear_changes!` rescue block
- **IMPROVED**: Performance optimizations - reduced repeated `Array()` and `format_field` calls
- **IMPROVED**: `fetch_object` API method now accepts optional `query:` parameter for keys/include

#### Usage Examples: Partial Fetch on Objects
```ruby
# Partial fetch specific fields on a pointer
pointer = Post.pointer("abc123")
post = pointer.fetch(keys: [:title, :content])  # Returns new partially fetched object

# Partial fetch on an existing object (updates self)
post = Post.find("abc123")
post.fetch(keys: [:view_count])  # Updates self, merges with existing fetched keys

# Partial fetch with nested fields (pointer auto-resolved)
post.fetch(keys: ["author.name", "author.email"])
# post.author is now a partially fetched user with just name and email

# Fetch raw JSON without updating object
json = post.fetch_json(keys: [:title])  # Returns Hash, doesn't update post

# Default behavior: local changes are discarded for fetched fields
post = Post.find("abc123")
post.title = "Modified"
post.fetch                        # Local title change is discarded (warning logged)
post.title                        # => "Original Title" (server value)

# Preserve local changes with preserve_changes: true
post = Post.find("abc123")
post.title = "Modified"
post.fetch(preserve_changes: true)  # Local changes preserved
post.title                          # => "Modified"
post.title_changed?                 # => true

# Unfetched fields always preserve dirty state
post = Post.find("abc123")
post.title = "Modified"           # Mark title as dirty
post.fetch(keys: [:view_count])   # Fetch only view_count (title not fetched)
post.title_changed?               # => true (dirty state preserved for unfetched field)
```

#### Breaking Change: Nested Partial Fetch Tracking
- **FIXED**: Nested partial fetch tracking now correctly uses `keys` parameter with dot notation instead of `includes` parameter
  - **Before (incorrect)**: `Model.first(keys: [:author], include: ["author.name"])` - tracking parsed from includes
  - **After (correct)**: `Model.first(keys: ["author.name"])` - tracking parsed from keys, pointer auto-resolved
- **RENAMED**: `parse_includes_to_nested_keys` method renamed to `parse_keys_to_nested_keys` to reflect correct behavior
- **CLARIFIED**: Proper Parse Server parameter usage:
  - `keys:` with dot notation (e.g., `"project.name"`) - Fetches specific nested fields, pointer auto-resolved by Parse
  - `includes:` - Only needed to resolve pointers as FULL objects (without field restrictions)
- **IMPROVED**: `parse_keys_to_nested_keys` now skips top-level keys (those without dots) as they don't define nested relationships
- **UPDATED**: All integration and unit tests updated to reflect correct `keys`/`includes` usage

#### Usage Examples: Query Partial Fetch
```ruby
# Partial nested object (only name field, pointer auto-resolved)
Asset.first(keys: ["project.name"])

# Full nested object (includes required)
Asset.first(keys: [:project], includes: [:project])

# Multiple nested fields
Asset.first(keys: ["project.name", "project.status", "project.owner.email"])
```

#### Query Validation Warnings
- **NEW**: `Parse.warn_on_query_issues` configuration option (default: `true`)
- **NEW**: Debug warnings for common query mistakes:
  - Warning when including non-pointer fields (e.g., including a string field that doesn't need `include`)
  - Warning when including a pointer AND specifying subfield keys (redundant - the full object makes keys unnecessary)
- **NEW**: Warnings include instructions for silencing

```ruby
# Disable query validation warnings globally
Parse.warn_on_query_issues = false

# Example warnings that may be shown:
# [Parse::Query] Warning: 'filename' is a string field, not a pointer/relation - it does not need to be included (silence with Parse.warn_on_query_issues = false)
# [Parse::Query] Warning: including 'project' returns the full object - keys ["project.name"] are unnecessary (silence with Parse.warn_on_query_issues = false)
```

### 2.1.4

- **FIXED**: `belongs_to` associations now correctly trigger autofetch when accessing unfetched fields on partially fetched objects
- **FIXED**: `has_many` associations now correctly trigger autofetch when accessing unfetched fields on partially fetched objects
- **FIXED**: Both association types now raise `UnfetchedFieldAccessError` when autofetch is disabled and an unfetched field is accessed
- **FIXED**: `fetch!` and `fetch` methods now preserve locally changed fields instead of overwriting them with server values
  - Unchanged fields are updated with server values (as expected)
  - Locally changed fields retain their modified values after fetch
  - Dirty tracking is correctly maintained with `*_was` methods returning the fetched server value
  - This allows refreshing an object from the server without losing unsaved local changes
- **IMPROVED**: Association getters now follow the same partial fetch behavior pattern as regular properties
- **IMPROVED**: Default Parse test port changed from 1337 to 2337 to avoid conflicts
- **NEW**: 5 new integration tests for association autofetch behavior and fetch preservation on partially fetched objects
- **DOCUMENTED**: Clarified behavioral difference between pointer objects and partially fetched objects when autofetch is disabled
  - Pointer objects (backward compatible): Return `nil` for unfetched fields, no error raised
  - Partially fetched objects (strict): Raise `UnfetchedFieldAccessError` for unfetched fields
  - This distinction maintains backward compatibility while providing safety for the new partial fetch feature

### 2.1.3

- **FIXED**: Assignment to unfetched fields on partially fetched objects no longer triggers autofetch - writes don't need to know the previous value
- **FIXED**: Change tracking now works correctly when assigning to unfetched fields - `changed` array properly includes modified fields
- **IMPROVED**: Assigned fields are automatically added to `@_fetched_keys`, preventing subsequent reads from triggering autofetch
- **NEW**: 5 new integration tests for assignment behavior on partially fetched objects

### 2.1.2

- **FIXED**: Partial fetch now correctly handles fields with default values - unfetched fields no longer return their defaults, instead triggering autofetch (or raising `UnfetchedFieldAccessError` if autofetch is disabled)
- **FIXED**: `apply_defaults!` now skips unfetched fields on partially fetched objects to preserve autofetch behavior

### 2.1.1

- **REMOVED**: `active_model_serializers` gem dependency (discontinued/unmaintained)
- **FIXED**: Deprecation warning "ActiveSupport::Configurable is deprecated" from Rails 8.2
- **FIXED**: Infinite recursion in enhanced change tracking when `_was` methods were aliased multiple times
- **FIXED**: Field selection integration tests updated to use `disable_autofetch!` for compatibility with new autofetch behavior

### 2.1.0

#### Partial Fetch Tracking System
- **NEW**: Partial fetch tracking for objects fetched with specific `keys` parameter
- **NEW**: `partially_fetched?` method to check if object was fetched with limited fields
- **NEW**: `fetched_keys` / `fetched_keys=` methods to get/set the array of fetched field names
- **NEW**: `field_was_fetched?(key)` method to check if a specific field was included in the fetch
- **NEW**: Autofetch triggers automatically when accessing unfetched fields on partially fetched objects
- **NEW**: Nested partial fetch tracking for included objects via `keys:` parameter with dot notation
- **NEW**: `nested_fetched_keys` / `nested_keys_for(field)` methods for tracking nested object fields
- **NEW**: `parse_keys_to_nested_keys` helper parses keys patterns like `["team.time_zone", "team.name"]`
- **FIXED**: Objects fetched with `keys:` parameter no longer have dirty tracking for fields with default values
- **FIXED**: `clear_changes!` now called after `apply_defaults!` to prevent false dirty tracking
- **IMPROVED**: Before-save hooks can now reliably access unfetched fields (triggers autofetch)
- **IMPROVED**: Saving partially fetched objects only updates actually changed fields, not default values

#### Code Quality & Security Improvements
- **NEW**: `disable_autofetch!` method to prevent automatic network requests on an instance
- **NEW**: `enable_autofetch!` method to re-enable autofetch
- **NEW**: `autofetch_disabled?` method to check if autofetch is disabled
- **NEW**: `clear_partial_fetch_state!` public method for clearing partial fetch tracking
- **NEW**: `Parse::UnfetchedFieldAccessError` raised when accessing unfetched fields with autofetch disabled
- **FIXED**: Inconsistent state in `build` - both `nested_fetched_keys` and `fetched_keys` now set before `initialize`
- **FIXED**: Deep nesting support - `parse_keys_to_nested_keys` now handles arbitrary depth (e.g., `a.b.c.d`)
- **FIXED**: String/symbol mismatch in `field_was_fetched?` - remote_key now converted to symbol
- **IMPROVED**: `fetched_keys` getter returns frozen duplicate to prevent external mutation
- **IMPROVED**: Autofetch prevented during `apply_defaults!` when object is partially fetched
- **IMPROVED**: Info-level logging when autofetch is triggered (shows class, id, and field that triggered fetch)

#### Thread Safety Notes
- **NOTE**: `Parse::Object` instances are not designed to be shared across threads during partial fetch operations. Each thread should work with its own object instances.
- **NOTE**: The autofetch mechanism uses a mutex for thread safety when fetching, but the partial fetch state (`@_fetched_keys`) itself is not synchronized for cross-thread access.
- **NOTE**: N+1 detection uses thread-local storage, so each thread has independent tracking with automatic cleanup.

#### Testing
- **NEW**: 34 unit tests for partial fetch functionality (no Docker required)
- **NEW**: 18 integration tests for partial fetch with real Parse Server

### 2.0.9

- **FIXED**: `Query#where` method now routes through `conditions` to properly handle special keywords like `keys:`, `include:`, `limit:`, etc. when chaining (e.g., `Model.query.where(keys: [...])`)
- **FIXED**: `conditions` method now normalizes hash keys to symbols before comparison, allowing special keywords to work correctly whether passed as strings or symbols

### 2.0.8

- **FIXED**: `include` method alias now properly forwards arguments to `includes` using single splat (`*fields`) instead of double splat (`**fields`), fixing "TypeError: no implicit conversion of Array into Hash" when calling `.include("field.name")`
- **ENHANCED**: `Query#first` method now accepts both integer limit and hash of constraints (similar to model-level `first` method), enabling syntax like `.first(keys: [...], include: [...])` for consistent API usage

### 2.0.7

- **NEW**: `readable_by?`, `writeable_by?`, and `owner?` ACL methods now accept arrays for OR logic
- **NEW**: ACL permission methods now support Parse::Pointer to User objects with automatic role expansion
- **ENHANCED**: ACL permission checking methods support checking if ANY user/role in an array has the specified permission
- **ENHANCED**: When passed a Parse::User object or Parse::Pointer to User, automatically queries and checks the user's roles
- **ENHANCED**: Array support works with user IDs and role names (strings)
- **IMPROVED**: Better flexibility for checking permissions across multiple users and roles simultaneously
- **IMPROVED**: Parse::Pointer to User queries roles without needing to fetch the full user object
- **FIXED**: `group_by_date` now properly converts Parse pointer constraints to MongoDB aggregation format, fixing empty result issues when filtering by Parse object references

### 2.0.6

- **NEW**: Added `:minute` and `:second` interval support to `group_by_date` for minute-level and second-level time grouping
- **NEW**: Added `timezone:` parameter to `group_by_date` for timezone-aware date grouping (e.g., `timezone: "America/New_York"` or `timezone: "+05:00"`)
- **IMPROVED**: MongoDB date operators now support timezone conversion at the database level using the `timezone` parameter
- **FIXED**: `count` method now properly handles aggregation pipeline constraints (`:ACL.readable_by`, `:ACL.writable_by`, etc.) by routing through aggregation endpoint instead of standard count endpoint

### 2.0.5

- **NEW**: Added `force:` parameter to `save`, `save!`, `update`, and `update!` methods to trigger callbacks and webhooks even when there are no changes
- **NEW**: When `force: true` is used on objects with no changes, `updated_at` is temporarily marked as changed to ensure a non-empty update payload triggers Parse Server hooks
- **IMPROVED**: Refactored `run_after_create_callbacks`, `run_after_save_callbacks`, and `run_after_delete_callbacks` to only execute after callbacks (not all callbacks) using new `run_callbacks_from_list` helper method

### 2.0.4

- **NEW**: Added ACL alias methods for easier access control management
- **NEW**: Added `master?` method to check for presence of a master key
- **NEW**: ACLs can now be modified for User objects
- **NEW**: Added explicit `cache:` argument for `find` method to control caching behavior
- **FIXED**: Corrected `or_where` behavior in query operations
- **CHANGED**: Request idempotency is now enabled by default for improved reliability

### 2.0.0 - Major Release

**BREAKING CHANGES:**
- This major version represents a complete transformation of Parse Stack with extensive new functionality
- Moved from primarily mock-based testing to comprehensive integration testing with real Parse Server
- Enhanced change tracking may affect existing webhook implementations
- Transaction support changes object persistence patterns
- **Minimum Ruby version is now 3.0+** (dropped support for Ruby < 3.0)
- **`distinct` method now returns object IDs directly by default** for pointer fields instead of full pointer hash objects like `{"__type"=>"Pointer", "className"=>"Team", "objectId"=>"abc123"}`. Use `distinct(field, return_pointers: true)` to get Parse::Pointer objects.
- **Updated to Faraday 2.x** and removed `faraday_middleware` dependency
- **Fixed typo "constaint" to "constraint"** throughout codebase (method names may have changed)

#### Docker-Based Integration Testing Infrastructure
- **NEW**: Complete Docker-based Parse Server testing environment with Redis caching support
- **NEW**: `scripts/docker/Dockerfile.parse`, `docker-compose.test.yml` for isolated testing
- **NEW**: `scripts/start-parse.sh` for automated Parse Server setup
- **NEW**: `test/support/docker_helper.rb` for test environment management
- **NEW**: Reliable, reproducible testing environment for all integration tests

#### Transaction Support System
- **NEW**: Full atomic transaction support with `Parse::Object.transaction` method
- **NEW**: Two transaction styles: explicit batch operations and automatic batching via return values
- **NEW**: Automatic retry mechanism for transaction conflicts (Parse error 251) with configurable retry limits
- **NEW**: Transaction rollback on any operation failure to ensure data consistency
- **NEW**: Support for mixed operations (create, update, delete) within single transactions
- **NEW**: Comprehensive transaction testing with complex business scenarios

#### Enhanced Change Tracking & Webhooks
- **NEW**: Advanced change tracking that preserves `_was` values in `after_save` hooks
- **NEW**: `*_was_changed?` methods work correctly in after_save contexts using previous_changes
- **NEW**: Proper webhook-based hook halting mechanism for Parse Server integration
- **NEW**: ActiveModel callbacks can now halt operations by returning `false`
- **NEW**: Webhook blocks can halt operations by returning `false` or throwing `Parse::Webhooks::ResponseError`
- **NEW**: Comprehensive webhook system with payload handling (`lib/parse/webhooks.rb`)
- **NEW**: Enhanced webhook callback coordination to distinguish Ruby vs client-initiated operations
- **NEW**: `dirty?` and `dirty?(field)` methods for compatibility with expected API
- **IMPROVED**: Enhanced change tracking preserves standard ActiveModel behavior while adding Parse Server-specific functionality

#### Request Idempotency System
- **NEW**: Request idempotency system with `_RB_` prefix for Ruby-initiated requests
- **NEW**: Prevents duplicate operations with request ID tracking
- **NEW**: Thread-safe request ID generation and configuration management
- **NEW**: Per-request idempotency control for production reliability

#### ACL Query Constraints
- **NEW**: `readable_by` constraint for filtering objects by ACL read permissions
- **NEW**: `writable_by` constraint for filtering objects by ACL write permissions
- **NEW**: Smart input handling for User objects, Role objects, Pointers, and role name strings
- **NEW**: Automatic role fetching when given User objects to include user's roles in permission checks
- **NEW**: Support for both ACL object field and Parse's internal `_rperm`/`_wperm` fields
- **NEW**: Public access ("*") automatically included when querying internal permission fields

#### Advanced Query Operations
- **NEW**: Query cloning functionality with `clone` method for independent query copies
- **NEW**: `latest` method for retrieving most recently created objects (ordered by created_at desc)
- **NEW**: `last_updated` method for retrieving most recently updated objects (ordered by updated_at desc)
- **NEW**: `Parse::Query.or(*queries)` class method for combining multiple queries with OR logic
- **NEW**: `Parse::Query.and(*queries)` class method for combining multiple queries with AND logic
- **NEW**: `between` constraint for range queries on numbers, dates, strings, and comparable values
- **NEW**: Enhanced query composition methods work seamlessly with aggregation pipelines

#### Aggregation & Cache System
- **NEW**: MongoDB-style aggregation pipeline support with `query.aggregate`
- **NEW**: Count distinct operations with comprehensive testing
- **NEW**: Group by aggregation with proper pointer conversion
- **NEW**: Advanced caching with integration testing and Redis TTL support
- **NEW**: Cache invalidation and authentication context handling
- **NEW**: Timezone-aware date/time handling with DST transition support

#### Enhanced Object Management
- **NEW**: `fetch_object` method for Parse::Pointer and Parse::Object to return fetched instances
- **NEW**: Enhanced `fetch` method with optional `returnObject` parameter (defaults to true)
- **NEW**: Schema-based pointer conversion and detection when available
- **NEW**: Improved upsert operations: `first_or_create`, `first_or_create!`, `create_or_update!`
- **NEW**: Performance optimizations for upsert methods with change detection
- **NEW**: Enhanced Rails-style attribute merging with proper query_attrs + resource_attrs combination

#### Comprehensive Integration Testing
- **NEW**: Real Parse Server testing across all major features
- **NEW**: Comprehensive object lifecycle and relationship testing
- **NEW**: Performance comparison testing with timing validation
- **NEW**: Complex business scenario testing with real Parse Server validation

#### Enhanced Array Pointer Query Support
- **NEW**: Automatic conversion of Parse objects to pointers in array `.in`/`.nin` queries
- **NEW**: Support for mixed Parse objects and pointer objects in query arrays
- **NEW**: Enhanced `ContainedInConstraint` and `NotContainedInConstraint` for array pointer fields
- **FIXED**: Array pointer field compatibility issues with proper constraint handling

#### New Aggregation Functions
- **NEW**: `sum(field)` - Calculate sum of numeric values across matching records
- **NEW**: `min(field)` - Find minimum value for a field
- **NEW**: `max(field)` - Find maximum value for a field
- **NEW**: `average(field)` / `avg(field)` - Calculate average value for numeric fields
- **NEW**: `count_distinct(field)` - Count unique values using MongoDB aggregation pipeline

#### Enhanced Group By Operations
- **NEW**: `group_by(field, options)` - Group records by field value with aggregation support
- **NEW**: `group_by_date(field, interval, options)` - Group by date intervals (:year, :month, :week, :day, :hour)
- **NEW**: `group_objects_by(field, options)` - Group actual object instances (not aggregated)
- **NEW**: Sortable grouping with `sortable: true` option and `SortableGroupBy`/`SortableGroupByDate` classes
- **NEW**: Array flattening with `flatten_arrays: true` for multi-value fields
- **NEW**: Pointer optimization with `return_pointers: true` for memory efficiency

#### Advanced Query Constraints
- **NEW**: `equals_linked_pointer` - Compare pointer fields across linked objects using aggregation
- **NEW**: `does_not_equal_linked_pointer` - Negative comparison of linked pointers
- **NEW**: `between_dates` - Query records within date/time ranges
- **NEW**: `matches_key_in_query` - Matches key in subquery
- **NEW**: `does_not_match_key_in_query` - Does not match key in subquery
- **NEW**: `starts_with` - String prefix matching constraint
- **NEW**: `contains` - String substring matching constraint

#### New Utility Methods
- **NEW**: `pluck(field)` - Extract values for single field from all matching records
- **NEW**: `to_table(columns, options)` - Format results as ASCII/CSV/JSON tables with sorting
- **NEW**: `verbose_aggregate` - Debug flag for MongoDB aggregation pipeline details
- **NEW**: `keys(*fields)` / `select_fields(*fields)` - Field selection optimization
- **NEW**: `result_pointers` - Get Parse::Pointer objects instead of full objects
- **NEW**: `distinct_objects(field)` - Get distinct values with populated objects

#### Enhanced Cloud Functions
- **NEW**: `call_function_with_session(name, body, session_token)` - Call cloud functions with session context
- **NEW**: `trigger_job_with_session(name, body, session_token)` - Trigger background jobs with session token
- **NEW**: Enhanced authentication options and master key support for cloud functions

#### Result Processing & Display
- **NEW**: `GroupedResult` class with built-in sorting capabilities (`sort_by_key_asc/desc`, `sort_by_value_asc/desc`)
- **NEW**: Table formatting with custom headers, sorting, and multiple output formats (ASCII, CSV, JSON)
- **NEW**: Enhanced result processing with pointer optimization across all aggregation methods

#### Enhanced Pointer & Object Handling
- **IMPROVED**: Enhanced `distinct` with automatic detection and conversion of MongoDB pointer strings
- **IMPROVED**: `return_pointers` option available across multiple methods for memory optimization
- **IMPROVED**: Server-side object population in aggregation pipelines
- **IMPROVED**: Automatic handling of `ClassName$objectId` format conversion
- **IMPROVED**: Schema-based approach for pointer conversion when available - provides more reliable pointer field detection
- **IMPROVED**: Enhanced `in` and `not_in` query constraints to properly handle Parse pointers
- **IMPROVED**: Automatic conversion of pointer strings to proper Parse::Pointer objects in queries
- **NEW**: Support for detecting pointer fields from schema information when available
- **NEW**: Fallback to pattern-based detection when schema is unavailable
- **FIXED**: Pointer conversion in aggregation queries now correctly handles all pointer field types

#### Dependency Updates
- **UPDATED**: ActiveModel and ActiveSupport to latest compatible versions
- **UPDATED**: Rack dependency
- **UPDATED**: Modernized for Ruby 3.0+ compatibility

### 1.11.3
- Adds "empty" query constraint option
- Adds "include" alias for "includes" query method
- Ensures create_or_update only saves once (preventing duplicate saves)

### 1.11.2
- Adds afterCreate as valid Parse trigger

### 1.11.1
- Always applies attribute changes in first_or_create resource_attrs argument

### 1.11.0
- Adds create_or_update! method

### 1.10.3
- Fixes potential crash caused by activerecord gem version 6+

### 1.10.0

- Adds support for Ruby 3+ style hash and block arguments.

### 1.9.0

- Support for ActiveModel and ActiveSupport 6.0.
- Fixes `as_json` tests related to changes.
- Support for Faraday 1.0 and FaradayMiddleware 1.0
- Minimum Ruby version is now `>= 2.5.0`

### 1.8.0

- NEW: Support for Parse Server [full text search](https://github.com/modernistik/parse-stack#full-text-search-constraint) with the `text_search` operator. Related to [Issue#46](https://github.com/modernistik/parse-stack/issues/46).
- NEW: Support for `:distinct` aggregation query. Finds the distinct values for a specified field across a single collection or view and returns the results in an array.
  For example, `User.distinct(:city, :created_at.after => 3.days.ago)` to return an array of unique city names for which records were created in the last 3 days.

### 1.7.4

- NEW: Added `parse_object` extension to Hash classes to more easily call
  Parse::Object.build in `map` loops with symbol to proc.
- CHANGED: Renamed `hyperdrive_config!` to `Parse::Hyperdrive.config!`
- REMOVED: The used of non-JSON dates has been removed for `createdAt` and `updatedAt`
  fields as all Parse SDKs now support the new JSON format. `Parse.disable_serialized_string_date`
  has also been removed so that `created_at` and `updated_at` return the same value
  as `createdAt` and `updatedAt` respectively.
- FIXED: Builder properly auto generates Parse Relation associations using `through: :relation`.
- REMOVED: Defining `has_many` or `belongs_to` associations more than once will no longer result
  in an `ArgumentError` (they are now warnings). This will allow you to define associations for classes before calling `auto_generate_models!`
- CHANGED: Parse::CollectionProxy now supports `parse_objects` and `parse_pointers` for compatibility with the
  sibling `Array` methods. Having an Parse-JSON Hash array or a Parse::CollectionProxy which contains a series
  of Parse hashes can now be easily converted to an array of Parse objects with these methods.
- FIXED: Correctly discards ACL changes on User model saves.
- FIXED: Fixes issues with double '/' in update URI paths.

### 1.7.3

- CHANGED: Moved to using preferred ENV variable names based on parse-server cli.
- CHANGED: Default url is now http://localhost:1337/parse
- NEW: Added method `hyperdrive_config!` to apply remote ENV from remote JSON url.

### 1.7.2

- NEW: `Parse::Model.autosave_on_create` has been removed in favor of `first_or_create!`.
- NEW: Webhook Triggers and Functions now have a `wlog` method, similar to `puts`, but allows easier tracing of
  single requests in a multi-request threaded environment. (See Parse::Webhooks::Payload)
- NEW: `:id` constraints also safely supports pointers by skipping class matching.
- NEW: Support for `add_unique` and the set union operator `|` in collection proxies.
- NEW: Support for `uniq` and `uniq!` in collection proxies.
- NEW: `uniq` and `uniq!` for collection proxies utilize `eql?` for determining uniqueness.
- NEW: Updated override behavior for the `hash` method in Parse::Pointer and subclasses.
- NEW: Support for additional array methods in collection proxies (+,-,& and |)
- NEW: Additional methods for Parse::ACL class for setting read/write privileges.
- NEW: Expose the shared cache store through `Parse.cache`.
- NEW: `User#any_session!` method, see documentation.
- NEW: Extension to support `Date#parse_date`.
- NEW: Added `Parse::Query#append` as alias to `Parse::Query#conditions`
- CHANGED: `save_all` now returns true if there were no errors.
- FIXED: first_or_create will now apply dirty tracking to newly created fields.
- FIXED: Properties of :array type will always return a Parse::CollectionProxy if
  their internal value is nil. The object will not be marked dirty until something is added to the array.
- FIXED: Encoding a Parse::Object into JSON will remove any values that are `nil`
  which were not explicitly changed to that value.
- [PR#39](https://github.com/modernistik/parse-stack/pull/39): Allow Moneta::Expires
  as cache object to allow for non-native expiring caches by [GrahamW](https://github.com/GrahamW)

### 1.7.1

- NEW: `:timezone` datatype that maps to `Parse::TimeZone` (which mimics `ActiveSupport::TimeZone`)
- NEW: Installation `:time_zone` field is now a `Parse::TimeZone` instance.
- Any properties named `time_zone` or `timezone` with a string data type set will be converted to use `Parse::TimeZone` as the data class.
- FIXED: Fixes issues with HTTP Method Override for long url queries.
- FIXED: Fixes issue with Parse::Object.each method signature.
- FIXED: Removed `:id` from the Parse::Properties::TYPES list.
- FIXED: Parse::Object subclasses will not be allowed to redefine core properties.
- Parse::Object save_all() and each() methods raise ArgumentError for
  invalid constraint arguments.
- Removes deprecated function `Role.apply_default_acls`. If you need the previous
  behavior, you should set your own :before_save callback that modifies the role
  object with the ACLs that you want or use the new `Role.set_default_acl`.
- Parse::Object.property returns true/false whether creating the property was successful.
- Parse::Session now has a `has_one` association to Installation through `:installation`
- Parse::User now has a `has_many` association to Sessions through `:active_sessions`
- Parse::Installation now has a `has_one` association to Session through `:session`

### 1.7.0

- NEW: You can use `set_default_acl` to set default ACLs for your subclasses.
- NEW: Support for `withinPolygon` query constraint.
- Refactoring of the default ACL system and deprecation of `Parse::Object.acl`
- Parse::ACL.everyone returns an ACL instance with public read and writes.
- Documentation updates.

### 1.6.12

- NEW: Parse.use_shortnames! to utilize shorter class methods. (optional)
- NEW: parse-console supports `--url` option to load config from JSON url.
- FIXES: Issue #27 where core classes could not be auto-upgraded if they were missing.
- Warnings are now printed if auto_upgrade! is called without the master key.
- Use `Parse.use_shortnames!` to use short name class names Ex. Parse::User -> User
- Hosting documentation on https://www.modernistik.com/gems/parse-stack/ since rubydoc.info doesn't
  use latest yard features.
- Parse::Query will raise an exception if a non-nil value is passed to `:session` that
  does not provide a valid session token string.
- `save` and `destroy` will raise an exception if a non-nil `session` argument is passed
  that does not provide a valid session token string.
- Additional documentation changes and tests.

### 1.6.11

- NEW: Parse::Object#sig method to get quick information about an instance.
- FIX: Typo fix when using Array#objectIds.
- FIX: Passing server url in parse-console without the `-s` option when using IRB.
- Exceptions will not be raised on property redefinitions, only warning messages.
- Additional tests.
- Short name classes are generated when using parse-console. Ex. Parse::User -> User
- parse-console supports `--config-sample` to generate a sample configuration file.

### 1.6.7

- Default SERVER_URL changed to http://localhost:1337/parse
- NEW: Command line tool `parse-console` to do interactive Parse development with parse-stack.
- REMOVED: Deprecated parse.com specific APIs under the `/apps/` path.

### 1.6.5

- Client handles HTTP Status 429 (RetryLimitExceeded)
- Role class does not automatically set default ACLs for Roles. You can restore
  previous behavior by using `before_save :apply_default_acls`.
- Fixed minor issue to Parse::User.signup when merging username into response.
- NEW: Adds Parse::Product core class.
- NEW: Rake task to list registered webhooks. `rake parse:webhooks:list`
- Experimental support for beforeFind and afterFind - though webhook support not
  yet fully available in open source Parse Server.
- Removes HTTPS requirement on webhooks.
- FIXES: Issue with WEBHOOK_KEY not being properly validated when set.
- beforeSaves now return empty hash instead of true on noop changes.

### 1.6.4

- Fixes #20: All temporary headers values are strings.
- Reduced cache storage consumption by only storing response body and headers.
- Increased maximum cache content length size to 1.25 MB.
- You may pass a redis url to the :cache option of setup.
- Fixes issue with invalid struct size of Faraday::Env with old caching keys.
- Added server_info and health check APIs for Parse-Server +2.2.25.
- Updated test to validate against MT6.

### 1.6.1

- NEW: Batch requests are now parallelized.
- `skip` in queries no longer capped to 10,000.
- `limit` in queries no longer capped at 1000.
- `all()` queries can now return as many results as possible.
- NEW: `each()` method on Parse::Object subclasses to iterate
  over all records in the colleciton.

### 1.6.0

- NEW: Auto generate models based on your remote schema.
- The default server url is now 'http://localhost:1337/parse'.
- Improves thread-safety of Webhooks middleware.
- Performance improvements.
- BeforeSave change payloads do not include the className field.
- Reaches 100% documentation (will try to keep it up).
- Retry mechanism now configurable per client through `retry_limit`.
- Retry now follows sampling back-off delay algorithm.
- Adds `schemas` API to retrieve all schemas for an application.
- :number can now be used as an alias for the :integer data type.
- :geo_point can now be used as an alias for the :geopoint data type.
- Support accessing properties of Parse::Object subclasses through the [] operator.
- Support setting properties of Parse::Object subclasses through the []= operator.
- :to_s method of Parse::Date returns the iso8601(3) by default, if no arguments are provided.
- Parse::ConstraintError has been removed in favor of ArgumentError.
- Parse::Payload has been placed under Parse::Webhooks::Payload for clarity.
- Parse::WebhookErrorResponse has been moved to Parse::Webhooks::ResponseError.
- Moves Parse::Object modular functionality under Core namespace
- Renames ClassBuilder to Parse::Model::Builder
- Renamed SaveFailureError to RecordNotSaved for ActiveRecord similarity.
- All Parse errors inherit from Parse::Error.

### 1.5.3

- Several fixes and performance improvements.
- Major revisions to documentation.
- Support for increment! and decrement! for Integer and Float properties.

### 1.5.2

- FIXES #16: Constraints to `count` were not properly handled.
- FIXES #15: Incorrect call to `request_password_reset`.
- FIXES #14: Typos
- FIXES: Issues when passing a block to chaining scope.
- FIXES: Enums properly handle default values.
- FIXES: Enums macro methods now are dirty tracked.
- FIXES: #17: overloads inspect to show objects in a has_many scope.
- `reload!` and session methods support client request options.
- Proactively deletes possible matching cache keys on non GET requests.
- Parse::File now has a `force_ssl` option that makes sure all urls returned are `https`.
- Documentation
- ParseConstraintError is now Parse::ConstraintError.
- All constraint subclasses are under the Constraint namespace.

### 1.5.1

- BREAKING CHANGE: The default `has_many` implementation is `:query` instead of `:array`.
- NEW: Support for `has_one` type of associations.
- NEW: `has_many` associations support `Query` implementation as the inverse of `:belongs_to`.
- NEW: `has_many` and `has_one` associations support scopes as second parameter.
- NEW: Enumerated property types that mimic ActiveRecord::Enum behavior.
- NEW: Support for scoped queries similar to ActiveRecord::Scope.
- NEW: Support updating Parse config using `set_config` and `update_config`
- NEW: Support for user login, logout and sessions.
- NEW: Support for signup, including signing up with third-party services.
- NEW: Support for linking and unlinking user accounts with third-party services.
- NEW: Improved support for Parse session APIs.
- NEW: Boolean properties automatically generate a positive query scope for the field.
- Added property options for `:scopes`, `:enum`, `:_prefix` and `:_suffix`
- FIX: Auto-upgrade did not upgrade core classes.
- FIX: Pointer and Relation collection proxies will delay pointer casting until update.
- Improves JSON encoding/decoding performance.
- Removes throttling of requests.
- Turns off cache when using `save_all` method.
- Parse::Query supports ActiveModel::Callbacks for `:prepare`.
- Subclasses now support a :create callback that is only executed after a new object is successfully saved.
- Added alias method :execute! for Parse::Query#fetch! for clarity.
- `Parse::Client.session` has been deprecated in favor of `Parse::Client.client`
- All Parse-Stack errors that are raised inherit from StandardError.
- All :object data types is now cast as ActiveSupport::HashWithIndifferentAccess.
- :boolean properties now have a special `?` method to access true/false values.
- Adds chaining to Parse::Query#conditions.
- Adds alias instance method `Parse::Query#query` to `Parse::Query#conditions`.
- `Parse::Object.where` is now an alias to `Parse::Object.query`. You can now use `Parse::Object.where_literal`.
- Parse::Query and Parse::CollectionProxy support Enumerable mixin.
- Parse::Query#constraints allow you to combine constraints from different queries.
- `Parse::Object#validate!` can be used in webhook to throw webhook error on failed validation.

### 1.4.3

- NEW: Support for rails generators: `parse_stack:install` and `parse_stack:model`.
- Support Parse::Date with ActiveSupport::TimeWithZone.
- :date properties will now raise an error if value was not converted to a Parse::Date.
- Support for calling `before_save` and `before_destroy` callbacks in your model when a Parse::Object is returned by your `before_save` or `before_delete` webhook respectively.
- Parse::Query `:cache` expression now allows integer values to define the specific cache duration for this specific query request. If `false` is passed, will ignore the cache and make the request regardless if a cache response is available. If `true` is passed (default), it will use the value configured when setting up when calling `Parse.setup`.
- Fixes the use of `:use_master_key` in Parse::Query.
- Fixes to the cache key used in middleware.
- Parse::User before_save callback clears the record ACLs.
- Added `anonymous?` instance method to `Parse::User` class.

### 1.3.8

- Support for reloading the Parse config data with `Parse.config!`.
- The Parse::Request object is now provided in the Parse::Response instance.
- The HTTP status code is provided in `http_status` accessor for a Parse::Response.
- Raised errors now provide info on the request that failed.
- Added new `ServiceUnavailableError` exception for Parse error code 2 and HTTP 503 errors.
- Upon a `ServiceUnavailableError`, we will retry the request one more time after 2 seconds.
- `:not_in` and `:contains_all` queries will format scalar values into an array.
- `:exists` and `:null` will raise `ConstraintError` if non-boolean values are passed.
- NEW: `:id` constraint to allow passing an objectId to a query where we will infer the class.

### 1.3.7

- Fixes json_api loading issue between ruby json and active_model_serializers.
- Fixes loading active_support core extensions.
- Support for passing a `:session_token` as part of a Parse::Query.
- Default mime-type for Parse::File instances is `image/jpeg`. You can override the default by setting
  `Parse::File.default_mime_type`.
- Added `Parse.config` for easy access to `Parse::Client.client(:default).config`
- Support for `Parse.auto_upgrade!` to easily upgrade all schemas.
- You can import useful rake tasks by requiring `parse/stack/tasks` in your rake file.
- Changes the format in `select` and `reject` queries (see documentation).
- Latitude and longitude values are now validated with warnings. Will raise exceptions in the future.
- Additional alias methods for queries.
- Added `$within` => `$box` GeoPoint query. (see documentation)
- Improves support when using Parse-Server.
- Major documentation updates.
- `limit` no longer defaults to 100 in `Parse::Query`. This will allow Parse-Server to determine default limit, if any.
- `:bool` property type has been added as an alias to `:boolean`.
- You can turn off formatting field names with `Parse::Query.field_formatter = nil`.

### 1.3.1

- Parse::Query now supports `:cache` and `:use_master_key` option. (experimental)
- Minimum ruby version set to 1.9.3 (same as ActiveModel 4.2.1)
- Support for Rails 5.0+ and Rack 2.0+

### 1.3.0

- **IMPORTANT**: **Raising an error no longer sends an error response back to
  the client in a Webhook trigger. You must now call `error!('...')` instead of
  calling `raise '...'`.** The webhook block is now binded to the Parse::Webhooks::Payload
  instance, removing the need to pass `payload` object; use the instance methods directly.
  See updated README.md for more details.
- **Parse-Stack will throw new exceptions** depending on the error code returned by Parse. These
  are of type AuthenticationError, TimeoutError, ProtocolError, ServerError, ConnectionError and RequestLimitExceededError.
- `nil` and Delete operations for `:integers` and `:booleans` are no longer typecast.
- Added aliases `before`, `on_or_before`, `after` and `on_or_after` to help with
  comparing non-integer fields such as dates. These map to `lt`,`lte`, `gt` and `gte`.
- Schema API return true is no changes were made to the table on `auto_upgrade!` (success)
- Parse::Middleware::Caching no longer caches 404 and 410 responses; and responses
  with content lengths less than 20 bytes.
- FIX: Parse::Payload when applying auth_data in Webhooks. This fixes handing Facebook
  login with Android devices.
- New method `save!` to raise an exception if the save fails.
- FIX: Verify Content-Type header field is present for webhooks before checking its value.
- FIX: Support `reload!` when using it Padrino.

### 1.2.1

- Add active support string dependencies.
- Support for handling the `Delete` operation on belongs_to
  and has_many relationships.
- Documentation changes for supported Parse atomic operations.

### 1.2

- Fixes issues with first_or_create.
- Fixes issue when singularizing :belongs_to and :has_many property names.
- Makes sure time is sent as UTC in queries.
- Allows for authData to be applied as an update to a before_save for a Parse::User.
- Webhooks allow for returning empty data sets and `false` from webhook functions.
- Minimum version for ActiveModel and ActiveSupport is now 4.2.1

### 1.1

- In Query `join` has been renamed to `matches`.
- Not In Query `exclude` has been renamed to `excludes` for consistency.
- Parse::Query now has a `:keys` operation to be usd when passing sub-queries to `select` and `matches`
- Improves query supporting `select`, `matches`, `matches` and `excludes`.
- Regular expression queries for `like` now send regex options

### 1.0.10

- Fixes issues with setting default values as dirty when using the builder or before_save hook.
- Fixes issues with autofetching pointers when default values are set.

### 1.0.8

- Fixes issues when setting a collection proxy property with a collection proxy.
- Default array values are now properly casted as collection proxies.
- Default booleans values of `false` are now properly set.

### 1.0.7

- Fixes issues when copying dates.
- Fixes issues with double-arrays.
- Fixes issues with mapping columns to atomic operations.

### 1.0.6

- Fixes issue when making batch requests with special prefix url.
- Adds Parse::ConnectionError custom exception type.
- You can call locally registered cloud functions with
  Parse::Webhooks.run_function(:functionName, params) without going through the
  entire Parse API network stack.
- `:symbolize => true` now works for `:array` data types. All items in the collection
  will be symbolized - useful for array of strings.
- Prevent ACLs from causing an autofetch.
- Empty strings, arrays and `false` are now working with `:default` option in properties.

### 1.0.5

- Defaults are applied on object instantiation.
- When applying default values, dirty tracking is called.

### 1.0.4

- Fixes minor issue when storing and retrieving objects from the cache.
- Support for providing :server_url as a connection option for those migrating hosting
  their own parse-server.

### 1.0.3

- Fixes minor issue when passing `nil` to the class `find` method.

### 1.0.2

- Fixes internal issue with `operate_field!` method.
