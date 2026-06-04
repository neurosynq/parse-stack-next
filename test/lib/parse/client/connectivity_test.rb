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
    # ServerHelper.setup returns true only when the server is actually
    # reachable (it probes /health), false otherwise — it does NOT skip.
    @server_up = Parse::Test::ServerHelper.setup
  end

  # The live-server probes below talk to localhost:2337. They must SKIP (not
  # FAIL) when no server is running. Gate on ACTUAL reachability, not on
  # PARSE_TEST_USE_DOCKER: the rake test task sets that flag unconditionally
  # even when no container is up, so an env-flag-only guard would turn these
  # into failures whenever the suite runs without the container.
  def require_live_server!
    skip "Live Parse Server not reachable at localhost:2337 (start the test container)" unless @server_up
  end

  def test_client_reachable_returns_true_against_live_server
    require_live_server!
    assert Parse::Client.client.reachable?,
           "expected reachable? to return true when Parse Server is up"
  end

  def test_client_connected_returns_true_against_live_server
    require_live_server!
    assert Parse::Client.client.connected?,
           "expected connected? to return true (health endpoint) when the server is up"
  end

  def test_module_reachable_returns_true_against_live_server
    require_live_server!
    assert Parse.reachable?,
           "expected Parse.reachable? to return true when Parse Server is up"
  end

  def test_module_connected_returns_true_against_live_server
    require_live_server!
    assert Parse.connected?,
           "expected Parse.connected? to return true (health endpoint) when the server is up"
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
    # When probing a data class (override endpoint), a bad REST key surfaces as
    # an AuthenticationError, which connected? must rescue to false (not raise)
    # so the `?` predicate stays a safe boolean smoke-test.
    client = stubbed_client { |*| raise Parse::Error::AuthenticationError, "bad key" }
    refute client.connected?("classes/_User"),
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

  def test_connected_probes_health_by_default_and_given_endpoint_with_limit_zero
    # Proves the endpoint parameter actually routes (no server needed): the
    # default probes "health", and a passed endpoint is probed instead — both
    # with query limit:0 so a class probe never pulls rows.
    ok = Object.new
    def ok.success?; true; end
    calls = []
    client = stubbed_client do |method, path, query: nil, **_opts|
      calls << [method, path, query]
      ok
    end

    assert client.connected?
    assert client.connected?("classes/_User")

    assert_equal :get, calls[0][0]
    assert_equal Parse::API::Server::SERVER_HEALTH_PATH, calls[0][1]
    assert_equal({ limit: 0 }, calls[0][2])
    assert_equal "classes/_User", calls[1][1],
                 "connected?(endpoint) must probe the given path, not the health endpoint"
    assert_equal({ limit: 0 }, calls[1][2])
  end

  def test_module_connected_returns_false_on_standard_error
    # The instance method only rescues Parse::Error / Faraday::Error, so to
    # exercise the module boundary's broader `rescue StandardError` we raise a
    # plain RuntimeError that the instance method lets propagate. Parse.connected?
    # must still convert it to false rather than re-raise.
    original_clients = nil
    original_clients = Parse::Client.clients.dup
    bad_client = stubbed_client { |*| raise RuntimeError, "unexpected boom" }
    Parse::Client.clients[:default] = bad_client
    refute Parse.connected?,
           "Parse.connected? must return false (not re-raise) on a non-Parse StandardError"
  ensure
    Parse::Client.clients[:default] = original_clients[:default] if original_clients
  end

  def test_module_reachable_returns_false_on_standard_error
    original_clients = nil
    original_clients = Parse::Client.clients.dup
    bad_client = stubbed_client { |*| raise Parse::Error::ConnectionError, "refused" }
    Parse::Client.clients[:default] = bad_client
    refute Parse.reachable?,
           "Parse.reachable? must return false (not re-raise) on StandardError"
  ensure
    Parse::Client.clients[:default] = original_clients[:default] if original_clients
  end

  # ---------------------------------------------------------------------------
  # Integration: the reachable? vs connected? distinction against a live server
  # with deliberately-wrong credentials. This is the behavior that justifies
  # having both methods — a typo'd app_id/key is reachable but not connected.
  # ---------------------------------------------------------------------------

  def test_bad_credentials_are_reachable_but_not_connected
    require_live_server!

    bad = Parse::Client.new(
      server_url: ENV["PARSE_TEST_SERVER_URL"] || "http://localhost:2337/parse",
      app_id: "wrong-app-id",
      api_key: "wrong-rest-key",
      master_key: nil,
    )
    assert bad.reachable?,
           "a wrong app_id/key must still be reachable? (health needs no credentials)"
    # Default connected? probes the health endpoint, which (like reachable?)
    # needs no credentials — so it is true even with a wrong key.
    assert bad.connected?,
           "default connected? hits the health endpoint, so bad credentials are still 'connected'"
    # Passing an endpoint routes the probe through the auth stack against a
    # data class, so a wrong app_id/key now correctly reports not-connected
    # (and must not raise).
    refute bad.connected?("classes/_User"),
           "connected?(endpoint) must validate credentials — a wrong app_id/key is NOT connected"
  end
end
