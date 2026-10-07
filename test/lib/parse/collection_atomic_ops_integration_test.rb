require_relative "../../test_helper_integration"
require "minitest/autorun"

class AtomicOpsItem < Parse::Object
  parse_class "AtomicOpsItem"
  property :name, :string
end

class AtomicOpsOwner < Parse::Object
  parse_class "AtomicOpsOwner"
  property :name, :string
  has_many :items, as: :atomic_ops_item, through: :array
  has_many :liked_items, as: :atomic_ops_item, through: :relation
end

# Atomic array and relation operations against a live Parse Server: a
# pointer array adopts the array the server returned, and relation
# operations write the remote column.
class CollectionAtomicOpsIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def test_pointer_array_add_and_remove_adopt_the_server_array
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      a, b, c = %w[a b c].map { |n| AtomicOpsItem.new(name: n).tap(&:save!) }
      owner = AtomicOpsOwner.new(name: "owner", items: [a])
      owner.save!

      # Another client adds b, so this copy is stale.
      other = AtomicOpsOwner.find(owner.id)
      assert other.items.add!(b)

      assert owner.items.add!(c)
      assert_equal [a.id, b.id, c.id], owner.items.map(&:id)
      refute_includes owner.changed, "items"

      assert owner.items.remove!(a)
      assert_equal [b.id, c.id], owner.items.map(&:id)
      refute_includes owner.changed, "items"

      assert_equal [b.id, c.id], AtomicOpsOwner.find(owner.id).items.map(&:id)
    end
  end

  def test_relation_save_and_atomic_ops_write_the_remote_column
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      a, b = %w[a b].map { |n| AtomicOpsItem.new(name: n).tap(&:save!) }
      owner = AtomicOpsOwner.new(name: "owner")
      owner.save!

      owner.liked_items.add(a)
      assert owner.liked_items.save
      refute_includes owner.changed, "liked_items"
      assert_equal [a.id], AtomicOpsOwner.find(owner.id).liked_items.all.map(&:id)

      assert owner.liked_items.add!(b)
      assert_equal [a.id, b.id].sort, AtomicOpsOwner.find(owner.id).liked_items.all.map(&:id).sort

      assert owner.liked_items.remove!(a)
      assert_equal [b.id], AtomicOpsOwner.find(owner.id).liked_items.all.map(&:id)
    end
  end

  def test_staged_relation_add_survives_a_fetch_with_the_relation_descriptor
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      a, b = %w[a b].map { |n| AtomicOpsItem.new(name: n).tap(&:save!) }
      owner = AtomicOpsOwner.new(name: "owner")
      owner.liked_items.add(a)
      owner.save!
      # The stored row now has a likedItems column, so a fetch response
      # carries its Relation descriptor.
      owner.liked_items.add(b)
      owner.fetch!(preserve_changes: true)
      assert_includes owner.changed, "liked_items"
      owner.save!
      assert_equal [a.id, b.id].sort, AtomicOpsOwner.find(owner.id).liked_items.all.map(&:id).sort
    end
  end

end
