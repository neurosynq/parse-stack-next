# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"

# Unit tests for the v5.5 spend-cap coverage extension: SpendCap.charge_query!
# (the non-agent embed-path charge), with_precharged suppression, ambient
# cache-tenant identity resolution, and the find_similar(text:) wiring.
class EmbeddingsSpendCapQueryTest < Minitest::Test
  CAP = Parse::Embeddings::SpendCap

  def self.register
    Parse::Embeddings.register(:fx_capq, Parse::Embeddings::Fixture.new(dimensions: 4))
  end
  register

  class CapQItem < Parse::Object
    parse_class "CapQItem"
    property :title, :string
    property :embedding, :vector, dimensions: 4, provider: :fx_capq
  end

  def teardown
    CAP.reset_all!
    Parse::Embeddings::Cache.disable!
  end

  def test_charge_query_noop_when_uncapped
    assert_nil CAP.charge_query!("hello world")
  end

  def test_charge_query_charges_default_bucket
    CAP.configure(limit_tokens: 10, window: 60)
    CAP.charge_query!("a" * 32) # ~8 tokens
    assert_raises(CAP::Exceeded) { CAP.charge_query!("a" * 32) }
  end

  def test_charge_query_uses_ambient_cache_tenant
    CAP.configure("tenantA", limit_tokens: 5, window: 60)
    # tenantA capped at 5; default uncapped.
    Parse.with_cache_tenant("tenantA") do
      assert_raises(CAP::Exceeded) { CAP.charge_query!("a" * 100) }
    end
    # Outside the tenant block the default (uncapped) bucket applies.
    assert_nil CAP.charge_query!("a" * 100)
  end

  def test_explicit_tenant_id_wins
    CAP.configure("tenantB", limit_tokens: 5, window: 60)
    assert_raises(CAP::Exceeded) { CAP.charge_query!("a" * 100, tenant_id: "tenantB") }
  end

  def test_with_precharged_suppresses_charge
    CAP.configure(limit_tokens: 5, window: 60)
    CAP.with_precharged do
      assert CAP.precharged?
      assert_nil CAP.charge_query!("a" * 100)
    end
    refute CAP.precharged?
  end

  def test_with_precharged_restores_on_exception
    begin
      CAP.with_precharged { raise "boom" }
    rescue RuntimeError
      nil
    end
    refute CAP.precharged?
  end

  def test_find_similar_text_charges_the_cap
    CAP.configure(limit_tokens: 5, window: 60)
    err = assert_raises(CAP::Exceeded) do
      CapQItem.find_similar(text: "a" * 100)
    end
    assert_includes err.message, "spend cap exceeded"
  end

  # ---------- soft-cap warning (warn_at:) ----------

  def collect_warnings
    events = []
    sub = ActiveSupport::Notifications.subscribe(CAP::AS_NOTIFICATION_NAME) do |*, payload|
      events << payload
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  def test_warn_at_emits_event_on_threshold_crossing
    CAP.configure(limit_tokens: 100, window: 60, warn_at: 0.8)
    events = collect_warnings do
      CAP.charge!(tenant_id: "t1", tokens: 70)  # below threshold
      CAP.charge!(tenant_id: "t1", tokens: 15)  # crosses 80
    end
    assert_equal 1, events.length
    payload = events.first
    assert_equal "t1", payload[:tenant_id]
    assert_equal 85, payload[:used]
    assert_equal 100, payload[:limit]
    assert_in_delta 80.0, payload[:threshold], 1e-9
  end

  def test_warn_at_fires_once_not_per_charge_above_threshold
    CAP.configure(limit_tokens: 100, window: 60, warn_at: 0.5)
    events = collect_warnings do
      CAP.charge!(tenant_id: "t1", tokens: 60)  # crosses 50
      CAP.charge!(tenant_id: "t1", tokens: 10)  # already above — no event
      CAP.charge!(tenant_id: "t1", tokens: 10)
    end
    assert_equal 1, events.length
  end

  def test_warn_at_does_not_fire_below_threshold_or_on_refusal
    CAP.configure(limit_tokens: 100, window: 60, warn_at: 0.9)
    events = collect_warnings do
      CAP.charge!(tenant_id: "t1", tokens: 50)
      assert_raises(CAP::Exceeded) { CAP.charge!(tenant_id: "t1", tokens: 60) }
    end
    assert_empty events
  end

  def test_warn_at_validates_range
    assert_raises(ArgumentError) { CAP.configure(limit_tokens: 100, warn_at: 0) }
    assert_raises(ArgumentError) { CAP.configure(limit_tokens: 100, warn_at: 1.0) }
    assert_raises(ArgumentError) { CAP.configure(limit_tokens: 100, warn_at: 2) }
  end

  def test_without_warn_at_no_event
    CAP.configure(limit_tokens: 100, window: 60)
    events = collect_warnings do
      CAP.charge!(tenant_id: "t1", tokens: 99)
    end
    assert_empty events
  end

  def test_find_similar_text_inside_precharged_skips_cap
    CAP.configure(limit_tokens: 5, window: 60)
    # Embedding succeeds (no Exceeded); the call then fails later at
    # index resolution because no Mongo/Atlas is configured — that error
    # PROVES the embed step got past the cap.
    err = assert_raises(StandardError) do
      CAP.with_precharged { CapQItem.find_similar(text: "a" * 100) }
    end
    refute_kind_of CAP::Exceeded, err
  end
end
