# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"
require "parse/agent/mcp_rack_app"
require "stringio"
require "json"

# Tests the general-purpose server-initiated notification stream: the
# `notifications: true` mode that opens the GET listening-stream bus
# without enabling LiveQuery resource subscriptions, and the public
# MCPRackApp#notify front door.
class MCPNotificationsTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @app = Parse::Agent::MCPRackApp.new(
      streaming: true, notifications: true,
      agent_factory: ->(_env) { Parse::Agent.new(permissions: :readonly) },
    )
  end

  def rack_env(body:, session_id: nil, method: "POST")
    env = {
      "REQUEST_METHOD" => method,
      "CONTENT_TYPE"   => "application/json",
      "rack.input"     => StringIO.new(body),
    }
    env["HTTP_MCP_SESSION_ID"] = session_id if session_id
    env
  end

  def post(body_hash, session_id: nil)
    @app.call(rack_env(body: JSON.generate(body_hash), session_id: session_id))
  end

  def test_notifications_mode_builds_a_manager
    refute_nil @app.subscription_manager
  end

  def test_notify_raises_on_blank_method
    assert_raises(ArgumentError) { @app.notify("s1", method: "") }
    assert_raises(ArgumentError) { @app.notify("s1", method: nil) }
  end

  def test_notify_returns_false_when_no_listener
    assert_equal false, @app.notify("no-stream", method: "notifications/custom")
  end

  def test_notify_delivers_notification_to_listener
    received = []
    @app.subscription_manager.attach_listener("s1") { |msg| received << msg }
    ok = @app.notify("s1", method: "notifications/custom", params: { "foo" => 1 })
    assert_equal true, ok
    assert_equal 1, received.length
    env = received.first
    assert_equal "2.0", env["jsonrpc"]
    assert_equal "notifications/custom", env["method"]
    assert_equal({ "foo" => 1 }, env["params"])
    refute env.key?("id"), "a notification must not carry an id"
  end

  def test_notify_omits_params_when_nil
    received = []
    @app.subscription_manager.attach_listener("s2") { |msg| received << msg }
    @app.notify("s2", method: "notifications/ping")
    refute received.first.key?("params")
  end

  def test_notify_false_when_notifications_disabled
    app = Parse::Agent::MCPRackApp.new(agent_factory: ->(_e) { Parse::Agent.new })
    assert_nil app.subscription_manager
    assert_equal false, app.notify("s1", method: "notifications/custom")
  end

  def test_initialize_does_not_advertise_resource_subscribe
    _status, _h, body = post({
      "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
      "params" => { "protocolVersion" => "2025-06-18", "capabilities" => {} },
    }, session_id: "cap-sess")
    caps = JSON.parse(body.join)["result"]["capabilities"]
    # notifications-only mode must not claim resources.subscribe.
    refute(caps.dig("resources", "subscribe"),
           "notifications mode must not advertise resources.subscribe")
  end

  def test_resource_subscribe_fails_closed_in_notifications_mode
    status, _h, body = post({
      "jsonrpc" => "2.0", "id" => 2, "method" => "resources/subscribe",
      "params" => { "uri" => "parse://Post/count" },
    }, session_id: "sub-sess")
    assert_equal 200, status
    parsed = JSON.parse(body.join)
    assert parsed.key?("error"), "subscribe must fail closed when subscriptions unsupported"
  end
end
