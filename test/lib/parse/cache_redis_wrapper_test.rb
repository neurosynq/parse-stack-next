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

  # SECURITY: cached values must be serialized as JSON, never Marshal, so a
  # cache hit can never `Marshal.load` attacker-influenced Redis bytes into a
  # gadget object graph (RCE-if-cache-compromised). The wrapper disables
  # Moneta's value serializer and does its own JSON (de)serialization.
  def test_values_are_json_encoded_not_marshal
    w = Parse::Cache::Redis.new(url: "redis://localhost:6379/0")
    payload = { "headers" => { "Content-Type" => "application/json" },
                "body" => '{"results":[1,2,3]}' }
    encoded = w.send(:encode_value, payload)
    assert_kind_of String, encoded
    refute encoded.b.start_with?("\x04\b".b),
      "value must not be a Marshal stream (\\x04\\x08 magic)"
    assert_equal payload, JSON.parse(encoded), "value must be JSON-decodable"
    assert_equal payload, w.send(:decode_value, encoded), "JSON value must round-trip"
  end

  def test_forces_value_serializer_nil_even_when_caller_passes_one
    # A caller-supplied serializer must not be able to re-enable Marshal on the
    # value path. The wrapper forces value_serializer: nil.
    w = Parse::Cache::Redis.new(url: "redis://localhost:6379/0", serializer: :marshal)
    opts = w.instance_variable_get(:@moneta_options)
    assert_nil opts[:value_serializer],
      "wrapper must force value_serializer: nil to keep Marshal off the value path"
  end

  def test_decode_value_treats_hostile_marshal_bytes_as_miss
    w = Parse::Cache::Redis.new(url: "redis://localhost:6379/0")
    hostile = Marshal.dump([1, 2, 3]) # non-JSON bytes an attacker could plant
    assert_nil w.send(:decode_value, hostile),
      "undecodable (e.g. Marshal) bytes must decode to nil, never be Marshal.load-ed"
    assert_nil w.send(:decode_value, nil), "a cache miss must decode to nil"
  end
end
