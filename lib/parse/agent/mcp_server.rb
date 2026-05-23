# encoding: UTF-8
# frozen_string_literal: true

require "webrick"
require "json"
require "active_support/core_ext/object/blank"
require "active_support/security_utils"

module Parse
  class Agent
    # MCP (Model Context Protocol) HTTP Server for Parse Stack.
    # Enables external AI agents (Claude, LM Studio, etc.) to interact with
    # Parse data over HTTP using the MCP protocol specification.
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
    #
    class MCPServer
      # MCP Protocol version
      PROTOCOL_VERSION = "2024-11-05"

      # Server capabilities
      CAPABILITIES = {
        tools: { listChanged: false },
        resources: { subscribe: false, listChanged: false },
        prompts: { listChanged: false },
      }.freeze

      # Default port for the MCP server
      @default_port = 3001

      # Maximum allowed request body size (1 MB)
      MAX_BODY_SIZE = 1_048_576

      # Maximum JSON nesting depth
      MAX_JSON_NESTING = 20

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
        def run(port: nil, permissions: :readonly, session_token: nil, host: "127.0.0.1", api_key: nil)
          unless Parse::Agent.mcp_enabled?
            raise "MCP server not enabled. Call Parse::Agent.enable_mcp! first"
          end

          server = new(
            port: port || @default_port,
            permissions: permissions,
            session_token: session_token,
            host: host,
            api_key: api_key,
          )
          server.start
        end
      end

      # @return [Integer] the port number
      attr_reader :port

      # @return [String] the host to bind to
      attr_reader :host

      # @return [Parse::Agent] the agent instance
      attr_reader :agent

      # Create a new MCP server instance
      #
      # @param port [Integer] port to listen on
      # @param host [String] host to bind to
      # @param permissions [Symbol] agent permission level
      # @param session_token [String, nil] optional session token
      def initialize(port: 3001, host: "127.0.0.1", permissions: :readonly, session_token: nil, api_key: nil)
        @port = port
        @host = host
        @api_key = api_key || ENV["MCP_API_KEY"]
        @agent = Parse::Agent.new(permissions: permissions, session_token: session_token)
        @server = nil
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
        # MCP endpoint for all protocol messages
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

      # Handle MCP protocol requests
      def handle_mcp_request(req, res)
        unless req.request_method == "POST"
          return error_response(res, 405, "Method not allowed")
        end

        # C4: API key authentication
        if @api_key.present?
          provided_key = req[MCP_API_KEY_HEADER].to_s
          unless ActiveSupport::SecurityUtils.secure_compare(@api_key, provided_key)
            return error_response(res, 401, "Unauthorized: invalid or missing API key")
          end
        end

        # C5: Payload size limit
        raw_body = req.body || "{}"
        if raw_body.bytesize > MAX_BODY_SIZE
          return error_response(res, 413, "Payload too large (max #{MAX_BODY_SIZE} bytes)")
        end

        begin
          body = JSON.parse(raw_body, max_nesting: MAX_JSON_NESTING)
        rescue JSON::ParserError, JSON::NestingError => e
          return error_response(res, 400, "Invalid JSON: #{e.message}")
        end

        method = body["method"]
        params = body["params"] || {}
        id = body["id"]

        result = case method
          when "initialize"
            handle_initialize(params)
          when "tools/list"
            handle_tools_list(params)
          when "tools/call"
            handle_tools_call(params)
          when "resources/list"
            handle_resources_list(params)
          when "prompts/list"
            handle_prompts_list(params)
          when "ping"
            {}
          else
            { error: { code: -32601, message: "Method not found: #{method}" } }
          end

        response = {
          jsonrpc: "2.0",
          id: id,
        }

        if result[:error]
          response[:error] = result[:error]
        else
          response[:result] = result
        end

        json_response(res, response)
      end

      # Handle MCP initialize request
      def handle_initialize(_params)
        {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: CAPABILITIES,
          serverInfo: {
            name: "parse-stack-mcp",
            version: Parse::Stack::VERSION,
          },
        }
      end

      # Handle tools/list request
      def handle_tools_list(_params)
        {
          tools: @agent.tool_definitions(format: :mcp),
        }
      end

      # Handle tools/call request
      def handle_tools_call(params)
        tool_name = params["name"]
        arguments = params["arguments"] || {}

        unless tool_name
          return { error: { code: -32602, message: "Missing tool name" } }
        end

        # Convert string keys to symbols for Ruby
        sym_args = arguments.transform_keys(&:to_sym)

        result = @agent.execute(tool_name.to_sym, **sym_args)

        if result[:success]
          {
            content: [
              {
                type: "text",
                text: JSON.pretty_generate(result[:data]),
              },
            ],
            isError: false,
          }
        else
          {
            content: [
              {
                type: "text",
                text: result[:error],
              },
            ],
            isError: true,
          }
        end
      end

      # Handle resources/list request (Parse classes as resources)
      def handle_resources_list(_params)
        result = @agent.execute(:get_all_schemas)

        if result[:success]
          resources = result[:data][:classes].map do |cls|
            {
              uri: "parse://#{cls[:name]}",
              name: cls[:name],
              description: "Parse class: #{cls[:type]}",
              mimeType: "application/json",
            }
          end
          { resources: resources }
        else
          { resources: [] }
        end
      end

      # Handle prompts/list request
      def handle_prompts_list(_params)
        {
          prompts: [
            {
              name: "explore_database",
              description: "Get an overview of the Parse database structure",
              arguments: [],
            },
            {
              name: "query_builder",
              description: "Help build a query for a specific class",
              arguments: [
                {
                  name: "class_name",
                  description: "The Parse class to query",
                  required: true,
                },
              ],
            },
          ],
        }
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
