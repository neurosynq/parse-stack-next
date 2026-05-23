# encoding: UTF-8
# frozen_string_literal: true

require "webrick"
require "json"
require "stringio"
require "active_support/core_ext/object/blank"
require "active_support/security_utils"

require_relative "prompts"
require_relative "mcp_dispatcher"
require_relative "mcp_rack_app"

module Parse
  class Agent
    # MCP (Model Context Protocol) HTTP Server for Parse Stack.
    # Enables external AI agents (Claude, LM Studio, etc.) to interact with
    # Parse data over HTTP using the MCP protocol specification.
    #
    # Since the Rack refactor this class is a thin WEBrick wrapper around
    # {Parse::Agent::MCPRackApp}. Embedded deployments (Sinatra, Rails) should
    # mount MCPRackApp directly with their own agent factory; this class
    # remains for standalone server deployments and back-compat.
    #
    # @example Start the server
    #   Parse::Agent.enable_mcp!
    #   Parse::Agent::MCPServer.run(port: 3001)
    #
    # @example With custom configuration
    #   server = Parse::Agent::MCPServer.new(
    #     port: 3001,
    #     permissions: :readonly,
    #     session_token: nil
    #   )
    #   server.start
    #
    # @see https://modelcontextprotocol.io/ MCP Protocol Specification
    # @see Parse::Agent::MCPRackApp for embedded mounting
    #
    class MCPServer
      # MCP Protocol version
      PROTOCOL_VERSION = MCPDispatcher::PROTOCOL_VERSION

      # Server capabilities
      CAPABILITIES = MCPDispatcher::CAPABILITIES

      # Default port for the MCP server
      @default_port = 3001

      # Maximum allowed request body size (1 MB) — kept as a back-compat constant.
      MAX_BODY_SIZE = MCPRackApp::DEFAULT_MAX_BODY_SIZE

      # Maximum JSON nesting depth — kept as a back-compat constant.
      MAX_JSON_NESTING = MCPRackApp::MAX_JSON_NESTING

      # HTTP header for MCP API key authentication
      MCP_API_KEY_HEADER = "X-MCP-API-Key"

      class << self
        attr_accessor :default_port

        # Start the MCP server (blocking)
        #
        # @param port [Integer] port to listen on
        # @param permissions [Symbol] agent permission level
        # @param session_token [String, nil] optional session token
        # @param host [String] host to bind to
        # @param rate_limiter [#check!, nil] optional external rate limiter
        def run(port: nil, permissions: :readonly, session_token: nil, host: "127.0.0.1", api_key: nil, rate_limiter: nil)
          unless Parse::Agent.mcp_enabled?
            raise "MCP server not enabled. Call Parse::Agent.enable_mcp! first"
          end

          server = new(
            port: port || @default_port,
            permissions: permissions,
            session_token: session_token,
            host: host,
            api_key: api_key,
            rate_limiter: rate_limiter,
          )
          server.start
        end
      end

      # @return [Integer] the port number
      attr_reader :port

      # @return [String] the host to bind to
      attr_reader :host

      # @return [Parse::Agent] the template agent used by the /tools listing
      #   endpoint and as a settings source for per-request agents. Hot tools
      #   in MCP requests run against fresh per-request instances; do NOT
      #   share this object across threads for mutable state inspection.
      attr_reader :agent

      # Create a new MCP server instance
      #
      # @param port [Integer] port to listen on
      # @param host [String] host to bind to
      # @param permissions [Symbol] agent permission level
      # @param session_token [String, nil] optional session token
      # @param rate_limiter [#check!, nil] optional external rate limiter (e.g.
      #   Redis-backed). When provided, replaces the default in-process
      #   {Parse::Agent::RateLimiter}. Must respond to `#check!` and raise
      #   {Parse::Agent::RateLimitExceeded} when the budget is exhausted.
      # @raise [ArgumentError] if rate_limiter is provided but does not respond to :check!
      # Loopback hosts that are safe to bind to without an API key.
      LOOPBACK_HOSTS = %w[127.0.0.1 ::1 localhost].freeze

      def initialize(port: 3001, host: "127.0.0.1", permissions: :readonly,
                     session_token: nil, api_key: nil, rate_limiter: nil,
                     pre_auth_rate_limiter: nil,
                     allowed_origins: nil, require_custom_header: nil)
        if rate_limiter && !rate_limiter.respond_to?(:check!)
          raise ArgumentError, "rate_limiter must respond to #check!"
        end
        if pre_auth_rate_limiter && !pre_auth_rate_limiter.respond_to?(:check!)
          raise ArgumentError, "pre_auth_rate_limiter must respond to #check!"
        end

        effective_api_key = api_key || ENV["MCP_API_KEY"]

        # NEW-MCP-1: a non-loopback bind without an API key is an unauthenticated
        # network-exposed JSON-RPC endpoint. Refuse to start. Operators who
        # genuinely want this — e.g., behind a reverse proxy that handles
        # auth — should bind to localhost and let the proxy forward, or
        # set MCP_API_KEY explicitly even when "the proxy authenticates"
        # (defense in depth).
        if !LOOPBACK_HOSTS.include?(host.to_s) && effective_api_key.to_s.empty?
          raise ArgumentError,
                "MCPServer refuses to bind non-loopback host #{host.inspect} without an api_key. " \
                "Set MCP_API_KEY in the environment, pass api_key: explicitly, or use a loopback " \
                "host (one of: #{LOOPBACK_HOSTS.join(', ')})."
        end

        @port = port
        @host = host
        @api_key = effective_api_key
        @permissions = permissions
        @session_token = session_token

        # Shared limiter across requests so per-request agents (built in
        # agent_factory) don't reset their window on every call. The
        # rate-limit budget is a server-level resource, not a per-Agent one.
        @shared_rate_limiter = rate_limiter || RateLimiter.new

        # Template agent for the /tools listing endpoint and for inspection
        # via #agent. NOT used for live request dispatch — see agent_factory.
        @agent = Parse::Agent.new(
          permissions: @permissions,
          session_token: @session_token,
          rate_limiter: @shared_rate_limiter,
        )
        @server = nil

        # The Rack app does the heavy lifting. Its agent_factory enforces the
        # API key and constructs a FRESH Parse::Agent per request so the
        # per-instance state (@conversation_history, @operation_log, token
        # counters) cannot leak between requests.
        # pre_auth_rate_limiter: closes NEW-MCP-6 — runs before the factory
        # is invoked so an empty or malformed body can't amplify into a
        # Parse Server round-trip.
        @rack_app = MCPRackApp.new(
          agent_factory: method(:agent_factory),
          pre_auth_rate_limiter: pre_auth_rate_limiter,
          allowed_origins: allowed_origins,
          require_custom_header: require_custom_header,
        )
      end

      # Start the HTTP server (blocking)
      def start
        @server = WEBrick::HTTPServer.new(
          Port: @port,
          BindAddress: @host,
          Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO),
          AccessLog: [[::File.open(::File::NULL, "w"), ""]], # Suppress access log
        )

        setup_routes

        trap("INT") { stop }
        trap("TERM") { stop }

        puts "Parse MCP Server starting on http://#{@host}:#{@port}"
        puts "Permissions: #{@agent.permissions}"
        puts "Tools available: #{@agent.allowed_tools.join(", ")}"

        @server.start
      end

      # Stop the server
      def stop
        @server&.shutdown
      end

      private

      def setup_routes
        # MCP endpoint — translated WEBrick request → Rack env → MCPRackApp.
        @server.mount_proc("/mcp") { |req, res| handle_mcp_request(req, res) }

        # Health check endpoint (unauthenticated - standard for monitoring)
        @server.mount_proc("/health") do |_req, res|
          json_response(res, { status: "ok", mcp_enabled: true })
        end

        # Tool list endpoint (requires auth if API key is configured)
        @server.mount_proc("/tools") do |req, res|
          if @api_key.present?
            provided_key = req[MCP_API_KEY_HEADER].to_s
            unless ActiveSupport::SecurityUtils.secure_compare(@api_key, provided_key)
              error_response(res, 401, "Unauthorized: invalid or missing API key")
              next
            end
          end
          json_response(res, @agent.tool_definitions(format: :mcp))
        end
      end

      # Translate a WEBrick request into a minimal Rack env and dispatch to the
      # MCPRackApp. The agent_factory bound at construction handles API-key
      # auth and returns the shared @agent for valid requests.
      #
      # WEBrick HTTPRequest#body reads lazily from the socket. We must reject
      # oversized bodies BEFORE calling req.body. Two attack shapes:
      #   (a) Content-Length > MAX_BODY_SIZE — caught by the explicit check.
      #   (b) Transfer-Encoding: chunked with no Content-Length — WEBrick's
      #       read_chunked has no size cap and will dechunk indefinitely.
      # We refuse (b) entirely: chunked or missing-Content-Length requests
      # return 411 "Length Required" before req.body is ever called.
      def handle_mcp_request(req, res)
        # NEW-MCP-5: WEBrick's mount_proc("/mcp") is prefix-matching, so
        # `/mcp/anything/at/all` reaches this handler and forwards the
        # extra path segments into the Rack app via PATH_INFO. Reverse
        # proxies that enforce ACLs against `^/mcp$` (or that route
        # `/mcp/admin` to a different upstream) will be defeated by the
        # prefix match unless we explicitly reject sub-paths here. A
        # trailing slash is accepted — `/mcp/` is the same endpoint —
        # but anything beyond is 404.
        normalized = req.path.to_s.chomp("/")
        unless normalized == "/mcp"
          res.status = 404
          res.content_type = "application/json"
          res.body = JSON.generate({
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => { "code" => -32_601, "message" => "Not Found" },
          })
          return
        end

        # Method gate FIRST. Returning 411 for a GET because it lacks a
        # Content-Length is semantically wrong (the method itself is not
        # allowed; body requirements never apply) and surprises Rack
        # middleware that expects 405 for method-mismatch.
        unless req.request_method == "POST"
          res.status = 405
          res["Allow"] = "POST"
          res.content_type = "application/json"
          res.body = JSON.generate({
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => { "code" => -32_600, "message" => "Method Not Allowed: only POST is accepted" },
          })
          return
        end

        transfer_encoding = req["Transfer-Encoding"].to_s.downcase
        content_length_header = req["Content-Length"]
        if transfer_encoding.include?("chunked") || content_length_header.nil?
          res.status = 411
          res.content_type = "application/json"
          res.body = JSON.generate({
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => { "code" => -32_700, "message" => "Length Required: Content-Length header is required and Transfer-Encoding: chunked is not accepted" },
          })
          return
        end

        content_length = content_length_header.to_i
        if content_length > MCPRackApp::DEFAULT_MAX_BODY_SIZE
          res.status = 413
          res.content_type = "application/json"
          res.body = JSON.generate({
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => { "code" => -32_700, "message" => "Payload Too Large: body exceeds #{MCPRackApp::DEFAULT_MAX_BODY_SIZE} bytes" },
          })
          return
        end

        env = build_rack_env(req)
        status, headers, body_chunks = @rack_app.call(env)

        res.status = status
        rack_ct = headers["Content-Type"] || headers["content-type"]
        headers.each { |k, v| res[k] = v unless k.casecmp("Content-Type").zero? }
        res.content_type = rack_ct if rack_ct
        res.body = body_chunks.join
      end

      # Agent factory passed to MCPRackApp. Enforces the API-key check (raising
      # Parse::Agent::Unauthorized so the Rack app renders a sanitized 401)
      # and then constructs a FRESH Parse::Agent per request, sharing only
      # the @shared_rate_limiter so the budget persists across calls.
      #
      # The per-instance @conversation_history, @operation_log, and token
      # counters on each returned agent are scoped to that single request
      # and discarded when it ends, eliminating cross-request leakage.
      def agent_factory(env)
        if @api_key.present?
          provided_key = env["HTTP_X_MCP_API_KEY"].to_s
          unless ActiveSupport::SecurityUtils.secure_compare(@api_key, provided_key)
            raise Parse::Agent::Unauthorized.new("invalid or missing API key", reason: :bad_api_key)
          end
        end

        Parse::Agent.new(
          permissions: @permissions,
          session_token: @session_token,
          rate_limiter: @shared_rate_limiter,
        )
      end

      # Build a minimal Rack env from a WEBrick request. We populate the
      # fields MCPRackApp reads (REQUEST_METHOD, CONTENT_TYPE, rack.input,
      # HTTP_X_MCP_API_KEY) plus a few Rack-required keys so middleware that
      # might wrap us still sees a plausible env. Per the Rack SPEC, the
      # special Content-Type and Content-Length headers are top-level keys
      # (no HTTP_ prefix), so the header-enumeration loop excludes them.
      RACK_TOP_LEVEL_HEADERS = %w[Content-Type Content-Length].freeze

      def build_rack_env(req)
        env = {
          "REQUEST_METHOD" => req.request_method,
          "CONTENT_TYPE" => req["Content-Type"].to_s,
          "CONTENT_LENGTH" => req["Content-Length"].to_s,
          "rack.input" => StringIO.new(req.body || ""),
          "rack.errors" => $stderr,
          "rack.url_scheme" => "http",
          "SERVER_NAME" => @host,
          "SERVER_PORT" => @port.to_s,
          "PATH_INFO" => req.path,
          "QUERY_STRING" => req.query_string.to_s,
        }
        req.each do |name|
          next if RACK_TOP_LEVEL_HEADERS.any? { |h| name.casecmp(h).zero? }
          # NEW-MCP-2: refuse header names that already contain underscores.
          # `X-MCP-API-Key` and `X_MCP_API_KEY` both collapse to the same
          # Rack env key (`HTTP_X_MCP_API_KEY`); a reverse proxy that
          # injects the trusted dash-form can be undermined by an attacker
          # also sending the underscore-form. Drop the underscore variant
          # at the transport layer.
          next if name.include?("_")
          header_key = "HTTP_#{name.upcase.tr("-", "_")}"
          env[header_key] = req[name].to_s
        end
        env
      end

      def json_response(res, data)
        res.content_type = "application/json"
        res.body = JSON.generate(data)
      end

      def error_response(res, status, message)
        res.status = status
        json_response(res, { error: message })
      end
    end
  end
end
