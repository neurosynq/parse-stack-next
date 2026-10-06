# encoding: UTF-8
# frozen_string_literal: true

# ---------------------------------------------------------------------------
# MCP client smoke test: a 2025-11-25 client session over real HTTP.
#
# Boots Parse::Agent::MCPRackApp (streaming on) under an in-process Puma
# server on a loopback port and drives it the way an MCP client does:
# initialize (server-assigned Mcp-Session-Id), notifications/initialized,
# tools/list, prompts/list, completion/complete, logging/setLevel, a streamed
# tools/call read off the SSE response, and DELETE to end the session.
#
# Uses the REAL dispatcher with a fake agent, so it needs no Parse Server and
# runs in the unit suite. Other MCP test files stub MCPDispatcher.call for the
# whole process; this file restores the real one for its own duration.
# ---------------------------------------------------------------------------

require "json"
require "socket"
require "net/http"
require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_rack_app"
require_relative "../../../../lib/parse/agent/mcp_dispatcher"

begin
  require "puma"
  require "puma/server"
  require "puma/events"
  MCP_SMOKE_PUMA = true
rescue LoadError
  MCP_SMOKE_PUMA = false
end

class MCPClientSmokeTest < Minitest::Test
  PROTOCOL = "2025-11-25"

  # Minimal agent: the surface the dispatcher, transport, and owner binding
  # read. A failing tool exercises the warning log on the streamed path.
  class SmokeAgent
    attr_accessor :correlation_id, :log_callback, :progress_callback, :cancellation_token
    attr_reader :session_token, :acl_user_scope, :acl_role_scope, :client

    def initialize(token)
      @session_token = token
      @client = Struct.new(:master_key).new(nil)
    end

    def permissions = :readonly

    def tool_definitions(format: :mcp, category: nil)
      [{ "name" => "count_objects", "description" => "Count objects",
         "inputSchema" => { "type" => "object", "properties" => {} } }]
    end

    def log(level, data, logger: nil)
      @log_callback&.call(level: level.to_s, data: data, logger: logger)
    end

    def cancelled? = false

    def execute(tool, **_kwargs)
      case tool
      when :get_all_schemas
        { success: true, data: { custom: [{ name: "Post" }, { name: "Project" }], built_in: [{ name: "_User" }] } }
      when :count_objects
        { success: false, error: "class not found", error_code: :invalid_argument }
      else
        { success: false, error: "unknown tool" }
      end
    end
  end

  def setup
    skip "puma gem not available" unless MCP_SMOKE_PUMA
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse", application_id: "a", api_key: "k")
    end
    # Undo a process-wide dispatcher stub installed by another MCP test file.
    @restub = defined?(MCPDispatcherStub) && !MCPDispatcherStub.instance_variable_get(:@original_call).nil?
    MCPDispatcherStub.restore! if @restub

    app = Parse::Agent::MCPRackApp.new(streaming: true, heartbeat_interval: 5) do |env|
      SmokeAgent.new(env["HTTP_AUTHORIZATION"].to_s.sub(/\ABearer /, ""))
    end
    @host = "127.0.0.1"
    @puma = Puma::Server.new(app, Puma::Events.new)
    # Bind port 0 and read the kernel-assigned port back, so no other process
    # can take the port between choosing it and binding it.
    @puma.add_tcp_listener(@host, 0)
    @port = @puma.connected_ports.first
    @puma_thread = @puma.run
    wait_for_port
  end

  def teardown
    @puma&.stop(true)
    @puma_thread&.join(3)
    MCPDispatcherStub.install! if @restub
  end

  def test_full_2025_11_25_client_session
    # initialize: the server assigns the session id.
    res = rpc("initialize", id: 1, params: {
      "protocolVersion" => PROTOCOL,
      "capabilities" => { "elicitation" => { "form" => {} } },
      "clientInfo" => { "name" => "psnext-smoke", "version" => "0" },
    })
    assert_equal "200", res.code
    session = res["Mcp-Session-Id"]
    refute_nil session, "initialize must return an Mcp-Session-Id"
    init = JSON.parse(res.body)["result"]
    assert_equal PROTOCOL, init["protocolVersion"]
    assert_equal({}, init["capabilities"]["completions"])
    assert_equal({}, init["capabilities"]["logging"], "streaming transport advertises logging")

    # notifications/initialized: accepted, no response body.
    res = rpc("notifications/initialized", session: session)
    assert_includes %w[200 202], res.code
    assert_empty res.body.to_s

    # tools/list and prompts/list.
    tools = JSON.parse(rpc("tools/list", id: 2, session: session).body)["result"]["tools"]
    assert_equal ["count_objects"], tools.map { |t| t["name"] }
    prompts = JSON.parse(rpc("prompts/list", id: 3, session: session).body)["result"]["prompts"]
    assert(prompts.any? { |p| p["name"] == "class_overview" })

    # completion/complete over the agent's visible classes.
    completion = JSON.parse(rpc("completion/complete", id: 4, session: session, params: {
      "ref" => { "type" => "ref/prompt", "name" => "class_overview" },
      "argument" => { "name" => "class_name", "value" => "P" },
    }).body)["result"]["completion"]
    assert_equal %w[Post Project], completion["values"]

    # logging/setLevel for this session.
    assert_equal({}, JSON.parse(rpc("logging/setLevel", id: 5, session: session,
                                                         params: { "level" => "warning" }).body)["result"])

    # Streamed tools/call: the failing tool's warning log arrives on the
    # response stream before the final response.
    messages = sse_rpc("tools/call", id: 6, session: session,
                                     params: { "name" => "count_objects", "arguments" => {} })
    log_at = messages.index { |m| m["method"] == "notifications/message" }
    response_at = messages.index { |m| m["id"] == 6 }
    refute_nil log_at, "expected a notifications/message log event"
    refute_nil response_at, "expected the final tools/call response"
    assert_operator log_at, :<, response_at
    assert_equal "warning", messages[log_at]["params"]["level"]
    assert_equal true, messages[response_at]["result"]["isError"]

    # DELETE ends the session.
    del = http_request(Net::HTTP::Delete.new("/"), session: session)
    assert_equal "204", del.code
  end

  private

  def wait_for_port
    50.times do
      TCPSocket.new(@host, @port).close
      return
    rescue Errno::ECONNREFUSED
      sleep 0.05
    end
    flunk "smoke server did not start on #{@host}:#{@port}"
  end

  def http_request(req, session: nil)
    req["Authorization"] = "Bearer smoke-user"
    req["MCP-Protocol-Version"] = PROTOCOL if session
    req["Mcp-Session-Id"] = session if session
    Net::HTTP.start(@host, @port, read_timeout: 10) { |h| h.request(req) }
  end

  def rpc(method, id: nil, session: nil, params: nil)
    body = { "jsonrpc" => "2.0", "method" => method }
    body["id"] = id if id
    body["params"] = params if params
    req = Net::HTTP::Post.new("/")
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json"
    req.body = JSON.generate(body)
    http_request(req, session: session)
  end

  # POST with `Accept: text/event-stream` and return every JSON-RPC message
  # read off the SSE response.
  def sse_rpc(method, id:, session:, params:)
    req = Net::HTTP::Post.new("/")
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json, text/event-stream"
    req.body = JSON.generate({ "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params })
    raw = +""
    req["Authorization"] = "Bearer smoke-user"
    req["MCP-Protocol-Version"] = PROTOCOL
    req["Mcp-Session-Id"] = session
    Net::HTTP.start(@host, @port, read_timeout: 10) do |h|
      h.request(req) do |res|
        assert_equal "200", res.code
        assert_match(%r{text/event-stream}, res["Content-Type"].to_s)
        res.read_body { |chunk| raw << chunk }
      end
    end
    raw.scan(/^data: (.*)$/).map { |(line)| JSON.parse(line) }
  end
end
