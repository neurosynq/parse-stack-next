require_relative "../../test_helper"
require "minitest/autorun"
require "stringio"
require "logger"

class GuardedThing < Parse::Object
  property :slug, :string
  property :owner, :string
  property :title, :string

  guard :owner, :master_only
  guard :slug, :immutable

  # Prevent autofetch when setters touch pointers in tests.
  def autofetch!(*)
    nil
  end
end

class GuardedSubThing < GuardedThing
  property :extra, :string
  guard :extra, :immutable
end

class GuardedAuthor < Parse::Object
  property :name, :string

  def autofetch!(*)
    nil
  end
end

class GuardedAlwaysImmutable < Parse::Object
  property :slug, :string
  property :note, :string

  guard :slug, :always_immutable

  def autofetch!(*); nil; end
end

class GuardedAcl < Parse::Object
  property :title, :string

  guard :acl, :master_only

  def autofetch!(*); nil; end
end

class GuardedFieldOverride < Parse::Object
  property :external_ref, :string, field: "externalRef"
  property :title, :string
  guard :external_ref, :immutable
  def autofetch!(*); nil; end
end

class GuardedTypes < Parse::Object
  property :occurred_at, :date
  property :tags, :array
  property :metadata, :object
  guard :occurred_at, :immutable
  guard :tags, :master_only
  guard :metadata, :master_only
  def autofetch!(*); nil; end
end

class GuardedWithDefault < Parse::Object
  property :status, :string, default: "pending"   # immutable with default
  property :region, :string, default: "us-east"   # master_only with default
  property :title, :string

  guard :status, :immutable
  guard :region, :master_only

  def autofetch!(*); nil; end
end

class GuardedPost < Parse::Object
  property :title, :string
  belongs_to :author, as: :guarded_author
  has_many :tags, as: :guarded_thing, through: :relation

  guard :author, :master_only
  guard :tags, :master_only

  def autofetch!(*)
    nil
  end
end

class FieldGuardsTest < Minitest::Test
  def setup
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse.setup(
      server_url: "https://test.parse.com",
      application_id: "test",
      api_key: "test",
    )
    @log_io = StringIO.new
    @prev_logger = Parse.logger
    Parse.logger = Logger.new(@log_io)
    Parse.logger.level = Logger::INFO
  end

  def teardown
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse.logger = @prev_logger
  end

  def test_class_level_dsl_stores_guards
    assert_equal :master_only, GuardedThing.field_guards[:owner]
    assert_equal :immutable, GuardedThing.field_guards[:slug]
  end

  def test_invalid_mode_raises
    # Use an existing named class so we don't leave an anonymous Parse::Object
    # subclass in Parse::Object.descendants (find_class iterates them).
    assert_raises(ArgumentError) do
      GuardedThing.guard :title, :not_a_mode
    end
    # Guard table must be unchanged after the raise
    refute_equal :not_a_mode, GuardedThing.field_guards[:title]
  end

  def test_client_update_reverts_master_only_and_immutable_fields
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedThing", "objectId" => "abc",
                      "slug" => "orig-slug", "owner" => "alice", "title" => "Old" },
      "object" => { "className" => "GuardedThing", "objectId" => "abc",
                    "slug" => "hacked-slug", "owner" => "attacker", "title" => "New" },
    )
    obj = payload.parse_object
    reverted = obj.apply_field_guards!(master: false, is_new: false)

    assert_includes reverted, :owner
    assert_includes reverted, :slug

    payload_out = obj.changes_payload
    refute payload_out.key?("owner"), "owner should be stripped from changes payload"
    refute payload_out.key?("slug"), "slug should be stripped from changes payload"
    assert_equal "New", payload_out["title"], "unguarded fields pass through"
  end

  def test_partial_revert_lets_unguarded_changes_save
    # Two guarded fields reverted, one valid field still saves successfully.
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedThing", "objectId" => "abc",
                      "slug" => "orig", "owner" => "alice", "title" => "Old" },
      "object" => { "className" => "GuardedThing", "objectId" => "abc",
                    "slug" => "new", "owner" => "bob", "title" => "New" },
    )
    obj = payload.parse_object
    obj.apply_field_guards!(master: false, is_new: false)

    payload_out = obj.changes_payload
    assert_equal({ "title" => "New" }, payload_out,
                 "only the unguarded field survives; save proceeds with that change")
  end

  def test_default_log_level_is_silent
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedThing", "objectId" => "abc", "owner" => "alice" },
      "object" => { "className" => "GuardedThing", "objectId" => "abc", "owner" => "attacker" },
    )
    obj = payload.parse_object
    obj.apply_field_guards!(master: false, is_new: false)
    assert_empty @log_io.string, "default INFO logger emits nothing; reverts are DEBUG-level"
  end

  def test_debug_log_level_records_revert
    Parse.logger.level = Logger::DEBUG
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedThing", "objectId" => "abc", "owner" => "alice" },
      "object" => { "className" => "GuardedThing", "objectId" => "abc", "owner" => "attacker" },
    )
    obj = payload.parse_object
    obj.apply_field_guards!(master: false, is_new: false)
    assert_match(/Reverted client writes on GuardedThing:abc/, @log_io.string)
  end

  def test_master_key_bypasses_guards
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => true,
      "original" => { "className" => "GuardedThing", "objectId" => "abc",
                      "slug" => "orig", "owner" => "alice", "title" => "Old" },
      "object" => { "className" => "GuardedThing", "objectId" => "abc",
                    "slug" => "new", "owner" => "bob", "title" => "New" },
    )
    obj = payload.parse_object
    reverted = obj.apply_field_guards!(master: true, is_new: false)

    assert_empty reverted
    payload_out = obj.changes_payload
    assert_equal "new", payload_out["slug"]
    assert_equal "bob", payload_out["owner"]
    assert_empty @log_io.string
  end

  def test_immutable_field_allowed_on_create
    new_obj = GuardedThing.new(slug: "first-slug", owner: "alice", title: "Hello")
    reverted = new_obj.apply_field_guards!(master: false, is_new: true)

    refute_includes reverted, :slug, ":immutable allowed on create"
    assert_includes reverted, :owner, ":master_only blocked on create"

    payload_out = new_obj.changes_payload
    assert_equal "first-slug", payload_out["slug"]
    # On create, a master_only field that the client tried to set is emitted as
    # a Delete op so Parse Server drops the client-supplied value rather than
    # silently persisting it.
    assert_equal({ "__op" => "Delete" }, payload_out["owner"])
  end

  def test_subclass_inherits_and_extends_guards
    # Parent guards carry into the subclass
    assert_equal :master_only, GuardedSubThing.field_guards[:owner]
    assert_equal :immutable, GuardedSubThing.field_guards[:slug]
    # Subclass-only guard is present on the child
    assert_equal :immutable, GuardedSubThing.field_guards[:extra]
    # Subclass declarations don't leak back into the parent
    refute GuardedThing.field_guards.key?(:extra),
           "child guard must not pollute parent"
  end

  def test_belongs_to_pointer_reverted_on_update
    orig_author = Parse::Pointer.new("GuardedAuthor", "author_orig")
    new_author  = Parse::Pointer.new("GuardedAuthor", "author_new")

    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedPost", "objectId" => "p1",
                      "title" => "Old",
                      "author" => orig_author.pointer },
      "object" => { "className" => "GuardedPost", "objectId" => "p1",
                    "title" => "New",
                    "author" => new_author.pointer },
    )
    obj = payload.parse_object
    reverted = obj.apply_field_guards!(master: false, is_new: false)

    assert_includes reverted, :author
    payload_out = obj.changes_payload
    refute payload_out.key?("author"), "author pointer change reverted"
    assert_equal "New", payload_out["title"]
  end

  def test_has_many_relation_additions_reverted_on_update
    obj = GuardedPost.new(id: "p1", title: "Existing")
    # Initialize the relation proxy with an empty collection and mark it as
    # loaded so subsequent dirty-tracking dereferences don't hit the server.
    obj.tags.set_collection!([])
    obj.tags.instance_variable_set(:@loaded, true)

    # Simulate client adding to the relation
    new_tag = Parse::Pointer.new("GuardedThing", "tag_new")
    obj.tags.add(new_tag)

    assert obj.relation_changes?, "precondition: relation should be dirty"

    obj.apply_field_guards!(master: false, is_new: false)

    refute obj.relation_changes?,
           "relation additions cleared after guard revert"
  end

  def test_raw_add_relation_op_in_payload_reverted
    # Client may send a raw __op: AddRelation hash for a guarded relation
    # field (not via proxy.add). The payload hydration translates this into
    # proxy state, and the guard must catch it the same as the API path.
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedPost", "objectId" => "p1", "title" => "old" },
      "object" => {
        "className" => "GuardedPost", "objectId" => "p1", "title" => "new",
        "tags" => {
          "__op" => "AddRelation",
          "objects" => [{ "__type" => "Pointer", "className" => "GuardedThing", "objectId" => "t1" }],
        },
      },
    )
    obj = payload.parse_object
    assert obj.relation_changes?, "precondition: raw AddRelation translated to proxy state"

    reverted = obj.apply_field_guards!(master: false, is_new: false)
    assert_includes reverted, :tags
    refute obj.relation_changes?, "raw AddRelation op reverted"
    payload_out = obj.changes_payload
    refute payload_out.key?("tags"), "tags excluded from response"
    assert_equal "new", payload_out["title"], "unguarded fields pass through"
  end

  def test_has_many_relation_removals_reverted
    obj = GuardedPost.new(id: "p1", title: "Existing")
    obj.tags.set_collection!([])
    obj.tags.instance_variable_set(:@loaded, true)

    existing_tag = Parse::Pointer.new("GuardedThing", "tag_existing")
    obj.tags.remove(existing_tag)

    assert obj.relation_changes?, "precondition: relation removal makes it dirty"

    obj.apply_field_guards!(master: false, is_new: false)
    refute obj.relation_changes?, "relation removals cleared after guard revert"
  end

  def test_apply_via_webhook_call_route
    Parse::Webhooks.route(:before_save, "GuardedThing") { parse_object }

    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedThing", "objectId" => "abc",
                      "slug" => "orig", "owner" => "alice" },
      "object" => { "className" => "GuardedThing", "objectId" => "abc",
                    "slug" => "hacked", "owner" => "attacker" },
      "headers" => { "x-parse-request-id" => "client_req_1" },
    )
    result = Parse::Webhooks.call_route(:before_save, "GuardedThing", payload)

    assert result.is_a?(Hash)
    refute result.key?("owner")
    refute result.key?("slug")
  end

  def test_server_side_writes_in_webhook_block_are_preserved
    # The key design property: a trusted webhook handler that writes to a
    # master_only field (e.g. setting created_by from server context) must
    # NOT have that write reverted. Only the client-supplied value gets
    # cleaned, and the handler's subsequent write survives.
    Parse::Webhooks.route(:before_save, "GuardedThing") do
      obj = parse_object
      obj.owner = "server-assigned-owner"   # server-side write to master_only field
      obj
    end

    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedThing", "objectId" => "abc",
                      "slug" => "orig", "owner" => "alice" },
      "object" => { "className" => "GuardedThing", "objectId" => "abc",
                    "slug" => "hacked", "owner" => "attacker" },
      "headers" => { "x-parse-request-id" => "client_req_1" },
    )
    result = Parse::Webhooks.call_route(:before_save, "GuardedThing", payload)

    assert_equal "server-assigned-owner", result["owner"],
                 "trusted server-side write to a master_only field must be preserved"
    refute result.key?("slug"), "client write to immutable field is still reverted"
  end

  def test_ruby_initiated_header_does_not_bypass_guards
    # Security: a client-supplied X-Parse-Request-Id starting with _RB_ must
    # NOT bypass guards. The header is derived from the client request and
    # cannot be a trust signal for write protection.
    Parse::Webhooks.route(:before_save, "GuardedThing") { parse_object }

    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedThing", "objectId" => "abc",
                      "slug" => "orig", "owner" => "alice" },
      "object" => { "className" => "GuardedThing", "objectId" => "abc",
                    "slug" => "hacked", "owner" => "attacker" },
      "headers" => { "x-parse-request-id" => "_RB_attacker_spoofed_this" },
    )
    result = Parse::Webhooks.call_route(:before_save, "GuardedThing", payload)

    refute result.key?("owner"), "spoofed _RB_ prefix must not bypass master_only"
    refute result.key?("slug"), "spoofed _RB_ prefix must not bypass immutable"
  end

  def test_hash_returning_handler_still_applies_guards
    # If the handler returns a Hash (delta) instead of the parse_object,
    # Parse Server would otherwise merge the response with the client payload
    # and persist the client-supplied guarded values. The webhook framework
    # must inject guard entries into the Hash response.
    Parse::Webhooks.route(:before_save, "GuardedThing") do
      # User returns a raw hash with their own delta; never touches parse_object
      { "title" => "set-by-handler" }
    end

    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedThing", "objectId" => "abc",
                      "slug" => "orig", "owner" => "alice", "title" => "Old" },
      "object" => { "className" => "GuardedThing", "objectId" => "abc",
                    "slug" => "hacked", "owner" => "attacker", "title" => "Old" },
    )
    result = Parse::Webhooks.call_route(:before_save, "GuardedThing", payload)

    assert_equal "set-by-handler", result["title"], "handler's hash entries pass through"
    refute result.key?("owner"), "master_only guard injected into hash response"
    refute result.key?("slug"), "immutable guard injected into hash response"
  end

  def test_nil_returning_handler_still_applies_guards_on_create
    # On a CREATE, if the handler returns nil/true (which the framework
    # normalizes to {}), Parse Server would persist the client values. The
    # guard injection must add a Delete op for the master_only field so the
    # value doesn't survive.
    Parse::Webhooks.route(:before_save, "GuardedThing") { nil }

    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "object" => { "className" => "GuardedThing",
                    "slug" => "first-slug", "owner" => "attacker" },
    )
    result = Parse::Webhooks.call_route(:before_save, "GuardedThing", payload)

    assert_equal({ "__op" => "Delete" }, result["owner"],
                 "master_only field is unset via Delete op even when handler returns nil")
  end

  def test_class_with_only_guards_auto_registers_before_save_route
    # A class that declares guards but never declares a webhook handler must
    # still have a before_save route registered, so register_triggers!(url)
    # picks it up and Parse Server actually invokes our webhook.
    Parse::Webhooks.instance_variable_set(:@routes, nil)

    klass = Class.new(Parse::Object) do
      def self.parse_class; "AutoRegisteredGuardClass"; end
      property :name, :string
      property :owner, :string
      guard :owner, :master_only
      def autofetch!(*); nil; end
    end

    refute_nil Parse::Webhooks.routes[:before_save]["AutoRegisteredGuardClass"],
               "guard declaration must auto-register a before_save stub"

    # And the stub must do the right thing under guard pressure
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "AutoRegisteredGuardClass", "objectId" => "x",
                      "name" => "Old", "owner" => "alice" },
      "object" => { "className" => "AutoRegisteredGuardClass", "objectId" => "x",
                    "name" => "New", "owner" => "attacker" },
    )
    result = Parse::Webhooks.call_route(:before_save, "AutoRegisteredGuardClass", payload)
    refute result.key?("owner"), "auto-registered stub still enforces guards"
    assert_equal "New", result["name"], "unguarded changes pass through stub"
  end

  def test_user_webhook_block_replaces_auto_stub
    # If the user later declares their own webhook :before_save, it must
    # replace the auto-registered stub (single-slot semantics).
    Parse::Webhooks.instance_variable_set(:@routes, nil)

    klass = Class.new(Parse::Object) do
      def self.parse_class; "UserOverrideGuardClass"; end
      property :note, :string
      property :owner, :string
      guard :owner, :master_only
      def autofetch!(*); nil; end
    end

    user_block_ran = false
    Parse::Webhooks.route(:before_save, klass) do
      user_block_ran = true
      parse_object
    end

    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "UserOverrideGuardClass", "objectId" => "x",
                      "owner" => "alice" },
      "object" => { "className" => "UserOverrideGuardClass", "objectId" => "x",
                    "owner" => "attacker" },
    )
    Parse::Webhooks.call_route(:before_save, "UserOverrideGuardClass", payload)
    assert user_block_ran, "user-declared block must run instead of the stub"
  end

  def test_guard_empty_fields_raises
    assert_raises(ArgumentError, "guard requires at least one field name") do
      GuardedThing.guard :master_only
    end
  end

  def test_guard_with_no_mode_raises
    assert_raises(ArgumentError) do
      GuardedThing.guard :title
    end
  end

  def test_guard_with_keyword_mode_works
    klass = Class.new(Parse::Object) do
      def self.parse_class; "KeywordGuardClass"; end
      property :x, :string
      guard :x, mode: :master_only
      def autofetch!(*); nil; end
    end
    assert_equal :master_only, klass.field_guards[:x]
  end

  def test_immutable_field_with_default_is_settable_on_create
    # A property with a default should still be settable by the client on
    # create when guarded as :immutable. The default exists as a fallback
    # but doesn't block client-supplied creation values.
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "object" => { "className" => "GuardedWithDefault",
                    "status" => "client-chose-this",
                    "title" => "Hello" },
    )
    obj = payload.parse_object
    reverted = obj.apply_field_guards!(master: false, is_new: true)

    refute_includes reverted, :status,
                    ":immutable with a default must NOT revert client-set value on create"
    assert_equal "client-chose-this", obj.status
  end

  def test_master_only_field_with_default_uses_default_when_client_writes
    # A :master_only property with a default: if the client tries to set it
    # on create, the guard must NOT just emit a Delete op (which would unset
    # and bypass the default). It should drop the client value and let the
    # default apply.
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "object" => { "className" => "GuardedWithDefault",
                    "region" => "client-attempted-region",
                    "title" => "Hello" },
    )
    obj = payload.parse_object
    obj.apply_field_guards!(master: false, is_new: true)

    payload_out = obj.changes_payload
    refute_equal "client-attempted-region", payload_out["region"],
                 "client-supplied master_only value must not be persisted"
    # The default must reach Parse Server: either as the literal default value
    # in changes_payload, or by deleting the field so Parse Server's
    # schema-side default (if any) applies. parse-stack defaults live in
    # Ruby, not in Parse Server's schema, so we expect the default literal.
    assert_equal "us-east", payload_out["region"],
                 "default value must override the client's master_only write"
  end

  def test_master_only_field_with_default_master_can_still_set_it
    # Master-key request bypasses everything, including the default fallback.
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => true,
      "object" => { "className" => "GuardedWithDefault",
                    "region" => "master-explicitly-chose",
                    "title" => "Hello" },
    )
    obj = payload.parse_object
    obj.apply_field_guards!(master: true, is_new: true)

    assert_equal "master-explicitly-chose", obj.changes_payload["region"]
  end

  def test_property_with_field_override_revert_works
    # `property :external_ref, field: "externalRef"` maps a local Ruby name
    # to a different wire-format key. The guard must revert correctly using
    # the local property name (the wire key is translated for us by the
    # payload hydration into the local attribute name in `changed`).
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedFieldOverride", "objectId" => "a",
                      "externalRef" => "orig-ref", "title" => "Old" },
      "object" => { "className" => "GuardedFieldOverride", "objectId" => "a",
                    "externalRef" => "client-tried-to-change-this", "title" => "New" },
    )
    obj = payload.parse_object
    reverted = obj.apply_field_guards!(master: false, is_new: false)

    assert_includes reverted, :external_ref
    payload_out = obj.changes_payload
    refute payload_out.key?("externalRef"),
           "remote key must be absent from changes payload after revert"
    refute payload_out.key?("external_ref"),
           "local key should never appear in wire payload"
    assert_equal "New", payload_out["title"], "unguarded field unaffected"
  end

  def test_guard_on_non_existent_property_is_silent_noop
    # A guard declared for a property name that doesn't exist on the model
    # cannot fire because the field is never in `changed`. This is a silent
    # no-op rather than a class-load-time error.
    klass = Class.new(Parse::Object) do
      def self.parse_class; "GuardedMissingField"; end
      property :real_field, :string
      guard :imaginary_field, :master_only   # not declared as a property
      def autofetch!(*); nil; end
    end

    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "object" => { "className" => "GuardedMissingField", "real_field" => "v" },
    )
    obj = payload.parse_object
    # Apply guards -- should not raise, should not affect the legitimate field.
    reverted = obj.apply_field_guards!(master: false, is_new: true)
    refute_includes reverted, :imaginary_field, "phantom field cannot be reverted"
    assert_equal "v", obj.real_field, "real field untouched"
  end

  def test_date_property_reverts_correctly
    orig_iso = "2020-01-01T12:00:00.000Z"
    new_iso  = "2025-06-15T09:30:00.000Z"
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedTypes", "objectId" => "a",
                      "occurred_at" => { "__type" => "Date", "iso" => orig_iso } },
      "object" => { "className" => "GuardedTypes", "objectId" => "a",
                    "occurred_at" => { "__type" => "Date", "iso" => new_iso } },
    )
    obj = payload.parse_object
    obj.apply_field_guards!(master: false, is_new: false)
    refute obj.changes_payload.key?("occurred_at"),
           ":immutable date field reverted, not in changes payload"
  end

  def test_array_property_reverts_correctly_on_update
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedTypes", "objectId" => "a",
                      "tags" => ["a", "b"] },
      "object" => { "className" => "GuardedTypes", "objectId" => "a",
                    "tags" => ["a", "b", "c-injected"] },
    )
    obj = payload.parse_object
    obj.apply_field_guards!(master: false, is_new: false)
    refute obj.changes_payload.key?("tags"),
           ":master_only array field reverted, not in changes payload"
  end

  def test_object_property_reverts_correctly_on_update
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedTypes", "objectId" => "a",
                      "metadata" => { "k" => "orig" } },
      "object" => { "className" => "GuardedTypes", "objectId" => "a",
                    "metadata" => { "k" => "injected" } },
    )
    obj = payload.parse_object
    obj.apply_field_guards!(master: false, is_new: false)
    refute obj.changes_payload.key?("metadata"),
           ":master_only object field reverted, not in changes payload"
  end

  def test_always_immutable_allows_create_for_client
    new_obj = GuardedAlwaysImmutable.new(slug: "first-slug", note: "hello")
    reverted = new_obj.apply_field_guards!(master: false, is_new: true)
    refute_includes reverted, :slug, ":always_immutable still allows client create"
    assert_equal "first-slug", new_obj.changes_payload["slug"]
  end

  def test_always_immutable_allows_create_for_master
    new_obj = GuardedAlwaysImmutable.new(slug: "master-set", note: "hi")
    reverted = new_obj.apply_field_guards!(master: true, is_new: true)
    refute_includes reverted, :slug, ":always_immutable still allows master create"
    assert_equal "master-set", new_obj.changes_payload["slug"]
  end

  def test_always_immutable_reverts_client_update
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedAlwaysImmutable", "objectId" => "a",
                      "slug" => "frozen", "note" => "old" },
      "object" => { "className" => "GuardedAlwaysImmutable", "objectId" => "a",
                    "slug" => "client-rename", "note" => "new" },
    )
    obj = payload.parse_object
    reverted = obj.apply_field_guards!(master: false, is_new: false)
    assert_includes reverted, :slug
    refute obj.changes_payload.key?("slug")
    assert_equal "new", obj.changes_payload["note"]
  end

  def test_always_immutable_reverts_master_update_too
    # The point of :always_immutable: master writes are ALSO reverted on
    # update. This is the difference from :immutable.
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => true,
      "original" => { "className" => "GuardedAlwaysImmutable", "objectId" => "a",
                      "slug" => "frozen", "note" => "old" },
      "object" => { "className" => "GuardedAlwaysImmutable", "objectId" => "a",
                    "slug" => "even-master-cant-rename", "note" => "new" },
    )
    obj = payload.parse_object
    reverted = obj.apply_field_guards!(master: true, is_new: false)
    assert_includes reverted, :slug,
                    ":always_immutable must revert even master-key updates"
    refute obj.changes_payload.key?("slug"),
           "master update to :always_immutable field stripped from payload"
    assert_equal "new", obj.changes_payload["note"]
  end

  def test_acl_master_only_reverts_client_widening
    permissive = { "*" => { "read" => true, "write" => true } }
    restrictive = { "u_owner" => { "read" => true, "write" => true } }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "original" => { "className" => "GuardedAcl", "objectId" => "a",
                      "title" => "x", "ACL" => restrictive },
      "object" => { "className" => "GuardedAcl", "objectId" => "a",
                    "title" => "y", "ACL" => permissive },
    )
    obj = payload.parse_object
    reverted = obj.apply_field_guards!(master: false, is_new: false)
    assert_includes reverted, :acl, "client ACL widening was reverted"
    refute obj.changes_payload.key?("ACL"),
           "ACL omitted from response payload after revert"
    assert_equal "y", obj.changes_payload["title"], "unguarded field still passes"
  end

  def test_acl_master_only_bypassed_by_master_key
    permissive = { "*" => { "read" => true, "write" => true } }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => true,
      "original" => { "className" => "GuardedAcl", "objectId" => "a",
                      "title" => "x", "ACL" => { "u_owner" => { "read" => true, "write" => true } } },
      "object" => { "className" => "GuardedAcl", "objectId" => "a",
                    "title" => "x", "ACL" => permissive },
    )
    obj = payload.parse_object
    reverted = obj.apply_field_guards!(master: true, is_new: false)
    refute_includes reverted, :acl, "master may rewrite ACL"
    assert_equal permissive, obj.changes_payload["ACL"]
  end

  def test_server_assigned_created_by_pattern
    # The canonical use case for :master_only: server assigns created_by
    # from the authorized user; client cannot.
    Parse::Webhooks.route(:before_save, "GuardedThing") do
      obj = parse_object
      # Server-side: assign created_by from the authenticated user. This
      # mimics setting `obj.created_by = payload.user` for a real user.
      obj.owner = "authorized-user-uid"
      obj
    end

    # Client tries to set owner directly:
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "master" => false,
      "object" => { "className" => "GuardedThing",
                    "slug" => "ok-slug",
                    "owner" => "ATTACKER-tried-to-set-this" },
    )
    result = Parse::Webhooks.call_route(:before_save, "GuardedThing", payload)

    assert_equal "authorized-user-uid", result["owner"],
                 "server-assigned owner wins; client-attempted owner is dropped"
    assert_equal "ok-slug", result["slug"], "unguarded fields pass through"
  end
end
