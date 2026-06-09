# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/autorun"

# Unit-level regression suite that LOCKS IN the webhook full-object contract:
#
#   "An afterSave / beforeSave webhook handler receives the FULL Parse object
#    exactly as Parse Server sent it (timestamps, ACL, internal fields) and can
#    correctly distinguish NEW vs CHANGED objects and detect field changes."
#
# These tests construct Parse::Webhooks::Payload.new(hash) directly (the same
# pattern as test/lib/parse/webhook_callbacks_test.rb) with FULL afterSave
# payload fixtures that mirror what Parse Server 8.4.0 actually sends. The
# fixture shapes were captured from a live container via the diagnostic in
# test/lib/parse/webhook_aftersave_state_integration_test.rb and a one-off
# raw-payload probe:
#
#   NEW   create raw object keys:
#         ["className","createdAt","objectId","status","title","updatedAt"]
#         (createdAt == updatedAt; ACL only present when the record has one)
#   UPDATE        raw object & original keys (record HAS an ACL):
#         ["ACL","className","createdAt","objectId","status","title","updatedAt"]
#         (createdAt < updatedAt; "original" present)
#
# Parse Server 8.4.0 does NOT send the Mongo-internal _rperm / _wperm in the
# REST webhook payload, so we do not assert on them here (there is also no
# Parse::Object property accessor for them). ACL DOES come through and survives,
# so it is asserted.
#
# ============================ WHAT THIS LOCKS IN ============================
# Parse::Webhooks::Payload#initialize scrubs trigger payloads with
# `scrub_credentials` (lib/parse/webhooks/payload.rb), which removes ONLY
# WEBHOOK_TRIGGER_CREDENTIAL_KEYS (session tokens, password hashes). Every
# other server-authoritative field -- createdAt/updatedAt, ACL, authData,
# roles, internal fields -- passes through to the handler, so `existed?` /
# `new?` read correctly and the full-object-fidelity contract holds.
#
# These tests are the guard that catches anyone re-introducing over-broad
# scrubbing (e.g. switching back to PROTECTED_MASS_ASSIGNMENT_KEYS, which
# includes createdAt/updatedAt): a dropped server field makes the fidelity
# assertions fail.
# ============================================================================

# Neutral domain class per CLAUDE.md domain-term hygiene (Post, not Capture).
class FidelityPost < Parse::Object
  parse_class "FidelityPost"
  property :title, :string
  property :status, :string
  property :body, :string
end

# Model with declared defaults, to lock in that an afterSave CREATE marks a
# field changed even when its create value EQUALS the property default. `build`
# applies defaults then clears changes; without the create-branch reset the
# overlay's dirty guard would suppress the mark for default-equal values.
class DefaultPost < Parse::Object
  parse_class "DefaultPost"
  property :title, :string
  property :status, :string, default: "draft"
  property :count, :integer, default: 0
  property :archived, :boolean, default: false
end

# Records `self` inside each model lifecycle callback so the tests can assert
# that a webhook-built object handed to before_save / before_create /
# after_create / after_save is the full object the server sent.
class LifecyclePost < Parse::Object
  parse_class "LifecyclePost"
  property :title, :string
  property :status, :string
  property :body, :string

  class << self
    attr_accessor :seen
  end
  self.seen = []

  before_save   { LifecyclePost.snapshot(self, :before_save) }
  before_create { LifecyclePost.snapshot(self, :before_create) }
  after_create  { LifecyclePost.snapshot(self, :after_create) }
  after_save    { LifecyclePost.snapshot(self, :after_save) }

  def self.snapshot(obj, hook)
    seen << {
      hook: hook,
      id: obj.id,
      title: obj.title,
      status: obj.status,
      has_created_at: !obj.created_at.nil?,
      has_updated_at: !obj.updated_at.nil?,
      new?: obj.new?,
      existed?: obj.existed?,
      has_acl: !obj.acl.nil?,
      title_changed?: obj.title_changed?,
    }
    true
  end
end

# A model whose before_create halts the save (returns false). Used to verify
# the webhook before-phase propagates a before_create halt as a rejection.
class HaltCreatePost < Parse::Object
  parse_class "HaltCreatePost"
  property :title, :string
  before_create { false }
end

# A model with conditional (`:if`) before callbacks. Used to verify the
# before-phase runner honors `:if`/`:unless` (the conditional callbacks must
# be skipped, not run unconditionally).
class CondCbPost < Parse::Object
  parse_class "CondCbPost"
  property :title, :string
  class << self; attr_accessor :ran; end
  self.ran = []
  before_save   :always_bs
  before_save   :skip_bs,  if: -> { false }
  before_create :always_bc
  before_create :skip_bc,  if: -> { false }
  def always_bs; CondCbPost.ran << :always_bs; end
  def skip_bs;   CondCbPost.ran << :skip_bs; end
  def always_bc; CondCbPost.ran << :always_bc; end
  def skip_bc;   CondCbPost.ran << :skip_bc; end
end

class WebhookAfterSavePayloadFidelityTest < Minitest::Test
  def setup
    Parse::Webhooks.instance_variable_set(:@routes, nil)
  end

  def teardown
    Parse::Webhooks.instance_variable_set(:@routes, nil)
  end

  # ------------------------------------------------------------------------
  # Fixtures: realistic Parse Server 8.4.0 afterSave payloads.
  # ------------------------------------------------------------------------

  CREATED_AT = "2026-06-04T12:00:00.000Z"
  UPDATED_AT = "2026-06-04T12:05:30.250Z"

  # A brand-new object: createdAt == updatedAt, NO "original".
  # ACL included to mirror a record that carries one (owner-only).
  def new_aftersave_payload
    {
      "triggerName" => "afterSave",
      "object" => {
        "className"  => "FidelityPost",
        "objectId"   => "NEWobj0001",
        "title"      => "hello world",
        "status"     => "draft",
        "createdAt"  => CREATED_AT,
        "updatedAt"  => CREATED_AT, # equal => freshly created
        "ACL"        => { "u_owner" => { "read" => true, "write" => true } },
      },
      "headers" => { "x-parse-request-id" => "client_create_01" },
    }
  end

  # A changed object: createdAt < updatedAt, WITH "original".
  # Title changed hello->goodbye; status unchanged. Both object and original
  # carry createdAt/updatedAt/ACL exactly as Parse Server sends them.
  def changed_aftersave_payload
    {
      "triggerName" => "afterSave",
      "object" => {
        "className"  => "FidelityPost",
        "objectId"   => "UPDobj0001",
        "title"      => "goodbye world",
        "status"     => "draft",
        "body"       => "v2",
        "createdAt"  => CREATED_AT,
        "updatedAt"  => UPDATED_AT, # differs => this is an update
        "ACL"        => { "u_owner" => { "read" => true, "write" => true } },
      },
      "original" => {
        "className"  => "FidelityPost",
        "objectId"   => "UPDobj0001",
        "title"      => "hello world",
        "status"     => "draft",
        "body"       => "v1",
        "createdAt"  => CREATED_AT,
        "updatedAt"  => CREATED_AT,
        "ACL"        => { "u_owner" => { "read" => true, "write" => true } },
      },
      "headers" => { "x-parse-request-id" => "client_update_01" },
    }
  end

  # ========================================================================
  # A1. NEW object semantics
  # ========================================================================

  def test_new_payload_object_identity_and_acl
    obj = Parse::Webhooks::Payload.new(new_aftersave_payload).parse_object
    refute_nil obj, "parse_object must build a typed object for an afterSave create"
    assert_instance_of FidelityPost, obj
    assert_equal "NEWobj0001", obj.id, "objectId must be present on the built object"
    assert_equal "hello world", obj.title
    assert_equal "draft", obj.status

    # ACL is NOT in the scrub denylist, so it survives today and must keep
    # surviving. This guards against ACL being added to the scrub set.
    refute_nil obj.acl, "ACL must survive into the built afterSave object"
    assert obj.acl.present?, "ACL must be populated"
    assert_includes obj.acl.permissions.keys, "u_owner",
                    "ACL row-permission for the owner must be readable in the handler"
  end

  # A freshly-created object must expose the server-issued createdAt/updatedAt
  # (equal), which `existed?`/`new?` depend on. Regression guard against
  # re-introducing timestamp scrubbing on the webhook path.
  def test_new_payload_timestamps_populated
    obj = Parse::Webhooks::Payload.new(new_aftersave_payload).parse_object
    refute_nil obj.created_at,
               "created_at must survive into the afterSave object (server-authoritative)"
    refute_nil obj.updated_at,
               "updated_at must survive into the afterSave object (server-authoritative)"
    assert_equal obj.created_at, obj.updated_at,
                 "a freshly-created object has createdAt == updatedAt"
  end

  # existed? must be false for a fresh create. This passes on HEAD ONLY by
  # accident (timestamps are nil -> existed? short-circuits to false). It is
  # kept so that AFTER the fix it still holds via the real createdAt==updatedAt
  # path. It does NOT by itself discriminate fixed-vs-broken; the timestamp
  # test above does.
  def test_new_payload_existed_is_false
    obj = Parse::Webhooks::Payload.new(new_aftersave_payload).parse_object
    # createdAt == updatedAt on a fresh create => existed? false (via the real
    # timestamp path now, not the nil short-circuit).
    refute obj.existed?, "a brand-new object must report existed? == false in afterSave"
    refute obj.new?, "a persisted object (createdAt present) reports new? == false in afterSave"
    assert_nil Parse::Webhooks::Payload.new(new_aftersave_payload).original,
               "a create payload has no original"
  end

  # ----- Change detection on an afterSave CREATE ---------------------------
  # afterSave on a create is now dirty-tracked: every populated data field is
  # reported changed (nil -> value) so a handler can build a sync/diff payload
  # from `*_changed?` / `changes` uniformly across create and update, while the
  # system fields (createdAt / updatedAt / ACL) stay clean and still readable.
  def test_new_payload_dirty_tracking
    obj = Parse::Webhooks::Payload.new(new_aftersave_payload).parse_object
    assert obj.title_changed?,  "title must be reported changed on an afterSave create"
    assert obj.status_changed?, "status must be reported changed on an afterSave create"
    assert_includes obj.changed, "title"
    assert_includes obj.changed, "status"
    # System fields are present (readable) but NOT reported as data changes.
    refute obj.created_at_changed?, "createdAt must stay clean on a create"
    refute obj.updated_at_changed?, "updatedAt must stay clean on a create"
    refute obj.acl_changed?,        "ACL must stay clean on a create"
    refute_nil obj.created_at, "createdAt is still readable"
    refute_nil obj.acl,        "ACL is still readable"
  end

  # Regression guard for the default-value bug: a property whose create value
  # EQUALS its declared default must STILL be reported changed. `build` applies
  # defaults and clears changes; the create branch resets default-bearing ivars
  # so the overlay's `unless val == current` guard fires anyway. Without the
  # reset, status/count/archived come back changed? == false.
  def test_new_payload_dirty_tracking_with_default_values
    payload = {
      "triggerName" => "afterSave",
      "object" => {
        "className" => "DefaultPost",
        "objectId"  => "DEFobj0001",
        "title"     => "hello",
        "status"    => "draft", # == default
        "count"     => 0,       # == default
        "archived"  => false,   # == default
        "createdAt" => CREATED_AT,
        "updatedAt" => CREATED_AT,
      },
    }
    obj = Parse::Webhooks::Payload.new(payload).parse_object
    assert obj.status_changed?,   "status == default must still mark changed on a create"
    assert obj.count_changed?,    "count == default must still mark changed on a create"
    assert obj.archived_changed?, "archived == default must still mark changed on a create"
    assert obj.title_changed?,    "a non-default field marks changed too"
    %w[status count archived title].each do |f|
      assert_includes obj.changed, f, "#{f} must be in changed"
    end
    refute obj.created_at_changed?, "system fields stay clean even with defaults in play"
  end

  # A defaulted property ABSENT from the afterSave payload keeps its default
  # value (still readable) and is NOT reported changed.
  def test_new_payload_absent_default_preserves_value
    payload = {
      "triggerName" => "afterSave",
      "object" => {
        "className" => "DefaultPost",
        "objectId"  => "DEFobj0002",
        "title"     => "hello",
        "createdAt" => CREATED_AT,
        "updatedAt" => CREATED_AT,
      },
    }
    obj = Parse::Webhooks::Payload.new(payload).parse_object
    assert_equal "draft", obj.status, "a defaulted field absent from the payload keeps its default"
    assert_equal 0, obj.count, "absent defaulted field keeps its default value"
    refute obj.status_changed?, "a field absent from the payload is not a change"
    assert obj.title_changed?,  "the present field is reported changed"
  end

  # ========================================================================
  # A2. CHANGED object semantics
  # ========================================================================

  def test_changed_payload_object_identity_and_acl
    payload = Parse::Webhooks::Payload.new(changed_aftersave_payload)
    obj = payload.parse_object
    refute_nil obj
    assert_equal "UPDobj0001", obj.id
    assert_equal "goodbye world", obj.title, "final object reflects the new value"
    refute_nil obj.acl, "ACL must survive into the built afterSave update object"
    refute_nil payload.original, "an update payload carries original"
  end

  # An updated object must expose createdAt < updatedAt so `existed?` returns
  # true. This is the assertion that most clearly discriminates the fix from
  # the old timestamp-stripping behavior.
  def test_changed_payload_existed_true_and_timestamps_differ
    obj = Parse::Webhooks::Payload.new(changed_aftersave_payload).parse_object
    refute_nil obj.created_at, "created_at must populate on an update object"
    refute_nil obj.updated_at, "updated_at must populate on an update object"
    refute_equal obj.created_at, obj.updated_at,
                 "an updated object has createdAt < updatedAt"
    assert obj.existed?,
           "existed? must be true for an object that was updated (not first save)"
    refute obj.new?, "new? must be false for an already-persisted, updated object"
  end

  # ----- Change detection: explicit original-vs-object diff ----------------
  # afterSave is dirty-tracked (see test_changed_payload_dirty_tracking and the
  # create-dirty tests above), but comparing original_parse_object vs
  # parse_object explicitly is still a supported, self-evident way to diff a
  # specific field across the prior and final state.
  def test_changed_payload_diff_via_original_vs_object
    payload = Parse::Webhooks::Payload.new(changed_aftersave_payload)
    obj  = payload.parse_object
    orig = payload.original_parse_object

    refute_nil orig, "original_parse_object must build from the original hash"
    assert_equal "hello world",   orig.title, "original retains previous value"
    assert_equal "goodbye world", obj.title,  "object holds new value"
    refute_equal orig.title, obj.title, "a field-level change is detectable by comparison"
    assert_equal orig.status, obj.status, "unchanged field is equal across original/object"
  end

  # ----- Change detection: dirty tracking on afterSave ----------------------
  # parse_object on an afterSave update is dirty-tracked relative to original,
  # so a webhook author can gate a side effect on `title_changed?` / inspect
  # `changes` -- symmetric with the beforeSave path.
  def test_changed_payload_dirty_tracking
    obj = Parse::Webhooks::Payload.new(changed_aftersave_payload).parse_object
    assert obj.title_changed?,
           "title_changed? must be true on an afterSave update where title changed"
    refute obj.status_changed?,
           "status_changed? must be false where status did not change"
    assert_includes obj.changed, "title",
                    "changed must include the mutated attribute"
    # changes maps attr => [old, new]
    assert_equal ["hello world", "goodbye world"], obj.changes["title"],
                 "changes must reflect original -> object for the mutated field"
  end

  # ========================================================================
  # A3. FULL-OBJECT FIDELITY GUARD
  # ------------------------------------------------------------------------
  # The core regression guard. It compares the set of fields Parse Server
  # actually SENT (read from the UNSCRUBBED raw payload, NOT payload.object
  # which is already scrubbed) against the fields the built object exposes,
  # after mapping remote<->local aliases (objectId<->id, createdAt<->created_at,
  # updatedAt<->updated_at, ACL<->acl). If anyone re-adds timestamp/ACL/ internal
  # scrubbing to the webhook path, a server field silently goes missing and
  # this FAILS.
  #
  # ========================================================================

  # Remote (wire) key -> local accessor used to read it back off the object.
  REMOTE_TO_LOCAL = {
    "objectId"  => :id,
    "createdAt" => :created_at,
    "updatedAt" => :updated_at,
    "ACL"       => :acl,
  }.freeze

  # Wire keys that are routing metadata, not data fields, and are not expected
  # to be readable as object attributes.
  ROUTING_ONLY = %w[className __type].freeze

  def assert_full_object_fidelity(raw_object_hash, built)
    expected_fields = raw_object_hash.keys - ROUTING_ONLY
    missing = expected_fields.reject do |wire_key|
      reader = REMOTE_TO_LOCAL[wire_key] || wire_key.to_sym
      built.respond_to?(reader) && !built.public_send(reader).nil?
    end
    assert_empty missing,
                 "Webhook object dropped server-sent field(s) #{missing.inspect}. " \
                 "Parse Server sent #{raw_object_hash.keys.sort.inspect}; the built " \
                 "object must expose every data field. A non-empty diff means " \
                 "over-broad scrubbing was (re)introduced on the webhook path " \
                 "(see Parse::Webhooks::Payload#scrub_credentials)."
  end

  def test_full_object_fidelity_new_create
    payload = Parse::Webhooks::Payload.new(new_aftersave_payload)
    # Reference set = what the SERVER sent = the UNSCRUBBED raw payload.
    raw_object = payload.raw[:object]
    assert raw_object.is_a?(Hash), "raw payload object must be retained for the guard"
    assert_full_object_fidelity(raw_object, payload.parse_object)
  end

  def test_full_object_fidelity_changed_update
    payload = Parse::Webhooks::Payload.new(changed_aftersave_payload)
    raw_object = payload.raw[:object]
    assert_full_object_fidelity(raw_object, payload.parse_object)

    # And the original side must be equally faithful.
    raw_original = payload.raw[:original]
    assert raw_original.is_a?(Hash), "raw original must be retained for the guard"
    assert_full_object_fidelity(raw_original, payload.original_parse_object)
  end

  # Belt-and-suspenders: prove the guard's reference set is the UNSCRUBBED raw,
  # not the already-scrubbed payload.object. Use a payload that DOES carry a
  # credential so the two key sets genuinely differ (server-authoritative
  # fields like createdAt are kept by both; only the credential is dropped).
  def test_guard_reference_set_uses_unscrubbed_raw
    p = new_aftersave_payload
    p["object"] = p["object"].merge("sessionToken" => "r:should-be-scrubbed")
    payload = Parse::Webhooks::Payload.new(p)

    raw_keys      = payload.raw[:object].keys.sort
    scrubbed_keys = payload.object.keys.sort

    assert_includes raw_keys, "createdAt",
                    "raw payload must retain createdAt for the fidelity reference set"
    assert_includes raw_keys, "sessionToken",
                    "raw payload retains the credential (reference set is pre-scrub)"
    refute_includes scrubbed_keys, "sessionToken",
                    "the scrubbed object must drop the credential"
    assert_includes scrubbed_keys, "createdAt",
                    "the scrubbed object must KEEP server-authoritative createdAt"
    refute_equal raw_keys, scrubbed_keys,
                 "raw and scrubbed key sets differ only by the credential"
  end

  # ========================================================================
  # A4. WRITE-SIDE GUARANTEE (the defense that replaces read-side scrubbing)
  # ------------------------------------------------------------------------
  # The handler can READ the full object, but a save of a webhook-built object
  # must never transmit forged privileged fields. _rperm/_wperm/_hashed_password
  # are not declared properties, so changes_payload/attribute_updates exclude
  # them; createdAt/updatedAt are BASE_KEYS and are likewise excluded from a
  # save body.
  # ========================================================================
  def test_forged_privileged_fields_never_reach_save_body
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "object" => {
        "className" => "FidelityPost",
        "objectId" => "UPDobj0001",
        "title" => "goodbye world",
        "_rperm" => ["*"],
        "_wperm" => ["userAttacker"],
        "_hashed_password" => "$2b$forged",
        "createdAt" => CREATED_AT,
        "updatedAt" => UPDATED_AT,
      },
      "original" => {
        "className" => "FidelityPost",
        "objectId" => "UPDobj0001",
        "title" => "hello world",
        "createdAt" => CREATED_AT,
        "updatedAt" => CREATED_AT,
      },
    )
    body = payload.parse_object.changes_payload
    %w[_rperm _wperm _hashed_password createdAt updatedAt].each do |forbidden|
      refute body.key?(forbidden),
             "#{forbidden} must never reach the save body returned to Parse Server"
    end
    assert_equal "goodbye world", body["title"],
                 "a legitimate field change is still transmitted"
  end

  # ========================================================================
  # A5. LIFECYCLE-CALLBACK FIDELITY + ORDER (before_save / before_create /
  #     after_create / after_save)
  # ------------------------------------------------------------------------
  # Driven through the REAL webhook dispatcher (call_route), since Parse Server
  # exposes no separate beforeCreate/afterCreate triggers -- the beforeSave hook
  # runs before_save then before_create (for new objects), and the afterSave
  # hook runs after_create then after_save. This is ActiveModel order
  # (before_save wraps before_create; after_create precedes after_save). Each
  # callback must also see the FULL object the server sent.
  # ========================================================================

  # beforeSave on a CREATE: Parse Server sends the submitted object (no server
  # timestamps yet, since it is not persisted), no "original".
  def beforesave_create_payload
    {
      "triggerName" => "beforeSave",
      "object" => {
        "className" => "LifecyclePost",
        "objectId"  => "BScreate01",
        "title"     => "new title",
        "status"    => "draft",
        "ACL"       => { "u_owner" => { "read" => true, "write" => true } },
      },
      "headers" => { "x-parse-request-id" => "client_bs_create" },
    }
  end

  # beforeSave on an UPDATE: object carries the new values + server timestamps;
  # original carries the prior state.
  def beforesave_update_payload
    {
      "triggerName" => "beforeSave",
      "object" => {
        "className" => "LifecyclePost", "objectId" => "BSupd01",
        "title" => "new title", "status" => "draft",
        "createdAt" => CREATED_AT, "updatedAt" => CREATED_AT,
      },
      "original" => {
        "className" => "LifecyclePost", "objectId" => "BSupd01",
        "title" => "old title", "status" => "draft",
        "createdAt" => CREATED_AT, "updatedAt" => CREATED_AT,
      },
      "headers" => { "x-parse-request-id" => "client_bs_update" },
    }
  end

  def lifecycle_snapshot(hook)
    LifecyclePost.seen.find { |s| s[:hook] == hook }
  end

  # Dispatch a payload through the real webhook router with a route block.
  # The chained after_save/after_create callbacks fire in run_after_save_chain
  # (which call! invokes once per delivery), not in call_route, so we drive it
  # here too. It is a no-op for the before_save triggers, whose before_* chain
  # still fires inside call_route.
  def dispatch_lifecycle(trigger, payload_hash, &route)
    LifecyclePost.seen = []
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks.route(trigger, "LifecyclePost", &route)
    payload = Parse::Webhooks::Payload.new(payload_hash)
    Parse::Webhooks.call_route(trigger, "LifecyclePost", payload)
    Parse::Webhooks.run_after_save_chain(payload)
    LifecyclePost.seen.map { |s| s[:hook] }
  end

  def test_before_save_then_before_create_fire_in_order_on_create
    # Parse Server has no beforeCreate webhook; the beforeSave hook runs
    # before_save THEN before_create for a new object (ActiveModel order).
    order = dispatch_lifecycle(:before_save, beforesave_create_payload) { parse_object }
    assert_equal [:before_save, :before_create], order,
                 "beforeSave webhook runs before_save then before_create on a create"
    LifecyclePost.seen.each do |s|
      assert_equal "BScreate01", s[:id], "#{s[:hook]} sees the objectId"
      assert_equal "new title", s[:title], "#{s[:hook]} sees the submitted title"
      assert_equal "draft", s[:status], "#{s[:hook]} sees the submitted status"
      assert s[:has_acl], "#{s[:hook]} sees the submitted ACL"
      assert s[:new?], "#{s[:hook]} on a create reports new? == true (not yet persisted)"
    end
  end

  def test_before_create_does_not_fire_on_update
    order = dispatch_lifecycle(:before_save, beforesave_update_payload) { parse_object }
    assert_includes order, :before_save, "before_save runs on an update"
    refute_includes order, :before_create, "before_create must NOT run on an update"

    bs = lifecycle_snapshot(:before_save)
    assert_equal "new title", bs[:title], "before_save sees the new value on update"
    assert bs[:has_created_at], "before_save sees server createdAt on update"
    assert bs[:title_changed?], "before_save sees dirty tracking (title changed) on update"
  end

  def test_after_create_then_after_save_fire_in_order_on_create
    raw = new_aftersave_payload
    raw["object"] = raw["object"].merge("className" => "LifecyclePost")
    order = dispatch_lifecycle(:after_save, raw) { true }
    assert_equal [:after_create, :after_save], order,
                 "afterSave webhook runs after_create then after_save on a create"
    LifecyclePost.seen.each do |s|
      assert_equal "NEWobj0001", s[:id], "#{s[:hook]} sees the persisted objectId"
      assert_equal "hello world", s[:title], "#{s[:hook]} sees the persisted title"
      assert s[:has_created_at], "#{s[:hook]} sees server createdAt"
      assert s[:has_updated_at], "#{s[:hook]} sees server updatedAt"
      assert s[:has_acl], "#{s[:hook]} sees the ACL"
      refute s[:existed?], "#{s[:hook]} on a fresh create reports existed? == false"
      refute s[:new?], "#{s[:hook]} reports new? == false (object is persisted)"
    end
  end

  # A before_create returning false must halt the save the same way before_save
  # does — the dispatcher raises a ResponseError that becomes a Parse Server
  # rejection.
  def test_before_create_halt_rejects_the_save
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks.route(:before_save, "HaltCreatePost") { parse_object }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "object" => { "className" => "HaltCreatePost", "objectId" => "h1", "title" => "x" },
      "headers" => { "x-parse-request-id" => "client_halt" },
    )
    err = assert_raises(Parse::Webhooks::ResponseError) do
      Parse::Webhooks.call_route(:before_save, "HaltCreatePost", payload)
    end
    assert_match(/before_create/, err.message,
                 "a before_create returning false halts the save with a before_create error")
  end

  # The before-phase runner must honor `:if`/`:unless` (and the terminator),
  # not run every callback unconditionally.
  def test_conditional_before_callbacks_are_honored
    CondCbPost.ran = []
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks.route(:before_save, "CondCbPost") { parse_object }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "object" => { "className" => "CondCbPost", "objectId" => "c1", "title" => "x" },
      "headers" => { "x-parse-request-id" => "client_cond" },
    )
    Parse::Webhooks.call_route(:before_save, "CondCbPost", payload)

    assert_includes CondCbPost.ran, :always_bs, "unconditional before_save runs"
    assert_includes CondCbPost.ran, :always_bc, "unconditional before_create runs (create)"
    refute_includes CondCbPost.ran, :skip_bs, "`if: false` before_save must be skipped"
    refute_includes CondCbPost.ran, :skip_bc, "`if: false` before_create must be skipped"
  end
end
