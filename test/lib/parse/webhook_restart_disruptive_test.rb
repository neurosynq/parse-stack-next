# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"
require_relative "../../support/webhook_test_server"

# DISRUPTIVE integration test: registers a real webhook against the live
# Parse Server (routed back to an in-process WEBrick via
# +host.docker.internal+), then RESTARTS the Parse Server container to
# prove webhook registrations survive a server restart and that the SDK's
# registration is idempotent.
#
# Segregated from the normal integration run (see the Rakefile's
# `test:integration:disruptive` task) because it restarts the shared
# server. The restart uses DockerHelper.restart_server! (docker restart of
# the Parse container ONLY) so mongo keeps its data — including the
# server-side `_Hooks` registrations, which is exactly the persistence this
# test depends on.
#
# Why a webhook FUNCTION (not an afterSave trigger) is the probe:
# +Parse.call_function+ is synchronous — Parse Server forwards the call to
# the in-process server and blocks on its response — so "the callback
# fired" is deterministic the instant the call returns. afterSave webhooks
# are fire-and-forget and would require polling.
#
# What this pins:
#   1. A registered webhook function round-trips: SDK -> Parse Server ->
#      in-process handler -> back, returning the handler's value.
#   2. Re-running registration is IDEMPOTENT: no duplicate server-side hook
#      is created, no error is raised (the SDK chooses update-vs-create).
#   3. After a Parse Server restart the registration persists (it lives in
#      mongo) and the webhook still round-trips on the same client.
class WebhookRestartDisruptiveTest < Minitest::Test
  include ParseStackIntegrationTest

  FUNCTION_NAME = "webhookRestartEcho"

  OUTAGE_ERRORS = [
    Parse::Error::ConnectionError,
    Parse::Error::TimeoutError,
    Parse::Error::ServiceUnavailableError,
    Faraday::Error,
  ].freeze

  def setup
    super # ParseStackIntegrationTest: ensures server up + clean DB

    # Preserve and override the two security flags that otherwise block
    # this end-to-end path:
    #   * allow_private_webhook_urls — the registration SSRF guard refuses
    #     private/loopback hosts, but the test host is only reachable from
    #     the container via host.docker.internal (a private address).
    #   * allow_unauthenticated — the in-process app fails closed without a
    #     configured webhook key, and the test server runs without one.
    @saved_allow_private = Parse::Webhooks.allow_private_webhook_urls
    @saved_allow_unauth = Parse::Webhooks.allow_unauthenticated
    Parse::Webhooks.allow_private_webhook_urls = true
    Parse::Webhooks.allow_unauthenticated = true

    # Register a synchronous webhook function whose handler echoes a param
    # and a fixed marker, so a successful round-trip is unambiguous.
    Parse::Webhooks.route(:function, FUNCTION_NAME) do |payload|
      { "echoed" => payload.params["ping"], "marker" => "from-webhook" }
    end

    # Start the in-process callback server and register the hook with Parse
    # Server pointing at it. Clear any stale hooks first so the idempotency
    # count is meaningful.
    @server = Parse::Test::WebhookTestServer.new.start!
    safe_remove_function_hooks!
    Parse::Webhooks.register_functions!(@server.url)
  end

  def teardown
    safe_remove_function_hooks!
    @server&.stop!

    Parse::Webhooks.routes.function.delete(FUNCTION_NAME) if Parse::Webhooks.routes.respond_to?(:function)

    Parse::Webhooks.allow_private_webhook_urls = @saved_allow_private
    Parse::Webhooks.allow_unauthenticated = @saved_allow_unauth

    # Bulletproof restore for the next test / the rest of the suite.
    Parse::Test::DockerHelper.ensure_server_running!
    super
  end

  def test_webhook_survives_server_restart_and_registration_is_idempotent
    # --- 1. Round-trip before restart --------------------------------
    result = Parse.call_function!(FUNCTION_NAME, { ping: "v1" })
    assert_equal({ "echoed" => "v1", "marker" => "from-webhook" }, result,
                 "webhook function must round-trip through the in-process handler")
    assert hook_hit?, "the in-process webhook server must have recorded the callback"

    # --- 2. Registration is idempotent (no duplicate, no error) ------
    assert_equal 1, registered_hook_count,
                 "precondition: exactly one server-side hook should be registered"
    # Re-register: must be a no-op (same URL) — not a second hook, not an error.
    Parse::Webhooks.register_functions!(@server.url)
    assert_equal 1, registered_hook_count,
                 "re-registering the same webhook must not create a duplicate hook"
    # And it must still work after the redundant registration.
    assert_equal "v1b",
                 Parse.call_function!(FUNCTION_NAME, { ping: "v1b" })["echoed"]

    # --- 3. Restart the Parse Server container -----------------------
    # docker restart preserves mongo, so the _Hooks registration persists.
    assert Parse::Test::DockerHelper.restart_server!,
           "Parse Server must come back up after restart_server!"
    _wait_until(timeout: 30) { Parse::Client.client.reachable? }

    # --- 4. Webhook still round-trips after the restart --------------
    # The registration lived in mongo and survived; the in-process server
    # was never touched. The same client must still drive the round-trip.
    after = _with_recovery_retries { Parse.call_function!(FUNCTION_NAME, { ping: "v2" }) }
    assert_equal({ "echoed" => "v2", "marker" => "from-webhook" }, after,
                 "the webhook registration must survive a Parse Server restart")
    assert_equal 1, registered_hook_count,
                 "the surviving hook must still be a single registration after restart"

    # --- 5. Re-registration remains idempotent post-restart ----------
    Parse::Webhooks.register_functions!(@server.url)
    assert_equal 1, registered_hook_count,
                 "re-registration after restart must remain idempotent"
  end

  private

  # True if the in-process server saw a callback for our function path.
  def hook_hit?
    @server.last_responses.any? { |r| r[:path].to_s.include?(FUNCTION_NAME) }
  end

  # Count of server-side webhook (URL-backed) registrations for our function.
  def registered_hook_count
    Parse.client.functions.results.count do |f|
      f["functionName"] == FUNCTION_NAME && f["url"].present?
    end
  end

  # Remove server-side webhook function registrations, tolerating an
  # unreachable/booting server (used in setup and teardown).
  def safe_remove_function_hooks!
    Parse::Webhooks.remove_all_functions!
  rescue *OUTAGE_ERRORS, Parse::Error => e
    # Best-effort cleanup; a transient error here must not mask the test
    # result or wedge teardown.
    warn "[webhook_restart_test] hook cleanup skipped: #{e.class}"
  end

  def _wait_until(timeout:, interval: 0.5)
    deadline = monotonic_now + timeout
    result = yield
    while !result && monotonic_now < deadline
      sleep interval
      result = yield
    end
    result
  end

  def _with_recovery_retries(attempts: 3)
    yield
  rescue *OUTAGE_ERRORS
    attempts -= 1
    raise if attempts <= 0
    sleep 1
    retry
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
