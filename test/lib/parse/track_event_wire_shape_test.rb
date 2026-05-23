# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "faraday"
require "json"

# Wire-shape regression guard for {Parse.track_event}.
#
# Parse Server's default +analyticsAdapter+ is a no-op, so a true
# round-trip integration test would require shipping a custom adapter
# in the Docker config just to read events back. The only behavior an
# end-to-end test would actually pin is the request shape — event name
# in the URL path, dimensions as the JSON body, +**opts+ flowing as
# headers/options — and that's pinned here at the bottom of the
# Faraday middleware chain using +Faraday::Adapter::Test::Stubs+.
#
# The load-bearing assertion this file exists for: the +dimensions:+
# kwarg form must flatten into the body as top-level keys, NOT get
# absorbed into a +"dimensions"+ wrapper. The earlier v5.0 doc audit
# (see CHANGELOG / `docs/client_sdk_todo.md`) flagged that the public
# examples were misleadingly written as if Ruby kwargs would auto-wrap
# into a nested hash; this test makes the actual contract executable
# so any future regression of {Parse.track_event} or
# {Parse::API::Analytics#send_analytics} produces an immediate failure.
class TrackEventWireShapeTest < Minitest::Test
  def setup
    @prior_default     = Parse::Client.clients[:default]
    @prior_env_master  = ENV["PARSE_SERVER_MASTER_KEY"]
    @prior_env_master2 = ENV["PARSE_MASTER_KEY"]
    @prior_client_mode = Parse.client_mode
    # Keep the resolution chain fully deterministic.
    ENV.delete("PARSE_SERVER_MASTER_KEY")
    ENV.delete("PARSE_MASTER_KEY")
    Parse.client_mode = false
  end

  def teardown
    Parse::Client.clients[:default] = @prior_default
    Parse.client_mode = @prior_client_mode
    ENV["PARSE_SERVER_MASTER_KEY"] = @prior_env_master
    ENV["PARSE_MASTER_KEY"]        = @prior_env_master2
  end

  # --------------------------------------------------------------------
  # The headline assertion: +Parse.track_event("evt", dimensions: {...})+
  # POSTs to +/parse/events/evt+ with the dimensions hash as the body.
  # Dimensions appear at the TOP level of the JSON body — there is no
  # +"dimensions"+ wrapper. If a future change re-introduces the kwarg-
  # absorption bug (e.g. by passing +dimensions: dimensions+ through
  # +send_analytics+ instead of the positional +metrics+ hash), the body
  # would arrive as +{"dimensions": {...}}+ and this assertion fires.
  # --------------------------------------------------------------------
  def test_track_event_posts_dimensions_as_top_level_body_keys
    captured_body = nil
    captured = nil
    install_stub_client do |stubs|
      stubs.post(%r{/parse/events/post_viewed}) do |env|
        captured = env
        captured_body = env.body
        [200, { "Content-Type" => "application/json" }, "{}"]
      end

      Parse.track_event("post_viewed", dimensions: { source: "feed", workspace: "w1" })
    end

    refute_nil captured, "the stub must have observed exactly one POST to /events/post_viewed"
    body = JSON.parse(captured_body)
    assert_equal({ "source" => "feed", "workspace" => "w1" }, body,
                 "dimensions must serialize as top-level body keys (not under a 'dimensions' wrapper)")
    refute body.key?("dimensions"),
           "regression guard: the body must NOT carry a 'dimensions' wrapper key " \
           "(would indicate the kwarg-absorption bug came back)"
  end

  # --------------------------------------------------------------------
  # Bare call with no dimensions still POSTs to the event endpoint with
  # an empty JSON object body. Catches a regression where the default
  # +dimensions: {}+ kwarg goes missing and the body becomes +nil+ /
  # the request fails before the wire.
  # --------------------------------------------------------------------
  def test_track_event_without_dimensions_posts_empty_body
    captured_body = nil
    install_stub_client do |stubs|
      stubs.post(%r{/parse/events/AppOpened}) do |env|
        captured_body = env.body
        [200, { "Content-Type" => "application/json" }, "{}"]
      end

      Parse.track_event("AppOpened")
    end

    refute_nil captured_body
    body = JSON.parse(captured_body)
    assert_equal({}, body, "empty dimensions must serialize as the empty JSON object")
  end

  # --------------------------------------------------------------------
  # The event name lands in the URL path verbatim. The path-segment
  # whitelist (+[\w\-\.]+) is enforced ahead of the HTTP call by
  # {Parse.track_event} itself; here we pin that an event name carrying
  # all three allowed character classes makes it onto the wire as-is.
  # --------------------------------------------------------------------
  def test_track_event_name_lands_in_url_path_segment
    captured = nil
    install_stub_client do |stubs|
      stubs.post(%r{/parse/events/checkout\.flow-step_3}) do |env|
        captured = env
        [200, { "Content-Type" => "application/json" }, "{}"]
      end

      Parse.track_event("checkout.flow-step_3", dimensions: { step: 3 })
    end

    refute_nil captured, "the event name with dots/hyphens/underscores must appear in the URL"
  end

  # --------------------------------------------------------------------
  # +**opts+ forwarded to the underlying request must flow through. A
  # +session_token:+ opt attaches as +X-Parse-Session-Token+ on the wire
  # (and, as a side-effect of the auth resolver, suppresses the master
  # key). This pins the documented "session token can be threaded
  # through for installations that require authentication on /events"
  # contract in +lib/parse/api/analytics.rb+.
  # --------------------------------------------------------------------
  def test_track_event_forwards_session_token_opt_as_header
    captured = nil
    install_stub_client(master_key: "configured-master") do |stubs|
      stubs.post(%r{/parse/events/page_view}) do |env|
        captured = env
        [200, { "Content-Type" => "application/json" }, "{}"]
      end

      Parse.track_event("page_view",
                        dimensions: { url: "/home" },
                        session_token: "r:fake-session-token")
    end

    refute_nil captured
    assert_equal "r:fake-session-token",
                 captured.request_headers[Parse::Protocol::SESSION_TOKEN],
                 "session_token opt must reach the wire as X-Parse-Session-Token"
    refute captured.request_headers.key?(Parse::Protocol::MASTER_KEY),
           "session_token must suppress the master key " \
           "(auth resolver: Parse::Middleware::Authentication#call), " \
           "headers seen: #{captured.request_headers.keys.inspect}"
  end

  # --------------------------------------------------------------------
  # Positive control for the suppression assertion above. Same client
  # configuration (a master key IS configured), same +track_event+ call,
  # but NO +session_token:+ opt — the master key MUST appear on the wire.
  # Without this pair, +test_track_event_forwards_session_token_opt_as_header+
  # would also pass under a regression where the auth resolver simply
  # stopped attaching the master key by default (independent of session
  # token presence). The two tests together pin the asymmetry: master
  # key by default; suppressed only when session_token is present.
  # --------------------------------------------------------------------
  def test_track_event_sends_master_key_when_no_session_token_opt
    captured = nil
    install_stub_client(master_key: "configured-master") do |stubs|
      stubs.post(%r{/parse/events/page_view}) do |env|
        captured = env
        [200, { "Content-Type" => "application/json" }, "{}"]
      end

      Parse.track_event("page_view", dimensions: { url: "/home" })
    end

    refute_nil captured
    assert_equal "configured-master",
                 captured.request_headers[Parse::Protocol::MASTER_KEY],
                 "without a session_token opt, the configured master key MUST attach " \
                 "to /events (positive control for the suppression assertion)"
    refute captured.request_headers.key?(Parse::Protocol::SESSION_TOKEN),
           "no session_token was passed, so no X-Parse-Session-Token must appear, " \
           "headers seen: #{captured.request_headers.keys.inspect}"
  end

  # --------------------------------------------------------------------
  # Invalid event names fail closed BEFORE any HTTP call. The whitelist
  # in {Parse.track_event} exists to prevent URL-path escape via slashes,
  # query-string injection, etc. The stub block is deliberately empty —
  # if the call ever reaches the adapter, Faraday raises NotFound and
  # the test still fails, which is the point.
  # --------------------------------------------------------------------
  def test_track_event_rejects_invalid_event_name_before_http
    install_stub_client do |_stubs|
      # No stub registered — any HTTP attempt would fail here.
      err = assert_raises(ArgumentError) do
        Parse.track_event("bad/name", dimensions: { x: 1 })
      end
      assert_match(/event name|word characters|hyphens|dots/i, err.message)

      err = assert_raises(ArgumentError) do
        Parse.track_event("", dimensions: { x: 1 })
      end
      assert_match(/event name|word characters|hyphens|dots/i, err.message)
    end
  end

  # --------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------

  # Mirrors the pattern in client_no_master_key_smoke_test.rb: build a
  # real Parse::Client, swap its Faraday connection for one ending in
  # the test adapter, install it as the default client. The
  # Authentication + BodyBuilder middleware chain runs as it would in
  # production, so the captured headers and body reflect exactly what
  # the HTTP layer would send for those two stages.
  #
  # NOTE — this is an INTENTIONAL slice of the production middleware
  # chain, not a full-fidelity replay. The real +Parse::Client#connection+
  # may add additional middleware (logging, retry, header-rewriting)
  # around Authentication/BodyBuilder. Anything that mutates headers or
  # body OUTSIDE those two stages would not be visible to this stub. The
  # tests in this file pin the SDK-side request shape and auth-resolver
  # decisions; the receiving-side round-trip is covered separately by
  # +track_event_adapter_integration_test.rb+ against the real Docker
  # Parse Server.
  def install_stub_client(master_key: nil)
    stubs = Faraday::Adapter::Test::Stubs.new
    client = Parse::Client.new(
      server_url: "http://test.example/parse",
      app_id: "test-app",
      api_key: "test-rest",
      master_key: master_key,
      logging: false,
    )

    conn = Faraday.new(url: "http://test.example/parse") do |c|
      c.use Parse::Middleware::Authentication,
            application_id: "test-app", api_key: "test-rest", master_key: master_key
      c.use Parse::Middleware::BodyBuilder
      c.adapter :test, stubs
    end
    client.instance_variable_set(:@conn, conn)

    Parse::Client.clients[:default] = client

    yield stubs
    stubs.verify_stubbed_calls
  ensure
    stubs&.verify_stubbed_calls rescue nil
  end
end
