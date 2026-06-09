# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Embeddings
    # Batch-level orchestration for bulk embedding jobs.
    #
    # {Provider#embed_text_batched} only slices input into
    # provider-sized chunks; any retry/backoff lives inside each
    # provider's single HTTP call. That is the wrong layer for bulk
    # work: a 50k-document backfill needs *batch-level* pacing (stay
    # under the provider's requests-per-minute budget across calls) and
    # *batch-level* backoff (a 429 after the provider's internal retries
    # are exhausted should pause the whole job, not kill it).
    # {BatchEmbedder} wraps any registered provider with both.
    #
    # @example Backfill with pacing and backoff
    #   embedder = Parse::Embeddings::BatchEmbedder.new(
    #     Parse::Embeddings.provider(:openai),
    #     requests_per_minute: 60,
    #     max_attempts: 5,
    #   )
    #   vectors = embedder.embed_text(texts, input_type: :search_document)
    #
    # @example Progress reporting
    #   embedder = Parse::Embeddings::BatchEmbedder.new(provider,
    #     on_progress: ->(done:, total:, batch_index:, batch_count:) {
    #       puts "#{done}/#{total}"
    #     })
    #
    # == Retry classification
    #
    # By default a batch is retried when the provider raises a
    # {Parse::Embeddings::Error} subclass whose class name ends in
    # `RateLimitError` or `TransientError` — the convention every
    # bundled provider follows (`OpenAI::RateLimitError`,
    # `Voyage::TransientError`, …). Pass `retry_on:` with explicit
    # exception classes to override. Non-retryable errors (auth,
    # bad-request, response-contract violations) propagate immediately.
    #
    # Vectors are returned aligned 1:1 with the input, identical to
    # `embed_text` on the wrapped provider.
    class BatchEmbedder
      # Raised when a batch still fails after `max_attempts` retryable
      # failures. Wraps the final provider error in `#cause` and carries
      # the index of the failing batch so a resumable job knows where to
      # pick up.
      class BatchFailed < Parse::Embeddings::Error
        # @return [Integer] zero-based index of the failing batch.
        attr_reader :batch_index
        # @return [Integer] number of inputs successfully embedded before the failure.
        attr_reader :completed_count

        def initialize(message, batch_index:, completed_count:)
          @batch_index = batch_index
          @completed_count = completed_count
          super(message)
        end
      end

      RETRYABLE_NAME_SUFFIXES = %w[RateLimitError TransientError].freeze

      # @return [Provider] the wrapped provider.
      attr_reader :provider

      # @param provider [Provider] any registered embedding provider.
      # @param batch_size [Integer, nil] inputs per provider call.
      #   Defaults to the provider's own {Provider#embed_batch_size}
      #   hint, falling back to 64 when the provider has none.
      # @param requests_per_minute [Numeric, nil] batch-level pacing
      #   budget. When set, consecutive provider calls are spaced at
      #   least `60.0 / requests_per_minute` seconds apart. nil disables
      #   pacing.
      # @param max_attempts [Integer] attempts per batch (1 = no retry).
      # @param base_delay [Numeric] first backoff delay in seconds;
      #   doubles per attempt.
      # @param max_delay [Numeric] backoff ceiling in seconds.
      # @param jitter [Numeric] random multiplier range added to each
      #   delay (`delay * (1 + rand * jitter)`); spreads thundering
      #   herds when several workers back off together.
      # @param retry_on [Array<Class>, nil] explicit retryable exception
      #   classes; nil uses the name-suffix convention described above.
      # @param on_progress [#call, nil] callable invoked after each
      #   successful batch with `done:, total:, batch_index:, batch_count:`.
      def initialize(provider, batch_size: nil, requests_per_minute: nil,
                     max_attempts: 5, base_delay: 2.0, max_delay: 60.0,
                     jitter: 0.25, retry_on: nil, on_progress: nil)
        unless provider.is_a?(Provider)
          raise ArgumentError,
                "Parse::Embeddings::BatchEmbedder expects a Parse::Embeddings::Provider " \
                "(got #{provider.class})."
        end
        @provider = provider
        @batch_size = batch_size ? Integer(batch_size) : nil
        raise ArgumentError, "batch_size must be positive" if @batch_size && @batch_size <= 0
        @min_interval = requests_per_minute ? (60.0 / Float(requests_per_minute)) : nil
        @max_attempts = Integer(max_attempts)
        raise ArgumentError, "max_attempts must be >= 1" if @max_attempts < 1
        @base_delay = Float(base_delay)
        @max_delay = Float(max_delay)
        @jitter = Float(jitter)
        @retry_on = retry_on && Array(retry_on)
        @on_progress = on_progress
        @last_call_at = nil
      end

      # Embed `strings` through the wrapped provider with pacing and
      # batch-level backoff.
      #
      # @param strings [Array<String>]
      # @param input_type [Symbol]
      # @return [Array<Array<Float>>] aligned 1:1 with `strings`.
      # @raise [BatchFailed] when a batch exhausts its attempts.
      def embed_text(strings, input_type: :search_document)
        unless strings.is_a?(Array)
          raise ArgumentError,
                "Parse::Embeddings::BatchEmbedder#embed_text expects Array<String> " \
                "(got #{strings.class})."
        end
        return [] if strings.empty?

        size = @batch_size || @provider.embed_batch_size || 64
        batches = strings.each_slice(size).to_a
        out = []
        batches.each_with_index do |batch, idx|
          out.concat(run_batch(batch, input_type, idx, out.length))
          if @on_progress
            @on_progress.call(done: out.length, total: strings.length,
                              batch_index: idx, batch_count: batches.length)
          end
        end
        out
      end

      private

      def run_batch(batch, input_type, batch_index, completed_count)
        attempts = 0
        begin
          attempts += 1
          pace!
          @provider.embed_text(batch, input_type: input_type)
        rescue StandardError => e
          raise unless retryable?(e)
          if attempts >= @max_attempts
            raise BatchFailed.new(
              "Parse::Embeddings::BatchEmbedder: batch #{batch_index} failed after " \
              "#{attempts} attempt(s) — #{e.class}: #{e.message}",
              batch_index: batch_index, completed_count: completed_count,
            )
          end
          sleep(backoff_delay(attempts))
          retry
        end
      end

      def retryable?(error)
        if @retry_on
          return @retry_on.any? { |klass| error.is_a?(klass) }
        end
        return false unless error.is_a?(Parse::Embeddings::Error)
        name = error.class.name.to_s
        RETRYABLE_NAME_SUFFIXES.any? { |suffix| name.end_with?(suffix) }
      end

      def backoff_delay(attempt)
        delay = [@base_delay * (2**(attempt - 1)), @max_delay].min
        delay * (1.0 + rand * @jitter)
      end

      # Enforce the inter-call interval. Measured from the START of the
      # previous call so a slow provider response counts toward the
      # interval rather than stacking on top of it.
      def pace!
        return if @min_interval.nil?
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if @last_call_at
          wait = (@last_call_at + @min_interval) - now
          if wait > 0
            sleep(wait)
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end
        @last_call_at = now
      end
    end
  end
end
