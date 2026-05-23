require_relative "../../test_helper_integration"

# Test models for upsert method integration testing
class UpsertTestUser < Parse::Object
  parse_class "UpsertTestUser"

  property :email, :string
  property :name, :string
  property :age, :integer
  property :status, :string, default: "active"
  property :last_login, :date
end

class UpsertTestProduct < Parse::Object
  parse_class "UpsertTestProduct"

  property :sku, :string
  property :name, :string
  property :price, :float
  property :category, :string
  property :in_stock, :boolean, default: true
end

class UpsertMethodsIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_first_or_create_finds_existing_object_unchanged
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "first_or_create finds existing test") do
        puts "\n=== Testing first_or_create Finds Existing Object Unchanged ==="

        # Create initial user
        original_user = UpsertTestUser.new(email: "existing@example.com", name: "Original Name", age: 25)
        assert original_user.save, "Original user should save"
        original_id = original_user.id

        # Use first_or_create with different resource_attrs
        found_user = UpsertTestUser.first_or_create(
          { email: "existing@example.com" },
          { name: "Different Name", age: 30, status: "inactive" }
        )

        # Verify object was found, not created
        assert_equal original_id, found_user.id, "Should find existing user"
        assert_equal "Original Name", found_user.name, "Name should be unchanged"
        assert_equal 25, found_user.age, "Age should be unchanged"
        assert_equal "active", found_user.status, "Status should be unchanged"
        refute found_user.new?, "Found user should not be new"

        puts "✅ first_or_create finds existing object without modifications"
      end
    end
  end

  def test_first_or_create_creates_new_object_unsaved
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "first_or_create creates new unsaved test") do
        puts "\n=== Testing first_or_create Creates New Object (Unsaved) ==="

        # Use first_or_create for non-existing user
        new_user = UpsertTestUser.first_or_create(
          { email: "new@example.com" },
          { name: "New User", age: 35, status: "pending" }
        )

        # Verify object was created with all attributes
        assert new_user.new?, "New user should be unsaved"
        assert_equal "new@example.com", new_user.email, "Email should be set from query_attrs"
        assert_equal "New User", new_user.name, "Name should be set from resource_attrs"
        assert_equal 35, new_user.age, "Age should be set from resource_attrs"
        assert_equal "pending", new_user.status, "Status should be set from resource_attrs"
        assert_nil new_user.id, "Unsaved object should not have ID"

        # Verify object is not yet in database
        found_in_db = UpsertTestUser.first(email: "new@example.com")
        assert_nil found_in_db, "Object should not be in database yet"

        puts "✅ first_or_create creates new unsaved object with combined attributes"
      end
    end
  end

  def test_first_or_create_bang_finds_existing_unchanged
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "first_or_create! finds existing test") do
        puts "\n=== Testing first_or_create! Finds Existing Object Unchanged ==="

        # Create initial product
        original_product = UpsertTestProduct.new(sku: "PROD-001", name: "Original Product", price: 19.99)
        assert original_product.save, "Original product should save"
        original_id = original_product.id

        # Use first_or_create! with different resource_attrs
        found_product = UpsertTestProduct.first_or_create!(
          { sku: "PROD-001" },
          { name: "Different Product", price: 29.99, category: "electronics" }
        )

        # Verify object was found, not created or modified
        assert_equal original_id, found_product.id, "Should find existing product"
        assert_equal "Original Product", found_product.name, "Name should be unchanged"
        assert_equal 19.99, found_product.price, "Price should be unchanged"
        assert_nil found_product.category, "Category should remain nil"
        refute found_product.new?, "Found product should not be new"

        puts "✅ first_or_create! finds existing object without modifications"
      end
    end
  end

  def test_first_or_create_bang_creates_and_saves_new_object
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "first_or_create! creates and saves test") do
        puts "\n=== Testing first_or_create! Creates and Saves New Object ==="

        # Use first_or_create! for non-existing product
        new_product = UpsertTestProduct.first_or_create!(
          { sku: "PROD-NEW" },
          { name: "New Product", price: 49.99, category: "gadgets" }
        )

        # Verify object was created and saved with all attributes
        refute new_product.new?, "New product should be saved"
        assert new_product.id.present?, "Saved object should have ID"
        assert_equal "PROD-NEW", new_product.sku, "SKU should be set from query_attrs"
        assert_equal "New Product", new_product.name, "Name should be set from resource_attrs"
        assert_equal 49.99, new_product.price, "Price should be set from resource_attrs"
        assert_equal "gadgets", new_product.category, "Category should be set from resource_attrs"

        # Verify object is in database
        found_in_db = UpsertTestProduct.first(sku: "PROD-NEW")
        assert found_in_db, "Object should be in database"
        assert_equal new_product.id, found_in_db.id, "Should find the same object"
        assert_equal "New Product", found_in_db.name, "Database object should have correct name"

        puts "✅ first_or_create! creates and saves new object with combined attributes"
      end
    end
  end

  def test_create_or_update_bang_finds_and_updates_existing
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "create_or_update! updates existing test") do
        puts "\n=== Testing create_or_update! Finds and Updates Existing Object ==="

        # Create initial user
        original_user = UpsertTestUser.new(email: "update@example.com", name: "Old Name", age: 25, status: "active")
        assert original_user.save, "Original user should save"
        original_id = original_user.id

        # Use create_or_update! to update existing user
        updated_user = UpsertTestUser.create_or_update!(
          { email: "update@example.com" },
          { name: "Updated Name", age: 30, last_login: Time.now }
        )

        # Verify object was found and updated
        assert_equal original_id, updated_user.id, "Should be the same object"
        assert_equal "Updated Name", updated_user.name, "Name should be updated"
        assert_equal 30, updated_user.age, "Age should be updated"
        assert updated_user.last_login.present?, "last_login should be set"
        assert_equal "active", updated_user.status, "Unchanged fields should remain"
        refute updated_user.new?, "Object should still be persisted"

        # Verify changes are persisted in database
        found_in_db = UpsertTestUser.first(email: "update@example.com")
        assert_equal "Updated Name", found_in_db.name, "Database should reflect name change"
        assert_equal 30, found_in_db.age, "Database should reflect age change"

        puts "✅ create_or_update! finds and updates existing object correctly"
      end
    end
  end

  def test_create_or_update_bang_creates_new_object
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "create_or_update! creates new test") do
        puts "\n=== Testing create_or_update! Creates New Object ==="

        # Use create_or_update! for non-existing user
        new_user = UpsertTestUser.create_or_update!(
          { email: "create@example.com" },
          { name: "Created User", age: 28, status: "pending" }
        )

        # Verify object was created and saved
        refute new_user.new?, "New user should be saved"
        assert new_user.id.present?, "Saved object should have ID"
        assert_equal "create@example.com", new_user.email, "Email should be set from query_attrs"
        assert_equal "Created User", new_user.name, "Name should be set from resource_attrs"
        assert_equal 28, new_user.age, "Age should be set from resource_attrs"
        assert_equal "pending", new_user.status, "Status should be set from resource_attrs"

        # Verify object is in database
        found_in_db = UpsertTestUser.first(email: "create@example.com")
        assert found_in_db, "Object should be in database"
        assert_equal new_user.id, found_in_db.id, "Should find the same object"

        puts "✅ create_or_update! creates and saves new object correctly"
      end
    end
  end

  def test_create_or_update_bang_no_save_when_no_changes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "create_or_update! no changes test") do
        puts "\n=== Testing create_or_update! No Save When No Changes ==="

        # Create initial product
        original_product = UpsertTestProduct.new(sku: "NO-CHANGE", name: "Same Product", price: 15.50)
        assert original_product.save, "Original product should save"
        original_updated_at = original_product.updated_at

        # Small delay to ensure updated_at would change if saved
        sleep(0.1)

        # Use create_or_update! with identical values
        result_product = UpsertTestProduct.create_or_update!(
          { sku: "NO-CHANGE" },
          { name: "Same Product", price: 15.50 } # Identical values
        )

        # Verify no save occurred (updated_at unchanged)
        result_product.fetch!  # Refresh from database
        assert_equal original_updated_at.to_s, result_product.updated_at.to_s, "updated_at should be unchanged (no save occurred)"
        assert_equal "Same Product", result_product.name, "Name should remain the same"
        assert_equal 15.50, result_product.price, "Price should remain the same"

        puts "✅ create_or_update! skips save when no changes detected"
      end
    end
  end

  def test_create_or_update_bang_empty_resource_attrs
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "create_or_update! empty resource_attrs test") do
        puts "\n=== Testing create_or_update! with Empty resource_attrs ==="

        # Create initial user
        original_user = UpsertTestUser.new(email: "empty@example.com", name: "Original", age: 40)
        assert original_user.save, "Original user should save"
        original_updated_at = original_user.updated_at

        # Small delay to ensure updated_at would change if saved
        sleep(0.1)

        # Use create_or_update! with empty resource_attrs
        result_user = UpsertTestUser.create_or_update!(
          { email: "empty@example.com" },
          {} # Empty resource_attrs
        )

        # Verify no modifications or saves occurred
        result_user.fetch!  # Refresh from database
        assert_equal original_updated_at.to_s, result_user.updated_at.to_s, "updated_at should be unchanged"
        assert_equal "Original", result_user.name, "Name should be unchanged"
        assert_equal 40, result_user.age, "Age should be unchanged"

        puts "✅ create_or_update! handles empty resource_attrs efficiently"
      end
    end
  end

  def test_performance_comparison_across_methods
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "performance comparison test") do
        puts "\n=== Testing Performance Comparison Across Methods ==="

        # Create initial test data
        test_user = UpsertTestUser.new(email: "perf@example.com", name: "Performance Test", age: 35)
        assert test_user.save, "Test user should save"

        # Test first_or_create performance (existing object)
        start_time = Time.now
        5.times do
          result = UpsertTestUser.first_or_create({ email: "perf@example.com" }, { name: "Different" })
          assert_equal "Performance Test", result.name, "Should find unchanged object"
        end
        first_or_create_time = Time.now - start_time

        # Test first_or_create! performance (existing object)
        start_time = Time.now
        5.times do
          result = UpsertTestUser.first_or_create!({ email: "perf@example.com" }, { name: "Different" })
          assert_equal "Performance Test", result.name, "Should find unchanged object"
        end
        first_or_create_bang_time = Time.now - start_time

        # Test create_or_update! performance (no changes)
        start_time = Time.now
        5.times do
          result = UpsertTestUser.create_or_update!({ email: "perf@example.com" }, { name: "Performance Test", age: 35 })
          assert_equal "Performance Test", result.name, "Should find unchanged object"
        end
        create_or_update_no_change_time = Time.now - start_time

        # Test create_or_update! performance (with changes)
        start_time = Time.now
        5.times do |i|
          result = UpsertTestUser.create_or_update!({ email: "perf@example.com" }, { age: 35 + i })
        end
        create_or_update_with_change_time = Time.now - start_time

        puts "Performance Results (5 operations each):"
        puts "  first_or_create (existing):     #{(first_or_create_time * 1000).round(2)}ms"
        puts "  first_or_create! (existing):    #{(first_or_create_bang_time * 1000).round(2)}ms"
        puts "  create_or_update! (no change):  #{(create_or_update_no_change_time * 1000).round(2)}ms"
        puts "  create_or_update! (with change):#{(create_or_update_with_change_time * 1000).round(2)}ms"

        # Verify performance optimizations
        # Allow some tolerance for natural variation in execution times
        performance_tolerance = 0.05 # 50ms tolerance
        assert (first_or_create_time <= first_or_create_bang_time + performance_tolerance),
               "first_or_create should be roughly as fast or faster (no save). Got #{(first_or_create_time * 1000).round(2)}ms vs #{(first_or_create_bang_time * 1000).round(2)}ms"
        assert create_or_update_no_change_time < create_or_update_with_change_time, "No-change should be faster than with-change"

        puts "✅ Performance characteristics verified"
      end
    end
  end

  def test_complex_upsert_workflow
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "complex upsert workflow test") do
        puts "\n=== Testing Complex Upsert Workflow ==="

        # Workflow: User registration and profile updates

        # Step 1: Try to find existing user, create if not found (unsaved)
        user = UpsertTestUser.first_or_create(
          { email: "workflow@example.com" },
          { name: "Workflow User", age: 25, status: "pending" }
        )

        assert user.new?, "User should be new and unsaved"
        assert_equal "pending", user.status, "Should have pending status"

        # Step 2: Complete registration (save the user)
        user.status = "active"
        assert user.save, "Should save user after completing registration"

        # Step 3: Update profile information
        updated_user = UpsertTestUser.create_or_update!(
          { email: "workflow@example.com" },
          { age: 26, last_login: Time.now }
        )

        assert_equal user.id, updated_user.id, "Should be the same user"
        assert_equal 26, updated_user.age, "Age should be updated"
        assert_equal "active", updated_user.status, "Status should remain active"
        assert updated_user.last_login.present?, "Should have last_login set"

        # Step 4: Subsequent login (no changes needed)
        login_user = UpsertTestUser.create_or_update!(
          { email: "workflow@example.com" },
          { age: 26 } # Same age, should not save
        )

        assert_equal updated_user.id, login_user.id, "Should be the same user"

        puts "✅ Complex upsert workflow completed successfully"
      end
    end
  end
end
