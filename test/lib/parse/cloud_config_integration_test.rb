require_relative "../../test_helper_integration"
require "minitest/autorun"

class CloudConfigTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_config_read_and_write_operations
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "config read and write operations test") do
        puts "\n=== Testing Cloud Config Read and Write Operations ==="

        # Test 1: Read initial config (should be empty or have default values)
        puts "\n--- Test 1: Read initial config ---"

        initial_config = Parse.config
        puts "Initial config: #{initial_config.inspect}"

        # Config should be a hash (might be empty initially)
        assert initial_config.is_a?(Hash), "Config should return a hash"

        # Test 2: Set a single config variable
        puts "\n--- Test 2: Set single config variable ---"

        test_key = "testKey1"
        test_value = "testValue1"

        result = Parse.set_config(test_key, test_value)
        assert result, "Setting config should return true on success"
        puts "Set config result: #{result}"

        # Test 3: Verify the config variable was set by reading it back
        puts "\n--- Test 3: Verify config variable was set ---"

        # Force refresh the config cache
        updated_config = Parse.config!
        puts "Updated config: #{updated_config.inspect}"

        assert updated_config.key?(test_key), "Config should contain the test key"
        assert_equal test_value, updated_config[test_key], "Config value should match what was set"

        # Test 4: Set multiple config variables at once
        puts "\n--- Test 4: Set multiple config variables ---"

        batch_config = {
          "batchKey1" => "batchValue1",
          "batchKey2" => 42,
          "batchKey3" => true,
          "batchKey4" => [1, 2, 3],
          "batchKey5" => { "nested" => "object" },
        }

        batch_result = Parse.update_config(batch_config)
        assert batch_result, "Batch config update should return true on success"
        puts "Batch update result: #{batch_result}"

        # Test 5: Verify all batch config variables were set
        puts "\n--- Test 5: Verify batch config variables ---"

        final_config = Parse.config!
        puts "Final config: #{final_config.inspect}"

        batch_config.each do |key, expected_value|
          assert final_config.key?(key), "Config should contain batch key: #{key}"
          assert_equal expected_value, final_config[key], "Config value for #{key} should match"
          puts "✓ #{key}: #{final_config[key]}"
        end

        # Test 6: Update existing config variable
        puts "\n--- Test 6: Update existing config variable ---"

        updated_value = "updatedTestValue1"
        update_result = Parse.set_config(test_key, updated_value)
        assert update_result, "Updating existing config should return true"

        refreshed_config = Parse.config!
        assert_equal updated_value, refreshed_config[test_key], "Updated config value should be reflected"
        puts "Updated #{test_key}: #{refreshed_config[test_key]}"

        # Test 7: Test config caching behavior
        puts "\n--- Test 7: Test config caching behavior ---"

        # Get config without forcing refresh (should use cache)
        cached_config = Parse.config
        assert_equal refreshed_config, cached_config, "Cached config should match refreshed config"

        # Force refresh and ensure it's still the same
        force_refreshed_config = Parse.config!
        assert_equal cached_config, force_refreshed_config, "Force refreshed config should match cached"

        puts "Config caching verified"

        puts "✅ Cloud config read and write operations test passed"
      end
    end
  end

  def test_config_data_types_and_edge_cases
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "config data types and edge cases test") do
        puts "\n=== Testing Cloud Config Data Types and Edge Cases ==="

        # Test different data types supported by Parse
        test_configs = {
          "stringValue" => "Hello World",
          "integerValue" => 123,
          "floatValue" => 45.67,
          "booleanTrue" => true,
          "booleanFalse" => false,
          "arrayValue" => ["item1", "item2", "item3"],
          "objectValue" => {
            "nested" => "value",
            "number" => 999,
            "array" => [1, 2, 3],
          },
          "emptyString" => "",
          "emptyArray" => [],
          "emptyObject" => {},
        }

        puts "\n--- Testing various data types ---"

        # Set all test configs
        result = Parse.update_config(test_configs)
        assert result, "Setting various data types should succeed"

        # Verify all data types
        verified_config = Parse.config!

        test_configs.each do |key, expected_value|
          assert verified_config.key?(key), "Config should contain key: #{key}"

          actual_value = verified_config[key]

          case expected_value
          when Hash, Array
            # For complex types, do deep comparison
            assert_equal expected_value, actual_value, "#{key} should match exactly"
          else
            # For simple types
            assert_equal expected_value, actual_value, "#{key} should match: expected #{expected_value.inspect}, got #{actual_value.inspect}"
          end

          puts "✓ #{key} (#{expected_value.class.name}): #{actual_value.inspect}"
        end

        # Test edge cases
        puts "\n--- Testing edge cases ---"

        # Test 1: Very long string
        long_string = "x" * 1000
        long_result = Parse.set_config("longString", long_string)
        assert long_result, "Setting long string should succeed"

        long_config = Parse.config!
        assert_equal long_string, long_config["longString"], "Long string should be preserved"
        puts "✓ Long string (#{long_string.length} chars) preserved"

        # Test 2: Large number
        large_number = 999999999
        large_result = Parse.set_config("largeNumber", large_number)
        assert large_result, "Setting large number should succeed"

        large_config = Parse.config!
        assert_equal large_number, large_config["largeNumber"], "Large number should be preserved"
        puts "✓ Large number (#{large_number}) preserved"

        # Test 3: Unicode strings
        unicode_string = "Hello 世界 🌍 émojis"
        unicode_result = Parse.set_config("unicodeString", unicode_string)
        assert unicode_result, "Setting unicode string should succeed"

        unicode_config = Parse.config!
        assert_equal unicode_string, unicode_config["unicodeString"], "Unicode string should be preserved"
        puts "✓ Unicode string preserved: #{unicode_config["unicodeString"]}"

        # Test 4: Deeply nested object
        nested_object = {
          "level1" => {
            "level2" => {
              "level3" => {
                "level4" => "deep value",
                "array" => [1, 2, { "nested_in_array" => true }],
              },
            },
          },
        }

        nested_result = Parse.set_config("deeplyNested", nested_object)
        assert nested_result, "Setting deeply nested object should succeed"

        nested_config = Parse.config!
        assert_equal nested_object, nested_config["deeplyNested"], "Deeply nested object should be preserved"
        puts "✓ Deeply nested object preserved"

        # Test 5: Special string values
        special_strings = {
          "nullString" => "null",
          "undefinedString" => "undefined",
          "jsonString" => '{"key": "value"}',
          "numberString" => "123",
          "booleanString" => "true",
        }

        special_result = Parse.update_config(special_strings)
        assert special_result, "Setting special strings should succeed"

        special_config = Parse.config!
        special_strings.each do |key, expected_value|
          # These should remain as strings, not be converted
          assert_equal expected_value, special_config[key], "#{key} should remain as string"
          assert special_config[key].is_a?(String), "#{key} should be a string type"
          puts "✓ #{key} remains string: #{special_config[key].inspect}"
        end

        puts "✅ Cloud config data types and edge cases test passed"
      end
    end
  end

  def test_config_error_handling_and_validation
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "config error handling and validation test") do
        puts "\n=== Testing Cloud Config Error Handling and Validation ==="

        # Test 1: Test config operations with valid data
        puts "\n--- Test 1: Valid config operations ---"

        valid_config = {
          "validKey1" => "validValue1",
          "validKey2" => 42,
        }

        valid_result = Parse.update_config(valid_config)
        assert valid_result, "Valid config update should succeed"

        verified_config = Parse.config!
        valid_config.each do |key, value|
          assert_equal value, verified_config[key], "Valid config should be set correctly"
        end
        puts "✓ Valid config operations work correctly"

        # Test 2: Test with nil values (may or may not be supported)
        puts "\n--- Test 2: Testing nil values ---"

        begin
          nil_result = Parse.set_config("nilValue", nil)
          if nil_result
            nil_config = Parse.config!
            puts "✓ Nil values are supported: #{nil_config["nilValue"].inspect}"
          else
            puts "ℹ Nil values are not supported (returned false)"
          end
        rescue => e
          puts "ℹ Nil values cause error: #{e.message}"
          # This is acceptable - Parse may not support nil values
        end

        # Test 3: Test with very large objects (testing limits)
        puts "\n--- Test 3: Testing large objects ---"

        begin
          # Create a large object to test size limits
          large_array = (1..1000).to_a
          large_object = {
            "largeArray" => large_array,
            "description" => "This is a test of large config objects",
          }

          large_result = Parse.set_config("largeObject", large_object)
          if large_result
            large_config = Parse.config!
            assert_equal large_array, large_config["largeObject"]["largeArray"], "Large object should be preserved"
            puts "✓ Large objects are supported (#{large_array.length} items)"
          else
            puts "ℹ Large objects are not supported (returned false)"
          end
        rescue => e
          puts "ℹ Large objects cause error: #{e.message}"
          # This is acceptable - Parse may have size limits
        end

        # Test 4: Test key validation
        puts "\n--- Test 4: Testing key validation ---"

        # Test empty key
        begin
          empty_key_result = Parse.set_config("", "value")
          if empty_key_result
            puts "ℹ Empty keys are allowed"
          else
            puts "✓ Empty keys are properly rejected"
          end
        rescue => e
          puts "✓ Empty keys cause error (expected): #{e.message}"
        end

        # Test very long key
        begin
          long_key = "x" * 100
          long_key_result = Parse.set_config(long_key, "value")
          if long_key_result
            long_key_config = Parse.config!
            assert_equal "value", long_key_config[long_key], "Long key should work"
            puts "✓ Long keys are supported (#{long_key.length} chars)"
          else
            puts "ℹ Long keys are not supported (returned false)"
          end
        rescue => e
          puts "ℹ Long keys cause error: #{e.message}"
        end

        # Test 5: Test concurrent config updates
        puts "\n--- Test 5: Testing multiple rapid updates ---"

        # Perform multiple rapid updates to test for race conditions
        (1..5).each do |i|
          rapid_result = Parse.set_config("rapidUpdate", i)
          assert rapid_result, "Rapid update #{i} should succeed"
        end

        final_rapid_config = Parse.config!
        assert_equal 5, final_rapid_config["rapidUpdate"], "Final rapid update value should be 5"
        puts "✓ Multiple rapid updates handled correctly"

        # Test 6: Test config persistence across client instances
        puts "\n--- Test 6: Testing config persistence ---"

        # Set a unique config value
        unique_value = "unique_#{Time.now.to_i}"
        persistence_result = Parse.set_config("persistenceTest", unique_value)
        assert persistence_result, "Persistence test config should be set"

        # Create a new client instance (if possible) or just clear cache
        Parse.config!  # Force refresh

        persistence_config = Parse.config
        assert_equal unique_value, persistence_config["persistenceTest"], "Config should persist across cache refreshes"
        puts "✓ Config values persist correctly"

        # Test 7: Test config with special characters in keys
        puts "\n--- Test 7: Testing special characters in keys ---"

        special_keys = {
          "key.with.dots" => "dots",
          "key-with-dashes" => "dashes",
          "key_with_underscores" => "underscores",
          "keyWithCamelCase" => "camelCase",
          "key with spaces" => "spaces",
          "key123numbers" => "numbers",
        }

        special_keys.each do |key, value|
          begin
            special_result = Parse.set_config(key, value)
            if special_result
              special_config = Parse.config!
              if special_config.key?(key) && special_config[key] == value
                puts "✓ Key '#{key}' is supported"
              else
                puts "⚠ Key '#{key}' was modified or rejected"
              end
            else
              puts "ℹ Key '#{key}' is not supported (returned false)"
            end
          rescue => e
            puts "ℹ Key '#{key}' causes error: #{e.message}"
          end
        end

        puts "✅ Cloud config error handling and validation test passed"
      end
    end
  end

  def test_config_client_methods_and_caching
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "config client methods and caching test") do
        puts "\n=== Testing Cloud Config Client Methods and Caching ==="

        # Test 1: Test direct client methods vs Parse module methods
        puts "\n--- Test 1: Client methods vs module methods ---"

        client = Parse.client

        # Set config using client method
        client_result = client.update_config({ "clientTest" => "clientValue" })
        assert client_result, "Client config update should succeed"

        # Read using module method
        module_config = Parse.config!
        assert_equal "clientValue", module_config["clientTest"], "Module method should read client-set config"

        # Set config using module method
        Parse.set_config("moduleTest", "moduleValue")

        # Read using client method
        client_config = client.config!
        assert_equal "moduleValue", client_config["moduleTest"], "Client method should read module-set config"

        puts "✓ Client and module methods are compatible"

        # Test 2: Test config caching behavior in detail
        puts "\n--- Test 2: Detailed caching behavior ---"

        # Set initial value
        Parse.set_config("cacheTest", "initialValue")

        # Read with caching (first call)
        cached_config1 = Parse.config
        assert_equal "initialValue", cached_config1["cacheTest"], "Initial cached read should work"

        # Read with caching (second call - should use cache)
        cached_config2 = Parse.config
        assert_equal cached_config1, cached_config2, "Second cached read should return same object"
        assert_equal "initialValue", cached_config2["cacheTest"], "Cached value should persist"

        # Update config externally (simulate another client/process updating)
        Parse.set_config("cacheTest", "updatedValue")

        # Read with caching (should still return old cached value)
        cached_config3 = Parse.config
        # Note: This might still return the cached value depending on implementation

        # Force refresh cache
        fresh_config = Parse.config!
        assert_equal "updatedValue", fresh_config["cacheTest"], "Force refresh should get updated value"

        # Read with caching after force refresh
        cached_config4 = Parse.config
        assert_equal "updatedValue", cached_config4["cacheTest"], "Cache should be updated after force refresh"

        puts "✓ Config caching behavior verified"

        # Test 3: Test cache invalidation with updates
        puts "\n--- Test 3: Cache invalidation with updates ---"

        # Set initial config
        Parse.update_config({ "invalidationTest1" => "value1", "invalidationTest2" => "value2" })

        # Read to populate cache
        pre_update_config = Parse.config
        assert_equal "value1", pre_update_config["invalidationTest1"]
        assert_equal "value2", pre_update_config["invalidationTest2"]

        # Update one value
        Parse.set_config("invalidationTest1", "updatedValue1")

        # Read cache (should reflect the update if cache is properly invalidated)
        post_update_config = Parse.config
        expected_value = post_update_config["invalidationTest1"]

        if expected_value == "updatedValue1"
          puts "✓ Cache is properly invalidated on updates"
        else
          puts "ℹ Cache is not automatically invalidated (manual refresh needed)"
          # Force refresh to verify the update was persisted
          force_refresh_config = Parse.config!
          assert_equal "updatedValue1", force_refresh_config["invalidationTest1"], "Update should be persisted"
        end

        # Test 4: Test config access with non-existent keys
        puts "\n--- Test 4: Non-existent key access ---"

        current_config = Parse.config!

        # Access non-existent key
        non_existent_value = current_config["nonExistentKey"]
        assert_nil non_existent_value, "Non-existent key should return nil"

        # Verify config is still usable
        assert current_config.is_a?(Hash), "Config should still be a hash"
        puts "✓ Non-existent key access handled correctly"

        # Test 5: Test config with different data access patterns
        puts "\n--- Test 5: Different data access patterns ---"

        # Set up test data
        test_data = {
          "accessTest" => {
            "nested" => {
              "deep" => "deepValue",
            },
            "array" => [1, 2, 3],
          },
        }

        Parse.update_config(test_data)
        access_config = Parse.config!

        # Test nested access
        nested_value = access_config["accessTest"]["nested"]["deep"]
        assert_equal "deepValue", nested_value, "Nested access should work"

        # Test array access
        array_value = access_config["accessTest"]["array"]
        assert_equal [1, 2, 3], array_value, "Array access should work"

        # Test array element access
        first_element = access_config["accessTest"]["array"].first
        assert_equal 1, first_element, "Array element access should work"

        puts "✓ Different data access patterns work correctly"

        puts "✅ Cloud config client methods and caching test passed"
      end
    end
  end

  def test_realistic_config_variables_and_access_patterns
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "realistic config variables and access patterns test") do
        puts "\n=== Testing Realistic Config Variables and Access Patterns ==="

        # Test 1: Set realistic config variables like those commonly used in Parse apps
        puts "\n--- Test 1: Setting realistic Parse config variables ---"

        realistic_config = {
          "_allowedTrailingProjectFeedDays" => 30,
          "_enablePushNotifications" => true,
          "_maxFileUploadSize" => 10485760,  # 10MB in bytes
          "_allowedDomains" => ["example.com", "mydomain.com"],
          "_apiRateLimits" => {
            "requests_per_minute" => 1000,
            "burst_limit" => 100,
          },
          "_featureFlags" => {
            "newUserInterface" => true,
            "betaFeatures" => false,
            "maintenanceMode" => false,
          },
          "_emailSettings" => {
            "fromAddress" => "noreply@example.com",
            "templates" => {
              "welcome" => "welcome_template_id",
              "passwordReset" => "reset_template_id",
            },
          },
          "_defaultUserSettings" => {
            "timezone" => "UTC",
            "notifications" => true,
            "privacy" => "public",
          },
        }

        # Set all realistic config variables
        result = Parse.update_config(realistic_config)
        assert result, "Setting realistic config variables should succeed"
        puts "✓ Set #{realistic_config.keys.length} realistic config variables"

        # Test 2: Access config variables using different patterns
        puts "\n--- Test 2: Accessing config variables with different patterns ---"

        config = Parse.config!

        # Test direct access to underscore-prefixed variables
        trailing_days = config["_allowedTrailingProjectFeedDays"]
        assert_equal 30, trailing_days, "Should access _allowedTrailingProjectFeedDays correctly"
        puts "✓ _allowedTrailingProjectFeedDays: #{trailing_days}"

        # Test boolean config access
        push_enabled = config["_enablePushNotifications"]
        assert_equal true, push_enabled, "Should access boolean config correctly"
        puts "✓ _enablePushNotifications: #{push_enabled}"

        # Test numeric config access
        max_file_size = config["_maxFileUploadSize"]
        assert_equal 10485760, max_file_size, "Should access numeric config correctly"
        puts "✓ _maxFileUploadSize: #{max_file_size} bytes"

        # Test array config access
        allowed_domains = config["_allowedDomains"]
        assert_equal ["example.com", "mydomain.com"], allowed_domains, "Should access array config correctly"
        puts "✓ _allowedDomains: #{allowed_domains}"

        # Test nested object access
        rate_limits = config["_apiRateLimits"]
        assert_equal 1000, rate_limits["requests_per_minute"], "Should access nested config correctly"
        puts "✓ _apiRateLimits.requests_per_minute: #{rate_limits["requests_per_minute"]}"

        # Test deeply nested access
        welcome_template = config["_emailSettings"]["templates"]["welcome"]
        assert_equal "welcome_template_id", welcome_template, "Should access deeply nested config correctly"
        puts "✓ _emailSettings.templates.welcome: #{welcome_template}"

        # Test 3: Update specific config variables and verify changes
        puts "\n--- Test 3: Updating specific config variables ---"

        # Update a single variable
        Parse.set_config("_allowedTrailingProjectFeedDays", 45)

        updated_config = Parse.config!
        updated_days = updated_config["_allowedTrailingProjectFeedDays"]
        assert_equal 45, updated_days, "Updated config variable should be reflected"
        puts "✓ Updated _allowedTrailingProjectFeedDays to: #{updated_days}"

        # Update nested object
        new_rate_limits = {
          "requests_per_minute" => 1500,
          "burst_limit" => 150,
          "daily_limit" => 50000,
        }
        Parse.set_config("_apiRateLimits", new_rate_limits)

        updated_rate_config = Parse.config!
        updated_rate_limits = updated_rate_config["_apiRateLimits"]
        assert_equal 1500, updated_rate_limits["requests_per_minute"], "Nested object update should work"
        assert_equal 50000, updated_rate_limits["daily_limit"], "New nested property should be added"
        puts "✓ Updated _apiRateLimits: #{updated_rate_limits}"

        # Test 4: Environment-specific config patterns
        puts "\n--- Test 4: Environment-specific config patterns ---"

        env_configs = {
          "_env_production" => {
            "debug" => false,
            "logging_level" => "error",
          },
          "_env_development" => {
            "debug" => true,
            "logging_level" => "debug",
          },
          "_env_staging" => {
            "debug" => true,
            "logging_level" => "warn",
          },
        }

        Parse.update_config(env_configs)
        env_config = Parse.config!

        # Test environment config access
        prod_config = env_config["_env_production"]
        assert_equal false, prod_config["debug"], "Production config should have debug false"
        puts "✓ _env_production.debug: #{prod_config["debug"]}"

        dev_config = env_config["_env_development"]
        assert_equal "debug", dev_config["logging_level"], "Development config should have debug logging"
        puts "✓ _env_development.logging_level: #{dev_config["logging_level"]}"

        # Test 5: Feature flag patterns
        puts "\n--- Test 5: Feature flag management patterns ---"

        # Test individual feature flag updates
        Parse.set_config("_featureFlags", {
          "newUserInterface" => false,  # Disable feature
          "betaFeatures" => true,       # Enable beta
          "maintenanceMode" => false,
          "experimentalSearch" => true,  # Add new feature
        })

        feature_config = Parse.config!
        feature_flags = feature_config["_featureFlags"]

        assert_equal false, feature_flags["newUserInterface"], "Feature flag should be disabled"
        assert_equal true, feature_flags["betaFeatures"], "Beta features should be enabled"
        assert_equal true, feature_flags["experimentalSearch"], "New feature flag should be added"
        puts "✓ Feature flags updated: #{feature_flags}"

        # Test 6: Configuration validation patterns
        puts "\n--- Test 6: Configuration validation and defaults ---"

        # Test getting config with fallback values
        current_config = Parse.config!

        # Simulate getting config value with default fallback
        max_upload_size = current_config["_maxFileUploadSize"] || 5242880  # Default 5MB
        assert_equal 10485760, max_upload_size, "Should get actual config value, not default"

        # Test non-existent config with fallback
        non_existent_timeout = current_config["_requestTimeout"] || 30000  # Default 30 seconds
        assert_equal 30000, non_existent_timeout, "Should use default for non-existent config"

        # Test array config with empty fallback
        domains = current_config["_allowedDomains"] || []
        assert_equal ["example.com", "mydomain.com"], domains, "Should get actual domain list"

        puts "✓ Config access with fallbacks works correctly"

        # Test 7: Batch config operations for performance
        puts "\n--- Test 7: Batch config operations ---"

        batch_updates = {}
        (1..10).each do |i|
          batch_updates["_batchTest#{i}"] = {
            "value" => i * 10,
            "enabled" => i.even?,
            "metadata" => {
              "created_at" => Time.now.iso8601,
              "version" => "1.0",
            },
          }
        end

        batch_result = Parse.update_config(batch_updates)
        assert batch_result, "Batch config update should succeed"

        batch_config = Parse.config!
        (1..10).each do |i|
          key = "_batchTest#{i}"
          config_item = batch_config[key]
          assert_equal i * 10, config_item["value"], "Batch item #{i} should have correct value"
          assert_equal i.even?, config_item["enabled"], "Batch item #{i} should have correct enabled state"
          puts "✓ _batchTest#{i}: value=#{config_item["value"]}, enabled=#{config_item["enabled"]}"
        end

        # Test 8: Config variable name validation
        puts "\n--- Test 8: Config variable name edge cases ---"

        edge_case_configs = {
          "_" => "single_underscore",
          "__double" => "double_underscore",
          "_snake_case_config" => "snake_case",
          "_camelCaseConfig" => "camelCase",
          "_123numeric" => "starts_with_number",
          "_config.with.dots" => "dotted_name",
          "_config-with-dashes" => "dashed_name",
        }

        edge_case_configs.each do |key, value|
          begin
            result = Parse.set_config(key, value)
            if result
              verified_config = Parse.config!
              if verified_config.key?(key) && verified_config[key] == value
                puts "✓ Config key '#{key}' is supported"
              else
                puts "⚠ Config key '#{key}' was modified or rejected"
              end
            else
              puts "ℹ Config key '#{key}' was rejected"
            end
          rescue => e
            puts "ℹ Config key '#{key}' caused error: #{e.message}"
          end
        end

        puts "✅ Realistic config variables and access patterns test passed"
      end
    end
  end
end
