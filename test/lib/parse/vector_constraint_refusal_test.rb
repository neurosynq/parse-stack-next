# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the `Parse::Query#reject_vector_constraint!` choke
# point. `:vector` properties only accept `$exists`-shaped constraints
# (the `:exists` / `:null` operators) in Parse::Query; every other
# operator is misuse and should raise immediately at query-build time
# so the foot-gun never reaches Parse Server.
#
# Vector retrieval lives on `Parse::Core::VectorSearchable.find_similar`,
# which doesn't go through Parse::Query at all -- it routes directly to
# {Parse::VectorSearch.search}. So anything that reaches
# Query#add_constraint with a `:vector` operand is, by definition, the
# wrong API.
class VectorConstraintRefusalTest < Minitest::Test
  class VecDoc < Parse::Object
    parse_class "VecDoc"
    property :title, :string
    property :body, :string
    property :body_embedding, :vector, dimensions: 4, provider: :fixture
  end

  # ---- allow-list: non-vector fields untouched --------------------------

  def test_allows_constraints_on_non_vector_fields
    q = VecDoc.query(title: "hello")
    assert_equal 1, q.constraints.size
  end

  def test_allows_eq_on_non_vector_field
    q = VecDoc.query(:body.eq => "x")
    assert_equal 1, q.constraints.size
  end

  # ---- allow-list: $exists on vector field ------------------------------

  def test_allows_exists_on_vector_field
    q = VecDoc.query(:body_embedding.exists => true)
    assert_equal 1, q.constraints.size
  end

  def test_allows_null_on_vector_field
    # `:null` and `:exists` both compile to $exists -- both legitimate
    # for backfill queries ("docs missing an embedding").
    q = VecDoc.query(:body_embedding.null => true)
    assert_equal 1, q.constraints.size
  end

  # ---- refusal: every other operator ------------------------------------

  def test_refuses_eq_on_vector_field
    err = assert_raises(Parse::VectorSearch::ConstraintNotSupported) do
      VecDoc.query(body_embedding: [1.0, 2.0, 3.0, 4.0])
    end
    assert_match(/is a :vector property/, err.message)
    assert_match(/find_similar/, err.message)
  end

  def test_refuses_in_on_vector_field
    assert_raises(Parse::VectorSearch::ConstraintNotSupported) do
      VecDoc.query(:body_embedding.in => [[1.0], [2.0]])
    end
  end

  def test_refuses_nin_on_vector_field
    assert_raises(Parse::VectorSearch::ConstraintNotSupported) do
      VecDoc.query(:body_embedding.nin => [[1.0]])
    end
  end

  def test_refuses_ne_on_vector_field
    assert_raises(Parse::VectorSearch::ConstraintNotSupported) do
      VecDoc.query(:body_embedding.ne => [1.0])
    end
  end

  def test_refuses_gt_on_vector_field
    assert_raises(Parse::VectorSearch::ConstraintNotSupported) do
      VecDoc.query(:body_embedding.gt => 5)
    end
  end

  def test_refuses_lt_on_vector_field
    assert_raises(Parse::VectorSearch::ConstraintNotSupported) do
      VecDoc.query(:body_embedding.lt => 5)
    end
  end

  def test_refuses_all_on_vector_field
    assert_raises(Parse::VectorSearch::ConstraintNotSupported) do
      VecDoc.query(:body_embedding.all => [1.0, 2.0])
    end
  end

  # ---- refusal: remote field name routes to the same check --------------

  def test_refuses_in_on_remote_camelcased_field
    # `:bodyEmbedding` is the remote field name. Some users build
    # queries against the parse_field directly.
    assert_raises(Parse::VectorSearch::ConstraintNotSupported) do
      VecDoc.query(:bodyEmbedding.in => [1])
    end
  end

  # ---- silent no-op when class can't be resolved ------------------------

  def test_unresolvable_table_is_silently_skipped
    # An ad-hoc Query against a table that doesn't map to a known
    # Parse::Object subclass must not crash the constraint pipeline --
    # legacy code may build such queries.
    q = Parse::Query.new("NoSuchClass1234")
    q.add_constraint(:foo.in, [1, 2, 3])
    assert_equal 1, q.constraints.size
  end

  # ---- error inheritance ------------------------------------------------

  def test_constraint_not_supported_is_an_argument_error
    assert_operator Parse::VectorSearch::ConstraintNotSupported, :<, ArgumentError
  end
end
