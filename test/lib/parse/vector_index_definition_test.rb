# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../support/snapshot_helper"
require "minitest/autorun"

# Generated Atlas vectorSearch index definitions
# (Parse::VectorSearch::IndexDefinition): snapshot-pinned output for the
# plain, filtered + tenant-scoped, and quantized shapes; the structured
# diff against a live index; the `vector_search_index` macro feeding the
# explicit SearchIndexMigrator; and quantization validation and drift.
class VectorIndexDefinitionTest < Minitest::Test
  GROUP = "vector_index_definition".freeze
  ID = Parse::VectorSearch::IndexDefinition

  class GenPlain < Parse::Object
    parse_class "GenPlain"
    property :embedding, :vector, dimensions: 1024
  end

  class GenFiltered < Parse::Object
    parse_class "GenFiltered"
    property :category, :string
    property :published, :boolean
    property :tenant_key, :string
    belongs_to :author, as: :user
    property :embedding, :vector, dimensions: 768, similarity: :dotProduct
    agent_searchable field: :embedding, filter_fields: %i[published category author]
  end

  class GenScalar < Parse::Object
    parse_class "GenScalar"
    property :embedding, :vector, dimensions: 1024, quantization: :scalar
  end

  class GenBinary < Parse::Object
    parse_class "GenBinary"
    property :embedding, :vector, dimensions: 1024, similarity: :euclidean, quantization: :binary
  end

  class GenTwoVectors < Parse::Object
    parse_class "GenTwoVectors"
    property :text_vec, :vector, dimensions: 8
    property :image_vec, :vector, dimensions: 16
  end

  class GenDeclared < Parse::Object
    parse_class "GenDeclared"
    property :category, :string
    property :embedding, :vector, dimensions: 4, quantization: :scalar
    agent_searchable field: :embedding, filter_fields: %i[category]
    vector_search_index "gen_declared_vec"
  end

  def with_tenant_scope(class_name, field)
    Parse::Agent::MetadataRegistry.register_tenant_scope(class_name, field, from: ->(_a) { "t" })
    yield
  ensure
    Parse::Agent::MetadataRegistry.instance_variable_get(:@tenant_scope_rules)&.delete(class_name)
  end

  # ---- generated shapes --------------------------------------------------

  def test_plain_definition
    assert_snapshot(ID.build(GenPlain), name: "plain", group: GROUP)
  end

  def test_filters_and_tenant_definition
    defn = with_tenant_scope("GenFiltered", :tenant_key) { ID.build(GenFiltered) }
    paths = defn["fields"].select { |f| f["type"] == "filter" }.map { |f| f["path"] }
    assert_equal %w[_p_author category published tenantKey], paths, "filters sorted; pointer uses storage path"
    assert_snapshot(defn, name: "filters_and_tenant", group: GROUP)
  end

  def test_scalar_quantization_definition
    defn = ID.build(GenScalar)
    assert_equal "scalar", defn["fields"].first["quantization"]
    assert_snapshot(defn, name: "quantization_scalar", group: GROUP)
  end

  def test_binary_quantization_definition
    defn = ID.build(GenBinary)
    assert_equal "binary", defn["fields"].first["quantization"]
    assert_snapshot(defn, name: "quantization_binary", group: GROUP)
  end

  def test_output_is_deterministic
    a = with_tenant_scope("GenFiltered", :tenant_key) { JSON.generate(ID.build(GenFiltered)) }
    b = with_tenant_scope("GenFiltered", :tenant_key) { JSON.generate(ID.build(GenFiltered)) }
    assert_equal a, b
    assert_equal %w[type path numDimensions similarity],
                 JSON.parse(a)["fields"].first.keys, "vector entry keys in fixed order"
  end

  def test_default_similarity_is_cosine
    assert_equal "cosine", ID.build(GenPlain)["fields"].first["similarity"]
  end

  def test_field_required_when_ambiguous_and_validated
    assert_raises(ArgumentError) { ID.build(GenTwoVectors) }
    assert_equal 16, ID.build(GenTwoVectors, field: :image_vec)["fields"].first["numDimensions"]
    assert_raises(ArgumentError) { ID.build(GenTwoVectors, field: :nope) }
  end

  def test_schema_entry_point_and_preview
    assert_equal ID.build(GenPlain), Parse::Schema.vector_index_definition(GenPlain)
    preview = ID.preview(GenPlain, name: "gen_plain_vec")
    assert_equal({ name: "gen_plain_vec", type: "vectorSearch", definition: ID.build(GenPlain) }, preview)
  end

  # ---- quantization declaration -----------------------------------------

  def test_quantization_is_validated_at_declaration
    klass = self.class.const_defined?(:GenBadQuant, false) ? self.class::GenBadQuant :
      self.class.const_set(:GenBadQuant, Class.new(Parse::Object))
    err = assert_raises(ArgumentError) do
      klass.property :embedding, :vector, dimensions: 4, quantization: :int4
    end
    assert_match(/quantization/, err.message)
  end

  def test_quantization_off_by_default
    assert_nil GenPlain.vector_properties[:embedding][:quantization]
    refute ID.build(GenPlain)["fields"].first.key?("quantization")
    assert_equal :scalar, GenScalar.vector_properties[:embedding][:quantization]
  end

  # ---- diff -------------------------------------------------------------

  def live_index(defn)
    { "name" => "x", "type" => "vectorSearch", "latestDefinition" => defn }
  end

  def test_diff_in_sync_against_identical_live_index
    defn = ID.build(GenScalar)
    result = ID.diff(defn, live_index(JSON.parse(JSON.generate(defn))))
    assert result[:in_sync]
  end

  def test_diff_reports_vector_and_filter_changes
    declared = with_tenant_scope("GenFiltered", :tenant_key) { ID.build(GenFiltered) }
    live = {
      "fields" => [
        { "type" => "vector", "path" => "embedding", "numDimensions" => 1536,
          "similarity" => "dotProduct", "quantization" => "binary" },
        { "type" => "filter", "path" => "category" },
        { "type" => "filter", "path" => "legacyFlag" },
      ],
    }
    result = ID.diff(declared, live_index(live))
    refute result[:in_sync]
    assert_equal({ "numDimensions" => { declared: 768, live: 1536 },
                   "quantization" => { declared: "none", live: "binary" } }, result[:vector])
    assert_equal %w[_p_author published tenantKey], result[:filters_missing]
    assert_equal %w[legacyFlag], result[:filters_extra]
    assert_snapshot(result, name: "diff_vector_and_filters", group: GROUP)
  end

  def test_diff_treats_absent_quantization_as_none
    defn = ID.build(GenPlain)
    live = JSON.parse(JSON.generate(defn))
    live["fields"].first["quantization"] = "none"
    assert ID.diff(defn, live)[:in_sync]
  end

  # ---- macro + explicit migrator ----------------------------------------

  def test_macro_declaration_reaches_the_migrator_plan
    decl = GenDeclared.search_indexes_plan[:declared].find { |d| d[:name] == "gen_declared_vec" }
    refute_nil decl
    assert_equal "vectorSearch", decl[:type]
    assert_equal ID.build(GenDeclared), decl[:definition]
  end

  def test_macro_definition_is_generated_at_plan_time
    with_tenant_scope("GenDeclared", :category) do
      decl = GenDeclared.search_indexes_plan[:declared].find { |d| d[:name] == "gen_declared_vec" }
      paths = decl[:definition]["fields"].select { |f| f["type"] == "filter" }.map { |f| f["path"] }
      assert_equal %w[category], paths, "tenant path deduplicated against filter_fields"
    end
  end

  def test_macro_rejects_name_collisions
    assert_raises(ArgumentError) { GenDeclared.mongo_search_index("gen_declared_vec", { "fields" => [] }) }
    assert_raises(ArgumentError) { GenDeclared.vector_search_index("gen_declared_vec", field: :other) }
    assert_equal({ name: "gen_declared_vec", field: nil }, GenDeclared.vector_search_index("gen_declared_vec"))
  end

  def test_plan_does_not_apply
    # Without Atlas, plan degrades to "everything to create" and performs
    # no mutation; application stays an explicit apply_search_indexes! call.
    plan = GenDeclared.search_indexes_plan
    assert_includes plan[:to_create].map { |d| d[:name] }, "gen_declared_vec"
  end
end
