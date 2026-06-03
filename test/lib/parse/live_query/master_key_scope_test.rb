# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/live_query"

# Coverage for the v5.1.0 LiveQuery master-key scoping security fix.
#
# Parse Server resolves master-key (ACL/CLP-bypass) authorization ONCE,
# per CONNECTION, from the connect frame (`_handleConnect` →
# `client.hasMasterKey`); `_handleSubscribe` never re-reads it. So:
#
# * The connect frame must carry `masterKey` ONLY when the caller built
#   an admin connection (`use_master_key: true`) — never merely because a
#   master key happens to be configured (the pre-5.1.0 bug that silently
#   elevated every subscription on the socket past ACL/CLP).
# * The subscribe frame never carries `masterKey` (see
#   upstream_fixes_test.rb).
# * Scope-mismatch warnings fire in both "you think you're elevated but
#   aren't" and "you think you're scoped but aren't" directions.
class LiveQueryMasterKeyScopeTest < Minitest::Test
  def setup
    @prev_enabled = Parse.live_query_enabled?
    Parse.live_query_enabled = true
    # Isolate LiveQuery config state — `config` is memoized in @config and
    # `use_master_key` leaking across tests would corrupt the default-case
    # assertions (a polluted config.use_master_key=true would silently make
    # build_client's NOT_PROVIDED default resolve to an admin connection).
    @prev_config = Parse::LiveQuery.instance_variable_get(:@config)
    Parse::LiveQuery.instance_variable_set(:@config, Parse::LiveQuery::Configuration.new)
  end

  def teardown
    Parse.live_query_enabled = @prev_enabled
    Parse::LiveQuery.instance_variable_set(:@config, @prev_config)
  end

  # ---- connect-frame elevation gating ---------------------------------

  def test_connect_frame_omits_master_key_by_default_even_with_master_key
    # The core regression guard: a configured master key must NOT elevate
    # the connection unless use_master_key: true is explicitly set.
    client = build_client(master_key: "MK-secret")
    refute client.admin_connection?
    refute client.use_master_key
    msg = capture_connect_message(client)
    refute msg.key?(:masterKey),
      "connect frame must NOT carry masterKey unless use_master_key: true — " \
      "a present master key alone must not elevate the connection"
    assert_equal "ck", msg[:clientKey]
  end

  def test_connect_frame_carries_master_key_for_admin_connection
    client = build_client(master_key: "MK-secret", use_master_key: true)
    assert client.admin_connection?
    msg = nil
    _out, err = capture_io { msg = capture_connect_message(client) }
    assert_equal "MK-secret", msg[:masterKey],
      "admin connection (use_master_key: true) must send masterKey on connect"
    assert_match(/SECURITY/, err)
    assert_match(/BYPASS ACL\/CLP/, err)
  end

  def test_admin_connection_false_when_use_master_key_set_but_no_master_key
    # use_master_key: true with no usable key cannot elevate — must not
    # claim admin status and must not put masterKey on the wire.
    client = build_client(master_key: nil, use_master_key: true)
    refute client.admin_connection?,
      "use_master_key: true without a master key must not be an admin connection"
    msg = capture_connect_message(client)
    refute msg.key?(:masterKey)
  end

  def test_admin_connection_false_for_empty_string_master_key
    client = build_client(master_key: "", use_master_key: true)
    refute client.admin_connection?
    refute capture_connect_message(client).key?(:masterKey)
  end

  def test_security_warning_emitted_once_per_connection
    client = build_client(master_key: "MK-secret", use_master_key: true)
    _out, err = capture_io do
      client.send(:send_connect_message)
      client.send(:send_connect_message) # e.g. a reconnect
    end
    assert_equal 1, err.scan(/Parse::LiveQuery:SECURITY/).size,
      "the connection-level master-key warning must fire at most once per client"
  end

  # ---- config-level opt-in --------------------------------------------

  def test_config_use_master_key_defaults_false
    config = Parse::LiveQuery::Configuration.new
    refute config.use_master_key
    assert_includes config.to_h, :use_master_key
  end

  def test_client_picks_up_config_use_master_key
    with_live_query_config(master_key: "MK-cfg", use_master_key: true) do
      client = Parse::LiveQuery::Client.new(
        url: "wss://test.example/parse", application_id: "app", auto_connect: false,
      )
      assert client.use_master_key, "Client must inherit use_master_key from config"
      assert client.admin_connection?
    end
  end

  def test_explicit_kwarg_overrides_config
    with_live_query_config(master_key: "MK-cfg", use_master_key: true) do
      client = Parse::LiveQuery::Client.new(
        url: "wss://test.example/parse", application_id: "app",
        use_master_key: false, auto_connect: false,
      )
      refute client.use_master_key, "explicit use_master_key: false must override config true"
      refute client.admin_connection?
    end
  end

  # ---- subscribe-time scope-mismatch warnings -------------------------

  def test_warns_when_use_master_key_subscription_on_non_admin_connection
    client = build_client(master_key: "MK-secret") # non-admin
    _out, err = capture_io do
      client.send(:warn_subscription_scope_mismatch, true, nil)
    end
    assert_match(/no per-subscription master key/i, err)
    assert_match(/admin connection/i, err)
  end

  def test_warns_when_session_token_subscription_on_admin_connection
    client = build_client(master_key: "MK-secret", use_master_key: true) # admin
    _out, err = capture_io do
      client.send(:warn_subscription_scope_mismatch, false, "r:abc")
    end
    assert_match(/does NOT scope results/i, err)
  end

  def test_no_warning_for_scoped_subscription_on_non_admin_connection
    client = build_client(master_key: "MK-secret") # non-admin
    _out, err = capture_io do
      client.send(:warn_subscription_scope_mismatch, false, "r:abc")
    end
    assert_empty err, "an ACL-scoped subscription on a scoped connection is the happy path"
  end

  def test_no_warning_for_admin_subscription_on_admin_connection
    client = build_client(master_key: "MK-secret", use_master_key: true) # admin
    _out, err = capture_io do
      client.send(:warn_subscription_scope_mismatch, true, nil)
    end
    assert_empty err,
      "use_master_key: true on an already-admin connection is consistent — no warning"
  end

  # ---- credential redaction in inspect (review item M1) ----------------

  def test_client_inspect_redacts_master_and_client_keys
    client = build_client(master_key: "MK-super-secret", use_master_key: true)
    out = client.inspect
    refute_includes out, "MK-super-secret", "master key must not appear in inspect"
    refute_includes out, "ck", "client key must not appear in inspect"
    assert_match(/master_key=\[REDACTED\]/, out)
    assert_match(/client_key=\[REDACTED\]/, out)
    # Non-secret diagnostic fields are still useful.
    assert_match(/state=/, out)
    assert_match(/admin_connection=true/, out)
  end

  def test_client_inspect_shows_nil_when_no_master_key
    client = build_client(master_key: nil)
    assert_match(/master_key=nil/, client.inspect)
  end

  def test_subscription_inspect_redacts_session_token
    client = build_client(master_key: nil)
    sub = Parse::LiveQuery::Subscription.new(
      client: client, class_name: "Post", query: {}, session_token: "r:super-secret-token",
    )
    out = sub.inspect
    refute_includes out, "r:super-secret-token", "session token must not appear in inspect"
    assert_match(/session_token=\[REDACTED\]/, out)
    assert_match(/class_name="Post"/, out)
  end

  def test_subscription_inspect_does_not_leak_client_secrets
    # Subscription holds @client; its inspect must not transitively dump
    # the client's master/REST keys.
    client = build_client(master_key: "MK-super-secret", use_master_key: true)
    sub = Parse::LiveQuery::Subscription.new(
      client: client, class_name: "Post", query: {},
    )
    refute_includes sub.inspect, "MK-super-secret"
  end

  private

  def build_client(master_key:, use_master_key: Parse::NOT_PROVIDED)
    Parse::LiveQuery::Client.new(
      url: "wss://test.example/parse",
      application_id: "app",
      client_key: "ck",
      master_key: master_key,
      use_master_key: use_master_key,
      auto_connect: false,
    )
  end

  # Capture the hash passed to send_message by send_connect_message
  # without touching a socket.
  def capture_connect_message(client)
    captured = nil
    client.define_singleton_method(:send_message) { |m| captured = m }
    client.send(:send_connect_message)
    captured
  end

  # Mutates the (per-test, isolated) LiveQuery config. setup/teardown
  # swap @config for a fresh instance, so no restore is needed here.
  def with_live_query_config(master_key:, use_master_key:)
    Parse::LiveQuery.configure do |c|
      c.master_key = master_key
      c.use_master_key = use_master_key
    end
    yield
  end
end
