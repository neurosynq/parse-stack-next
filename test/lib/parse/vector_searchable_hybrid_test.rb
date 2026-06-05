# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/vector_search/hybrid"

# Unit tests for Parse::Core::VectorSearchable#hybrid_search — the
# class-level wrapper — and #build_hybrid_hits. Parse::VectorSearch::Hybrid.search
# is stubbed so these run without Atlas; they pin (a) the kwargs the
# wrapper threads into Hybrid.search, and (b) that fused raw rows become
# Parse::Object instances carrying #hybrid_score / #hybrid_ranks /
# #vector_score / #search_score.
class VectorSearchableHybridTest < Minitest::Test
  def self.register_fixture
    Parse::Embeddings.register(:fixture_hyb, Parse::Embeddings::Fixture.new(dimensions: 4))
  end
  register_fixture

  class HybDoc < Parse::Object
    parse_class "HybDoc"
    property :title, :string
    property :embedding, :vector, dimensions: 4, provider: :fixture_hyb
    embed :title, into: :embedding
  end

  def test_hybrid_search_threads_kwargs_into_hybrid_module
    captured = nil
    fake = lambda do |collection, **kw|
      captured = { collection: collection }.merge(kw)
      []
    end
    Parse::VectorSearch::Hybrid.stub(:search, fake) do
      HybDoc.hybrid_search(
        text: "love and rain",
        lexical: { index: "hyb_lex" },
        vector: { index: "hyb_vec", num_candidates: 150 },
        k: 12,
        fusion: { k_constant: 40, weights: { lexical: 0.3, vector: 0.7 } },
        session_token: "tok",
      )
    end
    refute_nil captured
    assert_equal "HybDoc", captured[:collection]
    assert_equal "love and rain", captured[:lexical][:query] # defaults to text
    assert_equal "hyb_lex", captured[:lexical][:index]
    assert_equal :embedding, captured[:vector][:field]       # sole vector field
    assert_equal 150, captured[:vector][:num_candidates]
    assert_kind_of Array, captured[:vector][:query_vector]   # text embedded
    assert_equal 12, captured[:k]
    assert_equal 40, captured[:fusion][:k_constant]
    assert_equal "tok", captured[:session_token]
  end

  def test_hybrid_search_requires_a_query
    assert_raises(ArgumentError) do
      HybDoc.hybrid_search(lexical: {}, vector: {})
    end
  end

  def test_build_hybrid_hits_attaches_scores_and_ranks
    fused_rows = [
      {
        "_id" => "abc123", "title" => "rain song",
        "_hybrid_score" => 0.0321, "_hybrid_ranks" => { lexical: 2, vector: 1 },
        "_vscore" => 0.9, "_score" => 7.5,
      },
    ]
    Parse::VectorSearch::Hybrid.stub(:search, ->(*_a, **_k) { fused_rows }) do
      hits = HybDoc.hybrid_search(text: "rain", vector: { index: "hyb_vec" }, raw: false)
      assert_equal 1, hits.length
      obj = hits.first
      assert_kind_of Parse::Object, obj
      assert_in_delta 0.0321, obj.hybrid_score, 1e-9
      assert_equal({ lexical: 2, vector: 1 }, obj.hybrid_ranks)
      assert_in_delta 0.9, obj.vector_score, 1e-9
      assert_in_delta 7.5, obj.search_score, 1e-9
    end
  end

  def test_hybrid_search_raw_returns_rows
    fused_rows = [{ "_id" => "x", "_hybrid_score" => 0.1 }]
    Parse::VectorSearch::Hybrid.stub(:search, ->(*_a, **_k) { fused_rows }) do
      out = HybDoc.hybrid_search(text: "rain", vector: { index: "hyb_vec" }, raw: true)
      assert_equal fused_rows, out
    end
  end
end
