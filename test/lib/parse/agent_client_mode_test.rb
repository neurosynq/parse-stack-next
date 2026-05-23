# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

class AgentClientModeTest < Minitest::Test
  FAKE_SESSION = "r:client_mode_test_token"

  class ClientModeHiddenFixture < Parse::Object
    parse_class "ClientModeHiddenFixture"
    property :secret, :string
    agent_hidden
  end

  class ClientModeHiddenFixture2 < Parse::Object
    parse_class "ClientModeHiddenFixture2"
    property :secret, :string
    agent_hidden
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
    # Default test client has no master_key — exactly the client-mode posture.
    refute Parse::Client.client.master_key,
           "test client must have no master_key for these tests to exercise client mode"

    Parse::Agent::Tools.reset_registry!
  end

  def teardown
    Parse::Agent::Tools.reset_registry!
  end

  # ============================================================
  # Detection
  # ============================================================

  def test_no_master_key_with_session_token_is_client_mode
    agent = Parse::Agent.new(session_token: FAKE_SESSION)
    assert agent.client_mode?
  end

  def test_no_master_key_without_session_token_is_not_client_mode
    # Back-compat: existing master-key-posture construction is preserved
    # (those tools will fail at REST dispatch, but the agent itself does
    # not refuse construction).
    agent = Parse::Agent.new
    refute agent.client_mode?
  end

  def test_acl_user_refused_on_no_master_key_client
    user = Parse::User.pointer("abc1234567")
    assert_raises(ArgumentError) do
      Parse::Agent.new(acl_user: user)
    end
  end

  def test_acl_role_refused_on_no_master_key_client
    assert_raises(ArgumentError) do
      Parse::Agent.new(acl_role: "admin")
    end
  end

  # ============================================================
  # Tool ceiling — refused tools
  # ============================================================

  def test_client_mode_refuses_call_method
    agent = Parse::Agent.new(session_token: FAKE_SESSION)
    result = agent.execute(:call_method, class_name: "Post", method_name: "foo")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_match(/client-mode agents/, result[:error])
  end

  def test_client_mode_refuses_aggregate
    agent = Parse::Agent.new(permissions: :admin, session_token: FAKE_SESSION)
    result = agent.execute(:aggregate, class_name: "Post", pipeline: [])
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  def test_client_mode_refuses_atlas_text_search
    agent = Parse::Agent.new(session_token: FAKE_SESSION)
    result = agent.execute(:atlas_text_search, class_name: "Post", query: "x")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  def test_client_mode_refuses_get_all_schemas
    agent = Parse::Agent.new(session_token: FAKE_SESSION)
    result = agent.execute(:get_all_schemas)
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  # ============================================================
  # Tool ceiling — allowed tools (verified by gate-passage, not dispatch)
  # ============================================================

  def test_client_mode_allows_query_class_at_gate
    # We don't have a live Parse Server in unit tests, so verify the
    # client-mode gate doesn't refuse — the call may fail downstream
    # on network, but with a different error_code (not :access_denied
    # from the client-mode ceiling).
    agent = Parse::Agent.new(session_token: FAKE_SESSION)
    result = agent.execute(:query_class, class_name: "Post")
    if result[:success] == false
      refute_match(/client-mode agents/, result[:error].to_s,
                   "query_class should pass the client-mode ceiling")
    end
  end

  def test_client_mode_allows_list_tools
    agent = Parse::Agent.new(session_token: FAKE_SESSION)
    result = agent.execute(:list_tools)
    assert result[:success], "list_tools should succeed in client mode: #{result[:error]}"
  end

  # ============================================================
  # Mutation gate
  # ============================================================

  def test_client_mode_refuses_create_object_without_allow_mutations
    agent = Parse::Agent.new(permissions: :write, session_token: FAKE_SESSION)
    result = agent.execute(:create_object, class_name: "Post", data: { title: "x" })
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_match(/allow_mutations/, result[:error])
  end

  def test_client_mode_allow_mutations_default_is_false
    agent = Parse::Agent.new(permissions: :write, session_token: FAKE_SESSION)
    refute agent.allow_mutations?
  end

  def test_master_key_mode_allow_mutations_default_is_true
    # In master-key posture (no session_token), back-compat default is true.
    agent = Parse::Agent.new(permissions: :write)
    assert agent.allow_mutations?
  end

  def test_explicit_allow_mutations_honored_in_client_mode
    agent = Parse::Agent.new(
      permissions: :write,
      session_token: FAKE_SESSION,
      allow_mutations: true,
    )
    assert agent.allow_mutations?
  end

  # ============================================================
  # Sub-agent subset check
  # ============================================================

  def test_subagent_cannot_widen_allow_mutations
    parent = Parse::Agent.new(
      permissions: :write,
      session_token: FAKE_SESSION,
      allow_mutations: false,
    )
    assert_raises(ArgumentError) do
      Parse::Agent.new(parent: parent, allow_mutations: true)
    end
  end

  def test_subagent_inherits_allow_mutations_when_omitted
    parent = Parse::Agent.new(
      permissions: :write,
      session_token: FAKE_SESSION,
      allow_mutations: true,
    )
    child = Parse::Agent.new(parent: parent)
    assert child.allow_mutations?
  end

  def test_subagent_can_narrow_allow_mutations
    parent = Parse::Agent.new(
      permissions: :write,
      session_token: FAKE_SESSION,
      allow_mutations: true,
    )
    child = Parse::Agent.new(parent: parent, allow_mutations: false)
    refute child.allow_mutations?
  end

  # ============================================================
  # Custom tools
  # ============================================================

  def test_custom_tool_refused_in_client_mode_without_client_safe_flag
    Parse::Agent::Tools.register(
      name:        :my_unsafe_tool,
      description: "test tool",
      parameters:  { type: "object", properties: {} },
      permission:  :readonly,
      handler:     ->(_agent, **_args) { { result: "ok" } },
    )
    agent = Parse::Agent.new(session_token: FAKE_SESSION,
                             tools: { only: [:my_unsafe_tool] })
    result = agent.execute(:my_unsafe_tool)
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_match(/client-mode agents/, result[:error])
  end

  def test_custom_tool_allowed_in_client_mode_with_client_safe_flag
    Parse::Agent::Tools.register(
      name:        :my_safe_tool,
      description: "test tool",
      parameters:  { type: "object", properties: {} },
      permission:  :readonly,
      client_safe: true,
      handler:     ->(_agent, **_args) { { result: "ok" } },
    )
    agent = Parse::Agent.new(session_token: FAKE_SESSION,
                             tools: { only: [:my_safe_tool] })
    result = agent.execute(:my_safe_tool)
    assert result[:success], "client_safe registered tool should dispatch: #{result[:error]}"
  end

  def test_tools_client_safe_predicate
    assert Parse::Agent::Tools.client_safe?(:query_class)
    assert Parse::Agent::Tools.client_safe?(:create_object)
    refute Parse::Agent::Tools.client_safe?(:call_method)
    refute Parse::Agent::Tools.client_safe?(:aggregate)
    refute Parse::Agent::Tools.client_safe?(:atlas_text_search)
    refute Parse::Agent::Tools.client_safe?(:get_all_schemas)
  end

  # ============================================================
  # Advertised catalog matches dispatchable set
  # ============================================================

  def test_allowed_tools_in_client_mode_excludes_refused_builtins
    agent = Parse::Agent.new(session_token: FAKE_SESSION)
    tools = agent.allowed_tools
    refute_includes tools, :call_method
    refute_includes tools, :aggregate
    refute_includes tools, :atlas_text_search
    refute_includes tools, :atlas_autocomplete
    refute_includes tools, :atlas_faceted_search
    refute_includes tools, :get_all_schemas
    refute_includes tools, :get_schema
    refute_includes tools, :explain_query
    refute_includes tools, :export_data
    refute_includes tools, :group_by
    refute_includes tools, :group_by_date
    refute_includes tools, :distinct
    assert_includes tools, :query_class
    assert_includes tools, :get_object
    assert_includes tools, :count_objects
  end

  def test_allowed_tools_in_client_mode_excludes_mutation_without_allow_mutations
    agent = Parse::Agent.new(permissions: :write, session_token: FAKE_SESSION)
    tools = agent.allowed_tools
    refute_includes tools, :create_object
    refute_includes tools, :update_object
    refute_includes tools, :delete_object
  end

  def test_allowed_tools_in_client_mode_includes_mutations_with_allow_mutations
    agent = Parse::Agent.new(
      permissions: :write,
      session_token: FAKE_SESSION,
      allow_mutations: true,
    )
    tools = agent.allowed_tools
    assert_includes tools, :create_object
    assert_includes tools, :update_object
  end

  def test_tool_definitions_in_client_mode_match_allowed_tools
    agent = Parse::Agent.new(session_token: FAKE_SESSION)
    advertised = agent.tool_definitions(format: :openai).map { |d| d[:function][:name].to_sym }
    # Catalog the LLM sees must be ⊆ dispatchable set — otherwise the LLM
    # would attempt refused tools and waste turns on access-denied errors.
    extras = advertised - agent.allowed_tools
    assert_empty extras,
                 "tool_definitions advertised tools not in allowed_tools: #{extras.inspect}"
  end

  def test_allowed_tools_includes_client_safe_registered_tool
    Parse::Agent::Tools.register(
      name:        :advertised_safe_tool,
      description: "test",
      parameters:  { type: "object", properties: {} },
      permission:  :readonly,
      client_safe: true,
      handler:     ->(_a, **_k) { { result: "ok" } },
    )
    agent = Parse::Agent.new(session_token: FAKE_SESSION)
    assert_includes agent.allowed_tools, :advertised_safe_tool
  end

  def test_allowed_tools_excludes_non_client_safe_registered_tool
    Parse::Agent::Tools.register(
      name:        :advertised_unsafe_tool,
      description: "test",
      parameters:  { type: "object", properties: {} },
      permission:  :readonly,
      handler:     ->(_a, **_k) { { result: "ok" } },
    )
    agent = Parse::Agent.new(session_token: FAKE_SESSION)
    refute_includes agent.allowed_tools, :advertised_unsafe_tool
  end

  # ============================================================
  # Operator `tools:` filter cannot widen the mode ceiling
  # ============================================================

  def test_operator_tools_filter_intersects_with_ceiling
    # Operator asks for [:aggregate, :query_class] in client mode; ceiling
    # refuses :aggregate. Result must be [:query_class], not the union.
    agent = Parse::Agent.new(
      session_token: FAKE_SESSION,
      tools: { only: %i[aggregate query_class count_objects] },
    )
    tools = agent.allowed_tools
    refute_includes tools, :aggregate
    assert_includes tools, :query_class
    assert_includes tools, :count_objects
  end

  def test_operator_tools_filter_cannot_widen_to_disallowed_tool
    # Even with explicit only: [:aggregate], dispatch must still refuse
    # at the mode ceiling.
    agent = Parse::Agent.new(
      session_token: FAKE_SESSION,
      permissions:   :admin,
      tools:         { only: [:aggregate] },
    )
    result = agent.execute(:aggregate, class_name: "Post", pipeline: [])
    refute result[:success]
    # Whether the refusal hits the operator-filter path or the mode
    # ceiling, the LLM-advertised catalog must be empty.
    assert_empty agent.allowed_tools
  end

  # ============================================================
  # Sub-agent inherits client mode through parent's client
  # ============================================================

  def test_subagent_inherits_client_mode_from_parent_client
    parent = Parse::Agent.new(session_token: FAKE_SESSION)
    assert parent.client_mode?
    # @client is not inherited explicitly; default :default resolves to
    # the same Parse::Client.client. Auth scope (session_token) inherits
    # automatically when child omits identity kwargs. Together that
    # makes client_mode? propagate.
    child = Parse::Agent.new(parent: parent)
    assert child.client_mode?,
           "sub-agent must inherit client_mode? from parent's client + session"
  end

  def test_subagent_in_client_mode_refuses_same_tools_as_parent
    parent = Parse::Agent.new(session_token: FAKE_SESSION)
    child  = Parse::Agent.new(parent: parent)
    result = child.execute(:call_method, class_name: "Post", method_name: "x")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  # ============================================================
  # Layering: agent_hidden refusal vs client-mode refusal
  # ============================================================

  def test_agent_hidden_class_returns_class_denied_not_client_mode_error
    # When the requested tool IS client-safe (query_class) but the
    # target class is agent_hidden, the dispatch should pass the
    # client-mode ceiling and then hit the in-tool class-accessibility
    # gate, returning an AccessDenied with hidden-class semantics
    # (response :details populated by the AccessDenied exception).
    agent = Parse::Agent.new(session_token: FAKE_SESSION)
    result = agent.execute(:query_class, class_name: "ClientModeHiddenFixture")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    # Hidden-class refusal carries the class name in the message ("Class 'X'
    # is not accessible to this agent"); the generic client-mode ceiling
    # refusal mentions the tool, not the class. This message-shape difference
    # is how SOC tooling tells the two apart.
    assert_match(/Class 'ClientModeHiddenFixture' is not accessible/,
                 result[:error])
    refute_match(/client-mode agents/, result[:error],
                 "agent_hidden refusal must not be misreported as client-mode ceiling")
  end

  def test_client_mode_ceiling_fires_before_class_gate_for_refused_tool
    # When the tool is NOT client-safe (aggregate), the client-mode
    # ceiling fires FIRST — the LLM should not learn anything about
    # the class (hidden or otherwise). The refusal is the mode-level
    # one, with no per-class details.
    agent = Parse::Agent.new(permissions: :admin, session_token: FAKE_SESSION)
    result = agent.execute(:aggregate, class_name: "ClientModeHiddenFixture2", pipeline: [])
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_match(/client-mode agents/, result[:error])
    # The mode-ceiling message mentions the tool, not the class. SOC tooling
    # uses this absence to distinguish the ceiling refusal from a class-
    # accessibility refusal that would have leaked the class name.
    refute_match(/ClientModeHiddenFixture2/, result[:error],
                 "ceiling refusal must not echo class name back to LLM")
  end

  # ============================================================
  # Operator-filter precedence over mutation/ceiling messages
  # ============================================================

  def test_operator_except_filter_wins_message_over_mutation_gate
    # Operator excludes :create_object AND leaves allow_mutations at the
    # default false. The mutation-gate branch would tell the operator
    # "set allow_mutations: true", which would NOT actually fix anything
    # because the operator's tools: filter would still exclude it. The
    # operator-filter message must win so the operator looks at the
    # right knob first.
    agent = Parse::Agent.new(
      session_token: FAKE_SESSION,
      permissions:   :write,
      tools:         { except: [:create_object] },
    )
    result = agent.execute(:create_object, class_name: "Post", fields: { title: "x" })
    refute result[:success]
    assert_equal :tool_filtered, result[:error_code]
    assert_match(/tools: filter/, result[:error])
    refute_match(/allow_mutations/, result[:error],
                 "operator-filter refusal must not misdirect to allow_mutations")
  end

  def test_operator_only_filter_wins_message_over_mode_ceiling
    # Operator narrowed tools: to a set that doesn't include the refused
    # tool. The mode-ceiling message would still be technically true, but
    # the operator's filter is the binding gate and that's the message
    # the operator should see.
    agent = Parse::Agent.new(
      session_token: FAKE_SESSION,
      permissions:   :admin,
      tools:         { only: [:query_class] },
    )
    result = agent.execute(:count_objects, class_name: "Post")
    refute result[:success]
    assert_equal :tool_filtered, result[:error_code]
    assert_match(/tools: filter/, result[:error])
  end

  # ============================================================
  # Auth derives from instance state, NOT from LLM-supplied tool args
  # ============================================================

  def test_llm_supplied_session_token_in_args_does_not_override_instance_auth
    # An LLM that hallucinates `session_token: "r:malicious"` (or
    # `use_master_key: true`) into the tool-call JSON must not affect the
    # actual auth posture. The agent layer derives auth from instance
    # state via request_opts, and built-in handlers absorb extras into
    # **_kwargs. This pins that contract — without it, a kwarg-absorption
    # regression in the handler signature would silently let the LLM
    # change identity.
    agent = Parse::Agent.new(session_token: FAKE_SESSION)
    opts = agent.request_opts
    assert_equal FAKE_SESSION, opts[:session_token]
    assert_equal false, opts[:use_master_key]

    # An LLM-supplied master-key flag must not change what request_opts
    # would produce: the agent rebuilds auth on every dispatch from its
    # own instance state.
    spoofed_args = {
      class_name:     "Post",
      session_token:  "r:malicious_token",
      use_master_key: true,
      master:         true,
      acl_user:       "abc1234567",
    }
    # We don't have a live Parse Server in unit tests, so we can't assert
    # the actual outbound request — but we CAN assert request_opts is
    # unaffected by what just went through execute(), which is the
    # mechanism by which auth would otherwise change.
    agent.execute(:query_class, **spoofed_args) rescue nil
    post_opts = agent.request_opts
    assert_equal FAKE_SESSION, post_opts[:session_token],
                 "request_opts must not mutate based on LLM-supplied args"
    assert_equal false, post_opts[:use_master_key]
  end
end
