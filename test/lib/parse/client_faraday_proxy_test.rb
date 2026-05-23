# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit tests for the Faraday env-proxy gate.
#
# Without this gate, an attacker who can set HTTPS_PROXY / HTTP_PROXY in
# the process environment (or who can ship those vars via a poisoned
# `.env`, container metadata, or wrapper script) silently MITMs every
# Parse request — including the master key in the request headers —
# through the attacker-controlled proxy. Faraday's auto-discovery of
# those env vars is documented behavior; the SDK must opt out by
# default and require explicit `allow_faraday_proxy: true` to enable.
class TestClientFaradayProxy < Minitest::Test
  def test_default_opts_disables_env_proxy_autodiscovery
    client = Parse::Client.new(server_url: "https://example.parse.local/parse",
                               application_id: "app", master_key: "mk")
    proxy = client.instance_variable_get(:@conn).proxy
    assert_nil proxy, "default client must not pick up HTTPS_PROXY/HTTP_PROXY from env"
  end

  def test_env_proxy_var_is_ignored_by_default
    original_https = ENV["HTTPS_PROXY"]
    original_http  = ENV["HTTP_PROXY"]
    ENV["HTTPS_PROXY"] = "http://attacker.example:9999"
    ENV["HTTP_PROXY"]  = "http://attacker.example:9999"
    begin
      client = Parse::Client.new(server_url: "https://example.parse.local/parse",
                                 application_id: "app", master_key: "mk")
      proxy = client.instance_variable_get(:@conn).proxy
      assert_nil proxy, "HTTPS_PROXY/HTTP_PROXY env vars must be ignored unless explicitly opted in"
    ensure
      ENV["HTTPS_PROXY"] = original_https
      ENV["HTTP_PROXY"] = original_http
    end
  end

  def test_explicit_proxy_still_refused_without_allow_faraday_proxy
    err = assert_raises(ArgumentError) do
      Parse::Client.new(server_url: "https://example.parse.local/parse",
                        application_id: "app", master_key: "mk",
                        faraday: { proxy: "http://attacker.example:9999" })
    end
    assert_match(/proxy/i, err.message)
  end

  def test_allow_faraday_proxy_opt_in_lets_env_proxy_flow
    original_https = ENV["HTTPS_PROXY"]
    ENV["HTTPS_PROXY"] = "http://opted-in-proxy.example:8080"
    begin
      client = Parse::Client.new(server_url: "https://example.parse.local/parse",
                                 application_id: "app", master_key: "mk",
                                 allow_faraday_proxy: true)
      proxy = client.instance_variable_get(:@conn).proxy
      refute_nil proxy, "allow_faraday_proxy: true should let Faraday pick up env proxy"
      assert_includes proxy.uri.to_s, "opted-in-proxy.example"
    ensure
      ENV["HTTPS_PROXY"] = original_https
    end
  end

  def test_allow_faraday_proxy_opt_in_lets_explicit_proxy_through
    client = Parse::Client.new(server_url: "https://example.parse.local/parse",
                               application_id: "app", master_key: "mk",
                               allow_faraday_proxy: true,
                               faraday: { proxy: "http://opted-in-proxy.example:8080" })
    proxy = client.instance_variable_get(:@conn).proxy
    refute_nil proxy
    assert_includes proxy.uri.to_s, "opted-in-proxy.example"
  end
end
