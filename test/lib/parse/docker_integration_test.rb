require_relative '../../test_helper'
require_relative '../../support/test_server'
require_relative '../../support/docker_helper'

# Define test models for Docker integration testing
class Post < Parse::Object
  property :title, :string
  property :content, :string
  property :view_count, :integer, default: 0
  property :published, :boolean, default: false
  property :published_at, :date
  property :tags, :array
  property :metadata, :object
  belongs_to :author, class_name: 'Author'
  has_many :comments, class_name: 'Comment'
end

class Author < Parse::Object
  property :name, :string
  property :email, :string
  property :bio, :string
  property :profile_image, :file
  property :settings, :object
  has_many :posts, class_name: 'Post', as: :author
end

class Comment < Parse::Object
  property :content, :string
  property :approved, :boolean, default: false
  belongs_to :post, class_name: 'Post'
  belongs_to :author, class_name: 'Author'
end

class DockerTest < Parse::Object
  property :test_field, :string
  property :timestamp, :float
end

class QueryTest < Parse::Object
  property :name, :string
  property :value, :integer
  property :active, :boolean
end

class TestWithHook < Parse::Object
  property :name, :string
end

# Docker-based integration tests that specifically test against a real Parse Server
# running in Docker containers. These tests verify the full stack works correctly.
class DockerIntegrationTest < Minitest::Test

  def setup
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    # Ensure Docker containers are running
    unless Parse::Test::DockerHelper.running?
      unless Parse::Test::DockerHelper.start!
        skip "Unable to start Docker containers for integration testing"
      end
    end

    # Setup Parse client for Docker server
    unless Parse::Test::ServerHelper.setup
      skip "Parse Server is not available for Docker integration testing"
    end

    # Reset database to clean state
    Parse::Test::ServerHelper.reset_database!
  end

  def test_docker_containers_are_running
    assert Parse::Test::DockerHelper.running?, "Docker containers should be running"
    
    # Check individual services
    status = Parse::Test::DockerHelper.status
    assert status.include?('parse-stack-test-mongo'), "MongoDB container should be running"
    assert status.include?('parse-stack-test-server'), "Parse Server container should be running"
    assert status.include?('parse-stack-test-dashboard'), "Parse Dashboard container should be running"
  end

  def test_parse_server_connection
    # Test basic connectivity
    assert Parse::Test::ServerHelper.server_available?, "Parse Server should be accessible"
    
    # Verify client configuration
    client = Parse::Client.client
    assert client.server_url.start_with?('http://localhost:2337/parse'), "Server URL should point to localhost Parse server"
    assert_equal 'myAppId', client.app_id
    assert_equal 'myMasterKey', client.master_key
  end

  def test_mongodb_backend_working
    # Create an object to verify MongoDB is working
    test_obj = DockerTest.new
    test_obj[:test_field] = 'docker_value'
    test_obj[:timestamp] = Time.now.to_f
    
    assert test_obj.save, "Should be able to save object to MongoDB"
    assert test_obj.id.present?, "Saved object should have an ID"
    
    # Query it back to verify persistence
    query = DockerTest.query
    results = query.results
    assert_equal 1, results.count, "Should find the saved object"
    assert_equal 'docker_value', results.first[:test_field]
  end

  def test_master_key_schema_operations
    # Test schema operations that require master key
    schema = Parse.schema('DockerTest')
    assert schema.is_a?(Hash), "Should retrieve schema information"
    
    # Test schemas endpoint (requires master key)
    schemas = Parse.schemas
    assert schemas.is_a?(Array), "Should retrieve all schemas"
    assert schemas.any? { |s| s['className'] == 'DockerTest' }, "Should include our test class"
  end

  def test_cloud_functions_working
    # Test cloud function execution using existing helloName function
    # Pass parameters as a hash in the body parameter
    result = Parse.call_function('helloName', { name: 'Docker' })
    assert_equal 'Hello Docker!', result, "Cloud function with parameters should execute correctly"
    
    # Test cloud function without parameters
    result_no_params = Parse.call_function('helloName', {})
    assert_equal 'Hello World!', result_no_params, "Cloud function with default parameter should execute correctly"
    
    # Test cloud function with session token (non-master key)
    # Create a user to get a session token
    test_user = Parse::Test::ServerHelper.create_test_user(
      username: "cloud_test_user_#{Time.now.to_i}",
      password: 'test_password_123',
      email: "cloudtest#{Time.now.to_i}@test.com"
    )
    
    # Call cloud function with user session
    result_with_session = Parse.call_function_with_session('testFunction', { message: 'session test' }, test_user.session_token)
    assert result_with_session.is_a?(Hash), "Cloud function with session should return hash"
    assert_equal 'This is a test cloud function', result_with_session['message'], "Should execute testFunction correctly"
    assert_equal 'session test', result_with_session['params']['message'], "Should pass parameters correctly"
    assert_equal test_user.username, result_with_session['user'], "Should include authenticated user info"
    
    # Test cloud function with beforeSave hook
    skip "BeforeSave hook test - cloud code hooks may need Parse Server restart to reload"
    
    test_obj = TestWithHook.new
    test_obj[:name] = 'Hook Test'
    
    assert test_obj.save, "Should save object with beforeSave hook"
    # The beforeSave hook in test/cloud/main.js adds a field
    assert_equal true, test_obj['beforeSaveRan'], "beforeSave hook should have executed"
  end

  def test_user_operations
    # Test user creation and authentication
    username = "docker_user_#{Time.now.to_i}"
    password = 'test_password_123'
    email = "#{username}@test.com"
    
    user = Parse::Test::ServerHelper.create_test_user(
      username: username,
      password: password,
      email: email
    )
    
    assert user.id.present?, "User should be created with ID"
    assert_equal username, user.username
    assert_equal email, user.email
    
    # Test user login functionality would go here
    # (Commented out since it may require additional setup)
    # logged_in_user = Parse::User.login(username, password)
    # assert_equal user.id, logged_in_user.id
  end

  def test_query_operations
    # Create test data
    5.times do |i|
      obj = QueryTest.new
      obj[:name] = "Item #{i}"
      obj[:value] = i * 10
      obj[:active] = i.even?
      obj.save
    end
    
    # Test basic query
    query = QueryTest.query
    all_results = query.results
    assert_equal 5, all_results.count
    
    # Test query with constraints
    query = QueryTest.query
    query = query.where(:active => true)
    active_results = query.results
    assert_equal 3, active_results.count, "Should find 3 active items (0, 2, 4)"
    
    # Test query with limit
    query = QueryTest.query
    query = query.limit(2)
    limited_results = query.results
    assert_equal 2, limited_results.count
    
    # Test ordering
    query = QueryTest.query
    query = query.order(:value)
    ordered_results = query.results
    assert_equal 0, ordered_results.first['value']
    assert_equal 40, ordered_results.last['value']
  end

  def test_parse_schema_upgrade
    # Test automatic schema upgrade functionality
    puts "Testing schema upgrade with test models..."
    
    # Clear any existing schemas first
    ['Post', 'Author', 'Comment'].each do |class_name|
      begin
        Parse.client.delete_schema(class_name, use_master_key: true)
      rescue => e
        # Ignore errors if schema doesn't exist
      end
    end
    
    # Perform auto upgrade to create schemas based on model definitions
    Parse.auto_upgrade! do |klass|
      puts "  Upgrading schema for #{klass.parse_class}"
    end
    
    # Verify schemas were created
    schemas = Parse.schemas
    schema_names = schemas.map { |s| s['className'] }
    
    assert_includes schema_names, 'Post', "Post schema should be created"
    assert_includes schema_names, 'Author', "Author schema should be created"
    assert_includes schema_names, 'Comment', "Comment schema should be created"
    
    # Verify field definitions in one of the schemas
    post_schema = Parse.schema('Post')
    assert post_schema.dig('fields', 'title'), "Post schema should have title field"
    assert post_schema.dig('fields', 'content'), "Post schema should have content field"
    assert post_schema.dig('fields', 'viewCount'), "Post schema should have viewCount field"
    assert post_schema.dig('fields', 'published'), "Post schema should have published field"
    
    puts "  ✓ Schema upgrade completed successfully"
  end

  def test_model_relationships_and_data
    # Create test data using the defined models
    user = Author.new(
      name: 'Test Author',
      email: 'author@test.com',
      bio: 'A test author for Docker integration',
      settings: { theme: 'dark', notifications: true }
    )
    assert user.save, "Should be able to save Author"
    
    post = Post.new(
      title: 'Docker Integration Test Post',
      content: 'This is a test post for Docker integration testing.',
      view_count: 42,
      published: true,
      published_at: Time.now,
      tags: ['docker', 'integration', 'test'],
      metadata: { source: 'automated_test', priority: 'high' },
      author: user
    )
    assert post.save, "Should be able to save Post"
    
    comment = Comment.new(
      content: 'Great post about Docker integration!',
      approved: true,
      post: post,
      author: user
    )
    assert comment.save, "Should be able to save Comment"
    
    # Test relationships
    assert_equal user.id, post.author.id, "Post should be linked to author"
    assert_equal post.id, comment.post.id, "Comment should be linked to post"
    
    # Test querying with relationships
    posts_by_user = Post.query(author: user.pointer).results
    assert_equal 1, posts_by_user.count, "Should find one post by the user"
    
    comments_on_post = Comment.query(post: post.pointer).results  
    assert_equal 1, comments_on_post.count, "Should find one comment on the post"
    
    puts "  ✓ Model relationships and data operations work correctly"
  end

  def test_docker_logs_accessibility
    # Verify we can access Docker logs for debugging
    logs = Parse::Test::DockerHelper.logs
    assert logs.is_a?(String), "Should be able to retrieve Docker logs"
    assert logs.length > 0, "Logs should contain content"
  end

  def teardown
    # Clean up any test data but keep containers running
    # The containers will be managed by the test suite lifecycle
  end
end