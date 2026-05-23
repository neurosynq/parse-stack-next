require_relative "../../test_helper"

class TestClientAdapter < Minitest::Test
  def setup
    @base_options = {
      server_url: "http://localhost:1337/parse",
      app_id: "test_app_id",
      api_key: "test_api_key",
    }
    # Clear existing clients before each test
    Parse::Client.clients.clear
  end

  def teardown
    # Clean up clients after each test
    Parse::Client.clients.clear
  end

  # Helper to get the adapter class from a client's Faraday connection
  def get_adapter_class(client)
    conn = client.instance_variable_get(:@conn)
    # Faraday's builder stores the adapter - get the klass from the handler
    conn.builder.adapter.klass
  end

  def test_default_uses_net_http_persistent
    client = Parse::Client.new(@base_options)
    adapter_class = get_adapter_class(client)

    assert_equal Faraday::Adapter::NetHttpPersistent, adapter_class,
      "Default adapter should be Faraday::Adapter::NetHttpPersistent"
  end

  def test_connection_pooling_false_uses_default_faraday_adapter
    options = @base_options.merge(connection_pooling: false)
    client = Parse::Client.new(options)
    adapter_class = get_adapter_class(client)

    assert_equal Faraday::Adapter::NetHttp, adapter_class,
      "connection_pooling: false should use Faraday::Adapter::NetHttp"
  end

  def test_explicit_adapter_takes_priority
    options = @base_options.merge(adapter: :test)
    client = Parse::Client.new(options)
    adapter_class = get_adapter_class(client)

    assert_equal Faraday::Adapter::Test, adapter_class,
      "Explicit :adapter option should take priority"
  end

  def test_explicit_adapter_overrides_connection_pooling_true
    # Even if connection_pooling is explicitly true, adapter should win
    options = @base_options.merge(adapter: :test, connection_pooling: true)
    client = Parse::Client.new(options)
    adapter_class = get_adapter_class(client)

    assert_equal Faraday::Adapter::Test, adapter_class,
      "Explicit :adapter should override connection_pooling: true"
  end

  def test_explicit_adapter_overrides_connection_pooling_false
    # Use :test adapter since :excon requires the excon gem
    options = @base_options.merge(adapter: :test, connection_pooling: false)
    client = Parse::Client.new(options)
    adapter_class = get_adapter_class(client)

    assert_equal Faraday::Adapter::Test, adapter_class,
      "Explicit :adapter should override connection_pooling: false"
  end

  def test_connection_pooling_nil_uses_default_persistent
    # nil should be treated as "not specified", defaulting to pooling
    options = @base_options.merge(connection_pooling: nil)
    client = Parse::Client.new(options)
    adapter_class = get_adapter_class(client)

    assert_equal Faraday::Adapter::NetHttpPersistent, adapter_class,
      "connection_pooling: nil should default to Faraday::Adapter::NetHttpPersistent"
  end

  def test_parse_setup_uses_net_http_persistent_by_default
    Parse.setup(@base_options)
    client = Parse.client

    adapter_class = get_adapter_class(client)
    assert_equal Faraday::Adapter::NetHttpPersistent, adapter_class,
      "Parse.setup should use Faraday::Adapter::NetHttpPersistent by default"
  end

  def test_parse_setup_with_connection_pooling_false
    options = @base_options.merge(connection_pooling: false)
    Parse.setup(options)
    client = Parse.client

    adapter_class = get_adapter_class(client)
    assert_equal Faraday::Adapter::NetHttp, adapter_class,
      "Parse.setup with connection_pooling: false should use Faraday::Adapter::NetHttp"
  end

  def test_connection_pooling_hash_uses_net_http_persistent
    # Hash options should enable pooling with net_http_persistent
    options = @base_options.merge(connection_pooling: { pool_size: 5, idle_timeout: 30 })
    client = Parse::Client.new(options)
    adapter_class = get_adapter_class(client)

    assert_equal Faraday::Adapter::NetHttpPersistent, adapter_class,
      "connection_pooling: { ... } should use Faraday::Adapter::NetHttpPersistent"
  end

  def test_connection_pooling_empty_hash_uses_net_http_persistent
    # Empty hash should still enable pooling
    options = @base_options.merge(connection_pooling: {})
    client = Parse::Client.new(options)
    adapter_class = get_adapter_class(client)

    assert_equal Faraday::Adapter::NetHttpPersistent, adapter_class,
      "connection_pooling: {} should use Faraday::Adapter::NetHttpPersistent"
  end

  def test_connection_pooling_true_uses_net_http_persistent
    options = @base_options.merge(connection_pooling: true)
    client = Parse::Client.new(options)
    adapter_class = get_adapter_class(client)

    assert_equal Faraday::Adapter::NetHttpPersistent, adapter_class,
      "connection_pooling: true should use Faraday::Adapter::NetHttpPersistent"
  end
end
