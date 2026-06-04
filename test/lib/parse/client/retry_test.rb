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
  # Build a client whose connection always returns the given HTTP status and
  # counts how many HTTP attempts were made. `sleep` is stubbed (and the
  # requested delays recorded in @sleeps) so the test is instant.
  def stub_client(http_status:, retry_limit:)
    client = Parse::Client.allocate
    client.instance_variable_set(:@retry_limit, retry_limit)

    @sleeps = []
    sleeps = @sleeps
    client.define_singleton_method(:sleep) { |secs = 0| sleeps << secs; 0 }

    @attempts = 0
    bump = -> { @attempts += 1 } # closes over the test instance's @attempts

    resp = Parse::Response.new
    resp.http_status = http_status
    resp.code = 1
    resp.error = "service unavailable"
    env = Struct.new(:body).new(resp)

    conn = Object.new
    [:get, :post, :put, :delete].each do |verb|
      conn.define_singleton_method(verb) { |*_args| bump.call; env }
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
end
