# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/atlas_search"
require "parse/agent"

# Unit tests for the three Atlas Search agent tools:
# atlas_text_search, atlas_autocomplete, atlas_faceted_search.
#
# Coverage focus:
#   * Auth refusal — agent without session_token AND without
#     master_atlas: true is refused regardless of the library-level
#     require_session_token toggle.
#   * Session-bound agents forward their session_token.
#   * master_atlas: true agents forward master: true.
#   * agent_fields allowlist applies to `fields:` / `field:` /
#     `highlight_field:` / facet path arguments and to the returned
#     document rows.
#   * Highlights for fields outside the allowlist are dropped.
#   * Limits are clamped to ATLAS_LIMIT_MAX.
#   * faceted_search refuses session-bound agents even without an
#     allowlist (the bucket-count ACL gap).
class AtlasSearchAgentToolsTest < Minitest::Test
  def setup
    begin
      Parse.client
    rescue Parse::Error::ConnectionError
      Parse.setup(server_url: "http://localhost:9999/parse",
                  application_id: "test-app",
                  api_key: "test-key")
    end
    Parse::AtlasSearch.reset!
    Parse::AtlasSearch.configure(enabled: true)

    @captures = []

    # Stub Parse::AtlasSearch.search/.autocomplete/.faceted_search so
    # we can inspect what the tools forward without standing up a real
    # MongoDB. Each stub records its kwargs and returns a minimal
    # SearchResult shape.
    @captured_methods = {}
    captures = @captures
    @captured_methods[:search] = Parse::AtlasSearch.method(:search)
    @captured_methods[:autocomplete] = Parse::AtlasSearch.method(:autocomplete)
    @captured_methods[:faceted_search] = Parse::AtlasSearch.method(:faceted_search)

    Parse::AtlasSearch.define_singleton_method(:search) do |collection, query, **opts|
      captures << { op: :search, collection: collection, query: query, opts: opts }
      build_stub_search_result
    end
    Parse::AtlasSearch.define_singleton_method(:autocomplete) do |collection, query, field:, **opts|
      captures << { op: :autocomplete, collection: collection, query: query, field: field, opts: opts }
      build_stub_autocomplete_result
    end
    Parse::AtlasSearch.define_singleton_method(:faceted_search) do |collection, query, facets, **opts|
      captures << { op: :faceted_search, collection: collection, query: query, facets: facets, opts: opts }
      build_stub_faceted_result
    end

    # Helpers attached to the AtlasSearch singleton for reuse in stubs.
    Parse::AtlasSearch.define_singleton_method(:build_stub_search_result) do
      result = Object.new
      result.define_singleton_method(:results) { [] }
      result.define_singleton_method(:raw_results) { [] }
      result
    end
    Parse::AtlasSearch.define_singleton_method(:build_stub_autocomplete_result) do
      result = Object.new
      result.define_singleton_method(:suggestions) { ["lov"] }
      result.define_singleton_method(:results) { [] }
      result
    end
    Parse::AtlasSearch.define_singleton_method(:build_stub_faceted_result) do
      result = Object.new
      result.define_singleton_method(:results) { [] }
      result.define_singleton_method(:facets) { {} }
      result.define_singleton_method(:total_count) { 0 }
      result
    end
  end

  def teardown
    @captured_methods.each do |sym, m|
      Parse::AtlasSearch.define_singleton_method(sym, m)
    end
    Parse::AtlasSearch.reset!
  end

  def agent_with(session_token: nil, master_atlas: false)
    Parse::Agent.suppress_master_key_warning = true
    Parse::Agent.new(session_token: session_token, master_atlas: master_atlas)
  ensure
    Parse::Agent.suppress_master_key_warning = false
  end

  def test_master_key_agent_forwards_master_true
    # The previous policy refused atlas_text_search on master-key agents
    # that didn't also opt into master_atlas: true. That per-tool refusal
    # was removed because the SDK now enforces ACL uniformly on the
    # mongo-direct path via Parse::ACLScope; master-key posture is the
    # deliberate consequence of constructing without any identity input,
    # signaled at construction with the master-key banner. The call now
    # forwards `master: true` (from agent.acl_scope_kwargs) so Atlas
    # runs without per-row ACL filtering — same as the agent's other
    # tools.
    agent = agent_with(session_token: nil, master_atlas: false)
    Parse::Agent::Tools.atlas_text_search(agent, class_name: "Song", query: "love")
    capture = @captures.first
    assert_equal :search, capture[:op]
    assert_equal true, capture[:opts][:master]
  end

  def test_session_bound_agent_forwards_session_token
    agent = agent_with(session_token: "tok-1")
    Parse::Agent::Tools.atlas_text_search(agent, class_name: "Song", query: "love")
    capture = @captures.first
    assert_equal :search, capture[:op]
    assert_equal "tok-1", capture[:opts][:session_token]
    refute capture[:opts].key?(:master)
  end

  def test_master_atlas_agent_forwards_master_true
    # master_atlas: true still surfaces as `master: true` on the Atlas
    # call because acl_scope_kwargs returns {master: true} when no
    # identity input is present (master_atlas itself doesn't carry
    # identity — it's a per-class gate retained for faceted_search).
    agent = agent_with(master_atlas: true)
    Parse::Agent::Tools.atlas_text_search(agent, class_name: "Song", query: "love")
    capture = @captures.first
    assert_equal true, capture[:opts][:master]
    refute capture[:opts].key?(:session_token)
  end

  def test_limit_is_clamped_to_max
    agent = agent_with(master_atlas: true)
    Parse::Agent::Tools.atlas_text_search(agent, class_name: "Song", query: "love", limit: 9999)
    assert_equal Parse::Agent::Tools::ATLAS_LIMIT_MAX, @captures.first[:opts][:limit]
  end

  def test_limit_default_when_missing
    agent = agent_with(master_atlas: true)
    Parse::Agent::Tools.atlas_text_search(agent, class_name: "Song", query: "love")
    assert_equal Parse::Agent::Tools::ATLAS_LIMIT_DEFAULT, @captures.first[:opts][:limit]
  end

  def test_empty_query_is_refused
    agent = agent_with(master_atlas: true)
    assert_raises(Parse::Agent::ValidationError) do
      Parse::Agent::Tools.atlas_text_search(agent, class_name: "Song", query: "")
    end
    assert_raises(Parse::Agent::ValidationError) do
      Parse::Agent::Tools.atlas_text_search(agent, class_name: "Song", query: "   ")
    end
  end

  def test_atlas_text_search_field_outside_allowlist_refused
    define_class(:AclFieldsClass, parse_name: "AclFieldsClass") do
      property :title
      property :lyrics
      agent_fields :title  # lyrics is OUT
    end

    agent = agent_with(master_atlas: true)
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.atlas_text_search(
        agent, class_name: "AclFieldsClass", query: "love",
        fields: ["title", "lyrics"]
      )
    end
  ensure
    Object.send(:remove_const, :AclFieldsClass) if Object.const_defined?(:AclFieldsClass)
  end

  def test_atlas_autocomplete_field_outside_allowlist_refused
    define_class(:AclAutoClass, parse_name: "AclAutoClass") do
      property :title
      property :secret
      agent_fields :title
    end
    agent = agent_with(master_atlas: true)
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.atlas_autocomplete(
        agent, class_name: "AclAutoClass", query: "se", field: "secret"
      )
    end
  ensure
    Object.send(:remove_const, :AclAutoClass) if Object.const_defined?(:AclAutoClass)
  end

  def test_faceted_search_requires_master_atlas_even_with_session_token
    # The bucket-count ACL gap means session-bound agents must NOT
    # be able to call this tool. Library-level FacetedSearchNotACLSafe
    # already enforces this at the AtlasSearch layer, but the agent
    # layer refuses earlier with a friendlier message.
    agent = agent_with(session_token: "tok-1", master_atlas: false)
    assert_raises(Parse::Agent::ValidationError) do
      Parse::Agent::Tools.atlas_faceted_search(
        agent, class_name: "Song",
        facets: { genre: { type: :string, path: :genre } }
      )
    end
  end

  def test_faceted_search_accepts_master_atlas
    agent = agent_with(master_atlas: true)
    Parse::Agent::Tools.atlas_faceted_search(
      agent, class_name: "Song",
      facets: { genre: { type: :string, path: :genre } }
    )
    assert_equal :faceted_search, @captures.first[:op]
    assert_equal true, @captures.first[:opts][:master]
  end

  def test_faceted_search_facet_path_outside_allowlist_refused
    define_class(:AclFacetClass, parse_name: "AclFacetClass") do
      property :title
      property :secret
      agent_fields :title
    end
    agent = agent_with(master_atlas: true)
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.atlas_faceted_search(
        agent, class_name: "AclFacetClass",
        facets: { sec: { type: :string, path: :secret } }
      )
    end
  ensure
    Object.send(:remove_const, :AclFacetClass) if Object.const_defined?(:AclFacetClass)
  end

  def test_inaccessible_class_refused_before_search
    define_class(:AclHiddenClass, parse_name: "AclHiddenClass") do
      property :title
      agent_hidden
    end
    agent = agent_with(session_token: "tok-1")
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.atlas_text_search(agent, class_name: "AclHiddenClass", query: "love")
    end
    assert_empty @captures, "search must NOT have been issued when class is hidden"
  ensure
    Object.send(:remove_const, :AclHiddenClass) if Object.const_defined?(:AclHiddenClass)
    Parse::Agent::MetadataRegistry.send(:reset!) if Parse::Agent::MetadataRegistry.respond_to?(:reset!)
  end

  def test_master_atlas_predicate_default_false
    agent = agent_with
    refute_predicate agent, :master_atlas?
  end

  def test_master_atlas_predicate_true_when_set
    agent = agent_with(master_atlas: true)
    assert_predicate agent, :master_atlas?
  end

  private

  # @!visibility private
  # ActiveModel::Naming reads `Class.name` when `parse_class` is
  # declared, and an anonymous Class.new(Parse::Object) has `name` =
  # nil. Workaround: const_set FIRST (so the class has a real name),
  # then evaluate the body which calls `parse_class`. Cleaning up the
  # const in the test's ensure block keeps the global namespace clean.
  def define_class(const_name, parse_name:, &body)
    Object.send(:remove_const, const_name) if Object.const_defined?(const_name)
    klass = Class.new(Parse::Object)
    Object.const_set(const_name, klass)
    klass.parse_class parse_name
    klass.class_eval(&body) if body
    klass
  end
end
