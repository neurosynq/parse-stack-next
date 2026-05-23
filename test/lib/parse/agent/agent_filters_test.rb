# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Unit tests for the per-agent per-class `filters:` kwarg.
#
# Per-agent filters AND-merge into every query the agent runs against the
# keyed class. They compose ON TOP of the class-level `agent_canonical_filter`
# (same intent at a different layer): class-canonical encodes "this class is
# always queried in this valid state"; per-agent encodes "this specific agent
# instance must never see X." Both layers apply; neither shadows the other.
class AgentFiltersTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app", api_key: "test-key")
    end
  end

  class FiltersTestAccount < Parse::Object
    parse_class "FiltersTestAccount"
    property :name, :string
    property :test_user, :boolean, default: false
  end

  class FiltersTestPost < Parse::Object
    parse_class "FiltersTestPost"
    property :title, :string
  end

  # ---- Kwarg shape validation ---------------------------------------------

  def test_filters_kwarg_accepts_class_constant_string_and_default_symbol
    agent = silence_master_key do
      Parse::Agent.new(filters: {
        FiltersTestAccount => { test_user: false },
        "FiltersTestPost"  => { archived: false },
        :default           => { tenant_active: true },
      })
    end
    # Class constants expand through hidden_name_variants_for; the canonical
    # parse_class name is what's stored. Strings pass through. :default stays a Symbol.
    assert agent.filters.key?("FiltersTestAccount"), "Class-constant key should normalize to parse_class String"
    assert agent.filters.key?("FiltersTestPost"),    "String key should pass through"
    assert agent.filters.key?(:default),             ":default symbol should be preserved"
  end

  def test_filters_kwarg_rejects_non_hash_value
    err = assert_raises(ArgumentError) do
      silence_master_key { Parse::Agent.new(filters: { "Account" => "not-a-hash" }) }
    end
    assert_match(/value must be a constraint Hash/, err.message)
  end

  def test_filters_kwarg_rejects_invalid_constraint_operator
    # Typo'd operator — ConstraintTranslator.valid? returns false, normalization raises.
    err = assert_raises(ArgumentError) do
      silence_master_key { Parse::Agent.new(filters: { "Account" => { score: { "$gtt" => 5 } } }) }
    end
    assert_match(/failed ConstraintTranslator validation/, err.message)
  end

  def test_filters_kwarg_rejects_top_level_non_hash
    err = assert_raises(ArgumentError) do
      silence_master_key { Parse::Agent.new(filters: [1, 2, 3]) }
    end
    assert_match(/must be a Hash mapping class/, err.message)
  end

  # ---- filter_for composition ---------------------------------------------

  def test_filter_for_returns_per_class_when_only_per_class_set
    agent = silence_master_key { Parse::Agent.new(filters: { "Account" => { test_user: false } }) }
    assert_equal({ test_user: false }, agent.filter_for("Account"))
  end

  def test_filter_for_returns_default_when_only_default_set
    agent = silence_master_key { Parse::Agent.new(filters: { :default => { tenant_active: true } }) }
    assert_equal({ tenant_active: true }, agent.filter_for("AnyClass"))
  end

  def test_filter_for_merges_per_class_and_default_with_class_winning
    agent = silence_master_key do
      Parse::Agent.new(filters: {
        "Account" => { test_user: false, tenant_active: true },  # explicit field also in :default
        :default  => { tenant_active: false },                    # different value for same field
      })
    end
    # Class entry's tenant_active wins over :default's tenant_active (more specific declaration).
    merged = agent.filter_for("Account")
    assert_equal false, merged[:test_user]
    assert_equal true,  merged[:tenant_active], "per-class value must win over :default on key conflict"
  end

  def test_filter_for_returns_nil_when_no_filter_applies_and_no_default
    agent = silence_master_key { Parse::Agent.new(filters: { "Account" => { test_user: false } }) }
    assert_nil agent.filter_for("UnrelatedClass")
  end

  def test_filter_for_returns_nil_when_no_filters_kwarg
    agent = silence_master_key { Parse::Agent.new }
    assert_nil agent.filter_for("AnyClass")
  end

  def test_filter_for_canonicalizes_class_constant_and_parse_class_string_symmetrically
    agent = silence_master_key { Parse::Agent.new(filters: { Parse::User => { confirmed: true } }) }
    assert_equal({ confirmed: true }, agent.filter_for("_User")
    )
    assert_equal({ confirmed: true }, agent.filter_for("User"))
    assert_equal({ confirmed: true }, agent.filter_for(Parse::User))
  end

  # ---- apply_per_agent_filter_to_where composition ------------------------
  #
  # TRACK-AGENT-7: per-agent filter merging lives in
  # apply_per_agent_filter_to_where (UNCONDITIONAL, no LLM kwarg can
  # disable). The legacy apply_canonical_filter_to_where helper now
  # only applies the class-level `agent_canonical_filter` declaration,
  # not the per-agent filter, so these tests target the split helper.

  def test_where_merger_wraps_per_agent_filter_alongside_caller_where
    agent = silence_master_key { Parse::Agent.new(filters: { "Account" => { test_user: false } }) }
    composed = Parse::Agent::Tools.apply_per_agent_filter_to_where({ archived: false }, "Account", agent: agent)
    assert composed.key?("$and"), "non-empty caller where + per-agent filter must compose via $and"
    assert_includes composed["$and"], { test_user: false }
    assert_includes composed["$and"], { archived: false }
  end

  def test_where_merger_returns_per_agent_filter_when_caller_where_empty
    agent = silence_master_key { Parse::Agent.new(filters: { "Account" => { test_user: false } }) }
    composed = Parse::Agent::Tools.apply_per_agent_filter_to_where(nil, "Account", agent: agent)
    assert_equal({ test_user: false }, composed)
  end

  def test_where_merger_no_op_without_filter_or_canonical
    agent = silence_master_key { Parse::Agent.new }
    composed = Parse::Agent::Tools.apply_per_agent_filter_to_where({ archived: false }, "Account", agent: agent)
    assert_equal({ archived: false }, composed)
  end

  # ---- apply_per_agent_filter_to_pipeline composition ---------------------

  def test_pipeline_prepender_inserts_match_stage_after_leading_tenant_match
    agent = silence_master_key { Parse::Agent.new(filters: { "Account" => { test_user: false } }) }
    pipeline = [
      { "$match" => { tenant: "acme" } },  # tenant-scope $match at index 0
      { "$sort"  => { name: 1 } },
    ]
    out = Parse::Agent::Tools.apply_per_agent_filter_to_pipeline(pipeline, "Account", agent: agent)
    assert_equal({ "$match" => { tenant: "acme" } }, out[0], "tenant-scope match stays at index 0")
    assert_equal({ "$match" => { test_user: false } }, out[1], "per-agent filter goes at index 1")
    assert_equal({ "$sort"  => { name: 1 } }, out[2])
  end

  def test_pipeline_prepender_no_op_when_no_filter_applies
    agent = silence_master_key { Parse::Agent.new }
    pipeline = [{ "$sort" => { name: 1 } }]
    assert_equal pipeline, Parse::Agent::Tools.apply_per_agent_filter_to_pipeline(pipeline, "Account", agent: agent)
  end

  # ---- Sub-agent inheritance ----------------------------------------------

  def test_sub_agent_inherits_parent_filters_when_kwarg_omitted
    parent = silence_master_key { Parse::Agent.new(filters: { "Account" => { test_user: false } }) }
    child = Parse::Agent.new(parent: parent)
    assert_equal({ test_user: false }, child.filter_for("Account"))
  end

  def test_sub_agent_filters_merge_with_parent_child_winning_on_field_conflict
    parent = silence_master_key { Parse::Agent.new(filters: { "Account" => { test_user: false, region: "global" } }) }
    child = Parse::Agent.new(parent: parent, filters: { "Account" => { region: "us" } })
    merged = child.filter_for("Account")
    assert_equal false, merged[:test_user], "parent's other-field constraint must survive"
    assert_equal "us",  merged[:region],    "child's region must override parent's on key conflict"
  end

  def test_sub_agent_adds_new_class_keys_without_disturbing_parent_keys
    parent = silence_master_key { Parse::Agent.new(filters: { "Account" => { test_user: false } }) }
    child = Parse::Agent.new(parent: parent, filters: { "Comment" => { spam: false } })
    assert_equal({ test_user: false }, child.filter_for("Account"))
    assert_equal({ spam: false },      child.filter_for("Comment"))
  end

  # ---- Audit payload ------------------------------------------------------

  def test_tool_call_notification_includes_filters_key
    payload = nil
    sub = ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |*args|
      payload = args.last
    end
    agent = silence_master_key { Parse::Agent.new(filters: { "FiltersTestAccount" => { test_user: false } }) }
    # Trigger an audit by running any tool. count_objects against a hidden class
    # fails fast at the dispatcher gate, fires the notification, and emits the
    # payload — no Parse Server traffic needed for the assertion.
    agent.execute(:count_objects, class_name: "AgentClassFilterTest::ClassFilterHidden")

    assert payload, "expected parse.agent.tool_call notification to fire"
    assert payload[:filters].is_a?(Hash), "payload[:filters] should be present"
    assert payload[:filters].key?("FiltersTestAccount")
    assert_equal ["test_user"], payload[:filters]["FiltersTestAccount"],
                 "payload should echo FIELD NAMES, not constraint values"
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  def test_tool_call_notification_omits_filters_key_when_unscoped
    payload = nil
    sub = ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |*args|
      payload = args.last
    end
    agent = silence_master_key { Parse::Agent.new }
    agent.execute(:count_objects, class_name: "AgentClassFilterTest::ClassFilterHidden")
    refute payload.key?(:filters), "unscoped agent should not emit :filters key"
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  private

  def silence_master_key
    was = Parse::Agent.suppress_master_key_warning
    Parse::Agent.suppress_master_key_warning = true
    yield
  ensure
    Parse::Agent.suppress_master_key_warning = was unless was.nil?
  end
end
