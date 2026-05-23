require_relative '../../test_helper'

# Test model for collection proxy dirty tracking
class CollectionDirtyTestParent < Parse::Object
  parse_class "CollectionDirtyTestParent"

  property :name, :string
  has_many :items, through: :array
end

class CollectionDirtyTestItem < Parse::Object
  parse_class "CollectionDirtyTestItem"

  property :title, :string
  property :active, :boolean
end

class CollectionProxyDirtyTrackingTest < Minitest::Test

  def test_modifying_nested_item_does_not_mark_parent_dirty
    # Create parent with items
    parent = CollectionDirtyTestParent.new
    parent.instance_variable_set(:@id, "parent123")
    parent.instance_variable_set(:@created_at, Time.now)
    parent.instance_variable_set(:@updated_at, Time.now)

    # Create items
    item1 = CollectionDirtyTestItem.new
    item1.instance_variable_set(:@id, "item1")
    item1.instance_variable_set(:@created_at, Time.now)
    item1.instance_variable_set(:@updated_at, Time.now)
    item1.instance_variable_set(:@active, true)
    item1.clear_changes!

    # Set up the array with the item
    parent.items = [item1]
    parent.clear_changes!

    refute parent.dirty?, "Parent should not be dirty after clear_changes!"

    # Modify the nested item - this should NOT mark parent dirty
    parent.items.first.active = false

    # Verify the nested item is dirty
    assert item1.dirty?, "Item should be dirty after modifying active"
    assert item1.active_changed?, "Item's active should be changed"

    # Verify the parent is NOT dirty
    refute parent.dirty?, "Parent should NOT be dirty when nested item is modified"
    refute parent.items_changed?, "Parent's items should NOT be marked as changed"
  end

  def test_adding_item_marks_parent_dirty
    parent = CollectionDirtyTestParent.new
    parent.instance_variable_set(:@id, "parent123")
    parent.instance_variable_set(:@created_at, Time.now)
    parent.instance_variable_set(:@updated_at, Time.now)

    item1 = CollectionDirtyTestItem.new
    item1.instance_variable_set(:@id, "item1")

    parent.items = [item1]
    parent.clear_changes!

    item2 = CollectionDirtyTestItem.new
    item2.instance_variable_set(:@id, "item2")

    # Add a new item - this SHOULD mark parent dirty
    parent.items.add(item2)

    assert parent.dirty?, "Parent should be dirty after adding item"
    assert parent.items_changed?, "Parent's items should be marked as changed"
  end

  def test_removing_item_marks_parent_dirty
    parent = CollectionDirtyTestParent.new
    parent.instance_variable_set(:@id, "parent123")
    parent.instance_variable_set(:@created_at, Time.now)
    parent.instance_variable_set(:@updated_at, Time.now)

    item1 = CollectionDirtyTestItem.new
    item1.instance_variable_set(:@id, "item1")

    item2 = CollectionDirtyTestItem.new
    item2.instance_variable_set(:@id, "item2")

    parent.items = [item1, item2]
    parent.clear_changes!

    # Remove an item - this SHOULD mark parent dirty
    parent.items.remove(item1)

    assert parent.dirty?, "Parent should be dirty after removing item"
    assert parent.items_changed?, "Parent's items should be marked as changed"
  end

  def test_pointer_and_full_object_are_equal
    # Create a pointer
    item_pointer = CollectionDirtyTestItem.new
    item_pointer.instance_variable_set(:@id, "item1")
    # No timestamps, so it's a pointer

    # Create a full object with same id
    item_full = CollectionDirtyTestItem.new
    item_full.instance_variable_set(:@id, "item1")
    item_full.instance_variable_set(:@created_at, Time.now)
    item_full.instance_variable_set(:@updated_at, Time.now)
    item_full.instance_variable_set(:@title, "Test Title")
    item_full.instance_variable_set(:@active, true)

    # They should be equal (same class and id)
    assert_equal item_pointer, item_full, "Pointer and full object with same id should be equal"
    assert_equal item_full, item_pointer, "Full object and pointer with same id should be equal"
  end

  def test_objects_with_different_dirty_state_are_equal
    item1 = CollectionDirtyTestItem.new
    item1.instance_variable_set(:@id, "item1")
    item1.instance_variable_set(:@created_at, Time.now)
    item1.instance_variable_set(:@updated_at, Time.now)
    item1.instance_variable_set(:@active, true)
    item1.clear_changes!

    item2 = CollectionDirtyTestItem.new
    item2.instance_variable_set(:@id, "item1")
    item2.instance_variable_set(:@created_at, Time.now)
    item2.instance_variable_set(:@updated_at, Time.now)
    item2.instance_variable_set(:@active, true)
    item2.active = false  # Make item2 dirty

    assert item2.dirty?, "item2 should be dirty"
    refute item1.dirty?, "item1 should not be dirty"

    # Despite different dirty states, they should be equal (same id)
    assert_equal item1, item2, "Objects with same id should be equal regardless of dirty state"
  end

  def test_hash_consistency_with_equality
    # Ruby contract: a == b implies a.hash == b.hash
    item1 = CollectionDirtyTestItem.new
    item1.instance_variable_set(:@id, "item1")

    item2 = CollectionDirtyTestItem.new
    item2.instance_variable_set(:@id, "item1")
    item2.instance_variable_set(:@created_at, Time.now)
    item2.instance_variable_set(:@updated_at, Time.now)
    item2.active = false  # Make dirty

    # They should be equal
    assert_equal item1, item2, "Objects with same id should be equal"

    # Therefore their hashes should also be equal
    # NOTE: This test documents the DESIRED behavior. If it fails,
    # the hash method needs to be fixed to not include changes.
    assert_equal item1.hash, item2.hash, "Equal objects should have equal hashes"
  end

  def test_array_uniq_preserves_identity
    item1 = CollectionDirtyTestItem.new
    item1.instance_variable_set(:@id, "item1")
    item1.disable_autofetch!

    item2 = CollectionDirtyTestItem.new
    item2.instance_variable_set(:@id, "item1")
    item2.instance_variable_set(:@created_at, Time.now)
    item2.instance_variable_set(:@updated_at, Time.now)
    item2.instance_variable_set(:@active, true)

    item3 = CollectionDirtyTestItem.new
    item3.instance_variable_set(:@id, "item2")

    array = [item1, item2, item3]

    # uniq should remove duplicates based on identity (id)
    unique = array.uniq

    # Should have 2 unique items (item1/item2 are same id, item3 is different)
    assert_equal 2, unique.size, "Array#uniq should deduplicate by id"
  end
end
