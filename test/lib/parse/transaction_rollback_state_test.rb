require_relative "../../test_helper"
require "minitest/autorun"
require "ostruct"

# Unit coverage for the state a transaction rollback captures and restores.
#
# The rollback used to snapshot `Parse::Object#attributes` and restore it into
# `@attributes`. That method returns a SCHEMA map (field name to type symbol),
# not values, so the restore rolled nothing back. Worse, `@attributes` is the
# ivar `ActiveModel::Dirty` keys on: once defined, `mutations_from_database`
# builds an `AttributeMutationTracker` over it, and `forget_attribute_assignments`
# calls `map(&:forgetting_assignment)` on it. Both then raised `NoMethodError`
# against a schema Hash, and both call sites rescue and warn, so every rollback
# silently downgraded the object to broken change tracking.
#
# The existing integration coverage asserted rollback by re-fetching from the
# server, which only proves the SERVER was untouched. These tests assert the
# in-memory half.
class TransactionRollbackStateTest < Minitest::Test
  class RollbackWidget < Parse::Object
    parse_class "RollbackWidget"
    property :title, :string
    property :quantity, :integer
    property :tags, :array
    property :metadata, :object
    property :note, :string
    has_many :related_widgets, as: :rollback_widget, through: :relation
  end

  def build_widget
    widget = RollbackWidget.new(
      title: "original",
      quantity: 1,
      tags: ["a"],
      metadata: { nested: { count: 1 } },
    )
    widget.clear_changes!
    widget
  end

  def with_failed_batch
    original_new = Parse::BatchOperation.method(:new)
    Parse::BatchOperation.define_singleton_method(:new) do |*args, **kwargs|
      batch = original_new.call(*args, **kwargs)
      batch.define_singleton_method(:submit) do
        [OpenStruct.new(success?: false, error: "forced failure")]
      end
      batch
    end
    yield
  ensure
    Parse::BatchOperation.define_singleton_method(:new, &original_new)
  end

  def test_snapshot_captures_property_values_not_the_schema
    widget = build_widget
    snapshot = Parse::Core::Actions.snapshot_property_values(widget)

    assert_equal "original", snapshot[:@title]
    assert_equal 1, snapshot[:@quantity]
    assert_equal ["a"], snapshot[:@tags]

    # The schema map would have had type symbols as values. If any value is a
    # bare type symbol for a field of that name, the snapshot is the schema.
    refute_equal :string, snapshot[:@title]
    refute_equal :integer, snapshot[:@quantity]
  end

  def test_snapshot_dups_mutable_values_so_later_mutation_does_not_corrupt_it
    widget = build_widget
    snapshot = Parse::Core::Actions.snapshot_property_values(widget)

    # Mutate the live array in place, the way an `<<` on a property would.
    widget.instance_variable_get(:@tags) << "b"

    assert_equal ["a"], snapshot[:@tags],
                 "in-place mutation after the snapshot must not reach the saved copy"
  end

  def test_snapshot_deeply_dups_nested_values
    widget = build_widget
    snapshot = Parse::Core::Actions.snapshot_property_values(widget)

    widget.metadata[:nested][:count] = 2

    assert_equal 1, snapshot[:@metadata][:nested][:count],
                 "nested mutation after the snapshot must not reach the saved copy"
  end

  def test_snapshot_isolates_relation_operation_arrays
    widget = build_widget
    relation = widget.related_widgets
    relation.loaded = true
    snapshot = Parse::Core::Actions.snapshot_property_values(widget)
    related = RollbackWidget.new(title: "related")

    relation.add(related)

    saved_relation = snapshot[:@related_widgets]
    assert_empty saved_relation.additions
    assert_empty saved_relation.removals
    assert_empty saved_relation.to_a
  end

  def test_rollback_restores_property_values
    widget = build_widget
    state = {
      object: widget,
      property_values: Parse::Core::Actions.snapshot_property_values(widget),
      changed_attributes: {},
      id: widget.id,
      mutations_from_database: nil,
      mutations_before_last_save: nil,
    }

    widget.title = "modified"
    widget.quantity = 99
    assert_equal "modified", widget.title

    Parse::Core::Actions.rollback_object_state(state)

    assert_equal "original", widget.title, "rollback must restore the local value"
    assert_equal 1, widget.quantity, "rollback must restore the local value"
  end

  # The regression itself: after a rollback the object must still have working
  # ActiveModel dirty tracking. Before the fix, `@attributes` was left defined
  # as a schema Hash and both of these raised NoMethodError internally.
  def test_rollback_leaves_dirty_tracking_functional
    widget = build_widget
    state = {
      object: widget,
      property_values: Parse::Core::Actions.snapshot_property_values(widget),
      changed_attributes: {},
      id: widget.id,
      mutations_from_database: nil,
      mutations_before_last_save: nil,
    }

    widget.title = "modified"
    Parse::Core::Actions.rollback_object_state(state)

    # Each of these walks ActiveModel's mutation tracker.
    changed_list = nil
    clear_error = nil
    begin
      changed_list = widget.changed
      widget.title = "changed again"
      assert widget.changed?, "dirty tracking must still register a new assignment"
      widget.clear_changes!
    rescue NoMethodError => e
      clear_error = e
    end

    assert_nil clear_error,
               "dirty tracking raised after rollback: #{clear_error&.message}"
    refute_nil changed_list
    refute widget.changed?, "clear_changes! must actually clear after a rollback"
  end

  def test_rollback_does_not_define_the_activemodel_attributes_ivar
    widget = build_widget
    state = {
      object: widget,
      property_values: Parse::Core::Actions.snapshot_property_values(widget),
      changed_attributes: {},
      id: widget.id,
      mutations_from_database: nil,
      mutations_before_last_save: nil,
    }

    Parse::Core::Actions.rollback_object_state(state)

    refute widget.instance_variable_defined?(:@attributes),
           "@attributes must stay undefined so ActiveModel::Dirty keeps using " \
           "ForcedMutationTracker rather than building an AttributeMutationTracker " \
           "over Parse's schema hash"
  end

  def test_rollback_removes_a_property_ivar_that_was_originally_undefined
    widget = build_widget
    refute widget.instance_variable_defined?(:@note)
    state = Parse::Core::Actions.snapshot_object_state(widget)

    widget.note = "added"
    Parse::Core::Actions.rollback_object_state(state)

    refute widget.instance_variable_defined?(:@note)
  end

  def test_public_transaction_captures_state_before_mutate_then_add
    widget = build_widget

    with_failed_batch do
      assert_raises(Parse::Error) do
        Parse::Object.transaction do |batch|
          widget.title = "modified"
          batch.add(widget)
        end
      end
    end

    assert_equal "original", widget.title
    refute widget.changed?
    refute widget.instance_variable_defined?(:@attributes)
  end

  def test_public_transaction_restores_nested_and_undefined_values
    widget = build_widget

    with_failed_batch do
      assert_raises(Parse::Error) do
        Parse::Object.transaction do |batch|
          metadata = widget.metadata
          widget.metadata_will_change!
          metadata[:nested][:count] = 2
          widget.note = "added"
          batch.add(widget)
        end
      end
    end

    assert_equal 1, widget.metadata[:nested][:count]
    refute widget.instance_variable_defined?(:@note)
    refute widget.changed?
  end

  def test_public_transaction_preserves_preexisting_dirty_state
    widget = build_widget
    widget.title = "pending before transaction"
    changes_before = widget.changes

    with_failed_batch do
      assert_raises(Parse::Error) do
        Parse::Object.transaction do |batch|
          widget.quantity = 2
          batch.add(widget)
        end
      end
    end

    assert_equal "pending before transaction", widget.title
    assert_equal 1, widget.quantity
    assert_equal changes_before, widget.changes
  end

  def test_failed_create_keeps_values_but_not_a_server_id
    widget = nil

    with_failed_batch do
      assert_raises(Parse::Error) do
        Parse::Object.transaction do |batch|
          widget = RollbackWidget.new(title: "new widget", quantity: 3)
          batch.add(widget)
        end
      end
    end

    assert_equal "new widget", widget.title
    assert_equal 3, widget.quantity
    assert_nil widget.id
    assert widget.changed?
  end

  def test_transaction_context_is_restored_after_failure
    with_failed_batch do
      assert_raises(Parse::Error) do
        Parse::Object.transaction { [] }
      end
    end

    assert_nil Fiber[Parse::Core::Actions::TRANSACTION_CONTEXT_KEY]
  end

  # Pins the premise the bug rested on, so a future change to `#attributes`
  # that made it return values would surface here rather than silently.
  def test_attributes_returns_the_schema_map
    widget = build_widget
    assert_equal :string, widget.attributes[:title],
                 "Parse::Object#attributes is a schema map, not a value store"
  end
end
