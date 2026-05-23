# encoding: UTF-8
# frozen_string_literal: true

# Test 2: Tools.register end-to-end through MCPRackApp against a real Parse Server.
#
# Exercises the registered-handler path specifically — custom tools that do
# real Parse work, permission filtering, same-name replacement, error
# propagation, and AS::Notifications instrumentation.
#
# All tests are gated on PARSE_TEST_USE_DOCKER=true.

require_relative "../../../test_helper_integration"
require "json"
require "stringio"
require "active_support/notifications"

require "parse/agent"
require "parse/agent/mcp_rack_app"
require "parse/agent/mcp_dispatcher"

# ---------------------------------------------------------------------------
# Test fixture model
# ---------------------------------------------------------------------------
class MCPRegisteredItem < Parse::Object
  parse_class "MCPRegisteredItem"
  property :name, :string
  property :category, :string
end

# ---------------------------------------------------------------------------
# Main test class
# ---------------------------------------------------------------------------
class ToolsRegisterE2EIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  T = Parse::Agent::Tools

  # -------------------------------------------------------------------------
  # Helper: build a Rack env and call MCPRackApp, return [status, body_hash]
  # -------------------------------------------------------------------------

  def rack_post(method, params = {}, id: 1, permissions: :readonly)
    body = JSON.generate({
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params,
    })
    env = {
      "REQUEST_METHOD" => "POST",
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new(body),
      "rack.errors" => $stderr,
    }

    factory = ->(_env) { Parse::Agent.new(permissions: permissions) }
    app = Parse::Agent::MCPRackApp.new(agent_factory: factory)
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.join)]
  end

  # =========================================================================
  # 1. Register a custom tool that does real Parse work
  # =========================================================================

  def test_registered_tool_executes_real_parse_query
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    items = []
    with_parse_server do
      3.times do
        item = MCPRegisteredItem.new(name: "alpha", category: "test")
        item.save
        items << item
      end

      T.register(
        name: :count_items_by_name,
        description: "Count MCPRegisteredItems by name",
        parameters: {
          type: "object",
          properties: { name: { type: "string" } },
          required: ["name"],
        },
        permission: :readonly,
        handler: ->(_agent, name:, **) {
          count = MCPRegisteredItem.query(name: name).count
          { count: count, name: name }
        },
      )

      status, body = rack_post("tools/call", {
        "name" => "count_items_by_name",
        "arguments" => { "name" => "alpha" },
      })

      assert_equal 200, status
      result = body["result"]
      assert result, "Must have result key"
      refute result["isError"], "count_items_by_name should not error: #{result.inspect}"
      text = result["content"].first["text"]
      data = JSON.parse(text)
      assert_operator data["count"].to_i, :>=, 3,
                      "Should count at least 3 'alpha' items, got: #{data.inspect}"
    end
  ensure
    items.each { |i| i.destroy rescue nil }
    T.reset_registry!
  end

  # =========================================================================
  # 2. Permission filtering — :write tool invisible to :readonly agent
  # =========================================================================

  def test_write_tool_filtered_out_of_readonly_tools_list
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      T.register(
        name: :admin_delete_items,
        description: "Delete all items (write-level)",
        parameters: { type: "object", properties: {}, required: [] },
        permission: :write,
        handler: ->(_agent, **) { { deleted: 0 } },
      )

      _status, body = rack_post("tools/list", {}, permissions: :readonly)
      tool_names = body["result"]["tools"].map { |t| t["name"] }
      refute_includes tool_names, "admin_delete_items",
                      "write-level tool must not appear in readonly tools/list"
    end
  ensure
    T.reset_registry!
  end

  def test_write_tool_visible_to_write_agent
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      T.register(
        name: :write_level_tool,
        description: "A write-level tool",
        parameters: { type: "object", properties: {}, required: [] },
        permission: :write,
        handler: ->(_agent, **) { { result: "done" } },
      )

      _status, body = rack_post("tools/list", {}, permissions: :write)
      tool_names = body["result"]["tools"].map { |t| t["name"] }
      assert_includes tool_names, "write_level_tool",
                      "write-level tool must appear in write agent tools/list"
    end
  ensure
    T.reset_registry!
  end

  # =========================================================================
  # 3. Same-name replacement — second registration wins
  # =========================================================================

  def test_same_name_replacement_invokes_second_handler
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      T.register(
        name: :replaceable_tool,
        description: "First version",
        parameters: { type: "object", properties: {}, required: [] },
        permission: :readonly,
        handler: ->(_agent, **) { { result: "first" } },
      )

      T.register(
        name: :replaceable_tool,
        description: "Second version",
        parameters: { type: "object", properties: {}, required: [] },
        permission: :readonly,
        handler: ->(_agent, **) { { result: "second" } },
      )

      status, body = rack_post("tools/call", {
        "name" => "replaceable_tool",
        "arguments" => {},
      })

      assert_equal 200, status
      result = body["result"]
      refute result["isError"], "replaceable_tool should not error"
      text = result["content"].first["text"]
      data = JSON.parse(text)
      assert_equal "second", data["result"],
                   "Second handler should win after same-name replacement"
    end
  ensure
    T.reset_registry!
  end

  # =========================================================================
  # 4. Handler error propagation — isError: true, no class name leakage
  # =========================================================================

  def test_handler_error_surfaces_as_is_error_true
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      T.register(
        name: :failing_tool,
        description: "Always raises",
        parameters: { type: "object", properties: {}, required: [] },
        permission: :readonly,
        handler: ->(_agent, **) { raise "something went wrong internally" },
      )

      status, body = rack_post("tools/call", {
        "name" => "failing_tool",
        "arguments" => {},
      })

      assert_equal 200, status
      result = body["result"]
      assert result["isError"], "failing handler should produce isError: true"
      content_text = result["content"].first["text"].to_s
      refute_match(/RuntimeError/, content_text,
                   "Class name RuntimeError must not leak into MCP content")
    end
  ensure
    T.reset_registry!
  end

  # =========================================================================
  # 5. AS::Notifications — registered tool fires parse.agent.tool_call
  # =========================================================================

  def test_registered_tool_fires_notifications_event
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    events = []
    mutex = Mutex.new
    subscriber = nil

    with_parse_server do
      subscriber = ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |event|
        mutex.synchronize { events << event }
      end

      T.register(
        name: :observable_tool,
        description: "Observable tool for notification test",
        parameters: { type: "object", properties: {}, required: [] },
        permission: :readonly,
        handler: ->(_agent, **) { { result: "observed" } },
      )

      agent = Parse::Agent.new(permissions: :readonly)
      result = agent.execute(:observable_tool)
      assert result[:success], "observable_tool should succeed"

      matching = events.select { |e| e.payload[:tool] == :observable_tool }
      assert_operator matching.size, :>=, 1,
                      "Should have fired at least one notification for :observable_tool"

      event = matching.first
      assert_equal :observable_tool, event.payload[:tool]
      assert event.payload[:success], "notification payload should mark success"
    end
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    T.reset_registry!
  end

  # =========================================================================
  # 6. reset_registry! clears all custom registrations
  # =========================================================================

  def test_reset_registry_removes_all_custom_tools
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      T.register(
        name: :temp_e2e_tool,
        description: "Temporary tool",
        parameters: { type: "object", properties: {}, required: [] },
        permission: :readonly,
        handler: ->(_agent, **) { { result: "ok" } },
      )

      assert_includes T.all_tool_names, :temp_e2e_tool, "Should be registered before reset"

      T.reset_registry!

      refute_includes T.all_tool_names, :temp_e2e_tool, "Should be gone after reset"
      assert_includes T.all_tool_names, :get_all_schemas
      assert_includes T.all_tool_names, :query_class
    end
  ensure
    T.reset_registry!
  end

  # =========================================================================
  # 7. Registered tool with real count appears in tools/list definitions
  # =========================================================================

  def test_registered_tool_descriptor_appears_in_mcp_tools_list
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      T.register(
        name: :my_count_tool,
        description: "Count items matching a filter",
        parameters: {
          type: "object",
          properties: { category: { type: "string" } },
          required: [],
        },
        permission: :readonly,
        handler: ->(_agent, category: nil, **) {
          q = MCPRegisteredItem.query
          q = q.where(category: category) if category
          { count: q.count }
        },
      )

      _status, body = rack_post("tools/list")
      tools = body["result"]["tools"]
      tool = tools.find { |t| t["name"] == "my_count_tool" }
      assert tool, "my_count_tool must appear in tools/list"
      assert_equal "Count items matching a filter", tool["description"]
      assert tool.key?("inputSchema"), "tool descriptor must have inputSchema"
    end
  ensure
    T.reset_registry!
  end

  # =========================================================================
  # 8. Readonly agent cannot call a :write tool even via rack_post
  # =========================================================================

  def test_readonly_agent_permission_denied_for_write_tool_call
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      T.register(
        name: :write_only_action,
        description: "Write-only action",
        parameters: { type: "object", properties: {}, required: [] },
        permission: :write,
        handler: ->(_agent, **) { { done: true } },
      )

      agent = Parse::Agent.new(permissions: :readonly)
      result = agent.execute(:write_only_action)
      refute result[:success], "Readonly agent should not be allowed to execute :write tool"
      assert_equal :permission_denied, result[:error_code]
    end
  ensure
    T.reset_registry!
  end

  # =========================================================================
  # 9. Multiple custom tools coexist without interfering
  # =========================================================================

  def test_multiple_custom_tools_coexist
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      5.times do |i|
        T.register(
          name: :"custom_multi_#{i}",
          description: "Tool #{i}",
          parameters: { type: "object", properties: {}, required: [] },
          permission: :readonly,
          handler: ->(_agent, **) { { index: i } },
        )
      end

      all_names = T.all_tool_names
      5.times do |i|
        assert_includes all_names, :"custom_multi_#{i}"
      end
    end
  ensure
    T.reset_registry!
  end

  # =========================================================================
  # 10. Registered tool timeout is resolved correctly
  # =========================================================================

  def test_registered_tool_timeout_override
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      T.register(
        name: :slow_custom_tool,
        description: "A tool with a custom timeout",
        parameters: { type: "object", properties: {}, required: [] },
        permission: :readonly,
        timeout: 45,
        handler: ->(_agent, **) { { result: "done" } },
      )

      assert_equal 45, T.timeout_for(:slow_custom_tool),
                   "registered timeout should override the default"
    end
  ensure
    T.reset_registry!
  end
end
