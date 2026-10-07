# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "pp"

# SEC-17: Parse::Agent#inspect (and pp / to_s) must not print the session
# token, the client's keys, or conversation and response contents.
class AgentInspectRedactionTest < Minitest::Test
  SECRET = "r:super-secret-session-token"

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test",
                  master_key: "test_master_key")
    end
    @prior_suppress = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
  end

  def teardown
    Parse::Agent.suppress_master_key_warning = @prior_suppress
  end

  def session_agent
    Parse::ACLScope.stub(:resolve!, ->(*_a, **_k) { raise "offline" }) do
      Parse::Agent.new(session_token: SECRET)
    end
  end

  def rendered(agent)
    [agent.inspect, agent.to_s, agent.pretty_inspect, PP.pp(agent, +"")]
  end

  def test_session_token_never_appears
    agent = session_agent
    rendered(agent).each do |text|
      refute_includes text, SECRET
      refute_includes text, "super-secret"
    end
  end

  def test_client_keys_never_appear
    agent = Parse::Agent.new
    rendered(agent).each do |text|
      # The posture label (auth=master_key) is fine; key values and
      # request headers are not.
      refute_includes text, "test_master_key"
      refute_match(/api_key|X-Parse|@client/i, text)
    end
  end

  def test_conversation_and_response_contents_are_not_dumped
    agent = Parse::Agent.new
    agent.instance_variable_set(:@conversation_history, [{ role: "user", content: "PRIVATE-PROMPT" }])
    agent.instance_variable_set(:@last_response, { "results" => [{ "ssn" => "PRIVATE-ROW" }] })
    agent.instance_variable_set(:@last_request, { body: "PRIVATE-BODY" })
    rendered(agent).each do |text|
      refute_includes text, "PRIVATE-PROMPT"
      refute_includes text, "PRIVATE-ROW"
      refute_includes text, "PRIVATE-BODY"
    end
  end

  def test_inspect_still_identifies_the_agent
    agent = session_agent
    text = agent.inspect
    assert_includes text, agent.agent_id
    assert_includes text, "permissions=readonly"
    assert_includes text, "auth=session_token"
    assert_match(/\A#<Parse::Agent /, text)
  end
end
