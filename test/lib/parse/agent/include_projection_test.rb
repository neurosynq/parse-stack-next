# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Tests for the keys-on-include auto-projection introduced in 4.2.1.
# Covers the `agent_join_fields` DSL, the `MetadataRegistry.join_projection_fields`
# resolver, and the `Parse::Agent::Tools.apply_include_projection` integration.
class IncludeProjectionTest < Minitest::Test
  # ============================================================
  # Fixtures
  # ============================================================

  # Joined class with explicit agent_join_fields (narrowest projection).
  class FixtureJoinUser < Parse::Object
    parse_class "FixtureJoinUser"
    property :first_name, :string
    property :last_name, :string
    property :email, :string
    property :icon_image, :string
    property :source_image, :string
    property :category, :string
    property :phone_verified, :boolean
    agent_fields :first_name, :last_name, :email, :icon_image, :source_image,
                 :category, :phone_verified
    agent_large_fields :icon_image, :source_image
    agent_join_fields :first_name, :last_name, :email, :category
  end

  # Joined class without agent_join_fields — falls back to
  # agent_fields - agent_large_fields.
  class FixtureJoinNoJoinFields < Parse::Object
    parse_class "FixtureJoinNoJoinFields"
    property :name, :string
    property :description, :string
    property :icon_image, :string
    property :body_blob, :string
    agent_fields :name, :description, :icon_image, :body_blob
    agent_large_fields :icon_image, :body_blob
  end

  # Joined class with only agent_large_fields — falls back to
  # field_map.keys - agent_large_fields ("strip mode").
  class FixtureJoinOnlyLarge < Parse::Object
    parse_class "FixtureJoinOnlyLarge"
    property :title, :string
    property :status, :string
    property :icon_image, :string
    agent_large_fields :icon_image
  end

  # Joined class with no annotations at all — no auto-projection.
  class FixtureJoinNoAnnotations < Parse::Object
    parse_class "FixtureJoinNoAnnotations"
    property :foo, :string
    property :bar, :string
  end

  # Parent classes pointing at the joined classes via belongs_to.
  class FixtureMembership < Parse::Object
    parse_class "FixtureMembership"
    property :title, :string
    property :active, :boolean
    belongs_to :user, as: :fixture_join_user, field: :user
  end

  class FixtureMembershipNoJoinFields < Parse::Object
    parse_class "FixtureMembershipNoJoinFields"
    property :label, :string
    belongs_to :widget, as: :fixture_join_no_join_fields, field: :widget
  end

  class FixtureMembershipOnlyLarge < Parse::Object
    parse_class "FixtureMembershipOnlyLarge"
    property :label, :string
    belongs_to :doc, as: :fixture_join_only_large, field: :doc
  end

  class FixtureMembershipNoAnnotations < Parse::Object
    parse_class "FixtureMembershipNoAnnotations"
    property :label, :string
    belongs_to :thing, as: :fixture_join_no_annotations, field: :thing
  end

  # Multi-word pointer field whose Ruby attribute name (`cover_image`)
  # differs from its Parse wire name (`coverImage`). Exists so the
  # snake/camel dual-form resolution path has something to bite on —
  # all other fixtures use single-word pointer fields where snake and
  # camel forms collapse to the same string.
  class FixtureMembershipMultiWord < Parse::Object
    parse_class "FixtureMembershipMultiWord"
    property :title, :string
    belongs_to :cover_image, as: :fixture_join_user
    # `field:` defaults to key.to_s.camelize(:lower) -> :coverImage,
    # so `references` is keyed by `:coverImage`.
  end

  # ============================================================
  # DSL: agent_join_fields
  # ============================================================

  def test_agent_join_fields_stores_list_as_symbols
    assert_equal %i[first_name last_name email category],
      FixtureJoinUser.agent_join_field_list
  end

  def test_agent_join_fields_returns_empty_when_undeclared
    assert_equal [], FixtureJoinNoAnnotations.agent_join_field_list
  end

  # Fixture proving the subset invariant trips when agent_join_fields names
  # a field not in agent_fields. Class body must raise at load time.
  def test_agent_join_fields_subset_invariant_violation_raises
    err = assert_raises(ArgumentError) do
      eval <<~RUBY, binding, __FILE__, __LINE__ + 1
        class FixtureSubsetViolation < Parse::Object
          parse_class "FixtureSubsetViolation"
          agent_fields :a, :b, :c
          agent_join_fields :a, :b, :d
        end
      RUBY
    end
    assert_match(/agent_join_fields must be a subset of agent_fields/, err.message)
    assert_match(/:d\b/, err.message)
  end

  def test_agent_join_fields_subset_invariant_holds_across_declaration_order
    # Declare agent_join_fields BEFORE agent_fields — the late-declaring
    # agent_fields must still trip the invariant if it omits an entry.
    err = assert_raises(ArgumentError) do
      eval <<~RUBY, binding, __FILE__, __LINE__ + 1
        class FixtureReverseOrderViolation < Parse::Object
          parse_class "FixtureReverseOrderViolation"
          agent_join_fields :a, :b, :z
          agent_fields :a, :b
        end
      RUBY
    end
    assert_match(/agent_join_fields must be a subset of agent_fields/, err.message)
  end

  # Named fixture for the "join_fields without allowlist" case. Lives at the
  # class body level so it gets a real Ruby name and ActiveModel can compute
  # `model_name`.
  class FixtureJoinOnly < Parse::Object
    parse_class "FixtureJoinOnly"
    property :name, :string
    agent_join_fields :name
  end

  def test_agent_join_fields_without_agent_fields_is_allowed
    # No invariant to enforce — direct-query allowlist is absent so the
    # join list stands on its own.
    assert_equal [:name], FixtureJoinOnly.agent_join_field_list
    assert_equal [], FixtureJoinOnly.agent_field_allowlist
  end

  # ============================================================
  # MetadataRegistry.join_projection_fields
  # ============================================================

  def test_join_projection_uses_agent_join_fields_when_declared
    result = Parse::Agent::MetadataRegistry.join_projection_fields("FixtureJoinUser")
    refute_nil result
    assert_equal :join_fields, result[:source]
    assert_includes result[:project], "firstName"
    assert_includes result[:project], "lastName"
    assert_includes result[:project], "email"
    assert_includes result[:project], "category"
    refute_includes result[:project], "iconImage", "agent_large_fields excluded from join projection"
    refute_includes result[:project], "sourceImage"
    %w[objectId createdAt updatedAt].each do |sys|
      assert_includes result[:project], sys, "system field #{sys} always kept"
    end
    # Dropped is the large fields the join projection actively omits.
    assert_includes result[:dropped], "iconImage"
    assert_includes result[:dropped], "sourceImage"
  end

  def test_join_projection_falls_back_to_agent_fields_minus_large
    result = Parse::Agent::MetadataRegistry.join_projection_fields("FixtureJoinNoJoinFields")
    refute_nil result
    assert_equal :allowlist_minus_large, result[:source]
    assert_includes result[:project], "name"
    assert_includes result[:project], "description"
    refute_includes result[:project], "iconImage"
    refute_includes result[:project], "bodyBlob"
    assert_includes result[:dropped], "iconImage"
    assert_includes result[:dropped], "bodyBlob"
  end

  def test_join_projection_strip_mode_when_only_large_declared
    result = Parse::Agent::MetadataRegistry.join_projection_fields("FixtureJoinOnlyLarge")
    refute_nil result
    assert_equal :field_map_minus_large, result[:source]
    assert_includes result[:project], "title"
    assert_includes result[:project], "status"
    refute_includes result[:project], "iconImage"
    assert_includes result[:dropped], "iconImage"
  end

  def test_join_projection_nil_when_no_annotations
    assert_nil Parse::Agent::MetadataRegistry.join_projection_fields("FixtureJoinNoAnnotations")
  end

  def test_join_projection_nil_for_unknown_class
    assert_nil Parse::Agent::MetadataRegistry.join_projection_fields("NoSuchClassAnywhere")
  end

  # ============================================================
  # Tools.apply_include_projection — trigger conditions
  # ============================================================

  def test_auto_projection_fires_when_bare_pointer_in_keys_and_include
    result = Parse::Agent::Tools.apply_include_projection(
      "FixtureMembership",
      ["user", "title", "active", "createdAt"],
      ["user"]
    )
    rewritten = result[:effective_keys]
    refute_nil rewritten
    # Original bare-pointer reference stays so Parse Server returns the pointer column.
    assert_includes rewritten, "user"
    # Dotted-path projections for each agent_join_fields entry are appended.
    assert_includes rewritten, "user.firstName"
    assert_includes rewritten, "user.lastName"
    assert_includes rewritten, "user.email"
    assert_includes rewritten, "user.category"
    # Large fields are NOT appended (the join projection omits them).
    refute_includes rewritten, "user.iconImage"
    refute_includes rewritten, "user.sourceImage"
    # Truncation map records what was dropped.
    assert_equal :join_fields, result[:truncated]["user"][:source]
    assert_includes result[:truncated]["user"][:dropped], "iconImage"
  end

  def test_auto_projection_suppressed_when_caller_uses_dotted_path
    # `keys: ["user.iconImage"]` is the explicit-intent signal: caller
    # named exactly what they want, leave it alone.
    result = Parse::Agent::Tools.apply_include_projection(
      "FixtureMembership",
      ["user.iconImage", "title"],
      ["user"]
    )
    assert_equal ["user.iconImage", "title"], result[:effective_keys]
    assert_empty result[:truncated]
  end

  def test_auto_projection_suppressed_when_no_keys_passed
    # No `keys:` at all = "I want everything"; no auto-projection.
    result = Parse::Agent::Tools.apply_include_projection(
      "FixtureMembership", nil, ["user"]
    )
    assert_nil result[:effective_keys]
    assert_empty result[:truncated]
  end

  def test_auto_projection_suppressed_when_pointer_not_in_keys
    # `keys: ["title"]` without `"user"` — caller didn't ask for the pointer at
    # the parent level either, so the auto-expansion has nothing to attach to.
    result = Parse::Agent::Tools.apply_include_projection(
      "FixtureMembership",
      ["title", "active"],
      ["user"]
    )
    assert_equal ["title", "active"], result[:effective_keys]
    assert_empty result[:truncated]
  end

  def test_auto_projection_one_hop_only_skips_multi_hop_include
    # Multi-hop include (`user.team`) takes the deeper hop verbatim —
    # auto-expansion is one-hop only by design to bound the rewrite.
    result = Parse::Agent::Tools.apply_include_projection(
      "FixtureMembership",
      ["user", "title"],
      ["user.team"]
    )
    assert_equal ["user", "title"], result[:effective_keys]
    assert_empty result[:truncated]
  end

  def test_auto_projection_falls_back_to_allowlist_minus_large
    result = Parse::Agent::Tools.apply_include_projection(
      "FixtureMembershipNoJoinFields",
      ["widget", "label"],
      ["widget"]
    )
    rewritten = result[:effective_keys]
    assert_includes rewritten, "widget.name"
    assert_includes rewritten, "widget.description"
    refute_includes rewritten, "widget.iconImage"
    refute_includes rewritten, "widget.bodyBlob"
    assert_equal :allowlist_minus_large, result[:truncated]["widget"][:source]
  end

  def test_auto_projection_strip_mode_when_only_large_declared
    result = Parse::Agent::Tools.apply_include_projection(
      "FixtureMembershipOnlyLarge",
      ["doc", "label"],
      ["doc"]
    )
    rewritten = result[:effective_keys]
    assert_includes rewritten, "doc.title"
    assert_includes rewritten, "doc.status"
    refute_includes rewritten, "doc.iconImage"
    assert_equal :field_map_minus_large, result[:truncated]["doc"][:source]
  end

  def test_auto_projection_no_op_when_joined_class_has_no_annotations
    result = Parse::Agent::Tools.apply_include_projection(
      "FixtureMembershipNoAnnotations",
      ["thing", "label"],
      ["thing"]
    )
    assert_equal ["thing", "label"], result[:effective_keys]
    assert_empty result[:truncated]
  end

  def test_auto_projection_accepts_snake_case_pointer_via_belongs_to_reflection
    # belongs_to gives the pointer field its lowerCamel wire name; references[]
    # is keyed by that. The resolver accepts both Ruby snake_case and the wire
    # name, so an LLM that passes either form gets the same expansion. Uses
    # FixtureMembershipMultiWord because its pointer field has distinct
    # snake (`cover_image`) and camel (`coverImage`) forms — single-word
    # fixtures like `user` collapse the two paths into one string.
    snake = Parse::Agent::Tools.apply_include_projection(
      "FixtureMembershipMultiWord", ["cover_image", "title"], ["cover_image"]
    )
    camel = Parse::Agent::Tools.apply_include_projection(
      "FixtureMembershipMultiWord", ["coverImage", "title"], ["coverImage"]
    )
    # Both forms must trigger the auto-expansion; truncation map is keyed
    # by whatever prefix the caller passed.
    refute_empty snake[:truncated], "snake_case form should resolve to a pointer target"
    refute_empty camel[:truncated], "camelCase form should resolve to a pointer target"
    assert_equal snake[:truncated]["cover_image"][:source],
                 camel[:truncated]["coverImage"][:source]
    assert_equal snake[:truncated]["cover_image"][:dropped],
                 camel[:truncated]["coverImage"][:dropped]
    # The appended dotted paths use the caller's prefix verbatim, so the
    # full effective_keys arrays differ. The PROJECTED FIELD SET (the
    # suffix after the dot) must be identical between the two calls.
    snake_fields = snake[:effective_keys]
      .select { |k| k.start_with?("cover_image.") }
      .map { |k| k.split(".", 2)[1] }
      .sort
    camel_fields = camel[:effective_keys]
      .select { |k| k.start_with?("coverImage.") }
      .map { |k| k.split(".", 2)[1] }
      .sort
    refute_empty snake_fields, "snake_case form should produce dotted-path projections"
    assert_equal snake_fields, camel_fields
  end
end
