# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# SEC-01: `call_method` must resolve its instance receiver through the AGENT'S
# scope, not the master-backed default client. Previously `klass.find(object_id)`
# ran with ambient master authority, so a scoped agent could read (and via a
# write method, mutate) any object by id (IDOR + read->write escalation).
class AgentCallMethodScopeTest < Minitest::Test
  class Sec01Doc < Parse::Object
    parse_class "Sec01Doc"
    property :title, :string

    # Define BEFORE agent_method so the DSL infers type: :instance (it checks
    # method_defined? at declaration time; a forward declaration is :unknown).
    def read_title
      title
    end
    agent_method :read_title, permission: :readonly

    def retitle(title: nil)
      self.title = title
      "ok"
    end
    agent_method :retitle, permission: :write
  end

  # Minimal Parse::Client response shape used by fetch_object.
  FakeResp = Struct.new(:ok, :nf, :result, :error) do
    def success?
      ok
    end

    def object_not_found?
      nf
    end
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "a", api_key: "k")
    end
  end

  def teardown
    Parse::CLPScope.reset_cache! if defined?(Parse::CLPScope)
  end

  def master_client
    Parse::Client.new(server_url: "http://localhost:1337/parse",
                      app_id: "a", api_key: "k", master_key: "m", logging: false)
  end

  def doc_row
    { "objectId" => "o1", "className" => "Sec01Doc", "title" => "hi" }
  end

  # The receiver fetch for a session-scoped agent must carry the session
  # token (server-enforced ACL/CLP), NOT run as master.
  def test_receiver_fetch_forwards_session_scope_not_master
    agent = Parse::Agent.new(session_token: "r:alice", client: master_client,
                             permissions: :readonly)
    captured = nil
    fetch = lambda do |cls, id, **opts|
      captured = { cls: cls, id: id, opts: opts }
      FakeResp.new(true, false, doc_row, nil)
    end
    agent.client.stub(:fetch_object, fetch) do
      obj = Parse::Agent::Tools.fetch_call_method_receiver(agent, Sec01Doc, "Sec01Doc", "o1")
      assert_instance_of Sec01Doc, obj
    end
    assert_equal "r:alice", captured[:opts][:session_token],
                 "receiver fetch must carry the agent's session token (scoped read), not run as master"
  end

  # A master-posture agent (no scope) legitimately fetches unscoped.
  def test_receiver_fetch_master_agent_is_unscoped
    agent = Parse::Agent.new(client: master_client, permissions: :readonly)
    captured = nil
    fetch = lambda do |_cls, _id, **opts|
      captured = opts
      FakeResp.new(true, false, doc_row, nil)
    end
    agent.client.stub(:fetch_object, fetch) do
      Parse::Agent::Tools.fetch_call_method_receiver(agent, Sec01Doc, "Sec01Doc", "o1")
    end
    assert_nil captured[:session_token],
               "a master-posture agent carries no session token on the receiver fetch"
  end

  # A row the scope cannot read (object_not_found) fails closed -> nil, which
  # call_method maps to "Object not found" (no existence oracle, no master read).
  def test_receiver_fetch_returns_nil_when_scope_cannot_read
    agent = Parse::Agent.new(session_token: "r:alice", client: master_client,
                             permissions: :readonly)
    fetch = lambda { |_cls, _id, **_opts| FakeResp.new(false, true, nil, "not found") }
    agent.client.stub(:fetch_object, fetch) do
      assert_nil Parse::Agent::Tools.fetch_call_method_receiver(agent, Sec01Doc, "Sec01Doc", "missing")
    end
  end

  # An instance write/admin method under an acl_user:/acl_role: scope cannot be
  # enforced (no session token to bind) and must be refused before execution.
  def test_acl_role_instance_write_method_is_refused
    Parse::CLPScope.__cache_put("Sec01Doc", clp: {
      "find" => { "*" => true }, "update" => { "*" => true },
    })
    # Canned role resolution so construction / CLP gate don't hit the network.
    resolved = Parse::ACLScope::Resolution.new(
      mode: :role, permission_strings: ["role:editors"], user_id: nil,
      session: nil, strict_role: false,
    )
    # The write env-gate must be open so we reach the scope-enforcement guard
    # (not the env refusal) — that guard is what we're asserting.
    prev = ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"]
    ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = "true"
    Parse::ACLScope.stub(:resolve_for_role, resolved) do
      agent = Parse::Agent.new(acl_role: "editors", client: master_client, permissions: :write)
      err = assert_raises(Parse::Agent::AccessDenied) do
        Parse::Agent::Tools.call_method(agent, class_name: "Sec01Doc",
                                        method_name: "retitle", object_id: "o1",
                                        arguments: { title: "x" })
      end
      assert_equal :unenforceable_scope, err.kind
    end
  ensure
    prev ? ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = prev : ENV.delete("PARSE_AGENT_ALLOW_WRITE_TOOLS")
  end
end
