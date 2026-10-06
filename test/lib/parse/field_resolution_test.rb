# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Query compilation and the agent field allowlist resolve a field name with
# one rule (Parse::Model.wire_name_for): a Ruby property name maps to its
# declared column first, then a name that is exactly a declared column stays
# as is, else default formatting. Before, the two used opposite precedence,
# so an allowlist check could approve one column while the query addressed
# another.
class FieldResolutionTest < Minitest::Test
  # The property DSL refuses to declare `legacy_email` with remote name
  # "email" next to `email` (it reports a conflicting alias), so the
  # collision is set up through field_map, the table both paths read.
  class Contact < Parse::Object
    parse_class "FieldResolutionContact"
    property :email, :string, field: "contactEmail"
    property :nickname, :string
    field_map[:legacy_email] = :email
    Parse::Model.model_registry_changed!
  end

  class LinkedDoc < Parse::Object
    parse_class "FrLinkedDoc"
    belongs_to :owner, as: :user, field: "OwnerRef"
  end

  class Outer < Parse::Object
    parse_class "FieldResolutionOuter"
    belongs_to :owner, as: :user, field: "OuterOwner"
    belongs_to :fr_linked_doc
  end

  def teardown
    %i[FieldResolutionReloaded FieldResolutionLateNamed].each do |c|
      Object.send(:remove_const, c) if Object.const_defined?(c, false)
    end
  end

  # ---- one resolution rule -------------------------------------------------

  def test_ruby_property_name_wins_over_a_colliding_column_in_compile
    assert_equal({ "contactEmail" => "a" }, Contact.query(email: "a").compile_where)
    assert_equal({ "email" => "b" }, Contact.query(legacy_email: "b").compile_where)
    assert_equal({ "contactEmail" => "c" }, Contact.query("contactEmail" => "c").compile_where)
    assert_equal({ "nickname" => "d" }, Contact.query(nickname: "d").compile_where)
  end

  def test_ruby_property_name_wins_over_a_colliding_column_in_wire_field_names
    names = Parse::Agent::MetadataRegistry.wire_field_names(
      "FieldResolutionContact", %w[email legacy_email contactEmail nickname]
    )
    assert_equal %w[contactEmail email nickname], names
  end

  def test_allowlist_check_and_compiled_query_address_the_same_column
    %w[email legacy_email contactEmail nickname].each do |name|
      wire = Parse::Agent::MetadataRegistry.wire_field_names("FieldResolutionContact", [name]).first
      compiled = Contact.query(name => 1).compile_where.keys
      assert_equal [wire], compiled, "#{name} must resolve to one column on both paths"
    end
  end

  def test_wire_name_for
    assert_equal "contactEmail", Parse::Model.wire_name_for(Contact, :email)
    assert_equal "email", Parse::Model.wire_name_for(Contact, "legacy_email")
    assert_equal "contactEmail", Parse::Model.wire_name_for(Contact, "contactEmail")
    assert_nil Parse::Model.wire_name_for(Contact, "undeclared_thing")
    assert_nil Parse::Model.wire_name_for(nil, "email")
  end

  # ---- model cache staleness ------------------------------------------------

  def test_find_class_returns_a_redefined_model_not_the_removed_one
    eval(<<~RUBY, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
      class FieldResolutionReloaded < Parse::Object
        parse_class "FieldResolutionReloaded"
        property :code, :string, field: "old_code"
      end
    RUBY
    old = Object.const_get(:FieldResolutionReloaded)
    assert_equal old, Parse::Model.find_class("FieldResolutionReloaded")
    assert_equal({ "old_code" => 1 }, old.query(code: 1).compile_where)

    Object.send(:remove_const, :FieldResolutionReloaded)
    eval(<<~RUBY, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
      class FieldResolutionReloaded < Parse::Object
        parse_class "FieldResolutionReloaded"
        property :code, :string, field: "new_code"
      end
    RUBY
    fresh = Object.const_get(:FieldResolutionReloaded)
    refute_same old, fresh
    assert_same fresh, Parse::Model.find_class("FieldResolutionReloaded")
    assert_same fresh, Parse::Query.new("FieldResolutionReloaded").send(:table_model_class)
    assert_equal({ "new_code" => 1 }, Parse::Query.new("FieldResolutionReloaded", code: 1).compile_where)
  end

  def test_anonymous_model_named_after_a_miss_is_found
    klass = Class.new(Parse::Object)
    assert_nil Parse::Model.find_class("FieldResolutionLateNamed")
    assert Parse::Model.model_cache_misses.key?("FieldResolutionLateNamed")
    Object.const_set(:FieldResolutionLateNamed, klass)
    assert_same klass, Parse::Model.find_class("FieldResolutionLateNamed")
  end

  def test_association_declarations_advance_the_registry_generation
    klass = Class.new(Parse::Object) do
      def self.name
        "FieldResolutionTest::AssocDoc"
      end
      parse_class "FieldResolutionAssocDoc"
    end
    before = Parse::Model.model_generation
    klass.belongs_to :holder, as: :user, field: "HolderRef"
    assert_operator Parse::Model.model_generation, :>, before
    before = Parse::Model.model_generation
    klass.has_many :tags, as: :user, through: :relation, field: "TagRel"
    assert_operator Parse::Model.model_generation, :>, before
    assert_equal "HolderRef", Parse::Query.field_aliases_for("FieldResolutionAssocDoc")["holder"]
  end

  def test_same_size_field_map_change_is_seen_after_a_registry_bump
    assert_equal({ "contactEmail" => 1 }, Contact.query(email: 1).compile_where)
    original = Contact.field_map[:email]
    Contact.field_map[:email] = :primaryEmail
    Parse::Model.model_registry_changed!
    assert_equal({ "primaryEmail" => 1 }, Contact.query(email: 1).compile_where)
    assert_equal ["primaryEmail"], Parse::Agent::MetadataRegistry.wire_field_names("FieldResolutionContact", ["email"])
  ensure
    Contact.field_map[:email] = original
    Parse::Model.model_registry_changed!
  end

  # ---- linked-pointer constraints -------------------------------------------

  def linked_pipeline(constraint_class)
    op = Parse::Operation.new(:owner, :equals_linked_pointer)
    constraint = constraint_class.new(op, { through: :fr_linked_doc, field: :owner })
    Parse::Query.with_field_aliases("FieldResolutionOuter") { constraint.build }["__aggregation_pipeline"]
  end

  def test_equals_linked_pointer_formats_the_target_with_the_linked_class
    pipeline = linked_pipeline(Parse::Constraint::PointerEqualsLinkedPointerConstraint)
    expr = pipeline.last["$match"]["$expr"]["$eq"]
    assert_equal "$frLinkedDoc_data._p_OwnerRef", expr[0]["$arrayElemAt"][0]
    assert_equal "$_p_OuterOwner", expr[1]
  end

  def test_does_not_equal_linked_pointer_formats_the_target_with_the_linked_class
    pipeline = linked_pipeline(Parse::Constraint::DoesNotEqualLinkedPointerConstraint)
    expr = pipeline.last["$match"]["$expr"]["$ne"]
    assert_equal "$frLinkedDoc_data._p_OwnerRef", expr[0]["$arrayElemAt"][0]
    assert_equal "$_p_OuterOwner", expr[1]
  end

  # ---- inherited scope after the compile ends -------------------------------

  def test_thread_started_during_a_compile_drops_the_scope_after_it_ends
    gate = Queue.new
    seen = {}
    thread = nil
    Parse::Query.with_field_aliases("FieldResolutionContact") do
      thread = Thread.new do
        seen[:during] = Parse::Query.format_field("email")
        gate.pop
        seen[:after] = Parse::Query.format_field("email")
        seen[:table] = Parse::Query.field_alias_table
      end
      sleep 0.01 until seen.key?(:during)
    end
    gate << :go
    thread.join
    assert_equal "contactEmail", seen[:during]
    assert_equal "email", seen[:after]
    assert_nil seen[:table]
  end
end
