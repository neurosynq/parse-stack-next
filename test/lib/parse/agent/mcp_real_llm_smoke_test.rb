# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"
require "parse/agent/mcp_dispatcher"
require "net/http"
require "json"
require "uri"
require "stringio"
require "securerandom"

# ============================================================================
# Real-LLM smoke test for the MCP server.
#
# Boots a local MCPServer in-process (no Docker; Parse::Agent#execute is
# stubbed to return canned data so no Parse Server is required), then asks
# a real LLM to invoke a tool. Verifies the model:
#   - Received our tools/list correctly
#   - Picked the right tool for the prompt
#   - Got the result back in a form it can describe
#
# This is a smoke test, not a coverage test. It catches "the wire format is
# wrong and the model gives up" regressions that protocol-level tests miss
# because they don't exercise an actual LLM's tool-call decoder.
#
# Skipped by default. Run by setting:
#   - LLM_PROVIDER (lmstudio | openai | anthropic)
#   - LLM_API_KEY  (required for openai/anthropic; ignored for lmstudio)
#   - LLM_BASE_URL (optional override; defaults match each provider)
#   - LLM_MODEL    (optional override; sensible defaults per provider)
#
# Example invocations:
#
#   # Free, local — LM Studio with Qwen2.5-7B-instruct loaded:
#   LLM_PROVIDER=lmstudio bundle exec ruby -Ilib:test \
#     test/lib/parse/agent/mcp_real_llm_smoke_test.rb
#
#   # ~$0.01 per run — OpenAI gpt-4o-mini:
#   LLM_PROVIDER=openai LLM_API_KEY=sk-... bundle exec ruby -Ilib:test \
#     test/lib/parse/agent/mcp_real_llm_smoke_test.rb
#
#   # ~$0.01 per run — Anthropic Claude Haiku:
#   LLM_PROVIDER=anthropic LLM_API_KEY=sk-ant-... bundle exec ruby \
#     -Ilib:test test/lib/parse/agent/mcp_real_llm_smoke_test.rb
#
# Architecture: the test wires our MCP tools into the LLM via its native
# function-calling API (no MCP transport involved on the LLM side). The LLM
# decides to call a tool, we receive the call, dispatch it through our real
# MCPDispatcher (with a stubbed Agent), serialize the result, and feed it
# back. This validates the schema/contract our `tools/list` exposes is
# actually usable by a real model.
# ============================================================================
class MCPRealLLMSmokeTest < Minitest::Test
  def setup
    unless ENV["LLM_PROVIDER"]
      skip "Set LLM_PROVIDER (lmstudio | openai | anthropic) to run the real-LLM smoke test"
    end

    @provider = ENV["LLM_PROVIDER"]
    case @provider
    when "lmstudio"
      @base_url = ENV["LLM_BASE_URL"] || "http://localhost:1234/v1"
      @model    = ENV["LLM_MODEL"]    || "qwen2.5-7b-instruct"
      @api_key  = ENV["LLM_API_KEY"]  || "lm-studio"  # LM Studio ignores
    when "openai"
      skip "openai requires LLM_API_KEY" unless ENV["LLM_API_KEY"]
      @base_url = ENV["LLM_BASE_URL"] || "https://api.openai.com/v1"
      @model    = ENV["LLM_MODEL"]    || "gpt-4o-mini"
      @api_key  = ENV["LLM_API_KEY"]
    when "anthropic"
      skip "anthropic requires LLM_API_KEY" unless ENV["LLM_API_KEY"]
      @base_url = ENV["LLM_BASE_URL"] || "https://api.anthropic.com/v1"
      @model    = ENV["LLM_MODEL"]    || "claude-haiku-4-5"
      @api_key  = ENV["LLM_API_KEY"]
    else
      skip "Unknown LLM_PROVIDER=#{@provider.inspect} (expected lmstudio | openai | anthropic)"
    end

    Parse.setup(
      server_url:     "http://localhost:1337/parse",
      application_id: "smoke-test",
      api_key:        "smoke-test",
    ) unless Parse::Client.client?

    @agent = stub_agent_with_canned_data
  end

  def test_model_invokes_get_all_schemas_when_asked_to_list_classes
    tools_list = mcp_call({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => {} })
    refute_nil tools_list.dig("result", "tools"), "tools/list must return tool definitions"

    openai_tools = mcp_tools_to_openai(tools_list["result"]["tools"])
    prompt = "Use the get_all_schemas tool to list every Parse class in the database. " \
             "Then summarize the class names in one short sentence."

    transcript = llm_round_trip(prompt: prompt, tools: openai_tools, max_iterations: 4)
    flat = transcript.map { |m| m[:content].to_s }.join(" ")

    tool_call_names = transcript.flat_map { |m| Array(m[:tool_calls]).map { |tc| tc[:name] } }
    assert_includes tool_call_names, "get_all_schemas",
                    "model must invoke get_all_schemas; got tool calls: #{tool_call_names.inspect}"

    final = transcript.reverse.find { |m| m[:role] == "assistant" && (m[:content] || "").length.positive? }
    refute_nil final, "model must produce a final assistant message"
    assert_match(/Song|MCPE2EItem|_User|_Role/, flat,
                 "model's summary should reference at least one canned class name")
  end

  private

  # --- in-process MCP dispatch -----------------------------------------------

  # Build a Parse::Agent whose tool dispatch returns canned data so we don't
  # need a live Parse Server. The MCP envelope, the tool schemas, and the
  # serialization path are all REAL — only the data source is stubbed.
  def stub_agent_with_canned_data
    agent = Parse::Agent.new(permissions: :readonly)
    agent.define_singleton_method(:execute) do |tool_name, **kwargs|
      case tool_name
      when :get_all_schemas
        {
          success: true,
          data: {
            total: 3,
            classes: [
              { name: "Song",        type: "Custom", description: "Music tracks" },
              { name: "MCPE2EItem",  type: "Custom", description: "Smoke fixture" },
              { name: "_User",       type: "System", description: "Auth users"   },
            ],
          },
        }
      when :get_schema
        { success: true, data: { className: kwargs[:class_name], fields: { name: "String" } } }
      when :count_objects
        { success: true, data: { count: 42, class_name: kwargs[:class_name] } }
      when :query_class
        { success: true, data: { results: [{ "objectId" => "abc123", "name" => "sample" }], count: 1 } }
      else
        { success: true, data: { tool: tool_name.to_s, args: kwargs } }
      end
    end
    agent
  end

  def mcp_call(body)
    response = Parse::Agent::MCPDispatcher.call(body: body, agent: @agent)
    response[:body]
  end

  # --- MCP -> OpenAI tools translation ---------------------------------------

  # The OpenAI function-calling schema is { type: "function", function: { name, description, parameters } }.
  # Anthropic accepts essentially the same shape on the messages API too.
  # LM Studio (OpenAI-compatible) uses the OpenAI form.
  def mcp_tools_to_openai(tools)
    tools.map do |t|
      # MCPDispatcher returns symbol-keyed tool descriptors in-process; on
      # the JSON-RPC wire they're stringified by JSON.generate. We read both
      # forms so the translator works whether tools came from MCPDispatcher
      # directly (symbols) or were round-tripped through JSON (strings).
      h = t.transform_keys(&:to_s)
      {
        type: "function",
        function: {
          name:        h["name"],
          description: h["description"].to_s[0, 1024],
          parameters:  h["inputSchema"] || { "type" => "object", "properties" => {} },
        },
      }
    end
  end

  # --- LLM round-trip --------------------------------------------------------

  # Drive the model through up to `max_iterations` turns of tool calling. Each
  # tool call is fed back into the conversation via a `role: "tool"` message
  # containing the dispatched result (so the model can synthesize a reply).
  def llm_round_trip(prompt:, tools:, max_iterations: 4)
    messages = [{ role: "user", content: prompt }]
    transcript = []

    max_iterations.times do
      reply = call_llm(messages: messages, tools: tools)
      transcript << reply
      messages << { role: "assistant", content: reply[:content], tool_calls: reply[:tool_calls] }

      break if reply[:tool_calls].nil? || reply[:tool_calls].empty?

      reply[:tool_calls].each do |tc|
        body = {
          "jsonrpc" => "2.0",
          "id"      => SecureRandom.hex(4),
          "method"  => "tools/call",
          "params"  => { "name" => tc[:name], "arguments" => tc[:arguments] },
        }
        result = mcp_call(body)
        tool_text = if result["result"]
          (result.dig("result", "content", 0, "text") || result["result"].to_json)
        else
          result.dig("error", "message").to_s
        end
        messages << {
          role:         "tool",
          tool_call_id: tc[:id],
          content:      tool_text,
        }
      end
    end

    transcript
  end

  # Provider-agnostic chat completion. Returns
  #   { role:, content:, tool_calls: [{ id:, name:, arguments: {} }, ...] }.
  def call_llm(messages:, tools:)
    case @provider
    when "anthropic" then anthropic_chat(messages: messages, tools: tools)
    else                  openai_chat(messages: messages, tools: tools)
    end
  end

  def openai_chat(messages:, tools:)
    # Translate the test-internal message shape to OpenAI's chat-completion
    # wire shape. The internal assistant-with-tool-calls shape uses
    # `tool_calls: [{id:, name:, arguments:}]`; OpenAI requires
    # `tool_calls: [{id:, type: "function", function: {name:, arguments: <JSON-string>}}]`.
    openai_messages = messages.map do |m|
      case m[:role]
      when "user", "system"
        { role: m[:role], content: m[:content].to_s }
      when "assistant"
        out = { role: "assistant", content: m[:content] }
        if m[:tool_calls] && !m[:tool_calls].empty?
          out[:tool_calls] = m[:tool_calls].map do |tc|
            args = tc[:arguments]
            args_str = args.is_a?(String) ? args : JSON.generate(args || {})
            { id: tc[:id], type: "function", function: { name: tc[:name], arguments: args_str } }
          end
        end
        out
      when "tool"
        { role: "tool", tool_call_id: m[:tool_call_id], content: m[:content].to_s }
      end
    end.compact

    uri = URI("#{@base_url}/chat/completions")
    body = JSON.generate({
      model:       @model,
      messages:    openai_messages,
      tools:       tools,
      tool_choice: "auto",
    })

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"]   = "application/json"
    req["Authorization"]  = "Bearer #{@api_key}"
    req.body = body

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: 60) { |h| h.request(req) }
    skip "LLM call failed: HTTP #{res.code} #{res.body}" unless res.code.to_i.between?(200, 299)

    parsed = JSON.parse(res.body)
    msg    = parsed.dig("choices", 0, "message") || {}
    calls  = Array(msg["tool_calls"]).map do |tc|
      args = tc.dig("function", "arguments")
      args = JSON.parse(args) if args.is_a?(String) && !args.empty?
      {
        id:        tc["id"] || SecureRandom.hex(4),
        name:      tc.dig("function", "name"),
        arguments: args || {},
      }
    end
    { role: "assistant", content: msg["content"], tool_calls: calls }
  end

  def anthropic_chat(messages:, tools:)
    # Anthropic accepts a slightly different shape: tools at top level, tool_use
    # blocks inside the response content array. Translate both directions.
    anth_tools = tools.map { |t| { name: t[:function][:name], description: t[:function][:description], input_schema: t[:function][:parameters] } }
    anth_messages = messages.map { |m|
      case m[:role]
      when "user", "assistant" then { role: m[:role], content: m[:content].to_s }
      when "tool"              then { role: "user",   content: [{ type: "tool_result", tool_use_id: m[:tool_call_id], content: m[:content] }] }
      end
    }.compact

    uri = URI("#{@base_url}/messages")
    body = JSON.generate({
      model:      @model,
      max_tokens: 1024,
      tools:      anth_tools,
      messages:   anth_messages,
    })

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"]      = "application/json"
    req["x-api-key"]         = @api_key
    req["anthropic-version"] = "2023-06-01"
    req.body = body

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: 60) { |h| h.request(req) }
    skip "Anthropic call failed: HTTP #{res.code} #{res.body}" unless res.code.to_i.between?(200, 299)

    parsed = JSON.parse(res.body)
    blocks = Array(parsed["content"])
    text   = blocks.select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("\n")
    calls  = blocks.select { |b| b["type"] == "tool_use" }.map do |b|
      { id: b["id"], name: b["name"], arguments: b["input"] || {} }
    end
    { role: "assistant", content: text, tool_calls: calls }
  end
end
