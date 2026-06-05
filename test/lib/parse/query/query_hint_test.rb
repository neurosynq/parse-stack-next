# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

class TestQueryHint < Minitest::Test
  def setup
    @query = Parse::Query.new("Post")
  end

  def test_hint_method_exists
    assert_respond_to @query, :hint
  end

  def test_hint_returns_nil_when_unset
    assert_nil @query.hint
  end

  def test_hint_setter_returns_self_for_chaining
    result = @query.hint("status_1_created_at_-1")
    assert_same @query, result
  end

  def test_hint_stored_as_string
    @query.hint("status_1_created_at_-1")
    assert_equal "status_1_created_at_-1", @query.hint
  end

  def test_hint_reader_returns_current_value_after_set
    @query.hint("my_index")
    assert_equal "my_index", @query.hint
  end

  def test_compile_includes_hint_when_set
    @query.hint("status_1_created_at_-1")
    compiled = @query.compile
    assert_equal "status_1_created_at_-1", compiled[:hint]
  end

  def test_compile_omits_hint_when_unset
    compiled = @query.compile
    refute compiled.key?(:hint)
  end

  def test_hint_present_in_both_encoded_and_unencoded_compile
    @query.hint("my_index")
    assert_equal "my_index", @query.compile(encode: true)[:hint]
    assert_equal "my_index", @query.compile(encode: false)[:hint]
  end

  def test_hint_can_be_cleared_with_nil
    @query.hint("my_index")
    @query.hint(nil)
    compiled = @query.compile
    refute compiled.key?(:hint)
  end

  def test_hint_chainable_with_limit
    result = @query.hint("my_index").limit(5)
    assert_same @query, result
    assert_equal "my_index", @query.hint
    assert_equal 5, @query.compile[:limit]
  end

  def test_hint_survives_clone
    @query.hint("my_index")
    cloned = @query.clone
    assert_equal "my_index", cloned.hint
    compiled = cloned.compile
    assert_equal "my_index", compiled[:hint]
  end
end
