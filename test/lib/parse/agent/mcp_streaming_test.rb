# encoding: UTF-8
# frozen_string_literal: true

require "stringio"
require "json"
require "securerandom"
require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_rack_app"

# ---------------------------------------------------------------------------
# MCPStreamingTest — unit tests for SSE streaming support in MCPRackApp.
#
# MCPDispatcher.call is stubbed with a controllable implementation so tests
# can induce a realistic dispatch delay without relying on a live Parse server.
# The stub is installed only for the duration of this test file's run.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Controlled stub for MCPDispatcher.call used by streaming tests.
# The `delay` field causes the stub to sleep before returning, giving the
# heartbeat timer enough time to fire at least once.
#
# Unlike MCPDispatcherStub in mcp_rack_app_test.rb, this stub is installed
# and restored per-test (in setup/teardown) rather than at file-load time.
# This avoids cross-test pollution when multiple MCP test files are loaded
# into the same Ruby process (e.g. during rake test:unit).
# ---------------------------------------------------------------------------
module StreamingDispatcherStub
  FIXED_RESPONSE = {
    status: 200,
    body: { "jsonrpc" => "2.0", "id" => 1, "result" => { "tools" => [] } },
  }.freeze

  class << self
    attr_accessor :delay, :response, :raise_error, :progress_calls, :pre_progress_delay,
                  :last_cancellation_token

    def install!
      @original           = Parse::Agent::MCPDispatcher.method(:call)
      @delay              = 0
      @pre_progress_delay = 0
      @response           = nil
      @raise_error        = nil
      # When set to an Array of kwarg Hashes, the stub invokes
      # progress_callback once for each entry to simulate a tool reporting
      # tool-internal progress mid-dispatch. Each entry is splatted with
      # `**hash` so it must use Symbol keys (progress:, total:, message:).
      @progress_calls = nil

      Parse::Agent::MCPDispatcher.define_singleton_method(:call) do |body:, agent:, logger: nil, progress_callback: nil, cancellation_token: nil|
        delay = StreamingDispatcherStub.delay || 0

        # Drive the simulated tool-internal progress events. The
        # pre_progress_delay lets tests assert that real time-based
        # heartbeats fire BEFORE the first tool report (so the
        # suppression test exercises the actual transition path).
        if (calls = StreamingDispatcherStub.progress_calls) && progress_callback
          pre_delay = StreamingDispatcherStub.pre_progress_delay || 0
          sleep pre_delay if pre_delay > 0
          calls.each do |kwargs|
            progress_callback.call(**kwargs)
          end
        end

        # When the test installs a cancellation_token, the stub respects
        # it by short-circuiting before the simulated work completes.
        # Tests can also poll the token externally to verify it was
        # delivered to the dispatcher.
        StreamingDispatcherStub.last_cancellation_token = cancellation_token

        sleep delay if delay > 0
        if (err = StreamingDispatcherStub.raise_error)
          raise err
        end
        StreamingDispatcherStub.response || StreamingDispatcherStub::FIXED_RESPONSE
      end
    end

    def restore!
      if @original
        original = @original
        Parse::Agent::MCPDispatcher.define_singleton_method(:call, &original)
      end
      @delay                   = 0
      @pre_progress_delay      = 0
      @response                = nil
      @raise_error             = nil
      @progress_calls          = nil
      @last_cancellation_token = nil
      @original                = nil
    end

    def installed?
      !@original.nil?
    end
  end
end

class MCPStreamingTest < Minitest::Test
  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url:     "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key:        "test-api-key",
      )
    end

    # Install per-test so the stub does not bleed into other test files when
    # multiple MCP test files are loaded in the same process.
    StreamingDispatcherStub.install!
  end

  def teardown
    StreamingDispatcherStub.restore!
  end

  # Minimal Rack env. `accept` overrides HTTP_ACCEPT.
  def rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "ping" }),
               accept: nil,
               method: "POST",
               content_type: "application/json")
    env = {
      "REQUEST_METHOD" => method,
      "CONTENT_TYPE"   => content_type,
      "rack.input"     => StringIO.new(body),
    }
    env["HTTP_ACCEPT"] = accept if accept
    env
  end

  def valid_agent
    Parse::Agent.new
  end

  def permissive_factory
    ->(_env) { valid_agent }
  end

  # Capture warnings emitted via Kernel#warn during the block.
  def capture_warns
    original_stderr = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original_stderr
  end

  # Build a streaming-enabled app with a very short heartbeat interval for tests.
  # Suppresses the orphan-DoS warning by default (covered separately by
  # test_constructor_warns_when_streaming_without_concurrency_cap).
  def streaming_app(heartbeat_interval: 0.1, max_concurrent_dispatchers: 100, **kwargs)
    Parse::Agent::MCPRackApp.new(
      agent_factory:               permissive_factory,
      streaming:                   true,
      heartbeat_interval:          heartbeat_interval,
      max_concurrent_dispatchers:  max_concurrent_dispatchers,
      **kwargs,
    )
  end

  # Build a non-streaming app (the default).
  def plain_app(**kwargs)
    Parse::Agent::MCPRackApp.new(agent_factory: permissive_factory, **kwargs)
  end

  # Drain a Rack body object into an array of strings.
  def drain_body(body)
    chunks = []
    body.each { |c| chunks << c }
    chunks
  rescue => e
    # Surface drain errors in test output without swallowing the test
    chunks << "DRAIN_ERROR:#{e.class}:#{e.message}"
    chunks
  end

  # Parse SSE event chunks. Returns an array of { event:, data: } hashes.
  def parse_sse_chunks(chunks)
    events = []
    chunks.each do |chunk|
      chunk.scan(/event:\s*(\S+)\ndata:\s*(.+?)(?=\n\n|\z)/m) do |event, data|
        events << { event: event, data: data }
      end
    end
    events
  end

  # ---------------------------------------------------------------------------
  # 1. Default (streaming: false) — SSE Accept returns plain JSON
  # ---------------------------------------------------------------------------

  def test_default_streaming_false_sse_accept_returns_json
    app = plain_app
    status, headers, body = app.call(rack_env(accept: "text/event-stream"))

    assert_equal 200, status
    assert_equal "application/json", headers["Content-Type"]
    chunks = drain_body(body)
    parsed = JSON.parse(chunks.join)
    assert parsed.key?("result"), "Expected a JSON-RPC result envelope, got: #{parsed.inspect}"
  end

  def test_default_streaming_false_no_accept_returns_json
    app = plain_app
    status, headers, _body = app.call(rack_env)

    assert_equal 200, status
    assert_equal "application/json", headers["Content-Type"]
  end

  # ---------------------------------------------------------------------------
  # 2. streaming: true, no SSE Accept — still returns plain JSON
  # ---------------------------------------------------------------------------

  def test_streaming_true_without_sse_accept_returns_json
    app = streaming_app
    status, headers, _body = app.call(rack_env)

    assert_equal 200, status
    assert_equal "application/json", headers["Content-Type"]
  end

  # ---------------------------------------------------------------------------
  # 3. streaming: true + Accept: text/event-stream — returns SSE Content-Type
  # ---------------------------------------------------------------------------

  def test_streaming_true_with_sse_accept_returns_event_stream_content_type
    app = streaming_app
    status, headers, body = app.call(rack_env(accept: "text/event-stream"))

    body.close if body.respond_to?(:close)
    # Drain to completion so the worker thread cleans up before we assert
    drain_body(body) rescue nil

    assert_equal 200, status
    assert_equal "text/event-stream", headers["Content-Type"]
    assert_equal "no-cache", headers["Cache-Control"]
    assert_equal "keep-alive", headers["Connection"]
    assert_equal "no", headers["X-Accel-Buffering"]
  end

  # ---------------------------------------------------------------------------
  # 4. Streamed body contains at least one progress event and exactly one response
  # ---------------------------------------------------------------------------

  def test_streamed_body_contains_progress_and_response_events
    # Heartbeat every 0.1s; dispatcher sleeps 0.25s so at least 1 heartbeat fires.
    StreamingDispatcherStub.delay = 0.25

    app = streaming_app(heartbeat_interval: 0.1)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)

    progress_events = events.select { |e| e[:event] == "progress" }
    response_events = events.select { |e| e[:event] == "response" }

    assert progress_events.size >= 1,
           "Expected at least 1 progress event, got #{progress_events.size}. " \
           "Events: #{events.map { |e| e[:event] }.inspect}"
    assert_equal 1, response_events.size,
                 "Expected exactly 1 response event, got #{response_events.size}"
  end

  # ---------------------------------------------------------------------------
  # 5. Response event payload matches what plain JSON path would return
  # ---------------------------------------------------------------------------

  def test_response_event_payload_matches_plain_json_response
    fixed = {
      status: 200,
      body: { "jsonrpc" => "2.0", "id" => 7, "result" => { "count" => 42 } },
    }
    StreamingDispatcherStub.response = fixed

    # Plain JSON path
    plain = plain_app
    _s, _h, plain_body = plain.call(rack_env)
    plain_parsed = JSON.parse(drain_body(plain_body).join)

    # SSE path
    app = streaming_app(heartbeat_interval: 0.1)
    _s2, _h2, sse_body_obj = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(sse_body_obj)

    events = parse_sse_chunks(chunks)
    response_event = events.find { |e| e[:event] == "response" }
    refute_nil response_event, "No response event in SSE stream"

    sse_parsed = JSON.parse(response_event[:data])

    assert_equal plain_parsed["jsonrpc"], sse_parsed["jsonrpc"]
    assert_equal plain_parsed["id"],     sse_parsed["id"]
    assert_equal plain_parsed["result"], sse_parsed["result"]
  end

  # ---------------------------------------------------------------------------
  # 6. Unauthorized factory raises BEFORE any SSE stream — returns plain 401 JSON
  # ---------------------------------------------------------------------------

  def test_unauthorized_factory_returns_plain_401_not_sse
    factory = ->(_env) { raise Parse::Agent::Unauthorized, "bad token" }
    app = Parse::Agent::MCPRackApp.new(
      agent_factory:      factory,
      streaming:          true,
      heartbeat_interval: 0.1,
    )

    status, headers, body = app.call(rack_env(accept: "text/event-stream"))

    assert_equal 401, status
    assert_equal "application/json", headers["Content-Type"],
                 "Unauthorized should always return application/json, not SSE"

    parsed = JSON.parse(drain_body(body).join)
    assert_equal(-32_001, parsed.dig("error", "code"))
    assert_equal "Unauthorized", parsed.dig("error", "message")
  end

  # ---------------------------------------------------------------------------
  # 7. No leaked threads after stream completes
  # ---------------------------------------------------------------------------

  def test_no_leaked_threads_after_stream_completes
    require "timeout"

    # Allow the dispatcher to finish quickly so there's nothing to leak.
    StreamingDispatcherStub.delay = 0

    app = streaming_app(heartbeat_interval: 0.1)

    # Snapshot any pre-existing tagged threads BEFORE we make our call.
    # Orphan dispatchers from prior tests (random test order) may still be
    # sleeping; we must not assert on them.
    pre_existing = Thread.list.select { |t| t[:parse_mcp_sse_worker] || t[:parse_mcp_dispatcher] }

    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    drain_body(body)

    # Wait (bounded) for the SSE worker and dispatcher threads spawned by this
    # specific call to exit. We track tagged threads rather than comparing
    # absolute Thread.list counts, which would be fragile when orphaned
    # dispatchers from other tests are still running in the background.
    spawned = Thread.list.select { |t| t[:parse_mcp_sse_worker] || t[:parse_mcp_dispatcher] } - pre_existing
    deadline = Time.now + 10.0
    sleep 0.01 while spawned.any?(&:alive?) && Time.now < deadline

    assert spawned.none?(&:alive?),
           "Expected SSE worker and dispatcher threads to exit after stream completes. " \
           "Still alive: #{spawned.select(&:alive?).map(&:status).inspect}"
  end

  # ---------------------------------------------------------------------------
  # 8. progressToken is read from params._meta.progressToken when supplied
  # ---------------------------------------------------------------------------

  def test_progress_token_from_request_params
    # The client's progressToken is reserved for TOOL-internal progress
    # reports. Heartbeats use a dedicated server-generated token so the
    # elapsed-seconds scale never collides with tool work-unit values
    # on the same progressToken (MCP spec requires per-token monotonicity).
    token = "client-supplied-token-#{SecureRandom.hex(4)}"
    request_body = JSON.generate({
      "jsonrpc" => "2.0",
      "id"      => 10,
      "method"  => "tools/call",
      "params"  => {
        "name"      => "ping",
        "arguments" => {},
        "_meta"     => { "progressToken" => token },
      },
    })

    # Drive one tool-internal progress event so the client's token
    # actually appears on the wire.
    StreamingDispatcherStub.progress_calls = [{ progress: 5, total: 10 }]
    StreamingDispatcherStub.delay = 0.15

    app = streaming_app(heartbeat_interval: 0.05)
    _status, _headers, body = app.call(rack_env(body: request_body, accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)
    progress_events = events.select { |e| e[:event] == "progress" }
    assert progress_events.size >= 1

    tool_progress = progress_events.find { |e| JSON.parse(e[:data]).dig("params", "total") == 10 }
    refute_nil tool_progress, "Expected at least one tool-progress event"
    assert_equal token, JSON.parse(tool_progress[:data]).dig("params", "progressToken"),
                 "Tool-progress events MUST carry the client-supplied progressToken"

    # Heartbeats (when present) MUST carry a different, server-namespaced
    # token — they share the SSE stream but not the progressToken.
    heartbeats = progress_events - [tool_progress]
    heartbeats.each do |hb|
      tok = JSON.parse(hb[:data]).dig("params", "progressToken")
      refute_equal token, tok,
                   "Heartbeats must NOT reuse the client's progressToken"
    end
  end

  # ---------------------------------------------------------------------------
  # 9. Auto-generated progressToken when not supplied
  # ---------------------------------------------------------------------------

  def test_progress_token_auto_generated_when_absent
    StreamingDispatcherStub.delay = 0.25

    app = streaming_app(heartbeat_interval: 0.1)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)
    progress_events = events.select { |e| e[:event] == "progress" }

    assert progress_events.size >= 1, "Expected at least one progress event"

    token = JSON.parse(progress_events.first[:data]).dig("params", "progressToken")
    refute_nil token, "progressToken must be present even when not supplied by client"
    refute_empty token
  end

  # ---------------------------------------------------------------------------
  # 10. Transport-level errors (405/415/413/400) return plain JSON regardless
  # ---------------------------------------------------------------------------

  def test_405_returns_plain_json_regardless_of_accept
    app = streaming_app
    status, headers, _body = app.call(rack_env(method: "GET", accept: "text/event-stream"))
    assert_equal 405, status
    assert_equal "application/json", headers["Content-Type"]
  end

  def test_415_returns_plain_json_regardless_of_accept
    app = streaming_app
    env = rack_env(accept: "text/event-stream", content_type: "text/plain")
    status, headers, _body = app.call(env)
    assert_equal 415, status
    assert_equal "application/json", headers["Content-Type"]
  end

  def test_413_returns_plain_json_regardless_of_accept
    max = Parse::Agent::MCPRackApp::DEFAULT_MAX_BODY_SIZE
    app = streaming_app
    env = rack_env(body: "x" * (max + 1), accept: "text/event-stream")
    status, headers, _body = app.call(env)
    assert_equal 413, status
    assert_equal "application/json", headers["Content-Type"]
  end

  def test_400_returns_plain_json_regardless_of_accept
    app = streaming_app
    env = rack_env(body: "{bad json", accept: "text/event-stream")
    status, headers, _body = app.call(env)
    assert_equal 400, status
    assert_equal "application/json", headers["Content-Type"]
  end

  # ---------------------------------------------------------------------------
  # 11. Progress events carry correct JSON-RPC notification shape
  # ---------------------------------------------------------------------------

  def test_progress_events_have_correct_jsonrpc_notification_shape
    StreamingDispatcherStub.delay = 0.25

    app = streaming_app(heartbeat_interval: 0.1)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)
    progress = events.select { |e| e[:event] == "progress" }

    assert progress.size >= 1

    progress.each do |pe|
      data = JSON.parse(pe[:data])
      assert_equal "2.0",                     data["jsonrpc"]
      assert_equal "notifications/progress",  data["method"]
      assert data["params"].key?("progressToken")
      assert data["params"].key?("progress")
      # `total` is optional per MCP spec and is omitted (not null) when
      # unknown — heartbeats never know a total; tool reports may.
      # progress field must be a number
      assert_kind_of Numeric, data.dig("params", "progress")
    end
  end

  # ---------------------------------------------------------------------------
  # 12. MCPRackApp constructor — streaming keyword accepted without error
  # ---------------------------------------------------------------------------

  def test_constructor_accepts_streaming_keyword
    assert_silent do
      Parse::Agent::MCPRackApp.new(
        agent_factory:               permissive_factory,
        streaming:                   true,
        heartbeat_interval:          1,
        max_concurrent_dispatchers:  100,  # silences the orphan-DoS warning
      )
    end
  end

  def test_constructor_warns_when_streaming_without_concurrency_cap
    warns = capture_warns do
      Parse::Agent::MCPRackApp.new(
        agent_factory:      permissive_factory,
        streaming:          true,
        heartbeat_interval: 1,
      )
    end
    assert_match(/max_concurrent_dispatchers: nil \(unlimited\)/, warns)
  end

  def test_constructor_streaming_defaults_to_false
    # When streaming is false (default), SSE Accept does NOT trigger SSE path
    app = plain_app
    _status, headers, body = app.call(rack_env(accept: "text/event-stream"))
    drain_body(body) rescue nil
    assert_equal "application/json", headers["Content-Type"]
  end

  # ---------------------------------------------------------------------------
  # 13. Worker Thread.kill pushes DONE sentinel — no deadlock
  #
  # Verifies Fix 1: the ensure block in start_worker pushes DONE even when
  # the outer @worker is terminated via Thread.kill (which raises
  # Thread::Termination, an Exception subclass that bypasses rescue => e).
  # ---------------------------------------------------------------------------

  def test_worker_thread_kill_still_pushes_done_and_each_terminates
    require "timeout"

    # Use 1.5s delay: long enough that worker is still alive when killed,
    # short enough that the orphaned dispatcher_thread does not outlive the
    # full test suite run.
    StreamingDispatcherStub.delay = 1.5

    app = streaming_app(heartbeat_interval: 5)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))

    # Start driving #each on a separate thread. SSEBody#each calls start_worker,
    # which spawns @worker tagged with :parse_mcp_sse_worker.
    drain_thread = Thread.new { drain_body(body) }

    # Wait for the worker thread to appear (bounded).
    worker = nil
    Timeout.timeout(2) do
      sleep 0.01 until (worker = Thread.list.find { |t| t[:parse_mcp_sse_worker] && t.alive? })
    end

    refute_nil worker, "Worker thread with :parse_mcp_sse_worker tag must have started"

    # Kill the outer worker thread. Thread.kill raises Thread::Termination, an
    # Exception subclass that bypasses `rescue StandardError => e`, but DOES
    # run `ensure`. The ensure block pushes DONE so drain_thread can exit
    # cleanly — this is the core behaviour added by Fix 1.
    worker.kill

    # drain_thread must terminate within 2 seconds — deadlock here means DONE
    # was never pushed by the ensure block.
    assert drain_thread.join(2), "drain_thread deadlocked after worker Thread.kill — DONE sentinel not pushed"

    # The outer worker thread itself must be gone within 2s.
    Timeout.timeout(2) { sleep 0.01 while worker.alive? }
    refute worker.alive?, "Worker thread must have exited after kill"

    # The dispatcher_thread is intentionally orphaned (cancellation is a
    # separate deferred item). We do NOT assert it terminates here — it
    # will finish on its own after its sleep(1.5) elapses. We only verify
    # the worker is gone.
  end

  # ---------------------------------------------------------------------------
  # 13b. Inner dispatcher_thread death is handled gracefully
  #
  # When the dispatcher_thread is externally killed, `result` stays nil. The
  # outer worker falls through the `while dispatcher_thread.alive?` loop, then
  # attempts `result[:body]` which raises NoMethodError — caught by
  # `rescue StandardError`. The worker then pushes an error envelope + DONE,
  # and drain_thread terminates cleanly. This path worked before Fix 1 but is
  # worth regression-testing explicitly.
  # ---------------------------------------------------------------------------

  def test_dispatcher_thread_kill_outer_worker_recovers_and_pushes_done
    require "timeout"

    StreamingDispatcherStub.delay = 1.5

    app = streaming_app(heartbeat_interval: 5)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))

    drain_thread = Thread.new { drain_body(body) }

    # Wait for the inner dispatcher_thread to appear.
    dispatcher = nil
    Timeout.timeout(2) do
      sleep 0.01 until (dispatcher = Thread.list.find { |t| t[:parse_mcp_dispatcher] && t.alive? })
    end

    refute_nil dispatcher, "Dispatcher thread with :parse_mcp_dispatcher tag must have started"

    # Kill only the inner dispatcher_thread. The outer @worker will see it dead
    # on the next join, find result == nil, raise NoMethodError, catch it in
    # rescue StandardError, and push an error envelope + DONE.
    dispatcher.kill

    # drain_thread must complete — any deadlock means DONE was never pushed.
    assert drain_thread.join(3), "drain_thread deadlocked after dispatcher_thread kill"

    # Collect the events and verify we got an error response (not a real one).
    chunks = []
    begin
      drain_thread.value  # re-raise any exception from drain_thread
    rescue
      # drain_body rescues internally; ignore
    end
  end

  # ---------------------------------------------------------------------------
  # 14. Real heartbeat path: at least 2 heartbeats fire before response
  # ---------------------------------------------------------------------------

  def test_real_heartbeat_fires_multiple_times_before_response
    require "timeout"

    # Pre-declare locals referenced in `ensure` so they're never undefined.
    original_call = nil

    # Deterministic heartbeat test using a mocked waiter and a release-queue
    # dispatcher. No wall-clock timing: the test drives exactly N heartbeats
    # by pushing N tokens onto a tick queue, then releases the dispatcher.
    tick_q    = Queue.new
    release_q = Queue.new

    # Dispatcher blocks until the test releases it.
    StreamingDispatcherStub.delay = 0
    original_call = Parse::Agent::MCPDispatcher.method(:call)
    Parse::Agent::MCPDispatcher.define_singleton_method(:call) do |body:, agent:, logger: nil, progress_callback: nil, cancellation_token: nil|
      release_q.pop
      StreamingDispatcherStub::FIXED_RESPONSE
    end

    # Waiter pops one token per heartbeat iteration. While the dispatcher
    # thread is alive, the waiter blocks here; popping releases one tick.
    Thread.current[:parse_mcp_sse_heartbeat_waiter] = lambda do |dispatcher_thread, _interval|
      tick_q.pop
      nil
    end

    app = streaming_app(heartbeat_interval: 0.1)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))

    # Drive the stream in a background thread so we can push ticks and a
    # release signal from the test thread.
    chunks = []
    reader = Thread.new do
      Thread.current.abort_on_exception = false
      body.each { |c| chunks << c }
    rescue => e
      warn "reader error: #{e.class}: #{e.message}"
    end

    # Push 3 ticks → 3 heartbeats. Each tick unblocks the waiter, which
    # then returns to the loop; dispatcher is still blocked on release_q
    # so dispatcher_thread.alive? remains true and a progress event fires.
    3.times { tick_q << :tick }

    # Wait for 3 progress events to appear before releasing the dispatcher,
    # so we know all 3 ticks have been consumed (avoids a race where the
    # release happens before the heartbeat loop has drained the ticks).
    Timeout.timeout(5) do
      sleep 0.01 until parse_sse_chunks(chunks).count { |e| e[:event] == "progress" } >= 3
    end

    # Release the dispatcher; it returns FIXED_RESPONSE. The worker is
    # blocked in the waiter on tick_q.pop. There is an inherent race: after
    # the waiter returns, the worker re-checks dispatcher_thread.alive?, and
    # if the dispatcher hasn't yet finished its rescue/return, the worker
    # will emit one more progress event and loop back into the waiter. So
    # rather than pushing exactly one tick (which can deadlock if the race
    # plays out adversely on CI), we keep feeding ticks until the reader
    # thread exits — once dispatcher_thread is dead, the next loop iteration
    # observes that, pushes response + DONE, and the reader drains.
    release_q << :go
    Timeout.timeout(10) do
      until reader.join(0.05)
        tick_q << :tick
      end
    end

    events = parse_sse_chunks(chunks)
    progress_events = events.select { |e| e[:event] == "progress" }
    response_events = events.select { |e| e[:event] == "response" }

    assert progress_events.size >= 2,
           "Expected >=2 heartbeat events from 3 ticks, got " \
           "#{progress_events.size}. Events: #{events.map { |e| e[:event] }.inspect}"
    assert_equal 1, response_events.size, "Expected exactly 1 response event"

    # Verify both worker and dispatcher threads are gone within 2s. After
    # drain_body returns, the dispatcher has already finished (the response
    # event could only have been emitted once the dispatcher returned). The
    # worker thread may briefly be in its ensure block or aborting state;
    # give it 2s to fully exit.
    tagged_threads = Thread.list.select { |t| t[:parse_mcp_sse_worker] || t[:parse_mcp_dispatcher] }
    Timeout.timeout(2) { sleep 0.01 while tagged_threads.any?(&:alive?) } rescue nil
    assert tagged_threads.none?(&:alive?),
           "Tagged threads still alive 2s after stream completed: #{tagged_threads.map(&:status).inspect}"
  ensure
    Thread.current[:parse_mcp_sse_heartbeat_waiter] = nil
    if original_call
      Parse::Agent::MCPDispatcher.define_singleton_method(:call, &original_call)
    end
  end

  # ---------------------------------------------------------------------------
  # 15. Client disconnect mid-stream: all spawned threads terminate within 0.5s
  # ---------------------------------------------------------------------------

  def test_client_disconnect_mid_stream_no_leaked_threads
    require "timeout"

    # Long enough dispatcher so the stream is still active when we disconnect,
    # but short enough to limit orphan-thread lifetime in the test suite.
    StreamingDispatcherStub.delay = 1.5

    app = streaming_app(heartbeat_interval: 0.1)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))

    threads_before = Thread.list.size

    # Partially drain (receive one event) then close — simulates client disconnect.
    received = []
    drain_thread = Thread.new do
      body.each do |chunk|
        received << chunk
        break  # disconnect after first chunk
      end
    end

    drain_thread.join(2)

    # After close, the worker should be killed. The dispatcher_thread is
    # orphaned (cancellation is a separate deferred item) but will run to
    # completion naturally. Poll with a generous deadline — Thread#kill
    # propagation timing varies across Ruby versions and CI runners; the
    # contract is "eventually," not a tight wall-clock bound.
    deadline = Time.now + 10.0
    sleep 0.01 while Thread.list.any? { |t| t[:parse_mcp_sse_worker] && t.alive? } &&
                     Time.now < deadline

    assert Thread.list.none? { |t| t[:parse_mcp_sse_worker] && t.alive? },
           "Worker thread still alive 10s after client disconnect"
  end

  # ---------------------------------------------------------------------------
  # 16. max_concurrent_dispatchers cap: second concurrent request returns 503
  # ---------------------------------------------------------------------------

  def test_max_concurrent_dispatchers_returns_503_when_limit_reached
    require "timeout"

    # Dispatcher is slow so the first request's dispatcher_thread stays alive
    # when the second request arrives. 1.5s is long enough for the test to
    # complete while limiting orphan lifetime in the test suite.
    StreamingDispatcherStub.delay = 1.5

    app = streaming_app(heartbeat_interval: 0.1, max_concurrent_dispatchers: 1)

    # Fire request 1 in a background thread to keep the SSE stream open.
    req1_body = nil
    t1 = nil
    t1 = Thread.new do
      _s, _h, req1_body = app.call(rack_env(accept: "text/event-stream"))
      # Start driving #each so the dispatcher_thread actually spawns and gets tagged.
      req1_body.each { |_chunk| break }  # disconnect after first chunk
    end

    # Wait for the dispatcher_thread from request 1 to appear and be tagged.
    Timeout.timeout(2) do
      sleep 0.01 until Parse::Agent::MCPRackApp.active_dispatcher_count >= 1
    end

    # Now fire request 2 — it should be rejected with 503.
    status2, headers2, body2 = app.call(rack_env(accept: "text/event-stream"))

    assert_equal 503, status2,
                 "Second concurrent request must receive 503 when cap is 1"
    assert_equal "application/json", headers2["Content-Type"],
                 "503 response must use application/json"

    parsed2 = JSON.parse(body2.first)
    assert_equal "2.0",        parsed2["jsonrpc"]
    assert_equal(-32_000,      parsed2.dig("error", "code"))
    assert_equal "server busy", parsed2.dig("error", "message")
  ensure
    # Clean up: kill any lingering SSE body so the slow dispatcher finishes.
    (req1_body&.close rescue nil)
    t1&.kill if t1&.alive?
    (t1&.join(1) rescue nil)
  end

  # ---------------------------------------------------------------------------
  # 17. active_dispatcher_count class method
  # ---------------------------------------------------------------------------

  def test_active_dispatcher_count_returns_integer
    count = Parse::Agent::MCPRackApp.active_dispatcher_count
    assert_kind_of Integer, count
    assert count >= 0
  end

  def test_active_dispatcher_count_tracks_live_dispatchers
    require "timeout"

    # Slow enough dispatcher to observe the tagged thread in flight,
    # short enough to limit orphan lifetime.
    StreamingDispatcherStub.delay = 1.5

    app = streaming_app(heartbeat_interval: 0.2)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))

    drain_thread = Thread.new { drain_body(body) }

    # Wait for the dispatcher_thread to appear.
    Timeout.timeout(2) do
      sleep 0.01 until Parse::Agent::MCPRackApp.active_dispatcher_count >= 1
    end

    assert Parse::Agent::MCPRackApp.active_dispatcher_count >= 1,
           "active_dispatcher_count should be >=1 while dispatcher is running"

    # Disconnect — kills worker, orphans dispatcher_thread.
    body.close

    drain_thread.kill
    drain_thread.join(1) rescue nil
  end

  # ---------------------------------------------------------------------------
  # 18. Response headers must be mutable per-response on the SSE 200 path and
  # the 503 server-busy path. Same regression class as the JSON-path coverage
  # in mcp_rack_app_test.rb (4.1.2 frozen-headers fix): downstream Rack
  # middleware decorates response headers, so returning the frozen
  # SSE_HEADERS / JSON_CONTENT_TYPE constants directly raises FrozenError.
  # ---------------------------------------------------------------------------

  def test_sse_200_response_headers_are_not_frozen
    app = streaming_app
    body = nil
    _status, headers, body = app.call(rack_env(accept: "text/event-stream"))

    refute headers.frozen?,
           "SSE 200 response headers must be mutable for Rack middleware composability"
    headers["X-Decorator"] = "ok"  # would raise FrozenError under the old behavior
    assert_equal "ok", headers["X-Decorator"]
  ensure
    (body&.close rescue nil)
    (drain_body(body) rescue nil) if defined?(body) && body
  end

  def test_server_busy_503_response_headers_are_not_frozen
    require "timeout"

    StreamingDispatcherStub.delay = 1.5
    app = streaming_app(heartbeat_interval: 0.1, max_concurrent_dispatchers: 1)

    req1_body = nil
    t1 = nil
    t1 = Thread.new do
      _s, _h, req1_body = app.call(rack_env(accept: "text/event-stream"))
      req1_body.each { |_chunk| break }
    end

    Timeout.timeout(2) do
      sleep 0.01 until Parse::Agent::MCPRackApp.active_dispatcher_count >= 1
    end

    _status, headers, _body = app.call(rack_env(accept: "text/event-stream"))

    refute headers.frozen?,
           "503 server-busy response headers must be mutable for Rack middleware composability"
    headers["X-Decorator"] = "ok"
    assert_equal "ok", headers["X-Decorator"]
  ensure
    (req1_body&.close rescue nil)
    t1&.kill if t1&.alive?
    (t1&.join(1) rescue nil)
  end

  # ---------------------------------------------------------------------------
  # 19. Tool-internal progress reporting (v4.2)
  #
  # Verifies that progress_callback wired by serve_sse → SSEBody reaches the
  # dispatcher and that events emitted through it land on the SSE wire with
  # the correct `notifications/progress` shape.
  # ---------------------------------------------------------------------------

  def test_tool_internal_progress_event_reaches_sse_stream
    StreamingDispatcherStub.progress_calls = [
      { progress: 25, total: 100, message: "Fetching" },
      { progress: 75, total: 100, message: "Aggregating" },
    ]
    StreamingDispatcherStub.delay = 0.05

    app = streaming_app(heartbeat_interval: 5)  # heartbeat disabled in practice
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)
    progress_events = events.select { |e| e[:event] == "progress" }
    response_events = events.select { |e| e[:event] == "response" }

    assert_equal 2, progress_events.size,
                 "Expected exactly 2 tool-progress events, got #{progress_events.size}"
    assert_equal 1, response_events.size

    first = JSON.parse(progress_events[0][:data])
    assert_equal "2.0",                    first["jsonrpc"]
    assert_equal "notifications/progress", first["method"]
    assert_equal 25,                       first.dig("params", "progress")
    assert_equal 100,                      first.dig("params", "total")
    assert_equal "Fetching",               first.dig("params", "message")
    assert first["params"].key?("progressToken")

    second = JSON.parse(progress_events[1][:data])
    assert_equal 75,           second.dig("params", "progress")
    assert_equal 100,          second.dig("params", "total")
    assert_equal "Aggregating", second.dig("params", "message")
  end

  def test_tool_progress_omits_message_when_nil
    StreamingDispatcherStub.progress_calls = [{ progress: 10 }]
    StreamingDispatcherStub.delay = 0.05

    app = streaming_app(heartbeat_interval: 5)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)
    progress = events.find { |e| e[:event] == "progress" }
    refute_nil progress

    data = JSON.parse(progress[:data])
    refute data["params"].key?("message"),
           "`message` field must be omitted from wire when nil"
    assert_equal 10,  data.dig("params", "progress")
    assert_nil       data.dig("params", "total")
  end

  def test_tool_progress_suppresses_subsequent_heartbeats
    # Let one heartbeat fire (pre_progress_delay > heartbeat_interval), then
    # tool reports progress, then the dispatcher delays further (so more
    # heartbeats would have fired if not suppressed).
    StreamingDispatcherStub.pre_progress_delay = 0.15  # 1 heartbeat at 0.1s interval
    StreamingDispatcherStub.progress_calls     = [{ progress: 50, total: 100 }]
    StreamingDispatcherStub.delay              = 0.5   # would fit 5 more heartbeats

    app = streaming_app(heartbeat_interval: 0.1)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)
    progress_events = events.select { |e| e[:event] == "progress" }

    # Heartbeats are distinguished by their dedicated `parse-stack:heartbeat:*`
    # progressToken; tool reports use the request progressToken.
    heartbeats   = progress_events.select { |e|
      JSON.parse(e[:data]).dig("params", "progressToken").to_s.start_with?("parse-stack:heartbeat:")
    }
    tool_reports = progress_events - heartbeats

    assert tool_reports.size >= 1,
           "Expected at least 1 tool-progress event, got #{tool_reports.size}"
    # At most one heartbeat should have fired (the one BEFORE the tool
    # reported). After the tool report, the suppression flag stops all
    # further heartbeats even though the dispatcher continues for ~0.5s.
    assert heartbeats.size <= 1,
           "Expected at most 1 heartbeat before tool progress took over, got #{heartbeats.size}. " \
           "Events: #{progress_events.map { |e| JSON.parse(e[:data]).dig('params') }.inspect}"
  end

  def test_tool_progress_uses_request_progress_token
    token = "supplied-#{SecureRandom.hex(4)}"
    request_body = JSON.generate({
      "jsonrpc" => "2.0", "id" => 99, "method" => "tools/call",
      "params"  => {
        "name"      => "any_tool",
        "arguments" => {},
        "_meta"     => { "progressToken" => token },
      },
    })

    StreamingDispatcherStub.progress_calls = [{ progress: 1, total: 2 }]
    StreamingDispatcherStub.delay = 0.05

    app = streaming_app(heartbeat_interval: 5)
    _status, _headers, body = app.call(rack_env(body: request_body, accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)
    progress = events.find { |e| e[:event] == "progress" }
    refute_nil progress

    data = JSON.parse(progress[:data])
    assert_equal token, data.dig("params", "progressToken"),
                 "Tool-progress events must carry the client-supplied progressToken"
  end

  def test_progress_callback_exceptions_do_not_break_stream
    # First call raises inside the callback boundary; second is well-formed.
    # The stream should still deliver the second event and the response.
    raising_call_done = false
    StreamingDispatcherStub.progress_calls = [
      { progress: "not-numeric" },  # invalid kwarg — but the callback itself
                                    # accepts anything; the stream encoder
                                    # handles non-numeric gracefully.
      { progress: 10, total: 20 },
    ]
    StreamingDispatcherStub.delay = 0.05

    app = streaming_app(heartbeat_interval: 5)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)
    response = events.find { |e| e[:event] == "response" }
    refute_nil response, "Final response event must still arrive after callback edge cases"
    raising_call_done = true
    assert raising_call_done
  end

  # ---------------------------------------------------------------------------
  # 20. Cancellation (v4.2)
  # ---------------------------------------------------------------------------

  def test_cancellation_token_is_installed_on_agent_during_dispatch
    captured = nil
    # Capture the token the dispatcher receives so we can verify
    # MCPRackApp constructed and passed one along.
    StreamingDispatcherStub.delay = 0.05

    app = streaming_app(heartbeat_interval: 5)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    drain_body(body)

    captured = StreamingDispatcherStub.last_cancellation_token
    refute_nil captured, "Streaming dispatch must receive a CancellationToken"
    assert_kind_of Parse::Agent::CancellationToken, captured
    refute captured.cancelled?, "Token must not be tripped on a normal dispatch"
  end

  def test_client_disconnect_trips_cancellation_token
    require "timeout"
    StreamingDispatcherStub.delay = 1.5  # long dispatcher so close trips token mid-flight

    app = streaming_app(heartbeat_interval: 0.1)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))

    # Drive #each on a thread so the dispatcher_thread actually spawns
    # (the token is only passed to the dispatcher inside start_worker).
    drain_thread = nil
    drain_thread = Thread.new { body.each { |_| break } }

    # Wait until the dispatcher has been entered (so the token reaches it).
    Timeout.timeout(2) do
      sleep 0.01 until StreamingDispatcherStub.last_cancellation_token
    end
    token = StreamingDispatcherStub.last_cancellation_token

    drain_thread.join(2) rescue nil

    body.close

    assert token.cancelled?, "Token must be tripped after client disconnect"
    assert_equal :client_disconnect, token.reason
  ensure
    drain_thread&.kill
  end

  def test_notifications_cancelled_trips_matching_in_flight_token
    require "timeout"
    session_id = "test-session-#{SecureRandom.hex(4)}"
    request_id = 4242

    StreamingDispatcherStub.delay = 1.5

    app = streaming_app(heartbeat_interval: 0.1)

    # Fire the original request with Mcp-Session-Id and a known request id.
    req1_body = JSON.generate({ "jsonrpc" => "2.0", "id" => request_id, "method" => "tools/call",
                                "params" => { "name" => "any", "arguments" => {} } })
    env1 = rack_env(body: req1_body, accept: "text/event-stream")
    env1["HTTP_MCP_SESSION_ID"] = session_id

    sse_body = nil
    t1 = nil
    t1 = Thread.new do
      _s, _h, sse_body = app.call(env1)
      sse_body.each { |_| break }  # drive #each to spawn dispatcher_thread
    end

    # Wait for the dispatcher to receive the token (registration also happens
    # before this point in serve_sse, but we use the dispatcher entry as a
    # synchronization marker).
    Timeout.timeout(2) do
      sleep 0.01 until StreamingDispatcherStub.last_cancellation_token
    end
    token = StreamingDispatcherStub.last_cancellation_token

    # Now send notifications/cancelled with the same session id.
    cancel_body = JSON.generate({
      "jsonrpc" => "2.0",
      "method"  => "notifications/cancelled",
      "params"  => { "requestId" => request_id, "reason" => "user pressed stop" },
    })
    env2 = rack_env(body: cancel_body)
    env2["HTTP_MCP_SESSION_ID"] = session_id

    status, _headers, cancel_resp = app.call(env2)
    assert_equal 202, status, "notifications/cancelled must return 202 with empty body"
    assert_equal [""], cancel_resp.to_a, "Body must be empty for the notification"

    assert token.cancelled?, "Token must be tripped after notifications/cancelled with matching session"
    assert_equal :notifications_cancelled, token.reason
  ensure
    sse_body&.close
    t1&.kill
    t1&.join(1) rescue nil
  end

  def test_notifications_cancelled_with_wrong_session_id_is_silent_noop
    require "timeout"
    session_id_a = "session-a-#{SecureRandom.hex(4)}"
    session_id_b = "session-b-#{SecureRandom.hex(4)}"
    request_id   = 7777

    StreamingDispatcherStub.delay = 1.5

    app = streaming_app(heartbeat_interval: 0.1)

    req_body = JSON.generate({ "jsonrpc" => "2.0", "id" => request_id, "method" => "tools/call",
                               "params" => { "name" => "any", "arguments" => {} } })
    env1 = rack_env(body: req_body, accept: "text/event-stream")
    env1["HTTP_MCP_SESSION_ID"] = session_id_a

    sse_body = nil
    t1 = nil
    t1 = Thread.new do
      _s, _h, sse_body = app.call(env1)
      sse_body.each { |_| break }
    end

    Timeout.timeout(2) do
      sleep 0.01 until StreamingDispatcherStub.last_cancellation_token
    end
    token = StreamingDispatcherStub.last_cancellation_token

    # Send notifications/cancelled with a DIFFERENT session id.
    cancel_body = JSON.generate({
      "jsonrpc" => "2.0",
      "method"  => "notifications/cancelled",
      "params"  => { "requestId" => request_id },
    })
    env2 = rack_env(body: cancel_body)
    env2["HTTP_MCP_SESSION_ID"] = session_id_b

    status, _headers, _body = app.call(env2)
    assert_equal 202, status, "Response is still 202 (silent no-op, no probe oracle)"

    refute token.cancelled?,
           "Cross-session cancellation must NOT trip the token (identity binding)"
  ensure
    sse_body&.close
    t1&.kill
    t1&.join(1) rescue nil
  end

  def test_notifications_cancelled_without_session_id_is_silent_noop
    require "timeout"
    session_id = "owner-#{SecureRandom.hex(4)}"
    request_id = 8888

    StreamingDispatcherStub.delay = 1.5

    app = streaming_app(heartbeat_interval: 0.1)

    req_body = JSON.generate({ "jsonrpc" => "2.0", "id" => request_id, "method" => "tools/call",
                               "params" => { "name" => "any", "arguments" => {} } })
    env1 = rack_env(body: req_body, accept: "text/event-stream")
    env1["HTTP_MCP_SESSION_ID"] = session_id

    sse_body = nil
    t1 = nil
    t1 = Thread.new do
      _s, _h, sse_body = app.call(env1)
      sse_body.each { |_| break }
    end

    Timeout.timeout(2) do
      sleep 0.01 until StreamingDispatcherStub.last_cancellation_token
    end
    token = StreamingDispatcherStub.last_cancellation_token

    # No Mcp-Session-Id header on the cancel.
    cancel_body = JSON.generate({
      "jsonrpc" => "2.0",
      "method"  => "notifications/cancelled",
      "params"  => { "requestId" => request_id },
    })
    status, _headers, _body = app.call(rack_env(body: cancel_body))
    assert_equal 202, status

    refute token.cancelled?,
           "Cancellation without session id must NOT trip any token"
  ensure
    sse_body&.close
    t1&.kill
    t1&.join(1) rescue nil
  end

  def test_cancellation_registry_deregisters_on_normal_completion
    require "timeout"
    StreamingDispatcherStub.delay = 0.05

    app = streaming_app(heartbeat_interval: 5)
    registry = app.instance_variable_get(:@cancellation_registry)
    initial = registry.size

    env = rack_env(accept: "text/event-stream")
    env["HTTP_MCP_SESSION_ID"] = "test-session-#{SecureRandom.hex(4)}"

    _s, _h, body = app.call(env)
    drain_body(body)

    Timeout.timeout(2) { sleep 0.01 until registry.size == initial }
    assert_equal initial, registry.size,
                 "Registry must shrink back to its initial size after the request completes"
  end

  def test_cancelled_dispatcher_response_still_emits_response_event
    # Per the design (advisor option A), a cancelled stream still ends with
    # a response event so clients don't have to distinguish "cancelled" from
    # "network died". The stub returns a normal response; the SSE wire shape
    # should still include the response event regardless of cancellation
    # timing.
    StreamingDispatcherStub.delay = 0.05

    app = streaming_app(heartbeat_interval: 5)
    _s, _h, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)
    events = parse_sse_chunks(chunks)
    assert events.any? { |e| e[:event] == "response" },
           "Stream must always end with a response event"
  end

  def test_json_path_callback_is_nil_in_dispatcher
    # No tool can emit SSE events when the transport is JSON. The dispatcher
    # must be invoked with progress_callback: nil on the JSON path.
    captured = nil
    StreamingDispatcherStub.progress_calls = []
    original_call = Parse::Agent::MCPDispatcher.method(:call)
    Parse::Agent::MCPDispatcher.define_singleton_method(:call) do |body:, agent:, logger: nil, progress_callback: nil, cancellation_token: nil|
      captured = progress_callback
      StreamingDispatcherStub::FIXED_RESPONSE
    end

    begin
      app = plain_app
      app.call(rack_env)  # plain JSON path
      assert_nil captured, "JSON path must invoke dispatcher with progress_callback: nil"
    ensure
      Parse::Agent::MCPDispatcher.define_singleton_method(:call, &original_call)
    end
  end

  # ---------------------------------------------------------------------------
  # 21. listChanged notifications via SSE (v4.2)
  #
  # Registering or unregistering a tool/prompt mid-stream should push a
  # notifications/tools/list_changed (or .../prompts/list_changed) SSE event
  # onto the active wire. Verifies the Tools.subscribe / Prompts.subscribe
  # broadcast machinery and the SSEBody subscription lifecycle.
  # ---------------------------------------------------------------------------

  def test_tools_register_pushes_list_changed_onto_active_stream
    require "timeout"

    # Long-running dispatcher so we have time to register a tool mid-stream.
    StreamingDispatcherStub.delay = 0.6

    app = streaming_app(heartbeat_interval: 5)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))

    chunks = []
    drain_thread = nil
    drain_thread = Thread.new { body.each { |c| chunks << c } }

    # Wait for the dispatcher_thread (and therefore the SSEBody subscription)
    # to be live before mutating the registry.
    deadline = Time.now + 10.0
    sleep 0.01 until StreamingDispatcherStub.last_cancellation_token || Time.now >= deadline

    Parse::Agent::Tools.register(
      name:        :__test_list_changed_tool,
      description: "test fixture",
      parameters:  { "type" => "object", "properties" => {} },
      permission:  :readonly,
      handler:     ->(_a, **) { {} },
    )

    drain_thread.join(3)

    events = parse_sse_chunks(chunks)
    tools_changed = events.select do |e|
      e[:event] == "message" &&
        JSON.parse(e[:data])["method"] == "notifications/tools/list_changed"
    end
    assert tools_changed.size >= 1,
           "Expected at least 1 tools/list_changed event after Tools.register, " \
           "got #{tools_changed.size}. Events: #{events.map { |e| e[:event] }.inspect}"

    payload = JSON.parse(tools_changed.first[:data])
    assert_equal "2.0",                              payload["jsonrpc"]
    assert_equal "notifications/tools/list_changed", payload["method"]
    refute payload.key?("id"), "Notifications must not carry an id"
    refute payload.key?("params"),
           "tools/list_changed has no params per spec"
  ensure
    Parse::Agent::Tools.reset_registry!
    Parse::Agent::Tools.reset_subscribers!
    drain_thread&.kill
  end

  def test_prompts_register_pushes_list_changed_onto_active_stream
    require "timeout"

    StreamingDispatcherStub.delay = 0.6

    app = streaming_app(heartbeat_interval: 5)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))

    chunks = []
    drain_thread = nil
    drain_thread = Thread.new { body.each { |c| chunks << c } }

    deadline = Time.now + 10.0
    sleep 0.01 until StreamingDispatcherStub.last_cancellation_token || Time.now >= deadline

    Parse::Agent::Prompts.register(
      name:        "__test_list_changed_prompt",
      description: "test fixture",
      arguments:   [],
      renderer:    ->(_args) { "hello" },
    )

    drain_thread.join(3)

    events = parse_sse_chunks(chunks)
    prompts_changed = events.select do |e|
      e[:event] == "message" &&
        JSON.parse(e[:data])["method"] == "notifications/prompts/list_changed"
    end
    assert prompts_changed.size >= 1, "Expected at least 1 prompts/list_changed event"
  ensure
    Parse::Agent::Prompts.reset_registry!
    Parse::Agent::Prompts.reset_subscribers!
    drain_thread&.kill
  end

  def test_subscribers_deregister_after_stream_close
    StreamingDispatcherStub.delay = 0.05

    app = streaming_app(heartbeat_interval: 5)
    _s, _h, body = app.call(rack_env(accept: "text/event-stream"))
    drain_body(body)

    # After the stream closed, registering a tool must NOT push events
    # anywhere (we'd already be subscribed-zero). Indirect assertion:
    # if subscribers leaked, Tools.notify_subscribers would invoke a
    # callback that pushes into a closed/empty queue. We just verify
    # subscribe count is back to zero by registering and asserting no
    # exception/no leak.
    subscribers_before = Parse::Agent::Tools.instance_variable_get(:@subscribers).size
    Parse::Agent::Tools.register(
      name: :__test_post_close_register, description: "x",
      parameters: { "type" => "object" }, permission: :readonly,
      handler: ->(_a, **) { {} },
    )
    subscribers_after = Parse::Agent::Tools.instance_variable_get(:@subscribers).size
    assert_equal subscribers_before, subscribers_after,
                 "Stream close must deregister its tools subscriber"
  ensure
    Parse::Agent::Tools.reset_registry!
    Parse::Agent::Tools.reset_subscribers!
  end

  # ---------------------------------------------------------------------------
  # v4.2 follow-up safety fixes
  # ---------------------------------------------------------------------------

  def test_heartbeat_uses_distinct_token_from_tool_progress_token
    # No tool report — only heartbeats fire. The heartbeat token must
    # NOT match the client-supplied progressToken (MCP spec requires
    # per-token monotonicity; mixing elapsed-seconds heartbeats with
    # tool work-unit values on the same token would violate that).
    client_token = "client-#{SecureRandom.hex(4)}"
    request_body = JSON.generate({
      "jsonrpc" => "2.0", "id" => 1, "method" => "ping",
      "params"  => { "_meta" => { "progressToken" => client_token } },
    })

    StreamingDispatcherStub.delay = 0.25

    app = streaming_app(heartbeat_interval: 0.1)
    _s, _h, body = app.call(rack_env(body: request_body, accept: "text/event-stream"))
    chunks = drain_body(body)

    progress_events = parse_sse_chunks(chunks).select { |e| e[:event] == "progress" }
    assert progress_events.size >= 1, "Expected at least one heartbeat"

    progress_events.each do |pe|
      tok = JSON.parse(pe[:data]).dig("params", "progressToken")
      refute_equal client_token, tok,
                   "Heartbeats must use a dedicated server-generated progressToken, not the client's"
      assert_match(/\Aparse-stack:heartbeat:/, tok,
                   "Heartbeat progressToken must be namespaced for clients to recognize")
    end
  end

  def test_heartbeat_omits_total_field
    StreamingDispatcherStub.delay = 0.25
    app = streaming_app(heartbeat_interval: 0.1)
    _s, _h, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)

    progress_events = parse_sse_chunks(chunks).select { |e| e[:event] == "progress" }
    assert progress_events.size >= 1

    progress_events.each do |pe|
      params = JSON.parse(pe[:data])["params"]
      refute params.key?("total"),
             "Heartbeat must omit `total` rather than emit `total: null` (matches spec optional-field convention)"
    end
  end

  def test_tool_progress_omits_total_when_nil
    StreamingDispatcherStub.progress_calls = [{ progress: 7 }]
    StreamingDispatcherStub.delay = 0.05

    app = streaming_app(heartbeat_interval: 5)
    _s, _h, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)

    progress = parse_sse_chunks(chunks).find { |e| e[:event] == "progress" }
    refute_nil progress
    params = JSON.parse(progress[:data])["params"]
    refute params.key?("total"),
           "Tool-progress event must omit `total` rather than send `total: null` when the tool did not supply one"
  end

  def test_cancellation_registry_collision_uses_entry_id_to_avoid_evicting_sibling
    reg = Parse::Agent::MCPRackApp::CancellationRegistry.new
    tok_a = Parse::Agent::CancellationToken.new
    tok_b = Parse::Agent::CancellationToken.new

    eid_a = reg.register("sid", 1, tok_a)
    eid_b = reg.register("sid", 1, tok_b)
    refute_nil eid_a
    refute_nil eid_b
    refute_equal eid_a, eid_b, "Each registration must get a unique entry_id"

    # tok_b currently owns the slot. Deregistering with tok_a's entry_id
    # must NOT evict tok_b.
    assert_equal false, reg.deregister("sid", 1, eid_a),
                 "Stale deregister must not remove the sibling registration"

    # notifications/cancelled must trip tok_b (the current slot owner).
    reg.cancel("sid", 1, reason: :test)
    assert tok_b.cancelled?
    refute tok_a.cancelled?, "tok_a was overwritten by tok_b in the slot; cancel must reach the current owner only"

    # tok_b's owner can still release the slot cleanly.
    assert_equal true, reg.deregister("sid", 1, eid_b)
    assert_equal 0, reg.size
  end

  def test_cancellation_registry_rejects_registration_without_correlation_id
    reg = Parse::Agent::MCPRackApp::CancellationRegistry.new
    tok = Parse::Agent::CancellationToken.new
    assert_nil reg.register(nil, 1, tok),
               "register must return nil when correlation_id is nil (cancellation disabled)"
    assert_nil reg.register("", 1, tok)
    assert_equal 0, reg.size
  end

  def test_sse_body_close_is_idempotent_under_concurrent_calls
    # Build an SSEBody directly so we can drain it to completion before
    # racing close — that exercises the mutex's "second-caller no-op"
    # path without the worker-startup race that the integration path
    # would introduce.
    token = Parse::Agent::CancellationToken.new
    body  = Parse::Agent::MCPRackApp::SSEBody.new(
      "tok", 1, 5, nil, cancellation_token: token
    ) do |_pc|
      { status: 200, body: { "jsonrpc" => "2.0", "id" => 1, "result" => {} } }
    end
    drain_body(body)  # completes normally

    # N concurrent closes — only the first wins the mutex and runs the
    # cleanup body; the rest must short-circuit on @closed.
    threads = 4.times.map { Thread.new { body.close } }
    threads.each(&:join)
    body.close  # final no-op

    refute token.cancelled?,
           "Idempotent close after normal completion must not trip the cancellation token"
  end

  def test_sse_body_close_does_not_trip_cancellation_token_on_normal_completion
    token = Parse::Agent::CancellationToken.new
    sse_body = Parse::Agent::MCPRackApp::SSEBody.new(
      "tok", 1, 5, nil, cancellation_token: token
    ) do |_pc|
      { status: 200, body: { "jsonrpc" => "2.0", "id" => 1, "result" => {} } }
    end
    drain_body(sse_body)
    refute token.cancelled?, "Normal completion must NOT trip cancellation token"
    sse_body.close  # idempotent
    refute token.cancelled?
  end
end
