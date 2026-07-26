# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for Parse::Embeddings::BindingAudit and the declaration-time
# validation of :vector property options.
#
# A `:vector` property declares `provider:`, `model:`, and `dimensions:`,
# but only `provider:` was ever enforced, and `dimensions:` only after a
# provider had already returned a vector. `model:` was never checked —
# the dangerous gap, because same-family models usually share a width
# (voyage-3 and voyage-3.5 are both 1024), so swapping the registered
# model silently mixes incomparable vectors into one index with no error.
class EmbeddingsBindingAuditTest < Minitest::Test
  class AuditDoc < Parse::Object
    parse_class "AuditDoc"
    property :body, :string
    property :body_embedding, :vector, dimensions: 4,
                                       provider: :audit_fx, model: "fx-4"
  end

  # No `model:` declared — opts out of the model half of the check.
  class AuditNoModel < Parse::Object
    parse_class "AuditNoModel"
    property :embedding, :vector, dimensions: 4, provider: :audit_fx
  end

  class WideStorageOnly < Parse::Object
    parse_class "WideStorageOnly"
    property :embedding, :vector, dimensions: 9000, searchable: false
  end

  class DefaultSearchable < Parse::Object
    parse_class "DefaultSearchable"
    property :embedding, :vector, dimensions: 4
  end

  class GoodSimilarity < Parse::Object
    parse_class "GoodSimilarity"
    property :a_vec, :vector, dimensions: 4, similarity: "euclidean"
    property :b_vec, :vector, dimensions: 4, similarity: "cosine"
    property :c_vec, :vector, dimensions: 4, similarity: "dotProduct"
  end

  # Same field name and provider as AuditDoc but a different declared
  # model — used to prove verdicts are not carried over between classes.
  class AuditDocRedeclared < Parse::Object
    parse_class "AuditDocRedeclared"
    property :body_embedding, :vector, dimensions: 4,
                                       provider: :audit_fx, model: "fx-9"
  end

  def setup
    Parse::Embeddings.reset!
  end

  def teardown
    Parse::Embeddings.reset!
  end

  # ---- model binding ----------------------------------------------------

  def test_matching_binding_passes
    register(dimensions: 4, model_name: "fx-4")
    Parse::Embeddings::BindingAudit.verify!(
      AuditDoc, :body_embedding, Parse::Embeddings.provider(:audit_fx)
    )
  end

  # The headline case: identical width, different model. Nothing else in
  # the stack notices this.
  def test_same_width_different_model_is_refused
    register(dimensions: 4, model_name: "fx-4-turbo")
    err = assert_raises(Parse::Embeddings::BindingAudit::BindingMismatch) do
      Parse::Embeddings::BindingAudit.verify!(
        AuditDoc, :body_embedding, Parse::Embeddings.provider(:audit_fx)
      )
    end
    assert_match(/declares model: "fx-4"/, err.message)
    assert_match(/running "fx-4-turbo"/, err.message)
    assert_match(/not comparable/, err.message)
  end

  def test_dimension_mismatch_is_refused
    register(dimensions: 8, model_name: "fx-4")
    err = assert_raises(Parse::Embeddings::BindingAudit::BindingMismatch) do
      Parse::Embeddings::BindingAudit.verify!(
        AuditDoc, :body_embedding, Parse::Embeddings.provider(:audit_fx)
      )
    end
    assert_match(/declares dimensions: 4/, err.message)
    assert_match(/emits 8-dim/, err.message)
  end

  # A property that declares no model: opts out of that half of the
  # check rather than failing.
  def test_property_without_declared_model_skips_the_model_check
    register(dimensions: 4, model_name: "anything-at-all")
    Parse::Embeddings::BindingAudit.verify!(
      AuditNoModel, :embedding, Parse::Embeddings.provider(:audit_fx)
    )
  end

  def test_unknown_field_is_a_no_op
    register(dimensions: 4, model_name: "fx-4")
    Parse::Embeddings::BindingAudit.verify!(
      AuditDoc, :not_a_property, Parse::Embeddings.provider(:audit_fx)
    )
  end

  # ---- fail-closed on unusable provider accessors -----------------------

  # A provider that cannot say what model it runs cannot satisfy a
  # declared `model:`. Skipping the comparison would let a custom
  # provider write same-width embeddings that are never checked at all.
  class NoModelNameProvider < Parse::Embeddings::Provider
    def dimensions = 4
    def embed_text(strings, input_type: :search_document)
      strings.map { Array.new(4, 0.5) }
    end
  end

  def test_provider_without_model_name_fails_closed
    Parse::Embeddings.register(:audit_fx, NoModelNameProvider.new)
    err = assert_raises(Parse::Embeddings::BindingAudit::BindingMismatch) do
      Parse::Embeddings::BindingAudit.verify!(
        AuditDoc, :body_embedding, Parse::Embeddings.provider(:audit_fx)
      )
    end
    assert_match(/does not report a usable #model_name/, err.message)
  end

  class NilModelNameProvider < Parse::Embeddings::Provider
    def dimensions = 4
    def model_name = nil
    def embed_text(strings, input_type: :search_document)
      strings.map { Array.new(4, 0.5) }
    end
  end

  def test_provider_returning_nil_model_name_fails_closed
    Parse::Embeddings.register(:audit_fx, NilModelNameProvider.new)
    assert_raises(Parse::Embeddings::BindingAudit::BindingMismatch) do
      Parse::Embeddings::BindingAudit.verify!(
        AuditDoc, :body_embedding, Parse::Embeddings.provider(:audit_fx)
      )
    end
  end

  class NoDimensionsProvider < Parse::Embeddings::Provider
    def model_name = "fx-4"
    def embed_text(strings, input_type: :search_document)
      strings.map { Array.new(4, 0.5) }
    end
  end

  def test_provider_without_dimensions_fails_closed
    Parse::Embeddings.register(:audit_fx, NoDimensionsProvider.new)
    err = assert_raises(Parse::Embeddings::BindingAudit::BindingMismatch) do
      Parse::Embeddings::BindingAudit.verify!(
        AuditDoc, :body_embedding, Parse::Embeddings.provider(:audit_fx)
      )
    end
    assert_match(/does not report a usable #dimensions/, err.message)
  end

  # A property that declares no model: opts out, so a provider without
  # model_name is fine there.
  def test_provider_without_model_name_is_fine_when_none_is_declared
    Parse::Embeddings.register(:audit_fx, NoModelNameProvider.new)
    Parse::Embeddings::BindingAudit.verify!(
      AuditNoModel, :embedding, Parse::Embeddings.provider(:audit_fx)
    )
  end

  # ---- no stale approvals ------------------------------------------------

  # Verification is not memoized, so a class redefined with a changed
  # declaration is re-checked rather than inheriting an earlier verdict.
  def test_repeated_verification_reflects_the_current_declaration
    register(dimensions: 4, model_name: "fx-4")
    provider = Parse::Embeddings.provider(:audit_fx)
    Parse::Embeddings::BindingAudit.verify!(AuditDoc, :body_embedding, provider)

    # Same field, same provider instance, different declaration: the
    # earlier pass must not carry over.
    assert_raises(Parse::Embeddings::BindingAudit::BindingMismatch) do
      Parse::Embeddings::BindingAudit.verify!(AuditDocRedeclared, :body_embedding, provider)
    end
  end

  # ---- audit_all! -------------------------------------------------------

  def test_audit_all_reports_problems_without_raising
    register(dimensions: 4, model_name: "wrong-model")
    problems = Parse::Embeddings::BindingAudit.audit_all!(classes: [AuditDoc])
    assert_equal 1, problems.length
    assert_match(/AuditDoc#body_embedding/, problems.first)
  end

  def test_audit_all_is_clean_when_bindings_match
    register(dimensions: 4, model_name: "fx-4")
    assert_empty Parse::Embeddings::BindingAudit.audit_all!(classes: [AuditDoc])
  end

  def test_audit_all_or_raise_raises_on_drift
    register(dimensions: 4, model_name: "wrong-model")
    err = assert_raises(Parse::Embeddings::BindingAudit::BindingMismatch) do
      Parse::Embeddings::BindingAudit.audit_all_or_raise!(classes: [AuditDoc])
    end
    assert_match(/binding audit failed/, err.message)
  end

  # An empty result from a crashed sweep is indistinguishable from a
  # clean audit, so discovery failure must be reported, not swallowed —
  # otherwise audit_all_or_raise! passes having checked nothing.
  # Break the real discovery mechanism, so the module's own rescue is
  # what runs rather than a stub standing in for it.
  def with_broken_discovery
    ObjectSpace.stub(:each_object, ->(*) { raise "objectspace unavailable" }) { yield }
  end

  def test_discovery_failure_is_reported_not_swallowed
    with_broken_discovery do
      problems = Parse::Embeddings::BindingAudit.audit_all!
      assert_equal 1, problems.length
      assert_match(/could not enumerate/, problems.first)
    end
  end

  def test_audit_all_or_raise_fails_when_discovery_fails
    with_broken_discovery do
      err = assert_raises(Parse::Embeddings::BindingAudit::BindingMismatch) do
        Parse::Embeddings::BindingAudit.audit_all_or_raise!
      end
      assert_match(/could not enumerate/, err.message)
    end
  end

  # An explicit class list does not depend on discovery at all.
  def test_explicit_classes_bypass_discovery
    register(dimensions: 4, model_name: "fx-4")
    with_broken_discovery do
      assert_empty Parse::Embeddings::BindingAudit.audit_all!(classes: [AuditDoc])
    end
  end

  # A provider may legitimately be registered later in boot, so an
  # unregistered name is only a failure under strict:.
  def test_unregistered_provider_is_skipped_unless_strict
    assert_empty Parse::Embeddings::BindingAudit.audit_all!(classes: [AuditDoc])
    problems = Parse::Embeddings::BindingAudit.audit_all!(classes: [AuditDoc], strict: true)
    assert_equal 1, problems.length
  end

  # Re-registering a provider must invalidate the memoized verdict,
  # otherwise a drifted binding would keep passing on cached state.
  def test_reset_clears_memoized_verdicts
    register(dimensions: 4, model_name: "fx-4")
    Parse::Embeddings::BindingAudit.verify!(
      AuditDoc, :body_embedding, Parse::Embeddings.provider(:audit_fx)
    )
    Parse::Embeddings.reset!
    register(dimensions: 4, model_name: "fx-4-turbo")
    assert_raises(Parse::Embeddings::BindingAudit::BindingMismatch) do
      Parse::Embeddings::BindingAudit.verify!(
        AuditDoc, :body_embedding, Parse::Embeddings.provider(:audit_fx)
      )
    end
  end

  # ---- declaration-time validation --------------------------------------

  def test_invalid_similarity_is_refused_at_declaration
    err = assert_raises(ArgumentError) do
      declare(:embedding, :vector, dimensions: 4, similarity: :cosine_ish)
    end
    assert_match(/similarity:/, err.message)
    assert_match(/euclidean/, err.message)
  end

  def test_valid_similarities_are_accepted
    assert_equal "euclidean", GoodSimilarity.vector_properties[:a_vec][:similarity]
    assert_equal "cosine", GoodSimilarity.vector_properties[:b_vec][:similarity]
    assert_equal "dotProduct", GoodSimilarity.vector_properties[:c_vec][:similarity]
  end

  # Parse::Vector tolerates 16384 dims but Atlas caps a vectorSearch
  # index at 8192, so a wider searchable property is storable and
  # permanently unsearchable. That must fail at declaration.
  def test_dimensions_above_the_atlas_index_cap_are_refused_when_searchable
    err = assert_raises(ArgumentError) do
      declare(:embedding, :vector, dimensions: 9000)
    end
    assert_match(/exceeds the Atlas vectorSearch index cap/, err.message)
    assert_match(/searchable: false/, err.message)
  end

  def test_wide_storage_only_vector_is_allowed_with_explicit_opt_out
    assert_equal 9000, WideStorageOnly.vector_properties[:embedding][:dimensions]
    refute WideStorageOnly.vector_properties[:embedding][:searchable]
  end

  def test_searchable_defaults_to_true
    assert DefaultSearchable.vector_properties[:embedding][:searchable]
  end

  # `searchable: false` must actually mean unsearchable, not merely
  # acknowledge the dimension cap — otherwise field resolution would
  # happily route a query at a field no index can serve.
  def test_storage_only_field_is_refused_by_find_similar
    err = assert_raises(Parse::Core::VectorSearchable::NoVectorProperty) do
      WideStorageOnly.find_similar(vector: Array.new(9000, 0.1), field: :embedding)
    end
    assert_match(/searchable: false/, err.message)
    assert_match(/storage-only/, err.message)
  end

  # A class whose only :vector property is storage-only has nothing to
  # auto-resolve to.
  def test_storage_only_field_is_not_auto_resolved
    err = assert_raises(Parse::Core::VectorSearchable::NoVectorProperty) do
      WideStorageOnly.find_similar(vector: Array.new(9000, 0.1))
    end
    assert_match(/no searchable :vector property/, err.message)
  end

  # The agent DSL registers a search tool, so a storage-only field must
  # be refused at class load rather than at the agent's first query.
  def test_agent_searchable_refuses_a_storage_only_field
    err = assert_raises(ArgumentError) do
      named_parse_class("AgentWideStorageOnly") do
        property :embedding, :vector, dimensions: 9000, searchable: false
        agent_searchable field: :embedding
      end
    end
    assert_match(/searchable: false/, err.message)
    assert_match(/cannot back a search tool/, err.message)
  end

  def test_agent_searchable_accepts_a_searchable_field
    klass = named_parse_class("AgentSearchableOk") do
      property :embedding, :vector, dimensions: 4
      agent_searchable field: :embedding
    end
    assert_equal :embedding, klass.agent_searchable_field
  end

  def test_non_boolean_searchable_is_refused
    assert_raises(ArgumentError) do
      declare(:embedding, :vector, dimensions: 4, searchable: "yes")
    end
  end

  # Storage cap still applies independently of the index cap.
  def test_dimensions_above_the_storage_cap_are_refused_even_when_unsearchable
    err = assert_raises(ArgumentError) do
      declare(:embedding, :vector, dimensions: 20_000, searchable: false)
    end
    assert_match(/exceeds max/, err.message)
  end

  private

  # Declare a property on a throwaway class. `parse_class` is skipped
  # because ActiveModel refuses to name an anonymous class, and these
  # declarations are expected to raise before any of that matters.
  def declare(*args, **opts)
    Class.new(Parse::Object) { property(*args, **opts) }
  end

  # Build a Parse::Object subclass that HAS a constant name, which
  # `parse_class` requires. Used where the body under test needs the
  # class to be nameable (the agent DSL reads `parse_class`).
  def named_parse_class(const_name, &body)
    Object.send(:remove_const, const_name) if Object.const_defined?(const_name, false)
    klass = Class.new(Parse::Object)
    Object.const_set(const_name, klass)
    @named_classes = (@named_classes || []) << const_name
    klass.class_eval do
      parse_class const_name
      instance_eval(&body)
    end
    klass
  end

  def register(dimensions:, model_name:)
    Parse::Embeddings.register(
      :audit_fx,
      Parse::Embeddings::Fixture.new(dimensions: dimensions, model_name: model_name),
    )
  end
end
