# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"
require "parse/agent/mcp_server"

# NEW-MCP-5: WEBrick's mount_proc("/mcp") is a prefix match, so a request
# to /mcp/anything would reach the handler unless we explicitly validate
# the path. These tests exercise handle_mcp_request with hand-rolled
# req/res doubles — they do not spin up WEBrick.
class MCPServerPathRoutingTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
  end

  # Minimal WEBrick::HTTPRequest-shaped double. We only need #path,
  # #request_method, plus the header readers handle_mcp_request consults
  # before short-circuiting on path.
  class FakeReq
    attr_reader :path, :request_method
    def initialize(path:, method: "POST", body: "{}", content_type: "application/json")
      @path = path
      @request_method = method
      @body = body
      @headers = {
        "Content-Type" => content_type,
        "Content-Length" => body.bytesize.to_s,
      }
    end
    def [](k); @headers[k]; end
    def body; @body; end
    def query_string; ""; end
    def each(&block)
      @headers.each_key(&block) if block
    end
  end

  class FakeRes
    attr_accessor :status, :body, :content_type
    def initialize
      @headers = {}
      @status = nil
    end
    def []=(k, v); @headers[k] = v; end
    def [](k); @headers[k]; end
  end

  def build_server
    Parse::Agent::MCPServer.new(host: "127.0.0.1", api_key: "test-key")
  end

  def parse_body(res)
    JSON.parse(res.body)
  end

  def test_root_mcp_path_passes_routing_check
    server = build_server
    req = FakeReq.new(path: "/mcp", method: "GET")
    res = FakeRes.new
    server.send(:handle_mcp_request, req, res)
    # GET is rejected with 405, NOT 404 — proving the path check passed
    # and the method check fired.
    assert_equal 405, res.status
  end

  def test_trailing_slash_is_accepted
    server = build_server
    req = FakeReq.new(path: "/mcp/", method: "GET")
    res = FakeRes.new
    server.send(:handle_mcp_request, req, res)
    assert_equal 405, res.status,
                 "/mcp/ should normalize to /mcp; got #{res.status} #{res.body}"
  end

  def test_subpath_returns_404
    server = build_server
    req = FakeReq.new(path: "/mcp/admin")
    res = FakeRes.new
    server.send(:handle_mcp_request, req, res)
    assert_equal 404, res.status
    payload = parse_body(res)
    assert_equal "Not Found", payload.dig("error", "message")
  end

  def test_deep_subpath_returns_404
    server = build_server
    req = FakeReq.new(path: "/mcp/a/b/c/d")
    res = FakeRes.new
    server.send(:handle_mcp_request, req, res)
    assert_equal 404, res.status
  end

  def test_path_traversal_attempt_returns_404
    server = build_server
    req = FakeReq.new(path: "/mcp/../admin")
    res = FakeRes.new
    server.send(:handle_mcp_request, req, res)
    assert_equal 404, res.status
  end

  def test_404_response_is_json_rpc_envelope
    server = build_server
    req = FakeReq.new(path: "/mcp/whatever")
    res = FakeRes.new
    server.send(:handle_mcp_request, req, res)
    assert_equal "application/json", res.content_type
    payload = parse_body(res)
    assert_equal "2.0", payload["jsonrpc"]
    assert_equal(-32_601, payload.dig("error", "code"))
  end
end
