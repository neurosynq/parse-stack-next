# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"
require "parse/agent/mcp_dispatcher"

# Unit tests for Parse::Agent#log, the tool-facing side of MCP
# `notifications/message`.
class AgentLogTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @agent = Parse::Agent.new(permissions: :readonly)
  end

  def test_log_is_a_no_op_without_a_callback
    assert_nil @agent.log(:error, "x")
  end

  def test_log_forwards_level_data_and_logger
    seen = []
    @agent.log_callback = ->(**kw) { seen << kw }
    @agent.log(:info, { "rows" => 3 }, logger: "custom")
    assert_equal [{ level: "info", data: { "rows" => 3 }, logger: "custom" }], seen
  end

  def test_log_rejects_unknown_level
    @agent.log_callback = ->(**) {}
    assert_raises(ArgumentError) { @agent.log(:loud, "x") }
  end

  def test_log_rejects_unknown_level_even_without_a_callback
    assert_raises(ArgumentError) { @agent.log(:warn, "x") }
  end
end
