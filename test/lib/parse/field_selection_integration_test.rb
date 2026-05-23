require_relative "../../test_helper_integration"

# Test models for field selection testing
class FieldSelectionPost < Parse::Object
  parse_class "FieldSelectionPost"

  property :title, :string
  property :content, :string
  property :category, :string
  property :author_name, :string
  property :view_count, :integer, default: 0
  property :published, :boolean, default: false
  property :tags, :array
  property :meta_data, :object
end

class FieldSelectionUser < Parse::Object
  parse_class "FieldSelectionUser"

  property :name, :string
  property :email, :string
  property :age, :integer
  property :bio, :string
  property :preferences, :object
end

class FieldSelectionIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_keys_method_limits_returned_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "keys method field limitation test") do
        puts "\n=== Testing keys Method Limits Returned Fields ==="

        # Create test posts with full data
        post1 = FieldSelectionPost.new(
          title: "Test Post 1",
          content: "This is the content of post 1",
          category: "tech",
          author_name: "Alice",
          view_count: 100,
          published: true,
          tags: ["programming", "ruby"],
          meta_data: { featured: true, priority: "high" },
        )
        assert post1.save, "Post 1 should save"

        post2 = FieldSelectionPost.new(
          title: "Test Post 2",
          content: "This is the content of post 2",
          category: "news",
          author_name: "Bob",
          view_count: 50,
          published: false,
          tags: ["updates", "company"],
          meta_data: { featured: false, priority: "low" },
        )
        assert post2.save, "Post 2 should save"

        # Test keys with single field
        posts_with_title = FieldSelectionPost.query.keys(:title).results
        assert_equal 2, posts_with_title.length, "Should return all posts"

        post = posts_with_title.first
        post.disable_autofetch!  # Prevent autofetch when checking unfetched fields
        assert post.title.present?, "Title should be present"
        refute post.field_was_fetched?(:content), "Content should not be fetched"
        refute post.field_was_fetched?(:category), "Category should not be fetched"
        refute post.field_was_fetched?(:author_name), "Author name should not be fetched"

        # Test keys with multiple fields
        posts_with_multiple = FieldSelectionPost.query.keys(:title, :category, :published).results
        assert_equal 2, posts_with_multiple.length, "Should return all posts"

        post = posts_with_multiple.first
        post.disable_autofetch!  # Prevent autofetch when checking unfetched fields
        assert post.title.present?, "Title should be present"
        assert post.category.present?, "Category should be present"
        assert [true, false].include?(post.published), "Published should be present"
        refute post.field_was_fetched?(:content), "Content should not be fetched"
        refute post.field_was_fetched?(:author_name), "Author name should not be fetched"
        refute post.field_was_fetched?(:view_count), "View count should not be fetched"

        puts "✅ keys method correctly limits returned fields"
      end
    end
  end

  def test_select_fields_alias_functionality
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "select_fields alias test") do
        puts "\n=== Testing select_fields Alias Functionality ==="

        # Create test user
        user = FieldSelectionUser.new(
          name: "Test User",
          email: "test@example.com",
          age: 30,
          bio: "This is a bio",
          preferences: { theme: "dark", notifications: true },
        )
        assert user.save, "User should save"

        # Test select_fields (alias for keys)
        users_with_select_fields = FieldSelectionUser.query.select_fields(:name, :email).results
        assert_equal 1, users_with_select_fields.length, "Should return the user"

        user_result = users_with_select_fields.first
        user_result.disable_autofetch!  # Prevent autofetch when checking unfetched fields
        assert_equal "Test User", user_result.name, "Name should be present"
        assert_equal "test@example.com", user_result.email, "Email should be present"
        refute user_result.field_was_fetched?(:bio), "Bio should not be fetched"
        refute user_result.field_was_fetched?(:age), "Age should not be fetched"

        # Test that keys and select_fields produce same result
        users_with_keys = FieldSelectionUser.query.keys(:name, :email).results
        users_with_select = FieldSelectionUser.query.select_fields(:name, :email).results

        user_keys = users_with_keys.first
        user_keys.disable_autofetch!  # Prevent autofetch when checking unfetched fields
        user_select = users_with_select.first
        user_select.disable_autofetch!  # Prevent autofetch when checking unfetched fields

        assert_equal user_keys.name, user_select.name, "Name should be same with both methods"
        assert_equal user_keys.email, user_select.email, "Email should be same with both methods"
        refute user_keys.field_was_fetched?(:bio), "Bio should not be fetched with keys"
        refute user_select.field_was_fetched?(:bio), "Bio should not be fetched with select_fields"

        puts "✅ select_fields alias works correctly"
      end
    end
  end

  def test_field_selection_with_array_and_object_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "array and object field selection test") do
        puts "\n=== Testing Field Selection with Array and Object Fields ==="

        # Create post with complex data
        post = FieldSelectionPost.new(
          title: "Complex Post",
          content: "Content with arrays and objects",
          tags: ["ruby", "parse", "testing"],
          meta_data: {
            author: { name: "John", role: "admin" },
            stats: { views: 1000, likes: 50 },
          },
        )
        assert post.save, "Complex post should save"

        # Test selecting array field
        posts_with_tags = FieldSelectionPost.query.keys(:title, :tags).results
        post_result = posts_with_tags.first
        post_result.disable_autofetch!  # Prevent autofetch when checking unfetched fields

        assert_equal "Complex Post", post_result.title, "Title should be present"
        assert_equal ["ruby", "parse", "testing"], post_result.tags, "Tags array should be present"
        refute post_result.field_was_fetched?(:content), "Content should not be fetched"

        # Test selecting object field
        posts_with_meta = FieldSelectionPost.query.keys(:title, :meta_data).results
        post_result = posts_with_meta.first

        assert_equal "Complex Post", post_result.title, "Title should be present"
        assert post_result.meta_data.is_a?(Hash), "Meta data should be an object/hash"
        assert_equal "John", post_result.meta_data["author"]["name"], "Nested object data should be present"
        assert_equal 1000, post_result.meta_data["stats"]["views"], "Nested stats should be present"

        puts "✅ Array and object field selection works correctly"
      end
    end
  end

  def test_field_selection_with_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "field selection with constraints test") do
        puts "\n=== Testing Field Selection Combined with Query Constraints ==="

        # Create multiple posts
        post1 = FieldSelectionPost.new(title: "Tech Post", category: "tech", view_count: 100, published: true)
        assert post1.save, "Tech post should save"

        post2 = FieldSelectionPost.new(title: "News Post", category: "news", view_count: 50, published: false)
        assert post2.save, "News post should save"

        post3 = FieldSelectionPost.new(title: "Tech Post 2", category: "tech", view_count: 200, published: true)
        assert post3.save, "Tech post 2 should save"

        # Test field selection with where constraints
        tech_posts = FieldSelectionPost.query
          .where(category: "tech")
          .keys(:title, :view_count)
          .results

        assert_equal 2, tech_posts.length, "Should return 2 tech posts"
        tech_posts.each do |post|
          post.disable_autofetch!  # Prevent autofetch when checking unfetched fields
          assert post.title.present?, "Title should be present"
          assert post.view_count > 0, "View count should be present"
          refute post.field_was_fetched?(:category), "Category should not be fetched (even though used in where)"
          refute post.field_was_fetched?(:published), "Published should not be fetched"
        end

        # Test field selection with ordering
        ordered_posts = FieldSelectionPost.query
          .keys(:title, :view_count)
          .order(:view_count.desc)
          .results

        assert_equal 3, ordered_posts.length, "Should return all posts ordered"
        assert ordered_posts.first.view_count >= ordered_posts.last.view_count, "Should be ordered by view count desc"
        ordered_posts.each do |post|
          post.disable_autofetch!  # Prevent autofetch when checking unfetched fields
          assert post.title.present?, "Title should be present"
          refute post.field_was_fetched?(:category), "Category should not be fetched"
        end

        # Test field selection with limit
        limited_posts = FieldSelectionPost.query
          .keys(:title)
          .limit(2)
          .results

        assert_equal 2, limited_posts.length, "Should return limited number of posts"
        limited_posts.each do |post|
          post.disable_autofetch!  # Prevent autofetch when checking unfetched fields
          assert post.title.present?, "Title should be present"
          refute post.field_was_fetched?(:content), "Content should not be fetched"
        end

        puts "✅ Field selection with constraints works correctly"
      end
    end
  end

  def test_field_selection_chaining_and_method_calls
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "field selection chaining test") do
        puts "\n=== Testing Field Selection with Method Chaining ==="

        # Create test data
        user1 = FieldSelectionUser.new(name: "Alice", email: "alice@example.com", age: 25)
        assert user1.save, "User 1 should save"

        user2 = FieldSelectionUser.new(name: "Bob", email: "bob@example.com", age: 30)
        assert user2.save, "User 2 should save"

        # Test chaining with first()
        user = FieldSelectionUser.query.keys(:name).first
        assert user, "Should return a user"
        user.disable_autofetch!  # Prevent autofetch when checking unfetched fields
        assert user.name.present?, "Name should be present"
        refute user.field_was_fetched?(:email), "Email should not be fetched"

        # Test chaining with first(n)
        users = FieldSelectionUser.query.keys(:name, :age).first(2)
        assert_equal 2, users.length, "Should return 2 users"
        users.each do |u|
          u.disable_autofetch!  # Prevent autofetch when checking unfetched fields
          assert u.name.present?, "Name should be present"
          assert u.age > 0, "Age should be present"
          refute u.field_was_fetched?(:email), "Email should not be fetched"
        end

        # Test latest() method combined with field selection
        latest_user = FieldSelectionUser.query.keys(:name).latest
        assert latest_user, "Should return latest user"
        latest_user.disable_autofetch!  # Prevent autofetch when checking unfetched fields
        assert latest_user.name.present?, "Name should be present"
        refute latest_user.field_was_fetched?(:email), "Email should not be fetched"

        # Test chaining with count()
        count = FieldSelectionUser.query.keys(:name).count
        assert_equal 2, count, "Count should work with field selection"

        puts "✅ Field selection chaining works correctly"
      end
    end
  end

  def test_field_selection_performance_and_payload_size
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "field selection performance test") do
        puts "\n=== Testing Field Selection Performance Benefits ==="

        # Create post with large content
        large_content = "Lorem ipsum " * 1000  # Large text content
        large_bio = "Biography " * 500

        post = FieldSelectionPost.new(
          title: "Performance Test",
          content: large_content,
          author_name: "Performance Tester",
          view_count: 1000,
        )
        assert post.save, "Performance test post should save"

        user = FieldSelectionUser.new(
          name: "Performance User",
          email: "perf@example.com",
          bio: large_bio,
          age: 25,
        )
        assert user.save, "Performance test user should save"

        # Test full object vs limited fields
        start_time = Time.now
        full_post = FieldSelectionPost.first
        full_load_time = Time.now - start_time

        start_time = Time.now
        limited_post = FieldSelectionPost.query.keys(:title, :view_count).first
        limited_load_time = Time.now - start_time

        # Verify data differences
        limited_post.disable_autofetch!  # Prevent autofetch when checking unfetched fields
        assert_equal full_post.title, limited_post.title, "Titles should match"
        assert_equal full_post.view_count, limited_post.view_count, "View counts should match"
        assert full_post.content.length > 1000, "Full post should have large content"
        refute limited_post.field_was_fetched?(:content), "Content should not be fetched"

        # Performance should be better (though this can vary in test environment)
        puts "Full object load time: #{(full_load_time * 1000).round(2)}ms"
        puts "Limited fields load time: #{(limited_load_time * 1000).round(2)}ms"
        puts "Content size difference: #{full_post.content.length} vs 0 chars"

        # Test with multiple objects
        10.times do |i|
          FieldSelectionUser.new(
            name: "User #{i}",
            email: "user#{i}@example.com",
            bio: large_bio,
            age: 20 + i,
          ).save
        end

        start_time = Time.now
        full_users = FieldSelectionUser.all
        full_batch_time = Time.now - start_time

        start_time = Time.now
        limited_users = FieldSelectionUser.query.keys(:name, :age).results
        limited_batch_time = Time.now - start_time

        puts "Full batch (#{full_users.length} users): #{(full_batch_time * 1000).round(2)}ms"
        puts "Limited batch (#{limited_users.length} users): #{(limited_batch_time * 1000).round(2)}ms"

        assert_equal full_users.length, limited_users.length, "Should return same number of users"
        limited_users.each do |user|
          user.disable_autofetch!  # Prevent autofetch when checking unfetched fields
          assert user.name.present?, "Name should be present"
          assert user.age > 0, "Age should be present"
          refute user.field_was_fetched?(:bio), "Bio should not be fetched"
        end

        puts "✅ Field selection provides performance benefits"
      end
    end
  end

  def test_field_selection_edge_cases
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "field selection edge cases test") do
        puts "\n=== Testing Field Selection Edge Cases ==="

        # Create test data
        post = FieldSelectionPost.new(title: "Edge Case Test", content: "Test content")
        assert post.save, "Test post should save"

        # Test with no fields selected (should return all fields)
        posts_no_fields = FieldSelectionPost.query.keys().results
        assert_equal 1, posts_no_fields.length, "Should return the post"
        post_result = posts_no_fields.first
        assert post_result.title.present?, "Title should be present with no field selection"
        assert post_result.content.present?, "Content should be present with no field selection"

        # Test with non-existent field (should not cause error)
        posts_invalid_field = FieldSelectionPost.query.keys(:title, :non_existent_field).results
        assert_equal 1, posts_invalid_field.length, "Should return the post despite invalid field"
        post_result = posts_invalid_field.first
        assert post_result.title.present?, "Title should be present"
        refute post_result.respond_to?(:non_existent_field), "Should not have non-existent field"

        # Test with Parse built-in fields
        posts_with_system_fields = FieldSelectionPost.query.keys(:title, :objectId, :createdAt, :updatedAt).results
        post_result = posts_with_system_fields.first
        assert post_result.title.present?, "Title should be present"
        assert post_result.id.present?, "Object ID should be present"
        assert post_result.created_at.present?, "Created at should be present"
        assert post_result.updated_at.present?, "Updated at should be present"

        # Test field selection on empty results
        empty_results = FieldSelectionPost.query.where(title: "Non-existent").keys(:title).results
        assert_empty empty_results, "Should return empty array for non-matching query"

        puts "✅ Field selection edge cases handled correctly"
      end
    end
  end

  def test_select_constraint_functionality
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "select constraint test") do
        puts "\n=== Testing Select Query Constraint ($select) ==="

        # Create authors with different fan counts
        author1 = FieldSelectionUser.new(name: "Popular Author", email: "popular@example.com", age: 30, bio: "Has many fans")
        assert author1.save, "Popular author should save"

        author2 = FieldSelectionUser.new(name: "Niche Author", email: "niche@example.com", age: 25, bio: "Has few fans")
        assert author2.save, "Niche author should save"

        author3 = FieldSelectionUser.new(name: "Famous Author", email: "famous@example.com", age: 40, bio: "Very popular")
        assert author3.save, "Famous author should save"

        # Create posts with different categories and author associations
        post1 = FieldSelectionPost.new(
          title: "Tech Post by Popular Author",
          content: "Great tech content",
          category: "tech",
          author_name: author1.name,
        )
        assert post1.save, "Post 1 should save"

        post2 = FieldSelectionPost.new(
          title: "News Post by Niche Author",
          content: "Local news",
          category: "news",
          author_name: author2.name,
        )
        assert post2.save, "Post 2 should save"

        post3 = FieldSelectionPost.new(
          title: "Tech Post by Famous Author",
          content: "Advanced tech topics",
          category: "tech",
          author_name: author3.name,
        )
        assert post3.save, "Post 3 should save"

        # Test select constraint: Find posts where author_name matches name of users older than 35
        older_authors_query = FieldSelectionUser.query.where(:age.gt => 35)
        posts_by_older_authors = FieldSelectionPost.query
          .where(:author_name.select => {
                   key: :name,
                   query: older_authors_query,
                 })
          .results

        assert_equal 1, posts_by_older_authors.length, "Should find 1 post by author older than 35"
        post_result = posts_by_older_authors.first
        assert_equal "Tech Post by Famous Author", post_result.title, "Should be the post by Famous Author (age 40)"
        assert_equal "Famous Author", post_result.author_name, "Author name should match"

        # Test select constraint with simplified syntax (when field names match)
        # Create a query that looks for users by author_name field (this won't work since users don't have author_name)
        # Instead, let's test with a working scenario where field names actually match
        posts_with_specific_names = FieldSelectionPost.query.where(:title.contains => "Famous")

        # This simplified syntax would look for Users where 'title' field matches, but Users don't have title
        # So let's create a more appropriate test
        users_with_specific_names = FieldSelectionUser.query.where(:name.contains => "Famous")
        posts_by_specific_users = FieldSelectionPost.query
                                                    .where(:author_name.select => {
                                                             key: :name,
                                                             query: users_with_specific_names,
                                                           })
                                                    .results

        assert_equal 1, posts_by_specific_users.length, "Should find 1 post by user with 'Famous' in name"

        # Test select constraint with additional filters
        tech_posts_by_older_authors = FieldSelectionPost.query
                                                        .where(category: "tech")
                                                        .where(:author_name.select => {
                                                                 key: :name,
                                                                 query: older_authors_query,
                                                               })
                                                        .results

        assert_equal 1, tech_posts_by_older_authors.length, "Should find 1 tech post by older author"
        assert_equal "tech", tech_posts_by_older_authors.first.category, "Should be tech category"

        puts "✅ Select constraint works correctly"
      end
    end
  end

  def test_reject_constraint_functionality
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "reject constraint test") do
        puts "\n=== Testing Reject Query Constraint ($dontSelect) ==="

        # Create users with different preferences
        user1 = FieldSelectionUser.new(name: "Active User", email: "active@example.com", age: 28, bio: "Very active")
        assert user1.save, "Active user should save"

        user2 = FieldSelectionUser.new(name: "Inactive User", email: "inactive@example.com", age: 22, bio: "Not very active")
        assert user2.save, "Inactive user should save"

        user3 = FieldSelectionUser.new(name: "Moderate User", email: "moderate@example.com", age: 35, bio: "Somewhat active")
        assert user3.save, "Moderate user should save"

        # Create posts with different engagement levels and author associations
        post1 = FieldSelectionPost.new(
          title: "High Engagement Post",
          content: "Very popular content",
          category: "tech",
          author_name: user1.name,
          view_count: 1000,
        )
        assert post1.save, "High engagement post should save"

        post2 = FieldSelectionPost.new(
          title: "Low Engagement Post",
          content: "Not very popular",
          category: "news",
          author_name: user2.name,
          view_count: 10,
        )
        assert post2.save, "Low engagement post should save"

        post3 = FieldSelectionPost.new(
          title: "Medium Engagement Post",
          content: "Moderately popular",
          category: "tech",
          author_name: user3.name,
          view_count: 100,
        )
        assert post3.save, "Medium engagement post should save"

        # Test reject constraint: Find posts where author_name does NOT match name of young users (age < 25)
        young_users_query = FieldSelectionUser.query.where(:age.lt => 25)
        posts_not_by_young_authors = FieldSelectionPost.query
                                                       .where(:author_name.reject => {
                                                                key: :name,
                                                                query: young_users_query,
                                                              })
                                                       .results

        assert_equal 2, posts_not_by_young_authors.length, "Should find 2 posts not by young authors"
        author_names = posts_not_by_young_authors.map(&:author_name)
        assert_includes author_names, "Active User", "Should include post by Active User (age 28)"
        assert_includes author_names, "Moderate User", "Should include post by Moderate User (age 35)"
        refute_includes author_names, "Inactive User", "Should NOT include post by Inactive User (age 22)"

        # Test reject constraint with another query approach
        posts_not_by_inactive_user = FieldSelectionPost.query
                                                       .where(:author_name.reject => {
                                                                key: :name,
                                                                query: FieldSelectionUser.query.where(name: "Inactive User"),
                                                              })
                                                       .results

        assert_equal 2, posts_not_by_inactive_user.length, "Should find 2 posts not by Inactive User"

        # Test reject constraint combined with other filters
        tech_posts_not_by_young = FieldSelectionPost.query
                                                    .where(category: "tech")
                                                    .where(:author_name.reject => {
                                                             key: :name,
                                                             query: young_users_query,
                                                           })
                                                    .results

        assert_equal 2, tech_posts_not_by_young.length, "Should find 2 tech posts not by young authors"
        tech_posts_not_by_young.each do |post|
          assert_equal "tech", post.category, "Should all be tech posts"
          refute_equal "Inactive User", post.author_name, "Should not include young author"
        end

        puts "✅ Reject constraint works correctly"
      end
    end
  end

  def test_select_and_reject_constraints_with_complex_scenarios
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(25, "complex select/reject test") do
        puts "\n=== Testing Complex Select and Reject Constraint Scenarios ==="

        # Create a more complex scenario with different user roles and post types
        admin_user = FieldSelectionUser.new(name: "Admin User", email: "admin@example.com", age: 30, bio: "Administrator")
        assert admin_user.save, "Admin user should save"

        editor_user = FieldSelectionUser.new(name: "Editor User", email: "editor@example.com", age: 26, bio: "Content editor")
        assert editor_user.save, "Editor user should save"

        author_user = FieldSelectionUser.new(name: "Author User", email: "author@example.com", age: 24, bio: "Content author")
        assert author_user.save, "Author user should save"

        # Create posts with different statuses and authors
        published_post1 = FieldSelectionPost.new(
          title: "Published by Admin",
          content: "Important announcement",
          category: "news",
          author_name: admin_user.name,
          view_count: 500,
          published: true,
        )
        assert published_post1.save, "Published post 1 should save"

        draft_post1 = FieldSelectionPost.new(
          title: "Draft by Editor",
          content: "Work in progress",
          category: "tech",
          author_name: editor_user.name,
          view_count: 0,
          published: false,
        )
        assert draft_post1.save, "Draft post 1 should save"

        published_post2 = FieldSelectionPost.new(
          title: "Published by Author",
          content: "Tutorial content",
          category: "tech",
          author_name: author_user.name,
          view_count: 200,
          published: true,
        )
        assert published_post2.save, "Published post 2 should save"

        # Test chaining select and reject constraints
        experienced_users_query = FieldSelectionUser.query.where(:age.gte => 25)
        novice_users_query = FieldSelectionUser.query.where(:age.lt => 25)

        # Find published posts by experienced users but not by novice users
        published_posts_by_experienced = FieldSelectionPost.query
                                                           .where(published: true)
                                                           .where(:author_name.select => {
                                                                    key: :name,
                                                                    query: experienced_users_query,
                                                                  })
                                                           .where(:author_name.reject => {
                                                                    key: :name,
                                                                    query: novice_users_query,
                                                                  })
                                                           .results

        assert_equal 1, published_posts_by_experienced.length, "Should find 1 published post by experienced user"
        post_result = published_posts_by_experienced.first
        assert_equal "Published by Admin", post_result.title, "Should be the post by admin (age 30)"
        assert post_result.published, "Post should be published"

        # Test select constraint with field selection (keys)
        posts_by_experienced_limited_fields = FieldSelectionPost.query
          .where(:author_name.select => {
                   key: :name,
                   query: experienced_users_query,
                 })
          .keys(:title, :author_name, :published)
          .results

        assert_equal 2, posts_by_experienced_limited_fields.length, "Should find 2 posts by experienced users"
        posts_by_experienced_limited_fields.each do |post|
          post.disable_autofetch!  # Prevent autofetch when checking unfetched fields
          assert post.title.present?, "Title should be present"
          assert post.author_name.present?, "Author name should be present"
          refute post.field_was_fetched?(:content), "Content should not be fetched"
          refute post.field_was_fetched?(:category), "Category should not be fetched"
        end

        # Test error handling for invalid constraint values
        assert_raises(ArgumentError) do
          FieldSelectionPost.query.where(:author_name.select => "invalid_value").results
        end

        assert_raises(ArgumentError) do
          FieldSelectionPost.query.where(:author_name.reject => 123).results
        end

        puts "✅ Complex select and reject constraint scenarios work correctly"
      end
    end
  end
end
