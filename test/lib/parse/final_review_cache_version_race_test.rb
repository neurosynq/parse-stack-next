# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "moneta"
require "json"
require "parse/cache/keyspace"

# Regression for an in-flight race in Parse::Middleware::Caching's version
# binding.
#
# A GET on a cold cache (no `rv:` / `cv:` version keys yet) used to resolve
# its versions only after the response arrived. A read that started before
# an ACL update and finished after it therefore adopted the versions the
# write had just created and stored its older, private body under them, so
# every later reader was served the revoked data.
#
# The fix establishes the versions before dispatch and skips the store when
# any of them changed while the request was in flight. Each scenario below
# runs a write through the middleware from inside the read's server stub, so
# the write lands deterministically between the read's dispatch and its
# response. Every scenario runs under the legacy layout, the keyspace layout,
# a scan-capable keyspace store, and a store without set-if-absent.
module FinalReviewCacheRaceHarness
  include Parse::Protocol

  SERVER = "https://test.parse/parse"
  APP = "app-a"
  OBJECT = "/parse/classes/Post/abc"
  QUERY = "/parse/classes/Post?where=%7B%7D"
  STALE = '{"objectId":"abc","secret":"before-revoke"}'
  FRESH = '{"objectId":"abc","secret":"after-revoke"}'

  def setup
    @store = Moneta.new(:Memory, expires: true)
    @prior_enabled = Parse::Middleware::Caching.enabled
    Parse::Middleware::Caching.enabled = true
  end

  def teardown
    @store.clear
    Parse::Middleware::Caching.enabled = @prior_enabled
  end

  def keyspace
    nil
  end

  def store
    @store
  end

  def headers_for(master: nil, session: nil)
    h = { APP_ID => APP, API_KEY => "rest-a" }
    h[MASTER_KEY] = master if master
    h[SESSION_TOKEN] = session if session
    h
  end

  # Send one request through the caching middleware. `during` runs inside the
  # server stub, after the middleware dispatched the request and before the
  # response returns to it. Returns [body, served_from_cache].
  def request(path, headers, method: :get, req_body: nil, body: FRESH, during: nil)
    padded = body.ljust(20)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.send(method, path) do |_|
        during&.call
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
    [resp.body.to_s.strip, resp.headers["X-Cache-Response"] == "true"]
  end

  def revoke_acl(during: nil)
    request(OBJECT, headers_for(master: "mk-a"), method: :put,
                                                  req_body: '{"ACL":{}}', body: '{"updatedAt":"2026-01-01"}', during: during)
  end

  def assert_not_stale(path, headers)
    body, hit = request(path, headers, body: FRESH)
    refute hit, "the response fetched before the write must not be served from cache"
    assert_equal FRESH, body
  end

  # ---- write completes while the read is in flight -----------------------

  def test_cold_object_read_overlapping_a_write_is_not_cached
    victim = headers_for(session: "r:victim")
    body, = request(OBJECT, victim, body: STALE, during: -> { revoke_acl })
    assert_equal STALE, body, "precondition: the in-flight read saw the pre-write state"
    assert_not_stale(OBJECT, victim)
  end

  def test_cold_query_read_overlapping_a_write_is_not_cached
    victim = headers_for(session: "r:victim")
    request(QUERY, victim, body: STALE, during: -> { revoke_acl })
    assert_not_stale(QUERY, victim)
  end

  def test_cold_master_read_overlapping_a_write_is_not_cached
    m = headers_for(master: "mk-a")
    request(QUERY, m, body: STALE, during: -> { revoke_acl })
    assert_not_stale(QUERY, m)
  end

  def test_write_only_read_overlapping_a_write_is_not_cached
    victim = headers_for(session: "r:victim")
    wo = victim.merge(Parse::Middleware::Caching::CACHE_WRITE_ONLY => "true")
    request(OBJECT, wo, body: STALE, during: -> { revoke_acl })
    assert_not_stale(OBJECT, victim)
  end

  def test_warm_versions_read_overlapping_a_write_is_not_cached
    victim = headers_for(session: "r:victim")
    request(OBJECT, victim)
    request(QUERY, victim)
    revoke_acl
    request(OBJECT, victim, body: STALE, during: -> { revoke_acl })
    request(QUERY, victim, body: STALE, during: -> { revoke_acl })
    assert_not_stale(OBJECT, victim)
    assert_not_stale(QUERY, victim)
  end

  # ---- read runs entirely inside the write's flight ----------------------

  # The write's pre-dispatch bump creates the versions, the read binds to
  # them and fetches the pre-write state, and the write's post-response bump
  # must still retire that entry.
  def test_read_nested_inside_a_write_is_retired_by_the_post_write_bump
    victim = headers_for(session: "r:victim")
    revoke_acl(during: -> { request(OBJECT, victim, body: STALE) })
    assert_not_stale(OBJECT, victim)
  end

  def test_query_nested_inside_a_write_is_retired_by_the_post_write_bump
    victim = headers_for(session: "r:victim")
    revoke_acl(during: -> { request(QUERY, victim, body: STALE) })
    assert_not_stale(QUERY, victim)
  end

  # ---- unaffected behavior -----------------------------------------------

  def test_undisturbed_cold_read_is_still_cached
    victim = headers_for(session: "r:victim")
    request(OBJECT, victim)
    _, hit = request(OBJECT, victim)
    assert hit
    request(QUERY, victim)
    _, hit = request(QUERY, victim)
    assert hit
  end

  def test_write_to_another_class_in_flight_does_not_block_caching
    victim = headers_for(session: "r:victim")
    other_write = lambda do
      request("/parse/classes/Other/x", headers_for(master: "mk-a"), method: :put,
                                                                     req_body: "{}", body: '{"updatedAt":"2026-01-01"}')
    end
    request(QUERY, victim, during: other_write)
    _, hit = request(QUERY, victim)
    assert hit, "a write to an unrelated class must not discard the read"
  end

  def test_get_override_post_in_flight_does_not_block_caching
    victim = headers_for(session: "r:victim")
    override = lambda do
      request("/parse/classes/Post", victim.merge("X-Http-Method-Override" => "GET"),
              method: :post, req_body: "_method=GET&where=%7B%7D")
    end
    request(QUERY, victim, during: override)
    _, hit = request(QUERY, victim)
    assert hit, "a long query re-sent as a POST is a read and bumps nothing"
  end

  def test_batch_write_in_flight_discards_the_read
    victim = headers_for(session: "r:victim")
    batch = { requests: [{ method: "PUT", path: OBJECT, body: { ACL: {} } }] }.to_json
    batch_write = lambda do
      request("/parse/batch", headers_for(master: "mk-a"), method: :post, req_body: batch, body: "[]")
    end
    request(QUERY, victim, body: STALE, during: batch_write)
    assert_not_stale(QUERY, victim)
  end
end

class FinalReviewCacheRaceLegacyTest < Minitest::Test
  include FinalReviewCacheRaceHarness
end

class FinalReviewCacheRaceKeyspaceTest < Minitest::Test
  include FinalReviewCacheRaceHarness

  def keyspace
    @keyspace ||= Parse::Cache::Keyspace.new(app_id: FinalReviewCacheRaceHarness::APP,
                                             server_url: FinalReviewCacheRaceHarness::SERVER)
  end

  def test_tenant_read_overlapping_a_write_is_not_cached
    skip "cache tenants unavailable" unless Parse.respond_to?(:with_cache_tenant)
    victim = headers_for(session: "r:victim")
    Parse.with_cache_tenant("t1") do
      request(QUERY, victim, body: STALE, during: -> { revoke_acl })
      assert_not_stale(QUERY, victim)
    end
  end
end

# Minimal Moneta-like store with no set-if-absent, so version creation takes
# the write-and-read-back path. Also offers the pattern delete the keyspace
# eviction probes for.
class FinalReviewNoCreateStore
  attr_reader :inner

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

class FinalReviewCacheRaceNoCreateLegacyTest < Minitest::Test
  include FinalReviewCacheRaceHarness

  def store
    @no_create ||= FinalReviewNoCreateStore.new(@store)
  end
end

class FinalReviewCacheRaceNoCreateKeyspaceTest < FinalReviewCacheRaceKeyspaceTest
  def store
    @no_create ||= FinalReviewNoCreateStore.new(@store)
  end
end

# Version creation must not overwrite a version a concurrent write bumped
# between the reader's lookup and its creation.
class FinalReviewCacheVersionCreationTest < Minitest::Test
  include Parse::Protocol

  VERSION_KEY_RE = /\A(?:rv|cv):/.freeze

  # Wraps a store and, the first time a version key is created or stored by
  # a reader, lets a "writer" bump that key first.
  class InterleavingStore < FinalReviewNoCreateStore
    attr_reader :writer_values

    def initialize(inner, with_create:)
      super(inner)
      @with_create = with_create
      @writer_values = {}
    end

    def store(k, v, o = {})
      result = @inner.store(k, v, o)
      # Writer lands after the reader's write and before its read-back.
      writer_bump(k, o) if !@with_create && version_key?(k)
      result
    end

    protected

    def version_key?(k)
      k.match?(VERSION_KEY_RE) && !@writer_values.key?(k)
    end

    def writer_bump(k, o)
      return unless version_key?(k)
      value = "writer-#{@writer_values.size}"
      @writer_values[k] = value
      @inner.store(k, value, o)
    end
  end

  # The same, with an atomic set-if-absent the writer wins against.
  class CreatingInterleavingStore < InterleavingStore
    def create(k, v, o = {})
      writer_bump(k, o)
      @inner.create(k, v, o)
    end
  end

  def setup
    @prior_enabled = Parse::Middleware::Caching.enabled
    Parse::Middleware::Caching.enabled = true
  end

  def teardown
    Parse::Middleware::Caching.enabled = @prior_enabled
  end

  def run_read(store)
    body = '{"results":["row"]}'.ljust(20)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get("/parse/classes/Post") do
        [200, { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }, body]
      end
    end
    conn = Faraday.new(url: "https://test.parse/parse") do |f|
      f.use Parse::Middleware::Caching, store, { expires: 60 }
      f.adapter :test, stubs
    end
    conn.get("/parse/classes/Post") { |req| req.headers[APP_ID] = "app-a"; req.headers[MASTER_KEY] = "mk" }
  end

  def assert_writer_versions_kept(store)
    run_read(store)
    refute_empty store.writer_values
    store.writer_values.each do |key, value|
      assert_equal value, store.inner[key], "reader overwrote the writer's version for #{key}"
    end
    # The entry is bound to the adopted version, so it is reachable.
    assert_equal "true", run_read(store).headers["X-Cache-Response"]
  end

  def test_set_if_absent_adopts_a_concurrently_bumped_version
    assert_writer_versions_kept(CreatingInterleavingStore.new(Moneta.new(:Memory, expires: true), with_create: true))
  end

  def test_read_back_adopts_a_concurrently_bumped_version
    assert_writer_versions_kept(InterleavingStore.new(Moneta.new(:Memory, expires: true), with_create: false))
  end
end
