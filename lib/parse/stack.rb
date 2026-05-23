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

module Parse
  class Error < StandardError; end

  module Stack
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

  class << self
    attr_accessor :warn_on_query_issues, :autofetch_raise_on_missing_keys, :serialize_only_fetched_fields, :validate_query_keys,
                  :live_query_enabled, :cache_write_on_fetch, :default_query_cache, :mcp_server_enabled, :mcp_server_port, :mcp_remote_api

    # Check if LiveQuery feature is enabled
    # @return [Boolean]
    def live_query_enabled?
      @live_query_enabled == true
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

  # Error raised when autofetch would be triggered but Parse.autofetch_raise_on_missing_keys is true.
  # This helps developers identify where they need to add additional keys to their queries.
  class AutofetchTriggeredError < StandardError
    attr_reader :klass, :object_id, :field, :is_pointer

    def initialize(klass, object_id, field, is_pointer:)
      @klass = klass
      @object_id = object_id
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

require_relative "stack/railtie" if defined?(::Rails)
