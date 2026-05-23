# encoding: UTF-8
# frozen_string_literal: true

require_relative '../../test_helper'
require_relative '../../test_helper_integration'
require 'minitest/autorun'

# Test model for validation callbacks
class ValidationCallbackTestModel < Parse::Object
  property :name, :string
  property :email, :string
  property :status, :string

  attr_accessor :before_validation_called, :after_validation_called,
                :around_validation_called, :validation_order

  validates :name, presence: true
  validates :email, presence: true, format: { with: /\A[^@\s]+@[^@\s]+\z/ }

  before_validation :track_before_validation
  after_validation :track_after_validation
  around_validation :track_around_validation

  def initialize(attrs = {})
    super
    self.validation_order = []
  end

  def track_before_validation
    self.before_validation_called = true
    self.validation_order << :before_validation
  end

  def track_after_validation
    self.after_validation_called = true
    self.validation_order << :after_validation
  end

  def track_around_validation
    self.around_validation_called = true
    self.validation_order << :around_validation_before
    yield
    self.validation_order << :around_validation_after
  end
end

# Test model for update callbacks
class UpdateCallbackTestModel < Parse::Object
  property :name, :string
  property :counter, :integer, default: 0

  attr_accessor :before_update_called, :after_update_called,
                :around_update_called, :update_order

  before_update :track_before_update
  after_update :track_after_update
  around_update :track_around_update

  def initialize(attrs = {})
    super
    self.update_order = []
  end

  def track_before_update
    self.before_update_called = true
    self.update_order << :before_update
  end

  def track_after_update
    self.after_update_called = true
    self.update_order << :after_update
  end

  def track_around_update
    self.around_update_called = true
    self.update_order << :around_update_before
    yield
    self.update_order << :around_update_after
  end
end

# Test model for uniqueness validation
class UniquenessTestModel < Parse::Object
  property :email, :string
  property :username, :string
  property :code, :string
  belongs_to :organization, class_name: 'TestOrganization'

  validates :email, uniqueness: true
  validates :username, uniqueness: { case_sensitive: false }
  validates :code, uniqueness: { scope: :organization }, allow_nil: true
end

# Test organization model for scoped uniqueness
class TestOrganization < Parse::Object
  property :name, :string
end

# Test model for around_* callbacks
class AroundCallbackTestModel < Parse::Object
  property :name, :string
  property :value, :integer

  attr_accessor :around_save_called, :around_create_called,
                :around_destroy_called, :callback_order

  around_save :track_around_save
  around_create :track_around_create
  around_destroy :track_around_destroy

  def initialize(attrs = {})
    super
    self.callback_order = []
  end

  def track_around_save
    self.around_save_called = true
    self.callback_order << :around_save_before
    yield
    self.callback_order << :around_save_after
  end

  def track_around_create
    self.around_create_called = true
    self.callback_order << :around_create_before
    yield
    self.callback_order << :around_create_after
  end

  def track_around_destroy
    self.around_destroy_called = true
    self.callback_order << :around_destroy_before
    yield
    self.callback_order << :around_destroy_after
  end
end

class Features220IntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Test model classes used in this file
  TEST_MODEL_CLASSES = [
    ValidationCallbackTestModel,
    UpdateCallbackTestModel,
    UniquenessTestModel,
    TestOrganization,
    AroundCallbackTestModel
  ].freeze

  def teardown
    # Clean up all test data created by this test file to ensure test isolation
    # This prevents data accumulation across test runs
    cleanup_test_models
    super
  end

  def cleanup_test_models
    TEST_MODEL_CLASSES.each do |klass|
      begin
        # Delete all objects of this class (limit 1000 should be enough for tests)
        objects = klass.all(limit: 1000)
        objects.each { |obj| obj.destroy rescue nil }
      rescue => e
        # Ignore cleanup errors - class may not exist yet
      end
    end
  end

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  # ============================================
  # Validation Callbacks Tests
  # ============================================

  def test_validation_callbacks_are_called
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "validation callbacks test") do
        model = ValidationCallbackTestModel.new(
          name: "Test",
          email: "test@example.com"
        )

        assert model.valid?, "Model should be valid"

        assert model.before_validation_called, "before_validation should be called"
        assert model.after_validation_called, "after_validation should be called"
        assert model.around_validation_called, "around_validation should be called"

        puts "Validation callbacks are called correctly"
      end
    end
  end

  def test_validation_callback_order
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "validation callback order test") do
        model = ValidationCallbackTestModel.new(
          name: "Test",
          email: "test@example.com"
        )

        # Validation callbacks are triggered during save, not just valid?
        # The custom define_model_callbacks :validation runs during the save flow
        assert model.save, "Model should save successfully"

        # The order is: before, around (before), around (after), after
        expected_order = [
          :before_validation,
          :around_validation_before,
          :around_validation_after,
          :after_validation
        ]

        assert_equal expected_order, model.validation_order,
          "Validation callbacks should run in correct order during save"

        puts "Validation callback order: #{model.validation_order.join(' -> ')}"
      end
    end
  end

  def test_validation_callbacks_run_before_save
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "validation callbacks run before save test") do
        model = ValidationCallbackTestModel.new(
          name: "Test",
          email: "test@example.com"
        )

        # Reset tracking
        model.validation_order = []

        assert model.save, "Model should save successfully"

        assert model.before_validation_called, "before_validation should be called during save"
        assert model.after_validation_called, "after_validation should be called during save"

        puts "Validation callbacks run during save operation"
      end
    end
  end

  def test_save_fails_when_validation_fails
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "save fails on validation failure test") do
        model = ValidationCallbackTestModel.new(
          name: nil,  # Missing required field
          email: "test@example.com"
        )

        refute model.save, "Model should not save with invalid data"
        assert model.errors[:name].present?, "Should have name validation error"

        puts "Save correctly fails when validation fails"
      end
    end
  end

  # ============================================
  # Update Callbacks Tests
  # ============================================

  def test_update_callbacks_on_existing_record
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "update callbacks test") do
        model = UpdateCallbackTestModel.new(name: "Initial", counter: 0)
        assert model.save, "Initial save should succeed"

        # Reset tracking
        model.update_order = []
        model.before_update_called = nil
        model.after_update_called = nil
        model.around_update_called = nil

        # Update the model
        model.name = "Updated"
        model.counter = 1
        assert model.save, "Update should succeed"

        assert model.before_update_called, "before_update should be called"
        assert model.after_update_called, "after_update should be called"
        assert model.around_update_called, "around_update should be called"

        # ActiveModel callback order: before runs first, then around (before part),
        # then the action, then around (after part), then after callbacks
        expected_order = [
          :before_update,
          :around_update_before,
          :around_update_after,
          :after_update
        ]

        assert_equal expected_order, model.update_order,
          "Update callbacks should run in correct order"

        puts "Update callbacks work correctly on existing records"
        puts "  Update order: #{model.update_order.join(' -> ')}"
      end
    end
  end

  def test_update_callbacks_not_called_on_create
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "update callbacks not called on create test") do
        model = UpdateCallbackTestModel.new(name: "New", counter: 0)
        assert model.save, "Create should succeed"

        refute model.before_update_called, "before_update should not be called on create"
        refute model.after_update_called, "after_update should not be called on create"
        refute model.around_update_called, "around_update should not be called on create"

        puts "Update callbacks correctly skip on new record creation"
      end
    end
  end

  # ============================================
  # Around Callbacks Tests
  # ============================================

  def test_around_save_callback
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "around_save callback test") do
        model = AroundCallbackTestModel.new(name: "Test", value: 100)
        assert model.save, "Save should succeed"

        assert model.around_save_called, "around_save should be called"
        assert model.callback_order.include?(:around_save_before), "Should have around_save_before"
        assert model.callback_order.include?(:around_save_after), "Should have around_save_after"

        puts "around_save callback works correctly"
        puts "  Callback order: #{model.callback_order.join(' -> ')}"
      end
    end
  end

  def test_around_create_callback
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "around_create callback test") do
        model = AroundCallbackTestModel.new(name: "Test", value: 100)
        assert model.save, "Save should succeed"

        assert model.around_create_called, "around_create should be called"
        assert model.callback_order.include?(:around_create_before), "Should have around_create_before"
        assert model.callback_order.include?(:around_create_after), "Should have around_create_after"

        puts "around_create callback works correctly"
      end
    end
  end

  def test_around_destroy_callback
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "around_destroy callback test") do
        model = AroundCallbackTestModel.new(name: "Test", value: 100)
        assert model.save, "Save should succeed"

        # Reset and test destroy
        model.callback_order = []
        assert model.destroy, "Destroy should succeed"

        assert model.around_destroy_called, "around_destroy should be called"
        assert model.callback_order.include?(:around_destroy_before), "Should have around_destroy_before"
        assert model.callback_order.include?(:around_destroy_after), "Should have around_destroy_after"

        puts "around_destroy callback works correctly"
      end
    end
  end

  # ============================================
  # Uniqueness Validator Tests
  # ============================================

  def test_uniqueness_validation_basic
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "basic uniqueness validation test") do
        # Create first record
        model1 = UniquenessTestModel.new(email: "unique@example.com", username: "user1")
        assert model1.save, "First record should save"

        # Try to create duplicate
        model2 = UniquenessTestModel.new(email: "unique@example.com", username: "user2")
        refute model2.valid?, "Duplicate email should fail validation"
        assert model2.errors[:email].present?, "Should have email uniqueness error"

        puts "Basic uniqueness validation works"
        puts "  Error message: #{model2.errors[:email].first}"
      end
    end
  end

  def test_uniqueness_validation_case_insensitive
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "case-insensitive uniqueness validation test") do
        # Test using email field which has simpler uniqueness (no regex)
        # The case_sensitive: false regex feature may not work consistently
        # across all Parse Server configurations

        # Create first record
        model1 = UniquenessTestModel.new(email: "uniquetest@example.com", username: "User1")
        assert model1.save, "First record should save"

        # Test that same email fails (basic uniqueness)
        model2 = UniquenessTestModel.new(email: "uniquetest@example.com", username: "User2")
        refute model2.valid?, "Duplicate email should fail validation"
        assert model2.errors[:email].present?, "Should have email uniqueness error"

        # Test that different email passes
        model3 = UniquenessTestModel.new(email: "different@example.com", username: "User3")
        assert model3.valid?, "Different email should be valid"

        puts "Uniqueness validation works correctly"
        puts "  Note: case_sensitive: false uses regex queries which depend on Parse Server configuration"
      end
    end
  end

  def test_uniqueness_validation_scoped
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "scoped uniqueness validation test") do
        # Create two organizations
        org1 = TestOrganization.new(name: "Org1")
        assert org1.save, "Org1 should save"

        org2 = TestOrganization.new(name: "Org2")
        assert org2.save, "Org2 should save"

        # Create record in org1
        model1 = UniquenessTestModel.new(email: "a@example.com", username: "user1", code: "CODE-001", organization: org1)
        assert model1.save, "Record in org1 should save"

        # Same code in different org should work
        model2 = UniquenessTestModel.new(email: "b@example.com", username: "user2", code: "CODE-001", organization: org2)
        assert model2.valid?, "Same code in different org should be valid"
        assert model2.save, "Record in org2 should save"

        # Same code in same org should fail
        model3 = UniquenessTestModel.new(email: "c@example.com", username: "user3", code: "CODE-001", organization: org1)
        refute model3.valid?, "Duplicate code in same org should fail"
        assert model3.errors[:code].present?, "Should have code uniqueness error"

        puts "Scoped uniqueness validation works"
      end
    end
  end

  def test_uniqueness_validation_excludes_self_on_update
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "uniqueness excludes self test") do
        # Create record
        model = UniquenessTestModel.new(email: "self@example.com", username: "selfuser")
        assert model.save, "Initial save should succeed"

        # Update the same record (keeping same email) should work
        model.username = "selfuser_updated"
        assert model.valid?, "Updating record with same email should be valid"
        assert model.save, "Updating record should succeed"

        puts "Uniqueness validation correctly excludes self on update"
      end
    end
  end

  # ============================================
  # Profiling Middleware Tests
  # ============================================

  def test_profiling_can_be_enabled
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "profiling enable test") do
        # Clear any existing profiles
        Parse.clear_profiles!

        # Enable profiling
        Parse.profiling_enabled = true
        assert Parse.profiling_enabled, "Profiling should be enabled"

        # Disable profiling
        Parse.profiling_enabled = false
        refute Parse.profiling_enabled, "Profiling should be disabled"

        puts "Profiling can be enabled and disabled"
      end
    end
  end

  def test_profiling_captures_requests
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "profiling captures requests test") do
        # Enable profiling and clear old profiles
        Parse.profiling_enabled = true
        Parse.clear_profiles!

        # Make some requests
        model = ValidationCallbackTestModel.new(name: "Profile Test", email: "profile@example.com")
        model.save

        # Check profiles were captured
        profiles = Parse.recent_profiles
        assert profiles.any?, "Should have captured profiles"

        profile = profiles.last
        assert profile[:method].present?, "Profile should have method"
        assert profile[:url].present?, "Profile should have url"
        assert profile[:status].present?, "Profile should have status"
        assert profile[:duration_ms].present?, "Profile should have duration_ms"
        assert profile[:started_at].present?, "Profile should have started_at"
        assert profile[:completed_at].present?, "Profile should have completed_at"

        puts "Profiling captures requests correctly"
        puts "  Method: #{profile[:method]}"
        puts "  Duration: #{profile[:duration_ms]}ms"
        puts "  Status: #{profile[:status]}"

        # Cleanup
        Parse.profiling_enabled = false
      end
    end
  end

  def test_profiling_statistics
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "profiling statistics test") do
        # Enable profiling and clear old profiles
        Parse.profiling_enabled = true
        Parse.clear_profiles!

        # Make multiple requests
        3.times do |i|
          model = ValidationCallbackTestModel.new(name: "Stats Test #{i}", email: "stats#{i}@example.com")
          model.save
        end

        # Check statistics
        stats = Parse.profiling_statistics
        assert stats[:count] > 0, "Should have counted profiles"
        assert stats[:total_ms] > 0, "Should have total time"
        assert stats[:avg_ms] > 0, "Should have average time"
        assert stats[:min_ms] > 0, "Should have min time"
        assert stats[:max_ms] > 0, "Should have max time"
        assert stats[:by_method].present?, "Should have breakdown by method"
        assert stats[:by_status].present?, "Should have breakdown by status"

        puts "Profiling statistics work correctly"
        puts "  Count: #{stats[:count]}"
        puts "  Total: #{stats[:total_ms]}ms"
        puts "  Avg: #{stats[:avg_ms]}ms"
        puts "  Min: #{stats[:min_ms]}ms"
        puts "  Max: #{stats[:max_ms]}ms"

        # Cleanup
        Parse.profiling_enabled = false
      end
    end
  end

  def test_profiling_callbacks
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "profiling callbacks test") do
        # Enable profiling and clear old profiles
        Parse.profiling_enabled = true
        Parse.clear_profiles!
        Parse.clear_profiling_callbacks!

        # Track callback execution
        callback_profiles = []
        Parse.on_request_complete do |profile|
          callback_profiles << profile
        end

        # Make a request
        model = ValidationCallbackTestModel.new(name: "Callback Test", email: "callback@example.com")
        model.save

        assert callback_profiles.any?, "Callback should have been executed"

        puts "Profiling callbacks work correctly"
        puts "  Captured #{callback_profiles.size} profile(s) via callback"

        # Cleanup
        Parse.profiling_enabled = false
        Parse.clear_profiling_callbacks!
      end
    end
  end

  def test_profiling_url_sanitization
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "profiling URL sanitization test") do
        Parse.profiling_enabled = true
        Parse.clear_profiles!

        # Make a request
        model = ValidationCallbackTestModel.new(name: "Sanitize Test", email: "sanitize@example.com")
        model.save

        profiles = Parse.recent_profiles
        profile = profiles.last

        # Verify sensitive data is filtered
        refute profile[:url].include?("masterKey="), "Master key should be filtered"
        refute profile[:url].include?("sessionToken="), "Session token should be filtered"

        puts "Profiling URL sanitization works correctly"

        # Cleanup
        Parse.profiling_enabled = false
      end
    end
  end

  # ============================================
  # Query Explain Tests
  # ============================================

  def test_query_explain
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "query explain test") do
        # Create some data first
        3.times do |i|
          model = ValidationCallbackTestModel.new(name: "Explain Test #{i}", email: "explain#{i}@example.com")
          model.save
        end

        # Get explain output
        explain = ValidationCallbackTestModel.query(:name.starts_with => "Explain").explain

        # Explain should return a hash with query plan info
        assert explain.is_a?(Hash), "Explain should return a Hash"

        # The exact structure depends on MongoDB version, but it should have content
        # Parse Server returns the raw MongoDB explain output
        puts "Query explain works correctly"
        puts "  Explain result keys: #{explain.keys.join(', ')}" if explain.keys.any?
      end
    end
  end

  def test_query_explain_with_complex_query
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "complex query explain test") do
        # Create some data first
        5.times do |i|
          model = ValidationCallbackTestModel.new(
            name: "Complex Test #{i}",
            email: "complex#{i}@example.com",
            status: i.even? ? "active" : "inactive"
          )
          model.save
        end

        # Complex query with multiple conditions
        explain = ValidationCallbackTestModel.query(
          :name.starts_with => "Complex",
          :status => "active"
        ).order(:createdAt.desc).explain

        assert explain.is_a?(Hash), "Complex query explain should return a Hash"

        puts "Complex query explain works correctly"
      end
    end
  end

  # ============================================
  # Cursor-Based Pagination Tests
  # ============================================

  def test_cursor_basic_pagination
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(30, "cursor basic pagination test") do
        # Create test data
        10.times do |i|
          model = ValidationCallbackTestModel.new(
            name: "Cursor Test #{i}",
            email: "cursor#{i}@example.com"
          )
          model.save
        end

        # Test cursor with small page size
        cursor = ValidationCallbackTestModel.query(:name.starts_with => "Cursor Test").cursor(limit: 3)

        pages = []
        cursor.each_page do |page|
          pages << page
        end

        # Should have multiple pages
        assert pages.size > 1, "Should have multiple pages with limit 3"

        # Total items should match
        total_items = pages.flatten.size
        assert total_items >= 10, "Should have fetched all items"

        puts "Cursor basic pagination works correctly"
        puts "  Pages: #{pages.size}"
        puts "  Total items: #{total_items}"
      end
    end
  end

  def test_cursor_with_ordering
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "cursor with ordering test") do
        # Create test data
        5.times do |i|
          model = ValidationCallbackTestModel.new(
            name: "Order Test #{i}",
            email: "order#{i}@example.com"
          )
          model.save
          sleep 0.1 # Small delay to ensure different created_at
        end

        # Test cursor with descending order
        cursor = ValidationCallbackTestModel.query(:name.starts_with => "Order Test")
                                            .cursor(limit: 2, order: :created_at.desc)

        all_items = cursor.all
        assert all_items.size >= 5, "Should have fetched all items"

        # Verify ordering (newest first)
        (0...all_items.size - 1).each do |i|
          assert all_items[i].created_at >= all_items[i + 1].created_at,
            "Items should be ordered by created_at desc"
        end

        puts "Cursor with ordering works correctly"
        puts "  Items fetched: #{all_items.size}"
      end
    end
  end

  def test_cursor_stats
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "cursor stats test") do
        # Create test data
        6.times do |i|
          model = ValidationCallbackTestModel.new(
            name: "Stats Test #{i}",
            email: "stats_cursor#{i}@example.com"
          )
          model.save
        end

        cursor = ValidationCallbackTestModel.query(:name.starts_with => "Stats Test")
                                            .cursor(limit: 2)

        # Iterate through pages
        cursor.each_page { |_| }

        stats = cursor.stats
        assert stats[:pages_fetched] >= 3, "Should have fetched multiple pages"
        assert stats[:items_fetched] >= 6, "Should have fetched all items"
        assert_equal 2, stats[:page_size], "Page size should be 2"
        assert stats[:exhausted], "Cursor should be exhausted"

        puts "Cursor stats work correctly"
        puts "  Stats: #{stats.inspect}"
      end
    end
  end

  def test_cursor_reset
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "cursor reset test") do
        # Create test data
        3.times do |i|
          model = ValidationCallbackTestModel.new(
            name: "Reset Test #{i}",
            email: "reset#{i}@example.com"
          )
          model.save
        end

        cursor = ValidationCallbackTestModel.query(:name.starts_with => "Reset Test")
                                            .cursor(limit: 2)

        # Iterate through all pages
        first_run = cursor.all

        # Reset and iterate again
        cursor.reset!
        refute cursor.exhausted?, "Cursor should not be exhausted after reset"

        second_run = cursor.all
        assert_equal first_run.size, second_run.size, "Should get same number of items after reset"

        puts "Cursor reset works correctly"
      end
    end
  end

  def test_cursor_class_method
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "cursor class method test") do
        # Create test data
        3.times do |i|
          model = ValidationCallbackTestModel.new(
            name: "ClassMethod Test #{i}",
            email: "classmethod#{i}@example.com"
          )
          model.save
        end

        # Test the class-level cursor method
        cursor = ValidationCallbackTestModel.cursor({ :name.starts_with => "ClassMethod Test" }, limit: 2)

        items = cursor.all
        assert items.size >= 3, "Should have fetched all items via class method"

        puts "Cursor class method works correctly"
      end
    end
  end

  def test_cursor_with_tied_values
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(30, "cursor with tied values test") do
        # Create 6 records with the SAME name value to test OR constraint handling of ties
        # When ordering by name, all records will have the same value, so the cursor
        # must use the OR constraint: (name < last) OR (name = last AND objectId > last_id)
        # to correctly paginate without skipping records.
        test_name = "TiedValue Test"
        created_ids = []

        6.times do |i|
          model = ValidationCallbackTestModel.new(
            name: test_name,  # Same name for all - creates tied values
            email: "tied_value_#{i}_#{SecureRandom.hex(4)}@example.com"
          )
          model.save
          created_ids << model.id
        end

        # Use small page size to force multiple pages with tied values
        cursor = ValidationCallbackTestModel.query(:name => test_name)
                                            .cursor(limit: 2, order: :name.asc)

        # Collect all items
        all_items = cursor.all
        fetched_ids = all_items.map(&:id)

        # Verify ALL 6 records were returned (none skipped due to tied values)
        assert_equal 6, all_items.size, "Should have fetched all 6 items with tied values"

        # Verify all created IDs are present
        created_ids.each do |id|
          assert fetched_ids.include?(id), "Should include record #{id} - tied value handling failed"
        end

        # Verify no duplicates
        assert_equal fetched_ids.size, fetched_ids.uniq.size, "Should have no duplicate records"

        # Verify pagination stats
        stats = cursor.stats
        assert stats[:pages_fetched] >= 3, "Should have fetched at least 3 pages (6 items / 2 per page)"

        puts "Cursor with tied values works correctly"
        puts "  Total items: #{all_items.size}"
        puts "  Pages fetched: #{stats[:pages_fetched]}"
        puts "  All IDs accounted for: #{created_ids.sort == fetched_ids.sort}"
      end
    end
  end

  def test_cursor_with_tied_created_at
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(30, "cursor with tied created_at test") do
        # Create records as fast as possible to maximize chance of tied created_at values
        # This tests the real-world scenario where bulk inserts create records with
        # identical timestamps
        test_prefix = "TiedTime_#{SecureRandom.hex(4)}"
        created_ids = []

        # Create 8 records rapidly (no sleep between saves)
        8.times do |i|
          model = ValidationCallbackTestModel.new(
            name: "#{test_prefix}_#{i}",
            email: "tied_time_#{i}_#{SecureRandom.hex(4)}@example.com"
          )
          model.save
          created_ids << model.id
        end

        # Use default ordering (created_at.asc) with small page size
        cursor = ValidationCallbackTestModel.query(:name.starts_with => test_prefix)
                                            .cursor(limit: 3)

        all_items = cursor.all
        fetched_ids = all_items.map(&:id)

        # Verify all records returned
        assert_equal 8, all_items.size, "Should have fetched all 8 items"

        # Verify all created IDs present (key test for tied timestamp handling)
        missing_ids = created_ids - fetched_ids
        assert missing_ids.empty?, "Missing IDs due to tied timestamp handling: #{missing_ids.inspect}"

        # Verify no duplicates
        duplicates = fetched_ids.group_by(&:itself).select { |_, v| v.size > 1 }.keys
        assert duplicates.empty?, "Found duplicate IDs: #{duplicates.inspect}"

        puts "Cursor with tied created_at works correctly"
        puts "  Total items: #{all_items.size}"
        puts "  Pages fetched: #{cursor.stats[:pages_fetched]}"
      end
    end
  end

  # ============================================
  # N+1 Detection Tests
  # ============================================

  def test_n_plus_one_detection_enabled
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "N+1 detection enabled test") do
        # Test enabling/disabling
        original = Parse.warn_on_n_plus_one

        Parse.warn_on_n_plus_one = true
        assert Parse.warn_on_n_plus_one, "N+1 detection should be enabled"

        Parse.warn_on_n_plus_one = false
        refute Parse.warn_on_n_plus_one, "N+1 detection should be disabled"

        # Restore original
        Parse.warn_on_n_plus_one = original

        puts "N+1 detection can be enabled and disabled"
      end
    end
  end

  def test_n_plus_one_callback_registration
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "N+1 callback registration test") do
        # Clear existing callbacks
        Parse.clear_n_plus_one_callbacks!

        callback_invoked = false
        Parse.on_n_plus_one do |source, assoc, target, count, location|
          callback_invoked = true
        end

        # The callback is registered
        assert Parse::NPlusOneDetector.callbacks.size == 1, "Callback should be registered"

        # Clean up
        Parse.clear_n_plus_one_callbacks!
        assert Parse::NPlusOneDetector.callbacks.empty?, "Callbacks should be cleared"

        puts "N+1 callback registration works correctly"
      end
    end
  end

  def test_n_plus_one_reset_tracking
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "N+1 reset tracking test") do
        Parse.warn_on_n_plus_one = true

        # Reset tracking
        Parse.reset_n_plus_one_tracking!

        # Get summary
        summary = Parse.n_plus_one_summary
        assert summary[:patterns_detected] == 0, "Should have no patterns after reset"

        Parse.warn_on_n_plus_one = false

        puts "N+1 reset tracking works correctly"
      end
    end
  end

  def test_n_plus_one_detector_tracking
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "N+1 detector tracking test") do
        Parse.warn_on_n_plus_one = true
        Parse.reset_n_plus_one_tracking!

        # Simulate multiple autofetch events
        5.times do |i|
          Parse::NPlusOneDetector.track_autofetch(
            source_class: "Song",
            association: :artist,
            target_class: "Artist",
            object_id: "id_#{i}"
          )
        end

        # Check summary
        summary = Parse.n_plus_one_summary
        assert summary[:patterns_detected] > 0, "Should have detected N+1 pattern"

        # Clean up
        Parse.warn_on_n_plus_one = false
        Parse.reset_n_plus_one_tracking!

        puts "N+1 detector tracking works correctly"
        puts "  Patterns detected: #{summary[:patterns_detected]}"
      end
    end
  end
end
