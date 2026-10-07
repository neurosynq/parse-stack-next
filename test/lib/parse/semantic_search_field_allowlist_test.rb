# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/agent"

# semantic_search must not return a field outside the class's agent_fields
# allowlist as chunk content. The embedding may be computed from a field the
# agent cannot read (search the body, show only the title); that field's text
# must still never reach the agent, either as chunk content or as reranker
# input built from the same text field.
#
# These run the real Parse::Retrieval.retrieve and mock only the search
# boundary (find_similar), so the chunk-building path is exercised end to end.
class SemanticSearchFieldAllowlistTest < Minitest::Test
  # Embeds a field the agent may not read.
  class HiddenBodyDoc < Parse::Object
    parse_class "SemanticAllowlistHiddenBody"
    property :title, :string
    property :body, :string
    property :embedding, :vector, dimensions: 8, provider: :fixture
    embed :body, into: :embedding
    agent_searchable field: :embedding
    agent_fields :title
  end

  # Two embedded sources, only one readable.
  class MixedDoc < Parse::Object
    parse_class "SemanticAllowlistMixed"
    property :title, :string
    property :summary, :string
    property :body, :string
    property :embedding, :vector, dimensions: 8, provider: :fixture
    embed :summary, :body, into: :embedding
    agent_searchable field: :embedding
    agent_fields :title, :summary
  end

  # Two embedded sources, both readable: inference stays ambiguous.
  class OpenMultiDoc < Parse::Object
    parse_class "SemanticAllowlistOpenMulti"
    property :summary, :string
    property :body, :string
    property :embedding, :vector, dimensions: 8, provider: :fixture
    embed :summary, :body, into: :embedding
    agent_searchable field: :embedding
    agent_fields :summary, :body
  end

  # Filterable fields, for per-agent narrowing of filter_fields.
  class FilterDoc < Parse::Object
    parse_class "SemanticAllowlistFilter"
    property :summary, :string
    property :category, :string
    property :region, :string
    property :embedding, :vector, dimensions: 8, provider: :fixture
    embed :summary, into: :embedding
    agent_searchable field: :embedding, filter_fields: %i[category region]
    agent_fields :summary, :category, :region
  end

  SECRET = "PRIVATE-BODY-TEXT do not disclose"

  def fake_agent
    a = Object.new
    a.define_singleton_method(:permissions) { :readonly }
    a.define_singleton_method(:acl_scope_kwargs) { { master: true } }
    a
  end

  def setup
    @search_calls = 0
  end

  # Run semantic_search with find_similar returning one raw hit carrying
  # every field, private ones included. Every search is counted in
  # @search_calls, which stays readable even when the call raises.
  def run_search(klass, **args)
    hit = { "_id" => "d1", "title" => "Public title", "summary" => "Public summary",
            "body" => SECRET, "_vscore" => 0.9 }
    klass.stub(:find_similar, ->(**_kw) { @search_calls += 1; [hit] }) do
      Parse::Retrieval::AgentTool.stub(:convert_to_parse_form, ->(doc, _c) { doc.dup }) do
        Parse::Retrieval::AgentTool.semantic_search(
          fake_agent, class_name: klass.parse_class, query: "anything", **args,
        )
      end
    end
  end

  def test_inferred_hidden_text_source_is_refused_before_search
    err = assert_raises(Parse::Agent::AccessDenied) { run_search(HiddenBodyDoc) }
    assert_equal :field_denied, err.kind
    assert_equal "body", err.denied_field
    refute_includes err.message, SECRET
    assert_equal 0, @search_calls, "the search must not run for a refused text field"
  end

  def test_explicit_hidden_text_source_is_refused_before_search
    err = assert_raises(Parse::Agent::AccessDenied) { run_search(MixedDoc, text_field: "body") }
    assert_equal :field_denied, err.kind
    assert_equal 0, @search_calls, "the search must not run for a refused text field"
  end

  # Guards the counter itself: a successful search must register, or the
  # zero-call assertions above would pass vacuously.
  def test_search_counter_records_a_real_search
    run_search(MixedDoc, text_field: "summary")
    assert_equal 1, @search_calls
  end

  def test_inference_picks_the_only_readable_source
    result = run_search(MixedDoc)
    contents = result[:chunks].map { |c| c[:content] }
    assert_equal ["Public summary"], contents
    refute_includes JSON.generate(result), SECRET
  end

  def test_explicit_readable_source_still_works
    result = run_search(MixedDoc, text_field: "summary")
    assert_equal ["Public summary"], result[:chunks].map { |c| c[:content] }
    refute_includes JSON.generate(result), SECRET
  end

  # ---- per-agent narrowing (5.8) ----------------------------------------

  def narrowed_agent(narrowing)
    a = fake_agent
    a.define_singleton_method(:field_narrowing_for) do |cn|
      names = narrowing[cn.to_s]
      names && Parse::Agent::MetadataRegistry.wire_field_names(cn, names)
    end
    a
  end

  def test_per_agent_narrowing_hides_a_text_source_the_class_allows
    # The class ceiling allows summary, but this agent narrows it away.
    a = narrowed_agent("SemanticAllowlistMixed" => %i[title])
    err = assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::FieldPolicy.with(a) do
        MixedDoc.stub(:find_similar, ->(**_kw) { @search_calls += 1; [] }) do
          Parse::Retrieval::AgentTool.semantic_search(a, class_name: "SemanticAllowlistMixed", query: "q")
        end
      end
    end
    assert_equal :field_denied, err.kind
    assert_equal 0, @search_calls
  end

  def test_per_agent_narrowing_narrows_filter_fields
    a = narrowed_agent("SemanticAllowlistFilter" => %i[summary region])
    err = assert_raises(Parse::Agent::ValidationError) do
      Parse::Agent::FieldPolicy.with(a) do
        Parse::Retrieval::AgentTool.semantic_search(a, class_name: "SemanticAllowlistFilter", query: "q",
                                                       filter: { "category" => "x" })
      end
    end
    assert_match(/category/, err.message)
  end

  def test_multiple_readable_sources_still_require_text_field
    err = assert_raises(Parse::Agent::ValidationError) { run_search(OpenMultiDoc) }
    assert_match(/text_field/, err.message)
  end
end
