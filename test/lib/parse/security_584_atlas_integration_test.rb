# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../support/test_server"
require "json"
require "securerandom"
require "parse/mongodb"
require "parse/atlas_search"
require "parse/vector_search"

# Live Atlas Local coverage for the 5.8.4 security patch. Each behavior is
# checked both ways: an authorized search that returns rows, and a refused
# search that raises the documented error before any pipeline runs.
#
# Needs Atlas Local (scripts/docker/docker-compose.atlas.yml) with the seeded
# `Song` collection and its dynamic `default` index. The vector checks need
# the `vector_prototype.Movie` fixture (scripts/vector_prototype/run.sh). The
# session-scoped checks also need the Parse Server test stack, which resolves
# the session token and serves the class schema.
#
# Run:
#   ATLAS_URI="mongodb://localhost:29020/parse_atlas_test?directConnection=true" \
#     PARSE_TEST_USE_DOCKER=true bundle exec ruby -Ilib:test \
#     test/lib/parse/security_584_atlas_integration_test.rb
class Security584AtlasIntegrationTest < Minitest::Test
  ATLAS_URI = ENV["ATLAS_URI"] || "mongodb://localhost:29020/parse_atlas_test?directConnection=true"
  VECTOR_MANIFEST = File.expand_path("../../../../scripts/vector_prototype/fixture_manifest.json", __FILE__)

  def self.atlas_available?
    return @atlas_available if defined?(@atlas_available)
    @atlas_available = begin
        require "mongo"
        client = Mongo::Client.new(ATLAS_URI, server_selection_timeout: 15, connect_timeout: 5,
                                              socket_timeout: 15, logger: Logger.new(IO::NULL))
        n = client["Song"].count_documents({})
        client.close
        n.to_i > 0
      rescue StandardError => e
        warn "[Security584AtlasIntegrationTest] Atlas probe failed: #{e.class}: #{e.message}"
        false
      end
  end

  def self.vector_manifest
    return @vector_manifest if defined?(@vector_manifest)
    @vector_manifest = File.exist?(VECTOR_MANIFEST) ? JSON.parse(File.read(VECTOR_MANIFEST)) : nil
  end

  def setup
    unless self.class.atlas_available?
      skip "Atlas Search not reachable at #{ATLAS_URI}. Start it with " \
           "`docker-compose -f scripts/docker/docker-compose.atlas.yml up -d` or override ATLAS_URI."
    end
    Parse::CLPScope.reset_cache!
    configure_atlas!(ATLAS_URI)
  end

  def teardown
    @users&.each { |u| u.destroy rescue nil }
    Parse::AtlasSearch.reset!
    Parse::MongoDB.reset!
    Parse::CLPScope.reset_cache!
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  def configure_atlas!(uri)
    Parse::MongoDB.reset!
    Parse::MongoDB.configure(uri: uri, enabled: true, verify_role: false)
    Parse::AtlasSearch.configure(enabled: true, default_index: "default")
  end

  # The session-scoped checks resolve the token against Parse Server.
  def session_user!
    unless ENV["PARSE_TEST_USE_DOCKER"] == "true" && Parse::Test::ServerHelper.setup
      skip "Session-scoped Atlas checks need the Parse Server test stack (PARSE_TEST_USE_DOCKER=true)"
    end
    user = Parse::Test::ServerHelper.create_test_user(username: "sec584atlas_#{SecureRandom.hex(4)}")
    (@users ||= []) << user
    assert user.session_token.present?, "test user must carry a session token"
    user
  end

  # Make sure Parse Server has a `Song` schema whose CLP permits a public
  # find, so the authorized session search has a resolvable schema.
  def ensure_song_schema!
    response = Parse.client.schema("Song")
    return if response.success?
    schema = { "className" => "Song", "fields" => { "title" => { "type" => "String" } } }
    assert Parse.client.create_schema("Song", schema).success?, "could not create Song schema"
    Parse::CLPScope.reset_cache!
  end

  def stage(body)
    { "$search" => { "index" => "default" }.merge(body) }
  end

  def vector_ready!
    m = self.class.vector_manifest
    skip "No vector fixture manifest; run scripts/vector_prototype/run.sh against Atlas" unless m
    uri = ATLAS_URI.sub(%r{/[^/?]+(\?|\z)}, "/#{m["db"]}\\1")
    configure_atlas!(uri)
    n = Parse::MongoDB.client[m["collection"]].count_documents({})
    skip "Atlas vector fixture #{m["db"]}.#{m["collection"]} is empty; run scripts/vector_prototype/run.sh" unless n.to_i > 0
    m
  end

  # ------------------------------------------------------------------
  # Internal columns refused as Atlas Search paths, even for master
  # ------------------------------------------------------------------

  def test_internal_column_paths_refused_for_master_and_normal_search_returns_rows
    ok = Parse::AtlasSearch.search_with_stage("Song", stage("text" => { "query" => "love", "path" => { "wildcard" => "*" } }), master: true)
    assert ok.count > 0, "a normal wildcard text search must return seeded Song rows"

    refused_stages = [
      stage("wildcard" => { "query" => "a*", "path" => "_perishable_token", "allowAnalyzedField" => true }),
      stage("wildcard" => { "query" => "a*", "path" => { "wildcard" => "_perishable_tok*" }, "allowAnalyzedField" => true }),
      stage("regex" => { "query" => "a.*", "path" => "_hashed_password", "allowAnalyzedField" => true }),
      stage("queryString" => { "defaultPath" => "title", "query" => "_perishable_token:a*" }),
    ]
    refused_stages.each do |st|
      assert_raises(Parse::CLPScope::Denied, "expected Denied for #{st.inspect}") do
        Parse::AtlasSearch.search_with_stage("Song", st, master: true)
      end
    end

    # A glob that starts with a wildcard can match ordinary fields, so it is
    # refused only on the classes that store credential columns.
    star_token = stage("wildcard" => { "query" => "a*", "path" => { "wildcard" => "*token" }, "allowAnalyzedField" => true })
    assert_raises(Parse::CLPScope::Denied) do
      Parse::AtlasSearch.search_with_stage("_User", star_token, master: true)
    end
  end

  def test_internal_column_sort_and_highlight_refused_for_master
    ok = Parse::AtlasSearch.search("Song", "love", master: true)
    assert ok.count > 0

    assert_raises(Parse::CLPScope::Denied) do
      Parse::AtlasSearch.search("Song", "love", fields: ["_session_token"], master: true)
    end
    assert_raises(Parse::CLPScope::Denied) do
      Parse::AtlasSearch.search("Song", "love", highlight_field: "_perishable_token", master: true)
    end
  end

  # ------------------------------------------------------------------
  # Vector search on the loaded fixture
  # ------------------------------------------------------------------

  def test_vector_search_master_returns_rows_and_unschemed_session_denied
    m = vector_ready!
    seed = Parse::MongoDB.client[m["collection"]].find({}).limit(1).first
    rows = Parse::VectorSearch.search(m["collection"], field: :embedding, query_vector: seed["embedding"],
                                                       k: 3, index: m["index_name"], master: true)
    assert_equal 3, rows.size
    assert_equal seed["_id"], rows.first["_id"], "self-similarity top hit must be the seed document"

    # Parse Server has no schema for the fixture class, so a session scope
    # must fail closed instead of returning unscoped neighbors.
    user = session_user!
    Parse::CLPScope.reset_cache!
    assert_raises(Parse::CLPScope::Denied) do
      Parse::VectorSearch.search(m["collection"], field: :embedding, query_vector: seed["embedding"],
                                                  k: 3, index: m["index_name"], session_token: user.session_token)
    end
  end

  # ------------------------------------------------------------------
  # Session-scoped search: missing schema fails closed
  # ------------------------------------------------------------------

  def test_session_search_with_schema_returns_rows_and_missing_schema_denied
    user = session_user!
    ensure_song_schema!

    rows = Parse::AtlasSearch.search("Song", "love", session_token: user.session_token)
    assert rows.count > 0, "session search on a class with a public-find schema must return rows"

    unschemed = "Sec584Unschemed#{SecureRandom.hex(3)}"
    assert_raises(Parse::CLPScope::Denied) do
      Parse::AtlasSearch.search(unschemed, "love", session_token: user.session_token)
    end
    assert_raises(Parse::CLPScope::Denied) do
      Parse::AtlasSearch.search_with_stage(unschemed, stage("text" => { "query" => "love", "path" => "title" }),
                                           session_token: user.session_token)
    end
  end

  def test_faceted_search_master_returns_buckets_and_session_refused
    facets = { genre: { type: :string, path: :genre } }
    result = Parse::AtlasSearch.faceted_search("Song", "love", facets, master: true)
    assert result.results.size > 0, "master faceted search must return matching Song rows"
    buckets = Array(result.facets[:genre])
    assert buckets.sum { |b| b[:count].to_i } > 0, "master faceted search must return genre buckets"

    user = session_user!
    assert_raises(Parse::AtlasSearch::FacetedSearchNotACLSafe) do
      Parse::AtlasSearch.faceted_search("Song", "love", facets, session_token: user.session_token)
    end
  end
end
