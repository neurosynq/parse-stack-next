require_relative "../../test_helper_integration"

class ACLDirtyTrackingIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  class ACLTrackingTestDoc < Parse::Object
    parse_class "ACLTrackingTestDoc"
    property :title, :string
  end

  def test_acl_was_captures_original_state_before_in_place_modification
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      # Create a document with empty ACL
      doc = ACLTrackingTestDoc.new(title: "ACL Tracking Test")
      doc.acl = Parse::ACL.new  # Empty ACL (master key only)

      assert doc.save, "Initial save should succeed"
      doc_id = doc.id
      refute_nil doc_id

      # Fetch the document fresh
      fetched_doc = ACLTrackingTestDoc.find(doc_id)
      refute_nil fetched_doc

      # Clear any existing change tracking
      fetched_doc.clear_changes!

      # Store the original ACL state
      original_acl_json = fetched_doc.acl.as_json.dup

      # Modify ACL in place
      fetched_doc.acl.apply(:public, true, false)  # Add public read
      fetched_doc.acl.apply_role("Admin", true, true)  # Add Admin role

      # Verify acl_changed? is true
      assert fetched_doc.acl_changed?, "ACL should be marked as changed after in-place modification"

      # Verify acl_was captures the ORIGINAL state, not the mutated state
      assert_equal original_acl_json, fetched_doc.acl_was.as_json,
        "acl_was should capture the original state before modification"

      # Verify current ACL has the new permissions
      current_acl = fetched_doc.acl.as_json
      assert current_acl.key?("*"), "Current ACL should have public permissions"
      assert current_acl.key?("role:Admin"), "Current ACL should have Admin role"

      # Verify acl_was and acl are different
      refute_equal fetched_doc.acl_was.as_json, fetched_doc.acl.as_json,
        "acl_was and acl should be different after modification"

      # Save the modified document
      assert fetched_doc.save, "Save with modified ACL should succeed"

      # Fetch again and verify the new ACL was persisted
      refetched_doc = ACLTrackingTestDoc.find(doc_id)
      persisted_acl = refetched_doc.acl.as_json

      assert persisted_acl.key?("*"), "Persisted ACL should have public permissions"
      assert_equal true, persisted_acl["*"]["read"], "Public should have read access"
      assert persisted_acl.key?("role:Admin"), "Persisted ACL should have Admin role"

      # Cleanup
      refetched_doc.destroy
    end
  end

  def test_acl_modification_persists_correctly_after_multiple_changes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      # Create document with initial ACL
      doc = ACLTrackingTestDoc.new(title: "Multiple Changes Test")
      doc.acl = Parse::ACL.new
      doc.acl.apply(:public, true, false)

      assert doc.save, "Initial save should succeed"
      doc_id = doc.id

      # Fetch fresh
      fetched_doc = ACLTrackingTestDoc.find(doc_id)
      fetched_doc.clear_changes!

      # Store original state
      original_acl_json = fetched_doc.acl.as_json.dup

      # Make multiple in-place modifications
      fetched_doc.acl.apply(:public, true, true)  # Add public write
      fetched_doc.acl.apply_role("Editor", true, true)
      fetched_doc.acl.apply("user123", true, false)

      # acl_was should still be the FIRST original state
      assert_equal original_acl_json, fetched_doc.acl_was.as_json,
        "acl_was should capture first state even after multiple modifications"

      # Save
      assert fetched_doc.save, "Save should succeed"

      # Verify persistence
      refetched = ACLTrackingTestDoc.find(doc_id)
      final_acl = refetched.acl.as_json

      assert_equal true, final_acl["*"]["read"], "Public read should be set"
      assert_equal true, final_acl["*"]["write"], "Public write should be set"
      assert final_acl.key?("role:Editor"), "Editor role should be present"
      assert final_acl.key?("user123"), "User permission should be present"

      # Cleanup
      refetched.destroy
    end
  end

  def test_acl_assignment_vs_in_place_modification
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      # Test 1: Assignment (replacing entire ACL)
      doc1 = ACLTrackingTestDoc.new(title: "Assignment Test")
      doc1.acl = Parse::ACL.new
      assert doc1.save
      doc1_id = doc1.id

      fetched1 = ACLTrackingTestDoc.find(doc1_id)
      fetched1.clear_changes!
      original_acl1 = fetched1.acl.as_json.dup

      # Assign a completely new ACL
      new_acl = Parse::ACL.everyone(true, true)
      fetched1.acl = new_acl

      assert fetched1.acl_changed?
      assert_equal original_acl1, fetched1.acl_was.as_json,
        "acl_was should capture original state for assignment"
      assert fetched1.save

      # Test 2: In-place modification
      doc2 = ACLTrackingTestDoc.new(title: "In-place Test")
      doc2.acl = Parse::ACL.new
      assert doc2.save
      doc2_id = doc2.id

      fetched2 = ACLTrackingTestDoc.find(doc2_id)
      fetched2.clear_changes!
      original_acl2 = fetched2.acl.as_json.dup

      # Modify in place
      fetched2.acl.apply(:public, true, true)

      assert fetched2.acl_changed?
      assert_equal original_acl2, fetched2.acl_was.as_json,
        "acl_was should capture original state for in-place modification"
      assert fetched2.save

      # Verify both persisted correctly
      verify1 = ACLTrackingTestDoc.find(doc1_id)
      verify2 = ACLTrackingTestDoc.find(doc2_id)

      assert_equal true, verify1.acl.as_json["*"]["read"]
      assert_equal true, verify1.acl.as_json["*"]["write"]
      assert_equal true, verify2.acl.as_json["*"]["read"]
      assert_equal true, verify2.acl.as_json["*"]["write"]

      # Cleanup
      verify1.destroy
      verify2.destroy
    end
  end
end
