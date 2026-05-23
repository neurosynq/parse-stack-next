require_relative "../../test_helper"

class ParseErrorTest < Minitest::Test
  def test_single_argument_legacy_form
    e = Parse::Error.new("plain message")
    assert_equal "plain message", e.message
    assert_nil e.code
  end

  def test_two_argument_code_and_message
    e = Parse::Error.new(101, "Object not found")
    assert_equal 101, e.code
    assert_equal "[101] Object not found", e.message
  end

  def test_raise_with_implicit_construction
    err = assert_raises(Parse::Error) { raise Parse::Error, "boom" }
    assert_equal "boom", err.message
    assert_nil err.code
  end

  def test_raise_with_explicit_two_arg_construction
    err = assert_raises(Parse::Error) do
      raise Parse::Error.new(141, "cloud function failed")
    end
    assert_equal 141, err.code
    assert_equal "[141] cloud function failed", err.message
  end

  def test_subclass_inherits_two_arg_initializer
    err = Parse::Error::ConnectionError.new(503, "service down")
    assert_equal 503, err.code
    assert_equal "[503] service down", err.message
    assert_kind_of Parse::Error, err
  end

  def test_no_args_construction
    e = Parse::Error.new
    assert_nil e.code
  end

  def test_livequery_error_caught_by_parse_error_rescue
    require "parse/live_query"
    err = assert_raises(Parse::Error) do
      raise Parse::LiveQuery::ConnectionError, "ws disconnected"
    end
    assert_kind_of Parse::LiveQuery::ConnectionError, err
    assert_kind_of Parse::Error, err
    assert_equal "ws disconnected", err.message
  end

  def test_cloud_code_error_initialize_still_works
    # CloudCodeError defines its own initialize; ensure it is not broken by
    # the new Parse::Error base initialize.
    response = Struct.new(:code, :error, :http_status).new(141, "boom", 400)
    err = Parse::Error::CloudCodeError.new("myFunc", response)
    assert_equal "myFunc", err.function_name
    assert_equal 141, err.code
    assert_equal 400, err.http_status
    assert_match(/\[141\]/, err.message)
  end
end
