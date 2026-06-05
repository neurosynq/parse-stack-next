# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent"

class ToolsRegistrationTest < Minitest::Test
  T = Parse::Agent::Tools

  def setup
    T.reset_registry!
    # Ensure a minimal Parse client exists
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
  end

  def teardown
    T.reset_registry!
    T.reset_subscribers!
    # Reset refuse_collscan to default
    Parse::Agent.refuse_collscan = false
  end

  # -------------------------------------------------------------------------
  # subscribe / notify_subscribers (v4.2 listChanged broadcast)
  # -------------------------------------------------------------------------

  def test_subscribe_fires_callback_on_register
    fired = 0
    T.subscribe { fired += 1 }

    T.register(
      name: :sub_tool, description: "x",
      parameters: { "type" => "object" }, permission: :readonly,
      handler: ->(_a, **) { {} },
    )

    assert_equal 1, fired
  end

  def test_subscribe_fires_callback_on_reset_registry
    fired = 0
    T.subscribe { fired += 1 }

    T.reset_registry!
    assert_equal 1, fired, "reset_registry! must notify subscribers"
  end

  def test_subscribe_returns_deregister_proc
    fired = 0
    unsub = T.subscribe { fired += 1 }

    T.register(
      name: :sub_tool_a, description: "x",
      parameters: { "type" => "object" }, permission: :readonly,
      handler: ->(_a, **) { {} },
    )
    assert_equal 1, fired

    unsub.call

    T.register(
      name: :sub_tool_b, description: "x",
      parameters: { "type" => "object" }, permission: :readonly,
      handler: ->(_a, **) { {} },
    )
    assert_equal 1, fired,
                 "Deregistered subscriber must not fire on subsequent register"
  end

  def test_subscriber_exception_does_not_break_other_subscribers
    fired_b = 0
    T.subscribe { raise "subscriber A crashed" }
    T.subscribe { fired_b += 1 }

    original_stderr = $stderr
    $stderr = StringIO.new

    T.register(
      name: :sub_tool_x, description: "x",
      parameters: { "type" => "object" }, permission: :readonly,
      handler: ->(_a, **) { {} },
    )

    assert_equal 1, fired_b,
                 "Subscriber B must still fire even when subscriber A raises"
    assert_includes $stderr.string, "subscriber raised"
  ensure
    $stderr = original_stderr
  end

  # -------------------------------------------------------------------------
  # output_schema (v4.2 structuredContent support)
  # -------------------------------------------------------------------------

  def test_register_accepts_output_schema
    schema = { "type" => "object", "properties" => { "n" => { "type" => "integer" } } }
    T.register(
      name: :with_schema, description: "x",
      parameters: { "type" => "object" }, permission: :readonly,
      output_schema: schema,
      handler: ->(_a, **) { { n: 1 } },
    )

    assert_equal schema, T.output_schema_for(:with_schema)
  end

  def test_register_rejects_non_hash_output_schema
    assert_raises(ArgumentError) do
      T.register(
        name: :bad_schema, description: "x",
        parameters: { "type" => "object" }, permission: :readonly,
        output_schema: "not a hash",
        handler: ->(_a, **) { {} },
      )
    end
  end

  def test_output_schema_for_returns_nil_when_not_declared
    T.register(
      name: :no_schema, description: "x",
      parameters: { "type" => "object" }, permission: :readonly,
      handler: ->(_a, **) { {} },
    )

    assert_nil T.output_schema_for(:no_schema)
  end

  def test_output_schema_appears_in_mcp_tool_definition
    schema = { "type" => "object", "properties" => { "ok" => { "type" => "boolean" } } }
    T.register(
      name: :tool_with_schema, description: "x",
      parameters: { "type" => "object" }, permission: :readonly,
      output_schema: schema,
      handler: ->(_a, **) { { ok: true } },
    )

    defs = T.definitions([:tool_with_schema], format: :mcp)
    assert_equal 1, defs.size
    assert_equal schema, defs.first[:outputSchema]
  end

  # -------------------------------------------------------------------------
  # register — happy path
  # -------------------------------------------------------------------------

  def test_register_adds_tool_to_all_tool_names
    T.register(
      name: :my_custom,
      description: "A custom tool",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      handler: ->(_agent, **_args) { { result: "ok" } },
    )
    assert_includes T.all_tool_names, :my_custom
  end

  def test_register_idempotent_replaces_previous_registration
    T.register(
      name: :my_custom,
      description: "First",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      handler: ->(_agent, **_args) { { result: "first" } },
    )
    T.register(
      name: :my_custom,
      description: "Second",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :write,
      handler: ->(_agent, **_args) { { result: "second" } },
    )
    # Permission should reflect the latest registration
    assert_equal :write, T.permission_for(:my_custom)
  end

  # -------------------------------------------------------------------------
  # reset_registry!
  # -------------------------------------------------------------------------

  def test_reset_registry_removes_registered_tools
    T.register(
      name: :temp_tool,
      description: "Temp",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      handler: ->(_agent, **_args) { {} },
    )
    assert_includes T.all_tool_names, :temp_tool
    T.reset_registry!
    refute_includes T.all_tool_names, :temp_tool
  end

  def test_reset_registry_does_not_remove_builtins
    T.register(
      name: :temp_tool,
      description: "Temp",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      handler: ->(_agent, **_args) { {} },
    )
    T.reset_registry!
    assert_includes T.all_tool_names, :query_class
    assert_includes T.all_tool_names, :get_all_schemas
  end

  # -------------------------------------------------------------------------
  # definitions — registered tools merged with builtins
  # -------------------------------------------------------------------------

  def test_registered_tool_appears_in_definitions
    T.register(
      name: :breakdown_captures,
      description: "Count captures grouped by user",
      parameters: { type: "object", properties: { group: { type: "string" } }, required: ["group"] },
      permission: :readonly,
      handler: ->(_agent, **_args) { { count: 0 } },
    )

    agent = Parse::Agent.new(permissions: :readonly)
    defs = agent.tool_definitions(format: :openai)
    names = defs.map { |d| d[:function][:name] }
    assert_includes names, "breakdown_captures"
  end

  def test_registered_tool_appears_in_mcp_definitions
    T.register(
      name: :breakdown_captures,
      description: "Count captures grouped by user",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      handler: ->(_agent, **_args) { {} },
    )
    agent = Parse::Agent.new(permissions: :readonly)
    defs = agent.tool_definitions(format: :mcp)
    names = defs.map { |d| d[:name] }
    assert_includes names, "breakdown_captures"
  end

  def test_definitions_includes_builtins_with_registered
    T.register(
      name: :my_extra,
      description: "Extra",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      handler: ->(_agent, **_args) { {} },
    )
    agent = Parse::Agent.new(permissions: :readonly)
    names = agent.tool_definitions(format: :openai).map { |d| d[:function][:name] }
    assert_includes names, "query_class"
    assert_includes names, "my_extra"
  end

  # -------------------------------------------------------------------------
  # all_tool_names
  # -------------------------------------------------------------------------

  def test_all_tool_names_includes_builtins
    names = T.all_tool_names
    %i[get_all_schemas query_class get_objects aggregate explain_query].each do |n|
      assert_includes names, n
    end
  end

  def test_all_tool_names_includes_registered
    T.register(
      name: :new_tool,
      description: "New",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :admin,
      handler: ->(_agent, **_args) { {} },
    )
    assert_includes T.all_tool_names, :new_tool
  end

  # -------------------------------------------------------------------------
  # invoke — dispatch routing
  # -------------------------------------------------------------------------

  def test_invoke_dispatches_to_registered_handler
    captured_agent = nil
    captured_args  = nil
    T.register(
      name: :my_dispatch,
      description: "Dispatch test",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      handler: ->(agent, **args) {
        captured_agent = agent
        captured_args  = args
        { dispatched: true }
      },
    )

    agent = Parse::Agent.new
    result = T.invoke(agent, :my_dispatch, foo: "bar")
    assert_equal({ dispatched: true }, result)
    assert_equal agent, captured_agent
    assert_equal({ foo: "bar" }, captured_args)
  end

  def test_invoke_string_name_dispatches_to_registered_handler
    T.register(
      name: :str_dispatch,
      description: "String name dispatch",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      handler: ->(_agent, **_args) { { ok: true } },
    )
    agent = Parse::Agent.new
    result = T.invoke(agent, "str_dispatch")
    assert_equal({ ok: true }, result)
  end

  # -------------------------------------------------------------------------
  # invoke — registered-handler timeout enforcement
  # -------------------------------------------------------------------------

  # A custom handler that runs past its declared timeout is interrupted with
  # ToolTimeoutError — the bound is enforced by Tools.invoke's with_timeout
  # wrap, not left to the handler. Proves the orphan-bounding contract holds
  # for custom tools (previously the handler ran unbounded).
  def test_invoke_enforces_registered_handler_timeout
    T.register(
      name: :slow_custom,
      description: "Sleeps past its timeout",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      timeout: 1,
      handler: ->(_agent, **_args) { sleep 2; { ok: true } },
    )
    agent = Parse::Agent.new
    assert_raises(Parse::Agent::ToolTimeoutError) do
      T.invoke(agent, :slow_custom)
    end
  end

  # A fast handler well under its timeout must NOT be falsely interrupted.
  def test_invoke_does_not_time_out_fast_registered_handler
    T.register(
      name: :fast_custom,
      description: "Returns immediately",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      timeout: 5,
      handler: ->(_agent, **_args) { { ok: true } },
    )
    agent = Parse::Agent.new
    assert_equal({ ok: true }, T.invoke(agent, :fast_custom))
  end

  # register refuses a non-positive timeout: Timeout.timeout(0) would silently
  # disable the bound, so the registration must fail loudly at boot.
  def test_register_rejects_non_positive_timeout
    %i[zero fractional negative].zip([0, 0.5, -3]).each do |label, value|
      err = assert_raises(ArgumentError, "timeout: #{value.inspect} (#{label}) should raise") do
        T.register(
          name: :bad_timeout,
          description: "x",
          parameters: { type: "object", properties: {}, required: [] },
          permission: :readonly,
          timeout: value,
          handler: ->(_a, **) { {} },
        )
      end
      assert_match(/timeout must be a positive integer/, err.message)
    end
  end

  # -------------------------------------------------------------------------
  # permission_for
  # -------------------------------------------------------------------------

  def test_permission_for_registered_tool
    T.register(
      name: :write_tool,
      description: "Write",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :write,
      handler: ->(_agent, **_args) { {} },
    )
    assert_equal :write, T.permission_for(:write_tool)
  end

  def test_permission_for_builtin_readonly
    assert_equal :readonly, T.permission_for(:query_class)
    assert_equal :readonly, T.permission_for(:get_objects)
  end

  def test_permission_for_builtin_admin
    assert_equal :admin, T.permission_for(:delete_object)
  end

  def test_permission_for_unknown_returns_unknown
    assert_equal :unknown, T.permission_for(:nonexistent_tool)
  end

  # -------------------------------------------------------------------------
  # timeout_for
  # -------------------------------------------------------------------------

  def test_timeout_for_registered_tool_uses_declared_value
    T.register(
      name: :slow_tool,
      description: "Slow",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      timeout: 90,
      handler: ->(_agent, **_args) { {} },
    )
    assert_equal 90, T.timeout_for(:slow_tool)
  end

  def test_timeout_for_registered_tool_default_is_30
    T.register(
      name: :fast_tool,
      description: "Fast",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      handler: ->(_agent, **_args) { {} },
    )
    assert_equal 30, T.timeout_for(:fast_tool)
  end

  def test_timeout_for_builtin_uses_tool_timeouts_table
    assert_equal 60, T.timeout_for(:aggregate)
    assert_equal 30, T.timeout_for(:query_class)
  end

  def test_timeout_for_unknown_returns_default
    assert_equal Parse::Agent::Tools::DEFAULT_TIMEOUT, T.timeout_for(:no_such_tool)
  end

  # -------------------------------------------------------------------------
  # Permission gating — readonly agent rejects write tool
  # -------------------------------------------------------------------------

  def test_write_registered_tool_rejected_for_readonly_agent
    T.register(
      name: :protected_write,
      description: "Write op",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :write,
      handler: ->(_agent, **_args) { { did_write: true } },
    )

    agent = Parse::Agent.new(permissions: :readonly)
    refute agent.tool_allowed?(:protected_write),
           "readonly agent should not be allowed to call a write-permission registered tool"
  end

  def test_write_registered_tool_allowed_for_write_agent
    T.register(
      name: :allowed_write,
      description: "Write op",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :write,
      handler: ->(_agent, **_args) { { did_write: true } },
    )

    agent = Parse::Agent.new(permissions: :write)
    assert agent.tool_allowed?(:allowed_write)
  end

  def test_readonly_agent_execute_returns_permission_denied_for_write_tool
    T.register(
      name: :write_guarded,
      description: "Guarded write",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :write,
      handler: ->(_agent, **_args) { { secret: true } },
    )

    agent = Parse::Agent.new(permissions: :readonly)
    result = agent.execute(:write_guarded)
    refute result[:success]
    assert_match(/Permission denied/, result[:error])
  end

  # -------------------------------------------------------------------------
  # Registered handler raising ValidationError flows to :invalid_argument
  # -------------------------------------------------------------------------

  def test_registered_handler_validation_error_maps_to_invalid_argument
    T.register(
      name: :bad_args_tool,
      description: "Raises validation error",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      handler: ->(_agent, **_args) {
        raise Parse::Agent::ValidationError, "bad input detected"
      },
    )

    agent = Parse::Agent.new(permissions: :readonly)
    result = agent.execute(:bad_args_tool)
    refute result[:success]
    assert_equal :invalid_argument, result[:error_code]
    assert_match(/bad input detected/, result[:error])
  end

  # -------------------------------------------------------------------------
  # register raises ArgumentError for missing required kwargs
  # -------------------------------------------------------------------------

  def test_register_raises_for_invalid_permission
    assert_raises(ArgumentError) do
      T.register(
        name: :bad_perm,
        description: "Bad",
        parameters: {},
        permission: :superadmin,
        handler: ->(_a, **_k) { {} },
      )
    end
  end

  def test_register_raises_for_non_callable_handler
    assert_raises(ArgumentError) do
      T.register(
        name: :bad_handler,
        description: "Bad",
        parameters: {},
        permission: :readonly,
        handler: "not a proc",
      )
    end
  end

  def test_register_raises_for_missing_name
    assert_raises(ArgumentError) do
      T.register(
        name: nil,
        description: "Missing name",
        parameters: {},
        permission: :readonly,
        handler: ->(_a, **_k) { {} },
      )
    end
  end

  def test_register_raises_for_missing_description
    assert_raises(ArgumentError) do
      T.register(
        name: :no_desc,
        description: "",
        parameters: {},
        permission: :readonly,
        handler: ->(_a, **_k) { {} },
      )
    end
  end

  # -------------------------------------------------------------------------
  # registered_tools_for permission level
  # -------------------------------------------------------------------------

  def test_registered_tools_for_readonly_excludes_admin_tools
    T.register(
      name: :admin_custom,
      description: "Admin",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :admin,
      handler: ->(_a, **_k) { {} },
    )
    readonly_registered = T.registered_tools_for(:readonly)
    refute_includes readonly_registered, :admin_custom
  end

  def test_registered_tools_for_admin_includes_all_levels
    T.register(
      name: :ro_custom,
      description: "RO",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :readonly,
      handler: ->(_a, **_k) { {} },
    )
    T.register(
      name: :admin_custom,
      description: "Admin",
      parameters: { type: "object", properties: {}, required: [] },
      permission: :admin,
      handler: ->(_a, **_k) { {} },
    )
    admin_registered = T.registered_tools_for(:admin)
    assert_includes admin_registered, :ro_custom
    assert_includes admin_registered, :admin_custom
  end

  # -------------------------------------------------------------------------
  # validate_include! — query_class and get_object include parameter validation
  # -------------------------------------------------------------------------

  def setup_agent
    Parse::Agent.new(permissions: :readonly)
  end

  def test_query_class_include_underscore_prefix_raises_validation_error
    agent = setup_agent
    assert_raises(Parse::Agent::ValidationError) do
      T.query_class(agent, class_name: "Song", include: ["_session_token"])
    end
  end

  def test_query_class_include_entry_too_long_raises_validation_error
    agent = setup_agent
    assert_raises(Parse::Agent::ValidationError) do
      T.query_class(agent, class_name: "Song", include: ["a" * 200])
    end
  end

  def test_query_class_include_array_exceeds_limit_raises_validation_error
    agent = setup_agent
    assert_raises(Parse::Agent::ValidationError) do
      T.query_class(agent, class_name: "Song", include: Array.new(25) { "foo" })
    end
  end

  def test_query_class_include_nil_does_not_raise
    agent = setup_agent
    fake_response = Minitest::Mock.new
    fake_response.expect(:success?, true)
    fake_response.expect(:results, [])
    agent.client.stub(:find_objects, fake_response) do
      result = T.query_class(agent, class_name: "Song", include: nil)
      assert_kind_of Hash, result
    end
  end

  def test_get_object_include_underscore_prefix_raises_validation_error
    agent = setup_agent
    assert_raises(Parse::Agent::ValidationError) do
      T.get_object(agent, class_name: "Song", object_id: "abc1234567", include: ["_session_token"])
    end
  end

  def test_get_object_include_entry_too_long_raises_validation_error
    agent = setup_agent
    assert_raises(Parse::Agent::ValidationError) do
      T.get_object(agent, class_name: "Song", object_id: "abc1234567", include: ["a" * 200])
    end
  end

  def test_get_object_include_array_exceeds_limit_raises_validation_error
    agent = setup_agent
    assert_raises(Parse::Agent::ValidationError) do
      T.get_object(agent, class_name: "Song", object_id: "abc1234567", include: Array.new(25) { "foo" })
    end
  end

  def test_get_object_include_nil_does_not_raise
    agent = setup_agent
    fake_response = Minitest::Mock.new
    fake_response.expect(:success?, true)
    fake_response.expect(:result, { "objectId" => "abc1234567" })
    agent.client.stub(:fetch_object, fake_response) do
      result = T.get_object(agent, class_name: "Song", object_id: "abc1234567", include: nil)
      assert_kind_of Hash, result
    end
  end

  # -------------------------------------------------------------------------
  # permissions: alias for permission: (consistency with Agent.new)
  # -------------------------------------------------------------------------

  def test_register_accepts_permissions_alias
    T.register(
      name: :alias_tool, description: "x",
      parameters: { "type" => "object" }, permissions: :write,
      handler: ->(_a, **) { {} },
    )
    assert_equal :write, T.permission_for(:alias_tool)
  end

  def test_register_without_permission_or_alias_raises
    err = assert_raises(ArgumentError) do
      T.register(
        name: :no_perm_tool, description: "x",
        parameters: { "type" => "object" },
        handler: ->(_a, **) { {} },
      )
    end
    assert_match(/permission/, err.message)
  end
end
