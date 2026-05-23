require_relative "../../test_helper_integration"
require_relative "../../support/client_mode_helper"
require "securerandom"

# /parse/config (Cloud Config / app config) from the SDK-as-client side.
#
# Parse Server's GET /config returns the global app config to any caller
# — anonymous or authenticated — but it AUTOMATICALLY strips entries
# whose `masterKeyOnly` flag is `true` when the caller is not the master
# key. The client never even sees the master-only values. This test
# proves the SDK relays both the visible and stripped behaviors and
# refuses to write config from a non-master client.
class ClientRestCloudConfigIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  include Parse::Test::ClientModeHelper

  PUBLIC_KEY    = "client_public_flag"
  MASTER_ONLY_K = "client_master_only_secret"

  def setup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"
    super
    @user, @password = seed_client_user("ccfg")

    with_master_key do
      Parse.client.config!     # force cache refresh from server
      Parse.client.update_config(
        { PUBLIC_KEY => "visible-to-all", MASTER_ONLY_K => "for-admin-eyes-only" },
        master_key_only: { PUBLIC_KEY => false, MASTER_ONLY_K => true },
      )
      Parse.client.config!     # repopulate cache with new values
    end
  end

  # --------------------------------------------------------------------
  # An authed (non-master) client can READ the public config key. The
  # SDK's no-master client must round-trip the value.
  # --------------------------------------------------------------------
  def test_authed_client_can_read_public_config_key
    as_client do
      logged_in = Parse::User.login(@user.username, @password)
      assert logged_in

      # Force a fresh fetch under the no-master client so we observe
      # what the server sends, not the master-cached value.
      Parse.client.config!
      values = Parse.client.config
      assert_kind_of Hash, values
      assert_equal "visible-to-all", values[PUBLIC_KEY],
                   "public config key must be readable by a non-master client"
    end
  end

  # --------------------------------------------------------------------
  # The master-only key must NOT appear in the client-side response.
  # Parse Server strips masterKeyOnly entries before sending; the SDK
  # must not synthesize them from a cache that happens to know better.
  # --------------------------------------------------------------------
  def test_master_only_config_key_is_hidden_from_client
    as_client do
      Parse::User.login(@user.username, @password)

      Parse.client.config!
      values = Parse.client.config
      refute values.key?(MASTER_ONLY_K),
             "master-only config key must be invisible to non-master callers, got: #{values.inspect}"

      # config_entries should also filter master-only entries by default.
      entries = Parse.client.config_entries
      refute entries.key?(MASTER_ONLY_K),
             "config_entries(master: false) must exclude master-only keys"
    end
  end

  # --------------------------------------------------------------------
  # Anonymous (no session) client must ALSO see the public key (Parse
  # Server's /config does not require auth by default) but must NOT see
  # the master-only key.
  # --------------------------------------------------------------------
  def test_anonymous_client_sees_public_but_not_master_only
    as_client do
      Parse.client.config!
      values = Parse.client.config
      assert_equal "visible-to-all", values[PUBLIC_KEY],
                   "anonymous client should still see public config keys"
      refute values.key?(MASTER_ONLY_K),
             "anonymous client must not see master-only config keys"
    end
  end

  # --------------------------------------------------------------------
  # A non-master client must NOT be able to WRITE the config — even for
  # a public key. /config PUT is master-only in Parse Server.
  # --------------------------------------------------------------------
  def test_client_cannot_write_config_without_master_key
    as_client do
      logged_in = Parse::User.login(@user.username, @password)

      attempted_value = "hijacked-by-client-#{SecureRandom.hex(2)}"
      begin
        wrote = Parse.client.update_config(
          { PUBLIC_KEY => attempted_value },
        )
        refute wrote, "non-master client must not be able to write /config"
      rescue Parse::Error => e
        assert_match(/master|unauthor|forbidden|permission|not allowed/i, e.message,
                     "config write rejection should be an auth-class error, got: #{e.message}")
      end

      # Confirm via master that the value did NOT change.
      with_master_key do
        Parse.client.config!
        current = Parse.client.config[PUBLIC_KEY]
        refute_equal attempted_value, current,
                     "config value must not reflect unauthorized client write"
      end

      # Even with a valid session token threaded explicitly, /config PUT
      # is still master-only.
      session_attempt = Parse.client.request(
        :put, "config",
        body: { params: { PUBLIC_KEY => "via-session" } },
        opts: { session_token: logged_in.session_token, use_master_key: false },
      ) rescue $!
      refute(session_attempt.is_a?(Parse::Response) && session_attempt.success?,
             "PUT /config under a session token (no master) must not succeed: #{session_attempt.inspect}")
    end
  end

  # --------------------------------------------------------------------
  # The master_key_only flag map exposes which keys are restricted.
  # When read by a non-master client, Parse Server returns an empty
  # masterKeyOnly map (since it stripped those entries entirely). The
  # SDK exposes this via Parse.client.master_key_only.
  # --------------------------------------------------------------------
  def test_master_key_only_flag_map_visibility_differs_by_caller
    with_master_key do
      Parse.client.config!
      master_flags = Parse.client.master_key_only
      assert master_flags[MASTER_ONLY_K],
             "master key caller must observe masterKeyOnly flag for restricted key"
    end

    as_client do
      Parse.client.config!
      client_flags = Parse.client.master_key_only
      refute client_flags[MASTER_ONLY_K],
             "non-master caller must not see masterKeyOnly metadata for hidden keys"
    end
  end
end
