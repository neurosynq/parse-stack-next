# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Regression coverage for Parse::Client#request retry behavior (5.2.0).
#
# Two properties are pinned here:
#
#   1. Retry budget is bounded. The counter is initialized ABOVE the begin
#      block so Ruby's `retry` keyword (which re-runs only the begin) doesn't
#      reset it — a persistent 500/503/429 must make exactly retry_limit + 1
#      attempts, not loop forever. The backoff multiplier is derived from the
#      effective starting budget (`_retry_max`), not `self.retry_limit`, so an
#      explicit `opts: { retry: N }` above the instance default still produces
#      a positive, growing delay instead of a zero/negative one.
#
#   2. Retries are idempotency-aware. A request whose outcome is unknown
#      (500/503 or a dropped connection) is only re-sent when it is safe to
#      replay: GET/DELETE always, a PUT update only when it carries no atomic
#      `__op` mutation, and POST (create/batch) never. A 429 throttle is the
#      exception — the server provably discarded the request, so it re-sends
#      regardless of method.
class ClientRetryTest < Minitest::Test
  # Server-side request-id dedup is an explicit opt-in (`assume_server_idempotency`).
  # Keep it OFF for every test by default so the conservative behavior is the
  # baseline; the dedup tests flip it on and this restores it.
  def teardown
    Parse::Request.assume_server_idempotency = false
  end

  # Build a client whose connection always returns the given HTTP status and
  # counts how many HTTP attempts were made. `sleep` is stubbed (delays recorded
  # in @sleeps) and the per-attempt `X-Parse-Request-Id` header is recorded in
  # @req_ids, so a test can assert the same id is replayed across retries.
  def stub_client(http_status:, retry_limit:, code: 1, error: "service unavailable")
    resp = Parse::Response.new
    resp.http_status = http_status
    resp.code = code
    resp.error = error
    env = Struct.new(:body).new(resp)
    build_stub(retry_limit: retry_limit) { env }
  end

  # Like stub_client, but the connection RAISES `error` on every attempt (for
  # the dropped-connection / timeout retry branch).
  def stub_client_raising(error, retry_limit:)
    build_stub(retry_limit: retry_limit) { raise error }
  end

  # Shared stub builder. The no-arg block decides what each @conn verb does on
  # each call (return the canned env, or raise).
  def build_stub(retry_limit:, &on_call)
    client = Parse::Client.allocate
    client.instance_variable_set(:@retry_limit, retry_limit)

    @sleeps = []
    sleeps = @sleeps
    client.define_singleton_method(:sleep) { |secs = 0| sleeps << secs; 0 }

    @attempts = 0
    bump = -> { @attempts += 1 } # closes over the test instance's @attempts

    @req_ids = []
    req_ids = @req_ids

    conn = Object.new
    [:get, :post, :put, :delete].each do |verb|
      conn.define_singleton_method(verb) do |*args|
        hdrs = args[2] # @conn.send(method, uri, params, headers)
        req_ids << (hdrs.is_a?(Hash) ? hdrs["X-Parse-Request-Id"] : nil)
        bump.call
        on_call.call
      end
    end
    client.instance_variable_set(:@conn, conn)
    client
  end

  # ---------------------------------------------------------------------------
  # Budget bounding
  # ---------------------------------------------------------------------------

  def test_persistent_500_get_retries_exactly_retry_limit_times_then_raises
    client = stub_client(http_status: 500, retry_limit: 2)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:get, "classes/Post", query: { limit: 0 })
    end
    assert_equal 3, @attempts,
      "a persistent 500 on an idempotent GET must make exactly retry_limit + 1 attempts (1 + 2), not loop"
  end

  def test_persistent_503_get_is_bounded
    client = stub_client(http_status: 503, retry_limit: 1)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:get, "classes/Post", query: { limit: 0 })
    end
    assert_equal 2, @attempts, "retry_limit 1 => 2 attempts total"
  end

  def test_retry_disabled_makes_single_attempt
    client = stub_client(http_status: 503, retry_limit: 5)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:get, "classes/Post", query: { limit: 0 }, opts: { retry: false })
    end
    assert_equal 1, @attempts, "opts[:retry] == false must disable retries"
  end

  def test_explicit_retry_count_is_honored_and_bounded
    # opts[:retry] above the instance default must still terminate.
    client = stub_client(http_status: 500, retry_limit: 0)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:get, "classes/Post", query: { limit: 0 }, opts: { retry: 3 })
    end
    assert_equal 4, @attempts, "opts[:retry] = 3 must make exactly 4 attempts and terminate"
  end

  def test_backoff_delay_is_positive_when_explicit_retry_exceeds_instance_limit
    # Regression for the zero/negative-backoff bug: with retry_limit 1 and
    # opts[:retry] 4, the old multiplier `(retry_limit - count)` went negative
    # and every retry fired at zero delay. The multiplier now uses the
    # effective starting budget, so each backoff is strictly positive.
    client = stub_client(http_status: 503, retry_limit: 1)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:get, "classes/Post", query: { limit: 0 }, opts: { retry: 4 })
    end
    assert_equal 5, @attempts, "opts[:retry] = 4 => 5 attempts"
    assert_equal 4, @sleeps.length, "one backoff per retry"
    assert(@sleeps.all? { |s| s > 0 },
           "every backoff delay must be strictly positive, got #{@sleeps.inspect}")
  end

  # ---------------------------------------------------------------------------
  # Idempotency awareness
  # ---------------------------------------------------------------------------

  def test_post_is_not_retried_on_500
    # A POST (object create) whose outcome is ambiguous must NOT be re-sent —
    # replay could create a duplicate object.
    client = stub_client(http_status: 500, retry_limit: 3)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:post, "classes/Post", body: { title: "hi" })
    end
    assert_equal 1, @attempts, "POST must make a single attempt on an ambiguous 500"
  end

  def test_put_without_atomic_op_is_retried_on_503
    # A full-field PUT update with no atomic op is idempotent — safe to replay.
    client = stub_client(http_status: 503, retry_limit: 2)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:put, "classes/Post/abc", body: { "title" => "hi" })
    end
    assert_equal 3, @attempts, "an op-free PUT must retry like any idempotent request"
  end

  def test_put_with_atomic_op_is_not_retried_on_503
    # An Increment/Add/Remove op would double-apply on replay.
    client = stub_client(http_status: 503, retry_limit: 3)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:put, "classes/Post/abc",
                     body: { "likes" => { "__op" => "Increment", "amount" => 1 } })
    end
    assert_equal 1, @attempts, "a PUT carrying an atomic __op must not be replayed on an ambiguous 503"
  end

  def test_delete_is_retried_on_503
    client = stub_client(http_status: 503, retry_limit: 2)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:delete, "classes/Post/abc")
    end
    assert_equal 3, @attempts, "DELETE is idempotent and must retry"
  end

  # ---------------------------------------------------------------------------
  # 429 throttle: server provably discarded the request, so retry any method
  # ---------------------------------------------------------------------------

  def test_persistent_429_retries_post_and_is_bounded
    client = stub_client(http_status: 429, retry_limit: 2)
    assert_raises(Parse::Error::RequestLimitExceededError) do
      client.request(:post, "classes/Post", body: { title: "hi" })
    end
    assert_equal 3, @attempts,
      "a 429 must retry even a POST (server discarded it), bounded to retry_limit + 1 attempts"
  end

  def test_persistent_429_retries_atomic_op_put_and_is_bounded
    client = stub_client(http_status: 429, retry_limit: 1)
    assert_raises(Parse::Error::RequestLimitExceededError) do
      client.request(:put, "classes/Post/abc",
                     body: { "likes" => { "__op" => "Increment", "amount" => 1 } })
    end
    assert_equal 2, @attempts,
      "a 429 throttles before processing, so even an atomic-op PUT is safe to retry"
  end

  # ---------------------------------------------------------------------------
  # Server-side request-id dedup: writes become retry-safe ONLY when the
  # operator asserts Parse Server idempotency is configured AND the request
  # carries a stable X-Parse-Request-Id header (sent on every attempt).
  # ---------------------------------------------------------------------------

  def test_post_not_retried_when_server_dedup_not_asserted
    # Default posture: the POST carries an X-Parse-Request-Id (on by default),
    # but `assume_server_idempotency` is false, so it is still NOT retried —
    # the client cannot assume the server deduplicates the replay.
    refute Parse::Request.assume_server_idempotency
    client = stub_client(http_status: 503, retry_limit: 3)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:post, "classes/Post", body: { title: "hi" })
    end
    assert_equal 1, @attempts
    refute_nil @req_ids.compact.first, "sanity: a POST carries a request-id header by default"
  end

  def test_post_retried_with_stable_request_id_when_server_dedup_asserted
    Parse::Request.assume_server_idempotency = true
    client = stub_client(http_status: 503, retry_limit: 2)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:post, "classes/Post", body: { title: "hi" })
    end
    assert_equal 3, @attempts, "a POST is retry-safe under asserted server dedup"
    ids = @req_ids.compact
    assert_equal 3, ids.size, "every attempt must carry a request-id header"
    assert_equal 1, ids.uniq.size,
      "every retry must send the SAME X-Parse-Request-Id so the server dedups: #{@req_ids.inspect}"
    assert ids.first.start_with?("_RB_"), "request id should be the Ruby-Parse-Stack format"
  end

  def test_atomic_op_put_retried_when_server_dedup_asserted
    # An atomic-op PUT is normally NOT retried (would double-apply); under
    # asserted server dedup the replay is a server-side no-op, so it IS retried.
    Parse::Request.assume_server_idempotency = true
    client = stub_client(http_status: 500, retry_limit: 2)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:put, "classes/Post/abc",
                     body: { "likes" => { "__op" => "Increment", "amount" => 1 } })
    end
    assert_equal 3, @attempts, "an atomic-op PUT is retry-safe under server dedup"
    assert_equal 1, @req_ids.compact.uniq.size, "stable request id across retries"
  end

  def test_post_without_request_id_not_retried_even_when_server_dedup_asserted
    # A write with idempotency suppressed (no request-id header) must NOT be
    # retried even when server dedup is asserted — there is no dedup key for
    # the server to match the replay against.
    Parse::Request.assume_server_idempotency = true
    client = stub_client(http_status: 503, retry_limit: 2)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:post, "classes/Post", body: { title: "hi" }, opts: { idempotent: false })
    end
    assert_equal 1, @attempts, "no request-id header => not retried even when dedup is asserted"
    assert_empty @req_ids.compact, "the request must carry no X-Parse-Request-Id"
  end

  def test_post_retried_on_timeout_when_server_dedup_asserted
    # Faraday 2.x raises Faraday::TimeoutError for a real read timeout (the
    # ambiguous "sent but no answer" case). The timeout rescue branch honors the
    # same server-dedup fast path: a POST timeout is retried with a stable id.
    Parse::Request.assume_server_idempotency = true
    client = stub_client_raising(Faraday::TimeoutError.new("timed out"), retry_limit: 2)
    assert_raises(Parse::Error::ConnectionError) do
      client.request(:post, "classes/Post", body: { title: "hi" })
    end
    assert_equal 3, @attempts, "a POST retries on a read timeout under asserted server dedup"
    assert_equal 1, @req_ids.compact.uniq.size, "stable request id across timeout retries"
  end

  def test_post_not_retried_on_timeout_without_server_dedup
    client = stub_client_raising(Faraday::TimeoutError.new("timed out"), retry_limit: 2)
    assert_raises(Parse::Error::ConnectionError) do
      client.request(:post, "classes/Post", body: { title: "hi" })
    end
    assert_equal 1, @attempts, "default: a POST is not retried on a read timeout"
  end

  def test_connection_refused_is_not_caught_and_fails_fast
    # Connection refused (Faraday::ConnectionFailed) is intentionally NOT in the
    # rescue list — it is a non-transient failure that must propagate raw and
    # fast (no retry latency, no [Parse:Retry] noise on a down/misconfigured
    # server). Guards the deliberate scope of the timeout-only retry fix.
    client = stub_client_raising(Faraday::ConnectionFailed.new("refused"), retry_limit: 3)
    assert_raises(Faraday::ConnectionFailed) do
      client.request(:get, "classes/Post", query: { limit: 0 })
    end
    assert_equal 1, @attempts, "connection-refused must not be retried"
  end

  # ---------------------------------------------------------------------------
  # Code 159 — request-id idempotency duplicate → typed DuplicateRequestError.
  # ---------------------------------------------------------------------------

  def test_code_159_raises_duplicate_request_error
    # A replay rejected by server idempotency (HTTP 400, Parse code 159) is
    # surfaced as a typed, catchable error rather than a generic failure.
    client = stub_client(http_status: 400, code: 159, retry_limit: 0, error: "Duplicate request")
    assert_raises(Parse::Error::DuplicateRequestError) do
      client.request(:post, "classes/Post", body: { title: "hi" })
    end
  end

  def test_retry_into_duplicate_request_surfaces_duplicate_request_error
    # The headline ambiguous-success path: attempt 1 lands but returns 503; the
    # SDK retries (server dedup asserted) and replays the same request id; the
    # server answers 159. The caller gets DuplicateRequestError ("already
    # applied"), NOT an infinite loop or a generic ServiceUnavailableError.
    Parse::Request.assume_server_idempotency = true

    client = Parse::Client.allocate
    client.instance_variable_set(:@retry_limit, 3)
    client.define_singleton_method(:sleep) { |_s = 0| 0 }
    seq = [[503, 1, "unavailable"], [400, 159, "Duplicate request"]]
    i = -1
    conn = Object.new
    [:get, :post, :put, :delete].each do |verb|
      conn.define_singleton_method(verb) do |*_args|
        i += 1
        st, code, err = seq[[i, seq.size - 1].min]
        r = Parse::Response.new
        r.http_status = st
        r.code = code
        r.error = err
        Struct.new(:body).new(r)
      end
    end
    client.instance_variable_set(:@conn, conn)

    assert_raises(Parse::Error::DuplicateRequestError) do
      client.request(:post, "classes/Post", body: { title: "hi" })
    end
    assert_equal 2, i + 1, "exactly two attempts: the 503, then the 159 replay"
  end
end
