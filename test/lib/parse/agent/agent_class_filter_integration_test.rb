# encoding: UTF-8
# frozen_string_literal: true

# End-to-end integration tests for the per-agent `classes:` allowlist.
#
# These tests drive real Parse Server traffic to verify both the gate
# (allowed class returns rows, refused class returns access_denied without
# touching the server) and the audit payload (parse.agent.tool_call carries
# :classes_only / :classes_except / :denial_kind keys).
#
# Gated on PARSE_TEST_USE_DOCKER=true. Companion to
# `agent_class_filter_test.rb` which exercises the gate at the unit level.

require_relative "../../../test_helper_integration"
require "active_support/notifications"
require "securerandom"

require "parse/agent"

class ClassFilterIntegrationAllowed < Parse::Object
  parse_class "ClassFilterIntegrationAllowed"
  property :label, :string
end

class ClassFilterIntegrationDenied < Parse::Object
  parse_class "ClassFilterIntegrationDenied"
  property :label, :string
end

class AgentClassFilterIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_notif_collector
    events = []
    sub = ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |*args|
      events << args.last
    end
    yield events
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  def silence_master_key
    was = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
    yield
  ensure
    Parse::Agent.suppress_master_key_warning = was unless was.nil?
  end

  # ---- Allowed-class read flows end-to-end --------------------------------

  def test_allowed_class_query_returns_rows
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    rows = []
    with_parse_server do
      row = ClassFilterIntegrationAllowed.new(label: "allowed_#{SecureRandom.hex(3)}")
      row.save
      rows << row

      agent = silence_master_key do
        Parse::Agent.new(classes: { only: [ClassFilterIntegrationAllowed] })
      end
      result = agent.execute(:query_class,
                             class_name: "ClassFilterIntegrationAllowed",
                             where: { "label" => row.label },
                             limit: 5)
      assert result[:success], "allowed class should succeed: #{result[:error]}"
      assert_operator result[:data][:results].size, :>=, 1
    end
  ensure
    Array(rows).each { |r| r.destroy rescue nil } if defined?(rows) && rows
  end

  # ---- Refused-class flows refuse without server traffic ------------------

  def test_refused_class_query_returns_access_denied
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      agent = silence_master_key do
        Parse::Agent.new(classes: { only: [ClassFilterIntegrationAllowed] })
      end
      result = agent.execute(:query_class, class_name: "ClassFilterIntegrationDenied", limit: 5)
      refute result[:success], "off-allowlist class must be refused"
      assert_equal :access_denied, result[:error_code]
    end
  end

  # ---- Audit payload carries the filter set -------------------------------

  def test_tool_call_notification_carries_classes_only
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_notif_collector do |events|
        agent = silence_master_key do
          Parse::Agent.new(classes: { only: [ClassFilterIntegrationAllowed] })
        end
        agent.execute(:query_class, class_name: "ClassFilterIntegrationAllowed", limit: 1)

        evt = events.last
        assert evt, "expected at least one parse.agent.tool_call event"
        assert_equal ["ClassFilterIntegrationAllowed"], evt[:classes_only]
        refute evt.key?(:denial_kind), "successful call should not emit denial_kind"
      end
    end
  end

  def test_refusal_payload_carries_class_filter_kind
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    with_parse_server do
      with_notif_collector do |events|
        agent = silence_master_key do
          Parse::Agent.new(classes: { only: [ClassFilterIntegrationAllowed] })
        end
        agent.execute(:count_objects, class_name: "ClassFilterIntegrationDenied")

        evt = events.last
        assert evt, "expected at least one parse.agent.tool_call event"
        assert_equal :access_denied, evt[:error_code]
        assert_equal :class_filter, evt[:denial_kind],
                     "operator-narrowing denial must be distinguishable from policy hiding"
        assert_equal ["ClassFilterIntegrationAllowed"], evt[:classes_only]
      end
    end
  end

  # ---- Schema catalog filter -----------------------------------------------

  def test_get_all_schemas_omits_off_allowlist_classes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" \
      unless ENV["PARSE_TEST_USE_DOCKER"] == "true"

    rows = []
    with_parse_server do
      # Seed both classes so they exist in the server's schema catalog.
      [ClassFilterIntegrationAllowed, ClassFilterIntegrationDenied].each do |klass|
        row = klass.new(label: "seed_#{SecureRandom.hex(3)}")
        row.save
        rows << row
      end

      agent = silence_master_key do
        Parse::Agent.new(classes: { only: [ClassFilterIntegrationAllowed] })
      end
      result = agent.execute(:get_all_schemas)
      assert result[:success], "get_all_schemas should succeed: #{result[:error]}"
      # ResultFormatter.format_schemas splits into built_in / custom arrays
      # of {name:, fields:, desc:, methods:} entries — neither carries a
      # `className` key. Collect every `:name` across both buckets.
      data = result[:data] || {}
      class_names = (Array(data[:custom]) + Array(data[:built_in])).map { |s| s[:name] || s["name"] }.compact
      assert_includes class_names, "ClassFilterIntegrationAllowed"
      refute_includes class_names, "ClassFilterIntegrationDenied",
                      "schema catalog must omit classes outside the per-agent allowlist"
    end
  ensure
    Array(rows).each { |r| r.destroy rescue nil } if defined?(rows) && rows
  end
end
