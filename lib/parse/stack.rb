# encoding: UTF-8
# frozen_string_literal: true

require_relative "stack/version"
require_relative "client"
require_relative "query"
require_relative "model/object"
require_relative "webhooks"
require_relative "agent"
require_relative "two_factor_auth"
require_relative "two_factor_auth/user_extension"
require_relative "schema"
require_relative "schema/index_migrator"
require_relative "schema/search_index_migrator"
require_relative "lookup_rewriter"
require_relative "console"

module Parse
  class Error < StandardError; end

  module Stack
  end

  # Sentinel used by SDK methods that need to distinguish "the caller
  # omitted this kwarg" from "the caller explicitly passed `nil`" —
  # the latter must NOT fall through to a default that would silently
  # re-introduce a value the caller is trying to suppress (e.g. a
  # master-key or session-token override).
  #
  # Use as the default value of a keyword argument, then check with
  # `value.equal?(Parse::NOT_PROVIDED)` to detect omission. Comparison
  # by identity is intentional — `==` on the sentinel is meaningless.
  #
  # @example Distinguishing nil-pass from omission
  #   def fetch(master_key: Parse::NOT_PROVIDED)
  #     resolved = master_key.equal?(Parse::NOT_PROVIDED) ? config.master_key : master_key
  #     # `fetch(master_key: nil)` here produces `nil`, not the config value
  #   end
  NOT_PROVIDED = Object.new.tap do |o|
    def o.inspect
      "Parse::NOT_PROVIDED"
    end
  end.freeze

  # Fiber-local key consulted by the authentication middleware. A truthy
  # entry suppresses the master-key header for the duration of the block
  # set by {Parse.without_master_key}; a `:enabled` entry forces the
  # master-key header back on inside a nested {Parse.with_master_key}
  # block.
  MASTER_KEY_STATE_KEY = :__parse_master_key_state__

  # Run `block` with the master key suppressed for every Parse request
  # originating in the current fiber. Equivalent to setting the
  # `X-Disable-Parse-Master-Key` header on each request, but block-scoped
  # so callers can wrap a unit of work — e.g. running an action "as if
  # the configured master key were not available" — without threading
  # the header through every intermediate call.
  #
  # Survives Faraday retries (the per-request header would be stripped on
  # the first attempt and gone by the retry; the fiber-local state lives
  # for the lifetime of the block).
  #
  # @yield runs the block with master-key disabled
  # @return [Object] the block's return value
  # @example
  #   Parse.without_master_key do
  #     song = Song.find(id)         # session-token / API-key auth only
  #     song.title = "Renamed"
  #     song.save                    # subject to ACL/CLP
  #   end
  def self.without_master_key
    previous = Fiber[MASTER_KEY_STATE_KEY]
    Fiber[MASTER_KEY_STATE_KEY] = :disabled
    yield
  ensure
    Fiber[MASTER_KEY_STATE_KEY] = previous
  end

  # Inverse of {.without_master_key}: forces the master key back on for
  # the duration of the block, even if a containing {.without_master_key}
  # had suppressed it. Useful for re-entering an admin-only operation
  # inside a session-scoped block. If no master key is configured on the
  # client, this is a no-op — the helper does not synthesise one.
  #
  # @yield runs the block with master-key enabled (if configured)
  # @return [Object] the block's return value
  def self.with_master_key
    previous = Fiber[MASTER_KEY_STATE_KEY]
    Fiber[MASTER_KEY_STATE_KEY] = :enabled
    yield
  ensure
    Fiber[MASTER_KEY_STATE_KEY] = previous
  end

  # @return [Boolean] true if the current fiber is inside a
  #   {.without_master_key} block. Consulted by the authentication
  #   middleware in addition to the per-request disable header.
  def self.master_key_disabled?
    Fiber[MASTER_KEY_STATE_KEY] == :disabled
  end

  # Fiber-local key holding the ambient session token consulted by
  # {Parse::Client#request} when no explicit `session_token:` was
  # passed. Set by {Parse.with_session}; nested blocks save and restore
  # the previous value on exit.
  SESSION_TOKEN_STATE_KEY = :__parse_session_token__

  # Run `block` with an ambient session token set for the current fiber.
  # Inside the block, every Parse request that doesn't explicitly pass
  # `session_token:` *and* doesn't explicitly request `use_master_key:
  # true` will be sent with this token. Equivalent to threading
  # `session_token:` through every call site, but block-scoped.
  #
  # The `token` argument may be a String, a {Parse::User} (its
  # `session_token` is read), a {Parse::Session} (its `session_token` is
  # read), or `nil`. Passing `nil` clears the ambient inside the block —
  # useful for performing one anonymous call inside an otherwise
  # session-scoped region.
  #
  # Fiber-local, not thread-local: concurrent fibers (and threads, since
  # each thread starts with its own root fiber) do not share state.
  # Survives Faraday retries — the token lives for the lifetime of the
  # block, not just the first HTTP attempt.
  #
  # An explicit `session_token:` kwarg on any call still wins over the
  # ambient. An explicit `use_master_key: true` skips the ambient and
  # sends the master key (if configured).
  #
  # @param token [String, Parse::User, Parse::Session, nil]
  # @yield runs the block with the ambient session token in place
  # @return [Object] the block's return value
  # @example
  #   user = Parse::User.login!("alice", "pw")
  #   Parse.with_session(user) do
  #     post = Post.find(id)                # scoped to alice
  #     post.title = "edited"
  #     post.save                            # subject to ACL/CLP
  #     Comment.all(post: post)              # scoped to alice
  #   end
  def self.with_session(token)
    resolved = token.respond_to?(:session_token) ? token.session_token : token
    resolved = resolved.to_s if resolved
    # Capture BEFORE any raise so the `ensure` always restores the real
    # previous ambient (never clobbers an enclosing with_session).
    previous = Fiber[SESSION_TOKEN_STATE_KEY]
    # SEC-02: a present-but-blank (empty or whitespace) token is an unusable
    # credential. The prior behavior stored a whitespace token as the ambient
    # (only an exactly-empty string was treated as absent), and the request
    # layer would then drop it and silently send the master key. Reject blank
    # tokens loudly at the source instead. `nil` still means "no ambient".
    if resolved.is_a?(String) && resolved.strip.empty?
      raise ArgumentError,
        "Parse.with_session was given a blank session token. A present-but-empty " \
        "token is refused so the block cannot silently execute with master-key " \
        "authority — pass a valid session token, or `nil` for no ambient session."
    end
    Fiber[SESSION_TOKEN_STATE_KEY] = resolved
    yield
  ensure
    Fiber[SESSION_TOKEN_STATE_KEY] = previous
  end

  # The ambient session token set by {.with_session} for the current
  # fiber, or `nil` when not inside such a block.
  # @return [String, nil]
  def self.current_session_token
    Fiber[SESSION_TOKEN_STATE_KEY]
  end

  # @!visibility private
  CACHE_TENANT_STATE_KEY = :__parse_cache_tenant__

  # Set an ambient cache-tenant scope for the duration of the block.
  # When set, the {Parse::Middleware::Caching} middleware composes the
  # tenant into the cache key as `<base-namespace>:T:<tenant>:…` so a
  # multi-tenant Parse application can share one Redis (or any Moneta-
  # backed cache) without per-tenant configuration plumbing through
  # every `Parse::Client.new` site. Tenants do not see each other's
  # cached responses; a SCAN-delete over `<base-namespace>:T:<tenant>:*`
  # evicts exactly one tenant cleanly.
  #
  # This is purely a key namespacing mechanism — it does NOT enforce
  # any access-control semantics. Tenant isolation at the data layer
  # is the job of `agent_tenant_scope` (per-class scoping) and ACL/CLP.
  # The tenant cache scope's role is to keep tenant A's session-token-
  # keyed cache entry from being served on tenant B's request even
  # when the URL and session token happen to collide.
  #
  # Fiber-local — composes safely with `async` and concurrent web
  # frameworks. The scope is per-fiber, not per-thread, and is
  # restored on block exit even if the block raises.
  #
  # @example wrap an agent invocation under a tenant
  #   Parse.with_cache_tenant("tenant_abc") do
  #     agent.run(prompt)   # every Parse request issued inside the
  #                          # block writes/reads tenant-scoped cache
  #                          # entries
  #   end
  #
  # @example compose with `with_session`
  #   Parse.with_cache_tenant(tenant_id) do
  #     Parse.with_session(user) do
  #       Post.all
  #     end
  #   end
  #
  # @param scope [String, Symbol, nil] tenant identifier. `nil` clears
  #   the ambient scope for the duration of the block (useful to opt
  #   out within a larger tenant-scoped section). Must be ASCII
  #   `[A-Za-z0-9_-]+` — colon and other key-segment-delimiter chars
  #   are refused with `ArgumentError`, since the middleware composes
  #   the tenant into the cache key as `T:<tenant>:…` and a tenant
  #   containing `:` would collapse the segmentation (e.g.
  #   `with_cache_tenant("a:T:b")` would produce keys
  #   indistinguishable from `with_cache_tenant("a")` nested under
  #   `with_cache_tenant("b")`, breaking SCAN-delete isolation).
  # @yield runs the block with the ambient tenant scope in place
  # @return [Object] the block's return value
  # @raise [ArgumentError] when `scope` contains characters outside
  #   `[A-Za-z0-9_-]` or exceeds 256 bytes.
  CACHE_TENANT_PATTERN = /\A[A-Za-z0-9_\-]{1,256}\z/.freeze
  def self.with_cache_tenant(scope)
    resolved = scope.nil? ? nil : scope.to_s
    resolved = nil if resolved&.empty?
    if resolved && !CACHE_TENANT_PATTERN.match?(resolved)
      raise ArgumentError,
            "Parse.with_cache_tenant scope must match #{CACHE_TENANT_PATTERN.source} " \
            "(got #{scope.inspect}). Colon and other key-segment-delimiter characters " \
            "are refused — they would collapse the cache-key namespace boundary."
    end
    previous = Fiber[CACHE_TENANT_STATE_KEY]
    Fiber[CACHE_TENANT_STATE_KEY] = resolved
    yield
  ensure
    Fiber[CACHE_TENANT_STATE_KEY] = previous
  end

  # The ambient cache-tenant scope set by {.with_cache_tenant} for the
  # current fiber, or `nil` when not inside such a block.
  # @return [String, nil]
  def self.current_cache_tenant
    Fiber[CACHE_TENANT_STATE_KEY]
  end

  # The {Parse::User} cached alongside the ambient session set by
  # {.login}, or `nil` when no imperative login is active. Block-scoped
  # `{Parse.with_session}` does NOT populate this — only {.login} does.
  # @return [Parse::User, nil]
  def self.current_user
    Fiber[CURRENT_USER_STATE_KEY]
  end

  # Fiber-local key holding the {Parse::User} cached by {.login} for
  # {.current_user} lookup. Kept distinct from the session-token key so
  # block-scoped `Parse.with_session(tok)` (which has only a token, not a
  # user object) doesn't mis-populate it.
  CURRENT_USER_STATE_KEY = :__parse_current_user__

  # Imperative login for REPL / Rake-console use: logs in once, stashes
  # the resulting session token as the ambient for the current fiber,
  # and returns the {Parse::User}. Every subsequent Parse call in the
  # session (the IRB main fiber) is then auth-scoped to that user
  # without the caller threading `session_token:` or wrapping each
  # statement in {.with_session}.
  #
  # Intended for interactive use. For scoped work in production code,
  # prefer {.with_session} — it auto-restores prior state on exit, even
  # if the block raises.
  #
  # @param username [String] the user's username.
  # @param password [String] the user's password.
  # @param mfa_token [String, nil] one-time MFA code (TOTP or recovery
  #   code). When given, the credentials are submitted via the MFA
  #   endpoint. When the server requires MFA and none is supplied,
  #   {Parse::MFA::RequiredError} is raised so the caller can prompt
  #   for the code and retry.
  # @return [Parse::User] the logged-in user.
  # @raise [Parse::Error::AuthenticationError] when credentials are rejected.
  # @raise [Parse::MFA::RequiredError] when the server requires an MFA
  #   token and `mfa_token:` was not provided.
  # @raise [Parse::MFA::VerificationError] when the supplied `mfa_token:`
  #   is invalid or expired.
  # @example IRB / rails console
  #   Parse.login("alice", "hunter2")
  #   Post.all                # as alice
  #   p = Post.find(id); p.update!(title: "edited")  # as alice
  #   Parse.logout            # clears ambient and revokes the session
  # @example with MFA
  #   begin
  #     Parse.login("alice", "hunter2")
  #   rescue Parse::MFA::RequiredError
  #     code = $stdin.gets.chomp
  #     Parse.login("alice", "hunter2", mfa_token: code)
  #   end
  def self.login(username, password, mfa_token: nil)
    user = if mfa_token
        Parse::User.login_with_mfa(username, password, mfa_token)
      else
        Parse::User.login!(username, password)
      end
    unless user
      raise Parse::Error::AuthenticationError,
            "Parse.login: credentials rejected for #{username.inspect} (server returned no session)."
    end
    Fiber[SESSION_TOKEN_STATE_KEY] = user.session_token
    Fiber[CURRENT_USER_STATE_KEY]  = user
    user
  end

  # Imperative logout: clears the ambient session token and cached
  # current user for the current fiber and, by default, revokes the
  # token server-side via `POST /parse/logout`. Pair with {.login}.
  #
  # If you set the ambient via {.session_token=} (no server-side
  # session to revoke), pass `revoke: false` to skip the network call.
  #
  # @param revoke [Boolean] when true (default), call the server-side
  #   `/logout` endpoint to invalidate the token. When false, only
  #   clears local fiber state.
  # @return [Boolean] true if the local state was cleared (always); the
  #   server-side revoke result is intentionally not surfaced — `logout`
  #   is fire-and-forget in console use.
  def self.logout(revoke: true)
    token = Fiber[SESSION_TOKEN_STATE_KEY]
    Fiber[SESSION_TOKEN_STATE_KEY] = nil
    Fiber[CURRENT_USER_STATE_KEY]  = nil
    if revoke && token.is_a?(String) && !token.empty?
      begin
        Parse::Client.client.logout(token)
      rescue StandardError
        # Best-effort: a failed revoke shouldn't make `logout` raise in
        # a REPL. The local clear already happened.
      end
    end
    true
  end

  # Imperative ambient-token setter, for cases where you already have a
  # session token (e.g. read from a fixture, a test setup, a saved
  # credential) and want to scope subsequent calls without going through
  # the login endpoint. Set to `nil` to clear the ambient (does not
  # revoke server-side; use {.logout} for that).
  # @param token [String, Parse::User, Parse::Session, nil]
  # @return [String, nil] the resolved token now in effect.
  def self.session_token=(token)
    resolved = token.respond_to?(:session_token) ? token.session_token : token
    resolved = resolved.to_s if resolved
    Fiber[SESSION_TOKEN_STATE_KEY] = (resolved && !resolved.empty?) ? resolved : nil
    Fiber[CURRENT_USER_STATE_KEY]  = nil
    Fiber[SESSION_TOKEN_STATE_KEY]
  end

  # Strict client mode — when true, the request layer never sends the
  # configured master key unless the caller explicitly passes
  # `use_master_key: true`. In combination with {Parse.with_session},
  # this lets a same-process server+client deployment safely run a
  # region of code "as a client" — every Parse call that isn't
  # explicitly admin-flavored is scoped to the ambient session token (or
  # sent anonymous if none is set), and the configured master key is
  # ignored.
  #
  # **Honored ENV form:** `PARSE_CLIENT_MODE=true` at boot is equivalent
  # to setting this to `true` before any Parse request goes out.
  #
  # @example Enable for the whole process
  #   Parse.client_mode = true
  #   Parse.with_session(user.session_token) do
  #     Post.all                               # as alice, no master key
  #     SecretAdminThing.find(id, use_master_key: true)  # explicit override
  #   end
  # @return [Boolean]
  @client_mode = ENV["PARSE_CLIENT_MODE"] == "true"
  def self.client_mode
    @client_mode == true
  end
  def self.client_mode=(value)
    @client_mode = (value == true)
  end
  def self.client_mode?
    client_mode
  end

  # Configuration for query validation warnings
  # Set to false to disable warnings about unnecessary includes
  # @example Disable query warnings
  #   Parse.warn_on_query_issues = false
  @warn_on_query_issues = true

  # Configuration for debugging autofetch behavior.
  # When set to true, autofetch will raise Parse::AutofetchTriggeredError instead of
  # automatically fetching data. This helps identify where additional keys are needed
  # in queries to avoid unnecessary network requests.
  # @example Enable autofetch debugging
  #   Parse.autofetch_raise_on_missing_keys = true
  #   # Now accessing an unfetched field will raise an error:
  #   # Parse::AutofetchTriggeredError: Autofetch triggered on Post#abc123 - field :content was not fetched
  @autofetch_raise_on_missing_keys = false

  # Configuration for serialization of partially fetched objects.
  # When set to true (default), calling as_json or to_json on a partially fetched
  # object will only serialize the fields that were fetched, preventing autofetch
  # from being triggered during serialization. This is particularly useful for
  # webhook responses where you intentionally want to return partial data.
  # @example Disable (serialize all fields, triggering autofetch)
  #   Parse.serialize_only_fetched_fields = false
  # @example Override per-call
  #   user.as_json(only_fetched: false)  # Force full serialization
  @serialize_only_fetched_fields = true

  # Configuration for validating keys in partial fetch operations.
  # When set to true (default), fetch!(keys: [...]) will warn about keys that
  # don't match any defined property on the model. This helps catch typos and
  # undefined field references early.
  # Set to false if you use dynamic schemas or want to suppress warnings.
  # @example Disable key validation warnings
  #   Parse.validate_query_keys = false
  # @example With validation enabled (default)
  #   song.fetch!(keys: [:title, :nonexistent])
  #   # => [Parse::Fetch] Warning: unknown keys [:nonexistent] for Song
  @validate_query_keys = true

  # Opt-in toggle for the LiveQuery WebSocket subscription feature.
  # LiveQuery has been stable since Parse Stack 3.0.0; the toggle exists
  # so the network-egress surface (an outbound WebSocket to the LiveQuery
  # server) is opened only when the operator explicitly turns it on, not
  # as a side effect of requiring the file.
  #
  # The LiveQuery module is autoloaded — `Parse::LiveQuery.configure { … }`
  # works without an explicit `require 'parse/live_query'`. The autoload
  # is purely a file-loading convenience; it does NOT open a network
  # connection. A connection only opens when `Parse.live_query_enabled = true`
  # AND a `Parse::LiveQuery::Client` is instantiated (typically via
  # `Klass.subscribe { … }` or `Parse::Client.new(live_query_url: …)`).
  #
  # @example Enable LiveQuery
  #   Parse.live_query_enabled = true
  #   # Parse::LiveQuery is autoloaded — no explicit require needed
  #   Parse::LiveQuery.configure do |c|
  #     c.url = "wss://parse.example.com"
  #   end
  autoload :LiveQuery, "parse/live_query"

  # Public mutual-exclusion primitive (TTL-bounded, Redis-backed with
  # in-process Mutex fallback). See {Parse::Lock}.
  autoload :Lock, "parse/lock"

  # Shared low-level lock primitives consumed by both {Parse::Lock}
  # and {Parse::CreateLock}. `@api private` — application code should
  # use {Parse::Lock.acquire}.
  autoload :LockBackend, "parse/lock_backend"

  @live_query_enabled = false

  # Configuration for cache write-through on fetch operations.
  # When set to true (default), fetch!/reload!/find operations will:
  #   - Skip reading from cache (always get fresh data from server)
  #   - Write the fresh data back to cache for future cached reads
  # This is the "write-only" cache mode - ensures data freshness while keeping cache updated.
  # Set to false to completely bypass cache (no read or write) on fetch operations.
  # @example Disable cache write-on-fetch
  #   Parse.cache_write_on_fetch = false
  #   # Now fetch!/reload!/find will completely bypass cache
  # @example Default behavior (write-only mode)
  #   song.fetch!  # Gets fresh data, updates cache
  #   song.fetch!(cache: true)  # Uses cached data if available
  @cache_write_on_fetch = true

  # Configuration for default query caching behavior.
  # When set to false (default), queries do NOT use cache unless explicitly enabled.
  # When set to true, queries use cache by default (opt-out behavior).
  # This only affects queries - individual queries can always override with cache: true/false.
  # @example Enable cache by default (opt-out behavior)
  #   Parse.default_query_cache = true
  #   Song.first  # Uses cache
  #   Song.query(cache: false).first  # Explicitly bypasses cache
  # @example Default behavior (opt-in, cache disabled by default)
  #   Song.first  # Does NOT use cache
  #   Song.query(cache: true).first  # Explicitly uses cache
  @default_query_cache = false

  # Configuration for experimental Agent MCP server feature.
  # The MCP (Model Context Protocol) server allows AI agents to interact with Parse data.
  # This feature requires TWO steps to enable for safety:
  #   1. Set environment variable: PARSE_MCP_ENABLED=true
  #   2. Set in code: Parse.mcp_server_enabled = true
  # @example Enable MCP server (experimental)
  #   # In environment or .env file:
  #   # PARSE_MCP_ENABLED=true
  #
  #   # In code:
  #   Parse.mcp_server_enabled = true
  #   Parse::Agent.enable_mcp!(port: 3001)
  # @note MCP server implementation is experimental
  @mcp_server_enabled = false

  # Configuration for MCP server port.
  # @example Set custom port
  #   Parse.mcp_server_port = 3002
  @mcp_server_port = 3001

  # Configuration for MCP remote API.
  # When set, the MCP server can forward requests to a remote AI API (e.g., OpenAI, Claude).
  # @example Configure remote API
  #   Parse.mcp_remote_api = {
  #     provider: :openai,           # :openai, :claude, or :custom
  #     api_key: ENV['OPENAI_API_KEY'],
  #     model: 'gpt-4',
  #     base_url: nil                # Optional custom base URL
  #   }
  @mcp_remote_api = nil

  # Auto-rewrite LLM-style `$lookup` stages in aggregation pipelines passed
  # to `Parse::Query#aggregate` and `Parse::MongoDB.aggregate`. When true
  # (the default), pipelines using pretty/logical field names (e.g.
  # `localField: "author", foreignField: "_id"`) are translated to the
  # Parse-on-Mongo column-name form (`_p_author`/`parseReference`) when
  # the foreign class declares `parse_reference`. Pipelines already in
  # `_p_*`/`parseReference` form pass through unchanged (idempotent), and
  # when the foreign class lacks `parse_reference` the stage is left
  # alone (no `$split` fallback in the auto path — it's an optimization,
  # not a correction).
  # @example Disable auto-rewrite
  #   Parse.rewrite_lookups = false
  @rewrite_lookups = true

  # Configuration for strict property redefinition checks.
  # When set to true (default), redeclaring a property with a different data type
  # than the existing definition raises ArgumentError instead of warning and
  # silently dropping the new declaration. Identical redeclarations (same data
  # type and remote field name) are always silent. A type mismatch on a core
  # Parse field (e.g. Installation#badge defined as :integer but redeclared as
  # :string) is almost always a bug, so it is a hard failure by default. Set to
  # false to fall back to the legacy warn-and-ignore behavior.
  # @example Opt out of strict redefinition
  #   Parse.strict_property_redefinition = false
  @strict_property_redefinition = true

  # Configuration for globally enabling the synchronize-create lock on
  # `Parse::Object.first_or_create!` and `create_or_update!`. When true, every
  # call to those methods acquires a Moneta-backed mutex (typically Redis) to
  # prevent duplicate creation under concurrency. Per-call `synchronize: false`
  # still opts out. See {Parse::CreateLock}.
  # @example Enable globally
  #   Parse.synchronize_create_default = true
  # @example ENV fallback
  #   PARSE_STACK_SYNCHRONIZE_CREATE=true
  @synchronize_create_default = ENV["PARSE_STACK_SYNCHRONIZE_CREATE"] == "true"

  # Configuration for raising on impossible pointer-shape constraints
  # (e.g. bare objectId strings inside an `$in` array against a pointer
  # column whose target class cannot be resolved). When true, the SDK
  # raises {Parse::Query::PointerShapeError} instead of silently
  # returning a value that won't match — preventing the silent-zero
  # failure mode where the LLM/operator reads "0 results" as a real
  # answer. When false (default), the SDK logs a one-shot warning via
  # `Parse.logger` and leaves the value unchanged for backwards
  # compatibility.
  # @example Enable globally
  #   Parse.strict_pointer_shapes = true
  # @example ENV fallback (recommended for test/CI)
  #   PARSE_STRICT_POINTER_SHAPES=true
  @strict_pointer_shapes = ENV["PARSE_STRICT_POINTER_SHAPES"] == "true"

  # Configuration for automatic pluralized class-name aliases. When enabled
  # (the default), referencing the plural form of a {Parse::Object} subclass
  # constant resolves to that class, so `Posts.where(...)` works for a class
  # `Post`. The alias is created lazily on first reference via `const_missing`
  # and points at the same class object, so every class method
  # (`where`, `query`, `count`, `find`, `all`, scopes) works for free and
  # `Posts.parse_class` still returns `"Post"`. Classes whose name already
  # ends in `s` are skipped. Set to false to opt out globally.
  # @example Opt out globally
  #   Parse.pluralized_aliases = false
  # @example ENV opt-out
  #   PARSE_PLURALIZED_ALIASES=false
  # @see Parse::Core::Querying#pluralized_alias!
  @pluralized_aliases = ENV["PARSE_PLURALIZED_ALIASES"] != "false"

  # Tuning bundle for the synchronize-create lock. Per-call kwargs override.
  # Keys: :ttl (seconds, default 3, max 30), :wait (seconds, default 2.0,
  # max 30), :on_degraded (:warn, :warn_throttled, :raise, :proceed).
  # @example
  #   Parse.synchronize_create_options = { ttl: 5, wait: 1.0, on_degraded: :warn_throttled }
  @synchronize_create_options = {}

  # HMAC secret for synchronize-create lock-key derivation. When set, lock
  # keys are HMAC-SHA256 of the canonical payload (hides query_attrs content
  # from Redis MONITOR / snapshot snoopers). When unset and the cache store
  # is Redis-backed, a one-time warning is emitted and plain SHA256 is used
  # so cross-process locking still works. When unset and the store is the
  # in-memory adapter, an auto-derived per-process secret is used.
  # @example
  #   Parse.synchronize_create_secret = ENV["PARSE_STACK_LOCK_SECRET"]
  @synchronize_create_secret = nil

  # Optional dedicated Moneta store for the synchronize-create lock. When
  # nil, falls back to {Parse.cache}.
  #
  # SECURITY: if you pass a raw Moneta-Redis store, build it with
  # `value_serializer: nil`. The lock release path reads the stored owner
  # token back (`store[key]`) to compare-and-delete; with Moneta's default
  # Marshal value serializer that read `Marshal.load`s bytes from Redis — an
  # RCE vector on a shared/untrusted/MITM'd lock store. With
  # `value_serializer: nil` the owner token is a plain string and is never
  # deserialized. Alternatively pass a {Parse::Cache::Redis} instance, which
  # uses a raw-string acquire/release path and avoids Marshal entirely.
  # @example
  #   Parse.synchronize_create_store = Moneta.new(:Redis, url: "redis://locks:6379/1", value_serializer: nil)
  #   # or, preferred:
  #   Parse.synchronize_create_store = Parse::Cache::Redis.new(url: "redis://locks:6379/1")
  @synchronize_create_store = nil

  # Optional allowlist of {Parse::Object} subclasses that may use the
  # synchronize-create lock. When set, calls from any other class raise
  # {Parse::CreateLockUnavailableError}. When nil (default) with the global
  # default enabled, a one-time `[Parse::Stack:SECURITY]` warning is emitted
  # noting the unbounded surface; the lock still applies to every class.
  #
  # **Inheritance behavior:** The allowlist check in
  # {Parse::Core::Actions::ClassMethods#_assert_synchronize_class_allowed!}
  # uses `self <= entry`, so any subclass of an allowlisted Class entry is
  # itself allowlisted. Allowlisting `User` transitively allowlists every
  # `class GuestUser < User` / `class AdminUser < User` etc. — declared now
  # OR ever defined later in the process. If you need strict per-class
  # gating, pass entries as String names (`"User"`) — those are matched
  # against `self.name` / `parse_class` only, with no inheritance walk.
  # @example Restrict to specific classes (subclasses inherit)
  #   Parse.synchronize_classes = [User, Device, Subscription]
  # @example Strict equality, no inheritance
  #   Parse.synchronize_classes = ["User", "Device", "Subscription"]
  @synchronize_classes = nil

  # Suppress the one-shot Parse Server version deprecation warning emitted
  # by {Parse::API::Server#server_info} when the connected server is below
  # the floor in {Parse::API::Server::DEPRECATED_SERVER_VERSION_BELOW}.
  # Operators on a known-old Parse Server pinned for an explicit reason
  # can set this once at boot; the ENV form
  # `PARSE_SUPPRESS_SERVER_VERSION_WARNING=true` is honored equivalently.
  # @example Silence in code
  #   Parse.suppress_server_version_warning = true
  @suppress_server_version_warning = false

  # Slow-query threshold for the bundled slow-query subscriber. When
  # set to a positive integer, the SDK subscribes once to
  # `parse.mongodb.aggregate` and `parse.mongodb.find` AS::N events
  # and emits a `[Parse::MongoDB] SLOW` warning to `Parse.logger`
  # whenever an event's wall-clock duration exceeds the threshold (in
  # milliseconds). The log line contains ONLY metadata — collection,
  # scope, stage_count/stage_types (aggregate), or has_filter/
  # projection_keys (find), result_count, max_time_ms. Pipeline
  # bodies, filter bodies, and result rows are never included.
  #
  # The threshold is re-read on every event, so toggling
  # `Parse.slow_query_threshold_ms = nil` at runtime silences the
  # logger without unsubscribing. The ENV form
  # `PARSE_SLOW_QUERY_THRESHOLD_MS=250` is honored equivalently and
  # is bootstrapped at module-load (setting the ENV before `require
  # "parse/stack"` is sufficient — no explicit setter call needed).
  # Operators who already subscribe to the raw AS::N events from
  # their APM/OTel layer don't need this knob.
  # @example
  #   Parse.slow_query_threshold_ms = 250
  @slow_query_threshold_ms = nil
  @slow_query_subscribed = false

  class << self
    attr_accessor :warn_on_query_issues, :autofetch_raise_on_missing_keys, :serialize_only_fetched_fields, :validate_query_keys,
                  :live_query_enabled, :cache_write_on_fetch, :default_query_cache, :mcp_server_enabled, :mcp_server_port, :mcp_remote_api,
                  :rewrite_lookups, :strict_property_redefinition,
                  :synchronize_create_default, :synchronize_create_options, :synchronize_create_secret,
                  :synchronize_create_store, :synchronize_classes,
                  :strict_pointer_shapes, :suppress_server_version_warning,
                  :pluralized_aliases

    # Check whether the Parse Server version deprecation warning is
    # silenced. Returns true if either the in-process accessor or the
    # `PARSE_SUPPRESS_SERVER_VERSION_WARNING` ENV is set.
    # @return [Boolean]
    def suppress_server_version_warning?
      @suppress_server_version_warning == true || ENV["PARSE_SUPPRESS_SERVER_VERSION_WARNING"] == "true"
    end

    # Current slow-query threshold in milliseconds, or `nil` when
    # unconfigured. Resolves the in-process accessor first; falls back
    # to the `PARSE_SLOW_QUERY_THRESHOLD_MS` ENV. Non-positive values
    # are treated as `nil` (disabled).
    # @return [Integer, nil]
    def slow_query_threshold_ms
      value = @slow_query_threshold_ms
      value = ENV["PARSE_SLOW_QUERY_THRESHOLD_MS"].to_i if value.nil? && ENV["PARSE_SLOW_QUERY_THRESHOLD_MS"]
      value && value > 0 ? value : nil
    end

    # Set the slow-query threshold in milliseconds. When set to a
    # positive integer, lazily attaches the bundled subscriber to
    # `parse.mongodb.aggregate` and `parse.mongodb.find` so events
    # exceeding the threshold log a warning to {Parse.logger}. Set
    # to `nil` (or any non-positive value) to disable; the subscriber
    # stays attached but becomes a cheap pass-through.
    # @param value [Integer, nil]
    def slow_query_threshold_ms=(value)
      @slow_query_threshold_ms = value
      _attach_slow_query_subscriber!
      value
    end

    # @!visibility private
    # Attach the slow-query subscriber exactly once per process. The
    # subscriber re-reads {Parse.slow_query_threshold_ms} on every
    # event so toggling the knob at runtime takes effect without a
    # resubscribe. Safe to call repeatedly — guarded by
    # `@slow_query_subscribed`.
    def _attach_slow_query_subscriber!
      return if @slow_query_subscribed
      return unless defined?(ActiveSupport::Notifications)
      @slow_query_subscribed = true
      handler = lambda do |name, started, finished, _id, payload|
        threshold = slow_query_threshold_ms
        next if threshold.nil?
        duration_ms = ((finished - started) * 1000.0).round(1)
        next if duration_ms < threshold
        logger = respond_to?(:logger) ? Parse.logger : nil
        next unless logger
        detail =
          if name == "parse.mongodb.aggregate"
            "stages=#{payload[:stage_count]} types=#{Array(payload[:stage_types]).join(',')}"
          else
            "filter=#{!!payload[:has_filter]} projection=#{Array(payload[:projection_keys]).join(',')}"
          end
        logger.warn(
          "[Parse::MongoDB] SLOW #{name} #{duration_ms}ms " \
          "collection=#{payload[:collection]} scope=#{payload[:scope] || 'n/a'} " \
          "#{detail} result_count=#{payload[:result_count] || 'n/a'} " \
          "max_time_ms=#{payload[:max_time_ms] || 'n/a'}",
        )
      end
      ActiveSupport::Notifications.subscribe("parse.mongodb.aggregate", &handler)
      ActiveSupport::Notifications.subscribe("parse.mongodb.find", &handler)
    end

    # Check if LiveQuery feature is enabled
    # @return [Boolean]
    def live_query_enabled?
      @live_query_enabled == true
    end

    # Check if strict pointer-shape validation is enabled. When true,
    # impossible shapes (e.g. bare string `$in` element against a
    # pointer column whose target class is unknown) raise
    # {Parse::Query::PointerShapeError} instead of silently returning
    # zero rows. See {Parse.strict_pointer_shapes=}.
    # @return [Boolean]
    def strict_pointer_shapes?
      @strict_pointer_shapes == true
    end

    # Whether automatic pluralized class-name aliases are enabled. Defaults
    # to true; opt out with `Parse.pluralized_aliases = false` or
    # `PARSE_PLURALIZED_ALIASES=false`. See {Parse.pluralized_aliases}.
    # @return [Boolean]
    def pluralized_aliases?
      @pluralized_aliases != false
    end

    # @!visibility private
    # Resolve a (possibly plural) missing constant to its singular
    # {Parse::Object} subclass and install the alias on the referencing
    # module. Returns the class when an alias was created, otherwise nil so
    # the caller (`const_missing`) can fall through to `super` and preserve
    # normal `NameError` / autoloading behavior.
    #
    # Guards (fail-through to nil unless ALL hold):
    #   - the feature is enabled,
    #   - {Parse::Object} is loaded,
    #   - the name singularizes to a *different* string (i.e. looks plural),
    #   - the singular form does NOT already end in `s` (per design: classes
    #     whose name ends in `s` are not auto-aliased),
    #   - the singular constant is defined (searching ancestors so a
    #     top-level model is visible from a nested reference) and is a
    #     `Parse::Object` subclass,
    #   - the plural is not already defined on the referencing module.
    #
    # @param mod [Module] the module/class on which `const_missing` fired.
    # @param name [Symbol] the missing constant name.
    # @return [Class, nil]
    def __pluralized_alias_for(mod, name)
      return nil unless pluralized_aliases?
      return nil unless defined?(Parse::Object)
      str = name.to_s
      singular = str.singularize
      return nil if singular == str
      return nil if singular.end_with?("s")
      sym = singular.to_sym
      return nil unless mod.const_defined?(sym, true)
      klass = mod.const_get(sym)
      return nil unless klass.is_a?(Class) && klass < Parse::Object
      return nil if mod.const_defined?(name, false)
      mod.const_set(name, klass)
      klass
    rescue NameError, LoadError
      # const_get/const_defined? can raise on malformed names or autoload
      # failures; never let alias resolution mask the original lookup.
      nil
    end

    # Verify that every association target across the loaded {Parse::Object}
    # subclasses resolves to a known Parse class. Covers `belongs_to` and
    # `property … as:` pointer targets (via each class's `references`),
    # `has_many … through: :relation` targets (via `relations`), and the
    # query- and array-backed `has_many` targets (via `has_many_associations`)
    # — the bucket where an `as:` typo otherwise stays latent until the
    # association is first traversed at call time.
    #
    # This is the deferred companion to the definition-time scalar guard in
    # {Parse::Associations::BelongsTo::ClassMethods#belongs_to}: at declaration
    # time a forward reference (a target class that is required later) is legal
    # and indistinguishable from a typo, so the cross-class resolution check is
    # run here — after all models are loaded. Intended to run once at boot, in
    # CI, or from a rake task ("during the upgrade").
    #
    # A target resolves when it is a Parse system class (`_User`, `_Role`,
    # `_Installation`, `_Session`, …) or a registered {Parse::Object} subclass
    # (via {Parse::Model.find_class}). Note this checks against *loaded Ruby
    # models*: if you intentionally point at a server-side class that has no
    # Ruby model, define a stub model for it or exclude it via `classes:`.
    #
    # @param classes [Array<Class>, nil] optional subset of Parse::Object
    #   subclasses to check; defaults to every loaded subclass.
    # @raise [ArgumentError] if any target is unresolved, listing each
    #   offending `Class#field -> 'Target'`.
    # @return [true] when every association target resolves.
    def validate_associations!(classes: nil)
      models = classes || Parse::Object.descendants
      problems = []
      models.each do |klass|
        next unless klass.respond_to?(:parse_class)
        if klass.respond_to?(:references)
          klass.references.each do |field, target|
            next if _association_target_resolvable?(target)
            # `references` is keyed by the remote (camelCase) column; report the
            # declared Ruby accessor so the operator can find the offending line.
            accessor = (klass.respond_to?(:field_map) && klass.field_map.key(field)) || field
            problems << "#{klass}##{accessor} -> #{target.inspect} (no such Parse class)"
          end
        end
        if klass.respond_to?(:relations)
          klass.relations.each do |field, target|
            next if _association_target_resolvable?(target)
            problems << "#{klass}##{field} (relation) -> #{target.inspect} (no such Parse class)"
          end
        end
        if klass.respond_to?(:has_many_associations)
          klass.has_many_associations.each do |accessor, meta|
            # `:relation`-storage has_many is mirrored into `relations` and is
            # already reported above; only the `:query` and `:array` storage
            # targets (which live nowhere else) need checking here. This is the
            # branch where a `has_many … as:` typo hides, since a query-backed
            # has_many resolves its target lazily at call time.
            next if meta[:storage] == :relation
            target = meta[:target_class]
            next if target.nil? || _association_target_resolvable?(target)
            problems << "#{klass}##{accessor} (has_many #{meta[:storage]}) -> " \
                        "#{target.inspect} (no such Parse class)"
          end
        end
      end
      unless problems.empty?
        raise ArgumentError,
              "Unresolved Parse association targets:\n  " + problems.join("\n  ") +
              "\nRequire/define the target class, or fix the `as:`/`class_name:` name."
      end
      true
    end

    # @!visibility private
    # Whether an association target class name resolves to a known Parse
    # class. Parse system classes resolve against {Parse::Model::SYSTEM_CLASS_MAP}
    # — both the canonical `_`-prefixed value (`_User`) and the bare-name key
    # (`User`) — even when their Ruby class is not loaded; everything else must
    # resolve via {Parse::Model.find_class}. A leading underscore is NOT a
    # blanket pass: a typo'd system name such as `_Usr` is neither in the map
    # nor a registered model, so it is still surfaced as unresolved.
    def _association_target_resolvable?(target)
      name = target.to_s
      return false if name.empty?
      return true if Parse::Model::SYSTEM_CLASS_MAP.key?(name) ||
                     Parse::Model::SYSTEM_CLASS_MAP.value?(name)
      !Parse::Model.find_class(name).nil?
    end

    # Check if MCP server feature is enabled
    # Requires PARSE_MCP_ENABLED=true in environment AND Parse.mcp_server_enabled = true
    # @return [Boolean]
    def mcp_server_enabled?
      return false unless ENV["PARSE_MCP_ENABLED"] == "true"
      @mcp_server_enabled == true
    end

    # Configure MCP remote API connection
    # @param provider [Symbol] the API provider (:openai, :claude, :custom)
    # @param api_key [String] the API key
    # @param model [String] the model to use (e.g., 'gpt-4', 'claude-3-opus')
    # @param base_url [String, nil] optional custom base URL
    # @return [Hash] the configuration hash
    def configure_mcp_remote_api(provider:, api_key:, model: nil, base_url: nil)
      @mcp_remote_api = {
        provider: provider.to_sym,
        api_key: api_key,
        model: model,
        base_url: base_url,
      }
    end

    # Check if MCP remote API is configured
    # @return [Boolean]
    def mcp_remote_api_configured?
      @mcp_remote_api.is_a?(Hash) && @mcp_remote_api[:api_key].present?
    end

    # Send an analytics event to Parse Server's REST `/events/<name>`
    # endpoint. Thin shortcut around {Parse::Client#send_analytics} so
    # callers don't have to reach into `Parse.client` directly.
    #
    # Dimensions MUST be passed via the `dimensions:` keyword. Loose
    # symbol-keyed arguments at the call site would otherwise be
    # absorbed by `**opts` under Ruby 3's strict keyword separation,
    # and the dimensions would never reach Parse Server — the POST
    # would land with an empty body. Forwarded `**opts` is reserved
    # for request-layer kwargs (`session_token:`, `use_master_key:`,
    # etc.).
    #
    # Parse Server's default analytics adapter is a no-op — events
    # POSTed to `/events` are accepted but neither persisted nor
    # queryable through the SDK. Operators who configure a custom
    # `analyticsAdapter` decide what (if anything) to do with the
    # event and whether to cap dimension count. The legacy parse.com
    # eight-dimension cap does NOT apply to Parse Server out of the
    # box. If you need to read events back, persist them to a regular
    # `Parse::Object` subclass.
    #
    # The underlying request is a blocking HTTP POST — wrap in a
    # thread or background job if you don't want it on the request
    # path.
    #
    # @param name [String, Symbol] event name (e.g. "post_viewed",
    #   "AppOpened"). Restricted to word characters, hyphens, and
    #   dots so the value cannot escape the `/events/` path segment.
    # @param dimensions [Hash] dimension pairs. Values must be
    #   JSON-serializable.
    # @param opts [Hash] forwarded to {Parse::Client#request}.
    # @return [Parse::Response] the response.
    # @raise [ArgumentError] when `name` is empty or contains
    #   characters outside `[\w\-\.]`.
    # @example
    #   Parse.track_event("post_viewed", dimensions: { source: "feed", workspace: "w1" })
    #   Parse.track_event("AppOpened")
    #   Parse.track_event("error", dimensions: { code: "E_RATE_LIMIT" })
    def track_event(name, dimensions: {}, **opts)
      event_name = name.to_s
      unless event_name.match?(/\A[\w\-\.]+\z/)
        raise ArgumentError,
              "Parse.track_event: event name must contain only word characters, " \
              "hyphens, or dots (got #{name.inspect})"
      end
      Parse.client.send_analytics(event_name, dimensions, **opts)
    end

    # Capability probe against the connected Parse Server, delegated to the
    # default client. Builds on the memoized `serverInfo` fetch — see
    # {Parse::API::Server#server_supports?} for the capability table and the
    # fail-open-to-modern semantics.
    # @param feature [Symbol] a capability key.
    # @return [Boolean] whether the connected server supports the feature.
    def server_supports?(feature)
      Parse.client.server_supports?(feature)
    end

    # The coarse `features` block advertised by `GET /serverInfo`, delegated
    # to the default client. @see Parse::API::Server#server_features
    # @return [Hash] the advertised features block, or `{}` if unavailable.
    def server_features
      Parse.client.server_features
    end
  end

  # Error raised when {Parse::CreateLock#synchronize} cannot acquire the
  # mutex within the configured wait budget. Callers typically rescue and either
  # retry or treat as a temporary unavailability.
  class CreateLockTimeoutError < Parse::Error; end

  # Error raised when query_attrs passed to a synchronized `first_or_create!`
  # contain values that cannot be canonicalized into a stable lock key (Procs,
  # Regexps, query operators, unsaved pointers, nested Hashes, oversized
  # payloads).
  class CreateLockInvalidKey < Parse::Error; end

  # Error raised when a synchronized call is made but the lock store is
  # unavailable (typically `on_degraded: :raise` was configured and the store
  # is process-local).
  class CreateLockUnavailableError < Parse::Error; end

  # Error raised when autofetch would be triggered but Parse.autofetch_raise_on_missing_keys is true.
  # This helps developers identify where they need to add additional keys to their queries.
  class AutofetchTriggeredError < StandardError
    attr_reader :klass, :parse_object_id, :field, :is_pointer

    def initialize(klass, object_id, field, is_pointer:)
      @klass = klass
      @parse_object_id = object_id
      @field = field
      @is_pointer = is_pointer

      if is_pointer
        super("Autofetch triggered on #{klass}##{object_id} - pointer accessed field :#{field}. Add this field to your includes or fetch the object first.")
      else
        super("Autofetch triggered on #{klass}##{object_id} - field :#{field} was not included in partial fetch. Add :#{field} to your query keys.")
      end
    end
  end
end

# Startup warning: If ENV is set but programmatic flag isn't, warn the user
if ENV["PARSE_MCP_ENABLED"] == "true" && !Parse.instance_variable_get(:@mcp_server_enabled)
  warn "[Parse::Stack] PARSE_MCP_ENABLED is set in environment but Parse.mcp_server_enabled is false. " \
       "Call Parse.mcp_server_enabled = true to enable the MCP agent feature."
end

# Startup warning: synchronize-create global-default mode without a class
# allowlist exposes the whole first_or_create!/create_or_update! surface to
# attacker-controlled lock contention. Operators should either restrict via
# Parse.synchronize_classes or audit each call site that takes untrusted input.
if Parse.synchronize_create_default && Parse.synchronize_classes.nil?
  warn "[Parse::Stack:SECURITY] Parse.synchronize_create_default is true with no Parse.synchronize_classes allowlist. " \
       "Every first_or_create!/create_or_update! caller is now subject to Redis-backed lock contention; an attacker " \
       "controlling query_attrs on a public path can hold lock keys × TTL. Set Parse.synchronize_classes = [User, …] " \
       "to restrict the surface, or audit each call site."
end

# Auto-attach the slow-query subscriber when the threshold is supplied
# at boot via ENV. The programmatic setter handles the in-process case;
# the ENV path needs an explicit kick because nothing else calls into
# the setter on load.
Parse._attach_slow_query_subscriber! if Parse.slow_query_threshold_ms

# Install the lazy pluralized class-name alias hook (Posts -> Post). Loaded
# last so Parse::Object and the Parse.__pluralized_alias_for helper are
# already defined. Gated at runtime on Parse.pluralized_aliases?.
require_relative "model/core/pluralized_aliases"

require_relative "stack/railtie" if defined?(::Rails)
