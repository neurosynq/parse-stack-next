require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"

# End-to-end coverage for +Parse::API::Server#server_info+ and
# +#server_health+ under client mode. These endpoints have ASYMMETRIC
# authorization in Parse Server:
#
#   * +GET /parse/health+   — credential-free probe (load-balancer use).
#                              Must succeed under client mode.
#   * +GET /parse/serverInfo+ — master-key required. Under client mode
#                              the request must surface the 403 rather
#                              than silently smuggling a token.
#
# This file pins both halves of that contract so a future "make
# serverInfo public" refactor or "tighten /health" change doesn't
# regress the SDK boundary behavior.
class ClientRestServerInfoIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
  end

  # --------------------------------------------------------------------
  # /health: credential-free, must work under client mode.
  # --------------------------------------------------------------------
  def test_server_health_works_under_client_mode
    as_client do
      assert_client_mode!
      assert Parse.client.server_health,
             "server_health must report OK under client mode (credential-free endpoint)"
    end
  end

  # --------------------------------------------------------------------
  # /serverInfo: master-key only on Parse Server. Under client mode
  # the SDK must surface the 403 rather than silently succeeding under
  # a smuggled credential. Load-bearing: any other behavior means the
  # auth boundary leaked.
  # --------------------------------------------------------------------
  def test_server_info_requires_master_key_under_client_mode
    err = nil
    as_client do
      assert_client_mode!
      err = assert_raises(Parse::Error::AuthenticationError) do
        Parse.client.server_info!
      end
    end
    assert_match(/master key/i, err.message,
                 "rejection must cite the missing master key (got: #{err.message})")
  end

  # --------------------------------------------------------------------
  # /serverInfo under master-key mode: returns a hash with the canonical
  # +parseServerVersion+ key. Pins that the master-key path works and
  # the SDK extracts the version it needs for deprecation warnings.
  # --------------------------------------------------------------------
  def test_server_info_works_under_master_key
    info = nil
    with_master_key do
      info = Parse.client.server_info!
    end

    refute_nil info, "server_info must return a hash under master key"
    assert info.key?(:parseServerVersion) || info.key?("parseServerVersion"),
           "server_info must include parseServerVersion (got keys: #{info.keys.inspect})"
  end
end
