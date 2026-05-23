# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Unit tests for `Parse::Agent#describe`, `#describe_for(class_name)`, and
# `#would_permit?`. These are developer-introspection helpers — NOT exposed
# to the LLM. The session_token must never be emitted verbatim; mode +
# fingerprint is the entire wire surface for auth.
class AgentDescribeTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "test-app", api_key: "test-key")
    end
  end

  class DescribeAccount < Parse::Object
    parse_class "DescribeAccount"
    property :name, :string
    property :test_user, :boolean, default: false
  end

  class DescribePost < Parse::Object
    parse_class "DescribePost"
    property :title, :string
  end

  # ---- describe (Hash form) -----------------------------------------------

  def test_describe_returns_hash_with_required_keys
    agent = silence_master_key { Parse::Agent.new(permissions: :readonly) }
    data = agent.describe
    assert_kind_of Hash, data
    assert data.key?(:agent_id)
    assert data.key?(:auth)
    assert data.key?(:permissions)
    assert data.key?(:classes)
    assert data.key?(:tools)
    assert data.key?(:methods)
    assert data.key?(:filters)
    assert data.key?(:hidden_classes)
    assert data.key?(:per_class)
    assert data.key?(:strict_modes)
  end

  def test_describe_auth_master_key_mode_omits_fingerprint
    agent = silence_master_key { Parse::Agent.new }
    auth = agent.describe[:auth]
    assert_equal :master_key, auth[:mode]
    refute auth.key?(:fingerprint), "master-key mode must not emit a fingerprint"
  end

  def test_describe_auth_session_token_mode_emits_fingerprint_not_value
    agent = silence_master_key { Parse::Agent.new(session_token: "r:secret_abc123") }
    auth = agent.describe[:auth]
    assert_equal :session_token, auth[:mode]
    assert auth[:fingerprint].is_a?(String)
    assert_equal 8, auth[:fingerprint].length, "fingerprint must be 8 hex chars"
    refute_match(/secret_abc123/, agent.describe.inspect, "raw session_token must never appear in describe output")
  end

  def test_describe_session_token_fingerprint_is_deterministic_per_token
    a = silence_master_key { Parse::Agent.new(session_token: "r:same_token_xyz") }
    b = silence_master_key { Parse::Agent.new(session_token: "r:same_token_xyz") }
    c = silence_master_key { Parse::Agent.new(session_token: "r:different_token") }
    assert_equal a.describe[:auth][:fingerprint], b.describe[:auth][:fingerprint]
    refute_equal a.describe[:auth][:fingerprint], c.describe[:auth][:fingerprint]
  end

  def test_describe_classes_emits_only_and_except_sets
    agent = silence_master_key do
      Parse::Agent.new(classes: { only: [DescribePost, DescribeAccount], except: [Parse::Session] })
    end
    classes = agent.describe[:classes]
    assert_includes classes[:only],   "DescribePost"
    assert_includes classes[:only],   "DescribeAccount"
    assert_includes classes[:except], "_Session"
  end

  def test_describe_tools_effective_set_reflects_permission_tier_and_filter
    agent = silence_master_key do
      Parse::Agent.new(permissions: :readonly, tools: { except: [:get_schema] })
    end
    tools = agent.describe[:tools]
    assert_equal [:get_schema], tools[:except]
    refute_includes tools[:effective], :get_schema, "effective set must reflect the filter narrowing"
    refute_includes tools[:effective], :create_object, "effective set must reflect the permission tier"
  end

  def test_describe_filters_summary_emits_field_names_not_values
    agent = silence_master_key do
      Parse::Agent.new(filters: { "DescribeAccount" => { test_user: false, region: "us" } })
    end
    summary = agent.describe[:filters]
    assert_equal({ "DescribeAccount" => ["region", "test_user"] }, summary)
    refute_match(/\bfalse\b|"us"/, summary.inspect, "filter VALUES must never appear in describe summary")
  end

  def test_describe_per_class_entry_summarizes_explicit_class_references
    agent = silence_master_key do
      Parse::Agent.new(classes: { only: [DescribePost] },
                       filters: { "DescribeAccount" => { test_user: false } })
    end
    per_class = agent.describe[:per_class]
    # DescribePost is explicitly named in classes:.
    assert per_class.key?("DescribePost"), "explicitly-allowlisted class must appear in per_class"
    # DescribeAccount is explicitly named in filters: (even though not in classes:).
    assert per_class.key?("DescribeAccount"), "explicitly-filtered class must appear in per_class"
    # An unmentioned class must NOT appear.
    refute per_class.key?("_User"), "unmentioned class must NOT appear in per_class"
  end

  def test_describe_per_class_accessibility_marks_class_filter_excluded
    agent = silence_master_key do
      Parse::Agent.new(classes: { only: [DescribePost] },
                       filters: { "DescribeAccount" => { test_user: false } })
    end
    per_class = agent.describe[:per_class]
    # DescribePost is permitted (in classes.only).
    assert_equal :permitted, per_class["DescribePost"][:accessible]
    # DescribeAccount is filtered out (in filters, NOT in classes.only).
    assert_equal :class_filter_excluded, per_class["DescribeAccount"][:accessible]
  end

  # ---- describe(pretty: true) ---------------------------------------------

  def test_describe_pretty_returns_multiline_string
    agent = silence_master_key { Parse::Agent.new(permissions: :readonly) }
    text = agent.describe(pretty: true)
    assert_kind_of String, text
    assert text.lines.count > 3, "pretty output should be multi-line"
    assert_match(/Parse::Agent /, text)
    assert_match(/permissions: readonly/, text)
  end

  def test_describe_pretty_never_emits_raw_session_token
    agent = silence_master_key { Parse::Agent.new(session_token: "r:NEVER_LEAK_THIS_TOKEN") }
    text = agent.describe(pretty: true)
    refute_match(/NEVER_LEAK_THIS_TOKEN/, text)
    assert_match(/fingerprint=[0-9a-f]{8}/, text)
  end

  # ---- describe_for(class_name) -------------------------------------------

  def test_describe_for_accepts_class_constant_string_and_symbol
    agent = silence_master_key { Parse::Agent.new }
    by_const  = agent.describe_for(DescribePost)
    by_string = agent.describe_for("DescribePost")
    assert_equal by_const[:class_name],  by_string[:class_name]
    assert_equal "DescribePost", by_const[:class_name]
  end

  def test_describe_for_returns_per_agent_filter
    agent = silence_master_key do
      Parse::Agent.new(filters: { "DescribeAccount" => { test_user: false } })
    end
    result = agent.describe_for("DescribeAccount")
    assert_equal({ test_user: false }, result[:per_agent_filter])
  end

  def test_describe_for_unmentioned_class_returns_nil_metadata
    agent = silence_master_key { Parse::Agent.new }
    result = agent.describe_for("CompletelyUnknownClass")
    assert_equal :permitted, result[:accessible]
    assert_nil result[:agent_fields]
    assert_nil result[:per_agent_filter]
  end

  # ---- would_permit? -------------------------------------------------------

  def test_would_permit_returns_allowed_when_all_gates_pass
    agent = silence_master_key { Parse::Agent.new(permissions: :readonly) }
    result = agent.would_permit?(:query_class, class_name: "DescribePost")
    assert_equal({ allowed: true }, result)
  end

  def test_would_permit_returns_tool_filtered_when_tool_outside_filter
    agent = silence_master_key { Parse::Agent.new(tools: { only: [:query_class] }) }
    result = agent.would_permit?(:get_schema, class_name: "DescribePost")
    refute result[:allowed]
    assert_equal :tool_filtered, result[:reason]
    assert_equal :allowed_tools, result[:denied_at]
  end

  def test_would_permit_returns_tool_filtered_when_tool_outside_permission_tier
    agent = silence_master_key { Parse::Agent.new(permissions: :readonly) }
    # create_object is a :write tier tool.
    result = agent.would_permit?(:create_object, class_name: "DescribePost")
    refute result[:allowed]
    assert_equal :tool_filtered, result[:reason]
  end

  def test_would_permit_returns_class_filter_kind_when_class_outside_allowlist
    agent = silence_master_key { Parse::Agent.new(classes: { only: [DescribePost] }) }
    result = agent.would_permit?(:query_class, class_name: "DescribeAccount")
    refute result[:allowed]
    assert_equal :class_filter, result[:reason]
    assert_equal :assert_class_accessible!, result[:denied_at]
  end

  def test_would_permit_returns_hidden_class_kind_when_class_globally_hidden
    agent = silence_master_key { Parse::Agent.new }
    result = agent.would_permit?(:query_class, class_name: "_Product")
    refute result[:allowed]
    # Product is hidden by default in v4.2.3+; kind comes back as :access_denied
    # (the default AccessDenied kind for the unscoped global hidden gate).
    refute_nil result[:reason]
  end

  def test_would_permit_handles_tools_without_class_name_argument
    agent = silence_master_key { Parse::Agent.new(permissions: :readonly) }
    result = agent.would_permit?(:get_all_schemas)
    assert_equal({ allowed: true }, result)
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
