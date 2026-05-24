# encoding: UTF-8
# frozen_string_literal: true

# ---------------------------------------------------------------------------
# MCPSseE2eTest — SSE streaming end-to-end against a real in-process Puma server.
#
# Exercises the full path from Net::HTTP chunk-streaming through MCPRackApp's
# SSEBody → Puma's streaming Rack adapter. No Docker, no Parse Server — the
# agent factory returns a stubbed agent whose #execute sleeps so heartbeats
# have time to fire.
#
# Requires: puma gem (in Gemfile as of v4.1.0)
#
# Run standalone:
#   bundle exec ruby -Ilib:test test/lib/parse/agent/mcp_sse_e2e_test.rb
# ---------------------------------------------------------------------------

require "json"
require "socket"
require "net/http"
require "stringio"
require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_rack_app"
require_relative "../../../../lib/parse/agent/mcp_dispatcher"

# Load Puma inline so missing gem gives a readable skip, not a load error.
# Puma 8 changed the second argument to Puma::Server.new from LogWriter to
# Puma::Events (which exposes the #fire method the server expects internally).
begin
  require "puma"
  require "puma/server"
  require "puma/events"
  PUMA_AVAILABLE = true
rescue LoadError
  PUMA_AVAILABLE = false
end

# ---------------------------------------------------------------------------
# Shared SSE parse helper
# ---------------------------------------------------------------------------
module SSETestHelpers
  # Parse raw SSE text (may span many chunks) into [{event:, data:}] hashes.
  def parse_sse(raw)
    events = []
    raw.scan(/event:\s*(\S+)\r?\ndata:\s*(.+?)(?=\r?\n\r?\n|\z)/m) do |event, data|
      events << { event: event.strip, data: data.strip }
    end
    events
  end

  # Collect all streamed chunks from a Net::HTTP response into a single String.
  def collect_sse_body(response)
    buf = +""
    response.read_body { |chunk| buf << chunk }
    buf
  end

  # Build a tools/call JSON-RPC body, with optional progress token.
  def tools_call_body(id: 1, progress_token: nil, tool: "ping", args: {})
    body = {
      "jsonrpc" => "2.0",
      "id"      => id,
      "method"  => "tools/call",
      "params"  => { "name" => tool, "arguments" => args },
    }
    if progress_token
      body["params"]["_meta"] = { "progressToken" => progress_token }
    end
    JSON.generate(body)
  end

  # Build a standard JSON-RPC POST request targeting the MCPRackApp.
  def build_post(path = "/", body_str:, accept: "application/json")
    req = Net::HTTP::Post.new(path, {
      "Content-Type" => "application/json",
      "Accept"       => accept,
    })
    req.body = body_str
    req
  end
end

# ---------------------------------------------------------------------------
# The test class
# ---------------------------------------------------------------------------
class MCPSseE2eTest < Minitest::Test
  include SSETestHelpers

  # ---- set up stubbed dispatcher so no real Parse calls fire ---------------

  # Delays injected per-test via class var so the worker thread lambda sees them.
  @@dispatch_delay = 0
  @@dispatch_result = nil

  # The dispatcher stub is installed per-test in setup and restored in
  # teardown so it does not conflict with stubs from other MCP test files
  # (sinatra_mount_test.rb, concurrent_rate_limiter_test.rb, mcp_rack_app_test.rb)
  # when all tests are loaded into the same Minitest process.
  def self.install_dispatcher_stub!
    return if @stub_installed
    @orig_dispatcher  = Parse::Agent::MCPDispatcher.method(:call)
    @stub_installed   = true

    Parse::Agent::MCPDispatcher.define_singleton_method(:call) do |body:, agent:, logger: nil, progress_callback: nil, cancellation_token: nil|
      d = MCPSseE2eTest.class_variable_get(:@@dispatch_delay)
      sleep d if d && d > 0

      MCPSseE2eTest.class_variable_get(:@@dispatch_result) ||
        { status: 200, body: { "jsonrpc" => "2.0", "id" => body["id"], "result" => { "tools" => [], "stubbed" => true } } }
    end
  end

  def self.restore_dispatcher_stub!
    return unless @stub_installed
    orig = @orig_dispatcher
    Parse::Agent::MCPDispatcher.define_singleton_method(:call, &orig)
    @orig_dispatcher = nil
    @stub_installed  = false
  end

  def self.stub_installed?
    @stub_installed == true
  end

  # ---- Per-test Puma server + dispatcher stub (started/stopped in setup/teardown) -----------

  def setup
    skip "puma gem not available" unless PUMA_AVAILABLE

    unless Parse::Client.client?
      Parse.setup(
        server_url:     "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key:        "test-api-key",
      )
    end

    MCPSseE2eTest.install_dispatcher_stub!

    @@dispatch_delay  = 0
    @@dispatch_result = nil

    # Pick an ephemeral port
    @port = ephemeral_port
    @host = "127.0.0.1"

    # The rack app: streaming: true, very fast heartbeat for tests
    @rack_app = Parse::Agent::MCPRackApp.new(
      streaming:          true,
      heartbeat_interval: 0.1,
      agent_factory:      method(:build_stubbed_agent),
    )

    # Spin up Puma — Puma 8 expects a Puma::Events instance as second arg.
    @puma = Puma::Server.new(@rack_app, Puma::Events.new)
    @puma.add_tcp_listener(@host, @port)
    @puma_thread = @puma.run

    wait_for_server(@host, @port)
  end

  def teardown
    return unless PUMA_AVAILABLE
    MCPSseE2eTest.restore_dispatcher_stub!
    @puma&.stop(true)
    @puma_thread&.join(3)
    @puma = nil
    @puma_thread = nil
  end

  # ---- helpers -------------------------------------------------------------

  def ephemeral_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  # Agent factory: returns a fresh Parse::Agent whose #execute sleeps for the
  # current dispatch delay so SSE heartbeats have time to fire. The sleep is
  # on the dispatcher stub (class-level), not on the agent itself.
  def build_stubbed_agent(_env)
    Parse::Agent.new
  end

  # Poll until the server accepts a connection or timeout.
  def wait_for_server(host, port, timeout: 5)
    deadline = Time.now + timeout
    loop do
      TCPSocket.new(host, port).close
      break
    rescue Errno::ECONNREFUSED
      raise "Puma did not start on port #{port} within #{timeout}s" if Time.now > deadline
      sleep 0.05
    end
  end

  # Make a streaming SSE POST to the running Puma server. Returns parsed events.
  def sse_post(body_str, timeout: 5)
    events_raw = +""
    response_headers = {}

    Net::HTTP.start(@host, @port, read_timeout: timeout) do |http|
      req = build_post("/", body_str: body_str, accept: "text/event-stream")
      http.request(req) do |resp|
        response_headers = resp.to_hash.transform_values(&:first)
        events_raw << collect_sse_body(resp)
      end
    end

    [parse_sse(events_raw), response_headers, events_raw]
  end

  # Make a plain (non-SSE) POST to the running Puma server. Returns parsed JSON.
  def plain_post(body_str, accept: "application/json", timeout: 5)
    resp_body = nil
    resp_headers = {}

    Net::HTTP.start(@host, @port, read_timeout: timeout) do |http|
      req = build_post("/", body_str: body_str, accept: accept)
      resp = http.request(req)
      resp_headers = resp.to_hash.transform_values(&:first)
      resp_body = resp.body
      [resp.code.to_i, resp_headers, JSON.parse(resp_body)]
    end
  end

  # ---------------------------------------------------------------------------
  # 1. SSE response headers
  # ---------------------------------------------------------------------------

  def test_sse_response_has_correct_content_type
    @@dispatch_delay  = 0.3
    _events, headers, _raw = sse_post(tools_call_body)

    # Puma may lowercase header names; normalise
    ct = headers["content-type"] || headers["Content-Type"]
    assert_equal "text/event-stream", ct,
                 "Expected text/event-stream, got: #{ct.inspect}"
  end

  def test_sse_response_has_x_accel_buffering_no
    @@dispatch_delay = 0.3
    _events, headers, _raw = sse_post(tools_call_body)

    xab = headers["x-accel-buffering"] || headers["X-Accel-Buffering"]
    assert_equal "no", xab,
                 "Expected X-Accel-Buffering: no, got: #{xab.inspect}"
  end

  # ---------------------------------------------------------------------------
  # 2. Progress events fire during a slow tool call
  # ---------------------------------------------------------------------------

  def test_at_least_two_progress_events_arrive_for_slow_tool
    skip "timing-sensitive; skipped on macOS CI" if ENV["CI"] && RbConfig::CONFIG["host_os"] =~ /darwin/

    # Leave enough margin for CI scheduler jitter. With 0.1s heartbeats,
    # 0.6s should reliably produce multiple progress events even on slower runners.
    @@dispatch_delay = 0.6

    events, _headers, _raw = sse_post(tools_call_body)
    progress_events = events.select { |e| e[:event] == "progress" }

    assert progress_events.size >= 2,
           "Expected >=2 progress events for 0.6s tool; got #{progress_events.size}"
  end

  def test_progress_events_have_jsonrpc_notification_shape
    skip "timing-sensitive; skipped on macOS CI" if ENV["CI"] && RbConfig::CONFIG["host_os"] =~ /darwin/

    @@dispatch_delay = 0.6

    events, _headers, _raw = sse_post(tools_call_body)
    progress_events = events.select { |e| e[:event] == "progress" }

    assert progress_events.size >= 1, "Need at least one progress event to check shape"

    progress_events.each do |pe|
      data = JSON.parse(pe[:data])
      assert_equal "2.0",                    data["jsonrpc"]
      assert_equal "notifications/progress", data["method"]
      assert data["params"].key?("progressToken"), "Missing progressToken"
      assert data["params"].key?("progress"),      "Missing progress counter"
      assert_kind_of Numeric, data["params"]["progress"]
    end
  end

  def test_progress_token_from_client_params_echoed_in_events
    # The dispatcher stub here does not call progress_callback, so the
    # stream only contains heartbeat events. Heartbeats deliberately use
    # a dedicated server-namespaced progressToken (per MCP spec, the
    # client's token is reserved for tool-internal progress reports;
    # mixing elapsed-seconds heartbeats with tool work-unit values on
    # the same token would break per-token monotonicity).
    skip "timing-sensitive; skipped on macOS CI" if ENV["CI"] && RbConfig::CONFIG["host_os"] =~ /darwin/

    token = "e2e-client-token-#{SecureRandom.hex(4)}"
    @@dispatch_delay = 0.6

    events, _headers, _raw = sse_post(tools_call_body(progress_token: token))
    progress_events = events.select { |e| e[:event] == "progress" }

    assert progress_events.size >= 1, "Need progress events to verify token"

    progress_events.each do |pe|
      data = JSON.parse(pe[:data])
      tok  = data.dig("params", "progressToken")
      refute_equal token, tok,
                   "Heartbeat must NOT reuse the client's progressToken (would violate per-token monotonicity)"
      assert_match(/\Aparse-stack:heartbeat:/, tok,
                   "Heartbeat must use a server-namespaced progressToken")
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Final response event
  # ---------------------------------------------------------------------------

  def test_exactly_one_response_event_in_stream
    @@dispatch_delay = 0.3

    events, _headers, _raw = sse_post(tools_call_body(id: 42))
    response_events = events.select { |e| e[:event] == "response" }

    assert_equal 1, response_events.size,
                 "Expected exactly one response event, got #{response_events.size}"
  end

  def test_response_event_contains_valid_jsonrpc_envelope
    @@dispatch_delay = 0.15

    events, _headers, _raw = sse_post(tools_call_body(id: 99))
    response_event = events.find { |e| e[:event] == "response" }
    refute_nil response_event, "No response event found in SSE stream"

    data = JSON.parse(response_event[:data])
    assert_equal "2.0",  data["jsonrpc"]
    assert_equal 99,     data["id"]
    assert data.key?("result") || data.key?("error"),
           "Response envelope must have result or error key"
  end

  def test_response_event_matches_plain_json_result
    # Override stub to return a deterministic body
    fixed_body = {
      "jsonrpc" => "2.0",
      "id"      => 7,
      "result"  => { "tools" => [{ "name" => "ping" }] },
    }
    @@dispatch_result = { status: 200, body: fixed_body }
    @@dispatch_delay  = 0

    events, _headers, _raw = sse_post(tools_call_body(id: 7))
    response_event = events.find { |e| e[:event] == "response" }
    refute_nil response_event

    data = JSON.parse(response_event[:data])
    assert_equal fixed_body["result"], data["result"]
  end

  # ---------------------------------------------------------------------------
  # 4. Fallback: no SSE Accept → plain JSON
  # ---------------------------------------------------------------------------

  def test_plain_json_when_no_sse_accept
    @@dispatch_delay = 0

    status, headers, body = plain_post(tools_call_body, accept: "application/json")

    assert_equal 200, status
    ct = headers["content-type"] || headers["Content-Type"]
    assert_equal "application/json", ct
    assert body.key?("result") || body.key?("error"),
           "Plain JSON response must have result or error"
  end

  def test_405_for_get_request_regardless_of_sse_accept
    Net::HTTP.start(@host, @port) do |http|
      req = Net::HTTP::Get.new("/", "Accept" => "text/event-stream")
      resp = http.request(req)

      assert_equal "405", resp.code
      ct = resp["content-type"] || resp["Content-Type"]
      assert_equal "application/json", ct

      parsed = JSON.parse(resp.body)
      assert_equal(-32_700, parsed.dig("error", "code"))
    end
  end

  def test_415_for_wrong_content_type_regardless_of_sse_accept
    Net::HTTP.start(@host, @port) do |http|
      req = Net::HTTP::Post.new("/", {
        "Content-Type" => "text/plain",
        "Accept"       => "text/event-stream",
      })
      req.body = "hello"
      resp = http.request(req)

      assert_equal "415", resp.code
      ct = resp["content-type"] || resp["Content-Type"]
      assert_equal "application/json", ct
    end
  end

  # ---------------------------------------------------------------------------
  # 5. streaming: false on the app → plain JSON even with SSE Accept
  # ---------------------------------------------------------------------------

  def test_streaming_false_app_returns_plain_json_for_sse_accept
    @@dispatch_delay  = 0
    @@dispatch_result = nil

    plain_rack_app = Parse::Agent::MCPRackApp.new(
      streaming:          false,
      agent_factory:      method(:build_stubbed_agent),
    )

    # Spin up a second Puma instance on a different port
    port2    = ephemeral_port
    puma2    = Puma::Server.new(plain_rack_app, Puma::Events.new)
    puma2.add_tcp_listener(@host, port2)
    thread2  = puma2.run
    wait_for_server(@host, port2)

    begin
      status, headers, body = nil
      Net::HTTP.start(@host, port2) do |http|
        req = build_post("/", body_str: tools_call_body, accept: "text/event-stream")
        resp = http.request(req)
        status  = resp.code.to_i
        headers = resp.to_hash.transform_values(&:first)
        body    = JSON.parse(resp.body)
      end

      assert_equal 200, status
      ct = headers["content-type"] || headers["Content-Type"]
      assert_equal "application/json", ct,
                   "streaming:false app must return application/json even for SSE Accept"
      assert body.key?("result") || body.key?("error")
    ensure
      puma2.stop(true)
      thread2.join(3)
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Client disconnect: worker thread should not run past tool completion
  # ---------------------------------------------------------------------------

  def test_client_disconnect_does_not_leave_persistent_extra_threads
    # Give the tool a very short sleep so the orphaned dispatcher thread exits
    # naturally before we check Thread.list. Per the SSEBody comments the
    # dispatcher thread IS orphaned on disconnect but completes on its own.
    @@dispatch_delay = 0.1

    threads_before = Thread.list.size

    Net::HTTP.start(@host, @port, read_timeout: 3) do |http|
      req = build_post("/", body_str: tools_call_body, accept: "text/event-stream")
      http.request(req) do |resp|
        # Read exactly one chunk then break out to trigger socket close
        resp.read_body do |_chunk|
          break
        end
      end
    end

    # Allow orphaned threads to finish — tool delay is 0.1s, give 2x margin
    deadline = Time.now + 0.5
    loop do
      break if Thread.list.size <= threads_before + 1
      break if Time.now > deadline
      sleep 0.05
    end

    # After the short tool finishes, thread count must return to near-baseline.
    # We allow +1 for Puma's own housekeeping threads that may be momentarily
    # present; the key is no persistent leak beyond one.
    assert Thread.list.size <= threads_before + 2,
           "Thread leak after disconnect: before=#{threads_before}, " \
           "after=#{Thread.list.size}"
  end

  # ---------------------------------------------------------------------------
  # 7. Multiple concurrent SSE connections
  # ---------------------------------------------------------------------------

  def test_multiple_concurrent_sse_connections
    skip "timing-sensitive; skipped on macOS CI" if ENV["CI"] && RbConfig::CONFIG["host_os"] =~ /darwin/

    # 0.6s gives heartbeats (0.1s interval) plenty of room to fire even
    # under 3-way concurrent load on slower CI runners.
    @@dispatch_delay = 0.6

    results = Array.new(3, nil)
    threads = 3.times.map do |i|
      Thread.new do
        events, _h, _r = sse_post(tools_call_body(id: 100 + i))
        results[i] = {
          progress: events.count { |e| e[:event] == "progress" },
          response: events.count { |e| e[:event] == "response" },
        }
      end
    end
    threads.each { |t| t.join(8) }

    results.each_with_index do |r, i|
      refute_nil r, "Thread #{i} did not complete"
      assert r[:progress] >= 1, "Thread #{i}: expected >=1 progress events"
      assert_equal 1, r[:response], "Thread #{i}: expected exactly 1 response event"
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Response event is always last in the stream
  # ---------------------------------------------------------------------------

  def test_response_event_is_last_in_stream
    @@dispatch_delay = 0.25

    events, _headers, _raw = sse_post(tools_call_body)

    refute events.empty?, "Should have received at least one event"
    last_event = events.last
    assert_equal "response", last_event[:event],
                 "Final event must be 'response', got '#{last_event[:event]}'"
  end

  # ---------------------------------------------------------------------------
  # 9. Progress events arrive before the response event
  # ---------------------------------------------------------------------------

  def test_progress_events_precede_response_event
    @@dispatch_delay = 0.3

    events, _headers, _raw = sse_post(tools_call_body)

    progress_indices = events.each_index.select { |i| events[i][:event] == "progress" }
    response_index   = events.each_index.find   { |i| events[i][:event] == "response" }

    refute_nil response_index, "No response event found"
    assert progress_indices.size >= 1, "Expected at least one progress event before response"

    progress_indices.each do |pi|
      assert pi < response_index,
             "Progress event at index #{pi} must come before response at index #{response_index}"
    end
  end

  # ---------------------------------------------------------------------------
  # 10. Auto-generated progress token is a non-empty string
  # ---------------------------------------------------------------------------

  def test_auto_generated_progress_token_is_non_empty_string
    @@dispatch_delay = 0.25

    # Do NOT supply a progressToken in the request
    events, _headers, _raw = sse_post(tools_call_body)

    progress_events = events.select { |e| e[:event] == "progress" }
    assert progress_events.size >= 1, "Need at least one progress event"

    token = JSON.parse(progress_events.first[:data]).dig("params", "progressToken")
    refute_nil   token, "progressToken must be present even when not supplied by client"
    refute_empty token.to_s
    # Should look like a UUID (36 chars) or similar
    assert token.to_s.length >= 8,
           "Auto-generated progressToken should be a reasonable length, got: #{token.inspect}"
  end
end
