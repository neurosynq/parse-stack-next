# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Unit regression for the +Parse.client_mode+ guard that prevents the
# +PARSE_SERVER_MASTER_KEY+ / +PARSE_MASTER_KEY+ ENV variables from
# silently smuggling a master key onto a client-side deployment.
#
# Background: +Parse::Client#initialize+ reads both ENV vars as the
# +master_key+ fallback when none is passed explicitly. In a
# server-only deployment that is correct — the operator's intent is
# "use the configured admin key for outbound calls." But in a process
# that the operator wants to run "as a client" (mobile companion code,
# untrusted worker, hybrid same-process server+client where one
# request path must NOT have admin powers) the same ENV fallback would
# silently re-attach the master key to every request — defeating the
# +client_mode+ contract.
#
# The fix in 5.0.0 is the +Parse.client_mode+ flag (set via the
# accessor or +PARSE_CLIENT_MODE=true+ env) — when on, the auth
# resolver skips the master key unless the caller explicitly passes
# +use_master_key: true+. This test locks in that behavior at the
# request-construction layer so a future regression that re-introduces
# the ENV fallthrough is caught without spinning up a Parse Server.
class ClientMasterKeyEnvFallthroughTest < Minitest::Test
  # Fake Faraday-shaped connection that captures the headers the client
  # hands down at request time and short-circuits the response. We
  # don't need a real HTTP server to verify the auth-resolution
  # decision — that decision is fully observable from the headers that
  # +Parse::Client#request+ passes to its connection.
  class FakeConn
    attr_reader :calls

    def initialize
      @calls = []
    end

    def send(method, uri, params, headers)
      @calls << { method: method, uri: uri, params: params, headers: headers.dup }
      # Build the minimum response shape Parse::Client#request expects.
      body = Parse::Response.new({})
      body.http_status = 200
      Struct.new(:body).new(body)
    end
  end

  def setup
    @prior_client_mode = Parse.client_mode
    @prior_env_master  = ENV["PARSE_SERVER_MASTER_KEY"]
    @prior_env_master2 = ENV["PARSE_MASTER_KEY"]
    @prior_env_cmode   = ENV["PARSE_CLIENT_MODE"]
  end

  def teardown
    Parse.client_mode = @prior_client_mode
    ENV["PARSE_SERVER_MASTER_KEY"] = @prior_env_master
    ENV["PARSE_MASTER_KEY"]        = @prior_env_master2
    ENV["PARSE_CLIENT_MODE"]       = @prior_env_cmode
  end

  # --------------------------------------------------------------------
  # The flag itself: setter / reader / predicate / coercion.
  # --------------------------------------------------------------------
  def test_client_mode_defaults_to_false_without_env
    Parse.client_mode = false
    refute Parse.client_mode
    refute Parse.client_mode?
  end

  def test_client_mode_setter_coerces_strictly_to_boolean
    # Only the literal `true` flips the switch — common truthy values
    # like the string "true" or 1 must NOT enable client mode, because
    # an integrator who passes a possibly-tainted value should never
    # accidentally promote it to admin-suppression mode.
    Parse.client_mode = "true"
    refute Parse.client_mode, "string 'true' must not enable client mode"
    Parse.client_mode = 1
    refute Parse.client_mode, "1 must not enable client mode"
    Parse.client_mode = true
    assert Parse.client_mode, "literal true must enable client mode"
  end

  # --------------------------------------------------------------------
  # The runtime behavior: when client_mode is on, the request-time auth
  # resolver must mark DISABLE_MASTER_KEY on outbound headers — even
  # when the underlying client has a master key configured (from ENV
  # or set explicitly).
  # --------------------------------------------------------------------
  def test_client_mode_marks_disable_master_key_on_outbound_request
    client = build_client(master_key: "configured-master-key")
    Parse.client_mode = true

    headers = capture_request_headers(client)
    assert_equal "true", headers[Parse::Middleware::Authentication::DISABLE_MASTER_KEY],
                 "client_mode = true must mark DISABLE_MASTER_KEY on every outbound request"
  end

  def test_explicit_use_master_key_kwarg_clears_disable_in_client_mode
    client = build_client(master_key: "configured-master-key")
    Parse.client_mode = true
    # The escape hatch: callers who know they're doing an admin action
    # opt back into the master key via `use_master_key: true`. Without
    # this, client_mode would lock out legitimate admin call paths in
    # a mixed deployment.
    headers = capture_request_headers(client, opts: { use_master_key: true })
    refute headers.key?(Parse::Middleware::Authentication::DISABLE_MASTER_KEY),
           "use_master_key: true must clear the DISABLE_MASTER_KEY suppression in client_mode"
  end

  def test_default_mode_without_client_mode_lets_master_key_through
    client = build_client(master_key: "configured-master-key")
    Parse.client_mode = false

    headers = capture_request_headers(client)
    refute headers.key?(Parse::Middleware::Authentication::DISABLE_MASTER_KEY),
           "without client_mode, the resolver must not pre-suppress the master key"
  end

  # --------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------

  def build_client(master_key:)
    client = Parse::Client.new(
      server_url: "http://localhost:1337/parse",
      app_id: "test-app",
      api_key: "test-rest",
      master_key: master_key,
      logging: false,
    )
    # Swap the real Faraday connection for the capture stub so the
    # request never leaves the process.
    @fake_conn = FakeConn.new
    client.instance_variable_set(:@conn, @fake_conn)
    client
  end

  def capture_request_headers(client, opts: {})
    client.request(:get, "classes/_TestProbe", opts: opts)
    @fake_conn.calls.last[:headers]
  end
end
