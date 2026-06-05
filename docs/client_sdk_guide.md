# Client SDK Guide

How to use `parse-stack-next` as an **unprivileged Parse client** — the way a
mobile app, browser, untrusted worker, or any process you don't trust with
the master key would use it.

This guide is the complement to the rest of the documentation, which
generally assumes the process holds master-key credentials. Here we assume
the opposite: the SDK is configured **without** a master key, all requests
go over REST, and authorization is carried by the user's `sessionToken`.
Every claim below is locked in by the integration tests under
`test/lib/parse/client_*_integration_test.rb`.

For a runnable starting point, see
[`examples/basic_client.rb`](../examples/basic_client.rb) (a no-master client
with a row-level ACL-enforcement demo) and its master-key counterpart
[`examples/basic_server.rb`](../examples/basic_server.rb).

---

## Why a separate guide?

The default Parse Stack docs lean on convenience surfaces (`Song.find`,
`Song.create!`, `Song.first`) that resolve credentials implicitly through
`Parse.client`. Those calls work transparently because the configured
client carries the master key — Parse Server treats the request as an
admin operation, ACL/CLP/`protectedFields` checks are bypassed, and you
get whatever you asked for.

A client-mode process is the opposite world:

* No master key in the process. Ever. (If it's there, the operator made
  a mistake — the SDK should never paper over it.)
* Authorization is per-call: every save, fetch, query, file upload, and
  cloud-function invocation has to carry the caller's `sessionToken`.
* Parse Server is the enforcement boundary. CLP rejects the call; ACL
  filters rows; `protectedFields` strips columns. The SDK's job is to
  thread the auth context through honestly and surface the server's
  verdict — not to retry-with-master or invent a happy path.
* Several surfaces are simply unavailable: `/aggregate`, `/schemas`, full
  `/sessions` enumeration, `/config` writes. They're master-key-only on
  Parse Server, and the SDK fails closed when you call them without it.

If you've used Parse Stack with the master key and find that "the same
calls just stop working" when you remove it — that's not a regression.
That's Parse Server doing what it's documented to do, and this guide is
the field manual for working within it.

---

## 1. Configuration

### 1.1 No-master-key client

```ruby
require "parse/stack"

Parse.setup(
  server_url:  "https://parse.example.com/parse",
  app_id:      "MY_APP_ID",
  api_key:     "MY_REST_API_KEY",
  master_key:  nil,            # explicit; do NOT set this from env in client builds
  logging:     false,
)

Parse.client.master_key   # => nil
```

That's the whole knob. Once `master_key` is `nil`, every call that
resolves through `Parse.client` (which is essentially all of them) goes
out as a regular REST request. The server has no admin escape hatch to
fall back on.

### 1.2 Building a one-off client

If you need a side client (e.g. a worker that handles uploads on behalf
of a logged-in user) and don't want to touch the global one:

```ruby
client = Parse::Client.new(
  server_url: "https://parse.example.com/parse",
  app_id:     "MY_APP_ID",
  api_key:    "MY_REST_API_KEY",
  master_key: nil,
)
```

Most SDK surfaces operate on the global `Parse.client`; the one-off form
is mostly useful for tests and adapters.

### 1.3 Verifying you're really in client mode

The easiest mistake to make is "I thought I dropped the master key but
something is still threading it through." Pin it down explicitly:

```ruby
raise "client builds must not ship master key" if Parse.client.master_key.present?
```

The test harness ships an `assert_client_mode!` helper that does exactly
this; production code should be just as paranoid.

#### 1.3.1 v5.0: `Parse::Query` master-key default flipped to `nil`

Before v5.0, `Parse::Query#initialize` set `@use_master_key = true`. That
silently broke `Parse.client_mode = true` and every `Parse.with_session`
block: the truthy default propagated into `_opts` on every find, so the
request layer saw an explicit `use_master_key: true` and skipped the
client-mode resolution path entirely. Effect: queries went out
master-key-stamped regardless of operator intent.

v5.0 changes the init value to `nil` (tri-state: "no caller preference"):

- Server-mode unchanged. With a master key configured and no client_mode,
  the request layer still defaults to sending it when nothing else
  expresses a preference.
- Client-mode honored. `Parse.client_mode = true` now actually suppresses
  the master-key header for queries, the way the rest of the surface
  already did.
- Ambient session honored. Inside `Parse.with_session(user) { … }`, a plain
  `Song.all(...)` now picks up the ambient instead of being short-circuited
  by the old `true` default.
- Explicit wins. `query.use_master_key = true` or
  `Song.all(..., use_master_key: true)` still forces the header.

Mongo-direct gate: `Parse::Query#assert_mongo_direct_routable!` treats
a configured master key on the client as an ambient credential in
server mode. Direct-only constraints (Atlas Search-shaped operators,
etc.) route through the mongo-direct path as long as `Parse.client_mode`
is false and `use_master_key` was not explicitly set to `false` — server
apps don't have to thread `use_master_key: true` through every query
that hits a direct-only constraint. The gate raises
`Parse::Query::MongoDirectRequired` for client-mode processes or queries
that explicitly opt out of the master key without supplying a
`session_token` / `.scope_to_user(user)` / `.scope_to_role(role)`.

---

## 2. Authentication

### 2.1 Sign up

A user is created by `POST /users` — no auth required. `Parse::User#save`
on a brand-new user does signup-on-save and the response carries the
fresh `sessionToken`:

```ruby
user = Parse::User.new(
  username: "ada",
  password: "p4ssw0rd!",
  email:    "ada@example.com",
)
user.save                # => true
user.session_token       # => "r:abcd…"
user.id                  # => "oP3Q…"
```

Equivalent explicit form:

```ruby
user.signup!
```

`signup!` raises on failure (duplicate username, missing required field);
`save` returns `false` and populates `user.errors`.

### 2.2 Log in

```ruby
me = Parse::User.login("ada", "p4ssw0rd!")
me.session_token   # => "r:abcd…"
me.logged_in?      # => true
```

`Parse::User.login` **returns nil** on bad credentials — it does not raise.
If you need the underlying error info, drop down to the client:

```ruby
response = Parse.client.login("ada", "wrong")
response.success?   # => false
response.error      # => "Invalid username/password."
```

This duality is intentional. The high-level convenience method matches
what mobile SDKs do; the raw client preserves the response so you can
log or reroute.

#### A user-scoped client straight from login

`Parse::User#session_client` turns a logged-in user into a **non-master client
with that user's token bound**, so you don't thread `session_token:` through
every call. (`Parse.client.become(token)` builds the same thing from any token.)
`Parse::User#with_session` runs a block as the user:

```ruby
client = Parse::User.login("ada", "p4ssw0rd!").session_client
Parse::Query.new("Post", client: client).results     # runs as Ada

# Or a block — every REST-routed op inside is authorized as Ada:
Parse::User.login("ada", "p4ssw0rd!").with_session do
  Post.query.count
  Post.create(title: "Hello")
end
```

`session_client` returns `nil` if the user has no session token (e.g. it was
fetched/saved under the master key rather than logged in). The bound token is
applied as the lowest-priority auth fallback, so an explicit per-call
`session_token:`, a `Parse.with_session` block, or `use_master_key: true` all
still take precedence.

> **Scope boundary.** `with_session` (and `Parse.with_session`) authorize
> **REST-routed** operations (`find` / `get` / `count` / `save`) as the user.
> Mongo-direct queries (`results_direct`, `aggregate`, Atlas search) do **not**
> pick up the ambient session — scope them explicitly with a per-query
> `session_token:` or a scoped `Parse::Agent`. A no-master client like this one
> has no mongo-direct path anyway. To run a query as a user *without* a token —
> via the master key and SDK-side ACL simulation — use
> `Parse::Query#scope_to_user(user)`.

### 2.3 Validate / refresh a session

```ruby
response = Parse.client.current_user(token)
response.success?           # => true
response.result["objectId"] # => "oP3Q…"
```

`current_user` calls `GET /users/me`. A revoked or bogus token raises
`Parse::Error::InvalidSessionTokenError` — catch it if you want a
graceful "please log in again" UX, otherwise let it bubble up.

### 2.4 Log out

```ruby
Parse.client.logout(token)
```

Subsequent `current_user(token)` calls will raise. There's no separate
client-side "session cache" to clear — the token was just a string you
were holding.

### 2.5 Multi-factor auth

If you've loaded the optional `parse/two_factor_auth/user_extension`
module on the server side and configured the matching cloud-code hook,
`Parse::User#mfa_enabled?` and related methods become available. The
plain `login` path still works for users who haven't enrolled; for users
who have, the MFA challenge flow is the standard Parse Server one and
the SDK threads it through.

This guide doesn't reproduce the MFA setup — see the `two_factor_auth`
module source for the full surface.

### 2.6 Anonymous users and upgrading them in place

Some apps want to give a visitor a real session before they pick a
username — so their first writes (a draft post, a cart, a configured
preference) attach to a row that survives across reloads and tabs and
then later promotes to a named account without losing anything.

`Parse::User.anonymous_signup` creates a fully-formed `_User` row with
an `authData.anonymous` provider entry and returns it pre-logged-in.
A client-generated UUID is supplied for the provider payload via
`SecureRandom.uuid`; the SDK constructs the `authData` shape so the
caller doesn't have to:

```ruby
guest = Parse::User.anonymous_signup
guest.session_token  # => "r:abcd…"
guest.anonymous?     # => true
guest.username       # server-assigned random username

draft = Post.new(body: "first thoughts", author: guest)
draft.save(session: guest.session_token)
```

The token is a real session token — every CRUD/query example in §3
works against `guest.session_token` the same way it would for a named
user. ACL stamping under `acl_policy :owner_else_*` picks up the
anonymous user's objectId, so the row remains writable by whoever
holds the upgraded credentials later.

When the visitor signs up for real, **don't create a second `_User`
row** — upgrade the anonymous one in place:

```ruby
Parse.with_session(guest.session_token) do
  guest.upgrade_anonymous!(
    username: "ada",
    password: "p4ssw0rd!",
    email:    "ada@example.com",
  )
end

guest.anonymous?     # => false
guest.username       # => "ada"
guest.session_token  # rotated by the server, applied automatically
```

`upgrade_anonymous!` issues a single `PUT /users/:id` that sets the
new credentials AND explicitly unlinks the anonymous provider in the
same request (`authData: { anonymous: nil }`). The unlink is **not
optional** — leaving `authData.anonymous` attached after a username is
assigned would let anyone who learned the original anonymous UUID
silently log in as the freshly-named account. This is a documented
Parse foot-gun and the SDK closes it in one round trip.

Guards on `upgrade_anonymous!`:

* Requires `Parse.with_session(self.session_token)` (or a directly-set
  `@session_token` on the instance) — the call writes via the user's
  own session, not the master key.
* Refuses to run on a non-anonymous user, on a detached
  `Parse::User.new` with no objectId, and on an instance with no
  session token. All three raise `Parse::Error::AuthenticationError`
  rather than performing an unauthorized PUT.
* On success, clears `password` from memory, applies the server-rotated
  session token (when the server returns one), and runs
  `changes_applied!` so a subsequent `save` doesn't re-transmit
  credentials.

The Parse Server error codes for `username_taken` / `email_taken` /
`email_invalid` / missing-field surface as the existing
`Parse::Error::*` exception family — your existing signup error
handling works unchanged.

---

## 3. CRUD with a session token

The cardinal rule: **every save, fetch, query, and destroy needs to know
which session it's running as.** With no master key, the SDK has no
implicit "do whatever" path; you have to be explicit about who you are.

### 3.1 Save

```ruby
post = Post.new(title: "hello", author: me)
post.save(session: me.session_token)
```

Or, using the lower-level API:

```ruby
Parse.client.create_object(
  "Post", { "title" => "hello" },
  session_token: me.session_token, use_master_key: false,
)
```

`use_master_key: false` is the safety belt — it makes the call fail
loudly if some upstream code accidentally re-introduced a master key.
Get in the habit of writing it on every client-mode call.

> **Gotcha — kwarg absorption.** The SDK's `request` method uses a
> `**opts` splat, which silently absorbs a keyword named `opts:` into
> `{opts: {...}}` and DROPS your session token. Always pass auth as
> direct keywords (`session_token: …, use_master_key: false`), not as
> `opts: { … }`.

### 3.2 Update

```ruby
post.title = "v2"
post.save(session: me.session_token)
```

Or:

```ruby
Parse.client.update_object(
  "Post", post.id, { "title" => "v2" },
  session_token: me.session_token, use_master_key: false,
)
```

### 3.3 Destroy

```ruby
post.destroy(session: me.session_token)
```

If the ACL doesn't grant write to the caller, the destroy returns false
(or raises `Parse::RecordNotSaved` depending on the code path) — the
row is left intact. Parse Server reports this as "Object not found"
which is its uniform shape for "you can't see it OR you can't touch it."

### 3.4 Fetch and query

The class-level convenience methods (`Post.find`, `Post.all`) **do not**
take a `session:` argument because they predate client mode. Use
`Parse::Query` and stamp the token on the query object:

```ruby
q = Post.query
q.session_token = me.session_token
posts = q.where(:likes.gte => 10).order(:likes.desc).limit(20).results
```

For one-off `find_by_id` against a class:

```ruby
Parse.client.fetch_object(
  "Post", id,
  session_token: me.session_token, use_master_key: false,
)
```

`count` works the same way:

```ruby
q.where(:likes.gt => 0).count
```

### 3.5 Pointer includes

```ruby
q = Comment.query
q.session_token = me.session_token
comment = q.where(text: "nice").include(:post, :author).first
comment.post.title    # populated via REST `?include=post`
comment.author.id     # populated via `?include=author`
```

The server applies ACL to the included rows independently. If the
caller can read the comment but not the included `post`, `comment.post`
comes back as a bare pointer (just `objectId` + `className`) rather
than a hydrated object.

### 3.6 The snake_case ↔ camelCase trap

Ruby properties declared as `property :public_field, :string` are sent
on the wire as `publicField`. If you build a CLP schema, `protectedFields`
list, or raw query body, you **must** use the camelCase form:

```ruby
# WRONG — queries a column that doesn't exist server-side
Parse::Query.new("ClientClpProbe").where(public_field: "x")  # SDK rewrites OK
# but:
{ "publicField" => "x" }   # is what hits the wire — make sure the schema matches
```

The Parse Stack query DSL handles the rewrite for you. Raw `find_objects`
/ `create_object` calls do not — pass camelCase keys when you're talking
to the low-level API.

### 3.7 Model callbacks run locally — NOT as Parse Cloud webhooks

This is the most-missed thing on the SDK→server transition. ActiveModel
callbacks declared on your `Parse::Object` subclasses (`before_save`,
`after_save`, `before_create`, `after_destroy`, attribute normalizers,
validations, etc.) execute **in the Ruby process** before the write hits
Parse Server. They are **not** registered as Parse Cloud Code triggers
(`Parse.Cloud.beforeSave('Contact', ...)`).

```ruby
class Contact < Parse::Object
  property :email, :string

  before_save do
    self.email = email.downcase if email.present?
  end
end
```

Concretely:

- `Contact.new(email: "Foo@BAR.com").save` from your Ruby app — the
  `before_save` fires, `email` is lowercased, and `Foo@bar.com` lands on
  the server as `"foo@bar.com"`. Good.
- A record `Contact` created by the iOS SDK, the JS SDK, a webhook, the
  REST API directly, or the Parse Dashboard does **not** see your Ruby
  callback. The server stores whatever it was given, mixed case and all.
- A separate Ruby process that imports the Parse Server schema but does
  **not** define a `Contact` Ruby model also bypasses the callback.
- If you `update_object("Contact", id, { email: "Foo@BAR.com" })`
  directly via the raw client (skipping the model), there is no Ruby
  instance to run the callback on. The raw write goes through unchanged.

If you need invariants enforced on **every** write regardless of which
client sent it, that's Parse Cloud Code on the server (a
`Parse.Cloud.beforeSave('Contact', ...)` trigger in your cloud code
bundle) — not a Ruby model callback. Use Ruby callbacks for app-side
ergonomics (defaults, derived fields, post-save notifications **from
this app**), and use server-side Cloud Code triggers for cross-client
data integrity.

The same caveat applies to `after_save` — and this one bites harder,
because `after_save` is the natural home for "send the welcome email",
"enqueue the embedding job", "post to the activity feed", "invalidate
the cache". All of those only fire when the save originates from a Ruby
process holding a `Contact` model instance and calling `.save` on it.
A `Contact` created by:

- the iOS or JS SDK
- a separate Ruby service that doesn't define the `Contact` model
- the Parse Dashboard
- a direct REST call (`POST /parse/classes/Contact`)
- a Cloud Code `Parse.Cloud.run(...)` that constructs the row via the
  JS Parse SDK

...will not trigger your Ruby `after_save`. The row appears in the
database and your "every Contact gets a welcome email" promise quietly
breaks. If a side effect must fire on **every** save regardless of
client, put it in a Parse Cloud Code `afterSave` trigger (server-side
JS) — or in an external worker that subscribes to a LiveQuery on the
class. Ruby `after_save` is for side effects scoped to *this* app's
saves only.

The same caveat applies to ACL defaults, derived fields, soft-delete
flags, audit columns — anything you wire into a Ruby callback expecting
it to "always run" only runs when the write originates from this Ruby
process through this model class.

#### Same-stack deployments: don't double-fire non-idempotent hooks

A pure no-master-key client (what this guide covers) doesn't host Parse
Cloud Code webhooks, so the only place a callback can run is in your
Ruby model. No double-fire risk on this side of the wire.

That changes the moment the same Ruby process is **also** the master-key
server hosting the `Parse::Webhooks` Rack handler. In that dual-role
deployment, a single `contact.save` from your app can produce two
hook-firing opportunities — the local `after_save` in the calling
thread, *and* the Parse Cloud `afterSave` webhook trigger dispatched
back into the same process. Non-idempotent side effects (welcome
emails, billing increments, outbound API calls) will double up.

The mitigation lives on the **server-side / webhook** docs: the
master-key request origin is what lets a webhook handler short-circuit
when it sees a same-stack save. It is **not** a feature of the client
package and there is nothing to configure here. The principle to carry
across is just: pick one site per non-idempotent side effect (Ruby
model callback **or** Cloud Code webhook, never both), and if you're
about to run a Ruby `after_save` AND a `Parse::Webhooks.route(:after_save,
...)` handler that do the same work, that's the bug. See the webhooks
section of the main README and `lib/parse/webhooks.rb` for the
server-side guidance.

---

## 4. ACL — the row-level boundary

> **For the full ACL + CLP reference**, including aggregate-query
> enforcement asymmetry, Atlas Search, mongo-direct, role hierarchy
> direction, `protectedFields` semantics including the `_User`
> owner-exempt trap, and field-guard write protection, see
> [`acl_clp_guide.md`](./acl_clp_guide.md). The sections below are
> a client-mode quickstart.

Parse Server enforces ACL on every read and write against a non-master
caller. The SDK's job is to (a) thread the session token in so the server
has someone to check against, and (b) compose ACLs correctly on the
wire so the right people get the right access.

### 4.1 ACL policies on a class

```ruby
class Post < Parse::Object
  parse_class "Post"
  acl_policy :public            # everyone can read/write by default
  property :title, :string
end

class Note < Parse::Object
  parse_class "Note"
  acl_policy :owner_else_private  # default — see below
  property :body, :string
  belongs_to :author, as: :user
end
```

| Policy                   | What gets stamped on save                              | When to use                       |
|--------------------------|--------------------------------------------------------|-----------------------------------|
| `:public`                | `{"*": {"read": true, "write": true}}`                 | Public/anon-readable feeds        |
| `:public_read`           | `{"*": {"read": true}}`                                | Read-only catalogs, lookup tables |
| `:private`               | `{}` (master-key-only)                                 | System rows, audit logs           |
| `:owner_else_private`    | Owner ACL if `:author` resolves, else `{}` (master)    | **Default** — safe by default     |
| `:owner_else_public`     | Owner ACL if `:author` resolves, else public           | Public content authored by user   |
| `:owner_but_public_read` | Owner R/W + `{"*": {"read": true}}` (public-read fallback when no owner) | Public posts authored by one user |

`:public_read` is read-anywhere, master-key-write — no client can mutate
the row through ACL. `:owner_but_public_read` is the "public posts with
one author" case: the resolved owner gets R/W while the rest of the world
gets read-only access; when no owner resolves it degrades to
`:public_read` semantics rather than master-key-only.

`:owner_else_private` is the SDK's default for a reason: if your model
forgets to declare an owner field, your rows are stamped master-only and
become invisible to clients. That's exactly what you want — a noisy
failure mode beats a silent permission leak.

### 4.2 Building an ACL on a record

```ruby
post = Post.new(title: "draft")
post.acl.everyone(false, false)       # turn off public
post.acl.apply(me.id, true, true)     # owner: read + write
post.acl.apply_role("Editors", true, true)   # role-grant read+write
post.save(session: me.session_token)
```

Wire shape after `everyone(false, false) + apply(me.id, true, true)`:

```json
{ "<me.id>": { "read": true, "write": true } }
```

The `*` entry is suppressed entirely (or persisted as `nil`, which Parse
Server treats as absent). There's no `{"*": {"read": false}}` on the
wire — that'd be redundant.

### 4.3 What clients see

* `acl.everyone(true, false)` → public-read, public-write-denied. Other
  authenticated users and anonymous clients can fetch the row, but their
  saves on the row are rejected.
* `acl.everyone(false, false) + acl.apply(me.id, true, true)` → strictly
  owner-only. Other users get `nil` on fetch (Parse Server filters by
  ACL on the query result; the row simply isn't in their result set).
* `:owner_else_private` with no resolved owner → empty ACL `{}`. Master
  key only. Even the user who created the row can't see it from a
  client session unless you also stamp an ACL.

### 4.4 The `_User` row

A user's own `_User` row is ACL'd to themselves at signup. They can
update their own email/password from a client session:

```ruby
Parse.client.update_object(
  "_User", me.id, { "email" => "new@example.com" },
  session_token: me.session_token, use_master_key: false,
)
```

But **cannot** modify another user's `_User` row — Parse Server returns
"Insufficient auth." on the cross-user write attempt. This is enforced
server-side; the SDK just relays the rejection.

---

## 5. Roles — and a direction gotcha

Role grants apply at the row level the same way per-user grants do —
`acl.apply_role("Admin", true, true)` puts the Admin role on the row's
ACL and any user in Admin (or any role that inherits Admin) gets access.

### 5.1 Membership

```ruby
admin_role = Parse::Role.find_or_create("Admin")
admin_role.add_users(alice, bob).save
```

This must run under the master key. Parse Server defaults `_Role` CLP
to master-only writes — a non-master client cannot rename a role, add
users to it, or create one. Calling `update_object("_Role", …)` from
client mode returns an auth error; the SDK does not silently strip the
write.

### 5.2 Hierarchy — read this carefully

This is the single most counter-intuitive piece of Parse Server role
semantics. The shorthand "role hierarchy" can mean two opposite things
and the SDK exposes both, with sharply different names.

Per Parse Server's `getAllRolesForUser` expansion: a role's `roles`
relation contains *child roles whose users inherit access through this
role*. Put another way: if you want **SuperAdmin to inherit Admin's
capabilities**, you put **SuperAdmin into Admin's `roles` relation** —
not the reverse.

The SDK exposes a direction-explicit method to avoid mistakes:

```ruby
super_role = Parse::Role.find_or_create("SuperAdmin")
super_role.add_users(super_user).save

# "SuperAdmin should inherit everything Admin can do."
super_role.inherits_capabilities_from!(admin_role)
```

Under the hood this adds SuperAdmin to Admin's `roles` relation. Now any
row ACL'd to `role:Admin` is readable by SuperAdmin members too, because
the server's role-graph expansion traverses Admin → SuperAdmin when
resolving the caller's effective roles.

The older `add_child_role` method goes the **other direction** and is
preserved for backwards compatibility. If you find yourself reaching for
it: stop, and use `inherits_capabilities_from!` instead. Getting the
direction wrong is a privilege-escalation bug, not just a confusion.

---

## 6. CLP — the class-level boundary

Class-Level Permissions live one layer above ACL. They gate **what
operations are even allowed on the class** before ACL is consulted on
individual rows.

CLP is master-key-only to configure. From client mode you observe its
effects; you can't change it.

### 6.1 The common shape

```ruby
schema = {
  "className" => "Note",
  "fields" => {
    "body"        => { "type" => "String" },
    "secretField" => { "type" => "String" },
  },
  "classLevelPermissions" => {
    "find"   => { "requiresAuthentication" => true },
    "get"    => { "requiresAuthentication" => true },
    "count"  => { "requiresAuthentication" => true },
    "create" => { "requiresAuthentication" => true },
    "update" => { "requiresAuthentication" => true },
    "delete" => { "requiresAuthentication" => true },
    "addField" => {},                       # master-key-only
    "protectedFields" => {
      "*" => ["secretField"],               # strip for everyone but master
    },
  },
}

Parse.client.update_schema("Note", schema)
```

With `requiresAuthentication: true` on `find/get/create`, an anonymous
(no-token) client call gets rejected before ACL is even consulted —
the response carries `code: 101` and an error like
`"Permission denied, user needs to be authenticated."`. CLP errors
**do not raise** in the SDK; check `response.success?` and read
`response.error`.

### 6.2 `protectedFields` — write-but-not-read

```ruby
"protectedFields" => { "*" => ["secretField"] }
```

This is the canonical "client sets it but cannot read it back" pattern.
A client-mode caller can write `secretField` on create/update (Parse
Server accepts the field in the POST body), but the GET/find readback
omits the column. Master-key fetch still sees the value, confirming it
was persisted — not silently dropped.

Both `Parse.client.fetch_object` and `Parse::Query#results` strip the
protected field; the SDK doesn't try to re-synthesize it from any
cache. If you see it in your client-side result, your CLP is wrong.

Reads are stripped today; the **write** response historically still
echoed the value back in the create/update reply. Parse Server's
`protectedFieldsSaveResponseExempt` option closes that — its default
**will change to `false`** in a future version, which strips
`protectedFields` from write responses too. Set
`protectedFieldsSaveResponseExempt: false` in your server config to opt
in early. The SDK needs no changes: `save` merges the response onto the
object (it only overwrites fields the reply contains), so a stripped
protected field keeps its locally-assigned value rather than being
nulled out.

### 6.3 `_Installation` is special — CLP can't override the hardcoded gates

Parse Server hardcodes the access policy for `_Installation` at the REST
layer. CLP on this class is a thin overlay on top of behavior that is
already constrained, so `set_clp` (or a server-side CLP edit via the
Dashboard) can only tighten the operations Parse Server lets you
configure — it cannot loosen the ones the server pins to master-only.

| Operation  | What's actually enforced                                                                 |
|------------|------------------------------------------------------------------------------------------|
| `find`     | **Master key only. Hardcoded.** CLP changes are ignored by the server.                  |
| `delete`   | **Master key only. Hardcoded.** CLP changes are ignored by the server.                  |
| `create`   | Open to anonymous clients — `X-Parse-Installation-Id` is the credential.                |
| `update`   | Open when the request's `installationId` matches the record; else master key.           |
| `get`      | CLP applies normally.                                                                   |
| `count`    | CLP applies normally.                                                                   |
| `addField` | CLP applies normally.                                                                   |

Safe to tighten:

* `get` → `requiresAuthentication: true` or master-only. SDKs don't
  normally GET their own installation from the server; they cache
  `currentInstallation` locally.
* `count` → master-only. The push flow doesn't need it, and it removes a
  small enumeration signal.
* `addField` → master-only. Good hardening default for any class.
* `protectedFields` → hide `deviceToken`, `GCMSenderId`, `pushType` from
  non-master reads. These are write-only from the client's perspective
  in normal SDK flows.

Do NOT tighten:

* `create` requiring authentication — breaks first-launch device
  registration for users who haven't logged in yet. If your app pushes
  to anonymous users, this kills it.
* `update` requiring authentication — breaks silent device-token
  refresh and channel subscribe/unsubscribe before login.
* Pointer-based `readUserFields` / `writeUserFields` on `_Installation`
  — a device has no stable owning user (it can outlive a session and
  change users), so user-pointer ACLing is unreliable.
* Anything on `find` / `delete` — the server ignores it.

If your app genuinely requires login before any installation write, put
the policy in a `beforeSave('_Installation')` Cloud Code trigger rather
than in CLP:

```js
Parse.Cloud.beforeSave('_Installation', ({ user, master }) => {
  if (!master && !user) throw 'login required';
});
```

The trigger fires under master-key context and can inspect `request.user`
directly without disturbing the anonymous registration handshake that
the client SDKs depend on.

### 6.4 ACL still applies under CLP

CLP says "is this class operation allowed at all?". ACL says "given the
operation is allowed, which rows does this caller see / touch?". An
authed user who passed the CLP gate still gets their result set filtered
by ACL — if Alice writes a row with `acl.apply(alice.id, true, true)`
only, Bob's query for it (under his own session) returns nothing.

### 6.5 The other system classes — where CLP isn't the whole story

`_Installation` (section 6.3) isn't unique. Several Parse Server system
classes either ignore CLP entirely or layer it under hardcoded behavior.
Treat this table as the authoritative answer for "what can I actually
configure here?":

| Class                                                                                            | Does CLP do anything?                                                                                              |
|--------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| `_User`                                                                                          | Yes, but layered under hardcoded protections (password never returned, `authData` stripped from non-master finds, unauth update requires matching session token, email/username lowercasing, owner-exempt `protectedFields`). |
| `_Role`                                                                                          | Yes, layered under role-name regex, relation validation, and hierarchy integrity checks.                            |
| `_Installation`                                                                                  | Partial — only `get`, `count`, `addField`, and `protectedFields` are configurable; `find` and `delete` are master-only regardless of CLP. See section 6.3. |
| `_Session`                                                                                       | Mostly redundant — non-master queries are silently rewritten to `{ user: <current user> }` (`RestQuery.js`), so a caller only ever sees their own sessions. `find` also requires a session token. |
| `_JobStatus`, `_PushStatus`, `_Hooks`, `_GlobalConfig`, `_GraphQLConfig`, `_JobSchedule`, `_Audience`, `_Idempotency`, `_Join:*` (all relation join tables) | No — master-key-only at the REST layer (`SharedRest.js`). CLP changes are ignored.                                  |

Practical consequences when you're building a client-mode app:

* Don't query `_JobStatus`, `_PushStatus`, `_Audience`, `_JobSchedule`,
  or any `_Join:*` table from the client — those calls require master
  key. In the SDK, the corresponding model classes
  (`Parse::JobStatus`, `Parse::PushStatus`, `Parse::Audience`,
  `Parse::JobSchedule`) are server-side helpers. Auto-promote to a
  master-key client or expose them through a Cloud Code function.
* On `_Session`, you don't need ACLs or CLP to scope queries to the
  caller — Parse Server already does that. You also can't grant a user
  visibility into another user's sessions through CLP.
* On `_User`, never assume CLP alone gates a flow. Password changes,
  email verification, and session-token rotation have their own paths
  in `RestWrite.js`; they fire even if your CLP looks restrictive.
* On `_Role`, the role graph is validated server-side. CLP can gate
  who can call create/update/delete, but the contents of the `roles`
  and `users` relations are still checked for cycles and bad names.

### 6.6 `_User` field visibility — master-only vs. self-only

Two patterns come up constantly on `_User`:

* **Master-only fields** — admin-side metadata that the user themselves
  should not see. Examples: `my_opinion_of_them`, `risk_score`,
  `moderation_notes`.
* **Self-visible fields** — private profile data the user should see
  on their own row, but nobody else. Examples: `favorite_color`,
  `private_notes`, full `email`.

Vanilla `protectedFields` doesn't express either cleanly on `_User`,
because Parse Server's `protectedFieldsOwnerExempt` option (historical
default **true**) silently exempts the owning user from every
`protectedFields` rule on `_User`. So if you write `protect_fields "*",
[:risk_score]`, the user still sees their own `risk_score`. (Parse
Server's default for this option **is changing to `false`** in a future
version; until your server adopts that default, set it explicitly as in
step 1.) The fix has two moving parts on the server:

1. Start Parse Server with `protectedFieldsOwnerExempt: false`.
2. Add a self-pointer field on `_User` and populate it from a Cloud
   Code trigger so each row points at itself:

   ```js
   Parse.Cloud.beforeSave(Parse.User, (req) => {
     const u = req.object;
     if (!u.get('self')) u.set('self', u);
   });
   ```

With those in place, the SDK exposes a small DSL on `Parse::User`:

```ruby
class Parse::User
  property :my_opinion_of_them, :string
  property :favorite_color, :string

  master_only_fields :my_opinion_of_them
  self_visible_fields :favorite_color, via: :self   # name of the self-pointer
end
```

That expands to:

```ruby
protect_fields "*",                ["myOpinionOfThem", "favoriteColor"]
protect_fields "userField:self",   ["myOpinionOfThem"]
```

Resolution (recall: matching groups intersect):

| Caller         | Matching groups            | Hidden (intersection)               | Visible       |
|----------------|----------------------------|-------------------------------------|---------------|
| Other user     | `*`                        | `myOpinionOfThem`, `favoriteColor`  | neither       |
| The user itself| `*` ∩ `userField:self`     | `myOpinionOfThem` only              | `favoriteColor` |
| Master key     | none (master bypasses)     | nothing                             | both          |

If your code uses raw `protect_fields` on `_User` directly, the SDK
emits a one-time advisory pointing at these helpers and reminding you
to set `protectedFieldsOwnerExempt: false`. You can still use the raw
form — the override calls through — but the warning is there because
the default Parse Server setting will silently negate a lot of what
the raw `protect_fields` calls look like they're doing.

---

## 7. Files

```ruby
contents = File.read("note.txt")
response = Parse.client.create_file(
  "note.txt", contents, "text/plain",
  session_token: me.session_token, use_master_key: false,
)
file_name = response.result["name"]   # server-assigned, deduplicated
file_url  = response.result["url"]

# Attach to a row.
file = Parse::File.new(file_name, nil, "text/plain")
file.url = file_url
post = Post.new(title: "with-file", attachment: file)
post.save(session: me.session_token)
```

Parse Server's `fileUpload` configuration controls who's allowed to
upload:

* `enableForPublic: true` — anonymous clients can upload.
* `enableForAnonymousUser: true` — clients with an anonymous-user
  Parse session can upload.
* `enableForAuthenticatedUser: true` — clients with a real session can
  upload.

The SDK does not pre-flight this — if uploads are disabled, the server
returns a `File upload by …` error and the SDK surfaces it. If you want
authenticated uploads only, set `enableForPublic: false` and
`enableForAnonymousUser: false` and require a session token on every
upload call.

`Parse::File#save` (the convenience surface) runs through `Parse.client`
without an explicit session, so it inherits whatever session the
default client is configured with — which for client mode means
"anonymous unless your server allows it." Prefer
`Parse.client.create_file(…, session_token: …)` in client builds.

---

## 8. Cloud Code

```ruby
response = Parse.call_function(
  "myFunction", { argument: "value" },
  session_token: me.session_token, use_master_key: false,
)
response.result   # whatever the cloud function returned
```

Cloud functions run server-side with whatever auth context you give
them. `Parse.User.current` inside the cloud function resolves to the
session token's user — the same user who called the function from the
client. Master-key behavior inside cloud functions is at the cloud
function's discretion (it can call `Parse.useMasterKey()` server-side).
From the SDK's perspective: pass the session token, get back the
function's result.

`beforeSave` / `afterSave` hooks fire on client-mode saves the same way
they fire on master-key saves. If you have a hook that promotes
permissions or validates a write, it runs on the client request — the
SDK doesn't bypass cloud-code hooks just because the caller is
unprivileged.

### 8.1 Push notifications — server-side only via a cloud function

Parse Server's `POST /parse/push` endpoint is **master-key-only**.
There is no session-token authorization model on this surface; the
server unconditionally rejects pushes that aren't admin-stamped. The
SDK fails fast on this in client mode rather than letting the call
leave the process anonymous:

```ruby
Parse.client.push({ where: { deviceType: "ios" }, data: { alert: "hi" } })
# => raises Parse::Error::AuthenticationError("requires master key")
```

The guard fires at the SDK boundary, **before any network request**.
Passing `use_master_key: true` from a client-mode caller still raises
— the guard checks the client's actual `master_key`, not the per-call
opt. This is intentional: a no-master client cannot send a push under
any flag combination, and the failure is loud enough that callers
notice in dev rather than shipping a silent no-op to production.

The correct pattern is to put push behind a **cloud function** that
the client invokes with its session token. The function decides (a)
whether the caller is allowed to trigger this push and (b) which
audience the push targets — both decisions happen server-side under
admin context:

```js
// In cloud/main.js on the server
Parse.Cloud.define("notifyFollowers", async (req) => {
  const user = req.user;
  if (!user) throw "Authentication required";

  // Server-side authz: only paid accounts can fan-out push
  if (!user.get("subscriptionActive")) {
    throw "Subscription required to send notifications";
  }

  await Parse.Push.send(
    {
      where: new Parse.Query("_Installation").equalTo("followsUser", user),
      data:  { alert: req.params.message, badge: "Increment" },
    },
    { useMasterKey: true }  // server-side, never trusted from the client
  );

  return { sent: true };
});
```

From the client, the call is an ordinary cloud-function invocation
threaded with the session token — no master key in the client
process, no `/push` REST call, no chance of audience-targeting being
controlled by an attacker who tampers with the wire payload:

```ruby
Parse.with_session(me.session_token) do
  response = Parse.call_function(
    "notifyFollowers",
    { message: "New post" },
    use_master_key: false,
  )
  response.success?   # => true / false
end
```

Two reasons this is the right shape, not just a workaround:

1. **Audience targeting belongs on the server.** A client that
   constructs a `where:` query and posts it to `/push` has full
   control over who receives the notification. With a cloud function
   in front, the server owns the `Parse.Query("_Installation")`
   construction; the client only supplies the message body.
2. **The same cloud function is a natural choke point for rate
   limiting, abuse signals, and audit trails.** None of those belong
   in a client process, and `/push` doesn't expose hooks for them.

The same pattern applies to anything else master-key-only that you
want a client to trigger — see §12 for the full master-only matrix.

---

## 9. Analytics

`POST /events/<name>` is a public-writable surface and the SDK relays it
without requiring auth. The top-level `Parse.track_event` shortcut takes
dimensions as a keyword so Ruby 3 keyword-separation doesn't swallow them
into `**opts`:

```ruby
Parse.track_event("search",
  dimensions: { priceRange: "1000-1500", source: "ios", dayType: "weekday" }
)
```

Threaded with a session token (or any other request-layer option):

```ruby
Parse.track_event("search",
  dimensions: { source: "ios" },
  session_token: me.session_token,
  use_master_key: false,
)
```

If you call `Parse.client.send_analytics` directly, the dimensions must be
the second **positional** argument — passing them as bare keywords would
also be absorbed by `**opts`:

```ruby
Parse.client.send_analytics(
  "search",
  { priceRange: "1000-1500", source: "ios" },          # positional Hash
  session_token: me.session_token, use_master_key: false,
)
```

Parse Server's default `analyticsAdapter` is a no-op — events are accepted
but neither persisted nor queryable through the SDK. (The legacy parse.com
eight-dimension cap does NOT apply to Parse Server out of the box; if you
configure a custom adapter, it decides whether to cap and how.) For
queryable analytics, define a `Parse::Object` subclass and write rows;
see the "Analytics" section of `docs/usage_guide.md`.

Parse Server also accepts `at:` for backfilling the event timestamp; pass
it inside the dimensions hash so it reaches the POST body:

```ruby
Parse.track_event("session_start",
  dimensions: { at: (Time.now - 60).utc.iso8601, platform: "test_harness" }
)
```

---

## 10. Cloud Config

`GET /config` returns the app's Cloud Config. Parse Server **automatically
strips entries whose `masterKeyOnly` flag is true** when the caller is
not the master key — the client never sees those values.

```ruby
Parse.client.config!              # force fetch
Parse.client.config["theme"]      # public key, visible
Parse.client.config["api_secret"] # nil — masterKeyOnly entry, stripped
Parse.client.master_key_only      # {} for non-master callers
```

`PUT /config` is master-key-only. From client mode `Parse.client.update_config(…)`
either returns false or raises an auth-class `Parse::Error`. The SDK
does not silently downgrade or retry the write.

---

## 11. LiveQuery

LiveQuery is opt-in in the SDK because it opens a WebSocket egress
surface that operators should consciously enable:

```ruby
Parse.live_query_enabled = true
require "parse/live_query"

client = Parse::LiveQuery::Client.new(
  url:            "wss://parse.example.com/parse",
  application_id: "MY_APP_ID",
  client_key:     "MY_REST_API_KEY",
  master_key:     nil,             # explicit — see below
  auto_connect:   true,
)

sub = client.subscribe(
  "Post",
  where:         { author: me },
  session_token: me.session_token,
)
sub.on(:create) { |row| handle_new(row) }
sub.on(:update) { |row| handle_update(row) }
```

Subscriptions are scoped by `session_token` and ACL is enforced
server-side on every event before it goes out the WebSocket — Bob will
not receive an event for an ACL-private row Alice creates, even if his
subscription matches the `where` clause.

> **Master-key authorization is per-CONNECTION, not per-subscription.**
> Parse Server resolves master-key (ACL/CLP-bypass) authorization once,
> from the connect frame; once set, EVERY subscription on that socket
> bypasses ACL/CLP. The SDK therefore keeps connections **ACL-scoped by
> default**: a configured `master_key` does NOT elevate the connection.
> To build an admin (ACL-bypassing) connection — an event tap that sees
> every row regardless of ACL — opt in explicitly:
>
> ```ruby
> admin = Parse::LiveQuery::Client.new(
>   url: "wss://parse.example.com/parse",
>   application_id: "MY_APP_ID",
>   master_key: ENV["PARSE_MASTER_KEY"],
>   use_master_key: true,   # whole connection bypasses ACL/CLP; warns at connect
> )
> ```
>
> There is no per-subscription master key — `subscribe(use_master_key: true)`
> on a scoped connection warns and stays ACL-scoped. For a process that
> needs both scoped and admin streams, use two separate clients. Use
> `client.admin_connection?` to check whether a connection is elevated.

> **Configuration tip.** `Parse::LiveQuery::Client.new` reads
> `master_key` from configuration if you omit it. Passing
> `master_key: nil` **explicitly** in client builds is still good
> hygiene (the SDK preserves a sentinel so it can tell "not provided"
> apart from "explicitly nil"), but note that as of v5.1.0 a present
> master key alone no longer elevates a LiveQuery connection — only
> `use_master_key: true` does.

---

## 12. Endpoints that fail closed in client mode

These exist for completeness — they ALL require the master key and the
SDK will fail loudly (raise or return an unsuccessful response) when
you call them without it:

| Endpoint                  | SDK call                                | Why master-only                                       |
|---------------------------|-----------------------------------------|-------------------------------------------------------|
| `POST /aggregate/<Class>` | `Parse.client.aggregate_pipeline(…)`    | Bypasses ACL/CLP/`protectedFields` server-side        |
| `GET /schemas`            | `Parse.client.schemas`                  | Schema introspection is admin-only                    |
| `PUT /schemas/<Class>`    | `Parse.client.update_schema(…)`         | Schema mutation is admin-only                         |
| `PUT /config`             | `Parse.client.update_config(…)`         | Config mutation is admin-only                         |
| `_Role` mutation          | `Parse.client.update_object("_Role", …)`| Default CLP locks `_Role` writes to master            |
| Cross-user `_User` write  | `Parse.client.update_object("_User", o)`| ACL on `_User` rows blocks cross-user writes          |
| `_Session` enumeration    | `Parse.client.find_objects("_Session")` | Scoped to caller; anon gets rejected; no master = no full list |

Trying to call any of these without master should be treated as a code
smell, not a thing to work around. If you find yourself wanting to: the
correct fix is almost always (a) put the operation behind a cloud
function that runs server-side with `useMasterKey`, then call that
cloud function from the client, or (b) move the work to a privileged
worker process that's separate from your client deployment.

---

## 13. Error handling — the response shape

The SDK has two error paths and you need to be aware of both:

* **HTTP-level errors (401/403/5xx).** These come back as `Parse::Error`
  subclasses and `raise`. Wrap calls that might hit auth-class failures
  in `begin/rescue Parse::Error => e`.
* **Parse-protocol errors (`code: 101` etc.).** These return a
  `Parse::Response` with `response.success?` false and the message on
  `response.error`. They do **not** raise. The most common one is the
  CLP/ACL denial — `"Permission denied"`, `"Object not found"` (Parse
  Server's uniform shape for "you can't see it OR you can't touch it"),
  or `"Insufficient auth"`.

Robust client code checks both:

```ruby
begin
  response = Parse.client.update_object(
    "Post", id, { "title" => "v2" },
    session_token: me.session_token, use_master_key: false,
  )
  if response.success?
    handle_ok(response.result)
  else
    handle_denied(response.error)   # CLP/ACL rejection — not an exception
  end
rescue Parse::Error::InvalidSessionTokenError => e
  prompt_login_again(e)             # token revoked / expired
rescue Parse::Error => e
  log_and_surface(e)                # HTTP-level or transport failure
end
```

A bare `assert_raises(Parse::Error)` around a CLP rejection will be
silently wrong — the call returns an unsuccessful response, doesn't
raise. The test suite codifies this; production code should too.

---

## 14. Putting it together

A complete client-side write that respects ACL, threads auth, and
handles both error shapes:

```ruby
require "parse/stack"

Parse.setup(
  server_url: ENV.fetch("PARSE_SERVER_URL"),
  app_id:     ENV.fetch("PARSE_APP_ID"),
  api_key:    ENV.fetch("PARSE_REST_KEY"),
  master_key: nil,
  logging:    false,
)

raise "client builds must not ship master key" if Parse.client.master_key.present?

class Note < Parse::Object
  parse_class "Note"
  acl_policy :owner_else_private
  property :body, :string
  belongs_to :author, as: :user
end

def create_note(username:, password:, body:)
  me = Parse::User.login(username, password)
  return [:auth_failed, nil] unless me

  note = Note.new(body: body, author: me)
  # owner_else_private resolves :author → stamps ACL{ me.id => rw }
  begin
    if note.save(session: me.session_token)
      [:ok, note]
    else
      [:rejected, note.errors]
    end
  rescue Parse::Error => e
    [:error, e]
  end
end
```

That's the full shape. No master key in sight, no implicit ambient
auth, every call carries its session, both error paths handled
explicitly.

---

## 15. Audit logging — what gets redacted, what doesn't

When `Parse.logging` is enabled (or you've installed a custom logger
on `Parse::Client`), the request/response middleware writes a record
of every HTTP call the SDK makes. That log is **operational data**
— it sits in your application log stream, gets shipped to whatever
log aggregator you use, and is readable by anyone with access to
that aggregator. The SDK assumes the log stream is **less privileged
than the Parse Server itself** and redacts accordingly.

### 15.1 What is automatically redacted

`Parse::Middleware::BodyBuilder` runs two passes over every logged
request and response — a key-name-based scrub (`scrub_sensitive!`)
and a shape-based vector compactor (`compact_vectors!`).

**Body fields** — when a hash key matches any of the
`SENSITIVE_FIELDS` names (case-insensitive), the entire **value**
under that key is replaced with the literal string `"[FILTERED]"`.
The walker recurses into nested hashes and arrays, so a sensitive
key buried inside a `batch` envelope or under a deeply-nested
pointer payload is still caught. The walker also detects strings
that look like embedded JSON (e.g. a serialized log line stored
back as a field value) and re-runs the scrub on them.

Sensitive key names — matched case-insensitively:

| Key name                                | Replaced with   |
|-----------------------------------------|-----------------|
| `password`                              | `"[FILTERED]"`  |
| `token`, `sessionToken`, `session_token`| `"[FILTERED]"`  |
| `access_token`, `refreshToken`, `refresh_token` | `"[FILTERED]"` |
| `authData` (the entire provider block)  | `"[FILTERED]"`  |
| `masterKey`, `master_key`               | `"[FILTERED]"`  |
| `apiKey`, `api_key`                     | `"[FILTERED]"`  |
| `clientKey`, `client_key`               | `"[FILTERED]"`  |
| `javascriptKey`, `javascript_key`       | `"[FILTERED]"`  |

Two notes on the `authData` row: (a) the WHOLE provider block is
replaced — `authData.anonymous.id`, `authData.facebook.access_token`,
`authData.apple.id_token` all disappear together, so OAuth tokens
never escape into logs even on a provider the SDK doesn't know
about yet; (b) the redactor catches `authData` whether it appears
in a login payload, a signup payload, an `upgrade_anonymous!` PUT,
or a passing-through `GET /users/me` response.

`Parse::Middleware::BodyBuilder.redact(str)` is also exposed as a
last-line string-level pass that re-applies a regex over the
already-scrubbed text. The regex catches the small set of cases the
structural walker can miss — `password=hunter2` style query strings
in URLs, sensitive values inside array elements, and any embedded
text the structural pass already converted to `"[FILTERED]"` is
left alone (the regex is a backstop, not a re-redactor).

**Request headers** — these are always replaced with `"[FILTERED]"`
in debug logs, matched case-insensitively against the Faraday
header keys:

| Header                                  |
|-----------------------------------------|
| `X-Parse-Master-Key`                    |
| `X-Parse-REST-API-Key`                  |
| `X-Parse-Session-Token`                 |
| `X-Parse-JavaScript-Key`                |
| `Authorization`                         |
| `Cookie`                                |
| `X-Api-Key`                             |
| `OpenAI-Organization`, `OpenAI-Project` |
| `Anthropic-Api-Key`                     |

The OpenAI/Anthropic entries cover the case where embedding-provider
HTTP traffic shares the Parse logging path — the official OpenAI auth
header is `Authorization: Bearer …` (covered above), but Organization
and Project IDs are account-identifying metadata operators may not
want published.

**Vector embeddings** — see §15.3.

The redactor operates on a copy of the body so the live
request/response objects keep their values; subsequent middleware
handlers (retry, cache, error mapping, model hydration) see the real
data, only the log line is scrubbed.

### 15.2 What is **not** redacted

The redactor is deliberately conservative. These ride through to the
log stream as-is, and you should treat your log stream's access
controls accordingly:

* **Class-level data values** — every saved/fetched row's columns
  end up in the log when `Parse.logging` is at debug level. If you
  store PII (email, phone, addresses, profile body text), it lands
  in logs in the clear. The SDK can't tell PII from non-PII at this
  layer.
* **Query bodies** — every `where:` clause is logged verbatim. A
  query like `Post.where(authorEmail: "ada@…")` puts the email
  in the log.
* **Cloud function arguments and return values** — `Parse.call_function`
  arguments and the cloud function's response body are logged in
  full. If your cloud function accepts or returns a secret, redact
  it before logging.
* **File names, file URLs, file sizes.** `POST /files/<name>` and
  the resulting `Parse.File` URL are logged. The bytes themselves
  are not (the body builder uses a `…` placeholder for binary
  payloads).
* **Email addresses on `_User` rows.** Email is treated as ordinary
  column data — not redacted at this layer. Use Parse Server's
  `protectedFields` if you want it stripped on cross-user reads.

### 15.3 Vector embeddings

Embeddings are a special case worth calling out — they are caught
by **shape**, not by key name. A 1536-float embedding inlines as
~25 KB per logged row, and embeddings are *reversible-by-similarity*
against a public model: an attacker who scrapes operator logs can
recover topic, sentiment, and sometimes near-verbatim short text
from the raw vector. The `compact_vectors!` pass walks the logged
body and replaces any numeric-only `Array` of length ≥ 32 with the
single placeholder string `"<vector dims=N>"`. Coverage:

* `$vectorSearch.queryVector` in aggregate request bodies.
* `:vector` field values in `POST` / `PUT` request bodies.
* `Klass.find_similar(vector: …)` request bodies.
* Batched embedding-provider response shapes (when you've installed
  your own provider that logs through this middleware).

The 32-element threshold sits well below every common embedding
width (BGE-small 384, Cohere 1024, OpenAI small 1536, OpenAI large
3072) and well above any normal Parse `Array` property — tags,
role pointer lists, attachment id arrays. The all-Numeric guard
prevents the rule from mangling long string-array or
object-array properties.

### 15.4 Master-key context — what's logged regardless

A few outbound calls log enough metadata to identify a request even
under redaction:

* HTTP method + URL path are always logged.
* Request `objectId` (path segment) is always logged.
* Response status code and Parse `code` field are always logged.

This is deliberate — without these, an audit trail can't link a
user complaint ("I lost my draft at 14:02") to a server-side action.
The redactor's job is to keep secrets and reversible identifiers
out of the log, not to anonymize the trail itself.

### 15.5 Custom redaction

If you store sensitive values in column data and need them stripped
before they hit your log aggregator, the cleanest hook is a custom
middleware in front of `BodyBuilder` — or, if you only need to
filter the final formatted log line, a `Logger` subclass that
overrides `add` and applies a regex strip. Don't try to mutate the
`Parse::Response` body to redact inbound data; downstream model
hydration runs against that body and needs the real values.

```ruby
class RedactingLogger < Logger
  SENSITIVE = /"(stripeCustomerId|ssn|apiKey)":"[^"]+"/

  def add(severity, message = nil, progname = nil, &block)
    if message.is_a?(String)
      message = message.gsub(SENSITIVE, '"\1":"<redacted>"')
    end
    super
  end
end

Parse.setup(
  server_url: "…", app_id: "…", api_key: "…",
  logger: RedactingLogger.new($stdout),
  logging: :debug,
)
```

The custom-field redaction is **your** responsibility — the SDK
only knows about the auth surface and the embedding surface
because those are stable across deployments. Anything app-specific
(tenant ids, payment metadata, internal account numbers) needs an
app-specific filter.

---

## 16. Client-mode `Parse::Agent` (v5.0)

`Parse::Agent` follows the same posture as the rest of this guide. When
constructed against a no-master client with a session token, it enters
*client mode* and restricts itself to a session-token REST allowlist
(`list_tools`, `get_object`, `get_objects`, `query_class`,
`count_objects`, `get_sample_objects`, plus the mutation trio
`create_object` / `update_object` / `delete_object` behind an
`allow_mutations:` gate). Everything that needs master-key REST
(`aggregate`, `atlas_*`, `get_all_schemas`) or a direct MongoDB
connection (mongo-direct aggregations, vector search) is refused at the
dispatch ceiling.

```ruby
agent = Parse::Agent.new(session_token: me.session_token)
agent.client_mode?      # => true
agent.allow_mutations?  # => false (default)

agent.execute(:query_class, class_name: "Post", limit: 10)  # ACL-enforced by Parse Server

writer = Parse::Agent.new(session_token: me.session_token, allow_mutations: true)
writer.execute(:create_object, class_name: "Post", fields: { title: "Hi" })
```

`acl_user:` and `acl_role:` are refused at construction on a no-master
client — they're SDK-side identity assertions that require the
master-key mongo-direct path to enforce. Use `session_token:` as the
identity instead. Full reference (custom tools with `client_safe: true`,
sub-agent inheritance, refusal-message shapes) is in
[`docs/mcp_guide.md` § Client Mode](mcp_guide.md#client-mode--session-token-only-agents-v50).

---

## 17. Cross-references

* `test/lib/parse/client_rest_auth_integration_test.rb` — signup, login, logout, current_user, MFA surface
* `test/lib/parse/client_rest_crud_integration_test.rb` — save, fetch, update, destroy, query, include, ACL
* `test/lib/parse/client_rest_acl_integration_test.rb` — ACL policies, wire shape, cross-user `_User` write
* `test/lib/parse/client_rest_roles_integration_test.rb` — role membership, hierarchy direction, `_Role` write block
* `test/lib/parse/client_rest_clp_anonymous_integration_test.rb` — CLP enforcement and `protectedFields`
* `test/lib/parse/client_rest_files_integration_test.rb` — authed + anonymous file upload behavior
* `test/lib/parse/client_rest_analytics_integration_test.rb` — `/events` round-trip under client mode
* `test/lib/parse/client_rest_cloud_config_integration_test.rb` — `/config` visibility and write rejection
* `test/lib/parse/client_rest_forbidden_paths_integration_test.rb` — master-only endpoints fail closed
* `test/lib/parse/client_livequery_integration_test.rb` — LiveQuery handshake without master key
* `test/support/client_mode_helper.rb` — the test harness pattern these tests share
