# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/client/authentication"

# End-to-end regression for the ambient-session-token whitespace handling in
# +Parse::Client#request+ (the auth-resolution fallback chain).
#
# The bug: a whitespace-only ambient token (e.g. +Parse.with_session("   ")+)
# counted as "present" in the fallback, which (a) blocked the client's own
# bound +@session_token+ fallback and then (b) failed the later
# +token.present?+ check — so a client with a master key configured would
# silently send the MASTER KEY instead of either using the bound token or
# acting anonymously.
#
# This drives the decision through BOTH layers without an HTTP server:
#   1. +Parse::Client#request+ resolves the effective token and stamps
#      +X-Disable-Parse-Master-Key+ / +X-Parse-Session-Token+ accordingly
#      (captured by a stub connection), then
#   2. the real +Parse::Middleware::Authentication+ consumes those headers
#      and decides whether the +X-Parse-Master-Key+ header goes on the wire.
# Asserting on the post-middleware headers is the faithful "no master-key
# header" check.
class ClientAmbientSessionWhitespaceTest < Minitest::Test
  include Parse::Protocol
  MASTER = "configured-master-key"
  BOUND  = "r:bound-user-token"

  # Captures the headers +Parse::Client#request+ hands to its connection,
  # short-circuiting the response so nothing leaves the process.
  class FakeConn
    attr_reader :calls
    def initialize; @calls = []; end
    def send(method, uri, params, headers)
      @calls << { headers: headers.dup }
      body = Parse::Response.new({})
      body.http_status = 200
      Struct.new(:body).new(body)
    end
  end

  # Minimal Faraday-response shape: the Authentication middleware calls
  # +.on_complete+ on whatever the inner app returns.
  class FakeResponse
    def on_complete; yield(nil) if block_given?; self; end
  end

  # Build a master-key client whose connection is the capture stub.
  def build_client(session_token: nil)
    client = Parse::Client.new(
      server_url: "http://localhost:1337/parse",
      app_id: "test-app", api_key: "test-rest",
      master_key: MASTER, session_token: session_token, logging: false,
    )
    @fake_conn = FakeConn.new
    client.instance_variable_set(:@conn, @fake_conn)
    client
  end

  # Run +client.request+ (layer 1) and feed the produced request headers
  # through the real Authentication middleware (layer 2). Returns the final
  # headers as they would go on the wire.
  def wire_headers(client, opts: {})
    client.request(:get, "classes/_TestProbe", opts: opts)
    produced = @fake_conn.calls.last[:headers]

    final = nil
    terminal = lambda do |env|
      final = env[:request_headers]
      FakeResponse.new
    end
    mw = Parse::Middleware::Authentication.new(
      terminal, application_id: "test-app", api_key: "test-rest", master_key: MASTER,
    )
    mw.call({ request_headers: produced.dup })
    final
  end

  def test_whitespace_ambient_is_rejected_at_source
    # SEC-02: with_session refuses a blank/whitespace token outright, so a
    # whitespace ambient can no longer be established (and therefore can no
    # longer degrade to a master-key send). The prior fallback-to-bound
    # behavior is superseded by rejecting the unusable credential at source.
    client = build_client(session_token: BOUND)
    assert_raises(ArgumentError) do
      Parse.with_session("   ") { wire_headers(client) }
    end
  end

  def test_explicit_blank_session_token_fails_closed_not_master
    # SEC-02: an explicitly-supplied blank/whitespace session_token is an
    # unusable credential — it must go out anonymous (master suppressed),
    # never as master, and must NOT silently fall back to the bound token.
    client = build_client(session_token: BOUND)
    ["", "   ", "\t"].each do |blank|
      headers = wire_headers(client, opts: { session_token: blank })
      assert_nil headers[MASTER_KEY],
                 "explicit blank session_token #{blank.inspect} must not send the master key"
      refute headers.key?(SESSION_TOKEN),
             "explicit blank session_token #{blank.inspect} must not fall back to a session header"
    end
  end

  def test_real_ambient_token_still_wins_over_bound_token
    # Guard the precedence the fix must not break: a real ambient token
    # overrides the bound token, and still suppresses the master key.
    client = build_client(session_token: BOUND)
    headers = Parse.with_session("r:real-ambient") { wire_headers(client) }

    assert_nil headers[MASTER_KEY]
    assert_equal "r:real-ambient", headers[SESSION_TOKEN]
  end

  def test_no_token_anywhere_lets_master_key_through
    # Sanity baseline: with no bound token and no ambient, a master-key
    # client legitimately sends the master key (the resolver did not scope).
    client = build_client(session_token: nil)
    headers = wire_headers(client)

    assert_equal MASTER, headers[MASTER_KEY]
    refute headers.key?(SESSION_TOKEN)
  end
end
