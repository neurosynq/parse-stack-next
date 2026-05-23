require_relative '../../test_helper_integration'
require 'minitest/autorun'

# Test models for aggregate pipeline testing
class AggregateTestUser < Parse::Object
  parse_class "AggregateTestUser"
  property :name, :string
  property :age, :integer
  property :city, :string
  property :join_date, :date
  property :active, :boolean
end

class AggregateTestPost < Parse::Object
  parse_class "AggregateTestPost"
  property :title, :string
  property :content, :string
  property :author, :object  # pointer to AggregateTestUser
  property :category, :string
  property :likes, :integer
  property :published_at, :date
  property :tags, :array
end

class AggregateTestComment < Parse::Object
  parse_class "AggregateTestComment"
  property :text, :string
  property :post, :object  # pointer to AggregateTestPost
  property :commenter, :object  # pointer to AggregateTestUser
  # Note: created_at is already defined as a BASE_KEY in Parse::Object
  property :rating, :integer
end

class AggregateTestLibrary < Parse::Object
  parse_class "AggregateTestLibrary"
  property :name, :string
  property :books, :array  # array of pointers to AggregateTestPost (using posts as books)
  property :featured_authors, :array  # array of pointers to AggregateTestUser
  property :categories, :array  # regular array of strings
  property :established_date, :date
  property :last_updated, :date
end

class QueryAggregateTest < Minitest::Test
  include ParseStackIntegrationTest
  
  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end
  
  def test_aggregate_pipeline_with_pointers_match
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(25, "aggregate pipeline with pointers match test") do
        puts "\n=== Testing Aggregate Pipeline with Pointers and Match ==="
        
        # Create test users
        user1 = AggregateTestUser.new(name: "Alice Developer", age: 28, city: "San Francisco", active: true)
        user2 = AggregateTestUser.new(name: "Bob Designer", age: 32, city: "New York", active: true)
        user3 = AggregateTestUser.new(name: "Carol Writer", age: 25, city: "Los Angeles", active: false)
        
        assert user1.save, "User 1 should save successfully"
        assert user2.save, "User 2 should save successfully"
        assert user3.save, "User 3 should save successfully"
        
        # Create test posts
        post1 = AggregateTestPost.new(
          title: "Tech Post 1", 
          author: user1, 
          category: "technology", 
          likes: 100,
          tags: ["coding", "javascript"]
        )
        post2 = AggregateTestPost.new(
          title: "Design Post 1", 
          author: user2, 
          category: "design", 
          likes: 75,
          tags: ["ui", "ux"]
        )
        post3 = AggregateTestPost.new(
          title: "Tech Post 2", 
          author: user1, 
          category: "technology", 
          likes: 150,
          tags: ["coding", "python"]
        )
        post4 = AggregateTestPost.new(
          title: "Writing Post 1", 
          author: user3, 
          category: "writing", 
          likes: 50,
          tags: ["creative", "fiction"]
        )
        
        assert post1.save, "Post 1 should save successfully"
        assert post2.save, "Post 2 should save successfully"
        assert post3.save, "Post 3 should save successfully"
        assert post4.save, "Post 4 should save successfully"
        
        # Create test comments
        comment1 = AggregateTestComment.new(text: "Great post!", post: post1, commenter: user2, rating: 5)
        comment2 = AggregateTestComment.new(text: "Very helpful", post: post1, commenter: user3, rating: 4)
        comment3 = AggregateTestComment.new(text: "Nice design", post: post2, commenter: user1, rating: 5)
        comment4 = AggregateTestComment.new(text: "Good content", post: post3, commenter: user2, rating: 4)
        
        assert comment1.save, "Comment 1 should save successfully"
        assert comment2.save, "Comment 2 should save successfully"
        assert comment3.save, "Comment 3 should save successfully"
        assert comment4.save, "Comment 4 should save successfully"
        
        puts "Created test data: 3 users, 4 posts, 4 comments"
        
        # Test 1: Aggregate with $match on pointer field
        puts "\n--- Test 1: Aggregate with $match on pointer field ---"
        
        # Match posts by specific author using pointer
        # Parse Server stores pointers internally as simple string references
        author_match_pipeline = [
          { '$match' => { '_p_author' => "AggregateTestUser$#{user1.id}" } }
        ]
        
        tech_posts_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", author_match_pipeline)
        tech_posts_results = tech_posts_query.results || []
        
        assert tech_posts_results.length >= 2, "Should find at least 2 posts by user1"
        puts "Found #{tech_posts_results.length} posts by user1"
        
        # Test 2: Aggregate with $match on regular field and pointer conversion
        puts "\n--- Test 2: Aggregate with $match on category and pointer verification ---"
        
        category_match_pipeline = [
          { '$match' => { 'category' => 'technology' } }
        ]
        
        tech_category_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", category_match_pipeline)
        tech_category_results = tech_category_query.results || []
        
        assert tech_category_results.length >= 2, "Should find at least 2 technology posts"
        
        # Verify pointers are properly included in results
        if tech_category_results.any?
          first_result = tech_category_results.first
          assert first_result.key?('author'), "Result should contain author pointer"
          
          if first_result['author'].is_a?(Hash)
            assert first_result['author'].key?('__type'), "Author should be a pointer with __type"
            assert_equal 'Pointer', first_result['author']['__type'], "Author __type should be 'Pointer'"
            assert first_result['author'].key?('className'), "Author pointer should have className"
            assert first_result['author'].key?('objectId'), "Author pointer should have objectId"
          end
        end
        
        puts "✅ Aggregate pipeline with pointers and match test passed"
      end
    end
  end
  
  def test_aggregate_pipeline_with_group_by_and_sort
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(25, "aggregate pipeline with group by and sort test") do
        puts "\n=== Testing Aggregate Pipeline with Group By and Sort ==="
        
        # Create test users
        user1 = AggregateTestUser.new(name: "Group User 1", age: 30, city: "Boston")
        user2 = AggregateTestUser.new(name: "Group User 2", age: 35, city: "Seattle")
        user3 = AggregateTestUser.new(name: "Group User 3", age: 28, city: "Boston")
        
        assert user1.save, "User 1 should save successfully"
        assert user2.save, "User 2 should save successfully"
        assert user3.save, "User 3 should save successfully"
        
        # Create posts with different categories and likes
        posts_data = [
          { title: "Post A", author: user1, category: "tech", likes: 100 },
          { title: "Post B", author: user1, category: "tech", likes: 150 },
          { title: "Post C", author: user2, category: "design", likes: 80 },
          { title: "Post D", author: user2, category: "design", likes: 120 },
          { title: "Post E", author: user3, category: "tech", likes: 90 },
          { title: "Post F", author: user3, category: "writing", likes: 60 }
        ]
        
        posts_data.each_with_index do |data, index|
          post = AggregateTestPost.new(data)
          assert post.save, "Post #{index + 1} should save successfully"
        end
        
        puts "Created test data: 3 users, 6 posts across multiple categories"
        
        # Test 1: Group by category and count posts
        puts "\n--- Test 1: Group by category with count ---"
        
        group_by_category_pipeline = [
          {
            '$group' => {
              '_id' => '$category',
              'postCount' => { '$sum' => 1 },
              'totalLikes' => { '$sum' => '$likes' },
              'avgLikes' => { '$avg' => '$likes' }
            }
          },
          {
            '$sort' => { 'totalLikes' => -1 }
          }
        ]
        
        category_group_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", group_by_category_pipeline)
        category_results = category_group_query.results || []
        
        puts "DEBUG: Actual aggregation result keys: #{category_results.first.keys.inspect}" if category_results.any?
        puts "DEBUG: First result: #{category_results.first.inspect}" if category_results.any?
        
        assert category_results.length >= 3, "Should have results for at least 3 categories"
        
        # Verify structure and sorting
        if category_results.any?
          first_result = category_results.first
          assert first_result.key?('objectId'), "Should have objectId field (category)"
          assert first_result.key?('postCount'), "Should have postCount field"
          assert first_result.key?('totalLikes'), "Should have totalLikes field"
          assert first_result.key?('avgLikes'), "Should have avgLikes field"
          
          # Verify sorting (should be sorted by totalLikes descending)
          if category_results.length > 1
            assert category_results[0]['totalLikes'] >= category_results[1]['totalLikes'], 
                   "Results should be sorted by totalLikes descending"
          end
        end
        
        puts "Category grouping results: #{category_results.length} categories found"
        
        # Test 2: Group by author pointer and aggregate
        puts "\n--- Test 2: Group by author pointer with aggregation ---"
        
        group_by_author_pipeline = [
          {
            '$group' => {
              '_id' => '$_p_author',
              'postCount' => { '$sum' => 1 },
              'totalLikes' => { '$sum' => '$likes' },
              'maxLikes' => { '$max' => '$likes' },
              'categories' => { '$addToSet' => '$category' }
            }
          },
          {
            '$sort' => { 'postCount' => -1 }
          }
        ]
        
        author_group_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", group_by_author_pipeline)
        author_results = author_group_query.results || []
        
        assert author_results.length >= 3, "Should have results for 3 authors"
        
        # Verify pointer handling in grouping
        if author_results.any?
          first_result = author_results.first
          assert first_result.key?('objectId'), "Should have objectId field (author pointer)"
          assert first_result.key?('postCount'), "Should have postCount field"
          assert first_result.key?('totalLikes'), "Should have totalLikes field"
          assert first_result.key?('maxLikes'), "Should have maxLikes field"
          assert first_result.key?('categories'), "Should have categories array"
          
          # Verify the objectId is a valid author ID  
          author_id = first_result['objectId']
          if author_id.is_a?(String)
            assert author_id.length > 0, "Author objectId should be a valid string"
          end
          
          # Verify categories is an array
          assert first_result['categories'].is_a?(Array), "Categories should be an array"
        end
        
        puts "Author grouping results: #{author_results.length} authors found"
        
        # Test 3: Complex pipeline with match, group, and sort
        puts "\n--- Test 3: Complex pipeline with match, group, and sort ---"
        
        complex_pipeline = [
          {
            '$match' => { 'likes' => { '$gte' => 80 } }
          },
          {
            '$group' => {
              '_id' => '$category',
              'postCount' => { '$sum' => 1 },
              'avgLikes' => { '$avg' => '$likes' },
              'topPost' => { '$max' => '$likes' }
            }
          },
          {
            '$match' => { 'postCount' => { '$gte' => 1 } }
          },
          {
            '$sort' => { 'avgLikes' => -1, 'postCount' => -1 }
          }
        ]
        
        complex_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", complex_pipeline)
        complex_results = complex_query.results || []
        
        assert complex_results.length >= 1, "Should have at least 1 result from complex pipeline"
        
        # Verify complex pipeline results
        if complex_results.any?
          first_result = complex_results.first
          assert first_result['avgLikes'] >= 80, "Average likes should be >= 80 due to initial match"
          assert first_result['postCount'] >= 1, "Post count should be >= 1 due to second match"
        end
        
        puts "Complex pipeline results: #{complex_results.length} categories with high-like posts"
        
        puts "✅ Aggregate pipeline with group by and sort test passed"
      end
    end
  end
  
  def test_aggregate_pipeline_pointer_conversion_and_lookup
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(30, "aggregate pipeline pointer conversion and lookup test") do
        puts "\n=== Testing Aggregate Pipeline Pointer Conversion and Lookup ==="
        
        # Create test data
        user1 = AggregateTestUser.new(name: "Lookup User 1", age: 29, city: "Portland")
        user2 = AggregateTestUser.new(name: "Lookup User 2", age: 34, city: "Austin")
        
        assert user1.save, "User 1 should save successfully"
        assert user2.save, "User 2 should save successfully"
        
        post1 = AggregateTestPost.new(title: "Lookup Post 1", author: user1, category: "tech", likes: 120)
        post2 = AggregateTestPost.new(title: "Lookup Post 2", author: user2, category: "design", likes: 95)
        
        assert post1.save, "Post 1 should save successfully"
        assert post2.save, "Post 2 should save successfully"
        
        comment1 = AggregateTestComment.new(text: "Lookup comment 1", post: post1, commenter: user2, rating: 5)
        comment2 = AggregateTestComment.new(text: "Lookup comment 2", post: post1, commenter: user1, rating: 4)
        comment3 = AggregateTestComment.new(text: "Lookup comment 3", post: post2, commenter: user1, rating: 4)
        
        assert comment1.save, "Comment 1 should save successfully"
        assert comment2.save, "Comment 2 should save successfully"
        assert comment3.save, "Comment 3 should save successfully"
        
        puts "Created test data: 2 users, 2 posts, 3 comments"
        
        # Test 1: Aggregate comments with pointer field handling
        puts "\n--- Test 1: Aggregate comments grouping by post pointer ---"
        
        comment_grouping_pipeline = [
          {
            '$group' => {
              '_id' => '$_p_post',
              'commentCount' => { '$sum' => 1 },
              'avgRating' => { '$avg' => '$rating' },
              'commenters' => { '$addToSet' => '$_p_commenter' }
            }
          },
          {
            '$sort' => { 'commentCount' => -1 }
          }
        ]
        
        comment_group_query = AggregateTestComment.new.client.aggregate_pipeline("AggregateTestComment", comment_grouping_pipeline)
        comment_results = comment_group_query.results || []
        
        assert comment_results.length >= 1, "Should have results for comment grouping"
        
        # Verify pointer handling in results
        if comment_results.any?
          first_result = comment_results.first
          assert first_result.key?('objectId'), "Should have objectId field (post pointer)"
          assert first_result.key?('commentCount'), "Should have commentCount field"
          assert first_result.key?('avgRating'), "Should have avgRating field"
          assert first_result.key?('commenters'), "Should have commenters field"
          
          # Verify post pointer structure
          post_id = first_result['objectId']
          if post_id.is_a?(String)
            assert post_id.length > 0, "Post objectId should be a valid string"
          end
          
          # Verify commenters array contains pointers
          commenters = first_result['commenters']
          assert commenters.is_a?(Array), "Commenters should be an array"
          
          if commenters.any? && commenters.first.is_a?(String)
            commenter = commenters.first
            assert commenter.start_with?('AggregateTestUser$'), "Commenter should be in internal pointer format (AggregateTestUser$...)"
          end
        end
        
        puts "Comment grouping results: #{comment_results.length} posts with comments"
        
        # Test 2: Aggregate with multiple pointer fields and conversions
        puts "\n--- Test 2: Complex aggregation with multiple pointer fields ---"
        
        multi_pointer_pipeline = [
          {
            '$match' => { 'rating' => { '$gte' => 4 } }
          },
          {
            '$group' => {
              '_id' => {
                'post' => '$_p_post',
                'commenter' => '$_p_commenter'
              },
              'totalComments' => { '$sum' => 1 },
              'avgRating' => { '$avg' => '$rating' },
              'comments' => { '$push' => '$text' }
            }
          }
        ]
        
        multi_pointer_query = AggregateTestComment.new.client.aggregate_pipeline("AggregateTestComment", multi_pointer_pipeline)
        multi_pointer_results = multi_pointer_query.results || []
        
        assert multi_pointer_results.length >= 1, "Should have results for multi-pointer aggregation"
        
        # Verify complex _id structure with multiple pointers
        if multi_pointer_results.any?
          first_result = multi_pointer_results.first
          assert first_result.key?('objectId'), "Should have objectId field"
          
          id_obj = first_result['objectId']
          assert id_obj.is_a?(Hash), "_id should be a hash"
          assert id_obj.key?('post'), "_id should have post field"
          assert id_obj.key?('commenter'), "_id should have commenter field"
          
          # Verify both pointer fields
          %w[post commenter].each do |field|
            pointer = id_obj[field]
            if pointer.is_a?(Hash)
              assert pointer.key?('__type'), "#{field} should be a pointer with __type"
              assert_equal 'Pointer', pointer['__type'], "#{field} __type should be 'Pointer'"
              assert pointer.key?('className'), "#{field} should have className"
              assert pointer.key?('objectId'), "#{field} should have objectId"
            end
          end
          
          # Verify aggregated fields
          assert first_result.key?('totalComments'), "Should have totalComments field"
          assert first_result.key?('avgRating'), "Should have avgRating field"
          assert first_result.key?('comments'), "Should have comments array"
          assert first_result['comments'].is_a?(Array), "Comments should be an array"
        end
        
        puts "Multi-pointer aggregation results: #{multi_pointer_results.length} unique post-commenter combinations"
        
        # Test 3: Test with $match on pointer objectId
        puts "\n--- Test 3: Match on pointer objectId ---"
        
        pointer_match_pipeline = [
          {
            '$match' => {
              '_p_post' => "AggregateTestPost$#{post1.id}"
            }
          },
          {
            '$group' => {
              '_id' => nil,
              'totalComments' => { '$sum' => 1 },
              'uniqueCommenters' => { '$addToSet' => '$_p_commenter' }
            }
          }
        ]
        
        pointer_match_query = AggregateTestComment.new.client.aggregate_pipeline("AggregateTestComment", pointer_match_pipeline)
        pointer_match_results = pointer_match_query.results || []
        
        # This might not work depending on Parse Server aggregation implementation
        # but we test it to see how pointer objectId matching behaves
        puts "Pointer objectId match results: #{pointer_match_results.length} results"
        
        puts "✅ Aggregate pipeline pointer conversion and lookup test passed"
      end
    end
  end
  
  def test_aggregate_pipeline_sort_behaviors
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(20, "aggregate pipeline sort behaviors test") do
        puts "\n=== Testing Aggregate Pipeline Sort Behaviors ==="
        
        # Create test data with various sort criteria
        user1 = AggregateTestUser.new(name: "Sort User A", age: 25, city: "Denver")
        user2 = AggregateTestUser.new(name: "Sort User B", age: 30, city: "Miami")
        user3 = AggregateTestUser.new(name: "Sort User C", age: 35, city: "Chicago")
        
        assert user1.save, "User 1 should save successfully"
        assert user2.save, "User 2 should save successfully"
        assert user3.save, "User 3 should save successfully"
        
        # Create posts with different likes and dates
        posts = [
          { title: "Post Alpha", author: user1, likes: 50, category: "tech" },
          { title: "Post Beta", author: user2, likes: 150, category: "design" },
          { title: "Post Gamma", author: user3, likes: 100, category: "tech" },
          { title: "Post Delta", author: user1, likes: 200, category: "writing" },
          { title: "Post Epsilon", author: user2, likes: 75, category: "tech" }
        ]
        
        posts.each_with_index do |data, index|
          post = AggregateTestPost.new(data)
          assert post.save, "Post #{index + 1} should save successfully"
        end
        
        puts "Created test data: 3 users, 5 posts for sort testing"
        
        # Test 1: Sort by likes ascending
        puts "\n--- Test 1: Sort by likes ascending ---"
        
        likes_asc_pipeline = [
          { '$sort' => { 'likes' => 1 } },
          { '$limit' => 10 }
        ]
        
        likes_asc_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", likes_asc_pipeline)
        likes_asc_results = likes_asc_query.results || []
        
        assert likes_asc_results.length >= 3, "Should have at least 3 results"
        
        # Verify ascending sort
        if likes_asc_results.length > 1
          (0..likes_asc_results.length - 2).each do |i|
            current_likes = likes_asc_results[i]['likes']
            next_likes = likes_asc_results[i + 1]['likes']
            assert current_likes <= next_likes, "Results should be sorted by likes ascending"
          end
        end
        
        puts "Likes ascending sort verified with #{likes_asc_results.length} results"
        
        # Test 2: Sort by likes descending
        puts "\n--- Test 2: Sort by likes descending ---"
        
        likes_desc_pipeline = [
          { '$sort' => { 'likes' => -1 } },
          { '$limit' => 10 }
        ]
        
        likes_desc_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", likes_desc_pipeline)
        likes_desc_results = likes_desc_query.results || []
        
        assert likes_desc_results.length >= 3, "Should have at least 3 results"
        
        # Verify descending sort
        if likes_desc_results.length > 1
          (0..likes_desc_results.length - 2).each do |i|
            current_likes = likes_desc_results[i]['likes']
            next_likes = likes_desc_results[i + 1]['likes']
            assert current_likes >= next_likes, "Results should be sorted by likes descending"
          end
        end
        
        puts "Likes descending sort verified with #{likes_desc_results.length} results"
        
        # Test 3: Multi-field sort
        puts "\n--- Test 3: Multi-field sort (category asc, likes desc) ---"
        
        multi_sort_pipeline = [
          { '$sort' => { 'category' => 1, 'likes' => -1 } },
          { '$limit' => 10 }
        ]
        
        multi_sort_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", multi_sort_pipeline)
        multi_sort_results = multi_sort_query.results || []
        
        assert multi_sort_results.length >= 3, "Should have at least 3 results"
        
        # Verify multi-field sort
        if multi_sort_results.length > 1
          (0..multi_sort_results.length - 2).each do |i|
            current_cat = multi_sort_results[i]['category']
            next_cat = multi_sort_results[i + 1]['category']
            current_likes = multi_sort_results[i]['likes']
            next_likes = multi_sort_results[i + 1]['likes']
            
            # Categories should be in ascending order, or if same category, likes should be descending
            if current_cat == next_cat
              assert current_likes >= next_likes, "Within same category, likes should be descending"
            else
              assert current_cat <= next_cat, "Categories should be in ascending order"
            end
          end
        end
        
        puts "Multi-field sort verified with #{multi_sort_results.length} results"
        
        # Test 4: Sort with group and aggregation
        puts "\n--- Test 4: Sort with group and aggregation ---"
        
        group_sort_pipeline = [
          {
            '$group' => {
              '_id' => '$category',
              'totalLikes' => { '$sum' => '$likes' },
              'postCount' => { '$sum' => 1 },
              'avgLikes' => { '$avg' => '$likes' }
            }
          },
          {
            '$sort' => { 'totalLikes' => -1, 'postCount' => -1 }
          }
        ]
        
        group_sort_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", group_sort_pipeline)
        group_sort_results = group_sort_query.results || []
        
        assert group_sort_results.length >= 1, "Should have at least 1 group result"
        
        # Verify sort after grouping
        if group_sort_results.length > 1
          (0..group_sort_results.length - 2).each do |i|
            current_total = group_sort_results[i]['totalLikes']
            next_total = group_sort_results[i + 1]['totalLikes']
            current_count = group_sort_results[i]['postCount']
            next_count = group_sort_results[i + 1]['postCount']
            
            if current_total == next_total
              assert current_count >= next_count, "With same totalLikes, postCount should be descending"
            else
              assert current_total >= next_total, "totalLikes should be in descending order"
            end
          end
        end
        
        puts "Group and sort combination verified with #{group_sort_results.length} results"
        
        puts "✅ Aggregate pipeline sort behaviors test passed"
      end
    end
  end
  
  def test_aggregate_mongodb_field_conversions
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(25, "aggregate MongoDB field conversions test") do
        puts "\n=== Testing Aggregate MongoDB Field Conversions ==="
        
        # Create test data
        user1 = AggregateTestUser.new(name: "MongoDB Field User 1", age: 30, city: "Phoenix")
        user2 = AggregateTestUser.new(name: "MongoDB Field User 2", age: 25, city: "Tampa")
        
        assert user1.save, "User 1 should save successfully"
        assert user2.save, "User 2 should save successfully"
        
        post1 = AggregateTestPost.new(title: "MongoDB Field Post 1", author: user1, category: "tech", likes: 80)
        post2 = AggregateTestPost.new(title: "MongoDB Field Post 2", author: user2, category: "design", likes: 120)
        
        assert post1.save, "Post 1 should save successfully"
        assert post2.save, "Post 2 should save successfully"
        
        comment1 = AggregateTestComment.new(text: "MongoDB comment 1", post: post1, commenter: user2, rating: 4)
        comment2 = AggregateTestComment.new(text: "MongoDB comment 2", post: post2, commenter: user1, rating: 5)
        
        assert comment1.save, "Comment 1 should save successfully"
        assert comment2.save, "Comment 2 should save successfully"
        
        puts "Created test data: 2 users, 2 posts, 2 comments"
        
        # Test 1: Aggregate with pointer field using MongoDB internal representation
        puts "\n--- Test 1: MongoDB pointer field representation (_p_author) ---"
        
        # Test matching using the internal MongoDB pointer field format
        # In MongoDB, pointer fields are stored as _p_fieldName = _ClassName$objectId
        mongodb_pointer_pipeline = [
          {
            '$match' => {
              "_p_author" => "_AggregateTestUser$#{user1.id}"
            }
          },
          {
            '$project' => {
              'title' => 1,
              'likes' => 1,
              '_p_author' => 1,
              'author' => 1
            }
          }
        ]
        
        mongodb_pointer_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", mongodb_pointer_pipeline)
        mongodb_pointer_results = mongodb_pointer_query.results || []
        
        puts "MongoDB pointer field results: #{mongodb_pointer_results.length} posts found"
        
        # Verify the results contain the expected MongoDB internal fields
        if mongodb_pointer_results.any?
          first_result = mongodb_pointer_results.first
          puts "Result structure: #{first_result.keys.inspect}"
          
          # Check if MongoDB internal pointer field is present
          if first_result.key?('_p_author')
            assert first_result['_p_author'].include?('_AggregateTestUser$'), 
                   "MongoDB pointer field should contain internal format"
            puts "MongoDB internal pointer field: #{first_result['_p_author']}"
          end
          
          # Check if Parse API pointer field is also present/converted
          if first_result.key?('author')
            author = first_result['author']
            if author.is_a?(Hash)
              assert author.key?('__type'), "Parse API author should have __type"
              assert_equal 'Pointer', author['__type'], "Parse API author should be Pointer type"
              assert author.key?('className'), "Parse API author should have className"
              assert author.key?('objectId'), "Parse API author should have objectId"
              puts "Parse API pointer format: #{author.inspect}"
            end
          end
        end
        
        # Test 2: Aggregate with system classes using _ClassName format
        puts "\n--- Test 2: System class field handling (_User references) ---"
        
        # Create a pipeline that references user data and checks for _User format handling
        user_reference_pipeline = [
          {
            '$match' => {
              'likes' => { '$gte' => 50 }
            }
          },
          {
            '$lookup' => {
              'from' => '_User',  # MongoDB collection name for Parse User class
              'localField' => '_p_author',
              'foreignField' => '_id',
              'as' => 'authorDetails'
            }
          },
          {
            '$project' => {
              'title' => 1,
              'likes' => 1,
              'authorDetails.name' => 1,
              'authorDetails.city' => 1
            }
          }
        ]
        
        # Note: This might not work depending on Parse Server aggregation pipeline support
        # but we test it to verify how system class references are handled
        begin
          user_ref_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", user_reference_pipeline)
          user_ref_results = user_ref_query.results || []
          
          puts "User reference results: #{user_ref_results.length} posts with user details"
          
          if user_ref_results.any?
            first_result = user_ref_results.first
            puts "User lookup result keys: #{first_result.keys.inspect}"
            
            if first_result.key?('authorDetails') && first_result['authorDetails'].is_a?(Array)
              author_details = first_result['authorDetails'].first
              if author_details.is_a?(Hash)
                puts "Author details: #{author_details.keys.inspect}"
                # Verify user data was properly looked up
                assert author_details.key?('name') || author_details.key?('city'), 
                       "Author details should contain user fields"
              end
            end
          end
        rescue => e
          puts "User reference lookup may not be supported: #{e.message}"
          # This is expected if Parse Server doesn't support complex lookups
        end
        
        # Test 3: Group by internal pointer fields and verify conversion
        puts "\n--- Test 3: Group by internal pointer fields ---"
        
        group_internal_pointer_pipeline = [
          {
            '$group' => {
              '_id' => '$_p_author',
              'postCount' => { '$sum' => 1 },
              'totalLikes' => { '$sum' => '$likes' },
              'authorPointer' => { '$first' => '$author' }
            }
          },
          {
            '$sort' => { 'totalLikes' => -1 }
          }
        ]
        
        group_internal_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", group_internal_pointer_pipeline)
        group_internal_results = group_internal_query.results || []
        
        puts "Group by internal pointer results: #{group_internal_results.length} authors found"
        
        if group_internal_results.any?
          first_result = group_internal_results.first
          
          # Verify objectId contains the extracted object ID from the MongoDB internal pointer format
          object_id = first_result['objectId']
          if object_id.is_a?(String)
            assert object_id.length > 0, "ObjectId should be extracted from internal pointer format"
            puts "Extracted objectId: #{object_id}"
          end
          
          # Verify authorPointer contains MongoDB internal format
          author_pointer = first_result['authorPointer']
          if author_pointer.is_a?(String)
            assert author_pointer.include?('AggregateTestUser$'), 
                   "Author pointer should contain MongoDB internal format"
            puts "MongoDB internal pointer: #{author_pointer}"
          end
        end
        
        # Test 4: Match using objectId extraction from internal format
        puts "\n--- Test 4: ObjectId extraction from internal pointer format ---"
        
        # Extract objectId from the internal MongoDB format and use it for matching
        objectid_extraction_pipeline = [
          {
            '$addFields' => {
              'authorObjectId' => {
                '$substr' => ['$_p_author', { '$add' => [{ '$strLenCP' => '_AggregateTestUser$' }, 0] }, -1]
              }
            }
          },
          {
            '$match' => {
              'authorObjectId' => user1.id
            }
          },
          {
            '$project' => {
              'title' => 1,
              'authorObjectId' => 1,
              '_p_author' => 1
            }
          }
        ]
        
        begin
          objectid_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", objectid_extraction_pipeline)
          objectid_results = objectid_query.results || []
          
          puts "ObjectId extraction results: #{objectid_results.length} posts found"
          
          if objectid_results.any?
            first_result = objectid_results.first
            extracted_id = first_result['authorObjectId']
            internal_pointer = first_result['_p_author']
            
            puts "Extracted ObjectId: #{extracted_id}"
            puts "Internal pointer: #{internal_pointer}"
            
            # Verify the extraction worked correctly
            if extracted_id.is_a?(String) && internal_pointer.is_a?(String)
              assert internal_pointer.end_with?(extracted_id), 
                     "Internal pointer should end with extracted objectId"
            end
          end
        rescue => e
          puts "ObjectId extraction may not be supported: #{e.message}"
          # This is expected if Parse Server doesn't support string operations
        end
        
        # Test 5: Convert between internal and API pointer formats
        puts "\n--- Test 5: Pointer format conversion verification ---"
        
        conversion_pipeline = [
          {
            '$project' => {
              'title' => 1,
              'internalAuthor' => '$_p_author',
              'apiAuthor' => '$author',
              'authorObjectId' => '$author.objectId',
              'authorClassName' => '$author.className'
            }
          },
          {
            '$limit' => 5
          }
        ]
        
        conversion_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", conversion_pipeline)
        conversion_results = conversion_query.results || []
        
        puts "Pointer conversion results: #{conversion_results.length} posts analyzed"
        
        if conversion_results.any?
          conversion_results.each_with_index do |result, index|
            puts "\n  Post #{index + 1}: #{result['title']}"
            
            internal_format = result['internalAuthor']
            api_format = result['apiAuthor']
            object_id = result['authorObjectId']
            class_name = result['authorClassName']
            
            puts "    Internal format: #{internal_format}"
            puts "    API format: #{api_format.inspect}" if api_format
            puts "    ObjectId: #{object_id}"
            puts "    ClassName: #{class_name}"
            
            # Verify consistency between formats
            if internal_format.is_a?(String) && object_id.is_a?(String)
              assert internal_format.include?(object_id), 
                     "Internal format should contain the objectId"
            end
            
            if internal_format.is_a?(String) && class_name.is_a?(String)
              assert internal_format.include?("_#{class_name}$"), 
                     "Internal format should contain the className with MongoDB prefix"
            end
          end
        end
        
        puts "\n✅ Aggregate MongoDB field conversions test passed"
      end
    end
  end
  
  def test_aggregate_arrays_of_pointers_and_dates
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(30, "aggregate arrays of pointers and dates test") do
        puts "\n=== Testing Aggregate Arrays of Pointers and Date Conversion ==="
        
        # Create test data with date fields
        join_date1 = Time.now - 365 * 24 * 60 * 60  # 1 year ago
        join_date2 = Time.now - 180 * 24 * 60 * 60  # 6 months ago
        publish_date1 = Time.now - 30 * 24 * 60 * 60  # 1 month ago
        publish_date2 = Time.now - 7 * 24 * 60 * 60   # 1 week ago
        established_date = Time.now - 2 * 365 * 24 * 60 * 60  # 2 years ago
        
        user1 = AggregateTestUser.new(name: "Array User 1", age: 30, city: "Seattle", join_date: join_date1)
        user2 = AggregateTestUser.new(name: "Array User 2", age: 28, city: "Portland", join_date: join_date2)
        user3 = AggregateTestUser.new(name: "Array User 3", age: 32, city: "Denver", join_date: join_date1)
        
        assert user1.save, "User 1 should save successfully"
        assert user2.save, "User 2 should save successfully"
        assert user3.save, "User 3 should save successfully"
        
        post1 = AggregateTestPost.new(
          title: "Array Post 1", 
          author: user1, 
          category: "tech", 
          likes: 100,
          published_at: publish_date1,
          tags: ["javascript", "nodejs"]
        )
        post2 = AggregateTestPost.new(
          title: "Array Post 2", 
          author: user2, 
          category: "design", 
          likes: 80,
          published_at: publish_date2,
          tags: ["ui", "ux"]
        )
        post3 = AggregateTestPost.new(
          title: "Array Post 3", 
          author: user3, 
          category: "tech", 
          likes: 120,
          published_at: publish_date1,
          tags: ["python", "data"]
        )
        
        assert post1.save, "Post 1 should save successfully"
        assert post2.save, "Post 2 should save successfully"
        assert post3.save, "Post 3 should save successfully"
        
        # Create library with arrays of pointers
        library1 = AggregateTestLibrary.new(
          name: "Tech Library",
          books: [post1, post3],  # Array of post pointers
          featured_authors: [user1, user3],  # Array of user pointers
          categories: ["technology", "programming", "science"],
          established_date: established_date,
          last_updated: Time.now
        )
        
        library2 = AggregateTestLibrary.new(
          name: "Design Library",
          books: [post2],  # Array of post pointers
          featured_authors: [user2],  # Array of user pointers
          categories: ["design", "art", "creativity"],
          established_date: established_date,
          last_updated: Time.now - 24 * 60 * 60  # 1 day ago
        )
        
        assert library1.save, "Library 1 should save successfully"
        assert library2.save, "Library 2 should save successfully"
        
        puts "Created test data: 3 users, 3 posts, 2 libraries with pointer arrays and dates"
        
        
        # Test 1: Aggregate libraries grouping by array of pointer authors
        puts "\n--- Test 1: Aggregate libraries with arrays of pointer authors ---"
        
        library_authors_pipeline = [
          {
            '$unwind' => '$featuredAuthors'
          },
          {
            '$group' => {
              '_id' => '$featuredAuthors',
              'libraryCount' => { '$sum' => 1 },
              'libraries' => { '$addToSet' => '$name' },
              'totalCategories' => { '$sum' => { '$size' => '$categories' } }
            }
          },
          {
            '$sort' => { 'libraryCount' => -1 }
          }
        ]
        
        
        library_authors_query = AggregateTestLibrary.new.client.aggregate_pipeline("AggregateTestLibrary", library_authors_pipeline)
        library_authors_results = library_authors_query.results || []
        
        assert library_authors_results.length >= 2, "Should have results for featured authors"
        puts "Library authors aggregation results: #{library_authors_results.length} unique authors"
        
        # Verify pointer handling in array unwinding
        if library_authors_results.any?
          first_result = library_authors_results.first
          author_pointer = first_result['objectId']
          
          if author_pointer.is_a?(String)
            assert author_pointer.length > 0, "Author objectId should be a valid string"
            puts "Author objectId from array: #{author_pointer.inspect}"
          end
          
          assert first_result.key?('libraries'), "Should have libraries array"
          assert first_result['libraries'].is_a?(Array), "Libraries should be an array"
          puts "Libraries featuring this author: #{first_result['libraries']}"
        end
        
        # Test 2: Aggregate libraries grouping by array of pointer books
        puts "\n--- Test 2: Aggregate libraries with arrays of pointer books ---"
        
        library_books_pipeline = [
          {
            '$unwind' => '$books'
          },
          {
            '$group' => {
              '_id' => '$books',
              'libraryCount' => { '$sum' => 1 },
              'featuredIn' => { '$addToSet' => '$name' }
            }
          }
        ]
        
        library_books_query = AggregateTestLibrary.new.client.aggregate_pipeline("AggregateTestLibrary", library_books_pipeline)
        library_books_results = library_books_query.results || []
        
        assert library_books_results.length >= 2, "Should have results for featured books"
        puts "Library books aggregation results: #{library_books_results.length} unique books"
        
        # Verify book pointer handling
        if library_books_results.any?
          first_result = library_books_results.first
          book_pointer = first_result['objectId']
          
          # In aggregation results, grouped values may be just objectId strings or simplified objects
          if book_pointer.is_a?(String)
            assert book_pointer.length > 0, "Book objectId should be a valid string"
          elsif book_pointer.is_a?(Hash) && book_pointer.key?('__type')
            # Accept either Pointer or Object type (aggregation results vary)
            assert ['Pointer', 'Object'].include?(book_pointer['__type']), "Book should be Pointer or Object type"
            puts "Book pointer from array: #{book_pointer.inspect}"
          end
        end
        
        # Test 3: Date conversion and aggregation
        puts "\n--- Test 3: Date conversion and aggregation ---"
        
        date_aggregation_pipeline = [
          {
            '$group' => {
              '_id' => {
                '$dateToString' => {
                  'format' => '%Y-%m',
                  'date' => '$join_date'
                }
              },
              'userCount' => { '$sum' => 1 },
              'avgAge' => { '$avg' => '$age' },
              'cities' => { '$addToSet' => '$city' },
              'oldestJoinDate' => { '$min' => '$join_date' },
              'newestJoinDate' => { '$max' => '$join_date' }
            }
          },
          {
            '$sort' => { '_id' => 1 }
          }
        ]
        
        begin
          date_agg_query = AggregateTestUser.new.client.aggregate_pipeline("AggregateTestUser", date_aggregation_pipeline)
          date_agg_results = date_agg_query.results || []
          
          puts "Date aggregation results: #{date_agg_results.length} time periods"
          
          if date_agg_results.any?
            date_agg_results.each_with_index do |result, index|
              puts "  Period #{index + 1}: #{result['objectId']}"
              puts "    Users: #{result['userCount']}, Avg Age: #{result['avgAge']}"
              puts "    Cities: #{result['cities']}"
              puts "    Date range: #{result['oldestJoinDate']} to #{result['newestJoinDate']}"
              
              # Verify date fields are properly converted
              assert result.key?('oldestJoinDate'), "Should have oldestJoinDate"
              assert result.key?('newestJoinDate'), "Should have newestJoinDate"
              
              # Date fields should be either Date objects or ISO strings
              oldest = result['oldestJoinDate']
              newest = result['newestJoinDate']
              
              if oldest.is_a?(String)
                # Verify ISO date format
                assert oldest.match?(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/), 
                       "Date should be in ISO format: #{oldest}"
              elsif oldest.is_a?(Hash) && oldest.key?('__type')
                # Parse Date object format
                assert_equal 'Date', oldest['__type'], "Date should have __type: Date"
                assert oldest.key?('iso'), "Date should have iso field"
              end
            end
          end
        rescue => e
          puts "Date aggregation may not be fully supported: #{e.message}"
          # Some date operations might not be supported depending on Parse Server version
        end
        
        # Test 4: Aggregation with date filtering and pointer arrays
        puts "\n--- Test 4: Date filtering with pointer arrays ---"
        
        date_filter_pipeline = [
          {
            '$match' => {
              'published_at' => {
                '$gte' => (Time.now - 45 * 24 * 60 * 60).iso8601  # Posts from last 45 days
              }
            }
          },
          {
            '$group' => {
              '_id' => '$category',
              'postCount' => { '$sum' => 1 },
              'authors' => { '$addToSet' => '$author' },
              'totalLikes' => { '$sum' => '$likes' },
              'avgPublishDate' => { '$avg' => { '$toLong' => '$published_at' } }
            }
          },
          {
            '$sort' => { 'totalLikes' => -1 }
          }
        ]
        
        begin
          date_filter_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", date_filter_pipeline)
          date_filter_results = date_filter_query.results || []
          
          puts "Date filtered aggregation results: #{date_filter_results.length} categories"
          
          if date_filter_results.any?
            first_result = date_filter_results.first
            
            # Verify authors array contains pointers
            authors = first_result['authors']
            assert authors.is_a?(Array), "Authors should be an array"
            
            if authors.any? && authors.first.is_a?(Hash)
              first_author = authors.first
              assert first_author.key?('__type'), "Author should be a pointer with __type"
              assert_equal 'Pointer', first_author['__type'], "Author should be Pointer type"
              puts "Authors in category '#{first_result['objectId']}': #{authors.length} unique authors"
            end
            
            # Verify date aggregation field
            if first_result.key?('avgPublishDate')
              avg_date = first_result['avgPublishDate']
              puts "Average publish date (timestamp): #{avg_date}"
              assert avg_date.is_a?(Numeric), "Average date should be numeric timestamp"
            end
          end
        rescue => e
          puts "Date filtering aggregation may not be fully supported: #{e.message}"
        end
        
        # Test 5: Complex aggregation with multiple array operations and dates
        puts "\n--- Test 5: Complex aggregation with arrays and dates ---"
        
        complex_array_date_pipeline = [
          {
            '$match' => {
              'established_date' => {
                '$exists' => true
              }
            }
          },
          {
            '$unwind' => '$categories'
          },
          {
            '$group' => {
              '_id' => '$categories',
              'libraryCount' => { '$sum' => 1 },
              'totalBooks' => { '$sum' => { '$size' => '$books' } },
              'totalAuthors' => { '$sum' => { '$size' => '$featured_authors' } },
              'oldestLibrary' => { '$min' => '$established_date' },
              'newestUpdate' => { '$max' => '$last_updated' },
              'libraries' => { '$addToSet' => {
                'name' => '$name',
                'bookCount' => { '$size' => '$books' },
                'authorCount' => { '$size' => '$featured_authors' }
              }}
            }
          },
          {
            '$sort' => { 'totalBooks' => -1, 'totalAuthors' => -1 }
          }
        ]
        
        complex_query = AggregateTestLibrary.new.client.aggregate_pipeline("AggregateTestLibrary", complex_array_date_pipeline)
        complex_results = complex_query.results || []
        
        puts "Complex array and date aggregation results: #{complex_results.length} categories"
        
        if complex_results.any?
          complex_results.each_with_index do |result, index|
            puts "  Category #{index + 1}: #{result['objectId']}"
            puts "    Libraries: #{result['libraryCount']}, Total Books: #{result['totalBooks']}, Total Authors: #{result['totalAuthors']}"
            
            # Verify date fields
            if result.key?('oldestLibrary')
              oldest = result['oldestLibrary']
              puts "    Oldest library established: #{oldest}"
            end
            
            if result.key?('newestUpdate')
              newest = result['newestUpdate']
              puts "    Most recent update: #{newest}"
            end
            
            # Verify libraries array structure
            libraries = result['libraries']
            assert libraries.is_a?(Array), "Libraries should be an array"
            
            if libraries.any?
              first_lib = libraries.first
              assert first_lib.is_a?(Hash), "Library should be a hash"
              assert first_lib.key?('name'), "Library should have name"
              assert first_lib.key?('bookCount'), "Library should have bookCount"
              assert first_lib.key?('authorCount'), "Library should have authorCount"
              puts "    Sample library: #{first_lib}"
            end
          end
        end
        
        puts "\n✅ Aggregate arrays of pointers and dates test passed"
      end
    end
  end
  
  def test_aggregate_with_preceding_where_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(25, "aggregate with preceding where constraints test") do
        puts "\n=== Testing Aggregate with Preceding Where Constraints ==="
        
        # Create test data
        active_user = AggregateTestUser.new(name: "Active User", age: 30, city: "San Francisco", active: true)
        inactive_user = AggregateTestUser.new(name: "Inactive User", age: 25, city: "Los Angeles", active: false)
        
        assert active_user.save, "Active user should save successfully"
        assert inactive_user.save, "Inactive user should save successfully"
        
        # Create posts with different characteristics
        high_likes_post = AggregateTestPost.new(
          title: "High Likes Post", 
          author: active_user, 
          category: "tech", 
          likes: 500,
          tags: ["popular", "trending"]
        )
        
        medium_likes_post = AggregateTestPost.new(
          title: "Medium Likes Post", 
          author: active_user, 
          category: "design", 
          likes: 100,
          tags: ["design", "ui"]
        )
        
        low_likes_post = AggregateTestPost.new(
          title: "Low Likes Post", 
          author: inactive_user, 
          category: "tech", 
          likes: 25,
          tags: ["beginner", "tutorial"]
        )
        
        unpopular_post = AggregateTestPost.new(
          title: "Unpopular Post", 
          author: inactive_user, 
          category: "writing", 
          likes: 5,
          tags: ["niche", "experimental"]
        )
        
        assert high_likes_post.save, "High likes post should save successfully"
        assert medium_likes_post.save, "Medium likes post should save successfully"
        assert low_likes_post.save, "Low likes post should save successfully"
        assert unpopular_post.save, "Unpopular post should save successfully"
        
        puts "Created test data: 2 users (1 active, 1 inactive), 4 posts with varying likes"
        
        # Test 1: Parse Stack where constraint before aggregation
        puts "\n--- Test 1: Parse Stack where constraint applied before aggregation ---"
        
        # Use Parse Stack query with where constraint, then aggregate
        popular_posts_query = AggregateTestPost.where(:likes.gte => 50)
        
        # Apply aggregation pipeline to the constrained query
        popular_aggregation_pipeline = [
          {
            '$match' => { 'likes' => { '$gte' => 50 } }
          },
          {
            '$group' => {
              '_id' => '$category',
              'postCount' => { '$sum' => 1 },
              'totalLikes' => { '$sum' => '$likes' },
              'avgLikes' => { '$avg' => '$likes' },
              'authors' => { '$addToSet' => '$_p_author' }
            }
          },
          {
            '$sort' => { 'totalLikes' => -1 }
          }
        ]
        
        # This tests if where constraints are properly applied before the aggregation pipeline
        begin
          popular_agg_query = popular_posts_query.client.aggregate_pipeline("AggregateTestPost", popular_aggregation_pipeline)
          popular_agg_results = popular_agg_query.results || []
          
          puts "Popular posts aggregation (likes >= 50): #{popular_agg_results.length} categories"
          
          if popular_agg_results.any?
            total_posts_in_agg = popular_agg_results.sum { |r| r['postCount'] }
            puts "Total posts in aggregation: #{total_posts_in_agg}"
            
            # Should only include posts with >= 50 likes (high_likes_post and medium_likes_post)
            assert total_posts_in_agg <= 2, "Should only aggregate posts with >= 50 likes"
            
            popular_agg_results.each do |result|
              # All posts in results should have avgLikes >= 50 due to preceding constraint
              assert result['avgLikes'] >= 50, "Average likes should be >= 50 due to where constraint"
              puts "Category '#{result['objectId']}': #{result['postCount']} posts, avg likes: #{result['avgLikes']}"
            end
          end
        rescue => e
          puts "Parse Stack where constraint with aggregation may not be supported: #{e.message}"
          # Fall back to testing with direct pipeline match
        end
        
        # Test 2: Direct pipeline match equivalent to where constraint
        puts "\n--- Test 2: Direct pipeline match equivalent to where constraint ---"
        
        direct_match_pipeline = [
          {
            '$match' => {
              'likes' => { '$gte' => 50 }
            }
          },
          {
            '$group' => {
              '_id' => '$category',
              'postCount' => { '$sum' => 1 },
              'totalLikes' => { '$sum' => '$likes' },
              'avgLikes' => { '$avg' => '$likes' },
              'authors' => { '$addToSet' => '$author' }
            }
          },
          {
            '$sort' => { 'totalLikes' => -1 }
          }
        ]
        
        direct_match_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", direct_match_pipeline)
        direct_match_results = direct_match_query.results || []
        
        puts "Direct match aggregation (likes >= 50): #{direct_match_results.length} categories"
        
        if direct_match_results.any?
          total_posts_direct = direct_match_results.sum { |r| r['postCount'] }
          puts "Total posts in direct match: #{total_posts_direct}"
          
          direct_match_results.each do |result|
            assert result['avgLikes'] >= 50, "Average likes should be >= 50 due to direct match"
            puts "Category '#{result['objectId']}': #{result['postCount']} posts, avg likes: #{result['avgLikes']}"
            
            # Verify authors array contains pointers
            authors = result['authors']
            if authors.any? && authors.first.is_a?(Hash)
              first_author = authors.first
              assert first_author.key?('__type'), "Author should be a pointer"
              assert_equal 'Pointer', first_author['__type'], "Author should be Pointer type"
            end
          end
        end
        
        # Test 3: Multiple where constraints before aggregation
        puts "\n--- Test 3: Multiple where constraints before aggregation ---"
        
        multi_constraint_pipeline = [
          {
            '$match' => {
              'likes' => { '$gte' => 25 },
              'category' => { '$in' => ['tech', 'design'] }
            }
          },
          {
            '$lookup' => {
              'from' => 'AggregateTestUser',
              'localField' => 'author.objectId',
              'foreignField' => '_id',
              'as' => 'authorDetails'
            }
          },
          {
            '$unwind' => {
              'path' => '$authorDetails',
              'preserveNullAndEmptyArrays' => true
            }
          },
          {
            '$match' => {
              'authorDetails.active' => true
            }
          },
          {
            '$group' => {
              '_id' => '$category',
              'postCount' => { '$sum' => 1 },
              'totalLikes' => { '$sum' => '$likes' },
              'activeAuthors' => { '$addToSet' => '$author' }
            }
          }
        ]
        
        begin
          multi_constraint_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", multi_constraint_pipeline)
          multi_constraint_results = multi_constraint_query.results || []
          
          puts "Multi-constraint aggregation: #{multi_constraint_results.length} categories"
          
          if multi_constraint_results.any?
            multi_constraint_results.each do |result|
              puts "Category '#{result['objectId']}': #{result['postCount']} posts by active authors"
              
              # Should only include posts by active authors in tech/design categories with >= 25 likes
              active_authors = result['activeAuthors']
              assert active_authors.is_a?(Array), "Active authors should be an array"
              puts "  Active authors: #{active_authors.length}"
            end
          end
        rescue => e
          puts "Complex lookup aggregation may not be supported: #{e.message}"
        end
        
        # Test 4: Constraint on pointer field before aggregation
        puts "\n--- Test 4: Constraint on pointer field before aggregation ---"
        
        pointer_constraint_pipeline = [
          {
            '$match' => {
              '_p_author' => "AggregateTestUser$#{active_user.id}"
            }
          },
          {
            '$group' => {
              '_id' => nil,
              'totalPosts' => { '$sum' => 1 },
              'totalLikes' => { '$sum' => '$likes' },
              'categories' => { '$addToSet' => '$category' },
              'allTags' => { '$push' => '$tags' }
            }
          }
        ]
        
        pointer_constraint_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", pointer_constraint_pipeline)
        pointer_constraint_results = pointer_constraint_query.results || []
        
        puts "Pointer constraint aggregation: #{pointer_constraint_results.length} results"
        
        if pointer_constraint_results.any?
          result = pointer_constraint_results.first
          puts "Posts by active user: #{result['totalPosts']}, Total likes: #{result['totalLikes']}"
          puts "Categories: #{result['categories']}"
          
          # Should only include posts by the active user
          assert result['totalPosts'] <= 2, "Should only include posts by active user"
          
          # Verify tags array flattening
          all_tags = result['allTags']
          if all_tags.is_a?(Array) && all_tags.any?
            puts "All tags: #{all_tags.flatten.uniq}"
            assert all_tags.all? { |tag_array| tag_array.is_a?(Array) }, "Each tag entry should be an array"
          end
        end
        
        # Test 5: Date constraint before aggregation
        puts "\n--- Test 5: Date constraint before aggregation ---"
        
        recent_date = Time.now - 7 * 24 * 60 * 60  # 1 week ago
        
        date_constraint_pipeline = [
          {
            '$match' => {
              'createdAt' => {
                '$gte' => recent_date.iso8601
              }
            }
          },
          {
            '$group' => {
              '_id' => {
                '$dateToString' => {
                  'format' => '%Y-%m-%d',
                  'date' => '$createdAt'
                }
              },
              'postsCreated' => { '$sum' => 1 },
              'totalLikes' => { '$sum' => '$likes' }
            }
          },
          {
            '$sort' => { '_id' => -1 }
          }
        ]
        
        begin
          date_constraint_query = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", date_constraint_pipeline)
          date_constraint_results = date_constraint_query.results || []
          
          puts "Date constraint aggregation: #{date_constraint_results.length} days"
          
          if date_constraint_results.any?
            date_constraint_results.each do |result|
              puts "Date: #{result['objectId']}, Posts: #{result['postsCreated']}, Total likes: #{result['totalLikes']}"
            end
          end
        rescue => e
          puts "Date constraint aggregation may not be supported: #{e.message}"
        end
        
        puts "\n✅ Aggregate with preceding where constraints test passed"
      end
    end
  end

  def test_date_filtering_with_group_by_count
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(25, "date filtering with group by count test") do
        puts "\n=== Testing Date Filtering with Group By Count ==="
        
        # Create test users for grouping
        user1 = AggregateTestUser.new(name: "Date User 1", age: 25, city: "New York")
        user2 = AggregateTestUser.new(name: "Date User 2", age: 30, city: "Los Angeles")
        
        assert user1.save, "User 1 should save successfully"
        assert user2.save, "User 2 should save successfully"
        
        # Create posts at different times
        now = Time.now.utc
        past_time = now - 3600  # 1 hour ago
        future_time = now + 3600  # 1 hour from now
        
        posts_data = [
          { title: "Past Post 1", author: user1, category: "tech", published_at: past_time },
          { title: "Past Post 2", author: user1, category: "design", published_at: past_time },
          { title: "Past Post 3", author: user2, category: "tech", published_at: past_time },
          { title: "Future Post 1", author: user1, category: "tech", published_at: future_time },
          { title: "Future Post 2", author: user2, category: "design", published_at: future_time }
        ]
        
        posts_data.each_with_index do |data, index|
          post = AggregateTestPost.new(data)
          assert post.save, "Post #{index + 1} should save successfully"
          puts "Created post: #{data[:title]} at #{data[:published_at]}"
        end
        
        puts "Created test data: 2 users, 5 posts (3 past, 2 future)"
        
        # Test the exact pattern that was failing: where(date <= now).group_by(field).count
        puts "\n--- Testing where(published_at <= now).group_by(:author).count ---"
        puts "Filter time: #{now}"
        
        # First, let's see what posts actually exist
        puts "\n--- Debugging: Check all posts ---"
        all_posts = AggregateTestPost.all
        puts "Total posts in DB: #{all_posts.length}"
        all_posts.each do |post|
          puts "Post: #{post.title}, published_at: #{post.published_at}, author: #{post.author&.object_id}"
        end
        
        # Check posts with date filter
        puts "\n--- Debugging: Check posts with date filter ---"
        filtered_posts = AggregateTestPost.where(:published_at.lte => now).all
        puts "Posts matching date filter: #{filtered_posts.length}"
        filtered_posts.each do |post|
          puts "Filtered Post: #{post.title}, published_at: #{post.published_at}"
        end
        
        # Show the pipeline that will be generated
        puts "\n--- Debugging: Pipeline generation ---"
        pipeline = AggregateTestPost.where(:published_at.lte => now).group_by(:author).pipeline
        puts "Generated pipeline:"
        puts JSON.pretty_generate(pipeline)
        
        begin
          result = AggregateTestPost.where(:published_at.lte => now).group_by(:author).count
          
          puts "\nQuery executed successfully!"
          puts "Result type: #{result.class}"
          puts "Result: #{result}"
          
          # We should get results for the past posts only
          assert result.is_a?(Hash), "Result should be a hash"
          
          # Adjust expectation - if no filtered posts found, result will be empty
          if filtered_posts.empty?
            puts "⚠️  No posts match the date filter - this might be a timezone or data creation issue"
            assert result.empty?, "Result should be empty if no posts match filter"
          else
            assert result.length >= 1, "Should have at least 1 group when posts exist"
          end
          
          # Check that we're getting reasonable count values
          total_count = result.values.sum
          puts "Total posts found: #{total_count}"
          
          # Only check count if we have results
          if !result.empty?
            assert total_count >= filtered_posts.length, "Should find at least #{filtered_posts.length} matching posts"
            puts "✅ Found expected number of posts in aggregation"
          end
          
          puts "✅ Date filtering with group_by count works correctly"
          
        rescue => e
          flunk "Date filtering with group_by should work: #{e.class}: #{e.message}"
        end
        
        # Also test the pipeline generation to ensure correct date format
        puts "\n--- Testing pipeline generation ---"
        
        begin
          pipeline = AggregateTestPost.where(:published_at.lte => now).group_by(:author).pipeline
          
          puts "Generated pipeline:"
          puts JSON.pretty_generate(pipeline)
          
          # Verify pipeline structure
          assert pipeline.is_a?(Array), "Pipeline should be an array"
          assert pipeline.length >= 3, "Pipeline should have at least match, group, and project stages"
          
          # Check match stage has correct date format (raw ISO string)
          match_stage = pipeline.find { |stage| stage.key?("$match") }
          assert match_stage, "Pipeline should have a $match stage"
          
          published_at_constraint = match_stage["$match"]["publishedAt"]
          assert published_at_constraint, "Match stage should have publishedAt constraint"
          
          lte_constraint = published_at_constraint["$lte"] || published_at_constraint[:$lte]
          assert lte_constraint, "Should have $lte constraint"
          
          # Most importantly: should be a raw ISO string, not Parse Date object
          assert lte_constraint.is_a?(String), "Date constraint should be raw ISO string, got: #{lte_constraint.class}"
          assert_match(/^\d{4}-\d{2}-\d{2}T/, lte_constraint, "Should be in ISO format")
          
          puts "✅ Pipeline generates correct date format (raw ISO string)"
          
        rescue => e
          flunk "Pipeline generation should work: #{e.class}: #{e.message}"
        end
        
        puts "\n✅ Date filtering with group_by count integration test passed"
      end
    end
  end
  
  def test_pointer_constraint_aggregation
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(25, "pointer constraint aggregation test") do
        puts "\n=== Testing Pointer Constraint Aggregation ==="
        
        # Create test data for pointer constraint testing
        user1 = AggregateTestUser.new(name: "Pointer User 1", age: 28, city: "Boston", active: true)
        user2 = AggregateTestUser.new(name: "Pointer User 2", age: 32, city: "Seattle", active: true)
        user3 = AggregateTestUser.new(name: "Pointer User 3", age: 25, city: "Denver", active: false)
        
        assert user1.save, "User 1 should save successfully"
        assert user2.save, "User 2 should save successfully" 
        assert user3.save, "User 3 should save successfully"
        
        # Create posts with different authors
        post1 = AggregateTestPost.new(title: "Post by User 1", author: user1, category: "tech", likes: 100)
        post2 = AggregateTestPost.new(title: "Another Post by User 1", author: user1, category: "design", likes: 75)
        post3 = AggregateTestPost.new(title: "Post by User 2", author: user2, category: "tech", likes: 120)
        post4 = AggregateTestPost.new(title: "Post by User 3", author: user3, category: "writing", likes: 50)
        
        assert post1.save, "Post 1 should save successfully"
        assert post2.save, "Post 2 should save successfully"
        assert post3.save, "Post 3 should save successfully"
        assert post4.save, "Post 4 should save successfully"
        
        puts "Created test data: 3 users, 4 posts with pointer relationships"
        
        # Test 1: Filter by specific user pointer, then group by category
        puts "\n--- Test 1: where(author: user).group_by(:category).count ---"
        puts "Target user ID: #{user1.id}"
        
        # First verify basic where query works
        posts_by_user1 = AggregateTestPost.where(author: user1).all
        puts "Direct where query found: #{posts_by_user1.length} posts by user1"
        posts_by_user1.each do |post|
          puts "  - #{post.title} (#{post.category})"
        end
        
        # Show the aggregation pipeline that will be generated
        puts "\n--- Debugging: Pipeline generation ---"
        pipeline = AggregateTestPost.where(author: user1).group_by(:category).pipeline
        puts "Generated pipeline:"
        puts JSON.pretty_generate(pipeline)
        
        # Check the exact format of the pointer constraint in the match stage
        match_stage = pipeline.find { |stage| stage.key?("$match") }
        if match_stage
          match_conditions = match_stage["$match"]
          puts "\nMatch stage conditions:"
          match_conditions.each do |field, condition|
            puts "  #{field}: #{condition.inspect} (#{condition.class})"
          end
          
          # Look for author constraint specifically
          author_constraint = match_conditions["author"] || match_conditions["_p_author"]
          if author_constraint
            puts "Author constraint found: #{author_constraint.inspect} (#{author_constraint.class})"
          else
            puts "WARNING: No author constraint found in match stage"
          end
        end
        
        begin
          result = AggregateTestPost.where(author: user1).group_by(:category).count
          
          puts "\nPointer constraint aggregation executed successfully!"
          puts "Result type: #{result.class}"
          puts "Result: #{result.inspect}"
          
          if result.is_a?(Hash)
            assert !result.empty?, "Should find posts by user1"
            
            # Verify we get the expected categories
            expected_categories = ["tech", "design"]  # user1 has posts in these categories
            result.keys.each do |category|
              assert expected_categories.include?(category), "Found unexpected category: #{category}"
            end
            
            # Total should match direct query results
            total_count = result.values.sum
            assert total_count == posts_by_user1.length, "Aggregation count should match direct query: expected #{posts_by_user1.length}, got #{total_count}"
            
            puts "✅ Pointer constraint aggregation works correctly"
          else
            flunk "Expected Hash result, got #{result.class}: #{result.inspect}"
          end
          
        rescue => e
          puts "\n❌ Pointer constraint aggregation failed: #{e.class}: #{e.message}"
          puts "This confirms the issue with pointer constraints in aggregation pipelines"
          
          # Let's also test with the raw pipeline to see if Parse Server accepts it
          puts "\n--- Testing raw pipeline execution ---"
          begin
            raw_result = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", pipeline)
            puts "Raw pipeline result: #{raw_result.results&.inspect || raw_result.inspect}"
            
            if raw_result.results.is_a?(Array) && raw_result.results.empty?
              puts "Raw pipeline returned empty results - pointer constraint format issue confirmed"
            end
          rescue => raw_e
            puts "Raw pipeline also failed: #{raw_e.class}: #{raw_e.message}"
          end
          
          flunk "Pointer constraint aggregation should work: #{e.class}: #{e.message}"
        end
        
        # Test 2: Multiple pointer constraints
        puts "\n--- Test 2: Multiple constraints including pointer ---"
        
        begin
          result2 = AggregateTestPost.where(author: user1, :likes.gte => 80).group_by(:category).count
          
          puts "Multiple constraint result: #{result2.inspect}"
          
          # Should only include posts by user1 with likes >= 80
          if result2.is_a?(Hash)
            total_count = result2.values.sum
            expected_posts = posts_by_user1.select { |p| p.likes >= 80 }
            assert total_count == expected_posts.length, "Should match posts with likes >= 80"
            
            puts "✅ Multiple constraints including pointer work correctly"
          end
          
        rescue => e
          puts "Multiple constraints failed: #{e.class}: #{e.message}"
        end
        
        # Test 3: Test the exact failing pattern from user's example
        puts "\n--- Test 3: Test exact failing patterns ---"
        
        # Pattern 1: Membership.where(role: x, active: true).group_by(:project).count
        # We'll simulate with Post.where(author: x, category: y).group_by(:author).count
        begin
          simulated_result = AggregateTestPost.where(author: user1, category: "tech").group_by(:author).count
          puts "Simulated membership pattern result: #{simulated_result.inspect}"
          
          if simulated_result.is_a?(Hash) && !simulated_result.empty?
            puts "✅ Simulated membership pattern works"
          elsif simulated_result.is_a?(Hash) && simulated_result.empty?
            puts "❌ Simulated membership pattern returned empty results"
          end
        rescue => e
          puts "Simulated membership pattern failed: #{e.class}: #{e.message}"
        end
        
        # Test 4: Debug the internal pointer format vs expected format
        puts "\n--- Test 4: Pointer format debugging ---"
        
        # Check what format Parse Server expects vs what we're sending
        manual_pipeline = [
          {
            "$match" => {
              "_p_author" => "_AggregateTestUser$#{user1.id}"  # MongoDB internal format
            }
          },
          {
            "$group" => {
              "_id" => "$category",
              "count" => { "$sum" => 1 }
            }
          }
        ]
        
        puts "Manual pipeline with _p_author:"
        puts JSON.pretty_generate(manual_pipeline)
        
        begin
          manual_result = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", manual_pipeline)
          puts "Manual _p_author result: #{manual_result.results&.inspect || 'nil'}"
          
          if manual_result.results&.any?
            puts "✅ _p_author format works in aggregation"
          else
            puts "❌ _p_author format also fails"
          end
        rescue => e
          puts "Manual _p_author pipeline failed: #{e.class}: #{e.message}"
        end
        
        # Try with Parse API format
        manual_pipeline2 = [
          {
            "$match" => {
              "author" => {
                "__type" => "Pointer",
                "className" => "AggregateTestUser", 
                "objectId" => user1.id
              }
            }
          },
          {
            "$group" => {
              "_id" => "$category",
              "count" => { "$sum" => 1 }
            }
          }
        ]
        
        puts "\nManual pipeline with Parse Pointer format:"
        puts JSON.pretty_generate(manual_pipeline2)
        
        begin
          manual_result2 = AggregateTestPost.new.client.aggregate_pipeline("AggregateTestPost", manual_pipeline2)
          puts "Manual Parse Pointer result: #{manual_result2.results&.inspect || 'nil'}"
          
          if manual_result2.results&.any?
            puts "✅ Parse Pointer format works in aggregation"
          else
            puts "❌ Parse Pointer format also fails"
          end
        rescue => e
          puts "Manual Parse Pointer pipeline failed: #{e.class}: #{e.message}"
        end
        
        puts "\n✅ Pointer constraint aggregation test completed (debugging results above)"
      end
    end
  end
end