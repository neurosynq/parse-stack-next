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

    def initialize(update_result: nil, fetch_result: nil, update_results: nil)
      @calls = []
      @update_result = update_result
      @fetch_result = fetch_result
      @update_results = update_results
    end

    def update_object(klass, id, body, **_opts)
      @calls << [:update, klass, id, body.as_json]
      if @update_results
        next_result = @update_results.shift
        return next_result if next_result.is_a?(Parse::Response)
        return Parse::Response.new(next_result || { "updatedAt" => "2026-01-02T00:00:00.000Z" })
      end
      Parse::Response.new(@update_result || { "updatedAt" => "2026-01-02T00:00:00.000Z" })
    end

    def fetch_object(klass, id, **_opts)
      @calls << [:fetch, klass, id]
      Parse::Response.new(@fetch_result || { "objectId" => id, "name" => "server name",
                                             "createdAt" => "2026-01-01T00:00:00.000Z",
                                             "updatedAt" => "2026-01-03T00:00:00.000Z" })
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

  # Unsaved local edits survive an atomic add: the server array is not
  # adopted while the field is dirty, and the pending edit is still sent.
  def test_atomic_add_keeps_unsaved_local_edits
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1/parse", application_id: "a", api_key: "k")
    end
    obj = ServerArrayDoc.new(objectId: "x1", tags: ["a"])
    obj.send(:clear_changes!) if obj.respond_to?(:clear_changes!, true)
    obj.tags.add("pending")
    fake = Struct.new(:result) do
      def error? = false
      def success? = true
    end
    reply = fake.new({ "tags" => %w[a atomic] })
    obj.client.stub(:update_object, ->(*_a, **_k) { reply }) do
      assert obj.tags.add!("atomic")
    end
    assert_includes obj.tags.to_a, "pending"
    assert_includes obj.tags.to_a, "atomic"
    assert obj.tags_changed?, "the pending edit is still sent on save"
  end

  # 5.8.1: pointer collections ----------------------------------------

  # A pointer array adopts the server's array after an atomic op, keeping
  # the local object for an id it already holds.
  def test_pointer_collection_add_adopts_the_server_array
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1")])
    local = a.items.first
    attach_client(a, update_result: { "items" => [item_ptr("i1"), item_ptr("i9"), item_ptr("i3")],
                                      "updatedAt" => "2026-01-02T00:00:00.000Z" })
    assert a.items.add!(item("i3"))
    assert_equal %w[i1 i9 i3], a.items.map(&:id)
    assert a.items.all? { |o| o.is_a?(AssocAuditItem) }
    assert_same local, a.items.first
    refute_includes a.changed, "items"
  end

  def test_pointer_collection_remove_adopts_the_server_array
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1"), item_ptr("i2")])
    attach_client(a, update_result: { "items" => [item_ptr("i5")] })
    assert a.items.remove!(item("i1"))
    assert_equal %w[i5], a.items.map(&:id)
    refute_includes a.changed, "items"
  end

  # An entry that cannot be read as a pointer leaves the server array
  # unused, and the operation is applied locally.
  def test_pointer_collection_unreadable_server_array_applies_locally
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1")])
    attach_client(a, update_result: { "items" => [item_ptr("i1"), 42] })
    assert a.items.add!(item("i3"))
    assert_equal %w[i1 i3], a.items.map(&:id)
  end

  # 5.8.1: relation save and clear_changes! ----------------------------

  def test_relation_proxy_save_sends_only_staged_ops
    a = saved(AssocAuditAuthor, "a1")
    stub_fetch(a, :likes)
    fake = attach_client(a)
    a.likes.add(item("i1"))
    a.likes.remove(item("i2"))
    a.name = "unsaved name"
    assert_equal true, a.likes.save
    bodies = fake.calls.map { |c| c[3] }
    assert_equal({ "likes" => { "__op" => "RemoveRelation", "objects" => [item_ptr("i2")] } }, bodies[0])
    assert_equal({ "likes" => { "__op" => "AddRelation", "objects" => [item_ptr("i1")] } }, bodies[1])
    assert_empty a.likes.additions
    assert_empty a.likes.removals
    refute_includes a.changed, "likes"
    assert_includes a.changed, "name", "the rest of the owner is not saved"

    # A later owner save does not send the relation ops again.
    a.save
    refute fake.calls.last[3].key?("likes")
  end

  def test_relation_proxy_save_uses_the_remote_column
    a = saved(AssocAuditAuthor, "a1")
    stub_fetch(a, :fans)
    fake = attach_client(a)
    a.fans.add(item("i1"))
    assert a.fans.save
    assert_equal ["awesomeFans"], fake.calls.last[3].keys
  end

  def test_relation_atomic_ops_use_the_remote_column
    a = saved(AssocAuditAuthor, "a1")
    fake = attach_client(a)
    assert a.fans.add!(item("i1"))
    assert_equal ["awesomeFans"], fake.calls.last[3].keys
    assert a.fans.remove!(item("i1"))
    assert_equal ["awesomeFans"], fake.calls.last[3].keys
  end

  def test_relation_proxy_save_keeps_ops_on_failure
    a = saved(AssocAuditAuthor, "a1")
    stub_fetch(a, :likes)
    a.define_singleton_method(:operate_field!) { |*| false }
    a.likes.add(item("i1"))
    assert_equal false, a.likes.save
    assert_equal %w[i1], a.likes.additions.map(&:id)
    assert_includes a.changed, "likes"
  end

  def test_relation_proxy_save_on_unsaved_owner_returns_false
    a = AssocAuditAuthor.new
    a.likes.add(item("i1"))
    assert_equal false, a.likes.save
    assert_equal %w[i1], a.likes.additions.map(&:id)
  end

  def test_relation_proxy_save_with_nothing_staged
    a = saved(AssocAuditAuthor, "a1")
    fake = attach_client(a)
    assert_equal true, a.likes.save
    assert_empty fake.calls
  end

  def test_owner_clear_changes_drops_staged_relation_ops
    a = saved(AssocAuditAuthor, "a1")
    calls = stub_fetch(a, :likes, [item("i7")])
    fake = attach_client(a)
    a.likes.add(item("i1"))
    a.likes.remove(item("i2"))
    a.clear_changes!
    assert_empty a.likes.additions
    assert_empty a.likes.removals
    refute a.likes.changed?
    refute_includes a.changed, "likes"

    # The staged items were in the local list, so it reloads from the server.
    assert_equal %w[i7], a.likes.map(&:id)
    assert_equal [:likes], calls

    # A later change to the relation sends only that change.
    a.likes.add(item("i3"))
    a.save
    assert_equal({ "likes" => { "__op" => "AddRelation", "objects" => [item_ptr("i3")] } }, fake.calls.last[3])
  end

  def test_owner_clear_changes_clears_array_proxy_dirty_state
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1")])
    a.items.add(item("i2"))
    assert a.items.changed?
    a.clear_changes!
    refute a.items.changed?
    refute_includes a.changed, "items"
    assert_equal %w[i1 i2], a.items.map(&:id)
  end

  # 5.8.1 review: a fetch keeps staged relation ops ----------------------

  def staged_likes_author
    a = saved(AssocAuditAuthor, "a1", "name" => "local")
    stub_fetch(a, :likes)
    fake = attach_client(a)
    a.likes.add(item("i1"))
    [a, fake]
  end

  def assert_likes_still_staged(a, fake)
    assert_equal %w[i1], a.likes.additions.map(&:id)
    assert_includes a.changed, "likes"
    a.save
    assert_equal({ "likes" => { "__op" => "AddRelation", "objects" => [item_ptr("i1")] } }, fake.calls.last[3])
  end

  def test_fetch_preserving_changes_keeps_staged_relation_ops
    a, fake = staged_likes_author
    capture_io { a.fetch!(preserve_changes: true) }
    assert_likes_still_staged(a, fake)
  end

  def test_full_fetch_keeps_staged_relation_ops
    a, fake = staged_likes_author
    capture_io { a.fetch! }
    assert_likes_still_staged(a, fake)
  end

  def test_partial_fetch_keeps_staged_relation_ops
    a, fake = staged_likes_author
    capture_io { a.fetch!(keys: [:name]) }
    assert_likes_still_staged(a, fake)
  end

  def test_autofetch_keeps_staged_relation_ops
    a, fake = staged_likes_author
    a.fetched_keys = [:likes]
    assert a.has_selective_keys?
    capture_io { a.autofetch!(:name) }
    assert_includes fake.calls.map(&:first), :fetch
    assert_likes_still_staged(a, fake)
  end

  # A real fetch response carries the relation's descriptor. Applying it
  # must neither replace the proxy holding staged ops nor leave the owner
  # clean.

  def relation_descriptor_result(extra = {})
    { "objectId" => "a1", "name" => "server name",
      "likes" => { "__type" => "Relation", "className" => "AssocAuditItem" },
      "awesomeFans" => { "__type" => "Relation", "className" => "AssocAuditItem" },
      "createdAt" => "2026-01-01T00:00:00.000Z",
      "updatedAt" => "2026-01-03T00:00:00.000Z" }.merge(extra)
  end

  def staged_likes_author_with_descriptor
    a = saved(AssocAuditAuthor, "a1", "name" => "local")
    stub_fetch(a, :likes)
    fake = attach_client(a, fetch_result: relation_descriptor_result)
    a.likes.add(item("i1"))
    [a, fake]
  end

  def test_descriptor_fetch_preserving_changes_keeps_staged_relation_ops
    a, fake = staged_likes_author_with_descriptor
    proxy = a.likes
    capture_io { a.fetch!(preserve_changes: true) }
    assert_same proxy, a.likes
    assert_likes_still_staged(a, fake)
  end

  def test_descriptor_full_fetch_keeps_staged_relation_ops
    a, fake = staged_likes_author_with_descriptor
    capture_io { a.fetch! }
    assert_likes_still_staged(a, fake)
  end

  def test_descriptor_partial_fetch_including_relation_keeps_staged_ops
    a, fake = staged_likes_author_with_descriptor
    capture_io { a.fetch!(keys: [:name, :likes]) }
    assert_likes_still_staged(a, fake)
  end

  def test_descriptor_partial_fetch_excluding_relation_keeps_staged_ops
    a, fake = staged_likes_author_with_descriptor
    capture_io { a.fetch!(keys: [:name]) }
    assert_likes_still_staged(a, fake)
  end

  def test_descriptor_autofetch_keeps_staged_relation_ops
    a, fake = staged_likes_author_with_descriptor
    a.fetched_keys = [:likes]
    capture_io { a.autofetch!(:name) }
    assert_includes fake.calls.map(&:first), :fetch
    assert_likes_still_staged(a, fake)
  end

  def test_descriptor_fetch_keeps_staged_removal_on_mapped_column
    a = saved(AssocAuditAuthor, "a1", "name" => "local")
    stub_fetch(a, :fans, [item("i1")])
    fake = attach_client(a, fetch_result: relation_descriptor_result)
    a.fans.remove(item("i1"))
    capture_io { a.fetch!(preserve_changes: true) }
    assert_equal %w[i1], a.fans.removals.map(&:id)
    assert_includes a.changed, "fans"
    a.save
    assert_equal({ "awesomeFans" => { "__op" => "RemoveRelation", "objects" => [item_ptr("i1")] } }, fake.calls.last[3])
  end

  def test_descriptor_fetch_without_staged_ops_replaces_the_proxy
    a = saved(AssocAuditAuthor, "a1", "name" => "local")
    attach_client(a, fetch_result: relation_descriptor_result)
    before = a.likes
    capture_io { a.fetch! }
    refute_same before, a.likes
    refute_includes a.changed, "likes"
  end

  def test_reload_discards_staged_relation_ops
    a, fake = staged_likes_author
    capture_io { a.reload! }
    assert_empty a.likes.additions
    refute_includes a.changed, "likes"
    a.save
    refute(fake.calls.any? { |c| c.first == :update && c[3].key?("likes") })
  end

  # 5.8.1 review: pointer array adoption checks each entry ----------------

  def test_pointer_collection_foreign_class_entry_applies_locally
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1")])
    other = { "__type" => "Pointer", "className" => "AssocAuditOther", "objectId" => "z1" }
    attach_client(a, update_result: { "items" => [item_ptr("i1"), other] })
    assert a.items.add!(item("i3"))
    assert_equal %w[i1 i3], a.items.map(&:id)
    assert a.items.all? { |o| o.is_a?(AssocAuditItem) }
  end

  def test_pointer_collection_string_entry_applies_locally
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1")])
    attach_client(a, update_result: { "items" => [item_ptr("i1"), "AssocAuditItem$i9"] })
    assert a.items.add!(item("i3"))
    assert_equal %w[i1 i3], a.items.map(&:id)
  end

  def test_pointer_collection_add_unique_adopts_the_server_array
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1")])
    attach_client(a, update_result: { "items" => [item_ptr("i8"), item_ptr("i1"), item_ptr("i2")] })
    assert a.items.add_unique!(item("i1"), item("i2"))
    assert_equal %w[i8 i1 i2], a.items.map(&:id)
    refute_includes a.changed, "items"
  end

  def test_pointer_collection_reply_without_field_applies_locally
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1")])
    attach_client(a, update_result: { "updatedAt" => "2026-01-02T00:00:00.000Z" })
    assert a.items.add!(item("i3"))
    assert_equal %w[i1 i3], a.items.map(&:id)
    refute_includes a.changed, "items"
  end

  def test_pointer_collection_with_pending_edits_applies_locally
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1")])
    attach_client(a, update_result: { "items" => [item_ptr("i1"), item_ptr("i9"), item_ptr("i3")] })
    a.items.add(item("i2"))
    assert a.items.add!(item("i3"))
    assert_equal %w[i1 i2 i3], a.items.map(&:id)
    assert_includes a.changed, "items", "the pending local edit is still sent on save"
  end

  def test_last_operation_reply_is_read_once
    a = saved(AssocAuditAuthor, "a1", "items" => [item_ptr("i1")])
    attach_client(a, update_result: { "items" => [item_ptr("i1"), item_ptr("i3")] })
    assert a.items.add!(item("i3"))
    assert_nil a.send(:_last_operation_value, :items)
  end

  # 5.8.1 review: relation save partial failure ---------------------------

  def test_relation_proxy_save_partial_failure_keeps_unsent_additions
    a = saved(AssocAuditAuthor, "a1")
    stub_fetch(a, :likes)
    failed = Parse::Response.new("code" => 141, "error" => "boom")
    fake = attach_client(a, update_results: [nil, failed])
    a.likes.add(item("i1"))
    a.likes.remove(item("i2"))
    capture_io { assert_equal false, a.likes.save }
    assert_equal 2, fake.calls.size
    assert_empty a.likes.removals, "the removal was applied, so it is no longer staged"
    assert_equal %w[i1], a.likes.additions.map(&:id)
    assert_includes a.changed, "likes"
  end


  # PR review: rollback, transactions, stale lists, new owners, sessions --

  def test_rollback_after_descriptor_fetch_drops_staged_relation_ops
    a, fake = staged_likes_author_with_descriptor
    capture_io { a.fetch! }
    a.rollback!
    assert_empty a.likes.additions
    refute_includes a.changed, "likes"
    a.likes.add(item("i2"))
    a.save
    assert_equal({ "likes" => { "__op" => "AddRelation", "objects" => [item_ptr("i2")] } }, fake.calls.last[3])
  end

  def test_rollback_after_preserving_fetch_drops_staged_relation_ops
    a, _fake = staged_likes_author_with_descriptor
    capture_io { a.fetch!(preserve_changes: true) }
    a.rollback!
    assert_empty a.likes.additions
    assert_equal [{}, {}], a.relation_change_operations
  end

  SuccessResponse = Struct.new(:result) do
    def success?
      true
    end
  end

  def test_successful_transaction_settles_staged_relation_ops
    a, fake = staged_likes_author
    fake.define_singleton_method(:url_prefix) { URI("http://localhost:1/parse/") }
    original_new = Parse::BatchOperation.method(:new)
    Parse::BatchOperation.define_singleton_method(:new) do |*args, **kwargs|
      batch = original_new.call(*args, **kwargs)
      batch.define_singleton_method(:submit) do
        requests.map { SuccessResponse.new({ "updatedAt" => "2026-01-05T00:00:00.000Z" }) }
      end
      batch
    end
    begin
      Parse::Object.transaction { |batch| batch.add(a) }
    ensure
      Parse::BatchOperation.define_singleton_method(:new, &original_new)
    end
    assert_empty a.likes.additions
    refute_includes a.changed, "likes"
    calls_before = fake.calls.size
    a.likes.add(item("i2"))
    a.save
    sent = fake.calls[calls_before..].map { |c| c[3] }
    assert_equal [{ "likes" => { "__op" => "AddRelation", "objects" => [item_ptr("i2")] } }], sent
  end

  def test_descriptor_fetch_unloads_a_stale_loaded_list
    a = saved(AssocAuditAuthor, "a1", "name" => "local")
    fetches = stub_fetch(a, :likes, [item("old")])
    attach_client(a, fetch_result: relation_descriptor_result)
    assert_equal %w[old], a.likes.map(&:id)
    a.likes.add(item("i1"))
    fresh = item("fresh")
    a.define_singleton_method(:likes_fetch!) do
      fetches << :likes
      [fresh]
    end
    capture_io { a.fetch! }
    refute a.likes.loaded?
    assert_equal %w[fresh i1], a.likes.map(&:id)
    assert_equal %w[i1], a.likes.additions.map(&:id)
  end

  def test_relation_writes_during_a_create_with_a_client_side_id_stage_locally
    a = AssocAuditAuthor.new
    a.instance_variable_set(:@id, "precomputed")
    a.instance_variable_set(:@_creating_record, true)
    a.define_singleton_method(:autofetch!) { |*| nil }
    refute a.persisted?
    fake = attach_client(a)
    a.likes.add(item("i1"))
    assert_equal false, a.likes.save
    assert a.likes.add!(item("i2"))
    assert a.likes.remove!(item("i3"))
    assert_empty fake.calls
    assert_equal %w[i1 i2], a.likes.additions.map(&:id)
    assert_equal %w[i3], a.likes.removals.map(&:id)
  end

  def test_relation_writes_on_an_id_only_handle_are_sent
    a = AssocAuditAuthor.new(id: "existing")
    assert a.persisted?
    stub_fetch(a, :likes)
    fake = attach_client(a)
    a.likes.add(item("i1"))
    assert a.likes.save
    assert_equal({ "likes" => { "__op" => "AddRelation", "objects" => [item_ptr("i1")] } }, fake.calls.last[3])
  end

  class SessionRecordingClient < FakeClient
    attr_reader :sessions

    def update_object(klass, id, body, **opts)
      (@sessions ||= []) << opts[:session_token]
      super
    end
  end

  def test_relation_proxy_save_sends_with_the_given_session
    a = saved(AssocAuditAuthor, "a1")
    stub_fetch(a, :likes)
    fake = SessionRecordingClient.new
    a.define_singleton_method(:client) { fake }
    a.likes.add(item("i1"))
    a.likes.remove(item("i2"))
    assert a.likes.save(session: "r:alice")
    assert_equal ["r:alice", "r:alice"], fake.sessions
    refute a.instance_variable_defined?(:@_session_token), "the owner's session is restored"
  end

  def test_relation_proxy_save_restores_the_owners_previous_session
    a = saved(AssocAuditAuthor, "a1")
    stub_fetch(a, :likes)
    fake = SessionRecordingClient.new
    a.define_singleton_method(:client) { fake }
    a.instance_variable_set(:@_session_token, "r:owner")
    a.likes.add(item("i1"))
    assert a.likes.save(session: nil)
    assert_equal [nil], fake.sessions
    assert_equal "r:owner", a.instance_variable_get(:@_session_token)
    a.likes.add(item("i2"))
    assert a.likes.save
    assert_equal [nil, "r:owner"], fake.sessions
  end

  def test_relation_proxy_save_rejects_an_invalid_session
    a = saved(AssocAuditAuthor, "a1")
    stub_fetch(a, :likes)
    attach_client(a)
    a.likes.add(item("i1"))
    assert_raises(ArgumentError) { a.likes.save(session: "") }
    assert_equal %w[i1], a.likes.additions.map(&:id)
  end

  class ProxyIvarsModel < Parse::Object
    property :tags, :array
    has_many :likes, as: :assoc_audit_item, through: :relation
  end

  def test_proxy_change_ivars_tracks_later_declarations
    klass = ProxyIvarsModel
    before = klass.proxy_change_ivars
    assert_includes before, :@likes
    assert_includes before, :@tags
    klass.property :later_list, :array
    assert_includes klass.proxy_change_ivars, :@later_list
  end


  private

  def silence_warnings_for
    capture_io { yield }
  end

end

