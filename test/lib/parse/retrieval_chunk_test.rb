# encoding: UTF-8
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/parse/retrieval/chunk"

# Unit tests for the Parse::Retrieval::Chunk value object.
class RetrievalChunkTest < Minitest::Test
  Chunk = Parse::Retrieval::Chunk

  def test_to_h_shape
    c = Chunk.new(id: "doc1#0", content: "hello", source: { "objectId" => "doc1" },
                  score: 0.42, metadata: { chunk_index: 0 })
    assert_equal({
      id: "doc1#0",
      score: 0.42,
      content: "hello",
      source: { "objectId" => "doc1" },
      metadata: { chunk_index: 0 },
    }, c.to_h)
  end

  def test_defaults
    c = Chunk.new(id: "a#0", content: "x", source: {})
    assert_nil c.score
    assert_equal({}, c.metadata)
  end

  def test_id_coerced_to_string
    c = Chunk.new(id: :sym, content: "x", source: {})
    assert_equal "sym", c.id
  end

  def test_frozen
    c = Chunk.new(id: "a#0", content: "x", source: {})
    assert c.frozen?
  end

  def test_value_equality_on_identifying_triple
    a = Chunk.new(id: "a#0", content: "x", source: { "k" => 1 }, score: 0.5)
    b = Chunk.new(id: "a#0", content: "x", source: { "k" => 2 }, score: 0.5, metadata: { z: 9 })
    c = Chunk.new(id: "a#1", content: "x", source: {}, score: 0.5)
    assert_equal a, b
    refute_equal a, c
    assert_equal a.hash, b.hash
  end
end
