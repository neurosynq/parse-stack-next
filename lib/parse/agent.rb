# encoding: UTF-8
# frozen_string_literal: true

require_relative "agent/metadata_dsl"
require_relative "agent/metadata_registry"
require_relative "agent/tools"
require_relative "agent/constraint_translator"
require_relative "agent/result_formatter"
require_relative "agent/pipeline_validator"
require_relative "agent/rate_limiter"

# Only load MCP server when explicitly enabled
# require_relative "agent/mcp_server"

module Parse
  # The Parse::Agent module provides AI/LLM integration capabilities for Parse Stack.
  # It enables AI agents to interact with Parse data through a standardized tool interface.
  #
  # The agent supports two operational modes:
  # - **Readonly mode**: Query, count, schema, and aggregation operations only
  # - **Write mode**: Full CRUD operations (requires explicit opt-in)
  #
  # @example Basic readonly agent usage
  #   agent = Parse::Agent.new
  #
  #   # Get all schemas
  #   result = agent.execute(:get_all_schemas)
  #
  #   # Query a class
  #   result = agent.execute(:query_class,
  #     class_name: "Song",
  #     where: { plays: { "$gte" => 1000 } },
  #     limit: 10
  #   )
  #
  # @example With session token for ACL-scoped queries
  #   agent = Parse::Agent.new(session_token: user.session_token)
  #   result = agent.execute(:query_class, class_name: "PrivateData")
  #
  # @example MCP Server for external AI agents (requires ENV + code)
  #   # First, set in environment: PARSE_MCP_ENABLED=true
  #   Parse.mcp_server_enabled = true
  #   Parse::Agent.enable_mcp!(port: 3001)
  #
  class Agent
    # Error hierarchy for agent operations
    # Provides granular exception handling for different failure modes.

    # Base error class for all agent errors
    class AgentError < StandardError; end

    # Security-related errors (blocked operations, injection attempts)
    # These should NEVER be swallowed - always re-raise
    class SecurityError < AgentError; end

    # Validation errors for invalid input
    class ValidationError < AgentError; end

    # Timeout errors for long-running operations
    class ToolTimeoutError < AgentError
      attr_reader :tool_name, :timeout

      def initialize(tool_name, timeout)
        @tool_name = tool_name
        @timeout = timeout
        super("Tool '#{tool_name}' timed out after #{timeout} seconds")
      end
    end

    # Global configuration for MCP server feature
    # Must be explicitly enabled before using MCP server
    @mcp_enabled = false

    class << self
      # @!attribute [rw] mcp_enabled
      #   Whether the MCP server feature is enabled.
      #   Must be set to true before requiring 'parse/agent/mcp_server'.
      #   @return [Boolean] true if MCP server is enabled (default: false)
      attr_accessor :mcp_enabled

      # Check if MCP server feature is enabled
      # @return [Boolean]
      def mcp_enabled?
        @mcp_enabled == true
      end

      # Enable MCP server and load the server module
      # @param port [Integer] optional port to configure (default: Parse.mcp_server_port or 3001)
      # @return [Class] the MCPServer class
      # @raise [RuntimeError] if MCP server feature is not enabled via Parse.mcp_server_enabled
      # @note EXPERIMENTAL: MCP server is not fully implemented. You must enable it first:
      #   Parse.mcp_server_enabled = true
      #
      # @example Basic usage
      #   Parse.mcp_server_enabled = true
      #   Parse::Agent.enable_mcp!
      #
      # @example With custom port
      #   Parse.mcp_server_enabled = true
      #   Parse.mcp_server_port = 3002
      #   Parse::Agent.enable_mcp!
      #
      # @example With remote API (OpenAI)
      #   Parse.mcp_server_enabled = true
      #   Parse.configure_mcp_remote_api(
      #     provider: :openai,
      #     api_key: ENV['OPENAI_API_KEY'],
      #     model: 'gpt-4'
      #   )
      #   Parse::Agent.enable_mcp!
      #
      # @example With remote API (Claude)
      #   Parse.mcp_server_enabled = true
      #   Parse.configure_mcp_remote_api(
      #     provider: :claude,
      #     api_key: ENV['ANTHROPIC_API_KEY'],
      #     model: 'claude-3-opus-20240229'
      #   )
      #   Parse::Agent.enable_mcp!
      def enable_mcp!(port: nil)
        env_set = ENV["PARSE_MCP_ENABLED"] == "true"
        prog_set = Parse.instance_variable_get(:@mcp_server_enabled) == true

        unless env_set && prog_set
          error_parts = []
          error_parts << "Set PARSE_MCP_ENABLED=true in environment" unless env_set
          error_parts << "Set Parse.mcp_server_enabled = true in code" unless prog_set

          raise RuntimeError, "MCP server requires both environment and code configuration:\n" \
                "  - #{error_parts.join("\n  - ")}\n" \
                "Then call Parse::Agent.enable_mcp!(port: 3001)"
        end

        # Use provided port, or configured port, or default
        port ||= Parse.mcp_server_port || 3001

        @mcp_enabled = true
        require_relative "agent/mcp_server"
        MCPServer.default_port = port

        # Pass remote API config if available
        if Parse.mcp_remote_api_configured?
          MCPServer.remote_api_config = Parse.mcp_remote_api
        end

        MCPServer
      end

      # Get the current MCP server port
      # @return [Integer] the configured port
      def mcp_port
        Parse.mcp_server_port || 3001
      end

      # Check if remote API is configured for MCP
      # @return [Boolean]
      def mcp_remote_api?
        Parse.mcp_remote_api_configured?
      end
    end

    # Available permission levels
    PERMISSION_LEVELS = {
      readonly: %i[
        get_all_schemas
        get_schema
        query_class
        count_objects
        get_object
        get_sample_objects
        aggregate
        explain_query
        call_method
      ].freeze,
      write: %i[
        create_object
        update_object
      ].freeze,
      admin: %i[
        delete_object
        create_class
        delete_class
      ].freeze,
    }.freeze

    # All readonly tools (default)
    READONLY_TOOLS = PERMISSION_LEVELS[:readonly].freeze

    # Default query limits
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 1000

    # Default rate limiting configuration
    DEFAULT_RATE_LIMIT = 60   # requests per window
    DEFAULT_RATE_WINDOW = 60  # window in seconds

    # Default operation log size (circular buffer)
    DEFAULT_MAX_LOG_SIZE = 1000

    # @return [Symbol] the current permission level (:readonly, :write, or :admin)
    attr_reader :permissions

    # @return [String, nil] the session token for ACL-scoped queries
    attr_reader :session_token

    # @return [Parse::Client] the Parse client instance to use
    attr_reader :client

    # @return [Array<Hash>] log of operations performed in this session
    attr_reader :operation_log

    # @return [RateLimiter] the rate limiter instance
    attr_reader :rate_limiter

    # @return [Integer] the maximum operation log size
    attr_reader :max_log_size

    # @return [Array<Hash>] conversation history for multi-turn interactions
    attr_reader :conversation_history

    # @return [Integer] total prompt tokens used across all requests
    attr_reader :total_prompt_tokens

    # @return [Integer] total completion tokens used across all requests
    attr_reader :total_completion_tokens

    # @return [Integer] total tokens used across all requests
    attr_reader :total_tokens

    # @return [Hash, nil] the last request sent to the LLM
    attr_reader :last_request

    # @return [Hash, nil] the last response received from the LLM
    attr_reader :last_response

    # @return [Hash] pricing configuration for cost estimation (per 1K tokens)
    attr_reader :pricing

    # @return [String, nil] custom system prompt (replaces default)
    attr_reader :custom_system_prompt

    # @return [String, nil] suffix to append to default system prompt
    attr_reader :system_prompt_suffix

    # @return [Hash<Symbol, Array<Proc>>] registered callbacks by event type
    attr_reader :callbacks

    # Default pricing (zero - user should configure)
    DEFAULT_PRICING = { prompt: 0.0, completion: 0.0 }.freeze

    # Create a new Parse Agent instance.
    #
    # @param permissions [Symbol] the permission level (:readonly, :write, or :admin)
    # @param session_token [String, nil] optional session token for ACL-scoped queries
    # @param client [Parse::Client, Symbol] the client instance or connection name
    # @param rate_limit [Integer] maximum requests per window (default: 60)
    # @param rate_window [Integer] rate limit window in seconds (default: 60)
    # @param max_log_size [Integer] maximum operation log entries (default: 1000, uses circular buffer)
    # @param system_prompt [String, nil] custom system prompt (replaces default)
    # @param system_prompt_suffix [String, nil] suffix to append to default system prompt
    # @param pricing [Hash, nil] pricing per 1K tokens { prompt: rate, completion: rate }
    #
    # @example Readonly agent with master key
    #   agent = Parse::Agent.new
    #
    # @example Agent with user session
    #   agent = Parse::Agent.new(session_token: "r:abc123...")
    #
    # @example Agent with custom rate limiting
    #   agent = Parse::Agent.new(rate_limit: 100, rate_window: 60)
    #
    # @example Agent with larger operation log
    #   agent = Parse::Agent.new(max_log_size: 5000)
    #
    # @example Agent with custom system prompt
    #   agent = Parse::Agent.new(system_prompt: "You are a music database expert...")
    #
    # @example Agent with system prompt suffix
    #   agent = Parse::Agent.new(system_prompt_suffix: "Focus on performance data.")
    #
    # @example Agent with cost tracking
    #   agent = Parse::Agent.new(pricing: { prompt: 0.01, completion: 0.03 })
    #   agent.ask("How many users?")
    #   puts agent.estimated_cost  # => 0.0234
    #
    def initialize(permissions: :readonly, session_token: nil, client: :default,
                   rate_limit: DEFAULT_RATE_LIMIT, rate_window: DEFAULT_RATE_WINDOW,
                   max_log_size: DEFAULT_MAX_LOG_SIZE,
                   system_prompt: nil, system_prompt_suffix: nil, pricing: nil)
      @permissions = permissions
      @session_token = session_token
      @client = client.is_a?(Parse::Client) ? client : Parse::Client.client(client)
      @operation_log = []
      @max_log_size = max_log_size
      @rate_limiter = RateLimiter.new(limit: rate_limit, window: rate_window)
      @conversation_history = []
      @total_prompt_tokens = 0
      @total_completion_tokens = 0
      @total_tokens = 0

      # New features
      @last_request = nil
      @last_response = nil
      @custom_system_prompt = system_prompt
      @system_prompt_suffix = system_prompt_suffix
      @pricing = pricing || DEFAULT_PRICING.dup
      @callbacks = {
        before_tool_call: [],
        after_tool_call: [],
        on_error: [],
        on_llm_response: [],
      }
    end

    # Check if a tool is allowed under current permissions
    #
    # @param tool_name [Symbol] the name of the tool to check
    # @return [Boolean] true if the tool is allowed
    def tool_allowed?(tool_name)
      allowed_tools.include?(tool_name.to_sym)
    end

    # Get the list of tools allowed under current permissions
    #
    # @return [Array<Symbol>] list of allowed tool names
    def allowed_tools
      case @permissions
      when :readonly
        PERMISSION_LEVELS[:readonly]
      when :write
        PERMISSION_LEVELS[:readonly] + PERMISSION_LEVELS[:write]
      when :admin
        PERMISSION_LEVELS[:readonly] + PERMISSION_LEVELS[:write] + PERMISSION_LEVELS[:admin]
      else
        PERMISSION_LEVELS[:readonly]
      end
    end

    # Execute a tool by name with the given arguments.
    #
    # Implements granular exception handling:
    # - Security errors are re-raised (never swallowed)
    # - Rate limit errors include retry_after metadata
    # - Validation and Parse errors return structured error responses
    # - Unexpected errors are logged with stack traces
    #
    # @param tool_name [Symbol, String] the name of the tool to execute
    # @param kwargs [Hash] the arguments to pass to the tool
    # @return [Hash] the result of the tool execution with :success and :data or :error keys
    #
    # @example Query a class
    #   result = agent.execute(:query_class, class_name: "Song", limit: 10)
    #   if result[:success]
    #     puts result[:data][:results]
    #   else
    #     puts result[:error]
    #   end
    #
    # @raise [PipelineValidator::PipelineSecurityError] for blocked aggregation stages
    # @raise [ConstraintTranslator::ConstraintSecurityError] for blocked query operators
    #
    def execute(tool_name, **kwargs)
      tool_name = tool_name.to_sym

      # Check rate limit FIRST - before any processing
      @rate_limiter.check!

      unless tool_allowed?(tool_name)
        return error_response(
                 "Permission denied: '#{tool_name}' requires #{required_permission_for(tool_name)} permissions. " \
                 "Current level: #{@permissions}",
                 error_code: :permission_denied,
               )
      end

      # Trigger before_tool_call callbacks
      trigger_callbacks(:before_tool_call, tool_name, kwargs)

      begin
        result = Parse::Agent::Tools.send(tool_name, self, **kwargs)
        log_operation(tool_name, kwargs, result)
        response = success_response(result)

        # Trigger after_tool_call callbacks
        trigger_callbacks(:after_tool_call, tool_name, kwargs, response)

        response

        # Security errors - NEVER swallow, always re-raise
      rescue PipelineValidator::PipelineSecurityError,
             ConstraintTranslator::ConstraintSecurityError => e
        log_security_event(tool_name, kwargs, e)
        trigger_callbacks(:on_error, e, { tool: tool_name, args: kwargs })
        raise  # Re-raise security errors to caller

        # Validation errors - return structured error response
      rescue ConstraintTranslator::InvalidOperatorError => e
        trigger_callbacks(:on_error, e, { tool: tool_name, args: kwargs })
        error_response(e.message, error_code: :invalid_query)

        # Timeout errors
      rescue ToolTimeoutError => e
        trigger_callbacks(:on_error, e, { tool: tool_name, args: kwargs })
        error_response(e.message, error_code: :timeout)

        # Rate limit errors (should be caught above, but handle just in case)
      rescue RateLimiter::RateLimitExceeded => e
        trigger_callbacks(:on_error, e, { tool: tool_name, args: kwargs })
        error_response(e.message, error_code: :rate_limited, retry_after: e.retry_after)

        # Invalid arguments
      rescue ArgumentError => e
        trigger_callbacks(:on_error, e, { tool: tool_name, args: kwargs })
        error_response("Invalid arguments: #{e.message}", error_code: :invalid_argument)

        # Parse API errors
      rescue Parse::Error => e
        trigger_callbacks(:on_error, e, { tool: tool_name, args: kwargs })
        error_response("Parse error: #{e.message}", error_code: :parse_error)

        # Unexpected errors - log with stack trace for debugging
      rescue StandardError => e
        warn "[Parse::Agent] Unexpected error in #{tool_name}: #{e.class} - #{e.message}"
        warn e.backtrace.first(5).join("\n") if e.backtrace
        trigger_callbacks(:on_error, e, { tool: tool_name, args: kwargs })
        error_response("#{tool_name} failed: #{e.message}", error_code: :internal_error)
      end
    end

    # Get tool definitions in MCP/OpenAI function calling format
    #
    # @param format [Symbol] the output format (:mcp or :openai)
    # @return [Array<Hash>] array of tool definitions
    def tool_definitions(format: :openai)
      Parse::Agent::Tools.definitions(allowed_tools, format: format)
    end

    # Request options hash for Parse API calls
    # @return [Hash] options to pass to client requests
    # @api private
    def request_opts
      opts = {}
      if @session_token
        opts[:session_token] = @session_token
        opts[:use_master_key] = false
      end
      opts
    end

    # Ask the agent a natural language question and get a response.
    # Requires an LLM API endpoint to be configured.
    #
    # @param prompt [String] the natural language question to ask
    # @param continue_conversation [Boolean] whether to include conversation history
    # @param llm_endpoint [String] OpenAI-compatible API endpoint (default: LM Studio)
    # @param model [String] the model to use
    # @param max_iterations [Integer] maximum tool call iterations (default: 10)
    # @return [Hash] response with :answer and :tool_calls keys
    #
    # @example Ask about database structure
    #   agent = Parse::Agent.new
    #   result = agent.ask("How many users are in the database?")
    #   puts result[:answer]
    #
    # @example With custom endpoint
    #   result = agent.ask("Find songs with over 1000 plays",
    #     llm_endpoint: "http://localhost:1234/v1",
    #     model: "qwen2.5-7b-instruct")
    #
    # @example Multi-turn conversation
    #   agent = Parse::Agent.new
    #   agent.ask("How many users are there?")
    #   agent.ask_followup("What about in the last week?")
    #   agent.clear_conversation!  # Start fresh
    #
    def ask(prompt, continue_conversation: false, llm_endpoint: nil, model: nil, max_iterations: 10)
      require "net/http"
      require "json"

      # Clear history if not continuing conversation
      @conversation_history = [] unless continue_conversation

      endpoint = llm_endpoint || ENV["LLM_ENDPOINT"] || "http://127.0.0.1:1234/v1"
      model_name = model || ENV["LLM_MODEL"] || "default"

      # Build messages with system prompt, conversation history, and new prompt
      messages = [{ role: "system", content: computed_system_prompt }]
      messages += @conversation_history
      messages << { role: "user", content: prompt }

      # Store last request
      @last_request = {
        messages: messages.dup,
        model: model_name,
        endpoint: endpoint,
        streaming: false,
      }

      tool_calls_made = []

      max_iterations.times do |iteration|
        response = chat_completion(endpoint, model_name, messages)

        if response[:error]
          trigger_callbacks(:on_error, StandardError.new(response[:error]), { source: :llm })
          return { answer: nil, error: response[:error], tool_calls: tool_calls_made }
        end

        # Trigger on_llm_response callback
        trigger_callbacks(:on_llm_response, response)

        # Accumulate token usage
        if response[:usage]
          @total_prompt_tokens += response[:usage][:prompt_tokens]
          @total_completion_tokens += response[:usage][:completion_tokens]
          @total_tokens += response[:usage][:total_tokens]
        end

        message = response[:message]
        tool_calls = message["tool_calls"]

        # If no tool calls, we have the final answer
        unless tool_calls&.any?
          answer = message["content"]

          # Store last response
          @last_response = response.merge(answer: answer)

          # Save successful exchange to conversation history
          @conversation_history << { role: "user", content: prompt }
          @conversation_history << { role: "assistant", content: answer }

          return {
                   answer: answer,
                   tool_calls: tool_calls_made,
                 }
        end

        # Process tool calls
        messages << message
        tool_calls.each do |tool_call|
          function = tool_call&.dig("function")
          next unless function # Skip malformed tool calls

          tool_name = function["name"]
          next unless tool_name # Skip if no tool name

          args = JSON.parse(function["arguments"] || "{}")

          # Execute the tool
          result = execute(tool_name.to_sym, **args.transform_keys(&:to_sym))
          tool_calls_made << { tool: tool_name, args: args, success: result[:success] }

          # Add tool result to messages
          messages << {
            role: "tool",
            tool_call_id: tool_call["id"],
            content: JSON.generate(result),
          }
        end
      end

      { answer: nil, error: "Max iterations reached", tool_calls: tool_calls_made }
    end

    # Ask a follow-up question in the current conversation.
    # Convenience method that calls ask with continue_conversation: true.
    #
    # @param prompt [String] the follow-up question
    # @param kwargs [Hash] additional arguments passed to ask
    # @return [Hash] response with :answer and :tool_calls keys
    #
    # @example
    #   agent.ask("How many users are there?")
    #   agent.ask_followup("What about admins?")
    #   agent.ask_followup("Show me the most recent ones")
    #
    def ask_followup(prompt, **kwargs)
      ask(prompt, continue_conversation: true, **kwargs)
    end

    # Clear the conversation history to start a fresh conversation.
    #
    # @return [Array] empty array
    #
    # @example
    #   agent.ask("How many users?")
    #   agent.ask_followup("What about admins?")
    #   agent.clear_conversation!  # Start fresh
    #   agent.ask("Different topic...")
    #
    def clear_conversation!
      @conversation_history = []
    end

    # Reset token usage counters to zero.
    #
    # @return [Hash] zeroed token counts
    #
    # @example
    #   agent.ask("How many users?")
    #   puts agent.token_usage  # => { prompt_tokens: 150, completion_tokens: 50, total_tokens: 200 }
    #   agent.reset_token_counts!
    #   puts agent.total_tokens  # => 0
    #
    def reset_token_counts!
      @total_prompt_tokens = 0
      @total_completion_tokens = 0
      @total_tokens = 0
      token_usage
    end

    # Get a summary of token usage.
    #
    # @return [Hash] token usage summary with prompt, completion, and total tokens
    #
    # @example
    #   agent.ask("How many users?")
    #   agent.ask_followup("What about admins?")
    #   puts agent.token_usage
    #   # => { prompt_tokens: 300, completion_tokens: 100, total_tokens: 400 }
    #
    def token_usage
      {
        prompt_tokens: @total_prompt_tokens,
        completion_tokens: @total_completion_tokens,
        total_tokens: @total_tokens,
      }
    end

    # ===== Callback/Hooks System =====

    # Register a callback to be invoked before each tool call.
    #
    # @yield [tool_name, args] called before executing each tool
    # @yieldparam tool_name [Symbol] the name of the tool being called
    # @yieldparam args [Hash] the arguments passed to the tool
    # @return [self] for chaining
    #
    # @example
    #   agent.on_tool_call { |tool, args| puts "Calling: #{tool}" }
    #
    def on_tool_call(&block)
      @callbacks[:before_tool_call] << block if block_given?
      self
    end

    # Register a callback to be invoked after each tool call completes.
    #
    # @yield [tool_name, args, result] called after tool execution
    # @yieldparam tool_name [Symbol] the name of the tool that was called
    # @yieldparam args [Hash] the arguments passed to the tool
    # @yieldparam result [Hash] the tool execution result
    # @return [self] for chaining
    #
    # @example
    #   agent.on_tool_result { |tool, args, result| log_result(tool, result) }
    #
    def on_tool_result(&block)
      @callbacks[:after_tool_call] << block if block_given?
      self
    end

    # Register a callback to be invoked when an error occurs.
    #
    # @yield [error, context] called when an error occurs
    # @yieldparam error [Exception] the error that occurred
    # @yieldparam context [Hash] context about where the error occurred
    # @return [self] for chaining
    #
    # @example
    #   agent.on_error { |error, ctx| notify_slack(error) }
    #
    def on_error(&block)
      @callbacks[:on_error] << block if block_given?
      self
    end

    # Register a callback to be invoked after each LLM response.
    #
    # @yield [response] called after receiving LLM response
    # @yieldparam response [Hash] the parsed LLM response
    # @return [self] for chaining
    #
    # @example
    #   agent.on_llm_response { |resp| log_llm_usage(resp) }
    #
    def on_llm_response(&block)
      @callbacks[:on_llm_response] << block if block_given?
      self
    end

    # ===== Cost Estimation =====

    # Configure pricing for cost estimation.
    #
    # @param prompt [Float] cost per 1K prompt tokens
    # @param completion [Float] cost per 1K completion tokens
    # @return [Hash] the updated pricing configuration
    #
    # @example
    #   agent.configure_pricing(prompt: 0.01, completion: 0.03)
    #
    def configure_pricing(prompt:, completion:)
      @pricing = { prompt: prompt, completion: completion }
    end

    # Calculate the estimated cost based on token usage and configured pricing.
    #
    # @return [Float] estimated cost in configured currency units
    #
    # @example
    #   agent = Parse::Agent.new(pricing: { prompt: 0.01, completion: 0.03 })
    #   agent.ask("How many users?")
    #   puts agent.estimated_cost  # => 0.0234
    #
    def estimated_cost
      (@total_prompt_tokens / 1000.0 * @pricing[:prompt]) +
        (@total_completion_tokens / 1000.0 * @pricing[:completion])
    end

    # ===== Conversation Export/Import =====

    # Export the current conversation state for later restoration.
    # Includes conversation history, token usage, and permissions.
    #
    # @return [String] JSON string of conversation state
    #
    # @example
    #   state = agent.export_conversation
    #   File.write("conversation.json", state)
    #   # Later...
    #   agent.import_conversation(File.read("conversation.json"))
    #
    def export_conversation
      JSON.generate({
        conversation_history: @conversation_history,
        token_usage: token_usage,
        permissions: @permissions,
        exported_at: Time.now.iso8601,
      })
    end

    # Import a previously exported conversation state.
    # Restores conversation history, token usage, and optionally permissions.
    #
    # @param json_string [String] JSON string from export_conversation
    # @param restore_permissions [Boolean] whether to restore permissions (default: false)
    # @return [Boolean] true if import succeeded
    #
    # @example
    #   agent.import_conversation(saved_state)
    #   agent.ask_followup("Continue from where we left off")
    #
    def import_conversation(json_string, restore_permissions: false)
      require "json"
      data = JSON.parse(json_string, symbolize_names: true)

      @conversation_history = data[:conversation_history] || []
      if data[:token_usage]
        @total_prompt_tokens = data[:token_usage][:prompt_tokens] || 0
        @total_completion_tokens = data[:token_usage][:completion_tokens] || 0
        @total_tokens = data[:token_usage][:total_tokens] || 0
      end

      @permissions = data[:permissions].to_sym if restore_permissions && data[:permissions]

      true
    rescue JSON::ParserError => e
      warn "[Parse::Agent] Failed to import conversation: #{e.message}"
      false
    end

    # ===== Streaming Support =====

    # Ask a question with streaming response.
    # Yields chunks of the response as they arrive.
    #
    # @note **Important Limitation:** Streaming mode does NOT support tool calls.
    #   The agent cannot query the database, call cloud functions, or perform any
    #   Parse operations while streaming. Use this for text generation based on
    #   prior context, reformatting data, or general conversation. For database
    #   queries or Parse operations, use {#ask} instead.
    #
    # @param prompt [String] the natural language question to ask
    # @param continue_conversation [Boolean] whether to include conversation history
    # @param llm_endpoint [String] OpenAI-compatible API endpoint
    # @param model [String] the model to use
    # @yield [chunk] called for each chunk of the response
    # @yieldparam chunk [String] a chunk of text from the response
    # @return [Hash] final response with :answer and :tool_calls (always empty)
    #
    # @example Stream response to console
    #   agent.ask_streaming("Analyze user growth") do |chunk|
    #     print chunk
    #   end
    #
    # @example Stream response to WebSocket
    #   agent.ask_streaming("Summary of recent activity") do |chunk|
    #     websocket.send(chunk)
    #   end
    #
    # @example When NOT to use streaming (use ask instead)
    #   # DON'T: This won't query the database
    #   agent.ask_streaming("How many users?") { |c| print c }
    #
    #   # DO: Use ask for database queries
    #   result = agent.ask("How many users?")
    #
    def ask_streaming(prompt, continue_conversation: false, llm_endpoint: nil, model: nil, &block)
      raise ArgumentError, "Block required for streaming" unless block_given?

      require "net/http"
      require "json"

      # Clear history if not continuing conversation
      @conversation_history = [] unless continue_conversation

      endpoint = llm_endpoint || ENV["LLM_ENDPOINT"] || "http://127.0.0.1:1234/v1"
      model_name = model || ENV["LLM_MODEL"] || "default"

      # Build messages
      messages = [{ role: "system", content: computed_system_prompt }]
      messages += @conversation_history
      messages << { role: "user", content: prompt }

      # Store last request
      @last_request = {
        messages: messages.dup,
        model: model_name,
        endpoint: endpoint,
        streaming: true,
      }

      # Make streaming request
      full_response = stream_chat_completion(endpoint, model_name, messages, &block)

      # Store last response
      @last_response = full_response.merge(answer: full_response[:content])

      # Save to conversation history
      if full_response[:content]
        @conversation_history << { role: "user", content: prompt }
        @conversation_history << { role: "assistant", content: full_response[:content] }
      end

      {
        answer: full_response[:content],
        tool_calls: [],  # Streaming mode doesn't support tool calls currently
        error: full_response[:error],
      }
    end

    private

    # Compute the effective system prompt based on configuration.
    # Uses custom_system_prompt if set, otherwise default with optional suffix.
    # @return [String] the system prompt to use
    def computed_system_prompt
      return @custom_system_prompt if @custom_system_prompt

      base = default_system_prompt
      @system_prompt_suffix ? "#{base}\n#{@system_prompt_suffix}" : base
    end

    # Alias for backward compatibility
    alias_method :system_prompt, :computed_system_prompt

    # Default system prompt - optimized for token efficiency
    def default_system_prompt
      <<~PROMPT
        Parse database assistant. Tools: get_all_schemas (list classes), get_schema (class fields), query_class (find objects), count_objects, get_object (by ID), aggregate (analytics), call_method (model methods). Use get_all_schemas first. Be concise.
      PROMPT
    end

    # Make a chat completion request to the LLM
    def chat_completion(endpoint, model, messages)
      uri = URI("#{endpoint}/chat/completions")
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 120

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"

      body = {
        model: model,
        messages: messages,
        tools: tool_definitions.map { |t| { type: "function", function: t[:function] } },
        tool_choice: "auto",
        temperature: 0.1,
      }

      request.body = JSON.generate(body)

      begin
        response = http.request(request)
        data = JSON.parse(response.body)

        if data["error"]
          { error: data["error"]["message"] }
        else
          # Extract usage info if available (OpenAI-compatible format)
          usage = data["usage"] || {}
          {
            message: data["choices"][0]["message"],
            usage: {
              prompt_tokens: usage["prompt_tokens"] || 0,
              completion_tokens: usage["completion_tokens"] || 0,
              total_tokens: usage["total_tokens"] || 0,
            },
          }
        end
      rescue StandardError => e
        { error: e.message }
      end
    end

    # Make a streaming chat completion request to the LLM
    # @param endpoint [String] the API endpoint
    # @param model [String] the model name
    # @param messages [Array] the message history
    # @yield [chunk] called for each text chunk
    # @return [Hash] final response with content and error
    def stream_chat_completion(endpoint, model, messages, &block)
      uri = URI("#{endpoint}/chat/completions")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.read_timeout = 120

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "text/event-stream"

      body = {
        model: model,
        messages: messages,
        stream: true,
        temperature: 0.1,
      }

      request.body = JSON.generate(body)

      full_content = ""
      error = nil

      begin
        http.request(request) do |response|
          unless response.is_a?(Net::HTTPSuccess)
            error = "HTTP #{response.code}: #{response.message}"
            break
          end

          buffer = ""
          response.read_body do |chunk|
            buffer += chunk
            # Process complete SSE events
            while (line_end = buffer.index("\n"))
              line = buffer.slice!(0, line_end + 1).strip
              next if line.empty?

              if line.start_with?("data: ")
                data = line[6..]
                next if data == "[DONE]"

                begin
                  parsed = JSON.parse(data)
                  delta = parsed.dig("choices", 0, "delta", "content")
                  if delta
                    full_content += delta
                    block.call(delta)
                  end

                  # Check for finish reason
                  if parsed.dig("choices", 0, "finish_reason")
                    # Trigger on_llm_response callback
                    trigger_callbacks(:on_llm_response, { content: full_content, streaming: true })
                  end
                rescue JSON::ParserError
                  # Skip malformed JSON chunks
                end
              end
            end
          end
        end
      rescue StandardError => e
        error = e.message
        trigger_callbacks(:on_error, e, { source: :streaming, content_so_far: full_content })
      end

      { content: full_content, error: error }
    end

    # Trigger registered callbacks for an event
    # @param event [Symbol] the event type
    # @param args [Array] arguments to pass to callbacks
    def trigger_callbacks(event, *args)
      return unless @callbacks&.key?(event)

      @callbacks[event].each do |callback|
        begin
          callback.call(*args)
        rescue StandardError => e
          warn "[Parse::Agent] Callback error for #{event}: #{e.message}"
        end
      end
    end

    def required_permission_for(tool_name)
      PERMISSION_LEVELS.each do |level, tools|
        return level if tools.include?(tool_name)
      end
      :unknown
    end

    # Get the current authentication context
    # @return [Hash] auth type and master key usage info
    def auth_context
      @auth_context ||= if @session_token
          { type: :session_token, using_master_key: false }
        else
          { type: :master_key, using_master_key: true }
        end
    end

    # Keys that should never be logged for security reasons
    SENSITIVE_LOG_KEYS = %i[
      where pipeline session_token password secret token
      auth_data authData recovery_codes api_key master_key
    ].freeze

    def log_operation(tool_name, args, result)
      # Sanitize args by removing sensitive data
      sanitized_args = args.except(*SENSITIVE_LOG_KEYS)

      entry = {
        tool: tool_name,
        args: sanitized_args,
        timestamp: Time.now.iso8601,
        success: true,
        auth_type: auth_context[:type],
        using_master_key: auth_context[:using_master_key],
        permissions: @permissions,
      }
      append_log(entry)

      # Audit log master key usage
      if auth_context[:using_master_key]
        warn "[Parse::Agent:AUDIT] Master key operation: #{tool_name} at #{Time.now.iso8601}"
      end
    end

    # Log security events (blocked operations, injection attempts)
    # @param tool_name [Symbol] the tool that was called
    # @param args [Hash] the arguments passed
    # @param error [Exception] the security error
    def log_security_event(tool_name, args, error)
      entry = {
        type: :security_violation,
        tool: tool_name,
        error_class: error.class.name,
        error_message: error.message,
        timestamp: Time.now.iso8601,
        auth_type: auth_context[:type],
        permissions: @permissions,
      }

      # Add specific info based on error type
      case error
      when PipelineValidator::PipelineSecurityError
        entry[:stage] = error.stage if error.respond_to?(:stage)
        entry[:reason] = error.reason if error.respond_to?(:reason)
      when ConstraintTranslator::ConstraintSecurityError
        entry[:operator] = error.operator if error.respond_to?(:operator)
        entry[:reason] = error.reason if error.respond_to?(:reason)
      end

      append_log(entry)

      # Always warn on security events
      warn "[Parse::Agent:SECURITY] #{error.class.name}: #{error.message}"
      warn "[Parse::Agent:SECURITY] Tool: #{tool_name}, Auth: #{auth_context[:type]}"
    end

    def success_response(data)
      { success: true, data: data }
    end

    # Append an entry to the operation log with circular buffer enforcement
    # @param entry [Hash] the log entry to append
    def append_log(entry)
      @operation_log << entry
      @operation_log.shift if @operation_log.size > @max_log_size
    end

    def error_response(message, error_code: nil, retry_after: nil)
      entry = {
        error: message,
        error_code: error_code,
        timestamp: Time.now.iso8601,
        success: false,
      }
      append_log(entry)

      response = { success: false, error: message }
      response[:error_code] = error_code if error_code
      response[:retry_after] = retry_after if retry_after
      response
    end
  end
end

# Include the MetadataDSL in Parse::Object to enable agent metadata for all models.
# This adds class methods: agent_description, agent_method, agent_readonly, agent_write, agent_admin
# And instance methods: agent_description, property_descriptions, agent_methods
Parse::Object.include(Parse::Agent::MetadataDSL) if defined?(Parse::Object)
