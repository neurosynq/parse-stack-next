require_relative "../../test_helper"
require_relative "../../test_helper_integration"
require "minitest/autorun"

# Test model that uses before_validation on: :create to set defaults
class ProjectTask < Parse::Object
  property :name, :string, required: true
  property :status, :string, required: true
  property :priority, :integer, required: true
  property :assigned_by, :string

  # Set defaults before validation, only on create
  before_validation :set_defaults, on: :create

  # Track callback execution
  attr_accessor :before_validation_create_called, :before_validation_update_called

  before_validation :track_create_callback, on: :create
  before_validation :track_update_callback, on: :update

  def set_defaults
    self.status ||= "pending"
    self.priority ||= 1
  end

  def track_create_callback
    self.before_validation_create_called = true
  end

  def track_update_callback
    self.before_validation_update_called = true
  end
end

class ValidationContextIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_before_validation_on_create_sets_defaults_for_new_object
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "before_validation on: :create test") do
        # Create a new task with only name (status and priority will be set by defaults)
        task = ProjectTask.new(name: "Integration Test Task")

        # Before save, defaults should not be set yet
        assert_nil task.status, "Status should be nil before save"
        assert_nil task.priority, "Priority should be nil before save"

        # Save should trigger before_validation on: :create which sets defaults
        assert task.save, "Task should save successfully. Errors: #{task.errors.full_messages}"

        # Defaults should now be set
        assert_equal "pending", task.status, "Status should be set to default 'pending'"
        assert_equal 1, task.priority, "Priority should be set to default 1"

        # Verify callbacks were called correctly
        assert task.before_validation_create_called,
               "before_validation on: :create should be called on new object"
        assert_nil task.before_validation_update_called,
                   "before_validation on: :update should NOT be called on new object"

        # Verify saved to server
        assert task.id.present?, "Task should have an ID after save"

        # Fetch from server to verify
        fetched = ProjectTask.find(task.id)
        assert_equal "pending", fetched.status, "Status should be persisted on server"
        assert_equal 1, fetched.priority, "Priority should be persisted on server"

        puts "  Saved task: #{task.name} (status: #{task.status}, priority: #{task.priority})"
        puts "  before_validation on: :create was called: #{task.before_validation_create_called}"
      end
    end
  end

  def test_before_validation_on_create_not_called_on_update
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "before_validation on: :create not called on update test") do
        # Create and save a task
        task = ProjectTask.new(
          name: "Task for Update Test",
          status: "active",
          priority: 5,
        )
        assert task.save, "Task should save successfully"

        # Reset callback tracking
        task.before_validation_create_called = nil
        task.before_validation_update_called = nil

        # Update the task
        task.name = "Updated Task Name"
        assert task.save, "Task should update successfully"

        # on: :create callback should NOT be called on update
        assert_nil task.before_validation_create_called,
                   "before_validation on: :create should NOT be called on update"
        assert task.before_validation_update_called,
               "before_validation on: :update should be called on update"

        # Status and priority should remain unchanged (not reset to defaults)
        assert_equal "active", task.status, "Status should remain 'active'"
        assert_equal 5, task.priority, "Priority should remain 5"

        puts "  Updated task: #{task.name}"
        puts "  before_validation on: :update was called: #{task.before_validation_update_called}"
        puts "  before_validation on: :create was NOT called: #{task.before_validation_create_called.nil?}"
      end
    end
  end

  def test_defaults_not_overwritten_when_explicitly_set
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "defaults not overwritten test") do
        # Create a task with explicit values
        task = ProjectTask.new(
          name: "Explicit Values Task",
          status: "completed",
          priority: 10,
        )

        assert task.save, "Task should save successfully"

        # Explicit values should NOT be overwritten by defaults
        assert_equal "completed", task.status, "Status should remain 'completed'"
        assert_equal 10, task.priority, "Priority should remain 10"

        # Verify saved correctly on server
        fetched = ProjectTask.find(task.id)
        assert_equal "completed", fetched.status, "Status should be persisted as 'completed'"
        assert_equal 10, fetched.priority, "Priority should be persisted as 10"

        puts "  Task saved with explicit values: status=#{task.status}, priority=#{task.priority}"
      end
    end
  end

  def test_validation_context_with_conditional_validations
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "validation context with conditional validations test") do
        # Create task - defaults will be set by before_validation on: :create
        task = ProjectTask.new(name: "Conditional Validation Task")
        assert task.save, "Task should save with defaults set"
        assert task.id.present?, "Task should have ID"

        # Update - before_validation on: :create should NOT run
        # If it did run, it would try to set defaults again (but ||= prevents overwriting)
        task.assigned_by = "Test User"
        task.status = "in_progress"

        assert task.save, "Task should update successfully"
        assert_equal "in_progress", task.status, "Status should be updated"
        assert_equal "Test User", task.assigned_by, "assigned_by should be set"

        puts "  Task workflow: created with defaults, then updated"
        puts "  Final status: #{task.status}, assigned_by: #{task.assigned_by}"
      end
    end
  end
end
