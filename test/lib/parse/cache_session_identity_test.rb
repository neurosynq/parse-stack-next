# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "moneta"

# SEC-16: a cached response for a session-authenticated read was served by
# the caching middleware without contacting Parse Server, so once the session
# was revoked (logout, Session#destroy, logout_all!, a password change) or the
# user lost a role, the token kept reading the cached rows until the entry
# expired. The fix keeps session reads out of the response cache by default,
# whichever way the session reached the request (explicit `session_token:`,
# `Parse.with_session`, or a client bound to a session), while master-key and
# anonymous reads cache as before.
class CacheSessionIdentityTest < Minitest::Test
  include Parse::Protocol

  SERVER = "https://test.parse/parse"
  PATH = "/parse/classes/Post"

  def setup
    @store = Moneta.new(:Memory, expires: true)
    @prior_enabled = Parse::Middleware::Caching.enabled
    @opt_in = Parse::Middleware::Caching.respond_to?(:cache_session_requests=)
    @prior_session = Parse::Middleware::Caching.cache_session_requests if @opt_in
    Parse::Middleware::Caching.enabled = true
    Parse::Middleware::Caching.cache_session_requests = false if @opt_in
    @calls = Hash.new(0)
  end

  def teardown
    @store.clear
    Parse::Middleware::Caching.enabled = @prior_enabled
    Parse::Middleware::Caching.cache_session_requests = @prior_session if @opt_in
  end

  def stubs
    calls = @calls
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(PATH) do |env|
        calls[env.request_headers[SESSION_TOKEN] || :none] += 1
        body = '{"results":[{"objectId":"p1"}]}'
        [200, { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }, body]
      end
      stub.put("#{PATH}/p1") do
        body = '{"updatedAt":"2026-01-01T00:00:00.000Z"}'
        [200, { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }, body]
      end
    end
  end

  # Middleware-level request with fixed headers.
  def raw_get(headers)
    s = stubs
    conn = Faraday.new(url: SERVER) do |f|
      f.use Parse::Middleware::Caching, @store, { expires: 60 }
      f.adapter :test, s
    end
    resp = conn.get(PATH) { |req| headers.each { |k, v| req.headers[k] = v } }
    resp.headers["X-Cache-Response"] == "true"
  end

  def base_headers
    { APP_ID => "app", API_KEY => "rest" }
  end

  def test_session_read_is_not_served_from_cache_by_default
    h = base_headers.merge(SESSION_TOKEN => "r:alice")
    refute raw_get(h)
    refute raw_get(h), "a session read must reach Parse Server, so a revoked token stops reading"
    assert_equal 2, @calls["r:alice"]
  end

  def test_master_and_anonymous_reads_still_cache
    master = base_headers.merge(MASTER_KEY => "mk")
    refute raw_get(master)
    assert raw_get(master)
    anon = base_headers
    refute raw_get(anon)
    assert raw_get(anon)
  end

  def test_session_caching_is_an_explicit_opt_in
    Parse::Middleware::Caching.cache_session_requests = true
    h = base_headers.merge(SESSION_TOKEN => "r:alice")
    refute raw_get(h)
    assert raw_get(h)
    assert_equal 1, @calls["r:alice"]
  end

  # A full Parse::Client with a response cache, its Faraday adapter swapped
  # for test stubs so every request is counted.
  def cached_client(**extra)
    client = Parse::Client.new(server_url: SERVER, app_id: "app", api_key: "rest", master_key: "mk",
                               cache: @store, expires: 60, **extra)
    client.instance_variable_get(:@conn).builder.adapter :test, stubs
    client
  end

  def cached_get(client, **opts)
    capture_io { client.request(:get, "classes/Post", opts: { cache: true }.merge(opts)) }
  end

  def test_explicit_session_token_read_is_not_cached
    client = nil
    capture_io { client = cached_client }
    2.times { cached_get(client, session_token: "r:alice") }
    assert_equal 2, @calls["r:alice"]
  end

  def test_ambient_with_session_read_is_not_cached
    client = nil
    capture_io { client = cached_client }
    2.times { Parse.with_session("r:alice") { cached_get(client) } }
    assert_equal 2, @calls["r:alice"]
  end

  def test_client_bound_session_read_is_not_cached
    client = nil
    capture_io { client = cached_client(master_key: nil, session_token: "r:alice") }
    2.times { cached_get(client) }
    assert_equal 2, @calls["r:alice"]
  end

  def test_master_client_read_still_caches
    client = nil
    capture_io { client = cached_client }
    2.times { cached_get(client, use_master_key: true) }
    assert_equal 1, @calls[:none]
  end

  def test_session_write_still_retires_master_cached_reads
    master = base_headers.merge(MASTER_KEY => "mk")
    refute raw_get(master)
    assert raw_get(master)
    s = stubs
    conn = Faraday.new(url: SERVER) do |f|
      f.use Parse::Middleware::Caching, @store, { expires: 60 }
      f.adapter :test, s
    end
    conn.put("#{PATH}/p1", '{"title":"x"}') do |req|
      base_headers.merge(SESSION_TOKEN => "r:alice").each { |k, v| req.headers[k] = v }
    end
    refute raw_get(master), "a write made with a session still retires cached class reads"
  end
end
