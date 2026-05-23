require_relative "../../test_helper_integration"

class ACLDebugTest < Minitest::Test
  include ParseStackIntegrationTest

  class TestDoc < Parse::Object
    parse_class "TestDoc"
    property :title, :string
  end

  def test_acl_serialization_and_storage
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      puts "\n=== ACL Serialization and Storage Debug ==="

      # Find or create the TestRole
      test_role = Parse::Role.first_or_create!(name: "TestRole")
      puts "DEBUG: Using role: #{test_role.name} (#{test_role.id})"

      # Create a simple document with ACL
      doc = TestDoc.new(title: "Test Document")
      doc.acl = Parse::ACL.new
      doc.acl.apply(:public, read: true, write: false)
      doc.acl.apply_role(test_role.name, read: true, write: true)

      puts "DEBUG: ACL before save: #{doc.acl.as_json}"
      puts "DEBUG: Object as_json before save: #{doc.as_json}"

      # Save the document
      result = doc.save
      puts "DEBUG: Save result: #{result}"

      if result
        puts "DEBUG: Document ID: #{doc.id}"

        # Try to fetch it back
        fetched = TestDoc.query.where(:objectId => doc.id).first
        if fetched
          puts "DEBUG: Fetched document ACL: #{fetched.acl.as_json if fetched.acl}"
          puts "DEBUG: Fetched document as_json: #{fetched.as_json}"

          # Now test if the ACL constraint finds it
          public_query = TestDoc.query.readable_by("*")
          public_results = public_query.results
          puts "DEBUG: Public readable query results: #{public_results.size}"

          role_query = TestDoc.query.readable_by(test_role.name)
          role_results = role_query.results
          puts "DEBUG: #{test_role.name} readable query results: #{role_results.size}"

          # Test the pipeline generation
          puts "DEBUG: Public query pipeline: #{public_query.pipeline.inspect}"
          puts "DEBUG: Role query pipeline: #{role_query.pipeline.inspect}"
        else
          puts "ERROR: Could not fetch document back"
        end
      else
        puts "ERROR: Failed to save document"
      end
    end
  end
end
