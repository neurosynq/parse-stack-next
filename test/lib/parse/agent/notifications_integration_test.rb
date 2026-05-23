# encoding: UTF-8
# frozen_string_literal: true

# Test 4: AS::Notifications cross-feature integration.
#
# Subscribes to parse.agent.tool_call, fires built-in tools, registered tools,
# and error paths against a real Parse Server, and verifies the notification
# payload shape end-to-end.
#
# All tests are gated on PARSE_TEST_USE_DOCKER=true.
#
# NOTE on duration_ms:
# ActiveSupport::Notifications does NOT put duration into the payload Hash.
# Duration is available on the AS::Notifications::Event object returned by the
# 5-argument subscriber form (name, start, finish, id, payload).  When using
# the 1-argument block form (event), call event.duration.  Tests here use the
# 5-arg subscriber form to capture start/finish for duration assertions.

require_relative "../../../test_helper_integration"
require "active_support/notifications"
require "timeout"
require "securerandom"

require "parse/agent"

# ---------------------------------------------------------------------------
# Fixture model
# ---------------------------------------------------------------------------
class MCPNotificationItem < Parse::Object
  parse_class "MCPNotificationItem"
  property :label, :string
  property :count, :integer, default: 0
end

# ---------------------------------------------------------------------------
# Helper: a subscriber that captures AS::Notifications event payloads.
# Using the 5-argument form so we also capture start+finish for duration.
# ---------------------------------------------------------------------------
class NotifCollector
  attr_reader :events, :mutex

  Event = Struct.new(:name, :start, :finish, :id, :payload, keyword_init: true) do
    def duration_ms
      ((finish - start) * 1000.0).round(2)
    end
  end

  def initialize
    @events = []
    @mutex  = Mutex.new
    @subscriber = nil
  end

  def subscribe!
    @subscriber = ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |name, start, finish, id, payload|
      evt = Event.new(name: name, start: start, finish: finish, id: id, payload: payload)
      @mutex.synchronize { @events << evt }
    end
  end

  def unsubscribe!
    ActiveSupport::Notifications.unsubscribe(@subscriber) if @subscriber
    @subscriber = nil
  end

  def events_for(tool_sym)
    @mutex.synchronize { @events.select { |e| e.payload[:tool] == tool_sym } }
  end

  def all_events
    @mutex.synchronize { @events.dup }
  end

  def clear!
    @mutex.synchronize { @events.clear }
  end
end

# ---------------------------------------------------------------------------
# Main test class
# ---------------------------------------------------------------------------
class NotificationsIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  # -------------------------------------------------------------------------
  # Block helper: sets up a NotifCollector, subscribes it, yields, then
  # unsubscribes in ensure.  Caller is responsible for items cleanup.
  # -------------------------------------------------------------------------
  def with_notif_collector
    collector = NotifCollector.new
    Parse::Agent::Tools.reset_registry!
    Parse::Agent.refuse_collscan = false
    Parse::Agent.expose_explain  = false
    collector.subscribe!
    yield collector
  ensure
    collector.unsubscribe!
    Parse::Agent::Tools.reset_registry!
    Parse::Agent.refuse_collscan = false
    Parse::Agent.expose_explain  = false
  end

  # =========================================================================
  # 1. get_all_schemas success — full payload shape
  # =========================================================================

  def test_get_all_schemas_fires_notification_with_correct_payload
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_notif_collector do |collector|
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:get_all_schemas)
        assert result[:success], "get_all_schemas should succeed: #{result[:error]}"

        events = collector.events_for(:get_all_schemas)
        assert_operator events.size, :>=, 1,
                        "Should have at least one notification for get_all_schemas"

        evt = events.last
        p = evt.payload

        assert_equal :get_all_schemas, p[:tool]
        assert_equal true, p[:success]
        assert p[:auth_type], "auth_type must be present"
        assert_includes [:master_key, :session_token], p[:auth_type]
        assert p.key?(:using_master_key), "using_master_key must be present"
        assert_equal :readonly, p[:permissions]
        assert p[:result_size].is_a?(Integer) && p[:result_size] > 0,
               "result_size should be a positive Integer"
      end
    end
  end

  def test_get_all_schemas_notification_duration_is_positive
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_notif_collector do |collector|
        agent = Parse::Agent.new(permissions: :readonly)
        agent.execute(:get_all_schemas)
        events = collector.events_for(:get_all_schemas)
        assert events.size >= 1
        assert events.last.duration_ms > 0, "duration_ms should be positive"
      end
    end
  end

  # =========================================================================
  # 2. query_class — args_keys filters out :where but keeps :class_name
  # =========================================================================

  def test_query_class_args_keys_strips_sensitive_keys
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    items = []
    with_parse_server do
      item = MCPNotificationItem.new(label: "notif_test_#{SecureRandom.hex(3)}")
      item.save
      items << item

      with_notif_collector do |collector|
        agent = Parse::Agent.new(permissions: :readonly)
        agent.execute(:query_class,
          class_name: "MCPNotificationItem",
          where: { "label" => item.label },
          limit: 1,
        )

        events = collector.events_for(:query_class)
        assert events.size >= 1

        p = events.last.payload
        args_keys = p[:args_keys]

        refute_includes args_keys, :where,
                        ":where must not appear in args_keys (sensitive)"
        assert_includes args_keys, :class_name,
                        ":class_name must appear in args_keys"
        assert_includes args_keys, :limit,
                        ":limit must appear in args_keys"
      end
    end
  ensure
    items.each { |i| i.destroy rescue nil }
  end

  def test_query_class_args_keys_does_not_contain_other_sensitive_keys
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_notif_collector do |collector|
        agent = Parse::Agent.new(permissions: :readonly)
        agent.execute(:query_class,
          class_name: "MCPNotificationItem",
          limit: 1,
        )
        events = collector.events_for(:query_class)
        assert events.size >= 1

        sensitive = Parse::Agent::SENSITIVE_LOG_KEYS
        p = events.last.payload
        intersection = p[:args_keys] & sensitive.map(&:to_sym)
        assert intersection.empty?,
               "args_keys should not contain any SENSITIVE_LOG_KEYS; found: #{intersection.inspect}"
      end
    end
  end

  # =========================================================================
  # 3. Registered tool fires notification with correct :tool name
  # =========================================================================

  def test_registered_tool_notification_fires_with_correct_tool_name
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_notif_collector do |collector|
        Parse::Agent::Tools.register(
          name: :count_notification_items,
          description: "Count MCPNotificationItems",
          parameters: { type: "object", properties: {}, required: [] },
          permission: :readonly,
          handler: ->(_agent, **) {
            { count: MCPNotificationItem.query.count }
          },
        )

        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:count_notification_items)
        assert result[:success], "Registered tool should succeed"

        events = collector.events_for(:count_notification_items)
        assert events.size >= 1, "Should have fired notification for :count_notification_items"
        assert_equal :count_notification_items, events.last.payload[:tool]
        assert_equal true, events.last.payload[:success]
      end
    end
  end

  # =========================================================================
  # 4. Error path — nonexistent class returns :parse_error notification
  # =========================================================================

  def test_nonexistent_class_query_fires_error_notification
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_notif_collector do |collector|
        # Parse Server returns an empty array (not an error) for queries
        # against a class that has never been written to, so a name that
        # is structurally valid but never used does not trigger a failure
        # notification. Use a name that fails the agent's class_name
        # validation instead — that's the equivalent "unknown class"
        # surface in 4.x and still exercises the error-notification path.
        invalid_name = "Not A Valid Class Name"
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:query_class, class_name: invalid_name, limit: 1)

        refute result[:success], "Query with invalid class name should fail"

        events = collector.events_for(:query_class)
        error_events = events.select { |e| e.payload[:success] == false }
        assert error_events.size >= 1, "Should have at least one error notification"

        p = error_events.last.payload
        assert_equal false, p[:success]
        assert p[:error_class], "error_class must be set on failure"
        assert p[:error_code], "error_code must be set on failure"
      end
    end
  end

  # =========================================================================
  # 5. Security error — blocked pipeline operator fires notification
  # =========================================================================

  def test_security_error_pipeline_fires_notification_and_is_re_raised
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    items = []
    with_parse_server do
      item = MCPNotificationItem.new(label: "sec_test")
      item.save
      items << item

      with_notif_collector do |collector|
        assert_raises(Parse::Agent::PipelineValidator::PipelineSecurityError) do
          agent = Parse::Agent.new(permissions: :readonly)
          agent.execute(:aggregate,
            class_name: "MCPNotificationItem",
            pipeline: [{ "$out" => "hacked_collection" }],
          )
        end

        events = collector.events_for(:aggregate)
        security_events = events.select { |e| e.payload[:success] == false }
        assert security_events.size >= 1,
               "Security error should still fire a notification"

        p = security_events.last.payload
        assert_equal false, p[:success]
        assert_equal :security_blocked, p[:error_code]
        assert p[:error_class].is_a?(String), "error_class must be a String"
        assert_match(/Security/, p[:error_class],
                     "error_class should indicate a security-related exception")
      end
    end
  ensure
    items.each { |i| i.destroy rescue nil }
  end

  # =========================================================================
  # 6. Concurrent calls — all notifications arrive with correct :tool and duration
  # =========================================================================

  def test_concurrent_calls_all_fire_notifications
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    thread_count = 5

    with_parse_server do
      with_notif_collector do |collector|
        threads = thread_count.times.map do
          Thread.new do
            a = Parse::Agent.new(permissions: :readonly)
            a.execute(:get_all_schemas)
          end
        end
        threads.each(&:join)

        events = collector.events_for(:get_all_schemas)
        assert_operator events.size, :>=, thread_count,
                        "All #{thread_count} concurrent calls should fire notifications; got #{events.size}"

        events.each do |evt|
          assert evt.duration_ms >= 0, "Each event must have non-negative duration_ms"
          assert_equal :get_all_schemas, evt.payload[:tool]
        end
      end
    end
  end

  # =========================================================================
  # 7. Master key agent has correct auth metadata in notification
  # =========================================================================

  def test_master_key_agent_auth_metadata_in_notification
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_notif_collector do |collector|
        agent = Parse::Agent.new(permissions: :readonly)
        agent.execute(:get_all_schemas)

        events = collector.events_for(:get_all_schemas)
        assert events.size >= 1
        p = events.last.payload
        assert_equal :master_key, p[:auth_type]
        assert_equal true, p[:using_master_key]
      end
    end
  end

  # =========================================================================
  # 8. Session-token agent has correct auth metadata in notification
  # =========================================================================

  def test_session_token_agent_auth_metadata_in_notification
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_notif_collector do |collector|
        # A fake token is sufficient — auth_type is derived from presence of
        # @session_token, not from actual token validity.
        agent = Parse::Agent.new(permissions: :readonly, session_token: "r:fake-session-token-e2e")
        agent.execute(:get_all_schemas) # may fail auth — that's fine

        events = collector.events_for(:get_all_schemas)
        assert events.size >= 1
        p = events.last.payload
        assert_equal :session_token, p[:auth_type]
        assert_equal false, p[:using_master_key]
      end
    end
  end

  # =========================================================================
  # 9. Multiple successive tool calls each emit distinct notifications
  # =========================================================================

  def test_multiple_successive_calls_emit_distinct_notifications
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_notif_collector do |collector|
        agent = Parse::Agent.new(permissions: :readonly)
        agent.execute(:get_all_schemas)
        agent.execute(:query_class, class_name: "MCPNotificationItem", limit: 1)
        agent.execute(:count_objects, class_name: "MCPNotificationItem")

        all = collector.all_events
        tools_fired = all.map { |e| e.payload[:tool] }

        assert_includes tools_fired, :get_all_schemas
        assert_includes tools_fired, :query_class
        assert_includes tools_fired, :count_objects
        assert_operator all.size, :>=, 3, "Should have at least 3 distinct notifications"
      end
    end
  end

  # =========================================================================
  # 10. Notification always fires even when tool returns success:false
  # =========================================================================

  def test_notification_fires_even_when_tool_result_is_failure
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_notif_collector do |collector|
        # See test_nonexistent_class_query_fires_error_notification: an
        # unused (but structurally valid) class name is not a failure on
        # Parse Server's REST surface. Use an invalid identifier so the
        # tool definitively fails and the notification path is exercised.
        invalid_name = "Has Spaces And Punctuation!"
        agent = Parse::Agent.new(permissions: :readonly)
        result = agent.execute(:query_class, class_name: invalid_name, limit: 1)

        refute result[:success]
        events = collector.events_for(:query_class)
        assert events.size >= 1, "Notification should fire even on tool failure"
      end
    end
  end

  # =========================================================================
  # 11. Notification payload includes :permissions for agent level
  # =========================================================================

  def test_notification_includes_agent_permissions_level
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_notif_collector do |collector|
        agent = Parse::Agent.new(permissions: :readonly)
        agent.execute(:get_all_schemas)
        events = collector.events_for(:get_all_schemas)
        assert events.size >= 1
        assert_equal :readonly, events.last.payload[:permissions]
      end
    end
  end
end
