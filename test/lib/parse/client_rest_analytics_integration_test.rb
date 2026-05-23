require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# Parse Analytics from the SDK-as-client side.
#
# /events/<name> is a POST surface for free-form custom events with up
# to eight dimension pairs (per Parse docs). Parse Server accepts these
# events without master-key auth — they're meant to be called from
# mobile / browser clients shipping the SDK directly. The SDK's no-
# master-key client must therefore round-trip a track call cleanly,
# whether anonymous OR session-authed.
#
# We can't easily verify the dimensions were persisted (Parse Server's
# analytics backend is a black box from REST), so the assertions focus
# on the SDK contract:
#   * The POST returns a success response (HTTP 2xx, no Parse error).
#   * Per-call timing dimension is accepted alongside custom keys.
#   * The eight-dimension limit doesn't cause the SDK to raise — Parse
#     Server silently truncates, and our SDK must surface that as a
#     normal success, not invent a client-side error.
#   * Master-key flag toggling does not change the behavior (analytics
#     is public-writable; the SDK must not require master smuggling).
class ClientRestAnalyticsIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @user, @password = seed_client_user("analytics")
  end

  # --------------------------------------------------------------------
  # Anonymous (no auth) track call must succeed. This is the canonical
  # mobile-SDK pattern: opt-in analytics from an unauthenticated user.
  # --------------------------------------------------------------------
  def test_anonymous_track_event_succeeds
    as_client do
      response = Parse.client.send_analytics(
        "search",
        priceRange: "1000-1500",
        source: "test_anon",
        dayType: "weekday",
      )
      assert response.success?,
             "anonymous /events POST must succeed (#{response.error.inspect})"
    end
  end

  # --------------------------------------------------------------------
  # Session-token-authed track call must also succeed. The SDK must
  # thread the session token through without dropping it for
  # non-authenticated requests.
  # --------------------------------------------------------------------
  def test_authed_track_event_succeeds
    as_client do
      me = Parse::User.login(@user.username, @password)
      response = Parse.client.send_analytics(
        "search",
        { priceRange: "1500-2000", source: "test_authed" },
        session_token: me.session_token, use_master_key: false,
      )
      assert response.success?,
             "authed /events POST must succeed (#{response.error.inspect})"
    end
  end

  # --------------------------------------------------------------------
  # Parse docs document Analytics as an error-tracking surface too.
  # `track('error', { code: '42' })` from a non-master client must
  # succeed — it's the same /events POST. No code-path special-cases
  # the event name "error" in the SDK.
  # --------------------------------------------------------------------
  def test_track_error_event_under_client_mode
    as_client do
      response = Parse.client.send_analytics("error", { code: "E_TEST_#{SecureRandom.hex(2)}" })
      assert response.success?,
             "error-tracking analytics event must round-trip (#{response.error.inspect})"
    end
  end

  # --------------------------------------------------------------------
  # Custom timing / at-time analytics. The `at` parameter (ISO date)
  # lets a client backfill an event with the original timestamp; the
  # SDK should pass it through as part of the body without rewriting
  # or rejecting it.
  # --------------------------------------------------------------------
  def test_track_with_at_timestamp_under_client_mode
    as_client do
      response = Parse.client.send_analytics(
        "session_start",
        at: (Time.now - 60).utc.iso8601,
        platform: "test_harness",
      )
      assert response.success?,
             "analytics with `at` backfill must round-trip (#{response.error.inspect})"
    end
  end

  # --------------------------------------------------------------------
  # Parse Server stores the first eight dimension pairs per call. The
  # SDK MUST NOT pre-validate or refuse a call with more than eight —
  # silent server-side truncation is the documented behavior, and any
  # client-side preflight would diverge from other Parse SDKs.
  # --------------------------------------------------------------------
  def test_track_with_more_than_eight_dimensions_does_not_raise
    metrics = 12.times.map { |i| ["dim#{i}", "v#{i}"] }.to_h
    as_client do
      response = Parse.client.send_analytics("oversized", metrics)
      assert response.success?,
             "oversized analytics call must succeed (server truncates silently) (#{response.error.inspect})"
    end
  end

  # --------------------------------------------------------------------
  # Sanity: the no-master client used by all these calls did NOT smuggle
  # in a master key. Analytics is a public-writable surface and must
  # NEVER require master credentials to send.
  # --------------------------------------------------------------------
  def test_analytics_does_not_require_master_key
    as_client do
      assert_nil Parse::Client.client.master_key,
                 "client-mode default client must have no master key"
      response = Parse.client.send_analytics("smoke", { ok: "1" })
      assert response.success?, "analytics under client mode must succeed without a master key"
    end
  end
end
