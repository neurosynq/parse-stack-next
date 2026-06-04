# encoding: UTF-8
# frozen_string_literal: true

# ---------------------------------------------------------------------------
# SinatraMountTest — verifies Parse::Agent.rack_app embeds correctly inside
# a Sinatra::Base application with JWT-style Bearer authentication.
#
# Uses Rack::Test (rack-test gem) so no real HTTP server is needed.
#
# This test validates:
# - The MCP adapter can be mounted at an arbitrary sub-path in Sinatra
# - Bearer token auth via the agent factory works correctly
# - All transport-level rejections (405, 415, 401) still work as expected
# - Each request receives a fresh Parse::Agent (per-request isolation)
# - Agent factory is invoked exactly once per request
#
# Run standalone:
#   bundle exec ruby -Ilib:test test/lib/parse/agent/sinatra_mount_test.rb
# ---------------------------------------------------------------------------

require "json"
require "stringio"
require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_rack_app"
require_relative "../../../../lib/parse/agent/mcp_dispatcher"

begin
  require "sinatra/base"
  require "rack/test"
  SINATRA_AVAILABLE = true
rescue LoadError
  SINATRA_AVAILABLE = false
end

# ---------------------------------------------------------------------------
# Dispatcher stub scoped to this test file.
# Installed at file-load time; restored in Minitest.after_run.
# ---------------------------------------------------------------------------
module SinatraMountDispatcherStub
  class << self
    def install!
      return if @installed
      @original = Parse::Agent::MCPDispatcher.method(:call)
      @installed = true

      Parse::Agent::MCPDispatcher.define_singleton_method(:call) do |body:, agent:, logger: nil, progress_callback: nil, cancellation_token: nil, subscription_manager: nil|
        {
          status: 200,
          body: {
            "jsonrpc" => "2.0",
            "id"      => body["id"],
            "result"  => {
              "tools" => [
                {
                  "name"        => "ping",
                  "description" => "Stubbed ping tool",
                  "inputSchema" => { "type" => "object", "properties" => {}, "required" => [] },
                },
              ],
            },
          },
        }
      end
    end

    def restore!
      return unless @installed
      orig = @original
      Parse::Agent::MCPDispatcher.define_singleton_method(:call, &orig)
      @installed = false
      @original  = nil
    end
  end
end

# NOTE: The dispatcher stub is installed per-test in setup/teardown (below)
# rather than at file-load time. This prevents the stub from conflicting with
# stubs installed by other MCP test files loaded in the same Minitest process.

# ---------------------------------------------------------------------------
# The Sinatra application under test.
# ---------------------------------------------------------------------------
if SINATRA_AVAILABLE
  class MCPSinatraTestApp < Sinatra::Base
    # Rack::Test uses "example.org" as the default Host header. Sinatra 4.x
    # adds host_authorization middleware that rejects unlisted hosts with 403.
    # Allow all hosts in the test app so Rack::Test requests are not blocked.
    #
    # Also disable Rack::Protection entirely — there is no browser session, no
    # CSRF token, and no cookies in these API-level tests.
    disable :protection
    set :host_authorization, { permitted_hosts: [] }

    # The auth secret. Tests that know it get 200; others get 401.
    CORRECT_TOKEN = "correct-token".freeze

    # Per-test counters — reset in each test's setup.
    @factory_invocations = 0
    @last_agents = []

    class << self
      attr_accessor :factory_invocations, :last_agents
    end

    # Build the MCP adapter once at class definition time.
    # The factory block captures `CORRECT_TOKEN` via the class constant and
    # records each constructed agent so tests can inspect isolation.
    MCP_ADAPTER = Parse::Agent.rack_app do |env|
      MCPSinatraTestApp.factory_invocations += 1

      token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ").strip
      unless token == CORRECT_TOKEN
        raise Parse::Agent::Unauthorized.new("bad bearer token", reason: :bad_bearer)
      end

      agent = Parse::Agent.new
      # Stub #execute so no real Parse calls fire.
      agent.define_singleton_method(:execute) do |tool_name, **_kwargs|
        { success: true, data: { tool: tool_name.to_s } }
      end
      MCPSinatraTestApp.last_agents << agent
      agent
    end

    # Mount the adapter at /admin/mcp for all HTTP methods so that
    # non-POST requests are forwarded to the adapter and receive its 405
    # response (rather than Sinatra's own 404 "not found").
    #
    # Pull the Rack triple apart and write it back through Sinatra's response
    # helpers so status codes, headers, and body are faithfully forwarded.
    %w[post get put delete patch].each do |verb|
      send(verb, "/admin/mcp") do
        status_code, resp_headers, body_parts = MCP_ADAPTER.call(env)
        status status_code
        resp_headers.each { |k, v| headers[k] = v }
        body_parts.join
      end
    end
  end
end

# ---------------------------------------------------------------------------
# The test class
# ---------------------------------------------------------------------------
class SinatraMountTest < Minitest::Test
  include Rack::Test::Methods if SINATRA_AVAILABLE

  def app
    MCPSinatraTestApp
  end

  CORRECT_TOKEN = "correct-token".freeze
  AUTH_HEADER   = "Bearer #{CORRECT_TOKEN}".freeze

  def setup
    skip "sinatra or rack-test gem not available" unless SINATRA_AVAILABLE

    unless Parse::Client.client?
      Parse.setup(
        server_url:     "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key:        "test-api-key",
      )
    end

    # Install per-test so the stub doesn't conflict with other MCP test files
    # that may be loaded in the same Minitest process.
    SinatraMountDispatcherStub.install!

    # Reset per-test counters
    MCPSinatraTestApp.factory_invocations = 0
    MCPSinatraTestApp.last_agents         = []
  end

  def teardown
    return unless SINATRA_AVAILABLE
    SinatraMountDispatcherStub.restore!
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # POST to /admin/mcp with optional auth and content type.
  def mcp_post(body_hash, auth: AUTH_HEADER, content_type: "application/json")
    headers = { "CONTENT_TYPE" => content_type }
    headers["HTTP_AUTHORIZATION"] = auth if auth
    post "/admin/mcp", JSON.generate(body_hash), headers
    last_response
  end

  def parsed_body
    JSON.parse(last_response.body)
  end

  # ---------------------------------------------------------------------------
  # 1. Happy path: valid bearer + tools/list
  # ---------------------------------------------------------------------------

  def test_valid_bearer_tools_list_returns_200
    mcp_post({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list" })

    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type
    body = parsed_body
    assert_equal "2.0", body["jsonrpc"]
    assert body.key?("result"), "Expected result key in response; got: #{body.inspect}"
    assert body["result"].key?("tools"), "Expected tools in result"
  end

  def test_valid_bearer_tools_list_contains_tool_definitions
    mcp_post({ "jsonrpc" => "2.0", "id" => 2, "method" => "tools/list" })

    assert_equal 200, last_response.status
    tools = parsed_body.dig("result", "tools")
    assert_instance_of Array, tools
    assert tools.size >= 1, "Expected at least one tool definition"

    tools.each do |t|
      assert t.key?("name"),        "Tool missing 'name': #{t.inspect}"
      assert t.key?("inputSchema"), "Tool missing 'inputSchema': #{t.inspect}"
    end
  end

  def test_request_id_echoed_in_response
    mcp_post({ "jsonrpc" => "2.0", "id" => 42, "method" => "ping" })

    assert_equal 200, last_response.status
    assert_equal 42, parsed_body["id"]
  end

  # ---------------------------------------------------------------------------
  # 2. Auth failures
  # ---------------------------------------------------------------------------

  def test_missing_authorization_header_returns_401
    mcp_post({ "jsonrpc" => "2.0", "id" => 3, "method" => "tools/list" }, auth: nil)

    assert_equal 401, last_response.status
    assert_equal "application/json", last_response.content_type
    body = parsed_body
    assert_equal(-32_001, body.dig("error", "code"))
    assert_equal "Unauthorized", body.dig("error", "message")
  end

  def test_missing_auth_response_does_not_leak_exception_details
    mcp_post({ "jsonrpc" => "2.0", "id" => 4, "method" => "tools/list" }, auth: nil)

    refute_includes last_response.body, "bad bearer token",
                    "Exception message must not appear in 401 response"
    refute_includes last_response.body, "bad_bearer",
                    "Reason symbol must not appear in 401 response"
  end

  def test_wrong_bearer_token_returns_401
    mcp_post(
      { "jsonrpc" => "2.0", "id" => 5, "method" => "tools/list" },
      auth: "Bearer definitely-wrong-token",
    )

    assert_equal 401, last_response.status
    assert_equal(-32_001, parsed_body.dig("error", "code"))
  end

  def test_wrong_bearer_does_not_leak_token_in_response
    mcp_post(
      { "jsonrpc" => "2.0", "id" => 6, "method" => "tools/list" },
      auth: "Bearer definitely-wrong-token",
    )

    refute_includes last_response.body, "definitely-wrong-token"
  end

  # ---------------------------------------------------------------------------
  # 3. Transport-level rejections
  # ---------------------------------------------------------------------------

  def test_get_to_mcp_path_returns_405_from_adapter
    # GET /admin/mcp is routed to the adapter, which rejects non-POST requests
    # with a 405 Method Not Allowed JSON-RPC error envelope.
    get "/admin/mcp", {}, { "HTTP_AUTHORIZATION" => AUTH_HEADER }
    assert_equal 405, last_response.status
    assert_equal "application/json", last_response.content_type
    assert_equal(-32_700, parsed_body.dig("error", "code"))
    assert_equal "method_not_allowed", parsed_body.dig("error", "message")
  end

  def test_wrong_path_returns_404
    post "/admin/wrong",
         JSON.generate({ "jsonrpc" => "2.0", "id" => 7, "method" => "ping" }),
         { "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => AUTH_HEADER }

    assert_equal 404, last_response.status
  end

  def test_wrong_content_type_returns_415
    mcp_post(
      { "jsonrpc" => "2.0", "id" => 8, "method" => "tools/list" },
      content_type: "text/plain",
    )

    assert_equal 415, last_response.status
    assert_equal "application/json", last_response.content_type
    assert_equal(-32_700, parsed_body.dig("error", "code"))
  end

  def test_malformed_json_returns_400
    post "/admin/mcp",
         "{ this is not json",
         { "CONTENT_TYPE" => "application/json", "HTTP_AUTHORIZATION" => AUTH_HEADER }

    assert_equal 400, last_response.status
    assert_equal(-32_700, parsed_body.dig("error", "code"))
  end

  # ---------------------------------------------------------------------------
  # 4. Per-request agent isolation
  # ---------------------------------------------------------------------------

  def test_agent_factory_called_once_per_request
    3.times { mcp_post({ "jsonrpc" => "2.0", "id" => 9, "method" => "ping" }) }

    assert_equal 3, MCPSinatraTestApp.factory_invocations,
                 "agent_factory must be called exactly once per request (got " \
                 "#{MCPSinatraTestApp.factory_invocations} for 3 requests)"
  end

  def test_each_request_gets_fresh_agent_instance
    2.times do |i|
      mcp_post({ "jsonrpc" => "2.0", "id" => 10 + i, "method" => "ping" })
    end

    agents = MCPSinatraTestApp.last_agents
    assert_equal 2, agents.size,
                 "Expected two agents to be constructed (one per request)"
    refute_same agents[0], agents[1],
                "Each request must receive a distinct Parse::Agent instance"
  end

  def test_two_sequential_agents_have_different_object_ids
    2.times do |i|
      mcp_post({ "jsonrpc" => "2.0", "id" => 20 + i, "method" => "ping" })
    end

    agents = MCPSinatraTestApp.last_agents
    refute_equal agents[0].object_id, agents[1].object_id,
                 "Sequential agents must have different object_ids (no request state leak)"
  end
end
