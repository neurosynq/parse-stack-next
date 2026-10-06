require_relative "../../test_helper"

# Unit coverage for association and collection proxy fixes: relation
# staging and settling, atomic array operations, item validation, and
# belongs_to assignment. No server is needed: client calls are recorded by a
# fake client attached to each owner.
class AssocAuditItem < Parse::Object
  property :name
end

class AssocAuditOther < Parse::Object
  property :name
end

class AssocAuditAuthor < Parse::Object
  property :name
  has_many :likes, as: :assoc_audit_item, through: :relation
  has_many :fans, as: :assoc_audit_item, through: :relation, field: "awesomeFans"
  has_many :items, as: :assoc_audit_item, through: :array
  has_many :posts, as: :assoc_audit_post
  has_many :tagged, -> { where(title: "x") }, as: :assoc_audit_post, scope_only: true
  has_one :one_tagged, -> { where(title: "x") }, as: :assoc_audit_post, scope_only: true
  has_one :latest_post, -> { order(:created_at.desc) }, as: :assoc_audit_post
  property :tags, :array
end

class AssocAuditPost < Parse::Object
  property :title
  belongs_to :assoc_audit_author
  belongs_to :editor, as: :assoc_audit_author, field: "theEditor"
end

class AssocAuditTest < Minitest::Test
  # Records update/create calls and answers them with a success response.
  class FakeClient
    attr_reader :calls

    def initialize(update_result: nil)
      @calls = []
      @update_result = update_result
    end

    def update_object(klass, id, body, **_opts)
      @calls << [:update, klass, id, body.as_json]
      Parse::Response.new(@update_result || { "updatedAt" => "2026-01-02T00:00:00.000Z" })
    end

    def create_object(klass, body, **_opts)
      @calls << [:create, klass, body.as_json]
      Parse::Response.new("objectId" => "newId#{@calls.size}", "createdAt" => "2026-01-02T00:00:00.000Z")
    end
  end

  def saved(klass, id, extra = {})
    klass.build({ "objectId" => id, "createdAt" => "2026-01-01T00:00:00.000Z",
                  "updatedAt" => "2026-01-01T00:00:00.000Z" }.merge(extra), klass.parse_class)
  end

  def attach_client(obj, **opts)
    fake = FakeClient.new(**opts)
    obj.define_singleton_method(:client) { fake }
    fake
  end

  # Count relation fetches without hitting the server.
  def stub_fetch(owner, key, result = [])
    calls = []
    owner.define_singleton_method(:"#{key}_fetch!") do
      calls << key
      result
    end
    calls
  end

  def item(id)
    saved(AssocAuditItem, id, "name" => id)
  end

  def item_ptr(id)
    { "__type" => "Pointer", "className" => "AssocAuditItem", "objectId" => id }
  end

  # S1 -----------------------------------------------------------------

  def test_relation_with_field_option_queries_remote_column
    a = saved(AssocAuditAuthor, "a1")
    where = a.fans_relation_query.compile[:where]
    assert_includes where, "\"key\":\"awesomeFans\""
    refute_includes where, "\"key\":\"fans\""
  end

  # S2 -----------------------------------------------------------------

  def test_relation_ops_are_cleared_after_save
    a = saved(AssocAuditAuthor, "a1")
    fake = attach_client(a)
    stub_fetch(a, :likes)
    a.likes.remove(item("i1"))
    assert a.save
    assert_equal 1, fake.calls.size
    assert_equal "RemoveRelation", fake.calls.last[3]["likes"]["__op"]
    assert_empty a.likes.additions
    assert_empty a.likes.removals
    assert_equal [{}, {}], a.relation_change_operations

    # A later save of another relation change must not resend the removal.
    a.likes.add(item("i2"))
    assert a.save
    assert_equal 2, fake.calls.size
    body = fake.calls.last[3]
    assert_equal ["likes"], body.keys
    assert_equal "AddRelation", body["likes"]["__op"]
    assert_equal ["i2"], body["likes"]["objects"].map { |o| o["objectId"] }

    # Nothing pending: a third save sends nothing.
    assert a.save
    assert_equal 2, fake.calls.size
  end

  def test_relation_add_deduplicates
    a = saved(AssocAuditAuthor, "a1")
    i1 = item("i1")
    a.likes.add(i1, i1, i1.pointer, "i1")
    assert_equal ["i1"], a.likes.additions.map(&:id)
    add_op = a.relation_change_operations.first["likes"]
    assert_equal 1, add_op["objects"].size
  end

  def test_relation_ops_cleared_by_changes_applied
    a = saved(AssocAuditAuthor, "a1")
    a.likes.add(item("i1"))
    a.fans.remove(item("i2"))
    a.changes_applied!
    assert_empty a.likes.additions
    assert_empty a.fans.removals
  end

  def test_changes_applied_does_not_autofetch_pointer_owner
    a = AssocAuditAuthor.new("a1")
    assert a.pointer?
    a.define_singleton_method(:autofetch!) { |*| raise "autofetch should not run" }
    a.changes_applied!
  end

  # S3 -----------------------------------------------------------------

  def test_relation_rollback_drops_staged_ops
    a = saved(AssocAuditAuthor, "a1")
    stub_fetch(a, :likes)
    a.likes.add(item("i1"))
    a.likes.remove(item("i2"))
    a.likes.rollback!
    assert_empty a.likes.additions
    assert_empty a.likes.removals
    refute a.likes.changed?
    assert_equal [{}, {}], a.relation_change_operations
  end

  def test_owner_rollback_drops_relation_ops
    a = saved(AssocAuditAuthor, "a1")
    stub_fetch(a, :likes)
    a.name = "changed"
    a.likes.add(item("i1"))
    a.rollback!
    assert_nil a.name
    assert_empty a.likes.additions
  end

  # S4 -----------------------------------------------------------------

  def test_relation_add_and_remove_do_not_fetch
    a = saved(AssocAuditAuthor, "a1")
    calls = stub_fetch(a, :likes, [item("i1"), item("i2")])
    a.likes.add(item("i3"))
    a.likes.remove(item("i1"))
    assert_empty calls, "staging an add or remove must not load the relation"
    # Reading the relation loads it once and applies the staged ops.
    assert_equal %w[i2 i3], a.likes.to_a.map(&:id)
    assert_equal 1, calls.size
  end

  def test_relation_on_new_owner_never_queries
    a = AssocAuditAuthor.new
    a.define_singleton_method(:likes_relation_query) { raise "query on unsaved owner" }
    a.likes.add(item("i1"))
    assert_equal ["i1"], a.likes.to_a.map(&:id)
    assert_equal ["i1"], a.likes.all.map(&:id)
    assert_equal [], AssocAuditAuthor.new.likes_fetch!
  end

  def test_relation_remove_on_new_owner_stages_nothing
    a = AssocAuditAuthor.new
    a.likes.add(item("i1"), item("i2"))
    a.likes.remove(item("i2"))
    assert_equal ["i1"], a.likes.additions.map(&:id)
    assert_empty a.likes.removals
  end

  def test_relation_atomic_add_drops_staged_removal
    a = saved(AssocAuditAuthor, "a1")
    fake = attach_client(a)
    a.likes.remove(item("i1"))
    assert_equal true, a.likes.add!(item("i1"))
    assert_equal "AddRelation", fake.calls.last[3]["likes"]["__op"]
    assert_empty a.likes.removals
  end

  # S5 -----------------------------------------------------------------

  def test_clear_marks_array_dirty
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1"), item_ptr("i2")])
    refute_includes a.changed, "items"
    a.items.clear
    assert_includes a.changed, "items"
    assert_equal [], a.attribute_updates[:items].to_a
  end

  def test_clear_on_plain_array_saves_empty
    a = saved(AssocAuditAuthor, "a1", "tags" => %w[x y])
    fake = attach_client(a)
    a.tags.clear
    assert a.save
    assert_equal [], fake.calls.last[3]["tags"]
  end

  def test_reset_does_not_mark_dirty
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1")])
    a.items.reset!
    refute_includes a.changed, "items"
  end

  # S6 -----------------------------------------------------------------

  def test_atomic_add_keeps_local_items_and_stays_clean
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1"), item_ptr("i2")])
    fake = attach_client(a)
    assert_equal true, a.items.add!(item("i3"))
    assert_equal "Add", fake.calls.last[3]["items"]["__op"]
    assert_equal %w[i1 i2 i3], a.items.map(&:id)
    refute_includes a.changed, "items"

    # A normal save of another field must not write the array.
    a.name = "renamed"
    assert a.save
    assert_equal({ "name" => "renamed" }, fake.calls.last[3])
  end

  def test_atomic_add_unique_and_remove_update_local_items
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1"), item_ptr("i2")])
    attach_client(a)
    assert a.items.add_unique!(item("i1"), item("i3"))
    assert_equal %w[i1 i2 i3], a.items.map(&:id)
    assert a.items.remove!(item("i1"))
    assert_equal %w[i2 i3], a.items.map(&:id)
    refute_includes a.changed, "items"
  end

  def test_atomic_ops_on_plain_array_stay_clean
    a = saved(AssocAuditAuthor, "a1", "tags" => %w[x])
    fake = attach_client(a)
    assert a.tags.add!("y")
    assert_equal %w[x y], a.tags.to_a
    refute_includes a.changed, "tags"
    a.name = "n"
    a.save
    refute fake.calls.last[3].key?("tags")
  end

  def test_atomic_add_failure_leaves_items
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1")])
    a.define_singleton_method(:operate_field!) { |*| false }
    assert_equal false, a.items.add!(item("i3"))
    assert_equal %w[i1], a.items.map(&:id)
  end

  def test_atomic_add_on_new_owner_stages_change
    a = AssocAuditAuthor.new
    assert a.items.add!(item("i1"))
    assert_equal %w[i1], a.items.map(&:id)
    assert_includes a.changed, "items"
  end

  # S7 -----------------------------------------------------------------

  def test_array_has_many_rejects_wrong_class_and_nil
    a = saved(AssocAuditAuthor, "a1")
    other = saved(AssocAuditOther, "o1")
    assert_raises(ArgumentError) { a.items.add(other) }
    assert_raises(ArgumentError) { a.items << nil }
    assert_raises(ArgumentError) { a.items.add(Parse::Pointer.new("AssocAuditOther", "o2")) }
    assert_raises(ArgumentError) { a.items = [item("i1"), nil] }
    assert_raises(ArgumentError) { a.items = [other] }
    assert_raises(ArgumentError) { a.likes.add(other) }
    assert_empty a.items.to_a
  end

  def test_array_has_many_accepts_id_strings_as_declared_class
    a = saved(AssocAuditAuthor, "a1")
    a.items << "i9"
    a.items.add(item("i1"))
    assert_equal %w[i9 i1], a.items.map(&:id)
    assert a.items.all? { |o| o.parse_class == "AssocAuditItem" }
    a.items.remove("i9")
    assert_equal %w[i1], a.items.map(&:id)
  end

  def test_array_has_many_still_coerces_server_data
    a = saved(AssocAuditAuthor, "a1")
    silence_warnings_for do
      a.send(:items_set_attribute!, [{ "__type" => "Pointer", "className" => "_Session", "objectId" => "x" }], false)
    end
    assert_equal ["AssocAuditItem"], a.items.map(&:parse_class)
  end

  # S8 -----------------------------------------------------------------

  def test_nested_partial_fetch_on_multi_word_belongs_to
    post = AssocAuditPost.build(
      { "objectId" => "p1", "createdAt" => "2026-01-01T00:00:00.000Z", "title" => "t",
        "assocAuditAuthor" => { "__type" => "Object", "className" => "AssocAuditAuthor",
                                "objectId" => "a1", "name" => "n",
                                "createdAt" => "2026-01-01T00:00:00.000Z" } },
      "AssocAuditPost",
      fetched_keys: [:title, :assocAuditAuthor, :id, :objectId],
      nested_fetched_keys: { assocAuditAuthor: [:name] },
    )
    author = post.assoc_audit_author
    assert author.has_selective_keys?, "nested keys must be applied to the multi-word pointer"
    assert author.field_was_fetched?(:name)
    refute author.field_was_fetched?(:items)
  end

  # S9 / S10 -----------------------------------------------------------

  def test_belongs_to_refuses_wrong_class
    post = AssocAuditPost.new
    assert_raises(ArgumentError) { post.assoc_audit_author = saved(AssocAuditOther, "o1") }
    assert_raises(ArgumentError) { post.editor = Parse::Pointer.new("_User", "u1") }
    assert_raises(ArgumentError) { post.editor = 42 }
    assert_nil post.assoc_audit_author
  end

  def test_belongs_to_accepts_id_string
    post = saved(AssocAuditPost, "p1", "assocAuditAuthor" => { "__type" => "Pointer", "className" => "AssocAuditAuthor", "objectId" => "old" })
    post.assoc_audit_author = "new1"
    assert_equal "new1", post.assoc_audit_author.id
    assert_equal "AssocAuditAuthor", post.assoc_audit_author.parse_class
    assert_includes post.changed, "assoc_audit_author"
    assert_equal "new1", post.attribute_updates.as_json["assocAuditAuthor"]["objectId"]
    post.assoc_audit_author = ""
    assert_nil post.assoc_audit_author
  end

  def test_belongs_to_hash_class_still_coerced
    post = AssocAuditPost.new
    silence_warnings_for do
      post.assoc_audit_author = { "__type" => "Pointer", "className" => "_Session", "objectId" => "s1" }
    end
    assert_equal "AssocAuditAuthor", post.assoc_audit_author.parse_class
  end

  # S11 ----------------------------------------------------------------

  def test_query_has_many_on_new_owner_is_chainable_and_empty
    a = AssocAuditAuthor.new
    q = a.posts
    assert_kind_of Parse::Query, q
    assert_equal [], q.results
    assert_equal 0, q.count
    assert_equal [], a.posts.limit(5).where(title: "x").results
    assert_nil a.posts.first
    where = a.posts.compile[:where]
    refute_includes where, "null", "an unsaved owner must not produce a null objectId constraint"
  end

  def test_scope_only_has_many_on_new_owner_uses_scope
    a = AssocAuditAuthor.new
    q = a.tagged
    assert_kind_of Parse::Query, q
    assert_includes q.compile[:where], "\"title\":\"x\""
  end

  def test_scope_only_has_one_on_new_owner_runs_query
    a = AssocAuditAuthor.new
    ran = false
    original = Parse::Query.instance_method(:first)
    begin
      Parse::Query.send(:define_method, :first) { |*_a, **_o| ran = true; nil }
      a.one_tagged
    ensure
      Parse::Query.send(:define_method, :first, original)
    end
    assert ran
    assert_nil a.latest_post
  end

  # S12 ----------------------------------------------------------------

  def test_collection_proxy_replace
    a = saved(AssocAuditAuthor, "a1", "tags" => %w[x])
    a.tags.replace(%w[y z])
    assert_equal %w[y z], a.tags.to_a
    assert_includes a.changed, "tags"
    a.items.replace([item("i1")])
    assert_equal %w[i1], a.items.map(&:id)
    assert_raises(ArgumentError) { a.items.replace([saved(AssocAuditOther, "o1")]) }
  end

  def test_relation_replace_stages_diff
    a = saved(AssocAuditAuthor, "a1")
    stub_fetch(a, :likes, [item("i1"), item("i2")])
    a.likes.replace([item("i2"), item("i3")])
    assert_equal %w[i3], a.likes.additions.map(&:id)
    assert_equal %w[i1], a.likes.removals.map(&:id)
  end

  def test_pointer_setter_raises
    ptr = AssocAuditItem.pointer("i1")
    ptr.define_singleton_method(:fetch) { |*| raise "must not fetch" }
    err = assert_raises(NoMethodError) { ptr.name = "x" }
    assert_match(/fetch the object first/, err.message)
    refute ptr.respond_to?(:name=)
  end

  class ServerArrayDoc < Parse::Object
    parse_class "AssocAuditServerArray"
    property :tags, :array
  end

  # After an atomic add, a plain array adopts the array the server returned,
  # so a local copy that was already stale is corrected.
  def test_atomic_add_adopts_the_server_array
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1/parse", application_id: "a", api_key: "k")
    end
    obj = ServerArrayDoc.new(objectId: "x1", tags: ["a"])
    obj.send(:clear_changes!) if obj.respond_to?(:clear_changes!, true)
    fake = Struct.new(:result) do
      def error? = false
      def success? = true
    end
    reply = fake.new({ "tags" => %w[a b server-only], "updatedAt" => "2026-01-01T00:00:00.000Z" })
    obj.client.stub(:update_object, ->(*_a, **_k) { reply }) do
      assert obj.tags.add!("b")
    end
    assert_equal %w[a b server-only], obj.tags.to_a
    refute obj.tags_changed?, "adopting the server value is not a local change"
  end

  private

  def silence_warnings_for
    capture_io { yield }
  end

end

