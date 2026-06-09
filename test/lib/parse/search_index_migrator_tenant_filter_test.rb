# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the v5.5 SearchIndexMigrator augmentation: vectorSearch
# index declarations on classes with a registered agent_tenant_scope are
# auto-extended with the scope field as a `type: "filter"` path (so the
# tenant pre-filter Parse::Retrieval folds into $vectorSearch.filter is
# always covered by the deployed index).
class SearchIndexMigratorTenantFilterTest < Minitest::Test
  class TFDoc < Parse::Object
    parse_class "TFDoc"
    property :title, :string
    property :tenant_key, :string

    mongo_search_index "tfdoc_vec", {
      "fields" => [
        { "type" => "vector", "path" => "embedding",
          "numDimensions" => 4, "similarity" => "cosine" },
      ],
    }, type: "vectorSearch"

    mongo_search_index "tfdoc_lex", {
      "mappings" => { "dynamic" => true },
    }
  end

  class TFCovered < Parse::Object
    parse_class "TFCovered"
    property :tenant_key, :string

    mongo_search_index "tfcovered_vec", {
      "fields" => [
        { "type" => "vector", "path" => "embedding",
          "numDimensions" => 4, "similarity" => "cosine" },
        { "type" => "filter", "path" => "tenantKey" },
      ],
    }, type: "vectorSearch"
  end

  def with_tenant_scope(class_name, field)
    Parse::Agent::MetadataRegistry.register_tenant_scope(class_name, field, from: ->(_a) { "t" })
    yield
  ensure
    Parse::Agent::MetadataRegistry.instance_variable_get(:@tenant_scope_rules)&.delete(class_name)
  end

  def declared_for(klass)
    Parse::Schema::SearchIndexMigrator.new(klass).plan[:declared]
  end

  def filter_paths(decl)
    (decl[:definition]["fields"] || []).select { |f| (f["type"] || f[:type]).to_s == "filter" }
                                       .map { |f| (f["path"] || f[:path]).to_s }
  end

  def test_no_tenant_scope_leaves_declaration_untouched
    decls = declared_for(TFDoc)
    vec = decls.find { |d| d[:name] == "tfdoc_vec" }
    assert_empty filter_paths(vec)
  end

  def test_tenant_scope_field_auto_added_as_filter_path
    with_tenant_scope("TFDoc", :tenant_key) do
      decls = declared_for(TFDoc)
      vec = decls.find { |d| d[:name] == "tfdoc_vec" }
      # tenant_key columnizes to its wire name.
      assert_equal ["tenantKey"], filter_paths(vec)
      # The vector entry is preserved.
      types = vec[:definition]["fields"].map { |f| f["type"] }
      assert_includes types, "vector"
    end
  end

  def test_lexical_declaration_never_augmented
    with_tenant_scope("TFDoc", :tenant_key) do
      decls = declared_for(TFDoc)
      lex = decls.find { |d| d[:name] == "tfdoc_lex" }
      refute lex[:definition].key?("fields")
    end
  end

  def test_already_covered_declaration_unchanged
    with_tenant_scope("TFCovered", :tenant_key) do
      decls = declared_for(TFCovered)
      vec = decls.find { |d| d[:name] == "tfcovered_vec" }
      assert_equal ["tenantKey"], filter_paths(vec)
      assert_equal 2, vec[:definition]["fields"].length
    end
  end

  def test_original_declaration_not_mutated
    with_tenant_scope("TFDoc", :tenant_key) do
      declared_for(TFDoc)
      raw = TFDoc.mongo_search_index_declarations.find { |d| d[:name] == "tfdoc_vec" }
      assert_equal 1, raw[:definition]["fields"].length,
                   "augmentation must not write back into the frozen declaration"
    end
  end
end
