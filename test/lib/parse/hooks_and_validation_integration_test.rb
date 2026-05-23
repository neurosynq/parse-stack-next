require_relative "../../test_helper"
require_relative "../../test_helper_integration"
require "minitest/autorun"

# Test model with hooks, validations, and change tracking
class TestProduct < Parse::Object
  parse_class "HooksTestProduct"
  property :name, :string
  property :price, :float
  property :sku, :string
  property :category, :string
  property :stock_quantity, :integer
  property :is_active, :boolean, default: true
  property :description, :string
  property :created_by, :string
  property :updated_by, :string
  property :last_modified_at, :date

  # Track hook execution and changes
  attr_accessor :before_save_called, :after_save_called, :before_create_called,
                :after_create_called, :before_destroy_called, :after_destroy_called,
                :changes_in_before_save, :changes_in_after_save, :save_count

  # Validations
  validates_presence_of :name, :price, :sku
  validates_numericality_of :price, greater_than: 0
  validates_numericality_of :stock_quantity, greater_than_or_equal_to: 0, allow_nil: true
  validates_length_of :name, minimum: 3, maximum: 100
  validates_inclusion_of :category, in: ["Electronics", "Books", "Clothing", "Food"], allow_nil: true
  validate :custom_sku_format

  def custom_sku_format
    # Allow both upper and lowercase since normalize_data will uppercase it
    if sku.present? && !sku.match?(/^[A-Za-z]{3}-\d{4}$/)
      errors.add(:sku, "must be in format XXX-0000 (e.g., ABC-1234)")
    end
  end

  # Hooks - track changes before normalization
  before_save :track_before_save_changes
  before_save :normalize_data
  after_save :track_after_save_changes
  before_create :track_before_create
  after_create :track_after_create
  before_destroy :track_before_destroy
  after_destroy :track_after_destroy

  def track_before_save_changes
    self.before_save_called = true
    self.save_count = (self.save_count || 0) + 1

    # Track what's changed BEFORE any normalization
    self.changes_in_before_save = {
      name_changed: name_changed?,
      price_changed: price_changed?,
      sku_changed: sku_changed?,
      category_changed: category_changed?,
      stock_quantity_changed: stock_quantity_changed?,
      is_active_changed: is_active_changed?,
    }

    # Track previous values if changed
    if price_changed?
      self.changes_in_before_save[:price_was] = price_was
      self.changes_in_before_save[:price_new] = price
    end

    if name_changed?
      self.changes_in_before_save[:name_was] = name_was
      self.changes_in_before_save[:name_new] = name
    end

    # Set metadata
    self.created_by ||= "system"
    self.updated_by = "system"
  end

  def normalize_data
    self.name = name.strip.titleize if name.present? && name_changed?
    self.sku = sku.upcase if sku.present? && sku_changed?
    self.last_modified_at = Time.now.utc
  end

  def track_after_save_changes
    self.after_save_called = true

    # In after_save, enhanced change tracking shows what was changed in the save that just completed
    # Use _was_changed? methods since changes have been applied in after_save
    self.changes_in_after_save = {
      name_changed: name_was_changed?,
      price_changed: price_was_changed?,
      sku_changed: sku_was_changed?,
      category_changed: category_was_changed?,
      stock_quantity_changed: stock_quantity_was_changed?,
      is_active_changed: is_active_was_changed?,
    }
  end

  def track_before_create
    self.before_create_called = true
  end

  def track_after_create
    self.after_create_called = true
  end

  def track_before_destroy
    self.before_destroy_called = true
  end

  def track_after_destroy
    self.after_destroy_called = true
  end
end

# Test model with conditional hooks and change tracking
class TestOrder < Parse::Object
  property :order_number, :string
  property :status, :string
  property :total_amount, :float
  property :customer_email, :string
  property :items_count, :integer
  property :processed_at, :date
  property :shipped_at, :date
  property :notes, :string

  attr_accessor :status_change_logged, :email_sent, :inventory_updated,
                :status_changes_tracked, :total_changes_tracked

  # Conditional validations
  validates_presence_of :customer_email, if: :requires_email?
  validates_numericality_of :total_amount, greater_than: 0, if: :finalized?
  validate :shipping_date_validation, if: :shipped?

  # Conditional hooks with change tracking
  before_save :log_status_change, if: :status_changed?
  before_save :track_total_changes, if: :total_amount_changed?
  after_save :send_confirmation_email, if: :should_send_email?
  after_save :update_inventory

  def requires_email?
    status != "draft"
  end

  def finalized?
    ["pending", "processing", "completed", "shipped"].include?(status)
  end

  def shipped?
    status == "shipped"
  end

  def shipping_date_validation
    if shipped_at.present? && processed_at.present? && shipped_at < processed_at
      errors.add(:shipped_at, "cannot be before processed date")
    end
  end

  def should_send_email?
    # Use previous_changes in after_save context
    if previous_changes && previous_changes[:status]
      old_status, new_status = previous_changes[:status]
      ["completed", "shipped"].include?(new_status)
    else
      # Fallback for before_save context
      status_changed? && ["completed", "shipped"].include?(status)
    end
  end

  def log_status_change
    # Only track changes if there was a previous status
    if status_was.present?
      self.status_change_logged = true
      self.status_changes_tracked = {
        from: status_was,
        to: status,
        changed: status_changed?,
      }
      self.notes = "Status changed from #{status_was} to #{status} at #{Time.now.utc}"
    end
  end

  def track_total_changes
    self.total_changes_tracked = {
      was: total_amount_was,
      now: total_amount,
      difference: total_amount - (total_amount_was || 0),
    }
  end

  def send_confirmation_email
    self.email_sent = true
  end

  def update_inventory
    # Check if status changed to completed using previous_changes
    if previous_changes && previous_changes[:status]
      old_status, new_status = previous_changes[:status]
      if new_status == "completed" && old_status != "completed"
        self.inventory_updated = true
      end
    end
  end
end

# Test model with hook failures and halting
class TestAccount < Parse::Object
  property :username, :string
  property :email, :string
  property :balance, :float
  property :is_verified, :boolean
  property :verification_token, :string
  property :should_halt_save, :boolean

  attr_accessor :hook_execution_order, :balance_changes

  validates_presence_of :username, :email
  validates_format_of :email, with: /\A[^@\s]+@[^@\s]+\z/

  before_save :track_execution_order_1
  before_save :check_halt_condition
  before_save :track_balance_changes
  after_save :track_execution_order_2

  def initialize(attrs = {})
    super
    self.hook_execution_order = []
  end

  def check_halt_condition
    puts "DEBUG: should_halt_save = #{should_halt_save.inspect}"
    if should_halt_save
      puts "DEBUG: Adding error and returning false to halt save"
      errors.add(:base, "Save halted by before_save hook")
      return false  # Return false to halt the save in ActiveModel hooks
    end
    puts "DEBUG: Not halting save"
  end

  def track_execution_order_1
    puts "DEBUG: Executing track_execution_order_1"
    self.hook_execution_order << "before_save_1"
  end

  def track_balance_changes
    if balance_changed?
      self.balance_changes = {
        was: balance_was,
        now: balance,
        difference: balance - (balance_was || 0),
      }
    end
  end

  def track_execution_order_2
    self.hook_execution_order << "after_save"
  end
end

# Test model for before_save hook chaining and modification
class TestCounter < Parse::Object
  property :counter_value, :integer, default: 0
  property :name, :string

  attr_accessor :hook_execution_log

  before_save :add_one_to_counter
  before_save :add_ten_to_counter
  before_save :log_hook_execution

  def initialize(attrs = {})
    super
    self.hook_execution_log = []
  end

  def add_one_to_counter
    self.counter_value = (counter_value || 0) + 1
    self.hook_execution_log << "add_one_to_counter: #{counter_value}"
  end

  def add_ten_to_counter
    self.counter_value = (counter_value || 0) + 10
    self.hook_execution_log << "add_ten_to_counter: #{counter_value}"
  end

  def log_hook_execution
    self.hook_execution_log << "log_hook_execution: final_value=#{counter_value}"
  end
end

class HooksAndValidationIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Helper method to add timeout with custom message
  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_before_save_hook_with_change_tracking
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "before_save with change tracking test") do
        product = TestProduct.new({
          name: "  test product  ",
          price: 29.99,
          sku: "abc-1234",
          stock_quantity: 10,
          category: "Electronics",
        })

        # Before save, hooks should not be called
        assert_nil product.before_save_called, "before_save should not be called yet"
        assert_nil product.changes_in_before_save, "changes should not be tracked yet"

        # Save the product
        assert product.save, "Product should save successfully"

        # Check that before_save tracked changes correctly
        assert product.before_save_called, "before_save hook should have been called"
        assert product.changes_in_before_save[:name_changed], "name should be marked as changed"
        assert product.changes_in_before_save[:price_changed], "price should be marked as changed"
        assert product.changes_in_before_save[:sku_changed], "sku should be marked as changed"

        # Check data normalization from before_save (only happens when changed)
        assert_equal "Test Product", product.name, "Name should be normalized"
        assert_equal "ABC-1234", product.sku, "SKU should be uppercased"

        puts "✓ Before save hook with change tracking working correctly"
        puts "  - Changes tracked: #{product.changes_in_before_save.select { |k, v| v == true }.keys.join(", ")}"
        puts "  - Name normalized: '#{product.name}'"
        puts "  - SKU uppercased: '#{product.sku}'"

        # Now update the product
        product.price = 39.99
        product.stock_quantity = 5

        assert product.save, "Product update should save successfully"

        # Check that only changed fields are marked as changed
        assert !product.changes_in_before_save[:name_changed], "name should not be changed on update"
        assert product.changes_in_before_save[:price_changed], "price should be changed on update"
        assert product.changes_in_before_save[:stock_quantity_changed], "stock_quantity should be changed on update"
        assert_equal 29.99, product.changes_in_before_save[:price_was], "Should track previous price"
        assert_equal 39.99, product.changes_in_before_save[:price_new], "Should track new price"

        puts "  - Update changes tracked: price (#{product.changes_in_before_save[:price_was]} -> #{product.changes_in_before_save[:price_new]})"
      end
    end
  end

  def test_after_save_hook_change_state
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "after_save change state test") do
        product = TestProduct.new({
          name: "Test Product",
          price: 49.99,
          sku: "xyz-5678",
          stock_quantity: 5,
        })

        # Save the product
        assert product.save, "Product should save successfully"

        # In after_save, enhanced change tracking shows what was changed in the completed save
        assert product.after_save_called, "after_save hook should have been called"
        assert product.changes_in_after_save[:name_changed], "name_was_changed should be true in after_save (was changed in create)"
        assert product.changes_in_after_save[:price_changed], "price_was_changed should be true in after_save (was changed in create)"
        assert product.changes_in_after_save[:sku_changed], "sku_was_changed should be true in after_save (was changed in create)"

        puts "✓ After save hook change state correct"
        puts "  - Enhanced _was_changed? methods show what was changed in the completed save"
      end
    end
  end

  def test_conditional_hooks_with_change_tracking
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "conditional hooks with change tracking test") do
        order = TestOrder.new({
          order_number: "ORD-001",
          status: "draft",
          customer_email: "test@example.com",
          total_amount: 100.00,
        })

        # Save as draft
        assert order.save, "Order should save as draft"
        assert_nil order.status_changes_tracked, "Status change should not be tracked for new record"

        # Change to pending - status_changed? should be true
        order.status = "pending"
        order.total_amount = 150.00
        assert order.save, "Order should save as pending"

        assert order.status_change_logged, "Status change should be logged"
        assert_equal "draft", order.status_changes_tracked[:from], "Should track previous status"
        assert_equal "pending", order.status_changes_tracked[:to], "Should track new status"
        assert order.status_changes_tracked[:changed], "Should confirm status changed"

        assert order.total_changes_tracked, "Total amount change should be tracked"
        assert_equal 100.00, order.total_changes_tracked[:was], "Should track previous total"
        assert_equal 150.00, order.total_changes_tracked[:now], "Should track new total"
        assert_equal 50.00, order.total_changes_tracked[:difference], "Should track difference"

        # Change to completed - should trigger inventory update
        order.inventory_updated = nil
        order.email_sent = nil
        order.status = "completed"
        assert order.save, "Order should save as completed"

        assert order.inventory_updated, "Inventory should be updated when status changes to completed"
        assert order.email_sent, "Email should be sent for completed status"

        puts "✓ Conditional hooks with change tracking working correctly"
        puts "  - Status change tracked: #{order.status_changes_tracked[:from]} -> #{order.status_changes_tracked[:to]}"
        puts "  - Total change tracked: $#{order.total_changes_tracked[:was]} -> $#{order.total_changes_tracked[:now]}"
        puts "  - Conditional hooks fired based on _changed? methods"
      end
    end
  end

  def test_changed_was_methods_in_hooks
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "changed and was methods test") do
        account = TestAccount.new({
          username: "testuser",
          email: "test@example.com",
          balance: 100.00,
        })

        assert account.save, "Account should save successfully"

        # Update balance
        account.balance = 250.00
        assert account.save, "Account should update successfully"

        assert account.balance_changes, "Balance changes should be tracked"
        assert_equal 100.00, account.balance_changes[:was], "Should track previous balance"
        assert_equal 250.00, account.balance_changes[:now], "Should track new balance"
        assert_equal 150.00, account.balance_changes[:difference], "Should calculate difference"

        # Update without changing balance
        account.balance_changes = nil
        account.username = "newusername"
        assert account.save, "Account should update successfully"

        assert_nil account.balance_changes, "Balance changes should not be tracked when balance doesn't change"

        puts "✓ Changed and was methods working correctly"
        puts "  - balance_was: 100.00"
        puts "  - balance_changed?: true (when changed)"
        puts "  - Difference calculated: 150.00"
        puts "  - No tracking when field not changed"
      end
    end
  end

  def test_create_hooks
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "create hooks test") do
        product = TestProduct.new({
          name: "New Product",
          price: 99.99,
          sku: "new-0001",
        })

        # First save (create)
        assert product.save, "Product should save successfully"

        assert product.before_create_called, "before_create should be called on first save"
        assert product.after_create_called, "after_create should be called on first save"
        assert product.before_save_called, "before_save should be called"
        assert product.after_save_called, "after_save should be called"
        assert_equal 1, product.save_count, "Save count should be 1"

        # Reset hook tracking
        product.before_create_called = nil
        product.after_create_called = nil
        product.before_save_called = nil
        product.after_save_called = nil

        # Update the product
        product.price = 89.99
        assert product.save, "Product should update successfully"

        assert_nil product.before_create_called, "before_create should not be called on update"
        assert_nil product.after_create_called, "after_create should not be called on update"
        assert product.before_save_called, "before_save should be called on update"
        assert product.after_save_called, "after_save should be called on update"
        assert_equal 2, product.save_count, "Save count should be 2"

        puts "✓ Create hooks working correctly"
        puts "  - Create hooks called only on first save"
        puts "  - Save hooks called on both create and update"
        puts "  - Save count: #{product.save_count}"
      end
    end
  end

  def test_validation_presence
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "validation presence test") do
        # Test missing required fields
        product = TestProduct.new({
          price: 29.99,
        })

        assert !product.valid?, "Product should not be valid without required fields"
        assert product.errors[:name].present?, "Should have error for missing name"
        assert product.errors[:sku].present?, "Should have error for missing sku"

        # Test with all required fields
        product.name = "Valid Product"
        product.sku = "VAL-1234"

        assert product.valid?, "Product should be valid with all required fields"
        assert product.save, "Valid product should save successfully"

        puts "✓ Presence validations working correctly"
        puts "  - Missing fields detected"
        puts "  - Valid with all required fields"
      end
    end
  end

  def test_validation_numericality
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "validation numericality test") do
        # Test invalid price
        product = TestProduct.new({
          name: "Test Product",
          sku: "TST-0001",
          price: -10.00,
        })

        assert !product.valid?, "Product should not be valid with negative price"
        assert product.errors[:price].present?, "Should have error for negative price"

        # Test valid price
        product.price = 19.99
        assert product.valid?, "Product should be valid with positive price"

        # Test stock quantity validation
        product.stock_quantity = -5
        assert !product.valid?, "Product should not be valid with negative stock"
        assert product.errors[:stock_quantity].present?, "Should have error for negative stock"

        product.stock_quantity = 0
        assert product.valid?, "Product should be valid with zero stock"

        puts "✓ Numericality validations working correctly"
        puts "  - Negative values rejected"
        puts "  - Valid ranges accepted"
      end
    end
  end

  def test_validation_length_and_format
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "validation length and format test") do
        # Test name length validation
        product = TestProduct.new({
          name: "AB",  # Too short
          price: 29.99,
          sku: "ABC-1234",
        })

        assert !product.valid?, "Product should not be valid with short name"
        assert product.errors[:name].present?, "Should have error for short name"

        # Test custom SKU format validation
        product.name = "Valid Name"
        product.sku = "invalid-sku"

        assert !product.valid?, "Product should not be valid with invalid SKU format"
        assert product.errors[:sku].present?, "Should have error for invalid SKU format"

        # Test valid SKU format
        product.sku = "ABC-1234"
        assert product.valid?, "Product should be valid with correct SKU format"

        puts "✓ Length and format validations working correctly"
        puts "  - Length constraints enforced"
        puts "  - Custom format validation working"
      end
    end
  end

  def test_hook_halting_save
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "hook halting save test") do
        account = TestAccount.new({
          username: "haltuser",
          email: "halt@example.com",
          balance: 50.00,
          should_halt_save: true,
        })

        # Save should fail due to halt condition
        assert !account.save, "Save should be halted by before_save hook"
        assert account.errors[:base].present?, "Should have base error from halt"
        assert account.errors[:base].first.include?("halted"),
               "Error message should indicate save was halted"

        # Only first before_save hook should have executed
        assert_equal ["before_save_1"], account.hook_execution_order,
                     "Only first hook should execute before halt"

        # Remove halt condition and try again
        account.should_halt_save = false
        account.errors.clear
        account.hook_execution_order = []

        assert account.save, "Save should succeed without halt condition"
        assert_equal ["before_save_1", "after_save"],
                     account.hook_execution_order,
                     "All hooks should execute without halt"

        puts "✓ Hook halting working correctly"
        puts "  - Save halted when condition met"
        puts "  - Subsequent hooks not executed after halt"
        puts "  - Save succeeds when halt condition removed"
      end
    end
  end

  def test_destroy_hooks
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "destroy hooks test") do
        product = TestProduct.new({
          name: "Product to Delete",
          price: 19.99,
          sku: "DEL-0001",
        })

        assert product.save, "Product should save successfully"

        # Destroy the product
        assert product.destroy, "Product should be destroyed successfully"

        assert product.before_destroy_called, "before_destroy hook should be called"
        assert product.after_destroy_called, "after_destroy hook should be called"

        # Verify product is deleted
        found_products = TestProduct.query.where(:sku => "DEL-0001").results
        assert_equal 0, found_products.length, "Product should be deleted from database"

        puts "✓ Destroy hooks working correctly"
        puts "  - Before destroy called: #{product.before_destroy_called}"
        puts "  - After destroy called: #{product.after_destroy_called}"
        puts "  - Product deleted from database"
      end
    end
  end

  def test_previous_changes_in_after_save
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "previous_changes in after_save test") do
        order = TestOrder.new({
          order_number: "ORD-999",
          status: "draft",
          customer_email: "test@example.com",
          total_amount: 200.00,
        })

        assert order.save, "Order should save successfully"

        # Make changes to trigger after_save
        order.status = "completed"
        order.total_amount = 250.00

        assert order.save, "Order should update successfully"

        # The update_inventory method should have been called via previous_changes
        assert order.inventory_updated, "Inventory should be updated using previous_changes"

        puts "✓ previous_changes successfully used in after_save hooks"
        puts "  - Status changed from draft to completed"
        puts "  - Inventory updated using previous_changes detection"
        puts "  - Solution: Use previous_changes hash in after_save for change detection"
      end
    end
  end

  def test_before_save_hooks_modify_object_in_chain
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "before_save hooks modify object in chain test") do
        # Create a TestCounter with initial counter_value of 0
        counter = TestCounter.new({
          name: "Test Counter",
          counter_value: 0,
        })

        puts "Initial counter_value: #{counter.counter_value}"

        # Save the object - this should trigger the before_save hooks in order:
        # 1. add_one_to_counter: 0 + 1 = 1
        # 2. add_ten_to_counter: 1 + 10 = 11
        # 3. log_hook_execution: logs final value
        assert counter.save, "Counter should save successfully"

        # Verify the final counter_value is 11 (1 + 10)
        assert_equal 11, counter.counter_value, "Counter value should be 11 after both before_save hooks execute"

        # Verify the hook execution log shows the correct sequence
        expected_log = [
          "add_one_to_counter: 1",
          "add_ten_to_counter: 11",
          "log_hook_execution: final_value=11",
        ]
        assert_equal expected_log, counter.hook_execution_log, "Hook execution log should show correct sequence"

        puts "✓ Before save hooks modify object in chain correctly"
        puts "  - First hook: 0 + 1 = 1"
        puts "  - Second hook: 1 + 10 = 11"
        puts "  - Final saved value: #{counter.counter_value}"
        puts "  - Hook execution log: #{counter.hook_execution_log}"

        # Test that updating the object also applies the hooks
        counter.name = "Updated Counter"
        counter.counter_value = 5  # Reset to 5

        assert counter.save, "Counter should save successfully on update"

        # Should be 5 + 1 + 10 = 16
        assert_equal 16, counter.counter_value, "Counter value should be 16 after update with hooks"

        puts "✓ Before save hooks also work on updates"
        puts "  - Updated from 5: 5 + 1 + 10 = #{counter.counter_value}"
      end
    end
  end
end
