require_relative "../../test_helper"
require_relative "../../../lib/parse/live_query"

class TestClientLiveQuerySetup < Minitest::Test
  def setup
    @base_options = {
      server_url: "http://localhost:1337/parse",
      app_id: "test_app_id",
      api_key: "test_api_key",
      master_key: "test_master_key",
    }
    Parse::Client.clients.clear
    @prior_config = Parse::LiveQuery.instance_variable_get(:@config)
    Parse::LiveQuery.instance_variable_set(:@config, nil)
  end

  def teardown
    Parse::Client.clients.clear
    Parse::LiveQuery.instance_variable_set(:@config, @prior_config)
  end

  # Regression: configure_live_query previously called
  # Parse::LiveQuery.configure(url:, application_id:, ...) with kwargs, but
  # Parse::LiveQuery.configure only accepts a block — raising
  # "wrong number of arguments (given 1, expected 0)" any time live_query_url
  # was passed to Parse.setup.
  def test_live_query_url_from_setup_configures_live_query
    Parse::Client.new(@base_options.merge(live_query_url: "wss://live.example.com"))

    config = Parse::LiveQuery.config
    assert_equal "wss://live.example.com", config.url
    assert_equal "test_app_id", config.application_id
    assert_equal "test_api_key", config.client_key
    assert_equal "test_master_key", config.master_key
  end

  def test_live_query_opts_hash_is_applied_via_setters
    Parse::Client.new(@base_options.merge(
      live_query: { url: "wss://opts.example.com", ping_interval: 12.5, logging_enabled: true }
    ))

    config = Parse::LiveQuery.config
    assert_equal "wss://opts.example.com", config.url
    assert_equal 12.5, config.ping_interval
    assert config.logging_enabled
  end

  def test_unknown_live_query_opts_are_ignored
    # Bad keys should not raise — earlier kwargs form would have raised
    # ArgumentError. Block form must silently skip unrecognized options.
    Parse::Client.new(@base_options.merge(
      live_query: { url: "wss://x.example.com", nonsense_option: true }
    ))

    assert_equal "wss://x.example.com", Parse::LiveQuery.config.url
  end

  def test_no_live_query_options_leaves_config_untouched
    Parse::Client.new(@base_options)

    # configure_live_query should early-return; no Configuration instantiated.
    assert_nil Parse::LiveQuery.instance_variable_get(:@config)
  end
end
