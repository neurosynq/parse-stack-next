require_relative "../../test_helper"

class CacheRedisWrapperTest < Minitest::Test
  def test_wrapper_exposes_moneta_interface
    wrapper = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", namespace: "x")
    assert_respond_to wrapper, :[]
    assert_respond_to wrapper, :key?
    assert_respond_to wrapper, :store
    assert_respond_to wrapper, :delete
  end

  def test_namespace_normalization_strips_trailing_colon
    w = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", namespace: "app_x:")
    assert_equal "app_x", w.namespace
  end

  def test_empty_namespace_is_nil
    w = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", namespace: "")
    assert_nil w.namespace
  end

  def test_nil_namespace_is_nil
    w = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", namespace: nil)
    assert_nil w.namespace
  end

  def test_pool_size_default_is_five
    w = Parse::Cache::Redis.new(url: "redis://localhost:6379/0")
    assert_equal 5, w.pool_size
  end

  def test_pool_size_override
    w = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", pool_size: 12)
    assert_equal 12, w.pool_size
  end

  def test_wrapper_passes_arg_check_to_client_cache_option
    init = {
      server_url: "http://example.com/parse",
      app_id: "abc",
      api_key: "def",
      cache: Parse::Cache::Redis.new(url: "redis://localhost:6379/0", namespace: "scoped"),
      expires: 10,
    }
    # Should not raise — wrapper responds to all 4 Moneta methods.
    assert Parse.setup(init)
  end

  def test_pool_requires_block
    assert_raises(ArgumentError) { Parse::Cache::Pool.new(size: 2) }
  end

  def test_pool_delegates_to_backend_under_lock
    backend = Moneta.new(:Memory)
    pool = Parse::Cache::Pool.new(size: 3) { backend }

    pool.store("k", "v", {})
    assert_equal "v", pool["k"]
    assert pool.key?("k")
    pool.delete("k")
    refute pool.key?("k")
  end

  def test_pool_clear_flushes_backend
    backend = Moneta.new(:Memory)
    pool = Parse::Cache::Pool.new(size: 2) { backend }

    pool.store("a", "1", {})
    pool.store("b", "2", {})
    assert pool.key?("a")

    assert_same pool, pool.clear, "clear should return self for chaining"
    refute pool.key?("a")
    refute pool.key?("b")
  end

  def test_wrapper_responds_to_clear
    # Build without connecting — we just want to verify the method exists
    # on the Moneta surface so Parse::Client#clear_cache! does not raise.
    w = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", namespace: "x")
    assert_respond_to w, :clear
  end

  def test_wrapper_clear_returns_self_for_chaining
    # Use a Memory-backed Pool with a stub backend that mimics Redis
    # SCAN/DEL so we can exercise the namespace-scoped clear path
    # without needing a live Redis.
    w = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", namespace: "x")
    fake_redis = Class.new do
      def scan(_cursor, **_opts); ["0", []]; end
      def del(*_keys); 0; end
    end.new
    backend = Moneta.new(:Memory)
    backend.define_singleton_method(:backend) { fake_redis }
    w.instance_variable_set(:@pool, Parse::Cache::Pool.new(size: 1) { backend })
    assert_same w, w.clear, "Parse::Cache::Redis#clear should return self for chaining"
  end
end
