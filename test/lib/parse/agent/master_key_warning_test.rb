# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Covers the one-time `[Parse::Agent:SECURITY]` banner emitted on the first
# master-key construction in a process (no session_token), plus the
# `Parse::Agent.suppress_master_key_warning` accessor and the
# `reset_master_key_warning!` test helper.
class AgentMasterKeyWarningTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    Parse::Agent.reset_master_key_warning!
    @prior_suppress = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = false
  end

  def teardown
    Parse::Agent.suppress_master_key_warning = @prior_suppress
    Parse::Agent.reset_master_key_warning!
  end

  def capture_warn
    original_stderr = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original_stderr
  end

  def test_master_key_construction_emits_one_time_warning
    out = capture_warn { Parse::Agent.new }
    assert_match(/\[Parse::Agent:SECURITY\]/, out)
    assert_match(/master key/i, out)
    assert_match(/suppress_master_key_warning/, out)
  end

  def test_subsequent_master_key_constructions_are_silent
    capture_warn { Parse::Agent.new }
    out = capture_warn { 5.times { Parse::Agent.new } }
    assert_empty out, "expected one-time latch to suppress repeat banners"
  end

  def test_session_token_construction_does_not_emit_warning
    out = capture_warn { Parse::Agent.new(session_token: "r:abc123") }
    assert_empty out, "session-bound agent must not trigger the master-key banner"
  end

  def test_suppress_flag_silences_first_construction
    Parse::Agent.suppress_master_key_warning = true
    out = capture_warn { Parse::Agent.new }
    assert_empty out
  end

  def test_reset_master_key_warning_rearms_latch
    capture_warn { Parse::Agent.new }
    Parse::Agent.reset_master_key_warning!
    out = capture_warn { Parse::Agent.new }
    refute_empty out, "reset! should re-arm the one-time latch"
  end

  def test_sub_agent_inheritance_does_not_double_warn
    parent = nil
    capture_warn { parent = Parse::Agent.new }
    out = capture_warn { Parse::Agent.new(parent: parent, permissions: :readonly) }
    assert_empty out, "sub-agent inheriting parent's auth scope must not re-emit"
  end
end
