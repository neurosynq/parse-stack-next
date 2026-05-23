# encoding: UTF-8
# frozen_string_literal: true

require "stringio"
require_relative "../../../test_helper"

# Tests for Parse::Agent::MetadataAudit / Parse::Agent.audit_metadata.
# Surfaces declaration gaps in agent metadata: classes with no
# agent_description, properties without _description:, agent_fields
# entries that don't resolve to known property symbols, and the set of
# declared canonical filters.
class MetadataAuditTest < Minitest::Test
  class MACovered < Parse::Object
    parse_class "MACovered"

    agent_description "Fully-described class for the audit"
    agent_fields :title, :body

    property :title, :string, _description: "Display title"
    property :body, :string, _description: "Main content body"
  end

  class MAMissingClassDesc < Parse::Object
    parse_class "MAMissingClassDesc"
    # No agent_description
    property :foo, :string, _description: "A foo"
  end

  class MAMissingFieldDescs < Parse::Object
    parse_class "MAMissingFieldDescs"
    agent_description "Has class doc but no field docs"
    agent_fields :name, :status

    property :name, :string
    property :status, :string
  end

  class MAUnresolvableAllowlist < Parse::Object
    parse_class "MAUnresolvableAllowlist"
    agent_description "Allowlist references a property that doesn't exist"
    # Typo: :nme, :statys should not resolve to any declared property
    agent_fields :name, :nme, :statys

    property :name, :string
  end

  class MAWithCanonicalFilter < Parse::Object
    parse_class "MAWithCanonicalFilter"
    agent_description "Soft-delete class with canonical filter"
    agent_canonical_filter "archived" => { "$ne" => true }

    property :archived, :boolean
  end

  class MAHiddenFromAudit < Parse::Object
    parse_class "MAHiddenFromAudit"
    agent_hidden
    # No description, no field descriptions, declares a canonical filter
    # and a (typo-laden) allowlist. Hidden classes must be skipped from
    # ALL four sections of the audit, not just missing_class_descriptions.
    agent_fields :secret, :nonexistent_field_typo
    agent_canonical_filter "isDeleted" => { "$ne" => true }
    property :secret, :string
    property :isDeleted, :boolean
  end

  # ============================================================
  # Shape and scope of the audit hash
  # ============================================================

  def test_audit_returns_expected_top_level_keys
    data = Parse::Agent.audit_metadata
    %i[classes_audited
       visible_classes_declared
       missing_class_descriptions
       missing_field_descriptions
       unresolvable_allowlist_entries
       canonical_filter_summary].each do |key|
      assert data.key?(key), "audit should expose top-level key #{key.inspect}"
    end
    assert data[:classes_audited].is_a?(Integer)
    assert [true, false].include?(data[:visible_classes_declared])
  end

  # ============================================================
  # Missing class descriptions
  # ============================================================

  def test_audit_reports_class_missing_agent_description
    data = Parse::Agent.audit_metadata
    assert_includes data[:missing_class_descriptions], "MAMissingClassDesc"
    refute_includes data[:missing_class_descriptions], "MACovered"
  end

  def test_audit_skips_hidden_classes_in_missing_descriptions
    data = Parse::Agent.audit_metadata
    refute_includes data[:missing_class_descriptions], "MAHiddenFromAudit",
                    "agent_hidden classes are intentionally opaque; missing description on them is not a gap"
  end

  def test_audit_skips_hidden_classes_in_missing_field_descriptions
    data = Parse::Agent.audit_metadata
    refute data[:missing_field_descriptions].key?("MAHiddenFromAudit"),
           "agent_hidden classes must not appear in missing_field_descriptions"
  end

  def test_audit_skips_hidden_classes_in_unresolvable_allowlist_entries
    data = Parse::Agent.audit_metadata
    refute data[:unresolvable_allowlist_entries].key?("MAHiddenFromAudit"),
           "agent_hidden classes must not surface their allowlist typos to the audit"
  end

  def test_audit_skips_hidden_classes_in_canonical_filter_summary
    data = Parse::Agent.audit_metadata
    refute data[:canonical_filter_summary].key?("MAHiddenFromAudit"),
           "agent_hidden classes must not surface their canonical filters to the audit"
  end

  # ============================================================
  # Missing field descriptions
  # ============================================================

  def test_audit_reports_allowlisted_fields_missing_description
    data = Parse::Agent.audit_metadata
    missing = data[:missing_field_descriptions]["MAMissingFieldDescs"]
    refute_nil missing
    assert_includes missing, :name
    assert_includes missing, :status
  end

  def test_audit_omits_classes_with_full_field_coverage
    data = Parse::Agent.audit_metadata
    refute data[:missing_field_descriptions].key?("MACovered"),
           "fully-described class should not appear in missing_field_descriptions"
  end

  def test_audit_does_not_flag_system_fields_as_missing
    data = Parse::Agent.audit_metadata
    # Use a class that DOES appear in the missing-fields report
    # (MAMissingFieldDescs has :name and :status missing). The previous
    # version of this test iterated MACovered's report entry, which is
    # absent — making the loop vacuous and the assertion useless.
    missing = data[:missing_field_descriptions]["MAMissingFieldDescs"]
    refute_nil missing, "fixture should appear in the missing-fields report"
    refute_empty missing
    missing.each do |sym|
      refute %i[object_id objectId created_at createdAt updated_at updatedAt acl ACL].include?(sym),
             "system fields must not appear in the missing-fields report (saw #{sym.inspect})"
    end
  end

  # ============================================================
  # Unresolvable allowlist entries
  # ============================================================

  def test_audit_reports_unresolvable_allowlist_typos
    data = Parse::Agent.audit_metadata
    bad = data[:unresolvable_allowlist_entries]["MAUnresolvableAllowlist"]
    refute_nil bad
    assert_includes bad, :nme
    assert_includes bad, :statys
    refute_includes bad, :name, "the legitimate entry should not appear"
  end

  def test_audit_omits_classes_with_clean_allowlist
    data = Parse::Agent.audit_metadata
    refute data[:unresolvable_allowlist_entries].key?("MACovered"),
           "clean allowlist should not produce an entry"
  end

  # ============================================================
  # Canonical filter summary
  # ============================================================

  def test_audit_surfaces_declared_canonical_filters
    data = Parse::Agent.audit_metadata
    assert_equal({ "archived" => { "$ne" => true } },
                 data[:canonical_filter_summary]["MAWithCanonicalFilter"])
    refute data[:canonical_filter_summary].key?("MACovered"),
           "classes without canonical filters should not appear"
  end

  # ============================================================
  # Parse system class filter
  # ============================================================

  def test_audit_skips_parse_system_classes_from_missing_description_report
    data = Parse::Agent.audit_metadata
    # In fallback mode (no agent_visible classes declared globally),
    # Parse::Object.descendants includes _User, _Role, _Session,
    # _Installation, _Product, _Audience. The framework supplies them;
    # the audit must not flag them as gaps in userland code.
    %w[_User _Role _Session _Installation _Product _Audience].each do |sys_class|
      refute_includes data[:missing_class_descriptions], sys_class,
                      "system class #{sys_class} should not appear in missing_class_descriptions"
      refute data[:missing_field_descriptions].key?(sys_class),
             "system class #{sys_class} should not appear in missing_field_descriptions"
    end
  end

  # ============================================================
  # print_summary writes to the provided IO
  # ============================================================

  def test_print_summary_writes_human_readable_output_to_io
    io = StringIO.new
    Parse::Agent::MetadataAudit.print_summary(io: io)
    output = io.string
    assert_match(/Parse::Agent metadata audit/, output)
    assert_match(/Missing class descriptions/, output)
    assert_match(/Canonical filters declared/, output)
  end

  def test_print_summary_returns_the_audit_hash
    io = StringIO.new
    result = Parse::Agent::MetadataAudit.print_summary(io: io)
    assert result.is_a?(Hash)
    assert result.key?(:missing_class_descriptions)
  end
end
