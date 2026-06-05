# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# The webhook trigger allowlist must mirror Parse Server's `triggers.Types` so
# the SDK no longer pre-rejects registration of the auth / LiveQuery / password-
# reset hooks. (This gates registration only; payload routing for the non-object
# shapes is a separate follow-up.)
class TestHooksTriggerNames < Minitest::Test
  class HookHost
    include Parse::API::Hooks
  end

  NEW_TRIGGERS = %i[beforeLogin afterLogin afterLogout beforePasswordResetRequest
                    beforeConnect beforeSubscribe afterEvent].freeze

  def test_new_trigger_types_in_allowlist
    NEW_TRIGGERS.each do |t|
      assert_includes Parse::API::Hooks::TRIGGER_NAMES, t, "#{t} should be allowlisted"
    end
  end

  def test_original_object_triggers_preserved
    %i[beforeSave afterSave beforeDelete afterDelete beforeFind afterFind].each do |t|
      assert_includes Parse::API::Hooks::TRIGGER_NAMES, t
    end
  end

  def test_create_is_not_a_registerable_trigger
    # beforeCreate/afterCreate are NOT Parse Server trigger types — they are
    # ActiveModel callbacks dispatched inside beforeSave/afterSave.
    refute_includes Parse::API::Hooks::TRIGGER_NAMES, :afterCreate
    refute_includes Parse::API::Hooks::TRIGGER_NAMES, :beforeCreate
    refute_includes Parse::API::Hooks::TRIGGER_NAMES_LOCAL, :after_create
    refute_includes Parse::API::Hooks::TRIGGER_NAMES_LOCAL, :before_create
  end

  def test_verify_trigger_create_raises_helpful_guidance
    host = HookHost.new
    %i[before_create beforeCreate].each do |t|
      err = assert_raises(ArgumentError) { host.send(:_verify_trigger, t) }
      assert_match(/no beforeCreate webhook trigger/, err.message)
      assert_match(/beforeSave/, err.message)
    end
    %i[after_create afterCreate].each do |t|
      err = assert_raises(ArgumentError) { host.send(:_verify_trigger, t) }
      assert_match(/no afterCreate webhook trigger/, err.message)
      assert_match(/afterSave/, err.message)
    end
  end

  def test_local_snake_case_list_in_sync
    assert_equal Parse::API::Hooks::TRIGGER_NAMES.length,
                 Parse::API::Hooks::TRIGGER_NAMES_LOCAL.length
    assert_includes Parse::API::Hooks::TRIGGER_NAMES_LOCAL, :before_password_reset_request
    assert_includes Parse::API::Hooks::TRIGGER_NAMES_LOCAL, :after_event
  end

  def test_verify_trigger_accepts_snake_case_new_names
    host = HookHost.new
    assert_equal :beforeLogin, host.send(:_verify_trigger, :before_login)
    assert_equal :beforePasswordResetRequest,
                 host.send(:_verify_trigger, :before_password_reset_request)
    assert_equal :afterEvent, host.send(:_verify_trigger, "after_event")
  end

  def test_verify_trigger_accepts_camel_case_new_names
    host = HookHost.new
    assert_equal :beforeSubscribe, host.send(:_verify_trigger, "beforeSubscribe")
  end

  def test_verify_trigger_still_rejects_bogus
    host = HookHost.new
    assert_raises(ArgumentError) { host.send(:_verify_trigger, :totallyNotATrigger) }
  end

  # --- trigger className validation (@File / @Connect pseudo-classes) -------

  def test_trigger_class_name_accepts_pseudo_classes
    ps = Parse::API::PathSegment
    assert_equal "@File", ps.trigger_class_name!("@File")
    assert_equal "@Connect", ps.trigger_class_name!("@Connect")
    assert_equal "_User", ps.trigger_class_name!("_User")
    assert_equal "Post", ps.trigger_class_name!("Post")
  end

  def test_trigger_class_name_rejects_path_traversal
    ps = Parse::API::PathSegment
    %w[../_User a/b @@x @ a.b].each do |bad|
      assert_raises(ArgumentError, "#{bad.inspect} should be rejected") do
        ps.trigger_class_name!(bad)
      end
    end
  end

  # --- webhook route DSL rejects create with guidance ----------------------

  def test_route_dsl_rejects_create_with_guidance
    err = assert_raises(ArgumentError) do
      Parse::Webhooks.route(:after_create, "Post") { parse_object }
    end
    assert_match(/no after_create webhook/, err.message)
    assert_match(/after_save/, err.message)
  end
end
