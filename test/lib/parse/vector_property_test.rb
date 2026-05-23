# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the :vector property type and the Parse::Vector value class.
# Covers:
#   - Parse::Vector coercion, dimension awareness, finite-only enforcement.
#   - property :foo, :vector, dimensions: N — class metadata, field type,
#     coercion at assignment, dimension validation on save, default
#     omission from as_json (and opt-in via include_vectors: true).
class VectorPropertyTest < Minitest::Test
  # Anonymous Parse::Object subclass — Class.new without an assigned
  # constant trips the parse_class fallback, so we name it explicitly
  # via a real Ruby class for cleaner introspection.
  class VectorDoc < Parse::Object
    parse_class "VectorDoc"
    property :title, :string
    property :embedding, :vector, dimensions: 4,
                                  provider: :openai,
                                  model: "text-embedding-3-small",
                                  similarity: :cosine
  end

  # ---- Parse::Vector value class -----------------------------------------

  def test_vector_accepts_finite_numeric_array
    v = Parse::Vector.new([1.0, 2.0, 3.5, -0.25])
    assert_equal 4, v.dimensions
    assert_equal [1.0, 2.0, 3.5, -0.25], v.to_a
  end

  def test_vector_coerces_integers_to_floats
    v = Parse::Vector.new([1, 2, 3])
    assert v.to_a.all? { |x| x.is_a?(Float) }
  end

  def test_vector_rejects_non_array
    assert_raises(ArgumentError) { Parse::Vector.new("not an array") }
    assert_raises(ArgumentError) { Parse::Vector.new(nil) }
    assert_raises(ArgumentError) { Parse::Vector.new({ x: 1 }) }
  end

  def test_vector_rejects_non_numeric_elements
    assert_raises(ArgumentError) { Parse::Vector.new([1.0, "two", 3.0]) }
    assert_raises(ArgumentError) { Parse::Vector.new([1.0, nil, 3.0]) }
  end

  def test_vector_rejects_nan_and_infinity
    assert_raises(ArgumentError) { Parse::Vector.new([1.0, Float::NAN, 3.0]) }
    assert_raises(ArgumentError) { Parse::Vector.new([1.0, Float::INFINITY, 3.0]) }
    assert_raises(ArgumentError) { Parse::Vector.new([1.0, -Float::INFINITY, 3.0]) }
  end

  def test_vector_rejects_over_max_dimensions
    too_big = Parse::Vector::MAX_DIMENSIONS + 1
    assert_raises(ArgumentError) { Parse::Vector.new(Array.new(too_big, 0.1)) }
  end

  def test_vector_round_trips_through_initializer
    v1 = Parse::Vector.new([0.1, 0.2, 0.3])
    v2 = Parse::Vector.new(v1)
    assert_equal v1, v2
    assert_equal v1.to_a, v2.to_a
  end

  def test_vector_as_json_is_plain_float_array
    v = Parse::Vector.new([0.1, 0.2, 0.3])
    json = v.as_json
    assert_kind_of Array, json
    assert_equal [0.1, 0.2, 0.3], json
  end

  def test_vector_equality_with_array_and_vector
    v = Parse::Vector.new([0.1, 0.2])
    assert_equal v, Parse::Vector.new([0.1, 0.2])
    assert_equal v, [0.1, 0.2]
    refute_equal v, [0.1, 0.3]
    refute_equal v, "string"
  end

  # ---- Property registration --------------------------------------------

  def test_vector_registered_in_types
    assert_includes Parse::Properties::TYPES, :vector
  end

  def test_property_vector_records_field_type
    assert_equal :vector, VectorDoc.fields[:embedding]
  end

  def test_property_vector_stores_dimensions_and_metadata
    meta = VectorDoc.vector_properties[:embedding]
    refute_nil meta
    assert_equal 4, meta[:dimensions]
    assert_equal :openai, meta[:provider]
    assert_equal "text-embedding-3-small", meta[:model]
    assert_equal :cosine, meta[:similarity]
  end

  def test_property_vector_requires_dimensions
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        parse_class "NoDimDoc"
        property :embedding, :vector
      end
    end
  end

  def test_property_vector_rejects_non_positive_dimensions
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        parse_class "ZeroDimDoc"
        property :embedding, :vector, dimensions: 0
      end
    end
    assert_raises(ArgumentError) do
      Class.new(Parse::Object) do
        parse_class "NegDimDoc"
        property :embedding, :vector, dimensions: -5
      end
    end
  end

  # ---- Assignment coercion ----------------------------------------------

  def test_assignment_coerces_array_to_vector
    doc = VectorDoc.new
    doc.embedding = [0.1, 0.2, 0.3, 0.4]
    assert_kind_of Parse::Vector, doc.embedding
    assert_equal 4, doc.embedding.dimensions
  end

  def test_assignment_accepts_parse_vector_directly
    doc = VectorDoc.new
    v = Parse::Vector.new([0.1, 0.2, 0.3, 0.4])
    doc.embedding = v
    assert_kind_of Parse::Vector, doc.embedding
    assert_equal v, doc.embedding
  end

  def test_assignment_nil_clears_field
    doc = VectorDoc.new
    doc.embedding = [0.1, 0.2, 0.3, 0.4]
    doc.embedding = nil
    assert_nil doc.embedding
  end

  def test_assignment_rejects_non_array_non_vector
    doc = VectorDoc.new
    assert_raises(ArgumentError) { doc.embedding = "not a vector" }
    assert_raises(ArgumentError) { doc.embedding = 123 }
    assert_raises(ArgumentError) { doc.embedding = { vec: [1] } }
  end

  def test_assignment_with_non_finite_elements_raises
    doc = VectorDoc.new
    assert_raises(ArgumentError) { doc.embedding = [0.1, Float::NAN, 0.3, 0.4] }
    assert_raises(ArgumentError) { doc.embedding = [0.1, "x", 0.3, 0.4] }
  end

  # ---- Dimension validation at save -------------------------------------

  def test_save_validation_catches_dimension_mismatch
    doc = VectorDoc.new(title: "doc")
    # Pre-build a Parse::Vector of wrong dimension and stuff it past the
    # coercion path — both the format_value coercion and validates_each
    # run, but only validates_each is dimension-aware at the property
    # declaration level.
    doc.instance_variable_set(:@embedding, Parse::Vector.new([0.1, 0.2]))
    refute doc.valid?
    assert doc.errors[:embedding].any? { |e| e.include?("expected 4 dimensions") }
  end

  def test_save_validation_passes_for_matching_dimensions
    doc = VectorDoc.new(title: "doc", embedding: [0.1, 0.2, 0.3, 0.4])
    assert doc.valid?, "expected valid; got #{doc.errors.full_messages.inspect}"
  end

  # ---- as_json default omission ----------------------------------------

  def test_as_json_omits_vector_fields_by_default
    doc = VectorDoc.new(title: "doc", embedding: [0.1, 0.2, 0.3, 0.4])
    json = doc.as_json
    refute json.key?("embedding"), "embedding should be omitted by default; got #{json.inspect}"
    assert_equal "doc", json["title"]
  end

  def test_as_json_includes_vector_when_opted_in
    doc = VectorDoc.new(title: "doc", embedding: [0.1, 0.2, 0.3, 0.4])
    json = doc.as_json(include_vectors: true)
    assert json.key?("embedding"), "embedding should be present when include_vectors: true"
  end

  def test_as_json_omits_vector_even_when_dirty
    doc = VectorDoc.new(title: "doc")
    doc.embedding = [0.1, 0.2, 0.3, 0.4]
    assert doc.changed_attributes.key?("embedding") || doc.changes.key?("embedding"),
           "embedding must be dirty-tracked"
    refute doc.as_json.key?("embedding")
  end
end
