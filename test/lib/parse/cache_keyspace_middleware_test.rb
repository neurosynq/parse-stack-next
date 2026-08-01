# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "moneta"
require "parse/cache/keyspace"

# Drives Parse::Middleware::Caching with a Parse::Cache::Keyspace installed,
# asserting on the actual keys written and evicted. Covers the two properties
# the keyspace exists to guarantee: that differently-authenticated requests for
# one URL never share an entry, and that a write evicts every auth variant of a
# resource rather than only the ones the middleware can name.
class CacheKeyspaceMiddlewareTest < Minitest::Test
  APP_ID = "myAppId"
  SERVER = "https://test.parse/parse"
  PATH = "/parse/classes/Post"

  def setup
    @store = Moneta.new(:Memory, expires: true)
    @prior_enabled = Parse::Middleware::Caching.enabled
    Parse::Middleware::Caching.enabled = true
    @keyspace = Parse::Cache::Keyspace.new(app_id: APP_ID, server_url: SERVER)
  end

  def teardown
    @store.clear
    Parse::Middleware::Caching.enabled = @prior_enabled
  end

  def keys
    ks = []
    @store.each_key { |k| ks << k }
    ks
  end

  # --- key shape ----------------------------------------------------------

  def test_keys_are_written_under_the_keyspace
    request(PATH)
    refute_empty keys
    keys.each { |k| assert k.start_with?(@keyspace.root_prefix), "stray key #{k}" }
  end

  def test_without_a_keyspace_legacy_shape_is_preserved
    request(PATH, keyspace: nil)
    refute_empty keys
    keys.each { |k| refute k.start_with?("parse-stack:"), "unexpected keyspaced key #{k}" }
  end

  # --- the leak this prevents --------------------------------------------

  # A master-key response bypasses ACL, CLP and protectedFields, so it is
  # strictly fuller than a session response. They must never collide.
  def test_master_and_session_requests_do_not_share_an_entry
    request(PATH, headers: { Parse::Protocol::MASTER_KEY => "mk" }, body: '{"results":["master-only"]}')
    request(PATH, headers: { Parse::Protocol::SESSION_TOKEN => "r:abc" }, body: '{"results":["session"]}')
    assert_equal 2, keys.size, "expected distinct entries per auth context"
  end

  def test_two_sessions_do_not_share_an_entry
    request(PATH, headers: { Parse::Protocol::SESSION_TOKEN => "r:aaa" })
    request(PATH, headers: { Parse::Protocol::SESSION_TOKEN => "r:bbb" })
    assert_equal 2, keys.size
  end

  def test_anonymous_and_authenticated_do_not_share_an_entry
    request(PATH)
    request(PATH, headers: { Parse::Protocol::SESSION_TOKEN => "r:aaa" })
    assert_equal 2, keys.size
  end

  def test_no_raw_session_token_appears_in_any_key
    request(PATH, headers: { Parse::Protocol::SESSION_TOKEN => "r:supersecrettoken" })
    keys.each { |k| refute_includes k, "supersecrettoken" }
  end

  # --- resource invalidation ---------------------------------------------

  # The old two-variant delete could not reach another session's entry, so a
  # write left every other user holding a stale copy until TTL. With a
  # scan-capable store the keyspace expresses that as one pattern.
  def test_write_evicts_every_auth_variant_on_a_scan_capable_store
    store = ScanCapableStore.new(@store)
    request(PATH, store: store, headers: { Parse::Protocol::SESSION_TOKEN => "r:aaa" })
    request(PATH, store: store, headers: { Parse::Protocol::SESSION_TOKEN => "r:bbb" })
    request(PATH, store: store, headers: { Parse::Protocol::MASTER_KEY => "mk" })
    assert_equal 3, keys.size

    # A non-GET write to the same resource invalidates the resource.
    request(PATH, store: store, method: :post)
    assert_empty keys, "a write must evict all auth variants of the resource"
  end

  def test_write_on_a_plain_store_still_evicts_the_nameable_variants
    request(PATH)
    assert_equal 1, keys.size
    request(PATH, method: :post)
    assert_empty keys
  end

  def test_resource_invalidation_does_not_touch_another_resource
    store = ScanCapableStore.new(@store)
    other = "/parse/classes/Other"
    request(PATH, store: store)
    request(other, store: store)
    assert_equal 2, keys.size
    request(PATH, store: store, method: :post)
    assert_equal 1, keys.size, "eviction must not reach an unrelated resource"
  end

  # --- rolling-deploy transition -----------------------------------------

  # New workers write keyspaced keys while old workers still read the legacy
  # shape, so a write served by a new worker has to evict both.
  def test_write_also_evicts_the_legacy_key_shape
    legacy_key = "https://test.parse#{PATH}"
    @store.store(legacy_key, { "headers" => {}, "body" => "stale" }, expires: 60)
    assert_includes keys, legacy_key
    request(PATH, method: :post)
    refute_includes keys, legacy_key
  end

  def test_legacy_eviction_can_be_disabled_once_old_workers_are_drained
    legacy_key = "https://test.parse#{PATH}"
    @store.store(legacy_key, { "headers" => {}, "body" => "stale" }, expires: 60)
    request(PATH, method: :post, delete_legacy_variants: false)
    assert_includes keys, legacy_key
  end

  private

  # Minimal store that adds the pattern-delete capability the middleware probes
  # for, standing in for Parse::Cache::Redis without needing a live Redis.
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

  def request(path, store: @store, keyspace: :default, headers: {}, method: :get,
              body: '{"results":[]}', delete_legacy_variants: true)
    padded = body.length >= 20 ? body : body + (" " * (20 - body.length))
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.send(method, path) do |_|
        [200,
         { "Content-Type" => "application/json", "Content-Length" => padded.bytesize.to_s },
         padded]
      end
    end
    ks = keyspace == :default ? @keyspace : keyspace
    conn = Faraday.new(url: SERVER) do |f|
      f.use Parse::Middleware::Caching, store, {
        expires: 60,
        keyspace: ks,
        delete_legacy_variants: delete_legacy_variants,
      }
      f.adapter :test, stubs
    end
    conn.send(method, path) { |req| headers.each { |k, v| req.headers[k] = v } }.body
  end
end
