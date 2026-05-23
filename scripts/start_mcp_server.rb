#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Start the Parse MCP Server for AI agent integration.
#
# Required environment variables (no defaults — the script aborts if any
# is missing):
#   PARSE_SERVER_URL  - Parse Server URL (e.g. http://localhost:2337/parse)
#   PARSE_APP_ID      - Application ID
#   PARSE_MASTER_KEY  - Master Key
#
# Optional:
#   PARSE_API_KEY     - REST API Key (defaults unset; configure if your
#                       deployment requires it)
#   MCP_PORT          - MCP Server port (default: 3001)
#   MCP_API_KEY       - Bearer token gating the /mcp endpoint when
#                       binding to a non-loopback host
#
# Why no fallback values: previously this script accepted
# `ENV["PARSE_APP_ID"] || "myAppId"` and the equivalent for the master
# key. A deployment that forgot to set the env var (typo'd name, missing
# secret manager binding, container startup race) would silently boot
# with the placeholder credentials documented in the README — credentials
# that any reader of this repo knows. Failing closed here is a one-line
# safety net against that class of foot-gun.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "parse-stack"

# Hard-fail on any missing required env var. The error message names the
# variable so the operator can fix it without having to re-read the
# header comment.
def require_env!(name)
  value = ENV[name]
  if value.nil? || value.empty?
    abort "[start_mcp_server] Refusing to start: required environment variable #{name} is not set."
  end
  value
end

server_url     = require_env!("PARSE_SERVER_URL")
application_id = require_env!("PARSE_APP_ID")
master_key     = require_env!("PARSE_MASTER_KEY")
api_key        = ENV["PARSE_API_KEY"]  # optional

# Configure Parse client
Parse.setup(
  server_url: server_url,
  application_id: application_id,
  api_key: api_key,
  master_key: master_key,
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
