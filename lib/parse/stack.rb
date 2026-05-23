# encoding: UTF-8
# frozen_string_literal: true

require "net/http"
require "uri"

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

module Parse
  class Error < StandardError; end

  module Stack
  end

  # Fiber-local key consulted by the authentication middleware. A truthy
  # entry suppresses the master-key header for the duration of the block
  # set by {Parse.without_master_key}; a +:enabled+ entry forces the
  # master-key header back on inside a nested {Parse.with_master_key}
  # block.
  MASTER_KEY_STATE_KEY = :__parse_master_key_state__

  # Run +block+ with the master key suppressed for every Parse request
  # originating in the current fiber. Equivalent to setting the
  # +X-Disable-Parse-Master-Key+ header on each request, but block-scoped
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

  # Configuration for experimental LiveQuery feature.
  # LiveQuery provides real-time WebSocket subscriptions for reactive applications.
  # This feature is experimental and not fully implemented. Enable at your own risk.
  # @example Enable LiveQuery (experimental)
  #   Parse.live_query_enabled = true
  #   require 'parse/live_query'
  # @note WebSocket client implementation is incomplete
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
  # @example
  #   Parse.synchronize_create_store = Moneta.new(:Redis, url: "redis://locks:6379/1")
  @synchronize_create_store = nil

  # Optional allowlist of {Parse::Object} subclasses that may use the
  # synchronize-create lock. When set, calls from any other class raise
  # {Parse::CreateLockUnavailableError}. When nil (default) with the global
  # default enabled, a one-time +[Parse::Stack:SECURITY]+ warning is emitted
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

  class << self
    attr_accessor :warn_on_query_issues, :autofetch_raise_on_missing_keys, :serialize_only_fetched_fields, :validate_query_keys,
                  :live_query_enabled, :cache_write_on_fetch, :default_query_cache, :mcp_server_enabled, :mcp_server_port, :mcp_remote_api,
                  :rewrite_lookups, :strict_property_redefinition,
                  :synchronize_create_default, :synchronize_create_options, :synchronize_create_secret,
                  :synchronize_create_store, :synchronize_classes,
                  :strict_pointer_shapes

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

  # Special class to support Modernistik Hyperdrive server.
  class Hyperdrive
    # Applies a remote JSON hash containing the ENV keys and values from a remote
    # URL. Values from the JSON hash are only applied to the current ENV hash ONLY if
    # it does not already have a value. Therefore local ENV values will take precedence
    # over remote ones. By default, it uses the url in environment value in 'CONFIG_URL' or 'HYPERDRIVE_URL'.
    # @param url [String] the remote url that responds with the JSON body.
    # @return [Boolean] true if the JSON hash was found and applied successfully.
    def self.config!(url = nil)
      url ||= ENV["HYPERDRIVE_URL"] || ENV["CONFIG_URL"]
      return false if url.blank?

      begin
        uri = URI.parse(url)

        # Security: Only allow HTTPS or localhost HTTP for development
        unless uri.is_a?(URI::HTTPS) || (uri.is_a?(URI::HTTP) && %w[localhost 127.0.0.1].include?(uri.host))
          warn "[Parse::Stack] Security: Config URL must be HTTPS (got: #{url})"
          return false
        end

        # Use Net::HTTP instead of open-uri to avoid command injection via pipe characters
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 10

        request = Net::HTTP::Get.new(uri.request_uri)
        response = http.request(request)

        unless response.is_a?(Net::HTTPSuccess)
          warn "[Parse::Stack] Config fetch failed: #{url} (HTTP #{response.code})"
          return false
        end

        # Parse JSON safely
        remote_config = JSON.parse(response.body)

        unless remote_config.is_a?(Hash)
          warn "[Parse::Stack] Config must be a JSON object: #{url}"
          return false
        end

        remote_config.each do |key, value|
          k = key.to_s.upcase
          # Validate key format to prevent injection
          next unless k.match?(/\A[A-Z][A-Z0-9_]*\z/)
          next unless ENV[k].nil?
          ENV[k] = value.to_s
        end
        true
      rescue URI::InvalidURIError => e
        warn "[Parse::Stack] Invalid config URL: #{url} (#{e.message})"
        false
      rescue JSON::ParserError => e
        warn "[Parse::Stack] Invalid JSON in config: #{url} (#{e.message})"
        false
      rescue StandardError => e
        warn "[Parse::Stack] Error loading config: #{url} (#{e.class}: #{e.message})"
        false
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

require_relative "stack/railtie" if defined?(::Rails)
