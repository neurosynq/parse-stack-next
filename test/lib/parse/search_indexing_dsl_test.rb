# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the Parse::Core::SearchIndexing DSL (`mongo_search_index`
# declaration validation + accumulator semantics). No MongoDB, no Atlas
# — purely class-level declarative behavior.
class SearchIndexingDSLTest < Minitest::Test
  # Each test class gets its own anonymous Parse::Object subclass so
  # declarations don't leak between tests. parse_class is set so the
  # class registers cleanly without colliding with other test models.
  def fresh_model(name = "SearchIxModel#{SecureRandom.hex(4)}")
    klass = Class.new(Parse::Object)
    klass.define_singleton_method(:name) { name }
    klass.parse_class(name)
    klass
  end

  def test_mongo_search_index_registers_a_declaration
    m = fresh_model
    m.mongo_search_index("text_search", { mappings: { dynamic: true } })
    assert_equal 1, m.mongo_search_index_declarations.size
    decl = m.mongo_search_index_declarations.first
    assert_equal "text_search", decl[:name]
    assert_equal "search", decl[:type]
    assert_equal({ mappings: { dynamic: true } }, decl[:definition])
  end

  def test_mongo_search_index_supports_multiple_indexes_per_class
    m = fresh_model
    m.mongo_search_index("text_search",         { mappings: { dynamic: true } })
    m.mongo_search_index("autocomplete_index",  { mappings: { fields: { title: { type: "autocomplete" } } } })
    assert_equal 2, m.mongo_search_index_declarations.size
    assert_equal %w[text_search autocomplete_index],
                 m.mongo_search_index_declarations.map { |d| d[:name] }
  end

  def test_mongo_search_index_accepts_vectorsearch_type
    m = fresh_model
    decl = m.mongo_search_index(
      "vec_idx",
      { fields: [{ type: "vector", path: "embedding", numDimensions: 1536, similarity: "cosine" }] },
      type: "vectorSearch",
    )
    assert_equal "vectorSearch", decl[:type]
  end

  def test_mongo_search_index_rejects_unknown_type
    m = fresh_model
    assert_raises(ArgumentError) do
      m.mongo_search_index("ix", { mappings: { dynamic: true } }, type: "bogus")
    end
  end

  def test_mongo_search_index_rejects_invalid_name
    m = fresh_model
    %w[1leading_digit has\ space has/slash has:colon].each do |bad|
      assert_raises(ArgumentError, "expected #{bad.inspect} to be rejected") do
        m.mongo_search_index(bad, { mappings: { dynamic: true } })
      end
    end
  end

  def test_mongo_search_index_rejects_empty_or_non_hash_definition
    m = fresh_model
    assert_raises(ArgumentError) { m.mongo_search_index("ix", nil) }
    assert_raises(ArgumentError) { m.mongo_search_index("ix", {}) }
    assert_raises(ArgumentError) { m.mongo_search_index("ix", "not a hash") }
  end

  def test_mongo_search_index_idempotent_redeclaration_with_identical_content
    m = fresh_model
    first  = m.mongo_search_index("ix", { mappings: { dynamic: true } })
    second = m.mongo_search_index("ix", { mappings: { dynamic: true } })
    assert_equal 1, m.mongo_search_index_declarations.size,
                 "identical redeclaration must not accumulate duplicates"
    assert_same first, second, "idempotent redeclaration returns the existing entry"
  end

  def test_mongo_search_index_raises_on_redeclaration_with_different_definition
    m = fresh_model
    m.mongo_search_index("ix", { mappings: { dynamic: true } })
    assert_raises(ArgumentError) do
      m.mongo_search_index("ix", { mappings: { dynamic: false, fields: { title: { type: "string" } } } })
    end
  end

  def test_mongo_search_index_raises_on_redeclaration_with_different_type
    m = fresh_model
    m.mongo_search_index("ix", { mappings: { dynamic: true } })
    assert_raises(ArgumentError) do
      m.mongo_search_index("ix", { mappings: { dynamic: true } }, type: "vectorSearch")
    end
  end

  def test_declarations_are_deeply_frozen
    m = fresh_model
    inner_fields = { title: { type: "string" } }
    m.mongo_search_index("ix", { mappings: { fields: inner_fields } })
    decl = m.mongo_search_index_declarations.first
    assert decl.frozen?
    assert decl[:definition].frozen?
    assert decl[:definition][:mappings].frozen?
    assert decl[:definition][:mappings][:fields].frozen?
    # And the inner-fields nested hash:
    assert decl[:definition][:mappings][:fields][:title].frozen?
  end

  def test_subclasses_have_separate_declaration_storage
    parent = fresh_model("SIxParent#{SecureRandom.hex(4)}")
    child  = Class.new(parent)
    child.define_singleton_method(:name) { "SIxChild#{SecureRandom.hex(4)}" }
    child.parse_class("SIxChild#{SecureRandom.hex(4)}")
    parent.mongo_search_index("p_ix", { mappings: { dynamic: true } })
    child.mongo_search_index("c_ix",  { mappings: { dynamic: false, fields: { title: { type: "string" } } } })
    assert_equal %w[p_ix], parent.mongo_search_index_declarations.map { |d| d[:name] }
    assert_equal %w[c_ix], child.mongo_search_index_declarations.map { |d| d[:name] }
  end
end
