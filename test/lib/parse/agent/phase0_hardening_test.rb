# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_rack_app"

# ============================================================================
# Phase 0 pre-pentest hardening tests covering:
#
#   NEW-MCP-1: MCPServer refuses non-loopback bind without an API key.
#   NEW-MCP-2: build_rack_env drops HTTP headers whose names contain `_`.
#   NEW-TOOLS-5: keys: parameter rejects leading-underscore field names.
#   NEW-TOOLS-9: class_name / object_id / method_name format validation.
# ============================================================================

# ----------------------------------------------------------------------------
# NEW-MCP-1
# ----------------------------------------------------------------------------
class MCPBindKeyCouplingTest < Minitest::Test
  def setup
    @saved_env = ENV.delete("MCP_API_KEY")
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    # Load the MCP server class on demand — it's not auto-loaded by stack.rb.
    require_relative "../../../../lib/parse/agent/mcp_server" \
      unless defined?(Parse::Agent::MCPServer)
  end

  def teardown
    ENV["MCP_API_KEY"] = @saved_env if @saved_env
  end

  def test_loopback_127_without_api_key_is_allowed
    Parse::Agent::MCPServer.new(host: "127.0.0.1", api_key: nil)
    pass
  rescue ArgumentError => e
    flunk "loopback bind without api_key should not raise, got: #{e.message}"
  end

  def test_loopback_ipv6_without_api_key_is_allowed
    Parse::Agent::MCPServer.new(host: "::1", api_key: nil)
    pass
  end

  def test_localhost_string_without_api_key_is_allowed
    Parse::Agent::MCPServer.new(host: "localhost", api_key: nil)
    pass
  end

  def test_zero_zero_zero_zero_without_api_key_is_refused
    err = assert_raises(ArgumentError) do
      Parse::Agent::MCPServer.new(host: "0.0.0.0", api_key: nil)
    end
    assert_match(/non-loopback/, err.message)
    assert_match(/MCP_API_KEY/, err.message)
  end

  def test_external_address_without_api_key_is_refused
    err = assert_raises(ArgumentError) do
      Parse::Agent::MCPServer.new(host: "10.0.0.5", api_key: nil)
    end
    assert_match(/non-loopback/, err.message)
  end

  def test_non_loopback_with_explicit_api_key_is_allowed
    Parse::Agent::MCPServer.new(host: "0.0.0.0", api_key: "trusted-secret")
    pass
  end

  def test_non_loopback_with_env_api_key_is_allowed
    ENV["MCP_API_KEY"] = "env-secret"
    Parse::Agent::MCPServer.new(host: "0.0.0.0", api_key: nil)
    pass
  ensure
    ENV.delete("MCP_API_KEY")
  end

  def test_non_loopback_with_empty_string_api_key_is_refused
    err = assert_raises(ArgumentError) do
      Parse::Agent::MCPServer.new(host: "0.0.0.0", api_key: "")
    end
    assert_match(/non-loopback/, err.message)
  end
end

# ----------------------------------------------------------------------------
# NEW-MCP-2
# ----------------------------------------------------------------------------
class HeaderUnderscoreScrubTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    require_relative "../../../../lib/parse/agent/mcp_server" \
      unless defined?(Parse::Agent::MCPServer)
    @server = Parse::Agent::MCPServer.new(host: "127.0.0.1", api_key: "test")
  end

  def fake_req(headers)
    # Minimal duck-type of a WEBrick::HTTPRequest
    req = Object.new
    req.define_singleton_method(:request_method) { "POST" }
    req.define_singleton_method(:[]) { |name| headers[name] }
    req.define_singleton_method(:body) { "" }
    req.define_singleton_method(:path) { "/mcp" }
    req.define_singleton_method(:query_string) { "" }
    req.define_singleton_method(:each) do |&blk|
      headers.each_key { |k| blk.call(k) unless k =~ /^Content-(Type|Length)$/i }
    end
    req
  end

  def test_underscore_form_header_dropped
    headers = {
      "Content-Type"    => "application/json",
      "Content-Length"  => "0",
      "X-MCP-API-Key"   => "real-trusted-key",
      "X_MCP_API_KEY"   => "attacker-injected-key",
    }
    env = @server.send(:build_rack_env, fake_req(headers))
    # The dash-form value must win; the underscore-form must not appear.
    assert_equal "real-trusted-key", env["HTTP_X_MCP_API_KEY"]
    refute_equal "attacker-injected-key", env["HTTP_X_MCP_API_KEY"]
  end

  def test_only_dash_form_present_passes_through_normally
    headers = {
      "Content-Type"   => "application/json",
      "Content-Length" => "0",
      "X-MCP-API-Key"  => "the-only-key",
    }
    env = @server.send(:build_rack_env, fake_req(headers))
    assert_equal "the-only-key", env["HTTP_X_MCP_API_KEY"]
  end

  def test_only_underscore_form_is_dropped_entirely
    headers = {
      "Content-Type"   => "application/json",
      "Content-Length" => "0",
      "X_MCP_API_KEY"  => "underscore-attacker",
    }
    env = @server.send(:build_rack_env, fake_req(headers))
    refute env.key?("HTTP_X_MCP_API_KEY"),
           "underscore-only request should never produce HTTP_X_MCP_API_KEY"
  end
end

# ----------------------------------------------------------------------------
# NEW-TOOLS-5
# ----------------------------------------------------------------------------
class KeysUnderscoreDenylistTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @agent = Parse::Agent.new(permissions: :readonly)
    fake_client = Object.new
    fake_client.define_singleton_method(:find_objects) do |_c, _q, **_opts|
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:count)    { 0 }
      r.define_singleton_method(:results)  { [] }
      r
    end
    @agent.define_singleton_method(:client) { fake_client }
  end

  def test_keys_with_hashed_password_is_rejected
    result = @agent.execute(:query_class,
                            class_name: "Article",
                            keys: ["_hashed_password", "title"])
    refute result[:success]
    assert_includes result[:error].to_s.downcase, "underscore"
  end

  def test_keys_with_session_token_is_rejected
    result = @agent.execute(:query_class, class_name: "Article",
                                          keys: ["_session_token"])
    refute result[:success]
  end

  def test_keys_with_auth_data_dotted_path_starting_with_underscore_is_rejected
    result = @agent.execute(:query_class, class_name: "Article",
                                          keys: ["authData._provider"])
    refute result[:success]
  end

  def test_keys_with_normal_field_names_passes
    result = @agent.execute(:query_class, class_name: "Article",
                                          keys: ["title", "author", "createdAt"])
    # Down the line the fake-client returns success; the gate doesn't fire.
    assert result[:success], "normal keys should pass validation"
  end

  def test_keys_array_size_cap
    big = (1..100).map { |i| "field_#{i}" }
    result = @agent.execute(:query_class, class_name: "Article", keys: big)
    refute result[:success]
    assert_match(/64-field limit/, result[:error].to_s)
  end

  def test_keys_non_array_is_rejected
    result = @agent.execute(:query_class, class_name: "Article", keys: "title")
    refute result[:success]
  end
end

# ----------------------------------------------------------------------------
# NEW-TOOLS-9
# ----------------------------------------------------------------------------
class IdentifierFormatValidationTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @agent = Parse::Agent.new(permissions: :readonly)
  end

  def test_class_name_with_sql_injection_payload_is_refused
    result = @agent.execute(:query_class, class_name: "_User'; DROP TABLE x --")
    refute result[:success]
    assert_match(/identifier/i, result[:error].to_s)
  end

  def test_class_name_with_path_traversal_is_refused
    result = @agent.execute(:query_class, class_name: "../etc/passwd")
    refute result[:success]
  end

  def test_class_name_with_url_query_string_is_refused
    result = @agent.execute(:query_class, class_name: "Article?include=*")
    refute result[:success]
  end

  def test_class_name_with_very_long_value_is_refused
    result = @agent.execute(:query_class, class_name: "A" * 200)
    refute result[:success]
  end

  def test_valid_class_name_passes
    # The fake client isn't wired here, so it'll fail downstream — but the
    # failure must NOT be a validation error from our identifier check.
    result = @agent.execute(:query_class, class_name: "Article")
    refute_equal :invalid_argument, result[:error_code] if result.key?(:error_code)
  end

  def test_system_class_with_leading_underscore_passes_identifier_check
    # _User, _Role etc must remain accessible at the identifier layer
    # (they may be rejected later by agent_hidden or other guards).
    result = @agent.execute(:query_class, class_name: "_User")
    # Whatever the outcome, it must not be the identifier-format
    # rejection — leading underscore is a valid Parse class name.
    if result[:error_code] == :invalid_argument
      flunk "system class _User should pass identifier check, got: #{result[:error]}"
    end
  end

  def test_object_id_with_invalid_characters_is_refused
    result = @agent.execute(:get_object, class_name: "Article",
                                          object_id: "abc'; DROP TABLE--")
    refute result[:success]
    assert_match(/object_id/i, result[:error].to_s)
  end

  def test_object_id_too_long_is_refused
    result = @agent.execute(:get_object, class_name: "Article",
                                          object_id: "a" * 100)
    refute result[:success]
  end

  def test_method_name_with_special_characters_is_refused
    result = @agent.execute(:call_method, class_name: "Article",
                                           method_name: "send; rm -rf /")
    refute result[:success]
    assert_match(/method_name|identifier/i, result[:error].to_s)
  end

  def test_method_name_with_ruby_bang_or_question_passes_identifier_check
    # archive! and valid? are legitimate Ruby method names
    %w[archive! valid? assign=].each do |name|
      Parse::Agent::Tools.send(:assert_method_name!, name)
    end
    pass
  rescue Parse::Agent::ValidationError => e
    flunk "Ruby-style method names should pass: #{e.message}"
  end
end
