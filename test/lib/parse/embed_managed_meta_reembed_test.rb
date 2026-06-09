# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "parse/model/file"

# Unit tests for the v5.5 embedding-migration surface:
#   - auto-declared `<into>_meta` provenance sibling (stamped/cleared)
#   - Class.reembed! (force re-embed; only_stale: skip-current rows)
#   - embed_image source: :bytes dispatch through ImageFetch
class EmbedManagedMetaReembedTest < Minitest::Test
  def self.register
    Parse::Embeddings.register(:fx_meta, Parse::Embeddings::Fixture.new(dimensions: 4))
  end
  register

  class MetaItem < Parse::Object
    parse_class "MetaItem"
    property :title, :string
    property :embedding, :vector, dimensions: 4, provider: :fx_meta
    embed :title, into: :embedding
  end

  # ---------- <into>_meta provenance ----------

  def test_meta_property_is_auto_declared
    assert MetaItem.fields.key?(:embedding_meta)
    assert_equal :embedding_meta, MetaItem.embed_directives[:embedding].meta_field
  end

  def test_meta_is_stamped_on_recompute
    r = MetaItem.new(title: "hello world")
    r.compute_embedding!
    meta = r.embedding_meta
    refute_nil meta
    assert_equal "fx_meta", meta["provider"]
    assert_equal Parse::Embeddings.provider(:fx_meta).model_name, meta["model"]
    assert_equal 4, meta["dimensions"]
    assert_equal "text", meta["modality"]
    refute_nil meta["embedded_at"]
    assert Time.parse(meta["embedded_at"]) <= Time.now.utc + 1
  end

  def test_meta_is_cleared_when_source_clears
    r = MetaItem.new(title: "hello world")
    r.compute_embedding!
    refute_nil r.embedding_meta
    r.title = nil
    r.compute_embedding!
    assert_nil r.embedding
    assert_nil r.embedding_meta
  end

  # ---------- reembed! (stubbed query chain) ----------

  class FakeRecord
    attr_reader :id, :saves
    attr_accessor :embedding_digest, :embedding_meta
    def initialize(id, digest: "old", meta: nil)
      @id = id
      @saves = 0
      @embedding_digest = digest
      @embedding_meta = meta
    end
    def save(**_opts) = (@saves += 1)
  end

  class FakeQuery
    def initialize(batches) = (@batches = batches; @i = -1)
    def where(*) = self
    def order(*) = self
    def limit(*) = self
    def results
      @i += 1
      @batches[@i] || []
    end
  end

  def current_meta
    {
      "provider" => "fx_meta",
      "model" => Parse::Embeddings.provider(:fx_meta).model_name,
      "dimensions" => 4,
    }
  end

  def test_reembed_clears_digest_and_saves_every_row
    rows = [FakeRecord.new("a"), FakeRecord.new("b")]
    fq = FakeQuery.new([rows])
    MetaItem.stub(:query, ->(*_a) { fq }) do
      assert_equal 2, MetaItem.reembed!(batch_size: 5)
    end
    rows.each do |r|
      assert_equal 1, r.saves
      assert_nil r.embedding_digest, "digest must be cleared so the save-path recompute runs"
    end
  end

  def test_reembed_only_stale_skips_current_rows
    fresh = FakeRecord.new("a", meta: current_meta)
    stale_meta = current_meta.merge("model" => "old-model-1")
    stale = FakeRecord.new("b", meta: stale_meta)
    never = FakeRecord.new("c", meta: nil)
    fq = FakeQuery.new([[fresh, stale, never]])
    MetaItem.stub(:query, ->(*_a) { fq }) do
      assert_equal 2, MetaItem.reembed!(batch_size: 5, only_stale: true)
    end
    assert_equal 0, fresh.saves
    assert_equal 1, stale.saves
    assert_equal 1, never.saves, "rows with no meta count as stale"
  end

  def test_reembed_respects_limit
    rows = [FakeRecord.new("a"), FakeRecord.new("b"), FakeRecord.new("c")]
    fq = FakeQuery.new([rows])
    MetaItem.stub(:query, ->(*_a) { fq }) do
      assert_equal 1, MetaItem.reembed!(batch_size: 5, limit: 1)
    end
    assert_equal [1, 0, 0], rows.map(&:saves)
  end

  def test_reembed_unknown_field_raises
    err = assert_raises(ArgumentError) { MetaItem.reembed!(field: :nope) }
    # The shared backfill resolver must name the entry point the caller
    # actually used, not its embed_pending! sibling.
    assert_includes err.message, "reembed!"
    refute_includes err.message, "embed_pending!"
  end

  def test_reembed_validates_batch_size
    assert_raises(ArgumentError) { MetaItem.reembed!(batch_size: 0) }
  end

  # ---------- embed_image source: :bytes ----------

  class StubBytesProvider < Parse::Embeddings::Provider
    attr_reader :calls
    def initialize = @calls = []
    def dimensions; 4; end
    def model_name; "stub-bytes-1"; end
    def modalities; %i[text image]; end
    def embed_image(sources, input_type: :search_document, allow_insecure: false)
      @calls << { sources: sources, input_type: input_type }
      sources.map { [0.1, 0.2, 0.3, 0.4] }
    end
  end

  def self.register_bytes
    Parse::Embeddings.register(:stub_bytes, StubBytesProvider.new)
  end
  register_bytes

  class BytesItem < Parse::Object
    parse_class "BytesItem"
    property :photo, :file
    property :photo_embedding, :vector, dimensions: 4, provider: :stub_bytes
    embed_image :photo, into: :photo_embedding, source: :bytes
  end

  def test_bytes_mode_recorded_on_directive
    d = BytesItem.embed_directives[:photo_embedding]
    assert d.bytes_mode?
    assert_equal true, d.exif_strip
    assert_equal :photo_embedding_meta, d.meta_field
  end

  class BadBytesItem < Parse::Object
    parse_class "BadBytesItem"
    property :photo, :file
    property :v, :vector, dimensions: 4, provider: :stub_bytes
  end

  def test_invalid_source_mode_raises_at_declaration
    err = assert_raises(Parse::Core::EmbedManaged::InvalidEmbedDeclaration) do
      BadBytesItem.embed_image :photo, into: :v, source: :stream
    end
    assert_includes err.message, ":url or :bytes"
  end

  def test_bytes_mode_fetches_and_forwards_fetched_image
    fetched = Parse::Embeddings::ImageFetch::FetchedImage.new(
      bytes: "\xFF\xD8\xFF".b, mime_type: "image/jpeg",
      url: "https://1.1.1.1/p.jpg",
    )
    fetch_args = []
    stub_fetch = lambda do |url, allow_insecure:, exif_strip:|
      fetch_args << { url: url, allow_insecure: allow_insecure, exif_strip: exif_strip }
      fetched
    end
    provider = Parse::Embeddings.provider(:stub_bytes)
    provider.calls.clear

    r = BytesItem.new
    file = Parse::File.new("name" => "p.jpg", "url" => "https://1.1.1.1/p.jpg")
    r.photo = file

    Parse::Embeddings::ImageFetch.stub(:fetch!, stub_fetch) do
      r.compute_embedding!
    end

    assert_equal 1, fetch_args.length
    assert_equal "https://1.1.1.1/p.jpg", fetch_args.first[:url]
    assert_equal true, fetch_args.first[:exif_strip]
    assert_equal false, fetch_args.first[:allow_insecure]

    assert_equal 1, provider.calls.length
    assert_equal [fetched], provider.calls.first[:sources]
    assert_equal 4, r.photo_embedding.dimensions
    meta = r.photo_embedding_meta
    assert_equal "image", meta["modality"]
    assert_equal "stub-bytes-1", meta["model"]
  end

  class UrlModeItem < Parse::Object
    parse_class "UrlModeItem"
    property :photo, :file
    property :v, :vector, dimensions: 4, provider: :stub_bytes
    embed_image :photo, into: :v # default source: :url
  end

  def test_url_mode_still_forwards_raw_url
    refute UrlModeItem.embed_directives[:v].bytes_mode?

    provider = Parse::Embeddings.provider(:stub_bytes)
    provider.calls.clear
    r = UrlModeItem.new
    r.photo = Parse::File.new("name" => "p.jpg", "url" => "https://1.1.1.1/p.jpg")
    r.compute_embedding!
    assert_equal ["https://1.1.1.1/p.jpg"], provider.calls.first[:sources]
  end
end
