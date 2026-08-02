# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Whether one raising `after_*` handler prevents the rest from running.
#
# Handlers for the accumulating `after_*` triggers are folded with `Array#map`,
# and `map` abandons the collection on the first raise. That made "a raise
# starves every handler registered after it" an emergent property of the fold
# rather than a decision, and registration order is not fully under an
# application's control: the SDK's own cache-invalidation triggers install
# during `Parse.setup`, ahead of handlers registered by application files.
#
# `Parse::Webhooks.abort_after_callbacks_on_error` makes it a decision.
class WebhookHandlerIsolationTest < Minitest::Test
  def setup
    @previous = Parse::Webhooks.abort_after_callbacks_on_error
    Parse::Webhooks.instance_variable_set(:@routes, nil)
  end

  def teardown
    Parse::Webhooks.abort_after_callbacks_on_error = @previous
    Parse::Webhooks.instance_variable_set(:@routes, nil)
  end

  # Dispatch the composed registry directly. `call_route` does a great deal of
  # payload work around the fold that is irrelevant here and needs a configured
  # client; this exercises the fold itself.
  def dispatch(type, class_name, payload = nil)
    registry = Parse::Webhooks.routes[type][class_name]
    Parse::Webhooks.send(:dispatch_composed, payload || Object.new, registry, type)
  end

  def register_three(type: :after_save, class_name: "Widget")
    ran = []
    Parse::Webhooks.route(type, class_name) { |_p| ran << :first }
    Parse::Webhooks.route(type, class_name) { |_p| raise IOError, "backend down" }
    Parse::Webhooks.route(type, class_name) { |_p| ran << :third }
    ran
  end

  def test_default_is_to_abort
    assert_equal true, Parse::Webhooks.abort_after_callbacks_on_error,
                 "the default must preserve the historical behavior"
  end

  def test_aborting_stops_at_the_first_raise
    ran = register_three
    assert_raises(IOError) { dispatch(:after_save, "Widget") }
    assert_equal [:first], ran,
                 "handlers after the raising one must not run when aborting"
  end

  def test_isolating_runs_every_handler
    Parse::Webhooks.abort_after_callbacks_on_error = false
    ran = register_three
    dispatch(:after_save, "Widget")
    assert_equal [:first, :third], ran,
                 "a raising handler must not starve the ones registered after it"
  end

  def test_isolating_swallows_the_error
    Parse::Webhooks.abort_after_callbacks_on_error = false
    register_three
    dispatch(:after_save, "Widget") # must not raise
  end

  def test_isolating_reports_the_failure
    Parse::Webhooks.abort_after_callbacks_on_error = false
    register_three
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("parse.webhooks.handler_error") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
    begin
      capture_io { dispatch(:after_save, "Widget") }
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 1, events.size, "an isolated failure must still be reported"
    assert_equal "IOError", events.first.payload[:error]
    assert_equal :after_save, events.first.payload[:trigger]
  end

  # A silent skip would be worse than the starvation it replaces.
  def test_isolating_warns_on_stderr
    Parse::Webhooks.abort_after_callbacks_on_error = false
    register_three
    _out, err = capture_io { dispatch(:after_save, "Widget") }
    assert_match(/IOError/, err)
    assert_match(/backend down/, err)
  end

  def test_isolation_applies_to_after_delete_and_after_logout
    Parse::Webhooks.abort_after_callbacks_on_error = false
    [[:after_delete, "Widget"], [:after_logout, "_Session"]].each do |type, class_name|
      Parse::Webhooks.instance_variable_set(:@routes, nil)
      ran = register_three(type: type, class_name: class_name)
      dispatch(type, class_name)
      assert_equal [:first, :third], ran, "#{type} must isolate handlers too"
    end
  end

  # `before_*` triggers store a single block rather than an array, so they never
  # reach the composed fold at all. A raise there is how a handler denies the
  # operation and must keep propagating regardless of this setting.
  def test_before_triggers_store_a_single_handler_and_are_unaffected
    Parse::Webhooks.abort_after_callbacks_on_error = false
    Parse::Webhooks.route(:before_save, "Widget") { |_p| :first }
    Parse::Webhooks.route(:before_save, "Widget") { |_p| :second }

    registry = Parse::Webhooks.routes[:before_save]["Widget"]
    refute_kind_of Array, registry,
                   "before_save must not accumulate, so isolation cannot apply to it"
  end

  def test_rejectable_non_object_triggers_are_not_composed
    Parse::Webhooks.route(:before_login, "_User") { |_p| :first }
    Parse::Webhooks.route(:before_login, "_User") { |_p| :second }

    registry = Parse::Webhooks.routes[:before_login]["_User"]
    refute_kind_of Array, registry,
                   "a rejectable trigger must deny if ANY handler denies, so it " \
                   "cannot be folded"
  end
end
