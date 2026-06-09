# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../../test_helper"

class TestAclQueryConstraints < Minitest::Test
  extend Minitest::Spec::DSL

  # ReadableByConstraint is now a thin alias of ACLReadableByConstraint
  # (its full behavior is covered by acl_readable_by_test.rb). These tests
  # pin that the alias resolves to the unified, public-inclusive,
  # role-expanding implementation — NOT the removed standalone shape.
  describe "ReadableByConstraint (alias of ACLReadableByConstraint)" do
    it "registers :readable_by operator" do
      assert_includes Parse::Operation.operators.keys, :readable_by
    end

    it "creates constraint with Symbol#readable_by" do
      assert_respond_to :field, :readable_by
      op = :field.readable_by
      assert_instance_of Parse::Operation, op
      assert_equal :readable_by, op.operator
    end

    it "is a subclass of ACLReadableByConstraint" do
      assert Parse::Constraint::ReadableByConstraint < Parse::Constraint::ACLReadableByConstraint
    end

    # Empty intent ([] / "none" / :none / nil) -> explicit-empty _rperm match
    # (NOT missing, which Parse Server treats as public). Single $match, no $or.
    [[], "none", :none, nil].each do |empty_value|
      it "builds explicit-empty match for #{empty_value.inspect}" do
        constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, empty_value)
        result = constraint.build
        assert_equal(
          [{ "$match" => { "_rperm" => { "$exists" => true, "$eq" => [] } } }],
          result["__aggregation_pipeline"],
        )
      end
    end

    it "builds public-inclusive $or for a user ID string" do
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, "user123")
      match = constraint.build["__aggregation_pipeline"].first["$match"]
      assert_equal(
        { "$or" => [
          { "_rperm" => { "$in" => ["user123", "*"] } },
          { "_rperm" => { "$exists" => false } },
        ] },
        match,
      )
    end

    [:public, "public", "*"].each do |pub|
      it "maps #{pub.inspect} to the public wildcard" do
        constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, pub)
        match = constraint.build["__aggregation_pipeline"].first["$match"]
        assert_equal(
          { "$or" => [
            { "_rperm" => { "$in" => ["*"] } },
            { "_rperm" => { "$exists" => false } },
          ] },
          match,
        )
      end
    end

    it "handles an array of mixed permissions (public deduped)" do
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, ["user123", "role:Admin", "*"])
      in_array = constraint.build["__aggregation_pipeline"].first["$match"]["$or"].first["_rperm"]["$in"]
      assert_equal(["user123", "role:Admin", "*"], in_array)
    end

    it "extracts user ID from Parse::User (role expansion best-effort)" do
      user = Parse::User.new
      user.id = "abc123"
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, user)
      in_array = constraint.build["__aggregation_pipeline"].first["$match"]["$or"].first["_rperm"]["$in"]
      assert_includes in_array, "abc123"
      assert_includes in_array, "*"
    end

    it "extracts role name from Parse::Role (self always included)" do
      role = Parse::Role.new
      role.name = "Editor"
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, role)
      in_array = constraint.build["__aggregation_pipeline"].first["$match"]["$or"].first["_rperm"]["$in"]
      assert_includes in_array, "role:Editor"
      assert_includes in_array, "*"
    end

    it "strict mode (readable_by_exact) suppresses public and missing-field branches" do
      constraint = Parse::Constraint::ACLReadableByExactConstraint.new(:acl.readable_by_exact, "role:Admin")
      match = constraint.build["__aggregation_pipeline"].first["$match"]
      assert_equal({ "_rperm" => { "$in" => ["role:Admin"] } }, match)
    end
  end

  # WriteableByConstraint (British spelling) is now an alias of
  # ACLWritableByConstraint — the previous strict, non-expanding fork is gone.
  describe "WriteableByConstraint (alias of ACLWritableByConstraint)" do
    it "registers :writeable_by and :writable_by operators" do
      assert_includes Parse::Operation.operators.keys, :writeable_by
      assert_includes Parse::Operation.operators.keys, :writable_by
    end

    it ":writeable_by resolves to the same implementation as :writable_by" do
      assert Parse::Constraint::WriteableByConstraint < Parse::Constraint::ACLWritableByConstraint
    end

    it "builds explicit-empty match for []" do
      constraint = Parse::Constraint::WriteableByConstraint.new(:acl.writeable_by, [])
      assert_equal(
        [{ "$match" => { "_wperm" => { "$exists" => true, "$eq" => [] } } }],
        constraint.build["__aggregation_pipeline"],
      )
    end

    it "builds public-inclusive $or for a user ID (writeable == writable now)" do
      constraint = Parse::Constraint::WriteableByConstraint.new(:acl.writeable_by, "user456")
      match = constraint.build["__aggregation_pipeline"].first["$match"]
      assert_equal(
        { "$or" => [
          { "_wperm" => { "$in" => ["user456", "*"] } },
          { "_wperm" => { "$exists" => false } },
        ] },
        match,
      )
    end
  end

  # Test NotReadableByConstraint
  describe "NotReadableByConstraint" do
    it "registers :not_readable_by operator" do
      assert_includes Parse::Operation.operators.keys, :not_readable_by
    end

    it "builds $nin constraint including public, with $exists guard" do
      constraint = Parse::Constraint::NotReadableByConstraint.new(:acl.not_readable_by, "user123")
      match = constraint.build["__aggregation_pipeline"].first["$match"]
      # "not readable by user" must also exclude publicly-readable rows, so
      # "*" is added; the $exists:true guard excludes missing-_rperm (public)
      # rows that $nin would otherwise match.
      assert_equal({ "$exists" => true, "$nin" => ["user123", "*"] }, match["_rperm"])
    end

    it "for '*' (not_publicly_readable) excludes only public + missing" do
      constraint = Parse::Constraint::NotReadableByConstraint.new(:acl.not_readable_by, "*")
      match = constraint.build["__aggregation_pipeline"].first["$match"]
      assert_equal({ "$exists" => true, "$nin" => ["*"] }, match["_rperm"])
    end

    it "returns empty pipeline for empty array" do
      constraint = Parse::Constraint::NotReadableByConstraint.new(:acl.not_readable_by, [])
      result = constraint.build
      assert result.key?("__aggregation_pipeline")
      assert_empty result["__aggregation_pipeline"]
    end
  end

  # Test NotWriteableByConstraint
  describe "NotWriteableByConstraint" do
    it "registers :not_writeable_by and :not_writable_by operators" do
      assert_includes Parse::Operation.operators.keys, :not_writeable_by
      assert_includes Parse::Operation.operators.keys, :not_writable_by
    end

    it "builds $nin constraint including public, with $exists guard" do
      constraint = Parse::Constraint::NotWriteableByConstraint.new(:acl.not_writeable_by, "user123")
      match = constraint.build["__aggregation_pipeline"].first["$match"]
      assert_equal({ "$exists" => true, "$nin" => ["user123", "*"] }, match["_wperm"])
    end
  end

  # Test PrivateAclConstraint
  describe "PrivateAclConstraint" do
    it "registers :private_acl and :master_key_only operators" do
      assert_includes Parse::Operation.operators.keys, :private_acl
      assert_includes Parse::Operation.operators.keys, :master_key_only
    end

    it "private (true) matches explicit-empty _rperm AND _wperm, excluding missing" do
      constraint = Parse::Constraint::PrivateAclConstraint.new(:acl.private_acl, true)
      match = constraint.build["__aggregation_pipeline"].first["$match"]
      assert_equal(
        { "$and" => [
          { "_rperm" => { "$exists" => true, "$eq" => [] } },
          { "_wperm" => { "$exists" => true, "$eq" => [] } },
        ] },
        match,
      )
      # A missing _rperm is PUBLIC, not private — must NOT appear here.
      refute_includes match.to_json, '"$exists":false'
    end

    it "non-private (false) is the exact complement ($nor of the private match)" do
      constraint = Parse::Constraint::PrivateAclConstraint.new(:acl.private_acl, false)
      match = constraint.build["__aggregation_pipeline"].first["$match"]
      assert match.key?("$nor")
      assert_equal(
        [{ "$and" => [
          { "_rperm" => { "$exists" => true, "$eq" => [] } },
          { "_wperm" => { "$exists" => true, "$eq" => [] } },
        ] }],
        match["$nor"],
      )
    end
  end

  # Test Query integration
  describe "Query integration" do
    it "Query#readable_by accepts empty array" do
      query = Parse::Query.new("Song")
      result = query.readable_by([])
      assert_instance_of Parse::Query, result
    end

    it "Query#readable_by accepts 'none'" do
      query = Parse::Query.new("Song")
      result = query.readable_by("none")
      assert_instance_of Parse::Query, result
    end

    it "Query#readable_by accepts user ID" do
      query = Parse::Query.new("Song")
      result = query.readable_by("user123")
      assert_instance_of Parse::Query, result
    end

    it "Query#writable_by accepts empty array" do
      query = Parse::Query.new("Song")
      result = query.writable_by([])
      assert_instance_of Parse::Query, result
    end

    it "Query#writable_by accepts 'none'" do
      query = Parse::Query.new("Song")
      result = query.writable_by("none")
      assert_instance_of Parse::Query, result
    end

    it "Query#readable_by accepts mongo_direct option" do
      query = Parse::Query.new("Song")
      result = query.readable_by([], mongo_direct: true)
      assert_instance_of Parse::Query, result
      assert_equal true, query.instance_variable_get(:@acl_query_mongo_direct)
    end

    it "Query#readable_by accepts mongo_direct: false" do
      query = Parse::Query.new("Song")
      result = query.readable_by("user123", mongo_direct: false)
      assert_instance_of Parse::Query, result
      assert_equal false, query.instance_variable_get(:@acl_query_mongo_direct)
    end

    it "Query#writable_by accepts mongo_direct option" do
      query = Parse::Query.new("Song")
      result = query.writable_by([], mongo_direct: true)
      assert_instance_of Parse::Query, result
      assert_equal true, query.instance_variable_get(:@acl_query_mongo_direct)
    end

    it "Query#readable_by_role accepts mongo_direct option" do
      query = Parse::Query.new("Song")
      result = query.readable_by_role("Admin", mongo_direct: true)
      assert_instance_of Parse::Query, result
      assert_equal true, query.instance_variable_get(:@acl_query_mongo_direct)
    end

    it "Query#writable_by_role accepts mongo_direct option" do
      query = Parse::Query.new("Song")
      result = query.writable_by_role("Editor", mongo_direct: true)
      assert_instance_of Parse::Query, result
      assert_equal true, query.instance_variable_get(:@acl_query_mongo_direct)
    end

    it "Query#readable_by without mongo_direct does not set the variable" do
      query = Parse::Query.new("Song")
      result = query.readable_by("user123")
      assert_instance_of Parse::Query, result
      # Variable should not be defined or be nil
      refute query.instance_variable_defined?(:@acl_query_mongo_direct) &&
             !query.instance_variable_get(:@acl_query_mongo_direct).nil?
    end

    it "requires aggregation pipeline for ACL queries" do
      query = Parse::Query.new("Song")
      query.readable_by("user123")
      # The query should now require aggregation pipeline
      assert query.send(:requires_aggregation_pipeline?)
    end
  end

  # Test execute_aggregation_pipeline mongo_direct handling
  describe "execute_aggregation_pipeline mongo_direct" do
    it "respects explicit mongo_direct: true" do
      query = Parse::Query.new("Song")
      query.readable_by("user123", mongo_direct: true)

      # Verify the mongo_direct flag is stored on the query
      assert_equal true, query.instance_variable_get(:@acl_query_mongo_direct)
    end

    it "respects explicit mongo_direct: false to disable auto-detection" do
      query = Parse::Query.new("Song")
      query.readable_by("user123", mongo_direct: false)

      # Even though ACL queries normally auto-detect mongo_direct,
      # explicit false should disable it
      assert_equal false, query.instance_variable_get(:@acl_query_mongo_direct)
    end
  end
end
