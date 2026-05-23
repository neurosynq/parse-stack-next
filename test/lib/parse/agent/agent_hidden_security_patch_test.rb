# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# ============================================================================
# Regression tests for the v4.1.x agent_hidden / agent_fields security patch.
#
# Each test corresponds to a numbered finding from the security re-audit. The
# fixes are at the gem's gate layer (Tools.assert_*!, enforce_*!, redact_*!)
# so these tests run without Docker or a real Parse Server — they verify the
# gate refuses before any I/O.
# ============================================================================
class AgentHiddenSecurityPatchTest < Minitest::Test
  # ---- Fixtures ------------------------------------------------------------

  class PatchVisibleSubject < Parse::Object
    parse_class "PatchVisibleSubject"
    property :name, :string
  end

  class PatchVisibleStudent < Parse::Object
    parse_class "PatchVisibleStudent"
    property :name, :string
    property :ssn, :string
    property :parent_email, :string
    belongs_to :subject, as: :pointer, class_name: "PatchVisibleSubject"

    agent_fields :name, :subject
  end

  class PatchHiddenIDs < Parse::Object
    parse_class "PatchHiddenIDs"
    property :student_name, :string
    property :ssn, :string

    agent_hidden
  end

  # Visible class with a pointer INTO the hidden class. The audit's Finding #2
  # (include-resolution leak) needs a class that points at a hidden class.
  class PatchVisibleWithHiddenPointer < Parse::Object
    parse_class "PatchVisibleWithHiddenPointer"
    property :label, :string
    belongs_to :secret_record, as: :pointer, class_name: "PatchHiddenIDs"
  end

  # Hidden class whose parse_class is the canonical (underscore-prefixed)
  # form. Mirrors how Parse system classes (_User, _Role, etc.) work --
  # the registry stores `"_PatchHiddenAliased"` but an LLM might naturally
  # write `"PatchHiddenAliased"` in a $lookup. The canonicalization fix in
  # MetadataRegistry.hidden? must resolve the alias and refuse anyway.
  class PatchHiddenAliased < Parse::Object
    parse_class "_PatchHiddenAliased"
    property :name, :string
    agent_hidden
  end

  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app", api_key: "test-key")
    end
    @agent = Parse::Agent.new(permissions: :readonly)
  end

  # ---- Finding #3: call_method on hidden class is denied -------------------

  def test_call_method_against_hidden_class_is_denied
    result = @agent.execute(:call_method,
                            class_name: "PatchHiddenIDs",
                            method_name: "anything")
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  # ---- Finding #4: keys: override is intersected with agent_fields ---------

  def test_keys_argument_cannot_override_agent_fields_allowlist
    # The PatchVisibleStudent allowlist is [:name, :subject]. ssn is NOT in
    # the allowlist; passing keys: ["ssn"] used to forward "ssn" verbatim
    # and the field came back. With the fix, the caller's keys are
    # intersected with the allowlist, so ssn is dropped silently.
    captured = nil
    fake_client = Object.new
    fake_client.define_singleton_method(:find_objects) do |_class_name, query, **_opts|
      captured = query
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results)  { [] }
      r
    end
    @agent.define_singleton_method(:client) { fake_client }

    @agent.execute(:query_class,
                   class_name: "PatchVisibleStudent",
                   keys: %w[ssn name parent_email subject],
                   limit: 1)

    keys = captured[:keys].split(",")
    refute_includes keys, "ssn",          "ssn must be stripped despite caller's keys: override"
    refute_includes keys, "parent_email", "parent_email must be stripped"
    assert_includes keys, "name",         "permitted fields survive the intersection"
    assert_includes keys, "subject"
  end

  def test_keys_argument_without_allowlist_passes_through
    # No agent_fields declared on PatchVisibleSubject — keys: should still
    # work as a normal projection.
    captured = nil
    fake_client = Object.new
    fake_client.define_singleton_method(:find_objects) do |_class_name, query, **_opts|
      captured = query
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results)  { [] }
      r
    end
    @agent.define_singleton_method(:client) { fake_client }

    @agent.execute(:query_class,
                   class_name: "PatchVisibleSubject",
                   keys: %w[name],
                   limit: 1)
    assert_equal "name", captured[:keys]
  end

  # ---- Finding #1: $lookup into a hidden class is denied -------------------

  def test_aggregate_lookup_from_hidden_class_is_denied
    pipeline = [
      { "$lookup" => { "from" => "PatchHiddenIDs", "localField" => "objectId",
                       "foreignField" => "objectId", "as" => "leak" } },
    ]
    result = @agent.execute(:aggregate, class_name: "PatchVisibleStudent", pipeline: pipeline)
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  def test_aggregate_unionwith_hidden_class_is_denied
    pipeline = [{ "$unionWith" => { "coll" => "PatchHiddenIDs", "pipeline" => [] } }]
    result = @agent.execute(:aggregate, class_name: "PatchVisibleStudent", pipeline: pipeline)
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  def test_aggregate_lookup_nested_inside_facet_is_denied
    pipeline = [
      { "$facet" => {
        "branch" => [
          { "$lookup" => { "from" => "PatchHiddenIDs", "as" => "x",
                           "localField" => "objectId", "foreignField" => "objectId" } },
        ],
      } },
    ]
    result = @agent.execute(:aggregate, class_name: "PatchVisibleStudent", pipeline: pipeline)
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  # ---- Finding #5: $project re-projecting restricted fields is denied -----

  def test_aggregate_project_of_restricted_field_is_denied
    # PatchVisibleStudent.agent_fields = :name, :subject — ssn is restricted.
    pipeline = [
      { "$match" => { "name" => "Ada" } },
      { "$project" => { "ssn" => 1, "name" => 1 } },
    ]
    result = @agent.execute(:aggregate, class_name: "PatchVisibleStudent", pipeline: pipeline)
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
    assert_match(/ssn/, result[:error].to_s)
  end

  def test_aggregate_project_of_permitted_field_succeeds
    pipeline = [{ "$project" => { "name" => 1 } }]
    # Stub client so the actual aggregate call is a no-op.
    fake_client = Object.new
    fake_client.define_singleton_method(:aggregate_pipeline) do |_class_name, _pipeline, **_opts|
      r = Object.new
      r.define_singleton_method(:success?) { true }
      r.define_singleton_method(:results)  { [] }
      r
    end
    @agent.define_singleton_method(:client) { fake_client }
    result = @agent.execute(:aggregate, class_name: "PatchVisibleStudent", pipeline: pipeline)
    assert result[:success], "permitted projection must pass: #{result.inspect}"
  end

  def test_aggregate_addfields_with_restricted_reference_is_denied
    pipeline = [{ "$addFields" => { "copy" => "$ssn" } }]
    result = @agent.execute(:aggregate, class_name: "PatchVisibleStudent", pipeline: pipeline)
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  # ---- Finding #2: include: into a hidden class via pointer is denied -----

  def test_query_class_include_into_hidden_class_pointer_is_denied
    result = @agent.execute(:query_class,
                            class_name: "PatchVisibleWithHiddenPointer",
                            include: ["secret_record"],
                            limit: 1)
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  def test_get_object_include_into_hidden_class_pointer_is_denied
    result = @agent.execute(:get_object,
                            class_name: "PatchVisibleWithHiddenPointer",
                            object_id: "abc12345",
                            include: ["secret_record"])
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  def test_get_objects_include_into_hidden_class_pointer_is_denied
    result = @agent.execute(:get_objects,
                            class_name: "PatchVisibleWithHiddenPointer",
                            ids: ["abc12345"],
                            include: ["secret_record"])
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  # ---- Canonicalization gap: alias resolution at the hidden? boundary -----

  def test_hidden_predicate_canonicalizes_alias_to_parse_class
    # parse_class is "_PatchHiddenAliased"; calling hidden? with the
    # un-prefixed form must still resolve and return true.
    assert Parse::Agent::MetadataRegistry.hidden?("_PatchHiddenAliased")
    assert Parse::Agent::MetadataRegistry.hidden?("PatchHiddenAliased"),
           "hidden? must canonicalize unprefixed name to the registered _-prefixed parse_class"
    assert Parse::Agent::MetadataRegistry.hidden?(:PatchHiddenAliased),
           "hidden? must accept symbols and canonicalize them too"
    refute Parse::Agent::MetadataRegistry.hidden?("DefinitelyNotAClass")
    refute Parse::Agent::MetadataRegistry.hidden?(nil)
  end

  def test_aggregate_lookup_using_unprefixed_alias_of_hidden_class_is_denied
    # The LLM writes the alias form -- `from: "PatchHiddenAliased"` -- but
    # the hidden class is registered as `"_PatchHiddenAliased"`. Before the
    # canonicalization fix, the access policy compared strings verbatim and
    # let this lookup through, fetching the hidden class's rows server-side.
    pipeline = [
      { "$lookup" => { "from" => "PatchHiddenAliased", "localField" => "objectId",
                       "foreignField" => "objectId", "as" => "leak" } },
    ]
    result = @agent.execute(:aggregate, class_name: "PatchVisibleStudent", pipeline: pipeline)
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  def test_top_level_class_name_alias_of_hidden_class_is_denied
    # Same gap at the top-level entry-point check.
    result = @agent.execute(:query_class, class_name: "PatchHiddenAliased", limit: 1)
    refute result[:success]
    assert_equal :access_denied, result[:error_code]
  end

  # ---- Defense-in-depth: post-fetch className redaction --------------------

  def test_redact_hidden_classes_walker_replaces_nested_hidden_objects
    payload = [
      {
        "objectId" => "abc1",
        "label"    => "ok",
        "secret_record" => {
          "__type"    => "Object",
          "className" => "PatchHiddenIDs",
          "ssn"       => "123-45-6789",
          "address"   => "11 Maple St",
        },
      },
    ]
    redacted = Parse::Agent::Tools.redact_hidden_classes!(payload)
    refute_match(/123-45-6789/, redacted.to_json,
                 "SSN must not survive post-fetch redaction")
    refute_match(/Maple St/, redacted.to_json,
                 "nested PII must not survive post-fetch redaction")
    # The placeholder retains the className but everything else is gone.
    nested = redacted.first["secret_record"]
    assert_equal "PatchHiddenIDs", nested["className"]
    assert nested["__redacted"]
  end

  def test_redact_hidden_classes_walker_passes_visible_data_through
    payload = [
      { "objectId" => "abc1", "name" => "Ada", "subject" => {
        "__type" => "Object", "className" => "PatchVisibleSubject", "name" => "Math",
      } },
    ]
    redacted = Parse::Agent::Tools.redact_hidden_classes!(payload)
    assert_equal "Ada",  redacted.first["name"]
    assert_equal "Math", redacted.first["subject"]["name"]
  end

  # Storage-form pointer columns. `aggregate` returns raw Mongo docs in which
  # a pointer field appears as `_p_<field>: "ClassName$objectId"`. A hash-only
  # redaction walker missed these strings, allowing a hidden class to leak
  # its name + objectId into aggregate output. The walker now scrubs them
  # in the same shape as the hash-form redaction.
  def test_redact_hidden_classes_walker_scrubs_p_prefix_strings_for_hidden_class
    payload = [
      {
        "objectId" => "row1",
        "_p_secret_record" => "PatchHiddenIDs$abc123",
        "label" => "ok",
      },
    ]
    redacted = Parse::Agent::Tools.redact_hidden_classes!(payload)
    refute_match(/abc123/, redacted.to_json,
                 "hidden-class objectId must not survive _p_* string redaction")
    scrubbed = redacted.first["_p_secret_record"]
    assert_kind_of Hash, scrubbed
    assert_equal "PatchHiddenIDs", scrubbed["className"]
    assert scrubbed["__redacted"]
  end

  def test_redact_hidden_classes_walker_passes_visible_p_prefix_strings_through
    payload = [
      {
        "objectId" => "row1",
        "_p_subject" => "PatchVisibleSubject$xyz999",
        "label" => "ok",
      },
    ]
    redacted = Parse::Agent::Tools.redact_hidden_classes!(payload)
    assert_equal "PatchVisibleSubject$xyz999", redacted.first["_p_subject"]
  end
end
