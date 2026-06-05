require_relative "test_helper"
require_relative "support/docker_helper"
require_relative "support/test_server"

# Integration test helper that can work with a real Parse Server
module ParseStackIntegrationTest
  def self.included(base)
    # Start Docker containers before all tests if configured.
    # This runs once at include time, not per-test.
    if ENV["PARSE_TEST_USE_DOCKER"] == "true"
      puts "Starting Docker containers for integration tests..."
      Parse::Test::DockerHelper.ensure_available!
      Parse::Test::DockerHelper.start!
      Parse::Test::DockerHelper.setup_exit_handler
      puts "Docker containers started successfully"
    end
  end

  # Real instance methods so that `super` from a subclass setup/teardown chains
  # correctly up the ancestor stack.  The old `base.define_method :setup` pattern
  # installed the method directly on the test class, which caused a subclass
  # `def setup` to silently replace it — `super` then went to Minitest::Test#setup
  # (a no-op) instead of running Parse::Client.setup and DB reset.

  def setup
    begin
      super
    rescue NoMethodError
      # Minitest::Test#setup is a no-op and does not raise, but guard anyway.
    end

    @test_context = Parse::Test::Context.new

    puts "Setting up Parse server connection..."
    unless Parse::Test::ServerHelper.setup
      skip "Could not connect to Parse Server"
    end
    puts "Parse server connection established"

    puts "Resetting database for clean test environment..."
    Parse::Test::ServerHelper.reset_database!
    puts "Database reset completed"
  end

  def teardown
    @test_context.cleanup! if @test_context

    GC.start

    # Allow any pending operations and the server to stabilize between tests.
    sleep 1

    begin
      super
    rescue NoMethodError
      # No further teardown in the chain.
    end
  end

  # Helper methods available in tests
  def with_parse_server(&block)
    Parse::Test::ServerHelper.with_server(&block)
  end

  def create_test_object(class_name, attributes = {})
    # className is on the mass-assignment denylist now, so setting it
    # through the attributes hash no longer overrides Parse::Object's
    # own parse_class ("Parse::Object"). Resolve to the registered
    # subclass instead so the create routes through the right table.
    klass = Parse::Object.find_class(class_name) || Parse::Object
    obj = klass.new(attributes)
    obj.save
    @test_context.track(obj)
    obj
  end

  def create_test_user(attributes = {})
    user = Parse::Test::ServerHelper.create_test_user(**attributes)
    @test_context.track(user)
    user
  end

  def reset_database!
    Parse::Test::ServerHelper.reset_database!
  end

  # Obtain a live session token for a freshly-created user by logging in.
  #
  # Parse Server 9.x does NOT return a session token from a master-key signup
  # (`Parse::User.new(...).save` / `signup!` on the default master client) — it
  # treats master-key user creation as admin provisioning. Tests that need an
  # authenticated user session therefore log in right after signup. Pass the
  # just-saved user and the plaintext password; the user's `#session_token` is
  # populated on return. No-ops if a token is already present (e.g. a client-mode
  # signup that already issued one).
  #
  # @param user [Parse::User] a user that has already been saved/signed up.
  # @param password [String] the plaintext password used at signup.
  # @return [Parse::User] the same user, now carrying a live `#session_token`.
  def login_after_signup!(user, password)
    return user if user.session_token.present?
    assert user.login!(password),
           "login after signup must succeed to obtain a session token for #{user.username.inspect}"
    user
  end
end

# Example usage in tests:
# class MyIntegrationTest < Minitest::Test
#   include ParseStackIntegrationTest
#
#   def test_something_with_real_server
#     with_parse_server do
#       user = create_test_user(username: 'testuser')
#       assert user.id.present?
#     end
#   end
# end
