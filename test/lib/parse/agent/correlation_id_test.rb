# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_rack_app"

# ============================================================================
# Tests for audit-trail correlation id threading. A client-supplied
# X-MCP-Session-Id header (or a value set directly on the agent) flows into
# every parse.agent.tool_call notification under :correlation_id so a
# downstream log subscriber can attribute multiple tool calls to one
# logical conversation.
# ============================================================================
class CorrelationIdTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @agent = Parse::Agent.new(permissions: :readonly)
    @events = []
    @subscriber = ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |*args|
      e = ActiveSupport::Notifications::Event.new(*args)
      @events << e.payload.dup
    end
  end

  def teardown
    ActiveSupport::Notifications.unsubscribe(@subscriber)
  end

  # ---- Setter validation ------------------------------------------------

  def test_setter_accepts_safe_characters
    @agent.correlation_id = "session-abc.123_XYZ"
    assert_equal "session-abc.123_XYZ", @agent.correlation_id
  end

  def test_setter_rejects_unsafe_characters
    @agent.correlation_id = "ok-value"
    @agent.correlation_id = "evil\nLOG INJECTION line"
    # Silent reject — previous value preserved.
    assert_equal "ok-value", @agent.correlation_id
  end

  def test_setter_rejects_shell_metacharacters
    @agent.correlation_id = nil
    @agent.correlation_id = "$(rm -rf /)"
    assert_nil @agent.correlation_id
  end

  def test_setter_truncates_to_128_characters
    @agent.correlation_id = "x" * 200
    assert_equal 128, @agent.correlation_id.length
  end

  def test_setter_clears_with_nil_or_empty
    @agent.correlation_id = "abc"
    @agent.correlation_id = nil
    assert_nil @agent.correlation_id

    @agent.correlation_id = "def"
    @agent.correlation_id = ""
    assert_nil @agent.correlation_id
  end

  # ---- Notification payload ---------------------------------------------

  def test_correlation_id_included_in_notification_when_set
    @agent.correlation_id = "session-42"
    # Stub the client so execute doesn't actually hit Parse Server.
    fake_client = Object.new
    fake_client.define_singleton_method(:find_objects) do |_c, _q, **_opts|
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:count)    { 7 }
      r.define_singleton_method(:results)  { [] }
      r
    end
    @agent.define_singleton_method(:client) { fake_client }

    @agent.execute(:count_objects, class_name: "Anything")

    assert_equal 1, @events.size
    assert_equal "session-42", @events.first[:correlation_id]
  end

  def test_correlation_id_omitted_from_payload_when_unset
    fake_client = Object.new
    fake_client.define_singleton_method(:find_objects) do |_c, _q, **_opts|
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:count)    { 0 }
      r.define_singleton_method(:results)  { [] }
      r
    end
    @agent.define_singleton_method(:client) { fake_client }

    @agent.execute(:count_objects, class_name: "Anything")

    assert_equal 1, @events.size
    refute @events.first.key?(:correlation_id),
           "correlation_id key should not appear when unset"
  end

  # ---- MCPRackApp wiring -----------------------------------------------

  def test_rack_app_reads_x_mcp_session_id_header
    captured_agent = nil
    factory = ->(_env) {
      captured_agent = Parse::Agent.new(permissions: :readonly)
      # Make execute a no-op so we don't need a Parse server.
      captured_agent.define_singleton_method(:execute) do |*_, **_|
        { success: true, data: { ok: true } }
      end
      captured_agent.define_singleton_method(:tool_definitions) { |**_| [] }
      captured_agent
    }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory)

    env = {
      "REQUEST_METHOD"          => "POST",
      "CONTENT_TYPE"            => "application/json",
      "HTTP_X_MCP_SESSION_ID"   => "client-conv-7",
      "rack.input"              => StringIO.new(JSON.generate(
                                     jsonrpc: "2.0", id: 1,
                                     method: "tools/list",
                                   )),
    }
    app.call(env)

    refute_nil captured_agent
    assert_equal "client-conv-7", captured_agent.correlation_id
  end

  def test_rack_app_does_not_overwrite_factory_set_id
    captured_agent = nil
    factory = ->(_env) {
      captured_agent = Parse::Agent.new(permissions: :readonly)
      captured_agent.correlation_id = "factory-binds-this"
      captured_agent.define_singleton_method(:execute) { |*_, **_| { success: true, data: {} } }
      captured_agent.define_singleton_method(:tool_definitions) { |**_| [] }
      captured_agent
    }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory)

    env = {
      "REQUEST_METHOD"        => "POST",
      "CONTENT_TYPE"          => "application/json",
      "HTTP_X_MCP_SESSION_ID" => "client-tried-to-spoof",
      "rack.input"            => StringIO.new(JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list")),
    }
    app.call(env)

    assert_equal "factory-binds-this", captured_agent.correlation_id,
                 "factory-set correlation_id must not be overwritten by header"
  end

  def test_rack_app_silently_drops_malicious_header_value
    captured_agent = nil
    factory = ->(_env) {
      captured_agent = Parse::Agent.new(permissions: :readonly)
      captured_agent.define_singleton_method(:execute) { |*_, **_| { success: true, data: {} } }
      captured_agent.define_singleton_method(:tool_definitions) { |**_| [] }
      captured_agent
    }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory)

    env = {
      "REQUEST_METHOD"        => "POST",
      "CONTENT_TYPE"          => "application/json",
      "HTTP_X_MCP_SESSION_ID" => "evil\nLOG-INJECTION",
      "rack.input"            => StringIO.new(JSON.generate(jsonrpc: "2.0", id: 1, method: "tools/list")),
    }
    app.call(env)

    assert_nil captured_agent.correlation_id, "log-injection header must be dropped"
  end
end
