# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# Coverage for Parse::Agent.measure_embeddings (B6): scoping embed cost
# around arbitrary work (e.g. corpus ingestion at save time) that the
# per-tool-call telemetry does not span.
class MeasureEmbeddingsTest < Minitest::Test
  def setup
    @saved_rate = Parse::Agent.embed_cost_per_million_tokens
  end

  def teardown
    Parse::Agent.embed_cost_per_million_tokens = @saved_rate
  end

  def emit(tokens)
    ActiveSupport::Notifications.instrument("parse.embeddings.embed", total_tokens: tokens) { [] }
  end

  def test_captures_calls_tokens_and_cost
    Parse::Agent.embed_cost_per_million_tokens = 100.0 # $100 / 1M tokens
    stats = Parse::Agent.measure_embeddings do
      emit(1000)
      emit(2000)
    end
    assert_equal 2, stats[:calls]
    assert_equal 3000, stats[:tokens]
    assert_in_delta 0.3, stats[:cost_usd], 1e-9 # 3000/1e6 * 100
  end

  def test_cost_nil_when_no_rate_configured
    Parse::Agent.embed_cost_per_million_tokens = nil
    stats = Parse::Agent.measure_embeddings { emit(500) }
    assert_equal 1, stats[:calls]
    assert_equal 500, stats[:tokens]
    assert_nil stats[:cost_usd]
  end

  def test_embeds_outside_the_block_are_not_counted
    emit(9999) # before
    stats = Parse::Agent.measure_embeddings { emit(10) }
    emit(8888) # after
    assert_equal 1, stats[:calls]
    assert_equal 10, stats[:tokens]
  end

  def test_restores_prior_frame_even_on_error
    # An exception in the block must not leave a dangling accumulator frame.
    assert_raises(RuntimeError) do
      Parse::Agent.measure_embeddings { raise "boom" }
    end
    # A subsequent measurement starts clean.
    stats = Parse::Agent.measure_embeddings { emit(42) }
    assert_equal 42, stats[:tokens]
  end

  def test_embed_cost_usd_helper
    Parse::Agent.embed_cost_per_million_tokens = 50.0
    assert_in_delta 50.0, Parse::Agent.embed_cost_usd(1_000_000), 1e-9
    assert_in_delta 0.05, Parse::Agent.embed_cost_usd(1_000), 1e-9
    assert_nil Parse::Agent.embed_cost_usd(0)
    Parse::Agent.embed_cost_per_million_tokens = nil
    assert_nil Parse::Agent.embed_cost_usd(1000)
  end
end
