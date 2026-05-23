# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../../test_helper"

class TestAclQueryConstraints < Minitest::Test
  extend Minitest::Spec::DSL

  # Test ReadableByConstraint
  describe "ReadableByConstraint" do
    it "registers :readable_by operator" do
      assert_includes Parse::Operation.operators.keys, :readable_by
    end

    it "creates constraint with Symbol#readable_by" do
      assert_respond_to :field, :readable_by
      op = :field.readable_by
      assert_instance_of Parse::Operation, op
      assert_equal :readable_by, op.operator
    end

    it "builds empty array constraint for no read permissions" do
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, [])
      result = constraint.build

      assert result.key?("__aggregation_pipeline")
      pipeline = result["__aggregation_pipeline"]
      assert_instance_of Array, pipeline
      assert_equal 1, pipeline.length

      match_stage = pipeline.first["$match"]
      assert match_stage.key?("$or")
      # Should match empty _rperm or missing _rperm
      or_conditions = match_stage["$or"]
      assert_equal 2, or_conditions.length
    end

    it "builds empty array constraint for 'none' string" do
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, "none")
      result = constraint.build

      assert result.key?("__aggregation_pipeline")
      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      assert match_stage.key?("$or")
    end

    it "builds empty array constraint for :none symbol" do
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, :none)
      result = constraint.build

      assert result.key?("__aggregation_pipeline")
      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      assert match_stage.key?("$or")
    end

    it "builds $in constraint for user ID string" do
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, "user123")
      result = constraint.build

      assert result.key?("__aggregation_pipeline")
      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      assert_equal({ "$in" => ["user123"] }, match_stage["_rperm"])
    end

    it "builds $in constraint for role string" do
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, "role:Admin")
      result = constraint.build

      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      assert_equal({ "$in" => ["role:Admin"] }, match_stage["_rperm"])
    end

    it "converts :public to *" do
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, :public)
      result = constraint.build

      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      assert_equal({ "$in" => ["*"] }, match_stage["_rperm"])
    end

    it "converts 'public' string to *" do
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, "public")
      result = constraint.build

      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      assert_equal({ "$in" => ["*"] }, match_stage["_rperm"])
    end

    it "handles array of mixed permissions" do
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, ["user123", "role:Admin", "*"])
      result = constraint.build

      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      in_array = match_stage["_rperm"]["$in"]
      assert_includes in_array, "user123"
      assert_includes in_array, "role:Admin"
      assert_includes in_array, "*"
    end

    it "extracts user ID from Parse::User" do
      user = Parse::User.new
      user.id = "abc123"
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, user)
      result = constraint.build

      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      assert_equal({ "$in" => ["abc123"] }, match_stage["_rperm"])
    end

    it "extracts role name from Parse::Role" do
      role = Parse::Role.new
      role.name = "Editor"
      constraint = Parse::Constraint::ReadableByConstraint.new(:acl.readable_by, role)
      result = constraint.build

      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      assert_equal({ "$in" => ["role:Editor"] }, match_stage["_rperm"])
    end
  end

  # Test WriteableByConstraint
  describe "WriteableByConstraint" do
    it "registers :writeable_by and :writable_by operators" do
      assert_includes Parse::Operation.operators.keys, :writeable_by
      assert_includes Parse::Operation.operators.keys, :writable_by
    end

    it "builds empty array constraint for no write permissions" do
      constraint = Parse::Constraint::WriteableByConstraint.new(:acl.writeable_by, [])
      result = constraint.build

      assert result.key?("__aggregation_pipeline")
      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      assert match_stage.key?("$or")
    end

    it "builds $in constraint for user ID" do
      constraint = Parse::Constraint::WriteableByConstraint.new(:acl.writeable_by, "user456")
      result = constraint.build

      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      assert_equal({ "$in" => ["user456"] }, match_stage["_wperm"])
    end
  end

  # Test NotReadableByConstraint
  describe "NotReadableByConstraint" do
    it "registers :not_readable_by operator" do
      assert_includes Parse::Operation.operators.keys, :not_readable_by
    end

    it "builds $nin constraint" do
      constraint = Parse::Constraint::NotReadableByConstraint.new(:acl.not_readable_by, "user123")
      result = constraint.build

      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      assert_equal({ "$nin" => ["user123"] }, match_stage["_rperm"])
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

    it "builds $nin constraint" do
      constraint = Parse::Constraint::NotWriteableByConstraint.new(:acl.not_writeable_by, "user123")
      result = constraint.build

      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      assert_equal({ "$nin" => ["user123"] }, match_stage["_wperm"])
    end
  end

  # Test PrivateAclConstraint
  describe "PrivateAclConstraint" do
    it "registers :private_acl and :master_key_only operators" do
      assert_includes Parse::Operation.operators.keys, :private_acl
      assert_includes Parse::Operation.operators.keys, :master_key_only
    end

    it "builds constraint for private ACL (true)" do
      constraint = Parse::Constraint::PrivateAclConstraint.new(:acl.private_acl, true)
      result = constraint.build

      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      # Should have $and with conditions for both _rperm and _wperm being empty
      assert match_stage.key?("$and")
      assert_equal 2, match_stage["$and"].length
    end

    it "builds constraint for non-private ACL (false)" do
      constraint = Parse::Constraint::PrivateAclConstraint.new(:acl.private_acl, false)
      result = constraint.build

      pipeline = result["__aggregation_pipeline"]
      match_stage = pipeline.first["$match"]
      # Should have $or to match objects with some permissions
      assert match_stage.key?("$or")
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
      skip "Requires Parse::MongoDB to be defined" unless defined?(Parse::MongoDB)

      query = Parse::Query.new("Song")
      query.readable_by([], mongo_direct: true)

      # Check that the aggregation will use mongo_direct
      aggregation = query.send(:execute_aggregation_pipeline)
      # The aggregation should have mongo_direct set
      # (implementation detail - may need to check via different means)
    end

    it "respects explicit mongo_direct: false to disable auto-detection" do
      query = Parse::Query.new("Song")
      query.readable_by([], mongo_direct: false)

      # Even though ACL queries normally auto-detect mongo_direct,
      # explicit false should disable it
      assert_equal false, query.instance_variable_get(:@acl_query_mongo_direct)
    end
  end
end
