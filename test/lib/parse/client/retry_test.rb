# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Regression coverage for the retry-budget reset bug (5.1.2).
#
# Parse::Client#request retries transient failures (500/503/429) using Ruby's
# `retry` keyword, which re-runs the begin block. The retry counter was
# previously initialized INSIDE that block, so every attempt reset it back to
# retry_limit — a persistent failure looped forever ("Retries remaining 2"
# with no decrement, and zero backoff because `RETRY_DELAY * (limit - count)`
# was always 0). The fix hoists the budget initialization above the begin so
# the countdown survives `retry`. These tests pin that the number of attempts
# is bounded.
class ClientRetryTest < Minitest::Test
  # Build a client whose connection always returns the given HTTP status and
  # counts how many HTTP attempts were made. `sleep` is stubbed so the test is
  # instant (the real path would back off for seconds between attempts).
  def stub_client(http_status:, retry_limit:)
    client = Parse::Client.allocate
    client.instance_variable_set(:@retry_limit, retry_limit)
    client.define_singleton_method(:sleep) { |*| 0 }

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

  def test_persistent_500_retries_exactly_retry_limit_times_then_raises
    client = stub_client(http_status: 500, retry_limit: 2)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:post, "requestPasswordReset", body: { email: "x@y.z" })
    end
    assert_equal 3, @attempts,
      "a persistent 500 must make exactly retry_limit + 1 attempts (1 initial + 2 retries), not loop"
  end

  def test_persistent_503_is_bounded
    client = stub_client(http_status: 503, retry_limit: 1)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:post, "x", body: {})
    end
    assert_equal 2, @attempts, "retry_limit 1 => 2 attempts total"
  end

  def test_retry_disabled_makes_single_attempt
    client = stub_client(http_status: 503, retry_limit: 5)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:post, "x", body: {}, opts: { retry: false })
    end
    assert_equal 1, @attempts, "opts[:retry] == false must disable retries"
  end

  def test_explicit_retry_count_is_honored_and_bounded
    # Previously broken too: opts[:retry] re-applied inside the begin, so an
    # explicit retry count also looped. It must now terminate after N retries.
    client = stub_client(http_status: 500, retry_limit: 0)
    assert_raises(Parse::Error::ServiceUnavailableError) do
      client.request(:post, "x", body: {}, opts: { retry: 3 })
    end
    assert_equal 4, @attempts, "opts[:retry] = 3 must make exactly 4 attempts and terminate"
  end
end
