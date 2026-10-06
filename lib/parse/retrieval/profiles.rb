# encoding: UTF-8
# frozen_string_literal: true

require "timeout"

module Parse
  module Retrieval
    # Server-configured retrieval profiles for the `semantic_search` agent
    # tool.
    #
    # A profile composes the library's existing retrieval paths (vector,
    # hybrid, reranking) with explicit budgets, so an application can offer
    # an agent a few named strategies (for example `fast`, `balanced`,
    # `precise`) without letting the model pick providers, endpoints, or
    # credentials. The agent only ever names a profile; everything else is
    # fixed on the server at registration time.
    #
    # @example
    #   Parse::Retrieval.register_reranker(:voyage,
    #     Parse::Retrieval::Reranker::Voyage.new(api_key: ENV.fetch("VOYAGE_API_KEY"), model: "rerank-3-lite"))
    #
    #   Parse::Retrieval::Profiles.register(:fast, k: 5, max_k: 10)
    #   Parse::Retrieval::Profiles.register(:precise,
    #     reranker: :voyage, rerank_candidates: 30, rerank_top_n: 8,
    #     rerank_max_document_chars: 4_000, rerank_timeout: 5,
    #     on_rerank_failure: :fallback, max_total_tokens: 8_000)
    #
    #   agent.execute(:semantic_search, class_name: "Article", query: "refund policy", profile: "precise")
    #
    # Registration validates the whole configuration, so a misconfigured
    # profile (unknown option, unregistered reranker, non-positive budget)
    # fails at boot rather than mid-request. Without a `profile:` argument
    # `semantic_search` behaves exactly as before.
    module Profiles
      # A validated, frozen profile.
      Profile = Struct.new(
        :name, :k, :max_k, :hybrid, :reranker, :rerank_candidates, :rerank_top_n,
        :rerank_max_document_chars, :rerank_timeout, :on_rerank_failure, :max_total_tokens,
        keyword_init: true,
      ) do
        # @return [Boolean] true when the profile reranks.
        def rerank?
          !reranker.nil?
        end
      end

      ALLOWED_OPTIONS = %i[
        k max_k hybrid reranker rerank_candidates rerank_top_n
        rerank_max_document_chars rerank_timeout on_rerank_failure max_total_tokens
      ].freeze

      # Defaults applied to an option the profile does not set.
      DEFAULTS = {
        k: 10,
        max_k: 20,
        hybrid: nil,
        rerank_candidates: 30,
        rerank_top_n: nil,
        rerank_max_document_chars: 4_000,
        rerank_timeout: 10,
        on_rerank_failure: :fallback,
        max_total_tokens: nil,
      }.freeze

      # Hard ceilings no profile may exceed, so a misconfigured profile still
      # cannot fan out unbounded provider work.
      MAX_RERANK_CANDIDATES = 100
      # semantic_search returns at most this many documents, so a larger
      # max_k could never take effect; it is refused rather than clamped.
      MAX_K = 20
      MAX_RERANK_DOCUMENT_CHARS = 32_000

      FAILURE_MODES = %i[fallback raise].freeze
      # Options that only have an effect when the profile names a reranker.
      RERANK_OPTIONS = %i[rerank_candidates rerank_top_n rerank_max_document_chars rerank_timeout on_rerank_failure].freeze
      HYBRID_KEYS = %i[lexical vector fusion].freeze
      NAME_RE = /\A[a-z][a-z0-9_]{0,39}\z/.freeze

      @registry = {}
      @mutex = Mutex.new

      class << self
        # Register (or replace) a profile.
        #
        # @param name [Symbol, String] lowercase identifier.
        # @param options [Hash] see {ALLOWED_OPTIONS}.
        #   * `k`, `max_k` [Integer]: default and maximum results.
        #   * `hybrid` [true, Hash]: run lexical + vector fusion; a Hash
        #     carries server-side `lexical:`, `vector:`, `fusion:` settings.
        #   * `reranker` [Symbol, String]: a name registered with
        #     {Parse::Retrieval.register_reranker}.
        #   * `rerank_candidates` [Integer]: documents retrieved and sent to
        #     the reranker (capped at {MAX_RERANK_CANDIDATES}).
        #   * `rerank_top_n` [Integer, nil]: documents kept after reranking
        #     (defaults to the effective `k`).
        #   * `rerank_max_document_chars` [Integer]: each document's text is
        #     cut to this length before it is sent to the reranker.
        #   * `rerank_timeout` [Numeric]: seconds allowed for reranking.
        #   * `on_rerank_failure` [:fallback, :raise]: on timeout or provider
        #     failure, keep the retrieval order (observable) or fail the call.
        #   * `max_total_tokens` [Integer, nil]: default response budget.
        # @return [Profile]
        # @raise [ArgumentError] on any invalid option.
        def register(name, **options)
          profile = build(name, options)
          @mutex.synchronize { @registry[profile.name] = profile }
          profile
        end

        # @return [Profile] the registered profile.
        # @raise [Parse::Agent::ValidationError] for an unknown name, listing
        #   the registered ones.
        def fetch!(name)
          key = name.to_s
          profile = @mutex.synchronize { @registry[key] }
          return profile if profile

          raise Parse::Agent::ValidationError,
                "Unknown retrieval profile #{key.inspect}. Available: #{names.inspect}."
        end

        # @return [Array<String>] registered profile names, sorted.
        def names
          @mutex.synchronize { @registry.keys.sort }
        end

        def unregister(name)
          @mutex.synchronize { @registry.delete(name.to_s) }
        end

        def reset!
          @mutex.synchronize { @registry.clear }
        end

        private

        def build(name, options)
          key = name.to_s
          unless key.match?(NAME_RE)
            raise ArgumentError, "Retrieval profile name #{name.inspect} must match #{NAME_RE.inspect}."
          end
          unknown = options.keys.map(&:to_sym) - ALLOWED_OPTIONS
          unless unknown.empty?
            raise ArgumentError,
                  "Retrieval profile #{key.inspect}: unknown option(s) #{unknown.inspect}. " \
                  "Allowed: #{ALLOWED_OPTIONS.inspect}."
          end
          given = options.transform_keys(&:to_sym)
          rerank_only = given.keys & RERANK_OPTIONS
          if given[:reranker].nil? && !rerank_only.empty?
            raise ArgumentError,
                  "Retrieval profile #{key.inspect}: #{rerank_only.inspect} only apply with a reranker:; " \
                  "set reranker: or remove them."
          end
          opts = DEFAULTS.merge(given)

          k = positive_int!(key, :k, opts[:k])
          max_k = positive_int!(key, :max_k, opts[:max_k])
          raise ArgumentError, "Retrieval profile #{key.inspect}: k (#{k}) exceeds max_k (#{max_k})." if k > max_k
          if max_k > MAX_K
            raise ArgumentError,
                  "Retrieval profile #{key.inspect}: max_k #{max_k} exceeds the semantic_search maximum (#{MAX_K})."
          end

          reranker = nil
          unless opts[:reranker].nil?
            reranker = opts[:reranker].to_s
            unless Parse::Retrieval.reranker_registered?(reranker)
              raise ArgumentError,
                    "Retrieval profile #{key.inspect}: reranker #{reranker.inspect} is not registered. " \
                    "Register it with Parse::Retrieval.register_reranker before the profile."
            end
          end

          candidates = positive_int!(key, :rerank_candidates, opts[:rerank_candidates])
          if candidates > MAX_RERANK_CANDIDATES
            raise ArgumentError,
                  "Retrieval profile #{key.inspect}: rerank_candidates #{candidates} exceeds #{MAX_RERANK_CANDIDATES}."
          end
          top_n = opts[:rerank_top_n].nil? ? nil : positive_int!(key, :rerank_top_n, opts[:rerank_top_n])
          if top_n && top_n > candidates
            raise ArgumentError,
                  "Retrieval profile #{key.inspect}: rerank_top_n (#{top_n}) exceeds rerank_candidates (#{candidates})."
          end
          doc_chars = positive_int!(key, :rerank_max_document_chars, opts[:rerank_max_document_chars])
          if doc_chars > MAX_RERANK_DOCUMENT_CHARS
            raise ArgumentError,
                  "Retrieval profile #{key.inspect}: rerank_max_document_chars #{doc_chars} exceeds " \
                  "#{MAX_RERANK_DOCUMENT_CHARS}."
          end
          timeout = opts[:rerank_timeout]
          unless timeout.is_a?(Numeric) && timeout.positive?
            raise ArgumentError, "Retrieval profile #{key.inspect}: rerank_timeout must be a positive number."
          end
          failure = opts[:on_rerank_failure].to_s.to_sym
          unless FAILURE_MODES.include?(failure)
            raise ArgumentError,
                  "Retrieval profile #{key.inspect}: on_rerank_failure must be one of #{FAILURE_MODES.inspect}."
          end
          budget = opts[:max_total_tokens].nil? ? nil : positive_int!(key, :max_total_tokens, opts[:max_total_tokens])

          Profile.new(
            name: key, k: k, max_k: max_k, hybrid: normalize_hybrid!(key, opts[:hybrid]),
            reranker: reranker, rerank_candidates: candidates, rerank_top_n: top_n,
            rerank_max_document_chars: doc_chars, rerank_timeout: timeout,
            on_rerank_failure: failure, max_total_tokens: budget,
          ).freeze
        end

        def positive_int!(key, option, value)
          unless value.is_a?(Integer) && value.positive?
            raise ArgumentError,
                  "Retrieval profile #{key.inspect}: #{option} must be a positive Integer (got #{value.inspect})."
          end
          value
        end

        def normalize_hybrid!(key, hybrid)
          return nil if hybrid.nil? || hybrid == false
          return {} if hybrid == true
          unless hybrid.is_a?(Hash)
            raise ArgumentError, "Retrieval profile #{key.inspect}: hybrid must be true or a Hash."
          end
          extra = hybrid.keys.map(&:to_sym) - HYBRID_KEYS
          unless extra.empty?
            raise ArgumentError,
                  "Retrieval profile #{key.inspect}: unknown hybrid option(s) #{extra.inspect}. " \
                  "Allowed: #{HYBRID_KEYS.inspect}."
          end
          Marshal.load(Marshal.dump(hybrid.transform_keys(&:to_sym))).freeze
        end
      end
    end

    # Wraps a registered reranker with a profile's budgets. Every document
    # is cut to `rerank_max_document_chars`, the call is charged to the
    # caller's spend budget through `charge`, and the provider call is
    # bounded by `rerank_timeout`. On a timeout or provider failure it
    # either returns nil (the retriever then keeps the retrieval order) and
    # records the reason, or re-raises, per `on_rerank_failure`.
    #
    # The text it receives has already passed the `semantic_search` text
    # source check, so it never contains a field outside the agent's
    # effective `agent_fields`.
    class BudgetedReranker
      attr_reader :stats

      # @param inner [#rerank] the registered reranker.
      # @param profile [Profiles::Profile]
      # @param charge [Proc, nil] `charge.call(tokens)`; may raise to refuse.
      def initialize(inner, profile, charge: nil)
        @inner = inner
        @profile = profile
        @charge = charge
        @stats = { used: false, documents: 0, chars: 0, tokens_estimated: 0,
                   duration_ms: 0.0, fallback: false, fallback_reason: nil }
      end

      # Longest query sent to a reranker. The query is paired with every
      # document in the provider call, so an unbounded query multiplies the
      # cost of every rerank.
      MAX_QUERY_CHARS = 2_000

      def rerank(query:, documents:, top_n: nil)
        limit = @profile.rerank_max_document_chars
        query = query.to_s[0, MAX_QUERY_CHARS]
        docs = Array(documents).map { |d| d.to_s[0, limit] }
        tokens = Parse::Embeddings::SpendCap.estimate_tokens(query) * [docs.length, 1].max +
                 docs.sum { |d| Parse::Embeddings::SpendCap.estimate_tokens(d) }
        @stats.merge!(used: true, documents: docs.length, chars: docs.sum(&:length), tokens_estimated: tokens)
        @charge&.call(tokens)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          Timeout.timeout(@profile.rerank_timeout) do
            @inner.rerank(query: query, documents: docs, top_n: top_n)
          end
        rescue Timeout::Error, StandardError => e
          raise if @profile.on_rerank_failure == :raise
          @stats[:fallback] = true
          @stats[:fallback_reason] = e.is_a?(Timeout::Error) ? "timeout" : e.class.name
          nil
        ensure
          @stats[:duration_ms] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
        end
      end
    end

    @rerankers = {}
    @rerankers_mutex = Mutex.new

    class << self
      # Register a reranker under a name that retrieval profiles reference.
      # Profiles name rerankers instead of embedding them so provider
      # objects (and their credentials) stay server-side.
      #
      # @param name [Symbol, String]
      # @param reranker [#rerank]
      def register_reranker(name, reranker)
        unless reranker.respond_to?(:rerank)
          raise ArgumentError, "Parse::Retrieval.register_reranker: #{reranker.class} does not respond to #rerank."
        end
        @rerankers_mutex.synchronize { @rerankers[name.to_s] = reranker }
      end

      # @return [#rerank, nil]
      def reranker(name)
        @rerankers_mutex.synchronize { @rerankers[name.to_s] }
      end

      def reranker_registered?(name)
        !reranker(name).nil?
      end

      def reset_rerankers!
        @rerankers_mutex.synchronize { @rerankers.clear }
      end
    end
  end
end
