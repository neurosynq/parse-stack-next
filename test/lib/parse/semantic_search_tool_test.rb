# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/agent"

# Unit tests for the semantic_search agent tool handler. Parse::Retrieval.retrieve
# is stubbed so these run without Atlas; they pin the security envelope:
# class allowlist, underscore-key + filter-field gates, score-quantize
# signal, k clamping, and scope-kwarg pass-through.
class SemanticSearchToolTest < Minitest::Test
  class Doc < Parse::Object
    parse_class "SemanticSearchDoc"
    property :title, :string
    property :body, :string
    property :embedding, :vector, dimensions: 8, provider: :fixture
    embed :title, :body, into: :embedding
    agent_searchable field: :embedding, filter_fields: %i[published category]
  end

  # Minimal fake agent: the handler only needs permissions +
  # acl_scope_kwargs (retrieve is stubbed, so source_projector/tenant
  # resolution for an unscoped class returns nil and needs nothing more).
  def fake_agent(permissions: :readonly, scope_kwargs: { master: true })
    a = Object.new
    a.define_singleton_method(:permissions) { permissions }
    a.define_singleton_method(:acl_scope_kwargs) { scope_kwargs }
    a
  end

  # Capture the kwargs passed to Parse::Retrieval.retrieve and return canned chunks.
  def with_retrieve_spy
    captured = {}
    chunk = Parse::Retrieval::Chunk.new(id: "x#0", content: "hello", source: { "objectId" => "x" }, score: 0.5)
    fake = lambda do |**kw|
      captured.replace(kw)
      [chunk]
    end
    Parse::Retrieval.stub(:retrieve, fake) do
      yield captured
    end
  end

  def call(agent, **args)
    Parse::Retrieval::AgentTool.semantic_search(agent, **args)
  end

  def test_registered_as_readonly_client_safe
    assert_equal :readonly, Parse::Agent::Tools.permission_for(:semantic_search)
    assert Parse::Agent::Tools.registered_tools_for(:readonly).include?(:semantic_search)
  end

  def test_happy_path_returns_chunks_hash
    with_retrieve_spy do |captured|
      out = call(fake_agent, class_name: "SemanticSearchDoc", query: "hi")
      assert_equal 1, out[:count]
      assert_equal [{ id: "x#0", score: 0.5, content: "hello", source: { "objectId" => "x" }, metadata: {} }],
                   out[:chunks]
      assert_equal "hi", captured[:query]
      assert_equal :embedding, captured[:field]
    end
  end

  def test_blank_query_raises
    assert_raises(Parse::Agent::ValidationError) do
      call(fake_agent, class_name: "SemanticSearchDoc", query: "  ")
    end
  end

  def test_unregistered_class_raises_validation
    assert_raises(Parse::Agent::ValidationError) do
      call(fake_agent, class_name: "NopeClass", query: "hi")
    end
  end

  def test_score_quantize_true_for_non_admin
    with_retrieve_spy do |captured|
      call(fake_agent(permissions: :readonly), class_name: "SemanticSearchDoc", query: "hi")
      assert_equal true, captured[:score_quantize]
    end
  end

  def test_score_quantize_false_for_admin
    with_retrieve_spy do |captured|
      call(fake_agent(permissions: :admin), class_name: "SemanticSearchDoc", query: "hi")
      assert_equal false, captured[:score_quantize]
    end
  end

  def test_acl_scope_kwargs_forwarded
    with_retrieve_spy do |captured|
      call(fake_agent(scope_kwargs: { session_token: "r:tok" }),
           class_name: "SemanticSearchDoc", query: "hi")
      assert_equal "r:tok", captured[:session_token]
    end
  end

  def test_master_scope_forwarded
    with_retrieve_spy do |captured|
      call(fake_agent(scope_kwargs: { master: true }), class_name: "SemanticSearchDoc", query: "hi")
      assert_equal true, captured[:master]
    end
  end

  def test_k_clamped_to_max
    with_retrieve_spy do |captured|
      call(fake_agent, class_name: "SemanticSearchDoc", query: "hi", k: 9999)
      assert_equal 20, captured[:k]
    end
  end

  def test_k_defaulted_when_nonpositive
    with_retrieve_spy do |captured|
      call(fake_agent, class_name: "SemanticSearchDoc", query: "hi", k: 0)
      assert_equal Parse::Retrieval::AgentTool::DEFAULT_K, captured[:k]
    end
  end

  def test_underscore_key_in_filter_refused
    with_retrieve_spy do |_captured|
      assert_raises(ArgumentError) do
        call(fake_agent, class_name: "SemanticSearchDoc", query: "hi",
             filter: { "_rperm" => ["*"] })
      end
    end
  end

  def test_filter_field_outside_allowlist_refused
    with_retrieve_spy do |_captured|
      err = assert_raises(Parse::Agent::ValidationError) do
        call(fake_agent, class_name: "SemanticSearchDoc", query: "hi",
             filter: { "secret_field" => "x" })
      end
      assert_match(/filter field/, err.message)
    end
  end

  def test_allowlisted_filter_field_passes_through
    with_retrieve_spy do |captured|
      call(fake_agent, class_name: "SemanticSearchDoc", query: "hi",
           filter: { "category" => "news" })
      assert_equal({ "category" => "news" }, captured[:filter])
    end
  end

  def test_tenant_scope_value_threaded_when_present
    reg = Parse::Agent::MetadataRegistry
    with_retrieve_spy do |captured|
      reg.stub(:resolve_tenant_scope, { field: :workspace, value: "Workspace$abc" }) do
        call(fake_agent, class_name: "SemanticSearchDoc", query: "hi")
      end
      assert_equal({ field: :workspace, value: "Workspace$abc" }, captured[:tenant_scope])
    end
  end
end
