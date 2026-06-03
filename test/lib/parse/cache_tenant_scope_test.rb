# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "moneta"
require "active_support/notifications"

# Unit tests for the v5.1 tenant-aware cache namespacing surface added
# to Parse::Middleware::Caching. Drives the middleware directly with
# Faraday's test adapter so we can assert on the actual keys written
# and read, without going near a real Parse Server.
class CacheTenantScopeTest < Minitest::Test
  def setup
    @store = Moneta.new(:Memory, expires: true)
    @prior_enabled = Parse::Middleware::Caching.enabled
    Parse::Middleware::Caching.enabled = true
  end

  def teardown
    @store.clear
    Parse::Middleware::Caching.enabled = @prior_enabled
  end

  # ---- ambient accessor / block helper --------------------------------

  def test_current_cache_tenant_default_is_nil
    assert_nil Parse.current_cache_tenant
  end

  def test_with_cache_tenant_sets_and_restores
    assert_nil Parse.current_cache_tenant
    Parse.with_cache_tenant("tenant_x") do
      assert_equal "tenant_x", Parse.current_cache_tenant
    end
    assert_nil Parse.current_cache_tenant
  end

  def test_with_cache_tenant_restores_on_exception
    Parse.with_cache_tenant("outer") do
      assert_raises(RuntimeError) do
        Parse.with_cache_tenant("inner") do
          raise "boom"
        end
      end
      assert_equal "outer", Parse.current_cache_tenant
    end
    assert_nil Parse.current_cache_tenant
  end

  def test_with_cache_tenant_coerces_symbol_to_string
    Parse.with_cache_tenant(:tenant_y) do
      assert_equal "tenant_y", Parse.current_cache_tenant
    end
  end

  def test_with_cache_tenant_nil_clears_ambient_scope
    Parse.with_cache_tenant("outer") do
      Parse.with_cache_tenant(nil) do
        assert_nil Parse.current_cache_tenant
      end
      assert_equal "outer", Parse.current_cache_tenant
    end
  end

  def test_with_cache_tenant_empty_string_is_treated_as_nil
    Parse.with_cache_tenant("") do
      assert_nil Parse.current_cache_tenant
    end
  end

  def test_with_cache_tenant_refuses_colon_in_scope
    # `:` would collapse the key segmentation since the middleware
    # composes `T:<tenant>:<rest>`. Refuse at the boundary.
    err = assert_raises(ArgumentError) do
      Parse.with_cache_tenant("a:T:b") { flunk "should not run" }
    end
    assert_match(/key-segment-delimiter/, err.message)
  end

  def test_with_cache_tenant_refuses_whitespace_in_scope
    assert_raises(ArgumentError) { Parse.with_cache_tenant("tenant a") { flunk } }
    assert_raises(ArgumentError) { Parse.with_cache_tenant("tenant\nx") { flunk } }
  end

  def test_with_cache_tenant_accepts_underscore_and_hyphen
    Parse.with_cache_tenant("tenant-abc_123") do
      assert_equal "tenant-abc_123", Parse.current_cache_tenant
    end
  end

  def test_nested_with_session_and_with_cache_tenant_restore_correctly_on_raise
    assert_raises(RuntimeError) do
      Parse.with_cache_tenant("outer") do
        Parse.with_session("r:token") do
          raise "boom"
        end
      end
    end
    assert_nil Parse.current_cache_tenant
    assert_nil Parse.current_session_token
  end

  # TODO #5 — Fiber/Thread isolation. The Fiber-local storage is by
  # design scoped to the Fiber that set it; other Fibers (and other
  # Threads, which carry their own root Fiber) MUST NOT observe the
  # ambient set inside an unrelated context. Without this property,
  # request-scoped tenant scopes would bleed across concurrent
  # requests in any Fiber-per-request web server (Falcon, async-rack)
  # and across threads in any Threaded-per-request server (Puma).

  def test_with_cache_tenant_does_not_leak_across_threads
    # Queue-gated synchronization rather than sleep-based ordering:
    # the setter signals "scope established" via `setter_ready`, the
    # observer reads + signals back via `observer_done`. Without the
    # explicit gating, a slow CI box could schedule the observer
    # AFTER the setter's `with_cache_tenant` block exits — the
    # observer would still see nil (correct outcome) but for the
    # wrong reason ("observed after restore", not "isolated").
    setter_ready  = Queue.new
    observer_done = Queue.new
    leaked = :uninitialized

    setter = Thread.new do
      Parse.with_cache_tenant("thread-a") do
        setter_ready << :scope_set
        observer_done.pop  # block until observer has read
      end
    end

    observer = Thread.new do
      # Block until the setter has actually established its scope.
      assert_equal :scope_set, setter_ready.pop(timeout: 5)
      leaked = Parse.current_cache_tenant
      observer_done << :read
    end

    main_observed = Parse.current_cache_tenant  # main thread, never set
    setter.join
    observer.join

    assert_nil leaked, "Thread B must NOT see Thread A's cache tenant scope (got #{leaked.inspect})"
    assert_nil main_observed, "Main thread must NOT see a worker thread's scope"
    assert_nil Parse.current_cache_tenant, "Scope must be cleared after setter thread finishes"
  end

  def test_with_cache_tenant_does_not_leak_across_fibers
    setter_fiber = Fiber.new do
      Parse.with_cache_tenant("fiber-a") do
        # Suspend mid-block; main resumes and inspects.
        Fiber.yield Parse.current_cache_tenant
        # Resumed — verify ours is still set inside this fiber.
        Fiber.yield Parse.current_cache_tenant
      end
    end

    inside_setter   = setter_fiber.resume
    observer_fiber  = Fiber.new { Parse.current_cache_tenant }
    inside_observer = observer_fiber.resume
    inside_setter_again = setter_fiber.resume

    assert_equal "fiber-a", inside_setter,
      "Setter fiber must see its own scope"
    assert_nil inside_observer,
      "Observer fiber must NOT see the setter fiber's scope"
    assert_equal "fiber-a", inside_setter_again,
      "Setter fiber's scope must persist across Fiber.yield round-trips"
  end

  def test_with_cache_tenant_runs_ensure_even_when_thread_killed
    # Thread#kill runs `ensure` clauses on its way down. The Fiber-
    # local restore in `with_cache_tenant`'s ensure block must fire
    # so a killed worker doesn't leave a stale scope on its root
    # Fiber (which would matter if the thread is recycled — Puma
    # recycles threads from a pool).
    cleanup_observed = nil
    t = Thread.new do
      Parse.with_cache_tenant("kill-me") do
        # Signal that we're inside the block, then sleep waiting
        # for the kill.
        Thread.current[:inside] = true
        sleep 5
      end
    rescue StandardError
      # Thread#kill in some Ruby versions raises here; absorb so the
      # outer join can capture the ensure-clause result.
    ensure
      cleanup_observed = Parse.current_cache_tenant
    end

    # Wait for the block to actually be inside.
    sleep 0.01 until t[:inside]
    t.kill
    t.join(1.0)

    # The thread's ensure block ran after kill; the Fiber-local
    # restore inside `with_cache_tenant` set `current_cache_tenant`
    # back to its prior value (nil — outer scope never set one).
    assert_nil cleanup_observed,
      "with_cache_tenant's ensure must restore on Thread#kill — observed: #{cleanup_observed.inspect}"
  end

  # ---- cache-key composition --------------------------------------------

  def test_no_tenant_key_matches_legacy_shape
    # No tenant + no namespace → key is just the URL string.
    body = make_request("/classes/Post", store: @store)
    refute_empty body
    # Key for an anonymous GET is the bare URL string.
    keys = @store.each_key.to_a
    assert_equal 1, keys.length, "expected one cache entry, got #{keys.inspect}"
    assert keys.first.include?("/classes/Post"), "key should include the URL path: #{keys.first}"
    refute keys.first.start_with?("T:"), "no tenant set should not prefix T:"
  end

  def test_tenant_only_prefixes_key_with_t
    Parse.with_cache_tenant("tenant_x") do
      make_request("/classes/Post", store: @store)
    end
    key = @store.each_key.to_a.first
    assert key.start_with?("T:tenant_x:"), "expected T:tenant_x: prefix, got #{key.inspect}"
  end

  def test_tenant_with_namespace_composes_namespace_outside_tenant
    Parse.with_cache_tenant("tenant_x") do
      make_request("/classes/Post", store: @store, namespace: "app_a")
    end
    key = @store.each_key.to_a.first
    # Final shape: <namespace>:T:<tenant>:<url> — namespace outermost
    # so a SCAN over <namespace>:* still evicts the whole app cleanly.
    assert key.start_with?("app_a:T:tenant_x:"), key.inspect
  end

  def test_tenant_isolates_cached_responses
    # Tenant A writes a value; tenant B reads — must miss because the
    # key differs.
    Parse.with_cache_tenant("tenant_a") do
      make_request("/classes/Post", store: @store, fixture_body: '{"results":["A"]}')
    end
    Parse.with_cache_tenant("tenant_b") do
      body = make_request("/classes/Post", store: @store, fixture_body: '{"results":["B"]}')
      assert_includes body, '"B"', "tenant_b must not see tenant_a's cached response"
    end
    keys = @store.each_key.to_a
    assert_equal 2, keys.length, "expected two distinct cache entries (one per tenant), got #{keys}"
    assert keys.any? { |k| k.start_with?("T:tenant_a:") }
    assert keys.any? { |k| k.start_with?("T:tenant_b:") }
  end

  def test_no_tenant_does_not_see_tenant_scoped_entry
    # Tenant A writes; an unscoped request must NOT see it (different key).
    Parse.with_cache_tenant("tenant_a") do
      make_request("/classes/Post", store: @store, fixture_body: '{"results":["A"]}')
    end
    body = make_request("/classes/Post", store: @store, fixture_body: '{"results":["unscoped"]}')
    assert_includes body, '"unscoped"',
      "unscoped request must not be served from a tenant-scoped cache entry"
  end

  # ---- AS::N payload carries :cache_tenant -----------------------------

  def test_instrument_payload_includes_cache_tenant
    captured = []
    sub = ActiveSupport::Notifications.subscribe(/parse\.cache\./) { |*args| captured << args.last }
    begin
      Parse.with_cache_tenant("tenant_x") do
        make_request("/classes/Post", store: @store)
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
    refute_empty captured
    assert captured.all? { |p| p[:cache_tenant] == "tenant_x" },
      "every cache event under a tenant scope must carry :cache_tenant"
  end

  def test_instrument_payload_cache_tenant_is_nil_when_unset
    captured = []
    sub = ActiveSupport::Notifications.subscribe(/parse\.cache\./) { |*args| captured << args.last }
    begin
      make_request("/classes/Post", store: @store)
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
    refute_empty captured
    assert captured.all? { |p| p[:cache_tenant].nil? }
  end

  private

  # Build a Faraday connection with just the Caching middleware + a
  # test adapter that returns a fixed JSON body. Issues a GET and
  # returns the response body.
  def make_request(path, store:, namespace: nil, fixture_body: '{"results":[]}')
    # Pad the body up to >= 20 bytes — the cache middleware refuses to
    # store responses smaller than 20 bytes (assumes error/empty
    # result). Content-Length must also be set for the middleware to
    # consider the response cacheable.
    body = fixture_body.length >= 20 ? fixture_body : fixture_body + (" " * (20 - fixture_body.length))
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(path) do |_|
        [200,
         { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s },
         body]
      end
    end
    conn = Faraday.new(url: "https://test.parse/parse") do |f|
      f.use Parse::Middleware::Caching, store, { expires: 60, namespace: namespace }
      f.adapter :test, stubs
    end
    conn.get(path).body
  end
end
