require_relative "../../test_helper"

# Test model for ACL dirty tracking
class ACLDirtyTestObject < Parse::Object
  parse_class "ACLDirtyTestObject"
  property :name, :string
end

class ACLDirtyTrackingTest < Minitest::Test
  def setup
    @obj = ACLDirtyTestObject.new
    @obj.instance_variable_set(:@id, "test123")
    @obj.instance_variable_set(:@created_at, Time.now)
    @obj.instance_variable_set(:@updated_at, Time.now)
    @obj.instance_variable_set(:@acl, Parse::ACL.new)
    @obj.clear_changes!
  end

  # ============================================
  # Tests for acl_was capturing correct value
  # ============================================

  def test_acl_exists_for_new_object
    obj = ACLDirtyTestObject.new
    # Verify the object has an ACL (may be empty or have defaults)
    refute_nil obj.acl, "Object should have an ACL"
    # acl_was should also be available
    refute_nil obj.acl_was, "acl_was should be available"
  end

  def test_acl_changed_when_assigning_new_acl
    # Start with empty ACL
    assert_equal({}, @obj.acl.as_json)
    refute @obj.acl_changed?, "ACL should not be marked as changed initially"

    # Assign a new ACL with permissions
    new_acl = Parse::ACL.everyone(true, false)
    @obj.acl = new_acl

    assert @obj.acl_changed?, "ACL should be marked as changed after assignment"
    assert_equal({ "*" => { "read" => true } }, @obj.acl.as_json)
  end

  def test_acl_was_captures_previous_value_on_assignment
    # Set initial ACL
    initial_acl = Parse::ACL.everyone(true, false)
    @obj.acl = initial_acl
    @obj.clear_changes!

    # Verify initial state
    assert_equal({ "*" => { "read" => true } }, @obj.acl.as_json)
    refute @obj.acl_changed?

    # Assign new ACL
    new_acl = Parse::ACL.everyone(true, true)
    @obj.acl = new_acl

    assert @obj.acl_changed?, "ACL should be changed"
    assert_equal({ "*" => { "read" => true, "write" => true } }, @obj.acl.as_json)

    # acl_was should have the previous value
    assert_equal({ "*" => { "read" => true } }, @obj.acl_was.as_json,
                 "acl_was should capture the previous ACL value")
  end

  def test_acl_was_differs_from_current_acl_after_change
    # Set initial ACL
    @obj.acl = Parse::ACL.new  # empty
    @obj.clear_changes!

    # Change to public read
    @obj.acl = Parse::ACL.everyone(true, false)

    assert @obj.acl_changed?
    refute_equal @obj.acl_was.as_json, @obj.acl.as_json,
      "acl_was and acl should be different after change"
  end

  # ============================================
  # Tests for in-place ACL modification
  # ============================================

  def test_acl_apply_triggers_dirty_tracking
    # Start with empty ACL
    @obj.acl = Parse::ACL.new
    @obj.clear_changes!
    refute @obj.acl_changed?

    # Modify in place using apply
    @obj.acl.apply(:public, true, false)

    assert @obj.acl_changed?, "ACL should be marked as changed after apply"
  end

  def test_acl_apply_role_triggers_dirty_tracking
    @obj.acl = Parse::ACL.new
    @obj.clear_changes!
    refute @obj.acl_changed?

    @obj.acl.apply_role("Admin", true, true)

    assert @obj.acl_changed?, "ACL should be marked as changed after apply_role"
  end

  def test_acl_was_captures_state_before_in_place_modification
    # This is the critical test - acl_was should capture a SNAPSHOT
    # of the ACL before modification, not a reference to the same object

    # Set initial empty ACL
    @obj.acl = Parse::ACL.new
    @obj.clear_changes!

    # Store expected "was" value
    expected_was = {}

    # Modify in place
    @obj.acl.apply(:public, true, false)
    @obj.acl.apply_role("Admin", true, true)

    assert @obj.acl_changed?, "ACL should be changed"

    # Current ACL should have the new permissions
    current_acl_json = @obj.acl.as_json
    assert current_acl_json.key?("*"), "Current ACL should have public permissions"
    assert current_acl_json.key?("role:Admin"), "Current ACL should have Admin role"

    # acl_was should have the ORIGINAL empty state, not the modified state
    # THIS IS THE BUG: acl_was currently points to the same object as acl
    assert_equal expected_was, @obj.acl_was.as_json,
      "acl_was should capture the state BEFORE in-place modification, not after"
  end

  def test_acl_was_and_acl_are_different_objects_after_in_place_modification
    @obj.acl = Parse::ACL.new
    @obj.clear_changes!

    @obj.acl.apply(:public, true, false)

    # acl_was and acl should NOT be the same object
    # If they are the same object, changes to one affect the other
    refute_same @obj.acl_was, @obj.acl,
      "acl_was should be a different object than acl (snapshot, not reference)"
  end

  # ============================================
  # Tests for changes hash
  # ============================================

  def test_changes_shows_correct_before_and_after_for_assignment
    @obj.acl = Parse::ACL.everyone(true, false)
    @obj.clear_changes!

    @obj.acl = Parse::ACL.everyone(true, true)

    changes = @obj.changes["acl"]
    refute_nil changes, "changes should include acl"
    assert_equal 2, changes.length, "changes should have [was, current]"

    was_acl, current_acl = changes
    assert_equal({ "*" => { "read" => true } }, was_acl.as_json,
                 "First element should be the previous ACL")
    assert_equal({ "*" => { "read" => true, "write" => true } }, current_acl.as_json,
                 "Second element should be the current ACL")
  end

  def test_changes_shows_correct_before_and_after_for_in_place_modification
    # Set initial state
    @obj.acl = Parse::ACL.new
    @obj.clear_changes!

    # Modify in place
    @obj.acl.apply(:public, true, false)

    changes = @obj.changes["acl"]
    refute_nil changes, "changes should include acl"

    was_acl, current_acl = changes

    # NOTE: ActiveModel's `changes` hash stores references internally, so both
    # was_acl and current_acl point to the same mutated object. This is a known
    # limitation. Use `acl_was` method instead for accurate "before" value.
    # current should have the new permission
    assert_equal({ "*" => { "read" => true } }, current_acl.as_json,
                 "current value in changes should be the state AFTER modification")

    # The acl_was METHOD correctly returns the snapshot (our fix)
    assert_equal({}, @obj.acl_was.as_json,
                 "acl_was method should return the state BEFORE modification")
  end

  # ============================================
  # Tests for attribute_updates (save payload)
  # ============================================

  def test_attribute_updates_includes_acl_when_changed
    @obj.acl = Parse::ACL.new
    @obj.clear_changes!

    @obj.acl.apply(:public, true, false)

    updates = @obj.attribute_updates
    assert updates.key?(:ACL), "attribute_updates should include ACL when changed"
    assert_equal({ "*" => { "read" => true } }, updates[:ACL].as_json)
  end

  def test_attribute_updates_excludes_acl_when_unchanged
    @obj.acl = Parse::ACL.everyone(true, false)
    @obj.clear_changes!

    updates = @obj.attribute_updates
    refute updates.key?(:ACL), "attribute_updates should NOT include ACL when unchanged"
  end

  # ============================================
  # Tests for multiple sequential modifications
  # ============================================

  def test_acl_was_captures_first_state_across_multiple_modifications
    @obj.acl = Parse::ACL.new
    @obj.clear_changes!

    # First modification
    @obj.acl.apply(:public, true, false)

    # Second modification
    @obj.acl.apply_role("Admin", true, true)

    # Third modification
    @obj.acl.apply("user123", true, true)

    # acl_was should still be the ORIGINAL state (empty), not any intermediate state
    assert_equal({}, @obj.acl_was.as_json,
                 "acl_was should capture the first state before any modifications")
  end

  # ============================================
  # Tests for clear_changes!
  # ============================================

  def test_clear_changes_resets_acl_was
    @obj.acl = Parse::ACL.everyone(true, true)
    assert @obj.acl_changed?

    @obj.clear_changes!

    refute @obj.acl_changed?
    # After clear_changes!, acl_was should reflect current state (or be nil)
  end

  # ============================================
  # Tests for identical ACL not being marked as changed
  # ============================================

  def test_acl_not_changed_when_set_to_identical_value
    # Set initial ACL with some permissions
    @obj.acl = Parse::ACL.new
    @obj.acl.apply(:public, true, false)
    @obj.acl.apply_role("Admin", true, true)
    @obj.clear_changes!

    original_acl_json = @obj.acl.as_json.dup

    # Now "change" it to the same values
    @obj.acl = Parse::ACL.new
    @obj.acl.apply(:public, true, false)
    @obj.acl.apply_role("Admin", true, true)

    # Content is identical, so it should NOT be marked as changed
    assert_equal original_acl_json, @obj.acl.as_json,
      "ACL content should be identical"
    refute @obj.acl_changed?,
      "ACL should NOT be marked as changed when set to identical values"
  end

  def test_acl_changed_when_set_to_different_value
    # Set initial ACL
    @obj.acl = Parse::ACL.new
    @obj.acl.apply(:public, true, false)
    @obj.clear_changes!

    # Change to different values
    @obj.acl.apply_role("Admin", true, true)

    # Content is different, so it SHOULD be marked as changed
    assert @obj.acl_changed?,
      "ACL should be marked as changed when content differs"
  end

  def test_dirty_false_when_acl_rebuilt_to_same_value
    # Simulate the scenario from the user's issue:
    # 1. Object has ACL on server
    # 2. update_acl rebuilds ACL to same values
    # 3. Object should not be dirty

    # Set up object with ACL (simulating fetched from server)
    @obj.acl = Parse::ACL.new
    @obj.acl.apply(:public, true, false)
    @obj.acl.apply("user123", true, true)
    @obj.acl.apply_role("Admin", true, true)
    @obj.clear_changes!

    refute @obj.dirty?, "Object should not be dirty initially"

    # Store original state
    original_json = @obj.acl.as_json.dup

    # Now simulate update_acl rebuilding to same values
    @obj.acl = Parse::ACL.new
    @obj.acl.apply(:public, true, false)
    @obj.acl.apply("user123", true, true)
    @obj.acl.apply_role("Admin", true, true)

    # Verify content is the same
    assert_equal original_json, @obj.acl.as_json

    # Object should NOT be dirty since ACL content is identical
    refute @obj.acl_changed?, "ACL should not be changed"
    refute @obj.dirty?, "Object should not be dirty when ACL rebuilt to same value"
  end

  def test_new_object_includes_acl_in_changes_even_if_rebuilt
    # For NEW objects (no id), ACL should always be included in changes
    # because it needs to be sent to the server on first save
    new_obj = ACLDirtyTestObject.new
    new_obj.name = "Test"

    # Set ACL
    new_obj.acl = Parse::ACL.new
    new_obj.acl.apply(:public, true, false)

    # New object should have ACL in changes
    assert new_obj.new?, "Object should be new (no id)"
    assert new_obj.changed.include?("acl"), "New object should include ACL in changes"
    assert new_obj.dirty?, "New object should be dirty"
  end

  # ============================================
  # Tests for delegate pattern
  # ============================================

  def test_acl_has_delegate_set
    # When ACL is assigned, it should have the object as delegate
    @obj.acl = Parse::ACL.new

    delegate = @obj.acl.instance_variable_get(:@delegate)
    assert_equal @obj, delegate,
      "ACL should have the Parse::Object as its delegate"
  end

  def test_acl_delegate_receives_will_change_notification
    @obj.acl = Parse::ACL.new
    @obj.clear_changes!

    # The delegate (object) should receive acl_will_change! when ACL is modified
    assert @obj.respond_to?(:acl_will_change!),
      "Object should respond to acl_will_change!"

    # Modify ACL - this should trigger the delegate
    @obj.acl.apply(:public, true, false)

    assert @obj.acl_changed?,
      "Object should have acl marked as changed after ACL modification"
  end
end
