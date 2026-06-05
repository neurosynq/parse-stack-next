# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Parse Server 9.0 defaults `allowPublicExplain` to false. Query#explain warns
# proactively (one-shot) when the call is clearly non-master AND the server
# version is known to restrict it — but NOT for master-default calls or
# unknown-version servers (avoid spurious noise on a flag /serverInfo can't
# surface). The warn decision is observable via the one-shot latch.
class TestExplainPublicWarn < Minitest::Test
  FakeClient = Struct.new(:version, :supports) do
    def server_version; version; end
    def server_supports?(_feature); supports; end
  end

  def setup
    Parse::Query.instance_variable_set(:@public_explain_warned, false)
  end

  def teardown
    Parse::Query.instance_variable_set(:@public_explain_warned, false)
  end

  def query_with(client:, use_master_key: nil, session_token: nil)
    q = Parse::Query.new("Post")
    q.use_master_key = use_master_key unless use_master_key.nil?
    q.session_token = session_token if session_token
    q.define_singleton_method(:client) { client }
    q
  end

  def warned?(q)
    q.send(:warn_if_public_explain_restricted!)
    Parse::Query.public_explain_warned?
  end

  def test_warns_for_explicit_non_master_on_restricted_server
    q = query_with(client: FakeClient.new("9.9.0", false), use_master_key: false)
    assert warned?(q), "should warn for non-master explain on PS 9.x"
  end

  def test_warns_for_session_token_scope
    q = query_with(client: FakeClient.new("9.0.0", false), session_token: "r:abc")
    assert warned?(q)
  end

  def test_no_warn_for_explicit_master
    q = query_with(client: FakeClient.new("9.9.0", false), use_master_key: true)
    refute warned?(q), "master explain should not warn"
  end

  def test_no_warn_for_master_default_unspecified
    # use_master_key nil (the common master-default case) → no spurious warn.
    q = query_with(client: FakeClient.new("9.9.0", false))
    refute warned?(q)
  end

  def test_no_warn_when_server_supports_public_explain
    q = query_with(client: FakeClient.new("8.5.0", true), use_master_key: false)
    refute warned?(q)
  end

  def test_no_warn_on_unknown_version
    q = query_with(client: FakeClient.new("", false), use_master_key: false)
    refute warned?(q), "unknown version should not trigger the warning"
  end

  def test_one_shot_latch
    q = query_with(client: FakeClient.new("9.9.0", false), use_master_key: false)
    assert warned?(q)
    # Second call is a no-op; latch stays set and nothing raises.
    assert warned?(q)
  end
end
