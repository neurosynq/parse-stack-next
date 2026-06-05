# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/autorun"

# Tests for first-class routing of the NON-OBJECT webhook trigger shapes:
# the authentication triggers (beforeLogin / afterLogin / afterLogout /
# beforePasswordResetRequest) and the LiveQuery triggers (beforeConnect /
# beforeSubscribe / afterEvent).
#
# The behavioral contract under test mirrors Parse Server 9.x:
#   * Parse Server's webhook response handler IGNORES the body for all of these
#     (it resolves {}). The ONLY signal that affects the operation is the error
#     path, and only for the "before" variants -- a {success:false} body
#     RESOLVES and lets the login/connect/subscribe proceed. So a handler
#     returning `false` from before_login/before_connect/before_subscribe/
#     before_password_reset_request must be converted to a ResponseError, and a
#     returned Parse::Object must be normalized to a success no-op (never
#     serialized back).
#   * None of these run ActiveModel save/create/destroy callbacks even though
#     the auth triggers carry a _User / _Session object.
class WebhookNonObjectTriggersTest < Minitest::Test
  def setup
    Parse::Webhooks.instance_variable_set(:@routes, nil)
  end

  def teardown
    Parse::Webhooks.instance_variable_set(:@routes, nil)
  end

  # ==========================================================================
  # Trigger-type predicates
  # ==========================================================================

  TRIGGER_PREDICATES = {
    "beforeLogin"                => :before_login?,
    "afterLogin"                 => :after_login?,
    "afterLogout"                => :after_logout?,
    "beforePasswordResetRequest" => :before_password_reset_request?,
    "beforeConnect"              => :before_connect?,
    "beforeSubscribe"            => :before_subscribe?,
    "afterEvent"                 => :after_event?,
  }.freeze

  def test_each_trigger_predicate_is_exclusive
    TRIGGER_PREDICATES.each do |name, predicate|
      payload = Parse::Webhooks::Payload.new("triggerName" => name)
      assert payload.send(predicate), "#{predicate} should be true for #{name}"
      TRIGGER_PREDICATES.each do |other_name, other_pred|
        next if other_pred == predicate
        refute payload.send(other_pred),
               "#{other_pred} should be false for #{name}"
      end
    end
  end

  def test_auth_trigger_classification
    %w[beforeLogin afterLogin afterLogout beforePasswordResetRequest].each do |name|
      p = Parse::Webhooks::Payload.new("triggerName" => name)
      assert p.auth_trigger?, "#{name} should be an auth_trigger?"
      refute p.live_query_trigger?, "#{name} should not be a live_query_trigger?"
    end
  end

  def test_live_query_trigger_classification
    %w[beforeConnect beforeSubscribe afterEvent].each do |name|
      p = Parse::Webhooks::Payload.new("triggerName" => name)
      assert p.live_query_trigger?, "#{name} should be a live_query_trigger?"
      refute p.auth_trigger?, "#{name} should not be an auth_trigger?"
    end
  end

  def test_object_triggers_are_not_auth_or_live_query
    %w[beforeSave afterSave beforeDelete afterFind].each do |name|
      p = Parse::Webhooks::Payload.new("triggerName" => name)
      refute p.auth_trigger?, "#{name} must not classify as auth"
      refute p.live_query_trigger?, "#{name} must not classify as live_query"
    end
  end

  # ==========================================================================
  # Reject-on-false: a `false` return from a before_* auth/LQ trigger denies.
  # (Parse Server only treats {error} as a rejection.)
  # ==========================================================================

  def test_before_login_false_raises_response_error
    Parse::Webhooks.route(:before_login, "_User") { |_p| false }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeLogin",
      "object" => { "className" => "_User", "username" => "alice" },
    )
    assert_raises(Parse::Webhooks::ResponseError) do
      Parse::Webhooks.call_route(:before_login, "_User", payload)
    end
  end

  def test_before_password_reset_request_false_raises
    Parse::Webhooks.route(:before_password_reset_request, "_User") { |_p| false }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforePasswordResetRequest",
      "object" => { "className" => "_User", "email" => "a@example.com" },
    )
    assert_raises(Parse::Webhooks::ResponseError) do
      Parse::Webhooks.call_route(:before_password_reset_request, "_User", payload)
    end
  end

  def test_before_connect_false_raises
    Parse::Webhooks.route(:before_connect, "@Connect") { |_p| false }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeConnect", "event" => "connect",
    )
    payload.instance_variable_set(:@webhook_class, "@Connect")
    assert_raises(Parse::Webhooks::ResponseError) do
      Parse::Webhooks.call_route(:before_connect, "@Connect", payload)
    end
  end

  def test_before_subscribe_false_raises
    Parse::Webhooks.route(:before_subscribe, "Post") { |_p| false }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSubscribe",
      "query" => { "where" => { "archived" => false } },
    )
    payload.instance_variable_set(:@webhook_class, "Post")
    assert_raises(Parse::Webhooks::ResponseError) do
      Parse::Webhooks.call_route(:before_subscribe, "Post", payload)
    end
  end

  def test_before_login_error_bang_raises_with_message
    Parse::Webhooks.route(:before_login, "_User") { |_p| error!("banned user") }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeLogin",
      "object" => { "className" => "_User", "username" => "mallory" },
    )
    err = assert_raises(Parse::Webhooks::ResponseError) do
      Parse::Webhooks.call_route(:before_login, "_User", payload)
    end
    assert_equal "banned user", err.message
  end

  # ==========================================================================
  # after_* are observe-only: false does NOT raise, result normalizes to true,
  # and a returned object is never serialized back.
  # ==========================================================================

  def test_after_login_false_does_not_raise_and_normalizes_true
    Parse::Webhooks.route(:after_login, "_User") { |_p| false }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "afterLogin",
      "object" => { "className" => "_User", "username" => "alice" },
    )
    result = Parse::Webhooks.call_route(:after_login, "_User", payload)
    assert_equal true, result, "after_login response is ignored; normalize to success"
  end

  def test_after_logout_normalizes_true
    Parse::Webhooks.route(:after_logout, "_Session") { |_p| nil }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "afterLogout",
      "object" => { "className" => "_Session", "objectId" => "s1" },
    )
    assert_equal true, Parse::Webhooks.call_route(:after_logout, "_Session", payload)
  end

  def test_after_event_returned_object_is_not_leaked_into_response
    # A handler that returns the parse_object (a Parse::Object) must NOT have
    # that object serialized back -- Parse Server ignores the body and we must
    # not leak it into the response/log. The result must normalize to `true`.
    Parse::Webhooks.route(:after_event, "Post") { |p| p.parse_object }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "afterEvent", "event" => "create",
      "object" => { "className" => "Post", "objectId" => "p1", "title" => "Hi" },
    )
    payload.instance_variable_set(:@webhook_class, "Post")
    result = Parse::Webhooks.call_route(:after_event, "Post", payload)
    assert_equal true, result
    refute_kind_of Parse::Object, result
  end

  def test_before_login_returned_object_is_normalized_true
    # Even a "before" auth trigger that returns the user object (not false)
    # must succeed with a no-op -- the object is never serialized back.
    Parse::Webhooks.route(:before_login, "_User") { |p| p.parse_object }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeLogin",
      "object" => { "className" => "_User", "username" => "alice" },
    )
    result = Parse::Webhooks.call_route(:before_login, "_User", payload)
    assert_equal true, result
    refute_kind_of Parse::Object, result
  end

  # ==========================================================================
  # No ActiveModel save/create/destroy callbacks fire for auth triggers, even
  # though they carry a _User / _Session object.
  # ==========================================================================

  def test_before_login_does_not_run_save_or_create_callbacks
    fired = []
    spy = Object.new
    spy.define_singleton_method(:is_a?) { |k| k == Parse::Object }
    spy.define_singleton_method(:run_before_save_callbacks)  { fired << :before_save; true }
    spy.define_singleton_method(:run_before_create_callbacks) { fired << :before_create; true }
    spy.define_singleton_method(:changes_payload) { { "x" => 1 } }

    Parse::Webhooks.route(:before_login, "_User") { |_p| spy }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeLogin",
      "object" => { "className" => "_User", "username" => "alice" },
    )
    payload.define_singleton_method(:parse_object) { spy }

    Parse::Webhooks.call_route(:before_login, "_User", payload)
    assert_empty fired, "beforeLogin must not run save/create ActiveModel callbacks"
  end

  def test_after_login_does_not_run_after_save_or_create_callbacks
    fired = []
    spy = Object.new
    spy.define_singleton_method(:is_a?) { |k| k == Parse::Object }
    spy.define_singleton_method(:run_after_save_callbacks)   { fired << :after_save; true }
    spy.define_singleton_method(:run_after_create_callbacks) { fired << :after_create; true }

    Parse::Webhooks.route(:after_login, "_User") { |_p| true }
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "afterLogin",
      "object" => { "className" => "_User", "username" => "alice" },
    )
    payload.define_singleton_method(:parse_object) { spy }

    Parse::Webhooks.call_route(:after_login, "_User", payload)
    assert_empty fired, "afterLogin must not run after_save/after_create callbacks"
  end

  # ==========================================================================
  # Accessors: event / clients / subscriptions, the beforeLogin user footgun,
  # beforeSubscribe query, and top-level session-token capture.
  # ==========================================================================

  def test_after_event_event_accessor
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "afterEvent", "event" => "update",
      "clients" => 3, "subscriptions" => 7,
      "object" => { "className" => "Post", "objectId" => "p1" },
    )
    assert_equal "update", payload.event
    assert_equal 3, payload.clients
    assert_equal 7, payload.subscriptions
  end

  def test_non_live_query_triggers_have_nil_event
    p = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSave",
      "object" => { "className" => "Post", "objectId" => "p1" },
    )
    assert_nil p.event
    assert_nil p.clients
    assert_nil p.subscriptions
  end

  def test_before_login_user_is_parse_object_not_user
    # The login footgun: the user being authenticated is the OBJECT, and
    # #user is nil (auth not complete yet).
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeLogin",
      "object" => { "className" => "_User", "objectId" => "u1", "username" => "alice" },
    )
    assert_nil payload.user, "beforeLogin carries no resolved #user"
    assert_equal "_User", payload.parse_class
    obj = payload.parse_object
    assert_kind_of Parse::User, obj
    assert_equal "alice", obj.username
  end

  def test_before_subscribe_parse_query
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSubscribe",
      "query" => { "where" => { "archived" => false } },
    )
    payload.instance_variable_set(:@webhook_class, "Post")
    assert_equal "Post", payload.parse_class
    q = payload.parse_query
    assert_kind_of Parse::Query, q
  end

  def test_before_connect_captures_top_level_session_token
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeConnect", "event" => "connect",
      "sessionToken" => "r:lq-token-123",
    )
    assert_equal "r:lq-token-123", payload.session_token
    assert payload.session_token?
  end

  def test_top_level_session_token_not_in_as_json
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeSubscribe",
      "sessionToken" => "r:secret-lq-token",
      "query" => { "where" => {} },
    )
    refute_includes payload.as_json.to_json, "secret-lq-token",
                    "top-level session token must never appear in #as_json"
  end

  def test_blank_top_level_session_token_is_nil
    payload = Parse::Webhooks::Payload.new(
      "triggerName" => "beforeConnect", "sessionToken" => "   ",
    )
    assert_nil payload.session_token
    refute payload.session_token?
  end

  # ==========================================================================
  # Path routing: trigger_class_from_path accepts the @-prefixed pseudo-classes.
  # ==========================================================================

  def test_trigger_class_from_path_accepts_connect_pseudo_class
    assert_equal "@Connect",
                 Parse::Webhooks.trigger_class_from_path("/webhooks/beforeConnect/@Connect")
  end

  def test_trigger_class_from_path_accepts_file_pseudo_class
    assert_equal "@File",
                 Parse::Webhooks.trigger_class_from_path("/webhooks/beforeSave/@File")
  end

  def test_trigger_class_from_path_still_rejects_garbage
    assert_nil Parse::Webhooks.trigger_class_from_path("/webhooks/beforeConnect/..%2fetc")
    assert_nil Parse::Webhooks.trigger_class_from_path("/webhooks/beforeConnect/@@bad")
  end

  # ==========================================================================
  # End-to-end through the Rack entry point (#call!): the seam where the regex
  # fix, the Payload `webhook_class:` constructor handling, and routing combine
  # on a RAW body — the actual production path.
  # ==========================================================================

  WEBHOOK_HEADER = "HTTP_X_PARSE_WEBHOOK_KEY"

  def with_rack_webhook_env
    saved_key = Parse::Webhooks.instance_variable_get(:@key)
    saved_allow = Parse::Webhooks.instance_variable_get(:@allow_unauthenticated)
    saved_logging = Parse::Webhooks.logging
    Parse::Webhooks.instance_variable_set(:@key, nil)
    Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, true)
    Parse::Webhooks.logging = false
    Parse::Webhooks::ReplayProtection.reset!
    capture_io { yield }
  ensure
    Parse::Webhooks.instance_variable_set(:@key, saved_key)
    Parse::Webhooks.instance_variable_set(:@allow_unauthenticated, saved_allow)
    Parse::Webhooks.logging = saved_logging
  end

  def rack_env(body:, path:)
    {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "PATH_INFO" => path,
      "rack.input" => StringIO.new(body),
      "CONTENT_LENGTH" => body.bytesize.to_s,
    }
  end

  def test_call_routes_a_raw_before_login_body
    fired = []
    Parse::Webhooks.route(:before_login, "_User") do |p|
      fired << p.parse_object.username
      true
    end
    body = JSON.generate(
      "triggerName" => "beforeLogin",
      "object" => { "className" => "_User", "username" => "alice" },
    )
    with_rack_webhook_env do
      status, _h, resp = Parse::Webhooks.call(
        rack_env(body: body, path: "/webhooks/beforeLogin/_User")
      )
      assert_equal 200, status
      assert_equal({ "success" => true }, JSON.parse(resp.join))
    end
    assert_equal ["alice"], fired, "the beforeLogin handler must fire via call!"
  end

  def test_call_routes_a_raw_before_connect_body_with_at_connect_path
    # The full seam: a raw beforeConnect body carries NO className; the class
    # is resolved from the @Connect path via the constructor's webhook_class:.
    # error! must surface as an {error} response (deny the connection).
    Parse::Webhooks.route(:before_connect, "@Connect") do |_p|
      error!("connection refused")
    end
    body = JSON.generate(
      "triggerName" => "beforeConnect", "event" => "connect",
      "sessionToken" => "r:lq-tok",
    )
    with_rack_webhook_env do
      status, _h, resp = Parse::Webhooks.call(
        rack_env(body: body, path: "/webhooks/beforeConnect/@Connect")
      )
      assert_equal 200, status
      assert_equal "connection refused", JSON.parse(resp.join)["error"]
    end
  end
end
