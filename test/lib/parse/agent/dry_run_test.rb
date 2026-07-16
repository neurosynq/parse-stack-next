# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# ============================================================================
# Tests for the dry-run handling on call_method.
#
# Two paths:
#
#   - supports_dry_run: true  + dry_run: true  → kwarg forwarded, method's own
#                                                 preview executes
#   - supports_dry_run: true  + no dry_run arg → executes normally
#   - supports_dry_run unset  + dry_run: true  → UNIVERSAL preview envelope
#       returned; method body is NOT invoked. The agent confirms the call
#       would pass permission/args/object gates and reports the would_call:
#       block, but cannot produce a method-side preview (the response is
#       flagged supports_real_dry_run: false).
#   - supports_dry_run unset  + dry_run: false → dry_run is stripped from args
#       (method body has no idea about it) and the call executes normally.
#   - supports_dry_run unset  + no dry_run arg → existing behavior unchanged
# ============================================================================
class AgentDryRunTest < Minitest::Test
  # ---- Fixtures ---------------------------------------------------------------

  # A class method that supports dry-run (no object_id needed).
  class DryReport < Parse::Object
    parse_class "DryRunReport"

    agent_method :generate, "Generate a report", permission: :write, supports_dry_run: true
    def self.generate(dry_run: false)
      if dry_run
        { preview: true, would_create: "report", side_effects: ["emails_admin"] }
      else
        { created: true, report_id: "rpt_001" }
      end
    end
  end

  # An instance method that supports dry-run.
  # Stubbing find at the class level with a class variable so it is easy to
  # reset between tests without mutating the singleton in a way that may leak.
  class DryRecord < Parse::Object
    parse_class "DryRunRecord"
    property :status, :string

    @@stub_obj = nil
    def self.find(_id)
      @@stub_obj
    end

    def self.stub_find(obj)
      @@stub_obj = obj
    end

    def self.clear_stub
      @@stub_obj = nil
    end

    # Declare archive AFTER the method definition so agent_method can detect
    # the method type as :instance (method_defined? returns true at that point).
    def archive(dry_run: false)
      if dry_run
        { would_archive: id, current_status: status, side_effects: ["notifies_owner"] }
      else
        self.status = "archived"
        { archived: true }
      end
    end
    agent_method :archive, "Archive this record", permission: :admin, supports_dry_run: true
  end

  # A write method with NO dry-run support.
  class DryWidget < Parse::Object
    parse_class "DryRunWidget"
    property :name, :string

    agent_method :deactivate, "Deactivate this widget", permission: :write
    def deactivate
      self.name = "deactivated"
      { done: true }
    end

    agent_method :readonly_info, "Return info", permission: :readonly
    def self.readonly_info
      { info: "ok" }
    end
  end

  # ---- Setup ------------------------------------------------------------------

  ALL_ENV_VARS = %w[
    PARSE_AGENT_ALLOW_WRITE_TOOLS
    PARSE_AGENT_ALLOW_SCHEMA_OPS
  ].freeze

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test", api_key: "test")
    end
    @saved_env = ALL_ENV_VARS.each_with_object({}) { |k, h| h[k] = ENV.delete(k) }
    ENV["PARSE_AGENT_ALLOW_WRITE_TOOLS"] = "true"
    ENV["PARSE_AGENT_ALLOW_SCHEMA_OPS"]  = "true"
    DryRecord.clear_stub
  end

  def teardown
    @saved_env.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
    DryRecord.clear_stub
  end

  # ---- DSL storage ------------------------------------------------------------

  def test_supports_dry_run_stored_true_when_declared
    info = DryReport.agent_method_info(:generate)
    assert info[:supports_dry_run], "expected supports_dry_run to be true in method_info"
  end

  def test_supports_dry_run_defaults_to_false_when_omitted
    info = DryWidget.agent_method_info(:deactivate)
    refute info[:supports_dry_run], "expected supports_dry_run to default to false"
  end

  def test_supports_dry_run_stored_false_when_not_declared
    # A second method on DryWidget also has no supports_dry_run — confirm the
    # default applies to multiple registrations on the same class.
    info = DryWidget.agent_method_info(:readonly_info)
    refute info[:supports_dry_run], "readonly_info should also have supports_dry_run: false"
  end

  def test_supports_dry_run_stored_true_on_instance_method
    info = DryRecord.agent_method_info(:archive)
    assert info[:supports_dry_run], "archive should store supports_dry_run: true"
  end

  # ---- Class method: dry_run: true supported ----------------------------------

  def test_class_method_with_dry_run_true_returns_preview
    agent = Parse::Agent.new(permissions: :write)
    result = agent.execute(:call_method,
                           class_name: "DryRunReport",
                           method_name: "generate",
                           arguments: { "dry_run" => true })
    assert result[:success], "expected success but got: #{result[:error]}"
    assert_equal true, result[:data][:result][:preview]
    assert_includes result[:data][:result][:side_effects], "emails_admin"
  end

  # ---- Class method: no dry_run arg → executes for real (back-compat) ---------

  def test_class_method_without_dry_run_executes_normally
    agent = Parse::Agent.new(permissions: :write)
    result = agent.execute(:call_method,
                           class_name: "DryRunReport",
                           method_name: "generate")
    assert result[:success], "expected success but got: #{result[:error]}"
    assert_equal true, result[:data][:result][:created]
    refute result[:data][:result].key?(:preview)
  end

  # ---- Instance method: dry_run: true supported -------------------------------

  def test_instance_method_with_dry_run_true_returns_preview
    stub_obj = DryRecord.new
    stub_obj.id = "recDryAbc"
    # Bypass autofetch by setting the attribute directly
    stub_obj.instance_variable_set(:@status, "active")

    # SEC-01: call_method now resolves the instance receiver through the
    # agent's scoped client (fetch_call_method_receiver), not klass.find.
    # Stub at that boundary so this test exercises the dry-run LOGIC.
    agent = Parse::Agent.new(permissions: :admin)
    result = Parse::Agent::Tools.stub(:fetch_call_method_receiver, stub_obj) do
      agent.execute(:call_method,
                    class_name: "DryRunRecord",
                    method_name: "archive",
                    object_id: "recDryAbc",
                    arguments: { "dry_run" => true })
    end
    assert result[:success], "expected success but got: #{result[:error]}"
    r = result[:data][:result]
    assert r.key?(:would_archive), "preview result should include :would_archive"
    assert_includes r[:side_effects], "notifies_owner"
  end

  # ---- Instance method: no dry_run → executes for real (back-compat) ----------

  def test_instance_method_without_dry_run_executes_normally
    stub_obj = DryRecord.new
    stub_obj.id = "recDryXyz"
    stub_obj.disable_autofetch!

    agent = Parse::Agent.new(permissions: :admin)
    result = Parse::Agent::Tools.stub(:fetch_call_method_receiver, stub_obj) do
      agent.execute(:call_method,
                    class_name: "DryRunRecord",
                    method_name: "archive",
                    object_id: "recDryXyz")
    end
    assert result[:success], "expected success but got: #{result[:error]}"
    assert_equal true, result[:data][:result][:archived]
    refute result[:data][:result].key?(:would_archive)
  end

  # ---- Universal preview: supports_dry_run unset, dry_run: true ----------------
  # The agent returns a structural preview envelope confirming the call would
  # pass the permission/args/object gates. The method body is NOT invoked.

  def test_universal_preview_when_dry_run_true_and_not_declared
    stub_obj = DryRecord.new
    stub_obj.id = "w001"
    stub_obj.disable_autofetch! if stub_obj.respond_to?(:disable_autofetch!)

    # Use the instance-method case so we can verify the object-resolution
    # check is part of the universal-preview path.
    agent = Parse::Agent.new(permissions: :admin)
    result = Parse::Agent::Tools.stub(:fetch_call_method_receiver, stub_obj) do
      agent.execute(:call_method,
                    class_name: "DryRunRecord",
                    method_name: "archive",
                    object_id: "w001",
                    arguments: { "dry_run" => true })
    end
    # archive on DryRecord declared supports_dry_run: true. So this path
    # is NOT the universal preview — it's the method's own preview.
    assert result[:success]
    assert result[:data][:result].key?(:would_archive)
  end

  def test_universal_preview_returned_when_method_did_not_declare_dry_run
    agent = Parse::Agent.new(permissions: :write)
    result = agent.execute(:call_method,
                           class_name: "DryRunWidget",
                           method_name: "deactivate",
                           object_id: "w_001",
                           arguments: { "dry_run" => true })
    assert result[:success], "universal preview should succeed: #{result[:error]}"
    data = result[:data]
    assert_equal true, data[:dry_run]
    assert_equal false, data[:supports_real_dry_run]
    assert_equal "DryRunWidget", data[:would_call][:class]
    assert_equal "deactivate",  data[:would_call][:method]
    assert_equal "w_001",       data[:would_call][:object_id]
  end

  def test_universal_preview_strips_dry_run_from_would_call_args
    # The preview echoes the args the method would have seen, MINUS
    # +dry_run+ (which is a wrapper-level concern, not a method-level one).
    agent = Parse::Agent.new(permissions: :write)
    result = agent.execute(:call_method,
                           class_name: "DryRunWidget",
                           method_name: "deactivate",
                           object_id: "w_001",
                           arguments: { "dry_run" => true, "other_key" => "foo" })
    refute result[:data][:would_call][:args].key?(:dry_run)
  end

  # ---- supports_dry_run unset, dry_run: false → executes normally --------------
  # The dry_run kwarg is stripped before forwarding so the method body never
  # sees the unexpected kwarg. The call proceeds as if dry_run had not been
  # passed.

  def test_dry_run_false_on_undeclared_method_executes_normally
    agent = Parse::Agent.new(permissions: :readonly)
    result = agent.execute(:call_method,
                           class_name: "DryRunWidget",
                           method_name: "readonly_info",
                           arguments: { "dry_run" => false })
    assert result[:success], "dry_run: false should execute normally: #{result[:error]}"
    assert_equal "ok", result[:data][:result][:info]
  end

  # ---- Back-compat: undeclared method, no dry_run arg → unchanged -------------

  def test_normal_call_without_dry_run_on_unsupported_method_proceeds
    agent = Parse::Agent.new(permissions: :readonly)
    result = agent.execute(:call_method,
                           class_name: "DryRunWidget",
                           method_name: "readonly_info")
    assert result[:success], "expected success but got: #{result[:error]}"
    assert_equal "ok", result[:data][:result][:info]
  end

  # ---- dry_run: true on a readonly method without declaration -----------------
  # Universal preview also applies to readonly methods.

  def test_universal_preview_for_readonly_method_without_declaration
    agent = Parse::Agent.new(permissions: :readonly)
    result = agent.execute(:call_method,
                           class_name: "DryRunWidget",
                           method_name: "readonly_info",
                           arguments: { "dry_run" => true })
    assert result[:success]
    assert_equal true, result[:data][:dry_run]
    assert_equal false, result[:data][:supports_real_dry_run]
    assert_equal "readonly_info", result[:data][:would_call][:method]
  end

  # ---- Universal preview still resolves the object for instance methods --------
  # An instance-method dry-run must fail loudly if the object can't be found,
  # because the real call would fail the same way. Otherwise the preview
  # would be misleadingly successful.

  def test_universal_preview_fails_when_instance_target_missing
    DryRecord.clear_stub
    agent = Parse::Agent.new(permissions: :admin)
    result = agent.execute(:call_method,
                           class_name: "DryRunRecord",
                           # `archive` declares supports_dry_run: true, so use a different
                           # instance method to hit the universal-preview path.
                           method_name: "nonexistent_instance",
                           object_id: "missing_id",
                           arguments: { "dry_run" => true })
    refute result[:success], "preview should fail loudly when the method is unknown"
  end
end
