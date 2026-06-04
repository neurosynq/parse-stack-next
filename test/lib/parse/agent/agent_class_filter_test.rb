# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Verifies the per-agent `classes:` allowlist that lets an operator narrow a
# single Agent instance to a subset of Parse classes. The composition rule:
# the per-agent filter is the ceiling, not the floor — it cannot re-enable a
# globally `agent_hidden` class, and it cannot widen what `permissions:` /
# `agent_fields` / `tenant_id` already allowed. It strictly narrows.
class AgentClassFilterTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app", api_key: "test-key")
    end
  end

  class ClassFilterPost < Parse::Object
    parse_class "ClassFilterPost"
    property :title, :string
    belongs_to :author, as: :pointer, class_name: "ClassFilterAuthor"
  end

  class ClassFilterTopic < Parse::Object
    parse_class "ClassFilterTopic"
    property :name, :string
  end

  class ClassFilterComment < Parse::Object
    parse_class "ClassFilterComment"
    property :body, :string
  end

  class ClassFilterAuthor < Parse::Object
    parse_class "ClassFilterAuthor"
    property :name, :string
  end

  class ClassFilterHidden < Parse::Object
    parse_class "ClassFilterHidden"
    property :secret, :string
    agent_hidden
  end

  # ---- Basic only/except semantics ----------------------------------------

  def test_only_form_permits_listed_class
    agent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    Parse::Agent::Tools.assert_class_accessible!("ClassFilterPost", agent: agent)
  end

  def test_only_form_refuses_unlisted_class
    agent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    err = assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.assert_class_accessible!("ClassFilterComment", agent: agent)
    end
    assert_equal :class_filter, err.kind, "denial reason should distinguish agent narrowing from policy hiding"
  end

  def test_except_form_refuses_listed_and_permits_others
    agent = silence_master_key { Parse::Agent.new(classes: { except: [ClassFilterComment] }) }
    Parse::Agent::Tools.assert_class_accessible!("ClassFilterPost", agent: agent)
    err = assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.assert_class_accessible!("ClassFilterComment", agent: agent)
    end
    assert_equal :class_filter, err.kind
  end

  def test_flat_array_is_implicit_only
    agent = silence_master_key { Parse::Agent.new(classes: [ClassFilterPost, ClassFilterTopic]) }
    Parse::Agent::Tools.assert_class_accessible!("ClassFilterTopic", agent: agent)
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.assert_class_accessible!("ClassFilterComment", agent: agent)
    end
  end

  # ---- Class constants vs strings -----------------------------------------

  def test_string_and_constant_canonicalize_identically
    by_const  = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    by_string = silence_master_key { Parse::Agent.new(classes: { only: ["ClassFilterPost"] }) }
    assert_equal by_const.class_filter_only.include?("ClassFilterPost"),
                 by_string.class_filter_only.include?("ClassFilterPost")
    Parse::Agent::Tools.assert_class_accessible!("ClassFilterPost", agent: by_string)
  end

  def test_const_expands_through_name_variants
    # Parse::User has parse_class "_User" and Ruby name "User" — both forms
    # should match the allowlist entry built from the constant.
    agent = silence_master_key { Parse::Agent.new(classes: { only: [Parse::User] }) }
    Parse::Agent::Tools.assert_class_accessible!("_User", agent: agent)
    Parse::Agent::Tools.assert_class_accessible!("User", agent: agent)
  end

  # ---- Composition with global agent_hidden -------------------------------

  def test_only_cannot_re_enable_globally_hidden_class
    # Even if the operator lists a globally-hidden class in `only:`, the
    # registry gate still refuses. The per-agent filter is the ceiling.
    agent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterHidden, ClassFilterPost] }) }
    assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.assert_class_accessible!("ClassFilterHidden", agent: agent)
    end
    Parse::Agent::Tools.assert_class_accessible!("ClassFilterPost", agent: agent)
  end

  # ---- Pointer-include defense-in-depth -----------------------------------

  def test_pointer_include_refuses_off_allowlist_target
    # Post belongs_to author (ClassFilterAuthor). With Post permitted but
    # Author NOT in the allowlist, include: ["author"] must be refused at
    # walk_pointer_path! — the deep gate, not just the top-level.
    agent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    err = assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.assert_include_paths_accessible!("ClassFilterPost", ["author"], agent: agent)
    end
    assert_equal :class_filter, err.kind
  end

  # ---- Aggregation pipeline defense-in-depth ------------------------------

  def test_lookup_from_off_allowlist_target_is_refused
    agent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    pipeline = [{ "$lookup" => { "from" => "ClassFilterComment", "as" => "cs", "localField" => "x", "foreignField" => "y" } }]
    err = assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::Tools.enforce_pipeline_access_policy!("ClassFilterPost", pipeline, agent: agent)
    end
    assert_equal :class_filter, err.kind
  end

  # ---- Post-fetch redaction floor -----------------------------------------

  def test_walk_and_redact_scrubs_off_allowlist_pointer_strings
    agent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    row = {
      "objectId" => "abc",
      "_p_author" => "ClassFilterAuthor$xyz",  # off-allowlist class via pointer-storage string
    }
    cleaned = Parse::Agent::Tools.redact_hidden_classes!([row], agent: agent).first
    assert_kind_of Hash, cleaned["_p_author"], "off-allowlist pointer string should be replaced with redacted placeholder"
    assert cleaned["_p_author"]["__redacted"], "redaction placeholder must carry __redacted: true"
  end

  def test_walk_and_redact_scrubs_off_allowlist_nested_object
    agent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    row = {
      "objectId" => "abc",
      "author" => { "__type" => "Object", "className" => "ClassFilterAuthor", "objectId" => "xyz", "name" => "leak" },
    }
    cleaned = Parse::Agent::Tools.redact_hidden_classes!([row], agent: agent).first
    refute cleaned["author"].key?("name"), "off-allowlist class object must not surface user fields"
    assert cleaned["author"]["__redacted"], "off-allowlist class object must be replaced with redacted placeholder"
  end

  # ---- Sub-agent inheritance ----------------------------------------------

  def test_sub_agent_intersects_parent_class_filter
    parent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost, ClassFilterTopic] }) }
    child = Parse::Agent.new(parent: parent, classes: { only: [ClassFilterTopic, ClassFilterComment] })
    # Intersection = ClassFilterTopic only.
    assert child.class_filter_permits?("ClassFilterTopic")
    refute child.class_filter_permits?("ClassFilterPost"),    "child should not retain non-intersected parent class"
    refute child.class_filter_permits?("ClassFilterComment"), "child should not see classes outside the intersection"
  end

  def test_sub_agent_with_empty_intersection_raises
    parent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    assert_raises(ArgumentError) do
      Parse::Agent.new(parent: parent, classes: { only: [ClassFilterComment] })
    end
  end

  def test_sub_agent_inherits_parent_class_filter_when_kwarg_omitted
    parent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    child = Parse::Agent.new(parent: parent)
    assert child.class_filter_permits?("ClassFilterPost")
    refute child.class_filter_permits?("ClassFilterComment")
  end

  # ---- Strict mode --------------------------------------------------------

  def test_strict_mode_raises_on_unknown_class
    err = assert_raises(ArgumentError) do
      silence_master_key { Parse::Agent.new(classes: { only: ["TotallyNotARealClass"] }, strict_class_filter: true) }
    end
    assert_match(/TotallyNotARealClass/, err.message)
  end

  def test_default_mode_warns_on_unknown_class_but_proceeds
    captured = capture_warn do
      silence_master_key { Parse::Agent.new(classes: { only: ["TotallyNotARealClass"] }) }
    end
    assert_match(/TotallyNotARealClass/, captured)
  end

  def test_invalid_kwarg_shape_raises
    assert_raises(ArgumentError) do
      silence_master_key { Parse::Agent.new(classes: "not-a-list") }
    end
  end

  # ---- Cross-class constraint operator ($inQuery) -------------------------

  def test_in_query_against_off_allowlist_class_raises_access_denied_not_security_blocked
    agent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    # $inQuery references a className the agent's filter excludes. The expected
    # behavior is AccessDenied (kind: :class_filter) reaching the dispatcher,
    # NOT ConstraintSecurityError that would collapse to `:security_blocked` in
    # the audit payload. The translator was rewrapping any StandardError from
    # the embedded-class check; that erased the SOC-relevant `:denial_kind`
    # subcode and forced operators to disambiguate operator-narrowing from
    # injection attempts via message parsing.
    constraints = { "author" => { "$inQuery" => { "className" => "ClassFilterComment", "where" => {} } } }
    err = assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::ConstraintTranslator.translate(constraints, agent)
    end
    assert_equal :class_filter, err.kind,
                 "per-agent denial from inside a cross-class constraint must preserve :class_filter kind"
  end

  # ---- Audit payload ------------------------------------------------------

  def test_tool_call_notification_includes_classes_filter
    payload = nil
    sub = ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |*args|
      payload = args.last
    end

    agent = silence_master_key do
      Parse::Agent.new(classes: { only: [ClassFilterPost, ClassFilterTopic] })
    end
    # Drive a tool call that fails fast on the agent-side gate. count_objects
    # for an off-allowlist class triggers AccessDenied without ever hitting
    # Parse Server, so the notification fires deterministically in a unit-test
    # context where no Parse Server is reachable.
    agent.execute(:count_objects, class_name: "ClassFilterComment")

    assert payload, "expected parse.agent.tool_call notification to fire"
    assert_equal ["ClassFilterPost", "ClassFilterTopic"], payload[:classes_only]
    assert_equal :access_denied, payload[:error_code]
    assert_equal :class_filter, payload[:denial_kind],
                 "audit payload must distinguish operator narrowing from policy hiding"
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  def test_tool_call_notification_omits_filter_keys_when_unscoped
    payload = nil
    sub = ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |*args|
      payload = args.last
    end

    agent = silence_master_key { Parse::Agent.new }
    # No filter declared: classes_only / classes_except must not appear.
    agent.execute(:count_objects, class_name: "ClassFilterHidden")  # globally hidden, will deny
    refute payload.key?(:classes_only),   "unscoped agent should not emit classes_only"
    refute payload.key?(:classes_except), "unscoped agent should not emit classes_except"
    # AccessDenied from the global hidden gate still carries the :hidden_class kind.
    assert_equal :access_denied, payload[:error_code]
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  # ---- $relatedTo owning-object class is subject to the filter -------------
  # $relatedTo names a relation on an owning object in a second class. The
  # filter must gate that owning class the same way it gates $inQuery's
  # className, or an agent narrowed to one class could read relations
  # anchored on an off-allowlist class (SDK analog of GHSA-wmwx-jr2p-4j4r).

  def test_relatedTo_owning_class_outside_allowlist_is_refused
    agent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    constraints = {
      "$relatedTo" => {
        "object" => { "__type" => "Pointer", "className" => "ClassFilterComment", "objectId" => "x1" },
        "key" => "comments",
      },
    }
    err = assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::ConstraintTranslator.translate(constraints, agent)
    end
    assert_equal :class_filter, err.kind,
                 "off-allowlist $relatedTo owning class should deny with :class_filter"
  end

  def test_relatedTo_owning_class_inside_allowlist_is_permitted
    agent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    constraints = {
      "$relatedTo" => {
        "object" => { "__type" => "Pointer", "className" => "ClassFilterPost", "objectId" => "p1" },
        "key" => "tags",
      },
    }
    # Permitted owning class: translates without raising.
    out = Parse::Agent::ConstraintTranslator.translate(constraints, agent)
    assert_equal "ClassFilterPost", out["$relatedTo"]["object"]["className"]
  end

  def test_relatedTo_owning_class_checked_when_nested_in_or_with_field_sibling
    # Regression: a $relatedTo sharing a hash with a non-operator sibling
    # inside $or must still validate its owning class. The previous
    # all-operators gate routed mixed hashes to the field branch and skipped
    # the check, leaving the per-agent allowlist bypassable on the REST path.
    agent = silence_master_key { Parse::Agent.new(classes: { only: [ClassFilterPost] }) }
    constraints = {
      "$or" => [
        {
          "$relatedTo" => {
            "object" => { "__type" => "Pointer", "className" => "ClassFilterComment", "objectId" => "c1" },
            "key" => "comments",
          },
          "createdAt" => { "$exists" => true },
        },
      ],
    }
    err = assert_raises(Parse::Agent::AccessDenied) do
      Parse::Agent::ConstraintTranslator.translate(constraints, agent)
    end
    assert_equal :class_filter, err.kind
  end

  private

  def silence_master_key
    was = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
    yield
  ensure
    Parse::Agent.suppress_master_key_warning = was unless was.nil?
  end

  def capture_warn
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
