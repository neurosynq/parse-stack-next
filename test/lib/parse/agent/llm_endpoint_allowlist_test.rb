# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent"
require_relative "../../../../lib/parse/agent/mcp_client"

# Unit tests for the LLM endpoint allowlist. When
# `Parse::Agent.allowed_llm_endpoints` is set, the SDK refuses to send
# prompts to any LLM endpoint outside the allowlist. Default behavior
# (unset) preserves the prior open posture.
class TestLLMEndpointAllowlist < Minitest::Test
  def setup
    @original = Parse::Agent.allowed_llm_endpoints
    Parse::Agent.allowed_llm_endpoints = nil
  end

  def teardown
    Parse::Agent.allowed_llm_endpoints = @original
  end

  def test_assert_is_noop_when_allowlist_unset
    Parse::Agent.allowed_llm_endpoints = nil
    # Should not raise regardless of endpoint
    Parse::Agent.assert_llm_endpoint_allowed!("https://attacker.example.com/v1")
    Parse::Agent.assert_llm_endpoint_allowed!("http://localhost:1234/v1")
  end

  def test_assert_passes_for_allowlisted_prefix
    Parse::Agent.allowed_llm_endpoints = ["https://api.openai.com/v1"]
    Parse::Agent.assert_llm_endpoint_allowed!("https://api.openai.com/v1/chat/completions")
    Parse::Agent.assert_llm_endpoint_allowed!("https://api.openai.com/v1")
  end

  def test_assert_rejects_non_allowlisted_endpoint
    Parse::Agent.allowed_llm_endpoints = ["https://api.openai.com/v1"]
    err = assert_raises(ArgumentError) do
      Parse::Agent.assert_llm_endpoint_allowed!("https://attacker.example.com/v1")
    end
    assert_match(/allowed_llm_endpoints/, err.message)
  end

  def test_assert_is_case_insensitive
    Parse::Agent.allowed_llm_endpoints = ["https://API.OpenAI.com/v1"]
    Parse::Agent.assert_llm_endpoint_allowed!("https://api.openai.com/V1/chat")
  end

  def test_multiple_allowlist_entries_any_match
    Parse::Agent.allowed_llm_endpoints = [
      "https://api.openai.com/v1",
      "https://api.anthropic.com/v1",
      "http://localhost:1234/v1",
    ]
    Parse::Agent.assert_llm_endpoint_allowed!("https://api.anthropic.com/v1/messages")
    Parse::Agent.assert_llm_endpoint_allowed!("http://localhost:1234/v1/chat/completions")
  end

  def test_empty_allowlist_array_refuses_everything
    Parse::Agent.allowed_llm_endpoints = []
    assert_raises(ArgumentError) do
      Parse::Agent.assert_llm_endpoint_allowed!("https://api.openai.com/v1")
    end
  end

  # ---- MCPClient constructor ----------------------------------------------

  def test_mcp_client_constructor_enforces_allowlist
    Parse::Agent.allowed_llm_endpoints = ["https://api.anthropic.com/v1"]
    # Attempt to override with a non-allowlisted endpoint via base_url:
    assert_raises(ArgumentError) do
      Parse::Agent::MCPClient.new(
        agent: nil,
        provider: "anthropic",
        api_key: "test",
        model: "claude-test",
        base_url: "https://attacker.example.com/v1",
      )
    end
  end

  def test_mcp_client_constructor_allows_in_list_endpoint
    Parse::Agent.allowed_llm_endpoints = ["https://api.anthropic.com/v1"]
    client = Parse::Agent::MCPClient.new(
      agent: nil,
      provider: "anthropic",
      api_key: "test",
      model: "claude-test",
      base_url: "https://api.anthropic.com/v1",
    )
    assert_equal "https://api.anthropic.com/v1", client.instance_variable_get(:@base_url)
  end

  def test_mcp_client_unset_allowlist_accepts_any_endpoint
    Parse::Agent.allowed_llm_endpoints = nil
    client = Parse::Agent::MCPClient.new(
      agent: nil,
      provider: "anthropic",
      api_key: "test",
      model: "claude-test",
      base_url: "https://attacker.example.com/v1",
    )
    assert_equal "https://attacker.example.com/v1", client.instance_variable_get(:@base_url)
  end

  # ---- ask() public surface ----------------------------------------------

  def test_ask_refuses_non_allowlisted_per_call_endpoint
    skip("requires a configured Parse client") unless Parse::Client.client?
    Parse::Agent.allowed_llm_endpoints = ["https://api.openai.com/v1"]
    agent = Parse::Agent.new
    assert_raises(ArgumentError) do
      agent.ask("hi", llm_endpoint: "https://attacker.example.com/v1")
    end
  end
end
