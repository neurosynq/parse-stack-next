# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/atlas_search"
require "parse/vector_search/hybrid"

# Unit tests for the protected-field oracle refusals shared by every
# Atlas Search and vector search entry point. Stripping a protected
# field from the OUTPUT does not stop it deciding which rows match, how
# they rank, or which rows a filter keeps, so a scoped (non-master)
# caller must not be able to name one in a `$search` path, highlight,
# autocomplete field, sort key, or filter predicate.
#
# Harness mirrors atlas_search_acl_injection_test.rb: CLP is seeded into
# the CLPScope cache, Session.resolve is stubbed for session tokens, and
# Parse::MongoDB.collection returns a fake that records pipelines.
class AtlasSearchProtectedPathsTest < Minitest::Test
  PATHS = Parse::AtlasSearch::ProtectedPaths

  class FakeCollection
    attr_reader :pipelines

    def initialize
      @pipelines = []
      @rows = []
    end

    def aggregate(pipeline, _opts = {})
      @pipelines << pipeline
      @rows
    end

    def seed(rows)
      @rows = rows
    end
  end

  def setup
    begin
      Parse.client
    rescue Parse::Error::ConnectionError
      Parse.setup(server_url: "http://localhost:9999/parse",
                  application_id: "test-app",
                  api_key: "test-key")
    end
    Parse::AtlasSearch.reset!
    Parse::AtlasSearch.configure(enabled: true, default_index: "default")
    Parse::CLPScope.reset_cache!
    Parse::ACLScope.reset_warning_state!
    seed_clp("Song", {
      "find" => { "*" => true },
      "protectedFields" => { "*" => ["ssn"] },
    })
    seed_clp("Open", { "find" => { "*" => true } })

    @collections = Hash.new { |h, k| h[k] = FakeCollection.new }
    @original_available = Parse::MongoDB.method(:available?)
    Parse::MongoDB.define_singleton_method(:available?) { true }
    @original_collection = Parse::MongoDB.method(:collection)
    collections = @collections
    Parse::MongoDB.define_singleton_method(:collection) do |name, **_opts|
      collections[name.to_s]
    end
    @token = stub_session(user_id: "U1")
  end

  def teardown
    Parse::MongoDB.define_singleton_method(:available?, @original_available) if @original_available
    Parse::MongoDB.define_singleton_method(:collection, @original_collection) if @original_collection
    if Parse::AtlasSearch::Session.singleton_class.method_defined?(:__orig_resolve)
      Parse::AtlasSearch::Session.singleton_class.send(:alias_method, :resolve, :__orig_resolve)
      Parse::AtlasSearch::Session.singleton_class.send(:remove_method, :__orig_resolve)
    end
    Parse::AtlasSearch.reset!
    Parse::CLPScope.reset_cache!
  end

  def seed_clp(class_name, clp)
    Parse::CLPScope.__cache_put(class_name, clp: clp)
  end

  def stub_session(user_id:, role_names: [], token: "tok-abc")
    resolved = Parse::AtlasSearch::Session::Resolved.new(user_id, Set.new(role_names))
    Parse::AtlasSearch::Session.singleton_class.send(:alias_method, :__orig_resolve, :resolve)
    Parse::AtlasSearch::Session.define_singleton_method(:resolve) do |t|
      t == token ? resolved : __orig_resolve(t)
    end
    token
  end

  def ran?(collection = "Song")
    !@collections[collection].pipelines.empty?
  end

  def stage(operator)
    { "$search" => { "index" => "default" }.merge(operator) }
  end

  def assert_denied(&block)
    err = assert_raises(Parse::CLPScope::Denied, &block)
    refute ran?, "a refused call must not reach MongoDB"
    err
  end

  # ---------------------------------------------------------------
  # The shared helper
  # ---------------------------------------------------------------

  def test_touches_normalizes_dotted_and_pointer_storage_paths
    set = Set["ssn", "owner", "createdAt"]
    assert PATHS.touches?("ssn", set)
    assert PATHS.touches?("ssn.area", set)
    assert PATHS.touches?(:ssn, set)
    assert PATHS.touches?("_p_owner", set)
    assert PATHS.touches?("_created_at", set)
    refute PATHS.touches?("title", set)
    refute PATHS.touches?("ssnx", set)
    refute PATHS.touches?("_p_title", set)
  end

  def test_touches_path_objects_and_arrays
    set = Set["ssn"]
    assert PATHS.touches?({ "wildcard" => "*" }, set)
    assert PATHS.touches?({ wildcard: "title*" }, set)
    assert PATHS.touches?({ "value" => "ssn", "multi" => "english" }, set)
    refute PATHS.touches?({ "value" => "title", "multi" => "english" }, set)
    assert PATHS.touches?(["title", "ssn.x"], set)
    refute PATHS.touches?(["title", "body"], set)
    assert PATHS.touches?(42, set), "an unrecognized path shape reaches every field"
  end

  def test_touches_is_false_when_nothing_is_protected
    refute PATHS.touches?({ "wildcard" => "*" }, Set.new)
    refute PATHS.touches?("ssn", nil)
  end

  # ---------------------------------------------------------------
  # 1. search_with_stage walks the caller's $search stage
  # ---------------------------------------------------------------

  def test_search_with_stage_refuses_protected_path_in_compound_filter
    s = stage("compound" => {
      "must" => [{ "text" => { "query" => "x", "path" => "title" } }],
      "filter" => [{ "equals" => { "path" => "ssn", "value" => "123" } }],
    })
    assert_denied { Parse::AtlasSearch.search_with_stage("Song", s, session_token: @token) }
  end

  def test_search_with_stage_refuses_nested_embedded_document_path
    s = stage("embeddedDocument" => {
      "path" => "items",
      "operator" => { "compound" => { "mustNot" => [
        { "text" => { "query" => "x", "path" => ["items.name", "ssn.area"] } },
      ] } },
    })
    assert_denied { Parse::AtlasSearch.search_with_stage("Song", s, session_token: @token) }
  end

  def test_search_with_stage_refuses_wildcard_and_multi_path_objects
    wildcard = stage("text" => { "query" => "x", "path" => { "wildcard" => "*" } })
    assert_denied { Parse::AtlasSearch.search_with_stage("Song", wildcard, session_token: @token) }
    multi = stage("text" => { "query" => "x", "path" => { "value" => "ssn", "multi" => "en" } })
    assert_denied { Parse::AtlasSearch.search_with_stage("Song", multi, session_token: @token) }
  end

  def test_search_with_stage_refuses_protected_sort_and_query_string
    sorted = stage("text" => { "query" => "x", "path" => "title" }, "sort" => { "ssn" => 1 })
    assert_denied { Parse::AtlasSearch.search_with_stage("Song", sorted, session_token: @token) }
    qs = stage("queryString" => { "defaultPath" => "title", "query" => "ssn:123*" })
    assert_denied { Parse::AtlasSearch.search_with_stage("Song", qs, session_token: @token) }
  end

  def test_search_with_stage_refuses_protected_score_function_path
    s = stage("text" => {
      "query" => "x", "path" => "title",
      "score" => { "function" => { "path" => { "value" => "_p_ssn", "undefined" => 0 } } },
    })
    assert_denied { Parse::AtlasSearch.search_with_stage("Song", s, session_token: @token) }
  end

  def test_search_with_stage_allows_unprotected_paths_and_relevance_sort
    s = stage("compound" => {
      "should" => [{ "text" => { "query" => "x", "path" => "title" } }],
    }, "sort" => { "score" => { "$meta" => "searchScore" } })
    Parse::AtlasSearch.search_with_stage("Song", s, session_token: @token)
    assert ran?
  end

  def test_search_with_stage_master_is_unaffected
    s = stage("text" => { "query" => "x", "path" => { "wildcard" => "*" } }, "sort" => { "ssn" => 1 })
    Parse::AtlasSearch.search_with_stage("Song", s, master: true)
    assert ran?
  end

  def test_search_with_stage_class_without_protected_fields_is_unaffected
    s = stage("text" => { "query" => "x", "path" => { "wildcard" => "*" } })
    Parse::AtlasSearch.search_with_stage("Open", s, session_token: @token)
    assert ran?("Open")
  end

  def test_query_block_mode_refuses_protected_builder_path
    require "parse/query"
    q = Parse::Query.new("Song")
    q.session_token = @token
    assert_denied do
      q.atlas_search { |s| s.text(query: "x", path: :ssn) }
    end
  end

  # ---------------------------------------------------------------
  # 2. Highlights use the helper
  # ---------------------------------------------------------------

  def test_highlight_field_dotted_or_pointer_form_is_refused
    %w[ssn.sub _p_ssn].each do |hl|
      assert_denied do
        Parse::AtlasSearch.search("Song", "hi", fields: ["title"],
                                                session_token: @token, highlight_field: hl)
      end
    end
  end

  def test_strip_protected_highlights_drops_dotted_and_pointer_paths
    docs = [{ "_highlights" => [
      { "path" => "title" }, { "path" => "ssn.sub" }, { "path" => "_p_ssn" },
      { "path" => { "value" => "ssn", "multi" => "en" } },
    ] }]
    Parse::AtlasSearch.send(:strip_protected_highlights!, docs, Set["ssn"])
    assert_equal [{ "path" => "title" }], docs.first["_highlights"]
  end

  # ---------------------------------------------------------------
  # 3. Autocomplete field
  # ---------------------------------------------------------------

  def test_autocomplete_on_dotted_or_pointer_protected_field_is_refused
    %w[ssn.first _p_ssn].each do |f|
      assert_denied do
        Parse::AtlasSearch.autocomplete("Song", "12", field: f, session_token: @token)
      end
    end
  end

  # ---------------------------------------------------------------
  # 4. Search fields
  # ---------------------------------------------------------------

  def test_search_fields_pointer_form_is_refused
    assert_denied do
      Parse::AtlasSearch.search("Song", "hi", fields: ["title", "_p_ssn"], session_token: @token)
    end
  end

  # ---------------------------------------------------------------
  # 5. Filter predicate keys
  # ---------------------------------------------------------------

  def test_search_filter_keyed_on_protected_field_is_refused
    filters = [
      { "ssn" => "123-45-6789" },
      { "ssn.area" => "123" },
      { "_p_ssn" => "X$abc" },
      { "$or" => [{ "title" => "a" }, { "ssn" => { "$regex" => "^1" } }] },
      { "$and" => [{ "$nor" => [{ "ssn" => "x" }] }] },
      { "$expr" => { "$gt" => ["$_p_ssn", "M"] } },
      { ssn: "symbol key" },
    ]
    filters.each do |filter|
      assert_denied do
        Parse::AtlasSearch.search("Song", "hi", fields: ["title"], filter: filter,
                                                session_token: @token)
      end
    end
  end

  def test_search_filter_on_unprotected_field_is_allowed
    Parse::AtlasSearch.search("Song", "hi", fields: ["title"],
                                            filter: { "$or" => [{ "title" => "a" }, { "genre" => "b" }] },
                                            session_token: @token)
    assert ran?
  end

  def test_search_filter_on_protected_field_allowed_for_master
    Parse::AtlasSearch.search("Song", "hi", filter: { "ssn" => "x" }, master: true)
    assert ran?
  end

  def test_search_sort_on_protected_field_is_refused
    assert_denied do
      Parse::AtlasSearch.search("Song", "hi", fields: ["title"], sort: { "ssn" => 1 },
                                              session_token: @token)
    end
  end

  def test_autocomplete_filter_keyed_on_protected_field_is_refused
    assert_denied do
      Parse::AtlasSearch.autocomplete("Song", "ti", field: "title", filter: { "ssn" => "1" },
                                                    session_token: @token)
    end
  end

  def test_search_with_stage_filter_keyed_on_protected_field_is_refused
    s = stage("text" => { "query" => "x", "path" => "title" })
    assert_denied do
      Parse::AtlasSearch.search_with_stage("Song", s, filter: { "ssn" => "1" }, session_token: @token)
    end
  end

  # ---------------------------------------------------------------
  # 6. Vector search and the hybrid native path
  # ---------------------------------------------------------------

  def session_resolution(master: false)
    Parse::ACLScope::Resolution.new(
      mode: master ? :master : :session,
      permission_strings: master ? nil : Set["U1", "*"],
      user_id: master ? nil : "U1",
    )
  end

  def vector_search(**kwargs)
    resolution = session_resolution
    Parse::MongoDB.stub(:require_gem!, nil) do
      Parse::ACLScope.stub(:resolve!, ->(*, **) { resolution }) do
        Parse::VectorSearch.search("Song", query_vector: [0.1, 0.2, 0.3], k: 5,
                                           index: "vec_idx", **kwargs)
      end
    end
  end

  def test_vector_search_filter_keyed_on_protected_field_is_refused
    assert_denied { vector_search(field: "embedding", filter: { "ssn" => "1" }) }
    assert_denied { vector_search(field: "embedding", vector_filter: { "$or" => [{ "_p_ssn" => "x" }] }) }
    assert_denied { vector_search(field: "embedding", filter: { "$expr" => { "$eq" => ["$ssn", "1"] } }) }
  end

  def test_vector_search_on_protected_vector_field_is_refused
    seed_clp("Song", { "find" => { "*" => true }, "protectedFields" => { "*" => ["embedding"] } })
    assert_denied { vector_search(field: "embedding") }
  end

  def test_vector_search_unprotected_filter_is_allowed
    vector_search(field: "embedding", filter: { "title" => "a" })
    assert ran?
  end

  def run_native(lex:, vec:, master: false)
    vec = { field: "embedding", query_vector: [0.1, 0.2, 0.3], index: "vec_idx" }.merge(vec)
    lex = { query: "hi", fields: ["title"], index: "default" }.merge(lex)
    Parse::VectorSearch::Hybrid.send(:run_native, "Song", lex, vec, 10,
                                     k_constant: 60, weights: nil, scope_opts: {},
                                     resolution: session_resolution(master: master))
  end

  def test_hybrid_native_refuses_protected_filter_keys
    assert_denied { run_native(lex: { filter: { "ssn" => "1" } }, vec: {}) }
    assert_denied { run_native(lex: {}, vec: { filter: { "ssn.area" => "1" } }) }
    assert_denied { run_native(lex: {}, vec: { vector_filter: { "_p_ssn" => "1" } }) }
    assert_denied { run_native(lex: { filter: { "$expr" => { "$gt" => ["$ssn", "1"] } } }, vec: {}) }
  end

  def test_hybrid_native_refuses_protected_vector_field
    assert_denied { run_native(lex: {}, vec: { field: "ssn" }) }
  end

  def test_hybrid_native_allows_unprotected_filters_and_master
    run_native(lex: { filter: { "title" => "a" } }, vec: { filter: { "genre" => "b" } })
    assert ran?
    @collections["Song"].pipelines.clear
    run_native(lex: { filter: { "ssn" => "1" } }, vec: {}, master: true)
    assert ran?
  end

  # ---------------------------------------------------------------
  # 7. Faceted search (public fallback, no auth kwargs)
  # ---------------------------------------------------------------

  def test_faceted_search_refuses_protected_facet_path
    facets = { by_ssn: { type: :string, path: :ssn } }
    assert_denied { Parse::AtlasSearch.faceted_search("Song", nil, facets) }
  end

  def test_faceted_search_refuses_wildcard_query_when_fields_are_protected
    facets = { genre: { type: :string, path: :genre } }
    assert_denied { Parse::AtlasSearch.faceted_search("Song", "hi", facets) }
  end

  def test_faceted_search_with_unprotected_paths_runs
    facets = { genre: { type: :string, path: :genre } }
    Parse::AtlasSearch.faceted_search("Song", "hi", facets, fields: ["title"], limit: 0)
    assert ran?
  end

  def test_faceted_search_master_is_unaffected
    facets = { by_ssn: { type: :string, path: :ssn } }
    Parse::AtlasSearch.faceted_search("Song", "hi", facets, master: true, limit: 0)
    assert ran?
  end
end
