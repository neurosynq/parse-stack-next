# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require "parse/agent/prompts"

class PromptsTest < Minitest::Test
  P = Parse::Agent::Prompts
  V = Parse::Agent::Prompts::Validators

  def setup
    P.reset_registry!
  end

  # -------------------------------------------------------------------------
  # list
  # -------------------------------------------------------------------------

  def test_list_includes_all_builtins
    names = P.list.map { |p| p["name"] }
    %w[
      parse_conventions parse_relations explore_database class_overview
      count_by recent_activity find_relationship created_in_range
    ].each { |n| assert_includes names, n }
  end

  def test_list_entries_have_string_keys
    entry = P.list.first
    assert entry.key?("name"),        "entry should have string key 'name'"
    assert entry.key?("description"), "entry should have string key 'description'"
    assert entry.key?("arguments"),   "entry should have string key 'arguments'"
  end

  def test_list_with_registered_prompt_includes_custom
    P.register(name: "my_custom", description: "Custom", renderer: ->(_) { "text" })
    names = P.list.map { |p| p["name"] }
    assert_includes names, "my_custom"
  end

  def test_list_registered_overrides_builtin
    P.register(name: "explore_database", description: "Overridden", renderer: ->(_) { "new text" })
    entries = P.list.select { |p| p["name"] == "explore_database" }
    assert_equal 1, entries.size, "should only appear once"
    assert_equal "Overridden", entries.first["description"]
  end

  # -------------------------------------------------------------------------
  # render — response shape
  # -------------------------------------------------------------------------

  def test_render_returns_description_and_messages_keys
    result = P.render("parse_conventions")
    assert result.key?("description")
    assert result.key?("messages")
  end

  def test_render_messages_has_correct_shape
    result = P.render("parse_conventions")
    msg = result["messages"].first
    assert_equal "user", msg["role"]
    assert_equal "text", msg["content"]["type"]
    assert_kind_of String, msg["content"]["text"]
    refute_empty msg["content"]["text"]
  end

  def test_render_description_defaults_to_analytics_prefix
    result = P.render("explore_database")
    assert_equal "Parse analytics prompt: explore_database", result["description"]
  end

  # -------------------------------------------------------------------------
  # render — each builtin with valid args
  # -------------------------------------------------------------------------

  def test_render_parse_conventions
    result = P.render("parse_conventions")
    assert_includes result["messages"].first["content"]["text"], "objectId"
  end

  def test_render_class_overview
    result = P.render("class_overview", "class_name" => "Song")
    assert_includes result["messages"].first["content"]["text"], "Song"
  end

  def test_render_count_by
    result = P.render("count_by", "class_name" => "Song", "group_by" => "genre")
    text = result["messages"].first["content"]["text"]
    assert_includes text, "Song"
    assert_includes text, "genre"
  end

  def test_render_recent_activity
    result = P.render("recent_activity", "class_name" => "Post", "limit" => "5")
    text = result["messages"].first["content"]["text"]
    assert_includes text, "Post"
    assert_includes text, "5"
  end

  def test_render_recent_activity_default_limit
    result = P.render("recent_activity", "class_name" => "Post")
    assert_includes result["messages"].first["content"]["text"], "10"
  end

  def test_render_recent_activity_clamps_limit_to_100
    result = P.render("recent_activity", "class_name" => "Post", "limit" => "999")
    assert_includes result["messages"].first["content"]["text"], "100"
  end

  def test_render_find_relationship
    result = P.render("find_relationship",
      "parent_class"  => "Team",
      "parent_id"     => "abc123",
      "child_class"   => "_User",
      "pointer_field" => "team")
    text = result["messages"].first["content"]["text"]
    assert_includes text, "Team"
    assert_includes text, "abc123"
    assert_includes text, "_User"
  end

  def test_render_created_in_range_without_until
    result = P.render("created_in_range",
      "class_name" => "Event",
      "since"      => "2024-01-01T00:00:00Z")
    text = result["messages"].first["content"]["text"]
    assert_includes text, "Event"
    refute_includes text, "and before"
  end

  def test_render_created_in_range_with_until
    result = P.render("created_in_range",
      "class_name" => "Event",
      "since"      => "2024-01-01T00:00:00Z",
      "until"      => "2024-12-31T23:59:59Z")
    text = result["messages"].first["content"]["text"]
    assert_includes text, "and before"
  end

  # -------------------------------------------------------------------------
  # render — unknown prompt raises ValidationError
  # -------------------------------------------------------------------------

  def test_render_unknown_name_raises_validation_error
    err = assert_raises(Parse::Agent::ValidationError) { P.render("no_such_prompt") }
    assert_equal "Unknown prompt: no_such_prompt", err.message
  end

  # -------------------------------------------------------------------------
  # render — bad args raise ValidationError
  # -------------------------------------------------------------------------

  def test_render_class_overview_missing_class_name_raises
    assert_raises(Parse::Agent::ValidationError) { P.render("class_overview", {}) }
  end

  def test_render_class_overview_invalid_class_name_raises
    assert_raises(Parse::Agent::ValidationError) do
      P.render("class_overview", "class_name" => "bad name!")
    end
  end

  def test_render_find_relationship_invalid_object_id_raises
    assert_raises(Parse::Agent::ValidationError) do
      P.render("find_relationship",
        "parent_class"  => "Team",
        "parent_id"     => "has spaces!",
        "child_class"   => "_User",
        "pointer_field" => "team")
    end
  end

  def test_render_created_in_range_invalid_iso8601_raises
    assert_raises(Parse::Agent::ValidationError) do
      P.render("created_in_range",
        "class_name" => "Event",
        "since"      => "not-a-date")
    end
  end

  def test_render_created_in_range_missing_since_raises
    assert_raises(Parse::Agent::ValidationError) do
      P.render("created_in_range", "class_name" => "Event")
    end
  end

  # -------------------------------------------------------------------------
  # register — custom prompts
  # -------------------------------------------------------------------------

  def test_register_adds_custom_prompt
    P.register(name: "greet", description: "Greet", renderer: ->(args) { "Hello #{args['who']}" })
    result = P.render("greet", "who" => "World")
    assert_equal "Hello World", result["messages"].first["content"]["text"]
  end

  def test_register_replaces_same_name_prompt
    P.register(name: "greet", description: "First",  renderer: ->(_) { "first" })
    P.register(name: "greet", description: "Second", renderer: ->(_) { "second" })
    assert_equal "second", P.render("greet")["messages"].first["content"]["text"]
  end

  def test_register_renderer_returning_hash_uses_description_and_text
    P.register(
      name:        "rich",
      description: "Rich prompt",
      renderer:    ->(_) { { description: "Custom desc", text: "Custom text" } }
    )
    result = P.render("rich")
    assert_equal "Custom desc", result["description"]
    assert_equal "Custom text", result["messages"].first["content"]["text"]
  end

  # -------------------------------------------------------------------------
  # Validators
  # -------------------------------------------------------------------------

  def test_validate_identifier_accepts_valid_names
    assert_equal "Song",  V.validate_identifier!("Song",  "class_name")
    assert_equal "_User", V.validate_identifier!("_User", "class_name")
    assert_equal "my_field2", V.validate_identifier!("my_field2", "field")
  end

  def test_validate_identifier_rejects_empty
    assert_raises(Parse::Agent::ValidationError) { V.validate_identifier!(nil,  "f") }
    assert_raises(Parse::Agent::ValidationError) { V.validate_identifier!("",   "f") }
  end

  def test_validate_identifier_rejects_bad_chars
    assert_raises(Parse::Agent::ValidationError) { V.validate_identifier!("bad name", "f") }
    assert_raises(Parse::Agent::ValidationError) { V.validate_identifier!("1bad",     "f") }
  end

  def test_validate_object_id_accepts_alphanumeric
    assert_equal "abc123", V.validate_object_id!("abc123", "id")
  end

  def test_validate_object_id_rejects_spaces_and_punctuation
    assert_raises(Parse::Agent::ValidationError) { V.validate_object_id!("abc 123", "id") }
    assert_raises(Parse::Agent::ValidationError) { V.validate_object_id!("abc-123", "id") }
  end

  def test_validate_iso8601_accepts_valid_timestamps
    result = V.validate_iso8601!("2024-01-15T12:00:00Z", "ts")
    assert_kind_of String, result
    assert_match(/\d{4}-\d{2}-\d{2}/, result)
  end

  def test_validate_iso8601_returns_nil_when_optional_and_absent
    assert_nil V.validate_iso8601!(nil, "ts", required: false)
    assert_nil V.validate_iso8601!("",  "ts", required: false)
  end

  def test_validate_iso8601_raises_when_required_and_absent
    assert_raises(Parse::Agent::ValidationError) { V.validate_iso8601!(nil, "ts") }
  end

  def test_validate_iso8601_raises_for_bad_format
    assert_raises(Parse::Agent::ValidationError) { V.validate_iso8601!("not-a-date", "ts") }
  end

  # -------------------------------------------------------------------------
  # reset_registry!
  # -------------------------------------------------------------------------

  def test_reset_registry_removes_custom_prompts
    P.register(name: "temp", description: "Temp", renderer: ->(_) { "x" })
    assert_includes P.list.map { |p| p["name"] }, "temp"
    P.reset_registry!
    refute_includes P.list.map { |p| p["name"] }, "temp"
  end
end
