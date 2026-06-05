# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper_integration"

# Integration coverage proving that each webhook trigger type added to the
# allowlist in 5.4.0 can actually be registered against a live Parse Server
# (9.x) — register -> fetch -> delete round-trips cleanly. This is the surface
# the allowlist expansion enabled; payload routing for the non-object trigger
# shapes (login / connect / subscribe carry no `object`) remains a follow-up.
#
# NOTE on `beforeConnect`: it is a connection-global trigger whose documented
# className is the `@Connect` sentinel. Parse Server accepts `@Connect` on
# create, but the SDK's `PathSegment.identifier!` guard rejects the leading `@`
# on fetch/delete (same as `@File` for file triggers) — so this test exercises
# `beforeConnect` under a concrete className (`_User`) where the full lifecycle
# is SDK-manageable. First-class `@Connect` / `@File` path handling is a
# separate follow-up.
class HooksTriggerRegistrationIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  WEBHOOK_URL = "https://hooks.example.com/parse-stack-trigger-it"

  # [triggerName, className]
  NEW_TRIGGERS = [
    [:beforeLogin,                "_User"],
    [:afterLogin,                 "_User"],
    [:afterLogout,                "_Session"],
    [:beforePasswordResetRequest, "_User"],
    [:beforeSubscribe,            "HookRegITClass"],
    [:afterEvent,                 "HookRegITClass"],
    [:beforeConnect,              "_User"],
  ].freeze

  def teardown
    # Best-effort: remove any registration a failed assertion left behind so
    # the next run (and the rest of the suite) starts clean.
    if Parse::Client.client&.master_key.present?
      NEW_TRIGGERS.each { |t, k| Parse.client.delete_trigger(t, k) rescue nil }
      %i[beforeSave afterSave beforeDelete].each { |t| Parse.client.delete_trigger(t, "@File") rescue nil }
      Parse.client.delete_trigger(:beforeSave, "HookRegITClass") rescue nil
    end
    super
  end

  def test_new_trigger_types_register_fetch_delete
    skip "hook registration requires a master key" unless Parse::Client.client&.master_key.present?

    NEW_TRIGGERS.each do |trigger, klass|
      created = Parse.client.create_trigger(trigger, klass, WEBHOOK_URL)
      refute created.error?, "register #{trigger}/#{klass} failed: #{created.error}"
      assert_equal klass, created.result["className"],
                   "#{trigger}/#{klass}: server echoed an unexpected className"
      assert_equal WEBHOOK_URL, created.result["url"]

      fetched = Parse.client.fetch_trigger(trigger, klass)
      refute fetched.error?, "fetch #{trigger}/#{klass} failed: #{fetched.error}"
      assert_equal WEBHOOK_URL, fetched.result["url"]

      deleted = Parse.client.delete_trigger(trigger, klass)
      refute deleted.error?, "delete #{trigger}/#{klass} failed: #{deleted.error}"
    end
  end

  # A previously-allowed object trigger must still register cleanly after the
  # allowlist grew (guards against an accidental regression in the expansion).
  def test_object_trigger_still_registers
    skip "hook registration requires a master key" unless Parse::Client.client&.master_key.present?

    created = Parse.client.create_trigger(:beforeSave, "HookRegITClass", WEBHOOK_URL)
    refute created.error?, "register beforeSave failed: #{created.error}"
    Parse.client.delete_trigger(:beforeSave, "HookRegITClass")
  end

  # File triggers use the `@File` pseudo-class. Before the trigger-className
  # validator relaxation, create succeeded but fetch/delete raised on the `@`.
  # Now the full lifecycle works through the SDK.
  def test_file_trigger_at_pseudo_class_lifecycle
    skip "hook registration requires a master key" unless Parse::Client.client&.master_key.present?

    %i[beforeSave afterSave beforeDelete].each do |trigger|
      created = Parse.client.create_trigger(trigger, "@File", WEBHOOK_URL)
      refute created.error?, "register #{trigger}/@File failed: #{created.error}"

      fetched = Parse.client.fetch_trigger(trigger, "@File")
      refute fetched.error?, "fetch #{trigger}/@File failed: #{fetched.error}"

      deleted = Parse.client.delete_trigger(trigger, "@File")
      refute deleted.error?, "delete #{trigger}/@File failed: #{deleted.error}"
    end
  end
end
