#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Evaluate MCP Server with LM Studio
#
# This script connects LM Studio to the Parse MCP Server, allowing the
# LLM to query Parse data using the MCP tools.
#
# Usage:
#   ruby scripts/eval_mcp_with_lm_studio.rb
#
# Prerequisites:
#   - LM Studio running at http://127.0.0.1:1234
#   - MCP Server running at http://localhost:3001
#   - Parse Server running with test data

require "net/http"
require "json"
require "uri"

class MCPLMStudioEvaluator
  LM_STUDIO_URL = ENV["LM_STUDIO_URL"] || "http://127.0.0.1:1234"
  MCP_SERVER_URL = ENV["MCP_SERVER_URL"] || "http://localhost:3001"

  def initialize
    @conversation = []
    @tool_definitions = nil
  end

  # Fetch tool definitions from MCP server
  def fetch_tools
    uri = URI("#{MCP_SERVER_URL}/tools")
    response = Net::HTTP.get_response(uri)

    unless response.is_a?(Net::HTTPSuccess)
      raise "Failed to fetch tools: #{response.code} #{response.message}"
    end

    tools = JSON.parse(response.body)

    # Convert MCP format to OpenAI function calling format
    @tool_definitions = tools.map do |tool|
      {
        type: "function",
        function: {
          name: tool["name"],
          description: tool["description"],
          parameters: tool["inputSchema"]
        }
      }
    end

    puts "Loaded #{@tool_definitions.size} tools from MCP server"
    @tool_definitions
  end

  # Call a tool via MCP server
  def call_mcp_tool(tool_name, arguments)
    uri = URI("#{MCP_SERVER_URL}/mcp")
    http = Net::HTTP.new(uri.host, uri.port)

    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate({
      jsonrpc: "2.0",
      id: rand(10000),
      method: "tools/call",
      params: {
        name: tool_name,
        arguments: arguments
      }
    })

    response = http.request(request)
    result = JSON.parse(response.body)

    if result["error"]
      { error: result["error"]["message"] }
    else
      result["result"]
    end
  end

  # Send a message to LM Studio
  def chat_with_lm(user_message, tools: true)
    uri = URI("#{LM_STUDIO_URL}/v1/chat/completions")
    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 300  # LLMs can be slow, especially larger models
    http.open_timeout = 30

    @conversation << { role: "user", content: user_message }

    request_body = {
      model: "qwen2.5-32b-instruct",
      messages: @conversation,
      temperature: 0.1,
      max_tokens: 2000
    }

    # Add tools if available and requested
    if tools && @tool_definitions
      request_body[:tools] = @tool_definitions
      request_body[:tool_choice] = "auto"
    end

    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(request_body)

    puts "\n>>> Sending to LM Studio..."
    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise "LM Studio error: #{response.code} #{response.message}\n#{response.body}"
    end

    result = JSON.parse(response.body)
    assistant_message = result["choices"][0]["message"]

    @conversation << assistant_message

    assistant_message
  end

  # Check if message has actual tool calls
  def has_tool_calls?(message)
    return false unless message
    tool_calls = message["tool_calls"]
    return false unless tool_calls.is_a?(Array) && !tool_calls.empty?
    tool_calls.any? { |tc| tc["function"] && tc["function"]["name"] }
  end

  # Process tool calls from the LLM
  def process_tool_calls(message)
    tool_calls = message["tool_calls"]
    return nil unless tool_calls && !tool_calls.empty?

    tool_results = []

    tool_calls.each do |tool_call|
      function = tool_call["function"]
      next unless function && function["name"]

      tool_name = function["name"]
      arguments = JSON.parse(function["arguments"] || "{}")

      puts "\n🔧 LLM calling tool: #{tool_name}"
      puts "   Arguments: #{JSON.pretty_generate(arguments)}"

      result = call_mcp_tool(tool_name, arguments)

      puts "   Result preview: #{result.to_s[0..200]}..."

      tool_results << {
        role: "tool",
        tool_call_id: tool_call["id"],
        content: JSON.generate(result)
      }
    end

    return message if tool_results.empty?

    # Add tool results to conversation
    tool_results.each { |r| @conversation << r }

    # Get LLM's response after tool calls - allow more tool calls
    chat_with_lm("", tools: true)
  end

  # Run a full evaluation with a user prompt
  def evaluate(prompt)
    puts "=" * 60
    puts "MCP + LM Studio Evaluation"
    puts "=" * 60
    puts "\nLM Studio: #{LM_STUDIO_URL}"
    puts "MCP Server: #{MCP_SERVER_URL}"
    puts "\nUser prompt: #{prompt}"
    puts "=" * 60

    # Initialize
    fetch_tools

    # Add system message
    @conversation = [{
      role: "system",
      content: <<~SYSTEM
        You are a helpful assistant with access to a Parse database.
        Use the available tools to answer questions about the data.
        Always start by getting the schema if you need to understand the database structure.
        When querying, be specific and use appropriate constraints.
      SYSTEM
    }]

    # Send user message
    response = chat_with_lm(prompt)

    # Handle tool calls in a loop
    max_iterations = 5
    iterations = 0

    while has_tool_calls?(response) && iterations < max_iterations
      iterations += 1
      puts "\n--- Tool call iteration #{iterations} ---"
      new_response = process_tool_calls(response)
      break if new_response.nil? || new_response == response
      response = new_response
    end

    puts "\n" + "=" * 60
    puts "Final Response:"
    puts "=" * 60
    puts response["content"]
    puts "=" * 60

    response["content"]
  end

  # Check if services are available
  def check_services
    puts "Checking services..."

    # Check LM Studio
    begin
      uri = URI("#{LM_STUDIO_URL}/v1/models")
      response = Net::HTTP.get_response(uri)
      if response.is_a?(Net::HTTPSuccess)
        models = JSON.parse(response.body)
        puts "✓ LM Studio is running"
        puts "  Available models: #{models["data"]&.map { |m| m["id"] }&.join(", ") || "unknown"}"
      else
        puts "✗ LM Studio returned: #{response.code}"
        return false
      end
    rescue => e
      puts "✗ Cannot connect to LM Studio at #{LM_STUDIO_URL}: #{e.message}"
      return false
    end

    # Check MCP Server
    begin
      uri = URI("#{MCP_SERVER_URL}/health")
      response = Net::HTTP.get_response(uri)
      if response.is_a?(Net::HTTPSuccess)
        puts "✓ MCP Server is running"
      else
        puts "✗ MCP Server returned: #{response.code}"
        return false
      end
    rescue => e
      puts "✗ Cannot connect to MCP Server at #{MCP_SERVER_URL}: #{e.message}"
      return false
    end

    puts ""
    true
  end
end

# Main execution
if __FILE__ == $0
  evaluator = MCPLMStudioEvaluator.new

  unless evaluator.check_services
    puts "\nPlease ensure both LM Studio and MCP Server are running."
    puts "Start MCP Server with: ruby scripts/start_mcp_server.rb"
    exit 1
  end

  # Default prompt if none provided
  prompt = ARGV[0] || "What tables are in the database? Show me a sample of data from one of them."

  evaluator.evaluate(prompt)
end
