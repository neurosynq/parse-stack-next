# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# SEC-06: privilege/auth control options (:use_master_key, :session) must NOT
# be settable from an untrusted, STRING-keyed conditions hash — the common
# "forward the request params hash straight into a query" pattern. A
# string-keyed `use_master_key` was an ACL/CLP-bypass mass-assignment. Symbol
# keys (code-authored) still work.
class QueryControlOptionMassAssignmentTest < Minitest::Test
  def setup
    unless Parse::Client.client?
      Parse.setup(server_url: "http://localhost:1337/parse",
                  application_id: "a", api_key: "k")
    end
  end

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  def test_string_use_master_key_does_not_elevate
    q = nil
    capture_stderr do
      q = Parse::Query.new("Record", { "use_master_key" => true, "ownerId" => "victim" })
    end
    refute_equal true, q.instance_variable_get(:@use_master_key),
                 "a string-keyed use_master_key from a params hash must not set the master flag"
  end

  def test_string_use_master_key_is_treated_as_a_constraint
    q = nil
    capture_stderr { q = Parse::Query.new("Record", { "use_master_key" => true }) }
    refute_empty q.send(:compile_where),
                 "the string key falls through to a (harmless) field constraint, not a control option"
  end

  def test_symbol_use_master_key_is_still_honored
    q = Parse::Query.new("Record", { use_master_key: true })
    assert_equal true, q.instance_variable_get(:@use_master_key),
                 "symbol-keyed use_master_key (code-authored) must still set the flag"
  end

  def test_string_session_does_not_set_token
    q = nil
    capture_stderr { q = Parse::Query.new("Record", { "session" => "r:attacker" }) }
    assert_nil q.instance_variable_get(:@session_token),
               "a string-keyed session must not swap the query's auth principal"
  end

  def test_symbol_session_is_still_honored
    q = Parse::Query.new("Record", { session: "r:legit" })
    assert_equal "r:legit", q.instance_variable_get(:@session_token)
  end

  def test_string_control_key_emits_a_warning
    out = capture_stderr { Parse::Query.new("Record", { "use_master_key" => true }) }
    assert_match(/string-keyed control option/i, out,
                 "the ignored string control key should warn so a legit author notices")
  end

  # `where` is the same code path (aliased to #conditions) — the guard must
  # apply there too, not just on the constructor.
  def test_where_string_use_master_key_does_not_elevate
    q = Parse::Query.new("Record")
    capture_stderr { q.where("use_master_key" => true) }
    refute_equal true, q.instance_variable_get(:@use_master_key)
  end
end
