# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# A property declared with an explicit remote name (`field:`) must be queried
# by that exact name. Before 5.8 queries camel-cased every key, so
# `where(account_id:)` compiled to `accountId` and `"authId_sub"` to
# `authIdSub`, silently matching nothing on systems whose columns use
# underscores or mixed casing.
class QueryFieldAliasTest < Minitest::Test
  class ExtAccount < Parse::Object
    parse_class "FieldAliasExtAccount"
    property :account_id, :string, field: :account_id
    property :auth_id_sub, :string, field: :authId_sub
    property :plain_name, :string
    belongs_to :owner_ref, as: :field_alias_ext_owner, field: :owner_ref
  end

  class ExtOwner < Parse::Object
    parse_class "FieldAliasExtOwner"
    property :legacy_code, :string, field: :legacy_code
  end

  def test_where_uses_declared_names_for_ruby_and_remote_keys
    q = ExtAccount.query(account_id: "A1", auth_id_sub: "S1", plain_name: "p")
    assert_equal({ "account_id" => "A1", "authId_sub" => "S1", "plainName" => "p" }, q.compile_where)
    q = ExtAccount.query("account_id" => "A1", "authId_sub" => "S1")
    assert_equal({ "account_id" => "A1", "authId_sub" => "S1" }, q.compile_where)
  end

  def test_operators_order_keys_and_includes_use_declared_names
    q = ExtAccount.query(:account_id.in => %w[A1 A2], :auth_id_sub.exists => true)
                  .order(:auth_id_sub.desc).keys(:account_id, :plain_name).includes(:owner_ref)
    compiled = q.compile(encode: false)
    assert_equal({ "$in" => %w[A1 A2] }, q.compile_where["account_id"].transform_keys(&:to_s))
    assert_equal({ :$exists => true }.transform_keys(&:to_s), q.compile_where["authId_sub"].transform_keys(&:to_s))
    assert_equal "-authId_sub", compiled[:order]
    assert_equal "account_id,plainName,owner_ref", compiled[:keys]
    assert_equal "owner_ref", compiled[:include]
  end

  def test_undeclared_names_keep_default_formatting
    assert_equal({ "plainName" => "p" }, ExtAccount.query(plain_name: "p").compile_where)
  end

  def test_unrelated_class_is_unaffected
    q = Parse::Query.new("SomeOtherClass", account_id: "A1")
    assert_equal({ "accountId" => "A1" }, q.compile_where)
  end

  def test_subquery_uses_its_own_class_aliases
    inner = ExtOwner.query(legacy_code: "L1")
    q = ExtAccount.query(:owner_ref.in_query => inner, account_id: "A1")
    where = q.compile_where
    assert_equal "A1", where["account_id"]
    assert_equal({ "legacy_code" => "L1" }, where.dig("owner_ref", :$inQuery, :where) || where.dig("owner_ref", "$inQuery", "where"))
  end

  def test_scope_does_not_leak_between_threads
    seen = {}
    q = Queue.new
    t1 = Thread.new do
      Parse::Query.with_field_aliases("FieldAliasExtAccount") do
        q.pop
        seen[:aliased] = Parse::Query.format_field("account_id")
      end
    end
    t2 = Thread.new do
      q << :go
      seen[:plain] = Parse::Query.format_field("account_id")
    end
    [t1, t2].each(&:join)
    assert_equal "account_id", seen[:aliased]
    assert_equal "accountId", seen[:plain]
  end
end
