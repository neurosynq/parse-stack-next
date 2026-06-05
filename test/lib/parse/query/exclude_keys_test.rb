# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"

# Fields passed to exclude_keys go through Query.format_field, which converts
# snake_case to camelCase (e.g. :secret_token => "secretToken"). Tests use
# camelCase field names for clarity, but a snake_case round-trip is verified
# explicitly.
class TestQueryExcludeKeys < Minitest::Test
  def setup
    @query = Parse::Query.new("Post")
  end

  def test_exclude_keys_method_exists
    assert_respond_to @query, :exclude_keys
  end

  def test_exclude_keys_returns_self_for_chaining
    result = @query.exclude_keys(:token)
    assert_same @query, result
  end

  def test_exclude_keys_single_field
    @query.exclude_keys(:token)
    compiled = @query.compile
    assert_equal "token", compiled[:excludeKeys]
  end

  def test_exclude_keys_snake_case_converted_to_camel_case
    @query.exclude_keys(:secret_token)
    compiled = @query.compile
    # format_field converts snake_case -> camelCase
    assert_equal "secretToken", compiled[:excludeKeys]
  end

  def test_exclude_keys_multiple_fields_variadic
    @query.exclude_keys(:token, :notes)
    compiled = @query.compile
    fields = compiled[:excludeKeys].split(",")
    assert_includes fields, "token"
    assert_includes fields, "notes"
    assert_equal 2, fields.size
  end

  def test_exclude_keys_multiple_calls_accumulate
    @query.exclude_keys(:token)
    @query.exclude_keys(:notes)
    compiled = @query.compile
    fields = compiled[:excludeKeys].split(",")
    assert_includes fields, "token"
    assert_includes fields, "notes"
  end

  def test_exclude_keys_deduplicates
    @query.exclude_keys(:token, :token)
    compiled = @query.compile
    fields = compiled[:excludeKeys].split(",")
    assert_equal 1, fields.count("token")
  end

  def test_exclude_keys_omitted_when_unset
    compiled = @query.compile
    refute compiled.key?(:excludeKeys)
  end

  def test_exclude_keys_omitted_under_encode_false
    @query.exclude_keys(:token)
    compiled = @query.compile(encode: false)
    refute compiled.key?(:excludeKeys),
      "excludeKeys must not appear in the structural (encode: false) form"
  end

  def test_exclude_keys_present_under_encode_true_by_default
    @query.exclude_keys(:token)
    compiled = @query.compile(encode: true)
    assert compiled.key?(:excludeKeys)
  end

  def test_exclude_keys_chainable_with_other_methods
    result = @query.exclude_keys(:token).limit(10).where(status: "active")
    assert_same @query, result
    compiled = @query.compile
    assert_equal "token", compiled[:excludeKeys]
    assert_equal 10, compiled[:limit]
  end

  def test_exclude_keys_with_array_argument
    @query.exclude_keys([:token, :notes])
    compiled = @query.compile
    fields = compiled[:excludeKeys].split(",")
    assert_includes fields, "token"
    assert_includes fields, "notes"
  end

  def test_exclude_keys_survives_clone
    @query.exclude_keys(:token)
    cloned = @query.clone
    compiled = cloned.compile
    assert_equal "token", compiled[:excludeKeys]
  end
end
