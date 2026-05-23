# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/live_query"

# Unit tests for the LiveQuery `ws://` downgrade refusal.
# Parse::LiveQuery::Client must refuse to derive a `ws://` URL from an
# `http://` server URL on any non-loopback host unless the integrator
# explicitly opts in via
# `Parse::LiveQuery.configure { |c| c.allow_insecure = true }`.
class TestLiveQueryWsDowngrade < Minitest::Test
  def setup
    Parse::LiveQuery.reset!
    Parse::LiveQuery.instance_variable_set(:@config, nil)
    @original_clients = Parse::Client.instance_variable_get(:@clients)
    Parse::Client.instance_variable_set(:@clients, {})
  end

  def teardown
    Parse::Client.instance_variable_set(:@clients, @original_clients)
    Parse::LiveQuery.reset!
    Parse::LiveQuery.instance_variable_set(:@config, nil)
  end

  # Helper: install a fake Parse::Client with the given server_url so
  # `Client#parse_client_value(:server_url)` returns it.
  def install_parse_client(server_url)
    fake = Object.new
    fake.define_singleton_method(:server_url)     { server_url }
    fake.define_singleton_method(:application_id) { "app" }
    fake.define_singleton_method(:api_key)        { "key" }
    fake.define_singleton_method(:master_key)     { nil }
    Parse::Client.clients[:default] = fake
  end

  def build_client(allow_insecure: false)
    Parse::LiveQuery.configure do |c|
      c.url = nil  # force derive_websocket_url to be consulted
      c.application_id = "app"
      c.client_key = "key"
      c.allow_insecure = allow_insecure
    end
    Parse::LiveQuery::Client.new(auto_connect: false,
                                 application_id: "app",
                                 client_key: "key")
  end

  def test_https_server_derives_wss
    install_parse_client("https://api.example.com/parse")
    client = build_client
    assert_match %r{\Awss://api\.example\.com:443\z}, client.url
  end

  def test_http_routable_server_refused_by_default
    install_parse_client("http://api.example.com/parse")
    err = assert_raises(ArgumentError) { build_client }
    assert_match(/Refusing to derive insecure ws:\/\//, err.message)
    assert_match(/allow_insecure/, err.message)
  end

  def test_http_routable_server_allowed_when_opted_in
    install_parse_client("http://api.example.com/parse")
    out, _err = capture_io do
      client = build_client(allow_insecure: true)
      assert_match %r{\Aws://api\.example\.com:80\z}, client.url
    end
    # warning goes to stderr; the warn call uses Kernel#warn
    refute_nil out
  end

  def test_http_loopback_host_localhost_allowed_without_opt_in
    install_parse_client("http://localhost:1337/parse")
    client = build_client
    assert_match %r{\Aws://localhost:1337\z}, client.url
  end

  def test_http_loopback_host_ipv4_allowed_without_opt_in
    install_parse_client("http://127.0.0.1:1337/parse")
    client = build_client
    assert_match %r{\Aws://127\.0\.0\.1:1337\z}, client.url
  end

  def test_http_loopback_host_ipv6_allowed_without_opt_in
    install_parse_client("http://[::1]:1337/parse")
    client = build_client
    assert_match %r{\Aws://\[::1\]:1337\z}, client.url
  end
end
