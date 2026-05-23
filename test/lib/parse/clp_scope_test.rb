# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "net/http" # for Net::ReadTimeout in fail-closed tests

# Unit tests for Parse::CLPScope — the agent/SDK-side Class-Level
# Permissions + Protected Fields enforcement layer that mirrors
# Parse::ACLScope for the operation/class/field axes of authorization.
#
# Network-free: tests inject CLP entries into the cache via
# `Parse::CLPScope.__cache_put` and assert against the public
# {permits?, pointer_fields_for, protected_fields_for,
# redact_protected_fields!, filter_by_pointer_fields} helpers.
class CLPScopeTest < Minitest::Test
  def setup
    Parse.setup(server_url: "http://localhost:1337/parse",
                application_id: "test", api_key: "test") unless Parse::Client.client?
    Parse::CLPScope.reset_cache!
  end

  def teardown
    Parse::CLPScope.reset_cache!
  end

  # -------- permits? --------------------------------------------------

  def test_master_key_bypasses_every_op
    Parse::CLPScope.__cache_put("Song", clp: {
      "find" => { "role:Admin" => true },
      "delete" => { },
    })
    Parse::CLPScope::OPERATIONS.each do |op|
      assert Parse::CLPScope.permits?("Song", op, nil),
             "master-key must permit #{op}"
    end
  end

  def test_public_find_permitted_for_any_claim_set
    Parse::CLPScope.__cache_put("Song", clp: { "find" => { "*" => true } })
    assert Parse::CLPScope.permits?("Song", :find, ["*"])
    assert Parse::CLPScope.permits?("Song", :find, ["*", "role:Anyone"])
  end

  def test_role_permit_matches_claim_set
    Parse::CLPScope.__cache_put("Song", clp: { "create" => { "role:Admin" => true } })
    assert Parse::CLPScope.permits?("Song", :create, ["*", "u_alice", "role:Admin"])
    refute Parse::CLPScope.permits?("Song", :create, ["*", "u_alice"])
  end

  def test_user_id_permit_matches_claim_set
    Parse::CLPScope.__cache_put("Song", clp: { "update" => { "u_alice" => true } })
    assert Parse::CLPScope.permits?("Song", :update, ["*", "u_alice", "role:Editor"])
    refute Parse::CLPScope.permits?("Song", :update, ["*", "u_bob"])
  end

  def test_requires_authentication_needs_user_identity
    Parse::CLPScope.__cache_put("Song", clp: {
      "find" => { "requiresAuthentication" => true },
    })
    assert Parse::CLPScope.permits?("Song", :find, ["*", "u_alice"]),
           "user_id claim satisfies requiresAuthentication"
    refute Parse::CLPScope.permits?("Song", :find, ["*", "role:Admin"]),
           "role-only claim doesn't satisfy requiresAuthentication"
    refute Parse::CLPScope.permits?("Song", :find, ["*"]),
           "public-only claim doesn't satisfy requiresAuthentication"
  end

  def test_pointer_fields_permits_user_identity_at_boundary
    Parse::CLPScope.__cache_put("Doc", clp: {
      "update" => { "pointerFields" => ["owner"] },
    })
    assert Parse::CLPScope.permits?("Doc", :update, ["*", "u_alice"])
    refute Parse::CLPScope.permits?("Doc", :update, ["*", "role:Admin"]),
           "acl_role-only agents have no user_id to satisfy pointerFields"
  end

  def test_empty_op_map_denies_everything_but_master_key
    Parse::CLPScope.__cache_put("Song", clp: { "delete" => {} })
    refute Parse::CLPScope.permits?("Song", :delete, ["*", "u_alice", "role:Admin"])
    assert Parse::CLPScope.permits?("Song", :delete, nil) # master-key bypass
  end

  def test_missing_op_entry_defaults_to_permit
    Parse::CLPScope.__cache_put("Song", clp: { "find" => { "role:Admin" => true } })
    # No `delete` key at all → Parse Server's default is public; mirror that.
    assert Parse::CLPScope.permits?("Song", :delete, ["*"])
  end

  def test_lookup_failure_fail_closed
    # Wave-3 TRACK-CLP-2: schema-fetch failure now fails CLOSED.
    # Previously the SDK fell back to permit-everything when the
    # schema endpoint was unreachable, which silently surrendered
    # CLP enforcement during outages (or against classes whose schema
    # the client genuinely can't fetch). The mongo-direct path bypasses
    # Parse Server entirely, so a fail-open posture meant unfiltered
    # rows reached the application during the outage window.
    failing_client = Object.new
    def failing_client.schema(_class)
      raise Net::ReadTimeout, "stubbed timeout"
    end
    Parse::CLPScope.schema_client = failing_client
    begin
      _out, err = capture_io do
        refute Parse::CLPScope.permits?("DoesNotExist", :find, ["*", "u_alice"]),
               "permits? must fail CLOSED on schema fetch failure"
      end
      assert_match(/CLPScope.*unresolvable/i, err,
                   "fail-closed denial must emit operator-visible warning")
    ensure
      Parse::CLPScope.schema_client = nil
    end
  end

  def test_success_with_empty_clp_permits
    # Schema fetch succeeds, returns an empty (or absent) classLevelPermissions
    # map → Parse Server default is public → permit. This is the
    # `:no_clp` cache disposition.
    stub_client = Object.new
    def stub_client.schema(_class)
      Struct.new(:success?, :result).new(true, { "classLevelPermissions" => {} })
    end
    Parse::CLPScope.schema_client = stub_client
    begin
      assert Parse::CLPScope.permits?("PublicByDefault", :find, ["*", "u_alice"]),
             "empty CLP must permit (Parse Server's public-by-default)"
    ensure
      Parse::CLPScope.schema_client = nil
    end
  end

  def test_success_with_admin_only_clp_denies_non_admin
    # Schema fetch succeeds with role:Admin-only find CLP → permit only
    # claim sets that include role:Admin.
    stub_client = Object.new
    def stub_client.schema(_class)
      Struct.new(:success?, :result).new(true, {
        "classLevelPermissions" => { "find" => { "role:Admin" => true } },
      })
    end
    Parse::CLPScope.schema_client = stub_client
    begin
      assert Parse::CLPScope.permits?("AdminOnly", :find, ["*", "u_alice", "role:Admin"])
      refute Parse::CLPScope.permits?("AdminOnly", :find, ["*", "u_alice"])
    ensure
      Parse::CLPScope.schema_client = nil
    end
  end

  def test_unresolvable_warning_emitted_once_per_class
    # Same class denied twice → only one warning. Different class →
    # separate warning. Prevents the warned-once registry from
    # silencing per-class signals while still throttling log spam.
    failing_client = Object.new
    def failing_client.schema(_class)
      raise Net::ReadTimeout, "stubbed timeout"
    end
    Parse::CLPScope.schema_client = failing_client
    Parse::CLPScope.reset_cache! # also clears warned-once registry
    begin
      _out, err1 = capture_io do
        Parse::CLPScope.permits?("ClassA", :find, ["*"])
        Parse::CLPScope.permits?("ClassA", :find, ["*"])
      end
      assert_equal 1, err1.scan(/CLPScope.*unresolvable/i).length

      _out, err2 = capture_io do
        Parse::CLPScope.permits?("ClassB", :find, ["*"])
      end
      assert_match(/ClassB/, err2)
    ensure
      Parse::CLPScope.schema_client = nil
    end
  end

  # -------- pointer_fields_for ---------------------------------------

  def test_pointer_fields_returns_field_names
    Parse::CLPScope.__cache_put("Doc", clp: {
      "find" => { "pointerFields" => %w[owner editors] },
    })
    assert_equal %w[owner editors], Parse::CLPScope.pointer_fields_for("Doc", :find)
  end

  def test_pointer_fields_nil_when_absent
    Parse::CLPScope.__cache_put("Doc", clp: { "find" => { "*" => true } })
    assert_nil Parse::CLPScope.pointer_fields_for("Doc", :find)
  end

  # -------- protected_fields_for -------------------------------------

  def test_protected_fields_default_for_public
    Parse::CLPScope.__cache_put("User", clp: {
      "protectedFields" => { "*" => ["private_notes", "ssn"] },
    })
    perms = ["*"]
    assert_equal Set["private_notes", "ssn"],
                 Parse::CLPScope.protected_fields_for("User", perms)
  end

  def test_protected_fields_admin_override_strips_protection
    Parse::CLPScope.__cache_put("User", clp: {
      "protectedFields" => {
        "*" => ["private_notes", "ssn"],
        "role:Admin" => [],
      },
    })
    perms = ["*", "u_alice", "role:Admin"]
    # Admin override is [] — intersection collapses; strip-set is empty
    assert_equal Set.new, Parse::CLPScope.protected_fields_for("User", perms)
  end

  def test_protected_fields_master_key_returns_empty
    Parse::CLPScope.__cache_put("User", clp: {
      "protectedFields" => { "*" => ["ssn"] },
    })
    assert_equal Set.new, Parse::CLPScope.protected_fields_for("User", nil)
  end

  def test_protected_fields_no_config_returns_empty
    Parse::CLPScope.__cache_put("Song", clp: { "find" => { "*" => true } })
    assert_equal Set.new, Parse::CLPScope.protected_fields_for("Song", ["*", "u_alice"])
  end

  # -------- redact_protected_fields! ---------------------------------

  def test_redact_protected_fields_strips_top_level
    docs = [{ "objectId" => "1", "ssn" => "123", "title" => "hi" }]
    Parse::CLPScope.redact_protected_fields!(docs, Set.new(["ssn"]))
    refute_includes docs.first.keys, "ssn"
    assert_equal "hi", docs.first["title"]
  end

  def test_redact_protected_fields_strips_nested_subdocs
    docs = [{
      "objectId" => "1",
      "nested" => { "ssn" => "999", "ok" => "y" },
      "list"   => [{ "ssn" => "888", "n" => 1 }],
    }]
    Parse::CLPScope.redact_protected_fields!(docs, Set.new(["ssn"]))
    refute_includes docs.first["nested"].keys, "ssn"
    refute_includes docs.first["list"].first.keys, "ssn"
  end

  def test_redact_protected_fields_noop_for_empty_set
    docs = [{ "objectId" => "1", "ssn" => "123" }]
    Parse::CLPScope.redact_protected_fields!(docs, Set.new)
    assert_includes docs.first.keys, "ssn"
  end

  # -------- filter_by_pointer_fields ---------------------------------

  def test_filter_by_pointer_fields_parse_format
    docs = [
      { "objectId" => "1", "owner" => { "__type" => "Pointer", "className" => "_User", "objectId" => "u_alice" } },
      { "objectId" => "2", "owner" => { "__type" => "Pointer", "className" => "_User", "objectId" => "u_bob" } },
    ]
    result = Parse::CLPScope.filter_by_pointer_fields(docs, ["owner"], "u_alice")
    assert_equal ["1"], result.map { |d| d["objectId"] }
  end

  def test_filter_by_pointer_fields_direct_mongo_format
    docs = [
      { "objectId" => "1", "_p_owner" => "_User$u_alice" },
      { "objectId" => "2", "_p_owner" => "_User$u_bob" },
    ]
    result = Parse::CLPScope.filter_by_pointer_fields(docs, ["owner"], "u_alice")
    assert_equal ["1"], result.map { |d| d["objectId"] }
  end

  def test_filter_by_pointer_fields_array_form
    docs = [
      { "objectId" => "1", "editors" => [
        { "__type" => "Pointer", "className" => "_User", "objectId" => "u_alice" },
        { "__type" => "Pointer", "className" => "_User", "objectId" => "u_bob" },
      ] },
      { "objectId" => "2", "editors" => [
        { "__type" => "Pointer", "className" => "_User", "objectId" => "u_carol" },
      ] },
    ]
    result = Parse::CLPScope.filter_by_pointer_fields(docs, ["editors"], "u_alice")
    assert_equal ["1"], result.map { |d| d["objectId"] }
  end

  def test_filter_by_pointer_fields_returns_empty_for_nil_user
    docs = [{ "objectId" => "1", "owner" => { "__type" => "Pointer", "objectId" => "u_a" } }]
    result = Parse::CLPScope.filter_by_pointer_fields(docs, ["owner"], nil)
    assert_empty result
  end

  # -------- cache + invalidate ---------------------------------------

  def test_cache_invalidate_drops_entry
    Parse::CLPScope.__cache_put("Song", clp: { "find" => { "*" => true } })
    refute_empty Parse::CLPScope.cache_stats[:class_names]
    Parse::CLPScope.invalidate!("Song")
    refute_includes Parse::CLPScope.cache_stats[:class_names], "Song"
  end

  def test_reset_cache_drops_all
    Parse::CLPScope.__cache_put("A", clp: {})
    Parse::CLPScope.__cache_put("B", clp: {})
    Parse::CLPScope.reset_cache!
    assert_equal 0, Parse::CLPScope.cache_stats[:size]
  end

  # -------- assert_permitted! ----------------------------------------

  def test_assert_permitted_raises_on_denial
    Parse::CLPScope.__cache_put("Song", clp: { "delete" => {} })
    err = assert_raises(Parse::CLPScope::Denied) do
      Parse::CLPScope.assert_permitted!("Song", :delete, ["*", "u_alice"])
    end
    assert_equal "Song", err.class_name
    assert_equal :delete, err.operation
  end

  def test_assert_permitted_returns_nil_on_permit
    Parse::CLPScope.__cache_put("Song", clp: { "find" => { "*" => true } })
    assert_nil Parse::CLPScope.assert_permitted!("Song", :find, ["*"])
  end
end
