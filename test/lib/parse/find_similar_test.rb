# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/atlas_search"

# Unit tests for `Class.find_similar(vector:, k:, ...)` — the class-method
# wrapper introduced as the first ergonomic surface above
# `Parse::VectorSearch.search`. Covers field resolution, declared-
# dimension validation, index auto-discovery, and result wrapping.
# Network paths are stubbed via Minitest::Mock so the suite runs with
# neither Atlas nor Parse Server in the loop.
class FindSimilarTest < Minitest::Test
  class SingleVecDoc < Parse::Object
    parse_class "SingleVecDoc"
    property :title, :string
    property :embedding, :vector, dimensions: 3
  end

  class MultiVecDoc < Parse::Object
    parse_class "MultiVecDoc"
    property :embedding, :vector, dimensions: 3
    property :other_vec, :vector, dimensions: 4
  end

  class NoVecDoc < Parse::Object
    parse_class "NoVecDoc"
    property :title, :string
  end

  def setup
    # Default: stub IndexCatalog so the index-resolution branch returns
    # a predictable name. Tests that exercise the failure paths or the
    # explicit-index path override this stub locally.
    @catalog_stub = lambda do |coll, field:|
      { "name" => "#{coll}_#{field}_idx" }
    end
  end

  def stub_index_catalog(value_or_proc)
    Parse::AtlasSearch::IndexCatalog.stub(:find_vector_index, value_or_proc) do
      yield
    end
  end

  def stub_vector_search(captured_args = {})
    fake = lambda do |coll, **kwargs|
      captured_args[:collection] = coll
      captured_args.merge!(kwargs)
      [
        { "_id" => "abc", "title" => "first",  "_vscore" => 0.91 },
        { "_id" => "xyz", "title" => "second", "_vscore" => 0.42 },
      ]
    end
    Parse::VectorSearch.stub(:search, fake) { yield }
  end

  # ---- field resolution --------------------------------------------------

  def test_no_vector_property_raises
    err = assert_raises(Parse::Core::VectorSearchable::NoVectorProperty) do
      NoVecDoc.find_similar(vector: [0.1, 0.2, 0.3])
    end
    assert_match(/no :vector property/, err.message)
  end

  def test_multiple_vector_properties_require_field
    err = assert_raises(Parse::Core::VectorSearchable::AmbiguousVectorField) do
      MultiVecDoc.find_similar(vector: [0.1, 0.2, 0.3])
    end
    assert_match(/multiple :vector properties/, err.message)
  end

  def test_explicit_field_disambiguates_multi
    captured = {}
    stub_index_catalog(@catalog_stub) do
      stub_vector_search(captured) do
        MultiVecDoc.find_similar(vector: [0.1, 0.2, 0.3, 0.4],
                                 field: :other_vec, raw: true)
      end
    end
    assert_equal :other_vec, captured[:field]
  end

  def test_unknown_field_raises
    assert_raises(Parse::Core::VectorSearchable::NoVectorProperty) do
      SingleVecDoc.find_similar(vector: [0.1, 0.2, 0.3], field: :nope)
    end
  end

  # ---- dimension validation against declared property -------------------

  def test_query_vector_dimension_mismatch_raises
    err = assert_raises(Parse::VectorSearch::InvalidQueryVector) do
      stub_index_catalog(@catalog_stub) do
        SingleVecDoc.find_similar(vector: [0.1, 0.2])
      end
    end
    assert_match(/length 2/, err.message)
    assert_match(/declared dimensions 3/, err.message)
  end

  def test_query_vector_matching_dimensions_passes
    captured = {}
    stub_index_catalog(@catalog_stub) do
      stub_vector_search(captured) do
        SingleVecDoc.find_similar(vector: [0.1, 0.2, 0.3], raw: true)
      end
    end
    assert_equal [0.1, 0.2, 0.3], captured[:query_vector]
  end

  def test_parse_vector_accepted_as_query
    captured = {}
    vec = Parse::Vector.new([0.5, 0.6, 0.7])
    stub_index_catalog(@catalog_stub) do
      stub_vector_search(captured) do
        SingleVecDoc.find_similar(vector: vec, raw: true)
      end
    end
    assert_equal [0.5, 0.6, 0.7], captured[:query_vector]
  end

  def test_non_array_non_vector_raises
    assert_raises(Parse::VectorSearch::InvalidQueryVector) do
      stub_index_catalog(@catalog_stub) do
        SingleVecDoc.find_similar(vector: "not a vector")
      end
    end
  end

  # ---- index resolution -------------------------------------------------

  def test_index_auto_discovery
    captured = {}
    catalog = lambda do |coll, field:|
      assert_equal "SingleVecDoc", coll
      assert_equal :embedding, field
      { "name" => "discovered_idx" }
    end
    stub_index_catalog(catalog) do
      stub_vector_search(captured) do
        SingleVecDoc.find_similar(vector: [0.1, 0.2, 0.3], raw: true)
      end
    end
    assert_equal "discovered_idx", captured[:index]
  end

  def test_no_discoverable_index_raises
    catalog = lambda { |_coll, field:| nil }
    stub_index_catalog(catalog) do
      err = assert_raises(Parse::Core::VectorSearchable::IndexNotResolved) do
        SingleVecDoc.find_similar(vector: [0.1, 0.2, 0.3])
      end
      assert_match(/no vectorSearch index found/, err.message)
      assert_match(/SingleVecDoc\.embedding/, err.message)
    end
  end

  def test_explicit_index_skips_discovery
    captured = {}
    # Catalog should not be called at all; stub it to fail loudly if it is.
    catalog = lambda do |_coll, field:|
      flunk "IndexCatalog.find_vector_index must not be called when index: is explicit"
    end
    stub_index_catalog(catalog) do
      stub_vector_search(captured) do
        SingleVecDoc.find_similar(vector: [0.1, 0.2, 0.3],
                                  index: "explicit_idx", raw: true)
      end
    end
    assert_equal "explicit_idx", captured[:index]
  end

  # ---- pass-through arguments ------------------------------------------

  def test_forwards_filter_k_scope_kwargs
    captured = {}
    stub_index_catalog(@catalog_stub) do
      stub_vector_search(captured) do
        SingleVecDoc.find_similar(
          vector: [0.1, 0.2, 0.3],
          k: 7,
          filter: { tag: "ruby" },
          vector_filter: { wiki_id: 42 },
          num_candidates: 200,
          max_time_ms: 1500,
          session_token: "r:tok",
          raw: true,
        )
      end
    end
    assert_equal 7, captured[:k]
    assert_equal({ tag: "ruby" }, captured[:filter])
    assert_equal({ wiki_id: 42 }, captured[:vector_filter])
    assert_equal 200, captured[:num_candidates]
    assert_equal 1500, captured[:max_time_ms]
    assert_equal "r:tok", captured[:session_token]
    assert_equal "SingleVecDoc", captured[:collection]
  end

  # ---- result wrapping --------------------------------------------------

  def test_raw_mode_returns_unwrapped_hashes
    stub_index_catalog(@catalog_stub) do
      stub_vector_search({}) do
        results = SingleVecDoc.find_similar(vector: [0.1, 0.2, 0.3], raw: true)
        assert_kind_of Array, results
        assert results.all? { |r| r.is_a?(Hash) }
        assert_equal 0.91, results.first["_vscore"]
      end
    end
  end

  def test_object_mode_returns_typed_instances_with_score
    stub_index_catalog(@catalog_stub) do
      stub_vector_search({}) do
        results = SingleVecDoc.find_similar(vector: [0.1, 0.2, 0.3])
        assert_equal 2, results.length
        assert results.all? { |obj| obj.is_a?(SingleVecDoc) }
        assert_equal "first", results[0].title
        assert_equal 0.91, results[0].vector_score
        assert_equal 0.42, results[1].vector_score
      end
    end
  end

  def test_empty_results_returns_empty_array
    fake_search = lambda { |_coll, **_kwargs| [] }
    Parse::VectorSearch.stub(:search, fake_search) do
      stub_index_catalog(@catalog_stub) do
        assert_equal [], SingleVecDoc.find_similar(vector: [0.1, 0.2, 0.3])
      end
    end
  end

  # ---- text: overload --------------------------------------------------

  # Property variants that declare a `provider:` so the text: overload
  # can resolve it. Each declares a fixed `dimensions:` matching the
  # Fixture instance the test registers under the corresponding key.
  class TextVecDoc < Parse::Object
    parse_class "TextVecDoc"
    property :embedding, :vector, dimensions: 4,
                                  provider: :fix_textvec, model: "fix-4"
  end

  class NoProviderVecDoc < Parse::Object
    parse_class "NoProviderVecDoc"
    property :embedding, :vector, dimensions: 3
  end

  # Provider that records every call so tests can assert input_type and
  # batch shape — using the real Fixture would also work, but recording
  # the call surface here keeps the assertions explicit.
  class RecordingFixture < Parse::Embeddings::Fixture
    attr_reader :calls

    def initialize(**opts)
      super
      @calls = []
    end

    def embed_text(strings, input_type: :search_document)
      @calls << { strings: strings.dup, input_type: input_type }
      super
    end
  end

  # Mutates the process-global Parse::Embeddings registry for the
  # duration of the block, then restores prior state in `ensure`. Safe
  # only under sequential test execution — the suite does not call
  # `parallelize_me!`, so concurrent races on the same provider key
  # cannot happen. If Minitest parallel mode is ever enabled, switch
  # to per-test unique provider keys (and update the property
  # declarations to match) rather than mutating shared state.
  def with_registered_provider(name, provider)
    prev = Parse::Embeddings.configuration.providers[name]
    Parse::Embeddings.register(name, provider)
    yield
  ensure
    if prev
      Parse::Embeddings.configuration.providers[name] = prev
    else
      Parse::Embeddings.configuration.providers.delete(name)
    end
  end

  def test_text_overload_embeds_via_declared_provider
    provider = RecordingFixture.new(dimensions: 4, model_name: "fix-4")
    captured = {}
    with_registered_provider(:fix_textvec, provider) do
      stub_index_catalog(@catalog_stub) do
        stub_vector_search(captured) do
          TextVecDoc.find_similar(text: "ruby parse", raw: true)
        end
      end
    end
    assert_equal 1, provider.calls.length
    assert_equal ["ruby parse"], provider.calls.first[:strings]
    assert_equal :search_query, provider.calls.first[:input_type]
    assert_kind_of Array, captured[:query_vector]
    assert_equal 4, captured[:query_vector].length
  end

  def test_text_overload_requires_provider_metadata_on_property
    err = assert_raises(Parse::Core::VectorSearchable::EmbedderNotConfigured) do
      NoProviderVecDoc.find_similar(text: "anything")
    end
    assert_match(/no `provider:` declared/, err.message)
  end

  def test_text_overload_raises_when_provider_not_registered
    # Property declares `provider: :fix_textvec` but we don't register it.
    assert_nil Parse::Embeddings.configuration.providers[:fix_textvec]
    assert_raises(Parse::Embeddings::ProviderNotRegistered) do
      TextVecDoc.find_similar(text: "anything")
    end
  end

  def test_neither_vector_nor_text_raises
    err = assert_raises(ArgumentError) do
      SingleVecDoc.find_similar
    end
    assert_match(/must pass either `vector:` or `text:`/, err.message)
  end

  def test_both_vector_and_text_raises
    err = assert_raises(ArgumentError) do
      SingleVecDoc.find_similar(vector: [0.1, 0.2, 0.3], text: "ruby")
    end
    assert_match(/not both/, err.message)
  end

  def test_text_overload_rejects_non_string_text
    provider = Parse::Embeddings::Fixture.new(dimensions: 4, model_name: "fix-4")
    with_registered_provider(:fix_textvec, provider) do
      stub_index_catalog(@catalog_stub) do
        assert_raises(ArgumentError) do
          TextVecDoc.find_similar(text: 123)
        end
      end
    end
  end

  def test_text_overload_rejects_empty_text
    provider = Parse::Embeddings::Fixture.new(dimensions: 4, model_name: "fix-4")
    with_registered_provider(:fix_textvec, provider) do
      stub_index_catalog(@catalog_stub) do
        err = assert_raises(ArgumentError) do
          TextVecDoc.find_similar(text: "")
        end
        assert_match(/empty/, err.message)
      end
    end
  end

  def test_text_overload_validates_returned_vector_dimensions
    # Register a provider whose dimension disagrees with the declared
    # property (4 vs 8). The dimension-mismatch check downstream should
    # catch it before search runs.
    provider = Parse::Embeddings::Fixture.new(dimensions: 8, model_name: "fix-mismatch")
    with_registered_provider(:fix_textvec, provider) do
      stub_index_catalog(@catalog_stub) do
        err = assert_raises(Parse::VectorSearch::InvalidQueryVector) do
          TextVecDoc.find_similar(text: "ruby parse")
        end
        assert_match(/length 8/, err.message)
        assert_match(/declared dimensions 4/, err.message)
      end
    end
  end

  def test_text_overload_rejects_oversized_text
    provider = Parse::Embeddings::Fixture.new(dimensions: 4, model_name: "fix-4")
    cap = Parse::Core::VectorSearchable::MAX_QUERY_TEXT_BYTES
    with_registered_provider(:fix_textvec, provider) do
      stub_index_catalog(@catalog_stub) do
        err = assert_raises(ArgumentError) do
          TextVecDoc.find_similar(text: "a" * (cap + 1))
        end
        assert_match(/exceeds #{cap} bytes/, err.message)
      end
    end
  end

  def test_text_overload_object_mode_returns_typed_instances_with_score
    # Covers the build_vector_hits wrapping path through the text branch
    # — the other text: tests all use raw: true.
    provider = Parse::Embeddings::Fixture.new(dimensions: 4, model_name: "fix-4")
    with_registered_provider(:fix_textvec, provider) do
      stub_index_catalog(@catalog_stub) do
        stub_vector_search({}) do
          results = TextVecDoc.find_similar(text: "ruby parse")
          assert_equal 2, results.length
          assert results.all? { |obj| obj.is_a?(TextVecDoc) }
          assert_equal 0.91, results[0].vector_score
          assert_equal 0.42, results[1].vector_score
        end
      end
    end
  end

  def test_text_overload_forwards_scope_and_filter_kwargs
    provider = Parse::Embeddings::Fixture.new(dimensions: 4, model_name: "fix-4")
    captured = {}
    with_registered_provider(:fix_textvec, provider) do
      stub_index_catalog(@catalog_stub) do
        stub_vector_search(captured) do
          TextVecDoc.find_similar(
            text: "ruby parse",
            k: 5,
            filter: { tag: "ruby" },
            session_token: "r:tok",
            raw: true,
          )
        end
      end
    end
    assert_equal 5, captured[:k]
    assert_equal({ tag: "ruby" }, captured[:filter])
    assert_equal "r:tok", captured[:session_token]
  end
end
