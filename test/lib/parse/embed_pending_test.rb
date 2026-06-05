# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the v5.0 bulk/backfill surface:
#   - Parse::Object#compute_embedding!  (force in-place recompute)
#   - Class.embed_pending!              (objectId-cursor backfill)
# The provider is the deterministic Fixture; the query chain is stubbed
# so the backfill runs without a server.
class EmbedPendingTest < Minitest::Test
  def self.register
    Parse::Embeddings.register(:fx_ep, Parse::Embeddings::Fixture.new(dimensions: 4))
  end
  register

  class EPItem < Parse::Object
    parse_class "EPItem"
    property :title, :string
    property :embedding, :vector, dimensions: 4, provider: :fx_ep
    embed :title, into: :embedding
  end

  # ----- compute_embedding! -----

  def test_compute_embedding_populates_vector_and_digest
    r = EPItem.new(title: "hello world")
    assert_nil r.embedding
    assert_same r, r.compute_embedding!
    assert_equal 4, r.embedding.dimensions
    refute_nil r.embedding_digest
  end

  def test_compute_embedding_unknown_field_raises
    assert_raises(ArgumentError) { EPItem.new(title: "x").compute_embedding!(field: :nope) }
  end

  # ----- embed_pending! (stubbed query chain) -----

  # A fake record: records save calls; carries an id.
  class FakeRecord
    attr_reader :id, :saves
    def initialize(id) = (@id = id; @saves = 0)
    def save(**_opts) = (@saves += 1)
  end

  # A fake query that returns successive canned batches and records the
  # `:objectId.gt` cursor it was asked to filter on.
  class FakeQuery
    attr_reader :cursors
    def initialize(batches) = (@batches = batches; @i = -1; @cursors = [])
    def where(constraints = {})
      # The only .where call in the backfill carries the objectId cursor,
      # so capture every where value (the key is a Parse operation object).
      constraints.each_value { |v| @cursors << v }
      self
    end
    def order(*) = self
    def limit(*) = self
    def results
      @i += 1
      @batches[@i] || []
    end
  end

  def test_embed_pending_saves_each_pending_record_until_drained
    b1 = [FakeRecord.new("a"), FakeRecord.new("b")]
    b2 = [FakeRecord.new("c")] # short batch (< batch_size) ends the loop
    fq = FakeQuery.new([b1, b2])
    EPItem.stub(:query, ->(*_a) { fq }) do
      n = EPItem.embed_pending!(batch_size: 2)
      assert_equal 3, n
    end
    (b1 + b2).each { |r| assert_equal 1, r.saves }
    # cursor advanced to the last id of the first full batch.
    assert_includes fq.cursors, "b"
  end

  def test_embed_pending_respects_limit
    b1 = [FakeRecord.new("a"), FakeRecord.new("b"), FakeRecord.new("c")]
    fq = FakeQuery.new([b1, b1, b1])
    EPItem.stub(:query, ->(*_a) { fq }) do
      n = EPItem.embed_pending!(batch_size: 3, limit: 2)
      assert_equal 2, n
    end
    assert_equal 1, b1[0].saves
    assert_equal 1, b1[1].saves
    assert_equal 0, b1[2].saves, "limit should stop before the 3rd record"
  end

  def test_embed_pending_empty_first_batch_is_zero
    fq = FakeQuery.new([[]])
    EPItem.stub(:query, ->(*_a) { fq }) do
      assert_equal 0, EPItem.embed_pending!(batch_size: 50)
    end
  end
end
