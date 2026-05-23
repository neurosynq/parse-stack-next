require_relative '../../test_helper_integration'

class ACLNullTest < Minitest::Test
  include ParseStackIntegrationTest
  
  class TestDoc < Parse::Object
    parse_class "TestDocNullACL"
    property :title, :string
  end
  
  def test_acl_constraints_with_null_rperm_wperm
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      puts "\n=== Testing ACL Constraints with null/undefined _rperm/_wperm ==="
      
      # Clean up first
      TestDoc.query.results.each(&:destroy)
      sleep 0.1
      
      # Create a document without any ACL (should be publicly accessible)
      doc_no_acl = TestDoc.new(title: "No ACL Document")
      assert doc_no_acl.save, "Should save document without ACL"
      
      # Create a document with explicit ACL
      test_role = Parse::Role.first_or_create!(name: "TestRoleNullTest")
      doc_with_acl = TestDoc.new(title: "With ACL Document")
      doc_with_acl.acl = Parse::ACL.new
      doc_with_acl.acl.apply_role(test_role.name, read: true, write: true)
      doc_with_acl.acl.apply(:public, read: false, write: false)
      assert doc_with_acl.save, "Should save document with ACL"
      
      # Test public readable query - should find the no-ACL document
      public_query = TestDoc.query.readable_by("*")
      public_results = public_query.results
      puts "DEBUG: Public readable results: #{public_results.map(&:title)}"
      
      # Test role readable query - should find both documents (ACL doc + no-ACL doc)
      role_query = TestDoc.query.readable_by(test_role.name)
      role_results = role_query.results
      puts "DEBUG: Role readable results: #{role_results.map(&:title)}"
      
      # Test public writable query - should find the no-ACL document
      public_writable = TestDoc.query.writable_by("*")
      writable_results = public_writable.results
      puts "DEBUG: Public writable results: #{writable_results.map(&:title)}"
      
      # Verify pipelines include null checks
      puts "DEBUG: Public readable pipeline: #{public_query.pipeline.inspect}"
      puts "DEBUG: Role readable pipeline: #{role_query.pipeline.inspect}"
      puts "DEBUG: Public writable pipeline: #{public_writable.pipeline.inspect}"
      
      # Assertions
      assert public_results.any? { |doc| doc.title == "No ACL Document" }, "Public query should find no-ACL document"
      assert role_results.any? { |doc| doc.title == "No ACL Document" }, "Role query should find no-ACL document"
      assert role_results.any? { |doc| doc.title == "With ACL Document" }, "Role query should find ACL document"
      assert writable_results.any? { |doc| doc.title == "No ACL Document" }, "Public writable should find no-ACL document"
      
      puts "✅ ACL constraints correctly handle null/undefined _rperm/_wperm fields"
    end
  end
end