require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# End-to-end coverage for {Parse.track_event} against a real Parse
# Server that has a non-no-op AnalyticsAdapter installed.
#
# Why this exists alongside +track_event_wire_shape_test.rb+:
#
# The wire-shape test pins what the SDK puts on the wire (request body,
# URL path, headers) using a Faraday stub. It does NOT prove that
# Parse Server actually accepts the request or that the analytics
# payload survives the round-trip — Parse Server's default
# +analyticsAdapter+ is a no-op (lib/Adapters/Analytics/AnalyticsAdapter.js
# in parse-server 8.x just returns +Promise.resolve({})+), so a true
# integration test needs a non-no-op adapter to read events back.
#
# The integration stack installs a tiny in-process adapter
# (+test/cloud/analytics-adapter.js+, loaded via
# +PARSE_SERVER_ANALYTICS_ADAPTER+ in
# +scripts/docker/docker-compose.test.yml+) that pushes every event
# onto +global.__parseTestCapturedAnalytics+. Two master-key-only Cloud
# functions in +test/cloud/main.js+ drain and reset that buffer for
# this test.
#
# What this file pins down end-to-end against the Docker Parse Server:
#
#   * Master-key +Parse.track_event(name, dimensions: {...})+ produces
#     exactly ONE captured record on the server, with eventName in the
#     adapter's first arg and dimensions arriving as the parameters
#     hash (NOT wrapped under a "dimensions" key).
#   * Empty-dimensions form (+Parse.track_event("AppOpened")+) lands on
#     the server with parameters == +{}+.
#   * +session_token:+ opt reaches the server: the captured record
#     carries +req.info.sessionToken+ set to the value passed in. This
#     is the receiving-side counterpart to the wire-shape assertion in
#     +test_track_event_forwards_session_token_opt_as_header+ — the
#     stub proves the header left the SDK; this proves Parse Server
#     parsed it and threaded it through to the adapter.
#   * Invalid event names fail closed BEFORE any HTTP attempt (so no
#     event lands on the server at all).
class TrackEventAdapterIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super

    # Drain whatever the previous test (or container boot) recorded.
    # The adapter buffer is a Node-process global, so it survives DB
    # resets — the integration helper's setup wipes Mongo but the
    # captured-events array sits in the parse-server process memory.
    #
    # IMPORTANT — this reset is UNCONDITIONAL (it wipes the whole
    # buffer, not just events from this test). That is safe ONLY while
    # the integration suite runs sequentially. If a future change
    # introduces parallel test execution, OR if any other integration
    # test starts hitting +/events+, this setup will drop in-flight
    # records belonging to a concurrent test. Per-test event-name
    # randomization (+SecureRandom.hex(3)+ below) guards against name
    # collisions but NOT against this kind of cross-test buffer wipe.
    # To go parallel, scope the reset (or move to a per-run buffer key)
    # before flipping the executor.
    reset_captured_events!
  end

  # --------------------------------------------------------------------
  # Master-key form: dimensions land on the adapter as the parameters
  # hash (NOT wrapped under "dimensions"). This is the load-bearing
  # round-trip assertion — it proves the v5.0 kwarg contract reaches
  # the server in the documented shape.
  # --------------------------------------------------------------------
  def test_master_key_track_event_round_trips_dimensions_to_adapter
    event_name = "post_viewed_#{SecureRandom.hex(3)}"

    with_master_key do
      response = Parse.track_event(event_name,
                                   dimensions: { source: "feed", workspace: "w1" })
      assert response, "Parse.track_event must complete without raising"
    end

    captured = drain_captured_events
    matching = captured.select { |e| e["eventName"] == event_name }
    assert_equal 1, matching.size,
                 "exactly one trackEvent must have landed on the adapter, " \
                 "captured: #{captured.inspect}"

    record = matching.first
    assert_equal "trackEvent", record["kind"]
    assert_equal({ "source" => "feed", "workspace" => "w1" }, record["dimensions"],
                 "dimensions must arrive as the parameters hash with no 'dimensions' wrapper")
    refute record["dimensions"].key?("dimensions"),
           "regression guard: parameters must NOT carry a nested 'dimensions' key " \
           "(would mean the kwarg-absorption bug came back)"
  end

  # --------------------------------------------------------------------
  # Bare +Parse.track_event(name)+ (no dimensions) lands on the adapter
  # with parameters == +{}+. Catches a regression where the default
  # +dimensions: {}+ kwarg goes missing and the body becomes +nil+ /
  # the request fails before the wire.
  # --------------------------------------------------------------------
  def test_track_event_without_dimensions_lands_as_empty_parameters
    event_name = "AppOpenedSentinel_#{SecureRandom.hex(3)}"

    with_master_key do
      Parse.track_event(event_name)
    end

    captured = drain_captured_events
    matching = captured.select { |e| e["eventName"] == event_name }
    assert_equal 1, matching.size,
                 "the no-dimensions call must still land exactly once, captured: #{captured.inspect}"
    assert_equal({}, matching.first["dimensions"],
                 "empty dimensions must arrive as the empty object on the adapter")
  end

  # --------------------------------------------------------------------
  # +session_token:+ opt rides the SDK's +**opts+ pass-through into the
  # +X-Parse-Session-Token+ header. Parse Server parses that header and
  # populates +req.info.sessionToken+ before invoking the adapter. The
  # captured record proves the token survived the round trip — this is
  # the documented "session token can be threaded through for
  # installations that require authentication on /events" contract in
  # +lib/parse/api/analytics.rb+, verified on the receiving side.
  # --------------------------------------------------------------------
  def test_track_event_session_token_opt_threads_through_to_adapter_req_info
    user, password = seed_client_user("an_st")
    event_name = "page_view_#{SecureRandom.hex(3)}"

    as_client do
      me = Parse::User.login!(user.username, password)
      refute_nil me.session_token, "login must yield a session token"

      Parse.track_event(event_name,
                        dimensions: { url: "/home" },
                        session_token: me.session_token)

      # Drain under master-key — the Cloud function is requireMaster.
      restore_master_client!
      captured = drain_captured_events
      matching = captured.select { |e| e["eventName"] == event_name }
      assert_equal 1, matching.size,
                   "the session-token call must land exactly once on the adapter"

      record = matching.first
      assert_equal me.session_token, record["sessionToken"],
                   "session_token opt must reach the adapter via req.info.sessionToken " \
                   "(received: #{record["sessionToken"].inspect})"
      assert_equal({ "url" => "/home" }, record["dimensions"])
    end
  end

  # --------------------------------------------------------------------
  # Invalid event names raise BEFORE any HTTP call — so the adapter
  # never sees them. Pairs with +test_track_event_rejects_invalid_event_name_before_http+
  # in the wire-shape test (which uses a stub to prove no HTTP is made);
  # this version proves the same fact from the receiving side by
  # confirming the buffer stays empty after the call attempt.
  # --------------------------------------------------------------------
  def test_invalid_event_name_never_reaches_the_adapter
    assert_raises(ArgumentError) do
      Parse.track_event("bad/name", dimensions: { x: 1 })
    end

    captured = drain_captured_events
    assert_empty captured,
                 "an event-name-rejected call must not produce a captured event, " \
                 "captured: #{captured.inspect}"
  end

  # --------------------------------------------------------------------
  # Helpers — Cloud-function drains. Both require the master key (set
  # via +requireMaster: true+ in main.js); we always invoke them inside
  # +with_master_key+ to make the auth context explicit.
  # --------------------------------------------------------------------

  def drain_captured_events
    events = nil
    with_master_key do
      response = Parse.client.call_function("getCapturedAnalyticsEvents", {})
      assert response.success?,
             "getCapturedAnalyticsEvents must succeed: #{response.error.inspect}"
      # Cloud function responses arrive as +{"result" => <return value>}+
      # — Parse::Response keeps the wrapper because the body has no
      # +"results"+ array key (lib/parse/client/response.rb#parse_result!).
      # Pin that contract structurally: if a future SDK change adds
      # auto-unwrap of the +"result"+ key, this assertion fires LOUDLY
      # instead of letting the helper return +Array(nil) == []+ and
      # silently mask "captured: []" assertions.
      payload = response.result
      assert payload.is_a?(Hash) && payload.key?("result"),
             "drain helper assumes Parse::Response keeps the {\"result\" => ...} " \
             "cloud-function wrapper; got: #{payload.inspect}. If call_function " \
             "auto-unwraps now, update this helper rather than the assertion."
      events = payload["result"]
    end
    Array(events)
  end

  def reset_captured_events!
    with_master_key do
      response = Parse.client.call_function("resetCapturedAnalyticsEvents", {})
      assert response.success?,
             "resetCapturedAnalyticsEvents must succeed: #{response.error.inspect}"
    end
  end
end
