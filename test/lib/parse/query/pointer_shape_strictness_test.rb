# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Tests for the silent-zero failure mode in `$in`/`$nin` rewriting on
# pointer columns. When a query passes bare objectId strings inside an
# `$in` array against a pointer column whose target class cannot be
# resolved (no local belongs_to AND no peer Pointer in the array), the
# resulting query against `_p_<field>` matches "ClassName$objectId"
# storage strings against bare objectIds — guaranteed zero rows. The
# SDK used to silently pass the string through; now it raises in
# strict mode and warns in compatibility mode.
class TestPointerShapeStrictness < Minitest::Test
  def setup
    Parse::Query.instance_variable_set(:@pointer_shape_warned, {})
    @prior_strict = Parse.strict_pointer_shapes
  end

  def teardown
    Parse.strict_pointer_shapes = @prior_strict
  end

  def test_strict_mode_raises_when_target_class_cannot_be_inferred
    # Strict path fires when `fields[:workspace] == :pointer` (so
    # `field_is_pointer?` is true) but `references[:workspace]` is nil
    # (target class unresolvable) AND no peer Pointer is in the $in
    # array to infer from. Stub a class with that exact shape.
    Parse.strict_pointer_shapes = true

    # Stub a class on Parse::Model that reports `fields[:workspace] == :pointer`
    # but has no references entry.
    klass = Class.new do
      def self.fields
        { workspace: :pointer }
      end

      def self.references
        {}
      end

      def self.respond_to?(method_name, include_private = false)
        return true if [:fields, :references].include?(method_name)
        super
      end
    end
    Parse::Model.const_set(:PSSStubClass, klass)

    begin
      q = Parse::Query.new("PSSStubClass")
      constraints = { "workspace" => { "$in" => ["bare1", "bare2"] } }

      err = assert_raises(Parse::Query::PointerShapeError) do
        q.send(:convert_constraints_for_aggregation, constraints)
      end
      assert_match(/pointer column/i, err.message)
      assert_match(/bare string/i, err.message)
      assert_match(/PSSStubClass\.workspace/, err.message)
    ensure
      Parse::Model.send(:remove_const, :PSSStubClass)
    end
  end

  def test_compatibility_mode_warns_and_passes_through
    Parse.strict_pointer_shapes = false

    klass = Class.new do
      def self.fields
        { manager: :pointer }
      end

      def self.references
        {}
      end

      def self.respond_to?(method_name, include_private = false)
        return true if [:fields, :references].include?(method_name)
        super
      end
    end
    Parse::Model.const_set(:PSSStubClassCompat, klass)

    captured = StringIO.new
    prior_logger = Parse.logger
    Parse.logger = Logger.new(captured)

    begin
      q = Parse::Query.new("PSSStubClassCompat")
      constraints = { "manager" => { "$in" => ["bare1", "bare2"] } }
      result = q.send(:convert_constraints_for_aggregation, constraints)

      # Strings pass through unchanged in compatibility mode — the
      # historical behavior.
      assert_equal({ "_p_manager" => { "$in" => ["bare1", "bare2"] } }, result)
      assert_match(/Pointer-shape mismatch/, captured.string)
      assert_match(/PSSStubClassCompat\.manager/, captured.string)
    ensure
      Parse.logger = prior_logger
      Parse::Model.send(:remove_const, :PSSStubClassCompat)
    end
  end

  def test_compatibility_mode_warns_only_once_per_table_field
    Parse.strict_pointer_shapes = false

    klass = Class.new do
      def self.fields
        { author: :pointer }
      end

      def self.references
        {}
      end

      def self.respond_to?(method_name, include_private = false)
        return true if [:fields, :references].include?(method_name)
        super
      end
    end
    Parse::Model.const_set(:PSSStubClassOnce, klass)

    captured = StringIO.new
    prior_logger = Parse.logger
    Parse.logger = Logger.new(captured)

    begin
      q = Parse::Query.new("PSSStubClassOnce")
      3.times do
        q.send(:convert_constraints_for_aggregation,
               { "author" => { "$in" => ["x"] } })
      end
      occurrences = captured.string.scan(/Pointer-shape mismatch/).size
      assert_equal 1, occurrences, "expected exactly one warning across repeated calls"
    ensure
      Parse.logger = prior_logger
      Parse::Model.send(:remove_const, :PSSStubClassOnce)
    end
  end

  def test_or_branch_recurses_into_pointer_rewrite
    # The most common LLM-generated silent-zero pattern: wrapping a
    # pointer-field $in inside an $or branch. Without recursion, $or's
    # value array was passed through verbatim, so `workspace` never got
    # rewritten to `_p_workspace` and the bare strings never got the
    # "Workspace$" prefix.
    q = Parse::Query.new("Subscription")
    constraints = {
      "$or" => [
        { "workspace" => { "$in" => [Parse::Pointer.new("Workspace", "t1"), "t2"] } },
        { "workspace" => Parse::Pointer.new("Workspace", "t3") },
      ],
    }

    result = q.send(:convert_constraints_for_aggregation, constraints)

    assert_equal({
      "$or" => [
        { "_p_workspace" => { "$in" => ["Workspace$t1", "Workspace$t2"] } },
        { "_p_workspace" => "Workspace$t3" },
      ],
    }, result)
  end

  def test_and_branch_recurses_into_pointer_rewrite
    q = Parse::Query.new("Subscription")
    constraints = {
      "$and" => [
        { "workspace" => { "$in" => [Parse::Pointer.new("Workspace", "x")] } },
      ],
    }

    result = q.send(:convert_constraints_for_aggregation, constraints)
    assert_equal({ "$and" => [{ "_p_workspace" => { "$in" => ["Workspace$x"] } }] }, result)
  end

  def test_nor_branch_recurses_into_pointer_rewrite
    q = Parse::Query.new("Subscription")
    constraints = {
      "$nor" => [
        { "workspace" => { "$in" => [Parse::Pointer.new("Workspace", "z")] } },
      ],
    }
    result = q.send(:convert_constraints_for_aggregation, constraints)
    assert_equal({ "$nor" => [{ "_p_workspace" => { "$in" => ["Workspace$z"] } }] }, result)
  end

  def test_nested_or_and_recurses_into_pointer_rewrite
    # $or containing $and containing a pointer constraint — confirms
    # recursion holds at depth ≥ 2, not just one level.
    q = Parse::Query.new("Subscription")
    constraints = {
      "$or" => [
        {
          "$and" => [
            { "workspace" => { "$in" => [Parse::Pointer.new("Workspace", "a")] } },
            { "status" => "active" },
          ],
        },
        { "workspace" => Parse::Pointer.new("Workspace", "b") },
      ],
    }
    result = q.send(:convert_constraints_for_aggregation, constraints)
    assert_equal({
      "$or" => [
        {
          "$and" => [
            { "_p_workspace" => { "$in" => ["Workspace$a"] } },
            { "status" => "active" },
          ],
        },
        { "_p_workspace" => "Workspace$b" },
      ],
    }, result)
  end

  def test_inference_from_peer_pointer_still_succeeds_silently
    # Sanity: the strict path must NOT fire when peer inference can
    # resolve the target class. A Pointer peer in the array tells us
    # the className; bare strings then get rewritten correctly.
    Parse.strict_pointer_shapes = true

    q = Parse::Query.new("Subscription")
    constraints = {
      "workspace" => { "$in" => [Parse::Pointer.new("Workspace", "team1"), "bare2"] },
    }

    result = q.send(:convert_constraints_for_aggregation, constraints)
    assert_equal({ "_p_workspace" => { "$in" => ["Workspace$team1", "Workspace$bare2"] } }, result)
  end
end
