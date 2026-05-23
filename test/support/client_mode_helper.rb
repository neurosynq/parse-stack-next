require "securerandom"

# Test harness for "SDK-as-Parse-client" coverage.
#
# These tests exercise parse-stack-next the way an unprivileged Parse
# client would use it: REST only, session-token authentication, no master
# key, no mongo-direct path. The intent is to lock in the behavior a
# downstream app gets when it ships the SDK in a context where the master
# key is NOT trusted to the process (mobile background sync, untrusted
# worker, etc.) and to assert the convenience surface (signup, login,
# logout, current_user, file upload, LiveQuery auth) works end-to-end.
#
# Mechanics:
#   1. ParseStackIntegrationTest#setup configures the default client WITH
#      the master key (needed to reset the DB between tests).
#   2. This helper, included after, swaps the :default client for one
#      with master_key: nil for the duration of each test. All SDK calls
#      that resolve `Parse.client` implicitly (Parse::Object#save,
#      Parse::Query#results, Parse::User.login, Parse::File#save, ...)
#      route through the no-master-key client.
#   3. teardown restores the master-key client so the integration helper
#      can clean up tracked objects and reset the DB.
#
# Privileged setup (seeding users, granting CLP, pre-creating schemas)
# can still run before the swap via #with_master_key.
module Parse
  module Test
    module ClientModeHelper
      def setup
        super
        @master_client = Parse::Client.client
        @no_master_client = Parse::Client.new(
          server_url: @master_client.server_url,
          app_id: @master_client.application_id,
          api_key: @master_client.api_key,
          master_key: nil,
          logging: ENV["PARSE_DEBUG"] ? :debug : false,
        )
      end

      def teardown
        restore_master_client!
        super
      end

      # Run a block with the master-key client active. Use for privileged
      # setup steps the test fixture needs (creating roles, setting CLP,
      # seeding users that other test code will log in as).
      def with_master_key
        prior = Parse::Client.clients[:default]
        Parse::Client.clients[:default] = @master_client
        invalidate_model_client_cache!
        yield
      ensure
        Parse::Client.clients[:default] = prior
        invalidate_model_client_cache!
      end

      # Swap the default client to the no-master-key client. Call this
      # immediately before the assertions that need to run as a regular
      # client. Tests can call this directly or use #as_client.
      def use_client_mode!
        Parse::Client.clients[:default] = @no_master_client
        invalidate_model_client_cache!
      end

      def restore_master_client!
        return unless @master_client
        Parse::Client.clients[:default] = @master_client
        invalidate_model_client_cache!
      end

      # Run a block under client mode. Restores the master-key client
      # afterward so per-test teardown / cleanup keeps working.
      def as_client
        use_client_mode!
        yield
      ensure
        restore_master_client!
      end

      # Parse::Object subclasses cache `@client` at the class level
      # (lib/parse/client.rb#ClassMethods#client uses `||=`). That means
      # once Parse::Object.client has been resolved against the singleton
      # `Parse::Client.client`, reassigning `Parse::Client.clients[:default]`
      # has no effect on already-cached classes — they keep using the
      # original client object. We force a re-resolve on every swap by
      # clearing `@client` on Parse::Object and every descendant. This
      # is test-only surgery; nothing in production should swap the
      # default client at runtime.
      def invalidate_model_client_cache!
        klasses = []
        klasses.concat([Parse::Object, *Parse::Object.descendants]) if defined?(Parse::Object)
        klasses << Parse::Query if defined?(Parse::Query)
        klasses.each do |klass|
          klass.remove_instance_variable(:@client) if klass.instance_variable_defined?(:@client)
        end
      end

      # Seed a user under the master-key client, then return both the
      # persisted user (with its session_token from signup-on-save) and
      # the password used so callers can re-login as needed.
      def seed_client_user(prefix = "cu")
        username = "#{prefix}_#{SecureRandom.hex(4)}"
        password = "p4ssw0rd!#{SecureRandom.hex(2)}"
        user = nil
        with_master_key do
          user = Parse::User.new(
            username: username,
            password: password,
            email: "#{username}@test.com",
          )
          assert user.save, "seeded user must save"
          @test_context.track(user)
        end
        [user, password]
      end

      # Assert that the call made the expected REST shape under client
      # auth — i.e. it actually used the no-master client. Used to catch
      # tests that silently swap the client back without intending to.
      def assert_client_mode!
        refute Parse::Client.client.master_key.present?,
               "expected default client to be in client-mode (no master key) but it has one"
      end
    end
  end
end
