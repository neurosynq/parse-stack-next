# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Retrieval
    # Cross-encoder reranking for retrieved documents.
    #
    # A reranker takes a query and a list of candidate document texts and
    # returns a relevance-ordered scoring. It runs AFTER the (vector,
    # lexical, or hybrid) retrieval step and BEFORE chunking, reordering
    # the retrieved documents by a more expensive cross-encoder relevance
    # model than the first-stage similarity score.
    #
    # == Protocol
    #
    # A reranker is any object that responds to:
    #
    #   #rerank(query:, documents:, top_n: nil) -> Array<Result>
    #
    # where `documents` is an Array<String> and the return is an Array of
    # {Result} (`index` into `documents`, plus `relevance_score`),
    # descending by relevance. Implementations MUST:
    #
    # * Return at most `documents.length` results (and at most `top_n`
    #   when given).
    # * Use 0-based `index` values that are valid positions in the input.
    # * Never raise for an empty `documents` list — return `[]`.
    #
    # {Base} provides input validation and result normalization so
    # adapters only implement the network call ({Base#rerank_scores}).
    #
    # @example wiring into retrieve
    #   reranker = Parse::Retrieval::Reranker::Cohere.new(api_key: ENV.fetch("COHERE_API_KEY"))
    #   chunks = Parse::Retrieval.retrieve(query: q, klass: Article, k: 30,
    #                                      rerank: reranker, rerank_top_n: 5)
    module Reranker
      # The Cohere `/v2/rerank` adapter is loaded lazily — it requires
      # Faraday, which the core retrieval path does not.
      autoload :Cohere, ::File.expand_path("reranker/cohere", __dir__)

      # Base error for the reranker layer. Adapters raise subclasses.
      class Error < StandardError; end

      # Raised when a reranker returns a response that doesn't satisfy the
      # protocol (bad index, non-numeric score, over-length result set).
      class InvalidResponseError < Error; end

      # A single rerank result: the 0-based position of a document in the
      # input list, plus its cross-encoder relevance score (higher is more
      # relevant; range is provider-defined).
      Result = Struct.new(:index, :relevance_score, keyword_init: true)

      # Common superclass: validates inputs, bounds `top_n`, and
      # normalizes raw `(index, score)` pairs into sorted {Result}s.
      # Concrete adapters implement {#rerank_scores}.
      class Base
        # Hard cap on the number of documents a single rerank call may
        # carry, to bound provider cost / payload size. Providers
        # typically cap around 1000; we stay conservative.
        MAX_DOCUMENTS = 1000

        # Rerank `documents` against `query`.
        #
        # @param query [String] the natural-language query.
        # @param documents [Array<String>] candidate document texts.
        # @param top_n [Integer, nil] return at most this many results.
        # @return [Array<Result>] descending by `relevance_score`.
        def rerank(query:, documents:, top_n: nil)
          unless query.is_a?(String) && !query.strip.empty?
            raise ArgumentError, "#{self.class}#rerank: query must be a non-empty String."
          end
          docs = Array(documents).map(&:to_s)
          return [] if docs.empty?
          if docs.length > MAX_DOCUMENTS
            raise ArgumentError,
                  "#{self.class}#rerank: #{docs.length} documents exceeds MAX_DOCUMENTS=#{MAX_DOCUMENTS}."
          end
          n = top_n.nil? ? docs.length : [Integer(top_n), docs.length].min
          n = docs.length if n <= 0

          pairs = rerank_scores(query, docs, n)
          normalize_results(pairs, docs.length, n)
        end

        protected

        # Adapter hook: return an Array of `[index, score]` pairs (or
        # {Result}s) for `documents`. `top_n` is a hint; the base class
        # re-bounds and re-sorts regardless.
        #
        # @param query [String]
        # @param documents [Array<String>]
        # @param top_n [Integer]
        # @return [Array<Array(Integer, Numeric)>, Array<Result>]
        def rerank_scores(query, documents, top_n)
          raise NotImplementedError, "#{self.class}#rerank_scores must be implemented."
        end

        private

        def normalize_results(pairs, doc_count, top_n)
          results = Array(pairs).map do |p|
            idx, score =
              case p
              when Result then [p.index, p.relevance_score]
              when Array  then [p[0], p[1]]
              when Hash   then [p[:index] || p["index"], p[:relevance_score] || p["relevance_score"]]
              else
                raise InvalidResponseError, "#{self.class}: unexpected rerank result element #{p.inspect}."
              end
            i = Integer(idx)
            unless i >= 0 && i < doc_count
              raise InvalidResponseError,
                    "#{self.class}: rerank index #{i} out of range 0...#{doc_count}."
            end
            unless score.is_a?(Numeric) && score.to_f.finite?
              raise InvalidResponseError,
                    "#{self.class}: rerank relevance_score #{score.inspect} is not a finite number."
            end
            Result.new(index: i, relevance_score: score.to_f)
          end
          # Defensive: drop duplicate indices (keep the first / highest),
          # then sort descending and bound to top_n.
          seen = {}
          results.each { |r| seen[r.index] ||= r }
          seen.values.sort_by { |r| [-r.relevance_score, r.index] }.first(top_n)
        end
      end

      # Deterministic, zero-network reranker for tests and offline use.
      # Scores each document by lexical token overlap with the query
      # (Jaccard-ish: shared unique lowercased word count, tie-broken by
      # input order). No external dependency, fully reproducible.
      class Fixture < Base
        protected

        def rerank_scores(query, documents, _top_n)
          q_tokens = tokenize(query)
          documents.each_with_index.map do |doc, i|
            d_tokens = tokenize(doc)
            overlap = (q_tokens & d_tokens).length
            # Normalize into a 0..1-ish score so output looks like a real
            # relevance score; longer-overlap docs rank higher.
            denom = [q_tokens.length, 1].max
            [i, overlap.to_f / denom]
          end
        end

        private

        def tokenize(text)
          text.to_s.downcase.scan(/[a-z0-9]+/).uniq
        end
      end
    end
  end
end
