#!/usr/bin/env ruby
require_relative '../lib/parse/stack'
require_relative '../test/support/test_server'
require_relative '../test/support/docker_helper'

puts "Parse Stack Test Server Connection Test"
puts "=" * 40

# Try to start Docker containers
puts "\n1. Starting Docker containers..."
if Parse::Test::DockerHelper.start!
  puts "✓ Docker containers started successfully"
else
  puts "✗ Failed to start Docker containers"
  exit 1
end

# Wait a moment for services to fully initialize
puts "\n2. Waiting for services to initialize..."
sleep 5

# Test Parse Server connection
puts "\n3. Testing Parse Server connection..."
if Parse::Test::ServerHelper.setup
  puts "✓ Parse Server connection successful"
  
  # Test a basic operation
  puts "\n4. Testing basic Parse operations..."
  begin
    # Check client configuration
    client = Parse::Client.client
    puts "  Client server_url: #{client.server_url}"
    puts "  Client app_id: #{client.app_id}"
    puts "  Client has master_key: #{client.master_key.present?}"
    
    # Reset any existing data
    Parse::Test::ServerHelper.reset_database!
    
    # Create a test user
    user = Parse::Test::ServerHelper.create_test_user(
      username: 'testuser',
      password: 'testpass',
      email: 'test@example.com'
    )
    
    puts "✓ Created test user: #{user.username} (ID: #{user.id})"
    
    # Create a test object
    test_obj = Parse::Object.new({'className' => 'TestObject', 'name' => 'Test Item', 'value' => 42})
    test_obj.save
    
    puts "✓ Created test object: #{test_obj['name']} (ID: #{test_obj.id})"
    
    # Query the object back
    query = Parse::Query.new('TestObject')
    query = query.limit(10)  # Use limit() method instead of limit=
    results = query.results
    puts "✓ Retrieved #{results.count} test objects"
    
    # Test cloud function
    result = Parse.call_function('hello', name: 'Parse Stack')
    puts "✓ Cloud function result: #{result}"
    
    puts "\n✅ All tests passed! Parse Server is working correctly."
    
  rescue => e
    puts "✗ Error during testing: #{e.message}"
    puts e.backtrace.first(3) if ENV['DEBUG']
    exit 1
  end
else
  puts "✗ Parse Server connection failed"
  exit 1
end

puts "\n5. Connection information:"
puts "  Parse Server: http://localhost:1337/parse"
puts "  Parse Dashboard: http://localhost:4040"
puts "  Dashboard login: admin/admin"

puts "\nTo stop the containers, run:"
puts "  docker-compose -f docker-compose.test.yml down"