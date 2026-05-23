require_relative "../../test_helper_integration"

# Test models for partial fetch testing
class PartialFetchPost < Parse::Object
  parse_class "PartialFetchPost"

  property :title, :string
  property :content, :string
  property :category, :string
  property :view_count, :integer, default: 0
  property :is_published, :boolean, default: false
  property :is_featured, :boolean, default: false
  property :tags, :array, default: []
  property :meta_data, :object

  belongs_to :author, as: :partial_fetch_user
end

class PartialFetchUser < Parse::Object
  parse_class "PartialFetchUser"

  property :name, :string
  property :email, :string
  property :age, :integer
  property :is_active, :boolean, default: true
  property :is_verified, :boolean, default: false
  property :settings, :object
end

class PartialFetchIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_partial_fetch_tracks_fetched_keys
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "partial fetch tracking test") do
        puts "\n=== Testing Partial Fetch Tracks Fetched Keys ==="

        # Create test post with full data
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "This is the content",
          category: "tech",
          view_count: 100,
          is_published: true,
          is_featured: true,
          tags: ["ruby", "testing"],
          meta_data: { featured: true },
        )
        assert post.save, "Post should save"

        # Fetch with specific keys
        fetched_post = PartialFetchPost.first(keys: [:title, :category])

        # Check that object is partially fetched
        assert fetched_post.partially_fetched?, "Post should be marked as partially fetched"

        # Check that fetched_keys includes the requested keys and :id
        assert fetched_post.fetched_keys.include?(:title), "fetched_keys should include :title"
        assert fetched_post.fetched_keys.include?(:category), "fetched_keys should include :category"
        assert fetched_post.fetched_keys.include?(:id), "fetched_keys should always include :id"

        # Check field_was_fetched? method
        assert fetched_post.field_was_fetched?(:title), "title should be marked as fetched"
        assert fetched_post.field_was_fetched?(:category), "category should be marked as fetched"
        assert fetched_post.field_was_fetched?(:id), "id should always be fetched"
        refute fetched_post.field_was_fetched?(:content), "content should not be fetched"
        refute fetched_post.field_was_fetched?(:view_count), "view_count should not be fetched"

        puts "Partial fetch tracking works correctly"
      end
    end
  end

  def test_partial_fetch_no_dirty_tracking_for_defaults
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "partial fetch no dirty tracking test") do
        puts "\n=== Testing Partial Fetch Has No Dirty Tracking for Defaults ==="

        # Create post with specific values for fields with defaults
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          view_count: 50,
          is_published: true,
          is_featured: true,
          tags: ["ruby"],
        )
        assert post.save, "Post should save"

        # Fetch with only :id and :title
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # The changes hash should be empty - no dirty tracking from defaults
        assert_empty fetched_post.changes, "Changes should be empty after partial fetch"

        # Fields with defaults should not be marked as changed
        refute fetched_post.view_count_changed?, "view_count should not be changed"
        refute fetched_post.is_published_changed?, "is_published should not be changed"
        refute fetched_post.is_featured_changed?, "is_featured should not be changed"
        refute fetched_post.tags_changed?, "tags should not be changed"

        puts "Partial fetch has no dirty tracking for defaults"
      end
    end
  end

  def test_partial_fetch_autofetches_unfetched_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "autofetch unfetched fields test") do
        puts "\n=== Testing Partial Fetch Autofetches Unfetched Fields ==="

        # Create post with all fields set
        original_content = "This is the original content that should be autofetched"
        post = PartialFetchPost.new(
          title: "Test Post",
          content: original_content,
          category: "tech",
          view_count: 100,
          is_published: true,
        )
        assert post.save, "Post should save"

        # Fetch with only :title
        fetched_post = PartialFetchPost.first(keys: [:title])

        # Verify it's partially fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Access the content field - this should trigger autofetch
        actual_content = fetched_post.content

        # After autofetch, the object should no longer be partially fetched
        refute fetched_post.partially_fetched?, "Post should no longer be partially fetched after autofetch"

        # The content should match the original
        assert_equal original_content, actual_content, "Content should match original after autofetch"

        # Other fields should also be populated
        assert_equal "tech", fetched_post.category, "Category should be fetched"
        assert_equal 100, fetched_post.view_count, "View count should be fetched"
        assert fetched_post.is_published, "is_published should be fetched"

        puts "Autofetch works correctly for unfetched fields"
      end
    end
  end

  def test_partial_fetch_doesnt_autofetch_fetched_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "no autofetch for fetched fields test") do
        puts "\n=== Testing Partial Fetch Doesn't Autofetch Fetched Fields ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          category: "tech",
        )
        assert post.save, "Post should save"

        # Fetch with :title and :category
        fetched_post = PartialFetchPost.first(keys: [:title, :category])

        # Access fetched fields - should not trigger autofetch
        title = fetched_post.title
        category = fetched_post.category

        # Object should still be partially fetched
        assert fetched_post.partially_fetched?, "Post should still be partially fetched after accessing fetched fields"

        # Values should be correct
        assert_equal "Test Post", title
        assert_equal "tech", category

        puts "No autofetch for fetched fields"
      end
    end
  end

  def test_empty_keys_means_fully_fetched
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "empty keys fully fetched test") do
        puts "\n=== Testing Empty Keys Means Fully Fetched ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
        )
        assert post.save, "Post should save"

        # Fetch with empty keys array
        fetched_post = PartialFetchPost.query.keys().first

        # Object should not be partially fetched (empty keys = full fetch)
        refute fetched_post.partially_fetched?, "Empty keys should mean fully fetched"

        # All fields should be fetched
        assert fetched_post.field_was_fetched?(:title), "title should be fetched"
        assert fetched_post.field_was_fetched?(:content), "content should be fetched"
        assert fetched_post.field_was_fetched?(:category), "category should be fetched"

        puts "Empty keys means fully fetched"
      end
    end
  end

  def test_full_fetch_not_partially_fetched
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "full fetch not partially fetched test") do
        puts "\n=== Testing Full Fetch Is Not Partially Fetched ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
        )
        assert post.save, "Post should save"

        # Fetch without keys (full fetch)
        fetched_post = PartialFetchPost.first

        # Object should not be partially fetched
        refute fetched_post.partially_fetched?, "Full fetch should not be partially fetched"

        # All fields should be considered fetched
        assert fetched_post.field_was_fetched?(:title)
        assert fetched_post.field_was_fetched?(:content)
        assert fetched_post.field_was_fetched?(:view_count)

        puts "Full fetch is not partially fetched"
      end
    end
  end

  def test_fetch_clears_partial_fetch_state
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "fetch clears partial state test") do
        puts "\n=== Testing fetch! Clears Partial Fetch State ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
        )
        assert post.save, "Post should save"

        # Fetch with specific keys
        fetched_post = PartialFetchPost.first(keys: [:title])

        # Verify it's partially fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Call fetch! to get full object
        fetched_post.fetch!

        # Should no longer be partially fetched
        refute fetched_post.partially_fetched?, "Post should not be partially fetched after fetch!"

        # All fields should now be available
        assert_equal "Content", fetched_post.content, "Content should be available after fetch!"

        puts "fetch! clears partial fetch state"
      end
    end
  end

  def test_partial_fetch_save_only_changed_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "partial fetch save only changed fields test") do
        puts "\n=== Testing Partial Fetch Save Only Changed Fields ==="

        # Create post with specific values
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
          view_count: 100,
          is_published: true,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch with only :title
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # Change only the title
        fetched_post.title = "Updated Title"

        # Save should only update the title
        assert fetched_post.save, "Post should save with only title changed"

        # Verify by fetching fresh copy
        fresh_post = PartialFetchPost.find(post_id)

        assert_equal "Updated Title", fresh_post.title, "Title should be updated"
        assert_equal "Original Content", fresh_post.content, "Content should not be changed"
        assert_equal 100, fresh_post.view_count, "View count should not be changed"
        assert fresh_post.is_published, "is_published should not be changed"

        puts "Partial fetch save only updates changed fields"
      end
    end
  end

  def test_partial_fetch_with_associations
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "partial fetch with associations test") do
        puts "\n=== Testing Partial Fetch with Associations ==="

        # Create user
        user = PartialFetchUser.new(
          name: "Test User",
          email: "test@example.com",
          age: 30,
        )
        assert user.save, "User should save"

        # Create post with author
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          author: user,
        )
        assert post.save, "Post should save"

        # Fetch post with only title and author
        fetched_post = PartialFetchPost.first(keys: [:title, :author])

        # Should be partially fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Author should be fetched (as a pointer)
        assert fetched_post.field_was_fetched?(:author), "author should be marked as fetched"

        # Content should not be fetched
        refute fetched_post.field_was_fetched?(:content), "content should not be fetched"

        puts "Partial fetch with associations works correctly"
      end
    end
  end

  def test_partial_fetch_id_always_included
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "id always included test") do
        puts "\n=== Testing :id Always Included in Fetched Keys ==="

        # Create post
        post = PartialFetchPost.new(title: "Test Post")
        assert post.save, "Post should save"

        # Fetch with keys that don't include :id
        fetched_post = PartialFetchPost.first(keys: [:title])

        # :id should still be in fetched_keys
        assert fetched_post.fetched_keys.include?(:id), ":id should be in fetched_keys"
        assert fetched_post.fetched_keys.include?(:objectId), ":objectId should be in fetched_keys"

        # id should be available
        assert fetched_post.id.present?, "id should be available"

        # field_was_fetched? should return true for id
        assert fetched_post.field_was_fetched?(:id), "id should be marked as fetched"

        puts ":id is always included in fetched keys"
      end
    end
  end

  def test_partial_fetch_base_keys_always_fetched
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "base keys always fetched test") do
        puts "\n=== Testing Base Keys Always Considered Fetched ==="

        # Create post
        post = PartialFetchPost.new(title: "Test Post")
        assert post.save, "Post should save"

        # Fetch with minimal keys
        fetched_post = PartialFetchPost.first(keys: [:title])

        # Base keys should always be considered fetched
        assert fetched_post.field_was_fetched?(:id), "id should be considered fetched"
        assert fetched_post.field_was_fetched?(:created_at), "created_at should be considered fetched"
        assert fetched_post.field_was_fetched?(:updated_at), "updated_at should be considered fetched"
        assert fetched_post.field_was_fetched?(:acl), "acl should be considered fetched"

        puts "Base keys are always considered fetched"
      end
    end
  end

  def test_partial_fetch_with_query_methods
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "partial fetch with query methods test") do
        puts "\n=== Testing Partial Fetch with Query Methods ==="

        # Create posts
        post1 = PartialFetchPost.new(title: "Post 1", category: "tech", view_count: 100)
        assert post1.save, "Post 1 should save"

        post2 = PartialFetchPost.new(title: "Post 2", category: "tech", view_count: 200)
        assert post2.save, "Post 2 should save"

        # Test with .all
        posts = PartialFetchPost.query.keys(:title).all
        posts.each do |p|
          assert p.partially_fetched?, "Post should be partially fetched"
        end

        # Test with .results
        results = PartialFetchPost.query.keys(:title, :view_count).results
        results.each do |p|
          assert p.partially_fetched?, "Post should be partially fetched"
          assert p.field_was_fetched?(:title)
          assert p.field_was_fetched?(:view_count)
          refute p.field_was_fetched?(:content)
        end

        puts "Partial fetch works with all query methods"
      end
    end
  end

  def test_partial_fetch_remote_field_name_support
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "remote field name support test") do
        puts "\n=== Testing Partial Fetch Remote Field Name Support ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          view_count: 100,
          is_published: true,
        )
        assert post.save, "Post should save"

        # Fetch with local field names
        fetched_post = PartialFetchPost.first(keys: [:title, :view_count, :is_published])

        # Check both local and remote names work with field_was_fetched?
        assert fetched_post.field_was_fetched?(:title), "local name :title should be fetched"
        assert fetched_post.field_was_fetched?(:view_count), "local name :view_count should be fetched"
        assert fetched_post.field_was_fetched?(:is_published), "local name :is_published should be fetched"

        puts "Remote field name support works correctly"
      end
    end
  end

  def test_partial_fetch_changes_not_include_unfetched_defaults
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "changes not include unfetched defaults test") do
        puts "\n=== Testing Changes Don't Include Unfetched Defaults ==="

        # Create post with specific values for defaults
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          view_count: 50,
          is_published: true,
          is_featured: true,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch with only title
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # Changes should be empty
        assert_empty fetched_post.changes, "Changes should be empty"

        # Modify only the title
        fetched_post.title = "New Title"

        # Only title should be in changes
        assert_equal ["title"], fetched_post.changed, "Only title should be changed"

        # Save and verify
        assert fetched_post.save, "Save should succeed"

        # Verify other fields weren't affected
        fresh_post = PartialFetchPost.find(post_id)
        assert_equal "New Title", fresh_post.title
        assert_equal 50, fresh_post.view_count, "view_count should not be changed"
        assert fresh_post.is_published, "is_published should not be changed"
        assert fresh_post.is_featured, "is_featured should not be changed"

        puts "Changes don't include unfetched defaults"
      end
    end
  end

  def test_multiple_partial_fetches_independent
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "multiple partial fetches independent test") do
        puts "\n=== Testing Multiple Partial Fetches Are Independent ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          category: "tech",
        )
        assert post.save, "Post should save"

        # Fetch with different keys
        fetch1 = PartialFetchPost.first(keys: [:title])
        fetch2 = PartialFetchPost.first(keys: [:content])

        # Both should be partially fetched with different keys
        assert fetch1.partially_fetched?, "First fetch should be partially fetched"
        assert fetch2.partially_fetched?, "Second fetch should be partially fetched"

        # They should have different fetched keys
        assert fetch1.field_was_fetched?(:title)
        refute fetch1.field_was_fetched?(:content)

        refute fetch2.field_was_fetched?(:title)
        assert fetch2.field_was_fetched?(:content)

        puts "Multiple partial fetches are independent"
      end
    end
  end

  def test_nested_partial_fetch_with_keys
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "nested partial fetch with keys test") do
        puts "\n=== Testing Nested Partial Fetch with Keys ==="

        # Create user with all fields
        user = PartialFetchUser.new(
          name: "Test User",
          email: "test@example.com",
          age: 30,
          is_active: true,
          is_verified: true,
          settings: { theme: "dark" },
        )
        assert user.save, "User should save"

        # Create post with author
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          author: user,
        )
        assert post.save, "Post should save"

        # Fetch post with keys using dot notation for nested field selection
        # keys: ["title", "author.name", "author.email"] - specifies which fields to fetch
        # Note: includes is NOT needed - Parse auto-resolves pointers when using dot notation in keys
        fetched_post = PartialFetchPost.query
                                       .keys(:title, "author.name", "author.email")
                                       .first

        # Post should be partially fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Check nested fetched keys were set (parsed from keys, not includes)
        nested_keys = fetched_post.nested_keys_for(:author)
        assert nested_keys.present?, "Should have nested keys for author"
        assert nested_keys.include?(:name), "Nested keys should include name"
        assert nested_keys.include?(:email), "Nested keys should include email"

        # Access the author - it should be built with partial fetch keys
        author = fetched_post.author
        assert author.present?, "Author should be present"

        # Author should be partially fetched
        if author.respond_to?(:partially_fetched?)
          assert author.partially_fetched?, "Author should be partially fetched"
          assert author.field_was_fetched?(:name), "Author name should be fetched"
          assert author.field_was_fetched?(:email), "Author email should be fetched"
          refute author.field_was_fetched?(:age), "Author age should not be fetched"
          refute author.field_was_fetched?(:settings), "Author settings should not be fetched"
        end

        puts "Nested partial fetch with keys works correctly"
      end
    end
  end

  def test_nested_partial_fetch_autofetches_nested_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "nested partial fetch autofetch test") do
        puts "\n=== Testing Nested Partial Fetch Autofetches Nested Fields ==="

        # Create user
        original_age = 35
        user = PartialFetchUser.new(
          name: "Test User",
          email: "test@example.com",
          age: original_age,
        )
        assert user.save, "User should save"

        # Create post with author
        post = PartialFetchPost.new(
          title: "Test Post",
          author: user,
        )
        assert post.save, "Post should save"

        # Fetch post with keys specifying which nested fields to fetch
        # keys: ["title", "author.name"] defines nested field tracking
        # Note: includes is NOT needed - Parse auto-resolves pointers when using dot notation
        fetched_post = PartialFetchPost.query
                                       .keys(:title, "author.name")
                                       .first

        # Get the author
        author = fetched_post.author
        assert author.present?, "Author should be present"

        # If author is partially fetched, accessing age should trigger autofetch
        if author.respond_to?(:partially_fetched?) && author.partially_fetched?
          # Access the age - this should trigger autofetch
          actual_age = author.age

          # Age should match original (autofetch worked)
          assert_equal original_age, actual_age, "Age should match after autofetch"

          # Note: After autofetch, the author object is refreshed with full data
          # The partially_fetched? state may or may not be cleared depending on how
          # the object was fetched (direct fetch vs nested object)
        else
          # If not partially fetched, just verify the age is correct
          assert_equal original_age, author.age, "Age should be accessible"
        end

        puts "Nested partial fetch autofetches nested fields correctly"
      end
    end
  end

  def test_parse_keys_to_nested_keys
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "parse keys to nested keys test") do
        puts "\n=== Testing parse_keys_to_nested_keys ==="

        # Test parsing keys with dot notation for nested fields
        # Top-level keys like :title are skipped (not nested)
        # Keys with dots like "author.name" define nested field tracking
        keys = [:title, "author.name", "author.email", "team.manager"]
        nested_keys = Parse::Query.parse_keys_to_nested_keys(keys)

        # Top-level key :title should not create an entry
        refute nested_keys.key?(:title), "Top-level keys should not create entries"

        # Check author has name and email
        assert nested_keys[:author].present?, "Should have nested keys for author"
        assert nested_keys[:author].include?(:name), "Author should have name"
        assert nested_keys[:author].include?(:email), "Author should have email"

        # Check team has manager
        assert nested_keys[:team].present?, "Should have nested keys for team"
        assert nested_keys[:team].include?(:manager), "Team should have manager"

        puts "parse_keys_to_nested_keys works correctly"
      end
    end
  end

  def test_assignment_to_unfetched_field_does_not_trigger_autofetch
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "assignment no autofetch test") do
        puts "\n=== Testing Assignment to Unfetched Field Does Not Trigger Autofetch ==="

        # Create post with content
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Original Content",
          category: "tech",
          view_count: 100,
        )
        assert post.save, "Post should save"

        # Fetch with only :title (content is not fetched)
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # Verify it's partially fetched and content was not fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        refute fetched_post.field_was_fetched?(:content), "Content should not be fetched initially"

        # Assign to unfetched field - this should NOT trigger autofetch
        # The object should still be partially fetched (not fully fetched)
        fetched_post.content = "New Content"

        # After assignment, content should now be marked as fetched
        # (since we've defined its value, no need to fetch from server)
        assert fetched_post.field_was_fetched?(:content), "Content should be marked as fetched after assignment"

        # Other unfetched fields should still not be fetched
        refute fetched_post.field_was_fetched?(:category), "Category should still not be fetched"
        refute fetched_post.field_was_fetched?(:view_count), "View count should still not be fetched"

        # The object should still be considered partially fetched
        # (because other fields like category and view_count are still not fetched)
        assert fetched_post.partially_fetched?, "Post should still be partially fetched"

        puts "Assignment to unfetched field does not trigger autofetch"
      end
    end
  end

  def test_assignment_to_unfetched_field_tracks_changes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "assignment change tracking test") do
        puts "\n=== Testing Assignment to Unfetched Field Tracks Changes ==="

        # Create post with content
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Original Content",
          category: "tech",
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch with only :title (content is not fetched)
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # Verify initial state
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        assert_empty fetched_post.changed, "No fields should be changed initially"

        # Assign to unfetched field
        fetched_post.content = "New Content"

        # The field should be marked as changed
        assert fetched_post.content_changed?, "Content should be marked as changed"
        assert_includes fetched_post.changed, "content", "Changed array should include content"

        # Save and verify the change was persisted
        assert fetched_post.save, "Save should succeed"

        # Fetch fresh copy to verify
        fresh_post = PartialFetchPost.find(post_id)
        assert_equal "New Content", fresh_post.content, "Content should be updated"
        assert_equal "Test Post", fresh_post.title, "Title should be unchanged"
        assert_equal "tech", fresh_post.category, "Category should be unchanged"

        puts "Assignment to unfetched field tracks changes correctly"
      end
    end
  end

  def test_multiple_assignments_to_unfetched_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "multiple assignments test") do
        puts "\n=== Testing Multiple Assignments to Unfetched Fields ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Original Content",
          category: "original",
          view_count: 50,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch with only :id
        fetched_post = PartialFetchPost.first(keys: [:id])

        # Verify initial state
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Assign to multiple unfetched fields
        fetched_post.title = "New Title"
        fetched_post.content = "New Content"
        fetched_post.category = "new"

        # All fields should be marked as changed
        assert_includes fetched_post.changed, "title", "Title should be changed"
        assert_includes fetched_post.changed, "content", "Content should be changed"
        assert_includes fetched_post.changed, "category", "Category should be changed"

        # All assigned fields should now be marked as fetched
        assert fetched_post.field_was_fetched?(:title), "Title should be fetched"
        assert fetched_post.field_was_fetched?(:content), "Content should be fetched"
        assert fetched_post.field_was_fetched?(:category), "Category should be fetched"

        # Unassigned fields should still not be fetched
        refute fetched_post.field_was_fetched?(:view_count), "View count should not be fetched"

        # Save and verify
        assert fetched_post.save, "Save should succeed"

        fresh_post = PartialFetchPost.find(post_id)
        assert_equal "New Title", fresh_post.title
        assert_equal "New Content", fresh_post.content
        assert_equal "new", fresh_post.category
        assert_equal 50, fresh_post.view_count, "View count should be unchanged"

        puts "Multiple assignments to unfetched fields work correctly"
      end
    end
  end

  def test_assignment_with_same_value_does_not_mark_changed
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "same value assignment test") do
        puts "\n=== Testing Assignment with Same Value Does Not Mark Changed ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
        )
        assert post.save, "Post should save"

        # Fetch with :title
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # Assign same value to title
        fetched_post.title = "Test Post"

        # Title should not be marked as changed (same value)
        refute fetched_post.title_changed?, "Title should not be marked as changed"
        assert_empty fetched_post.changed, "No fields should be changed"

        puts "Assignment with same value does not mark changed"
      end
    end
  end

  def test_belongs_to_assignment_to_unfetched_field_tracks_changes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "belongs_to assignment test") do
        puts "\n=== Testing belongs_to Assignment to Unfetched Field Tracks Changes ==="

        # Create users
        user1 = PartialFetchUser.new(name: "User 1", email: "user1@example.com")
        assert user1.save, "User 1 should save"

        user2 = PartialFetchUser.new(name: "User 2", email: "user2@example.com")
        assert user2.save, "User 2 should save"

        # Create post with author
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          author: user1,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch with only :title (author is not fetched)
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # Verify initial state
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        refute fetched_post.field_was_fetched?(:author), "Author should not be fetched initially"

        # Assign to unfetched belongs_to field
        fetched_post.author = user2

        # Author should be marked as changed
        assert fetched_post.author_changed?, "Author should be marked as changed"
        assert_includes fetched_post.changed, "author", "Changed array should include author"

        # Author should now be marked as fetched
        assert fetched_post.field_was_fetched?(:author), "Author should be marked as fetched after assignment"

        # Save and verify
        assert fetched_post.save, "Save should succeed"

        fresh_post = PartialFetchPost.first(includes: :author)
        assert_equal user2.id, fresh_post.author.id, "Author should be updated to user2"

        puts "belongs_to assignment to unfetched field tracks changes correctly"
      end
    end
  end

  def test_belongs_to_unfetched_field_triggers_autofetch
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "belongs_to autofetch test") do
        puts "\n=== Testing belongs_to Unfetched Field Triggers Autofetch ==="

        # Create user and post with author
        user = PartialFetchUser.new(name: "Test Author", email: "author@example.com")
        assert user.save, "User should save"

        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          author: user,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch post with only [:id, :title] (author is NOT included)
        fetched_post = PartialFetchPost.first(id: post_id, keys: [:id, :title])

        # Verify it's partially fetched and author was not fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        refute fetched_post.field_was_fetched?(:author), "Author should not be fetched initially"

        # Access the author field - this should trigger autofetch
        author_result = fetched_post.author

        # Author should not be nil (this was the bug)
        refute_nil author_result, "Author should not be nil after autofetch"
        assert_instance_of PartialFetchUser, author_result, "Author should be a PartialFetchUser"
        assert_equal user.id, author_result.id, "Author should have correct id"

        puts "belongs_to unfetched field correctly triggers autofetch"
      end
    end
  end

  def test_belongs_to_unfetched_field_with_autofetch_disabled_raises_error
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "belongs_to error test") do
        puts "\n=== Testing belongs_to Unfetched Field with Autofetch Disabled Raises Error ==="

        # Create user and post with author
        user = PartialFetchUser.new(name: "Test Author", email: "author@example.com")
        assert user.save, "User should save"

        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          author: user,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch post with only [:id, :title]
        fetched_post = PartialFetchPost.first(id: post_id, keys: [:id, :title])

        # Disable autofetch on the fetched object
        fetched_post.disable_autofetch!

        # Verify it's partially fetched and autofetch is disabled
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        assert fetched_post.autofetch_disabled?, "Autofetch should be disabled"

        # Accessing unfetched author should raise error
        error = assert_raises(Parse::UnfetchedFieldAccessError) do
          fetched_post.author
        end

        assert_match(/author/, error.message, "Error should mention the field name")

        puts "belongs_to unfetched field with autofetch disabled correctly raises error"
      end
    end
  end

  def test_has_many_unfetched_field_triggers_autofetch
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "has_many autofetch test") do
        puts "\n=== Testing has_many Unfetched Field Triggers Autofetch ==="

        # Create a post with a tags array
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          tags: ["ruby", "testing", "parse"],
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch post with only [:id, :title] (tags array is NOT included)
        fetched_post = PartialFetchPost.first(id: post_id, keys: [:id, :title])

        # Verify it's partially fetched and tags was not fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        refute fetched_post.field_was_fetched?(:tags), "Tags should not be fetched initially"

        # Access the tags field - this should trigger autofetch for array fields
        tags_result = fetched_post.tags

        # Tags should not be nil after autofetch (for array fields, they get autofetched)
        refute_nil tags_result, "Tags should not be nil after autofetch"
        assert_equal ["ruby", "testing", "parse"], tags_result, "Tags should have correct values"

        puts "has_many/array unfetched field correctly triggers autofetch"
      end
    end
  end

  def test_fetch_preserves_local_changes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "fetch preserves changes test") do
        puts "\n=== Testing fetch! Preserves Local Changes with preserve_changes: true ==="

        # Create a post
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
          category: "tech",
          view_count: 100,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch the post
        fetched_post = PartialFetchPost.find(post_id)
        assert_equal "Original Title", fetched_post.title
        assert_equal "Original Content", fetched_post.content
        assert_equal "tech", fetched_post.category

        # Make local changes without saving
        fetched_post.title = "Modified Title"
        fetched_post.category = "updated"

        # Verify changes are tracked
        assert fetched_post.title_changed?, "Title should be marked as changed"
        assert fetched_post.category_changed?, "Category should be marked as changed"
        assert_equal "Original Title", fetched_post.title_was, "Title was should be original"
        assert_equal "tech", fetched_post.category_was, "Category was should be original"

        # Fetch from server with preserve_changes: true (server still has original values)
        fetched_post.fetch(preserve_changes: true)

        # Local changes should be preserved
        assert_equal "Modified Title", fetched_post.title, "Local title change should be preserved"
        assert_equal "updated", fetched_post.category, "Local category change should be preserved"

        # Unchanged field should have server value
        assert_equal "Original Content", fetched_post.content, "Unchanged field should have server value"
        assert_equal 100, fetched_post.view_count, "Unchanged field should have server value"

        # Changes should still be tracked
        assert fetched_post.title_changed?, "Title should still be marked as changed"
        assert fetched_post.category_changed?, "Category should still be marked as changed"

        # And _was methods should still work correctly
        assert_equal "Original Title", fetched_post.title_was, "Title was should still be original"
        assert_equal "tech", fetched_post.category_was, "Category was should still be original"

        puts "fetch! correctly preserves local changes with preserve_changes: true"
      end
    end
  end

  def test_fetch_updates_unchanged_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "fetch updates unchanged fields test") do
        puts "\n=== Testing fetch! Updates Unchanged Fields with preserve_changes: true ==="

        # Create a post
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch the post
        fetched_post = PartialFetchPost.find(post_id)

        # Make a local change to one field
        fetched_post.title = "Modified Title"

        # Update the content on the server (simulating another client)
        updated_post = PartialFetchPost.find(post_id)
        updated_post.content = "Updated Content from Server"
        assert updated_post.save, "Server update should save"

        # Fetch should update the unchanged field but preserve the local change
        fetched_post.fetch(preserve_changes: true)

        # Local change preserved
        assert_equal "Modified Title", fetched_post.title, "Local title change should be preserved"

        # Server update applied to unchanged field
        assert_equal "Updated Content from Server", fetched_post.content, "Server update should be applied"

        # Only title should be marked as changed
        assert fetched_post.title_changed?, "Title should be marked as changed"
        refute fetched_post.content_changed?, "Content should not be marked as changed"

        puts "fetch! correctly updates unchanged fields while preserving local changes"
      end
    end
  end

  # Tests for new fetch(keys:, includes:) functionality

  def test_fetch_with_keys_creates_partial_fetch
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "fetch with keys test") do
        puts "\n=== Testing fetch(keys:) Creates Partial Fetch ==="

        # Create test post with full data
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
          category: "tech",
          view_count: 100,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Create a fresh pointer to the post
        pointer = PartialFetchPost.pointer(post_id)
        assert pointer.pointer?, "Should be a pointer"

        # Fetch with specific keys - Pointer#fetch returns a NEW object
        fetched_post = pointer.fetch(keys: [:title, :category])

        # Check that returned object is partially fetched
        assert fetched_post.partially_fetched?, "Should be marked as partially fetched after fetch(keys:)"
        assert fetched_post.field_was_fetched?(:title), "title should be fetched"
        assert fetched_post.field_was_fetched?(:category), "category should be fetched"
        refute fetched_post.field_was_fetched?(:content), "content should not be fetched"
        refute fetched_post.field_was_fetched?(:view_count), "view_count should not be fetched"

        # Verify values are correct
        assert_equal "Test Title", fetched_post.title
        assert_equal "tech", fetched_post.category

        puts "fetch(keys:) correctly creates partial fetch"
      end
    end
  end

  def test_fetch_with_keys_merges_with_existing_partial_fetch
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "fetch with keys merging test") do
        puts "\n=== Testing fetch(keys:) Merges with Existing Partial Fetch ==="

        # Create test post with full data
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
          category: "tech",
          view_count: 100,
        )
        assert post.save, "Post should save"

        # First partial fetch with title
        fetched_post = PartialFetchPost.first(keys: [:title])
        assert fetched_post.partially_fetched?, "Should be partially fetched"
        assert fetched_post.field_was_fetched?(:title), "title should be fetched"
        refute fetched_post.field_was_fetched?(:category), "category should not be fetched"

        # Second partial fetch with category - should merge
        fetched_post.fetch(keys: [:category, :view_count])

        # Check that all keys are now tracked
        assert fetched_post.partially_fetched?, "Should still be partially fetched"
        assert fetched_post.field_was_fetched?(:title), "title should still be fetched"
        assert fetched_post.field_was_fetched?(:category), "category should now be fetched"
        assert fetched_post.field_was_fetched?(:view_count), "view_count should now be fetched"
        refute fetched_post.field_was_fetched?(:content), "content should still not be fetched"

        # Verify values are correct
        assert_equal "Test Title", fetched_post.title
        assert_equal "tech", fetched_post.category
        assert_equal 100, fetched_post.view_count

        puts "fetch(keys:) correctly merges with existing partial fetch"
      end
    end
  end

  def test_fetch_with_keys_and_includes_expands_pointers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "fetch with keys and includes test") do
        puts "\n=== Testing fetch(keys:, includes:) Expands Pointers ==="

        # Create test user
        user = PartialFetchUser.new(
          name: "Test Author",
          email: "author@test.com",
          age: 30,
        )
        assert user.save, "User should save"

        # Create test post with author
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
          author: user,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Create a fresh pointer and fetch with keys using dot notation
        # Note: Pointer#fetch returns a NEW object (unlike Object#fetch which updates self)
        pointer = PartialFetchPost.pointer(post_id)
        fetched_post = pointer.fetch(keys: [:title, "author.name", "author.email"])

        # Check that fetched_post is partially fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        assert fetched_post.field_was_fetched?(:title), "title should be fetched"
        refute fetched_post.field_was_fetched?(:content), "content should not be fetched"

        # Check that author is expanded and partially fetched
        author = fetched_post.author
        refute author.pointer?, "Author should not be a pointer"
        assert author.partially_fetched?, "Author should be partially fetched"
        assert author.field_was_fetched?(:name), "author.name should be fetched"
        assert author.field_was_fetched?(:email), "author.email should be fetched"
        refute author.field_was_fetched?(:age), "author.age should not be fetched"

        # Verify values are correct
        assert_equal "Test Title", fetched_post.title
        assert_equal "Test Author", author.name
        assert_equal "author@test.com", author.email

        puts "fetch(keys:, includes:) correctly expands pointers with partial fetch"
      end
    end
  end

  def test_fetch_without_keys_clears_partial_fetch_state
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "full fetch clears partial fetch state test") do
        puts "\n=== Testing Full fetch Clears Partial Fetch State ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
          category: "tech",
        )
        assert post.save, "Post should save"

        # First partial fetch
        fetched_post = PartialFetchPost.first(keys: [:title])
        assert fetched_post.partially_fetched?, "Should be partially fetched"

        # Full fetch should clear partial fetch state
        fetched_post.fetch

        refute fetched_post.partially_fetched?, "Should not be partially fetched after full fetch"

        # All fields should now be accessible
        assert_equal "Test Title", fetched_post.title
        assert_equal "Test Content", fetched_post.content
        assert_equal "tech", fetched_post.category

        puts "Full fetch correctly clears partial fetch state"
      end
    end
  end

  def test_fetch_json_returns_raw_data
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "fetch_json test") do
        puts "\n=== Testing fetch_json Returns Raw Data ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Create pointer and fetch as JSON
        pointer = PartialFetchPost.pointer(post_id)
        json = pointer.fetch_json(keys: [:title])

        # Should return a hash
        assert json.is_a?(Hash), "Should return a Hash"
        assert_equal "Test Title", json["title"]
        # content should not be in the response since we only asked for title
        refute json.key?("content"), "content should not be in partial response"

        # Pointer should still be a pointer (not updated)
        assert pointer.pointer?, "Pointer should still be a pointer after fetch_json"

        puts "fetch_json correctly returns raw data without updating object"
      end
    end
  end

  def test_legacy_fetch_signature_backward_compatibility
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "legacy fetch signature test") do
        puts "\n=== Testing Legacy fetch(true/false) Backward Compatibility ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Test fetch(true) on Pointer - returns a new fetched object (not self)
        pointer1 = PartialFetchPost.pointer(post_id)
        fetched = pointer1.fetch(true)
        assert fetched.is_a?(PartialFetchPost), "fetch(true) should return a PartialFetchPost"
        refute fetched.pointer?, "Returned object should not be a pointer"
        assert_equal "Test Title", fetched.title

        # Test fetch(false) - should return JSON hash
        pointer2 = PartialFetchPost.pointer(post_id)
        json = pointer2.fetch(false)
        assert json.is_a?(Hash), "fetch(false) should return a Hash"
        assert_equal "Test Title", json["title"]
        assert pointer2.pointer?, "Original pointer should still be a pointer after fetch(false)"

        # Test fetch on Object (not Pointer) - updates self
        obj = PartialFetchPost.find(post_id)
        result = obj.fetch
        assert_equal obj, result, "Object#fetch should return self"

        puts "Legacy fetch(true/false) signatures work correctly"
      end
    end
  end

  # Tests for smart change reconciliation during partial fetch

  def test_partial_fetch_preserves_unfetched_field_values
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "partial fetch preserves unfetched fields test") do
        puts "\n=== Testing Partial Fetch Preserves Unfetched Field Values ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
          category: "tech",
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch post fully
        fetched_post = PartialFetchPost.find(post_id)
        assert_equal "Original Content", fetched_post.content

        # Do a partial fetch for just title
        fetched_post.fetch(keys: [:title])

        # content should still have its value (unfetched fields preserved)
        assert_equal "Original Content", fetched_post.content
        # title should have its value
        assert_equal "Original Title", fetched_post.title

        puts "Partial fetch correctly preserves unfetched field values"
      end
    end
  end

  def test_partial_fetch_preserves_dirty_state_for_unfetched_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "partial fetch preserves dirty state test") do
        puts "\n=== Testing Partial Fetch Preserves Dirty State for Unfetched Fields ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch post and modify content
        fetched_post = PartialFetchPost.find(post_id)
        fetched_post.content = "Modified Content"
        assert fetched_post.content_changed?, "content should be dirty"

        # Do a partial fetch for just title (not content)
        fetched_post.fetch(keys: [:title])

        # content should still be dirty with modified value
        assert_equal "Modified Content", fetched_post.content
        assert fetched_post.content_changed?, "content should still be dirty after partial fetch"

        puts "Partial fetch correctly preserves dirty state for unfetched fields"
      end
    end
  end

  def test_partial_fetch_clears_dirty_when_server_matches_local
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "partial fetch clears dirty when values match test") do
        puts "\n=== Testing Partial Fetch Clears Dirty When Server Matches Local ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch post and modify content
        fetched_post = PartialFetchPost.find(post_id)
        fetched_post.content = "Modified Content"
        assert fetched_post.content_changed?, "content should be marked as dirty"

        # Simulate another client saving the same value we have locally
        other_client_post = PartialFetchPost.find(post_id)
        other_client_post.content = "Modified Content"
        assert other_client_post.save, "Other client save should succeed"

        # Do a partial fetch that includes content
        # Server now has "Modified Content" which matches our local dirty value
        fetched_post.fetch(keys: [:content])

        # Since server value matches local dirty value, should clear dirty state
        assert_equal "Modified Content", fetched_post.content
        refute fetched_post.content_changed?, "content should NOT be dirty when server matches local"

        puts "Partial fetch correctly clears dirty state when server matches local value"
      end
    end
  end

  def test_partial_fetch_keeps_dirty_when_server_differs_from_local
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "partial fetch keeps dirty when values differ test") do
        puts "\n=== Testing Partial Fetch Keeps Dirty When Server Differs (with preserve_changes) ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch post and modify content to different value
        fetched_post = PartialFetchPost.find(post_id)
        fetched_post.content = "User Modified Content"
        assert fetched_post.content_changed?, "content should be dirty"

        # Do a partial fetch that includes content with preserve_changes: true
        fetched_post.fetch(keys: [:content], preserve_changes: true)

        # Since preserve_changes: true, keep dirty state with local value
        assert_equal "User Modified Content", fetched_post.content
        assert fetched_post.content_changed?, "content should still be dirty when preserve_changes: true"

        puts "Partial fetch correctly keeps dirty state with preserve_changes: true"
      end
    end
  end

  def test_partial_fetch_updates_base_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "partial fetch updates base fields test") do
        puts "\n=== Testing Partial Fetch Updates Base Fields ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
        )
        assert post.save, "Post should save"
        post_id = post.id
        original_updated_at = post.updated_at

        # Wait a moment and update on server
        sleep 1
        server_post = PartialFetchPost.find(post_id)
        server_post.title = "Server Updated Title"
        assert server_post.save, "Server update should save"

        # Fetch original post partially (title only)
        post.fetch(keys: [:title])

        # Base fields like updated_at should be updated from server
        assert post.updated_at > original_updated_at, "updated_at should be updated from server"
        assert_equal "Server Updated Title", post.title

        puts "Partial fetch correctly updates base fields"
      end
    end
  end

  def test_partial_fetch_with_nested_field_triggers_autofetch
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "partial fetch nested field autofetch test") do
        puts "\n=== Testing Partial Fetch with Nested Field Triggers Autofetch ==="

        # Create test user with all fields
        user = PartialFetchUser.new(
          name: "Test Author",
          email: "author@test.com",
          age: 30,
        )
        assert user.save, "User should save"

        # Create test post with author
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
          author: user,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch post with nested field (author.name only)
        # Note: Pointer#fetch returns a NEW object
        pointer = PartialFetchPost.pointer(post_id)
        fetched_post = pointer.fetch(keys: ["author.name"])

        # Author should be partially fetched with just name
        author = fetched_post.author
        assert author.present?, "Author should be present"
        refute author.pointer?, "Author should not be a pointer"

        if author.partially_fetched?
          assert author.field_was_fetched?(:name), "name should be fetched"
          refute author.field_was_fetched?(:age), "age should not be fetched"

          # Accessing unfetched field should trigger autofetch
          age = author.age
          assert_equal 30, age, "age should be accessible after autofetch"
          refute author.partially_fetched?, "Author should be fully fetched after autofetch"
        end

        puts "Partial fetch with nested field correctly triggers autofetch"
      end
    end
  end

  def test_incremental_partial_fetch_merges_keys
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "incremental partial fetch test") do
        puts "\n=== Testing Incremental Partial Fetch Merges Keys ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
          category: "tech",
          view_count: 100,
        )
        assert post.save, "Post should save"

        # First partial fetch via query - just title
        fetched_post = PartialFetchPost.first(keys: [:title])

        assert fetched_post.partially_fetched?, "Should be partially fetched"
        assert fetched_post.field_was_fetched?(:title), "title should be fetched"
        refute fetched_post.field_was_fetched?(:content), "content should not be fetched yet"

        # Second partial fetch on the object - add content
        # Object#fetch updates self (unlike Pointer#fetch which returns new object)
        fetched_post.fetch(keys: [:content])

        assert fetched_post.partially_fetched?, "Should still be partially fetched"
        assert fetched_post.field_was_fetched?(:title), "title should still be tracked as fetched"
        assert fetched_post.field_was_fetched?(:content), "content should now be fetched"
        refute fetched_post.field_was_fetched?(:category), "category should not be fetched"

        # Values should be correct
        assert_equal "Test Title", fetched_post.title
        assert_equal "Test Content", fetched_post.content

        puts "Incremental partial fetch correctly merges keys"
      end
    end
  end

  def test_incremental_nested_keys_merging
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "incremental nested keys merging test") do
        puts "\n=== Testing Incremental Nested Keys Merging ==="

        # Create user (author)
        user = PartialFetchUser.new(
          name: "Test Author",
          email: "author@test.com",
          age: 30,
        )
        assert user.save, "User should save"

        # Create post with author
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
          author: user,
        )
        assert post.save, "Post should save"

        # First partial fetch with author.name via query
        fetched_post = PartialFetchPost.query(:objectId => post.id)
                                       .keys(:title, "author.name")
                                       .first

        assert fetched_post.partially_fetched?, "Should be partially fetched"
        assert fetched_post.field_was_fetched?(:title), "title should be fetched"

        # Check initial nested keys (nested keys track subfields, not the pointer field itself)
        nested_keys_before = fetched_post.nested_keys_for(:author)
        assert nested_keys_before.present?, "Should have nested keys for author"
        assert nested_keys_before.include?(:name), "Nested keys should include name"
        refute nested_keys_before.include?(:email), "Nested keys should not include email yet"

        # Capture the author's name before second fetch
        initial_author_name = fetched_post.author&.name
        assert_equal "Test Author", initial_author_name, "Author name should be accessible"

        # Second partial fetch - add content field and author.email
        # Note: When fetching new nested fields, include both old and new if you need both values
        # The nested keys tracking merges automatically, but Parse only returns what you request
        fetched_post.fetch(keys: [:content, "author.email"])

        # Now nested keys should include both name and email (merged)
        nested_keys_after = fetched_post.nested_keys_for(:author)
        assert nested_keys_after.present?, "Should still have nested keys for author"
        assert nested_keys_after.include?(:name), "Nested keys should still include name (merged)"
        assert nested_keys_after.include?(:email), "Nested keys should now include email (added)"

        # Content should now be fetched
        assert fetched_post.field_was_fetched?(:content), "content should now be fetched"
        assert_equal "Test Content", fetched_post.content

        # Author email is now available
        author = fetched_post.author
        assert author.present?, "Author should be present"
        assert_equal "author@test.com", author.email, "Author email should be accessible"

        puts "Incremental nested keys merging works correctly"
      end
    end
  end

  def test_fetch_default_discards_local_changes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "fetch default discards changes test") do
        puts "\n=== Testing fetch Default Behavior Discards Local Changes ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch post and modify title
        fetched_post = PartialFetchPost.find(post_id)
        fetched_post.title = "Modified Title"
        assert fetched_post.title_changed?, "title should be dirty"

        # Default fetch (without preserve_changes) should discard local changes
        fetched_post.fetch

        # Local changes should be discarded, server value applied
        assert_equal "Original Title", fetched_post.title, "Default fetch should discard local changes"
        refute fetched_post.title_changed?, "title should no longer be dirty"

        puts "Default fetch correctly discards local changes"
      end
    end
  end

  def test_fetch_preserve_changes_vs_default
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "fetch preserve_changes vs default test") do
        puts "\n=== Testing fetch preserve_changes: true vs Default ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Test 1: Default behavior (discard changes)
        post1 = PartialFetchPost.find(post_id)
        post1.title = "Modified Title 1"
        post1.fetch  # Default: preserve_changes: false
        assert_equal "Original Title", post1.title, "Default fetch should discard"
        refute post1.title_changed?, "Should not be dirty after default fetch"

        # Test 2: preserve_changes: true (keep local)
        post2 = PartialFetchPost.find(post_id)
        post2.title = "Modified Title 2"
        post2.fetch(preserve_changes: true)
        assert_equal "Modified Title 2", post2.title, "preserve_changes: true should keep local"
        assert post2.title_changed?, "Should still be dirty with preserve_changes: true"

        # Test 3: Unfetched fields always preserve dirty state
        post3 = PartialFetchPost.find(post_id)
        post3.content = "Modified Content"
        post3.fetch(keys: [:title])  # Only fetch title, not content
        assert_equal "Modified Content", post3.content, "Unfetched dirty field should be preserved"
        assert post3.content_changed?, "Unfetched dirty field should stay dirty"

        puts "fetch preserve_changes behavior works correctly"
      end
    end
  end

  def test_autofetch_raises_error_when_object_deleted
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "autofetch error on deleted object test") do
        puts "\n=== Testing Autofetch Raises Error When Object Deleted ==="

        # Create test post with all fields
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Test Content",
          category: "tech",
          view_count: 100,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch with only :title (partial fetch)
        fetched_post = PartialFetchPost.first(keys: [:title])
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        assert_equal post_id, fetched_post.id

        # Delete the post from the server
        assert post.destroy, "Post should be deleted"

        # Accessing an unfetched field should trigger autofetch
        # Since the object was deleted, autofetch should raise an error
        error_raised = false
        begin
          # Accessing :content (unfetched field) should trigger autofetch
          # which should fail because the object no longer exists
          _ = fetched_post.content
        rescue Parse::Error::ProtocolError => e
          error_raised = true
          assert e.message.include?("not found"), "Error should indicate object not found: #{e.message}"
        end

        assert error_raised, "Accessing unfetched field on deleted object should raise error"

        puts "Autofetch correctly raises error when object is deleted"
      end
    end
  end

  def test_autofetch_error_leaves_object_in_consistent_state
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "autofetch error state consistency test") do
        puts "\n=== Testing Autofetch Error Leaves Object in Consistent State ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Test Content",
          category: "tech",
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Partial fetch
        fetched_post = PartialFetchPost.first(keys: [:title])
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Delete the post
        post.destroy

        # Attempt autofetch (will fail)
        begin
          _ = fetched_post.content
        rescue Parse::Error::ProtocolError
          # Expected
        end

        # Object should still be in a consistent state
        # - Still has its ID
        assert_equal post_id, fetched_post.id, "Object should retain its ID after failed autofetch"

        # - Still has the originally fetched field
        assert_equal "Test Post", fetched_post.title, "Originally fetched field should still be accessible"

        # - Should still be marked as partially fetched (fetch failed, state unchanged)
        assert fetched_post.partially_fetched?, "Object should still be partially fetched after failed autofetch"

        puts "Object remains in consistent state after autofetch error"
      end
    end
  end

  def test_autofetch_preserves_dirty_changes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "autofetch preserves dirty changes test") do
        puts "\n=== Testing Autofetch Preserves Dirty Changes ==="

        # Create test post with all fields
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
          category: "tech",
          view_count: 100,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Partial fetch with only title and content
        fetched_post = PartialFetchPost.first(id: post_id, keys: [:title, :content])
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Make a local modification to a fetched field (title)
        fetched_post.title = "Modified Title"
        assert fetched_post.title_changed?, "Title should be marked as changed"
        assert_equal "Original Title", fetched_post.title_was, "title_was should be original"

        # Trigger autofetch by accessing an unfetched field (category)
        category_value = fetched_post.category

        # Verify autofetch happened (object is no longer partially fetched)
        refute fetched_post.partially_fetched?, "Post should be fully fetched after autofetch"

        # Verify autofetch got the correct data
        assert_equal "tech", category_value, "Autofetch should return correct category value"
        assert_equal 100, fetched_post.view_count, "Autofetch should populate view_count"

        # CRITICAL: Verify dirty changes were preserved during autofetch
        assert_equal "Modified Title", fetched_post.title, "Local title change should be preserved after autofetch"
        assert fetched_post.title_changed?, "Title should still be marked as changed after autofetch"
        assert_equal "Original Title", fetched_post.title_was, "title_was should still be original after autofetch"

        # Unchanged fetched field should have server value and not be dirty
        assert_equal "Original Content", fetched_post.content, "Unchanged field should have server value"
        refute fetched_post.content_changed?, "Unchanged field should not be dirty"

        puts "Autofetch correctly preserves dirty changes"
      end
    end
  end

  def test_autofetch_preserves_multiple_dirty_changes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "autofetch preserves multiple dirty changes test") do
        puts "\n=== Testing Autofetch Preserves Multiple Dirty Changes ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
          category: "tech",
          view_count: 50,
          is_published: false,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Partial fetch with title, content, and category
        fetched_post = PartialFetchPost.first(id: post_id, keys: [:title, :content, :category])
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Make multiple local modifications
        fetched_post.title = "Modified Title"
        fetched_post.content = "Modified Content"
        # Don't modify category - leave it unchanged

        # Verify both are dirty
        assert fetched_post.title_changed?, "Title should be dirty"
        assert fetched_post.content_changed?, "Content should be dirty"
        refute fetched_post.category_changed?, "Category should not be dirty"

        # Trigger autofetch by accessing unfetched field
        view_count = fetched_post.view_count

        # Object should now be fully fetched
        refute fetched_post.partially_fetched?, "Post should be fully fetched after autofetch"

        # All dirty changes should be preserved
        assert_equal "Modified Title", fetched_post.title, "Title modification preserved"
        assert_equal "Modified Content", fetched_post.content, "Content modification preserved"
        assert fetched_post.title_changed?, "Title should still be dirty"
        assert fetched_post.content_changed?, "Content should still be dirty"

        # Unchanged fields should have server values
        assert_equal "tech", fetched_post.category, "Unchanged category should have server value"
        assert_equal 50, view_count, "view_count should have server value"
        refute fetched_post.is_published, "is_published should have server value"

        puts "Autofetch correctly preserves multiple dirty changes"
      end
    end
  end

  def test_autofetch_preserves_dirty_unfetched_field_assignments
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "autofetch preserves unfetched field assignments test") do
        puts "\n=== Testing Autofetch Preserves Dirty Unfetched Field Assignments ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
          category: "tech",
          view_count: 100,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Partial fetch with only title
        fetched_post = PartialFetchPost.first(id: post_id, keys: [:title])
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Assign to an unfetched field (this marks it as fetched without triggering autofetch)
        fetched_post.content = "User Assigned Content"
        assert fetched_post.content_changed?, "Content should be dirty after assignment"
        assert fetched_post.field_was_fetched?(:content), "Content should be marked as fetched after assignment"

        # Object should still be partially fetched (category, view_count not fetched)
        assert fetched_post.partially_fetched?, "Post should still be partially fetched"

        # Trigger autofetch by accessing a different unfetched field
        category_value = fetched_post.category

        # Object should now be fully fetched
        refute fetched_post.partially_fetched?, "Post should be fully fetched after autofetch"

        # The assigned content should be preserved (not overwritten by server value)
        assert_equal "User Assigned Content", fetched_post.content, "User assigned content should be preserved"
        assert fetched_post.content_changed?, "Content should still be dirty"

        # Unfetched fields should have server values
        assert_equal "tech", category_value, "Category should have server value"
        assert_equal 100, fetched_post.view_count, "view_count should have server value"

        puts "Autofetch correctly preserves dirty unfetched field assignments"
      end
    end
  end

  def test_autofetch_raise_on_missing_keys_option
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "autofetch raise on missing keys test") do
        puts "\n=== Testing Parse.autofetch_raise_on_missing_keys Option ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
          category: "tech",
          view_count: 100,
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Partial fetch with only title
        fetched_post = PartialFetchPost.first(id: post_id, keys: [:title])
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Enable the raise option
        original_setting = Parse.autofetch_raise_on_missing_keys
        begin
          Parse.autofetch_raise_on_missing_keys = true

          # Accessing unfetched field should raise AutofetchTriggeredError
          error = assert_raises(Parse::AutofetchTriggeredError) do
            fetched_post.content
          end

          # Verify error details
          assert_equal PartialFetchPost, error.klass, "Error should have correct class"
          assert_equal post_id, error.object_id, "Error should have correct object_id"
          assert_equal :content, error.field, "Error should have correct field"
          refute error.is_pointer, "Error should indicate this is not a pointer fetch"

          # Error message should be helpful
          assert_match(/content/, error.message, "Error message should mention the field")
          assert_match(/partial fetch/, error.message, "Error message should mention partial fetch")
          assert_match(/Add :content to your query keys/, error.message, "Error message should suggest adding key")

          puts "Parse.autofetch_raise_on_missing_keys correctly raises error for partial fetch"
        ensure
          Parse.autofetch_raise_on_missing_keys = original_setting
        end
      end
    end
  end

  def test_autofetch_raise_on_missing_keys_for_pointer
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "autofetch raise on missing keys for pointer test") do
        puts "\n=== Testing Parse.autofetch_raise_on_missing_keys for Pointer ==="

        # Create test post
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Create a pointer (not fetched at all)
        pointer = PartialFetchPost.pointer(post_id)
        assert pointer.pointer?, "Should be a pointer"

        # Enable the raise option
        original_setting = Parse.autofetch_raise_on_missing_keys
        begin
          Parse.autofetch_raise_on_missing_keys = true

          # Accessing any field on pointer should raise AutofetchTriggeredError
          error = assert_raises(Parse::AutofetchTriggeredError) do
            pointer.title
          end

          # Verify error details
          assert_equal PartialFetchPost, error.klass, "Error should have correct class"
          assert_equal post_id, error.object_id, "Error should have correct object_id"
          assert_equal :title, error.field, "Error should have correct field"
          assert error.is_pointer, "Error should indicate this is a pointer fetch"

          # Error message should be helpful for pointers
          assert_match(/title/, error.message, "Error message should mention the field")
          assert_match(/pointer/, error.message, "Error message should mention pointer")
          assert_match(/includes/, error.message, "Error message should suggest adding includes")

          puts "Parse.autofetch_raise_on_missing_keys correctly raises error for pointer access"
        ensure
          Parse.autofetch_raise_on_missing_keys = original_setting
        end
      end
    end
  end

  def test_autofetch_preserves_nested_embedded_data
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(20, "autofetch preserves nested embedded data test") do
        puts "\n=== Testing Autofetch Preserves Nested Embedded Data ==="

        # Create test user with all fields
        user = PartialFetchUser.new(
          name: "Test Author",
          email: "author@test.com",
          age: 30,
        )
        assert user.save, "User should save"

        # Create test post with author
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
          category: "tech",
          author: user,
        )
        assert post.save, "Post should save"

        # Partial fetch with nested field (author.name only)
        fetched_post = PartialFetchPost.first(keys: ["author.name"])
        assert fetched_post.present?, "Post should be found"
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Author should have the embedded name
        author = fetched_post.author
        assert author.present?, "Author should be present"
        assert_equal "Test Author", author.name, "Author name should be embedded"

        # Now access an unfetched field on the post (e.g., content)
        # This should trigger autofetch but NOT wipe out author.name
        puts "Accessing unfetched field 'content' to trigger autofetch..."
        content = fetched_post.content

        assert_equal "Test Content", content, "Content should be autofetched"
        refute fetched_post.partially_fetched?, "Post should be fully fetched after autofetch"

        # The key assertion: author.name should STILL be available
        # (not wiped out by autofetch returning the author as a bare pointer)
        author_after = fetched_post.author
        assert author_after.present?, "Author should still be present after autofetch"

        # The author should be the same object with embedded data preserved
        assert_equal user.id, author_after.id, "Author ID should match"

        # This is the critical assertion - the nested fetched data should NOT be wiped
        # Previously, autofetch would replace the embedded author with a bare pointer
        assert_equal "Test Author", author_after.name, "Author name should be preserved after autofetch"

        puts "Autofetch correctly preserves nested embedded data"
      end
    end
  end

  def test_autofetch_raise_disabled_by_default
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "autofetch raise disabled by default test") do
        puts "\n=== Testing Parse.autofetch_raise_on_missing_keys is Disabled by Default ==="

        # Verify default setting
        refute Parse.autofetch_raise_on_missing_keys, "autofetch_raise_on_missing_keys should be false by default"

        # Create test post
        post = PartialFetchPost.new(
          title: "Test Title",
          content: "Test Content",
        )
        assert post.save, "Post should save"

        # Partial fetch with only title
        fetched_post = PartialFetchPost.first(keys: [:title])
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Accessing unfetched field should NOT raise, should autofetch
        # (if it raises, the test will fail)
        content = fetched_post.content

        # Should have autofetched successfully
        assert_equal "Test Content", content, "Should have autofetched content"
        refute fetched_post.partially_fetched?, "Should be fully fetched after autofetch"

        puts "Autofetch works normally when raise option is disabled"
      end
    end
  end
end
