# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"
require "parse/agent/mcp_rack_app"
require "json"
require "stringio"

# Rack-level wiring for MCP logging: which transports advertise it, and
# that a session's level can be set only by the principal that owns it.
class MCPLoggingTest < Minitest::Test
  class AgentStub
    attr_accessor :correlation_id, :log_callback, :progress_callback, :cancellation_token
    attr_reader :session_token, :acl_user_scope, :acl_role_scope, :client

    def initialize(session_token: nil)
      @correlation_id = nil
      @session_token = session_token
      @client = Struct.new(:master_key).new(session_token ? nil : "mk")
    end

    # Mirrors Parse::Agent#log.
    def log(level, data, logger: nil)
      @log_callback&.call(level: level.to_s, data: data, logger: logger)
    end

    # A tool that fails, and one that logs at info then succeeds.
    def execute(tool_name, **_kwargs)
      case tool_name
      when :fail_tool then { success: false, error: "boom", error_code: :invalid_query }
      when :chatty_tool
        log(:info, "working", logger: "custom")
        { success: true, data: { ok: true } }
      else { success: false, error: "unknown" }
      end
    end
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse", application_id: "a", api_key: "k")
    end
    # mcp_rack_app_test.rb replaces MCPDispatcher.call with a stub for the
    # whole process when it is loaded. These tests exercise the real
    # dispatcher, so put it back for their duration and re-stub afterwards.
    @restub = defined?(MCPDispatcherStub) && !MCPDispatcherStub.instance_variable_get(:@original_call).nil?
    MCPDispatcherStub.restore! if @restub
  end

  def teardown
    MCPDispatcherStub.install! if @restub
  end

  def build_app(streaming:)
    Parse::Agent::MCPRackApp.new(streaming: streaming) { |env| AgentStub.new(session_token: env["HTTP_X_PRINCIPAL"]) }
  end

  def post(app, method, params: {}, session_id: nil, principal: nil)
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json",
      "rack.input" => StringIO.new(JSON.generate("jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params)),
    }
    env["HTTP_MCP_SESSION_ID"] = session_id if session_id
    env["HTTP_X_PRINCIPAL"] = principal if principal
    status, _headers, body = app.call(env)
    [status, JSON.parse(body.join)]
  end

  # POST a streamed request and return every JSON-RPC message on its
  # response stream.
  def post_sse(app, method, params:, session_id:, principal:)
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json, text/event-stream",
      "HTTP_MCP_SESSION_ID" => session_id,
      "HTTP_X_PRINCIPAL" => principal,
      "rack.input" => StringIO.new(JSON.generate("jsonrpc" => "2.0", "id" => 2, "method" => method, "params" => params)),
    }
    _status, _headers, body = app.call(env)
    chunks = []
    body.each { |c| chunks << c }
    body.close if body.respond_to?(:close)
    chunks.join.scan(/^data: (.*)$/).map { |(line)| JSON.parse(line) }
  end

  def test_end_to_end_set_level_then_streamed_tool_call_emits_filtered_notification
    app = build_app(streaming: true)
    post(app, "initialize", params: { "protocolVersion" => "2025-11-25" }, session_id: "s1", principal: "alice")
    post(app, "initialize", params: { "protocolVersion" => "2025-11-25" }, session_id: "s2", principal: "bob")
    post(app, "logging/setLevel", params: { "level" => "warning" }, session_id: "s1", principal: "alice")

    # alice's failed tool call logs at warning, which meets her level.
    messages = post_sse(app, "tools/call", params: { "name" => "fail_tool" }, session_id: "s1", principal: "alice")
    logs = messages.select { |m| m["method"] == "notifications/message" }
    assert_equal [{ "level" => "warning", "data" => { "tool" => "fail_tool", "error_code" => "invalid_query" },
                    "logger" => "parse.agent.tools" }], logs.map { |m| m["params"] }
    response_index = messages.index { |m| m["id"] == 2 }
    assert_operator messages.index(logs.first), :<, response_index, "log precedes the final response"
    assert_equal true, messages[response_index]["result"]["isError"]

    # An info message is below alice's level and is dropped.
    quiet = post_sse(app, "tools/call", params: { "name" => "chatty_tool" }, session_id: "s1", principal: "alice")
    assert_empty quiet.select { |m| m["method"] == "notifications/message" }

    # bob never set a level, so his session receives no logs at all.
    other = post_sse(app, "tools/call", params: { "name" => "fail_tool" }, session_id: "s2", principal: "bob")
    assert_empty other.select { |m| m["method"] == "notifications/message" }
  end

  def level(app, sid)
    app.instance_variable_get(:@log_levels).get(sid)
  end

  def test_streaming_app_advertises_logging_and_records_owner_level
    app = build_app(streaming: true)
    _, init = post(app, "initialize", params: { "protocolVersion" => "2025-11-25" }, session_id: "s1", principal: "alice")
    assert_equal({}, init["result"]["capabilities"]["logging"])

    _, res = post(app, "logging/setLevel", params: { "level" => "warning" }, session_id: "s1", principal: "alice")
    assert_equal({}, res["result"])
    assert_equal "warning", level(app, "s1")
  end

  def test_other_principal_cannot_set_a_sessions_level
    app = build_app(streaming: true)
    post(app, "initialize", session_id: "s1", principal: "alice")
    post(app, "logging/setLevel", params: { "level" => "error" }, session_id: "s1", principal: "alice")
    _, res = post(app, "logging/setLevel", params: { "level" => "debug" }, session_id: "s1", principal: "mallory")
    assert_equal({}, res["result"], "no oracle: the refused call looks like success")
    assert_equal "error", level(app, "s1")
  end

  def test_reinitializing_another_sessions_id_cannot_change_its_level
    app = build_app(streaming: true)
    post(app, "initialize", session_id: "s1", principal: "alice")
    post(app, "logging/setLevel", params: { "level" => "error" }, session_id: "s1", principal: "alice")
    status, = post(app, "initialize", session_id: "s1", principal: "mallory")
    assert_equal 403, status
    post(app, "logging/setLevel", params: { "level" => "debug" }, session_id: "s1", principal: "mallory")
    assert_equal "error", level(app, "s1")
  end

  def test_uninitialized_session_ids_are_not_recorded
    app = build_app(streaming: true)
    post(app, "logging/setLevel", params: { "level" => "debug" }, session_id: "invented", principal: "alice")
    assert_nil level(app, "invented")
  end

  def test_delete_forgets_the_level
    app = build_app(streaming: true)
    post(app, "initialize", session_id: "s1", principal: "alice")
    post(app, "logging/setLevel", params: { "level" => "info" }, session_id: "s1", principal: "alice")
    status, = app.call("REQUEST_METHOD" => "DELETE", "HTTP_MCP_SESSION_ID" => "s1",
                       "HTTP_X_PRINCIPAL" => "mallory", "rack.input" => StringIO.new(""))
    assert_equal 403, status, "another principal cannot terminate the session"
    assert_equal "info", level(app, "s1")
    app.call("REQUEST_METHOD" => "DELETE", "HTTP_MCP_SESSION_ID" => "s1",
             "HTTP_X_PRINCIPAL" => "alice", "rack.input" => StringIO.new(""))
    assert_nil level(app, "s1")
  end

  def test_non_streaming_app_does_not_advertise_logging
    app = build_app(streaming: false)
    _, init = post(app, "initialize", session_id: "s1", principal: "alice")
    refute init["result"]["capabilities"].key?("logging")
    post(app, "logging/setLevel", params: { "level" => "info" }, session_id: "s1", principal: "alice")
    assert_nil level(app, "s1")
  end
end
