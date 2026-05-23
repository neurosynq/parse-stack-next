require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"

# End-to-end coverage for the master-key gate on +Parse::API::Push#push+.
# Parse Server's +POST /parse/push+ endpoint is master-key-only — there
# is no session-token authorization model for sending pushes. The SDK
# guard ({Parse::API::Push#push}) fails closed when the client has no
# master key configured, so a client-mode caller cannot accidentally
# (a) ship a push payload bearing the master key if one happens to be
# in the ambient client, or (b) hit the server at all and get a
# silent-success response.
#
# Two assertions:
#   1. Under client mode (no master key), +Parse.client.push+ raises
#      +Parse::Error::AuthenticationError+ at the SDK boundary,
#      BEFORE any network request leaves the process.
#   2. Under master-key mode the call reaches Parse Server. The test
#      server has no actual push adapter configured, so the response
#      will surface a server-side error rather than a successful
#      delivery — what we pin is "the SDK no longer short-circuits."
class ClientRestPushMasterOnlyIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  # --------------------------------------------------------------------
  # Client-mode: SDK guard raises before the request leaves the process.
  # This is the load-bearing assertion — it must fail closed regardless
  # of what the server would have done.
  # --------------------------------------------------------------------
  def test_push_under_client_mode_raises_authentication_error
    as_client do
      assert_client_mode!
      err = assert_raises(Parse::Error::AuthenticationError) do
        Parse.client.push({ where: { deviceType: "ios" }, data: { alert: "hi" } })
      end
      assert_match(/master key/i, err.message)
    end
  end

  # --------------------------------------------------------------------
  # Sanity: the guard is conditional on master_key presence, not
  # unconditionally locked. Under master-key mode the SDK does NOT
  # raise; the call reaches the server. We don't pin server response
  # shape (the test Parse Server has no push adapter), only that the
  # SDK boundary check passes through.
  # --------------------------------------------------------------------
  def test_push_under_master_key_does_not_short_circuit_in_sdk
    with_master_key do
      # Whatever Parse Server returns (success, server-error, etc.),
      # the SDK must NOT have raised AuthenticationError on the boundary.
      begin
        Parse.client.push({ where: { deviceType: "ios" }, data: { alert: "hi" } })
      rescue Parse::Error::AuthenticationError => e
        flunk "SDK guard must not raise under master-key mode (got: #{e.message})"
      rescue Parse::Error
        # Expected on the test server (no push adapter configured).
      end
    end
  end

  # --------------------------------------------------------------------
  # Per-call override: even under client mode, if the caller passes
  # use_master_key: true the SDK still has no master key to send and
  # the guard must fire. This pins that the guard is checking the
  # client's master_key, not the opts flag.
  # --------------------------------------------------------------------
  def test_push_under_client_mode_with_use_master_key_opt_still_raises
    as_client do
      assert_client_mode!
      assert_raises(Parse::Error::AuthenticationError) do
        Parse.client.push(
          { where: { deviceType: "ios" }, data: { alert: "hi" } },
          use_master_key: true,
        )
      end
    end
  end
end
