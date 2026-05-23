require_relative '../../test_helper_integration'

# Test models for transaction integration testing
class Product < Parse::Object
  parse_class "Product"
  
  property :name, :string, required: true
  property :price, :float
  property :sku, :string
  property :stock_quantity, :integer, default: 0
  property :category, :string
  property :is_active, :boolean, default: true
end

class Order < Parse::Object
  parse_class "Order"
  
  property :order_number, :string
  property :customer_name, :string
  property :total_amount, :float
  property :status, :string, default: "pending"
  property :items, :array
end

class Inventory < Parse::Object
  parse_class "Inventory"
  
  belongs_to :product
  property :location, :string
  property :quantity, :integer
  property :reserved_quantity, :integer, default: 0
end

class TransactionIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_basic_transaction_success
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "basic transaction success test") do
        puts "\n=== Testing Basic Transaction Success ==="

        # Create initial products
        product1 = Product.new(name: "Product 1", price: 10.00, sku: "PRD-001", stock_quantity: 100)
        product2 = Product.new(name: "Product 2", price: 20.00, sku: "PRD-002", stock_quantity: 50)
        
        assert product1.save, "Product 1 should save initially"
        assert product2.save, "Product 2 should save initially"

        # Execute transaction to update both products
        responses = Parse::Object.transaction do |batch|
          product1.price = 12.00
          product1.stock_quantity = 95
          batch.add(product1)

          product2.price = 22.00
          product2.stock_quantity = 45
          batch.add(product2)
        end

        # Verify transaction succeeded
        assert responses.is_a?(Array), "Transaction should return array of responses"
        assert responses.all?(&:success?), "All operations should succeed"
        assert_equal 2, responses.size, "Should have 2 responses"

        # Verify changes were persisted
        product1.fetch!
        product2.fetch!
        
        assert_equal 12.00, product1.price, "Product 1 price should be updated"
        assert_equal 95, product1.stock_quantity, "Product 1 stock should be updated"
        assert_equal 22.00, product2.price, "Product 2 price should be updated"
        assert_equal 45, product2.stock_quantity, "Product 2 stock should be updated"

        puts "✅ Basic transaction succeeded and changes persisted"
      end
    end
  end

  def test_transaction_with_return_value_auto_batch
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "transaction auto-batch test") do
        puts "\n=== Testing Transaction with Return Value Auto-Batch ==="

        # Create initial products
        product1 = Product.new(name: "Auto Product 1", price: 15.00, sku: "AUTO-001")
        product2 = Product.new(name: "Auto Product 2", price: 25.00, sku: "AUTO-002")
        
        assert product1.save, "Auto Product 1 should save initially"
        assert product2.save, "Auto Product 2 should save initially"

        # Execute transaction using return value approach
        responses = Parse::Object.transaction do
          product1.price = 18.00
          product2.price = 28.00
          
          # Return array of objects to be saved
          [product1, product2]
        end

        # Verify transaction succeeded
        assert responses.all?(&:success?), "All auto-batch operations should succeed"
        assert_equal 2, responses.size, "Should have 2 responses from auto-batch"

        # Verify changes were persisted
        product1.fetch!
        product2.fetch!
        
        assert_equal 18.00, product1.price, "Auto Product 1 price should be updated"
        assert_equal 28.00, product2.price, "Auto Product 2 price should be updated"

        puts "✅ Transaction with auto-batch succeeded"
      end
    end
  end

  def test_transaction_rollback_on_failure
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "transaction rollback test") do
        puts "\n=== Testing Transaction Rollback on Failure ==="

        # Create a valid product
        product = Product.new(name: "Rollback Test Product", price: 30.00, sku: "RBT-001")
        assert product.save, "Product should save initially"
        
        original_price = product.price

        # Attempt transaction that should fail
        error_occurred = false
        begin
          Parse::Object.transaction do |batch|
            # Add the product to the batch FIRST to capture its current state
            batch.add(product)
            
            # Then modify it - this should be rolled back if transaction fails
            product.price = 35.00

            # Create an object that will cause a failure by trying to save with invalid objectId
            invalid_product = Product.new(name: "Invalid Product", price: 40.00, sku: "INVALID")
            # Set an invalid objectId to force a server error
            invalid_product.instance_variable_set(:@id, "INVALID_ID_THAT_WILL_FAIL")
            batch.add(invalid_product)
          end
        rescue Parse::Error => e
          error_occurred = true
          puts "Expected error occurred: #{e.message}"
        end

        # Verify error occurred and rollback happened
        assert error_occurred, "Transaction should have failed"

        # Verify original product was not modified (rollback)
        product.fetch!
        assert_equal original_price, product.price, "Product price should be rolled back to original value"

        puts "✅ Transaction rollback worked correctly"
      end
    end
  end

  def test_complex_business_transaction
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "complex business transaction test") do
        puts "\n=== Testing Complex Business Transaction ==="

        # Setup: Create products and inventory
        product1 = Product.new(name: "Complex Product 1", price: 50.00, sku: "CPX-001", stock_quantity: 20)
        product2 = Product.new(name: "Complex Product 2", price: 75.00, sku: "CPX-002", stock_quantity: 15)
        
        assert product1.save, "Product 1 should save"
        assert product2.save, "Product 2 should save"

        inventory1 = Inventory.new(product: product1.pointer, location: "Warehouse A", quantity: 20)
        inventory2 = Inventory.new(product: product2.pointer, location: "Warehouse A", quantity: 15)
        
        assert inventory1.save, "Inventory 1 should save"
        assert inventory2.save, "Inventory 2 should save"

        # Business scenario: Process an order (reserve inventory, create order, update stock)
        order_items = [
          { product_id: product1.id, quantity: 5, price: 50.00 },
          { product_id: product2.id, quantity: 3, price: 75.00 }
        ]
        total_amount = (5 * 50.00) + (3 * 75.00)

        responses = Parse::Object.transaction do |batch|
          # Create order
          order = Order.new(
            order_number: "ORD-#{rand(10000)}",
            customer_name: "John Doe",
            total_amount: total_amount,
            status: "confirmed",
            items: order_items
          )
          batch.add(order)

          # Reserve inventory for product 1
          inventory1.reserved_quantity += 5
          inventory1.quantity -= 5
          batch.add(inventory1)

          # Reserve inventory for product 2
          inventory2.reserved_quantity += 3
          inventory2.quantity -= 3
          batch.add(inventory2)

          # Update product stock
          product1.stock_quantity -= 5
          batch.add(product1)

          product2.stock_quantity -= 3
          batch.add(product2)
        end

        # Verify complex transaction succeeded
        assert responses.all?(&:success?), "Complex transaction should succeed"
        assert_equal 5, responses.size, "Should have 5 operations (order + 2 inventory + 2 products)"

        # Verify all changes were applied correctly
        inventory1.fetch!
        inventory2.fetch!
        product1.fetch!
        product2.fetch!

        assert_equal 15, inventory1.quantity, "Inventory 1 quantity should be reduced"
        assert_equal 5, inventory1.reserved_quantity, "Inventory 1 should have reserved quantity"
        assert_equal 12, inventory2.quantity, "Inventory 2 quantity should be reduced"
        assert_equal 3, inventory2.reserved_quantity, "Inventory 2 should have reserved quantity"
        assert_equal 15, product1.stock_quantity, "Product 1 stock should be reduced"
        assert_equal 12, product2.stock_quantity, "Product 2 stock should be reduced"

        # Verify order was created  
        created_order = Order.first
        assert created_order, "Order should be created"
        assert_equal "confirmed", created_order.status, "Order should be confirmed"
        assert_equal total_amount, created_order.total_amount, "Order total should match"

        puts "✅ Complex business transaction completed successfully"
      end
    end
  end

  def test_transaction_with_retry_on_conflict
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    skip "Conflict simulation requires special setup" unless ENV['TEST_TRANSACTION_CONFLICTS'] == 'true'

    with_parse_server do
      with_timeout(20, "transaction retry test") do
        puts "\n=== Testing Transaction Retry on Conflict ==="

        # Create a product that will be updated concurrently
        product = Product.new(name: "Retry Test Product", price: 100.00, sku: "RTY-001", stock_quantity: 100)
        assert product.save, "Product should save initially"

        # Test transaction with custom retry count
        retry_count = 0
        responses = Parse::Object.transaction(retries: 3) do |batch|
          retry_count += 1
          puts "Transaction attempt ##{retry_count}"

          # Simulate concurrent modification scenario
          if retry_count == 1
            # On first attempt, modify product externally to simulate conflict
            # This is a simplified test - real conflicts are harder to simulate
            product.stock_quantity -= 1
          else
            product.stock_quantity -= 2
          end
          
          batch.add(product)
        end

        assert responses.all?(&:success?), "Transaction should eventually succeed with retries"
        
        puts "✅ Transaction retry mechanism tested"
      end
    end
  end

  def test_transaction_with_mixed_operations
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "mixed operations transaction test") do
        puts "\n=== Testing Transaction with Mixed Operations ==="

        # Create existing product for update
        existing_product = Product.new(name: "Existing Product", price: 60.00, sku: "EXT-001")
        assert existing_product.save, "Existing product should save"

        responses = Parse::Object.transaction do |batch|
          # Update existing product
          existing_product.price = 65.00
          existing_product.is_active = false
          batch.add(existing_product)

          # Create new product
          new_product = Product.new(
            name: "New Product in Transaction", 
            price: 45.00, 
            sku: "NEW-001",
            stock_quantity: 30
          )
          batch.add(new_product)

          # Create inventory for new product
          new_inventory = Inventory.new(
            product: new_product.pointer,
            location: "Warehouse B",
            quantity: 30
          )
          batch.add(new_inventory)

          # Create order referencing both products
          order = Order.new(
            order_number: "MXD-#{rand(10000)}",
            customer_name: "Jane Smith",
            total_amount: 110.00,  # 65 + 45
            status: "pending"
          )
          batch.add(order)
        end

        # Verify mixed operations succeeded
        assert responses.all?(&:success?), "Mixed operations transaction should succeed"
        assert_equal 4, responses.size, "Should have 4 operations"

        # Verify updates
        existing_product.fetch!
        assert_equal 65.00, existing_product.price, "Existing product price should be updated"
        assert_equal false, existing_product.is_active, "Existing product should be inactive"

        # Verify new objects were created
        new_product = Product.first(sku: "NEW-001")
        assert new_product, "New product should be created"
        assert_equal "New Product in Transaction", new_product.name

        new_inventory = Inventory.first(location: "Warehouse B")
        assert new_inventory, "New inventory should be created"

        puts "✅ Mixed operations transaction completed successfully"
      end
    end
  end

  def test_transaction_error_handling
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "transaction error handling test") do
        puts "\n=== Testing Transaction Error Handling ==="

        # Test 1: Transaction without block should raise ArgumentError
        assert_raises(ArgumentError) do
          Parse::Object.transaction
        end

        # Test 2: Empty transaction should succeed
        responses = Parse::Object.transaction do |batch|
          # Empty transaction
        end
        assert responses.is_a?(Array), "Empty transaction should return empty array"
        assert_empty responses, "Empty transaction should have no responses"

        # Test 3: Transaction with nil return should work
        responses = Parse::Object.transaction do |batch|
          nil  # Return nil
        end
        assert responses.is_a?(Array), "Nil return transaction should return array"

        # Test 4: Transaction returning non-Parse objects should ignore them
        responses = Parse::Object.transaction do
          ["string", 123, { hash: "object" }]  # Non-Parse objects
        end
        assert_empty responses, "Non-Parse objects should be ignored"

        puts "✅ Transaction error handling works correctly"
      end
    end
  end

  def test_transaction_batch_limits
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "transaction batch limits test") do
        puts "\n=== Testing Transaction Batch Limits ==="

        # Create multiple products to test batch processing
        products = []
        
        # Create products in a transaction (test batch size handling)
        responses = Parse::Object.transaction do |batch|
          10.times do |i|
            product = Product.new(
              name: "Batch Product #{i+1}",
              price: (i + 1) * 10.0,
              sku: "BCH-#{sprintf('%03d', i+1)}",
              stock_quantity: (i + 1) * 5
            )
            products << product
            batch.add(product)
          end
        end

        # Verify batch transaction succeeded
        assert responses.all?(&:success?), "Batch transaction should succeed"
        assert_equal 10, responses.size, "Should have 10 responses"

        # Verify all products were created
        created_products = Product.all(:sku.starts_with => "BCH-")
        assert_equal 10, created_products.count, "All 10 products should be created"

        # Test updating all in another transaction
        responses = Parse::Object.transaction do
          products.each { |p| p.is_active = false }
          products  # Return array for auto-batch
        end

        assert responses.all?(&:success?), "Batch update transaction should succeed"
        
        # Verify all products were updated
        products.each(&:fetch!)
        assert products.all? { |p| p.is_active == false }, "All products should be inactive"

        puts "✅ Transaction batch limits handled correctly"
      end
    end
  end

  def test_transaction_with_pointers_and_relations
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "transaction pointers and relations test") do
        puts "\n=== Testing Transaction with Pointers and Relations ==="

        # Create main product
        main_product = Product.new(name: "Main Product", price: 200.00, sku: "MAIN-001")
        assert main_product.save, "Main product should save"

        responses = Parse::Object.transaction do |batch|
          # Create inventory with pointer to main product
          inventory = Inventory.new(
            product: main_product.pointer,  # Test pointer relationship
            location: "Main Warehouse",
            quantity: 100
          )
          batch.add(inventory)

          # Create order with reference to product
          order = Order.new(
            order_number: "PTR-#{rand(10000)}",
            customer_name: "Pointer Test Customer",
            total_amount: 200.00,
            items: [{ 
              product_id: main_product.id,  # Reference by ID
              product_name: main_product.name,
              quantity: 1,
              price: 200.00
            }]
          )
          batch.add(order)

          # Update main product in same transaction
          main_product.stock_quantity = 99
          batch.add(main_product)
        end

        # Verify pointer-based transaction succeeded
        assert responses.all?(&:success?), "Pointer-based transaction should succeed"
        assert_equal 3, responses.size, "Should have 3 operations"

        # Verify relationships are correct
        created_inventory = Inventory.first(location: "Main Warehouse")
        assert created_inventory, "Inventory should be created"
        
        # Test pointer relationship
        assert_equal main_product.id, created_inventory.product.id, "Inventory should point to main product"

        # Verify order references are correct
        created_order = Order.all(:order_number.starts_with => "PTR-").first
        assert created_order, "Order should be created"
        assert_equal main_product.id, created_order.items.first["product_id"], "Order should reference main product"

        puts "✅ Transaction with pointers and relations worked correctly"
      end
    end
  end

  def test_transaction_assigns_object_ids_to_new_objects
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "transaction object ID assignment test") do
        puts "\n=== Testing Transaction Assigns Object IDs to New Objects ==="

        # Create NEW objects (not yet saved) within a transaction
        products = []

        responses = Parse::Object.transaction do |batch|
          3.times do |i|
            product = Product.new(name: "New Product #{i}", price: (i + 1) * 10.0, sku: "NEW-#{i}")
            products << product
            batch.add(product)
          end
        end

        # Verify transaction succeeded
        assert responses.all?(&:success?), "All operations should succeed"
        assert_equal 3, responses.size, "Should have 3 responses"

        # Verify each product received its objectId from the server
        products.each_with_index do |product, i|
          refute_nil product.id, "Product #{i} should have objectId assigned"
          assert product.id.is_a?(String), "Product #{i} objectId should be a string"
          assert product.id.length > 0, "Product #{i} objectId should not be empty"

          # Verify timestamps were assigned
          refute_nil product.created_at, "Product #{i} should have created_at assigned"
          refute_nil product.updated_at, "Product #{i} should have updated_at assigned"
          assert product.created_at.is_a?(DateTime) || product.created_at.is_a?(Parse::Date),
                 "Product #{i} created_at should be a DateTime"
        end

        # Verify objects can be fetched from server using assigned IDs
        products.each_with_index do |product, i|
          fetched = Product.find(product.id)
          refute_nil fetched, "Should be able to fetch Product #{i} by ID"
          assert_equal "New Product #{i}", fetched.name, "Fetched product should have correct name"
        end

        puts "✅ Transaction correctly assigned objectId, createdAt, updatedAt to new objects"
      end
    end
  end
end