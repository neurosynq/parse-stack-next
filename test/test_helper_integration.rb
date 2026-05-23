require_relative 'test_helper'
require_relative 'support/docker_helper'
require_relative 'support/test_server'

# Integration test helper that can work with a real Parse Server
module ParseStackIntegrationTest
  def self.included(base)
    # Start Docker containers before all tests if configured
    if ENV['PARSE_TEST_USE_DOCKER'] == 'true'
      puts "Starting Docker containers for integration tests..."
      Parse::Test::DockerHelper.ensure_available!
      Parse::Test::DockerHelper.start!
      Parse::Test::DockerHelper.setup_exit_handler
      puts "Docker containers started successfully"
    end

    # Add setup method to the including class
    base.define_method :setup do
      # Call super first to handle any parent setup
      begin
        super()
      rescue NoMethodError
        # No super method, continue
      end
      
      @test_context = Parse::Test::Context.new
      
      puts "Setting up Parse server connection..."
      # Setup Parse server connection
      unless Parse::Test::ServerHelper.setup
        skip "Could not connect to Parse Server"
      end
      puts "Parse server connection established"
      
      # Reset database to ensure clean test data
      puts "Resetting database for clean test environment..."
      Parse::Test::ServerHelper.reset_database!
      puts "Database reset completed"
    end

    # Add teardown method to the including class
    base.define_method :teardown do
      @test_context.cleanup! if @test_context
      
      # Force garbage collection to free memory
      GC.start
      
      # Longer delay to let any pending operations complete and server stabilize
      sleep 1
      
      super() if defined?(super)
    end
  end

  # Helper methods available in tests
  def with_parse_server(&block)
    Parse::Test::ServerHelper.with_server(&block)
  end

  def create_test_object(class_name, attributes = {})
    obj = Parse::Object.new(attributes.merge('className' => class_name))
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