# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Pins the webhook response bodies to Parse Server's HTTP webhook contract
# (HooksController.wrapToHTTPRequest + triggers.getResponseObject, Parse
# Server 9.10). The payload shapes mirror what Parse Server actually sends:
# `object` is `toJSON()` of the pending object, so every pending top-level
# operator (Increment, Delete, Add, AddRelation, ...) appears as its operator
# hash, next to the unchanged stored fields.
#
# Contract recap:
# - beforeSave: `success` REPLACES the write (`this.data = response.object`);
#   a body with no `success` key (`{}`) keeps the write exactly as sent.
#   `{"success": null}` is not safe: the adapter's `typeof result ===
#   "object"` check passes for null and it then throws.
# - afterFind: `success` is mapped through `toJSONwithObjects`, which turns
#   any plain JSON row into `{}` and crashes on a non-array; a body with no
#   `success` keeps the rows.
# - every trigger: only an `{"error": ...}` body denies the operation.
class WebhookAuditContractTest < Minitest::Test
  WEBHOOK_HEADER = "HTTP_X_PARSE_WEBHOOK_KEY"
  TS = "2026-10-06T22:05:32.610Z"

  class AuditDoc < Parse::Object
    parse_class "WebhookAuditDoc"
    property :title, :string
    property :count, :integer
    property :tags, :array
    property :meta, :object
    property :status, :string, default: "draft"
    def autofetch!(*); nil; end
  end

  class AuditGuarded < Parse::Object
    parse_class "WebhookAuditGuarded"
    property :title, :string
    property :owner, :string
    guard :owner, :master_only
    def autofetch!(*); nil; end
  end

  class AuditTag < Parse::Object
    parse_class "WebhookAuditTag"
    property :label, :string
    def autofetch!(*); nil; end
  end

  class AuditTagged < Parse::Object
    parse_class "WebhookAuditTagged"
    property :title, :string
    has_many :tags, as: :webhook_audit_tag, through: :relation
    guard :tags, :master_only
    def autofetch!(*); nil; end
  end

  class AuditDeletable < Parse::Object
    parse_class "WebhookAuditDeletable"
    property :title, :string
    before_destroy :check_locked
    after_destroy :record_destroyed
    # Parse Stack callbacks halt the chain by returning false.
    def check_locked
      title != "locked"
    end
    def record_destroyed
      $webhook_audit_destroyed << id
    end
    def autofetch!(*); nil; end
  end

  def setup
    @saved_key = Parse::Webhooks.instance_variable_get(:@key)
    @saved_logging = Parse::Webhooks.logging
    Parse::Webhooks.key = "audit-key"
    Parse::Webhooks.logging = false
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks::ReplayProtection.reset!
    $webhook_audit_destroyed = []
  end

  def teardown
    Parse::Webhooks.key = @saved_key
    Parse::Webhooks.logging = @saved_logging
    Parse::Webhooks.instance_variable_set(:@routes, nil)
    Parse::Webhooks::ReplayProtection.reset!
  end

  def post(path, body)
    json = body.to_json
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => path,
      "CONTENT_TYPE" => "application/json",
      "rack.input" => StringIO.new(json),
      "CONTENT_LENGTH" => json.bytesize.to_s,
      WEBHOOK_HEADER => "audit-key",
    }
    status, _headers, chunks = nil
    @last_out, @last_err = capture_io { status, _headers, chunks = Parse::Webhooks.call(env) }
    assert_equal 200, status
    JSON.parse(chunks.join)
  end

  def original_doc
    { "objectId" => "d1", "className" => "WebhookAuditDoc", "createdAt" => TS, "updatedAt" => TS,
      "title" => "t1", "count" => 5, "tags" => ["a", "b"], "meta" => { "x" => 1 },
      "ACL" => { "*" => { "read" => true } } }
  end

  # The pending update as Parse Server serializes it: stored fields plus the
  # client's operators.
  def update_object(changes)
    original_doc.merge(changes)
  end

  def before_save_update(changes)
    { "triggerName" => "beforeSave", "master" => false,
      "object" => update_object(changes), "original" => original_doc }
  end

  # --------------------------------------------------------------------------
  # W1: true / nil must not erase the client's write
  # --------------------------------------------------------------------------

  def test_before_save_true_on_create_keeps_the_write
    Parse::Webhooks.route(:before_save, "WebhookAuditDoc") { true }
    body = post("/before_save/WebhookAuditDoc",
                "triggerName" => "beforeSave", "master" => false,
                "object" => { "className" => "WebhookAuditDoc", "title" => "t1", "count" => 5,
                              "undeclared" => "u1" })
    assert_equal({}, body, "true must reply {} (keep the write), never {\"success\":{}}")
  end

  def test_before_save_nil_on_update_keeps_the_write
    Parse::Webhooks.route(:before_save, "WebhookAuditDoc") { nil }
    body = post("/before_save/WebhookAuditDoc",
                before_save_update("title" => "t2", "count" => { "__op" => "Increment", "amount" => 2 }))
    assert_equal({}, body)
  end

  def test_before_save_in_place_edit_with_true_is_merged_into_the_write
    Parse::Webhooks.route(:before_save, "WebhookAuditDoc") do
      parse_object.title = "server-set"
      true
    end
    body = post("/before_save/WebhookAuditDoc",
                before_save_update("title" => "t2", "count" => { "__op" => "Increment", "amount" => 2 },
                                   "undeclared" => "u2"))
    reply = body["success"]
    assert_equal "server-set", reply["title"]
    assert_equal({ "__op" => "Increment", "amount" => 2 }, reply["count"])
    assert_equal "u2", reply["undeclared"]
  end

  def test_guard_revert_on_create_keeps_the_rest_of_the_write
    Parse::Webhooks.route(:before_save, "WebhookAuditGuarded") { nil }
    body = post("/before_save/WebhookAuditGuarded",
                "triggerName" => "beforeSave", "master" => false,
                "object" => { "className" => "WebhookAuditGuarded", "title" => "hello",
                              "owner" => "attacker", "extra" => "kept" })
    reply = body["success"]
    assert_equal({ "__op" => "Delete" }, reply["owner"], "guarded client value is removed")
    assert_equal "hello", reply["title"], "unguarded client field survives"
    assert_equal "kept", reply["extra"], "undeclared client field survives"
  end

  def test_guard_revert_drops_a_client_relation_operator
    Parse::Webhooks.route(:before_save, "WebhookAuditTagged") { parse_object }
    add = { "__op" => "AddRelation",
            "objects" => [{ "__type" => "Pointer", "className" => "WebhookAuditTag", "objectId" => "t1" }] }
    original = { "objectId" => "g1", "className" => "WebhookAuditTagged", "createdAt" => TS,
                 "updatedAt" => TS, "title" => "a" }
    body = post("/before_save/WebhookAuditTagged",
                "triggerName" => "beforeSave", "master" => false,
                "object" => original.merge("title" => "b", "tags" => add), "original" => original)
    reply = body["success"]
    refute reply.key?("tags"), "the guarded AddRelation must not reach Parse Server: #{reply.inspect}"
    assert_equal "b", reply["title"]
  end

  def test_unrouted_before_save_passes_the_write_through
    body = post("/before_save/WebhookAuditDoc",
                "triggerName" => "beforeSave", "master" => false,
                "object" => { "className" => "WebhookAuditDoc", "title" => "t1" })
    assert_equal({}, body, "an unrouted beforeSave must not fail the create (was 105)")
  end

  # --------------------------------------------------------------------------
  # W4: a returned parse_object merges into the write instead of replacing it
  # --------------------------------------------------------------------------

  def test_unchanged_parse_object_on_update_keeps_operators
    Parse::Webhooks.route(:before_save, "WebhookAuditDoc") { parse_object }
    body = post("/before_save/WebhookAuditDoc",
                before_save_update("count" => { "__op" => "Increment", "amount" => 2 },
                                   "tags" => { "__op" => "Delete" }))
    assert_equal({}, body,
                 "no handler change: the write (with its operators) passes through as sent")
  end

  def test_modified_parse_object_preserves_untouched_operators_and_fields
    Parse::Webhooks.route(:before_save, "WebhookAuditDoc") do
      o = parse_object
      o.title = "server-set"
      o
    end
    body = post("/before_save/WebhookAuditDoc",
                before_save_update(
                  "title" => "t2",
                  "count" => { "__op" => "Increment", "amount" => 2 },
                  "tags" => { "__op" => "Delete" },
                  "undeclared" => "u2",
                  "readers" => { "__op" => "AddRelation",
                                 "objects" => [{ "__type" => "Pointer", "className" => "_User", "objectId" => "r1" }] },
                ))
    reply = body["success"]
    assert_equal "server-set", reply["title"]
    assert_equal({ "__op" => "Increment", "amount" => 2 }, reply["count"], "Increment is not flattened")
    assert_equal({ "__op" => "Delete" }, reply["tags"], "array Delete is not turned into []")
    assert_equal "u2", reply["undeclared"], "undeclared fields are not dropped"
    assert_equal "AddRelation", reply.dig("readers", "__op"), "relation operators pass through"
    %w[objectId className createdAt updatedAt].each do |k|
      refute reply.key?(k), "#{k} is server-managed and must not be echoed on update"
    end
    refute reply.key?("meta"), "an untouched stored field is not rewritten"
  end

  def test_add_and_remove_operators_survive_a_handler_change
    Parse::Webhooks.route(:before_save, "WebhookAuditDoc") do
      o = parse_object
      o.title = "x"
      o
    end
    add = post("/before_save/WebhookAuditDoc",
               before_save_update("tags" => { "__op" => "Add", "objects" => ["c"] }))
    assert_equal({ "__op" => "Add", "objects" => ["c"] }, add["success"]["tags"])
    remove = post("/before_save/WebhookAuditDoc",
                  before_save_update("tags" => { "__op" => "Remove", "objects" => ["a"] }))
    assert_equal({ "__op" => "Remove", "objects" => ["a"] }, remove["success"]["tags"])
  end

  def test_handler_that_rewrites_an_operator_field_wins
    Parse::Webhooks.route(:before_save, "WebhookAuditDoc") do
      o = parse_object
      o.count = 100
      o
    end
    body = post("/before_save/WebhookAuditDoc",
                before_save_update("count" => { "__op" => "Increment", "amount" => 2 }))
    assert_equal 100, body["success"]["count"]
  end

  def test_handler_restoring_the_stored_value_drops_the_client_write
    Parse::Webhooks.route(:before_save, "WebhookAuditDoc") do
      o = parse_object
      o.title = "t1" # the stored value
      o.meta = { "y" => 2 }
      o
    end
    body = post("/before_save/WebhookAuditDoc", before_save_update("title" => "client"))
    reply = body["success"]
    refute reply.key?("title"), "restoring the stored value drops the field from the write"
    assert_equal({ "y" => 2 }, reply["meta"])
  end

  def test_parse_object_on_create_keeps_undeclared_fields_and_adds_defaults
    Parse::Webhooks.route(:before_save, "WebhookAuditDoc") { parse_object }
    body = post("/before_save/WebhookAuditDoc",
                "triggerName" => "beforeSave", "master" => false,
                "object" => { "className" => "WebhookAuditDoc", "title" => "t1", "undeclared" => "u1" })
    reply = body["success"]
    assert_equal "t1", reply["title"]
    assert_equal "u1", reply["undeclared"]
    assert_equal "draft", reply["status"], "declared defaults are still applied on create"
    refute reply.key?("className")
  end

  def test_user_signup_fields_survive_a_handler_change
    Parse::Webhooks.route(:before_save, "_User") do
      u = parse_object
      u.email = "normalized@example.com"
      u
    end
    body = post("/before_save/_User",
                "triggerName" => "beforeSave", "master" => false,
                "object" => { "className" => "_User", "username" => "alice", "password" => "s3cret!",
                              "email" => "Alice@Example.com",
                              "authData" => { "anonymous" => { "id" => "abc" } } })
    reply = body["success"]
    assert_equal "alice", reply["username"]
    assert_equal "s3cret!", reply["password"], "signup password must reach Parse Server"
    assert_equal({ "anonymous" => { "id" => "abc" } }, reply["authData"])
    assert_equal "normalized@example.com", reply["email"]
  end

  # --------------------------------------------------------------------------
  # W2 / W3: afterFind passes rows through; rewrites are refused, never blanked
  # --------------------------------------------------------------------------

  def after_find_body
    { "triggerName" => "afterFind", "master" => false,
      "objects" => [{ "objectId" => "f1", "title" => "a" }, { "objectId" => "f2", "title" => "b" }] }
  end

  def test_after_find_nil_passes_rows_through
    Parse::Webhooks.route(:after_find, "WebhookAuditDoc") { nil }
    assert_equal({}, post("/after_find/WebhookAuditDoc", after_find_body),
                 "never {\"success\":true}, which crashes Parse Server (response.map)")
  end

  def test_after_find_returning_the_objects_passes_rows_through
    Parse::Webhooks.route(:after_find, "WebhookAuditDoc") { objects }
    assert_equal({}, post("/after_find/WebhookAuditDoc", after_find_body),
                 "plain JSON rows would be blanked to {} by toJSONwithObjects")
  end

  def test_after_find_returning_built_objects_passes_rows_through
    Parse::Webhooks.route(:after_find, "WebhookAuditDoc") do
      objects.map { |o| Parse::Object.build(o, "WebhookAuditDoc") }
    end
    assert_equal({}, post("/after_find/WebhookAuditDoc", after_find_body))
  end

  def test_after_find_filtering_is_denied_not_leaked
    Parse::Webhooks.route(:after_find, "WebhookAuditDoc") { objects.first(1) }
    body = post("/after_find/WebhookAuditDoc", after_find_body)
    assert_includes @last_err, "cannot apply row changes"
    assert_equal "afterFind webhooks cannot filter or replace results", body["error"]
    refute body.key?("success")
  end

  def test_after_find_false_denies
    Parse::Webhooks.route(:after_find, "WebhookAuditDoc") { false }
    assert post("/after_find/WebhookAuditDoc", after_find_body).key?("error")
  end

  def test_unrouted_after_find_passes_rows_through
    assert_equal({}, post("/after_find/WebhookAuditDoc", after_find_body))
  end

  # --------------------------------------------------------------------------
  # W6: beforeDelete can deny; afterDelete fires after_destroy
  # --------------------------------------------------------------------------

  def delete_body(trigger, title: "plain", master: false, request_id: nil)
    b = { "triggerName" => trigger, "master" => master,
          "object" => { "className" => "WebhookAuditDeletable", "objectId" => "x1", "title" => title,
                        "createdAt" => TS, "updatedAt" => TS } }
    b["headers"] = { "x-parse-request-id" => request_id } if request_id
    b
  end

  def test_before_delete_false_denies
    Parse::Webhooks.route(:before_delete, "WebhookAuditDeletable") { false }
    body = post("/before_delete/WebhookAuditDeletable", delete_body("beforeDelete"))
    assert_equal "Delete halted by before_delete webhook", body["error"]
  end

  def test_before_destroy_halt_denies
    Parse::Webhooks.route(:before_delete, "WebhookAuditDeletable") { parse_object }
    body = post("/before_delete/WebhookAuditDeletable", delete_body("beforeDelete", title: "locked"))
    assert_equal "Delete halted by before_destroy callback", body["error"]
    ok = post("/before_delete/WebhookAuditDeletable", delete_body("beforeDelete", title: "free"))
    assert_equal({ "success" => true }, ok)
    assert_empty $webhook_audit_destroyed, "after_destroy must not run in beforeDelete"
  end

  def test_after_delete_fires_after_destroy_once
    Parse::Webhooks.route(:after_delete, "WebhookAuditDeletable") { true }
    Parse::Webhooks.route(:after_delete, "*") { true }
    body = post("/after_delete/WebhookAuditDeletable", delete_body("afterDelete"))
    assert_equal({ "success" => true }, body)
    assert_equal ["x1"], $webhook_audit_destroyed, "after_destroy fires exactly once per delivery"
  end

  def test_after_delete_skips_callbacks_for_trusted_ruby_deletes
    Parse::Webhooks.route(:after_delete, "WebhookAuditDeletable") { true }
    post("/after_delete/WebhookAuditDeletable",
         delete_body("afterDelete", master: true, request_id: "_RB_local"))
    assert_empty $webhook_audit_destroyed, "a trusted Ruby delete already ran after_destroy locally"
  end

  # --------------------------------------------------------------------------
  # W5: identical function calls are not replays
  # --------------------------------------------------------------------------

  def test_identical_function_calls_both_run
    calls = 0
    Parse::Webhooks.route(:function, "auditPing") { calls += 1 }
    body = { "functionName" => "auditPing", "params" => { "a" => 1 }, "master" => false }
    first = post("/auditPing", body)
    second = post("/auditPing", body)
    assert_equal({ "success" => 1 }, first)
    assert_equal({ "success" => 2 }, second, "a repeat call must not be rejected as a replay")
  end

  # --------------------------------------------------------------------------
  # W7: parse_query reads constraints from `where` only
  # --------------------------------------------------------------------------

  def test_parse_query_uses_where_and_options
    payload = Parse::Webhooks::Payload.new(
      { "triggerName" => "beforeFind",
        "query" => { "where" => { "title" => "x", "where" => "literal", "limit" => { "$gt" => 3 } },
                     "limit" => 5, "skip" => 2, "order" => "-createdAt,title" } },
      "WebhookAuditDoc",
    )
    compiled = payload.parse_query.compile(encode: false)
    assert_equal 5, compiled[:limit]
    assert_equal 2, compiled[:skip]
    assert_equal "-createdAt,title", compiled[:order]
    where = compiled[:where].transform_keys(&:to_s)
    assert_equal "x", where["title"]
    assert_equal "literal", where["where"], "a field literally named where is a field constraint"
    assert_equal({ "$gt" => 3 }, where["limit"], "a field named limit is a field constraint")
    refute where.key?("skip")
    refute where.key?("order")
  end

  # --------------------------------------------------------------------------
  # W8: response logging is redacted
  # --------------------------------------------------------------------------

  def test_response_log_is_redacted
    Parse::Webhooks.logging = true
    Parse::Webhooks.route(:before_save, "_User") do
      u = parse_object
      u.email = "changed@example.com"
      u
    end
    json = { "triggerName" => "beforeSave", "master" => false,
             "object" => { "className" => "_User", "username" => "bob", "password" => "hunter2-secret" } }.to_json
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/before_save/_User",
            "CONTENT_TYPE" => "application/json", "rack.input" => StringIO.new(json),
            "CONTENT_LENGTH" => json.bytesize.to_s, WEBHOOK_HEADER => "audit-key" }
    out, _err = capture_io { Parse::Webhooks.call(env) }
    assert_includes out, "[Webhooks::Response]"
    refute_includes out, "hunter2-secret", "the reply echoes the password; the log must not"
  end

  # --------------------------------------------------------------------------
  # W9 / W10 / W11
  # --------------------------------------------------------------------------

  def test_unrouted_function_is_an_error
    body = post("/nopeFunction", "functionName" => "nopeFunction", "params" => {})
    assert_equal "Webhook function nopeFunction is not registered.", body["error"]
  end

  def test_unrouted_after_save_succeeds
    body = post("/after_save/WebhookAuditDoc",
                "triggerName" => "afterSave", "object" => original_doc)
    assert_equal({ "success" => true }, body)
  end

  def test_unexpected_exception_returns_generic_json_error
    Parse::Webhooks.route(:function, "auditBoom") { raise ArgumentError, "internal detail token=abc" }
    body = post("/auditBoom", "functionName" => "auditBoom")
    assert_equal({ "error" => "Webhook handler failed." }, body, "no exception message in the reply")
    assert_includes @last_err, "ArgumentError", "the class is logged for the operator"
    refute_includes @last_err, "token=abc", "the logged message is redacted"
  end

  def test_error_bang_carries_a_code
    Parse::Webhooks.route(:function, "auditCoded") { error!("duplicate slug", code: 137) }
    body = post("/auditCoded", "functionName" => "auditCoded")
    assert_equal({ "error" => "duplicate slug", "code" => 137 }, body)
    err = assert_raises(Parse::Webhooks::ResponseError) { Parse::Webhooks.run_function("auditCoded", {}) }
    assert_equal 137, err.code
  end

  def test_error_bang_without_code_keeps_the_old_body
    Parse::Webhooks.route(:function, "auditPlain") { error!("nope") }
    assert_equal({ "error" => "nope" }, post("/auditPlain", "functionName" => "auditPlain"))
  end

  def test_payload_class_mismatch_is_refused
    called = false
    Parse::Webhooks.route(:before_save, "WebhookAuditDoc") { called = true }
    body = post("/before_save/WebhookAuditDoc",
                "triggerName" => "beforeSave", "master" => false,
                "object" => { "className" => "WebhookAuditGuarded", "title" => "x" })
    assert_equal "Webhook payload class does not match the trigger class.", body["error"]
    refute called
  end
end
