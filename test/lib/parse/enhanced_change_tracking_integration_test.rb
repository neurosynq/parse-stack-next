require_relative '../../test_helper_integration'

# Test model with enhanced change tracking for integration testing
# Enhanced tracking preserves _was and _was_changed? methods in after_save hooks,
# while _changed? methods maintain normal behavior (false after save)
class TrackedProduct < Parse::Object
  parse_class "TrackedProduct"
  
  property :name, :string
  property :price, :float
  property :sku, :string
  property :category, :string
  property :stock_quantity, :integer
  property :is_active, :boolean, default: true
  property :description, :string
  
  # Track changes and hook execution
  attr_accessor :before_save_changes, :after_save_changes,
                :before_save_was_values, :after_save_was_values,
                :before_save_was_changed_values, :after_save_was_changed_values,
                :previous_changes_snapshot, :hook_execution_log,
                :change_summary

  def initialize(*args)
    super
    @hook_execution_log = []
    @change_summary = []
  end

  # Hooks to test enhanced change tracking
  before_save :capture_before_save_state
  after_save :capture_after_save_state
  after_save :process_enhanced_changes

  def capture_before_save_state
    @hook_execution_log << "before_save executed"
    
    # Capture standard change tracking in before_save
    @before_save_changes = {
      name_changed: name_changed?,
      price_changed: price_changed?,
      sku_changed: sku_changed?,
      category_changed: category_changed?,
      stock_quantity_changed: stock_quantity_changed?,
      is_active_changed: is_active_changed?
    }
    
    # Capture _was values in before_save
    @before_save_was_values = {
      name_was: (name_changed? ? name_was : nil),
      price_was: (price_changed? ? price_was : nil),
      sku_was: (sku_changed? ? sku_was : nil),
      category_was: (category_changed? ? category_was : nil),
      stock_quantity_was: (stock_quantity_changed? ? stock_quantity_was : nil),
      is_active_was: (is_active_changed? ? is_active_was : nil)
    }
    
    # Capture _was_changed? methods in before_save
    @before_save_was_changed_values = {
      name_was_changed: (respond_to?(:name_was_changed?) ? name_was_changed? : false),
      price_was_changed: (respond_to?(:price_was_changed?) ? price_was_changed? : false),
      sku_was_changed: (respond_to?(:sku_was_changed?) ? sku_was_changed? : false),
      category_was_changed: (respond_to?(:category_was_changed?) ? category_was_changed? : false),
      stock_quantity_was_changed: (respond_to?(:stock_quantity_was_changed?) ? stock_quantity_was_changed? : false),
      is_active_was_changed: (respond_to?(:is_active_was_changed?) ? is_active_was_changed? : false)
    }
  end

  def capture_after_save_state
    @hook_execution_log << "after_save executed"
    
    # Test what's available in after_save (should be cleared in standard ActiveModel)
    @after_save_changes = {
      name_changed: name_changed?,
      price_changed: price_changed?,
      sku_changed: sku_changed?,
      category_changed: category_changed?,
      stock_quantity_changed: stock_quantity_changed?,
      is_active_changed: is_active_changed?
    }

    # Test if _was values are available in after_save (enhanced tracking should preserve these)
    @after_save_was_values = {
      name_was: (respond_to?(:name_was) ? name_was : "method_not_available"),
      price_was: (respond_to?(:price_was) ? price_was : "method_not_available"),
      sku_was: (respond_to?(:sku_was) ? sku_was : "method_not_available"),
      category_was: (respond_to?(:category_was) ? category_was : "method_not_available"),
      stock_quantity_was: (respond_to?(:stock_quantity_was) ? stock_quantity_was : "method_not_available"),
      is_active_was: (respond_to?(:is_active_was) ? is_active_was : "method_not_available")
    }
    
    # Test if _was_changed? methods are available in after_save (enhanced tracking should preserve these)
    @after_save_was_changed_values = {
      name_was_changed: (respond_to?(:name_was_changed?) ? name_was_changed? : false),
      price_was_changed: (respond_to?(:price_was_changed?) ? price_was_changed? : false),
      sku_was_changed: (respond_to?(:sku_was_changed?) ? sku_was_changed? : false),
      category_was_changed: (respond_to?(:category_was_changed?) ? category_was_changed? : false),
      stock_quantity_was_changed: (respond_to?(:stock_quantity_was_changed?) ? stock_quantity_was_changed? : false),
      is_active_was_changed: (respond_to?(:is_active_was_changed?) ? is_active_was_changed? : false)
    }

    # Test enhanced change tracking using previous_changes if available
    if respond_to?(:previous_changes) && previous_changes.present?
      @previous_changes_snapshot = previous_changes.dup
    end
  end

  def process_enhanced_changes
    @hook_execution_log << "enhanced_changes processed"
    
    # Use before_save captured data to generate change summary
    @change_summary = []
    
    if @before_save_changes[:name_changed] && @before_save_was_values[:name_was]
      @change_summary << "Name: '#{@before_save_was_values[:name_was]}' → '#{name}'"
    end
    
    if @before_save_changes[:price_changed] && @before_save_was_values[:price_was]
      @change_summary << "Price: $#{@before_save_was_values[:price_was]} → $#{price}"
    end
    
    if @before_save_changes[:sku_changed] && @before_save_was_values[:sku_was]
      @change_summary << "SKU: '#{@before_save_was_values[:sku_was]}' → '#{sku}'"
    end
    
    if @before_save_changes[:category_changed] && @before_save_was_values[:category_was]
      @change_summary << "Category: '#{@before_save_was_values[:category_was]}' → '#{category}'"
    end
    
    if @before_save_changes[:stock_quantity_changed] && @before_save_was_values[:stock_quantity_was]
      @change_summary << "Stock: #{@before_save_was_values[:stock_quantity_was]} → #{stock_quantity}"
    end
    
    if @before_save_changes[:is_active_changed] && !@before_save_was_values[:is_active_was].nil?
      @change_summary << "Active: #{@before_save_was_values[:is_active_was]} → #{is_active}"
    end

    # Test enhanced change tracking using previous_changes if available
    if @previous_changes_snapshot.present?
      @previous_changes_snapshot.each do |field, changes|
        old_value, new_value = changes
        @change_summary << "Enhanced #{field}: '#{old_value}' → '#{new_value}'"
      end
    end
  end
end

class EnhancedChangeTrackingIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_enhanced_change_tracking_on_create
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "enhanced change tracking on create test") do
        puts "\n=== Testing Enhanced Change Tracking on Create ==="

        # Create a new product
        product = TrackedProduct.new(
          name: "Test Product",
          price: 29.99,
          sku: "TST-0001",
          category: "Electronics",
          stock_quantity: 100,
          is_active: true,
          description: "A test product for change tracking"
        )

        # Save the product
        assert product.save, "Product should save successfully"
        assert product.id.present?, "Product should have an ID after save"

        # Verify hooks were called
        assert_includes product.hook_execution_log, "before_save executed", "before_save hook should execute"
        assert_includes product.hook_execution_log, "after_save executed", "after_save hook should execute"
        assert_includes product.hook_execution_log, "enhanced_changes processed", "enhanced changes should be processed"

        # On create, all fields with values should be marked as changed in before_save
        assert product.before_save_changes[:name_changed], "name should be changed on create"
        assert product.before_save_changes[:price_changed], "price should be changed on create"
        assert product.before_save_changes[:sku_changed], "sku should be changed on create"

        # In enhanced tracking, _changed? methods return to normal behavior (false after save)
        refute product.after_save_changes[:name_changed], "name_changed? should be false after save (normal behavior)"
        refute product.after_save_changes[:price_changed], "price_changed? should be false after save (normal behavior)"
        refute product.after_save_changes[:sku_changed], "sku_changed? should be false after save (normal behavior)"

        # _was values should be nil on create (in before_save)
        assert_nil product.before_save_was_values[:name_was], "name_was should be nil on create"
        assert_nil product.before_save_was_values[:price_was], "price_was should be nil on create"

        puts "✅ Enhanced change tracking works correctly on create"
      end
    end
  end

  def test_enhanced_change_tracking_on_update
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "enhanced change tracking on update test") do
        puts "\n=== Testing Enhanced Change Tracking on Update ==="

        # Create initial product
        product = TrackedProduct.new(
          name: "Original Product",
          price: 19.99,
          sku: "ORG-0001",
          category: "Books",
          stock_quantity: 50,
          is_active: true
        )
        assert product.save, "Initial product should save"
        
        # Clear tracking state
        product.hook_execution_log.clear
        product.change_summary.clear

        # Update the product
        product.name = "Updated Product Name"
        product.price = 24.99
        product.stock_quantity = 75

        assert product.save, "Updated product should save"

        # Verify hooks were called again
        assert_includes product.hook_execution_log, "before_save executed", "before_save hook should execute on update"
        assert_includes product.hook_execution_log, "after_save executed", "after_save hook should execute on update"

        # Verify only changed fields are tracked in before_save
        assert product.before_save_changes[:name_changed], "name should be changed"
        assert product.before_save_changes[:price_changed], "price should be changed"
        assert product.before_save_changes[:stock_quantity_changed], "stock_quantity should be changed"
        refute product.before_save_changes[:sku_changed], "sku should not be changed"
        refute product.before_save_changes[:category_changed], "category should not be changed"

        # Verify _was values capture original values
        assert_equal "Original Product", product.before_save_was_values[:name_was], "name_was should capture original value"
        assert_equal 19.99, product.before_save_was_values[:price_was], "price_was should capture original value"
        assert_equal 50, product.before_save_was_values[:stock_quantity_was], "stock_quantity_was should capture original value"
        assert_nil product.before_save_was_values[:sku_was], "sku_was should be nil since sku didn't change"

        # Verify change summary is generated correctly
        assert_includes product.change_summary, "Name: 'Original Product' → 'Updated Product Name'", "Change summary should include name change"
        assert_includes product.change_summary, "Price: $19.99 → $24.99", "Change summary should include price change"
        assert_includes product.change_summary, "Stock: 50 → 75", "Change summary should include stock change"

        puts "✅ Enhanced change tracking works correctly on update"
      end
    end
  end

  def test_enhanced_change_tracking_with_multiple_updates
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "enhanced change tracking with multiple updates test") do
        puts "\n=== Testing Enhanced Change Tracking with Multiple Updates ==="

        # Create initial product
        product = TrackedProduct.new(
          name: "Multi Update Product",
          price: 10.00,
          sku: "MUP-0001",
          category: "Electronics",
          stock_quantity: 25,
          is_active: true
        )
        assert product.save, "Initial product should save"

        # First update
        product.hook_execution_log.clear
        product.change_summary.clear
        product.price = 15.00
        product.stock_quantity = 30
        assert product.save, "First update should save"

        first_update_summary = product.change_summary.dup

        # Second update
        product.hook_execution_log.clear
        product.change_summary.clear
        product.name = "Multi Update Product v2"
        product.category = "Books"
        assert product.save, "Second update should save"

        second_update_summary = product.change_summary.dup

        # Third update (change field back to original)
        product.hook_execution_log.clear
        product.change_summary.clear
        product.price = 10.00  # Back to original
        assert product.save, "Third update should save"

        third_update_summary = product.change_summary.dup

        # Verify each update tracked changes correctly
        assert_includes first_update_summary, "Price: $10.0 → $15.0", "First update should track price change"
        assert_includes first_update_summary, "Stock: 25 → 30", "First update should track stock change"

        assert_includes second_update_summary, "Name: 'Multi Update Product' → 'Multi Update Product v2'", "Second update should track name change"
        assert_includes second_update_summary, "Category: 'Electronics' → 'Books'", "Second update should track category change"

        assert_includes third_update_summary, "Price: $15.0 → $10.0", "Third update should track price change back to original"

        puts "✅ Enhanced change tracking works correctly with multiple updates"
      end
    end
  end

  def test_enhanced_change_tracking_with_boolean_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "enhanced change tracking with boolean fields test") do
        puts "\n=== Testing Enhanced Change Tracking with Boolean Fields ==="

        # Create product with boolean field
        product = TrackedProduct.new(
          name: "Boolean Test Product",
          price: 5.99,
          sku: "BTP-0001",
          is_active: true
        )
        assert product.save, "Product with boolean should save"

        # Update boolean field
        product.hook_execution_log.clear
        product.change_summary.clear
        product.is_active = false
        assert product.save, "Boolean update should save"

        # Verify boolean change is tracked
        assert product.before_save_changes[:is_active_changed], "is_active should be marked as changed"
        assert_equal true, product.before_save_was_values[:is_active_was], "is_active_was should capture original true value"
        assert_includes product.change_summary, "Active: true → false", "Change summary should include boolean change"

        # Update boolean back to true
        product.hook_execution_log.clear
        product.change_summary.clear
        product.is_active = true
        assert product.save, "Boolean update back should save"

        assert_equal false, product.before_save_was_values[:is_active_was], "is_active_was should capture false value"
        assert_includes product.change_summary, "Active: false → true", "Change summary should include boolean change back"

        puts "✅ Enhanced change tracking works correctly with boolean fields"
      end
    end
  end

  def test_enhanced_change_tracking_with_nil_values
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "enhanced change tracking with nil values test") do
        puts "\n=== Testing Enhanced Change Tracking with Nil Values ==="

        # Create product with some nil fields
        product = TrackedProduct.new(
          name: "Nil Test Product",
          price: 12.99,
          sku: "NTP-0001"
          # category and stock_quantity intentionally nil
        )
        assert product.save, "Product with nil fields should save"

        # Update from nil to value
        product.hook_execution_log.clear
        product.change_summary.clear
        product.category = "Electronics"
        product.stock_quantity = 10
        assert product.save, "Update from nil should save"

        # Verify nil → value changes are tracked
        assert product.before_save_changes[:category_changed], "category should be marked as changed"
        assert product.before_save_changes[:stock_quantity_changed], "stock_quantity should be marked as changed"
        assert_nil product.before_save_was_values[:category_was], "category_was should be nil"
        assert_nil product.before_save_was_values[:stock_quantity_was], "stock_quantity_was should be nil"

        # Update from value to nil
        product.hook_execution_log.clear
        product.change_summary.clear
        product.category = nil
        assert product.save, "Update to nil should save"

        # Verify value → nil changes are tracked
        assert product.before_save_changes[:category_changed], "category should be marked as changed when set to nil"
        assert_equal "Electronics", product.before_save_was_values[:category_was], "category_was should capture previous value"

        puts "✅ Enhanced change tracking works correctly with nil values"
      end
    end
  end

  def test_enhanced_change_tracking_persistence_across_saves
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "enhanced change tracking persistence test") do
        puts "\n=== Testing Enhanced Change Tracking Persistence Across Saves ==="

        # Create and save product
        product = TrackedProduct.new(
          name: "Persistence Test Product",
          price: 8.99,
          sku: "PTP-0001"
        )
        assert product.save, "Initial save should succeed"
        original_id = product.id

        # Fetch the product fresh from server
        fetched_product = TrackedProduct.find(original_id)
        assert fetched_product, "Should be able to fetch product"
        
        # Update the fetched product
        fetched_product.hook_execution_log = []  # Initialize tracking
        fetched_product.change_summary = []
        fetched_product.price = 12.99
        fetched_product.name = "Updated Persistence Test"
        
        assert fetched_product.save, "Update of fetched product should save"

        # Verify change tracking works on fetched object
        assert_includes fetched_product.change_summary, "Price: $8.99 → $12.99", "Should track price change on fetched object"
        assert_includes fetched_product.change_summary, "Name: 'Persistence Test Product' → 'Updated Persistence Test'", "Should track name change on fetched object"

        puts "✅ Enhanced change tracking persists correctly across saves and fetches"
      end
    end
  end

  def test_after_save_hook_availability
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "after_save hook availability test") do
        puts "\n=== Testing What's Available in after_save Hook ==="

        # Create product
        product = TrackedProduct.new(
          name: "Hook Test Product",
          price: 7.50,
          sku: "HTP-0001"
        )
        assert product.save, "Product should save"

        # Update to trigger after_save
        product.hook_execution_log.clear
        product.name = "Updated Hook Test"
        product.price = 9.75
        assert product.save, "Update should save"

        # Verify what's available in after_save
        puts "\n--- after_save availability analysis ---"
        puts "Standard _changed? methods in after_save:"
        product.after_save_changes.each do |field, changed|
          puts "  #{field}: #{changed}"
        end

        puts "\n_was methods in after_save:"
        product.after_save_was_values.each do |field, value|
          puts "  #{field}: #{value}"
        end

        if product.previous_changes_snapshot
          puts "\nprevious_changes available:"
          product.previous_changes_snapshot.each do |field, changes|
            puts "  #{field}: #{changes[0]} → #{changes[1]}"
          end
        else
          puts "\nprevious_changes: not available"
        end

        # Enhanced tracking: _changed? methods have normal behavior (false after save)
        refute product.after_save_changes[:name_changed], "name_changed? should be false after save (normal behavior)"
        refute product.after_save_changes[:price_changed], "price_changed? should be false after save (normal behavior)"
        
        # But _was methods should still be available in after_save with enhanced tracking
        assert_equal "Hook Test Product", product.after_save_was_values[:name_was], "name_was should be available in after_save"
        assert_equal 7.50, product.after_save_was_values[:price_was], "price_was should be available in after_save"
        
        # And _was_changed? methods should be populated in after_save with enhanced tracking
        assert product.after_save_was_changed_values[:name_was_changed], "name_was_changed? should be true in after_save"
        assert product.after_save_was_changed_values[:price_was_changed], "price_was_changed? should be true in after_save"

        puts "✅ after_save hook availability tested"
      end
    end
  end

  def test_previous_changes_functionality
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "previous_changes functionality test") do
        puts "\n=== Testing previous_changes Functionality ==="

        # Create product
        product = TrackedProduct.new(
          name: "Previous Changes Test",
          price: 15.00,
          sku: "PCT-0001",
          category: "Electronics"
        )
        assert product.save, "Product should save"

        # Update multiple fields
        product.hook_execution_log.clear
        product.change_summary.clear
        product.name = "Updated Previous Changes Test"
        product.price = 20.00
        product.category = "Books"
        product.stock_quantity = 5  # From nil to 5

        assert product.save, "Update should save"

        # Verify previous_changes is available and accurate
        assert product.previous_changes_snapshot.present?, "previous_changes should be available in after_save"
        
        changes = product.previous_changes_snapshot
        assert_equal ["Previous Changes Test", "Updated Previous Changes Test"], changes["name"], "previous_changes should track name change"
        assert_equal [15.0, 20.0], changes["price"], "previous_changes should track price change"
        assert_equal ["Electronics", "Books"], changes["category"], "previous_changes should track category change"
        assert_equal [nil, 5], changes["stock_quantity"], "previous_changes should track nil to value change"

        # Verify enhanced change summary includes previous_changes data
        enhanced_changes = product.change_summary.select { |c| c.start_with?("Enhanced") }
        assert enhanced_changes.any? { |c| c.include?("name") }, "Enhanced change summary should include name change"
        assert enhanced_changes.any? { |c| c.include?("price") }, "Enhanced change summary should include price change"

        puts "✅ previous_changes functionality works correctly"
      end
    end
  end

  def test_enhanced_tracking_vs_standard_tracking_comparison
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "enhanced vs standard tracking comparison test") do
        puts "\n=== Testing Enhanced vs Standard Tracking Comparison ==="

        # Create product
        product = TrackedProduct.new(
          name: "Comparison Test Product",
          price: 25.00,
          sku: "CTP-0001"
        )
        assert product.save, "Product should save"

        # Update for comparison
        product.hook_execution_log.clear
        product.name = "Updated Comparison Test"
        product.price = 30.00

        assert product.save, "Update should save"

        puts "\n--- Comparison Results ---"
        puts "before_save tracking (standard ActiveModel):"
        puts "  name_changed?: #{product.before_save_changes[:name_changed]}"
        puts "  price_changed?: #{product.before_save_changes[:price_changed]}" 
        puts "  name_was: #{product.before_save_was_values[:name_was]}"
        puts "  price_was: #{product.before_save_was_values[:price_was]}"

        puts "\nafter_save tracking (Parse Stack enhanced):"
        puts "  name_changed?: #{product.after_save_changes[:name_changed]}"
        puts "  price_changed?: #{product.after_save_changes[:price_changed]}"
        puts "  name_was: #{product.after_save_was_values[:name_was]}"
        puts "  price_was: #{product.after_save_was_values[:price_was]}"

        if product.previous_changes_snapshot
          puts "\nprevious_changes (Parse Stack enhanced):"
          product.previous_changes_snapshot.each do |field, changes|
            puts "  #{field}: #{changes[0]} → #{changes[1]}"
          end
        end

        # Key assertion: _changed? methods have normal behavior (false after save)
        refute product.after_save_changes[:name_changed], "Enhanced: name_changed? should be false after save (normal behavior)"
        refute product.after_save_changes[:price_changed], "Enhanced: price_changed? should be false after save (normal behavior)"
        
        # Key assertion: _was methods still work in after_save with enhanced tracking
        assert_equal "Comparison Test Product", product.after_save_was_values[:name_was], "Enhanced: name_was should work in after_save"
        assert_equal 25.0, product.after_save_was_values[:price_was], "Enhanced: price_was should work in after_save"
        
        # Key assertion: _was_changed? methods work in after_save with enhanced tracking
        assert product.after_save_was_changed_values[:name_was_changed], "Enhanced: name_was_changed? should be true in after_save"
        assert product.after_save_was_changed_values[:price_was_changed], "Enhanced: price_was_changed? should be true in after_save"

        # Key assertion: previous_changes provides detailed change information
        assert product.previous_changes_snapshot["name"], "Enhanced: previous_changes should include name"
        assert product.previous_changes_snapshot["price"], "Enhanced: previous_changes should include price"

        puts "✅ Enhanced tracking preserves _was methods while maintaining normal _changed? behavior in after_save hooks"
      end
    end
  end
end