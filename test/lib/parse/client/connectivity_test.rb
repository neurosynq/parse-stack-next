# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../support/test_server"

# Tests for Parse::Client#connected?, Parse::Client#reachable?,
# Parse.connected?, and Parse.reachable? (FIX 1 — connectivity smoke-test).
#
# Integration tests probe the live Parse Server at localhost:2337.
# Unit tests stub the #request method to verify error-handling contracts
# without a live server.
class ConnectivityTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # Integration tests — require a live server at localhost:2337
  # ---------------------------------------------------------------------------

  def setup
    Parse::Test::ServerHelper.setup
  end

  def test_client_reachable_returns_true_against_live_server
    assert Parse::Client.client.reachable?,
           "expected reachable? to return true when Parse Server is up"
  end

  def test_client_connected_returns_true_against_live_server
    assert Parse::Client.client.connected?,
           "expected connected? to return true when server is up and credentials are valid"
  end

  def test_module_reachable_returns_true_against_live_server
    assert Parse.reachable?,
           "expected Parse.reachable? to return true when Parse Server is up"
  end

  def test_module_connected_returns_true_against_live_server
    assert Parse.connected?,
           "expected Parse.connected? to return true when server is up and credentials are valid"
  end

  # ---------------------------------------------------------------------------
  # Unit tests — stub #request to avoid network I/O
  # ---------------------------------------------------------------------------

  # Build a minimal Parse::Client instance via .allocate so we bypass
  # initialize (which requires server_url, app_id, and a key). We then
  # override #request on the singleton to simulate various failure modes.
  def stubbed_client(&block)
    client = Parse::Client.allocate
    client.define_singleton_method(:request, &block)
    client
  end

  def test_connected_returns_false_when_connection_error_is_raised
    client = stubbed_client { |*| raise Parse::Error::ConnectionError, "refused" }
    refute client.connected?,
           "connected? must return false (not re-raise) on Parse::Error::ConnectionError"
  end

  def test_connected_returns_false_on_authentication_error
    # connected? is the credentials-validating probe: a bad REST key surfaces
    # as an AuthenticationError, which it must rescue to false (not raise) so
    # the `?` predicate stays a safe boolean smoke-test.
    client = stubbed_client { |*| raise Parse::Error::AuthenticationError, "bad key" }
    refute client.connected?,
           "connected? must return false (not re-raise) on a bad-credentials AuthenticationError"
  end

  def test_connected_returns_false_on_timeout_error
    client = stubbed_client { |*| raise Parse::Error::TimeoutError, "timed out" }
    refute client.connected?,
           "connected? must return false (not re-raise) on Parse::Error::TimeoutError"
  end

  def test_connected_does_not_rescue_programming_errors
    # A genuine Ruby bug must still propagate — the rescue is scoped to
    # Parse::Error / Faraday::Error, not StandardError.
    client = stubbed_client { |*| raise NoMethodError, "undefined method 'foo'" }
    assert_raises(NoMethodError) { client.connected? }
  end

  def test_reachable_returns_false_when_connection_error_is_raised
    client = stubbed_client { |*| raise Parse::Error::ConnectionError, "refused" }
    refute client.reachable?,
           "reachable? must return false (not re-raise) on Parse::Error::ConnectionError"
  end

  def test_reachable_returns_false_when_faraday_error_is_raised
    client = stubbed_client { |*| raise Faraday::ConnectionFailed.new("getaddrinfo: nodename nor servname provided") }
    refute client.reachable?,
           "reachable? must return false (not re-raise) on Faraday::Error"
  end

  def test_connected_returns_false_when_faraday_error_is_raised
    client = stubbed_client { |*| raise Faraday::ConnectionFailed.new("getaddrinfo: nodename nor servname provided") }
    refute client.connected?,
           "connected? must return false (not re-raise) on Faraday::Error"
  end

  def test_module_connected_returns_false_on_standard_error
    # Parse.connected? rescues StandardError at the module boundary, so even
    # an AuthenticationError becomes false at this level.
    original_clients = Parse::Client.clients.dup
    bad_client = stubbed_client { |*| raise Parse::Error::AuthenticationError, "bad key" }
    Parse::Client.clients[:default] = bad_client
    refute Parse.connected?,
           "Parse.connected? must return false (not re-raise) on StandardError"
  ensure
    Parse::Client.clients[:default] = original_clients[:default]
  end

  def test_module_reachable_returns_false_on_standard_error
    original_clients = Parse::Client.clients.dup
    bad_client = stubbed_client { |*| raise Parse::Error::ConnectionError, "refused" }
    Parse::Client.clients[:default] = bad_client
    refute Parse.reachable?,
           "Parse.reachable? must return false (not re-raise) on StandardError"
  ensure
    Parse::Client.clients[:default] = original_clients[:default]
  end

  # ---------------------------------------------------------------------------
  # Integration: the reachable? vs connected? distinction against a live server
  # with deliberately-wrong credentials. This is the behavior that justifies
  # having both methods — a typo'd app_id/key is reachable but not connected.
  # ---------------------------------------------------------------------------

  def test_bad_credentials_are_reachable_but_not_connected
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    bad = Parse::Client.new(
      server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:2337/parse",
      app_id: "wrong-app-id",
      api_key: "wrong-rest-key",
      master_key: nil,
    )
    assert bad.reachable?,
           "a wrong app_id/key must still be reachable? (health needs no credentials)"
    refute bad.connected?,
           "a wrong app_id/key must NOT be connected? (credentials are invalid) — and must not raise"
  end
end
