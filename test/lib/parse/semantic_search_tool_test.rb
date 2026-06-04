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
    chunk = Parse::Retrieval::Chunk.new(
      id: "x#0", content: "hello", source: { "objectId" => "x" }, score: 0.5,
      metadata: { chunk_index: 0, chunk_count: 1, object_id: "x" },
    )
    fake = lambda do |**kw|
      captured.replace(kw)
      [chunk]
    end
    Parse::Retrieval.stub(:retrieve, fake) do
      yield captured
    end
  end

  # Stub retrieve to return a fixed chunk list (for dedup / budget tests).
  def with_retrieve_returning(chunks)
    Parse::Retrieval.stub(:retrieve, ->(**_kw) { chunks }) { yield }
  end

  def chunk(oid, idx, content, count: 1)
    Parse::Retrieval::Chunk.new(
      id: "#{oid}##{idx}", content: content, score: 0.5,
      source: { "objectId" => oid, "title" => "doc-#{oid}" },
      metadata: { chunk_index: idx, chunk_count: count, object_id: oid },
    )
  end

  def call(agent, **args)
    Parse::Retrieval::AgentTool.semantic_search(agent, **args)
  end

  def test_registered_as_readonly_client_safe
    assert_equal :readonly, Parse::Agent::Tools.permission_for(:semantic_search)
    assert Parse::Agent::Tools.registered_tools_for(:readonly).include?(:semantic_search)
  end

  def test_happy_path_returns_chunks_and_documents
    with_retrieve_spy do |captured|
      out = call(fake_agent, class_name: "SemanticSearchDoc", query: "hi")
      assert_equal 1, out[:count]
      # Source is hoisted into `documents` (keyed by objectId), not inlined
      # on the chunk.
      assert_equal [{ id: "x#0", score: 0.5, content: "hello",
                      metadata: { chunk_index: 0, chunk_count: 1, object_id: "x" } }],
                   out[:chunks]
      assert_equal({ "x" => { "objectId" => "x" } }, out[:documents])
      refute out.key?(:budget_truncated)
      assert_equal "hi", captured[:query]
      assert_equal :embedding, captured[:field]
    end
  end

  # --- A3: source dedup into documents map ---

  def test_source_hoisted_once_per_document
    chunks = [chunk("a", 0, "one", count: 2), chunk("a", 1, "two", count: 2), chunk("b", 0, "three")]
    with_retrieve_returning(chunks) do
      out = call(fake_agent, class_name: "SemanticSearchDoc", query: "hi")
      assert_equal 3, out[:count]
      # Two documents despite three chunks.
      assert_equal %w[a b], out[:documents].keys.sort
      assert_equal({ "objectId" => "a", "title" => "doc-a" }, out[:documents]["a"])
      # No inline source on any chunk.
      assert(out[:chunks].none? { |c| c.key?(:source) })
      # Chunk still links to its document via metadata.object_id.
      assert_equal "a", out[:chunks].first.dig(:metadata, :object_id)
    end
  end

  def test_source_projector_strips_acl_for_unfiltered_class
    # SemanticSearchDoc declares no agent_fields, so project_object_to_allowlist
    # is a pass-through; the simplify_object normalization must still strip the
    # raw ACL from the documents-map source record (parity with other read tools).
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "t", api_key: "t")
    end
    agent = Parse::Agent.new(permissions: :readonly)
    raw = { "objectId" => "z", "title" => "t", "ACL" => { "*" => { "read" => true } } }
    Parse::Retrieval::AgentTool.stub(:convert_to_parse_form, ->(doc, _c) { doc }) do
      projector = Parse::Retrieval::AgentTool.source_projector(agent, "SemanticSearchDoc", nil)
      out = projector.call(raw)
      refute out.key?("ACL"), "ACL must be stripped from the documents-map source"
      assert_equal "t", out["title"]
    end
  ensure
    Parse::Agent.suppress_master_key_warning = false
  end

  def test_source_projector_conversion_failure_drops_internal_storage_keys
    # When convert_documents_to_parse raises, convert_to_parse_form's rescue
    # must NOT surface the raw storage-form hit: its underscore-prefixed keys
    # (_acl, _rperm/_wperm, _p_* pointers, _id) leak internal metadata that the
    # success path strips. For a class with no agent_fields allowlist this
    # fallback is the only gate, so every "_"-prefixed key must be dropped.
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "t", api_key: "t")
    end
    agent = Parse::Agent.new(permissions: :readonly)
    raw = {
      "_id" => "z", "title" => "t",
      "_acl" => { "userX" => { "r" => true } },
      "_rperm" => ["userX"], "_wperm" => ["userX"],
      "_p_author" => "_User$userX",
    }
    Parse::MongoDB.stub(:convert_documents_to_parse, ->(_docs, _c) { raise "boom" }) do
      projector = Parse::Retrieval::AgentTool.source_projector(agent, "SemanticSearchDoc", nil)
      out = projector.call(raw)
      assert_equal "t", out["title"], "non-internal field is preserved"
      %w[_id _acl _rperm _wperm _p_author].each do |k|
        refute out.key?(k), "internal storage key #{k} must be dropped in the conversion-failure fallback"
      end
    end
  ensure
    Parse::Agent.suppress_master_key_warning = false
  end

  # --- B4: total-token budget ---

  def test_token_budget_trims_and_signals
    big = "x" * 4000 # ~1000 tokens each
    chunks = [chunk("a", 0, big), chunk("b", 0, big), chunk("c", 0, big)]
    with_retrieve_returning(chunks) do
      out = call(fake_agent, class_name: "SemanticSearchDoc", query: "hi", max_total_tokens: 1500)
      assert_equal true, out[:budget_truncated]
      assert out[:count] < 3, "budget should drop at least one chunk"
      assert_equal 3 - out[:count], out[:budget_dropped]
    end
  end

  def test_token_budget_keeps_at_least_one_chunk
    huge = "x" * 40_000
    with_retrieve_returning([chunk("a", 0, huge)]) do
      out = call(fake_agent, class_name: "SemanticSearchDoc", query: "hi", max_total_tokens: 10)
      assert_equal 1, out[:count]
    end
  end

  def test_token_budget_disabled_with_zero
    big = "x" * 4000
    chunks = Array.new(5) { |i| chunk("d#{i}", 0, big) }
    with_retrieve_returning(chunks) do
      out = call(fake_agent, class_name: "SemanticSearchDoc", query: "hi", max_total_tokens: 0)
      assert_equal 5, out[:count]
      refute out.key?(:budget_truncated)
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

  # --- text_field (the multi-source escape hatch) ---

  def test_text_field_embedded_source_forwarded_as_symbol
    with_retrieve_spy do |captured|
      call(fake_agent, class_name: "SemanticSearchDoc", query: "hi", text_field: "body")
      assert_equal :body, captured[:text_field]
    end
  end

  def test_text_field_not_passed_is_nil_for_retrieve_to_infer
    with_retrieve_spy do |captured|
      call(fake_agent, class_name: "SemanticSearchDoc", query: "hi")
      assert_nil captured[:text_field]
    end
  end

  def test_text_field_outside_embedded_sources_refused
    with_retrieve_spy do |_captured|
      err = assert_raises(Parse::Agent::ValidationError) do
        call(fake_agent, class_name: "SemanticSearchDoc", query: "hi", text_field: "secret_field")
      end
      assert_match(/embedded/, err.message)
    end
  end

  # --- max_chunks_per_document forwarding (was dropped on the agent path) ---

  def test_max_chunks_per_document_forwarded_to_chunker
    with_retrieve_spy do |captured|
      call(fake_agent, class_name: "SemanticSearchDoc", query: "hi", max_chunks_per_document: 3)
      chunker = captured[:chunker]
      refute_nil chunker, "a chunker must be built when max_chunks_per_document is set"
      assert_equal 3, chunker.max_chunks_per_document
    end
  end

  def test_no_chunker_built_when_no_chunk_opts
    with_retrieve_spy do |captured|
      call(fake_agent, class_name: "SemanticSearchDoc", query: "hi")
      assert_nil captured[:chunker], "no chunker override means retrieve uses its default"
    end
  end

  # --- ergonomic aliases for direct callers ---

  def test_chunker_size_overlap_by_aliases
    with_retrieve_spy do |captured|
      call(fake_agent, class_name: "SemanticSearchDoc", query: "hi", size: 500, overlap: 50, by: "tokens")
      chunker = captured[:chunker]
      assert_equal 500, chunker.size
      assert_equal 50, chunker.overlap
      assert_equal :tokens, chunker.by
    end
  end

  def test_klass_alias_selects_class
    with_retrieve_spy do |captured|
      out = call(fake_agent, klass: "SemanticSearchDoc", query: "hi")
      assert_equal 1, out[:count]
      assert_equal :embedding, captured[:field]
    end
  end

  def test_class_alias_selects_class
    with_retrieve_spy do |captured|
      out = call(fake_agent, query: "hi", **{ class: "SemanticSearchDoc" })
      assert_equal 1, out[:count]
      assert_equal :embedding, captured[:field]
    end
  end
end
