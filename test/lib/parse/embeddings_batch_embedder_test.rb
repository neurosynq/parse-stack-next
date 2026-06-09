# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"

# Unit tests for Parse::Embeddings::BatchEmbedder — batch slicing,
# requests-per-minute pacing, batch-level exponential backoff on
# rate-limit / transient errors, and the BatchFailed terminal error.
class EmbeddingsBatchEmbedderTest < Minitest::Test
  # Provider double: deterministic vectors, scripted failures, call log.
  class ScriptedProvider < Parse::Embeddings::Provider
    class RateLimitError < Parse::Embeddings::Error; end
    class TransientError < Parse::Embeddings::Error; end
    class FatalError < Parse::Embeddings::Error; end

    attr_reader :calls

    def initialize(batch_size: 2, failures: [])
      @batch_size = batch_size
      @failures = failures # queue of exceptions to raise before succeeding
      @calls = []
    end

    def dimensions; 3; end
    def model_name; "scripted-1"; end
    def embed_batch_size; @batch_size; end

    def embed_text(strings, input_type: :search_document)
      if (err = @failures.shift)
        @calls << { batch: strings.dup, input_type: input_type, raised: err.class.name }
        raise err
      end
      @calls << { batch: strings.dup, input_type: input_type, raised: nil }
      strings.map { |s| [s.length.to_f, 1.0, 2.0] }
    end
  end

  def fast_embedder(provider, **opts)
    # base_delay tiny so retry tests run instantly.
    Parse::Embeddings::BatchEmbedder.new(provider, base_delay: 0.001, jitter: 0.0, **opts)
  end

  def test_rejects_non_provider
    assert_raises(ArgumentError) { Parse::Embeddings::BatchEmbedder.new("nope") }
  end

  def test_empty_input_returns_empty
    provider = ScriptedProvider.new
    assert_equal [], fast_embedder(provider).embed_text([])
    assert_empty provider.calls
  end

  def test_rejects_non_array
    provider = ScriptedProvider.new
    assert_raises(ArgumentError) { fast_embedder(provider).embed_text("one") }
  end

  def test_slices_by_provider_batch_size_and_preserves_order
    provider = ScriptedProvider.new(batch_size: 2)
    vectors = fast_embedder(provider).embed_text(%w[a bb ccc dddd e])
    assert_equal 5, vectors.length
    assert_equal [1.0, 2.0, 3.0, 4.0, 1.0], vectors.map(&:first)
    assert_equal [%w[a bb], %w[ccc dddd], %w[e]], provider.calls.map { |c| c[:batch] }
  end

  def test_explicit_batch_size_overrides_provider_hint
    provider = ScriptedProvider.new(batch_size: 2)
    fast_embedder(provider, batch_size: 4).embed_text(%w[a b c d e])
    assert_equal [4, 1], provider.calls.map { |c| c[:batch].length }
  end

  def test_retries_rate_limit_then_succeeds
    provider = ScriptedProvider.new(
      batch_size: 10,
      failures: [ScriptedProvider::RateLimitError.new("429")],
    )
    vectors = fast_embedder(provider).embed_text(%w[a b])
    assert_equal 2, vectors.length
    assert_equal ["ScriptedProvider::RateLimitError", nil].map { |x| x&.split("::")&.last },
                 provider.calls.map { |c| c[:raised]&.split("::")&.last }
  end

  def test_retries_transient_error
    provider = ScriptedProvider.new(
      batch_size: 10,
      failures: [ScriptedProvider::TransientError.new("503")],
    )
    assert_equal 1, fast_embedder(provider).embed_text(%w[a]).length
  end

  def test_batch_failed_after_max_attempts
    provider = ScriptedProvider.new(
      batch_size: 1,
      failures: Array.new(3) { ScriptedProvider::RateLimitError.new("429") },
    )
    err = assert_raises(Parse::Embeddings::BatchEmbedder::BatchFailed) do
      fast_embedder(provider, max_attempts: 3).embed_text(%w[a b])
    end
    assert_equal 0, err.batch_index
    assert_equal 0, err.completed_count
    assert_includes err.message, "after 3 attempt(s)"
  end

  def test_batch_failed_reports_progress_position
    provider = ScriptedProvider.new(
      batch_size: 1,
      failures: [],
    )
    # First batch succeeds, then two rate limits on the second exhaust
    # max_attempts: 2.
    def provider.embed_text(strings, input_type: :search_document)
      @calls << { batch: strings.dup, input_type: input_type, raised: nil }
      raise EmbeddingsBatchEmbedderTest::ScriptedProvider::RateLimitError, "429" if strings == ["b"]
      strings.map { |s| [s.length.to_f, 1.0, 2.0] }
    end
    err = assert_raises(Parse::Embeddings::BatchEmbedder::BatchFailed) do
      fast_embedder(provider, max_attempts: 2).embed_text(%w[a b c])
    end
    assert_equal 1, err.batch_index
    assert_equal 1, err.completed_count
  end

  def test_non_retryable_error_propagates_immediately
    provider = ScriptedProvider.new(
      batch_size: 10,
      failures: [ScriptedProvider::FatalError.new("401")],
    )
    assert_raises(ScriptedProvider::FatalError) do
      fast_embedder(provider).embed_text(%w[a])
    end
    assert_equal 1, provider.calls.length
  end

  def test_retry_on_override
    provider = ScriptedProvider.new(
      batch_size: 10,
      failures: [ScriptedProvider::FatalError.new("flaky")],
    )
    vectors = fast_embedder(provider, retry_on: [ScriptedProvider::FatalError])
              .embed_text(%w[a])
    assert_equal 1, vectors.length
  end

  def test_on_progress_callback
    provider = ScriptedProvider.new(batch_size: 2)
    events = []
    embedder = fast_embedder(provider, on_progress: ->(**kw) { events << kw })
    embedder.embed_text(%w[a b c])
    assert_equal [
      { done: 2, total: 3, batch_index: 0, batch_count: 2 },
      { done: 3, total: 3, batch_index: 1, batch_count: 2 },
    ], events
  end

  def test_pacing_spaces_calls
    provider = ScriptedProvider.new(batch_size: 1)
    # 1200 rpm => 50ms interval; two batches => one inter-batch wait.
    embedder = fast_embedder(provider, requests_per_minute: 1200)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    embedder.embed_text(%w[a b])
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    assert_operator elapsed, :>=, 0.045
  end

  def test_validation_kwargs
    provider = ScriptedProvider.new
    assert_raises(ArgumentError) { fast_embedder(provider, max_attempts: 0) }
    assert_raises(ArgumentError) { fast_embedder(provider, batch_size: 0) }
  end
end
