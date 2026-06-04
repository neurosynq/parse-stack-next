# encoding: UTF-8
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/parse/retrieval/chunker"

# Unit tests for Parse::Retrieval::Chunker::FixedSizeOverlap and the
# Chunker::Base contract. The chunker is a pure text transform with no
# dependency on Parse, a provider, or Docker — these load the chunker
# file directly and run without the full stack.
class RetrievalChunkerTest < Minitest::Test
  FSO = Parse::Retrieval::Chunker::FixedSizeOverlap

  # ----- construction guards -----

  def test_rejects_non_positive_size
    assert_raises(ArgumentError) { FSO.new(size: 0, overlap: 0) }
    assert_raises(ArgumentError) { FSO.new(size: -5, overlap: 0) }
    assert_raises(ArgumentError) { FSO.new(size: 10.5, overlap: 0) }
  end

  def test_rejects_negative_overlap
    assert_raises(ArgumentError) { FSO.new(size: 10, overlap: -1) }
  end

  def test_rejects_overlap_ge_size
    # overlap == size and overlap > size both produce a non-advancing
    # stride and must be refused to avoid an infinite loop.
    assert_raises(ArgumentError) { FSO.new(size: 10, overlap: 10) }
    assert_raises(ArgumentError) { FSO.new(size: 10, overlap: 11) }
  end

  def test_rejects_bad_by
    assert_raises(ArgumentError) { FSO.new(size: 10, overlap: 2, by: :words) }
  end

  def test_rejects_bad_max_chunks
    assert_raises(ArgumentError) { FSO.new(size: 10, overlap: 2, max_chunks_per_document: 0) }
    assert_raises(ArgumentError) { FSO.new(size: 10, overlap: 2, max_chunks_per_document: -3) }
  end

  # ----- blank input -----

  def test_blank_input_returns_empty
    c = FSO.new(size: 10, overlap: 2)
    assert_equal [], c.chunk(nil)
    assert_equal [], c.chunk("")
    assert_equal [], c.chunk("    \n\t  ")
  end

  def test_non_string_input_returns_empty
    c = FSO.new(size: 10, overlap: 2)
    assert_equal [], c.chunk(12345)
    assert_equal [], c.chunk([1, 2, 3])
  end

  # ----- char windowing -----

  def test_chars_no_overlap_exact_boundary
    c = FSO.new(size: 4, overlap: 0)
    assert_equal %w[abcd efgh ijkl], c.chunk("abcdefghijkl")
  end

  def test_chars_no_overlap_with_remainder
    c = FSO.new(size: 4, overlap: 0)
    assert_equal %w[abcd efgh ij], c.chunk("abcdefghij")
  end

  def test_chars_with_overlap
    # size 4, overlap 2 -> stride 2: windows at 0,2,4,...
    c = FSO.new(size: 4, overlap: 2)
    assert_equal %w[abcd cdef efgh ghij ij], c.chunk("abcdefghij")
  end

  def test_chars_shorter_than_size_single_chunk
    c = FSO.new(size: 100, overlap: 10)
    assert_equal ["hello"], c.chunk("hello")
  end

  # ----- token windowing -----

  def test_tokens_no_overlap
    c = FSO.new(size: 2, overlap: 0, by: :tokens)
    assert_equal ["the quick", "brown fox", "jumps"], c.chunk("the quick brown fox jumps")
  end

  def test_tokens_with_overlap
    # size 3, overlap 1 -> stride 2
    c = FSO.new(size: 3, overlap: 1, by: :tokens)
    assert_equal ["a b c", "c d e", "e f"], c.chunk("a b c d e f")
  end

  def test_tokens_collapse_whitespace
    c = FSO.new(size: 2, overlap: 0, by: :tokens)
    assert_equal ["one two", "three"], c.chunk("  one   two\n\tthree  ")
  end

  # ----- amplification cap (truncate-with-signal) -----

  def test_truncates_at_cap_without_raising
    c = FSO.new(size: 1, overlap: 0, max_chunks_per_document: 3)
    # 10 single-char chunks, capped to 3.
    assert_equal %w[a b c], c.chunk("abcdefghij")
  end

  def test_chunk_with_meta_reports_truncation
    c = FSO.new(size: 1, overlap: 0, max_chunks_per_document: 3)
    meta = c.chunk_with_meta("abcdefghij")
    assert_equal %w[a b c], meta[:chunks]
    assert_equal true, meta[:truncated]
    assert_equal 10, meta[:total_before_truncation]
  end

  def test_chunk_with_meta_no_truncation
    c = FSO.new(size: 4, overlap: 0)
    meta = c.chunk_with_meta("abcdefgh")
    assert_equal %w[abcd efgh], meta[:chunks]
    assert_equal false, meta[:truncated]
    assert_equal 2, meta[:total_before_truncation]
  end

  def test_chunk_with_meta_blank
    c = FSO.new(size: 4, overlap: 0)
    meta = c.chunk_with_meta("")
    assert_equal [], meta[:chunks]
    assert_equal false, meta[:truncated]
    assert_equal 0, meta[:total_before_truncation]
  end

  # ----- Base contract -----

  def test_base_chunk_is_abstract
    assert_raises(NotImplementedError) { Parse::Retrieval::Chunker::Base.new.chunk("x") }
  end

  def test_base_chunk_with_meta_delegates_for_subclass
    subclass = Class.new(Parse::Retrieval::Chunker::Base) do
      def chunk(text)
        n = normalize(text)
        n.nil? ? [] : n.split(",")
      end
    end
    meta = subclass.new.chunk_with_meta("a,b,c")
    assert_equal %w[a b c], meta[:chunks]
    assert_equal false, meta[:truncated]
    assert_equal 3, meta[:total_before_truncation]
  end

  def test_readers
    c = FSO.new(size: 800, overlap: 100, by: :chars, max_chunks_per_document: 50)
    assert_equal 800, c.size
    assert_equal 100, c.overlap
    assert_equal :chars, c.by
    assert_equal 50, c.max_chunks_per_document
  end
end
