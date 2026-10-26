# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/live_query"

# `_User` / `_Session` LiveQuery payloads have `sessionToken` and `authData`
# removed before hydration and delivery. Defense in depth against Parse
# Server releases without the GHSA-349r fix, where an `$or` subscription
# could receive other users' `_User` / `_Session` events with their tokens.
class TestLiveQueryCredentialScrub < Minitest::Test
  USER_PAYLOAD = {
    "className" => "_User",
    "objectId" => "u1",
    "username" => "other",
    "sessionToken" => "r:stolen",
    "authData" => { "github" => { "id" => "1", "access_token" => "gho_x" } },
    "_auth_data_github" => { "id" => "1" },
  }.freeze

  SESSION_PAYLOAD = {
    "className" => "_Session",
    "objectId" => "s1",
    "sessionToken" => "r:stolen",
    "user" => { "__type" => "Pointer", "className" => "_User", "objectId" => "u1" },
  }.freeze

  def test_scrub_removes_user_credentials
    out = Parse::LiveQuery::Event.scrub_credentials(USER_PAYLOAD)
    refute out.key?("sessionToken")
    refute out.key?("authData")
    refute out.key?("_auth_data_github")
    assert_equal "other", out["username"]
    assert USER_PAYLOAD.key?("sessionToken"), "input must not be mutated"
  end

  def test_scrub_uses_subscription_class_when_payload_has_no_class
    data = { "objectId" => "s1", "sessionToken" => "r:x" }
    refute Parse::LiveQuery::Event.scrub_credentials(data, "_Session").key?("sessionToken")
  end

  def test_other_classes_untouched
    data = { "className" => "Post", "objectId" => "p1", "sessionToken" => "kept" }
    assert_equal data, Parse::LiveQuery::Event.scrub_credentials(data, "Post")
  end

  def test_event_object_original_and_raw_scrubbed
    message = { "op" => "update", "requestId" => 1, "object" => USER_PAYLOAD.dup, "original" => USER_PAYLOAD.dup }
    event = Parse::LiveQuery::Event.new(
      type: :update, class_name: "_User", object_data: message["object"],
      original_data: message["original"], request_id: 1, raw: message,
    )
    assert_nil event.object.session_token if event.object.respond_to?(:session_token)
    refute event.object.as_json.to_s.include?("r:stolen")
    refute event.original.as_json.to_s.include?("r:stolen")
    refute event.raw["object"].key?("sessionToken")
    refute event.raw["original"].key?("authData")
    refute event.to_h.to_s.include?("gho_x")
  end

  def test_session_event_scrubbed
    event = Parse::LiveQuery::Event.new(
      type: :create, class_name: "_Session", object_data: SESSION_PAYLOAD.dup, request_id: 2,
      raw: { "object" => SESSION_PAYLOAD.dup },
    )
    refute event.to_h.to_s.include?("r:stolen")
    refute event.raw.to_s.include?("r:stolen")
  end

  class RecordingQueue
    attr_reader :items
    def initialize; @items = []; end
    def enqueue(item); @items << item; end
  end

  def test_client_handle_event_scrubs_before_enqueue
    client = Parse::LiveQuery::Client.new(
      url: "wss://test.example.com", application_id: "app", client_key: "key", auto_connect: false,
    )
    queue = RecordingQueue.new
    client.instance_variable_set(:@event_queue, queue)
    sub = Struct.new(:class_name).new("_User")
    client.instance_variable_get(:@subscriptions)[7] = sub
    message = { "op" => "create", "requestId" => 7, "object" => USER_PAYLOAD.dup }
    client.send(:handle_event, "create", message)
    event = queue.items.first[:event]
    refute event.raw.to_s.include?("r:stolen")
    refute event.to_h.to_s.include?("r:stolen")
  ensure
    Parse::LiveQuery.reset! if Parse::LiveQuery.respond_to?(:reset!)
  end
end
