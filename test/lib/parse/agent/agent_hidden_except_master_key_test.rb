# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Verifies the two-axis defense for the agent-hidden / agent-unhidden DSL:
#
#   1. Class-level visibility (per-class, configurable):
#        agent_hidden                           -> denied to every agent
#        agent_hidden(except: :master_key)      -> denied to session-bound,
#                                                  permitted to master-key
#        agent_unhidden                         -> reverses (returns prior state)
#
#   2. Field-level credential floor (process-wide, independent of class gate):
#        INTERNAL_FIELDS_DENYLIST stripped from every response, even when the
#        containing class has been deliberately unhidden. A compromised
#        master-key tool that reads the unhidden class still cannot exfiltrate
#        sessionToken / _hashed_password / _auth_data / _rperm / _wperm.
class AgentHiddenExceptMasterKeyTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app", api_key: "test-key")
    end
  end

  class ExceptMKHiddenClass < Parse::Object
    parse_class "ExceptMKHiddenClass"
    property :label, :string
    agent_hidden
  end

  class ExceptMKMasterOnlyClass < Parse::Object
    parse_class "ExceptMKMasterOnlyClass"
    property :label, :string
    property :session_token, :string  # legitimate stand-in for the Session.sessionToken column
    agent_hidden(except: :master_key)
  end

  # ---- agent_hidden(except: :master_key) ----------------------------------

  def test_except_master_key_permits_master_key_agent
    master = silence_master_key_warnings { Parse::Agent.new }
    # No raise expected: master-key agent + except: :master_key clears the gate.
    Parse::Agent::Tools.assert_class_accessible!(ExceptMKMasterOnlyClass.parse_class, agent: master)
  end

  def test_except_master_key_refuses_session_bound_agent
    session_bound = Parse::Agent.new(session_token: "r:abc123")
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.assert_class_accessible!(ExceptMKMasterOnlyClass.parse_class, agent: session_bound)
    end
  end

  def test_strict_hidden_refuses_even_master_key
    master = silence_master_key_warnings { Parse::Agent.new }
    # No `except:` -> unconditionally hidden, master-key included.
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.assert_class_accessible!(ExceptMKHiddenClass.parse_class, agent: master)
    end
  end

  def test_nil_agent_falls_back_to_strict_hidden
    # Callers that don't propagate the agent (e.g. registry introspection) must
    # not silently downgrade to master-key access.
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.assert_class_accessible!(ExceptMKMasterOnlyClass.parse_class, agent: nil)
    end
  end

  def test_argument_error_on_unknown_except_scope
    klass = Class.new(Parse::Object)
    assert_raises(ArgumentError) { klass.agent_hidden(except: :public) }
  end

  # ---- INTERNAL_FIELDS_DENYLIST floor -------------------------------------

  def test_walk_and_redact_strips_session_token_field
    row = {
      "objectId" => "abc123",
      "sessionToken" => "r:credential-leak",
      "user" => { "__type" => "Pointer", "className" => "_User", "objectId" => "u1" },
    }
    cleaned = Parse::Agent::Tools.redact_hidden_classes!([row]).first
    refute cleaned.key?("sessionToken"), "sessionToken must be stripped from agent response rows"
    assert_equal "abc123", cleaned["objectId"]
    assert_equal "u1", cleaned.dig("user", "objectId")
  end

  def test_walk_and_redact_strips_session_token_even_inside_nested_documents
    row = {
      "objectId" => "abc123",
      "nested" => {
        "extra" => "ok",
        "sessionToken" => "r:should-still-be-stripped",
      },
    }
    cleaned = Parse::Agent::Tools.redact_hidden_classes!([row]).first
    refute cleaned["nested"].key?("sessionToken")
    assert_equal "ok", cleaned["nested"]["extra"]
  end

  def test_walk_and_redact_strips_prefix_denied_auth_data_columns
    row = {
      "objectId" => "abc123",
      "_auth_data_facebook" => { "id" => "fb_user_id", "access_token" => "fb_token" },
    }
    cleaned = Parse::Agent::Tools.redact_hidden_classes!([row]).first
    refute cleaned.key?("_auth_data_facebook"), "per-provider auth_data prefix must be stripped"
  end

  # ---- agent_unhidden return value + idempotency --------------------------

  def test_agent_unhidden_returns_true_when_class_was_hidden
    klass = Class.new(Parse::Object) do
      def self.name; "TempHiddenForUnhide"; end
      parse_class "TempHiddenForUnhide"
      agent_hidden
    end
    result = silence_master_key_warnings { klass.agent_unhidden }
    assert_equal true, result, "agent_unhidden returns true when it actually flipped state"
    refute klass.agent_hidden?
  end

  def test_agent_unhidden_returns_false_when_class_was_not_hidden
    klass = Class.new(Parse::Object) do
      def self.name; "NeverHiddenAgentUnhide"; end
      parse_class "NeverHiddenAgentUnhide"
    end
    result = klass.agent_unhidden
    assert_equal false, result, "agent_unhidden returns false on no-op (class was not hidden)"
  end

  def test_agent_unhidden_does_not_warn_on_no_op
    klass = Class.new(Parse::Object) do
      def self.name; "NeverHiddenNoWarn"; end
      parse_class "NeverHiddenNoWarn"
    end
    captured = capture_warn { klass.agent_unhidden }
    assert_equal "", captured, "agent_unhidden must not emit a security banner when the class was not hidden"
  end

  private

  def silence_master_key_warnings
    suppressed_was = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
    yield
  ensure
    Parse::Agent.suppress_master_key_warning = suppressed_was unless suppressed_was.nil?
  end

  def capture_warn
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
