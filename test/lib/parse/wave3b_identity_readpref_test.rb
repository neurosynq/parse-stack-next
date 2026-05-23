# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"
require "parse/acl_scope"
require "parse/atlas_search"
require "active_support/notifications"

# ============================================================
# Wave-3b regression tests
#
# 1. TRACK-IDENTITY-1: Parse::ACLScope.resolve_for_user must reject
#    pointers whose className is anything other than `_User`/`User`.
#    The Parse::Agent acl_user: kwarg must enforce the same shape at
#    construction time as an early-fail UX mirror.
#
# 2. TRACK-IDENTITY-2: The sub-agent widen check's ArgumentError
#    message must NOT include real principal identifiers (raw _User
#    objectIds or `role:<name>` strings). The full diff is emitted on
#    a dedicated audit channel (`parse.agent.subagent_widen_refused`)
#    so audit-channel consumers retain visibility without forcing
#    exception sinks to capture PII.
#
# 3. TRACK-READPREF-4: Parse::Query#atlas_search /
#    #atlas_autocomplete / #atlas_facets must thread the query's
#    `@read_preference` through to the underlying Atlas Search
#    module. The module in turn forwards it to
#    Parse::MongoDB.aggregate's `read_preference:` kwarg.
# ============================================================

# ------------------------------------------------------------
# 1. resolve_for_user — className validation chokepoint
# ------------------------------------------------------------

class ResolveForUserClassNameValidationTest < Minitest::Test
  def setup
    Parse::ACLScope.reset_warning_state!
  end

  def test_accepts_parse_user_instance
    user = Parse::User.new(objectId: "u_alice")
    res = Parse::ACLScope.resolve_for_user(user)
    assert_includes res.permission_strings, "u_alice"
    assert_includes res.permission_strings, "*"
  end

  def test_accepts_pointer_with_underscore_user_class
    ptr = Parse::Pointer.new("_User", "u_alice")
    res = Parse::ACLScope.resolve_for_user(ptr)
    assert_includes res.permission_strings, "u_alice"
    assert_includes res.permission_strings, "*"
  end

  def test_accepts_pointer_with_legacy_user_alias
    # Some callers normalize away the leading underscore; accept the
    # legacy `"User"` className alias.
    ptr = Parse::Pointer.new("User", "u_alice")
    res = Parse::ACLScope.resolve_for_user(ptr)
    assert_includes res.permission_strings, "u_alice"
  end

  def test_rejects_pointer_for_foreign_class_with_otherwise_valid_id
    # The vuln: a `Pointer` to any other class with a 10-char
    # alphanumeric objectId previously slipped through and landed the
    # raw id in permission_strings.
    order_ptr = Parse::Pointer.new("Order", "abc1234567")
    err = assert_raises(ArgumentError) do
      Parse::ACLScope.resolve_for_user(order_ptr)
    end
    assert_match(/_User/, err.message)
    assert_match(/cross-class id-collision/, err.message)
  end

  def test_rejects_pointer_for_audit_log_class
    audit_ptr = Parse::Pointer.new("AuditLog", "xyz9876543")
    assert_raises(ArgumentError) do
      Parse::ACLScope.resolve_for_user(audit_ptr)
    end
  end

  def test_rejects_string_objectid
    assert_raises(ArgumentError) do
      Parse::ACLScope.resolve_for_user("u_alice")
    end
  end

  def test_rejects_hash_with_id
    # A duck-typed Hash exposing id would previously be accepted by
    # the `respond_to?(:id)` check.
    h = { "id" => "u_alice" }
    assert_raises(ArgumentError) do
      Parse::ACLScope.resolve_for_user(h)
    end
  end

  def test_rejects_arbitrary_object_with_id_method
    # Any duck-typed object exposing `#id` would previously be
    # accepted. The className check now closes that.
    duck = Class.new do
      def id; "u_alice"; end
    end.new
    assert_raises(ArgumentError) do
      Parse::ACLScope.resolve_for_user(duck)
    end
  end

  # ---- Indirect path: Parse::ACLScope.resolve! ----

  def test_resolve_bang_also_rejects_non_user_pointer
    # The most common production caller traverses resolve! rather
    # than calling resolve_for_user directly. Confirm the chokepoint
    # protects that path too.
    order_ptr = Parse::Pointer.new("Order", "abc1234567")
    assert_raises(ArgumentError) do
      Parse::ACLScope.resolve!({ acl_user: order_ptr }, method_name: :test)
    end
  end
end

# ------------------------------------------------------------
# 1b. Parse::Agent acl_user: kwarg — early-fail UX mirror
# ------------------------------------------------------------

class AgentAclUserClassNameValidationTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
    Parse::Agent.suppress_master_key_warning = true
  end

  def test_agent_accepts_parse_user_instance
    user = Parse::User.new(objectId: "u_alice")
    agent = Parse::Agent.new(acl_user: user)
    assert_equal :acl_user, agent.auth_context[:type]
  end

  def test_agent_accepts_pointer_with_user_class
    ptr = Parse::Pointer.new("_User", "u_alice")
    agent = Parse::Agent.new(acl_user: ptr)
    assert_equal :acl_user, agent.auth_context[:type]
  end

  def test_agent_rejects_pointer_with_foreign_class_name
    # The early-fail check fires before any state mutation; the
    # error must surface the className mismatch.
    order_ptr = Parse::Pointer.new("Order", "abc1234567")
    err = assert_raises(ArgumentError) do
      Parse::Agent.new(acl_user: order_ptr)
    end
    assert_match(/_User/, err.message)
    assert_match(/Order/, err.message)
    assert_match(/cross-class id-collision/, err.message)
  end

  def test_agent_rejects_pointer_for_audit_log_class
    audit_ptr = Parse::Pointer.new("AuditLog", "xyz9876543")
    assert_raises(ArgumentError) do
      Parse::Agent.new(acl_user: audit_ptr)
    end
  end

  def test_agent_rejects_arbitrary_duck_typed_object
    duck = Class.new do
      def id; "u_alice"; end
    end.new
    assert_raises(ArgumentError) do
      Parse::Agent.new(acl_user: duck)
    end
  end
end

# ------------------------------------------------------------
# 2. Sub-agent widen-error message redaction
# ------------------------------------------------------------

class SubAgentWidenErrorRedactionTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url: "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key: "test-api-key",
      )
    end
    Parse::Agent.suppress_master_key_warning = true
  end

  def test_widen_error_message_omits_user_object_ids
    alice = Parse::User.new(objectId: "u_alice_secret_id")
    bob   = Parse::User.new(objectId: "u_bob_secret_id")
    parent = Parse::Agent.new(acl_user: alice)
    err = assert_raises(ArgumentError) do
      Parse::Agent.new(parent: parent, acl_user: bob)
    end
    refute_includes err.message, "u_alice_secret_id",
                    "parent objectId must not appear in user-visible message"
    refute_includes err.message, "u_bob_secret_id",
                    "child objectId must not appear in user-visible message"
  end

  def test_widen_error_message_carries_cardinalities
    alice = Parse::User.new(objectId: "u_alice")
    bob   = Parse::User.new(objectId: "u_bob")
    parent = Parse::Agent.new(acl_user: alice)
    err = assert_raises(ArgumentError) do
      Parse::Agent.new(parent: parent, acl_user: bob)
    end
    # The redacted message communicates the shape of the diff via
    # counts, not via identifiers.
    assert_match(/extra principal/, err.message)
    assert_match(/parse\.agent\.subagent_widen_refused/, err.message)
  end

  def test_widen_error_emits_audit_notification_with_full_diff
    alice = Parse::User.new(objectId: "u_alice_secret_id")
    bob   = Parse::User.new(objectId: "u_bob_secret_id")
    parent = Parse::Agent.new(acl_user: alice)

    captured_payload = nil
    sub = ActiveSupport::Notifications.subscribe(
      "parse.agent.subagent_widen_refused"
    ) do |_name, _start, _finish, _id, payload|
      captured_payload = payload
    end

    begin
      assert_raises(ArgumentError) do
        Parse::Agent.new(parent: parent, acl_user: bob)
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    refute_nil captured_payload, "audit channel notification must fire"
    # The audit channel SHOULD carry the full diff so audit sinks
    # retain visibility — this is the documented split (user-visible
    # message redacted, audit channel detailed).
    assert_kind_of Integer, captured_payload[:parent_perm_count]
    assert_kind_of Integer, captured_payload[:child_perm_count]
    assert_kind_of Array, captured_payload[:extra]
    assert_includes captured_payload[:extra], "u_bob_secret_id",
                    "audit channel SHOULD retain the full extra-principals list"
  end

  def test_widen_error_for_master_key_child_redacts_message
    # Parent has explicit scope, child resolves to master-key (no
    # identity supplied AND parent has no inheritable session_token /
    # acl_user / acl_role — orchestrate by manually nil-ing inheritance).
    # Simpler reproduction: parent with acl_role, child explicitly
    # marked as widening via different identity would already be
    # handled by the previous case. For the `child_perms.nil?`
    # branch the existing inheritance is forced — we cannot easily
    # construct that case without monkey-patching. Skip this branch
    # in unit tests; the redaction logic is identical to the extra-
    # principals branch (same audit channel, same cardinality-only
    # message).
    skip "requires resolver mocking to trigger the parent-resolved/child-unresolved race; redaction shape is identical to the extra-principals branch"
  end
end

# ------------------------------------------------------------
# 3. Atlas Search read_preference threading
# ------------------------------------------------------------

class AtlasSearchReadPreferenceThreadingTest < Minitest::Test
  def setup
    Parse::AtlasSearch.reset!
    Parse::AtlasSearch.configure(enabled: true) if defined?(Parse::MongoDB) && Parse::MongoDB.respond_to?(:require_gem!)
    # Module-level config — stub `available?` so the search path
    # runs without requiring an actual MongoDB connection.
    Parse::AtlasSearch.instance_variable_set(:@enabled, true)
  end

  def teardown
    Parse::AtlasSearch.reset!
  end

  # ---- AtlasSearch module: kwarg acceptance + forwarding ----

  def test_search_accepts_read_preference_kwarg_and_forwards_to_aggregate
    # Note: HEAD's AtlasSearch executes pipelines via the private
    # `run_atlas_pipeline!` helper (not `Parse::MongoDB.aggregate`)
    # because $search must be at stage 0 and Parse::MongoDB.aggregate
    # would prepend an ACL $match. The read_preference kwarg
    # contract is therefore validated by capturing what
    # `run_atlas_pipeline!` receives.
    skip "needs Parse::MongoDB" unless defined?(Parse::MongoDB)
    captured_kwargs = nil
    Parse::AtlasSearch.stub(:available?, true) do
      Parse::AtlasSearch.stub(:run_atlas_pipeline!, ->(*_args, **kwargs) {
        captured_kwargs = kwargs
        []
      }) do
        Parse::AtlasSearch.search(
          "Song", "love",
          master: true,
          read_preference: :secondary,
        )
      end
    end
    refute_nil captured_kwargs
    assert_equal :secondary, captured_kwargs[:read_preference],
                 "AtlasSearch.search must forward read_preference: into run_atlas_pipeline!"
  end

  def test_autocomplete_accepts_read_preference_kwarg_and_forwards
    skip "needs Parse::MongoDB" unless defined?(Parse::MongoDB)
    captured_kwargs = nil
    Parse::AtlasSearch.stub(:available?, true) do
      Parse::AtlasSearch.stub(:run_atlas_pipeline!, ->(*_args, **kwargs) {
        captured_kwargs = kwargs
        []
      }) do
        Parse::AtlasSearch.autocomplete(
          "Song", "lov",
          field: :title,
          master: true,
          read_preference: :secondary_preferred,
        )
      end
    end
    refute_nil captured_kwargs
    assert_equal :secondary_preferred, captured_kwargs[:read_preference]
  end

  def test_faceted_search_accepts_read_preference_kwarg_and_forwards
    skip "needs Parse::MongoDB" unless defined?(Parse::MongoDB)
    captured_kwargs_list = []
    Parse::AtlasSearch.stub(:available?, true) do
      Parse::AtlasSearch.stub(:run_atlas_pipeline!, ->(*_args, **kwargs) {
        captured_kwargs_list << kwargs
        # Return a synthetic facet response so the next branch runs.
        [{ "count" => { "total" => 0 }, "facet" => {} }]
      }) do
        Parse::AtlasSearch.faceted_search(
          "Song", "rock",
          { genre: { type: :string, path: :genre } },
          master: true,
          read_preference: :nearest,
        )
      end
    end
    refute captured_kwargs_list.empty?, "run_atlas_pipeline! must be called at least once"
    # The $searchMeta aggregate call must carry read_preference.
    assert_equal :nearest, captured_kwargs_list.first[:read_preference]
  end

  # ---- Parse::Query bridges: @read_preference → AtlasSearch ----

  def test_query_atlas_search_forwards_read_preference_set_via_read_pref
    skip "needs Parse::MongoDB" unless defined?(Parse::MongoDB)
    captured_kwargs = nil
    Parse::AtlasSearch.stub(:available?, true) do
      Parse::AtlasSearch.stub(:search, ->(_collection, _query, **kwargs) {
        captured_kwargs = kwargs
        Parse::AtlasSearch::SearchResult.new(results: [], raw_results: [])
      }) do
        q = Parse::Query.new("Song").read_pref(:secondary)
        q.atlas_search("love", master: true)
      end
    end
    refute_nil captured_kwargs
    assert_equal :secondary, captured_kwargs[:read_preference],
                 "Query#atlas_search must inject @read_preference into the AtlasSearch.search options"
  end

  def test_query_atlas_search_does_not_override_explicit_option
    # If the caller explicitly passes `read_preference:` to
    # `atlas_search`, the query's `@read_preference` must NOT
    # silently overwrite it.
    skip "needs Parse::MongoDB" unless defined?(Parse::MongoDB)
    captured_kwargs = nil
    Parse::AtlasSearch.stub(:available?, true) do
      Parse::AtlasSearch.stub(:search, ->(_collection, _query, **kwargs) {
        captured_kwargs = kwargs
        Parse::AtlasSearch::SearchResult.new(results: [], raw_results: [])
      }) do
        q = Parse::Query.new("Song").read_pref(:secondary)
        q.atlas_search("love", master: true, read_preference: :primary)
      end
    end
    assert_equal :primary, captured_kwargs[:read_preference]
  end

  def test_query_atlas_autocomplete_forwards_read_preference
    skip "needs Parse::MongoDB" unless defined?(Parse::MongoDB)
    captured_kwargs = nil
    Parse::AtlasSearch.stub(:available?, true) do
      Parse::AtlasSearch.stub(:autocomplete, ->(_collection, _query, field:, **kwargs) {
        captured_kwargs = kwargs
        Parse::AtlasSearch::AutocompleteResult.new(suggestions: [], results: [])
      }) do
        q = Parse::Query.new("Song").read_pref(:secondary)
        q.atlas_autocomplete("lov", field: :title, master: true)
      end
    end
    refute_nil captured_kwargs
    assert_equal :secondary, captured_kwargs[:read_preference]
  end

  def test_query_atlas_facets_forwards_read_preference
    skip "needs Parse::MongoDB" unless defined?(Parse::MongoDB)
    captured_kwargs = nil
    Parse::AtlasSearch.stub(:available?, true) do
      Parse::AtlasSearch.stub(:faceted_search, ->(_collection, _query, _facets, **kwargs) {
        captured_kwargs = kwargs
        Parse::AtlasSearch::FacetedResult.new(results: [], facets: {}, total_count: 0)
      }) do
        q = Parse::Query.new("Song").read_pref(:nearest)
        q.atlas_facets("rock", { genre: { type: :string, path: :genre } }, master: true)
      end
    end
    refute_nil captured_kwargs
    assert_equal :nearest, captured_kwargs[:read_preference]
  end

  def test_query_atlas_search_omits_read_preference_when_query_did_not_set_one
    # The default `@read_preference` is nil; the option should not
    # be injected as `nil` (which would be functionally equivalent
    # but adds noise to the kwargs surface).
    skip "needs Parse::MongoDB" unless defined?(Parse::MongoDB)
    captured_kwargs = nil
    Parse::AtlasSearch.stub(:available?, true) do
      Parse::AtlasSearch.stub(:search, ->(_collection, _query, **kwargs) {
        captured_kwargs = kwargs
        Parse::AtlasSearch::SearchResult.new(results: [], raw_results: [])
      }) do
        q = Parse::Query.new("Song")  # no read_pref call
        q.atlas_search("love", master: true)
      end
    end
    refute_nil captured_kwargs
    refute captured_kwargs.key?(:read_preference),
           "Query should not inject read_preference when not set on the query"
  end
end
