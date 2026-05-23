# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"

# Unit tests for the `embed` class macro and Parse::Core::EmbedManaged.
#
# Covers declaration-time validation, the digest-tracked recompute path,
# the ProtectedFieldError guard, multi-source concatenation, and
# provider error shape. No Parse Server in the loop -- recompute_embedding!
# is exercised directly so we don't need to drive a full save flow.
class EmbedManagedTest < Minitest::Test
  # 4-dim Fixture so vectors are small and dimension mismatches are
  # cheap to assert.
  def self.register_fixture!(dims: 4)
    Parse::Embeddings.reset!
    Parse::Embeddings.register(:fixture4, Parse::Embeddings::Fixture.new(dimensions: dims))
  end

  class EmbedDoc < Parse::Object
    parse_class "EmbedDocA"
    property :title, :string
    property :body,  :string
    property :body_embedding, :vector, dimensions: 4, provider: :fixture4
    embed :title, :body, into: :body_embedding
  end

  class EmbedDocCustomDigest < Parse::Object
    parse_class "EmbedDocB"
    property :title, :string
    property :title_embedding, :vector, dimensions: 4, provider: :fixture4
    embed :title, into: :title_embedding, digest_field: :title_hash
  end

  def setup
    self.class.register_fixture!
  end

  def teardown
    Parse::Embeddings.reset!
  end

  # ---- declaration-time validation --------------------------------------

  # Build an anonymous Parse::Object subclass with @parse_class pre-set
  # so the embed declaration is what we actually exercise (and not a
  # `model_name.name` crash on the anonymous class first).
  def named_subclass(parse_name, &block)
    klass = Class.new(Parse::Object)
    klass.instance_variable_set(:@parse_class, parse_name)
    klass.class_eval(&block)
    klass
  end

  def test_embed_requires_at_least_one_source
    assert_raises(Parse::Core::EmbedManaged::InvalidEmbedDeclaration) do
      named_subclass("EDfail1") do
        property :v, :vector, dimensions: 4, provider: :fixture4
        embed into: :v
      end
    end
  end

  def test_embed_rejects_target_that_is_not_a_vector_property
    err = assert_raises(Parse::Core::EmbedManaged::InvalidEmbedDeclaration) do
      named_subclass("EDfail2") do
        property :title, :string
        embed :title, into: :title
      end
    end
    assert_match(/not a declared :vector property/, err.message)
  end

  def test_embed_rejects_vector_property_without_provider
    err = assert_raises(Parse::Core::EmbedManaged::InvalidEmbedDeclaration) do
      named_subclass("EDfail3") do
        property :title, :string
        property :v, :vector, dimensions: 4
        embed :title, into: :v
      end
    end
    assert_match(/no `provider:` declared/, err.message)
  end

  def test_embed_rejects_undeclared_source_fields
    err = assert_raises(Parse::Core::EmbedManaged::InvalidEmbedDeclaration) do
      named_subclass("EDfail4") do
        property :v, :vector, dimensions: 4, provider: :fixture4
        embed :nope, into: :v
      end
    end
    assert_match(/not declared on this class/, err.message)
  end

  def test_embed_auto_declares_default_digest_sibling
    assert EmbedDoc.fields.key?(:body_embedding_digest)
    assert_equal :string, EmbedDoc.fields[:body_embedding_digest]
  end

  def test_embed_honors_custom_digest_field_name
    assert EmbedDocCustomDigest.fields.key?(:title_hash)
    refute EmbedDocCustomDigest.fields.key?(:title_embedding_digest)
  end

  def test_embed_registers_directive_in_class_registry
    d = EmbedDoc.embed_directives[:body_embedding]
    assert_equal [:title, :body], d.sources
    assert_equal :body_embedding, d.into
    assert_equal :body_embedding_digest, d.digest_field
    assert_equal :search_document, d.input_type
    assert_equal :fixture4, d.provider_name
  end

  def test_embed_registers_before_save_callback
    cbs = EmbedDoc._save_callbacks.select { |cb| cb.kind == :before }
    methods = cbs.map { |cb| (cb.filter.to_sym rescue cb.filter) }
    assert_includes methods, :_auto_embed_body_embedding!
  end

  # ---- ProtectedFieldError ----------------------------------------------

  def test_direct_assignment_to_managed_vector_raises
    doc = EmbedDoc.new(title: "hi")
    err = assert_raises(Parse::Core::EmbedManaged::ProtectedFieldError) do
      doc.body_embedding = Parse::Vector.new(Array.new(4, 0.1))
    end
    assert_match(/managed by `embed`/, err.message)
  end

  def test_managed_writer_bypasses_guard
    doc = EmbedDoc.new(title: "hi")
    Parse::Core::EmbedManaged.with_writer(:body_embedding) do
      doc.body_embedding = Parse::Vector.new(Array.new(4, 0.5))
    end
    assert_equal 4, doc.body_embedding.dimensions
  end

  def test_writer_key_is_restored_after_with_writer
    Parse::Core::EmbedManaged.with_writer(:body_embedding) { :noop }
    assert_nil Thread.current[Parse::Core::EmbedManaged::WRITER_KEY]
  end

  # ---- recompute_embedding! semantics -----------------------------------

  def directive_for(klass, field)
    klass.embed_directives[field]
  end

  def test_recompute_populates_vector_and_digest_on_first_call
    doc = EmbedDoc.new(title: "hello", body: "world")
    assert_nil doc.body_embedding
    assert_nil doc.body_embedding_digest

    Parse::Core::EmbedManaged.recompute_embedding!(doc, directive_for(EmbedDoc, :body_embedding))

    assert_equal 4, doc.body_embedding.dimensions
    refute_nil doc.body_embedding_digest
    assert_equal 32, doc.body_embedding_digest.length
  end

  def test_recompute_is_idempotent_when_digest_matches
    doc = EmbedDoc.new(title: "hello", body: "world")
    d = directive_for(EmbedDoc, :body_embedding)
    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    first_vector = doc.body_embedding
    first_digest = doc.body_embedding_digest

    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    assert_same first_vector, doc.body_embedding
    assert_equal first_digest, doc.body_embedding_digest
  end

  def test_recompute_runs_when_source_field_changes
    doc = EmbedDoc.new(title: "hello", body: "world")
    d = directive_for(EmbedDoc, :body_embedding)
    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    first = doc.body_embedding

    doc.body = "world changed"
    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    refute_same first, doc.body_embedding
    assert_equal 4, doc.body_embedding.dimensions
  end

  def test_recompute_clears_vector_and_digest_when_all_sources_blank
    doc = EmbedDoc.new(title: "hello", body: "world")
    d = directive_for(EmbedDoc, :body_embedding)
    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    refute_nil doc.body_embedding

    doc.title = nil
    doc.body = nil
    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    assert_nil doc.body_embedding
    assert_nil doc.body_embedding_digest
  end

  def test_recompute_concatenates_multiple_source_fields
    doc_one = EmbedDoc.new(title: "alpha", body: "beta")
    doc_two = EmbedDoc.new(title: "alphabeta", body: nil)
    d = directive_for(EmbedDoc, :body_embedding)

    Parse::Core::EmbedManaged.recompute_embedding!(doc_one, d)
    Parse::Core::EmbedManaged.recompute_embedding!(doc_two, d)
    # Different concatenation -> different digest -> different vector.
    refute_equal doc_one.body_embedding_digest, doc_two.body_embedding_digest
  end

  def test_recompute_raises_when_provider_returns_wrong_dimensions
    Parse::Embeddings.reset!
    # Fixture configured to return 8-dim vectors against a 4-dim property.
    Parse::Embeddings.register(:fixture4, Parse::Embeddings::Fixture.new(dimensions: 8))

    doc = EmbedDoc.new(title: "hi", body: "there")
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      Parse::Core::EmbedManaged.recompute_embedding!(doc, directive_for(EmbedDoc, :body_embedding))
    end
    assert_match(/property declares dimensions: 4/, err.message)
  end

  def test_recompute_raises_when_provider_not_registered
    Parse::Embeddings.reset!  # purge :fixture4
    doc = EmbedDoc.new(title: "hi", body: "there")
    assert_raises(Parse::Embeddings::ProviderNotRegistered) do
      Parse::Core::EmbedManaged.recompute_embedding!(doc, directive_for(EmbedDoc, :body_embedding))
    end
  end
end
