# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "moneta"
require "json"
require "parse/cache/keyspace"

# Regressions for two cache isolation gaps in Parse::Middleware::Caching:
#
# * With a keyspace configured, entries were keyed only by `:anon`, `:master`
#   or a session-token digest. An invalid master key (or another REST key)
#   was served the entry cached under the valid one.
# * A write to one object retired that object's cached reads but left every
#   cached query over its class readable, so a row whose ACL was just revoked
#   stayed visible through `classes/<C>?where=...` until the entry expired.
#
# Every scenario runs under both the legacy layout and the keyspace layout.
module ClientReviewCacheHarness
  include Parse::Protocol

  SERVER = "https://test.parse/parse"
  APP = "app-a"
  QUERY = "/parse/classes/Post?where=%7B%7D"

  def setup
    @store = Moneta.new(:Memory, expires: true)
    @prior_enabled = Parse::Middleware::Caching.enabled
    # These tests cover session-keyed entries, which are cached only when
    # the application opts in (SEC-16).
    @prior_session_caching = Parse::Middleware::Caching.cache_session_requests
    Parse::Middleware::Caching.cache_session_requests = true
    Parse::Middleware::Caching.enabled = true
    @server_calls = Hash.new(0)
  end

  def teardown
    @store.clear
    Parse::Middleware::Caching.enabled = @prior_enabled
    Parse::Middleware::Caching.cache_session_requests = @prior_session_caching
  end

  # Subclasses return a keyspace, or nil for the legacy layout.
  def keyspace
    nil
  end

  def store
    @store
  end

  def headers_for(master: nil, session: nil, rest: "rest-a")
    h = { APP_ID => APP, API_KEY => rest }
    h[MASTER_KEY] = master if master
    h[SESSION_TOKEN] = session if session
    h
  end

  # Send one request through the caching middleware. Returns
  # [body, served_from_cache].
  def request(path, headers, method: :get, req_body: nil, body: '{"results":["fresh-from-server"]}')
    padded = body.ljust(20)
    calls = @server_calls
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.send(method, path) do |_|
        calls[path] += 1
        [200, { "Content-Type" => "application/json", "Content-Length" => padded.bytesize.to_s }, padded]
      end
    end
    ks = keyspace
    conn = Faraday.new(url: SERVER) do |f|
      f.use Parse::Middleware::Caching, store, { expires: 60, keyspace: ks }
      f.adapter :test, stubs
    end
    resp = conn.run_request(method, path, req_body, nil) do |req|
      headers.each { |k, v| req.headers[k] = v }
    end
    [resp.body, resp.headers["X-Cache-Response"] == "true"]
  end

  def put(path, headers)
    request(path, headers, method: :put, req_body: '{"ACL":{}}', body: '{"updatedAt":"2026-01-01"}')
  end

  def assert_cached(path, headers, label = nil)
    request(path, headers)
    _, hit = request(path, headers)
    assert hit, "precondition: #{label || path} is cached"
  end

  # ---- credential isolation ----------------------------------------------

  def test_wrong_master_key_does_not_hit
    assert_cached("/parse/classes/Post/abc", headers_for(master: "mk-a"))
    _, hit = request("/parse/classes/Post/abc", headers_for(master: "wrong-master"))
    refute hit, "a different master key must not read the entry cached under the valid one"
  end

  def test_wrong_rest_key_does_not_hit
    assert_cached("/parse/classes/Post/pub", headers_for)
    _, hit = request("/parse/classes/Post/pub", headers_for(rest: "wrong-rest"))
    refute hit, "an anonymous entry is bound to the REST key that produced it"
  end

  def test_same_credentials_still_hit
    assert_cached("/parse/classes/Post/abc", headers_for(master: "mk-a"))
    assert_cached(QUERY, headers_for(session: "r:ta"))
    assert_cached(QUERY, headers_for)
  end

  def test_write_still_retires_every_credential_variant
    assert_cached("/parse/classes/Post/abc", headers_for(master: "mk-a"))
    assert_cached("/parse/classes/Post/abc", headers_for(session: "r:tb"))
    put("/parse/classes/Post/abc", headers_for(session: "r:ta"))
    _, mk_hit = request("/parse/classes/Post/abc", headers_for(master: "mk-a"))
    refute mk_hit
    _, b_hit = request("/parse/classes/Post/abc", headers_for(session: "r:tb"))
    refute b_hit
  end

  # ---- collection retirement ---------------------------------------------

  def test_object_write_retires_cached_queries_of_its_class
    b = headers_for(session: "r:tb")
    assert_cached(QUERY, b)
    put("/parse/classes/Post/abc", headers_for(session: "r:ta"))
    _, hit = request(QUERY, b)
    refute hit, "a query containing a row whose ACL changed must not stay readable"
  end

  def test_object_write_retires_unfiltered_class_reads
    b = headers_for(session: "r:tb")
    assert_cached("/parse/classes/Post", b)
    put("/parse/classes/Post/abc", headers_for(master: "mk-a"))
    _, hit = request("/parse/classes/Post", b)
    refute hit
  end

  def test_object_write_retires_aggregate_reads_of_its_class
    m = headers_for(master: "mk-a")
    path = "/parse/aggregate/Post?pipeline=%5B%5D"
    assert_cached(path, m)
    put("/parse/classes/Post/abc", m)
    _, hit = request(path, m)
    refute hit
  end

  def test_create_retires_cached_queries_of_its_class
    b = headers_for(session: "r:tb")
    assert_cached(QUERY, b)
    request("/parse/classes/Post", headers_for(session: "r:ta"), method: :post,
                                                                 req_body: '{"title":"x"}', body: '{"objectId":"new1"}')
    _, hit = request(QUERY, b)
    refute hit
  end

  def test_delete_retires_cached_queries_of_its_class
    b = headers_for(session: "r:tb")
    assert_cached(QUERY, b)
    request("/parse/classes/Post/abc", headers_for(master: "mk-a"), method: :delete, body: "{}")
    _, hit = request(QUERY, b)
    refute hit
  end

  def test_batch_write_retires_cached_queries_and_objects_of_each_class
    b = headers_for(session: "r:tb")
    assert_cached(QUERY, b)
    assert_cached("/parse/classes/Post/abc", b)
    assert_cached("/parse/classes/Other?where=%7B%7D", b)
    batch = { requests: [
      { method: "PUT", path: "/parse/classes/Post/abc", body: { ACL: {} } },
    ] }.to_json
    request("/parse/batch", headers_for(master: "mk-a"), method: :post, req_body: batch, body: "[]")
    _, query_hit = request(QUERY, b)
    refute query_hit, "a batch write must retire cached queries of the class it touched"
    _, object_hit = request("/parse/classes/Post/abc", b)
    refute object_hit, "a batch write must retire the cached object it touched"
    _, other_hit = request("/parse/classes/Other?where=%7B%7D", b)
    assert other_hit, "a batch must not retire classes it did not touch"
  end

  def test_user_write_retires_cached_user_queries
    m = headers_for(master: "mk-a")
    assert_cached("/parse/users?where=%7B%7D", m)
    put("/parse/users/u1", m)
    _, hit = request("/parse/users?where=%7B%7D", m)
    refute hit
  end

  def test_object_write_does_not_retire_another_class
    b = headers_for(session: "r:tb")
    other = "/parse/classes/Other?where=%7B%7D"
    assert_cached(other, b)
    put("/parse/classes/Post/abc", b)
    _, hit = request(other, b)
    assert hit
  end

  def test_object_write_does_not_retire_sibling_object_reads
    b = headers_for(session: "r:tb")
    assert_cached("/parse/classes/Post/other", b)
    put("/parse/classes/Post/abc", b)
    _, hit = request("/parse/classes/Post/other", b)
    assert hit, "a single-object read is not a query and keeps its entry"
  end

  # A long query that BodyBuilder converted to `POST` with a GET method
  # override is a read, and must not retire anything.
  def test_get_override_post_does_not_retire_queries
    b = headers_for(session: "r:tb")
    assert_cached(QUERY, b)
    override = b.merge("X-Http-Method-Override" => "GET")
    request("/parse/classes/Post", override, method: :post, req_body: "_method=GET&where=%7B%7D")
    _, hit = request(QUERY, b)
    assert hit
  end
end

class ClientReviewLegacyCacheTest < Minitest::Test
  include ClientReviewCacheHarness
end

class ClientReviewKeyspaceCacheTest < Minitest::Test
  include ClientReviewCacheHarness

  def keyspace
    @keyspace ||= Parse::Cache::Keyspace.new(app_id: ClientReviewCacheHarness::APP, server_url: ClientReviewCacheHarness::SERVER)
  end

  def test_entries_and_version_keys_stay_under_the_keyspace
    request(QUERY, headers_for(master: "mk-a"))
    put("/parse/classes/Post/abc", headers_for(master: "mk-a"))
    keys = []
    @store.each_key { |k| keys << k }
    refute_empty keys
    keys.each { |k| assert k.start_with?("#{keyspace.root_prefix}:"), "stray key #{k}" }
  end

  def test_no_raw_credential_appears_in_any_key
    request(QUERY, headers_for(master: "super-secret-master", session: nil))
    request(QUERY, headers_for(session: "r:supersecrettoken"))
    @store.each_key do |k|
      refute_includes k, "super-secret-master"
      refute_includes k, "supersecrettoken"
    end
  end

  # Tenant scoping still applies to entries: one tenant never reads another's.
  def test_tenants_do_not_share_entries
    skip "cache tenants unavailable" unless Parse.respond_to?(:with_cache_tenant)
    m = headers_for(master: "mk-a")
    Parse.with_cache_tenant("t1") { assert_cached(QUERY, m) }
    hit = nil
    Parse.with_cache_tenant("t2") { _, hit = request(QUERY, m) }
    refute hit
  end
end

class ClientReviewKeyspaceScanCacheTest < ClientReviewKeyspaceCacheTest
  # Stands in for Parse::Cache::Redis: adds the pattern delete the middleware
  # probes for, so resource eviction takes its scan path.
  class ScanCapableStore
    def initialize(inner) = @inner = inner
    def [](k) = @inner[k]
    def key?(k) = @inner.key?(k)
    def delete(k) = @inner.delete(k)
    def store(k, v, o = {}) = @inner.store(k, v, o)

    def delete_matching(pattern)
      doomed = []
      @inner.each_key { |k| doomed << k if File.fnmatch(pattern, k, File::FNM_NOESCAPE) }
      doomed.each { |k| @inner.delete(k) }
      doomed.size
    end
  end

  def store
    @scan_store ||= ScanCapableStore.new(@store)
  end
end
