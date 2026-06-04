# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

# Tests embedding-cost attribution on parse.agent.tool_call: the
# thread-local accumulator fed by the process-wide parse.embeddings.embed
# subscriber, surfaced as embed_calls / embed_tokens / embed_cost_usd.
class EmbedCostTelemetryTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @saved_rate = Parse::Agent.embed_cost_per_million_tokens
    Parse::Agent::Tools.reset_registry!

    Parse::Agent::Tools.register(
      name: :tel_embed_once, description: "embed once", parameters: { "type" => "object" },
      permission: :readonly,
      handler: ->(_agent, **_a) { Parse::Embeddings.provider(:fixture).embed_text(["hi"]); { ok: true } },
    )
    Parse::Agent::Tools.register(
      name: :tel_embed_tokens, description: "embed with tokens", parameters: { "type" => "object" },
      permission: :readonly,
      handler: lambda do |_agent, **_a|
        ActiveSupport::Notifications.instrument("parse.embeddings.embed", total_tokens: 1000) { [] }
        { ok: true }
      end,
    )
    Parse::Agent::Tools.register(
      name: :tel_no_embed, description: "no embed", parameters: { "type" => "object" },
      permission: :readonly, handler: ->(_agent, **_a) { { ok: true } },
    )
    Parse::Agent::Tools.register(
      name: :tel_embed_raise, description: "embed then raise", parameters: { "type" => "object" },
      permission: :readonly,
      handler: lambda do |_agent, **_a|
        Parse::Embeddings.provider(:fixture).embed_text(["x"])
        raise "boom"
      end,
    )
  end

  def teardown
    Parse::Agent::Tools.reset_registry!
    Parse::Agent.embed_cost_per_million_tokens = @saved_rate
  end

  def capture_tool_call_payload
    captured = nil
    sub = ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |*args|
      captured = args.last.dup
    end
    yield
    captured
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  def agent
    Parse::Agent.new(permissions: :readonly)
  end

  def test_fixture_embed_counts_call_zero_tokens
    payload = capture_tool_call_payload { agent.execute(:tel_embed_once) }
    assert_equal 1, payload[:embed_calls]
    assert_equal 0, payload[:embed_tokens]
    refute payload.key?(:embed_cost_usd)
  end

  def test_token_and_cost_path
    Parse::Agent.embed_cost_per_million_tokens = 2.0
    payload = capture_tool_call_payload { agent.execute(:tel_embed_tokens) }
    assert_equal 1, payload[:embed_calls]
    assert_equal 1000, payload[:embed_tokens]
    assert_in_delta 0.002, payload[:embed_cost_usd], 1e-9
  end

  def test_no_embed_tool_omits_fields
    payload = capture_tool_call_payload { agent.execute(:tel_no_embed) }
    refute payload.key?(:embed_calls)
    refute payload.key?(:embed_tokens)
  end

  def test_leak_guard_no_carryover_after_raise
    a = agent
    capture_tool_call_payload { a.execute(:tel_embed_raise) } # raises internally, rescued by execute
    payload = capture_tool_call_payload { a.execute(:tel_no_embed) }
    refute payload.key?(:embed_calls), "embed accumulator must not leak across tool calls"
  end
end
