# ACL, CLP, and Field-Level Access in parse-stack-next

This is the canonical reference for who can do what to which records
in a Parse Server backed by parse-stack-next. It covers four layers
that compose into the effective permission decision, plus the places
where those layers are bypassed or hardcoded by Parse Server itself
and where parse-stack-next adds enforcement that the server doesn't.

For a narrower client-mode walkthrough (configuration, auth, CRUD),
see [`client_sdk_guide.md`](./client_sdk_guide.md). For deep dives on
the read paths that this guide references (Mongo-direct aggregation,
Atlas Search), see [`mongodb_direct_guide.md`](./mongodb_direct_guide.md)
and [`atlas_vector_search_guide.md`](./atlas_vector_search_guide.md).

---

## 1. The five layers, in order

When a non-master request hits Parse Server, the answer to "can this
operation proceed, and which fields come back?" is composed from:

1. **CLP** — class-level: "is this operation even allowed on this
   class for this caller?". Configurable per-class via
   `Parse::Object.set_clp`, with hardcoded overrides for some system
   classes (see §3.2).
2. **ACL** — row-level: "given the operation is allowed, which rows
   does this caller see / touch?". Stored on each row.
3. **`protectedFields`** — read-side field stripping: "of the fields
   on rows the caller can see, which ones does the server delete
   before returning?". Configured under CLP.
4. **Field guards (`guard :field, :master_only` / `:immutable` / ...)** —
   write-side, parse-stack-next-only: "if a client tries to write
   this field, silently revert the change". Enforced inside the SDK's
   `_User`/class `beforeSave` webhook handler, NOT by Parse Server.
   See §6.
5. **Master key bypass** — master-key callers skip 1–4 entirely
   except where Parse Server hardcodes master-only restrictions (see
   §3.2 and §7).

If a layer denies access at step 1, step 2 never runs. If step 2
filters a row out, step 3 has nothing to strip from it. If step 4
isn't wired to a webhook, it is silently a no-op.

---

## 2. ACL — row-level

Every row carries an `ACL` field shaped as
`{ "<userId|roleName|*>": { "read": true, "write": true } }`. Parse
Server enforces it on every find/get/update/delete that does not use
the master key.

### 2.1 Declaring a default policy for a class

```ruby
class Post < Parse::Object
  acl_policy public_read: true, public_write: false, default_roles: ["Editor"]
end
```

`acl_policy` writes the declared ACL onto every newly-created instance
of the class. It does NOT retroactively re-ACL existing rows.

### 2.2 Building an ACL imperatively on a record

```ruby
post = Post.new(body: "draft")
post.acl.apply(user.id, true, false)   # owner can read, not write
post.acl.apply_role("Admin", true, true)
post.acl.everyone(false, false)        # remove public access
post.save
```

`Parse::ACL#apply` accepts a `Parse::User`, a pointer to a user, or
a `Parse::Role` (with automatic role-name expansion). Passing
`Parse::Pointer` to a user expands the user's role memberships when
checking `readable_by?`/`writeable_by?` (see `Parse::Object`).

### 2.3 What clients see under ACL

A logged-in user only sees rows that have `read: true` for either
the user, one of their roles (recursively, see §5), or `"*"` (public).
The server-side filtering happens inside the find/get query before
the wire response is built; the SDK is not consulted.

ACL does NOT apply to REST `POST /aggregate/<Class>` — see §7.

---

## 3. CLP — class-level

CLPs gate whether an operation is even allowed on a class for a
caller, before ACL is consulted. CLP is master-key-only to configure
(via the Schema API or the SDK's migration tooling).

### 3.1 The DSL

```ruby
class Article < Parse::Object
  # Coarse mode-per-op:
  set_class_access(
    find:   :public,
    get:    :public,
    create: :authenticated,
    update: "Editor",          # role name; auto-prefixed "role:"
    delete: ["Editor", "Admin"],
    count:  :master,
    addField: :master,
  )

  # Or fine-grained:
  set_clp :create, public: false, roles: ["Editor"], requires_authentication: true

  # Sweeping defaults:
  master_only_class!     # everything master-only, then selectively open
  unlistable_class!      # find + count master-only; rest unchanged
end
```

A `set_clp(op)` with no positional args yields the master-only empty
`{}` permission for that op.

### 3.2 The system-class matrix

Several Parse Server system classes either ignore CLP entirely or
layer it under hardcoded behavior. This is non-negotiable: if you
call `set_clp` on them, Parse Server will silently do what its own
REST handler hardcodes regardless of the value you sent.

| Class                                                                                            | CLP actually configurable?                                                                                          |
|--------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|
| `_User`                                                                                          | Yes, but layered under hardcoded protections (password never returned, `authData` stripped from non-master finds, unauth update requires matching session token, email/username lowercasing, owner-exempt `protectedFields`). |
| `_Role`                                                                                          | Yes, layered under role-name regex, relation validation, and hierarchy integrity checks.                              |
| `_Installation`                                                                                  | **Partial.** Only `get`, `count`, `addField`, and `protectedFields` respond to CLP. `find` and `delete` are hardcoded master-only by Parse Server's `RestQuery` / `RestWrite` constructors (they throw `OPERATION_FORBIDDEN` for non-master callers regardless of CLP); `create` and `update` are gated by the `X-Parse-Installation-Id` header, not CLP. The SDK emits a one-time advisory when CLP is configured on `_Installation`. |
| `_Session`                                                                                       | Mostly redundant — non-master `find` queries are silently rewritten by `RestQuery.js` to scope by `user = <current user>`. `find` also requires a session token. You cannot grant cross-user session visibility through CLP. |
| `_JobStatus`, `_PushStatus`, `_Hooks`, `_GlobalConfig`, `_GraphQLConfig`, `_JobSchedule`, `_Audience`, `_Idempotency`, `_Join:*` (all relation join tables) | **No.** Hardcoded master-key-only at the REST layer (`SharedRest.js`). CLP changes are ignored.                     |

Practical consequences when you're building a client-mode app:

* Don't query `_JobStatus`, `_PushStatus`, `_Audience`, `_JobSchedule`,
  or any `_Join:*` table from the client. The model classes
  (`Parse::JobStatus`, `Parse::PushStatus`, `Parse::Audience`,
  `Parse::JobSchedule`) are server-side helpers — auto-promote to a
  master-key client or expose them through a Cloud Code function.
* `_Installation` is special-cased — see §3.3 for the full
  CLP-vs-hardcoded matrix on that class.
* On `_Session`, you don't need ACL or CLP to scope queries to the
  caller; Parse Server already does that.
* On `_User`, never assume CLP alone gates a flow. Password changes,
  email verification, and session-token rotation have their own
  paths; they fire even if your CLP looks restrictive.

### 3.3 `_Installation` — the hardcoded asymmetry

| Operation  | Behavior                                                                                  |
|------------|-------------------------------------------------------------------------------------------|
| `find`     | **Master key only. Hardcoded.** `set_clp :find, ...` is effectively ignored by the server. |
| `delete`   | **Master key only. Hardcoded.** `set_clp :delete, ...` is effectively ignored by the server. |
| `create`   | Open to anonymous clients (`X-Parse-Installation-Id` is the credential). Locking via CLP breaks first-launch device registration. |
| `update`   | Open when the request's `installationId` matches the record; else master key. Locking via CLP breaks silent device-token refresh and channel subscribe/unsubscribe before login. |
| `get`      | CLP applies normally. Safe to tighten — SDKs cache `currentInstallation` locally and don't normally GET it from the server. |
| `count`    | CLP applies normally. Safe to tighten to master-only. |
| `addField` | CLP applies normally. Safe to tighten to master-only as a hardening default. |

If your app genuinely requires login before any installation write,
put the policy in `beforeSave('_Installation')` Cloud Code rather
than in CLP:

```js
Parse.Cloud.beforeSave('_Installation', ({ user, master }) => {
  if (!master && !user) throw 'login required';
});
```

**Heads up — device-token dedup auth.** When two `_Installation`
records share the same `deviceToken`, Parse Server deduplicates them.
Historically that dedup ran with permissions bypassed; the
`installation.duplicateDeviceTokenActionEnforceAuth` option (default
**changing to `true`** in a future version) makes the dedup honor the
caller's auth context — and the resulting ACL/CLP — instead. This is
server-side behavior the SDK doesn't drive, but it can change which
record survives a token collision for non-master callers; set the
option to `true` to opt in now, or `false` to keep the old
permission-bypassing behavior.

---

## 4. `protectedFields` — read-side field stripping

Server-side strip list applied to query/get responses for non-master
callers. Configured per class, per group:

```ruby
class User < Parse::Object
  protect_fields "*",                 [:email, :phone]
  protect_fields "role:Admin",        []
  protect_fields "userField:owner",   []
end
```

Group resolution is **intersection**: a field is hidden only if it is
listed under every group the caller matches. So a user with role
`Admin` who matches both `*` (which strips `[:email, :phone]`) and
`role:Admin` (which strips `[]`) sees nothing stripped, because the
intersection of `[:email, :phone]` and `[]` is empty.

An empty array `[]` means "this group sees everything".

### 4.1 The "write but not read" pattern

```ruby
protect_fields "*", [:secret_token]
```

A client can write `secret_token` on create/update (Parse Server
accepts it in the POST body), but a subsequent GET/find from the
client omits it. Master-key fetch still sees it, confirming
persistence.

#### `protectedFieldsSaveResponseExempt` — stripping the write response too

Historically Parse Server stripped `protectedFields` only from
query/get responses; the create/update response echoed the full saved
row, so the value briefly came back to the client in the save reply
even though a later read would hide it. Parse Server added the
`protectedFieldsSaveResponseExempt` option to close that gap, and its
default **will change to `false` in a future version**. With it set to
`false`, `protectedFields` are stripped from write (create/update)
responses too — consistent with how they are already stripped from
reads. Set it now to opt in early:

```js
// parse-server config — strip protected fields from write responses
protectedFieldsSaveResponseExempt: false
```

parse-stack-next is compatible with either setting and never loses
local data: `Parse::Object#save` applies the server's response as a
merge (it only overwrites fields the response actually contains), so a
stripped protected field simply keeps the value you assigned locally —
nothing is clobbered.

This does **not** affect Cloud Code. A `beforeSave` / `afterSave`
trigger runs server-side before the response is serialized, so it
still sees, modifies, and persists protected fields normally — the
stripping happens only on the reply the *client* receives. The single
practical consequence is for the client's local view: if a `beforeSave`
trigger rewrites a protected field, that new value is now stripped from
the save reply just as it is from a read, so the SDK's in-memory object
won't reflect the server-side change until a master-key re-fetch. The
value is still persisted correctly.

### 4.2 `_User` field visibility and `protectedFieldsOwnerExempt`

Parse Server's `protectedFieldsOwnerExempt` option (historical default
**true**) silently exempts the owning user from every `protectedFields`
rule on `_User`. With that default in place, `protect_fields "*",
[:risk_score]` on `_User` does NOT hide `risk_score` from the user
themselves on their own row — they always see it.

> **Heads up:** Parse Server's default for `protectedFieldsOwnerExempt`
> **is changing to `false`** in a future version, which makes
> `protectedFields` apply consistently to the user's own `_User` row
> (the same as every other class) without extra config. Until your
> server adopts that default you must set `protectedFieldsOwnerExempt:
> false` explicitly for the helpers below to work; once it does, the
> explicit setting becomes a harmless no-op.

The fix has two server-side moving parts:

1. Start Parse Server with `protectedFieldsOwnerExempt: false`.
2. Add a self-pointer field on `_User` (default name `:self`),
   populated by a `beforeSave('_User')` Cloud Code trigger:

   ```js
   Parse.Cloud.beforeSave(Parse.User, (req) => {
     const u = req.object;
     if (!u.get('self')) u.set('self', u);
   });
   ```

   The trigger only fires on save, so **pre-existing user rows also
   need a one-shot backfill** before `self_visible_fields` works for
   them. Without the backfill, those rows never match the
   `userField:self` group and the self-visible fields stay hidden
   from the user themselves on their own row. A master-key script
   like the following works:

   ```ruby
   Parse::User.all(:self.null => true, batch_size: 200).each_slice(200) do |batch|
     batch.each { |u| u.self = u; u.save(use_master_key: true) }
   end
   ```

With those in place, parse-stack-next exposes:

```ruby
class Parse::User
  property :my_opinion_of_them, :string   # admin metadata
  property :favorite_color,    :string   # private profile

  master_only_fields  :my_opinion_of_them
  self_visible_fields :favorite_color, via: :self
end
```

That expands to:

```ruby
protect_fields "*",                ["myOpinionOfThem", "favoriteColor"]
protect_fields "userField:self",   ["myOpinionOfThem"]
```

Resolution (intersection across matching groups):

| Caller          | Matching groups          | Hidden (intersection)              | Visible          |
|-----------------|--------------------------|------------------------------------|------------------|
| Other user      | `*`                      | `myOpinionOfThem`, `favoriteColor` | neither          |
| The user itself | `*` ∩ `userField:self`   | `myOpinionOfThem` only             | `favoriteColor`  |
| Master key      | none (master bypasses)   | nothing                            | both             |

If you call raw `protect_fields` on `_User` directly, the SDK emits a
one-time advisory pointing at the helpers above and reminding you to
set `protectedFieldsOwnerExempt: false` — without that flag, the
default owner-exempt behavior silently negates a lot of what raw
`protect_fields` looks like it's doing.

`protectedFieldsOwnerExempt` only affects `_User`. On your own
classes, pointer-based group targeting (`userField:owner`) is the
clean way to do "owner sees their own protected field".

---

## 5. Roles and the hierarchy direction gotcha

`Parse::Role` rows carry two relations:

* `users` — direct members.
* `roles` — **child roles whose users inherit access through this role.**

That second one is the trap. If you want SuperAdmin to inherit
everything Admin can do, you put **SuperAdmin into Admin's `roles`
relation**, not the reverse.

The SDK exposes a direction-explicit helper:

```ruby
super_role = Parse::Role.find_or_create("SuperAdmin")
super_role.add_users(super_user).save
super_role.inherits_capabilities_from!(admin_role)
# Under the hood: adds SuperAdmin to Admin's `roles` relation.
```

The older `add_child_role` goes the other direction and is preserved
for backwards compat. Reach for `inherits_capabilities_from!`
instead — getting the direction wrong is a privilege-escalation bug.

For ACL/CLP purposes, the server's role-graph expansion walks this
relation when resolving the caller's effective roles. So a row
ACL'd to `role:Admin` becomes readable by SuperAdmin members
automatically; you do not need to add `role:SuperAdmin` to every
Admin-readable row.

---

## 6. Field guards (`guard :field, :master_only`) — SDK-only, webhook-required

This is parse-stack-next's write-side enforcement. Parse Server
itself has no equivalent: `protectedFields` only affects reads, not
writes.

```ruby
class Project < Parse::Object
  property :slug, :string
  property :created_by, :pointer

  guard :created_by,            :master_only
  guard :slug, :external_id,    :immutable
end
```

The modes:

* `:master_only` — never writable by clients. Client-supplied values
  are reverted. Master key bypasses.
* `:immutable` — writable on create, reverted on any subsequent
  client update. Master key bypasses updates.
* `:always_immutable` — same as `:immutable`, plus master-key
  updates are also reverted. Useful for one-way state transitions.
* `:set_once` — writable while the persisted value is blank, then
  locked forever — including for master-key writes. Useful for
  derived fields populated by an `after_create` callback (e.g.
  `parse_reference`).

### 6.1 This only works if the webhook is wired

Field guards are enforced inside the SDK's `beforeSave` webhook
handler. If your Parse Server deployment does not have its webhook
HTTPS callback pointed at a Ruby process running
`Parse::Webhooks`, the guards are silently a no-op. The SDK auto-
registers a stub handler when `guard` is declared
(`ensure_field_guards_webhook!`), but it cannot install the Parse
Server side of the wiring for you.

The reverts are silent successful no-ops from the client's
perspective: the save returns 200, the guarded field simply isn't
written. A DEBUG-level log line is emitted for diagnosis but
nothing is raised.

### 6.2 Where field guards fit relative to the other layers

* **CLP** says "is `update` even allowed on this class?".
* **ACL** says "given `update` is allowed, can this caller write
  to THIS row?".
* **`protectedFields`** strips on the way back out.
* **Field guards** revert specific field changes inside the
  `beforeSave` webhook before the row reaches the persistent store.

A client whose CLP/ACL allow the update will get a successful
response with the guarded field NOT applied. They have no signal
that their write was reverted; design your client UX accordingly
(e.g. re-fetch the row after save if you need to surface the
canonical value).

---

## 7. Aggregate queries — the big enforcement asymmetry

Parse Server's REST `POST /aggregate/<Class>` endpoint **requires
the master key AND enforces NEITHER CLP nor ACL nor
`protectedFields`**. There is no session-token authorization model
on this endpoint. This is non-obvious and asymmetric with the rest
of Parse Server's REST surface:

| Endpoint                                | Auth model            | CLP | ACL | `protectedFields` |
|-----------------------------------------|-----------------------|-----|-----|-------------------|
| `GET /classes/<Class>` (find)           | session token         | yes | yes | yes               |
| `GET /classes/<Class>/<id>` (get)       | session token         | yes | yes | yes               |
| `?count=1`                              | session token         | yes | yes | yes               |
| `POST /aggregate/<Class>`               | **master key only**   | no  | no  | no                |

### 7.1 Two aggregate paths in the SDK

parse-stack-next exposes two different aggregate code paths and they
have very different security postures:

**REST aggregate** — `Parse::Client#aggregate_pipeline`. Routes to
the Parse Server REST endpoint above. Master-key only, unscoped.
Safe ONLY for master-key agents and admin tools.

**Mongo-direct aggregate** — `Parse::MongoDB.aggregate`. Routes
directly to the underlying MongoDB driver. The SDK enforces
ACL (via `Parse::ACLScope`), CLP (via `Parse::CLPScope`), and
`protectedFields` itself in this code path. This is the only path
that supports scoped agents (`session_token:`, `acl_user:`,
`acl_role:`).

`Parse::Query#results_direct` / `#count_direct` and
`Parse::AtlasSearch.{search,autocomplete,faceted_search}` all route
through `Parse::MongoDB.aggregate` and inherit the SDK-side
enforcement.

### 7.2 Auto-promotion for scoped agents

The SDK's built-in agent tools auto-promote `mongo_direct: false` to
`mongo_direct: true` for any scoped agent, so REST aggregate cannot
silently bypass enforcement. `acl_user:` and `acl_role:` agent
scopes have NO REST equivalent — Parse Server's REST has no "act as
user-pointer" or "act as role" affordance. The SDK auto-routes
those to mongo-direct; `request_opts` fails closed for them.

### 7.3 If you find yourself writing this code

```ruby
client.aggregate_pipeline(class_name, pipeline, session_token: token)
client.find_objects(class_name, where: …, session_token: token)
```

Stop and consider whether the SDK-side enforcement layer should run
instead. The mongo-direct path is the only one with first-class ACL
+ CLP + `protectedFields` enforcement for scoped agents.

---

## 8. Atlas Search

Atlas Search (`Parse::AtlasSearch.search`, `.autocomplete`,
`.faceted_search`) routes through `Parse::MongoDB.aggregate`, so it
inherits the SDK-side ACL + CLP + `protectedFields` enforcement
described in §7. From a security standpoint, an Atlas Search call
with a session token is treated like a `Parse::Query` with a session
token — same scoping, same field stripping.

The `$search` stage itself runs on the Atlas Search index and is not
filtered by ACL. The ACL filter is applied as a `$match` stage by
`Parse::ACLScope` after `$search`, before results are returned. If
you're seeing rows in search results that the caller shouldn't see,
verify (a) that the call went through `Parse::AtlasSearch` (not raw
`aggregate_pipeline`), and (b) that the session token was actually
threaded through to the call.

See [`atlas_vector_search_guide.md`](./atlas_vector_search_guide.md)
for the search and indexing surface.

---

## 9. Mongo-direct — when it engages

`Parse::MongoDB.aggregate` is the SDK's direct path to MongoDB,
bypassing Parse Server's REST layer entirely. It's used:

* Explicitly via `Parse::Query#results_direct` / `#count_direct` /
  `Parse::AtlasSearch.*`.
* Implicitly by built-in agent tools when the request is scoped to
  a session token, ACL user, or ACL role (`mongo_direct: false`
  is auto-promoted to `true`).
* Implicitly by built-in agent tools when the requested aggregation
  needs SDK-side ACL/CLP/`protectedFields` enforcement that REST
  can't provide.

This path requires the SDK to have a direct MongoDB connection
configured (see [`mongodb_direct_guide.md`](./mongodb_direct_guide.md)).
In setups where mongo-direct is unavailable, scoped-agent aggregate
calls fail closed rather than silently downgrading to the unscoped
REST aggregate.

---

## 10. Common pitfalls

* **`protect_fields "*", [:email]` on `_User` doesn't hide email from
  the user themselves.** Default `protectedFieldsOwnerExempt: true`
  exempts the owner. Use `master_only_fields` / `self_visible_fields`
  and set the option to `false`. See §4.2.
* **`set_clp :find` on `_Installation` does nothing.** Hardcoded
  master-only at the REST layer. See §3.3.
* **CLP isn't sufficient gating for `_User` write flows.** Password
  changes, email verification, and session rotation have their own
  paths. Use field guards (§6) or `beforeSave` Cloud Code triggers
  for write-side policy on `_User`.
* **REST aggregate bypasses everything.** Don't route scoped-agent
  queries through `Parse::Client#aggregate_pipeline`. Use
  `Parse::Query#results_direct` or `Parse::MongoDB.aggregate`. See §7.
* **Atlas Search results aren't ACL-filtered by Atlas.** The ACL
  filter is a `$match` stage added by `Parse::ACLScope` after
  `$search`. If you call the `$search` stage outside the SDK
  helpers, you lose the filter. See §8.
* **Role hierarchy direction.** SuperAdmin inheriting from Admin
  means SuperAdmin goes into Admin's `roles` relation. Use
  `inherits_capabilities_from!` to keep it straight. See §5.
* **Field guards without webhook wiring are a no-op.** The Parse
  Server deployment must point its webhook HTTPS callback at a
  Ruby process running `Parse::Webhooks`. See §6.1.
