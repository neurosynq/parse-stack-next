# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/live_query"

# Contract for the lifetime of the ambient identity set by Parse.with_session,
# Parse.with_master_key and Parse.without_master_key, and for
# Parse.without_ambient_identity. See "Ambient identity lifetime" on
# Parse.with_session.
class SessionScopeLifetime584Test < Minitest::Test
  TOKEN = "r:session-584"

  def snapshot
    [
      Fiber[Parse::SESSION_TOKEN_STATE_KEY],
      Fiber[Parse::MASTER_KEY_STATE_KEY],
      Fiber[Parse::INNERMOST_AUTH_BLOCK_KEY],
    ]
  end

  # (a) restore on return and on raise
  def test_with_session_restores_on_return
    before = snapshot
    Parse.with_session(TOKEN) { assert_equal TOKEN, Parse.current_session_token }
    assert_equal before, snapshot
    assert_nil Parse.current_session_token
  end

  def test_with_session_restores_on_raise
    before = snapshot
    assert_raises(RuntimeError) do
      Parse.without_master_key do
        Parse.with_session(TOKEN) { raise "boom" }
      end
    end
    assert_equal before, snapshot
    refute Parse.master_key_disabled?
  end

  def test_nested_blocks_restore_enclosing_values
    Parse.with_session("r:outer") do
      Parse.with_master_key do
        Parse.with_session(TOKEN) { assert_equal TOKEN, Parse.current_session_token }
        assert_equal :enabled, Fiber[Parse::MASTER_KEY_STATE_KEY]
        assert_equal :master, Fiber[Parse::INNERMOST_AUTH_BLOCK_KEY]
      end
      assert_equal "r:outer", Parse.current_session_token
      assert_equal :session, Fiber[Parse::INNERMOST_AUTH_BLOCK_KEY]
    end
  end

  # (b) a reused worker thread does not carry identity between jobs
  def test_reused_worker_thread_does_not_carry_identity_between_jobs
    jobs = Queue.new
    results = Queue.new
    worker = Thread.new do
      while (job = jobs.pop) != :stop
        results << job.call
      end
    end

    jobs << -> { Parse.with_session(TOKEN) { Parse.current_session_token } }
    jobs << -> { [Parse.current_session_token, Fiber[Parse::INNERMOST_AUTH_BLOCK_KEY]] }
    jobs << -> {
      begin
        Parse.with_session(TOKEN) { raise "job failed" }
      rescue RuntimeError
        :rescued
      end
    }
    jobs << -> { [Parse.current_session_token, Fiber[Parse::INNERMOST_AUTH_BLOCK_KEY]] }
    jobs << :stop
    worker.join(5)

    assert_equal TOKEN, results.pop
    assert_equal [nil, nil], results.pop
    assert_equal :rescued, results.pop
    assert_equal [nil, nil], results.pop
  end

  # (c) documented inheritance into threads and fibers created in the block
  def test_thread_created_inside_with_session_inherits_token
    seen = nil
    t = nil
    Parse.with_session(TOKEN) do
      t = Thread.new { Thread.stop; seen = Parse.current_session_token }
    end
    # The block has exited; the child keeps its copy for its lifetime.
    Thread.pass until t.stop?
    t.wakeup
    t.join(5)
    assert_equal TOKEN, seen
  end

  def test_fiber_created_inside_with_session_inherits_token
    fiber = nil
    Parse.with_session(TOKEN) { fiber = Fiber.new { Parse.current_session_token } }
    assert_equal TOKEN, fiber.resume
  end

  # (d) without_ambient_identity clears and restores all three keys
  def test_without_ambient_identity_clears_and_restores
    Parse.with_session(TOKEN) do
      Parse.without_master_key do
        Parse.with_master_key do
          before = snapshot
          refute_nil before[0]
          refute_nil before[1]
          refute_nil before[2]
          Parse.without_ambient_identity do
            assert_equal [nil, nil, nil], snapshot
            assert_nil Parse.current_session_token
            refute Parse.anonymous_session?
            refute Parse.master_key_disabled?
          end
          assert_equal before, snapshot

          assert_raises(RuntimeError) { Parse.without_ambient_identity { raise "x" } }
          assert_equal before, snapshot
        end
      end
    end
  end

  def test_without_ambient_identity_returns_block_value
    assert_equal 42, Parse.without_ambient_identity { 42 }
  end

  def test_worker_started_with_without_ambient_identity_sees_no_token
    seen = :unset
    t = nil
    Parse.with_session(TOKEN) do
      t = Thread.new { Parse.without_ambient_identity { seen = Parse.current_session_token } }
    end
    t.join(5)
    assert_nil seen
  end

  # (e) LiveQuery worker threads started inside a session block
  def test_live_query_event_queue_thread_does_not_inherit_session
    queue = Parse::LiveQuery::EventQueue.new(max_size: 5)
    seen = Queue.new
    Parse.with_session(TOKEN) do
      Parse.without_master_key do
        queue.start do |_event|
          seen << [Parse.current_session_token, Fiber[Parse::MASTER_KEY_STATE_KEY],
                   Fiber[Parse::INNERMOST_AUTH_BLOCK_KEY]]
        end
      end
    end
    queue.enqueue(:event)
    result = Timeout.timeout(5) { seen.pop }
    # The token is dropped, and the caller's master-key suppression is kept:
    # a callback never gains the master key the starting code did not have.
    assert_equal [nil, :disabled, nil], result
  ensure
    queue&.stop(drain: false, timeout: 1)
  end

  def event_queue_state_when_started
    queue = Parse::LiveQuery::EventQueue.new(max_size: 5)
    seen = Queue.new
    yield(-> { queue.start { |_e| seen << [Parse.current_session_token, Fiber[Parse::MASTER_KEY_STATE_KEY]] } })
    queue.enqueue(:event)
    Timeout.timeout(5) { seen.pop }
  ensure
    queue&.stop(drain: false, timeout: 1)
  end

  def test_live_query_callback_thread_started_in_session_does_not_gain_master
    state = event_queue_state_when_started { |start| Parse.with_session(TOKEN) { start.call } }
    assert_equal [nil, :disabled], state
    state = event_queue_state_when_started { |start| Parse.with_session(nil) { start.call } }
    assert_equal [nil, :disabled], state
  end

  def test_live_query_callback_thread_started_unrestricted_has_no_ambient_state
    state = event_queue_state_when_started { |start| start.call }
    assert_equal [nil, nil], state
  end

  def test_without_ambient_identity_keep_restrictions
    Parse.without_master_key do
      Parse.without_ambient_identity(keep_restrictions: true) { assert Parse.master_key_disabled? }
      Parse.without_ambient_identity { refute Parse.master_key_disabled? }
    end
    Parse.without_ambient_identity(keep_restrictions: true) { refute Parse.master_key_disabled? }
  end

  def test_live_query_reader_thread_does_not_inherit_session
    client = build_client(master_key: nil)
    seen = Queue.new
    client.define_singleton_method(:establish_connection) { nil }
    client.define_singleton_method(:send_connect_message) { nil }
    client.define_singleton_method(:read_loop) { seen << Parse.current_session_token }

    Parse.with_session(TOKEN) { assert client.connect }
    assert_nil Timeout.timeout(5) { seen.pop }
  ensure
    client&.instance_variable_get(:@reader_thread)&.join(1)
  end

  def test_live_query_reconnect_thread_does_not_inherit_session
    client = build_client(master_key: nil)
    seen = Queue.new
    client.define_singleton_method(:connect) { seen << Parse.current_session_token; true }
    client.instance_variable_set(:@reconnect_interval, 0.01)

    Parse.with_session(TOKEN) { client.send(:schedule_reconnect) }
    assert_nil Timeout.timeout(5) { seen.pop }
  end

  def test_live_query_reconnect_scheduled_inside_without_master_key_latches_withhold
    client = nil
    capture_io { client = build_client(master_key: "MK", use_master_key: true) }
    seen = Queue.new
    client.define_singleton_method(:connect) { seen << Parse.master_key_disabled?; true }
    client.instance_variable_set(:@reconnect_interval, 0.01)

    Parse.without_master_key { client.send(:schedule_reconnect) }
    # The reconnect thread itself runs without the block state, so the
    # withhold must already be latched on the client.
    refute Timeout.timeout(5) { seen.pop }
    assert client.master_key_withheld?
  end

  def test_live_query_health_monitor_thread_does_not_inherit_session
    seen = Queue.new
    monitor = Parse::LiveQuery::HealthMonitor.new(client: Object.new)
    monitor.define_singleton_method(:ping_loop) { seen << Parse.current_session_token }
    Parse.with_session(TOKEN) { monitor.start }
    assert_nil Timeout.timeout(5) { seen.pop }
  ensure
    monitor&.stop
  end

  private

  def build_client(master_key:, use_master_key: Parse::NOT_PROVIDED)
    Parse::LiveQuery::Client.new(
      url: "wss://test.example/parse",
      application_id: "app",
      client_key: "ck",
      master_key: master_key,
      use_master_key: use_master_key,
      auto_connect: false,
      auto_reconnect: false,
    )
  end
end
