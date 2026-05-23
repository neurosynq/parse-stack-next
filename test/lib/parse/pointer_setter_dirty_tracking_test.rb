require_relative '../../test_helper'

# Test model for pointer setter dirty tracking
class PointerSetterTestModel < Parse::Object
  parse_class "PointerSetterTestModel"

  property :status, :string, enum: [:pending, :active, :completed]
  property :name, :string
  property :count, :integer

  belongs_to :related_item, as: :pointer_setter_test_item
  has_many :tags, through: :array
end

class PointerSetterTestItem < Parse::Object
  parse_class "PointerSetterTestItem"

  property :title, :string
end

class PointerSetterDirtyTrackingTest < Minitest::Test
  # These tests verify that when setting a field on a pointer object,
  # the dirty tracking is correctly maintained. Prior to the fix,
  # autofetch triggered during will_change! would clear the dirty state.

  def setup
    # Ensure autofetch is enabled (the default)
    # Tests will create pointer-like objects that would trigger autofetch
  end

  def test_setting_property_on_pointer_marks_as_dirty
    # Create a pointer-like object (has id but no timestamps)
    obj = PointerSetterTestModel.new
    obj.instance_variable_set(:@id, "abc123")
    obj.disable_autofetch!

    # Set a property - should mark as dirty
    obj.name = "Test Name"

    assert obj.dirty?, "Object should be dirty after setting name"
    assert obj.name_changed?, "name should be marked as changed"
    assert_equal "Test Name", obj.name
  end

  def test_setting_enum_property_on_pointer_marks_as_dirty
    # Create a pointer-like object
    obj = PointerSetterTestModel.new
    obj.instance_variable_set(:@id, "abc123")
    obj.disable_autofetch!

    # Set an enum property - should mark as dirty
    obj.status = :active

    assert obj.dirty?, "Object should be dirty after setting status"
    assert obj.status_changed?, "status should be marked as changed"
    assert_equal :active, obj.status
  end

  def test_setting_integer_property_on_pointer_marks_as_dirty
    # Create a pointer-like object
    obj = PointerSetterTestModel.new
    obj.instance_variable_set(:@id, "abc123")
    obj.disable_autofetch!

    # Set an integer property - should mark as dirty
    obj.count = 42

    assert obj.dirty?, "Object should be dirty after setting count"
    assert obj.count_changed?, "count should be marked as changed"
    assert_equal 42, obj.count
  end

  def test_setting_belongs_to_on_pointer_marks_as_dirty
    # Create a pointer-like object
    obj = PointerSetterTestModel.new
    obj.instance_variable_set(:@id, "abc123")
    obj.disable_autofetch!

    # Create a related item pointer
    item = PointerSetterTestItem.new
    item.instance_variable_set(:@id, "item456")

    # Set the belongs_to - should mark as dirty
    obj.related_item = item

    assert obj.dirty?, "Object should be dirty after setting related_item"
    assert obj.related_item_changed?, "related_item should be marked as changed"
    assert_equal item, obj.related_item
  end

  def test_setting_has_many_on_pointer_marks_as_dirty
    # Create a pointer-like object
    obj = PointerSetterTestModel.new
    obj.instance_variable_set(:@id, "abc123")
    obj.disable_autofetch!

    # Create some items for the array
    item1 = PointerSetterTestItem.new
    item1.instance_variable_set(:@id, "item1")
    item2 = PointerSetterTestItem.new
    item2.instance_variable_set(:@id, "item2")

    # Set the has_many - should mark as dirty
    obj.tags = [item1, item2]

    assert obj.dirty?, "Object should be dirty after setting tags"
    assert obj.tags_changed?, "tags should be marked as changed"
  end

  def test_setting_multiple_properties_on_pointer_all_marked_dirty
    # Create a pointer-like object
    obj = PointerSetterTestModel.new
    obj.instance_variable_set(:@id, "abc123")
    obj.disable_autofetch!

    # Set multiple properties
    obj.name = "Test Name"
    obj.status = :active
    obj.count = 100

    assert obj.dirty?, "Object should be dirty"
    assert obj.name_changed?, "name should be changed"
    assert obj.status_changed?, "status should be changed"
    assert obj.count_changed?, "count should be changed"

    # Verify changes hash includes at least the three we set
    # (may also include ACL or other auto-set fields)
    assert obj.changes.keys.size >= 3, "Should have at least 3 changed fields"
    assert obj.changes.key?("name"), "changes should include name"
    assert obj.changes.key?("status"), "changes should include status"
    assert obj.changes.key?("count"), "changes should include count"
  end

  def test_setting_same_value_does_not_mark_dirty
    # Create a pointer-like object with a value already set
    obj = PointerSetterTestModel.new
    obj.instance_variable_set(:@id, "abc123")
    obj.instance_variable_set(:@name, "Test Name")
    obj.disable_autofetch!
    obj.clear_changes!

    # Set the same value - should NOT mark as dirty
    obj.name = "Test Name"

    refute obj.name_changed?, "name should not be changed when set to same value"
  end

  def test_pointer_state_detection
    # Create a pointer-like object (has id but no created_at/updated_at)
    obj = PointerSetterTestModel.new
    obj.instance_variable_set(:@id, "abc123")

    assert obj.pointer?, "Object with id but no timestamps should be in pointer state"

    # Add timestamps - should no longer be pointer
    obj.instance_variable_set(:@created_at, Time.now)
    obj.instance_variable_set(:@updated_at, Time.now)

    refute obj.pointer?, "Object with timestamps should not be in pointer state"
  end

  def test_changes_preserved_through_setter_with_autofetch_disabled
    # This test verifies the core fix - that setting a field on a pointer
    # correctly marks it as dirty even when autofetch is disabled
    obj = PointerSetterTestModel.new
    obj.instance_variable_set(:@id, "abc123")
    obj.disable_autofetch!

    obj.name = "New Value"

    # Key assertion: the object should be dirty
    assert obj.dirty?, "Object MUST be dirty after assignment"

    # The changes hash should have the change recorded
    changes = obj.changes
    assert changes.key?("name"), "name should be in changes hash"
    assert_equal [nil, "New Value"], changes["name"], "Changes should show old (nil) and new value"
  end

  def test_attribute_updates_includes_changed_fields
    obj = PointerSetterTestModel.new
    obj.instance_variable_set(:@id, "abc123")
    obj.disable_autofetch!

    obj.name = "Test Name"
    obj.status = :active

    updates = obj.attribute_updates
    assert updates.key?(:name), "attribute_updates should include name"
    assert updates.key?(:status), "attribute_updates should include status"
  end

  def test_selective_keys_with_setter_marks_dirty
    # Test that setting a field on a selectively fetched object
    # (not a pointer - has timestamps) properly marks as dirty
    obj = PointerSetterTestModel.new
    obj.instance_variable_set(:@id, "abc123")
    obj.instance_variable_set(:@created_at, Time.now)
    obj.instance_variable_set(:@updated_at, Time.now)
    obj.fetched_keys = [:name]
    obj.disable_autofetch!

    # Set a field that was "fetched"
    obj.name = "New Name"

    assert obj.name_changed?, "Fetched field should be marked as changed"
    assert obj.dirty?, "Object should be dirty"
  end

  def test_selective_keys_setting_unfetched_field_marks_as_fetched_and_dirty
    # Test that setting an unfetched field adds it to fetched keys and marks dirty
    obj = PointerSetterTestModel.new
    obj.instance_variable_set(:@id, "abc123")
    obj.instance_variable_set(:@created_at, Time.now)
    obj.instance_variable_set(:@updated_at, Time.now)
    obj.fetched_keys = [:name]
    obj.disable_autofetch!

    # Set a field that was NOT originally fetched - this should work
    # because the setter adds it to fetched_keys before calling will_change!
    obj.count = 42

    assert obj.field_was_fetched?(:count), "count should now be marked as fetched"
    assert obj.count_changed?, "count should be marked as changed"
    assert obj.dirty?, "Object should be dirty"
  end
end
