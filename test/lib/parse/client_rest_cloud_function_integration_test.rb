require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"

# End-to-end coverage for +Parse::API::CloudFunctions#call_function+
# and +#call_function_with_session+ under client mode. Parse Server's
# +POST /functions/<name>+ accepts both unauthenticated and session-
# token-authenticated calls (subject to the function's own
# +requireMaster+ / +requireUser+ option), so this surface MUST work
# end-to-end without master key.
#
# What this pins:
#   1. An unauthenticated cloud function call (test fixture: +hello+)
#      succeeds under client mode and returns its result.
#   2. A function that reads +request.user+ (test fixture: +testFunction+)
#      sees the actual user under +call_function_with_session+.
#   3. A function with +requireMaster: true+ (test fixture:
#      +getCapturedAnalyticsEvents+) is REJECTED under client mode
#      rather than silently smuggling a token.
#
# Test cloud-code fixtures live in +test/cloud/main.js+:
#   * +hello+, +helloName+, +testFunction+ — open
#   * +getCapturedAnalyticsEvents+, +resetCapturedAnalyticsEvents+ —
#     +requireMaster: true+
class ClientRestCloudFunctionIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  # --------------------------------------------------------------------
  # Open function: anonymous-callable, returns a string. The SDK must
  # NOT short-circuit on absent master key; the call must reach the
  # server and return the function's value.
  # --------------------------------------------------------------------
  def test_open_cloud_function_works_under_client_mode_unauthenticated
    response = nil
    as_client do
      assert_client_mode!
      response = Parse.client.call_function("hello")
    end

    assert response.success?, "open cloud function must succeed under client mode (got: #{response.inspect})"
    assert_equal "Hello world!", response.result["result"]
  end

  # --------------------------------------------------------------------
  # Open function with params: confirms the body is forwarded.
  # --------------------------------------------------------------------
  def test_cloud_function_forwards_params_under_client_mode
    response = nil
    as_client do
      response = Parse.client.call_function("helloName", { name: "Ada" })
    end

    assert response.success?, response.inspect
    assert_equal "Hello Ada!", response.result["result"]
  end

  # --------------------------------------------------------------------
  # Session-token forwarding: the cloud function's +request.user+ must
  # resolve to the calling user when the call is wrapped in
  # +Parse.with_session+. This is the load-bearing assertion that the
  # session header is actually attached to /functions/<name> requests.
  # --------------------------------------------------------------------
  def test_cloud_function_sees_request_user_under_session_token
    user, password = seed_client_user("cf_user")

    response = nil
    as_client do
      me = Parse::User.login!(user.username, password)
      refute_nil me.session_token, "precondition: login must mint a session"

      Parse.with_session(me.session_token) do
        response = Parse.client.call_function("testFunction", { foo: "bar" })
      end
    end

    assert response.success?, "call_function under session must succeed (got: #{response.inspect})"
    result = response.result["result"]
    assert_equal user.username, result["user"],
                 "cloud function must see the session-token user as request.user " \
                 "(got: #{result.inspect})"
    assert_equal({ "foo" => "bar" }, result["params"])
  end

  # --------------------------------------------------------------------
  # call_function_with_session convenience: same end state, different
  # plumbing — proves the convenience method threads the token via opts.
  # --------------------------------------------------------------------
  def test_call_function_with_session_helper_authenticates
    user, password = seed_client_user("cf_helper")

    response = nil
    as_client do
      me = Parse::User.login!(user.username, password)
      response = Parse.client.call_function_with_session(
        "testFunction", { hello: "world" }, me.session_token,
      )
    end

    assert response.success?, response.inspect
    assert_equal user.username, response.result["result"]["user"]
  end

  # --------------------------------------------------------------------
  # requireMaster gate: a function declared +{ requireMaster: true }+
  # MUST be rejected by Parse Server when the calling client has no
  # master key. The contract here is intentionally different from
  # +trigger_job+ (background jobs): Parse Server rejects requireMaster
  # CLOUD FUNCTIONS with HTTP 200 + a cloud-code error code in the body
  # (typically 141 / +SCRIPT_FAILED+), so +call_function+ returns a
  # failed +Parse::Response+ rather than raising — the SDK's 401/403
  # middleware (see +Parse::Client#request+) doesn't kick in. Jobs, by
  # contrast, return HTTP 403 and DO raise +AuthenticationError+; that
  # asymmetry is pinned in +client_rest_cloud_job_integration_test.rb+.
  #
  # What we pin here:
  #   * The SDK did not short-circuit (no nil response, no exception).
  #   * +response.success?+ is false and +response.error?+ is true.
  #   * +response.code+ is a real Parse-error code (non-nil, > 0),
  #     proving the failure came from the wire and not an SDK-side
  #     fabrication. If a future Parse Server version starts returning
  #     HTTP 403 here, this test will turn into +assert_raises+ and
  #     the change needs to be a deliberate edit.
  # --------------------------------------------------------------------
  def test_require_master_function_rejected_under_client_mode
    response = nil
    as_client do
      assert_client_mode!
      response = Parse.client.call_function("getCapturedAnalyticsEvents")
    end

    refute_nil response, "SDK must not short-circuit on requireMaster (got nil response)"
    refute response.success?,
           "requireMaster function must NOT succeed under client mode " \
           "(got: #{response.inspect})"
    assert response.error?,
           "response must report error (got: #{response.inspect})"
    refute_nil response.code,
               "rejection must carry a Parse error code from the wire " \
               "(got: #{response.inspect})"
    assert response.code.to_i.positive?,
           "Parse error code must be a real positive code, not 0 / sentinel " \
           "(got: #{response.code.inspect})"
  end

  # --------------------------------------------------------------------
  # Master-key sanity: under master-key mode the requireMaster function
  # IS callable and returns its actual payload. Pins that the guard is
  # gating on the wire credential, not unconditionally locked.
  # --------------------------------------------------------------------
  def test_require_master_function_works_under_master_key
    response = nil
    with_master_key do
      response = Parse.client.call_function("getCapturedAnalyticsEvents")
    end

    assert response.success?,
           "requireMaster function must succeed under master key (got: #{response.inspect})"
    assert_kind_of Array, response.result["result"]
  end
end
