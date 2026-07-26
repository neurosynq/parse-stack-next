# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "base64"
require "tmpdir"

# Unit tests for Parse::Embeddings::StreamingBody — the IO-shaped
# request body that splices base64-encoded files into a JSON envelope
# without ever holding a file in memory. Correctness here is
# load-bearing: a byte off in the base64 stream produces a body the
# provider rejects, and a wrong #size desyncs Content-Length from the
# emitted payload.
class EmbeddingsStreamingBodyTest < Minitest::Test
  CHUNK = Parse::Embeddings::StreamingBody::READ_CHUNK

  def setup
    @dir = Dir.mktmpdir("psnext-stream")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  # ---- base64 correctness ----------------------------------------------

  # Chunked encoding is only equivalent to whole-file encoding when the
  # chunk size is a multiple of 3. Guard the invariant directly so a
  # future tweak to READ_CHUNK cannot silently corrupt every payload.
  def test_read_chunk_is_a_multiple_of_three
    assert_equal 0, CHUNK % 3,
                 "READ_CHUNK must be a multiple of 3 or chunked base64 desyncs"
  end

  def test_streams_byte_identically_across_chunk_boundaries
    [1, 2, 3, CHUNK - 1, CHUNK, CHUNK + 1, (CHUNK * 2) + 7].each do |n|
      path = write_blob("blob_#{n}.bin", n)
      body = Parse::Embeddings::StreamingBody.new(["<", segment(path), ">"])
      expected = "<#{Base64.strict_encode64(::File.binread(path))}>"
      assert_equal expected, drain(body), "payload mismatch at n=#{n}"
    end
  end

  def test_size_is_exact_for_every_boundary
    [1, 2, 3, CHUNK - 1, CHUNK, CHUNK + 1].each do |n|
      path = write_blob("size_#{n}.bin", n)
      body = Parse::Embeddings::StreamingBody.new(["ab", segment(path), "c"])
      assert_equal drain(body).bytesize, body.size, "size() wrong at n=#{n}"
    end
  end

  def test_interleaves_multiple_files_in_order
    a = write_blob("a.bin", 1000)
    b = write_blob("b.bin", CHUNK + 5)
    body = Parse::Embeddings::StreamingBody.new(["[", segment(a), "|", segment(b), "]"])
    expected = "[#{Base64.strict_encode64(::File.binread(a))}" \
               "|#{Base64.strict_encode64(::File.binread(b))}]"
    assert_equal expected, drain(body)
  end

  def test_literal_only_body_round_trips
    body = Parse::Embeddings::StreamingBody.new(["{\"a\":1}"])
    assert_equal "{\"a\":1}", drain(body)
    assert_equal 7, body.size
  end

  # ---- IO contract ------------------------------------------------------

  # Net::HTTP rewinds body_stream when it retries, so a replayed body
  # must be byte-identical or the retry sends a truncated payload.
  def test_rewind_replays_identically
    path = write_blob("replay.bin", CHUNK + 128)
    body = Parse::Embeddings::StreamingBody.new(["x", segment(path)])
    first = drain(body)
    body.rewind
    assert_equal first, drain(body)
  end

  def test_read_returns_nil_at_eof
    body = Parse::Embeddings::StreamingBody.new(["hi"])
    assert_equal "hi", body.read(64)
    assert_nil body.read(64)
  end

  def test_read_honors_requested_length
    path = write_blob("len.bin", 3000)
    body = Parse::Embeddings::StreamingBody.new([segment(path)])
    chunk = body.read(16)
    assert_equal 16, chunk.bytesize
  end

  def test_read_fills_caller_supplied_buffer
    body = Parse::Embeddings::StreamingBody.new(["abcdef"])
    buf = +"stale"
    assert_equal "abc", body.read(3, buf)
    assert_equal "abc", buf
  end

  # Peak retained memory must track the requested read size, not the
  # file size — that is the entire reason this class exists.
  def test_peak_chunk_is_bounded_by_requested_length
    path = write_blob("big.bin", CHUNK * 8)
    body = Parse::Embeddings::StreamingBody.new([segment(path)])
    peak = 0
    while (c = body.read(4096))
      peak = [peak, c.bytesize].max
    end
    assert_operator peak, :<=, 4096
  end

  # ---- failure modes ----------------------------------------------------

  def test_detects_file_changing_size_underneath_the_request
    path = write_blob("mutating.bin", 900)
    body = Parse::Embeddings::StreamingBody.new([segment(path)])
    ::File.binwrite(path, "\x00" * 50)
    assert_raises(Parse::Embeddings::StreamingBody::SizeMismatch) { drain(body) }
  end

  def test_rejects_malformed_segments
    assert_raises(ArgumentError) { Parse::Embeddings::StreamingBody.new([42]) }
    assert_raises(ArgumentError) do
      Parse::Embeddings::StreamingBody.new([{ path: "/x" }])
    end
  end

  private

  def write_blob(name, bytes)
    path = ::File.join(@dir, name)
    srand(bytes)
    ::File.binwrite(path, Array.new(bytes) { rand(256) }.pack("C*"))
    path
  end

  def segment(path)
    { path: path, size: ::File.size(path) }
  end

  def drain(body, chunk: 1024)
    out = +""
    while (c = body.read(chunk))
      out << c
    end
    out
  end
end
