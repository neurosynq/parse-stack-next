require_relative "../../test_helper_integration"
require "minitest/autorun"

# Test model to explore after_save change tracking
class TestItem < Parse::Object
  property :name, :string
  property :status, :string
  property :price, :float
  property :quantity, :integer

  # Instance variables to track changes
  attr_accessor :changes_captured_in_before_save, :changes_available_in_after_save,
                :was_values_in_before_save, :was_values_in_after_save,
                :previous_attributes, :change_summary

  before_save :capture_changes_before_save
  after_save :check_changes_after_save
  after_save :process_changes_using_cached_data

  def capture_changes_before_save
    # Capture current change state in before_save
    self.changes_captured_in_before_save = {
      name_changed: name_changed?,
      status_changed: status_changed?,
      price_changed: price_changed?,
      quantity_changed: quantity_changed?,
    }

    # Capture _was values
    self.was_values_in_before_save = {}
    if name_changed?
      self.was_values_in_before_save[:name] = name_was
    end
    if status_changed?
      self.was_values_in_before_save[:status] = status_was
    end
    if price_changed?
      self.was_values_in_before_save[:price] = price_was
    end
    if quantity_changed?
      self.was_values_in_before_save[:quantity] = quantity_was
    end

    # Store a snapshot of changes for after_save use
    self.previous_attributes = {
      name: name_was,
      status: status_was,
      price: price_was,
      quantity: quantity_was,
    }
  end

  def check_changes_after_save
    # Check what's available in after_save
    self.changes_available_in_after_save = {
      name_changed: name_changed?,
      status_changed: status_changed?,
      price_changed: price_changed?,
      quantity_changed: quantity_changed?,
    }

    # Try to get _was values in after_save
    self.was_values_in_after_save = {
      name_was: respond_to?(:name_was) ? name_was : nil,
      status_was: respond_to?(:status_was) ? status_was : nil,
      price_was: respond_to?(:price_was) ? price_was : nil,
      quantity_was: respond_to?(:quantity_was) ? quantity_was : nil,
    }
  end

  def process_changes_using_cached_data
    # Use the cached data from before_save to process changes
    if previous_attributes && was_values_in_before_save
      self.change_summary = []

      if was_values_in_before_save[:name]
        self.change_summary << "Name changed from '#{was_values_in_before_save[:name]}' to '#{name}'"
      end

      if was_values_in_before_save[:status]
        self.change_summary << "Status changed from '#{was_values_in_before_save[:status]}' to '#{status}'"
      end

      if was_values_in_before_save[:price]
        self.change_summary << "Price changed from $#{was_values_in_before_save[:price]} to $#{price}"
      end

      if was_values_in_before_save[:quantity]
        self.change_summary << "Quantity changed from #{was_values_in_before_save[:quantity]} to #{quantity}"
      end
    end
  end
end

# Alternative approach using ActiveModel's previous_changes
class TestItemWithPreviousChanges < Parse::Object
  property :name, :string
  property :status, :string
  property :price, :float

  attr_accessor :previous_changes_in_after_save, :mutations_info, :original_data

  before_save :store_original_data
  after_save :capture_previous_changes

  def store_original_data
    # Store original data before save
    if persisted?
      self.original_data = {
        name: name_was,
        status: status_was,
        price: price_was,
      }
    end
  end

  def capture_previous_changes
    # Check if we have access to previous_changes method
    if respond_to?(:previous_changes)
      self.previous_changes_in_after_save = previous_changes
    end

    # Check if we can access mutations
    if respond_to?(:mutations_from_database)
      self.mutations_info = {
        mutations_from_database: mutations_from_database,
        mutations_before_last_save: @mutations_before_last_save,
      }
    end

    # Alternative: manually track using stored original data
    if original_data
      changes = {}
      changes[:name] = [original_data[:name], name] if original_data[:name] != name
      changes[:status] = [original_data[:status], status] if original_data[:status] != status
      changes[:price] = [original_data[:price], price] if original_data[:price] != price
      self.previous_changes_in_after_save ||= changes
    end
  end
end

class AfterSaveChangesTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_change_tracking_in_after_save
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "after_save change tracking test") do
        # Create new item
        item = TestItem.new({
          name: "Original Item",
          status: "pending",
          price: 100.00,
          quantity: 5,
        })

        assert item.save, "Item should save successfully"

        puts "\n=== First Save (Create) ==="
        puts "Changes captured in before_save: #{item.changes_captured_in_before_save}"
        puts "Changes available in after_save: #{item.changes_available_in_after_save}"
        puts "Was values in before_save: #{item.was_values_in_before_save}"
        puts "Was values in after_save: #{item.was_values_in_after_save}"

        # Update the item
        item.name = "Updated Item"
        item.status = "active"
        item.price = 150.00

        assert item.save, "Item should update successfully"

        puts "\n=== Second Save (Update) ==="
        puts "Changes captured in before_save: #{item.changes_captured_in_before_save}"
        puts "Changes available in after_save: #{item.changes_available_in_after_save}"
        puts "Was values in before_save: #{item.was_values_in_before_save}"
        puts "Was values in after_save: #{item.was_values_in_after_save}"
        puts "Change summary: #{item.change_summary}"

        # Verify that we captured the changes
        assert item.was_values_in_before_save[:name] == "Original Item", "Should capture previous name"
        assert item.was_values_in_before_save[:status] == "pending", "Should capture previous status"
        assert item.was_values_in_before_save[:price] == 100.00, "Should capture previous price"

        # Check if changes are cleared in after_save
        assert !item.changes_available_in_after_save[:name_changed], "name_changed should be false in after_save"
        assert !item.changes_available_in_after_save[:status_changed], "status_changed should be false in after_save"

        # Verify change summary was built correctly
        assert item.change_summary.include?("Name changed from 'Original Item' to 'Updated Item'")
        assert item.change_summary.include?("Status changed from 'pending' to 'active'")
        assert item.change_summary.include?("Price changed from $100.0 to $150.0")
      end
    end
  end

  def test_previous_changes_method
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "previous_changes method test") do
        item = TestItemWithPreviousChanges.new({
          name: "Test Item",
          status: "draft",
          price: 50.00,
        })

        assert item.save, "Item should save successfully"

        puts "\n=== Testing previous_changes access ==="
        puts "Previous changes in after_save: #{item.previous_changes_in_after_save}"
        puts "Mutations info: #{item.mutations_info}"

        # Update the item
        item.name = "Modified Item"
        item.status = "published"
        item.price = 75.00

        assert item.save, "Item should update successfully"

        puts "\n=== After Update ==="
        puts "Previous changes: #{item.previous_changes_in_after_save}"
        puts "Original data tracked: #{item.original_data}"

        # Check if we have previous changes
        if item.previous_changes_in_after_save && !item.previous_changes_in_after_save.empty?
          assert item.previous_changes_in_after_save[:name], "Should have name in previous changes"
          assert_equal ["Test Item", "Modified Item"], item.previous_changes_in_after_save[:name],
                       "Should track name change correctly"
        else
          puts "Note: previous_changes not directly available, using manual tracking"
        end
      end
    end
  end

  def test_using_instance_variables_for_change_tracking
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "instance variable change tracking test") do
        # This demonstrates the recommended approach:
        # Store change information in before_save for use in after_save

        item = TestItem.new({
          name: "Product A",
          status: "available",
          price: 25.00,
          quantity: 10,
        })

        assert item.save, "Item should save successfully"

        # Make some changes
        item.status = "out_of_stock"
        item.quantity = 0

        assert item.save, "Item should update successfully"

        # Verify we can use the cached change data in after_save
        assert item.change_summary, "Should have change summary"
        assert item.change_summary.include?("Status changed from 'available' to 'out_of_stock'")
        assert item.change_summary.include?("Quantity changed from 10 to 0")

        puts "\n=== Successful Change Tracking in after_save ==="
        puts "Change summary generated in after_save:"
        item.change_summary.each { |change| puts "  - #{change}" }

        puts "\n✓ Solution: Cache _was values in before_save for use in after_save"
      end
    end
  end
end
