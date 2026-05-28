# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"
require "parse/model/file"

# Unit tests for the `embed_image` class macro on Parse::Core::EmbedManaged.
# Covers declaration-time validation (source must be `:file`), the
# URL-digest tracked recompute path, dispatch through
# Parse::Embeddings.validate_image_url! (sentinel-gated), and
# Provider#embed_image dispatch. The provider is stubbed via a
# Fixture-style subclass so no network traffic is generated.
class EmbedManagedImageTest < Minitest::Test
  SENTINEL = "PROVIDER_EGRESS_VERIFIED"

  # A test-only image provider that records the URLs it was called
  # with and returns deterministic 4-dim vectors. Inheriting from
  # Provider directly (not Fixture) so we can override embed_image
  # cleanly.
  class StubImageProvider < Parse::Embeddings::Provider
    attr_reader :calls

    def initialize
      @calls = []
    end

    def dimensions; 4; end
    def model_name; "stub-image-1"; end
    def modalities; %i[text image]; end

    def embed_image(sources, input_type: :search_document, allow_insecure: false)
      # Mirror real providers (Voyage) — validate every URL via
      # Parse::Embeddings.validate_image_url! before "forwarding". The
      # DSL path (build_source_input) no longer pre-validates, so the
      # provider is the single source of truth for URL safety.
      canonical = sources.map do |s|
        Parse::Embeddings.validate_image_url!(s, allow_insecure: allow_insecure)
      end
      @calls << { sources: canonical, input_type: input_type, allow_insecure: allow_insecure }
      vectors = canonical.each_with_index.map { |_, i| Array.new(4, (i + 1) / 10.0) }
      validate_response!(canonical.length, vectors)
    end
  end

  class ImageDoc < Parse::Object
    parse_class "EmbedImageDocA"
    property :cover_art, :file
    property :cover_embedding, :vector, dimensions: 4, provider: :stub_image
    embed_image :cover_art, into: :cover_embedding
  end

  def setup
    Parse::Embeddings.reset!
    @stub = StubImageProvider.new
    Parse::Embeddings.register(:stub_image, @stub)
    Parse::Embeddings.trust_provider_url_fetch = SENTINEL
    Parse::Embeddings.allowed_image_hosts = ["1.1.1.1", ".cloudfront.net"]
    @prior_ports = Parse::File.allowed_remote_ports.dup
    @prior_hosts = Parse::File.allowed_remote_hosts.dup
  end

  def teardown
    Parse::Embeddings.reset!
    Parse::File.allowed_remote_ports = @prior_ports
    Parse::File.allowed_remote_hosts = @prior_hosts
  end

  # ---- declaration-time validation -------------------------------------

  def named_subclass(parse_name, &block)
    klass = Class.new(Parse::Object)
    klass.instance_variable_set(:@parse_class, parse_name)
    klass.class_eval(&block)
    klass
  end

  def test_embed_image_rejects_target_that_is_not_a_vector_property
    err = assert_raises(Parse::Core::EmbedManaged::InvalidEmbedDeclaration) do
      named_subclass("EIfail1") do
        property :cover_art, :file
        embed_image :cover_art, into: :cover_art
      end
    end
    assert_match(/not a declared :vector property/, err.message)
  end

  def test_embed_image_rejects_vector_property_without_provider
    err = assert_raises(Parse::Core::EmbedManaged::InvalidEmbedDeclaration) do
      named_subclass("EIfail2") do
        property :cover_art, :file
        property :v, :vector, dimensions: 4
        embed_image :cover_art, into: :v
      end
    end
    assert_match(/no `provider:` declared/, err.message)
  end

  def test_embed_image_rejects_undeclared_source_field
    err = assert_raises(Parse::Core::EmbedManaged::InvalidEmbedDeclaration) do
      named_subclass("EIfail3") do
        property :v, :vector, dimensions: 4, provider: :stub_image
        embed_image :missing_field, into: :v
      end
    end
    assert_match(/not declared on this class/, err.message)
  end

  def test_embed_image_rejects_non_file_source
    err = assert_raises(Parse::Core::EmbedManaged::InvalidEmbedDeclaration) do
      named_subclass("EIfail4") do
        property :name, :string
        property :v, :vector, dimensions: 4, provider: :stub_image
        embed_image :name, into: :v
      end
    end
    assert_match(/must be a :file property/, err.message)
    assert_match(/text sources go through `embed`/, err.message)
  end

  def test_embed_image_auto_declares_digest_sibling
    assert ImageDoc.fields.key?(:cover_embedding_digest)
    assert_equal :string, ImageDoc.fields[:cover_embedding_digest]
  end

  def test_embed_image_registers_directive_with_image_modality
    d = ImageDoc.embed_directives[:cover_embedding]
    assert_equal [:cover_art], d.sources
    assert_equal :cover_embedding, d.into
    assert_equal :stub_image, d.provider_name
    assert_equal :image, d.modality
    assert d.image?
  end

  def test_embed_image_registers_before_save_callback
    cbs = ImageDoc._save_callbacks.select { |cb| cb.kind == :before }
    methods = cbs.map { |cb| (cb.filter.to_sym rescue cb.filter) }
    assert_includes methods, :_auto_embed_cover_embedding!
  end

  # ---- writer guard ----------------------------------------------------

  def test_direct_assignment_to_managed_image_vector_raises
    doc = ImageDoc.new
    err = assert_raises(Parse::Core::EmbedManaged::ProtectedFieldError) do
      doc.cover_embedding = Parse::Vector.new(Array.new(4, 0.1))
    end
    assert_match(/managed by `embed`/, err.message)
  end

  # ---- recompute_embedding! — image path -------------------------------

  def directive_for(klass, field)
    klass.embed_directives[field]
  end

  def file_with_url(url)
    f = Parse::File.allocate
    f.instance_variable_set(:@url, url)
    f.instance_variable_set(:@name, File.basename(URI.parse(url).path))
    f
  end

  def test_recompute_populates_vector_and_digest_from_file_url
    doc = ImageDoc.new
    doc.cover_art = file_with_url("https://1.1.1.1/cover.jpg")

    Parse::Core::EmbedManaged.recompute_embedding!(doc, directive_for(ImageDoc, :cover_embedding))

    assert_equal 4, doc.cover_embedding.dimensions
    refute_nil doc.cover_embedding_digest
    assert_equal 32, doc.cover_embedding_digest.length
    # Provider was called with the validated URL exactly once.
    assert_equal 1, @stub.calls.length
    assert_equal ["https://1.1.1.1/cover.jpg"], @stub.calls.first[:sources]
  end

  def test_recompute_is_idempotent_when_url_unchanged
    doc = ImageDoc.new
    doc.cover_art = file_with_url("https://1.1.1.1/cover.jpg")
    d = directive_for(ImageDoc, :cover_embedding)

    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    first_vec = doc.cover_embedding
    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)

    assert_same first_vec, doc.cover_embedding
    assert_equal 1, @stub.calls.length, "Provider must not be re-called when URL unchanged"
  end

  def test_recompute_re_embeds_when_file_url_changes
    doc = ImageDoc.new
    doc.cover_art = file_with_url("https://1.1.1.1/cover.jpg")
    d = directive_for(ImageDoc, :cover_embedding)
    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)

    doc.cover_art = file_with_url("https://1.1.1.1/cover_v2.jpg")
    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)

    assert_equal 2, @stub.calls.length
    assert_equal ["https://1.1.1.1/cover_v2.jpg"], @stub.calls.last[:sources]
  end

  def test_recompute_clears_vector_and_digest_when_file_is_nil
    doc = ImageDoc.new
    doc.cover_art = file_with_url("https://1.1.1.1/cover.jpg")
    d = directive_for(ImageDoc, :cover_embedding)
    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    refute_nil doc.cover_embedding

    doc.cover_art = nil
    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    assert_nil doc.cover_embedding
    assert_nil doc.cover_embedding_digest
  end

  def test_recompute_clears_when_file_has_no_url
    # Construct a file and then null its URL to simulate the
    # never-uploaded edge case. Direct ivar mutation because the
    # Parse::File constructor rejects empty names by design.
    doc = ImageDoc.new
    doc.cover_art = file_with_url("https://1.1.1.1/cover.jpg")
    doc.cover_art.instance_variable_set(:@url, "")
    d = directive_for(ImageDoc, :cover_embedding)
    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    assert_nil doc.cover_embedding
    assert_equal 0, @stub.calls.length
  end

  # ---- security wiring ------------------------------------------------

  def test_recompute_raises_when_sentinel_off
    Parse::Embeddings.trust_provider_url_fetch = nil
    doc = ImageDoc.new
    doc.cover_art = file_with_url("https://1.1.1.1/cover.jpg")
    d = directive_for(ImageDoc, :cover_embedding)

    err = assert_raises(Parse::Embeddings::ConfirmationRequired) do
      Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    end
    assert_match(/disabled/, err.message)
    assert_equal 0, @stub.calls.length
  end

  def test_recompute_raises_when_url_not_in_allowlist
    Parse::Embeddings.allowed_image_hosts = ["other.cdn.com"]
    doc = ImageDoc.new
    doc.cover_art = file_with_url("https://1.1.1.1/cover.jpg")
    d = directive_for(ImageDoc, :cover_embedding)

    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    end
    assert_equal :host_not_allowlisted, err.reason
    assert_equal 0, @stub.calls.length
  end

  def test_recompute_raises_on_private_ip_url
    # Pin the CIDR check specifically: put the loopback into the
    # allowlist so the request gets past the host-allowlist gate
    # and into Parse::File.assert_host_allowed!. The CIDR check
    # must still refuse the URL — operators cannot disable SSRF
    # protection by allowlisting a private IP.
    Parse::Embeddings.allowed_image_hosts = ["127.0.0.1"]
    doc = ImageDoc.new
    doc.cover_art = file_with_url("https://127.0.0.1/cover.jpg")
    d = directive_for(ImageDoc, :cover_embedding)

    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    end
    assert_equal :host_blocked, err.reason
  end

  # ---- allow_insecure forwarded through directive ---------------------

  def test_allow_insecure_directive_permits_http_url
    klass = named_subclass("EmbedImageHTTPDoc") do
      property :pic, :file
      property :pic_embedding, :vector, dimensions: 4, provider: :stub_image
      embed_image :pic, into: :pic_embedding, allow_insecure: true
    end
    doc = klass.new
    doc.pic = file_with_url("http://1.1.1.1/cover.jpg")
    Parse::Core::EmbedManaged.recompute_embedding!(doc, klass.embed_directives[:pic_embedding])
    assert_equal 4, doc.pic_embedding.dimensions
    assert_equal ["http://1.1.1.1/cover.jpg"], @stub.calls.first[:sources]
    assert_equal true, @stub.calls.first[:allow_insecure]
  end

  def test_allow_insecure_default_refuses_http_url
    doc = ImageDoc.new
    doc.cover_art = file_with_url("http://1.1.1.1/cover.jpg")
    d = directive_for(ImageDoc, :cover_embedding)
    err = assert_raises(Parse::Embeddings::InvalidImageURL) do
      Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    end
    assert_equal :scheme, err.reason
  end

  # ---- text `embed` + image `embed_image` on the same record ----------

  # A model declaring BOTH a text embedding (via `embed`) and an image
  # embedding (via `embed_image`) on different vector targets. The two
  # callbacks, two writer guards, and two digest siblings must be
  # independent — touching one source should re-embed only its own
  # target.
  class MixedDoc < Parse::Object
    parse_class "EmbedImageDocMixed"
    # Tiny 4-dim fixture for the text side.
    property :title, :string
    property :body,  :string
    property :title_embedding, :vector, dimensions: 4, provider: :fixture4
    embed :title, :body, into: :title_embedding

    # Image side uses the stub_image provider.
    property :cover_art, :file
    property :cover_embedding, :vector, dimensions: 4, provider: :stub_image
    embed_image :cover_art, into: :cover_embedding
  end

  def test_mixed_class_registers_both_directives_independently
    # Need the fixture4 provider too — register it alongside stub_image.
    Parse::Embeddings.register(:fixture4, Parse::Embeddings::Fixture.new(dimensions: 4))

    text_dir  = MixedDoc.embed_directives[:title_embedding]
    image_dir = MixedDoc.embed_directives[:cover_embedding]

    refute_nil text_dir
    refute_nil image_dir
    assert_nil text_dir.modality, "text directive must report nil modality"
    assert_equal :image, image_dir.modality

    cbs = MixedDoc._save_callbacks.select { |cb| cb.kind == :before }
    methods = cbs.map { |cb| (cb.filter.to_sym rescue cb.filter) }
    assert_includes methods, :_auto_embed_title_embedding!
    assert_includes methods, :_auto_embed_cover_embedding!
  end

  def test_mixed_class_text_change_does_not_trigger_image_provider
    Parse::Embeddings.register(:fixture4, Parse::Embeddings::Fixture.new(dimensions: 4))
    doc = MixedDoc.new(title: "hello", body: "world")
    doc.cover_art = file_with_url("https://1.1.1.1/cover.jpg")

    text_dir  = MixedDoc.embed_directives[:title_embedding]
    image_dir = MixedDoc.embed_directives[:cover_embedding]
    Parse::Core::EmbedManaged.recompute_embedding!(doc, text_dir)
    Parse::Core::EmbedManaged.recompute_embedding!(doc, image_dir)
    image_calls_after_first = @stub.calls.length
    assert_equal 1, image_calls_after_first

    # Mutate ONLY the text source; the image directive must be a no-op
    # because the file URL is unchanged.
    doc.title = "hello world updated"
    Parse::Core::EmbedManaged.recompute_embedding!(doc, text_dir)
    Parse::Core::EmbedManaged.recompute_embedding!(doc, image_dir)

    assert_equal image_calls_after_first, @stub.calls.length,
      "Image provider must not be re-called when only the text source changed"
  end

  # When the source `:file` property is declared `required: true` and
  # the field is nil at recompute time, the embed_image path should
  # treat nil as "clear vector and return" (mirroring the text path's
  # all-blank-sources behavior). The required-validator fires later
  # in the save chain (during the validation phase) and surfaces its
  # own ArgumentError — but recompute_embedding! itself must not
  # raise on the nil source, so the user sees the correct error.
  class RequiredImageDoc < Parse::Object
    parse_class "EmbedImageDocReq"
    property :cover_art, :file, required: true
    property :cover_embedding, :vector, dimensions: 4, provider: :stub_image
    embed_image :cover_art, into: :cover_embedding
  end

  def test_recompute_with_required_file_nil_clears_and_does_not_raise
    doc = RequiredImageDoc.new
    d = RequiredImageDoc.embed_directives[:cover_embedding]
    # cover_art is nil. recompute_embedding! sees no URL → clears
    # vector / digest, returns. No provider call, no exception. The
    # `required: true` validation runs in a separate phase (save's
    # valid? check) and is the right place for that error to surface.
    Parse::Core::EmbedManaged.recompute_embedding!(doc, d)
    assert_nil doc.cover_embedding
    assert_nil doc.cover_embedding_digest
    assert_equal 0, @stub.calls.length
  end

  def test_mixed_class_writer_guards_are_independent
    Parse::Embeddings.register(:fixture4, Parse::Embeddings::Fixture.new(dimensions: 4))
    doc = MixedDoc.new
    # Direct assignment must fail on BOTH managed fields, independently.
    assert_raises(Parse::Core::EmbedManaged::ProtectedFieldError) do
      doc.title_embedding = Parse::Vector.new(Array.new(4, 0.1))
    end
    assert_raises(Parse::Core::EmbedManaged::ProtectedFieldError) do
      doc.cover_embedding = Parse::Vector.new(Array.new(4, 0.1))
    end
  end
end
