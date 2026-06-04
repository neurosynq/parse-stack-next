# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for Parse::Retrieval.retrieve — the agent-agnostic core.
# `find_similar` is stubbed on a fake model so these run without Atlas
# or Docker; they pin the tenant-scope fold, score quantization, chunk
# assembly, source_transform injection, and reserved-kwarg guards.
class RetrievalRetrieveTest < Minitest::Test
  # Minimal directive double exposing the shape retrieve reads from
  # `embed_directives` (sources + image?).
  class FakeDirective
    attr_reader :sources
    def initialize(sources, image: false)
      @sources = sources
      @image = image
    end

    def image?
      @image
    end
  end

  # Fake model standing in for a Parse::Object subclass. Records the
  # kwargs find_similar receives so tests can assert the tenant-scope
  # fold and scope-kwarg pass-through.
  class FakeModel
    class << self
      attr_accessor :last_find_similar_kwargs, :canned_hits

      def parse_class
        "FakeDoc"
      end

      def field_map
        { author_workspace: :authorWorkspace }
      end

      def embed_directives
        { body_embedding: FakeDirective.new([:body]) }
      end

      def find_similar(**kwargs)
        self.last_find_similar_kwargs = kwargs
        canned_hits || []
      end
    end
  end

  def setup
    FakeModel.last_find_similar_kwargs = nil
    FakeModel.canned_hits = nil
  end

  def hit(id:, body:, score:, **extra)
    { "_id" => id, "body" => body, "_vscore" => score }.merge(extra)
  end

  # ----- reserved kwargs -----

  def test_hybrid_reserved
    assert_raises(NotImplementedError) do
      Parse::Retrieval.retrieve(query: "q", klass: FakeModel, hybrid: true)
    end
  end

  def test_rerank_reserved
    assert_raises(NotImplementedError) do
      Parse::Retrieval.retrieve(query: "q", klass: FakeModel, rerank: Object.new)
    end
  end

  # ----- input validation -----

  def test_blank_query_raises
    assert_raises(ArgumentError) { Parse::Retrieval.retrieve(query: "", klass: FakeModel) }
    assert_raises(ArgumentError) { Parse::Retrieval.retrieve(query: "   ", klass: FakeModel) }
  end

  def test_bad_class_raises
    assert_raises(ArgumentError) { Parse::Retrieval.retrieve(query: "q", klass: Object) }
  end

  # ----- tenant-scope fold into vector_filter (wire-name) -----

  def test_tenant_scope_folds_into_vector_filter_with_wire_name
    FakeModel.canned_hits = []
    Parse::Retrieval.retrieve(
      query: "q", klass: FakeModel,
      tenant_scope: { field: :author_workspace, value: "Workspace$abc" },
    )
    vf = FakeModel.last_find_similar_kwargs[:vector_filter]
    # Snake symbol :author_workspace folds to the wire column authorWorkspace.
    assert_equal({ "authorWorkspace" => "Workspace$abc" }, vf)
  end

  def test_tenant_scope_merges_with_existing_vector_filter
    FakeModel.canned_hits = []
    Parse::Retrieval.retrieve(
      query: "q", klass: FakeModel,
      vector_filter: { "category" => "news" },
      tenant_scope: { field: :author_workspace, value: "Workspace$abc" },
    )
    vf = FakeModel.last_find_similar_kwargs[:vector_filter]
    assert_equal "news", vf["category"]
    assert_equal "Workspace$abc", vf["authorWorkspace"]
  end

  def test_tenant_scope_spoof_conflict_raises
    FakeModel.canned_hits = []
    assert_raises(Parse::Retrieval::TenantScopeConflict) do
      Parse::Retrieval.retrieve(
        query: "q", klass: FakeModel,
        vector_filter: { "authorWorkspace" => "Workspace$EVIL" },
        tenant_scope: { field: :author_workspace, value: "Workspace$abc" },
      )
    end
  end

  # ----- scope kwarg pass-through -----

  def test_scope_opts_passthrough_to_find_similar
    FakeModel.canned_hits = []
    Parse::Retrieval.retrieve(query: "q", klass: FakeModel, session_token: "r:tok")
    assert_equal "r:tok", FakeModel.last_find_similar_kwargs[:session_token]
    assert_equal true, FakeModel.last_find_similar_kwargs[:raw]
  end

  # ----- chunk assembly -----

  def test_builds_chunks_with_metadata_and_score
    FakeModel.canned_hits = [hit(id: "doc1", body: "abcdefgh", score: 0.873)]
    chunker = Parse::Retrieval::Chunker::FixedSizeOverlap.new(size: 4, overlap: 0)
    chunks = Parse::Retrieval.retrieve(query: "q", klass: FakeModel, chunker: chunker)
    assert_equal 2, chunks.length
    assert_equal %w[abcd efgh], chunks.map(&:content)
    assert_equal %w[doc1#0 doc1#1], chunks.map(&:id)
    assert_equal [0, 1], chunks.map { |c| c.metadata[:chunk_index] }
    assert(chunks.all? { |c| c.metadata[:chunk_count] == 2 })
    assert(chunks.all? { |c| c.score == 0.873 })
  end

  def test_score_quantize_rounds_to_one_decimal
    FakeModel.canned_hits = [hit(id: "doc1", body: "abcd", score: 0.873)]
    chunker = Parse::Retrieval::Chunker::FixedSizeOverlap.new(size: 4, overlap: 0)
    chunks = Parse::Retrieval.retrieve(query: "q", klass: FakeModel, chunker: chunker, score_quantize: true)
    assert_equal 0.9, chunks.first.score
  end

  def test_no_quantize_keeps_full_precision
    FakeModel.canned_hits = [hit(id: "doc1", body: "abcd", score: 0.873)]
    chunker = Parse::Retrieval::Chunker::FixedSizeOverlap.new(size: 4, overlap: 0)
    chunks = Parse::Retrieval.retrieve(query: "q", klass: FakeModel, chunker: chunker, score_quantize: false)
    assert_equal 0.873, chunks.first.score
  end

  def test_doc_missing_text_field_is_skipped
    FakeModel.canned_hits = [
      { "_id" => "doc1", "_vscore" => 0.5 },          # no body
      hit(id: "doc2", body: "abcd", score: 0.4),
    ]
    chunker = Parse::Retrieval::Chunker::FixedSizeOverlap.new(size: 4, overlap: 0)
    chunks = Parse::Retrieval.retrieve(query: "q", klass: FakeModel, chunker: chunker)
    assert_equal %w[doc2#0], chunks.map(&:id)
  end

  def test_empty_hits_returns_empty
    FakeModel.canned_hits = []
    assert_equal [], Parse::Retrieval.retrieve(query: "q", klass: FakeModel)
  end

  # ----- source_transform injection -----

  def test_source_transform_applied_to_source
    FakeModel.canned_hits = [hit(id: "doc1", body: "abcd", score: 0.5, secret: "x")]
    chunker = Parse::Retrieval::Chunker::FixedSizeOverlap.new(size: 4, overlap: 0)
    projector = ->(doc) { { "objectId" => doc["_id"], "body" => doc["body"] } } # drops :secret
    chunks = Parse::Retrieval.retrieve(query: "q", klass: FakeModel, chunker: chunker,
                                       source_transform: projector)
    refute chunks.first.source.key?("secret")
    assert_equal "doc1", chunks.first.source["objectId"]
  end

  def test_source_transform_raise_propagates
    FakeModel.canned_hits = [hit(id: "doc1", body: "abcd", score: 0.5)]
    boom = ->(_doc) { raise Parse::Agent::AccessDenied.new("FakeDoc", "out of scope") }
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Retrieval.retrieve(query: "q", klass: FakeModel, source_transform: boom)
    end
  end

  # ----- text_field inference -----

  def test_text_field_inferred_from_embed_directive
    FakeModel.canned_hits = [hit(id: "doc1", body: "abcd", score: 0.5)]
    chunker = Parse::Retrieval::Chunker::FixedSizeOverlap.new(size: 4, overlap: 0)
    chunks = Parse::Retrieval.retrieve(query: "q", klass: FakeModel, chunker: chunker)
    assert_equal "abcd", chunks.first.content
  end

  def test_ambiguous_text_field_raises
    ambiguous = Class.new do
      def self.parse_class; "Amb"; end
      def self.field_map; {}; end
      def self.embed_directives
        { e1: FakeDirective.new([:title]), e2: FakeDirective.new([:body]) }
      end
      def self.find_similar(**_); []; end
    end
    assert_raises(Parse::Retrieval::AmbiguousTextField) do
      Parse::Retrieval.retrieve(query: "q", klass: ambiguous)
    end
  end

  def test_explicit_text_field_overrides_inference
    FakeModel.canned_hits = [hit(id: "doc1", body: "ignored", score: 0.5, "headline" => "abcd")]
    chunker = Parse::Retrieval::Chunker::FixedSizeOverlap.new(size: 4, overlap: 0)
    chunks = Parse::Retrieval.retrieve(query: "q", klass: FakeModel, chunker: chunker,
                                       text_field: :headline)
    assert_equal "abcd", chunks.first.content
  end

  # ----- alias -----

  def test_rag_alias
    assert_equal Parse::Retrieval, Parse::RAG
  end
end
