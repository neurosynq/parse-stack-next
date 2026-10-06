# encoding: UTF-8
# frozen_string_literal: true

require "json"

module Parse
  module Retrieval
    # A small evaluation harness for comparing retrieval profiles.
    #
    # Run a labeled case set through each profile and report quality
    # (recall@k, MRR, hit rate), latency (mean and p95), and estimated rerank
    # usage, overall and per tag. Tags group the cases a deployment cares
    # about: exact names, semantic questions, long documents, restrictive
    # ACLs, tenant boundaries. For ACL and tenant cases, `relevant` lists only
    # what the caller is ALLOWED to retrieve, and `forbidden` lists ids that
    # must never appear; any forbidden hit is reported as a violation.
    #
    # The harness is runner-agnostic. {.semantic_search_runner} drives the
    # real `semantic_search` tool through an agent, so measurements reflect
    # the access policy, budgets, and fallbacks that production uses.
    #
    # @example
    #   cases = Parse::Retrieval::Benchmark.load_cases("eval/cases.json")
    #   runner = Parse::Retrieval::Benchmark.semantic_search_runner(agent, class_name: "Article")
    #   report = Parse::Retrieval::Benchmark.run(cases: cases, profiles: %w[fast precise], runner: runner)
    #   report["precise"][:recall_at_k] # => 0.83
    module Benchmark
      # One labeled query. `relevant` and `forbidden` are object ids.
      Case = Struct.new(:id, :query, :relevant, :forbidden, :tags, keyword_init: true)

      module_function

      # @param path [String] JSON file: an Array of
      #   `{ "id", "query", "relevant": [...], "forbidden": [...], "tags": [...] }`.
      # @return [Array<Case>]
      def load_cases(path)
        Array(JSON.parse(::File.read(path))).map { |h| case_from(h) }
      end

      # @param hash [Hash]
      # @return [Case]
      def case_from(hash)
        h = hash.transform_keys(&:to_s)
        Case.new(
          id: h.fetch("id").to_s, query: h.fetch("query").to_s,
          relevant: Array(h["relevant"]).map(&:to_s), forbidden: Array(h["forbidden"]).map(&:to_s),
          tags: Array(h["tags"]).map(&:to_s),
        )
      end

      # Run every case through every profile.
      #
      # @param cases [Array<Case>]
      # @param profiles [Array<String, nil>] profile names (nil = default search).
      # @param runner [#call] `runner.call(case, profile)` returning
      #   `{ ids: Array<String> ranked best-first, tokens_estimated: Integer }`.
      # @param k [Integer] cutoff for recall and hits.
      # @return [Hash{String => Hash}] per-profile report.
      def run(cases:, profiles:, runner:, k: 10)
        profiles.each_with_object({}) do |profile, report|
          rows = cases.map { |c| score_case(c, profile, runner, k) }
          report[profile.nil? ? "default" : profile.to_s] = summarize(rows).merge(
            by_tag: rows.flat_map { |r| r[:tags].map { |t| [t, r] } }
                        .group_by(&:first)
                        .transform_values { |pairs| summarize(pairs.map(&:last)) },
          )
        end
      end

      # A runner that executes the `semantic_search` tool through `agent`
      # and ranks parent documents by their first chunk.
      #
      # @param agent [Parse::Agent]
      # @param class_name [String]
      # @param options [Hash] extra semantic_search arguments.
      # @return [Proc]
      def semantic_search_runner(agent, class_name:, **options)
        lambda do |bench_case, profile|
          tokens = 0
          # Notifications are delivered on the instrumenting thread, so only
          # events from THIS thread belong to this case; other threads'
          # searches are ignored.
          runner_thread = Thread.current
          sub = if defined?(ActiveSupport::Notifications)
              ActiveSupport::Notifications.subscribe("parse.retrieval.search") do |*args|
                next unless Thread.current.equal?(runner_thread)
                payload = args.last
                tokens += payload.dig(:rerank, :tokens_estimated).to_i if payload.is_a?(Hash)
              end
            end
          begin
            args = { class_name: class_name, query: bench_case.query }.merge(options)
            args[:profile] = profile unless profile.nil?
            result = agent.execute(:semantic_search, **args)
            data = result[:success] ? (result[:data] || {}) : {}
            chunks = data[:chunks] || data["chunks"] || []
            ids = chunks.map { |c| (c[:metadata] || c["metadata"] || {})[:object_id] || c.dig("metadata", "object_id") }
                        .compact.map(&:to_s).uniq
            { ids: ids, tokens_estimated: tokens, error: result[:success] ? nil : result[:error_code] }
          ensure
            ActiveSupport::Notifications.unsubscribe(sub) if sub
          end
        end
      end

      # @!visibility private
      def score_case(bench_case, profile, runner, k)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        out = runner.call(bench_case, profile) || {}
        ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
        ids = Array(out[:ids]).map(&:to_s)
        top = ids.first(k)
        relevant = bench_case.relevant
        found = relevant & top
        # MRR is cut off at k, like recall: a relevant hit below the cutoff
        # scores 0.
        first_rank = top.index { |id| relevant.include?(id) }
        {
          tags: bench_case.tags,
          recall: relevant.empty? ? (top.empty? ? 1.0 : 0.0) : found.size.to_f / relevant.size,
          reciprocal_rank: first_rank ? 1.0 / (first_rank + 1) : 0.0,
          hit: !found.empty? || (relevant.empty? && top.empty?),
          violations: (bench_case.forbidden & ids).size,
          ms: ms,
          tokens: out[:tokens_estimated].to_i,
          error: out[:error],
        }
      end

      # @!visibility private
      def summarize(rows)
        n = rows.size
        return { cases: 0 } if n.zero?
        latencies = rows.map { |r| r[:ms] }.sort
        {
          cases: n,
          recall_at_k: (rows.sum { |r| r[:recall] } / n).round(4),
          mrr: (rows.sum { |r| r[:reciprocal_rank] } / n).round(4),
          hit_rate: (rows.count { |r| r[:hit] }.to_f / n).round(4),
          violations: rows.sum { |r| r[:violations] },
          errors: rows.count { |r| r[:error] },
          mean_ms: (latencies.sum / n).round(1),
          p95_ms: latencies[[(n * 0.95).ceil - 1, 0].max].round(1),
          tokens_estimated: rows.sum { |r| r[:tokens] },
        }
      end
    end
  end
end
