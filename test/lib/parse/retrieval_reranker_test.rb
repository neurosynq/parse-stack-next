# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/retrieval/reranker"

# Unit tests for Parse::Retrieval::Reranker — the Base protocol
# (validation + normalization), the deterministic Fixture, and the
# Cohere adapter's response parsing (HTTP stubbed).
class RetrievalRerankerTest < Minitest::Test
  R = Parse::Retrieval::Reranker

  # ----- Base protocol -----

  def test_base_rerank_scores_is_abstract
    assert_raises(NotImplementedError) { R::Base.new.rerank(query: "q", documents: %w[a]) }
  end

  def test_base_validates_query
    rr = Class.new(R::Base) { def rerank_scores(*) = [] }.new
    assert_raises(ArgumentError) { rr.rerank(query: "", documents: %w[a]) }
    assert_raises(ArgumentError) { rr.rerank(query: nil, documents: %w[a]) }
  end

  def test_base_empty_documents_returns_empty
    rr = Class.new(R::Base) { def rerank_scores(*) = raise("should not be called") }.new
    assert_equal [], rr.rerank(query: "q", documents: [])
  end

  def test_base_sorts_descending_and_bounds_top_n
    rr = Class.new(R::Base) { def rerank_scores(_q, _d, _n) = [[0, 0.1], [1, 0.9], [2, 0.5]] }.new
    out = rr.rerank(query: "q", documents: %w[a b c], top_n: 2)
    assert_equal [1, 2], out.map(&:index)
    assert_in_delta 0.9, out.first.relevance_score, 1e-9
  end

  def test_base_rejects_out_of_range_index
    rr = Class.new(R::Base) { def rerank_scores(*) = [[7, 0.5]] }.new
    assert_raises(R::InvalidResponseError) { rr.rerank(query: "q", documents: %w[a]) }
  end

  def test_base_rejects_non_finite_score
    rr = Class.new(R::Base) { def rerank_scores(*) = [[0, Float::INFINITY]] }.new
    assert_raises(R::InvalidResponseError) { rr.rerank(query: "q", documents: %w[a]) }
  end

  def test_base_dedupes_duplicate_indices
    rr = Class.new(R::Base) { def rerank_scores(*) = [[0, 0.9], [0, 0.1]] }.new
    out = rr.rerank(query: "q", documents: %w[a])
    assert_equal 1, out.length
    assert_in_delta 0.9, out.first.relevance_score, 1e-9
  end

  def test_base_rejects_oversized_document_list
    rr = Class.new(R::Base) { def rerank_scores(*) = [] }.new
    big = Array.new(R::Base::MAX_DOCUMENTS + 1, "x")
    assert_raises(ArgumentError) { rr.rerank(query: "q", documents: big) }
  end

  # ----- Fixture reranker (deterministic) -----

  def test_fixture_is_deterministic_and_overlap_ranked
    fx = R::Fixture.new
    docs = ["a song about rain and love", "unrelated cooking recipe", "love", ""]
    a = fx.rerank(query: "rain love", documents: docs)
    b = fx.rerank(query: "rain love", documents: docs)
    assert_equal a.map(&:index), b.map(&:index), "Fixture must be deterministic"
    assert_equal 0, a.first.index, "highest token overlap ranks first"
  end

  # ----- Cohere adapter (HTTP stubbed) -----

  # Minimal Faraday response/connection doubles.
  FakeResp = Struct.new(:status, :body) do
    def headers = {}
  end

  class FakeConn
    def initialize(resp) = (@resp = resp)
    def post(_path) = @resp
  end

  def build_cohere_with_response(status:, body:)
    rr = R::Cohere.allocate
    rr.instance_variable_set(:@api_key, "k")
    rr.instance_variable_set(:@model, "rerank-v3.5")
    rr.instance_variable_set(:@base_url, "https://api.cohere.com/v2")
    rr.instance_variable_set(:@timeout, 30)
    rr.instance_variable_set(:@open_timeout, 5)
    rr.instance_variable_set(:@max_retries, 0)
    rr.instance_variable_set(:@allow_faraday_proxy, false)
    rr.instance_variable_set(:@connection, FakeConn.new(FakeResp.new(status, body)))
    rr
  end

  def test_cohere_parses_results
    body = { "results" => [{ "index" => 2, "relevance_score" => 0.91 },
                           { "index" => 0, "relevance_score" => 0.42 }] }.to_json
    rr = build_cohere_with_response(status: 200, body: body)
    out = rr.rerank(query: "q", documents: %w[a b c])
    assert_equal [2, 0], out.map(&:index)
    assert_in_delta 0.91, out.first.relevance_score, 1e-9
  end

  def test_cohere_401_raises_auth_error
    rr = build_cohere_with_response(status: 401, body: "{}")
    assert_raises(R::Cohere::AuthenticationError) { rr.rerank(query: "q", documents: %w[a]) }
  end

  def test_cohere_bad_json_raises_invalid_response
    rr = build_cohere_with_response(status: 200, body: "not json")
    assert_raises(R::InvalidResponseError) { rr.rerank(query: "q", documents: %w[a]) }
  end

  def test_cohere_inspect_redacts_api_key
    rr = build_cohere_with_response(status: 200, body: "{}")
    refute_match(/\bk\b/, rr.inspect)
    assert_match(/REDACTED/, rr.inspect)
  end

  def test_cohere_constructor_validates
    assert_raises(ArgumentError) { R::Cohere.new(api_key: "") }
    assert_raises(ArgumentError) { R::Cohere.new(api_key: "k", base_url: "ftp://x") }
  end
end
