require_relative "../../test_helper"

# Test model simulating the Capture class with traits array and boolean properties
class ArrayDirtyTestModel < Parse::Object
  parse_class "ArrayDirtyTestModel"

  property :name, :string
  property :traits, :array
  property :is_draft, :boolean
  property :on_timeline, :boolean
  property :tags, :array, symbolize: true
end

class ArrayPropertyDirtyTrackingTest < Minitest::Test
  def setup
    @model = ArrayDirtyTestModel.new
    @model.instance_variable_set(:@id, "test123")
    @model.instance_variable_set(:@created_at, Time.now)
    @model.instance_variable_set(:@updated_at, Time.now)
  end

  # ============================================
  # Basic Array Property Dirty Tracking
  # ============================================

  def test_array_property_starts_clean
    @model.clear_changes!
    refute @model.dirty?, "Model should not be dirty after clear_changes!"
    refute @model.traits_changed?, "traits should not be marked as changed"
  end

  def test_add_unique_marks_model_dirty
    @model.traits = []
    @model.clear_changes!

    @model.traits.add_unique("published")

    assert @model.dirty?, "Model should be dirty after add_unique"
    assert @model.traits_changed?, "traits should be marked as changed"
  end

  def test_add_unique_existing_item_still_marks_dirty
    # Even if item already exists, add_unique should still mark dirty
    # (the method calls notify_will_change! before checking uniqueness)
    @model.traits = ["published"]
    @model.clear_changes!

    @model.traits.add_unique("published")

    # Note: add_unique calls notify_will_change! before the union operation
    # so it marks dirty even if no actual change occurs
    assert @model.dirty?, "Model should be dirty after add_unique (even if item exists)"
  end

  def test_remove_marks_model_dirty
    @model.traits = ["draft", "published"]
    @model.clear_changes!

    @model.traits.remove("draft")

    assert @model.dirty?, "Model should be dirty after remove"
    assert @model.traits_changed?, "traits should be marked as changed"
  end

  def test_remove_nonexistent_item_still_marks_dirty
    @model.traits = ["published"]
    @model.clear_changes!

    @model.traits.remove("draft")

    # remove calls notify_will_change! before deleting
    assert @model.dirty?, "Model should be dirty after remove (even if item doesn't exist)"
  end

  def test_add_marks_model_dirty
    @model.traits = []
    @model.clear_changes!

    @model.traits.add("new_trait")

    assert @model.dirty?, "Model should be dirty after add"
    assert @model.traits_changed?, "traits should be marked as changed"
  end

  def test_push_marks_model_dirty
    @model.traits = []
    @model.clear_changes!

    @model.traits.push("new_trait")

    assert @model.dirty?, "Model should be dirty after push"
    assert @model.traits_changed?, "traits should be marked as changed"
  end

  def test_shovel_operator_marks_model_dirty
    @model.traits = []
    @model.clear_changes!

    @model.traits << "new_trait"

    assert @model.dirty?, "Model should be dirty after << operator"
    assert @model.traits_changed?, "traits should be marked as changed"
  end

  # ============================================
  # Boolean Property Dirty Tracking
  # ============================================

  def test_boolean_property_change_marks_dirty
    @model.is_draft = true
    @model.clear_changes!

    @model.is_draft = false

    assert @model.dirty?, "Model should be dirty after boolean change"
    assert @model.is_draft_changed?, "is_draft should be marked as changed"
  end

  def test_boolean_property_same_value_not_dirty
    @model.is_draft = false
    @model.clear_changes!

    @model.is_draft = false

    refute @model.dirty?, "Model should NOT be dirty when setting same value"
    refute @model.is_draft_changed?, "is_draft should NOT be marked as changed"
  end

  def test_boolean_nil_to_false_marks_dirty
    @model.instance_variable_set(:@is_draft, nil)
    @model.clear_changes!

    @model.is_draft = false

    assert @model.dirty?, "Model should be dirty when changing nil to false"
    assert @model.is_draft_changed?, "is_draft should be marked as changed"
  end

  def test_boolean_nil_to_true_marks_dirty
    @model.instance_variable_set(:@is_draft, nil)
    @model.clear_changes!

    @model.is_draft = true

    assert @model.dirty?, "Model should be dirty when changing nil to true"
    assert @model.is_draft_changed?, "is_draft should be marked as changed"
  end

  # ============================================
  # Combined Property Changes (Simulating publish!)
  # ============================================

  def test_multiple_changes_all_tracked
    @model.traits = ["draft"]
    @model.is_draft = true
    @model.on_timeline = false
    @model.clear_changes!

    # Simulate publish! logic
    @model.traits.add_unique("published") unless @model.traits.include?("published")
    @model.traits.remove("draft") if @model.traits.include?("draft")
    @model.is_draft = false
    @model.on_timeline = true

    assert @model.dirty?, "Model should be dirty after multiple changes"
    assert @model.traits_changed?, "traits should be marked as changed"
    assert @model.is_draft_changed?, "is_draft should be marked as changed"
    assert @model.on_timeline_changed?, "on_timeline should be marked as changed"
  end

  def test_publish_scenario_already_published_only_boolean_changes
    # Scenario: already published, just need to update booleans
    @model.traits = ["published"]
    @model.is_draft = true
    @model.on_timeline = false
    @model.clear_changes!

    # Simulate publish! logic - traits won't change because already published
    @model.traits.add_unique("published") unless @model.traits.include?("published")
    @model.traits.remove("draft") if @model.traits.include?("draft")
    @model.is_draft = false
    @model.on_timeline = true

    assert @model.dirty?, "Model should be dirty from boolean changes"
    # traits won't be changed because the guards prevented the calls
    refute @model.traits_changed?, "traits should NOT be changed (guards prevented calls)"
    assert @model.is_draft_changed?, "is_draft should be marked as changed"
    assert @model.on_timeline_changed?, "on_timeline should be marked as changed"
  end

  def test_publish_scenario_no_changes_when_already_in_final_state
    # Scenario: already in published state, nothing to change
    @model.traits = ["published"]
    @model.is_draft = false
    @model.on_timeline = true
    @model.clear_changes!

    # Simulate publish! logic - nothing changes
    @model.traits.add_unique("published") unless @model.traits.include?("published")
    @model.traits.remove("draft") if @model.traits.include?("draft")
    @model.is_draft = false
    @model.on_timeline = true

    refute @model.dirty?, "Model should NOT be dirty when already in final state"
    refute @model.traits_changed?, "traits should NOT be changed"
    refute @model.is_draft_changed?, "is_draft should NOT be changed"
    refute @model.on_timeline_changed?, "on_timeline should NOT be changed"
  end

  # ============================================
  # Symbolized Array Property Dirty Tracking
  # ============================================

  def test_symbolized_array_add_unique_marks_dirty
    @model.tags = []
    @model.clear_changes!

    @model.tags.add_unique(:important)

    assert @model.dirty?, "Model should be dirty after add_unique on symbolized array"
    assert @model.tags_changed?, "tags should be marked as changed"
  end

  def test_symbolized_array_remove_marks_dirty
    @model.tags = [:draft, :important]
    @model.clear_changes!

    @model.tags.remove(:draft)

    assert @model.dirty?, "Model should be dirty after remove on symbolized array"
    assert @model.tags_changed?, "tags should be marked as changed"
  end

  def test_symbolized_array_include_check_works
    @model.tags = [:published, :featured]
    @model.clear_changes!

    # Verify include? works with symbols
    assert @model.tags.include?(:published), "should find :published symbol"
    assert @model.tags.include?(:featured), "should find :featured symbol"
    refute @model.tags.include?(:draft), "should not find :draft symbol"

    # include? should not mark dirty
    refute @model.dirty?, "include? check should not mark model dirty"
  end

  # ============================================
  # Collection Proxy State
  # ============================================

  def test_collection_proxy_has_delegate
    @model.traits = ["test"]
    @model.clear_changes!

    proxy = @model.instance_variable_get(:@traits)
    assert_kind_of Parse::CollectionProxy, proxy, "traits should be a CollectionProxy"

    delegate = proxy.instance_variable_get(:@delegate)
    assert_equal @model, delegate, "CollectionProxy delegate should be the model"
  end

  def test_collection_proxy_has_correct_key
    @model.traits = ["test"]
    @model.clear_changes!

    proxy = @model.instance_variable_get(:@traits)
    key = proxy.instance_variable_get(:@key)
    assert_equal :traits, key, "CollectionProxy key should be :traits"
  end

  def test_collection_proxy_notify_will_change_forwards_to_model
    @model.traits = []
    @model.clear_changes!

    proxy = @model.instance_variable_get(:@traits)
    proxy.notify_will_change!

    assert @model.traits_changed?, "notify_will_change! should mark model's traits as changed"
    assert @model.dirty?, "notify_will_change! should mark model as dirty"
  end

  # ============================================
  # Changed Method Behavior
  # ============================================

  def test_changed_returns_array_of_changed_attributes
    @model.traits = []
    @model.is_draft = true
    @model.clear_changes!

    @model.traits.add("new")
    @model.is_draft = false

    changed = @model.changed
    assert_includes changed, "traits", "changed should include 'traits'"
    assert_includes changed, "is_draft", "changed should include 'is_draft'"
  end

  def test_changes_returns_hash_with_old_and_new_values
    @model.is_draft = true
    @model.clear_changes!

    @model.is_draft = false

    changes = @model.changes
    assert changes.key?("is_draft"), "changes should have is_draft key"
    assert_equal [true, false], changes["is_draft"], "changes should show [old, new] values"
  end

  def test_dirty_with_field_parameter
    @model.traits = []
    @model.is_draft = true
    @model.clear_changes!

    @model.traits.add("new")

    assert @model.dirty?(:traits), "dirty?(:traits) should return true"
    refute @model.dirty?(:is_draft), "dirty?(:is_draft) should return false"
  end

  # ============================================
  # Edge Cases
  # ============================================

  def test_nil_array_gets_initialized_as_collection_proxy
    fresh_model = ArrayDirtyTestModel.new
    fresh_model.instance_variable_set(:@id, "fresh123")
    fresh_model.disable_autofetch!

    # Accessing nil array should initialize it as CollectionProxy
    traits = fresh_model.traits

    assert_kind_of Parse::CollectionProxy, traits, "nil array should become CollectionProxy"
  end

  def test_add_unique_on_freshly_initialized_array
    fresh_model = ArrayDirtyTestModel.new
    fresh_model.instance_variable_set(:@id, "fresh123")
    fresh_model.disable_autofetch!
    fresh_model.clear_changes!

    # This should work even on a freshly accessed (nil -> CollectionProxy) array
    fresh_model.traits.add_unique("published")

    assert fresh_model.dirty?, "Model should be dirty after add_unique on fresh array"
    assert fresh_model.traits_changed?, "traits should be marked as changed"
  end

  def test_empty_add_does_not_mark_dirty
    @model.traits = ["existing"]
    @model.clear_changes!

    # add with no items should not mark dirty
    @model.traits.add

    refute @model.dirty?, "Model should NOT be dirty after empty add"
  end

  def test_empty_remove_does_not_mark_dirty
    @model.traits = ["existing"]
    @model.clear_changes!

    # remove with no items should not mark dirty
    @model.traits.remove

    refute @model.dirty?, "Model should NOT be dirty after empty remove"
  end

  def test_uniq_bang_marks_dirty
    @model.traits = ["a", "b", "a"]
    @model.clear_changes!

    @model.traits.uniq!

    assert @model.dirty?, "Model should be dirty after uniq!"
    assert @model.traits_changed?, "traits should be marked as changed"
  end

  def test_collection_assignment_marks_dirty
    @model.traits = ["old"]
    @model.clear_changes!

    @model.traits = ["new"]

    assert @model.dirty?, "Model should be dirty after array assignment"
    assert @model.traits_changed?, "traits should be marked as changed"
  end

  # ============================================
  # Simulating Server Fetch (Apply) Scenarios
  # ============================================

  def test_apply_creates_collection_proxy_with_delegate
    # Simulate what happens when data comes from server via set_attributes!
    model = ArrayDirtyTestModel.new
    model.set_attributes!({ "objectId" => "server123", "traits" => ["draft"] }, false)
    model.clear_changes!

    # Verify the traits is a CollectionProxy with proper delegate
    proxy = model.instance_variable_get(:@traits)
    assert_kind_of Parse::CollectionProxy, proxy, "traits should be CollectionProxy after apply"

    delegate = proxy.instance_variable_get(:@delegate)
    assert_equal model, delegate, "CollectionProxy delegate should be the model after apply"

    key = proxy.instance_variable_get(:@key)
    assert_equal :traits, key, "CollectionProxy key should be :traits after apply"
  end

  def test_add_unique_after_apply_marks_dirty
    # Simulate fetching from server then modifying
    model = ArrayDirtyTestModel.new
    model.set_attributes!({ "objectId" => "server123", "traits" => ["draft"] }, false)
    model.clear_changes!

    # This is the critical test - does add_unique work after apply?
    model.traits.add_unique("published")

    assert model.dirty?, "Model should be dirty after add_unique (post-apply)"
    assert model.traits_changed?, "traits should be marked as changed (post-apply)"
  end

  def test_remove_after_apply_marks_dirty
    model = ArrayDirtyTestModel.new
    model.set_attributes!({ "objectId" => "server123", "traits" => ["draft", "published"] }, false)
    model.clear_changes!

    model.traits.remove("draft")

    assert model.dirty?, "Model should be dirty after remove (post-apply)"
    assert model.traits_changed?, "traits should be marked as changed (post-apply)"
  end

  def test_symbolized_array_after_apply
    model = ArrayDirtyTestModel.new
    model.set_attributes!({ "objectId" => "server123", "tags" => ["important", "urgent"] }, false)
    model.clear_changes!

    # Verify it's a CollectionProxy
    proxy = model.instance_variable_get(:@tags)
    assert_kind_of Parse::CollectionProxy, proxy, "tags should be CollectionProxy after apply"

    # Test that add_unique works
    model.tags.add_unique(:new_tag)

    assert model.dirty?, "Model should be dirty after add_unique on symbolized array (post-apply)"
    assert model.tags_changed?, "tags should be marked as changed (post-apply)"
  end

  def test_publish_scenario_after_apply
    # This is the exact scenario the user is experiencing
    model = ArrayDirtyTestModel.new
    model.set_attributes!({
      "objectId" => "capture123",
      "traits" => ["draft"],
      "is_draft" => true,
      "on_timeline" => false,
    }, false)
    model.clear_changes!

    refute model.dirty?, "Model should start clean"

    # Simulate publish! logic
    model.traits.add_unique("published") unless model.traits.include?("published")
    model.traits.remove("draft") if model.traits.include?("draft")
    model.is_draft = false
    model.on_timeline = true

    # All changes should be tracked
    assert model.dirty?, "Model should be dirty after publish changes"
    assert model.traits_changed?, "traits should be changed"
    assert model.is_draft_changed?, "is_draft should be changed"
    assert model.on_timeline_changed?, "on_timeline should be changed"

    # Verify the actual changes
    assert_includes model.traits.to_a, "published"
    refute_includes model.traits.to_a, "draft"
    assert_equal false, model.is_draft
    assert_equal true, model.on_timeline
  end

  def test_collection_proxy_delegate_survives_clear_changes
    model = ArrayDirtyTestModel.new
    model.set_attributes!({ "objectId" => "server123", "traits" => ["draft"] }, false)
    model.clear_changes!

    proxy = model.instance_variable_get(:@traits)
    delegate_before = proxy.instance_variable_get(:@delegate)

    # Clear changes again
    model.clear_changes!

    delegate_after = proxy.instance_variable_get(:@delegate)
    assert_equal delegate_before, delegate_after, "Delegate should survive clear_changes!"
    assert_equal model, delegate_after, "Delegate should still be the model"
  end

  # ============================================
  # clear_attribute_change! Tests (for direct_save)
  # ============================================

  def test_clear_attribute_change_only_clears_specified_field
    @model.traits = ["new_trait"]
    @model.is_draft = true
    @model.on_timeline = true
    @model.clear_changes!

    # Make multiple changes
    @model.traits.add("another")
    @model.is_draft = false
    @model.on_timeline = false

    assert @model.traits_changed?, "traits should be changed"
    assert @model.is_draft_changed?, "is_draft should be changed"
    assert @model.on_timeline_changed?, "on_timeline should be changed"

    # Clear only traits - simulates direct_save for traits field
    @model.clear_attribute_change!([:traits])

    # traits should no longer be dirty
    refute @model.traits_changed?, "traits should NOT be changed after clear_attribute_change!"

    # Other fields should STILL be dirty
    assert @model.is_draft_changed?, "is_draft should STILL be changed"
    assert @model.on_timeline_changed?, "on_timeline should STILL be changed"
    assert @model.dirty?, "Model should still be dirty (other fields changed)"
  end

  def test_clear_attribute_change_multiple_fields
    @model.traits = []
    @model.is_draft = true
    @model.on_timeline = true
    @model.name = "original"
    @model.clear_changes!

    # Make changes to all fields
    @model.traits.add("trait")
    @model.is_draft = false
    @model.on_timeline = false
    @model.name = "changed"

    assert @model.dirty?, "Model should be dirty"

    # Clear traits and is_draft, but NOT on_timeline and name
    @model.clear_attribute_change!([:traits, :is_draft])

    refute @model.traits_changed?, "traits should NOT be changed"
    refute @model.is_draft_changed?, "is_draft should NOT be changed"
    assert @model.on_timeline_changed?, "on_timeline should STILL be changed"
    assert @model.name_changed?, "name should STILL be changed"
    assert @model.dirty?, "Model should still be dirty"
  end

  def test_clear_attribute_change_with_string_field_names
    @model.traits = []
    @model.is_draft = true
    @model.clear_changes!

    @model.traits.add("trait")
    @model.is_draft = false

    # Clear using string field names (as might happen from direct_save)
    @model.clear_attribute_change!(["traits"])

    refute @model.traits_changed?, "traits should NOT be changed (string key)"
    assert @model.is_draft_changed?, "is_draft should STILL be changed"
  end

  def test_direct_save_scenario_preserves_other_changes
    # This simulates what happens in publish! when direct_save is called
    model = ArrayDirtyTestModel.new
    model.set_attributes!({
      "objectId" => "capture123",
      "traits" => ["draft"],
      "is_draft" => true,
      "on_timeline" => false,
      "tags" => ["old_tag"],
    }, false)
    model.clear_changes!

    # Simulate publish! making changes
    model.traits.add_unique("published")
    model.traits.remove("draft")
    model.is_draft = false
    model.on_timeline = true

    assert model.dirty?, "Model should be dirty after publish changes"

    # Simulate direct_save being called for tags field only
    # (like update_assets! saving assets field)
    model.tags.add("new_tag")
    model.clear_attribute_change!([:tags])

    # tags should be cleared
    refute model.tags_changed?, "tags should NOT be changed after direct_save"

    # BUT all other publish! changes should still be dirty!
    assert model.traits_changed?, "traits should STILL be changed after tags direct_save"
    assert model.is_draft_changed?, "is_draft should STILL be changed after tags direct_save"
    assert model.on_timeline_changed?, "on_timeline should STILL be changed after tags direct_save"
    assert model.dirty?, "Model should STILL be dirty for non-direct_save fields"
  end

  def test_changed_after_partial_clear
    @model.traits = []
    @model.is_draft = true
    @model.on_timeline = false
    @model.clear_changes!

    @model.traits.add("x")
    @model.is_draft = false
    @model.on_timeline = true

    # Clear one field
    @model.clear_attribute_change!([:traits])

    # changed should still include the other fields
    changed_fields = @model.changed
    refute_includes changed_fields, "traits", "changed should not include traits"
    assert_includes changed_fields, "is_draft", "changed should include is_draft"
    assert_includes changed_fields, "on_timeline", "changed should include on_timeline"
  end
end
