# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../support/test_server"
require_relative "../../support/docker_helper"
require "securerandom"

# End-to-end integration tests for the `embed_image` class macro
# against a real Parse Server. Covers the v5.1.0 image-embedding surface
# end-to-end:
#
# * First save uploads a Parse::File, fires before_save, validates the
#   localhost file URL, calls the stub image provider, and persists the
#   vector + URL-digest on the server. Refetch round-trips.
# * Re-save with the same file is a no-op (digest match → zero provider
#   calls).
# * Re-save after assigning a different Parse::File re-embeds.
# * Sentinel-off → save raises ConfirmationRequired from before_save;
#   no half-written record (no server write).
# * Allowlist-rejection → save raises InvalidImageURL from before_save;
#   no half-written record.
# * Direct assignment to the managed vector field still raises
#   ProtectedFieldError end-to-end.
#
# The image provider is a stub (no external HTTP). Live-Voyage testing
# is gated by a separate VOYAGE_API_KEY env var and is not part of CI.

# Test-only image provider — mirrors the unit-test StubImageProvider
# but lives at the top level so the model declaration below can
# reference it.
class FixtureImageProviderE2E < Parse::Embeddings::Provider
  attr_reader :calls

  def initialize
    @calls = []
  end

  def dimensions; 8; end
  def model_name; "stub-image-e2e-1"; end
  def modalities; %i[text image]; end

  def embed_image(sources, input_type: :search_document, allow_insecure: false)
    canonical = sources.map do |s|
      Parse::Embeddings.validate_image_url!(s, allow_insecure: allow_insecure)
    end
    @calls << { sources: canonical, input_type: input_type, allow_insecure: allow_insecure }
    # Deterministic per-URL vector: digest the URL, expand to 8 floats.
    vectors = canonical.map do |u|
      digest = Digest::SHA256.digest(u)
      (0...8).map { |i| (digest.bytes[i].to_f / 255.0) }
    end
    validate_response!(canonical.length, vectors)
  end
end

class EmbedImageDocE2E < Parse::Object
  parse_class "EmbedImageDocE2E"
  property :cover_art, :file
  property :unrelated, :string
  property :cover_embedding, :vector, dimensions: 8, provider: :fixture_image_e2e
  # Default `allow_insecure: false` — production posture. The test
  # rewrites file URLs to https://1.1.1.1/... so the scheme gate
  # passes naturally.
  embed_image :cover_art, into: :cover_embedding
end

class EmbedManagedImageIntegrationTest < Minitest::Test
  SENTINEL = "PROVIDER_EGRESS_VERIFIED"

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    unless Parse::Test::DockerHelper.running?
      skip "Docker containers not running" unless Parse::Test::DockerHelper.start!
    end
    skip "Parse Server unavailable" unless Parse::Test::ServerHelper.setup
    Parse::Test::ServerHelper.reset_database!

    Parse::Embeddings.reset!
    @provider = FixtureImageProviderE2E.new
    Parse::Embeddings.register(:fixture_image_e2e, @provider)
    # Allowlist 1.1.1.1 — the public IP we'll rewrite the uploaded
    # Parse::File's URL to point at, since the validator (correctly)
    # refuses localhost / ::1 URLs. The validator's job is to refuse
    # forwarding URLs that point at internal infrastructure to
    # third-party providers, so any "URL → provider" integration
    # test against a local file server has to substitute a public-
    # looking URL for the validation hop.
    Parse::Embeddings.allowed_image_hosts = ["1.1.1.1"]
    Parse::Embeddings.trust_provider_url_fetch = SENTINEL
  end

  def teardown
    Parse::Embeddings.reset!
  end

  # --------------------------------------------------------------------
  # Test fixtures
  # --------------------------------------------------------------------

  # Upload a tiny PNG to the Docker Parse Server, then rewrite its
  # `.url` to a public-IP literal so the validator allows the
  # provider call to proceed. The upload itself is the real
  # integration — it verifies the Parse::File round-trip against the
  # server (multipart POST, URL assignment, mime detection). The URL
  # rewrite is the only honest way to exercise the validate →
  # embed_image → vector-persist path when the only available file
  # store is localhost. See the validator's `:host_blocked` reason
  # for why localhost URLs are refused on principle.
  def upload_and_rewrite_image(suffix: SecureRandom.hex(4), public_path: "/cover.jpg")
    # Minimal valid PNG: 67-byte 1x1 RGBA. Constructed from the canonical
    # PNG signature + IHDR + IDAT + IEND chunks with CRC.
    png_bytes = [
      0x89504e47, 0x0d0a1a0a,
      0x0000000d, 0x49484452, 0x00000001, 0x00000001,
      0x08060000, 0x001f1503,
      0x000d4944, 0x41540878, 0x9c620000,
      0x000005ff, 0xff1f0000, 0x00000049, 0x454e44,
      0xae426082,
    ].pack("N*")[0, 67]
    file = Parse::File.new("cover_#{suffix}.png", png_bytes, "image/png")
    assert file.save, "Parse::File upload failed: #{file.inspect}"
    refute_nil file.url
    # Rewrite the URL to a public-looking IP literal (validator-safe).
    # The suffix-derived path keeps URLs distinct across test fixtures.
    file.instance_variable_set(:@url, "https://1.1.1.1/#{suffix}#{public_path}")
    file
  end

  # --------------------------------------------------------------------
  # End-to-end embed_image save round-trip
  # --------------------------------------------------------------------

  def test_first_save_uploads_file_embeds_and_round_trips_vector
    file = upload_and_rewrite_image
    doc = EmbedImageDocE2E.new
    doc.cover_art = file
    assert_nil doc.cover_embedding
    assert_nil doc.cover_embedding_digest

    assert doc.save, "save failed: #{doc.errors.full_messages.inspect}"

    # Provider called exactly once with the validated URL.
    assert_equal 1, @provider.calls.length
    assert_equal [file.url], @provider.calls.first[:sources]
    assert_equal false, @provider.calls.first[:allow_insecure]

    refute_nil doc.cover_embedding
    assert_kind_of Parse::Vector, doc.cover_embedding
    assert_equal 8, doc.cover_embedding.dimensions
    refute_nil doc.cover_embedding_digest
    assert_equal 32, doc.cover_embedding_digest.length

    # Round-trip through the server.
    fetched = EmbedImageDocE2E.find(doc.id)
    refute_nil fetched
    assert_kind_of Parse::Vector, fetched.cover_embedding
    assert_equal 8, fetched.cover_embedding.dimensions
    assert_equal doc.cover_embedding.to_a, fetched.cover_embedding.to_a
    assert_equal doc.cover_embedding_digest, fetched.cover_embedding_digest
  end

  def test_second_save_with_unchanged_file_url_is_a_noop
    file = upload_and_rewrite_image
    doc = EmbedImageDocE2E.new
    doc.cover_art = file
    assert doc.save
    first_digest = doc.cover_embedding_digest
    first_calls  = @provider.calls.length
    assert_equal 1, first_calls

    # Mutate an unrelated field; file URL unchanged.
    doc.unrelated = "changed"
    assert doc.save

    assert_equal first_calls, @provider.calls.length,
      "Provider must not be called when the file URL is unchanged"
    assert_equal first_digest, doc.cover_embedding_digest

    fetched = EmbedImageDocE2E.find(doc.id)
    assert_equal first_digest, fetched.cover_embedding_digest
  end

  def test_re_assigning_file_with_different_url_re_embeds
    file_a = upload_and_rewrite_image(suffix: "a")
    doc = EmbedImageDocE2E.new
    doc.cover_art = file_a
    assert doc.save
    first_calls  = @provider.calls.length
    first_digest = doc.cover_embedding_digest
    first_vec   = doc.cover_embedding.to_a.dup

    file_b = upload_and_rewrite_image(suffix: "b")
    refute_equal file_a.url, file_b.url, "fixtures must produce distinct URLs"
    doc.cover_art = file_b
    assert doc.save

    assert_equal first_calls + 1, @provider.calls.length,
      "Provider must be re-called when the file URL changes"
    refute_equal first_digest, doc.cover_embedding_digest
    refute_equal first_vec, doc.cover_embedding.to_a
  end

  # --------------------------------------------------------------------
  # Security wiring against a live server: before_save abort cleanly
  # --------------------------------------------------------------------

  def test_save_aborts_cleanly_when_sentinel_unset
    file = upload_and_rewrite_image
    doc = EmbedImageDocE2E.new
    doc.cover_art = file

    # Clear the sentinel AFTER the file has uploaded (the file upload
    # itself goes through Parse::Client, not the embed validator).
    Parse::Embeddings.trust_provider_url_fetch = nil

    err = assert_raises(Parse::Embeddings::ConfirmationRequired) { doc.save }
    assert_match(/disabled/, err.message)

    # No half-written record on the server.
    assert_nil doc.id, "save must not have created a server-side record"
    assert_equal 0, @provider.calls.length
  end

  def test_save_aborts_cleanly_when_url_not_in_allowlist
    file = upload_and_rewrite_image
    doc = EmbedImageDocE2E.new
    doc.cover_art = file

    # Constrict the allowlist to something the URL won't match.
    Parse::Embeddings.allowed_image_hosts = ["evil.example.com"]

    err = assert_raises(Parse::Embeddings::InvalidImageURL) { doc.save }
    assert_equal :host_not_allowlisted, err.reason

    assert_nil doc.id, "save must not have created a server-side record"
    assert_equal 0, @provider.calls.length
  end

  # --------------------------------------------------------------------
  # Writer-guard end-to-end
  # --------------------------------------------------------------------

  def test_direct_vector_assignment_raises_even_with_live_server
    doc = EmbedImageDocE2E.new
    assert_raises(Parse::Core::EmbedManaged::ProtectedFieldError) do
      doc.cover_embedding = Parse::Vector.new(Array.new(8, 0.1))
    end
  end

  # --------------------------------------------------------------------
  # Nil cover_art clears the vector and digest on the server
  # --------------------------------------------------------------------

  def test_clearing_cover_art_clears_vector_and_digest_on_server
    file = upload_and_rewrite_image
    doc = EmbedImageDocE2E.new
    doc.cover_art = file
    assert doc.save
    refute_nil doc.cover_embedding

    doc.cover_art = nil
    assert doc.save

    fetched = EmbedImageDocE2E.find(doc.id)
    assert_nil fetched.cover_embedding,
      "fetched record's cover_embedding must be nil after cover_art cleared"
    assert_nil fetched.cover_embedding_digest
  end
end
