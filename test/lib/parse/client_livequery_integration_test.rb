require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"
require "timeout"

# LiveQuery is opt-in per the SDK's safety gate (a WebSocket egress
# surface that operators must consciously enable). Tests must explicitly
# load the module and flip the toggle before constructing a client.
Parse.live_query_enabled = true
require "parse/live_query"

# LiveQuery subscription from the SDK-as-client side. The LiveQuery
# server in this stack is configured (start-parse.sh) with the class
# name "TestLiveQuery" pre-whitelisted, so we use that as the fixture.
#
# The client is constructed WITHOUT the master key. Subscriptions
# authenticate with the user's session_token; ACL/CLP enforcement on
# the WebSocket stream is the server's responsibility, but we assert
# the SDK threads the token through and that an unrelated user does
# NOT receive an ACL-private event.
class TestLiveQuery < Parse::Object
  parse_class "TestLiveQuery"
  property :title, :string
  property :payload, :string
end

class ClientLiveQueryIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @user, @password = seed_client_user("lq")

    server_url = @master_client.server_url
    # Parse Server with startLiveQueryServer:true serves the WS upgrade
    # on the same host/port as the REST endpoint. Convert http→ws.
    @ws_url = server_url.sub(%r{^http}, "ws")
  end

  def teardown
    @lq_client&.shutdown(timeout: 2.0) rescue nil
    super
  end

  # --------------------------------------------------------------------
  # Sanity: a no-master-key LiveQuery client connects and registers the
  # session_token on subscribe. (We don't need to receive an event for
  # this assertion — just that the wire handshake completed and the
  # subscription is live.)
  # --------------------------------------------------------------------
  def test_livequery_client_constructs_without_master_key
    me = nil
    as_client { me = Parse::User.login(@user.username, @password) }

    @lq_client = Parse::LiveQuery::Client.new(
      url: @ws_url,
      application_id: @master_client.application_id,
      client_key: @master_client.api_key,
      master_key: nil,
      auto_connect: true,
      auto_reconnect: false,
    )
    assert_nil @lq_client.master_key, "LiveQuery client must not carry a master key"

    Timeout.timeout(5) do
      sleep 0.05 until @lq_client.state == :connected || @lq_client.state == :closed
    end
    assert_equal :connected, @lq_client.state, "client failed to reach :connected"

    sub = @lq_client.subscribe(
      "TestLiveQuery", where: { title: "doesnotmatter" }, session_token: me.session_token,
    )
    refute_nil sub, "subscribe must return a Subscription"
    assert_equal me.session_token, sub.session_token,
                 "subscription must carry the user's session_token, not the master key"
  end

  # --------------------------------------------------------------------
  # End-to-end: subscribe as Alice, create a row as Alice, receive the
  # create event on Alice's subscription. Bob's subscription on the
  # same class — but with an ACL-private row — should NOT receive it.
  # --------------------------------------------------------------------
  def test_livequery_receives_create_event_under_session_token
    skip "LiveQuery event delivery is flaky on cold Parse Server boot; gate with PARSE_TEST_LIVEQUERY_FLAKY=true" \
         unless ENV["PARSE_TEST_LIVEQUERY_FLAKY"] == "true"

    bob, bob_password = seed_client_user("lq_bob")

    alice = nil
    bob_session = nil
    as_client do
      alice = Parse::User.login(@user.username, @password)
      bob_session = Parse::User.login(bob.username, bob_password)
    end

    @lq_client = Parse::LiveQuery::Client.new(
      url: @ws_url,
      application_id: @master_client.application_id,
      client_key: @master_client.api_key,
      master_key: nil,
      auto_connect: true,
      auto_reconnect: false,
    )
    Timeout.timeout(5) do
      sleep 0.05 until @lq_client.state == :connected
    end

    received_alice = []
    received_bob   = []

    alice_sub = @lq_client.subscribe("TestLiveQuery", session_token: alice.session_token)
    alice_sub.on(:create) { |obj| received_alice << obj }

    bob_sub = @lq_client.subscribe("TestLiveQuery", session_token: bob_session.session_token)
    bob_sub.on(:create) { |obj| received_bob << obj }

    # Let the subscribe round-trip.
    sleep 0.5

    as_client do
      row = TestLiveQuery.new(title: "hello-lq", payload: "p")
      row.acl.everyone(false, false)
      row.acl.apply(alice.id, true, true)
      assert row.save(session: alice.session_token)
    end

    # Wait for event propagation.
    Timeout.timeout(5) do
      sleep 0.1 until received_alice.any? || (Time.now > Time.now + 4)
    end

    refute_empty received_alice, "Alice's subscription must receive her own create"
    assert_empty received_bob,   "Bob must not receive Alice's ACL-private create"
  end
end
