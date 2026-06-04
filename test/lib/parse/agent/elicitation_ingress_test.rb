# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"
require "parse/agent/mcp_rack_app"
require "stringio"
require "json"

# Rack-level tests for the elicitation transport wiring in MCPRackApp:
# client-capability capture at initialize, and the method-less
# JSON-RPC response ingress that routes a client's reply into the
# pending-elicitation registry (session-bound). In-process, no socket.
class ElicitationIngressTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @app = Parse::Agent::MCPRackApp.new(
      streaming: true, resource_subscriptions: true,
      agent_factory: ->(_env) { Parse::Agent.new(permissions: :admin) },
    )
    @pending = @app.instance_variable_get(:@pending_elicitations)
    @caps = @app.instance_variable_get(:@elicitation_capabilities)
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

  # ----- capability capture -----

  def test_initialize_captures_elicitation_capability
    sid = "sess-cap-1"
    status, _h, body = post({
      "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
      "params" => { "protocolVersion" => "2025-06-18", "capabilities" => { "elicitation" => {} } },
    }, session_id: sid)
    assert_equal 200, status
    assert_equal true, @caps.get(sid)
    # Server must NOT advertise elicitation in its own capabilities.
    result = JSON.parse(body.join)["result"]
    refute result["capabilities"].key?("elicitation")
  end

  def test_initialize_without_elicitation_records_false
    sid = "sess-cap-2"
    post({
      "jsonrpc" => "2.0", "id" => 1, "method" => "initialize",
      "params" => { "protocolVersion" => "2025-06-18", "capabilities" => {} },
    }, session_id: sid)
    assert_equal false, @caps.get(sid)
  end

  # ----- reply ingress -----

  def test_reply_routes_into_pending_registry
    sid = "sess-reply-1"
    queue = @pending.register(sid, "elic-1")
    status, _h, _b = post({
      "jsonrpc" => "2.0", "id" => "elic-1", "result" => { "action" => "accept" },
    }, session_id: sid)
    assert_equal 202, status
    assert_equal :accept, queue.pop(timeout: 1)
    assert_equal 0, @pending.size
  end

  def test_decline_reply_maps_to_decline
    sid = "sess-reply-2"
    queue = @pending.register(sid, "elic-2")
    post({ "jsonrpc" => "2.0", "id" => "elic-2", "result" => { "action" => "decline" } }, session_id: sid)
    assert_equal :decline, queue.pop(timeout: 1)
  end

  def test_accept_with_approve_false_maps_to_decline
    sid = "sess-reply-3"
    queue = @pending.register(sid, "elic-3")
    post({
      "jsonrpc" => "2.0", "id" => "elic-3",
      "result" => { "action" => "accept", "content" => { "approve" => false } },
    }, session_id: sid)
    assert_equal :decline, queue.pop(timeout: 1)
  end

  def test_error_reply_maps_to_cancel
    sid = "sess-reply-4"
    queue = @pending.register(sid, "elic-4")
    post({
      "jsonrpc" => "2.0", "id" => "elic-4", "error" => { "code" => -1, "message" => "user closed" },
    }, session_id: sid)
    assert_equal :cancel, queue.pop(timeout: 1)
  end

  def test_cross_session_reply_does_not_deliver
    @pending.register("S1", "elic-x")
    status, _h, _b = post({
      "jsonrpc" => "2.0", "id" => "elic-x", "result" => { "action" => "accept" },
    }, session_id: "S2")
    assert_equal 202, status, "still acks to avoid a probe oracle"
    assert_equal 1, @pending.size, "S1's pending entry must remain (S2 cannot answer it)"
  end

  def test_unknown_id_reply_is_silent_noop
    status, _h, _b = post({
      "jsonrpc" => "2.0", "id" => "no-such-elic", "result" => { "action" => "accept" },
    }, session_id: "sess-unknown")
    assert_equal 202, status
    assert_equal 0, @pending.size
  end

  def test_malformed_methodless_body_still_rejected
    # A method-less body with neither result nor error is NOT an
    # elicitation reply — it must still hit the -32600 guard.
    status, _h, body = post({ "jsonrpc" => "2.0", "id" => 7 }, session_id: "sess-bad")
    assert_equal 400, status
    assert_equal(-32_600, JSON.parse(body.join)["error"]["code"])
  end
end
