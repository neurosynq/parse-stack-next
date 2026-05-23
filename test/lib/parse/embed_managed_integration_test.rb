# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../support/test_server"
require_relative "../../support/docker_helper"

# End-to-end integration tests for the `embed` class macro against a
# real Parse Server. Covers:
#
# * First save populates the managed `:vector` property and digest
#   sibling on the server; refetch round-trips the vector back into a
#   Parse::Vector with the correct dimensions and values.
# * Repeated save with no source-field change is a no-op (provider not
#   called, digest unchanged on the server).
# * Save after a source-field change recomputes the vector and digest.
# * A save that only touches non-source fields does NOT change the
#   stored vector or digest (selective recompute).
# * Direct assignment to the managed vector field still raises
#   ProtectedFieldError even with a configured Parse Server.
class EmbedManagedDoc < Parse::Object
  parse_class "EmbedManagedDocE2E"
  property :title, :string
  property :body,  :string
  property :unrelated, :string
  # Fixture provider is registered under :fixture in tests; we declare
  # the property to use that name so first save can resolve it.
  property :body_embedding, :vector, dimensions: 8, provider: :fixture_embed_e2e
  embed :title, :body, into: :body_embedding
end

class EmbedManagedIntegrationTest < Minitest::Test
  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    unless Parse::Test::DockerHelper.running?
      skip "Docker containers not running" unless Parse::Test::DockerHelper.start!
    end
    skip "Parse Server unavailable" unless Parse::Test::ServerHelper.setup
    Parse::Test::ServerHelper.reset_database!

    Parse::Embeddings.reset!
    Parse::Embeddings.register(
      :fixture_embed_e2e,
      Parse::Embeddings::Fixture.new(dimensions: 8),
    )
  end

  def teardown
    Parse::Embeddings.reset!
  end

  def test_first_save_populates_vector_and_digest_round_trip
    doc = EmbedManagedDoc.new(title: "hello", body: "world")
    assert_nil doc.body_embedding
    assert_nil doc.body_embedding_digest

    assert doc.save, "save failed: #{doc.errors.full_messages.inspect}"

    refute_nil doc.body_embedding, "embedding should have been populated by before_save"
    assert_kind_of Parse::Vector, doc.body_embedding
    assert_equal 8, doc.body_embedding.dimensions
    refute_nil doc.body_embedding_digest
    assert_equal 32, doc.body_embedding_digest.length

    fetched = EmbedManagedDoc.find(doc.id)
    refute_nil fetched
    assert_kind_of Parse::Vector, fetched.body_embedding,
                   "round-trip should coerce JSON array back to Parse::Vector"
    assert_equal 8, fetched.body_embedding.dimensions
    assert_equal doc.body_embedding.to_a, fetched.body_embedding.to_a
    assert_equal doc.body_embedding_digest, fetched.body_embedding_digest
  end

  def test_second_save_with_no_source_change_is_a_noop
    doc = EmbedManagedDoc.new(title: "alpha", body: "beta")
    assert doc.save
    first_vector = doc.body_embedding.to_a.dup
    first_digest = doc.body_embedding_digest

    # Touch a non-source field and re-save.
    doc.unrelated = "metadata"
    assert doc.save

    assert_equal first_digest, doc.body_embedding_digest
    assert_equal first_vector, doc.body_embedding.to_a

    fetched = EmbedManagedDoc.find(doc.id)
    assert_equal first_digest, fetched.body_embedding_digest
    assert_equal first_vector, fetched.body_embedding.to_a
  end

  def test_save_after_source_field_change_recomputes
    doc = EmbedManagedDoc.new(title: "first", body: "version")
    assert doc.save
    initial_digest = doc.body_embedding_digest
    initial_vector = doc.body_embedding.to_a.dup

    doc.body = "version two"
    assert doc.save

    refute_equal initial_digest, doc.body_embedding_digest
    refute_equal initial_vector, doc.body_embedding.to_a

    fetched = EmbedManagedDoc.find(doc.id)
    assert_equal doc.body_embedding_digest, fetched.body_embedding_digest
    assert_equal doc.body_embedding.to_a, fetched.body_embedding.to_a
  end

  def test_direct_assignment_to_managed_vector_raises_even_in_e2e
    doc = EmbedManagedDoc.new(title: "x", body: "y")
    assert_raises(Parse::Core::EmbedManaged::ProtectedFieldError) do
      doc.body_embedding = Parse::Vector.new(Array.new(8, 0.5))
    end
  end

  def test_clearing_all_source_fields_clears_vector_and_digest
    doc = EmbedManagedDoc.new(title: "hi", body: "there")
    assert doc.save
    refute_nil doc.body_embedding_digest

    doc.title = nil
    doc.body = nil
    assert doc.save

    assert_nil doc.body_embedding
    assert_nil doc.body_embedding_digest

    fetched = EmbedManagedDoc.find(doc.id)
    assert_nil fetched.body_embedding
    assert_nil fetched.body_embedding_digest
  end
end
