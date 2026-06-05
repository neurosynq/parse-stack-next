# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for Parse::Embeddings::SpendCap — the per-tenant cumulative
# token cap with hard-refuse semantics.
class EmbeddingsSpendCapTest < Minitest::Test
  SC = Parse::Embeddings::SpendCap

  def setup
    SC.reset_all!
  end

  def teardown
    SC.reset_all!
  end

  def test_disabled_by_default_is_noop
    assert_nil SC.charge!(tenant_id: "t", tokens: 10_000)
    assert_equal 0, SC.usage(tenant_id: "t")
  end

  def test_charges_accumulate_and_hard_refuse
    SC.configure(limit_tokens: 100, window: 3600)
    assert_equal 60, SC.charge!(tenant_id: "t", tokens: 60)
    assert_equal 60, SC.usage(tenant_id: "t")
    err = assert_raises(SC::Exceeded) { SC.charge!(tenant_id: "t", tokens: 50) }
    assert_equal 60, err.used
    assert_equal 50, err.requested
    assert_equal 100, err.limit
    # The refused charge is NOT recorded.
    assert_equal 60, SC.usage(tenant_id: "t")
  end

  def test_separate_tenants_have_separate_buckets
    SC.configure(limit_tokens: 100)
    SC.charge!(tenant_id: "a", tokens: 90)
    assert_equal 90, SC.charge!(tenant_id: "b", tokens: 90)
    assert_equal 90, SC.usage(tenant_id: "a")
    assert_equal 90, SC.usage(tenant_id: "b")
  end

  def test_per_tenant_override_wins_over_default
    SC.configure(limit_tokens: 1000)
    SC.configure("small", limit_tokens: 10)
    assert_raises(SC::Exceeded) { SC.charge!(tenant_id: "small", tokens: 20) }
    # default tenant still has the large cap.
    assert_equal 500, SC.charge!(tenant_id: "big", tokens: 500)
  end

  def test_per_tenant_disable_overrides_default
    SC.configure(limit_tokens: 10)
    SC.configure("vip", limit_tokens: nil) # uncapped for vip
    assert_nil SC.charge!(tenant_id: "vip", tokens: 1_000_000)
  end

  def test_request_larger_than_limit_has_nil_retry_after
    SC.configure(limit_tokens: 10)
    err = assert_raises(SC::Exceeded) { SC.charge!(tenant_id: "t", tokens: 20) }
    assert_nil err.retry_after, "a charge that can never fit reports no retry_after"
  end

  def test_nil_tenant_uses_shared_default_bucket
    SC.configure(limit_tokens: 100)
    SC.charge!(tenant_id: nil, tokens: 70)
    assert_equal 70, SC.usage(tenant_id: nil)
  end

  def test_estimate_tokens_is_chars_over_four
    assert_equal 3, SC.estimate_tokens("abcdefghij") # 10/4 -> 3 (ceil)
    assert_equal 0, SC.estimate_tokens("")
  end

  def test_configure_rejects_bad_values
    assert_raises(ArgumentError) { SC.configure(limit_tokens: 0) }
    assert_raises(ArgumentError) { SC.configure(limit_tokens: 100, window: 0) }
  end

  def test_reset_clears_usage_but_keeps_limits
    SC.configure(limit_tokens: 100)
    SC.charge!(tenant_id: "t", tokens: 50)
    SC.reset!("t")
    assert_equal 0, SC.usage(tenant_id: "t")
    # limit still applies after a usage reset.
    assert_equal 100, SC.charge!(tenant_id: "t", tokens: 100)
  end
end
