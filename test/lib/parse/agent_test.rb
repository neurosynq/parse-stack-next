# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

class AgentTest < Minitest::Test
  def setup
    # Setup a minimal Parse client for testing
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
    @agent = Parse::Agent.new
  end

  # ============================================================
  # Permission Tests
  # ============================================================

  def test_default_permissions_is_readonly
    assert_equal :readonly, @agent.permissions
  end

  def test_readonly_tools_available
    expected_tools = %i[
      get_all_schemas get_schema query_class count_objects
      get_object get_sample_objects aggregate explain_query
      call_method
    ]
    assert_equal expected_tools.sort, @agent.allowed_tools.sort
  end

  def test_write_permissions_include_readonly_and_write
    agent = Parse::Agent.new(permissions: :write)
    assert agent.tool_allowed?(:query_class)
    assert agent.tool_allowed?(:create_object)
    assert agent.tool_allowed?(:update_object)
    refute agent.tool_allowed?(:delete_object)
  end

  def test_admin_permissions_include_all
    agent = Parse::Agent.new(permissions: :admin)
    assert agent.tool_allowed?(:query_class)
    assert agent.tool_allowed?(:create_object)
    assert agent.tool_allowed?(:delete_object)
    assert agent.tool_allowed?(:delete_class)
  end

  def test_permission_denied_for_unauthorized_tool
    result = @agent.execute(:create_object, class_name: "Song", data: {})
    refute result[:success]
    assert_match(/Permission denied/, result[:error])
  end

  # ============================================================
  # MCP Configuration Tests
  # ============================================================

  def test_mcp_disabled_by_default
    refute Parse::Agent.mcp_enabled?
  end

  def test_mcp_can_be_enabled
    original = Parse::Agent.mcp_enabled
    Parse::Agent.mcp_enabled = true
    assert Parse::Agent.mcp_enabled?
  ensure
    Parse::Agent.mcp_enabled = original
  end

  # ============================================================
  # Tool Definition Tests
  # ============================================================

  def test_tool_definitions_openai_format
    definitions = @agent.tool_definitions(format: :openai)
    assert definitions.is_a?(Array)
    assert definitions.all? { |d| d[:type] == "function" }
    assert definitions.all? { |d| d[:function][:name].is_a?(String) }
  end

  def test_tool_definitions_mcp_format
    definitions = @agent.tool_definitions(format: :mcp)
    assert definitions.is_a?(Array)
    assert definitions.all? { |d| d[:name].is_a?(String) }
    assert definitions.all? { |d| d[:inputSchema].is_a?(Hash) }
  end

  def test_tool_definitions_only_includes_allowed_tools
    definitions = @agent.tool_definitions
    tool_names = definitions.map { |d| d[:function][:name] }
    assert_includes tool_names, "query_class"
    refute_includes tool_names, "create_object"
  end

  # ============================================================
  # Session Token Tests
  # ============================================================

  def test_session_token_stored
    agent = Parse::Agent.new(session_token: "r:abc123")
    assert_equal "r:abc123", agent.session_token
  end

  def test_request_opts_with_session_token
    agent = Parse::Agent.new(session_token: "r:abc123")
    opts = agent.request_opts
    assert_equal "r:abc123", opts[:session_token]
    assert_equal false, opts[:use_master_key]
  end

  def test_request_opts_without_session_token
    opts = @agent.request_opts
    assert_empty opts
  end

  # ============================================================
  # Operation Log Tests
  # ============================================================

  def test_operation_log_starts_empty
    assert_empty @agent.operation_log
  end
end

class ConstraintTranslatorTest < Minitest::Test
  def test_simple_equality
    result = Parse::Agent::ConstraintTranslator.translate({ "name" => "John" })
    assert_equal({ "name" => "John" }, result)
  end

  def test_operators_preserved
    input = { "plays" => { "$gte" => 1000, "$lt" => 5000 } }
    result = Parse::Agent::ConstraintTranslator.translate(input)
    assert_equal({ "plays" => { "$gte" => 1000, "$lt" => 5000 } }, result)
  end

  def test_snake_case_to_camel_case
    result = Parse::Agent::ConstraintTranslator.translate({ "created_at" => "2024-01-01" })
    assert_equal({ "createdAt" => "2024-01-01" }, result)
  end

  def test_preserves_underscore_prefix
    result = Parse::Agent::ConstraintTranslator.translate({ "_User" => "test" })
    assert_equal({ "_User" => "test" }, result)
  end

  def test_pointer_type_preserved
    input = {
      "author" => {
        "__type" => "Pointer",
        "className" => "_User",
        "objectId" => "abc123",
      },
    }
    result = Parse::Agent::ConstraintTranslator.translate(input)
    assert_equal input, result
  end

  def test_nested_operators
    input = {
      "score" => { "$in" => [1, 2, 3] },
      "status" => "active",
    }
    result = Parse::Agent::ConstraintTranslator.translate(input)
    assert_equal({ "score" => { "$in" => [1, 2, 3] }, "status" => "active" }, result)
  end

  def test_empty_constraints
    assert_equal({}, Parse::Agent::ConstraintTranslator.translate(nil))
    assert_equal({}, Parse::Agent::ConstraintTranslator.translate({}))
  end
end

class ResultFormatterTest < Minitest::Test
  def test_format_schemas
    schemas = [
      { "className" => "Song", "fields" => { "objectId" => {}, "createdAt" => {}, "updatedAt" => {}, "ACL" => {}, "title" => { "type" => "String" } } },
      { "className" => "_User", "fields" => { "objectId" => {}, "createdAt" => {}, "updatedAt" => {}, "ACL" => {} } },
    ]
    result = Parse::Agent::ResultFormatter.format_schemas(schemas)

    assert_equal 2, result[:total]
    assert_equal 1, result[:custom].size
    assert_equal 1, result[:built_in].size
    assert_equal "Song", result[:custom][0][:name]
    assert_equal 1, result[:custom][0][:fields] # 1 custom field (title)
    assert_equal "_User", result[:built_in][0][:name]
    assert_includes result[:note], "get_schema"
  end

  def test_format_query_results
    results = [
      { "objectId" => "abc", "title" => "Test" },
    ]
    formatted = Parse::Agent::ResultFormatter.format_query_results(
      "Song", results, limit: 100, skip: 0,
    )

    assert_equal "Song", formatted[:class_name]
    assert_equal 1, formatted[:result_count]
    assert_equal false, formatted[:pagination][:has_more]
  end

  def test_format_object
    obj = {
      "objectId" => "abc123",
      "createdAt" => "2024-01-01T00:00:00.000Z",
      "updatedAt" => "2024-01-02T00:00:00.000Z",
      "title" => "Test Song",
    }
    result = Parse::Agent::ResultFormatter.format_object("Song", obj)

    assert_equal "Song", result[:class_name]
    assert_equal "abc123", result[:object_id]
    assert_equal "Test Song", result[:object]["title"]
  end

  def test_simplifies_date_type
    obj = {
      "objectId" => "abc",
      "publishedAt" => {
        "__type" => "Date",
        "iso" => "2024-01-01T00:00:00.000Z",
      },
    }
    result = Parse::Agent::ResultFormatter.format_object("Post", obj)
    assert_equal "2024-01-01T00:00:00.000Z", result[:object]["publishedAt"]
  end

  def test_simplifies_pointer_type
    obj = {
      "objectId" => "abc",
      "author" => {
        "__type" => "Pointer",
        "className" => "_User",
        "objectId" => "user123",
      },
    }
    result = Parse::Agent::ResultFormatter.format_object("Post", obj)
    assert_equal "Pointer", result[:object]["author"][:_type]
    assert_equal "_User", result[:object]["author"][:class]
    assert_equal "user123", result[:object]["author"][:id]
  end

  def test_truncates_large_results
    results = (1..100).map { |i| { "objectId" => "obj#{i}" } }
    formatted = Parse::Agent::ResultFormatter.format_query_results(
      "Song", results, limit: 100, skip: 0,
    )

    assert formatted[:truncated]
    assert_equal 50, formatted[:results].size
    assert_match(/first 50/, formatted[:truncated_note])
  end
end

class MetadataDSLTest < Minitest::Test
  # Define a test model with agent metadata
  class TestTeam < Parse::Object
    parse_class "TestTeam"

    agent_description "A group of users contributing to projects"

    property :name, :string, _description: "The team's display name"
    property :member_count, :integer, _description: "Number of active members"

    agent_readonly :active_projects, "Returns projects currently in progress"
    agent_write :add_member, "Add a new team member"
    agent_admin :delete_all, "Delete all team data"

    def self.active_projects
      # Would query projects
      []
    end

    def add_member(name:)
      # Would add member
      name
    end

    def self.delete_all
      # Would delete
    end
  end

  def test_agent_description
    assert_equal "A group of users contributing to projects", TestTeam.agent_description
  end

  def test_property_descriptions
    descs = TestTeam.property_descriptions
    assert_equal "The team's display name", descs[:name]
    assert_equal "Number of active members", descs[:member_count]
  end

  def test_agent_methods_registered
    methods = TestTeam.agent_methods
    assert methods.key?(:active_projects)
    assert methods.key?(:add_member)
    assert methods.key?(:delete_all)
  end

  def test_agent_method_permissions
    methods = TestTeam.agent_methods
    assert_equal :readonly, methods[:active_projects][:permission]
    assert_equal :write, methods[:add_member][:permission]
    assert_equal :admin, methods[:delete_all][:permission]
  end

  def test_agent_method_descriptions
    methods = TestTeam.agent_methods
    assert_equal "Returns projects currently in progress", methods[:active_projects][:description]
    assert_equal "Add a new team member", methods[:add_member][:description]
  end

  def test_agent_can_call_readonly
    assert TestTeam.agent_can_call?(:active_projects, :readonly)
    refute TestTeam.agent_can_call?(:add_member, :readonly)
    refute TestTeam.agent_can_call?(:delete_all, :readonly)
  end

  def test_agent_can_call_write
    assert TestTeam.agent_can_call?(:active_projects, :write)
    assert TestTeam.agent_can_call?(:add_member, :write)
    refute TestTeam.agent_can_call?(:delete_all, :write)
  end

  def test_agent_can_call_admin
    assert TestTeam.agent_can_call?(:active_projects, :admin)
    assert TestTeam.agent_can_call?(:add_member, :admin)
    assert TestTeam.agent_can_call?(:delete_all, :admin)
  end

  def test_agent_methods_for_readonly
    methods = TestTeam.agent_methods_for(:readonly)
    assert_equal [:active_projects], methods.keys
  end

  def test_agent_methods_for_write
    methods = TestTeam.agent_methods_for(:write)
    assert_includes methods.keys, :active_projects
    assert_includes methods.keys, :add_member
    refute_includes methods.keys, :delete_all
  end

  def test_agent_methods_for_admin
    methods = TestTeam.agent_methods_for(:admin)
    assert_includes methods.keys, :active_projects
    assert_includes methods.keys, :add_member
    assert_includes methods.keys, :delete_all
  end

  def test_has_agent_metadata
    assert TestTeam.has_agent_metadata?
  end

  def test_agent_method_allowed
    assert TestTeam.agent_method_allowed?(:active_projects)
    assert TestTeam.agent_method_allowed?(:add_member)
    refute TestTeam.agent_method_allowed?(:nonexistent_method)
  end
end

# ============================================================
# Sensitive Key Sanitization Tests
# ============================================================
class AgentLoggingSanitizationTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
    @agent = Parse::Agent.new
  end

  def test_sensitive_log_keys_constant_exists
    assert_kind_of Array, Parse::Agent::SENSITIVE_LOG_KEYS
    assert_includes Parse::Agent::SENSITIVE_LOG_KEYS, :session_token
    assert_includes Parse::Agent::SENSITIVE_LOG_KEYS, :password
    assert_includes Parse::Agent::SENSITIVE_LOG_KEYS, :secret
    assert_includes Parse::Agent::SENSITIVE_LOG_KEYS, :token
    assert_includes Parse::Agent::SENSITIVE_LOG_KEYS, :api_key
    assert_includes Parse::Agent::SENSITIVE_LOG_KEYS, :master_key
    assert_includes Parse::Agent::SENSITIVE_LOG_KEYS, :auth_data
    assert_includes Parse::Agent::SENSITIVE_LOG_KEYS, :authData
    assert_includes Parse::Agent::SENSITIVE_LOG_KEYS, :recovery_codes
  end

  def test_log_operation_excludes_session_token
    # Access private method for testing
    @agent.send(:log_operation, :test_tool, { class_name: "Song", session_token: "r:secret123" }, {})

    log_entry = @agent.operation_log.last
    refute log_entry[:args].key?(:session_token), "session_token should not be logged"
    assert_equal "Song", log_entry[:args][:class_name], "non-sensitive args should be logged"
  end

  def test_log_operation_excludes_password
    @agent.send(:log_operation, :test_tool, { username: "john", password: "secret123" }, {})

    log_entry = @agent.operation_log.last
    refute log_entry[:args].key?(:password), "password should not be logged"
    assert_equal "john", log_entry[:args][:username], "non-sensitive args should be logged"
  end

  def test_log_operation_excludes_multiple_sensitive_keys
    sensitive_args = {
      class_name: "User",
      session_token: "r:abc123",
      password: "secret",
      secret: "totp_secret",
      token: "mfa_token",
      api_key: "key123",
      master_key: "master123",
      auth_data: { mfa: {} },
      authData: { mfa: {} },
      recovery_codes: "ABC123",
      where: { name: "test" },
      pipeline: [{ "$match" => {} }],
    }

    @agent.send(:log_operation, :test_tool, sensitive_args, {})

    log_entry = @agent.operation_log.last
    assert_equal "User", log_entry[:args][:class_name], "class_name should be logged"

    Parse::Agent::SENSITIVE_LOG_KEYS.each do |key|
      refute log_entry[:args].key?(key), "#{key} should not be logged"
    end
  end

  def test_log_operation_preserves_non_sensitive_args
    @agent.send(:log_operation, :query_class, {
      class_name: "Song",
      limit: 10,
      skip: 0,
      order: "-createdAt",
    }, {})

    log_entry = @agent.operation_log.last
    assert_equal "Song", log_entry[:args][:class_name]
    assert_equal 10, log_entry[:args][:limit]
    assert_equal 0, log_entry[:args][:skip]
    assert_equal "-createdAt", log_entry[:args][:order]
  end

  def test_log_entry_has_required_fields
    @agent.send(:log_operation, :test_tool, { class_name: "Song" }, {})

    log_entry = @agent.operation_log.last
    assert_equal :test_tool, log_entry[:tool]
    assert log_entry[:timestamp].present?, "should have timestamp"
    assert_equal true, log_entry[:success]
    assert log_entry.key?(:auth_type), "should have auth_type"
    assert log_entry.key?(:using_master_key), "should have using_master_key"
    assert log_entry.key?(:permissions), "should have permissions"
  end
end

# ============================================================
# Rate Limiter Tests
# ============================================================
class AgentRateLimiterTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
  end

  def test_agent_has_rate_limiter
    agent = Parse::Agent.new
    assert_kind_of Parse::Agent::RateLimiter, agent.rate_limiter
  end

  def test_custom_rate_limit_configuration
    agent = Parse::Agent.new(rate_limit: 100, rate_window: 120)
    assert_equal 100, agent.rate_limiter.limit
    assert_equal 120, agent.rate_limiter.window
  end

  def test_default_rate_limit_values
    agent = Parse::Agent.new
    assert_equal Parse::Agent::DEFAULT_RATE_LIMIT, agent.rate_limiter.limit
    assert_equal Parse::Agent::DEFAULT_RATE_WINDOW, agent.rate_limiter.window
  end
end

# ============================================================
# Malformed Tool Call Handling Tests
# ============================================================
class AgentMalformedToolCallTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
    @agent = Parse::Agent.new
  end

  # Test that the safe navigation pattern correctly handles nil tool_call
  def test_nil_tool_call_dig_returns_nil
    tool_call = nil
    function = tool_call&.dig("function")
    assert_nil function, "nil tool_call should return nil function"
  end

  # Test that the safe navigation pattern handles missing function key
  def test_tool_call_without_function_key
    tool_call = { "id" => "call_123", "type" => "function" }
    function = tool_call&.dig("function")
    assert_nil function, "tool_call without function key should return nil"
  end

  # Test that normal tool_call structure works
  def test_valid_tool_call_structure
    tool_call = {
      "id" => "call_123",
      "type" => "function",
      "function" => {
        "name" => "query_class",
        "arguments" => '{"class_name": "Song"}',
      },
    }
    function = tool_call&.dig("function")
    assert_equal "query_class", function["name"]
    assert_equal '{"class_name": "Song"}', function["arguments"]
  end

  # Test that missing arguments defaults to empty hash
  def test_missing_arguments_defaults_to_empty
    function = { "name" => "get_all_schemas" }
    args = JSON.parse(function["arguments"] || "{}")
    assert_equal({}, args, "missing arguments should default to empty hash")
  end

  # Test that nil arguments defaults to empty hash
  def test_nil_arguments_defaults_to_empty
    function = { "name" => "get_all_schemas", "arguments" => nil }
    args = JSON.parse(function["arguments"] || "{}")
    assert_equal({}, args, "nil arguments should default to empty hash")
  end

  # Test that valid arguments are parsed correctly
  def test_valid_arguments_are_parsed
    function = { "name" => "query_class", "arguments" => '{"class_name": "Song", "limit": 10}' }
    args = JSON.parse(function["arguments"] || "{}")
    assert_equal({ "class_name" => "Song", "limit" => 10 }, args)
  end

  # Test the full pattern we use in the code
  def test_full_malformed_tool_call_handling_pattern
    malformed_tool_calls = [
      nil,
      {},
      { "id" => "123" },
      { "function" => nil },
      { "function" => {} },
      { "function" => { "name" => nil } },
    ]

    valid_count = 0

    malformed_tool_calls.each do |tool_call|
      function = tool_call&.dig("function")
      next unless function

      tool_name = function["name"]
      next unless tool_name

      # This should not be reached for malformed calls
      valid_count += 1
    end

    assert_equal 0, valid_count, "all malformed tool calls should be skipped"
  end

  def test_valid_tool_call_passes_through_pattern
    valid_tool_call = {
      "id" => "call_123",
      "function" => {
        "name" => "query_class",
        "arguments" => '{"class_name": "Song"}',
      },
    }

    processed = false

    function = valid_tool_call&.dig("function")
    if function
      tool_name = function["name"]
      if tool_name
        processed = true
      end
    end

    assert processed, "valid tool call should be processed"
  end
end
