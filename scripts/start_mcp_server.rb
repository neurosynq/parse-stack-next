#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Start the Parse MCP Server for AI agent integration
#
# Usage:
#   ruby scripts/start_mcp_server.rb
#
# Environment variables:
#   PARSE_SERVER_URL - Parse Server URL (default: http://localhost:2337/parse)
#   PARSE_APP_ID - Application ID (default: myAppId)
#   PARSE_API_KEY - REST API Key (default: test-rest-key)
#   PARSE_MASTER_KEY - Master Key (default: myMasterKey)
#   MCP_PORT - MCP Server port (default: 3001)

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "parse-stack"

# Configure Parse client
Parse.setup(
  server_url: ENV["PARSE_SERVER_URL"] || "http://localhost:2337/parse",
  application_id: ENV["PARSE_APP_ID"] || "myAppId",
  api_key: ENV["PARSE_API_KEY"] || "test-rest-key",
  master_key: ENV["PARSE_MASTER_KEY"] || "myMasterKey"
)

port = (ENV["MCP_PORT"] || 3001).to_i

puts "=" * 60
puts "Parse MCP Server"
puts "=" * 60
puts ""
puts "Parse Server: #{Parse.client.server_url}"
puts "MCP Port: #{port}"
puts ""
puts "Endpoints:"
puts "  Health:  http://localhost:#{port}/health"
puts "  Tools:   http://localhost:#{port}/tools"
puts "  MCP:     http://localhost:#{port}/mcp (POST)"
puts ""
puts "For LM Studio, configure the API endpoint as:"
puts "  http://localhost:#{port}/mcp"
puts ""
puts "=" * 60

# Enable MCP server feature (experimental)
Parse.mcp_server_enabled = true
Parse::Agent.enable_mcp!(port: port)
Parse::Agent::MCPServer.run(port: port)
