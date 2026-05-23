# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/embeddings"

# Unit tests for the Parse::Embeddings provider registry, the abstract
# Provider base, and the deterministic Fixture provider. No network,
# no Parse Server in the loop.
class EmbeddingsTest < Minitest::Test
  def setup
    Parse::Embeddings.reset!
  end

  def teardown
    Parse::Embeddings.reset!
  end

  # ---- registry --------------------------------------------------------

  def test_fixture_is_zero_config
    provider = Parse::Embeddings.provider(:fixture)
    assert_kind_of Parse::Embeddings::Fixture, provider
  end

  def test_fixture_default_instance_is_memoized
    a = Parse::Embeddings.provider(:fixture)
    b = Parse::Embeddings.provider(:fixture)
    assert_same a, b
  end

  def test_unknown_provider_raises
    err = assert_raises(Parse::Embeddings::ProviderNotRegistered) do
      Parse::Embeddings.provider(:openai)
    end
    assert_match(/no provider registered/, err.message)
  end

  def test_register_short_form
    custom = Parse::Embeddings::Fixture.new(dimensions: 8, model_name: "stub")
    Parse::Embeddings.register(:stub, custom)
    assert_same custom, Parse::Embeddings.provider(:stub)
  end

  def test_register_requires_provider_instance
    err = assert_raises(ArgumentError) do
      Parse::Embeddings.register(:bogus, "not a provider")
    end
    assert_match(/Parse::Embeddings::Provider instance/, err.message)
  end

  def test_configure_block_form
    Parse::Embeddings.configure do |c|
      c.providers[:test] = Parse::Embeddings::Fixture.new(dimensions: 16)
    end
    assert_kind_of Parse::Embeddings::Fixture, Parse::Embeddings.provider(:test)
    assert_equal 16, Parse::Embeddings.provider(:test).dimensions
  end

  def test_register_accepts_string_name
    Parse::Embeddings.register("strkey", Parse::Embeddings::Fixture.new(dimensions: 4))
    assert_kind_of Parse::Embeddings::Fixture, Parse::Embeddings.provider("strkey")
    assert_kind_of Parse::Embeddings::Fixture, Parse::Embeddings.provider(:strkey)
  end

  def test_reset_clears_registry
    Parse::Embeddings.register(:foo, Parse::Embeddings::Fixture.new(dimensions: 4))
    assert_includes Parse::Embeddings.registered_provider_names, :foo
    Parse::Embeddings.reset!
    refute_includes Parse::Embeddings.registered_provider_names, :foo
  end

  def test_register_overwrites_previous
    a = Parse::Embeddings::Fixture.new(dimensions: 4, model_name: "first")
    b = Parse::Embeddings::Fixture.new(dimensions: 4, model_name: "second")
    Parse::Embeddings.register(:dupe, a)
    Parse::Embeddings.register(:dupe, b)
    assert_same b, Parse::Embeddings.provider(:dupe)
  end

  def test_configuration_providers_hash_rejects_non_provider_assignment
    err = assert_raises(ArgumentError) do
      Parse::Embeddings.configuration.providers[:bogus] = "not a provider"
    end
    assert_match(/Parse::Embeddings::Provider/, err.message)
  end

  def test_configuration_providers_hash_accepts_string_key
    provider = Parse::Embeddings::Fixture.new(dimensions: 4)
    Parse::Embeddings.configuration.providers["foo"] = provider
    assert_same provider, Parse::Embeddings.provider(:foo)
  end

  # ---- Provider abstract base -----------------------------------------

  def test_abstract_methods_raise_not_implemented
    abstract = Parse::Embeddings::Provider.new
    assert_raises(NotImplementedError) { abstract.embed_text(["x"]) }
    assert_raises(NotImplementedError) { abstract.dimensions }
    assert_raises(NotImplementedError) { abstract.model_name }
    assert_raises(NotImplementedError) { abstract.embed_image([URI("http://x")]) }
  end

  def test_default_modalities_is_text
    assert_equal [:text], Parse::Embeddings::Provider.new.modalities
  end

  def test_error_class_hierarchy
    assert Parse::Embeddings::InvalidResponseError < Parse::Embeddings::Error
    assert Parse::Embeddings::Error < StandardError
  end

  def test_provider_inspect_does_not_dump_instance_vars
    klass = Class.new(Parse::Embeddings::Provider) do
      def initialize
        @api_key = "secret-key-DO-NOT-LEAK"
      end

      def dimensions; 8; end
      def model_name; "test-model"; end
    end
    provider = klass.new
    refute_includes provider.inspect, "secret-key-DO-NOT-LEAK"
    assert_includes provider.inspect, "test-model"
  end

  def test_embed_text_batched_default_single_shot_when_no_batch_size
    klass = Class.new(Parse::Embeddings::Provider) do
      attr_reader :calls
      def initialize; @calls = 0; end
      def dimensions; 4; end
      def model_name; "x"; end
      def embed_text(strings, input_type: :search_document)
        @calls += 1
        strings.map { [0.0, 0.0, 0.0, 0.0] }
      end
    end
    provider = klass.new
    out = provider.embed_text_batched(["a", "b", "c"])
    assert_equal 3, out.length
    assert_equal 1, provider.calls
  end

  def test_embed_text_batched_default_slices_by_embed_batch_size
    klass = Class.new(Parse::Embeddings::Provider) do
      attr_reader :slices
      def initialize; @slices = []; end
      def dimensions; 4; end
      def model_name; "x"; end
      def embed_batch_size; 2; end
      def embed_text(strings, input_type: :search_document)
        @slices << strings.length
        strings.map { [0.0, 0.0, 0.0, 0.0] }
      end
    end
    provider = klass.new
    out = provider.embed_text_batched(["a", "b", "c", "d", "e"])
    assert_equal 5, out.length
    assert_equal [2, 2, 1], provider.slices
  end

  def test_embed_text_batched_empty_input_short_circuits
    klass = Class.new(Parse::Embeddings::Provider) do
      attr_reader :called
      def initialize; @called = false; end
      def dimensions; 4; end
      def model_name; "x"; end
      def embed_text(strings, input_type: :search_document)
        @called = true
        []
      end
    end
    provider = klass.new
    assert_equal [], provider.embed_text_batched([])
    refute provider.called, "embed_text_batched must not call embed_text on empty input"
  end

  # ---- validate_response! ---------------------------------------------

  def test_validate_response_rejects_wrong_batch_length
    provider = Parse::Embeddings::Fixture.new(dimensions: 4)
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.validate_response!(2, [[0.0, 0.0, 0.0, 0.0]])
    end
    assert_match(/response length 1 != input count 2/, err.message)
  end

  def test_validate_response_rejects_non_array_outer
    provider = Parse::Embeddings::Fixture.new(dimensions: 4)
    assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.validate_response!(1, "not an array")
    end
  end

  def test_validate_response_rejects_non_array_inner
    provider = Parse::Embeddings::Fixture.new(dimensions: 4)
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.validate_response!(1, ["not a vector"])
    end
    assert_match(/response\[0\] is not an Array/, err.message)
  end

  def test_validate_response_rejects_wrong_width
    provider = Parse::Embeddings::Fixture.new(dimensions: 4)
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.validate_response!(1, [[1.0, 2.0]])
    end
    assert_match(/length 2 != declared dimensions 4/, err.message)
  end

  def test_validate_response_rejects_nan
    provider = Parse::Embeddings::Fixture.new(dimensions: 3)
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.validate_response!(1, [[1.0, Float::NAN, 0.0]])
    end
    assert_match(/not finite/, err.message)
  end

  def test_validate_response_rejects_infinity
    provider = Parse::Embeddings::Fixture.new(dimensions: 3)
    assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.validate_response!(1, [[1.0, Float::INFINITY, 0.0]])
    end
  end

  def test_validate_response_rejects_non_numeric_element
    provider = Parse::Embeddings::Fixture.new(dimensions: 3)
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.validate_response!(1, [[1.0, "x", 0.0]])
    end
    assert_match(/not Float or Integer/, err.message)
  end

  def test_validate_response_rejects_complex_numbers
    provider = Parse::Embeddings::Fixture.new(dimensions: 3)
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.validate_response!(1, [[1.0, Complex(1, 2), 0.0]])
    end
    assert_match(/not Float or Integer/, err.message)
  end

  def test_validate_response_rejects_rational_numbers
    provider = Parse::Embeddings::Fixture.new(dimensions: 3)
    err = assert_raises(Parse::Embeddings::InvalidResponseError) do
      provider.validate_response!(1, [[1.0, Rational(1, 2), 0.0]])
    end
    assert_match(/not Float or Integer/, err.message)
  end

  def test_validate_response_accepts_integer_elements
    provider = Parse::Embeddings::Fixture.new(dimensions: 3)
    vec = [[1, 2, 3]]
    assert_same vec, provider.validate_response!(1, vec)
  end

  def test_validate_response_accepts_empty_batch
    provider = Parse::Embeddings::Fixture.new(dimensions: 3)
    assert_equal [], provider.validate_response!(0, [])
  end

  def test_validate_response_accepts_well_formed_batch
    provider = Parse::Embeddings::Fixture.new(dimensions: 3)
    vectors = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
    assert_same vectors, provider.validate_response!(2, vectors)
  end

  # ---- Fixture provider behavior --------------------------------------

  def test_fixture_returns_correct_dimensions
    provider = Parse::Embeddings::Fixture.new(dimensions: 128)
    vectors = provider.embed_text(["alpha", "beta"])
    assert_equal 2, vectors.length
    vectors.each { |v| assert_equal 128, v.length }
  end

  def test_fixture_is_deterministic
    a = Parse::Embeddings::Fixture.new(dimensions: 16)
    b = Parse::Embeddings::Fixture.new(dimensions: 16)
    assert_equal a.embed_text(["hello"]), b.embed_text(["hello"])
  end

  def test_fixture_different_inputs_yield_different_vectors
    provider = Parse::Embeddings::Fixture.new(dimensions: 16)
    out = provider.embed_text(["alpha", "beta"])
    refute_equal out[0], out[1]
  end

  def test_fixture_input_type_changes_vector
    provider = Parse::Embeddings::Fixture.new(dimensions: 16)
    as_doc   = provider.embed_text(["foo"], input_type: :search_document).first
    as_query = provider.embed_text(["foo"], input_type: :search_query).first
    refute_equal as_doc, as_query,
                 "input_type must be folded into the seed so cache-key bugs surface in tests"
  end

  def test_fixture_output_is_unit_normalized
    provider = Parse::Embeddings::Fixture.new(dimensions: 256)
    vec = provider.embed_text(["normalize me"]).first
    norm = Math.sqrt(vec.inject(0.0) { |acc, x| acc + (x * x) })
    assert_in_delta 1.0, norm, 1e-9
  end

  def test_fixture_passes_validate_response
    provider = Parse::Embeddings::Fixture.new(dimensions: 4)
    vectors = provider.embed_text(["a", "b", "c"])
    assert_equal 3, vectors.length
    vectors.each do |v|
      assert_equal 4, v.length
      v.each { |x| assert_kind_of Float, x; assert x.finite? }
    end
  end

  def test_fixture_rejects_non_array_input
    provider = Parse::Embeddings::Fixture.new(dimensions: 4)
    assert_raises(ArgumentError) { provider.embed_text("not a batch") }
  end

  def test_fixture_rejects_non_string_element
    provider = Parse::Embeddings::Fixture.new(dimensions: 4)
    assert_raises(ArgumentError) { provider.embed_text(["ok", 123]) }
  end

  def test_fixture_rejects_non_positive_dimensions
    assert_raises(ArgumentError) { Parse::Embeddings::Fixture.new(dimensions: 0) }
    assert_raises(ArgumentError) { Parse::Embeddings::Fixture.new(dimensions: -4) }
    assert_raises(ArgumentError) { Parse::Embeddings::Fixture.new(dimensions: 3.5) }
  end

  def test_fixture_rejects_dimensions_above_max
    assert_raises(ArgumentError) do
      Parse::Embeddings::Fixture.new(dimensions: Parse::Embeddings::Fixture::MAX_DIMENSIONS + 1)
    end
  end

  def test_fixture_accepts_dimensions_at_max
    provider = Parse::Embeddings::Fixture.new(dimensions: Parse::Embeddings::Fixture::MAX_DIMENSIONS)
    assert_equal Parse::Embeddings::Fixture::MAX_DIMENSIONS, provider.dimensions
  end

  def test_fixture_empty_batch_returns_empty_array
    provider = Parse::Embeddings::Fixture.new(dimensions: 8)
    assert_equal [], provider.embed_text([])
  end

  def test_fixture_model_name_folded_into_seed
    a = Parse::Embeddings::Fixture.new(dimensions: 16, model_name: "model-a")
    b = Parse::Embeddings::Fixture.new(dimensions: 16, model_name: "model-b")
    refute_equal a.embed_text(["same"]).first, b.embed_text(["same"]).first,
                 "model_name must be folded into the seed so cross-model cache keys can't collide"
  end

  def test_fixture_metadata
    provider = Parse::Embeddings::Fixture.new(dimensions: 8, model_name: "my-fixture")
    assert_equal 8, provider.dimensions
    assert_equal "my-fixture", provider.model_name
    assert provider.normalize?
    assert provider.supports_input_type?
    assert_equal [:text], provider.modalities
  end

  # ---- parse.embeddings.embed AS::N notification -----------------------

  def capture_embed_events
    captured = []
    subscriber = ActiveSupport::Notifications.subscribe("parse.embeddings.embed") do |*args|
      captured << ActiveSupport::Notifications::Event.new(*args)
    end
    yield
    captured
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_fixture_emits_parse_embeddings_embed_event
    provider = Parse::Embeddings::Fixture.new(dimensions: 8, model_name: "fx-events")
    events = capture_embed_events do
      provider.embed_text(["hello", "world"], input_type: :search_query)
    end
    assert_equal 1, events.length
    payload = events.first.payload
    assert_equal "Parse::Embeddings::Fixture", payload[:provider]
    assert_equal "fx-events", payload[:model]
    assert_equal 8, payload[:dimensions]
    assert_equal 2, payload[:input_count]
    assert_equal :search_query, payload[:input_type]
    assert_nil payload[:total_tokens], "Fixture has no token usage"
    assert_equal false, payload[:cached]
    assert_nil payload[:error]
  end

  def test_fixture_event_records_error_class_on_validation_failure
    provider = Parse::Embeddings::Fixture.new(dimensions: 8)
    events = capture_embed_events do
      assert_raises(ArgumentError) do
        # Non-String element trips the per-element guard BEFORE the
        # instrument block — so no event is emitted for that case.
        provider.embed_text([:not_a_string])
      end
    end
    assert_equal 0, events.length,
                 "pre-validation failures should not emit an embed event"
  end

  def test_fixture_event_payload_carries_class_name_not_instance_inspect
    # Subscribers serialize :provider into log lines; must be the class
    # name (stable) not anything that could leak instance state.
    provider = Parse::Embeddings::Fixture.new(dimensions: 4)
    events = capture_embed_events { provider.embed_text(["x"]) }
    assert_equal "Parse::Embeddings::Fixture", events.first.payload[:provider]
  end

  def test_provider_instrument_embed_yields_payload_for_block_to_mutate
    klass = Class.new(Parse::Embeddings::Provider) do
      def dimensions; 4; end
      def model_name; "stub-provider"; end
      def embed_text(strings, input_type: :search_document)
        instrument_embed(strings.length, input_type) do |payload|
          payload[:total_tokens] = 42
          payload[:cached] = true
          strings.map { Array.new(4, 0.5) }
        end
      end
    end
    provider = klass.new
    events = capture_embed_events { provider.embed_text(["a", "b"]) }
    assert_equal 1, events.length
    assert_equal 42, events.first.payload[:total_tokens]
    assert_equal true, events.first.payload[:cached]
  end

  def test_provider_instrument_embed_marks_error_class_when_block_raises
    klass = Class.new(Parse::Embeddings::Provider) do
      def dimensions; 4; end
      def model_name; "raises"; end
      def embed_text(_strings, input_type: :search_document)
        instrument_embed(1, input_type) { raise Parse::Embeddings::InvalidResponseError, "boom" }
      end
    end
    provider = klass.new
    events = capture_embed_events do
      assert_raises(Parse::Embeddings::InvalidResponseError) { provider.embed_text(["x"]) }
    end
    assert_equal 1, events.length
    assert_equal "Parse::Embeddings::InvalidResponseError", events.first.payload[:error]
  end
end
