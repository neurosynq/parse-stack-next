require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"

# End-to-end coverage for +Parse::API::CloudFunctions#trigger_job+
# under client mode. Parse Server's +POST /jobs/<name>+ endpoint is
# MASTER-KEY-ONLY by contract — there is no session-token authorization
# model for triggering background jobs. (This mirrors +POST /push+.)
#
# What this pins:
#   1. Under client mode (no master key), +trigger_job+ does NOT
#      silently succeed. The server rejects with a permission error,
#      or — in a future SDK with a guard analogous to +Parse::API::Push+ —
#      the SDK fails closed at the boundary. Either is acceptable; the
#      invariant is "no silent escalation".
#   2. Under master-key mode, +trigger_job+ on a known-bad job name
#      surfaces a server-side rejection (no such job) rather than the
#      SDK short-circuiting. Pins that the master-key path actually
#      reaches the server.
#
# The test Docker Parse Server has NO jobs registered in
# +test/cloud/main.js+ — only cloud functions. We use a synthetic job
# name to exercise the auth boundary on both modes; the server's "no
# such job" response is the success signal that we reached it.
class ClientRestCloudJobIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  SYNTHETIC_JOB = "noSuchJobForTesting"

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  # --------------------------------------------------------------------
  # Client-mode: trigger_job must NOT silently succeed. The SDK's
  # response middleware translates the Parse Server 403 "master key is
  # required" into +Parse::Error::AuthenticationError+, so the
  # rejection surfaces as a raise — pin that exact translation.
  # --------------------------------------------------------------------
  def test_trigger_job_under_client_mode_does_not_silently_succeed
    err = nil
    as_client do
      assert_client_mode!
      err = assert_raises(Parse::Error::AuthenticationError) do
        Parse.client.trigger_job(SYNTHETIC_JOB)
      end
    end

    assert_match(/master key/i, err.message,
                 "rejection must cite the missing master key (got: #{err.message})")
  end

  # --------------------------------------------------------------------
  # Session-token forwarding does NOT promote the call to authorized —
  # Parse Server requires master key, period. Pin that wrapping in
  # Parse.with_session changes nothing.
  # --------------------------------------------------------------------
  def test_trigger_job_under_session_token_is_still_rejected
    user, password = seed_client_user("cjob_session")

    as_client do
      me = Parse::User.login!(user.username, password)
      Parse.with_session(me.session_token) do
        assert_raises(Parse::Error::AuthenticationError) do
          Parse.client.trigger_job(SYNTHETIC_JOB)
        end
      end
    end
  end

  # --------------------------------------------------------------------
  # Master-key sanity: under master-key mode the SDK does NOT short-
  # circuit; the call reaches the server, which returns "no such job"
  # for the synthetic name. The point is "the master-key path works
  # end-to-end" — that we didn't accidentally make this endpoint
  # unconditionally fail at the SDK boundary.
  # --------------------------------------------------------------------
  def test_trigger_job_under_master_key_reaches_server
    response = nil
    with_master_key do
      response = Parse.client.trigger_job(SYNTHETIC_JOB)
    end

    # The response is the SERVER'S — could be 404 "no such job", or
    # an empty success, depending on Parse Server version. The
    # invariant we're pinning is "the SDK didn't refuse to send".
    refute_nil response, "trigger_job under master key must return a response from the wire"
  end
end
