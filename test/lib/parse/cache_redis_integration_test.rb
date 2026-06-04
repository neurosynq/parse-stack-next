require_relative "../../test_helper_integration"
require "minitest/autorun"
require "moneta"

class RedisCacheTestProduct < Parse::Object
  parse_class "RedisCacheTestProduct"
  property :name, :string
  property :price, :float
end

class CacheRedisIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  REDIS_URL = ENV["PARSE_TEST_REDIS_URL"] || "redis://localhost:29379/0"
  CACHE_EXPIRES = 30

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    skip "Redis not reachable at #{REDIS_URL}" unless redis_reachable?

    super

    @original_caching_enabled = Parse::Middleware::Caching.enabled
    Parse::Middleware::Caching.enabled = true

    @probe = Moneta.new(:Redis, url: REDIS_URL)
    @probe.clear

    @client_a = Parse::Client.new(
      server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse",
      app_id: ENV["PARSE_TEST_APP_ID"] || "psnextItAppId",
      api_key: ENV["PARSE_TEST_API_KEY"] || "psnext-it-rest-key",
      master_key: ENV["PARSE_TEST_MASTER_KEY"] || "psnextItMasterKey",
      cache: REDIS_URL,
      expires: CACHE_EXPIRES,
    )

    @client_b = Parse::Client.new(
      server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse",
      app_id: ENV["PARSE_TEST_APP_ID"] || "psnextItAppId",
      api_key: ENV["PARSE_TEST_API_KEY"] || "psnext-it-rest-key",
      master_key: ENV["PARSE_TEST_MASTER_KEY"] || "psnextItMasterKey",
      cache: REDIS_URL,
      expires: CACHE_EXPIRES,
    )
  end

  def teardown
    @probe&.clear
    @probe&.close
    Parse::Middleware::Caching.enabled = @original_caching_enabled unless @original_caching_enabled.nil?
    super
  end

  def test_redis_cache_url_form_accepted
    refute_nil @client_a.cache, "Cache store should be set when redis:// URL is passed"
    assert_respond_to @client_a.cache, :store
    assert_respond_to @client_a.cache, :[]
  end

  def test_get_request_writes_to_redis
    created = @client_a.create_object("RedisCacheTestProduct", { name: "Redis Persist Widget", price: 12.50 })
    object_id = created.result["objectId"]

    @client_a.fetch_object("RedisCacheTestProduct", object_id)

    cache_key_fragment = "/classes/RedisCacheTestProduct/#{object_id}"
    matching_keys = @probe.each_key.select { |k| k.to_s.include?(cache_key_fragment) }
    refute_empty matching_keys, "GET response should land in Redis under a key containing #{cache_key_fragment}"
  end

  def test_cache_survives_across_client_instances
    created = @client_a.create_object("RedisCacheTestProduct", { name: "Cross-Client Widget", price: 7.25 })
    object_id = created.result["objectId"]

    @client_a.fetch_object("RedisCacheTestProduct", object_id)

    response = @client_b.fetch_object("RedisCacheTestProduct", object_id)

    assert_equal "true", response.headers[Parse::Middleware::Caching::CACHE_RESPONSE_HEADER],
                 "Second client should serve from the shared Redis cache"
    assert_equal object_id, response.result["objectId"]
    assert_equal "Cross-Client Widget", response.result["name"]
  end

  def test_cache_invalidates_on_update
    created = @client_a.create_object("RedisCacheTestProduct", { name: "Invalidate Me", price: 1.00 })
    object_id = created.result["objectId"]

    @client_a.fetch_object("RedisCacheTestProduct", object_id)
    cache_key_fragment = "/classes/RedisCacheTestProduct/#{object_id}"
    assert @probe.each_key.any? { |k| k.to_s.include?(cache_key_fragment) },
           "Cache should contain entry before update"

    @client_a.update_object("RedisCacheTestProduct", object_id, { name: "Invalidated", price: 2.00 })

    refute @probe.each_key.any? { |k| k.to_s.include?(cache_key_fragment) },
           "Cache entry should be deleted after PUT to the same resource"
  end

  def test_namespaced_caches_dont_collide
    client_ns_a = Parse::Client.new(
      server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse",
      app_id: ENV["PARSE_TEST_APP_ID"] || "psnextItAppId",
      api_key: ENV["PARSE_TEST_API_KEY"] || "psnext-it-rest-key",
      master_key: ENV["PARSE_TEST_MASTER_KEY"] || "psnextItMasterKey",
      cache: REDIS_URL,
      cache_namespace: "ns_a",
      expires: CACHE_EXPIRES,
    )
    client_ns_b = Parse::Client.new(
      server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse",
      app_id: ENV["PARSE_TEST_APP_ID"] || "psnextItAppId",
      api_key: ENV["PARSE_TEST_API_KEY"] || "psnext-it-rest-key",
      master_key: ENV["PARSE_TEST_MASTER_KEY"] || "psnextItMasterKey",
      cache: REDIS_URL,
      cache_namespace: "ns_b",
      expires: CACHE_EXPIRES,
    )

    created = client_ns_a.create_object("RedisCacheTestProduct", { name: "Namespaced", price: 9.99 })
    object_id = created.result["objectId"]

    # Prime ns_a's cache.
    client_ns_a.fetch_object("RedisCacheTestProduct", object_id)

    ns_a_keys = @probe.each_key.select { |k| k.to_s.start_with?("ns_a:") }
    refute_empty ns_a_keys, "ns_a should have written namespaced keys"
    refute @probe.each_key.any? { |k| k.to_s.start_with?("ns_b:") },
           "ns_b should not have any cache entries yet"

    # ns_b reads the same resource — must MISS because the namespace prefix differs.
    response = client_ns_b.fetch_object("RedisCacheTestProduct", object_id)
    refute_equal "true", response.headers[Parse::Middleware::Caching::CACHE_RESPONSE_HEADER],
                 "ns_b should NOT serve from ns_a's cached entry"

    # Now ns_b has its own namespaced entry.
    ns_b_keys = @probe.each_key.select { |k| k.to_s.start_with?("ns_b:") }
    refute_empty ns_b_keys, "ns_b should have its own namespaced cache entry"

    # And an update through ns_b should leave ns_a's entry intact.
    client_ns_b.update_object("RedisCacheTestProduct", object_id, { name: "Touched by B", price: 11.00 })
    refute @probe.each_key.any? { |k| k.to_s.start_with?("ns_b:") && k.to_s.include?(object_id) },
           "ns_b's own entry should be invalidated by ns_b's PUT"
    assert @probe.each_key.any? { |k| k.to_s.start_with?("ns_a:") && k.to_s.include?(object_id) },
           "ns_a's entry must survive a PUT made through ns_b (no cross-namespace blast)"
  end

  def test_same_namespace_still_shares
    shared_a = Parse::Client.new(
      server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse",
      app_id: ENV["PARSE_TEST_APP_ID"] || "psnextItAppId",
      api_key: ENV["PARSE_TEST_API_KEY"] || "psnext-it-rest-key",
      master_key: ENV["PARSE_TEST_MASTER_KEY"] || "psnextItMasterKey",
      cache: REDIS_URL,
      cache_namespace: "shared_app",
      expires: CACHE_EXPIRES,
    )
    shared_b = Parse::Client.new(
      server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse",
      app_id: ENV["PARSE_TEST_APP_ID"] || "psnextItAppId",
      api_key: ENV["PARSE_TEST_API_KEY"] || "psnext-it-rest-key",
      master_key: ENV["PARSE_TEST_MASTER_KEY"] || "psnextItMasterKey",
      cache: REDIS_URL,
      cache_namespace: "shared_app",
      expires: CACHE_EXPIRES,
    )

    created = shared_a.create_object("RedisCacheTestProduct", { name: "Shared", price: 3.33 })
    object_id = created.result["objectId"]

    shared_a.fetch_object("RedisCacheTestProduct", object_id)
    response = shared_b.fetch_object("RedisCacheTestProduct", object_id)

    assert_equal "true", response.headers[Parse::Middleware::Caching::CACHE_RESPONSE_HEADER],
                 "Two clients sharing a namespace must share cache entries"
  end

  def test_redis_wrapper_auto_threads_namespace
    wrapper = Parse::Cache::Redis.new(url: REDIS_URL, namespace: "wrapper_ns", pool_size: 4)
    client = Parse::Client.new(
      server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse",
      app_id: ENV["PARSE_TEST_APP_ID"] || "psnextItAppId",
      api_key: ENV["PARSE_TEST_API_KEY"] || "psnext-it-rest-key",
      master_key: ENV["PARSE_TEST_MASTER_KEY"] || "psnextItMasterKey",
      cache: wrapper,
      expires: CACHE_EXPIRES,
    )

    created = client.create_object("RedisCacheTestProduct", { name: "Wrapper Widget", price: 4.50 })
    object_id = created.result["objectId"]

    client.fetch_object("RedisCacheTestProduct", object_id)

    namespaced_keys = @probe.each_key.select { |k| k.to_s.start_with?("wrapper_ns:") }
    refute_empty namespaced_keys, "Wrapper namespace must be forwarded to the caching middleware automatically"
  end

  def test_pool_handles_concurrent_access
    wrapper = Parse::Cache::Redis.new(url: REDIS_URL, namespace: "pool_test", pool_size: 4, pool_timeout: 5)

    created = @client_a.create_object("RedisCacheTestProduct", { name: "Concurrent Widget", price: 1.11 })
    object_id = created.result["objectId"]

    # Seed wrapper's cache so subsequent reads hit (key? + [] = 2 checkouts per hit).
    wrapper.store("seed:#{object_id}", { headers: {}, body: "x" }, expires: CACHE_EXPIRES)

    errors = []
    threads = 20.times.map do
      Thread.new do
        begin
          50.times do
            wrapper.key?("seed:#{object_id}")
            _ = wrapper["seed:#{object_id}"]
          end
        rescue => e
          errors << e
        end
      end
    end
    threads.each(&:join)
    assert_empty errors, "Pool should serve 20 concurrent threads without errors: #{errors.first&.message}"
  ensure
    wrapper&.close
  end

  def test_client_clear_cache_through_wrapper
    wrapper = Parse::Cache::Redis.new(url: REDIS_URL, namespace: "clear_test", pool_size: 2)
    client = Parse::Client.new(
      server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:29337/parse",
      app_id: ENV["PARSE_TEST_APP_ID"] || "psnextItAppId",
      api_key: ENV["PARSE_TEST_API_KEY"] || "psnext-it-rest-key",
      master_key: ENV["PARSE_TEST_MASTER_KEY"] || "psnextItMasterKey",
      cache: wrapper,
      expires: CACHE_EXPIRES,
    )

    created = client.create_object("RedisCacheTestProduct", { name: "Clear Me", price: 5.55 })
    object_id = created.result["objectId"]
    client.fetch_object("RedisCacheTestProduct", object_id)

    assert @probe.each_key.any? { |k| k.to_s.start_with?("clear_test:") },
           "Wrapper should have written a namespaced cache entry"

    # Seed an unrelated tenant's key so the namespace-scoped blast-radius
    # contract (clear walks `<namespace>:*` via SCAN+DEL when a namespace
    # is configured; other tenants on the same DB are untouched) is
    # codified. To opt into a wide FLUSHDB, callers can invoke
    # Parse::Cache::Redis#flush_db! explicitly.
    @probe.store("other_tenant:keep_me", "1", expires: CACHE_EXPIRES)
    assert @probe.key?("other_tenant:keep_me")

    # Must NOT raise NoMethodError — wrapper exposes :clear.
    client.clear_cache!

    refute @probe.each_key.any? { |k| k.to_s.start_with?("clear_test:") },
           "client.clear_cache! through the wrapper should flush the namespace"
    assert @probe.key?("other_tenant:keep_me"),
           "namespace-scoped clear must leave other tenants intact"
  ensure
    wrapper&.close
  end

  def test_cache_emits_active_support_notifications
    events = []
    sub = ActiveSupport::Notifications.subscribe(/^parse\.cache\./) do |name, _start, _finish, _id, payload|
      events << [name, payload]
    end

    created = @client_a.create_object("RedisCacheTestProduct", { name: "Instrumented", price: 8.88 })
    object_id = created.result["objectId"]

    # First fetch -> miss + store
    @client_a.fetch_object("RedisCacheTestProduct", object_id)
    # Second fetch -> hit
    @client_a.fetch_object("RedisCacheTestProduct", object_id)
    # Update -> delete
    @client_a.update_object("RedisCacheTestProduct", object_id, { name: "Updated" })

    event_names = events.map(&:first).uniq
    assert_includes event_names, "parse.cache.miss"
    assert_includes event_names, "parse.cache.store"
    assert_includes event_names, "parse.cache.hit"
    assert_includes event_names, "parse.cache.delete"

    events.each do |name, payload|
      refute payload.key?(:cache_key), "AS::N payload must NEVER include :cache_key (side-channel)"
      refute payload[:url_path].to_s.include?("?"), "url_path must strip query string"
    end

    store_event = events.find { |n, _| n == "parse.cache.store" }
    refute_nil store_event
    assert_kind_of Float, store_event[1][:duration_ms]
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  private

  def redis_reachable?
    require "redis"
    client = Redis.new(url: REDIS_URL, connect_timeout: 1, timeout: 1)
    client.ping == "PONG"
  rescue LoadError, StandardError
    false
  ensure
    client&.close rescue nil
  end
end
