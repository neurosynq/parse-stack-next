# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/mongodb"
require "parse/atlas_search"

# Integration tests for Parse::AtlasSearch module.
# Requires Docker with mongodb/mongodb-atlas-local running.
#
# Setup (Docker - recommended):
#   docker-compose -f scripts/docker/docker-compose.atlas.yml up -d
#   # Wait for initialization to complete (~30 seconds)
#   docker-compose -f scripts/docker/docker-compose.atlas.yml logs -f atlas-init
#
# Run:
#   ATLAS_URI="mongodb://localhost:27020/parse_atlas_test?directConnection=true" ruby -Ilib:test test/lib/parse/atlas_search_integration_test.rb
#
# Alternative Setup (Atlas CLI):
#   atlas deployments setup local-atlas --type local
#   ATLAS_URI="mongodb://localhost:51973/parse_atlas_test?directConnection=true" ruby -Ilib:test test/lib/parse/atlas_search_integration_test.rb
#
# NOTE on Apple Silicon (ARM64) flakiness: mongodb-atlas-local's internal
# mongot (Lucene-based search engine) is unstable under sustained load on
# ARM64. The supervisor restarts mongod when mongot crashes, producing
# 5-10s outage windows. The `atlas_available?` probe below uses 15s
# timeouts × 3 attempts to bridge restart cycles. See
# atlas_search_mutations_integration_test.rb's header for a full writeup.
#
class AtlasSearchIntegrationTest < Minitest::Test
  # Default to Docker Atlas Local port (27020), can override with ATLAS_URI env var
  ATLAS_URI = ENV["ATLAS_URI"] || "mongodb://localhost:27020/parse_atlas_test?directConnection=true"

  # Class methods on Parse::AtlasSearch that the per-test wrapper baseline
  # below force-defaults `master: true` onto. The test suite predates the
  # 4.4.0 CLP-enforcement layer and runs against a fresh Atlas Local
  # container with no Parse Server / auth wiring — every search must run
  # in master scope or CLP refuses the underlying `Parse::MongoDB.aggregate`.
  SCOPED_SEARCH_METHODS = %i[search autocomplete faceted_search].freeze

  def setup
    unless self.class.atlas_available?
      skip "Atlas Search not reachable at #{ATLAS_URI}. Start it with " \
           "`docker-compose -f scripts/docker/docker-compose.atlas.yml up -d` " \
           "or override ATLAS_URI."
    end

    Parse::MongoDB.configure(uri: ATLAS_URI, enabled: true, verify_role: false)
    Parse::AtlasSearch.configure(enabled: true, default_index: "default")
    # allow_raw defaults to false in production — `raw: true` is then
    # silently ignored and results are converted to Parse-format
    # objects. This suite predates that opt-in and several tests
    # (`test_search_raw_mode`, `test_search_with_fields`,
    # `test_search_with_highlights`) assert against the raw Hash shape.
    Parse::AtlasSearch.allow_raw = true
    install_master_scope_wrappers!
  end

  def teardown
    uninstall_master_scope_wrappers!
    Parse::AtlasSearch.reset!
    Parse::MongoDB.reset!
  end

  # Wrap each Parse::AtlasSearch class method so calls without an
  # explicit scope (master:/session_token:/acl_user:/acl_role:) default
  # to `master: true`. Aliases the original under `__test_orig_<meth>`
  # so teardown can restore the production method.
  def install_master_scope_wrappers!
    sc = Parse::AtlasSearch.singleton_class
    SCOPED_SEARCH_METHODS.each do |meth|
      orig = "__test_orig_#{meth}".to_sym
      next if sc.method_defined?(orig)
      sc.send(:alias_method, orig, meth)
      sc.send(:remove_method, meth)
      Parse::AtlasSearch.define_singleton_method(meth) do |*args, **opts, &blk|
        unless opts.key?(:master) || opts.key?(:session_token) ||
               opts.key?(:acl_user) || opts.key?(:acl_role)
          opts[:master] = true
        end
        send(orig, *args, **opts, &blk)
      end
    end
  end

  def uninstall_master_scope_wrappers!
    sc = Parse::AtlasSearch.singleton_class
    SCOPED_SEARCH_METHODS.each do |meth|
      orig = "__test_orig_#{meth}".to_sym
      next unless sc.method_defined?(orig)
      sc.send(:remove_method, meth) if sc.method_defined?(meth)
      sc.send(:alias_method, meth, orig)
      sc.send(:remove_method, orig)
    end
  end

  #----------------------------------------------------------------
  # INDEX MANAGEMENT TESTS
  #----------------------------------------------------------------

  def test_list_indexes
    indexes = Parse::AtlasSearch.indexes("Song")
    assert indexes.is_a?(Array), "indexes should be an array"
    refute indexes.empty?, "should have at least one index"

    default_index = indexes.find { |idx| idx["name"] == "default" }
    assert default_index, "should have a 'default' index"
    assert_equal true, default_index["queryable"], "default index should be queryable"
  end

  def test_index_ready
    assert Parse::AtlasSearch.index_ready?("Song", "default"), "default index should be ready"
    refute Parse::AtlasSearch.index_ready?("Song", "nonexistent"), "nonexistent index should not be ready"
  end

  def test_index_manager_list_indexes
    indexes = Parse::AtlasSearch::IndexManager.list_indexes("Song")
    assert indexes.is_a?(Array)

    # Should be cached now
    cached = Parse::AtlasSearch::IndexManager.list_indexes("Song")
    assert_equal indexes, cached
  end

  #----------------------------------------------------------------
  # FULL-TEXT SEARCH TESTS
  #----------------------------------------------------------------

  def test_basic_search
    result = Parse::AtlasSearch.search("Song", "love")

    assert result.is_a?(Parse::AtlasSearch::SearchResult)
    refute result.empty?, "should find songs with 'love'"
    # Note: With dynamic mapping, may find fewer matches
    assert result.count >= 1, "should find at least 1 song with 'love'"
  end

  def test_search_with_fields
    # Use raw mode since we don't have a Song model defined
    result = Parse::AtlasSearch.search("Song", "Taylor", fields: [:artist], raw: true)

    refute result.empty?, "should find Taylor Swift song"
    assert result.results.any? { |r| r["artist"] == "Taylor Swift" }
  end

  def test_search_with_limit
    result = Parse::AtlasSearch.search("Song", "love", limit: 2)

    assert_equal 2, result.count, "should limit to 2 results"
  end

  def test_search_returns_scores
    result = Parse::AtlasSearch.search("Song", "love")

    refute result.empty?
    # Results should have scores attached - either via method or hash key
    first = result.first
    score = if first.respond_to?(:search_score)
        first.search_score
      elsif first.is_a?(Hash)
        first["_score"] || first[:_score]
      end
    assert score.is_a?(Numeric), "search_score should be numeric (got #{score.class})"
    assert score > 0, "search_score should be positive"
  end

  def test_search_raw_mode
    result = Parse::AtlasSearch.search("Song", "love", raw: true)

    refute result.empty?
    assert result.first.is_a?(Hash), "raw mode should return hashes"
    assert result.first.key?("_score"), "raw results should have _score"
  end

  #----------------------------------------------------------------
  # SEARCH BUILDER TESTS
  #----------------------------------------------------------------

  def test_search_with_builder_text
    builder = Parse::AtlasSearch::SearchBuilder.new(index_name: "default")
    builder.text(query: "love", path: :title)

    pipeline = [builder.build]
    pipeline << { "$addFields" => { "_score" => { "$meta" => "searchScore" } } }
    pipeline << { "$limit" => 10 }

    results = Parse::MongoDB.aggregate("Song", pipeline, master: true)
    refute results.empty?, "should find results with builder"
  end

  def test_search_with_builder_phrase
    builder = Parse::AtlasSearch::SearchBuilder.new
    builder.phrase(query: "Rock and Roll", path: :title)

    pipeline = [builder.build]
    pipeline << { "$limit" => 10 }

    results = Parse::MongoDB.aggregate("Song", pipeline, master: true)
    assert results.any? { |r| r["title"] == "Rock and Roll" }, "should find 'Rock and Roll' with phrase search"
  end

  #----------------------------------------------------------------
  # AUTOCOMPLETE TESTS
  #----------------------------------------------------------------

  def test_autocomplete_basic
    result = Parse::AtlasSearch.autocomplete("Song", "Lov", field: :title)

    assert result.is_a?(Parse::AtlasSearch::AutocompleteResult)
    refute result.suggestions.empty?, "should find suggestions starting with 'Lov'"
    # Should find "Love Story" and/or "Lovely Day"
    assert result.suggestions.any? { |s| s.start_with?("Lov") }, "suggestions should start with 'Lov'"
  end

  #----------------------------------------------------------------
  # FACETED SEARCH TESTS
  #----------------------------------------------------------------

  def test_faceted_search_basic
    facets = {
      genre: { type: :string, path: :genre, num_buckets: 10 },
    }

    result = Parse::AtlasSearch.faceted_search("Song", "love", facets, limit: 5)

    assert result.is_a?(Parse::AtlasSearch::FacetedResult)
    assert result.facets.is_a?(Hash)

    # Should have genre facet
    if result.facets[:genre]
      assert result.facets[:genre].is_a?(Array)
      result.facets[:genre].each do |bucket|
        assert bucket.key?(:value)
        assert bucket.key?(:count)
      end
    end
  end

  def test_faceted_search_with_total_count
    facets = {
      genre: { type: :string, path: :genre },
    }

    result = Parse::AtlasSearch.faceted_search("Song", "love", facets)

    assert result.respond_to?(:total_count)
    assert result.total_count >= 0
  end

  #----------------------------------------------------------------
  # HIGHLIGHT TESTS
  #----------------------------------------------------------------

  def test_search_with_highlights
    result = Parse::AtlasSearch.search("Song", "love", highlight_field: :title, raw: true)

    refute result.empty?, "should find songs with 'love'"
    # Raw results should have _highlights field when highlight is requested
    first_with_highlights = result.raw_results.find { |r| r["_highlights"] }
    if first_with_highlights
      assert first_with_highlights["_highlights"].is_a?(Array), "_highlights should be an array"
    end
  end

  #----------------------------------------------------------------
  # PAGINATION TESTS
  #----------------------------------------------------------------

  def test_search_with_skip
    # Get first 5 results
    first_page = Parse::AtlasSearch.search("Song", "love", limit: 5, raw: true)

    # Get results with skip
    second_page = Parse::AtlasSearch.search("Song", "love", limit: 5, skip: 5, raw: true)

    # If we have enough results, verify skip is working
    if first_page.count >= 5 && second_page.count > 0
      first_ids = first_page.results.map { |r| r["_id"] || r["objectId"] }
      second_ids = second_page.results.map { |r| r["_id"] || r["objectId"] }

      # No overlap between pages
      overlap = first_ids & second_ids
      assert_empty overlap, "skip should produce non-overlapping results"
    end
  end

  def test_search_skip_zero_same_as_no_skip
    without_skip = Parse::AtlasSearch.search("Song", "love", limit: 3, raw: true)
    with_skip_zero = Parse::AtlasSearch.search("Song", "love", limit: 3, skip: 0, raw: true)

    # Should have same results
    assert_equal without_skip.count, with_skip_zero.count
  end

  #----------------------------------------------------------------
  # FUZZY SEARCH TESTS
  #----------------------------------------------------------------

  def test_search_with_fuzzy_matching
    # Search with a typo - "lvoe" instead of "love"
    result = Parse::AtlasSearch.search("Song", "lvoe", fuzzy: true, limit: 10)

    # Fuzzy should find results despite the typo
    # Note: This depends on the test data having songs with "love"
    assert result.is_a?(Parse::AtlasSearch::SearchResult)
    # With fuzzy enabled, we should find results
    if result.count > 0
      # Verify the results contain songs (fuzzy matched)
      assert result.first
    end
  end

  def test_search_without_fuzzy_stricter
    # Search with exact text
    exact_result = Parse::AtlasSearch.search("Song", "love", fuzzy: false, limit: 20)
    # Search with typo without fuzzy
    typo_result = Parse::AtlasSearch.search("Song", "lvoe", fuzzy: false, limit: 20)

    # Exact search should find more/same results than typo search without fuzzy
    assert exact_result.count >= typo_result.count,
      "exact search should find at least as many results as typo without fuzzy"
  end

  #----------------------------------------------------------------
  # FILTER TESTS
  #----------------------------------------------------------------

  def test_search_with_filter
    # Search with a filter constraint
    result = Parse::AtlasSearch.search("Song", "love",
                                       filter: { "genre" => "Pop" },
                                       limit: 10,
                                       raw: true)

    assert result.is_a?(Parse::AtlasSearch::SearchResult)
    # If we have results with the filter, they should match the genre
    result.results.each do |song|
      if song["genre"]
        assert_equal "Pop", song["genre"], "filtered results should match genre"
      end
    end
  end

  def test_search_with_numeric_filter
    # Search with a numeric filter using MongoDB operators
    result = Parse::AtlasSearch.search("Song", "love",
                                       filter: { "plays" => { "$gte" => 0 } },
                                       limit: 10,
                                       raw: true)

    assert result.is_a?(Parse::AtlasSearch::SearchResult)
  end

  #----------------------------------------------------------------
  # INDEX MANAGER INTEGRATION TESTS
  #----------------------------------------------------------------

  def test_index_manager_index_exists
    assert Parse::AtlasSearch::IndexManager.index_exists?("Song", "default"),
      "default index should exist"
    refute Parse::AtlasSearch::IndexManager.index_exists?("Song", "nonexistent_index_12345"),
      "nonexistent index should not exist"
  end

  def test_index_manager_get_index
    index = Parse::AtlasSearch::IndexManager.get_index("Song", "default")

    assert index.is_a?(Hash), "should return index hash"
    assert_equal "default", index["name"]
  end

  def test_index_manager_get_index_nonexistent
    index = Parse::AtlasSearch::IndexManager.get_index("Song", "nonexistent_12345")

    assert_nil index, "should return nil for nonexistent index"
  end

  def test_index_manager_validate_index_raises_for_missing
    assert_raises(Parse::AtlasSearch::IndexNotFound) do
      Parse::AtlasSearch::IndexManager.validate_index!("Song", "definitely_not_an_index")
    end
  end

  def test_index_manager_validate_index_passes_for_existing
    # Should not raise
    Parse::AtlasSearch::IndexManager.validate_index!("Song", "default")
  end

  def test_index_manager_force_refresh
    # First call caches
    indexes1 = Parse::AtlasSearch::IndexManager.list_indexes("Song")

    # Force refresh should still return valid results
    indexes2 = Parse::AtlasSearch::IndexManager.list_indexes("Song", force_refresh: true)

    assert indexes1.is_a?(Array)
    assert indexes2.is_a?(Array)
    assert_equal indexes1.map { |i| i["name"] }.sort, indexes2.map { |i| i["name"] }.sort
  end

  #----------------------------------------------------------------
  # AUTOCOMPLETE ADVANCED TESTS
  #----------------------------------------------------------------

  def test_autocomplete_with_fuzzy
    result = Parse::AtlasSearch.autocomplete("Song", "Lvoe", field: :title, fuzzy: true)

    assert result.is_a?(Parse::AtlasSearch::AutocompleteResult)
    # Fuzzy autocomplete should be more forgiving of typos
  end

  def test_autocomplete_with_limit
    result = Parse::AtlasSearch.autocomplete("Song", "L", field: :title, limit: 3)

    assert result.suggestions.length <= 3, "should respect limit"
  end

  #----------------------------------------------------------------
  # MULTIPLE FIELD SEARCH TESTS
  #----------------------------------------------------------------

  def test_search_multiple_fields
    result = Parse::AtlasSearch.search("Song", "love",
                                       fields: [:title, :artist, :genre],
                                       limit: 10)

    assert result.is_a?(Parse::AtlasSearch::SearchResult)
    # Should search across all specified fields
  end

  #----------------------------------------------------------------
  # ERROR HANDLING TESTS
  #----------------------------------------------------------------

  def test_search_empty_query_raises
    assert_raises(Parse::AtlasSearch::InvalidSearchParameters) do
      Parse::AtlasSearch.search("Song", "")
    end
  end

  def test_autocomplete_missing_field_raises
    assert_raises(Parse::AtlasSearch::InvalidSearchParameters) do
      Parse::AtlasSearch.autocomplete("Song", "test", field: nil)
    end
  end

  def test_autocomplete_empty_query_raises
    assert_raises(Parse::AtlasSearch::InvalidSearchParameters) do
      Parse::AtlasSearch.autocomplete("Song", "", field: :title)
    end
  end

  def test_autocomplete_whitespace_query_raises
    assert_raises(Parse::AtlasSearch::InvalidSearchParameters) do
      Parse::AtlasSearch.autocomplete("Song", "   ", field: :title)
    end
  end

  private

  # Memoized at the class level so 50 tests don't each pay the probe timeout
  # when Atlas isn't running. The probe must bridge mongodb-atlas-local's
  # periodic internal mongod restarts — the image's supervisor cycles
  # mongod on replica-set sync events, producing 5-10s outage windows where
  # any connection sees Connection refused. The 15s server-selection
  # timeout per attempt + up to 3 attempts with 5s sleep between covers a
  # single restart cycle without skipping the whole suite.
  def self.atlas_available?
    return @atlas_available if defined?(@atlas_available)
    @atlas_available = probe_atlas_with_retries
  end

  def self.probe_atlas_with_retries(attempts: 3, sleep_between: 5)
    require "mongo"
    last_error = nil
    attempts.times do |i|
      begin
        client = Mongo::Client.new(
          ATLAS_URI,
          server_selection_timeout: 15,
          connect_timeout: 5,
          socket_timeout: 10,
          logger: Logger.new(IO::NULL),
        )
        # `$listSearchIndexes` is the discriminator: any MongoDB will answer
        # `collection_names`, but only an Atlas-Search-capable deployment
        # accepts this pipeline stage.
        client.database["Song"].aggregate([{ "$listSearchIndexes" => {} }]).first
        client.close
        return true
      rescue => e
        last_error = e
        client&.close rescue nil
        sleep sleep_between if i < attempts - 1
      end
    end
    warn "[AtlasSearchIntegrationTest] Atlas Search probe failed at #{ATLAS_URI} " \
         "after #{attempts} attempts: #{last_error.class}: #{last_error.message}"
    false
  end

  # Helper to get field from either Hash or Parse::Object
  def get_field(obj, field)
    if obj.is_a?(Hash)
      obj[field] || obj[field.to_s] || obj[field.to_sym]
    elsif obj.respond_to?(field)
      obj.send(field)
    elsif obj.respond_to?(:[])
      obj[field]
    end
  end
end
