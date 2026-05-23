# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# ============================================================================
# Tests for the PARSE_AGENT_ALLOW_WRITE_TOOLS / PARSE_AGENT_ALLOW_SCHEMA_OPS
# env-var gates. These are an operator-level kill switch independent of the
# per-agent `permissions:` level: even when a factory has constructed a
# :write or :admin agent, the corresponding ENV var must also be set or the
# tool is refused with :access_denied.
# ============================================================================
class AgentEnvGateTest < Minitest::Test
  class Article < Parse::Object
    parse_class "EnvGateArticle"
    property :title, :string

    # A method registered for agent_method to exercise the call_method gate.
    agent_method :touch_title, permission: :write
    def touch_title
      "touched"
    end

    agent_method :reset_class_state, permission: :admin
    def self.reset_class_state
      "reset"
    end
  end

  class ReadonlyMethodHolder < Parse::Object
    parse_class "EnvGateReadonlyHolder"
    agent_method :hello, permission: :readonly
    def self.hello
      "hi"
    end
  end

  ALL_ENV_VARS = %w[
    PARSE_AGENT_ALLOW_WRITE_TOOLS
    PARSE_AGENT_ALLOW_SCHEMA_OPS
    PARSE_AGENT_ALLOW_RAW_CRUD
    PARSE_AGENT_ALLOW_RAW_SCHEMA
  ].freeze

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @saved_env = ALL_ENV_VARS.each_with_object({}) { |k, h| h[k] = ENV.delete(k) }
  end

  def teardown
    @saved_env.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  # ---- Helper predicates ------------------------------------------------

  def test_write_tools_enabled_reads_env
    refute Parse::Agent.write_tools_enabled?

    ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = "true"
    assert Parse::Agent.write_tools_enabled?

    ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = "1"
    assert Parse::Agent.write_tools_enabled?

    ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = "yes"
    assert Parse::Agent.write_tools_enabled?

    ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = "false"
    refute Parse::Agent.write_tools_enabled?

    ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = ""
    refute Parse::Agent.write_tools_enabled?
  ensure
    ENV.delete("PARSE_AGENT_ALLOW_WRITE_TOOLS")
  end

  def test_schema_ops_enabled_reads_env
    refute Parse::Agent.schema_ops_enabled?
    ENV["PARSE_AGENT_ALLOW_SCHEMA_OPS"] = "on"
    assert Parse::Agent.schema_ops_enabled?
  ensure
    ENV.delete("PARSE_AGENT_ALLOW_SCHEMA_OPS")
  end

  # ---- Direct raw CRUD tools at execute() -------------------------------
  # Raw CRUD is gated by PARSE_AGENT_ALLOW_RAW_CRUD specifically — distinct
  # from PARSE_AGENT_ALLOW_WRITE_TOOLS, which only enables agent_method
  # writes via call_method.

  def test_create_object_refused_when_raw_crud_env_unset
    agent = Parse::Agent.new(permissions: :write)
    result = agent.execute(:create_object, class_name: "EnvGateArticle",
                                            data: { title: "T" })
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_includes result[:error], "PARSE_AGENT_ALLOW_RAW_CRUD"
  end

  def test_update_object_refused_when_raw_crud_env_unset
    agent = Parse::Agent.new(permissions: :write)
    result = agent.execute(:update_object, class_name: "EnvGateArticle",
                                            object_id: "abc", data: { title: "T" })
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_includes result[:error], "PARSE_AGENT_ALLOW_RAW_CRUD"
  end

  def test_delete_object_refused_when_raw_crud_env_unset
    agent = Parse::Agent.new(permissions: :admin)
    result = agent.execute(:delete_object, class_name: "EnvGateArticle",
                                            object_id: "abc")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_includes result[:error], "PARSE_AGENT_ALLOW_RAW_CRUD"
  end

  def test_create_class_refused_when_raw_schema_env_unset
    agent = Parse::Agent.new(permissions: :admin)
    result = agent.execute(:create_class, class_name: "ShouldNeverExist")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_includes result[:error], "PARSE_AGENT_ALLOW_RAW_SCHEMA"
  end

  def test_delete_class_refused_when_raw_schema_env_unset
    agent = Parse::Agent.new(permissions: :admin)
    result = agent.execute(:delete_class, class_name: "ShouldNeverExist")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_includes result[:error], "PARSE_AGENT_ALLOW_RAW_SCHEMA"
  end

  # ---- Critical: enabling WRITE_TOOLS alone does NOT enable raw CRUD ----

  def test_write_tools_env_does_not_enable_raw_create_object
    # The whole point of the split. Deployments that want agent_method
    # writes (set WRITE_TOOLS=true) should still be refused on raw
    # create_object/update_object/delete_object unless RAW_CRUD is also
    # explicitly set.
    ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = "true"
    agent = Parse::Agent.new(permissions: :write)
    result = agent.execute(:create_object, class_name: "EnvGateArticle",
                                            data: { title: "T" })
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_includes result[:error], "PARSE_AGENT_ALLOW_RAW_CRUD"
  end

  def test_schema_ops_env_does_not_enable_raw_create_class
    ENV["PARSE_AGENT_ALLOW_SCHEMA_OPS"] = "true"
    agent = Parse::Agent.new(permissions: :admin)
    result = agent.execute(:create_class, class_name: "ShouldNeverExist")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_includes result[:error], "PARSE_AGENT_ALLOW_RAW_SCHEMA"
  end

  # ---- Permission-level rejection still fires first ---------------------

  def test_readonly_agent_still_gets_permission_denied_not_access_denied
    # A :readonly agent attempting a write tool should hit the existing
    # per-agent permission check first, NOT the env-gate. The env-gate is
    # only relevant for misconfigured :write/:admin factories.
    agent = Parse::Agent.new(permissions: :readonly)
    result = agent.execute(:create_object, class_name: "EnvGateArticle",
                                            data: { title: "T" })
    refute result[:success]
    assert_equal :permission_denied, result[:error_code]
    refute_match(/PARSE_AGENT_ALLOW/, result[:error])
  end

  # ---- Env-gate compounds with call_method per-method permission --------

  def test_call_method_write_method_refused_when_write_env_unset
    agent = Parse::Agent.new(permissions: :write)
    # touch_title is declared agent_method permission: :write — the per-
    # agent permission check passes (agent is :write), but the env-gate
    # refuses because PARSE_AGENT_ALLOW_WRITE_TOOLS is not set.
    result = agent.execute(:call_method,
                           class_name: "EnvGateArticle",
                           method_name: "touch_title",
                           object_id: "abc123")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_includes result[:error], "PARSE_AGENT_ALLOW_WRITE_TOOLS"
  end

  def test_call_method_admin_method_refused_when_schema_env_unset
    agent = Parse::Agent.new(permissions: :admin)
    result = agent.execute(:call_method,
                           class_name: "EnvGateArticle",
                           method_name: "reset_class_state")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_includes result[:error], "PARSE_AGENT_ALLOW_SCHEMA_OPS"
  end

  def test_call_method_readonly_method_not_blocked_by_env_gate
    # A :readonly agent calling a :readonly method should not be affected
    # by either env-gate at all.
    agent = Parse::Agent.new(permissions: :readonly)
    result = agent.execute(:call_method,
                           class_name: "EnvGateReadonlyHolder",
                           method_name: "hello")
    # Whether the underlying call succeeds depends on test infra; we only
    # care that the env-gate did not refuse it.
    refute_equal :access_denied, result[:error_code] if result.key?(:error_code)
  end

  # ---- Env-set unblocks ----

  def test_raw_crud_alone_is_insufficient_without_write_tools
    # AND-gate: RAW_CRUD without WRITE_TOOLS is the inverse of the
    # documented "intent-based writes only" deployment posture. The gate
    # must refuse and tell the operator WRITE_TOOLS is also required.
    ENV["PARSE_AGENT_ALLOW_RAW_CRUD"] = "true"
    agent = Parse::Agent.new(permissions: :write)
    result = agent.execute(:create_object, class_name: "EnvGateArticle",
                                            data: { title: "T" })
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_includes result[:error], "PARSE_AGENT_ALLOW_WRITE_TOOLS"
    refute_includes result[:error], "PARSE_AGENT_ALLOW_RAW_CRUD=true",
                    "RAW_CRUD is set; missing-list should only name WRITE_TOOLS"
  end

  def test_both_write_envs_set_allows_create_object_to_proceed_to_dispatch
    ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = "true"
    ENV["PARSE_AGENT_ALLOW_RAW_CRUD"]    = "true"
    agent = Parse::Agent.new(permissions: :write)
    result = agent.execute(:create_object, class_name: "EnvGateArticle",
                                            data: { title: "T" })
    # Both vars set → env-gate passes; downstream failure (no Parse server)
    # surfaces a different error_code, not :access_denied.
    refute_equal :access_denied, result[:error_code]
  end

  def test_raw_schema_alone_is_insufficient_without_schema_ops
    ENV["PARSE_AGENT_ALLOW_RAW_SCHEMA"] = "true"
    agent = Parse::Agent.new(permissions: :admin)
    result = agent.execute(:create_class, class_name: "ShouldNeverExist")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_includes result[:error], "PARSE_AGENT_ALLOW_SCHEMA_OPS"
  end

  def test_both_schema_envs_set_allows_create_class_to_proceed_to_dispatch
    ENV["PARSE_AGENT_ALLOW_SCHEMA_OPS"] = "true"
    ENV["PARSE_AGENT_ALLOW_RAW_SCHEMA"] = "true"
    agent = Parse::Agent.new(permissions: :admin)
    result = agent.execute(:create_class, class_name: "ShouldNeverExist")
    refute_equal :access_denied, result[:error_code]
  end

  # ---- agent_method path: gated by WRITE_TOOLS, not RAW_CRUD ------------

  def test_call_method_write_method_unblocked_by_write_tools_alone
    # PARSE_AGENT_ALLOW_WRITE_TOOLS=true should be sufficient to invoke
    # an agent_method declared :write, WITHOUT also requiring RAW_CRUD.
    # That's the whole point of the split — operators can permit
    # intent-based writes while keeping raw CRUD off.
    ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = "true"
    refute Parse::Agent.raw_crud_enabled?, "raw CRUD must remain off"

    agent = Parse::Agent.new(permissions: :write)
    # The method invocation will fail downstream (no real instance to
    # find), but it must NOT be refused by our gate — we want to see a
    # different error code than :access_denied here.
    result = agent.execute(:call_method,
                           class_name: "EnvGateArticle",
                           method_name: "touch_title",
                           object_id: "abc")
    refute_equal :access_denied, result[:error_code],
                 "agent_method :write must NOT require RAW_CRUD: #{result[:error]}"
  end

  def test_call_method_admin_method_unblocked_by_schema_ops_alone
    ENV["PARSE_AGENT_ALLOW_SCHEMA_OPS"] = "true"
    refute Parse::Agent.raw_schema_enabled?, "raw schema ops must remain off"

    agent = Parse::Agent.new(permissions: :admin)
    result = agent.execute(:call_method,
                           class_name: "EnvGateArticle",
                           method_name: "reset_class_state")
    refute_equal :access_denied, result[:error_code],
                 "agent_method :admin must NOT require RAW_SCHEMA: #{result[:error]}"
  end

  # ---- New helper predicates --------------------------------------------

  def test_raw_crud_enabled_reads_env
    refute Parse::Agent.raw_crud_enabled?
    ENV["PARSE_AGENT_ALLOW_RAW_CRUD"] = "true"
    assert Parse::Agent.raw_crud_enabled?
  end

  def test_raw_schema_enabled_reads_env
    refute Parse::Agent.raw_schema_enabled?
    ENV["PARSE_AGENT_ALLOW_RAW_SCHEMA"] = "true"
    assert Parse::Agent.raw_schema_enabled?
  end
end
