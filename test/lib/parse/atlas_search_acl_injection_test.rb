# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/atlas_search"

# Unit tests for the ACL $match injection in Parse::AtlasSearch.search
# and Parse::AtlasSearch.autocomplete. These tests do NOT require a
# live MongoDB / Atlas deployment: they stub Parse::MongoDB.collection
# to return a fake collection whose #aggregate captures the pipeline
# the search method assembled before sending.
#
# IMPORTANT: do NOT stub Parse::MongoDB.aggregate (the module method).
# Atlas Search must bypass that helper because Parse::MongoDB.aggregate
# PREPENDS the ACL $match to stage 0 — MongoDB Atlas rejects any
# pipeline whose stage 0 is not $search / $searchMeta. Stubbing the
# module method masks the stage-ordering invariant. The fake collection
# below intercepts the call at the same boundary Atlas Search uses
# (`Parse::MongoDB.collection(name).aggregate(pipeline, opts).to_a`)
# so the assertions see exactly what Atlas would see on the wire.
#
# What we verify:
#   1. session_token: produces an ACL $match referencing _rperm with
#      the correct permission strings.
#   2. master: true suppresses the ACL $match entirely.
#   3. require_session_token = true refuses missing-auth calls.
#   4. Missing-auth calls fall through to public-only ACL semantics
#      under the banner-by-default mode and emit the banner once.
#   5. faceted_search refuses session_token: / acl_user: / acl_role:
#      outright (ATLAS-10 / NEW-ATLAS-10).
#   6. $search appears at index 0 of the compiled pipeline — never
#      preceded by an ACL $match — the stage-ordering regression
#      that nearly shipped. The previous test fixture stubbed
#      Parse::MongoDB.aggregate, hiding the bug.
#   7. protectedFields are stripped from result rows.
#   8. _highlights paths matching protectedFields are dropped.
class AtlasSearchACLInjectionTest < Minitest::Test
  # @!visibility private
  # Fake Mongo::Collection. Captures whatever pipeline / options are
  # handed to #aggregate, and returns whatever rows the test seeded
  # via {.seed}. The cursor surface is just an Array that responds to
  # #to_a (Mongo::Collection#aggregate returns a lazy cursor that
  # Atlas Search immediately materializes via .to_a).
  class FakeCollection
    attr_reader :pipelines, :options
    def initialize
      @pipelines = []
      @options = []
      @rows = []
    end

    def aggregate(pipeline, opts = {})
      @pipelines << pipeline
      @options << opts
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

    # Wave-3 TRACK-CLP-2 made Parse::CLPScope.permits? fail CLOSED when
    # the schema endpoint is unresolvable. In this unit-test file there
    # is no live Parse Server, so every CLP check on "Song" would
    # otherwise raise Parse::CLPScope::Denied before the test's actual
    # assertions about $rperm injection / stage ordering run. Pre-seed a
    # public-find CLP for "Song" so the gate is satisfied and these
    # tests exercise the ACL-injection + stage-ordering logic they were
    # written to cover. Tests that need a different CLP shape (e.g.
    # protectedFields) call seed_clp themselves; __cache_put just
    # overwrites this seed.
    Parse::CLPScope.__cache_put("Song", clp: {
      "find" => { "*" => true },
      "get" => { "*" => true },
      "count" => { "*" => true },
    })

    @collections = Hash.new { |h, k| h[k] = FakeCollection.new }

    @original_available = Parse::MongoDB.method(:available?)
    Parse::MongoDB.define_singleton_method(:available?) { true }
    @original_collection = Parse::MongoDB.method(:collection)
    collections = @collections
    Parse::MongoDB.define_singleton_method(:collection) do |name|
      collections[name.to_s]
    end
  end

  def teardown
    Parse::MongoDB.define_singleton_method(:available?, @original_available) if @original_available
    Parse::MongoDB.define_singleton_method(:collection, @original_collection) if @original_collection
    if Parse::AtlasSearch::Session.singleton_class.private_method_defined?(:__orig_resolve) ||
       Parse::AtlasSearch::Session.singleton_class.method_defined?(:__orig_resolve)
      Parse::AtlasSearch::Session.singleton_class.send(:alias_method, :resolve, :__orig_resolve)
      Parse::AtlasSearch::Session.singleton_class.send(:remove_method, :__orig_resolve)
    end
    Parse::AtlasSearch.reset!
    Parse::CLPScope.reset_cache!
  end

  # @!visibility private
  # Stub Session.resolve to skip the /users/me + role expansion path
  # and return a deterministic permission set.
  def stub_session(user_id:, role_names: [], token: "tok-abc")
    resolved = Parse::AtlasSearch::Session::Resolved.new(user_id, Set.new(role_names))
    Parse::AtlasSearch::Session.singleton_class.send(:alias_method, :__orig_resolve, :resolve)
    Parse::AtlasSearch::Session.define_singleton_method(:resolve) do |t|
      t == token ? resolved : __orig_resolve(t)
    end
    token
  end

  def pipeline_for(collection)
    @collections[collection].pipelines.first
  end

  def find_acl_match_stage(pipeline)
    pipeline.find do |stage|
      next unless stage.is_a?(Hash) && stage["$match"]
      stage["$match"]["$or"]&.any? { |b| b["_rperm"] }
    end
  end

  def acl_match_index(pipeline)
    pipeline.find_index do |stage|
      stage.is_a?(Hash) && stage["$match"] &&
        stage["$match"]["$or"]&.any? { |b| b["_rperm"] }
    end
  end

  def search_stage_index(pipeline)
    pipeline.find_index { |stage| stage.is_a?(Hash) && stage.key?("$search") }
  end

  # ----------------------------------------------------------------
  # Existing assertions (carried over, re-stubbed at the new boundary)
  # ----------------------------------------------------------------

  def test_session_token_injects_acl_match
    token = stub_session(user_id: "U1", role_names: %w[Member])
    Parse::AtlasSearch.search("Song", "love", session_token: token)

    pipeline = pipeline_for("Song")
    refute_nil pipeline, "search must execute a pipeline"

    acl_stage = find_acl_match_stage(pipeline)
    refute_nil acl_stage, "session_token: must inject a _rperm $match stage"

    perms = acl_stage["$match"]["$or"].first["_rperm"]["$in"]
    assert_includes perms, "U1"
    assert_includes perms, "role:Member"
    assert_includes perms, "*"

    assert acl_stage["$match"]["$or"].any? { |b| b["_rperm"] == { "$exists" => false } },
           "ACL $match must include $exists: false branch (public docs lack _rperm)"
  end

  def test_master_true_suppresses_acl_match
    Parse::AtlasSearch.search("Song", "love", master: true)
    pipeline = pipeline_for("Song")
    assert_nil find_acl_match_stage(pipeline),
               "master: true must NOT inject a _rperm match (master mode == ACL bypass)"
  end

  def test_anonymous_call_falls_through_with_public_only_perms
    capture = capture_stderr do
      Parse::AtlasSearch.search("Song", "love")
    end
    assert_match(/SECURITY/, capture, "missing-auth call should emit a one-time banner")

    pipeline = pipeline_for("Song")
    acl_stage = find_acl_match_stage(pipeline)
    refute_nil acl_stage, "anonymous fallback still injects an ACL $match (public-only)"
    perms = acl_stage["$match"]["$or"].first["_rperm"]["$in"]
    assert_equal ["*"], perms, "anonymous fallback's $in list is exactly [\"*\"]"
  end

  def test_anonymous_banner_only_once_per_process
    out1 = capture_stderr { Parse::AtlasSearch.search("Song", "love") }
    out2 = capture_stderr { Parse::AtlasSearch.search("Song", "again") }
    assert_match(/SECURITY/, out1)
    refute_match(/SECURITY/, out2, "banner must be one-time-per-process")
  end

  def test_require_session_token_refuses_unauthenticated
    Parse::AtlasSearch.require_session_token = true
    assert_raises(Parse::AtlasSearch::ACLRequired) do
      Parse::AtlasSearch.search("Song", "love")
    end
  end

  def test_require_session_token_allows_master
    Parse::AtlasSearch.require_session_token = true
    Parse::AtlasSearch.search("Song", "love", master: true)
    refute_nil pipeline_for("Song")
  end

  def test_cannot_pass_both_session_token_and_master
    token = stub_session(user_id: "U1", role_names: [])
    assert_raises(ArgumentError) do
      Parse::AtlasSearch.search("Song", "love", session_token: token, master: true)
    end
  end

  def test_autocomplete_also_injects_acl_match
    token = stub_session(user_id: "U2", role_names: %w[Admin])
    Parse::AtlasSearch.autocomplete("Song", "lo", field: "title", session_token: token)
    pipeline = pipeline_for("Song")
    acl_stage = find_acl_match_stage(pipeline)
    refute_nil acl_stage, "autocomplete must also inject the ACL $match"
    perms = acl_stage["$match"]["$or"].first["_rperm"]["$in"]
    assert_includes perms, "U2"
    assert_includes perms, "role:Admin"
  end

  def test_acl_match_placed_before_caller_filter
    # $search → $addFields → ACL $match → caller $match → sort/limit.
    # The user-controlled filter must not see documents the ACL would
    # have hidden.
    token = stub_session(user_id: "U1", role_names: [])
    Parse::AtlasSearch.search("Song", "love",
                              session_token: token,
                              filter: { "genre" => "Rock" })
    pipeline = pipeline_for("Song")

    acl_idx = acl_match_index(pipeline)
    user_filter_idx = pipeline.find_index { |s| s["$match"] == { "genre" => "Rock" } }

    refute_nil acl_idx, "ACL match must be present"
    refute_nil user_filter_idx, "User filter must be present"
    assert acl_idx < user_filter_idx,
           "ACL match must precede caller filter so the user filter cannot widen ACL"
  end

  def test_faceted_search_refuses_session_token
    token = stub_session(user_id: "U1", role_names: [])
    assert_raises(Parse::AtlasSearch::FacetedSearchNotACLSafe) do
      Parse::AtlasSearch.faceted_search("Song", "love",
                                        { genre: { type: :string, path: :genre } },
                                        session_token: token)
    end
  end

  # ----------------------------------------------------------------
  # NEW: stage-ordering regressions
  # ----------------------------------------------------------------

  # (a) The bug that nearly shipped. Atlas rejects any pipeline whose
  # stage 0 is anything other than $search/$searchMeta. Verify that
  # $search is at index 0 of the compiled pipeline regardless of
  # scope mode, and that no $match precedes it.
  def test_search_stage_at_index_zero_session_scope
    token = stub_session(user_id: "U1", role_names: %w[Member])
    Parse::AtlasSearch.search("Song", "love", session_token: token)
    pipeline = pipeline_for("Song")

    assert_equal 0, search_stage_index(pipeline),
                 "$search MUST be stage 0 of the pipeline (Atlas invariant)"
    pipeline.first(search_stage_index(pipeline)).each do |stage|
      refute stage.key?("$match"),
             "no $match stage may precede $search (would cause Atlas to reject)"
    end
  end

  def test_search_stage_at_index_zero_public_scope
    capture_stderr { Parse::AtlasSearch.search("Song", "love") }
    pipeline = pipeline_for("Song")
    assert_equal 0, search_stage_index(pipeline),
                 "$search MUST be stage 0 even in public/no-auth fallback"
    # The public-mode ACL $match still appears, just AFTER $search.
    acl_idx = acl_match_index(pipeline)
    refute_nil acl_idx, "public-mode ACL $match still injected"
    assert acl_idx > 0, "public-mode ACL $match must follow $search, not precede it"
  end

  def test_search_stage_at_index_zero_master_scope
    Parse::AtlasSearch.search("Song", "love", master: true)
    pipeline = pipeline_for("Song")
    assert_equal 0, search_stage_index(pipeline),
                 "$search MUST be stage 0 in master mode"
  end

  # (b) ACL $match must come AFTER $search but BEFORE the caller filter.
  def test_acl_match_after_search_and_before_caller_filter
    token = stub_session(user_id: "U1", role_names: [])
    Parse::AtlasSearch.search("Song", "love",
                              session_token: token,
                              filter: { "genre" => "Rock" })
    pipeline = pipeline_for("Song")

    s_idx = search_stage_index(pipeline)
    a_idx = acl_match_index(pipeline)
    f_idx = pipeline.find_index { |s| s["$match"] == { "genre" => "Rock" } }

    refute_nil s_idx
    refute_nil a_idx
    refute_nil f_idx
    assert s_idx < a_idx, "ACL must come AFTER $search"
    assert a_idx < f_idx, "ACL must come BEFORE caller filter"
  end

  # ----------------------------------------------------------------
  # NEW: protectedFields stripping (ATLAS-4 follow-through)
  # ----------------------------------------------------------------

  def seed_clp(class_name, clp)
    Parse::CLPScope.__cache_put(class_name, clp: clp)
  end

  def test_protected_fields_stripped_from_search_results
    seed_clp("Song", {
      "find" => { "*" => true },
      "protectedFields" => { "*" => ["lyrics"] },
    })
    @collections["Song"].seed([
      { "_id" => "s1", "title" => "Hi", "lyrics" => "SECRET TEXT", "_score" => 1.0 },
    ])
    # Flip allow_raw so the `raw: true` flag is honored and the
    # `raw_results` field on the SearchResult reflects what made it
    # through the protectedFields walker (rather than the post-
    # sanitization re-strip that fires regardless of raw mode).
    Parse::AtlasSearch.allow_raw = true
    token = stub_session(user_id: "U1", role_names: [])
    result = Parse::AtlasSearch.search("Song", "hi", session_token: token, raw: true,
                                       class_name: "Song")
    rows = result.raw_results
    assert_equal 1, rows.length
    refute rows.first.key?("lyrics"),
           "protectedFields entry 'lyrics' must be stripped from the result row"
    assert_equal "Hi", rows.first["title"], "non-protected fields pass through"
  end

  def test_master_mode_skips_protected_fields_strip
    seed_clp("Song", {
      "find" => { "*" => true },
      "protectedFields" => { "*" => ["lyrics"] },
    })
    @collections["Song"].seed([
      { "_id" => "s1", "title" => "Hi", "lyrics" => "SECRET TEXT", "_score" => 1.0 },
    ])
    Parse::AtlasSearch.allow_raw = true
    result = Parse::AtlasSearch.search("Song", "hi", master: true, raw: true, class_name: "Song")
    rows = result.raw_results
    assert_equal "SECRET TEXT", rows.first["lyrics"],
                 "master mode bypasses protectedFields enforcement"
  end

  # ----------------------------------------------------------------
  # NEW: ATLAS-4 highlight_field gates
  # ----------------------------------------------------------------

  def test_highlight_field_in_protected_fields_is_refused
    seed_clp("Song", {
      "find" => { "*" => true },
      "protectedFields" => { "*" => ["lyrics"] },
    })
    token = stub_session(user_id: "U1", role_names: [])
    assert_raises(Parse::CLPScope::Denied) do
      Parse::AtlasSearch.search("Song", "hi",
                                session_token: token, highlight_field: "lyrics")
    end
  end

  def test_highlight_field_outside_protected_fields_is_allowed
    seed_clp("Song", {
      "find" => { "*" => true },
      "protectedFields" => { "*" => ["lyrics"] },
    })
    token = stub_session(user_id: "U1", role_names: [])
    # Highlighting on `title` is fine — only `lyrics` is protected.
    Parse::AtlasSearch.search("Song", "hi",
                              session_token: token, highlight_field: "title")
    pipeline = pipeline_for("Song")
    refute_nil pipeline
  end

  def test_master_mode_allows_highlight_on_protected_field
    seed_clp("Song", {
      "find" => { "*" => true },
      "protectedFields" => { "*" => ["lyrics"] },
    })
    # master mode skips protectedFields enforcement entirely.
    Parse::AtlasSearch.search("Song", "hi", master: true, highlight_field: "lyrics")
    pipeline = pipeline_for("Song")
    refute_nil pipeline
  end

  def test_highlights_paths_in_protected_fields_are_dropped_from_results
    seed_clp("Song", {
      "find" => { "*" => true },
      "protectedFields" => { "*" => ["lyrics"] },
    })
    # Hand the pipeline a row that already carries a `_highlights`
    # payload referencing the protected field — simulates the case
    # where the highlight stage was attached upstream / by a future
    # caller-supplied highlight Hash. The strip step in
    # `strip_protected_highlights!` must drop the entry.
    @collections["Song"].seed([
      {
        "_id" => "s1",
        "title" => "Hi",
        "_score" => 1.0,
        "_highlights" => [
          { "path" => "title", "score" => 0.9, "texts" => [{ "value" => "Hi", "type" => "hit" }] },
          { "path" => "lyrics", "score" => 0.8, "texts" => [{ "value" => "SECRET HIT", "type" => "hit" }] },
        ],
      },
    ])
    Parse::AtlasSearch.allow_raw = true
    token = stub_session(user_id: "U1", role_names: [])
    result = Parse::AtlasSearch.search("Song", "hi",
                                       session_token: token, raw: true, class_name: "Song")
    rows = result.raw_results
    highlights = rows.first["_highlights"]
    refute_nil highlights, "the _highlights key should still be present"
    paths = highlights.map { |h| h["path"] }
    assert_includes paths, "title", "non-protected highlight path passes through"
    refute_includes paths, "lyrics",
                    "highlight entry pointing at a protected field must be dropped"
  end

  # ----------------------------------------------------------------
  # NEW: ATLAS-10 — faceted_search refuses acl_user / acl_role
  # ----------------------------------------------------------------

  def test_faceted_search_refuses_acl_user_kwarg
    user = Parse::Pointer.new(Parse::Model::CLASS_USER, "U1")
    assert_raises(Parse::AtlasSearch::FacetedSearchNotACLSafe) do
      Parse::AtlasSearch.faceted_search("Song", "love",
                                        { genre: { type: :string, path: :genre } },
                                        acl_user: user)
    end
  end

  def test_faceted_search_refuses_acl_role_kwarg
    assert_raises(Parse::AtlasSearch::FacetedSearchNotACLSafe) do
      Parse::AtlasSearch.faceted_search("Song", "love",
                                        { genre: { type: :string, path: :genre } },
                                        acl_role: "Admin")
    end
  end

  def test_faceted_search_refuses_session_token_without_master_override
    # A `session_token:` paired with `master: true` is meaningless
    # (master mode wins) — refuse the combination outright too via the
    # existing ArgumentError. The point of this test is to confirm
    # that the offending-kwargs check fires on `session_token:` even
    # when no `acl_user:` / `acl_role:` is present (i.e., the original
    # ATLAS-1 refusal is preserved).
    token = stub_session(user_id: "U1", role_names: [])
    assert_raises(Parse::AtlasSearch::FacetedSearchNotACLSafe) do
      Parse::AtlasSearch.faceted_search("Song", "love",
                                        { genre: { type: :string, path: :genre } },
                                        session_token: token)
    end
  end

  def test_faceted_search_allows_master_true
    # master: true is the only sanctioned mode for $searchMeta. The
    # call should reach the pipeline.
    @collections["Song"].seed([{ "facet" => {}, "count" => { "total" => 0 } }])
    Parse::AtlasSearch.faceted_search("Song", "love",
                                      { genre: { type: :string, path: :genre } },
                                      master: true)
    pipeline = pipeline_for("Song")
    refute_nil pipeline
    assert pipeline.first.key?("$searchMeta"), "facet pipeline begins with $searchMeta"
  end

  # ----------------------------------------------------------------
  # NEW: $expr protected-field oracle guard on the caller filter.
  #
  # `validate_filter!` blocks $where/$function/$out/$merge but NOT
  # `$expr`. A scoped caller could otherwise binary-search a
  # protectedFields value with `{"$expr" => {"$gt" => ["$ssn", "M"]}}`
  # even though the column is stripped from OUTPUT. The `filter:` path
  # previously skipped the guard the mongo-direct aggregate path applies.
  # ----------------------------------------------------------------

  def test_expr_filter_referencing_protected_field_is_refused
    seed_clp("Song", {
      "find" => { "*" => true },
      "protectedFields" => { "*" => ["ssn"] },
    })
    token = stub_session(user_id: "U1", role_names: [])
    assert_raises(Parse::CLPScope::Denied) do
      Parse::AtlasSearch.search("Song", "hi",
                                session_token: token,
                                filter: { "$expr" => { "$gt" => ["$ssn", "M"] } })
    end
  end

  def test_expr_filter_referencing_nonprotected_field_is_allowed
    seed_clp("Song", {
      "find" => { "*" => true },
      "protectedFields" => { "*" => ["ssn"] },
    })
    token = stub_session(user_id: "U1", role_names: [])
    # Referencing a NON-protected field via $expr is fine.
    Parse::AtlasSearch.search("Song", "hi",
                              session_token: token,
                              filter: { "$expr" => { "$gt" => ["$plays", 10] } })
    pipeline = pipeline_for("Song")
    refute_nil pipeline, "non-protected $expr filter must execute"
  end

  def test_expr_filter_referencing_protected_field_allowed_for_master
    seed_clp("Song", {
      "find" => { "*" => true },
      "protectedFields" => { "*" => ["ssn"] },
    })
    # master has no protectedFields to protect — the guard self-skips.
    Parse::AtlasSearch.search("Song", "hi",
                              master: true,
                              filter: { "$expr" => { "$gt" => ["$ssn", "M"] } })
    pipeline = pipeline_for("Song")
    refute_nil pipeline, "master $expr filter must execute (no protectedFields enforcement)"
  end

  # ----------------------------------------------------------------
  # NEW: Parse::Query#atlas_search builder-block mode.
  #
  # Previously non-functional: it called Parse::MongoDB.aggregate with
  # no auth forwarding (unscoped) AND an ACL $match prepended to stage 0
  # (rejected by Atlas). It now routes through search_with_stage, which
  # forwards the query's scope, keeps $search at stage 0, and runs the
  # full enforcement chain.
  # ----------------------------------------------------------------

  def test_query_block_mode_forwards_session_scope_and_keeps_search_stage_zero
    require "parse/query"
    token = stub_session(user_id: "U1", role_names: %w[Member])
    q = Parse::Query.new("Song")
    q.session_token = token
    q.atlas_search do |s|
      s.text(query: "love", path: :title)
    end

    pipeline = pipeline_for("Song")
    refute_nil pipeline, "block-mode search must execute a pipeline"
    assert_equal 0, search_stage_index(pipeline),
                 "$search MUST be stage 0 in block mode (Atlas invariant)"
    acl = find_acl_match_stage(pipeline)
    refute_nil acl, "block-mode must inject the ACL $match for a session scope"
    perms = acl["$match"]["$or"].first["_rperm"]["$in"]
    assert_includes perms, "U1", "ACL $match must carry the scoped user's permission strings"
  end

  def test_query_block_mode_master_suppresses_acl_match
    require "parse/query"
    # Explicit `master: true` on the call wins over any query scope.
    q = Parse::Query.new("Song")
    q.atlas_search(master: true) do |s|
      s.text(query: "love", path: :title)
    end

    pipeline = pipeline_for("Song")
    refute_nil pipeline, "block-mode master search must execute"
    assert_equal 0, search_stage_index(pipeline), "$search MUST be stage 0"
    assert_nil find_acl_match_stage(pipeline),
               "master: true block search must NOT inject a _rperm $match"
  end

  def test_query_block_mode_expr_filter_oracle_guard_applies
    require "parse/query"
    seed_clp("Song", {
      "find" => { "*" => true },
      "protectedFields" => { "*" => ["ssn"] },
    })
    token = stub_session(user_id: "U1", role_names: [])
    q = Parse::Query.new("Song")
    q.session_token = token
    # The caller filter carried into the block search must get the same
    # $expr oracle guard as the options path.
    assert_raises(Parse::CLPScope::Denied) do
      q.atlas_search(filter: { "$expr" => { "$gt" => ["$ssn", "M"] } }) do |s|
        s.text(query: "hi", path: :title)
      end
    end
  end

  private

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end
end
