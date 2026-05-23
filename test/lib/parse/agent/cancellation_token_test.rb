# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/cancellation_token"

class CancellationTokenTest < Minitest::Test
  def setup
    @token = Parse::Agent::CancellationToken.new
  end

  def test_starts_uncancelled
    refute @token.cancelled?
    assert_nil @token.reason
  end

  def test_cancel_trips_the_flag_and_records_reason
    assert @token.cancel!(reason: :user_requested)
    assert @token.cancelled?
    assert_equal :user_requested, @token.reason
  end

  def test_cancel_is_idempotent_and_returns_false_on_subsequent_calls
    assert_equal true,  @token.cancel!(reason: :first)
    assert_equal false, @token.cancel!(reason: :second),
                        "Second cancel! must return false (no state change)"
    assert_equal :first, @token.reason,
                 "Idempotent cancel must not overwrite the original reason"
  end

  def test_cancel_accepts_nil_reason
    assert @token.cancel!
    assert @token.cancelled?
    assert_nil @token.reason
  end

  def test_concurrent_cancel_calls_only_one_wins
    threads = 20.times.map do |i|
      Thread.new do
        sleep 0.001  # encourage contention
        @token.cancel!(reason: "thread-#{i}")
      end
    end
    results = threads.map(&:value)
    winners = results.count(true)
    assert_equal 1, winners,
                 "Exactly one concurrent cancel! must return true; got #{winners}"
    refute_nil @token.reason
  end
end
