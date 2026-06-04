# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# Tests the _source provenance stamping: the Tools.stamp_source! helper,
# the Parse::Agent.include_source_provenance flag, and the semantic_search
# integration.
class SourceProvenanceTest < Minitest::Test
  def setup
    @saved = Parse::Agent.include_source_provenance
    Parse::Agent.include_source_provenance = true
  end

  def teardown
    Parse::Agent.include_source_provenance = @saved
  end

  def test_flag_defaults_false
    Parse::Agent.include_source_provenance = nil
    refute Parse::Agent.include_source_provenance?
  end

  def test_stamp_sets_source
    rows = [{ "objectId" => "a1", "title" => "x" }]
    Parse::Agent::Tools.stamp_source!(rows, class_name: "Post", tool: :query_class)
    assert_equal({ "class" => "Post", "tool" => "query_class", "object_id" => "a1" }, rows.first["_source"])
  end

  def test_stamp_nil_object_id_for_grouped_rows
    rows = [{ "count" => 5 }] # no objectId (a $group row)
    Parse::Agent::Tools.stamp_source!(rows, class_name: "Post", tool: :aggregate)
    assert_nil rows.first["_source"]["object_id"]
    assert_equal "aggregate", rows.first["_source"]["tool"]
  end

  def test_stamp_idempotent
    rows = [{ "objectId" => "a1", "_source" => { "class" => "Pre", "tool" => "existing", "object_id" => "a1" } }]
    Parse::Agent::Tools.stamp_source!(rows, class_name: "Post", tool: :query_class)
    assert_equal "existing", rows.first["_source"]["tool"]
  end

  def test_stamp_skips_non_hash_rows
    rows = ["scalar", 42, { "objectId" => "a1" }]
    Parse::Agent::Tools.stamp_source!(rows, class_name: "Post", tool: :query_class)
    assert_equal "scalar", rows[0]
    assert rows[2].key?("_source")
  end

  def test_stamp_noop_when_disabled
    Parse::Agent.include_source_provenance = false
    rows = [{ "objectId" => "a1" }]
    Parse::Agent::Tools.stamp_source!(rows, class_name: "Post", tool: :query_class)
    refute rows.first.key?("_source")
  end

  # --- semantic_search integration ---

  class ProvDoc < Parse::Object
    parse_class "ProvenanceDoc"
    property :body, :string
    property :embedding, :vector, dimensions: 8, provider: :fixture
    embed :body, into: :embedding
    agent_searchable field: :embedding
  end

  def fake_agent
    a = Object.new
    a.define_singleton_method(:permissions) { :readonly }
    a.define_singleton_method(:acl_scope_kwargs) { { master: true } }
    a
  end

  def test_semantic_search_adds_underscore_source
    chunk = Parse::Retrieval::Chunk.new(
      id: "doc1#0", content: "hi", score: 0.5,
      source: { "objectId" => "doc1", "body" => "hi" },
      metadata: { object_id: "doc1", chunk_index: 0 },
    )
    out = nil
    Parse::Retrieval.stub(:retrieve, ->(**_kw) { [chunk] }) do
      out = Parse::Retrieval::AgentTool.semantic_search(fake_agent, class_name: "ProvenanceDoc", query: "hi")
    end
    c = out[:chunks].first
    # _source provenance is stamped from the chunk's metadata.object_id.
    assert_equal({ "class" => "ProvenanceDoc", "tool" => "semantic_search", "object_id" => "doc1" }, c[:_source])
    # The parent record is hoisted into the deduped `documents` map, not
    # inlined on the chunk — so `_source` is the chunk's only source marker.
    refute c.key?(:source), "source record is hoisted into documents, not inlined on the chunk"
    assert_equal({ "objectId" => "doc1", "body" => "hi" }, out[:documents]["doc1"])
  end

  def test_semantic_search_omits_source_when_disabled
    Parse::Agent.include_source_provenance = false
    chunk = Parse::Retrieval::Chunk.new(id: "d#0", content: "hi", source: {}, metadata: {})
    out = nil
    Parse::Retrieval.stub(:retrieve, ->(**_kw) { [chunk] }) do
      out = Parse::Retrieval::AgentTool.semantic_search(fake_agent, class_name: "ProvenanceDoc", query: "hi")
    end
    refute out[:chunks].first.key?(:_source)
  end
end
