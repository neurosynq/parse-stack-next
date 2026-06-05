# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/live_query"

# Tests for the LiveQuery `watch:` option (PS 7.0+, PR #8028).
# `watch` filters which field mutations trigger an update event, independently
# of field projection (`keys`/`fields` which control what the event payload
# contains).
class TestLiveQueryWatch < Minitest::Test
  def mock_client
    @mock_client ||= Minitest::Mock.new
  end

  def subscription_with(opts = {})
    Parse::LiveQuery::Subscription.new(
      client: mock_client,
      class_name: "Post",
      query: {},
      **opts,
    )
  end

  # --- Subscription constructor ------------------------------------------

  def test_watch_attr_reader_exists
    sub = subscription_with
    assert_respond_to sub, :watch
  end

  def test_watch_defaults_to_nil
    sub = subscription_with
    assert_nil sub.watch
  end

  def test_watch_stores_array_of_strings
    sub = subscription_with(watch: ["title", "status"])
    assert_equal ["title", "status"], sub.watch
  end

  def test_watch_stores_array_of_symbols
    sub = subscription_with(watch: [:title, :status])
    assert_equal [:title, :status], sub.watch
  end

  def test_watch_stores_mixed_array
    sub = subscription_with(watch: ["title", :status])
    assert_equal ["title", :status], sub.watch
  end

  # --- to_subscribe_message ---------------------------------------------

  def test_subscribe_message_omits_watch_when_nil
    sub = subscription_with
    msg = sub.to_subscribe_message
    refute msg[:query].key?(:watch),
      "watch must not appear in the message when nil"
  end

  def test_subscribe_message_omits_watch_when_empty_array
    sub = subscription_with(watch: [])
    msg = sub.to_subscribe_message
    refute msg[:query].key?(:watch),
      "watch must not appear in the message when the array is empty"
  end

  def test_subscribe_message_includes_watch_when_set
    sub = subscription_with(watch: ["title", "status"])
    msg = sub.to_subscribe_message
    assert msg[:query].key?(:watch),
      "watch must appear in the subscribe message when set"
    assert_equal ["title", "status"], msg[:query][:watch]
  end

  def test_subscribe_message_watch_and_keys_are_independent
    sub = subscription_with(
      keys: ["title", "author"],
      watch: ["status"],
    )
    msg = sub.to_subscribe_message
    assert_equal ["title", "author"], msg[:query][:keys]
    assert_equal ["status"],           msg[:query][:watch]
  end

  def test_subscribe_message_base_structure_intact_with_watch
    sub = subscription_with(watch: ["title"])
    msg = sub.to_subscribe_message
    assert_equal "subscribe",  msg[:op]
    assert_equal "Post",       msg[:query][:className]
    assert_equal({},           msg[:query][:where])
    assert_equal ["title"],    msg[:query][:watch]
  end

  # --- Client#subscribe forwarding ---------------------------------------

  def test_lq_client_subscribe_accepts_watch_kwarg
    # Build a minimal LiveQuery::Client stub
    stub_client = Object.new
    captured = {}

    stub_client.define_singleton_method(:subscribe) do |class_name, where: {}, fields: nil, keys: nil, watch: nil, session_token: nil, use_master_key: false, &block|
      captured[:watch] = watch
      Parse::LiveQuery::Subscription.new(
        client: stub_client,
        class_name: class_name,
        query: where,
        watch: watch,
      )
    end

    q = Parse::Query.new("Post")
    sub = q.subscribe(watch: ["title"], client: stub_client)
    assert_equal ["title"], sub.watch
    assert_equal ["title"], captured[:watch]
  end

  # --- Query#subscribe forwarding ---------------------------------------

  def test_query_subscribe_accepts_and_forwards_watch
    captured_watch = nil
    spy_lq = Object.new
    spy_lq.define_singleton_method(:subscribe) do |class_name, where: {}, fields: nil, keys: nil, watch: nil, session_token: nil, use_master_key: false, &block|
      captured_watch = watch
      Parse::LiveQuery::Subscription.new(
        client: spy_lq,
        class_name: class_name,
        query: where,
        watch: watch,
      )
    end

    q = Parse::Query.new("Post")
    q.subscribe(watch: ["title", "body"], client: spy_lq)
    assert_equal ["title", "body"], captured_watch
  end
end
