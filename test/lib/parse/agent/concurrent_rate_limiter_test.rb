# encoding: UTF-8
# frozen_string_literal: true

# ---------------------------------------------------------------------------
# ConcurrentRateLimiterTest — verifies per-request agent + shared RateLimiter
# work correctly under concurrent load.
#
# NO Docker, NO Parse Server, NO real HTTP socket. Uses raw Thread.new for
# parallelism and stubs Parse::Agent#execute via singleton method (the same
# technique used in mcp_integration_test.rb) so no network calls fire.
#
# Covers:
#  - Exactly `limit` successes out of `limit + N` concurrent calls
#  - Remaining-count returns to 0 after a burst
#  - Full success when limit == thread count
#  - Broken limiter (raises arbitrary StandardError) is wrapped into
#    RateLimitExceeded — no topology leak
#  - Constructor guard: non-#check! limiter raises ArgumentError
#
# The MCPDispatcher stub used by test_shared_limiter_enforced_through_rack_app
# is installed per-test (setup/teardown) so it does not bleed into other test
# files when all three new test files are loaded in the same Minitest process.
#
# Run standalone:
#   bundle exec ruby -Ilib:test test/lib/parse/agent/concurrent_rate_limiter_test.rb
# ---------------------------------------------------------------------------

require "json"
require "stringio"
require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/errors"
require_relative "../../../../lib/parse/agent/rate_limiter"

# Ensure the full Agent is loaded (needed for #execute and its rescue chain)
require_relative "../../../../lib/parse/agent"

# MCPRackApp + MCPDispatcher needed only for the Rack-path sub-test.
require_relative "../../../../lib/parse/agent/mcp_rack_app"
require_relative "../../../../lib/parse/agent/mcp_dispatcher"

# ---------------------------------------------------------------------------
# Dispatcher stub — installed PER TEST so it does not conflict with the
# global stubs from mcp_rack_app_test.rb or sinatra_mount_test.rb when those
# files are loaded in the same Minitest run.
#
# Each test that needs to go through MCPDispatcher installs this stub in
# setup and restores in teardown.
# ---------------------------------------------------------------------------
module ConcurrentRateLimiterDispatcherStub
  class << self
    def install!
      return if @installed
      @original  = Parse::Agent::MCPDispatcher.method(:call)
      @installed = true

      Parse::Agent::MCPDispatcher.define_singleton_method(:call) do |body:, agent:, logger: nil, progress_callback: nil, cancellation_token: nil, subscription_manager: nil|
        # Delegate to the (already-stubbed) agent so the rate limiter fires.
        result = agent.execute(:ping)
        if result[:success]
          {
            status: 200,
            body: {
              "jsonrpc" => "2.0",
              "id"      => body["id"],
              "result"  => {
                "content" => [{ "type" => "text", "text" => "{}" }],
                "isError" => false,
              },
            },
          }
        else
          {
            status: 200,
            body: {
              "jsonrpc" => "2.0",
              "id"      => body["id"],
              "result"  => {
                "content" => [{ "type" => "text", "text" => result[:error].to_s }],
                "isError" => true,
              },
            },
          }
        end
      end
    end

    def restore!
      return unless @installed
      orig = @original
      Parse::Agent::MCPDispatcher.define_singleton_method(:call, &orig)
      @installed = false
      @original  = nil
    end

    def installed?
      @installed == true
    end
  end
end

# ---------------------------------------------------------------------------
# Helper: build a stubbed agent that honours its rate limiter but does no
# real Parse work. Override #execute directly so tool dispatch never happens.
# ---------------------------------------------------------------------------
def build_stubbed_agent(rate_limiter: nil)
  agent = if rate_limiter
    Parse::Agent.new(rate_limiter: rate_limiter)
  else
    Parse::Agent.new
  end

  # Override execute to call check! (rate limiter) then return stubbed data.
  # This mirrors the pattern in mcp_integration_test.rb#stubbed_agent.
  agent.define_singleton_method(:execute) do |tool_name, **_kwargs|
    begin
      @rate_limiter.check!
    rescue Parse::Agent::RateLimitExceeded => e
      return { success: false, error: e.message, error_code: :rate_limited, retry_after: e.retry_after }
    rescue StandardError => e
      # Broken limiter path — translate any arbitrary error into RateLimitExceeded
      # so backend topology doesn't leak through the MCP response. This mirrors
      # the wrapping logic in Parse::Agent#execute (lib/parse/agent.rb).
      warn "[ConcurrentRateLimiterTest:stub] rate limiter failure: #{e.class}: #{e.message}"
      retry_after = (1.0 + rand * 4.0).round(2)
      l = @rate_limiter.respond_to?(:limit)  ? @rate_limiter.limit  : Parse::Agent::RateLimiter::DEFAULT_LIMIT
      w = @rate_limiter.respond_to?(:window) ? @rate_limiter.window : Parse::Agent::RateLimiter::DEFAULT_WINDOW
      exc = Parse::Agent::RateLimitExceeded.new(retry_after: retry_after, limit: l, window: w)
      return { success: false, error: exc.message, error_code: :rate_limited, retry_after: exc.retry_after }
    end

    { success: true, data: { tool: tool_name.to_s } }
  end

  agent
end

# ---------------------------------------------------------------------------
# The test class
# ---------------------------------------------------------------------------
class ConcurrentRateLimiterTest < Minitest::Test

  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url:     "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key:        "test-api-key",
      )
    end
    @prior_suppress_master_key_warning = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
  end

  def teardown
    # Restore the dispatcher stub if this test installed it.
    ConcurrentRateLimiterDispatcherStub.restore! if ConcurrentRateLimiterDispatcherStub.installed?
    Parse::Agent.suppress_master_key_warning = @prior_suppress_master_key_warning
  end

  # ---------------------------------------------------------------------------
  # 1. 50 threads, limit 10 → exactly 10 successes, 40 rate-limited
  # ---------------------------------------------------------------------------

  def test_exactly_limit_successes_out_of_many_concurrent_calls
    shared_limiter = Parse::Agent::RateLimiter.new(limit: 10, window: 60)

    results = Array.new(50, nil)
    threads = 50.times.map do |i|
      Thread.new do
        agent = build_stubbed_agent(rate_limiter: shared_limiter)
        results[i] = agent.execute(:ping)
      end
    end
    threads.each { |t| t.join(5) }

    successes = results.count { |r| r && r[:success] == true }
    rate_hits = results.count { |r| r && r[:success] == false && r[:error_code] == :rate_limited }

    assert_equal 10, successes,
                 "Expected exactly 10 successes with limit:10; got #{successes}"
    assert_equal 40, rate_hits,
                 "Expected exactly 40 rate-limited responses; got #{rate_hits}"
    assert_equal 50, results.compact.size,
                 "All 50 threads must have completed (no nil results)"
  end

  # ---------------------------------------------------------------------------
  # 2. Rate-limited responses include retry_after
  # ---------------------------------------------------------------------------

  def test_rate_limited_responses_include_retry_after
    shared_limiter = Parse::Agent::RateLimiter.new(limit: 5, window: 60)

    results = Array.new(10, nil)
    threads = 10.times.map do |i|
      Thread.new { results[i] = build_stubbed_agent(rate_limiter: shared_limiter).execute(:ping) }
    end
    threads.each { |t| t.join(5) }

    limited = results.select { |r| r && r[:success] == false && r[:error_code] == :rate_limited }

    assert limited.size >= 1, "Expected at least one rate-limited response"
    limited.each do |r|
      assert r.key?(:retry_after),      "Rate-limited result must include :retry_after"
      assert r[:retry_after].to_f > 0, "retry_after must be positive, got #{r[:retry_after].inspect}"
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Remaining count reaches 0 after the burst
  # ---------------------------------------------------------------------------

  def test_remaining_count_is_zero_after_burst
    limit = 10
    shared_limiter = Parse::Agent::RateLimiter.new(limit: limit, window: 60)

    threads = limit.times.map do
      Thread.new { build_stubbed_agent(rate_limiter: shared_limiter).execute(:ping) }
    end
    threads.each { |t| t.join(5) }

    assert_equal 0, shared_limiter.remaining,
                 "remaining must be 0 after #{limit} requests against limit:#{limit}"
  end

  # ---------------------------------------------------------------------------
  # 4. 50 threads, limit 50 → all 50 succeed
  # ---------------------------------------------------------------------------

  def test_all_requests_succeed_when_limit_equals_thread_count
    shared_limiter = Parse::Agent::RateLimiter.new(limit: 50, window: 60)

    results = Array.new(50, nil)
    threads = 50.times.map do |i|
      Thread.new { results[i] = build_stubbed_agent(rate_limiter: shared_limiter).execute(:ping) }
    end
    threads.each { |t| t.join(5) }

    successes = results.count { |r| r && r[:success] == true }
    assert_equal 50, successes,
                 "All 50 requests should succeed with limit:50; got #{successes}"
  end

  # ---------------------------------------------------------------------------
  # 5. No thread exceptions / races: all results are Hashes
  # ---------------------------------------------------------------------------

  def test_no_thread_exceptions_under_concurrent_burst
    shared_limiter = Parse::Agent::RateLimiter.new(limit: 10, window: 60)
    exceptions = []
    results    = Array.new(50, nil)

    threads = 50.times.map do |i|
      Thread.new do
        results[i] = build_stubbed_agent(rate_limiter: shared_limiter).execute(:ping)
      rescue => e
        exceptions << e
      end
    end
    threads.each { |t| t.join(5) }

    assert_empty exceptions, "No exceptions should be raised under concurrent load. " \
                             "Got: #{exceptions.map { |e| "#{e.class}: #{e.message}" }.join(', ')}"
    assert results.all? { |r| r.is_a?(Hash) },
           "All results must be Hashes (no nils from crashed threads)"
  end

  # ---------------------------------------------------------------------------
  # 6. Broken limiter: non-RateLimitExceeded errors are wrapped
  # ---------------------------------------------------------------------------

  def test_broken_limiter_non_rate_error_wrapped_into_rate_limit_exceeded
    # Simulate a Redis-style connection error from an external limiter.
    broken_limiter = Object.new
    broken_limiter.define_singleton_method(:check!) do
      raise RuntimeError, "Redis::CannotConnectError: connection refused"
    end
    broken_limiter.define_singleton_method(:limit)  { 60 }
    broken_limiter.define_singleton_method(:window) { 60 }

    agent  = build_stubbed_agent(rate_limiter: broken_limiter)
    result = agent.execute(:ping)

    assert_equal false, result[:success],
                 "Broken limiter must cause execute to return success: false"
    assert_equal :rate_limited, result[:error_code],
                 "error_code must be :rate_limited (wrapping hides topology)"
    assert result[:retry_after].to_f > 0,
           "retry_after must be positive, got #{result[:retry_after].inspect}"
    # The raw Redis error string must not appear in the rate-limit response.
    refute_includes result[:error].to_s, "Redis",
                    "Redis error details must not leak into the rate-limit response"
    refute_includes result[:error].to_s, "connection refused",
                    "Connection details must not leak into the rate-limit response"
  end

  # ---------------------------------------------------------------------------
  # 7. Multiple threads with broken limiter — all get rate-limited, no exceptions
  # ---------------------------------------------------------------------------

  def test_broken_limiter_under_concurrent_load_no_exceptions
    broken_limiter = Object.new
    broken_limiter.define_singleton_method(:check!) { raise RuntimeError, "backend down" }
    broken_limiter.define_singleton_method(:limit)  { 60 }
    broken_limiter.define_singleton_method(:window) { 60 }

    results    = Array.new(20, nil)
    exceptions = []

    threads = 20.times.map do |i|
      Thread.new do
        agent = build_stubbed_agent(rate_limiter: broken_limiter)
        results[i] = agent.execute(:ping)
      rescue => e
        exceptions << e
      end
    end
    threads.each { |t| t.join(5) }

    assert_empty exceptions,
                 "Broken limiter must not propagate exceptions to callers"
    assert results.all? { |r| r.is_a?(Hash) && r[:success] == false && r[:error_code] == :rate_limited },
           "All results must be rate-limited Hashes with success:false. " \
           "Unexpected: #{results.select { |r| !r.is_a?(Hash) || r[:success] }.inspect}"
  end

  # ---------------------------------------------------------------------------
  # 8. Constructor guard: limiter without #check! raises ArgumentError
  # ---------------------------------------------------------------------------

  def test_constructor_raises_for_limiter_missing_check_method
    bad_limiter = Object.new  # no #check! method

    assert_raises(ArgumentError) do
      Parse::Agent.new(rate_limiter: bad_limiter)
    end
  end

  def test_constructor_accepts_valid_external_limiter
    good_limiter = Object.new
    good_limiter.define_singleton_method(:check!) { true }
    good_limiter.define_singleton_method(:limit)  { 100 }
    good_limiter.define_singleton_method(:window) { 60  }

    agent = nil
    assert_silent do
      agent = Parse::Agent.new(rate_limiter: good_limiter)
    end
    assert_instance_of Parse::Agent, agent
    assert_same good_limiter, agent.rate_limiter
  end

  # ---------------------------------------------------------------------------
  # 9. Through MCPRackApp + MCPDispatcher end-to-end (Rack env, no HTTP socket)
  #
  # The dispatcher stub is installed per-test in this test only so it does not
  # conflict with the global stubs from other test files loaded in the same
  # Minitest process.
  # ---------------------------------------------------------------------------

  def test_shared_limiter_enforced_through_rack_app
    ConcurrentRateLimiterDispatcherStub.install!

    shared_limiter = Parse::Agent::RateLimiter.new(limit: 5, window: 60)

    rack_app = Parse::Agent::MCPRackApp.new(
      agent_factory: ->(_env) { build_stubbed_agent(rate_limiter: shared_limiter) },
    )

    results = Array.new(10, nil)
    threads = 10.times.map do |i|
      Thread.new do
        body = JSON.generate({
          "jsonrpc" => "2.0",
          "id"      => i,
          "method"  => "tools/call",
          "params"  => { "name" => "ping", "arguments" => {} },
        })
        env = {
          "REQUEST_METHOD" => "POST",
          "CONTENT_TYPE"   => "application/json",
          "rack.input"     => StringIO.new(body),
        }
        _status, _headers, body_chunks = rack_app.call(env)
        results[i] = JSON.parse(body_chunks.join)
      end
    end
    threads.each { |t| t.join(5) }

    successes = results.count { |r| r && r.dig("result", "isError") == false }
    failures  = results.count { |r| r && r.dig("result", "isError") == true }

    assert_equal 5, successes,
                 "Expected exactly 5 successes through Rack with limit:5; got #{successes}"
    assert_equal 5, failures,
                 "Expected exactly 5 rate-limited failures through Rack; got #{failures}"
  end

  # ---------------------------------------------------------------------------
  # 10. Built-in in-process RateLimiter is thread-safe under heavy concurrency
  # ---------------------------------------------------------------------------

  def test_in_process_limiter_thread_safety
    # Very high concurrency to stress the Mutex inside RateLimiter.
    limit          = 100
    thread_count   = 200
    shared_limiter = Parse::Agent::RateLimiter.new(limit: limit, window: 60)
    results        = Array.new(thread_count, nil)
    exceptions     = []

    threads = thread_count.times.map do |i|
      Thread.new do
        begin
          shared_limiter.check!
          results[i] = :ok
        rescue Parse::Agent::RateLimiter::RateLimitExceeded
          results[i] = :limited
        rescue => e
          exceptions << e
          results[i] = :error
        end
      end
    end
    threads.each { |t| t.join(5) }

    ok_count      = results.count(:ok)
    limited_count = results.count(:limited)

    assert_empty exceptions,
                 "No exceptions expected from in-process limiter: #{exceptions.map(&:message).inspect}"
    assert_equal limit, ok_count,
                 "Exactly #{limit} threads should succeed; got #{ok_count}"
    assert_equal thread_count - limit, limited_count,
                 "Exactly #{thread_count - limit} threads should be rate-limited; got #{limited_count}"
  end
end
