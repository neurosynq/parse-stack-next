# encoding: UTF-8
# frozen_string_literal: true

# Test 1: MCPServer end-to-end integration against a real running MCPServer
# instance, backed by a real Parse Server (Docker).
#
# Each test wraps its body in with_mcp_server { |port| ... } which spawns a
# WEBrick MCPServer on a random free port in a background thread, waits for
# /health to respond, yields the port, then stops the server in an ensure
# block.  Fixture records are seeded inside each test and destroyed in the
# same ensure block.
#
# All tests are gated on PARSE_TEST_USE_DOCKER=true.  When the env var is
# absent the file loads cleanly and every test shows as skipped.

require_relative "../../../test_helper_integration"
require "net/http"
require "json"
require "socket"
require "timeout"

require "parse/agent"
require "parse/agent/mcp_server"

# ---------------------------------------------------------------------------
# Test fixture model — defined once at file scope.
# ---------------------------------------------------------------------------
class MCPE2EItem < Parse::Object
  parse_class "MCPE2EItem"
  property :name, :string
  property :score, :integer, default: 0
end

# ---------------------------------------------------------------------------
# Helper: pick a free TCP port on loopback.
# ---------------------------------------------------------------------------
module FreePort
  def self.pick
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end
end

# ---------------------------------------------------------------------------
# Main test class
# ---------------------------------------------------------------------------
class MCPServerE2EIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  MCP_HOST = "127.0.0.1"
  TEST_API_KEY = "e2e-test-api-key-9x7z"

  # -------------------------------------------------------------------------
  # Block helper: spawns an MCPServer, yields the port, then cleans up.
  # Safe to nest inside with_parse_server.
  # -------------------------------------------------------------------------
  def with_mcp_server(api_key: TEST_API_KEY, permissions: :readonly)
    prev_enabled = Parse::Agent.instance_variable_get(:@mcp_enabled)
    Parse::Agent.instance_variable_set(:@mcp_enabled, true)

    port = FreePort.pick
    server = Parse::Agent::MCPServer.new(
      port: port,
      host: MCP_HOST,
      permissions: permissions,
      api_key: api_key,
    )

    thread = Thread.new { server.start }
    thread.abort_on_exception = false

    wait_for_health!(port)
    yield port
  ensure
    server&.stop
    thread&.join(3)
    Parse::Agent.instance_variable_set(:@mcp_enabled, prev_enabled)
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------

  def wait_for_health!(port, timeout: 8)
    deadline = Time.now + timeout
    loop do
      begin
        resp = http_get(port, "/health")
        break if resp.code == "200"
      rescue StandardError
        # server not yet ready
      end
      raise "MCPServer did not become healthy within #{timeout}s" if Time.now > deadline
      sleep 0.1
    end
  end

  def http_get(port, path, headers = {})
    Net::HTTP.start(MCP_HOST, port, open_timeout: 3, read_timeout: 5) do |http|
      req = Net::HTTP::Get.new(path)
      headers.each { |k, v| req[k] = v }
      http.request(req)
    end
  end

  def http_post_json(port, path, body, headers = {})
    Net::HTTP.start(MCP_HOST, port, open_timeout: 3, read_timeout: 15) do |http|
      req = Net::HTTP::Post.new(path)
      req["Content-Type"] = "application/json"
      req["X-MCP-API-Key"] = TEST_API_KEY
      headers.each { |k, v| req[k] = v }
      raw_body = body.is_a?(String) ? body : JSON.generate(body)
      req["Content-Length"] = raw_body.bytesize.to_s
      req.body = raw_body
      http.request(req)
    end
  end

  def rpc(method, params = {}, id: 1)
    { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }
  end

  def mcp(port, method, params = {}, id: 1, extra_headers: {})
    resp = http_post_json(port, "/mcp", rpc(method, params, id: id), extra_headers)
    [resp.code.to_i, JSON.parse(resp.body)]
  end

  # =========================================================================
  # 1. Health endpoint
  # =========================================================================

  def test_health_returns_ok_unauthenticated
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        resp = http_get(port, "/health")
        assert_equal "200", resp.code
        data = JSON.parse(resp.body)
        assert_equal "ok", data["status"]
        assert data.key?("mcp_enabled"), "health response should include mcp_enabled"
      end
    end
  end

  # =========================================================================
  # 2. Transport-level rejections
  # =========================================================================

  def test_get_to_mcp_returns_405
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        resp = http_get(port, "/mcp", { "X-MCP-API-Key" => TEST_API_KEY })
        assert_equal 405, resp.code.to_i
        body = JSON.parse(resp.body)
        assert_equal "2.0", body["jsonrpc"]
        assert body.key?("error"), "405 response must have error key"
      end
    end
  end

  def test_wrong_content_type_returns_415
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        resp = Net::HTTP.start(MCP_HOST, port, open_timeout: 3, read_timeout: 5) do |http|
          req = Net::HTTP::Post.new("/mcp")
          req["Content-Type"] = "text/plain"
          req["X-MCP-API-Key"] = TEST_API_KEY
          payload = JSON.generate(rpc("initialize"))
          req["Content-Length"] = payload.bytesize.to_s
          req.body = payload
          http.request(req)
        end
        assert_equal 415, resp.code.to_i
        body = JSON.parse(resp.body)
        assert body.key?("error"), "415 response must have error key"
      end
    end
  end

  def test_oversize_body_returns_413
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        oversize = "x" * (Parse::Agent::MCPRackApp::DEFAULT_MAX_BODY_SIZE + 100)
        resp = Net::HTTP.start(MCP_HOST, port, open_timeout: 3, read_timeout: 5) do |http|
          req = Net::HTTP::Post.new("/mcp")
          req["Content-Type"] = "application/json"
          req["X-MCP-API-Key"] = TEST_API_KEY
          req["Content-Length"] = oversize.bytesize.to_s
          req.body = oversize
          http.request(req)
        end
        assert_equal 413, resp.code.to_i
        body = JSON.parse(resp.body)
        assert body.key?("error"), "413 response must have error key"
      end
    end
  end

  def test_malformed_json_returns_400
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        resp = Net::HTTP.start(MCP_HOST, port, open_timeout: 3, read_timeout: 5) do |http|
          req = Net::HTTP::Post.new("/mcp")
          req["Content-Type"] = "application/json"
          req["X-MCP-API-Key"] = TEST_API_KEY
          bad_json = "{not: valid json}"
          req["Content-Length"] = bad_json.bytesize.to_s
          req.body = bad_json
          http.request(req)
        end
        assert_equal 400, resp.code.to_i
        body = JSON.parse(resp.body)
        assert body.key?("error"), "400 response must have error key"
        assert_match(/parse error/i, body["error"]["message"].to_s)
      end
    end
  end

  def test_chunked_transfer_encoding_returns_411
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        raw = "POST /mcp HTTP/1.1\r\nHost: #{MCP_HOST}:#{port}\r\nContent-Type: application/json\r\n" \
              "Transfer-Encoding: chunked\r\nX-MCP-API-Key: #{TEST_API_KEY}\r\n\r\n" \
              "5\r\nhello\r\n0\r\n\r\n"
        status_line = nil
        Timeout.timeout(5) do
          TCPSocket.open(MCP_HOST, port) do |sock|
            sock.write(raw)
            status_line = sock.gets
          end
        end
        assert status_line, "Expected a status line from server"
        assert_match(/411/, status_line, "Expected 411 Length Required for chunked request")
      end
    end
  end

  # =========================================================================
  # 3. API key enforcement
  # =========================================================================

  def test_mcp_wrong_api_key_returns_401
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        resp = http_post_json(port, "/mcp", rpc("initialize"), { "X-MCP-API-Key" => "wrong-key" })
        assert_equal 401, resp.code.to_i
        body = JSON.parse(resp.body)
        assert body.key?("error"), "401 response must have error key"
        assert_equal(-32_001, body["error"]["code"])
      end
    end
  end

  def test_mcp_no_api_key_returns_401
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        resp = Net::HTTP.start(MCP_HOST, port, open_timeout: 3, read_timeout: 5) do |http|
          req = Net::HTTP::Post.new("/mcp")
          req["Content-Type"] = "application/json"
          payload = JSON.generate(rpc("initialize"))
          req["Content-Length"] = payload.bytesize.to_s
          req.body = payload
          # Deliberately omit X-MCP-API-Key header
          http.request(req)
        end
        assert_equal 401, resp.code.to_i
        body = JSON.parse(resp.body)
        assert body.key?("error"), "401 response must have error key"
      end
    end
  end

  def test_mcp_correct_api_key_returns_200
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        status, body = mcp(port, "initialize")
        assert_equal 200, status
        assert body.key?("result"), "Successful request must have result key"
      end
    end
  end

  # =========================================================================
  # 4. /tools endpoint
  # =========================================================================

  def test_tools_endpoint_correct_key_returns_tool_list
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        resp = http_get(port, "/tools", { "X-MCP-API-Key" => TEST_API_KEY })
        assert_equal "200", resp.code
        data = JSON.parse(resp.body)
        assert data.is_a?(Array) || data.is_a?(Hash),
               "tools response should be Array or Hash of tool definitions"
      end
    end
  end

  def test_tools_endpoint_wrong_key_returns_401
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        resp = http_get(port, "/tools", { "X-MCP-API-Key" => "bad-key" })
        assert_equal "401", resp.code
        data = JSON.parse(resp.body)
        assert data.key?("error"), "401 response must have error key"
      end
    end
  end

  # =========================================================================
  # 5. MCP initialize handshake
  # =========================================================================

  def test_initialize_returns_protocol_version
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        status, body = mcp(port, "initialize")
        assert_equal 200, status
        result = body["result"]
        assert result, "initialize must return result"
        assert_equal Parse::Agent::MCPServer::PROTOCOL_VERSION, result["protocolVersion"]
      end
    end
  end

  def test_initialize_returns_capabilities
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        _status, body = mcp(port, "initialize")
        result = body["result"]
        caps = result["capabilities"]
        assert caps.is_a?(Hash), "capabilities must be a Hash"
        assert caps.key?("tools"), "capabilities must include tools"
        assert caps.key?("resources"), "capabilities must include resources"
        assert caps.key?("prompts"), "capabilities must include prompts"
      end
    end
  end

  def test_initialize_returns_server_info
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        _status, body = mcp(port, "initialize")
        result = body["result"]
        info = result["serverInfo"]
        assert info.is_a?(Hash), "serverInfo must be a Hash"
        assert_equal "parse-stack-mcp", info["name"]
        assert info["version"], "serverInfo must include version"
      end
    end
  end

  # =========================================================================
  # 6. tools/list
  # =========================================================================

  def test_tools_list_returns_array_of_tool_descriptors
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        _status, body = mcp(port, "tools/list")
        result = body["result"]
        assert result, "tools/list must return result"
        tools = result["tools"]
        assert tools.is_a?(Array), "tools must be an Array"
        assert tools.size >= 5, "Should have at least 5 built-in tools"

        tools.each do |tool|
          assert tool.key?("name"), "each tool must have 'name'"
          assert tool.key?("description"), "each tool must have 'description'"
          assert tool.key?("inputSchema"), "each tool must have 'inputSchema'"
        end
      end
    end
  end

  def test_tools_list_contains_known_builtin_tools
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        _status, body = mcp(port, "tools/list")
        tool_names = body["result"]["tools"].map { |t| t["name"] }
        assert_includes tool_names, "get_all_schemas"
        assert_includes tool_names, "query_class"
        assert_includes tool_names, "count_objects"
        assert_includes tool_names, "get_schema"
      end
    end
  end

  # =========================================================================
  # 7. tools/call — get_all_schemas against real Parse Server
  # =========================================================================

  def test_tools_call_get_all_schemas_returns_real_data
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        _status, body = mcp(port, "tools/call", {
          "name" => "get_all_schemas",
          "arguments" => {},
        })
        result = body["result"]
        assert result, "tools/call must return result"
        refute result["isError"], "get_all_schemas should not be an error: #{result.inspect}"

        content = result["content"]
        assert content.is_a?(Array), "content must be an Array"
        assert content.size >= 1, "content must have at least one item"

        text = content.first["text"]
        parsed = JSON.parse(text)
        assert parsed.key?("total") || parsed.key?("classes") || parsed.key?("custom"),
               "Response should contain schema data"
      end
    end
  end

  def test_tools_call_get_all_schemas_includes_fixture_class
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    items = nil
    with_parse_server do
      items = []
      # Seed at least one MCPE2EItem so the class exists on the server.
      item = MCPE2EItem.new(name: "e2e_seed", score: 1)
      item.save
      items << item

      with_mcp_server do |port|
        _status, body = mcp(port, "tools/call", {
          "name" => "get_all_schemas",
          "arguments" => {},
        })
        text = body["result"]["content"].first["text"]
        assert_match(/MCPE2EItem/, text, "Schema response should include MCPE2EItem class")
      end
    end
  ensure
    items&.each { |i| i.destroy rescue nil }
  end

  # =========================================================================
  # 8. tools/call — query_class against fixture data
  # =========================================================================

  def test_tools_call_query_class_returns_fixture_records
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    items = nil
    with_parse_server do
      items = []
      5.times do |i|
        item = MCPE2EItem.new(name: "item_#{i}", score: i * 10)
        item.save
        items << item
      end

      with_mcp_server do |port|
        _status, body = mcp(port, "tools/call", {
          "name" => "query_class",
          "arguments" => {
            "class_name" => "MCPE2EItem",
            "limit" => 10,
          },
        })
        result = body["result"]
        refute result["isError"], "query_class should succeed: #{result.inspect}"
        text = result["content"].first["text"]
        data = JSON.parse(text)
        count = data["result_count"] || data["count"] || 0
        assert_operator count, :>=, 5, "Should return at least 5 fixture records"
      end
    end
  ensure
    items&.each { |i| i.destroy rescue nil }
  end

  def test_tools_call_query_class_with_where_constraint
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    items = nil
    with_parse_server do
      items = []
      item = MCPE2EItem.new(name: "target_item", score: 99)
      item.save
      items << item

      with_mcp_server do |port|
        _status, body = mcp(port, "tools/call", {
          "name" => "query_class",
          "arguments" => {
            "class_name" => "MCPE2EItem",
            "where" => { "name" => "target_item" },
            "limit" => 5,
          },
        })
        result = body["result"]
        refute result["isError"], "query with where constraint should succeed"
        text = result["content"].first["text"]
        data = JSON.parse(text)
        count = data["result_count"] || data["count"] || 0
        assert_operator count, :>=, 1, "Should find at least 1 record named target_item"
      end
    end
  ensure
    items&.each { |i| i.destroy rescue nil }
  end

  # =========================================================================
  # 9. prompts/list and prompts/get
  # =========================================================================

  def test_prompts_list_returns_builtin_prompts
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        _status, body = mcp(port, "prompts/list")
        result = body["result"]
        assert result, "prompts/list must return result"
        prompts = result["prompts"]
        assert prompts.is_a?(Array), "prompts must be an Array"
        assert prompts.size >= 1, "Should have at least one builtin prompt"
        prompt_names = prompts.map { |p| p["name"] }
        assert_includes prompt_names, "parse_conventions"
      end
    end
  end

  def test_prompts_get_parse_conventions
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        _status, body = mcp(port, "prompts/get", {
          "name" => "parse_conventions",
          "arguments" => {},
        })
        result = body["result"]
        assert result, "prompts/get must return result"
        assert result.key?("description"), "prompt result must have description"
        msgs = result["messages"]
        assert msgs.is_a?(Array), "messages must be an Array"
        assert msgs.size >= 1, "messages must have at least one entry"
        text = msgs.first.dig("content", "text")
        assert text, "message content must have text"
        assert_match(/objectId/, text, "parse_conventions should mention objectId")
      end
    end
  end

  # =========================================================================
  # 10. resources/list
  # =========================================================================

  def test_resources_list_includes_fixture_class_resources
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    items = nil
    with_parse_server do
      items = []
      item = MCPE2EItem.new(name: "resource_seed", score: 1)
      item.save
      items << item

      with_mcp_server do |port|
        _status, body = mcp(port, "resources/list")
        result = body["result"]
        assert result, "resources/list must return result"
        resources = result["resources"]
        assert resources.is_a?(Array), "resources must be an Array"
        uris = resources.map { |r| r["uri"] }
        e2e_uris = uris.select { |u| u&.include?("MCPE2EItem") }
        assert e2e_uris.size >= 1,
               "Should have at least 1 resource for MCPE2EItem, got: #{uris.inspect}"
      end
    end
  ensure
    items&.each { |i| i.destroy rescue nil }
  end

  def test_resources_list_resource_shape
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        _status, body = mcp(port, "resources/list")
        resources = body["result"]["resources"]
        resources.first(3).each do |resource|
          assert resource.key?("uri"), "resource must have uri"
          assert resource.key?("name"), "resource must have name"
          assert resource.key?("mimeType"), "resource must have mimeType"
        end
      end
    end
  end

  # =========================================================================
  # 11. Unknown method returns -32601
  # =========================================================================

  def test_unknown_method_returns_method_not_found
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_mcp_server do |port|
        _status, body = mcp(port, "nonexistent/method")
        assert body.key?("error"), "Unknown method must return error"
        assert_equal(-32_601, body["error"]["code"])
      end
    end
  end
end
