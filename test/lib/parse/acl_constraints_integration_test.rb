require_relative '../../test_helper_integration'
require 'securerandom'

class ACLConstraintsIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  
  # Test models for ACL constraint testing
  class TestDocument < Parse::Object
    parse_class "TestDocument"
    property :title, :string
    property :content, :string
  end
  
  def setup
    @test_users = []
    @test_roles = []
    @test_documents = []
    
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    super
  end

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def create_test_role(name)
    # Use first_or_create! with test-specific names to avoid cross-test conflicts
    test_specific_name = "#{name}_#{self.class.name}_#{SecureRandom.hex(3)}"
    role = Parse::Role.first_or_create!(name: test_specific_name)
    assert role.persisted?, "Should have role #{test_specific_name}"
    @test_roles << role unless @test_roles.include?(role)
    role
  end

  def create_unique_test_user(base_username = "testuser")
    # Create unique username to avoid conflicts
    unique_username = "#{base_username}_#{SecureRandom.hex(4)}"
    user = Parse::User.new(username: unique_username, password: "password123")
    assert user.save, "Should save user #{unique_username}"
    @test_users ||= []
    @test_users << user
    user
  end

  def create_test_document(attributes = {})
    # Use the defined TestDocument class
    doc = TestDocument.new(attributes)
    if doc.save
      @test_documents << doc
      doc
    else
      assert false, "Should save document but failed"
    end
  end

  def test_readable_by_role_constraint_integration
    # Ensure Parse is setup before running the test
    Parse::Test::ServerHelper.setup
    
    # Ensure Parse is setup before running the test
    Parse::Test::ServerHelper.setup
    
    with_parse_server do
      with_timeout(20, "readable_by role constraint test") do
        puts "\n=== Testing readable_by Role Constraint Integration ==="

        # Clean up any existing test documents first
        TestDocument.query.results.each(&:destroy)
        sleep 0.1

        # Create test roles
        admin_role = create_test_role("Admin")
        editor_role = create_test_role("Editor")
        viewer_role = create_test_role("Viewer")

        # Create documents with different ACL permissions
        
        # Document 1: Admin and Editor can read
        doc1 = create_test_document(title: "Admin and Editor Doc", content: "Test content 1")
        doc1.acl = Parse::ACL.new
        doc1.acl.apply_role(admin_role.name, read: true, write: true)
        doc1.acl.apply_role(editor_role.name, read: true, write: false)
        doc1.acl.apply(:public, read: false, write: false)  # No public access
        assert doc1.save, "Should save doc1 with ACL"

        # Document 2: Only Admin can read
        doc2 = create_test_document(title: "Admin Only Doc", content: "Test content 2")
        doc2.acl = Parse::ACL.new
        doc2.acl.apply_role(admin_role.name, read: true, write: true)
        doc2.acl.apply(:public, read: false, write: false)
        assert doc2.save, "Should save doc2 with ACL"

        # Document 3: Public read access
        doc3 = create_test_document(title: "Public Doc", content: "Test content 3")
        doc3.acl = Parse::ACL.new
        doc3.acl.apply(:public, read: true, write: false)
        assert doc3.save, "Should save doc3 with ACL"
        
        # Test readable_by Admin role - should find doc1, doc2
        query_admin = Parse::Query.new("TestDocument")
        query_admin.readable_by(admin_role.name)
        query_admin.use_master_key = true  # ACL queries might need master key
        
        # Debug: Check what the constraint generates
        puts "DEBUG: Admin role name: #{admin_role.name}"
        puts "DEBUG: Query compiled: #{query_admin.compile.inspect}"
        puts "DEBUG: Query requires aggregation: #{query_admin.requires_aggregation_pipeline?}"
        puts "DEBUG: Query pipeline: #{query_admin.pipeline.inspect}"
        
        # Debug: Check raw document storage in MongoDB using aggregation
        # Check for _rperm/_wperm fields and project them to see if they exist but are null/empty
        raw_pipeline = [
          { 
            "$project" => { 
              "title" => 1, 
              "ACL" => 1, 
              "_rperm" => 1, 
              "_wperm" => 1,
              "rperm_exists" => { "$ifNull" => ["$_rperm", "MISSING"] },
              "wperm_exists" => { "$ifNull" => ["$_wperm", "MISSING"] },
              "rperm_type" => { "$type" => "$_rperm" },
              "wperm_type" => { "$type" => "$_wperm" },
              "all_fields" => "$$ROOT"  # Show all fields in the document
            } 
          }
        ]
        raw_agg_query = TestDocument.new.client.aggregate_pipeline("TestDocument", raw_pipeline)
        raw_results = raw_agg_query.results || []
        puts "DEBUG: Raw MongoDB document structure with field analysis:"
        raw_results.each_with_index do |doc, i|
          puts "  Doc #{i+1}:"
          puts "    Title: #{doc['title']}"
          puts "    _rperm exists: #{doc['rperm_exists']}"  
          puts "    _wperm exists: #{doc['wperm_exists']}"
          puts "    _rperm type: #{doc['rperm_type']}"
          puts "    _wperm type: #{doc['wperm_type']}"
          puts "    ACL field: #{doc['ACL']}"
          puts "    All fields keys: #{doc['all_fields']&.keys&.inspect}"
        end
        
        # Debug query execution path
        puts "DEBUG: Query requires aggregation: #{query_admin.requires_aggregation_pipeline?}"
        puts "DEBUG: Query aggregation pipeline: #{query_admin.send(:build_aggregation_pipeline).inspect}"
        
        admin_results = query_admin.results
        puts "DEBUG: Admin results count: #{admin_results.size}"
        
        # Debug: Test the aggregation pipeline directly to see if it works
        puts "DEBUG: Testing aggregation pipeline directly:"
        test_pipeline = [{"$match"=>{"$or"=>[{"_rperm"=>{"$in"=>["role:#{admin_role.name}", "*"]}}, {"_rperm"=>{"$exists"=>false}}]}}]
        direct_agg_query = TestDocument.new.client.aggregate_pipeline("TestDocument", test_pipeline)
        direct_results = direct_agg_query.results || []
        puts "DEBUG: Direct aggregation results count: #{direct_results.size}"
        puts "DEBUG: Direct aggregation results titles: #{direct_results.map { |r| r['title'] }.inspect}"
        
        # Test public access specifically - should find the public document
        public_query = Parse::Query.new("TestDocument")
        public_query.readable_by("*")
        public_query.use_master_key = true
        public_results = public_query.results
        puts "DEBUG: Public query pipeline: #{public_query.pipeline.inspect}"
        puts "DEBUG: Public results count: #{public_results.size}"
        puts "DEBUG: Public results titles: #{public_results.map{|d| d['title']}}"
        
        # If even public access doesn't work, the _rperm field might not be populated
        if public_results.empty?
          puts "WARNING: Even public access returns 0 results. _rperm field might not be populated by Parse Server when ACLs are set via SDK."
        end
        
        admin_titles = admin_results.map { |doc| doc["title"] }.sort
        expected_admin_titles = ["Admin and Editor Doc", "Admin Only Doc", "Public Doc"].sort
        assert_equal expected_admin_titles, admin_titles, "Admin should read docs 1, 2, and public doc"

        # Test readable_by Editor role - should find doc1 only
        query_editor = Parse::Query.new("TestDocument")
        query_editor.readable_by(editor_role.name)
        editor_results = query_editor.results
        
        editor_titles = editor_results.map { |doc| doc["title"] }.sort
        expected_editor_titles = ["Admin and Editor Doc", "Public Doc"].sort
        assert_equal expected_editor_titles, editor_titles, "Editor should read doc 1 and public doc"

        # Test readable_by Viewer role - should find only public doc (no explicit permissions)
        query_viewer = Parse::Query.new("TestDocument")
        query_viewer.readable_by(viewer_role.name)
        viewer_results = query_viewer.results
        
        viewer_titles = viewer_results.map { |doc| doc["title"] }
        assert_equal ["Public Doc"], viewer_titles, "Viewer should read only public doc"

        # Test readable_by with role prefix
        query_admin_prefix = Parse::Query.new("TestDocument")
        query_admin_prefix.readable_by("role:#{admin_role.name}")
        admin_prefix_results = query_admin_prefix.results
        
        admin_prefix_titles = admin_prefix_results.map { |doc| doc["title"] }.sort
        assert_equal expected_admin_titles, admin_prefix_titles, "role:Admin prefix should work the same"

        puts "✅ readable_by role constraint integration test passed"
      end
    end
  end

  def test_writable_by_role_constraint_integration
    # Ensure Parse is setup before running the test
    Parse::Test::ServerHelper.setup
    
    with_parse_server do
      with_timeout(20, "writable_by role constraint test") do
        puts "\n=== Testing writable_by Role Constraint Integration ==="

        # Clean up any existing test documents first
        TestDocument.query.results.each(&:destroy)
        sleep 0.1

        # Create test roles
        admin_role = create_test_role("Admin")
        editor_role = create_test_role("Editor")

        # Create documents with different write permissions
        
        # Document 1: Admin and Editor can write
        doc1 = create_test_document(title: "Admin and Editor Writable", content: "Content 1")
        doc1.acl = Parse::ACL.new
        doc1.acl.apply_role(admin_role.name, read: true, write: true)
        doc1.acl.apply_role(editor_role.name, read: true, write: true)
        doc1.acl.apply(:public, read: false, write: false)
        assert doc1.save, "Should save doc1 with ACL"

        # Document 2: Only Admin can write (Editor can read)
        doc2 = create_test_document(title: "Admin Write Only", content: "Content 2")
        doc2.acl = Parse::ACL.new
        doc2.acl.apply_role(admin_role.name, read: true, write: true)
        doc2.acl.apply_role(editor_role.name, read: true, write: false)  # Read but not write
        doc2.acl.apply(:public, read: false, write: false)
        assert doc2.save, "Should save doc2 with ACL"

        # Document 3: Public write access (unusual but valid)
        doc3 = create_test_document(title: "Public Writable", content: "Content 3")
        doc3.acl = Parse::ACL.new
        doc3.acl.apply(:public, read: true, write: true)
        assert doc3.save, "Should save doc3 with ACL"

        # Test writable_by Admin role - should find doc1, doc2
        query_admin = Parse::Query.new("TestDocument")
        query_admin.writable_by(admin_role.name)
        admin_results = query_admin.results
        
        admin_titles = admin_results.map { |doc| doc["title"] }.sort
        expected_admin_titles = ["Admin and Editor Writable", "Admin Write Only", "Public Writable"].sort
        assert_equal expected_admin_titles, admin_titles, "Admin should write to docs 1, 2, and public writable"

        # Test writable_by Editor role - should find doc1 only
        query_editor = Parse::Query.new("TestDocument")
        query_editor.writable_by(editor_role.name)
        editor_results = query_editor.results
        
        editor_titles = editor_results.map { |doc| doc["title"] }.sort
        expected_editor_titles = ["Admin and Editor Writable", "Public Writable"].sort
        assert_equal expected_editor_titles, editor_titles, "Editor should write to doc 1 and public writable"

        puts "✅ writable_by role constraint integration test passed"
      end
    end
  end

  def test_readable_by_user_constraint_integration
    # Ensure Parse is setup before running the test
    Parse::Test::ServerHelper.setup
    
    with_parse_server do
      with_timeout(20, "readable_by user constraint test") do
        puts "\n=== Testing readable_by User Constraint Integration ==="

        # Clean up any existing test documents first
        TestDocument.query.results.each(&:destroy)
        sleep 0.1

        # Create test users
        user1 = create_unique_test_user("testuser1")
        user2 = create_unique_test_user("testuser2")

        # Create documents with user-specific permissions
        
        # Document 1: Only user1 can read
        doc1 = create_test_document(title: "User1 Private Doc", content: "Private content")
        doc1.acl = Parse::ACL.new
        doc1.acl.apply(user1.id, read: true, write: true)
        doc1.acl.apply(:public, read: false, write: false)
        assert doc1.save, "Should save doc1 with user ACL"

        # Document 2: Both users can read
        doc2 = create_test_document(title: "Shared Doc", content: "Shared content")
        doc2.acl = Parse::ACL.new
        doc2.acl.apply(user1.id, read: true, write: true)
        doc2.acl.apply(user2.id, read: true, write: false)
        doc2.acl.apply(:public, read: false, write: false)
        assert doc2.save, "Should save doc2 with user ACLs"

        # Test readable_by user1 - should find doc1, doc2
        query_user1 = Parse::Query.new("TestDocument")
        query_user1.where(:ACL.readable_by => user1)
        user1_results = query_user1.results
        
        user1_titles = user1_results.map { |doc| doc["title"] }.sort
        expected_user1_titles = ["User1 Private Doc", "Shared Doc"].sort
        assert_equal expected_user1_titles, user1_titles, "User1 should read both documents"

        # Test readable_by user2 - should find doc2 only
        query_user2 = Parse::Query.new("TestDocument")
        query_user2.readable_by(user2)
        user2_results = query_user2.results
        
        user2_titles = user2_results.map { |doc| doc["title"] }
        assert_equal ["Shared Doc"], user2_titles, "User2 should read only shared doc"

        # Test readable_by with same user object via different method
        query_user1_alt = Parse::Query.new("TestDocument")
        query_user1_alt.readable_by(user1)
        user1_alt_results = query_user1_alt.results
        
        user1_alt_titles = user1_alt_results.map { |doc| doc["title"] }.sort
        assert_equal expected_user1_titles, user1_alt_titles, "User1 object should work consistently"

        puts "✅ readable_by user constraint integration test passed"
      end
    end
  end

  def test_writable_by_user_constraint_integration
    # Ensure Parse is setup before running the test
    Parse::Test::ServerHelper.setup
    
    with_parse_server do
      with_timeout(20, "writable_by user constraint test") do
        puts "\n=== Testing writable_by User Constraint Integration ==="

        # Clean up any existing test documents first
        TestDocument.query.results.each(&:destroy)
        sleep 0.1

        # Create test users
        user1 = create_unique_test_user("writeuser1")
        user2 = create_unique_test_user("writeuser2")

        # Create documents with different write permissions
        
        # Document 1: Only user1 can write
        doc1 = create_test_document(title: "User1 Writable", content: "Content 1")
        doc1.acl = Parse::ACL.new
        doc1.acl.apply(user1.id, read: true, write: true)
        doc1.acl.apply(user2.id, read: true, write: false)  # User2 can read but not write
        doc1.acl.apply(:public, read: false, write: false)
        assert doc1.save, "Should save doc1 with user ACLs"

        # Document 2: Both users can write
        doc2 = create_test_document(title: "Both Users Writable", content: "Content 2")
        doc2.acl = Parse::ACL.new
        doc2.acl.apply(user1.id, read: true, write: true)
        doc2.acl.apply(user2.id, read: true, write: true)
        doc2.acl.apply(:public, read: false, write: false)
        assert doc2.save, "Should save doc2 with user ACLs"

        # Test writable_by user1 - should find both documents
        query_user1 = Parse::Query.new("TestDocument")
        query_user1.writable_by(user1)
        user1_results = query_user1.results
        
        user1_titles = user1_results.map { |doc| doc["title"] }.sort
        expected_user1_titles = ["User1 Writable", "Both Users Writable"].sort
        assert_equal expected_user1_titles, user1_titles, "User1 should write to both documents"

        # Test writable_by user2 - should find doc2 only
        query_user2 = Parse::Query.new("TestDocument")
        query_user2.writable_by(user2)
        user2_results = query_user2.results
        
        user2_titles = user2_results.map { |doc| doc["title"] }
        assert_equal ["Both Users Writable"], user2_titles, "User2 should write only to shared doc"

        puts "✅ writable_by user constraint integration test passed"
      end
    end
  end

  def test_mixed_readable_writable_constraints
    # Ensure Parse is setup before running the test
    Parse::Test::ServerHelper.setup
    
    with_parse_server do
      with_timeout(25, "mixed readable/writable constraints test") do
        puts "\n=== Testing Mixed readable_by and writable_by Constraints ==="

        # Clean up any existing test documents first
        TestDocument.query.results.each(&:destroy)
        sleep 0.1

        # Create test data
        admin_role = create_test_role("Admin")
        user1 = create_unique_test_user("mixeduser1")

        # Document with complex ACL
        doc1 = create_test_document(title: "Complex ACL Doc", content: "Complex content")
        doc1.acl = Parse::ACL.new
        doc1.acl.apply_role(admin_role.name, read: true, write: true)  # Admin: read/write
        doc1.acl.apply(user1.id, read: true, write: false)    # User1: read only
        doc1.acl.apply(:public, read: false, write: false)    # No public access
        assert doc1.save, "Should save complex ACL document"

        # Test compound query: readable_by user1 AND writable_by Admin
        query_complex = Parse::Query.new("TestDocument")
        query_complex.readable_by(user1)
        query_complex.writable_by(admin_role.name)
        
        complex_results = query_complex.results
        assert_equal 1, complex_results.size, "Should find 1 document matching both constraints"
        assert_equal "Complex ACL Doc", complex_results.first["title"], "Should find the complex ACL document"

        # Test query that should return no results: writable_by user1
        query_no_results = Parse::Query.new("TestDocument")
        query_no_results.writable_by(user1)
        
        no_results = query_no_results.results
        assert_equal 0, no_results.size, "User1 should not be able to write to any documents"

        puts "✅ Mixed readable/writable constraints test passed"
      end
    end
  end

  def test_acl_constraints_with_arrays
    # Ensure Parse is setup before running the test
    Parse::Test::ServerHelper.setup
    
    with_parse_server do
      with_timeout(20, "ACL constraints with arrays test") do
        puts "\n=== Testing ACL Constraints with Arrays ==="

        # Clean up any existing test documents first
        TestDocument.query.results.each(&:destroy)
        sleep 0.1

        # Create test roles
        admin_role = create_test_role("Admin")
        editor_role = create_test_role("Editor")
        viewer_role = create_test_role("Viewer")

        # Create documents with role-based access
        doc1 = create_test_document(title: "Admin Doc", content: "Admin content")
        doc1.acl = Parse::ACL.new
        doc1.acl.apply_role(admin_role.name, read: true, write: true)
        doc1.acl.apply(:public, read: false, write: false)
        assert doc1.save, "Should save admin doc"

        doc2 = create_test_document(title: "Editor Doc", content: "Editor content")
        doc2.acl = Parse::ACL.new
        doc2.acl.apply_role(editor_role.name, read: true, write: true)
        doc2.acl.apply(:public, read: false, write: false)
        assert doc2.save, "Should save editor doc"

        # Test readable_by with array of roles
        query_multiple = Parse::Query.new("TestDocument")
        query_multiple.readable_by([admin_role.name, editor_role.name])
        
        multiple_results = query_multiple.results
        assert_equal 2, multiple_results.size, "Should find documents for both roles"
        
        multiple_titles = multiple_results.map { |doc| doc["title"] }.sort
        expected_titles = ["Admin Doc", "Editor Doc"].sort
        assert_equal expected_titles, multiple_titles, "Should find documents for both Admin and Editor"

        puts "✅ ACL constraints with arrays test passed"
      end
    end
  end
end