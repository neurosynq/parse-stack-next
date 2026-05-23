## Parse-Stack Changelog

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

### 2.0.0 - Major Release 🚀

**BREAKING CHANGES:**
- This major version represents a complete transformation of Parse Stack with extensive new functionality
- Moved from primarily mock-based testing to comprehensive integration testing with real Parse Server
- Enhanced change tracking may affect existing webhook implementations
- Transaction support changes object persistence patterns
- **Minimum Ruby version is now 3.2+** (dropped support for Ruby < 3.2)
- **`distinct` method now returns object IDs directly by default** for pointer fields instead of full pointer hash objects like `{"__type"=>"Pointer", "className"=>"Team", "objectId"=>"abc123"}`. Use `distinct(field, return_pointers: true)` to get Parse::Pointer objects.
- **Updated to Faraday 2.x** and removed `faraday_middleware` dependency
- **Fixed typo "constaint" to "constraint"** throughout codebase (method names may have changed)

#### 🐳 Docker-Based Integration Testing Infrastructure
- **NEW**: Complete Docker-based Parse Server testing environment with Redis caching support
- **NEW**: `scripts/docker/Dockerfile.parse`, `docker-compose.test.yml` for isolated testing
- **NEW**: `scripts/start-parse.sh` for automated Parse Server setup
- **NEW**: `test/support/docker_helper.rb` for test environment management
- **NEW**: Reliable, reproducible testing environment for all integration tests

#### 💾 Transaction Support System
- **NEW**: Full atomic transaction support with `Parse::Object.transaction` method
- **NEW**: Two transaction styles: explicit batch operations and automatic batching via return values
- **NEW**: Automatic retry mechanism for transaction conflicts (Parse error 251) with configurable retry limits
- **NEW**: Transaction rollback on any operation failure to ensure data consistency
- **NEW**: Support for mixed operations (create, update, delete) within single transactions
- **NEW**: Comprehensive transaction testing with complex business scenarios

#### 🔄 Enhanced Change Tracking & Webhooks
- **NEW**: Advanced change tracking that preserves `_was` values in `after_save` hooks
- **NEW**: `*_was_changed?` methods work correctly in after_save contexts using previous_changes
- **NEW**: Proper webhook-based hook halting mechanism for Parse Server integration
- **NEW**: ActiveModel callbacks can now halt operations by returning `false`
- **NEW**: Webhook blocks can halt operations by returning `false` or throwing `Parse::Webhooks::ResponseError`
- **NEW**: Comprehensive webhook system with payload handling (`lib/parse/webhooks.rb`)
- **NEW**: Enhanced webhook callback coordination to distinguish Ruby vs client-initiated operations
- **NEW**: `dirty?` and `dirty?(field)` methods for compatibility with expected API
- **IMPROVED**: Enhanced change tracking preserves standard ActiveModel behavior while adding Parse Server-specific functionality

#### ⚡ Request Idempotency System
- **NEW**: Request idempotency system with `_RB_` prefix for Ruby-initiated requests
- **NEW**: Prevents duplicate operations with request ID tracking
- **NEW**: Thread-safe request ID generation and configuration management
- **NEW**: Per-request idempotency control for production reliability

#### 🔐 ACL Query Constraints
- **NEW**: `readable_by` constraint for filtering objects by ACL read permissions
- **NEW**: `writable_by` constraint for filtering objects by ACL write permissions
- **NEW**: Smart input handling for User objects, Role objects, Pointers, and role name strings
- **NEW**: Automatic role fetching when given User objects to include user's roles in permission checks
- **NEW**: Support for both ACL object field and Parse's internal `_rperm`/`_wperm` fields
- **NEW**: Public access ("*") automatically included when querying internal permission fields

#### 🔍 Advanced Query Operations
- **NEW**: Query cloning functionality with `clone` method for independent query copies
- **NEW**: `latest` method for retrieving most recently created objects (ordered by created_at desc)
- **NEW**: `last_updated` method for retrieving most recently updated objects (ordered by updated_at desc)
- **NEW**: `Parse::Query.or(*queries)` class method for combining multiple queries with OR logic
- **NEW**: `Parse::Query.and(*queries)` class method for combining multiple queries with AND logic
- **NEW**: `between` constraint for range queries on numbers, dates, strings, and comparable values
- **NEW**: Enhanced query composition methods work seamlessly with aggregation pipelines

#### 📊 Aggregation & Cache System
- **NEW**: MongoDB-style aggregation pipeline support with `query.aggregate`
- **NEW**: Count distinct operations with comprehensive testing
- **NEW**: Group by aggregation with proper pointer conversion
- **NEW**: Advanced caching with integration testing and Redis TTL support
- **NEW**: Cache invalidation and authentication context handling
- **NEW**: Timezone-aware date/time handling with DST transition support

#### 🎯 Enhanced Object Management
- **NEW**: `fetch_object` method for Parse::Pointer and Parse::Object to return fetched instances
- **NEW**: Enhanced `fetch` method with optional `returnObject` parameter (defaults to true)
- **NEW**: Schema-based pointer conversion and detection when available
- **NEW**: Improved upsert operations: `first_or_create`, `first_or_create!`, `create_or_update!`
- **NEW**: Performance optimizations for upsert methods with change detection
- **NEW**: Enhanced Rails-style attribute merging with proper query_attrs + resource_attrs combination

#### 🧪 Comprehensive Integration Testing
- **NEW**: Massive integration test coverage (1,577+ lines in `query_integration_test.rb` alone)
- **NEW**: Real Parse Server testing across all major features
- **NEW**: Comprehensive object lifecycle and relationship testing
- **NEW**: **Mock dependency reduced by ~80%** - most core features now integration tested
- **NEW**: Performance comparison testing with timing validation
- **NEW**: Complex business scenario testing with real Parse Server validation

#### 🔧 Enhanced Array Pointer Query Support
- **NEW**: Automatic conversion of Parse objects to pointers in array `.in`/`.nin` queries
- **NEW**: Support for mixed Parse objects and pointer objects in query arrays
- **NEW**: Enhanced `ContainedInConstraint` and `NotContainedInConstraint` for array pointer fields
- **FIXED**: Array pointer field compatibility issues with proper constraint handling

#### 📈 New Aggregation Functions
- **NEW**: `sum(field)` - Calculate sum of numeric values across matching records
- **NEW**: `min(field)` - Find minimum value for a field  
- **NEW**: `max(field)` - Find maximum value for a field
- **NEW**: `average(field)` / `avg(field)` - Calculate average value for numeric fields
- **NEW**: `count_distinct(field)` - Count unique values using MongoDB aggregation pipeline

#### 📊 Enhanced Group By Operations  
- **NEW**: `group_by(field, options)` - Group records by field value with aggregation support
- **NEW**: `group_by_date(field, interval, options)` - Group by date intervals (:year, :month, :week, :day, :hour)
- **NEW**: `group_objects_by(field, options)` - Group actual object instances (not aggregated)
- **NEW**: Sortable grouping with `sortable: true` option and `SortableGroupBy`/`SortableGroupByDate` classes
- **NEW**: Array flattening with `flatten_arrays: true` for multi-value fields
- **NEW**: Pointer optimization with `return_pointers: true` for memory efficiency

#### 🔗 Advanced Query Constraints
- **NEW**: `equals_linked_pointer` - Compare pointer fields across linked objects using aggregation
- **NEW**: `does_not_equal_linked_pointer` - Negative comparison of linked pointers  
- **NEW**: `between_dates` - Query records within date/time ranges
- **NEW**: `matches_key_in_query` - Matches key in subquery
- **NEW**: `does_not_match_key_in_query` - Does not match key in subquery
- **NEW**: `starts_with` - String prefix matching constraint
- **NEW**: `contains` - String substring matching constraint

#### 🛠️ New Utility Methods
- **NEW**: `pluck(field)` - Extract values for single field from all matching records
- **NEW**: `to_table(columns, options)` - Format results as ASCII/CSV/JSON tables with sorting
- **NEW**: `verbose_aggregate` - Debug flag for MongoDB aggregation pipeline details
- **NEW**: `keys(*fields)` / `select_fields(*fields)` - Field selection optimization
- **NEW**: `result_pointers` - Get Parse::Pointer objects instead of full objects
- **NEW**: `distinct_objects(field)` - Get distinct values with populated objects

#### ☁️ Enhanced Cloud Functions
- **NEW**: `call_function_with_session(name, body, session_token)` - Call cloud functions with session context
- **NEW**: `trigger_job_with_session(name, body, session_token)` - Trigger background jobs with session token
- **NEW**: Enhanced authentication options and master key support for cloud functions

#### 📋 Result Processing & Display
- **NEW**: `GroupedResult` class with built-in sorting capabilities (`sort_by_key_asc/desc`, `sort_by_value_asc/desc`)
- **NEW**: Table formatting with custom headers, sorting, and multiple output formats (ASCII, CSV, JSON)
- **NEW**: Enhanced result processing with pointer optimization across all aggregation methods

#### 🎯 Enhanced Pointer & Object Handling
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

#### 📦 Dependency Updates
- **UPDATED**: ActiveModel and ActiveSupport to latest compatible versions
- **UPDATED**: Rack dependency
- **UPDATED**: Modernized for Ruby 3.2+ compatibility


### 1.11.3
- Adds "empty" query constraint option
- Adds "include" alias for "includes" query method

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
