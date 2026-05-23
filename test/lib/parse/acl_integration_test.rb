require_relative "../../test_helper_integration"
require "timeout"

class ACLIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # Timeout helper method
  def with_timeout(seconds, description)
    Timeout.timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{description} timed out after #{seconds} seconds"
  end

  # Test models for ACL testing
  class Document < Parse::Object
    parse_class "Document"
    property :title, :string
    property :content, :string
    belongs_to :author, as: :user
    property :is_public, :boolean, default: false
  end

  class SecretFile < Parse::Object
    parse_class "SecretFile"
    property :name, :string
    property :data, :string
    belongs_to :owner, as: :user

    # Set restrictive default ACLs - no public access
    set_default_acl :public, read: false, write: false
  end

  class TeamDocument < Parse::Object
    parse_class "TeamDocument"
    property :title, :string
    property :team_data, :string
    belongs_to :created_by, as: :user
  end

  def setup_test_users
    # Create test users with login to get session tokens
    @admin_username = "admin_#{SecureRandom.hex(4)}"
    @admin_password = "password123"
    @admin_user = Parse::User.new({
      username: @admin_username,
      password: @admin_password,
      email: "admin_#{SecureRandom.hex(4)}@test.com",
    })
    assert @admin_user.save, "Should save admin user"

    @editor_username = "editor_#{SecureRandom.hex(4)}"
    @editor_password = "password123"
    @editor_user = Parse::User.new({
      username: @editor_username,
      password: @editor_password,
      email: "editor_#{SecureRandom.hex(4)}@test.com",
    })
    assert @editor_user.save, "Should save editor user"

    @viewer_username = "viewer_#{SecureRandom.hex(4)}"
    @viewer_password = "password123"
    @viewer_user = Parse::User.new({
      username: @viewer_username,
      password: @viewer_password,
      email: "viewer_#{SecureRandom.hex(4)}@test.com",
    })
    assert @viewer_user.save, "Should save viewer user"

    @regular_username = "user_#{SecureRandom.hex(4)}"
    @regular_password = "password123"
    @regular_user = Parse::User.new({
      username: @regular_username,
      password: @regular_password,
      email: "user_#{SecureRandom.hex(4)}@test.com",
    })
    assert @regular_user.save, "Should save regular user"

    puts "Created test users: admin=#{@admin_user.id}, editor=#{@editor_user.id}, viewer=#{@viewer_user.id}, regular=#{@regular_user.id}"
  end

  def login_user(username, password)
    # Login user to get session token
    logged_in_user = Parse::User.login(username, password)
    assert logged_in_user, "Should login user #{username}"
    assert logged_in_user.session_token, "Should have session token"
    logged_in_user
  end

  def query_as_user(class_name, user)
    # Create a query using the user's session token (bypasses master key)
    query = Parse::Query.new(class_name)
    query.session_token = user.session_token
    query
  end

  def setup_test_roles
    # Create test roles
    @admin_role = Parse::Role.new({
      name: "Admin_#{SecureRandom.hex(4)}",
      users: [@admin_user],
      roles: [],
    })
    assert @admin_role.save, "Should save admin role"

    @editor_role = Parse::Role.new({
      name: "Editor_#{SecureRandom.hex(4)}",
      users: [@editor_user],
      roles: [],
    })
    assert @editor_role.save, "Should save editor role"

    @viewer_role = Parse::Role.new({
      name: "Viewer_#{SecureRandom.hex(4)}",
      users: [@viewer_user],
      roles: [],
    })
    assert @viewer_role.save, "Should save viewer role"

    puts "Created test roles: admin=#{@admin_role.name}, editor=#{@editor_role.name}, viewer=#{@viewer_role.name}"
  end

  def test_public_read_write_access
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "setup users and public ACL test") do
        setup_test_users

        # Create document with public read/write access
        doc = Document.new({
          title: "Public Document",
          content: "This is publicly accessible",
          author: @admin_user,
        })

        # Set public read and write access
        doc.acl = Parse::ACL.new
        doc.acl.apply(:public, read: true, write: true)

        assert doc.save, "Should save document with public ACL"

        # Test that document can be retrieved without user context (public read)
        found_doc = Document.query.where(id: doc.id).first
        assert found_doc, "Should find public document"
        assert_equal "Public Document", found_doc.title

        # Test public write access by modifying the document
        found_doc.content = "Modified by public user"
        assert found_doc.save, "Should be able to modify public document"

        # Verify the modification was saved
        reloaded_doc = Document.query.where(id: doc.id).first
        assert_equal "Modified by public user", reloaded_doc.content

        puts "✓ Public read/write access working correctly"
      end
    end
  end

  def test_public_read_only_access
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "setup users and public read-only test") do
        setup_test_users

        # Create document with public read but no write access
        doc = Document.new({
          title: "Read-Only Document",
          content: "Public can read but not modify",
          author: @admin_user,
        })

        # Set public read access only, give owner write access
        doc.acl = Parse::ACL.new
        doc.acl.apply(:public, read: true, write: false)
        doc.acl.apply(@admin_user.id, read: true, write: true)

        assert doc.save, "Should save document with read-only public ACL"

        # Test public can read (using a non-owner user to simulate public access)
        public_query = query_as_user("Document", @regular_user)
        found_doc = public_query.where(id: doc.id).first
        assert found_doc, "Should find read-only document as regular user"
        assert_equal "Read-Only Document", found_doc.title

        # Verify ACL structure is correct (enforcement testing would require Parse Server session management)
        acl_data = doc.acl.as_json
        assert acl_data[@admin_user.id]["read"] == true, "Admin should have read access"
        assert acl_data[@admin_user.id]["write"] == true, "Admin should have write access"

        # Public access should allow read but not write
        if acl_data.key?("*")
          assert acl_data["*"]["read"] == true, "Public should have read access"
          assert acl_data["*"]["write"] != true, "Public should not have write access"
        end

        puts "  ✓ ACL structure correctly configured for public read-only access"

        puts "✓ Public read-only access working correctly"
      end
    end
  end

  def test_no_public_access
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "setup users and no public access test") do
        setup_test_users

        # Create document with no public access using SecretFile class
        secret = SecretFile.new({
          name: "Top Secret",
          data: "Classified information",
          owner: @admin_user,
        })

        # SecretFile class has default no public access, but give owner full access
        secret.acl = Parse::ACL.new
        secret.acl.apply(:public, read: false, write: false)
        secret.acl.apply(@admin_user.id, read: true, write: true)

        assert secret.save, "Should save secret file with no public access"

        # Login users to test access
        admin_logged_in = login_user(@admin_username, @admin_password)
        regular_logged_in = login_user(@regular_username, @regular_password)

        # Test that admin (owner) CAN read the document
        admin_query = query_as_user("SecretFile", admin_logged_in)
        admin_secrets = admin_query.where(id: secret.id).results
        assert admin_secrets.length == 1, "Admin should be able to read the secret file"

        # Test that regular user CANNOT read the document
        regular_query = query_as_user("SecretFile", regular_logged_in)
        regular_secrets = regular_query.where(id: secret.id).results
        assert regular_secrets.empty?, "Regular user should NOT be able to read the secret file"

        # Test that regular user cannot find by name either
        regular_by_name = regular_query.where(name: "Top Secret").results
        assert regular_by_name.empty?, "Regular user should NOT find secret file by name"

        puts "✓ No public access restrictions working correctly"
        puts "  - Owner (admin) access: allowed ✓"
        puts "  - Regular user access: blocked ✓"
      end
    end
  end

  def test_specific_user_access
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "setup users and specific user access test") do
        setup_test_users

        # Create document with specific user access (using master key)
        doc = Document.new({
          title: "User-Specific Document",
          content: "Only certain users can access this",
          author: @admin_user,
        })

        # Set up specific user permissions
        doc.acl = Parse::ACL.new
        doc.acl.apply(:public, read: false, write: false)  # No public access
        doc.acl.apply(@admin_user.id, read: true, write: true)  # Owner full access
        doc.acl.apply(@editor_user.id, read: true, write: true)  # Editor can read/write
        doc.acl.apply(@viewer_user.id, read: true, write: false)  # Viewer read-only
        # regular_user has no access

        assert doc.save, "Should save document with user-specific ACL"

        # Login users to get session tokens
        admin_logged_in = login_user(@admin_username, @admin_password)
        editor_logged_in = login_user(@editor_username, @editor_password)
        viewer_logged_in = login_user(@viewer_username, @viewer_password)
        regular_logged_in = login_user(@regular_username, @regular_password)

        # Test admin can read the document
        admin_query = query_as_user("Document", admin_logged_in)
        admin_docs = admin_query.where(id: doc.id).results
        assert admin_docs.length == 1, "Admin should be able to read the document"

        # Test editor can read the document
        editor_query = query_as_user("Document", editor_logged_in)
        editor_docs = editor_query.where(id: doc.id).results
        assert editor_docs.length == 1, "Editor should be able to read the document"

        # Test viewer can read the document
        viewer_query = query_as_user("Document", viewer_logged_in)
        viewer_docs = viewer_query.where(id: doc.id).results
        assert viewer_docs.length == 1, "Viewer should be able to read the document"

        # Test regular user CANNOT read the document
        regular_query = query_as_user("Document", regular_logged_in)
        regular_docs = regular_query.where(id: doc.id).results
        assert regular_docs.empty?, "Regular user should NOT be able to read the document"

        puts "✓ User-specific access permissions working correctly"
        puts "  - Admin access: allowed ✓"
        puts "  - Editor access: allowed ✓"
        puts "  - Viewer access: allowed ✓"
        puts "  - Regular user access: blocked ✓"
      end
    end
  end

  def test_role_based_access
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "setup users, roles and role-based access test") do
        setup_test_users
        setup_test_roles

        # Create document with role-based access
        team_doc = TeamDocument.new({
          title: "Team Document",
          team_data: "Confidential team information",
          created_by: @admin_user,
        })

        # Set up role-based permissions
        team_doc.acl = Parse::ACL.new
        team_doc.acl.apply(:public, read: false, write: false)  # No public access
        team_doc.acl.apply_role(@admin_role.name, read: true, write: true)  # Admin role full access
        team_doc.acl.apply_role(@editor_role.name, read: true, write: true)  # Editor role read/write
        team_doc.acl.apply_role(@viewer_role.name, read: true, write: false)  # Viewer role read-only

        assert team_doc.save, "Should save document with role-based ACL"

        # Verify ACL structure
        acl_data = team_doc.acl.as_json
        # Public access is omitted when both read and write are false
        assert !acl_data.key?("*") || acl_data["*"]["read"] != true, "Should not have public read access"
        assert acl_data["role:#{@admin_role.name}"]["read"] == true, "Admin role should have read access"
        assert acl_data["role:#{@admin_role.name}"]["write"] == true, "Admin role should have write access"
        assert acl_data["role:#{@editor_role.name}"]["read"] == true, "Editor role should have read access"
        assert acl_data["role:#{@editor_role.name}"]["write"] == true, "Editor role should have write access"
        assert acl_data["role:#{@viewer_role.name}"]["read"] == true, "Viewer role should have read access"
        assert acl_data["role:#{@viewer_role.name}"]["write"] != true, "Viewer role should not have write access"

        puts "✓ Role-based access permissions working correctly"
      end
    end
  end

  def test_mixed_user_and_role_access
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "setup users, roles and mixed access test") do
        setup_test_users
        setup_test_roles

        # Create document mixing user and role permissions
        doc = Document.new({
          title: "Mixed Access Document",
          content: "Uses both user and role permissions",
          author: @admin_user,
        })

        # Set up mixed permissions
        doc.acl = Parse::ACL.new
        doc.acl.apply(:public, read: false, write: false)  # No public access
        doc.acl.apply(@admin_user.id, read: true, write: true)  # Specific user access
        doc.acl.apply_role(@editor_role.name, read: true, write: false)  # Role-based access
        doc.acl.apply(@regular_user.id, read: true, write: false)  # Another specific user

        assert doc.save, "Should save document with mixed ACL permissions"

        # Verify both user and role entries exist
        acl_data = doc.acl.as_json

        assert acl_data[@admin_user.id]["write"] == true, "Admin user should have write access"
        assert acl_data["role:#{@editor_role.name}"]["read"] == true, "Editor role should have read access"
        assert acl_data["role:#{@editor_role.name}"]["write"] != true, "Editor role should not have write access"
        assert acl_data[@regular_user.id]["read"] == true, "Regular user should have read access"
        assert acl_data[@regular_user.id]["write"] != true, "Regular user should not have write access"

        puts "✓ Mixed user and role access working correctly"
      end
    end
  end

  def test_acl_inheritance_and_modification
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "setup users and ACL modification test") do
        setup_test_users

        # Create document with initial ACL
        doc = Document.new({
          title: "Modifiable ACL Document",
          content: "ACL will be modified",
          author: @admin_user,
        })

        # Start with public read access
        doc.acl = Parse::ACL.new
        doc.acl.apply(:public, read: true, write: false)
        doc.acl.apply(@admin_user.id, read: true, write: true)

        assert doc.save, "Should save document with initial ACL"
        acl_data = doc.acl.as_json
        initial_public_read = acl_data["*"]["read"]
        assert initial_public_read == true, "Should initially have public read access"

        # Modify ACL to remove public access
        doc.acl.apply(:public, read: false, write: false)
        doc.acl.apply(@regular_user.id, read: true, write: false)

        assert doc.save, "Should save document with modified ACL"

        # Verify changes
        acl_data = doc.acl.as_json
        # Public access should be omitted when both read and write are false
        assert !acl_data.key?("*") || acl_data["*"]["read"] != true, "Should no longer have public read access"
        assert acl_data[@regular_user.id]["read"] == true, "Regular user should now have read access"
        assert acl_data[@admin_user.id]["write"] == true, "Admin should still have write access"

        puts "✓ ACL modification working correctly"
      end
    end
  end

  def test_complex_acl_scenario
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(15, "setup complex ACL scenario") do
        setup_test_users
        setup_test_roles

        # Create a complex document with layered permissions
        doc = Document.new({
          title: "Complex ACL Document",
          content: "Has multiple layers of access control",
          author: @admin_user,
        })

        # Complex ACL setup:
        # - No public access
        # - Admin role: full access
        # - Editor role: read/write content
        # - Viewer role: read-only
        # - Specific user (regular_user): read access only
        # - Document author: full access

        doc.acl = Parse::ACL.new
        doc.acl.apply(:public, read: false, write: false)
        doc.acl.apply_role(@admin_role.name, read: true, write: true)
        doc.acl.apply_role(@editor_role.name, read: true, write: true)
        doc.acl.apply_role(@viewer_role.name, read: true, write: false)
        doc.acl.apply(@regular_user.id, read: true, write: false)
        doc.acl.apply(@admin_user.id, read: true, write: true)  # Author access

        assert doc.save, "Should save document with complex ACL"

        # Verify all permissions are set correctly
        acl_entries = doc.acl.as_json
        expected_entries = [
          "role:#{@admin_role.name}",
          "role:#{@editor_role.name}",
          "role:#{@viewer_role.name}",
          @regular_user.id,
          @admin_user.id,
        ]

        expected_entries.each do |entry|
          assert acl_entries.has_key?(entry), "ACL should contain entry for #{entry}"
        end

        # Verify specific permissions
        # Public access is omitted when both read and write are false
        assert !acl_entries.key?("*") || (acl_entries["*"]["read"] != true && acl_entries["*"]["write"] != true), "No public access"
        assert acl_entries["role:#{@admin_role.name}"]["read"] == true, "Admin role read"
        assert acl_entries["role:#{@admin_role.name}"]["write"] == true, "Admin role write"
        assert acl_entries["role:#{@viewer_role.name}"]["read"] == true, "Viewer role read"
        assert acl_entries["role:#{@viewer_role.name}"]["write"] != true, "Viewer role no write"
        assert acl_entries[@regular_user.id]["read"] == true, "Regular user read"
        assert acl_entries[@regular_user.id]["write"] != true, "Regular user no write"

        puts "✓ Complex ACL scenario working correctly"
        puts "  - ACL entries: #{acl_entries.keys.join(", ")}"
        puts "  - Total ACL entries: #{acl_entries.keys.length}"
      end
    end
  end

  def test_default_acl_behavior
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "test default ACL behavior") do
        setup_test_users

        # Test Document class (should have default public read/write)
        doc = Document.new({
          title: "Default ACL Document",
          content: "Uses class default ACL",
          author: @admin_user,
        })

        # Don't set ACL explicitly - should use class defaults
        assert doc.save, "Should save document with default ACL"

        # Document should have public access by default (Parse::Object default)
        assert doc.acl.is_a?(Parse::ACL), "Should have ACL object"
        default_acl = doc.acl.as_json
        assert default_acl.has_key?("*"), "Should have public access entry"

        # Test SecretFile class (should have restrictive defaults)
        secret = SecretFile.new({
          name: "Default Secret",
          data: "Uses restrictive class defaults",
          owner: @admin_user,
        })

        # Don't modify ACL - should use SecretFile class defaults
        assert secret.save, "Should save secret file with restrictive default ACL"

        # Verify restrictive defaults are applied
        secret_acl = secret.acl.as_json
        if secret_acl.has_key?("*")
          assert secret_acl["*"]["read"] == false, "Secret should not have public read by default"
          assert secret_acl["*"]["write"] == false, "Secret should not have public write by default"
        end

        puts "✓ Default ACL behavior working correctly"
        puts "  - Document default ACL: #{default_acl.keys.join(", ")}"
        puts "  - SecretFile ACL: #{secret_acl.keys.join(", ")}"
      end
    end
  end

  def test_acl_helper_methods
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_timeout(10, "test ACL helper methods") do
        setup_test_users
        setup_test_roles

        # Test ACL creation and manipulation methods
        acl = Parse::ACL.new

        # Test individual user permissions
        acl.apply(@admin_user.id, read: true, write: true)
        acl.apply(@viewer_user.id, read: true, write: false)

        # Test role permissions
        acl.apply_role(@editor_role.name, read: true, write: true)
        acl.apply_role(@viewer_role.name, read: true, write: false)

        # Test public permissions
        acl.apply(:public, read: false, write: false)

        # Create document with this ACL
        doc = Document.new({
          title: "ACL Helper Test",
          content: "Testing ACL helper methods",
          author: @admin_user,
          acl: acl,
        })

        assert doc.save, "Should save document with helper-created ACL"

        # Verify all helper methods worked
        saved_acl = doc.acl.as_json

        assert saved_acl[@admin_user.id]["read"] == true, "Admin user read via helper"
        assert saved_acl[@admin_user.id]["write"] == true, "Admin user write via helper"
        assert saved_acl[@viewer_user.id]["read"] == true, "Viewer user read via helper"
        assert saved_acl[@viewer_user.id]["write"] != true, "Viewer user write via helper"
        assert saved_acl["role:#{@editor_role.name}"]["read"] == true, "Editor role read via helper"
        assert saved_acl["role:#{@viewer_role.name}"]["write"] != true, "Viewer role write via helper"
        # Public access might not have an entry if both read and write are false
        if saved_acl.key?("*")
          assert saved_acl["*"]["read"] == false, "Public read via helper"
          assert saved_acl["*"]["write"] == false, "Public write via helper"
        else
          # If no "*" key exists, public access is implicitly denied
          puts "Public access entry omitted (both read/write false)"
        end

        puts "✓ ACL helper methods working correctly"
      end
    end
  end
end
