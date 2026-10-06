# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "set"

# Object lifecycle contracts: mass assignment never retargets an object's id
# or sets protected keys, unsaved objects compare by identity, reading
# timestamps never dirties a record, destroy keeps the id and marks the
# object destroyed, cache keys, ACL revocation after a save, and the batch
# and save_all paths.
class ObjectLifecycleTest < Minitest::Test
  class Track < Parse::Object
    parse_class "LifecycleTrack"
    property :title, :string
    belongs_to :album, as: :lifecycle_album
    has_many :fans, through: :relation, as: :user
  end

  class LifecycleAlbum < Parse::Object
    parse_class "LifecycleAlbum"
    property :name, :string
  end

  class OwnedTrack < Parse::Object
    parse_class "LifecycleOwnedTrack"
    property :title, :string
    belongs_to :owner, as: :user
    acl_policy :owner_else_private, owner: :owner
  end

  module Nested
    class Clip < Parse::Object
      parse_class "LifecycleClip"
      property :name, :string
    end
  end

  FakeResponse = Struct.new(:result, :code, :error) do
    def success?; code.nil?; end
    def error?; !success?; end
  end

  TS = "2024-01-01T00:00:00.000Z"
  TS2 = "2024-01-02T00:00:00.000Z"

  def setup
    unless Parse::Client.client? && Parse::Client.client.master_key
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "a", api_key: "k", master_key: "m")
    end
    Parse::Object.suppress_permissive_acl_warning = true
  end

  def saved_track(extra = {})
    Track.build({ "objectId" => "T1", "createdAt" => TS, "updatedAt" => TS,
                  "title" => "t", "ACL" => { "u1" => { "read" => true, "write" => true } } }.merge(extra))
  end

  def client
    Parse::Client.client
  end

  # --- mass assignment of id -------------------------------------------------

  def test_attributes_assignment_cannot_change_existing_id
    t = saved_track
    t.attributes = { "id" => "victim", "objectId" => "victim2", :id => "victim3", "title" => "x" }
    assert_equal "T1", t.id
    assert_equal "x", t.title
  end

  def test_apply_attributes_cannot_change_existing_id
    t = saved_track
    t.apply_attributes!({ "id" => "victim", "objectId" => "v2" }, dirty_track: true)
    assert_equal "T1", t.id
    t.apply_attributes!({ "id" => "victim", "objectId" => "v2" })
    assert_equal "T1", t.id, "hydration must not retarget an object that already has an id"
  end

  def test_attributes_assignment_cannot_give_new_object_an_id
    t = Track.new(title: "a")
    t.attributes = { "id" => "victim", "objectId" => "victim" }
    assert_nil t.id
  end

  def test_trusted_and_constructor_paths_still_set_id
    assert_equal "abc", Track.new("objectId" => "abc").id
    assert_equal "abc", Track.new(id: "abc").id
    assert_equal "abc", Track.new("id" => "abc").id
    assert_equal "abc", Track.build({ "objectId" => "abc" }).id
    t = Track.new
    t.id = "explicit"
    assert_equal "explicit", t.id
  end

  def test_attributes_assignment_accepts_hash_like_params
    params = Struct.new(:title, :id).new("from struct", "victim")
    t = saved_track
    t.attributes = params
    assert_equal "from struct", t.title
    assert_equal "T1", t.id
  end

  # --- assign_attributes -----------------------------------------------------

  def test_assign_attributes_filters_protected_keys
    t = saved_track
    t.assign_attributes("id" => "victim", "created_at" => Time.utc(2000), "title" => "ok")
    assert_equal "T1", t.id
    assert_equal Time.utc(2024).to_i, t.created_at.to_time.to_i
    assert_equal "ok", t.title
  end

  def test_assign_attributes_filters_session_token_on_user
    u = Parse::User.new
    u.assign_attributes("session_token" => "forged", "username" => "bob", "id" => "victim")
    assert_nil u.session_token
    assert_nil u.id
    assert_equal "bob", u.username
  end

  def test_assign_attributes_remote_object_id_does_not_autofetch
    t = Track.new
    # Before the fix this went through Pointer#method_missing and tried to
    # fetch the record over the network.
    client.stub(:fetch_object, ->(*_a, **_k) { flunk "autofetch triggered" }) do
      t.assign_attributes("objectId" => "victim")
    end
    assert_nil t.id
  end

  def test_unknown_remote_alias_setter_raises_without_fetch
    t = Track.new
    client.stub(:fetch_object, ->(*_a, **_k) { flunk "autofetch triggered" }) do
      assert_raises(NoMethodError) { t.objectId = "x" }
    end
  end

  # --- equality --------------------------------------------------------------

  def test_unsaved_objects_compare_by_identity
    a = Track.new(title: "a")
    b = Track.new(title: "a")
    refute_equal a, b
    refute a.eql?(b)
    assert_equal a, a
    assert_equal 2, [a, b].uniq.size
    assert_equal 2, Set[a, b].size
    assert_equal 2, { a => 1, b => 2 }.size
  end

  def test_saved_objects_compare_by_class_and_id
    a = Track.build({ "objectId" => "same", "title" => "a" })
    b = Track.build({ "objectId" => "same", "title" => "b" })
    assert_equal a, b
    assert_equal a.hash, b.hash
    assert_equal 1, [a, b].uniq.size
    assert_equal a, Track.pointer("same")
    refute_equal a, LifecycleAlbum.build({ "objectId" => "same" })
    refute_equal a, Track.new
  end

  # --- timestamps do not dirty -----------------------------------------------

  def test_reading_timestamps_after_create_keeps_record_clean
    t = Track.new(title: "new")
    created = FakeResponse.new({ "objectId" => "NEW1", "createdAt" => TS })
    client.stub(:create_object, ->(*_a, **_k) { created }) do
      assert t.save
    end
    t.updated_at
    t.created_at
    refute t.changed?, "reading timestamps must not dirty the record: #{t.changed.inspect}"
    assert t.persisted?
    assert_equal "NEW1", t.to_param
    assert_kind_of Parse::Date, t.instance_variable_get(:@updated_at)
  end

  # --- destroy ---------------------------------------------------------------

  def test_destroy_keeps_id_and_marks_destroyed
    t = saved_track
    client.stub(:delete_object, ->(*_a, **_k) { FakeResponse.new({}) }) do
      assert t.destroy
    end
    assert_equal "T1", t.id
    assert t.destroyed?
    refute t.persisted?
    assert_equal ["T1"], t.to_key
  end

  def test_save_on_destroyed_object_is_refused
    t = saved_track
    client.stub(:delete_object, ->(*_a, **_k) { FakeResponse.new({}) }) do
      t.destroy
    end
    t.title = "again"
    calls = 0
    counter = ->(*_a, **_k) { calls += 1; FakeResponse.new({ "updatedAt" => TS2 }) }
    client.stub(:update_object, counter) do
      client.stub(:create_object, counter) do
        refute t.save
        assert_raises(Parse::RecordNotSaved) { t.save! }
      end
    end
    assert_equal 0, calls, "a destroyed record must not be recreated or updated"
  end

  def test_failed_destroy_does_not_mark_destroyed
    t = saved_track
    client.stub(:delete_object, ->(*_a, **_k) { FakeResponse.new(nil, 101, "not found") }) do
      refute t.destroy
    end
    refute t.destroyed?
    assert t.persisted?
  end

  # --- cache keys ------------------------------------------------------------

  def test_cache_key_and_version
    t = saved_track
    prefix = Track.model_name.cache_key
    assert_equal "#{prefix}/T1", t.cache_key
    assert_equal "20240101000000000000", t.cache_version
    assert_equal "#{prefix}/T1-20240101000000000000", t.cache_key_with_version
    assert_equal "#{prefix}/new", Track.new.cache_key
    assert_nil Track.new.cache_version
    assert_equal "#{prefix}/new", Track.new.cache_key_with_version
  end

  def test_cache_key_differs_across_classes_with_same_id
    a = Track.build({ "objectId" => "same" })
    b = LifecycleAlbum.build({ "objectId" => "same" })
    refute_equal a.cache_key, b.cache_key
    assert_includes Nested::Clip.build({ "objectId" => "c1" }).cache_key, "/c1"
  end

  def test_cache_version_does_not_autofetch_pointer_state
    t = Track.new("ptr1")
    client.stub(:fetch_object, ->(*_a, **_k) { flunk "autofetch triggered" }) do
      assert_nil t.cache_version
      assert_equal "#{Track.model_name.cache_key}/ptr1", t.cache_key
    end
  end

  # --- attributes / attribute_values ----------------------------------------

  def test_attributes_stays_type_map_and_attribute_values_returns_values
    t = saved_track
    assert_equal :string, t.attributes[:title]
    values = t.attribute_values
    assert_equal "t", values["title"]
    assert_equal "T1", values["id"]
    assert_kind_of Parse::Date, values["created_at"]
    refute values.key?("objectId"), "remote aliases are not duplicated"
    refute t.changed?
  end

  def test_attribute_values_does_not_autofetch
    t = Track.new("ptr1")
    client.stub(:fetch_object, ->(*_a, **_k) { flunk "autofetch triggered" }) do
      assert_nil t.attribute_values["title"]
    end
  end

  # --- ACL revocation after save (A1) and rollback ---------------------------

  def test_acl_revocation_after_save_is_sent
    t = saved_track
    sent = []
    updater = ->(_cls, _id, body, **_k) { sent << JSON.parse(body.to_json); FakeResponse.new({ "updatedAt" => TS2 }) }
    client.stub(:update_object, updater) do
      t.acl.everyone(true, false)
      assert t.save
      t.acl.everyone(false, false)
      assert t.changed?, "revoking the grant must register as a change"
      assert t.save
    end
    assert_equal 2, sent.size
    assert sent[0]["ACL"].key?("*")
    refute sent[1]["ACL"].key?("*"), "the revocation must be sent to the server"
  end

  def test_rollback_restores_in_place_acl_edit
    t = saved_track
    t.acl.apply("attacker", true, true)
    t.rollback!
    assert_equal({ "u1" => { "read" => true, "write" => true } }, t.acl.as_json)
    refute t.changed?
  end

  # --- ACL stamping on hydration (A8) ----------------------------------------

  def test_built_row_without_acl_is_not_stamped_with_local_default
    t = Track.build({ "objectId" => "T9", "createdAt" => TS, "updatedAt" => TS, "title" => "x" })
    assert_nil t.acl
    refute t.changed?
  end

  def test_new_object_still_gets_default_acl
    refute_nil Track.new(title: "x").acl
  end

  # --- batch change_requests (A2, B6, B14) -----------------------------------

  def test_batch_create_resolves_acl_policy_owner
    owner = Parse::User.build({ "objectId" => "owner1" })
    t = OwnedTrack.new(title: "x", owner: owner)
    req = t.change_requests.first
    body = JSON.parse(req.body.to_json)
    assert_equal :post, req.method.to_s.downcase.to_sym
    assert_equal({ "owner1" => { "read" => true, "write" => true } }, body["ACL"])
  end

  def test_batch_create_includes_relation_additions
    fan = Parse::User.build({ "objectId" => "fan1" })
    t = Track.new(title: "x")
    # Adding to a relation proxy loads it once for dirty tracking; answer
    # that lookup with an empty result instead of a network call.
    client.stub(:find_objects, ->(*_a, **_k) { Parse::Response.new({ "results" => [] }) }) do
      t.fans.add(fan)
    end
    reqs = t.change_requests
    assert_equal 1, reqs.size
    body = JSON.parse(reqs.first.body.to_json)
    assert_equal "AddRelation", body["fans"]["__op"]
    assert_equal "fan1", body["fans"]["objects"].first["objectId"]
  end

  def test_batch_refuses_unsaved_pointer
    t = Track.new(title: "x", album: LifecycleAlbum.new(name: "unsaved"))
    assert_raises(Parse::RecordNotSaved) { t.change_requests }
    assert_raises(Parse::RecordNotSaved) { [t].save }
  end

  def test_single_save_refuses_unsaved_pointer
    t = Track.new(title: "x", album: LifecycleAlbum.new(name: "unsaved"))
    client.stub(:create_object, ->(*_a, **_k) { flunk "dangling pointer sent" }) do
      refute t.save
      assert_includes t.errors[:album].join, "unsaved"
      assert_raises(Parse::RecordNotSaved) { t.save! }
    end
  end

  def test_saved_pointer_is_allowed
    album = LifecycleAlbum.build({ "objectId" => "A1" })
    t = Track.new(title: "x", album: album)
    body = JSON.parse(t.change_requests.first.body.to_json)
    assert_equal "A1", body["album"]["objectId"]
  end

  # --- transaction retry on 251 (B2) -----------------------------------------

  def test_transaction_retries_on_conflict_code
    t = saved_track
    attempts = 0
    batch = lambda do |op|
      attempts += 1
      if attempts == 1
        [Parse::Response.new({ "code" => 251, "error" => "write conflict" })]
      else
        op.requests.map { Parse::Response.new({ "updatedAt" => TS2 }) }
      end
    end
    client.stub(:batch_request, batch) do
      Parse::Object.transaction do |b|
        t.title = "tx"
        b.add(t)
      end
    end
    assert_equal 2, attempts
  end

  def test_transaction_does_not_retry_other_errors
    t = saved_track
    attempts = 0
    batch = ->(_op) { attempts += 1; [Parse::Response.new({ "code" => 142, "error" => "nope" })] }
    client.stub(:batch_request, batch) do
      err = assert_raises(Parse::Error) do
        Parse::Object.transaction do |b|
          t.title = "tx"
          b.add(t)
        end
      end
      assert_includes err.message, "142"
    end
    assert_equal 1, attempts
  end

  # --- save_all (B8, B9, B10) ------------------------------------------------

  class FakeQuery
    def initialize(pages, log, constraints)
      @pages = pages
      @log = log
      @constraints = constraints
    end

    def results
      @log << @constraints
      @pages.shift || []
    end
  end

  def with_fake_query(klass, pages, log)
    klass.stub(:query, ->(c) { FakeQuery.new(pages, log, c) }) { yield }
  end

  def page(count, ts, prefix)
    (1..count).map do |i|
      Track.build({ "objectId" => "#{prefix}#{i}", "createdAt" => TS, "updatedAt" => ts, "title" => "t" })
    end
  end

  def test_save_all_does_not_mutate_constraints
    constraints = { title: "t" }
    with_fake_query(Track, [[]], []) do
      Track.save_all(constraints) { |_r| }
    end
    assert_equal({ title: "t" }, constraints)
  end

  def test_save_all_reports_failure_on_last_page
    failing = ->(op) { op.requests.map { Parse::Response.new({ "code" => 142, "error" => "nope" }) } }
    client.stub(:batch_request, failing) do
      with_fake_query(Track, [page(3, TS, "a")], []) do
        refute Track.save_all { |r| r.title = "changed" }
      end
    end
  end

  def test_save_all_visits_unmodified_records_without_stopping
    log = []
    full = page(250, TS, "a")
    rest = page(10, TS2, "b")
    visited = []
    with_fake_query(Track, [full, rest], log) do
      assert Track.save_all { |r| visited << r.id }
    end
    assert_equal 260, visited.size
    second = log[1]
    gte = second.keys.find { |k| k.is_a?(Parse::Operation) && k.operator == :gte }
    nin = second.keys.find { |k| k.is_a?(Parse::Operation) && k.operator == :nin }
    refute_nil gte
    refute_nil nin
    assert_equal 250, second[nin].size
  end
end
