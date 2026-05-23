require_relative '../../test_helper_integration'

# Test models for latest/last_updated method testing
class TestBlogPost < Parse::Object
  parse_class "TestBlogPost"
  
  property :title, :string
  property :content, :string
  property :category, :string
  property :status, :string, default: "draft"
  property :view_count, :integer, default: 0
end

class LatestLastUpdatedTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_latest_method_returns_most_recent_created_object
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "latest method test") do
        puts "\n=== Testing latest Method (Most Recent Created) ==="

        # Create test objects with small delays to ensure different created_at times
        post1 = TestBlogPost.new(title: "First Post", content: "Content 1", category: "tech")
        assert post1.save, "First post should save"
        
        sleep(0.1) # Small delay
        
        post2 = TestBlogPost.new(title: "Second Post", content: "Content 2", category: "news")
        assert post2.save, "Second post should save"
        
        sleep(0.1) # Small delay
        
        post3 = TestBlogPost.new(title: "Third Post", content: "Content 3", category: "tech")
        assert post3.save, "Third post should save"

        # Test latest() - should return most recently created
        latest_post = TestBlogPost.latest
        assert latest_post, "latest should return an object"
        assert_equal "Third Post", latest_post.title, "latest should return the most recently created post"
        assert_equal post3.id, latest_post.id, "latest should return post3"

        # Test latest(2) - should return 2 most recent
        latest_posts = TestBlogPost.latest(2)
        assert_equal 2, latest_posts.length, "latest(2) should return 2 objects"
        assert_equal "Third Post", latest_posts[0].title, "First item should be most recent"
        assert_equal "Second Post", latest_posts[1].title, "Second item should be second most recent"

        # Test latest with constraints
        latest_tech_post = TestBlogPost.latest(category: "tech")
        assert latest_tech_post, "latest with constraints should return an object"
        assert_equal "Third Post", latest_tech_post.title, "Should return most recent tech post"
        assert_equal "tech", latest_tech_post.category, "Should match category constraint"

        puts "✅ latest method works correctly"
      end
    end
  end

  def test_last_updated_method_returns_most_recent_updated_object
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "last_updated method test") do
        puts "\n=== Testing last_updated Method (Most Recent Updated) ==="

        # Create test objects
        post1 = TestBlogPost.new(title: "Update Test 1", content: "Original content", view_count: 10)
        assert post1.save, "First post should save"
        
        post2 = TestBlogPost.new(title: "Update Test 2", content: "Original content", view_count: 20)
        assert post2.save, "Second post should save"
        
        post3 = TestBlogPost.new(title: "Update Test 3", content: "Original content", view_count: 30)
        assert post3.save, "Third post should save"

        # Update posts in reverse order to test updated_at ordering
        sleep(0.1)
        post1.content = "Updated content 1"
        post1.view_count = 15
        assert post1.save, "Post1 update should save"

        sleep(0.1)
        post3.content = "Updated content 3"
        post3.view_count = 35
        assert post3.save, "Post3 update should save"

        # Test last_updated() - should return post3 (most recently updated)
        last_updated_post = TestBlogPost.last_updated
        assert last_updated_post, "last_updated should return an object"
        assert_equal post3.id, last_updated_post.id, "last_updated should return post3"
        assert_equal "Updated content 3", last_updated_post.content, "Should have updated content"

        # Test last_updated(2) - should return 2 most recently updated
        last_updated_posts = TestBlogPost.last_updated(2)
        assert_equal 2, last_updated_posts.length, "last_updated(2) should return 2 objects"
        assert_equal post3.id, last_updated_posts[0].id, "First should be most recently updated (post3)"
        assert_equal post1.id, last_updated_posts[1].id, "Second should be second most recently updated (post1)"

        # Test last_updated with constraints
        last_updated_high_views = TestBlogPost.last_updated(:view_count.gte => 30)
        assert last_updated_high_views, "last_updated with constraints should return an object"
        assert_equal post3.id, last_updated_high_views.id, "Should return post3 (meets view count constraint)"
        assert last_updated_high_views.view_count >= 30, "Should meet view count constraint"

        puts "✅ last_updated method works correctly"
      end
    end
  end

  def test_latest_and_last_updated_with_empty_collection
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "empty collection test") do
        puts "\n=== Testing latest and last_updated with Empty Collection ==="

        # Test on empty collection
        latest_post = TestBlogPost.latest
        assert_nil latest_post, "latest should return nil for empty collection"

        last_updated_post = TestBlogPost.last_updated
        assert_nil last_updated_post, "last_updated should return nil for empty collection"

        # Test with constraints that don't match
        latest_nonexistent = TestBlogPost.latest(category: "nonexistent")
        assert_nil latest_nonexistent, "latest with non-matching constraints should return nil"

        puts "✅ Empty collection handling works correctly"
      end
    end
  end

  def test_method_consistency_with_first_pattern
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "method consistency test") do
        puts "\n=== Testing Method Consistency with first() Pattern ==="

        # Create test data
        3.times do |i|
          post = TestBlogPost.new(title: "Consistency Test #{i+1}", category: "test")
          assert post.save, "Test post #{i+1} should save"
          sleep(0.1) # Ensure different timestamps
        end

        # Test that methods follow same pattern as first()
        
        # Single object return
        latest_single = TestBlogPost.latest
        assert latest_single.is_a?(TestBlogPost), "latest() should return single object"
        
        last_updated_single = TestBlogPost.last_updated
        assert last_updated_single.is_a?(TestBlogPost), "last_updated() should return single object"
        
        # Multiple objects return
        latest_multiple = TestBlogPost.latest(2)
        assert latest_multiple.is_a?(Array), "latest(n) should return array"
        assert_equal 2, latest_multiple.length, "latest(2) should return exactly 2 items"
        
        last_updated_multiple = TestBlogPost.last_updated(2)
        assert last_updated_multiple.is_a?(Array), "last_updated(n) should return array"
        assert_equal 2, last_updated_multiple.length, "last_updated(2) should return exactly 2 items"

        puts "✅ Method consistency verified"
      end
    end
  end
end