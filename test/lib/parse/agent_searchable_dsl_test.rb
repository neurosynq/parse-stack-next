# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/agent"

# Unit tests for the agent_searchable DSL macro and
# MetadataRegistry.resolve_searchable! (the three opt-in / safety gates).
class AgentSearchableDSLTest < Minitest::Test
  class SearchableArticle < Parse::Object
    parse_class "SearchableArticleDSL"
    property :title, :string
    property :body, :string
    property :embedding, :vector, dimensions: 8, provider: :fixture
    embed :title, :body, into: :embedding
    agent_searchable field: :embedding, filter_fields: %i[published category]
  end

  class HiddenSearchable < Parse::Object
    parse_class "HiddenSearchableDSL"
    property :body, :string
    property :embedding, :vector, dimensions: 8, provider: :fixture
    embed :body, into: :embedding
    agent_searchable field: :embedding
    agent_hidden
  end

  class NotAVector < Parse::Object
    parse_class "NotAVectorDSL"
    property :title, :string
  end

  def test_macro_stores_field_and_filter_fields
    assert_equal :embedding, SearchableArticle.agent_searchable_field
    assert_equal %i[published category], SearchableArticle.agent_searchable_filter_fields
  end

  def test_registry_records_opt_in
    assert_equal :embedding, Parse::Agent::MetadataRegistry.searchable_field("SearchableArticleDSL")
    assert_equal %i[published category],
                 Parse::Agent::MetadataRegistry.searchable_filter_fields("SearchableArticleDSL")
  end

  def test_macro_rejects_non_vector_field
    assert_raises(ArgumentError) do
      NotAVector.class_eval { agent_searchable field: :title }
    end
  end

  def test_resolve_happy_path_returns_class
    assert_equal SearchableArticle,
                 Parse::Agent::MetadataRegistry.resolve_searchable!("SearchableArticleDSL")
  end

  def test_resolve_unopted_raises_validation_error
    assert_raises(Parse::Agent::ValidationError) do
      Parse::Agent::MetadataRegistry.resolve_searchable!("TotallyUnregisteredClass")
    end
  end

  def test_resolve_hidden_raises_access_denied
    err = assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::MetadataRegistry.resolve_searchable!("HiddenSearchableDSL")
    end
    assert_equal :hidden_class, err.kind
  end

  def test_resolve_missing_tenant_scope_raises
    # Simulate a tenant-aware deployment (some class declares a scope)
    # where this searchable class declares none. Stub the global tenant
    # flags so we don't pollute other tests with a real registration.
    reg = Parse::Agent::MetadataRegistry
    reg.stub(:any_tenant_scope?, true) do
      reg.stub(:tenant_scope_rule, nil) do
        assert_raises(Parse::Agent::MissingTenantScope) do
          reg.resolve_searchable!("SearchableArticleDSL")
        end
      end
    end
  end

  def test_resolve_with_tenant_scope_present_passes
    reg = Parse::Agent::MetadataRegistry
    reg.stub(:any_tenant_scope?, true) do
      reg.stub(:tenant_scope_rule, { field: :workspace, from: ->(_a) { "w1" } }) do
        assert_equal SearchableArticle, reg.resolve_searchable!("SearchableArticleDSL")
      end
    end
  end
end
