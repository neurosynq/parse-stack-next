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

    # Save/restore the full LiveQuery global surface — not just @config.
    # `Parse::LiveQuery.configure` with logging_enabled: true also
    # mutates Parse::LiveQuery::Logging.{enabled, log_level, logger},
    # which would leak across tests if we only restored @config.
    @prior_config = Parse::LiveQuery.instance_variable_get(:@config)
    @prior_logging_enabled = Parse::LiveQuery::Logging.enabled
    @prior_logging_level = Parse::LiveQuery::Logging.log_level
    @prior_logger = Parse::LiveQuery::Logging.logger
    Parse::LiveQuery.instance_variable_set(:@config, nil)
  end

  def teardown
    Parse::Client.clients.clear
    Parse::LiveQuery.instance_variable_set(:@config, @prior_config)
    Parse::LiveQuery::Logging.enabled = @prior_logging_enabled
    Parse::LiveQuery::Logging.log_level = @prior_logging_level
    Parse::LiveQuery::Logging.logger = @prior_logger
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
      live_query: { url: "wss://opts.example.com", ping_interval: 12.5 }
    ))

    config = Parse::LiveQuery.config
    assert_equal "wss://opts.example.com", config.url
    assert_equal 12.5, config.ping_interval
  end

  # Top-level `live_query_url:` must win over `live_query: { url: }`. The
  # implementation expresses precedence as `live_query_url || live_query_opts[:url]`,
  # locking it here so the order can't silently flip.
  def test_live_query_url_kwarg_takes_precedence_over_live_query_hash_url
    Parse::Client.new(@base_options.merge(
      live_query_url: "wss://top-level.example.com",
      live_query: { url: "wss://hash.example.com", ping_interval: 7.0 },
    ))

    config = Parse::LiveQuery.config
    assert_equal "wss://top-level.example.com", config.url
    # The hash's non-url options still apply.
    assert_equal 7.0, config.ping_interval
  end

  def test_unknown_live_query_opts_are_ignored_with_warning
    # Bad keys should not raise — earlier kwargs form would have raised
    # ArgumentError. Block form must skip unrecognized options and warn
    # so typos like `ssl_min_versoin:` don't silently leave TLS at the
    # default.
    _out, err = capture_io do
      Parse::Client.new(@base_options.merge(
        live_query: { url: "wss://x.example.com", nonsense_option: true, ssl_min_versoin: :TLSv1_3 }
      ))
    end

    assert_equal "wss://x.example.com", Parse::LiveQuery.config.url
    assert_match(/Ignoring unknown live_query option/, err)
    assert_match(/nonsense_option/, err)
    assert_match(/ssl_min_versoin/, err)
    # The known-good `url:` key must NOT be in the warning.
    refute_match(/\burl\b.*Ignoring/, err)
  end

  def test_no_live_query_options_leaves_config_untouched
    Parse::Client.new(@base_options)

    # configure_live_query should early-return; no Configuration instantiated.
    assert_nil Parse::LiveQuery.instance_variable_get(:@config)
  end

  # Security: explicit ws:// to a routable host must be refused unless
  # `allow_insecure: true` is passed. The connect frame carries the
  # master key and session token in cleartext on a non-TLS socket.
  def test_explicit_ws_url_to_routable_host_is_refused
    assert_raises(ArgumentError) do
      Parse::Client.new(@base_options.merge(live_query_url: "ws://prod.example.com:1337"))
    end
    assert_raises(ArgumentError) do
      Parse::Client.new(@base_options.merge(live_query: { url: "ws://prod.example.com:1337" }))
    end
  end

  def test_explicit_ws_url_to_loopback_host_is_allowed
    # Loopback exemption — local dev / container-internal traffic.
    Parse::Client.new(@base_options.merge(live_query_url: "ws://localhost:1337"))
    assert_equal "ws://localhost:1337", Parse::LiveQuery.config.url

    Parse::Client.clients.clear
    Parse::LiveQuery.instance_variable_set(:@config, nil)

    Parse::Client.new(@base_options.merge(live_query_url: "ws://127.0.0.1:1337"))
    assert_equal "ws://127.0.0.1:1337", Parse::LiveQuery.config.url
  end

  def test_explicit_ws_url_with_allow_insecure_is_allowed
    Parse::Client.new(@base_options.merge(
      live_query: { url: "ws://routable.example.com:1337", allow_insecure: true }
    ))

    assert_equal "ws://routable.example.com:1337", Parse::LiveQuery.config.url
    assert Parse::LiveQuery.config.allow_insecure
  end
end
