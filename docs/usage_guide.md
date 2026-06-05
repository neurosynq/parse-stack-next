# Parse Stack Usage Guide

A practical guide to using Parse Stack for Ruby applications.

## Setup

```ruby
require 'parse/stack'

Parse.setup(
  server_url: 'https://your-server.com/parse',
  app_id: 'your_app_id',
  api_key: 'your_rest_api_key',
  master_key: 'your_master_key'  # optional
)
```

## Defining Models

```ruby
class Song < Parse::Object
  property :title, :string, required: true
  property :artist, :string
  property :plays, :integer, default: 0
  property :duration, :float
  property :released, :date
  property :tags, :array
  property :metadata, :object

  belongs_to :album
  has_many :comments
end
```

## CRUD Operations

```ruby
# Create
song = Song.new(title: "My Song", artist: "Artist")
song.save

# or
song = Song.create!(title: "My Song", artist: "Artist")

# Read
song = Song.find("objectId")
song = Song.first(title: "My Song")
songs = Song.all(limit: 100)

# Update
song.title = "New Title"
song.save

# Delete
song.destroy
```

## Queries

```ruby
# Basic queries
Song.where(artist: "Artist Name").results
Song.query(genre: "rock").limit(10).results

# Comparison operators
Song.where(:plays.gt => 1000).results        # greater than
Song.where(:plays.gte => 1000).results       # greater than or equal
Song.where(:plays.lt => 100).results         # less than
Song.where(:plays.between => [100, 1000]).results

# String matching
Song.where(:title.like => /rock/i).results   # regex
Song.where(:title.starts_with => "The").results
Song.where(:title.ends_with => ".mp3").results

# Array operations
Song.where(:tags.in => ["rock", "pop"]).results
Song.where(:tags.all => ["rock", "guitar"]).results

# Sorting and pagination
Song.query.order(:plays.desc).skip(10).limit(20).results

# Include related objects
Song.all(includes: [:album, :comments])

# Select specific fields (allowlist)
Song.all(keys: [:title, :artist])

# Omit specific fields (denylist)
Song.query.exclude_keys(:internal_notes).results
```

> On the mongo-direct read path, `keys` is projected server-side while
> `exclude_keys` is applied as a recursive post-fetch sanitize (it strips
> matching field names at every depth and never removes reserved fields
> such as `objectId`). See the
> [Direct MongoDB Integration Guide](mongodb_direct_guide.md) for the
> exact semantics and how it differs from the REST path.

## Aggregation

```ruby
# Group by with aggregation — chain the aggregator you want
Song.group_by(:artist).count
Song.group_by(:artist).sum(:plays)
Song.group_by(:artist).average(:duration)

# Group by date
Song.group_by_date(:released, :month, timezone: "America/New_York").count

# Count distinct values
Song.query.count_distinct(:artist)

# Custom pipeline
Song.query.aggregate([
  { "$match" => { "plays" => { "$gt" => 1000 } } },
  { "$group" => { "_id" => "$artist", "total" => { "$sum" => "$plays" } } }
])
```

## Transactions

```ruby
Parse::Object.transaction do |batch|
  song.plays += 1
  batch.add(song)

  artist.total_plays += 1
  batch.add(artist)
end
```

## Upsert Operations

```ruby
# Find or create (returns unsaved if new)
song = Song.first_or_create({ title: "My Song" }, { artist: "Unknown" })

# Find or create and save
song = Song.first_or_create!({ title: "My Song" }, { artist: "Unknown" })

# Create or update existing
song = Song.create_or_update!({ title: "My Song" }, { plays: 100 })
```

Under concurrency these have a TOCTOU window. Pass `synchronize: true` to
serialize the find→create→save through a Moneta-backed lock, and declare a
`unique_index_on` on the dedup tuple as the durable correctness floor — the lock
optimizes latency, the unique index guarantees a single row even if the lock is
bypassed:

```ruby
class Song < Parse::Object
  property :title, :string
  unique_index_on :title          # provisioned via Song.apply_indexes!
end

Song.first_or_create!({ title: "My Song" }, { artist: "Unknown" }, synchronize: true)
```

## ACLs (Access Control)

```ruby
# Per-instance permissions
song.acl.apply(:public, read: true, write: false)
song.acl.apply(user, read: true, write: true)
song.acl.apply_role("Admin", read: true, write: true)

# Query by ACL
Song.query.publicly_readable.results
Song.query.readable_by(current_user).results
Song.query.readable_by_role("Admin").results

# Class-level default ACL policy (v4.1+)
class Post < Parse::Object
  belongs_to :author, as: :user
  # Grant R/W to the author at save; fall back to master-key-only.
  acl_policy :owner_else_private, owner: :author
end

Post.create!(title: "draft", author: current_user)
# → ACL: { "<current_user.id>": { read: true, write: true } }

# `as:` overrides any owner field for one-off ownership
Post.create!({ title: "x" }, as: current_user)

# For self-owned Parse::User records (one-roundtrip self-only ACL on signup)
class Parse::User
  acl_policy :owner_else_private, owner: :self
end
```

The gem-wide default is `:owner_else_private`. Records with no
resolvable owner are saved master-key-only. Declare
`acl_policy :public` or `:owner_else_public` on classes that need
public access.

Read-only and "publish-by-one-author" variants (v5.0+):

```ruby
# Read-anywhere, master-key-only write (no client can mutate)
class Country < Parse::Object
  property :name
  acl_policy :public_read
end

# Owner R/W + public read in the same ACL.
# Falls back to public-read-only when no owner resolves.
class PublishedPost < Parse::Object
  property :body
  belongs_to :author, as: :user
  acl_policy :owner_but_public_read, owner: :author
end
```

Valid policies: `:public`, `:public_read`, `:private`,
`:owner_else_public`, `:owner_else_private`, `:owner_but_public_read`.

## Roles

```ruby
# Find or create a role
admin = Parse::Role.find_or_create("Admin")

# Add users
admin.add_users(user1, user2).save

# Role hierarchy — Admins inherit Moderator capabilities.
# Parse Server semantics: when role X holds role Y in its `roles`
# relation, users-of-Y inherit X's permissions. The direction-explicit
# helpers below make intent obvious.
moderator = Parse::Role.find_or_create("Moderator")
admin.inherits_capabilities_from!(moderator)
# equivalent: moderator.grant_capabilities_to!(admin)

# Get all users (including inherited roles)
moderator.all_users
```

## Class-Level Permissions (CLP)

```ruby
class Document < Parse::Object
  # Operation permissions
  set_clp :find, public: true
  set_clp :delete, public: false, roles: ["Admin"]

  # Protect sensitive fields
  protect_fields "*", [:internal_notes, :secret_data]
  protect_fields "role:Admin", []  # Admins see everything
end

# Push to server
Document.auto_upgrade!
```

## Push Notifications

```ruby
# Simple push
Parse::Push.new
  .to_channel("news")
  .with_alert("Breaking news!")
  .send!

# Rich push
Parse::Push.new
  .to_channels(["sports", "news"])
  .with_title("Game Update")
  .with_body("Score: 3-2")
  .with_badge(1)
  .schedule(Time.now + 3600)
  .send!
```

## Caching

```ruby
# Enable caching in setup
Parse.setup(
  # ... other options
  cache: Moneta.new(:Memory),
  expires: 300  # 5 minutes
)

# Fetch with cache
song = Song.find_cached("objectId")
song.fetch_cache!

# Bypass cache
song = Song.find("objectId", cache: false)
```

## Direct MongoDB Access

For high-performance reads, bypass Parse Server:

```ruby
# Configure MongoDB
Parse::MongoDB.configure(
  uri: "mongodb://localhost:27017/parse",
  enabled: true
)

# Direct queries
songs = Song.query(:plays.gt => 1000).results_direct
song = Song.query(title: "My Song").first_direct
count = Song.query.count_direct
```

## Cloud Functions

```ruby
# Call a cloud function
result = Parse.call_function(:myFunction, { param1: "value" })

# Background job
Parse.trigger_job(:myJob, { data: "value" })
```

## Users & Authentication

```ruby
# Signup — creates _User row, returns it with a session token.
user = Parse::User.signup("alice", "s3cret", "alice@example.com")
user.session_token   # => "r:abc123..."

# Login — returns the user or nil on bad credentials.
user = Parse::User.login("alice", "s3cret")

# Resolve a user from a session token (e.g. from a Rails request).
user = Parse::User.session(request.headers["X-Parse-Session-Token"])
# session! raises Parse::Error::InvalidSessionTokenError on bad/expired tokens.

# Password reset email (configure email adapter on the server first).
Parse::User.request_password_reset("alice@example.com")
```

When you have a session-token-authenticated user, pass it through to scope
queries and writes to that user's ACL. The query object exposes
`session_token=` as a setter; on `.all` / `.first` it's a constraint-hash
key. The class-level `.all_as` / `.first_as` helpers wrap it as a kwarg
when you'd rather not remember the spelling:

```ruby
# Class-level kwarg form
Song.all_as(user, genre: "rock")
Song.first_as(user, genre: "rock")

# Constraints-hash form
Song.all(genre: "rock", session_token: user.session_token)

# Or block-scoped via Parse.with_session
Parse.with_session(user) do
  Song.all(genre: "rock")
  song.save
end

# Per-save kwarg
song.save(session_token: user.session_token)
```

As of v5.0, `Parse::Query` no longer hard-codes `@use_master_key = true`
at init — the default is `nil` ("no caller preference") so the request
layer can apply `Parse.client_mode` and the `Parse.with_session` ambient
token cleanly. Server-mode (master key configured, no client_mode) still
sends the master key by default; this only matters if you've flipped
`Parse.client_mode = true` or are running inside a `with_session` block,
where the previous `true` default silently master-key-stamped queries.
Explicitly setting `use_master_key: true` (or `query.use_master_key = true`)
still forces the header. The mongo-direct routing gate treats a
configured master key on the client as an ambient credential in
server mode: direct-only constraints route through mongo-direct as
long as `Parse.client_mode` is false and `use_master_key` was not
explicitly set to `false`. The gate raises
`Parse::Query::MongoDirectRequired` for client-mode processes or
queries that opt out of the master key without supplying a
`session_token` / `.scope_to_user(user)` / `.scope_to_role(role)`.

## Pointers, Relations, and Includes

Parse has three relationship shapes; pick by cardinality and access pattern:

```ruby
class Song < Parse::Object
  belongs_to :album                            # 1-to-1 pointer (column on Song)
  has_many   :comments                         # 1-to-many via inverse pointer on Comment
  has_many   :tags, through: :relation         # many-to-many via _Join Parse Relation
end
```

Pointers are **lazy by default** — `song.album` returns an unfetched
`Parse::Pointer`. Calling any property on it triggers a fetch, which causes
N+1 if you loop. Use `includes:` to batch them:

```ruby
# BAD — one fetch per song
Song.all(limit: 50).each { |s| puts s.album.title }

# GOOD — single round-trip
Song.all(limit: 50, includes: [:album]).each { |s| puts s.album.title }

# Fetch the pointer explicitly when you need it later
song.album.fetch! unless song.album.pointer?
```

For `through: :relation` columns, use the relation API rather than assigning
an array (Parse Server rejects bulk array writes to Relation columns):

```ruby
tag = Tag.first_or_create!(name: "guitar")
song.tags.add(tag)
song.save
# Or, atomic (no read-modify-write):
song.op_add_relation!(:tags, tag)

# Querying the other side:
Song.query(tags: tag).results          # songs containing this tag
tag.songs.results                      # inverse query, if Tag declares has_many :songs, through: :relation
```

### Heads up: Parse Server request-complexity limits

Recent Parse Server versions add `requestComplexity` limits whose
defaults are changing from "unlimited" (`-1`) to finite values in a
future release: `includeDepth: 10`, `includeCount: 100`,
`subqueryDepth: 10`, `queryDepth: 10`, and `batchRequestLimit: 100`.
These cap how deep an `includes:` chain can nest, how many include
paths a single query may carry, how deeply `matches_query` /
`$inQuery` / `$select` subqueries nest, how deeply `$and` / `$or`
conditions nest, and how many sub-requests a batch may contain.

The SDK's defaults stay within these limits — most relevantly, the
batch segment size is **50** (`Parse::BatchOperation#submit`), under the
incoming `batchRequestLimit: 100`. The cases to watch are app-specific:
very deep `includes: [{a: {b: {c: …}}}]` chains, queries with many
distinct include paths, or deeply nested subqueries can start returning
errors once the finite defaults land. If you hit one, restructure the
query (split it, fetch pointers lazily, flatten the nesting) or raise
the specific `requestComplexity.*` limit on your server. Set any of them
to `-1` to opt out of that limit entirely.

## Atomic Operations

Use atomic ops to avoid read-modify-write races on counters, sets, and
relations. They go straight to the server as `$inc` / `$addToSet` / `$pull`
and don't require a `save` afterwards:

```ruby
song.op_increment!(:plays)              # +1
song.op_increment!(:plays, -1)          # -1
song.op_add_unique!(:tags, ["live"])    # idempotent set-insert
song.op_remove!(:tags, ["demo"])
song.op_destroy!(:scratch_field)        # unset
song.op_add_relation!(:contributors, user)
```

## Files

```ruby
# From bytes
bytes = File.read("cover.jpg")
file  = Parse::File.new("cover.jpg", bytes, "image/jpeg")
file.save                # uploads, populates file.url

# From a URL (downloaded server-side, then uploaded)
file = Parse::File.new("https://example.com/cover.jpg")
file.save

# Attach to a property
class Song < Parse::Object
  property :cover, :file
end

song.cover = file
song.save
song.cover.url   # public URL on the Parse file storage
```

## GeoPoint Queries

```ruby
class Place < Parse::Object
  property :location, :geopoint
end

origin = Parse::GeoPoint.new(37.7749, -122.4194)   # San Francisco

# Nearest first, capped at 5 km
Place.where(:location.near => origin.max_kilometers(5)).results

# Bounded box (SW corner, NE corner)
sw = Parse::GeoPoint.new(32.82, -117.23)
ne = Parse::GeoPoint.new(36.12, -115.31)
Place.where(:location.within_box => [sw, ne]).results

# Circle (does not sort by distance — cheaper than near + max_*)
Place.where(:location.within_sphere => [origin, 10, :km]).results

# Polygon (3+ points)
Place.where(:location.within_polygon => [pt1, pt2, pt3, pt4]).results
```

## Schema Migration

The SDK can push your local model definitions to the server so columns and
indexes match what `property` / `belongs_to` / `has_many` declare. Run this
once at boot or as a deploy step — without it, fields you declared in Ruby
won't exist on the server and `save` will silently drop them.

```ruby
# One class
Song.auto_upgrade!

# Every Parse::Object subclass that has been loaded
Parse.auto_upgrade!

# Preview the diff before pushing
puts Parse::Schema.diff(Song).summary
Parse::Schema.migration(Song).apply!(dry_run: true)
```

## Webhooks (Cloud Code Triggers from Ruby)

Cloud Code triggers (`beforeSave`, `afterSave`, `beforeDelete`, `afterDelete`)
and custom functions can be implemented in Ruby and served as a Rack app that
Parse Server calls back into. **You must register the endpoint with the
server** — until you do, the trigger blocks below will not fire, even though
they're defined in Ruby.

```ruby
class Song < Parse::Object
  webhook :before_save do
    # `self` is a Parse::Webhooks::Payload; `parse_object` is the row.
    parse_object.title = parse_object.title.strip
    parse_object   # return the (possibly mutated) object
  end

  webhook :after_save do
    Rails.logger.info("Saved song #{parse_object.id}")
  end

  webhook_function :recountPlays do
    Song.find(params["songId"]).op_increment!(:plays, params["delta"].to_i)
  end
end

# Mount the Rack app (in config.ru or a Rails route):
run Parse::Webhooks

# Tell Parse Server where to reach it. Do this once per deploy.
Parse::Webhooks.register_triggers!("https://your-app.example.com/webhooks")
Parse::Webhooks.register_functions!("https://your-app.example.com/webhooks")
```

The endpoint must be HTTPS and publicly reachable from Parse Server. Set
`Parse::Webhooks.key = ENV["PARSE_WEBHOOK_KEY"]` and configure the same key
on Parse Server to authenticate incoming trigger calls.

## Analytics

Parse Server exposes a single analytics endpoint, `POST /events/<name>`. The
gem wraps it as `Parse.track_event`. Dimensions are passed via the
`dimensions:` keyword — loose symbol arguments would be absorbed by the
forwarded `**opts` splat under Ruby 3 keyword separation and would never
reach Parse Server.

```ruby
# Custom event with dimensions
Parse.track_event("post_viewed", dimensions: { source: "feed", workspace: "w1" })

# Parse's conventional app-launch event
Parse.track_event("AppOpened")

# Error tracking
Parse.track_event("error", dimensions: { code: "E_RATE_LIMIT" })
```

The call is a blocking HTTP POST — wrap in a thread or background job if you
don't want it on the request path.

**Reading events back:** Parse Server's default `analyticsAdapter` is a no-op:
events POSTed to `/events` are accepted but neither persisted nor queryable
through the SDK. (Operators who wire a custom adapter decide what to do with
each event. The legacy parse.com eight-dimension cap does NOT apply to Parse
Server out of the box; if a cap matters to you, your adapter enforces it.)

If you need to query analytics, persist them to a regular `Parse::Object`
subclass yourself:

```ruby
class AnalyticsEvent < Parse::Object
  property :name, :string, required: true
  property :dimensions, :object
  property :occurred_at, :date
end

AnalyticsEvent.create(name: "post_viewed",
                      dimensions: { source: "feed" },
                      occurred_at: Time.now)

# Aggregation is on the query, not the class
AnalyticsEvent.query.group_by(:name).count
AnalyticsEvent.query.group_by_date(:occurred_at, :day).count
```

That gives you the full query, aggregation, ACL, and mongo-direct surface for
analytics data — at the cost of an extra row write per event.

## Error Handling

```ruby
begin
  song.save!
rescue Parse::RecordNotSaved => e
  puts "Save failed: #{e.message}"
end

# Or check return value
if song.save
  puts "Saved!"
else
  puts "Errors: #{song.errors.full_messages}"
end
```

## More Information

- [CHANGELOG](./CHANGELOG.md) - Full feature history
- [GitHub Releases](https://github.com/neurosynq/parse-stack-next/releases) - Release notes
- [Parse Server Docs](https://docs.parseplatform.org) - Parse Server documentation
