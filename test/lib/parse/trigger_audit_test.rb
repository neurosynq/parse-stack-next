# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Exercises Parse::Webhooks.trigger_audit / Parse::Webhooks::TriggerAudit: the
# operator audit that cross-references model ActiveModel callbacks, locally
# registered webhook blocks, and the triggers registered with Parse Server.
class TestTriggerAudit < Minitest::Test
  # --- fixtures -------------------------------------------------------------

  # Callbacks declared, but NO webhook block and (in the live case) no server
  # trigger: the headline "inert" case.
  class AuditPostFixture < Parse::Object
    parse_class "AuditPostFixture"
    property :title, :string
    before_save  :normalize
    after_save   :reindex
    after_create :seed
    before_update :touch        # local-only (no server trigger can run it)
    after_validation :stamp     # local-only
    def normalize; end
    def reindex; end
    def seed; end
    def touch; end
    def stamp; end
  end

  # Callback AND a matching local webhook block — wired for non-Ruby clients
  # once the trigger is also on the server.
  class AuditReportFixture < Parse::Object
    parse_class "AuditReportFixture"
    property :name, :string
    after_save :notify
    webhook :after_save do
      parse_object
    end
    def notify; end
  end

  # No user callbacks at all.
  class AuditPlainFixture < Parse::Object
    parse_class "AuditPlainFixture"
    property :value, :string
  end

  # A fake Parse::Client stand-in for the network path. `triggers.results`
  # returns the hashes the audit reads; `master_key` gates the guard.
  FakeResponse = Struct.new(:results)
  class FakeClient
    attr_reader :master_key
    def initialize(master_key:, triggers:)
      @master_key = master_key
      @triggers = triggers
    end

    def triggers
      FakeResponse.new(@triggers)
    end
  end

  def setup
    @saved_routes = Parse::Webhooks.instance_variable_get(:@routes)
    # Re-declaring the webhook block here (the class body already did, but a
    # prior test may have reset @routes) keeps the AuditReportFixture route
    # present regardless of suite ordering.
    Parse::Webhooks.route(:after_save, "AuditReportFixture") { parse_object }
  end

  def teardown
    Parse::Webhooks.instance_variable_set(:@routes, @saved_routes)
  end

  def row(report_or_audit, name)
    classes = report_or_audit.is_a?(Parse::Webhooks::TriggerAudit) ?
              report_or_audit.classes : nil
    classes&.find { |c| c.parse_class == name }
  end

  def kinds_for(audit, name)
    r = row(audit, name)
    r ? r.findings.map { |f| f[:kind] } : []
  end

  # --- local-only audit (no server, no master key needed) -------------------

  def test_local_audit_flags_inert_callbacks
    audit = Parse::Webhooks::TriggerAudit.new(network: false)
    post = row(audit, "AuditPostFixture")
    refute_nil post

    inert = post.findings.select { |f| f[:kind] == :callbacks_inert }
    triggers = inert.map { |f| f[:trigger] }
    # before_save (from before_save callback) and after_save (after_save +
    # after_create) both lack a local webhook block.
    assert_includes triggers, :before_save
    assert_includes triggers, :after_save

    after_save_finding = inert.find { |f| f[:trigger] == :after_save }
    assert_includes after_save_finding[:callbacks], :after_create
    assert_includes after_save_finding[:callbacks], :after_save
    # Local-only audit can't see the server, so it never claims :server missing.
    assert_equal [:route], after_save_finding[:missing]
  end

  def test_local_audit_notes_local_only_callbacks
    audit = Parse::Webhooks::TriggerAudit.new(network: false)
    post = row(audit, "AuditPostFixture")
    note = post.findings.find { |f| f[:kind] == :local_only_callbacks }
    refute_nil note
    assert_includes note[:callbacks], :before_update
    assert_includes note[:callbacks], :after_validation
    # save/create callbacks are NOT local-only.
    refute_includes note[:callbacks], :before_save
  end

  def test_wired_callback_with_block_has_no_inert_finding_locally
    audit = Parse::Webhooks::TriggerAudit.new(network: false)
    report = row(audit, "AuditReportFixture")
    refute_nil report
    assert_includes report.local_routes, :after_save
    refute_includes kinds_for(audit, "AuditReportFixture"), :callbacks_inert
  end

  def test_plain_class_has_no_findings
    audit = Parse::Webhooks::TriggerAudit.new(network: false)
    plain = row(audit, "AuditPlainFixture")
    refute_nil plain
    assert_empty plain.findings
  end

  # The advisor's acceptance test: framework-internal callbacks must not leak
  # into the per-class callback report.
  def test_framework_callbacks_filtered_for_user
    audit = Parse::Webhooks::TriggerAudit.new(network: false)
    user = row(audit, "_User")
    refute_nil user
    all_names = user.callbacks.values.flatten.map { |c| c[:name] }
    refute_includes all_names, "_resolve_default_acl",
                    "gem-internal callback leaked into the audit"
  end

  def test_include_framework_surfaces_gem_callbacks
    audit = Parse::Webhooks::TriggerAudit.new(network: false, include_framework: true)
    user = row(audit, "_User")
    all_names = user.callbacks.values.flatten.map { |c| c[:name] }
    assert_includes all_names, "_resolve_default_acl"
  end

  # --- network audit (stubbed client) ---------------------------------------

  def server_triggers_list
    [
      # Orphan: registered on the server, no local block handles it.
      { "triggerName" => "beforeSave", "className" => "AuditPostFixture",
        "url" => "https://hooks.example.com/before_save/AuditPostFixture" },
      # Entries with no url are cloud-code, not webhooks — must be ignored.
      { "triggerName" => "afterSave", "className" => "AuditPlainFixture" },
    ]
  end

  def networked_audit
    client = FakeClient.new(master_key: "m", triggers: server_triggers_list)
    Parse::Webhooks::TriggerAudit.new(network: true, client: client)
  end

  def test_network_audit_flags_orphan_server_trigger
    audit = networked_audit
    post = row(audit, "AuditPostFixture")
    orphan = post.findings.find { |f| f[:kind] == :orphan_server_trigger }
    refute_nil orphan
    assert_equal :before_save, orphan[:trigger]
    assert_equal({ before_save: "https://hooks.example.com/before_save/AuditPostFixture" },
                 post.server_triggers)
  end

  def test_network_audit_flags_block_without_server_trigger
    audit = networked_audit
    kinds = kinds_for(audit, "AuditReportFixture")
    # Local block exists, server trigger does not.
    assert_includes kinds, :route_not_registered
    # And the callback is inert with :server missing.
    inert = row(audit, "AuditReportFixture").findings
                                             .find { |f| f[:kind] == :callbacks_inert }
    assert_equal [:server], inert[:missing]
  end

  def test_network_audit_ignores_urlless_cloudcode_triggers
    audit = networked_audit
    plain = row(audit, "AuditPlainFixture")
    # The afterSave entry has no url, so it must not register as a server trigger.
    assert_empty plain.server_triggers
    refute_includes plain.findings.map { |f| f[:kind] }, :orphan_server_trigger
  end

  def test_network_requires_master_key
    client = FakeClient.new(master_key: "", triggers: [])
    err = assert_raises(ArgumentError) do
      Parse::Webhooks::TriggerAudit.new(network: true, client: client)
    end
    assert_match(/master-key/, err.message)
  end

  # --- shape / convenience --------------------------------------------------

  def test_trigger_audit_returns_hash_by_default
    report = Parse::Webhooks.trigger_audit(network: false)
    assert_kind_of Hash, report
    assert report.key?(:classes)
    assert report.key?(:summary)
    assert_kind_of Integer, report[:summary][:classes_audited]
  end

  def test_trigger_audit_pretty_returns_string
    out = Parse::Webhooks.trigger_audit(network: false, pretty: true)
    assert_kind_of String, out
    assert_match(/Parse trigger audit/, out)
  end

  def test_gaps_fold_class_name_into_entries
    audit = networked_audit
    gap = audit.gaps.find { |g| g[:parse_class] == "AuditPostFixture" &&
                                g[:kind] == :callbacks_inert }
    refute_nil gap
    assert_equal "AuditPostFixture", gap[:parse_class]
  end
end
