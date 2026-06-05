require_relative "../../../test_helper"

class TestQueryReadPreference < Minitest::Test
  def test_read_preference_constant_defined
    assert_equal "X-Parse-Read-Preference", Parse::Protocol::READ_PREFERENCE
  end

  def test_valid_read_preferences_constant_defined
    expected = %w[PRIMARY PRIMARY_PREFERRED SECONDARY SECONDARY_PREFERRED NEAREST]
    assert_equal expected, Parse::Protocol::READ_PREFERENCES
  end

  def test_read_preference_attribute_exists
    query = Parse::Query.new("TestClass")
    assert_respond_to query, :read_preference
    assert_respond_to query, :read_preference=
  end

  def test_read_pref_method_exists
    query = Parse::Query.new("TestClass")
    assert_respond_to query, :read_pref
  end

  def test_read_pref_returns_self_for_chaining
    query = Parse::Query.new("TestClass")
    result = query.read_pref(:secondary)
    assert_same query, result
  end

  def test_read_pref_sets_read_preference
    query = Parse::Query.new("TestClass")
    query.read_pref(:secondary)
    assert_equal :secondary, query.read_preference
  end

  def test_read_preference_in_conditions
    query = Parse::Query.new("TestClass", read_preference: :secondary)
    assert_equal :secondary, query.read_preference
  end

  def test_headers_include_read_preference_when_set
    query = Parse::Query.new("TestClass")
    query.read_preference = :secondary
    headers = query.send(:_headers)
    assert_equal "SECONDARY", headers[Parse::Protocol::READ_PREFERENCE]
  end

  def test_headers_normalizes_primary
    query = Parse::Query.new("TestClass")
    query.read_preference = :primary
    headers = query.send(:_headers)
    assert_equal "PRIMARY", headers[Parse::Protocol::READ_PREFERENCE]
  end

  def test_headers_normalizes_primary_preferred
    query = Parse::Query.new("TestClass")
    query.read_preference = :primary_preferred
    headers = query.send(:_headers)
    assert_equal "PRIMARY_PREFERRED", headers[Parse::Protocol::READ_PREFERENCE]
  end

  def test_headers_normalizes_secondary_preferred
    query = Parse::Query.new("TestClass")
    query.read_preference = "secondary_preferred"
    headers = query.send(:_headers)
    assert_equal "SECONDARY_PREFERRED", headers[Parse::Protocol::READ_PREFERENCE]
  end

  def test_headers_normalizes_nearest
    query = Parse::Query.new("TestClass")
    query.read_preference = "NEAREST"
    headers = query.send(:_headers)
    assert_equal "NEAREST", headers[Parse::Protocol::READ_PREFERENCE]
  end

  def test_headers_empty_when_no_read_preference
    query = Parse::Query.new("TestClass")
    headers = query.send(:_headers)
    assert_empty headers
  end

  # --- REST BODY (the part Parse Server actually reads) -------------------
  # Parse Server's middleware maps no `X-Parse-Read-Preference` header into
  # request options; `RestQuery` reads `readPreference` only from restOptions
  # (the compiled query body). Asserting the header alone is the blind spot
  # that let the no-op ship — these pin the body.

  def test_compiled_body_includes_read_preference
    query = Parse::Query.new("TestClass")
    query.read_pref(:secondary)
    compiled = query.compile
    assert_equal "SECONDARY", compiled[:readPreference]
  end

  def test_compiled_body_normalizes_secondary_preferred
    query = Parse::Query.new("TestClass")
    query.read_pref("secondary_preferred")
    compiled = query.compile
    assert_equal "SECONDARY_PREFERRED", compiled[:readPreference]
  end

  def test_compiled_body_omits_read_preference_when_unset
    query = Parse::Query.new("TestClass")
    compiled = query.compile
    refute compiled.key?(:readPreference)
  end

  def test_compiled_body_omits_invalid_read_preference
    query = Parse::Query.new("TestClass")
    query.read_preference = :invalid_value
    assert_output(nil, /Invalid read preference/) do
      compiled = query.compile
      refute compiled.key?(:readPreference)
    end
  end

  def test_unencoded_compile_omits_read_preference
    # `readPreference` is a REST-wire concern; the structural (encode: false)
    # form used by mongo-direct / snapshot tooling should not carry it.
    query = Parse::Query.new("TestClass")
    query.read_pref(:secondary)
    compiled = query.compile(encode: false)
    refute compiled.key?(:readPreference)
  end

  def test_invalid_read_preference_not_added_to_headers
    query = Parse::Query.new("TestClass")
    query.read_preference = :invalid_value
    # Capture warning
    assert_output(nil, /Invalid read preference/) do
      headers = query.send(:_headers)
      refute headers.key?(Parse::Protocol::READ_PREFERENCE)
    end
  end

  # Test chaining with other query methods
  def test_chaining_with_limit
    query = Parse::Query.new("TestClass")
    result = query.read_pref(:secondary).limit(10)
    assert_same query, result
    assert_equal :secondary, query.read_preference
  end

  def test_chaining_with_where
    query = Parse::Query.new("TestClass")
    result = query.read_pref(:nearest).where(name: "test")
    assert_same query, result
    assert_equal :nearest, query.read_preference
  end
end
