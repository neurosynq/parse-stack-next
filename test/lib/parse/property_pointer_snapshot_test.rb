require_relative "../../test_helper"
require_relative "../../support/snapshot_helper"
require "minitest/autorun"

# Snapshot regression coverage for the `property … as: <class>` /
# `property … :pointer` delegation to belongs_to.
#
# A property that names a pointer target is really a belongs_to association.
# It must compile to the SAME class-level shape (field type :pointer, remote
# field name, references entry, agent metadata) as the equivalent belongs_to
# declaration — and an assigned value must serialize to a Pointer dict, not a
# String (the original bug: the `as:` option was silently dropped, leaving the
# field as :string). These snapshots pin both the declaration shape and the
# wire form; re-run with UPDATE_SNAPSHOTS=1 after an intentional change.

# Pointer fields declared via `property` (the delegating path). The fixtures
# deliberately exercise every option the delegation forwards: `as:`, bare
# `:pointer`, a custom `field:`, `required:`, `_description:`, and `_enum:`.
class SnapPtrViaProperty < Parse::Object
  parse_class "SnapPtrViaProperty"
  property :rejected_by, as: :user
  property :workspace, as: :workspace, _description: "owning workspace",
                       _enum: { "primary" => "the primary workspace" }
  property :owner, :pointer
  property :reviewer, as: :user, field: "reviewedBy", required: true
end

# The same four pointer fields declared the canonical way, for equivalence.
class SnapPtrViaBelongsTo < Parse::Object
  parse_class "SnapPtrViaBelongsTo"
  belongs_to :rejected_by, as: :user
  belongs_to :workspace, as: :workspace, _description: "owning workspace",
                         _enum: { "primary" => "the primary workspace" }
  belongs_to :owner
  belongs_to :reviewer, as: :user, field: "reviewedBy", required: true
end

class PropertyPointerSnapshotTest < Minitest::Test
  GROUP = "property_pointer".freeze
  KEYS = %i[rejected_by workspace owner reviewer].freeze

  # Extract the class-level declaration shape for the pointer fields. This is
  # the contract that `property as:` and `belongs_to` must agree on. It pins
  # every forwarded dimension — type, remote column, target reference, the
  # presence (`required:`) validator, and both kinds of agent metadata — so a
  # regression in any one of them breaks the equivalence assertion.
  def descriptor(klass)
    KEYS.each_with_object({}) do |key, h|
      remote = klass.field_map[key]
      h[key] = {
        "field_type" => klass.fields[key],
        "remote_field" => remote,
        "remote_field_type" => klass.attributes[remote],
        "reference_class" => klass.references[remote],
        "description" => klass.property_descriptions[key],
        "enum" => klass.property_enum_descriptions[key],
        "required" => klass.validators_on(key).any? do |v|
          v.is_a?(ActiveModel::Validations::PresenceValidator)
        end,
      }
    end
  end

  def test_property_as_pointer_declaration_shape
    assert_snapshot(descriptor(SnapPtrViaProperty),
                    name: "declaration_shape", group: GROUP)
  end

  def test_property_as_pointer_matches_belongs_to
    # The whole point of the fix: the two declarations are interchangeable.
    assert_equal descriptor(SnapPtrViaBelongsTo),
                 descriptor(SnapPtrViaProperty),
                 "property … as: <class> must produce the same shape as belongs_to"
  end

  def test_assigned_value_serializes_as_pointer_not_string
    user = Parse::User.new
    user.id = "abc1234567"
    obj = SnapPtrViaProperty.new
    obj.rejected_by = user

    # The original bug stored a String here; assert the Pointer wire form.
    assert_kind_of Parse::Pointer, obj.rejected_by
    # Dirty tracking parity (claimed in the changelog): assigning through the
    # delegated setter marks the attribute changed, just like belongs_to.
    assert obj.rejected_by_changed?, "assignment should mark the pointer attribute dirty"
    assert_snapshot(obj.rejected_by.pointer.as_json,
                    name: "assigned_value_wire", group: GROUP)
  end
end
