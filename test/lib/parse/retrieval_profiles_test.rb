# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/agent"

# Server-configured retrieval profiles on the semantic_search tool: boot-time
# validation, k/candidate/top_n budgets, reranker text and spend budgets,
# observable fallback, the sanitized parse.retrieval.search event, and the
# benchmark harness. find_similar is the only stubbed boundary in the end-to-
# end cases, so the real retrieve/rerank/chunk path runs.
class RetrievalProfilesTest < Minitest::Test
  P = Parse::Retrieval::Profiles

  class ProfDoc < Parse::Object
    parse_class "RetrievalProfileDoc"
    property :title, :string
    property :body, :string
    property :embedding, :vector, dimensions: 8, provider: :fixture
    embed :body, into: :embedding
    agent_searchable field: :embedding
  end

  # Deterministic reranker: reverses the input order, records what it saw.
  class ReverseReranker
    attr_reader :seen

    def rerank(query:, documents:, top_n: nil)
      @seen = { query: query, documents: documents, top_n: top_n }
      documents.each_index.to_a.reverse.first(top_n || documents.size).each_with_index.map do |i, rank|
        Parse::Retrieval::Reranker::Result.new(index: i, relevance_score: 1.0 - (rank * 0.1))
      end
    end
  end

  class FailingReranker
    def rerank(**)
      raise Parse::Retrieval::Reranker::Error, "provider down"
    end
  end

  class SlowReranker
    def rerank(**)
      sleep 2
      []
    end
  end

  def setup
    P.reset!
    Parse::Retrieval.reset_rerankers!
    @reverse = ReverseReranker.new
    Parse::Retrieval.register_reranker(:reverse, @reverse)
    Parse::Retrieval.register_reranker(:failing, FailingReranker.new)
    Parse::Retrieval.register_reranker(:slow, SlowReranker.new)
  end

  def teardown
    P.reset!
    Parse::Retrieval.reset_rerankers!
  end

  def fake_agent(permissions: :readonly)
    a = Object.new
    a.define_singleton_method(:permissions) { permissions }
    a.define_singleton_method(:acl_scope_kwargs) { { master: true } }
    a
  end

  # ---- registration ----------------------------------------------------

  def test_register_validates_at_boot
    assert_raises(ArgumentError) { P.register(:bad, nope: 1) }
    assert_raises(ArgumentError) { P.register(:bad, reranker: :not_registered) }
    assert_raises(ArgumentError) { P.register(:bad, k: 30, max_k: 10) }
    assert_raises(ArgumentError) { P.register(:bad, rerank_candidates: 500) }
    assert_raises(ArgumentError) { P.register(:bad, rerank_candidates: 5, rerank_top_n: 9) }
    assert_raises(ArgumentError) { P.register(:bad, on_rerank_failure: :ignore) }
    assert_raises(ArgumentError) { P.register(:bad, hybrid: { endpoint: "https://evil" }) }
    assert_raises(ArgumentError) { P.register(:bad, rerank_timeout: 0) }
    assert_raises(ArgumentError) { P.register("Not Valid", k: 1) }
    assert_raises(ArgumentError) { P.register(:wide, k: 30, max_k: 50) }
    assert_empty P.names
  end

  def test_unknown_profile_is_refused_with_the_available_names
    P.register(:fast, k: 5)
    err = assert_raises(Parse::Agent::ValidationError) { P.fetch!("precise") }
    assert_match(/"fast"/, err.message)
  end

  # ---- semantic_search wiring -----------------------------------------

  def with_retrieve_spy
    captured = {}
    Parse::Retrieval.stub(:retrieve, ->(**kw) { captured.replace(kw); [] }) { yield captured }
  end

  def call(**args)
    Parse::Retrieval::AgentTool.semantic_search(fake_agent, class_name: "RetrievalProfileDoc", query: "q", **args)
  end

  def test_no_profile_keeps_the_default_search
    with_retrieve_spy do |c|
      call
      assert_equal Parse::Retrieval::AgentTool::DEFAULT_K, c[:k]
      assert_nil c[:rerank]
      assert_nil c[:hybrid]
    end
  end

  def test_profile_bounds_k_by_max_k
    P.register(:fast, k: 4, max_k: 6)
    with_retrieve_spy do |c|
      call(profile: "fast")
      assert_equal 4, c[:k], "profile default k applies when the caller omits k"
      call(profile: "fast", k: 50)
      assert_equal 6, c[:k], "caller k is capped at max_k"
    end
  end

  def test_reranking_profile_retrieves_candidates_and_keeps_top_n
    P.register(:precise, k: 5, reranker: :reverse, rerank_candidates: 25, rerank_top_n: 3, hybrid: true)
    with_retrieve_spy do |c|
      result = call(profile: "precise")
      assert_equal 25, c[:k]
      assert_equal 3, c[:rerank_top_n]
      assert_kind_of Parse::Retrieval::BudgetedReranker, c[:rerank]
      assert_equal({}, c[:hybrid])
      assert_equal "precise", result[:profile]
    end
  end

  class HybridDoc < Parse::Object
    parse_class "RetrievalProfileHybridDoc"
    property :title, :string
    property :body, :string
    property :secret, :string
    property :embedding, :vector, dimensions: 8, provider: :fixture
    embed :body, into: :embedding
    agent_searchable field: :embedding
    agent_fields :title, :body
  end

  def test_hybrid_profile_lexical_branch_searches_only_readable_text
    P.register(:balanced, k: 5, hybrid: true)
    captured = {}
    Parse::Retrieval.stub(:retrieve, ->(**kw) { captured.replace(kw); [] }) do
      Parse::Retrieval::AgentTool.semantic_search(fake_agent, class_name: "RetrievalProfileHybridDoc",
                                                              query: "q", profile: "balanced")
    end
    assert_equal ["body"], captured[:hybrid][:lexical][:fields], "never a wildcard over hidden fields"
  end

  def test_caller_k_cannot_exceed_the_rerank_candidate_budget
    P.register(:tight, k: 2, max_k: 20, reranker: :reverse, rerank_candidates: 2)
    with_retrieve_spy do |c|
      call(profile: "tight", k: 20)
      assert_equal 2, c[:k], "retrieval stays within rerank_candidates"
      assert_equal 2, c[:rerank_top_n]
    end
  end

  # ---- end to end through the real retriever ----------------------------

  def hits(n)
    (1..n).map { |i| { "_id" => "d#{i}", "title" => "t#{i}", "body" => "body #{i} " + ("x" * 50), "_vscore" => 1.0 - i * 0.01 } }
  end

  def run_search(profile:, n: 5)
    ProfDoc.stub(:find_similar, ->(**_kw) { hits(n) }) do
      Parse::Retrieval::AgentTool.stub(:convert_to_parse_form, ->(doc, _c) { doc.dup }) do
        call(profile: profile)
      end
    end
  end

  def test_reranker_receives_truncated_text_and_reorders
    P.register(:precise, k: 3, reranker: :reverse, rerank_candidates: 5, rerank_top_n: 3,
                         rerank_max_document_chars: 10)
    result = run_search(profile: "precise")
    assert @reverse.seen[:documents].all? { |d| d.length <= 10 }, "documents are cut before reranking"
    ids = result[:chunks].map { |ch| ch[:metadata][:object_id] }
    assert_equal %w[d5 d4 d3], ids
    refute result.key?(:rerank_fallback)
  end

  def test_rerank_failure_falls_back_observably
    P.register(:precise, k: 3, reranker: :failing, rerank_candidates: 5)
    result = run_search(profile: "precise")
    assert_equal %w[d1 d2 d3], result[:chunks].map { |ch| ch[:metadata][:object_id] }, "retrieval order kept"
    assert_equal true, result[:rerank_fallback]
    assert_equal "Parse::Retrieval::Reranker::Error", result[:rerank_fallback_reason]
  end

  def test_rerank_timeout_falls_back
    P.register(:precise, k: 2, reranker: :slow, rerank_candidates: 3, rerank_timeout: 0.05)
    result = run_search(profile: "precise", n: 3)
    assert_equal "timeout", result[:rerank_fallback_reason]
  end

  def test_raise_mode_fails_the_call
    P.register(:strict, k: 2, reranker: :failing, rerank_candidates: 3, on_rerank_failure: :raise)
    assert_raises(Parse::Retrieval::Reranker::Error) { run_search(profile: "strict", n: 3) }
  end

  def test_rerank_tokens_are_charged_to_the_spend_cap
    P.register(:precise, k: 3, reranker: :reverse, rerank_candidates: 5)
    charged = []
    Parse::Embeddings::SpendCap.stub(:charge!, ->(tenant_id:, tokens:) { charged << tokens; nil }) do
      run_search(profile: "precise")
    end
    assert_equal 2, charged.size, "query embedding and rerank are both charged"
    assert_operator charged.last, :>, 0
  end

  def test_search_event_is_sanitized
    P.register(:precise, k: 3, reranker: :reverse, rerank_candidates: 5)
    events = []
    sub = ActiveSupport::Notifications.subscribe("parse.retrieval.search") { |*a| events << a.last }
    begin
      run_search(profile: "precise")
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
    assert_equal 1, events.size
    e = events.first
    assert_equal "precise", e[:profile]
    assert_equal 5, e[:candidates]
    assert_equal true, e[:rerank][:used]
    assert_operator e[:rerank][:tokens_estimated], :>, 0
    blob = e.to_s
    refute_includes blob, "body 1", "event must not carry document text"
    refute_includes blob, "q\"", "event must not carry the query"
  end

  def test_failed_search_emits_a_sanitized_event
    events = []
    sub = ActiveSupport::Notifications.subscribe("parse.retrieval.search") { |*a| events << a.last }
    begin
      assert_raises(Parse::Agent::ValidationError) { call(profile: "no-such-profile") }
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
    assert_equal 1, events.size
    assert_equal "Parse::Agent::ValidationError", events.first[:error]
    assert_equal "no-such-profile", events.first[:profile]
    refute events.first.key?(:query)
  end

  def test_profile_budget_cannot_be_disabled_or_raised_by_the_caller
    P.register(:capped, k: 5, max_total_tokens: 40)
    big = (1..5).map { |i| { "_id" => "d#{i}", "title" => "t", "body" => "y" * 200, "_vscore" => 0.9 } }
    result = ProfDoc.stub(:find_similar, ->(**_kw) { big }) do
      Parse::Retrieval::AgentTool.stub(:convert_to_parse_form, ->(doc, _c) { doc.dup }) do
        call(profile: "capped", max_total_tokens: 0)
      end
    end
    assert_equal true, result[:budget_truncated], "max_total_tokens: 0 does not disable a profile budget"
    assert_operator result[:count], :<, 5
  end

  def test_budget_counts_parent_documents
    chunk = ->(oid, content, source) do
      Parse::Retrieval::Chunk.new(id: "#{oid}#0", content: content, score: 0.5, source: source,
                                  metadata: { chunk_index: 0, chunk_count: 1, object_id: oid })
    end
    heavy = { "objectId" => "a", "notes" => "z" * 400 }
    chunks = [chunk.("a", "short", heavy), chunk.("b", "short", { "objectId" => "b" })]
    kept, dropped = Parse::Retrieval::AgentTool.send(:apply_token_budget, chunks, 60)
    assert_equal 1, kept.size, "the first document's size counts toward the budget"
    assert_equal 1, dropped
  end

  # ---- benchmark harness -------------------------------------------------

  def test_benchmark_reports_quality_violations_and_tags
    cases = Parse::Retrieval::Benchmark.load_cases(File.expand_path("../../fixtures/retrieval_benchmark/cases.json", __dir__))
    assert_equal 7, cases.size
    perfect = ->(c, _p) { { ids: c.relevant, tokens_estimated: 10 } }
    leaky = ->(c, _p) { { ids: c.relevant + c.forbidden, tokens_estimated: 0 } }
    report = Parse::Retrieval::Benchmark.run(cases: cases, profiles: [nil, "precise"], runner: ->(c, p) { p ? perfect.(c, p) : leaky.(c, p) })
    assert_equal 1.0, report["precise"][:recall_at_k]
    assert_equal 0, report["precise"][:violations]
    assert_equal 70, report["precise"][:tokens_estimated]
    assert_operator report["default"][:violations], :>, 0, "forbidden ids are counted as violations"
    assert_equal 2, report["precise"][:by_tag]["exact_name"][:cases]
  end
end
