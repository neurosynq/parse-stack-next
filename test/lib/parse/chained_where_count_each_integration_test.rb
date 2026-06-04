require_relative "../../test_helper_integration"

class CWWorkspace < Parse::Object
  parse_class "CWWorkspace"
  property :name, :string
end

class CWPost < Parse::Object
  parse_class "CWPost"
  property :title, :string
  property :approved, :boolean
  property :rejected, :boolean
  property :archived, :boolean
  property :draft, :boolean
  property :published, :boolean
  belongs_to :author_workspace, as: :cw_workspace
end

class ChainedWhereCountEachIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def seed!
    @workspace_a = create_test_object("CWWorkspace", name: "Alpha")
    @workspace_b = create_test_object("CWWorkspace", name: "Bravo")

    # 5 candidates for workspace A, 3 candidates for workspace B, plus 2 that
    # should be excluded by the base filters regardless of workspace
    5.times do |i|
      create_test_object("CWPost",
        title: "A#{i}",
        published: true,
        approved: false, rejected: false, archived: false, draft: false,
        author_workspace: @workspace_a,
      )
    end

    3.times do |i|
      create_test_object("CWPost",
        title: "B#{i}",
        published: true,
        approved: false, rejected: false, archived: false, draft: false,
        author_workspace: @workspace_b,
      )
    end

    create_test_object("CWPost", title: "approved", published: true,
                                    approved: true, rejected: false, archived: false, draft: false,
                                    author_workspace: @workspace_a)
    create_test_object("CWPost", title: "draft", published: true,
                                    approved: false, rejected: false, archived: false, draft: true,
                                    author_workspace: @workspace_b)
  end

  def base_query
    CWPost.query(
      :approved.ne => true,
      :rejected.ne => true,
      :archived.ne => true,
      :draft.ne => true,
      :published => true,
    )
  end

  def test_chained_where_is_honored_by_count_and_each
    skip "needs PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      seed!

      # 1) Baseline: no workspace filter -> 8 candidates (5 A + 3 B)
      q = base_query
      baseline_count = q.count
      assert_equal 8, baseline_count, "baseline candidate count without workspace filter"

      # 2) Chain on a workspace filter via .where AFTER construction; count must drop
      q.where(author_workspace: @workspace_a)

      compiled_where = q.compile[:where]
      assert_includes compiled_where, "authorWorkspace",
                      "chained where(author_workspace:) should appear in compiled query"

      filtered_count = q.count
      assert_equal 5, filtered_count,
                   "count must reflect the chained workspace filter (got #{filtered_count})"

      # 3) each_with_index must iterate only the filtered set
      seen_ids = []
      q.each_with_index do |post, _idx|
        seen_ids << post.id
        assert_equal @workspace_a.id, post.author_workspace.id,
                     "each_with_index yielded a post from the wrong workspace"
      end
      assert_equal 5, seen_ids.size,
                   "each_with_index iterated #{seen_ids.size} posts, expected 5"
      assert_equal seen_ids.uniq.size, seen_ids.size, "each_with_index yielded duplicates"
    end
  end

  def test_count_recomputes_after_additional_where
    skip "needs PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      seed!

      q = base_query
      assert_equal 8, q.count

      q.where(author_workspace: @workspace_a)
      assert_equal 5, q.count, "count after first chained where"

      # Tighten further with a non-matching filter; should drop to 0
      q.where(title: "no-such-title")
      assert_equal 0, q.count, "count after second chained where"
    end
  end

  def test_chained_where_honored_even_when_client_cache_enabled
    skip "needs PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      seed!

      q = base_query
      q.cache = true # opt the query into the HTTP cache path

      assert_equal 8, q.count
      q.where(author_workspace: @workspace_b)
      assert_equal 3, q.count,
                   "count with cache=true must still drop after chained workspace filter"
    end
  end

  # Now actually wire up the Moneta-backed caching middleware on the client and
  # repeat the scenario. This is the case that would bite a real app: the
  # default Parse::Client has `Parse::Middleware::Caching` installed with a
  # shared Moneta store + non-zero TTL, and queries opt in via `cache: true`.
  def test_chained_where_honored_with_real_caching_middleware
    skip "needs PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    require "moneta"

    with_parse_server do
      seed!

      # Rebuild the default client with caching middleware. Parse::Query
      # (via Connectable) memoizes a client reference on its class, so we
      # have to clear that AND any per-instance reference after swapping the
      # default — otherwise queries keep talking to the uncached client and
      # the test silently exercises nothing.
      cache_store = Moneta.new(:Memory, expires: true)
      Parse::Client.setup(
        server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse",
        app_id: ENV["PARSE_TEST_APP_ID"] || "psnextItAppId",
        api_key: ENV["PARSE_TEST_API_KEY"] || "psnext-it-rest-key",
        master_key: ENV["PARSE_TEST_MASTER_KEY"] || "psnextItMasterKey",
        cache: cache_store,
        expires: 60,
      )
      [Parse::Query, Parse::Object].each do |k|
        k.instance_variable_set(:@client, nil) if k.instance_variable_defined?(:@client)
      end

      cached_keys = ->() {
        adp = cache_store
        adp = adp.adapter while adp.respond_to?(:adapter)
        adp.instance_variable_get(:@backend).keys
      }

      begin
        q = base_query
        q.cache = true # opt this query into the cache path

        # 1) Prime the cache with the unfiltered count
        assert_equal 8, q.count, "primed baseline count"

        # 2) Sanity: the cache actually wrote something. Otherwise this test
        #    is vacuous and would falsely pass.
        refute_empty cached_keys.call,
                     "cache should have an entry after the first count"

        # 3) Same query repeated -> cache hit -> still 8.
        assert_equal 8, q.count, "repeat call should be a cache hit but still 8"

        # 4) Chain a workspace filter onto the SAME query object. If chained
        #    .where weren't being honored, or the cache were keyed too
        #    coarsely, we'd see 8 here. We expect 5.
        q.where(author_workspace: @workspace_a)
        assert_equal 5, q.count,
                     "chained where(author_workspace: A) must change URL -> cache miss -> 5"

        # 5) each_with_index honors the filter under caching too.
        ids = []
        q.each_with_index { |c, _| ids << c.id }
        assert_equal 5, ids.size

        # 6) Now build a fresh query with workspace B, with cache on -> 3.
        q2 = base_query
        q2.cache = true
        q2.where(author_workspace: @workspace_b)
        assert_equal 3, q2.count, "workspace B count under caching"

        # 7) Confirm the cache holds three distinct keys (one per URL),
        #    proving the URL truly varies with the chained where clause.
        assert_operator cached_keys.call.size, :>=, 3,
                        "expected at least 3 distinct cache keys (baseline, workspace A, workspace B)"
      ensure
        # Restore default (uncached) test client for any subsequent tests.
        Parse::Test::ServerHelper.setup
        [Parse::Query, Parse::Object].each do |k|
          k.instance_variable_set(:@client, nil) if k.instance_variable_defined?(:@client)
        end
      end
    end
  end
end
